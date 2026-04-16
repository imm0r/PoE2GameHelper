#Requires AutoHotkey v2.0
#SingleInstance Force

#Include PoE2MemoryReader.ahk
#Include GgpkMemoryMonitor.ahk

class GgpkOffsets
{
    static LoadedFilesRoot := Map(
        "TotalCount", 0x10,
        "RootSize", 0x40
    )

    static StdBucket := Map(
        "Data", 0x00,
        "DataLast", 0x08
    )

    static FilesPointerStructure := Map(
        "EntrySize", 0x18,
        "FilesPointer", 0x08
    )

    static FileInfoValue := Map(
        "Name", 0x08,
        "AreaChangeCount", 0x40
    )
}

reader := PoE2GameStateReader("PathOfExileSteam.exe")
monitor := GgpkMemoryMonitor(reader)
monitor.SetLogger(AppendLog)

defaultUiOnly := A_ScriptDir "\ggpk_ui_files_only.json"
defaultFull := A_ScriptDir "\ggpk_directory_tree.json"
defaultExportPath := A_ScriptDir "\GgpkMemoryDiscoveries.txt"
defaultPreloadDump := A_ScriptDir "\preload_dumps\latest.txt"
defaultPreloadOutDir := A_ScriptDir "\preload_dumps"

autoPreloadDumpEnabled := false
lastAutoDumpAreaHash := ""
preloadLastDumpArea := "-"
preloadLastDumpCount := 0
preloadLastSkipReason := "idle"
cachedFileRootStatic := 0
preloadDumpInProgress := false
preloadDumpPhase := "idle"
compactModeEnabled := false

knownPath := FileExist(defaultUiOnly) ? defaultUiOnly : defaultFull

appGui := Gui("+AlwaysOnTop +Resize", "GGPK Memory Monitor (AHK v2)")
appGui.SetFont("s10", "Segoe UI")

ggpkJsonLabel := appGui.AddText("x10 y12", "GGPK JSON")
jsonPathEdit := appGui.AddEdit("x90 y9 w820", knownPath)
loadBtn := appGui.AddButton("x920 y8 w130 h24", "Load Strings")
buildJsonBtn := appGui.AddButton("x1060 y8 w130 h24", "Build JSON")

preloadDumpLabel := appGui.AddText("x10 y44", "Preload Dump")
dumpPathEdit := appGui.AddEdit("x90 y41 w1100", defaultPreloadDump)

dumpDirLabel := appGui.AddText("x10 y76", "Dump Dir")
preloadOutDirEdit := appGui.AddEdit("x90 y73 w1100", defaultPreloadOutDir)

exportLabel := appGui.AddText("x10 y108", "Export")
exportPathEdit := appGui.AddEdit("x90 y105 w960", defaultExportPath)
exportBtn := appGui.AddButton("x1060 y104 w130 h24", "Export")

startBtn := appGui.AddButton("x10 y138 w110 h26", "Start")
stopBtn := appGui.AddButton("x128 y138 w110 h26", "Stop")
manualBtn := appGui.AddButton("x246 y138 w130 h26", "Manual Scan")
dumpPreloadsBtn := appGui.AddButton("x384 y138 w130 h26", "Dump Preloads")
autoDumpCheckbox := appGui.AddCheckbox("x524 y142 w90", "AutoDump")
autoDumpCheckbox.Value := autoPreloadDumpEnabled ? 1 : 0
intervalLabel := appGui.AddText("x626 y143", "Interval ms")
intervalEdit := appGui.AddEdit("x695 y138 w70 Number", "3000")
compactCheckbox := appGui.AddCheckbox("x775 y142 w100", "Compact")
compactCheckbox.Value := compactModeEnabled ? 1 : 0

statusText := appGui.AddText("x10 y172 w1180", "Status: idle")
preloadStatusText := appGui.AddText("x10 y190 w1180", "Preloads: last area=- | count=0 | skip=idle")
dumpIndicatorText := appGui.AddText("x10 y208 w1180", "Dump: IDLE")

