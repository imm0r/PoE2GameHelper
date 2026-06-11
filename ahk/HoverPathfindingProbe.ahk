; HoverPathfindingProbe.ahk
; TEMPORARY in-game diagnostics — NOT part of the per-frame hot path.
;
; Two probes to VERIFY the hypothesis offsets cross-referenced from
; Sikaka/POE2Radar (Poe2Offsets.cs) and added to PoE2Offsets.ahk:
;
;   * Pathfinding component  — PoE2Offsets.Pathfinding (Flying 0xE5, BaseSpeed 0xEC)
;   * HoverTracker           — resolve the entity currently under the cursor
;
; Both dump a PARSED interpretation (using our offsets) AND raw hex / scan data,
; so the real offsets can be confirmed / corrected against the live game. Remove
; this module once the offsets are verified and wired into the readers (or
; discarded).
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

; Scans base from startOff up to endOff in qword steps for entity-like pointers, adds
; each hit to <out>, keyed "<tag>+0xNNN". A slot counts when it IS a plausible
; Entity* (mode "direct") or points to one (mode "indirect"). Reads id + path per
; hit. IsPlausibleEntityPointer checks the component vector, details ptr and id
; range, so false positives are rare. Params: reader, base, offsets, tag, out Map.
_HPP_ScanEntityPtrs(reader, base, startOff, endOff, tag, out)
{
    off := startOff
    while (off + 8 <= endOff)
    {
        q := reader.Mem.ReadPtr(base + off)
        entPtr := 0
        mode := ""
        if (reader.IsProbablyValidPointer(q) && reader.IsPlausibleEntityPointer(q))
        {
            entPtr := q
            mode := "direct"
        }
        else if reader.IsProbablyValidPointer(q)
        {
            d := reader.Mem.ReadPtr(q)
            if (reader.IsProbablyValidPointer(d) && reader.IsPlausibleEntityPointer(d))
            {
                entPtr := d
                mode := "indirect"
            }
        }
        if (entPtr)
        {
            id := _HPP_ReadEntityId(reader, entPtr)
            path := "?"
            try {
                e := reader.ReadEntityBasic(entPtr)
                if (IsObject(e) && e.Has("path"))
                    path := e["path"]
            }
            out[tag "+0x" Format("{:X}", off)] := Map("ptr", q, "entPtr", entPtr,
                "id", id, "path", path, "mode", mode)
        }
        off += 8
    }
}

; Small helper: reads an entity's id (Entity.Id offset). Kept separate so the
; scan loop stays readable. Returns the uint id (or 0 on failure).
_HPP_ReadEntityId(reader, entPtr)
{
    try return reader.Mem.ReadUInt(entPtr + PoE2Offsets.Entity["Id"])
    return 0
}

