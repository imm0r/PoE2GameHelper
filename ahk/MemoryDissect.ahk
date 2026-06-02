; MemoryDissect.ahk
; Cheat-Engine-style memory dissector: navigate from a base address, view fields
; at 8-byte stride with multi-format decoding. Click pointer fields to jump.
; Back / Forward stacks support breadcrumb navigation.
;
; Globals declared in InGameStateMonitor.ahk:
;   g_memDissectAddress  — current base address (Int64), 0 = none
;   g_memDissectSize     — bytes to read (default 0x200 = 512 → 64 rows)
;   g_memDissectBuf      — Buffer holding current read, or 0
;   g_memDissectHistory  — Array of past addresses (back stack)
;   g_memDissectFwd      — Array of forward addresses (forward stack)
;   g_memDissectStatus   — short status string for the UI
;
; Included by InGameStateMonitor.ahk.

; ── Public API ────────────────────────────────────────────────────────────

; Jump to an absolute address: reads g_memDissectSize bytes, updates the buffer,
; pushes the old address onto the back stack, and clears the forward stack.
; addr is an Int64. Returns a status string.
MemDissectGoto(addr)
{
    global g_memDissectAddress, g_memDissectHistory, g_memDissectFwd, g_memDissectStatus

    if (!addr || addr = 0)
    {
        g_memDissectStatus := "invalid-address"
        return g_memDissectStatus
    }

    ; Push old address to history before the jump (skip if same address — refresh)
    if (g_memDissectAddress && g_memDissectAddress != addr)
    {
        g_memDissectHistory.Push(g_memDissectAddress)
        ; Cap history at 64 entries
        while (g_memDissectHistory.Length > 64)
            g_memDissectHistory.RemoveAt(1)
        g_memDissectFwd := []   ; new jump clears forward stack
    }

    return _MemDissectReadAt(addr)
}

; Resolve a named symbol (same set as MemDiff) and jump to it.
; customAddr is an Int64 only used when symbol = "Custom".
MemDissectGotoSymbol(symbol, customAddr := 0)
{
    global g_memDissectStatus
    addr := MemDiffResolveSymbol(symbol, customAddr)
    if (!addr)
    {
        g_memDissectStatus := "unresolved-symbol(" symbol ")"
        return g_memDissectStatus
    }
    return MemDissectGoto(addr)
}

; Navigate back to the previously visited address.
; Pushes the current address onto the forward stack.
MemDissectBack()
{
    global g_memDissectAddress, g_memDissectHistory, g_memDissectFwd, g_memDissectStatus
    if (g_memDissectHistory.Length = 0)
    {
        g_memDissectStatus := "no-history"
        return g_memDissectStatus
    }
    if (g_memDissectAddress)
        g_memDissectFwd.Push(g_memDissectAddress)
    return _MemDissectReadAt(g_memDissectHistory.Pop())
}

; Navigate forward (undo a Back).
; Pushes the current address onto the back stack.
MemDissectForward()
{
    global g_memDissectAddress, g_memDissectHistory, g_memDissectFwd, g_memDissectStatus
    if (g_memDissectFwd.Length = 0)
    {
        g_memDissectStatus := "no-forward"
        return g_memDissectStatus
    }
    if (g_memDissectAddress)
        g_memDissectHistory.Push(g_memDissectAddress)
    return _MemDissectReadAt(g_memDissectFwd.Pop())
}

; Re-read the current address without touching the navigation stacks.
MemDissectReread()
{
    global g_memDissectAddress, g_memDissectStatus
    if (!g_memDissectAddress)
    {
        g_memDissectStatus := "no-address"
        return g_memDissectStatus
    }
    return _MemDissectReadAt(g_memDissectAddress)
}

; ── Internal ──────────────────────────────────────────────────────────────

; Reads g_memDissectSize bytes at addr and updates the global buffer + status.
; Does NOT touch the history or forward stacks — callers manage those.
_MemDissectReadAt(addr)
{
    global g_reader, g_memDissectAddress, g_memDissectSize, g_memDissectBuf, g_memDissectStatus

    if !(IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle)
    {
        g_memDissectStatus := "not-connected"
        return g_memDissectStatus
    }

    sz  := g_memDissectSize
    buf := _MemDissectPageAwareRead(addr, sz)
    if !buf
    {
        g_memDissectStatus := "read-failed @ 0x" Format("{:X}", addr)
        return g_memDissectStatus
    }

    g_memDissectAddress := addr
    g_memDissectBuf     := buf
    g_memDissectStatus  := (buf.Size = sz) ? "ok" : ("ok partial " buf.Size " B / " sz)
    return g_memDissectStatus
}

