; UiBrowserHandler.ahk
; AHK-seitige Logik fuer den interaktiven Game-UI-Browser im WebView.
;
; Neue Bridge-Cases (in BridgeDispatch.ahk einfuegen):
;   "UiBrowseRoot"       -> navigiert zu GameUiPtr (Root)
;   "UiBrowseParent"     -> geht eine Ebene hoch
;   "UiBrowseChild"      -> navigiert zu einem bestimmten Kind (index)
;   "UiBrowseAddress"    -> springt direkt zu einer Adresse (hex string)
;   "UiBrowseSearch"     -> sucht im aktuellen Baum nach einer StringId
;
; Neue AHK->JS Funktion:
;   PushUiBrowserState() -> schickt den aktuellen Browser-Zustand ans WebView
;
; Voraussetzungen:
;   #Include UiTreeBrowser.ahk   (ReadElement, GetChildByIndex, GetChildByStringId)
;   g_reader, g_webGui muessen global verfuegbar sein
;
; Inkludieren in InGameStateMonitor.ahk:
;   #Include UiTreeBrowser.ahk
;   #Include UiBrowserHandler.ahk

; -- Globaler Browser-State ----------------------------------------------------
global g_uiBrowserCurrentPtr := 0        ; aktuell angezeigte Element-Adresse
global g_uiBrowserHistory := []        ; Stack fuer "Back"-Navigation: [ptr, ptr, ...]
global g_uiBrowserRootPtr := 0        ; GameUiPtr zum Session-Start

; -- Hilfsfunktion: GameUiPtr aus dem letzten Snapshot holen ------------------
_UiBrowser_GetGameUiPtr()
{
    global g_reader
    if !IsObject(g_reader)
        return 0

    try {
        ; Erst Cache versuchen, dann live lesen falls Cache noch leer
        igs := g_reader._radarInGameStateCache
        if !g_reader.IsProbablyValidPointer(igs)
        {
            ; Cache noch nicht gefuellt - direkt ueber GameStatesAddress aufloesen
            if !g_reader.IsProbablyValidPointer(g_reader.GameStatesAddress)
                return 0
            staticPtr := g_reader.Mem.ReadPtr(g_reader.GameStatesAddress)
            if !g_reader.IsProbablyValidPointer(staticPtr)
                return 0
            statesBase := staticPtr + PoE2Offsets.GameState["States"]
            ; InGameState ist Index 4 (0-basiert)
            igs := g_reader.Mem.ReadPtr(statesBase + (4 * PoE2Offsets.GameState["StateEntrySize"]))
            if !g_reader.IsProbablyValidPointer(igs)
                return 0
        }
        uiRootStructPtr := g_reader.Mem.ReadPtr(igs + PoE2Offsets.InGameState["UiRootStructPtr"])
        if !g_reader.IsProbablyValidPointer(uiRootStructPtr)
            return 0
        gameUiPtr := g_reader.Mem.ReadPtr(uiRootStructPtr + PoE2Offsets.UiRootStruct["GameUiPtr"])
        if !g_reader.IsProbablyValidPointer(gameUiPtr)
            gameUiPtr := g_reader.Mem.ReadPtr(uiRootStructPtr + PoE2Offsets.UiRootStruct["GameUiControllerPtr"])
        return gameUiPtr
    } catch {
        return 0
    }
}

