; BridgeDispatch.ahk
; Routes incoming JS→AHK bridge calls to the appropriate handler functions.
; Called from OnWebMessage when the WebView posts {method, args} JSON.
;
; Included by InGameStateMonitor.ahk

; Dispatches a JS→AHK bridge call by method name.
; Each case delegates to the appropriate handler, typically via SetTimer(-1) to avoid
; blocking the WebView message thread.
_DispatchBridgeCall(method, args)
{
    global g_radarShowEnemyNormal, g_radarShowEnemyRare, g_radarShowEnemyBoss
    global g_radarShowMinions, g_radarShowNpcs, g_radarShowChests
    global g_pinnedNodePaths, g_selectedNodePath, g_radarEnabled, g_highlightedEntityPath
    global g_skillBuffBlacklist

    switch method
    {
        case "PageReady":
            ; No-op: NavigationCompleted already handles initial push
        case "ToggleRadar":
            SetTimer(ToggleRadar, -1)
        case "TogglePlayerHud":
            SetTimer(TogglePlayerHud, -1)
        case "ToggleDebug":
            SetTimer(ToggleDebugMode, -1)
        case "TogglePause":
            SetTimer(ToggleUpdatesPause, -1)
        case "ToggleAutoFlask":
            SetTimer(ToggleAutoFlaskMode, -1)
        case "ToggleAutoFlaskPerf":
            SetTimer(ToggleAutoFlaskPerformanceMode, -1)
        case "SwitchTab":
            key := (args.Length >= 1) ? args[1] : ""
            if (key != "")
                SetTimer(() => SwitchTreeTab(key), -1)
        case "RequestHotkeys":
            SetTimer(PushHotkeysToWebView, -1)
            SetTimer(PushHotkeyBindingsToWebView, -1)
        case "SetHotkeysConfig":
            cfg := (args.Length >= 1) ? args[1] : ""
            if (cfg != "")
                SetTimer(() => _ApplyHotkeysConfigFromUI(cfg), -1)
        case "SetHotkeyOneShot":
            osv := (args.Length >= 1) ? args[1] : 0
            bos := (osv = "true" || osv = true || osv = 1) ? true : false
            SetTimer(() => _SetHotkeyOneShot(bos), -1)
        case "ExportHotkeysItem":
            ekind := (args.Length >= 1) ? args[1] : ""
            ename := (args.Length >= 2) ? args[2] : ""
            ejson := (args.Length >= 3) ? args[3] : ""
            if (ejson != "")
                SetTimer(() => _ExportHotkeysItem(ekind, ename, ejson), -1)
        case "ImportHotkeysGroup":
            SetTimer(_ImportHotkeysGroup, -1)
        case "ImportHotkeysAction":
            igi := (args.Length >= 1) ? (args[1] + 0) : -1
            ihi := (args.Length >= 2) ? (args[2] + 0) : -1
            if (igi >= 0 && ihi >= 0)
                SetTimer(() => _ImportHotkeysAction(igi, ihi), -1)
        case "SetThresholds":
            life := (args.Length >= 1) ? args[1] : ""
            mana := (args.Length >= 2) ? args[2] : ""
            SetTimer(() => ApplyThresholdsFromUI(life, mana), -1)
        case "SetEntityFilter":
            etype := (args.Length >= 1) ? args[1] : ""
            val := (args.Length >= 2) ? args[2] : 0
            bval := (val = "true" || val = true || val = 1) ? true : false
            SetTimer(() => _ApplyEntityFilter(etype, bval), -1)
        case "SetRadarFilter":
            type := (args.Length >= 1) ? args[1] : ""
            val := (args.Length >= 2) ? args[2] : 0
            bval := (val = "true" || val = true || val = 1) ? true : false
            switch type
            {
                case "normal": g_radarShowEnemyNormal := bval
                case "rare": g_radarShowEnemyRare := bval
                case "boss": g_radarShowEnemyBoss := bval
                case "minions": g_radarShowMinions := bval
                case "npcs": g_radarShowNpcs := bval
                case "chests": g_radarShowChests := bval
            }
            SetTimer(SaveConfig, -100)
        case "PinPath":
            path := (args.Length >= 1) ? args[1] : ""
            if (path != "")
            {
                for _, p in g_pinnedNodePaths
                    if (p = path)
                        return
                g_pinnedNodePaths.Push(path)
                SetTimer(PushWatchlistToWebView, -1)
                SetTimer(PushHeaderToWebView, -50)
            }
        case "PinSelected":
            if (g_selectedNodePath != "")
                _DispatchBridgeCall("PinPath", [g_selectedNodePath])
        case "SelectNode":
            g_selectedNodePath := (args.Length >= 1) ? args[1] : ""
        case "ClearPins":
            g_pinnedNodePaths := []
            SetTimer(PushWatchlistToWebView, -1)
            SetTimer(PushHeaderToWebView, -50)
        case "RemovePinnedSelected":
            newList := []
            for _, p in g_pinnedNodePaths
                if (p != g_selectedNodePath)
                    newList.Push(p)
            g_pinnedNodePaths := newList
            SetTimer(PushWatchlistToWebView, -1)
            SetTimer(PushHeaderToWebView, -50)
        case "DumpEntities":
            SetTimer(OnDumpEntitiesClicked, -1)
        case "DumpAtlas":
            SetTimer(OnDumpAtlasClicked, -1)
        case "HighlightEntity":
            g_highlightedEntityPath := (args.Length >= 1) ? args[1] : ""
        case "ClearEntityHighlight":
            g_highlightedEntityPath := ""
        case "SetGroups":
            _ApplyEntityGroups((args.Length >= 1) ? args[1] : 0)
            SaveEntityGroups()
            SetTimer(PushHeaderToWebView, -50)
        case "SetAlert":
            if (args.Length >= 2)
                _ApplyAlertSetting(args[1], args[2])
            SaveEntityAlertsConfig()
            SetTimer(PushHeaderToWebView, -50)
        case "SetVitals":
            _ApplyVitals((args.Length >= 1) ? args[1] : 0)
            SaveVitalsConfig()
            SetTimer(PushHeaderToWebView, -50)
        case "ToggleVitalsEdit":
            ToggleVitalsEditMode((args.Length >= 1) ? args[1] : "")
            SetTimer(PushHeaderToWebView, -50)
        case "DecodeComponent":
            ; Lazy-decode a single component for the Entity Inspector. The
            ; radar fast-path skips Stats/Buffs/Actor/Animated/StateMachine
            ; etc. for cost reasons; this handler runs the full decoder
            ; on request when the user expands an undecoded row.
            ; args: [entityAddrHex, componentName, componentAddrHex]
            if (args.Length >= 3)
                SetTimer(() => _DecodeComponentOnDemand(args[1], args[2], args[3]), -1)
        case "ToggleZoneNav":
            global g_zoneNavEnabled
            g_zoneNavEnabled := !g_zoneNavEnabled
            ; RadarOverlay reads g_zoneNavEnabled itself each frame (_SyncConfig).
            SetTimer(SaveConfig, -100)
        case "ToggleMapHack":
            global g_mapHackEnabled
            g_mapHackEnabled := !g_mapHackEnabled
            ; RadarOverlay reads g_mapHackEnabled itself each frame (_SyncConfig).
            SetTimer(SaveConfig, -100)
            SetTimer(PushHeaderToWebView, -50)
        case "SetMaphackSource":
            ; args[1] = "memory" | "ggpk". Anything else falls back to memory.
            global g_maphackSource, g_radarOverlay, g_mapHackEnabled
            newSrc := (args.Length >= 1 && args[1] = "ggpk") ? "ggpk" : "memory"
            g_maphackSource := newSrc
            ; The overlay only renders the memory-based maphack when its
            ; mode is "memory" AND the toggle is on. Mirror state down so
            ; switching the source instantly stops drawing the overlay.
            if (g_radarOverlay)
                g_radarOverlay._mapHackEnabled := (g_mapHackEnabled && newSrc = "memory")
            SetTimer(SaveConfig, -100)
            SetTimer(PushHeaderToWebView, -50)
        case "SetMaphackColor":
            ; args[1] = "outline" | "background"
            ; args[2] = 8-char RRGGBBAA hex (with or without leading '#')
            ; Stores the value in the matching global + persists via
            ; SaveConfig. Does NOT re-apply the GGPK patch — that's the
            ; user's explicit action via the Apply button. Header-push
            ; mirrors the new value back to the UI so other open color
            ; swatches stay in sync.
            global g_maphackOutlineHex, g_maphackBackgroundHex
            if (args.Length >= 2)
            {
                which := args[1]
                hex   := _NormalizeHex8(args[2], "")
                if (hex != "")
                {
                    if (which = "outline")
                        g_maphackOutlineHex := hex
                    else if (which = "background")
                        g_maphackBackgroundHex := hex
                    SetTimer(SaveConfig, -100)
                    SetTimer(PushHeaderToWebView, -50)
                }
            }
        case "SetConfigSubTab":
            ; args[1] = one of general / automation / overlay / vitals / ggpk /
            ; filters / debug. Anything else is silently ignored so a
            ; bad WebView call can't corrupt the persisted value.
            global g_configSubTab
            if (args.Length >= 1)
            {
                v := args[1]
                if (v = "general" || v = "automation" || v = "overlay"
                    || v = "vitals" || v = "ggpk" || v = "filters" || v = "debug")
                {
                    g_configSubTab := v
                    SetTimer(SaveConfig, -100)
                }
            }
        case "ToggleRangeCircles":
            global g_rangeCirclesEnabled
            g_rangeCirclesEnabled := !g_rangeCirclesEnabled
            ; RadarOverlay reads g_rangeCirclesEnabled itself each frame (_SyncConfig).
            SetTimer(SaveConfig, -100)
        case "ToggleAutoPilot":
            global g_autoPilotEnabled, g_autoPilotState, g_autoPilotReason
            global g_combatAutoEnabled, g_exploreEnabled
            global g_combatState, g_combatLastReason, g_exploreLastReason
            g_autoPilotEnabled := !g_autoPilotEnabled
            ; The user-facing toggle is now AutoPilot. Mirror the legacy
            ; sub-flags so combat + exploration save/load + status displays
            ; stay consistent. These flags are no longer user-controllable.
            g_combatAutoEnabled := g_autoPilotEnabled
            g_exploreEnabled    := g_autoPilotEnabled
            if !g_autoPilotEnabled
            {
                g_autoPilotState   := "idle"
                g_autoPilotReason  := "disabled"
                g_combatState      := "idle"
                g_combatLastReason := "disabled"
                g_exploreLastReason := "disabled"
            }
            SetTimer(SaveConfig, -100)
            SetTimer(() => SaveCombatAutoConfig(), -100)
            SetTimer(() => SaveExplorationConfig(), -100)
            SetTimer(PushHeaderToWebView, -50)
        case "RequestInventory":
            ; UI polls this when the Inventory tab is active. Off-snapshot read so
            ; the per-frame cost is zero when the user isn't looking at the tab.
            SetTimer(PushInventoryToWebView, -1)
        case "ToggleInventoryChainDump":
            global g_inventoryChainDumpEnabled
            g_inventoryChainDumpEnabled := !g_inventoryChainDumpEnabled
            SetTimer(SaveConfig, -100)
            SetTimer(PushHeaderToWebView, -50)
        case "ToggleOverlayStatusText":
            ; Toggle the on-screen automation status block drawn by the
            ; radar overlay. State is persisted to Radar.statusText in
            ; the INI so it survives across sessions.
            global g_overlayStatusTextEnabled
            g_overlayStatusTextEnabled := !g_overlayStatusTextEnabled
            SetTimer(SaveConfig, -100)
            SetTimer(PushHeaderToWebView, -50)

        case "ToggleLocalApi":
            ; Start/stop the local HTTP API (MCP backend). Bound to
            ; 127.0.0.1; off by default. State persists to [LocalApi].
            global g_localApiEnabled
            g_localApiEnabled := !g_localApiEnabled
            if (g_localApiEnabled)
                StartLocalApiServer()
            else
                StopLocalApiServer()
            SaveLocalApiConfig()
            SetTimer(PushHeaderToWebView, -50)

            ; ── Memory-Diff RE tab ────────────────────────────────────────
            ; Configure target: args = [symbol, customHex, sizeBytes]
        case "MemDiffConfigure":
            global g_memDiffSymbol, g_memDiffCustomAddr, g_memDiffSize
            g_memDiffSymbol     := (args.Length >= 1) ? String(args[1]) : "ServerDataStructure"
            customHex           := (args.Length >= 2) ? String(args[2]) : "0"
            g_memDiffSize       := (args.Length >= 3) ? Max(16, Min(262144, Integer(args[3]))) : 0x1000
            ; Parse "0x..." or decimal into Int64 — empty / bad input becomes 0
            parsed := 0
            try
            {
                s := Trim(customHex)
                if (s != "")
                {
                    if RegExMatch(s, "i)^\s*0x([0-9A-Fa-f]+)\s*$", &m)
                    {
                        hex := StrUpper(m[1])
                        i2 := 1
                        len2 := StrLen(hex)
                        while (i2 <= len2)
                        {
                            c := SubStr(hex, i2, 1)
                            asc := Asc(c)
                            if (asc >= 48 && asc <= 57)
                                d := asc - 48
                            else if (asc >= 65 && asc <= 70)
                                d := asc - 55
                            else
                                d := 0
                            parsed := parsed * 16 + d
                            i2 += 1
                        }
                    }
                    else
                        parsed := Integer(s)
                }
            }
            catch
                parsed := 0
            g_memDiffCustomAddr := parsed
            SetTimer(PushMemDiffStateToWebView, -1)
        case "MemDiffSnapshotBefore":
            MemDiffSnapshot("before")
            SetTimer(PushMemDiffStateToWebView, -1)
        case "MemDiffSnapshotAfter":
            MemDiffSnapshot("after")
            SetTimer(PushMemDiffResultToWebView, -1)
        case "MemDiffClear":
            MemDiffClear()
            SetTimer(PushMemDiffStateToWebView, -1)
        case "MemDiffRequestState":
            SetTimer(PushMemDiffStateToWebView, -1)
        case "TogglePanelDetection":
            global g_panelDetectionEnabled, g_reader, g_radarLastSnap
            g_panelDetectionEnabled := !g_panelDetectionEnabled
            if (!g_panelDetectionEnabled)
            {
                ; Clear cached panel visibility so UI/overlay doesn't think panels are open
                if IsObject(g_reader)
                {
                    try
                    {
                        g_reader._radarPanelVisCache := Map()
                        g_reader._radarPanelVisCacheTick := 0
                        g_reader._panelCleanSince := 0
                    }
                    catch
                    {

                    }
                }
                ; Push debug panels immediately to refresh UI
                SetTimer(() => PushDebugPanelsToWebView(g_radarLastSnap), -50)
            }
            else
            {
                ; When enabling, ensure discovery restarts cleanly
                if IsObject(g_reader)
                {
                    try
                    {
                        g_reader._radarPanelDiscoveryDone := false
                        g_reader._radarPanelDiscoveryResult := 0
                        g_reader._visBaselineTaken := false
                        g_reader._diffSnapshotTaken := false
                    }
                    catch
                    {

                    }
                }
            }
            SetTimer(SaveConfig, -100)
            SetTimer(PushHeaderToWebView, -50)
        case "SetRadarAlpha":
            global g_radarAlpha
            val := (args.Length >= 1) ? args[1] : 255
            g_radarAlpha := Max(0, Min(255, Integer(val)))
            if (g_radarOverlay)
                g_radarOverlay.SetAlpha(g_radarAlpha)
            SetTimer(SaveConfig, -100)
            SetTimer(PushHeaderToWebView, -50)
        case "SetCfgSections":
            global g_cfgOpenSections
            g_cfgOpenSections := (args.Length >= 1) ? String(args[1]) : ""
            SetTimer(SaveConfig, -100)
        case "WatchNpc":
            SetTimer(AddNearbyNpcScannerToWatchlist, -1)
        case "TreeRefresh":
            SetTimer(ForceRefreshActiveTree, -1)
        case "F3Dump":
            SetTimer(OnF3DebugDump, -1)
        case "ToggleTreePane":
            SetTimer(ToggleTreePaneVisibility, -1)
        case "StartGame":
            SetTimer(LaunchPoE2, -1)
        case "OpenUrl":
            ; Open an http(s) URL in the user's default browser via the
            ; shell. Whitelisted scheme so a malformed call can't shell
            ; out to arbitrary paths.
            url := (args.Length >= 1) ? args[1] : ""
            if (InStr(url, "https://") = 1) || (InStr(url, "http://") = 1)
                try Run(url)
        case "StartDrag":
            DllCall("ReleaseCapture")
            PostMessage(0xA1, 2, , , "ahk_id " g_webGui.Hwnd)
        case "WinMinimize":
            g_webGui.Minimize()
        case "WinMaximize":
            state := WinGetMinMax("ahk_id " g_webGui.Hwnd)
            if (state = 1)
                g_webGui.Restore()
            else
                g_webGui.Maximize()
            SetTimer(PushHeaderToWebView, -50)
        case "WinClose":
            ExitApp()
        case "ToggleAlwaysOnTop":
            global g_alwaysOnTop, g_webGui
            g_alwaysOnTop := !g_alwaysOnTop
            try WinSetAlwaysOnTop(g_alwaysOnTop ? 1 : 0, "ahk_id " g_webGui.Hwnd)
            SetTimer(SaveConfig, -100)
            SetTimer(PushHeaderToWebView, -50)
        case "BlacklistAdd":
            name := (args.Length >= 1) ? args[1] : ""
            if (name != "")
            {
                for _, n in g_skillBuffBlacklist
                    if (n = name)
                        return
                g_skillBuffBlacklist.Push(name)
                SetTimer(SaveConfig, -100)
            }
        case "BlacklistRemove":
            name := (args.Length >= 1) ? args[1] : ""
            if (name != "")
            {
                newList := []
                for _, n in g_skillBuffBlacklist
                    if (n != name)
                        newList.Push(n)
                g_skillBuffBlacklist := newList
                SetTimer(SaveConfig, -100)
                SetTimer(_PushBlacklistToWebView, -1)
            }
        case "ListTsvFiles":
            SetTimer(_PushTsvFileList, -1)
        case "ReadTsvFile":
            fname := (args.Length >= 1) ? args[1] : ""
            if (fname != "")
                SetTimer(() => _PushTsvFileContent(fname), -1)
        case "GenerateTsvs":
            SetTimer(_RunTsvGenerationPipeline, -1)
        case "RediscoverPanels":
            ; Force re-discovery by resetting the cache flags
            if IsObject(g_reader)
            {
                g_reader._radarPanelDiscoveryDone := false
                g_reader._radarPanelDiscoveryResult := 0
                g_reader._heapUiElems := []
                g_reader._visBaseline := Map()
                g_reader._visBaselineTaken := false
                g_reader._diffSnapshot := 0
                g_reader._diffSnapshotTaken := false
                g_reader._structBaselineRaw := 0
                PoE2Offsets.DiscoveredPanelOffsets := Map()
            }
        case "ResetBaseline":
            ; Re-read visibility flags as new baseline (user confirms all panels closed)
            if IsObject(g_reader) && g_reader._heapUiElems.Length > 0
            {
                ok := g_reader.RefreshVisibilityBaseline()
                cnt := g_reader._heapUiElems.Length
                msg := ok ? ("Baseline reset (" cnt " elements)") : "Failed — no elements discovered"
                WebViewExec("window.updateDiffStatus && window.updateDiffStatus(" _JsStr(msg) ")")
            }
            else
                WebViewExec("window.updateDiffStatus && window.updateDiffStatus(" _JsStr("Not ready — run discovery first") ")")
        case "TakeDiffSnapshot":
            if IsObject(g_reader) && g_reader._lastActiveGameUiPtr
            {
                ok := g_reader.TakeStructDiffSnapshot(g_reader._lastActiveGameUiPtr)
                cnt := g_reader._heapUiElems.Length
                msg := ok ? ("Snapshot taken (" cnt " elements)") : "Failed — no valid GameUiPtr"
                WebViewExec("window.updateDiffStatus && window.updateDiffStatus(" _JsStr(msg) ")")
            }
            else
                WebViewExec("window.updateDiffStatus && window.updateDiffStatus(" _JsStr("Not ready — wait for panel discovery to complete") ")")
        case "CompareDiffSnapshot":
            if IsObject(g_reader) && g_reader._lastActiveGameUiPtr && g_reader._diffSnapshotTaken
            {
                diffResult := g_reader.CompareStructDiffSnapshot(g_reader._lastActiveGameUiPtr)
                PushDiffResultsToWebView(diffResult)
            }
            else
                WebViewExec("window.updateDiffStatus && window.updateDiffStatus(" _JsStr("No snapshot — take one first") ")")
        case "SavePanelOffset":
            ; args[1] = struct offset (hex string like "0x4A8"), args[2] = panel name
            if (args.Length >= 2)
            {
                offStr := args[1]
                panelName := args[2]
                offVal := 0
                try offVal := Integer(offStr)
                if (offVal > 0 && panelName != "")
                {
                    PoE2Offsets.DiscoveredPanelOffsets[panelName] := offVal
                    SavePanelOffsetsToConfig()
                    ; Push updated list to UI
                    _PushSavedPanelOffsets()
                    WebViewExec("window.updateDiffStatus && window.updateDiffStatus(" _JsStr("✅ Saved: " panelName " = " offStr) ")")
                }
            }
        case "RemovePanelOffset":
            ; args[1] = panel name to remove
            if (args.Length >= 1)
            {
                panelName := args[1]
                if PoE2Offsets.DiscoveredPanelOffsets.Has(panelName)
                {
                    PoE2Offsets.DiscoveredPanelOffsets.Delete(panelName)
                    SavePanelOffsetsToConfig()
                    _PushSavedPanelOffsets()
                    WebViewExec("window.updateDiffStatus && window.updateDiffStatus(" _JsStr("🗑 Removed: " panelName) ")")
                }
            }
        case "GetSavedPanelOffsets":
            _PushSavedPanelOffsets()

            ; ── Combat Automation tuning (no separate toggle — managed by ToggleAutoPilot) ─
        case "SetCombatRange":
            global g_combatRange
            val := (args.Length >= 1) ? args[1] : 1500
            g_combatRange := Max(200, Min(5000, Integer(val)))
            SetTimer(() => SaveCombatAutoConfig(), -100)
        case "SetCombatDisengageRange":
            global g_combatDisengageRange
            val := (args.Length >= 1) ? args[1] : 2500
            g_combatDisengageRange := Max(500, Min(8000, Integer(val)))
            SetTimer(() => SaveCombatAutoConfig(), -100)
        case "SetCombatGCD":
            global g_combatGlobalCooldownMs
            val := (args.Length >= 1) ? args[1] : 120
            g_combatGlobalCooldownMs := Max(50, Min(2000, Integer(val)))
            SetTimer(() => SaveCombatAutoConfig(), -100)
        case "SetCombatW2S":
            global g_combatW2SScale
            val := (args.Length >= 1) ? args[1] : 0.20
            g_combatW2SScale := Max(0.05, Min(1.0, Float(val)))
            SetTimer(() => SaveCombatAutoConfig(), -100)
        case "SetCombatSlot":
            ; args: [slotNum, key, priority, skillName, type, cooldownMs, enabled, skillRange]
            _ApplyCombatSlotConfig(args)

            ; ── Loot Pickup rarity filter (no toggle — empty filter = off) ─
        case "SetLootRarity":
            ; args: [rarityLabel ("Normal"|"Magic"|"Rare"|"Unique"|"Currency"), bool]
            global g_lootRarityNormal, g_lootRarityMagic, g_lootRarityRare
            global g_lootRarityUnique, g_lootRarityCurrency
            lblRar := (args.Length >= 1) ? String(args[1]) : ""
            vRar := (args.Length >= 2) ? args[2] : false
            bvRar := (vRar = "true" || vRar = true || vRar = 1) ? true : false
            switch lblRar
            {
                case "Normal":   g_lootRarityNormal   := bvRar
                case "Magic":    g_lootRarityMagic    := bvRar
                case "Rare":     g_lootRarityRare     := bvRar
                case "Unique":   g_lootRarityUnique   := bvRar
                case "Currency": g_lootRarityCurrency := bvRar
            }
            SetTimer(() => SaveLootPickupConfig(), -100)

            ; ── Exploration tuning (no separate toggle — managed by ToggleAutoPilot) ──
        case "SetExploreTarget":
            global g_exploreTargetPercent
            val := (args.Length >= 1) ? args[1] : 80
            g_exploreTargetPercent := Max(10, Min(99, Integer(val)))
            SetTimer(() => SaveExplorationConfig(), -100)

            ; ── Range circle overlay (temporary visualization while editing) ──
        case "ShowRangeCircles":
            ; args: JSON-encoded array of {range, color, label} objects, or empty string to clear
            global g_radarOverlay
            if (!g_radarOverlay)
                return
            raw := (args.Length >= 1) ? args[1] : ""
            if (raw = "" || raw = "[]")
            {
                g_radarOverlay.SetRangeCircles([])
                return
            }
            ; Parse simple JSON array: [{range:N,color:N,label:"..."},...]
            circles := []
            pos := 1
            while (found := RegExMatch(raw, '\{[^}]+\}', &m, pos))
            {
                entry := m[]
                rc := Map()
                if RegExMatch(entry, '"range"\s*:\s*(\d+)', &rm)
                    rc["range"] := Integer(rm[1])
                if RegExMatch(entry, '"color"\s*:\s*(\d+)', &cm)
                    rc["color"] := Integer(cm[1])
                if RegExMatch(entry, '"label"\s*:\s*"([^"]*)"', &lm)
                    rc["label"] := lm[1]
                if (rc.Has("range"))
                    circles.Push(rc)
                pos := found + StrLen(entry)
            }
            g_radarOverlay.SetRangeCircles(circles)

            ; ── UI Browser ────────────────────────────────────────────────────
        ; ── Memory Dissector ──────────────────────────────────────────────────
        ; Jump to an absolute hex address (args[1] = "0x..." string).
        case "DissectGoto":
            hex := (args.Length >= 1) ? String(args[1]) : ""
            try LogError("DissectGoto hex=" hex)
            if (hex != "")
            {
                addr := _ParseHexAddr(hex)
                try LogError("DissectGoto parsed addr=0x" Format("{:X}", addr))
                if (addr)
                    SetTimer(() => _SafeDissect(() => MemDissectGoto(addr), "MemDissectGoto"), -1)
            }
        ; Jump to a named symbol (args[1] = symbol name, args[2] = optional custom hex addr).
        case "DissectSymbol":
            sym2   := (args.Length >= 1) ? String(args[1]) : "ServerDataStructure"
            cHex   := (args.Length >= 2) ? String(args[2]) : "0"
            cAddr2 := _ParseHexAddr(cHex)
            try LogError("DissectSymbol sym=" sym2 " cAddr=0x" Format("{:X}", cAddr2))
            SetTimer(() => _SafeDissect(() => MemDissectGotoSymbol(sym2, cAddr2), "MemDissectGotoSymbol"), -1)
        ; Navigation: go back / forward / re-read.
        case "DissectBack":
            try LogError("DissectBack")
            SetTimer(() => _SafeDissect(() => MemDissectBack(), "MemDissectBack"), -1)
        case "DissectForward":
            try LogError("DissectForward")
            SetTimer(() => _SafeDissect(() => MemDissectForward(), "MemDissectForward"), -1)
        case "DissectReread":
            try LogError("DissectReread")
            SetTimer(() => _SafeDissect(() => MemDissectReread(), "MemDissectReread"), -1)
        ; Change the read window size (bytes). args[1] = integer.
        ; Also re-reads the current address so the table immediately reflects
        ; the new page size — without this the dropdown looks unresponsive.
        case "DissectSetSize":
            global g_memDissectSize
            dSz := (args.Length >= 1) ? args[1] : 0x200
            g_memDissectSize := Max(0x40, Min(0x2000, Integer(dSz)))
            try LogError("DissectSetSize sz=" g_memDissectSize)
            SetTimer(() => _SafeDissect(() => MemDissectReread(), "DissectSetSize/reread"), -1)

        case "UiBrowseRoot":
            SetTimer(() => UiBrowseRoot(), -1)
        case "UiBrowseParent":
            SetTimer(() => UiBrowseParent(), -1)
        case "UiBrowseBack":
            SetTimer(() => UiBrowseBack(), -1)
        case "UiBrowseChild":
            idx := (args.Length >= 1) ? args[1] : 0
            SetTimer(() => UiBrowseChild(idx), -1)
        case "UiBrowseAddress":
            hex := (args.Length >= 1) ? String(args[1]) : ""
            if (hex != "")
                SetTimer(() => UiBrowseAddress(hex), -1)
        case "UiBrowseSearch":
            q := (args.Length >= 1) ? String(args[1]) : ""
            SetTimer(() => UiBrowseSearch(q), -1)
        case "UiBrowserClearHighlight":
            SetTimer(() => UiBrowserClearHighlight(), -1)
        case "RefreshItemSizes":
            ; Shell out to ggpk-tools/PoeDataExtract on a timer — runs
            ; ~200 ms..2 s end-to-end and pumps a status message back
            ; to the UI via the standard WebViewExec channel.
            SetTimer(() => GgpkToolBridgeUi_Refresh(), -1)
        case "GgpkMaphackApply":
            SetTimer(() => GgpkMaphackUi_Apply(), -1)
        case "GgpkMaphackRevert":
            SetTimer(() => GgpkMaphackUi_Revert(), -1)
        case "SetGgpkInstallPath":
            ; args[1] is the user-entered path. Validate + persist on a
            ; background timer so the WebView message thread stays
            ; responsive.
            pathArg := (args.Length >= 1) ? String(args[1]) : ""
            if (pathArg != "")
                SetTimer(() => GgpkInstallPathUi_Save(pathArg), -1)
        case "OffsetCompareRun":
            ; Fetch upstream (main) + diff local offsets/patterns on a timer;
            ; the result is pushed back via updateOffsetComparison().
            SetTimer(() => OffsetCompareRun(), -1)
        case "OffsetCompareRecord":
            ; args[1] = JSON array of {key, change_type, notes} classifications.
            ocPayload := (args.Length >= 1) ? String(args[1]) : ""
            SetTimer(() => OffsetCompareRecord(ocPayload), -1)
        case "OffsetCompareShowHistory":
            SetTimer(() => OffsetCompareShowHistory(), -1)
        case "OffsetComparePredict":
            SetTimer(() => OffsetComparePredict(), -1)
        case "AreaInstanceProbeRun":
            ; TEMP post-patch diagnostic: scan for shifted AreaInstance offsets.
            SetTimer(() => AreaInstanceProbeRun(), -1)
        case "ComponentProbeRun":
            ; TEMP post-patch diagnostic: Life/entity/validity component probe.
            SetTimer(() => ComponentProbeRun(), -1)
        case "UiMapProbeRun":
            ; TEMP post-patch diagnostic: UI->Map chain (LargeMap detection).
            SetTimer(() => UiMapProbeRun(), -1)
        case "ChestProbeRun":
            ; TEMP post-patch diagnostic: dump Chest component bytes (IsOpened).
            SetTimer(() => ChestProbeRun(), -1)
        case "TargetableProbeRun":
            ; TEMP post-patch diagnostic: dump Targetable component bytes.
            SetTimer(() => TargetableProbeRun(), -1)
        case "TargetedByPlayerProbeRun":
            ; TEMP post-patch diagnostic: IsTargetedByPlayer hover diff.
            SetTimer(() => TargetedByPlayerProbeRun(), -1)
        case "SkillProbeRun":
            ; TEMP post-patch diagnostic: trace the skill-name DAT chain.
            SetTimer(() => SkillProbeRun(), -1)
        case "PathfindingProbeRun":
            ; TEMP diagnostic: verify Pathfinding Flying/BaseSpeed offsets.
            SetTimer(() => PathfindingProbeRun(), -1)
        case "HoverTrackerProbeRun":
            ; TEMP diagnostic: verify the HoverTracker resolve chain (Ctrl+Alt+H).
            SetTimer(() => HoverTrackerProbeRun(), -1)
        case "ToggleFocusOverlay":
            ; Toggle the focused-entity test overlay (targeted monster + hovered object).
            SetTimer(() => ToggleFocusOverlay(), -1)
        case "ComponentDumpProbeRun":
            ; TEMP diagnostic: dump all components + raw fields of the highlighted entity.
            SetTimer(() => ComponentDumpProbeRun(), -1)
        case "PatchMaintSetPath":
            ; args[1] = user-entered path to Bundles2\_.index.bin / Content.ggpk.
            pmPathArg := (args.Length >= 1) ? String(args[1]) : ""
            SetTimer(() => PatchMaintSetPath(pmPathArg), -1)
        case "PatchMaintSkipData":
            SetTimer(() => PatchMaintSkipData(), -1)
    }
}

