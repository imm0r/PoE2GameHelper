; GgpkToolBridge.ahk
; Thin AHK wrapper around the standalone ggpk-tools CLI executables
; (PoeDataExtract / PoePatcher, both .NET 8 / AGPL-3.0, living in
; ggpk-tools/). All comms go via process args + filesystem — the AHK
; host never links any binary from ggpk-tools/, which keeps the AGPL
; scope contained inside that directory and lets the rest of the
; PoE2GameHelper stay MIT.
;
; Workflow:
;   - Locate the running PoE2 process to derive its install path
;     (and from there Bundles2\_.index.bin). Falls back to PoE1 paths
;     for legacy Content.ggpk installs that some users still have.
;   - Locate the published exe for whichever tool we need. Prefers
;     the AOT single-file publish output if present, falls back to
;     the framework-dependent `dotnet run` form during development.
;   - Shell out via RunWait, capturing exit code + a tail of stderr
;     for the diagnostic line the UI surfaces back to the user.
;
; The bridge is deliberately fire-and-forget per call — no shared
; state, no caching. The user pays the cost of a fresh .NET startup
; on each invocation (~200-500 ms for AOT, ~1-2 s for `dotnet run`),
; which is fine since these are user-initiated buttons, not hot paths.

class GgpkToolBridge
{
    ; ---- public surface ----

    ; Re-extract ALL TSVs the helper consumes in one shell-out:
    ;   base_item_sizes.tsv, base_item_name_map.tsv, monster_name_map.tsv,
    ;   stat_name_map.tsv, mod_name_map.tsv.
    ; Saves ~300 ms × 5 .NET-startup cost vs invoking the tool per-table.
    ; Returns Map("ok", bool, "msg", string, "rows", int).
    static RefreshAllTsvs()
    {
        indexPath := this._ResolveGameDataPath()
        if (indexPath = "")
            return this._Fail("PoE2 not running — start the game once so we can locate the install path.")

        exe := this._FindExe("PoeDataExtract")
        if (exe["path"] = "")
            return this._Fail("poe-data-extract.exe not found. Build it once via:`n"
                . "    cd ggpk-tools && dotnet publish PoeDataExtract -c Release -r win-x64 --self-contained -p:PublishAot=true")

        outDir := A_ScriptDir "\data"
        stderr := A_Temp "\poe-data-extract.stderr.txt"
        try FileDelete(stderr)

        cmd := exe["invoke"] . ' extract-all --ggpk "' indexPath '" --output-dir "' outDir '"'
        fullCmd := A_ComSpec ' /c "' cmd ' 2> "' stderr '""'

        try LogError("GgpkTools/RefreshAll cmd: " fullCmd)

        exit := 0
        try
        {
            exit := RunWait(fullCmd, exe["workDir"], "Hide")
        }
        catch as ex
        {
            return this._Fail("RunWait failed: " ex.Message)
        }

        tail := this._ReadTail(stderr, 8)
        if (exit != 0)
        {
            try LogError("GgpkTools/RefreshAll exited " exit (tail = "" ? "" : " stderr=" tail))
            return this._Fail("poe-data-extract extract-all exited with code " exit (tail = "" ? "" : ":`n" tail))
        }

        ; Reload the in-memory ItemSize registry so the next AutoPilot
        ; tick uses fresh data. Other TSVs (mods/stats/monsters) are
        ; lazily reloaded by their consumers via file-mtime caching, so
        ; no explicit reload needed there.
        rows := 0
        try
        {
            ItemSizeRegistry.Loaded := false
            ItemSizeRegistry.Sizes := Map()
            ItemSizeRegistry.Load()
            rows := ItemSizeRegistry.LoadStats["entries"]
        }

        ; Persist the path under [GgpkTools] lastIndexPath so the GGPK
        ; maphack apply/revert (which run while the game is CLOSED, so
        ; _ResolveGameDataPath would return nothing) can find the index.
        try IniWrite(indexPath, _ConfigPath(), "GgpkTools", "lastIndexPath")

        return Map("ok", true, "msg", "Refreshed all TSVs (item sizes: " rows " entries).", "rows", rows)
    }

