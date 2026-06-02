; UiBrowserHandler.ahk
; Interactive Game UI Browser - AHK side logic

global g_uiBrowserCurrentPtr := 0
global g_uiBrowserHistory := []
global g_uiBrowserRootPtr := 0
global g_uiBrowserHighlight := 0   ; Map(x,y,w,h) in UI coords, or 0 when inactive

; Formats a float for JSON — always uses "." regardless of Windows locale.
_UibF(n, decimals := 2)
{
    return Format("{:." . decimals . "f}", n)
}

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

    ; Show immediate loading state so user gets feedback right away.
    WebViewExec("updateUiBrowser(" . _JsStr('{"loading":true,"breadcrumb":[],"children":[],"props":{"address":"0x0","stringId":"Connecting...","isVisible":false,"childCount":0,"flags":"0x00000000","relX":0.0,"relY":0.0,"sizeW":0.0,"sizeH":0.0,"scaleIndex":0,"localMult":1.0,"vtable":"0x0","parentPtr":"0x0"},"canBack":false,"isRoot":true}') . ")")

    try {
        if !IsObject(g_reader) {
            WebViewExec("updateUiBrowser(" . _JsStr('{"error":"DIAG 1: g_reader not ready"}') . ")")
            return
        }
        if !g_reader.Mem.Handle {
            WebViewExec("updateUiBrowser(" . _JsStr('{"error":"DIAG 2: No process handle — game not connected?"}') . ")")
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
                WebViewExec("updateUiBrowser(" . _JsStr('{"error":"DIAG 5: InGameState ptr invalid — in login screen?"}') . ")")
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
    } catch as ex {
        WebViewExec("updateUiBrowser(" . _JsStr('{"error":"Exception in UiBrowseRoot: ' . ex.Message . '"}') . ")")
    }
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
    try {
        childPtr := UiTree_GetChildByIndex(g_reader, g_uiBrowserCurrentPtr, Integer(childIndex))
        if !g_reader.IsProbablyValidPointer(childPtr)
            return
        g_uiBrowserHistory.Push(g_uiBrowserCurrentPtr)
        if (g_uiBrowserHistory.Length > 64)
            g_uiBrowserHistory.RemoveAt(1)
        g_uiBrowserCurrentPtr := childPtr
        PushUiBrowserState()
    } catch {
    }
}

UiBrowseAddress(hexAddr)
{
    global g_uiBrowserCurrentPtr, g_uiBrowserHistory, g_reader
    if !IsObject(g_reader)
        return
    try {
        ptr := Integer(hexAddr)
        if !g_reader.IsProbablyValidPointer(ptr)
            return
        if (g_uiBrowserCurrentPtr && g_reader.IsProbablyValidPointer(g_uiBrowserCurrentPtr))
            g_uiBrowserHistory.Push(g_uiBrowserCurrentPtr)
        if (g_uiBrowserHistory.Length > 64)
            g_uiBrowserHistory.RemoveAt(1)
        g_uiBrowserCurrentPtr := ptr
        PushUiBrowserState()
    } catch {
    }
}

