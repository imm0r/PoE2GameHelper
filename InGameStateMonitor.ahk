#Requires AutoHotkey v2.0
#SingleInstance Force

SetWorkingDir(A_ScriptDir)
#Include Lib/WebViewToo.ahk
#Include PoE2MemoryReader.ahk
#Include PatchChecker.ahk
#Include RadarOverlay.ahk

GAMEHELPER_VERSION := "0.3.0.0"

; Tray icon
try TraySetIcon(A_ScriptDir "\ui\tray.ico")

reader := PoE2GameStateReader("PathOfExileSteam.exe")
debugMode := false
updatesPaused := false
autoFlaskEnabled := false
lifeThresholdPercent := 55
manaThresholdPercent := 35
flaskUseCooldownMs := 450
lastFlaskUseBySlot := Map(1, 0, 2, 0)
pendingFlaskVerifyBySlot := Map()
autoFlaskLastReason := "idle"
autoFlaskPerformanceMode := false
pinnedNodePaths := []
lastSnapshotForUi := 0
g_radarEnabled  := true   ; whether radar overlay is active
g_radarOverlay  := 0   ; lazy-init beim ersten Render-Aufruf
g_radarLastSnap := 0   ; last successful radar snapshot — used by Dump Entities button
g_radarReadMs   := 0  ; Last ReadRadarSnapshot() duration (ms)
g_radarRenderMs := 0  ; Last RadarOverlay.Render() duration (ms)
g_radarFps      := 0  ; Achieved overlay frames per second
g_profReadLastMs  := 0
g_profReadAvgMs   := 0
g_profTreeLastMs  := 0
g_profTotalLastMs := 0
offsetTableRowPathByRow := Map()
offsetPreviousValueByPath := Map()
offsetTableSortCol := 1
offsetTableSortDesc := false
npcWatchRadius := 1200
npcWatchAutoSync := false
npcWatchIgnoredKeys := Map()
treeRefreshRequested := true
readAndShowRunning := false
showTreePane := true
treeTabKeys := ["Overview", "Buffs", "Entities", "UI", "gameState"]
activeTreeTabKey := "Overview"
activeTreeTabIdx := 1
g_webViewReady   := false
g_bridge         := 0
webGui           := 0
g_selectedNodePath := ""
flaskConfigPath := A_MyDocuments "\My Games\Path of Exile 2\poe2_production_Config.ini"
flaskKeyBySlot := Map(1, "1", 2, "2", 3, "3", 4, "4", 5, "5")

; Radar Entity-Filter
radarShowEnemyNormal := true
radarShowEnemyRare   := true
radarShowEnemyBoss   := true
radarShowMinions := true
radarShowNpcs    := true
radarShowChests  := true

; Entity selected in the Entities tab — radar draws a line to it
g_highlightedEntityPath := ""

; Entities-Tab Type-Filter
entityShowPlayer    := true
entityShowMinion    := true
entityShowEnemy     := true
entityShowNPC       := true
entityShowChest     := true
entityShowWorldItem := true
entityShowOther     := true

; Skills & Buffs blacklist
g_skillBuffBlacklist := []

; Zone navigation toggle
g_zoneNavEnabled := true
g_mapHackEnabled := true

flaskKeyLoadStatus := "default"
errorLogPath := A_ScriptDir "\InGameStateMonitor.error.log"
errorLogMaxBytes := 1024 * 512

; ── Hidden data GUI: holds the 5 TreeView controls for data building ────────
dataGui := Gui()
treeControlsByTab := Map()
treeNodePathsByTab := Map()
loop treeTabKeys.Length
{
    key := treeTabKeys[A_Index]
    treeCtrl := dataGui.AddTreeView("w400 h400")
    treeControlsByTab[key] := treeCtrl
    treeNodePathsByTab[key] := Map()
}
valueTree := treeControlsByTab["Overview"]
nodePaths := treeNodePathsByTab["Overview"]
; Stubs for legacy code that references removed native controls
offsetTable := 0
offsetSearchEdit := 0   ; stub — no native search control in WebView-based UI
offsetTableRowPathByRow := Map()
offsetPreviousValueByPath := Map()
offsetTableSortCol := 1
offsetTableSortDesc := false

