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
                if g_radarOverlay
                    g_radarOverlay.Hide()
                if g_playerHud
                    g_playerHud.Hide()
                return
            }
        }
        g_radarLastSnap := radarSnap  ; cache for Dump Entities button
        HotkeyBindingsOnAreaChange(radarSnap)

        ; ── AutoPilot (state machine: combat → explore, owns shared guards) ──
        TryAutoPilot(radarSnap)

        currentState := radarSnap.Has("currentStateName") ? radarSnap["currentStateName"] : ""

        ; ── Determine overlay visibility ──────────────────────────────────────
        ; Overlays should only show when ALL conditions are met:
        ;   1. InGameState   2. Not town/hideout   3. Player alive
        ;   4. Large map visible   5. No panel/chat open   6. Player render component
        overlayAllowed := true
        hideReason := ""

        ; Condition 1: Reject only states that definitely have no player/area
        ; (login / character management / credits). Don't gate on
        ; currentState != "InGameState" alone — after a zone change the game
        ; can keep transitional states (AreaLoadingState etc.) on top of the
        ; state stack for tens of seconds, or report a state pointer we don't
        ; recognize ('GameNotLoaded'), even though areaInstance, playerRender
        ; and terrain are all valid (the snapshot's ResolveInGameStateAddress
        ; scoring picks the right InGameState by data, not by name). Conds 2-6
        ; below already filter out anything that isn't actually in-game.
        nonGameStates := Map(
            "PreGameState",         true,
            "LoginState",           true,
            "WaitingState",         true,
            "CreateCharacterState", true,
            "SelectCharacterState", true,
            "DeleteCharacterState", true,
            "ChangePasswordState",  true,
            "CreditsState",         true,
            "LoadingState",         true
        )
        if (nonGameStates.Has(currentState))
        {
            overlayAllowed := false
            hideReason := "not-ingame(" currentState ")"
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
            ; Temporal debounce: combat UI elements can briefly flicker visibility flags,
            ; so require the "panel open" signal to persist for 500ms before hiding.
            ; Real panels stay open for seconds; combat noise lasts < 200ms.
            static _panelOpenSinceTick := 0
            static _PANEL_DEBOUNCE_MS := 500
            panelVis := radarSnap.Has("panelVisibility") ? radarSnap["panelVisibility"] : 0
            panelDetected := false
            if (panelVis && IsObject(panelVis))
                panelDetected := (panelVis.Has("anyPanelOpen") && panelVis["anyPanelOpen"])

            if panelDetected
            {
                if (_panelOpenSinceTick = 0)
                    _panelOpenSinceTick := A_TickCount
                if ((A_TickCount - _panelOpenSinceTick) >= _PANEL_DEBOUNCE_MS)
                {
                    overlayAllowed := false
                    newlyVis := panelVis.Has("newlyVisible") ? panelVis["newlyVisible"] : 0
                    hideReason := "panel-open(" newlyVis " new)"
                }
            }
            else
            {
                _panelOpenSinceTick := 0
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
        inGs := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
        area := (inGs && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
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
            PushRadarDebugToWebView(overlayAllowed, hideReason)
            _debugPanelPushTick := A_TickCount
        }

        ; ── UI Browser inspect mode overrides all hide conditions ────────────
        ; When a highlight is active the user is actively inspecting an element;
        ; show the overlay regardless of map state, panels, or focus.
        global g_uiBrowserHighlight
        if IsObject(g_uiBrowserHighlight)
            overlayAllowed := true

        ; ── Hide overlays if conditions not met ──────────────────────────────
        ; GC-susceptible conditions (no-largemap, no-player) get a grace period
        ; to avoid flicker from brief memory read failures.
        static _overlayCondHideTick := 0
        if !overlayAllowed
        {
            gcSensitive := (hideReason = "no-largemap" || hideReason = "no-player")
            if gcSensitive
            {
                if (_overlayCondHideTick = 0)
                    _overlayCondHideTick := A_TickCount
                if ((A_TickCount - _overlayCondHideTick) < _OVERLAY_GRACE_MS)
                {
                    ; Within grace — skip hide, continue to render with last data
                }
                else
                {
                    _overlayCondHideTick := 0
                    if g_radarOverlay
                        g_radarOverlay.Hide()
                    if g_playerHud
                        g_playerHud.Hide()
                    return
                }
            }
            else
            {
                ; Deliberate state changes (panel open, chat, dead) — hide immediately
                _overlayCondHideTick := 0
                if g_radarOverlay
                    g_radarOverlay.Hide()
                if g_playerHud
                    g_playerHud.Hide()
                return
            }
        }
        else
        {
            _overlayCondHideTick := 0
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
            ; Keep rendering when our own tool window is focused (user clicks in GameHelper)
            ; or when range circles are set (config preview mode).
            ; Any other window in focus → hide.
            global g_webGui
            hasCircles := (g_radarOverlay && g_radarOverlay._rangeCircles.Length > 0)
            toolFocused := IsObject(g_webGui) && WinActive("ahk_id " g_webGui.Hwnd)
            if (!hasCircles && !toolFocused)
            {
                if g_radarOverlay
                    g_radarOverlay.Hide()
                if g_playerHud
                    g_playerHud.Hide()
                return
            }
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
            g_radarOverlay.ShowEnemyRare := g_radarShowEnemyRare
            g_radarOverlay.ShowEnemyBoss := g_radarShowEnemyBoss
            g_radarOverlay.ShowMinions := g_radarShowMinions
            g_radarOverlay.ShowNpcs := g_radarShowNpcs
            g_radarOverlay.ShowChests := g_radarShowChests
            g_radarOverlay.DebugMode := g_debugMode
            g_radarOverlay._navEnabled := g_zoneNavEnabled
            g_radarOverlay._mapHackEnabled := g_mapHackEnabled
            g_radarOverlay._rangeCirclesEnabled := IsSet(g_rangeCirclesEnabled) ? g_rangeCirclesEnabled : true
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
        lifeCur := stats.Has("lifeCurrent") ? stats["lifeCurrent"] : 0
        lifeMax := stats.Has("lifeMax") ? stats["lifeMax"] : 1
        manaCur := stats.Has("manaCurrent") ? stats["manaCurrent"] : 0
        manaMax := stats.Has("manaMax") ? stats["manaMax"] : 1
        esCur := stats.Has("esCurrent") ? stats["esCurrent"] : 0
        esMax := stats.Has("esMax") ? stats["esMax"] : 0

        hudData["lifeCur"] := lifeCur
        hudData["lifeMax"] := lifeMax
        hudData["lifePct"] := lifeMax > 0 ? (lifeCur / lifeMax) * 100 : 0
        hudData["manaCur"] := manaCur
        hudData["manaMax"] := manaMax
        hudData["manaPct"] := manaMax > 0 ? (manaCur / manaMax) * 100 : 0
        hudData["esCur"] := esCur
        hudData["esMax"] := esMax
        hudData["esPct"] := esMax > 0 ? (esCur / esMax) * 100 : 0
    }
    else
    {
        hudData["lifeCur"] := 0, hudData["lifeMax"] := 0, hudData["lifePct"] := 0
        hudData["manaCur"] := 0, hudData["manaMax"] := 0, hudData["manaPct"] := 0
        hudData["esCur"] := 0, hudData["esMax"] := 0, hudData["esPct"] := 0
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
        "PreGameState",         true,
        "LoginState",           true,
        "WaitingState",         true,
        "CreateCharacterState", true,
        "SelectCharacterState", true,
        "DeleteCharacterState", true,
        "ChangePasswordState",  true,
        "CreditsState",         true,
        "LoadingState",         true
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
    if WinExist("ahk_exe PathOfExileSteam.exe")
        return WinGetID("ahk_exe PathOfExileSteam.exe")
    if WinExist("ahk_exe PathOfExile.exe")
        return WinGetID("ahk_exe PathOfExile.exe")
    return 0
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

    ; KeyDown sofort
    DllCall("keybd_event", "uchar", vk, "uchar", 0, "uint", 0, "uptr", 0)

    ; KeyUp nach 20ms — nicht-blockierend über SetTimer
    ; Closure capturt vk als Kopie (AHK v2: Variablen in Closures sind by-value captures)
    keyUpFn := () => DllCall("keybd_event", "uchar", vk, "uchar", 0, "uint", 0x0002, "uptr", 0)
    SetTimer(keyUpFn, -KEY_UP_DELAY_MS)   ; negativ = einmaliger Fire

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
        ; Chat schon offen: Ctrl+A + End, dann 30ms warten, dann Command senden
        ControlSend("^a", , gameWin)
        ControlSend("{End}", , gameWin)
        sendFn := () => ControlSend(cmd "{Enter}", , gameWin)
        SetTimer(sendFn, -30)
    }
    else
    {
        ; Chat öffnen, 100ms warten, dann Command senden
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