; PoE2InventoryReader.ahk
; Inventory and item reading layer — extends PoE2PlayerReader.
;
; Handles flask slot detection, inventory scanning, item details (mods, rarity,
; base types, unique names), and server data reading.
;
; Inheritance chain: PoE2GameStateReader → PoE2InventoryReader → PoE2PlayerReader

class PoE2InventoryReader extends PoE2PlayerReader
{
    ; Reads the world area id, name, act, and flags (town/waypoint/hideout) from a DatFile row pointer.
    ; Returns a Map with id, name, act, isTown, hasWaypoint, isHideout, isBattleRoyale; or 0 on invalid ptr.
    ReadWorldAreaDat(worldAreaRowPtr)
    {
        if !this.IsProbablyValidPointer(worldAreaRowPtr)
            return 0

        idPtr := this.Mem.ReadPtr(worldAreaRowPtr + PoE2Offsets.WorldAreaDat["IdPtr"])
        namePtr := this.Mem.ReadPtr(worldAreaRowPtr + PoE2Offsets.WorldAreaDat["NamePtr"])
        act := this.Mem.ReadInt(worldAreaRowPtr + PoE2Offsets.WorldAreaDat["Act"])
        isTownRaw := this.Mem.ReadBool(worldAreaRowPtr + PoE2Offsets.WorldAreaDat["IsTown"])
        hasWaypointRaw := this.Mem.ReadBool(worldAreaRowPtr + PoE2Offsets.WorldAreaDat["HasWaypoint"])

        id := this.Mem.ReadUnicodeString(idPtr)
        name := this.Mem.ReadUnicodeString(namePtr)

        idLower := StrLower(id)
        isTown := isTownRaw || id = "HeistHub" || id = "KalguuranSettlersLeague"
        hasWaypoint := hasWaypointRaw || id = "HeistHub"
        isHideout := InStr(idLower, "hideout") && !InStr(idLower, "map")
        isBattleRoyale := InStr(idLower, "exileroyale")

        return Map(
            "id", id,
            "name", name,
            "act", act,
            "isTown", isTown ? true : false,
            "hasWaypoint", hasWaypoint ? true : false,
            "isHideout", isHideout ? true : false,
            "isBattleRoyale", isBattleRoyale ? true : false
        )
    }

    ; Reads server-side player data and selects the best flask inventory from the inventory list.
    ; Scores each inventory by flask content likelihood; falls back to ID-match or first valid pointer.
    ; Returns: Map with address, playerDataPtr, flaskInventory, and selection diagnostics.
    ReadServerData(serverDataAddress, minimal := false)
    {
        if !this.IsProbablyValidPointer(serverDataAddress)
            return 0

        playerDataVecFirst := this.Mem.ReadInt64(serverDataAddress + PoE2Offsets.ServerData["PlayerServerData"])
        playerDataVecLast := this.Mem.ReadInt64(serverDataAddress + PoE2Offsets.ServerData["PlayerServerDataLast"])

        playerDataPtr := 0
        if (playerDataVecFirst > 0 && playerDataVecLast >= playerDataVecFirst)
            playerDataPtr := this.Mem.ReadPtr(playerDataVecFirst)

        inventoriesCount := 0
        flaskInventoryPtr := 0
        flaskInventoryIdMatched := -1
        inventoryIdsSeen := []
        flaskInventorySelectReason := "none"
        flaskInventory := 0

        if this.IsProbablyValidPointer(playerDataPtr)
        {
            invVecFirst := this.Mem.ReadInt64(playerDataPtr + PoE2Offsets.ServerDataStructure["PlayerInventories"])
            invVecLast := this.Mem.ReadInt64(playerDataPtr + PoE2Offsets.ServerDataStructure["PlayerInventoriesLast"])
            if (invVecFirst > 0 && invVecLast >= invVecFirst)
            {
                totalBytes := invVecLast - invVecFirst
                entrySize := PoE2Offsets.InventoryArray["EntrySize"]
                inventoriesCount := Floor(totalBytes / entrySize)
                maxEntries := Min(inventoriesCount, 128)

                preferredFlaskIds := [12, 1]
                fallbackAnyPtr := 0
                fallbackAnyId := -1
                bestFlaskScore := -1
                bestFlaskPtr := 0
                bestFlaskId := -1

                idx := 0
                while (idx < maxEntries)
                {
                    entryAddr := invVecFirst + (idx * entrySize)
                    invId := this.Mem.ReadInt(entryAddr + PoE2Offsets.InventoryArray["InventoryId"])
                    invPtr0 := this.Mem.ReadPtr(entryAddr + PoE2Offsets.InventoryArray["InventoryPtr0"])

                    if (inventoryIdsSeen.Length < 64)
                        inventoryIdsSeen.Push(invId)

                    if (invPtr0 && fallbackAnyPtr = 0)
                    {
                        fallbackAnyPtr := invPtr0
                        fallbackAnyId := invId
                    }

                    if (invPtr0)
                    {
                        flaskScore := this.ScoreInventoryFlaskLikelihood(invPtr0, minimal ? 10 : 24)
                        if (flaskScore > bestFlaskScore)
                        {
                            bestFlaskScore := flaskScore
                            bestFlaskPtr := invPtr0
                            bestFlaskId := invId
                        }
                    }

                    isPreferred := false
                    for wantedId in preferredFlaskIds
                    {
                        if (invId = wantedId)
                        {
                            isPreferred := true
                            break
                        }
                    }

                    if (invPtr0 && flaskInventoryPtr = 0 && isPreferred)
                    {
                        flaskInventoryPtr := invPtr0
                        flaskInventoryIdMatched := invId
                        flaskInventorySelectReason := "id-match"
                    }
                    idx += 1
                }

                if (bestFlaskScore > 0)
                {
                    flaskInventoryPtr := bestFlaskPtr
                    flaskInventoryIdMatched := bestFlaskId
                    flaskInventorySelectReason := "content-score"
                }
                else if !this.IsProbablyValidPointer(flaskInventoryPtr)
                {
                    flaskInventoryPtr := fallbackAnyPtr
                    flaskInventoryIdMatched := fallbackAnyId
                    flaskInventorySelectReason := "first-valid-fallback"
                }
            }
        }

        if this.IsProbablyValidPointer(flaskInventoryPtr)
            flaskInventory := this.ReadInventoryBasic(flaskInventoryPtr, minimal)

        return Map(
            "address", serverDataAddress,
            "playerDataPtr", playerDataPtr,
            "inventoriesCount", inventoriesCount,
            "flaskInventoryIdMatched", flaskInventoryIdMatched,
            "flaskInventorySelectReason", flaskInventorySelectReason,
            "inventoryIdsSeen", inventoryIdsSeen,
            "flaskInventoryPtr", flaskInventoryPtr,
            "flaskInventory", flaskInventory
        )
    }

