; PoE2PlayerComponentsReader.ahk
; Player component reader layer — extends PoE2EntityReader.
;
; Reads individual player components: ServerData, Positioned, Actor, Render,
; Animated, Transitionable, StateMachine, and std::string/vector helpers.
;
; Inheritance chain: PoE2GameStateReader -> ... -> PoE2PlayerComponentsReader -> PoE2EntityReader

class PoE2PlayerComponentsReader extends PoE2EntityReader
{
    ; Validates a server-data pointer by checking the embedded PlayerServerData vector
    ; for plausible first/last bounds, pointer-aligned byte count, and count in [1, 128].
    ; Returns: true if the pointer looks like a real ServerData pointer
    IsPlausibleServerDataPointer(serverDataPtr)
    {
        if !this.IsProbablyValidPointer(serverDataPtr)
            return false

        vecFirst := this.Mem.ReadInt64(serverDataPtr + PoE2Offsets.ServerData["PlayerServerData"])
        vecLast := this.Mem.ReadInt64(serverDataPtr + PoE2Offsets.ServerData["PlayerServerDataLast"])
        if (vecFirst <= 0 || vecLast < vecFirst)
            return false

        bytes := vecLast - vecFirst
        if (Mod(bytes, A_PtrSize) != 0)
            return false

        count := Floor(bytes / A_PtrSize)
        return (count > 0 && count <= 128)
    }

    ; Walks a fallback chain to find the real ServerData pointer.
    ; Probes rawServerDataPtr plus small offsets (0x00–0x20) from playerInfoPtr,
    ; returning the first candidate that passes IsPlausibleServerDataPointer.
    ResolveServerDataPointer(playerInfoPtr, rawServerDataPtr)
    {
        if !this.IsProbablyValidPointer(playerInfoPtr)
            return rawServerDataPtr

        candidates := []
        if this.IsProbablyValidPointer(rawServerDataPtr)
            candidates.Push(rawServerDataPtr)

        probeOffsets := [0x00, 0x08, 0x10, 0x18, 0x20]
        for _, off in probeOffsets
        {
            p := this.Mem.ReadPtr(playerInfoPtr + off)
            if this.IsProbablyValidPointer(p)
                candidates.Push(p)
        }

        seen := Map()
        for _, candidate in candidates
        {
            key := candidate ""
            if seen.Has(key)
                continue
            seen[key] := true

            if this.IsPlausibleServerDataPointer(candidate)
                return candidate
        }

        return rawServerDataPtr
    }

    ; Scans the area entity map to locate the local player entity.
    ; Identifies the player by the presence of a valid "Player" component.
    ; Params: areaInstanceAddress - pointer to the current AreaInstance
    ; Returns: entity pointer, or 0 if not found
    FindLocalPlayerEntityFromArea(areaInstanceAddress, maxScan := 128)
    {
        if !this.IsProbablyValidPointer(areaInstanceAddress)
            return 0

        entityListOffset := this.ResolveEntityListOffset(areaInstanceAddress)
        awakeSummary := this.ReadAreaEntityMapSummary(areaInstanceAddress + entityListOffset, maxScan)
        if !(awakeSummary && awakeSummary.Has("sample"))
            return 0

        sample := awakeSummary["sample"]
        if !(sample && Type(sample) = "Array")
            return 0

        for _, entry in sample
        {
            if !(entry && Type(entry) = "Map" && entry.Has("entityPtr"))
                continue

            candidateRaw := entry["entityPtr"]
            candidate := this.ResolveEntityPointer(candidateRaw)
            if !this.IsPlausibleEntityPointer(candidate)
                continue

            playerComp := this.FindEntityComponentAddress(candidate, "Player")
            if this.IsProbablyValidPointer(playerComp)
                return candidate
        }

        return 0
    }