list := appGui.AddListView("x10 y234 w1180 h330 +Grid", ["Time", "Context", "String", "Address", "Parent"])
logBox := appGui.AddEdit("x10 y572 w1180 h150 ReadOnly -Wrap")

loadBtn.OnEvent("Click", OnLoadStrings)
buildJsonBtn.OnEvent("Click", OnBuildJson)
startBtn.OnEvent("Click", OnStart)
stopBtn.OnEvent("Click", OnStop)
manualBtn.OnEvent("Click", OnManualScan)
dumpPreloadsBtn.OnEvent("Click", OnDumpPreloads)
autoDumpCheckbox.OnEvent("Click", OnToggleAutoDump)
compactCheckbox.OnEvent("Click", OnToggleCompactMode)
exportBtn.OnEvent("Click", OnExport)
appGui.OnEvent("Close", OnClose)
appGui.OnEvent("Size", OnGuiSize)

appGui.Show("x20 y20 w1210 h735")
ApplyLayout(1210, 735)
SetTimer(RefreshUi, 1000)
RefreshUi()
return

OnGuiSize(guiObj, minMax, width, height)
{
    if (minMax = -1)
        return
    ApplyLayout(width, height)
}

OnToggleCompactMode(*)
{
    global compactCheckbox, compactModeEnabled, appGui
    compactModeEnabled := compactCheckbox.Value = 1

    appGui.GetClientPos(, , &w, &h)
    ApplyLayout(w, h)
}

ApplyLayout(width, height)
{
    global ggpkJsonLabel, jsonPathEdit, loadBtn, buildJsonBtn
    global preloadDumpLabel, dumpPathEdit, dumpDirLabel, preloadOutDirEdit
    global exportLabel, exportPathEdit, exportBtn
    global startBtn, stopBtn, manualBtn, dumpPreloadsBtn, autoDumpCheckbox, intervalLabel, intervalEdit, compactCheckbox
    global statusText, preloadStatusText, dumpIndicatorText, list, logBox
    global compactModeEnabled

    margin := 10
    gap := compactModeEnabled ? 5 : 8
    rowH := compactModeEnabled ? 21 : 24
    labelW := 80
    btnW := 130
    actionBtnW := 110
    actionWideW := 130
    logMinH := compactModeEnabled ? 120 : 150

    y1 := 8
    y2 := y1 + rowH + gap
    y3 := y2 + rowH + gap
    y4 := y3 + rowH + gap
    y5 := y4 + rowH + gap
    yStatus := y5 + rowH + gap

    right := width - margin

    buildX := right - btnW
    loadX := buildX - gap - btnW

    ggpkJsonLabel.Move(margin, y1 + 4)
    jsonEditX := margin + labelW
    jsonPathEdit.Move(jsonEditX, y1, loadX - gap - jsonEditX, rowH)
    loadBtn.Move(loadX, y1, btnW, rowH)
    buildJsonBtn.Move(buildX, y1, btnW, rowH)

    preloadDumpLabel.Move(margin, y2 + 4)
    dumpPathEdit.Move(jsonEditX, y2, right - jsonEditX, rowH)

    dumpDirLabel.Move(margin, y3 + 4)
    preloadOutDirEdit.Move(jsonEditX, y3, right - jsonEditX, rowH)

    exportLabel.Move(margin, y4 + 4)
    exportBtn.Move(right - btnW, y4, btnW, rowH)
    exportPathEdit.Move(jsonEditX, y4, right - btnW - gap - jsonEditX, rowH)

    x := margin
    startBtn.Move(x, y5, actionBtnW, rowH)
    x += actionBtnW + gap
    stopBtn.Move(x, y5, actionBtnW, rowH)
    x += actionBtnW + gap
    manualBtn.Move(x, y5, actionWideW, rowH)
    x += actionWideW + gap
    dumpPreloadsBtn.Move(x, y5, actionWideW, rowH)
    x += actionWideW + gap
    autoDumpCheckbox.Move(x, y5 + 4, 90, rowH)
    x += 90 + gap
    intervalLabel.Move(x, y5 + 4)
    x += 70
    intervalEdit.Move(x, y5, 70, rowH)
    x += 70 + gap
    compactCheckbox.Move(x, y5 + 4, 100, rowH)

    statusText.Move(margin, yStatus, width - (margin * 2), 18)
    preloadStatusText.Move(margin, yStatus + 18, width - (margin * 2), 18)
    dumpIndicatorText.Move(margin, yStatus + 36, width - (margin * 2), 18)

    listY := yStatus + 62
    logY := height - margin - logMinH
    if (logY < listY + 120)
        logY := listY + 120

    list.Move(margin, listY, width - (margin * 2), logY - gap - listY)
    logBox.Move(margin, logY, width - (margin * 2), height - margin - logY)
}

