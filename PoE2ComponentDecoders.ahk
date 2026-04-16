; PoE2ComponentDecoders.ahk
; Base class: low-level memory reading utilities and per-component-type decoders.
;
; Provides foundational methods used by the entire reader stack.
; All methods use this.Mem and this.IsProbablyValidPointer which are
; defined in the top-level PoE2GameStateReader constructor.
;
; Inheritance: PoE2GameStateReader extends ... extends PoE2ComponentDecoders

class PoE2ComponentDecoders
{
    ; ── String reading utilities ──────────────────────────────────────────────
    ; Reads a null-terminated ASCII (CP0) string from process memory.
    ; Params: address - base memory address; maxBytes - max bytes to scan before stopping
    ; Returns: decoded string, or "" on invalid pointer or empty result
    ReadNarrowString(address, maxBytes := 128)
    {
        if !this.IsProbablyValidPointer(address) || maxBytes <= 0
            return ""

        buf := this.Mem.ReadBytes(address, maxBytes, true)
        if (!buf || Type(buf) != "Buffer" || buf.Size = 0)
            return ""

        byteLen := 0
        while (byteLen < buf.Size)
        {
            b := NumGet(buf.Ptr, byteLen, "UChar")
            if (b = 0)
                break
            byteLen += 1
        }

        if (byteLen <= 0)
            return ""

        return StrGet(buf.Ptr, byteLen, "CP0")
    }

    ; Heuristic check: returns true if the string looks like a valid PoE2 component name.
    ; Validates length 2–64, ASCII letter start, alphanumeric/underscore/dot characters only.
    IsLikelyComponentName(name)
    {
        if (name = "")
            return false

        len := StrLen(name)
        if (len < 2 || len > 64)
            return false

        if !RegExMatch(name, "^[A-Za-z][A-Za-z0-9_.]+$")
            return false

        return true
    }

    ; Case-insensitive component name equality check; also matches "Module.ComponentName" suffix form.
    ; Params: actualName - name from memory; expectedName - name to match against
    ; Returns: true if names are equal or actualName ends with ".<expectedName>"
    ComponentNameMatches(actualName, expectedName)
    {
        if (actualName = "" || expectedName = "")
            return false

        actualLower := StrLower(actualName)
        expectedLower := StrLower(expectedName)

        if (actualLower = expectedLower)
            return true

        actualLen := StrLen(actualLower)
        expectedLen := StrLen(expectedLower)
        if (actualLen < expectedLen)
            return false

        suffixStart := actualLen - expectedLen + 1
        if (SubStr(actualLower, suffixStart) != expectedLower)
            return false

        return (suffixStart = 1 || SubStr(actualLower, suffixStart - 1, 1) = ".")
    }

    ; ── std::wstring reading ─────────────────────────────────────────────────
    ; Reads a C++ std::wstring (UTF-16) from memory; handles SSO inline buffer when capacity ≤ 8.
    ; Params: stdWStringAddress - address of the std::wstring struct; maxChars - sanity cap on length/capacity
    ; Returns: decoded UTF-16 string, or "" on invalid pointer or out-of-range length
    ReadStdWStringAt(stdWStringAddress, maxChars := 1000)
    {
        if !this.IsProbablyValidPointer(stdWStringAddress)
            return ""

        bufferOrInline := this.Mem.ReadInt64(stdWStringAddress + PoE2Offsets.StdWString["Buffer"])
        reservedInline := this.Mem.ReadInt64(stdWStringAddress + PoE2Offsets.StdWString["ReservedBytes"])
        length := this.Mem.ReadInt(stdWStringAddress + PoE2Offsets.StdWString["Length"])
        capacity := this.Mem.ReadInt(stdWStringAddress + PoE2Offsets.StdWString["Capacity"])

        if (length <= 0 || length > maxChars || capacity <= 0 || capacity > maxChars)
            return ""

        if (capacity <= 8)
        {
            inlineBuf := Buffer(16, 0)
            NumPut("Int64", bufferOrInline, inlineBuf, 0)
            NumPut("Int64", reservedInline, inlineBuf, 8)
            return StrGet(inlineBuf.Ptr, length, "UTF-16")
        }

        if !this.IsProbablyValidPointer(bufferOrInline)
            return ""

        raw := this.Mem.ReadBytes(bufferOrInline, length * 2, true)
        if (!raw || Type(raw) != "Buffer" || raw.Size < (length * 2))
            return ""

        return StrGet(raw.Ptr, length, "UTF-16")
    }

    ; ── VitalStruct (Life/Mana/ES) reader ───────────────────────────────────
    ; Reads one vital resource struct (life, mana, or ES) and derives reservation and percentage fields.
    ; Params: componentPtr - component base address; vitalBaseOffset - byte offset to the vital struct
    ; Returns: Map with current, max, regen, reservedTotal, unreserved, and percentage keys
    ReadVitalStructSnapshot(componentPtr, vitalBaseOffset)
    {
        reservedFlat := this.Mem.ReadInt(componentPtr + vitalBaseOffset + PoE2Offsets.Vital["ReservedFlat"])
        reservedFraction := this.Mem.ReadInt(componentPtr + vitalBaseOffset + PoE2Offsets.Vital["ReservedFraction"])
        regenPerMinuteStat := this.Mem.ReadInt(componentPtr + vitalBaseOffset + PoE2Offsets.Vital["RegenPerMinuteStat"])
        noRegenStat := regenPerMinuteStat
        regen := this.Mem.ReadFloat(componentPtr + vitalBaseOffset + PoE2Offsets.Vital["Regen"])
        maxValue := this.Mem.ReadInt(componentPtr + vitalBaseOffset + PoE2Offsets.Vital["Max"])
        currentValue := this.Mem.ReadInt(componentPtr + vitalBaseOffset + PoE2Offsets.Vital["Current"])

        reservedTotal := 0
        unreserved := maxValue
        currentPercentUnreserved := 0
        currentPercentMax := 0
        reservedPercentMax := 0

        if (maxValue > 0)
        {
            reservedTotal := Ceil((reservedFraction / 10000.0) * maxValue) + reservedFlat
            if (reservedTotal < 0)
                reservedTotal := 0
            if (reservedTotal > maxValue)
                reservedTotal := maxValue

            unreserved := maxValue - reservedTotal
            if (unreserved < 0)
                unreserved := 0

            currentPercentUnreserved := (unreserved > 0) ? ((currentValue * 100.0) / unreserved) : 0
            currentPercentMax := (currentValue * 100.0) / maxValue
            reservedPercentMax := (reservedTotal * 100.0) / maxValue
        }

        return Map(
            "reservedFlat", reservedFlat,
            "reservedFraction", reservedFraction,
            "regenPerMinuteStat", regenPerMinuteStat,
            "noRegenStat", noRegenStat,
            "regen", regen,
            "max", maxValue,
            "current", currentValue,
            "reservedTotal", reservedTotal,
            "unreserved", unreserved,
            "currentPercentUnreserved", currentPercentUnreserved,
            "currentPercentMax", currentPercentMax,
            "reservedPercentMax", reservedPercentMax
        )
    }


