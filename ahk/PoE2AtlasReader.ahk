; PoE2AtlasReader.ahk
; Reverse-engineering scaffold for porting the C# "Atlas" GameHelper plugin
; (github.com/danthespal/Atlas) to PoEformance.
;
; The offsets in g_atlasOff are taken verbatim from the reference plugin's
; GameStructures.cs and are HYPOTHESES for our PoE2 build. AtlasDumpDebug()
; writes BOTH a parsed interpretation (using these offsets) AND raw hex of the
; key regions, so we can verify / correct the offsets against the live game:
;
;   1. Start PoE2, open the Atlas / World map.
;   2. Trigger the dump (Config → Debug → "Dump Atlas", or ahkCall('DumpAtlas')).
;   3. Inspect debug\atlas_debug_*.txt — confirm the node count / names look
;      right; if not, the raw hex tells us where the real offsets are.
;
; Included by InGameStateMonitor.ahk

; Candidate offsets from the reference plugin (GameStructures.cs). VERIFY for PoE2.
global g_atlasOff := Map(
    "AtlasNodesFirst", 0x510,   ; StdVector<AtlasNodeEntry> First ptr
    "AtlasNodesLast",  0x518,   ; StdVector<AtlasNodeEntry> Last ptr (+8)
    "AtlasConnFirst",  0x528,   ; StdVector<AtlasNodeConnections> First ptr
    "AtlasConnLast",   0x530,   ; (+8)
    "EntryStride",     0x18,    ; AtlasNodeEntry: GridPos(8) + UiElemPtr(8) + Unknown(8)
    "EntryGridX",      0x00,
    "EntryGridY",      0x04,
    "EntryUiElemPtr",  0x08,
    "NodeNameAddr",    0x270,   ; AtlasNode.NodeNameAddress (IntPtr) -> +0x8 -> wide buffer
    "NodeNameBuf",     0x08,
    "NodeFlags",       0x290,   ; ushort AtlasNodeState (bit flags: accessible / completed)
    "NodeBiomeId",     0x293    ; byte biome id
)

; UI-tree search: locate the Atlas/World panel UiElement by its StringId.
; Walks children breadth-first from rootPtr (an UiElement) reading each
; element's StringId (StdWString @ UiElementBase.StringIdPtr). Returns the
; matching element pointer, or 0. Bounded by maxVisit to stay responsive.
; Params: reader (g_reader), rootPtr, wantList (array of lowercase substrings).
AtlasFindPanel(reader, rootPtr, wantList, maxVisit := 8000)
{
    if !(IsObject(reader) && reader.IsProbablyValidPointer(rootPtr))
        return 0
    childFirstOff := PoE2Offsets.UiElementBase["ChildrenFirst"]   ; 0x010
    childLastOff := childFirstOff + 0x08                          ; 0x018
    sidOff := PoE2Offsets.UiElementBase["StringIdPtr"]            ; 0x0F8

    queue := [rootPtr]
    visited := 0
    while (queue.Length > 0 && visited < maxVisit)
    {
        el := queue.RemoveAt(1)
        if !reader.IsProbablyValidPointer(el)
            continue
        visited += 1

        sid := ""
        try sid := reader.ReadStdWStringAt(el + sidOff, 64)
        if (sid != "")
        {
            low := StrLower(sid)
            for _, want in wantList
            {
                if InStr(low, want)
                    return el
            }
        }

        ; Enqueue children (StdVector of UiElement pointers).
        cFirst := reader.Mem.ReadInt64(el + childFirstOff)
        cLast := reader.Mem.ReadInt64(el + childLastOff)
        if (cFirst <= 0 || cLast <= cFirst)
            continue
        n := (cLast - cFirst) // 8
        if (n <= 0 || n > 10000)
            continue
        i := 0
        while (i < n)
        {
            child := reader.Mem.ReadPtr(cFirst + i * 8)
            if reader.IsProbablyValidPointer(child)
                queue.Push(child)
            i += 1
        }
    }
    return 0
}

