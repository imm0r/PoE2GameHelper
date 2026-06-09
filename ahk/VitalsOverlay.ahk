; VitalsOverlay.ahk
; Configurable player-vitals bar overlay (Life / Mana / Energy Shield). Replaces the
; old fixed PlayerHUD bar box: each bar is independently enabled, positioned (as a
; fraction of the game window, so it survives resolution changes), sized, coloured
; (foreground / background / outline) and labelled (current / max / percent / off).
; Extends GdiOverlayBase and is driven by OverlayManager through the standard
; ShouldShow/Layout/Draw contract. Config lives in the g_vitalsBars / g_vitalsEnabled
; globals and self-persists to poeformance_config.ini [Vitals].
;
; Drag-to-place (edit mode) is layered on top in a later step; the data model + the
; xPct/yPct positions are the foundation it writes to.
; Included by InGameStateMonitor.ahk (after GdiOverlayBase).

class VitalsOverlay extends GdiOverlayBase
{
    static FONT_HEIGHT := -13
    static FONT_WEIGHT := 600

    __New()
    {
        super.__New(255)
        this.Name := "vitals"
    }

    ; ── Overlay contract ────────────────────────────────────────────────────
    ; Shares the play-overlay gate with the radar, plus a master enable toggle.
    ; Edit mode forces it visible so bars can be placed even with the game blurred.
    ShouldShow(ctx)
    {
        global g_playerHudEnabled, g_vitalsEditMode, g_vitalsVisibility
        if (IsSet(g_vitalsEditMode) && g_vitalsEditMode)
            return (ctx.gwW > 100 && ctx.gwH > 100)
        if !(IsSet(g_playerHudEnabled) ? g_playerHudEnabled : true)
            return false
        ; Visibility mode: "map" = only with the large map open (shares the radar
        ; gate); "ingame" (default) = visible during combat (no map requirement).
        mode    := IsSet(g_vitalsVisibility) ? g_vitalsVisibility : "ingame"
        gateKey := (mode = "map") ? "allowed" : "allowedNoMap"
        return ctx.gate.Has(gateKey) ? ctx.gate[gateKey] : ctx.gate["allowed"]
    }

    ; Vitals draw across the whole game window so bars can sit anywhere.
    Layout(ctx)
    {
        if (ctx.gwW < 100 || ctx.gwH < 100)
            return 0
        return Map("x", ctx.gwX, "y", ctx.gwY, "w", ctx.gwW, "h", ctx.gwH)
    }

    ; Draws every enabled bar at its configured fraction-of-window position.
    Draw(ctx, rect)
    {
        global g_vitalsBars, g_vitalsEditMode
        if !(IsSet(g_vitalsBars) && IsObject(g_vitalsBars))
            return
        vit  := this._ExtractVitals(ctx.snapshot)
        gw   := rect["w"], gh := rect["h"]
        edit := (IsSet(g_vitalsEditMode) && g_vitalsEditMode)

        for id, bar in g_vitalsBars
        {
            if !(bar.Has("enabled") && bar["enabled"])
                continue
            if !vit.Has(id)
                continue
            v := vit[id]
            ; In edit mode show full bars with sample fill so empty pools stay grabbable.
            pct := edit ? 100 : v["pct"]
            this._DrawBar(bar, id, v["cur"], v["max"], pct, gw, gh, edit)
        }
    }

    ; ── Internal ──────────────────────────────────────────────────────────────

    ; Reads life / mana / ES current+max+percent from the snapshot into a Map.
    _ExtractVitals(snap)
    {
        out := Map("life", Map("cur",0,"max",0,"pct",0)
                 , "mana", Map("cur",0,"max",0,"pct",0)
                 , "es",   Map("cur",0,"max",0,"pct",0))
        pv := (snap && IsObject(snap) && snap.Has("playerVitals")) ? snap["playerVitals"] : 0
        if !(pv && IsObject(pv) && pv.Has("stats"))
            return out
        st := pv["stats"]
        for id, keys in Map("life", ["lifeCurrent","lifeMax"]
                          , "mana", ["manaCurrent","manaMax"]
                          , "es",   ["esCurrent","esMax"])
        {
            c := st.Has(keys[1]) ? st[keys[1]] : 0
            m := st.Has(keys[2]) ? st[keys[2]] : 0
            out[id] := Map("cur", c, "max", m, "pct", (m > 0 ? (c / m) * 100 : 0))
        }
        return out
    }

