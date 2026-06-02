; TreeView_StatsFormatting.ahk
; Stat formatting, display names, monster name lookup
; Included by TreeViewWatchlistPanel.ahk

; Formats a single stat pair for tree display.
; Returns "" if this stat should be suppressed (already rendered by argIndex=0 sibling).
FormatStatEntry(statKey, statValue)
{
    global _statsFormatted, _statsRaw, _statsSuppressed
    statId := ResolveStatDisplayName(statKey)

    ; Check if this stat should be suppressed before any other processing
    if IsSuppressedStat(statId)
    {
        _statsSuppressed += 1
        return ""
    }

    descMap := GetStatDescMap()
    if !(descMap && Type(descMap) = "Map" && descMap.Has(statId))
    {
        ; No CSD template — try pattern-based formatting
        patternLabel := FormatStatByPattern(statId, statValue)
        if (patternLabel != "")
        {
            _statsFormatted += 1
            return patternLabel
        }
        _statsRaw += 1
        global _rawStatIds
        if (Type(_rawStatIds) = "Array")
            _rawStatIds.Push(statId "`t" statValue)
        return statId ": " statValue
    }

    entry    := descMap[statId]
    tmpl     := entry["template"]
    argIdx   := entry["argIndex"]
    groupIds := entry["groupIds"]

    ; Single-stat entry
    if (groupIds.Length <= 1)
    {
        _statsFormatted += 1
        return ApplyStatTemplate(tmpl, [statValue])
    }

    ; Multi-stat: non-primary stats are suppressed (primary renders the full template)
    if (argIdx != 0)
    {
        _statsSuppressed += 1
        return ""
    }

    ; Primary (argIndex=0): collect all sibling values from the pre-built context
    argValues := []
    loop groupIds.Length
        argValues.Push("")

    argValues[argIdx + 1] := statValue
    ctx := GetStatSiblingContext()
    for _, sibId in groupIds
    {
        if (sibId = statId)
            continue
        if (ctx.Has(sibId))
        {
            sibEntry := descMap.Has(sibId) ? descMap[sibId] : ""
            sibArgIdx := (sibEntry && sibEntry.Has("argIndex")) ? sibEntry["argIndex"] : 1
            if (sibArgIdx + 1 <= argValues.Length)
                argValues[sibArgIdx + 1] := ctx[sibId]
        }
    }

    _statsFormatted += 1
    return ApplyStatTemplate(tmpl, argValues)
}

