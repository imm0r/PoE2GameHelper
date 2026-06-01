; CustomHotkeysBridge.ahk
; WebView bridge glue for the custom-hotkey engine: pushes the hotkey config to
; the UI and applies edits sent back from the Hotkeys tab.
;
; Included by InGameStateMonitor.ahk

; Pushes the current hotkey config (groups -> hotkeys -> actions) to the
; updateHotkeys() handler in the WebView as a JSON string.
PushHotkeysToWebView()
{
    global g_hotkeyGroups, g_webViewReady, g_hkOneShotPerTick
    if !g_webViewReady
        return
    json := JsonFull_Stringify(g_hotkeyGroups, false)
    oneShot := (IsSet(g_hkOneShotPerTick) && g_hkOneShotPerTick) ? "true" : "false"
    try WebViewExec("updateHotkeys(" _JsStr(json) ", " oneShot ")")
    PushHotkeyBindingsToWebView()
}

; Applies a full hotkey config received from the UI as a JSON string:
; parses + normalizes it, replaces the in-memory model, re-registers the
; AHK hotkeys, persists to disk, and echoes the normalized config back.
; Params: jsonStr - JSON array of groups from the UI.
_ApplyHotkeysConfigFromUI(jsonStr)
{
    global g_hotkeyGroups
    if (Trim(jsonStr) = "")
        return
    parsed := JsonFull_Parse(jsonStr)
    if !(parsed is Array)
        return
    g_hotkeyGroups := _HotkeysNormalizeGroups(parsed)
    HotkeysRegisterAll()
    HotkeysSaveConfig()
    PushHotkeysToWebView()
}

; Sets the global one-shot-per-tick flag and persists it to the config INI.
_SetHotkeyOneShot(enabled)
{
    global g_hkOneShotPerTick
    g_hkOneShotPerTick := enabled ? true : false
    try IniWrite(g_hkOneShotPerTick ? "1" : "0", _ConfigPath(), "Hotkeys", "oneShotPerTick")
}

; Returns the export/import folder (A_ScriptDir\hotkeys_export), creating it.
_HotkeysExportDir()
{
    dir := A_ScriptDir "\hotkeys_export"
    if !DirExist(dir)
        try DirCreate(dir)
    return dir
}

; Writes an exported hotkey item (group or action) as JSON into hotkeys_export/.
; Params: kind - "group"|"action"; name - base name; json - the item JSON string.
_ExportHotkeysItem(kind, name, json)
{
    if (Trim(json) = "")
        return
    dir := _HotkeysExportDir()
    safe := RegExReplace(Trim(name) = "" ? kind : name, "[^\w\-]", "_")
    safe := SubStr(safe, 1, 40)
    path := dir "\" kind "_" safe "_" FormatTime(A_Now, "yyyyMMdd_HHmmss") ".json"
    try
    {
        f := FileOpen(path, "w", "UTF-8")
        if f
        {
            f.Write(json)
            f.Close()
        }
        ToolTip("Exported " kind " → " path)
        SetTimer(() => ToolTip(), -2500)
    }
    catch as ex
    {
        LogError("_ExportHotkeysItem", ex)
    }
}

; Imports a hotkey group from a user-picked JSON file and appends it as a new
; group (its hotkeys get fresh ids to avoid collisions).
_ImportHotkeysGroup()
{
    global g_hotkeyGroups
    parsed := _HotkeysPickAndParse("Import hotkey group")
    if !(parsed is Map)
        return
    ; Force fresh ids for the imported hotkeys.
    if (parsed.Has("hotkeys") && parsed["hotkeys"] is Array)
        for hk in parsed["hotkeys"]
            if (hk is Map)
                hk["id"] := 0
    normalized := _HotkeysNormalizeGroups([parsed])
    for g in normalized
        g_hotkeyGroups.Push(g)
    HotkeysRegisterAll()
    HotkeysSaveConfig()
    PushHotkeysToWebView()
}

; Imports a single action from a user-picked JSON file and appends it to the
; hotkey at the given 0-based group/hotkey indices (UI coordinates).
_ImportHotkeysAction(gi0, hi0)
{
    global g_hotkeyGroups
    gi := gi0 + 1
    hi := hi0 + 1
    if (gi < 1 || gi > g_hotkeyGroups.Length)
        return
    grp := g_hotkeyGroups[gi]
    if (hi < 1 || hi > grp["hotkeys"].Length)
        return
    parsed := _HotkeysPickAndParse("Import action")
    if !(parsed is Map) || !parsed.Has("type")
        return
    grp["hotkeys"][hi]["actions"].Push(parsed)
    HotkeysSaveConfig()
    PushHotkeysToWebView()
}

; Shows a file-open dialog rooted at the export folder and parses the picked
; JSON file. Returns the parsed value, or "" on cancel/parse failure.
_HotkeysPickAndParse(title)
{
    dir := _HotkeysExportDir()
    path := ""
    try path := FileSelect(1, dir "\", title, "JSON Files (*.json)")
    if (path = "")
        return ""
    raw := ""
    try raw := FileRead(path, "UTF-8")
    if (raw = "")
        return ""
    return JsonFull_Parse(raw)
}
