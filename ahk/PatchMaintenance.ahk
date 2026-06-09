; PatchMaintenance.ahk
; When PatchChecker detects a new PoE2 version, run the post-patch maintenance
; the helper used to only *recommend*: regenerate the data/ files and re-check
; offsets against the upstream C# reference. Progress is streamed live into the
; themed patch modal in the WebView.
;
; Flow (all on a background SetTimer so the WebView stays responsive):
;   1. data    — GgpkToolBridge.RefreshAllTsvs() (GGPK extraction) then the
;                tools/ Python regeneration pipeline (skipped if no Python).
;                If the install path is unknown the user is prompted for it.
;   2. offsets — _OC_RunCompareData() (clone/pull main + diff), summarised in
;                the modal and pushed to the Config → Debug dev panel.
;
; Globals (declared in InGameStateMonitor.ahk):
;   g_patchMaint        — Map("prev","cur") for the active run, or ""
;   g_patchMaintPending — queued request when the WebView wasn't ready yet
;   g_patchMaintBusy    — true while GGPK extraction runs (MaybeAutoRefresh
;                         checks this so it doesn't extract concurrently)

; Entry point — called by CheckPoePatchVersion on a detected version change.
; Defers until the WebView is ready so the progress modal is actually visible.
TriggerPatchMaintenance(prevVer, curVer)
{
    global g_patchMaint, g_patchMaintPending, g_webViewReady
    req := Map("prev", prevVer, "cur", curVer)
    if (IsSet(g_webViewReady) && g_webViewReady)
    {
        g_patchMaint := req
        SetTimer(() => RunPatchMaintenance(), -1)
    }
    else
    {
        g_patchMaintPending := req   ; OnNavigationCompleted starts it
    }
}

; Opens the themed progress modal and kicks off the first stage.
RunPatchMaintenance()
{
    global g_patchMaint
    if !(Type(g_patchMaint) = "Map")
        return
    payload := Map(
        "previous", g_patchMaint["prev"],
        "current", g_patchMaint["cur"],
        "steps", [
            Map("id", "data",    "label", "Regenerate data files (data/)"),
            Map("id", "offsets", "label", "Check offsets vs upstream (main)")
        ])
    try WebViewExec("patchMaintStart(" _JsStr(JsonFull_Stringify(payload, false)) ")")
    PatchMaint_StageData()
}

; Stage 1 — regenerate data/. Prompts for the install path when it's unknown
; (paused; resumed by PatchMaintSetPath), otherwise runs the GGPK extraction
; followed by the optional Python pipeline, then advances to the offset stage.
PatchMaint_StageData()
{
    global g_patchMaint, g_patchMaintBusy
    if !GgpkToolBridge.HasCachedIndexPath()
    {
        _PM_Step("data", "needpath", "PoE2 install path unknown — enter the path to Bundles2\_.index.bin (or Content.ggpk).")
        return
    }

    _PM_Step("data", "running", "Extracting TSVs from the local GGPK…")
    g_patchMaintBusy := true
    res := ""
    try {
        res := GgpkToolBridge.RefreshAllTsvs()
    } catch as ex {
        res := Map("ok", false, "msg", ex.Message)
    }
    g_patchMaintBusy := false

    ggpkOk := (Type(res) = "Map" && res["ok"])
    cur := (Type(g_patchMaint) = "Map") ? g_patchMaint["cur"] : ""
    if (ggpkOk)
    {
        ; Dedup with the silent MaybeAutoRefresh — record the version we just
        ; refreshed at so it skips its own pass.
        try IniWrite(cur, _ConfigPath(), "GgpkTools", "lastRefreshedAtPatch")
        _PM_Step("data", "running", "GGPK: " res["msg"])
    }
    else
        _PM_Step("data", "running", "GGPK refresh failed: " ((Type(res) = "Map") ? res["msg"] : "unknown"))

    ; Dump the poe_data_tools CSVs (feeds build_item_names_csv.py → skill /
    ; unique-IVI name maps). Best-effort: a failure just leaves those two maps
    ; at their committed (possibly stale) values instead of breaking.
    _PM_RunDumpTables()

    pyRes := _PM_RunPythonPipeline()
    pyOk := (Type(pyRes) = "Map" && pyRes["ok"])

    if (ggpkOk || pyOk)
        _PM_Step("data", "ok", "Data regeneration finished.")
    else
        _PM_Step("data", "fail", "Data regeneration did not complete — see status above / error log.")

    SetTimer(() => PatchMaint_StageOffsets(), -1)
}

; Runs the tools/ Python regeneration scripts in order. Returns
; Map("ran", bool, "ok", bool); skips gracefully when no Python is installed.
_PM_RunPythonPipeline()
{
    py := _PM_FindPython()
    if (py = "")
    {
        _PM_Step("data", "running", "Python not found — skipping script regeneration.")
        return Map("ran", false, "ok", false)
    }
    toolsDir := A_ScriptDir "\tools"
    ; build_item_names_csv.py runs LAST: it supersedes build_item_names.py and
    ; additionally emits skill_name_map.tsv + unique_ivi_name_map.tsv (skill /
    ; unique-by-IVI names). It needs the poe_data_tools CSVs from the dump_tables
    ; step (_PM_RunDumpTables, run just before this); if those are missing it
    ; exits cleanly and the older scripts' output stands.
    scripts := ["extract_stats_dat.py", "build_stat_desc_map.py", "build_item_names.py", "extract_monster_names.py", "build_item_names_csv.py"]
    okCount := 0
    ranCount := 0
    for i, s in scripts
    {
        if !FileExist(toolsDir "\" s)
            continue
        ranCount += 1
        _PM_Step("data", "running", "Python: " s " (" i "/" scripts.Length ")…")
        stderrF := A_Temp "\poe-pyregen.stderr.txt"
        try FileDelete(stderrF)
        exit := 1
        try {
            exit := RunWait(A_ComSpec ' /c ' py ' "' s '" 2> "' stderrF '"', toolsDir, "Hide")
        } catch as ex {
            exit := -1
        }
        if (exit = 0)
            okCount += 1
        else
        {
            tail := ""
            try tail := Trim(FileRead(stderrF, "UTF-8"), " `r`n`t")
            try LogError("PatchMaint python " s " exit " exit (tail = "" ? "" : ": " tail))
        }
        try FileDelete(stderrF)
    }
    if (ranCount > 0)
        _PM_Step("data", "running", "Python regeneration: " okCount "/" ranCount " script(s) ok.")
    return Map("ran", ranCount > 0, "ok", okCount > 0)
}

; Dumps the .datc64 tables to CSV via tools/dump_tables.bat (poe_data_tools.exe),
; which build_item_names_csv.py then reads to build skill_name_map.tsv +
; unique_ivi_name_map.tsv. Best-effort: skips when the tool/bat is missing, and
; passes the Steam library root derived from the cached GGPK index path when it
; can (else lets the bat auto-detect). Returns Map("ran", bool, "ok", bool).
_PM_RunDumpTables()
{
    toolsDir := A_ScriptDir "\tools"
    batPath  := toolsDir "\dump_tables.bat"
    pdtPath  := toolsDir "\poe_data_tools.exe"
    if !(FileExist(batPath) && FileExist(pdtPath))
    {
        _PM_Step("data", "running", "dump_tables.bat / poe_data_tools.exe missing — skipping CSV dump (skill / unique-IVI maps keep their committed values).")
        return Map("ran", false, "ok", false)
    }

    ; Derive the Steam library root from <root>\steamapps\common\…\_.index.bin.
    steamArg := ""
    idx := IniRead(_ConfigPath(), "GgpkTools", "lastIndexPath", "")
    p := InStr(idx, "\steamapps\")
    if (p > 0)
        steamArg := ' "' SubStr(idx, 1, p - 1) '"'

    _PM_Step("data", "running", "Dumping .datc64 tables (poe_data_tools)…")
    stderrF := A_Temp "\poe-dumptables.stderr.txt"
    try FileDelete(stderrF)
    exit := 1
    try {
        exit := RunWait(A_ComSpec ' /c "' batPath '"' steamArg ' 2> "' stderrF '"', toolsDir, "Hide")
    } catch as ex {
        exit := -1
    }
    ok := (exit = 0)
    if !ok
    {
        tail := ""
        try tail := Trim(FileRead(stderrF, "UTF-8"), " `r`n`t")
        try LogError("PatchMaint dump_tables exit " exit (tail = "" ? "" : ": " tail))
        _PM_Step("data", "running", "CSV dump failed (exit " exit ") — skill / unique-IVI maps keep their committed values.")
    }
    try FileDelete(stderrF)
    return Map("ran", true, "ok", ok)
}

; Returns a working Python launcher prefix ("py -3" / "python" / "python3") or
; "" if none responds to --version.
_PM_FindPython()
{
    for i, cand in ["py -3", "python", "python3"]
    {
        out := _OC_RunCapture(cand " --version")
        if (out != "" && InStr(out, "Python"))
            return cand
    }
    return ""
}

; Stage 2 — clone/pull main, diff offsets, summarise in the modal and push
; the full result to the Config → Debug → Offset Comparison dev panel.
PatchMaint_StageOffsets()
{
    _PM_Step("offsets", "running", "Fetching upstream (main) & diffing offsets…")
    res := ""
    try {
        res := _OC_RunCompareData()
    } catch as ex {
        res := Map("ok", false, "msg", ex.Message)
    }
    if (Type(res) = "Map" && res.Has("ok") && res["ok"])
    {
        try _OC_PushRun(res)   ; also populate the dev panel
        od := (res.Has("offsetDiffs")  && Type(res["offsetDiffs"])  = "Array") ? res["offsetDiffs"].Length  : 0
        pd := (res.Has("patternDiffs") && Type(res["patternDiffs"]) = "Array") ? res["patternDiffs"].Length : 0
        msg := od " offset diff(s), " pd " pattern diff(s). See Config → Debug → Offset Comparison."
        _PM_Step("offsets", (od = 0 && pd = 0) ? "ok" : "warn", msg)
    }
    else
        _PM_Step("offsets", "fail", "Offset check failed: " ((Type(res) = "Map" && res.Has("msg")) ? res["msg"] : "unknown"))

    _PM_Done("Maintenance complete.")
}

; Bridge: user submitted an install path in the modal prompt. Validate, persist
; and resume the data stage. Called from BridgeDispatch (PatchMaintSetPath).
PatchMaintSetPath(rawPath)
{
    path := Trim(rawPath, ' "`t')
    if (path = "" || !FileExist(path) || !RegExMatch(path, "i)\.(index\.bin|ggpk)$"))
    {
        _PM_Step("data", "needpath", "Invalid path — point us at Bundles2\_.index.bin or Content.ggpk.")
        return
    }
    try IniWrite(path, _ConfigPath(), "GgpkTools", "lastIndexPath")
    _PM_Step("data", "running", "Path saved — regenerating…")
    SetTimer(() => PatchMaint_StageData(), -1)
}

; Bridge: user chose to skip the data step (e.g. can't supply the path now).
; Jump straight to the offset stage. Called from BridgeDispatch.
PatchMaintSkipData()
{
    _PM_Step("data", "skip", "Skipped — data files not regenerated.")
    SetTimer(() => PatchMaint_StageOffsets(), -1)
}

; Pushes a single step's live state to the modal.
; state ∈ pending|running|ok|warn|fail|skip|needpath.
_PM_Step(id, state, msg)
{
    p := Map("id", id, "state", state, "msg", msg)
    try WebViewExec("patchMaintStep(" _JsStr(JsonFull_Stringify(p, false)) ")")
}

; Signals the modal that the whole run finished.
_PM_Done(msg)
{
    try WebViewExec("patchMaintDone(" _JsStr(JsonFull_Stringify(Map("msg", msg), false)) ")")
}
