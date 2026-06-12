; AutoFlask.ahk
; Automatic flask usage logic and fast radar overlay update.
;
; Contains: UpdateRadarFast, TryAutoFlaskFast, TryAutoFlask, IsStrictInGameState, TryUseFlaskSlot,
; ProcessPendingFlaskVerification, ResolvePoEWindow, SendFlaskKeyToGame,
; SendChatSlashCommand, LoadFlaskHotkeysFromConfig, TryParseFlaskBindingLine, NormalizeConfigKeyToSend
;
; Included by InGameStateMonitor.ahk

; Timer callback fired every 100 ms; reads a lightweight radar snapshot and renders the overlay.
; Uses a reentrancy guard to prevent overlapping calls from stacking up.
UpdateRadarFast()
{
    static _running := false
    if _running
        return
    ; Skip all reads while not attached to PoE2. The poll timer
    ; (EnsureConnected) handles reattachment; running this loop without
    ; a valid handle just spams ReadProcessMemory failures.
    global g_isConnected
    if (IsSet(g_isConnected) && !g_isConnected)
        return
    _running := true
    try
    {
        global g_reader, g_overlayManager, g_radarLastSnap, g_updatesPaused, g_radarReadMs, g_radarRenderMs
        global g_autoPilotEnabled, g_vitalsNeedsCombat, Profiler
        if g_updatesPaused
        {
            if IsObject(g_overlayManager)
                g_overlayManager.HideAll()
            return
        }
        if !IsObject(g_reader)
            return

        radarReadStart := A_TickCount
        Profiler.Begin("tick.read")
        radarSnap := g_reader.ReadRadarSnapshot()
        Profiler.End("tick.read")
        g_radarReadMs := A_TickCount - radarReadStart

        ; Grace period: tolerate brief GC-related read failures instead of
        ; immediately hiding the overlay and stopping automation.
        static _lastValidSnap := 0
        static _overlayHideTick := 0
        static _OVERLAY_GRACE_MS := 800

        if radarSnap
        {
            _lastValidSnap := radarSnap
            _overlayHideTick := 0
        }
        else
        {
            ; Snapshot failed — use last valid for combat/exploration,
            ; and start the overlay hide grace timer
            if _lastValidSnap
                radarSnap := _lastValidSnap
            if (_overlayHideTick = 0)
                _overlayHideTick := A_TickCount
            if (!_lastValidSnap || (A_TickCount - _overlayHideTick) > _OVERLAY_GRACE_MS)
            {
                ; Hard read failure: hide the play overlays, leave the banner /
                ; focus overlay untouched (they self-resolve next valid tick).
                if IsObject(g_overlayManager)
                {
                    g_overlayManager.Get("radar").Hide()
                    g_overlayManager.Get("vitals").Hide()
                }
                return
            }
        }
        g_radarLastSnap := radarSnap  ; cache for Dump Entities button
        HotkeyBindingsOnAreaChange(radarSnap)

        ; ── AutoPilot (state machine: combat → explore, owns shared guards) ──
        Profiler.Begin("tick.autopilot")
        TryAutoPilot(radarSnap)
        Profiler.End("tick.autopilot")

        ; ── Standalone combat presence ──────────────────────────────────────
        ; The AutoPilot loop only maintains g_combatState while it is enabled.
        ; When the bot is off but a feature needs combat (e.g. a Vitals bar with
        ; an "In Combat" condition), keep the flag fresh with a lightweight,
        ; proximity-only detector. Skipped entirely when nothing needs it.
        if (!g_autoPilotEnabled && IsSet(g_vitalsNeedsCombat) && g_vitalsNeedsCombat)
            UpdateCombatPresence(radarSnap)

        ; ── Entity alerts + banner — every tick, outside the claim chain, map-independent ──
        Profiler.Begin("tick.alerts")
        TryEntityAlerts(radarSnap)
        Profiler.End("tick.alerts")

        ; ── Atlas overlay snapshot (self-gated on g_atlasOverlayEnabled, throttled) ──
        TryBuildAtlasRender(radarSnap)
        if !IsObject(g_overlayManager)
            return

        ; ── Drive every overlay through the manager ──────────────────────────
        ; Refresh the shared context (snapshot, reader, game-window rect,
        ; foreground state); the manager evaluates the play-overlay gate once and
        ; runs each overlay's Update(ctx). All per-overlay visibility / layout /
        ; draw logic now lives in the overlay classes + PlayOverlayPolicy.
        ctx := g_overlayManager.context
        ctx.snapshot     := radarSnap
        ctx.reader       := g_reader
        ctx.paused       := g_updatesPaused
        ctx.currentState := radarSnap.Has("currentStateName") ? radarSnap["currentStateName"] : ""

        gameHwnd := ResolvePoEWindow()
        ctx.gameHwnd := gameHwnd
        if gameHwnd
        {
            global g_webGui
            ctx.gameActive  := WinActive("ahk_id " gameHwnd) ? true : false
            ctx.toolFocused := (IsObject(g_webGui) && WinActive("ahk_id " g_webGui.Hwnd)) ? true : false
            gwX := 0, gwY := 0, gwW := 0, gwH := 0
            try WinGetPos(&gwX, &gwY, &gwW, &gwH, "ahk_id " gameHwnd)
            ctx.gwX := gwX, ctx.gwY := gwY, ctx.gwW := gwW, ctx.gwH := gwH
        }
        else
        {
            ctx.gameActive := false, ctx.toolFocused := false
            ctx.gwX := 0, ctx.gwY := 0, ctx.gwW := 0, ctx.gwH := 0
        }

        radarRenderStart := A_TickCount
        Profiler.Begin("tick.overlays")
        g_overlayManager.Tick(ctx)
        Profiler.End("tick.overlays")
        g_radarRenderMs := A_TickCount - radarRenderStart

        ; ── Debug panel push (every 500 ms), using the resolved gate ─────────
        static _debugPanelPushTick := 0
        if (A_TickCount - _debugPanelPushTick > 500)
        {
            PushDebugPanelsToWebView(radarSnap, ctx.gate["allowed"], ctx.gate["reason"])
            PushRadarDebugToWebView(ctx.gate["allowed"], ctx.gate["reason"])
            _debugPanelPushTick := A_TickCount
        }
    }
    catch as ex
    {
        ; Timer callback must never bubble exceptions.
        LogError("UpdateRadarFast", ex)
    }
    finally
    {
        _running := false
    }
}

