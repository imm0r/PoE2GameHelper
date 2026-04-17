#Requires AutoHotkey v2.0
#SingleInstance Force

SetWorkingDir(A_ScriptDir)
#Include Lib/WebViewToo.ahk
#Include PoE2MemoryReader.ahk
#Include PatchChecker.ahk
#Include RadarOverlay.ahk
#Include PlayerHUD.ahk

GAMEHELPER_VERSION := "0.4.11.2"

; Tray icon
try TraySetIcon(A_ScriptDir "\ui\tray.ico")

g_reader := PoE2GameStateReader("PathOfExileSteam.exe")
g_debugMode := false
g_updatesPaused := false
g_autoFlaskEnabled := false
g_lifeThresholdPercent := 55
g_manaThresholdPercent := 35
g_flaskUseCooldownMs := 450
g_lastFlaskUseBySlot := Map(1, 0, 2, 0)
g_pendingFlaskVerifyBySlot := Map()
g_autoFlaskLastReason := "idle"
g_autoFlaskPerformanceMode := false
g_pinnedNodePaths := []
g_lastSnapshotForUi := 0
g_radarEnabled  := true   ; whether radar overlay is active
g_radarAlpha    := 255    ; overlay opacity (0=transparent, 255=opaque)
g_cfgOpenSections := "status,overview,toggles,autoflask,radar,entities,actions"  ; comma-separated open detail sections
g_radarOverlay  := 0   ; lazy-init beim ersten Render-Aufruf
g_playerHudEnabled := true   ; whether the player HUD overlay is active
g_playerHud     := 0   ; lazy-init on first render
g_radarLastSnap := 0   ; last successful radar snapshot — used by Dump Entities button
g_radarReadMs   := 0  ; Last ReadRadarSnapshot() duration (ms)
g_radarRenderMs := 0  ; Last RadarOverlay.Render() duration (ms)
g_radarFps      := 0  ; Achieved overlay frames per second
g_profReadLastMs  := 0
g_profReadAvgMs   := 0
g_profTreeLastMs  := 0
g_profTotalLastMs := 0
g_offsetTableRowPathByRow := Map()
g_offsetPreviousValueByPath := Map()
g_offsetTableSortCol := 1
g_offsetTableSortDesc := false
g_npcWatchRadius := 1200
g_npcWatchAutoSync := false
g_npcWatchIgnoredKeys := Map()
g_treeRefreshRequested := true
g_readAndShowRunning := false
g_showTreePane := true
g_treeTabKeys := ["Overview", "Buffs", "Entities", "UI", "gameState"]
g_activeTreeTabKey := "Overview"
g_activeTreeTabIdx := 1
g_webViewReady   := false
g_bridge         := 0
g_webGui           := 0
g_selectedNodePath := ""
g_flaskConfigPath := A_MyDocuments "\My Games\Path of Exile 2\poe2_production_Config.ini"
g_flaskKeyBySlot := Map(1, "1", 2, "2", 3, "3", 4, "4", 5, "5")

; Radar Entity-Filter
g_radarShowEnemyNormal := true
g_radarShowEnemyRare   := true
g_radarShowEnemyBoss   := true
g_radarShowMinions := true
g_radarShowNpcs    := true
g_radarShowChests  := true

; Entity selected in the Entities tab — radar draws a line to it
g_highlightedEntityPath := ""

; Entities-Tab Type-Filter
g_entityShowPlayer    := true
g_entityShowMinion    := true
g_entityShowEnemy     := true
g_entityShowNPC       := true
g_entityShowChest     := true
g_entityShowWorldItem := true
g_entityShowOther     := true

; Skills & Buffs blacklist
g_skillBuffBlacklist := []

; Zone navigation toggle
g_zoneNavEnabled := true
g_mapHackEnabled := true

; Window geometry (restored from INI by LoadConfig)
g_winX := 20
g_winY := 20
g_winW := 1080
g_winH := 850
g_winMaximized := false

g_flaskKeyLoadStatus := "default"
g_errorLogPath := A_ScriptDir "\InGameStateMonitor.error.log"
g_errorLogMaxBytes := 1024 * 512

