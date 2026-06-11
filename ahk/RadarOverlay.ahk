; RadarOverlay.ahk
; Transparent, click-through overlay — draws entity dots on the mini-map and the large map.
;
; ── Coordinate transformation (ported from Radar.cs / GameHelper2) ─────────────────────
;   Camera angle: 38.7°
;   Projection formula:
;     mapScale   = 240 / zoom  (large map: zoom *= LARGE_MAP_ZOOM_FACTOR = 0.1738)
;     projCos    = mapDiagonal * cos(38.7°) / mapScale
;     projSin    = mapDiagonal * sin(38.7°) / mapScale
;     gridDelta  = (worldPosition - playerWorldPosition) / WORLD_TO_GRID_RATIO
;     screenDelta.x = (gridDelta.x - gridDelta.y) * projCos
;     screenDelta.y = (gridDelta.z - gridDelta.x - gridDelta.y) * projSin
;     dotScreenPos  = mapCenter + screenDelta
;
; ── UI position calculation (ported from UiElement.cs / GameHelper2) ──────────────────
;   GetUnscaledPosition(): walk up the parent chain, accumulating relativePosition.
;   Final result: unscaledPos * GameWindowScale(scaleIndex, localMultiplier)
;     Game design reference resolution: 2560×1600
;     scaleFactorX = windowWidth  / 2560
;     scaleFactorY = windowHeight / 1600
;     scaleIndex 1 → uiScaleX = localMult * scaleFactorX, uiScaleY = localMult * scaleFactorX
;     scaleIndex 2 → uiScaleX = localMult * scaleFactorY, uiScaleY = localMult * scaleFactorY
;     scaleIndex 3 → uiScaleX = localMult * scaleFactorX, uiScaleY = localMult * scaleFactorY  (UI default)
;
; ── Map types ───────────────────────────────────────────────────────────────────────────
;   MiniMap:   stored position = TOP-LEFT     → center = pos + size/2 + defaultShift + shift
;   LargeMap:  stored position = MAP CENTER   → center = pos + defaultShift + shift
;              mapDiagonal = sqrt(windowWidth² + windowHeight²)  (rawsz=0 → window as equivalent)

class RadarOverlay extends GdiOverlayBase
{
    ; Transparency color: near black (0x000000 is ignored by some systems)
    static TRANSPARENT_BACKGROUND := 0x010101

    ; Camera-angle constants for 38.7°
    static CAMERA_COS := 0.78094   ; cos(38.7° in radians)
    static CAMERA_SIN := 0.62470   ; sin(38.7° in radians)

    ; Zoom correction factor for the large map (from RadarSettings.cs, default = 0.1738)
    static LARGE_MAP_ZOOM_FACTOR := 0.1738

    ; Conversion factor WorldPosition → GridPosition (from Radar.cs: ratio = 10.86957)
    static WORLD_TO_GRID_RATIO := 10.86957

    ; HUD clip masks (design px @ the 2560×1600 UI reference). The game draws its corner HUD
    ; (orbs, skill/flask bars, XP bar, area & quest panel) on top of its own map; our
    ; always-on-top overlay would otherwise paint the maphack outline / dots over it. The
    ; large-map layer is clipped to EXCLUDE every rectangle below, so the visible map area
    ; becomes a rectangle minus these corners. Dimensions scale UNIFORMLY by
    ; gameWindowHeight/1600 at render time (PoE2 HUD scales with height, so corner masks keep
    ; their size on ultrawide instead of stretching). Tune each entry in-game; empty the array
    ; to disable all masking.
    ;   "anchor": "bottom" = full-width strip along the bottom edge (its "w" is ignored)
    ;             "bl"/"br"/"tr"/"tl" = pinned to that corner, extending inward by w×h design px
    ; Multiple entries may share an anchor — their union is excluded, so each bottom corner
    ; is an L-shape: a tall narrow rect over the orb plus a lower wider rect over the flask /
    ; skill bar that extends further toward the screen centre.
    static MAP_HUD_MASKS := [
        Map("anchor", "bottom", "w",   0, "h",  30),   ; XP bar (spans the full window width)
        Map("anchor", "bl",     "w", 600, "h", 410),   ; life orb (tall corner)
        Map("anchor", "bl",     "w", 950, "h", 270),   ; flask / utility bar (lower, reaches inward)
        Map("anchor", "br",     "w", 600, "h", 410),   ; mana / spirit orb (tall corner)
        Map("anchor", "br",     "w", 950, "h", 270),   ; skill gem bar (lower, reaches inward)
        Map("anchor", "tr",     "w", 400, "h", 500)]   ; area info + quest tracker

    ; Dot colors (GDI expects BGR, not RGB)
    static COLOR_ENEMY_NORMAL := 0x0000FF   ; red    (normal enemies)
    static COLOR_ENEMY_RARE   := 0xFF00FF   ; magenta (rare enemies)
    static COLOR_ENEMY_BOSS   := 0x00FFFF   ; yellow (Unique/Boss)
    static COLOR_MINION       := 0x0080FF   ; orange (own minions)
    static COLOR_NPC          := 0x00FF80   ; green
    static COLOR_CHEST        := 0xFFFF00   ; cyan   (Chests/Strongboxes)
    static COLOR_PLAYER       := 0xFFFFFF   ; white

    ; Maximum world-unit radius drawn on the radar. Entities beyond this distance are skipped.
    ; 6000 world units ≈ 552 grid units — matches the outer scoring penalty in the entity sampler.
    static RADAR_MAX_WORLD_DIST_SQ := 36000000   ; 6000^2
    ; Extended range for important sleeping entities (Boss, Waypoint, AreaTransition, etc.)
    static RADAR_MAX_WORLD_DIST_SQ_EXTENDED := 400000000  ; 20000^2

    ; Colors for structural entity types
    static COLOR_WAYPOINT       := 0xFFD700   ; gold
    static COLOR_AREATRANSITION := 0x00BFFF   ; deep sky blue
    static COLOR_CHECKPOINT     := 0x7FFF00   ; chartreuse
    static COLOR_MAPHACK        := 0x909090   ; neutral gray (BGR) — matches game map outlines
    static COLOR_WALKABLE       := 0xFF8030   ; blue (BGR) — walkable-grid fill diagnostic overlay

    ; Creates the transparent, click-through overlay GUI window and initialises all GDI state fields.
    __New()
    {
        ; GdiOverlayBase owns the transparent click-through window, the double
        ; buffer, the pen/brush caches, the bg-clear brush and the Show/Hide/blit
        ; plumbing. RadarOverlay only adds its own state below.
        super.__New(255)
        this.Name := "radar"
        this.highlightedEntityPath := ""   ; path of entity selected in the Entities tab — drawn with a line on the radar
        this._lastMiniMapDiagonal := 0   ; cached minimap diagonal used for large-map projection
        ; Last valid player world position — reused for a short grace window when a
        ; snapshot briefly lacks worldPosition (GC / pointer race), so the whole
        ; overlay (map + dots + status text) doesn't blink out for that frame.
        this._lastPlayerPos       := 0    ; Map("x","y","h") or 0 when never seen
        this._lastPlayerPosTick   := 0    ; A_TickCount of the last valid position

        ; Entity-group filters (all visible by default)
        this.ShowEnemyNormal := true
        this.ShowEnemyRare   := true
        this.ShowEnemyBoss   := true
        this.ShowMinions     := true
        this.ShowNpcs        := true
        this.ShowChests      := true
        this.DebugMode       := true

        ; Terrain walkability data (set from snapshot each render frame).
        this._terrain             := 0
        ; Shared pathfinder instance (used for A* paths and line-of-sight).
        this._pathfinder          := TerrainPathfinder()
        ; Cached A* path: array of [gridX, gridY] absolute coordinates.
        this._pathGridCoords      := []
        ; Cache-invalidation keys for the path.
        this._pathHlEntity        := ""
        this._pathPlayerGX        := -999999
        this._pathPlayerGY        := -999999
        this._pathEntityGX        := -999999
        this._pathEntityGY        := -999999
        this._pathLastComputeTick := 0
        ; Highlighted entity world position — written by _RenderMapLayer, read by Render().
        this._hlEntityWorldX      := 0
        this._hlEntityWorldY      := 0
        ; Color for path/dot of the highlighted entity (determined from entity type each frame).
        this._hlEntityColor       := 0x00FFFF   ; default cyan

        ; Zone navigation: auto-paths to discovered AreaTransitions from deep scan
        this._navTargets          := []    ; Array of Maps from zone scan (path, type, worldX/Y, gridX/Y)
        this._navPathCoords       := []    ; A* path to nearest AreaTransition [gx, gy] pairs
        this._navTargetIdx        := -1    ; index in _navTargets of current path target
        this._navPlayerGX         := -999999
        this._navPlayerGY         := -999999

        ; Combat path overlay: written by CombatAutomation when LoS to the
        ; current target is blocked. Same shape as _navPathCoords — Array of
        ; [gx, gy] pairs from player to enemy. Rendered as a red polyline so
        ; the user sees the route the bot has chosen around obstacles. Empty
        ; when combat is idle OR when direct LoS is available.
        this._combatPathCoords    := []

        ; Exploration overlay: written by ExplorationModule each AutoPilot
        ; tick. _explorePathCoords is the A* route (Array of [gx, gy]) to the
        ; current scouting target; _exploreTargetGX/GY is that target cell
        ; (grid coords, -1 = none). Rendered as a cyan polyline + ring so the
        ; user can see exactly where the bot is heading and along which path.
        this._explorePathCoords   := []
        this._exploreTargetGX     := -1
        this._exploreTargetGY     := -1

        ; Combat target marker: written by CombatAutomation each tick while
        ; engaged ([gx, gy] grid coords of the current enemy, -1 = none).
        ; Rendered as a red ring + crosshair next to the red combat path.
        this._combatTargetGX      := -1
        this._combatTargetGY      := -1
        this._navLastComputeTick  := 0
        this._navAreaHash         := 0xFFFFFFFF
        this._navEnabled          := true  ; toggle from config

        ; Range circles: array of Maps with "range" (world units), "color" (BGR), "label" (text)
        ; Set externally via SetRangeCircles(); drawn as isometric ellipses around the player.
        this._rangeCircles        := []
        this._rangeCirclesEnabled := true   ; toggle from config — gates the entire range-circle render

        ; Map hack: pre-rendered walkable terrain border bitmap
        this._mapHackEnabled      := true  ; toggle from config
        this._mapHackDC           := 0     ; memory DC holding the solid-color source bitmap
        this._mapHackBmp          := 0     ; source bitmap handle (solid maphack color)
        this._mapHackMask         := 0     ; monochrome mask bitmap (1=border, 0=skip)
        this._mapHackW            := 0     ; bitmap width (gridW / STEP)
        this._mapHackH            := 0     ; bitmap height (totalRows / STEP)
        this._mapHackStep         := 4     ; grid sampling step
        this._mapHackGridW        := 0     ; grid width covered by bitmap
        this._mapHackGridH        := 0     ; grid height covered by bitmap
        this._mapHackTerrainSz    := 0     ; terrain data size — only updated on successful generate
        this._mapHackRetryTick    := 0     ; tick of last regenerate attempt (for retry throttle)

        ; Walkable-grid fill overlay (diagnostic): same pre-rendered bitmap
        ; pass as the border maphack, but the mask carries 1-bits for ALL
        ; walkable cells (50% stippled so the game map shows through) and is
        ; blitted in a distinct fill colour. Lets you compare our memory
        ; walkable grid against what the game actually shows.
        this._walkGridEnabled     := false ; toggle from config (off by default — diagnostic)
        this._mapHackMaskDebug    := false ; red outlines of the HUD clip masks (off — debug)
        this._mapWalkColorDC      := 0     ; memory DC holding the solid fill-colour source bitmap
        this._mapWalkColorBmp     := 0     ; source bitmap handle (solid walkable fill colour)
        this._mapWalkMask         := 0     ; monochrome mask bitmap (1=walkable cell, stippled)

        ; Debug lines — collected each Render() when DebugMode is on, pushed to WebView
        ; (Debug tab) instead of being drawn on the overlay so they're copyable.
        this._debugLines := Map()
        ; Cache for path-based entity classification flags to avoid repeated StrLower/InStr
        ; work in the per-frame render hot path.
        this._pathTypeCache := Map()

        ; ── Batch-draw queues ────────────────────────────────────────────────────────────
        ; Draw calls are collected and executed at the end of the frame in a single batch
        ; — reduces kernel-mode switches by 80–95 %.
        ;   Key encoding for _dotBatch / _dotTopBatch:  colorBGR | (radius << 24)
        ;   Key encoding for _lineBatch:                colorBGR | (width  << 24)
        this._dotBatch    := Map()   ; normal entity dots (all color groups)
        this._dotTopBatch := Map()   ; highlight dot — rendered after _dotBatch (on top)
        this._lineBatch   := Map()   ; line segments: one array per color/width group
        this._textBatch   := []      ; text entries: [x, y, text, colorBGR]
    }

