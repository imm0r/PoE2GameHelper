# PoE2 GameHelper — Projekt Status

**Version:** 0.4.0.0  
**Zuletzt aktualisiert:** 17. Juni 2025  
**Status:** ✅ **PRODUKTIV**

## Zusammenfassung

Das Projekt ist ein **vollständiger AHK v2-Port** der Path of Exile 2 Memory-Reading-Engine mit WebView-basierter UI, Radar/Maphack-Overlay, Zone-Navigation und AutoFlask-Automation.

**Referenz-Projekte (immer als Maßstab nutzen):**

1. C# Original: https://gitlab.com/bylafko/gamehelper2
2. DAT-Schema (für TSV-Generierung): https://github.com/poe-tool-dev/dat-schema
3. PoE2 Patch-Server: `patch.pathofexile2.com:13060` (gibt aktuelle Version z.B. `4.4.0.10`)
4. AHK v2 Docs: https://www.autohotkey.com/docs/v2/
5. Wraedar (Zone-Nav Referenz): https://github.com/diesal/Wraedar

**Standard Formatierungen / Layouting:**

1. Auf der gesamten GUI Oberfläche: Speicheradressen ausschließlich hexadecimal (0x00000000)
2. Memory-Layout: Il2CppDumper kompatibel
3. Pattern-Format: IDA-Notation (`48 ?? 33 ??`)

---

## Datei-Struktur