    ; Scores how likely an inventory is a flask inventory by counting flask-like items inside it.
    ; Params: maxCheck - max number of item pointers to examine before stopping.
    ; Returns: count of items that pass IsLikelyFlaskItem, or 0 on invalid input.
    ScoreInventoryFlaskLikelihood(inventoryAddress, maxCheck := 24)
    {
        if !this.IsProbablyValidPointer(inventoryAddress)
            return 0

        itemListFirst := this.Mem.ReadInt64(inventoryAddress + PoE2Offsets.Inventory["ItemList"])
        itemListLast := this.Mem.ReadInt64(inventoryAddress + PoE2Offsets.Inventory["ItemListLast"])
        if (itemListFirst <= 0 || itemListLast < itemListFirst)
            return 0

        ptrSize := A_PtrSize
        totalEntries := Floor((itemListLast - itemListFirst) / ptrSize)
        if (totalEntries <= 0)
            return 0

        maxCheck := Min(totalEntries, maxCheck)
        score := 0
        idx := 0
        while (idx < maxCheck)
        {
            invItemStructPtr := this.Mem.ReadPtr(itemListFirst + (idx * ptrSize))
            if this.IsProbablyValidPointer(invItemStructPtr)
            {
                itemEntityPtr := this.Mem.ReadPtr(invItemStructPtr + PoE2Offsets.InventoryItem["Item"])
                ; Always use minimal for scoring — only metadataPath is needed by IsLikelyFlaskItem
                details := this.ReadFlaskItemDetails(itemEntityPtr, true)
                if this.IsLikelyFlaskItem(details)
                    score += 1
            }
            idx += 1
        }

        return score
    }

    ; Reads all item entries from an inventory slot array and builds a flask slot summary.
    ; Params: minimal - if true, returns only entryCount and flaskSlots (skips grid dimensions).
    ; Returns: Map with address, totalBoxes, entryCount, and flaskSlots keyed 1–5.
    ReadInventoryBasic(inventoryAddress, minimal := false)
    {
        if !this.IsProbablyValidPointer(inventoryAddress)
            return 0

        totalBoxesX := this.Mem.ReadInt(inventoryAddress + PoE2Offsets.Inventory["TotalBoxes"])
        totalBoxesY := this.Mem.ReadInt(inventoryAddress + PoE2Offsets.Inventory["TotalBoxesY"])

        itemListFirst := this.Mem.ReadInt64(inventoryAddress + PoE2Offsets.Inventory["ItemList"])
        itemListLast := this.Mem.ReadInt64(inventoryAddress + PoE2Offsets.Inventory["ItemListLast"])

        entries := []
        entryCount := 0
        if (itemListFirst > 0 && itemListLast >= itemListFirst)
        {
            totalBytes := itemListLast - itemListFirst
            ptrSize := A_PtrSize
            entryCount := Floor(totalBytes / ptrSize)
            maxEntries := Min(entryCount, 256)

            idx := 0
            while (idx < maxEntries)
            {
                invItemStructPtr := this.Mem.ReadPtr(itemListFirst + (idx * ptrSize))
                if this.IsProbablyValidPointer(invItemStructPtr)
                {
                    itemEntityPtr := this.Mem.ReadPtr(invItemStructPtr + PoE2Offsets.InventoryItem["Item"])
                    slotStartX := this.Mem.ReadInt(invItemStructPtr + PoE2Offsets.InventoryItem["SlotStart"])
                    slotStartY := this.Mem.ReadInt(invItemStructPtr + PoE2Offsets.InventoryItem["SlotStartY"])
                    slotEndX := this.Mem.ReadInt(invItemStructPtr + PoE2Offsets.InventoryItem["SlotEnd"])
                    slotEndY := this.Mem.ReadInt(invItemStructPtr + PoE2Offsets.InventoryItem["SlotEndY"])
                    itemDetails := this.ReadFlaskItemDetails(itemEntityPtr, minimal)
                    isFlaskItem := this.IsLikelyFlaskItem(itemDetails)
                    flaskSlot := isFlaskItem ? this.GetFlaskSlotFromCoords(slotStartX, slotStartY) : 0
                    flaskStats := this.ReadFlaskStatsFromItemEntity(itemEntityPtr)

                    entries.Push(Map(
                        "inventoryItemStructPtr", invItemStructPtr,
                        "itemEntityPtr", itemEntityPtr,
                        "slotStartX", slotStartX,
                        "slotStartY", slotStartY,
                        "slotEndX", slotEndX,
                        "slotEndY", slotEndY,
                        "flaskSlot", flaskSlot,
                        "itemDetails", itemDetails,
                        "flaskStats", flaskStats
                    ))
                }
                idx += 1
            }
        }

        flaskSlots := this.BuildFlaskSlotSummary(entries)

        if (minimal)
        {
            return Map(
                "address", inventoryAddress,
                "entryCount", entryCount,
                "flaskSlots", flaskSlots
            )
        }

        return Map(
            "address", inventoryAddress,
            "totalBoxesX", totalBoxesX,
            "totalBoxesY", totalBoxesY,
            "entryCount", entryCount,
            "flaskSlots", flaskSlots
        )
    }

