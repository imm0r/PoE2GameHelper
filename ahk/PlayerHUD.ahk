; PlayerHUD.ahk
; Lightweight always-on-top, click-through GDI overlay showing game state and player vitals.
;
; Displays: current game state, life bar, mana bar, energy shield bar (when applicable).
; Positioned at top-center of the game window. Extends GdiOverlayBase, which owns the
; transparent window, the double buffer, the pen/brush/font caches and the Show/Hide/blit
; plumbing. The HUD only adds its visibility policy, layout and frame rendering.
;
; Included by InGameStateMonitor.ahk

class PlayerHUD extends GdiOverlayBase
{
    ; BGR colors
    static COLOR_BG         := 0x302020   ; dark background for bars
    static COLOR_LIFE       := 0x2222DD   ; red (BGR)
    static COLOR_MANA       := 0xDD7722   ; blue-ish (BGR)
    static COLOR_ES         := 0xCCCC44   ; cyan-ish (BGR)
    static COLOR_TEXT        := 0xDDDDDD   ; light gray
    static COLOR_TEXT_DIM    := 0x888888   ; dim gray
    static COLOR_STATE_GOOD  := 0x44DD44   ; green
    static COLOR_STATE_WARN  := 0x22CCFF   ; yellow-ish (BGR)
    static COLOR_BAR_EMPTY   := 0x222222   ; dark empty bar
    static COLOR_BORDER      := 0x555555   ; bar border

    ; HUD dimensions
    static HUD_WIDTH   := 280
    static HUD_HEIGHT  := 68
    static BAR_HEIGHT  := 10
    static BAR_MARGIN  := 4
    static PADDING     := 6

    __New()
    {
        super.__New(230)        ; HUD opacity 230 (background colour-key stays transparent)
        this.Name := "playerHud"
    }

    ; ── Overlay contract (driven by OverlayManager) ─────────────────────────
    ; The HUD shares the play-overlay gate with the radar (they show together),
    ; gated additionally by the user's HUD on/off toggle.
    ShouldShow(ctx)
    {
        global g_playerHudEnabled
        return ctx.gate["allowed"] && (IsSet(g_playerHudEnabled) ? g_playerHudEnabled : true)
    }

    ; Top-center of the game window.
    Layout(ctx)
    {
        if (ctx.gwW < 100 || ctx.gwH < 100)
            return 0
        w := PlayerHUD.HUD_WIDTH, h := PlayerHUD.HUD_HEIGHT
        return Map("x", ctx.gwX + Floor((ctx.gwW - w) / 2), "y", ctx.gwY + 2, "w", w, "h", h)
    }

    ; Builds the vitals data from the snapshot, then renders the frame.
    Draw(ctx, rect)
    {
        data := this._ExtractHud(ctx.snapshot, ctx.currentState)
        this._RenderFrame(data, rect["w"], rect["h"])
    }

    ; Extracts state + life/mana/ES from the radar snapshot into a flat Map.
    _ExtractHud(snap, currentState)
    {
        data := Map()
        data["stateName"] := currentState
        data["areaLevel"] := (snap && IsObject(snap) && snap.Has("areaLevel")) ? snap["areaLevel"] : 0

        pv := (snap && IsObject(snap) && snap.Has("playerVitals")) ? snap["playerVitals"] : 0
        if (pv && IsObject(pv) && pv.Has("stats"))
        {
            stats := pv["stats"]
            lifeCur := stats.Has("lifeCurrent") ? stats["lifeCurrent"] : 0
            lifeMax := stats.Has("lifeMax") ? stats["lifeMax"] : 1
            manaCur := stats.Has("manaCurrent") ? stats["manaCurrent"] : 0
            manaMax := stats.Has("manaMax") ? stats["manaMax"] : 1
            esCur   := stats.Has("esCurrent") ? stats["esCurrent"] : 0
            esMax   := stats.Has("esMax") ? stats["esMax"] : 0

            data["lifeCur"] := lifeCur
            data["lifeMax"] := lifeMax
            data["lifePct"] := lifeMax > 0 ? (lifeCur / lifeMax) * 100 : 0
            data["manaCur"] := manaCur
            data["manaMax"] := manaMax
            data["manaPct"] := manaMax > 0 ? (manaCur / manaMax) * 100 : 0
            data["esCur"]   := esCur
            data["esMax"]   := esMax
            data["esPct"]   := esMax > 0 ? (esCur / esMax) * 100 : 0
        }
        else
        {
            data["lifeCur"] := 0, data["lifeMax"] := 0, data["lifePct"] := 0
            data["manaCur"] := 0, data["manaMax"] := 0, data["manaPct"] := 0
            data["esCur"] := 0, data["esMax"] := 0, data["esPct"] := 0
        }
        return data
    }