    ; Reads charge data from a Charges component and validates plausibility via score.
    ; Computes remainingUses as floor(current / perUse) when perUse > 0.
    ; Returns: Map with current, perUse, remainingUses, score; or 0 if score < 2
    BuildChargesComponentSnapshot(componentPtr)
    {
        if !this.IsProbablyValidPointer(componentPtr)
            return 0

        chargesInternalPtr := this.Mem.ReadPtr(componentPtr + PoE2Offsets.Charges["ChargesInternalPtr"])
        current := this.Mem.ReadInt(componentPtr + PoE2Offsets.Charges["Current"])
        perUse := this.IsProbablyValidPointer(chargesInternalPtr)
            ? this.Mem.ReadInt(chargesInternalPtr + PoE2Offsets.ChargesInternal["PerUseCharges"])
            : 0

        score := 0
        if (current >= 0 && current <= 100000)
            score += 1
        if (perUse >= 0 && perUse <= 100000)
            score += 1
        if (this.IsProbablyValidPointer(chargesInternalPtr))
            score += 1
        if (current > 0 || perUse > 0)
            score += 1

        if (score < 2)
            return 0

        ; Cache the StaticPtr for Charges type identification in inventory items
        if (!this._chargesStaticPtr)
        {
            sp := this.Mem.ReadPtr(componentPtr + PoE2Offsets.ComponentHeader["StaticPtr"])
            if this.IsProbablyValidPointer(sp)
                this._chargesStaticPtr := sp
        }

        remainingUses := (perUse > 0) ? Floor(current / perUse) : 0
        return Map(
            "address", componentPtr,
            "chargesInternalPtr", chargesInternalPtr,
            "current", current,
            "perUse", perUse,
            "remainingUses", remainingUses,
            "score", score
        )
    }

    ; Finds the Positioned component for the local player by matching owner entity pointer.
    ; Validates the reaction byte (must be <= 0x7F) and derives isFriendly from bit 0.
    ; Returns: Map with address, reaction, isFriendly; or 0 if not found
    ReadPlayerPositionedComponent(localPlayerPtr)
    {
        if !this.IsProbablyValidPointer(localPlayerPtr)
            return 0

        compVecFirst := this.Mem.ReadInt64(localPlayerPtr + PoE2Offsets.Entity["ComponentsVec"])
        compVecLast := this.Mem.ReadInt64(localPlayerPtr + PoE2Offsets.Entity["ComponentsVecLast"])
        if (compVecFirst <= 0 || compVecLast < compVecFirst)
            return 0

        ptrSize := A_PtrSize
        componentCount := Floor((compVecLast - compVecFirst) / ptrSize)
        maxEntries := Min(componentCount, 96)

        idx := 0
        while (idx < maxEntries)
        {
            componentPtr := this.Mem.ReadPtr(compVecFirst + (idx * ptrSize))
            if this.IsProbablyValidPointer(componentPtr)
            {
                ownerEntityPtr := this.Mem.ReadPtr(componentPtr + PoE2Offsets.ComponentHeader["EntityPtr"])
                if (ownerEntityPtr = localPlayerPtr)
                {
                    reaction := this.Mem.ReadUChar(componentPtr + PoE2Offsets.Positioned["Reaction"])
                    plausible := (reaction <= 0x7F)
                    if (plausible)
                    {
                        isFriendly := (reaction & 0x7F) = 0x01
                        return Map(
                            "address", componentPtr,
                            "reaction", reaction,
                            "isFriendly", isFriendly ? true : false
                        )
                    }
                }
            }
            idx += 1
        }

        return 0
    }

    ; Finds and decodes the Actor component for the local player entity.
    ; Only returns a result when at least one of activeSkillsCount, cooldownsCount,
    ; or deployedCount is greater than zero.
    ; Returns: decoded Actor Map or 0 if not found or all counts are zero
    ReadPlayerActorComponentBasic(localPlayerPtr)
    {
        if !this.IsProbablyValidPointer(localPlayerPtr)
            return 0

        compVecFirst := this.Mem.ReadInt64(localPlayerPtr + PoE2Offsets.Entity["ComponentsVec"])
        compVecLast := this.Mem.ReadInt64(localPlayerPtr + PoE2Offsets.Entity["ComponentsVecLast"])
        if (compVecFirst <= 0 || compVecLast < compVecFirst)
            return 0

        ptrSize := A_PtrSize
        componentCount := Floor((compVecLast - compVecFirst) / ptrSize)
        maxEntries := Min(componentCount, 96)

        idx := 0
        while (idx < maxEntries)
        {
            componentPtr := this.Mem.ReadPtr(compVecFirst + (idx * ptrSize))
            if this.IsProbablyValidPointer(componentPtr)
            {
                ownerEntityPtr := this.Mem.ReadPtr(componentPtr + PoE2Offsets.ComponentHeader["EntityPtr"])
                if (ownerEntityPtr = localPlayerPtr)
                {
                    decoded := this.DecodeActorComponentBasic(componentPtr)
                    if (decoded)
                    {
                        if (decoded["activeSkillsCount"] > 0
                            || decoded["cooldownsCount"] > 0
                            || decoded["deployedCount"] > 0)
                            return decoded
                    }
                }
            }
            idx += 1
        }

        return 0
    }