; Validates + persists a manually-entered PoE2 install index path
; (Bundles2\_.index.bin OR Content.ggpk). After a successful save,
; pushes a fresh header so the GGPK Apply/Revert UI flips out of
; "path unknown" state immediately.
GgpkInstallPathUi_Save(rawPath)
{
    path := Trim(rawPath, ' "`t')
    result := Map("ok", false, "msg", "")
    if (path = "")
    {
        result["msg"] := "Empty path."
    }
    else if (!FileExist(path))
    {
        result["msg"] := "File not found: " path
    }
    else if (!RegExMatch(path, "i)\.(index\.bin|ggpk)$"))
    {
        result["msg"] := "Path must point at Bundles2\_.index.bin or Content.ggpk."
    }
    else
    {
        ; Validated — persist and (politely) tell the UI to re-render.
        try IniWrite(path, _ConfigPath(), "GgpkTools", "lastIndexPath")
        result["ok"] := true
        result["msg"] := "Saved. Apply/Revert buttons should appear."
    }
    json := '{"ok":' (result["ok"] ? "true" : "false")
        . ',"msg":' _BridgeJsonEscape(result["msg"]) '}'
    try WebViewExec("updateGgpkMaphackStatus(" _JsStr(json) ")")
    SetTimer(PushHeaderToWebView, -50)
}

