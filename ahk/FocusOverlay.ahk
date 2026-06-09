; FocusOverlay.ahk
; Small always-on-top, click-through GDI overlay that prints a few text lines
; (focused-entity debug readout) near the top-left of the PoE window. Test surface
; for the targeted-monster + hovered-world-object resolution. Extends GdiOverlayBase
; and is driven by OverlayManager via the uniform ShouldShow/Layout/Draw contract.
; It builds its own lines each tick from the snapshot via BuildFocusLines().
; Included by InGameStateMonitor.ahk (after GdiOverlayBase).

class FocusOverlay extends GdiOverlayBase
{
    ; BGR colours
    static COLOR_BG      := 0x101010
    static COLOR_BORDER  := 0x5AA8C8
    static COLOR_TEXT    := 0xC8E6F0
    ; Layout
    static PAD_X         := 12
    static PAD_Y         := 8
    static LINE_GAP      := 2
    static FONT_HEIGHT   := -18       ; negative = char height in px
    static FONT_WEIGHT   := 600
    static LEFT_FRACTION := 0.012     ; x margin as a fraction of game-window width
    static TOP_FRACTION  := 0.22      ; y position as a fraction of game-window height

    __New()
    {
        super.__New(255)
        this.Name   := "focus"
        this._lines := []
    }

    ; ── Overlay contract ────────────────────────────────────────────────────
    ; Enabled via g_focusOverlayEnabled; visible only when the game is focused and
    ; the snapshot yields at least one focus line. Lines are (re)built here so
    ; Layout/Draw can reuse them without re-reading memory.
    ShouldShow(ctx)
    {
        global g_focusOverlayEnabled
        this._lines := []
        if !(IsSet(g_focusOverlayEnabled) && g_focusOverlayEnabled)
            return false
        if (!ctx.gameActive || ctx.gwW < 200 || ctx.gwH < 100)
            return false
        try this._lines := BuildFocusLines(ctx.reader, ctx.snapshot)
        return (Type(this._lines) = "Array" && this._lines.Length > 0)
    }

    ; Sized to the widest line + stacked height, anchored top-left of the viewport.
    Layout(ctx)
    {
        font  := this._GetFont(FocusOverlay.FONT_HEIGHT, FocusOverlay.FONT_WEIGHT)
        maxW  := 0
        lineH := 0
        for _, ln in this._lines
        {
            m := this._MeasureText(font, ln)
            if (m["w"] > maxW)
                maxW := m["w"]
            if (m["h"] > lineH)
                lineH := m["h"]
        }
        padX := FocusOverlay.PAD_X, padY := FocusOverlay.PAD_Y, gap := FocusOverlay.LINE_GAP
        barW := maxW + padX * 2
        barH := this._lines.Length * lineH + (this._lines.Length - 1) * gap + padY * 2
        return Map("x", ctx.gwX + Round(ctx.gwW * FocusOverlay.LEFT_FRACTION)
                 , "y", ctx.gwY + Round(ctx.gwH * FocusOverlay.TOP_FRACTION)
                 , "w", barW, "h", barH)
    }

    ; Background + border + each line.
    Draw(ctx, rect)
    {
        w := rect["w"], h := rect["h"]
        this._FillRect(0, 0, w, h, FocusOverlay.COLOR_BG)
        this._DrawRectOutline(0, 0, w, h, FocusOverlay.COLOR_BORDER, 1)

        font := this._GetFont(FocusOverlay.FONT_HEIGHT, FocusOverlay.FONT_WEIGHT)
        oldFont := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", font, "Ptr")
        padX := FocusOverlay.PAD_X, gap := FocusOverlay.LINE_GAP
        ; Recompute the line height the same way Layout did, for vertical stepping.
        lineH := 0
        for _, ln in this._lines
        {
            m := this._MeasureText(font, ln)
            if (m["h"] > lineH)
                lineH := m["h"]
        }
        ty := FocusOverlay.PAD_Y
        for _, ln in this._lines
        {
            this._DrawText(padX, ty, ln, FocusOverlay.COLOR_TEXT)
            ty += lineH + gap
        }
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldFont)
    }
}