; Reads up to `maxSize` bytes starting at `addr` while gracefully handling
; the case where the requested range straddles an uncommitted memory page.
; Strategy: read the first chunk only up to the next 4 KB boundary, then
; extend page-by-page until the requested size is met or a read fails.
;
; ReadProcessMemory's behaviour when a range crosses a committed →
; uncommitted boundary is version-dependent — on some Windows versions it
; returns the partial bytes, on others it fails the whole call with
; bytesRead=0. By splitting the request along page boundaries we get
; deterministic "largest contiguous prefix" semantics regardless.
;
; Returns: Buffer of size ≤ maxSize (≥ 1) on success, 0 if even the first
; byte at `addr` is unreadable.
_MemDissectPageAwareRead(addr, maxSize)
{
    global g_reader
    if (!addr || maxSize <= 0)
        return 0

    pageSize := 0x1000

    ; First chunk = bytes from addr to the next page boundary, capped at maxSize.
    firstChunkSize := pageSize - Mod(addr, pageSize)
    if (firstChunkSize > maxSize)
        firstChunkSize := maxSize

    firstBuf := g_reader.Mem.ReadBytes(addr, firstChunkSize, true)
    if !firstBuf
        return 0   ; even the first page slice unreadable

    totalRead := firstBuf.Size
    ; If we already have everything, done.
    if (totalRead >= maxSize)
        return firstBuf
    ; If the first chunk was short, no point continuing — boundary hit.
    if (totalRead < firstChunkSize)
        return firstBuf

    ; Allocate result buffer at the full requested size and copy the prefix.
    ; We'll trim it down at the end if we couldn't fill it.
    result := Buffer(maxSize, 0)
    DllCall("RtlMoveMemory", "Ptr", result.Ptr, "Ptr", firstBuf.Ptr, "UPtr", totalRead)

    nextAddr := addr + totalRead
    while (totalRead < maxSize)
    {
        chunkSize := pageSize
        if (totalRead + chunkSize > maxSize)
            chunkSize := maxSize - totalRead

        chunkBuf := g_reader.Mem.ReadBytes(nextAddr, chunkSize, true)
        if !chunkBuf
            break   ; hit unmapped page

        DllCall("RtlMoveMemory", "Ptr", result.Ptr + totalRead, "Ptr", chunkBuf.Ptr, "UPtr", chunkBuf.Size)
        totalRead += chunkBuf.Size
        nextAddr  += chunkBuf.Size

        ; Short read inside the chunk also means we hit a boundary.
        if (chunkBuf.Size < chunkSize)
            break
    }

    ; If we filled the full request, return the result buffer as-is.
    if (totalRead >= maxSize)
        return result

    ; Otherwise return a tightly-sized buffer containing what we did read.
    trimmed := Buffer(totalRead, 0)
    DllCall("RtlMoveMemory", "Ptr", trimmed.Ptr, "Ptr", result.Ptr, "UPtr", totalRead)
    return trimmed
}

; Parses a hex/decimal address string into an Int64. Returns 0 on failure.
; Accepts: "0x1A2B3C", "1A2B3C" (assumed hex if hex chars present), or decimal.
; AHK v2's Integer() understands the "0x..." prefix natively, but throws on
; invalid input — we swallow that and fall back to a manual hex walk so the
; bridge never propagates a parse failure that wedges the dispatcher.
_ParseHexAddr(s)
{
    s := Trim(String(s))
    if (s = "")
        return 0
    ; Try AHK's native Integer() first — handles "0x..." and decimals directly.
    try
    {
        v := Integer(s)
        if (v != 0 || s = "0")
            return v
    }
    catch
    {
        ; fall through to manual hex parse below
    }
    ; Manual hex parse for safety: strip optional 0x, then walk digits.
    hex := s
    if (SubStr(hex, 1, 2) = "0x" || SubStr(hex, 1, 2) = "0X")
        hex := SubStr(hex, 3)
    hex := StrUpper(hex)
    out := 0
    i := 1
    n := StrLen(hex)
    while (i <= n)
    {
        c  := SubStr(hex, i, 1)
        cc := Ord(c)
        if (cc >= 48 && cc <= 57)
            d := cc - 48
        else if (cc >= 65 && cc <= 70)
            d := cc - 55
        else
            return 0   ; unknown char: bail
        out := out * 16 + d
        i += 1
    }
    return out
}

; Wrapper used by the bridge dispatcher: runs the supplied operation, catches
; any exception (logging it to error.log), then always pushes the latest
; dissector state to the WebView so the UI reflects any status change — even
; when the read failed.
_SafeDissect(opFn, label)
{
    global g_memDissectStatus
    try
    {
        opFn.Call()
    }
    catch as ex
    {
        msg := ex.HasOwnProp("Message") ? ex.Message : "?"
        g_memDissectStatus := label "-exception: " msg
        try LogError(label " exception: " msg)
    }
    ; Final push wrapped with explicit catch — `try Foo()` (no catch) is OK
    ; in AHK v2 but a paired try/catch makes the intent unambiguous and lets
    ; us log any push-side failure rather than silently swallowing it.
    try
    {
        PushMemDissectToWebView()
    }
    catch as ex2
    {
        try LogError(label " push exception: " (ex2.HasOwnProp("Message") ? ex2.Message : "?"))
    }
}
