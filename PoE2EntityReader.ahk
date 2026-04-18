; PoE2EntityReader.ahk
; Entity reading layer — extends PoE2ComponentDecoders.
;
; Responsible for collecting, sampling and decoding entities from the game's
; std::unordered_map (AwakeEntities / SleepingEntities). Also provides
; component-vector decoding and entity pointer validation helpers.
;
; Inheritance chain: PoE2GameStateReader → ... → PoE2EntityReader → PoE2ComponentDecoders

class PoE2EntityReader extends PoE2ComponentDecoders
{
    ResolveEntityListOffset(areaInstanceAddress, forceRefresh := false)
    {
        return PoE2Offsets.AreaInstance["AwakeEntities"]
    }

    ; Entry point: reads the std::map header, then collects, samples and counts entities.
    ; Params: stdMapAddress - pointer to the AwakeEntities std::map; playerOrigin - {x,y,z} Map used for distance filtering
    ; Returns: Map with address, size, head, root, sample, sampleCount, npcCount, chestCount
    ReadAreaEntityMapSummary(stdMapAddress, maxSample := 32, playerOrigin := 0)
    {
        out := Map(
            "address", stdMapAddress,
            "size", 0,
            "head", 0,
            "root", 0,
            "sample", []
        )

        if !this.IsProbablyValidPointer(stdMapAddress)
            return out

        head := this.Mem.ReadPtr(stdMapAddress + PoE2Offsets.StdMap["Head"])
        size := this.Mem.ReadInt(stdMapAddress + PoE2Offsets.StdMap["Size"])
        if (size < 0 || size > 200000)
            size := 0

        out["head"] := head
        out["size"] := size

        if !this.IsProbablyValidPointer(head)
            return out

        root := this.Mem.ReadPtr(head + PoE2Offsets.StdMapNode["Parent"])
        out["root"] := root
        if !this.IsProbablyValidPointer(root) || root = head
            return out

        candidates      := this.CollectEntityMapCandidates(head, root, size, maxSample, playerOrigin)
        sample          := this.SelectEntitySample(candidates, maxSample)
        counts          := this.CountEntityTypes(sample)

        out["sample"]      := sample
        out["sampleCount"] := sample.Length
        out["npcCount"]    := counts["npcCount"]
        out["chestCount"]  := counts["chestCount"]
        return out
    }

    ; BFS traversal of the std::map red-black tree; collects entity candidate entries.
    ; Prioritises NPCs to guarantee at least minNpcCandidates; caps total nodes visited at maxVisited.
    ; Params: head - sentinel node pointer; root - tree root pointer; size - map size hint
    ; Returns: Array of sample-entry Maps (id, entityPtr, entityRawPtr, node, entity, distance, priority)
    CollectEntityMapCandidates(head, root, size, maxSample, playerOrigin)
    {
        candidates        := []
        queue             := [root]
        queueIndex        := 1
        visited           := Map()
        npcCandidateCount := 0

        maxCandidates := maxSample * 8
        if (maxCandidates < 128)
            maxCandidates := 128
        if (maxCandidates > 768)
            maxCandidates := 768

        minNpcCandidates := Floor(maxSample / 2)
        if (minNpcCandidates < 4)
            minNpcCandidates := 4
        if (minNpcCandidates > 12)
            minNpcCandidates := 12

        maxVisited := maxSample * 20
        if (size > 0 && size * 6 < maxVisited)
            maxVisited := size * 6
        bfsFloor := this._radarMode ? 64 : 512
        if (maxVisited < bfsFloor)
            maxVisited := bfsFloor
        radarVisitedCap := this._radarMode ? 400 : 6000
        if (maxVisited > radarVisitedCap)
            maxVisited := radarVisitedCap

        ; Time budget: radar gets 35ms (was 25ms, increased for larger 40-entity sample), full scan gets 80ms
        bfsBudgetMs  := this._radarMode ? 35 : 80
        deadlineTick := A_TickCount + bfsBudgetMs
        bfsIter      := 0

        while (queueIndex <= queue.Length)
        {
            if (visited.Count >= maxVisited)
                break
            if (candidates.Length >= maxCandidates && npcCandidateCount >= minNpcCandidates)
                break

            ; Check time budget every 50 iterations to avoid per-iteration overhead
            bfsIter += 1
            if (bfsIter >= 50)
            {
                bfsIter := 0
                if (A_TickCount > deadlineTick)
                    break
            }

            node := queue[queueIndex]
            queueIndex += 1
            if !this.IsProbablyValidPointer(node)
                continue
            if (node = head)
                continue

            if visited.Has(node)
                continue
            visited[node] := true

            left  := this.Mem.ReadPtr(node + PoE2Offsets.StdMapNode["Left"])
            right := this.Mem.ReadPtr(node + PoE2Offsets.StdMapNode["Right"])

            nodeEntry    := this.DecodeEntityMapNodeEntry(node)
            entityId     := (nodeEntry && nodeEntry.Has("id"))        ? nodeEntry["id"]        : this.Mem.ReadUInt(node + PoE2Offsets.StdMapNode["KeyId"])
            entityRawPtr := (nodeEntry && nodeEntry.Has("rawPtr"))    ? nodeEntry["rawPtr"]    : this.Mem.ReadPtr(node + PoE2Offsets.StdMapNode["ValueEntityPtr"])
            entityPtr    := (nodeEntry && nodeEntry.Has("entityPtr")) ? nodeEntry["entityPtr"] : this.ResolveEntityPointer(entityRawPtr)

            if (entityId <= 0 && this.IsProbablyValidPointer(entityPtr))
                entityId := this.Mem.ReadUInt(entityPtr + PoE2Offsets.Entity["Id"])

            if this.IsEntityLikePointer(entityPtr)
            {
                entityBasic := this.ReadEntityBasic(entityPtr, entityId)
                if !(entityBasic && Type(entityBasic) = "Map")
                    entityBasic := 0
                if !entityBasic
                    continue

                sampleEntry := Map(
                    "id",           entityId,
                    "entityPtr",    entityPtr,
                    "entityRawPtr", entityRawPtr,
                    "node",         node
                )
                if (nodeEntry && nodeEntry.Has("layout"))
                    sampleEntry["nodeLayout"] := nodeEntry["layout"]

                entityPos               := this.ExtractEntityWorldPositionFromEntityBasic(entityBasic, playerOrigin)
                sampleEntry["entity"]   := entityBasic
                sampleEntry["distance"] := this.ComputeDistance3DFromMaps(playerOrigin, entityPos)
                sampleEntry["priority"] := this.ComputeSampleEntryPriority(entityBasic, sampleEntry["distance"])
                if (sampleEntry["priority"] >= 30)
                    npcCandidateCount += 1

                candidates.Push(sampleEntry)
            }

            if (this.IsProbablyValidPointer(left) && left != head)
                queue.Push(left)
            if (this.IsProbablyValidPointer(right) && right != head)
                queue.Push(right)
        }

        return candidates
    }

    ; Sorts candidates by priority/distance, fills up to 65 % of the quota with high-priority (NPC) entries,
    ; then fills the remainder with any remaining candidates in order.
    ; Returns: Array of up to maxSample sample-entry Maps
    SelectEntitySample(candidates, maxSample)
    {
        sample := []
        if (candidates.Length = 0)
            return sample

        this.SortSampleEntriesByDistance(candidates)
        maxKeep := Min(maxSample, candidates.Length)
        npcKeep := Floor(maxKeep * 0.65)
        if (npcKeep < 4)
            npcKeep := 4
        if (npcKeep > maxKeep)
            npcKeep := maxKeep

        used := Map()
        idx  := 1
        while (idx <= candidates.Length && sample.Length < npcKeep)
        {
            entry := candidates[idx]
            prio  := (entry && entry.Has("priority")) ? entry["priority"] : 0
            if (prio >= 30)
            {
                sample.Push(entry)
                used[idx] := true
            }
            idx += 1
        }

        idx := 1
        while (idx <= candidates.Length && sample.Length < maxKeep)
        {
            if !used.Has(idx)
                sample.Push(candidates[idx])
            idx += 1
        }

        return sample
    }

