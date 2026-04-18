; CombatAutomation.ahk
; Automated skill rotation engine — detects combat from entity proximity,
; reads skill cooldowns, and fires skills in priority order.
;
; Architecture:
;   - Called from UpdateRadarFast() after entity data is available
;   - Uses entity cache from radar snapshot for combat detection
;   - Reads skill cooldowns via g_reader.ReadPlayerSkills()
;   - Sends keypresses via keybd_event (Win32 API, bypasses UIPI)
;
; Included by InGameStateMonitor.ahk

; ── Timer callback: reads skill snapshot + decides skill usage ─────────────
; Called every 100ms from UpdateRadarFast when combat automation is enabled.
; Params: radarSnap - the full radar snapshot from ReadRadarSnapshot()
TryCombatAutomation(radarSnap)
{
    static _running := false
    if _running
        return
    _running := true
    try
    {
        global g_combatAutoEnabled, g_updatesPaused, g_reader, g_combatLastReason
        global g_combatState, g_combatSkillSlots, g_combatGlobalCooldownMs
        global g_lastSkillUseTime, g_combatRange, g_combatDisengageRange
        global g_combatSkillCooldowns

        if (g_updatesPaused || !g_combatAutoEnabled)
        {
            g_combatLastReason := "disabled"
            g_combatState := "idle"
            return
        }

        gameHwnd := ResolvePoEWindow()
        if !gameHwnd
        {
            g_combatLastReason := "no-game-window"
            g_combatState := "idle"
            return
        }
        if !WinActive("ahk_id " gameHwnd)
        {
            g_combatLastReason := "game-not-focused"
            g_combatState := "idle"
            return
        }

        ; Block in town/hideout
        wad := radarSnap.Has("worldAreaDat") ? radarSnap["worldAreaDat"] : 0
        if (wad && IsObject(wad))
        {
            if ((wad.Has("isTown") && wad["isTown"]) || (wad.Has("isHideout") && wad["isHideout"]))
            {
                g_combatLastReason := "town-hideout"
                g_combatState := "idle"
                return
            }
        }

        ; Block when panel is open
        panelVis := radarSnap.Has("panelVisibility") ? radarSnap["panelVisibility"] : 0
        if (panelVis && IsObject(panelVis) && panelVis.Has("anyPanelOpen") && panelVis["anyPanelOpen"])
        {
            g_combatLastReason := "panel-open"
            g_combatState := "idle"
            return
        }

        ; Block when player is dead
        pv := radarSnap.Has("playerVitals") ? radarSnap["playerVitals"] : 0
        if (pv && IsObject(pv) && pv.Has("stats"))
        {
            stats := pv["stats"]
            if (stats.Has("isAlive") && !stats["isAlive"])
            {
                g_combatLastReason := "dead"
                g_combatState := "idle"
                return
            }
        }

        ; ── Combat detection from entity cache ────────────────────────────
        combatInfo := _DetectCombat(radarSnap)
        hostileCount := combatInfo["hostileCount"]
        nearestDist  := combatInfo["nearestDist"]   ; Euclidean

        ; ── Terrain-aware distance (replaces Euclidean for engage/disengage) ──
        ; Uses line-of-sight check (fast) and falls back to A* path length
        ; when terrain blocks the straight line.
        static _combatPF := TerrainPathfinder()
        static _pfTerrainSz := 0
        terrain := 0
        inGs := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
        areaForTerrain := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
        if (areaForTerrain && IsObject(areaForTerrain) && areaForTerrain.Has("terrain") && areaForTerrain["terrain"])
        {
            terrain := areaForTerrain["terrain"]
            tsz := terrain["dataSize"]
            if (tsz != _pfTerrainSz)
            {
                _combatPF.SetTerrain(terrain)
                _pfTerrainSz := tsz
            }
        }

        terrainDist := nearestDist
        if (hostileCount > 0 && _combatPF.HasTerrain()
            && combatInfo["playerWorldX"] != 0 && combatInfo["nearestWorldX"] != 0)
        {
            td := _CachedTerrainDistance(_combatPF,
                combatInfo["playerWorldX"], combatInfo["playerWorldY"],
                combatInfo["nearestWorldX"], combatInfo["nearestWorldY"])
            if (td >= 0)
                terrainDist := td
        }
        combatInfo["terrainDist"] := terrainDist

        ; State machine: idle ↔ combat (uses terrain-aware distance)
        prevState := g_combatState
        if (g_combatState = "idle")
        {
            if (hostileCount > 0 && terrainDist <= g_combatRange)
            {
                g_combatState := "combat"
            }
        }
        else if (g_combatState = "combat")
        {
            if (hostileCount = 0 || terrainDist > g_combatDisengageRange)
            {
                g_combatState := "idle"
                g_combatLastReason := "disengage(dist=" Round(terrainDist) " n=" hostileCount ")"
                return
            }
        }

        if (g_combatState != "combat")
        {
            g_combatLastReason := "idle(n=" hostileCount " d=" Round(terrainDist) ")"
            return
        }

        ; ── Move mouse toward nearest enemy ───────────────────────────────
        ; Always aim the cursor at the closest hostile so the character walks
        ; toward enemies and skills fire in the right direction.
        targetScreenPos := _WorldToScreen(combatInfo, gameHwnd)
        if (targetScreenPos)
        {
            _MoveMouseToTarget(targetScreenPos)
            mat := combatInfo["w2sMatrix"]
            matTag := (mat && Type(mat) = "Array" && mat.Length = 16) ? "mat" : "approx"
            distTag := (terrainDist != nearestDist) ? " td=" Round(terrainDist) : ""
            g_combatLastReason := matTag "→" targetScreenPos["x"] "," targetScreenPos["y"]
                . " pw=" Round(combatInfo["playerWorldX"]) "," Round(combatInfo["playerWorldY"])
                . " ew=" Round(combatInfo["nearestWorldX"]) "," Round(combatInfo["nearestWorldY"])
                . distTag
        }
        else
        {
            g_combatLastReason := "no-screen-pos"
                . " pw=" Round(combatInfo["playerWorldX"]) "," Round(combatInfo["playerWorldY"])
                . " ew=" Round(combatInfo["nearestWorldX"]) "," Round(combatInfo["nearestWorldY"])
        }

        ; ── Confirm cursor is on target (isTargetedByPlayer) ──────────────
        ; Only fire skills once the game confirms our cursor is on the enemy.
        ; Grace period: if not targeted within 500ms, fire anyway — projection
        ; may be slightly off but close enough.
        static _aimStartTick := 0
        tgtAddr := combatInfo["nearestTargetableAddr"]
        isTargeted := false
        if (tgtAddr && g_reader.IsProbablyValidPointer(tgtAddr))
        {
            try
                isTargeted := g_reader.Mem.ReadUChar(tgtAddr + PoE2Offsets.Targetable["IsTargetedByPlayer"]) = 1
        }
        if (!isTargeted)
        {
            if (_aimStartTick = 0)
                _aimStartTick := A_TickCount
            aimElapsed := A_TickCount - _aimStartTick
            if (aimElapsed < 500)
            {
                g_combatLastReason := "aiming(" aimElapsed "ms)"
                return
            }
            ; Grace period expired — fire anyway
        }
        else
            _aimStartTick := 0

        ; ── Global cooldown check ─────────────────────────────────────────
        now := A_TickCount
        if (now - g_lastSkillUseTime < g_combatGlobalCooldownMs)
        {
            g_combatLastReason := "gcd(" (g_combatGlobalCooldownMs - (now - g_lastSkillUseTime)) "ms)"
            return
        }

        ; ── Read skill cooldowns ──────────────────────────────────────────
        ; Use cached skill data, refresh every 200ms
        static _skillCache := 0
        static _skillCacheTick := 0
        if (!_skillCache || (now - _skillCacheTick) > 200)
        {
            inGs := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
            area := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
            localPlayerPtr := (area && IsObject(area) && area.Has("localPlayerPtr")) ? area["localPlayerPtr"] : 0
            if localPlayerPtr
            {
                try _skillCache := g_reader.ReadPlayerSkills(localPlayerPtr)
                catch
                    _skillCache := 0
            }
            _skillCacheTick := now
        }

        if !_skillCache
        {
            g_combatLastReason := "no-skill-data"
            return
        }

        ; ── Store cooldown state for UI ───────────────────────────────────
        skills := _skillCache.Has("skills") ? _skillCache["skills"] : []
        _UpdateCooldownState(skills)

        ; ── Auto-detect skill ranges from game data ───────────────────────
        ; When a slot matches a skill by name, infer range from castType if
        ; the user hasn't set one manually (skillRange = 0).
        _AutoPopulateSkillRanges(skills)

        ; ── Select and execute next skill ─────────────────────────────────
        selResult := _SelectNextSkill(skills, combatInfo)
        selectedSlot := selResult["slot"]
        if (selectedSlot)
        {
            slotCfg := g_combatSkillSlots[selectedSlot]
            sendKey := slotCfg["key"]

            if _SendSkillKey(sendKey, gameHwnd)
            {
                g_lastSkillUseTime := now
                slotCfg["lastUseTick"] := now
                g_combatLastReason := "cast-slot" selectedSlot "(" slotCfg["name"] " key=" sendKey " n=" hostileCount ")"
            }
            else
            {
                g_combatLastReason := "send-failed-slot" selectedSlot
            }
        }
        else if (selResult["outOfRange"])
        {
            g_combatLastReason := "approaching(d=" Round(nearestDist) ")"
        }
        else
        {
            g_combatLastReason := "no-ready-skill(n=" hostileCount " d=" Round(nearestDist) ")"
        }
    }
    catch as ex
    {
        LogError("TryCombatAutomation", ex)
    }
    finally
    {
        _running := false
    }
}

