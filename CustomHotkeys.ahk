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
    return Map(
        "id", id,
        "name", hk.Has("name") ? hk["name"] : ("Hotkey #" id),
        "enabled", _HkBool(hk, "enabled", 1),
        "focusOnly", _HkBool(hk, "focusOnly", 1),
        "safeZoneDisabled", _HkBool(hk, "safeZoneDisabled", 0),
        "key", hk.Has("key") ? hk["key"] : "",
        "mods", mods,
        "actions", actions
    )
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
    ; "~" keeps the native key working (passes through to the game). "$" forces
    ; the keyboard hook and is only valid for keyboard keys, not mouse buttons.
    kl := StrLower(key)
    isMouse := (kl = "lbutton" || kl = "rbutton" || kl = "mbutton" || kl = "xbutton1" || kl = "xbutton2" || kl = "wheelup" || kl = "wheeldown")
    hook := isMouse ? "~" : "~$"
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
    global g_hotkeyGroups, g_hkRuntime
    for grp in g_hotkeyGroups
    {
        if !grp["enabled"]
            continue
        for hk in grp["hotkeys"]
        {
            if !hk["enabled"]
                continue
            if !_HotkeysHasConditionAction(hk)
                continue   ; manual / chain-only hotkey

            id := hk["id"]
            rt := _HotkeysRuntime(id)
            ; Re-fire throttle: default 250ms, or the smallest repeat interval.
            minGap := _HotkeysReFireGap(hk)
            if ((A_TickCount - rt["lastAutoFire"]) < minGap)
                continue

            if _HotkeysActionsWouldRun(hk)
            {
                rt["lastAutoFire"] := A_TickCount
                _HotkeysFire(id, "program")
            }
        }
    }
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
        if (t = "vitals" || t = "buff" || t = "charges" || t = "monsterCount")
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
        }
    }
    return true
}

; ── Firing / action execution ──────────────────────────────────────────────

; Fires a hotkey: checks enabled state and global guards, then runs its actions.
; Params: id - hotkey id; context - "user" | "program" | "chain".
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

    if !_HotkeysPassesGuards(hk)
        return

    _HotkeysRunActions(hk, context, depth)
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
            case "press":
                _HotkeysSendKey(hk["key"])
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
    try _SendSkillKey(key, gameHwnd)
}

; Repeat action: presses the output key repeatedly.
; action: Map("infinite",0|1, "count", n, "intervalMs", ms)
; Infinite repeat toggles a per-hotkey timer on/off on each fire.
_HotkeysDoRepeat(hk, a)
{
    id := hk["id"]
    key := hk["key"]
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
        fn := () => _HotkeysSendKey(key)
        rt["repeatFn"] := fn
        rt["repeatActive"] := 1
        SetTimer(fn, interval)
        return
    }

    ; Finite count: schedule N sends without blocking the message loop.
    count := a.Has("count") ? Max(1, a["count"] + 0) : 1
    _HotkeysScheduleBurst(key, count, interval)
}

; Schedules <count> key presses spaced <interval> ms apart via a self-cancelling timer.
_HotkeysScheduleBurst(key, count, interval)
{
    state := Map("left", count, "fn", 0)
    tick()
    {
        _HotkeysSendKey(key)
        state["left"] -= 1
        if (state["left"] <= 0)
            SetTimer(state["fn"], 0)
    }
    state["fn"] := tick
    SetTimer(tick, interval)
}

; Hold action: presses the output key down and releases it after duration ms.
; action: Map("durationMs", ms)
_HotkeysDoHold(hk, a)
{
    key := Trim(hk["key"])
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
    SetTimer(() => _HotkeysFire(targetId, "chain", depth + 1), -Max(1, delay))
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
        if (holdMs > 0)
        {
            key := Trim(hk["key"])
            if (key != "" && _HotkeysKeyDown(key))
                SetTimer(() => _HotkeysKeyUp(key), -holdMs)
        }
        else
            _HotkeysSendKey(hk["key"])
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
    vk := GetKeyVK(key)
    if (!vk)
        return false
    DllCall("keybd_event", "uchar", vk, "uchar", 0, "uint", 0x0002, "uptr", 0)
    return true
}