    ; Re-extract data/base_item_sizes.tsv from the user's local PoE2
    ; install. Returns Map("ok", bool, "msg", string, "rows", int).
    ; On success the new TSV replaces data/base_item_sizes.tsv in
    ; place and ItemSizeRegistry is reloaded.
    static RefreshItemSizes()
    {
        indexPath := this._ResolveGameDataPath()
        if (indexPath = "")
            return this._Fail("PoE2 not running — start the game once so we can locate the install path.")

        exe := this._FindExe("PoeDataExtract")
        ; AHK v2 Maps are indexed with [], NOT . — dot access throws
        ; "no property named X" at runtime. Burned by this twice.
        if (exe["path"] = "")
            return this._Fail("poe-data-extract.exe not found. Build it once via:`n"
                . "    cd ggpk-tools && dotnet publish PoeDataExtract -c Release -r win-x64 --self-contained -p:PublishAot=true")

        outPath := A_ScriptDir "\data\base_item_sizes.tsv"
        tmpPath := outPath ".tmp-ggpk"
        stderr  := A_Temp "\poe-data-extract.stderr.txt"

        try FileDelete(tmpPath)
        try FileDelete(stderr)

        cmd := exe["invoke"]
            . ' extract --ggpk "' indexPath '" --table BaseItemTypes --output "' tmpPath '"'

        ; Wrap the whole thing in outer quotes so cmd.exe's /c parser
        ; treats it as a single command — without this, the multiple
        ; quoted args inside cmd get mis-parsed when the first character
        ; after /c is a quote (the infamous "first quote stripped" rule).
        fullCmd := A_ComSpec ' /c "' cmd ' 2> "' stderr '""'

        ; Log the exact command we're about to run so we can debug
        ; quoting / arg-splitting issues from the error log.
        try LogError("GgpkTools/Refresh cmd: " fullCmd)

        ; RunWait blocks the GUI; the extract typically completes in
        ; under a second on a warm cache. The UI button shows a
        ; "Refreshing..." status before calling so the user has a hint
        ; this is intentional.
        exit := 0
        try
        {
            ; "Hide" keeps the console window from flashing.
            exit := RunWait(fullCmd, exe["workDir"], "Hide")
        }
        catch as ex
        {
            return this._Fail("RunWait failed: " ex.Message)
        }

        if (exit != 0)
        {
            tail := this._ReadTail(stderr, 6)
            try LogError("GgpkTools/Refresh exited " exit (tail = "" ? "" : " stderr=" tail))
            return this._Fail("poe-data-extract exited with code " exit (tail = "" ? "" : ":`n" tail))
        }

        if (!FileExist(tmpPath))
            return this._Fail("poe-data-extract reported success but produced no output file.")

        ; Replace the old TSV atomically.
        try FileDelete(outPath)
        try FileMove(tmpPath, outPath)
        catch as ex
            return this._Fail("Couldn't replace " outPath ": " ex.Message)

        ; Reload the in-memory registry so the next AutoPilot tick uses
        ; the fresh data without needing a script restart.
        rows := 0
        try
        {
            ItemSizeRegistry.Loaded := false
            ItemSizeRegistry.Sizes := Map()
            ItemSizeRegistry.Load()
            rows := ItemSizeRegistry.LoadStats["entries"]
        }
        catch as ex
        {
            ; TSV is on disk, just the in-memory reload tripped — log
            ; but call it a success so the user sees the file is there.
            try LogError("GgpkToolBridge/reload", ex)
        }

        return Map("ok", true, "msg", "Refreshed " rows " entries from local PoE2 install.", "rows", rows)
    }

