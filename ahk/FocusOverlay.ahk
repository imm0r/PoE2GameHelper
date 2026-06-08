; FocusOverlay.ahk
; Small always-on-top, click-through GDI overlay that prints a few text lines
; (focused-entity debug readout) near the top-left of the PoE window. Test surface
; for the targeted-monster + hovered-world-object resolution. Extends GdiOverlayBase.
; Driven once per tick via Tick(); content set via SetLines().
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
        this._lines := []
    }

    ; Sets the lines to display (array of strings). An empty array hides the overlay.
    SetLines(lines)
    {
        this._lines := (lines && Type(lines) = "Array") ? lines : []
    }

    ; Per-tick driver (call from UpdateRadarFast). Foreground-gated; hidden when
    ; there are no lines or the game isn't the active window.
    Tick()
    {
        if (this._lines.Length = 0)
        {
            this.Hide()
            return
        }
        gameHwnd := ResolvePoEWindow()
        if (!gameHwnd || !WinActive("ahk_id " gameHwnd))
        {
            this.Hide()
            return
        }
        gwX := 0, gwY := 0, gwW := 0, gwH := 0
        try WinGetPos(&gwX, &gwY, &gwW, &gwH, "ahk_id " gameHwnd)
        if (gwW < 200 || gwH < 100)
        {
            this.Hide()
            return
        }
        this._Render(gwX, gwY, gwW, gwH)
    }

    ; Lays out the lines (widest line + stacked height), draws bg + border + each
    ; line, then blits. One cached font; measured per line.
    _Render(gwX, gwY, gwW, gwH)
    {
        font := this._GetFont(FocusOverlay.FONT_HEIGHT, FocusOverlay.FONT_WEIGHT)
        padX := FocusOverlay.PAD_X, padY := FocusOverlay.PAD_Y, gap := FocusOverlay.LINE_GAP

        maxW := 0
        lineH := 0
        for _, ln in this._lines
        {
            m := this._MeasureText(font, ln)
            if (m["w"] > maxW)
                maxW := m["w"]
            if (m["h"] > lineH)
                lineH := m["h"]
        }
        barW := maxW + padX * 2
        barH := this._lines.Length * lineH + (this._lines.Length - 1) * gap + padY * 2

        x := gwX + Round(gwW * FocusOverlay.LEFT_FRACTION)
        y := gwY + Round(gwH * FocusOverlay.TOP_FRACTION)

        if !this._EnsureShown(x, y, barW, barH)
            return

        this._FillRect(0, 0, barW, barH, FocusOverlay.COLOR_BG)
        this._DrawRectOutline(0, 0, barW, barH, FocusOverlay.COLOR_BORDER, 1)

        oldFont := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", font, "Ptr")
        ty := padY
        for _, ln in this._lines
        {
            this._DrawText(padX, ty, ln, FocusOverlay.COLOR_TEXT)
            ty += lineH + gap
        }
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldFont)

        this._Blit(barW, barH)
    }
}