; ── Combat Detection ──────────────────────────────────────────────────────
; Scans entity cache for hostile, alive, targetable monsters within range.
; Returns: Map with hostileCount, nearestDist, nearestPath
_DetectCombat(radarSnap)
{
    global g_combatRange, g_reader

    result := Map("hostileCount", 0, "nearestDist", 999999, "nearestPath", ""
        , "nearestWorldX", 0, "nearestWorldY", 0, "nearestWorldZ", 0
        , "playerWorldX", 0, "playerWorldY", 0, "playerWorldZ", 0
        , "nearestTargetableAddr", 0, "w2sMatrix", [])

    inGs := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
    area := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    awake := (area && IsObject(area) && area.Has("awakeEntities")) ? area["awakeEntities"] : 0
    sample := (awake && IsObject(awake) && awake.Has("sample")) ? awake["sample"] : []

    ; Extract WorldToScreen matrix from inGameState
    if (inGs && IsObject(inGs) && inGs.Has("w2sMatrix"))
        result["w2sMatrix"] := inGs["w2sMatrix"]

    ; Extract player world position for screen projection
    prc := (area && IsObject(area) && area.Has("playerRenderComponent")) ? area["playerRenderComponent"] : 0
    if (prc && IsObject(prc) && prc.Has("worldPosition"))
    {
        pwp := prc["worldPosition"]
        result["playerWorldX"] := pwp.Has("x") ? pwp["x"] : 0
        result["playerWorldY"] := pwp.Has("y") ? pwp["y"] : 0
        result["playerWorldZ"] := pwp.Has("z") ? pwp["z"] : 0
    }

    hostileCount := 0
    nearestDist := 999999.0

    for _, entry in sample
    {
        if !(entry && IsObject(entry))
            continue

        ; Must have entity basic data
        entity := entry.Has("entity") ? entry["entity"] : 0
        if !(entity && IsObject(entity))
            continue

        path := entity.Has("path") ? entity["path"] : ""
        if (path = "")
            continue

        ; Only monsters/characters (not player, not attachments)
        if !g_reader.IsNpcLikeEntityPath(path)
            continue

        ; Check decoded components for alive + targetable + hostile
        decoded := entity.Has("decodedComponents") ? entity["decodedComponents"] : 0
        if !(decoded && IsObject(decoded))
            continue

        ; Must be targetable (alive monsters are targetable; dead ones are not)
        ; Radar mode stores targetable as a bare boolean; full mode as a Map with isTargetable key.
        tgt := decoded.Has("targetable") ? decoded["targetable"] : 0
        if IsObject(tgt)
            isTargetable := (tgt.Has("isTargetable") && tgt["isTargetable"])
        else
            isTargetable := tgt ? true : false
        if !isTargetable
            continue

        ; Also check life component — dead entities have curHP <= 0 or isAlive = false
        lifeComp := decoded.Has("life") ? decoded["life"] : 0
        if (lifeComp && IsObject(lifeComp) && lifeComp.Has("isAlive") && !lifeComp["isAlive"])
            continue

        ; Live re-read of Targetable byte to catch recently-dead entities whose
        ; cached targetable status is stale (round-robin hasn't reached them yet).
        comps := entity.Has("components") ? entity["components"] : 0
        if (comps && Type(comps) = "Array")
        {
            liveTargetable := false
            for _, comp in comps
            {
                if !(comp && Type(comp) = "Map" && comp.Has("name") && comp.Has("address"))
                    continue
                if (InStr(comp["name"], "Targetable"))
                {
                    tgtAddr := comp["address"]
                    if (tgtAddr && g_reader.IsProbablyValidPointer(tgtAddr))
                    {
                        raw := g_reader.Mem.ReadUChar(tgtAddr + PoE2Offsets.Targetable["IsTargetable"])
                        liveTargetable := (raw = 1)
                    }
                    break
                }
            }
            if !liveTargetable
                continue
        }

        ; Must NOT be friendly
        pos := decoded.Has("positioned") ? decoded["positioned"] : 0
        if (pos && IsObject(pos) && pos.Has("isFriendly") && pos["isFriendly"])
            continue

        ; Check distance
        dist := entry.Has("distance") ? entry["distance"] : -1
        if (dist < 0)
            continue

        hostileCount += 1
        if (dist < nearestDist)
        {
            nearestDist := dist
            result["nearestPath"] := path

            ; Store Targetable component address for live isTargetedByPlayer check
            if (comps && Type(comps) = "Array")
            {
                for _, comp in comps
                {
                    if !(comp && Type(comp) = "Map" && comp.Has("name") && comp.Has("address"))
                        continue
                    if (InStr(comp["name"], "Targetable"))
                    {
                        result["nearestTargetableAddr"] := comp["address"]
                        break
                    }
                }
            }

            ; Capture world position for mouse targeting
            render := decoded.Has("render") ? decoded["render"] : 0
            if (render && IsObject(render) && render.Has("worldPosition"))
            {
                ewp := render["worldPosition"]
                result["nearestWorldX"] := ewp.Has("x") ? ewp["x"] : 0
                result["nearestWorldY"] := ewp.Has("y") ? ewp["y"] : 0
                result["nearestWorldZ"] := ewp.Has("z") ? ewp["z"] : 0
            }
        }
    }

    result["hostileCount"] := hostileCount
    result["nearestDist"] := nearestDist
    return result
}

; ── Skill Selection ───────────────────────────────────────────────────────
; Picks the highest-priority skill that is off cooldown and ready to use.
; Returns: Map("slot", N, "outOfRange", bool) — slot=0 if nothing ready
_SelectNextSkill(skills, combatInfo)
{
    global g_combatSkillSlots, g_combatSkillCooldowns

    bestSlot := 0
    bestPriority := 99999
    anyOutOfRange := false

    for slotNum, slotCfg in g_combatSkillSlots
    {
        if !(slotCfg["enabled"])
            continue

        key := slotCfg["key"]
        if (key = "")
            continue

        priority := slotCfg["priority"]
        skillName := slotCfg["skillName"]
        slotType := slotCfg["type"]
        skillRange := slotCfg.Has("skillRange") ? slotCfg["skillRange"] : 0

        ; Check per-slot cooldown
        now := A_TickCount
        lastUse := slotCfg.Has("lastUseTick") ? slotCfg["lastUseTick"] : 0
        slotCdMs := slotCfg.Has("cooldownMs") ? slotCfg["cooldownMs"] : 0
        if (slotCdMs > 0 && (now - lastUse) < slotCdMs)
            continue

        ; Match skill by name to check game cooldown state
        if (skillName != "")
        {
            skillReady := false
            for _, skill in skills
            {
                sName := skill.Has("name") ? skill["name"] : ""
                sDisplay := skill.Has("displayName") ? skill["displayName"] : ""
                if (sName = skillName || sDisplay = skillName)
                {
                    canUse := skill.Has("canUse") ? skill["canUse"] : true
                    if canUse
                        skillReady := true
                    break
                }
            }
            ; If we have a skill name match and it's on cooldown, skip
            if (skillName != "" && !skillReady)
                continue
        }

        ; Type-based logic
        nearestDist := combatInfo.Has("terrainDist") ? combatInfo["terrainDist"] : combatInfo["nearestDist"]
        hostileCount := combatInfo["hostileCount"]

        ; "buff" type: only use when not recently used (long cooldown handled by slotCdMs)
        ; "aoe" type: prefer when multiple enemies nearby
        ; "single" type: default single-target
        if (slotType = "aoe" && hostileCount < 2)
            continue

        ; Range check: skillRange > 0 means limited range, 0 = unlimited
        if (skillRange > 0 && nearestDist > skillRange)
        {
            anyOutOfRange := true
            continue
        }

        if (priority < bestPriority)
        {
            bestPriority := priority
            bestSlot := slotNum
        }
    }

    return Map("slot", bestSlot, "outOfRange", anyOutOfRange)
}

; ── Update cooldown state for UI display ──────────────────────────────────
_UpdateCooldownState(skills)
{
    global g_combatSkillCooldowns

    g_combatSkillCooldowns := Map()
    for _, skill in skills
    {
        name := skill.Has("name") ? skill["name"] : ""
        if (name = "")
            continue
        g_combatSkillCooldowns[name] := Map(
            "name", name,
            "displayName", skill.Has("displayName") ? skill["displayName"] : name,
            "canUse", skill.Has("canUse") ? skill["canUse"] : true,
            "cooldownMs", skill.Has("cooldownMs") ? skill["cooldownMs"] : 0,
            "activeCooldowns", skill.Has("activeCooldowns") ? skill["activeCooldowns"] : 0,
            "maxUses", skill.Has("maxUses") ? skill["maxUses"] : 0,
            "castType", skill.Has("castType") ? skill["castType"] : 0
        )
    }
}

; ── Auto-populate skill ranges from game data ─────────────────────────────
; When a combat slot matches a skill by name and has skillRange=0 (unset),
; infers a default range from the skill's castType:
;   castType 0 (attack/melee) → 300 world units
;   castType 1 (spell)        → 1200 world units
;   anything else              → 800 world units (safe default)
_AutoPopulateSkillRanges(skills)
{
    global g_combatSkillSlots
    static _autoRangeApplied := Map()

    for slotNum, slotCfg in g_combatSkillSlots
    {
        if !(slotCfg["enabled"])
            continue
        skillName := slotCfg.Has("skillName") ? slotCfg["skillName"] : ""
        if (skillName = "")
            continue
        ; Only auto-fill if user hasn't set a range
        if (slotCfg.Has("skillRange") && slotCfg["skillRange"] > 0)
            continue
        ; Avoid re-applying every tick
        cacheKey := slotNum ":" skillName
        if _autoRangeApplied.Has(cacheKey)
            continue

        for _, skill in skills
        {
            sName := skill.Has("name") ? skill["name"] : ""
            sDisplay := skill.Has("displayName") ? skill["displayName"] : ""
            if (sName = skillName || sDisplay = skillName)
            {
                castType := skill.Has("castType") ? skill["castType"] : -1
                autoRange := 800
                if (castType = 0)
                    autoRange := 300    ; melee / attack
                else if (castType = 1)
                    autoRange := 1200   ; spell
                slotCfg["skillRange"] := autoRange
                _autoRangeApplied[cacheKey] := true
                break
            }
        }
    }
}

; ── Cached Terrain Distance ─────────────────────────────────────────────
; Computes terrain-aware distance between player and enemy, with caching.
; Returns: world-unit distance, or -1 if terrain unavailable / pathfinding fails.
_CachedTerrainDistance(pf, playerWX, playerWY, enemyWX, enemyWY)
{
    static _cachedDist := -1
    static _cachedPGX := -999999, _cachedPGY := -999999
    static _cachedEGX := -999999, _cachedEGY := -999999

    ratio := TerrainPathfinder.WORLD_TO_GRID_RATIO
    pGX := Round(playerWX / ratio)
    pGY := Round(playerWY / ratio)
    eGX := Round(enemyWX / ratio)
    eGY := Round(enemyWY / ratio)

    ; Reuse cached result if player and enemy haven't moved significantly (>3 grid cells)
    if (Abs(pGX - _cachedPGX) <= 3 && Abs(pGY - _cachedPGY) <= 3
        && Abs(eGX - _cachedEGX) <= 3 && Abs(eGY - _cachedEGY) <= 3
        && _cachedDist >= 0)
        return _cachedDist

    _cachedPGX := pGX, _cachedPGY := pGY
    _cachedEGX := eGX, _cachedEGY := eGY

    _cachedDist := pf.ComputeTerrainDistance(playerWX, playerWY, enemyWX, enemyWY)
    return _cachedDist
}

; ── World-to-Screen projection ─────────────────────────────────────────────
; Projects a world-space enemy position to game-viewport screen coordinates.
; Uses the game's own 4x4 WorldToScreen matrix (read from camera structure)
; for pixel-perfect projection. Falls back to isometric approximation if
; the matrix is unavailable.
; Returns: Map("x", screenX, "y", screenY) or 0 on failure.
_WorldToScreen(combatInfo, gameHwnd)
{
    global g_combatW2SScale

    ex := combatInfo["nearestWorldX"]
    ey := combatInfo["nearestWorldY"]
    ez := combatInfo["nearestWorldZ"]

    ; Get game window position and dimensions
    try
    {
        WinGetPos(&winX, &winY, &winW, &winH, "ahk_id " gameHwnd)
    }
    catch
        return 0

    if (winW < 100 || winH < 100)
        return 0

    ; ── Try proper matrix projection ──────────────────────────────────
    mat := combatInfo["w2sMatrix"]
    if (mat && Type(mat) = "Array" && mat.Length = 16)
    {
        ; Get client area (rendering region, excluding title bar/borders)
        clientRect := Buffer(16, 0)
        clientPt := Buffer(8, 0)
        DllCall("GetClientRect", "Ptr", gameHwnd, "Ptr", clientRect)
        DllCall("ClientToScreen", "Ptr", gameHwnd, "Ptr", clientPt)
        cX := NumGet(clientPt, 0, "Int")
        cY := NumGet(clientPt, 4, "Int")
        cW := NumGet(clientRect, 8, "Int")
        cH := NumGet(clientRect, 12, "Int")
        ; Matrix4x4 multiplication: result = mat × [ex, ey, ez, 1.0]
        ; C# Matrix4x4 is row-major: M[row,col] with FieldOffset layout
        ;   mat[1]=M11, mat[2]=M12, mat[3]=M13, mat[4]=M14
        ;   mat[5]=M21, mat[6]=M22, mat[7]=M23, mat[8]=M24
        ;   mat[9]=M31, mat[10]=M32, mat[11]=M33, mat[12]=M34
        ;   mat[13]=M41, mat[14]=M42, mat[15]=M43, mat[16]=M44
        ; GameHelper2 iterates: tmpResult[i] += mat[j,i] * input[j]
        ;   i.e. result = transpose(mat) × input  (column-major multiply)
        input := [ex, ey, ez, 1.0]
        r := [0.0, 0.0, 0.0, 0.0]
        Loop 4
        {
            i := A_Index
            Loop 4
            {
                j := A_Index
                ; mat[j, i] in row-major = mat[(j-1)*4 + i]
                r[i] := r[i] + mat[(j - 1) * 4 + i] * input[j]
            }
        }

        ; Perspective divide
        if (r[4] = 0)
            return 0
        Loop 4
            r[A_Index] := r[A_Index] / r[4]

        ; NDC to screen coordinates (client area → absolute screen)
        screenX := Round(cX + (r[1] + 1.0) * (cW / 2.0))
        screenY := Round(cY + (1.0 - r[2]) * (cH / 2.0))

        ; Clamp to client area bounds (with margin to avoid edge UI)
        margin := 50
        screenX := Max(cX + margin, Min(screenX, cX + cW - margin))
        screenY := Max(cY + margin, Min(screenY, cY + cH - margin))

        return Map("x", screenX, "y", screenY)
    }

    ; ── Fallback: isometric approximation ─────────────────────────────
    px := combatInfo["playerWorldX"]
    py := combatInfo["playerWorldY"]
    dx := ex - px
    dy := ey - py

    static CAM_SIN := 0.62470   ; sin(38.7°)
    scaleFactor := g_combatW2SScale * (winW / 1920.0)

    screenOffsetX := (dx - dy) * scaleFactor
    screenOffsetY := -(dx + dy) * CAM_SIN * scaleFactor

    screenX := Round(winX + winW / 2 + screenOffsetX)
    screenY := Round(winY + winH / 2 + screenOffsetY)

    margin := 50
    screenX := Max(winX + margin, Min(screenX, winX + winW - margin))
    screenY := Max(winY + margin, Min(screenY, winY + winH - margin))

    return Map("x", screenX, "y", screenY)
}

; ── Move mouse to enemy screen position ───────────────────────────────────
; Uses DllCall("SetCursorPos") — a raw Win32 API that bypasses UIPI.
; MouseMove / SendInput are blocked when the game runs elevated (admin).
_MoveMouseToTarget(screenPos)
{
    if !(screenPos && IsObject(screenPos))
        return false

    x := screenPos["x"]
    y := screenPos["y"]

    return DllCall("SetCursorPos", "int", x, "int", y)
}

; ── Send skill keypress ───────────────────────────────────────────────────
; Uses keybd_event (Win32 API) — same privilege level as SetCursorPos/mouse_event.
; Bypasses UIPI when the game runs elevated, unlike ControlSend/SendInput.
_SendSkillKey(sendKey, gameHwnd)
{
    if (sendKey = "" || !gameHwnd)
        return false

    ; Handle mouse buttons separately via mouse_event
    keyLower := StrLower(sendKey)
    if (keyLower = "lbutton")
    {
        DllCall("mouse_event", "uint", 0x0002, "int", 0, "int", 0, "uint", 0, "uptr", 0)
        Sleep(20)
        DllCall("mouse_event", "uint", 0x0004, "int", 0, "int", 0, "uint", 0, "uptr", 0)
        return true
    }
    if (keyLower = "rbutton")
    {
        DllCall("mouse_event", "uint", 0x0008, "int", 0, "int", 0, "uint", 0, "uptr", 0)
        Sleep(20)
        DllCall("mouse_event", "uint", 0x0010, "int", 0, "int", 0, "uint", 0, "uptr", 0)
        return true
    }
    if (keyLower = "mbutton")
    {
        DllCall("mouse_event", "uint", 0x0020, "int", 0, "int", 0, "uint", 0, "uptr", 0)
        Sleep(20)
        DllCall("mouse_event", "uint", 0x0040, "int", 0, "int", 0, "uint", 0, "uptr", 0)
        return true
    }

    ; Convert AHK key name → virtual key code
    vk := GetKeyVK(sendKey)
    if (!vk)
        return false

    ; keybd_event: key down then key up (bypasses UIPI)
    DllCall("keybd_event", "uchar", vk, "uchar", 0, "uint", 0, "uptr", 0)          ; KEYEVENTF_KEYDOWN
    Sleep(20)
    DllCall("keybd_event", "uchar", vk, "uchar", 0, "uint", 0x0002, "uptr", 0)     ; KEYEVENTF_KEYUP
    return true
}

; ── Config: Load/Save combat automation settings ──────────────────────────
LoadCombatAutoConfig()
{
    global g_combatAutoEnabled, g_combatRange, g_combatDisengageRange
    global g_combatGlobalCooldownMs, g_combatSkillSlots, g_combatToggleHotkey
    global g_combatW2SScale

    cfgPath := A_ScriptDir "\gamehelper_config.ini"

    g_combatAutoEnabled := false
    g_combatRange := 1500
    g_combatDisengageRange := 2500
    g_combatGlobalCooldownMs := 120
    g_combatToggleHotkey := "F10"
    g_combatW2SScale := 0.20

    try g_combatAutoEnabled := IniRead(cfgPath, "CombatAutomation", "enabled", "0") = "1"
    try g_combatRange := Integer(IniRead(cfgPath, "CombatAutomation", "combatRange", "1500"))
    try g_combatDisengageRange := Integer(IniRead(cfgPath, "CombatAutomation", "disengageRange", "2500"))
    try g_combatGlobalCooldownMs := Integer(IniRead(cfgPath, "CombatAutomation", "globalCooldownMs", "120"))
    try g_combatToggleHotkey := IniRead(cfgPath, "CombatAutomation", "toggleHotkey", "F10")
    try g_combatW2SScale := Float(IniRead(cfgPath, "CombatAutomation", "worldToScreenScale", "0.20"))

    ; Load up to 8 skill slots
    g_combatSkillSlots := Map()
    Loop 8
    {
        slotNum := A_Index
        prefix := "slot" slotNum
        enabled := false
        key := ""
        priority := slotNum
        skillName := ""
        slotType := "single"
        cooldownMs := 0
        skillRange := 0

        try enabled := IniRead(cfgPath, "CombatAutomation", prefix "Enabled", "0") = "1"
        try key := IniRead(cfgPath, "CombatAutomation", prefix "Key", "")
        try priority := Integer(IniRead(cfgPath, "CombatAutomation", prefix "Priority", String(slotNum)))
        try skillName := IniRead(cfgPath, "CombatAutomation", prefix "SkillName", "")
        try slotType := IniRead(cfgPath, "CombatAutomation", prefix "Type", "single")
        try cooldownMs := Integer(IniRead(cfgPath, "CombatAutomation", prefix "CooldownMs", "0"))
        try skillRange := Integer(IniRead(cfgPath, "CombatAutomation", prefix "Range", "0"))

        if (key != "" || enabled)
        {
            g_combatSkillSlots[slotNum] := Map(
                "enabled", enabled,
                "key", key,
                "priority", priority,
                "skillName", skillName,
                "name", skillName != "" ? skillName : "Slot" slotNum,
                "type", slotType,
                "cooldownMs", cooldownMs,
                "lastUseTick", 0,
                "skillRange", skillRange
            )
        }
    }
}

SaveCombatAutoConfig()
{
    global g_combatAutoEnabled, g_combatRange, g_combatDisengageRange
    global g_combatGlobalCooldownMs, g_combatSkillSlots, g_combatToggleHotkey
    global g_combatW2SScale

    cfgPath := A_ScriptDir "\gamehelper_config.ini"

    try IniWrite(g_combatAutoEnabled ? "1" : "0", cfgPath, "CombatAutomation", "enabled")
    try IniWrite(String(g_combatRange), cfgPath, "CombatAutomation", "combatRange")
    try IniWrite(String(g_combatDisengageRange), cfgPath, "CombatAutomation", "disengageRange")
    try IniWrite(String(g_combatGlobalCooldownMs), cfgPath, "CombatAutomation", "globalCooldownMs")
    try IniWrite(g_combatToggleHotkey, cfgPath, "CombatAutomation", "toggleHotkey")
    try IniWrite(Format("{:.2f}", g_combatW2SScale), cfgPath, "CombatAutomation", "worldToScreenScale")

    Loop 8
    {
        slotNum := A_Index
        prefix := "slot" slotNum
        if g_combatSkillSlots.Has(slotNum)
        {
            slot := g_combatSkillSlots[slotNum]
            try IniWrite(slot["enabled"] ? "1" : "0", cfgPath, "CombatAutomation", prefix "Enabled")
            try IniWrite(slot["key"], cfgPath, "CombatAutomation", prefix "Key")
            try IniWrite(String(slot["priority"]), cfgPath, "CombatAutomation", prefix "Priority")
            try IniWrite(slot["skillName"], cfgPath, "CombatAutomation", prefix "SkillName")
            try IniWrite(slot["type"], cfgPath, "CombatAutomation", prefix "Type")
            try IniWrite(String(slot["cooldownMs"]), cfgPath, "CombatAutomation", prefix "CooldownMs")
            try IniWrite(String(slot.Has("skillRange") ? slot["skillRange"] : 0), cfgPath, "CombatAutomation", prefix "Range")
        }
    }
}

; ── Hotkey registration ───────────────────────────────────────────────────
; Registers (or re-registers) the combat toggle hotkey.
; Call once after LoadCombatAutoConfig().
RegisterCombatHotkey()
{
    global g_combatToggleHotkey
    static _currentHotkey := ""

    ; Unregister previous hotkey if it changed
    if (_currentHotkey != "")
    {
        try Hotkey(_currentHotkey, , "Off")
    }

    hk := Trim(g_combatToggleHotkey)
    if (hk = "")
        return

    try
    {
        Hotkey(hk, _OnCombatHotkeyPressed, "On")
        _currentHotkey := hk
    }
    catch as ex
    {
        LogError("RegisterCombatHotkey", ex)
    }
}

_OnCombatHotkeyPressed(*)
{
    _ToggleCombatAuto()
}
