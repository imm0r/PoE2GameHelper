; GdiOverlayBase.ahk
; Shared base for lightweight, always-on-top, click-through GDI overlay windows.
; Provides the transparent window, double-buffer management, cached GDI objects
; (pens / brushes / fonts) and basic draw / blit / show / hide plumbing. Subclasses add
; their own state + render logic and call _EnsureShown()/_Blit() once per frame.
;
; NOTE: RadarOverlay and PlayerHUD predate this base and remain standalone for now;
; migrating them onto GdiOverlayBase is a separate, in-game-testable step. New overlays
; (e.g. NotificationOverlay) should extend this class. Member naming mirrors PlayerHUD
; (memDC / hwnd / bufW / bufH) as the canonical contract.
; Included by InGameStateMonitor.ahk (before any subclass).

class GdiOverlayBase
{
    ; Creates the transparent, click-through overlay window and initialises GDI state.
    ; transAlpha is the overall window opacity 0-255 (the 010101 colour-key stays transparent).
    __New(transAlpha := 255)
    {
        ; +ToolWindow keeps the overlay out of the taskbar / Alt-Tab list, so the
        ; per-tick Show()/Hide() cycle no longer flashes a taskbar button.
        this.overlayGui := Gui("-Caption +AlwaysOnTop +ToolWindow -DPIScale +E0x80000")
        this.overlayGui.BackColor := "010101"
        this.hwnd        := this.overlayGui.Hwnd
        this.memDC       := 0
        this.bitmap      := 0
        this.bufW        := 0
        this.bufH        := 0
        this.isVisible   := false
        this._styled     := false
        this._alpha      := transAlpha
        this._lastX      := -1
        this._lastY      := -1
        this._lastW      := 0
        this._lastH      := 0
        this._penCache   := Map()
        this._brushCache := Map()
        this._fontCache  := Map()
        this._bgBrush    := 0          ; cached transparent-key fill brush (back-buffer clear)
        ; ── Overlay contract (driven by OverlayManager) ──────────────────────
        this.Name        := "overlay"  ; subclasses override with a stable id
        this.Enabled     := true       ; master on/off toggle (manager hides when false)
    }

    ; ── Overlay contract ─────────────────────────────────────────────────────
    ; Template method run once per tick by OverlayManager. Subclasses do NOT
    ; override Update(); they override the three hooks below. Update() owns the
    ; uniform Enabled → ShouldShow → Layout → draw → blit flow and is the single
    ; place that decides show vs. hide, which keeps every overlay flicker-free by
    ; construction.
    Update(ctx)
    {
        if (!this.Enabled || !this.ShouldShow(ctx))
        {
            this.Hide()
            return
        }
        rect := this.Layout(ctx)
        if (!rect || rect["w"] < 1 || rect["h"] < 1)
        {
            this.Hide()
            return
        }
        if !this._EnsureShown(rect["x"], rect["y"], rect["w"], rect["h"])
            return
        this._ClearBackBuffer(rect["w"], rect["h"])
        this.Draw(ctx, rect)
        this._Blit(rect["w"], rect["h"])
    }

    ; Visibility policy — return true to show this frame, false to hide.
    ; Default: always show. Override per overlay (e.g. foreground/gate checks).
    ShouldShow(ctx) => true

    ; Returns the screen rectangle as Map("x","y","w","h"), or 0 to hide.
    ; Must be overridden by drawing subclasses.
    Layout(ctx) => 0

    ; Draws the overlay content onto the back-buffer (memDC). rect is the Map
    ; returned by Layout(). Must be overridden by drawing subclasses.
    Draw(ctx, rect)
    {
    }

    ; Clears the back-buffer to the transparent colour key (010101) so the
    ; previous frame's pixels don't bleed through. Brush is cached once.
    _ClearBackBuffer(w, h)
    {
        if !this._bgBrush
            this._bgBrush := DllCall("CreateSolidBrush", "UInt", 0x010101, "Ptr")
        this._FillRectBrush(0, 0, w, h, this._bgBrush)
    }