    ; Counts NPC-like and chest-like entities in a sample array using path heuristics.
    ; Returns: Map with keys npcCount and chestCount
    CountEntityTypes(sample)
    {
        npcCount   := 0
        chestCount := 0
        for _, entry in sample
        {
            if !(entry && Type(entry) = "Map" && entry.Has("entity"))
                continue
            entity := entry["entity"]
            if !(entity && Type(entity) = "Map")
                continue
            path := entity.Has("path") ? entity["path"] : ""
            if this.IsNpcLikeEntityPath(path)
                npcCount += 1
            if this.IsChestLikeEntityPath(path)
                chestCount += 1
        }
        return Map("npcCount", npcCount, "chestCount", chestCount)
    }

    ; Extracts the validated worldPosition Map from a decoded render component.
    ; Returns: {x,y,z} Map, or 0 if the component or position fields are absent/invalid
    ExtractWorldPositionFromRenderComponent(renderComponent)
    {
        if !(renderComponent && Type(renderComponent) = "Map")
            return 0
        if !renderComponent.Has("worldPosition")
            return 0

        wp := renderComponent["worldPosition"]
        if !(wp && Type(wp) = "Map")
            return 0
        if (!wp.Has("x") || !wp.Has("y") || !wp.Has("z"))
            return 0

        return wp
    }

    ; Extracts and validates the world position from an entity's decoded render component.
    ; Returns: {x,y,z} Map if position passes IsPlausibleEntityWorldPosition, otherwise 0
    ExtractEntityWorldPositionFromEntityBasic(entityBasic, playerOrigin := 0)
    {
        if !(entityBasic && Type(entityBasic) = "Map")
            return 0
        if !entityBasic.Has("decodedComponents")
            return 0

        decoded := entityBasic["decodedComponents"]
        if !(decoded && Type(decoded) = "Map")
            return 0
        if !decoded.Has("render")
            return 0

        render := decoded["render"]
        worldPos := this.ExtractWorldPositionFromRenderComponent(render)
        if !this.IsPlausibleEntityWorldPosition(playerOrigin, worldPos)
            return 0
        return worldPos
    }

    ; Validates an entity world position: checks coordinate types, rejects positions near the
    ; world origin when the player is far from it, and rejects positions >25 000 units away.
    ; Params: playerOrigin - {x,y,z} Map (pass 0 to skip player-relative checks)
    ; Returns: true if the position is plausible
    IsPlausibleEntityWorldPosition(playerOrigin, entityPos)
    {
        if !(entityPos && Type(entityPos) = "Map")
            return false
        if (!entityPos.Has("x") || !entityPos.Has("y") || !entityPos.Has("z"))
            return false

        x := entityPos["x"]
        y := entityPos["y"]
        z := entityPos["z"]
        if ((Type(x) != "Float" && Type(x) != "Integer")
            || (Type(y) != "Float" && Type(y) != "Integer")
            || (Type(z) != "Float" && Type(z) != "Integer"))
            return false

        if !(playerOrigin && Type(playerOrigin) = "Map")
            return true
        if (!playerOrigin.Has("x") || !playerOrigin.Has("y") || !playerOrigin.Has("z"))
            return true

        px := playerOrigin["x"]
        py := playerOrigin["y"]
        pz := playerOrigin["z"]
        if ((Type(px) != "Float" && Type(px) != "Integer")
            || (Type(py) != "Float" && Type(py) != "Integer")
            || (Type(pz) != "Float" && Type(pz) != "Integer"))
            return true

        playerFarFromOrigin := (Abs(px) > 512) || (Abs(py) > 512)
        entityNearOrigin := (Abs(x) < 64) && (Abs(y) < 64) && (Abs(z) < 512)
        if (playerFarFromOrigin && entityNearOrigin)
            return false

        dx := Abs(px - x)
        dy := Abs(py - y)
        dz := Abs(pz - z)
        if (dx > 25000 || dy > 25000 || dz > 10000)
            return false

        return true
    }

    ; Computes Euclidean 3D distance between two {x,y,z} Maps.
    ; Returns: distance as Float, or -1 if either input is missing or invalid
    ComputeDistance3DFromMaps(posA, posB)
    {
        if !(posA && Type(posA) = "Map")
            return -1
        if !(posB && Type(posB) = "Map")
            return -1
        if (!posA.Has("x") || !posA.Has("y") || !posA.Has("z"))
            return -1
        if (!posB.Has("x") || !posB.Has("y") || !posB.Has("z"))
            return -1

        dx := posA["x"] - posB["x"]
        dy := posA["y"] - posB["y"]
        dz := posA["z"] - posB["z"]
        return Sqrt((dx * dx) + (dy * dy) + (dz * dz))
    }

    ; In-place insertion sort on sample-entry Maps: primary key = priority (descending),
    ; secondary key = distance (ascending); entries with unknown distance (-1) sort last within a tier.
    SortSampleEntriesByDistance(items)
    {
        i := 2
        while (i <= items.Length)
        {
            current := items[i]
            currentDist := (current && current.Has("distance")) ? current["distance"] : -1
            currentPrio := (current && current.Has("priority")) ? current["priority"] : 0
            j := i - 1

            while (j >= 1)
            {
                prev := items[j]
                prevDist := (prev && prev.Has("distance")) ? prev["distance"] : -1
                prevPrio := (prev && prev.Has("priority")) ? prev["priority"] : 0

                prevUnknown := (prevDist < 0)
                currUnknown := (currentDist < 0)

                movePrev := false
                if (prevPrio < currentPrio)
                    movePrev := true
                else if (prevPrio > currentPrio)
                    movePrev := false
                else if (prevUnknown && !currUnknown)
                    movePrev := true
                else if (!prevUnknown && !currUnknown && prevDist > currentDist)
                    movePrev := true

                if !movePrev
                    break

                items[j + 1] := items[j]
                j -= 1
            }

            items[j + 1] := current
            i += 1
        }
    }

    ; Scores an entity for sampling priority: friendly=4, NPC+alive/targetable=30, NPC only=12,
    ; targeted=24, alive=18, chest≤5; entities >3000 or >6000 units away receive score penalties.
    ; Params: distance - pre-computed distance, or -1 if unknown
    ; Returns: integer priority score (0–30)
    ComputeSampleEntryPriority(entityBasic, distance := -1)
    {
        if !(entityBasic && Type(entityBasic) = "Map")
            return 0

        path := entityBasic.Has("path") ? StrLower(entityBasic["path"]) : ""

        decoded := (entityBasic.Has("decodedComponents") && entityBasic["decodedComponents"] && Type(entityBasic["decodedComponents"]) = "Map")
            ? entityBasic["decodedComponents"]
            : 0

        isFriendly := false
        hasAliveLife := false
        hasActiveTargetable := false

        if (decoded && decoded.Has("positioned"))
        {
            pos := decoded["positioned"]
            if (pos && Type(pos) = "Map" && pos.Has("isFriendly") && pos["isFriendly"])
                isFriendly := true
        }

        if (decoded && decoded.Has("life"))
        {
            life := decoded["life"]
            if (life && Type(life) = "Map" && life.Has("isAlive") && life["isAlive"])
                hasAliveLife := true
        }

        if (decoded && decoded.Has("targetable"))
        {
            targetable := decoded["targetable"]
            if (targetable && Type(targetable) = "Map")
            {
                if ((targetable.Has("isTargetable") && targetable["isTargetable"])
                    || (targetable.Has("isHighlightable") && targetable["isHighlightable"]))
                    hasActiveTargetable := true
            }
        }

        ; Important structural entities always get high priority
        if (InStr(path, "areatransition") || InStr(path, "waypoint")
            || InStr(path, "checkpoint") || InStr(path, "boss"))
            return 35

        if isFriendly
            return 4

        score := 8
        if this.IsNpcLikeEntityPath(path)
            score := (hasActiveTargetable || hasAliveLife) ? 30 : 12
        else if hasActiveTargetable
            score := 24
        else if hasAliveLife
            score := 18

        if this.IsChestLikeEntityPath(path)
            score := Min(score, 5)

        if (distance >= 0 && distance > 6000)
            score -= 12
        else if (distance >= 0 && distance > 3000)
            score -= 6

        if (score < 0)
            score := 0

        return score
    }

