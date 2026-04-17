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
        ; Cached A* path: array of [gridX, gridY] absolute coordinates.
        this._pathGridCoords      := []
        ; Cache-invalidation keys for the path.
        this._pathHlEntity        := ""
        this._pathPlayerGX        := -999999
        this._pathPlayerGY        := -999999
        this._pathEntityGX        := -999999
        this._pathEntityGY        := -999999
        this._pathLastComputeTick := 0
        this._pathDebug           := ""   ; last failure reason from _FindPath
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
        this._navLastComputeTick  := 0
        this._navAreaHash         := 0xFFFFFFFF
        this._navEnabled          := true  ; toggle from config

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
        this._mapHackTerrainSz    := 0     ; terrain data size (for change detection)
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
            this._terrain := areaInstance["terrain"]
        terrainError := (areaInstance && areaInstance.Has("terrainError")) ? areaInstance["terrainError"] : ""

        ; Regenerate maphack bitmap when terrain data changes (new area loaded)
        if (this._terrain && this._terrain["dataSize"] != this._mapHackTerrainSz)
        {
            this._mapHackTerrainSz := this._terrain["dataSize"]
            this._GenerateMapHackBitmap()
        }

        hasPlayerPosition   := (playerRender && playerRender.Has("worldPosition"))
        awakeEntityCount    := (areaInstance && areaInstance.Has("awakeEntities") && areaInstance["awakeEntities"].Has("sampleCount"))
                               ? areaInstance["awakeEntities"]["sampleCount"] : "?"

        ; ── Status lines at bottom-center (debug only) ─────────────────────────────────
        dbgX := gameWindowWidth // 2 - 400
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
            this._DrawText(dbgX, gameWindowHeight - 80,
                "area:" (areaInstance?"OK":"NIL") " pr:" (hasPlayerPosition?"OK":"NIL") " ent:" awakeEntityCount
                " mm:" miniMapSize "[" miniMapVisible "]" " upos:" miniMapPos " lm:" largeMapSize "[" largeMapVisible "]"
                " " terrDbg,
                0x00FFFF)
            this._DrawDot(8, 8, 0xFFFFFF, 5)   ; weißer Punkt = Overlay läuft
        }

        if !hasPlayerPosition
        {
            this._DrawDot(20, 8, 0x0000FF, 5)   ; blauer Punkt = kein Spieler gefunden
            this._Blit(gameWindowWidth, gameWindowHeight)
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
                this._pathGridCoords      := this._FindPath(pGX, pGY, eGX, eGY)
                this._pathPlayerGX        := pGX
                this._pathPlayerGY        := pGY
                this._pathEntityGX        := eGX
                this._pathEntityGY        := eGY
                this._pathHlEntity        := this.highlightedEntityPath
                this._pathLastComputeTick := A_TickCount
            }
            ; Always show path status when entity is highlighted
            this._DrawText(dbgX, gameWindowHeight - 65,
                "path: pG=" pGX "," pGY " eG=" eGX "," eGY
                " pts=" this._pathGridCoords.Length
                " terrain=" (this._terrain ? "OK" : "NIL")
                " dbg=" this._pathDebug,
                0x00FF00)
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
                    this._navPathCoords      := this._FindPath(pGX, pGY, tGX, tGY)
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

        ; Debug: show zone scan status
        if (this.DebugMode)
        {
            if (zoneScanResults.Length > 0 || zoneScanDone)
            {
                atCount := 0
                for _, t in zoneScanResults
                    if (t["type"] = "AreaTransition")
                        atCount += 1
                this._DrawText(dbgX, gameWindowHeight - 95,
                    "nav: accum=" zoneScanResults.Length " AT=" atCount " path=" this._navPathCoords.Length
                    " initMs=" zoneScanMs,
                    0xFFD700)
            }
            else if (this._navEnabled)
            {
                this._DrawText(dbgX, gameWindowHeight - 95, "nav: scanning...", 0xFFD700)
            }
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

        ; ── DEBUG: Mittelpunkt und Info ──────────────────────────────────────────
        if this.DebugMode
        {
            debugColor := isLargeMap ? 0xFFFF00 : 0xFF8800
            this._DrawDot(Round(mapCenterX), Round(mapCenterY), debugColor, 15)
            debugTextRow := isLargeMap ? 32 : 16
            this._DrawText(4, debugTextRow,
                (isLargeMap?"L":"M") " ctr=" Round(mapCenterX) "," Round(mapCenterY)
                " spos=" Round(mapElementScreenX) "," Round(mapElementScreenY)
                " rawsz=" Round(mapData["sizeW"]) "x" Round(mapData["sizeH"])
                " sz=" Round(mapScreenWidth) "x" Round(mapScreenHeight)
                " si=" mapData["scaleIdx"] " dep=" mapData["chainDepth"] " z=" Round(mapZoom, 3),
                debugColor)
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

                ; Path-Filter: nur Monster, Spielercharaktere, NPCs und Chests anzeigen
                entityPathLower := entity.Has("path") ? StrLower(entity["path"]) : ""
                isMonster        := InStr(entityPathLower, "metadata/monsters/")
                isCharacter      := InStr(entityPathLower, "metadata/characters/")
                isNpcPath        := InStr(entityPathLower, "metadata/npc/")
                isChestPath      := InStr(entityPathLower, "/chests/") || InStr(entityPathLower, "strongbox")
                isAreaTransition := InStr(entityPathLower, "areatransition")
                isWaypoint       := InStr(entityPathLower, "waypoint")
                isCheckpoint     := InStr(entityPathLower, "checkpoint")
                isBossPath       := isMonster && (InStr(entityPathLower, "boss") || InStr(entityPathLower, "unique"))
                isImportantSleep := isAreaTransition || isWaypoint || isCheckpoint || isBossPath || isNpcPath

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
            pathCoords := this._pathGridCoords
            if (pathCoords.Length >= 2 && this._pathHlEntity = this.highlightedEntityPath)
            {
                prevSX := -1, prevSY := -1
                for _, pt in pathCoords
                {
                    dGX := pt[1] - playerGX
                    dGY := pt[2] - playerGY
                    pSX := Round(mapCenterX + (dGX - dGY) * projectionCos)
                    pSY := Round(mapCenterY + (0 - dGX - dGY) * projectionSin)
                    if (prevSX >= 0)
                        this._DrawLine(prevSX, prevSY, pSX, pSY, hlColor, lineWidth)
                    prevSX := pSX, prevSY := pSY
                }
            }
            else
                this._DrawLine(Round(mapCenterX), Round(mapCenterY), hlScreenX, hlScreenY, hlColor, lineWidth)

            hlRadius := isLargeMap ? 7 : 5
            this._DrawDot(hlScreenX, hlScreenY, hlColor, hlRadius)
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
        navCoords := this._navPathCoords
        if (this._navEnabled && navCoords.Length >= 2)
        {
            navColor  := 0x00D7FF   ; gold (BGR)
            navWidth  := isLargeMap ? 3 : 2
            playerGX  := playerWorldX / RadarOverlay.WORLD_TO_GRID_RATIO
            playerGY  := playerWorldY / RadarOverlay.WORLD_TO_GRID_RATIO
            prevSX := -1, prevSY := -1
            for _, pt in navCoords
            {
                dGX := pt[1] - playerGX
                dGY := pt[2] - playerGY
                pSX := Round(mapCenterX + (dGX - dGY) * projectionCos)
                pSY := Round(mapCenterY + (0 - dGX - dGY) * projectionSin)
                if (prevSX >= 0)
                    this._DrawLine(prevSX, prevSY, pSX, pSY, navColor, navWidth)
                prevSX := pSX, prevSY := pSY
            }
        }

        ; Debug-Statuszeile: zeigt wie viele Entities durch welchen Filter gefallen sind
        if this.DebugMode
        {
            debugColor := isLargeMap ? 0xFFFF00 : 0xFF8800
            dbgX2      := gameWindowWidth // 2 - 400
            this._DrawText(dbgX2, gameWindowHeight - 50,
                (isLargeMap?"L":"M") "-ent: tot=" statTotal " noD=" statNoDecoded " noR=" statNoRender
                " flt=" statFiltered " dead=" statDead " drawn=" statDrawn " p0=" firstEntityPath,
                debugColor)
            if fs
            {
                preFlt  := fs.Has("preFilter")  ? fs["preFilter"]  : "?"
                postFlt := fs.Has("postFilter") ? fs["postFilter"] : "?"
                this._DrawText(dbgX2, gameWindowHeight - 36,
                    "flt: s1=" fs["s1"] " s2=" fs["s2"] " s3=" fs["s3"] " s4=" fs["s4"]
                    " s5=" fs["s5"] " s6=" fs["s6"] " bl=" fs["bl"] " blTot=" fs["blTotal"]
                    " pre=" preFlt " post=" postFlt,
                    debugColor)
            }
        }
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

    ; Draws a text string at the given back-buffer coordinates using transparent background mode.
    _DrawText(screenX, screenY, text, colorBGR)
    {
        DllCall("SetTextColor", "Ptr", this.memoryDC, "UInt", colorBGR)
        DllCall("SetBkMode",    "Ptr", this.memoryDC, "Int", 1)   ; TRANSPARENT
        DllCall("TextOutW", "Ptr", this.memoryDC,
                "Int", screenX, "Int", screenY, "Str", text, "Int", StrLen(text))
    }

    ; Draws a straight line on the back-buffer between two screen coordinates.
    _DrawLine(x1, y1, x2, y2, colorBGR, penWidth := 1)
    {
        pen    := this._GetPen(colorBGR, penWidth)
        oldPen := DllCall("SelectObject", "Ptr", this.memoryDC, "Ptr", pen, "Ptr")
        DllCall("MoveToEx", "Ptr", this.memoryDC, "Int", x1, "Int", y1, "Ptr", 0)
        DllCall("LineTo",   "Ptr", this.memoryDC, "Int", x2, "Int", y2)
        DllCall("SelectObject", "Ptr", this.memoryDC, "Ptr", oldPen)
    }

    ; Draws a filled circle on the back-buffer at (centerX, centerY) with the given radius.
    _DrawDot(centerX, centerY, colorBGR, radius := 3)
    {
        pen      := this._GetPen(colorBGR)
        brush    := this._GetBrush(colorBGR)
        oldPen   := DllCall("SelectObject", "Ptr", this.memoryDC, "Ptr", pen,   "Ptr")
        oldBrush := DllCall("SelectObject", "Ptr", this.memoryDC, "Ptr", brush, "Ptr")
        DllCall("Ellipse", "Ptr", this.memoryDC,
                "Int", centerX - radius, "Int", centerY - radius,
                "Int", centerX + radius, "Int", centerY + radius)
        DllCall("SelectObject", "Ptr", this.memoryDC, "Ptr", oldPen)
        DllCall("SelectObject", "Ptr", this.memoryDC, "Ptr", oldBrush)
    }

    ; Draws a hollow rectangle outline on the back-buffer; uses NULL_BRUSH to avoid filling the interior.
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

    ; ── Terrain pathfinding ──────────────────────────────────────────────────────────────

    ; Returns true if grid cell (gx, gy) is walkable according to the packed nibble terrain data.
    _IsWalkable(gx, gy, buf, bpr, rows, dsz)
    {
        if (gx < 0 || gy < 0 || gy >= rows || gx >= bpr * 2)
            return false
        idx := gy * bpr + (gx >> 1)
        if (idx >= dsz)
            return false
        byt := NumGet(buf.Ptr, idx, "UChar")
        return ((byt >> ((gx & 1) * 4)) & 0xF) != 0
    }

    ; A* pathfinder on the walkable terrain grid.
    ; startGX/GY and endGX/GY are absolute grid coordinates.
    ; Operates on a step-2 coarse grid (4× smaller search space) for speed.
    ; Returns an Array of [gx, gy] pairs (player → entity), smoothed via line-of-sight culling.
    ; Returns [] on failure (no terrain, unwalkable endpoints, or time cap exceeded).
    _FindPath(startGX, startGY, endGX, endGY)
    {
        terrain := this._terrain
        if !(terrain && terrain.Has("data"))
        {
            this._pathDebug := "no-terrain"
            return []
        }

        buf  := terrain["data"]
        bpr  := terrain["bytesPerRow"]
        rows := terrain["totalRows"]
        dsz  := terrain["dataSize"]
        maxW := bpr * 2

        ; Clamp to grid bounds.
        startGX := Max(0, Min(startGX, maxW - 1))
        startGY := Max(0, Min(startGY, rows - 1))
        endGX   := Max(0, Min(endGX,   maxW - 1))
        endGY   := Max(0, Min(endGY,   rows - 1))

        ; Nudge start / end to nearest walkable cell (handles player/entity standing on a border).
        startGX := this._NudgeToWalkable(startGX, startGY, buf, bpr, rows, dsz, &startGY)
        endGX   := this._NudgeToWalkable(endGX,   endGY,   buf, bpr, rows, dsz, &endGY)
        if (startGX < 0 || endGX < 0)
        {
            this._pathDebug := "nudge-fail sW=" (startGX < 0 ? "0" : "1") " eW=" (endGX < 0 ? "0" : "1")
            return []
        }

        ; ── Coarse grid (STEP cells per logical unit) ─────────────────────────────────
        ; Reduces search space: STEP=2 for short, STEP=4 for medium, STEP=8 for very long paths.
        rawDist := Max(Abs(startGX - endGX), Abs(startGY - endGY))
        STEP := (rawDist > 500) ? 8 : (rawDist > 200) ? 4 : 2
        csX := startGX // STEP,   csY := startGY // STEP
        ceX := endGX   // STEP,   ceY := endGY   // STEP
        cmW := maxW    // STEP + 1
        cmH := rows    // STEP + 1

        STRIDE   := cmW + 1
        startKey := csY * STRIDE + csX
        endKey   := ceY * STRIDE + ceX

        ; Bounding box (in coarse coords) + padding to restrict expansion area.
        ; Bounding box: at least PAD_MIN coarse cells around the rect, scaled up for distance.
        dist  := Max(Abs(csX - ceX), Abs(csY - ceY))
        PAD   := Max(30, dist // 4)   ; grow with distance so far entities don't get clipped
        bMinX := Max(0,      Min(csX, ceX) - PAD)
        bMaxX := Min(cmW-1,  Max(csX, ceX) + PAD)
        bMinY := Max(0,      Min(csY, ceY) - PAD)
        bMaxY := Min(cmH-1,  Max(csY, ceY) + PAD)

        ; A* data structures (integer-keyed Maps avoid slow string hashing).
        gScore   := Map()
        cameFrom := Map()
        closed   := Map()
        gScore[startKey] := 0

        h0   := (Abs(csX - ceX) + Abs(csY - ceY)) * 10
        heap := [[h0, startKey]]

        ; 8-directional movement vectors and costs (×10 for integer arithmetic).
        static DX := [1, -1, 0, 0, 1, 1, -1, -1]
        static DY := [0, 0, 1, -1, 1, -1, 1, -1]
        static DC := [10, 10, 10, 10, 14, 14, 14, 14]

        ; Scale iteration budget with search area so far entities aren't cut off.
        searchArea := (bMaxX - bMinX + 1) * (bMaxY - bMinY + 1)
        MAX_ITER := Min(200000, Max(15000, searchArea))
        iter     := 0
        found    := false
        deadline := A_TickCount + ((rawDist > 400) ? 500 : 200)   ; extended budget for zone-wide paths

        while (heap.Length > 0 && iter < MAX_ITER && A_TickCount < deadline)
        {
            ; Heap pop.
            curItem  := heap[1]
            lastItem := heap.RemoveAt(heap.Length)
            if heap.Length > 0
            {
                heap[1] := lastItem
                this._HeapDown(heap, 1)
            }
            curKey := curItem[2]

            if closed.Has(curKey)
                continue
            closed[curKey] := true
            iter++

            if (curKey = endKey)
            {
                found := true
                break
            }

            cx := Mod(curKey, STRIDE)
            cy := (curKey - cx) // STRIDE
            curG := gScore[curKey]

            loop 8
            {
                ii := A_Index
                nx := cx + DX[ii]
                ny := cy + DY[ii]

                if (nx < bMinX || nx > bMaxX || ny < bMinY || ny > bMaxY)
                    continue
                ; Check walkability at actual grid coordinates.
                if !this._IsWalkable(nx * STEP, ny * STEP, buf, bpr, rows, dsz)
                    continue

                nKey := ny * STRIDE + nx
                if closed.Has(nKey)
                    continue

                tentG := curG + DC[ii]
                oldG  := gScore.Has(nKey) ? gScore[nKey] : 999999999

                if (tentG < oldG)
                {
                    gScore[nKey]   := tentG
                    cameFrom[nKey] := curKey
                    h := (Abs(nx - ceX) + Abs(ny - ceY)) * 10
                    heap.Push([tentG + h, nKey])
                    this._HeapUp(heap, heap.Length)
                }
            }
        }

        if !found
        {
            this._pathDebug := "astar-fail iter=" iter "/" MAX_ITER " heap=" heap.Length " rawD=" rawDist " STEP=" STEP " dist=" dist " PAD=" PAD
            return []
        }
        this._pathDebug := "ok iter=" iter "/" MAX_ITER " STEP=" STEP

        ; Reconstruct path (end → start) in actual grid coords, then reverse.
        path := []
        k    := endKey
        loop 20000
        {
            cx := Mod(k, STRIDE)
            cy := (k - cx) // STRIDE
            path.Push([cx * STEP, cy * STEP])
            if (k = startKey || !cameFrom.Has(k))
                break
            k := cameFrom[k]
        }

        n := path.Length
        loop n // 2
        {
            ii := A_Index, jj := n - ii + 1
            tmp := path[ii], path[ii] := path[jj], path[jj] := tmp
        }

        return this._SmoothPath(path, buf, bpr, rows, dsz)
    }

    ; Finds the nearest walkable cell within radius 5 of (gx, gy).
    ; Returns the walkable gx (and modifies gy via byref); returns -1 if none found.
    _NudgeToWalkable(gx, gy, buf, bpr, rows, dsz, &outGY)
    {
        if this._IsWalkable(gx, gy, buf, bpr, rows, dsz)
        {
            outGY := gy
            return gx
        }
        loop 5
        {
            r := A_Index
            loop r * 8
            {
                angle := (A_Index - 1) * (6.2831853 / (r * 8))
                nx := gx + Round(r * Cos(angle))
                ny := gy + Round(r * Sin(angle))
                if this._IsWalkable(nx, ny, buf, bpr, rows, dsz)
                {
                    outGY := ny
                    return nx
                }
            }
        }
        outGY := gy
        return -1
    }

    ; Reduces path waypoints by greedily skipping intermediate points with line-of-sight.
    _SmoothPath(path, buf, bpr, rows, dsz)
    {
        n := path.Length
        if (n <= 2)
            return path

        smoothed := [path[1]]
        i := 1
        while (i < n)
        {
            ; Find the furthest point reachable in a straight walkable line.
            best := i + 1
            loop Min(n - i, 25) - 1    ; look ahead up to 25 steps
            {
                j := i + A_Index + 1
                if this._HasLineOfSight(smoothed[smoothed.Length][1], smoothed[smoothed.Length][2],
                                        path[j][1], path[j][2], buf, bpr, rows, dsz)
                    best := j
            }
            i := best
            if (i <= n)
                smoothed.Push(path[i])
        }
        return smoothed
    }

    ; Bresenham line-of-sight check: returns true iff all cells on the line are walkable.
    _HasLineOfSight(x0, y0, x1, y1, buf, bpr, rows, dsz)
    {
        dx := Abs(x1 - x0), dy := Abs(y1 - y0)
        sx := (x0 < x1) ? 1 : -1
        sy := (y0 < y1) ? 1 : -1
        err := dx - dy
        x := x0, y := y0
        loop 400
        {
            if !this._IsWalkable(x, y, buf, bpr, rows, dsz)
                return false
            if (x = x1 && y = y1)
                return true
            e2 := err * 2
            if (e2 > -dy)
                err -= dy, x += sx
            if (e2 < dx)
                err += dx, y += sy
        }
        return false
    }

    ; Binary min-heap: sift item at index i upward.
    _HeapUp(heap, i)
    {
        while (i > 1)
        {
            p := i >> 1
            if (heap[p][1] <= heap[i][1])
                break
            tmp := heap[p], heap[p] := heap[i], heap[i] := tmp
            i := p
        }
    }

    ; Binary min-heap: sift item at index i downward.
    _HeapDown(heap, i)
    {
        n := heap.Length
        loop
        {
            s := i, l := i * 2, r := i * 2 + 1
            if (l <= n && heap[l][1] < heap[s][1])
                s := l
            if (r <= n && heap[r][1] < heap[s][1])
                s := r
            if (s = i)
                break
            tmp := heap[i], heap[i] := heap[s], heap[s] := tmp
            i := s
        }
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

        ; 8-direction offsets for neighbor checking
        nDX := [-1, 0, 1, -1, 1, -1, 0, 1]
        nDY := [-1, -1, -1, 0, 0, 1, 1, 1]

        ; Skip outer margin to avoid drawing the terrain boundary rectangle.
        MARGIN := 6
        loop bmpH
        {
            by := A_Index - 1
            gy := by * STEP
            if (gy < MARGIN || gy >= rows - MARGIN)
                continue
            loop bmpW
            {
                bx := A_Index - 1
                gx := bx * STEP
                if (gx < MARGIN || gx >= gridW - MARGIN)
                    continue

                ; Check all sub-cells in this STEP×STEP block.
                ; If ANY sub-cell is a border, set the mask pixel.
                foundBorder := false
                sy := 0
                while (sy < STEP) {
                    if foundBorder
                        break
                    sx := 0
                    while (sx < STEP) {
                        cGX := gx + sx
                        cGY := gy + sy
                        if (cGX >= gridW || cGY >= rows) {
                            sx++
                            continue
                        }
                        ci := cGY * bpr + (cGX >> 1)
                        if (ci < 0 || ci >= dsz) {
                            sx++
                            continue
                        }
                        curVal := (NumGet(buf, ci, "UChar") >> ((cGX & 1) * 4)) & 0xF
                        if (curVal != 0) {
                            sx++
                            continue
                        }
                        ; Non-walkable cell — check 8-connected neighbors for walkable
                        loop 8 {
                            nx := cGX + nDX[A_Index]
                            ny := cGY + nDY[A_Index]
                            if (nx < 0 || nx >= gridW || ny < 0 || ny >= rows)
                                continue
                            ni := ny * bpr + (nx >> 1)
                            if (ni < 0 || ni >= dsz)
                                continue
                            nv := (NumGet(buf, ni, "UChar") >> ((nx & 1) * 4)) & 0xF
                            if (nv != 0) {
                                foundBorder := true
                                break
                            }
                        }
                        if foundBorder
                            break
                        sx++
                    }
                    sy++
                }

                if foundBorder
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