    ; Maps inventory grid coordinates to a flask slot number (1–5).
    ; Flask slots occupy row Y=0 at even columns X=0,2,4,6,8; returns 0 if coords don't match.
    GetFlaskSlotFromCoords(slotStartX, slotStartY)
    {
        if (slotStartY != 0)
            return 0

        if (slotStartX < 0 || slotStartX > 8)
            return 0

        if (Mod(slotStartX, 2) != 0)
            return 0

        slot := Floor(slotStartX / 2) + 1
        return (slot >= 1 && slot <= 5) ? slot : 0
    }

    ; Builds a Map(1..5 → entry) assigning life, mana, and charm items to their logical slots.
    ; Sorts candidates by grid coords; falls back to "other" items for empty life/mana/slot-5.
    BuildFlaskSlotSummary(entries)
    {
        slots := Map()
        loop 5
            slots[A_Index] := 0

        uniqueEntries := this.BuildUniqueInventoryEntries(entries)
        if (uniqueEntries.Length = 0)
            return slots

        lifeCandidates := []
        manaCandidates := []
        charmCandidates := []
        otherCandidates := []

        for entry in uniqueEntries
        {
            kind := this.GetFlaskInventoryItemKind(entry)
            switch kind
            {
                case "life":
                    lifeCandidates.Push(entry)
                case "mana":
                    manaCandidates.Push(entry)
                case "charm":
                    charmCandidates.Push(entry)
                default:
                    otherCandidates.Push(entry)
            }
        }

        this.SortEntriesByCoords(lifeCandidates)
        this.SortEntriesByCoords(manaCandidates)
        this.SortEntriesByCoords(charmCandidates)
        this.SortEntriesByCoords(otherCandidates)

        this.AssignFlaskSlot(slots, 1, lifeCandidates.Length ? lifeCandidates[1] : 0, "semantic")
        this.AssignFlaskSlot(slots, 2, manaCandidates.Length ? manaCandidates[1] : 0, "semantic")

        if (charmCandidates.Length >= 1)
            this.AssignFlaskSlot(slots, 3, charmCandidates[1], "semantic")
        if (charmCandidates.Length >= 2)
            this.AssignFlaskSlot(slots, 4, charmCandidates[2], "semantic")
        if (charmCandidates.Length >= 3)
            this.AssignFlaskSlot(slots, 5, charmCandidates[3], "semantic")

        ; Fallback for slot 5: use first "other" item if no 3rd charm
        if (!slots[5] && otherCandidates.Length >= 1)
            this.AssignFlaskSlot(slots, 5, otherCandidates[1], "semantic")

        ; Fallback: falls Life/Mana fehlen, versuche verbleibende Nicht-Charms in Slot 1/2
        if !slots[1] && otherCandidates.Length
            this.AssignFlaskSlot(slots, 1, otherCandidates[1], "semantic-fallback")
        if !slots[2] && otherCandidates.Length >= 2
            this.AssignFlaskSlot(slots, 2, otherCandidates[2], "semantic-fallback")

        return slots
    }