```
GameHelper/
├── InGameStateMonitor.ahk      — Main Entry Point, UI Layout, Timer Management
├── PoE2MemoryReader.ahk        — Core Engine: Pattern-Scan, Memory-Read, Panel Detection
├── PoE2EntityReader.ahk        — Entity-Dekodierung, TgtTilesLocations, Awake/Sleeping Scan
├── PoE2PlayerReader.ahk        — Player-Vitals, Flask-Slots, Player-Specific Reads
├── PoE2PlayerComponentsReader.ahk — Player Component Decoding (Stats, Buffs, Charges)
├── PoE2ComponentDecoders.ahk   — Shared Component Decoders (Life, Positioned, Render, etc.)
├── PoE2InventoryReader.ahk     — Inventory & Item Decoding
├── PoE2Offsets.ahk             — Offset-Maps (1:1 Port von C# GameOffsets)
├── ProcessMemory.ahk           — Win32 Memory I/O
├── StaticOffsetsPatterns.ahk   — Pattern-Signaturen (IDA-Notation)
├── RadarOverlay.ahk            — GDI Radar/Minimap Overlay + Maphack + A* Pathfinder
├── AutoFlask.ahk               — AutoFlask-Automation, Render Loop, Radar Sync
├── PlayerHUD.ahk               — Compact Player Vitals GDI Overlay
├── WebViewBridge.ahk           — JSON Push, Debug Data, Panel Visibility Serialization
├── BridgeDispatch.ahk          — WebView→AHK Message Routing
├── ConfigManager.ahk           — Config Save/Load (INI Persistence)
├── ToggleHandlers.ahk          — Feature Toggle Logic
├── SnapshotSerializers.ahk     — Snapshot→JSON Serialization (Entities, Buffs, UI, etc.)
├── DebugDump.ahk               — Debug Dump (F3, Entity TSV, Screenshots)
├── ErrorLogger.ahk             — Error Logging with Rotation
├── JsonParser.ahk              — Bridge Message JSON Parsing
├── UIHelpers.ahk               — Thresholds, Formatters, UI Helpers
├── TreeViewWatchlistPanel.ahk  — TreeView Watchlist & Stat-Formatierung
├── TreeView_EntityScanner.ahk  — Entity-Scanner Tab Logic
├── TreeView_Rendering.ahk      — TreeView Rendering Helpers
├── TreeView_StateManagement.ahk — TreeView State Management
├── TreeView_StatsFormatting.ahk — Stat Description Enrichment & Formatting
├── PatchChecker.ahk            — Patch-Version via TCP
├── SmokeTest.ahk               — Schnell-Diagnose (Connectivity Check)
├── PatternScanDemo.ahk         — Pattern-Scan Diagnostik-Tool
├── GgpkMemoryMonitor.ahk       — GGPK Memory Monitor
├── GgpkMemoryMonitorApp.ahk    — GGPK Monitor App Wrapper
├── gamehelper_config.ini        — Runtime-Konfiguration (AutoFlask, Radar, Tabs, etc.)
├── schema.min.json              — DAT-Schema (für TSV-Generierung)
├── Lib/
│   ├── WebViewToo.ahk          — WebView2 AHK-Wrapper (extended)
│   ├── WebView2.ahk            — WebView2 COM-Interface
│   ├── Promise.ahk             — Promise-Pattern für AHK
│   ├── ComVar.ahk              — COM Variant Helpers
│   ├── 32bit/                  — WebView2 32-bit Loader DLL
│   └── 64bit/                  — WebView2 64-bit Loader DLL
├── ui/
│   ├── index.html              — WebView UI (Tabs: Entities, Skills & Buffs, Config, etc.)
│   ├── animation_names.js      — Animation Enum Lookup (JS)
│   ├── gamehelper.ico           — App Icon
│   ├── tray.ico                — Tray Icon
│   ├── tray2.ico               — Alt Tray Icon
│   └── logo.png                — Logo
├── Pages/
│   ├── index.html              — Bootstrap-based alternate page
│   └── Bootstrap/              — Bootstrap assets
├── data/
│   ├── stat_name_map.tsv       — Hash→stat_id (24887 Einträge)
│   ├── stat_desc_map.tsv       — stat_id→Template (12958 Einträge)
│   ├── mod_name_map.tsv        — mod_id→Name
│   ├── base_item_name_map.tsv  — Basis-Item-Namen
│   ├── unique_item_name_map.tsv
│   ├── unique_name_map.tsv
│   ├── monster_name_map.tsv
│   ├── raw_stats_debug.tsv     — Debug-Output
│   ├── animation_enum.json     — Animation Enum (953 Einträge)
│   └── ggpk_directory_tree.json — GGPK Directory Index
├── tools/
│   ├── compare_offsets.py      — Offset-Vergleich AHK↔C# (GitLab)
│   ├── build_item_names.py     — Generiert alle item/mod/unique TSVs
│   ├── build_stat_desc_map.py  — Generiert stat_desc_map.tsv
│   ├── extract_stats_dat.py    — Generiert stat_name_map.tsv
│   ├── extract_mods_dat.py     — Extrahiert Mod-Daten
│   ├── extract_monster_names.py — Extrahiert Monster-Namen
│   ├── parse_index.py          — Shared: Bundle-Index Parser
│   ├── analyze_shared.py       — Shared: Bundle-Reader
│   ├── gen_anim_lookup.py      — Generiert animation_names.js + animation_enum.json
│   ├── gen_ct.py               — Generiert Cheat Engine Table
│   ├── make_icon.py            — Generiert Icons
│   ├── poe2_ce_inspector.lua   — Cheat Engine Lua Script
│   ├── PoE2_Inspector.CT       — Cheat Engine Table
│   ├── ggpk-explorer.exe       — GGPK Explorer Binary
│   └── explore_*, inspect_*    — Analyse-/Debug-Tools
└── metadata/
    └── ui/                     — UI metadata files
```

**Nach jedem PoE2-Patch TSVs neu generieren:**

```
cd tools
python extract_stats_dat.py
python build_stat_desc_map.py
python build_item_names.py
python extract_monster_names.py
```

**Offset-Vergleich mit C#-Upstream nach Patch:**

```
cd tools
python compare_offsets.py              # Diff anzeigen (fetcht automatisch)
python compare_offsets.py --no-fetch   # Diff ohne Online-Abfrage
python compare_offsets.py --record     # Änderungen in offset_history.json aufnehmen
python compare_offsets.py --history    # Historische Änderungen anzeigen
python compare_offsets.py --predict    # Delta-Muster für Vorhersagen analysieren
```

---

## Features (aktueller Stand)

