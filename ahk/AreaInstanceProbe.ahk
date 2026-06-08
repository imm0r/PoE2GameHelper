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

; Component-level probe (v2): confirms WHERE the breakage is downstream of the
; (verified-correct) AreaInstance offsets. Dumps the player's component lookup,
; decodes Life at our vs upstream offsets (plus a scan), enumerates entities via
; the real reader, and tests the entity validity byte at 0x84 vs 0x8C. No params,
; no return; writes a log + summary MsgBox. Trigger: ahkCall 'ComponentProbeRun'.
ComponentProbeRun()
{
    global g_reader
    base := _AIP_ResolveAreaInstance()
    if !base
    {
        try MsgBox("Component probe: not connected or not in-game.", "Component Probe", "Iconx")
        return
    }
    piOff := PoE2Offsets.AreaInstance["PlayerInfo"]
    lpRaw := g_reader.Mem.ReadPtr(base + piOff + PoE2Offsets.LocalPlayerStruct["LocalPlayerPtr"])
    localPlayer := g_reader.ResolveEntityPointer(lpRaw)
    nl := "`r`n"

    rpt := "=== Component Probe ===" nl
    rpt .= "areaInstanceData=0x" Format("{:X}", base) "  localPlayer=0x" Format("{:X}", localPlayer)
        . "  plausible=" (g_reader.IsPlausibleEntityPointer(localPlayer) ? "YES" : "NO") nl nl

    ; ── 1. Player component lookup (name -> address). Proves the lookup works. ──
    rpt .= "-- Player components (name : address) --" nl
    comps := ""
    try comps := g_reader.ReadEntityComponentLookupBasic(localPlayer, 96)
    lifeAddr := 0
    if (comps && Type(comps) = "Array")
    {
        for _, c in comps
        {
            if !(c && Type(c) = "Map" && c.Has("name") && c.Has("address"))
                continue
            rpt .= "  " c["name"] " : 0x" Format("{:X}", c["address"]) nl
            if (c["name"] = "Life")
                lifeAddr := c["address"]
        }
    }
    else
        rpt .= "  (component lookup returned nothing!)" nl
    rpt .= nl

    ; ── 2. Life: decode HP/Mana/ES at our vs upstream offsets, plus a window scan. ──
    if !lifeAddr
        try lifeAddr := g_reader.FindEntityComponentAddress(localPlayer, "Life")
    rpt .= "-- Life @0x" Format("{:X}", lifeAddr) " : Vital(current/max) per Health-offset --" nl
    lifeVerdict := "unknown"
    if lifeAddr
    {
        oursH := g_reader.ReadVitalStructSnapshot(lifeAddr, 0x1A8)
        oursM := g_reader.ReadVitalStructSnapshot(lifeAddr, 0x1F8)
        oursE := g_reader.ReadVitalStructSnapshot(lifeAddr, 0x230)
        upH   := g_reader.ReadVitalStructSnapshot(lifeAddr, 0x1B0)
        upM   := g_reader.ReadVitalStructSnapshot(lifeAddr, 0x208)
        upE   := g_reader.ReadVitalStructSnapshot(lifeAddr, 0x248)
        rpt .= "  ours(0x1A8/0x1F8/0x230):  HP " oursH["current"] "/" oursH["max"]
            . "   Mana " oursM["current"] "/" oursM["max"] "   ES " oursE["current"] "/" oursE["max"] nl
        rpt .= "  upstream(0x1B0/0x208/0x248):  HP " upH["current"] "/" upH["max"]
            . "   Mana " upM["current"] "/" upM["max"] "   ES " upE["current"] "/" upE["max"] nl
        oursOK := (oursH["max"] > 0 && oursH["max"] < 500000 && oursH["current"] <= oursH["max"] + 50000)
        upOK   := (upH["max"] > 0 && upH["max"] < 500000 && upH["current"] <= upH["max"] + 50000)
        lifeVerdict := oursOK ? "OURS 0x1A8" : (upOK ? "UPSTREAM 0x1B0" : "neither (see scan)")
        rpt .= "  [scan Health-offset 0x180..0x268 for plausible max>0]:" nl
        ho := 0x180
        while (ho <= 0x268)
        {
            v := g_reader.ReadVitalStructSnapshot(lifeAddr, ho)
            if (v["max"] > 0 && v["max"] < 500000 && v["current"] >= 0 && v["current"] <= v["max"] + 50000)
                rpt .= "    0x" Format("{:X}", ho) " -> " v["current"] "/" v["max"] nl
            ho += 0x08
        }
    }
    else
        rpt .= "  (Life component NOT in lookup — lookup or name match is the problem)" nl
    rpt .= nl

    ; ── 3. Entity enumeration via the REAL reader (same path the radar uses). ──
    awakeAddr := base + PoE2Offsets.AreaInstance["AwakeEntities"]
    rpt .= "-- ReadAreaEntityMapSummary(0x" Format("{:X}", awakeAddr) ") --" nl
    summary := ""
    try summary := g_reader.ReadAreaEntityMapSummary(awakeAddr, 16, 0)
    entSampleCount := -1
    if (summary && Type(summary) = "Map")
    {
        entSampleCount := summary.Has("sampleCount") ? summary["sampleCount"] : 0
        rpt .= "  size=" (summary.Has("size") ? summary["size"] : "?")
            . "  sampleCount=" entSampleCount
            . "  npc=" (summary.Has("npcCount") ? summary["npcCount"] : "?")
            . "  chest=" (summary.Has("chestCount") ? summary["chestCount"] : "?") nl
        if (summary.Has("sample") && Type(summary["sample"]) = "Array")
        {
            n := 0
            for _, en in summary["sample"]
            {
                if (n >= 8)
                    break
                if !(en && Type(en) = "Map")
                    continue
                ePtr := en.Has("entityPtr") ? en["entityPtr"] : (en.Has("entityRawPtr") ? en["entityRawPtr"] : 0)
                ent  := en.Has("entity") ? en["entity"] : 0
                path := (IsObject(ent) && ent.Has("path")) ? ent["path"] : "?"
                valid := (IsObject(ent) && ent.Has("isValid")) ? (ent["isValid"] ? "y" : "n") : "?"
                rpt .= "    ptr=0x" Format("{:X}", ePtr) " valid=" valid " path=" path nl
                n += 1
            }
        }
    }
    else
        rpt .= "  (reader returned nothing)" nl
    rpt .= nl

    ; ── 4. Validity byte: which of 0x84 / 0x8C is the IsValid flag? (valid = bit0 clear) ──
    b84 := g_reader.Mem.ReadUChar(localPlayer + 0x84)
    b8C := g_reader.Mem.ReadUChar(localPlayer + 0x8C)
    rpt .= "-- localPlayer validity byte: @0x84=0x" Format("{:X}", b84) " (bit0=" (b84 & 1) ")"
        . "   @0x8C=0x" Format("{:X}", b8C) " (bit0=" (b8C & 1) ")   [valid = bit0 clear] --" nl

    path := A_ScriptDir "\logs\InGameStateMonitor.component_probe.log"
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
    try LogError("ComponentProbe " writeMsg " -> " path)

    summaryBox := "Component Probe done." nl nl
        . "Life offset verdict: " lifeVerdict nl
        . "Entity sampleCount (real reader): " entSampleCount nl
        . "Validity bit0 — @0x84=" (b84 & 1) "  @0x8C=" (b8C & 1) " (valid=0)" nl nl
        . "Full report (please send me this file):" nl . path
    try MsgBox(summaryBox, "Component Probe", "Iconi")
}