OnLoadStrings(*)
{
    global monitor, jsonPathEdit
    path := Trim(jsonPathEdit.Value)
    if (path = "")
    {
        AppendLog("[UI] ❌ Please enter GGPK JSON path")
        return
    }

    ok := monitor.InitializeFromGgpkExport(path)
    if ok
        AppendLog("[UI] ✅ Known strings loaded")
    else
        AppendLog("[UI] ❌ Failed to load strings from JSON")

    RefreshUi()
}

OnBuildJson(*)
{
    global dumpPathEdit, jsonPathEdit, preloadDumpInProgress

    if preloadDumpInProgress
    {
        AppendLog("[UI] ⏳ Build JSON blocked: preload dump is running")
        return
    }

    dumpPath := Trim(dumpPathEdit.Value)
    outJsonPath := Trim(jsonPathEdit.Value)

    if (dumpPath = "")
    {
        AppendLog("[UI] ❌ Please enter preload dump path")
        return
    }

    if (outJsonPath = "")
    {
        AppendLog("[UI] ❌ Please enter GGPK JSON output path")
        return
    }

    if !FileExist(dumpPath)
    {
        AppendLog("[UI] ❌ Preload dump not found: " dumpPath)
        return
    }

    try
    {
        count := BuildUiJsonFromPreloadDump(dumpPath, outJsonPath)
        AppendLog("[UI] ✅ Built GGPK JSON with " count " entries: " outJsonPath)
    }
    catch as ex
    {
        AppendLog("[UI] ❌ Build JSON failed: " ex.Message)
    }
}

OnStart(*)
{
    global monitor, intervalEdit

    interval := ParseIntOrDefault(intervalEdit.Value, 3000)
    interval := Max(500, interval)

    ok := monitor.StartMonitoring(interval)
    if !ok
        AppendLog("[UI] ❌ Start failed: " monitor.LastError)

    RefreshUi()
}

OnStop(*)
{
    global monitor
    monitor.StopMonitoring()
    RefreshUi()
}

OnManualScan(*)
{
    global monitor, reader

    if (!reader.Mem.Handle)
    {
        if !reader.Connect(false)
        {
            AppendLog("[UI] ❌ Reader connect failed")
            return
        }
    }

    snapshot := reader.ReadSnapshot()
    if !snapshot || !snapshot.Has("currentStateName") || snapshot["currentStateName"] != "InGameState"
    {
        AppendLog("[UI] ❌ Manual scan only in InGameState")
        return
    }

    inGame := snapshot["inGameState"]
    if !inGame
    {
        AppendLog("[UI] ❌ InGameState data is null")
        return
    }

    addr := inGame.Has("activeGameUiPtr") ? inGame["activeGameUiPtr"] : 0
    if (!addr || !reader.IsProbablyValidPointer(addr))
    {
        AppendLog("[UI] ❌ activeGameUiPtr is invalid")
        return
    }

    found := monitor.ScanForGgpkStrings(addr, 2 * 1024 * 1024, "Manual-GameUi")
    AppendLog("[UI] 🔎 Manual scan done, new discoveries: " found)
    RefreshUi()
}

OnExport(*)
{
    global monitor, exportPathEdit
    path := Trim(exportPathEdit.Value)
    if (path = "")
    {
        AppendLog("[UI] ❌ Please enter export path")
        return
    }

    try
    {
        monitor.ExportDiscoveries(path)
        AppendLog("[UI] ✅ Exported discoveries")
    }
    catch as ex
    {
        AppendLog("[UI] ❌ Export failed: " ex.Message)
    }
}

