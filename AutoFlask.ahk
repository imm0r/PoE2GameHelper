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
    _running := true
    try
    {
        global reader, g_radarOverlay, g_radarLastSnap, updatesPaused, g_radarReadMs, g_radarRenderMs, g_radarEnabled
        if updatesPaused
            return
        if !g_radarEnabled
        {
            if g_radarOverlay
                g_radarOverlay.Hide()
            return
        }
        if !IsObject(reader)
            return

        radarReadStart := A_TickCount
        radarSnap := reader.ReadRadarSnapshot()
        g_radarReadMs := A_TickCount - radarReadStart
        if !radarSnap
        {
            if g_radarOverlay
                g_radarOverlay.Hide()
            return
        }
        g_radarLastSnap := radarSnap  ; cache for Dump Entities button

        ; Only show overlay when player render component is present (= truly in-game)
        inGs         := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
        area         := (inGs && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
        playerRender := (area && area.Has("playerRenderComponent")) ? area["playerRenderComponent"] : 0
        if !playerRender
        {
            if g_radarOverlay
                g_radarOverlay.Hide()
            return
        }

        gameHwnd := ResolvePoEWindow()
        if !gameHwnd
        {
            if g_radarOverlay
                g_radarOverlay.Hide()
            return
        }

        ; Hide overlay when the game window is not the active (foreground) window
        if !WinActive("ahk_id " gameHwnd)
        {
            if g_radarOverlay
                g_radarOverlay.Hide()
            return
        }

        if !g_radarOverlay
            g_radarOverlay := RadarOverlay()

        global radarShowEnemyNormal, radarShowEnemyRare, radarShowEnemyBoss, radarShowMinions, radarShowNpcs, radarShowChests
        global debugMode, g_highlightedEntityPath, g_zoneNavEnabled, g_mapHackEnabled
        g_radarOverlay.ShowEnemyNormal := radarShowEnemyNormal
        g_radarOverlay.ShowEnemyRare   := radarShowEnemyRare
        g_radarOverlay.ShowEnemyBoss   := radarShowEnemyBoss
        g_radarOverlay.ShowMinions := radarShowMinions
        g_radarOverlay.ShowNpcs    := radarShowNpcs
        g_radarOverlay.ShowChests  := radarShowChests
        g_radarOverlay.DebugMode   := debugMode
        g_radarOverlay._navEnabled := g_zoneNavEnabled
        g_radarOverlay._mapHackEnabled := g_mapHackEnabled
        g_radarOverlay.highlightedEntityPath := IsSet(g_highlightedEntityPath) ? g_highlightedEntityPath : ""

        WinGetPos(&gwX, &gwY, &gwW, &gwH, "ahk_id " gameHwnd)
        radarRenderStart := A_TickCount
        g_radarOverlay.Render(radarSnap, gwX, gwY, gwW, gwH)
        g_radarRenderMs := A_TickCount - radarRenderStart
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
    _running := true
    try
    {
        global reader, autoFlaskEnabled, updatesPaused
        if (updatesPaused || !autoFlaskEnabled)
            return
        flask_snap := reader.ReadAutoFlaskSnapshot()
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
    global autoFlaskEnabled, lifeThresholdPercent, manaThresholdPercent, autoFlaskLastReason, pendingFlaskVerifyBySlot

    if !autoFlaskEnabled
    {
        autoFlaskLastReason := "disabled"
        return
    }

    gameHwnd := ResolvePoEWindow()
    if !gameHwnd
    {
        autoFlaskLastReason := "game-window-missing"
        return
    }

    stateName := (snapshot && snapshot.Has("currentStateName")) ? snapshot["currentStateName"] : ""
    if !IsStrictInGameState(snapshot)
    {
        try pendingFlaskVerifyBySlot.Clear()
        autoFlaskLastReason := "state-blocked(" (stateName = "" ? "unknown" : stateName) ")"
        return
    }

    inGame := snapshot.Has("inGameState") ? snapshot["inGameState"] : 0
    if !inGame
    {
        autoFlaskLastReason := "ingame-null"
        return
    }

    worldDet := inGame.Has("worldDataDetails") ? inGame["worldDataDetails"] : 0
    worldArea := (worldDet && worldDet.Has("worldAreaDat")) ? worldDet["worldAreaDat"] : 0
    if (worldArea)
    {
        if ((worldArea.Has("isTown") && worldArea["isTown"]) || (worldArea.Has("isHideout") && worldArea["isHideout"]))
        {
            autoFlaskLastReason := "town-hideout"
            return
        }
    }

    areaInst := inGame.Has("areaInstance") ? inGame["areaInstance"] : 0
    if !areaInst
    {
        autoFlaskLastReason := "area-null"
        return
    }

    playerVitals := areaInst.Has("playerVitals") ? areaInst["playerVitals"] : 0
    if !playerVitals || !playerVitals.Has("stats")
    {
        autoFlaskLastReason := "vitals-missing"
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
        autoFlaskLastReason := "flask-slots-missing"
        return
    }

    verifyReason := ProcessPendingFlaskVerification(slots)

    triggered := false
    attempted := false
    failDetails := []

    if (lifePct >= 0 && lifePct <= lifeThresholdPercent)
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

    if (manaPct >= 0 && manaPct <= manaThresholdPercent)
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
        autoFlaskLastReason := (detail = "" ? "triggered" : "triggered|" detail)
    }
    else if (attempted)
    {
        detail := ""
        for _, reason in failDetails
            detail .= (detail = "" ? "" : "|") reason
        if (verifyReason != "")
            detail := (detail = "" ? verifyReason : verifyReason "|" detail)
        autoFlaskLastReason := (detail = "" ? "attempted-no-use" : detail)
    }
    else
    {
        base := "no-threshold(lp=" Round(lifePct) " mp=" Round(manaPct) ")"
        autoFlaskLastReason := (verifyReason = "" ? base : verifyReason "|" base)
    }
}

; Returns true only when the snapshot represents a live InGameState (not a loading screen or main menu).
; Verifies that currentStateAddress matches inGameStateAddress to rule out stale pointer reads.
IsStrictInGameState(snapshot)
{
    if !snapshot
        return false

    if !snapshot.Has("currentStateName") || snapshot["currentStateName"] != "InGameState"
        return false

    if !snapshot.Has("currentStateAddress") || !snapshot.Has("inGameStateAddress")
        return false

    currentAddr := snapshot["currentStateAddress"]
    inGameAddr := snapshot["inGameStateAddress"]
    if (!currentAddr || !inGameAddr)
        return false

    return currentAddr = inGameAddr
}

; Attempts to activate one flask slot; checks buff state, charges, cooldown, and key availability.
; Params: slots - flask slot Map; slotNumber - 1-indexed slot; slotReason - out: human-readable outcome
; Returns: true if the key press was successfully sent to the game
TryUseFlaskSlot(slots, slotNumber, gameHwnd, &slotReason := "")
{
    global flaskUseCooldownMs, lastFlaskUseBySlot, flaskKeyBySlot, autoFlaskLastReason, pendingFlaskVerifyBySlot
    slotReason := ""

    if (pendingFlaskVerifyBySlot.Has(slotNumber))
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
        autoFlaskLastReason := slotReason
        return false
    }

    current := fs.Has("current") ? fs["current"] : 0
    perUse := fs.Has("perUse") ? fs["perUse"] : 0
    if (perUse <= 0 || current < perUse)
    {
        slotReason := "slot" slotNumber "-no-charges(cur=" current "/use=" perUse ")"
        autoFlaskLastReason := slotReason
        return false
    }

    now := A_TickCount
    last := lastFlaskUseBySlot.Has(slotNumber) ? lastFlaskUseBySlot[slotNumber] : 0
    if (now - last < flaskUseCooldownMs)
    {
        slotReason := "slot" slotNumber "-cooldown"
        autoFlaskLastReason := slotReason
        return false
    }

    if !flaskKeyBySlot.Has(slotNumber)
    {
        slotReason := "slot" slotNumber "-key-missing"
        return false
    }

    sendKey := flaskKeyBySlot[slotNumber]
    if (sendKey = "")
    {
        slotReason := "slot" slotNumber "-key-empty"
        return false
    }

    if !SendFlaskKeyToGame(sendKey, gameHwnd)
    {
        slotReason := "slot" slotNumber "-send-failed(key=" sendKey ")"
        autoFlaskLastReason := slotReason
        return false
    }

    lastFlaskUseBySlot[slotNumber] := now
    pendingFlaskVerifyBySlot[slotNumber] := Map(
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
    global pendingFlaskVerifyBySlot, lastFlaskUseBySlot

    if !pendingFlaskVerifyBySlot || (pendingFlaskVerifyBySlot.Count = 0)
        return ""

    now := A_TickCount
    parts := []
    timeoutMs := 650

    for slotNumber, info in pendingFlaskVerifyBySlot.Clone()
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
            pendingFlaskVerifyBySlot.Delete(slotNumber)
            parts.Push("slot" slotNumber "-confirm(cur:" pre "->" cur ")")
            continue
        }

        sentAt := info.Has("sentAt") ? info["sentAt"] : now
        if (now - sentAt > timeoutMs)
        {
            pendingFlaskVerifyBySlot.Delete(slotNumber)
            lastFlaskUseBySlot[slotNumber] := 0
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
    if WinExist("ahk_exe PathOfExileSteam.exe")
        return WinGetID("ahk_exe PathOfExileSteam.exe")
    if WinExist("ahk_exe PathOfExile.exe")
        return WinGetID("ahk_exe PathOfExile.exe")
    return 0
}

; Sends a keystroke to the PoE2 window via ControlSend using the window handle.
; Params: sendKey - AHK Send-format key name; gameHwnd - target window HWND
; Returns: true if ControlSend succeeded
SendFlaskKeyToGame(sendKey, gameHwnd)
{
    if (sendKey = "" || !gameHwnd)
        return false

    gameWin := "ahk_id " gameHwnd

    ; Primary path requested: direct ControlSend to PoE window handle.
    try
    {
        ControlSend("{Blind}{" sendKey "}", , gameWin)
        return true
    }
    catch
    {
    }

    return false
}

; Opens the in-game chat (or reuses it if already open) and types a slash command, then submits it.
; Reads isChatActive from the last snapshot to decide whether to open or clear the input first.
; Params: cmd - slash command string, must begin with "/"
; Returns: true if the command was sent successfully
SendChatSlashCommand(cmd)
{
    global lastSnapshotForUi

    if (cmd = "" || SubStr(cmd, 1, 1) != "/")
        return false

    gameHwnd := ResolvePoEWindow()
    if !gameHwnd
        return false

    gameWin := "ahk_id " gameHwnd

    ; IsChatActive aus dem letzten Snapshot lesen
    isChatActive := false
    try
    {
        inGame  := (lastSnapshotForUi && lastSnapshotForUi.Has("inGameState")) ? lastSnapshotForUi["inGameState"] : 0
        uiElems := (inGame && inGame.Has("importantUiElements")) ? inGame["importantUiElements"] : 0
        if (uiElems && uiElems.Has("isChatActive"))
            isChatActive := uiElems["isChatActive"]
    }
    catch
    {
    }

    try
    {
        if isChatActive
        {
            ; Chat ist offen: Ctrl+A um vorhandenen Text zu überschreiben
            ControlSend("^a", , gameWin)
            Sleep(30)
            ControlSend("{End}", , gameWin)
            Sleep(20)
        }
        else
        {
            ; Chat öffnen
            ControlSend("{Enter}", , gameWin)
            Sleep(100)
        }

        ControlSend(cmd "{Enter}", , gameWin)
        return true
    }
    catch
    {
        return false
    }
}

; Loads flask key bindings from a PoE2 config INI file and populates flaskKeyBySlot.
; Falls back to default keys (1–5) if the file is missing, empty, or contains no matching entries.
; Params: configPath - full path to the poe2_production_Config.ini file
LoadFlaskHotkeysFromConfig(configPath)
{
    global flaskKeyBySlot, flaskKeyLoadStatus

    flaskKeyBySlot := Map(1, "1", 2, "2", 3, "3", 4, "4", 5, "5")
    flaskKeyLoadStatus := "default"

    if !FileExist(configPath)
    {
        flaskKeyLoadStatus := "missing"
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
            flaskKeyLoadStatus := "read-error"
            return false
        }
    }

    if (StrLen(raw) < 5)
    {
        flaskKeyLoadStatus := "empty"
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
                flaskKeyBySlot[slot] := normalized
                found += 1
            }
        }
    }

    if (found > 0)
    {
        flaskKeyLoadStatus := "config"
        return true
    }

    flaskKeyLoadStatus := "default(no-match)"
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
        code := Integer(key)
        if (code >= 48 && code <= 57)
            return Chr(code)
        if (code >= 96 && code <= 105)
            return "Numpad" (code - 96)
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