    ; Pulls the radar's per-frame config straight from the toggle globals (the
    ; overlay owns reading its own settings, so the driver no longer pokes a dozen
    ; properties every tick). Also applies the highlighted-entity auto-expire.
    _SyncConfig(snapshot)
    {
        global g_radarShowEnemyNormal, g_radarShowEnemyRare, g_radarShowEnemyBoss
        global g_radarShowMinions, g_radarShowNpcs, g_radarShowChests
        global g_debugMode, g_zoneNavEnabled, g_mapHackEnabled, g_rangeCirclesEnabled
        global g_radarAlpha, g_highlightedEntityPath, g_walkGridEnabled, g_maphackMaskDebug

        this.ShowEnemyNormal := g_radarShowEnemyNormal
        this.ShowEnemyRare   := g_radarShowEnemyRare
        this.ShowEnemyBoss   := g_radarShowEnemyBoss
        this.ShowMinions     := g_radarShowMinions
        this.ShowNpcs        := g_radarShowNpcs
        this.ShowChests      := g_radarShowChests
        this.DebugMode       := g_debugMode
        this._navEnabled     := g_zoneNavEnabled
        this._mapHackEnabled := g_mapHackEnabled
        this._walkGridEnabled := IsSet(g_walkGridEnabled) ? g_walkGridEnabled : false
        this._mapHackMaskDebug := IsSet(g_maphackMaskDebug) ? g_maphackMaskDebug : false
        this._rangeCirclesEnabled := IsSet(g_rangeCirclesEnabled) ? g_rangeCirclesEnabled : true
        if (IsSet(g_radarAlpha) && this._alpha != g_radarAlpha)
            this.SetAlpha(g_radarAlpha)

        ; Auto-expire entity tracking once the target is finished (opened
        ; chest/strongbox or dead monster) so the tracking line/label stop
        ; pinning a completed objective.
        if (IsSet(g_highlightedEntityPath) && g_highlightedEntityPath != ""
            && _TrackedEntityExpired(snapshot, g_highlightedEntityPath))
            g_highlightedEntityPath := ""
        this.highlightedEntityPath := IsSet(g_highlightedEntityPath) ? g_highlightedEntityPath : ""
    }

    ; ── Overlay contract (driven by OverlayManager) ─────────────────────────
    ; Visibility: the radar follows the shared play-overlay gate, plus the user's
    ; radar on/off toggle (g_radarEnabled).
    ShouldShow(ctx)
    {
        global g_radarEnabled
        radarOn := (IsSet(g_radarEnabled) ? g_radarEnabled : true)
        if !radarOn
            return false
        if ctx.gate["allowed"]
            return true
        ; Also render on the play area (foreground only) when a debug-enabled hotkey
        ; wants a range circle, so the combat/aim radius shows even with the large map
        ; closed. The map layers stay gated on ctx.gate["allowed"] (see Draw), so this
        ; only adds the circle, never the maphack/dots.
        return (ctx.gameActive || ctx.keepWhenBackground) && this._HasHotkeyDebugCircle()
    }

    ; True if any debug-enabled hotkey action currently requests a screen-space range
    ; circle (monsterCount / aim). Keeps the radar alive for that circle even when the
    ; play-overlay gate (large map) is closed.
    _HasHotkeyDebugCircle()
    {
        global g_hkDebugItems
        if !(IsSet(g_hkDebugItems) && g_hkDebugItems is Array)
            return false
        for _, rec in g_hkDebugItems
        {
            if !(rec is Map)
                continue
            if ((rec.Has("circleCursorPx") && rec["circleCursorPx"] > 0)
                || (rec.Has("circlePlayerPx") && rec["circlePlayerPx"] > 0))
                return true
        }
        return false
    }

    ; Layout: the radar draws across the whole game window.
    Layout(ctx)
    {
        if (ctx.gwW < 100 || ctx.gwH < 100)
            return 0
        return Map("x", ctx.gwX, "y", ctx.gwY, "w", ctx.gwW, "h", ctx.gwH)
    }

    ; Draw entry point: pulls per-frame config from the globals, then draws all
    ; map layers. The window placement, buffer sizing and back-buffer clear are
    ; handled by GdiOverlayBase.Update() before this runs; the final blit happens
    ; after it returns. _FinishFrame() does the atlas + batch flush + UI highlight.
    ; gameWindowX/Y/Width/Height mirror the rect for the unchanged body below.
    Draw(ctx, rect)
    {
        global Profiler
        this._SyncConfig(ctx.snapshot)
        snapshot         := ctx.snapshot
        gameWindowX      := rect["x"]
        gameWindowY      := rect["y"]
        gameWindowWidth  := rect["w"]
        gameWindowHeight := rect["h"]

        ; Extract data from the snapshot
        inGameState    := (snapshot && snapshot.Has("inGameState"))           ? snapshot["inGameState"]                 : 0
        uiElements     := (inGameState && inGameState.Has("importantUiElements")) ? inGameState["importantUiElements"]  : 0
        areaInstance   := (inGameState && inGameState.Has("areaInstance"))    ? inGameState["areaInstance"]             : 0
        playerRender   := (areaInstance && areaInstance.Has("playerRenderComponent")) ? areaInstance["playerRenderComponent"] : 0
        miniMapData    := (uiElements && uiElements.Has("miniMapData"))       ? uiElements["miniMapData"]               : 0
        largeMapData   := (uiElements && uiElements.Has("largeMapData"))      ? uiElements["largeMapData"]              : 0

        ; Update terrain data from snapshot (re-read only when area hash changes in the reader).
        if (areaInstance && areaInstance.Has("terrain") && areaInstance["terrain"])
        {
            this._terrain := areaInstance["terrain"]
            this._pathfinder.SetTerrain(this._terrain)
        }
        terrainError := (areaInstance && areaInstance.Has("terrainError")) ? areaInstance["terrainError"] : ""

        ; Regenerate maphack bitmap when terrain data changes (new area loaded)
        ; or when the bitmap got destroyed (e.g. by an aborted previous generate).
        ;
        ; sizeChanged and "generate" are intentionally split across two ticks:
        ;   1. zone-change tick — destroy the stale bitmap, commit the new size,
        ;      and request immediate regen. Render() continues; _RenderMapHack
        ;      returns early because DC/Mask are gone, so this frame paints
        ;      WITHOUT any maphack outlines.
        ;   2. next tick — bitmap is missing, retry threshold cleared, generate
        ;      runs (1–2 s blocking call). On return the new bitmap is drawn.
        ;
        ; Without this split the destroy+generate ran in the same tick: the
        ; previous frame (with the OLD zone's outlines) stayed on screen for
        ; the full 1–2 s of generation. Now it's gone within one 50 ms tick.
        if (this._terrain)
        {
            curSz := this._terrain["dataSize"]
            sizeChanged := (curSz != this._mapHackTerrainSz)
            bitmapMissing := !this._mapHackDC || !this._mapHackMask
            retryReady := bitmapMissing && (A_TickCount - this._mapHackRetryTick) > 2000

            if (sizeChanged)
            {
                ; Tick 1: drop the old zone's bitmap immediately so it can't be
                ; blitted to the back buffer this frame. Commit the new size to
                ; suppress repeated sizeChanged triggers, and clear the retry
                ; tick so generation fires on the very next tick.
                if (this._mapHackDC || this._mapHackMask)
                    this._DestroyMapHackBitmap()
                this._mapHackTerrainSz := curSz
                this._mapHackRetryTick := 0
            }
            else if (retryReady)
            {
                ; Tick 2 (or any subsequent tick where bitmap is missing and
                ; throttle has elapsed): build the new bitmap. Blocks the tick
                ; for 1–2 s — acceptable because no maphack is on screen during
                ; that window thanks to the destroy from tick 1.
                this._mapHackRetryTick := A_TickCount
                Profiler.Begin("radar.maphackGen")
                this._GenerateMapHackBitmap()
                Profiler.End("radar.maphackGen")
                ; Re-commit size only on success — failed generates leave the
                ; retry primed for the next throttle window.
                if (this._mapHackDC && this._mapHackMask)
                    this._mapHackTerrainSz := curSz
            }
        }
        else
        {
            ; Terrain became unavailable between zones (loading screen, area
            ; ptr transitionally null). Drop the old bitmap immediately so the
            ; previous zone's outlines don't linger over the new map.
            if (this._mapHackDC || this._mapHackMask)
            {
                this._DestroyMapHackBitmap()
                this._mapHackTerrainSz := 0
                this._mapHackRetryTick := 0
            }
        }

        hasPlayerPosition   := (playerRender && playerRender.Has("worldPosition"))
        awakeEntityCount    := (areaInstance && areaInstance.Has("awakeEntities") && areaInstance["awakeEntities"].Has("sampleCount"))
                               ? areaInstance["awakeEntities"]["sampleCount"] : "?"

        ; ── Status (debug only) — collected for the WebView Debug tab, no overlay draw ──
        dbgX := 0   ; kept for backward-compatible math; no longer used for text
        this._debugLines := Map()   ; reset each frame
        if this.DebugMode
        {
            miniMapSize    := miniMapData  ? (Round(miniMapData["sizeW"])  "x" Round(miniMapData["sizeH"]))  : "no-mm"
            largeMapSize   := largeMapData ? (Round(largeMapData["sizeW"]) "x" Round(largeMapData["sizeH"])) : "no-lm"
            miniMapVisible := miniMapData  ? (miniMapData["isVisible"]  ? "V" : "H") : "-"
            largeMapVisible := largeMapData ? (largeMapData["isVisible"] ? "V" : "H") : "-"
            miniMapPos     := miniMapData  ? (Round(miniMapData["unscaledPosX"]) "," Round(miniMapData["unscaledPosY"])) : "-"
            terrDbg := this._terrain
                ? ("terr:" this._terrain["dataSize"] " gW=" this._terrain["gridWidth"] " gH=" this._terrain["totalRows"]
                   " bpr=" this._terrain["bytesPerRow"] (terrainError != "" ? " [" terrainError "]" : ""))
                : ("terr:NIL" (terrainError != "" ? " (" terrainError ")" : ""))
            mhDbg := " mh:" ((this._mapHackDC && this._mapHackMask) ? "OK" : "NIL")
                . "(sz=" this._mapHackTerrainSz " w=" this._mapHackW " h=" this._mapHackH ")"
            this._debugLines["status"] := "area:" (areaInstance?"OK":"NIL")
                . " pr:" (hasPlayerPosition?"OK":"NIL") " ent:" awakeEntityCount
                . " mm:" miniMapSize "[" miniMapVisible "]" " upos:" miniMapPos
                . " lm:" largeMapSize "[" largeMapVisible "]"
                . " " terrDbg . mhDbg
        }

        ; Reuse the last valid player position for a short grace window when this
        ; snapshot briefly lacks worldPosition (GC / pointer race). Without this the
        ; whole overlay — map, dots AND the status strings drawn below — blinks out
        ; for that single frame, which looks like the overlay is flickering.
        static _POS_GRACE_MS := 800
        if hasPlayerPosition
        {
            pwp := playerRender["worldPosition"]
            this._lastPlayerPos := Map("x", pwp["x"], "y", pwp["y"]
                , "h", playerRender.Has("terrainHeight") ? playerRender["terrainHeight"] : 0.0)
            this._lastPlayerPosTick := A_TickCount
        }
        else if (this._lastPlayerPos && (A_TickCount - this._lastPlayerPosTick) <= _POS_GRACE_MS)
        {
            ; Within grace — render this frame with the cached position.
            hasPlayerPosition := true
        }

        if !hasPlayerPosition
        {
            this._DrawDot(20, 8, 0x0000FF, 5)   ; blue dot = no player found
            this._FinishFrame(gameWindowWidth, gameWindowHeight)
            return
        }

        playerWorldPosition := (playerRender && playerRender.Has("worldPosition"))
                             ? playerRender["worldPosition"] : this._lastPlayerPos
        playerWorldX        := playerWorldPosition["x"]
        playerWorldY        := playerWorldPosition["y"]
        playerTerrainHeight := playerWorldPosition.Has("h") ? playerWorldPosition["h"]
                             : (playerRender.Has("terrainHeight") ? playerRender["terrainHeight"] : 0.0)

        ; Cache the minimap diagonal even when the minimap is currently invisible
        ; (the large map needs it, but is often open while the minimap is hidden).
        if miniMapData
        {
            sfX := gameWindowWidth  / 2560.0
            sfY := gameWindowHeight / 1600.0
            si  := miniMapData["scaleIdx"]
            lm  := miniMapData["localMult"]
            s   := (si = 1 || si = 3) ? lm * sfX : (si = 2) ? lm * sfY : lm
            mmW := miniMapData["sizeW"] * s
            mmH := miniMapData["sizeH"] * s
            if (mmW > 20 && mmH > 20)
                this._lastMiniMapDiagonal := Sqrt(mmW * mmW + mmH * mmH)
        }

        ; Map layers only render under the full play-overlay gate. When ShouldShow let
        ; the radar through purely for a hotkey-debug circle (gate closed, map shut),
        ; mapAllowed is false so we skip the maphack/dots and draw only the circle below.
        mapAllowed := (ctx.gate is Map && ctx.gate.Has("allowed")) ? ctx.gate["allowed"] : true

        if (mapAllowed && miniMapData && miniMapData["isVisible"])
        {
            Profiler.Begin("radar.mini")
            try this._RenderMapLayer(miniMapData, playerWorldX, playerWorldY, playerTerrainHeight,
                                     areaInstance, gameWindowWidth, gameWindowHeight, false)
            catch
                this._DrawDot(40, 8, 0x00FF00, 4)   ; green dot = MiniMap error
            Profiler.End("radar.mini")
        }

        if (mapAllowed && largeMapData && largeMapData["isVisible"])
        {
            Profiler.Begin("radar.large")
            try this._RenderMapLayer(largeMapData, playerWorldX, playerWorldY, playerTerrainHeight,
                                     areaInstance, gameWindowWidth, gameWindowHeight, true)
            catch
                this._DrawDot(56, 8, 0x00FFFF, 4)   ; cyan dot = large-map error
            Profiler.End("radar.large")
        }

        ; ── Path recompute (A*) when highlighted entity changes or player/entity moves ──
        if (this.highlightedEntityPath != "" && this._hlEntityWorldX != 0)
        {
            pGX := Round(playerWorldX / RadarOverlay.WORLD_TO_GRID_RATIO)
            pGY := Round(playerWorldY / RadarOverlay.WORLD_TO_GRID_RATIO)
            eGX := Round(this._hlEntityWorldX / RadarOverlay.WORLD_TO_GRID_RATIO)
            eGY := Round(this._hlEntityWorldY / RadarOverlay.WORLD_TO_GRID_RATIO)
            now := A_TickCount
            recompute := (this.highlightedEntityPath != this._pathHlEntity)
                      || (this._pathGridCoords.Length = 0 && (now - this._pathLastComputeTick) > 2000)
                      || ((now - this._pathLastComputeTick) > 500
                          && (Abs(pGX - this._pathPlayerGX) > 5
                           || Abs(pGY - this._pathPlayerGY) > 5
                           || Abs(eGX - this._pathEntityGX) > 5
                           || Abs(eGY - this._pathEntityGY) > 5))
            if recompute
            {
                this._pathGridCoords      := this._pathfinder.FindPath(pGX, pGY, eGX, eGY)
                this._pathPlayerGX        := pGX
                this._pathPlayerGY        := pGY
                this._pathEntityGX        := eGX
                this._pathEntityGY        := eGY
                this._pathHlEntity        := this.highlightedEntityPath
                this._pathLastComputeTick := A_TickCount
            }
            ; Always collect path status when entity is highlighted (shown in WebView debug tab)
            if this.DebugMode
            {
                this._debugLines["path"] := "path: pG=" pGX "," pGY " eG=" eGX "," eGY
                    . " pts=" this._pathGridCoords.Length
                    . " terrain=" (this._terrain ? "OK" : "NIL")
                    . " dbg=" this._pathfinder.LastDebug
            }
        }
        else if (this.highlightedEntityPath = "")
            this._pathGridCoords := []

        ; ── Zone navigation: auto-path to nearest AreaTransition (continuous accumulation) ──
        zoneScanResults := (areaInstance && areaInstance.Has("zoneScanResults")) ? areaInstance["zoneScanResults"] : []
        zoneScanDone    := (areaInstance && areaInstance.Has("zoneScanDone"))    ? areaInstance["zoneScanDone"]    : false
        zoneScanMs      := (areaInstance && areaInstance.Has("zoneScanTimingMs")) ? areaInstance["zoneScanTimingMs"] : 0
        if !(Type(zoneScanResults) = "Array")
            zoneScanResults := []

        if (this._navEnabled && zoneScanResults.Length > 0)
        {
            ; Detect new entities added since last tick → force path recompute
            prevTargetCount := this._navTargets.Length
            this._navTargets := zoneScanResults
            targetsChanged := (zoneScanResults.Length != prevTargetCount)

            pGX := Round(playerWorldX / RadarOverlay.WORLD_TO_GRID_RATIO)
            pGY := Round(playerWorldY / RadarOverlay.WORLD_TO_GRID_RATIO)
            now := A_TickCount

            ; Collect all AreaTransition targets with distances
            atCandidates := []
            for idx, target in this._navTargets
            {
                if (target["type"] != "AreaTransition")
                    continue
                dx := target["gridX"] - pGX
                dy := target["gridY"] - pGY
                d := dx * dx + dy * dy
                atCandidates.Push(Map("idx", idx, "dist", d))
            }

            ; Skip the nearest AreaTransition (entry point) and target the farthest remaining
            ; With ≤1 AT we still navigate to it (no alternative)
            bestIdx := -1
            if (atCandidates.Length = 1)
            {
                bestIdx := atCandidates[1]["idx"]
            }
            else if (atCandidates.Length >= 2)
            {
                ; Find farthest AT — usually the zone exit we're looking for
                bestDist := -1
                for _, c in atCandidates
                {
                    if (c["dist"] > bestDist) {
                        bestDist := c["dist"]
                        bestIdx := c["idx"]
                    }
                }
            }

            ; Recompute navigation path when player moves or new targets discovered
            if (bestIdx > 0)
            {
                recompute := targetsChanged
                          || (bestIdx != this._navTargetIdx)
                          || (this._navPathCoords.Length = 0 && (now - this._navLastComputeTick) > 3000)
                          || ((now - this._navLastComputeTick) > 1000
                              && (Abs(pGX - this._navPlayerGX) > 8
                               || Abs(pGY - this._navPlayerGY) > 8))
                if recompute
                {
                    t := this._navTargets[bestIdx]
                    tGX := Round(t["gridX"])
                    tGY := Round(t["gridY"])
                    this._navPathCoords      := this._pathfinder.FindPath(pGX, pGY, tGX, tGY)
                    this._navTargetIdx       := bestIdx
                    this._navPlayerGX        := pGX
                    this._navPlayerGY        := pGY
                    this._navLastComputeTick := A_TickCount
                }
            }
        }
        else if (!this._navEnabled)
        {
            this._navPathCoords := []
            this._navTargetIdx  := -1
        }

        ; Debug: collect zone scan status for the WebView debug tab
        if (this.DebugMode)
        {
            if (zoneScanResults.Length > 0 || zoneScanDone)
            {
                atCount := 0
                for _, t in zoneScanResults
                    if (t["type"] = "AreaTransition")
                        atCount += 1
                this._debugLines["nav"] := "nav: accum=" zoneScanResults.Length " AT=" atCount
                    . " path=" this._navPathCoords.Length " initMs=" zoneScanMs
            }
            else if (this._navEnabled)
            {
                this._debugLines["nav"] := "nav: scanning..."
            }
        }

        this._FinishFrame(gameWindowWidth, gameWindowHeight)

        ; Hotkey-debug range circles (monsterCount / aim) — drawn last so they sit on
        ; top, on the play area, regardless of map state (see ShouldShow's circle gate).
        this._RenderHotkeyCircles()
    }

    ; Finishes the frame on the back-buffer: atlas overlay, flush of all queued
    ; draw ops, then the optional UI-Browser highlight rect (topmost layer).
    ; GdiOverlayBase.Update() performs the actual blit right after Draw() returns,
    ; so this no longer blits itself — it is the single flush point per frame.
    _FinishFrame(gameWindowWidth, gameWindowHeight)
    {
        global Profiler
        ; Atlas overlay (dormant until g_atlasRender is populated by the reader).
        Profiler.Begin("radar.atlas")
        this._RenderAtlas()
        Profiler.End("radar.atlas")
        ; Flush all queued draw operations before the optional highlight rect.
        Profiler.Begin("radar.flush")
        this._FlushBatch()
        Profiler.End("radar.flush")

        global g_uiBrowserHighlight
        if IsObject(g_uiBrowserHighlight)
        {
            sf := gameWindowHeight / 1600.0
            hx := Round(g_uiBrowserHighlight["x"] * sf)
            hy := Round(g_uiBrowserHighlight["y"] * sf)
            hw := Round(g_uiBrowserHighlight["w"] * sf)
            hh := Round(g_uiBrowserHighlight["h"] * sf)
            if (hw > 4 && hh > 4 && hx < gameWindowWidth && hy < gameWindowHeight)
                this._DrawRect(hx, hy, hw, hh, 0x0000FF, 3)
        }
    }

    ; Renders entity dots onto one map layer using isometric projection and the game's UI scale math.
    ; Params: isLargeMap - switches between large-map center/window-diagonal vs. mini-map top-left formulas.
    ; Draws entities onto one map layer (mini-map or large map).
    _RenderMapLayer(mapData, playerWorldX, playerWorldY, playerTerrainHeight,
                    areaInstance, gameWindowWidth, gameWindowHeight, isLargeMap)
    {
        global Profiler
        ; ── Compute UI scaling (per GameWindowScale.cs) ──────────────────────────────────
        ; The game uses 2560×1600 as the design reference resolution for all UI positions.
        ; scaleFactorX/Y convert unscaled UI coordinates into real pixel coordinates.
        scaleFactorX    := gameWindowWidth  / 2560.0
        scaleFactorY    := gameWindowHeight / 1600.0
        scaleIndex      := mapData["scaleIdx"]
        localMultiplier := mapData["localMult"]

        if      scaleIndex = 1
            uiScaleX := localMultiplier * scaleFactorX, uiScaleY := localMultiplier * scaleFactorX
        else if scaleIndex = 2
            uiScaleX := localMultiplier * scaleFactorY, uiScaleY := localMultiplier * scaleFactorY
        else if scaleIndex = 3
            uiScaleX := localMultiplier * scaleFactorX, uiScaleY := localMultiplier * scaleFactorY
        else
            uiScaleX := localMultiplier,                uiScaleY := localMultiplier

        ; ── Map position on screen ───────────────────────────────────────────────────────
        ; MiniMap: unscaledPos = TOP-LEFT → mapCenter = pos + size/2 + shifts
        ; LargeMap: the position traversal already yields the map center (the large map
        ;           is positioned relative to the screen center in the UI tree → no +size/2)
        mapElementScreenX := mapData["unscaledPosX"] * uiScaleX
        mapElementScreenY := mapData["unscaledPosY"] * uiScaleY

        ; ── Map size and center on screen ────────────────────────────────────────────────
        mapScreenWidth  := mapData["sizeW"] * uiScaleX
        mapScreenHeight := mapData["sizeH"] * uiScaleY

        if isLargeMap
        {
            ; Large map: position traversal gives the center → only add the shifts.
            ; The stored element size is often 0 → use window size as a display fallback.
            mapCenterX := mapElementScreenX + mapData["defaultShiftX"] + mapData["shiftX"]
            mapCenterY := mapElementScreenY + mapData["defaultShiftY"] + mapData["shiftY"]
            if (!(mapScreenWidth > 20) || !(mapScreenHeight > 20)) {
                mapScreenWidth  := gameWindowWidth
                mapScreenHeight := gameWindowHeight
            }
        }
        else
        {
            if (!(mapScreenWidth > 20) || !(mapScreenHeight > 20))
                return
            ; MiniMap: position is top-left → center = pos + size/2 + shifts.
            mapCenterX := mapElementScreenX + mapScreenWidth  / 2 + mapData["defaultShiftX"] + mapData["shiftX"]
            mapCenterY := mapElementScreenY + mapScreenHeight / 2 + mapData["defaultShiftY"] + mapData["shiftY"]
        }

        if (mapCenterX < -mapScreenWidth  || mapCenterX > gameWindowWidth  + mapScreenWidth
         || mapCenterY < -mapScreenHeight || mapCenterY > gameWindowHeight + mapScreenHeight)
            return

        ; ── Diagonal for projection scaling ──────────────────────────────────────────────
        ; MiniMap: diagonal of the actual map element.
        ; LargeMap: UnscaledSize=0 in memory → use the minimap diagonal (cached in Render()).
        ;           Combined without LARGE_MAP_ZOOM_FACTOR, because that factor scales the
        ;           window diagonal down to the minimap diagonal — when using the minimap
        ;           diagonal directly it is no longer needed.
        if isLargeMap
            mapDiagonal := (this._lastMiniMapDiagonal > 0)
                ? this._lastMiniMapDiagonal
                : Sqrt(gameWindowWidth * gameWindowWidth + gameWindowHeight * gameWindowHeight)
        else
            mapDiagonal := Sqrt(mapScreenWidth * mapScreenWidth + mapScreenHeight * mapScreenHeight)

        ; ── Zoom value for radar projection ──────────────────────────────────────────────
        ; LARGE_MAP_ZOOM_FACTOR is ONLY needed when the window diagonal is used.
        ; With the minimap diagonal directly → use the raw zoom value (no factor).
        mapZoom := mapData["zoom"]
        if (!(mapZoom > 0) || mapZoom > 20)
            mapZoom := 0.5

        ; ── DEBUG: collect per-map info for the WebView debug tab ────────────────
        if this.DebugMode
        {
            mapKey := isLargeMap ? "mapL" : "mapM"
            this._debugLines[mapKey] := (isLargeMap?"L":"M")
                . " ctr=" Round(mapCenterX) "," Round(mapCenterY)
                . " spos=" Round(mapElementScreenX) "," Round(mapElementScreenY)
                . " rawsz=" Round(mapData["sizeW"]) "x" Round(mapData["sizeH"])
                . " sz=" Round(mapScreenWidth) "x" Round(mapScreenHeight)
                . " si=" mapData["scaleIdx"] " dep=" mapData["chainDepth"]
                . " z=" Round(mapZoom, 3)
        }

        ; ── Projection factors for the radar coordinate transformation ───────────────────
        baseMapScale := 240.0 / mapZoom
        projectionCos := mapDiagonal * RadarOverlay.CAMERA_COS / baseMapScale
        projectionSin := mapDiagonal * RadarOverlay.CAMERA_SIN / baseMapScale

        ; ── HUD clip masks (large map only) ──────────────────────────────────────────────
        ; Exclude each corner/edge HUD rectangle so the maphack outline / dots never paint
        ; over the game's orbs, skill/flask/XP bars or the area & quest panel (the game draws
        ; that HUD on top of its map; our overlay is always-on-top). GDI clips PlgBlt and every
        ; dot/line below to the remaining region for the rest of the method; the clip is cleared
        ; unconditionally at the end (cannot leak a frame). Result: a non-rectangular map area.
        if isLargeMap
        {
            for _, mask in RadarOverlay.MAP_HUD_MASKS
            {
                r := this._HudMaskRect(mask, gameWindowWidth, gameWindowHeight, scaleFactorY)
                if !r
                    continue
                DllCall("ExcludeClipRect", "Ptr", this.memDC,
                    "Int", r[1], "Int", r[2], "Int", r[1] + r[3], "Int", r[2] + r[4])
            }
        }

        ; ── Maphack / walkable-grid overlays (large map only, before entities) ──
        ; Walkable fill goes first so the wall-border outline draws on top.
        if (isLargeMap && this._walkGridEnabled && this._mapWalkColorDC && this._mapWalkMask)
        {
            Profiler.Begin("radar.mask.walk")
            this._BlitMaskLayer(this._mapWalkColorDC, this._mapWalkMask,
                mapCenterX, mapCenterY, playerWorldX, playerWorldY, projectionCos, projectionSin)
            Profiler.End("radar.mask.walk")
        }
        if (isLargeMap && this._mapHackEnabled && this._mapHackDC && this._mapHackMask)
        {
            Profiler.Begin("radar.mask.hack")
            this._BlitMaskLayer(this._mapHackDC, this._mapHackMask,
                mapCenterX, mapCenterY, playerWorldX, playerWorldY, projectionCos, projectionSin)
            Profiler.End("radar.mask.hack")
        }

        ; Player dot at the map center
        this._DrawDot(Round(mapCenterX), Round(mapCenterY), RadarOverlay.COLOR_PLAYER, isLargeMap ? 4 : 2)

        ; ── Range circles (config toggle + only when entries are set) ──
        if (this._rangeCirclesEnabled)
        {
            for _, rc in this._rangeCircles
            {
                if (rc.Has("range") && rc["range"] > 0)
                    this._DrawRangeCircle(rc["range"], mapCenterX, mapCenterY,
                        projectionCos, projectionSin,
                        rc.Has("color") ? rc["color"] : 0x00FFFF,
                        rc.Has("label") ? rc["label"] : "")
            }
        }

        ; (Hotkey-debug range circles are drawn once per frame from Draw() via
        ; _RenderHotkeyCircles — independent of the map layers, so they show even
        ; when the large map is closed.)

        ; ── Draw entities ────────────────────────────────────────────────────────────────
        awakeEntities   := (areaInstance && areaInstance.Has("awakeEntities"))    ? areaInstance["awakeEntities"]    : 0
        sleepingEntities := (areaInstance && areaInstance.Has("sleepingEntities")) ? areaInstance["sleepingEntities"] : 0

        statTotal     := 0
        statNoDecoded := 0
        statNoRender  := 0
        statFiltered  := 0
        statDead      := 0
        statDrawn     := 0
        firstEntityPath := ""

        ; Track selected entity screen position for post-loop line drawing
        hlScreenX := -1, hlScreenY := -1, hlDistM := -1, hlName := ""

        ; Collect filter stats from awake entities (filter signals 1-5 + blacklist)
        fs := (awakeEntities && awakeEntities.Has("filterStats")) ? awakeEntities["filterStats"] : 0

        for _, entitySource in [awakeEntities, sleepingEntities]
        {
            if !(entitySource && entitySource.Has("sample"))
                continue
            for _, sampleEntry in entitySource["sample"]
            {
                if !(sampleEntry && sampleEntry.Has("entity"))
                    continue
                entity := sampleEntry["entity"]
                statTotal += 1

                if (firstEntityPath = "" && entity.Has("path"))
                    firstEntityPath := SubStr(entity["path"], 1, 40)

                ; Skip stale/removed entities (flags bit-0 set = invalid in game engine)
                if (entity.Has("isValid") && !entity["isValid"]) {
                    statDead += 1
                    continue
                }

                decodedComponents := entity.Has("decodedComponents") ? entity["decodedComponents"] : 0
                if !decodedComponents {
                    statNoDecoded += 1
                    continue
                }

                renderComponent := decodedComponents.Has("render") ? decodedComponents["render"] : 0
                if !(renderComponent && renderComponent.Has("worldPosition")) {
                    statNoRender += 1
                    continue
                }

                ; Path filter: only show monsters, player characters, NPCs and chests.
                ; Resolve via cached classification to avoid repeated StrLower/InStr per frame.
                entityPath := entity.Has("path") ? entity["path"] : ""
                pathFlags := this._GetPathTypeFlags(entityPath)
                isMonster        := pathFlags["isMonster"]
                isCharacter      := pathFlags["isCharacter"]
                isNpcPath        := pathFlags["isNpcPath"]
                isChestPath      := pathFlags["isChestPath"]
                isAreaTransition := pathFlags["isAreaTransition"]
                isWaypoint       := pathFlags["isWaypoint"]
                isCheckpoint     := pathFlags["isCheckpoint"]
                isBossPath       := pathFlags["isBossPath"]
                isImportantSleep := pathFlags["isImportantSleep"]

                entityWorldPos      := renderComponent["worldPosition"]
                entityTerrainHeight := renderComponent.Has("terrainHeight") ? renderComponent["terrainHeight"] : 0.0

                ; Hard distance cutoff: 6000 world units for normal entities, 20000 for important types.
                wdx := entityWorldPos["x"] - playerWorldX
                wdy := entityWorldPos["y"] - playerWorldY
                distSq := wdx * wdx + wdy * wdy
                maxDistSq := isImportantSleep ? RadarOverlay.RADAR_MAX_WORLD_DIST_SQ_EXTENDED : RadarOverlay.RADAR_MAX_WORLD_DIST_SQ
                if (distSq > maxDistSq) {
                    statFiltered += 1
                    continue
                }

                ; Convert world delta → grid delta
                gridDeltaX := (entityWorldPos["x"] - playerWorldX)        / RadarOverlay.WORLD_TO_GRID_RATIO
                gridDeltaY := (entityWorldPos["y"] - playerWorldY)        / RadarOverlay.WORLD_TO_GRID_RATIO
                gridDeltaZ := (entityTerrainHeight - playerTerrainHeight) / RadarOverlay.WORLD_TO_GRID_RATIO

                ; Isometric radar projection (camera angle 38.7°)
                screenDeltaX := (gridDeltaX - gridDeltaY) * projectionCos
                screenDeltaY := (gridDeltaZ - gridDeltaX - gridDeltaY) * projectionSin

                dotScreenX := Round(mapCenterX + screenDeltaX)
                dotScreenY := Round(mapCenterY + screenDeltaY)

                ; Capture highlighted entity screen position early — bypass all visibility filters
                if (this.highlightedEntityPath != "" && entity.Has("path") && entity["path"] = this.highlightedEntityPath)
                {
                    hlScreenX := dotScreenX
                    hlScreenY := dotScreenY
                    hlDistM   := Round(Sqrt(wdx*wdx + wdy*wdy) / RadarOverlay.WORLD_TO_GRID_RATIO)
                    hlName    := entity.Has("displayName") ? entity["displayName"]
                                 : SubStr(entity["path"], InStr(entity["path"], "/",, -1)+1)
                    ; Store world position for pathfinding trigger in Render()
                    this._hlEntityWorldX := entityWorldPos["x"]
                    this._hlEntityWorldY := entityWorldPos["y"]
                    ; Determine entity type color now (before filter continues may skip color computation below)
                    _hlPos  := decodedComponents.Has("positioned") ? decodedComponents["positioned"] : 0
                    _hlFr   := _hlPos && _hlPos.Has("isFriendly") && _hlPos["isFriendly"]
                    _hlCh   := isChestPath
                    _hlMn   := isMonster && _hlFr
                    _hlNpc  := isNpcPath || isCharacter || (_hlFr && !isMonster)
                    _hlEn   := !_hlFr && !_hlCh
                    _hlRar  := decodedComponents.Has("rarityId") ? decodedComponents["rarityId"] : 0
                    this._hlEntityColor := isAreaTransition ? RadarOverlay.COLOR_AREATRANSITION
                        : isWaypoint  ? RadarOverlay.COLOR_WAYPOINT
                        : isCheckpoint ? RadarOverlay.COLOR_CHECKPOINT
                        : _hlCh ? RadarOverlay.COLOR_CHEST
                        : _hlMn   ? RadarOverlay.COLOR_MINION
                        : _hlNpc  ? RadarOverlay.COLOR_NPC
                        : (_hlEn && _hlRar = 3) ? RadarOverlay.COLOR_ENEMY_BOSS
                        : (_hlEn && _hlRar = 2) ? RadarOverlay.COLOR_ENEMY_RARE
                        :                         RadarOverlay.COLOR_ENEMY_NORMAL
                }

                if !(isMonster || isCharacter || isNpcPath || isChestPath || isAreaTransition || isWaypoint || isCheckpoint) {
                    statFiltered += 1
                    continue
                }

                ; Skip only if the life component was successfully decoded AND explicitly reports dead.
                ; If life component is absent (failed plausibility) we allow through — radar decode
                ; now scans all components, so a missing life key means the address was unreadable.
                lifeComponent := decodedComponents.Has("life") ? decodedComponents["life"] : 0
                if (lifeComponent && Type(lifeComponent) = "Map"
                    && lifeComponent.Has("isAlive") && !lifeComponent["isAlive"]) {
                    statDead += 1
                    continue
                }

                ; Skip already-opened chests — they stay valid in the AwakeMap but are no longer
                ; relevant and cause persistent "ghost" dots on the radar.
                if (isChestPath) {
                    chestComp := decodedComponents.Has("chest") ? decodedComponents["chest"] : 0
                    if (chestComp && Type(chestComp) = "Map" && chestComp.Has("isOpened") && chestComp["isOpened"]) {
                        statFiltered += 1
                        continue
                    }
                }

                ; Classify the entity type
                positionedComponent := decodedComponents.Has("positioned") ? decodedComponents["positioned"] : 0
                isFriendly := positionedComponent && positionedComponent.Has("isFriendly") && positionedComponent["isFriendly"]

                isChest  := isChestPath
                isMinion := isMonster && isFriendly
                isNpc    := isNpcPath || isCharacter || (isFriendly && !isMonster)
                isEnemy  := !isFriendly && !isChest && !isAreaTransition && !isWaypoint && !isCheckpoint

                ; Rarity from Mods/ObjectMagicProperties (0=Normal,1=Magic,2=Rare,3=Unique/Boss)
                rarityId := decodedComponents.Has("rarityId") ? decodedComponents["rarityId"] : 0
                isEnemyBoss   := isEnemy && (rarityId = 3)           ; Unique — bosses
                isEnemyRare   := isEnemy && (rarityId = 2)           ; Rare
                isEnemyNormal := isEnemy && !isEnemyBoss && !isEnemyRare

                ; Apply entity-group filters
                if (isChest && !this.ShowChests) {
                    statFiltered += 1
                    continue
                }
                if (isMinion && !this.ShowMinions) {
                    statFiltered += 1
                    continue
                }
                if (isNpc && !this.ShowNpcs) {
                    statFiltered += 1
                    continue
                }
                if (isEnemyNormal && !this.ShowEnemyNormal) {
                    statFiltered += 1
                    continue
                }
                if (isEnemyRare && !this.ShowEnemyRare) {
                    statFiltered += 1
                    continue
                }
                if (isEnemyBoss && !this.ShowEnemyBoss) {
                    statFiltered += 1
                    continue
                }

                ; Dot color by entity type
                dotColor := isAreaTransition ? RadarOverlay.COLOR_AREATRANSITION
                          : isWaypoint       ? RadarOverlay.COLOR_WAYPOINT
                          : isCheckpoint     ? RadarOverlay.COLOR_CHECKPOINT
                          : isChest          ? RadarOverlay.COLOR_CHEST
                          : isMinion         ? RadarOverlay.COLOR_MINION
                          : isNpc            ? RadarOverlay.COLOR_NPC
                          : isEnemyBoss      ? RadarOverlay.COLOR_ENEMY_BOSS
                          : isEnemyRare      ? RadarOverlay.COLOR_ENEMY_RARE
                          :                    RadarOverlay.COLOR_ENEMY_NORMAL
                ; Group color override — a matching path group wins over the type color
                if (entityPath != "") {
                    _grp := ResolveEntityGroupByPath(entityPath)
                    if (_grp)
                        dotColor := GroupColorToBgr(_grp["color"])
                }

                dotRadius := (isAreaTransition || isWaypoint || isCheckpoint) ? (isLargeMap ? 6 : 4)
                           : (isLargeMap ? 4 : 3)
                ; Skip normal dot draw for highlighted entity — it will be drawn last, on top
                if !(this.highlightedEntityPath != "" && entity.Has("path") && entity["path"] = this.highlightedEntityPath)
                    this._DrawDot(dotScreenX, dotScreenY, dotColor, dotRadius)
                statDrawn += 1
            }
        }

        ; ── Highlighted entity: draw path or straight line, then dot on top ──────
        if (hlScreenX >= 0)
        {
            hlColor   := this._hlEntityColor   ; entity-type color (set when entity was found above)
            lineWidth := isLargeMap ? 2 : 1
            playerGX  := playerWorldX / RadarOverlay.WORLD_TO_GRID_RATIO
            playerGY  := playerWorldY / RadarOverlay.WORLD_TO_GRID_RATIO

            ; Use cached A* path segments if available for this entity, else straight line.
            ; Polyline: builds the POINT buffer once → 1 syscall instead of 4×n syscalls.
            pathCoords := this._pathGridCoords
            if (pathCoords.Length >= 2 && this._pathHlEntity = this.highlightedEntityPath)
            {
                n       := pathCoords.Length
                pathPts := Buffer(n * 8, 0)
                for i, pt in pathCoords
                {
                    dGX := pt[1] - playerGX
                    dGY := pt[2] - playerGY
                    NumPut("Int", Round(mapCenterX + (dGX - dGY)     * projectionCos), pathPts, (i-1)*8)
                    NumPut("Int", Round(mapCenterY + (0-dGX-dGY)     * projectionSin), pathPts, (i-1)*8+4)
                }
                pen    := this._GetPen(hlColor, lineWidth)
                oldPen := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", pen, "Ptr")
                DllCall("Polyline", "Ptr", this.memDC, "Ptr", pathPts, "Int", n)
                DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldPen)
            }
            else
                this._DrawLine(Round(mapCenterX), Round(mapCenterY), hlScreenX, hlScreenY, hlColor, lineWidth)

            hlRadius := isLargeMap ? 7 : 5
            this._DrawTopDot(hlScreenX, hlScreenY, hlColor, hlRadius)
            ; Label: entity short name + distance
            labelText := (hlName != "" ? hlName : "?") . (hlDistM >= 0 ? " (" hlDistM "m)" : "")
            this._DrawText(hlScreenX + hlRadius + 3, hlScreenY - 6, labelText, hlColor)
        }

        ; ── Zone scan entities: draw discovered sleeping entities from deep scan ──
        if (this._navEnabled && this._navTargets.Length > 0)
        {
            playerGX  := playerWorldX / RadarOverlay.WORLD_TO_GRID_RATIO
            playerGY  := playerWorldY / RadarOverlay.WORLD_TO_GRID_RATIO
            for idx, target in this._navTargets
            {
                dGX := target["gridX"] - playerGX
                dGY := target["gridY"] - playerGY
                tSX := Round(mapCenterX + (dGX - dGY) * projectionCos)
                tSY := Round(mapCenterY + (0 - dGX - dGY) * projectionSin)

                tType := target["type"]
                tColor := (tType = "AreaTransition") ? RadarOverlay.COLOR_AREATRANSITION
                        : (tType = "Waypoint")       ? RadarOverlay.COLOR_WAYPOINT
                        : (tType = "Checkpoint")     ? RadarOverlay.COLOR_CHECKPOINT
                        : (tType = "Boss")           ? RadarOverlay.COLOR_ENEMY_BOSS
                        : (tType = "NPC")            ? RadarOverlay.COLOR_NPC
                        :                              0xFFFFFF
                tRadius := (tType = "AreaTransition" || tType = "Waypoint") ? (isLargeMap ? 7 : 5)
                         : (isLargeMap ? 5 : 3)

                ; Draw a ring (hollow) for zone-scan entities so they're visually distinct from live entities
                this._DrawDot(tSX, tSY, tColor, tRadius)

                ; Label for AreaTransitions and Waypoints
                if (tType = "AreaTransition" || tType = "Waypoint")
                {
                    shortName := target["path"]
                    lastSlash := InStr(shortName, "/",, -1)
                    if (lastSlash > 0)
                        shortName := SubStr(shortName, lastSlash + 1)
                    distWorld := Round(Sqrt(dGX * dGX + dGY * dGY) * RadarOverlay.WORLD_TO_GRID_RATIO)
                    this._DrawText(tSX + tRadius + 3, tSY - 6,
                        shortName " (" distWorld "m)", tColor)
                }
            }
        }

        ; ── Navigation path: A* path to nearest AreaTransition ──
        ; Polyline: 1 syscall for the entire path instead of 4×n syscalls.
        navCoords := this._navPathCoords
        if (this._navEnabled && navCoords.Length >= 2)
        {
            navColor  := 0x00D7FF   ; gold (BGR)
            navWidth  := isLargeMap ? 3 : 2
            playerGX  := playerWorldX / RadarOverlay.WORLD_TO_GRID_RATIO
            playerGY  := playerWorldY / RadarOverlay.WORLD_TO_GRID_RATIO
            n         := navCoords.Length
            navPts    := Buffer(n * 8, 0)
            for i, pt in navCoords
            {
                dGX := pt[1] - playerGX
                dGY := pt[2] - playerGY
                NumPut("Int", Round(mapCenterX + (dGX - dGY)   * projectionCos), navPts, (i-1)*8)
                NumPut("Int", Round(mapCenterY + (0-dGX-dGY)   * projectionSin), navPts, (i-1)*8+4)
            }
            pen    := this._GetPen(navColor, navWidth)
            oldPen := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", pen, "Ptr")
            DllCall("Polyline", "Ptr", this.memDC, "Ptr", navPts, "Int", n)
            DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldPen)
        }

        ; ── Combat path: A* route to the currently targeted enemy ─────────
        ; Same projection as the nav path. Drawn in red on top so it visually
        ; dominates if both paths happen to overlap. Empty (and so skipped) when
        ; combat is idle or LoS to the target is direct.
        combatCoords := this._combatPathCoords
        if (combatCoords.Length >= 2)
        {
            combatColor := 0x3030FF   ; red (BGR)
            combatWidth := isLargeMap ? 3 : 2
            playerGX    := playerWorldX / RadarOverlay.WORLD_TO_GRID_RATIO
            playerGY    := playerWorldY / RadarOverlay.WORLD_TO_GRID_RATIO
            cn          := combatCoords.Length
            combatPts   := Buffer(cn * 8, 0)
            for i, pt in combatCoords
            {
                dGX := pt[1] - playerGX
                dGY := pt[2] - playerGY
                NumPut("Int", Round(mapCenterX + (dGX - dGY) * projectionCos), combatPts, (i-1)*8)
                NumPut("Int", Round(mapCenterY + (0-dGX-dGY) * projectionSin), combatPts, (i-1)*8+4)
            }
            pen    := this._GetPen(combatColor, combatWidth)
            oldPen := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", pen, "Ptr")
            DllCall("Polyline", "Ptr", this.memDC, "Ptr", combatPts, "Int", cn)
            DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldPen)
        }

        ; ── Combat target marker (current enemy) ──────────────────────────
        ; Red ring + crosshair at the enemy the bot is engaging — same style
        ; as the exploration target so the user can always see where the bot
        ; wants to go/attack. Gated on the combat state; coordinates are
        ; written by CombatAutomation each tick (-1 clears). g_autoPilotState
        ; is declared global in the exploration block above.
        if (IsSet(g_autoPilotState) && g_autoPilotState = "combat" && this._combatTargetGX >= 0)
        {
            ctColor  := 0x3030FF   ; red (BGR)
            playerGX := playerWorldX / RadarOverlay.WORLD_TO_GRID_RATIO
            playerGY := playerWorldY / RadarOverlay.WORLD_TO_GRID_RATIO
            dGX := this._combatTargetGX - playerGX
            dGY := this._combatTargetGY - playerGY
            ctX := Round(mapCenterX + (dGX - dGY) * projectionCos)
            ctY := Round(mapCenterY + (0-dGX-dGY) * projectionSin)
            r   := isLargeMap ? 8 : 5
            this._DrawRectOutline(ctX - r, ctY - r, r * 2, r * 2, ctColor, 2)
            this._DrawLine(ctX - r - 3, ctY, ctX + r + 3, ctY, ctColor, 1)
            this._DrawLine(ctX, ctY - r - 3, ctX, ctY + r + 3, ctColor, 1)
        }

        ; ── Exploration path + target (AutoPilot scouting) ────────────────
        ; Same projection as the nav/combat paths. Cyan polyline for the A*
        ; route the explorer is following, plus a hollow ring at the current
        ; target cell. Gated on the explore state so a stale route is never
        ; drawn while combat/loot owns the tick; coordinates are written by
        ; ExplorationModule each tick (empty/-1 clears them).
        global g_autoPilotState
        if (IsSet(g_autoPilotState) && g_autoPilotState = "explore")
        {
            exploreColor := 0xFFC000   ; light blue (BGR)
            playerGX     := playerWorldX / RadarOverlay.WORLD_TO_GRID_RATIO
            playerGY     := playerWorldY / RadarOverlay.WORLD_TO_GRID_RATIO

            exploreCoords := this._explorePathCoords
            if (exploreCoords.Length >= 2)
            {
                en        := exploreCoords.Length
                explorePts := Buffer(en * 8, 0)
                for i, pt in exploreCoords
                {
                    dGX := pt[1] - playerGX
                    dGY := pt[2] - playerGY
                    NumPut("Int", Round(mapCenterX + (dGX - dGY) * projectionCos), explorePts, (i-1)*8)
                    NumPut("Int", Round(mapCenterY + (0-dGX-dGY) * projectionSin), explorePts, (i-1)*8+4)
                }
                pen    := this._GetPen(exploreColor, isLargeMap ? 3 : 2)
                oldPen := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", pen, "Ptr")
                DllCall("Polyline", "Ptr", this.memDC, "Ptr", explorePts, "Int", en)
                DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldPen)
            }

            ; Target cell — hollow ring + crosshair so it stands out from dots.
            if (this._exploreTargetGX >= 0)
            {
                dGX := this._exploreTargetGX - playerGX
                dGY := this._exploreTargetGY - playerGY
                etX := Round(mapCenterX + (dGX - dGY) * projectionCos)
                etY := Round(mapCenterY + (0-dGX-dGY) * projectionSin)
                r   := isLargeMap ? 8 : 5
                this._DrawRectOutline(etX - r, etY - r, r * 2, r * 2, exploreColor, 2)
                this._DrawLine(etX - r - 3, etY, etX + r + 3, etY, exploreColor, 1)
                this._DrawLine(etX, etY - r - 3, etX, etY + r + 3, exploreColor, 1)
            }
        }

        ; Debug entity-filter stats — collected for the WebView debug tab.
        if this.DebugMode
        {
            entKey := isLargeMap ? "entL" : "entM"
            this._debugLines[entKey] := (isLargeMap?"L":"M")
                . "-ent: tot=" statTotal " noD=" statNoDecoded " noR=" statNoRender
                . " flt=" statFiltered " dead=" statDead " drawn=" statDrawn
                . " p0=" firstEntityPath
            if fs
            {
                preFlt  := fs.Has("preFilter")  ? fs["preFilter"]  : "?"
                postFlt := fs.Has("postFilter") ? fs["postFilter"] : "?"
                fltKey := isLargeMap ? "fltL" : "fltM"
                this._debugLines[fltKey] := "flt: s1=" fs["s1"] " s2=" fs["s2"]
                    . " s3=" fs["s3"] " s4=" fs["s4"] " s5=" fs["s5"] " s6=" fs["s6"]
                    . " bl=" fs["bl"] " blTot=" fs["blTotal"]
                    . " pre=" preFlt " post=" postFlt
            }
        }

        ; Release any clip region set above (HUD masks) so it never affects a later draw into
        ; the back-buffer. SelectClipRgn(NULL) is a harmless no-op when none was set.
        DllCall("SelectClipRgn", "Ptr", this.memDC, "Ptr", 0)

        ; Debug: outline every HUD clip mask in red (unclipped, on top of the maphack) so the
        ; user can see exactly where MAP_HUD_MASKS clips while tuning the values. Large map only.
        if (isLargeMap && this._mapHackMaskDebug)
        {
            for _, mask in RadarOverlay.MAP_HUD_MASKS
            {
                r := this._HudMaskRect(mask, gameWindowWidth, gameWindowHeight, scaleFactorY)
                if r
                    this._DrawRectOutline(r[1], r[2], r[3], r[4], 0x0000FF, 2)   ; red (BGR)
            }
        }
    }

    ; Computes the on-screen rectangle for one HUD clip mask: design px scaled uniformly by
    ; gameWindowHeight/1600 (sY) and pinned to its anchor corner/edge. Returns [x, y, w, h] in
    ; window pixels, or 0 when the mask has no area. Shared by the clip loop and the debug outline.
    _HudMaskRect(mask, gw, gh, sY)
    {
        mh := Round(mask["h"] * sY)
        if (mh <= 0)
            return 0
        if (mask["anchor"] = "bottom")
            return [0, gh - mh, gw, mh]
        mw := Round(mask["w"] * sY)
        if (mw <= 0)
            return 0
        mx := (mask["anchor"] = "br" || mask["anchor"] = "tr") ? gw - mw : 0
        my := (mask["anchor"] = "bl" || mask["anchor"] = "br") ? gh - mh : 0
        return [mx, my, mw, mh]
    }

    ; Returns cached path classification flags used by the hot render loop.
    _GetPathTypeFlags(entityPath)
    {
        if (entityPath = "")
            return Map(
                "isMonster", false, "isCharacter", false, "isNpcPath", false, "isChestPath", false,
                "isAreaTransition", false, "isWaypoint", false, "isCheckpoint", false, "isBossPath", false,
                "isImportantSleep", false
            )

        if this._pathTypeCache.Has(entityPath)
            return this._pathTypeCache[entityPath]

        entityPathLower := StrLower(entityPath)
        isMonster        := InStr(entityPathLower, "metadata/monsters/")
        isCharacter      := InStr(entityPathLower, "metadata/characters/")
        isNpcPath        := InStr(entityPathLower, "metadata/npc/")
        isChestPath      := InStr(entityPathLower, "/chests/") || InStr(entityPathLower, "strongbox")
        isAreaTransition := InStr(entityPathLower, "areatransition")
        isWaypoint       := InStr(entityPathLower, "waypoint")
        isCheckpoint     := InStr(entityPathLower, "checkpoint")
        isBossPath       := isMonster && (InStr(entityPathLower, "boss") || InStr(entityPathLower, "unique"))
        isImportantSleep := isAreaTransition || isWaypoint || isCheckpoint || isBossPath || isNpcPath

        flags := Map(
            "isMonster", isMonster,
            "isCharacter", isCharacter,
            "isNpcPath", isNpcPath,
            "isChestPath", isChestPath,
            "isAreaTransition", isAreaTransition,
            "isWaypoint", isWaypoint,
            "isCheckpoint", isCheckpoint,
            "isBossPath", isBossPath,
            "isImportantSleep", isImportantSleep
        )
        this._pathTypeCache[entityPath] := flags
        return flags
    }

    ; ── GDI drawing helpers ──────────────────────────────────────────────────────────────
    ; _GetPen / _GetBrush are inherited from GdiOverlayBase (same cached impl).

    ; ── Batch collector methods ──────────────────────────────────────────────────────────
    ; These methods do NOT draw immediately — they collect draw operations in RAM.
    ; _FlushBatch() executes all collected ops in one batch (once per frame).

    ; Queues a filled circle into the normal dot batch (drawn before the highlight dot).
    _DrawDot(centerX, centerY, colorBGR, radius := 3)
    {
        key := colorBGR | (radius << 24)
        if !this._dotBatch.Has(key)
            this._dotBatch[key] := []
        this._dotBatch[key].Push([centerX, centerY])
    }

    ; Queues a filled circle into the top-priority dot batch (drawn after _dotBatch → always on top).
    ; Used exclusively for the highlighted entity dot so it appears above all other dots.
    _DrawTopDot(centerX, centerY, colorBGR, radius := 3)
    {
        key := colorBGR | (radius << 24)
        if !this._dotTopBatch.Has(key)
            this._dotTopBatch[key] := []
        this._dotTopBatch[key].Push([centerX, centerY])
    }

    ; Queues a line segment into the line batch.
    _DrawLine(x1, y1, x2, y2, colorBGR, penWidth := 1)
    {
        key := colorBGR | (penWidth << 24)
        if !this._lineBatch.Has(key)
            this._lineBatch[key] := []
        this._lineBatch[key].Push([x1, y1, x2, y2])
    }

    ; Queues a text draw into the text batch.
    _DrawText(screenX, screenY, text, colorBGR)
    {
        this._textBatch.Push([screenX, screenY, text, colorBGR])
    }

    ; ── Batch flush ──────────────────────────────────────────────────────────────────────
    ; Renders all queued draw operations in one pass — called once per frame before _Blit().
    ;
    ; Flush order (correct layering):
    ;   1. Lines       — sit below the dots
    ;   2. Normal dots (entity dots, player dot, zone-scan dots)
    ;   3. Top dot     — highlighted entity always on top
    ;   4. Text        — labels always at the very top
    ;
    ; Dot-batch technique: BeginPath → n×Ellipse → EndPath → StrokeAndFillPath
    ;   → 2 SelectObject + 1 BeginPath + n×Ellipse + 1 EndPath + 1 StrokeAndFillPath
    ;   instead of 5 DllCalls × n per color group.
    ;
    ; Line technique: PolyPolyline with n×2-point segments
    ;   → 1 SelectObject + 1 PolyPolyline instead of 4 DllCalls × n.
    _FlushBatch()
    {
        dc := this.memDC

        ; ── 1. Lines ─────────────────────────────────────────────────────────────────────
        for key, segs in this._lineBatch
        {
            n := segs.Length
            if !n
                continue
            color  := key & 0xFFFFFF
            width  := (key >> 24) & 0xFF
            pen    := this._GetPen(color, width)
            oldPen := DllCall("SelectObject", "Ptr", dc, "Ptr", pen, "Ptr")

            ; PolyPolyline: all segments as 2-point polylines in one syscall
            pts    := Buffer(n * 16, 0)    ; n segments × 2 POINTs × 8 bytes
            counts := Buffer(n * 4,  0)    ; n DWORD counts of 2 each
            i := 0
            for seg in segs
            {
                NumPut("Int", seg[1], pts, i * 16)
                NumPut("Int", seg[2], pts, i * 16 + 4)
                NumPut("Int", seg[3], pts, i * 16 + 8)
                NumPut("Int", seg[4], pts, i * 16 + 12)
                NumPut("UInt", 2, counts, i * 4)
                i++
            }
            DllCall("PolyPolyline", "Ptr", dc, "Ptr", pts, "Ptr", counts, "UInt", n)
            DllCall("SelectObject", "Ptr", dc, "Ptr", oldPen)
        }
        this._lineBatch.Clear()

        ; ── 2. + 3. Dots (normal, then top) ──────────────────────────────────────────────
        this._FlushDotLayer(this._dotBatch)
        this._dotBatch.Clear()
        this._FlushDotLayer(this._dotTopBatch)
        this._dotTopBatch.Clear()

        ; ── 4. Text ──────────────────────────────────────────────────────────────────────
        ; SetBkMode once per frame — all TextOut calls benefit from it
        DllCall("SetBkMode", "Ptr", dc, "Int", 1)   ; TRANSPARENT
        for t in this._textBatch
        {
            DllCall("SetTextColor", "Ptr", dc, "UInt", t[4])
            DllCall("TextOutW", "Ptr", dc, "Int", t[1], "Int", t[2], "Str", t[3], "Int", StrLen(t[3]))
        }
        this._textBatch := []
    }

    ; Internal: renders one dot-batch Map (used for both normal and top-priority dots).
    ; Technique: BeginPath + n×Ellipse + EndPath + StrokeAndFillPath per color/radius group.
    _FlushDotLayer(batch)
    {
        dc := this.memDC
        for key, dots in batch
        {
            color  := key & 0xFFFFFF
            radius := (key >> 24) & 0xFF
            pen    := this._GetPen(color)
            brush  := this._GetBrush(color)
            oldPen   := DllCall("SelectObject", "Ptr", dc, "Ptr", pen,   "Ptr")
            oldBrush := DllCall("SelectObject", "Ptr", dc, "Ptr", brush, "Ptr")
            DllCall("BeginPath", "Ptr", dc)
            for dot in dots
                DllCall("Ellipse", "Ptr", dc,
                    "Int", dot[1] - radius, "Int", dot[2] - radius,
                    "Int", dot[1] + radius, "Int", dot[2] + radius)
            DllCall("EndPath", "Ptr", dc)
            DllCall("StrokeAndFillPath", "Ptr", dc)
            DllCall("SelectObject", "Ptr", dc, "Ptr", oldPen)
            DllCall("SelectObject", "Ptr", dc, "Ptr", oldBrush)
        }
    }

    ; Draws a hollow rectangle outline on the back-buffer; uses NULL_BRUSH to avoid filling the interior.
    ; Not batched — called at most once per frame (UI Browser highlight).
    _DrawRect(screenX, screenY, width, height, colorBGR, penWidth := 1)
    {
        pen       := this._GetPen(colorBGR, penWidth)
        nullBrush := DllCall("GetStockObject", "Int", 5, "Ptr")   ; NULL_BRUSH
        oldPen    := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", pen,       "Ptr")
        oldBrush  := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", nullBrush, "Ptr")
        DllCall("Rectangle", "Ptr", this.memDC,
                "Int", screenX, "Int", screenY, "Int", screenX + width, "Int", screenY + height)
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldPen)
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldBrush)
    }

    ; ── Range circle API ─────────────────────────────────────────────────────────────────

    ; Sets (or clears) range circles to draw around the player.
    ; circles: Array of Maps, each with "range" (world units), "color" (BGR), "label" (string).
    ; Pass an empty array [] to clear.
    SetRangeCircles(circles)
    {
        this._rangeCircles := circles
    }

    ; Draws an isometric range ellipse around the player.
    ; rangeWorld: radius in world units.  mapCenterX/Y: player screen position.
    ; projectionCos/Sin: current projection factors.  colorBGR: line color.  label: optional text.
    ; Uses Polyline (1 GDI call for all 49 segments) instead of 48 individual _DrawLine calls.
    _DrawRangeCircle(rangeWorld, mapCenterX, mapCenterY, projectionCos, projectionSin, colorBGR, label := "")
    {
        gridR    := rangeWorld / RadarOverlay.WORLD_TO_GRID_RATIO
        segments := 48
        step     := 6.2831853 / segments   ; 2π / 48
        n        := segments + 1           ; closed loop: last point = first point
        pts      := Buffer(n * 8, 0)       ; n POINTs × 8 Byte
        topSX    := 0, topSY := 999999

        Loop n
        {
            angle := (A_Index - 1) * step
            gx    := gridR * Cos(angle)
            gy    := gridR * Sin(angle)
            sx    := Round(mapCenterX + (gx - gy)       * projectionCos)
            sy    := Round(mapCenterY + (0 - gx - gy)   * projectionSin)
            NumPut("Int", sx, pts, (A_Index - 1) * 8)
            NumPut("Int", sy, pts, (A_Index - 1) * 8 + 4)
            if (sy < topSY)
                topSX := sx, topSY := sy
        }

        pen    := this._GetPen(colorBGR, 2)
        oldPen := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", pen, "Ptr")
        DllCall("Polyline", "Ptr", this.memDC, "Ptr", pts, "Int", n)
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldPen)

        if (label != "")
            this._DrawText(topSX - StrLen(label) * 3, topSY - 14, label, colorBGR)
    }

    ; Draws the screen-space range circle(s) requested by debug-enabled hotkey actions
    ; (monsterCount / aim): a ring at the cursor or at the player's projected screen
    ; position, read from g_hkDebugItems. Called once per frame from Draw(), independent
    ; of the map layers, so the combat/aim radius shows even with the large map closed.
    ; The matching debug TEXT lives in the DebugOverlay's "HOTKEYS" section.
    _RenderHotkeyCircles()
    {
        global g_hkDebugItems
        if !(IsSet(g_hkDebugItems) && g_hkDebugItems is Array && g_hkDebugItems.Length)
            return

        COL_CUR := 0xC0A8FF    ; cursor / player range circle (pinkish, BGR)

        for _, rec in g_hkDebugItems
        {
            if !(rec is Map)
                continue
            ; Cursor pixel circle (screen cursor → client coords).
            if (rec.Has("circleCursorPx") && rec["circleCursorPx"] > 0)
            {
                cx := 0, cy := 0
                CoordMode("Mouse", "Screen")
                MouseGetPos(&cx, &cy)
                this._DrawPixelCircle(cx - this._lastX, cy - this._lastY,
                    rec["circleCursorPx"], COL_CUR)
            }
            ; Player pixel circle (player projected to screen → client coords).
            if (rec.Has("circlePlayerPx") && rec["circlePlayerPx"] > 0)
            {
                ps := this._PlayerScreenPos()
                if (ps)
                    this._DrawPixelCircle(ps["x"] - this._lastX, ps["y"] - this._lastY,
                        rec["circlePlayerPx"], COL_CUR)
            }
        }
    }

    ; Draws the Atlas overlay from the global g_atlasRender snapshot (built by the
    ; Atlas reader once node offsets are confirmed). Inert while g_atlasRender is
    ; 0. Expected shape (all coords in SCREEN space):
    ;   g_atlasRender := Map(
    ;     "nodes", [ Map("x","y","name","biomeId","content"(array of tag strings),"flags"), ... ],
    ;     "connections", [ Map("x1","y1","x2","y2"), ... ],
    ;     "path", [ Map("x","y"), ... ]   ; e.g. player → selected map
    ;   )
    _RenderAtlas()
    {
        global g_atlasRender
        if !(IsSet(g_atlasRender) && g_atlasRender is Map)
            return
        nodes := g_atlasRender.Has("nodes") ? g_atlasRender["nodes"] : 0
        if !(nodes is Array) || !nodes.Length
            return

        ox := this._lastX, oy := this._lastY
        COL_CONN := 0x707070    ; node-graph connections (grey, BGR)
        COL_NAME := 0x8AD6F0    ; map names (gold-ish, BGR)
        COL_PATH := 0xFFC040    ; player → target route (cyan, BGR)

        ; Node-graph connections (under everything else).
        conns := g_atlasRender.Has("connections") ? g_atlasRender["connections"] : 0
        if (conns is Array)
        {
            for c in conns
            {
                if (c is Map && c.Has("x1"))
                    this._DrawLine(Round(c["x1"] - ox), Round(c["y1"] - oy),
                        Round(c["x2"] - ox), Round(c["y2"] - oy), COL_CONN, 1)
            }
        }

        ; Per-node: biome ring, name label, content badges.
        for nd in nodes
        {
            if !(nd is Map && nd.Has("x"))
                continue
            sx := Round(nd["x"] - ox), sy := Round(nd["y"] - oy)

            bi := AtlasBiome(nd.Has("biomeId") ? nd["biomeId"] : -1)
            if (bi && bi["show"])
                this._DrawPixelCircle(sx, sy, 14, bi["color"])

            nm := nd.Has("name") ? nd["name"] : ""
            if (nm != "")
                this._DrawText(sx + 16, sy - 6, nm, COL_NAME)

            if (nd.Has("content") && nd["content"] is Array)
            {
                bx := sx + 16, by := sy + 8
                for tag in nd["content"]
                {
                    ci := AtlasContent(tag)
                    if !(ci && ci["show"])
                        continue
                    this._DrawText(bx, by, "[" ci["abbrev"] "]", ci["bg"])
                    bx += (StrLen(ci["abbrev"]) + 2) * 8
                }
            }
        }

        ; Optional path from player to a selected map.
        path := g_atlasRender.Has("path") ? g_atlasRender["path"] : 0
        if (path is Array && path.Length >= 2)
        {
            i := 1
            while (i < path.Length)
            {
                a := path[i], b := path[i + 1]
                if (a is Map && b is Map)
                    this._DrawLine(Round(a["x"] - ox), Round(a["y"] - oy),
                        Round(b["x"] - ox), Round(b["y"] - oy), COL_PATH, 2)
                i += 1
            }
        }
    }

    ; Projects the player's world position to screen via the last radar snapshot.
    ; Returns Map("x","y") in screen coordinates, or 0 if unavailable.
    _PlayerScreenPos()
    {
        global g_radarLastSnap
        snap := (IsSet(g_radarLastSnap) && g_radarLastSnap is Map) ? g_radarLastSnap : 0
        if !snap
            return 0
        gameHwnd := ResolvePoEWindow()
        if !gameHwnd
            return 0
        inGs := snap.Has("inGameState") ? snap["inGameState"] : 0
        w2sMatrix := (inGs && inGs.Has("w2sMatrix")) ? inGs["w2sMatrix"] : 0
        area := (inGs && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
        prc := (area && area.Has("playerRenderComponent")) ? area["playerRenderComponent"] : 0
        pwp := (prc && prc is Map && prc.Has("worldPosition")) ? prc["worldPosition"] : 0
        if !(pwp && pwp is Map)
            return 0
        pX := pwp.Has("x") ? pwp["x"] : 0
        pY := pwp.Has("y") ? pwp["y"] : 0
        pZ := pwp.Has("z") ? pwp["z"] : 0
        ci := Map("nearestWorldX", pX, "nearestWorldY", pY, "nearestWorldZ", pZ,
            "w2sMatrix", w2sMatrix, "playerWorldX", pX, "playerWorldY", pY, "playerWorldZ", pZ)
        return _WorldToScreen(ci, gameHwnd)
    }

    ; Draws a screen-space (non-isometric) circle of <radiusPx> around (cx,cy).
    _DrawPixelCircle(cx, cy, radiusPx, colorBGR)
    {
        segments := 40
        step := 6.2831853 / segments
        n := segments + 1
        pts := Buffer(n * 8, 0)
        Loop n
        {
            angle := (A_Index - 1) * step
            NumPut("Int", Round(cx + radiusPx * Cos(angle)), pts, (A_Index - 1) * 8)
            NumPut("Int", Round(cy + radiusPx * Sin(angle)), pts, (A_Index - 1) * 8 + 4)
        }
        pen := this._GetPen(colorBGR, 2)
        oldPen := DllCall("SelectObject", "Ptr", this.memDC, "Ptr", pen, "Ptr")
        DllCall("Polyline", "Ptr", this.memDC, "Ptr", pts, "Int", n)
        DllCall("SelectObject", "Ptr", this.memDC, "Ptr", oldPen)
    }

    ; ── Internal buffer management ───────────────────────────────────────────────────────
    ; _InitBuffers / _Blit are inherited from GdiOverlayBase (same impl).

    ; ── Map Hack: walkable terrain border overlay ──────────────────────────────────

    ; Generates a pre-rendered maphack bitmap pair (color source + monochrome mask)
    ; from the walkable terrain data.  Called once when the area changes.
    ; The mask has 1-bits for border cells (non-walkable cells adjacent to walkable cells)
    ; and 0-bits elsewhere; PlgBlt uses the mask so only borders are drawn.
    _GenerateMapHackBitmap()
    {
        this._DestroyMapHackBitmap()

        terrain := this._terrain
        if !terrain
            return

        buf  := terrain["data"]
        bpr  := terrain["bytesPerRow"]
        rows := terrain["totalRows"]
        gridW := terrain["gridWidth"]
        dsz  := terrain["dataSize"]

        ; Snapshot the terrain identity now — if the player changes zone during
        ; the long generation loop below we want to bail out cleanly instead of
        ; finishing a bitmap that's already stale.
        startDsz := dsz

        STEP := 2
        bmpW := gridW // STEP
        bmpH := rows // STEP
        if (bmpW < 10 || bmpH < 10)
            return

        ; ── Source bitmap: solid maphack color ──
        screenDC := DllCall("GetDC", "Ptr", 0, "Ptr")
        hBmp := DllCall("CreateCompatibleBitmap", "Ptr", screenDC, "Int", bmpW, "Int", bmpH, "Ptr")
        hDC  := DllCall("CreateCompatibleDC", "Ptr", screenDC, "Ptr")
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", screenDC)
        DllCall("SelectObject", "Ptr", hDC, "Ptr", hBmp)

        brush := DllCall("CreateSolidBrush", "UInt", RadarOverlay.COLOR_MAPHACK, "Ptr")
        rct := Buffer(16, 0)
        NumPut("Int", bmpW, rct, 8)
        NumPut("Int", bmpH, rct, 12)
        DllCall("FillRect", "Ptr", hDC, "Ptr", rct, "Ptr", brush)
        DllCall("DeleteObject", "Ptr", brush)

        ; ── Monochrome mask bitmap via DC (proven approach) ──
        hMask := DllCall("CreateBitmap", "Int", bmpW, "Int", bmpH, "UInt", 1, "UInt", 1, "Ptr", 0, "Ptr")
        maskDC := DllCall("CreateCompatibleDC", "Ptr", 0, "Ptr")
        oldMaskBmp := DllCall("SelectObject", "Ptr", maskDC, "Ptr", hMask, "Ptr")

        blackBrush := DllCall("GetStockObject", "Int", 4, "Ptr")  ; BLACK_BRUSH
        DllCall("FillRect", "Ptr", maskDC, "Ptr", rct, "Ptr", blackBrush)

        ; ── Walkable-fill mask (1-bit) — 1 wherever the 2×2 block has ANY
        ; walkable cell, 50% stippled so the game map shows through. Built in
        ; the same scan as the border mask below. ──
        hWalkMask := DllCall("CreateBitmap", "Int", bmpW, "Int", bmpH, "UInt", 1, "UInt", 1, "Ptr", 0, "Ptr")
        walkMaskDC := DllCall("CreateCompatibleDC", "Ptr", 0, "Ptr")
        oldWalkBmp := DllCall("SelectObject", "Ptr", walkMaskDC, "Ptr", hWalkMask, "Ptr")
        DllCall("FillRect", "Ptr", walkMaskDC, "Ptr", rct, "Ptr", blackBrush)

        ; Skip outer margin to avoid drawing the terrain boundary rectangle.
        MARGIN := 6

        ; Border detection — byte-wise mixed-region test.
        ;
        ; Each bitmap pixel maps to a 2×2 grid block at (gx, gy)..(gx+1, gy+1).
        ; Each row of that block is encoded as ONE byte (two 4-bit nibbles,
        ; lower=even-x, upper=odd-x). The pixel is a border iff the block
        ; contains BOTH walkable (nibble != 0) AND non-walkable (nibble = 0)
        ; cells — i.e. the boundary between walkable and not runs through
        ; this 2×2 region.
        ;
        ; Reading two bytes and checking a handful of bitwise conditions per
        ; pixel replaces 4-sub-cell × 8-neighbor scans of the previous version
        ; (~36 NumGets per pixel → 2). Total speedup ~10–15×. Visually equivalent
        ; for wall outlines — the previous "non-walkable cell with walkable
        ; neighbor" definition just shifts the highlighted edge inward by one
        ; cell, which at half-grid bitmap resolution is invisible.
        loop bmpH
        {
            by := A_Index - 1
            gy := by * STEP
            if (gy < MARGIN || gy >= rows - MARGIN - 1)
                continue

            ; Abort cleanly if the player changed zones mid-generation: the
            ; terrain buffer in `this._terrain` would now point at the new map
            ; and continuing would produce a mismatched bitmap. Cheap to check
            ; once every 64 rows.
            if (Mod(by, 64) = 0)
            {
                if !(this._terrain && this._terrain["dataSize"] = startDsz)
                {
                    this._DestroyMapHackBitmap()
                    DllCall("SelectObject", "Ptr", maskDC, "Ptr", oldMaskBmp)
                    DllCall("DeleteDC", "Ptr", maskDC)
                    DllCall("SelectObject", "Ptr", walkMaskDC, "Ptr", oldWalkBmp)
                    DllCall("DeleteDC", "Ptr", walkMaskDC)
                    DllCall("DeleteObject", "Ptr", hWalkMask)
                    return
                }
            }

            row1Base := gy * bpr           ; byte offset for row gy
            row2Base := (gy + 1) * bpr     ; byte offset for row gy+1

            loop bmpW
            {
                bx := A_Index - 1
                gx := bx * STEP
                if (gx < MARGIN || gx >= gridW - MARGIN - 1)
                    continue

                ; One byte per row covers cells (gx, gx+1) because gx is even.
                bIdx := gx >> 1
                i1 := row1Base + bIdx
                i2 := row2Base + bIdx
                if (i1 < 0 || i2 < 0 || i1 >= dsz || i2 >= dsz)
                    continue

                b1 := NumGet(buf, i1, "UChar")
                b2 := NumGet(buf, i2, "UChar")

                ; Walkable-fill mask: any walkable cell in the 2×2 block, 50%
                ; checkerboard stipple so the underlying game map stays visible.
                if ((b1 != 0 || b2 != 0) && ((bx + by) & 1) = 0)
                    DllCall("SetPixelV", "Ptr", walkMaskDC, "Int", bx, "Int", by, "UInt", 0xFFFFFF)

                if (   (b1 & 0x0F) != 0 && (b1 & 0xF0) != 0
                    && (b2 & 0x0F) != 0 && (b2 & 0xF0) != 0)
                    continue   ; all 4 walkable — open ground, skip

                if (b1 != 0 || b2 != 0)
                {
                    ; Mixed region — at least one walkable AND at least one
                    ; non-walkable cell within the 2×2 block. Fast border path.
                    DllCall("SetPixelV", "Ptr", maskDC, "Int", bx, "Int", by, "UInt", 0xFFFFFF)
                    continue
                }

                ; All 4 cells non-walkable. Could still be the EDGE of a wall
                ; that's grid-aligned with our 2×2 sampling — adjacent walkable
                ; bytes would not show up via the mixed test. Read the 6
                ; surrounding bytes (left/right rows + above/below) and mark
                ; the pixel as a border if any of them carries a walkable cell.
                isBorder := false

                ; Left column (rows gy, gy+1 at byte index bx-1)
                if (bx > 0)
                {
                    li := row1Base + (bx - 1)
                    if (li >= 0 && li < dsz && NumGet(buf, li, "UChar") != 0)
                        isBorder := true
                    if !isBorder
                    {
                        li := row2Base + (bx - 1)
                        if (li < dsz && NumGet(buf, li, "UChar") != 0)
                            isBorder := true
                    }
                }
                ; Right column
                if (!isBorder && (bx + 1) < bpr)
                {
                    ri := row1Base + (bx + 1)
                    if (ri < dsz && NumGet(buf, ri, "UChar") != 0)
                        isBorder := true
                    if !isBorder
                    {
                        ri := row2Base + (bx + 1)
                        if (ri < dsz && NumGet(buf, ri, "UChar") != 0)
                            isBorder := true
                    }
                }
                ; Top row
                if (!isBorder && gy > 0)
                {
                    ti := (gy - 1) * bpr + bx
                    if (ti >= 0 && ti < dsz && NumGet(buf, ti, "UChar") != 0)
                        isBorder := true
                }
                ; Bottom row
                if (!isBorder && (gy + 2) < rows)
                {
                    bi := (gy + 2) * bpr + bx
                    if (bi < dsz && NumGet(buf, bi, "UChar") != 0)
                        isBorder := true
                }

                if isBorder
                    DllCall("SetPixelV", "Ptr", maskDC, "Int", bx, "Int", by, "UInt", 0xFFFFFF)
            }
        }

        DllCall("SelectObject", "Ptr", maskDC, "Ptr", oldMaskBmp)
        DllCall("DeleteDC", "Ptr", maskDC)
        DllCall("SelectObject", "Ptr", walkMaskDC, "Ptr", oldWalkBmp)
        DllCall("DeleteDC", "Ptr", walkMaskDC)

        ; ── Walkable fill colour source bitmap (solid COLOR_WALKABLE) ──
        ; PlgBlt takes the drawn colour from this source through hWalkMask.
        screenDC2 := DllCall("GetDC", "Ptr", 0, "Ptr")
        hWalkBmp  := DllCall("CreateCompatibleBitmap", "Ptr", screenDC2, "Int", bmpW, "Int", bmpH, "Ptr")
        walkColorDC := DllCall("CreateCompatibleDC", "Ptr", screenDC2, "Ptr")
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", screenDC2)
        DllCall("SelectObject", "Ptr", walkColorDC, "Ptr", hWalkBmp)
        wbrush := DllCall("CreateSolidBrush", "UInt", RadarOverlay.COLOR_WALKABLE, "Ptr")
        DllCall("FillRect", "Ptr", walkColorDC, "Ptr", rct, "Ptr", wbrush)
        DllCall("DeleteObject", "Ptr", wbrush)

        this._mapHackDC    := hDC
        this._mapHackBmp   := hBmp
        this._mapHackMask  := hMask
        this._mapWalkColorDC  := walkColorDC
        this._mapWalkColorBmp := hWalkBmp
        this._mapWalkMask     := hWalkMask
        this._mapHackW     := bmpW
        this._mapHackH     := bmpH
        this._mapHackStep  := STEP
        this._mapHackGridW := bmpW * STEP
        this._mapHackGridH := bmpH * STEP
    }

    ; Frees all GDI resources used by the maphack + walkable-grid bitmaps.
    _DestroyMapHackBitmap()
    {
        if this._mapHackMask {
            DllCall("DeleteObject", "Ptr", this._mapHackMask)
            this._mapHackMask := 0
        }
        if this._mapHackBmp {
            stockBmp := DllCall("GetStockObject", "Int", 0, "Ptr")
            if this._mapHackDC
                DllCall("SelectObject", "Ptr", this._mapHackDC, "Ptr", stockBmp)
            DllCall("DeleteObject", "Ptr", this._mapHackBmp)
            this._mapHackBmp := 0
        }
        if this._mapHackDC {
            DllCall("DeleteDC", "Ptr", this._mapHackDC)
            this._mapHackDC := 0
        }
        ; Walkable-grid fill layer
        if this._mapWalkMask {
            DllCall("DeleteObject", "Ptr", this._mapWalkMask)
            this._mapWalkMask := 0
        }
        if this._mapWalkColorBmp {
            stockBmp2 := DllCall("GetStockObject", "Int", 0, "Ptr")
            if this._mapWalkColorDC
                DllCall("SelectObject", "Ptr", this._mapWalkColorDC, "Ptr", stockBmp2)
            DllCall("DeleteObject", "Ptr", this._mapWalkColorBmp)
            this._mapWalkColorBmp := 0
        }
        if this._mapWalkColorDC {
            DllCall("DeleteDC", "Ptr", this._mapWalkColorDC)
            this._mapWalkColorDC := 0
        }
    }

    ; Blits one pre-rendered terrain layer (srcDC's colour through mask's
    ; 1-bits) onto the back-buffer via PlgBlt with the isometric projection.
    ; Shared by the wall-border maphack and the walkable-grid fill overlay —
    ; both bitmaps are generated together so they share W/H/grid dimensions.
    _BlitMaskLayer(srcDC, mask, mapCenterX, mapCenterY, playerWorldX, playerWorldY,
                   projectionCos, projectionSin)
    {
        if (!srcDC || !mask)
            return

        playerGX := playerWorldX / RadarOverlay.WORLD_TO_GRID_RATIO
        playerGY := playerWorldY / RadarOverlay.WORLD_TO_GRID_RATIO
        gridW := this._mapHackGridW
        gridH := this._mapHackGridH
        bmpW  := this._mapHackW
        bmpH  := this._mapHackH
        if (bmpW < 1 || bmpH < 1)
            return

        ; Forward affine — source pixel (bx,by) → screen — built from the same 3 grid
        ; corners the entity dots use. Grid (gx,gy) → screen:
        ;   sX = mcX + ((gx-pGX)-(gy-pGY))*pCos,  sY = mcY + (-(gx-pGX)-(gy-pGY))*pSin
        ; Source (0,0)=grid(0,0), (bmpW,0)=grid(gridW,0), (0,bmpH)=grid(0,gridH).
        dGX0 := -playerGX
        dGY0 := -playerGY
        p0x := mapCenterX + (dGX0 - dGY0) * projectionCos
        p0y := mapCenterY + (-dGX0 - dGY0) * projectionSin
        p1x := mapCenterX + ((gridW - playerGX) - dGY0) * projectionCos
        p1y := mapCenterY + (-(gridW - playerGX) - dGY0) * projectionSin
        p2x := mapCenterX + (dGX0 - (gridH - playerGY)) * projectionCos
        p2y := mapCenterY + (-dGX0 - (gridH - playerGY)) * projectionSin

        ; Per-source-pixel screen-space basis vectors (along source X and Y).
        ux := (p1x - p0x) / bmpW, uy := (p1y - p0y) / bmpW
        vx := (p2x - p0x) / bmpH, vy := (p2y - p0y) / bmpH
        det := ux * vy - uy * vx

        ; ── Source-rect clipping ──────────────────────────────────────────────────────
        ; The full bitmap maps to a parallelogram whose bounding box dwarfs the window,
        ; so PlgBlt otherwise iterates millions of off-screen pixels. Inverse-map the 4
        ; window corners into source space, take their bounding box (a superset → no
        ; outline pixels lost), pad it, and blit only that sub-rectangle. Pixel-identical
        ; to the full blit; just skips the invisible majority. Degenerate det → full blit.
        bx0 := 0, by0 := 0, bx1 := bmpW, by1 := bmpH
        if (Abs(det) > 1.0e-9)
        {
            W := this.bufW, H := this.bufH
            minBx := "", minBy := "", maxBx := "", maxBy := ""
            for _, c in [[0, 0], [W, 0], [0, H], [W, H]]
            {
                sx := c[1] - p0x, sy := c[2] - p0y
                bx := (sx * vy - sy * vx) / det
                by := (ux * sy - uy * sx) / det
                if (minBx = "" || bx < minBx)
                    minBx := bx
                if (maxBx = "" || bx > maxBx)
                    maxBx := bx
                if (minBy = "" || by < minBy)
                    minBy := by
                if (maxBy = "" || by > maxBy)
                    maxBy := by
            }
            pad := 2
            bx0 := Max(0,    Floor(minBx) - pad)
            by0 := Max(0,    Floor(minBy) - pad)
            bx1 := Min(bmpW, Ceil(maxBx)  + pad)
            by1 := Min(bmpH, Ceil(maxBy)  + pad)
            if (bx1 <= bx0 || by1 <= by0)
                return   ; whole map off-screen this frame → nothing to draw
        }

        subW := bx1 - bx0
        subH := by1 - by0

        ; Destination parallelogram for the clipped sub-rect (source corners → screen).
        np0x := Round(p0x + bx0 * ux + by0 * vx), np0y := Round(p0y + bx0 * uy + by0 * vy)
        np1x := Round(p0x + bx1 * ux + by0 * vx), np1y := Round(p0y + bx1 * uy + by0 * vy)
        np2x := Round(p0x + bx0 * ux + by1 * vx), np2y := Round(p0y + bx0 * uy + by1 * vy)

        ; POINT array: 3 × (x, y) = 24 bytes
        pts := Buffer(24, 0)
        NumPut("Int", np0x, pts, 0),  NumPut("Int", np0y, pts, 4)
        NumPut("Int", np1x, pts, 8),  NumPut("Int", np1y, pts, 12)
        NumPut("Int", np2x, pts, 16), NumPut("Int", np2y, pts, 20)

        DllCall("PlgBlt",
            "Ptr", this.memDC,
            "Ptr", pts,
            "Ptr", srcDC,
            "Int", bx0, "Int", by0,
            "Int", subW,
            "Int", subH,
            "Ptr", mask,
            "Int", bx0, "Int", by0)
    }

    ; Hide() and SetAlpha() are inherited from GdiOverlayBase.

    ; Destructor: hide, release the maphack bitmap pair, then let the base free the
    ; cached pens/brushes and the back-buffer.
    __Delete()
    {
        this.Hide()
        this._DestroyMapHackBitmap()
        super.__Delete()
    }
}