; Parses the AtlasNodes vector at panelPtr using g_atlasOff. Returns an array of
; Map("gridX","gridY","uiElemPtr","flags","biomeId","name"), capped at maxNodes.
AtlasReadNodes(reader, panelPtr, maxNodes := 2000)
{
    out := []
    if !(IsObject(reader) && reader.IsProbablyValidPointer(panelPtr))
        return out
    first := reader.Mem.ReadInt64(panelPtr + g_atlasOff["AtlasNodesFirst"])
    last := reader.Mem.ReadInt64(panelPtr + g_atlasOff["AtlasNodesLast"])
    if (first <= 0 || last <= first)
        return out
    stride := g_atlasOff["EntryStride"]
    count := (last - first) // stride
    if (count <= 0 || count > 100000)
        return out
    count := Min(count, maxNodes)

    i := 0
    while (i < count)
    {
        entry := first + i * stride
        i += 1
        eb := reader.Mem.ReadBytes(entry, stride)
        if !eb
            continue
        gx := NumGet(eb.Ptr, g_atlasOff["EntryGridX"], "Int")
        gy := NumGet(eb.Ptr, g_atlasOff["EntryGridY"], "Int")
        uiElem := NumGet(eb.Ptr, g_atlasOff["EntryUiElemPtr"], "Int64")

        flags := 0
        biome := 0
        name := ""
        if reader.IsProbablyValidPointer(uiElem)
        {
            nb := reader.Mem.ReadBytes(uiElem + g_atlasOff["NodeFlags"], 0x08)
            if nb
            {
                flags := NumGet(nb.Ptr, 0, "UShort")
                biome := NumGet(nb.Ptr, g_atlasOff["NodeBiomeId"] - g_atlasOff["NodeFlags"], "UChar")
            }
            nameStruct := reader.Mem.ReadPtr(uiElem + g_atlasOff["NodeNameAddr"])
            if reader.IsProbablyValidPointer(nameStruct)
            {
                bufPtr := reader.Mem.ReadPtr(nameStruct + g_atlasOff["NodeNameBuf"])
                if reader.IsProbablyValidPointer(bufPtr)
                    name := _AtlasReadWide(reader, bufPtr, 64)
            }
        }
        out.Push(Map("gridX", gx, "gridY", gy, "uiElemPtr", uiElem,
            "flags", flags, "biomeId", biome, "name", name))
    }
    return out
}

; Reads up to maxChars UTF-16 chars from a raw buffer pointer (not a StdWString).
_AtlasReadWide(reader, bufPtr, maxChars := 64)
{
    buf := reader.Mem.ReadBytes(bufPtr, maxChars * 2)
    if !buf
        return ""
    s := ""
    i := 0
    while (i < maxChars)
    {
        code := NumGet(buf.Ptr, i * 2, "UShort")
        if (code = 0)
            break
        ; Keep printable BMP range only; bail on garbage.
        if (code < 0x20 || code > 0xFFFD)
            break
        s .= Chr(code)
        i += 1
    }
    return s
}

; Formats <size> bytes at <addr> as an offset-annotated hex dump (16/row).
_AtlasHexDump(reader, addr, size)
{
    b := reader.Mem.ReadBytes(addr, size)
    if !b
        return "  <read failed>`n"
    out := ""
    row := 0
    while (row * 16 < size)
    {
        line := Format("  +0x{:03X}:", row * 16)
        col := 0
        while (col < 16 && (row * 16 + col) < size)
        {
            line .= " " Format("{:02X}", NumGet(b.Ptr, row * 16 + col, "UChar"))
            col += 1
        }
        out .= line "`n"
        row += 1
    }
    return out
}

