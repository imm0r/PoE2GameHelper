#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn All, Off

; #Warn Unreachable, Off
;   AHK v2's unreachable-code analysis is notoriously confused by
;   classes / functions declared across #Include boundaries — it treats
;   a `return` inside a top-level function as if it ended the auto-
;   execute section, then flags the next #Include'd class declaration
;   as "won't execute". Every reload pops a popup per offending file,
;   which gets old fast in a multi-module project like this one.
; #Warn LocalSameAsGlobal, Off
;   We use class-level static state heavily (e.g. ItemSizeRegistry,
;   GgpkToolBridge) and a few intentionally-shadowing locals; the
;   diagnostics are too noisy to be useful for our coding style.
; Real-bug warnings (VarUnset, etc.) stay ON.
#Warn Unreachable, Off
#Warn LocalSameAsGlobal, Off

SetWorkingDir(A_ScriptDir)
#Include Lib/WebViewToo.ahk
#Include ahk/PoE2MemoryReader.ahk
#Include ahk/PatchChecker.ahk
#Include Lib/TerrainPathfinder.ahk
#Include ahk/GdiOverlayBase.ahk
#Include ahk/RadarOverlay.ahk
#Include ahk/VitalsOverlay.ahk
#Include ahk/NotificationOverlay.ahk
#Include ahk/DebugOverlay.ahk
#Include ahk/FocusOverlay.ahk
#Include ahk/OverlayContext.ahk
#Include ahk/PlayOverlayPolicy.ahk
#Include ahk/OverlayManager.ahk
#Include ahk/UiTreeBrowser.ahk
#Include ahk/UiBrowserHandler.ahk

/*
The project and all the files I develop in are located locally at "E:\PoEformance\"
For maximum readability, keep all .ahk files as small as possible. If you notice that you have developed a substantial amount of new code for a particular area, move it into a new .ahk file and include it via #include.
Break large tasks into smaller steps and ask clarifying questions when needed.
In your feedback, explain your reasoning and point out problems and opportunities.
Think step by step and lay out your reasoning for complex problems.
Use concrete examples.
In general, at the start of a new task, always check the original C# project ("https://github.com/Gordin/GameHelper2" — branch main) to see whether a solution or approach for the current task already exists there.
When you create new functions, always add a 2-3 line comment beforehand: what the function is for, which parameters it uses, and whether it returns values.
When you create new variables, always name them meaningfully and follow the existing general style.
*/

POEFORMANCE_VERSION := "0.45.12.77"

; ── WebView2Loader.dll bundling (compiled .exe only) ──────────────────────
; Lib/WebView2.ahk loads WebView2Loader.dll via DllCall, with a fallback that
; resolves it relative to A_LineFile + Lib/<bitness>bit/. When the script is
; compiled to .exe via Ahk2Exe, A_LineFile points at the .exe (not the source
; tree) so that fallback fails — surfaces as "Failed to load DLL" the first
; time CreateCoreWebView2EnvironmentWithOptions is invoked.
;
; Fix: at startup, FileInstall the matching-bitness DLL next to the .exe so
; the library's primary check ("WebView2Loader.dll" relative to A_WorkingDir,
; which equals A_ScriptDir for compiled runs) succeeds.
;
; Uncompiled runs short-circuit on A_IsCompiled and keep using the source
; tree's Lib/<bitness>bit/ DLL via the library's existing fallback.
if A_IsCompiled
{
    wvDll := A_ScriptDir "\WebView2Loader.dll"
    if !FileExist(wvDll)
    {
        ; FileInstall requires literal source paths so we branch on bitness
        ; explicitly. Ahk2Exe embeds both blobs (~200 KB each); only the one
        ; matching the compile target's bitness is extracted at runtime.
        if (A_PtrSize = 8)
            FileInstall("Lib\64bit\WebView2Loader.dll", wvDll, true)
        else
            FileInstall("Lib\32bit\WebView2Loader.dll", wvDll, true)
    }
}

; Tray icon
try TraySetIcon(A_ScriptDir "\ui\tray.ico")

; ── One-time settings migration (PoE2GameHelper → PoEformance rebrand) ──
; The settings file was renamed gamehelper_config.ini → poeformance_config.ini.
; Carry an existing file over so users keep their settings after updating.
_oldCfg := A_ScriptDir "\gamehelper_config.ini"
_newCfg := A_ScriptDir "\poeformance_config.ini"
if (FileExist(_oldCfg) && !FileExist(_newCfg))
    try FileMove(_oldCfg, _newCfg, false)