    ; Reads full skill data from the Actor component of the local player.
    ; Uses FindEntityComponentAddress("Actor") for reliable lookup.
    ; Returns: Map with skills, cooldowns, deployedCounts — or 0 if not found
    ReadPlayerSkills(localPlayerPtr)
    {
        if !this.IsProbablyValidPointer(localPlayerPtr)
            return 0

        actorPtr := this.FindEntityComponentAddress(localPlayerPtr, "Actor")
        if !this.IsProbablyValidPointer(actorPtr)
            return 0

        return this.DecodeActorSkills(actorPtr)
    }

    ; Finds and reads the Render component for the local player entity.
    ; Tries a named-component lookup first; falls back to a scored scan that prefers
    ; non-zero world positions over zero vectors.
    ; Returns: Map with worldPosition, gridPosition, modelBounds, terrainHeight, score
    ReadPlayerRenderComponent(localPlayerPtr)
    {
        if !this.IsProbablyValidPointer(localPlayerPtr)
            return 0

        renderByLookup := this.FindEntityComponentAddress(localPlayerPtr, "Render")
        if this.IsProbablyValidPointer(renderByLookup)
        {
            decoded := this.DecodeRenderComponent(renderByLookup)
            if (decoded)
            {
                worldPosition := decoded["worldPosition"]
                modelBounds := decoded["modelBounds"]
                terrainHeight := decoded["terrainHeight"]

                isZeroVector := (Abs(worldPosition["x"]) < 0.001)
                    && (Abs(worldPosition["y"]) < 0.001)
                    && (Abs(worldPosition["z"]) < 0.001)
                    && (Abs(terrainHeight) < 0.001)

                score := 0
                if (!isZeroVector)
                    score += 4
                if (Abs(worldPosition["x"]) > 0.01)
                    score += 1
                if (Abs(worldPosition["y"]) > 0.01)
                    score += 1
                if (Abs(worldPosition["z"]) > 0.01)
                    score += 1
                if (Abs(modelBounds["x"]) > 0.001 || Abs(modelBounds["y"]) > 0.001 || Abs(modelBounds["z"]) > 0.001)
                    score += 1

                decoded["score"] := score
                decoded["source"] := "component-lookup"
                decoded["isZeroVector"] := isZeroVector
                return decoded
            }
        }

        compVecFirst := this.Mem.ReadInt64(localPlayerPtr + PoE2Offsets.Entity["ComponentsVec"])
        compVecLast := this.Mem.ReadInt64(localPlayerPtr + PoE2Offsets.Entity["ComponentsVecLast"])
        if (compVecFirst <= 0 || compVecLast < compVecFirst)
            return 0

        ptrSize := A_PtrSize
        componentCount := Floor((compVecLast - compVecFirst) / ptrSize)
        maxEntries := Min(componentCount, 96)

        best := 0
        bestScore := -1
        bestZero := 0
        idx := 0
        while (idx < maxEntries)
        {
            componentPtr := this.Mem.ReadPtr(compVecFirst + (idx * ptrSize))
            if this.IsProbablyValidPointer(componentPtr)
            {
                ownerEntityPtr := this.Mem.ReadPtr(componentPtr + PoE2Offsets.ComponentHeader["EntityPtr"])
                if (ownerEntityPtr = localPlayerPtr)
                {
                    worldX := this.Mem.ReadFloat(componentPtr + PoE2Offsets.Render["CurrentWorldPosition"])
                    worldY := this.Mem.ReadFloat(componentPtr + PoE2Offsets.Render["CurrentWorldPositionY"])
                    worldZ := this.Mem.ReadFloat(componentPtr + PoE2Offsets.Render["CurrentWorldPositionZ"])
                    boundsX := this.Mem.ReadFloat(componentPtr + PoE2Offsets.Render["CharacterModelBounds"])
                    boundsY := this.Mem.ReadFloat(componentPtr + PoE2Offsets.Render["CharacterModelBoundsY"])
                    boundsZ := this.Mem.ReadFloat(componentPtr + PoE2Offsets.Render["CharacterModelBoundsZ"])
                    terrainHeight := this.Mem.ReadFloat(componentPtr + PoE2Offsets.Render["TerrainHeight"])

                    score := 0
                    if (Abs(worldX) <= 200000)
                        score += 1
                    if (Abs(worldY) <= 200000)
                        score += 1
                    if (Abs(worldZ) <= 200000)
                        score += 1
                    if (Abs(terrainHeight) <= 200000)
                        score += 1
                    if (Abs(boundsX) <= 100000)
                        score += 1
                    if (Abs(boundsY) <= 100000)
                        score += 1
                    if (Abs(boundsZ) <= 100000)
                        score += 1

                    if (score >= 6)
                    {
                        worldToGridRatio := 250.0 / 0x17
                        gridX := worldX / worldToGridRatio
                        gridY := worldY / worldToGridRatio

                        isZeroVector := (Abs(worldX) < 0.001)
                            && (Abs(worldY) < 0.001)
                            && (Abs(worldZ) < 0.001)
                            && (Abs(terrainHeight) < 0.001)

                        candidate := Map(
                            "address", componentPtr,
                            "worldPosition", Map("x", worldX, "y", worldY, "z", worldZ),
                            "gridPosition", Map("x", gridX, "y", gridY),
                            "modelBounds", Map("x", boundsX, "y", boundsY, "z", boundsZ),
                            "terrainHeight", terrainHeight,
                            "score", score,
                            "source", "component-scan",
                            "isZeroVector", isZeroVector
                        )

                        if (isZeroVector)
                        {
                            if (!bestZero)
                                bestZero := candidate
                        }
                        else
                        {
                            quality := score
                            if (Abs(worldX) > 0.01)
                                quality += 2
                            if (Abs(worldY) > 0.01)
                                quality += 2
                            if (Abs(worldZ) > 0.01)
                                quality += 1
                            if (Abs(terrainHeight) > 0.01)
                                quality += 1

                            if (quality > bestScore)
                            {
                                bestScore := quality
                                best := candidate
                            }
                        }
                    }
                }
            }
            idx += 1
        }

        if (best)
            return best

        return bestZero ? bestZero : 0
    }