; Resolves the live InGameState address (snapshot first, index-4 chain fallback).
_AIP_ResolveInGameState()
{
    global g_reader, g_radarLastSnap
    if !(IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle)
        return 0
    if IsObject(g_radarLastSnap)
    {
        inGs := g_radarLastSnap.Has("inGameState") ? g_radarLastSnap["inGameState"] : 0
        addr := (IsObject(inGs) && inGs.Has("address")) ? inGs["address"] : 0
        if (addr && g_reader.IsProbablyValidPointer(addr))
            return addr
    }
    try
    {
        if !g_reader.IsProbablyValidPointer(g_reader.GameStatesAddress)
            return 0
        staticPtr := g_reader.Mem.ReadPtr(g_reader.GameStatesAddress)
        igs := g_reader.Mem.ReadPtr(staticPtr + PoE2Offsets.GameState["States"]
            + (PoE2Offsets.GameState["InGameStateIndex"] * PoE2Offsets.GameState["StateEntrySize"]))
        return g_reader.IsProbablyValidPointer(igs) ? igs : 0
    }
    catch
        return 0
}

; Dumps a candidate map-UiElement: validity, ReadMapUiElementData (visible/size),
; raw Flags, and StringId read at BOTH 0xF8 (ours) and 0x140 (reference) so we can
; tell which StringId offset is correct. Returns a report line.
_AIP_MapElemLine(label, ptr)
{
    global g_reader
    if !g_reader.IsProbablyValidPointer(ptr)
        return "  " label " 0x" Format("{:X}", ptr) "  (invalid)`r`n"
    flags := g_reader.Mem.ReadUInt(ptr + PoE2Offsets.UiElementBase["Flags"])
    sid_F8 := "", sid_140 := ""
    try sid_F8  := g_reader.ReadStdWStringAt(ptr + 0xF8, 48)
    try sid_140 := g_reader.ReadStdWStringAt(ptr + 0x140, 48)
    vis := "?", sw := "?", sh := "?"
    try {
        d := g_reader.ReadMapUiElementData(ptr)
        if (d && IsObject(d))
        {
            vis := (d.Has("isVisible") && d["isVisible"]) ? "Y" : "N"
            sw := d.Has("sizeW") ? Round(d["sizeW"]) : "?"
            sh := d.Has("sizeH") ? Round(d["sizeH"]) : "?"
        }
    }
    return "  " label " 0x" Format("{:X}", ptr) "  flags=0x" Format("{:X}", flags)
        . " vis=" vis " size=" sw "x" sh
        . "  strId@0xF8='" sid_F8 "'  @0x140='" sid_140 "'`r`n"
}