; Load persisted settings before showing the window
LoadConfig()

; ── WebViewGui ────────────────────────────────────────────────────────────────
webGui := WebViewGui("+AlwaysOnTop +Resize -Caption +Border", "PoE2 GameHelper", , {DefaultWidth: 1080, DefaultHeight: 850})
webGui.OnEvent("Close", (*) => ExitApp())
webGui.OnEvent("Size",  OnWebGuiSize)
webGui.Show("x20 y20 w1080 h850")

; Set window icon (title bar + taskbar) using LoadImage for reliable HICON
try
{
    iconPath := A_ScriptDir "\ui\tray.ico"
    hIconSm := DllCall("LoadImage", "Ptr", 0, "Str", iconPath, "UInt", 1, "Int", 16, "Int", 16, "UInt", 0x10, "Ptr")
    hIconBig := DllCall("LoadImage", "Ptr", 0, "Str", iconPath, "UInt", 1, "Int", 32, "Int", 32, "UInt", 0x10, "Ptr")
    if hIconSm
        SendMessage(0x0080, 0, hIconSm,  , "ahk_id " webGui.Hwnd)
    if hIconBig
        SendMessage(0x0080, 1, hIconBig, , "ahk_id " webGui.Hwnd)
}

; Dark DWM title bar
try
{
    DwmVal := Buffer(4, 0)
    NumPut("Int", 1, DwmVal)
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", webGui.Hwnd, "Int", 20, "Ptr", DwmVal, "Int", 4)
}

; JS→AHK: page posts JSON {method, args} via window.chrome.webview.postMessage(...)
; AHK→JS: WebViewExec() calls ExecuteScriptAsync()
; NavigationCompleted fires when the page finishes loading → trigger initial data push.
webGui.Control.WebMessageReceived(OnWebMessage)
webGui.Control.NavigationCompleted(OnNavigationCompleted)

webGui.Navigate("ui/index.html")

LoadFlaskHotkeysFromConfig(flaskConfigPath)

; Check for PoE2 patch updates (async-like: runs PowerShell hidden, max ~5s)
CheckPoePatchVersion()
UpdateStatusBar()

if !reader.Connect()
{
    valueTree.Delete()
    valueTree.Add("Konnte PathOfExileSteam.exe oder GameStates-Adresse nicht auflösen.")
    valueTree.Add("Starte das Skript als Admin, falls nötig.")
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
    global g_radarReadMs, g_radarRenderMs, g_radarFps, g_profReadLastMs, g_profReadAvgMs, g_profTreeLastMs, g_profTotalLastMs, reader
    patch := GetLastKnownPoeVersion()
    now   := FormatTime(A_Now, "HH:mm:ss")

    radarDetail := ""
    try
    {
        rt := reader.RadarTimings
        if IsObject(rt)
        {
            cacheInfo := ""
            try cacheInfo := " map=" rt["mapSize"] " cache=" rt["cacheSize"] " new=" rt["newDecode"] " upd=" rt["cheapUpdate"] " err=" rt["cacheErrors"] " filt=" rt["filterPost"] "/" rt["filterPre"] " bl=" rt["filterBL"]
            radarDetail := "  radar-detail: state=" rt["state"] " player=" rt["player"] " ui=" rt["ui"] " awake=" rt["awake"] " sleep=" rt["sleep"] " filter=" rt["filter"] cacheInfo
        }
    }

    text := "PoE2 v" (patch != "" ? patch : "unknown") "   |   Last update: " now
           . "   |   Profiling(ms): read=" g_profReadLastMs "(avg=" g_profReadAvgMs ")"
           . "  tree=" g_profTreeLastMs "  total=" g_profTotalLastMs
           . "  radar=" g_radarFps "fps r" g_radarReadMs "+d" g_radarRenderMs
           . radarDetail

    WebViewExec("updateStatus(" _JsStr(text) ")")
}