; Pattern-based formatting for virtual/computed stats not covered by CSD templates.
; Returns "" if no pattern matched.
FormatStatByPattern(statId, statValue)
{
    ctx := GetStatSiblingContext()

    ; --- permyriad → percent (divide by 100, e.g. 4000 → 40%) ---
    if RegExMatch(statId, "^(.+)_\+permyriad$", &m)
    {
        pct := Round(statValue / 100, 1)
        sign := (pct >= 0) ? "+" : ""
        label := StatIdToLabel(RegExReplace(m[1], "_\+$", ""))
        return sign pct "% " label
    }

    ; --- main_hand / off_hand min+max damage pairs ---
    for _, dmgType in ["cold", "fire", "lightning", "physical", "chaos"]
    {
        for _, hand in ["main_hand", "off_hand"]
        {
            minKey := hand "_minimum_" dmgType "_damage"
            maxKey := hand "_maximum_" dmgType "_damage"
            handLabel := (hand = "main_hand") ? "Main Hand" : "Off Hand"
            dmgLabel  := StrUpper(SubStr(dmgType, 1, 1)) SubStr(dmgType, 2)

            if (statId = minKey)
            {
                if ctx.Has(maxKey)
                {
                    GetStatSuppressSet()[maxKey] := true  ; register max for suppression
                    return handLabel " Adds " statValue " to " ctx[maxKey] " " dmgLabel " Damage"
                }
                return handLabel " Min " dmgLabel " Damage: " statValue
            }
        }
    }

    ; --- main_hand / off_hand min+max total damage ---
    for _, hand in ["main_hand", "off_hand"]
    {
        minKey := hand "_minimum_total_damage"
        maxKey := hand "_maximum_total_damage"
        handLabel := (hand = "main_hand") ? "Main Hand" : "Off Hand"
        if (statId = minKey)
        {
            if ctx.Has(maxKey)
            {
                GetStatSuppressSet()[maxKey] := true  ; register max for suppression
                return handLabel " Damage: " statValue "-" ctx[maxKey]
            }
            return handLabel " Min Damage: " statValue
        }
    }

    ; --- accuracy rating ---
    if RegExMatch(statId, "^(main_hand|off_hand|)_?accuracy_rating$", &m)
    {
        prefix := (m[1] = "main_hand") ? "Main Hand " : (m[1] = "off_hand") ? "Off Hand " : ""
        return prefix "Accuracy Rating: " statValue
    }

    ; --- attack speed ---
    if RegExMatch(statId, "^(main_hand|off_hand)_attack_speed_\+%$", &m)
    {
        handLabel := (m[1] = "main_hand") ? "Main Hand" : "Off Hand"
        return statValue "% increased " handLabel " Attack Speed"
    }

    ; --- critical strike chance ---
    if RegExMatch(statId, "^(main_hand|off_hand)_critical_strike_chance$", &m)
    {
        handLabel := (m[1] = "main_hand") ? "Main Hand" : "Off Hand"
        return handLabel " Crit Chance: " Round(statValue / 100, 2) "%"
    }

    ; --- life/mana/es recovery per minute ---
    if (statId = "total_life_recovery_per_minute_from_regeneration")
        return "Life Regen: " Round(statValue / 60, 1) "/s"
    if (statId = "total_mana_recovery_per_minute_from_regeneration")
        return "Mana Regen: " Round(statValue / 60, 1) "/s"
    if (statId = "energy_shield_recharge_rate_per_minute")
        return "ES Recharge Rate: " Round(statValue / 60, 1) "/s"

    ; --- cast/attack speed display ---
    if (statId = "cast_speed_+%_for_scaling_and_display")
        return statValue "% increased Cast Speed"

    ; === Single named stats ===
    if (statId = "armour")
        return "Armour: " statValue
    if (statId = "ailment_threshold")
        return "Ailment Threshold: " statValue
    if (statId = "poise_threshold")
        return "Poise Threshold: " statValue
    if (statId = "life_unreserved")
        return "Unreserved Life: " statValue
    if (statId = "mana_unreserved")
        return "Unreserved Mana: " statValue
    if (statId = "life_recovery_per_minute")
        return "Life Regen: " Round(statValue / 60, 1) "/s"
    if (statId = "mana_recovery_per_minute")
        return "Mana Regen: " Round(statValue / 60, 1) "/s"
    if (statId = "energy_shield_recovery_per_minute" || statId = "total_energy_shield_recovery_per_minute_from_recharge")
        return "ES Recharge: " Round(statValue / 60, 1) "/s"
    if (statId = "generic_accuracy_rating")
        return "Accuracy Rating: " statValue
    if (statId = "virtual_maximum_rage")
        return "Maximum Rage: " statValue
    if (statId = "is_at_maximum_rage")
        return "At Maximum Rage: " (statValue ? "Yes" : "No")
    if (statId = "virtual_total_energy_shield_recharge_delay_ms")
        return "ES Recharge Delay: " Round(statValue / 1000, 2) "s"
    if (statId = "total_sanctum_honour")
        return "Sanctum Honour: " statValue
    if (statId = "number_of_active_buffs")
        return "Active Buffs: " statValue
    if (statId = "number_of_equipped_items")
        return "Equipped Items: " statValue
    if (statId = "num_socketed_soul_cores")
        return "Socketed Soul Cores: " statValue
    if (statId = "num_socketed_runes")
        return "Socketed Runes: " statValue
    if (statId = "attack_hits_trigger_herald_of_thunder_lightning")
        return "Herald of Thunder Trigger: Active"

    ; === Chance to evade ===
    if RegExMatch(statId, "^(effective_)?chance_to_evade_%_estimate$")
        return "Chance to Evade: " statValue "%"

    ; === Socketed support gem colors ===
    if RegExMatch(statId, "^total_socketed_(red|green|blue)_skill_support_gems$", &m)
    {
        col := StrUpper(SubStr(m[1], 1, 1)) SubStr(m[1], 2)
        return col " Support Gems: " statValue
    }

    ; === Chance to hit evasive monsters ===
    if RegExMatch(statId, "^(main_hand|off_hand)_chance_to_hit_evasive_monsters_%$", &m)
    {
        handLabel := (m[1] = "main_hand") ? "Main Hand" : "Off Hand"
        return handLabel " Hit Chance: " statValue "%"
    }

    ; === Crit chance (permyriad, note typo "effetive" in game data) ===
    if RegExMatch(statId, "^(main_hand|off_hand)_effetive_total_chance_permyriad_for_hit_to_be_critical$", &m)
    {
        handLabel := (m[1] = "main_hand") ? "Main Hand" : "Off Hand"
        return handLabel " Crit Chance: " Round(statValue / 100, 2) "%"
    }

    ; === Reload speed ===
    if RegExMatch(statId, "^(main_hand|off_hand)_reload_speed_\+%$", &m)
    {
        handLabel := (m[1] = "main_hand") ? "Main Hand" : "Off Hand"
        return "+" statValue "% " handLabel " Reload Speed"
    }

    ; === affected_by_* → "Affected by X" ===
    if RegExMatch(statId, "^affected_by_(.+)$", &m)
        return "Affected by " StatIdToLabel(m[1])

    ; === combined_*_+%_final → "X% more Y" ===
    if RegExMatch(statId, "^combined_(.+)_\+%_final$", &m)
    {
        label := StatIdToLabel(m[1])
        return statValue "% more " label
    }

    ; === combined_*_+% → "+X% increased Y" ===
    if RegExMatch(statId, "^combined_(.+)_\+%$", &m)
    {
        label := StatIdToLabel(m[1])
        sign := (statValue >= 0) ? "+" : ""
        return sign statValue "% increased " label
    }

    ; === virtual_*_+% → "+X% increased Y" ===
    if RegExMatch(statId, "^virtual_(.+)_\+%$", &m)
    {
        label := StatIdToLabel(m[1])
        sign := (statValue >= 0) ? "+" : ""
        return sign statValue "% increased " label
    }

    ; === thorns damage pairs ===
    for _, dmgType in ["physical", "lightning", "cold", "fire", "chaos"]
    {
        minKey := "thorns_minimum_" dmgType "_damage"
        maxKey := "thorns_maximum_" dmgType "_damage"
        dmgLabel := StrUpper(SubStr(dmgType, 1, 1)) SubStr(dmgType, 2)
        if (statId = minKey)
        {
            if ctx.Has(maxKey)
            {
                GetStatSuppressSet()[maxKey] := true
                return "Thorns " dmgLabel " Damage: " statValue "-" ctx[maxKey]
            }
            return "Thorns Min " dmgLabel " Damage: " statValue
        }
    }
    if (statId = "thorns_minimum_total_damage")
    {
        if ctx.Has("thorns_maximum_total_damage")
        {
            GetStatSuppressSet()["thorns_maximum_total_damage"] := true
            return "Thorns Damage: " statValue "-" ctx["thorns_maximum_total_damage"]
        }
        return "Thorns Min Damage: " statValue
    }

    ; === estimate_mitigated damage pairs ===
    for _, dmgType in ["physical", "lightning", "cold", "fire", "chaos"]
    {
        for _, src in ["main_hand", "off_hand", "thorns"]
        {
            minKey := "estimate_mitigated_" src "_minimum_" dmgType "_damage"
            maxKey := "estimate_mitigated_" src "_maximum_" dmgType "_damage"
            srcLabel := (src = "main_hand") ? "Main Hand" : (src = "off_hand") ? "Off Hand" : "Thorns"
            dmgLabel  := StrUpper(SubStr(dmgType, 1, 1)) SubStr(dmgType, 2)
            if (statId = minKey)
            {
                if ctx.Has(maxKey)
                {
                    GetStatSuppressSet()[maxKey] := true
                    return "Est. " srcLabel " " dmgLabel ": " statValue "-" ctx[maxKey]
                }
                return "Est. " srcLabel " Min " dmgLabel ": " statValue
            }
        }
    }

    return ""
}


