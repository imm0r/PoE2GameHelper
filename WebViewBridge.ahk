; WebViewBridge.ahk
; All WebView communication helpers: JS execution, JSON escaping, and data push functions.
; Pushes toggle state, tree data, watchlist, blacklist, and special tab data to the UI.
;
; Included by InGameStateMonitor.ahk

; Escapes a string for use as a JSON string literal (with surrounding double quotes).
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
    global g_webGui, g_webViewReady
    if !g_webViewReady
        return
    try g_webGui.Control.wv.ExecuteScriptAsync(js)
}

; Pushes the current toggle/config state as a JSON object to updateHeader() in the WebView.
PushHeaderToWebView()
{
    global g_debugMode, g_updatesPaused, g_autoFlaskEnabled, g_autoFlaskPerformanceMode
    global g_pinnedNodePaths, g_showTreePane, g_activeTreeTabKey, g_npcWatchAutoSync
    global g_lifeThresholdPercent, g_manaThresholdPercent
    global g_radarShowEnemyNormal, g_radarShowEnemyRare, g_radarShowEnemyBoss
    global g_radarShowMinions, g_radarShowNpcs, g_radarShowChests
    global g_autoFlaskLastReason, g_flaskKeyBySlot, g_reader, g_radarEnabled, g_webGui
    global g_playerHudEnabled
    global GAMEHELPER_VERSION
    global g_entityShowPlayer, g_entityShowMinion, g_entityShowEnemy
    global g_entityShowNPC, g_entityShowChest, g_entityShowWorldItem, g_entityShowOther
    global g_zoneNavEnabled
    global g_radarAlpha, g_mapHackEnabled
    global g_cfgOpenSections

    poeRunning := (ProcessExist("PathOfExileSteam.exe") || ProcessExist("PathOfExile.exe")) ? "true" : "false"
    slot1Key := g_flaskKeyBySlot.Has(1) ? g_flaskKeyBySlot[1] : "?"
    slot2Key := g_flaskKeyBySlot.Has(2) ? g_flaskKeyBySlot[2] : "?"
    connected := (IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle) ? "true" : "false"
    gameVer := GetLastKnownPoeVersion()
    isMaximized := (WinGetMinMax("ahk_id " g_webGui.Hwnd) = 1) ? "true" : "false"

    json := "{"
          . '"connected":'      connected                ","
          . '"debug":'          (g_debugMode              ? "true" : "false") ","
          . '"paused":'         (g_updatesPaused          ? "true" : "false") ","
          . '"autoFlask":'      (g_autoFlaskEnabled        ? "true" : "false") ","
          . '"afPerf":'         (g_autoFlaskPerformanceMode ? "true" : "false") ","
          . '"showTree":'       (g_showTreePane            ? "true" : "false") ","
          . '"npcSync":'        (g_npcWatchAutoSync        ? "true" : "false") ","
          . '"poeRunning":'     poeRunning               ","
          . '"lifeThreshold":'  g_lifeThresholdPercent     ","
          . '"manaThreshold":'  g_manaThresholdPercent     ","
          . '"pinnedCount":'    g_pinnedNodePaths.Length   ","
          . '"activeTab":'      _JsStr(g_activeTreeTabKey) ","
          . '"afReason":'       _JsStr(g_autoFlaskLastReason) ","
          . '"afSlot1Key":'     _JsStr(slot1Key) ","
          . '"afSlot2Key":'     _JsStr(slot2Key) ","
          . '"ghVersion":'      _JsStr(GAMEHELPER_VERSION) ","
          . '"gameVersion":'    _JsStr(gameVer) ","
          . '"radarEnabled":'   (g_radarEnabled ? "true" : "false") ","
          . '"playerHud":'      (g_playerHudEnabled ? "true" : "false") ","
          . '"radarAlpha":'     g_radarAlpha ","
          . '"isMaximized":'    isMaximized ","
          . '"entityFilter":{'
          . '"player":'    (g_entityShowPlayer    ? "true" : "false") ","
          . '"minion":'    (g_entityShowMinion    ? "true" : "false") ","
          . '"enemy":'     (g_entityShowEnemy     ? "true" : "false") ","
          . '"npc":'       (g_entityShowNPC       ? "true" : "false") ","
          . '"chest":'     (g_entityShowChest     ? "true" : "false") ","
          . '"worlditem":' (g_entityShowWorldItem ? "true" : "false") ","
          . '"other":'     (g_entityShowOther     ? "true" : "false")
          . "},"
          . '"radar":{'
          . '"normal":'  (g_radarShowEnemyNormal ? "true" : "false") ","
          . '"rare":'    (g_radarShowEnemyRare   ? "true" : "false") ","
          . '"boss":'    (g_radarShowEnemyBoss   ? "true" : "false") ","
          . '"minions":' (g_radarShowMinions     ? "true" : "false") ","
          . '"npcs":'    (g_radarShowNpcs        ? "true" : "false") ","
          . '"chests":'  (g_radarShowChests      ? "true" : "false")
          . "},"
          . '"zoneNav":' (g_zoneNavEnabled ? "true" : "false") ","
          . '"mapHack":' (g_mapHackEnabled ? "true" : "false") ","
          . '"cfgSections":' _JsStr(g_cfgOpenSections)
          . "}"
    WebViewExec("updateHeader(" json ")")
}

