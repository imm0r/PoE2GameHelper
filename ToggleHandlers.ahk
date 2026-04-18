; ToggleHandlers.ahk
; Toggle functions for all binary settings (debug, pause, autoflask, radar, entity filters).
; Each function flips a global flag, persists the change, and refreshes the UI.
;
; Included by InGameStateMonitor.ahk

; Toggles the debug mode flag and triggers a full UI refresh.
ToggleDebugMode()
{
    global g_debugMode
    g_debugMode := !g_debugMode
    SaveConfig()
    ReadAndShow()
}

; Toggles update pausing; updates the tree root label when pausing, or resumes live updates.
ToggleUpdatesPause()
{
    global g_updatesPaused, g_valueTree
    g_updatesPaused := !g_updatesPaused
    SaveConfig()
    if (g_updatesPaused)
    {
        if g_valueTree
        {
            root := TV_GetRoot(g_valueTree.Hwnd)
            if (root)
                g_valueTree.Modify(root, , RegExReplace(g_valueTree.GetText(root), "Updates:\s+(PAUSED|LIVE)", "Updates: PAUSED"))
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
    global g_autoFlaskEnabled
    g_autoFlaskEnabled := !g_autoFlaskEnabled
    SaveConfig()
    ReadAndShow()
}

; Toggles autoFlaskPerformanceMode (skips full snapshot reads in main loop).
ToggleAutoFlaskPerformanceMode()
{
    global g_autoFlaskPerformanceMode
    g_autoFlaskPerformanceMode := !g_autoFlaskPerformanceMode
    SaveConfig()
    ReadAndShow()
}

; Toggles the radar overlay on/off and hides it when disabled.
ToggleRadar()
{
    global g_radarEnabled, g_radarOverlay
    g_radarEnabled := !g_radarEnabled
    if (!g_radarEnabled && g_radarOverlay)
        g_radarOverlay.Hide()
    SaveConfig()
    PushHeaderToWebView()
}

; Toggles the Player HUD overlay on/off.
TogglePlayerHud()
{
    global g_playerHudEnabled, g_playerHud
    g_playerHudEnabled := !g_playerHudEnabled
    if (!g_playerHudEnabled && g_playerHud)
        g_playerHud.Hide()
    SaveConfig()
    PushHeaderToWebView()
}

; Applies a single entity type filter change and persists it.
; Params: etype - entity type key (player/minion/enemy/npc/chest/worlditem/other)
;         bval  - boolean visibility state
_ApplyEntityFilter(etype, bval)
{
    global g_entityShowPlayer, g_entityShowMinion, g_entityShowEnemy
    global g_entityShowNPC, g_entityShowChest, g_entityShowWorldItem, g_entityShowOther
    switch etype
    {
        case "player":    g_entityShowPlayer    := bval
        case "minion":    g_entityShowMinion    := bval
        case "enemy":     g_entityShowEnemy     := bval
        case "npc":       g_entityShowNPC       := bval
        case "chest":     g_entityShowChest     := bval
        case "worlditem": g_entityShowWorldItem := bval
        case "other":     g_entityShowOther     := bval
    }
    SaveConfig()
    PushHeaderToWebView()
}

; ── Combat Automation toggle + slot config ────────────────────────────────

_ToggleCombatAuto()
{
    global g_combatAutoEnabled, g_combatState, g_combatLastReason
    g_combatAutoEnabled := !g_combatAutoEnabled
    if !g_combatAutoEnabled
    {
        g_combatState := "idle"
        g_combatLastReason := "disabled"
    }
    SaveCombatAutoConfig()
    PushHeaderToWebView()
}

; Applies a skill slot configuration change from the UI.
; Args: [slotNum, key, priority, skillName, type, cooldownMs, enabled]
_ApplyCombatSlotConfig(args)
{
    global g_combatSkillSlots

    slotNum := (args.Length >= 1) ? Integer(args[1]) : 0
    if (slotNum < 1 || slotNum > 8)
        return

    key       := (args.Length >= 2) ? String(args[2]) : ""
    priority  := (args.Length >= 3) ? Integer(args[3]) : slotNum
    skillName := (args.Length >= 4) ? String(args[4]) : ""
    slotType  := (args.Length >= 5) ? String(args[5]) : "single"
    cdMs      := (args.Length >= 6) ? Integer(args[6]) : 0
    enabled   := (args.Length >= 7) ? (args[7] = "true" || args[7] = true || args[7] = 1) : false
    skillRange := (args.Length >= 8) ? Integer(args[8]) : 0

    g_combatSkillSlots[slotNum] := Map(
        "enabled", enabled,
        "key", key,
        "priority", priority,
        "skillName", skillName,
        "name", skillName != "" ? skillName : "Slot" slotNum,
        "type", slotType,
        "cooldownMs", cdMs,
        "lastUseTick", 0,
        "skillRange", skillRange
    )

    SetTimer(() => SaveCombatAutoConfig(), -100)
}