    ; FillRect helper that takes a ready HBRUSH (used by _ClearBackBuffer).
    _FillRectBrush(x, y, w, h, hBrush)
    {
        r := Buffer(16, 0)
        NumPut("Int", x, r, 0), NumPut("Int", y, r, 4)
        NumPut("Int", x + w, r, 8), NumPut("Int", y + h, r, 12)
        DllCall("FillRect", "Ptr", this.memDC, "Ptr", r, "Ptr", hBrush)
    }

    ; Sets overlay opacity (0-255). Applied on the next _EnsureShown styling pass.
    SetAlpha(alpha)
    {
        this._alpha := alpha
        if (this._styled && this.isVisible)
            WinSetTransColor("010101 " this._alpha, this.hwnd)
    }

    __Delete()
    {
        this._Cleanup()
    }

    ; Returns a cached HPEN for colorBGR/width (created once, freed in _Cleanup).
    _GetPen(colorBGR, width := 1)
    {
        key := colorBGR | (width << 24)
        if !this._penCache.Has(key)
            this._penCache[key] := DllCall("CreatePen", "Int", 0, "Int", width, "UInt", colorBGR, "Ptr")
        return this._penCache[key]
    }

    ; Returns a cached HBRUSH for colorBGR (created once, freed in _Cleanup).
    _GetBrush(colorBGR)
    {
        if !this._brushCache.Has(colorBGR)
            this._brushCache[colorBGR] := DllCall("CreateSolidBrush", "UInt", colorBGR, "Ptr")
        return this._brushCache[colorBGR]
    }

    ; Returns a cached HFONT for the given pixel height/weight/face (created once, freed in _Cleanup).
    ; Negative height = character height in pixels (GDI convention).
    _GetFont(height, weight := 400, face := "Segoe UI")
    {
        key := face "|" height "|" weight
        if !this._fontCache.Has(key)
            this._fontCache[key] := DllCall("CreateFontW", "Int", height, "Int", 0, "Int", 0, "Int", 0
                , "Int", weight, "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 1, "UInt", 0, "UInt", 0
                , "UInt", 5, "UInt", 0, "Str", face, "Ptr")
        return this._fontCache[key]
    }

    ; (Re)creates the back-buffer DC + bitmap sized to w x h. Called when the size changes.
    _InitBuffers(w, h)
    {
        if this.bitmap
        {
            stockBmp := DllCall("GetStockObject", "Int", 0, "Ptr")
            DllCall("SelectObject", "Ptr", this.memDC, "Ptr", stockBmp)
            DllCall("DeleteObject", "Ptr", this.bitmap)
            DllCall("DeleteDC",     "Ptr", this.memDC)
        }
        scrDC       := DllCall("GetDC", "Ptr", this.hwnd, "Ptr")
        this.memDC  := DllCall("CreateCompatibleDC",     "Ptr", scrDC, "Ptr")
        this.bitmap := DllCall("CreateCompatibleBitmap", "Ptr", scrDC, "Int", w, "Int", h, "Ptr")
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", this.bitmap)
        DllCall("ReleaseDC", "Ptr", this.hwnd, "Ptr", scrDC)
        this.bufW := w
        this.bufH := h
    }

    ; Ensures the window is shown at x,y sized w x h, styled (transparent + click-through) once,
    ; and that the back-buffer matches w x h. Returns true when memDC is ready to draw.
    _EnsureShown(x, y, w, h)
    {
        if !this.isVisible
        {
            this.overlayGui.Show("x" x " y" y " w" w " h" h " NoActivate")
            this.isVisible := true
            this._lastX := x, this._lastY := y, this._lastW := w, this._lastH := h
            if !this._styled
            {
                WinSetTransColor("010101 " this._alpha, this.hwnd)
                WinSetExStyle("+0x20", this.hwnd)   ; WS_EX_TRANSPARENT -> click-through
                this._styled := true
            }
        }
        else if (x != this._lastX || y != this._lastY || w != this._lastW || h != this._lastH)
        {
            WinMove(x, y, w, h, this.hwnd)
            this._lastX := x, this._lastY := y, this._lastW := w, this._lastH := h
        }
        if (this.bufW != w || this.bufH != h)
            this._InitBuffers(w, h)
        return this.memDC ? true : false
    }