        ; Decide whether base_item_sizes.tsv needs refreshing and trigger
    ; it on a background timer if so. Called once at startup; safe to
    ; invoke before PoE2 is running (skips silently in that case and
    ; reschedules itself with a back-off).
    ;
    ; Refresh is triggered when ANY of:
    ;   - the TSV is missing or implausibly small (<100 bytes)
    ;   - the game's patch version (PatchChecker / GetLastKnownPoeVersion)
    ;     differs from the version recorded the last time we refreshed
    ;     (stored under [GgpkTools] lastRefreshedAtPatch).
    ;
    ; The version string comes from the existing PatchChecker (queries
    ; patch.pathofexile2.com on startup), which is already the canonical
    ; "what version is the user on" source — we just piggyback off it
    ; instead of fingerprinting _.index.bin's mtime.
    static MaybeAutoRefresh(retryAttempt := 0)
    {
        try
        {
            tsvPath        := A_ScriptDir "\data\base_item_sizes.tsv"
            tsvOk          := FileExist(tsvPath) && FileGetSize(tsvPath) >= 100
            iniFile        := _ConfigPath()
            lastRefreshVer := IniRead(iniFile, "GgpkTools", "lastRefreshedAtPatch", "")
            currentVer     := GetLastKnownPoeVersion()

            ; If PatchChecker hasn't populated the version yet, wait —
            ; CheckPoePatchVersion runs on startup but the TCP probe
            ; can take a few seconds. Don't trigger a refresh until we
            ; know whether the version changed.
            if (currentVer = "")
            {
                if (retryAttempt < 5)
                    SetTimer(() => GgpkToolBridge.MaybeAutoRefresh(retryAttempt + 1), -10000)
                return
            }

            ; Need PoE2 running so we have an install path to read from.
            indexPath := this._ResolveGameDataPath()
            if (indexPath = "")
            {
                if (retryAttempt < 3)
                    SetTimer(() => GgpkToolBridge.MaybeAutoRefresh(retryAttempt + 1), -30000)
                else
                    try LogError("GgpkTools: auto-refresh skipped — PoE not running after 3 retries")
                return
            }

            reason := ""
            if (!tsvOk)
                reason := "TSV missing/empty"
            else if (lastRefreshVer = "")
            {
                ; First time we're tracking refreshes on this install,
                ; but a TSV is already present (shipped or pre-existing
                ; repoe-fork dump). Don't force a refresh — record the
                ; current version as our baseline so future patches
                ; trigger correctly.
                IniWrite(currentVer, iniFile, "GgpkTools", "lastRefreshedAtPatch")
                return
            }
            else if (currentVer != lastRefreshVer)
                reason := "game patched: " lastRefreshVer " → " currentVer

            if (reason = "")
                return

            try LogError("GgpkTools: auto-refresh triggered (" reason ")")
            ; Refresh all the TSVs the helper consumes, not just item
            ; sizes — keeps the whole data pack in sync with patches.
            result := this.RefreshAllTsvs()
            if (result["ok"])
            {
                IniWrite(currentVer, iniFile, "GgpkTools", "lastRefreshedAtPatch")
                ; Surface the result to the UI if it's listening — the
                ; same envelope the manual button uses.
                msgJson := '{"ok":true,"msg":"Auto-refresh: ' result["rows"] ' entries (' reason ').","rows":' result["rows"] '}'
                try WebViewExec("updateGgpkToolStatus(" _JsStr(msgJson) ")")
            }
            else
            {
                try LogError("GgpkTools: auto-refresh failed: " result["msg"])
            }
        }
        catch as ex
        {
            try LogError("GgpkTools/MaybeAutoRefresh", ex)
        }
    }

    ; ────────────────────────────────────────────────────────────────
    ; Minimap maphack — patch / revert PoE2's two minimap shader files
    ; in place. Both operations require the game to be CLOSED (the
    ; bundle files are open + cached by PoE2 while it runs, so any
    ; write would be silently discarded or worse).
    ;
    ; Both functions return Map("ok", bool, "msg", string).
    ; ────────────────────────────────────────────────────────────────

    static ApplyMinimapPatch()
    {
        return this._RunPatchVerb("apply")
    }

    static RevertMinimapPatch()
    {
        return this._RunPatchVerb("revert")
    }

