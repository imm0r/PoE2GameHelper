; AvoidZones.ahk
; Shared "do not click here" registry for AutoPilot automation.
;
; Two automation subsystems issue left-clicks at world positions:
;   - CombatAutomation aims the cursor at an enemy or a path waypoint
;   - ExplorationModule click-to-moves toward unexplored frontiers
;
; Both must avoid clicking on:
;   1. HUD elements (life globe, skill bar, flask bar, quest tracker, area banner)
;   2. The small corner minimap (NOT the large Tab map — that is click-through
;      for movement and its rect would cover the whole screen)
;   3. World entities whose left-click triggers something other than movement:
;        * AreaTransition  → enters another zone (interrupts everything)
;        * Waypoint        → opens travel UI (panel-open guard then kills automation)
;        * Portal          → returns to town
;        * NPC             → opens dialog
;        * Checkpoint      → activates checkpoint marker, may open UI
;
; Previously each subsystem either had its own (incomplete) UI-rect list or
; none at all — combat clicked on globes; exploration occasionally selected
; transitions. This helper unifies the avoid-zone logic so both rely on the
; same screen-coordinate rect list.
;
; The interactable-entity rects are deliberately oversized (~160 px box around
; the projected world position) — better to skip a tick and recompute than to
; misclick into a zone change.
;
; Included by InGameStateMonitor.ahk.

; ── Public API ────────────────────────────────────────────────────────────

; Returns an Array of [x, y, w, h] screen-coordinate rectangles. A click that
; falls inside ANY of these rects must be suppressed; the caller decides
; whether to fall back to a nearby safe position or skip the tick entirely.
;
; Params:
;   radarSnap - full radar snapshot (must have inGameState.areaInstance.awakeEntities
;               for interactable detection; without it only HUD rects are returned)
;   gameHwnd  - PoE2 window handle (required for client-area math)
GetAvoidZones(radarSnap, gameHwnd)
{
    rects := []
    if !gameHwnd
        return rects

    clientRect := Buffer(16, 0)
    clientPt   := Buffer(8, 0)
    DllCall("GetClientRect",  "Ptr", gameHwnd, "Ptr", clientRect)
    DllCall("ClientToScreen", "Ptr", gameHwnd, "Ptr", clientPt)
    cX := NumGet(clientPt, 0, "Int"),    cY := NumGet(clientPt, 4, "Int")
    cW := NumGet(clientRect, 8, "Int"),  cH := NumGet(clientRect, 12, "Int")
    if (cW < 100 || cH < 100)
        return rects

    _AppendHudRects(rects, cX, cY, cW, cH)
    _AppendMapRects(rects, radarSnap, cX, cY, cW, cH)
    _AppendInteractableRects(rects, radarSnap, gameHwnd, cX, cY, cW, cH)

    return rects
}

; Point-in-rect test against the full avoid-zone list. Linear scan — at most
; ~6 HUD rects + ~5 map rects + N entity rects (typically < 10). No spatial
; index needed.
IsPointInAvoidZone(sx, sy, rects)
{
    for _, r in rects
    {
        if (sx >= r[1] && sx < r[1] + r[3] && sy >= r[2] && sy < r[2] + r[4])
            return true
    }
    return false
}

; Returns the kind tag ("hud" | "map" | "ent") of the first avoid rect that
; contains (sx, sy), or "" when the point is clear. Same hit test as
; IsPointInAvoidZone but exposes WHICH category blocked — feeds the
; exploration "ui-blocked" cause breakdown in the debug overlay.
AvoidZoneHitKind(sx, sy, rects)
{
    for _, r in rects
    {
        if (sx >= r[1] && sx < r[1] + r[3] && sy >= r[2] && sy < r[2] + r[4])
            return (r.Length >= 5) ? r[5] : "?"
    }
    return ""
}

; ── HUD rects (fixed-anchor PoE2 UI) ─────────────────────────────────────
; PoE2 anchors these to fixed corners/edges and scales them linearly with
; resolution. Proportions are conservative (slightly oversized) — better to
; occasionally skip a safe click than to keep firing into a UI element that
; eats the click silently.
_AppendHudRects(rects, cX, cY, cW, cH)
{
    ; Bottom skill bar + center flask bar (middle 50% horizontal, bottom 14%)
    rects.Push([cX + cW * 0.25, cY + cH * 0.86, cW * 0.50, cH * 0.14, "hud"])
    ; Bottom-left life globe + left flask bar
    rects.Push([cX,             cY + cH * 0.78, cW * 0.13, cH * 0.22, "hud"])
    ; Bottom-right mana globe + right flask bar
    rects.Push([cX + cW * 0.87, cY + cH * 0.78, cW * 0.13, cH * 0.22, "hud"])
    ; Top-right quest tracker / area info
    rects.Push([cX + cW * 0.78, cY,             cW * 0.22, cH * 0.12, "hud"])
    ; Top-left area-name banner (the minimap sits just below)
    rects.Push([cX,             cY,             cW * 0.22, cH * 0.06, "hud"])
}

