; Resolves the project root — the directory that holds gamehelper_config.ini,
; data\, logs\, debug\, etc. — independently of which script launched the helper.
; A_ScriptDir points at the *launched* script's folder, which is the repo root
; for InGameStateMonitor.ahk but a subfolder (dev\) for the standalone dev tools,
; so paths built from A_ScriptDir break there. Every module lives under
; <root>\ahk\, and A_LineFile inside this function always resolves to
; ...\ahk\ProcessMemory.ahk regardless of the caller, so the root is the parent
; of this file's own directory. Result is cached after the first call.
global g_appRoot := ""
AppRoot()
{
    global g_appRoot
    if (g_appRoot != "")
        return g_appRoot
    SplitPath(A_LineFile, , &dir)   ; dir    = ...\ahk
    SplitPath(dir, , &parent)       ; parent = project root
    g_appRoot := (parent != "") ? parent : A_ScriptDir
    return g_appRoot
}

GetKnownPoeExeCandidates()
{
    return ["PathOfExileSteam.exe", "PathOfExile_x64Steam.exe", "PathOfExile.exe", "PathOfExile_x64.exe"]
}

; Helper: detect installed/active PoE executable name from common candidates.
DetectPoeExeName()
{
    for name in GetKnownPoeExeCandidates()
        if ProcessExist(name)
            return name

    name := ResolvePoeExeNameFromCachedInstall()
    if (name != "")
        return name

    name := ResolvePoeExeNameFromSteamInstall()
    if (name != "")
        return name

    return GetKnownPoeExeCandidates()[1]
}

; Helper: return PID of first-matching running PoE process, or 0.
FindPoePid()
{
    for name in GetKnownPoeExeCandidates()
    {
        pid := ProcessExist(name)
        if (pid)
            return pid
    }
    return 0
}

; Helper: return main window HWND for PoE if present, or 0.
GetPoeMainWindowHwnd()
{
    for name in GetKnownPoeExeCandidates()
    {
        hwnd := WinExist("ahk_exe " name)
        if (hwnd)
            return hwnd
    }
    return 0
}

