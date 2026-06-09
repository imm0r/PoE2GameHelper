; MemoryDiff.ahk
; Reverse-engineering helper: capture two snapshots of a memory region with a
; user-driven action between them, then diff the byte-runs that changed.
;
; Typical workflow:
;   1. Pick a named anchor (ServerDataStructure / GameUI / AreaInstance /
;      InGameState) or a raw hex address + a size in bytes.
;   2. Click "Before" → reads `size` bytes, stores them.
;   3. Perform an in-game action (open stash tab, equip item, cast a skill).
;   4. Click "After" → reads again, compares against the saved buffer,
;      pushes the byte-runs that changed with multi-format decodes (hex,
;      int32, int64, ptr, float).
;
; Use cases this collapses from hours into seconds:
;   - Discovering which struct field tracks the active stash tab index
;   - Finding where a "is panel open" bit lives without scanning by hand
;   - Validating offset hypotheses ("if I change zone, does field X at
;     offset 0x300 update?")
;   - Detecting cooldown counters / skill state by acting then diffing
;
; Included by InGameStateMonitor.ahk.

; Globals declared in InGameStateMonitor.ahk:
;   g_memDiffSymbol        — chosen anchor name or "Custom"
;   g_memDiffAddress       — resolved absolute address (Int64)
;   g_memDiffSize          — read size in bytes (Int)
;   g_memDiffBeforeBuf     — Buffer holding the "Before" snapshot, or 0
;   g_memDiffBeforeAddr    — address the Before snapshot was taken at
;   g_memDiffBeforeTime    — A_TickCount when Before was taken
;   g_memDiffAfterBuf      — Buffer holding the "After" snapshot, or 0
;   g_memDiffAfterTime     — A_TickCount when After was taken
;   g_memDiffStatus        — short status string for the UI

; ── Symbol resolution ─────────────────────────────────────────────────────
; Maps a symbol name to an absolute address by walking the same pointer
; chains the rest of the reader uses. Returns 0 when unresolvable.
;
; Supported symbols:
;   ServerDataStructure  — the deref'd player-server-data struct (carries
;                          PlayerInventories at +0x320)
;   GameUI               — the in-game UI root pointer (carries panel ptrs)
;   AreaInstance         — current area instance struct
;   InGameState          — current InGameState struct
;   Custom               — caller-provided hex address (returned as-is)
;
; The chain reads mirror PushInventoryToWebView's resolver — copy-paste
; rather than refactor because the symbol set may grow independently.
MemDiffResolveSymbol(symbol, customAddr := 0)
{
    global g_reader, g_radarLastSnap
    if !(IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle)
        return 0

    if (symbol = "Custom")
        return customAddr

    snap     := IsObject(g_radarLastSnap) ? g_radarLastSnap : 0
    inGs     := (snap && snap.Has("inGameState")) ? snap["inGameState"] : 0
    area     := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    inGsAddr := (inGs && IsObject(inGs) && inGs.Has("address")) ? inGs["address"] : 0
    areaAddr := (area && IsObject(area) && area.Has("address")) ? area["address"] : 0

    if (symbol = "InGameState")
        return inGsAddr
    if (symbol = "AreaInstance")
        return areaAddr

    if (symbol = "ServerDataStructure")
    {
        if (!areaAddr)
            return 0
        try
        {
            playerInfoPtr    := areaAddr + PoE2Offsets.AreaInstance["PlayerInfo"]
            serverDataRawPtr := g_reader.Mem.ReadPtr(playerInfoPtr + PoE2Offsets.LocalPlayerStruct["ServerDataPtr"])
            sdPtr            := g_reader.ResolveServerDataPointer(playerInfoPtr, serverDataRawPtr)
            if !sdPtr
                return 0
            ; ServerDataStructure is the deref'd PlayerServerData[0] — go one hop further
            psdVecFirst := g_reader.Mem.ReadInt64(sdPtr + PoE2Offsets.ServerData["PlayerServerData"])
            if (psdVecFirst <= 0)
                return 0
            return g_reader.Mem.ReadPtr(psdVecFirst)
        }
        catch
            return 0
    }

    if (symbol = "GameUI")
    {
        if (!inGsAddr)
            return 0
        try
        {
            ; GameUI anchor = the UI-root struct pointer itself (KB/M) or the gamepad
            ; one (controller). The PoE2 v4.5 patch dropped the old GameUiPtr(0xBE0)
            ; indirection (see PoE2MemoryReader.activeGameUiPtr / UiBrowserHandler).
            uiRootStructPtr := g_reader.Mem.ReadPtr(inGsAddr + PoE2Offsets.InGameState["UiRootStructPtr"])
            if g_reader.IsProbablyValidPointer(uiRootStructPtr)
                return uiRootStructPtr
            return g_reader.Mem.ReadPtr(inGsAddr + PoE2Offsets.InGameState["GamepadUiRootStructPtr"])
        }
        catch
            return 0
    }

    return 0
}

