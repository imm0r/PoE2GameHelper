; ExplorationModule.ahk
; Auto-exploration engine — navigates the current area until a configurable
; percentage of walkable terrain has been visited.
;
; Architecture:
;   - Called from UpdateRadarFast() after combat automation
;   - Uses terrain walkable grid for visited-cell tracking
;   - Uses TerrainPathfinder for A* pathfinding to unexplored frontier
;   - Uses W2S matrix for screen-coordinate projection + click-to-move
;   - Pauses navigation when combat automation is active (enemies nearby)
;
; Included by InGameStateMonitor.ahk
; Globals declared in InGameStateMonitor.ahk:
;   g_exploreEnabled, g_exploreTargetPercent, g_exploreCurrentPercent, g_exploreLastReason

; ── Timer callback ────────────────────────────────────────────────────────
; Called every 50ms from UpdateRadarFast.
; radarSnap: full radar snapshot from ReadRadarSnapshot()
TryExploration(radarSnap)
{
    static _running := false
    if _running
        return
    _running := true
    try
        _RunExploration(radarSnap)
    catch as ex
        LogError("TryExploration", ex)
    finally
        _running := false
}

_RunExploration(radarSnap)
{
    global g_exploreEnabled, g_exploreTargetPercent, g_exploreCurrentPercent
    global g_exploreLastReason, g_updatesPaused, g_reader
    global g_combatState

    if (g_updatesPaused || !g_exploreEnabled)
    {
        g_exploreLastReason := "disabled"
        return
    }

    ; ── Resolve game window ───────────────────────────────────────────
    gameHwnd := ResolvePoEWindow()
    if !gameHwnd
    {
        g_exploreLastReason := "no-game-window"
        return
    }
    if !WinActive("ahk_id " gameHwnd)
    {
        g_exploreLastReason := "game-not-focused"
        return
    }

    ; ── Block in town/hideout ─────────────────────────────────────────
    wad := radarSnap.Has("worldAreaDat") ? radarSnap["worldAreaDat"] : 0
    if (wad && IsObject(wad))
    {
        if ((wad.Has("isTown") && wad["isTown"]) || (wad.Has("isHideout") && wad["isHideout"]))
        {
            g_exploreLastReason := "town-hideout"
            return
        }
    }

    ; ── Block when panel is open ──────────────────────────────────────
    panelVis := radarSnap.Has("panelVisibility") ? radarSnap["panelVisibility"] : 0
    if (panelVis && IsObject(panelVis) && panelVis.Has("anyPanelOpen") && panelVis["anyPanelOpen"])
    {
        g_exploreLastReason := "panel-open"
        return
    }

    ; ── Extract terrain + player position ─────────────────────────────
    inGs := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
    area := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    terrain := (area && IsObject(area) && area.Has("terrain") && area["terrain"]) ? area["terrain"] : 0
    if !terrain
    {
        g_exploreLastReason := "no-terrain"
        return
    }

    prc := (area && area.Has("playerRenderComponent")) ? area["playerRenderComponent"] : 0
    if !(prc && IsObject(prc) && prc.Has("worldPosition"))
    {
        g_exploreLastReason := "no-player-pos"
        return
    }
    pwp := prc["worldPosition"]
    playerWX := pwp.Has("x") ? pwp["x"] : 0
    playerWY := pwp.Has("y") ? pwp["y"] : 0
    playerWZ := pwp.Has("z") ? pwp["z"] : 0
    if (playerWX = 0 && playerWY = 0)
    {
        g_exploreLastReason := "origin-player"
        return
    }

    ; ── W2S matrix ────────────────────────────────────────────────────
    w2sMat := (inGs && inGs.Has("w2sMatrix")) ? inGs["w2sMatrix"] : []

    ; ── Initialize / reset visited tracking on area change ────────────
    static _pf := TerrainPathfinder()
    static _visited := 0           ; Buffer — byte per coarse cell (0/1)
    static _totalWalkable := 0     ; walkable coarse cells in area
    static _visitedWalkable := 0   ; visited walkable cells
    static _terrainSz := 0         ; cache key for area change detection
    static _STEP := 4              ; coarse step for visited grid (4×4 area)
    static _coarseW := 0
    static _coarseH := 0
    static _bpr := 0
    static _rows := 0

    tsz := terrain["dataSize"]
    if (tsz != _terrainSz)
    {
        ; New area — reinitialize
        _pf.SetTerrain(terrain)
        _terrainSz := tsz
        _bpr := terrain["bytesPerRow"]
        _rows := terrain["totalRows"]
        gridW := terrain["gridWidth"]
        _coarseW := gridW // _STEP
        _coarseH := _rows // _STEP

        ; Allocate visited map
        mapSize := _coarseW * _coarseH
        _visited := Buffer(mapSize, 0)

        ; Count total walkable coarse cells
        buf := terrain["data"]
        dsz := terrain["dataSize"]
        count := 0
        cy := 0
        while (cy < _coarseH)
        {
            cx := 0
            while (cx < _coarseW)
            {
                gx := cx * _STEP
                gy := cy * _STEP
                if (gx < gridW && gy < _rows)
                {
                    idx := gy * _bpr + (gx >> 1)
                    if (idx < dsz)
                    {
                        byt := NumGet(buf.Ptr, idx, "UChar")
                        if (((byt >> ((gx & 1) * 4)) & 0xF) != 0)
                            count++
                    }
                }
                cx++
            }
            cy++
        }
        _totalWalkable := count
        _visitedWalkable := 0

        ; Flag that navigation state needs reset
        _areaResetDone := 0
    }

    if (_totalWalkable = 0)
    {
        g_exploreLastReason := "no-walkable"
        return
    }

    ; ── Mark cells near player as visited ─────────────────────────────
    ; Vision radius: ~40 grid cells ≈ roughly what's visible on screen
    VISION_RADIUS := 40
    ratio := TerrainPathfinder.WORLD_TO_GRID_RATIO
    pGX := Round(playerWX / ratio)
    pGY := Round(playerWY / ratio)
    pcX := pGX // _STEP
    pcY := pGY // _STEP
    vr := VISION_RADIUS // _STEP

    buf := terrain["data"]
    dsz := terrain["dataSize"]
    gridW := _bpr * 2
    vrSq := vr * vr

    dy := -vr
    while (dy <= vr)
    {
        cy := pcY + dy
        if (cy >= 0 && cy < _coarseH)
        {
            dx := -vr
            while (dx <= vr)
            {
                if (dx * dx + dy * dy <= vrSq)
                {
                    cx := pcX + dx
                    if (cx >= 0 && cx < _coarseW)
                    {
                        cellIdx := cy * _coarseW + cx
                        if (NumGet(_visited.Ptr, cellIdx, "UChar") = 0)
                        {
                            ; Only mark if walkable
                            gx := cx * _STEP
                            gy := cy * _STEP
                            if (gx < gridW && gy < _rows)
                            {
                                tIdx := gy * _bpr + (gx >> 1)
                                if (tIdx < dsz)
                                {
                                    byt := NumGet(buf.Ptr, tIdx, "UChar")
                                    if (((byt >> ((gx & 1) * 4)) & 0xF) != 0)
                                    {
                                        NumPut("UChar", 1, _visited.Ptr, cellIdx)
                                        _visitedWalkable++
                                    }
                                }
                            }
                        }
                    }
                }
                dx++
            }
        }
        dy++
    }

    ; ── Compute exploration percentage ────────────────────────────────
    g_exploreCurrentPercent := Round((_visitedWalkable / _totalWalkable) * 100, 1)

    ; ── Check if target reached ───────────────────────────────────────
    if (g_exploreCurrentPercent >= g_exploreTargetPercent)
    {
        g_exploreLastReason := "done(" g_exploreCurrentPercent "%)"
        return
    }

    ; ── Pause navigation during combat ────────────────────────────────
    if (g_combatState = "combat")
    {
        g_exploreLastReason := "combat-pause(" g_exploreCurrentPercent "%)"
        return
    }

    ; ── Navigation: find frontier and click-to-move ───────────────────
    static _targetCX := -1, _targetCY := -1
    static _pathCoords := []
    static _pathIdx := 0
    static _lastClickTick := 0
    static _lastFrontierTick := 0
    static _stuckCheckTick := 0
    static _stuckPGX := 0, _stuckPGY := 0
    static _areaResetDone := 0
    static _doorClickTick := 0
    static _doorClickCounts := Map()  ; entityAddr → clickCount

    ; Reset navigation when area changes
    if (!_areaResetDone)
    {
        _targetCX := -1
        _targetCY := -1
        _pathCoords := []
        _pathIdx := 0
        _lastClickTick := 0
        _lastFrontierTick := 0
        _stuckCheckTick := 0
        _stuckPGX := 0
        _stuckPGY := 0
        _doorClickTick := 0
        _doorClickCounts := Map()
        _areaResetDone := 1
    }

    now := A_TickCount

    ; ── Proactive door/switch opening (AutoOpen-style) ────────────────
    ; Scan every 300ms for closed doors & unswitched switches within range
    if ((now - _doorClickTick) > 300)
    {
        doorResult := _FindNearbyInteractable(radarSnap, playerWX, playerWY, playerWZ, _doorClickCounts)
        if (doorResult)
        {
            doorScreen := _ExploreWorldToScreen(doorResult["x"], doorResult["y"], doorResult["z"], w2sMat, gameHwnd)
            if (doorScreen)
            {
                ; Save current mouse position
                prevPt := Buffer(8, 0)
                DllCall("GetCursorPos", "Ptr", prevPt)
                prevX := NumGet(prevPt, 0, "Int")
                prevY := NumGet(prevPt, 4, "Int")

                ; Click the door/switch: move → LUp → LDown → LUp (AutoOpen pattern)
                DllCall("SetCursorPos", "int", doorScreen["x"], "int", doorScreen["y"])
                Sleep(15)
                DllCall("mouse_event", "uint", 0x0004, "int", 0, "int", 0, "uint", 0, "uptr", 0) ; LEFTUP
                DllCall("mouse_event", "uint", 0x0002, "int", 0, "int", 0, "uint", 0, "uptr", 0) ; LEFTDOWN
                Sleep(15)
                DllCall("mouse_event", "uint", 0x0004, "int", 0, "int", 0, "uint", 0, "uptr", 0) ; LEFTUP

                ; Restore mouse and re-press LMB to resume movement
                DllCall("SetCursorPos", "int", prevX, "int", prevY)
                Sleep(10)
                DllCall("mouse_event", "uint", 0x0002, "int", 0, "int", 0, "uint", 0, "uptr", 0) ; LEFTDOWN

                ; Track click count
                addr := doorResult["addr"]
                _doorClickCounts[addr] := (_doorClickCounts.Has(addr) ? _doorClickCounts[addr] : 0) + 1

                _doorClickTick := now
                g_exploreLastReason := "open-" doorResult["type"] "(" g_exploreCurrentPercent "%)"
                return
            }
        }
    }

    ; Stuck detection: if player hasn't moved in 3s, re-target
    if (_stuckCheckTick = 0 || (now - _stuckCheckTick) > 3000)
    {
        if (Abs(pGX - _stuckPGX) < 5 && Abs(pGY - _stuckPGY) < 5 && _targetCX >= 0)
        {
            _targetCX := -1
            _pathCoords := []
        }
        _stuckPGX := pGX
        _stuckPGY := pGY
        _stuckCheckTick := now
    }

    ; Recompute frontier target every 2s or when no target
    if (_targetCX < 0 || (now - _lastFrontierTick) > 2000)
    {
        frontier := _FindNearestFrontier(pcX, pcY, _visited, _coarseW, _coarseH,
                                          buf, _bpr, _rows, dsz, _STEP)
        if (frontier)
        {
            _targetCX := frontier[1]
            _targetCY := frontier[2]
            ; Compute A* path to frontier target
            tGX := _targetCX * _STEP
            tGY := _targetCY * _STEP
            _pathCoords := _pf.FindPath(pGX, pGY, tGX, tGY)
            _pathIdx := 1
        }
        else
        {
            ; No frontier found — area fully explored or unreachable
            _targetCX := -1
            g_exploreLastReason := "no-frontier(" g_exploreCurrentPercent "%)"
            return
        }
        _lastFrontierTick := now
    }

    ; ── Follow path: click toward next waypoint ──────────────────────
    ; Throttle clicks to every 400ms
    if ((now - _lastClickTick) < 400)
    {
        g_exploreLastReason := "moving(" g_exploreCurrentPercent "% → " Round(_targetCX * _STEP * ratio) "," Round(_targetCY * _STEP * ratio) ")"
        return
    }

    ; Advance waypoint if player is close enough
    if (_pathCoords.Length > 0 && _pathIdx <= _pathCoords.Length)
    {
        wp := _pathCoords[_pathIdx]
        wpDist := Abs(pGX - wp[1]) + Abs(pGY - wp[2])
        if (wpDist < 15)
        {
            _pathIdx++
            if (_pathIdx > _pathCoords.Length)
            {
                ; Reached end of path — find new frontier next tick
                _targetCX := -1
                g_exploreLastReason := "wp-done(" g_exploreCurrentPercent "%)"
                return
            }
        }
    }

    ; Pick the waypoint to click toward (look ahead ~3 waypoints for smoother movement)
    clickWP := 0
    if (_pathCoords.Length > 0 && _pathIdx <= _pathCoords.Length)
    {
        lookAhead := Min(_pathIdx + 3, _pathCoords.Length)
        clickWP := _pathCoords[lookAhead]
    }
    else
    {
        ; No path — click directly toward target
        clickWP := [_targetCX * _STEP, _targetCY * _STEP]
    }

    ; Convert grid → world → screen
    clickWX := clickWP[1] * ratio
    clickWY := clickWP[2] * ratio
    screenPos := _ExploreWorldToScreen(clickWX, clickWY, playerWZ, w2sMat, gameHwnd)
    if (!screenPos)
    {
        g_exploreLastReason := "no-w2s(" g_exploreCurrentPercent "%)"
        return
    }

    ; Move mouse and click
    DllCall("SetCursorPos", "int", screenPos["x"], "int", screenPos["y"])
    Sleep(30)
    ; Left mouse down+up via mouse_event (bypasses UIPI like SetCursorPos)
    DllCall("mouse_event", "uint", 0x0002, "int", 0, "int", 0, "uint", 0, "uptr", 0) ; MOUSEEVENTF_LEFTDOWN
    Sleep(30)
    DllCall("mouse_event", "uint", 0x0004, "int", 0, "int", 0, "uint", 0, "uptr", 0) ; MOUSEEVENTF_LEFTUP
    _lastClickTick := now

    g_exploreLastReason := "click(" g_exploreCurrentPercent "% wp=" _pathIdx "/" _pathCoords.Length ")"
}

