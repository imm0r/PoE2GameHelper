; TerrainHeights.ahk
; Terrain height grid — faithful port of GameHelper2's GetTerrainHeight()
; (AreaInstance.cs) including the sub-tile RLE height decoding and the
; rotation lookup handling.
;
; Why: the walkable terrain grid is strictly 2D. Multi-level zones (bridge /
; tower layouts like The Spires of Deshar) overlap several floors in XY, so
; A* happily routes across level seams the character can't physically cross
; and the AutoPilot ping-pongs at the ledge. With per-cell heights the
; pathfinder can reject transitions whose height delta exceeds a walkable
; slope, and exploration clicks can project with the target floor's real Z.
;
; Data sources (all already present in this project):
;   - TileDetails vector + TileHeightMultiplier  (PoE2Offsets.TerrainMetadata)
;   - "Terrain Rotation Selector" (9 bytes) and "Terrain Rotator Helper"
;     (25 bytes) static arrays found by the existing pattern scan
;     (StaticOffsetsPatterns.ahk / PoE2MemoryReader.FindStaticAddresses)
;   - SubTileStruct.SubTileHeight StdVector per unique sub-tile template
;
; Formula (GameHelper2):
;   height = (TileHeight * TileHeightMultiplier + subTileHeight) * 7.8125 * -1
; The result is in world units and comparable to Render.worldPosition.z —
; which is exactly how the context self-validates (see _THValidate): if the
; computed height at the player's grid cell doesn't match the player's
; actual Z, the feature disables itself for the area (fail-safe) and the
; diagnostic shows up in the status overlay as "hz:...".
;
; Per-cell heights are evaluated lazily and memoized on a coarse (4×4-cell)
; grid so the A*/LoS hot path stays cheap.
;
; Included by InGameStateMonitor.ahk

; ── Public: shared per-area height context ────────────────────────────────
; Returns the height context Map for the current area (built once, cached),
; or 0 when unavailable (no terrain, missing patterns, read failure).
; While validation is "pending" each call retries with the current player
; position until it can decide "ok" / "bad" (max 10 samples).
GetTerrainHeightContext(radarSnap)
{
    global g_reader, g_exploreHeightDiag
    static _ctx := 0
    static _ctxKey := ""

    inGs := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
    area := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    terrain := (area && IsObject(area) && area.Has("terrain") && area["terrain"]) ? area["terrain"] : 0
    if !(terrain && IsObject(terrain) && area.Has("address") && area["address"])
        return 0
    if !(IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle)
        return 0

    areaHash := radarSnap.Has("currentAreaHash") ? radarSnap["currentAreaHash"] : 0
    key := areaHash "_" terrain["dataSize"]
    if (key = _ctxKey)
    {
        if (_ctx && _ctx["val"] = "pending")
            _THValidate(_ctx, area)
        return _ctx
    }

    _ctx := _THBuildContext(g_reader, area["address"], terrain)
    _ctxKey := key
    if _ctx
        _THValidate(_ctx, area)
    return _ctx
}

; ── Public: height lookup (world-unit Z) at fine grid cell (gx, gy) ──────
; Lazy + memoized at 4×4-cell resolution. Returns 0.0 outside the tile area.
TerrainHeightAt(ctx, gx, gy)
{
    gw := ctx["gridW"]
    gr := ctx["rows"]
    gx := (gx < 0) ? 0 : (gx >= gw ? gw - 1 : gx)
    gy := (gy < 0) ? 0 : (gy >= gr ? gr - 1 : gy)
    mIdx := (gy >> 2) * ctx["memoW"] + (gx >> 2)
    done := ctx["memoDone"]
    if NumGet(done.Ptr, mIdx, "UChar")
        return NumGet(ctx["memoVal"].Ptr, mIdx * 4, "Float")
    h := _THComputeCellHeight(ctx, gx, gy)
    NumPut("Float", h, ctx["memoVal"].Ptr, mIdx * 4)
    NumPut("UChar", 1, done.Ptr, mIdx)
    return h
}

