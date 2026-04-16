# PoE2 GameHelper v0.3.0.0

AHK v2.0 Port der Path of Exile 2 Memory-Reading-Engine mit Radar/Maphack-Overlay, Zone-Navigation, AutoFlask und WebView-basierter UI.

**Status:** ✅ **Produktiv**

## Features

### ✅ Radar & Maphack Overlay
- **GDI Overlay** mit Minimap + Large Map Modus
- **Maphack** — Enthüllt die gesamte Zone auf der Large Map (walkable terrain borders)
- **Entity-Icons** — AreaTransitions, Waypoints, Checkpoints, NPCs, Bosses
- **Distance-Labels** für alle sichtbaren Entities
- Isometrische Projektion passend zum Game-Kamerawinkel

### ✅ Zone Navigation
- **A* Pathfinder** mit 3-Tier STEP-System (2/4/8 je nach Distanz)
- Zone-weiter Scan für AreaTransitions via TgtTilesLocations
- Pfad zum nächsten Ziel wird auf der Karte gezeichnet

### ✅ Memory-Reading
- Pattern-Scanning mit RIP-relative Adress-Auflösung
- GameState-Tracking (InGameState, Loading, Menu)
- Player-Vitals, Entity-Dekodierung, Component-System
- Awake & Sleeping Entity-Maps

### ✅ AutoFlask
- Life/Mana-Schwellen (konfigurierbar)
- Cooldown-Tracking mit Verification
- ControlSend + PostMessage Fallback

### ✅ Skills & Buffs
- Dedizierter Tab für aktive Buffs/Debuffs
- Icons, Duration-Timer, Charges
- Blacklist mit INI-Persistenz

### ✅ WebView UI
- Multi-Tab-Layout (Entities, Skills & Buffs, Config)
- Sortierbare Entity-Liste mit Distance und Type
- Konfigurierbare Toggles für alle Features

## Start

1. **Voraussetzungen:**
   - AutoHotkey v2.0+ ([Download](https://www.autohotkey.com/download/))
   - PoE2 installiert und laufend
   - Terminal mit Admin-Rechten (für Memory-Zugriff)

2. **Starten:**
   ```powershell
   # Terminal als Administrator öffnen
   cd <GameHelper-Verzeichnis>
   "C:\Program Files\AutoHotkey\v2\AutoHotkey.exe" InGameStateMonitor.ahk
   ```

3. **Beenden:** `Esc`

## Architektur

```
InGameStateMonitor.ahk (Main Entry, WebView UI Host)
├── PoE2MemoryReader.ahk (Core: Pattern-Scan, Static Addresses)
│   ├── PoE2EntityReader.ahk (Entity Decoding, TgtTiles)
│   ├── PoE2PlayerReader.ahk (Player Vitals, Flask-Slots)
│   ├── PoE2PlayerComponentsReader.ahk (Stats, Buffs, Charges)
│   ├── PoE2ComponentDecoders.ahk (Shared: Life, Render, Position)
│   └── PoE2InventoryReader.ahk (Inventory & Items)
├── RadarOverlay.ahk (GDI Overlay, Maphack, A* Pathfinder)
├── AutoFlask.ahk (Flask Automation, Render Loop)
├── UIHelpers.ahk (WebView Bridge, Config Save/Load)
└── ProcessMemory.ahk / PoE2Offsets.ahk / StaticOffsetsPatterns.ahk
```

## Referenzen

- **C# Original:** https://gitlab.com/bylafko/gamehelper2
- **Wraedar (Zone Nav):** https://github.com/diesal/Wraedar
- **DAT-Schema:** https://github.com/poe-tool-dev/dat-schema
- **AHK v2 Docs:** https://www.autohotkey.com/docs/v2/

Detaillierte Dokumentation: siehe `PROJECT_STATUS.md`