    ; ── Component lookup table reader ───────────────────────────────────────
    ; Walks the entity's component hash bucket and collects {name, index, address} entries.
    ; Params: entityPtr - entity base address; maxComponents - cap on returned entries
    ; Returns: Array of Maps with keys "name", "index", "address"; empty array on failure
    ReadEntityComponentLookupBasic(entityPtr, maxComponents := 24)
    {
        out := []
        if !this.IsProbablyValidPointer(entityPtr)
            return out

        entityDetailsPtr := this.Mem.ReadPtr(entityPtr + PoE2Offsets.Entity["EntityDetailsPtr"])
        if !this.IsProbablyValidPointer(entityDetailsPtr)
            return out

        componentLookupPtr := this.Mem.ReadPtr(entityDetailsPtr + PoE2Offsets.EntityDetails["ComponentLookupPtr"])
        if !this.IsProbablyValidPointer(componentLookupPtr)
            return out

        compVecFirst := this.Mem.ReadInt64(entityPtr + PoE2Offsets.Entity["ComponentsVec"])
        compVecLast := this.Mem.ReadInt64(entityPtr + PoE2Offsets.Entity["ComponentsVecLast"])
        if (compVecFirst <= 0 || compVecLast < compVecFirst)
            return out

        componentCount := Floor((compVecLast - compVecFirst) / A_PtrSize)
        if (componentCount < 0 || componentCount > 512)
            return out

        bucketAddress := componentLookupPtr + PoE2Offsets.ComponentLookup["Bucket"]
        bucketCapacity := this.Mem.ReadInt(bucketAddress + PoE2Offsets.StdBucket["Capacity"])
        if (bucketCapacity <= 0 || bucketCapacity > 4096)
            return out

        dataFirst := this.Mem.ReadInt64(bucketAddress + PoE2Offsets.StdBucket["Data"])
        dataLast := this.Mem.ReadInt64(bucketAddress + PoE2Offsets.StdBucket["DataLast"])
        if (dataFirst <= 0 || dataLast < dataFirst)
            return out

        entrySize := PoE2Offsets.ComponentLookupEntry["Size"]
        rawCount := Floor((dataLast - dataFirst) / entrySize)
        if (rawCount <= 0)
            return out

        readCount := Min(rawCount, 256)
        seenNames := Map()

        idx := 0
        while (idx < readCount && out.Length < maxComponents)
        {
            entryAddr := dataFirst + (idx * entrySize)
            namePtr := this.Mem.ReadPtr(entryAddr + PoE2Offsets.ComponentLookupEntry["NamePtr"])
            compIndex := this.Mem.ReadInt(entryAddr + PoE2Offsets.ComponentLookupEntry["Index"])

            if (compIndex >= 0 && compIndex < componentCount)
            {
                compPtr := this.Mem.ReadPtr(compVecFirst + (compIndex * A_PtrSize))
                if this.IsProbablyValidPointer(compPtr)
                {
                    compName := this.ReadNarrowString(namePtr, 96)
                    if (compName = "")
                        compName := this.Mem.ReadUnicodeString(namePtr)

                    if this.IsLikelyComponentName(compName)
                    {
                        key := StrLower(compName)
                        if !seenNames.Has(key)
                        {
                            seenNames[key] := true
                            out.Push(Map(
                                "name", compName,
                                "index", compIndex,
                                "address", compPtr
                            ))
                        }
                    }
                }
            }

            idx += 1
        }

        return out
    }


    ; ── Individual component decoders ───────────────────────────────────────
    ; Reads all targeting flags from the Targetable component; rejects non-boolean raw values.
    ; Returns: Map with isTargetable, isHighlightable, isTargetedByPlayer, hiddenFromPlayer, etc., or 0 on failure
    DecodeTargetableComponent(componentPtr)
    {
        isTargetableRaw := this.Mem.ReadUChar(componentPtr + PoE2Offsets.Targetable["IsTargetable"])
        isHighlightableRaw := this.Mem.ReadUChar(componentPtr + PoE2Offsets.Targetable["IsHighlightable"])
        isTargetedByPlayerRaw := this.Mem.ReadUChar(componentPtr + PoE2Offsets.Targetable["IsTargetedByPlayer"])
        meetsQuestStateRaw := this.Mem.ReadUChar(componentPtr + PoE2Offsets.Targetable["MeetsQuestState"])
        needsTrueRaw := this.Mem.ReadUChar(componentPtr + PoE2Offsets.Targetable["NeedsTrue"])
        hiddenFromPlayerRaw := this.Mem.ReadUChar(componentPtr + PoE2Offsets.Targetable["HiddenFromPlayer"])
        needsFalseRaw := this.Mem.ReadUChar(componentPtr + PoE2Offsets.Targetable["NeedsFalse"])

        plausible := (isTargetableRaw <= 1)
            && (isHighlightableRaw <= 1)
            && (isTargetedByPlayerRaw <= 1)
            && (meetsQuestStateRaw <= 1)
            && (needsTrueRaw <= 1)
            && (hiddenFromPlayerRaw <= 1)
            && (needsFalseRaw <= 1)
        if !plausible
            return 0

        isTargetable := (isTargetableRaw != 0)
            && (hiddenFromPlayerRaw = 0)

        return Map(
            "address", componentPtr,
            "isTargetable", isTargetable ? true : false,
            "isHighlightable", isHighlightableRaw != 0 ? true : false,
            "isTargetedByPlayer", isTargetedByPlayerRaw != 0 ? true : false,
            "meetsQuestState", meetsQuestStateRaw != 0 ? true : false,
            "needsTrue", needsTrueRaw != 0 ? true : false,
            "hiddenFromPlayer", hiddenFromPlayerRaw != 0 ? true : false,
            "needsFalse", needsFalseRaw != 0 ? true : false
        )
    }

    ; Reads world XYZ position, model bounds, and terrain height from the Render component.
    ; Validates plausibility ranges and rejects near-zero, flat, or suspicious vectors.
    ; Returns: Map with worldPosition, gridPosition, modelBounds, terrainHeight, or 0 on failure
    DecodeRenderComponent(componentPtr)
    {
        worldX := this.Mem.ReadFloat(componentPtr + PoE2Offsets.Render["CurrentWorldPosition"])
        worldY := this.Mem.ReadFloat(componentPtr + PoE2Offsets.Render["CurrentWorldPositionY"])
        worldZ := this.Mem.ReadFloat(componentPtr + PoE2Offsets.Render["CurrentWorldPositionZ"])
        boundsX := this.Mem.ReadFloat(componentPtr + PoE2Offsets.Render["CharacterModelBounds"])
        boundsY := this.Mem.ReadFloat(componentPtr + PoE2Offsets.Render["CharacterModelBoundsY"])
        boundsZ := this.Mem.ReadFloat(componentPtr + PoE2Offsets.Render["CharacterModelBoundsZ"])
        terrainHeight := this.Mem.ReadFloat(componentPtr + PoE2Offsets.Render["TerrainHeight"])

        plausible := (Abs(worldX) <= 200000)
            && (Abs(worldY) <= 200000)
            && (Abs(worldZ) <= 200000)
            && (Abs(boundsX) <= 100000)
            && (Abs(boundsY) <= 100000)
            && (Abs(boundsZ) <= 100000)
            && (Abs(terrainHeight) <= 200000)
        if !plausible
            return 0

        isNearZeroVector := (Abs(worldX) < 0.01)
            && (Abs(worldY) < 0.01)
            && (Abs(worldZ) < 0.01)
        if isNearZeroVector
            return 0

        isSuspiciousFlatVector := (Abs(worldY) < 0.01)
            && (Abs(worldZ) < 0.01)
            && (Abs(worldX) > 50)
            && (Abs(terrainHeight) < 0.01)
        if isSuspiciousFlatVector
            return 0

        isSuspiciousOriginProjection := (Abs(worldX) < 0.01)
            && (Abs(worldY) < 0.01)
            && (Abs(worldZ) < 512)
            && (Abs(terrainHeight) < 0.01)
        if isSuspiciousOriginProjection
            return 0

        worldToGridRatio := 250.0 / 0x17
        gridX := worldX / worldToGridRatio
        gridY := worldY / worldToGridRatio

        return Map(
            "address", componentPtr,
            "worldPosition", Map("x", worldX, "y", worldY, "z", worldZ),
            "gridPosition", Map("x", gridX, "y", gridY),
            "modelBounds", Map("x", boundsX, "y", boundsY, "z", boundsZ),
            "terrainHeight", terrainHeight
        )
    }