; ── Snapshot capture ──────────────────────────────────────────────────────
; Reads `g_memDiffSize` bytes starting at `g_memDiffAddress` (resolving the
; symbol first when set) and stores the buffer in the matching slot.
; slot is "before" or "after". Returns a status string for the UI.
MemDiffSnapshot(slot)
{
    global g_reader, g_memDiffSymbol, g_memDiffAddress, g_memDiffCustomAddr, g_memDiffSize
    global g_memDiffBeforeBuf, g_memDiffBeforeAddr, g_memDiffBeforeTime
    global g_memDiffAfterBuf, g_memDiffAfterTime, g_memDiffStatus

    if !(IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle)
    {
        g_memDiffStatus := "not-connected"
        return g_memDiffStatus
    }

    addr := MemDiffResolveSymbol(g_memDiffSymbol, g_memDiffCustomAddr)
    if (!addr)
    {
        g_memDiffStatus := "unresolved-symbol(" g_memDiffSymbol ")"
        return g_memDiffStatus
    }
    g_memDiffAddress := addr

    sz := g_memDiffSize
    if (sz < 16 || sz > 262144)   ; clamp 16 B .. 256 KB
    {
        g_memDiffStatus := "bad-size(" sz ")"
        return g_memDiffStatus
    }

    buf := g_reader.Mem.ReadBytes(addr, sz, true)
    if !buf
    {
        g_memDiffStatus := "read-failed addr=0x" Format("{:X}", addr) " size=" sz
        return g_memDiffStatus
    }

    if (slot = "before")
    {
        g_memDiffBeforeBuf  := buf
        g_memDiffBeforeAddr := addr
        g_memDiffBeforeTime := A_TickCount
        g_memDiffStatus := "before-ok " (buf.Size) "B @ 0x" Format("{:X}", addr)
    }
    else if (slot = "after")
    {
        g_memDiffAfterBuf  := buf
        g_memDiffAfterTime := A_TickCount
        g_memDiffStatus := "after-ok " (buf.Size) "B @ 0x" Format("{:X}", addr)
    }
    return g_memDiffStatus
}

; Clears both snapshots and resets status.
MemDiffClear()
{
    global g_memDiffBeforeBuf, g_memDiffAfterBuf, g_memDiffStatus
    g_memDiffBeforeBuf := 0
    g_memDiffAfterBuf  := 0
    g_memDiffStatus    := "cleared"
}

