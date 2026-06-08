; HoverPathfindingProbe.ahk
; TEMPORARY in-game diagnostics — NOT part of the per-frame hot path.
;
; Two probes to VERIFY the hypothesis offsets cross-referenced from
; Sikaka/POE2Radar (Poe2Offsets.cs) and added to PoE2Offsets.ahk:
;
;   * Pathfinding component  — PoE2Offsets.Pathfinding (Flying 0xE5, BaseSpeed 0xEC)
;   * HoverTracker chain     — PoE2Offsets.HoverTracker (FromUiRoot 0x7D8,
;                              WorldTracker 0x630, HoveredEntity 0x18)
;
; Both dump a PARSED interpretation (using our offsets) AND raw hex of the key
; regions, so the real offsets can be confirmed / corrected against the live
; game. Remove this module once the offsets are verified and wired into the
; readers (or discarded).
;
; Reuses helpers from AreaInstanceProbe.ahk: _AIP_ResolveAreaInstance(),
; _AIP_ResolveInGameState(), _AIP_WriteProbeLog().
;
; Included by InGameStateMonitor.ahk

; Formats <size> bytes read from <addr> as an offset-annotated hex dump (16/row),
; labelling each row with (startLabel + row offset) so the printed offsets match
; the struct-relative offsets the reader cares about. Returns the text (or a note).
_HPP_HexDump(reader, addr, size, startLabel := 0)
{
    b := reader.Mem.ReadBytes(addr, size, true)
    if !b
        return "  <read failed @0x" Format("{:X}", addr) ">`r`n"
    out := ""
    i := 0
    cap := Min(size, b.Size)
    while (i < cap)
    {
        line := "  +0x" Format("{:03X}:", startLabel + i)
        j := 0
        while (j < 16 && (i + j) < cap)
        {
            line .= " " Format("{:02X}", NumGet(b.Ptr, i + j, "UChar"))
            j += 1
        }
        out .= line "`r`n"
        i += 16
    }
    return out
}

; Pathfinding probe: enumerate awake monster entities, resolve their Pathfinding
; component and dump the candidate Flying (0xE5, byte) / BaseSpeed (0xEC) fields,
; plus a raw hex window for the first few so the offsets can be confirmed/fixed.
; No hover needed — trigger from Config -> Debug. Writes a probe log.
PathfindingProbeRun()
{
    global g_reader
    base := _AIP_ResolveAreaInstance()
    if !base
    {
        try MsgBox("Pathfinding probe: not in-game.", "Pathfinding Probe", "Iconx")
        return
    }
    nl := "`r`n"
    rpt := "=== Pathfinding Probe (Flying 0xE5 / BaseSpeed 0xEC) ===" nl
    rpt .= "HYPOTHESIS offsets from Sikaka/POE2Radar — VERIFY the values below look sane." nl nl

    summary := 0
    try summary := g_reader.ReadAreaEntityMapSummary(base + PoE2Offsets.AreaInstance["AwakeEntities"], 256, 0)
    if !(summary && Type(summary) = "Map" && summary.Has("sample") && Type(summary["sample"]) = "Array")
    {
        rpt .= "(no awake-entity sample — stand in a populated area and retry)" nl
        _AIP_WriteProbeLog("pathfinding_probe", rpt)
        return
    }

    flyOff := PoE2Offsets.Pathfinding["Flying"]
    spdOff := PoE2Offsets.Pathfinding["BaseSpeed"]
    parsed := 0
    rawDumped := 0
    rpt .= "monsters with a Pathfinding component:" nl
    rpt .= "  entity              id        Flying@0xE5  BaseSpeed@0xEC (int / float)" nl
    for _, en in summary["sample"]
    {
        if !(en && Type(en) = "Map")
            continue
        ent := en.Has("entity") ? en["entity"] : 0
        path := (IsObject(ent) && ent.Has("path")) ? ent["path"] : ""
        if !InStr(StrLower(path), "/monsters/")
            continue
        entPtr := en.Has("entityPtr") ? en["entityPtr"] : 0
        id := en.Has("id") ? en["id"] : 0
        pfAddr := 0
        try pfAddr := g_reader.FindEntityComponentAddress(entPtr, "Pathfinding", ["PathfindingComponent", "Pathfind"])
        if !(pfAddr && g_reader.IsProbablyValidPointer(pfAddr))
            continue

        flying := g_reader.Mem.ReadUChar(pfAddr + flyOff)
        spdInt := g_reader.Mem.ReadInt(pfAddr + spdOff)
        spdFlt := g_reader.Mem.ReadFloat(pfAddr + spdOff)
        parsed += 1
        rpt .= Format("  0x{:X}  {:>9}  {:>7}      {} / {}", pfAddr, id, flying, spdInt, Round(spdFlt, 3))
            . "   " path nl

        ; Raw hex for the first few so the real field offsets can be located.
        if (rawDumped < 3)
        {
            rawDumped += 1
            rpt .= nl . "  -- RAW Pathfinding @0x" Format("{:X}", pfAddr)
                . " (+0xC0..+0x110) --" nl
            rpt .= _HPP_HexDump(g_reader, pfAddr + 0xC0, 0x50, 0xC0)
            rpt .= nl
        }
        if (parsed >= 25)
            break
    }
    if (parsed = 0)
        rpt .= "  (none found — no awake monster exposed a Pathfinding component)" nl
    rpt .= nl . "parsed " parsed " monster(s)." nl
    _AIP_WriteProbeLog("pathfinding_probe", rpt)
}

