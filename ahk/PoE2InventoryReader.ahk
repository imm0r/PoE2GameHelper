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

    ; Enumerates every PlayerInventories entry and returns the full item list for each.
    ; Re-uses ReadInventoryBasic and its existing item-detail decoder — extracts the
    ; entries array (which ReadServerData discards) so the UI can render grids.
    ;
    ; Returns: Array of Maps, each with:
    ;   inventoryId  — game-internal ID (1=Backpack, 12=Flasks, etc.); used by UI to label
    ;   inventoryType — resolved type from Inventories.datc64 (e.g. "Flask1"), "" if unknown
    ;   address       — inventory struct pointer (diagnostic)
    ;   totalBoxesX/Y — grid dimensions
    ;   items         — Array of item Maps (slotStart/End, displayName, rarity, mods, …)
    ;
    ; Skips empty inventories. Caller decides if and how to label by inventoryId.
    ReadAllPlayerInventories(serverDataAddress)
    {
        result := []
        if !this.IsProbablyValidPointer(serverDataAddress)
            return result

        playerDataVecFirst := this.Mem.ReadInt64(serverDataAddress + PoE2Offsets.ServerData["PlayerServerData"])
        if (playerDataVecFirst <= 0)
            return result
        playerDataPtr := this.Mem.ReadPtr(playerDataVecFirst)
        if !this.IsProbablyValidPointer(playerDataPtr)
            return result

        invVecFirst := this.Mem.ReadInt64(playerDataPtr + PoE2Offsets.ServerDataStructure["PlayerInventories"])
        invVecLast  := this.Mem.ReadInt64(playerDataPtr + PoE2Offsets.ServerDataStructure["PlayerInventoriesLast"])
        if (invVecFirst <= 0 || invVecLast < invVecFirst)
            return result

        entrySize := PoE2Offsets.InventoryArray["EntrySize"]
        count     := Min(Floor((invVecLast - invVecFirst) / entrySize), 128)

        idx := 0
        while (idx < count)
        {
            entryAddr := invVecFirst + (idx * entrySize)
            invId  := this.Mem.ReadInt(entryAddr + PoE2Offsets.InventoryArray["InventoryId"])
            invPtr := this.Mem.ReadPtr(entryAddr + PoE2Offsets.InventoryArray["InventoryPtr0"])
            idx += 1

            if !this.IsProbablyValidPointer(invPtr)
                continue

            inv := this._ReadInventoryWithItems(invPtr)
            if !inv
                continue
            inv["inventoryId"] := invId
            inv["inventoryType"] := this.GetInventoryType(invId)
            result.Push(inv)
        }

        ; ── Resolve user-given stash tab names ─────────────────────────────
        ; PoE2 exposes every stash tab as a separate inventory in PlayerInventories
        ; (IDs outside 1, 2-11, 12). The corresponding tab names live in a separate
        ; std::vector<ServerStashTab> inside ServerDataStructure. We don't know the
        ; exact offset for PoE2, so ReadStashTabNames scans for any 0x40-stride
        ; vector whose entries pass the NativeStringU "Name" validity check.
        ;
        ; Correlation: assume the i-th stash inventory (by enumeration order in
        ; PlayerInventories, filtered to non-player IDs) matches the i-th tab name.
        ; This is the same assumption upstream tooling uses; works in practice when
        ; both vectors are populated in DisplayIndex order.
        stashIdx := []
        i := 1
        for entry in result
        {
            id := entry["inventoryId"]
            isPlayer := (id = 1 || id = 12 || (id >= 2 && id <= 11))
            if !isPlayer
                stashIdx.Push(i)
            i += 1
        }
        if (stashIdx.Length > 0)
        {
            try names := this.ReadStashTabNames(playerDataPtr, 1, stashIdx.Length)
            catch
                names := []
            ; Apply names by position. When the tab-name vector is shorter than
            ; the stash-inventory list (or vice versa), unmatched tabs are left
            ; nameless and the UI falls back to "Stash Tab #<id>".
            nameIdx := 1
            for _, resultPos in stashIdx
            {
                if (nameIdx > names.Length)
                    break
                tabName := names[nameIdx]
                if (tabName != "")
                    result[resultPos]["tabName"] := tabName
                nameIdx += 1
            }
        }

        return result
    }

    ; Reads one inventory and returns its full item entries (vs. ReadInventoryBasic
    ; which discards them and only returns the flask-slot summary).
    ; Internal helper used by ReadAllPlayerInventories + ReadStashInventories.
    _ReadInventoryWithItems(inventoryAddress)
    {
        if !this.IsProbablyValidPointer(inventoryAddress)
            return 0

        totalBoxesX := this.Mem.ReadInt(inventoryAddress + PoE2Offsets.Inventory["TotalBoxes"])
        totalBoxesY := this.Mem.ReadInt(inventoryAddress + PoE2Offsets.Inventory["TotalBoxesY"])

        itemListFirst := this.Mem.ReadInt64(inventoryAddress + PoE2Offsets.Inventory["ItemList"])
        itemListLast  := this.Mem.ReadInt64(inventoryAddress + PoE2Offsets.Inventory["ItemListLast"])

        ; Plausibility filter — skip pointers that look nothing like an inventory struct.
        ; Used by the stash heuristic scanner to reject false positives.
        if (totalBoxesX < 1 || totalBoxesX > 64 || totalBoxesY < 1 || totalBoxesY > 64)
            return 0
        if (itemListFirst <= 0 || itemListLast < itemListFirst)
            return 0
        totalBytes := itemListLast - itemListFirst
        if (Mod(totalBytes, A_PtrSize) != 0)
            return 0
        entryCount := Floor(totalBytes / A_PtrSize)
        if (entryCount < 0 || entryCount > 1024)
            return 0

        items := []
        maxEntries := Min(entryCount, 256)
        idx := 0
        while (idx < maxEntries)
        {
            invItemStructPtr := this.Mem.ReadPtr(itemListFirst + (idx * A_PtrSize))
            idx += 1
            if !this.IsProbablyValidPointer(invItemStructPtr)
                continue

            itemEntityPtr := this.Mem.ReadPtr(invItemStructPtr + PoE2Offsets.InventoryItem["Item"])
            slotStartX := this.Mem.ReadInt(invItemStructPtr + PoE2Offsets.InventoryItem["SlotStart"])
            slotStartY := this.Mem.ReadInt(invItemStructPtr + PoE2Offsets.InventoryItem["SlotStartY"])
            slotEndX   := this.Mem.ReadInt(invItemStructPtr + PoE2Offsets.InventoryItem["SlotEnd"])
            slotEndY   := this.Mem.ReadInt(invItemStructPtr + PoE2Offsets.InventoryItem["SlotEndY"])

            itemDetails := this.ReadFlaskItemDetails(itemEntityPtr, false)
            if !itemDetails
                continue

            items.Push(Map(
                "itemEntityPtr", itemEntityPtr,
                "slotStartX", slotStartX,
                "slotStartY", slotStartY,
                "slotEndX",   slotEndX,
                "slotEndY",   slotEndY,
                "details",    itemDetails
            ))
        }

        return Map(
            "address",     inventoryAddress,
            "totalBoxesX", totalBoxesX,
            "totalBoxesY", totalBoxesY,
            "entryCount",  entryCount,
            "items",       items
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

        ; Fallback: if Life/Mana are missing, try remaining non-charms in slot 1/2
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
        displayName := this.ComposeItemDisplayName(metadataPath, baseType, modsInfo, rarityId, itemEntityPtr)

        ; Stack count (for stackable items like scrolls, currency, gold).
        ; Reads the Stack component's Count field when present; non-stackable
        ; items don't have this component and report 0 (UI hides the badge).
        ; Max stack size isn't on the Stack component — it lives on BaseItemTypes.dat
        ; which isn't schema-mapped yet, so we show only the current count for now.
        stackCount := 0
        try
        {
            stackPtr := this.FindEntityComponentAddress(itemEntityPtr, "Stack")
            if this.IsProbablyValidPointer(stackPtr)
                stackCount := this.Mem.ReadInt(stackPtr + PoE2Offsets.Stack["Count"])
        }
        catch
            stackCount := 0

        return Map(
            "metadataPath", metadataPath,
            "baseType", baseType,
            "displayName", displayName,
            "rarityId", rarityId,
            "rarity", this.RarityNameFromId(rarityId),
            "stackCount", stackCount,
            "modsInfo", modsInfo
        )
    }

    ; Compose the full display name like "Potent Transcendent Life Flask of the Abundant"
    ; genType 1=Prefix, 2=Suffix. Prefix goes before baseType, suffix after.
    ; Note: mod_name_map's `modFamily` column (e.g. "IncreasedLife") is the
    ; game's internal exclusion-group label, NOT the tier-adjective shown in
    ; the in-game item name — so we do NOT splice it into the display name
    ; (doing so produced names like "Blessed IncreasedLife Cuffs of the …").
    ; The real tier adjective lives in stat-description data we don't extract
    ; yet; until that lands the composed name simply drops the tier slot.
    ComposeItemDisplayName(metadataPath, baseType, modsInfo, rarityId := -1, itemEntityPtr := 0)
    {
        ; Unique items: resolve the name via the item's ItemVisualIdentity Id
        ; (robust — distinguishes uniques that share a base, e.g. Morior Invictus
        ; vs Tabula Rasa on FourBodyStrDexInt1). Fall back to the metadata-path map
        ; only when the IVI read / lookup fails.
        if (rarityId = 3)
        {
            iviId := this.ReadUniqueIviId(itemEntityPtr)
            if (iviId != "")
            {
                uniqueByIvi := this.GetUniqueNameByIvi(iviId)
                if (uniqueByIvi != "")
                    return uniqueByIvi
            }
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
            if (genType = 1 && prefix = "")
                prefix := affix
            else if (genType = 2 && suffix = "")
                suffix := affix
        }

        name := displayBase
        if (prefix != "")
            name := prefix " " name
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
                            bestCandidate := Map(
                                "componentPtr",         componentPtr,
                                "allModsOffset",        PoE2Offsets.ObjectMagicProperties["AllMods"],
                                "statsFromModsOffset", PoE2Offsets.ObjectMagicProperties["StatsFromMods"],
                                "rarityId",             rarityOMP,
                                "sourceType",           "ObjectMagicProperties")
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
                            bestCandidate := Map(
                                "componentPtr",         componentPtr,
                                "allModsOffset",        PoE2Offsets.Mods["AllMods"],
                                "statsFromModsOffset", PoE2Offsets.Mods["StatsFromMods"],
                                "rarityId",             rarityMods,
                                "sourceType",           "Mods")
                        }
                    }
                }
            }
            idx += 1
        }

        if (bestScore >= 0 && bestCandidate != 0)
            return this.ReadItemModsDetails(
                bestCandidate["componentPtr"],
                bestCandidate["allModsOffset"],
                bestCandidate["rarityId"],
                bestCandidate["sourceType"],
                bestCandidate["statsFromModsOffset"])

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
    ; Also reads the aggregated StatsFromMods (statId, statValue) list — the item-level
    ; flat stat array that drives templated tooltip rendering ("+38 to Spirit" etc).
    ; Returns: Map with per-category arrays, counts, rarityId, rarity string, merged
    ; allModNames, and statsFromMods.
    ReadItemModsDetails(componentPtr, allModsBaseOffset, rarityId, sourceType, statsFromModsOffset := 0)
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

        statsFromMods := []
        if (statsFromModsOffset > 0)
            statsFromMods := this.ReadItemStatsFromMods(componentPtr + statsFromModsOffset)

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
            "allModNames", allNames,
            "statsFromMods", statsFromMods
        )
    }

    ; ── Stash tab name discovery ─────────────────────────────────────────────
    ; Reads an MSVC std::wstring (the "NativeStringU" struct from ExileApi).
    ; Layout (32 bytes):
    ;   +0x00  buf       — first 8 bytes of SSO buffer OR heap pointer to wide chars
    ;   +0x08  buf2      — next 8 bytes of SSO buffer (unused when heap)
    ;   +0x10  size      — uint, wide-char length (excl. null)
    ;   +0x18  capacity  — uint, wide-char capacity
    ;
    ; MSVC SSO threshold: capacity <= 7 -> inline buffer (16 bytes UTF-16 fits 8 chars
    ; counting null); capacity > 7 -> buf is the heap pointer. ExileApi has this
    ; backwards in comments but the threshold above matches actual MSVC behaviour.
    ;
    ; Returns: the decoded string, "" on any read failure or obviously invalid struct.
    _ReadNativeStringU(addr)
    {
        if !this.IsProbablyValidPointer(addr)
            return ""
        buf := this.Mem.ReadBytes(addr, 0x20)
        if !buf
            return ""

        size     := NumGet(buf.Ptr, 0x10, "UInt")
        capacity := NumGet(buf.Ptr, 0x18, "UInt")
        if (size = 0 || size > 256 || capacity < size)
            return ""

        raw := ""
        if (capacity <= 7)
        {
            ; SSO: inline 16-byte buffer (8 wide chars including the null terminator).
            raw := StrGet(buf.Ptr, size, "UTF-16")
        }
        else
        {
            ; Heap path: dereference buf as a wide-char pointer.
            heapPtr := NumGet(buf.Ptr, 0x00, "Ptr")
            if !this.IsProbablyValidPointer(heapPtr)
                return ""
            strBuf := this.Mem.ReadBytes(heapPtr, (size + 1) * 2)
            if !strBuf
                return ""
            raw := StrGet(strBuf.Ptr, size, "UTF-16")
        }

        ; Validate: reject anything that contains NUL or control chars. A real
        ; user-given tab name is printable text. Garbage memory matching the
        ; (size, capacity) numeric bounds by chance almost always carries a
        ; non-printable byte somewhere — this filter cuts those out cleanly.
        nulPos := InStr(raw, Chr(0))
        if (nulPos > 0)
            raw := SubStr(raw, 1, nulPos - 1)
        if (raw = "")
            return ""
        loop StrLen(raw)
        {
            c := Ord(SubStr(raw, A_Index, 1))
            if (c < 0x20)   ; any control char (including NUL we already stripped)
                return ""
        }
        return raw
    }

    ; Heuristically locates the std::vector<ServerStashTab> inside ServerDataStructure
    ; and returns the tab names in their natural order.
    ;
    ; Intra-entry layout (MSVC-stable across versions):
    ;   Name (NativeStringU) at +0x08 within each entry.
    ; Variable across versions:
    ;   Outer vector position in ServerDataStructure (PoE1: 0x1CB0; PoE2: unknown)
    ;   Entry stride (PoE1: 0x40; PoE2: possibly different due to added fields)
    ;
    ; Strategy: scan a wide window from playerDataPtr looking for NativePtrArray
    ; triples (First, Last, End) whose entry count is plausible AND where at
    ; least one entry's Name field reads as a valid wstring. Try several strides;
    ; pick the candidate that resolves the most names.
    ;
    ; Params: playerDataPtr - the dereferenced ServerData[PlayerServerData] pointer
    ;         minTabs       - minimum non-empty name count required
    ; Returns: Array of name strings (positionally aligned with that vector's entries).
    ReadStashTabNames(playerDataPtr, minTabs := 1, expectedCount := 0)
    {
        result := []
        if !this.IsProbablyValidPointer(playerDataPtr)
            return result

        ; ── Per-session cache ──────────────────────────────────────────────
        ; Reuse the last good (offset, stride) for this ServerData pointer,
        ; revalidated each call. Avoids re-scanning 96 KB on every inventory
        ; read and keeps results stable. Auto-invalidated when revalidation
        ; fails (zone / character change relocates the struct).
        if !this.HasOwnProp("_stashVecCache")
            this._stashVecCache := Map()
        if this._stashVecCache.Has(playerDataPtr)
        {
            c := this._stashVecCache[playerDataPtr]
            cachedNames := this._ReadStashVecAt(playerDataPtr + c["off"], c["stride"])
            if (this._StashNonEmptyCount(cachedNames) >= minTabs)
                return cachedNames
            this._stashVecCache.Delete(playerDataPtr)   ; stale → rescan below
        }

        ; Wide scan window — 96 KB. PoE2 has more inventory metadata than PoE1
        ; (we see 100+ inventory entries), so the stash-tab vector may have
        ; shifted far below PoE1's 0x1CB0 offset.
        scanSize := 0x18000
        buf := this.Mem.ReadBytes(playerDataPtr, scanSize)
        if !buf
            return result

        ; Strides to probe. 0x40 is the PoE1 ServerStashTab size; 0x48 / 0x50 /
        ; 0x60 cover plausible PoE2 expansions with extra fields.
        strides := [0x40, 0x48, 0x50, 0x60]
        best := 0   ; Map("names","off","stride","count","nonEmpty","score") | 0

        for _, stride in strides
        {
            off := 0
            while (off <= scanSize - 24)
            {
                first := NumGet(buf.Ptr, off,      "Int64")
                last  := NumGet(buf.Ptr, off + 8,  "Int64")
                end   := NumGet(buf.Ptr, off + 16, "Int64")
                thisOff := off
                off += 8   ; pointer-aligned step

                if !this.IsProbablyValidPointer(first)
                    continue
                ; StdVector triple sanity: last>first, end>=last, and BOTH the
                ; used span and the capacity are stride-aligned with capacity
                ; >= span. The capacity check rejects most coincidental triples.
                if (last <= first || end < last)
                    continue
                span := last - first
                cap  := end - first
                if (span <= 0 || Mod(span, stride) != 0 || Mod(cap, stride) != 0 || cap < span)
                    continue
                count := span // stride
                if (count < Max(minTabs, 1) || count > 200)
                    continue

                ; Probe the first few entries before reading all. Special/system
                ; tabs sometimes lead with an empty slot before user-named tabs.
                probeOk := false
                probeI := 0
                while (probeI < Min(3, count))
                {
                    if (this._ReadNativeStringU(first + (probeI * stride) + 0x08) != "")
                    {
                        probeOk := true
                        break
                    }
                    probeI += 1
                }
                if !probeOk
                    continue

                names := this._ReadStashVecEntries(first, stride, count)
                nonEmpty := this._StashNonEmptyCount(names)
                if (nonEmpty < minTabs)
                    continue
                ; Reject a vector dominated by a single repeated string (garbage
                ; that happens to read as the same text) once it's non-trivial.
                if (count > 2 && this._StashDistinctCount(names) < 2)
                    continue

                ; Score: a vector that has at least one named entry per loaded
                ; stash tab (expectedCount) is almost certainly the real one, so
                ; it gets a large bonus; otherwise rank by non-empty names. Ties
                ; keep the lowest offset (we iterate ascending with strict >).
                score := nonEmpty
                if (expectedCount > 0 && count >= expectedCount && nonEmpty >= expectedCount)
                    score += 10000
                if (!best || score > best["score"])
                {
                    best := Map("names", names, "off", thisOff, "stride", stride,
                        "count", count, "nonEmpty", nonEmpty, "score", score)
                }
            }
        }

        if !best
            return result

        ; Cache the winner for this ServerData pointer + log a diagnostic so a
        ; future in-game run still reveals the real offset for a deterministic
        ; hardcode later.
        this._stashVecCache[playerDataPtr] := Map("off", best["off"], "stride", best["stride"])
        try {
            sample := ""
            sIdx := 1
            while (sIdx <= Min(5, best["names"].Length))
            {
                sample .= (sIdx > 1 ? "," : "") best["names"][sIdx]
                sIdx += 1
            }
            countMatch := (expectedCount > 0 && best["count"] >= expectedCount && best["nonEmpty"] >= expectedCount) ? 1 : 0
            LogError("StashTabScan stride=" Format("0x{:X}", best["stride"])
                . " ofs=" Format("0x{:X}", best["off"])
                . " count=" best["count"]
                . " nonEmpty=" best["nonEmpty"]
                . " expected=" expectedCount
                . " countMatch=" countMatch
                . " sample=[" sample "]")
        }
        return best["names"]
    }

    ; Reads <count> tab names (NativeStringU at entry+0x08) from a stash-tab
    ; vector whose first entry is at <first>, stepping by <stride>.
    _ReadStashVecEntries(first, stride, count)
    {
        names := []
        idx := 0
        while (idx < count)
        {
            names.Push(this._ReadNativeStringU(first + (idx * stride) + 0x08))
            idx += 1
        }
        return names
    }

    ; Revalidates + reads a cached stash-tab vector given the address of its
    ; StdVector header (first/last/end) and the stride. Returns the name array,
    ; or [] if the header no longer looks like a valid vector of names.
    _ReadStashVecAt(vecFieldAddr, stride)
    {
        out := []
        hdr := this.Mem.ReadBytes(vecFieldAddr, 24)
        if !hdr
            return out
        first := NumGet(hdr.Ptr, 0,  "Int64")
        last  := NumGet(hdr.Ptr, 8,  "Int64")
        end   := NumGet(hdr.Ptr, 16, "Int64")
        if !this.IsProbablyValidPointer(first)
            return out
        if (last <= first || end < last)
            return out
        span := last - first
        if (span <= 0 || Mod(span, stride) != 0)
            return out
        count := span // stride
        if (count < 1 || count > 200)
            return out
        return this._ReadStashVecEntries(first, stride, count)
    }

    ; Counts non-empty names in an array.
    _StashNonEmptyCount(names)
    {
        n := 0
        for _, s in names
            if (s != "")
                n += 1
        return n
    }

    ; Counts distinct non-empty names in an array.
    _StashDistinctCount(names)
    {
        seen := Map()
        for _, s in names
            if (s != "")
                seen[s] := true
        return seen.Count
    }

    ; Reads the StatsFromMods StdVector — a flat list of (statKey, statValue) pairs
    ; aggregated across all of an item's mods. Same element layout as player stats
    ; (8-byte StatArrayStruct: int key + int value). Resolves to the same stat IDs
    ; that stat_desc_map.tsv covers, so the existing FormatStatEntry pipeline can
    ; produce templated lines like "+38 to Spirit".
    ;
    ; Params: vectorAddress - absolute address of the StdVector struct (NOT a pointer to one)
    ;         maxPairs      - safety cap for runaway vectors
    ; Returns: Array of Maps with "key" and "value", or [] on invalid input.
    ReadItemStatsFromMods(vectorAddress, maxPairs := 128)
    {
        out := []
        if !this.IsProbablyValidPointer(vectorAddress)
            return out

        first := this.Mem.ReadInt64(vectorAddress + PoE2Offsets.StdVector["First"])
        last  := this.Mem.ReadInt64(vectorAddress + PoE2Offsets.StdVector["Last"])
        if (first <= 0 || last < first)
            return out

        pairSize := 8   ; StatArrayStruct = int key (4B) + int value (4B)
        count    := Floor((last - first) / pairSize)
        if (count <= 0)
            return out

        maxRead := Min(count, maxPairs)
        idx := 0
        while (idx < maxRead)
        {
            addr := first + (idx * pairSize)
            key  := this.Mem.ReadInt(addr + PoE2Offsets.StatPair["Key"])
            val  := this.Mem.ReadInt(addr + PoE2Offsets.StatPair["Value"])
            out.Push(Map("key", key, "value", val))
            idx += 1
        }
        return out
    }

    ; Reads a std::vector of mod entries and returns an array of mod Maps (name, value, genType, modFamily).
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
            entryAddr   := first + (idx * entrySize)
            value0Raw   := this.Mem.ReadInt(entryAddr + PoE2Offsets.ModArray["Value0"])
            modRowPtr   := this.Mem.ReadPtr(entryAddr + PoE2Offsets.ModArray["ModsPtr"])

            ; ── Read the mod's Values vector — array of roll values (4 B each) ──
            ; This is NOT a (key, value) StatPair vector. The stat IDs live on the
            ; Mods.dat row pointed to by ModsPtr; the per-item vector holds only the
            ; numeric rolls for those stats. A "+Life and +Mana" mod has 2 values,
            ; a single "+Strength" mod has 1 value, etc.
            ;
            ; Per-mod stat IDs would require the Mods.dat row schema (offsets into
            ; the dat row for the stat-id columns), which isn't available: the
            ; GameHelper source (GameOffsets/.../ModsAndObjectMagicProperties.cs)
            ; exposes only the same component offsets we have — there is no Mods.dat
            ; offset file to copy. So per-mod attribution stays values-only.
            ;
            ; NOTE: item-level templated text ("+38 to Spirit") is NOT blocked by
            ; this — _BuildItemModsJson renders it from the aggregated StatsFromMods
            ; (statKey, statValue) list via stat_desc_map. This Values vector only
            ; feeds the per-mod fallback breakdown.
            valuesVecAddr := entryAddr + PoE2Offsets.ModArray["Values"]
            vFirst := this.Mem.ReadInt64(valuesVecAddr + PoE2Offsets.StdVector["First"])
            vLast  := this.Mem.ReadInt64(valuesVecAddr + PoE2Offsets.StdVector["Last"])
            values := []
            vCount := 0
            if (vFirst > 0 && vLast >= vFirst)
            {
                vCount := Min(Floor((vLast - vFirst) / 4), 16)
                vIdx := 0
                while (vIdx < vCount)
                {
                    values.Push(this.Mem.ReadInt(vFirst + (vIdx * 4)))
                    vIdx += 1
                }
            }

            ; Back-compat fields used by TreeView debug rendering. value0 is the
            ; first roll value when present, otherwise the Value0 fallback int.
            value0 := (values.Length >= 1) ? values[1] : value0Raw
            value1 := (values.Length >= 2) ? values[2] : ""

            modName := this.ReadModName(modRowPtr)
            if (modName != "")
            {
                modInfo := this.GetModDisplayInfo(modName)
                out.Push(Map(
                    "name", modName,
                    "displayName", modInfo["affix"],
                    "genType", modInfo["genType"],
                    "modFamily", modInfo["modFamily"],
                    "values", values,         ; preferred — all roll values for this mod
                    "value0", value0,         ; legacy: first roll value
                    "value1", value1,         ; legacy: second roll value
                    "valuesCount", vCount,
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
    ; TSV columns: modId, affixName, genType (1=prefix / 2=suffix), modFamily.
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
                modFamily  := (parts.Length >= 4) ? parts[4] : ""
                this.ModNameMap[modId] := Map("affix", affix, "genType", genType, "modFamily", modFamily)
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

    ; Looks up affix display name, genType, and modFamily for a mod ID; returns empty defaults if absent.
    GetModDisplayInfo(modId)
    {
        if this.ModNameMap.Has(modId)
            return this.ModNameMap[modId]
        return Map("affix", "", "genType", 0, "modFamily", "")
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

    ; Reads the item's ItemVisualIdentity Id (e.g. "FourUniquePinnacle1") for unique
    ; items via the Base component: Base+0x30 → IVI dat row → +0x00 → Id wide string.
    ; Returns "" for non-uniques or on any invalid pointer in the chain.
    ReadUniqueIviId(itemEntityPtr)
    {
        if !this.IsProbablyValidPointer(itemEntityPtr)
            return ""
        baseComp := this.FindEntityComponentAddress(itemEntityPtr, "Base")
        if !this.IsProbablyValidPointer(baseComp)
            return ""
        iviRowPtr := this.Mem.ReadPtr(baseComp + PoE2Offsets.ItemBaseComponent["UniqueIviRow"])
        if !this.IsProbablyValidPointer(iviRowPtr)
            return ""
        idStrPtr := this.Mem.ReadPtr(iviRowPtr + PoE2Offsets.ItemVisualIdentityRow["IdPtr"])
        if !this.IsProbablyValidPointer(idStrPtr)
            return ""
        iviId := this.Mem.ReadUnicodeString(idStrPtr)
        if (StrLen(iviId) <= 0 || StrLen(iviId) > 128)
            return ""
        return iviId
    }

    ; Loads the IVI-id → unique-name lookup table (data/unique_ivi_name_map.tsv)
    ; into this.UniqueIviNameMap. Columns: ivi_id, unique_name.
    LoadUniqueIviNameMap(tsvPath)
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
                this.UniqueIviNameMap[parts[1]] := parts[2]
            }
            f.Close()
        }
        catch as err {
        }
    }

    ; Returns the unique name for an ItemVisualIdentity Id, or "" if not mapped.
    GetUniqueNameByIvi(iviId)
    {
        if this.UniqueIviNameMap.Has(iviId)
            return this.UniqueIviNameMap[iviId]
        return ""
    }

    ; Loads the inventory type lookup table from a TSV file into this.InventoryTypeMap.
    ; Generated by tools/extract_inventories_dat.py. Columns:
    ;   game_index (1-based, 0x01-based), dat_row (0-based), type (Id), inventory_id_key.
    ; The map is keyed by game_index because that is the InventoryId the game exposes
    ; in memory (dat_row + 1); value is the inventory type/category label (the Id string,
    ; e.g. "BodyArmour1", "Flask1").
    LoadInventoryTypeMap(tsvPath)
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
                if (parts.Length < 3)
                    continue
                gameIndex := Integer(parts[1])
                this.InventoryTypeMap[gameIndex] := parts[3]
            }
            f.Close()
        }
        catch as err {
        }
    }

    ; Returns the inventory type for a game InventoryId (1-based), or "" if not in the map.
    GetInventoryType(inventoryId)
    {
        if this.InventoryTypeMap.Has(inventoryId)
            return this.InventoryTypeMap[inventoryId]
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
