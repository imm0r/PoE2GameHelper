; PoE2PlayerReader.ahk
; Player stats/vitals/buffs/charges layer — extends PoE2PlayerComponentsReader.
;
; Reads: stat pairs, vitals (Life/Mana/ES/Spirit/Rage), buff effects,
; charges (Power/Frenzy/Endurance), and the top-level ReadPlayer* wrappers.
;
; Inheritance chain: PoE2GameStateReader -> ... -> PoE2PlayerReader -> PoE2PlayerComponentsReader

class PoE2PlayerReader extends PoE2PlayerComponentsReader
{
    ; Collects all (key, value) stat pairs from a Stats component snapshot.
    ; Merges the statsByItems and statsByBuffAndActions arrays into one flat array.
    ; Returns: Array of Map("key", ..., "value", ...) pairs
    CollectStatsPairs(playerStatsComponent)
    {
        out := []
        if !(playerStatsComponent && Type(playerStatsComponent) = "Map")
            return out

        items := playerStatsComponent.Has("statsByItems") ? playerStatsComponent["statsByItems"] : 0
        buffs := playerStatsComponent.Has("statsByBuffAndActions") ? playerStatsComponent["statsByBuffAndActions"] : 0

        if (items && Type(items) = "Array")
        {
            for _, pair in items
                out.Push(pair)
        }

        if (buffs && Type(buffs) = "Array")
        {
            for _, pair in buffs
                out.Push(pair)
        }

        return out
    }

    ; Converts a flat stat pairs array into a Map of statId → statValue.
    ; When a key appears multiple times, keeps the entry with the largest absolute value.
    BuildStatsPairMap(statsPairs)
    {
        out := Map()
        if !(statsPairs && Type(statsPairs) = "Array")
            return out

        for _, pair in statsPairs
        {
            if !(pair && Type(pair) = "Map" && pair.Has("key") && pair.Has("value"))
                continue

            key := pair["key"]
            value := pair["value"]

            if !out.Has(key) || (Abs(value) > Abs(out[key]))
                out[key] := value
        }

        return out
    }

    /*
        Rage/Spirit key calibration (PoE2, calibrated 2026-03-25):
        - RageCurrent: key 7011
        - RageMax: key 11187
        - Legacy Rage fallback: 7009 / 7008
        - SpiritCurrent: key 16179
        - SpiritMax: key 16205 (secondary: 11187)
        - SpiritReserved is derived as (SpiritMax - SpiritCurrent)
    */

    ; Locates Spirit current/max values in the stats pair map using calibrated key IDs.
    ; Primary keys: current=16179, max=16205 or 11187 (whichever is larger and in range).
    ; Returns: Map with current, max, reserved, source; or 0 if not found
    ReadSpiritSnapshotFromStats(playerStatsComponent, statShift := "")
    {
        statsPairs := this.CollectStatsPairs(playerStatsComponent)
        if !(statsPairs && Type(statsPairs) = "Array" && statsPairs.Length)
            return 0

        pairMap := this.BuildStatsPairMap(statsPairs)

        forcedSpiritCurrentKeys := [16179]
        forcedSpiritMaxKeys := [16205, 11187]

        forcedCurrent := -1
        forcedCurrentKey := 0
        for _, key in forcedSpiritCurrentKeys
        {
            if pairMap.Has(key)
            {
                val := pairMap[key]
                if (val >= 0 && val <= 400)
                {
                    forcedCurrent := val
                    forcedCurrentKey := key
                    break
                }
            }
        }

        forcedMax := -1
        forcedMaxKey := 0
        for _, key in forcedSpiritMaxKeys
        {
            if pairMap.Has(key)
            {
                val := pairMap[key]
                if (val >= 0 && val <= 400)
                {
                    if (val > forcedMax)
                    {
                        forcedMax := val
                        forcedMaxKey := key
                    }
                }
            }
        }

        if (forcedCurrent >= 0 && forcedMax >= forcedCurrent && forcedMax > 0)
        {
            forcedReserved := forcedMax - forcedCurrent
            return Map(
                "current", forcedCurrent,
                "max", forcedMax,
                "reserved", forcedReserved,
                "currentKey", forcedCurrentKey,
                "maxKey", forcedMaxKey,
                "source", "stats-forced"
            )
        }

        return 0
    }

