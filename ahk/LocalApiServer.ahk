; LocalApiServer.ahk
; A tiny local HTTP API that exposes live game data + a write surface so an
; external Model-Context-Protocol (MCP) server (see mcp-server/) can let an AI
; assistant query and steer PoEformance.
;
; Design notes:
;   - Bound to 127.0.0.1 only (loopback). Opt-in; off by default.
;   - Event-driven via Winsock + WSAAsyncSelect so the radar hot path is never
;     blocked by a blocking accept/recv. Socket notifications arrive as window
;     messages on a hidden Gui and are dispatched through OnMessage, i.e. on the
;     main AHK thread between operations — reads of g_radarLastSnap are therefore
;     consistent (the snapshot Map is swapped in atomically once fully built).
;   - Responses are sent with a short blocking send (loopback, tiny payloads).
;   - Self-persists its config to poeformance_config.ini [LocalApi] (same pattern
;     as the other modules). Globals are seeded unconditionally in
;     LoadLocalApiConfig() because module-level initializers don't run (AHK v2
;     include-after-return gotcha).
;
; Included by InGameStateMonitor.ahk.

; Seeds all module globals + Winsock constants (defaults first) then overlays the
; persisted config. Call once at startup before the window is shown.
;
; NB: the constants live here (not as top-level `global x := …` initializers)
; because module-level initializers never run for files #Include'd after the
; auto-execute return — see the AHK v2 init gotcha in CLAUDE.md.
LoadLocalApiConfig()
{
    global g_localApiEnabled, g_localApiPort
    global g_localApiListenSock, g_localApiClients, g_localApiGui
    global g_localApiStarted, g_localApiWsaUp, g_localApiNameRows, g_localApiMsgBound
    global LOCALAPI_WM_SOCKET, LOCALAPI_AF_INET, LOCALAPI_SOCK_STREAM, LOCALAPI_IPPROTO_TCP
    global LOCALAPI_FD_READ, LOCALAPI_FD_ACCEPT, LOCALAPI_FD_CLOSE
    global LOCALAPI_FIONBIO, LOCALAPI_WSAEWOULDBLOCK

    ; Winsock / socket-event constants
    LOCALAPI_WM_SOCKET     := 0x8001          ; WM_APP+1 — our socket notify message
    LOCALAPI_AF_INET       := 2
    LOCALAPI_SOCK_STREAM   := 1
    LOCALAPI_IPPROTO_TCP   := 6
    LOCALAPI_FD_READ       := 0x01
    LOCALAPI_FD_ACCEPT     := 0x08
    LOCALAPI_FD_CLOSE      := 0x20
    LOCALAPI_FIONBIO       := 0x8004667E
    LOCALAPI_WSAEWOULDBLOCK := 10035

    ; Defaults — seeded unconditionally so a fresh install never trips the
    ; "global has not been assigned a value" runtime error.
    g_localApiEnabled := false
    g_localApiPort    := 7777
    g_localApiListenSock := 0
    g_localApiClients := Map()
    g_localApiGui     := 0
    g_localApiStarted := false
    g_localApiWsaUp   := false
    g_localApiNameRows := 0      ; lazily loaded name table (Array) or 0
    g_localApiMsgBound := false

    f := A_ScriptDir "\poeformance_config.ini"
    g_localApiEnabled := (IniRead(f, "LocalApi", "enabled", "0") = "1")
    p := Integer(IniRead(f, "LocalApi", "port", "7777"))
    g_localApiPort := (p >= 1 && p <= 65535) ? p : 7777
}

; Persists the local-API config to the INI [LocalApi] section.
SaveLocalApiConfig()
{
    global g_localApiEnabled, g_localApiPort
    f := A_ScriptDir "\poeformance_config.ini"
    IniWrite(g_localApiEnabled ? "1" : "0", f, "LocalApi", "enabled")
    IniWrite(g_localApiPort,                f, "LocalApi", "port")
}

