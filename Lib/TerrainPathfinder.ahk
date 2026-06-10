; Lib\TerrainPathfinder.ahk
; Shared A* pathfinding on the PoE2 walkable terrain grid.
;
; Extracted from RadarOverlay so both RadarOverlay and CombatAutomation
; can share the same pathfinding logic.
;
; Usage:
;   pf := TerrainPathfinder()
;   pf.SetTerrain(terrainData)          ; from ReadTerrainData()
;   path := pf.FindPath(sGX, sGY, eGX, eGY)
;   dist := pf.ComputePathWorldDistance(path)
;   pf.HasLineOfSight(x0, y0, x1, y1)

class TerrainPathfinder
{
    static WORLD_TO_GRID_RATIO := 10.86957   ; 250.0 / 23

    __New()
    {
        this._buf  := 0
        this._bpr  := 0
        this._rows := 0
        this._dsz  := 0
        this._maxW := 0
        this._lastDebug := ""
        this._lastFailExhausted := false
        this._hctx := 0
    }

    ; Stores terrain data from ReadTerrainData() result.
    ; terrainData: Map with keys "data" (Buffer), "bytesPerRow", "totalRows", "dataSize"
    SetTerrain(terrainData)
    {
        if !(terrainData && IsObject(terrainData) && terrainData.Has("data"))
        {
            this._buf := 0
            return
        }
        this._buf  := terrainData["data"]
        this._bpr  := terrainData["bytesPerRow"]
        this._rows := terrainData["totalRows"]
        this._dsz  := terrainData["dataSize"]
        this._maxW := this._bpr * 2
    }

    HasTerrain() => this._buf != 0

    ; Attaches (or detaches with 0) a terrain-height context from
    ; GetTerrainHeightContext(). Only a context that passed self-validation
    ; ("ok") activates the height-aware checks; "pending"/"bad"/0 keep the
    ; pathfinder in plain 2D mode. Hot fields are cached as properties so
    ; the A*/LoS loops can do memo lookups without per-step Map access.
    ;
    ; Slope threshold: 30 world units per fine cell of distance (stairs and
    ; ramps stay well below it; cross-floor seams on multi-level zones are
    ; hundreds of units). Heights are memoized at 4-cell resolution, so the
    ; effective minimum span is 4 cells.
    SetHeights(ctx)
    {
        if (ctx && IsObject(ctx) && ctx["val"] = "ok")
        {
            this._hctx     := ctx
            this._hMemoVal := ctx["memoVal"].Ptr
            this._hMemoDone:= ctx["memoDone"].Ptr
            this._hMemoW   := ctx["memoW"]
            this._hGridW   := ctx["gridW"]
            this._hRows    := ctx["rows"]
        }
        else
            this._hctx := 0
    }

    HeightsEnabled => this._hctx != 0

    ; The last debug/reason string from FindPath().
    LastDebug => this._lastDebug

    ; True when the last FindPath() failure exhausted the search space
    ; (genuinely no route in the padded bounding box) as opposed to giving
    ; up on its iteration/deadline budget. Callers use this to distinguish
    ; "unreachable — skip the target" from "just far away — keep trying".
    LastFailExhausted => this._lastFailExhausted

    ; Returns true if grid cell (gx, gy) is walkable (packed nibble terrain data).
    IsWalkable(gx, gy)
    {
        buf := this._buf, bpr := this._bpr, rows := this._rows, dsz := this._dsz
        if (!buf || gx < 0 || gy < 0 || gy >= rows || gx >= bpr * 2)
            return false
        idx := gy * bpr + (gx >> 1)
        if (idx >= dsz)
            return false
        byt := NumGet(buf.Ptr, idx, "UChar")
        return ((byt >> ((gx & 1) * 4)) & 0xF) != 0
    }

