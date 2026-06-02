; PlayerHUD.ahk
; Lightweight always-on-top, click-through GDI overlay showing game state and player vitals.
;
; Displays: current game state, life bar, mana bar, energy shield bar (when applicable).
; Positioned at top-center of the game window. Rendered via double-buffered GDI.
;
; Included by InGameStateMonitor.ahk

class PlayerHUD
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
        this.overlayGui   := Gui("-Caption +AlwaysOnTop -DPIScale +E0x80000")
        this.overlayGui.BackColor := "010101"
        this.hwnd         := this.overlayGui.Hwnd
        this.memDC        := 0
        this.bitmap       := 0
        this.bufW         := 0
        this.bufH         := 0
        this.isVisible    := false
        this._styled      := false
        this._lastX       := -1
        this._lastY       := -1
        this._penCache    := Map()
        this._brushCache  := Map()
        this._font        := 0
        this._fontSmall   := 0
    }

    __Delete()
    {
        this._Cleanup()
    }

    ; Updates the HUD with fresh data and renders it.
    ; Params:
    ;   data - Map with keys: stateName, areaLevel, lifePct, manaPct, esPct,
    ;          lifeCur, lifeMax, manaCur, manaMax, esCur, esMax
    ;   gwX, gwY, gwW, gwH - game window position/size
    Update(data, gwX, gwY, gwW, gwH)
    {
        if (gwW < 100 || gwH < 100)
            return

        w := PlayerHUD.HUD_WIDTH
        h := PlayerHUD.HUD_HEIGHT
        x := gwX + Floor((gwW - w) / 2)
        y := gwY + 2

        if (x != this._lastX || y != this._lastY)
        {
            if this.isVisible
                WinMove(x, y, w, h, this.hwnd)
            this._lastX := x
            this._lastY := y
        }

        if !this.isVisible
        {
            this.overlayGui.Show("x" x " y" y " w" w " h" h " NoActivate")
            this.isVisible := true
            if !this._styled
            {
                WinSetTransColor("010101 230", this.hwnd)
                WinSetExStyle("+0x20", this.hwnd)
                this._styled := true
            }
        }

        if (this.bufW != w || this.bufH != h)
            this._InitBuffers(w, h)
        if !this.memDC
            return

        this._RenderFrame(data, w, h)
        this._Blit(w, h)
    }

    Hide()
    {
        if this.isVisible
        {
            this.overlayGui.Hide()
            this.isVisible := false
        }
    }

    ; ── Rendering ─────────────────────────────────────────────────────────

    _RenderFrame(data, w, h)
    {
        ; Clear with near-black (transparency key)
        bgBrush := this._GetBrush(0x010101)
        rect := Buffer(16, 0)
        NumPut("Int", 0, rect, 0)
        NumPut("Int", 0, rect, 4)
        NumPut("Int", w, rect, 8)
        NumPut("Int", h, rect, 12)
        DllCall("FillRect", "Ptr", this.memDC, "Ptr", rect, "Ptr", bgBrush)

        ; Draw semi-transparent background panel
        panelBrush := this._GetBrush(PlayerHUD.COLOR_BG)
        DllCall("FillRect", "Ptr", this.memDC, "Ptr", rect, "Ptr", panelBrush)

        if !this._font
            this._CreateFonts()

        pad := PlayerHUD.PADDING

        ; Line 1: Game state
        stateName := (data && data.Has("stateName")) ? data["stateName"] : "Unknown"
        areaLevel := (data && data.Has("areaLevel")) ? data["areaLevel"] : 0
        stateColor := (stateName = "InGameState") ? PlayerHUD.COLOR_STATE_GOOD : PlayerHUD.COLOR_STATE_WARN
        stateText := this._FormatStateName(stateName)
        if (areaLevel > 0 && stateName = "InGameState")
            stateText .= "  ·  Zone Lv " areaLevel

        oldFont := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", this._font, "Ptr")
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
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", this._fontSmall, "Ptr")
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
        emptyBrush := this._GetBrush(PlayerHUD.COLOR_BAR_EMPTY)
        rect := Buffer(16, 0)
        NumPut("Int", x, rect, 0)
        NumPut("Int", y, rect, 4)
        NumPut("Int", x + w, rect, 8)
        NumPut("Int", y + h, rect, 12)
        DllCall("FillRect", "Ptr", this.memDC, "Ptr", rect, "Ptr", emptyBrush)

        ; Filled portion
        if (pct > 0)
        {
            fillW := Floor(w * Min(pct, 100) / 100)
            if (fillW > 0)
            {
                fillBrush := this._GetBrush(fillColor)
                NumPut("Int", x, rect, 0)
                NumPut("Int", y, rect, 4)
                NumPut("Int", x + fillW, rect, 8)
                NumPut("Int", y + h, rect, 12)
                DllCall("FillRect", "Ptr", this.memDC, "Ptr", rect, "Ptr", fillBrush)
            }
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

    ; ── GDI helpers ───────────────────────────────────────────────────────

    _DrawText(sx, sy, text, colorBGR)
    {
        DllCall("SetTextColor", "Ptr", this.memDC, "UInt", colorBGR)
        DllCall("SetBkMode",    "Ptr", this.memDC, "Int", 1)
        DllCall("TextOutW", "Ptr", this.memDC,
                "Int", sx, "Int", sy, "Str", text, "Int", StrLen(text))
    }

    _GetPen(colorBGR, width := 1)
    {
        key := colorBGR | (width << 24)
        if !this._penCache.Has(key)
            this._penCache[key] := DllCall("CreatePen", "Int", 0, "Int", width, "UInt", colorBGR, "Ptr")
        return this._penCache[key]
    }

    _GetBrush(colorBGR)
    {
        if !this._brushCache.Has(colorBGR)
            this._brushCache[colorBGR] := DllCall("CreateSolidBrush", "UInt", colorBGR, "Ptr")
        return this._brushCache[colorBGR]
    }

    _CreateFonts()
    {
        this._font := DllCall("CreateFontW",
            "Int", -13,                         ; height (negative = char height)
            "Int", 0,                           ; width
            "Int", 0, "Int", 0,                 ; escapement, orientation
            "Int", 600,                         ; weight (semi-bold)
            "UInt", 0,                          ; italic
            "UInt", 0, "UInt", 0,               ; underline, strikeout
            "UInt", 1,                          ; charset (DEFAULT)
            "UInt", 0, "UInt", 0, "UInt", 5,    ; out precision, clip, quality (CLEARTYPE)
            "UInt", 0,                          ; pitch
            "Str", "Segoe UI",
            "Ptr")

        this._fontSmall := DllCall("CreateFontW",
            "Int", -11,
            "Int", 0,
            "Int", 0, "Int", 0,
            "Int", 400,                         ; normal weight
            "UInt", 0,
            "UInt", 0, "UInt", 0,
            "UInt", 1,
            "UInt", 0, "UInt", 0, "UInt", 5,
            "UInt", 0,
            "Str", "Segoe UI",
            "Ptr")
    }

    ; ── Buffer management ─────────────────────────────────────────────────

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

    _Blit(w, h)
    {
        scrDC := DllCall("GetDC", "Ptr", this.hwnd, "Ptr")
        DllCall("BitBlt", "Ptr", scrDC,
                "Int", 0, "Int", 0, "Int", w, "Int", h,
                "Ptr", this.memDC, "Int", 0, "Int", 0, "UInt", 0x00CC0020)
        DllCall("ReleaseDC", "Ptr", this.hwnd, "Ptr", scrDC)
    }

    _Cleanup()
    {
        for _, pen in this._penCache
            DllCall("DeleteObject", "Ptr", pen)
        for _, brush in this._brushCache
            DllCall("DeleteObject", "Ptr", brush)
        if this._font
            DllCall("DeleteObject", "Ptr", this._font)
        if this._fontSmall
            DllCall("DeleteObject", "Ptr", this._fontSmall)
        if this.bitmap
        {
            stockBmp := DllCall("GetStockObject", "Int", 0, "Ptr")
            DllCall("SelectObject", "Ptr", this.memDC, "Ptr", stockBmp)
            DllCall("DeleteObject", "Ptr", this.bitmap)
            DllCall("DeleteDC",     "Ptr", this.memDC)
        }
    }
}