g_reader := PoE2GameStateReader()
; Connection state — flipped by EnsureConnected(). When false, the
; game-tick timers (radar, flask, ReadAndShow) short-circuit so we
; don't spam ReadProcessMemory failures against a dead handle.
g_isConnected := false
g_lastConnectedPid := 0   ; tracks whether the PID changed between checks
; so PID-rotation (Steam restart) refreshes module addresses
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
g_radarEnabled := true   ; whether radar overlay is active
g_radarAlpha := 255    ; overlay opacity (0=transparent, 255=opaque)
g_overlayStatusTextEnabled := true   ; show automation status block on game overlay
g_overlayPoeOnly := false   ; restrict play overlays to the PoE2 window only (hide while our own tool is focused)
g_cfgOpenSections := "status,overview,toggles,autoflask,radar,entities,actions,al-conditions,al-timing,al-output"  ; comma-separated open detail sections
g_overlayManager := 0   ; OverlayManager — owns all overlays; built in LoadOverlaySystem()
g_radarOverlay := 0   ; reference to the manager-owned RadarOverlay (set in LoadOverlaySystem)
g_playerHudEnabled := true   ; master toggle for the vitals overlay (formerly the player HUD)
g_playerHud := 0   ; legacy alias -> the manager-owned VitalsOverlay (set in LoadOverlaySystem)
g_vitalsOverlay := 0   ; reference to the manager-owned VitalsOverlay (set in LoadOverlaySystem)
g_vitalsBars := 0      ; Map(barId -> config Map); seeded by LoadVitalsConfig()
g_vitalsEditMode := false   ; drag-to-place layout edit mode for the vitals bars
g_vitalsNeedsCombat := false   ; true when a vitals bar uses an "In Combat" condition (gates the standalone combat detector)
g_notifyOverlay := 0   ; reference to the manager-owned NotificationOverlay (set in LoadOverlaySystem)
g_focusOverlay := 0   ; reference to the manager-owned FocusOverlay (set in LoadOverlaySystem)
g_focusOverlayEnabled := true   ; whether the focused-entity test overlay is active
g_atlasOverlayEnabled := false  ; Atlas map overlay (opt-in; offsets still being verified)
g_atlasBuildTick := 0           ; throttle stamp for TryBuildAtlasRender
g_atlasRender := 0              ; Atlas render snapshot (built by TryBuildAtlasRender)
g_localApiEnabled := false   ; local HTTP API (MCP backend) — opt-in; seeded by LoadLocalApiConfig()
g_localApiPort := 7777       ; loopback port for the local HTTP API
g_radarLastSnap := 0   ; last successful radar snapshot — used by Dump Entities button
g_radarReadMs := 0  ; Last ReadRadarSnapshot() duration (ms)
g_radarRenderMs := 0  ; Last RadarOverlay.Render() duration (ms)
g_radarFps := 0  ; Achieved overlay frames per second
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
g_webViewReady := false
g_pendingPatchNotice := ""   ; queued showPatchUpdate(...) JS until the WebView is ready
g_patchMaint := ""           ; active post-patch maintenance run, Map("prev","cur") or ""
g_patchMaintPending := ""    ; maintenance request queued until the WebView is ready
g_patchMaintBusy := false    ; true while GGPK extraction runs (auto-refresh dedup guard)
g_bridge := 0
g_webGui := 0
g_alwaysOnTop := true   ; main window AoT — toggle via header pin button
g_selectedNodePath := ""
g_flaskConfigPath := A_MyDocuments "\My Games\Path of Exile 2\poe2_production_Config.ini"
g_flaskKeyBySlot := Map(1, "1", 2, "2", 3, "3", 4, "4", 5, "5")

; Combat Automation globals
g_combatAutoEnabled := false
g_combatToggleHotkey := "F10"
g_combatRange := 1500
g_combatDisengageRange := 2500
g_combatGlobalCooldownMs := 120
g_combatW2SScale := 0.20
g_combatSkillSlots := Map()
g_combatState := "idle"
g_combatLastReason := "idle"
g_lastSkillUseTime := 0
g_combatSkillCooldowns := Map()