    ; Returns true if the path matches metadata/characters/, metadata/monsters/, or metadata/npc/,
    ; excluding /player, /attachments/, and /outfits/ sub-paths.
    IsNpcLikeEntityPath(path)
    {
        if (path = "")
            return false

        p := StrLower(path)
        if InStr(p, "/player")
            return false
        if InStr(p, "/attachments/") || InStr(p, "/outfits/")
            return false

        return InStr(p, "metadata/characters/") || InStr(p, "metadata/monsters/") || InStr(p, "metadata/npc/")
    }

    ; Returns true if the path contains /chests/, strongbox, or metadata/chests/.
    IsChestLikeEntityPath(path)
    {
        if (path = "")
            return false

        p := StrLower(path)
        return InStr(p, "/chests/") || InStr(p, "strongbox") || InStr(p, "metadata/chests/")
    }

    ; Reads one std::map node: entity ID (KeyId) + raw entity pointer (ValueEntityPtr),
    ; then resolves the raw pointer via ResolveEntityPointer to obtain a usable entity address.
    ; Returns: Map with id, rawPtr, entityPtr, layout
    DecodeEntityMapNodeEntry(nodeAddress)
    {
        out := Map(
            "id", 0,
            "rawPtr", 0,
            "entityPtr", 0,
            "layout", "direct"
        )

        if !this.IsProbablyValidPointer(nodeAddress)
            return out

        entityId := this.Mem.ReadUInt(nodeAddress + PoE2Offsets.StdMapNode["KeyId"])
        rawPtr := this.Mem.ReadPtr(nodeAddress + PoE2Offsets.StdMapNode["ValueEntityPtr"])
        entityPtr := this.ResolveEntityPointer(rawPtr)

        out["id"] := entityId
        out["rawPtr"] := rawPtr
        out["entityPtr"] := entityPtr
        return out
    }

    ; Checks the IsNil flag byte of a std::map node to detect the sentinel/end node.
    ; Returns: true if the node is nil (invalid pointer or flag != 0)
    IsStdMapNodeNil(nodeAddress)
    {
        if !this.IsProbablyValidPointer(nodeAddress)
            return true

        flag := this.Mem.ReadUChar(nodeAddress + PoE2Offsets.StdMapNode["IsNil"])
        return flag != 0
    }

    ; Quick structural validity check: verifies component vector bounds, entity details pointer,
    ; and that the entity ID falls within the valid range (>0, <0x40000000).
    ; Returns: true if the address looks like a valid Entity*
    IsEntityLikePointer(address)
    {
        if !this.IsProbablyValidPointer(address)
            return false

        compVecFirst := this.Mem.ReadInt64(address + PoE2Offsets.Entity["ComponentsVec"])
        compVecLast := this.Mem.ReadInt64(address + PoE2Offsets.Entity["ComponentsVecLast"])
        if (compVecFirst <= 0 || compVecLast < compVecFirst)
            return false

        totalBytes := compVecLast - compVecFirst
        if (totalBytes <= 0 || Mod(totalBytes, A_PtrSize) != 0)
            return false

        componentCount := Floor(totalBytes / A_PtrSize)
        if (componentCount <= 0 || componentCount > 1024)
            return false

        entityDetailsPtr := this.Mem.ReadPtr(address + PoE2Offsets.Entity["EntityDetailsPtr"])
        if !this.IsProbablyValidPointer(entityDetailsPtr)
            return false

        entityId := this.Mem.ReadUInt(address + PoE2Offsets.Entity["Id"])
        if (entityId <= 0 || entityId >= 0x40000000)
            return false

        return true
    }

    ; Reads a full entity snapshot: ID, flags, path, component count, named component lookup,
    ; and decoded components. Falls back to vector scan if the lookup yields no decoded data.
    ; Params: mapId - caller-supplied entity ID to store alongside the snapshot
    ; Returns: Map with address, mapId, entityId, flags, isValid, path, componentCount, decodedComponents, …
    ReadEntityBasic(entityPtr, mapId := 0)
    {
        if !this.IsProbablyValidPointer(entityPtr)
            return 0

        ; Batch-read entity header: 0x08..0x1F → EntityDetailsPtr(0x08), ComponentsVec(0x10), ComponentsVecLast(0x18)
        ; and 0x80..0x87 → Id(0x80), Flags(0x84) — two reads instead of five
        hdrBuf := this.Mem.ReadBytes(entityPtr + 0x08, 0x18)
        if !hdrBuf
            return 0
        entityDetailsPtr := NumGet(hdrBuf.Ptr, 0x00, "Ptr")   ; offset 0x08 in entity struct
        compVecFirst     := NumGet(hdrBuf.Ptr, 0x08, "Int64")  ; offset 0x10
        compVecLast      := NumGet(hdrBuf.Ptr, 0x10, "Int64")  ; offset 0x18

        idBuf := this.Mem.ReadBytes(entityPtr + 0x80, 8)
        entityId := idBuf ? NumGet(idBuf.Ptr, 0, "UInt") : 0
        flags    := idBuf ? NumGet(idBuf.Ptr, 4, "UChar") : 0

        path := ""
        if this.IsProbablyValidPointer(entityDetailsPtr)
            path := this.ReadStdWStringAt(entityDetailsPtr + PoE2Offsets.EntityDetails["Path"], 260)

        componentCount := -1
        if (compVecFirst > 0 && compVecLast >= compVecFirst)
        {
            totalBytes := compVecLast - compVecFirst
            count := Floor(totalBytes / A_PtrSize)
            if (count >= 0 && count <= 256)
                componentCount := count
        }

        components := this.ReadEntityComponentLookupBasic(entityPtr, this._radarMode ? 64 : 48)
        namedComponentCount := (components && Type(components) = "Array") ? components.Length : 0
        if (this._radarMode)
        {
            decodedComponents := this.DecodeSampleEntityComponentsRadar(components)
            ; Fallback: if lookup-based decode found no render component, try the vector scan
            if (!(decodedComponents && Type(decodedComponents) = "Map" && decodedComponents.Has("render")))
            {
                fallback := this.DecodeEntityComponentsFromVectorBasic(entityPtr, 64)
                if (fallback && Type(fallback) = "Map" && fallback.Count > 0)
                    decodedComponents := fallback
            }
        }
        else
        {
            decodedComponents := this.DecodeSampleEntityComponents(components)
            if (!(decodedComponents && Type(decodedComponents) = "Map") || decodedComponents.Count = 0)
                decodedComponents := this.DecodeEntityComponentsFromVectorBasic(entityPtr, 48)
        }
        decodedComponentCount := (decodedComponents && Type(decodedComponents) = "Map") ? decodedComponents.Count : 0

        return Map(
            "address", entityPtr,
            "mapId", mapId,
            "entityId", entityId,
            "flags", flags,
            "isValid", (flags & 0x01) = 0 ? true : false,
            "entityDetailsPtr", entityDetailsPtr,
            "path", path,
            "componentCount", componentCount,
            "namedComponentCount", namedComponentCount,
            "components", components,
            "decodedComponents", decodedComponents,
            "decodedComponentCount", decodedComponentCount
        )
    }

    ; Lightweight entity read: only fetches ID, flags, isValid flag, and path string.
    ; Params: maxPathLen - maximum wide-string length to read for the path
    ; Returns: Map with entityId, flags, isValid, path; or 0 on invalid pointer
    ReadEntityIdentityBasic(entityPtr, maxPathLen := 180)
    {
        if !this.IsProbablyValidPointer(entityPtr)
            return 0

        entityId := this.Mem.ReadUInt(entityPtr + PoE2Offsets.Entity["Id"])
        flags := this.Mem.ReadUChar(entityPtr + PoE2Offsets.Entity["Flags"])
        entityDetailsPtr := this.Mem.ReadPtr(entityPtr + PoE2Offsets.Entity["EntityDetailsPtr"])

        path := ""
        if this.IsProbablyValidPointer(entityDetailsPtr)
            path := this.ReadStdWStringAt(entityDetailsPtr + PoE2Offsets.EntityDetails["Path"], maxPathLen)

        return Map(
            "entityId", entityId,
            "flags", flags,
            "isValid", (flags & 0x01) = 0 ? true : false,
            "path", path
        )
    }