; Debug entrypoint: resolve the Atlas panel, parse nodes, and write a report
; (parsed view + raw hex of the panel & first node struct) for offset RE.
; Returns the output path, or "" on failure.
AtlasDumpDebug(reader, snap)
{
    if !(IsObject(reader) && snap && snap.Has("inGameState"))
        return ""
    inGs := snap["inGameState"]
    root := 0
    for _, k in ["activeGameUiPtr", "gameUiPtr", "uiRootPtr"]
    {
        if (inGs.Has(k) && reader.IsProbablyValidPointer(inGs[k]))
        {
            root := inGs[k]
            break
        }
    }
    if !root
        return ""

    panel := AtlasFindPanel(reader, root, ["worldpanel", "atlas"])
    outDir := A_ScriptDir "\debug"
    if !DirExist(outDir)
        DirCreate(outDir)
    outPath := outDir "\atlas_debug_" FormatTime(A_Now, "yyyyMMdd_HHmmss") ".txt"

    txt := "PoE2 Atlas RE dump`n"
    txt .= "root UI ptr: " Format("0x{:X}", root) "`n"
    if !panel
    {
        txt .= "`n!! Atlas/World panel NOT found by StringId (worldpanel/atlas).`n"
        txt .= "   Open the Atlas/World map first, then dump again. If it is open,`n"
        txt .= "   the StringId differs — widen the search list in AtlasDumpDebug().`n"
        FileAppend(txt, outPath, "UTF-8")
        return outPath
    }
    txt .= "panel ptr:   " Format("0x{:X}", panel) "`n"

    first := reader.Mem.ReadInt64(panel + g_atlasOff["AtlasNodesFirst"])
    last := reader.Mem.ReadInt64(panel + g_atlasOff["AtlasNodesLast"])
    stride := g_atlasOff["EntryStride"]
    rawCount := (first > 0 && last > first) ? (last - first) // stride : 0
    txt .= Format("AtlasNodes vector @ +0x{:X}: first=0x{:X} last=0x{:X} count={}`n",
        g_atlasOff["AtlasNodesFirst"], first, last, rawCount)

    nodes := AtlasReadNodes(reader, panel, 60)
    txt .= "parsed nodes (first " nodes.Length "):`n"
    txt .= "  grid      flags  biome  name`n"
    for _, nd in nodes
    {
        txt .= Format("  ({:4},{:4})  0x{:04X}  {:3}    {}`n",
            nd["gridX"], nd["gridY"], nd["flags"], nd["biomeId"], nd["name"])
    }

    ; Raw hex for offset verification.
    txt .= "`n--- RAW: panel +0x500..+0x540 (locate node/conn vectors) ---`n"
    txt .= _AtlasHexDump(reader, panel + 0x500, 0x40)
    if (nodes.Length > 0 && reader.IsProbablyValidPointer(nodes[1]["uiElemPtr"]))
    {
        node1 := nodes[1]["uiElemPtr"]
        txt .= "`n--- RAW: first node UiElem +0x260..+0x2A0 (name/flags/biome) ---`n"
        txt .= "node1 ptr: " Format("0x{:X}", node1) "`n"
        txt .= _AtlasHexDump(reader, node1 + 0x260, 0x40)
    }

    FileAppend(txt, outPath, "UTF-8")
    return outPath
}

; Bridge handler: triggered from the UI ("Dump Atlas" button / ahkCall).
OnDumpAtlasClicked(*)
{
    global g_reader, g_radarLastSnap
    if !IsObject(g_reader)
    {
        MsgBox("Reader not initialised.", "Dump Atlas", 0x10)
        return
    }
    snap := IsObject(g_radarLastSnap) ? g_radarLastSnap : 0
    if !snap
    {
        MsgBox("No game snapshot yet. Load into the game first.", "Dump Atlas", 0x10)
        return
    }
    outPath := ""
    try outPath := AtlasDumpDebug(g_reader, snap)
    if outPath
        MsgBox("Atlas RE dump written to:`n" outPath "`n`nOpen the Atlas/World map before dumping for useful data.", "Dump Atlas", 0x40)
    else
        MsgBox("Atlas dump failed (no UI root / snapshot).", "Dump Atlas", 0x10)
}