; Exploration Module
g_exploreEnabled := false
g_exploreTargetPercent := 80
g_exploreCurrentPercent := 0.0
g_exploreLastReason := "idle"

; AutoPilot — master state machine that arbitrates combat / loot / exploration.
; When off, none of the sub-routines run.
g_autoPilotEnabled := false
g_autoPilotState := "idle"   ; "idle" | "combat" | "loot" | "explore"
g_autoPilotReason := "idle"

; Loot Pickup — ground-item collection inside AutoPilot. Five rarity bits
; gate which items the bot will pick up. Cache persists across ticks so an
; item that dropped mid-fight stays remembered until the path is clear.
g_lootRarityNormal := false
g_lootRarityMagic := true
g_lootRarityRare := true
g_lootRarityUnique := true
g_lootRarityCurrency := true
g_lootCache := Map()  ; entityAddr → Map(worldX, worldY, worldZ, rarity, …)
g_lootLastReason := "idle"
; Backpack free-cell cache — recomputed on demand by LootPickup, refreshed
; every ~3 s. The free-cell count gates pickup so the bot stops clicking when
; the inventory is full. -1 means "not yet computed / unavailable".
g_lootInvFreeCells := -1
g_lootInvLastCheckTick := 0
g_lootInvForceRefresh := false
g_lootInvDiag := ""   ; debug snapshot of last inv-read (raw counts)
; Occupancy grid for the backpack. Array of arrays of 0/1 (1 = occupied).
; Indexed [y][x+1] (1-based inner). Used by _CanFitInBackpack to check
; that a target item's footprint actually has contiguous free space.
g_lootInvGrid := 0
g_lootInvGridX := 0
g_lootInvGridY := 0

; Diagnostics: when on, every inventory push writes a pointer-chain dump to
; InGameStateMonitor.inventory_chain.log. Off by default — opt-in for debugging
; layout questions, since the dump does dozens of extra RPM reads per cycle.
g_inventoryChainDumpEnabled := false

; Memory Diff (RE helper). Snapshot a region of memory, do something in-game,
; snapshot again, diff. See MemoryDiff.ahk.
g_memDiffSymbol := "ServerDataStructure"   ; named anchor or "Custom"
g_memDiffCustomAddr := 0                       ; absolute address when symbol = "Custom"
g_memDiffAddress := 0                       ; resolved address from last snapshot
g_memDiffSize := 0x1000                  ; 4 KB default — covers most struct ranges
g_memDiffBeforeBuf := 0
g_memDiffBeforeAddr := 0
g_memDiffBeforeTime := 0
g_memDiffAfterBuf := 0
g_memDiffAfterTime := 0
g_memDiffStatus := "idle"

; Memory Dissector (CE-style Dissect Memory). Navigate from a base address
; through pointer chains. See MemoryDissect.ahk.
g_memDissectAddress := 0                ; current base address being viewed
g_memDissectSize := 0x200            ; bytes to read per page (64 rows at 8-byte stride)
g_memDissectBuf := 0               ; last read Buffer, or 0
g_memDissectHistory := []              ; back-navigation stack (Array of Int64 addresses)
g_memDissectFwd := []              ; forward-navigation stack
g_memDissectStatus := "idle"

; Radar Entity-Filter
g_radarShowEnemyNormal := true
g_radarShowEnemyRare := true
g_radarShowEnemyBoss := true
g_radarShowMinions := true
g_radarShowNpcs := true
g_radarShowChests := true

; Entity selected in the Entities tab — radar draws a line to it
g_highlightedEntityPath := ""

; Entities-Tab Type-Filter
g_entityShowPlayer := true
g_entityShowMinion := true
g_entityShowEnemy := true
g_entityShowNPC := true
g_entityShowChest := true
g_entityShowWorldItem := true
g_entityShowOther := true

; Skills & Buffs blacklist
g_skillBuffBlacklist := []

