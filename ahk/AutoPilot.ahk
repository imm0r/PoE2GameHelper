; AutoPilot.ahk
; Master automation state machine. Owns the shared guard chain and arbitrates
; between combat and exploration sub-routines, which were previously two
; loosely-coordinated top-level features.
;
; State machine:
;   idle    → no automation active (paused, disabled, or guard failed)
;   combat  → TryCombatAutomation engaged an enemy this tick
;   loot    → TryLootPickup is collecting a cached ground item
;   explore → no combat or loot pending, TryExploration is navigating
;
; Priority is combat > loot > explore — each sub-routine returns true to
; claim the tick. The loot module maintains its own cache of filter-passing
; items so drops noticed during combat aren't forgotten once it's safe.
;
; Layering:
;   AutoFlask -> TryAutoPilot -> {TryCombatAutomation, TryLootPickup, TryExploration}
;
; Toggle:
;   g_autoPilotEnabled — only user-facing switch. When on, BOTH combat and
;                        exploration run as a single unified routine; combat
;                        takes priority and pauses exploration whenever a
;                        hostile is in engagement range.
;   g_combatAutoEnabled / g_exploreEnabled are still kept as internal flags
;   for status display but no longer have separate UI toggles — they mirror
;   g_autoPilotEnabled at load time and on each AutoPilot toggle.
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
    global g_updatesPaused

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

    ; ── Priority chain: combat > loot > explore ──────────────────────────
    ; Each sub-routine returns true to claim the tick (block the rest).
    ; Combat first — fighting always beats picking up loot or scouting.
    inCombat := TryCombatAutomation(radarSnap, gameHwnd)
    if (inCombat)
    {
        g_autoPilotState  := "combat"
        g_autoPilotReason := "engaged"
        return
    }

    ; Loot next — when no hostiles are engaged. The pickup module also
    ; refreshes its own cache here so items spotted during combat stay
    ; remembered, and short-circuits internally when no hostile is near AND
    ; the cache is empty.
    inLoot := TryLootPickup(radarSnap, gameHwnd)
    if (inLoot)
    {
        global g_lootLastReason
        g_autoPilotState  := "loot"
        g_autoPilotReason := g_lootLastReason
        return
    }

    ; Explore last — no fight, no loot pending; scout the area.
    TryExploration(radarSnap, gameHwnd)
    g_autoPilotState  := "explore"
    g_autoPilotReason := "scouting"
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