; UI/Map chain probe: walks InGameState -> UiRoot -> GameUi -> MapParent -> Large/
; MiniMap (cache + child-walk) so we can see exactly where LargeMap detection fails.
; Run with the in-game large map OPEN. No params; writes a log + summary MsgBox.
UiMapProbeRun()
{
    global g_reader
    inGs := _AIP_ResolveInGameState()
    if !inGs
    {
        try MsgBox("UI/Map probe: not in-game.", "UI/Map Probe", "Iconx")
        return
    }
    nl := "`r`n"
    M := PoE2Offsets
    uiRootStruct := g_reader.Mem.ReadPtr(inGs + M.InGameState["UiRootStructPtr"])
    uiRoot       := g_reader.Mem.ReadPtr(uiRootStruct + M.UiRootStruct["UiRootPtr"])
    gameUi       := g_reader.Mem.ReadPtr(uiRootStruct + M.UiRootStruct["GameUiPtr"])
    gameUiCtrl   := g_reader.Mem.ReadPtr(uiRootStruct + M.UiRootStruct["GameUiControllerPtr"])

    rpt := "=== UI/Map Probe (open the large map before running!) ===" nl
    rpt .= "inGameState=0x" Format("{:X}", inGs) nl
    rpt .= "uiRootStruct(@0x" Format("{:X}", M.InGameState["UiRootStructPtr"]) ")=0x" Format("{:X}", uiRootStruct)
        . " valid=" (g_reader.IsProbablyValidPointer(uiRootStruct) ? "y" : "N") nl
    rpt .= "uiRoot=0x" Format("{:X}", uiRoot) "  gameUi(@0xBE0)=0x" Format("{:X}", gameUi)
        . " valid=" (g_reader.IsProbablyValidPointer(gameUi) ? "y" : "N")
        . "  gameUiCtrl=0x" Format("{:X}", gameUiCtrl) nl nl

    ; Manager base = the UiRoot struct pointer itself (reference: GameUi.Address =
    ; uiManagerPtr = UiRootStructPtr), NOT the deref'd GameUiPtr.
    activeUi := g_reader.IsProbablyValidPointer(uiRootStruct) ? uiRootStruct : gameUiCtrl
    mapParent := g_reader.Mem.ReadPtr(activeUi + M.ImportantUiElements["MapParentPtr"])
    ctrlMapParent := g_reader.Mem.ReadPtr(activeUi + M.ImportantUiElements["ControllerModeMapParentPtr"])
    rpt .= "mapParentPtr(@0x" Format("{:X}", M.ImportantUiElements["MapParentPtr"]) ")=0x" Format("{:X}", mapParent)
        . " valid=" (g_reader.IsProbablyValidPointer(mapParent) ? "y" : "N")
        . "  ctrlMapParent(@0xAA8)=0x" Format("{:X}", ctrlMapParent) nl

    largeMapPtr := g_reader.Mem.ReadPtr(mapParent + M.MapParentStruct["LargeMapPtr"])
    miniMapPtr  := g_reader.Mem.ReadPtr(mapParent + M.MapParentStruct["MiniMapPtr"])
    childrenFirst := g_reader.Mem.ReadPtr(mapParent + M.UiElementBase["ChildrenFirst"])
    child0 := g_reader.Mem.ReadPtr(childrenFirst)
    child1 := g_reader.Mem.ReadPtr(childrenFirst + 0x08)
    rpt .= "  cache: largeMapPtr(@+0x28)=0x" Format("{:X}", largeMapPtr)
        . "  miniMapPtr(@+0x30)=0x" Format("{:X}", miniMapPtr) nl
    rpt .= "  childrenFirst(@+0x10)=0x" Format("{:X}", childrenFirst)
        . "  child0=0x" Format("{:X}", child0) "  child1=0x" Format("{:X}", child1) nl nl

    rpt .= "-- LargeMap candidates (flags / visible / size / StringId@0xF8 vs 0x140) --" nl
    rpt .= _AIP_MapElemLine("cache(0x28) ", largeMapPtr)
    rpt .= _AIP_MapElemLine("child0      ", child0)
    rpt .= nl "-- MiniMap candidates --" nl
    rpt .= _AIP_MapElemLine("cache(0x30) ", miniMapPtr)
    rpt .= _AIP_MapElemLine("child1      ", child1)

    path := A_ScriptDir "\logs\InGameStateMonitor.uimap_probe.log"
    wrote := ""
    try
    {
        try DirCreate(A_ScriptDir "\logs")
        f := FileOpen(path, "w", "UTF-8")
        if f
        {
            f.Write(rpt)
            f.Close()
            wrote := "ok"
        }
    }
    catch as ex
        wrote := "err:" (ex.HasOwnProp("Message") ? ex.Message : "?")
    try LogError("UiMapProbe " wrote " -> " path)

    box := "UI/Map Probe done (run with the large map OPEN)." nl nl
        . "gameUi valid: " (g_reader.IsProbablyValidPointer(gameUi) ? "y" : "N") nl
        . "mapParent valid: " (g_reader.IsProbablyValidPointer(mapParent) ? "y" : "N") nl
        . "largeMapPtr(cache 0x28) valid: " (g_reader.IsProbablyValidPointer(largeMapPtr) ? "y" : "N") nl
        . "child0 valid: " (g_reader.IsProbablyValidPointer(child0) ? "y" : "N") nl nl
        . "Send me:" nl . path
    try MsgBox(box, "UI/Map Probe", "Iconi")
}