; Timer callback fired every 150 ms; reads a minimal flask/vitals snapshot and delegates to TryAutoFlask.
; Uses a reentrancy guard to prevent overlapping calls from stacking up.
TryAutoFlaskFast()
{
    static _running := false
    if _running
        return
    global g_isConnected
    if (IsSet(g_isConnected) && !g_isConnected)
        return
    _running := true
    try
    {
        global g_reader, g_autoFlaskEnabled, g_updatesPaused
        if (g_updatesPaused || !g_autoFlaskEnabled)
            return
        flask_snap := g_reader.ReadAutoFlaskSnapshot()
        if flask_snap
            TryAutoFlask(flask_snap)
    }
    catch as ex
    {
        ; Timer callback must never bubble exceptions, otherwise AHK can spam dialogs.
        LogError("TryAutoFlaskFast", ex)
    }
    finally
    {
        _running := false
    }
}

; Core flask logic: checks life/mana against thresholds and triggers flask slots as needed.
; Skips execution in town, hideout, loading screens, or when the game state is not fully in-game.
; Params: snapshot - full or autoflask-mode snapshot Map from ReadSnapshot/ReadAutoFlaskSnapshot
TryAutoFlask(snapshot)
{
    global g_autoFlaskEnabled, g_lifeThresholdPercent, g_manaThresholdPercent, g_autoFlaskLastReason, g_pendingFlaskVerifyBySlot

    if !g_autoFlaskEnabled
    {
        g_autoFlaskLastReason := "disabled"
        return
    }

    gameHwnd := ResolvePoEWindow()
    if !gameHwnd
    {
        g_autoFlaskLastReason := "game-window-missing"
        return
    }

    stateName := (snapshot && snapshot.Has("currentStateName")) ? snapshot["currentStateName"] : ""
    if !IsStrictInGameState(snapshot)
    {
        try g_pendingFlaskVerifyBySlot.Clear()
        g_autoFlaskLastReason := "state-blocked(" (stateName = "" ? "unknown" : stateName) ")"
        return
    }

    inGame := snapshot.Has("inGameState") ? snapshot["inGameState"] : 0
    if !inGame
    {
        g_autoFlaskLastReason := "ingame-null"
        return
    }

    worldDet := inGame.Has("worldDataDetails") ? inGame["worldDataDetails"] : 0
    worldArea := (worldDet && worldDet.Has("worldAreaDat")) ? worldDet["worldAreaDat"] : 0
    if (worldArea)
    {
        if ((worldArea.Has("isTown") && worldArea["isTown"]) || (worldArea.Has("isHideout") && worldArea["isHideout"]))
        {
            g_autoFlaskLastReason := "town-hideout"
            return
        }
    }

    areaInst := inGame.Has("areaInstance") ? inGame["areaInstance"] : 0
    if !areaInst
    {
        g_autoFlaskLastReason := "area-null"
        return
    }

    playerVitals := areaInst.Has("playerVitals") ? areaInst["playerVitals"] : 0
    if !playerVitals || !playerVitals.Has("stats")
    {
        g_autoFlaskLastReason := "vitals-missing"
        return
    }

    stats := playerVitals["stats"]
    lifePct := SafePercent(stats["lifeCurrent"], stats["lifeMax"])
    manaPct := SafePercent(stats["manaCurrent"], stats["manaMax"])

    srv := areaInst.Has("serverData") ? areaInst["serverData"] : 0
    flaskInv := (srv && srv.Has("flaskInventory")) ? srv["flaskInventory"] : 0
    slots := (flaskInv && flaskInv.Has("flaskSlots")) ? flaskInv["flaskSlots"] : 0
    if !slots
    {
        g_autoFlaskLastReason := "flask-slots-missing"
        return
    }

    verifyReason := ProcessPendingFlaskVerification(slots)

    triggered := false
    attempted := false
    failDetails := []

    if (lifePct >= 0 && lifePct <= g_lifeThresholdPercent)
    {
        attempted := true
        slotReason := ""
        if TryUseFlaskSlot(slots, 1, gameHwnd, &slotReason)
        {
            triggered := true
            failDetails.Push(slotReason)
        }
        else if (slotReason != "")
            failDetails.Push(slotReason)
    }

    if (manaPct >= 0 && manaPct <= g_manaThresholdPercent)
    {
        attempted := true
        slotReason := ""
        if TryUseFlaskSlot(slots, 2, gameHwnd, &slotReason)
        {
            triggered := true
            failDetails.Push(slotReason)
        }
        else if (slotReason != "")
            failDetails.Push(slotReason)
    }

    if (triggered)
    {
        detail := ""
        for _, reason in failDetails
            detail .= (detail = "" ? "" : "|") reason
        if (verifyReason != "")
            detail := (detail = "" ? verifyReason : verifyReason "|" detail)
        g_autoFlaskLastReason := (detail = "" ? "triggered" : "triggered|" detail)
    }
    else if (attempted)
    {
        detail := ""
        for _, reason in failDetails
            detail .= (detail = "" ? "" : "|") reason
        if (verifyReason != "")
            detail := (detail = "" ? verifyReason : verifyReason "|" detail)
        g_autoFlaskLastReason := (detail = "" ? "attempted-no-use" : detail)
    }
    else
    {
        base := "no-threshold(lp=" Round(lifePct) " mp=" Round(manaPct) ")"
        g_autoFlaskLastReason := (verifyReason = "" ? base : verifyReason "|" base)
    }
}

