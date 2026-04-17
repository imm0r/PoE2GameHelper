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
        case "SetThresholds":
            life := (args.Length >= 1) ? args[1] : ""
            mana := (args.Length >= 2) ? args[2] : ""
            SetTimer(() => ApplyThresholdsFromUI(life, mana), -1)
        case "SetEntityFilter":
            etype := (args.Length >= 1) ? args[1] : ""
            val   := (args.Length >= 2) ? args[2] : 0
            bval  := (val = "true" || val = true || val = 1) ? true : false
            SetTimer(() => _ApplyEntityFilter(etype, bval), -1)
        case "SetRadarFilter":
            type := (args.Length >= 1) ? args[1] : ""
            val  := (args.Length >= 2) ? args[2] : 0
            bval := (val = "true" || val = true || val = 1) ? true : false
            switch type
            {
                case "normal":  g_radarShowEnemyNormal := bval
                case "rare":    g_radarShowEnemyRare   := bval
                case "boss":    g_radarShowEnemyBoss   := bval
                case "minions": g_radarShowMinions     := bval
                case "npcs":    g_radarShowNpcs        := bval
                case "chests":  g_radarShowChests      := bval
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
        case "HighlightEntity":
            g_highlightedEntityPath := (args.Length >= 1) ? args[1] : ""
        case "ClearEntityHighlight":
            g_highlightedEntityPath := ""
        case "ToggleZoneNav":
            global g_zoneNavEnabled
            g_zoneNavEnabled := !g_zoneNavEnabled
            if (g_radarOverlay)
                g_radarOverlay._navEnabled := g_zoneNavEnabled
            SetTimer(SaveConfig, -100)
        case "ToggleMapHack":
            global g_mapHackEnabled
            g_mapHackEnabled := !g_mapHackEnabled
            if (g_radarOverlay)
                g_radarOverlay._mapHackEnabled := g_mapHackEnabled
            SetTimer(SaveConfig, -100)
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
            try Run("steam://rungameid/2694490")
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
    }
}