; HoverTracker probe: walk the hypothesised chain UiRoot -> FromUiRoot(0x7D8) ->
; WorldTracker(0x630) -> HoveredEntity(0x18) and report the resolved entity, plus
; raw hex of each struct region so a wrong link can be spotted/corrected. Because
; clicking a UI button drops the hover, this is best run via its hotkey
; (Ctrl+Alt+H) WHILE hovering a monster/chest. Writes a probe log.
HoverTrackerProbeRun()
{
    global g_reader
    inGs := _AIP_ResolveInGameState()
    if !inGs
    {
        try MsgBox("HoverTracker probe: not in-game.", "HoverTracker Probe", "Iconx")
        return
    }
    nl := "`r`n"
    H := PoE2Offsets.HoverTracker
    rpt := "=== HoverTracker Probe (resolve hovered entity) ===" nl
    rpt .= "HYPOTHESIS chain from Sikaka/POE2Radar — hover a monster/chest, then run." nl
    rpt .= "inGameState: 0x" Format("{:X}", inGs) nl

    uiRoot := g_reader.Mem.ReadPtr(inGs + PoE2Offsets.InGameState["UiRootStructPtr"])
    rpt .= "uiRoot (ReadPtr(inGs+0x" Format("{:X}", PoE2Offsets.InGameState["UiRootStructPtr"]) "))"
        . " = 0x" Format("{:X}", uiRoot) (g_reader.IsProbablyValidPointer(uiRoot) ? "" : "  (invalid)") nl
    if !g_reader.IsProbablyValidPointer(uiRoot)
    {
        _AIP_WriteProbeLog("hovertracker_probe", rpt)
        return
    }

    tracker := g_reader.Mem.ReadPtr(uiRoot + H["FromUiRoot"])
    rpt .= "tracker (ReadPtr(uiRoot+0x" Format("{:X}", H["FromUiRoot"]) "))"
        . " = 0x" Format("{:X}", tracker) (g_reader.IsProbablyValidPointer(tracker) ? "" : "  (invalid)") nl

    worldTracker := g_reader.IsProbablyValidPointer(tracker)
        ? g_reader.Mem.ReadPtr(tracker + H["WorldTracker"]) : 0
    rpt .= "worldTracker (ReadPtr(tracker+0x" Format("{:X}", H["WorldTracker"]) "))"
        . " = 0x" Format("{:X}", worldTracker) (g_reader.IsProbablyValidPointer(worldTracker) ? "" : "  (invalid)") nl

    hovered := g_reader.IsProbablyValidPointer(worldTracker)
        ? g_reader.Mem.ReadPtr(worldTracker + H["HoveredEntity"]) : 0
    rpt .= "hoveredEntity (ReadPtr(worldTracker+0x" Format("{:X}", H["HoveredEntity"]) "))"
        . " = 0x" Format("{:X}", hovered) nl nl

    ; Try to interpret the resolved pointer as an entity and read its path.
    if (hovered && g_reader.IsPlausibleEntityPointer(hovered))
    {
        path := "?"
        try {
            ent := g_reader.ReadEntityBasic(hovered)
            if (IsObject(ent) && ent.Has("path"))
                path := ent["path"]
        }
        eid := g_reader.Mem.ReadUInt(hovered + PoE2Offsets.Entity["Id"])
        rpt .= ">> hovered entity LOOKS VALID: id=" eid "  path=" path nl
        rpt .= "   (compare with what you were hovering — match = chain confirmed)" nl nl
    }
    else
    {
        rpt .= ">> resolved pointer is NOT a plausible entity — the chain/offsets need fixing." nl
        rpt .= "   Use the raw hex below to find the real links (look for an entity-like ptr:" nl
        rpt .= "   one whose +0x" Format("{:X}", PoE2Offsets.Entity["Id"]) " reads a small id < 0x40000000)." nl nl
    }

    ; Raw hex of each region so a mis-stepped link can be corrected.
    rpt .= "-- RAW uiRoot +0x7C0..+0x800 (locate FromUiRoot link) --" nl
    rpt .= _HPP_HexDump(g_reader, uiRoot + 0x7C0, 0x40, 0x7C0)
    if g_reader.IsProbablyValidPointer(tracker)
    {
        rpt .= nl . "-- RAW tracker +0x620..+0x660 (locate WorldTracker link) --" nl
        rpt .= _HPP_HexDump(g_reader, tracker + 0x620, 0x40, 0x620)
    }
    if g_reader.IsProbablyValidPointer(worldTracker)
    {
        rpt .= nl . "-- RAW worldTracker +0x00..+0x40 (locate HoveredEntity link) --" nl
        rpt .= _HPP_HexDump(g_reader, worldTracker, 0x40, 0x00)
    }
    _AIP_WriteProbeLog("hovertracker_probe", rpt)
}