; Returns true when the snapshot represents a live in-game session (entities/area/player
; data present). Used to gate auto-flask so it doesn't fire on the login or character
; select screen. Don't strictly require currentStateName == "InGameState": after a zone
; change the game keeps a transitional state on top of the state stack for tens of
; seconds while play is fully resumed, and the state-pointer offsets occasionally
; produce a 'GameNotLoaded' false negative. Gate on actual data instead.
IsStrictInGameState(snapshot)
{
    if !snapshot
        return false

    ; Hard reject only the states that definitely have no character/area.
    nonGameStates := Map(
        "PreGameState", true,
        "LoginState", true,
        "WaitingState", true,
        "CreateCharacterState", true,
        "SelectCharacterState", true,
        "DeleteCharacterState", true,
        "ChangePasswordState", true,
        "CreditsState", true,
        "LoadingState", true
    )
    name := snapshot.Has("currentStateName") ? snapshot["currentStateName"] : ""
    if (name != "" && nonGameStates.Has(name))
        return false

    ; Need a player render component (proves the character exists in the world).
    inGs := snapshot.Has("inGameState") ? snapshot["inGameState"] : 0
    if !(inGs && IsObject(inGs))
        return false
    area := inGs.Has("areaInstance") ? inGs["areaInstance"] : 0
    if !(area && IsObject(area))
        return false
    pr := area.Has("playerRenderComponent") ? area["playerRenderComponent"] : 0
    return (pr && IsObject(pr)) ? true : false
}