; ── Hidden data GUI: holds the 5 TreeView controls for data building ────────
g_dataGui := Gui()
g_treeControlsByTab := Map()
g_treeNodePathsByTab := Map()
loop g_treeTabKeys.Length
{
    key := g_treeTabKeys[A_Index]
    treeCtrl := g_dataGui.AddTreeView("w400 h400")
    g_treeControlsByTab[key] := treeCtrl
    g_treeNodePathsByTab[key] := Map()
}
g_valueTree := g_treeControlsByTab["Overview"]
g_nodePaths := g_treeNodePathsByTab["Overview"]
; Stubs for legacy code that references removed native controls
g_offsetTable := 0
g_offsetSearchEdit := 0   ; stub — no native search control in WebView-based UI
g_offsetTableRowPathByRow := Map()
g_offsetPreviousValueByPath := Map()
g_offsetTableSortCol := 1
g_offsetTableSortDesc := false

; Load persisted settings before showing the window
LoadConfig()

; ── WebViewGui ────────────────────────────────────────────────────────────────
g_webGui := WebViewGui("+AlwaysOnTop +Resize -Caption +Border", "PoE2 GameHelper", , {DefaultWidth: g_winW, DefaultHeight: g_winH})
g_webGui.OnEvent("Close", (*) => ExitApp())
g_webGui.OnEvent("Size",  OnWebGuiSize)
g_webGui.Show()
; Restore saved outer-rect geometry (WinMove uses window rect, not client area)
WinMove(g_winX, g_winY, g_winW, g_winH, "ahk_id " g_webGui.Hwnd)
if g_winMaximized
    g_webGui.Maximize()

; Save window geometry on exit and after move/resize
OnExit((*) => (_CaptureWindowGeometry(), SaveConfig()))
OnMessage(0x0232, _OnExitSizeMove)  ; WM_EXITSIZEMOVE

; Set window icon (title bar + taskbar) using LoadImage for reliable HICON
try
{
    iconPath := A_ScriptDir "\ui\tray.ico"
    hIconSm := DllCall("LoadImage", "Ptr", 0, "Str", iconPath, "UInt", 1, "Int", 16, "Int", 16, "UInt", 0x10, "Ptr")
    hIconBig := DllCall("LoadImage", "Ptr", 0, "Str", iconPath, "UInt", 1, "Int", 32, "Int", 32, "UInt", 0x10, "Ptr")
    if hIconSm
        SendMessage(0x0080, 0, hIconSm,  , "ahk_id " g_webGui.Hwnd)
    if hIconBig
        SendMessage(0x0080, 1, hIconBig, , "ahk_id " g_webGui.Hwnd)
}

; Dark DWM title bar
try
{
    DwmVal := Buffer(4, 0)
    NumPut("Int", 1, DwmVal)
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", g_webGui.Hwnd, "Int", 20, "Ptr", DwmVal, "Int", 4)
}

; JS→AHK: page posts JSON {method, args} via window.chrome.webview.postMessage(...)
; AHK→JS: WebViewExec() calls ExecuteScriptAsync()
; NavigationCompleted fires when the page finishes loading → trigger initial data push.
g_webGui.Control.WebMessageReceived(OnWebMessage)
g_webGui.Control.NavigationCompleted(OnNavigationCompleted)

g_webGui.Navigate("ui/index.html")

LoadFlaskHotkeysFromConfig(g_flaskConfigPath)

; Check for PoE2 patch updates (async-like: runs PowerShell hidden, max ~5s)
CheckPoePatchVersion()
UpdateStatusBar()

if !g_reader.Connect()
{
    g_valueTree.Delete()
    g_valueTree.Add("Konnte PathOfExileSteam.exe oder GameStates-Adresse nicht auflösen.")
    g_valueTree.Add("Starte das Skript als Admin, falls nötig.")
    return
}

InitializeErrorLog()
SetTimer(TryAutoFlaskFast, 150)
SetTimer(UpdateRadarFast, 50)
SetTimer(ReadAndShow, 2000)
ReadAndShow()
return

; Updates the status bar text and pushes it to the WebView.
UpdateStatusBar()
{
    global g_radarReadMs, g_radarRenderMs, g_radarFps, g_profReadLastMs, g_profReadAvgMs, g_profTreeLastMs, g_profTotalLastMs, g_reader
    global GAMEHELPER_VERSION

    patch := GetLastKnownPoeVersion()
    now   := FormatTime(A_Now, "HH:mm:ss")

    leftText := "GameHelper v" GAMEHELPER_VERSION " for PoE2 v" (patch != "" ? patch : "—")
    rightText := "Last Updated: " now

    ; Performance details for the FPS pill: total iteration ms + radar fps
    perfText := g_profTotalLastMs "ms"
    if (g_radarFps > 0)
        perfText .= " | " g_radarFps " fps"

    WebViewExec("updateStatus(" _JsStr(leftText) "," _JsStr(rightText) "," _JsStr(perfText) ")")
}