UiBrowseBack()
{
    global g_uiBrowserCurrentPtr, g_uiBrowserHistory, g_reader
    if (g_uiBrowserHistory.Length = 0)
        return
    try {
        prev := g_uiBrowserHistory.Pop()
        if !g_reader.IsProbablyValidPointer(prev)
            return
        g_uiBrowserCurrentPtr := prev
        PushUiBrowserState()
    } catch {
    }
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
    try {
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
        for i, r in results {
            if (i > 1)
                rows .= ","
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
    } catch {
    }
}

PushUiBrowserState()
{
    global g_uiBrowserCurrentPtr, g_uiBrowserHistory, g_uiBrowserRootPtr, g_reader, g_uiBrowserHighlight
    if !IsObject(g_reader)
        return

    try {
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
        for i, b in breadcrumb {
            if (i > 1)
                bcJson .= ","
            sid := StrReplace(b["stringId"], "\", "\\")
            sid := StrReplace(sid, '"', '\"')
            bcJson .= '{"ptr":"' . Format("0x{:X}", b["ptr"]) . '","stringId":"' . sid . '"}'
        }
        bcJson .= "]"

        ; Build children JSON
        chJson := "["
        for i, c in children {
            if (i > 1)
                chJson .= ","
            sid := StrReplace(c["stringId"], "\", "\\")
            sid := StrReplace(sid, '"', '\"')
            chJson .= '{"idx":' . c["idx"]
                . ',"ptr":"' . Format("0x{:X}", c["ptr"]) . '"'
                . ',"stringId":"' . sid . '"'
                . ',"isVisible":' . (c["isVisible"] ? "true" : "false")
                . ',"childCount":' . c["childCount"] . '}'
        }
        chJson .= "]"

        ; Index path (root → element) like [1, 41, 1]
        idxPath := UiTree_GetIndexPath(g_reader, g_uiBrowserRootPtr, g_uiBrowserCurrentPtr)
        ipJson := "["
        for i, ix in idxPath {
            if (i > 1)
                ipJson .= ","
            ipJson .= ix
        }
        ipJson .= "]"

        ; Compute Screen Pos and per-axis scale factors (need game window size)
        gwW := 0, gwH := 0
        try {
            gameHwnd := ResolvePoEWindow()
            if gameHwnd
                WinGetPos(, , &gwW, &gwH, "ahk_id " gameHwnd)
        }
        screenPosX := 0.0, screenPosY := 0.0
        try {
            sp := UiTree_GetScreenPos(g_reader, g_uiBrowserCurrentPtr)
            screenPosX := sp["x"]
            screenPosY := sp["y"]
        }
        ; Computed scale based on Scale Index. PoE2 design res = 2560x1600.
        sf := (gwH > 0) ? (gwH / 1600.0) : 1.0
        sfX := (gwW > 0) ? (gwW / 2560.0) : 1.0
        scIdx := elem["scaleIndex"]
        if (scIdx = 1)
            cs := sfX, csY := sfX, scLabel := "Width/Width"
        else if (scIdx = 2)
            cs := sf,  csY := sf,  scLabel := "Height/Height"
        else if (scIdx = 3)
            cs := sfX, csY := sf,  scLabel := "Width/Height"
        else
            cs := 1.0, csY := 1.0, scLabel := "None"

        screenSizeW := elem["sizeW"] * cs
        screenSizeH := elem["sizeH"] * csY
        ; Screen Pos in pixels = computed UI-space pos * height-scale (matches game projection)
        screenPxX := screenPosX * sf
        screenPxY := screenPosY * sf

        ; Build props JSON — use _UibF() for floats to avoid locale-specific decimal comma
        sid := StrReplace(elem["stringId"], "\", "\\")
        sid := StrReplace(sid, '"', '\"')
        fnt := StrReplace(elem["fontName"], "\", "\\")
        fnt := StrReplace(fnt, '"', '\"')
        scLabelJ := StrReplace(scLabel, '"', '\"')
        propsJson := '{'
            . '"address":"' . Format("0x{:X}", g_uiBrowserCurrentPtr) . '"'
            . ',"stringId":"' . sid . '"'
            . ',"fontName":"' . fnt . '"'
            . ',"isVisible":' . (elem["isVisible"] ? "true" : "false")
            . ',"shouldModifyPos":' . (elem["shouldModifyPos"] ? "true" : "false")
            . ',"childCount":' . elem["childCount"]
            . ',"flags":"' . Format("0x{:08X}", elem["flags"]) . '"'
            . ',"relX":' . _UibF(elem["relX"], 2)
            . ',"relY":' . _UibF(elem["relY"], 2)
            . ',"posModX":' . _UibF(elem["posModX"], 2)
            . ',"posModY":' . _UibF(elem["posModY"], 2)
            . ',"unscaledPosX":' . _UibF(screenPosX, 2)
            . ',"unscaledPosY":' . _UibF(screenPosY, 2)
            . ',"screenPosX":' . _UibF(screenPxX, 2)
            . ',"screenPosY":' . _UibF(screenPxY, 2)
            . ',"sizeW":' . _UibF(elem["sizeW"], 1)
            . ',"sizeH":' . _UibF(elem["sizeH"], 1)
            . ',"screenSizeW":' . _UibF(screenSizeW, 1)
            . ',"screenSizeH":' . _UibF(screenSizeH, 1)
            . ',"scaleIndex":' . scIdx
            . ',"scaleLabel":"' . scLabelJ . '"'
            . ',"computedScaleW":' . _UibF(cs, 4)
            . ',"computedScaleH":' . _UibF(csY, 4)
            . ',"localMult":' . _UibF(elem["localMult"], 4)
            . ',"vtable":"' . Format("0x{:X}", elem["vtable"]) . '"'
            . ',"parentPtr":"' . Format("0x{:X}", elem["parentPtr"]) . '"'
            . ',"bgColor":"' . Format("0x{:08X}", elem["bgColor"]) . '"'
            . '}'

        payload := '{'
            . '"breadcrumb":' . bcJson
            . ',"indexPath":' . ipJson
            . ',"children":' . chJson
            . ',"props":' . propsJson
            . ',"canBack":' . (g_uiBrowserHistory.Length > 0 ? "true" : "false")
            . ',"isRoot":' . (g_uiBrowserCurrentPtr = g_uiBrowserRootPtr ? "true" : "false")
            . '}'

        ; Update overlay highlight BEFORE WebViewExec so outer catch can't clear it.
        try {
            pos := UiTree_GetScreenPos(g_reader, g_uiBrowserCurrentPtr)
            g_uiBrowserHighlight := Map("x", pos["x"], "y", pos["y"],
                                        "w", elem["sizeW"], "h", elem["sizeH"])
        } catch {
            g_uiBrowserHighlight := 0
        }

        WebViewExec("updateUiBrowser(" . _JsStr(payload) . ")")
    } catch as ex {
        ; Don't clear g_uiBrowserHighlight — it was set successfully above; only the
        ; WebView push failed, which is independent of the overlay highlight state.
        WebViewExec("updateUiBrowser(" . _JsStr('{"error":"Exception in PushUiBrowserState: ' . ex.Message . '"}') . ")")
    }
}

; Clears the UI Browser overlay highlight (call when leaving the UI tab).
UiBrowserClearHighlight()
{
    global g_uiBrowserHighlight
    g_uiBrowserHighlight := 0
}
