#Requires AutoHotkey v2.0
#Include PoE2MemoryReader.ahk

class GgpkMemoryMonitor
{
    __New(reader)
    {
        this.Reader := reader
        this.IsRunning := false
        this.KnownStrings := Map()
        this.StringPatternsByFirstWord := Map()
        this.DiscoveredStringAddresses := Map()
        this.StringStructureMap := Map()
        this.Discoveries := []
        this.LastScanTime := ""
        this.IntervalMs := 3000
        this.MaxScanBytes := 50 * 1024 * 1024
        this.TickFn := ObjBindMethod(this, "MonitoringTick")
        this.LastError := ""
        this.OnLog := 0
    }

    SetLogger(logFn)
    {
        this.OnLog := logFn
    }

    Log(text)
    {
        if (this.OnLog)
        {
            try this.OnLog.Call(text)
            catch
            {
            }
        }
    }

    Initialize(knownStrings)
    {
        this.KnownStrings := Map()
        this.StringPatternsByFirstWord := Map()
        this.DiscoveredStringAddresses.Clear()
        this.StringStructureMap.Clear()
        this.Discoveries := []

        added := 0
        if (Type(knownStrings) = "Array")
        {
            for str in knownStrings
            {
                if this.AddKnownString(str)
                    added += 1
            }
        }
        else if (Type(knownStrings) = "Map")
        {
            for str, _ in knownStrings
            {
                if this.AddKnownString(str)
                    added += 1
            }
        }

        this.BuildStringPatterns()
        this.Log("[GGPK] Initialized with " added " known strings")
        return added
    }

    InitializeFromGgpkExport(jsonFilePath := "")
    {
        if (jsonFilePath = "")
        {
            uiOnly := A_ScriptDir "\ggpk_ui_files_only.json"
            full := A_ScriptDir "\ggpk_directory_tree.json"
            if FileExist(uiOnly)
                jsonFilePath := uiOnly
            else if FileExist(full)
                jsonFilePath := full
        }

        if (jsonFilePath = "" || !FileExist(jsonFilePath))
        {
            this.LastError := "GGPK export JSON not found"
            this.Log("[GGPK] ❌ " this.LastError)
            return false
        }

        localSet := Map()
        pathCount := 0

        Loop Read, jsonFilePath
        {
            line := A_LoopReadLine
            if RegExMatch(line, 'i)"path"\s*:\s*"((?:\\.|[^"])*)"', &m)
            {
                rawPath := m[1]
                path := this.UnescapeJsonString(rawPath)
                if this.AddPathDerivedStrings(localSet, path)
                    pathCount += 1
            }
        }

        knownArr := []
        for str, _ in localSet
            knownArr.Push(str)

        this.Initialize(knownArr)
        this.Log("[GGPK] ✅ Loaded " knownArr.Length " unique known strings from " jsonFilePath)
        return knownArr.Length > 0
    }

    StartMonitoring(intervalMs := 3000)
    {
        if this.IsRunning
            return true

        if (!this.Reader || !this.Reader.Mem)
        {
            this.LastError := "Reader is not configured"
            this.Log("[GGPK] ❌ " this.LastError)
            return false
        }

        if (this.KnownStrings.Count = 0)
        {
            if !this.InitializeFromGgpkExport()
            {
                this.LastError := "No known strings loaded"
                this.Log("[GGPK] ❌ " this.LastError)
                return false
            }
        }

        if (!this.Reader.Mem.Handle)
        {
            if !this.Reader.Connect(false)
            {
                this.LastError := "Reader connection failed"
                this.Log("[GGPK] ❌ " this.LastError)
                return false
            }
        }

        this.IntervalMs := Max(500, intervalMs)
        this.IsRunning := true
        SetTimer(this.TickFn, this.IntervalMs)
        this.Log("[GGPK] ✅ Monitoring started (" this.IntervalMs " ms)")
        return true
    }

    StopMonitoring()
    {
        this.IsRunning := false
        SetTimer(this.TickFn, 0)
        this.Log("[GGPK] ⏹️ Monitoring stopped")
    }

    MonitoringTick()
    {
        if !this.IsRunning
            return

        try
        {
            if (!this.Reader || !this.Reader.Mem || !this.Reader.Mem.Handle)
                return

            snapshot := this.Reader.ReadSnapshot()
            if !snapshot
                return

            if !snapshot.Has("currentStateName") || snapshot["currentStateName"] != "InGameState"
                return

            inGame := snapshot.Has("inGameState") ? snapshot["inGameState"] : 0
            if !inGame
                return

            if (inGame.Has("activeGameUiPtr") && this.Reader.IsProbablyValidPointer(inGame["activeGameUiPtr"]))
                this.ScanForGgpkStrings(inGame["activeGameUiPtr"], 2 * 1024 * 1024, "UIRoot")

            if (inGame.Has("uiRootPtr") && this.Reader.IsProbablyValidPointer(inGame["uiRootPtr"]))
                this.ScanForGgpkStrings(inGame["uiRootPtr"], 1024 * 1024, "UiRootPtr")

            areaInst := inGame.Has("areaInstance") ? inGame["areaInstance"] : 0
            if (areaInst && areaInst.Has("localPlayerPtr") && this.Reader.IsProbablyValidPointer(areaInst["localPlayerPtr"]))
                this.ScanForGgpkStrings(areaInst["localPlayerPtr"], 256 * 1024, "PlayerEntity")

            this.LastScanTime := A_Now
        }
        catch as ex
        {
            this.LastError := ex.Message
            this.Log("[GGPK] Error in monitoring tick: " ex.Message)
        }
    }

