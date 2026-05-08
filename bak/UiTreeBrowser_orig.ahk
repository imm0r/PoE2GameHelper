; UiTreeBrowser.ahk
; Recursiver UI-Element-Baum-Browser.
;
; Funktionen:
;   UiTree_Dump(reader, gameUiPtr, maxDepth, outPath)
;       -> Traversiert den gesamten UI-Baum ab gameUiPtr und schreibt
;         alle StringIds + Pfade in eine TSV-Datei.
;
;   UiTree_FindByPath(reader, gameUiPtr, pathString)
;       -> Navigiert zu einem Element anhand eines Pfads wie
;         "Skills > [0] > SomeChild" und gibt die Adresse zurueck.
;
;   UiTree_ReadElement(reader, elemPtr)
;       -> Liest alle Properties eines einzelnen Elements (wie im C#-Browser)
;         und gibt eine Map zurueck.
;
; Verwendung (einmalig beim Start oder per Hotkey):
;   #Include UiTreeBrowser.ahk
;   outFile := UiTree_Dump(g_reader, activeGameUiPtr)
;   MsgBox "Dump gespeichert: " outFile
;
; Inkludiert von: InGameStateMonitor.ahk (oder manuell per #Include)

; -- Haupt-Dump-Funktion -------------------------------------------------------
; Traversiert den UI-Baum ab gameUiPtr (BFS) und schreibt alle Elemente als TSV.
; Params:
;   reader      - PoE2GameStateReader-Instanz (braucht .Mem und String-Reader)
;   gameUiPtr   - Startpunkt (GameUiPtr oder UiRootPtr aus UiRootStruct)
;   maxDepth    - Maximale Tiefe (default 12, reicht fuer alle bekannten Panels)
;   outPath     - Ausgabedatei (default: ScriptDir\debug\ui_tree_<timestamp>.tsv)
; Returns: Pfad zur geschriebenen Datei, oder "" bei Fehler.
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

    ; TSV-Header
    header := "Depth`tPath`tStringId`tAddress`tVisible`tChildCount`tScreenX`tScreenY`tSizeW`tSizeH`tFlags`n"

    ; BFS-Queue: [{ptr, depth, parentPath}]
    queue := [{ ptr: gameUiPtr, depth: 0, parentPath: "" }]
    rows := []
    visited := Map()   ; ptr -> true, verhindert Zyklen (falls Baum korrupt ist)
    totalNodes := 0
    deadline := A_TickCount + 20000   ; max 20s fuer sehr grosse Baeume

    while (queue.Length > 0)
    {
        if (A_TickCount > deadline)
            break

        item := queue.RemoveAt(1)
        elemPtr := item.ptr
        depth := item.depth
        parentPath := item.parentPath

        if (visited.Has(elemPtr))
            continue
        visited[elemPtr] := true

        ; Element lesen
        elem := UiTree_ReadElement(reader, elemPtr)
        if !elem
            continue

        totalNodes += 1
        stringId := elem["stringId"]
        childCount := elem["childCount"]

        ; Pfad aufbauen - leer oder Index wenn keine StringId
        if (stringId != "")
            myPath := (parentPath = "") ? stringId : parentPath " > " stringId
        else
            myPath := parentPath   ; namenlose Elemente zeigen keinen eigenen Knoten

        ; Zeile schreiben
        rows.Push(
            depth "`t"
            . myPath "`t"
            . stringId "`t"
            . Format("0x{:X}", elemPtr) "`t"
            . (elem["isVisible"] ? "1" : "0") "`t"
            . childCount "`t"
            . Round(elem["screenX"], 1) "`t"
            . Round(elem["screenY"], 1) "`t"
            . Round(elem["sizeW"], 1) "`t"
            . Round(elem["sizeH"], 1) "`t"
            . Format("0x{:08X}", elem["flags"])
        )

        ; Kinder in Queue einschieben (wenn Tiefe erlaubt)
        if (depth < maxDepth && childCount > 0)
        {
            childFirst := elem["childFirst"]
            childLast := elem["childLast"]
            if (reader.IsProbablyValidPointer(childFirst) && childLast > childFirst)
            {
                numChildren := Min((childLast - childFirst) // A_PtrSize, 512)
                ; Batch-read alle Kind-Pointer in einem RPM-Call
                ptrBuf := reader.Mem.ReadBytes(childFirst, numChildren * A_PtrSize)
                if ptrBuf
                {
                    Loop numChildren
                    {
                        childPtr := NumGet(ptrBuf.Ptr, (A_Index - 1) * A_PtrSize, "Ptr")
                        if (reader.IsProbablyValidPointer(childPtr) && !visited.Has(childPtr))
                        {
                            ; Index in Pfad nur wenn Kind keine eigene StringId hat
                            ; (wird spaeter beim Lesen des Kinds aufgeloest)
                            queue.Push({
                                ptr: childPtr,
                                depth: depth + 1,
                                parentPath: myPath
                            })
                        }
                    }
                }
            }
        }
    }

    ; Datei schreiben
    try
    {
        content := header
        for _, row in rows
            content .= row "`n"
        FileAppend(content, outPath, "UTF-8")
        return outPath
    }
    catch
        return ""
}

; -- Einzelnes Element vollstaendig lesen --------------------------------------
; Entspricht dem "Element Properties"-Panel im C#-Browser.
; Params:
;   reader  - PoE2GameStateReader-Instanz
;   elemPtr - Adresse des UiElements
; Returns: Map mit allen Properties, oder 0 bei ungueltigem Pointer.
UiTree_ReadElement(reader, elemPtr)
{
    if (!IsObject(reader) || !reader.IsProbablyValidPointer(elemPtr))
        return 0

    offsets := PoE2Offsets.UiElementBase

    ; Batch-Read: kompletten Element-Header (0x2A0 Bytes) in einem RPM-Call
    ; Deckt alle bekannten Offsets ab (StringIdPtr @ 0x140, Flags @ 0x180, UnscaledSize @ 0x288 usw.)
    headerSize := 0x2A0
    hdr := reader.Mem.ReadBytes(elemPtr, headerSize)
    if !hdr
        return 0

    ; -- Children StdVector (0x010: first, 0x018: last) ---------------------
    childFirst := NumGet(hdr.Ptr, 0x010, "Ptr")
    childLast := NumGet(hdr.Ptr, 0x018, "Ptr")
    childCount := 0
    if (reader.IsProbablyValidPointer(childFirst) && childLast > childFirst)
        childCount := Min((childLast - childFirst) // A_PtrSize, 4096)

    ; -- Parent (0x0B8) -----------------------------------------------------
    parentPtr := NumGet(hdr.Ptr, 0x0B8, "Ptr")

    ; -- Position (0x118: RelativePosition float x,y) -----------------------
    relX := NumGet(hdr.Ptr, 0x118, "Float")
    relY := NumGet(hdr.Ptr, 0x11C, "Float")

    ; -- Scale (0x130: LocalScaleMultiplier, 0x18A: ScaleIndex) -------------
    localMult := NumGet(hdr.Ptr, 0x130, "Float")
    scaleIndex := NumGet(hdr.Ptr, 0x18A, "UChar")

    ; -- StringId (0x140: StdWString) ----------------------------------------
    ; StdWString liegt direkt inline (nicht als Pointer) - wir lesen die
    ; StdWString-Struktur ab offset 0x140 des Elements selbst.
    stringId := reader.ReadStdWStringAt(elemPtr + offsets["StringIdPtr"])

    ; -- Flags (0x180) -------------------------------------------------------
    flags := NumGet(hdr.Ptr, 0x180, "UInt")
    isVisible := ((flags >> 11) & 1) ? true : false
    shouldModifyPos := ((flags >> 10) & 1) ? true : false

    ; -- UnscaledSize (0x288: float W, 0x28C: float H) ----------------------
    sizeW := NumGet(hdr.Ptr, 0x288, "Float")
    sizeH := NumGet(hdr.Ptr, 0x28C, "Float")

    ; -- Position Modifier (0x0F0) -------------------------------------------
    posModX := NumGet(hdr.Ptr, 0x0F0, "Float")
    posModY := NumGet(hdr.Ptr, 0x0F4, "Float")

    ; -- Background / Text / Border Color (0x25C, 0x26C, 0x27C) ------------
    bgR := NumGet(hdr.Ptr, 0x25C, "Float")
    bgG := NumGet(hdr.Ptr, 0x260, "Float")
    bgB := NumGet(hdr.Ptr, 0x264, "Float")
    bgA := NumGet(hdr.Ptr, 0x268, "Float")

    ; -- Vtable (erster Eintrag @ 0x000) ------------------------------------
    vtable := NumGet(hdr.Ptr, 0x000, "Ptr")

    ; -- Screen-Position berechnen (vereinfacht: nur eigene RelPos) ---------
    ; Fuer exakte Screen-Pos muesste man die Parent-Chain hochlaufen wie in
    ; ReadMapUiElementData() - hier geben wir RelPos als Naeherung aus.
    ; Wer die exakte Screen-Pos braucht: UiTree_GetScreenPos(reader, elemPtr)
    screenX := relX
    screenY := relY

    return Map(
        "address", elemPtr,
        "stringId", stringId,
        "isVisible", isVisible,
        "shouldModifyPos", shouldModifyPos,
        "flags", flags,
        "childCount", childCount,
        "childFirst", childFirst,
        "childLast", childLast,
        "parentPtr", parentPtr,
        "relX", relX,
        "relY", relY,
        "screenX", screenX,
        "screenY", screenY,
        "sizeW", sizeW,
        "sizeH", sizeH,
        "localMult", localMult,
        "scaleIndex", scaleIndex,
        "posModX", posModX,
        "posModY", posModY,
        "bgColor", Map("r", bgR, "g", bgG, "b", bgB, "a", bgA),
        "vtable", vtable
    )
}

; -- Pfad-Navigation -----------------------------------------------------------
; Navigiert den UI-Baum anhand eines StringId-Pfads.
; Pfad-Format: "Skills" oder "LeftPanel > InventoryPanel > Grid"
;   - Jedes Segment ist eine StringId
;   - "[N]" navigiert zum N-ten Kind (0-basiert), unabhaengig von StringId
;
; Beispiele:
;   addr := UiTree_FindByPath(g_reader, gameUiPtr, "Skills")
;   addr := UiTree_FindByPath(g_reader, gameUiPtr, "LeftPanel > InventoryPanel")
;   addr := UiTree_FindByPath(g_reader, gameUiPtr, "LeftPanel > [0] > Label")
;
; Returns: Adresse des gefundenen Elements, oder 0 wenn nicht gefunden.
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

        ; Index-Segment: "[N]" -> N-tes Kind
        if (SubStr(segment, 1, 1) = "[" && SubStr(segment, -1) = "]")
        {
            idx := Integer(SubStr(segment, 2, StrLen(segment) - 2))
            currentPtr := UiTree_GetChildByIndex(reader, currentPtr, idx)
        }
        else
        {
            ; StringId-Segment: suche Kind mit passender StringId
            currentPtr := UiTree_GetChildByStringId(reader, currentPtr, segment)
        }

        if !reader.IsProbablyValidPointer(currentPtr)
            return 0
    }

    return currentPtr
}

; -- Hilfsfunktion: Kind per StringId finden -----------------------------------
UiTree_GetChildByStringId(reader, elemPtr, targetId)
{
    if (!reader.IsProbablyValidPointer(elemPtr))
        return 0

    hdr := reader.Mem.ReadBytes(elemPtr, 0x20)
    if !hdr
        return 0

    childFirst := NumGet(hdr.Ptr, 0x010, "Ptr")
    childLast := NumGet(hdr.Ptr, 0x018, "Ptr")
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

; -- Hilfsfunktion: Kind per Index ---------------------------------------------
UiTree_GetChildByIndex(reader, elemPtr, idx)
{
    if (!reader.IsProbablyValidPointer(elemPtr))
        return 0

    hdr := reader.Mem.ReadBytes(elemPtr, 0x20)
    if !hdr
        return 0

    childFirst := NumGet(hdr.Ptr, 0x010, "Ptr")
    childLast := NumGet(hdr.Ptr, 0x018, "Ptr")
    if (!reader.IsProbablyValidPointer(childFirst) || childLast <= childFirst)
        return 0

    numChildren := (childLast - childFirst) // A_PtrSize
    if (idx < 0 || idx >= numChildren)
        return 0

    ptrBuf := reader.Mem.ReadBytes(childFirst + idx * A_PtrSize, A_PtrSize)
    return ptrBuf ? NumGet(ptrBuf.Ptr, 0, "Ptr") : 0
}

; -- Exakte Screen-Position (Parent-Chain-Traversal) ---------------------------
; Wie ReadMapUiElementData() - akkumuliert RelativePosition die Parent-Chain hoch.
; Gibt {x, y} in UI-Koordinaten (2560?1600 Basis) zurueck.
UiTree_GetScreenPos(reader, elemPtr)
{
    chain := []
    curPtr := elemPtr
    Loop 16
    {
        if !reader.IsProbablyValidPointer(curPtr)
            break
        hdr := reader.Mem.ReadBytes(curPtr, 0x200)
        if !hdr
            break
        relX := NumGet(hdr.Ptr, 0x118, "Float")
        relY := NumGet(hdr.Ptr, 0x11C, "Float")
        flags := NumGet(hdr.Ptr, 0x180, "UInt")
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
    Loop N - 1
    {
        childIdx := N - A_Index
        parentIdx := childIdx + 1
        child := chain[childIdx]
        parent := chain[parentIdx]
        if (child["flags"] >> 10) & 1
        {
            accX += parent["posModX"]
            accY += parent["posModY"]
        }
        accX += child["relX"]
        accY += child["relY"]
    }
    return Map("x", accX, "y", accY)
}