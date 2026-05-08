; UiBrowserHandler.ahk

global g_uiBrowserCurrentPtr := 0
global g_uiBrowserHistory := []
global g_uiBrowserRootPtr := 0

MsgBox("UIBrowserHandler wurde geladen!")

UiBrowseRoot()
{
    global g_uiBrowserCurrentPtr, g_uiBrowserHistory, g_uiBrowserRootPtr, g_reader
    msg := ""
    if !IsObject(g_reader)
        msg := "DIAG1"
    else if !g_reader.Mem.Handle
        msg := "DIAG2"
    if (msg != "") {
        WebViewExec("updateUiBrowser(" . Chr(34) . "{" . Chr(92) . Chr(34) . "error" . Chr(92) . Chr(34) . ":" . Chr(92) . Chr(34) . msg . Chr(92) . Chr(34) . "}" . Chr(34) . ")")
        return
    }
    igs := g_reader._radarInGameStateCache
    if !g_reader.IsProbablyValidPointer(igs) {
        try g_reader.Connect()
        igs := g_reader._radarInGameStateCache
    }
    if !g_reader.IsProbablyValidPointer(igs) {
        if g_reader.IsProbablyValidPointer(g_reader.GameStatesAddress) {
            staticPtr := g_reader.Mem.ReadPtr(g_reader.GameStatesAddress)
            if g_reader.IsProbablyValidPointer(staticPtr) {
                base := staticPtr + PoE2Offsets.GameState["States"]
                igs := g_reader.Mem.ReadPtr(base + (4 * PoE2Offsets.GameState["StateEntrySize"]))
            }
        }
    }
    if !g_reader.IsProbablyValidPointer(igs) {
        _UibErr("DIAG3: no InGameState")
        return
    }
    uiRoot := g_reader.Mem.ReadPtr(igs + PoE2Offsets.InGameState["UiRootStructPtr"])
    if !g_reader.IsProbablyValidPointer(uiRoot) {
        _UibErr("DIAG6: bad UiRootStructPtr")
        return
    }
    gameUiPtr := g_reader.Mem.ReadPtr(uiRoot + PoE2Offsets.UiRootStruct["GameUiPtr"])
    if !g_reader.IsProbablyValidPointer(gameUiPtr)
        gameUiPtr := g_reader.Mem.ReadPtr(uiRoot + PoE2Offsets.UiRootStruct["GameUiControllerPtr"])
    if !g_reader.IsProbablyValidPointer(gameUiPtr) {
        _UibErr("DIAG7: bad GameUiPtr")
        return
    }
    g_uiBrowserRootPtr := gameUiPtr
    g_uiBrowserCurrentPtr := gameUiPtr
    g_uiBrowserHistory := []
    PushUiBrowserState()
}

_UibErr(msg)
{
    j := Chr(34) . "{" . Chr(92) . Chr(34) . "error" . Chr(92) . Chr(34) . ":" . Chr(92) . Chr(34) . msg . Chr(92) . Chr(34) . "}" . Chr(34)
    WebViewExec("updateUiBrowser(" . j . ")")
}

UiBrowseParent()
{
    global g_uiBrowserCurrentPtr, g_uiBrowserHistory, g_reader, g_uiBrowserRootPtr
    if !IsObject(g_reader) || !g_reader.IsProbablyValidPointer(g_uiBrowserCurrentPtr)
        return
    if (g_uiBrowserCurrentPtr = g_uiBrowserRootPtr)
        return
    try {
        p := g_reader.Mem.ReadPtr(g_uiBrowserCurrentPtr + PoE2Offsets.UiElementBase["ParentPtr"])
        if !g_reader.IsProbablyValidPointer(p)
            return
        g_uiBrowserHistory.Push(g_uiBrowserCurrentPtr)
        if (g_uiBrowserHistory.Length > 64)
            g_uiBrowserHistory.RemoveAt(1)
        g_uiBrowserCurrentPtr := p
        PushUiBrowserState()
    } catch {

    }
}

