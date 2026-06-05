; PatchChecker.ahk
; Queries the PoE2 patch server on startup to detect game updates.
; Ported from: https://github.com/poe-tool-dev/poe-patch-update
;
; Protocol: TCP connect to patch.pathofexile2.com:13060, send [0x01, 0x06],
; read the response. The patch version string is UTF-16LE starting at byte 35,
; with its length (in chars) at byte 34; the final '/'-separated segment is the
; patch version (e.g. "4.4.0.10").
;
; The TCP probe runs natively via Winsock (ws2_32.dll, DllCall) — no PowerShell
; child process is spawned.
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

; Queries the PoE2 patch server over a raw TCP socket (Winsock) and returns the
; current patch-version string (the final '/'-separated segment), or "" on any
; failure (offline, timeout, malformed packet). No external process is spawned.
; Params: host/port - patch-server endpoint; timeoutMs - send/recv timeout.
_PatchChecker_FetchVersion(host := "patch.pathofexile2.com", port := 13060, timeoutMs := 5000)
{
    static AF_INET := 2, SOCK_STREAM := 1, IPPROTO_TCP := 6
    static SOL_SOCKET := 0xFFFF, SO_RCVTIMEO := 0x1006, SO_SNDTIMEO := 0x1005
    static INVALID_SOCKET := -1

    ; Winsock 2.2 init — bail quietly if it fails.
    wsaData := Buffer(512, 0)
    if DllCall("ws2_32\WSAStartup", "UShort", 0x0202, "Ptr", wsaData)
        return ""

    sock := INVALID_SOCKET
    pResult := 0
    version := ""
    try
    {
        ; Resolve host:port into a TCP/IPv4 sockaddr (ANSI addrinfo). The int
        ; fields (ai_family/socktype/protocol) sit at the same offsets on x86/x64;
        ; the pointer fields are addressed via A_PtrSize so this stays bitness-safe.
        hints := Buffer(64, 0)
        NumPut("Int", AF_INET, hints, 4)    ; addrinfo.ai_family
        NumPut("Int", SOCK_STREAM, hints, 8)    ; addrinfo.ai_socktype
        NumPut("Int", IPPROTO_TCP, hints, 12)   ; addrinfo.ai_protocol
        if DllCall("ws2_32\getaddrinfo", "AStr", host, "AStr", String(port), "Ptr", hints, "Ptr*", &pResult, "Int")
            return ""
        aiAddrLen := NumGet(pResult, 16, "Ptr")                  ; addrinfo.ai_addrlen
        aiAddr := NumGet(pResult, 16 + 2 * A_PtrSize, "Ptr")  ; addrinfo.ai_addr (sockaddr*)

        sock := DllCall("ws2_32\socket", "Int", AF_INET, "Int", SOCK_STREAM, "Int", IPPROTO_TCP, "Ptr")
        if (sock = INVALID_SOCKET)
            return ""

        ; Apply send/recv timeouts (ms) so a stalled server can't hang startup.
        tv := Buffer(4, 0)
        NumPut("Int", timeoutMs, tv)
        DllCall("ws2_32\setsockopt", "Ptr", sock, "Int", SOL_SOCKET, "Int", SO_RCVTIMEO, "Ptr", tv, "Int", 4)
        DllCall("ws2_32\setsockopt", "Ptr", sock, "Int", SOL_SOCKET, "Int", SO_SNDTIMEO, "Ptr", tv, "Int", 4)

        if DllCall("ws2_32\connect", "Ptr", sock, "Ptr", aiAddr, "Int", aiAddrLen, "Int")
            return ""

        ; Request packet: [0x01, 0x06].
        reqBuf := Buffer(2, 0)
        NumPut("UChar", 1, reqBuf, 0)
        NumPut("UChar", 6, reqBuf, 1)
        if (DllCall("ws2_32\send", "Ptr", sock, "Ptr", reqBuf, "Int", 2, "Int", 0, "Int") = INVALID_SOCKET)
            return ""

        ; Single response read — the version sits near the start of the packet.
        rcvBuf := Buffer(1024, 0)
        n := DllCall("ws2_32\recv", "Ptr", sock, "Ptr", rcvBuf, "Int", 1024, "Int", 0, "Int")
        if (n < 36)
            return ""

        len := NumGet(rcvBuf, 34, "UChar")         ; version length in chars (byte 34)
        if (len <= 0 || 35 + len * 2 > n)          ; bounds-check against bytes received
            return ""
        ver := StrGet(rcvBuf.Ptr + 35, len, "UTF-16")

        ; Keep the final non-empty '/'-separated segment (e.g. ".../4.4.0.10").
        for i, seg in StrSplit(ver, "/")
            if (Trim(seg) != "")
                version := seg
    }
    finally
    {
        if (sock != INVALID_SOCKET)
            DllCall("ws2_32\closesocket", "Ptr", sock)
        if (pResult)
            DllCall("ws2_32\freeaddrinfo", "Ptr", pResult)
        DllCall("ws2_32\WSACleanup")
    }
    return version
}

CheckPoePatchVersion()
{
    _PatchChecker_MigrateLegacyFile()
    iniFile := _ConfigPath()

    currentPatch := _PatchChecker_FetchVersion()

    ; Bail on empty/invalid response (offline, timeout, or malformed packet).
    if (!currentPatch || !RegExMatch(currentPatch, "^\d+\.\d+"))
        return

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
        "note", "Offsets may also have changed — verify pattern scanning."
    )
    js := "showPatchUpdate(" JsonFull_Stringify(payload, false) ")"
    if (IsSet(g_webViewReady) && g_webViewReady)
    {
        try WebViewExec(js)
    }
    else
        g_pendingPatchNotice := js
}

; Returns the last known patch version string, or "" if never checked.
; Reads from the INI ([General] lastKnownPatch), migrating the legacy
; last_known_patch.txt if it's still lying around.
GetLastKnownPoeVersion()
{
    _PatchChecker_MigrateLegacyFile()
    return IniRead(_ConfigPath(), "General", "lastKnownPatch", "")
}