    ; Locates Rage current/max values in the stats pair map using calibrated key IDs.
    ; Tries primary keys 7011/11187 first, then falls back to legacy keys 7009/7008.
    ; Returns: Map with current, max, shift, source; or 0 if not found
    ReadRageSnapshotFromStats(playerStatsComponent)
    {
        statsPairs := this.CollectStatsPairs(playerStatsComponent)
        if !(statsPairs && Type(statsPairs) = "Array" && statsPairs.Length)
            return 0

        pairMap := this.BuildStatsPairMap(statsPairs)

        if (pairMap.Has(7011) && pairMap.Has(11187))
        {
            forcedCurrent := pairMap[7011]
            forcedMax := pairMap[11187]
            if (forcedCurrent >= 0 && forcedCurrent <= 150 && forcedMax >= forcedCurrent && forcedMax <= 200)
            {
                return Map(
                    "current", forcedCurrent,
                    "max", forcedMax,
                    "currentKey", 7011,
                    "maxKey", 11187,
                    "shift", 2,
                    "source", "stats-forced"
                )
            }
        }

        if (pairMap.Has(7009) && pairMap.Has(7008))
        {
            legacyCurrent := pairMap[7009]
            legacyMax := pairMap[7008]
            if (legacyCurrent >= 0 && legacyCurrent <= 150 && legacyMax >= legacyCurrent && legacyMax <= 200)
            {
                return Map(
                    "current", legacyCurrent,
                    "max", legacyMax,
                    "currentKey", 7009,
                    "maxKey", 7008,
                    "shift", 0,
                    "source", "stats-forced-legacy"
                )
            }
        }

        return 0
    }

    ; Reads Life, Mana, and Energy Shield vitals for the local player.
    ; Tries a named Life component lookup first, then falls back to a component scan.
    ; Returns: BuildVitalsResult Map, or 0 on failure
    ReadPlayerVitals(localPlayerPtr, playerStatsComponent := 0)
    {
        if !this.IsProbablyValidPointer(localPlayerPtr)
            return 0

        lifeByLookup := this.FindEntityComponentAddress(localPlayerPtr, "Life")
        if this.IsProbablyValidPointer(lifeByLookup)
        {
            healthVital := this.ReadVitalStructSnapshot(lifeByLookup, PoE2Offsets.Life["Health"])
            manaVital   := this.ReadVitalStructSnapshot(lifeByLookup, PoE2Offsets.Life["Mana"])
            esVital     := this.ReadVitalStructSnapshot(lifeByLookup, PoE2Offsets.Life["EnergyShield"])

            plausible := (healthVital["max"] > 0 && healthVital["max"] < 500000)
                && (healthVital["current"] >= 0 && healthVital["current"] <= healthVital["max"] + 50000)
                && (manaVital["max"] >= 0 && manaVital["max"] < 500000)
                && (manaVital["current"] >= 0 && manaVital["current"] <= manaVital["max"] + 50000)
                && (esVital["max"] >= 0 && esVital["max"] < 500000)
                && (esVital["current"] >= 0 && esVital["current"] <= esVital["max"] + 50000)

            if (plausible)
                return this.BuildVitalsResult(localPlayerPtr, lifeByLookup, healthVital, manaVital, esVital, playerStatsComponent, 1)
        }

        compVecFirst := this.Mem.ReadInt64(localPlayerPtr + PoE2Offsets.Entity["ComponentsVec"])
        compVecLast  := this.Mem.ReadInt64(localPlayerPtr + PoE2Offsets.Entity["ComponentsVecLast"])
        if (compVecFirst <= 0 || compVecLast < compVecFirst)
            return 0

        ptrSize        := A_PtrSize
        componentCount := Floor((compVecLast - compVecFirst) / ptrSize)
        maxEntries     := Min(componentCount, 96)

        idx := 0
        while (idx < maxEntries)
        {
            componentPtr := this.Mem.ReadPtr(compVecFirst + (idx * ptrSize))
            if this.IsProbablyValidPointer(componentPtr)
            {
                ownerEntityPtr := this.Mem.ReadPtr(componentPtr + PoE2Offsets.ComponentHeader["EntityPtr"])
                if (ownerEntityPtr = localPlayerPtr)
                {
                    healthVital := this.ReadVitalStructSnapshot(componentPtr, PoE2Offsets.Life["Health"])
                    manaVital   := this.ReadVitalStructSnapshot(componentPtr, PoE2Offsets.Life["Mana"])
                    esVital     := this.ReadVitalStructSnapshot(componentPtr, PoE2Offsets.Life["EnergyShield"])

                    plausible := (healthVital["max"] > 0 && healthVital["max"] < 500000)
                        && (healthVital["current"] >= 0 && healthVital["current"] <= healthVital["max"] + 50000)
                        && (manaVital["max"] >= 0 && manaVital["max"] < 500000)
                        && (manaVital["current"] >= 0 && manaVital["current"] <= manaVital["max"] + 50000)
                        && (esVital["max"] >= 0 && esVital["max"] < 500000)
                        && (esVital["current"] >= 0 && esVital["current"] <= esVital["max"] + 50000)

                    if (plausible)
                        return this.BuildVitalsResult(localPlayerPtr, componentPtr, healthVital, manaVital, esVital, playerStatsComponent, maxEntries)
                }
            }
            idx += 1
        }

        return 0
    }

