; CustomHotkeysBridge.ahk
; WebView bridge glue for the custom-hotkey engine: pushes the hotkey config to
; the UI and applies edits sent back from the Hotkeys tab.
;
; Included by InGameStateMonitor.ahk

; Pushes the current hotkey config (groups -> hotkeys -> actions) to the
; updateHotkeys() handler in the WebView as a JSON string.
PushHotkeysToWebView()
{
    global g_hotkeyGroups, g_webViewReady
    if !g_webViewReady
        return
    json := JsonFull_Stringify(g_hotkeyGroups, false)
    try WebViewExec("updateHotkeys(" _JsStr(json) ")")
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