; -- Navigiert zum Root (GameUiPtr) -------------------------------------------
UiBrowseRoot()
{
    global g_uiBrowserCurrentPtr, g_uiBrowserHistory, g_uiBrowserRootPtr, g_reader

    if !IsObject(g_reader) {
        WebViewExec("updateUiBrowser(" _JsStr('{"error":"DIAG 1: g_reader ist kein Objekt"}') ")")
        return
    }
    if !g_reader.Mem.Handle {
        WebViewExec("updateUiBrowser(" _JsStr('{"error":"DIAG 2: Kein Prozess-Handle - Spiel nicht verbunden?"}') ")")
        return
    }

    igs := g_reader._radarInGameStateCache
    if !g_reader.IsProbablyValidPointer(igs) {
        if !g_reader.IsProbablyValidPointer(g_reader.GameStatesAddress) {
            WebViewExec("updateUiBrowser(" _JsStr('{"error":"DIAG 3: GameStatesAddress ungueltig (0x' Format("{:X}", g_reader.GameStatesAddress) ')"}') ")")
            return
        }
        staticPtr := g_reader.Mem.ReadPtr(g_reader.GameStatesAddress)
        if !g_reader.IsProbablyValidPointer(staticPtr) {
            WebViewExec("updateUiBrowser(" _JsStr('{"error":"DIAG 4: staticPtr ungueltig"}') ")")
            return
        }
        statesBase := staticPtr + PoE2Offsets.GameState["States"]
        igs := g_reader.Mem.ReadPtr(statesBase + (4 * PoE2Offsets.GameState["StateEntrySize"]))
        if !g_reader.IsProbablyValidPointer(igs) {
            WebViewExec("updateUiBrowser(" _JsStr('{"error":"DIAG 5: InGameState-Ptr ungueltig - Spiel im Login-Screen?"}') ")")
            return
        }
    }

    uiRootStructPtr := g_reader.Mem.ReadPtr(igs + PoE2Offsets.InGameState["UiRootStructPtr"])
    if !g_reader.IsProbablyValidPointer(uiRootStructPtr) {
        WebViewExec("updateUiBrowser(" _JsStr('{"error":"DIAG 6: UiRootStructPtr ungueltig (igs=0x' Format("{:X}", igs) ')"}') ")")
        return
    }

    gameUiPtr := g_reader.Mem.ReadPtr(uiRootStructPtr + PoE2Offsets.UiRootStruct["GameUiPtr"])
    if !g_reader.IsProbablyValidPointer(gameUiPtr)
        gameUiPtr := g_reader.Mem.ReadPtr(uiRootStructPtr + PoE2Offsets.UiRootStruct["GameUiControllerPtr"])
    if !g_reader.IsProbablyValidPointer(gameUiPtr) {
        WebViewExec("updateUiBrowser(" _JsStr('{"error":"DIAG 7: GameUiPtr ungueltig (uiRootStruct=0x' Format("{:X}", uiRootStructPtr) ')"}') ")")
        return
    }

    g_uiBrowserRootPtr := gameUiPtr
    g_uiBrowserCurrentPtr := gameUiPtr
    g_uiBrowserHistory := []
    PushUiBrowserState()
}

; -- Navigiert zum Parent des aktuellen Elements -------------------------------
UiBrowseParent()
{
    global g_uiBrowserCurrentPtr, g_uiBrowserHistory, g_reader, g_uiBrowserRootPtr
    if !IsObject(g_reader) || !g_reader.IsProbablyValidPointer(g_uiBrowserCurrentPtr)
        return

    ; Nicht ueber Root hinaus
    if (g_uiBrowserCurrentPtr = g_uiBrowserRootPtr)
        return

    try {
        parentPtr := g_reader.Mem.ReadPtr(g_uiBrowserCurrentPtr + PoE2Offsets.UiElementBase["ParentPtr"])
        if !g_reader.IsProbablyValidPointer(parentPtr)
            return
        g_uiBrowserHistory.Push(g_uiBrowserCurrentPtr)
        if (g_uiBrowserHistory.Length > 64)
            g_uiBrowserHistory.RemoveAt(1)
        g_uiBrowserCurrentPtr := parentPtr
        PushUiBrowserState()
    } catch {
    }
}

; -- Navigiert zu einem Kind per Index ----------------------------------------
UiBrowseChild(childIndex)
{
    global g_uiBrowserCurrentPtr, g_uiBrowserHistory, g_reader
    if !IsObject(g_reader) || !g_reader.IsProbablyValidPointer(g_uiBrowserCurrentPtr)
        return

    childPtr := UiTree_GetChildByIndex(g_reader, g_uiBrowserCurrentPtr, Integer(childIndex))
    if !g_reader.IsProbablyValidPointer(childPtr)
        return

    g_uiBrowserHistory.Push(g_uiBrowserCurrentPtr)
    if (g_uiBrowserHistory.Length > 64)
        g_uiBrowserHistory.RemoveAt(1)
    g_uiBrowserCurrentPtr := childPtr
    PushUiBrowserState()
}