    ; Finds the Animated component for the local player and reads its sub-entity.
    ; Validates that animatedEntityPtr is in heap range (< 0x7FF000000000) before use.
    ; Returns: Map with animatedEntityPtr, path, id; or 0 if not found
    ReadPlayerAnimatedComponent(localPlayerPtr)
    {
        if !this.IsProbablyValidPointer(localPlayerPtr)
            return 0

        compVecFirst := this.Mem.ReadInt64(localPlayerPtr + PoE2Offsets.Entity["ComponentsVec"])
        compVecLast := this.Mem.ReadInt64(localPlayerPtr + PoE2Offsets.Entity["ComponentsVecLast"])
        if (compVecFirst <= 0 || compVecLast < compVecFirst)
            return 0

        ptrSize := A_PtrSize
        componentCount := Floor((compVecLast - compVecFirst) / ptrSize)
        maxEntries := Min(componentCount, 96)

        idx := 0
        while (idx < maxEntries)
        {
            componentPtr := this.Mem.ReadPtr(compVecFirst + (idx * ptrSize))
            if this.IsProbablyValidPointer(componentPtr)
            {
                ownerEntityPtr := this.Mem.ReadPtr(componentPtr + PoE2Offsets.ComponentHeader["EntityPtr"])
                if (ownerEntityPtr = localPlayerPtr)
                {
                    animatedEntityPtr := this.Mem.ReadPtr(componentPtr + PoE2Offsets.Animated["AnimatedEntityPtr"])
                    ; Only treat as valid entity if it's in heap range (not executable/DLL memory)
                    if this.IsProbablyValidPointer(animatedEntityPtr) && (animatedEntityPtr < 0x7FF000000000)
                    {
                        entityId := this.Mem.ReadUInt(animatedEntityPtr + PoE2Offsets.Entity["Id"])
                        entityDetailsPtr := this.Mem.ReadPtr(animatedEntityPtr + PoE2Offsets.Entity["EntityDetailsPtr"])

                        path := ""
                        if this.IsProbablyValidPointer(entityDetailsPtr)
                            path := this.ReadStdWStringAt(entityDetailsPtr + PoE2Offsets.EntityDetails["Path"])

                        if (path != "" || entityId > 0)
                        {
                            return Map(
                                "address", componentPtr,
                                "animatedEntityPtr", animatedEntityPtr,
                                "path", path,
                                "id", entityId
                            )
                        }
                    }
                }
            }
            idx += 1
        }

        return 0
    }

