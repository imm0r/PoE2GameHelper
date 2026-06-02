; PatchChecker.ahk
; Queries the PoE2 patch server on startup to detect game updates.
; Ported from: https://github.com/poe-tool-dev/poe-patch-update
;
; Protocol: TCP connect to patch.pathofexile.com:12995, send [0x01, 0x06],
; read response. The patch version string is UTF-16LE starting at byte 35,
; with length (in chars) at byte 34.
;
; Storage: persisted in the main config INI under [General] lastKnownPatch.
; Older builds stashed it in `last_known_patch.txt`; if that file exists
; we migrate its contents into the INI once and then delete the file.

; Migrate legacy last_known_patch.txt into the INI exactly once.
; Safe to call multiple times — short-circuits when there's nothing to do.
_PatchChecker_MigrateLegacyFile()
{
    legacy := A_ScriptDir "\last_known_patch.txt"
    if (!FileExist(legacy))
        return
    iniFile := _ConfigPath()
    existing := IniRead(iniFile, "General", "lastKnownPatch", "")
    if (existing = "")
    {
        try
        {
            content := Trim(FileRead(legacy))
            if (content != "")
                IniWrite(content, iniFile, "General", "lastKnownPatch")
        }
    }
    try FileDelete(legacy)
}

CheckPoePatchVersion()
{
    _PatchChecker_MigrateLegacyFile()
    iniFile := _ConfigPath()
    tempOut := A_Temp "\poe_patch_out_" A_TickCount ".txt"
    tempScript := A_Temp "\poe_patch_" A_TickCount ".ps1"

    ; Write a PS1 script to temp — avoids all inline quoting issues
    psContent := ""
        . "try {`r`n"
        . "    $c = New-Object System.Net.Sockets.TcpClient`r`n"
        . "    $c.ReceiveTimeout = 5000`r`n"
        . "    $c.SendTimeout = 5000`r`n"
        . "    $c.Connect('patch.pathofexile2.com', 13060)`r`n"
        . "    $s = $c.GetStream()`r`n"
        . "    $s.Write([byte[]](1, 6), 0, 2)`r`n"
        . "    $b = New-Object byte[] 1024`r`n"
        . "    $null = $s.Read($b, 0, 1024)`r`n"
        . "    $len = $b[34]`r`n"
        . "    $ver = [System.Text.Encoding]::Unicode.GetString($b, 35, $len * 2)`r`n"
        . "    $patch = ($ver -split '/') | Where-Object { $_ } | Select-Object -Last 1`r`n"
        . "    [System.IO.File]::WriteAllText('" tempOut "', $patch)`r`n"
        . "    $c.Close()`r`n"
        . "} catch {`r`n"
        . "    [System.IO.File]::WriteAllText('" tempOut "', 'ERROR: ' + $_.Exception.Message)`r`n"
        . "}`r`n"

    try {
        fh := FileOpen(tempScript, "w", "UTF-8")
        fh.Write(psContent)
        fh.Close()
    }

    RunWait('powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' tempScript '"', , "Hide")

    try FileDelete(tempScript)

    if !FileExist(tempOut)
        return

    raw := Trim(FileRead(tempOut))
    try FileDelete(tempOut)

    ; Bail on error or empty/invalid response
    if (!raw || SubStr(raw, 1, 5) = "ERROR" || !RegExMatch(raw, "^\d+\.\d+"))
        return

    currentPatch := raw
    lastPatch := IniRead(iniFile, "General", "lastKnownPatch", "")

    ; Always persist the latest known version
    IniWrite(currentPatch, iniFile, "General", "lastKnownPatch")

    if (lastPatch = "")
        return  ; First run — silently store, no popup

    if (currentPatch != lastPatch)
        ShowPatchUpdateNotice(lastPatch, currentPatch)
}

; Shows the "patch update detected" notice in the WebView, styled to match the
; Helper UI (Codex theme), instead of a native MsgBox. If the WebView isn't
; ready yet (this runs at startup, while the page is still navigating), the
; payload is queued in g_pendingPatchNotice and flushed by OnNavigationCompleted.
; Params: prevPatch / curPatch — the previous and current patch version strings.
ShowPatchUpdateNotice(prevPatch, curPatch)
{
    global g_webViewReady, g_pendingPatchNotice
    payload := Map(
        "previous", prevPatch,
        "current", curPatch,
        "files", ["python build_stat_desc_map.py", "python build_item_names.py"],
        "note", "Offsets may also have changed — verify pattern scanning.")
    js := "showPatchUpdate(" JsonFull_Stringify(payload, false) ")"
    if (IsSet(g_webViewReady) && g_webViewReady)
    {
        try WebViewExec(js)
    }
    else
    {
        g_pendingPatchNotice := js
    }
}

; Returns the last known patch version string, or "" if never checked.
; Reads from the INI ([General] lastKnownPatch), migrating the legacy
; last_known_patch.txt if it's still lying around.
GetLastKnownPoeVersion()
{
    _PatchChecker_MigrateLegacyFile()
    return IniRead(_ConfigPath(), "General", "lastKnownPatch", "")
}