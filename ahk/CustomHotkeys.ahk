; CustomHotkeys.ahk
; Custom hotkey / macro engine. Provides user-defined hotkey groups, each
; containing hotkeys with a boolean condition tree (the firing gate) and an
; ordered list of effect actions (key press/hold/loop, chain, auto-aim).
;
; The condition tree combines the per-type gates (vitals/buff/charge/
; monster-count) with AND/OR and nesting (= brackets):
;   conditions := Map("kind","group", "mode","all"|"any", "children", [ <node>... ])
;   node       := a group (above) OR a leaf condition Map("type","vitals", ...)
;   mode "all" = AND (every child passes), "any" = OR (one child passes).
; Legacy configs carried conditions inline in "actions"; _HotkeysNormalizeHotkey
; migrates those into a root "all" group on load.
;
; Data model (also the on-disk shape in hotkeys.json):
;   g_hotkeyGroups := [
;     Map("name", "...", "enabled", 1, "hotkeys", [
;       Map("id", 1, "name", "...", "enabled", 1,
;           "focusOnly", 1, "safeZoneDisabled", 1,
;           "key", "1", "mods", Map("ctrl",0,"shift",0,"alt",0,"gamepadLT",0),
;           "conditions", Map("kind","group","mode","all","children",[ ... ]),
;           "actions", [ Map("type","key", ...), ... ])
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
    global g_hkFlaskCache := 0            ; cached flask-slot Map for output readiness (charge gate)
    global g_hkFlaskCacheTick := 0        ; A_TickCount of the last on-demand flask-slot read
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
    ; Split the raw action list into EFFECTS (kept in "actions") and CONDITION
    ; gates. Conditions live in a boolean tree under "conditions" (groups with
    ; mode "all"=AND / "any"=OR, nestable for brackets). Legacy configs carried
    ; conditions inline in the action list, so migrate those into a root AND
    ; group; a new-shape config supplies "conditions" directly.
    actions := []
    condLegacy := []
    actRaw := (hk.Has("actions") && hk["actions"] is Array) ? hk["actions"] : []
    for a in actRaw
    {
        if !(a is Map)
            continue
        if _HotkeysIsCondType(a.Has("type") ? a["type"] : "")
            condLegacy.Push(a)
        else
            actions.Push(a)
    }
    if (hk.Has("conditions") && hk["conditions"] is Map)
    {
        conditions := _HotkeysNormalizeCondTree(hk["conditions"])
        ; Fold any stray inline condition actions (e.g. an imported legacy
        ; action) into the root group so none are silently lost.
        for c in condLegacy
            conditions["children"].Push(c)
    }
    else
        conditions := Map("kind", "group", "mode", "all", "children", condLegacy)
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
    ; Default for legacy configs: automated if it has any condition.
    hasCond := (_HotkeysCountLeaves(conditions) > 0)
    trigger := hk.Has("trigger") ? hk["trigger"] : (hasCond ? "automated" : "manual")
    if (trigger != "automated" && trigger != "manual")
        trigger := "manual"
    ; Custom cooldown (ms): minimum time between firings. 0 = off (a skill output
    ; still uses its own detected cooldown; raw keys / undetected skills use only
    ; the default throttle). Lets the user gate outputs whose real cooldown the
    ; reader can't see (e.g. Orb of Storms on a raw key).
    cooldownMs := hk.Has("cooldownMs") ? (hk["cooldownMs"] + 0) : 0
    if (cooldownMs < 0)
        cooldownMs := 0
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
        "cooldownMs", cooldownMs,
        "actions", actions,
        "conditions", conditions
    )
}

; Sanitizes a condition tree node parsed from JSON: enforces the group shape
; (kind/mode/children), keeps only valid condition leaves, recurses into nested
; sub-groups (= brackets). A non-group leaf passed at the root is wrapped in an
; AND group. Returns a normalized root group Map.
_HotkeysNormalizeCondTree(node)
{
    if !(node is Map)
        return Map("kind", "group", "mode", "all", "children", [])
    if (node.Has("kind") && node["kind"] = "group")
    {
        mode := (node.Has("mode") && node["mode"] = "any") ? "any" : "all"
        out := []
        chRaw := (node.Has("children") && node["children"] is Array) ? node["children"] : []
        for ch in chRaw
        {
            if !(ch is Map)
                continue
            if (ch.Has("kind") && ch["kind"] = "group")
                out.Push(_HotkeysNormalizeCondTree(ch))
            else if (ch.Has("type") && _HotkeysIsCondType(ch["type"]))
                out.Push(ch)
        }
        return Map("kind", "group", "mode", mode, "children", out)
    }
    if (node.Has("type") && _HotkeysIsCondType(node["type"]))
        return Map("kind", "group", "mode", "all", "children", [node])
    return Map("kind", "group", "mode", "all", "children", [])
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
        return (out.Has("key") && out["key"] != "") ? out["key"]
             : (g_skillKeyBySlot.Has(slot) ? g_skillKeyBySlot[slot] : "")
    return out.Has("key") ? out["key"] : (hk.Has("key") ? hk["key"] : "")
}

; Readiness gate for the output binding: true if the bound flask has charges /
; the bound skill is off cooldown. Free "key" bindings are always ready.
; Returns Map("ready", bool, "cooldownMs", int).
_HotkeysOutputReadiness(hk)
{
    out := (hk.Has("output") && hk["output"] is Map) ? hk["output"] : 0
    if !out
        return Map("ready", true, "cooldownMs", 0, "kind", "key")
    kind := out.Has("kind") ? out["kind"] : "key"
    if (kind = "skill")
    {
        nm := out.Has("skillName") ? out["skillName"] : ""
        if (nm = "")
            return Map("ready", true, "cooldownMs", 0, "kind", "skill")
        r := HotkeysSkillReadiness(nm)
        return Map("ready", r["found"] ? r["canUse"] : true, "cooldownMs", r["cooldownMs"], "kind", "skill")
    }
    if (kind = "flask")
    {
        ; Charge gate — mirrors AutoFlask's TryUseFlaskSlot: a flask may only fire
        ; when it holds at least one full use (current >= perUse) and its own buff
        ; isn't already active. Flask charges aren't in the radar snapshot, so the
        ; slot data is read on demand and cached (see _HotkeysFlaskSlots).
        slot   := out.Has("slot") ? (out["slot"] + 0) : 0
        slots  := _HotkeysFlaskSlots()
        if !(slots && slots is Map && slots.Has(slot))
            return Map("ready", true, "cooldownMs", 0, "kind", "flask")   ; lenient when unreadable
        s      := slots[slot]
        fs     := (s && s is Map && s.Has("flaskStats")) ? s["flaskStats"] : 0
        cur    := (fs && fs is Map && fs.Has("current")) ? (fs["current"] + 0) : 0
        perUse := (fs && fs is Map && fs.Has("perUse"))  ? (fs["perUse"]  + 0) : 0
        active := (s && s is Map && s.Has("activeByBuff") && s["activeByBuff"]) ? true : false
        ready  := (perUse > 0 && cur >= perUse && !active)
        return Map("ready", ready, "cooldownMs", 0, "kind", "flask"
                 , "charges", cur, "perUse", perUse, "active", active)
    }
    ; Free "key" binding — no readiness constraint.
    return Map("ready", true, "cooldownMs", 0, "kind", "key")
}

; Returns the flask-slot Map (slot 1-5 -> flask data with flaskStats / activeByBuff),
; read on demand from the area instance in the cached radar snapshot and itself cached
; for 150ms (charges change slowly, and readiness is polled every eval tick). Returns 0
; when unavailable. Independent of AutoFlask, so a flask hotkey works on its own.
_HotkeysFlaskSlots()
{
    global g_reader, g_hkFlaskCache, g_hkFlaskCacheTick
    if ((A_TickCount - g_hkFlaskCacheTick) < 150)
        return g_hkFlaskCache
    g_hkFlaskCacheTick := A_TickCount
    g_hkFlaskCache := 0
    snap := _HotkeysSnap()
    if !snap
        return 0
    inGs := snap.Has("inGameState") ? snap["inGameState"] : 0
    area := (inGs && inGs is Map && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    addr := (area && area is Map && area.Has("address")) ? area["address"] : 0
    if !addr
        return 0
    ai := 0
    try ai := g_reader.ReadAreaInstanceAutoFlask(addr)
    if !(ai && ai is Map && ai.Has("serverData"))
        return 0
    srv      := ai["serverData"]
    flaskInv := (srv && srv is Map && srv.Has("flaskInventory")) ? srv["flaskInventory"] : 0
    slots    := (flaskInv && flaskInv is Map && flaskInv.Has("flaskSlots")) ? flaskInv["flaskSlots"] : 0
    g_hkFlaskCache := slots
    return slots
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

; One-time seed of the default "Flasks" hotkey group that replaces the old
; standalone AutoFlask feature:
;   Life Flask -> flask slot 1, automated, fires at <= 55% life
;   Mana Flask -> flask slot 2, automated, fires at <= 35% mana
; Both are foreground-only and suppressed in town/hideout; the flask output
; readiness charge-gates them, so an empty flask never fires. A persistent flag
; ([Hotkeys] flaskPresetsSeeded in poeformance_config.ini) guarantees this runs
; at most once per install — deleting the presets later never re-creates them,
; and existing user hotkeys are appended to, never overwritten. Called once at
; startup after HotkeysLoadConfig().
HotkeysSeedFlaskPresets()
{
    global g_hotkeyGroups
    cfgPath := A_ScriptDir "\poeformance_config.ini"
    if (IniRead(cfgPath, "Hotkeys", "flaskPresetsSeeded", "0") = "1")
        return

    raw := [ Map(
        "name", "Flasks",
        "enabled", 1,
        "hotkeys", [
            Map(
                "name", "Life Flask",
                "enabled", 1,
                "trigger", "automated",
                "focusOnly", 1,
                "safeZoneDisabled", 1,
                "output", Map("kind", "flask", "slot", 1),
                "actions", [ Map("type", "vitals", "resource", "hp", "op", "<=", "value", 55) ]
            ),
            Map(
                "name", "Mana Flask",
                "enabled", 1,
                "trigger", "automated",
                "focusOnly", 1,
                "safeZoneDisabled", 1,
                "output", Map("kind", "flask", "slot", 2),
                "actions", [ Map("type", "vitals", "resource", "mana", "op", "<=", "value", 35) ]
            )
        ]
    ) ]

    for g in _HotkeysNormalizeGroups(raw)
        g_hotkeyGroups.Push(g)
    HotkeysSaveConfig()
    IniWrite("1", cfgPath, "Hotkeys", "flaskPresetsSeeded")
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
            ; User-set custom cooldown raises the gap too (authoritative for
            ; outputs whose real cooldown can't be detected).
            cd := hk.Has("cooldownMs") ? (hk["cooldownMs"] + 0) : 0
            if (cd > minGap)
                minGap := cd
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
            ; Condition leaves (monsterCount/vitals/buff/charges) carry their own
            ; debug flags + range-circle colors, so walk the tree too.
            root := (hk.Has("conditions") && hk["conditions"] is Map) ? hk["conditions"] : 0
            if root
                _HotkeysCollectCondDebug(root, hk, snap, items)
        }
    }
    g_hkDebugItems := items
}

; Recursively pushes a debug record for every condition leaf (with its debug
; flag set) under a tree node into the items array.
_HotkeysCollectCondDebug(node, hk, snap, items)
{
    if !(node is Map)
        return
    if (node.Has("kind") && node["kind"] = "group")
    {
        children := (node.Has("children") && node["children"] is Array) ? node["children"] : []
        for ch in children
            _HotkeysCollectCondDebug(ch, hk, snap, items)
        return
    }
    if (node.Has("debug") && node["debug"])
        items.Push(_HotkeysBuildDebugRecord(hk, node, 0, snap))
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

    ; Per-action range-circle color from the UI color picker (#RRGGBB → BGR).
    ; 0 = none set → the radar falls back to its default circle color.
    rec["color"] := (a.Has("circleColor") && a["circleColor"] != "")
        ? GroupColorToBgr(a["circleColor"]) : 0

    ; The output key this hotkey fires — always shown in the debug readout.
    key := _HotkeysResolveKey(hk)
    rec["key"] := key
    rec["lines"].Push("key: " (key != "" ? key : "(unbound)"))

    ; When this hotkey last actually fired its key (any path), and which key.
    rt := _HotkeysRuntime(hk["id"])
    if (rt.Has("lastFireTick") && rt["lastFireTick"] > 0)
        rec["lines"].Push("last fired: " (rt.Has("lastFireKey") && rt["lastFireKey"] != "" ? rt["lastFireKey"] : "?")
            " (" Round((A_TickCount - rt["lastFireTick"]) / 1000.0, 1) "s ago)")
    else
        rec["lines"].Push("last fired: never")

    if (t = "monsterCount" || t = "monsterCountCursor")
    {
        ; Legacy "monsterCountCursor" is always cursor-origin.
        mode := (t = "monsterCountCursor") ? "cursor"
            : (a.Has("radiusMode") ? a["radiusMode"] : "player")
        if (mode = "world")
        {
            wr := a.Has("worldRadius") ? (a["worldRadius"] + 0) : 1000
            rec["circlePlayerWorld"] := wr   ; isometric world-radius ground ring around the player
            counts := _HotkeysCountByRarity(snap, wr, "world")
            rec["counts"] := counts
            rec["lines"].Push("@range(" wr ") N:" counts["normal"] " M:" counts["magic"] " R:" counts["rare"] " U:" counts["unique"] " =" counts["total"])
            _HotkeysPushCountDiag(rec, snap, wr, "world")
        }
        else if (mode = "worldCursor")
        {
            wr := a.Has("worldRadius") ? (a["worldRadius"] + 0) : 1000
            rec["circleCursorWorld"] := wr   ; isometric ring drawn around the mouse position
            ; (kept for any consumer that wants the unprojected cursor ground point — the
            ; ring itself no longer needs it, but the count below still does)
            cwp := _HotkeysCursorWorldPos(snap)
            if (cwp)
                rec["cursorWx"] := cwp["x"], rec["cursorWy"] := cwp["y"], rec["cursorWz"] := cwp["z"]
            counts := _HotkeysCountByRarity(snap, wr, "worldCursor")
            rec["counts"] := counts
            rec["lines"].Push("@cursorRange(" wr ") N:" counts["normal"] " M:" counts["magic"] " R:" counts["rare"] " U:" counts["unique"] " =" counts["total"])
            _HotkeysPushCountDiag(rec, snap, wr, "worldCursor")
        }
        else
        {
            px := a.Has("radius") ? (a["radius"] + 0) : 120
            rec[(mode = "cursor") ? "circleCursorPx" : "circlePlayerPx"] := px
            counts := _HotkeysCountByRarity(snap, px, mode)
            rec["counts"] := counts
            rec["lines"].Push("@" mode " N:" counts["normal"] " M:" counts["magic"] " R:" counts["rare"] " U:" counts["unique"] " =" counts["total"])
            _HotkeysPushCountDiag(rec, snap, px, mode)
        }
    }
    else if (t = "aim")
    {
        px := a.Has("radius") ? (a["radius"] + 0) : 150
        mode := (a.Has("radiusMode") && a["radiusMode"] = "cursor") ? "cursor" : "player"
        rec[(mode = "cursor") ? "circleCursorPx" : "circlePlayerPx"] := px
        rec["lines"].Push("aim radius " px "px @" mode)
    }
    else if (t = "charges")
    {
        type := a.Has("chargeType") ? a["chargeType"] : "power"
        nameMap := Map("power", "power_charge", "frenzy", "frenzy_charge", "endurance", "endurance_charge", "charged_staff", "charged_staff_stack")
        buffName := nameMap.Has(type) ? nameMap[type] : type
        op  := a.Has("op") ? a["op"] : ">="
        val := a.Has("value") ? a["value"] : 0
        rec["lines"].Push(type " charges " op " " val " - active buffs:")
        for _, ln in _HotkeysBuffListLines(snap, buffName)
            rec["lines"].Push(ln)
    }
    else if (t = "buff")
    {
        nm   := a.Has("buffName") ? a["buffName"] : ""
        mode := a.Has("mode") ? a["mode"] : "present"
        rec["lines"].Push("buff '" nm "' (" mode ") - active buffs:")
        for _, ln in _HotkeysBuffListLines(snap, nm)
            rec["lines"].Push(ln)
    }
    else if (t = "vitals")
    {
        ; Live resource readout matching the condition: current / max, percent,
        ; the configured threshold, and whether it passes right now.
        res := a.Has("resource") ? a["resource"] : "hp"
        op  := a.Has("op") ? a["op"] : "<="
        thr := a.Has("value") ? (a["value"] + 0) : 0
        pv  := (snap && snap.Has("playerVitals")) ? snap["playerVitals"] : 0
        st  := (pv && pv is Map && pv.Has("stats")) ? pv["stats"] : 0
        if (st)
        {
            switch res
            {
                case "es":   cur := st.Has("esCurrent")   ? st["esCurrent"]   : 0, max := st.Has("esMax")   ? st["esMax"]   : 0
                case "mana": cur := st.Has("manaCurrent") ? st["manaCurrent"] : 0, max := st.Has("manaMax") ? st["manaMax"] : 0
                default:     cur := st.Has("lifeCurrent") ? st["lifeCurrent"] : 0, max := st.Has("lifeMax") ? st["lifeMax"] : 0
            }
            pct  := (max > 0) ? (cur * 100.0 / max) : 0
            pass := (max > 0) && _HotkeysCompare(pct, op, thr)
            rec["lines"].Push(res " " Round(cur) "/" Round(max) " " Round(pct, 1) "% " op " " thr "% -> " (pass ? "PASS" : "fail"))
        }
        else
            rec["lines"].Push("vitals " res " " op " " thr "% (no data)")
    }

    ; Output readiness (applies to any debugged action). Flask outputs always show
    ; their live charge count; skills show cooldown only when not ready. Guard the
    ; flask charge keys: the lenient "unreadable" readiness omits them.
    rdy := _HotkeysOutputReadiness(hk)
    rk := rdy.Has("kind") ? rdy["kind"] : ""
    if (rk = "flask")
    {
        if (rdy.Has("charges"))
            rec["lines"].Push("flask charges " rdy["charges"] "/" rdy["perUse"]
                ((rdy.Has("active") && rdy["active"]) ? " (buff active)" : "") " -> " (rdy["ready"] ? "READY" : "NOT READY"))
        else
            rec["lines"].Push("flask charges n/a (unread) -> " (rdy["ready"] ? "READY" : "NOT READY"))
    }
    else if (rdy["cooldownMs"] > 0 || !rdy["ready"])
        rec["lines"].Push("skill " (rdy["ready"] ? "READY" : "on CD") (rdy["cooldownMs"] > 0 ? " (" rdy["cooldownMs"] "ms)" : ""))
    return rec
}

; Counts hostile entities by rarity within a radius. mode "world" uses the per-entity
; world distance to the player; "worldCursor" uses the world distance to the cursor's
; unprojected ground point (experimental); "cursor"/"player" project to screen and
; measure pixels from the cursor / the player. Returns Map("normal".."unique","total").
_HotkeysCountByRarity(snap, radius, mode)
{
    out := Map("normal", 0, "magic", 0, "rare", 0, "unique", 0, "total", 0)
    if !snap
        return out
    octx := 0
    cwp := 0
    if (mode = "worldCursor")
    {
        cwp := _HotkeysCursorWorldPos(snap)
        if !cwp
            return out          ; cursor can't be unprojected this frame → count 0
    }
    else if (mode != "world")
    {
        octx := _HotkeysPxOrigin(snap, mode)
        if !octx
            return out
    }
    rarKeys := Map(0, "normal", 1, "magic", 2, "rare", 3, "unique")
    for entry in _HotkeysAwakeSample(snap)
    {
        entity := entry.Has("entity") ? entry["entity"] : 0
        if !(entity && entity is Map)
            continue
        ; Only count actual monsters — not portals, checkpoints, NPCs, chests, decals or
        ; effects (which can also be "targetable"). Mirrors the aim "monster" classifier:
        ; the entity path must live under metadata/monsters/.
        pathLower := entity.Has("path") ? StrLower(entity["path"]) : ""
        if !InStr(pathLower, "metadata/monsters/")
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
        else if (mode = "worldCursor")
        {
            render := dc.Has("render") ? dc["render"] : 0
            wp := (render && render is Map && render.Has("worldPosition")) ? render["worldPosition"] : 0
            if !(wp && wp is Map)
                continue
            ddx := (wp.Has("x") ? wp["x"] : 0) - cwp["x"]
            ddy := (wp.Has("y") ? wp["y"] : 0) - cwp["y"]
            if (Sqrt(ddx * ddx + ddy * ddy) > radius)
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
            d := _HotkeysPxDist(octx, wp.Has("x") ? wp["x"] : 0, wp.Has("y") ? wp["y"] : 0, wp.Has("z") ? wp["z"] : 0)
            if (d < 0 || d > radius)
                continue
        }
        rid := dc.Has("rarityId") ? dc["rarityId"] : -1
        if rarKeys.Has(rid)
            out[rarKeys[rid]] += 1
        out["total"] += 1
    }
    return out
}

; Debug breakdown for a monster-count gate: walks the same sample/filters as
; _HotkeysCountByRarity but tallies how many entities pass each stage, so the
; overlay can show WHY a count is 0. Returns Map("sample","mon","tgt","pos",
; "inR","min") — min = the smallest distance seen (px for cursor/player, world
; units for world modes), or -1 if none.
_HotkeysCountDiag(snap, radius, mode)
{
    d := Map("sample", 0, "mon", 0, "tgt", 0, "pos", 0, "inR", 0, "min", -1)
    if !snap
        return d
    octx := 0, cwp := 0
    if (mode = "worldCursor")
        cwp := _HotkeysCursorWorldPos(snap)
    else if (mode != "world")
        octx := _HotkeysPxOrigin(snap, mode)
    for entry in _HotkeysAwakeSample(snap)
    {
        d["sample"] += 1
        entity := entry.Has("entity") ? entry["entity"] : 0
        if !(entity && entity is Map)
            continue
        if !InStr(entity.Has("path") ? StrLower(entity["path"]) : "", "metadata/monsters/")
            continue
        d["mon"] += 1
        dc := entity.Has("decodedComponents") ? entity["decodedComponents"] : 0
        if !(dc && dc is Map) || !_HotkeysIsTargetable(dc)
            continue
        d["tgt"] += 1
        if (mode = "world")
        {
            dist := entry.Has("distance") ? entry["distance"] : -1
            if (dist < 0)
                continue
            d["pos"] += 1
            if (d["min"] < 0 || dist < d["min"])
                d["min"] := Round(dist)
            if (dist <= radius)
                d["inR"] += 1
            continue
        }
        render := dc.Has("render") ? dc["render"] : 0
        wp := (render && render is Map && render.Has("worldPosition")) ? render["worldPosition"] : 0
        if !(wp && wp is Map)
            continue
        d["pos"] += 1
        if (mode = "worldCursor")
        {
            if !cwp
                continue
            ddx := (wp.Has("x") ? wp["x"] : 0) - cwp["x"]
            ddy := (wp.Has("y") ? wp["y"] : 0) - cwp["y"]
            dd := Sqrt(ddx * ddx + ddy * ddy)
        }
        else
        {
            if !octx
                continue
            dd := _HotkeysPxDist(octx, wp.Has("x") ? wp["x"] : 0, wp.Has("y") ? wp["y"] : 0, wp.Has("z") ? wp["z"] : 0)
        }
        if (d["min"] < 0 || dd < d["min"])
            d["min"] := Round(dd)
        if (dd <= radius)
            d["inR"] += 1
    }
    return d
}

; Formats _HotkeysCountDiag into a readable overlay line and pushes it onto a
; debug record. Reads: sample = entities scanned; mon = under metadata/monsters/;
; tgt = also targetable; pos = also have a world position to project; inR = within
; the radius; min = nearest distance seen (px for cursor/player, world units else).
_HotkeysPushCountDiag(rec, snap, radius, mode)
{
    unit := (mode = "world" || mode = "worldCursor") ? "" : "px"
    d := _HotkeysCountDiag(snap, radius, mode)
    rec["lines"].Push("diag sample=" d["sample"] " mon=" d["mon"] " tgt=" d["tgt"]
        . " pos=" d["pos"] " inR=" d["inR"] " min=" (d["min"] < 0 ? "-" : d["min"] unit)
        . " (r=" radius unit ")")
}

; Shared isometric projection origin for the radar-style ground projection used BOTH by the
; range ring (RadarOverlay._DrawWorldRing) and by monster counting, so the count always
; matches the visible ring. Returns the player world pos, the player's on-screen position
; (the projection centre, same as the ring's centre), the game window, and the world→screen
; scale (sx horizontal, sy vertical squash = sin 38.7°). 0 when player/window unavailable.
_HotkeysIsoOrigin(snap)
{
    global g_combatW2SScale
    if !(snap && snap is Map)
        return 0
    inGs := snap.Has("inGameState") ? snap["inGameState"] : 0
    mat  := (inGs && inGs.Has("w2sMatrix")) ? inGs["w2sMatrix"] : 0
    area := (inGs && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    prc  := (area && area.Has("playerRenderComponent")) ? area["playerRenderComponent"] : 0
    pwp  := (prc && prc is Map && prc.Has("worldPosition")) ? prc["worldPosition"] : 0
    if !(pwp && pwp is Map)
        return 0
    pX := pwp.Has("x") ? pwp["x"] : 0
    pY := pwp.Has("y") ? pwp["y"] : 0
    pZ := pwp.Has("z") ? pwp["z"] : 0
    gameHwnd := ResolvePoEWindow()
    if !gameHwnd
        return 0
    rect := NavClientRect(gameHwnd)
    if !rect
        return 0
    ; Player's on-screen position = the projection centre (the player projects onto the
    ; camera centre reliably; _WorldToScreen falls back to the window centre if the matrix
    ; is unavailable). This is the same centre the ring is drawn around (_PlayerScreenPos).
    ci := Map("nearestWorldX", pX, "nearestWorldY", pY, "nearestWorldZ", pZ,
        "w2sMatrix", mat, "playerWorldX", pX, "playerWorldY", pY, "playerWorldZ", pZ)
    psp := _WorldToScreen(ci, gameHwnd)
    if !psp
        return 0
    scale := (IsSet(g_combatW2SScale) && g_combatW2SScale > 0) ? g_combatW2SScale : 0.20
    sx := scale * (rect["w"] / 1920.0)
    sy := sx * 0.62470                       ; isometric vertical squash (sin 38.7°)
    if (sx <= 0 || sy <= 0)
        return 0
    return Map("hwnd", gameHwnd, "px", pX, "py", pY, "pz", pZ,
        "psx", psp["x"], "psy", psp["y"], "sx", sx, "sy", sy)
}

; Converts the current mouse cursor to a ground-plane world position at the player's Z via
; the INVERSE of the radar's isometric projection (consistent with how the cursor ring is
; drawn). The player's screen position is the projection centre; the cursor's screen offset
; from it maps back to a world (dx,dy) delta. Returns Map("x","y","z") or 0 if unavailable.
_HotkeysCursorWorldPos(snap)
{
    pori := _HotkeysIsoOrigin(snap)
    if !pori
        return 0
    cx := 0, cy := 0
    CoordMode("Mouse", "Screen")
    MouseGetPos(&cx, &cy)
    u := (cx - pori["psx"]) / pori["sx"]      ; = dx - dy
    v := -(cy - pori["psy"]) / pori["sy"]     ; = dx + dy
    return Map("x", pori["px"] + (u + v) / 2
             , "y", pori["py"] + (v - u) / 2
             , "z", pori["pz"])
}

; Returns the runtime-state Map for a hotkey id, creating it on first use.
_HotkeysRuntime(id)
{
    global g_hkRuntime
    if !g_hkRuntime.Has(id)
        g_hkRuntime[id] := Map("lastAutoFire", 0, "repeatActive", 0, "repeatFn", 0
                             , "lastFireTick", 0, "lastFireKey", "", "lastCooldownFire", 0)
    return g_hkRuntime[id]
}

; True if t names a condition (gate) type rather than an effect type.
_HotkeysIsCondType(t)
{
    return (t = "vitals" || t = "buff" || t = "charges" || t = "monsterCount" || t = "monsterCountCursor")
}

; Counts the condition leaves under a tree node (a leaf counts as 1; a group
; sums its children). Used for "has any condition" and the auto-trigger gate.
_HotkeysCountLeaves(node)
{
    if !(node is Map)
        return 0
    if !(node.Has("kind") && node["kind"] = "group")
        return 1
    n := 0
    children := (node.Has("children") && node["children"] is Array) ? node["children"] : []
    for ch in children
        n += _HotkeysCountLeaves(ch)
    return n
}

; True if the hotkey's condition tree holds at least one condition leaf.
_HotkeysHasConditionAction(hk)
{
    root := (hk.Has("conditions") && hk["conditions"] is Map) ? hk["conditions"] : 0
    return root ? (_HotkeysCountLeaves(root) > 0) : false
}

; Derives the auto re-fire gap (ms) for a condition-triggered hotkey.
_HotkeysReFireGap(hk)
{
    gap := 250
    for a in hk["actions"]
    {
        t := a.Has("type") ? a["type"] : ""
        ; "repeat" is the legacy type; "key" with mode "loop" is the merged form.
        isLoop := (t = "repeat") || (t = "key" && a.Has("mode") && a["mode"] = "loop")
        if (isLoop)
        {
            iv := a.Has("intervalMs") ? (a["intervalMs"] + 0) : 0
            if (iv > 0 && iv < gap)
                gap := iv
        }
    }
    return gap
}

; Evaluates the hotkey's boolean condition tree against the live snapshot.
; An absent/empty tree is a neutral pass (true). Used both by the eval tick to
; decide whether a program-triggered hotkey should fire and as the gate inside
; _HotkeysRunActions.
_HotkeysActionsWouldRun(hk)
{
    snap := _HotkeysSnap()
    root := (hk.Has("conditions") && hk["conditions"] is Map) ? hk["conditions"] : 0
    return root ? _HotkeysEvalNode(root, snap) : true
}

; Evaluates one condition tree node: recurses into groups, defers leaves to the
; per-type evaluators. Returns true/false.
_HotkeysEvalNode(node, snap)
{
    if !(node is Map)
        return true
    if (node.Has("kind") && node["kind"] = "group")
        return _HotkeysEvalGroup(node, snap)
    return _HotkeysEvalLeaf(node, snap)
}

; Combines a group's children by its mode: "any" = OR (one passing child wins),
; otherwise "all" = AND. An empty group is neutral (passes).
_HotkeysEvalGroup(group, snap)
{
    children := (group.Has("children") && group["children"] is Array) ? group["children"] : []
    if (children.Length = 0)
        return true
    if (group.Has("mode") && group["mode"] = "any")
    {
        for ch in children
            if _HotkeysEvalNode(ch, snap)
                return true
        return false
    }
    for ch in children
        if !_HotkeysEvalNode(ch, snap)
            return false
    return true
}

; Evaluates a single condition leaf via the matching per-type checker.
; Unknown leaf types don't block (return true).
_HotkeysEvalLeaf(a, snap)
{
    switch (a.Has("type") ? a["type"] : "")
    {
        case "vitals":             return _HotkeysCheckVitals(a, snap)
        case "buff":               return _HotkeysCheckBuff(a, snap)
        case "charges":            return _HotkeysCheckCharges(a, snap)
        case "monsterCount":       return _HotkeysCheckMonsterCount(a, snap)
        case "monsterCountCursor": return _HotkeysCheckMonsterCountCursor(a, snap)
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
; If every condition passes but the hotkey has NO effect action that sends a key,
; the output key is pressed once at the end — so the intuitive "bind output +
; one condition" setup (e.g. flask 2 + mana < 50%) fires on its own, without
; needing a redundant "Key press" action.
_HotkeysRunActions(hk, context, depth)
{
    ; Condition gate: the whole boolean condition tree must pass before any
    ; effect runs (or the bound output auto-fires). Applies to manual presses
    ; and automated firing alike.
    if !_HotkeysActionsWouldRun(hk)
        return
    ; Custom cooldown gate: once the conditions pass, never run the effects more
    ; than once per cooldownMs (user-set; 0 = off). This is the single choke
    ; point for every firing path — manual key, automated tick, and chains — so
    ; an output with no detectable cooldown (raw key / unrecognised skill) can
    ; still be rate-limited by the user.
    cd := hk.Has("cooldownMs") ? (hk["cooldownMs"] + 0) : 0
    if (cd > 0)
    {
        rt := _HotkeysRuntime(hk["id"])
        if ((A_TickCount - rt["lastCooldownFire"]) < cd)
            return
        rt["lastCooldownFire"] := A_TickCount
    }
    snap := _HotkeysSnap()
    hadEffect := false
    for a in hk["actions"]
    {
        t := a.Has("type") ? a["type"] : ""
        switch t
        {
            case "key":
                _HotkeysDoKey(hk, a)
                hadEffect := true
            case "press":
                _HotkeysFireOutput(hk)
                hadEffect := true
            case "repeat":
                _HotkeysDoRepeat(hk, a)
                hadEffect := true
            case "hold":
                _HotkeysDoHold(hk, a)
                hadEffect := true
            case "chain":
                _HotkeysDoChain(a, context, depth)
                hadEffect := true
            case "aim":
                ; Aim only counts as "the effect" when it pressed the output
                ; itself (press=on). A move-only aim leaves hadEffect false so the
                ; bound output still auto-fires below — i.e. aim + cast.
                if _HotkeysDoAim(hk, a, snap)
                    hadEffect := true
        }
    }
    ; Conditions-only hotkey: no effect action ran, so fire the bound output once.
    if !hadEffect
        _HotkeysFireOutput(hk)
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

; Reads the full list of active player buff effects (on demand, via the snapshot's
; local-player pointer), or 0 when unavailable. Each effect is a Map with name /
; charges / timeLeft. Used by the buff & charges debug readout.
_HotkeysReadBuffs(snap)
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
    return buffs["effects"]
}

; Builds the debug lines listing every active buff (name + stacks + time-left). The
; buff whose name contains <needle> (case-insensitive — the one the condition checks)
; is returned as a [text, "green"] pair so the overlay highlights it; the rest are
; plain strings. Returns an Array (with a "(no active buffs)" entry when none).
_HotkeysBuffListLines(snap, needle)
{
    out := []
    effects := _HotkeysReadBuffs(snap)
    if !(effects && effects is Array && effects.Length)
    {
        out.Push("  (no active buffs)")
        return out
    }
    nlow := StrLower(needle)
    for eff in effects
    {
        if !(eff is Map)
            continue
        bn := eff.Has("name") ? eff["name"] : ""
        if (bn = "")
            continue
        ch := eff.Has("charges")  ? (eff["charges"] + 0) : 0
        tl := eff.Has("timeLeft") ? Round(eff["timeLeft"]) : 0
        txt := "  " bn (ch > 1 ? " x" ch : "") (tl > 0 ? " " tl "ms" : "")
        out.Push((nlow != "" && InStr(StrLower(bn), nlow)) ? [txt, "green"] : txt)
    }
    if (out.Length = 0)
        out.Push("  (no active buffs)")
    return out
}

; Builds the projection origin for a pixel-radius test. originMode "cursor" measures from the
; mouse position; "player" from the player's own on-screen position. Reuses the shared
; isometric origin so the distance metric matches the drawn range ring exactly. Returns the
; origin Map (adds ox/oy = the radius centre) or 0 if the game/window/player is unavailable.
_HotkeysPxOrigin(snap, originMode)
{
    pori := _HotkeysIsoOrigin(snap)
    if !pori
        return 0
    if (originMode = "cursor")
    {
        ox := 0, oy := 0
        CoordMode("Mouse", "Screen")
        MouseGetPos(&ox, &oy)
    }
    else
    {
        ox := pori["psx"], oy := pori["psy"]
    }
    pori["ox"] := ox, pori["oy"] := oy
    return pori
}

; Screen-pixel distance from the px-origin (see _HotkeysPxOrigin) to a world point, using the
; radar's isometric ground projection (so it matches the drawn ring + dots). UNCLAMPED: an
; off-screen entity keeps its true far offset and falls outside the radius, instead of being
; clamped to the screen edge and falsely counted (which made monsterCount fire with nothing
; actually in range). Always >= 0.
_HotkeysPxDist(octx, wx, wy, wz)
{
    dx := wx - octx["px"]
    dy := wy - octx["py"]
    ex := octx["psx"] + (dx - dy) * octx["sx"]    ; entity screen pos (isometric)
    ey := octx["psy"] - (dx + dy) * octx["sy"]
    ddx := ex - octx["ox"]
    ddy := ey - octx["oy"]
    return Sqrt(ddx * ddx + ddy * ddy)
}

; Monster-count gate: counts hostile (targetable) entities, optionally filtered by
; rarity, within the configured radius, and compares to the threshold. radiusMode
; "cursor"/"player" use a screen-pixel radius (action "radius"); "world" uses a
; zoom-independent world-unit radius around the player (action "worldRadius").
; action: Map("radius", px, "worldRadius", units,
;             "radiusMode","cursor"|"player"|"world",
;             "rarity","any"|"normal"|"magic"|"rare"|"unique", "op",">=", "value", n)
; Delegates the actual counting to _HotkeysCountByRarity, then picks the rarity bucket.
_HotkeysCheckMonsterCount(a, snap)
{
    if !snap
        return false
    mode := a.Has("radiusMode") ? a["radiusMode"] : "player"
    radiusVal := (mode = "world" || mode = "worldCursor")
        ? (a.Has("worldRadius") ? (a["worldRadius"] + 0) : 1000)
        : (a.Has("radius") ? (a["radius"] + 0) : 120)
    counts := _HotkeysCountByRarity(snap, radiusVal, mode)
    rarity := a.Has("rarity") ? a["rarity"] : "any"
    n := (rarity = "any") ? counts["total"]
                          : (counts.Has(rarity) ? counts[rarity] : 0)
    return _HotkeysCompare(n, a.Has("op") ? a["op"] : ">=", a.Has("value") ? (a["value"] + 0) : 1)
}

; Legacy alias: the old "monsterCountCursor" action is now just a monster-count
; gate with radiusMode "cursor". Kept so pre-merge configs/exports still run.
_HotkeysCheckMonsterCountCursor(a, snap)
{
    a2 := a.Clone()
    a2["radiusMode"] := "cursor"
    return _HotkeysCheckMonsterCount(a2, snap)
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

; Records that hotkey <hk> just fired <key> into its runtime state
; (lastFireTick / lastFireKey), for the debug overlay's "last fired" line.
; Empty keys are ignored (no real trigger happened).
_HotkeysMarkFired(hk, key)
{
    if (Trim(key) = "")
        return
    rt := _HotkeysRuntime(hk["id"])
    rt["lastFireTick"] := A_TickCount
    rt["lastFireKey"]  := key
}

; Resolves the hotkey's output key, sends it once, and records the fire. The single
; "send the bound output once" path, so every site that does so also updates the
; last-fired bookkeeping.
_HotkeysFireOutput(hk)
{
    key := _HotkeysResolveKey(hk)
    _HotkeysSendKey(key)
    _HotkeysMarkFired(hk, key)
}

; Merged key action: dispatches on "mode" to the press / hold / loop behaviour.
; action: Map("mode","press"|"hold"|"loop", ...mode-specific fields)
_HotkeysDoKey(hk, a)
{
    mode := a.Has("mode") ? a["mode"] : "press"
    if (mode = "hold")
        _HotkeysDoHold(hk, a)
    else if (mode = "loop")
        _HotkeysDoRepeat(hk, a)
    else
        _HotkeysFireOutput(hk)
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
    _HotkeysFireOutput(hk)
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
            _HotkeysFireOutput(hk)
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
    _HotkeysMarkFired(hk, key)
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
; Returns true only when it actually PRESSED the output key (press=on + a target
; was found), so the caller knows whether the bound output still needs to fire.
; A move-only aim (press off) returns false → the hotkey's auto-output still
; fires afterwards, so "aim at the monster + cast" works without a Press toggle.
_HotkeysDoAim(hk, a, snap)
{
    if !snap
        return false
    gameHwnd := ResolvePoEWindow()
    if !gameHwnd
        return false

    target := _HotkeysSelectAimTarget(a, snap)
    if !target
        return false

    ; Project the target to the screen with the SAME player-relative isometric
    ; projection the radar dots, the range rings and the monster-count gate use
    ; (_HotkeysIsoOrigin + the ex/ey formula from _HotkeysPxDist). The W2S camera
    ; matrix proved unreliable for points away from the player (see the note on
    ; RadarOverlay._DrawWorldRing), so an earlier matrix-based aim landed where
    ; the entity shows on the map rather than on the monster. This iso projection
    ; is centred on the player's on-screen position and is tunable via the Combat
    ; "world-to-screen scale" slider (g_combatW2SScale), matching the visible ring.
    octx := _HotkeysIsoOrigin(snap)
    if !octx
        return false
    dx := target["x"] - octx["px"]
    dy := target["y"] - octx["py"]
    screenX := Round(octx["psx"] + (dx - dy) * octx["sx"])
    screenY := Round(octx["psy"] - (dx + dy) * octx["sy"])
    ; Safety clamp to the game's client area (margin) so a bad projection can
    ; never move the cursor onto another window / off-screen.
    rect := NavClientRect(gameHwnd)
    if (rect)
    {
        m := 4
        screenX := Max(rect["x"] + m, Min(screenX, rect["x"] + rect["w"] - m))
        screenY := Max(rect["y"] + m, Min(screenY, rect["y"] + rect["h"] - m))
    }
    _MoveMouseToTarget(Map("x", screenX, "y", screenY))

    ; Move-only aim: report false so the caller still auto-fires the bound output
    ; (cursor is now on the monster, so the output casts there).
    if !(a.Has("press") && a["press"])
        return false

    holdMs := a.Has("holdMs") ? (a["holdMs"] + 0) : 0
    outKey := _HotkeysResolveKey(hk)
    if (holdMs > 0)
    {
        key := Trim(outKey)
        if (key != "" && _HotkeysKeyDown(key))
        {
            _HotkeysMarkFired(hk, key)
            SetTimer(() => _HotkeysKeyUp(key), -holdMs)
            return true
        }
        return false
    }
    _HotkeysSendKey(outKey)
    _HotkeysMarkFired(hk, outKey)
    return true
}

; Selects the nearest entity matching the aim filter within a screen-pixel
; radius of the chosen origin (mouse cursor or the player's on-screen position).
; Returns Map("x","y","z") of the target world position, or 0.
_HotkeysSelectAimTarget(a, snap)
{
    radius := a.Has("radius") ? (a["radius"] + 0) : 150
    scanAll := a.Has("scanAll") && a["scanAll"]
    targetType := a.Has("targetType") ? a["targetType"] : "monster"
    ; Radius origin: pixel distance measured either from the cursor or from the
    ; player's projected screen position (both in screen pixels).
    originMode := (a.Has("radiusMode") && a["radiusMode"] = "cursor") ? "cursor" : "player"
    worldPre := 4000   ; cheap world pre-filter before projecting

    octx := _HotkeysPxOrigin(snap, originMode)
    if !octx
        return 0

    bestDist := radius + 1
    best := 0
    for entry in _HotkeysAwakeSample(snap)
    {
        entity := entry.Has("entity") ? entry["entity"] : 0
        if !(entity && entity is Map)
            continue
        dist := entry.Has("distance") ? entry["distance"] : -1
        if (dist < 0 || dist > worldPre)
            continue
        if (!scanAll && !_HotkeysAimMatches(entity, a, targetType))
            continue
        dc := entity.Has("decodedComponents") ? entity["decodedComponents"] : 0
        render := (dc && dc is Map && dc.Has("render")) ? dc["render"] : 0
        wp := (render && render is Map && render.Has("worldPosition")) ? render["worldPosition"] : 0
        if !(wp && wp is Map)
            continue
        wx := wp.Has("x") ? wp["x"] : 0
        wy := wp.Has("y") ? wp["y"] : 0
        wz := wp.Has("z") ? wp["z"] : 0

        metric := _HotkeysPxDist(octx, wx, wy, wz)
        if (metric < 0 || metric > radius)
            continue
        if (metric < bestDist)
        {
            bestDist := metric
            best := Map("x", wx, "y", wy, "z", wz)
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