OnDumpPreloads(*)
{
    global preloadDumpInProgress, preloadLastSkipReason

    if preloadDumpInProgress
    {
        preloadLastSkipReason := "already-running"
        AppendLog("[Preloads] ⏳ Dump already running")
        return
    }

    if DumpCurrentAreaPreloads(&outPath, &count, &msg)
    {
        preloadLastSkipReason := "manual-ok"
        AppendLog("[Preloads] ✅ Dumped " count " paths -> " outPath)
    }
    else
    {
        preloadLastSkipReason := msg
        AppendLog("[Preloads] ❌ " msg)
    }
}

OnToggleAutoDump(*)
{
    global autoDumpCheckbox, autoPreloadDumpEnabled, preloadLastSkipReason
    autoPreloadDumpEnabled := autoDumpCheckbox.Value = 1
    preloadLastSkipReason := autoPreloadDumpEnabled ? "auto-on" : "auto-off"
    AppendLog("[Preloads] AutoDump is now " (autoPreloadDumpEnabled ? "ON" : "OFF"))
}

RefreshUi()
{
    global monitor, statusText, preloadStatusText, dumpIndicatorText, list
    global buildJsonBtn, dumpPreloadsBtn, preloadDumpInProgress

    stats := monitor.GetStats()
    runningText := stats["isMonitoring"] ? "RUNNING" : "STOPPED"
    lastScan := stats["lastScan"] = "" ? "never" : FormatTime(stats["lastScan"], "yyyy-MM-dd HH:mm:ss")
    status := "Status: " runningText
    status .= " | Known: " stats["knownStrings"]
    status .= " | Discovered: " stats["discoveredCount"]
    status .= " | LastScan: " lastScan
    if (stats["lastError"] != "")
        status .= " | LastError: " stats["lastError"]
    statusText.Value := status

    list.Delete()
    for disc in monitor.GetDiscoveries(120)
    {
        ts := disc["timestamp"]
        tsText := ts != "" ? FormatTime(ts, "HH:mm:ss") : ""
        addr := "0x" Format("{:X}", disc["memoryAddress"])
        parent := disc["possibleParentAddress"] ? ("0x" Format("{:X}", disc["possibleParentAddress"])) : ""
        list.Add(, tsText, disc["context"], disc["knownString"], addr, parent)
    }

    MaybeAutoDumpPreloads()

    preloadStatusText.Opt("c" GetPreloadStatusColor())
    preloadStatusText.Value := BuildPreloadStatusText()

    dumpIndicatorText.Opt("c" GetDumpIndicatorColor())
    dumpIndicatorText.Value := BuildDumpIndicatorText()

    buildJsonBtn.Enabled := !preloadDumpInProgress
    dumpPreloadsBtn.Enabled := !preloadDumpInProgress
}

MaybeAutoDumpPreloads()
{
    global autoPreloadDumpEnabled, lastAutoDumpAreaHash, preloadLastSkipReason

    if !autoPreloadDumpEnabled
    {
        preloadLastSkipReason := "auto-off"
        return
    }

    if !TryGetAreaContext(&ctx)
    {
        preloadLastSkipReason := "not-ingame"
        return
    }

    if (ctx["areaHash"] = "")
    {
        preloadLastSkipReason := "no-area-hash"
        return
    }

    if (ctx["isTown"] || ctx["isHideout"])
    {
        preloadLastSkipReason := "town-hideout"
        return
    }

    if (ctx["areaHash"] = lastAutoDumpAreaHash)
    {
        preloadLastSkipReason := "same-area"
        return
    }

    if DumpCurrentAreaPreloads(&outPath, &count, &msg)
    {
        lastAutoDumpAreaHash := ctx["areaHash"]
        preloadLastSkipReason := "auto-ok"
        AppendLog("[Preloads] AutoDump " count " paths for " ctx["areaName"] " -> " outPath)
    }
    else
    {
        preloadLastSkipReason := msg
        AppendLog("[Preloads] AutoDump skipped: " msg)
    }
}