; Returns true if this stat should be hidden (display_* prefix, or registered max-damage sibling).
IsSuppressedStat(statId)
{
    ; All display_ prefixed stats are internal/redundant
    if (SubStr(statId, 1, 8) = "display_")
        return true

    ; Check the suppress set (populated when paired min-damage stat renders)
    suppressSet := GetStatSuppressSet()
    if (suppressSet.Has(statId))
        return true

    ; Generic fallback: any _maximum_*_damage where the _minimum_ counterpart exists in context
    if RegExMatch(statId, "^(.+)_maximum_(.+_damage)$", &m)
    {
        minKey := m[1] "_minimum_" m[2]
        if (GetStatSiblingContext().Has(minKey))
            return true
    }

    ; Internal / redundant stats — no useful display value
    if (statId = "use_melee_pattern_range"
        || statId = "use_melee_pattern_range_for_maximum_action_distance"
        || statId = "main_hand_wieldable_type"
        || statId = "skill_elemental_conflux_has_reservation"
        || statId = "both_hands_are_empty"
        || statId = "always_has_quadruped_head_control"
        || statId = "weapon_set_index"
        || statId = "is_shapeshifted"
        || statId = "current_shapeshift"
        || statId = "weapon_set_inherent_shapeshift_form"
        || statId = "dodge_roll_use_additive_move_anim"
        || statId = "override_turn_duration_ms")
        return true

    ; Suppress by prefix
    if (SubStr(statId, 1, 13) = "intermediary_"
        || SubStr(statId, 1, 13) = "intermediate_"
        || SubStr(statId, 1, 16) = "base_pushiness_+"
        || SubStr(statId, 1, 28) = "local_weapon_implicit_hidden"
        || SubStr(statId, 1, 12) = "support_gem_"
        || SubStr(statId, 1, 16) = "arrow_rain_fall_"
        || SubStr(statId, 1, 5) = "wolf_")
        return true

    ; virtual_total_socketed_*_are_the_highest
    if RegExMatch(statId, "^virtual_total_socketed_.+_are_the_highest$")
        return true

    return false
}