; ── Diff computation ──────────────────────────────────────────────────────
; Walks the two buffers byte-by-byte, grouping consecutive differing bytes
; into runs. For each run we emit:
;   {
;     offset:  byte offset from the snapshot base (relative)
;     length:  run length in bytes
;     before:  hex string of original bytes
;     after:   hex string of new bytes
;     decode:  Map of name → interpretation (int32, int64, ptr, float)
;              — only filled for runs that align to 4 or 8 bytes
;   }
;
; The hex strings are truncated past 64 bytes to keep the UI rendering snappy
; (longer runs are rare except across page boundaries; the UI shows the
; full length and a "…" suffix so the user knows there's more).
;
; Returns: Map with "runs" (Array of run Maps), "totalChanged" (count of
; differing bytes), "addrBefore", "addrAfter" (resolved addresses).
MemDiffCompute()
{
    global g_memDiffBeforeBuf, g_memDiffAfterBuf, g_memDiffBeforeAddr

    out := Map(
        "runs", [],
        "totalChanged", 0,
        "addrBefore", g_memDiffBeforeAddr,
        "addrAfter",  g_memDiffBeforeAddr,
        "error", ""
    )

    b := g_memDiffBeforeBuf
    a := g_memDiffAfterBuf
    if !(b && a)
    {
        out["error"] := "need-both-snapshots"
        return out
    }
    if (b.Size != a.Size)
    {
        out["error"] := "size-mismatch before=" b.Size " after=" a.Size
        return out
    }

    sz := b.Size
    runs := []
    runStart  := -1
    totalChanged := 0
    i := 0
    while (i < sz)
    {
        bByte := NumGet(b.Ptr, i, "UChar")
        aByte := NumGet(a.Ptr, i, "UChar")
        if (bByte != aByte)
        {
            if (runStart < 0)
                runStart := i
            totalChanged += 1
        }
        else if (runStart >= 0)
        {
            ; Run ended at i. Flush it.
            _MemDiffEmitRun(runs, b, a, runStart, i - runStart)
            runStart := -1
        }
        i += 1
    }
    if (runStart >= 0)
        _MemDiffEmitRun(runs, b, a, runStart, sz - runStart)

    out["runs"] := runs
    out["totalChanged"] := totalChanged
    return out
}

; Internal: build one run record and push it onto the runs array.
_MemDiffEmitRun(runs, beforeBuf, afterBuf, offset, length)
{
    maxHex := 64   ; hex preview cap per side
    showLen := Min(length, maxHex)

    beforeHex := ""
    afterHex  := ""
    j := 0
    while (j < showLen)
    {
        bv := NumGet(beforeBuf.Ptr, offset + j, "UChar")
        av := NumGet(afterBuf.Ptr,  offset + j, "UChar")
        beforeHex .= Format("{:02X}", bv) . " "
        afterHex  .= Format("{:02X}", av) . " "
        j += 1
    }
    beforeHex := RTrim(beforeHex)
    afterHex  := RTrim(afterHex)
    if (length > maxHex)
    {
        beforeHex .= " …"
        afterHex  .= " …"
    }

    ; Decode interpretations — only when the run starts on a useful alignment
    ; AND is long enough to hold the type. Multiple decodes per run are
    ; useful: a 4-byte change at an 8-aligned offset could be an int32 *or*
    ; the low half of an int64.
    decode := Map()
    if (length >= 4)
    {
        decode["i32(before)"] := NumGet(beforeBuf.Ptr, offset, "Int")
        decode["i32(after)"]  := NumGet(afterBuf.Ptr,  offset, "Int")
        decode["u32(before)"] := NumGet(beforeBuf.Ptr, offset, "UInt")
        decode["u32(after)"]  := NumGet(afterBuf.Ptr,  offset, "UInt")
        decode["flt(before)"] := Round(NumGet(beforeBuf.Ptr, offset, "Float"), 4)
        decode["flt(after)"]  := Round(NumGet(afterBuf.Ptr,  offset, "Float"), 4)
    }
    if (length >= 8)
    {
        bPtr := NumGet(beforeBuf.Ptr, offset, "Int64")
        aPtr := NumGet(afterBuf.Ptr,  offset, "Int64")
        decode["i64(before)"] := bPtr
        decode["i64(after)"]  := aPtr
        decode["ptr(before)"] := Format("0x{:X}", bPtr & 0xFFFFFFFFFFFFFFFF)
        decode["ptr(after)"]  := Format("0x{:X}", aPtr & 0xFFFFFFFFFFFFFFFF)
    }
    if (length = 1)
    {
        decode["u8(before)"] := NumGet(beforeBuf.Ptr, offset, "UChar")
        decode["u8(after)"]  := NumGet(afterBuf.Ptr,  offset, "UChar")
    }
    if (length = 2)
    {
        decode["u16(before)"] := NumGet(beforeBuf.Ptr, offset, "UShort")
        decode["u16(after)"]  := NumGet(afterBuf.Ptr,  offset, "UShort")
    }

    runs.Push(Map(
        "offset", offset,
        "length", length,
        "before", beforeHex,
        "after",  afterHex,
        "decode", decode
    ))
}