| Feature | Status | Beschreibung |
|---|---|---|
| Memory-Engine | ✅ | Pattern-Scan, RIP-Relative, GameStates |
| AutoFlask | ✅ | Life/Mana-Schwellen, Cooldown, Verification |
| Entity-Scanner | ✅ | Awake/Sleeping, Distance-Sort, Icons, Highlights |
| Radar Overlay | ✅ | GDI Minimap + Large Map, Entity Icons, Pathlines |
| Maphack | ✅ | Full terrain border rendering on large map via PlgBlt |
| Zone Navigation | ✅ | A* Pathfinder to farthest AreaTransition, TgtTilesLocations |
| Skills & Buffs Tab | ✅ | Live buff/debuff tracking with icons, blacklist, INI persistence |
| Player-Stats | ✅ | Stat-Description-Enrichment mit CSD-Templates |
| Player HUD | ✅ | Compact GDI overlay — Life, Mana, Shield, ES, Evasion |
| Panel Detection | ✅ | Visibility-differential + raw struct pointer tracking |
| Overlay Gating | ✅ | Overlay auto-hide bei Large Map off, Panels offen, Chat aktiv |
| WebView UI | ✅ | 8-Tab UI with icons, Config right-aligned |
| Debug Tab | ✅ | Panel Visibility Live, Discovery Results, Struct Diff Diagnostic |
| Patch-Version-Check | ✅ | TCP-Query beim Start, MsgBox bei neuem Patch |
| Config Persistence | ✅ | INI-based save/load for all toggles and settings |
| Codebase Refactoring | ✅ | Single-responsibility file extraction (12 new modules) |

---

## Neue Features (v0.4.0.0)

### Panel Detection (PoE2MemoryReader.ahk)
- **Heap-Pointer-Scan** — scannt ImportantUiElements Struct (0x400-0xC00) für gültige Heap-Pointer
- **UiElement-Validierung** — Heap-Filter (< 0x7FF000000000) + ParentPtr-Check
- **Visibility-Differential** — IS_VISIBLE bit 11 @ Flags-Offset 0x180 gegen Baseline
- **Raw-Struct-Pointer-Tracking** — single 2KB RPM detektiert Pointer-Erscheinen/Verschwinden
- **Dual Detection** — nur positive Signale (newlyVisible + ptrsAppeared) = Panel offen
- **Auto-Baseline** — 3s nach Zone-Change automatisch neu kalibriert
- **Manual Reset** — Button im Debug-Tab für manuelle Baseline-Neukalibrierung
- **Struct Diff Diagnostic** — Snapshot/Compare Tool für zukünftige Offset-Recherche

### Player HUD (PlayerHUD.ahk)
- **GDI Overlay** — Life, Mana, Shield, ES, Evasion mit Prozent-Anzeige
- **Dynamische Farben** je nach Wert (rot/gelb/grün)
- **Konfigurierbar** via Config-Tab Toggle

### Overlay Visibility Gating (AutoFlask.ahk)
- **5 Bedingungen** für Overlay-Sichtbarkeit:
  1. Radar eingeschaltet
  2. InGameState aktiv
  3. Nicht im Ladebildschirm
  4. Large Map aktiv (nicht nur Minimap)
  5. Kein Game-Panel offen (Panel Detection)
- **Chat Detection** — erkannter ChatParent @ 0x5C0

### Codebase Refactoring
- **12 neue Module** extrahiert aus InGameStateMonitor.ahk und UIHelpers.ahk
- **Single Responsibility** — jede Datei hat genau eine Aufgabe
- **Neue Dateien:** JsonParser, ErrorLogger, BridgeDispatch, ConfigManager, WebViewBridge, SnapshotSerializers, DebugDump, ToggleHandlers, PlayerHUD

### WebView UI Enhancements (ui/index.html)
- **8 Tabs** mit Unicode-Icons: 🔍 Entities, ⚔ Skills & Buffs, 🖥 UI, 📊 gameState, 📋 WatchList, 📁 TSVs, 🐛 Debug, ⚙ Config
- **Config-Tab rechts ausgerichtet**, alle anderen links
- **Debug-Tab** mit Panel Visibility Live, Discovery Results, Struct Diff, Overlay State
- **Overview-Sektion** im Config-Tab direkt unter Status

---

## Neue Features (v0.3.0.0)

