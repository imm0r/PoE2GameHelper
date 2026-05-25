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
        if (exe.path = "")
            return this._Fail("poe-data-extract.exe not found. Build it once via:`n"
                . "    cd ggpk-tools && dotnet publish PoeDataExtract -c Release -r win-x64 --self-contained -p:PublishAot=true")

        outPath := A_ScriptDir "\data\base_item_sizes.tsv"
        tmpPath := outPath ".tmp-ggpk"
        stderr  := A_Temp "\poe-data-extract.stderr.txt"

        try FileDelete(tmpPath)
        try FileDelete(stderr)

        cmd := exe.invoke
            . ' extract --ggpk "' indexPath '" --table BaseItemTypes --output "' tmpPath '"'

        ; RunWait blocks the GUI; the extract typically completes in
        ; under a second on a warm cache. The UI button shows a
        ; "Refreshing..." status before calling so the user has a hint
        ; this is intentional.
        try
        {
            ; "Hide" keeps the console window from flashing.
            exit := RunWait(A_ComSpec ' /c ' cmd ' 2> "' stderr '"', exe.workDir, "Hide")
        }
        catch as ex
        {
            return this._Fail("RunWait failed: " ex.Message)
        }

        if (exit != 0)
        {
            tail := this._ReadTail(stderr, 6)
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
            result := this.RefreshItemSizes()
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
