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

        ; ── Reference-based location (GameHelper2 ImportantUiElements.cs) ─────────
        ; Atlas = GameUi -> child 22 -> child 0 -> child 6;  WorldMap = [22,0].
        ; The indices drift per patch, so list the root children to confirm which
        ; index is the world-travel panel for THIS build, then resolve the paths
        ; and scan the atlas panel for its Descriptions (node) list.
        txt .= "`n=== reference child-path location (GameHelper2: Atlas = root->22->0->6) ===`n"
        txt .= "root children (identify the world-map panel index by size/children):`n"
        txt .= _AtlasDumpChildren(reader, root, 40)

        wm := _AtlasResolveChildPath(reader, root, [22, 0])
        txt .= Format("`nWorldMap [22,0] -> 0x{:X}`n", wm)
        if wm
            txt .= _AtlasDumpChildren(reader, wm, 40)

        at := _AtlasResolveChildPath(reader, root, [22, 0, 6])
        txt .= Format("`nAtlas [22,0,6] -> 0x{:X}`n", at)
        if at
        {
            txt .= _AtlasDumpChildren(reader, at, 16)
            txt .= "vector scan @ Atlas panel (look for the Descriptions/node list):`n"
            txt .= _AtlasScanVectors(reader, at, 0x800)
        }

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
        rootHits := []
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
                    rootHits.Push(v)
                    found += 1
                }
                off += 8
            }
            if !found
                txt .= "  (no chain pointer in root+0..0x1600 — panel attaches deeper)`n"
        }

        ; ── Locate the node array: scan each candidate panel struct for StdVector
        ; (first,last) pairs, and report its UI-children count. The atlas node DATA
        ; vector should surface as a vector with a large/plausible element count.
        probe := []
        seenP := Map()
        for _, p in rootHits
            if (!seenP.Has(p)) {
                seenP[p] := 1
                probe.Push(p)
            }
        for _, c in [cand.Length >= 1 ? cand[1]["ptr"] : 0, cand.Length >= 2 ? cand[2]["ptr"] : 0]
            if (c && !seenP.Has(c)) {
                seenP[c] := 1
                probe.Push(c)
            }
        for _, p in probe
        {
            cf := reader.Mem.ReadInt64(p + 0x10)
            cl := reader.Mem.ReadInt64(p + 0x18)
            childN := (cf > 0 && cl > cf) ? (cl - cf) // 8 : 0
            txt .= Format("`n--- vector scan @ 0x{:X} (uiChildren={}) ---`n", p, childN)
            txt .= _AtlasScanVectors(reader, p, 0x800)
        }

        ; ── Decisive check: read GameHelper2 node fields from each candidate panel.
        ; The atlas is whichever panel's children have valid mapData/biome/grid.
        txt .= "`n=== atlas node-field probe (mapData 0x2A0 / biome 0x2CE / status 0x2CF / grid 0x320 / conn 0x5A8) ===`n"
        txt .= "Atlas [22,0,6]:`n"
        txt .= at ? _AtlasProbeNodeFields(reader, at, 8) : "  (path unresolved)`n"
        pj := 1
        while (pj <= Min(cand.Length, 5))
        {
            txt .= Format("cand#{} {}x{}:`n", pj, Round(cand[pj]["w"]), Round(cand[pj]["h"]))
            txt .= _AtlasProbeNodeFields(reader, cand[pj]["ptr"], 6)
            pj += 1
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

; Peeks the first element of a candidate vector to classify it (address-
; independent). For an 8-byte (pointer) stride it derefs entry[0] and reports
; whether it looks like a UiElement (valid parent ptr) plus its size and any
; style/string at 0xF8; for wider strides it shows the inline element's leading
; int64 / float fields (e.g. grid or world coordinates). Returns a short label.
_AtlasPeekEntry(reader, first, stride)
{
    ub := PoE2Offsets.UiElementBase
    if (stride = 8)
    {
        p := reader.Mem.ReadPtr(first)
        if !reader.IsProbablyValidPointer(p)
            return Format("[0]=0x{:X} (non-ptr)", p)
        par := reader.Mem.ReadPtr(p + ub["ParentPtr"])
        sid := ""
        try sid := reader.ReadStdWStringAt(p + ub["StringIdPtr"], 32)
        kind := reader.IsProbablyValidPointer(par) ? "elem" : "obj "
        w := reader.Mem.ReadFloat(p + ub["UnscaledSize"])
        h := reader.Mem.ReadFloat(p + ub["UnscaledSize"] + 4)
        return Format("[0]->0x{:X} {} sz={}x{} sid='{}'", p, kind, Round(w), Round(h), sid)
    }
    b := reader.Mem.ReadBytes(first, 0x20)
    if !b
        return "[0]=read-fail"
    return Format("[0] i64=0x{:X},0x{:X} f=[{:.1f},{:.1f},{:.1f},{:.1f}]",
        NumGet(b.Ptr, 0, "Int64"), NumGet(b.Ptr, 8, "Int64"),
        NumGet(b.Ptr, 0, "Float"), NumGet(b.Ptr, 4, "Float"),
        NumGet(b.Ptr, 8, "Float"), NumGet(b.Ptr, 12, "Float"))
}

; Scans a struct for StdVector-like (first,last) pointer pairs: both heap ptrs,
; last > first, span divisible by a plausible element stride with a sane element
; count. Returns formatted lines — used to locate the atlas node array inside a
; panel struct without knowing the exact field offset. base/range define the scan.
_AtlasScanVectors(reader, base, range := 0x800)
{
    buf := reader.Mem.ReadBytes(base, range + 16)
    if !buf
        return "  (read fail)`n"
    strides := [8, 16, 0x18, 0x20, 0x28, 0x30, 0x38, 0x40, 0x48, 0x50]
    out := ""
    off := 0
    while (off < range)
    {
        v0 := NumGet(buf.Ptr, off, "Int64")
        v1 := NumGet(buf.Ptr, off + 8, "Int64")
        if (reader.IsProbablyValidPointer(v0) && reader.IsProbablyValidPointer(v1)
            && v1 > v0 && (v1 - v0) < 0x400000)
        {
            span := v1 - v0
            for _, st in strides
            {
                if (Mod(span, st) = 0)
                {
                    cnt := span // st
                    if (cnt >= 4 && cnt <= 8000)
                    {
                        out .= Format("  +0x{:03X}: first=0x{:X} stride=0x{:02X} count={:5}  {}`n",
                            off, v0, st, cnt, _AtlasPeekEntry(reader, v0, st))
                        break
                    }
                }
            }
        }
        off += 8
    }
    return (out != "") ? out : "  (no vector-like pairs)`n"
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

; Reads the GameHelper2 atlas-node fields from a panel's first children to verify
; which candidate panel is the real endgame Atlas and that the offsets resolve to
; sane values. Offsets (GameHelper2 ImportantUiElements.cs): mapData 0x2A0,
; biomeId 0x2CE, status 0x2CF, gridPosition 0x320 (int,int), connections vec 0x5A8.
; A real node has a valid mapData ptr, a small biome byte and plausible grid ints.
_AtlasProbeNodeFields(reader, panelPtr, maxN := 8)
{
    ub := PoE2Offsets.UiElementBase
    if !reader.IsProbablyValidPointer(panelPtr)
        return "  (invalid panel)`n"
    cf := reader.Mem.ReadInt64(panelPtr + ub["ChildrenFirst"])
    cl := reader.Mem.ReadInt64(panelPtr + ub["ChildrenFirst"] + 8)
    n := (cf > 0 && cl > cf) ? (cl - cf) // 8 : 0
    out := Format("  panel 0x{:X}  children={}`n", panelPtr, n)
    i := 0
    while (i < n && i < maxN)
    {
        c := reader.Mem.ReadPtr(cf + i * 8)
        if reader.IsProbablyValidPointer(c)
        {
            mapData := reader.Mem.ReadPtr(c + 0x2A0)
            biome := reader.Mem.ReadUChar(c + 0x2CE)
            status := reader.Mem.ReadUChar(c + 0x2CF)
            gp := reader.Mem.ReadBytes(c + 0x320, 8)
            gx := gp ? NumGet(gp.Ptr, 0, "Int") : 0
            gy := gp ? NumGet(gp.Ptr, 4, "Int") : 0
            cvf := reader.Mem.ReadInt64(c + 0x5A8)
            cvl := reader.Mem.ReadInt64(c + 0x5A8 + 8)
            connBytes := (cvf > 0 && cvl > cvf && (cvl - cvf) < 0x10000) ? (cvl - cvf) : 0
            w := reader.Mem.ReadFloat(c + ub["UnscaledSize"])
            h := reader.Mem.ReadFloat(c + ub["UnscaledSize"] + 4)
            out .= Format("  [{:2}] 0x{:X} sz={}x{} mapData={} biome={} st={} grid=({},{}) conn={}`n",
                i, c, Round(w), Round(h),
                (reader.IsProbablyValidPointer(mapData) ? Format("0x{:X}", mapData) : "-"),
                biome, status, gx, gy, connBytes)
        }
        i += 1
    }
    return out
}

; Walks a UiElement child-index path (e.g. [22,0,6]) from base via the children
; vector at ChildrenFirst (0x10). This is how GameHelper2 locates the atlas panel.
; Returns the resolved element pointer, or 0 if any index is out of range.
_AtlasResolveChildPath(reader, base, path)
{
    cur := base
    for _, idx in path
    {
        if !reader.IsProbablyValidPointer(cur)
            return 0
        cf := reader.Mem.ReadInt64(cur + PoE2Offsets.UiElementBase["ChildrenFirst"])
        cl := reader.Mem.ReadInt64(cur + PoE2Offsets.UiElementBase["ChildrenFirst"] + 8)
        n := (cf > 0 && cl > cf) ? (cl - cf) // 8 : 0
        if (idx < 0 || idx >= n)
            return 0
        cur := reader.Mem.ReadPtr(cf + idx * 8)
    }
    return reader.IsProbablyValidPointer(cur) ? cur : 0
}

; Lists a UiElement's direct children (index, ptr, visibility, size, grandchild
; count) — used to identify the world-map / atlas child index for the current
; patch when the reference indices drift. Returns formatted text.
_AtlasDumpChildren(reader, elem, maxN := 40)
{
    ub := PoE2Offsets.UiElementBase
    if !reader.IsProbablyValidPointer(elem)
        return "  (invalid element)`n"
    cf := reader.Mem.ReadInt64(elem + ub["ChildrenFirst"])
    cl := reader.Mem.ReadInt64(elem + ub["ChildrenFirst"] + 8)
    n := (cf > 0 && cl > cf) ? (cl - cf) // 8 : 0
    out := Format("  ({} children)`n", n)
    i := 0
    while (i < n && i < maxN)
    {
        c := reader.Mem.ReadPtr(cf + i * 8)
        if reader.IsProbablyValidPointer(c)
        {
            flags := reader.Mem.ReadUInt(c + ub["Flags"])
            w := reader.Mem.ReadFloat(c + ub["UnscaledSize"])
            h := reader.Mem.ReadFloat(c + ub["UnscaledSize"] + 4)
            gcf := reader.Mem.ReadInt64(c + ub["ChildrenFirst"])
            gcl := reader.Mem.ReadInt64(c + ub["ChildrenFirst"] + 8)
            gn := (gcf > 0 && gcl > gcf) ? (gcl - gcf) // 8 : 0
            out .= Format("  [{:2}] 0x{:X} vis={} sz={}x{} children={}`n",
                i, c, ((flags >> 11) & 1), Round(w), Round(h), gn)
        }
        else
            out .= Format("  [{:2}] 0x{:X} (invalid)`n", i, c)
        i += 1
    }
    return out
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
