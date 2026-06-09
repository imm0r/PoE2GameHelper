; PlayOverlayPolicy.ahk
; Single source of truth for play-overlay visibility. Evaluates the in-game gate
; once per tick and returns TWO results so different overlays can pick their policy:
;   - "allowed"      : full gate INCLUDING the large-map-open requirement (radar).
;   - "allowedNoMap" : same gate WITHOUT the large-map requirement (vitals bars,
;                      which a player wants visible during combat, not only on the map).
; Ported from the gate that used to live inline in UpdateRadarFast: the six in-game
; conditions, the panel-open debounce, separate GC-grace for no-largemap / no-player,
; the UI-browser inspect override and the foreground gate. Owns the debounce/grace
; state across ticks. Included by InGameStateMonitor.ahk (before OverlayManager).

class PlayOverlayPolicy
{
    static GRACE_MS          := 800   ; tolerate brief no-largemap / no-player gaps (GC reads)
    static PANEL_DEBOUNCE_MS := 500   ; combat UI flickers visibility; require panel to persist

    __New()
    {
        this._mapHideTick        := 0   ; A_TickCount when large map first read as closed
        this._playerHideTick     := 0   ; A_TickCount when player-render first read as missing
        this._panelOpenSinceTick := 0   ; A_TickCount when a panel was first detected open
    }

    ; Evaluates the gate for this tick.
    ; Returns Map("allowed", bool, "allowedNoMap", bool, "reason", str).
    ; ctx must have: snapshot, currentState, gameActive, keepWhenBackground, inspectOverride.
    Evaluate(ctx)
    {
        snap := ctx.snapshot
        if !(snap && IsObject(snap))
            return Map("allowed", false, "allowedNoMap", false, "reason", "no-snapshot")

        core   := true   ; conditions 1,2,3,5,6 (everything except the large map)
        reason := ""

        ; ── Condition 1: reject states that definitely have no player/area ──
        static nonGameStates := Map(
            "PreGameState", true, "LoginState", true, "WaitingState", true,
            "CreateCharacterState", true, "SelectCharacterState", true,
            "DeleteCharacterState", true, "ChangePasswordState", true,
            "CreditsState", true, "LoadingState", true)
        if nonGameStates.Has(ctx.currentState)
        {
            core   := false
            reason := "not-ingame(" ctx.currentState ")"
        }

        ; ── Condition 2: not town or hideout ──
        if core
        {
            wad := snap.Has("worldAreaDat") ? snap["worldAreaDat"] : 0
            if (wad && IsObject(wad)
                && ((wad.Has("isTown") && wad["isTown"]) || (wad.Has("isHideout") && wad["isHideout"])))
            {
                core   := false
                reason := "town-hideout"
            }
        }

        ; ── Condition 3: player must be alive ──
        if core
        {
            pv := snap.Has("playerVitals") ? snap["playerVitals"] : 0
            if (pv && IsObject(pv) && pv.Has("stats"))
            {
                st := pv["stats"]
                if (st.Has("isAlive") && !st["isAlive"])
                {
                    core   := false
                    reason := "dead"
                }
            }
        }

        ; ── Condition 5: no game panel open + chat not active (panel debounced) ──
        if core
        {
            panelVis      := snap.Has("panelVisibility") ? snap["panelVisibility"] : 0
            panelDetected := (panelVis && IsObject(panelVis) && panelVis.Has("anyPanelOpen") && panelVis["anyPanelOpen"])
            if panelDetected
            {
                if (this._panelOpenSinceTick = 0)
                    this._panelOpenSinceTick := A_TickCount
                if ((A_TickCount - this._panelOpenSinceTick) >= PlayOverlayPolicy.PANEL_DEBOUNCE_MS)
                {
                    core     := false
                    newlyVis := panelVis.Has("newlyVisible") ? panelVis["newlyVisible"] : 0
                    reason   := "panel-open(" newlyVis " new)"
                }
            }
            else
            {
                this._panelOpenSinceTick := 0
            }

            if core
            {
                inGs    := snap.Has("inGameState") ? snap["inGameState"] : 0
                uiElems := (inGs && IsObject(inGs) && inGs.Has("importantUiElements")) ? inGs["importantUiElements"] : 0
                if (uiElems && IsObject(uiElems) && uiElems.Has("isChatActive") && uiElems["isChatActive"])
                {
                    core   := false
                    reason := "chat-active"
                }
            }
        }

        ; ── Condition 6: player render component present (truly in-game), with grace ──
        if core
        {
            inGs := snap.Has("inGameState") ? snap["inGameState"] : 0
            area := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
            playerRender := (area && IsObject(area) && area.Has("playerRenderComponent")) ? area["playerRenderComponent"] : 0
            if !playerRender
            {
                core   := false
                reason := "no-player"
            }
        }
        ; no-player grace (GC briefly drops the component)
        if (!core && reason = "no-player")
        {
            if (this._playerHideTick = 0)
                this._playerHideTick := A_TickCount
            if ((A_TickCount - this._playerHideTick) < PlayOverlayPolicy.GRACE_MS)
            {
                core   := true
                reason := "grace(no-player)"
            }
            else
                this._playerHideTick := 0
        }
        else if core
        {
            this._playerHideTick := 0
        }

        ; ── Condition 4: large map visible (radar only), with its own grace ──
        mapOpen := false
        inGs2    := snap.Has("inGameState") ? snap["inGameState"] : 0
        uiElems2 := (inGs2 && IsObject(inGs2) && inGs2.Has("importantUiElements")) ? inGs2["importantUiElements"] : 0
        if (uiElems2 && IsObject(uiElems2))
        {
            lm := uiElems2.Has("largeMapData") ? uiElems2["largeMapData"] : 0
            if (lm && IsObject(lm) && lm.Has("isVisible") && lm["isVisible"])
                mapOpen := true
        }
        mapOpenEff := mapOpen
        if !mapOpen
        {
            if (this._mapHideTick = 0)
                this._mapHideTick := A_TickCount
            if ((A_TickCount - this._mapHideTick) < PlayOverlayPolicy.GRACE_MS)
                mapOpenEff := true   ; within grace — treat as still open
        }
        else
            this._mapHideTick := 0

        ; ── UI-browser inspect mode overrides all hide conditions ──
        if ctx.inspectOverride
        {
            core       := true
            mapOpenEff := true
            reason     := "ui-inspect"
        }

        ; ── Foreground gate (applied after the snapshot gate, like the original) ──
        foreground := (ctx.gameActive || ctx.keepWhenBackground)

        allowedNoMap := core && foreground
        allowed      := core && mapOpenEff && foreground
        if (core && !foreground)
            reason := "not-foreground"

        return Map("allowed", allowed, "allowedNoMap", allowedNoMap, "reason", reason)
    }
}