; ── Map overlay rects (minimap only) ────────────────────────────────────
; Exact rects derived from importantUiElements when visible — same UI-scale
; math the radar overlay uses (scaleIdx + localMult).
;
; ONLY the small corner minimap is treated as an avoid zone. The large map
; (Tab overlay) is deliberately EXCLUDED: it is click-through for movement
; in PoE2 (click-to-move works straight through it), and its rect covers
; most/all of the screen — including it blocked every movement click while
; the map was open, leaving the bot stuck on "ui-blocked" with no clicks at
; all (only stray behind-camera edge clicks outside the rect ever got
; through, which looked like "clicking the wrong place").
_AppendMapRects(rects, radarSnap, cX, cY, cW, cH)
{
    inGs    := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
    uiElems := (inGs && IsObject(inGs) && inGs.Has("importantUiElements")) ? inGs["importantUiElements"] : 0
    if !uiElems
        return

    sfX := cW / 2560.0, sfY := cH / 1600.0
    for _, mapKey in ["miniMapData"]
    {
        md := (uiElems && IsObject(uiElems) && uiElems.Has(mapKey)) ? uiElems[mapKey] : 0
        if !(md && IsObject(md) && md.Has("isVisible") && md["isVisible"])
            continue
        si := md.Has("scaleIdx")  ? md["scaleIdx"]  : 3
        lm := md.Has("localMult") ? md["localMult"] : 1.0
        if      si = 1
            uiSX := lm * sfX, uiSY := lm * sfX
        else if si = 2
            uiSX := lm * sfY, uiSY := lm * sfY
        else if si = 3
            uiSX := lm * sfX, uiSY := lm * sfY
        else
            uiSX := lm,       uiSY := lm
        rw := md["sizeW"] * uiSX
        rh := md["sizeH"] * uiSY
        rx := md["unscaledPosX"] * uiSX
        ry := md["unscaledPosY"] * uiSY
        ; MiniMap stores top-left already — no center adjustment needed.
        if (rw > 20 && rh > 20)
            rects.Push([cX + rx, cY + ry, rw, rh, "map"])
    }
}

; ── Interactable-entity rects ────────────────────────────────────────────
; Iterates the awake-entity sample, picks entities whose left-click would
; interrupt automation, projects each to screen via the W2S matrix, and adds
; an oversized bounding box (~160 px) around the projected point.
;
; The 160-px box is intentionally conservative: it has to cover the
; clickable hitbox of the entity (which can be substantial for a waypoint
; pillar or transition arch) plus account for projection inaccuracy at
; the edges of the camera frustum.
_AppendInteractableRects(rects, radarSnap, gameHwnd, cX, cY, cW, cH)
{
    AVOID_BOX_PX := 160   ; total width/height — 80 px radius

    inGs := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
    if !(inGs && IsObject(inGs))
        return
    w2sMat := inGs.Has("w2sMatrix") ? inGs["w2sMatrix"] : 0
    if !(w2sMat && Type(w2sMat) = "Array" && w2sMat.Length = 16)
        return   ; without a matrix we can't project — skip silently

    area   := inGs.Has("areaInstance") ? inGs["areaInstance"] : 0
    awake  := (area && IsObject(area) && area.Has("awakeEntities")) ? area["awakeEntities"] : 0
    sample := (awake && IsObject(awake) && awake.Has("sample")) ? awake["sample"] : []
    if !(sample && Type(sample) = "Array")
        return

    for _, entry in sample
    {
        if !(entry && IsObject(entry))
            continue
        entity := entry.Has("entity") ? entry["entity"] : 0
        if !(entity && IsObject(entity))
            continue

        path := entity.Has("path") ? entity["path"] : ""
        if (path = "")
            continue
        if !_IsInteractablePath(path)
            continue

        decoded := entity.Has("decodedComponents") ? entity["decodedComponents"] : 0
        if !(decoded && IsObject(decoded))
            continue
        render := decoded.Has("render") ? decoded["render"] : 0
        if !(render && IsObject(render) && render.Has("worldPosition"))
            continue
        wp := render["worldPosition"]
        wx := wp.Has("x") ? wp["x"] : 0
        wy := wp.Has("y") ? wp["y"] : 0
        wz := wp.Has("z") ? wp["z"] : 0
        if (wx = 0 && wy = 0)
            continue

        sp := _AvoidWorldToScreen(wx, wy, wz, w2sMat, cX, cY, cW, cH)
        if !sp
            continue

        half := AVOID_BOX_PX / 2
        rects.Push([sp["x"] - half, sp["y"] - half, AVOID_BOX_PX, AVOID_BOX_PX, "ent"])
    }
}

; Pattern match for entity paths whose left-click breaks automation.
; Case-insensitive substring match — same classification the entity tab uses.
_IsInteractablePath(path)
{
    p := StrLower(path)
    if InStr(p, "areatransition")
        return true
    if InStr(p, "waypoint")
        return true
    if InStr(p, "/portal")           ; town portal scrolls etc.
        return true
    if InStr(p, "checkpoint")
        return true
    if InStr(p, "metadata/npc/")     ; click → dialog
        return true
    return false
}

; Local W2S projection — duplicates the matrix multiply used elsewhere but
; uses the client-rect numbers the caller already computed. Returning 0 means
; the projection failed (perspective divide degenerate, etc.) and the caller
; should skip the entity. No clamping — the caller decides what to do with
; off-screen points; we want them excluded by being outside any rect anyway.
_AvoidWorldToScreen(wx, wy, wz, w2sMat, cX, cY, cW, cH)
{
    input := [wx, wy, wz, 1.0]
    r := [0.0, 0.0, 0.0, 0.0]
    Loop 4
    {
        i := A_Index
        Loop 4
        {
            j := A_Index
            r[i] := r[i] + w2sMat[(j - 1) * 4 + i] * input[j]
        }
    }
    if (Abs(r[4]) < 0.0001)
        return 0
    Loop 3
        r[A_Index] := r[A_Index] / r[4]

    sx := Round(cX + (r[1] + 1.0) * (cW / 2.0))
    sy := Round(cY + (1.0 - r[2]) * (cH / 2.0))
    return Map("x", sx, "y", sy)
}
