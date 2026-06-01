; CustomHotkeys.ahk
; Custom hotkey / macro engine. Provides user-defined hotkey groups, each
; containing hotkeys with global conditions and an ordered list of actions
; (repeat, hold, chain, vitals/buff/charge/monster-count gates, auto-aim).
;
; Data model (also the on-disk shape in hotkeys.json):
;   g_hotkeyGroups := [
;     Map("name", "...", "enabled", 1, "hotkeys", [
;       Map("id", 1, "name", "...", "enabled", 1,
;           "focusOnly", 1, "safeZoneDisabled", 1,
;           "key", "1", "mods", Map("ctrl",0,"shift",0,"alt",0,"gamepadLT",0),
;           "actions", [ Map("type","vitals", ...), ... ])
;     ])
;   ]
;
; Runtime state (not persisted) lives in g_hkRuntime[id].
;
; Reuses existing building blocks: ResolvePoEWindow, _SendSkillKey,
; _WorldToScreen, _MoveMouseToTarget (CombatAutomation/AutoFlask), the radar
; snapshot in g_radarLastSnap, and g_reader for on-demand buff reads.
;
; Included by InGameStateMonitor.ahk

; Returns the absolute path to the custom-hotkey config file.
_HotkeysConfigPath() => A_ScriptDir "\hotkeys.json"

; Initializes the custom-hotkey globals to empty defaults.
; Call once during startup before HotkeysLoadConfig().
HotkeysInit()
{
    global g_hotkeyGroups := []
    global g_hkNextId := 1
    global g_hkRuntime := Map()           ; id -> runtime Map
    global g_hkRegisteredBindings := []   ; AHK hotkey strings currently bound
    global g_hkEvalInterval := 120        ; ms between auto-trigger evaluations
    global g_hkInjectGuard := Map()       ; lowercased key -> expiry tick (self-injection guard)
    global g_hkOneShotPerTick := false    ; when true, at most one hotkey auto-fires per eval tick
    global g_hkDebugItems := []           ; per-frame debug records for actions with debug on (read by the overlay)
}

; ── Persistence ────────────────────────────────────────────────────────────

; Loads hotkey groups from hotkeys.json into g_hotkeyGroups, normalizing each
; entry and assigning unique ids. Keeps empty defaults if the file is missing.
HotkeysLoadConfig()
{
    global g_hotkeyGroups, g_hkNextId
    path := _HotkeysConfigPath()
    if !FileExist(path)
        return
    raw := ""
    try raw := FileRead(path, "UTF-8")
    if (raw = "")
        return
    parsed := JsonFull_Parse(raw)
    if !(parsed is Array)
        return
    g_hotkeyGroups := _HotkeysNormalizeGroups(parsed)
}

; Normalizes a parsed JSON array of groups into the in-memory model, assigning
; unique ids and updating g_hkNextId. Returns the normalized groups array.
; Shared by HotkeysLoadConfig() and the UI config-apply path.
_HotkeysNormalizeGroups(parsed)
{
    global g_hkNextId
    groups := []
    maxId := 0
    for grp in parsed
    {
        if !(grp is Map)
            continue
        normGroup := Map(
            "name", grp.Has("name") ? grp["name"] : "Group",
            "enabled", _HkBool(grp, "enabled", 1),
            "hotkeys", []
        )
        hkList := (grp.Has("hotkeys") && grp["hotkeys"] is Array) ? grp["hotkeys"] : []
        for hk in hkList
        {
            if !(hk is Map)
                continue
            normHk := _HotkeysNormalizeHotkey(hk)
            if (normHk["id"] > maxId)
                maxId := normHk["id"]
            normGroup["hotkeys"].Push(normHk)
        }
        groups.Push(normGroup)
    }
    if (maxId >= g_hkNextId)
        g_hkNextId := maxId + 1
    return groups
}

; Normalizes a single hotkey Map read from JSON, filling missing fields with
; sensible defaults. Returns the normalized hotkey Map.
_HotkeysNormalizeHotkey(hk)
{
    global g_hkNextId
    id := (hk.Has("id") && IsInteger(hk["id"]) && hk["id"] > 0) ? hk["id"] : 0
    if (id = 0)
    {
        id := g_hkNextId
        g_hkNextId += 1
    }
    modsRaw := (hk.Has("mods") && hk["mods"] is Map) ? hk["mods"] : Map()
    mods := Map(
        "ctrl",      _HkBool(modsRaw, "ctrl", 0),
        "shift",     _HkBool(modsRaw, "shift", 0),
        "alt",       _HkBool(modsRaw, "alt", 0),
        "gamepadLT", _HkBool(modsRaw, "gamepadLT", 0)
    )
    actions := []
    actRaw := (hk.Has("actions") && hk["actions"] is Array) ? hk["actions"] : []
    for a in actRaw
        if (a is Map)
            actions.Push(a)
    ; Output binding: where the macro's key comes from.
    ;   kind "flask"  -> slot (1-5), key resolved live from g_flaskKeyBySlot
    ;   kind "skill"  -> slot (skill-bar slot), key from g_skillKeyBySlot, plus
    ;                    skillName for the cooldown-readiness gate
    ;   kind "key"    -> a literal key (legacy / free binding)
    outRaw := (hk.Has("output") && hk["output"] is Map) ? hk["output"] : Map()
    output := Map(
        "kind", outRaw.Has("kind") ? outRaw["kind"] : (hk.Has("key") && hk["key"] != "" ? "key" : "flask"),
        "slot", outRaw.Has("slot") ? (outRaw["slot"] + 0) : 1,
        "skillName", outRaw.Has("skillName") ? outRaw["skillName"] : "",
        "key", outRaw.Has("key") ? outRaw["key"] : (hk.Has("key") ? hk["key"] : "")
    )
    ; Trigger mode: "manual" fires only on a physical key press; "automated"
    ; auto-fires from the eval tick whenever the hotkey's conditions are met.
    ; Default for legacy configs: automated if it has a condition action.
    hasCond := false
    for a in actions
    {
        if (a is Map && a.Has("type"))
        {
            ct := a["type"]
            if (ct = "vitals" || ct = "buff" || ct = "charges" || ct = "monsterCount" || ct = "monsterCountCursor")
                hasCond := true
        }
    }
    trigger := hk.Has("trigger") ? hk["trigger"] : (hasCond ? "automated" : "manual")
    if (trigger != "automated" && trigger != "manual")
        trigger := "manual"
    return Map(
        "id", id,
        "name", hk.Has("name") ? hk["name"] : ("Hotkey #" id),
        "enabled", _HkBool(hk, "enabled", 1),
        "trigger", trigger,
        "focusOnly", _HkBool(hk, "focusOnly", 1),
        "safeZoneDisabled", _HkBool(hk, "safeZoneDisabled", 0),
        "passThrough", _HkBool(hk, "passThrough", 0),
        "key", hk.Has("key") ? hk["key"] : "",
        "output", output,
        "mods", mods,
        "actions", actions
    )
}