; Attempts to activate one flask slot; checks buff state, charges, cooldown, and key availability.
; Params: slots - flask slot Map; slotNumber - 1-indexed slot; slotReason - out: human-readable outcome
; Returns: true if the key press was successfully sent to the game
TryUseFlaskSlot(slots, slotNumber, gameHwnd, &slotReason := "")
{
    global g_flaskUseCooldownMs, g_lastFlaskUseBySlot, g_flaskKeyBySlot, g_autoFlaskLastReason, g_pendingFlaskVerifyBySlot
    slotReason := ""

    if (g_pendingFlaskVerifyBySlot.Has(slotNumber))
    {
        slotReason := "slot" slotNumber "-awaiting-confirm"
        return false
    }

    if !slots || !slots.Has(slotNumber)
    {
        slotReason := "slot" slotNumber "-missing"
        return false
    }

    slot := slots[slotNumber]
    if !slot
    {
        slotReason := "slot" slotNumber "-null"
        return false
    }

    if (slot.Has("activeByBuff") && slot["activeByBuff"])
    {
        slotReason := "slot" slotNumber "-already-active"
        return false
    }

    fs := slot.Has("flaskStats") ? slot["flaskStats"] : 0
    if !fs
    {
        iep := slot.Has("itemEntityPtr") ? slot["itemEntityPtr"] : 0
        src := slot.Has("source") ? slot["source"] : "?"
        slotReason := "slot" slotNumber "-no-stats(src=" src ",iep=" Format("0x{:X}", iep) ")"
        g_autoFlaskLastReason := slotReason
        return false
    }

    current := fs.Has("current") ? fs["current"] : 0
    perUse := fs.Has("perUse") ? fs["perUse"] : 0
    if (perUse <= 0 || current < perUse)
    {
        slotReason := "slot" slotNumber "-no-charges(cur=" current "/use=" perUse ")"
        g_autoFlaskLastReason := slotReason
        return false
    }

    now := A_TickCount
    last := g_lastFlaskUseBySlot.Has(slotNumber) ? g_lastFlaskUseBySlot[slotNumber] : 0
    if (now - last < g_flaskUseCooldownMs)
    {
        slotReason := "slot" slotNumber "-cooldown"
        g_autoFlaskLastReason := slotReason
        return false
    }

    if !g_flaskKeyBySlot.Has(slotNumber)
    {
        slotReason := "slot" slotNumber "-key-missing"
        return false
    }

    sendKey := g_flaskKeyBySlot[slotNumber]
    if (sendKey = "")
    {
        slotReason := "slot" slotNumber "-key-empty"
        return false
    }

    if !SendFlaskKeyToGame(sendKey, gameHwnd)
    {
        slotReason := "slot" slotNumber "-send-failed(key=" sendKey ")"
        g_autoFlaskLastReason := slotReason
        return false
    }

    g_lastFlaskUseBySlot[slotNumber] := now
    g_pendingFlaskVerifyBySlot[slotNumber] := Map(
        "sentAt", now,
        "preCurrent", current,
        "perUse", perUse,
        "key", sendKey
    )
    slotReason := "slot" slotNumber "-sent(key=" sendKey ",cur=" current "/use=" perUse ")"
    return true
}