    ScanForGgpkStrings(baseAddress, scanRange, context := "Manual")
    {
        if (!this.Reader || !this.Reader.Mem || !this.Reader.Mem.Handle)
            return 0

        if (this.StringPatternsByFirstWord.Count = 0)
            return 0

        startAddr := baseAddress - scanRange
        if (startAddr < 0)
            startAddr := 0
        endAddr := baseAddress + scanRange
        size := endAddr - startAddr

        if (size <= 0 || size > this.MaxScanBytes)
            return 0

        buffer := this.Reader.Mem.ReadBytes(startAddr, size, true)
        if (!buffer || Type(buffer) != "Buffer" || buffer.Size <= 2)
            return 0

        foundCount := 0
        newDiscoveries := []

        maxOffset := buffer.Size - 2
        offset := 0
        while (offset <= maxOffset)
        {
            firstWord := NumGet(buffer.Ptr, offset, "UShort")
            if this.StringPatternsByFirstWord.Has(firstWord)
            {
                patternList := this.StringPatternsByFirstWord[firstWord]
                for pat in patternList
                {
                    byteLen := pat["byteLen"]
                    if (offset + byteLen > buffer.Size)
                        continue

                    if !this.CompareBytes(buffer, offset, pat["bytes"], byteLen)
                        continue

                    stringAddr := startAddr + offset
                    if this.DiscoveredStringAddresses.Has(stringAddr)
                        continue

                    this.DiscoveredStringAddresses[stringAddr] := pat["str"]

                    parentPtr := this.FindParentPointer(stringAddr, startAddr)
                    offsetFromParent := ""
                    if (parentPtr)
                        offsetFromParent := stringAddr - parentPtr

                    disc := Map(
                        "knownString", pat["str"],
                        "memoryAddress", stringAddr,
                        "possibleParentAddress", parentPtr,
                        "offsetFromParent", offsetFromParent,
                        "context", context,
                        "timestamp", A_Now
                    )

                    this.Discoveries.Push(disc)
                    newDiscoveries.Push(disc)
                    foundCount += 1

                    structureInfo := Map(
                        "stringAddress", stringAddr,
                        "stringValue", pat["str"],
                        "parentPointer", parentPtr,
                        "offsetFromParent", offsetFromParent,
                        "discoveredAt", A_Now,
                        "structureBytes", 0
                    )

                    try
                    {
                        structureSize := Min(256, endAddr - stringAddr)
                        if (structureSize > 0)
                            structureInfo["structureBytes"] := this.Reader.Mem.ReadBytes(stringAddr, structureSize, true)
                    }
                    catch
                    {
                    }

                    this.StringStructureMap[stringAddr] := structureInfo
                }
            }

            offset += 2
        }

        if (foundCount > 0)
        {
            this.Log("[GGPK] ✅ Found " foundCount " new strings near 0x" this.Hex(baseAddress) " (" context ")")
            maxLog := Min(10, newDiscoveries.Length)
            loop maxLog
            {
                disc := newDiscoveries[A_Index]
                parentInfo := ""
                parent := disc["possibleParentAddress"]
                if (parent)
                    parentInfo := " (parent: 0x" this.Hex(parent) " +" disc["offsetFromParent"] ")"
                this.Log("  `"" disc["knownString"] "`" @ 0x" this.Hex(disc["memoryAddress"]) parentInfo)
            }
            if (newDiscoveries.Length > maxLog)
                this.Log("  ... and " (newDiscoveries.Length - maxLog) " more")
        }

        return foundCount
    }

    FindParentPointer(stringAddr, scanStart)
    {
        try
        {
            scanBackward := Min(512, stringAddr - scanStart)
            if (scanBackward < 8)
                return 0

            startScan := stringAddr - scanBackward
            buffer := this.Reader.Mem.ReadBytes(startScan, scanBackward, true)
            if (!buffer || Type(buffer) != "Buffer")
                return 0

            i := 0
            while (i <= buffer.Size - 8)
            {
                ptrValue := NumGet(buffer.Ptr, i, "Int64")
                if (ptrValue = stringAddr)
                {
                    pointerAddress := startScan + i
                    if (pointerAddress < stringAddr - 8)
                        return pointerAddress
                }
                i += 8
            }
        }
        catch
        {
        }

        return 0
    }

    GetDiscoveredStrings()
    {
        out := Map()
        for addr, str in this.DiscoveredStringAddresses
            out[addr] := str
        return out
    }

    GetDiscoveries(maxCount := 50)
    {
        out := []
        if (maxCount <= 0)
            return out

        idx := this.Discoveries.Length
        while (idx >= 1 && out.Length < maxCount)
        {
            out.Push(this.Discoveries[idx])
            idx -= 1
        }
        return out
    }

    GetStats()
    {
        return Map(
            "discoveredCount", this.DiscoveredStringAddresses.Count,
            "knownStrings", this.KnownStrings.Count,
            "lastScan", this.LastScanTime,
            "isMonitoring", this.IsRunning,
            "lastError", this.LastError
        )
    }

    ExportDiscoveries(filePath)
    {
        lines := []
        lines.Push("GGPK Memory Discovery Export - " FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss"))
        lines.Push("Total Discoveries: " this.Discoveries.Length)
        lines.Push("")

        for disc in this.Discoveries
        {
            parentInfo := ""
            parent := disc["possibleParentAddress"]
            if (parent)
                parentInfo := " | Parent: 0x" this.Hex(parent) " (offset: " disc["offsetFromParent"] ")"

            lines.Push("[" disc["timestamp"] "] " disc["context"] ":")
            lines.Push("  String: `"" disc["knownString"] "`"")
            lines.Push("  Address: 0x" this.Hex(disc["memoryAddress"]) parentInfo)
            lines.Push("")
        }

        text := ""
        for line in lines
            text .= line "`r`n"

        if FileExist(filePath)
            FileDelete(filePath)
        FileAppend(text, filePath, "UTF-8")
        this.Log("[GGPK] Exported " this.Discoveries.Length " discoveries to " filePath)
    }

    AddKnownString(str)
    {
        s := Trim(str)
        if (s = "" || StrLen(s) < 4)
            return false

        if this.KnownStrings.Has(s)
            return false

        this.KnownStrings[s] := true
        return true
    }

    AddPathDerivedStrings(localSet, path)
    {
        p := Trim(path)
        if (p = "")
            return false

        localSet[p] := true

        normalized := StrReplace(p, "\\", "/")
        for part in StrSplit(normalized, "/")
        {
            if (part != "" && StrLen(part) > 3)
                localSet[part] := true
        }

        name := p
        slashPos := InStr(name, "/",, -1)
        if (slashPos)
            name := SubStr(name, slashPos + 1)
        slashPos2 := InStr(name, "\\",, -1)
        if (slashPos2)
            name := SubStr(name, slashPos2 + 1)

        dotPos := InStr(name, ".",, -1)
        if (dotPos > 1)
        {
            baseName := SubStr(name, 1, dotPos - 1)
            if (baseName != "" && StrLen(baseName) > 3)
                localSet[baseName] := true
        }

        return true
    }

    UnescapeJsonString(raw)
    {
        s := raw
        s := StrReplace(s, "\/", "/")
        s := StrReplace(s, "\\\\", "\")
        s := StrReplace(s, '\"', '"')
        s := StrReplace(s, "\t", "`t")
        s := StrReplace(s, "\r", "`r")
        s := StrReplace(s, "\n", "`n")
        return s
    }

    BuildStringPatterns()
    {
        this.StringPatternsByFirstWord := Map()

        for str, _ in this.KnownStrings
        {
            pat := this.MakeUtf16Pattern(str)
            if !pat
                continue

            firstWord := pat["firstWord"]
            if !this.StringPatternsByFirstWord.Has(firstWord)
                this.StringPatternsByFirstWord[firstWord] := []

            this.StringPatternsByFirstWord[firstWord].Push(pat)
        }
    }

    MakeUtf16Pattern(str)
    {
        charsWithNull := StrPut(str, "UTF-16")
        if (charsWithNull <= 1)
            return 0

        byteLen := (charsWithNull - 1) * 2
        if (byteLen <= 0 || byteLen >= 512)
            return 0

        bytes := Buffer(byteLen + 2, 0)
        StrPut(str, bytes, charsWithNull, "UTF-16")
        firstWord := NumGet(bytes.Ptr, 0, "UShort")

        return Map(
            "str", str,
            "bytes", bytes,
            "byteLen", byteLen,
            "firstWord", firstWord
        )
    }

    CompareBytes(bufA, offsetA, bufB, len)
    {
        i := 0
        while (i < len)
        {
            if (NumGet(bufA.Ptr, offsetA + i, "UChar") != NumGet(bufB.Ptr, i, "UChar"))
                return false
            i += 1
        }
        return true
    }

    Hex(val)
    {
        return Format("{:X}", val)
    }
}
