; PathfindingProbe.ahk
; TEMPORARY in-game diagnostic — NOT part of the per-frame hot path.
;
; Verifies the Pathfinding component offsets cross-referenced from
; Sikaka/POE2Radar (Poe2Offsets.cs) and added to PoE2Offsets.ahk:
;   * Pathfinding component — PoE2Offsets.Pathfinding (Flying 0xE5, BaseSpeed 0xEC)
;
; Dumps a PARSED interpretation (using our offsets) AND raw hex, so the real
; offsets can be confirmed / corrected against the live game. Remove this module
; once the offsets are verified and wired into the readers (or discarded).
;
; (The HoverTracker / MouseOver hover probes that used to live here were removed
; once the MouseOver entity chain — [[[inGameState+0x300]+0x3F0]+0xA8] — was
; verified and wired into EntityFocus / the DebugOverlay.)
;
; Reuses helpers from AreaInstanceProbe.ahk: _AIP_ResolveAreaInstance(),
; _AIP_WriteProbeLog().
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
