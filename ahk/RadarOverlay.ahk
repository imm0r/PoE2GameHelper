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
        global g_radarAlpha, g_highlightedEntityPath

        this.ShowEnemyNormal := g_radarShowEnemyNormal
        this.ShowEnemyRare   := g_radarShowEnemyRare
        this.ShowEnemyBoss   := g_radarShowEnemyBoss
        this.ShowMinions     := g_radarShowMinions
        this.ShowNpcs        := g_radarShowNpcs
        this.ShowChests      := g_radarShowChests
        this.DebugMode       := g_debugMode
        this._navEnabled     := g_zoneNavEnabled
        this._mapHackEnabled := g_mapHackEnabled
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
        return ctx.gate["allowed"] && (IsSet(g_radarEnabled) ? g_radarEnabled : true)
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
                this._GenerateMapHackBitmap()
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
            this._RenderStatusOverlay(gameWindowWidth, gameWindowHeight)   ; status block "shows always"
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

        if (miniMapData && miniMapData["isVisible"])
        {
            try this._RenderMapLayer(miniMapData, playerWorldX, playerWorldY, playerTerrainHeight,
                                     areaInstance, gameWindowWidth, gameWindowHeight, false)
            catch
                this._DrawDot(40, 8, 0x00FF00, 4)   ; green dot = MiniMap error
        }

        if (largeMapData && largeMapData["isVisible"])
        {
            try this._RenderMapLayer(largeMapData, playerWorldX, playerWorldY, playerTerrainHeight,
                                     areaInstance, gameWindowWidth, gameWindowHeight, true)
            catch
                this._DrawDot(56, 8, 0x00FFFF, 4)   ; cyan dot = large-map error
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

        ; Status text block — automation summary drawn on the game overlay.
        ; Off when g_overlayStatusTextEnabled is false; user-toggleable
        ; from Config > Radar > "Status Text on Overlay".
        this._RenderStatusOverlay(gameWindowWidth, gameWindowHeight)

        this._FinishFrame(gameWindowWidth, gameWindowHeight)
    }

    ; ── Status overlay ────────────────────────────────────────────────────
    ; Draws a compact codex-styled block of automation status lines onto
    ; the game overlay. Shows the AutoPilot summary always, plus contextual
    ; sub-lines for whichever sub-routine is currently active (combat /
    ; loot / explore). User can toggle off via Config > Radar > "Status
    ; Text on Overlay".
    ;
    ; Position: bottom-left of the game viewport, just above the skill bar,
    ; clear of the life globe and the radar minimap. Colour palette in BGR
    ; matches the codex WebView theme: gold for labels, ivory for values,
    ; blood-red for combat, dim brass for inactive states.
    _RenderStatusOverlay(gameWindowWidth, gameWindowHeight)
    {
        global g_overlayStatusTextEnabled
        global g_autoPilotEnabled, g_autoPilotState, g_autoPilotReason
        global g_combatState, g_combatLastReason
        global g_lootLastReason, g_lootCache
        global g_exploreCurrentPercent, g_exploreLastReason, g_exploreHeightDiag
        global g_exploreRegionDiag
        global g_autoFlaskEnabled, g_autoFlaskLastReason
        global POEFORMANCE_VERSION

        if !g_overlayStatusTextEnabled
            return
        if (gameWindowWidth < 200 || gameWindowHeight < 200)
            return

        ; ── Layout ──────────────────────────────────────────────────────
        ; Anchor at ~14% from left (just past bottom-left life globe) and
        ; ~62% from top (well clear of bottom skill/flask bar at ~86%).
        baseX := Round(gameWindowWidth  * 0.14)
        baseY := Round(gameWindowHeight * 0.62)
        linePitch := 16

        ; Codex palette in BGR (the _DrawText helper takes BGR ints)
        COL_GOLD_HI := 0x8AD6F0   ; #f0d68a — primary gold for labels
        COL_GOLD    := 0x5AA8C8   ; #c8a85a — muted gold for value text
        COL_IVORY   := 0xB8DCE8   ; #e8dcb8 — main text colour
        COL_DIM     := 0x648A9C   ; #9c8a64 — dim text for "off" / sub-info
        COL_BLOOD   := 0x4848C5   ; #c54848 — blood red for combat warning
        COL_AMBER   := 0x43A0D4   ; #d4a043 — burnished bronze for active

        lines := []   ; each entry: [text, colorBGR]

        ; Line 1: AutoPilot master state
        if !g_autoPilotEnabled
        {
            lines.Push(["AUTOPILOT  OFF", COL_DIM])
        }
        else
        {
            stUp := StrUpper(g_autoPilotState)
            stCol := (g_autoPilotState = "combat") ? COL_BLOOD
                  : (g_autoPilotState = "explore" || g_autoPilotState = "loot") ? COL_AMBER
                  : COL_GOLD_HI
            lines.Push(["AUTOPILOT  " stUp, stCol])
            if (g_autoPilotReason && g_autoPilotReason != "" && g_autoPilotReason != "idle")
                lines.Push(["  " g_autoPilotReason, COL_IVORY])
        }

        ; Contextual sub-lines for the active automation
        if g_autoPilotEnabled
        {
            if (g_combatState = "combat" && g_combatLastReason != "" && g_combatLastReason != "idle")
                lines.Push(["  combat: " g_combatLastReason, COL_IVORY])

            cacheCount := (g_lootCache && Type(g_lootCache) = "Map") ? g_lootCache.Count : 0
            if (cacheCount > 0 || (g_autoPilotState = "loot"))
                lines.Push(["  loot: " g_lootLastReason " · " cacheCount " cached", COL_IVORY])

            if (g_autoPilotState = "explore" || g_exploreCurrentPercent > 0)
            {
                pctTxt := Format("{:.0f}%", g_exploreCurrentPercent)
                rsn := (g_exploreLastReason != "" && g_exploreLastReason != "idle")
                    ? (" · " g_exploreLastReason) : ""
                hz := (IsSet(g_exploreHeightDiag) && g_exploreHeightDiag != "")
                    ? (" · hz:" g_exploreHeightDiag) : ""
                rg := (IsSet(g_exploreRegionDiag) && g_exploreRegionDiag != "")
                    ? (" · rg:" g_exploreRegionDiag) : ""
                lines.Push(["  explore: " pctTxt rsn hz rg, COL_IVORY])
            }
        }

        if (g_autoFlaskEnabled && g_autoFlaskLastReason != "" && g_autoFlaskLastReason != "idle")
            lines.Push(["FLASK  " g_autoFlaskLastReason, COL_GOLD])

        ; Build identifier — lets a screenshot/video of the overlay prove
        ; which version is actually running (pull-without-restart happens).
        lines.Push(["v" POEFORMANCE_VERSION, COL_DIM])

        ; Queue the text lines into the existing batch — flushes in
        ; _FlushBatch (called from _FinishFrame) so the lines land
        ; on top of the radar / entity dots already rendered.
        y := baseY
        for _, ln in lines
        {
            this._DrawText(baseX, y, ln[1], ln[2])
            y += linePitch
        }
    }

    ; Finishes the frame on the back-buffer: atlas overlay, flush of all queued
    ; draw ops, then the optional UI-Browser highlight rect (topmost layer).
    ; GdiOverlayBase.Update() performs the actual blit right after Draw() returns,
    ; so this no longer blits itself — it is the single flush point per frame.
    _FinishFrame(gameWindowWidth, gameWindowHeight)
    {
        ; Atlas overlay (dormant until g_atlasRender is populated by the reader).
        this._RenderAtlas()
        ; Flush all queued draw operations before the optional highlight rect.
        this._FlushBatch()

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

        ; ── Maphack: draw walkable terrain border overlay (large map only, before entities) ──
        if (isLargeMap && this._mapHackEnabled)
            this._RenderMapHack(mapCenterX, mapCenterY, playerWorldX, playerWorldY,
                projectionCos, projectionSin)

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

        ; ── Hotkey action debug (per-action debug flag in the Hotkeys tab) ──
        this._RenderHotkeyDebug(mapCenterX, mapCenterY, projectionCos, projectionSin,
            gameWindowWidth, gameWindowHeight)

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

    ; Renders per-action debug overlays for hotkey actions whose debug flag is on.
    ; Reads g_hkDebugItems (built each tick by the hotkey engine) and draws, per
    ; item: a world range circle (around the player) or a cursor pixel circle,
    ; plus a stacked text block (label + monster counts / cooldown / charges).
    _RenderHotkeyDebug(mapCenterX, mapCenterY, projectionCos, projectionSin, gw, gh)
    {
        global g_hkDebugItems
        if !(IsSet(g_hkDebugItems) && g_hkDebugItems is Array && g_hkDebugItems.Length)
            return

        COL := 0x55FFFF        ; debug yellow (BGR)
        COL_CUR := 0xC0A8FF    ; cursor circle (pinkish)
        textX := Round(gw * 0.55)
        textY := Round(gh * 0.30)
        pitch := 15

        for _, rec in g_hkDebugItems
        {
            if !(rec is Map)
                continue
            ; World range circle around the player.
            if (rec.Has("circleWorld") && rec["circleWorld"] > 0)
                this._DrawRangeCircle(rec["circleWorld"], mapCenterX, mapCenterY,
                    projectionCos, projectionSin, COL,
                    rec.Has("label") ? rec["label"] : "")
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
            ; Text block.
            this._DrawText(textX, textY, rec.Has("label") ? rec["label"] : "?", COL)
            textY += pitch
            if (rec.Has("lines") && rec["lines"] is Array)
            {
                for _, ln in rec["lines"]
                {
                    this._DrawText(textX + 10, textY, ln, 0xB8DCE8)
                    textY += pitch
                }
            }
            textY += 4
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

        this._mapHackDC    := hDC
        this._mapHackBmp   := hBmp
        this._mapHackMask  := hMask
        this._mapHackW     := bmpW
        this._mapHackH     := bmpH
        this._mapHackStep  := STEP
        this._mapHackGridW := bmpW * STEP
        this._mapHackGridH := bmpH * STEP
    }

    ; Frees all GDI resources used by the maphack bitmap.
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
    }

    ; Renders the maphack bitmap onto the back-buffer using PlgBlt with isometric projection.
    ; Only border pixels (from the mask) are drawn; everything else is untouched.
    _RenderMapHack(mapCenterX, mapCenterY, playerWorldX, playerWorldY,
                   projectionCos, projectionSin)
    {
        if (!this._mapHackDC || !this._mapHackMask)
            return

        playerGX := playerWorldX / RadarOverlay.WORLD_TO_GRID_RATIO
        playerGY := playerWorldY / RadarOverlay.WORLD_TO_GRID_RATIO
        gridW := this._mapHackGridW
        gridH := this._mapHackGridH

        ; Compute 3 parallelogram destination points for PlgBlt.
        ; These map the bitmap's top-left, top-right, bottom-left to screen positions.
        ; Grid (gx,gy) → screen: sX = mcX + (dGX-dGY)*pCos, sY = mcY + (-dGX-dGY)*pSin

        ; Point 0: Grid (0, 0)
        dGX0 := -playerGX
        dGY0 := -playerGY
        p0x := Round(mapCenterX + (dGX0 - dGY0) * projectionCos)
        p0y := Round(mapCenterY + (-dGX0 - dGY0) * projectionSin)

        ; Point 1: Grid (gridW, 0)
        dGX1 := gridW - playerGX
        p1x := Round(mapCenterX + (dGX1 - dGY0) * projectionCos)
        p1y := Round(mapCenterY + (-dGX1 - dGY0) * projectionSin)

        ; Point 2: Grid (0, gridH)
        dGY2 := gridH - playerGY
        p2x := Round(mapCenterX + (dGX0 - dGY2) * projectionCos)
        p2y := Round(mapCenterY + (-dGX0 - dGY2) * projectionSin)

        ; POINT array: 3 × (x, y) = 24 bytes
        pts := Buffer(24, 0)
        NumPut("Int", p0x, pts, 0),  NumPut("Int", p0y, pts, 4)
        NumPut("Int", p1x, pts, 8),  NumPut("Int", p1y, pts, 12)
        NumPut("Int", p2x, pts, 16), NumPut("Int", p2y, pts, 20)

        DllCall("PlgBlt",
            "Ptr", this.memDC,
            "Ptr", pts,
            "Ptr", this._mapHackDC,
            "Int", 0, "Int", 0,
            "Int", this._mapHackW,
            "Int", this._mapHackH,
            "Ptr", this._mapHackMask,
            "Int", 0, "Int", 0)
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