    ; Draws one configured bar (background, fill, outline, optional label, and an
    ; edit-mode handle frame) onto the back-buffer in window-local coordinates.
    _DrawBar(bar, id, cur, max, pct, gw, gh, edit)
    {
        w := bar.Has("w") ? bar["w"] : 200
        h := bar.Has("h") ? bar["h"] : 16
        x := Round((bar.Has("xPct") ? bar["xPct"] : 0.4) * gw)
        y := Round((bar.Has("yPct") ? bar["yPct"] : 0.05) * gh)

        bgCol  := GroupColorToBgr(bar.Has("bg")      ? bar["bg"]      : "#222222")
        fgCol  := GroupColorToBgr(bar.Has("fg")      ? bar["fg"]      : "#DD2222")
        olCol  := GroupColorToBgr(bar.Has("outline") ? bar["outline"] : "#555555")

        ; Background
        this._FillRect(x, y, w, h, bgCol)
        ; Fill (left-anchored proportional to pct)
        if (pct > 0)
        {
            fillW := Floor(w * Min(pct, 100) / 100)
            if (fillW > 0)
                this._FillRect(x, y, fillW, h, fgCol)
        }
        ; Outline
        this._DrawRectOutline(x, y, w, h, olCol, edit ? 2 : 1)

        ; Label (current / max / percent), unless all text flags are off
        label := this._FormatLabel(bar, cur, max, pct)
        if (label != "")
        {
            font := this._GetFont(VitalsOverlay.FONT_HEIGHT, VitalsOverlay.FONT_WEIGHT)
            old  := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", font, "Ptr")
            this._DrawText(x + 4, y + (h // 2) - 7, label, 0xFFFFFF)
            DllCall("SelectObject", "Ptr", this.memDC, "Ptr", old)
        }

        ; Edit-mode affordance: a small id tag above the bar.
        if edit
        {
            font := this._GetFont(VitalsOverlay.FONT_HEIGHT, VitalsOverlay.FONT_WEIGHT)
            old  := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", font, "Ptr")
            this._DrawText(x, y - 14, StrUpper(id), 0x66E0FF)
            DllCall("SelectObject", "Ptr", this.memDC, "Ptr", old)
        }
    }

    ; Builds the bar label from the per-bar text flags (tCur / tMax / tPct).
    ; Returns "" when no text flag is set.
    _FormatLabel(bar, cur, max, pct)
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
}

; ── Config (self-persist [Vitals]) ──────────────────────────────────────────

; Returns a fresh default bar config Map. Positions are fractions of the game window.
_VitalsDefaultBar(enabled, xPct, yPct, w, h, fg, bg, outline)
{
    return Map("enabled", enabled, "xPct", xPct, "yPct", yPct, "w", w, "h", h
             , "fg", fg, "bg", bg, "outline", outline
             , "tCur", true, "tMax", true, "tPct", true)
}

; Seeds the vitals globals with defaults (unconditionally, per the AHK v2 init
; gotcha), then overlays any persisted values from poeformance_config.ini [Vitals].
LoadVitalsConfig()
{
    global g_vitalsEditMode, g_vitalsBars, g_vitalsVisibility
    g_vitalsEditMode := false
    g_vitalsVisibility := "ingame"   ; "ingame" (combat) | "map" (only with large map open)
    ; Default layout: three stacked bars near the top-centre (mirrors the old HUD).
    g_vitalsBars := Map(
        "life", _VitalsDefaultBar(true, 0.430, 0.020, 220, 16, "#DD2222", "#221010", "#555555"),
        "mana", _VitalsDefaultBar(true, 0.430, 0.052, 220, 16, "#2277DD", "#101822", "#555555"),
        "es",   _VitalsDefaultBar(true, 0.430, 0.084, 220, 14, "#44CCCC", "#0E2222", "#555555"))

    f := _ConfigPath()
    if !FileExist(f)
        return
    vis := IniRead(f, "Vitals", "visibility", g_vitalsVisibility)
    g_vitalsVisibility := (vis = "map") ? "map" : "ingame"
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
        bar["tCur"]    := (IniRead(f, "Vitals", pre "tCur", bar["tCur"] ? "1" : "0") = "1")
        bar["tMax"]    := (IniRead(f, "Vitals", pre "tMax", bar["tMax"] ? "1" : "0") = "1")
        bar["tPct"]    := (IniRead(f, "Vitals", pre "tPct", bar["tPct"] ? "1" : "0") = "1")
    }
}

; Writes the current vitals config to poeformance_config.ini [Vitals].
SaveVitalsConfig()
{
    global g_vitalsBars, g_vitalsVisibility
    f := _ConfigPath()
    IniWrite(IsSet(g_vitalsVisibility) ? g_vitalsVisibility : "ingame", f, "Vitals", "visibility")
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
        IniWrite(bar["tCur"] ? "1" : "0", f, "Vitals", pre "tCur")
        IniWrite(bar["tMax"] ? "1" : "0", f, "Vitals", pre "tMax")
        IniWrite(bar["tPct"] ? "1" : "0", f, "Vitals", pre "tPct")
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
; Only known keys are copied, with clamping, so a bad value can't corrupt a bar.
_ApplyVitals(payload)
{
    global g_vitalsBars, g_vitalsVisibility
    if !(IsSet(g_vitalsBars) && IsObject(g_vitalsBars) && payload && IsObject(payload))
        return
    if payload.Has("visibility")
    {
        v := payload["visibility"] ""
        g_vitalsVisibility := (v = "map") ? "map" : "ingame"
    }
    for id, bar in g_vitalsBars
    {
        if !(payload.Has(id) && IsObject(payload[id]))
            continue
        p := payload[id]
        if p.Has("enabled")  bar["enabled"] := p["enabled"] ? true : false
        if p.Has("xPct")     bar["xPct"]    := Min(1.0, Max(0.0, Float(p["xPct"])))
        if p.Has("yPct")     bar["yPct"]    := Min(1.0, Max(0.0, Float(p["yPct"])))
        if p.Has("w")        bar["w"]       := Min(4000, Max(4, Integer(p["w"])))
        if p.Has("h")        bar["h"]       := Min(400,  Max(2, Integer(p["h"])))
        if p.Has("fg")       bar["fg"]      := _VitalsHex(p["fg"], bar["fg"])
        if p.Has("bg")       bar["bg"]      := _VitalsHex(p["bg"], bar["bg"])
        if p.Has("outline")  bar["outline"] := _VitalsHex(p["outline"], bar["outline"])
        if p.Has("tCur")     bar["tCur"]    := p["tCur"] ? true : false
        if p.Has("tMax")     bar["tMax"]    := p["tMax"] ? true : false
        if p.Has("tPct")     bar["tPct"]    := p["tPct"] ? true : false
    }
}

; Serialises the vitals config (bars + edit-mode flag) for the WebView header push.
BuildVitalsHeaderJson()
{
    global g_vitalsBars, g_vitalsEditMode, g_vitalsVisibility
    if !(IsSet(g_vitalsBars) && IsObject(g_vitalsBars))
        return "{}"
    return JsonFull_Stringify(Map("bars", g_vitalsBars
        , "edit", (IsSet(g_vitalsEditMode) && g_vitalsEditMode) ? true : false
        , "visibility", IsSet(g_vitalsVisibility) ? g_vitalsVisibility : "ingame"), false)
}

; Sets (or toggles, when val is "") the drag-to-place edit mode. The interactive
; mouse handling is wired in a later step; this owns the state + click-through.
ToggleVitalsEditMode(val := "")
{
    global g_vitalsEditMode
    if (val = "")
        g_vitalsEditMode := !g_vitalsEditMode
    else
        g_vitalsEditMode := (val = true || val = 1 || val = "1" || val = "true")
    ; The interactive click-through toggle + drag mouse handling are wired in the
    ; edit-mode step; for now this flips the flag so the overlay shows the bar
    ; handles/labels and SaveVitalsConfig persists positions edited via the UI.
}