    ; Bresenham line-of-sight: true iff all cells on the line are walkable.
    ; With a validated height context the line must also stay on one level —
    ; otherwise path smoothing would happily cut across a floor seam that
    ; the height-aware A* just routed around. The memo-hit path is inlined
    ; (raw NumGets on cached pointers); only uncached cells fall back to
    ; TerrainHeightAt, which computes and memoizes them.
    HasLineOfSight(x0, y0, x1, y1)
    {
        heightsOn := this._hctx != 0
        if heightsOn
        {
            hVal := this._hMemoVal, hDone := this._hMemoDone, hMW := this._hMemoW
            hGW := this._hGridW,    hRows := this._hRows
            cxq := (x0 < 0) ? 0 : (x0 >= hGW ? hGW - 1 : x0)
            cyq := (y0 < 0) ? 0 : (y0 >= hRows ? hRows - 1 : y0)
            mIdx := (cyq >> 2) * hMW + (cxq >> 2)
            lastH := NumGet(hDone, mIdx, "UChar")
                ? NumGet(hVal, mIdx * 4, "Float")
                : TerrainHeightAt(this._hctx, x0, y0)
        }
        dx := Abs(x1 - x0), dy := Abs(y1 - y0)
        sx := (x0 < x1) ? 1 : -1
        sy := (y0 < y1) ? 1 : -1
        err := dx - dy
        x := x0, y := y0
        loop 400
        {
            if !this.IsWalkable(x, y)
                return false
            if (heightsOn)
            {
                cxq := (x < 0) ? 0 : (x >= hGW ? hGW - 1 : x)
                cyq := (y < 0) ? 0 : (y >= hRows ? hRows - 1 : y)
                mIdx := (cyq >> 2) * hMW + (cxq >> 2)
                h := NumGet(hDone, mIdx, "UChar")
                    ? NumGet(hVal, mIdx * 4, "Float")
                    : TerrainHeightAt(this._hctx, x, y)
                ; 120 = 30 units/cell × the 4-cell memo resolution
                if (Abs(h - lastH) > 120)
                    return false
                lastH := h
            }
            if (x = x1 && y = y1)
                return true
            e2 := err * 2
            if (e2 > -dy)
                err -= dy, x += sx
            if (e2 < dx)
                err += dx, y += sy
        }
        return false
    }

    ; Finds the nearest walkable cell within radius 5 of (gx, gy).
    ; Returns [walkableGX, walkableGY] or 0 if none found.
    NudgeToWalkable(gx, gy)
    {
        if this.IsWalkable(gx, gy)
            return [gx, gy]
        loop 5
        {
            r := A_Index
            loop r * 8
            {
                angle := (A_Index - 1) * (6.2831853 / (r * 8))
                nx := gx + Round(r * Cos(angle))
                ny := gy + Round(r * Sin(angle))
                if this.IsWalkable(nx, ny)
                    return [nx, ny]
            }
        }
        return 0
    }

