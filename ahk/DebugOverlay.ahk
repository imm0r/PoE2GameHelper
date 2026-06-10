; DebugOverlay.ahk
; Standalone debug/status overlay — the automation status block that used to
; be painted into the RadarOverlay, detached into its own GdiOverlayBase
; window so it is readable independently of the radar (solid background,
; monospace font) and can be toggled on its own.
;
; Position: docked to the OUTER RIGHT edge of the game window, vertically
; below the quest tracker. Toggle: the "Debug Overlay" pill in
; Config → Overlay (global g_overlayStatusTextEnabled, persisted as
; Radar.statusText — same setting that previously controlled the radar
; status block, so existing user configs carry over).
;
; Content: AutoPilot state + reason, combat/loot/explore sub-lines (with the
; hz/rg diagnostics), the current exploration target (world coordinates +
; straight-line distance, fed by ExplorationModule via g_exploreTarget*),
; AutoFlask state, and the running version.
; Included by InGameStateMonitor.ahk (after GdiOverlayBase).

class DebugOverlay extends GdiOverlayBase
{
    ; BGR palette (mirrors the codex WebView theme)
    static COLOR_BG     := 0x141414   ; solid panel background
    static COLOR_BORDER := 0x5AA8C8   ; muted gold border (#c8a85a)
    static COL_GOLD_HI  := 0x8AD6F0   ; #f0d68a — primary gold for labels
    static COL_GOLD     := 0x5AA8C8   ; #c8a85a — muted gold for value text
    static COL_IVORY    := 0xB8DCE8   ; #e8dcb8 — main text colour
    static COL_DIM      := 0x648A9C   ; #9c8a64 — dim text for "off" / sub-info
    static COL_BLOOD    := 0x4848C5   ; #c54848 — blood red for combat
    static COL_AMBER    := 0x43A0D4   ; #d4a043 — burnished bronze for active
    ; Layout
    static PAD_X        := 12
    static PAD_Y        := 10
    static LINE_PITCH   := 17
    static FONT_HEIGHT  := -13
    static FONT_FACE    := "Consolas"
    static EDGE_MARGIN  := 6          ; gap to the game window's right edge
    static TOP_FRACTION := 0.16       ; below the top-right quest tracker

    __New()
    {
        super.__New(235)
        this.Name := "debug"
    }

    ; ── Overlay contract ────────────────────────────────────────────────────
    ; Visible while the pill is on and the game (or the PoEformance UI, for
    ; tweaking while alt-tabbed into the tool) is focused. Not bound to the
    ; play-overlay gate — debug info is wanted in town/hideout too.
    ShouldShow(ctx)
    {
        global g_overlayStatusTextEnabled
        if !g_overlayStatusTextEnabled
            return false
        if !(ctx.gameActive || ctx.keepWhenBackground)
            return false
        return (ctx.gwW >= 400 && ctx.gwH >= 300)
    }

    ; Docked to the outer right edge; width follows the longest line.
    Layout(ctx)
    {
        lines := this._BuildLines()
        this._lines := lines
        font := this._GetFont(DebugOverlay.FONT_HEIGHT, 400, DebugOverlay.FONT_FACE)
        maxW := 120
        for _, ln in lines
        {
            m := this._MeasureText(font, ln[1])
            if (m["w"] > maxW)
                maxW := m["w"]
        }
        boxW := maxW + DebugOverlay.PAD_X * 2
        boxH := lines.Length * DebugOverlay.LINE_PITCH + DebugOverlay.PAD_Y * 2
        return Map("x", ctx.gwX + ctx.gwW - boxW - DebugOverlay.EDGE_MARGIN
                 , "y", ctx.gwY + Round(ctx.gwH * DebugOverlay.TOP_FRACTION)
                 , "w", boxW, "h", boxH)
    }

    ; Solid panel + border + the status lines collected in Layout().
    Draw(ctx, rect)
    {
        w := rect["w"], h := rect["h"]
        this._FillRect(0, 0, w, h, DebugOverlay.COLOR_BG)
        this._DrawRectOutline(0, 0, w, h, DebugOverlay.COLOR_BORDER, 1)

        font := this._GetFont(DebugOverlay.FONT_HEIGHT, 400, DebugOverlay.FONT_FACE)
        oldFont := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", font, "Ptr")
        y := DebugOverlay.PAD_Y
        for _, ln in this._lines
        {
            this._DrawText(DebugOverlay.PAD_X, y, ln[1], ln[2])
            y += DebugOverlay.LINE_PITCH
        }
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldFont)
    }

