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
    ; Strip any remaining control chars (NUL, BEL, ESC, …) that the StrReplace
    ; pairs above didn't catch — JSON spec forbids unescaped < 0x20 inside
    ; strings, and WebView2's JSON.parse rejects them, breaking the whole push.
    ; Rare in user input but happens when stale memory reads sneak garbage past
    ; the upstream validators (e.g. heuristic stash-name scanner).
    if RegExMatch(s, "[\x00-\x08\x0B\x0C\x0E-\x1F]")
        s := RegExReplace(s, "[\x00-\x08\x0B\x0C\x0E-\x1F]", "")
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
    global g_radarAlpha, g_mapHackEnabled, g_maphackSource, g_isConnected, g_rangeCirclesEnabled, g_panelDetectionEnabled
    global g_autoPilotEnabled, g_autoPilotState, g_autoPilotReason
    global g_inventoryChainDumpEnabled, g_overlayStatusTextEnabled, g_alwaysOnTop
    global g_cfgOpenSections
    global g_combatAutoEnabled, g_combatState, g_combatLastReason, g_combatToggleHotkey
    global g_combatRange, g_combatDisengageRange, g_combatGlobalCooldownMs, g_combatSkillSlots
    global g_exploreEnabled, g_exploreCurrentPercent, g_exploreTargetPercent, g_exploreLastReason
    global g_lootRarityNormal, g_lootRarityMagic, g_lootRarityRare
    global g_lootRarityUnique, g_lootRarityCurrency, g_lootCache, g_lootLastReason

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
          . '"alwaysOnTop":'    (g_alwaysOnTop ? "true" : "false") ","
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
          . '"maphackSource":' _JsStr(IsSet(g_maphackSource) ? g_maphackSource : "memory") ","
          . '"maphackOutlineHex":' _JsStr(IsSet(g_maphackOutlineHex) ? g_maphackOutlineHex : "8080FFCC") ","
          . '"maphackBackgroundHex":' _JsStr(IsSet(g_maphackBackgroundHex) ? g_maphackBackgroundHex : "66FF6619") ","
          . '"configSubTab":' _JsStr(IsSet(g_configSubTab) ? g_configSubTab : "general") ","
          . '"ggpkInstallPathKnown":' (GgpkToolBridge.HasCachedIndexPath() ? "true" : "false") ","
          . '"ggpkMaphackApplied":' (GgpkToolBridge.IsMaphackApplied() ? "true" : "false") ","
          . '"isConnected":' (IsSet(g_isConnected) && g_isConnected ? "true" : "false") ","
          . '"rangeCircles":' (g_rangeCirclesEnabled ? "true" : "false") ","
          . '"panelDetection":' (g_panelDetectionEnabled ? "true" : "false") ","
          . '"cfgSections":' _JsStr(g_cfgOpenSections) ","
          . '"autoPilot":' (g_autoPilotEnabled ? "true" : "false") ","
          . '"autoPilotState":' _JsStr(g_autoPilotState) ","
          . '"autoPilotReason":' _JsStr(g_autoPilotReason) ","
          . '"invChainDump":' (g_inventoryChainDumpEnabled ? "true" : "false") ","
          . '"overlayStatusText":' (g_overlayStatusTextEnabled ? "true" : "false") ","
          . '"combatAuto":' (g_combatAutoEnabled ? "true" : "false") ","
          . '"combatHotkey":' _JsStr(g_combatToggleHotkey) ","
          . '"combatState":' _JsStr(g_combatState) ","
          . '"combatReason":' _JsStr(g_combatLastReason) ","
          . '"combatRange":' g_combatRange ","
          . '"combatDisengage":' g_combatDisengageRange ","
          . '"combatGCD":' g_combatGlobalCooldownMs ","
          . '"combatW2S":' Format("{:.2f}", g_combatW2SScale) ","
          . '"combatSlots":' _SerializeCombatSlots() ","
          . '"exploreEnabled":' (g_exploreEnabled ? "true" : "false") ","
          . '"explorePct":' Format("{:.1f}", g_exploreCurrentPercent) ","
          . '"exploreTarget":' g_exploreTargetPercent ","
          . '"exploreReason":' _JsStr(g_exploreLastReason) ","
          . '"lootRarity":' _SerializeLootRarity() ","
          . '"lootCacheCount":' _GetLootCacheCount() ","
          . '"lootReason":' _JsStr(_GetLootLastReason()) ","
          . '"zoneScan":' _SerializeZoneScanStatus()
          . "}"
    WebViewExec("updateHeader(" json ")")
}

; Returns a JSON object with the five rarity-filter bits — the UI uses this
; to mirror the per-rarity checkboxes back when the header re-syncs (e.g.
; after a fresh page load).
_SerializeLootRarity()
{
    global g_lootRarityNormal, g_lootRarityMagic, g_lootRarityRare
    global g_lootRarityUnique, g_lootRarityCurrency
    return "{"
        . '"Normal":'   (g_lootRarityNormal   ? "true" : "false") ","
        . '"Magic":'    (g_lootRarityMagic    ? "true" : "false") ","
        . '"Rare":'     (g_lootRarityRare     ? "true" : "false") ","
        . '"Unique":'   (g_lootRarityUnique   ? "true" : "false") ","
        . '"Currency":' (g_lootRarityCurrency ? "true" : "false")
        . "}"
}

_GetLootCacheCount()
{
    global g_lootCache
    return (g_lootCache && Type(g_lootCache) = "Map") ? g_lootCache.Count : 0
}

_GetLootLastReason()
{
    global g_lootLastReason
    return g_lootLastReason ? g_lootLastReason : "idle"
}