    ; Returns true when we have a cached install path AND the file
    ; still exists on disk. The Apply/Revert UI hides itself when this
    ; is false. Three paths populate the cache:
    ;   1) RefreshAllTsvs after a TSV refresh against a running game
    ;   2) EnsureConnected the moment the helper attaches
    ;   3) HasCachedIndexPath itself — falls back to a Steam registry
    ;      lookup so the workflow can succeed even on a fresh install
    ;      where PoE2 has never been running while the helper was up.
    static HasCachedIndexPath()
    {
        indexPath := IniRead(_ConfigPath(), "GgpkTools", "lastIndexPath", "")
        if (indexPath != "" && FileExist(indexPath))
            return true
        ; Cache miss — try to derive it from Steam's own bookkeeping.
        autoPath := this._FindIndexPathFromSteam()
        if (autoPath != "")
        {
            try IniWrite(autoPath, _ConfigPath(), "GgpkTools", "lastIndexPath")
            return true
        }
        return false
    }

    ; Steam-based PoE2 install discovery (no running process required).
    ; Chain:
    ;   1) Find Steam itself via HKLM\Software\WOW6432Node\Valve\Steam.
    ;   2) Parse <steam>\steamapps\libraryfolders.vdf to enumerate every
    ;      library folder (Steam may have several across drives).
    ;   3) In each library, look for appmanifest_2694490.acf (PoE2's
    ;      Steam app id) and read the "installdir" key. The game folder
    ;      isn't always literally "Path of Exile 2" — users sometimes
    ;      rename it, so we always defer to the manifest.
    ;   4) Build <library>\steamapps\common\<installdir>\Bundles2\_.index.bin
    ;      and verify it exists.
    ; Returns the path on hit, "" on any miss.
    static _FindIndexPathFromSteam()
    {
        static APP_ID := "2694490"
        try
        {
            steamRoot := RegRead("HKLM\SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath", "")
            if (steamRoot = "")
                steamRoot := RegRead("HKLM\SOFTWARE\Valve\Steam", "InstallPath", "")
            if (steamRoot = "" || !DirExist(steamRoot))
                return ""

            vdf := steamRoot "\steamapps\libraryfolders.vdf"
            if (!FileExist(vdf))
                return ""

            libraries := this._ParseSteamLibraryPaths(vdf)
            ; Always include the default library — older Steam VDFs
            ; sometimes omit the install root itself.
            if (steamRoot != "" && !this._ListContains(libraries, steamRoot))
                libraries.Push(steamRoot)

            for _, lib in libraries
            {
                manifest := lib "\steamapps\appmanifest_" APP_ID ".acf"
                if (!FileExist(manifest))
                    continue
                installDir := this._ParseAcfKey(manifest, "installdir")
                if (installDir = "")
                    continue
                cand := lib "\steamapps\common\" installDir "\Bundles2\_.index.bin"
                if (FileExist(cand))
                    return cand
                ; PoE2 beta builds had a Content.ggpk alongside the
                ; bundle index; check that as a fallback so legacy
                ; installs aren't left out.
                cand := lib "\steamapps\common\" installDir "\Content.ggpk"
                if (FileExist(cand))
                    return cand
            }
        }
        catch as ex
        {
            try LogError("GgpkTools/_FindIndexPathFromSteam", ex)
        }
        return ""
    }

    ; libraryfolders.vdf is Valve's KeyValues text format. We just need
    ; the `"path"  "<dir>"` entries — there's at most one per library
    ; and they live at the top level under each numeric index. A naive
    ; regex over the whole file is enough for that.
    static _ParseSteamLibraryPaths(vdfFile)
    {
        out := []
        try
        {
            content := FileRead(vdfFile, "UTF-8")
            ; Steam stores Windows paths with doubled backslashes inside
            ; the VDF ("C:\\Program Files (x86)\\Steam"). Unescape here
            ; so the path we hand to FileExist actually works.
            pos := 1
            while (pos := RegExMatch(content, 'i)"path"\s+"((?:[^"\\]|\\.)*)"', &m, pos))
            {
                raw := m[1]
                raw := StrReplace(raw, "\\", "\")
                raw := StrReplace(raw, '\"', '"')
                if (raw != "")
                    out.Push(raw)
                pos += m.Len
            }
        }
        catch
        {
            ; Malformed VDF or unreadable file — just return whatever we
            ; collected so far (likely empty). Callers handle the
            ; no-libraries case fine.
        }
        return out
    }

    ; Pulls a single string value out of an ACF manifest. Same
    ; KeyValues format as VDF but the keys we care about (installdir,
    ; name, etc.) sit inside the top-level "AppState" block, so a
    ; flat regex match is good enough.
    static _ParseAcfKey(acfFile, keyName)
    {
        try
        {
            content := FileRead(acfFile, "UTF-8")
            pattern := 'i)"' keyName '"\s+"((?:[^"\\]|\\.)*)"'
            if (RegExMatch(content, pattern, &m))
            {
                val := m[1]
                val := StrReplace(val, "\\", "\")
                val := StrReplace(val, '\"', '"')
                return val
            }
        }
        return ""
    }

    static _ListContains(list, needle)
    {
        for _, v in list
            if (v = needle)
                return true
        return false
    }

    ; Returns true when PoePatcher's backup directory for the minimap
    ; patch exists and contains the snapshot file we drop on apply.
    ;
    ; BackupManager.Save creates `<ggpkdir>/backups/<patch>/...` on
    ; apply; PoePatcher.Program.SnapshotIndexFile drops
    ; `_index_snapshot.bin` next to the per-file backups (first apply
    ; only). On revert, BackupManager.Clear() recursively deletes the
    ; whole directory, so its presence is a reliable "currently
    ; applied" signal — independent of whether the game is running.
    static IsMaphackApplied()
    {
        indexPath := IniRead(_ConfigPath(), "GgpkTools", "lastIndexPath", "")
        if (indexPath = "" || !FileExist(indexPath))
            return false
        SplitPath(indexPath, , &dir)
        backupDir := dir "\backups\minimap"
        return DirExist(backupDir) ? true : false
    }

    static _RunPatchVerb(verb)
    {
        ; Hard pre-flight: refuse if PoE2 is running. The UI also
        ; disables the buttons but this is defense in depth.
        if (ProcessExist("PathOfExileSteam.exe")
            || ProcessExist("PathOfExile_x64Steam.exe")
            || ProcessExist("PathOfExile.exe")
            || ProcessExist("PathOfExile_x64.exe"))
        {
            return this._Fail("PoE2 is still running — close the game first.")
        }

        ; We can't use _ResolveGameDataPath() (it walks the running
        ; process). Instead, look up the install path in the INI from
        ; the last successful auto-refresh — we cache it there for
        ; exactly this situation.
        iniFile := _ConfigPath()
        indexPath := IniRead(iniFile, "GgpkTools", "lastIndexPath", "")
        if (indexPath = "" || !FileExist(indexPath))
            return this._Fail("PoE2 install path not known yet. Start the game once so the helper can record it (Bundles2/_.index.bin path is persisted under [GgpkTools] lastIndexPath).")

        exe := this._FindExe("PoePatcher")
        if (exe["path"] = "")
            return this._Fail("poe-patcher.exe not found. Build it once via:`n"
                . "    cd ggpk-tools && dotnet publish PoePatcher -c Release -r win-x64 --self-contained -p:PublishAot=true")

        stderr := A_Temp "\poe-patcher.stderr.txt"
        try FileDelete(stderr)

        cmd := exe["invoke"] . ' ' verb ' --ggpk "' indexPath '" --patch minimap'
        fullCmd := A_ComSpec ' /c "' cmd ' 2> "' stderr '""'

        try LogError("GgpkTools/" verb " cmd: " fullCmd)

        exit := 0
        try
        {
            exit := RunWait(fullCmd, exe["workDir"], "Hide")
        }
        catch as ex
        {
            return this._Fail("RunWait failed: " ex.Message)
        }

        tail := this._ReadTail(stderr, 6)
        if (exit != 0)
        {
            try LogError("GgpkTools/" verb " exited " exit (tail = "" ? "" : " stderr=" tail))
            return this._Fail("poe-patcher " verb " exited with code " exit (tail = "" ? "" : ":`n" tail))
        }

        return Map("ok", true, "msg", (verb = "apply"
            ? "Minimap patch applied. Start PoE2 to see the full minimap."
            : "Minimap patch reverted. Vanilla shaders restored."), "rows", 0)
    }

    ; ---- internals ----

    ; Walk all running processes and locate either PathOfExile2 (Steam
    ; or standalone) or legacy PathOfExile (PoE1, for users who only
    ; have that installed). Return the path to the Bundles2 index
    ; (PoE2) or Content.ggpk (PoE1).
    static _ResolveGameDataPath()
    {
        exeNames := ["PathOfExileSteam.exe", "PathOfExile_x64Steam.exe", "PathOfExile.exe", "PathOfExile_x64.exe"]
        for _, name in exeNames
        {
            hwnd := WinExist("ahk_exe " name)
            if (!hwnd)
                continue
            try
            {
                pid := WinGetPID("ahk_exe " name)
                exePath := ProcessGetPath(pid)
                if (exePath = "")
                    continue
                installDir := this._DirName(exePath)
                idx := installDir "\Bundles2\_.index.bin"
                if FileExist(idx)
                    return idx
                ggpk := installDir "\Content.ggpk"
                if FileExist(ggpk)
                    return ggpk
            }
            catch
            {
                continue
            }
        }
        return ""
    }

    ; Find the executable for the given tool. Search order:
    ;   1) ggpk-tools/<Tool>/bin/Release/net8.0/win-x64/publish/<tool>.exe (AOT publish)
    ;   2) ggpk-tools/<Tool>/bin/Release/net8.0/win-x64/<tool>.exe        (RID build)
    ;   3) ggpk-tools/<Tool>/bin/Release/net8.0/<tool>.dll  + dotnet run  (dev fallback)
    ; Returns Map("path", exe-or-dll-path, "invoke", quoted command prefix, "workDir", working dir).
    static _FindExe(toolDirName)
    {
        toolFile := this._ToolFileName(toolDirName)
        root := A_ScriptDir "\ggpk-tools\" toolDirName
        candidates := [
            root "\bin\Release\net8.0\win-x64\publish\" toolFile ".exe",
            root "\bin\Release\net8.0\win-x64\" toolFile ".exe",
            root "\bin\Release\net8.0\" toolFile ".dll"
        ]
        for _, p in candidates
        {
            if !FileExist(p)
                continue
            if (SubStr(p, -3) = ".dll")
                return Map("path", p, "invoke", 'dotnet "' p '"', "workDir", root)
            return Map("path", p, "invoke", '"' p '"', "workDir", this._DirName(p))
        }
        return Map("path", "", "invoke", "", "workDir", "")
    }

    ; PoeDataExtract → poe-data-extract, PoePatcher → poe-patcher.
    ; This mirrors the <AssemblyName> values in the .csproj files.
    static _ToolFileName(toolDirName)
    {
        if (toolDirName = "PoeDataExtract")
            return "poe-data-extract"
        if (toolDirName = "PoePatcher")
            return "poe-patcher"
        return toolDirName
    }

    static _DirName(path)
    {
        SplitPath(path, , &dir)
        return dir
    }

    ; Read up to maxLines from the end of a file. Used to surface the
    ; tool's stderr back to the UI without dumping multi-KB blobs.
    static _ReadTail(path, maxLines)
    {
        if !FileExist(path)
            return ""
        try
        {
            content := FileRead(path, "UTF-8")
            content := RTrim(content, "`r`n")
            lines := StrSplit(content, "`n")
            start := Max(1, lines.Length - maxLines + 1)
            out := ""
            loop lines.Length - start + 1
                out .= (out = "" ? "" : "`n") RTrim(lines[start + A_Index - 1], "`r")
            return out
        }
        catch
        {
            return ""
        }
    }

    static _Fail(msg)
    {
        return Map("ok", false, "msg", msg, "rows", 0)
    }
}