    ; Iterates a named component list from ReadEntityComponentLookupBasic and dispatches each
    ; entry to the matching DecodeXxx method, storing results under a canonical lowercase key.
    ; Params: maxDecoded - upper bound on how many components to decode
    ; Returns: Map of canonical-name → decoded component data
    DecodeSampleEntityComponents(components, maxDecoded := 20)
    {
        out := Map()
        if !(components && Type(components) = "Array")
            return out

        decoded := 0
        for _, comp in components
        {
            if (decoded >= maxDecoded)
                break
            if !(comp && Type(comp) = "Map")
                continue
            if !comp.Has("name") || !comp.Has("address")
                continue

            compName := comp["name"]
            compAddr := comp["address"]
            if !this.IsProbablyValidPointer(compAddr)
                continue

            canonical := ""
            decodedData := 0

            if this.ComponentNameMatches(compName, "Targetable")
            {
                canonical := "targetable"
                decodedData := this.DecodeTargetableComponent(compAddr)
            }
            else if this.ComponentNameMatches(compName, "Render")
            {
                canonical := "render"
                decodedData := this.DecodeRenderComponent(compAddr)
            }
            else if this.ComponentNameMatches(compName, "Chest")
            {
                canonical := "chest"
                decodedData := this.DecodeChestComponent(compAddr)
            }
            else if this.ComponentNameMatches(compName, "Shrine")
            {
                canonical := "shrine"
                decodedData := this.DecodeShrineComponent(compAddr)
            }
            else if this.ComponentNameMatches(compName, "Positioned")
            {
                canonical := "positioned"
                decodedData := this.DecodePositionedComponent(compAddr)
            }
            else if this.ComponentNameMatches(compName, "Transitionable")
            {
                canonical := "transitionable"
                decodedData := this.DecodeTransitionableComponent(compAddr)
            }
            else if this.ComponentNameMatches(compName, "StateMachine")
            {
                canonical := "statemachine"
                decodedData := this.DecodeStateMachineComponentBasic(compAddr)
            }
            else if this.ComponentNameMatches(compName, "Actor")
            {
                canonical := "actor"
                decodedData := this.DecodeActorComponentBasic(compAddr)
            }
            else if this.ComponentNameMatches(compName, "Animated")
            {
                canonical := "animated"
                decodedData := this.DecodeAnimatedComponentBasic(compAddr)
            }
            else if this.ComponentNameMatches(compName, "Buffs")
            {
                canonical := "buffs"
                decodedData := this.DecodeBuffsComponentBasic(compAddr)
            }
            else if this.ComponentNameMatches(compName, "Stats")
            {
                canonical := "stats"
                decodedData := this.DecodeStatsComponentBasic(compAddr)
            }
            else if this.ComponentNameMatches(compName, "Life")
            {
                canonical := "life"
                decodedData := this.DecodeLifeComponentBasic(compAddr)
            }
            else if this.ComponentNameMatches(compName, "Charges") || this.ComponentNameMatches(compName, "Charge")
            {
                canonical := "charges"
                decodedData := this.DecodeChargesComponentBasic(compAddr)
            }
            else if this.ComponentNameMatches(compName, "Player")
            {
                canonical := "player"
                decodedData := this.DecodePlayerComponentBasic(compAddr)
            }
            else if this.ComponentNameMatches(compName, "TriggerableBlockage")
            {
                canonical := "triggerableblockage"
                decodedData := this.DecodeTriggerableBlockageComponentBasic(compAddr)
            }
            else if this.ComponentNameMatches(compName, "Mods")
            {
                canonical := "mods"
                decodedData := this.DecodeModsComponentBasic(compAddr)
            }
            else if this.ComponentNameMatches(compName, "ObjectMagicProperties")
            {
                canonical := "objectmagicproperties"
                decodedData := this.DecodeObjectMagicPropertiesComponentBasic(compAddr)
            }
            else if this.ComponentNameMatches(compName, "Npc")
            {
                canonical := "npc"
                decodedData := this.DecodeNpcComponentBasic(compAddr)
            }
            else if this.ComponentNameMatches(compName, "MinimapIcon")
            {
                canonical := "minimapicon"
                decodedData := this.DecodeMinimapIconComponentBasic(compAddr)
            }
            else if this.ComponentNameMatches(compName, "DiesAfterTime")
            {
                canonical := "diesaftertime"
                decodedData := this.DecodeDiesAfterTimeComponentBasic(compAddr)
            }

            if (canonical = "" || out.Has(canonical))
                continue

            if (decodedData)
            {
                out[canonical] := decodedData
                decoded += 1
            }
        }

        return out
    }

    ; Fallback decoder: walks the raw component pointer vector, confirms ownership via the
    ; ComponentHeader EntityPtr back-pointer, then tries each decoder in sequence.
    ; Params: maxEntries - maximum number of component pointers to examine
    ; Returns: Map of canonical-name → decoded component data
    DecodeEntityComponentsFromVectorBasic(entityPtr, maxEntries := 48)
    {
        out := Map()
        if !this.IsProbablyValidPointer(entityPtr)
            return out

        compVecFirst := this.Mem.ReadInt64(entityPtr + PoE2Offsets.Entity["ComponentsVec"])
        compVecLast := this.Mem.ReadInt64(entityPtr + PoE2Offsets.Entity["ComponentsVecLast"])
        if (compVecFirst <= 0 || compVecLast < compVecFirst)
            return out

        ptrSize := A_PtrSize
        componentCount := Floor((compVecLast - compVecFirst) / ptrSize)
        if (componentCount <= 0)
            return out

        readCount := Min(componentCount, maxEntries)
        idx := 0
        while (idx < readCount)
        {
            componentPtr := this.Mem.ReadPtr(compVecFirst + (idx * ptrSize))
            if this.IsProbablyValidPointer(componentPtr)
            {
                ownerEntityPtr := this.Mem.ReadPtr(componentPtr + PoE2Offsets.ComponentHeader["EntityPtr"])
                if (ownerEntityPtr = entityPtr)
                {
                    if (!out.Has("targetable"))
                    {
                        decoded := this.DecodeTargetableComponent(componentPtr)
                        if (decoded)
                            out["targetable"] := decoded
                    }

                    if (!out.Has("life"))
                    {
                        decoded := this.DecodeLifeComponentBasic(componentPtr)
                        if (decoded)
                            out["life"] := decoded
                    }

                    if (!out.Has("render"))
                    {
                        decoded := this.DecodeRenderComponent(componentPtr)
                        if (decoded)
                            out["render"] := decoded
                    }

                    if (!out.Has("chest"))
                    {
                        decoded := this.DecodeChestComponent(componentPtr)
                        if (decoded)
                            out["chest"] := decoded
                    }

                    if (!out.Has("shrine"))
                    {
                        decoded := this.DecodeShrineComponent(componentPtr)
                        if (decoded)
                            out["shrine"] := decoded
                    }

                    if (!out.Has("triggerableblockage"))
                    {
                        decoded := this.DecodeTriggerableBlockageComponentBasic(componentPtr)
                        if (decoded)
                            out["triggerableblockage"] := decoded
                    }

                    if (!out.Has("mods"))
                    {
                        decoded := this.DecodeModsComponentBasic(componentPtr)
                        if (decoded)
                            out["mods"] := decoded
                    }

                    if (!out.Has("objectmagicproperties"))
                    {
                        decoded := this.DecodeObjectMagicPropertiesComponentBasic(componentPtr)
                        if (decoded)
                            out["objectmagicproperties"] := decoded
                    }

                    if (!out.Has("positioned"))
                    {
                        decoded := this.DecodePositionedComponent(componentPtr)
                        if (decoded)
                            out["positioned"] := decoded
                    }
                }
            }

            idx += 1
        }

        return out
    }


    ; Searches the entity's component lookup for a component matching componentName or any alias.
    ; Params: aliases - optional Array of alternate component name strings
    ; Returns: component address (pointer), or 0 if not found
    FindEntityComponentAddress(entityPtr, componentName, aliases := 0)
    {
        if !this.IsProbablyValidPointer(entityPtr)
            return 0

        components := this.ReadEntityComponentLookupBasic(entityPtr, 96)
        if !(components && Type(components) = "Array")
            return 0

        for _, component in components
        {
            if !(component && Type(component) = "Map" && component.Has("name") && component.Has("address"))
                continue

            if this.ComponentNameMatches(component["name"], componentName)
                return component["address"]

            if (aliases && Type(aliases) = "Array")
            {
                for _, aliasName in aliases
                {
                    if this.ComponentNameMatches(component["name"], aliasName)
                        return component["address"]
                }
            }
        }

        return 0
    }