    ; Assembles the full vitals result Map from pre-read vital snapshots and stats.
    ; Appends Spirit and Rage sub-maps when available; derives spiritReserved inline.
    ; Returns: Map with localPlayerPtr, lifeComponentPtr, componentsScanned, stats
    BuildVitalsResult(localPlayerPtr, lifeComponentPtr, healthVital, manaVital, esVital, playerStatsComponent, componentsScanned)
    {
        rage := this.ReadRageSnapshotFromStats(playerStatsComponent)
        if !rage
            rage := this.ReadRageSnapshotFromStats(this.ReadPlayerStatsComponent(localPlayerPtr))

        statShift := (rage && Type(rage) = "Map" && rage.Has("shift")) ? rage["shift"] : ""

        spirit := this.ReadSpiritSnapshotFromStats(playerStatsComponent, statShift)
        if !spirit
            spirit := this.ReadSpiritSnapshotFromStats(this.ReadPlayerStatsComponent(localPlayerPtr), statShift)

        stats := Map(
            "lifeCurrent",    healthVital["current"],
            "lifeMax",        healthVital["max"],
            "manaCurrent",    manaVital["current"],
            "manaMax",        manaVital["max"],
            "esCurrent",      esVital["current"],
            "esMax",          esVital["max"],
            "isAlive",        healthVital["current"] > 0 ? true : false,
            "life",           healthVital,
            "mana",           manaVital,
            "energyShield",   esVital,
            "spiritCurrent",  0,
            "spiritMax",      0,
            "spiritReserved", 0,
            "spirit",         0,
            "rageCurrent",    0,
            "rageMax",        0,
            "rage",           0
        )

        if spirit
        {
            stats["spiritCurrent"]  := spirit["current"]
            stats["spiritMax"]      := spirit["max"]
            stats["spiritReserved"] := spirit["reserved"]
            stats["spirit"]         := spirit["current"]
            stats["spiritResource"] := spirit
        }

        if rage
        {
            stats["rageCurrent"]  := rage["current"]
            stats["rageMax"]      := rage["max"]
            stats["rage"]         := rage["current"]
            stats["rageResource"] := rage
        }

        return Map(
            "localPlayerPtr",    localPlayerPtr,
            "lifeComponentPtr",  lifeComponentPtr,
            "componentsScanned", componentsScanned,
            "stats",             stats
        )
    }