; Starts the HTTP server: WSAStartup, creates a loopback listening socket and
; routes its FD_ACCEPT/FD_CLOSE notifications to our OnMessage handler.
; Idempotent — a no-op if already running. Returns true on success.
StartLocalApiServer()
{
    global g_localApiEnabled, g_localApiPort, g_localApiListenSock, g_localApiClients
    global g_localApiGui, g_localApiStarted, g_localApiWsaUp, g_localApiMsgBound
    global LOCALAPI_WM_SOCKET, LOCALAPI_AF_INET, LOCALAPI_SOCK_STREAM, LOCALAPI_IPPROTO_TCP
    global LOCALAPI_FD_ACCEPT, LOCALAPI_FD_CLOSE

    if (g_localApiStarted)
        return true

    try
    {
        ; WSAStartup(MAKEWORD(2,2), &wsaData)
        wsaData := Buffer(512, 0)
        if (DllCall("ws2_32\WSAStartup", "UShort", 0x0202, "Ptr", wsaData, "Int") != 0)
            throw Error("WSAStartup failed")
        g_localApiWsaUp := true

        sock := DllCall("ws2_32\socket", "Int", LOCALAPI_AF_INET, "Int", LOCALAPI_SOCK_STREAM, "Int", LOCALAPI_IPPROTO_TCP, "UPtr")
        if (sock = 0 || sock = -1)
            throw Error("socket() failed")

        ; SO_REUSEADDR so a quick restart can re-bind the port immediately.
        optVal := Buffer(4, 0)
        NumPut("Int", 1, optVal)
        DllCall("ws2_32\setsockopt", "UPtr", sock, "Int", 0xFFFF, "Int", 4, "Ptr", optVal, "Int", 4)

        ; sockaddr_in { family(2), port(2, network order), addr(4), zero(8) }
        addr := Buffer(16, 0)
        NumPut("UShort", LOCALAPI_AF_INET, addr, 0)
        NumPut("UShort", _LocalApiHtons(g_localApiPort), addr, 2)
        NumPut("UInt", 0x0100007F, addr, 4)        ; 127.0.0.1 in network byte order
        if (DllCall("ws2_32\bind", "UPtr", sock, "Ptr", addr, "Int", 16, "Int") != 0)
            throw Error("bind() failed (port " g_localApiPort " in use?)")
        if (DllCall("ws2_32\listen", "UPtr", sock, "Int", 16, "Int") != 0)
            throw Error("listen() failed")

        ; Hidden Gui gives us a clean hwnd to receive the async socket messages.
        if !(IsObject(g_localApiGui))
            g_localApiGui := Gui("+ToolWindow -Caption +Disabled")
        if !g_localApiMsgBound
        {
            OnMessage(LOCALAPI_WM_SOCKET, _LocalApiOnSocket)
            g_localApiMsgBound := true
        }

        DllCall("ws2_32\WSAAsyncSelect", "UPtr", sock, "Ptr", g_localApiGui.Hwnd
            , "UInt", LOCALAPI_WM_SOCKET, "Int", (LOCALAPI_FD_ACCEPT | LOCALAPI_FD_CLOSE), "Int")

        g_localApiListenSock := sock
        g_localApiClients := Map()
        g_localApiStarted := true
        return true
    }
    catch as e
    {
        try LogError("StartLocalApiServer", e)
        StopLocalApiServer()
        return false
    }
}