    ; Finds and reads the Transitionable component for the local player.
    ; Scores each candidate by currentState plausibility and returns the best match.
    ; Returns: Map with address, currentState, score; or 0 if bestScore < 1
    ReadPlayerTransitionableComponent(localPlayerPtr)
    {
        if !this.IsProbablyValidPointer(localPlayerPtr)
            return 0

        compVecFirst := this.Mem.ReadInt64(localPlayerPtr + PoE2Offsets.Entity["ComponentsVec"])
        compVecLast := this.Mem.ReadInt64(localPlayerPtr + PoE2Offsets.Entity["ComponentsVecLast"])
        if (compVecFirst <= 0 || compVecLast < compVecFirst)
            return 0

        ptrSize := A_PtrSize
        componentCount := Floor((compVecLast - compVecFirst) / ptrSize)
        maxEntries := Min(componentCount, 96)

        best := 0
        bestScore := -1
        idx := 0
        while (idx < maxEntries)
        {
            componentPtr := this.Mem.ReadPtr(compVecFirst + (idx * ptrSize))
            if this.IsProbablyValidPointer(componentPtr)
            {
                ownerEntityPtr := this.Mem.ReadPtr(componentPtr + PoE2Offsets.ComponentHeader["EntityPtr"])
                if (ownerEntityPtr = localPlayerPtr)
                {
                    currentState := this.Mem.ReadShort(componentPtr + PoE2Offsets.Transitionable["CurrentState"])
                    score := 0

                    if (currentState >= -1 && currentState <= 512)
                        score += 1

                    if (score > bestScore)
                    {
                        bestScore := score
                        best := Map(
                            "address", componentPtr,
                            "currentState", currentState,
                            "score", score
                        )

                        if (score = 1)
                            break
                    }
                }
            }
            idx += 1
        }

        return (bestScore >= 1) ? best : 0
    }

    ; Finds and reads the StateMachine component for the local player.
    ; Collects all state slot values and resolves the current state index to a name.
    ; Returns: Map with currentState, states, statesSummary; or 0 if score < 2
    ReadPlayerStateMachineComponent(localPlayerPtr)
    {
        if !this.IsProbablyValidPointer(localPlayerPtr)
            return 0

        compVecFirst := this.Mem.ReadInt64(localPlayerPtr + PoE2Offsets.Entity["ComponentsVec"])
        compVecLast  := this.Mem.ReadInt64(localPlayerPtr + PoE2Offsets.Entity["ComponentsVecLast"])
        if (compVecFirst <= 0 || compVecLast < compVecFirst)
            return 0

        ptrSize        := A_PtrSize
        componentCount := Floor((compVecLast - compVecFirst) / ptrSize)
        maxEntries     := Min(componentCount, 96)

        best      := 0
        bestScore := -1
        idx       := 0
        while (idx < maxEntries)
        {
            componentPtr := this.Mem.ReadPtr(compVecFirst + (idx * ptrSize))
            if this.IsProbablyValidPointer(componentPtr)
            {
                ownerEntityPtr := this.Mem.ReadPtr(componentPtr + PoE2Offsets.ComponentHeader["EntityPtr"])
                if (ownerEntityPtr = localPlayerPtr)
                {
                    currentState := this.Mem.ReadShort(componentPtr + PoE2Offsets.Transitionable["CurrentState"])
                    statesPtr    := this.Mem.ReadPtr(componentPtr + PoE2Offsets.StateMachine["StatesPtr"])
                    vecFirst     := this.Mem.ReadInt64(componentPtr + PoE2Offsets.StateMachine["StatesValues"])
                    vecLast      := this.Mem.ReadInt64(componentPtr + PoE2Offsets.StateMachine["StatesValuesLast"])

                    score := 0
                    if (this.IsProbablyValidPointer(statesPtr))
                        score += 1
                    if (vecFirst > 0 && vecLast >= vecFirst)
                        score += 1

                    stateData          := this.CollectStateMachineStateValues(vecFirst, vecLast, statesPtr)
                    values             := stateData["values"]
                    stateCount         := stateData["stateCount"]
                    resolvedNamesCount := stateData["resolvedNamesCount"]

                    if (stateCount > 0 && stateCount <= 128)
                        score += 1

                    currentStateName := ""
                    if (currentState >= 0)
                    {
                        rawCurrentName   := ""
                        currentStateName := this.ResolveStateMachineStateName(statesPtr, currentState, &rawCurrentName)
                    }

                    statesSummary := this.BuildStateMachineSummary(values, currentState)

                    if (score > bestScore)
                    {
                        bestScore := score
                        best := Map(
                            "address",             componentPtr,
                            "currentState",        currentState,
                            "currentStateName",    currentStateName,
                            "statesPtr",           statesPtr,
                            "stateCount",          stateCount,
                            "resolvedNamesCount",  resolvedNamesCount,
                            "states",              values,
                            "statesSummary",       statesSummary,
                            "score",               score
                        )

                        if (score >= 3)
                            break
                    }
                }
            }
            idx += 1
        }

        return (bestScore >= 2) ? best : 0
    }