; HoverTracker probe (entity-ptr scan + DIFF). The fixed Sikaka chain does not fit
; our build (tracker+0x630 hit a vtable, not a heap struct), so instead of trusting
; offsets we SCAN the hover-tracker / UI-root structs for slots that hold a
; plausible Entity* (direct) or point to one (indirect), and DIFF two runs to
; isolate the slot that only carries a valid entity while hovering.
;
; Usage (best via the Ctrl+Alt+H hotkey so the click does not drop the hover):
;   1. Hover NOTHING (cursor over empty ground), press Ctrl+Alt+H.
;   2. Hover a monster/chest, press Ctrl+Alt+H again.
; The slot listed under "NEW/CHANGED" is the hovered-entity pointer. Writes a log.
HoverTrackerProbeRun()
{
    global g_reader, g_hoverScanPrev
    if !IsSet(g_hoverScanPrev)
        g_hoverScanPrev := Map()
    inGs := _AIP_ResolveInGameState()
    if !inGs
    {
        try MsgBox("HoverTracker probe: not in-game.", "HoverTracker Probe", "Iconx")
        return
    }
    nl := "`r`n"
    uiRoot := g_reader.Mem.ReadPtr(inGs + PoE2Offsets.InGameState["UiRootStructPtr"])
    tracker := g_reader.IsProbablyValidPointer(uiRoot)
        ? g_reader.Mem.ReadPtr(uiRoot + PoE2Offsets.HoverTracker["FromUiRoot"]) : 0

    rpt := "=== HoverTracker Probe (entity-ptr scan + diff) ===" nl
    rpt .= "Run 1: hover NOTHING.  Run 2: hover a monster/chest, then Ctrl+Alt+H again." nl
    rpt .= "inGameState=0x" Format("{:X}", inGs) "  uiRoot=0x" Format("{:X}", uiRoot)
        . "  tracker(uiRoot+0x" Format("{:X}", PoE2Offsets.HoverTracker["FromUiRoot"]) ")=0x"
        . Format("{:X}", tracker) nl

    ; Confirmed resolve: WorldTracker is embedded, so the hovered entity sits at
    ; tracker + 0x648 (= WorldTracker 0x630 + HoveredEntity 0x18).
    hov := g_reader.IsProbablyValidPointer(tracker)
        ? g_reader.Mem.ReadPtr(tracker + PoE2Offsets.HoverTracker["HoveredEntityFromTracker"]) : 0
    if (hov && g_reader.IsPlausibleEntityPointer(hov))
    {
        hp := "?"
        try {
            he := g_reader.ReadEntityBasic(hov)
            if (IsObject(he) && he.Has("path"))
                hp := he["path"]
        }
        rpt .= "HOVERED world-object (tracker+0x648) = 0x" Format("{:X}", hov)
            . "  id=" _HPP_ReadEntityId(g_reader, hov) "  " hp nl
        rpt .= "(world objects only: chests/ground-items/shrines. Monsters are NOT"
            . " tracked here — use Targetable.IsTargetedByPlayer 0x6B for those.)" nl nl
    }
    else
        rpt .= "HOVERED world-object (tracker+0x648) = none"
            . " (hover a chest/ground item; monsters do not populate this slot)" nl nl

    ; Scan two candidate regions for entity-like pointers. Keys are "<tag>+0xNNN":
    ; T = the hover-tracker struct (uiRoot+FromUiRoot), U = the UI-root struct.
    ; The world-object slot sits at tracker+0x648; the cursor-hovered MONSTER is a
    ; separate slot we have not pinned yet, so scan the WHOLE tracker struct (well
    ; past 0x648) and the full UI-root struct rather than the narrow original windows.
    cur := Map()
    if g_reader.IsProbablyValidPointer(tracker)
        _HPP_ScanEntityPtrs(g_reader, tracker, 0x000, 0x1800, "T", cur)
    if g_reader.IsProbablyValidPointer(uiRoot)
        _HPP_ScanEntityPtrs(g_reader, uiRoot, 0x000, 0x1800, "U", cur)

    rpt .= "entity-like slots found this run: " cur.Count nl
    for key, h in cur
        rpt .= Format("  {} {} ptr=0x{:X}  ent=0x{:X}  id={}  {}",
            key, h["mode"], h["ptr"], h["entPtr"], h["id"], h["path"]) nl

    ; Diff vs the previous run — the slot whose entity id appeared or changed
    ; between "no hover" and "hover" is the hovered-entity pointer.
    prevCount := g_hoverScanPrev.Count
    rpt .= nl . "previous run slots: " prevCount nl
    if (prevCount = 0 && cur.Count = 0)
        rpt .= "(nothing found — make sure you are in-game; run 1 stored)" nl
    else if (prevCount = 0)
        rpt .= "(run 1 stored — now hover a monster/chest and run again)" nl
    else
    {
        rpt .= "-- NEW/CHANGED vs previous run (hovered-entity candidates) --" nl
        changes := 0
        for key, h in cur
        {
            prevId := g_hoverScanPrev.Has(key) ? g_hoverScanPrev[key]["id"] : 0
            if (prevId != h["id"])
            {
                rpt .= Format("  >> {} id {} -> {}  ent=0x{:X}  {}",
                    key, prevId, h["id"], h["entPtr"], h["path"]) nl
                changes += 1
            }
        }
        for key, h in g_hoverScanPrev
        {
            if !cur.Has(key)
            {
                rpt .= Format("  << {} lost id {} (was {})", key, h["id"], h["path"]) nl
                changes += 1
            }
        }
        if (changes = 0)
            rpt .= "  (no slot changed — re-run while the cursor is actually over a monster"
                . " when you press Ctrl+Alt+H)" nl
    }

    g_hoverScanPrev := cur
    _AIP_WriteProbeLog("hovertracker_probe", rpt)
}
