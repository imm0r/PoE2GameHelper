; CustomHotkeysBindings.ahk
; Resolves the in-game key bindings (flask slots, skill slots) and exposes them
; — together with the currently active skill names and their cooldown readiness —
; to the Hotkeys UI, so a macro's output key is picked from a dropdown of real
; in-game binds instead of being typed freely.
;
; Data sources:
;   - Flask slot keys:  g_flaskKeyBySlot (parsed from poe2_production_Config.ini).
;   - Skill slot keys:  g_skillKeyBySlot (best-effort parse of the same INI; the
;                       exact key names PoE2 uses for skill slots are unconfirmed,
;                       so this may legitimately come back empty).
;   - Skill readiness:  DecodeActorSkills() -> per-skill "canUse" / "cooldownMs",
;                       keyed by skill NAME (the game exposes no slot->skill link).
;
; Included by InGameStateMonitor.ahk

; Initializes the skill-key map to empty. Called once at startup.
SkillHotkeysInit()
{
    global g_skillKeyBySlot := Map()
    global g_skillKeyLoadStatus := "default"
}

; Best-effort parse of skill-slot key bindings from the PoE2 config INI.
; Populates g_skillKeyBySlot (slotNumber -> AHK send key). PoE2's exact config
; key names for skill slots are unconfirmed, so several patterns are tried; if
; none match the map stays empty and the UI simply shows no skill binds.
; Params: configPath - full path to poe2_production_Config.ini.
LoadSkillHotkeysFromConfig(configPath)
{
    global g_skillKeyBySlot, g_skillKeyLoadStatus
    g_skillKeyBySlot := Map()
    g_skillKeyLoadStatus := "default"

    if !FileExist(configPath)
    {
        g_skillKeyLoadStatus := "missing"
        return false
    }
    raw := ""
    try raw := FileRead(configPath, "UTF-8")
    catch
    {
        try raw := FileRead(configPath)
        catch
        {
            g_skillKeyLoadStatus := "read-error"
            return false
        }
    }
    if (StrLen(raw) < 5)
    {
        g_skillKeyLoadStatus := "empty"
        return false
    }

    lines := StrSplit(raw, "`n", "`r")

    ; PoE2 keeps two skill-bind sections — [ACTION_KEYS] and [WASD_ACTION_KEYS] —
    ; with different bindings; the active one is chosen by user_input_mode.
    inputMode := ""
    for line in lines
    {
        if RegExMatch(Trim(line), "i)^user_input_mode\s*=\s*(\S+)", &mm)
        {
            inputMode := StrLower(mm[1])
            break
        }
    }
    targetSection := (inputMode = "wasd") ? "wasd_action_keys" : "action_keys"

    ; Parse use_bound_skillN within the chosen section. Values are decimal VK
    ; codes; a trailing " 2" is the weapon-set indicator (same physical key) and
    ; is ignored. VK 0 means unbound.
    found := 0
    curSection := ""
    for line in lines
    {
        clean := Trim(line)
        if (clean = "" || SubStr(clean, 1, 1) = ";")
            continue
        if RegExMatch(clean, "^\[(.+)\]$", &sm)
        {
            curSection := StrLower(sm[1])
            continue
        }
        if (curSection != targetSection)
            continue
        if RegExMatch(clean, "i)^use_bound_skill([0-9]+)\s*=\s*(.+)$", &m)
        {
            slot := Integer(m[1])
            vkTok := Trim(m[2])
            if RegExMatch(vkTok, "^(\d+)", &vm)   ; primary VK; drop weapon-set suffix
                vkTok := vm[1]
            if (vkTok = "0")
                continue
            normalized := NormalizeConfigKeyToSend(vkTok)
            if (slot >= 1 && normalized != "")
            {
                g_skillKeyBySlot[slot] := normalized
                found += 1
            }
        }
    }
    g_skillKeyLoadStatus := (found > 0) ? ("config:" targetSection) : "default(no-match)"
    return found > 0
}

; Builds the bindings payload (flask slots, skill slots, active skill names with
; readiness) and pushes it to updateHotkeyBindings() in the WebView as JSON.
PushHotkeyBindingsToWebView()
{
    global g_webViewReady, g_flaskKeyBySlot, g_skillKeyBySlot, g_reader
    if !g_webViewReady
        return

    ; Flask slots — PoE2 only uses slots 1 (life) and 2 (mana) as user-pressable
    ; flasks; slots 3-5 are charms that trigger automatically (no hotkey).
    flaskArr := []
    loop 2
    {
        s := A_Index
        if g_flaskKeyBySlot.Has(s)
            flaskArr.Push(Map("slot", s, "key", g_flaskKeyBySlot[s]))
    }

    ; Skill slots (whatever the config yielded), in ascending slot order.
    skillSlotArr := []
    loop 24
    {
        s := A_Index
        if g_skillKeyBySlot.Has(s)
            skillSlotArr.Push(Map("slot", s, "key", g_skillKeyBySlot[s]))
    }

    ; Active skill names for the readiness dropdown (on-demand read).
    skillNames := _CollectActiveSkillNames()

    payload := Map(
        "flaskSlots", flaskArr,
        "skillSlots", skillSlotArr,
        "skillNames", skillNames,
        "chestTypes", _CollectChestTypes()
    )
    try WebViewExec("updateHotkeyBindings(" _JsStr(JsonFull_Stringify(payload, false)) ")")
}