; Stops the server: closes all sockets, unbinds the message hook, WSACleanup.
StopLocalApiServer()
{
    global g_localApiListenSock, g_localApiClients, g_localApiStarted, g_localApiWsaUp
    global g_localApiMsgBound, LOCALAPI_WM_SOCKET

    if (IsObject(g_localApiClients))
    {
        for sock, _ in g_localApiClients.Clone()
            try DllCall("ws2_32\closesocket", "UPtr", sock)
    }
    g_localApiClients := Map()

    if (g_localApiListenSock)
        try DllCall("ws2_32\closesocket", "UPtr", g_localApiListenSock)
    g_localApiListenSock := 0

    if (g_localApiMsgBound)
    {
        try OnMessage(LOCALAPI_WM_SOCKET, _LocalApiOnSocket, 0)
        g_localApiMsgBound := false
    }

    if (g_localApiWsaUp)
    {
        try DllCall("ws2_32\WSACleanup")
        g_localApiWsaUp := false
    }
    g_localApiStarted := false
}

; OnMessage handler for socket events. wParam = socket handle,
; LOWORD(lParam) = event, HIWORD(lParam) = error code.
_LocalApiOnSocket(wParam, lParam, msg, hwnd)
{
    global g_localApiListenSock, g_localApiClients
    global LOCALAPI_FD_READ, LOCALAPI_FD_ACCEPT, LOCALAPI_FD_CLOSE, LOCALAPI_WM_SOCKET

    event := lParam & 0xFFFF
    sock  := wParam

    if (event = LOCALAPI_FD_ACCEPT)
    {
        client := DllCall("ws2_32\accept", "UPtr", g_localApiListenSock, "Ptr", 0, "Ptr", 0, "UPtr")
        if (client != 0 && client != -1)
        {
            g_localApiClients[client] := ""
            DllCall("ws2_32\WSAAsyncSelect", "UPtr", client, "Ptr", hwnd
                , "UInt", LOCALAPI_WM_SOCKET, "Int", (LOCALAPI_FD_READ | LOCALAPI_FD_CLOSE), "Int")
        }
        return 0
    }

    if (event = LOCALAPI_FD_READ)
    {
        _LocalApiReadClient(sock)
        return 0
    }

    if (event = LOCALAPI_FD_CLOSE)
    {
        try DllCall("ws2_32\closesocket", "UPtr", sock)
        if (g_localApiClients.Has(sock))
            g_localApiClients.Delete(sock)
        return 0
    }
    return 0
}

; Drains pending bytes from a client socket and, once a full HTTP request has
; arrived, routes it and writes the response.
_LocalApiReadClient(sock)
{
    global g_localApiClients, LOCALAPI_WSAEWOULDBLOCK

    if !g_localApiClients.Has(sock)
        g_localApiClients[sock] := ""

    buf := Buffer(8192)
    chunk := ""
    closed := false
    loop
    {
        n := DllCall("ws2_32\recv", "UPtr", sock, "Ptr", buf, "Int", 8192, "Int", 0, "Int")
        if (n > 0)
        {
            chunk .= StrGet(buf, n, "UTF-8")
            continue
        }
        if (n = 0)
        {
            closed := true
            break
        }
        ; n < 0
        if (DllCall("ws2_32\WSAGetLastError", "Int") = LOCALAPI_WSAEWOULDBLOCK)
            break
        closed := true
        break
    }

    data := g_localApiClients[sock] . chunk
    g_localApiClients[sock] := data

    headerEnd := InStr(data, "`r`n`r`n")
    if (headerEnd)
    {
        head := SubStr(data, 1, headerEnd - 1)
        body := SubStr(data, headerEnd + 4)
        contentLen := 0
        if RegExMatch(head, "im)^Content-Length:\s*(\d+)", &m)
            contentLen := Integer(m[1])
        bodyBytes := (body = "") ? 0 : StrPut(body, "UTF-8") - 1
        if (bodyBytes >= contentLen)
        {
            g_localApiClients.Delete(sock)
            _LocalApiServe(sock, head, body)
            return
        }
    }

    ; Request not complete yet — if the peer closed early, give up.
    if (closed)
    {
        try DllCall("ws2_32\closesocket", "UPtr", sock)
        if (g_localApiClients.Has(sock))
            g_localApiClients.Delete(sock)
    }
}