    ; ── Content ─────────────────────────────────────────────────────────────
    ; Builds the [text, colorBGR] line list. Same information the radar status
    ; block used to show, plus the current exploration target (coordinates and
    ; straight-line distance) and the running build version.
    _BuildLines()
    {
        global g_autoPilotEnabled, g_autoPilotState, g_autoPilotReason
        global g_combatState, g_combatLastReason
        global g_lootLastReason, g_lootCache
        global g_exploreCurrentPercent, g_exploreLastReason
        global g_exploreHeightDiag, g_exploreRegionDiag
        global g_exploreTargetWX, g_exploreTargetWY, g_exploreTargetDist
        global g_exploreTargetHD, g_explorePosWX, g_explorePosWY, g_explorePosH
        global g_exploreClickX, g_exploreClickY, g_exploreCurX, g_exploreCurY
        global g_explorePlayerSX, g_explorePlayerSY
        global g_autoFlaskEnabled, g_autoFlaskLastReason
        global POEFORMANCE_VERSION

        lines := []

        if !g_autoPilotEnabled
        {
            lines.Push(["AUTOPILOT  OFF", DebugOverlay.COL_DIM])
        }
        else
        {
            stUp := StrUpper(g_autoPilotState)
            stCol := (g_autoPilotState = "combat") ? DebugOverlay.COL_BLOOD
                  : (g_autoPilotState = "explore" || g_autoPilotState = "loot") ? DebugOverlay.COL_AMBER
                  : DebugOverlay.COL_GOLD_HI
            lines.Push(["AUTOPILOT  " stUp, stCol])
            if (g_autoPilotReason && g_autoPilotReason != "" && g_autoPilotReason != "idle")
                lines.Push(["  " g_autoPilotReason, DebugOverlay.COL_IVORY])

            if (g_combatState = "combat" && g_combatLastReason != "" && g_combatLastReason != "idle")
                lines.Push(["  combat: " g_combatLastReason, DebugOverlay.COL_IVORY])

            cacheCount := (IsSet(g_lootCache) && g_lootCache && Type(g_lootCache) = "Map") ? g_lootCache.Count : 0
            if (cacheCount > 0 || g_autoPilotState = "loot")
                lines.Push(["  loot: " g_lootLastReason " · " cacheCount " cached", DebugOverlay.COL_IVORY])

            if (g_autoPilotState = "explore" || g_exploreCurrentPercent > 0)
            {
                pctTxt := Format("{:.0f}%", g_exploreCurrentPercent)
                rsn := (g_exploreLastReason != "" && g_exploreLastReason != "idle")
                    ? (" · " g_exploreLastReason) : ""
                lines.Push(["  explore: " pctTxt rsn, DebugOverlay.COL_IVORY])

                hz := (IsSet(g_exploreHeightDiag) && g_exploreHeightDiag != "") ? ("hz:" g_exploreHeightDiag) : ""
                rg := (IsSet(g_exploreRegionDiag) && g_exploreRegionDiag != "") ? ("rg:" g_exploreRegionDiag) : ""
                if (hz != "" || rg != "")
                    lines.Push(["    " hz (hz != "" && rg != "" ? " · " : "") rg, DebugOverlay.COL_DIM])

                ; Player position (world + render Z) and the current target:
                ; world coordinates, straight-line distance, and the height
                ; delta vs the player (hΔ of several hundred units = the
                ; target sits on another storey → region/path leaked a seam).
                if (IsSet(g_explorePosWX))
                    lines.Push(["    pos: " g_explorePosWX "," g_explorePosWY "  h=" g_explorePosH
                        , DebugOverlay.COL_DIM])
                if (IsSet(g_exploreTargetDist) && g_exploreTargetDist >= 0)
                {
                    hd := (IsSet(g_exploreTargetHD) && g_exploreTargetHD != "")
                        ? ("  hΔ=" g_exploreTargetHD) : ""
                    lines.Push(["    target: " Round(g_exploreTargetWX) "," Round(g_exploreTargetWY)
                        . "  d=" Round(g_exploreTargetDist) hd, DebugOverlay.COL_GOLD])
                }
                else
                    lines.Push(["    target: -", DebugOverlay.COL_DIM])

                ; Click diagnostics — intended click point vs the cursor read
                ; back after SetCursorPos, plus the player's on-screen point.
                ; If cur != click the OS rejected the move (the cursor never
                ; reached the click target → the character walks to the wrong
                ; place); that line turns red. clkΔ is the pixel gap from the
                ; player to the click — a tiny value means we are clicking
                ; almost on top of the character (no real movement).
                if (IsSet(g_exploreClickX))
                {
                    miss := (Abs(g_exploreClickX - g_exploreCurX) > 2
                          || Abs(g_exploreClickY - g_exploreCurY) > 2)
                    lines.Push(["    click: " g_exploreClickX "," g_exploreClickY
                        . "  cur: " g_exploreCurX "," g_exploreCurY (miss ? "  !!" : "")
                        , miss ? DebugOverlay.COL_BLOOD : DebugOverlay.COL_DIM])
                    if (IsSet(g_explorePlayerSX))
                    {
                        clkD := Abs(g_exploreClickX - g_explorePlayerSX)
                              + Abs(g_exploreClickY - g_explorePlayerSY)
                        lines.Push(["    plr@ " g_explorePlayerSX "," g_explorePlayerSY
                            . "  clkD=" clkD, DebugOverlay.COL_DIM])
                    }
                }
            }
        }

        if (g_autoFlaskEnabled && g_autoFlaskLastReason != "" && g_autoFlaskLastReason != "idle")
            lines.Push(["FLASK  " g_autoFlaskLastReason, DebugOverlay.COL_GOLD])

        lines.Push(["v" POEFORMANCE_VERSION, DebugOverlay.COL_DIM])
        return lines
    }
}
