; AreaInstanceProbe.ahk
; TEMPORARY post-patch diagnostic — NOT part of the per-frame hot path.
;
; After a PoE2 patch, AreaInstance fields past PlayerInfo can shift while
; ServerDataPtr (PlayerInfo+0x00 -> inventory) still resolves. Concretely:
; entities (was AreaInstance+0x6C0), terrain (was +0x8A0) and the local-player
; pointer (was PlayerInfo+0x20) move, which kills the radar, HP/Mana/ES and
; skills/buffs while inventory keeps working. This probe anchors on the known-good
; areaInstanceData and scans offset windows for the *new* locations of the awake/
; sleeping entity std::maps, the TerrainStruct and the local-player entity, so the
; correct offsets can be re-derived from the live game instead of guessed.
;
; Trigger: Config -> Debug -> "Probe AreaInstance" button (ahkCall
; 'AreaInstanceProbeRun'). Writes logs\InGameStateMonitor.areainstance_probe.log
; and shows a short summary MsgBox. Remove this module once PoE2Offsets is updated
; and verified in-game.

; Resolves the live areaInstanceData address, preferring the last radar snapshot
; (which already selects the active InGameState) and falling back to the index-4
; InGameState pointer chain. Returns the address or 0.
_AIP_ResolveAreaInstance()
{
    global g_reader, g_radarLastSnap
    if !(IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle)
        return 0

    if IsObject(g_radarLastSnap)
    {
        inGs := g_radarLastSnap.Has("inGameState") ? g_radarLastSnap["inGameState"] : 0
        area := (IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
        addr := (IsObject(area) && area.Has("address")) ? area["address"] : 0
        if (addr && g_reader.IsProbablyValidPointer(addr))
            return addr
    }

    try
    {
        if !g_reader.IsProbablyValidPointer(g_reader.GameStatesAddress)
            return 0
        staticPtr := g_reader.Mem.ReadPtr(g_reader.GameStatesAddress)
        if !g_reader.IsProbablyValidPointer(staticPtr)
            return 0
        igs := g_reader.Mem.ReadPtr(staticPtr + PoE2Offsets.GameState["States"]
            + (PoE2Offsets.GameState["InGameStateIndex"] * PoE2Offsets.GameState["StateEntrySize"]))
        if !g_reader.IsProbablyValidPointer(igs)
            return 0
        area := g_reader.Mem.ReadPtr(igs + PoE2Offsets.InGameState["AreaInstanceData"])
        return g_reader.IsProbablyValidPointer(area) ? area : 0
    }
    catch
        return 0
}

; Tests whether base+off carries a populated std::map header (head valid, size in
; [1..200000], root = ReadPtr(head+Parent) valid and != head). Outputs size/head/root.
; Returns true on a match.
_AIP_LooksLikeMap(base, off, &size, &head, &root)
{
    global g_reader
    head := g_reader.Mem.ReadPtr(base + off + PoE2Offsets.StdMap["Head"])
    size := g_reader.Mem.ReadInt(base + off + PoE2Offsets.StdMap["Size"])
    root := 0
    if !g_reader.IsProbablyValidPointer(head)
        return false
    if (size < 1 || size > 200000)
        return false
    root := g_reader.Mem.ReadPtr(head + PoE2Offsets.StdMapNode["Parent"])
    return (g_reader.IsProbablyValidPointer(root) && root != head)
}

; Gold confirmation: reads the map root node's ValueEntityPtr and tests it as an
; entity. Returns the entity pointer when the map really is the entity list, else 0.
_AIP_MapHasEntity(root)
{
    global g_reader
    try
    {
        val := g_reader.Mem.ReadPtr(root + PoE2Offsets.StdMapNode["ValueEntityPtr"])
        ent := g_reader.ResolveEntityPointer(val)
        return g_reader.IsPlausibleEntityPointer(ent) ? ent : 0
    }
    catch
        return 0
}

; Tests whether base+off looks like a TerrainStruct (plausible tile counts, valid
; TileDetails / walkable-grid vectors, sane BytesPerRow). Outputs the decoded fields.
; Returns true on a match.
_AIP_LooksLikeTerrain(base, off, &tx, &ty, &bpr, &tileDetails)
{
    global g_reader
    tm := PoE2Offsets.TerrainMetadata
    tx := g_reader.Mem.ReadInt64(base + off + tm["TotalTilesX"])
    ty := g_reader.Mem.ReadInt64(base + off + tm["TotalTilesY"])
    tileDetails := g_reader.Mem.ReadPtr(base + off + tm["TileDetailsPtr"])
    bpr := g_reader.Mem.ReadInt(base + off + tm["BytesPerRow"])
    gridFirst := g_reader.Mem.ReadPtr(base + off + tm["GridWalkableData"])
    gridLast := g_reader.Mem.ReadPtr(base + off + tm["GridWalkableData"] + 0x08)
    if (tx < 1 || tx > 50000 || ty < 1 || ty > 50000)
        return false
    if !g_reader.IsProbablyValidPointer(tileDetails)
        return false
    if !g_reader.IsProbablyValidPointer(gridFirst) || gridLast < gridFirst
        return false
    return (bpr >= 1 && bpr <= 100000)
}

; Formats a signed delta as "+0xNN" / "-0xNN".
_AIP_Delta(now, old)
{
    d := now - old
    return (d < 0 ? "-0x" Format("{:X}", -d) : "+0x" Format("{:X}", d))
}

; Main probe: anchors on areaInstanceData, scans for the new entity-map / terrain /
; local-player offsets, writes a full report to the log and shows a short summary.
; No parameters; no return value (UI feedback via MsgBox + log file).
AreaInstanceProbeRun()
{
    global g_reader
    base := _AIP_ResolveAreaInstance()
    if !base
    {
        try MsgBox("AreaInstance probe: not connected or not in-game (no areaInstanceData resolved).", "AreaInstance Probe", "Iconx")
        return
    }

    oldEnt  := PoE2Offsets.AreaInstance["AwakeEntities"]      ; 0x6C0
    oldTerr := PoE2Offsets.AreaInstance["TerrainMetadata"]    ; 0x8A0
    piOff   := PoE2Offsets.AreaInstance["PlayerInfo"]         ; 0x580
    oldLp   := PoE2Offsets.LocalPlayerStruct["LocalPlayerPtr"] ; 0x20
    nl := "`r`n"

    sdRaw := g_reader.Mem.ReadPtr(base + piOff + PoE2Offsets.LocalPlayerStruct["ServerDataPtr"])
    areaHash := g_reader.Mem.ReadUInt(base + PoE2Offsets.AreaInstance["CurrentAreaHash"])

    rpt := "=== AreaInstance Probe ===" nl
    rpt .= "areaInstanceData = 0x" Format("{:X}", base) nl
    rpt .= "anchor ServerDataPtr(@PlayerInfo+0x0 = 0x" Format("{:X}", piOff) ") = 0x" Format("{:X}", sdRaw)
        . "  valid=" (g_reader.IsProbablyValidPointer(sdRaw) ? "YES" : "NO") nl
    rpt .= "sanity CurrentAreaHash(@0x" Format("{:X}", PoE2Offsets.AreaInstance["CurrentAreaHash"]) ") = 0x" Format("{:X}", areaHash) nl
    rpt .= "OLD offsets: AwakeEntities=0x" Format("{:X}", oldEnt) "  Terrain=0x" Format("{:X}", oldTerr)
        . "  LocalPlayer=PlayerInfo+0x" Format("{:X}", oldLp) nl nl

    ; ── Entity std::map scan (AwakeEntities at O, SleepingEntities at O+0x10) ──
    rpt .= "-- Entity map candidates (offset : size : head : root : sleepOk : ENTITY? : delta) --" nl
    bestEnt := "", bestEntOff := 0
    off := 0x600
    while (off <= 0x900)
    {
        size := 0, head := 0, root := 0
        if _AIP_LooksLikeMap(base, off, &size, &head, &root)
        {
            s2 := 0, h2 := 0, r2 := 0
            sleepOk := _AIP_LooksLikeMap(base, off + 0x10, &s2, &h2, &r2)
                || g_reader.IsProbablyValidPointer(g_reader.Mem.ReadPtr(base + off + 0x10))
            entPtr := _AIP_MapHasEntity(root)
            rpt .= "  0x" Format("{:X}", off) "  size=" size "  head=0x" Format("{:X}", head)
                . "  root=0x" Format("{:X}", root) "  sleep=" (sleepOk ? "y" : "n")
                . "  entity=" (entPtr ? "0x" Format("{:X}", entPtr) : "-")
                . "  (" _AIP_Delta(off, oldEnt) ")" nl
            if (entPtr && sleepOk && bestEnt = "")
            {
                bestEnt := "0x" Format("{:X}", off) " (" _AIP_Delta(off, oldEnt) ")"
                bestEntOff := off
            }
        }
        off += 0x08
    }
    rpt .= nl

    ; ── Terrain scan ──
    rpt .= "-- Terrain candidates (offset : tilesX : tilesY : tileDetailsPtr : bytesPerRow : delta) --" nl
    bestTerr := ""
    off := 0x800
    while (off <= 0xB80)
    {
        tx := 0, ty := 0, bpr := 0, td := 0
        if _AIP_LooksLikeTerrain(base, off, &tx, &ty, &bpr, &td)
        {
            rpt .= "  0x" Format("{:X}", off) "  X=" tx "  Y=" ty "  tiles=0x" Format("{:X}", td)
                . "  bpr=" bpr "  (" _AIP_Delta(off, oldTerr) ")" nl
            if (bestTerr = "")
                bestTerr := "0x" Format("{:X}", off) " (" _AIP_Delta(off, oldTerr) ")"
        }
        off += 0x08
    }
    rpt .= nl

    ; ── Local-player entity scan (relative to PlayerInfo) ──
    rpt .= "-- LocalPlayer candidates (PlayerInfo+off : raw : resolved : delta) --" nl
    bestLp := ""
    poff := 0x10
    while (poff <= 0x90)
    {
        raw := g_reader.Mem.ReadPtr(base + piOff + poff)
        resolved := g_reader.ResolveEntityPointer(raw)
        if g_reader.IsPlausibleEntityPointer(resolved)
        {
            rpt .= "  +0x" Format("{:X}", poff) "  raw=0x" Format("{:X}", raw)
                . "  resolved=0x" Format("{:X}", resolved) "  (" _AIP_Delta(poff, oldLp) ")" nl
            if (bestLp = "")
                bestLp := "PlayerInfo+0x" Format("{:X}", poff) " (" _AIP_Delta(poff, oldLp) ")"
        }
        poff += 0x08
    }
    rpt .= nl

    ; ── Raw qword window dump (for offline analysis if heuristics miss) ──
    rpt .= "-- Raw qword dump (offset : qword : i32lo) --" nl
    dumpStart := 0x500, dumpEnd := 0xB80
    buf := g_reader.Mem.ReadBytes(base + dumpStart, dumpEnd - dumpStart, true)
    if buf
    {
        i := 0
        cap := buf.Size - 8
        while (i <= cap)
        {
            q := NumGet(buf.Ptr, i, "Int64")
            i32 := NumGet(buf.Ptr, i, "Int")
            rpt .= "  0x" Format("{:X}", dumpStart + i) ": 0x" Format("{:016X}", q & 0xFFFFFFFFFFFFFFFF)
                . "  i32=" i32 nl
            i += 0x08
        }
    }
    else
        rpt .= "  (raw read failed)" nl

    path := A_ScriptDir "\logs\InGameStateMonitor.areainstance_probe.log"
    writeMsg := ""
    try
    {
        try DirCreate(A_ScriptDir "\logs")
        f := FileOpen(path, "w", "UTF-8")
        if f
        {
            f.Write(rpt)
            f.Close()
            writeMsg := "wrote " StrLen(rpt) " chars"
        }
        else
            writeMsg := "FileOpen failed"
    }
    catch as ex
        writeMsg := "exception: " (ex.HasOwnProp("Message") ? ex.Message : "?")
    try LogError("AreaInstanceProbe " writeMsg " -> " path)

    summary := "AreaInstance Probe done." nl nl
        . "areaInstanceData = 0x" Format("{:X}", base) nl
        . "anchor ServerDataPtr valid = " (g_reader.IsProbablyValidPointer(sdRaw) ? "YES" : "NO") nl nl
        . "Entity map (was 0x" Format("{:X}", oldEnt) "):  " (bestEnt != "" ? bestEnt : "none confirmed") nl
        . "Terrain    (was 0x" Format("{:X}", oldTerr) "):  " (bestTerr != "" ? bestTerr : "none") nl
        . "LocalPlayer(was +0x" Format("{:X}", oldLp) "):  " (bestLp != "" ? bestLp : "none") nl nl
        . "Full report (please send me this file):" nl . path
    try MsgBox(summary, "AreaInstance Probe", "Iconi")
}