; Parses the request line off <head>, routes it, and sends the response.
_LocalApiServe(sock, head, body)
{
    method := "GET", rawPath := "/"
    firstLine := head
    if (p := InStr(head, "`r`n"))
        firstLine := SubStr(head, 1, p - 1)
    parts := StrSplit(firstLine, " ")
    if (parts.Length >= 2)
    {
        method  := parts[1]
        rawPath := parts[2]
    }

    if (method = "OPTIONS")
    {
        _LocalApiSend(sock, "204 No Content", "text/plain", "")
        return
    }

    resp := ""
    try
        resp := _LocalApiRoute(method, rawPath, body)
    catch as e
    {
        try LogError("LocalApiRoute", e)
        _LocalApiSend(sock, "500 Internal Server Error", "application/json", '{"error":"internal error"}')
        return
    }
    _LocalApiSend(sock, resp.Has("status") ? resp["status"] : "200 OK"
        , resp.Has("type") ? resp["type"] : "application/json"
        , resp.Has("body") ? resp["body"] : "")
}

; Routes a request to a handler. Returns Map("status","type","body").
; GET endpoints read live data; POST/DELETE mutate (apply in-memory now, persist
; + refresh the UI header deferred via SetTimer so we never reenter during the
; socket interrupt).
_LocalApiRoute(method, rawPath, body)
{
    global g_radarLastSnap, g_pinnedNodePaths

    path := rawPath
    query := ""
    if (qp := InStr(rawPath, "?"))
    {
        path  := SubStr(rawPath, 1, qp - 1)
        query := SubStr(rawPath, qp + 1)
    }
    q := _LocalApiParseQuery(query)
    snap := (IsSet(g_radarLastSnap) && g_radarLastSnap is Map) ? g_radarLastSnap : 0

    ; ── Reads ────────────────────────────────────────────────────────────────
    if (method = "GET")
    {
        if (path = "/" || path = "/state")
            return _LocalApiOk(_LocalApiBuildStateJson())
        if (path = "/entities")
            return _LocalApiOk(_BuildEntitiesJson(snap))
        if (path = "/api/groups")
            return _LocalApiOk(BuildGroupsHeaderJson())
        if (path = "/api/alerts")
            return _LocalApiOk(BuildAlertsHeaderJson())
        if (path = "/api/config")
            return _LocalApiOk(_LocalApiBuildConfigJson())
        if (path = "/api/watchlist")
            return _LocalApiOk(_LocalApiBuildWatchlistJson())
        if (path = "/api/names")
            return _LocalApiOk(_LocalApiSearchNames(q.Has("q") ? q["q"] : ""))
    }

    ; ── Writes ───────────────────────────────────────────────────────────────
    if (method = "POST")
    {
        parsed := (body != "") ? JsonFull_Parse(body) : ""

        if (path = "/api/groups")
        {
            if !(IsObject(parsed) && parsed is Array)
                return _LocalApiErr("400 Bad Request", "expected a JSON array of groups")
            _ApplyEntityGroups(parsed)
            SetTimer(SaveEntityGroups, -1)
            SetTimer(PushHeaderToWebView, -50)
            return _LocalApiOk('{"ok":true,"count":' _LocalApiArrLen(parsed) '}')
        }
        if (path = "/api/alerts")
        {
            if !(IsObject(parsed) && parsed is Map && parsed.Has("key"))
                return _LocalApiErr("400 Bad Request", "expected {key, value}")
            _ApplyAlertSetting(parsed["key"], parsed.Has("value") ? parsed["value"] : "")
            SetTimer(SaveEntityAlertsConfig, -1)
            SetTimer(PushHeaderToWebView, -50)
            return _LocalApiOk('{"ok":true}')
        }
        if (path = "/api/config")
        {
            if !(IsObject(parsed) && parsed is Map)
                return _LocalApiErr("400 Bad Request", "expected a JSON object of settings")
            applied := _LocalApiApplyConfig(parsed)
            return _LocalApiOk('{"ok":true,"applied":' applied "}")
        }
        if (path = "/api/watchlist")
        {
            if !(IsObject(parsed) && parsed is Map && parsed.Has("path"))
                return _LocalApiErr("400 Bad Request", "expected {path}")
            _DispatchBridgeCall("PinPath", [String(parsed["path"])])
            return _LocalApiOk('{"ok":true}')
        }
    }

    if (method = "DELETE")
    {
        if (path = "/api/watchlist")
        {
            target := q.Has("path") ? q["path"] : ""
            removed := _LocalApiUnpin(target)
            return _LocalApiOk('{"ok":true,"removed":' removed "}")
        }
    }

    return _LocalApiErr("404 Not Found", "no such endpoint: " method " " path)
}

