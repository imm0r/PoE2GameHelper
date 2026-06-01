; RadarOverlay.ahk
; Transparentes, click-through Overlay — zeichnet Entity-Dots auf Mini- und Großkarte.
;
; ── Koordinatentransformation (portiert von Radar.cs / GameHelper2) ────────────────────
;   Kamerawinkel: 38.7°
;   Projektionsformel:
;     mapScale   = 240 / zoom  (Großkarte: zoom *= LARGE_MAP_ZOOM_FACTOR = 0.1738)
;     projCos    = mapDiagonal * cos(38.7°) / mapScale
;     projSin    = mapDiagonal * sin(38.7°) / mapScale
;     gridDelta  = (worldPosition - playerWorldPosition) / WORLD_TO_GRID_RATIO
;     screenDelta.x = (gridDelta.x - gridDelta.y) * projCos
;     screenDelta.y = (gridDelta.z - gridDelta.x - gridDelta.y) * projSin
;     dotScreenPos  = mapCenter + screenDelta
;
; ── UI-Positionsberechnung (portiert von UiElement.cs / GameHelper2) ──────────────────
;   GetUnscaledPosition(): Laufe die Parent-Chain hoch, akkumuliere relativePosition.
;   Finales Ergebnis: unscaledPos * GameWindowScale(scaleIndex, localMultiplier)
;     Referenzauflösung des Spiels: 2560×1600
;     scaleFactorX = windowWidth  / 2560
;     scaleFactorY = windowHeight / 1600
;     scaleIndex 1 → uiScaleX = localMult * scaleFactorX, uiScaleY = localMult * scaleFactorX
;     scaleIndex 2 → uiScaleX = localMult * scaleFactorY, uiScaleY = localMult * scaleFactorY
;     scaleIndex 3 → uiScaleX = localMult * scaleFactorX, uiScaleY = localMult * scaleFactorY  (Standard für UI)
;
; ── Kartentypen ───────────────────────────────────────────────────────────────────────
;   MiniMap:   gespeicherte Position = LINKS OBEN  → Mitte = pos + size/2 + defaultShift + shift
;   Großkarte: gespeicherte Position = KARTENMITTE → Mitte = pos + defaultShift + shift
;              mapDiagonal = sqrt(windowWidth² + windowHeight²)  (rawsz=0 → Fenster als Äquivalent)

class RadarOverlay
{
    ; Transparenzfarbe: fast Schwarz (0x000000 wird von manchen Systemen ignoriert)
    static TRANSPARENT_BACKGROUND := 0x010101

    ; Kamerawinkel-Konstanten für 38.7°
    static CAMERA_COS := 0.78094   ; cos(38.7° in Radiant)
    static CAMERA_SIN := 0.62470   ; sin(38.7° in Radiant)

    ; Zoom-Korrekturfaktor für die Großkarte (aus RadarSettings.cs, default = 0.1738)
    static LARGE_MAP_ZOOM_FACTOR := 0.1738

    ; Umrechnungsfaktor WorldPosition → GridPosition (aus Radar.cs: ratio = 10.86957)
    static WORLD_TO_GRID_RATIO := 10.86957

