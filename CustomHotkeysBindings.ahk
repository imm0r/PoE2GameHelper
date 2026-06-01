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

    found := 0
    for line in StrSplit(raw, "`n", "`r")
    {
        slot := 0
        keyValue := ""
        if _TryParseSkillBindingLine(line, &slot, &keyValue)
        {
            normalized := NormalizeConfigKeyToSend(keyValue)
            if (slot >= 1 && slot <= 13 && normalized != "")
            {
                g_skillKeyBySlot[slot] := normalized
                found += 1
            }
        }
    }
    g_skillKeyLoadStatus := (found > 0) ? "config" : "default(no-match)"
    return found > 0
}

; Tries to extract a skill-slot binding from a config line.
; Recognises patterns like: skill1=..., skill_slot_2=..., InputAction_skill3=...
; Sets &slot (1-based) and &keyValue (raw key token). Returns true on match.
_TryParseSkillBindingLine(line, &slot, &keyValue)
{
    slot := 0
    keyValue := ""
    clean := Trim(line)
    if (clean = "" || SubStr(clean, 1, 1) = ";")
        return false
    ; Avoid matching flask lines (handled separately).
    if RegExMatch(clean, "i)flask")
        return false
    if RegExMatch(clean, "i)\bskill[_\s-]*slot[_\s-]*([0-9]+)\b[^=]*=\s*(.+)$", &m)
    {
        slot := Integer(m[1]), keyValue := Trim(m[2])
        return true
    }
    if RegExMatch(clean, "i)\bskill[_\s-]*([0-9]+)\b[^=]*=\s*(.+)$", &m2)
    {
        slot := Integer(m2[1]), keyValue := Trim(m2[2])
        return true
    }
    return false
}

; Builds the bindings payload (flask slots, skill slots, active skill names with
; readiness) and pushes it to updateHotkeyBindings() in the WebView as JSON.
PushHotkeyBindingsToWebView()
{
    global g_webViewReady, g_flaskKeyBySlot, g_skillKeyBySlot, g_reader
    if !g_webViewReady
        return

    ; Flask slots (1-5).
    flaskArr := []
    loop 5
    {
        s := A_Index
        if g_flaskKeyBySlot.Has(s)
            flaskArr.Push(Map("slot", s, "key", g_flaskKeyBySlot[s]))
    }

    ; Skill slots (whatever the config yielded).
    skillSlotArr := []
    for s, k in g_skillKeyBySlot
        skillSlotArr.Push(Map("slot", s, "key", k))

    ; Active skill names for the readiness dropdown (on-demand read).
    skillNames := _CollectActiveSkillNames()

    payload := Map(
        "flaskSlots", flaskArr,
        "skillSlots", skillSlotArr,
        "skillNames", skillNames
    )
    try WebViewExec("updateHotkeyBindings(" _JsStr(JsonFull_Stringify(payload, false)) ")")
}

; Reads the player's currently active skills and returns a sorted array of their
; display names (deduplicated). Returns [] if unavailable.
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
