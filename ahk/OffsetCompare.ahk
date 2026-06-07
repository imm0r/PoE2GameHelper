; OffsetCompare.ahk
; Native AHK2 port of tools/compare_offsets.py.
;
; Compares the offset tables in ahk/PoE2Offsets.ahk and the byte patterns in
; ahk/StaticOffsetsPatterns.ahk against the current C# reference
; (https://github.com/Gordin/GameHelper2, branch main) and keeps a versioned
; change history (offset_history.json) with fix/game_update classification plus
; a delta-pattern prediction. Results are surfaced in the WebView dev panel.
;
; The patch version is obtained live via _PatchChecker_FetchVersion()
; (ahk/PatchChecker.ahk), falling back to the INI and then "unknown".

; ── Configuration ───────────────────────────────────────────────────────────
; All paths are relative to the app root (A_ScriptDir == repo root).
_OC_GitUrl()      => "https://github.com/Gordin/GameHelper2.git"
_OC_GitBranch()   => "main"
_OC_CsRel()       => "GameOffsets"                       ; path inside the repo
_OC_AhkOffsets()  => A_ScriptDir "\ahk\PoE2Offsets.ahk"
_OC_AhkPatterns() => A_ScriptDir "\ahk\StaticOffsetsPatterns.ahk"
_OC_HistoryFile() => A_ScriptDir "\offset_history.json"
_OC_CacheDir()    => A_ScriptDir "\.upstream_cache"

; ── Small helpers ─────────────────────────────────────────────────────────────

; Returns a fresh case-sensitive Map so field/struct keys behave like Python dicts.
_OC_Map()
{
    m := Map()
    m.CaseSense := "On"
    return m
}

; Normalises a hex/decimal offset string to 0xHHH (uppercase, minimal digits),
; mirroring norm_hex() in the Python tool. Returns the input unchanged if it
; isn't a recognisable number.
_OC_NormHex(val)
{
    v := Trim(val)
    low := StrLower(v)
    if (SubStr(low, 1, 2) = "0x")
    {
        stripped := LTrim(SubStr(low, 3), "0")
        if (stripped = "")
            stripped := "0"
        return "0x" StrUpper(stripped)
    }
    if RegExMatch(v, "^-?\d+$")
        return "0x" Format("{:X}", Integer(v))
    return val
}

; Strips the common C#-struct suffixes (Offsets/Offset/Data/Struct) so AHK map
; names and C# struct names can be matched. Mirrors norm_struct().
_OC_NormStruct(name)
{
    for i, suf in ["Offsets", "Offset", "Data", "Struct"]
    {
        if (StrLen(name) > StrLen(suf) && SubStr(name, -StrLen(suf)) == suf)
            return SubStr(name, 1, StrLen(name) - StrLen(suf))
    }
    return name
}

; Normalises a git URL for comparison (drops a trailing slash and ".git").
_OC_NormUrl(u)
{
    u := RTrim(Trim(u), "/")
    if (SubStr(u, -4) = ".git")
        u := SubStr(u, 1, StrLen(u) - 4)
    return u
}

; Runs a command via cmd.exe and returns its trimmed combined output (stdout +
; stderr). Used for the few git queries that need their text captured.
_OC_RunCapture(cmd)
{
    tmp := A_Temp "\oc_git_" A_TickCount "_" Random(1000, 9999) ".txt"
    try FileDelete(tmp)
    RunWait(A_ComSpec ' /c ' cmd ' >"' tmp '" 2>&1', , "Hide")
    out := ""
    if FileExist(tmp)
    {
        try out := FileRead(tmp, "UTF-8")
        try FileDelete(tmp)
    }
    return Trim(out, " `r`n`t")
}

; Returns the live PoE2 patch version via the native Winsock probe, falling
; back to the stored INI value and finally "unknown".
_OC_GameVersion()
{
    v := ""
    try v := _PatchChecker_FetchVersion()
    if (v = "")
    {
        try v := GetLastKnownPoeVersion()
    }
    return (v = "") ? "unknown" : v
}

; Returns the short commit hash of the cached upstream clone, or "unknown".
_OC_UpstreamCommit()
{
    out := _OC_RunCapture('git -C "' _OC_CacheDir() '" rev-parse --short HEAD')
    if (out = "" || InStr(out, "fatal") || InStr(out, "not a git"))
        return "unknown"
    return StrSplit(out, "`n")[1]
}

; ── Upstream fetch (git clone/pull of the main branch into the cache) ─────────

; True if the cached clone already points at the configured URL + branch.
_OC_CacheMatches()
{
    cache := _OC_CacheDir()
    url := _OC_RunCapture('git -C "' cache '" remote get-url origin')
    branch := _OC_RunCapture('git -C "' cache '" rev-parse --abbrev-ref HEAD')
    url := StrSplit(url, "`n")[1]
    branch := StrSplit(branch, "`n")[1]
    return (_OC_NormUrl(url) = _OC_NormUrl(_OC_GitUrl())) && (branch = _OC_GitBranch())
}

; Clones or pulls the main branch into the cache. Discards a cache that
; points at a different repo/branch first. Returns Map("ok", bool, "msg", str).
_OC_FetchUpstream()
{
    cache := _OC_CacheDir()
    url := _OC_GitUrl()
    branch := _OC_GitBranch()

    if (DirExist(cache) && !_OC_CacheMatches())
    {
        try DirDelete(cache, true)
    }

    if !DirExist(cache)
    {
        exit := RunWait('git clone --depth=1 --branch ' branch ' "' url '" "' cache '"', , "Hide")
        if (exit != 0)
            return Map("ok", false, "msg", "git clone failed (no network or git not on PATH)")
        return Map("ok", true, "msg", "cloned " branch)
    }

    exit := RunWait('git -C "' cache '" pull --depth=1 --rebase origin ' branch, , "Hide")
    if (exit != 0)
        return Map("ok", true, "msg", "pull failed — using cached upstream")
    return Map("ok", true, "msg", "upstream up to date")
}

; ── AHK parsing ───────────────────────────────────────────────────────────────

; Parses ahk/PoE2Offsets.ahk into {mapName: {field: "0xHH"}}. Mirrors
; parse_ahk_offsets(); uses the same regex so behaviour matches the Python tool.
_OC_ParseAhkOffsets(path)
{
    result := _OC_Map()
    if !FileExist(path)
        return result
    text := FileRead(path, "UTF-8")
    pos := 1
    while (pos := RegExMatch(text, 's)static\s+(\w+)\s*:=\s*Map\s*\((.*?)\)', &m, pos))
    {
        mapName := m[1]
        body := m[2]
        fields := _OC_Map()
        fp := 1
        while (fp := RegExMatch(body, '"(\w+)"\s*,\s*(0x[0-9A-Fa-f]+|-?\d+)', &fm, fp))
        {
            fields[fm[1]] := _OC_NormHex(fm[2])
            fp += fm.Len
        }
        if (fields.Count > 0)
            result[mapName] := fields
        pos += m.Len
    }
    return result
}

; Parses ahk/StaticOffsetsPatterns.ahk into {name: pattern}. Mirrors
; parse_ahk_patterns().
_OC_ParseAhkPatterns(path)
{
    result := _OC_Map()
    if !FileExist(path)
        return result
    text := FileRead(path, "UTF-8")
    pos := 1
    while (pos := RegExMatch(text, 'Map\s*\(\s*"name"\s*,\s*"([^"]+)"\s*,\s*"pattern"\s*,\s*"([^"]+)"\s*\)', &m, pos))
    {
        result[m[1]] := Trim(m[2])
        pos += m.Len
    }
    return result
}

; ── C# parsing ────────────────────────────────────────────────────────────────

; Parses all .cs files under the GameOffsets dir into
; {structName: {"_file": rel, field: "0xHH"}}. Mirrors parse_cs_offsets().
_OC_ParseCsOffsets(csDir)
{
    result := _OC_Map()
    if !DirExist(csDir)
        return result
    fieldRe  := '\[FieldOffset\s*\(\s*(0x[0-9A-Fa-f]+|\d+)\s*\)\]\s+public\s+[\w<>, *?]+\s+(\w+)'
    structRe := 'public\s+struct\s+(\w+)'

    Loop Files, csDir "\*.cs", "R"
    {
        if (InStr(A_LoopFilePath, "\bin\") || InStr(A_LoopFilePath, "\obj\"))
            continue
        text := FileRead(A_LoopFilePath, "UTF-8")

        ; Collect every FieldOffset entry first; skip files with none.
        entry := _OC_Map()
        relPath := StrReplace(A_LoopFilePath, csDir "\", "")
        entry["_file"] := relPath
        fp := 1
        while (fp := RegExMatch(text, fieldRe, &fm, fp))
        {
            fname := fm[2]
            if (SubStr(fname, 1, 4) != "PAD_")
                entry[fname] := _OC_NormHex(fm[1])
            fp += fm.Len
        }
        if (entry.Count <= 1)
            continue

        ; Primary struct name: prefer the one matching the file stem.
        stem := RegExReplace(A_LoopFileName, "\.cs$", "")
        primary := stem
        firstStruct := ""
        matchedStem := false
        sp := 1
        while (sp := RegExMatch(text, structRe, &sm, sp))
        {
            if (firstStruct = "")
                firstStruct := sm[1]
            if (StrLower(sm[1]) = StrLower(stem))
            {
                primary := sm[1]
                matchedStem := true
                break
            }
            sp += sm.Len
        }
        if (!matchedStem && firstStruct != "")
            primary := firstStruct

        result[primary] := entry
    }
    return result
}

; Parses GameOffsets/StaticOffsetsPatterns.cs into {name: pattern}. Mirrors
; parse_cs_patterns().
_OC_ParseCsPatterns(csDir)
{
    result := _OC_Map()
    path := csDir "\StaticOffsetsPatterns.cs"
    if !FileExist(path)
        return result
    text := FileRead(path, "UTF-8")
    pos := 1
    while (pos := RegExMatch(text, 'new\s*\(\s*"([^"]+)"\s*,\s*\n?\s*"([^"]+)"', &m, pos))
    {
        result[m[1]] := Trim(m[2])
        pos += m.Len
    }
    return result
}

; ── Matching & diff ────────────────────────────────────────────────────────────

; Builds {ahkMapName: csStructName} via normalised name matching. Mirrors
; build_struct_mapping().
_OC_BuildStructMapping(ahk, cs)
{
    csNorm := Map()   ; lowercased normalised cs name -> actual cs key (case-insensitive)
    for k, v in cs
        csNorm[StrLower(_OC_NormStruct(k))] := k
    mapping := _OC_Map()
    for ahkName, v in ahk
    {
        key := StrLower(_OC_NormStruct(ahkName))
        if csNorm.Has(key)
            mapping[ahkName] := csNorm[key]
        else if cs.Has(ahkName)
            mapping[ahkName] := ahkName
    }
    return mapping
}

; Returns an array of diff entries (only fields present on both sides that
; differ). Mirrors compute_diff().
_OC_ComputeDiff(ahk, cs, mapping)
{
    diffs := []
    for ahkMap, fields in ahk
    {
        csStruct := mapping.Has(ahkMap) ? mapping[ahkMap] : ""
        csEntry  := (csStruct != "" && cs.Has(csStruct)) ? cs[csStruct] : _OC_Map()
        csFile   := csEntry.Has("_file") ? csEntry["_file"] : "?"
        for field, ahkVal in fields
        {
            if !csEntry.Has(field)
                continue
            csVal := csEntry[field]
            if (ahkVal != csVal)
                diffs.Push(Map(
                    "key", ahkMap "/" field,
                    "ahk_map", ahkMap, "field", field,
                    "ahk_val", ahkVal, "cs_val", csVal,
                    "cs_struct", (csStruct != "" ? csStruct : "?"), "cs_file", csFile))
        }
    }
    return diffs
}

; Returns an array of pattern diffs. Mirrors compute_pattern_diff().
_OC_ComputePatternDiff(ahkPats, csPats)
{
    diffs := []
    for name, ahkP in ahkPats
    {
        if (csPats.Has(name) && csPats[name] != ahkP)
            diffs.Push(Map("name", name, "ahk", ahkP, "cs", csPats[name]))
    }
    return diffs
}

; Counts total fields across all C# structs (excluding the "_file" marker).
_OC_CsFieldCount(cs)
{
    total := 0
    for k, entry in cs
        total += entry.Count - 1
    return total
}

; ── History (offset_history.json) ──────────────────────────────────────────────

; Loads the history file, or an empty schema if absent/unreadable.
_OC_LoadHistory()
{
    path := _OC_HistoryFile()
    if FileExist(path)
    {
        try
        {
            h := JsonFull_Parse(FileRead(path, "UTF-8"))
            if (Type(h) = "Map" && h.Has("offsets") && h.Has("patterns"))
                return h
        }
    }
    return Map("schema", 1, "offsets", Map(), "patterns", Map())
}

; Writes the history file as pretty-printed JSON.
_OC_SaveHistory(h)
{
    f := FileOpen(_OC_HistoryFile(), "w", "UTF-8")
    if f
    {
        f.Write(JsonFull_Stringify(h, true))
        f.Close()
    }
}

; Returns the last recorded ahk_value for a history entry, or "".
_OC_LastValue(events)
{
    return events.Length ? events[events.Length]["ahk_value"] : ""
}

; ── Bridge handlers (called from BridgeDispatch via SetTimer) ────────────────────

; Computes the full comparison result Map (no UI push). Shared by the dev-panel
; handler (OffsetCompareRun) and the patch-maintenance flow.
_OC_RunCompareData()
{
    result := Map("ok", false, "msg", "", "version", "", "fetchMsg", "")
    try
    {
        result["version"] := _OC_GameVersion()
        fetch := _OC_FetchUpstream()
        result["fetchMsg"] := fetch["msg"]

        csDir := _OC_CacheDir() "\" _OC_CsRel()
        if !DirExist(csDir)
        {
            result["msg"] := "C# sources not found in cache: " csDir
            return result
        }

        ahk      := _OC_ParseAhkOffsets(_OC_AhkOffsets())
        ahkPats  := _OC_ParseAhkPatterns(_OC_AhkPatterns())
        cs       := _OC_ParseCsOffsets(csDir)
        csPats   := _OC_ParseCsPatterns(csDir)
        mapping  := _OC_BuildStructMapping(ahk, cs)

        offsetDiffs  := _OC_ComputeDiff(ahk, cs, mapping)
        patternDiffs := _OC_ComputePatternDiff(ahkPats, csPats)

        ahkOffsetCount := 0
        for k, v in ahk
            ahkOffsetCount += v.Count

        result["ok"]            := true
        result["commit"]        := _OC_UpstreamCommit()
        result["ahkMapCount"]   := ahk.Count
        result["ahkOffsetCount"]:= ahkOffsetCount
        result["csStructCount"] := cs.Count
        result["csFieldCount"]  := _OC_CsFieldCount(cs)
        result["matchCount"]    := mapping.Count
        result["offsetDiffs"]   := offsetDiffs
        result["patternDiffs"]  := patternDiffs
    }
    catch as ex
    {
        result["ok"] := false
        result["msg"] := ex.Message
        try LogError("OffsetCompareRun", ex)
    }
    return result
}

; Runs a full comparison and pushes the result to the WebView dev panel.
OffsetCompareRun()
{
    _OC_PushRun(_OC_RunCompareData())
}

_OC_PushRun(result)
{
    json := JsonFull_Stringify(result, false)
    try WebViewExec("updateOffsetComparison(" _JsStr(json) ")")
}

; Records the supplied classifications into the history file. payloadJson is a
; JSON array of {key, change_type, notes}; unlisted changes default to
; game_update. Also seeds "initial" baselines for in-sync fields/patterns.
OffsetCompareRecord(payloadJson)
{
    status := Map("ok", false, "msg", "")
    try
    {
        cls := Map()
        cls.CaseSense := "On"
        parsed := (payloadJson != "") ? JsonFull_Parse(payloadJson) : ""
        if (Type(parsed) = "Array")
        {
            for i, item in parsed
            {
                if (Type(item) = "Map" && item.Has("key"))
                    cls[item["key"]] := item
            }
        }

        csDir := _OC_CacheDir() "\" _OC_CsRel()
        ahk      := _OC_ParseAhkOffsets(_OC_AhkOffsets())
        ahkPats  := _OC_ParseAhkPatterns(_OC_AhkPatterns())
        cs       := _OC_ParseCsOffsets(csDir)
        csPats   := _OC_ParseCsPatterns(csDir)
        mapping  := _OC_BuildStructMapping(ahk, cs)
        offsetDiffs  := _OC_ComputeDiff(ahk, cs, mapping)
        patternDiffs := _OC_ComputePatternDiff(ahkPats, csPats)

        h := _OC_LoadHistory()
        gv := _OC_GameVersion()
        commit := _OC_UpstreamCommit()
        today := FormatTime(A_Now, "yyyy-MM-dd")
        changed := 0

        ; Changed offsets — append a classified event when the value moved.
        for i, d in offsetDiffs
        {
            key := d["key"]
            ct := (cls.Has(key) && cls[key].Has("change_type")) ? cls[key]["change_type"] : "game_update"
            notes := (cls.Has(key) && cls[key].Has("notes")) ? cls[key]["notes"] : ""
            if !h["offsets"].Has(key)
                h["offsets"][key] := Map("ahk_map", d["ahk_map"], "field", d["field"], "cs_struct", d["cs_struct"], "cs_file", d["cs_file"], "events", [])
            entry := h["offsets"][key]
            if (_OC_LastValue(entry["events"]) = d["ahk_val"])
                continue
            entry["events"].Push(Map("date", today, "game_version", gv, "cs_commit", commit, "ahk_value", d["ahk_val"], "cs_value", d["cs_val"], "change_type", ct, "notes", notes))
            changed += 1
        }

        ; Baseline (initial) entries for fields that are currently in sync.
        initCount := 0
        for ahkMap, fields in ahk
        {
            csStruct := mapping.Has(ahkMap) ? mapping[ahkMap] : ""
            csEntry  := (csStruct != "" && cs.Has(csStruct)) ? cs[csStruct] : _OC_Map()
            csFile   := csEntry.Has("_file") ? csEntry["_file"] : "?"
            for field, ahkVal in fields
            {
                if (!csEntry.Has(field) || csEntry[field] != ahkVal)
                    continue
                key := ahkMap "/" field
                if !h["offsets"].Has(key)
                    h["offsets"][key] := Map("ahk_map", ahkMap, "field", field, "cs_struct", (csStruct != "" ? csStruct : "?"), "cs_file", csFile, "events", [])
                entry := h["offsets"][key]
                if (entry["events"].Length = 0)
                {
                    entry["events"].Push(Map("date", today, "game_version", gv, "cs_commit", commit, "ahk_value", ahkVal, "cs_value", csEntry[field], "change_type", "initial", "notes", ""))
                    initCount += 1
                }
            }
        }

        ; Patterns: classified change events + baselines for matching ones.
        for i, d in patternDiffs
        {
            name := d["name"]
            ct := (cls.Has("pattern:" name) && cls["pattern:" name].Has("change_type")) ? cls["pattern:" name]["change_type"] : "game_update"
            notes := (cls.Has("pattern:" name) && cls["pattern:" name].Has("notes")) ? cls["pattern:" name]["notes"] : ""
            if !h["patterns"].Has(name)
                h["patterns"][name] := Map("events", [])
            h["patterns"][name]["events"].Push(Map("date", today, "game_version", gv, "cs_commit", commit, "ahk_value", d["ahk"], "cs_value", d["cs"], "change_type", ct, "notes", notes))
            changed += 1
        }
        for name, ahkP in ahkPats
        {
            if (csPats.Has(name) && csPats[name] = ahkP)
            {
                if !h["patterns"].Has(name)
                    h["patterns"][name] := Map("events", [])
                if (h["patterns"][name]["events"].Length = 0)
                {
                    h["patterns"][name]["events"].Push(Map("date", today, "game_version", gv, "cs_commit", commit, "ahk_value", ahkP, "cs_value", csPats[name], "change_type", "initial", "notes", ""))
                    initCount += 1
                }
            }
        }

        _OC_SaveHistory(h)
        status["ok"] := true
        status["msg"] := changed " change(s) recorded, " initCount " baseline(s) added"
    }
    catch as ex
    {
        status["msg"] := ex.Message
        try LogError("OffsetCompareRecord", ex)
    }
    try WebViewExec("updateOffsetRecordStatus(" _JsStr(JsonFull_Stringify(status, false)) ")")
    OffsetCompareShowHistory()
}

; Pushes the recorded change history (non-initial events) to the WebView.
OffsetCompareShowHistory()
{
    out := Map("ok", true, "events", [])
    try
    {
        h := _OC_LoadHistory()
        events := []
        for key, entry in h["offsets"]
            for i, ev in entry["events"]
                if (ev["change_type"] != "initial")
                    events.Push(Map("date", ev["date"], "kind", "offset", "key", key, "ahk", ev["ahk_value"], "cs", ev["cs_value"], "type", ev["change_type"], "version", ev["game_version"], "notes", ev.Has("notes") ? ev["notes"] : ""))
        for name, entry in h["patterns"]
            for i, ev in entry["events"]
                if (ev["change_type"] != "initial")
                    events.Push(Map("date", ev["date"], "kind", "pattern", "key", name, "ahk", ev["ahk_value"], "cs", ev["cs_value"], "type", ev["change_type"], "version", ev["game_version"], "notes", ev.Has("notes") ? ev["notes"] : ""))
        out["events"] := events
    }
    catch as ex
    {
        out["ok"] := false
        out["msg"] := ex.Message
    }
    try WebViewExec("updateOffsetHistory(" _JsStr(JsonFull_Stringify(out, false)) ")")
}

; Analyses game_update deltas per struct and pushes prediction candidates
; (structs whose fields shifted by a single uniform delta). Mirrors
; show_predictions().
OffsetComparePredict()
{
    out := Map("ok", true, "structs", [])
    try
    {
        h := _OC_LoadHistory()
        ; struct -> array of {field, version, old, new, delta}
        structDeltas := Map()
        for key, entry in h["offsets"]
        {
            ahkMap := entry.Has("ahk_map") ? entry["ahk_map"] : StrSplit(key, "/")[1]
            for i, ev in entry["events"]
            {
                if (ev["change_type"] != "game_update")
                    continue
                old := _OC_HexToInt(ev["ahk_value"])
                new := _OC_HexToInt(ev["cs_value"])
                if (old = "" || new = "")
                    continue
                if !structDeltas.Has(ahkMap)
                    structDeltas[ahkMap] := []
                structDeltas[ahkMap].Push(Map("field", entry["field"], "version", ev["game_version"], "old", ev["ahk_value"], "new", ev["cs_value"], "delta", new - old))
            }
        }

        for structName, events in structDeltas
        {
            ; Group by game version; flag uniform shifts (>1 field, single delta).
            byVer := Map()
            for i, e in events
            {
                if !byVer.Has(e["version"])
                    byVer[e["version"]] := []
                byVer[e["version"]].Push(e)
            }
            versions := []
            for ver, batch in byVer
            {
                deltaSet := Map()
                for i, e in batch
                    deltaSet[e["delta"]] := true
                uniform := (deltaSet.Count = 1 && batch.Length > 1)
                fields := []
                for i, e in batch
                    fields.Push(e["field"])
                versions.Push(Map("version", ver, "uniform", uniform, "delta", batch[1]["delta"], "count", batch.Length, "fields", fields))
            }
            out["structs"].Push(Map("struct", structName, "versions", versions))
        }
    }
    catch as ex
    {
        out["ok"] := false
        out["msg"] := ex.Message
    }
    try WebViewExec("updateOffsetPredict(" _JsStr(JsonFull_Stringify(out, false)) ")")
}

; Parses a normalised hex string ("0xHH") to an integer, or "" if invalid.
_OC_HexToInt(s)
{
    s := Trim(s)
    if RegExMatch(s, "i)^-?0x[0-9a-f]+$")
        return Integer(s)
    return ""
}