### Radar Overlay (RadarOverlay.ahk)
- **GDI-basiertes Overlay** mit Minimap- und Large-Map-Modus
- **Entity-Icons** auf der Karte (AreaTransition, Waypoint, Checkpoint, NPC, Boss, etc.)
- **Player-Position-Tracking** mit isometrischer Projektion
- **Distance-Labels** für alle sichtbaren Entities
- Konfigurierbar via WebView UI Toggles

### Maphack
- **Volle Terrain-Enthüllung** der gesamten Zone auf der Large Map
- Liest `GridWalkableData` und erkennt Grenz-Zellen (non-walkable mit walkable Nachbar)
- 8-connected Border-Detection mit STEP=2 Downsampling, alle Sub-Cells geprüft
- Monochrome Maske + `PlgBlt` isometrische Projektion
- Neutrales Grau (0x909090) passend zum Game-Style
- **Toggle** über WebView UI mit INI-Persistenz

### Zone Navigation
- **A* Pathfinder** mit 3-Tier STEP-System (2/4/8) je nach Distanz
- **TgtTilesLocations**: Zone-weiter Scan für AreaTransitions, Waypoints, Checkpoints
- Targets automatisch das **entfernteste** AreaTransition
- Pfad wird als Linie auf der Karte gezeichnet
- Sleeping-Entity-Scan mit erweitertem Bubble-Radius für Navigation-Entities
- Zeitbudget: 200ms (kurz) / 500ms (zone-weit)

### Skills & Buffs Tab
- **Dedizierter Tab** in der WebView UI für alle aktiven Buffs/Debuffs
- **Buff-Icons** mit Duration-Timer und Charges
- **Blacklist** — Skills per Rechtsklick ausblenden
- **INI-Persistenz** der Blacklist (`[SkillsBlacklist]` Section)

### WebView UI (ui/index.html)
- **Multi-Tab-Layout**: Entities, Skills & Buffs, Konfiguration
- **Entity-Tab**: Sortierbare Entity-Liste mit Distance, Type, Icons
- **Config-Tab**: AutoFlask-Schwellen, Radar-Toggles, Maphack-Toggle, Zone-Nav-Toggle
- **Bridge-Kommunikation** AHK↔WebView via `chrome.webview.postMessage`

---

## Architektur-Übersicht

```
┌─────────────────────────────────────────────────────────┐
│            InGameStateMonitor.ahk (Main)                │
│  - WebView UI Host & Timer Management                   │
│  - #Include Orchestration (18 modules)                  │
└──────────┬──────────────────┬───────────────────────────┘
           │                  │
    ┌──────┴──────┐    ┌──────┴──────────────────┐
    │ AutoFlask   │    │  RadarOverlay.ahk       │
    │ .ahk        │    │  - GDI Overlay          │
    │ - Flask     │    │  - Minimap + Large Map   │
    │   Logic     │    │  - Maphack (PlgBlt)      │
    │ - Overlay   │    │  - A* Pathfinder         │
    │   Gating    │    │  - Entity Icons          │
    └──────┬──────┘    └──────┬──────────────────┘
           │                  │
    ┌──────┴──────┐    ┌──────┴──────────────────┐
    │ PlayerHUD   │    │  WebViewBridge.ahk      │
    │ .ahk        │    │  BridgeDispatch.ahk     │
    │ - Life/Mana │    │  ConfigManager.ahk      │
    │ - GDI HUD   │    │  ToggleHandlers.ahk     │
    └──────┬──────┘    └──────┬──────────────────┘
           │                  │
    ┌──────┴──────────────────┴──────────────────┐
    │        PoE2MemoryReader.ahk (Core)         │
    │  - Pattern-Scanning & Static Addresses     │
    │  - GameState Traversal                     │
    │  - Panel Detection (Visibility Baseline)   │
    ├────────────────────────────────────────────┤
    │ PoE2EntityReader    │ PoE2PlayerReader     │
    │ PoE2ComponentDecod. │ PoE2PlayerComponents │
    │ PoE2InventoryReader │                      │
    └────────────┬───────────────────────────────┘
                 │
    ┌────────────┼──────────────────────────────┐
    │ ProcessMemory.ahk  PoE2Offsets.ahk        │
    │ (Win32 I/O)        (Offset Maps)          │
    │                    StaticOffsetsPatterns   │
    └───────────────────────────────────────────┘
```