; Creates or appends a session-start header to the error log file on script launch.
InitializeErrorLog()
{
    global errorLogPath
    try
    {
        header := "`n===== Start " FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") " | PID=" DllCall("GetCurrentProcessId", "UInt") " =====`n"
        FileAppend(header, errorLogPath, "UTF-8")
    }
    catch
    {
    }
}

; Appends a timestamped error entry to the log file; rotates the log to a .1 backup if it exceeds 512 KB.
; Params: context - label identifying the call site; err - optional AHK Error object with message/stack
LogError(context, err := "")
{
    global errorLogPath, errorLogMaxBytes
    static _logging := false

    if _logging
        return
    _logging := true
    try
    {
        try
        {
            if FileExist(errorLogPath)
            {
                size := FileGetSize(errorLogPath)
                if (size >= errorLogMaxBytes)
                {
                    backupPath := errorLogPath ".1"
                    try FileDelete(backupPath)
                    FileMove(errorLogPath, backupPath, true)
                }
            }
        }
        catch
        {
        }

        msg := ""
        try msg := err.Message
        what := ""
        try what := err.What
        line := ""
        try line := err.Line
        extra := ""
        try extra := err.Extra
        stack := ""
        try stack := err.Stack

        text := "[" FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") "] " context
        if (msg != "")
            text .= " | msg=" msg
        if (what != "")
            text .= " | what=" what
        if (line != "")
            text .= " | line=" line
        if (extra != "")
            text .= " | extra=" extra
        if (stack != "")
            text .= "`n" stack
        text .= "`n"

        FileAppend(text, errorLogPath, "UTF-8")
    }
    catch
    {
    }
    finally
        _logging := false
}

; WebGui Size event handler — WebView resizes itself; just update status.
OnWebGuiSize(guiObj, minMax, width, height)
{
    if (minMax = -1)
        return
    UpdateStatusBar()
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

; Dispatches a JS→AHK bridge call by method name.
_DispatchBridgeCall(method, args)
{
    global radarShowEnemyNormal, radarShowEnemyRare, radarShowEnemyBoss
    global radarShowMinions, radarShowNpcs, radarShowChests
    global pinnedNodePaths, g_selectedNodePath, g_radarEnabled, g_highlightedEntityPath
    global g_skillBuffBlacklist

    switch method
    {
        case "PageReady":
            ; No-op: NavigationCompleted already handles initial push
        case "ToggleRadar":
            SetTimer(ToggleRadar, -1)
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
                case "normal":  radarShowEnemyNormal := bval
                case "rare":    radarShowEnemyRare   := bval
                case "boss":    radarShowEnemyBoss   := bval
                case "minions": radarShowMinions     := bval
                case "npcs":    radarShowNpcs        := bval
                case "chests":  radarShowChests      := bval
            }
            SetTimer(SaveConfig, -100)
        case "PinPath":
            path := (args.Length >= 1) ? args[1] : ""
            if (path != "")
            {
                for _, p in pinnedNodePaths
                    if (p = path)
                        return
                pinnedNodePaths.Push(path)
                SetTimer(PushWatchlistToWebView, -1)
                SetTimer(PushHeaderToWebView, -50)
            }
        case "PinSelected":
            if (g_selectedNodePath != "")
                _DispatchBridgeCall("PinPath", [g_selectedNodePath])
        case "SelectNode":
            g_selectedNodePath := (args.Length >= 1) ? args[1] : ""
        case "ClearPins":
            pinnedNodePaths := []
            SetTimer(PushWatchlistToWebView, -1)
            SetTimer(PushHeaderToWebView, -50)
        case "RemovePinnedSelected":
            newList := []
            for _, p in pinnedNodePaths
                if (p != g_selectedNodePath)
                    newList.Push(p)
            pinnedNodePaths := newList
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
            PostMessage(0xA1, 2, , , "ahk_id " webGui.Hwnd)
        case "WinMinimize":
            webGui.Minimize()
        case "WinMaximize":
            state := WinGetMinMax("ahk_id " webGui.Hwnd)
            if (state = 1)
                webGui.Restore()
            else
                webGui.Maximize()
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
    }
}