; ── WebGui event handlers ────────────────────────────────────────────────────
OnWebGuiSize(guiObj, minMax, width, height)
{
    if (minMax = -1)
        return
    UpdateStatusBar()
}

; Debounced save after the user finishes moving or resizing the window.
_OnExitSizeMove(wParam, lParam, msg, hwnd)
{
    global g_webGui
    if (hwnd = g_webGui.Hwnd)
        SetTimer(_DebouncedGeometrySave, -500)
}

_DebouncedGeometrySave()
{
    _CaptureWindowGeometry()
    SaveConfig()
}

; Fires when the WebView finishes loading a page — triggers the first data push.
OnNavigationCompleted(wv, args, *)
{
    global g_webViewReady
    g_webViewReady := true
    SetTimer(PushAllDataToWebView, -100)
}

; Receives JSON messages posted from JS via window.chrome.webview.postMessage({method, args}).
OnWebMessage(wv, args, *)
{
    try
    {
        msg := args.WebMessageAsJson   ; ICoreWebView2WebMessageReceivedEventArgs.WebMessageAsJson
        data := _JsonParseSimple(msg)
        if !IsObject(data)
            return
        method := data.Has("method") ? data["method"] : ""
        jargs  := data.Has("args")   ? data["args"]   : []
        _DispatchBridgeCall(method, jargs)
    }
    catch as ex
    {
        LogError("OnWebMessage", ex)
    }
}


; Main update loop: reads a game snapshot, runs auto-flask logic, renders the radar overlay, and rebuilds the TreeView.
; Uses a reentrancy guard (g_readAndShowRunning) to prevent overlapping executions from timer calls.
; Params: forceTreeRefresh - when true, rebuilds the tree regardless of g_treeRefreshRequested
ReadAndShow(forceTreeRefresh := false)
{
    static _readCycles := 0
    static _readTotalMs := 0
    static _readLastMs := 0
    static _treeLastMs := 0
    static _totalLastMs := 0
    global g_readAndShowRunning
    if g_readAndShowRunning
        return
    g_readAndShowRunning := true
    totalStart := A_TickCount
    try
        {
        global g_reader, g_valueTree, g_nodePaths, g_debugMode, g_updatesPaused, g_autoFlaskEnabled, g_flaskKeyLoadStatus, g_flaskKeyBySlot, g_showTreePane
        global g_lifeThresholdPercent, g_manaThresholdPercent, g_autoFlaskLastReason, autoFlaskStatusText, hotkeyLegendText, g_autoFlaskPerformanceMode, g_lastSnapshotForUi
        global g_treeRefreshRequested, g_profReadLastMs, g_profReadAvgMs, g_profTreeLastMs, g_profTotalLastMs

        if (g_updatesPaused && !forceTreeRefresh)
            return

        SetActiveTreeContextFromTab()

        readStart := A_TickCount
        snapshot := g_autoFlaskPerformanceMode ? g_reader.ReadAutoFlaskSnapshot() : g_reader.ReadSnapshot()
        _readLastMs := A_TickCount - readStart
        _readCycles += 1
        _readTotalMs += _readLastMs
        readAvgMs := (_readCycles > 0) ? Round(_readTotalMs / _readCycles, 1) : 0
        entityModeText := "-"
        try entityModeText := g_reader.LastEntityReadMode
        entityOffsetText := "-"
        try entityOffsetText := PoE2GameStateReader.Hex(g_reader.LastEntityReadOffset)
        entityFallbackAgeText := "-"
        try
        {
            lastFbTick := g_reader.LastEntityFallbackTick
            if (lastFbTick > 0)
                entityFallbackAgeText := Round((A_TickCount - lastFbTick) / 1000.0, 1) "s"
        }

        if !snapshot
        {
            g_valueTree.Delete()
            g_nodePaths := Map()
            StoreNodePathMapForActiveTab(g_nodePaths)
            g_valueTree.Add("Lesefehler: Snapshot leer")
            return
        }

        TryAutoFlask(snapshot)
        g_lastSnapshotForUi := snapshot

        UpdateActionButtonLabels()

        nowTick := A_TickCount
        doTreeRefresh := g_treeRefreshRequested || forceTreeRefresh || !g_updatesPaused

        expandedPaths := Map()
        treeFocus := 0
        if doTreeRefresh
        {
            expandedPaths := CaptureExpandedPaths()
            treeFocus := CaptureTreeFocusState()
        }

        snapshotModeText := (snapshot.Has("snapshotMode") && snapshot["snapshotMode"] != "")
            ? snapshot["snapshotMode"]
            : "full"

        if doTreeRefresh
        {
            treeStart := A_TickCount
            g_valueTree.Opt("-Redraw")
            g_valueTree.Delete()
            g_nodePaths := Map()
            StoreNodePathMapForActiveTab(g_nodePaths)

            RenderActiveTreeTab(snapshot, snapshotModeText, readAvgMs, _readLastMs, _treeLastMs, _totalLastMs, entityModeText, entityOffsetText, entityFallbackAgeText, expandedPaths)
            RestoreTreeFocusState(treeFocus)
            g_valueTree.Opt("+Redraw")
            _treeLastMs := A_TickCount - treeStart
            g_treeRefreshRequested := false
        }
        _totalLastMs := A_TickCount - totalStart
        g_profReadLastMs  := _readLastMs
        g_profReadAvgMs   := readAvgMs
        g_profTreeLastMs  := _treeLastMs
        g_profTotalLastMs := _totalLastMs
        UpdateOffsetTable(snapshot)
        ; Push the active (tree) tab plus all special-tab data to the WebView UI.
        PushActiveTreeToWebView()
        PushSpecialTabsToWebView(snapshot)
        PushHeaderToWebView()
        PushWatchlistToWebView()
    }
    catch as ex
    {
        ; Never propagate timer callback errors as modal dialogs.
        LogError("ReadAndShow", ex)
    }
    finally
    {
        g_readAndShowRunning := false
        UpdateStatusBar()
    }
}

