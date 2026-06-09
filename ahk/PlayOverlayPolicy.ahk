; PlayOverlayPolicy.ahk
; Single source of truth for "should the play overlays (radar + player HUD) be
; visible this tick". Ported verbatim from the inlined gate that used to live in
; UpdateRadarFast (AutoFlask.ahk): the six in-game conditions, the panel-open
; debounce, the GC-sensitive grace for no-largemap / no-player, the UI-browser
; inspect override and the foreground gate. Owns the small amount of persistent
; debounce/grace state across ticks, so the manager can stay stateless.
; Included by InGameStateMonitor.ahk (before OverlayManager).

class PlayOverlayPolicy
{
    static GRACE_MS          := 800   ; tolerate brief no-largemap / no-player gaps (GC reads)
    static PANEL_DEBOUNCE_MS := 500   ; combat UI flickers visibility; require panel to persist

    __New()
    {
        this._condHideTick       := 0   ; A_TickCount when a GC-sensitive hide reason first appeared
        this._panelOpenSinceTick := 0   ; A_TickCount when a panel was first detected open
    }

    ; Evaluates the gate for this tick. Returns Map("allowed", bool, "reason", str).
    ; ctx must have: snapshot, currentState, gameActive, keepWhenBackground, inspectOverride.
    Evaluate(ctx)
    {
        snap    := ctx.snapshot
        allowed := true
        reason  := ""

        if !(snap && IsObject(snap))
            return Map("allowed", false, "reason", "no-snapshot")

        ; ── Condition 1: reject states that definitely have no player/area ──
        static nonGameStates := Map(
            "PreGameState", true, "LoginState", true, "WaitingState", true,
            "CreateCharacterState", true, "SelectCharacterState", true,
            "DeleteCharacterState", true, "ChangePasswordState", true,
            "CreditsState", true, "LoadingState", true)
        if nonGameStates.Has(ctx.currentState)
        {
            allowed := false
            reason  := "not-ingame(" ctx.currentState ")"
        }

        ; ── Condition 2: not town or hideout ──
        if allowed
        {
            wad := snap.Has("worldAreaDat") ? snap["worldAreaDat"] : 0
            if (wad && IsObject(wad)
                && ((wad.Has("isTown") && wad["isTown"]) || (wad.Has("isHideout") && wad["isHideout"])))
            {
                allowed := false
                reason  := "town-hideout"
            }
        }

        ; ── Condition 3: player must be alive ──
        if allowed
        {
            pv := snap.Has("playerVitals") ? snap["playerVitals"] : 0
            if (pv && IsObject(pv) && pv.Has("stats"))
            {
                st := pv["stats"]
                if (st.Has("isAlive") && !st["isAlive"])
                {
                    allowed := false
                    reason  := "dead"
                }
            }
        }

        ; ── Condition 4: large map must be visible (overlay draws on the large map) ──
        if allowed
        {
            inGs    := snap.Has("inGameState") ? snap["inGameState"] : 0
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
                allowed := false
                reason  := "no-largemap"
            }
        }

        ; ── Condition 5: no game panel open + chat not active (panel debounced) ──
        if allowed
        {
            panelVis      := snap.Has("panelVisibility") ? snap["panelVisibility"] : 0
            panelDetected := (panelVis && IsObject(panelVis) && panelVis.Has("anyPanelOpen") && panelVis["anyPanelOpen"])
            if panelDetected
            {
                if (this._panelOpenSinceTick = 0)
                    this._panelOpenSinceTick := A_TickCount
                if ((A_TickCount - this._panelOpenSinceTick) >= PlayOverlayPolicy.PANEL_DEBOUNCE_MS)
                {
                    allowed  := false
                    newlyVis := panelVis.Has("newlyVisible") ? panelVis["newlyVisible"] : 0
                    reason   := "panel-open(" newlyVis " new)"
                }
            }
            else
            {
                this._panelOpenSinceTick := 0
            }

            if allowed
            {
                inGs    := snap.Has("inGameState") ? snap["inGameState"] : 0
                uiElems := (inGs && IsObject(inGs) && inGs.Has("importantUiElements")) ? inGs["importantUiElements"] : 0
                if (uiElems && IsObject(uiElems) && uiElems.Has("isChatActive") && uiElems["isChatActive"])
                {
                    allowed := false
                    reason  := "chat-active"
                }
            }
        }

        ; ── Condition 6: player render component present (truly in-game) ──
        if allowed
        {
            inGs := snap.Has("inGameState") ? snap["inGameState"] : 0
            area := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
            playerRender := (area && IsObject(area) && area.Has("playerRenderComponent")) ? area["playerRenderComponent"] : 0
            if !playerRender
            {
                allowed := false
                reason  := "no-player"
            }
        }

        ; ── UI-browser inspect mode overrides all hide conditions ──
        if ctx.inspectOverride
        {
            allowed := true
            reason  := "ui-inspect"
        }

        ; ── Grace for GC-sensitive negatives (no-largemap / no-player) ──
        if !allowed
        {
            if (reason = "no-largemap" || reason = "no-player")
            {
                if (this._condHideTick = 0)
                    this._condHideTick := A_TickCount
                if ((A_TickCount - this._condHideTick) < PlayOverlayPolicy.GRACE_MS)
                {
                    allowed := true              ; within grace — keep showing with last data
                    reason  := "grace(" reason ")"
                }
                else
                {
                    this._condHideTick := 0
                }
            }
        }
        else
        {
            this._condHideTick := 0
        }

        ; ── Foreground gate (applied after the snapshot gate, like the original) ──
        if (allowed && !(ctx.gameActive || ctx.keepWhenBackground))
        {
            allowed := false
            reason  := "not-foreground"
        }

        return Map("allowed", allowed, "reason", reason)
    }
}