    ; Deduplicates inventory entries by item entity pointer, keeping the topmost-leftmost slot.
    ; Returns: array of unique entry Maps with no repeated itemEntityPtr values.
    BuildUniqueInventoryEntries(entries)
    {
        unique := []
        byEntity := Map()

        for entry in entries
        {
            if !entry || !entry.Has("itemEntityPtr")
                continue

            itemPtr := entry["itemEntityPtr"]
            if !this.IsProbablyValidPointer(itemPtr)
                continue

            if !byEntity.Has(itemPtr)
            {
                byEntity[itemPtr] := entry
                unique.Push(entry)
                continue
            }

            old := byEntity[itemPtr]
            oldY := old.Has("slotStartY") ? old["slotStartY"] : 99
            oldX := old.Has("slotStartX") ? old["slotStartX"] : 99
            newY := entry.Has("slotStartY") ? entry["slotStartY"] : 99
            newX := entry.Has("slotStartX") ? entry["slotStartX"] : 99

            better := (newY < oldY) || (newY = oldY && newX < oldX)
            if (better)
                byEntity[itemPtr] := entry
        }

        result := []
        for _, entry in byEntity
            result.Push(entry)

        return result
    }

    ; Classifies a flask inventory entry as "life", "mana", "charm", or "other" by metadata path.
    GetFlaskInventoryItemKind(entry)
    {
        details := entry.Has("itemDetails") ? entry["itemDetails"] : 0
        if !details || !details.Has("metadataPath")
            return "other"

        path := StrLower(details["metadataPath"])
        if InStr(path, "flasklife")
            return "life"
        if InStr(path, "flaskmana")
            return "mana"
        if InStr(path, "charm")
            return "charm"

        return "other"
    }

    ; Writes a flask entry into the given 1-based slot index of the slots Map.
    ; Params: sourceTag - diagnostic label ("semantic", "semantic-fallback", etc.).
    AssignFlaskSlot(slots, slot, entry, sourceTag)
    {
        if (slot < 1 || slot > 5 || !entry)
            return

        slots[slot] := Map(
            "itemEntityPtr", entry["itemEntityPtr"],
            "slotStartX", entry["slotStartX"],
            "slotStartY", entry["slotStartY"],
            "itemDetails", entry["itemDetails"],
            "flaskStats", entry["flaskStats"],
            "source", sourceTag
        )
    }

    ; Sorts an array of inventory entries in-place by (slotStartY, slotStartX) ascending.
    SortEntriesByCoords(arr)
    {
        if !arr || arr.Length < 2
            return

        i := 1
        while (i <= arr.Length)
        {
            j := i + 1
            while (j <= arr.Length)
            {
                yi := arr[i].Has("slotStartY") ? arr[i]["slotStartY"] : 99
                xi := arr[i].Has("slotStartX") ? arr[i]["slotStartX"] : 99
                yj := arr[j].Has("slotStartY") ? arr[j]["slotStartY"] : 99
                xj := arr[j].Has("slotStartX") ? arr[j]["slotStartX"] : 99

                if (yj < yi || (yj = yi && xj < xi))
                {
                    temp := arr[i]
                    arr[i] := arr[j]
                    arr[j] := temp
                }
                j += 1
            }
            i += 1
        }
    }

    ; Reads active flask slot data from the player's Buffs component.
    ; Returns: the flaskSlots map from ReadPlayerBuffsComponent, or 0 if unavailable.
    ReadFlaskSlotsFromBuffs(localPlayerPtr)
    {
        buffsComp := this.ReadPlayerBuffsComponent(localPlayerPtr)
        if (buffsComp && buffsComp.Has("flaskSlots"))
            return buffsComp["flaskSlots"]
        return 0
    }

    ; Merges buff-derived active flask state into the inventory-based flask slot map.
    ; Annotates existing slots with activeByBuff/buffInfo; creates stub entries for buff-only slots.
    MergeFlaskSlotsWithBuffs(flaskSlots, buffSlots)
    {
        if !flaskSlots || !buffSlots
            return

        loop 5
        {
            slot := A_Index
            if !buffSlots.Has(slot)
                continue

            buffInfo := buffSlots[slot]
            existing := flaskSlots[slot]

            if (existing)
            {
                existing["activeByBuff"] := true
                existing["buffInfo"] := buffInfo
                oldSource := existing.Has("source") ? existing["source"] : "coords"
                existing["source"] := (oldSource = "coords") ? "coords+buffs" : oldSource
            }
            else
            {
                flaskSlots[slot] := Map(
                    "itemEntityPtr", 0,
                    "slotStartX", -1,
                    "slotStartY", -1,
                    "itemDetails", 0,
                    "flaskStats", 0,
                    "activeByBuff", true,
                    "buffInfo", buffInfo,
                    "source", "buffs"
                )
            }
        }
    }

    ; Reads flask item details: metadata path, base type, rarity, display name, and mods.
    ; Params: minimal - if true returns only metadataPath and baseType (skips mod parsing).
    ReadFlaskItemDetails(itemEntityPtr, minimal := false)
    {
        if !this.IsProbablyValidPointer(itemEntityPtr)
            return 0

        entityDetailsPtr := this.Mem.ReadPtr(itemEntityPtr + PoE2Offsets.Entity["EntityDetailsPtr"])
        if !this.IsProbablyValidPointer(entityDetailsPtr)
            return 0

        metadataPath := this.ReadStdWStringAt(entityDetailsPtr + PoE2Offsets.EntityDetails["Path"])
        if (metadataPath = "")
            return 0

        baseType := this.ExtractFlaskBaseType(metadataPath)
        if (minimal)
        {
            return Map(
                "metadataPath", metadataPath,
                "baseType", baseType
            )
        }

        modsInfo := this.ReadItemModsAndMagicProperties(itemEntityPtr)
        rarityId := (modsInfo && modsInfo.Has("rarityId")) ? modsInfo["rarityId"] : -1
        displayName := this.ComposeItemDisplayName(metadataPath, baseType, modsInfo, rarityId)

        return Map(
            "metadataPath", metadataPath,
            "baseType", baseType,
            "displayName", displayName,
            "rarityId", rarityId,
            "rarity", this.RarityNameFromId(rarityId),
            "modsInfo", modsInfo
        )
    }

