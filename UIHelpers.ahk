; UIHelpers.ahk
; UI helper functions for the InGameState monitor.
;
; Contains: OnApplyThresholdClick, ApplyThresholdsFromUI, ParseThresholdPercent, SafePercent,
; ShouldHideNode, FormatScalar, IsAddressLikeField, BuildHotkeyLegendText,
; UpdateActionButtonLabels, Toggle*Mode functions
;
; Included by InGameStateMonitor.ahk

; Click handler for the Apply Threshold button; delegates to ApplyThresholdsFromUI.
OnApplyThresholdClick(*)
{
    ApplyThresholdsFromUI()
}

; Applies life/mana thresholds from provided values and triggers a UI refresh.
ApplyThresholdsFromUI(lifeRaw := "", manaRaw := "")
{
    global lifeThresholdPercent, manaThresholdPercent

    if (lifeRaw != "")
        lifeThresholdPercent := ParseThresholdPercent(lifeRaw, lifeThresholdPercent)
    if (manaRaw != "")
        manaThresholdPercent := ParseThresholdPercent(manaRaw, manaThresholdPercent)

    SaveConfig()
    ReadAndShow()
}

; Parses a percentage string from a UI input field and clamps the result to [1, 100].
; Params: raw - raw string value from the edit control; fallback - returned when parsing fails
; Returns: integer percentage in [1, 100]
ParseThresholdPercent(raw, fallback)
{
    text := Trim(raw)
    if !RegExMatch(text, "^-?\d+$")
        return fallback

    val := Integer(text)
    if (val < 1)
        val := 1
    if (val > 100)
        val := 100
    return val
}

; Returns (current / max) * 100 as a float, or -1 if max is zero to avoid division by zero.
SafePercent(current, max)
{
    if (max <= 0)
        return -1
    return (current * 100.0) / max
}

; Returns true if the given tree node should be suppressed from the display.
; Hides noise nodes such as patternScanReport, inventory ID lists, and duplicate vitals paths.
ShouldHideNode(nodePath, name)
{
    pathLower := StrLower(nodePath)
    nameLower := StrLower(name)

    if (nameLower = "patternscanreport")
        return true

    if (nameLower = "inventoryidsseen" || nameLower = "flaskinventoryselectreason")
        return true

    if InStr(pathLower, "/patternscanreport")
        return true

    ; Legacy-Compat: Vitaldaten nur einmal anzeigen (top-level vitalStruct unter areaInstance).
    if (pathLower = "snapshot/ingamestate/areainstance/playervitals")
        return true
    if (pathLower = "snapshot/ingamestate/areainstance/playerstruct/playervitals")
        return true
    if (pathLower = "snapshot/ingamestate/areainstance/playerstruct/vitalstruct")
        return true

    return false
}

; Formats a raw memory value for TreeView display; renders large integers and address-like fields as hex.
; Params: fieldName - optional field name hint; nodePath - optional path used by the address heuristic
FormatScalar(value, fieldName := "", nodePath := "")
{
    valueType := Type(value)

    if (valueType = "String")
        return value

    if (valueType = "Integer")
    {
        if (value > 0x10000 || IsAddressLikeField(fieldName, nodePath))
            return PoE2GameStateReader.Hex(value)
        return value
    }

    if (valueType = "Float")
        return value

    if (valueType = "Buffer")
        return "<Buffer size=" value.Size ">"

    return value
}

; Heuristic: returns true if the field name or path suggests the value is a memory pointer or address.
IsAddressLikeField(fieldName, nodePath := "")
{
    nameLower := StrLower(Trim(fieldName))
    pathLower := StrLower(Trim(nodePath))

    if (nameLower != "")
    {
        if (InStr(nameLower, "address") || InStr(nameLower, "addr") || InStr(nameLower, "ptr") || InStr(nameLower, "pointer"))
            return true
    }

    if (pathLower != "")
    {
        if (InStr(pathLower, "/address") || InStr(pathLower, "address/") || InStr(pathLower, "/ptr") || InStr(pathLower, "ptr/"))
            return true
    }

    return false
}

; Builds the hotkey legend string shown in the status row, reflecting all current toggle states.
; Returns: formatted legend string with Debug/Updates/AutoFlask/AF Perf/Tree/TreeMode/Pinned status
BuildHotkeyLegendText()
{
    global debugMode, updatesPaused, autoFlaskEnabled, autoFlaskPerformanceMode, pinnedNodePaths, showTreePane, activeTreeTabKey

    return (
        "Buttons: "
        . "Debug(" (debugMode ? "ON" : "OFF") ") | "
        . "Updates(" (updatesPaused ? "PAUSED" : "LIVE") ") | "
        . "AutoFlask(" (autoFlaskEnabled ? "ON" : "OFF") ") | "
        . "AFPerf(" (autoFlaskPerformanceMode ? "ON" : "OFF") ") | "
        . "Tree(" (showTreePane ? "ON" : "OFF") ") | "
        . "TreeMode(MANUAL:" activeTreeTabKey ") | "
        . "Pinned(" pinnedNodePaths.Length ")"
    )
}

; Pushes the current toggle states to the WebView header area.
UpdateActionButtonLabels()
{
    PushHeaderToWebView()
}

OnDebugButtonClick(*) => ToggleDebugMode()
OnPauseButtonClick(*) => ToggleUpdatesPause()
OnAutoFlaskButtonClick(*) => ToggleAutoFlaskMode()
OnAutoFlaskPerfButtonClick(*) => ToggleAutoFlaskPerformanceMode()
OnPinSelectedButtonClick(*) => PinSelectedTreeNodePath()
OnWatchNearbyNpcButtonClick(*) => AddNearbyNpcScannerToWatchlist()
OnTreeToggleButtonClick(*) => ToggleTreePaneVisibility()
OnTreeSnapButtonClick(*) => ForceRefreshActiveTree()
OnClearPinsButtonClick(*) => ClearPinnedNodePaths()