; Zone navigation toggle
g_zoneNavEnabled := true
g_mapHackEnabled := true
g_walkGridEnabled := false   ; walkable-grid fill overlay (diagnostic, off by default)
g_maphackMaskDebug := false  ; red outlines of the HUD clip masks (debug, off by default)
; Maphack source: "memory" = render an overlay on top of the unexplored
; minimap cells (requires PoE2 attached + the radar reading working);
; "ggpk" = patch the visibility shader so the game itself draws every
; cell as explored (requires the game to be closed for the apply step,
; survives until the user reverts).
g_maphackSource := "memory"
; Shader-color overrides for the GGPK maphack. 8-char RRGGBBAA hex
; (no '#'); the patcher receives these verbatim via CLI args.
; Defaults: outline = blue-ish wall ramp at 80% alpha (game's original
; color, just more opaque); background = faint Exile-Forge green at
; 10% alpha so revealed-but-unexplored areas are subtly visible.
g_maphackOutlineHex := "8080FFCC"
g_maphackBackgroundHex := "66FF6619"
; Config tab sub-tab persistence. One of: general / automation /
; overlay / ggpk / filters / debug. Defaults to General on first run.
g_configSubTab := "general"
g_rangeCirclesEnabled := true
g_panelDetectionEnabled := true

; Window geometry (restored from INI by LoadConfig)
g_winX := 20
g_winY := 20
g_winW := 1080
g_winH := 850
g_winMaximized := false

g_flaskKeyLoadStatus := "default"
; Logs live under logs\ to keep the repo root tidy. Ensure the folder exists
; before the error logger writes its header.
try DirCreate(A_ScriptDir "\logs")
g_errorLogPath := A_ScriptDir "\logs\InGameStateMonitor.error.log"
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
LoadCombatAutoConfig()
LoadExplorationConfig()
LoadLootPickupConfig()
LoadEntityGroups()
LoadEntityAlertsConfig()
LoadLocalApiConfig()      ; local HTTP API (MCP backend) settings + Winsock constants
LoadOverlaySystem()       ; build the OverlayManager + all overlays; wire legacy globals
InitProfiler()            ; QPC profiler singleton (disabled until Shift+F3 enables it)
ItemSizeRegistry.Load()   ; ~4000-entry path→(w,h) map used by loot fit-check
AtlasData_Load()          ; Atlas biome/content lookup tables for the map overlay
try g_atlasOverlayEnabled := (IniRead(A_ScriptDir "\poeformance_config.ini", "Atlas", "overlayEnabled", "0") = "1")

; Custom hotkey / macro engine — init defaults then load persisted hotkeys.json
HotkeysInit()
SkillHotkeysInit()
HotkeysLoadConfig()
HotkeysSeedFlaskPresets()   ; one-time: create the default "Flasks" hotkey group (replaces AutoFlask)
g_hkOneShotPerTick := (IniRead(_ConfigPath(), "Hotkeys", "oneShotPerTick", "0") = "1")

; Schedule an auto-refresh check shortly after startup. Runs on a
; background timer so it doesn't block the GUI: PoE2 may not be open
; yet, the user may not have published the ggpk-tools binary, etc. —
; MaybeAutoRefresh handles all those cases gracefully (logs + retries
; / skips). The 8-second delay gives the WebView a chance to attach
; first, so the status callback has somewhere to land.
SetTimer(() => GgpkToolBridge.MaybeAutoRefresh(), -8000)

; AutoPilot is now the only user-facing toggle for combat+explore; the
; sub-flags are kept for status display and config persistence but must
; mirror AutoPilot at startup so a freshly-loaded session can't end up
; with AutoPilot enabled while a sub-routine is silently disabled (or
; vice-versa from a stale config from before the unification).
g_combatAutoEnabled := g_autoPilotEnabled
g_exploreEnabled := g_autoPilotEnabled
RegisterCombatHotkey()
RegisterW2STuneHotkeys()   ; Ctrl +/- tune g_combatW2SScale in-game (only while PoE2 is focused)
_AIP_RegisterProbeHotkeys()   ; TEMP: Ctrl+Alt+Shift+T triggers the Targetable probe in-game

; Custom hotkeys: bind user-defined hotkeys and start the condition evaluator.
HotkeysRegisterAll()
SetTimer(HotkeysEvaluateTick, g_hkEvalInterval)

; ── WebViewGui ────────────────────────────────────────────────────────────────
g_webGui := WebViewGui("+AlwaysOnTop +Resize -Caption +Border", "PoEformance", , { DefaultWidth: g_winW, DefaultHeight: g_winH })