---

## Technische Details

### Maphack
- **Generation** (einmal pro Zone): `_GenerateMapHackBitmap()` erstellt Source-Bitmap (Solid Gray) + Monochrome Mask
- **Rendering** (pro Frame): `_RenderMapHack()` via PlgBlt isometrische Projektion
- **Border-Detection**: Non-walkable Cell (nibble=0) mit mindestens einem walkable 8-Nachbar
- **STEP=2** Downsampling: Alle 4 Sub-Cells pro Bitmap-Pixel geprüft (lückenlose Grenzen)
- **MARGIN=6**: Überspringt äußere Terrain-Grenze (kein Rahmen-Artefakt)

### A* Pathfinder
- 3 STEP-Stufen: 2 (≤200 Grid), 4 (≤500), 8 (>500)
- 8-Richtungen, Integer-Kosten, Manhattan-Heuristik
- Adaptive Bounding-Box mit Padding
- Zeitbudgets: 200ms (kurz/mittel), 500ms (zone-weit)

### Isometrische Projektion
- Kamerawinkel: 38.7° (CAMERA_COS=0.78094, CAMERA_SIN=0.62470)
- Grid→Screen: `screenDX = (dGX-dGY)*projCos`, `screenDY = (-dGX-dGY)*projSin`

### Walkable Terrain Data
- Gepacktes Nibble-Array über gesamte Zone
- Jedes Byte = 2 Grid-Cells: gerade-x → untere 4 Bits, ungerade-x → obere 4 Bits
- Nibble: 0 = nicht begehbar, 1-5 = begehbar

### Config/INI System
- Globals in `InGameStateMonitor.ahk`, Bridge in `BridgeDispatch.ahk`
- Save/Load in `ConfigManager.ahk`, Header-Push als JSON an WebView
- Sections: `[AutoFlask]`, `[Radar]`, `[SkillsBlacklist]`, `[EntityScanner]`

### Panel Detection (PoE2MemoryReader.ahk)
- **Struct Layout:** ImportantUiElements at InGameUi + 0x400..0xC00 (2KB, single RPM call)
- **Pointer Filter:** Only heap pointers < 0x7FF000000000 (excludes module-space false positives)
- **UiElement Validation:** Valid ParentPtr at +0x0B8 confirms genuine UiElement
- **Flags:** IS_VISIBLE = bit 11 at Flags offset +0x180 (0x004626F1 → 0x00462EF1)
- **Baseline:** Captured with all panels closed (auto-refresh 3s post zone-change)
- **Detection:** newlyVisible (flag flips) + ptrsAppeared (new struct pointers) → anyPanelOpen
- **Known Containers:** 0x5C0 (ChatParent), 0x6B0 (PassiveTree), 0x748 (MapParent)
- **StringId Offset 0x140 is WRONG** for current game version — probed all offsets 0x000-0x300 with multiple string encodings, zero strings found

| Thema | Detail |
|---|---|
| AHK v2 static Map | `static x := Map(...)` nicht erlaubt — `\|`-Kette oder lazy init |
| `CreateBitmap` raw buffer | Silently fails — DC + SetPixelV Ansatz verwenden |
| Nested ternary chains | Misparsed in AHK v2 — explizite Arrays verwenden |
| `while(cond && cond)` + `continue` | Unerwartet — `while(cond) { if (x) break }` |
| stat_name_map Keys | 1-basiert im Speicher → -1 für 0-basierten TSV-Lookup |
| permyriad | ÷100 = %, nicht ÷10 |
| WORLD_TO_GRID_RATIO | 10.870 (Welt→Grid Umrechnung) |

---

## Referenzen

- **C# Original:** https://gitlab.com/bylafko/gamehelper2
- **DAT-Schema:** https://github.com/poe-tool-dev/dat-schema
- **Wraedar (Zone Nav):** https://github.com/diesal/Wraedar
- **Patch-Update:** https://github.com/poe-tool-dev/poe-patch-update
- **AHK v2 Docs:** https://www.autohotkey.com/docs/v2/