; ── Response helpers ──────────────────────────────────────────────────────────
_LocalApiOk(jsonBody) => Map("status", "200 OK", "type", "application/json", "body", jsonBody)
_LocalApiErr(status, message) => Map("status", status, "type", "application/json"
    , "body", '{"error":' _LocalApiJsStr(message) "}")

; Sends an HTTP/1.1 response and closes the socket. Switches the socket back to
; blocking first (loopback, payloads are small) so a single send loop suffices.
_LocalApiSend(sock, status, contentType, bodyText)
{
    global g_localApiGui, LOCALAPI_WM_SOCKET, LOCALAPI_FIONBIO

    ; Cancel async notifications and return the socket to blocking mode.
    try DllCall("ws2_32\WSAAsyncSelect", "UPtr", sock, "Ptr", g_localApiGui.Hwnd
        , "UInt", LOCALAPI_WM_SOCKET, "Int", 0, "Int")
    nb := Buffer(4, 0)              ; FIONBIO arg = 0 → blocking
    try DllCall("ws2_32\ioctlsocket", "UPtr", sock, "Int", LOCALAPI_FIONBIO, "Ptr", nb)

    bodyBytes := (bodyText = "") ? 0 : StrPut(bodyText, "UTF-8") - 1
    hdr := "HTTP/1.1 " status "`r`n"
        . "Content-Type: " contentType "`r`n"
        . "Content-Length: " bodyBytes "`r`n"
        . "Access-Control-Allow-Origin: *`r`n"
        . "Cache-Control: no-store`r`n"
        . "Connection: close`r`n`r`n"
    full := hdr . bodyText
    size := StrPut(full, "UTF-8") - 1
    sbuf := Buffer(size + 1)
    StrPut(full, sbuf, "UTF-8")

    sent := 0
    while (sent < size)
    {
        n := DllCall("ws2_32\send", "UPtr", sock, "Ptr", sbuf.Ptr + sent, "Int", size - sent, "Int", 0, "Int")
        if (n <= 0)
            break
        sent += n
    }
    try DllCall("ws2_32\closesocket", "UPtr", sock)
}

; ── Builders ──────────────────────────────────────────────────────────────────