; Resolves the actual AHK send-key for a hotkey's output binding (live, so
; config-driven flask/skill keys always reflect the current game config).
; Returns the key string, or "" if unresolved.
_HotkeysResolveKey(hk)
{
    global g_flaskKeyBySlot, g_skillKeyBySlot
    out := (hk.Has("output") && hk["output"] is Map) ? hk["output"] : 0
    if !out
        return hk.Has("key") ? hk["key"] : ""
    kind := out.Has("kind") ? out["kind"] : "key"
    slot := out.Has("slot") ? (out["slot"] + 0) : 0
    if (kind = "flask")
        return (g_flaskKeyBySlot.Has(slot)) ? g_flaskKeyBySlot[slot] : ""
    if (kind = "skill")
        return (g_skillKeyBySlot.Has(slot)) ? g_skillKeyBySlot[slot] : (out.Has("key") ? out["key"] : "")
    return out.Has("key") ? out["key"] : (hk.Has("key") ? hk["key"] : "")
}

; Readiness gate for the output binding: true if the bound flask has charges /
; the bound skill is off cooldown. Free "key" bindings are always ready.
; Returns Map("ready", bool, "cooldownMs", int).
_HotkeysOutputReadiness(hk)
{
    out := (hk.Has("output") && hk["output"] is Map) ? hk["output"] : 0
    if !out
        return Map("ready", true, "cooldownMs", 0)
    kind := out.Has("kind") ? out["kind"] : "key"
    if (kind = "skill")
    {
        nm := out.Has("skillName") ? out["skillName"] : ""
        if (nm = "")
            return Map("ready", true, "cooldownMs", 0)
        r := HotkeysSkillReadiness(nm)
        return Map("ready", r["found"] ? r["canUse"] : true, "cooldownMs", r["cooldownMs"])
    }
    ; Flask charge counts are not present in the radar snapshot (only buff
    ; data is), so a flask readiness gate can't be evaluated reliably here —
    ; treat flask/key bindings as always ready.
    return Map("ready", true, "cooldownMs", 0)
}

; Serializes g_hotkeyGroups to hotkeys.json (pretty-printed for hand-editing).
HotkeysSaveConfig()
{
    global g_hotkeyGroups
    path := _HotkeysConfigPath()
    json := JsonFull_Stringify(g_hotkeyGroups, true)
    try
    {
        f := FileOpen(path, "w", "UTF-8")
        if f
        {
            f.Write(json)
            f.Close()
        }
    }
}

; Reads a truthy/0-1 value from a Map key with a default. Accepts 1/0, true/false.
_HkBool(m, key, def)
{
    if !(m is Map) || !m.Has(key)
        return def
    v := m[key]
    if (v = true || v = 1 || v = "true" || v = "1")
        return 1
    if (v = false || v = 0 || v = "false" || v = "0" || v = "")
        return 0
    return def
}

; ── Hotkey registration ────────────────────────────────────────────────────

; (Re-)registers AHK Hotkey() bindings for every enabled hotkey that has a key.
; Unbinds previously-registered bindings first. Gamepad LT is accepted in the
; data model but not bound here (AHK cannot bind an analog trigger directly).
HotkeysRegisterAll()
{
    global g_hotkeyGroups, g_hkRegisteredBindings

    for binding in g_hkRegisteredBindings
    {
        try Hotkey(binding, , "Off")
    }
    g_hkRegisteredBindings := []

    for grp in g_hotkeyGroups
    {
        if !grp["enabled"]
            continue
        for hk in grp["hotkeys"]
        {
            if (!hk["enabled"] || Trim(hk["key"]) = "")
                continue
            ; Automated hotkeys have no manual trigger key — don't register one,
            ; otherwise a leftover key from a former manual binding would keep
            ; firing the macro (and suppress the native key when passThrough is off).
            if (hk["trigger"] = "automated")
                continue
            binding := _HotkeysBuildBinding(hk)
            if (binding = "")
                continue
            id := hk["id"]
            try
            {
                Hotkey(binding, _HotkeysMakeHandler(id), "On")
                g_hkRegisteredBindings.Push(binding)
            }
            catch as ex
            {
                LogError("HotkeysRegisterAll(" binding ")", ex)
            }
        }
    }
}

; Builds the AHK hotkey string for a hotkey from its modifiers and key.
; Uses "~" (non-blocking, native key still reaches the game) and "$"
; (keyboard hook). Returns "" if the key is empty.
_HotkeysBuildBinding(hk)
{
    key := Trim(hk["key"])
    if (key = "")
        return ""
    mods := hk["mods"]
    prefix := ""
    if (mods["ctrl"])
        prefix .= "^"
    if (mods["shift"])
        prefix .= "+"
    if (mods["alt"])
        prefix .= "!"
    ; By default the trigger key is SUPPRESSED (no "~"): the macro's actions
    ; re-send the output key, so passing the native key through too would
    ; double it. Set passThrough on a hotkey to also let the native key reach
    ; the game. "$" forces the keyboard hook (keyboard keys only, not mouse).
    kl := StrLower(key)
    isMouse := (kl = "lbutton" || kl = "rbutton" || kl = "mbutton" || kl = "xbutton1" || kl = "xbutton2" || kl = "wheelup" || kl = "wheeldown")
    pass := (hk.Has("passThrough") && hk["passThrough"]) ? "~" : ""
    hook := isMouse ? pass : (pass "$")
    return hook prefix key
}

; Returns a callback bound to a specific hotkey id, fired in "user" context.
_HotkeysMakeHandler(id)
{
    return (*) => _HotkeysFire(id, "user")
}

; ── Lookup helpers ─────────────────────────────────────────────────────────

; Finds a hotkey (and its owning group) by id. Returns Map("group",g,"hotkey",hk) or 0.
_HotkeysFindById(id)
{
    global g_hotkeyGroups
    for grp in g_hotkeyGroups
        for hk in grp["hotkeys"]
            if (hk["id"] = id)
                return Map("group", grp, "hotkey", hk)
    return 0
}

