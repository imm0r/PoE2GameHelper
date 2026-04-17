#Requires AutoHotkey v2.0
#Include ProcessMemory.ahk
#Include StaticOffsetsPatterns.ahk
#Include PoE2ComponentDecoders.ahk
#Include PoE2EntityReader.ahk
#Include PoE2PlayerComponentsReader.ahk
#Include PoE2PlayerReader.ahk
#Include PoE2InventoryReader.ahk
#Include PoE2Offsets.ahk

class PoE2GameStateReader extends PoE2InventoryReader
{
    ; Initializes the reader state, pattern scan report, entity sample limits, and item name dictionaries.
    __New(processName := "PathOfExileSteam.exe")
    {
        this.Mem := ProcessMemory(processName)
        this.GameStatesAddress := 0
        this.StaticAddresses := Map()
        this.MemChrMode := -1
        this.PatternScanReport := Map(
            "missingCritical", [],
            "missingOptional", [],
            "duplicateCritical", [],
            "duplicateOptional", [],
            "found", []
        )
        this.StateNames := [
            "AreaLoadingState",
            "ChangePasswordState",
            "CreditsState",
            "EscapeState",
            "InGameState",
            "PreGameState",
            "LoginState",
            "WaitingState",
            "CreateCharacterState",
            "SelectCharacterState",
            "DeleteCharacterState",
            "LoadingState"
        ]
        this.LastAreaInstanceAddress := 0
        this.LastAreaHash := 0
        this.LastAreaLevel := -1
        this.LastInGameStateAddress := 0
        this.LastEntityReadMode := "direct"
        this.LastEntityFallbackTick := 0
        this.LastEntityReadOffset := PoE2Offsets.AreaInstance["AwakeEntities"]

        ; Fixed sampling limits (legacy sample-mode toggle removed).
        this.AwakeEntitySampleLimit := 32
        this.SleepingEntitySampleLimit := 16
        this._radarMode := false

        ; Radar-specific limits — smaller than full snapshot for faster 100ms updates.
        ; Awake entities are capped at 70 to widen nearby coverage compared to the normal sample
        ; limit, while still keeping radar polls cheap enough for the 100ms update cadence.
        ; Sleeping entities carry stale world positions, but are scanned with a small limit
        ; so the Entities tab can display important types (Boss, NPC, Waypoint, AreaTransition, Checkpoint).
        this.RadarAwakeEntityLimit := 40
        this.RadarSleepingEntityLimit := 8

        ; Stale-entity cleanup (port of upstream commit 75d48872).
        ; Tracks entities seen as dead/invalid for consecutive ticks.
        ; addr → entityId: permanently filtered for current area; cleared if address is reused
        ;   for a new entity with a different ID (PoE2 memory allocator recycles entity addresses).
        this._deadEntityBlacklist := Map()
        ; last seen areaInstance address — blacklist is reset on area change
        this._lastAreaInstanceAddr := 0
        ; addr → true: entities that have been confirmed alive (HP > 0) at least once this area.
        this._everAliveAddrs := Map()
        ; addr → consecutive ticks where IsTargetable=0 after entity was seen as targetable=1.
        ; Dead monsters hold IsTargetable=0 (or garbage, treated as 0) indefinitely.
        ; At 100ms/tick and TargetableDeadThreshold=10, a non-boss entity is blacklisted after 1 second.
        this._targetableDeadMap := Map()
        this.TargetableDeadThreshold := 10
        ; addr → true: entities seen with IsTargetable=true at least once.
        this._targetableEverOn := Map()
        ; addr → A_TickCount when entity was first seen in the radar sample.
        ; Used by Signal 4: monsters never confirmed alive after 5 s are ghost entities.
        this._firstSeenTick := Map()
        ; addr → "X,Y" string (world position rounded to 1 dp) at last tick it was in sample.
        ; Used by Signal 6: monsters whose position is frozen for PosDeadThresholdMs are dead.
        this._posLastXY := Map()
        ; addr → A_TickCount when we first observed the entity's position being frozen (no change).
        this._posFrozenSinceTick := Map()
        ; Milliseconds a monster must stay at the exact same position before being treated as dead.
        ; Dead corpses are perfectly static; live monsters move or shift slightly.
        ; Since Signal 2 (HP=0) and Signal 5 (Targetable flip) now work correctly,
        ; Signal 6 is only a fallback. Use a generous threshold to avoid false positives
        ; for idle/ranged monsters that stand still in combat.
        this.PosDeadThresholdMs := 15000

        ; Cached UI element data for radar (re-read every 400ms instead of every 100ms).
        this._radarUiCache := 0
        this._radarUiCacheTick := 0

        ; Panel visibility: visibility-differential approach.
        ; _heapUiElems stores [{off, ptr}, ...] for all valid heap UiElements in the struct.
        ; _visBaseline stores Map(structOffset → isVisible) taken at discovery time.
        ; Real-time: compare current visibility to baseline; new visible = panel open.
        this._radarPanelVisCache := 0
        this._radarPanelVisCacheTick := 0
        this._radarPanelDiscoveryDone := false
        this._radarPanelDiscoveryResult := 0
        this._heapUiElems := []
        this._visBaseline := Map()
        this._visBaselineTaken := false
        this._diffSnapshot := 0
        this._diffSnapshotTaken := false
        this._lastActiveGameUiPtr := 0
        this._structBaselineRaw := 0
        this._baselineDelayTick := 0

        ; Cached InGameState address for radar (re-resolved every 800ms instead of every 100ms).
        this._radarInGameStateCache := 0
        this._radarInGameStateTick := 0
        this._radarCurrentStateName := "GameNotLoaded"

        ; Cached terrain walkability data — re-read only when area hash changes.
        this._radarTerrainCache     := 0
        this._radarTerrainAreaHash  := 0xFFFFFFFF   ; sentinel: guarantees read on first tick
        this._radarTerrainRetryTick := 0            ; tick of last failed-read retry attempt
        this._terrainLastError      := ""           ; last ReadTerrainData failure reason

        ; World area data cache (town/hideout flags) — re-read on zone change.
        this._radarWorldAreaCache   := 0
        this._radarWorldAreaHash    := 0xFFFFFFFF

        ; Persistent entity cache (mirrors C# AreaInstance.AwakeEntities ConcurrentDictionary).
        ; entityId → sampleEntry Map (same format as CollectEntityMapCandidates output).
        ; Reset on area change. New entities get full ReadEntityBasic decode; existing ones get
        ; cheap per-tick updates (position, life, targetable, flags) via UpdateCachedEntityRadar.
        this._radarEntityCache      := Map()
        this._radarEntityCacheAreaHash := 0xFFFFFFFF

        ; Zone navigation: continuous accumulation of important entities.
        ; Initial deep scan on area change, then harvests from regular scans each tick.
        this._zoneScanAccumulated := Map()   ; path → Map(path, type, worldX/Y/Z, gridX/Y)
        this._zoneScanAreaHash    := 0xFFFFFFFF
        this._zoneScanDone        := false   ; true once initial deep scan completed
        this._zoneScanEnabled     := true    ; toggle from config
        this._zoneScanTimingMs    := 0       ; how long the last deep scan took
        this._zoneScanScheduledAt := 0       ; tick when deep scan should run
        this._zoneScanRetries     := 0       ; retry count if deep scan finds 0 results
        this._tgtScanInProgress   := false   ; true while incremental tile scan is running

        ; BFS throttle: reuse tree scan results for 200ms to reduce per-tick RPM calls.
        this._radarLastBfsTick           := 0
        this._radarLastCurrentEntities   := 0
        this._radarLastFullAwakeRawPtrs  := 0

        ; Round-robin cursor for time-budgeted cheap entity updates.
        this._cheapUpdateOffset := 0

        ; Player vitals cache (refreshed every 200ms in radar snapshot)
        this._radarPlayerVitalsCache := 0
        this._radarPlayerVitalsTick  := 0

        ; Cached StaticPtr for the Charges component type (populated on first named-lookup hit)
        this._chargesStaticPtr := 0

        ; Load item name dictionaries from TSV files
        this.ModNameMap := Map()
        this.BaseItemNameMap := Map()
        this.UniqueItemNameMap := Map()
        this.LoadModNameMap(A_ScriptDir "\\data\\mod_name_map.tsv")
        this.LoadBaseItemNameMap(A_ScriptDir "\\data\\base_item_name_map.tsv")
        this.LoadUniqueItemNameMap(A_ScriptDir "\\data\\unique_item_name_map.tsv")
    }

    ; Opens the process and resolves the GameStates address via pattern scan, falling back to heuristic scan.
    ; Params: strictPatterns - if true, returns false when any critical pattern is missing or duplicated.
    ; Returns: true if GameStatesAddress was successfully resolved.
    Connect(strictPatterns := false)
    {
        if !this.Mem.Open()
            return false

        if (!strictPatterns)
        {
            this.GameStatesAddress := this.ResolveGameStatesAddressFromStaticPattern()
            if (this.GameStatesAddress && this.ValidateGameStatesAddress(this.GameStatesAddress))
                return true

            this.GameStatesAddress := this.ResolveGameStatesAddressFallback()
            if (this.GameStatesAddress && this.ValidateGameStatesAddress(this.GameStatesAddress))
                return true
        }

        this.StaticAddresses := this.FindStaticAddresses()

        if (strictPatterns && this.HasPatternScanCriticalIssues())
            return false

        this.GameStatesAddress := this.StaticAddresses.Has("Game States") ? this.StaticAddresses["Game States"] : 0

        if (!this.GameStatesAddress)
            this.GameStatesAddress := this.ResolveGameStatesAddressFallback()
        else if (!this.ValidateGameStatesAddress(this.GameStatesAddress))
            this.GameStatesAddress := this.ResolveGameStatesAddressFallback()

        return this.GameStatesAddress != 0
    }

    ; Scans the .text section in 2 MB chunks for the Game States RIP-relative signature.
    ; Returns: resolved absolute GameStates address, or 0 if not found or deadline exceeded.
    ResolveGameStatesAddressFromStaticPattern()
    {
        if (!this.Mem.ModuleBase || !this.Mem.ModuleSize)
            return 0

        this.Mem.GetScanRegion(true)
        scanBase := this.Mem.ScanBase ? this.Mem.ScanBase : this.Mem.ModuleBase
        scanSize := this.Mem.ScanSize ? this.Mem.ScanSize : this.Mem.ModuleSize

        parsed := this.ParsePattern("48 39 2D ^ ?? ?? ?? ?? 0F 85 16 01 00 00")
        patternLen := parsed["data"].Length
        chunkSize := 2 * 1024 * 1024
        overlap := Max(0, patternLen - 1)
        currentOffset := 0
        deadline := A_TickCount + 15000

        while (currentOffset < scanSize)
        {
            if (A_TickCount > deadline)
                break

            remaining := scanSize - currentOffset
            readSize := Min(chunkSize, remaining)
            buffer := this.Mem.ReadBytes(scanBase + currentOffset, readSize, true)
            if (buffer && Type(buffer) = "Buffer" && buffer.Size >= patternLen)
            {
                matches := this.FindPatternAddressesInBuffer(
                    buffer,
                    buffer.Size,
                    scanBase + currentOffset,
                    parsed,
                    64,
                    deadline)

                for matchAddr in matches
                {
                    relOperandAddress := matchAddr + parsed["bytesToSkip"]
                    relValue := this.Mem.ReadInt(relOperandAddress)
                    candidate := relOperandAddress + relValue + 4
                    if (!this.IsProbablyValidPointer(candidate))
                        continue

                    gsPtr := this.Mem.ReadPtr(candidate)
                    if (!this.IsProbablyValidPointer(gsPtr))
                        continue

                    if (this.ValidateGameStatesAddress(candidate))
                        return candidate
                }
            }

            if (readSize <= overlap)
                break
            currentOffset += (readSize - overlap)
        }

        return 0
    }

    ; Runs all named patterns from GetStaticPatterns() against the cached module snapshot.
    ; Resolves each match's RIP-relative operand to a final address and categorises results into
    ; found, missingCritical, missingOptional, duplicateCritical, and duplicateOptional buckets.
    ; Returns: Map of pattern name → resolved address for every uniquely matched pattern.
    FindStaticAddresses()
    {
        result := Map()
        patterns := this.GetStaticPatterns()
        optionalNames := PoE2StaticOffsetsPatterns.GetOptionalNames()
        missingCritical := []
        missingOptional := []
        duplicateCritical := []
        duplicateOptional := []
        found := []
        scanDeadline := A_TickCount + 30000

        moduleBytes := this.Mem.GetModuleSnapshot(true)
        moduleSize := moduleBytes ? moduleBytes.Size : 0

        for patternInfo in patterns
        {
            if (A_TickCount > scanDeadline)
                break

            parsed := this.ParsePattern(patternInfo["pattern"])
            matchAddresses := []
            if (moduleBytes)
                matchAddresses := this.FindPatternAddressesInBuffer(moduleBytes, moduleSize, this.Mem.ModuleSnapshotBase, parsed, 2, scanDeadline)

            if (matchAddresses.Length = 0)
            {
                if optionalNames.Has(patternInfo["name"])
                    missingOptional.Push(patternInfo["name"])
                else
                    missingCritical.Push(patternInfo["name"])
                continue
            }

            if (matchAddresses.Length > 1)
            {
                if optionalNames.Has(patternInfo["name"])
                    duplicateOptional.Push(patternInfo["name"])
                else
                    duplicateCritical.Push(patternInfo["name"])
                continue
            }

            matchAddress := matchAddresses[1]

            if (parsed["bytesToSkip"] < 0)
            {
                if optionalNames.Has(patternInfo["name"])
                    missingOptional.Push(patternInfo["name"])
                else
                    missingCritical.Push(patternInfo["name"])
                continue
            }

            relOperandAddress := matchAddress + parsed["bytesToSkip"]
            relValue := this.Mem.ReadInt(relOperandAddress)
            finalAddress := relOperandAddress + relValue + 4

            if this.IsProbablyValidPointer(finalAddress)
            {
                result[patternInfo["name"]] := finalAddress
                found.Push(patternInfo["name"])
            }
            else
            {
                if optionalNames.Has(patternInfo["name"])
                    missingOptional.Push(patternInfo["name"])
                else
                    missingCritical.Push(patternInfo["name"])
            }
        }

        this.PatternScanReport := Map(
            "missingCritical", missingCritical,
            "missingOptional", missingOptional,
            "duplicateCritical", duplicateCritical,
            "duplicateOptional", duplicateOptional,
            "found", found
        )

        return result
    }

    ; Returns true if any critical pattern had zero matches or more than one match after scanning.
    HasPatternScanCriticalIssues()
    {
        return this.PatternScanReport["missingCritical"].Length > 0 || this.PatternScanReport["duplicateCritical"].Length > 0
    }

    ; Collects GameStates address candidates via a broader heuristic scan and returns the first valid one.
    ; Returns: first validated candidate address, or the first raw candidate if none validate.
    ResolveGameStatesAddressFallback()
    {
        candidates := this.ScanForGameStatesCandidates()
        for candidate in candidates
        {
            if this.ValidateGameStatesAddress(candidate["calculated"])
                return candidate["calculated"]
        }

        return candidates.Length ? candidates[1]["calculated"] : 0
    }

    ; Returns the full list of named byte-signature patterns from PoE2StaticOffsetsPatterns.
    GetStaticPatterns()
    {
        return PoE2StaticOffsetsPatterns.GetAll()
    }

    ; Parses a hex byte pattern string into data, mask, bytesToSkip, and anchorIndex arrays.
    ; Params: patternText - space-separated hex bytes, optional "??" wildcards, and "^" RIP-offset marker.
    ; Returns: Map with "data", "mask", "bytesToSkip", and "anchorIndex" keys.
    ParsePattern(patternText)
    {
        tokens := StrSplit(Trim(patternText), " ")
        data := []
        mask := []
        bytesToSkip := -1
        anchorIndex := -1

        for token in tokens
        {
            token := Trim(token)
            if (token = "")
                continue

            if (token = "^")
            {
                bytesToSkip := data.Length
                continue
            }

            if (token = "??" || token = "?")
            {
                data.Push(0)
                mask.Push(false)
            }
            else
            {
                data.Push(Integer("0x" token))
                mask.Push(true)
                if (anchorIndex < 0)
                    anchorIndex := data.Length - 1
            }
        }

        if (anchorIndex < 0)
            anchorIndex := 0

        return Map(
            "data", data,
            "mask", mask,
            "bytesToSkip", bytesToSkip,
            "anchorIndex", anchorIndex
        )
    }

    ; Returns the first pattern match address in the cached module snapshot, or 0 if none found.
    FindPatternAddressInModule(parsedPattern)
    {
        matches := this.FindPatternAddressesInModule(parsedPattern, 1)
        return matches.Length ? matches[1] : 0
    }

    ; Finds up to maxMatches occurrences of parsedPattern in the cached module snapshot.
    ; Returns: array of matching absolute addresses (may be empty).
    FindPatternAddressesInModule(parsedPattern, maxMatches := 1)
    {
        moduleBytes := this.Mem.GetModuleSnapshot()
        if !moduleBytes
            return []

        return this.FindPatternAddressesInBuffer(
            moduleBytes,
            moduleBytes.Size,
                this.Mem.ModuleSnapshotBase,
            parsedPattern,
            maxMatches)
    }

            ; Searches buffer for all occurrences of parsedPattern, returning up to maxMatches results.
            ; Uses MemChr on the anchor byte as a fast pre-filter before running the full mask comparison.
            ; Returns: array of absolute addresses (baseAddress + buffer offset of each match).
            FindPatternAddressesInBuffer(buffer, bufferSize, baseAddress, parsedPattern, maxMatches := 1, deadlineTick := 0)
    {
        if (!buffer || bufferSize <= 0)
            return []

        patternData := parsedPattern["data"]
        patternMask := parsedPattern["mask"]
        anchorIndex := parsedPattern["anchorIndex"]
        patternLen := patternData.Length
        if (patternLen <= 0)
            return []

        matches := []

        lastStart := bufferSize - patternLen
        ptr := buffer.Ptr
        anchorByte := patternData[anchorIndex + 1]
        i := 0
        while (i <= lastStart)
        {
            if (deadlineTick > 0 && A_TickCount > deadlineTick)
                break

            searchStart := ptr + i + anchorIndex
            remaining := (lastStart - i) + 1
            foundPtr := this.MemChr(searchStart, anchorByte, remaining)
            if (!foundPtr)
            {
                k := i
                while (k <= lastStart)
                {
                    if (deadlineTick > 0 && A_TickCount > deadlineTick)
                        break

                    if (NumGet(ptr, k + anchorIndex, "UChar") = anchorByte)
                    {
                        foundPtr := ptr + k + anchorIndex
                        break
                    }
                    k += 1
                }
            }

            if !foundPtr
                break

            i := foundPtr - ptr - anchorIndex
            if (i < 0 || i > lastStart)
                break

            matched := true
            j := 1
            while (j <= patternLen)
            {
                if (patternMask[j])
                {
                    b := NumGet(ptr, i + (j - 1), "UChar")
                    if (b != patternData[j])
                    {
                        matched := false
                        break
                    }
                }
                j += 1
            }

            if (matched)
            {
                matchAddress := baseAddress + i
                if (matches.Length = 0 || matches[matches.Length] != matchAddress)
                    matches.Push(matchAddress)

                if (maxMatches > 0 && matches.Length >= maxMatches)
                    return matches
            }

            i += 1
        }

        return matches
    }

    ; Searches for byteValue in a raw memory region via ucrtbase or msvcrt memchr, auto-detecting DLL.
    ; Returns: pointer to the first matching byte, or 0 if not found or no CRT DLL is available.
    MemChr(startPtr, byteValue, byteCount)
    {
        if (byteCount <= 0)
            return 0

        if (this.MemChrMode = 1)
            return DllCall("ucrtbase.dll\\memchr", "Ptr", startPtr, "Int", byteValue, "UPtr", byteCount, "Ptr")

        if (this.MemChrMode = 2)
            return DllCall("msvcrt.dll\\memchr", "Ptr", startPtr, "Int", byteValue, "UPtr", byteCount, "Ptr")

        if (this.MemChrMode = 0)
            return 0

        try
        {
            ptr := DllCall("ucrtbase.dll\\memchr", "Ptr", startPtr, "Int", byteValue, "UPtr", byteCount, "Ptr")
            this.MemChrMode := 1
            return ptr
        }
        catch
        {
            try
            {
                ptr := DllCall("msvcrt.dll\\memchr", "Ptr", startPtr, "Int", byteValue, "UPtr", byteCount, "Ptr")
                this.MemChrMode := 2
                return ptr
            }
            catch
            {
                this.MemChrMode := 0
                return 0
            }
        }
    }

    ; Scans all known patterns and writes a human-readable debug log of every match and resolved address.
    ; Returns: path to the written log file, or "" on failure.
    ExportPatternMatchesDebug(maxMatchesPerPattern := 0, outputPath := "")
    {
        if (!this.Mem.Handle)
            return ""

        if (outputPath = "")
        {
            stamp := FormatTime(, "yyyyMMdd_HHmmss")
            outputPath := A_ScriptDir "\\PatternScanDebug_" stamp ".log"
        }

        patterns := this.GetStaticPatterns()
        report := []
        report.Push("PoE2 AHK Pattern Debug Export")
        report.Push("Generated: " FormatTime(, "yyyy-MM-dd HH:mm:ss"))
        report.Push("PID: " this.Mem.Pid)
        report.Push("ModuleBase: " PoE2GameStateReader.Hex(this.Mem.ModuleBase))
        report.Push("ModuleSize: " this.Mem.ModuleSize)
        report.Push("")

        for patternInfo in patterns
        {
            parsed := this.ParsePattern(patternInfo["pattern"])
            matches := this.FindPatternAddressesInModule(parsed, maxMatchesPerPattern)

            report.Push("[Pattern] " patternInfo["name"])
            report.Push("  Signature: " patternInfo["pattern"])
            report.Push("  BytesToSkip: " parsed["bytesToSkip"])
            report.Push("  Matches: " matches.Length)

            for addr in matches
                report.Push("    - " PoE2GameStateReader.Hex(addr))

            if (parsed["bytesToSkip"] >= 0 && matches.Length = 1)
            {
                relOperandAddress := matches[1] + parsed["bytesToSkip"]
                relValue := this.Mem.ReadInt(relOperandAddress)
                finalAddress := relOperandAddress + relValue + 4
                report.Push("  ResolvedAddress: " PoE2GameStateReader.Hex(finalAddress))
            }

            report.Push("")
        }

        outFile := FileOpen(outputPath, "w", "UTF-8")
        if !IsObject(outFile)
            return ""

        for line in report
            outFile.WriteLine(line)
        outFile.Close()

        return outputPath
    }

    ; Scans all known patterns and writes each match result as a CSV row.
    ; Returns: path to the written CSV file, or "" on failure.
    ExportPatternMatchesCsv(maxMatchesPerPattern := 0, outputPath := "")
    {
        if (!this.Mem.Handle)
            return ""

        if (outputPath = "")
        {
            stamp := FormatTime(, "yyyyMMdd_HHmmss")
            outputPath := A_ScriptDir "\\PatternScanDebug_" stamp ".csv"
        }

        patterns := this.GetStaticPatterns()
        outFile := FileOpen(outputPath, "w", "UTF-8")
        if !IsObject(outFile)
            return ""

        outFile.WriteLine("PatternName,Signature,BytesToSkip,MatchIndex,MatchAddress,ResolvedAddress")

        for patternInfo in patterns
        {
            parsed := this.ParsePattern(patternInfo["pattern"])
            matches := this.FindPatternAddressesInModule(parsed, maxMatchesPerPattern)

            if (matches.Length = 0)
            {
                outFile.WriteLine(this.CsvCell(patternInfo["name"]) ","
                    . this.CsvCell(patternInfo["pattern"]) ","
                    . parsed["bytesToSkip"] ",0,,")
                continue
            }

            for idx, addr in matches
            {
                resolved := ""
                if (parsed["bytesToSkip"] >= 0)
                {
                    relOperandAddress := addr + parsed["bytesToSkip"]
                    relValue := this.Mem.ReadInt(relOperandAddress)
                    finalAddress := relOperandAddress + relValue + 4
                    resolved := PoE2GameStateReader.Hex(finalAddress)
                }

                outFile.WriteLine(this.CsvCell(patternInfo["name"]) ","
                    . this.CsvCell(patternInfo["pattern"]) ","
                    . parsed["bytesToSkip"] ","
                    . idx ","
                    . this.CsvCell(PoE2GameStateReader.Hex(addr)) ","
                    . this.CsvCell(resolved))
            }
        }

        outFile.Close()
        return outputPath
    }

    ; Wraps a value in double-quotes and escapes any internal double-quotes for safe CSV embedding.
    CsvCell(value)
    {
        text := value ""
        text := StrReplace(text, '"', '""')
        return '"' text '"'
    }

    ; Heuristic fallback scanner: searches for a common function prologue near "48 39 2D" to extract
    ; GameStates address candidates by reading the following RIP-relative operand.
    ; Returns: array of Maps with "pattern" (match addr) and "calculated" (resolved addr) keys.
    ScanForGameStatesCandidates()
    {
        result := []
        if (!this.Mem.ModuleBase || !this.Mem.ModuleSize)
            return result

        this.Mem.GetScanRegion(true)
        scanBase := this.Mem.ScanBase ? this.Mem.ScanBase : this.Mem.ModuleBase
        scanSize := this.Mem.ScanSize ? this.Mem.ScanSize : this.Mem.ModuleSize

        parsed := this.ParsePattern("48 83 EC ?? 48 8B F1 33 ED 48 39 2D")
        patternLen := parsed["data"].Length
        chunkSize := 2 * 1024 * 1024
        overlap := Max(0, patternLen - 1)
        currentOffset := 0
        deadline := A_TickCount + 12000

        while (currentOffset < scanSize)
        {
            if (A_TickCount > deadline)
                break

            remaining := scanSize - currentOffset
            readSize := Min(chunkSize, remaining)
            buffer := this.Mem.ReadBytes(scanBase + currentOffset, readSize, true)
            if (buffer && Type(buffer) = "Buffer" && buffer.Size >= patternLen)
            {
                matches := this.FindPatternAddressesInBuffer(
                    buffer,
                    buffer.Size,
                    scanBase + currentOffset,
                    parsed,
                    32,
                    deadline)

                for patternAddr in matches
                {
                    relOffset := this.Mem.ReadInt(patternAddr + 3)
                    nextInstruction := patternAddr + 7
                    gameStatesAddr := nextInstruction + relOffset

                    if this.IsProbablyValidPointer(gameStatesAddr)
                    {
                        result.Push(Map(
                            "pattern", patternAddr,
                            "calculated", gameStatesAddr
                        ))
                    }
                }

                if (result.Length >= 16)
                    break
            }

            if (readSize <= overlap)
                break
            currentOffset += (readSize - overlap)
        }

        return result
    }

    ; Validates a candidate GameStates address by dereferencing known offsets down to AreaInstanceData.
    ; Returns: true if the pointer chain resolves to plausible InGameState data.
    ValidateGameStatesAddress(address)
    {
        if !this.IsProbablyValidPointer(address)
            return false

        ; Preferred path for current reader model:
        ; address -> GameStateOffset* at +0x00 (GameStateStaticOffset.GameState)
        ; GameStateOffset.States at +0x48, each entry is 16 bytes, index 4 => InGameState
        gameStateOffsetPtr := this.Mem.ReadPtr(address)
        if this.IsProbablyValidPointer(gameStateOffsetPtr)
        {
            inGameStatePtr := this.Mem.ReadPtr(gameStateOffsetPtr
                + PoE2Offsets.GameState["States"]
                + (PoE2Offsets.GameState["InGameStateIndex"] * PoE2Offsets.GameState["StateEntrySize"]))
            if this.IsProbablyValidPointer(inGameStatePtr)
            {
                areaInstanceData := this.Mem.ReadPtr(inGameStatePtr + PoE2Offsets.InGameState["AreaInstanceData"])
                if this.IsProbablyValidPointer(areaInstanceData)
                    return true
            }
        }

        return false
    }

    ; Reads the full game state snapshot: all 12 named states, active state, and complete InGameState tree.
    ; Returns: Map with gameStates address, current/active state info, inGameState subtree; or 0 on error.
    ReadSnapshot()
    {
        if (!this.Mem.Handle || !this.GameStatesAddress)
            return 0

        staticGameStatePtr := this.Mem.ReadPtr(this.GameStatesAddress)
        if !this.IsProbablyValidPointer(staticGameStatePtr)
            return 0

        currentStateVecLast := this.Mem.ReadInt64(staticGameStatePtr + PoE2Offsets.GameState["CurrentStateVecLast"])

        statesByIndex := []
        statesByAddress := Map()
        statesBase := staticGameStatePtr + PoE2Offsets.GameState["States"]
        loop 12
        {
            idx := A_Index - 1
            stateAddr := this.Mem.ReadPtr(statesBase + (idx * PoE2Offsets.GameState["StateEntrySize"]))
            stateName := this.StateNames[A_Index]
            statesByIndex.Push(Map("index", idx, "name", stateName, "address", stateAddr))
            if (stateAddr)
                statesByAddress[stateAddr] := stateName
        }

        currentStateAddress := 0
        currentStateName := "GameNotLoaded"
        if (currentStateVecLast > 0x10)
        {
            currentStateAddress := this.Mem.ReadPtr(currentStateVecLast - 0x10)
            if (currentStateAddress && statesByAddress.Has(currentStateAddress))
                currentStateName := statesByAddress[currentStateAddress]
        }

        inGameStateAddress := this.ResolveInGameStateAddress(statesByIndex, currentStateAddress)
        inGameStateData := this.ReadInGameState(inGameStateAddress)

        return Map(
            "gameStatesAddress", this.GameStatesAddress,
            "staticAddresses", this.StaticAddresses,
            "patternScanReport", this.PatternScanReport,
            "gameStateObject", staticGameStatePtr,
            "currentStateAddress", currentStateAddress,
            "currentStateName", currentStateName,
            "inGameStateAddress", inGameStateAddress,
            "inGameState", inGameStateData,
            "allStates", statesByIndex
        )
    }

    ; Reads a lightweight snapshot optimised for the AutoFlask overlay, skipping the full entity scan.
    ; Returns: Map with flask slots, vitals, buffs, server data, and state info; or 0 on error.
    ReadAutoFlaskSnapshot()
    {
        if (!this.Mem.Handle || !this.GameStatesAddress)
            return 0

        staticGameStatePtr := this.Mem.ReadPtr(this.GameStatesAddress)
        if !this.IsProbablyValidPointer(staticGameStatePtr)
            return 0

        currentStateVecLast := this.Mem.ReadInt64(staticGameStatePtr + PoE2Offsets.GameState["CurrentStateVecLast"])

        statesByIndex := []
        statesByAddress := Map()
        statesBase := staticGameStatePtr + PoE2Offsets.GameState["States"]
        loop 12
        {
            idx := A_Index - 1
            stateAddr := this.Mem.ReadPtr(statesBase + (idx * PoE2Offsets.GameState["StateEntrySize"]))
            stateName := this.StateNames[A_Index]
            statesByIndex.Push(Map("index", idx, "name", stateName, "address", stateAddr))
            if (stateAddr)
                statesByAddress[stateAddr] := stateName
        }

        currentStateAddress := 0
        currentStateName := "GameNotLoaded"
        if (currentStateVecLast > 0x10)
        {
            currentStateAddress := this.Mem.ReadPtr(currentStateVecLast - 0x10)
            if (currentStateAddress && statesByAddress.Has(currentStateAddress))
                currentStateName := statesByAddress[currentStateAddress]
        }

        inGameStateAddress := this.ResolveInGameStateAddress(statesByIndex, currentStateAddress)
        inGameStateData := this.ReadInGameStateAutoFlask(inGameStateAddress)

        return Map(
            "snapshotMode", "autoflask-performance",
            "gameStatesAddress", this.GameStatesAddress,
            "gameStateObject", staticGameStatePtr,
            "currentStateAddress", currentStateAddress,
            "currentStateName", currentStateName,
            "inGameStateAddress", inGameStateAddress,
            "inGameState", inGameStateData,
            "allStates", statesByIndex
        )
    }

    ; Scores each state entry by validating its pointer chains and name, then returns the best InGameState address.
    ; Params: currentStateAddress - currently active state pointer used as a scoring hint.
    ; Returns: best InGameState address found, falling back to the cached or index-5 address.
    ResolveInGameStateAddress(statesByIndex, currentStateAddress := 0)
    {
        bestAddress := 0
        bestScore := -1

        if !(statesByIndex && Type(statesByIndex) = "Array")
            return 0

        for _, stateInfo in statesByIndex
        {
            if !(stateInfo && Type(stateInfo) = "Map" && stateInfo.Has("address"))
                continue

            stateAddress := stateInfo["address"]
            if !this.IsProbablyValidPointer(stateAddress)
                continue

            score := 0
            if (stateInfo.Has("name") && stateInfo["name"] = "InGameState")
                score += 6
            if (currentStateAddress && stateAddress = currentStateAddress)
                score += 2
            if (this.LastInGameStateAddress && stateAddress = this.LastInGameStateAddress)
                score += 4

            areaInstanceData := this.Mem.ReadPtr(stateAddress + PoE2Offsets.InGameState["AreaInstanceData"])
            worldData := this.Mem.ReadPtr(stateAddress + PoE2Offsets.InGameState["WorldData"])

            if this.IsProbablyValidPointer(areaInstanceData)
                score += 3
            if this.IsProbablyValidPointer(worldData)
                score += 1

            if this.IsProbablyValidPointer(areaInstanceData)
            {
                areaLevel := this.Mem.ReadUChar(areaInstanceData + PoE2Offsets.AreaInstance["CurrentAreaLevel"])
                areaHash := this.Mem.ReadUInt(areaInstanceData + PoE2Offsets.AreaInstance["CurrentAreaHash"])
                if (areaLevel >= 1 && areaLevel <= 100)
                    score += 1
                if (areaHash != 0)
                    score += 1

                playerInfoPtr := areaInstanceData + PoE2Offsets.AreaInstance["PlayerInfo"]
                localPlayerRawPtr := this.Mem.ReadPtr(playerInfoPtr + PoE2Offsets.LocalPlayerStruct["LocalPlayerPtr"])
                localPlayerPtr := this.ResolveEntityPointer(localPlayerRawPtr)
                if this.IsPlausibleEntityPointer(localPlayerPtr)
                    score += 2
            }

            if (score > bestScore)
            {
                bestScore := score
                bestAddress := stateAddress
            }
        }

        if this.IsProbablyValidPointer(bestAddress)
        {
            this.LastInGameStateAddress := bestAddress
            return bestAddress
        }

        if this.IsProbablyValidPointer(this.LastInGameStateAddress)
            return this.LastInGameStateAddress

        return (statesByIndex.Length >= 5 && statesByIndex[5].Has("address")) ? statesByIndex[5]["address"] : 0
    }

    ; Re-scans for the GameStates address and resets all cached area, entity, and state pointers.
    RefreshStateAnchors()
    {
        candidate := this.ResolveGameStatesAddressFromStaticPattern()
        if !(candidate && this.ValidateGameStatesAddress(candidate))
            candidate := this.ResolveGameStatesAddressFallback()

        if (candidate && this.ValidateGameStatesAddress(candidate))
            this.GameStatesAddress := candidate

        this.LastInGameStateAddress := 0
        this.LastAreaInstanceAddress := 0
        this.LastAreaHash := 0
        this.LastAreaLevel := -1
    }

    ; Reads a slim InGameState containing only area instance and world data pointers for the AutoFlask path.
    ReadInGameStateAutoFlask(inGameStateAddress)
    {
        if !this.IsProbablyValidPointer(inGameStateAddress)
            return 0

        areaInstanceData := this.Mem.ReadPtr(inGameStateAddress + PoE2Offsets.InGameState["AreaInstanceData"])
        worldData := this.Mem.ReadPtr(inGameStateAddress + PoE2Offsets.InGameState["WorldData"])

        return Map(
            "address", inGameStateAddress,
            "areaInstanceData", areaInstanceData,
            "areaInstance", this.ReadAreaInstanceAutoFlask(areaInstanceData),
            "worldData", worldData,
            "worldDataDetails", this.ReadWorldDataAutoFlask(worldData)
        )
    }

    ; Reads the world area details pointer chain for the AutoFlask snapshot (no full WorldAreaDat decode).
    ReadWorldDataAutoFlask(worldDataAddress)
    {
        if !this.IsProbablyValidPointer(worldDataAddress)
            return 0

        worldAreaDetailsPtr := this.Mem.ReadPtr(worldDataAddress + PoE2Offsets.WorldData["WorldAreaDetailsPtr"])
        worldAreaDetailsRowPtr := 0
        worldAreaDat := 0
        if this.IsProbablyValidPointer(worldAreaDetailsPtr)
        {
            worldAreaDetailsRowPtr := this.Mem.ReadPtr(worldAreaDetailsPtr + PoE2Offsets.WorldData["WorldAreaDetailsRowPtr"])
            worldAreaDat := this.ReadWorldAreaDat(worldAreaDetailsRowPtr)
        }

        return Map(
            "address", worldDataAddress,
            "worldAreaDetailsPtr", worldAreaDetailsPtr,
            "worldAreaDetailsRowPtr", worldAreaDetailsRowPtr,
            "worldAreaDat", worldAreaDat
        )
    }

    ; Reads player vitals, flask slots, buffs, and server data for the AutoFlask snapshot.
    ; Resolves the local player pointer via direct struct lookup, falling back to an area search.
    ReadAreaInstanceAutoFlask(areaInstanceAddress)
    {
        if !this.IsProbablyValidPointer(areaInstanceAddress)
            return 0

        currentAreaLevel := this.Mem.ReadUChar(areaInstanceAddress + PoE2Offsets.AreaInstance["CurrentAreaLevel"])
        currentAreaHash := this.Mem.ReadUInt(areaInstanceAddress + PoE2Offsets.AreaInstance["CurrentAreaHash"])
        playerInfoPtr := areaInstanceAddress + PoE2Offsets.AreaInstance["PlayerInfo"]
        serverDataRawPtr := this.Mem.ReadPtr(playerInfoPtr + PoE2Offsets.LocalPlayerStruct["ServerDataPtr"])
        localPlayerRawPtr := this.Mem.ReadPtr(playerInfoPtr + PoE2Offsets.LocalPlayerStruct["LocalPlayerPtr"])
        localPlayerPtr := this.ResolveEntityPointer(localPlayerRawPtr)
        if !this.IsPlausibleEntityPointer(localPlayerPtr)
        {
            localPlayerPtr := this.FindLocalPlayerEntityFromArea(areaInstanceAddress, 128)
            if this.IsProbablyValidPointer(localPlayerPtr)
                localPlayerRawPtr := localPlayerPtr
        }
        serverDataPtr := this.ResolveServerDataPointer(playerInfoPtr, serverDataRawPtr)

        playerVitals := this.ReadPlayerVitals(localPlayerPtr)
        playerBuffsComponent := this.ReadPlayerBuffsComponent(localPlayerPtr)
        playerSkills := this.ReadPlayerSkills(localPlayerPtr)
        flaskSlotsFromBuffs := (playerBuffsComponent && playerBuffsComponent.Has("flaskSlots"))
            ? playerBuffsComponent["flaskSlots"]
            : this.ReadFlaskSlotsFromBuffs(localPlayerPtr)

        serverData := this.ReadServerData(serverDataPtr, true)
        if (serverData && serverData.Has("flaskInventory"))
        {
            flaskInventory := serverData["flaskInventory"]
            if (flaskInventory && flaskInventory.Has("flaskSlots") && flaskSlotsFromBuffs)
                this.MergeFlaskSlotsWithBuffs(flaskInventory["flaskSlots"], flaskSlotsFromBuffs)
        }

        playerStructCompat := Map(
            "localPlayerPtr", localPlayerPtr,
            "localPlayerRawPtr", localPlayerRawPtr,
            "vitalStruct", playerVitals,
            "playerVitals", playerVitals
        )

        return Map(
            "address", areaInstanceAddress,
            "currentAreaLevel", currentAreaLevel,
            "currentAreaHash", currentAreaHash,
            "serverDataPtr", serverDataPtr,
            "serverDataRawPtr", serverDataRawPtr,
            "localPlayerPtr", localPlayerPtr,
            "localPlayerRawPtr", localPlayerRawPtr,
            "vitalStruct", playerVitals,
            "playerStruct", playerStructCompat,
            "playerVitals", playerVitals,
            "playerBuffsComponent", playerBuffsComponent,
            "playerSkills", playerSkills,
            "flaskSlotsFromBuffs", flaskSlotsFromBuffs,
            "serverData", serverData
        )
    }

    ; Root reader: reads the full InGameState tree including area instance, world data, and UI elements.
    ; Falls back to ReadAreaInstanceAutoFlask to populate missing player vitals when needed.
    ; Returns: Map with address, area/world/UI subtrees; or 0 if inGameStateAddress is invalid.
    ReadInGameState(inGameStateAddress)
    {
        if !this.IsProbablyValidPointer(inGameStateAddress)
            return 0

        areaInstanceData := this.Mem.ReadPtr(inGameStateAddress + PoE2Offsets.InGameState["AreaInstanceData"])
        worldData := this.Mem.ReadPtr(inGameStateAddress + PoE2Offsets.InGameState["WorldData"])
        uiRootStructPtr := this.Mem.ReadPtr(inGameStateAddress + PoE2Offsets.InGameState["UiRootStructPtr"])
        worldDataDetails := this.ReadWorldData(worldData)
        areaInstanceDetails := this.ReadAreaInstanceBasic(areaInstanceData)

        needsPlayerFallback := true
        if (areaInstanceDetails && Type(areaInstanceDetails) = "Map")
        {
            if (areaInstanceDetails.Has("playerVitals") && areaInstanceDetails["playerVitals"])
                needsPlayerFallback := false
            else if (areaInstanceDetails.Has("vitalStruct") && areaInstanceDetails["vitalStruct"])
                needsPlayerFallback := false
        }

        if needsPlayerFallback
        {
            areaInstanceFallback := this.ReadAreaInstanceAutoFlask(areaInstanceData)
            if (areaInstanceFallback && Type(areaInstanceFallback) = "Map")
            {
                if !(areaInstanceDetails && Type(areaInstanceDetails) = "Map")
                    areaInstanceDetails := Map()

                mergeKeys := [
                    "localPlayerPtr",
                    "localPlayerRawPtr",
                    "playerVitals",
                    "vitalStruct",
                    "playerStruct",
                    "playerBuffsComponent",
                    "flaskSlotsFromBuffs",
                    "serverData",
                    "serverDataPtr",
                    "serverDataRawPtr"
                ]

                for _, key in mergeKeys
                {
                    if areaInstanceFallback.Has(key)
                        areaInstanceDetails[key] := areaInstanceFallback[key]
                }
            }
        }

        uiRootPtr := 0
        gameUiPtr := 0
        gameUiControllerPtr := 0
        activeGameUiPtr := 0
        isControllerMode := false

        if this.IsProbablyValidPointer(uiRootStructPtr)
        {
            uiRootPtr := this.Mem.ReadPtr(uiRootStructPtr + PoE2Offsets.UiRootStruct["UiRootPtr"])
            gameUiPtr := this.Mem.ReadPtr(uiRootStructPtr + PoE2Offsets.UiRootStruct["GameUiPtr"])
            gameUiControllerPtr := this.Mem.ReadPtr(uiRootStructPtr + PoE2Offsets.UiRootStruct["GameUiControllerPtr"])
            if (!gameUiPtr && gameUiControllerPtr)
            {
                isControllerMode := true
                activeGameUiPtr := gameUiControllerPtr
            }
            else
            {
                activeGameUiPtr := gameUiPtr
            }
        }

        importantUiElements := this.ReadImportantUiElements(activeGameUiPtr, isControllerMode)

        return Map(
            "address", inGameStateAddress,
            "areaInstanceData", areaInstanceData,
            "areaInstance", areaInstanceDetails,
            "worldData", worldData,
            "worldDataDetails", worldDataDetails,
            "uiRootStructPtr", uiRootStructPtr,
            "uiRootPtr", uiRootPtr,
            "gameUiPtr", gameUiPtr,
            "gameUiControllerPtr", gameUiControllerPtr,
            "activeGameUiPtr", activeGameUiPtr,
            "isControllerMode", isControllerMode,
            "importantUiElements", importantUiElements
        )
    }

    ; Reads map UI pointers (MiniMap, LargeMap) and chat background alpha to detect the chat-open state.
    ; Params: isControllerMode - if true, prefers ControllerModeMapParentPtr over MapParentPtr.
    ReadImportantUiElements(gameUiPtr, isControllerMode := false)
    {
        if !this.IsProbablyValidPointer(gameUiPtr)
            return 0

        chatParentPtr     := this.Mem.ReadPtr(gameUiPtr + PoE2Offsets.ImportantUiElements["ChatParentPtr"])
        passiveTreePanel  := this.Mem.ReadPtr(gameUiPtr + PoE2Offsets.ImportantUiElements["PassiveSkillTreePanel"])
        mapParentPtr      := this.Mem.ReadPtr(gameUiPtr + PoE2Offsets.ImportantUiElements["MapParentPtr"])
        ctrlMapParentPtr  := this.Mem.ReadPtr(gameUiPtr + PoE2Offsets.ImportantUiElements["ControllerModeMapParentPtr"])

        ; Pick the active map parent depending on controller mode
        activeMapParentPtr := (isControllerMode && this.IsProbablyValidPointer(ctrlMapParentPtr))
            ? ctrlMapParentPtr
            : mapParentPtr

        largeMapPtr := 0
        miniMapPtr  := 0
        miniMapData := 0
        largeMapData := 0
        if this.IsProbablyValidPointer(activeMapParentPtr)
        {
            largeMapPtr := this.Mem.ReadPtr(activeMapParentPtr + PoE2Offsets.MapParentStruct["LargeMapPtr"])
            miniMapPtr  := this.Mem.ReadPtr(activeMapParentPtr + PoE2Offsets.MapParentStruct["MiniMapPtr"])

            ; Cache location can become stale (same issue as PassiveSkillTree).
            ; Fall back to navigating the children StdVector directly if both pointers are equal.
            if (largeMapPtr = miniMapPtr && this.IsProbablyValidPointer(largeMapPtr))
            {
                childrenDataPtr := this.Mem.ReadPtr(activeMapParentPtr + PoE2Offsets.UiElementBase["ChildrenFirst"])
                if this.IsProbablyValidPointer(childrenDataPtr)
                {
                    largeMapPtr := this.Mem.ReadPtr(childrenDataPtr + 0 * 8)  ; 1st child
                    miniMapPtr  := this.Mem.ReadPtr(childrenDataPtr + 1 * 8)  ; 2nd child
                }
            }

            if this.IsProbablyValidPointer(miniMapPtr)
                miniMapData := this.ReadMapUiElementData(miniMapPtr)
            if this.IsProbablyValidPointer(largeMapPtr)
                largeMapData := this.ReadMapUiElementData(largeMapPtr)
        }

        ; ChatParentUiElement — IsChatActive detection.
        ; Strategy: check background alpha on chatParent and its first children (float4 .W and uint approach).
        ; Also check visibility flags as a secondary signal.
        chatAlphaFloat := 0.0
        chatAlpha      := 0
        isChatActive   := false
        chatDebugInfo  := ""
        if this.IsProbablyValidPointer(chatParentPtr)
        {
            bgColorOffset := PoE2Offsets.UiElementBase["BackgroundColor"]
            childrenFirstOffset := PoE2Offsets.UiElementBase["ChildrenFirst"]
            flagsOffset := PoE2Offsets.UiElementBase["Flags"]

            ; Read raw values at BackgroundColor offset from parent for diagnostics
            parentFloatW := this.Mem.ReadFloat(chatParentPtr + bgColorOffset + 12)
            parentUint   := this.Mem.ReadUInt(chatParentPtr + bgColorOffset)
            parentFlags  := this.Mem.ReadUInt(chatParentPtr + flagsOffset)
            parentVisible := (parentFlags >> 11) & 1

            bestAlpha := parentFloatW
            bestSource := "parent-float"
            chatDebugInfo := "pF=" Round(parentFloatW, 3) " pU=" Format("0x{:08X}", parentUint) " pVis=" parentVisible

            ; Check children
            childrenFirst := this.Mem.ReadPtr(chatParentPtr + childrenFirstOffset)
            childrenLast  := this.Mem.ReadPtr(chatParentPtr + childrenFirstOffset + A_PtrSize)
            childCount := 0
            if (this.IsProbablyValidPointer(childrenFirst) && this.IsProbablyValidPointer(childrenLast) && childrenLast > childrenFirst)
                childCount := Min(Floor((childrenLast - childrenFirst) / A_PtrSize), 8)

            chatDebugInfo .= " ch=" childCount
            idx := 0
            while (idx < childCount && idx < 5)
            {
                childPtr := this.Mem.ReadPtr(childrenFirst + idx * A_PtrSize)
                if this.IsProbablyValidPointer(childPtr)
                {
                    cFloatW := this.Mem.ReadFloat(childPtr + bgColorOffset + 12)
                    cUint   := this.Mem.ReadUInt(childPtr + bgColorOffset)
                    cFlags  := this.Mem.ReadUInt(childPtr + flagsOffset)
                    cVis    := (cFlags >> 11) & 1
                    chatDebugInfo .= " c" idx "F=" Round(cFloatW, 3) "/U=" Format("0x{:X}", cUint) "/V=" cVis

                    if (cFloatW > bestAlpha)
                    {
                        bestAlpha := cFloatW
                        bestSource := "child" idx "-float"
                    }
                    cUintAlpha := (cUint >> 24) & 0xFF
                    if (cUintAlpha / 255.0 > bestAlpha)
                    {
                        bestAlpha := cUintAlpha / 255.0
                        bestSource := "child" idx "-uint"
                    }
                }
                idx += 1
            }

            chatAlphaFloat := bestAlpha
            chatAlpha      := Round(chatAlphaFloat * 255)
            isChatActive   := chatAlpha >= 0x8C
        }

        return Map(
            "chatParentPtr",              chatParentPtr,
            "chatAlphaFloat",             chatAlphaFloat,
            "chatAlpha",                  chatAlpha,
            "isChatActive",               isChatActive,
            "chatDebugInfo",              chatDebugInfo,
            "passiveSkillTreePanel",      passiveTreePanel,
            "passiveTreeVisible",         (this.IsProbablyValidPointer(passiveTreePanel)
                                           && (this.Mem.ReadUInt(passiveTreePanel + PoE2Offsets.UiElementBase["Flags"]) >> 11) & 1) ? true : false,
            "mapParentPtr",               mapParentPtr,
            "controllerModeMapParentPtr", ctrlMapParentPtr,
            "activeMapParentPtr",         activeMapParentPtr,
            "largeMapPtr",                largeMapPtr,
            "miniMapPtr",                 miniMapPtr,
            "miniMapData",                miniMapData,
            "largeMapData",               largeMapData
        )
    }

    ; ── Panel discovery ──────────────────────────────────────────────────
    ; Scans the ImportantUiElements struct memory (0x400..0xC00) at 8-byte intervals.
    ; Scans the ImportantUiElements struct for heap UiElement pointers and records
    ; their initial IS_VISIBLE state as a baseline. The real-time check
    ; (ReadAllPanelVisibility) compares current visibility to this baseline —
    ; any element that was invisible at baseline but is now visible = panel open.
    ;
    ; This is an expensive one-time operation. Call once at startup or on zone change,
    ; then use ReadAllPanelVisibility() for cheap per-tick checks.
    DiscoverPanelOffsets(gameUiPtr)
    {
        result := Map()

        if !this.IsProbablyValidPointer(gameUiPtr)
            return result

        parentPtrOff := PoE2Offsets.UiElementBase["ParentPtr"]

        ; ── Phase 1: scan struct for heap UiElement pointers ──
        scanStart := 0x400
        scanEnd := 0xC00
        scanSize := scanEnd - scanStart
        structBuf := this.Mem.ReadBytes(gameUiPtr + scanStart, scanSize)
        if !structBuf
            return result

        scannedPtrCount := 0
        heapPtrCount := 0
        uiElemCount := 0

        heapElements := []
        off := 0
        while (off < scanSize)
        {
            candidatePtr := NumGet(structBuf.Ptr, off, "Int64")
            structOffset := scanStart + off
            off += 8
            scannedPtrCount += 1

            if !this.IsProbablyValidPointer(candidatePtr)
                continue
            if (candidatePtr >= 0x7FF000000000)
                continue

            heapPtrCount += 1
            parentPtr := this.Mem.ReadPtr(candidatePtr + parentPtrOff)
            if !this.IsProbablyValidPointer(parentPtr)
                continue

            uiElemCount += 1
            heapElements.Push(Map("off", structOffset, "ptr", candidatePtr))
        }

        ; ── Phase 2: visibility baseline scan ──
        flagsOffset := PoE2Offsets.UiElementBase["Flags"]
        knownOffsets := Map(0x5C0, "ChatParent", 0x6B0, "PassiveTree", 0x748, "MapParent", 0xAA8, "CtrlMapParent")
        visBaseline := Map()
        visibleCount := 0
        invisibleCount := 0
        diagSamples := []

        for _, elem in heapElements
        {
            elemPtr := elem["ptr"]
            structOffset := elem["off"]

            flags := this.Mem.ReadUInt(elemPtr + flagsOffset)
            isVis := ((flags >> 11) & 1) ? true : false
            visBaseline[structOffset] := {ptr: elemPtr, vis: isVis, flags: flags}

            if isVis
                visibleCount += 1
            else
                invisibleCount += 1

            if (diagSamples.Length < 60)
            {
                label := knownOffsets.Has(structOffset) ? knownOffsets[structOffset] : ""
                diagSamples.Push(Map(
                    "idx", Format("0x{:X}", structOffset),
                    "ptr", Format("0x{:X}", elemPtr),
                    "stringId", label,
                    "rawHex", Format("0x{:08X}", flags),
                    "childInfo", isVis ? "👁 VISIBLE" : "· hidden"
                ))
            }
        }

        ; Store for real-time differential checks
        this._heapUiElems := heapElements
        this._visBaseline := visBaseline
        this._visBaselineTaken := true

        result["_totalChildren"] := scannedPtrCount
        result["_heapPtrCount"] := heapPtrCount
        result["_uiElemCount"] := uiElemCount
        result["_diagSamples"] := diagSamples
        result["_visibleCount"] := visibleCount
        result["_invisibleCount"] := invisibleCount
        return result
    }

    ; Helper: try both UTF-16 and UTF-8 string readers at an address
    _TryReadStringId(addr)
    {
        try
        {
            s := this.ReadStdWStringAt(addr, 128)
            if (s != "")
                return s
        }
        try
        {
            s := this.ReadStdStringAt(addr, 128)
            if (s != "")
                return s
        }
        return ""
    }

    ; Helper: hex dump a Buffer (or return "" if null)
    _HexDump(buf, maxBytes)
    {
        if !buf
            return ""
        hexStr := ""
        i := 0
        while (i < maxBytes && i < buf.Size)
        {
            hexStr .= Format("{:02X} ", NumGet(buf.Ptr, i, "UChar"))
            i += 1
        }
        return hexStr
    }

    ; Refreshes the visibility baseline using the already-discovered heap UiElements.
    ; Call this when you KNOW all panels are closed (e.g. after zone load or user action).
    ; Much cheaper than full DiscoverPanelOffsets — no struct scan, just re-reads flags.
    RefreshVisibilityBaseline()
    {
        if (this._heapUiElems.Length = 0)
            return false

        flagsOffset := PoE2Offsets.UiElementBase["Flags"]
        visBaseline := Map()

        for _, elem in this._heapUiElems
        {
            elemPtr := elem["ptr"]
            structOff := elem["off"]
            flags := this.Mem.ReadUInt(elemPtr + flagsOffset)
            isVis := ((flags >> 11) & 1) ? true : false
            visBaseline[structOff] := {ptr: elemPtr, vis: isVis, flags: flags}
        }

        this._visBaseline := visBaseline
        this._visBaselineTaken := true

        ; Also snapshot the raw struct bytes for pointer-level change detection
        if this.IsProbablyValidPointer(this._lastActiveGameUiPtr)
        {
            structBuf := this.Mem.ReadBytes(this._lastActiveGameUiPtr + 0x400, 0x800)
            if structBuf
            {
                rawCopy := Buffer(0x800)
                DllCall("RtlMoveMemory", "Ptr", rawCopy.Ptr, "Ptr", structBuf.Ptr, "UInt", 0x800)
                this._structBaselineRaw := rawCopy
            }
        }
        return true
    }

    ; Reads visibility (Flags bit 11) for all heap UiElements discovered in Phase 1.
    ; Uses visibility-differential: compares current state to baseline.
    ; Detects BOTH newly visible AND newly hidden elements as panel state changes.
    ; Also performs raw struct pointer-level change detection (1 RPM call).
    ; Returns: Map with "anyPanelOpen" → bool, "newlyVisible" → count,
    ;          "newlyHidden" → count, "totalChanged" → count,
    ;          "currentVisible" → count, "baselineVisible" → count
    ReadAllPanelVisibility(gameUiPtr)
    {
        vis := Map()
        vis["anyPanelOpen"] := false
        vis["newlyVisible"] := 0
        vis["newlyHidden"] := 0
        vis["totalChanged"] := 0
        vis["currentVisible"] := 0
        vis["baselineVisible"] := 0
        vis["ptrChanges"] := 0
        vis["_changedOffsets"] := []

        if (!this._visBaselineTaken || this._heapUiElems.Length = 0)
            return vis

        flagsOffset := PoE2Offsets.UiElementBase["Flags"]
        ; Skip containers that always have visibility and fluctuate for other reasons
        knownAlwaysVisible := Map(0x5C0, true, 0x6B0, true, 0x748, true, 0xAA8, true)
        newlyVisCount := 0
        newlyHidCount := 0
        currentVisCount := 0
        baselineVisCount := 0

        for _, elem in this._heapUiElems
        {
            structOff := elem["off"]
            elemPtr := elem["ptr"]

            flags := this.Mem.ReadUInt(elemPtr + flagsOffset)
            isVisNow := ((flags >> 11) & 1) ? true : false

            if isVisNow
                currentVisCount += 1

            if this._visBaseline.Has(structOff)
            {
                wasVis := this._visBaseline[structOff].vis
                if wasVis
                    baselineVisCount += 1

                if (knownAlwaysVisible.Has(structOff))
                    continue

                ; Newly visible = was hidden → now visible (panel opened)
                if (isVisNow && !wasVis)
                {
                    newlyVisCount += 1
                    if (vis["_changedOffsets"].Length < 20)
                        vis["_changedOffsets"].Push(Format("+0x{:X}", structOff))
                }
                ; Newly hidden = was visible → now hidden (panel state change)
                else if (!isVisNow && wasVis)
                {
                    newlyHidCount += 1
                    if (vis["_changedOffsets"].Length < 20)
                        vis["_changedOffsets"].Push(Format("-0x{:X}", structOff))
                }
            }
        }

        ; ── Raw struct pointer-level change detection (1 RPM call for 2KB) ──
        ptrsAppeared := 0
        ptrsDisappeared := 0
        if (this.HasOwnProp("_structBaselineRaw") && IsObject(this._structBaselineRaw)
            && this.IsProbablyValidPointer(gameUiPtr))
        {
            newBuf := this.Mem.ReadBytes(gameUiPtr + 0x400, 0x800)
            if newBuf
            {
                off := 0
                while (off < 0x800)
                {
                    oldVal := NumGet(this._structBaselineRaw.Ptr, off, "Int64")
                    newVal := NumGet(newBuf.Ptr, off, "Int64")
                    structOff := 0x400 + off
                    if (oldVal != newVal && !knownAlwaysVisible.Has(structOff))
                    {
                        oldIsPtr := (oldVal > 0x10000 && oldVal < 0x7FF000000000)
                        newIsPtr := (newVal > 0x10000 && newVal < 0x7FF000000000)
                        oldIsNull := (oldVal = 0 || !oldIsPtr)
                        newIsNull := (newVal = 0 || !newIsPtr)

                        if (oldIsNull && newIsPtr)
                            ptrsAppeared += 1
                        else if (oldIsPtr && newIsNull)
                            ptrsDisappeared += 1
                    }
                    off += 8
                }
            }
        }

        ; Panel is open = new elements became visible OR new pointers appeared
        ; (closing a panel reverts these — newlyHidden/ptrsDisappeared don't count as "open")
        vis["anyPanelOpen"] := (newlyVisCount > 0 || ptrsAppeared > 0)
        vis["newlyVisible"] := newlyVisCount
        vis["newlyHidden"] := newlyHidCount
        vis["totalChanged"] := newlyVisCount + newlyHidCount
        vis["ptrsAppeared"] := ptrsAppeared
        vis["ptrsDisappeared"] := ptrsDisappeared
        vis["currentVisible"] := currentVisCount
        vis["baselineVisible"] := baselineVisCount
        return vis
    }

    ; Returns true if ANY panel is detected as open (newly visible vs baseline).
    IsAnyPanelOpen(panelVisMap)
    {
        if !IsObject(panelVisMap)
            return false
        return panelVisMap.Has("anyPanelOpen") ? panelVisMap["anyPanelOpen"] : false
    }

    ; ── Struct Diff Diagnostic ──────────────────────────────────────────
    ; Snapshots raw struct bytes (0x400-0xC00) and per-element fields.
    ; User takes snapshot with panels closed, then compares with panel open.
    TakeStructDiffSnapshot(gameUiPtr)
    {
        if !this.IsProbablyValidPointer(gameUiPtr)
            return false

        ; Raw struct bytes (2KB, single RPM call)
        scanStart := 0x400
        scanSize := 0x800
        structBuf := this.Mem.ReadBytes(gameUiPtr + scanStart, scanSize)
        if !structBuf
            return false

        rawCopy := Buffer(scanSize)
        DllCall("RtlMoveMemory", "Ptr", rawCopy.Ptr, "Ptr", structBuf.Ptr, "UInt", scanSize)

        snap := Map()
        snap["rawBuf"] := rawCopy
        snap["scanStart"] := scanStart
        snap["scanSize"] := scanSize

        ; Per-element key fields
        elemSnaps := Map()
        for _, elem in this._heapUiElems
        {
            off := elem["off"]
            ptr := elem["ptr"]

            flags := this.Mem.ReadUInt(ptr + 0x180)
            sizeX := this.Mem.ReadFloat(ptr + 0x288)
            sizeY := this.Mem.ReadFloat(ptr + 0x28C)
            childFirst := this.Mem.ReadPtr(ptr + 0x010)
            childEnd := this.Mem.ReadPtr(ptr + 0x018)
            childCount := (childFirst && childEnd && childEnd > childFirst)
                ? ((childEnd - childFirst) // 8) : 0

            elemSnaps[off] := Map(
                "flags", flags,
                "sizeX", sizeX, "sizeY", sizeY,
                "childCount", childCount,
                "ptr", ptr
            )
        }
        snap["elemSnaps"] := elemSnaps

        this._diffSnapshot := snap
        this._diffSnapshotTaken := true
        return true
    }

    ; Compares current struct + element fields against snapshot.
    ; Returns Map with structChanges[] and elemChanges[].
    CompareStructDiffSnapshot(gameUiPtr)
    {
        result := Map()
        result["structChanges"] := []
        result["elemChanges"] := []
        result["success"] := false

        if (!this._diffSnapshotTaken || !IsObject(this._diffSnapshot))
            return result
        if !this.IsProbablyValidPointer(gameUiPtr)
            return result

        snap := this._diffSnapshot

        ; ── Raw struct byte-by-byte comparison ──
        scanStart := snap["scanStart"]
        scanSize := snap["scanSize"]
        newBuf := this.Mem.ReadBytes(gameUiPtr + scanStart, scanSize)
        if !newBuf
            return result

        oldBuf := snap["rawBuf"]
        structChanges := []
        i := 0
        while (i < scanSize)
        {
            oldByte := NumGet(oldBuf.Ptr, i, "UChar")
            newByte := NumGet(newBuf.Ptr, i, "UChar")
            if (oldByte != newByte && structChanges.Length < 100)
            {
                structChanges.Push(Map(
                    "off", Format("0x{:03X}", scanStart + i),
                    "old", Format("0x{:02X}", oldByte),
                    "new", Format("0x{:02X}", newByte)
                ))
            }
            i += 1
        }
        result["structChanges"] := structChanges

        ; ── Per-element field comparison ──
        oldElems := snap["elemSnaps"]
        elemChanges := []
        knownNames := Map(0x5C0, "ChatParent", 0x6B0, "PassiveTree",
            0x748, "MapParent", 0xAA8, "CtrlMapParent")

        for _, elem in this._heapUiElems
        {
            off := elem["off"]
            ptr := elem["ptr"]
            if !oldElems.Has(off)
                continue

            old := oldElems[off]
            flags := this.Mem.ReadUInt(ptr + 0x180)
            sizeX := this.Mem.ReadFloat(ptr + 0x288)
            sizeY := this.Mem.ReadFloat(ptr + 0x28C)
            childFirst := this.Mem.ReadPtr(ptr + 0x010)
            childEnd := this.Mem.ReadPtr(ptr + 0x018)
            childCount := (childFirst && childEnd && childEnd > childFirst)
                ? ((childEnd - childFirst) // 8) : 0

            changes := []
            if (flags != old["flags"])
                changes.Push("flags:" Format("0x{:08X}", old["flags"]) "→" Format("0x{:08X}", flags))
            if (Round(sizeX, 0) != Round(old["sizeX"], 0) || Round(sizeY, 0) != Round(old["sizeY"], 0))
                changes.Push("size:" Round(old["sizeX"], 0) "×" Round(old["sizeY"], 0) "→" Round(sizeX, 0) "×" Round(sizeY, 0))
            if (childCount != old["childCount"])
                changes.Push("children:" old["childCount"] "→" childCount)

            if (changes.Length > 0)
            {
                label := knownNames.Has(off) ? knownNames[off] : ""
                elemChanges.Push(Map(
                    "off", Format("0x{:X}", off),
                    "ptr", Format("0x{:X}", ptr),
                    "label", label,
                    "changes", changes
                ))
            }
        }
        result["elemChanges"] := elemChanges
        result["success"] := true
        return result
    }

    ; Reads position, size, shift and zoom from a MapUiElement pointer.
    ; Position is computed via a full parent-chain traversal (replicating C# GetUnScaledPosition()).
    ; Returned unscaledPosX/Y are in UI base coords (2560×1600).  Caller must apply GameWindowScale.
    ; For MiniMap the position is the TOP-LEFT; for LargeMap it is the MAP CENTER.
    ReadMapUiElementData(mapElemPtr)
    {
        if !this.IsProbablyValidPointer(mapElemPtr)
            return 0

        ; ── Walk parent chain (element → parent → … → root) ──────────────────────
        ; chain[1]=element, chain[2]=parent, ..., chain[N]=root
        chain := []
        curPtr := mapElemPtr
        Loop 10 {
            if !this.IsProbablyValidPointer(curPtr)
                break
            relX    := this.Mem.ReadFloat(curPtr + PoE2Offsets.UiElementBase["RelativePosition"])
            relY    := this.Mem.ReadFloat(curPtr + PoE2Offsets.UiElementBase["RelativePosition"] + 4)
            flags   := this.Mem.ReadUInt( curPtr + PoE2Offsets.UiElementBase["Flags"])
            posModX := this.Mem.ReadFloat(curPtr + PoE2Offsets.UiElementBase["PositionModifier"])
            posModY := this.Mem.ReadFloat(curPtr + PoE2Offsets.UiElementBase["PositionModifier"] + 4)
            parentP := this.Mem.ReadPtr(  curPtr + PoE2Offsets.UiElementBase["ParentPtr"])
            chain.Push(Map(
                "relX", relX, "relY", relY,
                "flags", flags,
                "posModX", posModX, "posModY", posModY
            ))
            if !this.IsProbablyValidPointer(parentP)
                break
            curPtr := parentP
        }

        ; ── Simulate C# GetUnScaledPosition() from root → element ─────────────────
        ; Root element returns its own relativePosition; each child adds its relativePosition
        ; and, if its own ShouldModifyPos flag (bit 10) is set, also its parent's positionModifier.
        N := chain.Length
        accX := 0.0
        accY := 0.0
        if N > 0 {
            accX := chain[N]["relX"]    ; root starts from its own relPos
            accY := chain[N]["relY"]
            Loop N - 1 {
                childIdx  := N - A_Index    ; walks N-1, N-2, …, 1
                parentIdx := childIdx + 1
                child  := chain[childIdx]
                parent := chain[parentIdx]
                if (child["flags"] >> 10) & 1 {    ; ShouldModifyPos = bit 10
                    accX += parent["posModX"]
                    accY += parent["posModY"]
                }
                accX += child["relX"]
                accY += child["relY"]
            }
        }

        ; ── Scale info from the map element itself ─────────────────────────────────
        ; GameWindowScale: v1 = (gwW-2*cull)/2560, v2 = gwH/1600
        ;   scaleIdx 1 → wScale = lMult*v1, hScale = lMult*v1
        ;   scaleIdx 2 → wScale = lMult*v2, hScale = lMult*v2
        ;   scaleIdx 3 → wScale = lMult*v1, hScale = lMult*v2  (most UI elements)
        scaleIdx  := this.Mem.ReadUChar(mapElemPtr + PoE2Offsets.UiElementBase["ScaleIndex"])
        localMult := this.Mem.ReadFloat(mapElemPtr + PoE2Offsets.UiElementBase["LocalScaleMultiplier"])

        ; ── Map element fields ─────────────────────────────────────────────────────
        flags     := (N > 0) ? chain[1]["flags"] : 0
        isVisible := (flags >> 11) & 1
        sizeW     := this.Mem.ReadFloat(mapElemPtr + PoE2Offsets.UiElementBase["UnscaledSize"])
        sizeH     := this.Mem.ReadFloat(mapElemPtr + PoE2Offsets.UiElementBase["UnscaledSize"] + 4)
        shiftX    := this.Mem.ReadFloat(mapElemPtr + PoE2Offsets.MapUiElement["Shift"])
        shiftY    := this.Mem.ReadFloat(mapElemPtr + PoE2Offsets.MapUiElement["Shift"] + 4)
        defShiftX := this.Mem.ReadFloat(mapElemPtr + PoE2Offsets.MapUiElement["DefaultShift"])
        defShiftY := this.Mem.ReadFloat(mapElemPtr + PoE2Offsets.MapUiElement["DefaultShift"] + 4)
        zoom      := this.Mem.ReadFloat(mapElemPtr + PoE2Offsets.MapUiElement["Zoom"])

        return Map(
            "ptr",           mapElemPtr,
            "unscaledPosX",  accX,       ; UI-coord position (apply GameWindowScale to get screen pixels)
            "unscaledPosY",  accY,
            "scaleIdx",      scaleIdx,   ; for GameWindowScale lookup
            "localMult",     localMult,
            "flags",         flags,
            "isVisible",     isVisible,
            "sizeW",         sizeW,      ; unscaled element size (UI coords)
            "sizeH",         sizeH,
            "shiftX",        shiftX,     ; already in screen-pixel units (no additional scaling needed)
            "shiftY",        shiftY,
            "defaultShiftX", defShiftX,
            "defaultShiftY", defShiftY,
            "zoom",          zoom,
            "chainDepth",    N,
            "relX",          (N > 0) ? chain[1]["relX"] : 0   ; debug: element's own relPos
        )
    }

    ; Reads world area details and the .dat row pointer for use in area name and property resolution.
    ReadWorldData(worldDataAddress)
    {
        if !this.IsProbablyValidPointer(worldDataAddress)
            return 0

        worldAreaDetailsPtr := this.Mem.ReadPtr(worldDataAddress + PoE2Offsets.WorldData["WorldAreaDetailsPtr"])
        worldAreaDetailsRowPtr := 0
        worldAreaDat := 0
        if this.IsProbablyValidPointer(worldAreaDetailsPtr)
        {
            worldAreaDetailsRowPtr := this.Mem.ReadPtr(worldAreaDetailsPtr + PoE2Offsets.WorldData["WorldAreaDetailsRowPtr"])
            worldAreaDat := this.ReadWorldAreaDat(worldAreaDetailsRowPtr)
        }

        return Map(
            "address", worldDataAddress,
            "worldAreaDetailsPtr", worldAreaDetailsPtr,
            "worldAreaDetailsRowPtr", worldAreaDetailsRowPtr,
            "worldAreaDat", worldAreaDat
        )
    }

    ; Collects awake and sleeping entities, all player components, flask slots, and server data.
    ; Scans AwakeEntities and SleepingEntities maps up to their respective configured sample limits.
    ; Returns: Map with entity arrays, all player component subtrees, flask data, and server data.
    ReadAreaInstanceBasic(areaInstanceAddress)
    {
        if !this.IsProbablyValidPointer(areaInstanceAddress)
            return 0

        currentAreaLevel := this.Mem.ReadUChar(areaInstanceAddress + PoE2Offsets.AreaInstance["CurrentAreaLevel"])
        currentAreaHash := this.Mem.ReadUInt(areaInstanceAddress + PoE2Offsets.AreaInstance["CurrentAreaHash"])

        this.LastAreaInstanceAddress := areaInstanceAddress
        this.LastAreaHash := currentAreaHash
        this.LastAreaLevel := currentAreaLevel

        playerInfoPtr := areaInstanceAddress + PoE2Offsets.AreaInstance["PlayerInfo"]
        serverDataRawPtr := this.Mem.ReadPtr(playerInfoPtr + PoE2Offsets.LocalPlayerStruct["ServerDataPtr"])
        localPlayerRawPtr := this.Mem.ReadPtr(playerInfoPtr + PoE2Offsets.LocalPlayerStruct["LocalPlayerPtr"])
        localPlayerPtr := this.ResolveEntityPointer(localPlayerRawPtr)
        if !this.IsPlausibleEntityPointer(localPlayerPtr)
        {
            localPlayerPtr := this.FindLocalPlayerEntityFromArea(areaInstanceAddress, 160)
            if this.IsProbablyValidPointer(localPlayerPtr)
                localPlayerRawPtr := localPlayerPtr
        }

        serverDataPtr := this.ResolveServerDataPointer(playerInfoPtr, serverDataRawPtr)
        awakeLimit := this.AwakeEntitySampleLimit ? this.AwakeEntitySampleLimit : 16
        sleepingLimit := this.SleepingEntitySampleLimit ? this.SleepingEntitySampleLimit : 8
        playerRenderComponent := this.ReadPlayerRenderComponent(localPlayerPtr)
        playerOrigin := this.ExtractWorldPositionFromRenderComponent(playerRenderComponent)

        entityListOffset := PoE2Offsets.AreaInstance["AwakeEntities"]
        awakeMapAddress := areaInstanceAddress + entityListOffset
        sleepingMapAddress := awakeMapAddress + 0x10
        awakeEntities := this.ReadAreaEntityMapSummary(awakeMapAddress, awakeLimit, playerOrigin)
        sleepingEntities := this.ReadAreaEntityMapSummary(sleepingMapAddress, sleepingLimit, playerOrigin)

        this.LastEntityReadOffset := entityListOffset
        this.LastEntityReadMode := "direct"

        serverData := this.ReadServerData(serverDataPtr)
        playerVitals := this.ReadPlayerVitals(localPlayerPtr)
        playerComponent := this.ReadPlayerComponent(localPlayerPtr)
        playerStatsComponent := this.ReadPlayerStatsComponent(localPlayerPtr)
        playerBuffsComponent := this.ReadPlayerBuffsComponent(localPlayerPtr)
        playerChargesComponent := this.ReadPlayerChargesComponent(localPlayerPtr)
        playerPositionedComponent := this.ReadPlayerPositionedComponent(localPlayerPtr)
        playerTransitionableComponent := this.ReadPlayerTransitionableComponent(localPlayerPtr)
        playerStateMachineComponent := this.ReadPlayerStateMachineComponent(localPlayerPtr)
        playerTargetableComponent := this.ReadPlayerTargetableComponent(localPlayerPtr)
        playerActorComponent := this.ReadPlayerActorComponentBasic(localPlayerPtr)
        playerSkills := this.ReadPlayerSkills(localPlayerPtr)
        flaskSlotsFromBuffs := (playerBuffsComponent && playerBuffsComponent.Has("flaskSlots"))
            ? playerBuffsComponent["flaskSlots"]
            : this.ReadFlaskSlotsFromBuffs(localPlayerPtr)

        if (serverData && serverData.Has("flaskInventory"))
        {
            flaskInventory := serverData["flaskInventory"]
            if (flaskInventory && flaskInventory.Has("flaskSlots") && flaskSlotsFromBuffs)
                this.MergeFlaskSlotsWithBuffs(flaskInventory["flaskSlots"], flaskSlotsFromBuffs)
        }

        playerStructCompat := Map(
            "localPlayerPtr", localPlayerPtr,
            "localPlayerRawPtr", localPlayerRawPtr,
            "vitalStruct", playerVitals,
            "playerVitals", playerVitals
        )

        return Map(
            "address", areaInstanceAddress,
            "currentAreaLevel", currentAreaLevel,
            "currentAreaHash", currentAreaHash,
            "entityListOffset", entityListOffset,
            "awakeMapAddress", awakeMapAddress,
            "sleepingMapAddress", sleepingMapAddress,
            "serverDataPtr", serverDataPtr,
            "serverDataRawPtr", serverDataRawPtr,
            "localPlayerPtr", localPlayerPtr,
            "localPlayerRawPtr", localPlayerRawPtr,
            "awakeEntities", awakeEntities,
            "sleepingEntities", sleepingEntities,
            "vitalStruct", playerVitals,
            "playerStruct", playerStructCompat,
            "playerVitals", playerVitals,
            "playerComponent", playerComponent,
            "playerStatsComponent", playerStatsComponent,
            "playerBuffsComponent", playerBuffsComponent,
            "playerChargesComponent", playerChargesComponent,
            "playerPositionedComponent", playerPositionedComponent,
            "playerRenderComponent", playerRenderComponent,
            "playerTransitionableComponent", playerTransitionableComponent,
            "playerStateMachineComponent", playerStateMachineComponent,
            "playerTargetableComponent", playerTargetableComponent,
            "playerActorComponent", playerActorComponent,
            "playerSkills", playerSkills,
            "flaskSlotsFromBuffs", flaskSlotsFromBuffs,
            "serverData", serverData
        )
    }

    ; Filters ghost/dead entities from a radar entity summary.
    ; Dead signals (in order of reliability):
    ;   1. isValid=false — game engine invalidated the entity
    ;   2. isAlive=false — HP reached 0 (hard dead, immediate blacklist)
    ;   3. !lifeDecoded && targetableOff — both memory signals gone (corpse, immediate blacklist)
    ;   4. Targetable component present and reads 0, never read 1, for ≥3 s since first seen —
    ;      catches ghost entities that were already dead when we first observed them.
    ;   5. Targetable=0 for TargetableDeadThreshold consecutive ticks after being seen targetable=1
    ;      — catches monsters killed while being tracked whose HP memory stays stale.
    ;
    ; areaInstanceAddr is used to detect area transitions and reset all tracking maps.
    ; fullAwakeRawPtrs (optional): Map from ScanEntityMapRawPtrs() — entities removed from the
    ;   AwakeMap entirely are blacklisted immediately (network-bubble eviction signal).
    _FilterStaleRadarEntities(entitySummary, areaInstanceAddr, fullAwakeRawPtrs := 0)
    {
        if !(entitySummary && entitySummary.Has("sample"))
            return entitySummary

        ; Robust zone-change detection: use CurrentAreaHash instead of raw pointer.
        ; The raw AreaInstance pointer may not change between zones if the game reuses
        ; the same struct; the hash reliably changes on every area transition.
        areaHashKey := areaInstanceAddr
        if this.IsProbablyValidPointer(areaInstanceAddr)
        {
            areaHash := this.Mem.ReadUInt(areaInstanceAddr + PoE2Offsets.AreaInstance["CurrentAreaHash"])
            if (areaHash != 0)
                areaHashKey := areaHash
        }

        ; Reset all maps on area change (new map = fresh entity set).
        if (areaHashKey != this._lastAreaInstanceAddr)
        {
            this._deadEntityBlacklist := Map()
            this._everAliveAddrs      := Map()
            this._targetableDeadMap   := Map()
            this._targetableEverOn    := Map()
            this._firstSeenTick       := Map()
            this._posLastXY           := Map()
            this._posFrozenSinceTick  := Map()
            this._lastAreaInstanceAddr := areaHashKey
        }

        blacklist := this._deadEntityBlacklist
        sample    := entitySummary["sample"]
        newSample := []
        nowTick   := A_TickCount
        ; Filter signal counters for debug output
        dbgS1 := 0, dbgS2 := 0, dbgS3 := 0, dbgS4 := 0, dbgS5 := 0, dbgS6 := 0, dbgBL := 0

        for _, sampleEntry in sample
        {
            entity := (sampleEntry && sampleEntry.Has("entity")) ? sampleEntry["entity"] : 0
            if !entity
            {
                newSample.Push(sampleEntry)
                continue
            }

            addr   := entity.Has("address") ? entity["address"] : 0
            rawPtr := (sampleEntry && sampleEntry.Has("entityRawPtr")) ? sampleEntry["entityRawPtr"] : 0

            ; Permanently blacklisted from a previous tick — drop immediately.
            ; Exception: if the entity ID at this address differs from what was blacklisted,
            ; the game has reused the memory address for a new entity. Clear the stale blacklist
            ; entry and all tracking state so the fresh entity can be processed normally.
            if (addr > 0 && blacklist.Has(addr)) {
                currentId := sampleEntry.Has("id") ? sampleEntry["id"] : 0
                if (currentId > 0 && blacklist[addr] != currentId) {
                    blacklist.Delete(addr)
                    if this._everAliveAddrs.Has(addr)
                        this._everAliveAddrs.Delete(addr)
                    if this._targetableDeadMap.Has(addr)
                        this._targetableDeadMap.Delete(addr)
                    if this._targetableEverOn.Has(addr)
                        this._targetableEverOn.Delete(addr)
                    if this._firstSeenTick.Has(addr)
                        this._firstSeenTick.Delete(addr)
                    if this._posLastXY.Has(addr)
                        this._posLastXY.Delete(addr)
                    if this._posFrozenSinceTick.Has(addr)
                        this._posFrozenSinceTick.Delete(addr)
                    ; Fall through to normal processing for this new entity.
                } else {
                    dbgBL += 1
                    continue
                }
            }

            ; Record when we first encounter this entity address.
            if (addr > 0 && !this._firstSeenTick.Has(addr))
                this._firstSeenTick[addr] := nowTick

            isMonster := entity.Has("path") && InStr(StrLower(entity["path"]), "metadata/monsters/")
            ; rarityId=3 = Unique/Boss: exempt from the targetable-dead timer because bosses have
            ; legitimate multi-second untargetable phases (phase transitions, invulnerability windows).
            rarityId  := (entity.Has("decodedComponents") && entity["decodedComponents"].Has("rarityId"))
                         ? entity["decodedComponents"]["rarityId"] : 0
            isBoss    := (rarityId = 3)

            dc          := entity.Has("decodedComponents") ? entity["decodedComponents"] : 0
            lifeDecoded := (dc && dc.Has("life") && dc["life"] && Type(dc["life"]) = "Map")

            ; Normalize targetable to a tri-state boolean:
            ;   true  = component present and reads "targetable"
            ;   false = component present and reads "not targetable" (dead/ghost signal)
            ;   ""    = component not found / unknown (no signal either way)
            ;
            ; The lookup path (DecodeSampleEntityComponentsRadar) stores a raw boolean.
            ; The vector-scan fallback (DecodeEntityComponentsFromVectorBasic) stores a full Map
            ; from DecodeTargetableComponent.  Both must be handled here.
            tgtRaw := dc ? (dc.Has("targetable") ? dc["targetable"] : "") : ""
            if (Type(tgtRaw) = "Map")
                tgtBool := tgtRaw.Has("isTargetable") ? (tgtRaw["isTargetable"] ? true : false) : ""
            else
                tgtBool := tgtRaw
            targetableOff := (tgtBool = false)
            tgtFound      := (tgtBool = true || tgtBool = false)

            isDead   := false
            hardDead := false
            dbgSig   := 0

            ; ── Dead-signal evaluation ──────────────────────────────────────────────────
            ; Signal 1: game engine cleared the isValid flag
            if (entity.Has("isValid") && !entity["isValid"]) {
                isDead := hardDead := true
                dbgSig := 1
            }

            ; Signal 2: HP explicitly 0 (life component successfully decoded)
            if (!isDead && lifeDecoded && dc["life"].Has("isAlive") && !dc["life"]["isAlive"]) {
                isDead := hardDead := true
                dbgSig := 2
            }

            ; Signal 3: both life and targetable memory are gone — fully degraded corpse.
            ; Guard: only fire if entity was previously confirmed alive, to prevent false positives
            ; when Life/Targetable offsets fail to decode for live monsters (both read as 0).
            if (!isDead && isMonster && !lifeDecoded && targetableOff && this._everAliveAddrs.Has(addr)) {
                isDead := hardDead := true
                dbgSig := 3
            }

            ; (Signal 4 removed: "targetable=0 for Ns since first seen" was causing false positives
            ; because monsters rotate in/out of the 20-entity sample, so firstSeenTick can be >3s
            ; even when the entity was only sampled once. This blacklisted all live monsters.
            ; Signal 3 covers pre-dead ghosts when both life+targetable are degraded.
            ; Signal 5 covers monsters killed while being actively tracked.)

            ; ── Alive path ──────────────────────────────────────────────────────────────
            if !isDead
            {
                ; Confirm alive when life component explicitly reports HP > 0.
                if (lifeDecoded && dc["life"].Has("isAlive") && dc["life"]["isAlive"])
                {
                    if (addr > 0)
                        this._everAliveAddrs[addr] := true
                }
                ; Signal 5: targetable-dead timer— dead monsters hold IsTargetable=0/garbage
                ; indefinitely even when HP memory reads stale-positive.  Boss entities are exempt.
                shouldAdd := true
                if (isMonster && !isBoss && addr > 0)
                {
                    if (tgtBool = true)
                    {
                        this._targetableEverOn[addr] := true
                        if this._targetableDeadMap.Has(addr)
                            this._targetableDeadMap.Delete(addr)
                    }
                    else if (tgtBool = false && this._targetableEverOn.Has(addr))
                    {
                        tCount := this._targetableDeadMap.Has(addr) ? this._targetableDeadMap[addr] : 0
                        tCount += 1
                        this._targetableDeadMap[addr] := tCount
                        if (tCount >= this.TargetableDeadThreshold)
                        {
                            blacklist[addr] := sampleEntry.Has("id") ? sampleEntry["id"] : -1
                            if this._everAliveAddrs.Has(addr)
                                this._everAliveAddrs.Delete(addr)
                            if this._targetableDeadMap.Has(addr)
                                this._targetableDeadMap.Delete(addr)
                            if this._targetableEverOn.Has(addr)
                                this._targetableEverOn.Delete(addr)
                            dbgS5 += 1
                            shouldAdd := false
                        }
                    }
                }
                ; Signal 6: position-freeze — dead corpses have a perfectly static render position.
                ; Any entity (monster, non-boss) frozen at the exact same world position for
                ; PosDeadThresholdMs is treated as dead. Live entities that move reset the timer.
                if (shouldAdd && isMonster && !isBoss && addr > 0)
                {
                    render := (dc && dc.Has("render") && dc["render"] && Type(dc["render"]) = "Map") ? dc["render"] : 0
                    wp     := (render && render.Has("worldPosition")) ? render["worldPosition"] : 0
                    if (wp && wp.Has("x") && wp.Has("y"))
                    {
                        posKey := Round(wp["x"], 1) . "," . Round(wp["y"], 1)
                        if (this._posLastXY.Has(addr) && this._posLastXY[addr] = posKey)
                        {
                            if !this._posFrozenSinceTick.Has(addr)
                                this._posFrozenSinceTick[addr] := nowTick
                            frozenMs := nowTick - this._posFrozenSinceTick[addr]
                            if (frozenMs > this.PosDeadThresholdMs)
                            {
                                shouldAdd := false
                                dbgS6 += 1
                            }
                        }
                        else
                        {
                            ; Position changed — entity is alive; reset freeze timer.
                            this._posLastXY[addr] := posKey
                            if this._posFrozenSinceTick.Has(addr)
                                this._posFrozenSinceTick.Delete(addr)
                        }
                    }
                }
                if shouldAdd
                    newSample.Push(sampleEntry)
            }
            else if hardDead
            {
                ; Hard dead: blacklist immediately, clean up all tracking state.
                if (dbgSig = 1)
                    dbgS1 += 1
                else if (dbgSig = 2)
                    dbgS2 += 1
                else if (dbgSig = 3)
                    dbgS3 += 1

                if (addr > 0)
                {
                    blacklist[addr] := sampleEntry.Has("id") ? sampleEntry["id"] : -1
                    if this._everAliveAddrs.Has(addr)
                        this._everAliveAddrs.Delete(addr)
                    if this._targetableDeadMap.Has(addr)
                        this._targetableDeadMap.Delete(addr)
                    if this._targetableEverOn.Has(addr)
                        this._targetableEverOn.Delete(addr)
                    if this._firstSeenTick.Has(addr)
                        this._firstSeenTick.Delete(addr)
                    if this._posLastXY.Has(addr)
                        this._posLastXY.Delete(addr)
                    if this._posFrozenSinceTick.Has(addr)
                        this._posFrozenSinceTick.Delete(addr)
                }
                ; Drop: do not push to newSample.
            }
            ; (No soft-dead path: eliminated to prevent false positives on live monsters
            ;  whose life component transiently fails to decode.)
        }

        entitySummary["sample"]        := newSample
        entitySummary["sampleCount"]   := newSample.Length
        entitySummary["filterStats"]   := Map(
            "s1", dbgS1, "s2", dbgS2, "s3", dbgS3, "s4", dbgS4, "s5", dbgS5, "s6", dbgS6,
            "bl", dbgBL, "blTotal", blacklist.Count,
            "preFilter", sample.Length, "postFilter", newSample.Length
        )
        return entitySummary
    }

    ; Reads walkable terrain data from memory for the given AreaInstance address.
    ; The data is a packed byte array where each byte represents 2 grid cells:
    ;   even-x cell → lower nibble (bits 3-0),  odd-x cell → upper nibble (bits 7-4)
    ;   nibble != 0 → walkable
    ; Returns a Map with keys: data (Buffer), bytesPerRow (int), totalRows (int),
    ;   dataSize (int), gridWidth (int).  Returns 0 on failure.
    ; On failure, this._terrainLastError is set to a human-readable reason string.
    ReadTerrainData(areaInstanceAddress)
    {
        if !this.IsProbablyValidPointer(areaInstanceAddress)
        {
            this._terrainLastError := "bad-area-ptr"
            return 0
        }

        terrainMetaBase := areaInstanceAddress + PoE2Offsets.AreaInstance["TerrainMetadata"]

        firstPtr := this.Mem.ReadPtr(terrainMetaBase + PoE2Offsets.TerrainMetadata["GridWalkableData"])
        lastPtr  := this.Mem.ReadPtr(terrainMetaBase + PoE2Offsets.TerrainMetadata["GridWalkableData"] + 8)

        if (!firstPtr || !lastPtr || lastPtr <= firstPtr)
        {
            ; Pointer-pair scan: find where GridWalkableData StdVector actually is.
            ; Step by 4 (not 8) to catch any alignment, since the actual offset may not
            ; be 8-byte-aligned from the struct base. Covers offsets 0x18..0x10C.
            ptrScan := ""
            matchCount := 0
            loop 63
            {
                off  := 0x18 + (A_Index - 1) * 4
                fp2  := this.Mem.ReadPtr(terrainMetaBase + off)
                lp2  := this.Mem.ReadPtr(terrainMetaBase + off + 8)
                sz2  := lp2 - fp2
                if (fp2 > 0x10000 && lp2 > fp2 && sz2 > 4096 && sz2 < 8 * 1024 * 1024)
                {
                    ptrScan .= "[0x" Format("{:X}", off) ":sz=" sz2 "]"
                    matchCount++
                    if (matchCount >= 4)
                        break
                }
            }
            ; When no ptr pairs found, dump the raw TerrainStruct bytes to a debug file.
            if (ptrScan = "")
            {
                try {
                    dumpBuf := this.Mem.ReadBytes(terrainMetaBase, 0x120, false)
                    if (dumpBuf && dumpBuf.Size >= 0x120)
                    {
                        lines := "TerrainStruct hex dump (base=AreaInstance+0x" Format("{:X}", PoE2Offsets.AreaInstance["TerrainMetadata"])
                            . " areaInst=0x" Format("{:X}", areaInstanceAddress) ")`n"
                        loop 0x120 // 16
                        {
                            row := (A_Index - 1) * 16
                            line := Format("+{:03X}: ", row)
                            loop 16
                            {
                                b := NumGet(dumpBuf, row + (A_Index - 1), "UChar")
                                line .= Format("{:02X} ", b)
                            }
                            lines .= line "`n"
                        }
                        FileAppend lines, A_ScriptDir "\debug\terrain_dump.txt"
                    }
                }
            }
            this._terrainLastError := "bad-vec fp=0x" Format("{:X}", firstPtr) " lp=0x" Format("{:X}", lastPtr)
                . (ptrScan != "" ? " ptrs=" ptrScan : " no-ptrs (see debug\terrain_dump.txt)")
            return 0
        }

        dataSize := lastPtr - firstPtr
        if (dataSize > 32 * 1024 * 1024 || dataSize < 64)
        {
            this._terrainLastError := "bad-size sz=" dataSize
            return 0
        }

        ; Read BytesPerRow directly at the known offset (TerrainStruct+0x130).
        ; Fall back to a scan window centred on that offset if the direct read fails validation.
        bytesPerRow := 0
        foundBprOffset := 0
        directBpr := this.Mem.ReadInt(terrainMetaBase + PoE2Offsets.TerrainMetadata["BytesPerRow"])
        if (directBpr > 1 && directBpr <= 16384 && Mod(dataSize, directBpr) = 0)
        {
            rows := dataSize // directBpr
            if (rows >= 16 && rows <= 32768)
            {
                bytesPerRow := directBpr
                foundBprOffset := PoE2Offsets.TerrainMetadata["BytesPerRow"]
            }
        }

        ; Scan fallback: wider window in case the exact offset shifted.
        if (bytesPerRow <= 0)
        {
            startOff := Max(0x40, PoE2Offsets.TerrainMetadata["BytesPerRow"] - 0x80)
            loop 0xC0  ; scan 192 dwords (768 bytes window)
            {
                off := startOff + ((A_Index - 1) * 4)
                v := this.Mem.ReadInt(terrainMetaBase + off)
                if (v > 1 && v <= 16384 && Mod(dataSize, v) = 0)
                {
                    rows := dataSize // v
                    if (rows >= 16 && rows <= 32768)
                    {
                        bytesPerRow := v
                        foundBprOffset := off
                        break
                    }
                }
            }
        }

        if (bytesPerRow <= 0)
        {
            ; Last-resort brute-force any reasonable factor of dataSize
            loop 16384
            {
                v := A_Index
                if (v > 1 && Mod(dataSize, v) = 0)
                {
                    rows := dataSize // v
                    if (rows >= 16 && rows <= 32768)
                    {
                        bytesPerRow := v
                        foundBprOffset := -1   ; brute-forced, no known offset
                        break
                    }
                }
            }
        }

        if (bytesPerRow <= 0)
        {
            this._terrainLastError := "no-bpr sz=" dataSize
            return 0
        }

        buf := this.Mem.ReadBytes(firstPtr, dataSize, true)
        if (!buf || Type(buf) != "Buffer" || buf.Size < 64)
        {
            this._terrainLastError := "read-fail sz=" dataSize
            return 0
        }

        totalRows := buf.Size // bytesPerRow
        if totalRows <= 0
        {
            this._terrainLastError := "no-rows sz=" buf.Size " bpr=" bytesPerRow
            return 0
        }

        this._terrainLastError := "bprOff=" (foundBprOffset >= 0 ? "0x" Format("{:X}", foundBprOffset) : "brute")
        return Map(
            "data",        buf,
            "bytesPerRow", bytesPerRow,
            "totalRows",   totalRows,
            "dataSize",    buf.Size,
            "gridWidth",   bytesPerRow * 2
        )
    }

    ; Reads a lightweight snapshot for the radar overlay: player position, entity positions, and map UI data.
    ; Much faster than ReadSnapshot() — skips inventory, stats, buffs, server data, and world area details.
    ; InGameState address is re-resolved every 800ms; UI element data is re-read every 400ms.
    ; Returns: snapshot Map compatible with RadarOverlay.Render(), or 0 on error.
    ReadRadarSnapshot()
    {
        if (!this.Mem.Handle || !this.GameStatesAddress)
            return 0

        t0 := A_TickCount

        ; Re-resolve InGameState address every 800ms — the 12-state loop is expensive at 100ms.
        nowTick := A_TickCount
        if (!this._radarInGameStateCache || (nowTick - this._radarInGameStateTick) > 800)
        {
            staticGameStatePtr := this.Mem.ReadPtr(this.GameStatesAddress)
            if !this.IsProbablyValidPointer(staticGameStatePtr)
                return 0

            currentStateVecLast := this.Mem.ReadInt64(staticGameStatePtr + PoE2Offsets.GameState["CurrentStateVecLast"])

            statesByIndex   := []
            statesByAddress := Map()
            statesBase := staticGameStatePtr + PoE2Offsets.GameState["States"]
            loop 12
            {
                idx       := A_Index - 1
                stateAddr := this.Mem.ReadPtr(statesBase + (idx * PoE2Offsets.GameState["StateEntrySize"]))
                stateName := this.StateNames[A_Index]
                statesByIndex.Push(Map("index", idx, "name", stateName, "address", stateAddr))
                if stateAddr
                    statesByAddress[stateAddr] := stateName
            }

            currentStateAddress := 0
            if (currentStateVecLast > 0x10)
            {
                currentStateAddress := this.Mem.ReadPtr(currentStateVecLast - 0x10)
                if !(currentStateAddress && statesByAddress.Has(currentStateAddress))
                    currentStateAddress := 0
            }

            currentStateName := "GameNotLoaded"
            if (currentStateAddress && statesByAddress.Has(currentStateAddress))
                currentStateName := statesByAddress[currentStateAddress]

            resolved := this.ResolveInGameStateAddress(statesByIndex, currentStateAddress)
            if !resolved
                return 0
            this._radarInGameStateCache := resolved
            this._radarCurrentStateName := currentStateName
            this._radarInGameStateTick := nowTick
        }
        t1 := A_TickCount  ; after state resolution
        inGameStateAddress := this._radarInGameStateCache

        areaInstanceData := this.Mem.ReadPtr(inGameStateAddress + PoE2Offsets.InGameState["AreaInstanceData"])
        if !this.IsProbablyValidPointer(areaInstanceData)
            return 0

        ; Terrain walkability data — re-read when area hash changes, or retry every 3 s after a failed read.
        currentAreaHash := this.Mem.ReadUInt(areaInstanceData + PoE2Offsets.AreaInstance["CurrentAreaHash"])
        needsTerrainRead := (currentAreaHash != this._radarTerrainAreaHash)
                         || (!this._radarTerrainCache && (nowTick - this._radarTerrainRetryTick) > 3000)
        if needsTerrainRead
        {
            this._radarTerrainRetryTick := nowTick
            terrainResult := 0
            try terrainResult := this.ReadTerrainData(areaInstanceData)
            catch
                terrainResult := 0
            this._radarTerrainCache := terrainResult
            ; Only lock in the area hash when we have a valid result — on failure we retry in 3 s.
            if terrainResult
                this._radarTerrainAreaHash := currentAreaHash
        }

        ; World area data (town/hideout flags) — re-read only on zone change (area hash).
        if (currentAreaHash != this._radarWorldAreaHash)
        {
            this._radarWorldAreaCache := 0
            try {
                worldData := this.Mem.ReadPtr(inGameStateAddress + PoE2Offsets.InGameState["WorldData"])
                if this.IsProbablyValidPointer(worldData)
                {
                    wdp := this.Mem.ReadPtr(worldData + PoE2Offsets.WorldData["WorldAreaDetailsPtr"])
                    if this.IsProbablyValidPointer(wdp)
                    {
                        rowPtr := this.Mem.ReadPtr(wdp + PoE2Offsets.WorldData["WorldAreaDetailsRowPtr"])
                        this._radarWorldAreaCache := this.ReadWorldAreaDat(rowPtr)
                    }
                }
            }
            this._radarWorldAreaHash := currentAreaHash
        }

        ; Player world position
        playerInfoPtr     := areaInstanceData + PoE2Offsets.AreaInstance["PlayerInfo"]
        localPlayerRawPtr := this.Mem.ReadPtr(playerInfoPtr + PoE2Offsets.LocalPlayerStruct["LocalPlayerPtr"])
        localPlayerPtr    := this.ResolveEntityPointer(localPlayerRawPtr)
        playerRenderComponent := this.ReadPlayerRenderComponent(localPlayerPtr)

        ; Player vitals — cached, re-read every 200ms (cheap: ~3 RPM)
        if (!this._radarPlayerVitalsCache || (nowTick - this._radarPlayerVitalsTick) > 200)
        {
            try this._radarPlayerVitalsCache := this.ReadPlayerVitals(localPlayerPtr)
            catch
                this._radarPlayerVitalsCache := 0
            this._radarPlayerVitalsTick := nowTick
        }
        t2 := A_TickCount  ; after player read

        ; Map UI element data — re-read only every 400ms to avoid expensive UI tree walk at 100ms.
        ; Map positions/zoom rarely change mid-frame; re-reading less often has no visible impact.
        if (!this._radarUiCache || (nowTick - this._radarUiCacheTick) > 400)
        {
            uiRootStructPtr := this.Mem.ReadPtr(inGameStateAddress + PoE2Offsets.InGameState["UiRootStructPtr"])
            importantUiElements := 0
            if this.IsProbablyValidPointer(uiRootStructPtr)
            {
                gameUiPtr           := this.Mem.ReadPtr(uiRootStructPtr + PoE2Offsets.UiRootStruct["GameUiPtr"])
                gameUiControllerPtr := this.Mem.ReadPtr(uiRootStructPtr + PoE2Offsets.UiRootStruct["GameUiControllerPtr"])
                isControllerMode    := (!gameUiPtr && gameUiControllerPtr)
                activeGameUiPtr     := isControllerMode ? gameUiControllerPtr : gameUiPtr
                importantUiElements := this.ReadImportantUiElements(activeGameUiPtr, isControllerMode)
            }
            this._radarUiCache := importantUiElements
            this._radarUiCacheTick := nowTick
        }

        ; Panel visibility — re-read every 200ms (cheap: 1 ReadPtr + 1 ReadUInt per panel).
        ; Also triggers one-time discovery if panel offsets haven't been discovered yet.
        if (!this._radarPanelVisCache || (nowTick - this._radarPanelVisCacheTick) > 200)
        {
            if !IsSet(uiRootStructPtr)
                uiRootStructPtr := this.Mem.ReadPtr(inGameStateAddress + PoE2Offsets.InGameState["UiRootStructPtr"])
            if this.IsProbablyValidPointer(uiRootStructPtr)
            {
                if !IsSet(activeGameUiPtr)
                {
                    gameUiPtr           := this.Mem.ReadPtr(uiRootStructPtr + PoE2Offsets.UiRootStruct["GameUiPtr"])
                    gameUiControllerPtr := this.Mem.ReadPtr(uiRootStructPtr + PoE2Offsets.UiRootStruct["GameUiControllerPtr"])
                    activeGameUiPtr     := (!gameUiPtr && gameUiControllerPtr) ? gameUiControllerPtr : gameUiPtr
                }
                this._lastActiveGameUiPtr := activeGameUiPtr
                ; One-time discovery (or re-discovery after zone change)
                if (!this._radarPanelDiscoveryDone)
                {
                    this._radarPanelDiscoveryResult := this.DiscoverPanelOffsets(activeGameUiPtr)
                    this._radarPanelDiscoveryDone := true
                    ; After zone change, schedule a clean baseline 3s later
                    ; (all panels are guaranteed closed right after zone load)
                    if (this._baselineDelayTick > 0)
                        this._baselineDelayTick := A_TickCount + 3000
                }
                ; Delayed baseline refresh: re-read flags 3s after zone change
                if (this._baselineDelayTick > 0 && nowTick >= this._baselineDelayTick)
                {
                    this.RefreshVisibilityBaseline()
                    this._baselineDelayTick := 0
                }
                this._radarPanelVisCache := this.ReadAllPanelVisibility(activeGameUiPtr)
            }
            this._radarPanelVisCacheTick := nowTick
        }

        t3 := A_TickCount  ; after UI cache

        ; ── Persistent entity cache (mirrors C# AreaInstance.UpdateEntities) ──────────────
        ; Instead of sampling a small subset of entities per tick, we:
        ;   1. Fast-scan the entire AwakeMap tree to get ALL entityId → entityPtr pairs
        ;   2. Full-decode only NEW entities (not yet in cache)
        ;   3. Cheap-update EXISTING cached entities (position, life, targetable, flags)
        ;   4. Remove from cache entities no longer in the tree
        ; This finds ALL entities like the C# reference, not just a 40-entity sample.
        entityListOffset   := PoE2Offsets.AreaInstance["AwakeEntities"]
        awakeMapAddress    := areaInstanceData + entityListOffset
        playerOrigin       := this.ExtractWorldPositionFromRenderComponent(playerRenderComponent)

        ; Reset cache on area change
        if (currentAreaHash != this._radarEntityCacheAreaHash)
        {
            this._radarEntityCache := Map()
            this._radarEntityCacheAreaHash := currentAreaHash
            ; Schedule zone scanner (terrain tiles are available almost immediately)
            this._zoneScanDone := false
            this._zoneScanScheduledAt := A_TickCount + 500
            this._zoneScanRetries := 0
            this._zoneScanAccumulated := Map()
            this._zoneScanTimingMs := 0
            this._tgtScanInProgress := false
            ; Force fresh BFS on zone change
            this._radarLastBfsTick := 0
            this._radarLastCurrentEntities := 0
            this._radarLastFullAwakeRawPtrs := 0
            this._cheapUpdateOffset := 0
            ; Re-discover panels on zone change (runtime pointers are stale)
            this._radarPanelDiscoveryDone := false
            PoE2Offsets.DiscoveredPanelOffsets := Map()
            this._radarPanelDiscoveryResult := 0
            this._heapUiElems := []
            this._visBaseline := Map()
            this._visBaselineTaken := false
            this._diffSnapshot := 0
            this._diffSnapshotTaken := false
            this._structBaselineRaw := 0
            this._baselineDelayTick := A_TickCount + 3000
            ; Clear component name cache (lives on PoE2ComponentDecoders via inheritance)
            if this.HasOwnProp("_compNameCache")
                this._compNameCache := Map()
        }

        ; Zone scanner: incremental TGT tile scan (processes batch per tick instead of all-at-once)
        if (this._zoneScanEnabled && !this._zoneScanDone
            && this._zoneScanScheduledAt > 0 && A_TickCount >= this._zoneScanScheduledAt)
        {
            scanStart := A_TickCount

            if (!this._tgtScanInProgress)
            {
                try this._tgtScanInProgress := this._SetupTgtScan(areaInstanceData)
                catch
                    this._tgtScanInProgress := false

                if (!this._tgtScanInProgress)
                {
                    this._zoneScanRetries += 1
                    if (this._zoneScanRetries >= 3)
                    {
                        this._zoneScanDone := true
                        this._zoneScanScheduledAt := 0
                    }
                    else
                        this._zoneScanScheduledAt := A_TickCount + 2000
                }
            }

            if (this._tgtScanInProgress)
            {
                try batchDone := this._ProcessTgtScanBatch(2000)
                catch
                    batchDone := true
                this._zoneScanTimingMs += A_TickCount - scanStart

                if (batchDone)
                {
                    this._tgtScanInProgress := false
                    tgtResults := this._tgtScanPartialResults
                    if (tgtResults.Count > 0)
                    {
                        for key, ent in tgtResults
                        {
                            if !this._zoneScanAccumulated.Has(key)
                                this._zoneScanAccumulated[key] := ent
                        }
                    }
                    this._zoneScanAreaHash := currentAreaHash
                    this._zoneScanDone := true
                    this._zoneScanScheduledAt := 0
                }
            }
        }

        ; Step 1: Full tree scan — get all entityId → rawPtr
        ; Throttle BFS to every 200ms; reuse cached results on intermediate ticks.
        bfsInterval := 200
        doFullBfs := !this._radarLastBfsTick
            || (nowTick - this._radarLastBfsTick) >= bfsInterval
            || !this._radarLastCurrentEntities
        if (doFullBfs)
        {
            currentEntities := 0
            try currentEntities := this.ScanEntityMapIdsAndPtrs(awakeMapAddress)
            catch
                currentEntities := Map()
            if !currentEntities
                currentEntities := Map()

            ; Build rawPtr set for the stale filter
            fullAwakeRawPtrs := Map()
            for _, rawPtr in currentEntities
            {
                if (rawPtr > 0)
                    fullAwakeRawPtrs[rawPtr] := true
            }

            this._radarLastCurrentEntities := currentEntities
            this._radarLastFullAwakeRawPtrs := fullAwakeRawPtrs
            this._radarLastBfsTick := nowTick
        }
        else
        {
            currentEntities := this._radarLastCurrentEntities
            fullAwakeRawPtrs := this._radarLastFullAwakeRawPtrs
        }
        mapSize := currentEntities.Count

        ; Step 2+3: Update cache — new entities get full decode, existing get cheap update
        ;   Phase 1: Collect new/changed entity IDs (pure CPU, no RPM calls)
        ;   Phase 2: Decode new + changed entities FIRST (priority time budget)
        ;   Phase 3: Cheap-update existing cached entities (separate budget, round-robin)
        cache := this._radarEntityCache
        newDecodeCount := 0
        cheapUpdateCount := 0
        cacheErrors := 0

        ; How full is the cache vs the tree? During zone load, prioritize decodes heavily.
        cacheFillRatio := mapSize > 0 ? (cache.Count / mapSize) : 1.0
        isZoneLoading := (cacheFillRatio < 0.90)
        decodeBudgetMs := isZoneLoading ? 45 : 30
        cheapBudgetMs  := isZoneLoading ? 10 : 30

        ; ── Phase 1: Classify entities (no RPM) ──────────────────────────
        newEntityList := []       ; [{id, rawPtr}, ...]
        changedEntityList := []   ; [{id, rawPtr, cached}, ...]
        for entityId, rawPtr in currentEntities
        {
            if cache.Has(entityId)
            {
                cached := cache[entityId]
                cachedRawPtr := cached.Has("entityRawPtr") ? cached["entityRawPtr"] : 0
                if (cachedRawPtr != rawPtr)
                    changedEntityList.Push(Map("id", entityId, "rawPtr", rawPtr, "cached", cached))
            }
            else
                newEntityList.Push(Map("id", entityId, "rawPtr", rawPtr))
        }

        ; ── Phase 2: Decode new + changed entities (priority budget) ─────
        decodeDeadline := A_TickCount + decodeBudgetMs
        this._radarMode := true

        for _, item in newEntityList
        {
            if (A_TickCount >= decodeDeadline)
                break
            try
            {
                entityPtr := this.ResolveEntityPointer(item["rawPtr"])
                if !this.IsProbablyValidPointer(entityPtr)
                    continue
                entityBasic := this.ReadEntityBasic(entityPtr, item["id"])
                if (entityBasic && Type(entityBasic) = "Map")
                {
                    entityPos := this.ExtractEntityWorldPositionFromEntityBasic(entityBasic, playerOrigin)
                    sampleEntry := Map(
                        "id",           item["id"],
                        "entityPtr",    entityPtr,
                        "entityRawPtr", item["rawPtr"],
                        "entity",       entityBasic,
                        "distance",     this.ComputeDistance3DFromMaps(playerOrigin, entityPos),
                        "priority",     this.ComputeSampleEntryPriority(entityBasic, 0)
                    )
                    cache[item["id"]] := sampleEntry
                    newDecodeCount += 1
                }
            }
            catch as err
                cacheErrors += 1
        }

        for _, item in changedEntityList
        {
            if (A_TickCount >= decodeDeadline)
                break
            try
            {
                entityPtr := this.ResolveEntityPointer(item["rawPtr"])
                if !this.IsProbablyValidPointer(entityPtr)
                    continue
                entityBasic := this.ReadEntityBasic(entityPtr, item["id"])
                if (entityBasic && Type(entityBasic) = "Map")
                {
                    entityPos := this.ExtractEntityWorldPositionFromEntityBasic(entityBasic, playerOrigin)
                    cached := item["cached"]
                    cached["entity"]       := entityBasic
                    cached["entityPtr"]    := entityPtr
                    cached["entityRawPtr"] := item["rawPtr"]
                    cached["distance"]     := this.ComputeDistance3DFromMaps(playerOrigin, entityPos)
                    cached["priority"]     := this.ComputeSampleEntryPriority(entityBasic, 0)
                    newDecodeCount += 1
                }
            }
            catch as err
                cacheErrors += 1
        }

        ; ── Phase 3: Cheap updates (time-budgeted, round-robin) ──────────
        ; Build array of cached entity IDs for round-robin traversal.
        ; Start from where we left off last tick so every entity gets updated eventually.
        cachedIds := []
        for entityId, _ in cache
        {
            if currentEntities.Has(entityId)
                cachedIds.Push(entityId)
        }
        cachedCount := cachedIds.Length
        if (cachedCount > 0)
        {
            cheapDeadline := A_TickCount + cheapBudgetMs
            offset := this._cheapUpdateOffset
            if (offset >= cachedCount)
                offset := 0
            Loop cachedCount
            {
                if (A_TickCount >= cheapDeadline)
                    break
                idx := Mod(offset + A_Index - 1, cachedCount) + 1
                entityId := cachedIds[idx]
                if !cache.Has(entityId)
                    continue
                try
                {
                    this.UpdateCachedEntityRadar(cache[entityId], playerOrigin)
                    cheapUpdateCount += 1
                }
                catch as err
                    cacheErrors += 1
            }
            this._cheapUpdateOffset := Mod(offset + cheapUpdateCount, Max(cachedCount, 1))
        }
        this._radarMode := false

        ; Step 4: Remove entities no longer in the tree
        removeIds := []
        for cachedId, _ in cache
        {
            if !currentEntities.Has(cachedId)
                removeIds.Push(cachedId)
        }
        for _, rid in removeIds
            cache.Delete(rid)

        ; Build sample array from cache for downstream consumers
        awakeSample := []
        for _, entry in cache
            awakeSample.Push(entry)

        awakeEntities := Map(
            "address", awakeMapAddress,
            "size", mapSize,
            "sample", awakeSample,
            "sampleCount", awakeSample.Length
        )
        t4 := A_TickCount  ; after entity cache update

        ; Sleeping entities — skip during zone loading to preserve RPM budget for awake decodes.
        ; Once the cache is >90% full (steady state), scan sleeping entities with a small limit.
        sleepingMapAddress := awakeMapAddress + 0x10
        emptyEntitySummary := Map("address", 0, "size", 0, "sample", [], "sampleCount", 0)
        if (isZoneLoading)
        {
            sleepingEntities := emptyEntitySummary
        }
        else
        {
            sleepingLimit := this.RadarSleepingEntityLimit
            try
            {
                if (sleepingLimit > 0)
                    sleepingEntities := this.ReadAreaEntityMapSummaryForRadar(sleepingMapAddress, sleepingLimit, playerOrigin)
                else
                    sleepingEntities := emptyEntitySummary
            }
            catch
            {
                sleepingEntities := emptyEntitySummary
            }
        }
        t5 := A_TickCount  ; after sleeping entity read

        ; Continuous accumulation: harvest important entities from awake + sleeping samples.
        ; As the player moves, new entities enter the network bubble and get captured.
        if (this._zoneScanEnabled)
        {
            worldToGridRatio := 250.0 / 0x17
            for _, entityList in [awakeSample, sleepingEntities.Has("sample") ? sleepingEntities["sample"] : []]
            {
                for _, entry in entityList
                {
                    try
                    {
                        ent := entry.Has("entity") ? entry["entity"] : 0
                        if !(ent && Type(ent) = "Map")
                            continue
                        path := ent.Has("path") ? ent["path"] : ""
                        if (path = "")
                            continue

                        ; Classify entity type (same logic as deep scan)
                        pathLower := StrLower(path)
                        entType := ""
                        if InStr(pathLower, "areatransition")
                            entType := "AreaTransition"
                        else if InStr(pathLower, "waypoint")
                            entType := "Waypoint"
                        else if InStr(pathLower, "checkpoint")
                            entType := "Checkpoint"
                        else if (InStr(pathLower, "metadata/monsters/") && (InStr(pathLower, "boss") || InStr(pathLower, "unique")))
                            entType := "Boss"
                        else if InStr(pathLower, "metadata/npc/")
                            entType := "NPC"
                        if (entType = "")
                            continue

                        ; Extract world position from decoded render component
                        dc := ent.Has("decodedComponents") ? ent["decodedComponents"] : 0
                        if !(dc && Type(dc) = "Map" && dc.Has("render"))
                            continue
                        r := dc["render"]
                        if !(r && Type(r) = "Map" && r.Has("worldPosition"))
                            continue
                        wp := r["worldPosition"]
                        if !(wp && Type(wp) = "Map")
                            continue
                        worldX := wp.Has("x") ? wp["x"] : 0
                        worldY := wp.Has("y") ? wp["y"] : 0
                        worldZ := wp.Has("z") ? wp["z"] : 0
                        if (Abs(worldX) < 0.01 && Abs(worldY) < 0.01)
                            continue

                        gridX := worldX / worldToGridRatio
                        gridY := worldY / worldToGridRatio

                        ; Try to refine an existing TGT tile entry with precise render position
                        refined := false
                        for existingKey, existing in this._zoneScanAccumulated
                        {
                            if (InStr(existingKey, path) = 1 && !existing.Has("refined"))
                            {
                                existing["worldX"] := worldX
                                existing["worldY"] := worldY
                                existing["worldZ"] := worldZ
                                existing["gridX"]  := gridX
                                existing["gridY"]  := gridY
                                existing["refined"] := true
                                refined := true
                                break
                            }
                        }

                        ; If no TGT match, add as new entry (entity not in tile data)
                        if (!refined && !this._zoneScanAccumulated.Has(path))
                        {
                            this._zoneScanAccumulated[path] := Map(
                                "path", path,
                                "type", entType,
                                "worldX", worldX,
                                "worldY", worldY,
                                "worldZ", worldZ,
                                "gridX", gridX,
                                "gridY", gridY,
                                "refined", true
                            )
                        }
                    }
                }
            }
        }

        ; Apply entity filter (ghost detection + dead-entity blacklisting).
        ; See _FilterStaleRadarEntities for the 5 dead signals used.
        ; fullAwakeRawPtrs enables the network-bubble check: entities removed from the AwakeMap
        ; are blacklisted on the very next tick regardless of what their HP memory reads.
        awakeEntities    := this._FilterStaleRadarEntities(awakeEntities,    areaInstanceData, fullAwakeRawPtrs)
        sleepingEntities := this._FilterStaleRadarEntities(sleepingEntities, areaInstanceData)

        ; Sync cache: remove entities that the stale filter blacklisted.
        ; The filter builds a new sample array excluding dead entities; rebuild a set of surviving
        ; entity ids and prune anything the filter dropped from the persistent cache.
        survivingIds := Map()
        for _, entry in awakeEntities["sample"]
        {
            eid := entry.Has("id") ? entry["id"] : 0
            if (eid > 0)
                survivingIds[eid] := true
        }
        pruneIds := []
        for cachedId, _ in cache
        {
            if !survivingIds.Has(cachedId)
                pruneIds.Push(cachedId)
        }
        for _, pid in pruneIds
            cache.Delete(pid)

        t6 := A_TickCount  ; after filter

        ; Extract filter stats for status bar
        filterPre := 0
        filterPost := 0
        filterBL := 0
        try {
            fs := awakeEntities.Has("filterStats") ? awakeEntities["filterStats"] : 0
            if (fs && Type(fs) = "Map") {
                filterPre  := fs.Has("preFilter") ? fs["preFilter"] : 0
                filterPost := fs.Has("postFilter") ? fs["postFilter"] : 0
                filterBL   := fs.Has("blTotal") ? fs["blTotal"] : 0
            }
        }

        ; Store sub-timings for display in status bar (all in ms).
        this.RadarTimings := Map(
            "state",   t1 - t0,
            "player",  t2 - t1,
            "ui",      t3 - t2,
            "awake",   t4 - t3,
            "sleep",   t5 - t4,
            "filter",  t6 - t5,
            "total",   t6 - t0,
            "cacheSize",  cache.Count,
            "mapSize",    mapSize,
            "newDecode",  newDecodeCount,
            "cheapUpdate", cheapUpdateCount,
            "cacheErrors", cacheErrors,
            "filterPre",  filterPre,
            "filterPost", filterPost,
            "filterBL",   filterBL
        )

        return Map(
            "currentStateName", this._radarCurrentStateName,
            "areaLevel", (this.LastAreaLevel > 0) ? this.LastAreaLevel : 0,
            "playerVitals", this._radarPlayerVitalsCache,
            "worldAreaDat", this._radarWorldAreaCache,
            "panelVisibility", this._radarPanelVisCache,
            "panelDiscovery", this._radarPanelDiscoveryResult,
            "inGameState", Map(
                "address",             inGameStateAddress,
                "importantUiElements", this._radarUiCache,
                "areaInstance", Map(
                    "address",               areaInstanceData,
                    "playerRenderComponent", playerRenderComponent,
                    "awakeEntities",         awakeEntities,
                    "sleepingEntities",      sleepingEntities,
                    "terrain",               this._radarTerrainCache,
                    "terrainError",          this._terrainLastError,
                    "zoneScanResults",       this._ZoneScanAccumulatedArray(),
                    "zoneScanDone",          this._zoneScanDone,
                    "zoneScanTimingMs",      this._zoneScanTimingMs
                )
            )
        )
    }

    ; Converts the accumulated zone scan Map to an Array for snapshot output.
    _ZoneScanAccumulatedArray()
    {
        arr := []
        for _, ent in this._zoneScanAccumulated
            arr.Push(ent)
        return arr
    }

    ; Dumps diagnostic data for all entities in the last radar snapshot to a TSV file.
    ; Rows include: address, rawPtr, path, rarityId, isValid, lifeDecoded, HPcur, HPmax,
    ;   isAlive, targetableRaw (byte read directly), targetableDecoded, reaction,
    ;   inBlacklist, staleCount, targetableDeadCount, inFullAwakeScan.
    DumpRadarEntityDebug(radarSnap, outDir := "")
    {
        if !outDir
        {
            outDir := A_ScriptDir "\debug"
            if !DirExist(outDir)
                DirCreate(outDir)
        }
        timestamp := FormatTime(A_Now, "yyyyMMdd_HHmmss")
        outPath   := outDir "\radar_entity_debug_" timestamp ".tsv"

        inGs  := (radarSnap && radarSnap.Has("inGameState")) ? radarSnap["inGameState"] : 0
        area  := (inGs && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
        if !area
            return ""

        areaAddr := area.Has("address") ? area["address"] : 0

        ; Re-scan the full AwakeMap for rawPtr presence check
        fullRawPtrs := Map()
        try
        {
            entityListOffset := PoE2Offsets.AreaInstance["AwakeEntities"]
            mapBase := this.Mem.ReadPtr(areaAddr + entityListOffset)
            fullRawPtrs := this.ScanEntityMapRawPtrs(mapBase)
        }

        blacklist  := this._deadEntityBlacklist
        firstSeen  := this._firstSeenTick
        tgtDeadMap := this._targetableDeadMap
        tgtEverOn  := this._targetableEverOn

        awake    := area.Has("awakeEntities")    ? area["awakeEntities"]    : Map()
        sleeping := area.Has("sleepingEntities") ? area["sleepingEntities"] : Map()

        ; Build a diagnostic stats line: StdMap size, BFS pre/post filter counts, signal breakdown.
        awakeFs  := (awake.Has("filterStats") && Type(awake["filterStats"]) = "Map")  ? awake["filterStats"]  : 0
        sleepFs  := (sleeping.Has("filterStats") && Type(sleeping["filterStats"]) = "Map") ? sleeping["filterStats"] : 0
        awakeSize := awake.Has("size") ? awake["size"] : "?"
        statsLine := "; STATS awake: mapSize=" awakeSize
                   . " preFilter=" (awakeFs ? awakeFs["preFilter"] : "?")
                   . " postFilter=" (awakeFs ? awakeFs["postFilter"] : "?")
                   . " s1(invalid)=" (awakeFs ? awakeFs["s1"] : "?")
                   . " s2(hp=0)=" (awakeFs ? awakeFs["s2"] : "?")
                   . " s3(lifeTgtGone)=" (awakeFs ? awakeFs["s3"] : "?")
                   . " s5(tgtFlip)=" (awakeFs ? awakeFs["s5"] : "?")
                   . " s6(frozen)=" (awakeFs ? awakeFs["s6"] : "?")
                   . " bl(blacklisted)=" (awakeFs ? awakeFs["bl"] : "?")
                   . " blTotal=" (awakeFs ? awakeFs["blTotal"] : "?")
                   . "`n"

        header := "Timestamp`tAddress`tRawPtr`tPath`tRarityId`tIsValid`tLifeDecoded`tHPcur`tHPmax`tIsAlive`tTargetableRaw`tTargetableDecoded`tReaction`tInBlacklist`tFirstSeenMs`tTgtDeadCount`tInFullAwakeScan`tEverAlive`tTgtEverOn`tRenderDecoded`tWorldX`tWorldY`tFrozenMs`n"
        rows   := ""
        now    := FormatTime(A_Now, "HH:mm:ss")

        awakeSample    := (awake.Has("sample"))    ? awake["sample"]    : []
        sleepingSample := (sleeping.Has("sample")) ? sleeping["sample"] : []

        processSample(sampleList, sourceLabel)
        {
            for _, sampleEntry in sampleList
            {
                entity := (sampleEntry && sampleEntry.Has("entity")) ? sampleEntry["entity"] : 0
                if !entity
                    continue

                addr   := entity.Has("address")    ? entity["address"]    : 0
                rawPtr := sampleEntry.Has("entityRawPtr") ? sampleEntry["entityRawPtr"] : 0
                path   := entity.Has("path")        ? entity["path"]       : ""
                isValid := entity.Has("isValid")   ? (entity["isValid"] ? 1 : 0) : "?"

                dc := entity.Has("decodedComponents") ? entity["decodedComponents"] : 0

                lifeDecoded := 0
                HPcur := ""
                HPmax := ""
                isAlive := ""
                if (dc && dc.Has("life") && dc["life"] && Type(dc["life"]) = "Map")
                {
                    lifeDecoded := 1
                    lf := dc["life"]
                    lStruct := (lf.Has("life") && Type(lf["life"]) = "Map") ? lf["life"] : 0
                    if lStruct
                    {
                        HPcur := lStruct.Has("current") ? lStruct["current"] : ""
                        HPmax := lStruct.Has("max")     ? lStruct["max"]     : ""
                    }
                    isAlive := lf.Has("isAlive") ? (lf["isAlive"] ? 1 : 0) : ""
                }

                ; Read IsTargetable byte directly from memory — ground truth
                targetableRaw := ""
                targetableDecoded := ""
                if (dc && dc.Has("targetable"))
                {
                    tgtV := dc["targetable"]
                    if (Type(tgtV) = "Map")
                        targetableDecoded := (tgtV.Has("isTargetable") && tgtV["isTargetable"]) ? 1 : 0
                    else
                        targetableDecoded := tgtV ? 1 : 0
                }
                ; Try to read raw byte from the entity's component list
                comps := entity.Has("components") ? entity["components"] : 0
                if (comps && Type(comps) = "Array")
                {
                    for _, comp in comps
                    {
                        if (comp && comp.Has("name") && comp.Has("address")
                            && InStr(comp["name"], "Targetable"))
                        {
                            cAddr := comp["address"]
                            if this.IsProbablyValidPointer(cAddr)
                            {
                                try targetableRaw := this.Mem.ReadUChar(cAddr + PoE2Offsets.Targetable["IsTargetable"])
                            }
                            break
                        }
                    }
                }

                reaction := ""
                if (dc && dc.Has("positioned") && dc["positioned"] && Type(dc["positioned"]) = "Map")
                    reaction := dc["positioned"].Has("reaction") ? dc["positioned"]["reaction"] : ""

                rarityId    := (dc && dc.Has("rarityId")) ? dc["rarityId"] : ""
                inBL        := (addr > 0 && blacklist.Has(addr))   ? 1 : 0
                firstSeenMs := (addr > 0 && firstSeen.Has(addr))   ? (A_TickCount - firstSeen[addr]) : 0
                tgtDead     := (addr > 0 && tgtDeadMap.Has(addr))  ? tgtDeadMap[addr] : 0
                inFullScan  := (rawPtr > 0 && fullRawPtrs.Has(rawPtr)) ? 1 : 0
                everAlive   := (addr > 0 && this._everAliveAddrs.Has(addr))  ? 1 : 0
                tgtEverOnF  := (addr > 0 && tgtEverOn.Has(addr))   ? 1 : 0

                renderDecoded := 0
                worldX := ""
                worldY := ""
                frozenMs := ""
                if (dc && dc.Has("render") && dc["render"] && Type(dc["render"]) = "Map")
                {
                    renderDecoded := 1
                    rnd := dc["render"]
                    if rnd.Has("worldPosition")
                    {
                        worldX := Round(rnd["worldPosition"]["x"], 1)
                        worldY := Round(rnd["worldPosition"]["y"], 1)
                    }
                }
                if (addr > 0 && this._posFrozenSinceTick.Has(addr))
                    frozenMs := A_TickCount - this._posFrozenSinceTick[addr]

                rows .= now "`t" Format("0x{:X}", addr) "`t" Format("0x{:X}", rawPtr) "`t" path
                     . "`t" rarityId "`t" isValid "`t" lifeDecoded "`t" HPcur "`t" HPmax
                     . "`t" isAlive "`t" targetableRaw "`t" targetableDecoded "`t" reaction
                     . "`t" inBL "`t" firstSeenMs "`t" tgtDead "`t" inFullScan
                     . "`t" everAlive "`t" tgtEverOnF
                     . "`t" renderDecoded "`t" worldX "`t" worldY "`t" frozenMs "`n"
            }
        }
        processSample(awakeSample, "awake")
        processSample(sleepingSample, "sleeping")

        try
        {
            FileAppend(statsLine . header . rows, outPath, "UTF-8")
            return outPath
        }
        catch
            return ""
    }

}