; Compact live-state JSON: connection, area, vitals and entity counts.
_LocalApiBuildStateJson()
{
    global g_radarLastSnap, g_isConnected
    snap := (IsSet(g_radarLastSnap) && g_radarLastSnap is Map) ? g_radarLastSnap : 0

    st := Map()
    st["connected"] := (IsSet(g_isConnected) && g_isConnected) ? true : false
    if !IsObject(snap)
    {
        st["inGame"] := false
        return JsonFull_Stringify(st)
    }
    st["inGame"] := true
    st["stateName"] := snap.Has("currentStateName") ? String(snap["currentStateName"]) : ""
    st["areaLevel"] := snap.Has("areaLevel") ? snap["areaLevel"] : 0

    wa := snap.Has("worldAreaDat") ? snap["worldAreaDat"] : 0
    if IsObject(wa)
    {
        st["areaId"]    := wa.Has("id")   ? String(wa["id"])   : ""
        st["areaName"]  := wa.Has("name") ? String(wa["name"]) : ""
        st["act"]       := wa.Has("act")  ? wa["act"]          : 0
        st["isTown"]    := (wa.Has("isTown")    && wa["isTown"])    ? true : false
        st["isHideout"] := (wa.Has("isHideout") && wa["isHideout"]) ? true : false
    }

    pv := snap.Has("playerVitals") ? snap["playerVitals"] : 0
    stats := (IsObject(pv) && pv.Has("stats")) ? pv["stats"] : 0
    if IsObject(stats)
    {
        st["life"]         := Map("current", stats.Has("lifeCurrent") ? stats["lifeCurrent"] : 0, "max", stats.Has("lifeMax") ? stats["lifeMax"] : 0)
        st["mana"]         := Map("current", stats.Has("manaCurrent") ? stats["manaCurrent"] : 0, "max", stats.Has("manaMax") ? stats["manaMax"] : 0)
        st["energyShield"] := Map("current", stats.Has("esCurrent")   ? stats["esCurrent"]   : 0, "max", stats.Has("esMax")   ? stats["esMax"]   : 0)
        st["alive"]        := (stats.Has("isAlive") && stats["isAlive"]) ? true : false
    }

    inGame := snap.Has("inGameState") ? snap["inGameState"] : 0
    area := (IsObject(inGame) && inGame.Has("areaInstance")) ? inGame["areaInstance"] : 0
    if IsObject(area)
    {
        st["areaHash"] := area.Has("currentAreaHash") ? area["currentAreaHash"] : 0
        ae := area.Has("awakeEntities") ? area["awakeEntities"] : 0
        se := area.Has("sleepingEntities") ? area["sleepingEntities"] : 0
        st["awakeCount"]    := (IsObject(ae) && ae.Has("sample") && IsObject(ae["sample"])) ? ae["sample"].Length : 0
        st["sleepingCount"] := (IsObject(se) && se.Has("sample") && IsObject(se["sample"])) ? se["sample"].Length : 0
        prc := area.Has("playerRenderComponent") ? area["playerRenderComponent"] : 0
        if IsObject(prc)
        {
            gp := prc.Has("gridPosition") ? prc["gridPosition"] : 0
            if IsObject(gp)
                st["playerGrid"] := Map("x", gp.Has("x") ? gp["x"] : 0, "y", gp.Has("y") ? gp["y"] : 0)
        }
    }
    return JsonFull_Stringify(st)
}

; Current values of the settings exposed for read/update via /api/config.
_LocalApiBuildConfigJson()
{
    global g_lifeThresholdPercent, g_manaThresholdPercent, g_radarEnabled, g_playerHudEnabled
    global g_radarAlpha, g_mapHackEnabled, g_zoneNavEnabled, g_rangeCirclesEnabled
    global g_autoFlaskEnabled, g_autoPilotEnabled, g_debugMode, g_updatesPaused
    global g_overlayStatusTextEnabled, g_panelDetectionEnabled
    global g_localApiEnabled, g_localApiPort

    c := Map(
        "lifeThreshold",     g_lifeThresholdPercent,
        "manaThreshold",     g_manaThresholdPercent,
        "radarEnabled",      g_radarEnabled ? 1 : 0,
        "playerHud",         g_playerHudEnabled ? 1 : 0,
        "radarAlpha",        g_radarAlpha,
        "mapHack",           g_mapHackEnabled ? 1 : 0,
        "zoneNav",           g_zoneNavEnabled ? 1 : 0,
        "rangeCircles",      g_rangeCirclesEnabled ? 1 : 0,
        "autoFlask",         g_autoFlaskEnabled ? 1 : 0,
        "autoPilot",         g_autoPilotEnabled ? 1 : 0,
        "debug",             g_debugMode ? 1 : 0,
        "paused",            g_updatesPaused ? 1 : 0,
        "overlayStatusText", g_overlayStatusTextEnabled ? 1 : 0,
        "panelDetection",    g_panelDetectionEnabled ? 1 : 0,
        "localApiPort",      g_localApiPort
    )
    return JsonFull_Stringify(c)
}