; Returns the cached radar snapshot if it is a usable Map, else 0.
_HotkeysSnap()
{
    global g_radarLastSnap
    return (g_radarLastSnap && g_radarLastSnap is Map) ? g_radarLastSnap : 0
}

; ── Evaluation loop ────────────────────────────────────────────────────────

; Periodic timer body: evaluates every enabled hotkey that contains a
; condition action (vitals/buff/charges/monsterCount) and fires it in
; "program" context when its conditions pass and the re-fire interval elapsed.
HotkeysEvaluateTick()
{
    global g_hotkeyGroups, g_hkRuntime, g_hkOneShotPerTick
    _HotkeysCollectDebug()
    for grp in g_hotkeyGroups
    {
        if !grp["enabled"]
            continue
        for hk in grp["hotkeys"]
        {
            if !hk["enabled"]
                continue
            ; Only "automated"-trigger hotkeys auto-fire here; manual ones fire
            ; on a physical key press (via their registered Hotkey()).
            if (hk["trigger"] != "automated")
                continue
            ; Automated firing is condition-driven: a hotkey with no condition
            ; gate would otherwise spam its effects every tick. Require at least
            ; one condition action before auto-firing.
            if !_HotkeysHasConditionAction(hk)
                continue

            id := hk["id"]
            rt := _HotkeysRuntime(id)
            ; Re-fire throttle: at least the bound skill's cooldown (so a skill
            ; hotkey never fires faster than the skill can be cast), else the
            ; smallest repeat interval, else a 250ms default.
            minGap := _HotkeysReFireGap(hk)
            rdy := _HotkeysOutputReadiness(hk)
            if (rdy["cooldownMs"] > minGap)
                minGap := rdy["cooldownMs"]
            if ((A_TickCount - rt["lastAutoFire"]) < minGap)
                continue

            ; Skill/flask readiness gate: only fire when the bound skill is off
            ; cooldown (flasks/keys are always ready — see _HotkeysOutputReadiness).
            if !rdy["ready"]
                continue

            if _HotkeysActionsWouldRun(hk)
            {
                rt["lastAutoFire"] := A_TickCount
                _HotkeysFire(id, "program")
                ; Global one-shot: at most one hotkey fires per evaluation tick.
                if (IsSet(g_hkOneShotPerTick) && g_hkOneShotPerTick)
                    return
            }
        }
    }
}

; Rebuilds g_hkDebugItems for this frame: one record per action that has its
; debug flag on, holding what the overlay should draw (name/id, range circle,
; per-rarity monster counts, skill cooldown, charge count). Cheap data only;
; the overlay does the drawing.
_HotkeysCollectDebug()
{
    global g_hotkeyGroups, g_hkDebugItems
    items := []
    snap := _HotkeysSnap()
    for grp in g_hotkeyGroups
    {
        if !grp["enabled"]
            continue
        for hk in grp["hotkeys"]
        {
            if !hk["enabled"]
                continue
            ai := 0
            for a in hk["actions"]
            {
                ai += 1
                if !(a is Map && a.Has("debug") && a["debug"])
                    continue
                items.Push(_HotkeysBuildDebugRecord(hk, a, ai, snap))
            }
        }
    }
    g_hkDebugItems := items
}

; Builds a single debug record Map for one action. Fields are kept generic so
; the overlay can render whatever is present:
;   label, kind, circleWorld | circleCursorPx, counts(Map rarity->n),
;   countTotal, cooldownMs, ready, charges
_HotkeysBuildDebugRecord(hk, a, ai, snap)
{
    t := a.Has("type") ? a["type"] : ""
    rec := Map(
        "label", hk["name"] " #" hk["id"] " · " t,
        "kind", t,
        "lines", []
    )

    if (t = "monsterCount")
    {
        radius := a.Has("radius") ? (a["radius"] + 0) : 1500
        rec["circleWorld"] := radius
        counts := _HotkeysCountByRarity(snap, radius, "world")
        rec["counts"] := counts
        rec["lines"].Push("N:" counts["normal"] " M:" counts["magic"] " R:" counts["rare"] " U:" counts["unique"] " =" counts["total"])
    }
    else if (t = "monsterCountCursor")
    {
        px := a.Has("radius") ? (a["radius"] + 0) : 120
        rec["circleCursorPx"] := px
        counts := _HotkeysCountByRarity(snap, px, "cursor")
        rec["counts"] := counts
        rec["lines"].Push("@cursor N:" counts["normal"] " M:" counts["magic"] " R:" counts["rare"] " U:" counts["unique"] " =" counts["total"])
    }
    else if (t = "aim")
    {
        radius := a.Has("radius") ? (a["radius"] + 0) : 1500
        rec["circleWorld"] := radius
        rec["lines"].Push("aim radius " radius)
    }
    else if (t = "charges")
    {
        type := a.Has("chargeType") ? a["chargeType"] : "power"
        nameMap := Map("power", "power_charge", "frenzy", "frenzy_charge", "endurance", "endurance_charge", "charged_staff", "charged_staff_stack")
        eff := _HotkeysFindBuff(snap, nameMap.Has(type) ? nameMap[type] : type)
        n := (eff && eff.Has("charges")) ? (eff["charges"] + 0) : 0
        rec["charges"] := n
        rec["lines"].Push(type " charges: " n)
    }
    else if (t = "buff")
    {
        nm := a.Has("buffName") ? a["buffName"] : ""
        eff := (nm != "") ? _HotkeysFindBuff(snap, nm) : 0
        if (eff)
            rec["lines"].Push("buff '" nm "' x" (eff.Has("charges") ? eff["charges"] : 0) " " (eff.Has("timeLeft") ? Round(eff["timeLeft"]) "ms" : ""))
        else
            rec["lines"].Push("buff '" nm "' absent")
    }
    else if (t = "vitals")
    {
        rec["lines"].Push("vitals " (a.Has("resource") ? a["resource"] : "hp") " " (a.Has("op") ? a["op"] : "<=") " " (a.Has("value") ? a["value"] : 0) "%")
    }

    ; Output skill cooldown / readiness (applies to any debugged action).
    rdy := _HotkeysOutputReadiness(hk)
    if (rdy["cooldownMs"] > 0 || !rdy["ready"])
        rec["lines"].Push("skill " (rdy["ready"] ? "READY" : "on CD") (rdy["cooldownMs"] > 0 ? " (" rdy["cooldownMs"] "ms)" : ""))
    return rec
}

