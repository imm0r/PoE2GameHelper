; VitalsOverlay.ahk
; Configurable player-vitals bar overlay (Life / Mana / Energy Shield). Replaces the
; old fixed PlayerHUD bar box. Each bar is independently enabled, positioned (as a
; fraction of the game window, so it survives resolution changes), sized, coloured
; (foreground / background / outline), labelled (current / max / percent / off) AND
; given its own opacity.
;
; Per-bar opacity needs per-bar transparency, which a single colour-key window can't
; do (it has one window-wide alpha). So each bar is its OWN small overlay window
; (VitalsBarWindow): the window covers exactly the bar, and the window's alpha = the
; bar's opacity. VitalsOverlay is a thin controller registered with OverlayManager
; that drives the three bar windows. Config lives in g_vitalsBars and self-persists to
; poeformance_config.ini [Vitals]. Included by InGameStateMonitor.ahk (after GdiOverlayBase).

; ── Controller: registered as the "vitals" overlay; owns the per-bar windows ──
class VitalsOverlay
{
    static BAR_IDS := ["life", "mana", "es"]

    __New()
    {
        this.Name    := "vitals"
        this.Enabled := true
        this._bars   := Map()
        for id in VitalsOverlay.BAR_IDS
            this._bars[id] := VitalsBarWindow(id)
    }

    ; Driven once per tick by OverlayManager: forward to each bar window's own
    ; GdiOverlayBase Update() template (ShouldShow/Layout/Draw + hide-debounce).
    Update(ctx)
    {
        for id, w in this._bars
        {
            try w.Update(ctx)
            catch as e
                LogError("VitalsBar:" id, e)
        }
    }

    ; Hides every bar window (pause / hard snapshot failure / master off).
    Hide()
    {
        for id, w in this._bars
            try w.Hide()
    }

    ; Immediately syncs every bar window's edit interactivity (called on toggle).
    _EnsureEditStyle()
    {
        for id, w in this._bars
            try w._EnsureEditStyle()
    }
}

; ── One small click-through window per bar; its window alpha = the bar opacity ──
class VitalsBarWindow extends GdiOverlayBase
{
    static FONT_HEIGHT := -13
    static FONT_WEIGHT := 600

    __New(barId)
    {
        super.__New(255)
        this.barId := barId
        this.Name  := "vitals-" barId
        ; Game-window rect captured each Draw, needed by the async drag handlers.
        this._gwX := 0, this._gwY := 0, this._gwW := 0, this._gwH := 0
        ; Edit / drag state
        this._editInteractive := false
        this._mouseBound      := false
        this._dragging        := false
        this._fnDragTick      := 0       ; bound poll callback (created lazily on first drag)
        this._downSX := 0, this._downSY := 0     ; cursor screen pos at mouse-down
        this._barDownX := 0, this._barDownY := 0  ; bar window screen pos at mouse-down
    }

    ; ── Overlay contract ────────────────────────────────────────────────────
    ShouldShow(ctx)
    {
        global g_playerHudEnabled, g_vitalsBars, g_vitalsEditMode
        if !(IsSet(g_vitalsBars) && IsObject(g_vitalsBars) && g_vitalsBars.Has(this.barId))
            return false
        bar := g_vitalsBars[this.barId]
        if !(bar.Has("enabled") && bar["enabled"])
            return false
        if !(IsSet(g_playerHudEnabled) ? g_playerHudEnabled : true)
            return false
        if (IsSet(g_vitalsEditMode) && g_vitalsEditMode)
            return (ctx.gwW > 100 && ctx.gwH > 100)
        ; Hard safety gate (in-game, alive, player present, no panel, foreground;
        ; town/map deliberately excluded), then the per-bar priority rule list.
        if !(ctx.gate.Has("vitalsBase") ? ctx.gate["vitalsBase"] : ctx.gate["allowedNoMap"])
            return false
        return _VitalsRulesShow(bar, ctx.snapshot)
    }

    ; The window is exactly the bar rectangle, positioned by the bar's fraction.
    Layout(ctx)
    {
        global g_vitalsBars
        if (ctx.gwW < 100 || ctx.gwH < 100)
            return 0
        bar := g_vitalsBars[this.barId]
        w := bar.Has("w") ? bar["w"] : 200
        h := bar.Has("h") ? bar["h"] : 16
        x := ctx.gwX + Round((bar.Has("xPct") ? bar["xPct"] : 0.4) * ctx.gwW)
        y := ctx.gwY + Round((bar.Has("yPct") ? bar["yPct"] : 0.05) * ctx.gwH)
        return Map("x", x, "y", y, "w", w, "h", h)
    }