ResolvePoeExeNameFromCachedInstall()
{
    ; Resolve the config path inline rather than calling _ConfigPath():
    ; ProcessMemory.ahk is included by standalone entrypoints (SmokeTest.ahk,
    ; PatternScanDemo.ahk, GgpkMemoryMonitorApp.ahk) that don't include
    ; ConfigManager.ahk, where _ConfigPath() lives — and a call to an undefined
    ; function is a load-time error in v2. This mirrors _ConfigPath() exactly.
    configPath := AppRoot() "\gamehelper_config.ini"

    indexPath := IniRead(configPath, "GgpkTools", "lastIndexPath", "")
    if (!FileExist(indexPath))
        return ""

    installDir := ""
    if (InStr(indexPath, "\Bundles2\_.index.bin"))
        installDir := SubStr(indexPath, 1, StrLen(indexPath) - StrLen("\Bundles2\_.index.bin"))
    else if (InStr(indexPath, "\Content.ggpk"))
        installDir := SubStr(indexPath, 1, StrLen(indexPath) - StrLen("\Content.ggpk"))

    if (installDir = "" || !DirExist(installDir))
        return ""

    for name in GetKnownPoeExeCandidates()
    {
        if FileExist(installDir "\" name)
            return name
    }
    return ""
}

ResolvePoeExeNameFromSteamInstall()
{
    exeNames := GetKnownPoeExeCandidates()
    steamRoot := RegRead("HKLM\SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath", "")
    if (steamRoot = "")
        steamRoot := RegRead("HKLM\SOFTWARE\Valve\Steam", "InstallPath", "")
    if (steamRoot = "" || !DirExist(steamRoot))
        return ""

    vdf := steamRoot "\steamapps\libraryfolders.vdf"
    if (!FileExist(vdf))
        return ""

    libraries := ParseSteamLibraryPaths(vdf)
    if (!ListContains(libraries, steamRoot))
        libraries.Push(steamRoot)

    for _, lib in libraries
    {
        manifest := lib "\steamapps\appmanifest_2694490.acf"
        if (!FileExist(manifest))
            continue
        installDir := ParseAcfKey(manifest, "installdir")
        if (installDir = "")
            continue

        baseDir := lib "\steamapps\common\" installDir
        for name in exeNames
            if FileExist(baseDir "\" name)
                return name
    }
    return ""
}

ParseSteamLibraryPaths(vdfPath)
{
    contents := FileRead(vdfPath)
    paths := []
    for line in StrSplit(contents, "`n")
    {
        if RegExMatch(line, '"path"\s*"([^"]+)"', &m)
        {
            ; libraryfolders.vdf escapes backslashes ("C:\\Games") — unescape.
            path := StrReplace(m[1], "\\", "\")
            if (path != "" && DirExist(path))
                paths.Push(path)
        }
    }
    return paths
}

ParseAcfKey(manifestPath, key)
{
    contents := FileRead(manifestPath)
    pattern := '"' key '"\s*"([^"]+)"'
    if RegExMatch(contents, pattern, &m)
        return m[1]
    return ""
}

ListContains(list, value)
{
    for _, item in list
        if (item = value)
            return true
    return false
}

class ProcessMemory
{
    ; Initializes all process, handle, and module tracking fields to zero/default.
    __New(processName := "")
    {
        ; Initialize all fields first so the object is fully formed even if the
        ; executable detection below throws — otherwise __Delete/Close() would
        ; later fault on a missing this.Handle.
        this.ProcessName := ""
        this.Pid := 0
        this.Handle := 0
        this.ModuleBase := 0
        this.ModuleSize := 0
        this.LastOpenError := 0
        this.LastReadError := 0
        this.LastBytesRead := 0
        this.LastReadSuccess := 0
        this.ModuleSnapshot := 0
        this.ModuleSnapshotBase := 0
        this.ModuleSnapshotSize := 0
        this.ScanBase := 0
        this.ScanSize := 0
        this.ProcessName := (processName != "") ? processName : DetectPoeExeName()
    }

    ; Closes the process handle when the object is destroyed.
    __Delete()
    {
        this.Close()
    }

    ; Opens a handle to the target process and resolves its main module base address.
    ; Returns: true on success, false if the process is not found or module info is unavailable.
    Open()
    {
        this.Close()

        pid := ProcessExist(this.ProcessName)
        if (!pid)
        {
            baseName := StrReplace(this.ProcessName, ".exe")
            pid := ProcessExist(baseName)
        }

        if (!pid)
            return false

        handle := DllCall("OpenProcess", "UInt", 0x0010 | 0x0400, "Int", false, "UInt", pid, "Ptr")
        this.LastOpenError := A_LastError
        if (!handle)
            return false

        this.Pid := pid
        this.Handle := handle

        if (!this.RefreshMainModuleInfo())
        {
            this.Close()
            return false
        }

        return true
    }

    ; Closes the process handle and resets all cached module, snapshot, and scan state.
    Close()
    {
        ; Guard against a partially-constructed object (e.g. if __New threw
        ; during executable detection before Handle was assigned).
        if (this.HasOwnProp("Handle") && this.Handle)
            DllCall("CloseHandle", "Ptr", this.Handle)

        this.Pid := 0
        this.Handle := 0
        this.ModuleBase := 0
        this.ModuleSize := 0
        this.ModuleSnapshot := 0
        this.ModuleSnapshotBase := 0
        this.ModuleSnapshotSize := 0
        this.ScanBase := 0
        this.ScanSize := 0
    }

    ; Enumerates loaded modules via Toolhelp32Snapshot to locate the main module base address and size.
    ; Returns: true if the module matching ProcessName was found.
    RefreshMainModuleInfo()
    {
        if (!this.Pid)
            return false

        TH32CS_SNAPMODULE := 0x00000008
        TH32CS_SNAPMODULE32 := 0x00000010

        snapshot := DllCall("CreateToolhelp32Snapshot", "UInt", TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, "UInt", this.Pid, "Ptr")
        if (snapshot = -1 || snapshot = 0)
            return false

        entrySize := (A_PtrSize = 8) ? 1080 : 548
        me32 := Buffer(entrySize, 0)
        NumPut("UInt", entrySize, me32, 0)

        offsets := Map()
        if (A_PtrSize = 8)
        {
            offsets["modBaseAddr"] := 24
            offsets["modBaseSize"] := 32
            offsets["szModule"] := 48
        }
        else
        {
            offsets["modBaseAddr"] := 20
            offsets["modBaseSize"] := 24
            offsets["szModule"] := 32
        }

        found := false
        if DllCall("Module32FirstW", "Ptr", snapshot, "Ptr", me32, "Int")
        {
            loop
            {
                moduleName := StrGet(me32.Ptr + offsets["szModule"], 256, "UTF-16")
                if (StrLower(moduleName) = StrLower(this.ProcessName))
                {
                    this.ModuleBase := NumGet(me32.Ptr, offsets["modBaseAddr"], "Ptr")
                    this.ModuleSize := NumGet(me32.Ptr, offsets["modBaseSize"], "UInt")
                    found := true
                    break
                }

                if !DllCall("Module32NextW", "Ptr", snapshot, "Ptr", me32, "Int")
                    break
            }
        }

        DllCall("CloseHandle", "Ptr", snapshot)
        return found
    }

    ; Reads raw bytes from the target process at the given address via ReadProcessMemory.
    ; Params: allowPartial - if true, returns a smaller Buffer instead of 0 when fewer bytes are read.
    ; Returns: Buffer on success, 0 on failure.
    ReadBytes(address, size, allowPartial := false)
    {
        if (!this.Handle || !address || size <= 0)
            return 0

        buf := Buffer(size, 0)
        bytesRead := 0
        success := DllCall("ReadProcessMemory", "Ptr", this.Handle, "Ptr", address, "Ptr", buf.Ptr, "UPtr", size, "UPtr*", bytesRead, "Int")
        this.LastReadError := A_LastError
        this.LastBytesRead := bytesRead
        this.LastReadSuccess := success

        if (success)
        {
            effectiveBytes := (bytesRead > 0) ? bytesRead : size
            this.LastBytesRead := effectiveBytes

            if (!allowPartial && effectiveBytes < size)
                return 0

            if (allowPartial && effectiveBytes < size)
            {
                partial := Buffer(effectiveBytes, 0)
                DllCall("RtlMoveMemory", "Ptr", partial.Ptr, "Ptr", buf.Ptr, "UPtr", effectiveBytes)
                return partial
            }

            return buf
        }

        if (bytesRead <= 0)
            return 0

        if (!allowPartial && bytesRead < size)
            return 0

        partial := Buffer(bytesRead, 0)
        DllCall("RtlMoveMemory", "Ptr", partial.Ptr, "Ptr", buf.Ptr, "UPtr", bytesRead)
        return partial
    }

    ; Reads a native pointer-sized value (4 or 8 bytes depending on A_PtrSize) from the target process.
    ReadPtr(address)
    {
        buf := this.ReadBytes(address, A_PtrSize)
        return buf ? NumGet(buf.Ptr, 0, "Ptr") : 0
    }

    ; Reads a signed 32-bit integer from the target process.
    ReadInt(address)
    {
        buf := this.ReadBytes(address, 4)
        return buf ? NumGet(buf.Ptr, 0, "Int") : 0
    }

    ; Reads a signed 64-bit integer from the target process.
    ReadInt64(address)
    {
        buf := this.ReadBytes(address, 8)
        return buf ? NumGet(buf.Ptr, 0, "Int64") : 0
    }

    ; Reads an unsigned 32-bit integer from the target process.
    ReadUInt(address)
    {
        buf := this.ReadBytes(address, 4)
        return buf ? NumGet(buf.Ptr, 0, "UInt") : 0
    }

    ; Reads an unsigned 8-bit byte from the target process.
    ReadUChar(address)
    {
        buf := this.ReadBytes(address, 1)
        return buf ? NumGet(buf.Ptr, 0, "UChar") : 0
    }

    ; Reads a signed 16-bit integer from the target process.
    ReadShort(address)
    {
        buf := this.ReadBytes(address, 2)
        return buf ? NumGet(buf.Ptr, 0, "Short") : 0
    }

    ; Reads a 32-bit floating-point value from the target process.
    ReadFloat(address)
    {
        buf := this.ReadBytes(address, 4)
        return buf ? NumGet(buf.Ptr, 0, "Float") : 0
    }

    ; Reads a boolean value by interpreting a non-zero UChar as true.
    ReadBool(address)
    {
        return this.ReadUChar(address) != 0
    }

    ; Reads a null-terminated UTF-16 string from the target process.
    ; Params: maxBytes - maximum bytes to read before stopping; scanning stops at the first null wchar.
    ; Returns: decoded string, or "" if the address is invalid or contains no text.
    ReadUnicodeString(address, maxBytes := 512)
    {
        if (!address || maxBytes <= 2)
            return ""

        buf := this.ReadBytes(address, maxBytes, true)
        if (!buf || Type(buf) != "Buffer" || buf.Size < 2)
            return ""

        byteLen := 0
        i := 0
        while (i + 1 < buf.Size)
        {
            b0 := NumGet(buf.Ptr, i, "UChar")
            b1 := NumGet(buf.Ptr, i + 1, "UChar")
            if (b0 = 0 && b1 = 0)
                break
            byteLen := i + 2
            i += 2
        }

        if (byteLen <= 0)
            return ""

        return StrGet(buf.Ptr, byteLen // 2, "UTF-16")
    }

    ; Returns a cached Buffer of the module scan region, re-reading it when stale or forced.
    ; Params: forceRefresh - if true, re-reads module bytes and resets scan region bounds.
    ; Returns: Buffer containing the scanned memory region, or 0 on failure.
    GetModuleSnapshot(forceRefresh := false)
    {
        if (!this.ModuleBase || !this.ModuleSize)
            return 0

        this.GetScanRegion(forceRefresh)
        scanBase := this.ScanBase ? this.ScanBase : this.ModuleBase
        scanSize := this.ScanSize ? this.ScanSize : this.ModuleSize

        if (!forceRefresh && this.ModuleSnapshot &&
            this.ModuleSnapshotBase = scanBase &&
            this.ModuleSnapshotSize = scanSize)
        {
            return this.ModuleSnapshot
        }

        buf := this.ReadModuleChunked(scanBase, scanSize, 8000)
        if !buf
            return 0

        this.ModuleSnapshot := buf
        this.ModuleSnapshotBase := scanBase
        this.ModuleSnapshotSize := scanSize
        return this.ModuleSnapshot
    }

    ; Reads up to totalSize bytes starting at baseAddress in 1 MB chunks, respecting a timeout.
    ; Unreadable chunks are left as zero-filled; partial reads at boundaries are handled gracefully.
    ; Returns: Buffer of totalSize bytes (unread sections remain zeroed).
    ReadModuleChunked(baseAddress, totalSize, timeoutMs := 20000)
    {
        if (!baseAddress || totalSize <= 0)
            return 0

        out := Buffer(totalSize, 0)
        chunkSize := 1024 * 1024
        offset := 0
        deadline := A_TickCount + timeoutMs

        while (offset < totalSize)
        {
            if (A_TickCount > deadline)
                break

            remaining := totalSize - offset
            requestSize := Min(chunkSize, remaining)
            part := this.ReadBytes(baseAddress + offset, requestSize, true)
            if (part && Type(part) = "Buffer" && part.Size > 0)
                DllCall("RtlMoveMemory", "Ptr", out.Ptr + offset, "Ptr", part.Ptr, "UPtr", part.Size)

            offset += requestSize
        }

        return out
    }

    ; Parses the PE header to narrow ScanBase/ScanSize to the .text code section only.
    ; Falls back to the full module range when the MZ/PE header or .text section is not found.
    GetScanRegion(forceRefresh := false)
    {
        if (!this.ModuleBase || !this.ModuleSize)
            return

        if (!forceRefresh && this.ScanBase && this.ScanSize)
            return

        this.ScanBase := this.ModuleBase
        this.ScanSize := this.ModuleSize

        headerSize := Min(this.ModuleSize, 0x8000)
        hdr := this.ReadBytes(this.ModuleBase, headerSize, true)
        if (!hdr || hdr.Size < 0x200)
            return

        ptr := hdr.Ptr
        mz := NumGet(ptr, 0, "UShort")
        if (mz != 0x5A4D)
            return

        peOffset := NumGet(ptr, 0x3C, "UInt")
        if (peOffset <= 0 || peOffset + 0x108 >= hdr.Size)
            return

        peSig := NumGet(ptr, peOffset, "UInt")
        if (peSig != 0x00004550)
            return

        numberOfSections := NumGet(ptr, peOffset + 6, "UShort")
        sizeOfOptionalHeader := NumGet(ptr, peOffset + 20, "UShort")
        sectionTable := peOffset + 24 + sizeOfOptionalHeader
        if (numberOfSections <= 0 || sectionTable <= 0)
            return

        loop numberOfSections
        {
            sectionOffset := sectionTable + (A_Index - 1) * 40
            if (sectionOffset + 40 > hdr.Size)
                break

            name := ""
            loop 8
            {
                ch := NumGet(ptr, sectionOffset + (A_Index - 1), "UChar")
                if (ch = 0)
                    break
                name .= Chr(ch)
            }

            if (name = ".text")
            {
                virtualSize := NumGet(ptr, sectionOffset + 8, "UInt")
                virtualAddress := NumGet(ptr, sectionOffset + 12, "UInt")
                rawSize := NumGet(ptr, sectionOffset + 16, "UInt")
                sectionSize := Max(virtualSize, rawSize)
                if (sectionSize > 0)
                {
                    this.ScanBase := this.ModuleBase + virtualAddress
                    maxSize := this.ModuleSize - virtualAddress
                    if (maxSize > 0)
                        this.ScanSize := Min(sectionSize, maxSize)
                }
                break
            }
        }
    }
}