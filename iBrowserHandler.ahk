; UiBrowserHandler.ahk
; Interactive Game UI Browser - AHK side logic

global g_uiBrowserCurrentPtr := 0
global g_uiBrowserHistory := []
global g_uiBrowserRootPtr := 0

_UiBrowser_GetGameUiPtr()
{
    global g_reader
    if !IsObject(g_reader)
        return 0
    try {
        igs := g_reader._radarInGameStateCache
        if !g_reader.IsProbablyValidPointer(igs)
        {
            if !g_reader.IsProbablyValidPointer(g_reader.GameStatesAddress)
                return 0
            staticPtr := g_reader.Mem.ReadPtr(g_reader.GameStatesAddress)
            if !g_reader.IsProbablyValidPointer(staticPtr)
                return 0
            statesBase := staticPtr + PoE2Offsets.GameState["States"]
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

UiBrowseRoot()
{
    global g_uiBrowserCurrentPtr, g_uiBrowserHistory, g_uiBrowserRootPtr, g_reader

    if !IsObject(g_reader) {
        WebViewExec("updateUiBrowser(" . _JsStr('{"error":"DIAG 1: g_reader not ready"}') . ")")
        return
    }
    if !g_reader.Mem.Handle {
        WebViewExec("updateUiBrowser(" . _JsStr('{"error":"DIAG 2: No process handle - game not connected?"}') . ")")
        return
    }
    igs := g_reader._radarInGameStateCache
    if !g_reader.IsProbablyValidPointer(igs)
    {
        if !g_reader.IsProbablyValidPointer(g_reader.GameStatesAddress) {
            WebViewExec("updateUiBrowser(" . _JsStr('{"error":"DIAG 3: GameStatesAddress invalid"}') . ")")
            return
        }
        staticPtr := g_reader.Mem.ReadPtr(g_reader.GameStatesAddress)
        if !g_reader.IsProbablyValidPointer(staticPtr) {
            WebViewExec("updateUiBrowser(" . _JsStr('{"error":"DIAG 4: staticPtr invalid"}') . ")")
            return
        }
        statesBase := staticPtr + PoE2Offsets.GameState["States"]
        igs := g_reader.Mem.ReadPtr(statesBase + (4 * PoE2Offsets.GameState["StateEntrySize"]))
        if !g_reader.IsProbablyValidPointer(igs) {
            WebViewExec("updateUiBrowser(" . _JsStr('{"error":"DIAG 5: InGameState ptr invalid - in login screen?"}') . ")")
            return
        }
    }
    uiRootStructPtr := g_reader.Mem.ReadPtr(igs + PoE2Offsets.InGameState["UiRootStructPtr"])
    if !g_reader.IsProbablyValidPointer(uiRootStructPtr) {
        WebViewExec("updateUiBrowser(" . _JsStr('{"error":"DIAG 6: UiRootStructPtr invalid (igs=0x' . Format("{:X}", igs) . ')"}') . ")")
        return
    }
    gameUiPtr := g_reader.Mem.ReadPtr(uiRootStructPtr + PoE2Offsets.UiRootStruct["GameUiPtr"])
    if !g_reader.IsProbablyValidPointer(gameUiPtr)
        gameUiPtr := g_reader.Mem.ReadPtr(uiRootStructPtr + PoE2Offsets.UiRootStruct["GameUiControllerPtr"])
    if !g_reader.IsProbablyValidPointer(gameUiPtr) {
        WebViewExec("updateUiBrowser(" . _JsStr('{"error":"DIAG 7: GameUiPtr invalid (uiRootStruct=0x' . Format("{:X}", uiRootStructPtr) . ')"}') . ")")
        return
    }
    g_uiBrowserRootPtr := gameUiPtr
    g_uiBrowserCurrentPtr := gameUiPtr
    g_uiBrowserHistory := []
    PushUiBrowserState()
}

UiBrowseParent()
{
    global g_uiBrowserCurrentPtr, g_uiBrowserHistory, g_reader, g_uiBrowserRootPtr
    if !IsObject(g_reader) || !g_reader.IsProbablyValidPointer(g_uiBrowserCurrentPtr)
        return
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
    rows := "["
    first := true
    for _, r in results {
        if !first
            rows .= ","
        first := false
        sid := StrReplace(r["stringId"], "\", "\\")
        sid := StrReplace(sid, '"', '\"')
        rows .= '{"ptr":"' . Format("0x{:X}", r["ptr"]) . '"'
            . ',"stringId":"' . sid . '"'
            . ',"isVisible":' . (r["isVisible"] ? "true" : "false") . '}'
    }
    rows .= "]"
    qEsc := StrReplace(query, "\", "\\")
    qEsc := StrReplace(qEsc, '"', '\"')
    WebViewExec("updateUiBrowserSearch(" . rows . ',"' . qEsc . '")')
}

PushUiBrowserState()
{
    global g_uiBrowserCurrentPtr, g_uiBrowserHistory, g_uiBrowserRootPtr, g_reader
    if !IsObject(g_reader)
        return
    if !g_reader.IsProbablyValidPointer(g_uiBrowserCurrentPtr)
    {
        UiBrowseRoot()
        return
    }
    elem := UiTree_ReadElement(g_reader, g_uiBrowserCurrentPtr)
    if !elem {
        WebViewExec("updateUiBrowser(" . _JsStr('{"error":"Element not readable (invalid address or game not connected)"}') . ")")
        return
    }

    ; Build breadcrumb by walking parent chain
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

    ; Build children list
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
                children.Push(Map("idx", A_Index - 1, "ptr", cp, "stringId", sid, "isVisible", vis, "childCount", cc))
            }
        }
    }

    ; Build breadcrumb JSON
    bcJson := "["
    first := true
    for _, b in breadcrumb {
        if !first bcJson .= ","
            first := false
        sid := StrReplace(b["stringId"], "\", "\\")
        sid := StrReplace(sid, '"', '\"')
        bcJson .= '{"ptr":"' . Format("0x{:X}", b["ptr"]) . '","stringId":"' . sid . '"}'
    }
    bcJson .= "]"

    ; Build children JSON
    chJson := "["
    first := true
    for _, c in children {
        if !first chJson .= ","
            first := false
        sid := StrReplace(c["stringId"], "\", "\\")
        sid := StrReplace(sid, '"', '\"')
        chJson .= '{"idx":' . c["idx"]
            . ',"ptr":"' . Format("0x{:X}", c["ptr"]) . '"'
            . ',"stringId":"' . sid . '"'
            . ',"isVisible":' . (c["isVisible"] ? "true" : "false")
            . ',"childCount":' . c["childCount"] . '}'
    }
    chJson .= "]"

    ; Build props JSON
    sid := StrReplace(elem["stringId"], "\", "\\")
    sid := StrReplace(sid, '"', '\"')
    propsJson := '{'
        . '"address":"' . Format("0x{:X}", g_uiBrowserCurrentPtr) . '"'
        . ',"stringId":"' . sid . '"'
        . ',"isVisible":' . (elem["isVisible"] ? "true" : "false")
        . ',"childCount":' . elem["childCount"]
        . ',"flags":"' . Format("0x{:08X}", elem["flags"]) . '"'
        . ',"relX":' . Round(elem["relX"], 2)
        . ',"relY":' . Round(elem["relY"], 2)
        . ',"sizeW":' . Round(elem["sizeW"], 1)
        . ',"sizeH":' . Round(elem["sizeH"], 1)
        . ',"scaleIndex":' . elem["scaleIndex"]
        . ',"localMult":' . Round(elem["localMult"], 4)
        . ',"vtable":"' . Format("0x{:X}", elem["vtable"]) . '"'
        . ',"parentPtr":"' . Format("0x{:X}", elem["parentPtr"]) . '"'
        . '}'

    payload := '{'
        . '"breadcrumb":' . bcJson
        . ',"children":' . chJson
        . ',"props":' . propsJson
        . ',"canBack":' . (g_uiBrowserHistory.Length > 0 ? "true" : "false")
        . ',"isRoot":' . (g_uiBrowserCurrentPtr = g_uiBrowserRootPtr ? "true" : "false")
        . '}'

    WebViewExec("updateUiBrowser(" . _JsStr(payload) . ")")
}