; Override WebViewToo's compiled-mode behaviour.
; The library auto-calls BrowseExe() when A_IsCompiled is true, which sets
; up a catch-all WebResourceRequested route that reads HTML/CSS/JS via
; FindResource against Windows resources embedded in the .exe. We don't
; embed those resources — we ship ui/, data/, etc. as files next to the
; .exe — so every request returns empty content and the WebView renders
; a blank page.
;
; Fix: remove the catch-all filter installed by BrowseExe, drop the
; compiled-routes record for the default host, and install a folder
; mapping instead (same call uncompiled runs use). After this the
; WebView resolves https://ahk.localhost/ui/index.html against
; <exe_dir>/ui/index.html on disk — identical to uncompiled behaviour.
if A_IsCompiled
{
    try
    {
        _wvHost := "ahk.localhost"
        _wvCtrl := g_webGui.Control
        try _wvCtrl.wv.RemoveWebResourceRequestedFilter("http://" _wvHost "/*", 0)
        try _wvCtrl.wv.RemoveWebResourceRequestedFilter("https://" _wvHost "/*", 0)
        if (IsObject(_wvCtrl._CompiledRoutes) && _wvCtrl._CompiledRoutes.Has(_wvHost))
            _wvCtrl._CompiledRoutes.Delete(_wvHost)
        _wvCtrl.BrowseFolder(A_ScriptDir, _wvHost)
    }
    catch as _wvEx
        try LogError("WebView2 compiled BrowseFolder override", _wvEx)
}

g_webGui.OnEvent("Close", (*) => ExitApp())
g_webGui.OnEvent("Size", OnWebGuiSize)
g_webGui.Show()
; Restore saved outer-rect geometry (WinMove uses window rect, not client area)
WinMove(g_winX, g_winY, g_winW, g_winH, "ahk_id " g_webGui.Hwnd)
if g_winMaximized
    g_webGui.Maximize()

; Apply persisted AlwaysOnTop AFTER Show — calling WinSetAlwaysOnTop on
; a not-yet-shown window is a silent no-op, which left the WS_EX_TOPMOST
; from the +AlwaysOnTop creation flag in place regardless of preference.
try WinSetAlwaysOnTop(g_alwaysOnTop ? 1 : 0, "ahk_id " g_webGui.Hwnd)

; Save window geometry on exit and after move/resize
OnExit((*) => (_CaptureWindowGeometry(), SaveConfig(), SaveCombatAutoConfig()))
OnMessage(0x0232, _OnExitSizeMove)  ; WM_EXITSIZEMOVE

; Local HTTP API (MCP backend) — opt-in, bound to 127.0.0.1, off by default.
; Start it here so the hidden message-receiver Gui and OnMessage hook are live
; once the main window exists; tear it down cleanly on exit.
if (g_localApiEnabled)
    StartLocalApiServer()
OnExit((*) => StopLocalApiServer())

