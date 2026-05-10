; UiTreeBrowser.ahk
; Recursive UI element tree walker and navigator

; Dump entire UI tree starting from gameUiPtr to a TSV file.
; Returns: path to written file, or "" on error.
UiTree_Dump(reader, gameUiPtr, maxDepth := 12, outPath := "")
{
    if (!IsObject(reader) || !reader.IsProbablyValidPointer(gameUiPtr))
        return ""
    if (outPath = "")
    {
        debugDir := A_ScriptDir "\debug"
        if !DirExist(debugDir)
            DirCreate(debugDir)
        stamp := FormatTime(, "yyyyMMdd_HHmmss")
        outPath := debugDir "\ui_tree_" stamp ".tsv"
    }
    header := "Depth`tPath`tStringId`tAddress`tVisible`tChildCount`tScreenX`tScreenY`tSizeW`tSizeH`tFlags`n"
    queue   := [{ptr: gameUiPtr, depth: 0, parentPath: ""}]
    rows    := []
    visited := Map()
    deadline := A_TickCount + 20000
    while (queue.Length > 0)
    {
        if (A_TickCount > deadline)
            break
        item     := queue.RemoveAt(1)
        elemPtr  := item.ptr
        depth    := item.depth
        parentPath := item.parentPath
        if (visited.Has(elemPtr))
            continue
        visited[elemPtr] := true
        elem := UiTree_ReadElement(reader, elemPtr)
        if !elem
            continue
        stringId   := elem["stringId"]
        childCount := elem["childCount"]
        if (stringId != "")
            myPath := (parentPath = "") ? stringId : parentPath " > " stringId
        else
            myPath := parentPath
        rows.Push(
            depth . "`t"
            . myPath . "`t"
            . stringId . "`t"
            . Format("0x{:X}", elemPtr) . "`t"
            . (elem["isVisible"] ? "1" : "0") . "`t"
            . childCount . "`t"
            . Round(elem["screenX"], 1) . "`t"
            . Round(elem["screenY"], 1) . "`t"
            . Round(elem["sizeW"], 1) . "`t"
            . Round(elem["sizeH"], 1) . "`t"
            . Format("0x{:08X}", elem["flags"])
        )
        if (depth < maxDepth && childCount > 0)
        {
            childFirst := elem["childFirst"]
            childLast  := elem["childLast"]
            if (reader.IsProbablyValidPointer(childFirst) && childLast > childFirst)
            {
                numChildren := Min((childLast - childFirst) // A_PtrSize, 512)
                ptrBuf := reader.Mem.ReadBytes(childFirst, numChildren * A_PtrSize)
                if ptrBuf
                {
                    Loop numChildren
                    {
                        childPtr := NumGet(ptrBuf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
                        if (reader.IsProbablyValidPointer(childPtr) && !visited.Has(childPtr))
                            queue.Push({ptr: childPtr, depth: depth + 1, parentPath: myPath})
                    }
                }
            }
        }
    }
    try
    {
        content := header
        for _, row in rows
            content .= row . "`n"
        FileAppend(content, outPath, "UTF-8")
        return outPath
    }
    catch
        return ""
}

; Read all properties of a single UI element in one batch RPM call.
; Returns: Map with all properties, or 0 on invalid pointer.
UiTree_ReadElement(reader, elemPtr)
{
    if (!IsObject(reader) || !reader.IsProbablyValidPointer(elemPtr))
        return 0
    headerSize := 0x2A0
    hdr := reader.Mem.ReadBytes(elemPtr, headerSize)
    if !hdr
        return 0
    childFirst := NumGet(hdr.Ptr, 0x010, "Ptr")
    childLast  := NumGet(hdr.Ptr, 0x018, "Ptr")
    childCount := 0
    if (reader.IsProbablyValidPointer(childFirst) && childLast > childFirst)
        childCount := Min((childLast - childFirst) // A_PtrSize, 4096)
    parentPtr  := NumGet(hdr.Ptr, 0x0B8, "Ptr")
    relX       := NumGet(hdr.Ptr, 0x118, "Float")
    relY       := NumGet(hdr.Ptr, 0x11C, "Float")
    localMult  := NumGet(hdr.Ptr, 0x130, "Float")
    scaleIndex := NumGet(hdr.Ptr, 0x18A, "UChar")
    stringId   := reader.ReadStdWStringAt(elemPtr + PoE2Offsets.UiElementBase["StringIdPtr"])
    flags      := NumGet(hdr.Ptr, 0x180, "UInt")
    isVisible  := ((flags >> 11) & 1) ? true : false
    sizeW      := NumGet(hdr.Ptr, 0x288, "Float")
    sizeH      := NumGet(hdr.Ptr, 0x28C, "Float")
    posModX    := NumGet(hdr.Ptr, 0x0F0, "Float")
    posModY    := NumGet(hdr.Ptr, 0x0F4, "Float")
    vtable     := NumGet(hdr.Ptr, 0x000, "Ptr")
    return Map(
        "address",     elemPtr,
        "stringId",    stringId,
        "isVisible",   isVisible,
        "flags",       flags,
        "childCount",  childCount,
        "childFirst",  childFirst,
        "childLast",   childLast,
        "parentPtr",   parentPtr,
        "relX",        relX,
        "relY",        relY,
        "screenX",     relX,
        "screenY",     relY,
        "sizeW",       sizeW,
        "sizeH",       sizeH,
        "localMult",   localMult,
        "scaleIndex",  scaleIndex,
        "posModX",     posModX,
        "posModY",     posModY,
        "vtable",      vtable
    )
}

; Probe an element header for StdWStrings at every 8-byte aligned offset.
; Returns: Array of Maps {offset, value} for offsets where a non-empty plausible
; StdWString was decoded. Used to locate the correct StringId offset after a game
; patch shifts struct layouts.
UiTree_ProbeStrings(reader, elemPtr, scanRange := 0x400)
{
    results := []
    if (!IsObject(reader) || !reader.IsProbablyValidPointer(elemPtr))
        return results
    ; Read enough bytes to cover the entire scan range plus 0x20 for the last StdWString header.
    totalBytes := scanRange + 0x20
    hdr := reader.Mem.ReadBytes(elemPtr, totalBytes)
    if !hdr
        return results
    off := 0
    while (off + 0x20 <= totalBytes)
    {
        bufferOrInline := NumGet(hdr.Ptr, off + 0x00, "Int64")
        length         := NumGet(hdr.Ptr, off + 0x10, "Int")
        capacity       := NumGet(hdr.Ptr, off + 0x18, "Int")
        ; StdWString plausibility filter: small length, capacity >= length,
        ; capacity is one of 7 (default SSO) or higher.
        if (length > 0 && length <= 256 && capacity >= length && capacity <= 4096)
        {
            try
            {
                str := reader.ReadStdWStringAt(elemPtr + off, 256)
                ; Reject non-printable / empty results
                if (str != "" && _UibIsPrintable(str))
                    results.Push(Map("offset", off, "value", str))
            }
            catch
            {
                ; ignore
            }
        }
        off += 8
    }
    return results
}

; Helper: returns true if string contains only printable ASCII / common whitespace.
_UibIsPrintable(str)
{
    if (str = "")
        return false
    Loop Parse, str
    {
        c := Ord(A_LoopField)
        if (c < 32 || c > 126)
            return false
    }
    return true
}

; Navigate by StringId path like "LeftPanel > InventoryPanel"
; or index path like "[0] > [3]"
; Returns: address of found element, or 0.
UiTree_FindByPath(reader, gameUiPtr, pathString)
{
    if (!IsObject(reader) || !reader.IsProbablyValidPointer(gameUiPtr) || pathString = "")
        return 0
    segments := StrSplit(pathString, " > ")
    currentPtr := gameUiPtr
    for _, segment in segments
    {
        segment := Trim(segment)
        if (segment = "")
            continue
        if (SubStr(segment, 1, 1) = "[" && SubStr(segment, -1) = "]")
        {
            idx := Integer(SubStr(segment, 2, StrLen(segment) - 2))
            currentPtr := UiTree_GetChildByIndex(reader, currentPtr, idx)
        }
        else
            currentPtr := UiTree_GetChildByStringId(reader, currentPtr, segment)
        if !reader.IsProbablyValidPointer(currentPtr)
            return 0
    }
    return currentPtr
}

; Find child by StringId.
UiTree_GetChildByStringId(reader, elemPtr, targetId)
{
    if (!reader.IsProbablyValidPointer(elemPtr))
        return 0
    hdr := reader.Mem.ReadBytes(elemPtr, 0x20)
    if !hdr
        return 0
    childFirst := NumGet(hdr.Ptr, 0x010, "Ptr")
    childLast  := NumGet(hdr.Ptr, 0x018, "Ptr")
    if (!reader.IsProbablyValidPointer(childFirst) || childLast <= childFirst)
        return 0
    numChildren := Min((childLast - childFirst) // A_PtrSize, 512)
    ptrBuf := reader.Mem.ReadBytes(childFirst, numChildren * A_PtrSize)
    if !ptrBuf
        return 0
    Loop numChildren
    {
        childPtr := NumGet(ptrBuf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
        if !reader.IsProbablyValidPointer(childPtr)
            continue
        sid := reader.ReadStdWStringAt(childPtr + PoE2Offsets.UiElementBase["StringIdPtr"])
        if (sid = targetId)
            return childPtr
    }
    return 0
}

; Find child by index (0-based).
UiTree_GetChildByIndex(reader, elemPtr, idx)
{
    if (!reader.IsProbablyValidPointer(elemPtr))
        return 0
    hdr := reader.Mem.ReadBytes(elemPtr, 0x20)
    if !hdr
        return 0
    childFirst := NumGet(hdr.Ptr, 0x010, "Ptr")
    childLast  := NumGet(hdr.Ptr, 0x018, "Ptr")
    if (!reader.IsProbablyValidPointer(childFirst) || childLast <= childFirst)
        return 0
    numChildren := (childLast - childFirst) // A_PtrSize
    if (idx < 0 || idx >= numChildren)
        return 0
    ptrBuf := reader.Mem.ReadBytes(childFirst + idx * A_PtrSize, A_PtrSize)
    return ptrBuf ? NumGet(ptrBuf.Ptr, 0, "Ptr") : 0
}

; Get exact screen position by walking parent chain.
UiTree_GetScreenPos(reader, elemPtr)
{
    chain := []
    curPtr := elemPtr
    Loop 16 {
        if !reader.IsProbablyValidPointer(curPtr)
            break
        hdr := reader.Mem.ReadBytes(curPtr, 0x200)
        if !hdr
            break
        relX    := NumGet(hdr.Ptr, 0x118, "Float")
        relY    := NumGet(hdr.Ptr, 0x11C, "Float")
        flags   := NumGet(hdr.Ptr, 0x180, "UInt")
        posModX := NumGet(hdr.Ptr, 0x0F0, "Float")
        posModY := NumGet(hdr.Ptr, 0x0F4, "Float")
        parentP := NumGet(hdr.Ptr, 0x0B8, "Ptr")
        chain.Push(Map("relX", relX, "relY", relY, "flags", flags, "posModX", posModX, "posModY", posModY))
        if !reader.IsProbablyValidPointer(parentP)
            break
        curPtr := parentP
    }
    N := chain.Length
    if (N = 0)
        return Map("x", 0.0, "y", 0.0)
    accX := chain[N]["relX"]
    accY := chain[N]["relY"]
    Loop N - 1 {
        childIdx  := N - A_Index
        parentIdx := childIdx + 1
        child  := chain[childIdx]
        parent := chain[parentIdx]
        if (child["flags"] >> 10) & 1 {
            accX += parent["posModX"]
            accY += parent["posModY"]
        }
        accX += child["relX"]
        accY += child["relY"]
    }
    return Map("x", accX, "y", accY)
}
