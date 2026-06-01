; ErrorLogger.ahk
; Error logging with automatic log rotation.
; Writes timestamped entries to InGameStateMonitor.error.log and rotates at 512 KB.
;
; Included by InGameStateMonitor.ahk

; Creates or appends a session-start header to the error log file on script launch.
InitializeErrorLog()
{
    global g_errorLogPath
    try
    {
        header := "`n===== Start " FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") " | PID=" DllCall("GetCurrentProcessId", "UInt") " =====`n"
        FileAppend(header, g_errorLogPath, "UTF-8")
    }
    catch
    {
    }
}

; Appends a timestamped error entry to the log file.
; Rotates the log to a .1 backup if it exceeds the max size.
; Params: context - label identifying the call site; err - optional AHK Error object
LogError(context, err := "")
{
    global g_errorLogPath, g_errorLogMaxBytes
    static _logging := false

    if _logging
        return
    _logging := true
    try
    {
        ; Rotate log if it exceeds size limit
        try
        {
            if FileExist(g_errorLogPath)
            {
                size := FileGetSize(g_errorLogPath)
                if (size >= g_errorLogMaxBytes)
                {
                    backupPath := g_errorLogPath ".1"
                    try FileDelete(backupPath)
                    FileMove(g_errorLogPath, backupPath, true)
                }
            }
        }
        catch
        {
        }

        ; Extract error details with safe fallbacks
        msg := ""
        try msg := err.Message
        what := ""
        try what := err.What
        line := ""
        try line := err.Line
        extra := ""
        try extra := err.Extra
        stack := ""
        try stack := err.Stack

        text := "[" FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") "] " context
        if (msg != "")
            text .= " | msg=" msg
        if (what != "")
            text .= " | what=" what
        if (line != "")
            text .= " | line=" line
        if (extra != "")
            text .= " | extra=" extra
        if (stack != "")
            text .= "`n" stack
        text .= "`n"

        FileAppend(text, g_errorLogPath, "UTF-8")
    }
    catch
    {
    }
    finally
        _logging := false
}