DumpCurrentAreaPreloads(&outPath, &count, &msg)
{
    global reader, preloadOutDirEdit, dumpPathEdit, preloadLastDumpArea, preloadLastDumpCount
    global preloadDumpInProgress, preloadDumpPhase

    preloadDumpInProgress := true
    preloadDumpPhase := "prepare"
    Sleep(10)

    try
    {
        outPath := ""
        count := 0
        msg := ""

        preloadDumpPhase := "connect"
        if !EnsureReaderConnected(&err)
        {
            msg := err
            return false
        }

        preloadDumpPhase := "state"
        if !TryGetAreaContext(&ctx)
        {
            msg := "not in InGameState"
            return false
        }

        preloadDumpPhase := "scan-file-root"
        rootMap := ScanLoadedFilesFromFileRoot(&scanErr)
        if !rootMap
        {
            msg := scanErr
            return false
        }

        names := rootMap["names"]
        if (names.Length = 0)
        {
            msg := "no preload paths found"
            return false
        }

        safeName := MakeSafeFileName(ctx["areaName"])
        if (safeName = "")
            safeName := "Area"
        fileName := safeName "_" ctx["areaHash"] ".txt"

        outDir := Trim(preloadOutDirEdit.Value)
        if (outDir = "")
            outDir := A_ScriptDir "\preload_dumps"
        if !DirExist(outDir)
            DirCreate(outDir)

        outPath := outDir "\" fileName

        preloadDumpPhase := "write-file"
        text := ""
        for name in names
            text .= name "`n"

        if FileExist(outPath)
            FileDelete(outPath)
        FileAppend(text, outPath, "UTF-8")
        dumpPathEdit.Value := outPath

        count := names.Length
        preloadLastDumpArea := ctx["areaName"] " (" ctx["areaHash"] ")"
        preloadLastDumpCount := count
        return true
    }
    finally
    {
        preloadDumpInProgress := false
        preloadDumpPhase := "idle"
    }
}

BuildPreloadStatusText()
{
    global preloadLastDumpArea, preloadLastDumpCount, preloadLastSkipReason
    return "Preloads: last area=" preloadLastDumpArea " | count=" preloadLastDumpCount " | skip=" preloadLastSkipReason
}

BuildDumpIndicatorText()
{
    global preloadDumpInProgress, preloadDumpPhase
    if preloadDumpInProgress
        return "Dump: RUNNING (" preloadDumpPhase ")"
    return "Dump: IDLE"
}

GetDumpIndicatorColor()
{
    global preloadDumpInProgress
    return preloadDumpInProgress ? "Aqua" : "Silver"
}

GetPreloadStatusColor()
{
    global preloadLastSkipReason

    reason := StrLower(Trim(preloadLastSkipReason))
    if (reason = "")
        return "Silver"

    if (InStr(reason, "ok") || InStr(reason, "manual-ok") || InStr(reason, "auto-ok"))
        return "Lime"

    if (reason = "auto-off" || reason = "same-area" || reason = "idle")
        return "FFB000"

    return "Red"
}

SortTextArray(items)
{
    arr := []
    for item in items
        arr.Push(item)

    n := arr.Length
    if (n <= 1)
        return arr

    i := 2
    while (i <= n)
    {
        key := arr[i]
        j := i - 1
        while (j >= 1 && StrCompare(arr[j], key, true) > 0)
        {
            arr[j + 1] := arr[j]
            j -= 1
        }
        arr[j + 1] := key
        i += 1
    }

    return arr
}