; Set window icon (title bar + taskbar) using LoadImage for reliable HICON
try
{
    iconPath := A_ScriptDir "\ui\tray.ico"
    hIconSm := DllCall("LoadImage", "Ptr", 0, "Str", iconPath, "UInt", 1, "Int", 16, "Int", 16, "UInt", 0x10, "Ptr")
    hIconBig := DllCall("LoadImage", "Ptr", 0, "Str", iconPath, "UInt", 1, "Int", 32, "Int", 32, "UInt", 0x10, "Ptr")
    if hIconSm
        SendMessage(0x0080, 0, hIconSm, , "ahk_id " g_webGui.Hwnd)
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
LoadSkillHotkeysFromConfig(g_flaskConfigPath)

; Check for PoE2 patch updates (async-like: runs PowerShell hidden, max ~5s)
CheckPoePatchVersion()
UpdateStatusBar()

; ── Connection state machine ─────────────────────────────────────────────
; The helper no longer bails when PoE2 isn't running at startup. Instead
; it boots into a "disconnected" state, schedules all the game-tick
; timers (which short-circuit while disconnected), and polls every 2 s
; for the process. When PoE2 appears we attach + push a fresh snapshot;
; if the process dies later we transition back to waiting.
;
; This unblocks two workflows:
;   - User launches the helper before the game (or via the "Launch PoE2"
;     button) and the helper hooks itself once login finishes.
;   - GGPK-maphack apply/revert: the user closes the game to patch, then
;     starts it again — the helper auto-reconnects to the fresh PID.
InitializeErrorLog()
g_isConnected := false
; Show a friendly placeholder until EnsureConnected attaches.
try
{
    g_valueTree.Delete()
    g_valueTree.Add("Waiting for PoE2 process…")
    g_valueTree.Add("Start the game (Steam or via the Launch button below).")
}
; AutoFlask retired — replaced by the default "Flasks" hotkey presets (HotkeysSeedFlaskPresets).
; The TryAutoFlask* / ReadAutoFlaskSnapshot code is now dead and pending removal.
SetTimer(UpdateRadarFast, 50)
SetTimer(ReadAndShow, 2000)
SetTimer(EnsureConnected, 2000)
EnsureConnected()  ; immediate first attempt
return

; Drives the PoE2 connection state machine. Called every 2 s by a
; SetTimer plus once immediately at startup. Cheap when PoE2 is
; already attached (single ProcessExist call), more work only on
; the actual connect/disconnect transitions.
;
; Side effects on the global state:
;   - g_isConnected:        bool toggled on each transition
;   - g_lastConnectedPid:   resets g_reader's caches when the PID
;                           rotates (e.g. Steam restarts the game,
;                           or the user restarts via the Launch button)
;   - g_valueTree:          shows a "Waiting for PoE2..." stub while
;                           disconnected, so the user knows the helper
;                           is alive and waiting (not crashed)
;   - WebView header push:  surfaces connection state in the title bar
EnsureConnected()
{
    global g_reader, g_isConnected, g_lastConnectedPid, g_valueTree

    pid := FindPoePid()

    if (!pid)
    {
        ; Process gone. If we were connected, transition to waiting.
        if (g_isConnected)
        {
            g_isConnected := false
            g_lastConnectedPid := 0
            try g_reader.Mem.Close()
            try
            {
                g_valueTree.Delete()
                g_valueTree.Add("Waiting for PoE2 process…")
                g_valueTree.Add("Start the game (Steam or via the Launch button below).")
            }
            try LogError("Helper disconnected — PoE2 process is gone")
        }
        return
    }

    ; PID exists. If we were already connected to THIS pid, nothing to do.
    if (g_isConnected && g_lastConnectedPid = pid)
        return

    ; New pid (fresh launch OR Steam restart) — drop stale state and re-connect.
    if (g_lastConnectedPid && g_lastConnectedPid != pid)
        try LogError("Helper: PoE2 PID rotated " g_lastConnectedPid " → " pid " (restart?). Re-attaching.")

    try g_reader.Mem.Close()
    if (!g_reader.Connect())
    {
        ; Process exists but we couldn't resolve GameStates. This usually
        ; means PoE2 is still loading (pre-login splash). Stay disconnected
        ; and the next poll will retry.
        try LogError("Helper: PoE2 found (pid=" pid ") but Connect() failed — will retry")
        return
    }

    g_isConnected := true
    g_lastConnectedPid := pid
    try LogError("Helper connected to PoE2 (pid=" pid ")")

    ; Opportunistically cache the install path while we have a running
    ; process to derive it from. This unlocks the GGPK maphack workflow
    ; even if the user has never clicked "Refresh all TSVs" yet — they
    ; can just hit Launch PoE2, log in (or not, the path is available
    ; the moment the process exists), close again, and Apply.
    try
    {
        exePath := ProcessGetPath(pid)
        if (exePath != "")
        {
            SplitPath(exePath, , &installDir)
            indexPath := installDir "\Bundles2\_.index.bin"
            ggpkPath := installDir "\Content.ggpk"
            cached := FileExist(indexPath) ? indexPath
                : (FileExist(ggpkPath) ? ggpkPath : "")
            if (cached != "")
                IniWrite(cached, _ConfigPath(), "GgpkTools", "lastIndexPath")
        }
    }

    ; Push a snapshot immediately so the UI tree refreshes without
    ; waiting for the next 2 s ReadAndShow tick.
    try ReadAndShow()
}

; Updates the status bar text and pushes it to the WebView.
UpdateStatusBar()
{
    global g_radarReadMs, g_radarRenderMs, g_radarFps, g_reader
    global POEFORMANCE_VERSION

    patch := GetLastKnownPoeVersion()
    now := FormatTime(A_Now, "HH:mm:ss")

    leftText := "PoEformance v" POEFORMANCE_VERSION " for PoE2 v" (patch != "" ? patch : "—")
    rightText := "Last Updated: " now

    ; Live perf for the status pill — only applied while the Shift+F3 benchmark is
    ; idle; during/after a benchmark run the pill is owned by updateProfilerPill().
    perfText := (g_radarFps > 0) ? (g_radarFps " fps") : ""

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
    global g_webViewReady, g_pendingPatchNotice, g_patchMaint, g_patchMaintPending
    g_webViewReady := true
    SetTimer(PushAllDataToWebView, -100)
    ; Flush a patch-update notice that was raised before the page was ready.
    if (IsSet(g_pendingPatchNotice) && g_pendingPatchNotice != "")
    {
        notice := g_pendingPatchNotice
        g_pendingPatchNotice := ""
        SetTimer(() => WebViewExec(notice), -300)
    }
    ; Start a post-patch maintenance run that was queued before the page loaded.
    if (IsSet(g_patchMaintPending) && g_patchMaintPending != "")
    {
        g_patchMaint := g_patchMaintPending
        g_patchMaintPending := ""
        SetTimer(() => RunPatchMaintenance(), -300)
    }
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
        jargs := data.Has("args") ? data["args"] : []
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
    global g_readAndShowRunning, g_isConnected
    if g_readAndShowRunning
        return
    ; Skip the snapshot while not attached. The tree shows a
    ; "Waiting for PoE2…" stub already (set by EnsureConnected),
    ; so we don't even need to repaint here.
    if (IsSet(g_isConnected) && !g_isConnected)
        return
    g_readAndShowRunning := true
    totalStart := A_TickCount
    try
    {
        global g_reader, g_valueTree, g_nodePaths, g_debugMode, g_updatesPaused, g_autoFlaskEnabled, g_flaskKeyLoadStatus, g_flaskKeyBySlot, g_showTreePane
        global g_lifeThresholdPercent, g_manaThresholdPercent, g_autoFlaskLastReason, autoFlaskStatusText, hotkeyLegendText, g_autoFlaskPerformanceMode, g_lastSnapshotForUi
        global g_treeRefreshRequested

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

#Include ahk/TreeViewWatchlistPanel.ahk

; ── Extracted single-responsibility modules ──────────────────────────────────
#Include ahk/EntityFocus.ahk
#Include ahk/JsonParser.ahk
#Include ahk/JsonFull.ahk
#Include ahk/ErrorLogger.ahk
#Include ahk/Profiler.ahk
#Include ahk/ConfigManager.ahk
#Include ahk/SnapshotSerializers.ahk
#Include ahk/WebViewBridge.ahk
#Include ahk/DebugDump.ahk
#Include ahk/ToggleHandlers.ahk
#Include ahk/BridgeDispatch.ahk
#Include ahk/LocalApiServer.ahk
#Include ahk/GgpkToolBridge.ahk

#Include ahk/AutoFlask.ahk
#Include ahk/AvoidZones.ahk
#Include ahk/TerrainHeights.ahk
#Include ahk/ClickNav.ahk
#Include ahk/CombatAutomation.ahk
#Include ahk/ItemSizeRegistry.ahk
#Include ahk/LootPickup.ahk
#Include ahk/ExplorationModule.ahk
#Include ahk/AutoPilot.ahk
#Include ahk/CustomHotkeys.ahk
#Include ahk/CustomHotkeysBindings.ahk
#Include ahk/CustomHotkeysBridge.ahk
#Include ahk/AtlasData.ahk
#Include ahk/PoE2AtlasReader.ahk
#Include ahk/MemoryDiff.ahk
#Include ahk/MemoryDissect.ahk
#Include ahk/AreaInstanceProbe.ahk
#Include ahk/PathfindingProbe.ahk
#Include ahk/OffsetCompare.ahk
#Include ahk/PatchMaintenance.ahk
#Include ahk/UIHelpers.ahk

; F3: one-shot debug dump — TreeView content, game window screenshot, radar entity TSV.
F3:: OnF3DebugDump()

; The per-tick QPC profiler is toggled by CLICKING the ⏱ status pill in the header
; (ProfilerToggle bridge case → ProfilerToggleDump). It no longer has a hotkey.