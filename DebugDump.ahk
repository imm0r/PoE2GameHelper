; DebugDump.ahk
; F3 debug dump functionality: TreeView JSON export, game window screenshots,
; and radar entity diagnostic TSV output.
;
; Included by InGameStateMonitor.ahk

; Recursively walks a TreeView control and builds a JSON array of node objects.
; Each node: {"text": "...", "children": [...]}
_DumpTreeNodeRecursiveJson(ctrl, hwnd, nodeId)
{
    items := []
    while (nodeId != 0)
    {
        label := ctrl.GetText(nodeId)
        ; Escape JSON-special characters
        escaped := StrReplace(label, "\", "\\")
        escaped := StrReplace(escaped, '"', '\"')
        escaped := StrReplace(escaped, "`n", "\n")
        escaped := StrReplace(escaped, "`r", "\r")
        escaped := StrReplace(escaped, "`t", "\t")

        child := TV_GetChild(hwnd, nodeId)
        if child
        {
            childJson := _DumpTreeNodeRecursiveJson(ctrl, hwnd, child)
            items.Push('{"text":"' escaped '","children":' childJson '}')
        }
        else
            items.Push('{"text":"' escaped '"}')

        nodeId := TV_GetNext(hwnd, nodeId)
    }
    joined := ""
    for i, item in items
        joined .= (i > 1 ? "," : "") item
    return "[" joined "]"
}

; Dumps the content of every TreeView tab to debug\treeview_dump_<timestamp>.json.
; Returns: path of the created file, or "" on error.
DumpTreeViewContent()
{
    global g_treeControlsByTab, g_treeTabKeys

    outDir  := A_ScriptDir "\debug"
    if !DirExist(outDir)
        DirCreate(outDir)
    ts      := FormatTime(A_Now, "yyyyMMdd_HHmmss")
    outPath := outDir "\treeview_dump_" ts ".json"

    ; Build JSON object: {"timestamp": "...", "tabs": {"tabKey": [...]}}
    tabsJson := ""
    first := true
    for _, tabKey in g_treeTabKeys
    {
        if !g_treeControlsByTab.Has(tabKey)
            continue
        ctrl := g_treeControlsByTab[tabKey]
        hwnd  := ctrl.Hwnd
        root  := TV_GetRoot(hwnd)
        nodes := root ? _DumpTreeNodeRecursiveJson(ctrl, hwnd, root) : "[]"

        escapedKey := StrReplace(tabKey, '"', '\"')
        tabsJson .= (first ? "" : ",") '"' escapedKey '"' ":" nodes
        first := false
    }

    ts_display := FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")
    json := '{"timestamp":"' ts_display '","tabs":{' tabsJson '}}'

    try
    {
        FileAppend(json, outPath, "UTF-8")
        return outPath
    }
    catch
        return ""
}

; Captures a screenshot of the PoE2 game window (or the primary monitor as fallback)
; and saves it to debug\screenshot_<timestamp>.png.
; Returns: path of the created file, or "" on error.
CaptureGameWindowScreenshot()
{
    outDir  := A_ScriptDir "\debug"
    if !DirExist(outDir)
        DirCreate(outDir)
    ts      := FormatTime(A_Now, "yyyyMMdd_HHmmss")
    outPath := outDir "\screenshot_" ts ".png"

    ; Find the PoE2 window
    gameHwnd := WinExist("ahk_exe PathOfExileSteam.exe")
    if !gameHwnd
        gameHwnd := WinExist("ahk_exe PathOfExile.exe")

    if gameHwnd
    {
        WinGetPos(&gwX, &gwY, &gwW, &gwH, "ahk_id " gameHwnd)
        if (gwW > 0 && gwH > 0)
        {
            x := gwX, y := gwY, w := gwW, h := gwH
        }
        else
        {
            x := 0, y := 0, w := A_ScreenWidth, h := A_ScreenHeight
        }
    }
    else
    {
        x := 0, y := 0, w := A_ScreenWidth, h := A_ScreenHeight
    }

    ; Use GDI+ to capture the screen region
    pToken := 0
    DllCall("LoadLibrary", "Str", "gdiplus")
    si := Buffer(24, 0)
    NumPut("UInt", 1, si, 0)
    DllCall("gdiplus\GdiplusStartup", "Ptr*", &pToken, "Ptr", si, "Ptr", 0)

    hDC     := DllCall("GetDC", "Ptr", 0, "Ptr")
    hMemDC  := DllCall("CreateCompatibleDC", "Ptr", hDC, "Ptr")
    hBitmap := DllCall("CreateCompatibleBitmap", "Ptr", hDC, "Int", w, "Int", h, "Ptr")
    DllCall("SelectObject", "Ptr", hMemDC, "Ptr", hBitmap)
    DllCall("BitBlt", "Ptr", hMemDC, "Int", 0, "Int", 0, "Int", w, "Int", h,
            "Ptr", hDC, "Int", x, "Int", y, "UInt", 0x00CC0020)  ; SRCCOPY

    ; Encode to PNG via GDI+
    pBitmap := 0
    DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", hBitmap, "Ptr", 0, "Ptr*", &pBitmap)

    pngClsid := Buffer(16, 0)
    _GetEncoderClsid("image/png", pngClsid)
    DllCall("gdiplus\GdipSaveImageToFile", "Ptr", pBitmap, "WStr", outPath, "Ptr", pngClsid, "Ptr", 0)

    DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
    DllCall("gdiplus\GdiplusShutdown", "Ptr", pToken)
    DllCall("DeleteObject", "Ptr", hBitmap)
    DllCall("DeleteDC", "Ptr", hMemDC)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hDC)

    return FileExist(outPath) ? outPath : ""
}