    ; Reads the Chest component: isOpened flag, label visibility, and optional strongbox DAT pointer.
    ; Returns: Map with isOpened, isLabelVisible, strongboxDatPtr, isStrongbox, or 0 if not plausible
    DecodeChestComponent(componentPtr)
    {
        chestDataPtr := this.Mem.ReadPtr(componentPtr + PoE2Offsets.Chest["ChestDataPtr"])
        isOpenedRaw := this.Mem.ReadUChar(componentPtr + PoE2Offsets.Chest["IsOpened"])
        if (isOpenedRaw > 1)
            return 0

        isLabelVisibleRaw := 0
        strongboxDatPtr := 0
        if this.IsProbablyValidPointer(chestDataPtr)
        {
            isLabelVisibleRaw := this.Mem.ReadUChar(chestDataPtr + PoE2Offsets.ChestData["IsLabelVisible"])
            strongboxDatPtr := this.Mem.ReadPtr(chestDataPtr + PoE2Offsets.ChestData["StrongboxDatPtr"])
        }

        return Map(
            "address", componentPtr,
            "chestDataPtr", chestDataPtr,
            "isOpened", isOpenedRaw != 0 ? true : false,
            "isLabelVisible", isLabelVisibleRaw != 0 ? true : false,
            "strongboxDatPtr", strongboxDatPtr,
            "isStrongbox", this.IsProbablyValidPointer(strongboxDatPtr) ? true : false
        )
    }

    ; Reads the Shrine component's isUsed flag; returns 0 if the byte value is not boolean.
    ; Returns: Map with isUsed, or 0 on failure
    DecodeShrineComponent(componentPtr)
    {
        isUsedRaw := this.Mem.ReadUChar(componentPtr + PoE2Offsets.Shrine["IsUsed"])
        if (isUsedRaw > 1)
            return 0

        return Map(
            "address", componentPtr,
            "isUsed", isUsedRaw != 0 ? true : false
        )
    }

    ; Reads the Positioned component reaction byte and derives isFriendly (reaction & 0x7F == 1).
    ; Returns: Map with reaction and isFriendly, or 0 if reaction byte exceeds 0x7F
    DecodePositionedComponent(componentPtr)
    {
        reaction := this.Mem.ReadUChar(componentPtr + PoE2Offsets.Positioned["Reaction"])
        if (reaction > 0x7F)
            return 0

        isFriendly := (reaction & 0x7F) = 0x01
        return Map(
            "address", componentPtr,
            "reaction", reaction,
            "isFriendly", isFriendly ? true : false
        )
    }


    ; Reads the Transitionable component's currentState short integer.
    ; Returns: Map with currentState, or 0 if the value is out of the [-1, 2048] range
    DecodeTransitionableComponent(componentPtr)
    {
        currentState := this.Mem.ReadShort(componentPtr + PoE2Offsets.Transitionable["CurrentState"])
        if (currentState < -1 || currentState > 2048)
            return 0

        return Map(
            "address", componentPtr,
            "currentState", currentState
        )
    }

    ; Reads the StateMachine component: currentState, state values vector, and resolves state names.
    ; Walks the states vector and calls ResolveStateMachineStateName for each index.
    ; Returns: Map with currentState, stateCount, states array, statesSummary, or 0 on failure
    DecodeStateMachineComponentBasic(componentPtr)
    {
        currentState := this.Mem.ReadShort(componentPtr + PoE2Offsets.Transitionable["CurrentState"])
        statesPtr := this.Mem.ReadPtr(componentPtr + PoE2Offsets.StateMachine["StatesPtr"])
        vecFirst := this.Mem.ReadInt64(componentPtr + PoE2Offsets.StateMachine["StatesValues"])
        vecLast := this.Mem.ReadInt64(componentPtr + PoE2Offsets.StateMachine["StatesValuesLast"])

        hasValuesVec := (vecFirst > 0 && vecLast >= vecFirst)
        plausible := (currentState >= -1 && currentState <= 2048)
            && (this.IsProbablyValidPointer(statesPtr) || hasValuesVec)
        if !plausible
            return 0

        values := []
        stateCount := 0
        resolvedNamesCount := 0

        if hasValuesVec
        {
            totalBytes := vecLast - vecFirst
            if (totalBytes >= 8)
            {
                maxBytes := 8 * 64
                if (totalBytes > maxBytes)
                    totalBytes := maxBytes

                bytesCount := Floor(totalBytes / 8) * 8
                if (bytesCount > 0)
                {
                    stateCount := Floor(bytesCount / 8)
                    offset := 0
                    while (offset < bytesCount)
                    {
                        val := this.Mem.ReadInt64(vecFirst + offset)
                        stateIndex := Floor(offset / 8)
                        rawStateName := ""
                        stateName := this.ResolveStateMachineStateName(statesPtr, stateIndex, &rawStateName)
                        if (stateName = "")
                            stateName := "state_" stateIndex
                        else
                            resolvedNamesCount += 1

                        values.Push(Map(
                            "name", stateName,
                            "rawName", rawStateName,
                            "value", val
                        ))
                        offset += 8
                    }
                }
            }
        }

        currentStateName := ""
        if (currentState >= 0)
        {
            rawCurrentName := ""
            currentStateName := this.ResolveStateMachineStateName(statesPtr, currentState, &rawCurrentName)
        }

        statesSummary := this.BuildStateMachineSummary(values, currentState)

        return Map(
            "address", componentPtr,
            "currentState", currentState,
            "currentStateName", currentStateName,
            "statesPtr", statesPtr,
            "stateCount", stateCount,
            "resolvedNamesCount", resolvedNamesCount,
            "states", values,
            "statesSummary", statesSummary
        )
    }

    ; Reads the Actor component: animationId, counts active skills/cooldowns/deployed entities, and samples them.
    ; Returns: Map with animationId, counts, firstActiveSkill, firstCooldown, samples, and samplesSummary
    DecodeActorComponentBasic(componentPtr)
    {
        animationId := this.Mem.ReadInt(componentPtr + PoE2Offsets.Actor["AnimationId"])
        activeSkillsCount := this.ReadStdVectorCount(componentPtr + PoE2Offsets.Actor["ActiveSkills"], 0x10, 512)
        cooldownsCount := this.ReadStdVectorCount(componentPtr + PoE2Offsets.Actor["Cooldowns"], 0x48, 512)
        deployedCount := this.ReadStdVectorCount(componentPtr + PoE2Offsets.Actor["DeployedEntities"], 0x14, 1024)

        plausible := (animationId >= 0 && animationId <= 2000000)
            && (activeSkillsCount >= 0)
            && (cooldownsCount >= 0)
            && (deployedCount >= 0)
        if !plausible
            return 0

        samples := this.ReadActorComponentSamples(componentPtr, activeSkillsCount, cooldownsCount, deployedCount, 6)
        activeSkills := samples["activeSkills"]
        cooldowns := samples["cooldowns"]
        deployedEntities := samples["deployedEntities"]

        firstActiveSkill := (activeSkills.Length > 0) ? activeSkills[1] : 0
        firstCooldown := (cooldowns.Length > 0) ? cooldowns[1] : 0

        return Map(
            "address", componentPtr,
            "animationId", animationId,
            "activeSkillsCount", activeSkillsCount,
            "cooldownsCount", cooldownsCount,
            "deployedCount", deployedCount,
            "firstActiveSkill", firstActiveSkill,
            "firstCooldown", firstCooldown,
            "activeSkillsSample", activeSkills,
            "cooldownsSample", cooldowns,
            "deployedEntitiesSample", deployedEntities,
            "samplesSummary", samples["summary"]
        )
    }