    ; Iterates a C++ vector of 8-byte state value slots and resolves each to a name.
    ; Caps reads at 128 entries; falls back to "state_N" for unresolvable indices.
    ; Returns: Map with stateCount, resolvedNamesCount, and values array
    CollectStateMachineStateValues(vecFirst, vecLast, statesPtr)
    {
        values             := []
        stateCount         := 0
        resolvedNamesCount := 0

        if (vecFirst <= 0 || vecLast < vecFirst || vecLast - vecFirst < 8)
            return Map("stateCount", 0, "resolvedNamesCount", 0, "values", values)

        totalBytes := vecLast - vecFirst
        maxBytes   := 8 * 128
        if (totalBytes > maxBytes)
            totalBytes := maxBytes

        bytesCount := Floor(totalBytes / 8) * 8
        stateCount := Floor(bytesCount / 8)

        offset := 0
        while (offset < bytesCount)
        {
            val        := this.Mem.ReadInt64(vecFirst + offset)
            stateIndex := Floor(offset / 8)
            rawName    := ""
            stateName  := this.ResolveStateMachineStateName(statesPtr, stateIndex, &rawName)
            if (stateName = "")
                stateName := "state_" stateIndex
            else
                resolvedNamesCount += 1

            values.Push(Map("name", stateName, "rawName", rawName, "value", val))
            offset += 8
        }

        return Map("stateCount", stateCount, "resolvedNamesCount", resolvedNamesCount, "values", values)
    }

