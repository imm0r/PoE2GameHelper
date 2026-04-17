; SnapshotSerializers.ahk
; Converts game snapshots (AHK Maps) into JSON strings for the WebView UI.
; Each _Build*Json function produces a JSON string for a specific UI tab.
;
; Included by InGameStateMonitor.ahk

; Classifies an entity path string into a display type (Player, Enemy, NPC, etc.).
_ClassifyEntityType(path)
{
    p := StrLower(path)
    if InStr(p, "metadata/characters/")
        return "Player"
    if InStr(p, "playersummoned") || InStr(p, "companion") || InStr(p, "playerminion")
        return "Minion"
    ; Structural / navigation types (check before generic Enemy)
    if InStr(p, "areatransition")
        return "AreaTransition"
    if InStr(p, "waypoint")
        return "Waypoint"
    if InStr(p, "checkpoint")
        return "Checkpoint"
    if InStr(p, "metadata/npc/") || InStr(p, "/npcs/")
        return "NPC"
    if InStr(p, "metadata/monsters/")
    {
        if InStr(p, "boss") || InStr(p, "unique")
            return "Boss"
        return "Enemy"
    }
    if InStr(p, "metadata/chests/") || InStr(p, "strongbox") || InStr(p, "detonator")
        return "Chest"
    if InStr(p, "worlditem") || InStr(p, "metadata/items/")
        return "WorldItem"
    if InStr(p, "metadata/projectiles/")
        return "Projectile"
    if InStr(p, "metadata/terrain/")
        return "Terrain"
    return "Object"
}

; Returns true if the entity type is one worth showing even when sleeping.
_IsSleepingEntityImportant(entityType)
{
    return (entityType = "Boss" || entityType = "Checkpoint"
        || entityType = "Waypoint" || entityType = "AreaTransition" || entityType = "NPC")
}