    ; Reads up to maxSample entries from each of the three actor vectors (active skills, cooldowns, deployed entities).
    ; Params: activeSkillsCount/cooldownsCount/deployedCount - vector sizes; maxSample - per-vector read cap
    ; Returns: Map with activeSkills, cooldowns, deployedEntities arrays, and an aggregated summary Map
    ReadActorComponentSamples(componentPtr, activeSkillsCount, cooldownsCount, deployedCount, maxSample := 6)
    {
        activeSkills := []
        cooldowns := []
        deployedEntities := []

        activeSkillsFirst := this.Mem.ReadInt64(componentPtr + PoE2Offsets.Actor["ActiveSkills"])
        activeSkillsLast := this.Mem.ReadInt64(componentPtr + PoE2Offsets.Actor["ActiveSkillsLast"])
        cooldownsFirst := this.Mem.ReadInt64(componentPtr + PoE2Offsets.Actor["Cooldowns"])
        cooldownsLast := this.Mem.ReadInt64(componentPtr + PoE2Offsets.Actor["CooldownsLast"])
        deployedFirst := this.Mem.ReadInt64(componentPtr + PoE2Offsets.Actor["DeployedEntities"])
        deployedLast := this.Mem.ReadInt64(componentPtr + PoE2Offsets.Actor["DeployedEntitiesLast"])

        readActive := Min(activeSkillsCount, maxSample)
        idx := 0
        while (idx < readActive)
        {
            entryAddr := activeSkillsFirst + (idx * 0x10)
            detailsPtr := this.Mem.ReadPtr(entryAddr + PoE2Offsets.ActiveSkillStructure["ActiveSkillPtr"])
            if this.IsProbablyValidPointer(detailsPtr)
            {
                activeSkills.Push(Map(
                    "activeSkillDetailsPtr", detailsPtr,
                    "useStage", this.Mem.ReadInt(detailsPtr + PoE2Offsets.ActiveSkillDetails["UseStage"]),
                    "castType", this.Mem.ReadInt(detailsPtr + PoE2Offsets.ActiveSkillDetails["CastType"]),
                    "unknownIdAndEquipmentInfo", this.Mem.ReadUInt(detailsPtr + PoE2Offsets.ActiveSkillDetails["UnknownIdAndEquipmentInfo"]),
                    "totalUses", this.Mem.ReadInt(detailsPtr + PoE2Offsets.ActiveSkillDetails["TotalUses"]),
                    "totalCooldownTimeInMs", this.Mem.ReadInt(detailsPtr + PoE2Offsets.ActiveSkillDetails["TotalCooldownTimeInMs"])
                ))
            }
            idx += 1
        }

        readCooldowns := Min(cooldownsCount, maxSample)
        idx := 0
        while (idx < readCooldowns)
        {
            entryAddr := cooldownsFirst + (idx * 0x48)
            activeCooldownCount := this.ReadStdVectorCount(entryAddr + PoE2Offsets.ActiveSkillCooldown["CooldownsList"], 0x10, 64)
            cooldowns.Push(Map(
                "activeSkillsDatId", this.Mem.ReadInt(entryAddr + PoE2Offsets.ActiveSkillCooldown["ActiveSkillsDatId"]),
                "maxUses", this.Mem.ReadInt(entryAddr + PoE2Offsets.ActiveSkillCooldown["MaxUses"]),
                "totalCooldownTimeInMs", this.Mem.ReadInt(entryAddr + PoE2Offsets.ActiveSkillCooldown["TotalCooldownTimeInMs"]),
                "activeCooldownCount", activeCooldownCount,
                "cannotBeUsed", (activeCooldownCount >= this.Mem.ReadInt(entryAddr + PoE2Offsets.ActiveSkillCooldown["MaxUses"])
                    && this.Mem.ReadInt(entryAddr + PoE2Offsets.ActiveSkillCooldown["MaxUses"]) > 0) ? true : false,
                "unknownIdAndEquipmentInfo", this.Mem.ReadUInt(entryAddr + PoE2Offsets.ActiveSkillCooldown["UnknownIdAndEquipmentInfo"])
            ))
            idx += 1
        }

        readDeployed := Min(deployedCount, maxSample)
        idx := 0
        while (idx < readDeployed)
        {
            entryAddr := deployedFirst + (idx * 0x14)
            deployedEntities.Push(Map(
                "entityId", this.Mem.ReadInt(entryAddr + PoE2Offsets.DeployedEntity["EntityId"]),
                "activeSkillsDatId", this.Mem.ReadInt(entryAddr + PoE2Offsets.DeployedEntity["ActiveSkillsDatId"]),
                "deployedObjectType", this.Mem.ReadInt(entryAddr + PoE2Offsets.DeployedEntity["DeployedObjectType"]),
                "counter", this.Mem.ReadInt(entryAddr + PoE2Offsets.DeployedEntity["Counter"])
            ))
            idx += 1
        }

        summary := this.BuildActorSamplesSummary(activeSkills, cooldowns, deployedEntities)
        summary["activeSkillsSampleRead"] := activeSkills.Length
        summary["cooldownsSampleRead"] := cooldowns.Length
        summary["deployedSampleRead"] := deployedEntities.Length

        return Map(
            "activeSkills", activeSkills,
            "cooldowns", cooldowns,
            "deployedEntities", deployedEntities,
            "summary", summary
        )
    }

    ; Aggregates sampled actor data into cast type/use stage frequency maps and cooldown statistics.
    ; Returns: Map with castTypeCounts, useStageCounts, cooldownBlockedCount, cooldownTotalMsSampleSum, totalUsesSampleSum
    BuildActorSamplesSummary(activeSkills, cooldowns, deployedEntities)
    {
        castTypeCounts := Map()
        useStageCounts := Map()
        cooldownBlockedCount := 0
        cooldownTotalMsSum := 0
        totalUsesSum := 0

        for _, skill in activeSkills
        {
            if !(skill && Type(skill) = "Map")
                continue

            castType := skill.Has("castType") ? skill["castType"] : -1
            useStage := skill.Has("useStage") ? skill["useStage"] : -1
            totalUses := skill.Has("totalUses") ? skill["totalUses"] : 0

            keyCast := castType ""
            keyStage := useStage ""
            castTypeCounts[keyCast] := castTypeCounts.Has(keyCast) ? (castTypeCounts[keyCast] + 1) : 1
            useStageCounts[keyStage] := useStageCounts.Has(keyStage) ? (useStageCounts[keyStage] + 1) : 1

            if (totalUses > 0)
                totalUsesSum += totalUses
        }

        for _, cooldown in cooldowns
        {
            if !(cooldown && Type(cooldown) = "Map")
                continue

            totalMs := cooldown.Has("totalCooldownTimeInMs") ? cooldown["totalCooldownTimeInMs"] : 0
            if (totalMs > 0)
                cooldownTotalMsSum += totalMs

            if (cooldown.Has("cannotBeUsed") && cooldown["cannotBeUsed"])
                cooldownBlockedCount += 1
        }

        return Map(
            "activeSkillsSampleCount", activeSkills.Length,
            "cooldownsSampleCount", cooldowns.Length,
            "deployedSampleCount", deployedEntities.Length,
            "totalUsesSampleSum", totalUsesSum,
            "cooldownBlockedCount", cooldownBlockedCount,
            "cooldownTotalMsSampleSum", cooldownTotalMsSum,
            "castTypeCounts", castTypeCounts,
            "useStageCounts", useStageCounts
        )
    }