UiBrowseChild(childIndex)
{
    global g_uiBrowserCurrentPtr, g_uiBrowserHistory, g_reader
    if !IsObject(g_reader) || !g_reader.IsProbablyValidPointer(g_uiBrowserCurrentPtr)
        return
    cp := UiTree_GetChildByIndex(g_reader, g_uiBrowserCurrentPtr, Integer(childIndex))
    if !g_reader.IsProbablyValidPointer(cp)
        return
    g_uiBrowserHistory.Push(g_uiBrowserCurrentPtr)
    if (g_uiBrowserHistory.Length > 64)
        g_uiBrowserHistory.RemoveAt(1)
    g_uiBrowserCurrentPtr := cp
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
        cf := elem["childFirst"]
        cl := elem["childLast"]
        if (g_reader.IsProbablyValidPointer(cf) && cl > cf) {
            n := Min((cl - cf) // A_PtrSize, 256)
            buf := g_reader.Mem.ReadBytes(cf, n * A_PtrSize)
            if buf {
                Loop n {
                    cp := NumGet(buf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
                    if (g_reader.IsProbablyValidPointer(cp) && !visited.Has(cp))
                        queue.Push(cp)
                }
            }
        }
    }
    rows := _UibJsonArray(results)
    qe := StrReplace(StrReplace(query, "\", "\\"), Chr(34), "\" . Chr(34))
    WebViewExec("updateUiBrowserSearch(" . rows . "," . Chr(34) . qe . Chr(34) . ")")
}

_UibEsc(s)
{
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, Chr(34), "\" . Chr(34))
    return s
}

_UibQ(s)
{
    return Chr(34) . _UibEsc(s) . Chr(34)
}

_UibJsonArray(results)
{
    rows := "["
    first := true
    for _, r in results {
        if !first
            rows .= ","
        first := false
        rows .= "{" . _UibQ("ptr") . ":" . _UibQ(Format("0x{:X}", r["ptr"]))
            . "," . _UibQ("stringId") . ":" . _UibQ(r["stringId"])
            . "," . _UibQ("isVisible") . ":" . (r["isVisible"] ? "true" : "false") . "}"
    }
    rows .= "]"
    return rows
}

PushUiBrowserState()
{
    global g_uiBrowserCurrentPtr, g_uiBrowserHistory, g_uiBrowserRootPtr, g_reader
    if !IsObject(g_reader)
        return
    if !g_reader.IsProbablyValidPointer(g_uiBrowserCurrentPtr) {
        UiBrowseRoot()
        return
    }
    elem := UiTree_ReadElement(g_reader, g_uiBrowserCurrentPtr)
    if !elem {
        _UibErr("Element not readable")
        return
    }
    breadcrumb := []
    curPtr := g_uiBrowserCurrentPtr
    Loop 16 {
        if !g_reader.IsProbablyValidPointer(curPtr)
            break
        e := UiTree_ReadElement(g_reader, curPtr)
        if !e
            break
        breadcrumb.InsertAt(1, Map("ptr", curPtr, "stringId", e["stringId"]))
        pp := e["parentPtr"]
        if (!g_reader.IsProbablyValidPointer(pp) || pp = curPtr)
            break
        if (curPtr = g_uiBrowserRootPtr)
            break
        curPtr := pp
    }
    children := []
    cf := elem["childFirst"]
    cl := elem["childLast"]
    cc := elem["childCount"]
    if (g_reader.IsProbablyValidPointer(cf) && cl > cf && cc > 0) {
        n := Min(cc, 256)
        buf := g_reader.Mem.ReadBytes(cf, n * A_PtrSize)
        if buf {
            Loop n {
                cp := NumGet(buf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
                if !g_reader.IsProbablyValidPointer(cp)
                    continue
                ce := UiTree_ReadElement(g_reader, cp)
                children.Push(Map("idx", A_Index - 1, "ptr", cp,
                    "stringId", ce ? ce["stringId"] : "",
                    "isVisible", ce ? ce["isVisible"] : false,
                    "childCount", ce ? ce["childCount"] : 0))
            }
        }
    }
    bcJson := "["
    first := true
    for _, b in breadcrumb {
        if !first bcJson .= ","
            first := false
        bcJson .= "{" . _UibQ("ptr") . ":" . _UibQ(Format("0x{:X}", b["ptr"]))
            . "," . _UibQ("stringId") . ":" . _UibQ(b["stringId"]) . "}"
    }
    bcJson .= "]"
    chJson := "["
    first := true
    for _, c in children {
        if !first chJson .= ","
            first := false
        chJson .= "{" . _UibQ("idx") . ":" . c["idx"]
            . "," . _UibQ("ptr") . ":" . _UibQ(Format("0x{:X}", c["ptr"]))
            . "," . _UibQ("stringId") . ":" . _UibQ(c["stringId"])
            . "," . _UibQ("isVisible") . ":" . (c["isVisible"] ? "true" : "false")
            . "," . _UibQ("childCount") . ":" . c["childCount"] . "}"
    }
    chJson .= "]"
    props := "{" . _UibQ("address") . ":" . _UibQ(Format("0x{:X}", g_uiBrowserCurrentPtr))
        . "," . _UibQ("stringId") . ":" . _UibQ(elem["stringId"])
        . "," . _UibQ("isVisible") . ":" . (elem["isVisible"] ? "true" : "false")
        . "," . _UibQ("childCount") . ":" . elem["childCount"]
        . "," . _UibQ("flags") . ":" . _UibQ(Format("0x{:08X}", elem["flags"]))
        . "," . _UibQ("relX") . ":" . Round(elem["relX"], 2)
        . "," . _UibQ("relY") . ":" . Round(elem["relY"], 2)
        . "," . _UibQ("sizeW") . ":" . Round(elem["sizeW"], 1)
        . "," . _UibQ("sizeH") . ":" . Round(elem["sizeH"], 1)
        . "," . _UibQ("scaleIndex") . ":" . elem["scaleIndex"]
        . "," . _UibQ("localMult") . ":" . Round(elem["localMult"], 4)
        . "," . _UibQ("vtable") . ":" . _UibQ(Format("0x{:X}", elem["vtable"]))
        . "," . _UibQ("parentPtr") . ":" . _UibQ(Format("0x{:X}", elem["parentPtr"])) . "}"
    payload := "{" . _UibQ("breadcrumb") . ":" . bcJson
        . "," . _UibQ("children") . ":" . chJson
        . "," . _UibQ("props") . ":" . props
        . "," . _UibQ("canBack") . ":" . (g_uiBrowserHistory.Length > 0 ? "true" : "false")
        . "," . _UibQ("isRoot") . ":" . (g_uiBrowserCurrentPtr = g_uiBrowserRootPtr ? "true" : "false") . "}"
    WebViewExec("updateUiBrowser(" . _JsStr(payload) . ")")
}