    ; Compose the full display name like "Potent Transcendent Life Flask of the Abundant"
    ; genType 1=Prefix, 2=Suffix. Prefix goes before baseType, suffix after.
    ; tierWord (from Words.datc64 via ModType) adds the tier qualifier after the prefix name.
    ComposeItemDisplayName(metadataPath, baseType, modsInfo, rarityId := -1)
    {
        ; Unique items: look up by metadata path → unique name
        if (rarityId = 3)
        {
            uniqueName := this.GetUniqueItemName(metadataPath)
            if (uniqueName != "")
                return uniqueName
        }

        ; Use base_item_name_map.tsv for the base name if available
        mappedBase := this.GetBaseItemName(metadataPath)
        displayBase := (mappedBase != "") ? mappedBase : baseType

        if (!modsInfo)
            return displayBase

        prefix := ""
        prefixTier := ""
        suffix := ""

        allMods := []
        for _, key in ["implicitMods", "explicitMods", "enchantMods"]
        {
            if modsInfo.Has(key)
            {
                for _, m in modsInfo[key]
                    allMods.Push(m)
            }
        }

        for _, m in allMods
        {
            genType := m.Has("genType") ? m["genType"] : 0
            affix   := m.Has("displayName") ? m["displayName"] : ""
            tier    := m.Has("tierWord") ? m["tierWord"] : ""
            if (genType = 1 && prefix = "")
            {
                prefix := affix
                prefixTier := tier
            }
            else if (genType = 2 && suffix = "")
                suffix := affix
        }

        name := displayBase
        prefixPart := prefix
        if (prefixTier != "" && prefix != "")
            prefixPart := prefix " " prefixTier
        else if (prefixTier != "" && prefix = "")
            prefixPart := prefixTier
        if (prefixPart != "")
            name := prefixPart " " name
        if (suffix != "")
            name := name " " suffix
        return name
    }

    ; Extracts a human-readable base type name from the last segment of a metadata path.
    ; Uses a hardcoded table for known tokens; falls back to camelCase/digit splitting for unknowns.
    ExtractFlaskBaseType(metadataPath)
    {
        parts := StrSplit(metadataPath, "/")
        if (parts.Length = 0)
            return metadataPath

        last := parts[parts.Length]
        if (last = "")
            return metadataPath

        token := StrLower(last)
        switch token
        {
            case "fourflasklife8":
                return "Life Flask"
            case "fourflaskmana9":
                return "Mana Flask"
            case "fourcharm7":
                return "Silver Charm"
            case "fourcharm6":
                return "Stone Charm"
        }

        readable := RegExReplace(last, "([a-z])([A-Z])", "$1 $2")
        readable := RegExReplace(readable, "([A-Za-z])(\d+)$", "$1 $2")
        readable := Trim(readable)
        return (readable != "") ? readable : last
    }

    ; Returns the rarity ID (0=Normal … 5=Currency) for an item entity, or -1 on failure.
    ReadItemRarity(itemEntityPtr)
    {
        info := this.ReadItemModsAndMagicProperties(itemEntityPtr)
        if (info && info.Has("rarityId"))
            return info["rarityId"]
        return -1
    }