    ; Stricter than IsEntityLikePointer: also validates that the entity ID is in the range (0, 0x40000000).
    ; Returns: true if the address is a structurally plausible Entity*
    IsPlausibleEntityPointer(entityPtr)
    {
        if !this.IsProbablyValidPointer(entityPtr)
            return false

        compVecFirst := this.Mem.ReadInt64(entityPtr + PoE2Offsets.Entity["ComponentsVec"])
        compVecLast := this.Mem.ReadInt64(entityPtr + PoE2Offsets.Entity["ComponentsVecLast"])
        if (compVecFirst <= 0 || compVecLast < compVecFirst)
            return false

        totalBytes := compVecLast - compVecFirst
        if (Mod(totalBytes, A_PtrSize) != 0)
            return false

        componentCount := Floor(totalBytes / A_PtrSize)
        if (componentCount <= 0 || componentCount > 512)
            return false

        entityDetailsPtr := this.Mem.ReadPtr(entityPtr + PoE2Offsets.Entity["EntityDetailsPtr"])
        if !this.IsProbablyValidPointer(entityDetailsPtr)
            return false

        entityId := this.Mem.ReadUInt(entityPtr + PoE2Offsets.Entity["Id"])
        return (entityId > 0 && entityId < 0x40000000)
    }

    ; Tries rawPtr, rawPtr-8, and several dereferenced neighbors to find a valid entity pointer.
    ; Accounts for wrapper/indirection patterns in the game's memory layout.
    ; Returns: first candidate that passes IsPlausibleEntityPointer, or rawPtr as fallback
    ResolveEntityPointer(rawPtr)
    {
        if !this.IsProbablyValidPointer(rawPtr)
            return 0

        candidates := []
        candidates.Push(rawPtr)
        candidates.Push(rawPtr - 0x08)

        p0 := this.Mem.ReadPtr(rawPtr)
        if this.IsProbablyValidPointer(p0)
            candidates.Push(p0)

        p8 := this.Mem.ReadPtr(rawPtr + 0x08)
        if this.IsProbablyValidPointer(p8)
            candidates.Push(p8)

        pm8 := this.Mem.ReadPtr(rawPtr - 0x08)
        if this.IsProbablyValidPointer(pm8)
            candidates.Push(pm8)

        seen := Map()
        for _, candidate in candidates
        {
            if !this.IsProbablyValidPointer(candidate)
                continue

            key := candidate ""
            if seen.Has(key)
                continue
            seen[key] := true

            if this.IsPlausibleEntityPointer(candidate)
                return candidate
        }

        return rawPtr
    }

    ; Fast component decoder for radar overlay: decodes only Render, Life, and Positioned.
    ; Scans all named components (no count limit) to ensure Life is always found regardless of position.
    ; Returns: Map subset with "render", "life", "positioned" (each absent if not decoded).
    DecodeSampleEntityComponentsRadar(components)
    {
        out := Map()
        if !(components && Type(components) = "Array")
            return out

        for _, comp in components
        {
            if (out.Has("render") && out.Has("life") && out.Has("positioned") && out.Has("rarityId") && out.Has("targetable"))
                break
            if !(comp && Type(comp) = "Map") || !comp.Has("name") || !comp.Has("address")
                continue

            compName := comp["name"]
            compAddr := comp["address"]
            if !this.IsProbablyValidPointer(compAddr)
                continue

            if !out.Has("render") && this.ComponentNameMatches(compName, "Render")
            {
                decoded := this.DecodeRenderComponent(compAddr)
                if decoded
                    out["render"] := decoded
            }
            else if !out.Has("life") && this.ComponentNameMatches(compName, "Life")
            {
                decoded := this.DecodeLifeComponentBasic(compAddr)
                if decoded
                    out["life"] := decoded
            }
            else if !out.Has("positioned") && this.ComponentNameMatches(compName, "Positioned")
            {
                decoded := this.DecodePositionedComponent(compAddr)
                if decoded
                    out["positioned"] := decoded
            }
            else if !out.Has("rarityId") && this.ComponentNameMatches(compName, "Mods")
            {
                ; Nur den Rarity-Int lesen — kein vollständiger Mods-Decode (zu teuer für 100ms-Tick)
                rarityId := this.Mem.ReadInt(compAddr + PoE2Offsets.Mods["Rarity"])
                if (rarityId >= 0 && rarityId <= 5)
                    out["rarityId"] := rarityId
            }
            else if !out.Has("rarityId") && this.ComponentNameMatches(compName, "ObjectMagicProperties")
            {
                rarityId := this.Mem.ReadInt(compAddr + PoE2Offsets.ObjectMagicProperties["Rarity"])
                if (rarityId >= 0 && rarityId <= 5)
                    out["rarityId"] := rarityId
            }
            else if !out.Has("chest") && this.ComponentNameMatches(compName, "Chest")
            {
                ; Chest entities have no Life component so the early-break never fires for them.
                ; Decoding isOpened lets the render loop hide already-opened chests.
                decoded := this.DecodeChestComponent(compAddr)
                if decoded
                    out["chest"] := decoded
            }
            else if !out.Has("targetable") && this.ComponentNameMatches(compName, "Targetable")
            {
                ; isTargetable goes false when a monster dies — used to detect corpses whose
                ; HP memory is stale (still reads > 0 despite entity being dead).
                ; raw=1 → alive; raw=0 → dead; raw>1 → garbage (dead memory), also treated as dead.
                ; Treating garbage the same as 0 is key: dead entities read 0 or unstable garbage,
                ; live entities reliably read 1. Discarding garbage made dead-detection impossible.
                raw := this.Mem.ReadUChar(compAddr + PoE2Offsets.Targetable["IsTargetable"])
                out["targetable"] := (raw = 1)
            }
        }
        return out
    }

    ; Reads entity map summary using the radar-only component decoder (Render + Life + Positioned).
    ; Sets a temporary _radarMode flag so ReadEntityBasic uses DecodeSampleEntityComponentsRadar.
    ; Falls back to DecodeEntityComponentsFromVectorBasic if the named-component lookup yields no Render.
    ; Returns: same structure as ReadAreaEntityMapSummary, but with a component subset per entity.
    ReadAreaEntityMapSummaryForRadar(stdMapAddress, maxSample := 32, playerOrigin := 0)
    {
        this._radarMode := true
        try
        {
            result := this.ReadAreaEntityMapSummary(stdMapAddress, maxSample, playerOrigin)
        }
        catch
        {
            result := Map("address", stdMapAddress, "size", 0, "head", 0, "root", 0,
                          "sample", [], "sampleCount", 0, "npcCount", 0, "chestCount", 0)
        }
        this._radarMode := false
        return result
    }

    ; Fast lightweight BFS scan of all entity raw pointers in a std::map red-black tree.
    ; Reads only Left, Right, and ValueEntityPtr per node — no component decode, no pointer resolution.
    ; Use this to build the complete set of entity raw pointers currently in the AwakeMap so that
    ; _FilterStaleRadarEntities can detect entities that have been fully removed from the map.
    ; Returns: Map of rawPtr → true (empty on invalid input).
    ScanEntityMapRawPtrs(stdMapAddress)
    {
        result := Map()
        if !this.IsProbablyValidPointer(stdMapAddress)
            return result

        head := this.Mem.ReadPtr(stdMapAddress + PoE2Offsets.StdMap["Head"])
        size := this.Mem.ReadInt(stdMapAddress + PoE2Offsets.StdMap["Size"])
        if (size < 1 || size > 200000 || !this.IsProbablyValidPointer(head))
            return result

        root := this.Mem.ReadPtr(head + PoE2Offsets.StdMapNode["Parent"])
        if !this.IsProbablyValidPointer(root) || root = head
            return result

        nodeReadSize := 0x30
        offLeft  := 0x00
        offRight := 0x10
        offValue := 0x28

        queue    := [root]
        qi       := 1
        visited  := Map()
        maxVisit := Min(size * 2 + 20, 3000)

        while (qi <= queue.Length && visited.Count < maxVisit)
        {
            node := queue[qi]
            qi += 1
            if !this.IsProbablyValidPointer(node) || node = head || visited.Has(node)
                continue
            visited[node] := true

            nodeBuf := this.Mem.ReadBytes(node, nodeReadSize)
            if !nodeBuf
                continue

            left   := NumGet(nodeBuf.Ptr, offLeft, "Ptr")
            right  := NumGet(nodeBuf.Ptr, offRight, "Ptr")
            rawPtr := NumGet(nodeBuf.Ptr, offValue, "Ptr")

            if this.IsProbablyValidPointer(rawPtr)
                result[rawPtr] := true

            if (this.IsProbablyValidPointer(left) && left != head)
                queue.Push(left)
            if (this.IsProbablyValidPointer(right) && right != head)
                queue.Push(right)
        }
        return result
    }