    ; ── Rendering ─────────────────────────────────────────────────────────

    _RenderFrame(data, w, h)
    {
        ; Solid dark HUD panel over the whole rect (the back-buffer was already
        ; cleared to the transparent key by GdiOverlayBase.Update()).
        this._FillRectBrush(0, 0, w, h, this._GetBrush(PlayerHUD.COLOR_BG))

        pad := PlayerHUD.PADDING

        ; Line 1: Game state
        stateName := (data && data.Has("stateName")) ? data["stateName"] : "Unknown"
        areaLevel := (data && data.Has("areaLevel")) ? data["areaLevel"] : 0
        stateColor := (stateName = "InGameState") ? PlayerHUD.COLOR_STATE_GOOD : PlayerHUD.COLOR_STATE_WARN
        stateText := this._FormatStateName(stateName)
        if (areaLevel > 0 && stateName = "InGameState")
            stateText .= "  ·  Zone Lv " areaLevel

        oldFont := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", this._GetFont(-13, 600), "Ptr")
        this._DrawText(pad, pad, stateText, stateColor)

        ; Line 2: Life bar + Mana bar (side by side)
        barY := pad + 18
        barW := Floor((w - pad * 3) / 2)
        barH := PlayerHUD.BAR_HEIGHT

        lifePct := (data && data.Has("lifePct")) ? data["lifePct"] : 0
        manaPct := (data && data.Has("manaPct")) ? data["manaPct"] : 0
        esPct   := (data && data.Has("esPct"))   ? data["esPct"]   : 0

        lifeCur := (data && data.Has("lifeCur")) ? data["lifeCur"] : 0
        lifeMax := (data && data.Has("lifeMax")) ? data["lifeMax"] : 0
        manaCur := (data && data.Has("manaCur")) ? data["manaCur"] : 0
        manaMax := (data && data.Has("manaMax")) ? data["manaMax"] : 0
        esCur   := (data && data.Has("esCur"))   ? data["esCur"]   : 0
        esMax   := (data && data.Has("esMax"))    ? data["esMax"]   : 0

        ; Life bar (left)
        this._DrawBar(pad, barY, barW, barH, lifePct, PlayerHUD.COLOR_LIFE)
        ; Mana bar (right)
        this._DrawBar(pad * 2 + barW, barY, barW, barH, manaPct, PlayerHUD.COLOR_MANA)

        ; Text labels below bars
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", this._GetFont(-11, 400), "Ptr")
        labelY := barY + barH + 2
        lifeLabel := lifeCur "/" lifeMax " (" Round(lifePct) "%)"
        manaLabel := manaCur "/" manaMax " (" Round(manaPct) "%)"
        this._DrawText(pad, labelY, lifeLabel, PlayerHUD.COLOR_LIFE)
        this._DrawText(pad * 2 + barW, labelY, manaLabel, PlayerHUD.COLOR_MANA)

        ; ES bar (full width, only if player has ES)
        if (esMax > 0)
        {
            esBarY := labelY + 14
            esBarW := w - pad * 2
            this._DrawBar(pad, esBarY, esBarW, barH - 2, esPct, PlayerHUD.COLOR_ES)
            esLabel := "ES: " esCur "/" esMax " (" Round(esPct) "%)"
            this._DrawText(pad, esBarY + barH, esLabel, PlayerHUD.COLOR_ES)
        }

        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldFont, "Ptr")
    }

    _FormatStateName(name)
    {
        if (name = "InGameState")
            return "In Game"
        if (name = "AreaLoadingState" || name = "LoadingState")
            return "Loading..."
        if (name = "LoginState")
            return "Login Screen"
        if (name = "SelectCharacterState")
            return "Character Select"
        if (name = "EscapeState")
            return "Menu"
        if (name = "PreGameState")
            return "Pre-Game"
        return name
    }

    _DrawBar(x, y, w, h, pct, fillColor)
    {
        ; Empty bar background
        this._FillRectBrush(x, y, w, h, this._GetBrush(PlayerHUD.COLOR_BAR_EMPTY))

        ; Filled portion
        if (pct > 0)
        {
            fillW := Floor(w * Min(pct, 100) / 100)
            if (fillW > 0)
                this._FillRectBrush(x, y, fillW, h, this._GetBrush(fillColor))
        }

        ; Border
        borderPen := this._GetPen(PlayerHUD.COLOR_BORDER)
        nullBrush := DllCall("GetStockObject", "Int", 5, "Ptr")
        oldPen   := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", borderPen, "Ptr")
        oldBrush := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", nullBrush, "Ptr")
        DllCall("Rectangle", "Ptr", this.memDC,
                "Int", x, "Int", y, "Int", x + w, "Int", y + h)
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldPen)
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldBrush)
    }
}