    ; ── Full Actor Skill Reader ─────────────────────────────────────────────
    ; Reads ALL active skills and cooldowns from the Actor component, resolves
    ; skill names via the GrantedEffectsPerLevel→GrantedEffects→ActiveSkillDat chain,
    ; matches cooldowns to skills, and computes "canUse" for each skill.
    ; Uses _skillNameCache (Map of GrantedEffectsPerLevelDatRow → name) for caching.
    ; Returns: Map with "skills" (Array of skill Maps), "cooldowns" (Map of equipId → cooldown),
    ;          "deployedCounts" (Map of objectType → count), or 0 on failure
    DecodeActorSkills(componentPtr)
    {
        if !this.IsProbablyValidPointer(componentPtr)
            return 0

        ; Read cooldowns first so we can link them to skills
        cooldownsByEquipId := Map()
        cooldownsFirst := this.Mem.ReadInt64(componentPtr + PoE2Offsets.Actor["Cooldowns"])
        cooldownsLast := this.Mem.ReadInt64(componentPtr + PoE2Offsets.Actor["CooldownsLast"])
        if (cooldownsFirst > 0 && cooldownsLast >= cooldownsFirst)
        {
            cdCount := Min(Floor((cooldownsLast - cooldownsFirst) / 0x48), 256)
            idx := 0
            while (idx < cdCount)
            {
                entryAddr := cooldownsFirst + (idx * 0x48)
                equipId := this.Mem.ReadUInt(entryAddr + PoE2Offsets.ActiveSkillCooldown["UnknownIdAndEquipmentInfo"])
                activeCooldownCount := this.ReadStdVectorCount(entryAddr + PoE2Offsets.ActiveSkillCooldown["CooldownsList"], 0x10, 64)
                maxUses := this.Mem.ReadInt(entryAddr + PoE2Offsets.ActiveSkillCooldown["MaxUses"])
                cdTotalMs := this.Mem.ReadInt(entryAddr + PoE2Offsets.ActiveSkillCooldown["TotalCooldownTimeInMs"])
                cannotBeUsed := (activeCooldownCount >= maxUses) ? true : false
                cooldownsByEquipId[equipId] := Map(
                    "activeSkillsDatId", this.Mem.ReadInt(entryAddr + PoE2Offsets.ActiveSkillCooldown["ActiveSkillsDatId"]),
                    "maxUses", maxUses,
                    "activeCooldownCount", activeCooldownCount,
                    "totalCooldownTimeInMs", cdTotalMs,
                    "cannotBeUsed", cannotBeUsed
                )
                idx += 1
            }
        }

        ; Read active skills — deduplicate by name (C# uses Dictionary<string, ActiveSkillDetails>)
        skillsByName := Map()
        activeSkillsFirst := this.Mem.ReadInt64(componentPtr + PoE2Offsets.Actor["ActiveSkills"])
        activeSkillsLast := this.Mem.ReadInt64(componentPtr + PoE2Offsets.Actor["ActiveSkillsLast"])
        if (activeSkillsFirst <= 0 || activeSkillsLast < activeSkillsFirst)
            return Map("skills", [], "cooldowns", cooldownsByEquipId, "deployedCounts", Map())

        skillCount := Min(Floor((activeSkillsLast - activeSkillsFirst) / 0x10), 256)
        idx := 0
        while (idx < skillCount)
        {
            entryAddr := activeSkillsFirst + (idx * 0x10)
            detailsPtr := this.Mem.ReadPtr(entryAddr + PoE2Offsets.ActiveSkillStructure["ActiveSkillPtr"])
            if !this.IsProbablyValidPointer(detailsPtr)
            {
                idx += 1
                continue
            }

            geplRow := this.Mem.ReadPtr(detailsPtr + PoE2Offsets.ActiveSkillDetails["GrantedEffectsPerLevelDatRow"])
            if !this.IsProbablyValidPointer(geplRow)
            {
                idx += 1
                continue
            }

            ; Resolve skill name via pointer chain (cached)
            skillNames := this._ResolveSkillName(geplRow)
            internalName := skillNames["internalName"]
            displayName := skillNames["displayName"]

            useStage := this.Mem.ReadInt(detailsPtr + PoE2Offsets.ActiveSkillDetails["UseStage"])
            castType := this.Mem.ReadInt(detailsPtr + PoE2Offsets.ActiveSkillDetails["CastType"])
            equipId := this.Mem.ReadUInt(detailsPtr + PoE2Offsets.ActiveSkillDetails["UnknownIdAndEquipmentInfo"])
            totalUses := this.Mem.ReadInt(detailsPtr + PoE2Offsets.ActiveSkillDetails["TotalUses"])
            cooldownMs := this.Mem.ReadInt(detailsPtr + PoE2Offsets.ActiveSkillDetails["TotalCooldownTimeInMs"])

            ; Link cooldown via equipId (C#: CannotBeUsed = activeCds >= maxUses)
            canUse := true
            cdInfo := 0
            if cooldownsByEquipId.Has(equipId)
            {
                cdInfo := cooldownsByEquipId[equipId]
                if cdInfo["cannotBeUsed"]
                    canUse := false
            }

            iconPath := skillNames["iconPath"]

            ; Last entry wins (matches C# this.ActiveSkills[name] = skillDetails)
            skillsByName[internalName] := Map(
                "name", internalName,
                "displayName", displayName,
                "iconPath", iconPath,
                "useStage", useStage,
                "castType", castType,
                "equipId", equipId,
                "totalUses", totalUses,
                "cooldownMs", cooldownMs,
                "canUse", canUse,
                "activeCooldowns", (cdInfo ? cdInfo["activeCooldownCount"] : 0),
                "maxUses", (cdInfo ? cdInfo["maxUses"] : 0),
                "detailsPtr", detailsPtr,
                "geplRow", geplRow
            )
            idx += 1
        }

        skills := []
        for _, skill in skillsByName
            skills.Push(skill)

        ; Read deployed entities
        deployedCounts := Map()
        deployedFirst := this.Mem.ReadInt64(componentPtr + PoE2Offsets.Actor["DeployedEntities"])
        deployedLast := this.Mem.ReadInt64(componentPtr + PoE2Offsets.Actor["DeployedEntitiesLast"])
        if (deployedFirst > 0 && deployedLast >= deployedFirst)
        {
            dCount := Min(Floor((deployedLast - deployedFirst) / 0x14), 1024)
            idx := 0
            while (idx < dCount)
            {
                entryAddr := deployedFirst + (idx * 0x14)
                objType := this.Mem.ReadInt(entryAddr + PoE2Offsets.DeployedEntity["DeployedObjectType"])
                if (objType >= 0 && objType < 256)
                {
                    key := objType ""
                    deployedCounts[key] := deployedCounts.Has(key) ? (deployedCounts[key] + 1) : 1
                }
                idx += 1
            }
        }

        asOff := this.HasOwnProp("_activeSkillOffset") ? this._activeSkillOffset : 0
        return Map(
            "skills", skills,
            "cooldowns", cooldownsByEquipId,
            "deployedCounts", deployedCounts,
            "activeSkillOffset", asOff
        )
    }

    ; Resolves skill names from a GrantedEffectsPerLevelDatRow pointer.
    ; Returns Map with "internalName", "displayName", and "iconPath".
    ; Chain: geplRow → GE row (at +0x00) → Id string (internalName)
    ;        GE row + activeSkillOffset → ActiveSkills row → +0x08 → DisplayedName
    ;        ActiveSkills row + 0x28 → Icon_DDSFile path
    ; Auto-discovers the ActiveSkill foreignrow offset via two-phase scan.
    _ResolveSkillName(geplRow)
    {
        if !this.HasOwnProp("_skillNameCache")
            this._skillNameCache := Map()
        if !this.HasOwnProp("_activeSkillOffset")
            this._activeSkillOffset := 0

        cacheKey := geplRow ""
        if this._skillNameCache.Has(cacheKey)
            return this._skillNameCache[cacheKey]

        internalName := ""
        displayName := ""
        iconPath := ""
        try
        {
            grantedEffectDatPtr := this.Mem.ReadPtr(geplRow + PoE2Offsets.GrantedEffectsPerLevelDat["GrantedEffectDatPtr"])
            if this.IsProbablyValidPointer(grantedEffectDatPtr)
            {
                ; Internal name from GrantedEffects row offset 0x00
                nameStringPtr := this.Mem.ReadPtr(grantedEffectDatPtr)
                if this.IsProbablyValidPointer(nameStringPtr)
                    internalName := this.Mem.ReadUnicodeString(nameStringPtr, 256)

                ; Display name + icon via ActiveSkills.dat row
                if (this._activeSkillOffset > 0)
                {
                    asInfo := this._TryReadActiveSkillRow(grantedEffectDatPtr, this._activeSkillOffset)
                    displayName := asInfo["displayName"]
                    iconPath := asInfo["iconPath"]
                }
                else
                {
                    this._activeSkillOffset := this._FindActiveSkillOffset(grantedEffectDatPtr)
                    if (this._activeSkillOffset > 0)
                    {
                        asInfo := this._TryReadActiveSkillRow(grantedEffectDatPtr, this._activeSkillOffset)
                        displayName := asInfo["displayName"]
                        iconPath := asInfo["iconPath"]
                    }
                }
            }
        }
        catch
        {
        }

        if (internalName = "")
            internalName := "Skill_" Format("{:X}", geplRow)
        if (displayName = "")
            displayName := internalName

        result := Map("internalName", internalName, "displayName", displayName, "iconPath", iconPath)
        this._skillNameCache[cacheKey] := result
        return result
    }

    ; Auto-discovers the correct offset to the ActiveSkill foreignrow within a GrantedEffects row.
    ; Phase 1: Look for the dat-name reference ("ActiveSkills") at offset+8 (foreignrow is 16 bytes).
    ; Phase 2: Fallback — validate the full chain (row ptr → Id + DisplayName strings).
    ; Returns the offset, or 0 if not found.
    _FindActiveSkillOffset(grantedEffectDatPtr)
    {
        ; Phase 1: Dat-name scan — look for "ActiveSkills" string ref at offset+8
        off := 0x40
        while (off <= 0xC0)
        {
            try
            {
                datNamePtr := this.Mem.ReadPtr(grantedEffectDatPtr + off + 8)
                if this.IsProbablyValidPointer(datNamePtr)
                {
                    datNameStr := this.Mem.ReadUnicodeString(datNamePtr, 128)
                    if (datNameStr != "" && InStr(datNameStr, "ActiveSkills"))
                    {
                        rowPtr := this.Mem.ReadPtr(grantedEffectDatPtr + off)
                        if this.IsProbablyValidPointer(rowPtr)
                        {
                            asInfo := this._TryReadActiveSkillRow(grantedEffectDatPtr, off)
                            if (asInfo["displayName"] != "")
                                return off
                        }
                    }
                }
            }
            catch
            {
            }
            off += 1
        }

        ; Phase 2: Fallback — try reading the full chain at each offset
        off := 0x40
        while (off <= 0xC0)
        {
            asInfo := this._TryReadActiveSkillRow(grantedEffectDatPtr, off)
            if (asInfo["displayName"] != "")
                return off
            off += 1
        }

        return 0
    }

    ; Reads ActiveSkills row data (displayName + iconPath) from a GE row at the given offset.
    ; Returns Map with "displayName" and "iconPath" (both "" if invalid).
    _TryReadActiveSkillRow(grantedEffectDatPtr, offset)
    {
        empty := Map("displayName", "", "iconPath", "")
        try
        {
            rowPtr := this.Mem.ReadPtr(grantedEffectDatPtr + offset)
            if !this.IsProbablyValidPointer(rowPtr)
                return empty

            ; ActiveSkills row: Id at +0x00
            idPtr := this.Mem.ReadPtr(rowPtr)
            if !this.IsProbablyValidPointer(idPtr)
                return empty
            idStr := this.Mem.ReadUnicodeString(idPtr, 128)
            if (idStr = "" || InStr(idStr, "/") || InStr(idStr, "\") || InStr(idStr, ".dat"))
                return empty

            ; ActiveSkills row: DisplayedName at +0x08
            displayNamePtr := this.Mem.ReadPtr(rowPtr + PoE2Offsets.ActiveSkillsDat["DisplayedName"])
            if !this.IsProbablyValidPointer(displayNamePtr)
                return empty
            dn := this.Mem.ReadUnicodeString(displayNamePtr, 256)
            if (dn = "" || StrLen(dn) < 2 || StrLen(dn) > 100)
                return empty
            if (InStr(dn, "/") || InStr(dn, "\") || InStr(dn, ".dat"))
                return empty
            if !RegExMatch(dn, "[A-Za-z]")
                return empty

            ; ActiveSkills row: Icon_DDSFile at +0x28
            iconPath := ""
            try
            {
                iconPtr := this.Mem.ReadPtr(rowPtr + PoE2Offsets.ActiveSkillsDat["IconDDSFile"])
                if this.IsProbablyValidPointer(iconPtr)
                {
                    raw := this.Mem.ReadUnicodeString(iconPtr, 512)
                    if (raw != "" && InStr(raw, "Art/"))
                        iconPath := raw
                }
            }
            return Map("displayName", dn, "iconPath", iconPath)
        }
        catch
            return empty
    }
    
    ; Reads the Animated component's inner entity pointer, its numeric ID, and path string.
    ; Returns: Map with animatedEntityPtr, id, path, or 0 if the inner pointer is invalid
    DecodeAnimatedComponentBasic(componentPtr)
    {
        animatedEntityPtr := this.Mem.ReadPtr(componentPtr + PoE2Offsets.Animated["AnimatedEntityPtr"])
        if !this.IsProbablyValidPointer(animatedEntityPtr)
            return 0

        entityId := this.Mem.ReadUInt(animatedEntityPtr + PoE2Offsets.Entity["Id"])
        namePtr := this.Mem.ReadPtr(animatedEntityPtr + PoE2Offsets.EntityDetails["Path"])
        entityDetailsPtr := this.Mem.ReadPtr(animatedEntityPtr + PoE2Offsets.Entity["EntityDetailsPtr"])

        path := ""
        if this.IsProbablyValidPointer(namePtr)
            path := this.Mem.ReadUnicodeString(namePtr)
        if (path = "" && this.IsProbablyValidPointer(entityDetailsPtr))
            path := this.ReadStdWStringAt(entityDetailsPtr + PoE2Offsets.EntityDetails["Path"])

        if (path = "" && entityId = 0)
            return 0

        return Map(
            "address", componentPtr,
            "animatedEntityPtr", animatedEntityPtr,
            "id", entityId,
            "path", path
        )
    }

    ; Reads the Buffs component status effect vector and samples up to 12 entries.
    ; Returns: Map with statusCount, effectsSample array, flaskLikeCount, timedEffectCount, effectsSummary
    DecodeBuffsComponentBasic(componentPtr)
    {
        statusFirst := this.Mem.ReadInt64(componentPtr + PoE2Offsets.Buffs["StatusEffectPtr"])
        statusLast := this.Mem.ReadInt64(componentPtr + PoE2Offsets.Buffs["StatusEffectPtrLast"])
        if (statusFirst <= 0 || statusLast < statusFirst)
            return 0

        statusCount := Floor((statusLast - statusFirst) / PoE2Offsets.Buffs["StatusEffectStructSize"])
        if (statusCount < 0 || statusCount > 2048)
            return 0

        effectsSample := []
        maxSample := Min(statusCount, 12)
        idx := 0
        while (idx < maxSample)
        {
            entryAddr := statusFirst + (idx * PoE2Offsets.Buffs["StatusEffectStructSize"])
            effect := this.ReadBuffEffectEntryBasic(entryAddr)
            if (effect)
                effectsSample.Push(effect)
            idx += 1
        }

        firstEffect := (effectsSample.Length > 0) ? effectsSample[1] : 0
        effectsSummary := this.BuildBuffSummaryFromEffects(effectsSample)

        return Map(
            "address", componentPtr,
            "statusCount", statusCount,
            "effectsSampleCount", effectsSample.Length,
            "effectsSample", effectsSample,
            "flaskLikeCount", effectsSummary["flaskLikeCount"],
            "timedEffectCount", effectsSummary["timedEffectCount"],
            "effectsSummary", effectsSummary,
            "firstEffect", firstEffect
        )
    }

    ; Reads one StatusEffect struct: name, buffType, totalTime, timeLeft, charges, flaskSlot, effectiveness.
    ; Returns: Map with all status effect fields, or 0 if the entry or buffDef pointer is invalid
    ReadBuffEffectEntryBasic(statusEntryAddress)
    {
        if !this.IsProbablyValidPointer(statusEntryAddress)
            return 0

        buffDefPtr := this.Mem.ReadPtr(statusEntryAddress + PoE2Offsets.StatusEffect["BuffDefinationPtr"])
        if !this.IsProbablyValidPointer(buffDefPtr)
            return 0

        namePtr := this.Mem.ReadPtr(buffDefPtr + PoE2Offsets.BuffDefinition["Name"])
        name := this.IsProbablyValidPointer(namePtr) ? this.Mem.ReadUnicodeString(namePtr) : ""
        buffType := this.Mem.ReadUChar(buffDefPtr + PoE2Offsets.BuffDefinition["BuffType"])
        totalTime := this.Mem.ReadFloat(statusEntryAddress + PoE2Offsets.StatusEffect["TotalTime"])
        timeLeft := this.Mem.ReadFloat(statusEntryAddress + PoE2Offsets.StatusEffect["TimeLeft"])
        sourceEntityId := this.Mem.ReadUInt(statusEntryAddress + PoE2Offsets.StatusEffect["SourceEntityId"])
        charges := this.Mem.ReadShort(statusEntryAddress + PoE2Offsets.StatusEffect["Charges"])
        flaskSlotRaw := this.Mem.ReadShort(statusEntryAddress + PoE2Offsets.StatusEffect["FlaskSlot"])
        effectivenessRaw := this.Mem.ReadShort(statusEntryAddress + PoE2Offsets.StatusEffect["Effectiveness"])
        unknownIdAndEquipmentInfo := this.Mem.ReadUInt(statusEntryAddress + PoE2Offsets.StatusEffect["UnknownIdAndEquipmentInfo"])

        flaskSlot := (flaskSlotRaw >= 0 && flaskSlotRaw < 5) ? (flaskSlotRaw + 1) : 0

        return Map(
            "buffDefPtr", buffDefPtr,
            "name", name,
            "buffType", buffType,
            "totalTime", totalTime,
            "timeLeft", timeLeft,
            "sourceEntityId", sourceEntityId,
            "charges", charges,
            "flaskSlotRaw", flaskSlotRaw,
            "flaskSlot", flaskSlot,
            "isFlaskBuff", buffType = 0x4 ? true : false,
            "effectivenessRaw", effectivenessRaw,
            "effectivenessPercent", 100 + effectivenessRaw,
            "unknownIdAndEquipmentInfo", unknownIdAndEquipmentInfo
        )
    }

    ; Reads the Stats component: statsByItems and statsByBuffs stat pairs, currentWeaponIndex, shapeshift state.
    ; Returns: Map with counts, summaries, and 8-entry samples for each stat source, or 0 on failure
    DecodeStatsComponentBasic(componentPtr)
    {
        statsByItemsPtr := this.Mem.ReadPtr(componentPtr + PoE2Offsets.Stats["StatsByItems"])
        currentWeaponIndex := this.Mem.ReadInt(componentPtr + PoE2Offsets.Stats["CurrentWeaponIndex"])
        shapeshiftPtr := this.Mem.ReadPtr(componentPtr + PoE2Offsets.Stats["ShapeshiftPtr"])
        statsByBuffPtr := this.Mem.ReadPtr(componentPtr + PoE2Offsets.Stats["StatsByBuffAndActions"])

        plausible := (currentWeaponIndex >= 0 && currentWeaponIndex <= 8)
            && (this.IsProbablyValidPointer(statsByItemsPtr)
                || this.IsProbablyValidPointer(statsByBuffPtr)
                || this.IsProbablyValidPointer(shapeshiftPtr))
        if !plausible
            return 0

        statsByItems := this.ReadStatsPairsFromStatsInternal(statsByItemsPtr)
        statsByBuffs := this.ReadStatsPairsFromStatsInternal(statsByBuffPtr)
        statsByItemsSummary := this.BuildStatsSummaryFromPairs(statsByItems)
        statsByBuffsSummary := this.BuildStatsSummaryFromPairs(statsByBuffs)
        statsByItemsSample := []
        statsByBuffsSample := []

        maxSample := 8
        idx := 1
        while (idx <= Min(statsByItems.Length, maxSample))
        {
            statsByItemsSample.Push(statsByItems[idx])
            idx += 1
        }

        idx := 1
        while (idx <= Min(statsByBuffs.Length, maxSample))
        {
            statsByBuffsSample.Push(statsByBuffs[idx])
            idx += 1
        }

        return Map(
            "address", componentPtr,
            "statsByItemsPtr", statsByItemsPtr,
            "statsByBuffAndActionsPtr", statsByBuffPtr,
            "currentWeaponIndex", currentWeaponIndex,
            "isInShapeshiftedForm", this.IsProbablyValidPointer(shapeshiftPtr),
            "statsByItemsCount", statsByItems.Length,
            "statsByBuffAndActionsCount", statsByBuffs.Length,
            "statsByItemsSummary", statsByItemsSummary,
            "statsByBuffAndActionsSummary", statsByBuffsSummary,
            "statsByItemsSample", statsByItemsSample,
            "statsByBuffAndActionsSample", statsByBuffsSample
        )
    }

    ; Reads life, mana, and energy shield vital structs; validates plausibility of all values.
    ; Returns: Map with isAlive, percent fields, regen values, and nested life/mana/energyShield Maps, or 0
    DecodeLifeComponentBasic(componentPtr)
    {
        life := this.ReadVitalStructSnapshot(componentPtr, PoE2Offsets.Life["Health"])
        mana := this.ReadVitalStructSnapshot(componentPtr, PoE2Offsets.Life["Mana"])
        es := this.ReadVitalStructSnapshot(componentPtr, PoE2Offsets.Life["EnergyShield"])

        healthMax := life["max"]
        healthCurrent := life["current"]
        manaMax := mana["max"]
        manaCurrent := mana["current"]
        esMax := es["max"]
        esCurrent := es["current"]

        plausible := (healthMax > 0 && healthMax < 50000000)
            && (healthCurrent >= 0 && healthCurrent <= healthMax + 50000)
            && (manaMax >= 0 && manaMax < 50000000)
            && (manaCurrent >= 0 && manaCurrent <= manaMax + 50000)
            && (esMax >= 0 && esMax < 50000000)
            && (esCurrent >= 0 && esCurrent <= esMax + 50000)
        if !plausible
        {
            ; Fallback: if HP clearly reads as 0 with a plausible max HP, treat as dead.
            ; Handles entities whose life-memory partially degrades after death (max/mana/ES
            ; values become garbage while current-HP remains at the last-written 0).
            if (healthCurrent = 0 && healthMax >= 1 && healthMax < 50000000)
                return Map("address", componentPtr, "isAlive", false)
            return 0
        }

        return Map(
            "address", componentPtr,
            "isAlive", healthCurrent > 0 ? true : false,
            "lifeCurrentPercentMax", life["currentPercentMax"],
            "manaCurrentPercentMax", mana["currentPercentMax"],
            "energyShieldCurrentPercentMax", es["currentPercentMax"],
            "lifeRegen", life["regen"],
            "manaRegen", mana["regen"],
            "energyShieldRegen", es["regen"],
            "life", life,
            "mana", mana,
            "energyShield", es
        )
    }

    ; Reads current charges, perUse cost, and derives remainingUses; caches the component's staticPtr.
    ; Returns: Map with current, perUse, remainingUses, or 0 if values are implausible or both zero
    DecodeChargesComponentBasic(componentPtr)
    {
        chargesInternalPtr := this.Mem.ReadPtr(componentPtr + PoE2Offsets.Charges["ChargesInternalPtr"])
        current := this.Mem.ReadInt(componentPtr + PoE2Offsets.Charges["Current"])
        perUse := this.IsProbablyValidPointer(chargesInternalPtr)
            ? this.Mem.ReadInt(chargesInternalPtr + PoE2Offsets.ChargesInternal["PerUseCharges"])
            : 0

        plausible := (current >= 0 && current <= 100000)
            && (perUse >= 0 && perUse <= 100000)
            && (current > 0 || perUse > 0)
        if !plausible
            return 0

        ; Cache the StaticPtr so we can identify Charges components in inventory items
        ; (item entities lack a named component lookup table)
        if (!this._chargesStaticPtr)
        {
            staticPtr := this.Mem.ReadPtr(componentPtr + PoE2Offsets.ComponentHeader["StaticPtr"])
            if this.IsProbablyValidPointer(staticPtr)
                this._chargesStaticPtr := staticPtr
        }

        remainingUses := (perUse > 0) ? Floor(current / perUse) : 0
        return Map(
            "address", componentPtr,
            "chargesInternalPtr", chargesInternalPtr,
            "current", current,
            "perUse", perUse,
            "remainingUses", remainingUses
        )
    }

    ; Reads the Player component: level (1–100), XP, and player name from the embedded std::wstring.
    ; Returns: Map with name, level, xp, or 0 if level/xp/name fail plausibility checks
    DecodePlayerComponentBasic(componentPtr)
    {
        level := this.Mem.ReadUChar(componentPtr + PoE2Offsets.Player["Level"])
        xp := this.Mem.ReadInt(componentPtr + PoE2Offsets.Player["Xp"])
        name := this.ReadStdWStringAt(componentPtr + PoE2Offsets.Player["Name"])

        plausible := (level > 0 && level <= 100)
            && (xp >= 0 && xp <= 2147483647)
            && (StrLen(name) > 0 && StrLen(name) <= 64)
        if !plausible
            return 0

        return Map(
            "address", componentPtr,
            "name", name,
            "level", level,
            "xp", xp
        )
    }

    ; Reads the TriggerableBlockage component's isBlocked boolean flag.
    ; Returns: Map with isBlocked, or 0 if the raw byte is not a valid boolean
    DecodeTriggerableBlockageComponentBasic(componentPtr)
    {
        isBlockedRaw := this.Mem.ReadUChar(componentPtr + PoE2Offsets.TriggerableBlockage["IsBlocked"])
        if (isBlockedRaw > 1)
            return 0

        return Map(
            "address", componentPtr,
            "isBlocked", isBlockedRaw != 0 ? true : false
        )
    }

    ; Reads the Mods component: rarity, and all five mod arrays (implicit/explicit/enchant/hellscape/crucible).
    ; Returns: summary Map from ReadModsSummaryAt with rarityId and rarity fields added, or 0 on failure
    DecodeModsComponentBasic(componentPtr)
    {
        rarityId := this.Mem.ReadInt(componentPtr + PoE2Offsets.Mods["Rarity"])
        if (rarityId < 0 || rarityId > 5)
            return 0

        summary := this.ReadModsSummaryAt(componentPtr, PoE2Offsets.Mods["AllMods"], componentPtr + PoE2Offsets.Mods["StatsFromMods"])
        if !summary
            return 0

        summary["address"] := componentPtr
        summary["sourceType"] := "Mods"
        summary["rarityId"] := rarityId
        summary["rarity"] := this.RarityNameFromId(rarityId)
        return summary
    }

    ; Reads the ObjectMagicProperties component using the same mod/stats layout as Mods component.
    ; Returns: summary Map from ReadModsSummaryAt with rarityId and rarity fields added, or 0 on failure
    DecodeObjectMagicPropertiesComponentBasic(componentPtr)
    {
        rarityId := this.Mem.ReadInt(componentPtr + PoE2Offsets.ObjectMagicProperties["Rarity"])
        if (rarityId < 0 || rarityId > 5)
            return 0

        summary := this.ReadModsSummaryAt(componentPtr, PoE2Offsets.ObjectMagicProperties["AllMods"], componentPtr + PoE2Offsets.ObjectMagicProperties["StatsFromMods"])
        if !summary
            return 0

        summary["address"] := componentPtr
        summary["sourceType"] := "ObjectMagicProperties"
        summary["rarityId"] := rarityId
        summary["rarity"] := this.RarityNameFromId(rarityId)
        return summary
    }

    ; Reads all five mod vectors (implicit/explicit/enchant/hellscape/crucible) and statsFromMods at given offsets.
    ; Returns: summary Map with counts, statsFromMods pairs, and all five mod arrays, or 0 if everything is empty
    ReadModsSummaryAt(componentPtr, allModsBaseOffset, statsFromModsPtr)
    {
        implicitMods := this.ReadModArrayFromVector(componentPtr + allModsBaseOffset + (0x18 * 0), 12)
        explicitMods := this.ReadModArrayFromVector(componentPtr + allModsBaseOffset + (0x18 * 1), 12)
        enchantMods := this.ReadModArrayFromVector(componentPtr + allModsBaseOffset + (0x18 * 2), 12)
        hellscapeMods := this.ReadModArrayFromVector(componentPtr + allModsBaseOffset + (0x18 * 3), 12)
        crucibleMods := this.ReadModArrayFromVector(componentPtr + allModsBaseOffset + (0x18 * 4), 12)

        statPairs := this.ReadStatsPairsFromStatsInternal(statsFromModsPtr, 64)

        totalMods := implicitMods.Length + explicitMods.Length + enchantMods.Length + hellscapeMods.Length + crucibleMods.Length
        if (totalMods = 0 && statPairs.Length = 0)
            return 0

        return Map(
            "implicitCount", implicitMods.Length,
            "explicitCount", explicitMods.Length,
            "enchantCount", enchantMods.Length,
            "hellscapeCount", hellscapeMods.Length,
            "crucibleCount", crucibleMods.Length,
            "totalMods", totalMods,
            "statsFromModsCount", statPairs.Length,
            "statsFromMods", statPairs,
            "implicitMods", implicitMods,
            "explicitMods", explicitMods,
            "enchantMods", enchantMods,
            "hellscapeMods", hellscapeMods,
            "crucibleMods", crucibleMods
        )
    }

    ; Reads the NPC component's owner entity pointer and resolves basic identity via ReadEntityIdentityBasic.
    ; Returns: Map with ownerEntityPtr, owner identity Map, and isNpc flag
    DecodeNpcComponentBasic(componentPtr)
    {
        ownerEntityPtr := this.Mem.ReadPtr(componentPtr + PoE2Offsets.ComponentHeader["EntityPtr"])
        owner := this.ReadEntityIdentityBasic(ownerEntityPtr, 120)

        return Map(
            "address", componentPtr,
            "ownerEntityPtr", ownerEntityPtr,
            "owner", owner,
            "isNpc", true
        )
    }


    ; Reads the MinimapIcon component's owner entity and staticPtr for minimap icon lookup.
    ; Returns: Map with ownerEntityPtr, owner identity, staticPtr, and hasMinimapIcon, or 0 on invalid owner
    DecodeMinimapIconComponentBasic(componentPtr)
    {
        staticPtr := this.Mem.ReadPtr(componentPtr + PoE2Offsets.ComponentHeader["StaticPtr"])
        ownerEntityPtr := this.Mem.ReadPtr(componentPtr + PoE2Offsets.ComponentHeader["EntityPtr"])
        if !this.IsProbablyValidPointer(ownerEntityPtr)
            return 0
        owner := this.ReadEntityIdentityBasic(ownerEntityPtr, 120)

        return Map(
            "address", componentPtr,
            "ownerEntityPtr", ownerEntityPtr,
            "owner", owner,
            "staticPtr", staticPtr,
            "hasMinimapIcon", true
        )
    }

    ; Reads the DiesAfterTime component's owner entity and staticPtr, used to track temporary entities.
    ; Returns: Map with ownerEntityPtr, owner identity, staticPtr, and diesAfterTime flag, or 0 on invalid owner
    DecodeDiesAfterTimeComponentBasic(componentPtr)
    {
        staticPtr := this.Mem.ReadPtr(componentPtr + PoE2Offsets.ComponentHeader["StaticPtr"])
        ownerEntityPtr := this.Mem.ReadPtr(componentPtr + PoE2Offsets.ComponentHeader["EntityPtr"])
        if !this.IsProbablyValidPointer(ownerEntityPtr)
            return 0
        owner := this.ReadEntityIdentityBasic(ownerEntityPtr, 120)

        return Map(
            "address", componentPtr,
            "ownerEntityPtr", ownerEntityPtr,
            "owner", owner,
            "staticPtr", staticPtr,
            "diesAfterTime", true
        )
    }
    ; ── Core pointer validation ────────────────────────────────────────────────

    ; Returns true if value is within the plausible user-space pointer range (0x10000–0x7FFFFFFFFFFF).
    IsProbablyValidPointer(value)
    {
        return value > 0x10000 && value < 0x7FFFFFFFFFFF
    }

    ; Formats an integer as an uppercase hex string prefixed with "0x".
    ; Returns: string like "0x1A2B3C"
    static Hex(value)
    {
        return Format("0x{:X}", value)
    }
}