    ; Full-tree BFS scan returning entityId → rawPtr for all valid entities.
    ; Mirrors C# AreaInstance.UpdateEntities: reads ALL entities from the std::map, filtering
    ; out visual/decoration entities (id >= 0x40000000) per EntityFilter.IgnoreVisualsAndDecorations.
    ; Reads only 4 values per node (Left, Right, KeyId, ValueEntityPtr) — no component decode.
    ; Does NOT resolve entity pointers (deferred to full decode for new entities).
    ; Returns: Map of entityId → rawPtr
    ScanEntityMapIdsAndPtrs(stdMapAddress)
    {
        result := Map()
        if !this.IsProbablyValidPointer(stdMapAddress)
            return result

        head := this.Mem.ReadPtr(stdMapAddress + PoE2Offsets.StdMap["Head"])
        size := this.Mem.ReadInt(stdMapAddress + PoE2Offsets.StdMap["Size"])
        if (size < 1 || size > 200000 || !this.IsProbablyValidPointer(head))
            return result

        root := this.Mem.ReadPtr(head + PoE2Offsets.StdMapNode["Parent"])
        if !this.IsProbablyValidPointer(root) || root = head
            return result

        ; Pre-resolve offsets for batch node read (0x30 bytes covers Left..ValueEntityPtr)
        nodeReadSize := 0x30
        offLeft  := 0x00   ; StdMapNode.Left
        offRight := 0x10   ; StdMapNode.Right
        offKeyId := 0x20   ; StdMapNode.KeyId
        offValue := 0x28   ; StdMapNode.ValueEntityPtr

        queue    := [root]
        qi       := 1
        visited  := Map()
        maxVisit := Min(size * 2 + 20, 8000)

        while (qi <= queue.Length && visited.Count < maxVisit)
        {
            node := queue[qi]
            qi += 1
            if !this.IsProbablyValidPointer(node) || node = head || visited.Has(node)
                continue
            visited[node] := true

            ; Batch-read entire node struct in one RPM call (was 4 separate calls)
            nodeBuf := this.Mem.ReadBytes(node, nodeReadSize)
            if !nodeBuf
                continue

            left     := NumGet(nodeBuf.Ptr, offLeft, "Ptr")
            right    := NumGet(nodeBuf.Ptr, offRight, "Ptr")
            entityId := NumGet(nodeBuf.Ptr, offKeyId, "UInt")
            rawPtr   := NumGet(nodeBuf.Ptr, offValue, "Ptr")

            ; C# EntityFilter.IgnoreVisualsAndDecorations: skip id >= 0x40000000
            if (entityId > 0 && entityId < 0x40000000 && this.IsProbablyValidPointer(rawPtr))
                result[entityId] := rawPtr

            if (this.IsProbablyValidPointer(left) && left != head)
                queue.Push(left)
            if (this.IsProbablyValidPointer(right) && right != head)
                queue.Push(right)
        }
        return result
    }

    ; One-time deep scan of the sleeping entity tree to find structurally important entities.
    ; BFS-traverses the entire tree (no sample limit) and reads path + position for each node.
    ; Filters for AreaTransition, Waypoint, Checkpoint, Boss, NPC entities.
    ; Returns: Array of Maps with keys: path, type, worldX, worldY, worldZ, gridX, gridY
    ; This is expensive (~200-500ms) and should be called only once per zone change.
    DeepScanSleepingForImportantEntities(sleepingMapAddress)
    {
        results := []
        if !this.IsProbablyValidPointer(sleepingMapAddress)
            return results

        head := this.Mem.ReadPtr(sleepingMapAddress + PoE2Offsets.StdMap["Head"])
        size := this.Mem.ReadInt(sleepingMapAddress + PoE2Offsets.StdMap["Size"])
        if (size < 1 || size > 200000 || !this.IsProbablyValidPointer(head))
            return results

        root := this.Mem.ReadPtr(head + PoE2Offsets.StdMapNode["Parent"])
        if !this.IsProbablyValidPointer(root) || root = head
            return results

        ; BFS with generous limits (scan the full tree)
        ; Batch-read node structs (0x30 bytes each) to minimize RPM calls.
        queue    := [root]
        qi       := 1
        visited  := Map()
        maxVisit := Min(size * 2 + 100, 10000)
        worldToGridRatio := 250.0 / 0x17
        nodeReadSize := 0x30

        while (qi <= queue.Length && visited.Count < maxVisit)
        {
            node := queue[qi]
            qi += 1
            if !this.IsProbablyValidPointer(node) || node = head || visited.Has(node)
                continue
            visited[node] := true

            nodeBuf := this.Mem.ReadBytes(node, nodeReadSize)
            if !nodeBuf
                continue

            left   := NumGet(nodeBuf.Ptr, 0x00, "Ptr")
            right  := NumGet(nodeBuf.Ptr, 0x10, "Ptr")
            rawPtr := NumGet(nodeBuf.Ptr, 0x28, "Ptr")

            if (this.IsProbablyValidPointer(left) && left != head)
                queue.Push(left)
            if (this.IsProbablyValidPointer(right) && right != head)
                queue.Push(right)

            if !this.IsProbablyValidPointer(rawPtr)
                continue

            ; Resolve entity pointer (same indirection as regular entity scan)
            entityPtr := this.ResolveEntityPointer(rawPtr)
            if !this.IsProbablyValidPointer(entityPtr)
                continue

            ; Read just the path string (lightweight)
            identity := this.ReadEntityIdentityBasic(entityPtr, 180)
            if !(identity && Type(identity) = "Map")
                continue
            path := identity.Has("path") ? identity["path"] : ""
            if (path = "")
                continue

            ; Classify entity type
            pathLower := StrLower(path)
            entType := ""
            if InStr(pathLower, "areatransition")
                entType := "AreaTransition"
            else if InStr(pathLower, "waypoint")
                entType := "Waypoint"
            else if InStr(pathLower, "checkpoint")
                entType := "Checkpoint"
            else if (InStr(pathLower, "metadata/monsters/") && (InStr(pathLower, "boss") || InStr(pathLower, "unique")))
                entType := "Boss"
            else if InStr(pathLower, "metadata/npc/")
                entType := "NPC"

            if (entType = "")
                continue

            ; Read position via render component (need to find it from component vector)
            ; Use the fast vector-based approach to find the Render component
            renderAddr := this._FindRenderComponentFast(entityPtr)
            if !renderAddr
                continue

            worldX := this.Mem.ReadFloat(renderAddr + PoE2Offsets.Render["CurrentWorldPosition"])
            worldY := this.Mem.ReadFloat(renderAddr + PoE2Offsets.Render["CurrentWorldPositionY"])
            worldZ := this.Mem.ReadFloat(renderAddr + PoE2Offsets.Render["CurrentWorldPositionZ"])

            ; Plausibility check
            if (Abs(worldX) > 200000 || Abs(worldY) > 200000 || Abs(worldZ) > 200000)
                continue
            if (Abs(worldX) < 0.01 && Abs(worldY) < 0.01 && Abs(worldZ) < 0.01)
                continue

            gridX := worldX / worldToGridRatio
            gridY := worldY / worldToGridRatio

            results.Push(Map(
                "path", path,
                "type", entType,
                "worldX", worldX,
                "worldY", worldY,
                "worldZ", worldZ,
                "gridX", gridX,
                "gridY", gridY
            ))
        }
        return results
    }