    ; Scans an item's component vector for ObjectMagicProperties or Mods to find the best mods block.
    ; Selects the highest-scoring candidate (score = rarity * 10 + total mod count).
    ; Returns: Map from ReadItemModsDetails, or 0 if no valid mods component is found.
    ReadItemModsAndMagicProperties(itemEntityPtr)
    {
        if !this.IsProbablyValidPointer(itemEntityPtr)
            return 0

        componentsVecFirst := this.Mem.ReadInt64(itemEntityPtr + PoE2Offsets.Entity["ComponentsVec"])
        componentsVecLast := this.Mem.ReadInt64(itemEntityPtr + PoE2Offsets.Entity["ComponentsVecLast"])
        if (componentsVecFirst <= 0 || componentsVecLast < componentsVecFirst)
            return 0

        ptrSize := A_PtrSize
        componentCount := Floor((componentsVecLast - componentsVecFirst) / ptrSize)
        maxEntries := Min(componentCount, 64)

        bestCandidate := 0
        bestScore := -1

        idx := 0
        while (idx < maxEntries)
        {
            componentPtr := this.Mem.ReadPtr(componentsVecFirst + (idx * ptrSize))
            if this.IsProbablyValidPointer(componentPtr)
            {
                ownerEntityPtr := this.Mem.ReadPtr(componentPtr + PoE2Offsets.ComponentHeader["EntityPtr"])
                if (ownerEntityPtr = itemEntityPtr)
                {
                    ; Try ObjectMagicProperties first (used by flasks and magic/rare/unique items)
                    ; Score = rarity (higher is more specific) + bonus for non-empty mods
                    rarityOMP := this.Mem.ReadInt(componentPtr + PoE2Offsets.ObjectMagicProperties["Rarity"])
                    if (rarityOMP >= 0 && rarityOMP <= 5)
                    {
                        score := this.ScoreModsCandidate(componentPtr + PoE2Offsets.ObjectMagicProperties["AllMods"], rarityOMP)
                        if (score > bestScore)
                        {
                            bestScore := score
                            bestCandidate := Map("componentPtr", componentPtr, "allModsOffset", PoE2Offsets.ObjectMagicProperties["AllMods"], "rarityId", rarityOMP, "sourceType", "ObjectMagicProperties")
                        }
                    }

                    ; Try Mods (used by regular non-flask equipment)
                    rarityMods := this.Mem.ReadInt(componentPtr + PoE2Offsets.Mods["Rarity"])
                    if (rarityMods >= 0 && rarityMods <= 5)
                    {
                        score := this.ScoreModsCandidate(componentPtr + PoE2Offsets.Mods["AllMods"], rarityMods)
                        if (score > bestScore)
                        {
                            bestScore := score
                            bestCandidate := Map("componentPtr", componentPtr, "allModsOffset", PoE2Offsets.Mods["AllMods"], "rarityId", rarityMods, "sourceType", "Mods")
                        }
                    }
                }
            }
            idx += 1
        }

        if (bestScore >= 0 && bestCandidate != 0)
            return this.ReadItemModsDetails(bestCandidate["componentPtr"], bestCandidate["allModsOffset"], bestCandidate["rarityId"], bestCandidate["sourceType"])

        return 0
    }

    ; Returns a score for how likely this is a valid mods block. Higher = more confident.
    ; Score formula: rarity * 10 + total mod count across all 5 vectors
    ScoreModsCandidate(allModsBase, rarityId)
    {
        totalMods := 0
        hasInvalidVectors := false
        vecIdx := 0
        while (vecIdx < 5)
        {
            vecAddr := allModsBase + (vecIdx * 0x18)
            first := this.Mem.ReadInt64(vecAddr)
            last  := this.Mem.ReadInt64(vecAddr + 0x08)
            if (first = 0 && last = 0)
            {
                vecIdx += 1
                continue
            }
            if (!this.IsProbablyValidPointer(first) || last < first)
            {
                hasInvalidVectors := true
                break
            }
            count := Floor((last - first) / 0x40)
            if (count < 0 || count > 512)
            {
                hasInvalidVectors := true
                break
            }
            totalMods += count
            vecIdx += 1
        }
        if (hasInvalidVectors)
            return -1
        return rarityId * 10 + totalMods
    }

    ; Reads all 5 mod vectors (implicit, explicit, enchant, hellscape, crucible) from a component.
    ; Returns: Map with per-category arrays, counts, rarityId, rarity string, and merged allModNames.
    ReadItemModsDetails(componentPtr, allModsBaseOffset, rarityId, sourceType)
    {
        implicitMods := this.ReadModArrayFromVector(componentPtr + allModsBaseOffset + (0x18 * 0))
        explicitMods := this.ReadModArrayFromVector(componentPtr + allModsBaseOffset + (0x18 * 1))
        enchantMods := this.ReadModArrayFromVector(componentPtr + allModsBaseOffset + (0x18 * 2))
        hellscapeMods := this.ReadModArrayFromVector(componentPtr + allModsBaseOffset + (0x18 * 3))
        crucibleMods := this.ReadModArrayFromVector(componentPtr + allModsBaseOffset + (0x18 * 4))

        allNames := []
        this.AppendDistinctModNames(allNames, implicitMods)
        this.AppendDistinctModNames(allNames, explicitMods)
        this.AppendDistinctModNames(allNames, enchantMods)
        this.AppendDistinctModNames(allNames, hellscapeMods)
        this.AppendDistinctModNames(allNames, crucibleMods)

        return Map(
            "sourceType", sourceType,
            "rarityId", rarityId,
            "rarity", this.RarityNameFromId(rarityId),
            "implicitMods", implicitMods,
            "explicitMods", explicitMods,
            "enchantMods", enchantMods,
            "hellscapeMods", hellscapeMods,
            "crucibleMods", crucibleMods,
            "implicitCount", implicitMods.Length,
            "explicitCount", explicitMods.Length,
            "enchantCount", enchantMods.Length,
            "hellscapeCount", hellscapeMods.Length,
            "crucibleCount", crucibleMods.Length,
            "allModNames", allNames
        )
    }