ScanLoadedFilesFromFileRoot(&err)
{
    global reader, cachedFileRootStatic
    err := ""

    ; Fast path: if we already resolved a File Root static address, reuse it.
    if (cachedFileRootStatic && reader.IsProbablyValidPointer(cachedFileRootStatic))
    {
        if !reader.StaticAddresses
            reader.StaticAddresses := Map()
        if !reader.StaticAddresses.Has("File Root")
            reader.StaticAddresses["File Root"] := cachedFileRootStatic
    }

    if !reader.StaticAddresses || !reader.StaticAddresses.Has("File Root")
    {
        ; Connect(false) can return early with GameStates resolved, without full static pattern map.
        ; Resolve static addresses on-demand for File Root.
        try
        {
            refreshed := reader.FindStaticAddresses()
            if (refreshed && Type(refreshed) = "Map" && refreshed.Count > 0)
            {
                if !reader.StaticAddresses
                    reader.StaticAddresses := Map()
                for key, value in refreshed
                    reader.StaticAddresses[key] := value
            }
        }
        catch
        {
        }
    }

    if !reader.StaticAddresses || !reader.StaticAddresses.Has("File Root")
    {
        if ResolveStaticAddressByName("File Root", &resolvedAddr, &resolveReason)
        {
            if !reader.StaticAddresses
                reader.StaticAddresses := Map()
            reader.StaticAddresses["File Root"] := resolvedAddr
        }
        else if (resolveReason != "")
        {
            err := "File Root static address not found (" resolveReason ")"
            return 0
        }
    }

    if !reader.StaticAddresses || !reader.StaticAddresses.Has("File Root")
    {
        err := "File Root static address not found"
        return 0
    }

    fileRootStatic := reader.StaticAddresses["File Root"]
    if !reader.IsProbablyValidPointer(fileRootStatic)
    {
        err := "File Root static address invalid"
        return 0
    }
    cachedFileRootStatic := fileRootStatic

    rootBase := reader.Mem.ReadPtr(fileRootStatic)
    if !reader.IsProbablyValidPointer(rootBase)
    {
        err := "File Root base pointer is invalid"
        return 0
    }

    rootCount := GgpkOffsets.LoadedFilesRoot["TotalCount"]
    rootSize := GgpkOffsets.LoadedFilesRoot["RootSize"]
    nodeSize := GgpkOffsets.FilesPointerStructure["EntrySize"]
    maxNodesPerRoot := 200000

    byNameAreaCount := Map()
    latestAreaCount := 0

    loop rootCount
    {
        idx := A_Index - 1
        rootAddr := rootBase + (idx * rootSize)

        first := reader.Mem.ReadInt64(rootAddr + GgpkOffsets.StdBucket["Data"])
        last := reader.Mem.ReadInt64(rootAddr + GgpkOffsets.StdBucket["DataLast"])

        if (first <= 0 || last <= first)
            continue

        bytes := last - first
        if (bytes <= 0)
            continue

        nodeCount := Floor(bytes / nodeSize)
        if (nodeCount <= 0)
            continue
        if (nodeCount > maxNodesPerRoot)
            nodeCount := maxNodesPerRoot

        loop nodeCount
        {
            ni := A_Index - 1
            nodeAddr := first + (ni * nodeSize)
            fileInfoPtr := reader.Mem.ReadPtr(nodeAddr + GgpkOffsets.FilesPointerStructure["FilesPointer"])
            if !reader.IsProbablyValidPointer(fileInfoPtr)
                continue

            areaChangeCount := reader.Mem.ReadInt(fileInfoPtr + GgpkOffsets.FileInfoValue["AreaChangeCount"])
            if (areaChangeCount > latestAreaCount)
                latestAreaCount := areaChangeCount

            name := reader.ReadStdWStringAt(fileInfoPtr + GgpkOffsets.FileInfoValue["Name"])
            if (name = "")
                continue

            atPos := InStr(name, "@")
            if (atPos > 1)
                name := SubStr(name, 1, atPos - 1)

            if (name = "")
                continue

            prev := byNameAreaCount.Has(name) ? byNameAreaCount[name] : -2147483648
            if (areaChangeCount > prev)
                byNameAreaCount[name] := areaChangeCount
        }
    }

    if (byNameAreaCount.Count = 0)
    {
        err := "File Root scan returned no names"
        return 0
    }

    names := []
    for name, acc in byNameAreaCount
    {
        if (acc > 2 && acc = latestAreaCount)
            names.Push(name)
    }

    if (names.Length = 0)
    {
        ; fallback: if strict area-change filter yields nothing, include all names once
        for name, _ in byNameAreaCount
            names.Push(name)
    }

    names := SortTextArray(names)

    return Map(
        "latestAreaCount", latestAreaCount,
        "names", names
    )
}