    ; Fast render component finder: scans the entity's component vector for the Render component.
    ; Uses the same vector-scan approach as DecodeEntityComponentsFromVectorBasic but only looks for Render.
    ; Returns the Render component address, or 0 if not found.
    _FindRenderComponentFast(entityPtr)
    {
        if !this.IsProbablyValidPointer(entityPtr)
            return 0

        compVecFirst := this.Mem.ReadInt64(entityPtr + PoE2Offsets.Entity["ComponentsVec"])
        compVecLast  := this.Mem.ReadInt64(entityPtr + PoE2Offsets.Entity["ComponentsVecLast"])
        if (compVecFirst <= 0 || compVecLast < compVecFirst)
            return 0

        count := Floor((compVecLast - compVecFirst) / A_PtrSize)
        if (count < 1 || count > 256)
            return 0

        ; Scan component pointers looking for one with Render-like offsets
        Loop Min(count, 64)
        {
            compAddr := this.Mem.ReadPtr(compVecFirst + (A_Index - 1) * A_PtrSize)
            if !this.IsProbablyValidPointer(compAddr)
                continue

            ; Quick heuristic: Render component has plausible world position at offset 0x138
            testX := this.Mem.ReadFloat(compAddr + PoE2Offsets.Render["CurrentWorldPosition"])
            testY := this.Mem.ReadFloat(compAddr + PoE2Offsets.Render["CurrentWorldPositionY"])
            testZ := this.Mem.ReadFloat(compAddr + PoE2Offsets.Render["CurrentWorldPositionZ"])

            if (Abs(testX) < 0.01 && Abs(testY) < 0.01 && Abs(testZ) < 0.01)
                continue
            if (Abs(testX) > 200000 || Abs(testY) > 200000 || Abs(testZ) > 200000)
                continue

            ; Verify: terrain height should also be plausible
            terrH := this.Mem.ReadFloat(compAddr + PoE2Offsets.Render["TerrainHeight"])
            if (Abs(terrH) > 200000)
                continue

            return compAddr
        }
        return 0
    }

    ; Sets up incremental TGT tile scanning — validates terrain metadata and caches scan parameters.
    ; Returns true if setup succeeded and incremental scanning can begin.
    _SetupTgtScan(areaInstanceData)
    {
        terrainBase := areaInstanceData + PoE2Offsets.AreaInstance["TerrainMetadata"]

        totalTilesX := this.Mem.ReadInt64(terrainBase + PoE2Offsets.TerrainMetadata["TotalTilesX"])
        totalTilesY := this.Mem.ReadInt64(terrainBase + PoE2Offsets.TerrainMetadata["TotalTilesY"])
        if (totalTilesX < 1 || totalTilesX > 1000 || totalTilesY < 1 || totalTilesY > 1000)
        {
            this._zoneScanFailReason := "tiles-oob(" totalTilesX "x" totalTilesY ")"
            return false
        }

        tileVecFirst := this.Mem.ReadInt64(terrainBase + PoE2Offsets.TerrainMetadata["TileDetailsPtr"])
        tileVecLast  := this.Mem.ReadInt64(terrainBase + PoE2Offsets.TerrainMetadata["TileDetailsPtr"] + 8)
        if !this.IsProbablyValidPointer(tileVecFirst) || tileVecLast <= tileVecFirst
        {
            this._zoneScanFailReason := "vec-bad(f:" Format("0x{:X}", tileVecFirst) " l:" Format("0x{:X}", tileVecLast) ")"
            return false
        }

        tileStructSize := 0x38
        totalTiles := Floor((tileVecLast - tileVecFirst) / tileStructSize)
        if (totalTiles < 1 || totalTiles > 100000)
        {
            this._zoneScanFailReason := "count-oob(" totalTiles ")"
            return false
        }

        this._tgtScanTileIdx := 0
        this._tgtScanTotalTiles := totalTiles
        this._tgtScanTileVecFirst := tileVecFirst
        this._tgtScanTotalTilesX := totalTilesX
        this._tgtScanPartialResults := Map()
        this._zoneScanFailReason := ""
        return true
    }

    ; Processes a batch of tiles from the incremental TGT scan.
    ; Reads tile structs in bulk (one RPM call per batch) and only does individual reads for path strings.
    ; Returns true when all tiles have been processed.
    _ProcessTgtScanBatch(batchSize)
    {
        tileStructSize := 0x38
        tileToGrid := 0x17
        startIdx := this._tgtScanTileIdx
        endIdx := Min(startIdx + batchSize, this._tgtScanTotalTiles)
        results := this._tgtScanPartialResults

        ; Batch-read contiguous tile structs in one RPM call
        batchBytes := (endIdx - startIdx) * tileStructSize
        tileBatchBuf := this.Mem.ReadBytes(this._tgtScanTileVecFirst + startIdx * tileStructSize, batchBytes)
        if !tileBatchBuf
        {
            this._tgtScanTileIdx := endIdx
            return (endIdx >= this._tgtScanTotalTiles)
        }

        offTgtFilePtr := PoE2Offsets.TileStruct["TgtFilePtr"]
        offTileIdX    := PoE2Offsets.TileStruct["TileIdX"]
        offTileIdY    := PoE2Offsets.TileStruct["TileIdY"]
        offRotSel     := PoE2Offsets.TileStruct["RotationSelector"]

        Loop endIdx - startIdx
        {
            tileIdx := startIdx + A_Index - 1
            bufOff := (A_Index - 1) * tileStructSize

            tgtFilePtr := NumGet(tileBatchBuf.Ptr, bufOff + offTgtFilePtr, "Ptr")
            if !this.IsProbablyValidPointer(tgtFilePtr)
                continue

            tgtPath := this.ReadStdWStringAt(tgtFilePtr + PoE2Offsets.TgtFile["TgtPath"], 260)
            if (tgtPath = "")
                continue

            pathLower := StrLower(tgtPath)
            entType := ""
            if InStr(pathLower, "areatransition")
                entType := "AreaTransition"
            else if InStr(pathLower, "waypoint")
                entType := "Waypoint"
            else if InStr(pathLower, "checkpoint")
                entType := "Checkpoint"
            if (entType = "")
                continue

            rotSel  := NumGet(tileBatchBuf.Ptr, bufOff + offRotSel, "UChar")
            tileIdX := NumGet(tileBatchBuf.Ptr, bufOff + offTileIdX, "UChar")
            tileIdY := NumGet(tileBatchBuf.Ptr, bufOff + offTileIdY, "UChar")
            if (Mod(rotSel, 2) = 0)
                tileKey := tgtPath "x:" tileIdX "-y:" tileIdY
            else
                tileKey := tgtPath "x:" tileIdY "-y:" tileIdX

            gridX := Mod(tileIdx, this._tgtScanTotalTilesX) * tileToGrid
            gridY := Floor(tileIdx / this._tgtScanTotalTilesX) * tileToGrid

            if !results.Has(tileKey)
            {
                results[tileKey] := Map(
                    "path", tgtPath,
                    "type", entType,
                    "gridX", gridX,
                    "gridY", gridY,
                    "worldX", gridX * (250.0 / 0x17),
                    "worldY", gridY * (250.0 / 0x17),
                    "worldZ", 0
                )
            }
        }

        this._tgtScanTileIdx := endIdx
        return (endIdx >= this._tgtScanTotalTiles)
    }