OnOffsetSearchChanged(*) => RefreshOffsetTableView()
OnRemovePinnedSelectedClick(*) => RemoveSelectedPinnedFromTable()

; No-op: radar filter state is now set directly via the JS bridge (SetRadarFilter).
OnRadarFilterChanged(*)
{
}

; Dumps diagnostic info for all currently visible radar entities to data\radar_entity_debug_*.tsv.
; Use this to investigate ghost entities — the file shows raw targetable byte, HP, isAlive, etc.
OnDumpEntitiesClicked(*)
{
    global reader, g_radarLastSnap
    if !IsObject(reader)
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
    outPath := reader.DumpRadarEntityDebug(snap)
    if outPath
        MsgBox("Exported to:`n" outPath, "Dump Entities", 0x40)
    else
        MsgBox("Export failed (no entities or write error).", "Dump Entities", 0x10)
}

; Toggles the debugMode flag and triggers a full UI refresh.
ToggleDebugMode()
{
    global debugMode
    debugMode := !debugMode
    SaveConfig()
    ReadAndShow()
}

; Toggles the updatesPaused flag; updates the tree root label when pausing, or resumes live updates.
ToggleUpdatesPause()
{
    global updatesPaused, valueTree
    updatesPaused := !updatesPaused
    SaveConfig()
    if (updatesPaused)
    {
        if valueTree
        {
            root := TV_GetRoot(valueTree.Hwnd)
            if (root)
                valueTree.Modify(root, , RegExReplace(valueTree.GetText(root), "Updates:\s+(PAUSED|LIVE)", "Updates: PAUSED"))
        }
    }
    else
    {
        ReadAndShow()
        return
    }

    ReadAndShow()
}

; Toggles the autoFlaskEnabled flag and triggers a full UI refresh.
ToggleAutoFlaskMode()
{
    global autoFlaskEnabled
    autoFlaskEnabled := !autoFlaskEnabled
    SaveConfig()
    ReadAndShow()
}

; Toggles autoFlaskPerformanceMode (skips full snapshot reads in the main loop) and triggers a refresh.
ToggleAutoFlaskPerformanceMode()
{
    global autoFlaskPerformanceMode
    autoFlaskPerformanceMode := !autoFlaskPerformanceMode
    SaveConfig()
    ReadAndShow()
}

ToggleRadar()
{
    global g_radarEnabled, g_radarOverlay
    g_radarEnabled := !g_radarEnabled
    if (!g_radarEnabled && g_radarOverlay)
        g_radarOverlay.Hide()
    SaveConfig()
    PushHeaderToWebView()
}

_ApplyEntityFilter(etype, bval)
{
    global entityShowPlayer, entityShowMinion, entityShowEnemy
    global entityShowNPC, entityShowChest, entityShowWorldItem, entityShowOther
    switch etype
    {
        case "player":    entityShowPlayer    := bval
        case "minion":    entityShowMinion    := bval
        case "enemy":     entityShowEnemy     := bval
        case "npc":       entityShowNPC       := bval
        case "chest":     entityShowChest     := bval
        case "worlditem": entityShowWorldItem := bval
        case "other":     entityShowOther     := bval
    }
    SaveConfig()
    PushHeaderToWebView()
}

; ─────────────────────────────────────────────────────────────────────────────
; F3 Debug-Dump: dumps TreeView, a game-window screenshot, and the radar TSV.
; ─────────────────────────────────────────────────────────────────────────────

; Recursively walks a TreeView control and builds a JSON array of node objects.
; Each node: {"text": "...", "children": [...]}
; Returns: JSON array string
_DumpTreeNodeRecursiveJson(ctrl, hwnd, nodeId)
{
    items := []
    while (nodeId != 0)
    {
        label := ctrl.GetText(nodeId)
        ; Escape JSON string
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
    ; Join items into JSON array
    joined := ""
    for i, item in items
        joined .= (i > 1 ? "," : "") item
    return "[" joined "]"
}

; Dumps the content of every TreeView tab to debug\treeview_dump_<timestamp>.json.
; Returns: path of the created file, or "" on error.
DumpTreeViewContent()
{
    global treeControlsByTab, treeTabKeys

    outDir  := A_ScriptDir "\debug"
    if !DirExist(outDir)
        DirCreate(outDir)
    ts      := FormatTime(A_Now, "yyyyMMdd_HHmmss")
    outPath := outDir "\treeview_dump_" ts ".json"

    ; Build JSON object: {"timestamp": "...", "tabs": {"tabKey": [...]}}
    tabsJson := ""
    first := true
    for _, tabKey in treeTabKeys
    {
        if !treeControlsByTab.Has(tabKey)
            continue
        ctrl := treeControlsByTab[tabKey]
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
        ; Bring game window to focus so BitBlt captures it correctly
        ; (do NOT activate — we just need its position)
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

    ; Capture from screen DC (hDC=0 = entire virtual screen)
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

    ; Each ImageCodecInfo struct is 76 bytes (x64 with packing considerations, but layout below is standard)
    loop numEncoders
    {
        offset := (A_Index - 1) * 104  ; sizeof ImageCodecInfo = 104 on x64
        mimePtr := NumGet(buf, offset + 64, "Ptr")   ; MimeType field offset
        mime    := StrGet(mimePtr, "UTF-16")
        if (mime = mimeType)
        {
            ; CLSID is at offset 0
            DllCall("RtlCopyMemory", "Ptr", clsidBuf, "Ptr", buf.Ptr + offset, "Ptr", 16)
            return A_Index - 1
        }
    }
    return -1
}

; F3 handler: dumps TreeView, captures a game screenshot, then dumps the radar entity TSV.
; All three files land in debug\ with matching timestamps.
OnF3DebugDump()
{
    global reader, g_radarLastSnap

    debugDir := A_ScriptDir "\debug"
    if !DirExist(debugDir)
        DirCreate(debugDir)

    ; 1) TreeView dump
    tvPath := DumpTreeViewContent()

    ; 2) Screenshot of game window
    ssPath := CaptureGameWindowScreenshot()

    ; 3) Radar entity TSV — use cached snapshot or read a fresh one
    tsvPath := ""
    if IsObject(reader)
    {
        snap := IsObject(g_radarLastSnap) ? g_radarLastSnap : 0
        if !snap
        {
            try snap := reader.ReadRadarSnapshot()
        }
        if snap
            tsvPath := reader.DumpRadarEntityDebug(snap, debugDir)
    }

    ; Show a brief non-blocking tooltip so the user knows the dump succeeded
    msg := "F3 Debug Dump:`n"
        . (tvPath  ? "  TreeView : " tvPath  "`n" : "  TreeView : FAILED`n")
        . (ssPath  ? "  Screenshot: " ssPath "`n" : "  Screenshot: FAILED`n")
        . (tsvPath ? "  Radar TSV : " tsvPath     : "  Radar TSV : FAILED (no snapshot?)")
    ToolTip(msg)
    SetTimer(() => ToolTip(), -4000)
}