; Collects the distinct chest-type tokens present in the current area (the path
; segment after "chests/", plus "strongbox" when seen). These feed the aim
; action's chest-type dropdown so it reflects what's actually around.
; Returns an array of lowercase substring tokens (may be empty).
_CollectChestTypes()
{
    global g_radarLastSnap
    out := []
    seen := Map()
    snap := (g_radarLastSnap && g_radarLastSnap is Map) ? g_radarLastSnap : 0
    if !snap
        return out
    inGs := snap.Has("inGameState") ? snap["inGameState"] : 0
    area := (inGs && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    if !area
        return out
    for listKey in ["awakeEntities", "sleepingEntities"]
    {
        lst := area.Has(listKey) ? area[listKey] : 0
        sample := (lst && lst is Map && lst.Has("sample")) ? lst["sample"] : 0
        if !(sample is Array)
            continue
        for entry in sample
        {
            entity := (entry is Map && entry.Has("entity")) ? entry["entity"] : 0
            if !(entity is Map)
                continue
            path := entity.Has("path") ? StrLower(entity["path"]) : ""
            if (path = "" || (!InStr(path, "chest") && !InStr(path, "strongbox")))
                continue
            tok := ""
            if RegExMatch(path, "chests/([^/]+)", &m)
                tok := m[1]
            else if InStr(path, "strongbox")
                tok := "strongbox"
            if (tok != "" && !seen.Has(tok))
            {
                seen[tok] := true
                out.Push(tok)
            }
        }
    }
    return out
}

; Reads the player's currently active skills and returns an array of their display
; names (deduplicated). Internal/engine skills (Move, Interaction, [DNT-UNUSED]…) are
; filtered out via hasRealName, so only real, translated skill names remain — the skill
; cooldown-gate dropdown only makes sense for those. Returns [] if unavailable.
_CollectActiveSkillNames()
{
    global g_reader, g_radarLastSnap
    names := []
    seen := Map()
    snap := (g_radarLastSnap && g_radarLastSnap is Map) ? g_radarLastSnap : 0
    if !snap
        return names
    inGs := snap.Has("inGameState") ? snap["inGameState"] : 0
    area := (inGs && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    lpPtr := (area && area.Has("localPlayerPtr")) ? area["localPlayerPtr"] : 0
    if !lpPtr
        return names
    skillsData := 0
    try skillsData := g_reader.ReadPlayerSkills(lpPtr)
    if !(skillsData && skillsData is Map && skillsData.Has("skills"))
        return names
    for sk in skillsData["skills"]
    {
        if !(sk is Map)
            continue
        ; Skip internal/engine skills (Move, Interaction, [DNT-UNUSED]…). hasRealName marks
        ; skills resolved to a real DisplayedName — the same flag the Skills & Buffs tab uses
        ; for its "internal skills" toggle. The cooldown gate only makes sense for real skills.
        if !(sk.Has("hasRealName") && sk["hasRealName"])
            continue
        nm := sk.Has("displayName") && sk["displayName"] != "" ? sk["displayName"]
            : (sk.Has("name") ? sk["name"] : "")
        if (nm != "" && !seen.Has(nm))
        {
            seen[nm] := true
            names.Push(nm)
        }
    }
    return names
}

; Returns readiness info for a skill by (display or internal) name from an
; on-demand skills read: Map("found",bool, "canUse",bool, "cooldownMs",int).
; Used by the engine's skill-output readiness gate.
HotkeysSkillReadiness(skillName)
{
    global g_reader, g_radarLastSnap
    out := Map("found", false, "canUse", false, "cooldownMs", 0)
    if (Trim(skillName) = "")
        return out
    snap := (g_radarLastSnap && g_radarLastSnap is Map) ? g_radarLastSnap : 0
    if !snap
        return out
    inGs := snap.Has("inGameState") ? snap["inGameState"] : 0
    area := (inGs && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    lpPtr := (area && area.Has("localPlayerPtr")) ? area["localPlayerPtr"] : 0
    if !lpPtr
        return out
    skillsData := 0
    try skillsData := g_reader.ReadPlayerSkills(lpPtr)
    if !(skillsData && skillsData is Map && skillsData.Has("skills"))
        return out
    needle := StrLower(skillName)
    for sk in skillsData["skills"]
    {
        if !(sk is Map)
            continue
        dn := sk.Has("displayName") ? StrLower(sk["displayName"]) : ""
        inm := sk.Has("name") ? StrLower(sk["name"]) : ""
        if (dn = needle || inm = needle)
        {
            out["found"] := true
            out["canUse"] := sk.Has("canUse") ? (sk["canUse"] ? true : false) : true
            out["cooldownMs"] := sk.Has("cooldownMs") ? (sk["cooldownMs"] + 0) : 0
            return out
        }
    }
    return out
}

; Called on every radar tick. Re-pushes hotkey bindings (including the
; chest-type list) to the UI when the area instance address changes,
; so the dropdown reflects the new area without requiring a tab reload.
; Params: snap - current radar snapshot Map.
HotkeyBindingsOnAreaChange(snap)
{
    static _lastAreaAddr := 0
    inGs := (snap && snap.Has("inGameState")) ? snap["inGameState"] : 0
    addr := (inGs && inGs.Has("areaInstanceData")) ? inGs["areaInstanceData"] : 0
    if (addr = 0 || addr = _lastAreaAddr)
        return
    _lastAreaAddr := addr
    SetTimer(PushHotkeyBindingsToWebView, -1)
}
