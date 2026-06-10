; ClickNav.ahk
; Shared world-to-screen projection + click-point selection for the
; AutoPilot modules (ExplorationModule, CombatAutomation).
;
; Why this exists: both modules used to carry their own projection code and
; the two drifted apart — combat lacked the behind-camera (w-sign) check and
; mirrored far waypoints to the opposite screen edge, walking the character
; AWAY from its target. Everything click-related now goes through one
; toolkit with three hard rules:
;   1. The PLAYER's own projection anchors the w-sign convention AND must
;      land near the screen centre (PoE keeps the camera on the player) —
;      otherwise the matrix is stale/garbage and NOTHING is clicked.
;   2. Candidates are projected with the player's Z (grid heights proved
;      unreliable) and rejected when their w sign differs from the anchor.
;   3. Off-screen candidates are clamped ALONG THE RAY from the player's
;      projection (direction-true), never per-axis.
;
; Stateless functions only — no module globals (AHK v2 init gotcha N/A).

; Client rectangle of the game window in absolute screen coordinates.
; Returns Map("x", "y", "w", "h") or 0.
NavClientRect(gameHwnd)
{
    clientRect := Buffer(16, 0)
    clientPt := Buffer(8, 0)
    if !DllCall("GetClientRect", "Ptr", gameHwnd, "Ptr", clientRect)
        return 0
    DllCall("ClientToScreen", "Ptr", gameHwnd, "Ptr", clientPt)
    w := NumGet(clientRect, 8, "Int")
    h := NumGet(clientRect, 12, "Int")
    if (w < 100 || h < 100)
        return 0
    return Map("x", NumGet(clientPt, 0, "Int"), "y", NumGet(clientPt, 4, "Int"), "w", w, "h", h)
}

; Projection w (4th homogeneous component) of a world position. The sign of
; the PLAYER's w defines what "in front of the camera" means under this
; engine's matrix convention. 0 when the matrix is unavailable.
NavProjW(wx, wy, wz, mat)
{
    if !(mat && Type(mat) = "Array" && mat.Length = 16)
        return 0
    w := 0.0
    loop 4
    {
        j := A_Index
        w += mat[(j - 1) * 4 + 4] * (j = 1 ? wx : j = 2 ? wy : j = 3 ? wz : 1.0)
    }
    return w
}

; World → screen, UNCLAMPED (may land outside the window — clamp with
; NavRayClamp). Rejects degenerate w and, when visSign is set, points whose
; w sign differs from the anchor (behind the camera — dividing by their w
; mirrors the position to the opposite screen side).
; Returns Map("x", "y") or 0.
NavProject(wx, wy, wz, mat, rect, visSign := 0)
{
    if !(mat && Type(mat) = "Array" && mat.Length = 16 && rect)
        return 0
    r1 := 0.0, r2 := 0.0, r4 := 0.0
    loop 4
    {
        j := A_Index
        v := (j = 1) ? wx : (j = 2) ? wy : (j = 3) ? wz : 1.0
        r1 += mat[(j - 1) * 4 + 1] * v
        r2 += mat[(j - 1) * 4 + 2] * v
        r4 += mat[(j - 1) * 4 + 4] * v
    }
    if (Abs(r4) < 0.0001)
        return 0
    if (visSign != 0 && r4 * visSign < 0)
        return 0
    return Map("x", Round(rect["x"] + (r1 / r4 + 1) * rect["w"] / 2)
             , "y", Round(rect["y"] + (1 - r2 / r4) * rect["h"] / 2))
}

; Per-tick camera anchor: the player's own projection. ok=false means the
; matrix can't be trusted this tick (missing, or the player projects far
; off-centre — stale matrix during zone load / camera transition) and no
; click should be issued at all.
; Returns Map("ok", "why", "sp", "visSign").
NavAnchor(playerWX, playerWY, playerWZ, mat, rect)
{
    sp := NavProject(playerWX, playerWY, playerWZ, mat, rect, 0)
    if !sp
        return Map("ok", false, "why", "no-proj", "sp", 0, "visSign", 0)
    w := NavProjW(playerWX, playerWY, playerWZ, mat)
    visSign := (w > 0) ? 1 : (w < 0 ? -1 : 0)
    cxm := rect["x"] + rect["w"] / 2
    cym := rect["y"] + rect["h"] / 2
    ok := Abs(sp["x"] - cxm) <= rect["w"] * 0.30 && Abs(sp["y"] - cym) <= rect["h"] * 0.30
    return Map("ok", ok, "why", ok ? "" : "off-center", "sp", sp, "visSign", visSign)
}