ResolveStaticAddressByName(targetName, &address, &reason)
{
    global reader
    address := 0
    reason := ""

    patterns := reader.GetStaticPatterns()
    if !patterns
    {
        reason := "no-patterns"
        return false
    }

    targetPattern := ""
    for p in patterns
    {
        if (p.Has("name") && p["name"] = targetName)
        {
            targetPattern := p["pattern"]
            break
        }
    }

    if (targetPattern = "")
    {
        reason := "pattern-missing"
        return false
    }

    moduleBytes := reader.Mem.GetModuleSnapshot(true)
    if (!moduleBytes || Type(moduleBytes) != "Buffer" || moduleBytes.Size <= 0)
    {
        reason := "snapshot-missing"
        return false
    }

    parsed := reader.ParsePattern(targetPattern)
    deadline := A_TickCount + 6000
    matches := reader.FindPatternAddressesInBuffer(moduleBytes, moduleBytes.Size, reader.Mem.ModuleSnapshotBase, parsed, 2, deadline)

    if (matches.Length = 0)
    {
        reason := "pattern-no-match"
        return false
    }

    if (parsed["bytesToSkip"] < 0)
    {
        reason := "no-anchor"
        return false
    }

    if (matches.Length > 1)
        reason := "pattern-duplicate"

    matchAddress := matches[1]
    relOperandAddress := matchAddress + parsed["bytesToSkip"]
    relValue := reader.Mem.ReadInt(relOperandAddress)
    finalAddress := relOperandAddress + relValue + 4
    if !reader.IsProbablyValidPointer(finalAddress)
    {
        reason := "resolved-invalid"
        return false
    }

    address := finalAddress
    if (reason = "")
        reason := "resolved"
    return true
}

TryGetAreaContext(&ctx)
{
    global reader
    ctx := 0

    snapshot := reader.ReadSnapshot()
    if !snapshot
        return false

    if !snapshot.Has("currentStateName") || snapshot["currentStateName"] != "InGameState"
        return false

    inGame := snapshot.Has("inGameState") ? snapshot["inGameState"] : 0
    if !inGame
        return false

    areaInst := inGame.Has("areaInstance") ? inGame["areaInstance"] : 0
    if !areaInst
        return false

    worldDet := inGame.Has("worldDataDetails") ? inGame["worldDataDetails"] : 0
    worldArea := (worldDet && worldDet.Has("worldAreaDat")) ? worldDet["worldAreaDat"] : 0

    areaName := "UnknownArea"
    if (worldArea)
    {
        areaName := worldArea.Has("name") ? worldArea["name"] : areaName
        if (areaName = "")
            areaName := worldArea.Has("id") ? worldArea["id"] : "UnknownArea"
    }

    areaHash := areaInst.Has("currentAreaHash") ? Format("{:X}", areaInst["currentAreaHash"]) : ""

    isTown := false
    isHideout := false
    if (worldArea)
    {
        isTown := worldArea.Has("isTown") && worldArea["isTown"]
        isHideout := worldArea.Has("isHideout") && worldArea["isHideout"]
    }

    ctx := Map(
        "areaName", areaName,
        "areaHash", areaHash,
        "isTown", isTown ? true : false,
        "isHideout", isHideout ? true : false
    )
    return true
}

EnsureReaderConnected(&err)
{
    global reader
    err := ""

    if (reader.Mem && reader.Mem.Handle)
        return true

    if !reader.Connect(false)
    {
        err := "reader connect failed"
        return false
    }

    return true
}

MakeSafeFileName(name)
{
    s := Trim(name)
    if (s = "")
        return ""
    for ch in ["\\", "/", ":", "*", "?", Chr(34), "<", ">", "|"]
        s := StrReplace(s, ch, "_")
    s := RegExReplace(s, "\s+", "_")
    s := RegExReplace(s, "_+", "_")
    return Trim(s, "_")
}