; Chest open-flag probe: dumps the Chest component bytes (0x150..0x197) for nearby
; chest entities so the IsOpened offset can be pinned. Run once with a chest CLOSED,
; then OPEN that chest and run again; the byte that flips 0->1 for the same entity
; id is the real IsOpened flag. No params; writes a log + summary MsgBox.
ChestProbeRun()
{
    global g_reader
    base := _AIP_ResolveAreaInstance()
    if !base
    {
        try MsgBox("Chest probe: not in-game.", "Chest Probe", "Iconx")
        return
    }
    nl := "`r`n"
    summary := ""
    try summary := g_reader.ReadAreaEntityMapSummary(base + PoE2Offsets.AreaInstance["AwakeEntities"], 96, 0)

    rpt := "=== Chest Probe (run CLOSED, then open the chest and run again) ===" nl
    rpt .= "current IsOpened offset = 0x" Format("{:X}", PoE2Offsets.Chest["IsOpened"])
        . " (= byte index 0x18 of the 0x150 dump)" nl nl

    n := 0
    if (summary && Type(summary) = "Map" && summary.Has("sample") && Type(summary["sample"]) = "Array")
    {
        for _, en in summary["sample"]
        {
            if !(en && Type(en) = "Map")
                continue
            ent := en.Has("entity") ? en["entity"] : 0
            path := (IsObject(ent) && ent.Has("path")) ? ent["path"] : ""
            if !(InStr(path, "Chest") || InStr(path, "Boulder") || InStr(path, "Strongbox"))
                continue
            entPtr := en.Has("entityPtr") ? en["entityPtr"] : 0
            id := en.Has("id") ? en["id"] : 0
            chestAddr := 0
            try chestAddr := g_reader.FindEntityComponentAddress(entPtr, "Chest")
            rpt .= "#" id "  " path nl
            if chestAddr
            {
                rpt .= "  Chest@0x" Format("{:X}", chestAddr)
                    . "  isOpened@0x168=" g_reader.Mem.ReadUChar(chestAddr + 0x168) nl
                buf := g_reader.Mem.ReadBytes(chestAddr + 0x150, 0x48, true)
                if buf
                {
                    line := "  0x150: "
                    i := 0
                    while (i < buf.Size)
                    {
                        line .= Format("{:02X} ", NumGet(buf.Ptr, i, "UChar"))
                        i += 1
                        if (Mod(i, 16) = 0)
                        {
                            rpt .= RTrim(line) nl
                            line := "  0x" Format("{:X}", 0x150 + i) ": "
                        }
                    }
                    if (Trim(line) != "0x" Format("{:X}", 0x150 + i) ":")
                        rpt .= RTrim(line) nl
                }
            }
            else
                rpt .= "  (no Chest component)" nl
            rpt .= nl
            n += 1
            if (n >= 10)
                break
        }
    }
    if (n = 0)
        rpt .= "(no chest entities in the awake sample — stand closer to chests)" nl

    path := A_ScriptDir "\logs\InGameStateMonitor.chest_probe.log"
    try
    {
        try DirCreate(A_ScriptDir "\logs")
        f := FileOpen(path, "w", "UTF-8")
        if f
        {
            f.Write(rpt)
            f.Close()
        }
    }
    try LogError("ChestProbe " n " chests -> " path)
    try MsgBox("Chest probe done (" n " chest(s) dumped)." nl nl
        . "Run once with a chest CLOSED, then OPEN that chest and run again." nl
        . "Send me both logs:" nl . path, "Chest Probe", "Iconi")
}