    ; Dot-Farben (GDI erwartet BGR, nicht RGB)
    static COLOR_ENEMY_NORMAL := 0x0000FF   ; rot   (normale Gegner)
    static COLOR_ENEMY_RARE   := 0xFF00FF   ; magenta (seltene Gegner)
    static COLOR_ENEMY_BOSS   := 0x00FFFF   ; gelb  (Unique/Boss)
    static COLOR_MINION       := 0x0080FF   ; orange (eigene Minions)
    static COLOR_NPC          := 0x00FF80   ; grün
    static COLOR_CHEST        := 0xFFFF00   ; cyan  (Chests/Strongboxes)
    static COLOR_PLAYER       := 0xFFFFFF   ; weiß

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
        this.overlayGui      := Gui("-Caption +AlwaysOnTop -DPIScale +E0x80000")
        this.overlayGui.BackColor := "010101"
        this.windowHandle    := this.overlayGui.Hwnd
        this.memoryDC        := 0
        this.backBitmap      := 0
        this.bufferWidth     := 0
        this.bufferHeight    := 0
        this.isVisible            := false
        this.stylesApplied        := false
        this._alpha               := 255     ; overlay opacity (0-255), set via SetAlpha()
        this.highlightedEntityPath := ""   ; path of entity selected in the Entities tab — drawn with a line on the radar
        this._lastMiniMapDiagonal := 0   ; cached minimap diagonal used for large-map projection
        this._lastGwX := -1, this._lastGwY := -1, this._lastGwW := 0, this._lastGwH := 0
        this._penCache   := Map()   ; colorBGR|(width<<24) → HPEN  (created once, reused)
        this._brushCache := Map()   ; colorBGR             → HBRUSH
        this._bgBrush    := 0       ; cached background fill brush
        this._frameRect  := Buffer(16, 0)  ; reused RECT for FillRect

        ; Entity-Gruppen-Filter (alle standardmäßig sichtbar)
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

