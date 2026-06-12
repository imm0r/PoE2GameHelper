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
    root := _AtlasResolveUiRoot(reader, snap)
    if !root
        return ""

    panel := AtlasFindPanel(reader, root, ["worldpanel", "atlas", "worldmap", "atlasmap"])
    outDir := A_ScriptDir "\debug"
    if !DirExist(outDir)
        DirCreate(outDir)
    outPath := outDir "\atlas_debug_" FormatTime(A_Now, "yyyyMMdd_HHmmss") ".txt"

    txt := "PoE2 Atlas RE dump`n"
    txt .= "root UI ptr: " Format("0x{:X}", root) "`n"
    if !panel
    {
        txt .= "`n!! Atlas/World panel NOT found by StringId (worldpanel/atlas/worldmap/atlasmap).`n"
        txt .= "   Enumerating UI elements under the root so the real panel StringId`n"
        txt .= "   can be identified. Make sure the Atlas was open, then send this file.`n"

        ids := _AtlasEnumStringIds(reader, root, 8000)

        ; Visible, panel-sized candidates (large + on screen), area-sorted desc.
        cand := []
        for _, r in ids
            if (r["vis"] && r["w"] >= 200 && r["h"] >= 150)
                cand.Push(r)
        Loop cand.Length - 1                      ; selection sort by area desc
        {
            mi := A_Index
            j := A_Index + 1
            while (j <= cand.Length)
            {
                if (cand[j]["w"] * cand[j]["h"] > cand[mi]["w"] * cand[mi]["h"])
                    mi := j
                j += 1
            }
            if (mi != A_Index)
            {
                tmp := cand[A_Index], cand[A_Index] := cand[mi], cand[mi] := tmp
            }
        }
        txt .= Format("`n--- visible panel-sized elements ({} of {} named) ---`n", cand.Length, ids.Length)
        txt .= "  depth  w      h     stringId`n"
        for _, r in cand
            txt .= Format("  {:5}  {:5}  {:5}  {}`n", r["depth"], Round(r["w"]), Round(r["h"]), r["sid"])

        ; Full unique StringId vocabulary (deduped), sorted by max element area —
        ; the atlas container surfaces near the top even with a generic name.
        uni := Map()
        for _, r in ids
        {
            key := StrLower(r["sid"])
            if !uni.Has(key)
                uni[key] := Map("sid", r["sid"], "count", 0, "maxW", 0, "maxH", 0, "anyVis", 0, "minDepth", 999)
            u := uni[key]
            u["count"] += 1
            if (r["w"] > u["maxW"])
                u["maxW"] := r["w"]
            if (r["h"] > u["maxH"])
                u["maxH"] := r["h"]
            if (r["vis"])
                u["anyVis"] := 1
            if (r["depth"] < u["minDepth"])
                u["minDepth"] := r["depth"]
        }
        arr := []
        for _, u in uni
            arr.Push(u)
        Loop arr.Length - 1                       ; selection sort by max area desc
        {
            mi := A_Index, j := A_Index + 1
            while (j <= arr.Length)
            {
                if (arr[j]["maxW"] * arr[j]["maxH"] > arr[mi]["maxW"] * arr[mi]["maxH"])
                    mi := j
                j += 1
            }
            if (mi != A_Index)
                tmp := arr[A_Index], arr[A_Index] := arr[mi], arr[mi] := tmp
        }
        txt .= Format("`n--- all {} unique StringIds (by max area) ---`n", arr.Length)
        txt .= "  cnt  vis  depth  maxW   maxH   stringId`n"
        for _, u in arr
            txt .= Format("  {:3}  {:3}  {:5}  {:5}  {:5}  {}`n",
                u["count"], u["anyVis"], u["minDepth"], Round(u["maxW"]), Round(u["maxH"]), u["sid"])

        ; WString-offset scan on the largest visible elements — verifies whether
        ; StringIdPtr (0x0F8) is still right this patch and reveals any better-named
        ; field (Normal/Large/NormalSC look font/style-like, not panel ids).
        scanN := Min(cand.Length, 3)
        i := 1
        while (i <= scanN)
        {
            ep := cand[i]["ptr"]
            txt .= Format("`n--- WString scan @ 0x{:X} (w={} h={} depth={}) ---`n",
                ep, Round(cand[i]["w"]), Round(cand[i]["h"]), cand[i]["depth"])
            off := 0xB0
            while (off <= 0x168)
            {
                s := ""
                try s := reader.ReadStdWStringAt(ep + off, 48)
                if (s != "" && _AtlasPrintable(s))
                    txt .= Format("  +0x{:03X}: {}`n", off, s)
                off += 8
            }
            i += 1
        }

        ; Locate the atlas panel the way the rest of the codebase does — by its
        ; FIXED offset in the root UI struct (cf. MapParent @ 0x748), not by name.
        ; Walk the parent chains of the largest visible containers up to the root,
        ; then report which root offset stores each chain pointer. The shallowest
        ; match (the child-of-root) is the stable AtlasPanel anchor to read.
        wanted := Map()
        topN := Min(cand.Length, 4)
        ti := 1
        while (ti <= topN)
        {
            cur := cand[ti]["ptr"], hops := 0
            while (reader.IsProbablyValidPointer(cur) && hops < 12)
            {
                wanted[cur] := Format("cand#{} hop{} {}x{}", ti, hops, Round(cand[ti]["w"]), Round(cand[ti]["h"]))
                p := reader.Mem.ReadPtr(cur + PoE2Offsets.UiElementBase["ParentPtr"])
                if (p = root || !reader.IsProbablyValidPointer(p))
                    break
                cur := p
                hops += 1
            }
            ti += 1
        }
        txt .= "`n--- root-struct offsets holding the atlas container chain ---`n"
        buf := reader.Mem.ReadBytes(root, 0x1600)
        if !buf
            txt .= "  (could not read root struct)`n"
        else
        {
            off := 0, found := 0
            while (off < 0x1600)
            {
                v := NumGet(buf.Ptr, off, "Int64")
                if wanted.Has(v)
                {
                    txt .= Format("  root+0x{:04X} -> 0x{:X}  ({})`n", off, v, wanted[v])
                    found += 1
                }
                off += 8
            }
            if !found
                txt .= "  (no chain pointer in root+0..0x1600 — panel attaches deeper)`n"
        }

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

; True if s is a short, fully printable-ASCII string — filters WString-offset
; scan hits (real identifiers) from random heap garbage. Returns true/false.
_AtlasPrintable(s)
{
    if (StrLen(s) < 2 || StrLen(s) > 40)
        return false
    Loop Parse, s
    {
        c := Ord(A_LoopField)
        if (c < 0x20 || c > 0x7E)
            return false
    }
    return true
}

; BFS the UI tree from rootPtr, collecting every UiElement that has a non-empty
; StringId. Each record is Map("ptr","sid","vis","w","h","depth"). Walks at most
; maxVisit elements. Used by the Atlas dump to reveal the real panel StringId when
; the expected ids don't match (mirrors AtlasFindPanel's traversal).
_AtlasEnumStringIds(reader, rootPtr, maxVisit := 8000)
{
    out := []
    if !(IsObject(reader) && reader.IsProbablyValidPointer(rootPtr))
        return out
    ub := PoE2Offsets.UiElementBase
    childFirstOff := ub["ChildrenFirst"]
    childLastOff := childFirstOff + 0x08
    sidOff := ub["StringIdPtr"]
    flagsOff := ub["Flags"]
    sizeOff := ub["UnscaledSize"]

    queue := [rootPtr]
    depths := [0]
    visited := 0
    while (queue.Length > 0 && visited < maxVisit)
    {
        el := queue.RemoveAt(1)
        dep := depths.RemoveAt(1)
        if !reader.IsProbablyValidPointer(el)
            continue
        visited += 1

        sid := ""
        try sid := reader.ReadStdWStringAt(el + sidOff, 64)
        if (sid != "")
        {
            flags := reader.Mem.ReadUInt(el + flagsOff)
            out.Push(Map("ptr", el, "sid", sid,
                "vis", ((flags >> 11) & 1) ? 1 : 0,
                "w", reader.Mem.ReadFloat(el + sizeOff),
                "h", reader.Mem.ReadFloat(el + sizeOff + 4),
                "depth", dep))
        }

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
            {
                queue.Push(child)
                depths.Push(dep + 1)
            }
            i += 1
        }
    }
    return out
}