    ; Copies the back-buffer to the window's screen DC (SRCCOPY).
    _Blit(w, h)
    {
        scrDC := DllCall("GetDC", "Ptr", this.hwnd, "Ptr")
        DllCall("BitBlt", "Ptr", scrDC, "Int", 0, "Int", 0, "Int", w, "Int", h
            , "Ptr", this.memDC, "Int", 0, "Int", 0, "UInt", 0x00CC0020)
        DllCall("ReleaseDC", "Ptr", this.hwnd, "Ptr", scrDC)
    }

    ; Hides the window (no blit happens while hidden).
    Hide()
    {
        if this.isVisible
        {
            this.overlayGui.Hide()
            this.isVisible := false
        }
    }

    ; Fills a rectangle on the back-buffer with colorBGR.
    _FillRect(x, y, w, h, colorBGR)
    {
        r := Buffer(16, 0)
        NumPut("Int", x, r, 0), NumPut("Int", y, r, 4)
        NumPut("Int", x + w, r, 8), NumPut("Int", y + h, r, 12)
        DllCall("FillRect", "Ptr", this.memDC, "Ptr", r, "Ptr", this._GetBrush(colorBGR))
    }

    ; Draws a rectangular outline (no fill) on the back-buffer with colorBGR/penWidth.
    _DrawRectOutline(x, y, w, h, colorBGR, penWidth := 1)
    {
        pen := this._GetPen(colorBGR, penWidth)
        nullBrush := DllCall("GetStockObject", "Int", 5, "Ptr")   ; NULL_BRUSH (hollow)
        op := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", pen, "Ptr")
        ob := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", nullBrush, "Ptr")
        DllCall("Rectangle", "Ptr", this.memDC, "Int", x, "Int", y, "Int", x + w, "Int", y + h)
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", op)
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", ob)
    }

    ; Draws text at sx,sy with the given colour (transparent background). The caller must have
    ; selected the desired font onto memDC beforehand.
    _DrawText(sx, sy, text, colorBGR)
    {
        DllCall("SetBkMode",    "Ptr", this.memDC, "Int", 1)   ; TRANSPARENT
        DllCall("SetTextColor", "Ptr", this.memDC, "UInt", colorBGR)
        DllCall("TextOutW", "Ptr", this.memDC, "Int", sx, "Int", sy, "Str", text, "Int", StrLen(text))
    }

    ; Measures text extent (px) for a font handle without needing the back-buffer.
    ; Returns Map("w", cx, "h", cy).
    _MeasureText(font, text)
    {
        scrDC := DllCall("GetDC", "Ptr", 0, "Ptr")
        oldFont := DllCall("SelectObject", "Ptr", scrDC, "Ptr", font, "Ptr")
        sz := Buffer(8, 0)
        DllCall("GetTextExtentPoint32W", "Ptr", scrDC, "Str", text, "Int", StrLen(text), "Ptr", sz)
        DllCall("SelectObject", "Ptr", scrDC, "Ptr", oldFont)
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", scrDC)
        return Map("w", NumGet(sz, 0, "Int"), "h", NumGet(sz, 4, "Int"))
    }

    ; Frees all cached GDI objects and the back-buffer. Called from __Delete.
    _Cleanup()
    {
        for _, pen in this._penCache
            DllCall("DeleteObject", "Ptr", pen)
        for _, brush in this._brushCache
            DllCall("DeleteObject", "Ptr", brush)
        for _, font in this._fontCache
            DllCall("DeleteObject", "Ptr", font)
        if this._bgBrush
            DllCall("DeleteObject", "Ptr", this._bgBrush)
        if this.bitmap
        {
            stockBmp := DllCall("GetStockObject", "Int", 0, "Ptr")
            DllCall("SelectObject", "Ptr", this.memDC, "Ptr", stockBmp)
            DllCall("DeleteObject", "Ptr", this.bitmap)
            DllCall("DeleteDC",     "Ptr", this.memDC)
        }
    }
}