; Serialises the active TreeView tab and pushes it to updateTree() in the WebView.
PushActiveTreeToWebView()
{
    global g_activeTreeTabKey, g_treeControlsByTab, g_treeNodePathsByTab

    if !g_treeControlsByTab.Has(g_activeTreeTabKey)
        return

    ctrl := g_treeControlsByTab[g_activeTreeTabKey]
    hwnd := ctrl.Hwnd
    root := TV_GetRoot(hwnd)
    nodePathsMap := g_treeNodePathsByTab.Has(g_activeTreeTabKey) ? g_treeNodePathsByTab[g_activeTreeTabKey] : Map()
    nodesJson := root ? _DumpTreeNodeRecursiveJsonEx(ctrl, hwnd, root, nodePathsMap) : "[]"

    WebViewExec("updateTree(" _JsStr(g_activeTreeTabKey) "," nodesJson ")")
}

; Recursive tree serialiser that also embeds the node path when available.
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
    global g_pinnedNodePaths, g_lastSnapshotForUi

    rows := "["
    first := true
    for _, path in g_pinnedNodePaths
    {
        value := ""
        if IsObject(g_lastSnapshotForUi)
        {
            try value := _ResolveSnapshotPath(g_lastSnapshotForUi, path)
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

; Resolves a dot/slash-separated snapshot path to a leaf value.
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

; Pushes header, tree, watchlist, blacklist, and status bar data to the WebView.
PushAllDataToWebView()
{
    PushHeaderToWebView()
    PushActiveTreeToWebView()
    PushWatchlistToWebView()
    _PushBlacklistToWebView()
    UpdateStatusBar()
}

; Pushes the skill/buff blacklist array to updateBlacklist() in the WebView.
_PushBlacklistToWebView()
{
    global g_webViewReady, g_skillBuffBlacklist
    if !g_webViewReady
        return
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

; Pushes debug panel data (panel visibility, discovery info, overlay state) to updateDebugPanels().
PushDebugPanelsToWebView(radarSnap, overlayAllowed := true, hideReason := "")
{
    global g_webViewReady
    if !g_webViewReady
        return

    json := "{"

    ; Panel visibility (new differential format)
    panelVis := (radarSnap && radarSnap.Has("panelVisibility")) ? radarSnap["panelVisibility"] : 0
    json .= '"panelVisibility":{'
    if (panelVis && IsObject(panelVis))
    {
        json .= '"anyPanelOpen":' (panelVis.Has("anyPanelOpen") && panelVis["anyPanelOpen"] ? "true" : "false") ","
        json .= '"newlyVisible":' (panelVis.Has("newlyVisible") ? panelVis["newlyVisible"] : 0) ","
        json .= '"newlyHidden":' (panelVis.Has("newlyHidden") ? panelVis["newlyHidden"] : 0) ","
        json .= '"totalChanged":' (panelVis.Has("totalChanged") ? panelVis["totalChanged"] : 0) ","
        json .= '"ptrsAppeared":' (panelVis.Has("ptrsAppeared") ? panelVis["ptrsAppeared"] : 0) ","
        json .= '"ptrsDisappeared":' (panelVis.Has("ptrsDisappeared") ? panelVis["ptrsDisappeared"] : 0) ","
        json .= '"currentVisible":' (panelVis.Has("currentVisible") ? panelVis["currentVisible"] : 0) ","
        json .= '"baselineVisible":' (panelVis.Has("baselineVisible") ? panelVis["baselineVisible"] : 0) ","
        json .= '"_changedOffsets":['
        chOff := panelVis.Has("_changedOffsets") ? panelVis["_changedOffsets"] : []
        if (chOff && IsObject(chOff))
        {
            first := true
            for _, off in chOff
            {
                if !first
                    json .= ","
                json .= _JsStr(off)
                first := false
            }
        }
        json .= "]"
    }
    else
        json .= '"anyPanelOpen":false,"newlyVisible":0,"newlyHidden":0,"totalChanged":0,"ptrsAppeared":0,"ptrsDisappeared":0,"currentVisible":0,"baselineVisible":0,"_changedOffsets":[]'
    json .= "},"

    ; Panel discovery
    disc := (radarSnap && radarSnap.Has("panelDiscovery")) ? radarSnap["panelDiscovery"] : 0
    json .= '"panelDiscovery":{'
    if (disc && IsObject(disc))
    {
        json .= '"_totalChildren":' (disc.Has("_totalChildren") ? disc["_totalChildren"] : 0) ","
        json .= '"_heapPtrCount":' (disc.Has("_heapPtrCount") ? disc["_heapPtrCount"] : 0) ","
        json .= '"_uiElemCount":' (disc.Has("_uiElemCount") ? disc["_uiElemCount"] : 0) ","
        json .= '"_visibleCount":' (disc.Has("_visibleCount") ? disc["_visibleCount"] : 0) ","
        json .= '"_invisibleCount":' (disc.Has("_invisibleCount") ? disc["_invisibleCount"] : 0) ","

        ; Diagnostic samples (struct offsets with flags + visibility)
        json .= '"_diagSamples":['
        diagSamples := disc.Has("_diagSamples") ? disc["_diagSamples"] : 0
        if (diagSamples && IsObject(diagSamples))
        {
            first := true
            for _, sample in diagSamples
            {
                if !first
                    json .= ","
                json .= '{"idx":' _JsStr(sample["idx"])
                    . ',"ptr":' _JsStr(sample["ptr"])
                    . ',"stringId":' _JsStr(sample["stringId"])
                    . ',"rawHex":' _JsStr(sample["rawHex"])
                    . ',"childInfo":' _JsStr(sample["childInfo"])
                    . '}'
                first := false
            }
        }
        json .= "]"
    }
    else
        json .= '"_totalChildren":0,"_heapPtrCount":0,"_uiElemCount":0,"_visibleCount":0,"_invisibleCount":0,"_diagSamples":[]'
    json .= "},"

    ; Overlay state
    currentState := (radarSnap && radarSnap.Has("currentStateName")) ? radarSnap["currentStateName"] : ""
    wad := (radarSnap && radarSnap.Has("worldAreaDat")) ? radarSnap["worldAreaDat"] : 0
    pv := (radarSnap && radarSnap.Has("playerVitals")) ? radarSnap["playerVitals"] : 0
    isTown := (wad && IsObject(wad) && wad.Has("isTown")) ? wad["isTown"] : false
    isHideout := (wad && IsObject(wad) && wad.Has("isHideout")) ? wad["isHideout"] : false
    isAlive := true
    if (pv && IsObject(pv) && pv.Has("stats"))
    {
        stats := pv["stats"]
        if stats.Has("isAlive")
            isAlive := stats["isAlive"]
    }

    ; Check large map visibility and collect map diagnostics
    largeMapOpen := false
    miniMapOpen := false
    mapDebug := ""
    inGs := (radarSnap && radarSnap.Has("inGameState")) ? radarSnap["inGameState"] : 0
    uiElems := (inGs && IsObject(inGs) && inGs.Has("importantUiElements")) ? inGs["importantUiElements"] : 0
    if (uiElems && IsObject(uiElems))
    {
        lm := uiElems.Has("largeMapData") ? uiElems["largeMapData"] : 0
        mm := uiElems.Has("miniMapData") ? uiElems["miniMapData"] : 0
        lmPtr := uiElems.Has("largeMapPtr") ? uiElems["largeMapPtr"] : 0
        mmPtr := uiElems.Has("miniMapPtr") ? uiElems["miniMapPtr"] : 0
        mapDebug := Format("lmPtr=0x{:X} mmPtr=0x{:X}", lmPtr, mmPtr)
        if (lm && IsObject(lm) && lm.Has("isVisible"))
        {
            largeMapOpen := lm["isVisible"] ? true : false
            mapDebug .= " lmVis=" (lm["isVisible"] ? "1" : "0") " lmFlags=" (lm.Has("flags") ? lm["flags"] : "?")
        }
        else
            mapDebug .= " lmData=NONE"
        if (mm && IsObject(mm) && mm.Has("isVisible"))
        {
            miniMapOpen := mm["isVisible"] ? true : false
            mapDebug .= " mmVis=" (mm["isVisible"] ? "1" : "0")
        }
        else
            mapDebug .= " mmData=NONE"
    }
    else
        mapDebug := "uiElems=" (uiElems ? "non-obj" : "null")

    json .= '"overlay":{'
        . '"allowed":'      (overlayAllowed ? "true" : "false") ","
        . '"hideReason":'   _JsStr(hideReason) ","
        . '"currentState":' _JsStr(currentState) ","
        . '"largeMapOpen":' (largeMapOpen ? "true" : "false") ","
        . '"miniMapOpen":'  (miniMapOpen ? "true" : "false") ","
        . '"mapDebug":'     _JsStr(mapDebug) ","
        . '"isTown":'       (isTown ? "true" : "false") ","
        . '"isHideout":'    (isHideout ? "true" : "false") ","
        . '"isAlive":'      (isAlive ? "true" : "false")
        . "}"

    json .= "}"
    try WebViewExec("updateDebugPanels(" json ")")
}

; Pushes struct diff comparison results to the Debug tab's updateDiffResults() JS function.
PushDiffResultsToWebView(diffResult)
{
    global g_webViewReady
    if !g_webViewReady
        return

    json := "{"
    json .= '"success":' (diffResult.Has("success") && diffResult["success"] ? "true" : "false") ","

    ; Struct byte changes
    json .= '"structChanges":['
    sc := diffResult.Has("structChanges") ? diffResult["structChanges"] : []
    first := true
    for _, ch in sc
    {
        if !first
            json .= ","
        json .= '{"off":' _JsStr(ch["off"]) ',"old":' _JsStr(ch["old"]) ',"new":' _JsStr(ch["new"]) '}'
        first := false
    }
    json .= "],"

    ; Element field changes
    json .= '"elemChanges":['
    ec := diffResult.Has("elemChanges") ? diffResult["elemChanges"] : []
    first := true
    for _, ch in ec
    {
        if !first
            json .= ","
        ; Serialize changes array
        chArr := ch.Has("changes") ? ch["changes"] : []
        chJson := "["
        cfirst := true
        for _, c in chArr
        {
            if !cfirst
                chJson .= ","
            chJson .= _JsStr(c)
            cfirst := false
        }
        chJson .= "]"

        json .= '{"off":' _JsStr(ch["off"])
            . ',"ptr":' _JsStr(ch["ptr"])
            . ',"label":' _JsStr(ch.Has("label") ? ch["label"] : "")
            . ',"changes":' chJson '}'
        first := false
    }
    json .= "]"

    json .= "}"
    try WebViewExec("updateDiffResults(" json ")")
}

; Pushes all four non-tree special tabs (buffs, entities, UI, gameState, skills) to the WebView.
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

; Lists *.tsv files in the data/ directory and pushes the names to the WebView.
_PushTsvFileList()
{
    scriptDir := A_ScriptDir
    dataDir := scriptDir "\data"
    files := []
    loop files dataDir "\*.tsv"
        files.Push(A_LoopFileName)

    ; Build JSON array
    json := "["
    for i, f in files
    {
        if (i > 1)
            json .= ","
        json .= _JsStr(f)
    }
    json .= "]"
    WebViewExec("populateTsvFileList(" _JsStr(json) ")")
}

; Reads a TSV file and pushes its content as {headers, rows} JSON to the WebView.
_PushTsvFileContent(filename)
{
    scriptDir := A_ScriptDir
    filePath := scriptDir "\data\" filename

    ; Security: ensure the file is inside data/ and is a .tsv
    if (!FileExist(filePath) || !InStr(filename, ".tsv"))
    {
        WebViewExec("renderTsvData(" _JsStr('{"headers":[],"rows":[]}') ")")
        return
    }

    content := FileRead(filePath, "UTF-8")
    lines := StrSplit(content, "`n", "`r")

    ; Skip comment lines (# prefix) and empty lines at the start
    dataStart := 1
    while (dataStart <= lines.Length)
    {
        line := lines[dataStart]
        if (line = "" || SubStr(line, 1, 1) = "#")
            dataStart++
        else
            break
    }

    if (dataStart > lines.Length)
    {
        WebViewExec("renderTsvData(" _JsStr('{"headers":[],"rows":[]}') ")")
        return
    }

    ; Detect columns from first data line
    firstLine := lines[dataStart]
    cols := StrSplit(firstLine, "`t")

    ; Determine if the first data line looks like a header
    ; Heuristic: if no column is purely numeric, treat it as headers
    allText := true
    for _, c in cols
    {
        trimmed := Trim(c)
        if (trimmed != "" && IsNumber(trimmed))
        {
            allText := false
            break
        }
    }

    ; Build headers
    headers := []
    rowStart := dataStart
    if (allText && cols.Length >= 2)
    {
        ; Use first line as headers
        for _, c in cols
            headers.Push(Trim(c))
        rowStart := dataStart + 1
    }
    else
    {
        ; Generate generic column headers
        loop cols.Length
            headers.Push("col_" A_Index)
    }

    ; Build JSON
    json := '{"headers":['
    for i, h in headers
    {
        if (i > 1)
            json .= ","
        json .= _JsStr(h)
    }
    json .= '],"rows":['

    rowCount := 0
    idx := rowStart
    while (idx <= lines.Length)
    {
        line := lines[idx]
        idx++
        if (line = "" || SubStr(line, 1, 1) = "#")
            continue

        parts := StrSplit(line, "`t")
        if (rowCount > 0)
            json .= ","
        json .= "["
        loop headers.Length
        {
            if (A_Index > 1)
                json .= ","
            val := (A_Index <= parts.Length) ? parts[A_Index] : ""
            json .= _JsStr(val)
        }
        json .= "]"
        rowCount++
    }
    json .= "]}"

    WebViewExec("renderTsvData(" _JsStr(json) ")")
}

; Runs the full TSV generation pipeline: poe_data_tools dump + Python scripts.
; Sends progress to the WebView via tsvGenLog/tsvGenStatus/tsvGenDone.
_RunTsvGenerationPipeline()
{
    toolsDir := A_ScriptDir "\tools"
    pdt := toolsDir "\poe_data_tools.exe"
    csvDir := A_ScriptDir "\data\raw_csv"
    extractDir := A_ScriptDir "\data\raw_extracted"

    _TsvLog("=== TSV Generation Pipeline ===", "log-step")

    ; Check poe_data_tools.exe exists
    if !FileExist(pdt)
    {
        _TsvLog("ERROR: poe_data_tools.exe not found in tools/", "log-err")
        _TsvStatus("Failed — poe_data_tools.exe missing", "error")
        WebViewExec("tsvGenDone(false)")
        return
    }

    ; Ensure output dirs exist
    if !DirExist(csvDir)
        DirCreate(csvDir)
    if !DirExist(extractDir)
        DirCreate(extractDir)

    ; Step 1: dump-tables
    _TsvLog("[1/3] Dumping .datc64 tables to CSV…", "log-step")
    _TsvStatus("Step 1/3 — Extracting datc64 tables…", "running")

    dumpCmd := '"' pdt '" --patch 2 dump-tables "' csvDir '" '
        . '"Data/Balance/Stats.datc64" '
        . '"Data/Balance/Mods.datc64" '
        . '"Data/Balance/ModType.datc64" '
        . '"Data/Balance/Words.datc64" '
        . '"Data/Balance/MonsterVarieties.datc64" '
        . '"Data/Balance/BaseItemTypes.datc64" '
        . '"Data/Balance/UniqueGoldPrices.datc64" '
        . '"Data/Balance/UniqueStashLayout.datc64" '
        . '"Data/Balance/ItemVisualIdentity.datc64"'

    result := _RunCmdCapture(dumpCmd, toolsDir)
    if (result.exitCode != 0)
    {
        _TsvLog("ERROR: dump-tables failed (exit " result.exitCode ")", "log-err")
        if (result.output != "")
            _TsvLog(result.output, "log-err")
        _TsvStatus("Failed at step 1 — dump-tables", "error")
        WebViewExec("tsvGenDone(false)")
        return
    }
    _TsvLog("  dump-tables OK", "log-ok")

    ; Step 2: extract CSD files
    _TsvLog("[2/3] Extracting StatDescriptions CSD files…", "log-step")
    _TsvStatus("Step 2/3 — Extracting CSD files…", "running")

    extractCmd := '"' pdt '" --patch 2 extract "' extractDir '" '
        . '"Data/StatDescriptions/**/*.csd"'
    result := _RunCmdCapture(extractCmd, toolsDir)
    if (result.exitCode != 0)
    {
        _TsvLog("WARNING: CSD extraction failed — stat_desc_map.tsv won't update", "log-err")
    }
    else
        _TsvLog("  CSD extraction OK", "log-ok")

    ; Step 3: Run Python scripts
    _TsvLog("[3/3] Running Python scripts…", "log-step")
    _TsvStatus("Step 3/3 — Running Python scripts…", "running")

    scripts := [
        "extract_stats_dat_csv.py",
        "extract_mods_dat_csv.py",
        "extract_monster_names_csv.py",
        "build_item_names_csv.py",
        "build_stat_desc_map_csv.py"
    ]

    allOk := true
    for _, script in scripts
    {
        _TsvLog("  Running " script "…", "")
        result := _RunCmdCapture('python "' toolsDir "\" script '"', toolsDir)
        if (result.exitCode != 0)
        {
            _TsvLog("  ERROR: " script " failed", "log-err")
            if (result.output != "")
                _TsvLog("  " result.output, "log-err")
            allOk := false
        }
        else
        {
            out := Trim(result.output, " `t`n`r")
            if (out != "")
                _TsvLog("  " out, "log-ok")
        }
    }

    if (allOk)
    {
        _TsvLog("=== All done! ===", "log-ok")
        _TsvStatus("Complete ✓", "done")
    }
    else
    {
        _TsvLog("=== Finished with errors ===", "log-err")
        _TsvStatus("Completed with errors", "error")
    }

    WebViewExec("tsvGenDone(" (allOk ? "true" : "false") ")")
}

; Helper: send a log line to the WebView
_TsvLog(msg, cls)
{
    WebViewExec("tsvGenLog(" _JsStr(msg) "," _JsStr(cls) ")")
}

; Helper: update the status text in the WebView
_TsvStatus(msg, cls)
{
    WebViewExec("tsvGenStatus(" _JsStr(msg) "," _JsStr(cls) ")")
}

; Helper: run a command and capture stdout+stderr, return {output, exitCode}
_RunCmdCapture(cmd, workDir)
{
    tmpFile := A_Temp "\poe2gh_cmd_" A_TickCount ".tmp"
    fullCmd := A_ComSpec ' /c "cd /d "' workDir '" && ' cmd ' >"' tmpFile '" 2>&1"'
    exitCode := RunWait(fullCmd, workDir, "Hide")
    output := ""
    if FileExist(tmpFile)
    {
        try output := FileRead(tmpFile, "UTF-8")
        try FileDelete(tmpFile)
    }
    return {output: output, exitCode: exitCode}
}