; Builds a JSON array of active buff objects for the Buffs tab.
_BuildBuffsJson(snapshot)
{
    try
    {
        inGame  := snapshot.Has("inGameState")   ? snapshot["inGameState"]   : 0
        area    := (inGame && inGame.Has("areaInstance")) ? inGame["areaInstance"] : 0
        bc      := (area  && area.Has("playerBuffsComponent")) ? area["playerBuffsComponent"] : 0
        if !IsObject(bc)
            return "[]"
        effects := bc.Has("effects") ? bc["effects"] : 0
        if !IsObject(effects)
            return "[]"

        ; Build skill icon lookup for fallback (buff→skill icon matching)
        skillIconLookup := Map()
        sk := (area && area.Has("playerSkills")) ? area["playerSkills"] : 0
        if IsObject(sk) && sk.Has("skills")
        {
            for _, s in sk["skills"]
            {
                if !IsObject(s)
                    continue
                dn := s.Has("displayName") ? String(s["displayName"]) : ""
                sic := s.Has("iconPath") ? String(s["iconPath"]) : ""
                if (dn != "" && sic != "")
                    skillIconLookup[StrLower(StrReplace(dn, " ", ""))] := sic
            }
        }

        rows      := "["
        first     := true
        buffNames := GetBuffNameMap()
        for _, eff in effects
        {
            if !IsObject(eff)
                continue
            name    := eff.Has("name")      ? String(eff["name"])      : ""
            charges := eff.Has("charges")   ? Integer(eff["charges"])  : 0
            tLeft   := eff.Has("timeLeft")  ? eff["timeLeft"]          : 0
            tTotal  := eff.Has("totalTime") ? eff["totalTime"]         : 0

            tLeftJson  := (!IsNumber(tLeft)  || tLeft  > 999999) ? '"inf"' : Round(Float(tLeft),  2)
            tTotalJson := (!IsNumber(tTotal) || tTotal > 999999)  ? '"inf"' : Round(Float(tTotal), 2)

            nameKey     := StrLower(name)
            displayName := buffNames.Has(nameKey) ? buffNames[nameKey] : name
            en := StrReplace(displayName, "\",  "\\")
            en := StrReplace(en,          '"',  '\"')
            en := StrReplace(en,          "`n", "\n")
            en := StrReplace(en,          "`r", "\r")
            en := StrReplace(en,          "`t", "\t")
            ic := eff.Has("iconPath") ? String(eff["iconPath"]) : ""
            if (ic = "")
            {
                ; Try matching buff name to a skill icon
                normBuff := StrLower(StrReplace(name, "_", ""))
                for skillKey, skillIcon in skillIconLookup
                {
                    if (StrLen(skillKey) >= 4 && InStr(normBuff, skillKey) = 1)
                    {
                        ic := skillIcon
                        break
                    }
                }
            }
            ic := StrReplace(ic, "\",  "\\")
            ic := StrReplace(ic, '"',  '\"')

            if (en = "")
                continue
            rows .= (first ? "" : ",") '{"n":"' en '","s":' charges ',"t":' tLeftJson ',"tt":' tTotalJson ',"ic":"' ic '"}'
            first := false
        }
        return rows . "]"
    }
    catch
        return "[]"
}

; Builds a JSON array of entity objects for the Entities tab.
; Merges awake entities with important sleeping entities (bosses, NPCs, waypoints).
_BuildEntitiesJson(snap)
{
    try
    {
        global g_entityShowPlayer, g_entityShowMinion, g_entityShowEnemy
        global g_entityShowNPC, g_entityShowChest, g_entityShowWorldItem, g_entityShowOther

        if !IsObject(snap)
            return "[]"

        ; Collect awake and sleeping entity sources
        awakeEnt := 0
        sleepEnt := 0
        if snap.Has("inGameState")
        {
            inGame := snap["inGameState"]
            area   := (inGame && inGame.Has("areaInstance")) ? inGame["areaInstance"] : 0
            if (area && area.Has("awakeEntities"))
                awakeEnt := area["awakeEntities"]
            if (area && area.Has("sleepingEntities"))
                sleepEnt := area["sleepingEntities"]
        }
        if snap.Has("awakeEntities")
            awakeEnt := snap["awakeEntities"]
        if snap.Has("sleepingEntities") && !IsObject(sleepEnt)
            sleepEnt := snap["sleepingEntities"]

        ; Build unified candidate list: all awake + important sleeping
        allEntries := []
        awakePaths := Map()

        if (IsObject(awakeEnt) && awakeEnt.Has("sample") && IsObject(awakeEnt["sample"]))
        {
            for _, entry in awakeEnt["sample"]
            {
                if !IsObject(entry)
                    continue
                entity := entry.Has("entity") ? entry["entity"] : 0
                if !IsObject(entity)
                    continue
                path := entity.Has("path") ? entity["path"] : "?"
                awakePaths[path] := true
                allEntries.Push(Map("entry", entry, "sleeping", false))
            }
        }

        ; Sleeping entities — only keep important types
        if (IsObject(sleepEnt) && sleepEnt.Has("sample") && IsObject(sleepEnt["sample"]))
        {
            for _, entry in sleepEnt["sample"]
            {
                if !IsObject(entry)
                    continue
                entity := entry.Has("entity") ? entry["entity"] : 0
                if !IsObject(entity)
                    continue
                path := entity.Has("path") ? entity["path"] : "?"
                if awakePaths.Has(path)
                    continue
                eType := _ClassifyEntityType(path)
                if _IsSleepingEntityImportant(eType)
                    allEntries.Push(Map("entry", entry, "sleeping", true))
            }
        }

        if (allEntries.Length = 0)
            return "[]"

        rarityNames := Map(0,"Normal",1,"Magic",2,"Rare",3,"Unique",4,"Unique",5,"Boss")
        rows  := "["
        first := true
        for _, item in allEntries
        {
            entry  := item["entry"]
            isSleep := item["sleeping"]
            entity := entry.Has("entity")   ? entry["entity"]   : 0
            dist   := entry.Has("distance") ? Round(entry["distance"], 0) : -1
            if !IsObject(entity)
                continue

            path    := entity.Has("path") ? entity["path"] : "?"
            decoded := entity.Has("decodedComponents") ? entity["decodedComponents"] : 0

            entityType := _ClassifyEntityType(path)

            ; Promote Enemy to Boss if rarity is Unique/Boss
            rarId := (decoded && decoded.Has("rarityId")) ? decoded["rarityId"] : 0
            if (entityType = "Enemy" && (rarId >= 3))
                entityType := "Boss"

            ; Apply entity type filters
            showIt := true
            switch entityType
            {
                case "Player":         showIt := g_entityShowPlayer
                case "Minion":         showIt := g_entityShowMinion
                case "Enemy":          showIt := g_entityShowEnemy
                case "Boss":           showIt := g_entityShowEnemy
                case "NPC":            showIt := g_entityShowNPC
                case "Chest":          showIt := g_entityShowChest
                case "WorldItem":      showIt := g_entityShowWorldItem
                case "AreaTransition": showIt := g_entityShowOther
                case "Waypoint":       showIt := g_entityShowOther
                case "Checkpoint":     showIt := g_entityShowOther
                default:               showIt := g_entityShowOther
            }
            if !showIt
                continue

            shortPath   := (path != "?") ? RegExReplace(path, ".*/", "") : "?"
            displayName := ResolveMonsterDisplayName(path, shortPath)

            rarity := rarityNames.Has(rarId) ? rarityNames[rarId] : "Normal"

            life    := (decoded && decoded.Has("life")) ? decoded["life"] : 0
            isAlive := true
            lifePct := -1
            if IsObject(life)
            {
                isAlive := life.Has("isAlive") ? life["isAlive"] : true
                lifePct := life.Has("lifeCurrentPercentMax") ? Round(life["lifeCurrentPercentMax"], 0) : -1
            }
            if decoded && decoded.Has("targetable")
                isAlive := decoded["targetable"]

            ; JSON-escape strings
            ep := StrReplace(path,        "\", "\\")
            ep := StrReplace(ep,          '"', '\"')
            en := StrReplace(displayName, "\", "\\")
            en := StrReplace(en,          '"', '\"')
            er := StrReplace(rarity,      '"', '\"')
            et := StrReplace(entityType,  '"', '\"')
            sl := isSleep ? "true" : "false"
            rows .= (first ? "" : ",")
                . '{"path":"' ep '","name":"' en '","rarity":"' er '","type":"' et '"'
                . ',"life":' lifePct ',"dist":' dist ',"alive":' (isAlive ? "true" : "false")
                . ',"sleep":' sl '}'
            first := false
        }
        return rows . "]"
    }
    catch
        return "[]"
}

; Builds a JSON object of important UI element states.
_BuildUIJson(snapshot)
{
    try
    {
        inGame := snapshot.Has("inGameState") ? snapshot["inGameState"] : 0
        if !inGame
            return "{}"
        ui := inGame.Has("importantUiElements") ? inGame["importantUiElements"] : 0
        if !IsObject(ui)
            return "{}"
        return _SerializeMapShallow(ui, 3)
    }
    catch
        return "{}"
}

; Builds a JSON object of the current game state (area instance data, excluding heavy subtrees).
_BuildGameStateJson(snapshot)
{
    try
    {
        if !IsObject(snapshot)
            return "{}"
        inGame := snapshot.Has("inGameState") ? snapshot["inGameState"] : 0
        if !inGame
            return "{}"
        area := inGame.Has("areaInstance") ? inGame["areaInstance"] : 0
        if !IsObject(area)
            return "{}"
        skip := Map("awakeEntities",1,"sleepingEntities",1,"playerBuffsComponent",1,"playerSkills",1,"flaskSlotsFromBuffs",1)
        return _SerializeMapShallow(area, 2, skip)
    }
    catch
        return "{}"
}

; Builds a JSON object with player skills data, deduplicating against active buffs.
_BuildSkillsJson(snapshot)
{
    try
    {
        inGame := snapshot.Has("inGameState") ? snapshot["inGameState"] : 0
        area := (inGame && inGame.Has("areaInstance")) ? inGame["areaInstance"] : 0
        sk := (area && area.Has("playerSkills")) ? area["playerSkills"] : 0
        if !IsObject(sk)
            return '{"skills":[],"asOff":0}'
        skills := sk.Has("skills") ? sk["skills"] : 0
        asOff := sk.Has("activeSkillOffset") ? Integer(sk["activeSkillOffset"]) : 0
        if !IsObject(skills) || Type(skills) != "Array" || skills.Length = 0
            return '{"skills":[],"asOff":' asOff '}'

        ; Read active buff names for dedup and distance-block detection
        buffNormSet := Map()
        distCharges := -1
        bc := (area && area.Has("playerBuffsComponent")) ? area["playerBuffsComponent"] : 0
        if IsObject(bc) && bc.Has("effects")
        {
            for _, eff in bc["effects"]
            {
                if !IsObject(eff)
                    continue
                bn := eff.Has("name") ? String(eff["name"]) : ""
                if (bn != "")
                {
                    normBn := StrLower(StrReplace(bn, "_", ""))
                    buffNormSet[normBn] := true
                }
                if (InStr(bn, "unusable") && InStr(bn, "moved"))
                    distCharges := eff.Has("charges") ? Integer(eff["charges"]) : 0
            }
        }

        rows := "["
        first := true
        for _, s in skills
        {
            if !IsObject(s)
                continue
            nm := s.Has("name") ? String(s["name"]) : "?"
            nm := StrReplace(nm, "\",  "\\")
            nm := StrReplace(nm, '"',  '\"')
            nm := StrReplace(nm, "`n", "\n")
            nm := StrReplace(nm, "`r", "\r")
            if (nm = "")
                continue
            dn := s.Has("displayName") ? String(s["displayName"]) : nm

            ; Dedup: skip skills already shown as active buffs
            normDn := StrLower(StrReplace(dn, " ", ""))
            if (StrLen(normDn) >= 4
                && (buffNormSet.Has(normDn)
                    || buffNormSet.Has(normDn "reservation")
                    || buffNormSet.Has(normDn "reserve")
                    || buffNormSet.Has(normDn "active")))
                continue

            dn := StrReplace(dn, "\",  "\\")
            dn := StrReplace(dn, '"',  '\"')
            dn := StrReplace(dn, "`n", "\n")
            dn := StrReplace(dn, "`r", "\r")

            ; Filter out unusable/DNT/utility skills
            if (InStr(nm, "Unusable") || InStr(nm, "DodgeRoll")
                || InStr(nm, "DirectMinions") || InStr(nm, "LingeringIllusionSpawn")
                || InStr(dn, "Direct Minions") || InStr(dn, "LingeringIllusionSpawn")
                || InStr(dn, "[DNT") || InStr(dn, "enforced_walking"))
                continue

            ic := s.Has("iconPath") ? String(s["iconPath"]) : ""
            ic := StrReplace(ic, "\",  "\\")
            ic := StrReplace(ic, '"',  '\"')

            useStage    := s.Has("useStage")    ? Integer(s["useStage"])    : 0
            castType    := s.Has("castType")    ? Integer(s["castType"])    : 0
            totalUses   := s.Has("totalUses")   ? Integer(s["totalUses"])   : 0
            cooldownMs  := s.Has("cooldownMs")  ? Integer(s["cooldownMs"])  : 0
            canUse      := (s.Has("canUse") && s["canUse"]) ? "true" : "false"
            activeCds   := s.Has("activeCooldowns") ? Integer(s["activeCooldowns"]) : 0
            maxUses     := s.Has("maxUses")     ? Integer(s["maxUses"])     : 0
            equipId     := s.Has("equipId")     ? s["equipId"]             : 0
            equipHex    := Format("0x{:X}", equipId & 0xFFFFFFFF)

            rows .= (first ? "" : ",")
                . '{"n":"' nm '"'
                . ',"dn":"' dn '"'
                . ',"ic":"' ic '"'
                . ',"us":' useStage
                . ',"ct":' castType
                . ',"tu":' totalUses
                . ',"cd":' cooldownMs
                . ',"ok":' canUse
                . ',"ac":' activeCds
                . ',"mu":' maxUses
                . ',"eq":"' equipHex '"}'
            first := false
        }
        return '{"skills":' rows '],"asOff":' asOff ',"distCh":' distCharges '}'
    }
    catch
        return '{"skills":[],"asOff":0}'
}

; Shallow-serialises an AHK Map to a JSON object string.
; depth: how many levels deep to recurse (1=flat, 2=one level of nested Maps)
; skipKeys: optional Map of keys to omit
_SerializeMapShallow(m, depth := 1, skipKeys := 0)
{
    if !IsObject(m) || Type(m) != "Map"
        return '""'
    out   := "{"
    first := true
    for k, v in m
    {
        if (IsObject(skipKeys) && skipKeys.Has(k))
            continue
        ek := StrReplace(String(k), '"', '\"')
        if IsObject(v)
        {
            if (depth > 1 && Type(v) = "Map")
                sv := _SerializeMapShallow(v, depth - 1, 0)
            else if Type(v) = "Array"
                sv := '"[Array/' v.Length ']"'
            else
                sv := '"[Object]"'
        }
        else
        {
            sv := String(v)
            if IsInteger(sv)
            {
                n := Integer(sv)
                ; Only hex-format values that look like pointers (large 64-bit values)
                ; and whose key name suggests a pointer/address/offset
                isPtr := (InStr(k, "Ptr") || InStr(k, "Address") || InStr(k, "address") || InStr(k, "Offset") || InStr(k, "flags") || InStr(k, "Flags"))
                if (isPtr && (n > 0xFFFF || n < -0xFFFF))
                    sv := '"0x' Format("{:X}", n & 0xFFFFFFFFFFFFFFFF) '"'
            }
            else if !IsNumber(sv)
            {
                sv := StrReplace(sv, "\",  "\\")
                sv := StrReplace(sv, '"',  '\"')
                sv := StrReplace(sv, "`n", "\n")
                sv := StrReplace(sv, "`r", "\r")
                sv := '"' sv '"'
            }
        }
        out .= (first ? "" : ",") '"' ek '":' sv
        first := false
    }
    return out . "}"
}