; Returns the global suppress set Map (lazy-initialized per stats array).
GetStatSuppressSet()
{
    global _statsSuppressSet
    if (Type(_statsSuppressSet) != "Map")
        _statsSuppressSet := Map()
    return _statsSuppressSet
}

; Convert a stat_id string to a readable label (underscores → spaces, title-case).
StatIdToLabel(statId)
{
    result := StrReplace(statId, "_", " ")
    ; Title-case first letter only
    return StrUpper(SubStr(result, 1, 1)) SubStr(result, 2)
}

; Apply a CSD template string, substituting {0}, {1}, ... with values from argValues[].
; Handles {N:+d} (force sign) format specifiers.
ApplyStatTemplate(tmpl, argValues)
{
    result := tmpl
    loop argValues.Length
    {
        idx := A_Index - 1
        val := argValues[A_Index]

        if RegExMatch(result, "\{" idx ":([^}]+)\}", &fm)
        {
            fmt := fm[1]
            fmtPlaceholder := "{" idx ":" fmt "}"
            if InStr(fmt, "+")
                formatted := (val >= 0 ? "+" val : val)
            else if (fmt = "%")
                formatted := Round(val / 10, 1)
            else
                formatted := val
            result := StrReplace(result, fmtPlaceholder, formatted)
        }
        result := StrReplace(result, "{" idx "}", val)
    }
    return result
}

; Initialises the global sibling context Map from a full stats array before rendering begins.
; Resets all formatting counters and the suppress set for a fresh render pass.
BuildStatSiblingContext(statsArray)
{
    global _statSiblingContext, _statsSuppressSet, _statsFormatted, _statsRaw, _statsSuppressed, _rawStatIds
    _statSiblingContext := Map()
    _statsSuppressSet   := Map()
    _statsFormatted     := 0
    _statsRaw           := 0
    _statsSuppressed    := 0
    _rawStatIds         := []
    for _, pair in statsArray
    {
        if !(Type(pair) = "Map" && pair.Has("key") && pair.Has("value"))
            continue
        statId := ResolveStatDisplayName(pair["key"])
        _statSiblingContext[statId] := pair["value"]
    }
}

; Returns the global sibling context Map (lazy-initialised), used to look up paired stat values.
GetStatSiblingContext()
{
    global _statSiblingContext
    if (Type(_statSiblingContext) != "Map")
        _statSiblingContext := Map()
    return _statSiblingContext
}

; Clears the sibling context and suppress set after a render pass is complete.
ClearStatSiblingContext()
{
    global _statSiblingContext, _statsSuppressSet
    _statSiblingContext := Map()
    _statsSuppressSet   := Map()
}