; Marks a tree refresh as requested and triggers an immediate ReadAndShow call if one is not already running.
ForceRefreshActiveTree()
{
    global g_treeRefreshRequested, g_readAndShowRunning

    g_treeRefreshRequested := true

    if g_readAndShowRunning
        return

    ReadAndShow(true)
}

; Synchronises the g_valueTree and g_nodePaths globals with the currently-selected tab.
SetActiveTreeContextFromTab()
{
    global g_activeTreeTabIdx, g_treeTabKeys, g_treeControlsByTab, g_treeNodePathsByTab, g_activeTreeTabKey, g_valueTree, g_nodePaths

    idx := g_activeTreeTabIdx
    if (idx < 1 || idx > g_treeTabKeys.Length)
        idx := 1

    key := g_treeTabKeys[idx]
    g_activeTreeTabKey := key
    g_valueTree := g_treeControlsByTab[key]
    g_nodePaths := g_treeNodePathsByTab.Has(key) ? g_treeNodePathsByTab[key] : Map()
    g_treeNodePathsByTab[key] := g_nodePaths
}

; Writes the supplied node-path Map back into g_treeNodePathsByTab for the active tab.
; Called after g_nodePaths is reset to a fresh Map() so the lookup stays in sync.
StoreNodePathMapForActiveTab(nodePathMap)
{
    global g_activeTreeTabKey, g_treeNodePathsByTab
    g_treeNodePathsByTab[g_activeTreeTabKey] := nodePathMap
}

