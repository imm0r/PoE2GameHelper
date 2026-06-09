; NotificationOverlay.ahk
; Map-independent notification overlay (entity-alert banners, future toasts).
; Unlike RadarOverlay / PlayerHUD it does NOT follow the play-overlay gate: it shows
; whenever the game window is focused and a banner is active, and stays fully hidden
; otherwise. Extends GdiOverlayBase and is driven by OverlayManager via the uniform
; ShouldShow/Layout/Draw contract. Content is set via SetBanner() (EntityAlerts).
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
        this.Name         := "notification"
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

    ; ── Overlay contract ────────────────────────────────────────────────────
    ; Visible only while a banner is active AND the game window is focused
    ; (map-independent — does NOT use the play-overlay gate).
    ShouldShow(ctx)
    {
        if (this._bannerText = "" || A_TickCount > this._bannerUntil)
            return false
        if !ctx.gameActive
            return false
        return (ctx.gwW >= 200 && ctx.gwH >= 100)
    }

    ; Centered horizontally, near the top of the game window. Width follows the text.
    Layout(ctx)
    {
        font := this._GetFont(NotificationOverlay.FONT_HEIGHT, NotificationOverlay.FONT_WEIGHT)
        m    := this._MeasureText(font, this._bannerText)
        barW := m["w"] + NotificationOverlay.PAD_X * 2
        barH := m["h"] + NotificationOverlay.PAD_Y * 2
        return Map("x", ctx.gwX + (ctx.gwW - barW) // 2
                 , "y", ctx.gwY + Round(ctx.gwH * NotificationOverlay.TOP_FRACTION)
                 , "w", barW, "h", barH)
    }

    ; Background bar + gold border + banner text.
    Draw(ctx, rect)
    {
        w := rect["w"], h := rect["h"]
        this._FillRect(0, 0, w, h, NotificationOverlay.COLOR_BG)
        this._DrawRectOutline(0, 0, w, h, NotificationOverlay.COLOR_BORDER, 2)

        font := this._GetFont(NotificationOverlay.FONT_HEIGHT, NotificationOverlay.FONT_WEIGHT)
        oldFont := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", font, "Ptr")
        this._DrawText(NotificationOverlay.PAD_X, NotificationOverlay.PAD_Y, this._bannerText, this._bannerColor)
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldFont)
    }
}