; Resolves a raw stat key (numeric row index or string ID) to its human-readable display name.
; Returns: the display name from stat_name_map.tsv, or "#key" if not found.
ResolveStatDisplayName(statId)
{
    statMap := GetStatNameMap()
    key := statId ""
    if !(statMap && Type(statMap) = "Map")
        return "#" key

    ; In-memory StatPair keys are 1-based Stats.dat row indices.
    ; stat_name_map.tsv is 0-based row index keyed.
    if RegExMatch(key, "^-?\d+$")
    {
        numericKey := Integer(key)
        if (numericKey > 0)
        {
            zeroBasedKey := (numericKey - 1) ""
            if statMap.Has(zeroBasedKey)
                return statMap[zeroBasedKey]
        }
    }

    if statMap.Has(key)
        return statMap[key]
    return "#" key
}

; Resolves a monster entity path to a display name using the monster name map.
; Returns: display name from monster_name_map.tsv, or fallbackName if not found.
ResolveMonsterDisplayName(entityPath, fallbackName := "")
{
    monsterMap := GetMonsterNameMap()
    if !(monsterMap && Type(monsterMap) = "Map")
        return fallbackName

    candidates := []
    seen := Map()

    AddMonsterNameLookupCandidates(candidates, seen, entityPath)
    short := ShortEntityPath(entityPath)
    AddMonsterNameLookupCandidates(candidates, seen, short)

    for _, key in candidates
    {
        if monsterMap.Has(key)
            return monsterMap[key]
    }

    return fallbackName
}

; Adds normalised key variants of rawKey (full path and basename) to the candidate list.
AddMonsterNameLookupCandidates(candidates, seen, rawKey)
{
    n := NormalizeMonsterNameMapKey(rawKey)
    if (n = "")
        return

    AddMonsterNameLookupCandidateVariants(candidates, seen, n)

    if RegExMatch(n, ".*/([^/]+)$", &m)
        AddMonsterNameLookupCandidateVariants(candidates, seen, m[1])
}

; Adds a normalised key and its stripped variants (no @level suffix, no trailing underscore) to the candidate list.
AddMonsterNameLookupCandidateVariants(candidates, seen, normalizedKey)
{
    if (normalizedKey = "")
        return

    AddMonsterNameLookupCandidate(candidates, seen, normalizedKey)

    noAt := RegExReplace(normalizedKey, "@\d+$", "")
    if (noAt != normalizedKey)
        AddMonsterNameLookupCandidate(candidates, seen, noAt)

    noAtNoUnderscore := RegExReplace(noAt, "_+$", "")
    if (noAtNoUnderscore != noAt)
        AddMonsterNameLookupCandidate(candidates, seen, noAtNoUnderscore)
}

; Appends key to the candidates list if it has not been seen before.
AddMonsterNameLookupCandidate(candidates, seen, key)
{
    if (key = "" || seen.Has(key))
        return
    seen[key] := true
    candidates.Push(key)
}

; Lowercases and normalises slash separators in a monster name map key.
NormalizeMonsterNameMapKey(key)
{
    if (key = "")
        return ""

    n := StrLower(Trim(key))
    n := StrReplace(n, "\\", "/")
    while InStr(n, "//")
        n := StrReplace(n, "//", "/")
    return n
}

; Loads and caches stat_name_map.tsv as a rowIndex→statId Map.
; Returns: the Map, automatically reloaded when the file changes on disk.
GetStatNameMap()
{
    static cachedMap := 0
    static cachedSig := ""

    mapPath := A_ScriptDir "\\data\\stat_name_map.tsv"
    if !FileExist(mapPath)
        return Map()

    sig := FileGetSize(mapPath) "|" FileGetTime(mapPath, "M")
    if (cachedMap && cachedSig = sig)
        return cachedMap

    loaded := Map()
    Loop Read, mapPath
    {
        line := Trim(A_LoopReadLine)
        if (line = "")
            continue
        first := SubStr(line, 1, 1)
        if (first = ";" || first = "#")
            continue

        parts := StrSplit(line, "`t")
        if (parts.Length < 2)
            continue

        idText := Trim(parts[1])
        nameText := Trim(parts[2])
        if (idText = "" || nameText = "")
            continue
        loaded[idText] := nameText
    }

    cachedMap := loaded
    cachedSig := sig
    return cachedMap
}