        ; ── Batch-Draw Queues ────────────────────────────────────────────────────────────
        ; Draw-Calls werden gesammelt und am Ende des Frames in einem einzigen Batch
        ; ausgeführt — reduziert Kernel-Mode-Switches um 80–95 %.
        ;   Key-Encoding für _dotBatch / _dotTopBatch:  colorBGR | (radius << 24)
        ;   Key-Encoding für _lineBatch:                colorBGR | (width  << 24)
        this._dotBatch    := Map()   ; normale Entity-Dots (alle Farb-Gruppen)
        this._dotTopBatch := Map()   ; Highlight-Dot — wird nach _dotBatch gerendert (on top)
        this._lineBatch   := Map()   ; Liniensegmente: je Farb-/Breiten-Gruppe ein Array
        this._textBatch   := []      ; Text-Einträge: [x, y, text, colorBGR]
    }

    ; Main render entry point: aligns the overlay window, clears the back-buffer, and draws all map layers.
    ; Params: snapshot - full game state snapshot; gameWindow* - screen position and size of the PoE window.
    ; Hauptmethode — wird bei jedem Snapshot-Update aufgerufen.
    ; gameWindowX/Y/Width/Height: Position und Größe des PoE-Fensters in Bildschirmkoordinaten.
    Render(snapshot, gameWindowX, gameWindowY, gameWindowWidth, gameWindowHeight)
    {
        if (gameWindowWidth < 100 || gameWindowHeight < 100)
            return

        ; Overlay-Fenster auf das Spielfenster ausrichten — nur wenn sich Position/Größe geändert hat
        if (gameWindowX != this._lastGwX || gameWindowY != this._lastGwY
         || gameWindowWidth != this._lastGwW || gameWindowHeight != this._lastGwH)
        {
            WinMove(gameWindowX, gameWindowY, gameWindowWidth, gameWindowHeight, this.windowHandle)
            this._lastGwX := gameWindowX, this._lastGwY := gameWindowY
            this._lastGwW := gameWindowWidth, this._lastGwH := gameWindowHeight
        }
        if !this.isVisible
        {
            this.overlayGui.Show("x" gameWindowX " y" gameWindowY " w" gameWindowWidth " h" gameWindowHeight " NoActivate")
            this.isVisible := true
            if !this.stylesApplied
            {
                WinSetTransColor("010101 " this._alpha, this.windowHandle)
                WinSetExStyle("+0x20", this.windowHandle)   ; WS_EX_TRANSPARENT → click-through
                this.stylesApplied := true
            }
        }

        if (this.bufferWidth != gameWindowWidth || this.bufferHeight != gameWindowHeight)
            this._InitBuffers(gameWindowWidth, gameWindowHeight)
        if !this.memoryDC
            return

        ; Clear back-buffer with transparency colour (brush created once and cached)
        if !this._bgBrush
            this._bgBrush := DllCall("CreateSolidBrush", "UInt", RadarOverlay.TRANSPARENT_BACKGROUND, "Ptr")
        NumPut("Int", gameWindowWidth,  this._frameRect, 8)
        NumPut("Int", gameWindowHeight, this._frameRect, 12)
        DllCall("FillRect", "Ptr", this.memoryDC, "Ptr", this._frameRect, "Ptr", this._bgBrush)

        ; Daten aus dem Snapshot extrahieren
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

        if !hasPlayerPosition
        {
            this._DrawDot(20, 8, 0x0000FF, 5)   ; blauer Punkt = kein Spieler gefunden
            this._BlitWithHighlight(gameWindowWidth, gameWindowHeight)
            return
        }

        playerWorldPosition := playerRender["worldPosition"]
        playerWorldX        := playerWorldPosition["x"]
        playerWorldY        := playerWorldPosition["y"]
        playerTerrainHeight := playerRender.Has("terrainHeight") ? playerRender["terrainHeight"] : 0.0

        ; Minimap-Diagonale auch dann cachen, wenn die Minimap gerade unsichtbar ist
        ; (die Großkarte braucht sie, ist aber oft offen wenn Minimap verdeckt ist).
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
                this._DrawDot(40, 8, 0x00FF00, 4)   ; grüner Punkt = MiniMap-Fehler
        }

        if (largeMapData && largeMapData["isVisible"])
        {
            try this._RenderMapLayer(largeMapData, playerWorldX, playerWorldY, playerTerrainHeight,
                                     areaInstance, gameWindowWidth, gameWindowHeight, true)
            catch
                this._DrawDot(56, 8, 0x00FFFF, 4)   ; cyaner Punkt = Großkarten-Fehler
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

        this._BlitWithHighlight(gameWindowWidth, gameWindowHeight)
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
        global g_exploreCurrentPercent, g_exploreLastReason
        global g_autoFlaskEnabled, g_autoFlaskLastReason

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
                lines.Push(["  explore: " pctTxt rsn, COL_IVORY])
            }
        }

        if (g_autoFlaskEnabled && g_autoFlaskLastReason != "" && g_autoFlaskLastReason != "idle")
            lines.Push(["FLASK  " g_autoFlaskLastReason, COL_GOLD])

        ; Queue the text lines into the existing batch — flushes in
        ; _FlushBatch (called from _BlitWithHighlight) so the lines land
        ; on top of the radar / entity dots already rendered.
        y := baseY
        for _, ln in lines
        {
            this._DrawText(baseX, y, ln[1], ln[2])
            y += linePitch
        }
    }

    ; Draws UI Browser highlight (if active) then blits the back-buffer to screen.
    ; Called instead of _Blit so the highlight is always the topmost drawn layer.
    ; _FlushBatch() is called here — this is the single flush point per frame.
    _BlitWithHighlight(gameWindowWidth, gameWindowHeight)
    {
        ; Flush all queued draw operations before the optional highlight rect and blit.
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
        this._Blit(gameWindowWidth, gameWindowHeight)
    }

    ; Renders entity dots onto one map layer using isometric projection and the game's UI scale math.
    ; Params: isLargeMap - switches between large-map center/window-diagonal vs. mini-map top-left formulas.
    ; Zeichnet Entities auf eine Kartenschicht (Mini- oder Großkarte).
    _RenderMapLayer(mapData, playerWorldX, playerWorldY, playerTerrainHeight,
                    areaInstance, gameWindowWidth, gameWindowHeight, isLargeMap)
    {
        ; ── UI-Skalierung berechnen (nach GameWindowScale.cs) ────────────────────────────
        ; Das Spiel nutzt 2560×1600 als Design-Referenzauflösung für alle UI-Positionen.
        ; scaleFactorX/Y rechnen unscaled UI-Koordinaten in echte Pixelkoordinaten um.
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

        ; ── Kartenposition auf dem Bildschirm ────────────────────────────────────────────
        ; MiniMap: unscaledPos = LINKS OBEN → mapCenter = pos + size/2 + shifts
        ; LargeMap: Die Position-Traversal liefert bereits den Kartenmittelpunkt (der Großkarte
        ;           ist im UI-Baum relativ zum Bildschirmmittelpunkt positioniert → kein +size/2)
        mapElementScreenX := mapData["unscaledPosX"] * uiScaleX
        mapElementScreenY := mapData["unscaledPosY"] * uiScaleY

        ; ── Kartengröße und Mittelpunkt auf dem Bildschirm ───────────────────────────────
        mapScreenWidth  := mapData["sizeW"] * uiScaleX
        mapScreenHeight := mapData["sizeH"] * uiScaleY

        if isLargeMap
        {
            ; Großkarte: Position-Traversal gibt Mittelpunkt → nur Shifts hinzuaddieren.
            ; Die gespeicherte Elementgröße ist oft 0 → Fenstergröße als Displayfallback.
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
            ; MiniMap: Position ist Links-Oben → Mittelpunkt = pos + size/2 + shifts.
            mapCenterX := mapElementScreenX + mapScreenWidth  / 2 + mapData["defaultShiftX"] + mapData["shiftX"]
            mapCenterY := mapElementScreenY + mapScreenHeight / 2 + mapData["defaultShiftY"] + mapData["shiftY"]
        }

        if (mapCenterX < -mapScreenWidth  || mapCenterX > gameWindowWidth  + mapScreenWidth
         || mapCenterY < -mapScreenHeight || mapCenterY > gameWindowHeight + mapScreenHeight)
            return

        ; ── Diagonale für Projektionsskalierung ──────────────────────────────────────────
        ; MiniMap: Diagonale des tatsächlichen Kartenelements.
        ; LargeMap: UnscaledSize=0 im Speicher → Minimap-Diagonale verwenden (gecacht in Render()).
        ;           Wird ohne LARGE_MAP_ZOOM_FACTOR kombiniert, weil dieser Faktor die
        ;           Fensterdiagonale auf Minimap-Diagonale herunterskaliert — bei direkter
        ;           Nutzung der Minimap-Diagonale wird er nicht mehr benötigt.
        if isLargeMap
            mapDiagonal := (this._lastMiniMapDiagonal > 0)
                ? this._lastMiniMapDiagonal
                : Sqrt(gameWindowWidth * gameWindowWidth + gameWindowHeight * gameWindowHeight)
        else
            mapDiagonal := Sqrt(mapScreenWidth * mapScreenWidth + mapScreenHeight * mapScreenHeight)

        ; ── Zoom-Wert für Radar-Projektion ───────────────────────────────────────────────
        ; LARGE_MAP_ZOOM_FACTOR ist NUR nötig wenn Fensterdiagonale verwendet wird.
        ; Mit Minimap-Diagonale direkt → rohen Zoom-Wert verwenden (kein Faktor).
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

        ; ── Projektionsfaktoren für Radar-Koordinatentransformation ──────────────────────
        baseMapScale := 240.0 / mapZoom
        projectionCos := mapDiagonal * RadarOverlay.CAMERA_COS / baseMapScale
        projectionSin := mapDiagonal * RadarOverlay.CAMERA_SIN / baseMapScale

        ; ── Maphack: draw walkable terrain border overlay (large map only, before entities) ──
        if (isLargeMap && this._mapHackEnabled)
            this._RenderMapHack(mapCenterX, mapCenterY, playerWorldX, playerWorldY,
                projectionCos, projectionSin)

        ; Spieler-Dot in der Kartenmitte
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

        ; ── Entities zeichnen ────────────────────────────────────────────────────────────
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

                ; Path-Filter: nur Monster, Spielercharaktere, NPCs und Chests anzeigen.
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

                ; Welt-Delta → Grid-Delta umrechnen
                gridDeltaX := (entityWorldPos["x"] - playerWorldX)        / RadarOverlay.WORLD_TO_GRID_RATIO
                gridDeltaY := (entityWorldPos["y"] - playerWorldY)        / RadarOverlay.WORLD_TO_GRID_RATIO
                gridDeltaZ := (entityTerrainHeight - playerTerrainHeight) / RadarOverlay.WORLD_TO_GRID_RATIO

                ; Isometrische Radar-Projektion (Kamerawinkel 38.7°)
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

                ; Entity-Typ klassifizieren
                positionedComponent := decodedComponents.Has("positioned") ? decodedComponents["positioned"] : 0
                isFriendly := positionedComponent && positionedComponent.Has("isFriendly") && positionedComponent["isFriendly"]

                isChest  := isChestPath
                isMinion := isMonster && isFriendly
                isNpc    := isNpcPath || isCharacter || (isFriendly && !isMonster)
                isEnemy  := !isFriendly && !isChest && !isAreaTransition && !isWaypoint && !isCheckpoint

                ; Rarity aus Mods/ObjectMagicProperties (0=Normal,1=Magic,2=Rare,3=Unique/Boss)
                rarityId := decodedComponents.Has("rarityId") ? decodedComponents["rarityId"] : 0
                isEnemyBoss   := isEnemy && (rarityId = 3)           ; Unique — Bosse
                isEnemyRare   := isEnemy && (rarityId = 2)           ; Rare
                isEnemyNormal := isEnemy && !isEnemyBoss && !isEnemyRare

                ; Entity-Gruppen-Filter anwenden
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

                ; Dot-Farbe nach Entity-Typ
                dotColor := isAreaTransition ? RadarOverlay.COLOR_AREATRANSITION
                          : isWaypoint       ? RadarOverlay.COLOR_WAYPOINT
                          : isCheckpoint     ? RadarOverlay.COLOR_CHECKPOINT
                          : isChest          ? RadarOverlay.COLOR_CHEST
                          : isMinion         ? RadarOverlay.COLOR_MINION
                          : isNpc            ? RadarOverlay.COLOR_NPC
                          : isEnemyBoss      ? RadarOverlay.COLOR_ENEMY_BOSS
                          : isEnemyRare      ? RadarOverlay.COLOR_ENEMY_RARE
                          :                    RadarOverlay.COLOR_ENEMY_NORMAL

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
            ; Polyline: baut POINT-Buffer einmalig → 1 Syscall statt 4×n Syscalls.
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
                oldPen := DllCall("SelectObject", "Ptr", this.memoryDC, "Ptr", pen, "Ptr")
                DllCall("Polyline", "Ptr", this.memoryDC, "Ptr", pathPts, "Int", n)
                DllCall("SelectObject", "Ptr", this.memoryDC, "Ptr", oldPen)
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
        ; Polyline: 1 Syscall für den gesamten Pfad statt 4×n Syscalls.
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
            oldPen := DllCall("SelectObject", "Ptr", this.memoryDC, "Ptr", pen, "Ptr")
            DllCall("Polyline", "Ptr", this.memoryDC, "Ptr", navPts, "Int", n)
            DllCall("SelectObject", "Ptr", this.memoryDC, "Ptr", oldPen)
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
            oldPen := DllCall("SelectObject", "Ptr", this.memoryDC, "Ptr", pen, "Ptr")
            DllCall("Polyline", "Ptr", this.memoryDC, "Ptr", combatPts, "Int", cn)
            DllCall("SelectObject", "Ptr", this.memoryDC, "Ptr", oldPen)
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

    ; ── GDI Zeichen-Helfer ───────────────────────────────────────────────────────────────

    ; Returns a cached HPEN for (colorBGR, width). Creates on first use, never deleted until __Delete.
    _GetPen(colorBGR, width := 1)
    {
        key := colorBGR | (width << 24)
        if !this._penCache.Has(key)
            this._penCache[key] := DllCall("CreatePen", "Int", 0, "Int", width, "UInt", colorBGR, "Ptr")
        return this._penCache[key]
    }

    ; Returns a cached HBRUSH for colorBGR. Creates on first use, never deleted until __Delete.
    _GetBrush(colorBGR)
    {
        if !this._brushCache.Has(colorBGR)
            this._brushCache[colorBGR] := DllCall("CreateSolidBrush", "UInt", colorBGR, "Ptr")
        return this._brushCache[colorBGR]
    }

    ; ── Batch-Collector-Methoden ─────────────────────────────────────────────────────────
    ; Diese Methoden zeichnen NICHT sofort — sie sammeln Draw-Operationen im RAM.
    ; _FlushBatch() führt alle gesammelten Ops in einem Batch aus (einmal pro Frame).

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

    ; ── Batch-Flush ──────────────────────────────────────────────────────────────────────
    ; Renders all queued draw operations in one pass — called once per frame before _Blit().
    ;
    ; Flush-Reihenfolge (korrekte Layering):
    ;   1. Linien      — liegen unter Dots
    ;   2. Normale Dots (entity-Dots, Player-Dot, Zone-Scan-Dots)
    ;   3. Top-Dot     — Highlight-Entity immer on top
    ;   4. Text        — Labels immer ganz oben
    ;
    ; Dot-Batch-Technik: BeginPath → n×Ellipse → EndPath → StrokeAndFillPath
    ;   → 2 SelectObject + 1 BeginPath + n×Ellipse + 1 EndPath + 1 StrokeAndFillPath
    ;   statt 5 DllCalls × n pro Farb-Gruppe.
    ;
    ; Linien-Technik: PolyPolyline mit n×2-Punkt-Segmenten
    ;   → 1 SelectObject + 1 PolyPolyline statt 4 DllCalls × n.
    _FlushBatch()
    {
        dc := this.memoryDC

        ; ── 1. Linien ────────────────────────────────────────────────────────────────────
        for key, segs in this._lineBatch
        {
            n := segs.Length
            if !n
                continue
            color  := key & 0xFFFFFF
            width  := (key >> 24) & 0xFF
            pen    := this._GetPen(color, width)
            oldPen := DllCall("SelectObject", "Ptr", dc, "Ptr", pen, "Ptr")

            ; PolyPolyline: alle Segmente als 2-Punkt-Polylines in einem Syscall
            pts    := Buffer(n * 16, 0)    ; n Segmente × 2 POINTs × 8 Byte
            counts := Buffer(n * 4,  0)    ; n DWORD-Counts à 2
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

        ; ── 2. + 3. Dots (normal, dann top) ─────────────────────────────────────────────
        this._FlushDotLayer(this._dotBatch)
        this._dotBatch.Clear()
        this._FlushDotLayer(this._dotTopBatch)
        this._dotTopBatch.Clear()

        ; ── 4. Text ──────────────────────────────────────────────────────────────────────
        ; SetBkMode einmal pro Frame — alle TextOut-Calls profitieren davon
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
        dc := this.memoryDC
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
    ; Not batched — called at most once per frame (UI-Browser highlight).
    _DrawRect(screenX, screenY, width, height, colorBGR, penWidth := 1)
    {
        pen       := this._GetPen(colorBGR, penWidth)
        nullBrush := DllCall("GetStockObject", "Int", 5, "Ptr")   ; NULL_BRUSH
        oldPen    := DllCall("SelectObject", "Ptr", this.memoryDC, "Ptr", pen,       "Ptr")
        oldBrush  := DllCall("SelectObject", "Ptr", this.memoryDC, "Ptr", nullBrush, "Ptr")
        DllCall("Rectangle", "Ptr", this.memoryDC,
                "Int", screenX, "Int", screenY, "Int", screenX + width, "Int", screenY + height)
        DllCall("SelectObject", "Ptr", this.memoryDC, "Ptr", oldPen)
        DllCall("SelectObject", "Ptr", this.memoryDC, "Ptr", oldBrush)
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
        oldPen := DllCall("SelectObject", "Ptr", this.memoryDC, "Ptr", pen, "Ptr")
        DllCall("Polyline", "Ptr", this.memoryDC, "Ptr", pts, "Int", n)
        DllCall("SelectObject", "Ptr", this.memoryDC, "Ptr", oldPen)

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
                this._DrawPixelCircle(cx - this._lastGwX, cy - this._lastGwY,
                    rec["circleCursorPx"], COL_CUR)
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
        oldPen := DllCall("SelectObject", "Ptr", this.memoryDC, "Ptr", pen, "Ptr")
        DllCall("Polyline", "Ptr", this.memoryDC, "Ptr", pts, "Int", n)
        DllCall("SelectObject", "Ptr", this.memoryDC, "Ptr", oldPen)
    }

    ; ── Interne Buffer-Verwaltung ────────────────────────────────────────────────────────

    ; Creates (or re-creates) the compatible memory DC and DIB bitmap used for off-screen rendering.
    _InitBuffers(width, height)
    {
        if this.backBitmap
        {
            stockBitmap := DllCall("GetStockObject", "Int", 0, "Ptr")
            DllCall("SelectObject", "Ptr", this.memoryDC, "Ptr", stockBitmap)
            DllCall("DeleteObject", "Ptr", this.backBitmap)
            DllCall("DeleteDC",     "Ptr", this.memoryDC)
        }
        screenDC          := DllCall("GetDC", "Ptr", this.windowHandle, "Ptr")
        this.memoryDC     := DllCall("CreateCompatibleDC",     "Ptr", screenDC,              "Ptr")
        this.backBitmap   := DllCall("CreateCompatibleBitmap", "Ptr", screenDC, "Int", width, "Int", height, "Ptr")
        DllCall("SelectObject", "Ptr", this.memoryDC, "Ptr", this.backBitmap)
        DllCall("ReleaseDC", "Ptr", this.windowHandle, "Ptr", screenDC)
        this.bufferWidth  := width
        this.bufferHeight := height
    }

    ; Copies the completed back-buffer to the overlay window's screen DC for flicker-free display.
    _Blit(width, height)
    {
        screenDC := DllCall("GetDC", "Ptr", this.windowHandle, "Ptr")
        DllCall("BitBlt", "Ptr", screenDC,
                "Int", 0, "Int", 0, "Int", width, "Int", height,
                "Ptr", this.memoryDC, "Int", 0, "Int", 0, "UInt", 0x00CC0020)   ; SRCCOPY
        DllCall("ReleaseDC", "Ptr", this.windowHandle, "Ptr", screenDC)
    }

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
            "Ptr", this.memoryDC,
            "Ptr", pts,
            "Ptr", this._mapHackDC,
            "Int", 0, "Int", 0,
            "Int", this._mapHackW,
            "Int", this._mapHackH,
            "Ptr", this._mapHackMask,
            "Int", 0, "Int", 0)
    }

    ; Hides the overlay GUI window and resets the visibility flag.
    Hide()
    {
        if this.isVisible
        {
            this.overlayGui.Hide()
            this.isVisible := false
        }
    }

    ; Sets the opacity of all drawn content (0=invisible, 255=fully opaque).
    ; Combined with the color-key so background stays fully transparent.
    SetAlpha(alpha)
    {
        this._alpha := alpha
        if this.windowHandle
            WinSetTransColor("010101 " alpha, this.windowHandle)
    }

    ; Destructor: hides the overlay and releases all GDI objects (cached pens/brushes + back-buffer).
    __Delete()
    {
        this.Hide()
        this._DestroyMapHackBitmap()
        for _, pen in this._penCache
            DllCall("DeleteObject", "Ptr", pen)
        for _, brush in this._brushCache
            DllCall("DeleteObject", "Ptr", brush)
        if this._bgBrush
            DllCall("DeleteObject", "Ptr", this._bgBrush)
        if this.backBitmap
            DllCall("DeleteObject", "Ptr", this.backBitmap)
        if this.memoryDC
            DllCall("DeleteDC", "Ptr", this.memoryDC)
    }
}
