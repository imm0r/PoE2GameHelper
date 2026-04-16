#Requires AutoHotkey v2.0
#SingleInstance Force

#Include PoE2MemoryReader.ahk

reader := PoE2GameStateReader("PathOfExileSteam.exe")
strictOk := reader.Connect(true)
if (!reader.Mem.Handle)
{
    MsgBox "Konnte Prozess nicht öffnen: PathOfExileSteam.exe"
    ExitApp
}

staticAddresses := reader.StaticAddresses
debugLogPath := reader.ExportPatternMatchesDebug(0)
debugCsvPath := reader.ExportPatternMatchesCsv(0)
if (staticAddresses.Count = 0)
{
    report := reader.PatternScanReport
    missingCriticalList := report["missingCritical"]
    msg := "Keine Static Addresses per Pattern-Scan gefunden.`n`n"
    if (missingCriticalList.Length)
        msg .= "Missing critical: " JoinArray(missingCriticalList, ", ")
    MsgBox msg
    ExitApp
}

out := "Pattern Scan Ergebnis`n`n"
out .= "PID: " reader.Mem.Pid "`n"
out .= "ModuleBase: " PoE2GameStateReader.Hex(reader.Mem.ModuleBase) "`n`n"
if (debugLogPath != "")
    out .= "DebugLog: " debugLogPath "`n`n"
if (debugCsvPath != "")
    out .= "DebugCsv: " debugCsvPath "`n`n"

for name, addr in staticAddresses
    out .= name ": " PoE2GameStateReader.Hex(addr) "`n"

if (staticAddresses.Has("Game States"))
{
    isValid := reader.ValidateGameStatesAddress(staticAddresses["Game States"])
    out .= "`nGame States Validierung: " (isValid ? "OK" : "Fehlgeschlagen")
}

report := reader.PatternScanReport
out .= "StrictConnect: " (strictOk ? "OK" : "FAILED") "`n"
if (report["missingCritical"].Length)
    out .= "`n`nMissing critical: " JoinArray(report["missingCritical"], ", ")
if (report["missingOptional"].Length)
    out .= "`nMissing optional: " JoinArray(report["missingOptional"], ", ")
if (report["duplicateCritical"].Length)
    out .= "`nDuplicate critical: " JoinArray(report["duplicateCritical"], ", ")
if (report["duplicateOptional"].Length)
    out .= "`nDuplicate optional: " JoinArray(report["duplicateOptional"], ", ")

MsgBox out
ExitApp

JoinArray(arr, sep := ", ")
{
    text := ""
    for i, v in arr
    {
        if (i > 1)
            text .= sep
        text .= v
    }
    return text
}