; ── Context construction ─────────────────────────────────────────────────
; Bulk-reads the tile structs, the two rotation lookup tables and every
; unique sub-tile height array (zones instantiate thousands of tiles from a
; few dozen templates, so this is a handful of small reads). Returns 0 on
; any validation failure.
_THBuildContext(reader, areaAddr, terrain)
{
    global g_exploreHeightDiag

    sa := reader.StaticAddresses
    if !(IsObject(sa) && sa.Has("Terrain Rotation Selector") && sa.Has("Terrain Rotator Helper"))
    {
        g_exploreHeightDiag := "no-pattern"
        return 0
    }
    rotSel  := reader.Mem.ReadBytes(sa["Terrain Rotation Selector"], 9)
    rotHelp := reader.Mem.ReadBytes(sa["Terrain Rotator Helper"], 25)
    if (!rotSel || !rotHelp)
    {
        g_exploreHeightDiag := "rot-read-fail"
        return 0
    }

    terrainBase := areaAddr + PoE2Offsets.AreaInstance["TerrainMetadata"]
    numTX := reader.Mem.ReadInt64(terrainBase + PoE2Offsets.TerrainMetadata["TotalTilesX"])
    numTY := reader.Mem.ReadInt64(terrainBase + PoE2Offsets.TerrainMetadata["TotalTilesY"])
    if (numTX < 1 || numTY < 1 || numTX * numTY > 250000)
    {
        g_exploreHeightDiag := "tiles-oob(" numTX "x" numTY ")"
        return 0
    }
    mult := reader.Mem.ReadShort(terrainBase + PoE2Offsets.TerrainMetadata["TileHeightMultiplier"])

    tileStructSize := 0x38
    tileVecFirst := reader.Mem.ReadInt64(terrainBase + PoE2Offsets.TerrainMetadata["TileDetailsPtr"])
    tileVecLast  := reader.Mem.ReadInt64(terrainBase + PoE2Offsets.TerrainMetadata["TileDetailsPtr"] + 8)
    if (!reader.IsProbablyValidPointer(tileVecFirst)
        || (tileVecLast - tileVecFirst) // tileStructSize < numTX * numTY)
    {
        g_exploreHeightDiag := "tilevec-bad"
        return 0
    }
    tiles := reader.Mem.ReadBytes(tileVecFirst, numTX * numTY * tileStructSize)
    if !tiles
    {
        g_exploreHeightDiag := "tiles-read-fail"
        return 0
    }

    ; Collect every unique SubTileDetailsPtr and read its height vector once.
    subMap := Map()
    offSub := PoE2Offsets.TileStruct["SubTileDetailsPtr"]
    total := numTX * numTY
    i := 0
    while (i < total)
    {
        subPtr := NumGet(tiles.Ptr, i * tileStructSize + offSub, "Ptr")
        if (subPtr && !subMap.Has(subPtr))
        {
            arr := Buffer(0)
            if reader.IsProbablyValidPointer(subPtr)
            {
                ; SubTileStruct.SubTileHeight is an StdVector at +0x00
                hBegin := reader.Mem.ReadInt64(subPtr)
                hEnd   := reader.Mem.ReadInt64(subPtr + 8)
                len := hEnd - hBegin
                if (hBegin && len > 0 && len <= 2048)
                {
                    b := reader.Mem.ReadBytes(hBegin, len)
                    if b
                        arr := b
                }
            }
            subMap[subPtr] := arr
        }
        i++
    }

    ; Memo buffers at 1/4 resolution of the fine grid.
    gridW := terrain["bytesPerRow"] * 2
    rows  := terrain["totalRows"]
    memoW := (gridW >> 2) + 1
    memoH := (rows  >> 2) + 1
    if (memoW * memoH > 4000000)
    {
        g_exploreHeightDiag := "memo-oob"
        return 0
    }

    return Map(
        "tiles",    tiles,
        "numTX",    numTX,
        "numTY",    numTY,
        "mult",     mult,
        "rotSel",   rotSel,
        "rotHelp",  rotHelp,
        "subMap",   subMap,
        "gridW",    gridW,
        "rows",     rows,
        "memoW",    memoW,
        "memoVal",  Buffer(memoW * memoH * 4, 0),
        "memoDone", Buffer(memoW * memoH, 0),
        "val",      "pending",
        "valTries", 0
    )
}

; ── Self-validation against the player's actual Z ────────────────────────
; The formula's output must match Render.worldPosition.z for an on-ground
; player. One sample per call while "pending"; first match within 100 world
; units flips to "ok", 10 failed samples flip to "bad" (feature disabled for
; the area). The verdict lands in g_exploreHeightDiag for the status overlay.
_THValidate(ctx, area)
{
    global g_exploreHeightDiag

    prc := area.Has("playerRenderComponent") ? area["playerRenderComponent"] : 0
    if !(prc && IsObject(prc) && prc.Has("worldPosition"))
        return
    wp := prc["worldPosition"]
    px := wp.Has("x") ? wp["x"] : 0
    py := wp.Has("y") ? wp["y"] : 0
    pz := wp.Has("z") ? wp["z"] : 0
    if (px = 0 && py = 0)
        return

    ratio := TerrainPathfinder.WORLD_TO_GRID_RATIO
    h := TerrainHeightAt(ctx, Round(px / ratio), Round(py / ratio))
    delta := Abs(h - pz)
    if (delta <= 100)
    {
        ctx["val"] := "ok"
        g_exploreHeightDiag := "ok(d" Round(delta) ")"
        return
    }
    ctx["valTries"] := ctx["valTries"] + 1
    if (ctx["valTries"] >= 10)
    {
        ctx["val"] := "bad"
        g_exploreHeightDiag := "off(d" Round(delta) ")"
    }
}

; ── Per-cell height (uncached path) ──────────────────────────────────────
; Tile lookup + rotation transform + sub-tile RLE decode, exactly mirroring
; GameHelper2. All reads come from buffers captured at context build time —
; no cross-process reads on this path.
_THComputeCellHeight(ctx, gx, gy)
{
    TILE := 0x17   ; TileStructure.TileToGridConversion (23 cells per tile)

    tileX := gx // TILE
    tileY := gy // TILE
    if (tileX >= ctx["numTX"] || tileY >= ctx["numTY"])
        return 0.0

    tiles := ctx["tiles"]
    tBase := (tileY * ctx["numTX"] + tileX) * 0x38
    tileHeight := NumGet(tiles.Ptr, tBase + PoE2Offsets.TileStruct["TileHeight"], "Short")
    rotSelIdx  := NumGet(tiles.Ptr, tBase + PoE2Offsets.TileStruct["RotationSelector"], "UChar")
    subPtr     := NumGet(tiles.Ptr, tBase + PoE2Offsets.TileStruct["SubTileDetailsPtr"], "Ptr")

    sub := 0
    subMap := ctx["subMap"]
    if (subPtr && subMap.Has(subPtr) && subMap[subPtr].Size > 0)
    {
        gxr := Mod(gx, TILE)
        gyr := Mod(gy, TILE)

        rotSel := ctx["rotSel"]
        rotationSelected := (rotSelIdx < 9) ? NumGet(rotSel.Ptr, rotSelIdx, "UChar") * 3 : 24
        if (rotationSelected > 24)
            rotationSelected := 24

        ; rotatorMetrix (0-based in the C# original; AHK arrays are 1-based,
        ; hence the +1 at the lookups below)
        rm := [TILE - gxr - 1, gxr, TILE - gyr - 1, gyr]
        rotHelp := ctx["rotHelp"]
        rx0 := NumGet(rotHelp.Ptr, rotationSelected, "UChar")
        rx1 := NumGet(rotHelp.Ptr, rotationSelected + 1, "UChar")
        ry0 := NumGet(rotHelp.Ptr, rotationSelected + 2, "UChar")
        ry1 := (rx0 = 0) ? 2 : 0

        ix := rx0 * 2 + rx1
        iy := ry0 + ry1
        if (ix >= 0 && ix <= 3 && iy >= 0 && iy <= 3)
        {
            finalX := rm[ix + 1]
            finalY := rm[iy + 1]
            sub := _THSubHeight(subMap[subPtr], finalY * TILE + finalX)
        }
    }

    return (tileHeight * ctx["mult"] + sub) * 7.8125 * -1
}

; Sub-tile height decode — GameHelper2 GetSubTerrainHeight. The array length
; encodes the format: 1 = constant; 0x45/0x89/0x119 = 1/2/4-bit indices into
; 2/4/16 leading sbyte values; anything longer = plain sbyte per cell.
_THSubHeight(buf, index)
{
    len := buf.Size
    if (len = 0 || index < 0)
        return 0
    if (len = 1)
        return NumGet(buf.Ptr, 0, "Char")
    if (len = 0x45)
    {
        bi := (index >> 3) + 2
        if (bi >= len)
            return 0
        sel := (NumGet(buf.Ptr, bi, "UChar") >> (index & 7)) & 0x1
        return NumGet(buf.Ptr, sel, "Char")
    }
    if (len = 0x89)
    {
        bi := (index >> 2) + 4
        if (bi >= len)
            return 0
        sel := (NumGet(buf.Ptr, bi, "UChar") >> ((index & 3) << 1)) & 0x3
        return NumGet(buf.Ptr, sel, "Char")
    }
    if (len = 0x119)
    {
        bi := (index >> 1) + 16
        if (bi >= len)
            return 0
        sel := (NumGet(buf.Ptr, bi, "UChar") >> ((index & 1) << 2)) & 0xF
        return NumGet(buf.Ptr, sel, "Char")
    }
    if (len > index)
        return NumGet(buf.Ptr, index, "Char")
    return 0
}
