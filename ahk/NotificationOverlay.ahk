; NotificationOverlay.ahk
; Map-independent notification overlay (entity-alert banners, future toasts).
; Unlike RadarOverlay / PlayerHUD it is NOT tied to the large-map / panel gate: it shows
; whenever the game window is focused and a notification is active, and stays fully hidden
; (no blit) otherwise. Extends GdiOverlayBase. Driven once per tick via Tick(); content is
; set via SetBanner(). Depends on ResolvePoEWindow() (AutoFlask.ahk).
; Included by InGameStateMonitor.ahk (after GdiOverlayBase).

class NotificationOverlay extends GdiOverlayBase
{
    ; BGR colours
    static COLOR_BG     := 0x101010   ; banner bar background
    static COLOR_BORDER := 0x5AA8C8   ; muted gold border (#c8a85a)
    static COLOR_TEXT   := 0x8AD6F0   ; gold text (#f0d68a)
    ; Layout
    static PAD_X        := 22
    static PAD_Y        := 10
    static FONT_HEIGHT  := -28        ; negative = char height in px
    static FONT_WEIGHT  := 700
    static TOP_FRACTION := 0.08       ; banner top offset as a fraction of game-window height

    __New()
    {
        super.__New(255)
        this._bannerText  := ""
        this._bannerUntil := 0
        this._bannerColor := NotificationOverlay.COLOR_TEXT
    }

    ; Shows a banner with <text> for <durationMs>. colorBGR (non-zero) overrides the text colour.
    ; Replaces any currently-shown banner; cleared automatically once the deadline passes.
    SetBanner(text, durationMs := 2500, colorBGR := 0)
    {
        this._bannerText  := text
        this._bannerColor := colorBGR ? colorBGR : NotificationOverlay.COLOR_TEXT
        this._bannerUntil := A_TickCount + Abs(durationMs)
    }

    ; Per-tick driver (call early in UpdateRadarFast, before the radar hide-returns).
    ; No-op + hidden when nothing is active OR the game isn't foreground — so the idle cost is
    ; just a couple of cheap checks (no WinGetPos, no blit).
    Tick()
    {
        if (this._bannerText = "" || A_TickCount > this._bannerUntil)
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
        this._RenderBanner(gwX, gwY, gwW, gwH)
    }

    ; Lays out and draws the banner bar (background + gold border + centered text), then blits.
    _RenderBanner(gwX, gwY, gwW, gwH)
    {
        font := this._GetFont(NotificationOverlay.FONT_HEIGHT, NotificationOverlay.FONT_WEIGHT)
        m := this._MeasureText(font, this._bannerText)
        padX := NotificationOverlay.PAD_X, padY := NotificationOverlay.PAD_Y
        barW := m["w"] + padX * 2
        barH := m["h"] + padY * 2

        x := gwX + (gwW - barW) // 2
        y := gwY + Round(gwH * NotificationOverlay.TOP_FRACTION)

        if !this._EnsureShown(x, y, barW, barH)
            return

        this._FillRect(0, 0, barW, barH, NotificationOverlay.COLOR_BG)
        this._DrawRectOutline(0, 0, barW, barH, NotificationOverlay.COLOR_BORDER, 2)

        oldFont := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", font, "Ptr")
        this._DrawText(padX, padY, this._bannerText, this._bannerColor)
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldFont)

        this._Blit(barW, barH)
    }
}