    ; Builds a human-readable summary of state machine slot values.
    ; Collects active (non-zero) states and top-N by absolute value via insertion sort.
    ; Returns: Map with totalCount, activeStates, topAbsStates, currentStateValue, etc.
    BuildStateMachineSummary(statesValues, currentState := -1, topAbsSize := 6, activeSampleSize := 8)
    {
        totalCount := 0
        nonZeroCount := 0
        positiveCount := 0
        negativeCount := 0
        zeroCount := 0
        sumValues := 0

        currentStateValue := 0
        hasCurrentStateValue := false

        activeStates := []
        topAbsStates := []

        if !(statesValues && Type(statesValues) = "Array")
        {
            return Map(
                "totalCount", 0,
                "nonZeroCount", 0,
                "positiveCount", 0,
                "negativeCount", 0,
                "zeroCount", 0,
                "sumValues", 0,
                "hasCurrentStateValue", false,
                "currentStateValue", 0,
                "activeStates", activeStates,
                "topAbsStates", topAbsStates
            )
        }

        for idx, state in statesValues
        {
            if !(state && Type(state) = "Map" && state.Has("value"))
                continue

            val := state["value"]
            name := state.Has("name") ? state["name"] : ""
            rawName := state.Has("rawName") ? state["rawName"] : ""
            stateIndex := idx - 1

            totalCount += 1
            sumValues += val

            if (val > 0)
            {
                nonZeroCount += 1
                positiveCount += 1
            }
            else if (val < 0)
            {
                nonZeroCount += 1
                negativeCount += 1
            }
            else
            {
                zeroCount += 1
            }

            if (stateIndex = currentState)
            {
                currentStateValue := val
                hasCurrentStateValue := true
            }

            if (val != 0 && activeStates.Length < activeSampleSize)
            {
                activeStates.Push(Map(
                    "index", stateIndex,
                    "name", name,
                    "rawName", rawName,
                    "value", val
                ))
            }

            absVal := Abs(val)
            entry := Map(
                "index", stateIndex,
                "name", name,
                "rawName", rawName,
                "value", val,
                "absValue", absVal
            )

            inserted := false
            insertIdx := 1
            while (insertIdx <= topAbsStates.Length)
            {
                if (absVal > topAbsStates[insertIdx]["absValue"])
                {
                    topAbsStates.InsertAt(insertIdx, entry)
                    inserted := true
                    break
                }
                insertIdx += 1
            }

            if !inserted && (topAbsStates.Length < topAbsSize)
                topAbsStates.Push(entry)

            if (topAbsStates.Length > topAbsSize)
                topAbsStates.Pop()
        }

        return Map(
            "totalCount", totalCount,
            "nonZeroCount", nonZeroCount,
            "positiveCount", positiveCount,
            "negativeCount", negativeCount,
            "zeroCount", zeroCount,
            "sumValues", sumValues,
            "hasCurrentStateValue", hasCurrentStateValue,
            "currentStateValue", currentStateValue,
            "activeStates", activeStates,
            "topAbsStates", topAbsStates
        )
    }