; Rebuilds the active TreeView tab with snapshot data, per-read timing, and entity debug info.
; Delegates to tab-specific helpers (AddActiveBuffsNode, AddEntityScannerNode, BuildTreeNode, etc.).
RenderActiveTreeTab(snapshot, snapshotModeText, readAvgMs, readLastMs, treeLastMs, totalLastMs, entityModeText, entityOffsetText, entityFallbackAgeText, expandedPaths)
{
    global g_valueTree, g_nodePaths, g_reader, g_debugMode, g_updatesPaused, g_autoFlaskEnabled, g_autoFlaskPerformanceMode
    global g_lifeThresholdPercent, g_manaThresholdPercent, g_flaskKeyLoadStatus, g_autoFlaskLastReason, g_flaskKeyBySlot, g_activeTreeTabKey
    global g_radarReadMs, g_radarRenderMs

    title := "Updated: " FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")
       . " | PID: " g_reader.Mem.Pid
        " | Debug: " (g_debugMode ? "ON" : "OFF")
        " | Updates: " (g_updatesPaused ? "PAUSED" : "LIVE")
        " | AutoFlask: " (g_autoFlaskEnabled ? "ON" : "OFF")
        " | AFPerf: " (g_autoFlaskPerformanceMode ? "ON" : "OFF")
      . " | Snap: " snapshotModeText
      . " | Profiling(ms): read=" readLastMs "(avg=" readAvgMs ") tree=" treeLastMs " total=" totalLastMs " radar=r" g_radarReadMs "+d" g_radarRenderMs
      . " | EntityMode: " StrUpper(entityModeText)
      . " | EntityOff: " entityOffsetText
      . " | FallbackAgo: " entityFallbackAgeText
      . " | L/M %: " g_lifeThresholdPercent "/" g_manaThresholdPercent
      . " | Keys: " g_flaskKeyLoadStatus
      . " | AF: " g_autoFlaskLastReason

    header := g_valueTree.Add(title)
    g_nodePaths[header] := "snapshot"

    EnsureLegacyGameStateAliases(snapshot)

    switch g_activeTreeTabKey
    {
        case "Overview":
            inGame := (snapshot && snapshot.Has("inGameState")) ? snapshot["inGameState"] : 0
            areaInst := (inGame && inGame.Has("areaInstance")) ? inGame["areaInstance"] : 0
            playerPosText := BuildPlayerPositionText(areaInst)
            if (playerPosText != "-")
                g_valueTree.Add("Player Position: " playerPosText, header)

            keyNode := g_valueTree.Add("Flask Hotkeys (active mapping)", header)
            loop 5
            {
                slot := A_Index
                key := g_flaskKeyBySlot.Has(slot) ? g_flaskKeyBySlot[slot] : "?"
                g_valueTree.Add("Slot " slot " -> " key, keyNode)
            }
            g_valueTree.Modify(keyNode, "Expand")

        case "Buffs":
            AddActiveBuffsNode(header, snapshot, expandedPaths)

        case "Entities":
            if (snapshotModeText = "autoflask-performance")
            {
                perfNode := g_valueTree.Add("Performance Mode: Entity Highlights/Scanner deaktiviert", header)
                g_nodePaths[perfNode] := "snapshot/performanceMode"
            }
            else
            {
                AddDecodedEntityHighlightsNode(header, snapshot, expandedPaths)
                AddEntityScannerNode(header, snapshot, expandedPaths)
            }

        case "UI":
            AddImportantUiElementsNode(header, snapshot, expandedPaths)

        case "gameState":
            counters := Map("nodes", 0)
            BuildTreeNode(header, "snapshot", snapshot, 0, counters, expandedPaths, "snapshot")
    }

    g_valueTree.Modify(header, "Expand")
}

; Injects compatibility keys (vitalStruct, playerStruct) into the snapshot Map for older TreeView code.
; Params: snapshot - the current game state Map; modified in place if aliases are missing
EnsureLegacyGameStateAliases(snapshot)
{
    if !(snapshot && Type(snapshot) = "Map" && snapshot.Has("inGameState"))
        return

    inGameState := snapshot["inGameState"]
    if !(inGameState && Type(inGameState) = "Map" && inGameState.Has("areaInstance"))
        return

    areaInstance := inGameState["areaInstance"]
    if !(areaInstance && Type(areaInstance) = "Map")
        return

    playerVitals := areaInstance.Has("playerVitals") ? areaInstance["playerVitals"] : 0

    if (playerVitals && !areaInstance.Has("vitalStruct"))
        areaInstance["vitalStruct"] := playerVitals

    if !areaInstance.Has("playerStruct")
    {
        playerStruct := Map(
            "localPlayerPtr", areaInstance.Has("localPlayerPtr") ? areaInstance["localPlayerPtr"] : 0,
            "localPlayerRawPtr", areaInstance.Has("localPlayerRawPtr") ? areaInstance["localPlayerRawPtr"] : 0
        )

        if playerVitals
        {
            playerStruct["vitalStruct"] := playerVitals
            playerStruct["playerVitals"] := playerVitals
        }

        areaInstance["playerStruct"] := playerStruct
    }
}

; Tab Change event handler; switches the active tree context and requests a full tree refresh.
OnTreeTabChanged(*)
{
    global g_treeRefreshRequested

    SetActiveTreeContextFromTab()
    g_treeRefreshRequested := true
    ReadAndShow()
}

#Include TreeViewWatchlistPanel.ahk

; ── Extracted single-responsibility modules ──────────────────────────────────
#Include JsonParser.ahk
#Include ErrorLogger.ahk
#Include ConfigManager.ahk
#Include SnapshotSerializers.ahk
#Include WebViewBridge.ahk
#Include DebugDump.ahk
#Include ToggleHandlers.ahk
#Include BridgeDispatch.ahk

#Include AutoFlask.ahk
#Include UIHelpers.ahk

; F3: one-shot debug dump — TreeView content, game window screenshot, radar entity TSV.
F3::OnF3DebugDump()