; -- Springt direkt zu einer Hex-Adresse --------------------------------------
UiBrowseAddress(hexAddr)
{
    global g_uiBrowserCurrentPtr, g_uiBrowserHistory, g_reader
    if !IsObject(g_reader)
        return

    try ptr := Integer(hexAddr)
    catch {
        return
    }

    if !g_reader.IsProbablyValidPointer(ptr)
        return

    if (g_uiBrowserCurrentPtr && g_reader.IsProbablyValidPointer(g_uiBrowserCurrentPtr))
        g_uiBrowserHistory.Push(g_uiBrowserCurrentPtr)
    if (g_uiBrowserHistory.Length > 64)
        g_uiBrowserHistory.RemoveAt(1)
    g_uiBrowserCurrentPtr := ptr
    PushUiBrowserState()
}

; -- Geht einen Schritt zurueck in der History ----------------------------------
UiBrowseBack()
{
    global g_uiBrowserCurrentPtr, g_uiBrowserHistory, g_reader
    if (g_uiBrowserHistory.Length = 0)
        return
    prev := g_uiBrowserHistory.Pop()
    if !g_reader.IsProbablyValidPointer(prev)
        return
    g_uiBrowserCurrentPtr := prev
    PushUiBrowserState()
}

; -- Sucht Kinder des aktuellen Elements nach StringId-Substring ---------------
UiBrowseSearch(query)
{
    global g_uiBrowserCurrentPtr, g_reader
    if !IsObject(g_reader) || !g_reader.IsProbablyValidPointer(g_uiBrowserCurrentPtr)
        return

    query := Trim(query)
    if (query = "") {
        PushUiBrowserState()
        return
    }

    ; BFS ab aktuellem Element, max 500 Nodes, findet alle die query enthalten
    results := []
    queue := [g_uiBrowserCurrentPtr]
    visited := Map()
    deadline := A_TickCount + 3000

    while (queue.Length > 0 && A_TickCount < deadline)
    {
        ptr := queue.RemoveAt(1)
        if (visited.Has(ptr))
            continue
        visited[ptr] := true

        elem := UiTree_ReadElement(g_reader, ptr)
        if !elem
            continue

        sid := elem["stringId"]
        if (sid != "" && InStr(StrLower(sid), StrLower(query)))
            results.Push(Map("ptr", ptr, "stringId", sid, "isVisible", elem["isVisible"]))

        if (results.Length >= 200)
            break

        ; Kinder einschieben
        childFirst := elem["childFirst"]
        childLast := elem["childLast"]
        if (g_reader.IsProbablyValidPointer(childFirst) && childLast > childFirst)
        {
            n := Min((childLast - childFirst) // A_PtrSize, 256)
            buf := g_reader.Mem.ReadBytes(childFirst, n * A_PtrSize)
            if buf {
                Loop n {
                    cp := NumGet(buf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
                    if (g_reader.IsProbablyValidPointer(cp) && !visited.Has(cp))
                        queue.Push(cp)
                }
            }
        }
    }

    ; Ergebnisse als JSON ans WebView
    rows := "["
    first := true
    for _, r in results {
        if !first
            rows .= ","
        first := false
        rows .= '{"ptr":"' Format("0x{:X}", r["ptr"]) '"'
            . ',"stringId":' _JsStrEscape(r["stringId"])
            . ',"isVisible":' (r["isVisible"] ? "true" : "false") '}'
    }
    rows .= "]"

    WebViewExec("updateUiBrowserSearch(" rows "," _JsStr(query) ")")
}

; -- Haupt-Push-Funktion: liest aktuelles Element + alle Kinder -> WebView -----
PushUiBrowserState()
{
    global g_uiBrowserCurrentPtr, g_uiBrowserHistory, g_uiBrowserRootPtr, g_reader
    if !IsObject(g_reader)
        return

    ; Auto-Init wenn noch kein Ptr gesetzt
    if !g_reader.IsProbablyValidPointer(g_uiBrowserCurrentPtr)
    {
        UiBrowseRoot()
        return
    }

    ; Aktuelles Element lesen
    elem := UiTree_ReadElement(g_reader, g_uiBrowserCurrentPtr)
    if !elem {
        WebViewExec("updateUiBrowser(" _JsStr('{"error":"Element nicht lesbar (Adresse ungueltig oder Spiel nicht verbunden)."}') ")")
        return
    }

    ; -- Breadcrumb-Pfad aufbauen (max 8 Schritte zur Root) ----------------
    breadcrumb := []
    curPtr := g_uiBrowserCurrentPtr
    Loop 16 {
        if !g_reader.IsProbablyValidPointer(curPtr)
            break
        e := UiTree_ReadElement(g_reader, curPtr)
        if !e
            break
        breadcrumb.InsertAt(1, Map("ptr", curPtr, "stringId", e["stringId"]))
        parentPtr := e["parentPtr"]
        if (!g_reader.IsProbablyValidPointer(parentPtr) || parentPtr = curPtr)
            break
        if (curPtr = g_uiBrowserRootPtr)
            break
        curPtr := parentPtr
    }

    ; -- Kinder lesen (max 256, Batch-RPM) --------------------------------
    children := []
    childFirst := elem["childFirst"]
    childLast := elem["childLast"]
    childCount := elem["childCount"]
    if (g_reader.IsProbablyValidPointer(childFirst) && childLast > childFirst && childCount > 0)
    {
        n := Min(childCount, 256)
        buf := g_reader.Mem.ReadBytes(childFirst, n * A_PtrSize)
        if buf {
            Loop n {
                cp := NumGet(buf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
                if !g_reader.IsProbablyValidPointer(cp)
                    continue
                ce := UiTree_ReadElement(g_reader, cp)
                sid := ce ? ce["stringId"] : ""
                vis := ce ? ce["isVisible"] : false
                cc := ce ? ce["childCount"] : 0
                children.Push(Map(
                    "idx", A_Index - 1,
                    "ptr", cp,
                    "stringId", sid,
                    "isVisible", vis,
                    "childCount", cc
                ))
            }
        }
    }

    ; -- JSON bauen --------------------------------------------------------
    ; Breadcrumb
    bcJson := "["
    first := true
    for _, b in breadcrumb {
        if !first bcJson .= ","
            first := false
        bcJson .= '{"ptr":"' Format("0x{:X}", b["ptr"]) '"'
            . ',"stringId":' _JsStrEscape(b["stringId"]) '}'
    }
    bcJson .= "]"

    ; Children
    chJson := "["
    first := true
    for _, c in children {
        if !first chJson .= ","
            first := false
        chJson .= '{"idx":' c["idx"]
            . ',"ptr":"' Format("0x{:X}", c["ptr"]) '"'
            . ',"stringId":' _JsStrEscape(c["stringId"])
            . ',"isVisible":' (c["isVisible"] ? "true" : "false")
            . ',"childCount":' c["childCount"] '}'
    }
    chJson .= "]"

    ; Aktuelles Element Properties
    propsJson := '{'
        . '"address":"' Format("0x{:X}", g_uiBrowserCurrentPtr) '"'
        . ',"stringId":' _JsStrEscape(elem["stringId"])
        . ',"isVisible":' (elem["isVisible"] ? "true" : "false")
        . ',"childCount":' elem["childCount"]
        . ',"flags":"' Format("0x{:08X}", elem["flags"]) '"'
        . ',"relX":' Round(elem["relX"], 2)
        . ',"relY":' Round(elem["relY"], 2)
        . ',"sizeW":' Round(elem["sizeW"], 1)
        . ',"sizeH":' Round(elem["sizeH"], 1)
        . ',"scaleIndex":' elem["scaleIndex"]
        . ',"localMult":' Round(elem["localMult"], 4)
        . ',"vtable":"' Format("0x{:X}", elem["vtable"]) '"'
        . ',"parentPtr":"' Format("0x{:X}", elem["parentPtr"]) '"'
        . '}'

    ; Alles zusammen
    payload := '{'
        . '"breadcrumb":' bcJson
        . ',"children":' chJson
        . ',"props":' propsJson
        . ',"canBack":' (g_uiBrowserHistory.Length > 0 ? "true" : "false")
        . ',"isRoot":' (g_uiBrowserCurrentPtr = g_uiBrowserRootPtr ? "true" : "false")
        . '}'

    WebViewExec("updateUiBrowser(" _JsStr(payload) ")")
}

; -- Hilfsfunktion: String fuer JSON escapen (ohne aeussere Quotes-Wrapper) -------
_JsStrEscape(s)
{
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`r", "\r")
    return '"' s '"'
}