; Clamps sp into the margin-inset client rect ALONG the ray from pSp
; (the player's projection) — an off-screen point keeps its exact travel
; direction instead of being bent by per-axis clamping.
NavRayClamp(sp, pSp, rect, margin := 80)
{
    minX := rect["x"] + margin, maxX := rect["x"] + rect["w"] - margin
    minY := rect["y"] + margin, maxY := rect["y"] + rect["h"] - margin
    x := sp["x"], y := sp["y"]
    if (x >= minX && x <= maxX && y >= minY && y <= maxY)
        return sp
    if !pSp
        return Map("x", Max(minX, Min(x, maxX)), "y", Max(minY, Min(y, maxY)))
    dx := x - pSp["x"], dy := y - pSp["y"]
    t := 1.0
    if (dx > 0)
        t := Min(t, (maxX - pSp["x"]) / dx)
    else if (dx < 0)
        t := Min(t, (minX - pSp["x"]) / dx)
    if (dy > 0)
        t := Min(t, (maxY - pSp["y"]) / dy)
    else if (dy < 0)
        t := Min(t, (minY - pSp["y"]) / dy)
    if (t < 0)
        t := 0
    return Map("x", Round(pSp["x"] + dx * t), "y", Round(pSp["y"] + dy * t))
}

; Validates one click candidate against the avoid zones and the
; on-character veto. HUD-band hits get a rescue: the point is pulled toward
; the player's projection in quarter steps and the first clear spot wins
; (keeps the travel direction instead of dropping the candidate).
; Returns Map("ok", true, "sp", point) or Map("ok", false, "cause",
; "hud"|"map"|"ent"|"near").
NavValidateClick(sp, pSp, avoidRects, selfPx := 40)
{
    kind := AvoidZoneHitKind(sp["x"], sp["y"], avoidRects)
    if (kind = "hud" && pSp)
    {
        step := 1
        while (step <= 3)
        {
            t := step / 4.0
            nx := Round(sp["x"] + (pSp["x"] - sp["x"]) * t)
            ny := Round(sp["y"] + (pSp["y"] - sp["y"]) * t)
            if (AvoidZoneHitKind(nx, ny, avoidRects) = "")
            {
                sp := Map("x", nx, "y", ny)
                kind := ""
                break
            }
            step++
        }
    }
    if (kind != "")
        return Map("ok", false, "cause", kind)
    if (pSp && Abs(sp["x"] - pSp["x"]) < selfPx && Abs(sp["y"] - pSp["y"]) < selfPx)
        return Map("ok", false, "cause", "near")
    return Map("ok", true, "sp", sp)
}

; Interpolated point `cells` fine-grid cells along `path` (array of [gx, gy]
; starting at the player). Clamps to the path end. Returns [gx, gy] floats
; or 0 on a degenerate path.
NavPointAlongPath(path, cells)
{
    if !(path && path.Length >= 1)
        return 0
    if (path.Length = 1)
        return [path[1][1], path[1][2]]
    remain := cells + 0.0
    i := 1
    while (i < path.Length)
    {
        dx := path[i + 1][1] - path[i][1]
        dy := path[i + 1][2] - path[i][2]
        segLen := Sqrt(dx * dx + dy * dy)
        if (segLen >= remain && segLen > 0)
            return [path[i][1] + dx * remain / segLen, path[i][2] + dy * remain / segLen]
        remain -= segLen
        i++
    }
    return [path[path.Length][1], path[path.Length][2]]
}

; Picks the click point for following `path` (fresh fine-grid path starting
; at the player): tries a point ~aheadCells along the path, backing off in
; steps toward minCells until one projects in front of the camera, clears
; the avoid zones and isn't on the character. Projection uses the PLAYER's
; Z (grid heights are unreliable; targets are floor-gated anyway).
; Returns Map("ok", true, "sp", point, "wx", "wy", "ahead", cells) or
; Map("ok", false, "why", "arrived"|"blocked", "rej", counterMap).
NavPickClickPoint(path, anchor, mat, rect, playerWZ, avoidRects, aheadCells := 35, minCells := 8)
{
    static RATIO := 10.86957   ; TerrainPathfinder.WORLD_TO_GRID_RATIO
    rej := Map("proj", 0, "hud", 0, "map", 0, "ent", 0, "near", 0)
    if !(path && path.Length >= 2)
        return Map("ok", false, "why", "arrived", "rej", rej)
    totalLen := 0.0
    i := 1
    while (i < path.Length)
    {
        dx := path[i + 1][1] - path[i][1]
        dy := path[i + 1][2] - path[i][2]
        totalLen += Sqrt(dx * dx + dy * dy)
        i++
    }
    if (totalLen < minCells)
        return Map("ok", false, "why", "arrived", "rej", rej)
    pSp := anchor["sp"]
    visSign := anchor["visSign"]
    tryCells := Min(aheadCells, totalLen)
    while (tryCells >= minCells)
    {
        pt := NavPointAlongPath(path, tryCells)
        tryCells -= 7
        if !pt
            continue
        cwx := pt[1] * RATIO
        cwy := pt[2] * RATIO
        sp := NavProject(cwx, cwy, playerWZ, mat, rect, visSign)
        if !sp
        {
            rej["proj"] += 1
            continue
        }
        sp := NavRayClamp(sp, pSp, rect)
        v := NavValidateClick(sp, pSp, avoidRects)
        if !v["ok"]
        {
            rej[v["cause"]] += 1
            continue
        }
        return Map("ok", true, "sp", v["sp"], "wx", cwx, "wy", cwy, "ahead", tryCells + 7)
    }
    return Map("ok", false, "why", "blocked", "rej", rej)
}

; Moves the cursor and issues a left click (raw Win32 — SetCursorPos +
; mouse_event bypass UIPI when the game runs elevated). Reads the cursor
; back so the caller can surface OS-side clamping in the debug overlay.
; Returns Map("curX", "curY").
NavClickAt(x, y)
{
    DllCall("SetCursorPos", "int", x, "int", y)
    Sleep(30)
    curPt := Buffer(8, 0)
    DllCall("GetCursorPos", "Ptr", curPt)
    DllCall("mouse_event", "uint", 0x0002, "int", 0, "int", 0, "uint", 0, "uptr", 0) ; LEFTDOWN
    Sleep(30)
    DllCall("mouse_event", "uint", 0x0004, "int", 0, "int", 0, "uint", 0, "uptr", 0) ; LEFTUP
    return Map("curX", NumGet(curPt, 0, "Int"), "curY", NumGet(curPt, 4, "Int"))
}