; Targetable byte probe: dumps the Targetable component bytes (0x40..0x67) for
; nearby targetable entities (monsters/strongboxes/monoliths). A live monster's
; IsTargetable should read 1 somewhere; if it's not at 0x51, the offset shifted in
; the patch. Hover/target an entity before running. Writes a log + summary MsgBox.
TargetableProbeRun()
{
    global g_reader
    base := _AIP_ResolveAreaInstance()
    if !base
    {
        try MsgBox("Targetable probe: not in-game.", "Targetable Probe", "Iconx")
        return
    }
    nl := "`r`n"
    summary := ""
    try summary := g_reader.ReadAreaEntityMapSummary(base + PoE2Offsets.AreaInstance["AwakeEntities"], 96, 0)

    DUMP := 0xC0
    openedBufs := []
    closedBufs := []
    openedInfo := []
    closedInfo := []
    if (summary && Type(summary) = "Map" && summary.Has("sample") && Type(summary["sample"]) = "Array")
    {
        for _, en in summary["sample"]
        {
            if !(en && Type(en) = "Map")
                continue
            ent := en.Has("entity") ? en["entity"] : 0
            path := (IsObject(ent) && ent.Has("path")) ? ent["path"] : "?"
            pl := StrLower(path)
            if !((InStr(pl, "/chests/") || InStr(pl, "strongbox")) && !InStr(pl, "interactionobject"))
                continue
            entPtr := en.Has("entityPtr") ? en["entityPtr"] : 0
            id := en.Has("id") ? en["id"] : 0
            tgtAddr := 0
            chestAddr := 0
            try tgtAddr := g_reader.FindEntityComponentAddress(entPtr, "Targetable")
            try chestAddr := g_reader.FindEntityComponentAddress(entPtr, "Chest")
            if (!tgtAddr || !chestAddr)
                continue
            isOpened := g_reader.Mem.ReadUChar(chestAddr + PoE2Offsets.Chest["IsOpened"])
            buf := g_reader.Mem.ReadBytes(tgtAddr, DUMP, true)
            if !buf
                continue
            if (isOpened = 1)
            {
                openedBufs.Push(buf)
                openedInfo.Push("#" id " " path)
            }
            else if (isOpened = 0)
            {
                closedBufs.Push(buf)
                closedInfo.Push("#" id " " path)
            }
        }
    }

    rpt := "=== Targetable Diff Probe (chest CLOSED vs OPENED) ===" nl
    rpt .= "closed chests: " closedBufs.Length "   opened chests: " openedBufs.Length nl nl

    if (closedBufs.Length >= 1 && openedBufs.Length >= 1)
    {
        rpt .= "-- offsets where CLOSED != OPENED (IsTargetable/IsHighlightable candidates) --" nl
        off := 0
        while (off < DUMP)
        {
            cVal := _AIP_ConsistentByte(closedBufs, off)
            oVal := _AIP_ConsistentByte(openedBufs, off)
            if (cVal >= 0 && oVal >= 0 && cVal != oVal)
                rpt .= "  0x" Format("{:X}", off) ":  closed=" cVal "  opened=" oVal nl
            off += 1
        }
        rpt .= nl
    }
    else
        rpt .= "(need >=1 CLOSED and >=1 OPENED chest nearby — stand near a mix)" nl nl

    if (closedBufs.Length >= 1)
        rpt .= "-- sample CLOSED " closedInfo[1] " --" nl . _AIP_HexDump(closedBufs[1], DUMP)
    if (openedBufs.Length >= 1)
        rpt .= "-- sample OPENED " openedInfo[1] " --" nl . _AIP_HexDump(openedBufs[1], DUMP)

    path := A_ScriptDir "\logs\InGameStateMonitor.targetable_probe.log"
    try
    {
        try DirCreate(A_ScriptDir "\logs")
        f := FileOpen(path, "w", "UTF-8")
        if f
        {
            f.Write(rpt)
            f.Close()
        }
    }
    try LogError("TargetableDiffProbe closed=" closedBufs.Length " opened=" openedBufs.Length " -> " path)
    try MsgBox("Targetable diff probe done." nl nl
        . "closed chests: " closedBufs.Length "   opened chests: " openedBufs.Length nl
        . "(need >=1 of each — stand near a mix of opened & unopened chests)" nl nl
        . "Send me:" nl . path, "Targetable Probe", "Iconi")
}

