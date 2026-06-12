; EntityFacts.ahk
; Thin shared helpers for entity facts derived from a path or decoded components.
; Deliberately small: the single entity-type classifier stays _ClassifyEntityType
; (SnapshotSerializers.ahk). These helpers add only what was missing and is shared by
; the serializer, the path-group engine and the alert engine:
;   - ExtractMetaGroup    : grouping seed = the family/archetype segment (3rd)
;   - ExtractMetaCategory : the top-level category segment (2nd)
;   - ExtractEntityLevel  : the "@NN" level suffix off the path leaf
;   - ReadEntityRarityId / RarityIdToName : robust rarity read (flat + nested shapes)
; Included via TreeViewWatchlistPanel.ahk.

; Grouping SEED for a path: the FAMILY/ARCHETYPE segment — the 3rd segment, i.e. the
; one after metadata/<category>/ — lowercased. This is NOT the top-level category
; (use ExtractMetaCategory for that). It is most meaningful for monsters, where the
; 3rd segment is the monster family you would group/colour by:
;   "Metadata/Monsters/LeagueBreach/BreachHand" -> "leaguebreach"   (the real group)
;   "Metadata/Chests/KedgeBayChests/KedgeBayChestValuable" -> "kedgebaychests"
;   "Metadata/NPC/Four_Act4/TujenJourneysEndSummon" -> "four_act4"  (an act bucket,
;       a weak "group" — which is why NPC/world-object readouts prefer the category).
; Consumers: SnapshotSerializers (JSON "metaGroup"), and EntityGroups, which ORs this
; seed together with the full path into the group-match haystack, so user group terms
; match against both the family token and the full path. Returns "" if no match.
ExtractMetaGroup(path)
{
    if (path = "")
        return ""
    if RegExMatch(path, "i)metadata/[^/]+/([^/]+)", &m)
        return StrLower(m[1])
    return ""
}

; Returns the top-level metadata category — the segment right after "Metadata/"
; (e.g. "Monsters", "NPC", "Chests"). Original case is preserved so it reads as the
; game intends ("NPC", not "npc"). Returns "" if the path is not a metadata path.
ExtractMetaCategory(path)
{
    if (path = "")
        return ""
    if RegExMatch(path, "i)metadata/([^/]+)", &m)
        return m[1]
    return ""
}

; Parses the optional "@NN" level suffix from an entity path leaf, e.g.
; ".../TujenJourneysEndSummon@51" -> "51". The game appends the entity's level there.
; Returns the level digits as a string, or "" when the path has no @level suffix.
ExtractEntityLevel(path)
{
    if (path = "")
        return ""
    if RegExMatch(path, "@(\d+)\s*$", &m)
        return m[1]
    return ""
}

; Reads the entity rarity id robustly. The radar/fast decode stores it flat as
; decoded["rarityId"]; the full decode stores it nested under mods /
; objectmagicproperties. We take the max found so a flat 0 cannot mask a nested
; value. Param: decoded - the entity's decodedComponents Map. Returns: 0..5.
ReadEntityRarityId(decoded)
{
    if !(decoded && Type(decoded) = "Map")
        return 0

    best := 0
    if (decoded.Has("rarityId") && IsInteger(decoded["rarityId"]))
        best := Max(best, decoded["rarityId"])

    for _, key in ["objectmagicproperties", "mods"]
    {
        if !decoded.Has(key)
            continue
        sub := decoded[key]
        if (sub && Type(sub) = "Map" && sub.Has("rarityId") && IsInteger(sub["rarityId"]))
            best := Max(best, sub["rarityId"])
    }
    return best
}

; Maps a rarity id to its display name (mirrors the serializer's inline table so
; all consumers agree). Param: id - 0..5. Returns: the rarity string.
RarityIdToName(id)
{
    static names := Map(0, "Normal", 1, "Magic", 2, "Rare", 3, "Unique", 4, "Unique", 5, "Boss")
    return names.Has(id) ? names[id] : "Normal"
}