; Counts hostile entities by rarity within a radius. mode "world" uses the
; per-entity world distance; "cursor" projects to screen and measures pixels
; from the cursor. Returns Map("normal","magic","rare","unique","total").
_HotkeysCountByRarity(snap, radius, mode)
{
    out := Map("normal", 0, "magic", 0, "rare", 0, "unique", 0, "total", 0)
    if !snap
        return out
    cx := 0, cy := 0, gameHwnd := 0, w2sMatrix := 0, pX := 0, pY := 0, pZ := 0
    if (mode = "cursor")
    {
        gameHwnd := ResolvePoEWindow()
        if !gameHwnd
            return out
        CoordMode("Mouse", "Screen")
        MouseGetPos(&cx, &cy)
        inGs := snap.Has("inGameState") ? snap["inGameState"] : 0
        w2sMatrix := (inGs && inGs.Has("w2sMatrix")) ? inGs["w2sMatrix"] : 0
        area := (inGs && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
        prc := (area && area.Has("playerRenderComponent")) ? area["playerRenderComponent"] : 0
        pwp := (prc && prc is Map && prc.Has("worldPosition")) ? prc["worldPosition"] : 0
        pX := (pwp && pwp.Has("x")) ? pwp["x"] : 0
        pY := (pwp && pwp.Has("y")) ? pwp["y"] : 0
        pZ := (pwp && pwp.Has("z")) ? pwp["z"] : 0
    }
    rarKeys := Map(0, "normal", 1, "magic", 2, "rare", 3, "unique")
    for entry in _HotkeysAwakeSample(snap)
    {
        entity := entry.Has("entity") ? entry["entity"] : 0
        if !(entity && entity is Map)
            continue
        dc := entity.Has("decodedComponents") ? entity["decodedComponents"] : 0
        if !(dc && dc is Map) || !_HotkeysIsTargetable(dc)
            continue
        if (mode = "world")
        {
            dist := entry.Has("distance") ? entry["distance"] : -1
            if (dist < 0 || dist > radius)
                continue
        }
        else
        {
            dist := entry.Has("distance") ? entry["distance"] : -1
            if (dist < 0 || dist > 4000)
                continue
            render := dc.Has("render") ? dc["render"] : 0
            wp := (render && render is Map && render.Has("worldPosition")) ? render["worldPosition"] : 0
            if !(wp && wp is Map)
                continue
            ci := Map("nearestWorldX", wp.Has("x") ? wp["x"] : 0, "nearestWorldY", wp.Has("y") ? wp["y"] : 0,
                "nearestWorldZ", wp.Has("z") ? wp["z"] : 0, "w2sMatrix", w2sMatrix,
                "playerWorldX", pX, "playerWorldY", pY, "playerWorldZ", pZ)
            sp := _WorldToScreen(ci, gameHwnd)
            if !sp
                continue
            ddx := sp["x"] - cx, ddy := sp["y"] - cy
            if (Sqrt(ddx * ddx + ddy * ddy) > radius)
                continue
        }
        rid := dc.Has("rarityId") ? dc["rarityId"] : -1
        if rarKeys.Has(rid)
            out[rarKeys[rid]] += 1
        out["total"] += 1
    }
    return out
}

; Returns the runtime-state Map for a hotkey id, creating it on first use.
_HotkeysRuntime(id)
{
    global g_hkRuntime
    if !g_hkRuntime.Has(id)
        g_hkRuntime[id] := Map("lastAutoFire", 0, "repeatActive", 0, "repeatFn", 0)
    return g_hkRuntime[id]
}

; True if the hotkey has at least one condition-type action.
_HotkeysHasConditionAction(hk)
{
    for a in hk["actions"]
    {
        t := a.Has("type") ? a["type"] : ""
        if (t = "vitals" || t = "buff" || t = "charges" || t = "monsterCount" || t = "monsterCountCursor")
            return true
    }
    return false
}

; Derives the auto re-fire gap (ms) for a condition-triggered hotkey.
_HotkeysReFireGap(hk)
{
    gap := 250
    for a in hk["actions"]
    {
        if (a.Has("type") && a["type"] = "repeat")
        {
            iv := a.Has("intervalMs") ? (a["intervalMs"] + 0) : 0
            if (iv > 0 && iv < gap)
                gap := iv
        }
    }
    return gap
}

; Dry-run of the condition gates only (no side effects), used by the evaluator
; to decide whether a program-triggered hotkey should fire.
_HotkeysActionsWouldRun(hk)
{
    snap := _HotkeysSnap()
    for a in hk["actions"]
    {
        t := a.Has("type") ? a["type"] : ""
        switch t
        {
            case "vitals":
                if !_HotkeysCheckVitals(a, snap)
                    return false
            case "buff":
                if !_HotkeysCheckBuff(a, snap)
                    return false
            case "charges":
                if !_HotkeysCheckCharges(a, snap)
                    return false
            case "monsterCount":
                if !_HotkeysCheckMonsterCount(a, snap)
                    return false
            case "monsterCountCursor":
                if !_HotkeysCheckMonsterCountCursor(a, snap)
                    return false
        }
    }
    return true
}

; ── Firing / action execution ──────────────────────────────────────────────

; Fires a hotkey: checks enabled state and global guards, then runs its actions.
; Params: id - hotkey id; context - "user" (physical press) | "program"
;   (auto/condition). Chains propagate the originating context unchanged.
_HotkeysFire(id, context, depth := 0)
{
    if (depth > 8)
        return   ; chain recursion guard

    found := _HotkeysFindById(id)
    if !found
        return
    grp := found["group"]
    hk := found["hotkey"]
    if (!grp["enabled"] || !hk["enabled"])
        return

    ; Self-trigger guard: keys we inject via keybd_event/mouse_event are also
    ; seen by the keyboard/mouse hook (DllCall injection isn't tagged the way
    ; AHK's own Send is), so a press/repeat/hold whose output key equals the
    ; trigger key would otherwise re-fire this hotkey in a runaway loop. Echoes
    ; only matter for physically-pressed (user-context) hotkeys.
    if (context = "user" && _HotkeysIsInjectedEcho(hk["key"]))
        return

    if !_HotkeysPassesGuards(hk)
        return

    _HotkeysRunActions(hk, context, depth)
}

; Marks a key as just-injected by us, so its hook echo is ignored briefly.
_HotkeysMarkInjected(key)
{
    global g_hkInjectGuard
    tok := StrLower(Trim(key))
    if (tok != "")
        g_hkInjectGuard[tok] := A_TickCount + 60
}

; True if <key> was injected by us within the guard window (i.e. a self echo).
_HotkeysIsInjectedEcho(key)
{
    global g_hkInjectGuard
    tok := StrLower(Trim(key))
    return (tok != "" && g_hkInjectGuard.Has(tok) && A_TickCount < g_hkInjectGuard[tok])
}

; Checks the per-hotkey global conditions (focus, safe-zone). Returns true if OK.
_HotkeysPassesGuards(hk)
{
    global g_webGui
    ; Focus: only fire when the PoE2 window is foreground (the tool's own
    ; window counts as "not the game", matching AutoFlask behaviour).
    if (hk["focusOnly"])
    {
        gameHwnd := ResolvePoEWindow()
        if (!gameHwnd || !WinActive("ahk_id " gameHwnd))
            return false
    }
    ; Safe zone: skip in towns / hideouts.
    if (hk["safeZoneDisabled"])
    {
        snap := _HotkeysSnap()
        wa := (snap && snap.Has("worldAreaDat")) ? snap["worldAreaDat"] : 0
        if (wa && wa is Map)
        {
            if ((wa.Has("isTown") && wa["isTown"]) || (wa.Has("isHideout") && wa["isHideout"]))
                return false
        }
    }
    return true
}

; Runs the ordered action list. Condition actions gate the sequence (a failed
; condition aborts the remaining actions); effect actions perform their effect.
_HotkeysRunActions(hk, context, depth)
{
    snap := _HotkeysSnap()
    for a in hk["actions"]
    {
        t := a.Has("type") ? a["type"] : ""
        switch t
        {
            case "vitals":
                if !_HotkeysCheckVitals(a, snap)
                    return
            case "buff":
                if !_HotkeysCheckBuff(a, snap)
                    return
            case "charges":
                if !_HotkeysCheckCharges(a, snap)
                    return
            case "monsterCount":
                if !_HotkeysCheckMonsterCount(a, snap)
                    return
            case "monsterCountCursor":
                if !_HotkeysCheckMonsterCountCursor(a, snap)
                    return
            case "press":
                _HotkeysSendKey(_HotkeysResolveKey(hk))
            case "repeat":
                _HotkeysDoRepeat(hk, a)
            case "hold":
                _HotkeysDoHold(hk, a)
            case "chain":
                _HotkeysDoChain(a, context, depth)
            case "aim":
                _HotkeysDoAim(hk, a, snap)
        }
    }
}

; ── Condition evaluators ───────────────────────────────────────────────────

; Vitals gate: compares HP/ES/Mana percent against the action threshold.
; action: Map("resource","hp"|"es"|"mana", "op","<"|"<="|">"|">=", "value", pct)
_HotkeysCheckVitals(a, snap)
{
    if !snap
        return false
    pv := snap.Has("playerVitals") ? snap["playerVitals"] : 0
    if !(pv && pv is Map && pv.Has("stats"))
        return false
    st := pv["stats"]
    res := a.Has("resource") ? a["resource"] : "hp"
    switch res
    {
        case "es":   cur := st["esCurrent"],   max := st["esMax"]
        case "mana": cur := st["manaCurrent"], max := st["manaMax"]
        default:     cur := st["lifeCurrent"], max := st["lifeMax"]
    }
    if (max <= 0)
        return false
    pct := (cur * 100.0) / max
    return _HotkeysCompare(pct, a.Has("op") ? a["op"] : "<=", a.Has("value") ? (a["value"] + 0) : 0)
}

; Buff gate: checks presence/absence and optional min stacks / min time-left.
; action: Map("buffName", "...", "mode","present"|"absent",
;             "minStacks", n, "minTimeLeftMs", ms)
_HotkeysCheckBuff(a, snap)
{
    name := a.Has("buffName") ? a["buffName"] : ""
    mode := a.Has("mode") ? a["mode"] : "present"
    if (name = "")
        return true
    eff := _HotkeysFindBuff(snap, name)
    if (mode = "absent")
        return !eff
    if !eff
        return false
    if (a.Has("minStacks") && a["minStacks"] + 0 > 0)
    {
        ch := eff.Has("charges") ? (eff["charges"] + 0) : 0
        if (ch < a["minStacks"] + 0)
            return false
    }
    if (a.Has("minTimeLeftMs") && a["minTimeLeftMs"] + 0 > 0)
    {
        tl := eff.Has("timeLeft") ? (eff["timeLeft"] + 0) : 0
        if (tl < a["minTimeLeftMs"] + 0)
            return false
    }
    return true
}

; Charges gate: charge buffs (power/frenzy/endurance) and charged_staff_stack
; are exposed as named buffs with a "charges" count. Compares against value.
; action: Map("chargeType","power"|"frenzy"|"endurance"|"charged_staff",
;             "op",">=", "value", n)
_HotkeysCheckCharges(a, snap)
{
    type := a.Has("chargeType") ? a["chargeType"] : "power"
    nameMap := Map(
        "power", "power_charge",
        "frenzy", "frenzy_charge",
        "endurance", "endurance_charge",
        "charged_staff", "charged_staff_stack"
    )
    buffName := nameMap.Has(type) ? nameMap[type] : type
    eff := _HotkeysFindBuff(snap, buffName)
    count := (eff && eff.Has("charges")) ? (eff["charges"] + 0) : 0
    return _HotkeysCompare(count, a.Has("op") ? a["op"] : ">=", a.Has("value") ? (a["value"] + 0) : 0)
}

; Looks up a player buff effect by (case-insensitive substring) name from an
; on-demand buff read. Returns the effect Map or 0.
_HotkeysFindBuff(snap, name)
{
    global g_reader
    if !snap
        return 0
    inGs := snap.Has("inGameState") ? snap["inGameState"] : 0
    area := (inGs && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    lpPtr := (area && area.Has("localPlayerPtr")) ? area["localPlayerPtr"] : 0
    if !lpPtr
        return 0
    buffs := 0
    try buffs := g_reader.ReadPlayerBuffsComponent(lpPtr)
    if !(buffs && buffs is Map && buffs.Has("effects"))
        return 0
    needle := StrLower(name)
    for eff in buffs["effects"]
    {
        if !(eff is Map)
            continue
        bn := eff.Has("name") ? StrLower(eff["name"]) : ""
        if (bn != "" && InStr(bn, needle))
            return eff
    }
    return 0
}

; Monster-count gate: counts hostile (targetable) entities within radius,
; optionally filtered by rarity, and compares to the threshold.
; action: Map("radius", r, "rarity","any"|"normal"|"magic"|"rare"|"unique",
;             "op",">=", "value", n)
_HotkeysCheckMonsterCount(a, snap)
{
    if !snap
        return false
    radius := a.Has("radius") ? (a["radius"] + 0) : 1500
    rarity := a.Has("rarity") ? a["rarity"] : "any"
    rarMap := Map("normal", 0, "magic", 1, "rare", 2, "unique", 3)
    wantRar := rarMap.Has(rarity) ? rarMap[rarity] : -1

    count := 0
    for entry in _HotkeysAwakeSample(snap)
    {
        entity := entry.Has("entity") ? entry["entity"] : 0
        if !(entity && entity is Map)
            continue
        dist := entry.Has("distance") ? entry["distance"] : -1
        if (dist < 0 || dist > radius)
            continue
        dc := entity.Has("decodedComponents") ? entity["decodedComponents"] : 0
        if !(dc && dc is Map)
            continue
        if !_HotkeysIsTargetable(dc)
            continue
        if (wantRar >= 0)
        {
            rid := dc.Has("rarityId") ? dc["rarityId"] : -1
            if (rid != wantRar)
                continue
        }
        count += 1
    }
    return _HotkeysCompare(count, a.Has("op") ? a["op"] : ">=", a.Has("value") ? (a["value"] + 0) : 1)
}

; Monster-count-at-cursor gate: like _HotkeysCheckMonsterCount but measures the
; screen-pixel distance from the mouse cursor instead of world distance from the
; player. Each hostile entity is projected to screen via _WorldToScreen and
; counted if within <radius> pixels of the cursor.
; action: Map("radius", px, "rarity","any"|..., "op",">=", "value", n,
;             "worldRadius", maxWorldDist)  -- worldRadius pre-filters far
;             entities before projection (default 4000) for performance.
_HotkeysCheckMonsterCountCursor(a, snap)
{
    if !snap
        return false
    gameHwnd := ResolvePoEWindow()
    if !gameHwnd
        return false

    pxRadius := a.Has("radius") ? (a["radius"] + 0) : 120
    worldRadius := a.Has("worldRadius") ? (a["worldRadius"] + 0) : 4000
    rarity := a.Has("rarity") ? a["rarity"] : "any"
    rarMap := Map("normal", 0, "magic", 1, "rare", 2, "unique", 3)
    wantRar := rarMap.Has(rarity) ? rarMap[rarity] : -1

    ; Current cursor position in screen coordinates.
    cx := 0, cy := 0
    CoordMode("Mouse", "Screen")
    MouseGetPos(&cx, &cy)

    ; Player world pos + W2S matrix for projection.
    inGs := snap.Has("inGameState") ? snap["inGameState"] : 0
    w2sMatrix := (inGs && inGs.Has("w2sMatrix")) ? inGs["w2sMatrix"] : 0
    area := (inGs && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    prc := (area && area.Has("playerRenderComponent")) ? area["playerRenderComponent"] : 0
    pwp := (prc && prc is Map && prc.Has("worldPosition")) ? prc["worldPosition"] : 0
    pX := (pwp && pwp.Has("x")) ? pwp["x"] : 0
    pY := (pwp && pwp.Has("y")) ? pwp["y"] : 0
    pZ := (pwp && pwp.Has("z")) ? pwp["z"] : 0

    count := 0
    for entry in _HotkeysAwakeSample(snap)
    {
        entity := entry.Has("entity") ? entry["entity"] : 0
        if !(entity && entity is Map)
            continue
        ; Cheap world-distance pre-filter to avoid projecting the whole map.
        dist := entry.Has("distance") ? entry["distance"] : -1
        if (dist < 0 || dist > worldRadius)
            continue
        dc := entity.Has("decodedComponents") ? entity["decodedComponents"] : 0
        if !(dc && dc is Map)
            continue
        if !_HotkeysIsTargetable(dc)
            continue
        if (wantRar >= 0)
        {
            rid := dc.Has("rarityId") ? dc["rarityId"] : -1
            if (rid != wantRar)
                continue
        }
        render := dc.Has("render") ? dc["render"] : 0
        wp := (render && render is Map && render.Has("worldPosition")) ? render["worldPosition"] : 0
        if !(wp && wp is Map)
            continue
        combatInfo := Map(
            "nearestWorldX", wp.Has("x") ? wp["x"] : 0,
            "nearestWorldY", wp.Has("y") ? wp["y"] : 0,
            "nearestWorldZ", wp.Has("z") ? wp["z"] : 0,
            "w2sMatrix", w2sMatrix,
            "playerWorldX", pX, "playerWorldY", pY, "playerWorldZ", pZ
        )
        sp := _WorldToScreen(combatInfo, gameHwnd)
        if !sp
            continue
        ddx := sp["x"] - cx
        ddy := sp["y"] - cy
        if (Sqrt(ddx * ddx + ddy * ddy) <= pxRadius)
            count += 1
    }
    return _HotkeysCompare(count, a.Has("op") ? a["op"] : ">=", a.Has("value") ? (a["value"] + 0) : 1)
}

; Returns the awake-entity sample array from a snapshot, or an empty array.
_HotkeysAwakeSample(snap)
{
    inGs := snap.Has("inGameState") ? snap["inGameState"] : 0
    area := (inGs && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    awake := (area && area.Has("awakeEntities")) ? area["awakeEntities"] : 0
    if (awake && awake is Map && awake.Has("sample") && awake["sample"] is Array)
        return awake["sample"]
    return []
}

; Reads the targetable flag from a decoded-components Map (bool or Map shape).
_HotkeysIsTargetable(dc)
{
    if !dc.Has("targetable")
        return false
    tgt := dc["targetable"]
    if (tgt is Map)
        return tgt.Has("isTargetable") ? tgt["isTargetable"] : false
    return tgt ? true : false
}

; Generic numeric comparison for condition gates.
_HotkeysCompare(lhs, op, rhs)
{
    switch op
    {
        case "<":  return lhs <  rhs
        case "<=": return lhs <= rhs
        case ">":  return lhs >  rhs
        case ">=": return lhs >= rhs
        case "=":  return lhs =  rhs
        case "!=": return lhs != rhs
    }
    return false
}

; ── Effect actions ─────────────────────────────────────────────────────────

; Sends the hotkey's output key once (UIPI-safe, via _SendSkillKey).
_HotkeysSendKey(key)
{
    if (Trim(key) = "")
        return
    gameHwnd := ResolvePoEWindow()
    if !gameHwnd
        return
    ; X1/X2 mouse buttons aren't handled by _SendSkillKey — route via the
    ; local down/up helpers (which support them) as a quick click.
    kl := StrLower(Trim(key))
    if (kl = "xbutton1" || kl = "xbutton2")
    {
        if _HotkeysKeyDown(key)
            SetTimer(() => _HotkeysKeyUp(key), -20)
        return
    }
    _HotkeysMarkInjected(key)
    try _SendSkillKey(key, gameHwnd)
}

; Repeat action: presses the output key repeatedly.
; action: Map("infinite",0|1, "count", n, "intervalMs", ms)
; Infinite repeat toggles a per-hotkey timer on/off on each fire.
_HotkeysDoRepeat(hk, a)
{
    id := hk["id"]
    interval := a.Has("intervalMs") ? Max(15, a["intervalMs"] + 0) : 100
    rt := _HotkeysRuntime(id)

    if (a.Has("infinite") && a["infinite"])
    {
        if (rt["repeatActive"])
        {
            ; Toggle off.
            try SetTimer(rt["repeatFn"], 0)
            rt["repeatActive"] := 0
            rt["repeatFn"] := 0
            return
        }
        ; Re-resolve the key and re-check skill readiness on every tick so a
        ; cooldown-bound skill isn't spammed during its cooldown (the eval-tick
        ; minGap only throttles _HotkeysFire, not this timer).
        fn := () => _HotkeysSendKeyIfReady(hk)
        rt["repeatFn"] := fn
        rt["repeatActive"] := 1
        SetTimer(fn, interval)
        return
    }

    ; Finite count: schedule N sends without blocking the message loop.
    count := a.Has("count") ? Max(1, a["count"] + 0) : 1
    _HotkeysScheduleBurst(hk, count, interval)
}

; Sends the hotkey's resolved output key, but only if its output readiness gate
; passes (skill off cooldown). Used by repeat timers so each tick is gated.
_HotkeysSendKeyIfReady(hk)
{
    rdy := _HotkeysOutputReadiness(hk)
    if !rdy["ready"]
        return
    _HotkeysSendKey(_HotkeysResolveKey(hk))
}

; Schedules <count> key presses spaced <interval> ms apart via a self-cancelling
; timer. Each tick re-checks readiness (and counts only when a key was sent), so
; a cooldown-bound skill burst won't fire faster than the skill allows.
_HotkeysScheduleBurst(hk, count, interval)
{
    ; ticksLeft caps total attempts so a never-ready skill can't keep the timer
    ; alive forever: allow up to 4x the requested sends before giving up.
    state := Map("left", count, "ticksLeft", count * 4 + 8, "fn", 0)
    tick()
    {
        rdy := _HotkeysOutputReadiness(hk)
        if rdy["ready"]
        {
            _HotkeysSendKey(_HotkeysResolveKey(hk))
            state["left"] -= 1
        }
        state["ticksLeft"] -= 1
        if (state["left"] <= 0 || state["ticksLeft"] <= 0)
            SetTimer(state["fn"], 0)
    }
    state["fn"] := tick
    SetTimer(tick, interval)
}

; Hold action: presses the output key down and releases it after duration ms.
; action: Map("durationMs", ms)
_HotkeysDoHold(hk, a)
{
    key := Trim(_HotkeysResolveKey(hk))
    if (key = "")
        return
    dur := a.Has("durationMs") ? Max(10, a["durationMs"] + 0) : 200
    if !_HotkeysKeyDown(key)
        return
    SetTimer(() => _HotkeysKeyUp(key), -dur)
}

; Chain action: triggers another hotkey by id, honouring the trigger-mode filter.
; action: Map("targetId", n, "triggerMode","program"|"user"|"always", "delayMs", ms)
_HotkeysDoChain(a, context, depth)
{
    targetId := a.Has("targetId") ? (a["targetId"] + 0) : 0
    if (targetId <= 0)
        return
    mode := a.Has("triggerMode") ? a["triggerMode"] : "always"
    if (mode = "program" && context != "program")
        return
    if (mode = "user" && context != "user")
        return
    delay := a.Has("delayMs") ? Max(0, a["delayMs"] + 0) : 0
    ; Propagate the originating context (user/program) so multi-step chains
    ; keep honouring per-link trigger-mode filters down the whole chain.
    SetTimer(() => _HotkeysFire(targetId, context, depth + 1), -Max(1, delay))
}

; Auto-aim action: finds a target by filter, moves the cursor to it, and
; optionally presses the output key (held for holdMs).
; action: Map("targetType","monster"|"chest"|"npc"|"custom",
;             "rarity", "...", "chestType", "...", "name", "...",
;             "metadataPath", "...", "radius", r, "holdMs", ms,
;             "press", 0|1, "scanAll", 0|1)
_HotkeysDoAim(hk, a, snap)
{
    if !snap
        return
    gameHwnd := ResolvePoEWindow()
    if !gameHwnd
        return

    target := _HotkeysSelectAimTarget(a, snap)
    if !target
        return

    inGs := snap.Has("inGameState") ? snap["inGameState"] : 0
    w2sMatrix := (inGs && inGs.Has("w2sMatrix")) ? inGs["w2sMatrix"] : 0
    area := (inGs && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    prc := (area && area.Has("playerRenderComponent")) ? area["playerRenderComponent"] : 0
    pwp := (prc && prc is Map && prc.Has("worldPosition")) ? prc["worldPosition"] : 0

    combatInfo := Map(
        "nearestWorldX", target["x"],
        "nearestWorldY", target["y"],
        "nearestWorldZ", target["z"],
        "w2sMatrix", w2sMatrix,
        "playerWorldX", (pwp && pwp.Has("x")) ? pwp["x"] : 0,
        "playerWorldY", (pwp && pwp.Has("y")) ? pwp["y"] : 0,
        "playerWorldZ", (pwp && pwp.Has("z")) ? pwp["z"] : 0
    )

    screenPos := _WorldToScreen(combatInfo, gameHwnd)
    if !screenPos
        return
    _MoveMouseToTarget(screenPos)

    if (a.Has("press") && a["press"])
    {
        holdMs := a.Has("holdMs") ? (a["holdMs"] + 0) : 0
        outKey := _HotkeysResolveKey(hk)
        if (holdMs > 0)
        {
            key := Trim(outKey)
            if (key != "" && _HotkeysKeyDown(key))
                SetTimer(() => _HotkeysKeyUp(key), -holdMs)
        }
        else
            _HotkeysSendKey(outKey)
    }
}

; Selects the nearest entity matching the aim filter within radius.
; Returns Map("x","y","z") of the target world position, or 0.
_HotkeysSelectAimTarget(a, snap)
{
    radius := a.Has("radius") ? (a["radius"] + 0) : 1500
    scanAll := a.Has("scanAll") && a["scanAll"]
    targetType := a.Has("targetType") ? a["targetType"] : "monster"

    bestDist := radius + 1
    best := 0
    for entry in _HotkeysAwakeSample(snap)
    {
        entity := entry.Has("entity") ? entry["entity"] : 0
        if !(entity && entity is Map)
            continue
        dist := entry.Has("distance") ? entry["distance"] : -1
        if (dist < 0 || dist > radius)
            continue
        if (!scanAll && !_HotkeysAimMatches(entity, a, targetType))
            continue
        dc := entity.Has("decodedComponents") ? entity["decodedComponents"] : 0
        render := (dc && dc is Map && dc.Has("render")) ? dc["render"] : 0
        wp := (render && render is Map && render.Has("worldPosition")) ? render["worldPosition"] : 0
        if !(wp && wp is Map)
            continue
        if (dist < bestDist)
        {
            bestDist := dist
            best := Map(
                "x", wp.Has("x") ? wp["x"] : 0,
                "y", wp.Has("y") ? wp["y"] : 0,
                "z", wp.Has("z") ? wp["z"] : 0
            )
        }
    }
    return best
}

; Tests whether an entity matches the aim filter for the given target type.
_HotkeysAimMatches(entity, a, targetType)
{
    path := entity.Has("path") ? entity["path"] : ""
    pathLower := StrLower(path)
    dc := entity.Has("decodedComponents") ? entity["decodedComponents"] : 0

    switch targetType
    {
        case "monster":
            if !InStr(pathLower, "metadata/monsters/")
                return false
            if (dc && dc is Map && !_HotkeysIsTargetable(dc))
                return false
            rarity := a.Has("rarity") ? a["rarity"] : "any"
            if (rarity != "any" && dc && dc is Map)
            {
                rarMap := Map("normal", 0, "magic", 1, "rare", 2, "unique", 3)
                if (rarMap.Has(rarity))
                {
                    rid := dc.Has("rarityId") ? dc["rarityId"] : -1
                    if (rid != rarMap[rarity])
                        return false
                }
            }
            return true
        case "chest":
            if !InStr(pathLower, "chest")
                return false
            chestType := a.Has("chestType") ? StrLower(a["chestType"]) : ""
            if (chestType != "" && !InStr(pathLower, chestType))
                return false
            return true
        case "npc":
            if !(InStr(pathLower, "metadata/npc/") || InStr(pathLower, "metadata/characters/"))
                return false
            wantName := a.Has("name") ? StrLower(a["name"]) : ""
            if (wantName != "" && !InStr(pathLower, wantName))
                return false
            return true
        case "custom":
            mp := a.Has("metadataPath") ? StrLower(a["metadataPath"]) : ""
            return (mp != "" && InStr(pathLower, mp))
    }
    return false
}

; ── Low-level key send (hold-capable) ──────────────────────────────────────

; Presses a key (or mouse button) down via Win32 API (UIPI-safe). Returns true on success.
_HotkeysKeyDown(key)
{
    _HotkeysMarkInjected(key)
    kl := StrLower(key)
    if (kl = "lbutton")
    {
        DllCall("mouse_event", "uint", 0x0002, "int", 0, "int", 0, "uint", 0, "uptr", 0)
        return true
    }
    if (kl = "rbutton")
    {
        DllCall("mouse_event", "uint", 0x0008, "int", 0, "int", 0, "uint", 0, "uptr", 0)
        return true
    }
    if (kl = "mbutton")
    {
        DllCall("mouse_event", "uint", 0x0020, "int", 0, "int", 0, "uint", 0, "uptr", 0)
        return true
    }
    if (kl = "xbutton1")
    {
        DllCall("mouse_event", "uint", 0x0080, "int", 0, "int", 0, "uint", 1, "uptr", 0)   ; XDOWN, XBUTTON1
        return true
    }
    if (kl = "xbutton2")
    {
        DllCall("mouse_event", "uint", 0x0080, "int", 0, "int", 0, "uint", 2, "uptr", 0)   ; XDOWN, XBUTTON2
        return true
    }
    vk := GetKeyVK(key)
    if (!vk)
        return false
    DllCall("keybd_event", "uchar", vk, "uchar", 0, "uint", 0, "uptr", 0)
    return true
}

; Releases a key (or mouse button) previously pressed with _HotkeysKeyDown.
_HotkeysKeyUp(key)
{
    kl := StrLower(key)
    if (kl = "lbutton")
    {
        DllCall("mouse_event", "uint", 0x0004, "int", 0, "int", 0, "uint", 0, "uptr", 0)
        return true
    }
    if (kl = "rbutton")
    {
        DllCall("mouse_event", "uint", 0x0010, "int", 0, "int", 0, "uint", 0, "uptr", 0)
        return true
    }
    if (kl = "mbutton")
    {
        DllCall("mouse_event", "uint", 0x0040, "int", 0, "int", 0, "uint", 0, "uptr", 0)
        return true
    }
    if (kl = "xbutton1")
    {
        DllCall("mouse_event", "uint", 0x0100, "int", 0, "int", 0, "uint", 1, "uptr", 0)   ; XUP, XBUTTON1
        return true
    }
    if (kl = "xbutton2")
    {
        DllCall("mouse_event", "uint", 0x0100, "int", 0, "int", 0, "uint", 2, "uptr", 0)   ; XUP, XBUTTON2
        return true
    }
    vk := GetKeyVK(key)
    if (!vk)
        return false
    DllCall("keybd_event", "uchar", vk, "uchar", 0, "uint", 0x0002, "uptr", 0)
    return true
}
