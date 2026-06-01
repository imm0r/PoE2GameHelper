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

    ; The last debug/reason string from FindPath().
    LastDebug => this._lastDebug

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
    HasLineOfSight(x0, y0, x1, y1)
    {
        dx := Abs(x1 - x0), dy := Abs(y1 - y0)
        sx := (x0 < x1) ? 1 : -1
        sy := (y0 < y1) ? 1 : -1
        err := dx - dy
        x := x0, y := y0
        loop 400
        {
            if !this.IsWalkable(x, y)
                return false
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