; ── Find nearest unvisited walkable cell (frontier) ──────────────────────
; Spiral search from player's coarse position outward.
; Returns [cx, cy] or 0 if none found.
_FindNearestFrontier(pcX, pcY, visited, cW, cH, buf, bpr, rows, dsz, STEP)
{
    ; Spiral search: scan outward in rings
    maxRadius := Max(cW, cH)
    gridW := bpr * 2

    r := 1
    while (r < maxRadius)
    {
        ; Scan the ring at distance r
        ; Top and bottom edges
        dy := -r
        while (dy <= r)
        {
            for _, dxVal in [-r, r]
            {
                cx := pcX + dxVal
                cy := pcY + dy
                result := _CheckFrontierCell(cx, cy, visited, cW, cH, buf, bpr, rows, dsz, gridW, STEP)
                if result
                    return result
            }
            ; Only process corners once, skip inner cells on left/right edges
            if (dy != -r && dy != r)
            {
                dy++
                continue
            }
            ; Full scan of this row for top/bottom edges
            dx := -r + 1
            while (dx < r)
            {
                cx := pcX + dx
                cy := pcY + dy
                result := _CheckFrontierCell(cx, cy, visited, cW, cH, buf, bpr, rows, dsz, gridW, STEP)
                if result
                    return result
                dx++
            }
            dy++
        }
        r++
        ; Safety limit
        if (r > 500)
            break
    }
    return 0
}

