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
        global g_reader, g_radarOverlay, g_radarLastSnap, g_updatesPaused, g_radarReadMs, g_radarRenderMs, g_radarEnabled, g_radarAlpha
        global g_playerHudEnabled, g_playerHud
        if g_updatesPaused
        {
            if g_radarOverlay
                g_radarOverlay.Hide()
            if g_playerHud
                g_playerHud.Hide()
            return
        }
        if !IsObject(g_reader)
            return

        radarReadStart := A_TickCount
        radarSnap := g_reader.ReadRadarSnapshot()
        g_radarReadMs := A_TickCount - radarReadStart
        if !radarSnap
        {
            if g_radarOverlay
                g_radarOverlay.Hide()
            if g_playerHud
                g_playerHud.Hide()
            return
        }
        g_radarLastSnap := radarSnap  ; cache for Dump Entities button

        currentState := radarSnap.Has("currentStateName") ? radarSnap["currentStateName"] : ""

        ; ── Determine overlay visibility ──────────────────────────────────────
        ; Overlays should only show when ALL conditions are met:
        ;   1. InGameState   2. Not town/hideout   3. Player alive
        ;   4. Large map visible   5. No panel/chat open   6. Player render component
        overlayAllowed := true
        hideReason := ""

        ; Condition 1: Must be in InGameState
        if (currentState != "InGameState")
        {
            overlayAllowed := false
            hideReason := "not-ingame"
        }

        ; Condition 2: Not town or hideout
        if overlayAllowed
        {
            wad := radarSnap.Has("worldAreaDat") ? radarSnap["worldAreaDat"] : 0
            if (wad && IsObject(wad))
            {
                if ((wad.Has("isTown") && wad["isTown"]) || (wad.Has("isHideout") && wad["isHideout"]))
                {
                    overlayAllowed := false
                    hideReason := "town-hideout"
                }
            }
        }

        ; Condition 3: Player must be alive
        if overlayAllowed
        {
            pv := radarSnap.Has("playerVitals") ? radarSnap["playerVitals"] : 0
            if (pv && IsObject(pv) && pv.Has("stats"))
            {
                stats := pv["stats"]
                if (stats.Has("isAlive") && !stats["isAlive"])
                {
                    overlayAllowed := false
                    hideReason := "dead"
                }
            }
        }

        ; Condition 4: Large map must be visible (overlay draws on the large map)
        if overlayAllowed
        {
            inGs := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
            uiElems := (inGs && IsObject(inGs) && inGs.Has("importantUiElements")) ? inGs["importantUiElements"] : 0
            largeMapOpen := false
            if (uiElems && IsObject(uiElems))
            {
                lm := uiElems.Has("largeMapData") ? uiElems["largeMapData"] : 0
                if (lm && IsObject(lm) && lm.Has("isVisible") && lm["isVisible"])
                    largeMapOpen := true
            }
            if !largeMapOpen
            {
                overlayAllowed := false
                hideReason := "no-largemap"
            }
        }

        ; Condition 5: No game panel open + chat not active
        if overlayAllowed
        {
            ; Visibility-differential check: any newly visible elements = panel open
            panelVis := radarSnap.Has("panelVisibility") ? radarSnap["panelVisibility"] : 0
            if (panelVis && IsObject(panelVis))
            {
                if (panelVis.Has("anyPanelOpen") && panelVis["anyPanelOpen"])
                {
                    overlayAllowed := false
                    newlyVis := panelVis.Has("newlyVisible") ? panelVis["newlyVisible"] : 0
                    hideReason := "panel-open(" newlyVis " new)"
                }
            }

            ; Chat check (ImportantUiElements)
            if overlayAllowed
            {
                if !IsSet(uiElems)
                {
                    inGs := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
                    uiElems := (inGs && inGs.Has("importantUiElements")) ? inGs["importantUiElements"] : 0
                }
                if (uiElems && IsObject(uiElems) && uiElems.Has("isChatActive") && uiElems["isChatActive"])
                {
                    overlayAllowed := false
                    hideReason := "chat-active"
                }
            }
        }

        ; Condition 6: Player render component present (truly in-game)
        inGs         := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
        area         := (inGs && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
        playerRender := (area && area.Has("playerRenderComponent")) ? area["playerRenderComponent"] : 0
        if (overlayAllowed && !playerRender)
        {
            overlayAllowed := false
            hideReason := "no-player"
        }

        ; ── Push debug panel data periodically (every 500ms) ────────────────
        static _debugPanelPushTick := 0
        if (A_TickCount - _debugPanelPushTick > 500)
        {
            PushDebugPanelsToWebView(radarSnap, overlayAllowed, hideReason)
            _debugPanelPushTick := A_TickCount
        }

        ; ── Hide overlays if conditions not met ──────────────────────────────
        if !overlayAllowed
        {
            if g_radarOverlay
                g_radarOverlay.Hide()
            if g_playerHud
                g_playerHud.Hide()
            return
        }

        ; ── Game window checks ────────────────────────────────────────────────
        gameHwnd := ResolvePoEWindow()
        if !gameHwnd
        {
            if g_radarOverlay
                g_radarOverlay.Hide()
            if g_playerHud
                g_playerHud.Hide()
            return
        }

        if !WinActive("ahk_id " gameHwnd)
        {
            if g_radarOverlay
                g_radarOverlay.Hide()
            if g_playerHud
                g_playerHud.Hide()
            return
        }

        ; ── Render overlays ───────────────────────────────────────────────────
        if (!g_radarOverlay && g_radarEnabled)
        {
            g_radarOverlay := RadarOverlay()
            g_radarOverlay._alpha := g_radarAlpha
        }

        global g_radarShowEnemyNormal, g_radarShowEnemyRare, g_radarShowEnemyBoss, g_radarShowMinions, g_radarShowNpcs, g_radarShowChests
        global g_debugMode, g_highlightedEntityPath, g_zoneNavEnabled, g_mapHackEnabled

        WinGetPos(&gwX, &gwY, &gwW, &gwH, "ahk_id " gameHwnd)

        if (g_radarEnabled && g_radarOverlay)
        {
            g_radarOverlay.ShowEnemyNormal := g_radarShowEnemyNormal
            g_radarOverlay.ShowEnemyRare   := g_radarShowEnemyRare
            g_radarOverlay.ShowEnemyBoss   := g_radarShowEnemyBoss
            g_radarOverlay.ShowMinions := g_radarShowMinions
            g_radarOverlay.ShowNpcs    := g_radarShowNpcs
            g_radarOverlay.ShowChests  := g_radarShowChests
            g_radarOverlay.DebugMode   := g_debugMode
            g_radarOverlay._navEnabled := g_zoneNavEnabled
            g_radarOverlay._mapHackEnabled := g_mapHackEnabled
            g_radarOverlay.highlightedEntityPath := IsSet(g_highlightedEntityPath) ? g_highlightedEntityPath : ""

            radarRenderStart := A_TickCount
            g_radarOverlay.Render(radarSnap, gwX, gwY, gwW, gwH)
            g_radarRenderMs := A_TickCount - radarRenderStart
        }
        else if (!g_radarEnabled && g_radarOverlay)
        {
            g_radarOverlay.Hide()
        }

        ; Player HUD
        _UpdatePlayerHUD(radarSnap, currentState, gameHwnd)
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

; Extracts player vitals from the radar snapshot and feeds them to the PlayerHUD overlay.
_UpdatePlayerHUD(radarSnap, currentState, gameHwnd)
{
    global g_playerHudEnabled, g_playerHud
    if !g_playerHudEnabled
    {
        if g_playerHud
            g_playerHud.Hide()
        return
    }

    if !gameHwnd
    {
        gameHwnd := ResolvePoEWindow()
        if !gameHwnd
        {
            if g_playerHud
                g_playerHud.Hide()
            return
        }
        if !WinActive("ahk_id " gameHwnd)
        {
            if g_playerHud
                g_playerHud.Hide()
            return
        }
    }

    if !g_playerHud
        g_playerHud := PlayerHUD()

    ; Build data Map for the HUD
    hudData := Map()
    hudData["stateName"] := currentState
    hudData["areaLevel"] := radarSnap.Has("areaLevel") ? radarSnap["areaLevel"] : 0

    pv := radarSnap.Has("playerVitals") ? radarSnap["playerVitals"] : 0
    if (pv && IsObject(pv) && pv.Has("stats"))
    {
        stats := pv["stats"]
        lifeCur := stats.Has("lifeCurrent")  ? stats["lifeCurrent"]  : 0
        lifeMax := stats.Has("lifeMax")      ? stats["lifeMax"]      : 1
        manaCur := stats.Has("manaCurrent")  ? stats["manaCurrent"]  : 0
        manaMax := stats.Has("manaMax")      ? stats["manaMax"]      : 1
        esCur   := stats.Has("esCurrent")    ? stats["esCurrent"]    : 0
        esMax   := stats.Has("esMax")        ? stats["esMax"]        : 0

        hudData["lifeCur"] := lifeCur
        hudData["lifeMax"] := lifeMax
        hudData["lifePct"] := lifeMax > 0 ? (lifeCur / lifeMax) * 100 : 0
        hudData["manaCur"] := manaCur
        hudData["manaMax"] := manaMax
        hudData["manaPct"] := manaMax > 0 ? (manaCur / manaMax) * 100 : 0
        hudData["esCur"]   := esCur
        hudData["esMax"]   := esMax
        hudData["esPct"]   := esMax > 0 ? (esCur / esMax) * 100 : 0
    }
    else
    {
        hudData["lifeCur"] := 0, hudData["lifeMax"] := 0, hudData["lifePct"] := 0
        hudData["manaCur"] := 0, hudData["manaMax"] := 0, hudData["manaPct"] := 0
        hudData["esCur"]   := 0, hudData["esMax"]   := 0, hudData["esPct"]   := 0
    }

    WinGetPos(&gwX, &gwY, &gwW, &gwH, "ahk_id " gameHwnd)
    g_playerHud.Update(hudData, gwX, gwY, gwW, gwH)
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
    global g_lastSnapshotForUi

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
        inGame  := (g_lastSnapshotForUi && g_lastSnapshotForUi.Has("inGameState")) ? g_lastSnapshotForUi["inGameState"] : 0
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