; Retrieves the CLSID of a GDI+ image encoder by MIME type into the given buffer.
_GetEncoderClsid(mimeType, clsidBuf)
{
    numEncoders := 0
    size := 0
    DllCall("gdiplus\GdipGetImageEncodersSize", "UInt*", &numEncoders, "UInt*", &size)
    if (size = 0)
        return -1

    buf := Buffer(size, 0)
    DllCall("gdiplus\GdipGetImageEncoders", "UInt", numEncoders, "UInt", size, "Ptr", buf)

    ; Each ImageCodecInfo struct is 104 bytes on x64
    loop numEncoders
    {
        offset := (A_Index - 1) * 104
        mimePtr := NumGet(buf, offset + 64, "Ptr")
        mime    := StrGet(mimePtr, "UTF-16")
        if (mime = mimeType)
        {
            DllCall("RtlCopyMemory", "Ptr", clsidBuf, "Ptr", buf.Ptr + offset, "Ptr", 16)
            return A_Index - 1
        }
    }
    return -1
}

; F3 handler: dumps TreeView, captures a game screenshot, then dumps the radar entity TSV.
OnF3DebugDump()
{
    global g_reader, g_radarLastSnap

    debugDir := A_ScriptDir "\debug"
    if !DirExist(debugDir)
        DirCreate(debugDir)

    tvPath := DumpTreeViewContent()
    ssPath := CaptureGameWindowScreenshot()

    ; Radar entity TSV — use cached snapshot or read a fresh one
    tsvPath := ""
    if IsObject(g_reader)
    {
        snap := IsObject(g_radarLastSnap) ? g_radarLastSnap : 0
        if !snap
        {
            try snap := g_reader.ReadRadarSnapshot()
        }
        if snap
            tsvPath := g_reader.DumpRadarEntityDebug(snap, debugDir)
    }

    msg := "F3 Debug Dump:`n"
        . (tvPath  ? "  TreeView : " tvPath  "`n" : "  TreeView : FAILED`n")
        . (ssPath  ? "  Screenshot: " ssPath "`n" : "  Screenshot: FAILED`n")
        . (tsvPath ? "  Radar TSV : " tsvPath     : "  Radar TSV : FAILED (no snapshot?)")
    ToolTip(msg)
    SetTimer(() => ToolTip(), -4000)
}

; Dumps diagnostic info for all visible radar entities to a TSV file.
OnDumpEntitiesClicked(*)
{
    global g_reader, g_radarLastSnap
    if !IsObject(g_reader)
    {
        MsgBox("Reader not initialised.", "Dump Entities", 0x10)
        return
    }
    snap := IsObject(g_radarLastSnap) ? g_radarLastSnap : 0
    if !snap
    {
        MsgBox("No radar snapshot available yet. Wait for the game to load.", "Dump Entities", 0x10)
        return
    }
    outPath := g_reader.DumpRadarEntityDebug(snap)
    if outPath
        MsgBox("Exported to:`n" outPath, "Dump Entities", 0x40)
    else
        MsgBox("Export failed (no entities or write error).", "Dump Entities", 0x10)
}