; Checks previously-sent flask activations against the current slot state to confirm or retry them.
; Returns: pipe-separated status string describing each slot outcome (e.g. "slot1-confirm(cur:5->4)")
ProcessPendingFlaskVerification(slots)
{
    global g_pendingFlaskVerifyBySlot, g_lastFlaskUseBySlot

    if !g_pendingFlaskVerifyBySlot || (g_pendingFlaskVerifyBySlot.Count = 0)
        return ""

    now := A_TickCount
    parts := []
    timeoutMs := 650

    for slotNumber, info in g_pendingFlaskVerifyBySlot.Clone()
    {
        if !slots || !slots.Has(slotNumber)
            continue

        slot := slots[slotNumber]
        fs := (slot && slot.Has("flaskStats")) ? slot["flaskStats"] : 0
        if !fs
            continue

        cur := fs.Has("current") ? fs["current"] : 0
        pre := info.Has("preCurrent") ? info["preCurrent"] : cur
        activeByBuff := (slot && slot.Has("activeByBuff") && slot["activeByBuff"])

        if (cur < pre || activeByBuff)
        {
            g_pendingFlaskVerifyBySlot.Delete(slotNumber)
            parts.Push("slot" slotNumber "-confirm(cur:" pre "->" cur ")")
            continue
        }

        sentAt := info.Has("sentAt") ? info["sentAt"] : now
        if (now - sentAt > timeoutMs)
        {
            g_pendingFlaskVerifyBySlot.Delete(slotNumber)
            g_lastFlaskUseBySlot[slotNumber] := 0
            parts.Push("slot" slotNumber "-unconfirmed-retry")
        }
    }

    if (parts.Length = 0)
        return ""

    text := ""
    for _, part in parts
        text .= (text = "" ? "" : "|") part
    return text
}

; Returns the HWND of the running Path of Exile 2 window, checking both Steam and standalone executables.
; Returns: window handle, or 0 if the game is not running
ResolvePoEWindow()
{
    return GetPoeMainWindowHwnd()
}

; Sends a keystroke to the PoE2 window via keybd_event (Win32 API).
; Bypasses UIPI when the game runs elevated, unlike ControlSend/SendInput.
; Params: sendKey - AHK key name; gameHwnd - target window HWND
; Returns: true if key was sent
; Sends a keystroke to the PoE2 window via keybd_event (Win32 API).
; KeyDown is sent immediately; KeyUp is fired after KEY_UP_DELAY_MS via SetTimer.
; Bypasses UIPI when the game runs elevated, unlike ControlSend/SendInput.
SendFlaskKeyToGame(sendKey, gameHwnd)
{
    static KEY_UP_DELAY_MS := 20

    if (sendKey = "" || !gameHwnd)
        return false

    vk := GetKeyVK(sendKey)
    if (!vk)
        return false

    ; KeyDown immediately
    DllCall("keybd_event", "uchar", vk, "uchar", 0, "uint", 0, "uptr", 0)

    ; KeyUp after 20ms — non-blocking via SetTimer
    ; Closure captures vk as a copy (AHK v2: variables in closures are by-value captures)
    keyUpFn := () => DllCall("keybd_event", "uchar", vk, "uchar", 0, "uint", 0x0002, "uptr", 0)
    SetTimer(keyUpFn, -KEY_UP_DELAY_MS)   ; negative = one-shot fire

    return true
}

; Opens the in-game chat and types a slash command — non-blocking version.
; The three steps (open chat / clear, wait, send command) are chained via SetTimer.
; Params: cmd - slash command string, must begin with "/"
; Returns: true if the command was sent successfully
SendChatSlashCommand(cmd)
{
    global g_lastSnapshotForUi

    if (cmd = "" || SubStr(cmd, 1, 1) != "/")
        return false

    gameHwnd := ResolvePoEWindow()
    if !gameHwnd
        return false

    gameWin := "ahk_id " gameHwnd

    isChatActive := false
    try {
        inGame := (g_lastSnapshotForUi && g_lastSnapshotForUi.Has("inGameState")) ? g_lastSnapshotForUi["inGameState"] : 0
        uiElems := (inGame && inGame.Has("importantUiElements")) ? inGame["importantUiElements"] : 0
        if (uiElems && uiElems.Has("isChatActive"))
            isChatActive := uiElems["isChatActive"]
    }

    if isChatActive
    {
        ; Chat already open: Ctrl+A + End, wait 30ms, then send the command
        ControlSend("^a", , gameWin)
        ControlSend("{End}", , gameWin)
        sendFn := () => ControlSend(cmd "{Enter}", , gameWin)
        SetTimer(sendFn, -30)
    }
    else
    {
        ; Open chat, wait 100ms, then send the command
        ControlSend("{Enter}", , gameWin)
        sendFn := () => ControlSend(cmd "{Enter}", , gameWin)
        SetTimer(sendFn, -100)
    }

    return true
}

