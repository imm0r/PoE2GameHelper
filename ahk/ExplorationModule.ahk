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

; ── Exploration tick (called from AutoPilot) ──────────────────────────────
; Runs one exploration step: tracks visited cells, computes A* path to the
; nearest unexplored frontier, and click-to-moves toward it.
;
; AutoPilot owns the shared guard chain (window focus, town/hideout, panel-open,
; player-dead) AND the master enable check. This is a trusted callee — when
; invoked we run exploration unconditionally. The previous g_exploreEnabled
; gate was removed when combat + exploration were unified under a single
; AutoPilot toggle.
;
; Params: radarSnap - full radar snapshot
;         gameHwnd  - resolved PoE2 window handle (must be valid + active)
TryExploration(radarSnap, gameHwnd)
{
    static _running := false
    if _running
        return
    _running := true
    try
        _RunExploration(radarSnap, gameHwnd)
    catch as ex
        LogError("TryExploration", ex)
    finally
        _running := false
}

_RunExploration(radarSnap, gameHwnd)
{
    global g_exploreTargetPercent, g_exploreCurrentPercent
    global g_exploreLastReason, g_reader

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

    ; ── Navigation: precomputed plan + click-to-move ──────────────────
    static _targetCX := -1, _targetCY := -1
    static _pathCoords := []
    static _pathIdx := 0
    static _lastClickTick := 0
    static _lastTargetTick := 0   ; was _lastFrontierTick — generalised
    static _stuckCheckTick := 0
    static _stuckPGX := 0, _stuckPGY := 0
    static _areaResetDone := 0
    static _doorClickTick := 0
    static _doorClickCounts := Map()  ; entityAddr → clickCount

    ; Precomputed exploration plan — built once per area from the (already
    ; fully-known) walkable terrain grid. ~50-80 sample waypoints in a
    ; sparse grid pattern, ordered by greedy-nearest-from-start TSP,
    ; AreaTransitions appended last so the bot exits the zone at the end.
    ; See _BuildExplorationPlan at the bottom of the module for details.
    static _plan := []
    static _planIdx := 1
    static _planBuilt := false

    ; Reset navigation when area changes
    if (!_areaResetDone)
    {
        _targetCX := -1
        _targetCY := -1
        _pathCoords := []
        _pathIdx := 0
        _lastClickTick := 0
        _lastTargetTick := 0
        _stuckCheckTick := 0
        _stuckPGX := 0
        _stuckPGY := 0
        _doorClickTick := 0
        _doorClickCounts := Map()
        _plan := []
        _planIdx := 1
        _planBuilt := false
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

                ; Restore mouse. Movement resumes via the next regular
                ; click-to-move tick (≤400 ms away) — deliberately NO held
                ; LEFTDOWN here: leaving the button pressed turned every
                ; subsequent SetCursorPos into a drag and could stall the
                ; character mid-walk with the cursor parked on the door.
                DllCall("SetCursorPos", "int", prevX, "int", prevY)

                ; Track click count
                addr := doorResult["addr"]
                _doorClickCounts[addr] := (_doorClickCounts.Has(addr) ? _doorClickCounts[addr] : 0) + 1

                _doorClickTick := now
                g_exploreLastReason := "open-" doorResult["type"] "(" g_exploreCurrentPercent "%)"
                return
            }
        }
    }

    ; Stuck detection: if player hasn't moved in 3 s, the current waypoint
    ; is probably unreachable from here — rebuild the plan from the new
    ; position. Crucially, the stuck target's coarse cell is marked visited
    ; FIRST: without that, the rebuilt greedy-nearest plan immediately
    ; re-picks the exact same waypoint (the player hasn't moved, so it is
    ; still the nearest unvisited sample) and the bot loops clicking the
    ; same unreachable spot forever. Marking also covers the zone-exit case
    ; where every click near an AreaTransition lands in its avoid box.
    if (_stuckCheckTick = 0 || (now - _stuckCheckTick) > 3000)
    {
        if (Abs(pGX - _stuckPGX) < 5 && Abs(pGY - _stuckPGY) < 5 && _targetCX >= 0)
        {
            _visitedWalkable += _ExploreMarkCoarseVisited(_visited, _targetCX, _targetCY
                , _coarseW, _coarseH, _STEP, buf, dsz, _bpr, gridW, _rows)
            _targetCX := -1
            _pathCoords := []
            _planBuilt := false   ; rebuild plan from current position
        }
        _stuckPGX := pGX
        _stuckPGY := pGY
        _stuckCheckTick := now
    }

    ; ── Plan-driven target selection ──────────────────────────────────
    ; First, build the plan if we haven't yet. Terrain + player position
    ; are guaranteed available at this point — both were validated above.
    if (!_planBuilt)
    {
        _plan := _BuildExplorationPlan(terrain, radarSnap, pGX, pGY)
        _planIdx := 1
        _planBuilt := true
        _targetCX := -1   ; force fresh A* on first plan waypoint
    }

    ; Skip plan waypoints whose coarse cell has already been marked visited
    ; by the vision sweep — we'd just walk in place if we kept them. This
    ; loop naturally short-circuits once the next "real" waypoint is found.
    while (_planIdx <= _plan.Length)
    {
        wp := _plan[_planIdx]
        wcX := wp[1] // _STEP
        wcY := wp[2] // _STEP
        if (wcX < 0 || wcX >= _coarseW || wcY < 0 || wcY >= _coarseH)
        {
            _planIdx++
            continue
        }
        if (NumGet(_visited.Ptr, wcY * _coarseW + wcX, "UChar") = 1)
        {
            _targetCX := -1   ; force fresh path on next waypoint
            _planIdx++
            continue
        }
        break
    }

    ; Pick the target: next plan waypoint, or frontier search as a fallback
    ; when the plan is exhausted (catches any leftover unvisited corners
    ; that the sparse sampling missed).
    if (_planIdx <= _plan.Length && _targetCX < 0)
    {
        wp := _plan[_planIdx]
        tGX := wp[1]
        tGY := wp[2]
        _targetCX := tGX // _STEP
        _targetCY := tGY // _STEP
        _pathCoords := _pf.FindPath(pGX, pGY, tGX, tGY)
        _pathIdx := 1
        _lastTargetTick := now
        if (_pathCoords.Length = 0)
        {
            ; A* failed — the waypoint is unreachable from here (walkable
            ; "island" disconnected from the player's region, or behind a
            ; closed blockage). Mark its cell visited and skip it instead of
            ; falling through to the blind "click directly toward target"
            ; branch, which would click into a wall every 400 ms forever.
            _visitedWalkable += _ExploreMarkCoarseVisited(_visited, _targetCX, _targetCY
                , _coarseW, _coarseH, _STEP, buf, dsz, _bpr, gridW, _rows)
            _targetCX := -1
            _planIdx++
            g_exploreLastReason := "wp-unreachable(" g_exploreCurrentPercent "% wp=" _planIdx "/" _plan.Length ")"
            return
        }
    }
    else if (_planIdx > _plan.Length && (_targetCX < 0 || (now - _lastTargetTick) > 2000))
    {
        ; Plan exhausted — fall back to greedy frontier search.
        frontier := _FindNearestFrontier(pcX, pcY, _visited, _coarseW, _coarseH,
                                          buf, _bpr, _rows, dsz, _STEP)
        if (frontier)
        {
            _targetCX := frontier[1]
            _targetCY := frontier[2]
            tGX := _targetCX * _STEP
            tGY := _targetCY * _STEP
            _pathCoords := _pf.FindPath(pGX, pGY, tGX, tGY)
            _pathIdx := 1
            if (_pathCoords.Length = 0)
            {
                ; Unreachable frontier (same island problem as plan waypoints).
                ; Mark it visited so the spiral search returns the next-nearest
                ; frontier on the following tick instead of this one again.
                _visitedWalkable += _ExploreMarkCoarseVisited(_visited, _targetCX, _targetCY
                    , _coarseW, _coarseH, _STEP, buf, dsz, _bpr, gridW, _rows)
                _targetCX := -1
                _lastTargetTick := now
                g_exploreLastReason := "frontier-unreachable(" g_exploreCurrentPercent "%)"
                return
            }
        }
        else
        {
            _targetCX := -1
            g_exploreLastReason := "no-frontier-done(" g_exploreCurrentPercent "%)"
            return
        }
        _lastTargetTick := now
    }

    ; ── Follow path: click toward next waypoint ──────────────────────
    ; Throttle clicks to every 400ms
    if ((now - _lastClickTick) < 400)
    {
        planTag := (_plan.Length > 0)
            ? (" wp=" _planIdx "/" _plan.Length)
            : " frontier"
        g_exploreLastReason := "moving(" g_exploreCurrentPercent "%" planTag
            . " → " Round(_targetCX * _STEP * ratio) "," Round(_targetCY * _STEP * ratio) ")"
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

    ; Pick the waypoint to click toward.
    ; Default look-ahead is +3 from current waypoint for smoother movement. If the
    ; projected screen position lands on a UI element (minimap, life globe, skill bar,
    ; flask bar, etc.) the click would be consumed by the UI instead of moving the
    ; character — so we walk *back* through the path toward the player to find a
    ; waypoint whose projection clears all known UI rects. Falling back to a closer
    ; waypoint keeps the same movement direction; a forward LA would push the click
    ; even deeper into the same UI element.
    ; Shared avoid-zone list: HUD elements, minimap/large map AND world
    ; interactables (AreaTransition, Waypoint, Portal, NPC, Checkpoint). The
    ; world-entity rects are what stops the exploration loop from accidentally
    ; clicking the next zone's entrance and ending the exploration session.
    avoidRects := GetAvoidZones(radarSnap, gameHwnd)
    clickWX   := 0
    clickWY   := 0
    screenPos := 0
    chosenLA  := 0

    if (_pathCoords.Length > 0 && _pathIdx <= _pathCoords.Length)
    {
        startLA := Min(_pathIdx + 3, _pathCoords.Length)
        la := startLA
        while (la >= _pathIdx)
        {
            wp  := _pathCoords[la]
            cwx := wp[1] * ratio
            cwy := wp[2] * ratio
            sp  := _ExploreWorldToScreen(cwx, cwy, playerWZ, w2sMat, gameHwnd)
            if (sp && !IsPointInAvoidZone(sp["x"], sp["y"], avoidRects))
            {
                clickWX   := cwx
                clickWY   := cwy
                screenPos := sp
                chosenLA  := la
                break
            }
            la--
        }
    }
    else
    {
        ; No path — click directly toward target. Same UI-safety check, but with
        ; only one candidate there's no fallback besides skipping this tick.
        clickWX := _targetCX * _STEP * ratio
        clickWY := _targetCY * _STEP * ratio
        sp      := _ExploreWorldToScreen(clickWX, clickWY, playerWZ, w2sMat, gameHwnd)
        if (sp && !IsPointInAvoidZone(sp["x"], sp["y"], avoidRects))
            screenPos := sp
    }

    if (!screenPos)
    {
        ; Either W2S projection failed, or every candidate waypoint projects onto a
        ; UI element. Skip the click — character keeps walking from the previous
        ; click for a moment; next tick has a fresh player position and the
        ; projection geometry usually shifts off the UI element. Stuck-detection at
        ; 3 s upstream will reset the target if we end up persistently blocked.
        g_exploreLastReason := "ui-blocked(" g_exploreCurrentPercent "% wp=" _pathIdx "/" _pathCoords.Length ")"
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

    laTag := (chosenLA > 0 && chosenLA != Min(_pathIdx + 3, _pathCoords.Length))
        ? " la=" chosenLA : ""
    g_exploreLastReason := "click(" g_exploreCurrentPercent "% wp=" _pathIdx "/" _pathCoords.Length laTag ")"
}

; ── Mark a coarse visited-grid cell as handled ────────────────────────────
; Used for unreachable targets (A* failure / stuck detection) so the plan
; skip-loop, the frontier search AND the completion percentage all stop
; considering the cell. Returns 1 when a walkable cell was newly marked
; (caller adds it to its visited-walkable counter), else 0.
_ExploreMarkCoarseVisited(visited, cx, cy, coarseW, coarseH, STEP, buf, dsz, bpr, gridW, rows)
{
    if (cx < 0 || cy < 0 || cx >= coarseW || cy >= coarseH)
        return 0
    cellIdx := cy * coarseW + cx
    if (NumGet(visited.Ptr, cellIdx, "UChar") != 0)
        return 0
    NumPut("UChar", 1, visited.Ptr, cellIdx)
    ; Same corner-walkability test the vision sweep uses — only walkable
    ; cells were counted into totalWalkable, so only those may increment
    ; the visited counter (keeps the percentage consistent).
    gx := cx * STEP
    gy := cy * STEP
    if (gx < gridW && gy < rows)
    {
        tIdx := gy * bpr + (gx >> 1)
        if (tIdx < dsz && ((NumGet(buf.Ptr, tIdx, "UChar") >> ((gx & 1) * 4)) & 0xF) != 0)
            return 1
    }
    return 0
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
; ── Precomputed exploration plan ─────────────────────────────────────────
; Builds an ordered list of waypoints covering the (known-at-zone-load)
; walkable terrain. Replaces the old "find nearest frontier each tick"
; greedy loop which tended to backtrack across the zone.
;
; Strategy:
;   1. Sample walkable cells in a regular spaced grid. Target ~60 samples,
;      computed from the area's total size so dense zones still get
;      reasonable coverage and tiny zones don't get bloated.
;   2. Greedy-nearest-from-start TSP over the samples — pick the closest
;      unvisited sample to the current position, repeat until all chosen.
;      O(n²) is fine for n≈60.
;   3. Append known AreaTransition entity positions LAST. The bot
;      naturally walks toward the zone exit at the end of the route. If
;      there are multiple, they're also sorted nearest-from-last-waypoint.
;
; The plan is rebuilt:
;   - On every area change (via _areaResetDone flag)
;   - When stuck-detection fires (player hasn't moved in 3 s) — likely the
;     current waypoint is unreachable, so re-plan from the new position
;
; Returns: Array of [gridX, gridY, kind] tuples. Empty array on failure.
_BuildExplorationPlan(terrain, radarSnap, startGX, startGY)
{
    plan := []
    if !(terrain && IsObject(terrain))
        return plan

    buf      := terrain["data"]
    dsz      := terrain["dataSize"]
    bpr      := terrain["bytesPerRow"]
    rows     := terrain["totalRows"]
    gridW    := terrain["gridWidth"]
    if (gridW <= 0 || rows <= 0)
        return plan

    ; ── Sample walkable cells in a regular grid ─────────────────────
    ; Spacing chosen to land ~SAMPLE_TARGET points across the zone. Min
    ; 20 cells so individual waypoints stay visually distinct.
    SAMPLE_TARGET := 60
    area := gridW * rows
    spacing := Max(20, Round(Sqrt(area / SAMPLE_TARGET)))
    half := spacing // 2

    samples := []
    cy := half
    while (cy < rows)
    {
        cx := half
        while (cx < gridW)
        {
            ; Walkability: 4-bit nibble per cell, packed two per byte.
            tIdx := cy * bpr + (cx >> 1)
            if (tIdx < dsz)
            {
                byt := NumGet(buf.Ptr, tIdx, "UChar")
                if (((byt >> ((cx & 1) * 4)) & 0xF) != 0)
                    samples.Push([cx, cy])
            }
            cx += spacing
        }
        cy += spacing
    }

    ; ── Collect AreaTransition positions ────────────────────────────
    ; These become the FINAL plan stops — the bot heads to the exit at
    ; the end of the route. Read entity worldPositions from the radar
    ; snapshot and convert to grid coords via WORLD_TO_GRID_RATIO.
    ;
    ; Important: AreaTransition entity anchors very often sit on blocked
    ; doorway-prop geometry (frames, archways, decorative pillars), not
    ; on a walkable cell. Pushing those raw coords causes A* to fail and
    ; the bot to repeatedly click into a wall, stuck-replan, click again,
    ; … and stall near the end of exploration. Each candidate is therefore
    ; nudged to the nearest walkable cell within a 16-cell radius before
    ; being added; transitions with no walkable cell anywhere in that
    ; halo are dropped from the plan entirely.
    transitions := []
    ratio := TerrainPathfinder.WORLD_TO_GRID_RATIO
    inGs   := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
    area2  := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    awake  := (area2 && IsObject(area2) && area2.Has("awakeEntities")) ? area2["awakeEntities"] : 0
    sample := (awake && IsObject(awake) && awake.Has("sample")) ? awake["sample"] : []
    if (sample && Type(sample) = "Array")
    {
        for _, entry in sample
        {
            if !(entry && IsObject(entry))
                continue
            entity := entry.Has("entity") ? entry["entity"] : 0
            if !(entity && IsObject(entity))
                continue
            path := entity.Has("path") ? entity["path"] : ""
            if (path = "" || !InStr(StrLower(path), "areatransition"))
                continue
            decoded := entity.Has("decodedComponents") ? entity["decodedComponents"] : 0
            if !(decoded && IsObject(decoded))
                continue
            render := decoded.Has("render") ? decoded["render"] : 0
            if !(render && IsObject(render) && render.Has("worldPosition"))
                continue
            wp := render["worldPosition"]
            wx := wp.Has("x") ? wp["x"] : 0
            wy := wp.Has("y") ? wp["y"] : 0
            if (wx = 0 && wy = 0)
                continue
            rawGX := Round(wx / ratio)
            rawGY := Round(wy / ratio)
            nudged := _NudgeToWalkableCell(rawGX, rawGY, buf, dsz, bpr, gridW, rows, 16)
            if nudged
                transitions.Push(nudged)
        }
    }

    ; ── Greedy nearest-from-start + 2-opt local search over samples ────
    ; Greedy alone tends to leave obvious "X" crossings in the tour. A
    ; couple of 2-opt passes irons those out — typically 10-20% shorter
    ; total travel distance, at ~5 ms for n≈60.
    cur := [startGX, startGY]
    plan := _GreedyTspOrder(samples, cur, "sample")
    _TwoOptOptimize(plan, startGX, startGY)

    ; ── Append transitions (same greedy + 2-opt from last plan stop) ──
    if (transitions.Length > 0)
    {
        last := plan.Length > 0
            ? [plan[plan.Length][1], plan[plan.Length][2]]
            : [startGX, startGY]
        transTour := _GreedyTspOrder(transitions, last, "transition")
        _TwoOptOptimize(transTour, last[1], last[2])
        for _, t in transTour
            plan.Push(t)
    }

    return plan
}

; ── 2-opt local-search tour optimisation ─────────────────────────────────
; Iteratively reverses sub-sequences of the tour when doing so shortens
; the total path. Operates IN-PLACE on the tour array. The "tour" here is
; an open path (not a cycle) — start is a fixed origin (startGX/startGY)
; and the path simply ends at the last element (no return-to-start edge).
;
; Convergence: usually 3-8 full passes for n ≤ 100. Iteration cap of 20
; bounds the worst case in pathological inputs. For n ≈ 60 the whole
; routine completes in ~5 ms.
;
; Why open-tour 2-opt: we want the bot to TRAVERSE the waypoints, not
; return to the player start. The standard closed-cycle formulation
; would penalise long "return" edges that don't exist in our scenario.
_TwoOptOptimize(tour, startGX, startGY)
{
    n := tour.Length
    if (n < 4)
        return   ; trivial — no swap can improve a < 4-stop tour

    maxIter := 20
    iter := 0
    while (iter < maxIter)
    {
        improved := false
        i := 1
        while (i < n)
        {
            j := i + 1
            while (j <= n)
            {
                ; Cost of the two edges that change if we reverse tour[i..j]:
                ;   before reversal: (i-1)→i and j→(j+1)
                ;   after  reversal: (i-1)→j and i→(j+1)
                ;
                ; The interior of the reversed segment keeps the same edge
                ; weights (just traversed in opposite direction), so the
                ; total tour delta depends only on those two endpoint edges.
                prevX := (i = 1) ? startGX : tour[i - 1][1]
                prevY := (i = 1) ? startGY : tour[i - 1][2]

                tiX := tour[i][1], tiY := tour[i][2]
                tjX := tour[j][1], tjY := tour[j][2]

                if (j < n)
                {
                    nextX := tour[j + 1][1]
                    nextY := tour[j + 1][2]
                    dCurr := _Hypot(prevX - tiX, prevY - tiY) + _Hypot(tjX - nextX, tjY - nextY)
                    dProp := _Hypot(prevX - tjX, prevY - tjY) + _Hypot(tiX - nextX, tiY - nextY)
                }
                else
                {
                    ; Open tour — j is the last stop; only the leading
                    ; edge (i-1)→i changes to (i-1)→j. There's no trailing
                    ; edge to compensate, so this becomes a pure "should
                    ; we put node j here instead of node i" check that
                    ; happens to reverse the suffix.
                    dCurr := _Hypot(prevX - tiX, prevY - tiY)
                    dProp := _Hypot(prevX - tjX, prevY - tjY)
                }

                ; Strict-better with a tiny epsilon avoids equal-cost swap
                ; thrashing in regular grids.
                if (dProp + 0.00001 < dCurr)
                {
                    ; In-place reverse of tour[i..j]
                    a := i, b := j
                    while (a < b)
                    {
                        tmp := tour[a]
                        tour[a] := tour[b]
                        tour[b] := tmp
                        a += 1
                        b -= 1
                    }
                    improved := true
                }
                j += 1
            }
            i += 1
        }
        if !improved
            break
        iter += 1
    }
}

_Hypot(dx, dy)
{
    return Sqrt(dx * dx + dy * dy)
}

; ── Walkability nudge ─────────────────────────────────────────────────────
; Returns the nearest walkable grid cell within `maxRadius` of (gx, gy), or
; 0 if no walkable cell exists in that halo. Used to keep AreaTransition
; waypoints off blocked geometry (doorway frames, decorative pillars):
; the entity world position often anchors on the prop itself, not on a
; walkable cell, so we pre-resolve the closest valid cell before adding
; the transition to the exploration plan.
;
; Search pattern: spiral perimeter at increasing radius. First walkable
; cell found wins (Chebyshev-distance closest, not Euclidean — close
; enough for nudge purposes and lets us early-out without scanning the
; full halo).
;
; Walkability uses the same 4-bit-per-cell nibble layout the maphack scan
; consumes elsewhere in this module.
_NudgeToWalkableCell(gx, gy, buf, dsz, bpr, gridW, rows, maxRadius)
{
    if _IsGridCellWalkable(gx, gy, buf, dsz, bpr, gridW, rows)
        return [gx, gy]

    r := 1
    while (r <= maxRadius)
    {
        ; Scan only the perimeter at this radius (corners + edges).
        dy := -r
        while (dy <= r)
        {
            ; On the top/bottom rows we sweep the full x-range;
            ; on the side rows we only check the two end-columns to
            ; avoid re-scanning interior cells covered at smaller r.
            if (dy = -r || dy = r)
            {
                dx := -r
                while (dx <= r)
                {
                    if _IsGridCellWalkable(gx + dx, gy + dy, buf, dsz, bpr, gridW, rows)
                        return [gx + dx, gy + dy]
                    dx++
                }
            }
            else
            {
                if _IsGridCellWalkable(gx - r, gy + dy, buf, dsz, bpr, gridW, rows)
                    return [gx - r, gy + dy]
                if _IsGridCellWalkable(gx + r, gy + dy, buf, dsz, bpr, gridW, rows)
                    return [gx + r, gy + dy]
            }
            dy++
        }
        r++
    }
    return 0
}

_IsGridCellWalkable(cx, cy, buf, dsz, bpr, gridW, rows)
{
    if (cx < 0 || cx >= gridW || cy < 0 || cy >= rows)
        return false
    tIdx := cy * bpr + (cx >> 1)
    if (tIdx >= dsz)
        return false
    byt := NumGet(buf.Ptr, tIdx, "UChar")
    return (((byt >> ((cx & 1) * 4)) & 0xF) != 0)
}

; Greedy-nearest TSP: starting from `start` [gx, gy], repeatedly picks
; the closest unvisited point, returning the ordered list with each
; entry tagged with `kind`. Uses squared distance so no sqrt per
; comparison.
_GreedyTspOrder(points, start, kind)
{
    ordered := []
    remaining := points.Clone()
    cur := [start[1], start[2]]
    while (remaining.Length > 0)
    {
        bestIdx := 0
        bestDist := 999999999
        for i, p in remaining
        {
            dx := p[1] - cur[1]
            dy := p[2] - cur[2]
            d := dx * dx + dy * dy
            if (d < bestDist)
            {
                bestDist := d
                bestIdx := i
            }
        }
        if (bestIdx = 0)
            break
        chosen := remaining[bestIdx]
        remaining.RemoveAt(bestIdx)
        ordered.Push([chosen[1], chosen[2], kind])
        cur := [chosen[1], chosen[2]]
    }
    return ordered
}

LoadExplorationConfig()
{
    global g_exploreEnabled, g_exploreTargetPercent

    iniFile := A_ScriptDir "\poeformance_config.ini"
    section := "Exploration"

    g_exploreEnabled       := IniRead(iniFile, section, "Enabled", "0") = "1"
    g_exploreTargetPercent := Integer(IniRead(iniFile, section, "TargetPercent", "80"))
    g_exploreTargetPercent := Max(10, Min(99, g_exploreTargetPercent))
}

SaveExplorationConfig()
{
    global g_exploreEnabled, g_exploreTargetPercent

    iniFile := A_ScriptDir "\poeformance_config.ini"
    section := "Exploration"

    IniWrite(g_exploreEnabled ? "1" : "0", iniFile, section, "Enabled")
    IniWrite(g_exploreTargetPercent, iniFile, section, "TargetPercent")
}
