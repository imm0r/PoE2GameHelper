; PatchChecker.ahk
; Queries the PoE2 patch server on startup to detect game updates.
; Ported from: https://github.com/poe-tool-dev/poe-patch-update
;
; Protocol: TCP connect to patch.pathofexile.com:12995, send [0x01, 0x06],
; read response. The patch version string is UTF-16LE starting at byte 35,
; with length (in chars) at byte 34.

CheckPoePatchVersion()
{
    versionFile := A_ScriptDir "\last_known_patch.txt"
    tempOut     := A_Temp "\poe_patch_out_" A_TickCount ".txt"
    tempScript  := A_Temp "\poe_patch_" A_TickCount ".ps1"

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
    lastPatch    := FileExist(versionFile) ? Trim(FileRead(versionFile)) : ""

    ; Always persist the latest known version
    try {
        fh := FileOpen(versionFile, "w", "UTF-8")
        fh.Write(currentPatch)
        fh.Close()
    }

    if (lastPatch = "")
        return  ; First run — silently store, no popup

    if (currentPatch != lastPatch)
    {
        msg := "⚠️  PoE2 Patch Update detected!`n`n"
            . "Previous: " lastPatch "`n"
            . "Current:  " currentPatch "`n`n"
            . "The following files should be rebuilt:`n"
            . "  python build_stat_desc_map.py`n"
            . "  python build_item_names.py`n`n"
            . "Offsets may also have changed — verify pattern scanning."
        MsgBox(msg, "PoE2 Patch Update", "Icon! 48")
    }
}

; Returns the last known patch version string, or "" if never checked.
GetLastKnownPoeVersion()
{
    versionFile := A_ScriptDir "\last_known_patch.txt"
    return FileExist(versionFile) ? Trim(FileRead(versionFile)) : ""
}