    ; Resolves a state machine state name using the correct two-level indirection.
    ; Layout (from C# source):
    ;   statesPtr (at component+0x158) → read ptr at +0x10 → stateNamesBase
    ;   stateNamesBase + index * 0xC0  → StdString { Buffer@0x00, ReservedBytes@0x08, Length@0x10, Capacity@0x18 }
    ;   If Capacity <= 15: string stored in-place at Buffer field; else Buffer is a heap pointer.
    ResolveStateMachineStateName(statesPtr, stateIndex, &rawName := "")
    {
        rawName := ""
        if !this.IsProbablyValidPointer(statesPtr) || stateIndex < 0 || stateIndex > 1024
            return ""

        stateNamesBase := this.Mem.ReadPtr(statesPtr + 0x10)
        if !this.IsProbablyValidPointer(stateNamesBase)
            return ""

        stdStringAddr := stateNamesBase + (stateIndex * 0xC0)
        name := this.ReadStdStringFromAddr(stdStringAddr)
        rawName := name
        return name
    }

    ; Reads a C++ std::string with short-string optimisation (SSO) support.
    ; Capacity <= 15 means bytes are stored inline at stdStringAddr (no heap pointer).
    ; Returns: decoded narrow string, or empty string on failure
    ReadStdStringFromAddr(stdStringAddr)
    {
        if !this.IsProbablyValidPointer(stdStringAddr)
            return ""

        length   := this.Mem.ReadInt(stdStringAddr + 0x10)
        capacity := this.Mem.ReadInt(stdStringAddr + 0x18)

        if (length <= 0 || length > 512)
            return ""

        maxRead := Min(length + 1, 512)

        if (capacity <= 15)
            return this.ReadNarrowString(stdStringAddr, maxRead)

        bufPtr := this.Mem.ReadPtr(stdStringAddr)
        if !this.IsProbablyValidPointer(bufPtr)
            return ""
        return this.ReadNarrowString(bufPtr, maxRead)
    }

    ; Finds and reads the Targetable component for the local player entity.
    ; Validates all seven flag bytes and returns the highest-scoring candidate.
    ; Returns: Map with isTargetable, isHighlightable, hiddenFromPlayer flags; or 0
    ReadPlayerTargetableComponent(localPlayerPtr)
    {
        if !this.IsProbablyValidPointer(localPlayerPtr)
            return 0

        compVecFirst := this.Mem.ReadInt64(localPlayerPtr + PoE2Offsets.Entity["ComponentsVec"])
        compVecLast := this.Mem.ReadInt64(localPlayerPtr + PoE2Offsets.Entity["ComponentsVecLast"])
        if (compVecFirst <= 0 || compVecLast < compVecFirst)
            return 0

        ptrSize := A_PtrSize
        componentCount := Floor((compVecLast - compVecFirst) / ptrSize)
        maxEntries := Min(componentCount, 96)

        best := 0
        bestScore := -1
        idx := 0
        while (idx < maxEntries)
        {
            componentPtr := this.Mem.ReadPtr(compVecFirst + (idx * ptrSize))
            if this.IsProbablyValidPointer(componentPtr)
            {
                ownerEntityPtr := this.Mem.ReadPtr(componentPtr + PoE2Offsets.ComponentHeader["EntityPtr"])
                if (ownerEntityPtr = localPlayerPtr)
                {
                    isTargetableRaw := this.Mem.ReadUChar(componentPtr + PoE2Offsets.Targetable["IsTargetable"])
                    isHighlightableRaw := this.Mem.ReadUChar(componentPtr + PoE2Offsets.Targetable["IsHighlightable"])
                    isTargetedByPlayerRaw := this.Mem.ReadUChar(componentPtr + PoE2Offsets.Targetable["IsTargetedByPlayer"])
                    meetsQuestStateRaw := this.Mem.ReadUChar(componentPtr + PoE2Offsets.Targetable["MeetsQuestState"])
                    needsTrueRaw := this.Mem.ReadUChar(componentPtr + PoE2Offsets.Targetable["NeedsTrue"])
                    hiddenFromPlayerRaw := this.Mem.ReadUChar(componentPtr + PoE2Offsets.Targetable["HiddenFromPlayer"])
                    needsFalseRaw := this.Mem.ReadUChar(componentPtr + PoE2Offsets.Targetable["NeedsFalse"])

                    score := 0
                    if (isTargetableRaw <= 1)
                        score += 1
                    if (isHighlightableRaw <= 1)
                        score += 1
                    if (isTargetedByPlayerRaw <= 1)
                        score += 1
                    if (meetsQuestStateRaw <= 1)
                        score += 1
                    if (needsTrueRaw <= 1)
                        score += 1
                    if (hiddenFromPlayerRaw <= 1)
                        score += 1
                    if (needsFalseRaw <= 1)
                        score += 1

                    if (score > bestScore)
                    {
                        isTargetable := (isTargetableRaw != 0)
                            && (hiddenFromPlayerRaw = 0)
                            && (needsTrueRaw != 0)
                            && (meetsQuestStateRaw != 0)
                            && (needsFalseRaw = 0)

                        bestScore := score
                        best := Map(
                            "address", componentPtr,
                            "isTargetable", isTargetable ? true : false,
                            "isHighlightable", isHighlightableRaw != 0 ? true : false,
                            "isTargetedByPlayer", isTargetedByPlayerRaw != 0 ? true : false,
                            "meetsQuestState", meetsQuestStateRaw != 0 ? true : false,
                            "needsTrue", needsTrueRaw != 0 ? true : false,
                            "hiddenFromPlayer", hiddenFromPlayerRaw != 0 ? true : false,
                            "needsFalse", needsFalseRaw != 0 ? true : false,
                            "score", score
                        )

                        if (score = 7)
                            break
                    }
                }
            }

            idx += 1
        }

        return (bestScore >= 6) ? best : 0
    }

    ; Computes the element count of a C++ std::vector from its first/last pointers.
    ; Returns 0 if the address is invalid, elementSize <= 0, or count > maxCount.
    ReadStdVectorCount(vectorAddress, elementSize, maxCount := 4096)
    {
        if !this.IsProbablyValidPointer(vectorAddress) || elementSize <= 0
            return 0

        first := this.Mem.ReadInt64(vectorAddress + PoE2Offsets.StdVector["First"])
        last := this.Mem.ReadInt64(vectorAddress + PoE2Offsets.StdVector["Last"])
        if (first <= 0 || last < first)
            return 0

        bytes := last - first
        count := Floor(bytes / elementSize)
        if (count < 0)
            return 0
        if (count > maxCount)
            return 0
        return count
    }

}