; Returns the byte at `off` if identical across every buffer in `bufs`, else -1.
_AIP_ConsistentByte(bufs, off)
{
    if (bufs.Length = 0)
        return -1
    val := -1
    for _, b in bufs
    {
        if (off >= b.Size)
            return -1
        v := NumGet(b.Ptr, off, "UChar")
        if (val = -1)
            val := v
        else if (v != val)
            return -1
    }
    return val
}

; Hex-dumps a Buffer (16 bytes/line with offset labels); returns the text.
_AIP_HexDump(buf, len)
{
    out := ""
    line := ""
    i := 0
    cap := Min(len, buf.Size)
    while (i < cap)
    {
        if (Mod(i, 16) = 0)
            line := "  0x" Format("{:02X}", i) ": "
        line .= Format("{:02X} ", NumGet(buf.Ptr, i, "UChar"))
        i += 1
        if (Mod(i, 16) = 0)
        {
            out .= RTrim(line) "`r`n"
            line := ""
        }
    }
    if (line != "")
        out .= RTrim(line) "`r`n"
    return out
}

; IsTargetedByPlayer hover-diff: captures each sampled monster's Targetable flag
; bytes (component +0x60..+0x80) and diffs against the previous run (stored in
; g_aipTgtPrev). Hovering/targeting one monster between two runs reveals which byte
; flips 0->1 — that byte is IsTargetedByPlayer. Run once with NO hover, then hover
; a monster and run again.
TargetedByPlayerProbeRun()
{
    global g_reader, g_radarLastSnap, g_aipTgtPrev
    if !IsSet(g_aipTgtPrev)
        g_aipTgtPrev := Map()
    if !(IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle)
    {
        try MsgBox("IsTargetedByPlayer probe: not connected.", "TgtByPlayer Probe", "Iconx")
        return
    }
    nl := "`r`n"
    ; Use the persistent radar cache (stable across frames) so the SAME monsters are
    ; present in both runs — a fresh BFS re-samples a different subset each call.
    sample := 0
    try
    {
        inGs := (IsObject(g_radarLastSnap) && g_radarLastSnap.Has("inGameState")) ? g_radarLastSnap["inGameState"] : 0
        area := (IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
        awake := (IsObject(area) && area.Has("awakeEntities")) ? area["awakeEntities"] : 0
        sample := (IsObject(awake) && awake.Has("sample")) ? awake["sample"] : 0
    }
    if !IsObject(sample)
    {
        try MsgBox("No radar snapshot yet — let the radar run a moment, then retry.", "TgtByPlayer Probe", "Iconx")
        return
    }

    LEN := 0x100
    cur := Map()
    for _, en in sample
    {
        if !(IsObject(en) && en.Has("entity"))
            continue
        ent := en["entity"]
        path := (IsObject(ent) && ent.Has("path")) ? ent["path"] : ""
        if !InStr(StrLower(path), "monster")
            continue
        entPtr := en.Has("entityPtr") ? en["entityPtr"] : (en.Has("entityRawPtr") ? en["entityRawPtr"] : 0)
        id := en.Has("id") ? en["id"] : 0
        if (!entPtr || !id)
            continue
        tgt := 0
        try tgt := g_reader.FindEntityComponentAddress(entPtr, "Targetable")
        if !tgt
            continue
        buf := g_reader.Mem.ReadBytes(tgt, LEN, true)
        if buf
            cur[id] := Map("path", path, "buf", buf)
    }

    curCount := cur.Count
    prevCount := g_aipTgtPrev.Count
    rpt := "=== IsTargetedByPlayer diff (run 1 = no target, run 2 = while ATTACKING one monster) ===" nl
    rpt .= "captured monsters: " curCount "   previous: " prevCount nl nl

    if (prevCount > 0)
    {
        rpt .= "-- byte changes vs previous run (full Targetable component 0x00..0x100) --" nl
        changes := 0
        for id, c in cur
        {
            if !g_aipTgtPrev.Has(id)
                continue
            pb := g_aipTgtPrev[id]["buf"]
            cb := c["buf"]
            line := ""
            k := 0
            while (k < LEN && k < pb.Size && k < cb.Size)
            {
                pv := NumGet(pb.Ptr, k, "UChar")
                cv := NumGet(cb.Ptr, k, "UChar")
                if (pv != cv)
                    line .= "0x" Format("{:X}", k) ":" pv "->" cv "  "
                k += 1
            }
            if (line != "")
            {
                rpt .= "  #" id " " c["path"] ":  " line nl
                changes += 1
            }
        }
        if (changes = 0)
            rpt .= "  (no byte changed in any monster's Targetable component between the two runs)" nl
    }
    else
        rpt .= "(first run stored — now ATTACK/target ONE monster and run again)" nl

    g_aipTgtPrev := cur

    path := A_ScriptDir "\logs\InGameStateMonitor.targetedbyplayer_probe.log"
    try
    {
        try DirCreate(A_ScriptDir "\logs")
        f := FileOpen(path, "w", "UTF-8")
        if f
        {
            f.Write(rpt)
            f.Close()
        }
    }
    try LogError("TgtByPlayerProbe cur=" curCount " prev=" prevCount " -> " path)
    try MsgBox("IsTargetedByPlayer diff." nl nl
        . "Run 1: do NOT target anything. Then ATTACK/target ONE monster and press Ctrl+B again." nl
        . "captured=" curCount "  previous=" prevCount nl nl
        . "Send me the log after the 2nd run:" nl . path, "TgtByPlayer Probe", "Iconi")
}

; Registers the temporary in-game probe hotkeys (Ctrl+Alt+Shift+T = chest CLOSED/
; OPENED diff, Ctrl+B = IsTargetedByPlayer hover diff) so they fire in-game
; without the UI button dropping the hover/target. Called once at startup.
_AIP_RegisterProbeHotkeys()
{
    try Hotkey("^!+t", (*) => TargetableProbeRun(), "On")
    try Hotkey("^b", (*) => TargetedByPlayerProbeRun(), "On")
}