    ; A* pathfinder on the walkable terrain grid.
    ; startGX/GY and endGX/GY are absolute grid coordinates.
    ; Returns an Array of [gx, gy] pairs (start → end), smoothed via line-of-sight culling.
    ; Returns [] on failure.
    FindPath(startGX, startGY, endGX, endGY)
    {
        buf := this._buf, bpr := this._bpr, rows := this._rows, dsz := this._dsz
        this._lastFailExhausted := false
        if !buf
        {
            this._lastDebug := "no-terrain"
            return []
        }
        maxW := this._maxW

        ; Clamp to grid bounds.
        startGX := Max(0, Min(startGX, maxW - 1))
        startGY := Max(0, Min(startGY, rows - 1))
        endGX   := Max(0, Min(endGX,   maxW - 1))
        endGY   := Max(0, Min(endGY,   rows - 1))

        ; Nudge start / end to nearest walkable cell.
        sNudge := this.NudgeToWalkable(startGX, startGY)
        eNudge := this.NudgeToWalkable(endGX, endGY)
        if (!sNudge || !eNudge)
        {
            ; No walkable cell anywhere near an endpoint — treat as a true
            ; unreachable, not a budget timeout.
            this._lastFailExhausted := true
            this._lastDebug := "nudge-fail sW=" (sNudge ? "1" : "0") " eW=" (eNudge ? "1" : "0")
            return []
        }
        startGX := sNudge[1], startGY := sNudge[2]
        endGX   := eNudge[1], endGY   := eNudge[2]

        ; ── Coarse grid (STEP cells per logical unit) ─────────────────
        rawDist := Max(Abs(startGX - endGX), Abs(startGY - endGY))
        STEP := (rawDist > 500) ? 8 : (rawDist > 200) ? 4 : 2
        csX := startGX // STEP,   csY := startGY // STEP
        ceX := endGX   // STEP,   ceY := endGY   // STEP
        cmW := maxW    // STEP + 1
        cmH := rows    // STEP + 1

        STRIDE   := cmW + 1
        startKey := csY * STRIDE + csX
        endKey   := ceY * STRIDE + ceX

        ; Bounding box (in coarse coords) + padding.
        dist  := Max(Abs(csX - ceX), Abs(csY - ceY))
        PAD   := Max(30, dist // 4)
        bMinX := Max(0,      Min(csX, ceX) - PAD)
        bMaxX := Min(cmW-1,  Max(csX, ceX) + PAD)
        bMinY := Max(0,      Min(csY, ceY) - PAD)
        bMaxY := Min(cmH-1,  Max(csY, ceY) + PAD)

        ; A* data structures.
        gScore   := Map()
        cameFrom := Map()
        closed   := Map()
        gScore[startKey] := 0

        h0   := (Abs(csX - ceX) + Abs(csY - ceY)) * 10
        heap := [[h0, startKey]]

        ; 8-directional movement.
        static DX := [1, -1, 0, 0, 1, 1, -1, -1]
        static DY := [0, 0, 1, -1, 1, -1, 1, -1]
        static DC := [10, 10, 10, 10, 14, 14, 14, 14]

        searchArea := (bMaxX - bMinX + 1) * (bMaxY - bMinY + 1)
        MAX_ITER := Min(200000, Max(15000, searchArea))
        iter     := 0
        found    := false
        deadline := A_TickCount + ((rawDist > 400) ? 500 : 200)
        heightsOn := this._hctx != 0
        if heightsOn
        {
            hVal := this._hMemoVal, hDone := this._hMemoDone, hMW := this._hMemoW
            hGW := this._hGridW,    hRows := this._hRows
            ; Max height delta per STEP-hop: 30 units/cell × hop length
            ; (4-cell floor because heights are memoized at 1/4 resolution).
            hAllow := 30.0 * Max(STEP, 4)
        }

        while (heap.Length > 0 && iter < MAX_ITER && A_TickCount < deadline)
        {
            ; Heap pop.
            curItem  := heap[1]
            lastItem := heap.RemoveAt(heap.Length)
            if heap.Length > 0
            {
                heap[1] := lastItem
                this._HeapDown(heap, 1)
            }
            curKey := curItem[2]

            if closed.Has(curKey)
                continue
            closed[curKey] := true
            iter++

            if (curKey = endKey)
            {
                found := true
                break
            }

            cx := Mod(curKey, STRIDE)
            cy := (curKey - cx) // STRIDE
            curG := gScore[curKey]

            ; Height of the node being expanded — once per node, inlined
            ; memo-hit path (raw NumGets), miss falls back to TerrainHeightAt.
            if heightsOn
            {
                gx0 := cx * STEP, gy0 := cy * STEP
                cxq := (gx0 >= hGW) ? hGW - 1 : gx0
                cyq := (gy0 >= hRows) ? hRows - 1 : gy0
                mIdx := (cyq >> 2) * hMW + (cxq >> 2)
                curH := NumGet(hDone, mIdx, "UChar")
                    ? NumGet(hVal, mIdx * 4, "Float")
                    : TerrainHeightAt(this._hctx, gx0, gy0)
            }

            loop 8
            {
                ii := A_Index
                nx := cx + DX[ii]
                ny := cy + DY[ii]

                if (nx < bMinX || nx > bMaxX || ny < bMinY || ny > bMaxY)
                    continue
                ; Check walkability at actual grid coordinates.
                if !this.IsWalkable(nx * STEP, ny * STEP)
                    continue
                ; Reject cross-floor seams (multi-level zones) when heights
                ; are available — same walkable nibble, different storey.
                if heightsOn
                {
                    gx1 := nx * STEP, gy1 := ny * STEP
                    cxq := (gx1 >= hGW) ? hGW - 1 : gx1
                    cyq := (gy1 >= hRows) ? hRows - 1 : gy1
                    mIdx := (cyq >> 2) * hMW + (cxq >> 2)
                    nH := NumGet(hDone, mIdx, "UChar")
                        ? NumGet(hVal, mIdx * 4, "Float")
                        : TerrainHeightAt(this._hctx, gx1, gy1)
                    if (Abs(nH - curH) > hAllow)
                        continue
                }

                nKey := ny * STRIDE + nx
                if closed.Has(nKey)
                    continue

                tentG := curG + DC[ii]
                oldG  := gScore.Has(nKey) ? gScore[nKey] : 999999999

                if (tentG < oldG)
                {
                    gScore[nKey]   := tentG
                    cameFrom[nKey] := curKey
                    h := (Abs(nx - ceX) + Abs(ny - ceY)) * 10
                    heap.Push([tentG + h, nKey])
                    this._HeapUp(heap, heap.Length)
                }
            }
        }

        if !found
        {
            ; Empty heap = the whole (padded) search area was explored and
            ; the goal was never reached → genuinely no route. A non-empty
            ; heap means we bailed on the iteration cap or the deadline —
            ; the target may well be reachable, just far / expensive.
            this._lastFailExhausted := (heap.Length = 0)
            this._lastDebug := "astar-fail iter=" iter "/" MAX_ITER " heap=" heap.Length " rawD=" rawDist " STEP=" STEP
            return []
        }
        this._lastDebug := "ok iter=" iter "/" MAX_ITER " STEP=" STEP

        ; Reconstruct path (end → start), then reverse.
        path := []
        k    := endKey
        loop 20000
        {
            cx := Mod(k, STRIDE)
            cy := (k - cx) // STRIDE
            path.Push([cx * STEP, cy * STEP])
            if (k = startKey || !cameFrom.Has(k))
                break
            k := cameFrom[k]
        }

        n := path.Length
        loop n // 2
        {
            ii := A_Index, jj := n - ii + 1
            tmp := path[ii], path[ii] := path[jj], path[jj] := tmp
        }

        return this._SmoothPath(path)
    }

    ; Computes total path length in world units from an array of [gx, gy] grid coords.
    ComputePathWorldDistance(path)
    {
        if (!path || path.Length < 2)
            return 0
        totalGrid := 0.0
        loop path.Length - 1
        {
            dx := path[A_Index + 1][1] - path[A_Index][1]
            dy := path[A_Index + 1][2] - path[A_Index][2]
            totalGrid += Sqrt(dx * dx + dy * dy)
        }
        return totalGrid * TerrainPathfinder.WORLD_TO_GRID_RATIO
    }

    ; Computes terrain-aware distance between two world positions.
    ; Fast path: line-of-sight clear → Euclidean distance (no A* needed).
    ; Slow path: line-of-sight blocked → A* path length.
    ; Returns: world-unit distance, or -1 if terrain unavailable.
    ComputeTerrainDistance(worldX1, worldY1, worldX2, worldY2)
    {
        if !this._buf
            return -1

        ratio := TerrainPathfinder.WORLD_TO_GRID_RATIO
        gx1 := Round(worldX1 / ratio)
        gy1 := Round(worldY1 / ratio)
        gx2 := Round(worldX2 / ratio)
        gy2 := Round(worldY2 / ratio)

        ; Fast path: if line-of-sight is clear, Euclidean is accurate
        if this.HasLineOfSight(gx1, gy1, gx2, gy2)
        {
            dx := worldX1 - worldX2
            dy := worldY1 - worldY2
            return Sqrt(dx * dx + dy * dy)
        }

        ; Slow path: A* to get terrain-aware distance
        path := this.FindPath(gx1, gy1, gx2, gy2)
        if (path.Length < 2)
            return -1

        return this.ComputePathWorldDistance(path)
    }

    ; ── Private helpers ──────────────────────────────────────────────

    ; Reduces path waypoints by greedily skipping intermediate points with line-of-sight.
    _SmoothPath(path)
    {
        n := path.Length
        if (n <= 2)
            return path

        smoothed := [path[1]]
        i := 1
        while (i < n)
        {
            best := i + 1
            loop Min(n - i, 25) - 1
            {
                j := i + A_Index + 1
                if this.HasLineOfSight(smoothed[smoothed.Length][1], smoothed[smoothed.Length][2],
                                       path[j][1], path[j][2])
                    best := j
            }
            i := best
            if (i <= n)
                smoothed.Push(path[i])
        }
        return smoothed
    }

    ; Binary min-heap: sift item at index i upward.
    _HeapUp(heap, i)
    {
        while (i > 1)
        {
            p := i >> 1
            if (heap[p][1] <= heap[i][1])
                break
            tmp := heap[p], heap[p] := heap[i], heap[i] := tmp
            i := p
        }
    }

    ; Binary min-heap: sift item at index i downward.
    _HeapDown(heap, i)
    {
        n := heap.Length
        loop
        {
            s := i, l := i * 2, r := i * 2 + 1
            if (l <= n && heap[l][1] < heap[s][1])
                s := l
            if (r <= n && heap[r][1] < heap[s][1])
                s := r
            if (s = i)
                break
            tmp := heap[i], heap[i] := heap[s], heap[s] := tmp
            i := s
        }
    }
}