; Loads flask key bindings from a PoE2 config INI file and populates g_flaskKeyBySlot.
; Falls back to default keys (1–5) if the file is missing, empty, or contains no matching entries.
; Params: configPath - full path to the poe2_production_Config.ini file
LoadFlaskHotkeysFromConfig(configPath)
{
    global g_flaskKeyBySlot, g_flaskKeyLoadStatus

    g_flaskKeyBySlot := Map(1, "1", 2, "2", 3, "3", 4, "4", 5, "5")
    g_flaskKeyLoadStatus := "default"

    if !FileExist(configPath)
    {
        g_flaskKeyLoadStatus := "missing"
        return false
    }

    try
    {
        raw := FileRead(configPath, "UTF-8")
    }
    catch
    {
        try raw := FileRead(configPath)
        catch
        {
            g_flaskKeyLoadStatus := "read-error"
            return false
        }
    }

    if (StrLen(raw) < 5)
    {
        g_flaskKeyLoadStatus := "empty"
        return false
    }

    found := 0
    lines := StrSplit(raw, "`n", "`r")
    for line in lines
    {
        slot := 0
        keyValue := ""
        if TryParseFlaskBindingLine(line, &slot, &keyValue)
        {
            normalized := NormalizeConfigKeyToSend(keyValue)
            if (slot >= 1 && slot <= 5 && normalized != "")
            {
                g_flaskKeyBySlot[slot] := normalized
                found += 1
            }
        }
    }

    if (found > 0)
    {
        g_flaskKeyLoadStatus := "config"
        return true
    }

    g_flaskKeyLoadStatus := "default(no-match)"
    return false
}

; Parses one config file line and extracts the flask slot number and raw key value.
; Params: line - raw text line; slot - out: 1–5 slot number; keyValue - out: raw key string
; Returns: true if a valid flask binding was found
TryParseFlaskBindingLine(line, &slot, &keyValue)
{
    slot := 0
    keyValue := ""
    clean := Trim(line)
    if (clean = "" || SubStr(clean, 1, 1) = ";")
        return false

    ; Examples handled:
    ;   flask1=DIK_1
    ;   flask_2 = KEY_2
    ;   UseFlask3=3
    ;   Input_flask_4_primary = DIK_4
    if RegExMatch(clean, "i)\b(?:use)?flask[_\s-]*([1-5])\b[^=]*=\s*(.+)$", &m)
    {
        slot := Integer(m[1])
        keyValue := Trim(m[2])
        return true
    }

    if RegExMatch(clean, "i)^([^=]*flask[^=]*[1-5][^=]*)=\s*(.+)$", &m2)
    {
        left := m2[1]
        if RegExMatch(left, "([1-5])", &n)
        {
            slot := Integer(n[1])
            keyValue := Trim(m2[2])
            return true
        }
    }

    return false
}

; Converts a raw config key name (e.g. "DIK_1", "NUMPAD2") to an AHK Send-format key string.
; Returns: normalized key string suitable for use in SendFlaskKeyToGame
NormalizeConfigKeyToSend(rawKey)
{
    val := Trim(rawKey, ' "`t')
    if (val = "")
        return ""

    if RegExMatch(val, "^([^,;\s]+)", &m)
        val := m[1]

    key := StrUpper(val)
    key := RegExReplace(key, "^(DIK_|VK_|KEY_)")

    keyMap := Map(
        "ESCAPE", "Esc",
        "RETURN", "Enter",
        "ENTER", "Enter",
        "SPACE", "Space",
        "TAB", "Tab",
        "BACK", "Backspace",
        "BACKSPACE", "Backspace",
        "LSHIFT", "LShift",
        "RSHIFT", "RShift",
        "LCONTROL", "LCtrl",
        "RCONTROL", "RCtrl",
        "LCTRL", "LCtrl",
        "RCTRL", "RCtrl",
        "LMENU", "LAlt",
        "RMENU", "RAlt",
        "LALT", "LAlt",
        "RALT", "RAlt",
        "CAPITAL", "CapsLock",
        "CAPSLOCK", "CapsLock"
    )

    if keyMap.Has(key)
        return keyMap[key]

    if RegExMatch(key, "^NUMPAD([0-9])$", &n)
        return "Numpad" n[1]

    if RegExMatch(key, "^\d+$")
    {
        sk := _ConfigVkToSendKey(Integer(key))
        if (sk != "")
            return sk
    }

    if RegExMatch(key, "^F([1-9]|1[0-2])$", &f)
        return "F" f[1]

    if RegExMatch(key, "^[0-9]$")
        return key

    if RegExMatch(key, "^[A-Z]$")
        return key

    if RegExMatch(key, "^OEM_MINUS$")
        return "-"
    if RegExMatch(key, "^OEM_PLUS$")
        return "="

    return key
}