; Minimal JSON parser: handles flat {key:value} objects and arrays of strings/numbers.
; Only used for parsing bridge messages — not a general-purpose parser.
_JsonParseSimple(json)
{
    json := Trim(json)
    if (SubStr(json, 1, 1) = "{")
    {
        result := Map()
        inner := SubStr(json, 2, StrLen(json) - 2)
        pos := 1
        while (pos <= StrLen(inner))
        {
            ; Skip whitespace/comma
            while (pos <= StrLen(inner) && InStr(", `t`r`n", SubStr(inner, pos, 1)))
                pos++
            if (pos > StrLen(inner))
                break
            ; Read key
            if (SubStr(inner, pos, 1) != '"')
                break
            pos++
            keyEnd := InStr(inner, '"', true, pos)
            if !keyEnd
                break
            key := SubStr(inner, pos, keyEnd - pos)
            pos := keyEnd + 1
            ; Skip :
            while (pos <= StrLen(inner) && InStr(": `t", SubStr(inner, pos, 1)))
                pos++
            ; Read value
            valResult := _JsonReadValue(inner, pos)
            result[key] := valResult[1]
            pos := valResult[2]
        }
        return result
    }
    if (SubStr(json, 1, 1) = "[")
        return _JsonReadArray(json, 1)[1]
    return json
}