    ; Finds and reads the Player component: character name, level, and XP.
    ; Tries a named lookup first; falls back to a full scan requiring score >= 2.
    ; Returns: Map with name, level, xp, score; or 0 if no plausible component found
    ReadPlayerComponent(localPlayerPtr)
    {
        if !this.IsProbablyValidPointer(localPlayerPtr)
            return 0

        compVecFirst := this.Mem.ReadInt64(localPlayerPtr + PoE2Offsets.Entity["ComponentsVec"])
        compVecLast := this.Mem.ReadInt64(localPlayerPtr + PoE2Offsets.Entity["ComponentsVecLast"])
        if (compVecFirst <= 0 || compVecLast < compVecFirst)
            return 0

        playerByLookup := this.FindEntityComponentAddress(localPlayerPtr, "Player")
        if this.IsProbablyValidPointer(playerByLookup)
        {
            level := this.Mem.ReadUChar(playerByLookup + PoE2Offsets.Player["Level"])
            xp := this.Mem.ReadInt(playerByLookup + PoE2Offsets.Player["Xp"])
            name := this.ReadStdWStringAt(playerByLookup + PoE2Offsets.Player["Name"])

            plausibleLevel := (level > 0 && level <= 100)
            plausibleXp := (xp >= 0 && xp <= 2147483647)
            plausibleName := (StrLen(name) > 0 && StrLen(name) <= 64)

            score := 0
            if (plausibleLevel)
                score += 1
            if (plausibleXp)
                score += 1
            if (plausibleName)
                score += 1

            if (score >= 2)
            {
                return Map(
                    "address", playerByLookup,
                    "name", name,
                    "level", level,
                    "xp", xp,
                    "componentsScanned", 1,
                    "score", score
                )
            }
        }

        ptrSize := A_PtrSize
        totalBytes := compVecLast - compVecFirst
        componentCount := Floor(totalBytes / ptrSize)
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
                    level := this.Mem.ReadUChar(componentPtr + PoE2Offsets.Player["Level"])
                    xp := this.Mem.ReadInt(componentPtr + PoE2Offsets.Player["Xp"])
                    name := this.ReadStdWStringAt(componentPtr + PoE2Offsets.Player["Name"])

                    plausibleLevel := (level > 0 && level <= 100)
                    plausibleXp := (xp >= 0 && xp <= 2147483647)
                    plausibleName := (StrLen(name) > 0 && StrLen(name) <= 64)

                    score := 0
                    if (plausibleLevel)
                        score += 1
                    if (plausibleXp)
                        score += 1
                    if (plausibleName)
                        score += 1

                    if (score > bestScore)
                    {
                        bestScore := score
                        best := Map(
                            "address", componentPtr,
                            "name", name,
                            "level", level,
                            "xp", xp,
                            "componentsScanned", maxEntries,
                            "score", score
                        )
                    }

                    if (score = 3)
                        break
                }
            }

            idx += 1
        }

        return (bestScore >= 2) ? best : 0
    }

    ; Finds and reads the Stats component for the local player entity.
    ; Reads stat pairs from both statsByItems and statsByBuffAndActions sub-structures.
    ; Returns: Map with pair arrays, summaries, currentWeaponIndex; or 0 on failure
    ReadPlayerStatsComponent(localPlayerPtr)
    {
        if !this.IsProbablyValidPointer(localPlayerPtr)
            return 0

        compVecFirst := this.Mem.ReadInt64(localPlayerPtr + PoE2Offsets.Entity["ComponentsVec"])
        compVecLast := this.Mem.ReadInt64(localPlayerPtr + PoE2Offsets.Entity["ComponentsVecLast"])
        if (compVecFirst <= 0 || compVecLast < compVecFirst)
            return 0

        statsByLookup := this.FindEntityComponentAddress(localPlayerPtr, "Stats")
        if this.IsProbablyValidPointer(statsByLookup)
        {
            statsByItemsPtr := this.Mem.ReadPtr(statsByLookup + PoE2Offsets.Stats["StatsByItems"])
            currentWeaponIndex := this.Mem.ReadInt(statsByLookup + PoE2Offsets.Stats["CurrentWeaponIndex"])
            shapeshiftPtr := this.Mem.ReadPtr(statsByLookup + PoE2Offsets.Stats["ShapeshiftPtr"])
            statsByBuffPtr := this.Mem.ReadPtr(statsByLookup + PoE2Offsets.Stats["StatsByBuffAndActions"])

            plausible := (currentWeaponIndex >= 0 && currentWeaponIndex <= 8)
                && (this.IsProbablyValidPointer(statsByItemsPtr)
                    || this.IsProbablyValidPointer(statsByBuffPtr)
                    || this.IsProbablyValidPointer(shapeshiftPtr))

            if (plausible)
            {
                statsByItems := this.ReadStatsPairsFromStatsInternal(statsByItemsPtr)
                statsByBuffs := this.ReadStatsPairsFromStatsInternal(statsByBuffPtr)
                statsByItemsSummary := this.BuildStatsSummaryFromPairs(statsByItems)
                statsByBuffsSummary := this.BuildStatsSummaryFromPairs(statsByBuffs)
                return Map(
                    "address", statsByLookup,
                    "currentWeaponIndex", currentWeaponIndex,
                    "isInShapeshiftedForm", this.IsProbablyValidPointer(shapeshiftPtr),
                    "statsByItemsCount", statsByItems.Length,
                    "statsByBuffAndActionsCount", statsByBuffs.Length,
                    "statsByItemsSummary", statsByItemsSummary,
                    "statsByBuffAndActionsSummary", statsByBuffsSummary,
                    "statsByItems", statsByItems,
                    "statsByBuffAndActions", statsByBuffs
                )
            }
        }

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
                    statsByItemsPtr := this.Mem.ReadPtr(componentPtr + PoE2Offsets.Stats["StatsByItems"])
                    currentWeaponIndex := this.Mem.ReadInt(componentPtr + PoE2Offsets.Stats["CurrentWeaponIndex"])
                    shapeshiftPtr := this.Mem.ReadPtr(componentPtr + PoE2Offsets.Stats["ShapeshiftPtr"])
                    statsByBuffPtr := this.Mem.ReadPtr(componentPtr + PoE2Offsets.Stats["StatsByBuffAndActions"])

                    plausible := (currentWeaponIndex >= 0 && currentWeaponIndex <= 8)
                        && (this.IsProbablyValidPointer(statsByItemsPtr)
                            || this.IsProbablyValidPointer(statsByBuffPtr)
                            || this.IsProbablyValidPointer(shapeshiftPtr))

                    if (plausible)
                    {
                        statsByItems := this.ReadStatsPairsFromStatsInternal(statsByItemsPtr)
                        statsByBuffs := this.ReadStatsPairsFromStatsInternal(statsByBuffPtr)
                        statsByItemsSummary := this.BuildStatsSummaryFromPairs(statsByItems)
                        statsByBuffsSummary := this.BuildStatsSummaryFromPairs(statsByBuffs)
                        return Map(
                            "address", componentPtr,
                            "currentWeaponIndex", currentWeaponIndex,
                            "isInShapeshiftedForm", this.IsProbablyValidPointer(shapeshiftPtr),
                            "statsByItemsCount", statsByItems.Length,
                            "statsByBuffAndActionsCount", statsByBuffs.Length,
                            "statsByItemsSummary", statsByItemsSummary,
                            "statsByBuffAndActionsSummary", statsByBuffsSummary,
                            "statsByItems", statsByItems,
                            "statsByBuffAndActions", statsByBuffs
                        )
                    }
                }
            }

            idx += 1
        }

        return 0
    }

    ; Reads (key, value) stat pairs from a StatsInternal sub-structure's vector.
    ; Each pair is 8 bytes: 4-byte int key followed by 4-byte int value.
    ; Returns: Array of Map("key", ..., "value", ...) or empty array on invalid input
    ReadStatsPairsFromStatsInternal(statsInternalPtr, maxPairs := 2048)
    {
        out := []
        if !this.IsProbablyValidPointer(statsInternalPtr)
            return out

        vecFirst := this.Mem.ReadInt64(statsInternalPtr + PoE2Offsets.Stats["StatsInternalStatsVector"])
        vecLast := this.Mem.ReadInt64(statsInternalPtr + PoE2Offsets.Stats["StatsInternalStatsVectorLast"])
        if (vecFirst <= 0 || vecLast < vecFirst)
            return out

        pairSize := 8
        pairCount := Floor((vecLast - vecFirst) / pairSize)
        if (pairCount <= 0)
            return out

        maxRead := Min(pairCount, maxPairs)
        idx := 0
        while (idx < maxRead)
        {
            addr := vecFirst + (idx * pairSize)
            key := this.Mem.ReadInt(addr + PoE2Offsets.StatPair["Key"])
            value := this.Mem.ReadInt(addr + PoE2Offsets.StatPair["Value"])
            out.Push(Map("key", key, "value", value))
            idx += 1
        }

        return out
    }

    ; Builds display statistics from a flat stat pairs array.
    ; Returns a sample of the first N pairs and top-N by absolute value via insertion sort,
    ; plus count/sum aggregates (totalCount, positiveCount, negativeCount, etc.).
    BuildStatsSummaryFromPairs(statsPairs, sampleSize := 8, topAbsSize := 5)
    {
        sample := []
        topAbs := []

        totalCount := 0
        nonZeroCount := 0
        positiveCount := 0
        negativeCount := 0
        zeroCount := 0
        sumPositive := 0
        sumNegative := 0
        maxValue := 0
        minValue := 0
        hasRange := false

        if !(statsPairs && Type(statsPairs) = "Array")
        {
            return Map(
                "totalCount", 0,
                "nonZeroCount", 0,
                "positiveCount", 0,
                "negativeCount", 0,
                "zeroCount", 0,
                "sumPositive", 0,
                "sumNegative", 0,
                "maxValue", 0,
                "minValue", 0,
                "sample", sample,
                "topAbs", topAbs
            )
        }

        for idx, pair in statsPairs
        {
            if !(pair && Type(pair) = "Map" && pair.Has("value"))
                continue

            val := pair["value"]
            key := pair.Has("key") ? pair["key"] : 0

            totalCount += 1
            if !hasRange
            {
                maxValue := val
                minValue := val
                hasRange := true
            }
            else
            {
                if (val > maxValue)
                    maxValue := val
                if (val < minValue)
                    minValue := val
            }

            if (val > 0)
            {
                positiveCount += 1
                nonZeroCount += 1
                sumPositive += val
            }
            else if (val < 0)
            {
                negativeCount += 1
                nonZeroCount += 1
                sumNegative += val
            }
            else
            {
                zeroCount += 1
            }

            if (sample.Length < sampleSize)
                sample.Push(Map("key", key, "value", val))

            absVal := Abs(val)
            topEntry := Map("key", key, "value", val, "absValue", absVal)
            inserted := false
            insertIdx := 1
            while (insertIdx <= topAbs.Length)
            {
                if (absVal > topAbs[insertIdx]["absValue"])
                {
                    topAbs.InsertAt(insertIdx, topEntry)
                    inserted := true
                    break
                }
                insertIdx += 1
            }

            if !inserted && (topAbs.Length < topAbsSize)
                topAbs.Push(topEntry)

            if (topAbs.Length > topAbsSize)
                topAbs.Pop()
        }

        if !hasRange
        {
            maxValue := 0
            minValue := 0
        }

        return Map(
            "totalCount", totalCount,
            "nonZeroCount", nonZeroCount,
            "positiveCount", positiveCount,
            "negativeCount", negativeCount,
            "zeroCount", zeroCount,
            "sumPositive", sumPositive,
            "sumNegative", sumNegative,
            "maxValue", maxValue,
            "minValue", minValue,
            "sample", sample,
            "topAbs", topAbs
        )
    }

    ; Converts a raw buff effects list into a readable summary Map.
    ; Tracks by-type counts, per-slot flask activity, and top-N effects by time remaining.
    ; Params: sourceSelfId - player entity ID used to identify self-sourced buffs
    BuildBuffSummaryFromEffects(effects, sourceSelfId := 0, topTimeSize := 5)
    {
        byType := Map()
        byFlaskSlot := Map(1, 0, 2, 0, 3, 0, 4, 0, 5, 0)
        topTimeLeft := []

        totalCount := 0
        flaskLikeCount := 0
        timedEffectCount := 0
        selfSourceCount := 0
        positiveChargesCount := 0

        if !(effects && Type(effects) = "Array")
        {
            return Map(
                "totalCount", 0,
                "flaskLikeCount", 0,
                "timedEffectCount", 0,
                "selfSourceCount", 0,
                "positiveChargesCount", 0,
                "byType", byType,
                "byFlaskSlot", byFlaskSlot,
                "topTimeLeft", topTimeLeft
            )
        }

        for _, effect in effects
        {
            if !(effect && Type(effect) = "Map")
                continue

            totalCount += 1

            buffType := effect.Has("buffType") ? effect["buffType"] : -1
            keyType := buffType ""
            byType[keyType] := byType.Has(keyType) ? (byType[keyType] + 1) : 1

            if effect.Has("isFlaskBuff") && effect["isFlaskBuff"]
                flaskLikeCount += 1

            totalTime := effect.Has("totalTime") ? effect["totalTime"] : 0
            timeLeft := effect.Has("timeLeft") ? effect["timeLeft"] : 0
            if (totalTime > 0 || timeLeft > 0)
                timedEffectCount += 1

            sourceId := effect.Has("sourceEntityId") ? effect["sourceEntityId"] : 0
            if (sourceSelfId != 0 && sourceId = sourceSelfId)
                selfSourceCount += 1

            charges := effect.Has("charges") ? effect["charges"] : 0
            if (charges > 0)
                positiveChargesCount += 1

            slot := effect.Has("flaskSlot") ? effect["flaskSlot"] : 0
            if (slot >= 1 && slot <= 5)
                byFlaskSlot[slot] := byFlaskSlot[slot] + 1

            if (timeLeft > 0)
            {
                topEntry := Map(
                    "timeLeft", timeLeft,
                    "totalTime", totalTime,
                    "name", effect.Has("name") ? effect["name"] : "",
                    "buffType", buffType,
                    "flaskSlot", slot
                )

                inserted := false
                insertIdx := 1
                while (insertIdx <= topTimeLeft.Length)
                {
                    if (timeLeft > topTimeLeft[insertIdx]["timeLeft"])
                    {
                        topTimeLeft.InsertAt(insertIdx, topEntry)
                        inserted := true
                        break
                    }
                    insertIdx += 1
                }

                if !inserted && (topTimeLeft.Length < topTimeSize)
                    topTimeLeft.Push(topEntry)

                if (topTimeLeft.Length > topTimeSize)
                    topTimeLeft.Pop()
            }
        }

        return Map(
            "totalCount", totalCount,
            "flaskLikeCount", flaskLikeCount,
            "timedEffectCount", timedEffectCount,
            "selfSourceCount", selfSourceCount,
            "positiveChargesCount", positiveChargesCount,
            "byType", byType,
            "byFlaskSlot", byFlaskSlot,
            "topTimeLeft", topTimeLeft
        )
    }

    ; Finds and reads the Buffs component for the local player entity.
    ; Deduplicates effects by (buffDefPtr, sourceEntityId) and builds flask slot state.
    ; Returns: Map with effects, effectsSummary, flaskActive, flaskSlots; or 0
    ReadPlayerBuffsComponent(localPlayerPtr)
    {
        if !this.IsProbablyValidPointer(localPlayerPtr)
            return 0

        playerId := this.Mem.ReadUInt(localPlayerPtr + PoE2Offsets.Entity["Id"])
        compVecFirst := this.Mem.ReadInt64(localPlayerPtr + PoE2Offsets.Entity["ComponentsVec"])
        compVecLast := this.Mem.ReadInt64(localPlayerPtr + PoE2Offsets.Entity["ComponentsVecLast"])
        if (compVecFirst <= 0 || compVecLast < compVecFirst)
            return 0

        buffsByLookup := this.FindEntityComponentAddress(localPlayerPtr, "Buffs")
        if this.IsProbablyValidPointer(buffsByLookup)
        {
            statusVecFirst := this.Mem.ReadInt64(buffsByLookup + PoE2Offsets.Buffs["StatusEffectPtr"])
            statusVecLast := this.Mem.ReadInt64(buffsByLookup + PoE2Offsets.Buffs["StatusEffectPtrLast"])
            if (statusVecFirst > 0 && statusVecLast >= statusVecFirst)
            {
                ptrSizeLookup := A_PtrSize
                statusCountLookup := Floor((statusVecLast - statusVecFirst) / ptrSizeLookup)
                if (statusCountLookup > 0 && statusCountLookup <= 512)
                {
                    effectsLookup := []
                    flaskSlotsLookup := Map()
                    flaskActiveLookup := Map(1, false, 2, false, 3, false, 4, false, 5, false)
                    validEffectsLookup := 0
                    seenKeysLookup := Map()

                    maxStatusReadLookup := Min(statusCountLookup, 160)
                    statusIdxLookup := 0
                    while (statusIdxLookup < maxStatusReadLookup)
                    {
                        statusPtrLookup := this.Mem.ReadPtr(statusVecFirst + (statusIdxLookup * ptrSizeLookup))
                        if this.IsProbablyValidPointer(statusPtrLookup)
                        {
                            effectLookup := this.ReadBuffEffectEntryBasic(statusPtrLookup)
                            if (effectLookup)
                            {
                                dedupKey := Format("{:X}-{}", effectLookup["buffDefPtr"], effectLookup["sourceEntityId"])
                                if !seenKeysLookup.Has(dedupKey)
                                {
                                    seenKeysLookup[dedupKey] := true
                                    validEffectsLookup += 1
                                    effectsLookup.Push(effectLookup)

                                    if ((playerId = 0 || effectLookup["sourceEntityId"] = playerId)
                                        && effectLookup["isFlaskBuff"]
                                        && effectLookup["flaskSlot"] >= 1
                                        && effectLookup["flaskSlot"] <= 5)
                                    {
                                        slotLookup := effectLookup["flaskSlot"]
                                        flaskActiveLookup[slotLookup] := true
                                        flaskSlotsLookup[slotLookup] := Map(
                                            "active", true,
                                            "buffCharges", effectLookup["charges"],
                                            "timeLeft", effectLookup["timeLeft"],
                                            "totalTime", effectLookup["totalTime"],
                                            "sourceEntityId", effectLookup["sourceEntityId"],
                                            "name", effectLookup["name"]
                                        )
                                    }
                                }
                            }
                        }

                        statusIdxLookup += 1
                    }

                    if (validEffectsLookup > 0)
                    {
                        effectsSummaryLookup := this.BuildBuffSummaryFromEffects(effectsLookup, playerId)
                        return Map(
                            "address", buffsByLookup,
                            "statusCount", statusCountLookup,
                            "effectsRead", effectsLookup.Length,
                            "effects", effectsLookup,
                            "effectsSummary", effectsSummaryLookup,
                            "flaskActive", flaskActiveLookup,
                            "flaskSlots", flaskSlotsLookup
                        )
                    }
                }
            }
        }

        ptrSize := A_PtrSize
        componentCount := Floor((compVecLast - compVecFirst) / ptrSize)
        maxComponents := Min(componentCount, 96)

        compIdx := 0
        while (compIdx < maxComponents)
        {
            componentPtr := this.Mem.ReadPtr(compVecFirst + (compIdx * ptrSize))
            if !this.IsProbablyValidPointer(componentPtr)
            {
                compIdx += 1
                continue
            }

            ownerEntityPtr := this.Mem.ReadPtr(componentPtr + PoE2Offsets.ComponentHeader["EntityPtr"])
            if (ownerEntityPtr != localPlayerPtr)
            {
                compIdx += 1
                continue
            }

            statusVecFirst := this.Mem.ReadInt64(componentPtr + PoE2Offsets.Buffs["StatusEffectPtr"])
            statusVecLast := this.Mem.ReadInt64(componentPtr + PoE2Offsets.Buffs["StatusEffectPtrLast"])
            if (statusVecFirst <= 0 || statusVecLast < statusVecFirst)
            {
                compIdx += 1
                continue
            }

            statusCount := Floor((statusVecLast - statusVecFirst) / ptrSize)
            if (statusCount <= 0 || statusCount > 512)
            {
                compIdx += 1
                continue
            }

            effects := []
            flaskSlots := Map()
            flaskActive := Map(1, false, 2, false, 3, false, 4, false, 5, false)
            validEffects := 0
            seenKeys := Map()

            maxStatusRead := Min(statusCount, 160)
            statusIdx := 0
            while (statusIdx < maxStatusRead)
            {
                statusPtr := this.Mem.ReadPtr(statusVecFirst + (statusIdx * ptrSize))
                if this.IsProbablyValidPointer(statusPtr)
                {
                    effect := this.ReadBuffEffectEntryBasic(statusPtr)
                    if (effect)
                    {
                        dedupKey := Format("{:X}-{}", effect["buffDefPtr"], effect["sourceEntityId"])
                        if !seenKeys.Has(dedupKey)
                        {
                            seenKeys[dedupKey] := true
                            validEffects += 1
                            effects.Push(effect)

                            if ((playerId = 0 || effect["sourceEntityId"] = playerId)
                                && effect["isFlaskBuff"]
                                && effect["flaskSlot"] >= 1
                                && effect["flaskSlot"] <= 5)
                            {
                                slot := effect["flaskSlot"]
                                flaskActive[slot] := true
                                flaskSlots[slot] := Map(
                                    "active", true,
                                    "buffCharges", effect["charges"],
                                    "timeLeft", effect["timeLeft"],
                                    "totalTime", effect["totalTime"],
                                    "sourceEntityId", effect["sourceEntityId"],
                                    "name", effect["name"]
                                )
                            }
                        }
                    }
                }

                statusIdx += 1
            }

            if (validEffects > 0)
            {
                effectsSummary := this.BuildBuffSummaryFromEffects(effects, playerId)
                return Map(
                    "address", componentPtr,
                    "statusCount", statusCount,
                    "effectsRead", effects.Length,
                    "effects", effects,
                    "effectsSummary", effectsSummary,
                    "flaskActive", flaskActive,
                    "flaskSlots", flaskSlots
                )
            }

            compIdx += 1
        }

        return 0
    }

    ; Finds and reads the Charges component for the local player entity.
    ; Tries named lookup, named component list, then a brute-force component scan.
    ; Returns: charges snapshot Map (current, perUse, remainingUses) or 0
    ReadPlayerChargesComponent(localPlayerPtr)
    {
        if !this.IsProbablyValidPointer(localPlayerPtr)
            return 0

        compVecFirst := this.Mem.ReadInt64(localPlayerPtr + PoE2Offsets.Entity["ComponentsVec"])
        compVecLast := this.Mem.ReadInt64(localPlayerPtr + PoE2Offsets.Entity["ComponentsVecLast"])
        if (compVecFirst <= 0 || compVecLast < compVecFirst)
            return 0

        chargesByLookup := this.FindEntityComponentAddress(localPlayerPtr, "Charges", ["Charge", "FlaskCharges"])
        if this.IsProbablyValidPointer(chargesByLookup)
        {
            chargesSnapshot := this.BuildChargesComponentSnapshot(chargesByLookup)
            if chargesSnapshot
                return chargesSnapshot
        }

        namedComponents := this.ReadEntityComponentLookupBasic(localPlayerPtr, 128)
        if (namedComponents && Type(namedComponents) = "Array")
        {
            for _, component in namedComponents
            {
                if !(component && Type(component) = "Map" && component.Has("name") && component.Has("address"))
                    continue

                compName := component["name"]
                if !(this.ComponentNameMatches(compName, "Charges")
                    || this.ComponentNameMatches(compName, "Charge")
                    || this.ComponentNameMatches(compName, "FlaskCharges"))
                    continue

                namedSnapshot := this.BuildChargesComponentSnapshot(component["address"])
                if namedSnapshot
                    return namedSnapshot
            }
        }

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
                    snapshot := this.BuildChargesComponentSnapshot(componentPtr)
                    if snapshot
                    {
                        score := snapshot["score"]
                        if (score > bestScore)
                        {
                            bestScore := score
                            best := snapshot
                        }

                        if (score >= 4)
                            break
                    }
                }
            }
            idx += 1
        }

        return (bestScore >= 2) ? best : 0
    }


}