; Launches the installed PoE2 client, picking the method from the detected
; install (GgpkTools lastIndexPath). A Steam install (path under \steamapps\)
; goes through the Steam protocol so Steam handles updates/overlay; a standalone
; install runs its client exe directly from the game folder. Falls back to the
; Steam protocol when nothing is detected. No parameters; no return value.
LaunchPoE2()
{
    idx := ""
    try idx := IniRead(_ConfigPath(), "GgpkTools", "lastIndexPath", "")
    if (idx = "" || !FileExist(idx))
    {
        ; Cache miss — let the GGPK bridge derive it from Steam's bookkeeping.
        try {
            if GgpkToolBridge.HasCachedIndexPath()
                idx := IniRead(_ConfigPath(), "GgpkTools", "lastIndexPath", "")
        }
    }
    if (idx != "" && !InStr(idx, "\steamapps\"))
    {
        ; Standalone (non-Steam) install — run the client exe from the game folder.
        installDir := RegExReplace(idx, "i)\\(Bundles2\\_\.index\.bin|Content\.ggpk)$", "")
        for _, exe in ["PathOfExile.exe", "PathOfExile_x64.exe", "PathOfExileSteam.exe", "PathOfExile_x64Steam.exe"]
        {
            full := installDir "\" exe
            if FileExist(full)
            {
                try Run('"' full '"', installDir)
                return
            }
        }
    }
    ; Steam install or undetected — let Steam launch PoE2 (app id 2694490).
    try Run("steam://rungameid/2694490")
}

; UI-side wrappers for the GGPK maphack patch/revert. Both shell out
; to ggpk-tools/PoePatcher and surface the result via the same
; updateGgpkToolStatus envelope the manual refresh button uses.
GgpkMaphackUi_Apply()
{
    result := GgpkToolBridge.ApplyMinimapPatch()
    _PushGgpkToolStatus(result)
}
GgpkMaphackUi_Revert()
{
    result := GgpkToolBridge.RevertMinimapPatch()
    _PushGgpkToolStatus(result)
}
_PushGgpkToolStatus(result)
{
    ; Maphack apply/revert get their own status function so the
    ; message lands on the Config-tab row (#ggpk-maphack-status),
    ; not on the data-tab refresh row (#ggpk-refresh-status). Same
    ; envelope shape — different sink.
    json := '{"ok":' (result["ok"] ? "true" : "false")
        . ',"msg":' _BridgeJsonEscape(result["msg"]) '}'
    try WebViewExec("updateGgpkMaphackStatus(" _JsStr(json) ")")
    ; Refresh the header so the Apply/Revert button visibility flips
    ; immediately (the new `ggpkMaphackApplied` flag rides on it).
    SetTimer(PushHeaderToWebView, -50)
}

; UI-side wrapper around GgpkToolBridge.RefreshAllTsvs that pushes
; the result back to the WebView via updateGgpkToolStatus(json).
; Refreshes all GGPK-derived TSVs (item sizes, names, mods, monsters,
; stats) in a single shell-out, not just item sizes.
GgpkToolBridgeUi_Refresh()
{
    result := GgpkToolBridge.RefreshAllTsvs()
    json := '{"ok":' (result["ok"] ? "true" : "false")
        . ',"msg":' _BridgeJsonEscape(result["msg"])
        . ',"rows":' result["rows"] '}'
    try WebViewExec("updateGgpkToolStatus(" _JsStr(json) ")")
}

; Minimal JSON-string escaper for status messages — handles the few
; characters we actually need to quote inside the msg field.
_BridgeJsonEscape(s)
{
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`r", "")
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`t", "\t")
    return '"' s '"'
}