_JsonReadValue(s, pos)
{
    ch := SubStr(s, pos, 1)
    if (ch = '"')
    {
        pos++
        start := pos
        while (pos <= StrLen(s))
        {
            c := SubStr(s, pos, 1)
            if (c = "\" )
            {
                pos += 2
                continue
            }
            if (c = '"')
                break
            pos++
        }
        val := SubStr(s, start, pos - start)
        val := StrReplace(val, "\n", "`n")
        val := StrReplace(val, "\t", "`t")
        val := StrReplace(val, '\"', '"')
        val := StrReplace(val, "\\", "\")
        return [val, pos + 1]
    }
    if (ch = "[")
        return _JsonReadArray(s, pos)
    if (ch = "{")
    {
        ; Nested object: skip it, return empty map
        depth := 0
        start := pos
        while (pos <= StrLen(s))
        {
            c := SubStr(s, pos, 1)
            if (c = "{")
                depth++
            else if (c = "}")
            {
                depth--
                if (depth = 0)
                {
                    pos++
                    break
                }
            }
            pos++
        }
        return [Map(), pos]
    }
    ; Number / bool / null
    end := pos
    while (end <= StrLen(s) && !InStr(",]}", SubStr(s, end, 1)))
        end++
    raw := Trim(SubStr(s, pos, end - pos))
    if (raw = "true")
        return [true,  end]
    if (raw = "false")
        return [false, end]
    if (raw = "null")
        return ["",    end]
    return [IsNumber(raw) ? raw + 0 : raw, end]
}

_JsonReadArray(s, pos)
{
    result := []
    pos++  ; skip [
    while (pos <= StrLen(s))
    {
        while (pos <= StrLen(s) && InStr(", `t`r`n", SubStr(s, pos, 1)))
            pos++
        if (SubStr(s, pos, 1) = "]")
        {
            pos++
            break
        }
        valResult := _JsonReadValue(s, pos)
        result.Push(valResult[1])
        pos := valResult[2]
    }
    return [result, pos]
}

; Main update loop: reads a game snapshot, runs auto-flask logic, renders the radar overlay, and rebuilds the TreeView.
; Uses a reentrancy guard (readAndShowRunning) to prevent overlapping executions from timer calls.
; Params: forceTreeRefresh - when true, rebuilds the tree regardless of treeRefreshRequested
ReadAndShow(forceTreeRefresh := false)
{
    static _readCycles := 0
    static _readTotalMs := 0
    static _readLastMs := 0
    static _treeLastMs := 0
    static _totalLastMs := 0
    global readAndShowRunning
    if readAndShowRunning
        return
    readAndShowRunning := true
    totalStart := A_TickCount
    try
        {
        global reader, valueTree, nodePaths, debugMode, updatesPaused, autoFlaskEnabled, flaskKeyLoadStatus, flaskKeyBySlot, showTreePane
        global lifeThresholdPercent, manaThresholdPercent, autoFlaskLastReason, autoFlaskStatusText, hotkeyLegendText, autoFlaskPerformanceMode, lastSnapshotForUi
        global treeRefreshRequested, g_profReadLastMs, g_profReadAvgMs, g_profTreeLastMs, g_profTotalLastMs

        if (updatesPaused && !forceTreeRefresh)
            return

        SetActiveTreeContextFromTab()

        readStart := A_TickCount
        snapshot := autoFlaskPerformanceMode ? reader.ReadAutoFlaskSnapshot() : reader.ReadSnapshot()
        _readLastMs := A_TickCount - readStart
        _readCycles += 1
        _readTotalMs += _readLastMs
        readAvgMs := (_readCycles > 0) ? Round(_readTotalMs / _readCycles, 1) : 0
        entityModeText := "-"
        try entityModeText := reader.LastEntityReadMode
        entityOffsetText := "-"
        try entityOffsetText := PoE2GameStateReader.Hex(reader.LastEntityReadOffset)
        entityFallbackAgeText := "-"
        try
        {
            lastFbTick := reader.LastEntityFallbackTick
            if (lastFbTick > 0)
                entityFallbackAgeText := Round((A_TickCount - lastFbTick) / 1000.0, 1) "s"
        }

        if !snapshot
        {
            valueTree.Delete()
            nodePaths := Map()
            StoreNodePathMapForActiveTab(nodePaths)
            valueTree.Add("Lesefehler: Snapshot leer")
            return
        }

        TryAutoFlask(snapshot)
        lastSnapshotForUi := snapshot

        UpdateActionButtonLabels()

        nowTick := A_TickCount
        doTreeRefresh := treeRefreshRequested || forceTreeRefresh || !updatesPaused

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
            valueTree.Opt("-Redraw")
            valueTree.Delete()
            nodePaths := Map()
            StoreNodePathMapForActiveTab(nodePaths)

            RenderActiveTreeTab(snapshot, snapshotModeText, readAvgMs, _readLastMs, _treeLastMs, _totalLastMs, entityModeText, entityOffsetText, entityFallbackAgeText, expandedPaths)
            RestoreTreeFocusState(treeFocus)
            valueTree.Opt("+Redraw")
            _treeLastMs := A_TickCount - treeStart
            treeRefreshRequested := false
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
        readAndShowRunning := false
        UpdateStatusBar()
    }
}

; Marks a tree refresh as requested and triggers an immediate ReadAndShow call if one is not already running.
ForceRefreshActiveTree()
{
    global treeRefreshRequested, readAndShowRunning

    treeRefreshRequested := true

    if readAndShowRunning
        return

    ReadAndShow(true)
}

; Synchronises the valueTree and nodePaths globals with the currently-selected tab.
SetActiveTreeContextFromTab()
{
    global activeTreeTabIdx, treeTabKeys, treeControlsByTab, treeNodePathsByTab, activeTreeTabKey, valueTree, nodePaths

    idx := activeTreeTabIdx
    if (idx < 1 || idx > treeTabKeys.Length)
        idx := 1

    key := treeTabKeys[idx]
    activeTreeTabKey := key
    valueTree := treeControlsByTab[key]
    nodePaths := treeNodePathsByTab.Has(key) ? treeNodePathsByTab[key] : Map()
    treeNodePathsByTab[key] := nodePaths
}

; Writes the supplied node-path Map back into treeNodePathsByTab for the active tab.
; Called after nodePaths is reset to a fresh Map() so the lookup stays in sync.
StoreNodePathMapForActiveTab(nodePathMap)
{
    global activeTreeTabKey, treeNodePathsByTab
    treeNodePathsByTab[activeTreeTabKey] := nodePathMap
}

; Rebuilds the active TreeView tab with snapshot data, per-read timing, and entity debug info.
; Delegates to tab-specific helpers (AddActiveBuffsNode, AddEntityScannerNode, BuildTreeNode, etc.).
RenderActiveTreeTab(snapshot, snapshotModeText, readAvgMs, readLastMs, treeLastMs, totalLastMs, entityModeText, entityOffsetText, entityFallbackAgeText, expandedPaths)
{
    global valueTree, nodePaths, reader, debugMode, updatesPaused, autoFlaskEnabled, autoFlaskPerformanceMode
    global lifeThresholdPercent, manaThresholdPercent, flaskKeyLoadStatus, autoFlaskLastReason, flaskKeyBySlot, activeTreeTabKey
    global g_radarReadMs, g_radarRenderMs

    title := "Updated: " FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")
       . " | PID: " reader.Mem.Pid
        " | Debug: " (debugMode ? "ON" : "OFF")
        " | Updates: " (updatesPaused ? "PAUSED" : "LIVE")
        " | AutoFlask: " (autoFlaskEnabled ? "ON" : "OFF")
        " | AFPerf: " (autoFlaskPerformanceMode ? "ON" : "OFF")
      . " | Snap: " snapshotModeText
      . " | Profiling(ms): read=" readLastMs "(avg=" readAvgMs ") tree=" treeLastMs " total=" totalLastMs " radar=r" g_radarReadMs "+d" g_radarRenderMs
      . " | EntityMode: " StrUpper(entityModeText)
      . " | EntityOff: " entityOffsetText
      . " | FallbackAgo: " entityFallbackAgeText
      . " | L/M %: " lifeThresholdPercent "/" manaThresholdPercent
      . " | Keys: " flaskKeyLoadStatus
      . " | AF: " autoFlaskLastReason

    header := valueTree.Add(title)
    nodePaths[header] := "snapshot"

    EnsureLegacyGameStateAliases(snapshot)

    switch activeTreeTabKey
    {
        case "Overview":
            inGame := (snapshot && snapshot.Has("inGameState")) ? snapshot["inGameState"] : 0
            areaInst := (inGame && inGame.Has("areaInstance")) ? inGame["areaInstance"] : 0
            playerPosText := BuildPlayerPositionText(areaInst)
            if (playerPosText != "-")
                valueTree.Add("Player Position: " playerPosText, header)

            keyNode := valueTree.Add("Flask Hotkeys (active mapping)", header)
            loop 5
            {
                slot := A_Index
                key := flaskKeyBySlot.Has(slot) ? flaskKeyBySlot[slot] : "?"
                valueTree.Add("Slot " slot " -> " key, keyNode)
            }
            valueTree.Modify(keyNode, "Expand")

        case "Buffs":
            AddActiveBuffsNode(header, snapshot, expandedPaths)

        case "Entities":
            if (snapshotModeText = "autoflask-performance")
            {
                perfNode := valueTree.Add("Performance Mode: Entity Highlights/Scanner deaktiviert", header)
                nodePaths[perfNode] := "snapshot/performanceMode"
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

    valueTree.Modify(header, "Expand")
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
    global treeRefreshRequested

    SetActiveTreeContextFromTab()
    treeRefreshRequested := true
    ReadAndShow()
}

#Include TreeViewWatchlistPanel.ahk


#Include AutoFlask.ahk
#Include UIHelpers.ahk

; F3: one-shot debug dump — TreeView content, game window screenshot, radar entity TSV.
F3::OnF3DebugDump()