; Serialises combat skill slots to a JSON array for the header push.
_SerializeCombatSlots()
{
    global g_combatSkillSlots
    json := "["
    first := true
    Loop 8
    {
        slotNum := A_Index
        if !g_combatSkillSlots.Has(slotNum)
            continue
        s := g_combatSkillSlots[slotNum]
        if !first
            json .= ","
        first := false
        json .= "{"
            . '"slot":' slotNum ","
            . '"enabled":' (s["enabled"] ? "true" : "false") ","
            . '"key":' _JsStr(s["key"]) ","
            . '"priority":' s["priority"] ","
            . '"skillName":' _JsStr(s.Has("skillName") ? s["skillName"] : "") ","
            . '"type":' _JsStr(s["type"]) ","
            . '"cooldownMs":' (s.Has("cooldownMs") ? s["cooldownMs"] : 0) ","
            . '"skillRange":' (s.Has("skillRange") ? s["skillRange"] : 0)
            . "}"
    }
    json .= "]"
    return json
}

; Serialises zone scan (maphack) status for the header push.
_SerializeZoneScanStatus()
{
    global g_reader
    if !(IsObject(g_reader))
        return '{"done":false,"inProgress":false,"elapsed":0,"timing":0,"tiles":0}'

    done       := g_reader._zoneScanDone
    inProgress := g_reader._tgtScanInProgress
    timing     := g_reader._zoneScanTimingMs
    tiles      := g_reader._zoneScanAccumulated.Count
    startedAt  := g_reader._zoneScanStartedAt
    retries    := g_reader._zoneScanRetries
    schedAt    := g_reader._zoneScanScheduledAt
    totalTiles := g_reader.HasOwnProp("_tgtScanTotalTiles") ? g_reader._tgtScanTotalTiles : 0
    tileIdx    := g_reader.HasOwnProp("_tgtScanTileIdx") ? g_reader._tgtScanTileIdx : 0
    failReason := g_reader.HasOwnProp("_zoneScanFailReason") ? g_reader._zoneScanFailReason : ""

    if (!done && startedAt > 0)
        elapsed := A_TickCount - startedAt
    else
        elapsed := timing

    return "{"
        . '"done":'       (done ? "true" : "false") ","
        . '"inProgress":' (inProgress ? "true" : "false") ","
        . '"elapsed":'    elapsed ","
        . '"timing":'     timing ","
        . '"tiles":'      tiles ","
        . '"retries":'    retries ","
        . '"totalTiles":' totalTiles ","
        . '"tileIdx":'    tileIdx ","
        . '"schedAt":'    (schedAt > 0 ? "true" : "false") ","
        . '"fail":'       _JsStr(failReason)
        . "}"
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

; Pushes the RadarOverlay's collected debug lines to the Debug tab.
; The lines (formerly drawn at the bottom of the game overlay) are now copyable
; in the WebView. Pushed every ~500 ms from UpdateRadarFast — runs always (not
; only when Render() ran) so a 'gate' line shows why the overlay is hidden.
PushRadarDebugToWebView(overlayAllowed := true, hideReason := "")
{
    global g_webViewReady, g_radarOverlay, g_radarReadMs, g_radarRenderMs
    if !g_webViewReady
        return

    ; Always include a gate line that shows allow/hide-reason — this updates
    ; even when Render() is skipped, so we can see WHY rendering stopped.
    if (g_radarOverlay && IsObject(g_radarOverlay._debugLines))
        g_radarOverlay._debugLines["gate"] := "gate: allowed=" (overlayAllowed ? "YES" : "NO")
            . (hideReason != "" ? " reason=" hideReason : "")

    json := "{"
    debugMode := (g_radarOverlay && g_radarOverlay.DebugMode) ? true : false
    json .= '"enabled":' (debugMode ? "true" : "false") ","
    json .= '"readMs":'   (IsSet(g_radarReadMs)   ? Integer(g_radarReadMs)   : 0) ","
    json .= '"renderMs":' (IsSet(g_radarRenderMs) ? Integer(g_radarRenderMs) : 0) ","
    json .= '"lines":['
    if (g_radarOverlay && IsObject(g_radarOverlay._debugLines))
    {
        ; Stable display order — gate at top so it's always at-a-glance
        order := ["gate", "status", "nav", "path", "mapL", "mapM", "entL", "entM", "fltL", "fltM"]
        first := true
        for _, key in order
        {
            if !g_radarOverlay._debugLines.Has(key)
                continue
            if !first
                json .= ","
            json .= '{"key":' _JsStr(key) ',"text":' _JsStr(g_radarOverlay._debugLines[key]) "}"
            first := false
        }
    }
    json .= "]}"
    try WebViewExec("updateRadarDebug(" json ")")
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

; Pushes saved panel offsets to the WebView for display in the Debug tab.
_PushSavedPanelOffsets()
{
    global g_webViewReady
    if !g_webViewReady
        return

    offsets := PoE2Offsets.DiscoveredPanelOffsets
    json := "["
    first := true
    for name, off in offsets
    {
        if !first
            json .= ","
        json .= '{"name":' _JsStr(name) ',"offset":' _JsStr(Format("0x{:X}", off)) '}'
        first := false
    }
    json .= "]"
    try WebViewExec("updateSavedPanelOffsets(" json ")")
}

; ── Inventory tab push ───────────────────────────────────────────────────
; Reads all player inventories (Backpack, Flasks, Trinkets, …) + best-effort
; stash scan, then pushes a JSON dump to the WebView's updateInventory() handler.
; Triggered on-demand from the UI when the Inventory tab is active — keeps the
; per-frame snapshot cost zero when the user isn't looking at the tab.
PushInventoryToWebView()
{
    global g_reader, g_radarLastSnap, g_webViewReady
    if !g_webViewReady
        return
    if !(IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle)
    {
        try WebViewExec("updateInventory(" _JsStr('{"error":"not-connected"}') ")")
        return
    }

    ; Resolve serverData + gameUi pointers on-demand. The Radar snapshot is a slim
    ; variant that omits both (it's optimized for per-frame entity/panel reads), so
    ; we walk the same pointer chain ReadAutoFlaskSnapshot uses — four extra RPMs
    ; that only run when the user has the Inventory tab open.
    snap     := IsObject(g_radarLastSnap) ? g_radarLastSnap : 0
    inGs     := (snap && snap.Has("inGameState")) ? snap["inGameState"] : 0
    area     := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    inGsAddr := (inGs && IsObject(inGs) && inGs.Has("address")) ? inGs["address"] : 0
    areaAddr := (area && IsObject(area) && area.Has("address")) ? area["address"] : 0

    if (!inGsAddr || !areaAddr)
    {
        try WebViewExec("updateInventory(" _JsStr('{"error":"no-server-data"}') ")")
        return
    }

    sdPtr  := 0
    gameUi := 0
    try
    {
        ; serverDataPtr: read raw pointer from playerInfo struct, then resolve via reader's
        ; own pointer-laundering helper (handles indirections + plausibility checks).
        playerInfoPtr    := areaAddr + PoE2Offsets.AreaInstance["PlayerInfo"]
        serverDataRawPtr := g_reader.Mem.ReadPtr(playerInfoPtr + PoE2Offsets.LocalPlayerStruct["ServerDataPtr"])
        sdPtr            := g_reader.ResolveServerDataPointer(playerInfoPtr, serverDataRawPtr)

        ; gameUiPtr: inGameState → UiRootStruct → GameUiPtr
        uiRootStructPtr  := g_reader.Mem.ReadPtr(inGsAddr + PoE2Offsets.InGameState["UiRootStructPtr"])
        if g_reader.IsProbablyValidPointer(uiRootStructPtr)
            gameUi := g_reader.Mem.ReadPtr(uiRootStructPtr + PoE2Offsets.UiRootStruct["GameUiPtr"])
    }
    catch as ex
        LogError("PushInventoryToWebView/resolve", ex)

    if (!sdPtr)
    {
        try WebViewExec("updateInventory(" _JsStr('{"error":"no-server-data"}') ")")
        return
    }

    ; Diagnostic: dump the full inventory pointer chain. Gated by the toggle
    ; on the Inventory tab toolbar — off by default because each dump does
    ; dozens of extra RPM reads, and most users don't care about the trace.
    ; Throttled to once per 2 s even when enabled.
    global g_inventoryChainDumpEnabled
    static _lastInvDump := 0
    if (g_inventoryChainDumpEnabled && (A_TickCount - _lastInvDump > 2000))
    {
        _lastInvDump := A_TickCount
        dumpResult := ""
        try
        {
            dumpResult := _DumpInventoryPointerChain(sdPtr, areaAddr, inGsAddr, gameUi)
        }
        catch as ex
        {
            LogError("PushInventoryToWebView/dump", ex)
            dumpResult := "EXCEPTION: " (ex.HasOwnProp("Message") ? ex.Message : "?")
        }
        ; Echo the result to the error log so the user can confirm the dump
        ; actually ran and find the exact file path. _DumpInventoryPointerChain
        ; returns the path it wrote to (or an error string if FileOpen failed).
        try LogError("InventoryChainDump " dumpResult)
    }

    ; ReadAllPlayerInventories already covers everything: backpack (id=1),
    ; equipped slots (id=2–11), flasks (id=12), and the currently open stash
    ; tab (id=27 — the game server populates this slot with whichever stash tab
    ; is visible, so no separate UI traversal is needed). The gameUi pointer is
    ; resolved above only to mirror future read paths; not used for stash now.
    invs := []
    try invs := g_reader.ReadAllPlayerInventories(sdPtr)
    catch as ex
        LogError("PushInventoryToWebView/player", ex)

    json := "{"
          . '"player":' _BuildInventoryArrayJson(invs)
          . "}"
    try WebViewExec("updateInventory(" _JsStr(json) ")")
}

; ── Memory-Diff RE tab push functions ────────────────────────────────────
; PushMemDiffStateToWebView — sends the current configuration + snapshot
; status (which slots are filled, last addresses, etc.). Triggered on every
; Configure / Before / Clear so the tab UI stays in sync.
;
; PushMemDiffResultToWebView — runs the diff and sends the run list to the
; UI's renderer. Called after an "After" snapshot.
PushMemDiffStateToWebView()
{
    global g_memDiffSymbol, g_memDiffCustomAddr, g_memDiffSize
    global g_memDiffBeforeBuf, g_memDiffBeforeAddr, g_memDiffBeforeTime
    global g_memDiffAfterBuf, g_memDiffAfterTime, g_memDiffStatus, g_webViewReady
    if !g_webViewReady
        return

    json := "{"
        . '"symbol":'      _JsStr(g_memDiffSymbol) ","
        . '"customAddr":'  _JsStr(Format("0x{:X}", g_memDiffCustomAddr)) ","
        . '"size":'        g_memDiffSize ","
        . '"beforeReady":' ((g_memDiffBeforeBuf && Type(g_memDiffBeforeBuf) = "Buffer") ? "true" : "false") ","
        . '"afterReady":'  ((g_memDiffAfterBuf  && Type(g_memDiffAfterBuf)  = "Buffer") ? "true" : "false") ","
        . '"beforeAddr":'  _JsStr(Format("0x{:X}", g_memDiffBeforeAddr)) ","
        . '"beforeAge":'   (g_memDiffBeforeTime > 0 ? (A_TickCount - g_memDiffBeforeTime) : 0) ","
        . '"afterAge":'    (g_memDiffAfterTime  > 0 ? (A_TickCount - g_memDiffAfterTime)  : 0) ","
        . '"status":'      _JsStr(g_memDiffStatus)
        . "}"
    try WebViewExec("updateMemDiffState(" _JsStr(json) ")")
}

PushMemDiffResultToWebView()
{
    global g_webViewReady
    if !g_webViewReady
        return

    ; State push first so the result tab knows the snapshot is "after-ok".
    PushMemDiffStateToWebView()

    result := MemDiffCompute()
    if (result["error"] != "")
    {
        try WebViewExec("updateMemDiffResult(" _JsStr('{"error":' _JsStr(result["error"]) ',"runs":[]}') ")")
        return
    }

    runs := result["runs"]
    runsJson := "["
    first := true
    for _, run in runs
    {
        if !first
            runsJson .= ","
        first := false
        decodeJson := "{"
        dFirst := true
        for k, v in run["decode"]
        {
            if !dFirst
                decodeJson .= ","
            dFirst := false
            ; v can be int or string ("0x..." for ptr fields). _JsStr quotes safely;
            ; for raw numerics we want them as JSON numbers so the UI can format.
            if (Type(v) = "String")
                decodeJson .= _JsStr(k) ":" _JsStr(v)
            else
                decodeJson .= _JsStr(k) ":" v
        }
        decodeJson .= "}"

        runsJson .= "{"
            . '"offset":' run["offset"] ","
            . '"length":' run["length"] ","
            . '"before":' _JsStr(run["before"]) ","
            . '"after":'  _JsStr(run["after"]) ","
            . '"decode":' decodeJson
            . "}"
    }
    runsJson .= "]"

    json := "{"
        . '"error":' _JsStr("") ","
        . '"totalChanged":' result["totalChanged"] ","
        . '"addrBefore":' _JsStr(Format("0x{:X}", result["addrBefore"])) ","
        . '"runCount":' runs.Length ","
        . '"runs":' runsJson
        . "}"
    try WebViewExec("updateMemDiffResult(" _JsStr(json) ")")
}

; ── Memory Dissector push ─────────────────────────────────────────────────
; Serializes the current dissector buffer as a JSON row array and calls
; updateMemDissect() in the WebView. Each row covers 8 bytes at increasing
; offsets from the base address. Decodes: u8/u16/i32/u32/f32/i64/ptr/f64/ascii.
; Rows whose ptr value looks like a valid heap address have isPtr=true so the
; UI can render them as clickable links for dereferencing.
PushMemDissectToWebView()
{
    global g_reader, g_memDissectAddress, g_memDissectSize, g_memDissectBuf
    global g_memDissectHistory, g_memDissectFwd, g_memDissectStatus, g_webViewReady
    if !g_webViewReady
        return

    ; Hard try/catch around the entire serialization — any NumGet on a buffer
    ; that was concurrently released, a malformed JSON build, or a transient
    ; reader-state issue must NOT escape into the SetTimer thread, where AHK
    ; would surface it as a blocking "critical error" dialog. We always send
    ; a status JSON to the WebView so the UI updates even on failure.
    try
    {
        json := _BuildMemDissectJson()
    }
    catch as ex
    {
        msg := ex.HasOwnProp("Message") ? ex.Message : "?"
        try LogError("PushMemDissectToWebView exception: " msg)
        g_memDissectStatus := "render-exception: " msg
        ; Build a minimal status-only payload so the UI shows something useful
        ; rather than going dark when the render path blows up.
        json := "{"
            . '"addr":'    _JsStr(g_memDissectAddress ? Format("0x{:X}", g_memDissectAddress) : "") ","
            . '"size":'    g_memDissectSize ","
            . '"status":'  _JsStr(g_memDissectStatus) ","
            . '"canBack":' (g_memDissectHistory.Length > 0 ? "true" : "false") ","
            . '"canFwd":'  (g_memDissectFwd.Length  > 0 ? "true" : "false") ","
            . '"rows":[]}'
    }

    try WebViewExec("updateMemDissect(" _JsStr(json) ")")
}

; Internal: build the full dissector JSON payload. May throw — the caller is
; responsible for catching and falling back to a status-only payload.
_BuildMemDissectJson()
{
    global g_reader, g_memDissectAddress, g_memDissectSize, g_memDissectBuf
    global g_memDissectHistory, g_memDissectFwd, g_memDissectStatus

    baseAddr := g_memDissectAddress
    buf      := g_memDissectBuf
    canRead  := (IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle)

    json := "{"
        . '"addr":'    _JsStr(baseAddr ? Format("0x{:X}", baseAddr) : "") ","
        . '"size":'    g_memDissectSize ","
        . '"status":'  _JsStr(g_memDissectStatus) ","
        . '"canBack":' (g_memDissectHistory.Length > 0 ? "true" : "false") ","
        . '"canFwd":'  (g_memDissectFwd.Length  > 0 ? "true" : "false") ","
        . '"rows":['

    if (buf && Type(buf) = "Buffer" && baseAddr && buf.Size >= 8)
    {
        bufPtr  := buf.Ptr      ; snapshot Ptr+Size up front so concurrent reassignments
        bufSize := buf.Size     ;  to g_memDissectBuf can't make us read off the end.
        stride  := 8
        maxRows := bufSize // stride
        first   := true
        r := 0
        while (r < maxRows)
        {
            off := r * stride
            if (off + stride > bufSize)
                break

            ; Each row is wrapped: a single bad NumGet on a freed buffer must
            ; not cancel the entire push — log it and skip that row.
            rowOk := true
            try
            {
                ; Raw bytes hex string (8 bytes)
                rawHex := ""
                jj := 0
                while (jj < stride)
                {
                    rawHex .= Format("{:02X} ", NumGet(bufPtr, off + jj, "UChar"))
                    jj += 1
                }
                rawHex := RTrim(rawHex)

                ; Numeric decodes
                u8v   := NumGet(bufPtr, off, "UChar")
                u16v  := NumGet(bufPtr, off, "UShort")
                i32v  := NumGet(bufPtr, off, "Int")
                u32v  := NumGet(bufPtr, off, "UInt")
                f32v  := Round(NumGet(bufPtr, off, "Float"), 4)
                i64v  := NumGet(bufPtr, off, "Int64")
                ptrHex := Format("0x{:X}", i64v & 0xFFFFFFFFFFFFFFFF)
                f64v  := Round(NumGet(bufPtr, off, "Double"), 6)

                ascii := ""
                kk := 0
                while (kk < stride)
                {
                    ch := NumGet(bufPtr, off + kk, "UChar")
                    ascii .= (ch >= 32 && ch < 127) ? Chr(ch) : "."
                    kk += 1
                }
            }
            catch
            {
                rowOk := false
            }
            if !rowOk
            {
                r += 1
                continue
            }

            ; Pointer heuristic — pure range check, NO live RPM read.
            ; IsProbablyValidPointer was previously called here, but it issues
            ; an extra ReadProcessMemory per row. When the main update loop
            ; was already mid-RPM (deep in PoE2EntityReader), the resulting
            ; concurrent RPM/NumGet pattern occasionally surfaced as a
            ; Windows SEH "Invalid memory read/write" — uncatchable by AHK
            ; try/catch. The dereference click handler still validates the
            ; address fresh when the user actually follows a pointer, so a
            ; false-positive clickable here at worst yields a "read-failed"
            ; status on the next page — never a crash.
            isPtr := "false"
            ; Windows x64 user-mode heap pointers are typically aligned and
            ; sit in the 0x000001'00000000 … 0x00007FFF'FFFFFFFF range.
            if (canRead && i64v > 0x10000 && i64v < 0x00007FFFFFFFFFFF
                && Mod(i64v, 8) = 0)
                isPtr := "true"

            if !first
                json .= ","
            first := false

            absAddr := Format("0x{:X}", baseAddr + off)

            json .= "{"
                . '"off":'    off ","
                . '"addr":'   _JsStr(absAddr) ","
                . '"hex":'    _JsStr(rawHex) ","
                . '"u8":'     u8v ","
                . '"u16":'    u16v ","
                . '"i32":'    i32v ","
                . '"u32":'    u32v ","
                . '"f32":'    f32v ","
                . '"i64":'    i64v ","
                . '"ptr":'    _JsStr(ptrHex) ","
                . '"f64":'    f64v ","
                . '"ascii":'  _JsStr(ascii) ","
                . '"isPtr":'  isPtr
                . "}"

            r += 1
        }
    }

    json .= "]}"
    return json
}

; ── Inventory pointer-chain diagnostic dump ─────────────────────────────
; Walks every memory hop the inventory reader uses and writes a hierarchical
; trace to inventory_chain.log (overwriting on each call). Used as a
; reference when investigating layout offsets or missing inventories.
;
; The dump traverses:
;   ServerData
;     → PlayerServerData std::vector (offset 0x48)
;       → PlayerData[0]
;         → PlayerInventories std::vector (offset 0x320)
;           → InventoryArrayStruct (id + ptr0 + ptr1)
;             → InventoryStruct (totalBoxes + ItemList vec)
;               → InventoryItemStruct (slot coords + item entity ptr)
;                 → Entity (EntityDetailsPtr + ComponentsVec + Id/Flags)
;                   → EntityDetails (Path string)
;
; Items capped at 5 per inventory to keep the file readable; a "+N more"
; suffix indicates additional items not shown.
_DumpInventoryPointerChain(sdPtr, areaAddr, inGsAddr, gameUiPtr)
{
    global g_reader
    if !(IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle)
        return "skipped: reader-not-connected"

    mem := g_reader.Mem
    out := "=== INVENTORY POINTER CHAIN DUMP @ " FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") " ==="
    out .= "`n"
    out .= "`nResolved roots (from snapshot + on-demand resolution):"
    out .= "`n  InGameState:  " _FmtChainHex(inGsAddr)
    out .= "`n  AreaInstance: " _FmtChainHex(areaAddr)
    out .= "`n  ServerData:   " _FmtChainHex(sdPtr) "  (after ResolveServerDataPointer)"
    out .= "`n  GameUi:       " _FmtChainHex(gameUiPtr)
    out .= "`n"

    ; ── Step 1: ServerData → PlayerServerData std::vector ──────────────
    psdOff      := PoE2Offsets.ServerData["PlayerServerData"]
    psdVecFirst := mem.ReadInt64(sdPtr + psdOff)
    psdVecLast  := mem.ReadInt64(sdPtr + psdOff + 8)
    out .= "`n[Step 1] ServerData + 0x" Format("{:X}", psdOff) " → PlayerServerData std::vector"
    out .= "`n  First: " _FmtChainHex(psdVecFirst)
    out .= "`n  Last:  " _FmtChainHex(psdVecLast)

    if (psdVecFirst <= 0 || psdVecLast < psdVecFirst)
        return _WriteChainLog(out . "`n  [bailing — empty / invalid vector]`n")

    ; ── Step 2: PlayerServerData[0] → PlayerData pointer ───────────────
    playerDataPtr := mem.ReadPtr(psdVecFirst)
    out .= "`n"
    out .= "`n[Step 2] PlayerServerData[0] → PlayerData ptr"
    out .= "`n  " _FmtChainHex(playerDataPtr)

    if !g_reader.IsProbablyValidPointer(playerDataPtr)
        return _WriteChainLog(out . "`n  [bailing — invalid PlayerData ptr]`n")

    ; ── Step 3: PlayerData → PlayerInventories std::vector ─────────────
    piOff   := PoE2Offsets.ServerDataStructure["PlayerInventories"]
    piFirst := mem.ReadInt64(playerDataPtr + piOff)
    piLast  := mem.ReadInt64(playerDataPtr + piOff + 8)
    entrySz := PoE2Offsets.InventoryArray["EntrySize"]
    invCount := (piFirst > 0 && piLast >= piFirst) ? Floor((piLast - piFirst) / entrySz) : 0
    out .= "`n"
    out .= "`n[Step 3] PlayerData + 0x" Format("{:X}", piOff) " → PlayerInventories std::vector"
    out .= "`n  First:    " _FmtChainHex(piFirst)
    out .= "`n  Last:     " _FmtChainHex(piLast)
    out .= "`n  EntrySize: 0x" Format("{:X}", entrySz)
    out .= "`n  Count:    " invCount

    if (invCount <= 0)
        return _WriteChainLog(out . "`n  [bailing — empty inventories]`n")

    ; ── Step 4+: per-inventory dump ────────────────────────────────────
    out .= "`n"
    out .= "`n[Step 4] Iterating InventoryArrayStruct entries (capped at 128):"
    maxInv := Min(invCount, 128)
    idx := 0
    while (idx < maxInv)
    {
        entryAddr := piFirst + (idx * entrySz)
        invId   := mem.ReadInt(entryAddr + PoE2Offsets.InventoryArray["InventoryId"])
        invPtr0 := mem.ReadPtr(entryAddr + PoE2Offsets.InventoryArray["InventoryPtr0"])
        invPtr1 := mem.ReadPtr(entryAddr + PoE2Offsets.InventoryArray["InventoryPtr1"])

        out .= "`n"
        out .= "`n  ── Inventory[" idx "] @ " _FmtChainHex(entryAddr) " ──"
        out .= "`n    id=" invId
        out .= "`n    ptr0=" _FmtChainHex(invPtr0)
        out .= "`n    ptr1=" _FmtChainHex(invPtr1)
        idx += 1

        if !g_reader.IsProbablyValidPointer(invPtr0)
        {
            out .= "`n    [skip — invalid ptr0]"
            continue
        }

        ; InventoryStruct fields
        tbX := mem.ReadInt(invPtr0 + PoE2Offsets.Inventory["TotalBoxes"])
        tbY := mem.ReadInt(invPtr0 + PoE2Offsets.Inventory["TotalBoxesY"])
        ilF := mem.ReadInt64(invPtr0 + PoE2Offsets.Inventory["ItemList"])
        ilL := mem.ReadInt64(invPtr0 + PoE2Offsets.Inventory["ItemListLast"])
        itemCount := (ilF > 0 && ilL >= ilF) ? Floor((ilL - ilF) / A_PtrSize) : 0
        out .= "`n    InventoryStruct:"
        out .= "`n      totalBoxes:   " tbX " × " tbY
        out .= "`n      ItemList vec: First=" _FmtChainHex(ilF) " Last=" _FmtChainHex(ilL) " count=" itemCount

        if (itemCount <= 0)
            continue

        ; Per-item dump — first 5 only
        maxItems := Min(itemCount, 5)
        itemIdx := 0
        while (itemIdx < maxItems)
        {
            invItemStructPtr := mem.ReadPtr(ilF + (itemIdx * A_PtrSize))
            out .= "`n      Item[" itemIdx "]: structPtr=" _FmtChainHex(invItemStructPtr)

            if !g_reader.IsProbablyValidPointer(invItemStructPtr)
            {
                out .= " [invalid]"
                itemIdx += 1
                continue
            }

            itemEntityPtr := mem.ReadPtr(invItemStructPtr + PoE2Offsets.InventoryItem["Item"])
            sx := mem.ReadInt(invItemStructPtr + PoE2Offsets.InventoryItem["SlotStart"])
            sy := mem.ReadInt(invItemStructPtr + PoE2Offsets.InventoryItem["SlotStartY"])
            ex2 := mem.ReadInt(invItemStructPtr + PoE2Offsets.InventoryItem["SlotEnd"])
            ey := mem.ReadInt(invItemStructPtr + PoE2Offsets.InventoryItem["SlotEndY"])
            out .= " slot=(" sx "," sy ")→(" ex2 "," ey ")"
            out .= "`n        entityPtr: " _FmtChainHex(itemEntityPtr)

            if g_reader.IsProbablyValidPointer(itemEntityPtr)
            {
                edPtr   := mem.ReadPtr(itemEntityPtr + PoE2Offsets.Entity["EntityDetailsPtr"])
                cvFirst := mem.ReadInt64(itemEntityPtr + PoE2Offsets.Entity["ComponentsVec"])
                cvLast  := mem.ReadInt64(itemEntityPtr + PoE2Offsets.Entity["ComponentsVecLast"])
                eid     := mem.ReadUInt(itemEntityPtr + PoE2Offsets.Entity["Id"])
                flags   := mem.ReadUChar(itemEntityPtr + PoE2Offsets.Entity["Flags"])
                compCnt := (cvFirst > 0 && cvLast >= cvFirst) ? Floor((cvLast - cvFirst) / A_PtrSize) : 0
                out .= "`n        Entity: id=" eid " flags=0x" Format("{:02X}", flags)
                out .= "`n          EntityDetailsPtr: " _FmtChainHex(edPtr)
                out .= "`n          ComponentsVec:    First=" _FmtChainHex(cvFirst) " Last=" _FmtChainHex(cvLast) " count=" compCnt

                if g_reader.IsProbablyValidPointer(edPtr)
                {
                    try
                    {
                        path := g_reader.ReadStdWStringAt(edPtr + PoE2Offsets.EntityDetails["Path"], 260)
                        if (path != "")
                            out .= "`n          path: " path
                    }
                }
            }
            itemIdx += 1
        }
        if (itemCount > maxItems)
            out .= "`n      … +" (itemCount - maxItems) " more items not shown"
    }

    out .= "`n"
    out .= "`n=== END OF DUMP ===`n"
    return _WriteChainLog(out)
}

; Helper: pointer formatting for the chain log. "0" for null so the
; hierarchy stays scannable.
_FmtChainHex(addr)
{
    if (!addr)
        return "0"
    return "0x" Format("{:X}", addr)
}

; Helper: overwrites the chain log file with a fresh snapshot. Returns
; the absolute path that was written (or an error string) so the caller
; can echo it into the regular error log — that way the user can locate
; the dump file even if A_ScriptDir resolved somewhere unexpected.
;
; Filename mirrors the error log convention (`InGameStateMonitor.X.log`)
; so all diagnostic outputs live with the same prefix.
_WriteChainLog(text)
{
    path := A_ScriptDir "\InGameStateMonitor.inventory_chain.log"
    try
    {
        f := FileOpen(path, "w", "UTF-8")
        if !f
            return "FileOpen-failed path=" path
        f.Write(text)
        f.Close()
        return "wrote " StrLen(text) " chars to " path
    }
    catch as ex
    {
        return "FileOpen-exception path=" path " msg=" (ex.HasOwnProp("Message") ? ex.Message : "?")
    }
}

; Serialises an array of inventory Maps (from ReadAllPlayerInventories /
; ReadStashInventories) into a compact JSON array consumed by the Inventory tab.
_BuildInventoryArrayJson(invs)
{
    json := "["
    first := true
    if !(invs && Type(invs) = "Array")
        return "[]"
    for _, inv in invs
    {
        if !(inv && Type(inv) = "Map")
            continue
        if !first
            json .= ","
        first := false
        invId   := inv.Has("inventoryId") ? Integer(inv["inventoryId"]) : -1
        boxX    := inv.Has("totalBoxesX") ? Integer(inv["totalBoxesX"]) : 0
        boxY    := inv.Has("totalBoxesY") ? Integer(inv["totalBoxesY"]) : 0
        source  := inv.Has("source")   ? String(inv["source"])   : ""
        tabName := inv.Has("tabName")  ? String(inv["tabName"])  : ""
        items   := inv.Has("items") ? inv["items"] : []

        ; PoE2's inventory ItemList is cell-based: a 2×3 body armor produces
        ; 6 entries that all point to the same itemEntityPtr with identical
        ; slotStart/End rectangles. The UI grid renderer happens to overlap
        ; them visually so it "looks right", but the count in the section
        ; header reports raw-entry count (9 for 3 items in 9 cells), which
        ; is misleading. Dedupe here by itemEntityPtr — with a slot-rect
        ; fallback when ptr is missing — so the JSON we send to the UI has
        ; one entry per actual item.
        seenItemKeys := Map()
        itemsJson := "["
        itemFirst := true
        for _, it in items
        {
            if !(it && Type(it) = "Map")
                continue
            d := it.Has("details") ? it["details"] : 0
            if !(d && Type(d) = "Map")
                continue
            iep := it.Has("itemEntityPtr") ? it["itemEntityPtr"] : 0
            isx := it.Has("slotStartX") ? it["slotStartX"] : 0
            isy := it.Has("slotStartY") ? it["slotStartY"] : 0
            iex := it.Has("slotEndX")   ? it["slotEndX"]   : isx
            iey := it.Has("slotEndY")   ? it["slotEndY"]   : isy
            dedupKey := iep ? ("p:" iep) : ("r:" isx "," isy "," iex "," iey)
            if seenItemKeys.Has(dedupKey)
                continue
            seenItemKeys[dedupKey] := true
            if !itemFirst
                itemsJson .= ","
            itemFirst := false
            name   := d.Has("displayName") ? String(d["displayName"]) : ""
            base   := d.Has("baseType")    ? String(d["baseType"])    : ""
            rarId  := d.Has("rarityId")    ? Integer(d["rarityId"])   : -1
            stkCnt := d.Has("stackCount")  ? Integer(d["stackCount"]) : 0
            modsJson := _BuildItemModsJson(d.Has("modsInfo") ? d["modsInfo"] : 0)
            itemsJson .= "{"
                . '"sx":'  Integer(it["slotStartX"]) ","
                . '"sy":'  Integer(it["slotStartY"]) ","
                . '"ex":'  Integer(it["slotEndX"])   ","
                . '"ey":'  Integer(it["slotEndY"])   ","
                . '"n":'   _JsStr(name) ","
                . '"b":'   _JsStr(base) ","
                . '"r":'   rarId        ","
                . '"s":'   stkCnt       ","
                . '"m":'   modsJson
                . "}"
        }
        itemsJson .= "]"

        json .= "{"
            . '"id":'    invId  ","
            . '"bx":'    boxX   ","
            . '"by":'    boxY   ","
            . '"src":'   _JsStr(source) ","
            . '"tn":'    _JsStr(tabName) ","
            . '"items":' itemsJson
            . "}"
    }
    return json . "]"
}

; Flattens an item's mod data into a JSON array of { c: category, t: text } objects
; for the inventory tooltip.
;
; PRIMARY path: use the aggregated StatsFromMods (statKey, statValue) list. The
; component exposes this as a flat (key, value) vector — same shape as player
; stats — so the existing FormatStatEntry pipeline (stat_desc_map templates +
; multi-stat sibling resolution) produces lines like "+38 to Spirit" identical
; to what the GameState tab shows for the player.
;
; FALLBACK path: when StatsFromMods is empty (e.g. read failed, or some items
; with no aggregated stat list), fall back to per-mod affix names + roll values
; so the user still sees something.
_BuildItemModsJson(modsInfo)
{
    if !(modsInfo && Type(modsInfo) = "Map")
        return "[]"

    out := "["
    first := true

    ; ── Primary: aggregated StatsFromMods rendered via stat_desc_map templates ──
    statsFromMods := modsInfo.Has("statsFromMods") ? modsInfo["statsFromMods"] : 0
    if (statsFromMods && Type(statsFromMods) = "Array" && statsFromMods.Length > 0)
    {
        ; BuildStatSiblingContext populates the global Map FormatStatEntry uses
        ; for multi-stat templates ("Adds X to Y damage" etc.). Scoping it to
        ; THIS item's stats means siblings resolve against the right values.
        BuildStatSiblingContext(statsFromMods)
        for _, pair in statsFromMods
        {
            if !(pair && Type(pair) = "Map" && pair.Has("key") && pair.Has("value"))
                continue
            text := FormatStatEntry(pair["key"], pair["value"])
            if (text = "")
                continue
            if !first
                out .= ","
            first := false
            ; All item stats share one category — implicit/explicit grouping
            ; isn't preserved in the aggregated list, and the in-game tooltip
            ; renders them as one flat block too.
            out .= "{"
                . '"c":' _JsStr("explicit") ","
                . '"t":' _JsStr(text)
                . "}"
        }
        ClearStatSiblingContext()
        return out . "]"
    }

    ; ── Fallback: per-mod affix + roll values when no aggregated stats ──
    for _, entry in [
        Map("key", "implicitMods", "cat", "implicit"),
        Map("key", "enchantMods",  "cat", "enchant"),
        Map("key", "explicitMods", "cat", "explicit")]
    {
        arr := modsInfo.Has(entry["key"]) ? modsInfo[entry["key"]] : 0
        if !(arr && Type(arr) = "Array")
            continue
        for _, m in arr
        {
            if !(m && Type(m) = "Map")
                continue
            lines := _FormatModLines(m)
            for _, line in lines
            {
                if (line = "")
                    continue
                if !first
                    out .= ","
                first := false
                out .= "{"
                    . '"c":' _JsStr(entry["cat"]) ","
                    . '"t":' _JsStr(line)
                    . "}"
            }
        }
    }
    return out . "]"
}

; Resolves one mod entry to a single human-readable line.
; Format: "<tier> <Affix> (val0[, val1[, val2…]])" — uses what's reliably
; readable from the per-item mod struct: the affix display name, optional tier
; word, and ALL roll values from the mod's Values vector.
;
; Full templated rendering (e.g. "+38 to Spirit") needs the stat-ID list from
; the Mods.dat row, which isn't in PoE2Offsets yet. See the TODO in
; PoE2InventoryReader.ReadModArrayFromVector.
;
; Returns: Array of strings (currently always 0 or 1 entries — the API supports
; multiple lines for when template rendering lands later).
_FormatModLines(m)
{
    lines := []
    affix := m.Has("displayName") ? String(m["displayName"]) : ""
    name  := m.Has("name")        ? String(m["name"])        : ""

    ; Note: a `modFamily` field is also present on each mod Map (game
    ; exclusion-group label like "IncreasedLife"). It is deliberately
    ; NOT used in the rendered label — it's an internal grouping id,
    ; not a human-readable tier word.
    label := (affix != "") ? affix : name
    if (label = "")
        return lines

    ; Build the value annotation from every roll the mod carries.
    valStr := ""
    values := m.Has("values") ? m["values"] : 0
    if (values && Type(values) = "Array" && values.Length > 0)
    {
        parts := []
        for _, v in values
        {
            n := _SafeNumStr(v)
            if (n != "")
                parts.Push(n)
        }
        if (parts.Length > 0)
        {
            joined := ""
            for i, p in parts
                joined .= (i = 1 ? "" : ", ") . p
            valStr := " (" joined ")"
        }
    }
    else
    {
        ; Legacy single-value fallback for entries that pre-date the values[] field.
        v0 := _SafeNumStr(m.Has("value0") ? m["value0"] : "")
        if (v0 != "")
            valStr := " (" v0 ")"
    }

    lines.Push(label . valStr)
    return lines
}

; Tolerant numeric → string conversion. Used for mod roll values which can be
; ints from a successful memory read, or empty strings when the slot has no
; value. Returns "" so the caller can decide whether to skip.
_SafeNumStr(v)
{
    if (Type(v) = "Integer" || Type(v) = "Float")
        return String(v)
    s := Trim(String(v))
    return (s = "" || !RegExMatch(s, "^-?\d+$")) ? "" : s
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