; Resolves the active UI-root UiElement (KB/M, else controller) from a snapshot —
; the BFS starting point for the Atlas panel search. Derives it live from the
; InGameState address so it never depends on what the radar snapshot happened to
; cache. Returns a pointer, or 0.
_AtlasResolveUiRoot(reader, snap)
{
    if !(IsObject(reader) && snap && snap.Has("inGameState"))
        return 0
    inGs := snap["inGameState"]
    if !(inGs is Map && inGs.Has("address") && reader.IsProbablyValidPointer(inGs["address"]))
        return 0
    addr := inGs["address"]
    root := reader.Mem.ReadPtr(addr + PoE2Offsets.InGameState["UiRootStructPtr"])
    if reader.IsProbablyValidPointer(root)
        return root
    root := reader.Mem.ReadPtr(addr + PoE2Offsets.InGameState["GamepadUiRootStructPtr"])
    return reader.IsProbablyValidPointer(root) ? root : 0
}

; Computes the ABSOLUTE screen position of a UI element by walking its parent
; chain (accumulating RelativePosition, plus the parent's PositionModifier when
; the child's ShouldModifyPos flag is set) and applying GameWindowScale — the
; same math ReadMapUiElementData / the radar use for the map element. rect is the
; client rect (NavClientRect: x,y,w,h). Returns Map("x","y") or 0.
; NOTE: the GameWindowScale branch (esp. scaleIdx 3) is a tuning point to verify
; in-game once the node offsets are confirmed.
_AtlasElemScreenPos(reader, elemPtr, rect)
{
    if !(reader.IsProbablyValidPointer(elemPtr) && rect)
        return 0
    ub := PoE2Offsets.UiElementBase
    relOff := ub["RelativePosition"]
    chain := []
    cur := elemPtr
    Loop 12
    {
        if !reader.IsProbablyValidPointer(cur)
            break
        chain.Push(Map(
            "relX", reader.Mem.ReadFloat(cur + relOff),
            "relY", reader.Mem.ReadFloat(cur + relOff + 4),
            "flags", reader.Mem.ReadUInt(cur + ub["Flags"]),
            "pmX", reader.Mem.ReadFloat(cur + ub["PositionModifier"]),
            "pmY", reader.Mem.ReadFloat(cur + ub["PositionModifier"] + 4)))
        parent := reader.Mem.ReadPtr(cur + ub["ParentPtr"])
        if !reader.IsProbablyValidPointer(parent)
            break
        cur := parent
    }
    N := chain.Length
    if (N = 0)
        return 0
    accX := chain[N]["relX"], accY := chain[N]["relY"]
    Loop N - 1
    {
        ci := N - A_Index            ; walk root-1 … element
        ch := chain[ci], pa := chain[ci + 1]
        if (ch["flags"] >> 10) & 1   ; ShouldModifyPos = bit 10
        {
            accX += pa["pmX"]
            accY += pa["pmY"]
        }
        accX += ch["relX"]
        accY += ch["relY"]
    }
    sfX := rect["w"] / 2560.0        ; UI design reference is 2560×1600
    sfY := rect["h"] / 1600.0
    si := reader.Mem.ReadUChar(elemPtr + ub["ScaleIndex"])
    lm := reader.Mem.ReadFloat(elemPtr + ub["LocalScaleMultiplier"])
    if (lm <= 0)
        lm := 1.0
    if (si = 1)
        usX := lm * sfX, usY := lm * sfX
    else if (si = 2)
        usX := lm * sfY, usY := lm * sfY
    else if (si = 3)
        usX := lm * sfX, usY := lm * sfY
    else
        usX := lm, usY := lm
    return Map("x", rect["x"] + accX * usX, "y", rect["y"] + accY * usY)
}

; Per-tick (throttled, self-gated) builder that bridges the reader to the radar's
; _RenderAtlas: resolve the Atlas panel, read its nodes, project each to absolute
; screen coords via its UiElement, and publish g_atlasRender. Clears g_atlasRender
; (nothing drawn) when the overlay is off or the Atlas panel isn't open. Reads run
; on the main thread, so this is throttled to ~300 ms (the BFS + node walk isn't
; cheap). Connections / content tags / routing come in a later phase once the node
; offsets are confirmed via AtlasDumpDebug.
TryBuildAtlasRender(snap)
{
    global g_reader, g_atlasRender, g_atlasBuildTick, g_atlasOverlayEnabled
    if !(IsSet(g_atlasOverlayEnabled) && g_atlasOverlayEnabled)
        return
    if !(IsObject(g_reader) && snap && snap.Has("inGameState"))
        return
    now := A_TickCount
    if (IsSet(g_atlasBuildTick) && (now - g_atlasBuildTick) < 300)
        return
    g_atlasBuildTick := now

    root := _AtlasResolveUiRoot(g_reader, snap)
    panel := root ? AtlasFindPanel(g_reader, root, ["worldpanel", "atlas"]) : 0
    if !panel
    {
        g_atlasRender := 0       ; atlas not open / not found
        return
    }
    gameHwnd := ResolvePoEWindow()
    rect := gameHwnd ? NavClientRect(gameHwnd) : 0
    if !rect
    {
        g_atlasRender := 0
        return
    }
    nodes := AtlasReadNodes(g_reader, panel, 2000)
    outNodes := []
    for nd in nodes
    {
        if !g_reader.IsProbablyValidPointer(nd["uiElemPtr"])
            continue
        sp := _AtlasElemScreenPos(g_reader, nd["uiElemPtr"], rect)
        if !sp
            continue
        ; Reject nodes that project well outside the window (off-screen / garbage).
        if (sp["x"] < rect["x"] - 300 || sp["x"] > rect["x"] + rect["w"] + 300
            || sp["y"] < rect["y"] - 300 || sp["y"] > rect["y"] + rect["h"] + 300)
            continue
        outNodes.Push(Map("x", sp["x"], "y", sp["y"],
            "name", nd["name"], "biomeId", nd["biomeId"], "flags", nd["flags"]))
    }
    g_atlasRender := outNodes.Length ? Map("nodes", outNodes) : 0
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
