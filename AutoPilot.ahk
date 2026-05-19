; AutoPilot.ahk
; Master automation state machine. Owns the shared guard chain and arbitrates
; between combat and exploration sub-routines, which were previously two
; loosely-coordinated top-level features.
;
; State machine:
;   idle    → no automation active (paused, disabled, or guard failed)
;   combat  → TryCombatAutomation engaged an enemy this tick
;   explore → no combat target, TryExploration is navigating
;
; Layering:
;   AutoFlask -> TryAutoPilot -> {TryCombatAutomation, TryExploration}
;
; Toggles:
;   g_autoPilotEnabled   — master switch. When off, neither sub-routine runs.
;   g_combatAutoEnabled  — sub-toggle. Skip combat tick inside AutoPilot if false.
;   g_exploreEnabled     — sub-toggle. Skip explore tick inside AutoPilot if false.
;
; Status globals (for UI):
;   g_autoPilotState  — "idle" | "combat" | "explore"
;   g_autoPilotReason — diagnostic string for the current state
;
; Sub-routines still maintain their granular reasons (g_combatLastReason,
; g_exploreLastReason) for detailed status displays.
;
; Included by InGameStateMonitor.ahk

; ── Entry point (called from AutoFlask UpdateRadarFast tick) ──────────────
TryAutoPilot(radarSnap)
{
    static _running := false
    if _running
        return
    _running := true
    try
        _RunAutoPilot(radarSnap)
    catch as ex
        LogError("TryAutoPilot", ex)
    finally
        _running := false
}

_RunAutoPilot(radarSnap)
{
    global g_autoPilotEnabled, g_autoPilotState, g_autoPilotReason
    global g_combatAutoEnabled, g_exploreEnabled, g_updatesPaused

    ; Master gate. Updates are paused or master switch is off.
    if (g_updatesPaused || !g_autoPilotEnabled)
    {
        g_autoPilotState  := "idle"
        g_autoPilotReason := g_updatesPaused ? "paused" : "disabled"
        return
    }

    ; ── Shared guard chain (was duplicated across combat + explore) ──────
    guard := _CheckAutoPilotGuards(radarSnap)
    if !guard["allowed"]
    {
        g_autoPilotState  := "idle"
        g_autoPilotReason := guard["reason"]
        return
    }
    gameHwnd := guard["gameHwnd"]

    ; ── Combat takes priority. If it engaged this tick, skip exploration ─
    if g_combatAutoEnabled
    {
        inCombat := TryCombatAutomation(radarSnap, gameHwnd)
        if (inCombat)
        {
            g_autoPilotState  := "combat"
            g_autoPilotReason := "engaged"
            return
        }
    }

    ; ── No combat target — explore the area ──────────────────────────────
    if g_exploreEnabled
    {
        TryExploration(radarSnap, gameHwnd)
        g_autoPilotState  := "explore"
        g_autoPilotReason := "scouting"
        return
    }

    ; Neither sub-routine is enabled.
    g_autoPilotState  := "idle"
    g_autoPilotReason := "no-sub-enabled"
}

; ── Shared guard chain ────────────────────────────────────────────────────
; Returns a Map with:
;   "allowed"  — true if all guards passed
;   "reason"   — short diagnostic string when allowed=false
;   "gameHwnd" — resolved PoE2 window handle (only meaningful when allowed=true)
_CheckAutoPilotGuards(radarSnap)
{
    out := Map("allowed", false, "reason", "", "gameHwnd", 0)

    gameHwnd := ResolvePoEWindow()
    if !gameHwnd
    {
        out["reason"] := "no-game-window"
        return out
    }
    if !WinActive("ahk_id " gameHwnd)
    {
        out["reason"] := "game-not-focused"
        return out
    }

    ; Block in town/hideout — automation makes no sense there.
    wad := radarSnap.Has("worldAreaDat") ? radarSnap["worldAreaDat"] : 0
    if (wad && IsObject(wad))
    {
        if ((wad.Has("isTown") && wad["isTown"]) || (wad.Has("isHideout") && wad["isHideout"]))
        {
            out["reason"] := "town-hideout"
            return out
        }
    }

    ; Block when any game panel (inventory, passive tree, map, etc.) is open —
    ; sending clicks/keys while a panel is up would target the panel, not the world.
    panelVis := radarSnap.Has("panelVisibility") ? radarSnap["panelVisibility"] : 0
    if (panelVis && IsObject(panelVis) && panelVis.Has("anyPanelOpen") && panelVis["anyPanelOpen"])
    {
        out["reason"] := "panel-open"
        return out
    }

    ; Block when player is dead. Previously only checked inside combat —
    ; now applies to explore as well, which is correct (a corpse can't navigate).
    pv := radarSnap.Has("playerVitals") ? radarSnap["playerVitals"] : 0
    if (pv && IsObject(pv) && pv.Has("stats"))
    {
        stats := pv["stats"]
        if (stats.Has("isAlive") && !stats["isAlive"])
        {
            out["reason"] := "dead"
            return out
        }
    }

    out["allowed"]  := true
    out["gameHwnd"] := gameHwnd
    return out
}