; JSON array of the current watchlist (pinned entity paths).
_LocalApiBuildWatchlistJson()
{
    global g_pinnedNodePaths
    arr := []
    if (IsObject(g_pinnedNodePaths))
    {
        for _, p in g_pinnedNodePaths
            arr.Push(String(p))
    }
    return JsonFull_Stringify(arr)
}

; ── Mutators ──────────────────────────────────────────────────────────────────

; Applies a subset of settings sent to /api/config. Each known key is routed
; through the existing bridge command so all side effects (overlay create/destroy,
; persistence, header refresh) stay identical to flipping the toggle in the UI.
; Returns the number of settings applied.
_LocalApiApplyConfig(obj)
{
    global g_radarEnabled, g_playerHudEnabled, g_mapHackEnabled, g_zoneNavEnabled
    global g_rangeCirclesEnabled, g_autoFlaskEnabled, g_autoPilotEnabled, g_debugMode
    global g_updatesPaused, g_overlayStatusTextEnabled, g_panelDetectionEnabled
    global g_lifeThresholdPercent, g_manaThresholdPercent, g_radarAlpha

    ; key → current value, and key → the existing toggle command that owns the
    ; side effects. Keeping these explicit (no dynamic var refs) avoids surprises.
    curBool := Map(
        "radarEnabled",      g_radarEnabled ? true : false,
        "playerHud",         g_playerHudEnabled ? true : false,
        "mapHack",           g_mapHackEnabled ? true : false,
        "zoneNav",           g_zoneNavEnabled ? true : false,
        "rangeCircles",      g_rangeCirclesEnabled ? true : false,
        "autoFlask",         g_autoFlaskEnabled ? true : false,
        "autoPilot",         g_autoPilotEnabled ? true : false,
        "debug",             g_debugMode ? true : false,
        "paused",            g_updatesPaused ? true : false,
        "overlayStatusText", g_overlayStatusTextEnabled ? true : false,
        "panelDetection",    g_panelDetectionEnabled ? true : false
    )
    cmdBool := Map(
        "radarEnabled",      "ToggleRadar",
        "playerHud",         "TogglePlayerHud",
        "mapHack",           "ToggleMapHack",
        "zoneNav",           "ToggleZoneNav",
        "rangeCircles",      "ToggleRangeCircles",
        "autoFlask",         "ToggleAutoFlask",
        "autoPilot",         "ToggleAutoPilot",
        "debug",             "ToggleDebug",
        "paused",            "TogglePause",
        "overlayStatusText", "ToggleOverlayStatusText",
        "panelDetection",    "TogglePanelDetection"
    )

    applied := 0
    for key, val in obj
    {
        if (cmdBool.Has(key))
        {
            want := _LocalApiTruthy(val)
            if (want != curBool[key])
                _DispatchBridgeCall(cmdBool[key], [])
            applied += 1
            continue
        }
        if (key = "lifeThreshold")
        {
            _DispatchBridgeCall("SetThresholds", [_LocalApiClampInt(val, 0, 100), g_manaThresholdPercent])
            applied += 1
        }
        else if (key = "manaThreshold")
        {
            _DispatchBridgeCall("SetThresholds", [g_lifeThresholdPercent, _LocalApiClampInt(val, 0, 100)])
            applied += 1
        }
        else if (key = "radarAlpha")
        {
            _DispatchBridgeCall("SetRadarAlpha", [_LocalApiClampInt(val, 0, 255)])
            applied += 1
        }
    }
    return applied
}

