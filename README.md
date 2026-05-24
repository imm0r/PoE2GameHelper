<div align="center">

<img src="assets/logo_poE2gamehelper.png" width="640" alt="PoE2 GameHelper">

**A modern AutoHotkey v2 toolset for *Path of Exile 2* — overlays, automation, and a reverse-engineering workbench in one place.**

![Version](https://img.shields.io/badge/version-v0.4.11.2-blue)
![Build](https://img.shields.io/badge/build-stable-green)
![License](https://img.shields.io/badge/license-MIT-lightgrey)
![Language](https://img.shields.io/badge/language-AutoHotkey%20v2-orange)
![UI](https://img.shields.io/badge/UI-WebView2-7eb0e0)

</div>

---

<div align="center">
  <img src="assets/inventory.png" width="900" alt="PoE2 GameHelper — Arcane Codex UI">
  <p><em>Inventory tab — the "Arcane Codex" theme: vellum pages, illuminated chapter headings, sigil-card items with rarity ink-bleed glows.</em></p>
</div>

---

## Table of Contents

- [Highlights](#highlights)
- [Features](#features)
  - [Automation](#-automation)
  - [Overlays](#-overlays)
  - [Live Inspection](#-live-inspection)
  - [Reverse-Engineering Tools](#-reverse-engineering-tools)
- [UI Theme — Arcane Codex](#ui-theme--arcane-codex)
- [Requirements](#requirements)
- [Installation & Usage](#installation--usage)
- [Hotkeys](#hotkeys)
- [Project Structure](#project-structure)
- [References](#references)
- [License](#license)

---

## Highlights

🤖 **AutoPilot** — a single toggle drives unified **combat + loot pickup + exploration**, with LoS-gated skill firing, A\* path overlays, and a hard "don't click UI / transitions / portals" guard.

💎 **Loot Pickup** — rarity-filtered ground-item collection with a persistent cache (drops noticed during combat aren't forgotten) and an actual **per-item-size fit check** against the live backpack grid — fed by a 4 040-entry registry of every PoE2 base item.

🔬 **Reverse-Engineering Workbench** — Memory Diff (snapshot · do something in-game · snapshot · diff with multi-format decode), Cheat-Engine-style Dissector for navigating pointer chains, struct-diff Panel Detection, live UI tree browser.

📜 **Arcane Codex UI** — leather-bound grimoire aesthetic. Cinzel-titled chapter headings, vellum-page inventory grid, antique-gold inlays, IM Fell English numerals.

🗺 **Radar / Maphack overlay** — high-performance GDI render with full-zone reveal, entity icons, A\* path drawing.

💧 **AutoFlask** — life/mana threshold automation with cooldown-aware fallbacks.

---

## Features

### 🤖 Automation

**AutoPilot — one switch, full automation.** Hit `F10` (or the in-UI toggle) and the bot picks up the game: it explores unexplored terrain, engages hostiles when they come into range, collects filter-passing loot when the area is safe, and avoids waypoints / transitions / NPC dialogs.

The priority chain is *combat > loot > explore*; each stage claims a tick by returning true and the next stage only runs when the previous one stayed idle. State is surfaced in real time in the header pill — gilded gold when exploring, blood-red pulse during combat.

- **LoS-aware combat aiming** — A\* path computed when terrain blocks the straight line; the bot aims at the farthest waypoint with line-of-sight and walks via LMB until the enemy itself becomes visible. Skill keys **only** fire on direct LoS (no cooldown wasted on walls).
- **Click safety (`AvoidZones`)** — shared registry of screen-coordinate keep-out rects covering HUD elements (life globe, skill bar, minimap) + interactable world entities (transitions, waypoints, portals, NPCs). Combat and loot both consult it before any click.
- **Loot Pickup** — see below.

**AutoFlask** — configurable life/mana % thresholds, cooldown-aware, with ControlSend + PostMessage fallbacks for elevated-game scenarios.

<div align="center">
  <img src="assets/configuration1.png" width="800" alt="AutoPilot configuration">
  <p><em>AutoPilot configuration — master toggle, F10 hotkey, status feed, with the advanced tuning collapsed.</em></p>
</div>

### 💎 Loot Pickup

Filter ground drops by rarity (Normal · Magic · Rare · Unique · Currency) and the bot collects them when no hostile is in engage range. Items dropped *during* combat stay in a persistent cache so they're not forgotten — once the area is safe, the bot walks back for them.

- **Per-item-size fit check** — the bot reads each item's exact `inventory_width × inventory_height` from the bundled [base-item registry](data/base_item_sizes.tsv) (4 040 entries derived from [repoe-fork/poe2](https://repoe-fork.github.io/poe2/base_items.json)). Before clicking, it builds the **live backpack occupancy grid** and verifies there's a contiguous free rectangle that fits — no more "tried to pick up a 2×3 body armor with 5 scattered free cells".
- **Picked-up detection** — when a clicked entity disappears from the snapshot, it's removed from the cache immediately so the bot doesn't keep clicking ghost world positions.
- **Inventory-full gate** — the bot pauses pickup with a clear "inventory-full" status when no fitting rectangle exists; resumes automatically when you free space.

<div align="center">
  <img src="assets/configuration3.png" width="800" alt="Loot Pickup configuration">
  <p><em>Loot Pickup — five rarity filter pills, live cache count, last-action status.</em></p>
</div>

### 🗺 Overlays

**Radar & Maphack** — high-performance GDI overlay with minimap + large-map modes, full-zone reveal, entity icons (NPCs, Bosses, Waypoints, Chests), distance indicators, and isometric projection.

<div align="center">
  <img src="assets/radar_overlay.png" width="900" alt="Radar / Maphack overlay">
  <p><em>The radar overlaid on the game window — entities, A* combat path, maphack zone reveal.</em></p>
</div>

**Zone Navigation** — A\* pathfinder with adaptive step sizes (2/4/8) and automatic AreaTransition detection.

**Player HUD** — compact vitals overlay readable at a glance during combat.

### 🔍 Live Inspection

The WebView UI ships a multi-tab inspection layer over the live game state. Everything updates from the same memory-reader snapshot the automation modules consume.

**Entities** — sortable list of all active entities with rarity, life percentage, distance, and path. Click an entity to highlight it on the radar.

<div align="center">
  <img src="assets/entities_tab.png" width="800" alt="Entities tab">
</div>

**Skills & Buffs** — currently active skills + buffs with cooldowns, charges, and timers.

<div align="center">
  <img src="assets/skills_buffs.png" width="800" alt="Skills & Buffs tab">
</div>

**Inventory** — backpack grid + equipped slots + flask bar + every stash tab the game has populated. Hover any item for a parchment-slip tooltip with the full mod list.

<div align="center">
  <img src="assets/inventory.png" width="800" alt="Inventory tab">
</div>

**Watchlist** — pin any memory-tree path and watch its value live.

<div align="center">
  <img src="assets/watchlist_tab.png" width="800" alt="Watchlist tab">
</div>

### 🔬 Reverse-Engineering Tools

A first-class workbench for poking PoE2's memory — collected under a dedicated `RE` category in the navigation.

#### Memory Diff
Snapshot a memory region around a named anchor (`ServerDataStructure` / `GameUI` / `AreaInstance` / `InGameState`) or a raw hex address, do something in-game, snapshot again. Diff the byte runs that changed with multi-format decodes (i32 / u32 / i64 / ptr / float). Collapses hours of "find the byte that toggles when I open stash" into seconds.

<div align="center">
  <img src="assets/memory_diff.png" width="800" alt="Memory Diff tool">
</div>

#### Dissector — Cheat-Engine-style memory navigator
Any address rendered as an 8-byte-stride table: hex · i32 · u32 · f32 · i64 · ptr · f64 · ASCII. Click any pointer cell to dereference and jump there — back/forward history, configurable page size (64 B — 8 KB), page-aware reading that gracefully degrades at uncommitted-page boundaries.

<div align="center">
  <img src="assets/dissector.png" width="800" alt="Memory Dissector">
</div>

#### Panel Detection (struct diff)
Capture a struct baseline, open a game panel, compare. Surfaces the exact byte offsets that flip when each panel opens — the foundation of the "is the inventory window currently open?" guard used by all the automation modules.

<div align="center">
  <img src="assets/panel_diff.png" width="800" alt="Panel Detection diff">
</div>

#### UI Browser
Walk the game's live UI element tree from the root.

<div align="center">
  <img src="assets/ui_browser.png" width="800" alt="UI Browser">
</div>

#### gameState
Read-only view of the master `InGameState` struct — every nested object, decoded into a navigable tree.

<div align="center">
  <img src="assets/gamestate_tab.png" width="800" alt="gameState tree">
</div>

#### Data
Generated TSV exports (stat templates, base-item registry, etc.) for offline analysis.

<div align="center">
  <img src="assets/data.png" width="800" alt="Data exports">
</div>

---

## UI Theme — Arcane Codex

The interface is intentionally framed as a leather-bound grimoire of relics — a single bold aesthetic direction executed across every surface:

- **Typography** — [Cinzel](https://fonts.google.com/specimen/Cinzel) for illuminated chapter headings, [EB Garamond](https://fonts.google.com/specimen/EB+Garamond) for body text and item names, [IM Fell English SC](https://fonts.google.com/specimen/IM+Fell+English+SC) for engraved numerals. Windows-native serif fallbacks (Constantia / Palatino / Georgia) keep the aesthetic intact when offline.
- **Palette** — warm dark browns and aged ivory for the parchment; antique gold for active states and rules; blood crimson reserved for urgent combat warnings; cool steel-blue retained for "info" highlights to keep them distinct from automation gold.
- **AutoPilot cockpit** — the header pill shows three visually-distinct states the user can recognise at a glance during gameplay: quiet brown (OFF), gilded gold halo (exploring / ON), blood-red pulse (combat).
- **Inventory chapter** — vellum-page background with paper-grain noise + corner vignettes; item cards as sigil-slips with rarity-tinted ink-bleed glows (Rare items carry a subtle 4.5 s brightness pulse); tooltip is a parchment slip with corner fleurons and gilded section dividers.

<div align="center">
  <img src="assets/configuration2.png" width="800" alt="Config tab — Arcane Codex theme">
  <p><em>The Config tab — codex-framed sections, brass-thumbed sliders, inscribed-switch toggles, Cinzel small-caps everywhere.</em></p>
</div>

---

## Requirements

- **AutoHotkey v2.0+** — [download](https://www.autohotkey.com/)
- **Path of Exile 2** — Steam or standalone, both supported
- **Administrator privileges** — required for `ReadProcessMemory` against an elevated game process
- **WebView2 Runtime** — pre-installed on Windows 11; Windows 10 may need the [Evergreen runtime](https://developer.microsoft.com/en-us/microsoft-edge/webview2/)

---

## Installation & Usage

```bash
# Clone
git clone https://github.com/imm0r/PoE2GameHelper.git
cd PoE2GameHelper

# Run (path may vary; AHK v2 install location)
"C:\Program Files\AutoHotkey\v2\AutoHotkey.exe" InGameStateMonitor.ahk
```

The WebView UI window opens immediately. Start *Path of Exile 2* (or have it running already). The header shows `Connected ●` once the helper has attached to the process; from there everything is live.

---

## Hotkeys

| Key | Action |
|---|---|
| `F10` | Toggle **AutoPilot** (combat + loot + explore) |
| `F3` | One-shot debug dump (TreeView + game-window screenshot + radar entity TSV) |

Window-drag is bound to the header; double-click maximises. The Snap button (top-right) realigns the overlay to the current PoE window.

Most other toggles live in the **Config** tab — AutoPilot tuning, AutoFlask thresholds, radar entity filters, loot rarity filter, and per-skill slot configuration.

---

## Project Structure

```
InGameStateMonitor.ahk          ─ main entry / WebView host
│
├── Automation
│   ├── AutoPilot.ahk           ─ master state machine (combat > loot > explore)
│   ├── CombatAutomation.ahk    ─ LoS-aware aim, skill rotation, A* approach
│   ├── ExplorationModule.ahk   ─ visited-cell tracking, frontier finding
│   ├── LootPickup.ahk          ─ ground-item cache + fit-check pickup
│   ├── AvoidZones.ahk          ─ shared screen-rect keep-out registry
│   ├── ItemSizeRegistry.ahk    ─ base-item dimensions (loads data/base_item_sizes.tsv)
│   └── AutoFlask.ahk           ─ life/mana threshold flask automation
│
├── Memory reading
│   ├── PoE2MemoryReader.ahk         ─ core: pattern-scan, RIP-relative, panel diff
│   ├── PoE2EntityReader.ahk         ─ entity decoding + radar tile reads
│   ├── PoE2PlayerReader.ahk         ─ player vitals, flask slots
│   ├── PoE2PlayerComponentsReader.ahk ─ stats, buffs, charges
│   ├── PoE2ComponentDecoders.ahk    ─ shared component decoders
│   ├── PoE2InventoryReader.ahk      ─ inventories, items, mods, stash tabs
│   ├── PoE2Offsets.ahk              ─ struct offsets + discovered panel offsets
│   ├── StaticOffsetsPatterns.ahk    ─ pattern → static-pointer resolution
│   └── ProcessMemory.ahk            ─ RPM wrapper, pointer chain helpers
│
├── Overlays
│   ├── RadarOverlay.ahk        ─ GDI overlay + maphack + A* drawing
│   ├── PlayerHUD.ahk           ─ compact vitals overlay
│   └── Lib/TerrainPathfinder.ahk ─ A* with adaptive step sizing
│
├── Reverse-engineering
│   ├── MemoryDiff.ahk          ─ snapshot/diff with multi-format decode
│   ├── MemoryDissect.ahk       ─ CE-style memory navigator + history
│   └── UiTreeBrowser.ahk       ─ live UI tree traversal
│
├── UI / Bridge
│   ├── ui/index.html           ─ WebView UI (single page, Codex theme)
│   ├── WebViewBridge.ahk       ─ AHK → JS push (snapshots, status, JSON)
│   ├── BridgeDispatch.ahk      ─ JS → AHK route dispatch
│   ├── UIHelpers.ahk           ─ WebView control helpers
│   ├── SnapshotSerializers.ahk ─ JSON serializers per tab
│   ├── TreeViewWatchlistPanel.ahk ─ watchlist pinning logic
│   └── Lib/WebViewToo.ahk      ─ WebView2 ComCall wrapper
│
├── Support
│   ├── ConfigManager.ahk       ─ INI save/load
│   ├── ToggleHandlers.ahk      ─ feature-toggle wiring
│   ├── ErrorLogger.ahk         ─ rotating error.log
│   ├── PatchChecker.ahk        ─ detect game updates / version drift
│   └── JsonParser.ahk          ─ AHK v2 JSON parsing
│
└── data/                       ─ generated data assets
    ├── base_item_sizes.tsv     ─ 4040-entry path → (w, h) (for loot fit-check)
    ├── stat_desc_map.tsv       ─ mod template descriptions
    └── *.tsv                   ─ name maps, monster data, item base names
```

---

## References

- [**C# Original (GameHelper2)**](https://gitlab.com/bylafko/gamehelper2) — the original tool this AHK port draws inspiration from
- [**Wraedar (Zone Nav)**](https://github.com/diesal/Wraedar) — terrain pathfinding reference
- [**DAT-Schema**](https://github.com/poe-tool-dev/dat-schema) — PoE/PoE2 game-data schema
- [**poe-data-tools**](https://github.com/LocalIdentity/poe_data_tools) — PoE data file utilities
- [**repoe-fork (PoE2 base items)**](https://repoe-fork.github.io/poe2/base_items.json) — base-item registry source
- [**AHK v2 docs**](https://www.autohotkey.com/docs/v2/)

Detailed developer notes: [`DEV_README.md`](DEV_README.md)

---

## License

MIT — see [`LICENSE`](LICENSE) for the full text.

<div align="center">
  <sub>Built with ❤️ for the <em>Path of Exile 2</em> community.</sub>
</div>