AppendLog(text)
{
    global logBox
    ts := FormatTime(A_Now, "HH:mm:ss")
    current := logBox.Value
    next := current "[" ts "] " text "`r`n"

    maxChars := 20000
    if (StrLen(next) > maxChars)
        next := SubStr(next, StrLen(next) - maxChars + 1)

    logBox.Value := next
}

ParseIntOrDefault(raw, fallback)
{
    t := Trim(raw)
    if !RegExMatch(t, "^-?\d+$")
        return fallback
    return Integer(t)
}

BuildUiJsonFromPreloadDump(dumpPath, outJsonPath)
{
    unique := Map()
    q := Chr(34)

    Loop Read, dumpPath
    {
        line := Trim(A_LoopReadLine)
        if (line = "")
            continue
        if (SubStr(line, 1, 1) = "#" || SubStr(line, 1, 1) = ";")
            continue

        path := StrReplace(line, "\\", "/")
        while InStr(path, "//")
            path := StrReplace(path, "//", "/")

        unique[path] := true
    }

    if (unique.Count = 0)
        throw Error("No usable paths found in preload dump")

    lines := []
    lines.Push("{")
    lines.Push("  " q "generated_by" q ": " q "GgpkMemoryMonitorApp.ahk" q ",")
    lines.Push("  " q "source_dump" q ": " q JsonEscape(dumpPath) q ",")
    lines.Push("  " q "ui_files" q ": [")

    idx := 0
    total := unique.Count
    for path, _ in unique
    {
        idx += 1
        ext := GetFileExtension(path)
        ty := GuessFileType(ext, path)
        uiCat := GuessUiCategory(path)

        row := "    {"
        row .= q "hash" q ":" idx
        row .= "," q "path" q ":" q JsonEscape(path) q
        row .= "," q "ext" q ":" q JsonEscape(ext) q
        row .= "," q "ty" q ":" q JsonEscape(ty) q
        row .= "," q "ui_cat" q ":" q JsonEscape(uiCat) q
        row .= "}"
        if (idx < total)
            row .= ","

        lines.Push(row)
    }

    lines.Push("  ]")
    lines.Push("}")

    outText := ""
    for line in lines
        outText .= line "`r`n"

    SplitPath(outJsonPath, , &outDir)
    if (outDir != "" && !DirExist(outDir))
        DirCreate(outDir)

    if FileExist(outJsonPath)
        FileDelete(outJsonPath)
    FileAppend(outText, outJsonPath, "UTF-8")

    return total
}

GetFileExtension(path)
{
    p := path
    dotPos := InStr(p, ".",, -1)
    slashPos := InStr(p, "/",, -1)
    if (dotPos <= 0 || (slashPos > 0 && dotPos < slashPos))
        return ""
    return StrLower(SubStr(p, dotPos))
}

GuessFileType(ext, path)
{
    if (ext = ".dds" || ext = ".png" || ext = ".tga")
        return "tex"
    if (ext = ".layout" || ext = ".ui")
        return "ui"
    if (ext = ".otf" || ext = ".ttf")
        return "font"
    if InStr(StrLower(path), "/metadata/")
        return "meta"
    return "oth"
}

GuessUiCategory(path)
{
    p := StrLower(path)
    if InStr(p, "/textures/") || InStr(p, "/art/textures/interface")
        return "Texture"
    if InStr(p, "/layout") || InStr(p, ".layout")
        return "Layout"
    if InStr(p, "/icon")
        return "Icon"
    if InStr(p, "/font") || InStr(p, ".ttf") || InStr(p, ".otf")
        return "Font"
    return "Other"
}

JsonEscape(s)
{
    t := s
    t := StrReplace(t, "\", "\\")
    t := StrReplace(t, Chr(34), Chr(92) Chr(34))
    t := StrReplace(t, "`r", "\r")
    t := StrReplace(t, "`n", "\n")
    t := StrReplace(t, "`t", "\t")
    return t
}

OnClose(*)
{
    global monitor
    try monitor.StopMonitoring()
    ExitApp
}