; Removes a pinned path (or clears all when <target> is empty). Returns count removed.
_LocalApiUnpin(target)
{
    global g_pinnedNodePaths
    if !(IsObject(g_pinnedNodePaths))
        return 0
    if (target = "")
    {
        n := g_pinnedNodePaths.Length
        g_pinnedNodePaths := []
        SetTimer(PushWatchlistToWebView, -1)
        return n
    }
    removed := 0
    keep := []
    for _, p in g_pinnedNodePaths
    {
        if (String(p) = target)
            removed += 1
        else
            keep.Push(p)
    }
    if (removed)
    {
        g_pinnedNodePaths := keep
        SetTimer(PushWatchlistToWebView, -1)
    }
    return removed
}

; Substring-searches the monster name table (data/monster_name_map.tsv), lazily
; loaded on first use. Returns a JSON array of {path, name}, capped at 50.
_LocalApiSearchNames(query)
{
    global g_localApiNameRows
    if !(IsObject(g_localApiNameRows))
        g_localApiNameRows := _LocalApiLoadNames()

    needle := StrLower(Trim(query))
    out := []
    if (needle != "")
    {
        for _, row in g_localApiNameRows
        {
            if (InStr(StrLower(row[1]), needle) || InStr(StrLower(row[2]), needle))
            {
                out.Push(Map("path", row[1], "name", row[2]))
                if (out.Length >= 50)
                    break
            }
        }
    }
    return JsonFull_Stringify(out)
}

; Loads the monster name TSV into an Array of [path, name]. Returns [] on failure.
_LocalApiLoadNames()
{
    rows := []
    f := A_ScriptDir "\data\monster_name_map.tsv"
    if !FileExist(f)
        return rows
    try
    {
        txt := FileRead(f, "UTF-8")
        first := true
        loop parse, txt, "`n", "`r"
        {
            if (first)            ; skip header row
            {
                first := false
                continue
            }
            if (A_LoopField = "")
                continue
            cols := StrSplit(A_LoopField, "`t")
            if (cols.Length >= 2 && cols[1] != "")
                rows.Push([cols[1], cols[2]])
        }
    }
    return rows
}

; ── Small utilities ───────────────────────────────────────────────────────────
_LocalApiHtons(port) => ((port & 0xFF) << 8) | ((port >> 8) & 0xFF)
_LocalApiArrLen(a) => (IsObject(a) && a is Array) ? a.Length : 0

; Coerces a JSON-parsed value (1/0, "true"/"false", numbers) to a boolean.
_LocalApiTruthy(v)
{
    if (v = "" || v = 0 || v = "0" || v = "false" || v = "False")
        return false
    return true
}

; Parses a numeric value and clamps it into [lo, hi].
_LocalApiClampInt(v, lo, hi)
{
    n := 0
    try n := Integer(v)
    return Max(lo, Min(hi, n))
}

; Minimal JSON string escaper for our hand-built error bodies.
_LocalApiJsStr(s)
{
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`n", "\n")
    return '"' s '"'
}

; Parses a URL query string into a Map of decoded key→value pairs.
_LocalApiParseQuery(query)
{
    m := Map()
    if (query = "")
        return m
    for _, pair in StrSplit(query, "&")
    {
        if (pair = "")
            continue
        eq := InStr(pair, "=")
        if (eq)
            m[_LocalApiUrlDecode(SubStr(pair, 1, eq - 1))] := _LocalApiUrlDecode(SubStr(pair, eq + 1))
        else
            m[_LocalApiUrlDecode(pair)] := ""
    }
    return m
}

; Decodes percent-encoding and '+' in a URL component.
_LocalApiUrlDecode(s)
{
    s := StrReplace(s, "+", " ")
    out := ""
    i := 1
    len := StrLen(s)
    while (i <= len)
    {
        c := SubStr(s, i, 1)
        if (c = "%" && i + 2 <= len)
        {
            hex := SubStr(s, i + 1, 2)
            if RegExMatch(hex, "^[0-9A-Fa-f]{2}$")
            {
                out .= Chr(Integer("0x" hex))
                i += 3
                continue
            }
        }
        out .= c
        i += 1
    }
    return out
}