    ; Reads a std::vector of mod entries and returns an array of mod Maps (name, value, genType, tierWord).
    ; Params: maxEntries - cap on entries read to guard against corrupt/runaway vectors.
    ReadModArrayFromVector(stdVectorAddress, maxEntries := 32)
    {
        out := []
        if !this.IsProbablyValidPointer(stdVectorAddress)
            return out

        first := this.Mem.ReadInt64(stdVectorAddress + PoE2Offsets.StdVector["First"])
        last := this.Mem.ReadInt64(stdVectorAddress + PoE2Offsets.StdVector["Last"])
        if (first <= 0 || last < first)
            return out

        entrySize := 0x40
        totalBytes := last - first
        count := Floor(totalBytes / entrySize)
        if (count <= 0)
            return out

        readCount := Min(count, maxEntries)
        idx := 0
        while (idx < readCount)
        {
            entryAddr := first + (idx * entrySize)
            value0 := this.Mem.ReadInt(entryAddr + PoE2Offsets.ModArray["Value0"])
            modRowPtr := this.Mem.ReadPtr(entryAddr + PoE2Offsets.ModArray["ModsPtr"])
            valuesCount := this.ReadStdVectorCount(entryAddr + PoE2Offsets.ModArray["Values"], 0x04, 16)

            value1 := ""
            if (valuesCount >= 1)
                value0 := this.Mem.ReadInt(this.Mem.ReadInt64(entryAddr + PoE2Offsets.ModArray["Values"]) + PoE2Offsets.StatPair["Key"])
            if (valuesCount >= 2)
                value1 := this.Mem.ReadInt(this.Mem.ReadInt64(entryAddr + PoE2Offsets.ModArray["Values"]) + PoE2Offsets.StatPair["Value"])

            modName := this.ReadModName(modRowPtr)
            if (modName != "")
            {
                modInfo := this.GetModDisplayInfo(modName)
                out.Push(Map(
                    "name", modName,
                    "displayName", modInfo["affix"],
                    "genType", modInfo["genType"],
                    "tierWord", modInfo["tierWord"],
                    "value0", value0,
                    "value1", value1,
                    "valuesCount", valuesCount,
                    "modRowPtr", modRowPtr
                ))
            }

            idx += 1
        }

        return out
    }

    ; Reads the mod ID string from a dat-file mod row pointer.
    ; Returns: the mod name string, or "" on invalid pointer or implausible length (>256).
    ReadModName(modRowPtr)
    {
        if !this.IsProbablyValidPointer(modRowPtr)
            return ""

        namePtr := this.Mem.ReadPtr(modRowPtr + PoE2Offsets.BuffDefinition["Name"])
        if !this.IsProbablyValidPointer(namePtr)
            return ""

        name := this.Mem.ReadUnicodeString(namePtr)
        if (StrLen(name) <= 0 || StrLen(name) > 256)
            return ""

        return name
    }

    ; Loads the mod name lookup table from a TSV file into this.ModNameMap.
    ; TSV columns: modId, affixName, genType (1=prefix / 2=suffix), tierWord.
    LoadModNameMap(tsvPath)
    {
        if !FileExist(tsvPath)
            return
        try {
            f := FileOpen(tsvPath, "r", "UTF-8")
            if !f
                return
            while !f.AtEOF
            {
                line := f.ReadLine()
                line := RTrim(line, "`r`n")
                if (SubStr(line, 1, 1) = "#" || line = "")
                    continue
                parts := StrSplit(line, "`t")
                if (parts.Length < 2)
                    continue
                modId      := parts[1]
                affix      := parts[2]
                genType    := (parts.Length >= 3) ? Integer(parts[3]) : 0
                tierWord   := (parts.Length >= 4) ? parts[4] : ""
                this.ModNameMap[modId] := Map("affix", affix, "genType", genType, "tierWord", tierWord)
            }
            f.Close()
        }
        catch as err {
        }
    }

    ; Loads the base item name lookup table from a TSV file (metadataPath → display name).
    LoadBaseItemNameMap(tsvPath)
    {
        if !FileExist(tsvPath)
            return
        try {
            f := FileOpen(tsvPath, "r", "UTF-8")
            if !f
                return
            while !f.AtEOF
            {
                line := f.ReadLine()
                line := RTrim(line, "`r`n")
                if (SubStr(line, 1, 1) = "#" || line = "")
                    continue
                parts := StrSplit(line, "`t")
                if (parts.Length < 2)
                    continue
                this.BaseItemNameMap[parts[1]] := parts[2]
            }
            f.Close()
        }
        catch as err {
        }
    }

    ; Looks up affix display name, genType, and tierWord for a mod ID; returns empty defaults if absent.
    GetModDisplayInfo(modId)
    {
        if this.ModNameMap.Has(modId)
            return this.ModNameMap[modId]
        return Map("affix", "", "genType", 0, "tierWord", "")
    }

    ; Returns the mapped base item display name for a metadata path, or "" if not in the map.
    GetBaseItemName(metadataPath)
    {
        if this.BaseItemNameMap.Has(metadataPath)
            return this.BaseItemNameMap[metadataPath]
        return ""
    }

    ; Loads the unique item name lookup table from a TSV file (metadataPath → unique name).
    LoadUniqueItemNameMap(tsvPath)
    {
        if !FileExist(tsvPath)
            return
        try {
            f := FileOpen(tsvPath, "r", "UTF-8")
            if !f
                return
            while !f.AtEOF
            {
                line := f.ReadLine()
                line := RTrim(line, "`r`n")
                if (SubStr(line, 1, 1) = "#" || line = "")
                    continue
                parts := StrSplit(line, "`t")
                if (parts.Length < 2)
                    continue
                this.UniqueItemNameMap[parts[1]] := parts[2]
            }
            f.Close()
        }
        catch as err {
        }
    }