; Converts a decimal Windows Virtual-Key code (as stored in poe2_production_Config.ini,
; e.g. use_bound_skill4=81) into an AHK send-key string. Returns "" if unmapped.
; Letters map to lowercase; mouse buttons and OEM punctuation map to AHK names / vk codes.
_ConfigVkToSendKey(code)
{
    static m := Map(
        1, "LButton", 2, "RButton", 4, "MButton", 5, "XButton1", 6, "XButton2",
        8, "Backspace", 9, "Tab", 13, "Enter", 16, "Shift", 17, "Control", 18, "Alt",
        19, "Pause", 20, "CapsLock", 27, "Escape", 32, "Space",
        33, "PgUp", 34, "PgDn", 35, "End", 36, "Home",
        37, "Left", 38, "Up", 39, "Right", 40, "Down", 45, "Insert", 46, "Delete",
        106, "NumpadMult", 107, "NumpadAdd", 109, "NumpadSub", 110, "NumpadDot", 111, "NumpadDiv",
        144, "NumLock", 145, "ScrollLock",
        186, "vkBA", 187, "vkBB", 188, "vkBC", 189, "vkBD", 190, "vkBE", 191, "vkBF",
        192, "vkC0", 219, "vkDB", 220, "vkDC", 221, "vkDD", 222, "vkDE"
    )
    if m.Has(code)
        return m[code]
    if (code >= 48 && code <= 57)        ; 0-9
        return Chr(code)
    if (code >= 65 && code <= 90)        ; A-Z -> lowercase
        return Chr(code + 32)
    if (code >= 96 && code <= 105)       ; Numpad 0-9
        return "Numpad" (code - 96)
    if (code >= 112 && code <= 135)      ; F1-F24
        return "F" (code - 111)
    return ""
}

; Returns true when every radar-sample entity matching trackPath is "finished"
; (opened chest/strongbox or dead) and at least one such entity exists — used to
; auto-expire entity tracking. Fully defensive: any read/shape error returns false
; so tracking is never dropped by accident.
_TrackedEntityExpired(snap, trackPath)
{
    if !(IsObject(snap) && trackPath != "")
        return false
    try
    {
        inGame := snap.Has("inGameState") ? snap["inGameState"] : 0
        area   := (IsObject(inGame) && inGame.Has("areaInstance")) ? inGame["areaInstance"] : 0
        awake  := (IsObject(area) && area.Has("awakeEntities")) ? area["awakeEntities"] : 0
        sample := (IsObject(awake) && awake.Has("sample")) ? awake["sample"] : 0
        if !IsObject(sample)
            return false
        foundActive := false
        foundExpired := false
        for _, entry in sample
        {
            if !(IsObject(entry) && entry.Has("entity"))
                continue
            ent := entry["entity"]
            if !(IsObject(ent) && ent.Has("path") && ent["path"] = trackPath)
                continue
            dc := ent.Has("decodedComponents") ? ent["decodedComponents"] : 0
            isExpired := false
            if IsObject(dc)
            {
                ch := dc.Has("chest") ? dc["chest"] : 0
                if (IsObject(ch) && ch.Has("isOpened") && ch["isOpened"])
                    isExpired := true
                lf := dc.Has("life") ? dc["life"] : 0
                if (IsObject(lf) && lf.Has("isAlive") && !lf["isAlive"])
                    isExpired := true
            }
            if isExpired
                foundExpired := true
            else
                foundActive := true
        }
        return (foundExpired && !foundActive)
    }
    catch
        return false
}