    ; Draws the bar in window-local coordinates; the whole window IS the bar, so
    ; the window alpha (set from the bar's opacity) gives per-bar transparency.
    Draw(ctx, rect)
    {
        global g_vitalsBars, g_vitalsEditMode
        this._EnsureEditStyle()
        this._gwX := ctx.gwX, this._gwY := ctx.gwY, this._gwW := ctx.gwW, this._gwH := ctx.gwH
        if !(IsSet(g_vitalsBars) && g_vitalsBars.Has(this.barId))
            return
        bar := g_vitalsBars[this.barId]

        ; Per-bar opacity -> window alpha (0..100 -> 0..255).
        op := bar.Has("opacity") ? bar["opacity"] : 100
        ta := Round(Min(100, Max(0, op)) / 100 * 255)
        if (this._alpha != ta)
            this.SetAlpha(ta)

        edit := (IsSet(g_vitalsEditMode) && g_vitalsEditMode) ? true : false
        v    := _VitalsValue(ctx.snapshot, this.barId)
        pct  := edit ? 100 : v["pct"]
        w    := rect["w"], h := rect["h"]

        bgCol := GroupColorToBgr(bar.Has("bg")      ? bar["bg"]      : "#222222")
        fgCol := GroupColorToBgr(bar.Has("fg")      ? bar["fg"]      : "#DD2222")
        olCol := GroupColorToBgr(bar.Has("outline") ? bar["outline"] : "#555555")

        this._FillRect(0, 0, w, h, bgCol)
        if (pct > 0)
        {
            fillW := Floor(w * Min(pct, 100) / 100)
            if (fillW > 0)
                this._FillRect(0, 0, fillW, h, fgCol)
        }
        this._DrawRectOutline(0, 0, w, h, olCol, edit ? 2 : 1)

        label := _VitalsFormatLabel(bar, v["cur"], v["max"], pct)
        if (label != "")
        {
            font := this._GetFont(VitalsBarWindow.FONT_HEIGHT, VitalsBarWindow.FONT_WEIGHT)
            old  := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", font, "Ptr")
            this._DrawText(4, (h // 2) - 7, label, 0xFFFFFF)
            DllCall("SelectObject", "Ptr", this.memDC, "Ptr", old)
        }
        if edit
        {
            font := this._GetFont(VitalsBarWindow.FONT_HEIGHT, VitalsBarWindow.FONT_WEIGHT)
            old  := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", font, "Ptr")
            this._DrawText(2, 0, StrUpper(this.barId), 0x66E0FF)
            DllCall("SelectObject", "Ptr", this.memDC, "Ptr", old)
        }
    }

    ; ── Edit mode (drag the bar window) ───────────────────────────────────────
    _EnsureEditStyle()
    {
        global g_vitalsEditMode
        want := (IsSet(g_vitalsEditMode) && g_vitalsEditMode) ? true : false
        if (want = this._editInteractive)
            return
        if !this._styled
            return
        if want
        {
            WinSetExStyle("-0x20", this.hwnd)   ; remove WS_EX_TRANSPARENT -> clickable
            this._RegisterMouse()
        }
        else
        {
            WinSetExStyle("+0x20", this.hwnd)   ; restore click-through
            this._UnregisterMouse()
        }
        this._editInteractive := want
    }

    ; Only WM_LBUTTONDOWN is hooked — the drag itself is driven by a poll timer
    ; (below) so it never depends on the tiny bar window staying under the cursor.
    _RegisterMouse()
    {
        if this._mouseBound
            return
        this._fnDown := ObjBindMethod(this, "_OnLDown")
        OnMessage(0x201, this._fnDown)   ; WM_LBUTTONDOWN
        this._mouseBound := true
    }

    _UnregisterMouse()
    {
        if !this._mouseBound
            return
        OnMessage(0x201, this._fnDown, 0)
        this._mouseBound := false
        this._EndDrag()
    }

    _CursorScreen(&cx, &cy)
    {
        pt := Buffer(8, 0)
        DllCall("GetCursorPos", "Ptr", pt)
        cx := NumGet(pt, 0, "Int")
        cy := NumGet(pt, 4, "Int")
    }

    ; Mouse-down on the bar starts the drag: capture the mouse and start a 10 ms
    ; poll that follows the cursor while the left button is physically held. The
    ; poll (not per-message moves) is what makes dragging a 0.5 cm-tall bar reliable.
    _OnLDown(wParam, lParam, msg, hwnd)
    {
        if (hwnd != this.hwnd)
            return
        cx := 0, cy := 0
        this._CursorScreen(&cx, &cy)
        this._downSX := cx, this._downSY := cy
        this._barDownX := this._lastX, this._barDownY := this._lastY
        this._dragging := true
        DllCall("SetCapture", "Ptr", this.hwnd)
        if !this._fnDragTick
            this._fnDragTick := ObjBindMethod(this, "_DragTick")
        SetTimer(this._fnDragTick, 10)
    }

    ; Poll: reposition the bar to follow the cursor; stop when the button is released.
    _DragTick()
    {
        global g_vitalsBars
        if (!this._dragging)
        {
            SetTimer(this._fnDragTick, 0)
            return
        }
        if !GetKeyState("LButton", "P")   ; button released anywhere -> finish
        {
            this._EndDrag()
            SaveVitalsConfig()
            SetTimer(PushHeaderToWebView, -30)
            return
        }
        cx := 0, cy := 0
        this._CursorScreen(&cx, &cy)
        bar := g_vitalsBars[this.barId]
        w := bar.Has("w") ? bar["w"] : 200
        h := bar.Has("h") ? bar["h"] : 16
        gwX := this._gwX, gwY := this._gwY, gwW := this._gwW, gwH := this._gwH
        if (gwW < 1 || gwH < 1)
            return
        nsx := this._barDownX + (cx - this._downSX)
        nsy := this._barDownY + (cy - this._downSY)
        nsx := Min(gwX + gwW - w, Max(gwX, nsx))   ; clamp inside the game window
        nsy := Min(gwY + gwH - h, Max(gwY, nsy))
        bar["xPct"] := (nsx - gwX) / gwW
        bar["yPct"] := (nsy - gwY) / gwH
        WinMove(nsx, nsy, , , this.hwnd)        ; the window IS the bar, so move = draw
        this._lastX := nsx, this._lastY := nsy  ; keep base move-tracking in sync
    }

    ; Ends the drag: stop the poll, release capture, clear the flag.
    _EndDrag()
    {
        if this._fnDragTick
            SetTimer(this._fnDragTick, 0)
        if this._dragging
            DllCall("ReleaseCapture")
        this._dragging := false
    }
}

; ── Shared helpers ──────────────────────────────────────────────────────────

; Returns Map("cur","max","pct") for one bar id from the snapshot.
_VitalsValue(snap, barId)
{
    keys := Map("life", ["lifeCurrent", "lifeMax"]
              , "mana", ["manaCurrent", "manaMax"]
              , "es",   ["esCurrent",   "esMax"])
    out := Map("cur", 0, "max", 0, "pct", 0)
    if !keys.Has(barId)
        return out
    pv := (snap && IsObject(snap) && snap.Has("playerVitals")) ? snap["playerVitals"] : 0
    if !(pv && IsObject(pv) && pv.Has("stats"))
        return out
    st := pv["stats"]
    k  := keys[barId]
    c  := st.Has(k[1]) ? st[k[1]] : 0
    m  := st.Has(k[2]) ? st[k[2]] : 0
    return Map("cur", c, "max", m, "pct", (m > 0 ? (c / m) * 100 : 0))
}

; Builds the bar label from the per-bar text flags. Returns "" when all are off.
_VitalsFormatLabel(bar, cur, max, pct)
{
    tCur := bar.Has("tCur") && bar["tCur"]
    tMax := bar.Has("tMax") && bar["tMax"]
    tPct := bar.Has("tPct") && bar["tPct"]
    s := ""
    if (tCur && tMax)
        s := cur "/" max
    else if tCur
        s := cur ""
    else if tMax
        s := max ""
    if tPct
        s := (s != "") ? (s " (" Round(pct) "%)") : (Round(pct) "%")
    return s
}

; ── Visibility rules (per-bar priority list) ────────────────────────────────

; Evaluates a bar's rule list against the snapshot. Walks the rules in priority
; order; the first enabled rule whose condition is currently true decides
; show/hide. If none match, the bar's "otherwise" default applies.
_VitalsRulesShow(bar, snap)
{
    low := bar.Has("lowLifePct") ? bar["lowLifePct"] : 50
    rules := bar.Has("rules") ? bar["rules"] : 0
    if (rules && Type(rules) = "Array")
    {
        for r in rules
        {
            if !(IsObject(r) && r.Has("enabled") && r["enabled"])
                continue
            if _VitalsCondMatch(r.Has("state") ? r["state"] : "", snap, low)
                return (r.Has("action") ? r["action"] : "show") = "show"
        }
    }
    return (bar.Has("otherwise") ? bar["otherwise"] : "show") = "show"
}

; Returns true when the named visibility state currently applies.
_VitalsCondMatch(state, snap, lowLifePct)
{
    if (state = "town")
    {
        wad := (snap && IsObject(snap) && snap.Has("worldAreaDat")) ? snap["worldAreaDat"] : 0
        return (wad && IsObject(wad)
            && ((wad.Has("isTown") && wad["isTown"]) || (wad.Has("isHideout") && wad["isHideout"]))) ? true : false
    }
    if (state = "map")
    {
        inGs := (snap && IsObject(snap) && snap.Has("inGameState")) ? snap["inGameState"] : 0
        ui   := (inGs && IsObject(inGs) && inGs.Has("importantUiElements")) ? inGs["importantUiElements"] : 0
        lm   := (ui && IsObject(ui) && ui.Has("largeMapData")) ? ui["largeMapData"] : 0
        return (lm && IsObject(lm) && lm.Has("isVisible") && lm["isVisible"]) ? true : false
    }
    if (state = "combat")
    {
        global g_combatState
        return (IsSet(g_combatState) && g_combatState = "combat") ? true : false
    }
    if (state = "lowlife")
    {
        v := _VitalsValue(snap, "life")
        return (v["max"] > 0 && v["pct"] < lowLifePct) ? true : false
    }
    return false
}

; Validates a UI rule payload (Array of {state,action,enabled}) into a clean Array.
_VitalsNormalizeRules(arr)
{
    out := []
    if !(arr && Type(arr) = "Array")
        return _VitalsDefaultRules()
    static valid := Map("combat", 1, "lowlife", 1, "town", 1, "map", 1)
    for r in arr
    {
        if !(IsObject(r) && r.Has("state") && valid.Has(r["state"] ""))
            continue
        out.Push(Map(
            "state",   r["state"] "",
            "action",  (r.Has("action") && r["action"] = "hide") ? "hide" : "show",
            "enabled", (r.Has("enabled") && r["enabled"]) ? true : false))
    }
    return out.Length ? out : _VitalsDefaultRules()
}

; Serialises a rule list to a compact INI string: "state|action|enabled,...".
_VitalsRulesToStr(rules)
{
    parts := []
    if (rules && Type(rules) = "Array")
        for r in rules
            parts.Push(r["state"] "|" r["action"] "|" (r["enabled"] ? "1" : "0"))
    out := ""
    for p in parts
        out .= (out = "" ? "" : ",") p
    return out
}

; Parses the compact INI string back into a rule list.
_VitalsRulesFromStr(s)
{
    out := []
    static valid := Map("combat", 1, "lowlife", 1, "town", 1, "map", 1)
    for tok in StrSplit(Trim(s), ",")
    {
        f := StrSplit(Trim(tok), "|")
        if (f.Length >= 3 && valid.Has(f[1]))
            out.Push(Map("state", f[1], "action", (f[2] = "hide") ? "hide" : "show", "enabled", (f[3] = "1")))
    }
    return out.Length ? out : _VitalsDefaultRules()
}

; ── Config (self-persist [Vitals]) ──────────────────────────────────────────

; Returns a fresh default bar config Map. Positions are fractions of the game window.
_VitalsDefaultBar(enabled, xPct, yPct, w, h, fg, bg, outline)
{
    return Map("enabled", enabled, "xPct", xPct, "yPct", yPct, "w", w, "h", h
             , "fg", fg, "bg", bg, "outline", outline, "opacity", 100
             , "tCur", true, "tMax", true, "tPct", true
             , "rules", _VitalsDefaultRules(), "otherwise", "show", "lowLifePct", 50)
}

; Default visibility rule list (priority order, all disabled -> behaves like
; "always visible in-game" until the user enables/reorders them).
_VitalsDefaultRules()
{
    return [
        Map("state", "combat",  "action", "show", "enabled", false),
        Map("state", "lowlife", "action", "show", "enabled", false),
        Map("state", "town",    "action", "show", "enabled", false),
        Map("state", "map",     "action", "show", "enabled", false)]
}

; Seeds the vitals globals with defaults (unconditionally, per the AHK v2 init
; gotcha), then overlays any persisted values from poeformance_config.ini [Vitals].
LoadVitalsConfig()
{
    global g_vitalsEditMode, g_vitalsBars
    g_vitalsEditMode := false
    ; Default layout: three stacked bars near the top-centre (mirrors the old HUD).
    g_vitalsBars := Map(
        "life", _VitalsDefaultBar(true, 0.430, 0.020, 220, 16, "#DD2222", "#221010", "#555555"),
        "mana", _VitalsDefaultBar(true, 0.430, 0.052, 220, 16, "#2277DD", "#101822", "#555555"),
        "es",   _VitalsDefaultBar(true, 0.430, 0.084, 220, 14, "#44CCCC", "#0E2222", "#555555"))

    f := _ConfigPath()
    if !FileExist(f)
        return
    for id, bar in g_vitalsBars
    {
        pre := id "_"
        bar["enabled"] := (IniRead(f, "Vitals", pre "enabled", bar["enabled"] ? "1" : "0") = "1")
        bar["xPct"]    := Float(IniRead(f, "Vitals", pre "xPct", bar["xPct"]))
        bar["yPct"]    := Float(IniRead(f, "Vitals", pre "yPct", bar["yPct"]))
        bar["w"]       := Integer(IniRead(f, "Vitals", pre "w", bar["w"]))
        bar["h"]       := Integer(IniRead(f, "Vitals", pre "h", bar["h"]))
        bar["fg"]      := IniRead(f, "Vitals", pre "fg", bar["fg"])
        bar["bg"]      := IniRead(f, "Vitals", pre "bg", bar["bg"])
        bar["outline"] := IniRead(f, "Vitals", pre "outline", bar["outline"])
        bar["opacity"] := Integer(IniRead(f, "Vitals", pre "opacity", bar["opacity"]))
        bar["tCur"]    := (IniRead(f, "Vitals", pre "tCur", bar["tCur"] ? "1" : "0") = "1")
        bar["tMax"]    := (IniRead(f, "Vitals", pre "tMax", bar["tMax"] ? "1" : "0") = "1")
        bar["tPct"]    := (IniRead(f, "Vitals", pre "tPct", bar["tPct"] ? "1" : "0") = "1")
        bar["otherwise"]  := (IniRead(f, "Vitals", pre "otherwise", bar["otherwise"]) = "hide") ? "hide" : "show"
        bar["lowLifePct"] := Min(100, Max(1, Integer(IniRead(f, "Vitals", pre "lowLifePct", bar["lowLifePct"]))))
        rulesStr := IniRead(f, "Vitals", pre "rules", "")
        if (rulesStr != "")
            bar["rules"] := _VitalsRulesFromStr(rulesStr)
    }
}

; Writes the current vitals config to poeformance_config.ini [Vitals].
SaveVitalsConfig()
{
    global g_vitalsBars
    f := _ConfigPath()
    for id, bar in g_vitalsBars
    {
        pre := id "_"
        IniWrite(bar["enabled"] ? "1" : "0", f, "Vitals", pre "enabled")
        IniWrite(bar["xPct"],    f, "Vitals", pre "xPct")
        IniWrite(bar["yPct"],    f, "Vitals", pre "yPct")
        IniWrite(bar["w"],       f, "Vitals", pre "w")
        IniWrite(bar["h"],       f, "Vitals", pre "h")
        IniWrite(bar["fg"],      f, "Vitals", pre "fg")
        IniWrite(bar["bg"],      f, "Vitals", pre "bg")
        IniWrite(bar["outline"], f, "Vitals", pre "outline")
        IniWrite(bar["opacity"], f, "Vitals", pre "opacity")
        IniWrite(bar["tCur"] ? "1" : "0", f, "Vitals", pre "tCur")
        IniWrite(bar["tMax"] ? "1" : "0", f, "Vitals", pre "tMax")
        IniWrite(bar["tPct"] ? "1" : "0", f, "Vitals", pre "tPct")
        IniWrite(bar.Has("otherwise") ? bar["otherwise"] : "show", f, "Vitals", pre "otherwise")
        IniWrite(bar.Has("lowLifePct") ? bar["lowLifePct"] : 50, f, "Vitals", pre "lowLifePct")
        IniWrite(_VitalsRulesToStr(bar.Has("rules") ? bar["rules"] : []), f, "Vitals", pre "rules")
    }
}

; ── Bridge helpers (JS <-> AHK) ─────────────────────────────────────────────

; Sanitises a "#RRGGBB" colour string; returns fallback when malformed.
_VitalsHex(v, fallback)
{
    s := Trim(v "")
    if (SubStr(s, 1, 1) != "#")
        s := "#" s
    if (StrLen(s) = 7 && RegExMatch(s, "i)^#[0-9a-f]{6}$"))
        return s
    return fallback
}

; Merges a UI payload (Map of barId -> settings Map) into g_vitalsBars in place.
; Only known keys are copied, with clamping/validation.
_ApplyVitals(payload)
{
    global g_vitalsBars
    if !(IsSet(g_vitalsBars) && IsObject(g_vitalsBars) && payload && IsObject(payload))
        return
    for id, bar in g_vitalsBars
    {
        if !(payload.Has(id) && IsObject(payload[id]))
            continue
        p := payload[id]
        if (p.Has("enabled"))
            bar["enabled"] := p["enabled"] ? true : false
        if (p.Has("xPct"))
            bar["xPct"] := Min(1.0, Max(0.0, Float(p["xPct"])))
        if (p.Has("yPct"))
            bar["yPct"] := Min(1.0, Max(0.0, Float(p["yPct"])))
        if (p.Has("w"))
            bar["w"] := Min(4000, Max(4, Integer(p["w"])))
        if (p.Has("h"))
            bar["h"] := Min(400, Max(2, Integer(p["h"])))
        if (p.Has("opacity"))
            bar["opacity"] := Min(100, Max(0, Integer(p["opacity"])))
        if (p.Has("fg"))
            bar["fg"] := _VitalsHex(p["fg"], bar["fg"])
        if (p.Has("bg"))
            bar["bg"] := _VitalsHex(p["bg"], bar["bg"])
        if (p.Has("outline"))
            bar["outline"] := _VitalsHex(p["outline"], bar["outline"])
        if (p.Has("tCur"))
            bar["tCur"] := p["tCur"] ? true : false
        if (p.Has("tMax"))
            bar["tMax"] := p["tMax"] ? true : false
        if (p.Has("tPct"))
            bar["tPct"] := p["tPct"] ? true : false
        if (p.Has("otherwise"))
            bar["otherwise"] := (p["otherwise"] = "hide") ? "hide" : "show"
        if (p.Has("lowLifePct"))
            bar["lowLifePct"] := Min(100, Max(1, Integer(p["lowLifePct"])))
        if (p.Has("rules") && Type(p["rules"]) = "Array")
            bar["rules"] := _VitalsNormalizeRules(p["rules"])
    }
}

; Serialises the vitals config (bars + edit-mode flag + visibility) for the header push.
BuildVitalsHeaderJson()
{
    global g_vitalsBars, g_vitalsEditMode
    if !(IsSet(g_vitalsBars) && IsObject(g_vitalsBars))
        return "{}"
    return JsonFull_Stringify(Map("bars", g_vitalsBars
        , "edit", (IsSet(g_vitalsEditMode) && g_vitalsEditMode) ? true : false), false)
}

; Sets (or toggles, when val is "") the drag-to-place edit mode.
ToggleVitalsEditMode(val := "")
{
    global g_vitalsEditMode, g_vitalsOverlay
    if (val = "")
        g_vitalsEditMode := !g_vitalsEditMode
    else
        g_vitalsEditMode := (val = true || val = 1 || val = "1" || val = "true")
    ; Sync each bar window's click-through state + mouse hooks immediately (they
    ; also self-sync each frame via _EnsureEditStyle). Persist when leaving edit.
    if (IsSet(g_vitalsOverlay) && IsObject(g_vitalsOverlay))
        try g_vitalsOverlay._EnsureEditStyle()
    if !g_vitalsEditMode
        SaveVitalsConfig()
}