_CheckFrontierCell(cx, cy, visited, cW, cH, buf, bpr, rows, dsz, gridW, STEP)
{
    if (cx < 0 || cx >= cW || cy < 0 || cy >= cH)
        return 0

    cellIdx := cy * cW + cx
    ; Must be unvisited
    if (NumGet(visited.Ptr, cellIdx, "UChar") != 0)
        return 0

    ; Must be walkable
    gx := cx * STEP
    gy := cy * STEP
    if (gx >= gridW || gy >= rows)
        return 0
    tIdx := gy * bpr + (gx >> 1)
    if (tIdx >= dsz)
        return 0
    byt := NumGet(buf.Ptr, tIdx, "UChar")
    if (((byt >> ((gx & 1) * 4)) & 0xF) = 0)
        return 0

    ; Must be adjacent to a visited cell (frontier condition)
    for _, d in [[1,0],[-1,0],[0,1],[0,-1]]
    {
        nx := cx + d[1]
        ny := cy + d[2]
        if (nx >= 0 && nx < cW && ny >= 0 && ny < cH)
        {
            nIdx := ny * cW + nx
            if (NumGet(visited.Ptr, nIdx, "UChar") = 1)
                return [cx, cy]
        }
    }
    return 0
}

; ── World-to-Screen for exploration clicks ───────────────────────────────
; Simplified W2S that reuses the camera matrix from radar snapshot.
_ExploreWorldToScreen(worldX, worldY, worldZ, w2sMat, gameHwnd)
{
    if !(w2sMat && Type(w2sMat) = "Array" && w2sMat.Length = 16)
        return 0

    ; Get client area
    clientRect := Buffer(16, 0)
    clientPt := Buffer(8, 0)
    DllCall("GetClientRect", "Ptr", gameHwnd, "Ptr", clientRect)
    DllCall("ClientToScreen", "Ptr", gameHwnd, "Ptr", clientPt)
    cX := NumGet(clientPt, 0, "Int")
    cY := NumGet(clientPt, 4, "Int")
    cW := NumGet(clientRect, 8, "Int")
    cH := NumGet(clientRect, 12, "Int")

    if (cW < 100 || cH < 100)
        return 0

    ; Matrix multiply (transpose, matching GameHelper2 C#)
    input := [worldX, worldY, worldZ, 1.0]
    r := [0.0, 0.0, 0.0, 0.0]
    loop 4
    {
        i := A_Index
        loop 4
        {
            j := A_Index
            r[i] += w2sMat[(j-1)*4 + i] * input[j]
        }
    }

    ; Perspective divide
    if (Abs(r[4]) < 0.0001)
        return 0
    loop 3
        r[A_Index] /= r[4]

    ; NDC to screen
    screenX := Round(cX + (r[1] + 1) * cW / 2)
    screenY := Round(cY + (1 - r[2]) * cH / 2)

    ; Clamp to client area with margin
    margin := 80
    screenX := Max(cX + margin, Min(screenX, cX + cW - margin))
    screenY := Max(cY + margin, Min(screenY, cY + cH - margin))

    return Map("x", screenX, "y", screenY)
}

; ── Find nearby interactable (doors/switches) — AutoOpen-style ────────────
; Scans entities for:
;   - Doors: TriggerableBlockage.isBlocked + path contains "door"
;   - Switches: Transitionable.currentState == 1 + path contains "switch"
; Returns Map("x","y","z","addr","type") or 0.
_FindNearbyInteractable(radarSnap, playerWX, playerWY, playerWZ, clickCounts)
{
    global g_reader

    inGs := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
    area := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    awake := (area && IsObject(area) && area.Has("awakeEntities")) ? area["awakeEntities"] : 0
    sample := (awake && IsObject(awake) && awake.Has("sample")) ? awake["sample"] : []

    INTERACT_RANGE := 600
    MAX_CLICKS := 15
    bestDist := INTERACT_RANGE
    bestResult := 0

    for _, entry in sample
    {
        if !(entry && IsObject(entry))
            continue
        entity := entry.Has("entity") ? entry["entity"] : 0
        if !(entity && IsObject(entity))
            continue

        entityAddr := entity.Has("address") ? entity["address"] : 0
        if !entityAddr
            continue

        ; Skip if we've already clicked this entity too many times
        if (clickCounts.Has(entityAddr) && clickCounts[entityAddr] >= MAX_CLICKS)
            continue

        path := entity.Has("path") ? entity["path"] : ""
        pathLower := StrLower(path)

        decoded := entity.Has("decodedComponents") ? entity["decodedComponents"] : 0
        if !(decoded && IsObject(decoded))
            continue

        interactType := ""
        needsInteraction := false

        ; ── Door check: TriggerableBlockage + path contains "door" ────
        if (InStr(pathLower, "door"))
        {
            tb := decoded.Has("triggerableblockage") ? decoded["triggerableblockage"] : 0
            if (tb && IsObject(tb) && tb.Has("isBlocked") && tb["isBlocked"])
            {
                ; Live re-read to confirm still blocked
                stillBlocked := true
                comps := entity.Has("components") ? entity["components"] : 0
                if (comps && Type(comps) = "Array")
                {
                    for _, comp in comps
                    {
                        if !(comp && Type(comp) = "Map" && comp.Has("name") && comp.Has("address"))
                            continue
                        if (InStr(comp["name"], "TriggerableBlockage"))
                        {
                            tbAddr := comp["address"]
                            if (tbAddr && g_reader.IsProbablyValidPointer(tbAddr))
                            {
                                liveVal := g_reader.Mem.ReadUChar(tbAddr + PoE2Offsets.TriggerableBlockage["IsBlocked"])
                                if (liveVal != 1)
                                    stillBlocked := false
                            }
                            break
                        }
                    }
                }
                if (stillBlocked)
                {
                    interactType := "door"
                    needsInteraction := true
                }
            }
        }

        ; ── Switch check: Transitionable + path contains "switch" ─────
        if (!needsInteraction && InStr(pathLower, "switch"))
        {
            trans := decoded.Has("transitionable") ? decoded["transitionable"] : 0
            if (trans && IsObject(trans) && trans.Has("currentState"))
            {
                ; In AutoOpen: Flag1 == 1 means NOT yet switched
                if (trans["currentState"] = 1)
                {
                    interactType := "switch"
                    needsInteraction := true
                }
            }
        }

        if !needsInteraction
            continue

        ; Get world position
        render := decoded.Has("render") ? decoded["render"] : 0
        if !(render && IsObject(render) && render.Has("worldPosition"))
            continue
        wp := render["worldPosition"]
        ex := wp.Has("x") ? wp["x"] : 0
        ey := wp.Has("y") ? wp["y"] : 0
        dx := ex - playerWX
        dy := ey - playerWY
        dist := Sqrt(dx * dx + dy * dy)

        if (dist < bestDist)
        {
            bestDist := dist
            bestResult := Map(
                "x", ex,
                "y", ey,
                "z", wp.Has("z") ? wp["z"] : playerWZ,
                "addr", entityAddr,
                "type", interactType
            )
        }
    }

    return bestResult
}

; ── Config: Load/Save exploration settings ────────────────────────────────
LoadExplorationConfig()
{
    global g_exploreEnabled, g_exploreTargetPercent

    iniFile := A_ScriptDir "\gamehelper_config.ini"
    section := "Exploration"

    g_exploreEnabled       := IniRead(iniFile, section, "Enabled", "0") = "1"
    g_exploreTargetPercent := Integer(IniRead(iniFile, section, "TargetPercent", "80"))
    g_exploreTargetPercent := Max(10, Min(99, g_exploreTargetPercent))
}

SaveExplorationConfig()
{
    global g_exploreEnabled, g_exploreTargetPercent

    iniFile := A_ScriptDir "\gamehelper_config.ini"
    section := "Exploration"

    IniWrite(g_exploreEnabled ? "1" : "0", iniFile, section, "Enabled")
    IniWrite(g_exploreTargetPercent, iniFile, section, "TargetPercent")
}