    ; Legacy synchronous tile scan — kept for compatibility but prefer incremental _SetupTgtScan/_ProcessTgtScanBatch.
    ReadTgtTilesLocations(areaInstanceData)
    {
        results := Map()
        terrainBase := areaInstanceData + PoE2Offsets.AreaInstance["TerrainMetadata"]

        totalTilesX := this.Mem.ReadInt64(terrainBase + PoE2Offsets.TerrainMetadata["TotalTilesX"])
        totalTilesY := this.Mem.ReadInt64(terrainBase + PoE2Offsets.TerrainMetadata["TotalTilesY"])
        if (totalTilesX < 1 || totalTilesX > 1000 || totalTilesY < 1 || totalTilesY > 1000)
            return results

        tileVecFirst := this.Mem.ReadInt64(terrainBase + PoE2Offsets.TerrainMetadata["TileDetailsPtr"])
        tileVecLast  := this.Mem.ReadInt64(terrainBase + PoE2Offsets.TerrainMetadata["TileDetailsPtr"] + 8)
        if !this.IsProbablyValidPointer(tileVecFirst) || tileVecLast <= tileVecFirst
            return results

        tileStructSize := 0x38
        totalTiles := Floor((tileVecLast - tileVecFirst) / tileStructSize)
        if (totalTiles < 1 || totalTiles > 100000)
            return results

        tileToGrid := 0x17

        offTgtFilePtr := PoE2Offsets.TileStruct["TgtFilePtr"]
        offTileIdX    := PoE2Offsets.TileStruct["TileIdX"]
        offTileIdY    := PoE2Offsets.TileStruct["TileIdY"]
        offRotSel     := PoE2Offsets.TileStruct["RotationSelector"]

        ; Process in chunks to use batch reads
        chunkSize := 2000
        tileIdx := 0
        while (tileIdx < totalTiles)
        {
            chunkEnd := Min(tileIdx + chunkSize, totalTiles)
            chunkBytes := (chunkEnd - tileIdx) * tileStructSize
            chunkBuf := this.Mem.ReadBytes(tileVecFirst + tileIdx * tileStructSize, chunkBytes)
            if !chunkBuf
            {
                tileIdx := chunkEnd
                continue
            }

            Loop chunkEnd - tileIdx
            {
                curIdx := tileIdx + A_Index - 1
                bufOff := (A_Index - 1) * tileStructSize

                tgtFilePtr := NumGet(chunkBuf.Ptr, bufOff + offTgtFilePtr, "Ptr")
                if !this.IsProbablyValidPointer(tgtFilePtr)
                    continue

                tgtPath := this.ReadStdWStringAt(tgtFilePtr + PoE2Offsets.TgtFile["TgtPath"], 260)
                if (tgtPath = "")
                    continue

                pathLower := StrLower(tgtPath)
                entType := ""
                if InStr(pathLower, "areatransition")
                    entType := "AreaTransition"
                else if InStr(pathLower, "waypoint")
                    entType := "Waypoint"
                else if InStr(pathLower, "checkpoint")
                    entType := "Checkpoint"
                if (entType = "")
                    continue

                rotSel  := NumGet(chunkBuf.Ptr, bufOff + offRotSel, "UChar")
                tileIdX := NumGet(chunkBuf.Ptr, bufOff + offTileIdX, "UChar")
                tileIdY := NumGet(chunkBuf.Ptr, bufOff + offTileIdY, "UChar")
                if (Mod(rotSel, 2) = 0)
                    tileKey := tgtPath "x:" tileIdX "-y:" tileIdY
                else
                    tileKey := tgtPath "x:" tileIdY "-y:" tileIdX

                gridX := Mod(curIdx, totalTilesX) * tileToGrid
                gridY := Floor(curIdx / totalTilesX) * tileToGrid

                if !results.Has(tileKey)
                {
                    results[tileKey] := Map(
                        "path", tgtPath,
                        "type", entType,
                        "gridX", gridX,
                        "gridY", gridY,
                        "worldX", gridX * (250.0 / 0x17),
                        "worldY", gridY * (250.0 / 0x17),
                        "worldZ", 0
                    )
                }
            }
            tileIdx := chunkEnd
        }
        return results
    }

    ; Cheap per-tick update of a cached entity's volatile fields (position, life, targetable, flags).
    ; Used by the persistent radar cache: avoids the expensive full ReadEntityBasic + component lookup
    ; for entities that are already known. Reads ~10 values instead of ~50+.
    ; Params:
    ;   cachedEntry - the sampleEntry Map from the cache (modified in-place)
    ;   playerOrigin - {x,y,z} Map for distance/plausibility checks
    ; Returns: true if update succeeded, false if entity appears invalid (should re-decode)
    UpdateCachedEntityRadar(cachedEntry, playerOrigin := 0)
    {
        entity := cachedEntry.Has("entity") ? cachedEntry["entity"] : 0
        if !(entity && Type(entity) = "Map")
            return false

        entityPtr := entity.Has("address") ? entity["address"] : 0
        if !this.IsProbablyValidPointer(entityPtr)
            return false

        ; Update flags / isValid
        flags := this.Mem.ReadUChar(entityPtr + PoE2Offsets.Entity["Flags"])
        entity["flags"] := flags
        entity["isValid"] := (flags & 0x01) = 0 ? true : false

        dc := entity.Has("decodedComponents") ? entity["decodedComponents"] : 0
        if !(dc && Type(dc) = "Map")
            return false

        ; Update render position + terrain height — single RPM call for the range 0x138..0x1B4
        renderComp := dc.Has("render") ? dc["render"] : 0
        if (renderComp && Type(renderComp) = "Map" && renderComp.Has("address"))
        {
            compAddr := renderComp["address"]
            if this.IsProbablyValidPointer(compAddr)
            {
                static renderBaseOff := PoE2Offsets.Render["CurrentWorldPosition"]
                static terrainOff    := PoE2Offsets.Render["TerrainHeight"]
                static renderSpan    := terrainOff - renderBaseOff + 4  ; 0x1B0 - 0x138 + 4 = 0x7C
                static terrainLocal  := terrainOff - renderBaseOff      ; 0x78

                renderBuf := this.Mem.ReadBytes(compAddr + renderBaseOff, renderSpan)
                if renderBuf
                {
                    worldX := NumGet(renderBuf.Ptr, 0, "Float")
                    worldY := NumGet(renderBuf.Ptr, 4, "Float")
                    worldZ := NumGet(renderBuf.Ptr, 8, "Float")
                    terrainHeight := NumGet(renderBuf.Ptr, terrainLocal, "Float")

                    if (Abs(worldX) <= 200000 && Abs(worldY) <= 200000 && Abs(worldZ) <= 200000
                        && !(Abs(worldX) < 0.01 && Abs(worldY) < 0.01 && Abs(worldZ) < 0.01))
                    {
                        wp := renderComp.Has("worldPosition") ? renderComp["worldPosition"] : Map()
                        wp["x"] := worldX
                        wp["y"] := worldY
                        wp["z"] := worldZ
                        renderComp["worldPosition"] := wp
                        renderComp["terrainHeight"] := terrainHeight

                        worldToGridRatio := 250.0 / 0x17
                        gp := renderComp.Has("gridPosition") ? renderComp["gridPosition"] : Map()
                        gp["x"] := worldX / worldToGridRatio
                        gp["y"] := worldY / worldToGridRatio
                        renderComp["gridPosition"] := gp
                    }
                }
            }
        }

        ; Update life — batch-read Max+Current (8 bytes) in one RPM call
        lifeComp := dc.Has("life") ? dc["life"] : 0
        if (lifeComp && Type(lifeComp) = "Map" && lifeComp.Has("address"))
        {
            lifeAddr := lifeComp["address"]
            if this.IsProbablyValidPointer(lifeAddr)
            {
                healthBase := lifeAddr + PoE2Offsets.Life["Health"]
                lifeBuf := this.Mem.ReadBytes(healthBase + PoE2Offsets.Vital["Max"], 8)
                if lifeBuf
                {
                    maxHP := NumGet(lifeBuf.Ptr, 0, "Int")
                    curHP := NumGet(lifeBuf.Ptr, 4, "Int")
                    lifeComp["curHP"] := curHP
                    lifeComp["maxHP"] := maxHP
                    lifeComp["isAlive"] := (curHP > 0 && maxHP > 0)
                }
            }
        }

        ; Update targetable only for monsters (non-monsters don't change targetability; saves 1 RPM)
        isMonster := entity.Has("path") && InStr(StrLower(entity["path"]), "metadata/monsters/")
        if isMonster
        {
            comps := entity.Has("components") ? entity["components"] : 0
            if (comps && Type(comps) = "Array")
            {
                for _, comp in comps
                {
                    if !(comp && Type(comp) = "Map" && comp.Has("name") && comp.Has("address"))
                        continue
                    cName := comp["name"]
                    if (InStr(cName, "Targetable") || cName = "Targetable")
                    {
                        tgtAddr := comp["address"]
                        if (tgtAddr && this.IsProbablyValidPointer(tgtAddr))
                        {
                            raw := this.Mem.ReadUChar(tgtAddr + PoE2Offsets.Targetable["IsTargetable"])
                            dc["targetable"] := (raw = 1)
                        }
                        break
                    }
                }
            }
        }

        ; Update distance from player
        entityPos := this.ExtractEntityWorldPositionFromEntityBasic(entity, playerOrigin)
        if entityPos
            cachedEntry["distance"] := this.ComputeDistance3DFromMaps(playerOrigin, entityPos)

        return true
    }

}