; Loads and caches stat_desc_map.tsv as a statId→{template,argIndex,groupIds} Map.
; Returns: the description Map, automatically reloaded when the file changes on disk.
GetStatDescMap()
{
    static cachedMap := 0
    static cachedSig := ""

    mapPath := A_ScriptDir "\\data\\stat_desc_map.tsv"
    if !FileExist(mapPath)
        return Map()

    sig := FileGetSize(mapPath) "|" FileGetTime(mapPath, "M")
    if (cachedMap && cachedSig = sig)
        return cachedMap

    loaded := Map()
    Loop Read, mapPath
    {
        line := Trim(A_LoopReadLine)
        if (line = "" || SubStr(line, 1, 1) = "#")
            continue
        parts := StrSplit(line, "`t")
        if (parts.Length < 4)
            continue
        ; Map: stat_id -> {template, argIndex, groupIds[]}
        loaded[Trim(parts[1])] := Map(
            "template",  Trim(parts[2]),
            "argIndex",  Integer(Trim(parts[3])),
            "groupIds",  StrSplit(Trim(parts[4]), ",")
        )
    }

    cachedMap := loaded
    cachedSig := sig
    return cachedMap
}

; ─── Shared TSV map loader ────────────────────────────────────────────────────
; Loads a two-column TSV (key TAB value) into a Map.
; keyMode: "raw" | "lower" | "monster"
; skipDupes: if true, first occurrence of a key wins; otherwise last wins.
LoadTsvMap(filePath, keyMode := "raw", skipDupes := false)
{
    loaded := Map()
    Loop Read, filePath
    {
        line := Trim(A_LoopReadLine)
        if (line = "")
            continue
        first := SubStr(line, 1, 1)
        if (first = ";" || first = "#")
            continue
        parts := StrSplit(line, "`t")
        if (parts.Length < 2)
            continue
        rawKey := Trim(parts[1])
        val    := Trim(parts[2])
        if (rawKey = "" || val = "")
            continue
        k := (keyMode = "lower") ? StrLower(rawKey)
           : (keyMode = "monster") ? NormalizeMonsterNameMapKey(rawKey)
           : rawKey
        if (skipDupes && loaded.Has(k))
            continue
        loaded[k] := val
    }
    return loaded
}

; Cache-aware wrapper for LoadTsvMap. Keeps one {sig, map} entry per unique filePath.
_GetCachedTsvMap(filePath, keyMode, skipDupes, &cache)
{
    if !IsObject(cache)
        cache := Map()
    if !FileExist(filePath)
        return Map()
    sig := FileGetSize(filePath) "|" FileGetTime(filePath, "M")
    if (cache.Has("sig") && cache["sig"] = sig)
        return cache["map"]
    loaded := LoadTsvMap(filePath, keyMode, skipDupes)
    cache["sig"] := sig
    cache["map"] := loaded
    return loaded
}

; Loads and caches buff_name_map.tsv as a lowercase id → display name Map.
GetBuffNameMap()
{
    static cache := 0
    return _GetCachedTsvMap(A_ScriptDir "\\data\\buff_name_map.tsv", "lower", true, &cache)
}

; ─── Monster name map ─────────────────────────────────────────────────────────
; Loads and caches monster_name_map.tsv as a normalised path suffix→display name Map.
; Returns: the monster name Map, automatically reloaded when the file changes on disk.
GetMonsterNameMap()
{
    static cachedMap := 0
    static cachedSig := ""

    mapPath := A_ScriptDir "\\data\\monster_name_map.tsv"
    if !FileExist(mapPath)
        return Map()

    sig := FileGetSize(mapPath) "|" FileGetTime(mapPath, "M")
    if (cachedMap && cachedSig = sig)
        return cachedMap

    loaded := Map()
    Loop Read, mapPath
    {
        line := Trim(A_LoopReadLine)
        if (line = "")
            continue

        first := SubStr(line, 1, 1)
        if (first = ";" || first = "#")
            continue

        parts := StrSplit(line, "`t")
        if (parts.Length < 2)
            continue

        keyText := NormalizeMonsterNameMapKey(parts[1])
        nameText := Trim(parts[2])
        if (keyText = "" || nameText = "")
            continue

        if !loaded.Has(keyText)
            loaded[keyText] := nameText
    }

    cachedMap := loaded
    cachedSig := sig
    return cachedMap
}