; ─────────────────────────────────────────────────────────────────────────────
; WebView push helpers
; ─────────────────────────────────────────────────────────────────────────────

; Escapes a string for use as a JSON string literal (surrounded by double quotes).
_JsStr(s)
{
    s := StrReplace(s, "\",  "\\")
    s := StrReplace(s, '"',  '\"')
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`t", "\t")
    return '"' s '"'
}

; Executes arbitrary JS in the WebView. No-ops if the WebView is not ready.
WebViewExec(js)
{
    global webGui, g_webViewReady
    if !g_webViewReady
        return
    try webGui.Control.wv.ExecuteScriptAsync(js)
}

; Pushes the current toggle/config state as a JSON object to updateHeader() in the WebView.
PushHeaderToWebView()
{
    global debugMode, updatesPaused, autoFlaskEnabled, autoFlaskPerformanceMode
    global pinnedNodePaths, showTreePane, activeTreeTabKey, npcWatchAutoSync
    global lifeThresholdPercent, manaThresholdPercent
    global radarShowEnemyNormal, radarShowEnemyRare, radarShowEnemyBoss
    global radarShowMinions, radarShowNpcs, radarShowChests
    global autoFlaskLastReason, flaskKeyBySlot, reader, g_radarEnabled, webGui
    global GAMEHELPER_VERSION
    global entityShowPlayer, entityShowMinion, entityShowEnemy
    global entityShowNPC, entityShowChest, entityShowWorldItem, entityShowOther
    global g_zoneNavEnabled

    poeRunning := (ProcessExist("PathOfExileSteam.exe") || ProcessExist("PathOfExile.exe")) ? "true" : "false"
    slot1Key := flaskKeyBySlot.Has(1) ? flaskKeyBySlot[1] : "?"
    slot2Key := flaskKeyBySlot.Has(2) ? flaskKeyBySlot[2] : "?"
    connected := (IsObject(reader) && IsObject(reader.Mem) && reader.Mem.Handle) ? "true" : "false"
    gameVer := GetLastKnownPoeVersion()
    isMaximized := (WinGetMinMax("ahk_id " webGui.Hwnd) = 1) ? "true" : "false"

    json := "{"
          . '"connected":'      connected                ","
          . '"debug":'          (debugMode              ? "true" : "false") ","
          . '"paused":'         (updatesPaused          ? "true" : "false") ","
          . '"autoFlask":'      (autoFlaskEnabled        ? "true" : "false") ","
          . '"afPerf":'         (autoFlaskPerformanceMode ? "true" : "false") ","
          . '"showTree":'       (showTreePane            ? "true" : "false") ","
          . '"npcSync":'        (npcWatchAutoSync        ? "true" : "false") ","
          . '"poeRunning":'     poeRunning               ","
          . '"lifeThreshold":'  lifeThresholdPercent     ","
          . '"manaThreshold":'  manaThresholdPercent     ","
          . '"pinnedCount":'    pinnedNodePaths.Length   ","
          . '"activeTab":'      _JsStr(activeTreeTabKey) ","
          . '"afReason":'       _JsStr(autoFlaskLastReason) ","
          . '"afSlot1Key":'     _JsStr(slot1Key) ","
          . '"afSlot2Key":'     _JsStr(slot2Key) ","
          . '"ghVersion":'      _JsStr(GAMEHELPER_VERSION) ","
          . '"gameVersion":'    _JsStr(gameVer) ","
          . '"radarEnabled":'   (g_radarEnabled ? "true" : "false") ","
          . '"isMaximized":'    isMaximized ","
          . '"entityFilter":{'
          . '"player":'    (entityShowPlayer    ? "true" : "false") ","
          . '"minion":'    (entityShowMinion    ? "true" : "false") ","
          . '"enemy":'     (entityShowEnemy     ? "true" : "false") ","
          . '"npc":'       (entityShowNPC       ? "true" : "false") ","
          . '"chest":'     (entityShowChest     ? "true" : "false") ","
          . '"worlditem":' (entityShowWorldItem ? "true" : "false") ","
          . '"other":'     (entityShowOther     ? "true" : "false")
          . "},"
          . '"radar":{'
          . '"normal":'  (radarShowEnemyNormal ? "true" : "false") ","
          . '"rare":'    (radarShowEnemyRare   ? "true" : "false") ","
          . '"boss":'    (radarShowEnemyBoss   ? "true" : "false") ","
          . '"minions":' (radarShowMinions     ? "true" : "false") ","
          . '"npcs":'    (radarShowNpcs        ? "true" : "false") ","
          . '"chests":'  (radarShowChests      ? "true" : "false")
          . "},"
          . '"zoneNav":' (g_zoneNavEnabled ? "true" : "false") ","
          . '"mapHack":' (g_mapHackEnabled ? "true" : "false")
          . "}"
    WebViewExec("updateHeader(" json ")")
}

; Serialises the active TreeView and pushes it to updateTree() in the WebView.
PushActiveTreeToWebView()
{
    global activeTreeTabKey, treeControlsByTab, treeNodePathsByTab

    if !treeControlsByTab.Has(activeTreeTabKey)
        return

    ctrl := treeControlsByTab[activeTreeTabKey]
    hwnd := ctrl.Hwnd
    root := TV_GetRoot(hwnd)
    nodePathsMap := treeNodePathsByTab.Has(activeTreeTabKey) ? treeNodePathsByTab[activeTreeTabKey] : Map()
    nodesJson := root ? _DumpTreeNodeRecursiveJsonEx(ctrl, hwnd, root, nodePathsMap) : "[]"

    WebViewExec("updateTree(" _JsStr(activeTreeTabKey) "," nodesJson ")")
}

; Recursive tree serialiser that also embeds the node path (from nodePathsMap) when available.
_DumpTreeNodeRecursiveJsonEx(ctrl, hwnd, nodeId, nodePathsMap)
{
    items := []
    while (nodeId != 0)
    {
        label := ctrl.GetText(nodeId)
        escaped := StrReplace(label, "\",  "\\")
        escaped := StrReplace(escaped, '"',  '\"')
        escaped := StrReplace(escaped, "`n", "\n")
        escaped := StrReplace(escaped, "`r", "\r")
        escaped := StrReplace(escaped, "`t", "\t")

        pathPart := ""
        if nodePathsMap.Has(nodeId)
        {
            p := nodePathsMap[nodeId]
            ep := StrReplace(p, "\", "\\")
            ep := StrReplace(ep, '"', '\"')
            pathPart := ',"path":"' ep '"'
        }

        child := TV_GetChild(hwnd, nodeId)
        if child
        {
            childJson := _DumpTreeNodeRecursiveJsonEx(ctrl, hwnd, child, nodePathsMap)
            items.Push('{"text":"' escaped '"' pathPart ',"children":' childJson '}')
        }
        else
            items.Push('{"text":"' escaped '"' pathPart '}')

        nodeId := TV_GetNext(hwnd, nodeId)
    }
    joined := ""
    for i, item in items
        joined .= (i > 1 ? "," : "") item
    return "[" joined "]"
}

; Pushes the current watchlist (pinned node paths) to updateWatchlist() in the WebView.
PushWatchlistToWebView()
{
    global pinnedNodePaths, lastSnapshotForUi

    rows := "["
    first := true
    for _, path in pinnedNodePaths
    {
        value := ""
        if IsObject(lastSnapshotForUi)
        {
            try value := _ResolveSnapshotPath(lastSnapshotForUi, path)
        }
        ep := StrReplace(path,  "\", "\\")
        ep := StrReplace(ep,    '"', '\"')
        ev := StrReplace(String(value), "\", "\\")
        ev := StrReplace(ev, '"', '\"')
        rows .= (first ? "" : ",") '{"path":"' ep '","value":"' ev '"}'
        first := false
    }
    rows .= "]"
    WebViewExec("updateWatchlist(" rows ")")
}

; Resolves a snapshot path like "snapshot/inGameState/..." to a leaf value.
_ResolveSnapshotPath(snapshot, path)
{
    parts := StrSplit(path, "/")
    cur := snapshot
    for _, part in parts
    {
        if (part = "snapshot")
            continue
        if !(IsObject(cur) && Type(cur) = "Map" && cur.Has(part))
            return ""
        cur := cur[part]
    }
    return IsObject(cur) ? "[object]" : cur
}

; Calls all three push functions and updates the status bar.
PushAllDataToWebView()
{
    PushHeaderToWebView()
    PushActiveTreeToWebView()
    PushWatchlistToWebView()
    _PushBlacklistToWebView()
    UpdateStatusBar()
}

_PushBlacklistToWebView()
{
    global g_webViewReady, g_skillBuffBlacklist
    if !g_webViewReady
        return
    ; Build JSON array of blacklisted names
    json := "["
    for i, name in g_skillBuffBlacklist
    {
        if (i > 1)
            json .= ","
        escaped := StrReplace(StrReplace(name, "\", "\\"), "`"", "\`"")
        json .= "`"" escaped "`""
    }
    json .= "]"
    try WebViewExec("updateBlacklist(" json ")")
}

; Switches the active tree tab by key name and triggers a refresh.
SwitchTreeTab(key)
{
    global activeTreeTabIdx, treeTabKeys

    loop treeTabKeys.Length
    {
        if (treeTabKeys[A_Index] = key)
        {
            activeTreeTabIdx := A_Index
            break
        }
    }
    SetActiveTreeContextFromTab()
    ForceRefreshActiveTree()
}

; GameHelperBridge is no longer used — JS→AHK is handled via postMessage / OnWebMessage.
; Kept as empty stub for any legacy references.
/*
class GameHelperBridge
{
}
*/

; ─────────────────────────────────────────────────────────────────────────────
; Special-tab push functions (Buffs / Entities / UI / gameState)
; ─────────────────────────────────────────────────────────────────────────────

; Pushes all four non-tree tabs to the WebView using the current snapshot.
PushSpecialTabsToWebView(snapshot)
{
    global g_radarLastSnap, g_webViewReady
    if !g_webViewReady
        return
    try
    {
        WebViewExec("updateBuffs("     _JsStr(_BuildBuffsJson(snapshot))                                    ")")
        WebViewExec("updateEntities("  _JsStr(_BuildEntitiesJson(IsObject(g_radarLastSnap) ? g_radarLastSnap : 0)) ")")
        WebViewExec("updateUIState("   _JsStr(_BuildUIJson(snapshot))                                       ")")
        WebViewExec("updateGameState(" _JsStr(_BuildGameStateJson(snapshot))                                ")")
        WebViewExec("updateSkills("    _JsStr(_BuildSkillsJson(snapshot))                                   ")")
    }
    catch as ex
        LogError("PushSpecialTabsToWebView", ex)
}

_BuildBuffsJson(snapshot)
{
    try
    {
        inGame  := snapshot.Has("inGameState")   ? snapshot["inGameState"]   : 0
        area    := (inGame && inGame.Has("areaInstance")) ? inGame["areaInstance"] : 0
        bc      := (area  && area.Has("playerBuffsComponent")) ? area["playerBuffsComponent"] : 0
        if !IsObject(bc)
            return "[]"
        effects := bc.Has("effects") ? bc["effects"] : 0
        if !IsObject(effects)
            return "[]"

        ; Build skill icon lookup for fallback (buff→skill icon matching)
        skillIconLookup := Map()
        sk := (area && area.Has("playerSkills")) ? area["playerSkills"] : 0
        if IsObject(sk) && sk.Has("skills")
        {
            for _, s in sk["skills"]
            {
                if !IsObject(s)
                    continue
                dn := s.Has("displayName") ? String(s["displayName"]) : ""
                sic := s.Has("iconPath") ? String(s["iconPath"]) : ""
                if (dn != "" && sic != "")
                    skillIconLookup[StrLower(StrReplace(dn, " ", ""))] := sic
            }
        }

        rows      := "["
        first     := true
        buffNames := GetBuffNameMap()
        for _, eff in effects
        {
            if !IsObject(eff)
                continue
            name    := eff.Has("name")      ? String(eff["name"])      : ""
            charges := eff.Has("charges")   ? Integer(eff["charges"])  : 0
            tLeft   := eff.Has("timeLeft")  ? eff["timeLeft"]          : 0
            tTotal  := eff.Has("totalTime") ? eff["totalTime"]         : 0

            tLeftJson  := (!IsNumber(tLeft)  || tLeft  > 999999) ? '"inf"' : Round(Float(tLeft),  2)
            tTotalJson := (!IsNumber(tTotal) || tTotal > 999999)  ? '"inf"' : Round(Float(tTotal), 2)

            nameKey     := StrLower(name)
            displayName := buffNames.Has(nameKey) ? buffNames[nameKey] : name
            en := StrReplace(displayName, "\",  "\\")
            en := StrReplace(en,          '"',  '\"')
            en := StrReplace(en,          "`n", "\n")
            en := StrReplace(en,          "`r", "\r")
            en := StrReplace(en,          "`t", "\t")
            ic := eff.Has("iconPath") ? String(eff["iconPath"]) : ""
            if (ic = "")
            {
                normBuff := StrLower(StrReplace(name, "_", ""))
                for skillKey, skillIcon in skillIconLookup
                {
                    if (StrLen(skillKey) >= 4 && InStr(normBuff, skillKey) = 1)
                    {
                        ic := skillIcon
                        break
                    }
                }
            }
            ic := StrReplace(ic, "\",  "\\")
            ic := StrReplace(ic, '"',  '\"')

            if (en = "")
                continue
            rows .= (first ? "" : ",") '{"n":"' en '","s":' charges ',"t":' tLeftJson ',"tt":' tTotalJson ',"ic":"' ic '"}'
            first := false
        }
        return rows . "]"
    }
    catch
        return "[]"
}

; Classifies an entity path into a display type string.
_ClassifyEntityType(path)
{
    p := StrLower(path)
    if InStr(p, "metadata/characters/")
        return "Player"
    if InStr(p, "playersummoned") || InStr(p, "companion") || InStr(p, "playerminion")
        return "Minion"
    ; Structural / navigation types (check before generic Enemy)
    if InStr(p, "areatransition")
        return "AreaTransition"
    if InStr(p, "waypoint")
        return "Waypoint"
    if InStr(p, "checkpoint")
        return "Checkpoint"
    if InStr(p, "metadata/npc/") || InStr(p, "/npcs/")
        return "NPC"
    if InStr(p, "metadata/monsters/")
    {
        ; Boss detection: Unique monsters with "boss" or specific boss-like paths
        if InStr(p, "boss") || InStr(p, "unique")
            return "Boss"
        return "Enemy"
    }
    if InStr(p, "metadata/chests/") || InStr(p, "strongbox") || InStr(p, "detonator")
        return "Chest"
    if InStr(p, "worlditem") || InStr(p, "metadata/items/")
        return "WorldItem"
    if InStr(p, "metadata/projectiles/")
        return "Projectile"
    if InStr(p, "metadata/terrain/")
        return "Terrain"
    return "Object"
}

; Returns true if the entity type is one that should be scanned in sleeping entities.
_IsSleepingEntityImportant(entityType)
{
    return (entityType = "Boss" || entityType = "Checkpoint"
        || entityType = "Waypoint" || entityType = "AreaTransition" || entityType = "NPC")
}

_BuildEntitiesJson(snap)
{
    try
    {
        global entityShowPlayer, entityShowMinion, entityShowEnemy
        global entityShowNPC, entityShowChest, entityShowWorldItem, entityShowOther

        if !IsObject(snap)
            return "[]"

        ; Collect awake entities
        awakeEnt := 0
        sleepEnt := 0
        if snap.Has("inGameState")
        {
            inGame := snap["inGameState"]
            area   := (inGame && inGame.Has("areaInstance")) ? inGame["areaInstance"] : 0
            if (area && area.Has("awakeEntities"))
                awakeEnt := area["awakeEntities"]
            if (area && area.Has("sleepingEntities"))
                sleepEnt := area["sleepingEntities"]
        }
        if snap.Has("awakeEntities")
            awakeEnt := snap["awakeEntities"]
        if snap.Has("sleepingEntities") && !IsObject(sleepEnt)
            sleepEnt := snap["sleepingEntities"]

        ; Build unified candidate list: all awake + important sleeping
        allEntries := []
        awakePaths := Map()  ; track awake paths to avoid duplicates

        ; Process awake entities
        if (IsObject(awakeEnt) && awakeEnt.Has("sample") && IsObject(awakeEnt["sample"]))
        {
            for _, entry in awakeEnt["sample"]
            {
                if !IsObject(entry)
                    continue
                entity := entry.Has("entity") ? entry["entity"] : 0
                if !IsObject(entity)
                    continue
                path := entity.Has("path") ? entity["path"] : "?"
                awakePaths[path] := true
                allEntries.Push(Map("entry", entry, "sleeping", false))
            }
        }

        ; Process sleeping entities — only keep important types (Boss, NPC, Waypoint, etc.)
        if (IsObject(sleepEnt) && sleepEnt.Has("sample") && IsObject(sleepEnt["sample"]))
        {
            for _, entry in sleepEnt["sample"]
            {
                if !IsObject(entry)
                    continue
                entity := entry.Has("entity") ? entry["entity"] : 0
                if !IsObject(entity)
                    continue
                path := entity.Has("path") ? entity["path"] : "?"
                ; Skip if already in awake set
                if awakePaths.Has(path)
                    continue
                eType := _ClassifyEntityType(path)
                if _IsSleepingEntityImportant(eType)
                    allEntries.Push(Map("entry", entry, "sleeping", true))
            }
        }

        if (allEntries.Length = 0)
            return "[]"

        rarityNames := Map(0,"Normal",1,"Magic",2,"Rare",3,"Unique",4,"Unique",5,"Boss")
        rows  := "["
        first := true
        for _, item in allEntries
        {
            entry  := item["entry"]
            isSleep := item["sleeping"]
            entity := entry.Has("entity")   ? entry["entity"]   : 0
            dist   := entry.Has("distance") ? Round(entry["distance"], 0) : -1
            if !IsObject(entity)
                continue

            path    := entity.Has("path") ? entity["path"] : "?"
            decoded := entity.Has("decodedComponents") ? entity["decodedComponents"] : 0

            entityType := _ClassifyEntityType(path)

            ; Promote Enemy to Boss if rarity is Unique/Boss
            rarId := (decoded && decoded.Has("rarityId")) ? decoded["rarityId"] : 0
            if (entityType = "Enemy" && (rarId >= 3))
                entityType := "Boss"

            ; Apply entity type filters
            showIt := true
            switch entityType
            {
                case "Player":         showIt := entityShowPlayer
                case "Minion":         showIt := entityShowMinion
                case "Enemy":          showIt := entityShowEnemy
                case "Boss":           showIt := entityShowEnemy
                case "NPC":            showIt := entityShowNPC
                case "Chest":          showIt := entityShowChest
                case "WorldItem":      showIt := entityShowWorldItem
                case "AreaTransition": showIt := entityShowOther
                case "Waypoint":       showIt := entityShowOther
                case "Checkpoint":     showIt := entityShowOther
                default:               showIt := entityShowOther
            }
            if !showIt
                continue

            shortPath   := (path != "?") ? RegExReplace(path, ".*/", "") : "?"
            displayName := ResolveMonsterDisplayName(path, shortPath)

            rarity := rarityNames.Has(rarId) ? rarityNames[rarId] : "Normal"

            life    := (decoded && decoded.Has("life")) ? decoded["life"] : 0
            isAlive := true
            lifePct := -1
            if IsObject(life)
            {
                isAlive := life.Has("isAlive") ? life["isAlive"] : true
                lifePct := life.Has("lifeCurrentPercentMax") ? Round(life["lifeCurrentPercentMax"], 0) : -1
            }
            if decoded && decoded.Has("targetable")
                isAlive := decoded["targetable"]

            ep := StrReplace(path,        "\", "\\")
            ep := StrReplace(ep,          '"', '\"')
            en := StrReplace(displayName, "\", "\\")
            en := StrReplace(en,          '"', '\"')
            er := StrReplace(rarity,      '"', '\"')
            et := StrReplace(entityType,  '"', '\"')
            sl := isSleep ? "true" : "false"
            rows .= (first ? "" : ",")
                . '{"path":"' ep '","name":"' en '","rarity":"' er '","type":"' et '"'
                . ',"life":' lifePct ',"dist":' dist ',"alive":' (isAlive ? "true" : "false")
                . ',"sleep":' sl '}'
            first := false
        }
        return rows . "]"
    }
    catch
        return "[]"
}

_BuildUIJson(snapshot)
{
    try
    {
        inGame := snapshot.Has("inGameState") ? snapshot["inGameState"] : 0
        if !inGame
            return "{}"
        ui := inGame.Has("importantUiElements") ? inGame["importantUiElements"] : 0
        if !IsObject(ui)
            return "{}"
        return _SerializeMapShallow(ui, 2)
    }
    catch
        return "{}"
}

_BuildGameStateJson(snapshot)
{
    try
    {
        if !IsObject(snapshot)
            return "{}"
        inGame := snapshot.Has("inGameState") ? snapshot["inGameState"] : 0
        if !inGame
            return "{}"
        area := inGame.Has("areaInstance") ? inGame["areaInstance"] : 0
        if !IsObject(area)
            return "{}"
        skip := Map("awakeEntities",1,"sleepingEntities",1,"playerBuffsComponent",1)
        return _SerializeMapShallow(area, 1, skip)
    }
    catch
        return "{}"
}

_BuildSkillsJson(snapshot)
{
    try
    {
        inGame := snapshot.Has("inGameState") ? snapshot["inGameState"] : 0
        area := (inGame && inGame.Has("areaInstance")) ? inGame["areaInstance"] : 0
        sk := (area && area.Has("playerSkills")) ? area["playerSkills"] : 0
        if !IsObject(sk)
            return '{"skills":[],"asOff":0}'
        skills := sk.Has("skills") ? sk["skills"] : 0
        asOff := sk.Has("activeSkillOffset") ? Integer(sk["activeSkillOffset"]) : 0
        if !IsObject(skills) || Type(skills) != "Array" || skills.Length = 0
            return '{"skills":[],"asOff":' asOff '}'

        ; Read active buff names for dedup and distance-block detection
        buffNormSet := Map()
        distCharges := -1
        bc := (area && area.Has("playerBuffsComponent")) ? area["playerBuffsComponent"] : 0
        if IsObject(bc) && bc.Has("effects")
        {
            for _, eff in bc["effects"]
            {
                if !IsObject(eff)
                    continue
                bn := eff.Has("name") ? String(eff["name"]) : ""
                if (bn != "")
                {
                    normBn := StrLower(StrReplace(bn, "_", ""))
                    buffNormSet[normBn] := true
                }
                if (InStr(bn, "unusable") && InStr(bn, "moved"))
                    distCharges := eff.Has("charges") ? Integer(eff["charges"]) : 0
            }
        }

        rows := "["
        first := true
        for _, s in skills
        {
            if !IsObject(s)
                continue
            nm := s.Has("name") ? String(s["name"]) : "?"
            nm := StrReplace(nm, "\",  "\\")
            nm := StrReplace(nm, '"',  '\"')
            nm := StrReplace(nm, "`n", "\n")
            nm := StrReplace(nm, "`r", "\r")
            if (nm = "")
                continue
            dn := s.Has("displayName") ? String(s["displayName"]) : nm

            ; Dedup: skip skills already shown as active buffs (before escaping)
            normDn := StrLower(StrReplace(dn, " ", ""))
            if (StrLen(normDn) >= 4
                && (buffNormSet.Has(normDn)
                    || buffNormSet.Has(normDn "reservation")
                    || buffNormSet.Has(normDn "reserve")
                    || buffNormSet.Has(normDn "active")))
                continue

            dn := StrReplace(dn, "\",  "\\")
            dn := StrReplace(dn, '"',  '\"')
            dn := StrReplace(dn, "`n", "\n")
            dn := StrReplace(dn, "`r", "\r")

            ; Filter out unusable/DNT/utility skills
            if (InStr(nm, "Unusable") || InStr(nm, "DodgeRoll")
                || InStr(nm, "DirectMinions") || InStr(nm, "LingeringIllusionSpawn")
                || InStr(dn, "Direct Minions") || InStr(dn, "LingeringIllusionSpawn")
                || InStr(dn, "[DNT") || InStr(dn, "enforced_walking"))
                continue

            ic := s.Has("iconPath") ? String(s["iconPath"]) : ""
            ic := StrReplace(ic, "\",  "\\")
            ic := StrReplace(ic, '"',  '\"')

            useStage    := s.Has("useStage")    ? Integer(s["useStage"])    : 0
            castType    := s.Has("castType")    ? Integer(s["castType"])    : 0
            totalUses   := s.Has("totalUses")   ? Integer(s["totalUses"])   : 0
            cooldownMs  := s.Has("cooldownMs")  ? Integer(s["cooldownMs"])  : 0
            canUse      := (s.Has("canUse") && s["canUse"]) ? "true" : "false"
            activeCds   := s.Has("activeCooldowns") ? Integer(s["activeCooldowns"]) : 0
            maxUses     := s.Has("maxUses")     ? Integer(s["maxUses"])     : 0
            equipId     := s.Has("equipId")     ? s["equipId"]             : 0
            equipHex    := Format("0x{:X}", equipId & 0xFFFFFFFF)

            rows .= (first ? "" : ",")
                . '{"n":"' nm '"'
                . ',"dn":"' dn '"'
                . ',"ic":"' ic '"'
                . ',"us":' useStage
                . ',"ct":' castType
                . ',"tu":' totalUses
                . ',"cd":' cooldownMs
                . ',"ok":' canUse
                . ',"ac":' activeCds
                . ',"mu":' maxUses
                . ',"eq":"' equipHex '"}'
            first := false
        }
        return '{"skills":' rows '],"asOff":' asOff ',"distCh":' distCharges '}'
    }
    catch
        return '{"skills":[],"asOff":0}'
}

; Shallow-serialises an AHK Map to a JSON object string.
; depth: how many levels deep to recurse (1 = flat, 2 = one level of nested Maps)
; skipKeys: optional Map of keys to omit
_SerializeMapShallow(m, depth := 1, skipKeys := 0)
{
    if !IsObject(m) || Type(m) != "Map"
        return '""'
    out   := "{"
    first := true
    for k, v in m
    {
        if (IsObject(skipKeys) && skipKeys.Has(k))
            continue
        ek := StrReplace(String(k), '"', '\"')
        if IsObject(v)
        {
            if (depth > 1 && Type(v) = "Map")
                sv := _SerializeMapShallow(v, depth - 1, 0)
            else if Type(v) = "Array"
                sv := '"[Array/' v.Length ']"'
            else
                sv := '"[Object]"'
        }
        else
        {
            sv := String(v)
            if IsInteger(sv)
            {
                n := Integer(sv)
                if (n > 0xFFFF || n < -0xFFFF)
                    sv := '"0x' Format("{:X}", n & 0xFFFFFFFFFFFFFFFF) '"'
                ; else keep as plain number
            }
            else if !IsNumber(sv)
            {
                sv := StrReplace(sv, "\",  "\\")
                sv := StrReplace(sv, '"',  '\"')
                sv := StrReplace(sv, "`n", "\n")
                sv := StrReplace(sv, "`r", "\r")
                sv := '"' sv '"'
            }
        }
        out .= (first ? "" : ",") '"' ek '":' sv
        first := false
    }
    return out . "}"
}

; ─────────────────────────────────────────────────────────────────────────────
; Config persistence — saves/loads all user-configurable settings to/from INI
; ─────────────────────────────────────────────────────────────────────────────

_ConfigPath() => A_ScriptDir "\gamehelper_config.ini"

SaveConfig()
{
    global debugMode, autoFlaskEnabled, autoFlaskPerformanceMode
    global lifeThresholdPercent, manaThresholdPercent, g_radarEnabled
    global updatesPaused, npcWatchAutoSync
    global radarShowEnemyNormal, radarShowEnemyRare, radarShowEnemyBoss
    global radarShowMinions, radarShowNpcs, radarShowChests
    global entityShowPlayer, entityShowMinion, entityShowEnemy
    global entityShowNPC, entityShowChest, entityShowWorldItem, entityShowOther
    global g_skillBuffBlacklist, g_zoneNavEnabled, g_mapHackEnabled

    f := _ConfigPath()
    IniWrite(debugMode             ? "1" : "0",  f, "General",       "debugMode")
    IniWrite(updatesPaused         ? "1" : "0",  f, "General",       "updatesPaused")
    IniWrite(npcWatchAutoSync      ? "1" : "0",  f, "General",       "npcWatchAutoSync")
    IniWrite(lifeThresholdPercent,               f, "General",       "lifeThreshold")
    IniWrite(manaThresholdPercent,               f, "General",       "manaThreshold")
    IniWrite(autoFlaskEnabled      ? "1" : "0",  f, "AutoFlask",     "enabled")
    IniWrite(autoFlaskPerformanceMode ? "1":"0", f, "AutoFlask",     "performanceMode")
    IniWrite(g_radarEnabled        ? "1" : "0",  f, "Radar",         "enabled")
    IniWrite(radarShowEnemyNormal  ? "1" : "0",  f, "Radar",         "showNormal")
    IniWrite(radarShowEnemyRare    ? "1" : "0",  f, "Radar",         "showRare")
    IniWrite(radarShowEnemyBoss    ? "1" : "0",  f, "Radar",         "showBoss")
    IniWrite(radarShowMinions      ? "1" : "0",  f, "Radar",         "showMinions")
    IniWrite(radarShowNpcs         ? "1" : "0",  f, "Radar",         "showNpcs")
    IniWrite(radarShowChests       ? "1" : "0",  f, "Radar",         "showChests")
    IniWrite(g_zoneNavEnabled      ? "1" : "0",  f, "Radar",         "zoneNav")
    IniWrite(g_mapHackEnabled      ? "1" : "0",  f, "Radar",         "mapHack")
    IniWrite(entityShowPlayer      ? "1" : "0",  f, "EntityFilters", "showPlayer")
    IniWrite(entityShowMinion      ? "1" : "0",  f, "EntityFilters", "showMinion")
    IniWrite(entityShowEnemy       ? "1" : "0",  f, "EntityFilters", "showEnemy")
    IniWrite(entityShowNPC         ? "1" : "0",  f, "EntityFilters", "showNPC")
    IniWrite(entityShowChest       ? "1" : "0",  f, "EntityFilters", "showChest")
    IniWrite(entityShowWorldItem   ? "1" : "0",  f, "EntityFilters", "showWorldItem")
    IniWrite(entityShowOther       ? "1" : "0",  f, "EntityFilters", "showOther")

    ; Blacklist: store as pipe-separated (names may contain commas)
    blStr := ""
    for i, name in g_skillBuffBlacklist
    {
        if (i > 1)
            blStr .= "|"
        blStr .= name
    }
    IniWrite(blStr, f, "SkillBuffBlacklist", "names")
}

LoadConfig()
{
    global debugMode, autoFlaskEnabled, autoFlaskPerformanceMode
    global lifeThresholdPercent, manaThresholdPercent, g_radarEnabled
    global updatesPaused, npcWatchAutoSync
    global radarShowEnemyNormal, radarShowEnemyRare, radarShowEnemyBoss
    global radarShowMinions, radarShowNpcs, radarShowChests
    global entityShowPlayer, entityShowMinion, entityShowEnemy
    global entityShowNPC, entityShowChest, entityShowWorldItem, entityShowOther
    global g_skillBuffBlacklist, g_zoneNavEnabled, g_mapHackEnabled

    f := _ConfigPath()
    if !FileExist(f)
        return  ; no file yet — keep defaults

    _Ini(sec, key, defVal) => IniRead(f, sec, key, defVal)
    _B(sec, key, defVal) => (_Ini(sec, key, defVal ? "1" : "0") = "1")

    debugMode                := _B("General",       "debugMode",       false)
    updatesPaused            := _B("General",       "updatesPaused",   false)
    npcWatchAutoSync         := _B("General",       "npcWatchAutoSync",false)
    lifeThresholdPercent     := Integer(_Ini("General",   "lifeThreshold",   55))
    manaThresholdPercent     := Integer(_Ini("General",   "manaThreshold",   35))
    autoFlaskEnabled         := _B("AutoFlask",     "enabled",         false)
    autoFlaskPerformanceMode := _B("AutoFlask",     "performanceMode", false)
    g_radarEnabled           := _B("Radar",         "enabled",         true)
    radarShowEnemyNormal     := _B("Radar",         "showNormal",      true)
    radarShowEnemyRare       := _B("Radar",         "showRare",        true)
    radarShowEnemyBoss       := _B("Radar",         "showBoss",        true)
    radarShowMinions         := _B("Radar",         "showMinions",     true)
    radarShowNpcs            := _B("Radar",         "showNpcs",        true)
    radarShowChests          := _B("Radar",         "showChests",      true)
    g_zoneNavEnabled         := _B("Radar",         "zoneNav",         true)
    g_mapHackEnabled         := _B("Radar",         "mapHack",         true)
    entityShowPlayer         := _B("EntityFilters", "showPlayer",      true)
    entityShowMinion         := _B("EntityFilters", "showMinion",      true)
    entityShowEnemy          := _B("EntityFilters", "showEnemy",       true)
    entityShowNPC            := _B("EntityFilters", "showNPC",         true)
    entityShowChest          := _B("EntityFilters", "showChest",       true)
    entityShowWorldItem      := _B("EntityFilters", "showWorldItem",   true)
    entityShowOther          := _B("EntityFilters", "showOther",       true)

    ; Blacklist
    blStr := _Ini("SkillBuffBlacklist", "names", "")
    g_skillBuffBlacklist := []
    if (blStr != "")
    {
        loop parse, blStr, "|"
        {
            if (A_LoopField != "")
                g_skillBuffBlacklist.Push(A_LoopField)
        }
    }
}