    ; Returns the unique item display name for a metadata path, or "" if not in the map.
    GetUniqueItemName(metadataPath)
    {
        if this.UniqueItemNameMap.Has(metadataPath)
            return this.UniqueItemNameMap[metadataPath]
        return ""
    }

    ; Appends unique mod name strings from modsArray into outNames, skipping duplicates.
    AppendDistinctModNames(outNames, modsArray)
    {
        for _, mod in modsArray
        {
            if (!mod || !mod.Has("name"))
                continue

            name := mod["name"]
            if (name = "")
                continue

            seen := false
            for _, existing in outNames
            {
                if (existing = name)
                {
                    seen := true
                    break
                }
            }

            if !seen
                outNames.Push(name)
        }
    }

    ; Returns true if the item's metadata path contains "/flasks/", indicating it is a flask.
    IsLikelyFlaskItem(itemDetails)
    {
        if !itemDetails
            return false

        if !itemDetails.Has("metadataPath")
            return false

        path := StrLower(itemDetails["metadataPath"])
        return InStr(path, "/flasks/") > 0
    }

    ; Converts a numeric rarity ID to its label string (Normal/Magic/Rare/Unique/Relic/Currency).
    RarityNameFromId(rarityId)
    {
        switch rarityId
        {
            case 0:
                return "Normal"
            case 1:
                return "Magic"
            case 2:
                return "Rare"
            case 3:
                return "Unique"
            case 4:
                return "Relic"
            case 5:
                return "Currency"
            default:
                return "Unknown"
        }
    }

    ; Scans an item entity's component vector for the Charges component and reads current/perUse values.
    ; Caches the component's StaticPtr after first discovery for faster matching on subsequent calls.
    ; Returns: Map with chargesComponentPtr, current, perUse, remainingUses; or 0 if not found.
    ReadFlaskStatsFromItemEntity(itemEntityPtr)
    {
        if !this.IsProbablyValidPointer(itemEntityPtr)
            return 0

        ; Item entities lack a named component lookup table, so we must scan the raw vec.
        ; We identify the Charges component by matching its StaticPtr (a per-type constant
        ; populated by DecodeChargesComponentBasic the first time a player/world Charges
        ; component is decoded via the named lookup).
        compVecFirst := this.Mem.ReadInt64(itemEntityPtr + PoE2Offsets.Entity["ComponentsVec"])
        compVecLast  := this.Mem.ReadInt64(itemEntityPtr + PoE2Offsets.Entity["ComponentsVecLast"])
        if (compVecFirst <= 0 || compVecLast < compVecFirst)
            return 0

        componentCount := Min(Floor((compVecLast - compVecFirst) / A_PtrSize), 64)
        knownStaticPtr := this._chargesStaticPtr

        ; Two-pass approach: first try exact StaticPtr match, then brute-force
        passes := knownStaticPtr ? [true, false] : [false]
        for _, useExactMatch in passes
        {
            idx := 0
            while (idx < componentCount)
            {
                cPtr := this.Mem.ReadPtr(compVecFirst + (idx * A_PtrSize))
                if this.IsProbablyValidPointer(cPtr)
                {
                    ownerPtr := this.Mem.ReadPtr(cPtr + PoE2Offsets.ComponentHeader["EntityPtr"])
                    if (ownerPtr = itemEntityPtr)
                    {
                        if (useExactMatch)
                        {
                            staticPtr := this.Mem.ReadPtr(cPtr + PoE2Offsets.ComponentHeader["StaticPtr"])
                            if (staticPtr != knownStaticPtr)
                            {
                                idx += 1
                                continue
                            }
                        }

                        ; Decode as Charges
                        current := this.Mem.ReadInt(cPtr + PoE2Offsets.Charges["Current"])
                        chargesInternalPtr := this.Mem.ReadPtr(cPtr + PoE2Offsets.Charges["ChargesInternalPtr"])
                        perUse := 0
                        if this.IsProbablyValidPointer(chargesInternalPtr)
                            perUse := this.Mem.ReadInt(chargesInternalPtr + PoE2Offsets.ChargesInternal["PerUseCharges"])

                        if (current >= 0 && current <= 1000 && perUse >= 0 && perUse <= 1000
                            && (current > 0 || perUse > 0))
                        {
                            ; Cache/update StaticPtr for future scans
                            sp := this.Mem.ReadPtr(cPtr + PoE2Offsets.ComponentHeader["StaticPtr"])
                            if this.IsProbablyValidPointer(sp)
                                this._chargesStaticPtr := sp
                            remainingUses := (perUse > 0) ? Floor(current / perUse) : 0
                            return Map(
                                "chargesComponentPtr", cPtr,
                                "current", current,
                                "perUse", perUse,
                                "remainingUses", remainingUses
                            )
                        }
                    }
                }
                idx += 1
            }
        }

        return 0
    }

}
