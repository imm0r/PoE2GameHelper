#Requires AutoHotkey v2.0
#Include PoE2MemoryReader.ahk

debugMode := 0

outPath := A_ScriptDir "\SmokeTestResult.txt"
if FileExist(outPath)
    FileDelete(outPath)
LogLine("version=3")
LogLine("phase=start")

try
{
    reader := PoE2GameStateReader("PathOfExileSteam.exe")
    LogLine("phase=before_connect")
    startedAt := A_TickCount
    connected := reader.Connect(false)
    LogLine("phase=after_connect")
    strictOk := connected && !reader.HasPatternScanCriticalIssues()

    elapsedMs := A_TickCount - startedAt

    LogLine("phase=connected")
    LogLine("connected=" (connected ? "1" : "0"))
    LogLine("strictOk=" (strictOk ? "1" : "0"))
    LogLine("elapsedMs=" elapsedMs)
    LogLine("hasHandle=" (reader.Mem.Handle ? "1" : "0"))
    LogLine("pid=" reader.Mem.Pid)
    LogLine("moduleBase=" PoE2GameStateReader.Hex(reader.Mem.ModuleBase))
    LogLine("moduleSize=" reader.Mem.ModuleSize)
    LogLine("gameStatesAddress=" PoE2GameStateReader.Hex(reader.GameStatesAddress))
    gsPtr := reader.Mem.ReadPtr(reader.GameStatesAddress)
    LogLine("gameStatesPtr=" PoE2GameStateReader.Hex(gsPtr))
    LogLine("gameStatesPtrValid=" (reader.IsProbablyValidPointer(gsPtr) ? "1" : "0"))

    report := reader.PatternScanReport
    LogLine("missingCritical=" report["missingCritical"].Length)
    LogLine("missingOptional=" report["missingOptional"].Length)
    LogLine("duplicateCritical=" report["duplicateCritical"].Length)
    LogLine("duplicateOptional=" report["duplicateOptional"].Length)
    LogLine("foundPatterns=" report["found"].Length)

    if (reader.GameStatesAddress)
    {
        snapshot := reader.ReadSnapshot()
        if IsObject(snapshot)
        {
            LogLine("snapshot=1")
            LogLine("currentState=" snapshot["currentStateName"])
            LogLine("inGameStateAddress=" PoE2GameStateReader.Hex(snapshot["inGameStateAddress"]))

            inGame := snapshot["inGameState"]
            if (inGame)
            {
                areaInst := inGame["areaInstance"]
                worldDet := inGame["worldDataDetails"]
                if (areaInst)
                {
                    LogLine("areaLevel=" areaInst["currentAreaLevel"])
                    LogLine("areaHash=" Format("0x{:X}", areaInst["currentAreaHash"]))
                    LogLine("localPlayerPtr=" PoE2GameStateReader.Hex(areaInst["localPlayerPtr"]))

                    buffSlots := areaInst["flaskSlotsFromBuffs"]
                    LogLine("flask.buffSlotsActive=" (buffSlots ? buffSlots.Count : 0))

                    pv := areaInst["playerVitals"]
                    if (pv)
                    {
                        ps := pv["stats"]
                        LogLine("player.lifeComponentPtr=" PoE2GameStateReader.Hex(pv["lifeComponentPtr"]))
                        LogLine("player.life=" ps["lifeCurrent"] "/" ps["lifeMax"])
                        LogLine("player.mana=" ps["manaCurrent"] "/" ps["manaMax"])
                        LogLine("player.es=" ps["esCurrent"] "/" ps["esMax"])
                    }

                    pc := areaInst["playerComponent"]
                    if (pc)
                    {
                        LogLine("player.componentPtr=" PoE2GameStateReader.Hex(pc["address"]))
                        LogLine("player.name=" pc["name"])
                        LogLine("player.level=" pc["level"])
                        LogLine("player.xp=" pc["xp"])
                    }

                    pstats := areaInst["playerStatsComponent"]
                    if (pstats)
                    {
                        LogLine("player.stats.ptr=" PoE2GameStateReader.Hex(pstats["address"]))
                        LogLine("player.stats.weaponIndex=" pstats["currentWeaponIndex"])
                        LogLine("player.stats.shapeshift=" (pstats["isInShapeshiftedForm"] ? "1" : "0"))
                        LogLine("player.stats.itemsCount=" pstats["statsByItemsCount"])
                        LogLine("player.stats.buffsCount=" pstats["statsByBuffAndActionsCount"])
                    }

                    pbuffs := areaInst["playerBuffsComponent"]
                    if (pbuffs)
                    {
                        LogLine("player.buffs.ptr=" PoE2GameStateReader.Hex(pbuffs["address"]))
                        LogLine("player.buffs.statusCount=" pbuffs["statusCount"])
                        LogLine("player.buffs.effectsRead=" pbuffs["effectsRead"])
                    }

                    ppos := areaInst["playerPositionedComponent"]
                    if (ppos)
                    {
                        LogLine("player.positioned.ptr=" PoE2GameStateReader.Hex(ppos["address"]))
                        LogLine("player.positioned.reaction=" ppos["reaction"])
                        LogLine("player.positioned.isFriendly=" (ppos["isFriendly"] ? "1" : "0"))
                    }

                    pactor := areaInst["playerActorComponent"]
                    if (pactor)
                    {
                        LogLine("player.actor.ptr=" PoE2GameStateReader.Hex(pactor["address"]))
                        LogLine("player.actor.animationId=" pactor["animationId"])
                        LogLine("player.actor.activeSkillsCount=" pactor["activeSkillsCount"])
                        LogLine("player.actor.cooldownsCount=" pactor["cooldownsCount"])
                        LogLine("player.actor.deployedCount=" pactor["deployedCount"])
                    }

                    srv := areaInst["serverData"]
                    if (srv)
                    {
                        LogLine("serverData.playerDataPtr=" PoE2GameStateReader.Hex(srv["playerDataPtr"]))
                        LogLine("serverData.inventoriesCount=" srv["inventoriesCount"])
                        LogLine("serverData.flaskInventoryIdMatched=" srv["flaskInventoryIdMatched"])
                        if (debugMode)
                        {
                            LogLine("serverData.flaskInventorySelectReason=" srv["flaskInventorySelectReason"])
                            invIds := srv["inventoryIdsSeen"]
                            if (invIds && invIds.Length)
                            {
                                idText := ""
                                for invId in invIds
                                    idText .= (idText = "" ? "" : ",") invId
                                LogLine("serverData.inventoryIdsSeen=" idText)
                            }
                        }
                        LogLine("serverData.flaskInventoryPtr=" PoE2GameStateReader.Hex(srv["flaskInventoryPtr"]))

                        flaskInv := srv["flaskInventory"]
                        if (flaskInv)
                        {
                            LogLine("flask.grid=" flaskInv["totalBoxesX"] "x" flaskInv["totalBoxesY"])
                            LogLine("flask.entryCountRaw=" flaskInv["entryCount"])
                            LogLine("flask.entriesRead=" flaskInv["entries"].Length)

                            slots := flaskInv["flaskSlots"]
                            if (slots)
                            {
                                loop 5
                                {
                                    slot := A_Index
                                    info := slots[slot]
                                    if (info)
                                    {
                                        source := info.Has("source") ? info["source"] : "unknown"
                                        slotText := "slot" slot ": item=" PoE2GameStateReader.Hex(info["itemEntityPtr"]) " source=" source
                                        details := info["itemDetails"]
                                        if (details)
                                            slotText .= " name='" details["baseType"] "' rarity=" details["rarity"]
                                        fsSlot := info["flaskStats"]
                                        if (fsSlot)
                                            slotText .= " charges=" fsSlot["current"] "/use=" fsSlot["perUse"] "/uses=" fsSlot["remainingUses"]
                                        else
                                            slotText .= " charges=n/a"

                                        if (info.Has("activeByBuff") && info["activeByBuff"])
                                        {
                                            bi := info["buffInfo"]
                                            if (bi)
                                                slotText .= " active=1 buffCharges=" bi["buffCharges"] " t=" Format("{:.2f}", bi["timeLeft"]) "/" Format("{:.2f}", bi["totalTime"])
                                            else
                                                slotText .= " active=1"
                                        }
                                        LogLine("flask." slotText)
                                    }
                                    else
                                    {
                                        LogLine("flask.slot" slot ": empty")
                                    }
                                }
                            }

                            if (flaskInv["entries"].Length)
                            {
                                e0 := flaskInv["entries"][1]
                                if (debugMode)
                                {
                                    LogLine("flask.e0.itemPtr=" PoE2GameStateReader.Hex(e0["itemEntityPtr"]))
                                    LogLine("flask.e0.slotStart=" e0["slotStartX"] "," e0["slotStartY"])
                                    LogLine("flask.e0.slotEnd=" e0["slotEndX"] "," e0["slotEndY"])
                                }

                                foundStats := false
                                for entry in flaskInv["entries"]
                                {
                                    fs := entry["flaskStats"]
                                    if (fs)
                                    {
                                        LogLine("flask.stats.itemPtr=" PoE2GameStateReader.Hex(entry["itemEntityPtr"]))
                                        LogLine("flask.stats.current=" fs["current"])
                                        LogLine("flask.stats.perUse=" fs["perUse"])
                                        LogLine("flask.stats.remainingUses=" fs["remainingUses"])
                                        foundStats := true
                                        break
                                    }
                                }
                                if (!foundStats)
                                    LogLine("flask.stats=none")
                            }
                        }
                    }
                }

                if (worldDet)
                {
                    LogLine("worldAreaDetailsPtr=" PoE2GameStateReader.Hex(worldDet["worldAreaDetailsPtr"]))
                    LogLine("worldAreaRowPtr=" PoE2GameStateReader.Hex(worldDet["worldAreaDetailsRowPtr"]))

                    wad := worldDet["worldAreaDat"]
                    if (wad)
                    {
                        LogLine("worldArea.id=" wad["id"])
                        LogLine("worldArea.name=" wad["name"])
                        LogLine("worldArea.flags="
                            . (wad["isTown"] ? "T" : "-")
                            . (wad["isHideout"] ? "H" : "-")
                            . (wad["hasWaypoint"] ? "W" : "-"))
                    }
                }
            }
        }
        else
        {
            LogLine("snapshot=0")
        }
    }
    else
    {
        LogLine("snapshot=0")
    }

    LogLine("phase=done")
}
catch Error as err
{
    LogLine("phase=error")
    LogLine("errorType=" err.What)
    LogLine("errorMsg=" err.Message)
}

LogLine("phase=exit")

ExitApp

LogLine(text)
{
    global outPath
    FileAppend(text "`n", outPath, "UTF-8")
}
