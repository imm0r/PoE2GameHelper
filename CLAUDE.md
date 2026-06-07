# Project conventions for Claude

Path of Exile 2 memory-reading / overlay assistant. AutoHotkey v2 + a WebView2 UI.
Reimplementation of the original C# project (see Reference). Version `0.4.12.2`.

## Language

**All written output must be in English.** That includes:

- Source code (variable names, function names, file names)
- Code comments (block comments, line comments, docstrings)
- Git commit messages
- Pull-request titles, descriptions, review comments
- Issue text on GitHub
- Any other artifact that ends up on GitHub or in the repo

Chat replies inside the editor may use whatever language the user is
writing in (German is fine), but the moment something gets committed
or posted to GitHub, switch to English.

The user is a native German speaker but explicitly wants the project
to stay in English so future contributors / public review aren't
blocked by language. Don't ask for translation help — just translate
inline when authoring commit messages, PR bodies, etc.

## Working rules

- **Never guess.** When unclear, first check the C# reference project (below); ask a
  clarifying question before doing extensive work.
- **Plan first** for larger tasks, then break them into small, verifiable steps.
- **Performance matters** — keep the per-frame render / radar hot path (every ~50–100 ms)
  as cheap as possible.
- Keep files small; split into new `*.ahk` modules via `#Include` when a single file grows
  substantially.
- New functions get a short 2-3 line comment explaining purpose, parameters, and return value.
- Variable names follow the existing camelCase / snake_case style of surrounding code.
- The user often cannot runtime-test (the game is ~140 GB). When a change can only be
  verified in-game, say so and list exactly what to check.

## Project structure & conventions

- **Entry point:** `InGameStateMonitor.ahk` (repo root). Run with **AutoHotkey v2**.
- **All other `.ahk` files live in `ahk/`.**
- **UI:** `ui/index.html` — one self-contained file with a single inline `<script>`,
  rendered in a WebView2 control.
- **Sounds:** alert `.wav` files live in the root **`wav/`** folder.

### Include conventions
- `InGameStateMonitor.ahk` includes with the `ahk/` prefix, e.g. `#Include ahk/RadarOverlay.ahk`.
- Files inside `ahk/` include each other with bare names, e.g. `#Include EntityFacts.ahk`.

### ⚠️ AHK v2 gotcha — module init (read before adding globals)
Feature modules are `#Include`d at the **bottom** of `InGameStateMonitor.ahk` (after the
auto-execute `return`, ~line 437). Function/class definitions still work, but **top-level
`global x := value` initializers in those modules never run.**

→ **Initialize every module global inside a `Load…()` / init function the main script calls
before its `return`** (see `LoadEntityGroups()`, `LoadEntityAlertsConfig()` around line ~295).
Seed defaults **unconditionally** (defaults first, then optionally overlay from INI). The
symptom of getting this wrong is the runtime error *"This global variable has not been
assigned a value."*

### Persistence (self-persist pattern, like LootPickup)
Each module owns its INI section: Groups → `poeformance_config.ini [Groups]`;
Alerts → `alerts.ini [Alerts]`.

### AHK ↔ WebView bridge
- AHK → JS: `PushHeaderToWebView()` builds a JSON header and calls `updateHeader(...)`.
- JS → AHK: UI calls `ahkCall(name, ...args)`, dispatched in `ahk/BridgeDispatch.ahk`.

### Line endings (preserve per file when editing)
- **CRLF:** `BridgeDispatch.ahk`, `WebViewBridge.ahk`. **LF:** everything else.

### Static verification (no game needed)
- AHK: brace balance per file; confirm edit anchors match exactly once.
- UI: extract the inline `<script>` and run `node --check`; keep `<div>` balance unchanged.

## Feature update — path-based Groups + Alert engine + overlay base

### New files (`ahk/`)
- **EntityFacts.ahk** — `ExtractMetaGroup(path)`, `ReadEntityRarityId(decoded)` (max of flat +
  nested `mods`/`objectmagicproperties`), `RarityIdToName(id)`. Used by SnapshotSerializers,
  EntityGroups, EntityAlerts.
- **EntityGroups.ahk** — `g_entityGroups`; resolve group by path/metaGroup,
  `GroupColorToBgr(#RRGGBB)`, `_ApplyEntityGroups`, `BuildGroupsHeaderJson`,
  `Save/LoadEntityGroups` (self-persist `[Groups]`).
- **EntityAlerts.ahk** — per-tick alert engine off the radar snapshot, run after AutoPilot,
  outside the "claim the tick" chain. Town/hideout suppression, per-area reset via
  `currentAreaHash`, severity ranking, zone-entry + proximity (cooldown) timing, and
  banner / sound / window-flash / radar-highlight / log outputs. WAV list from `wav/`.
  Self-persist `[Alerts]` in `alerts.ini`.
- **GdiOverlayBase.ahk** — reusable transparent, click-through, always-on-top GDI layer
  (cached pens/brushes/fonts, double-buffered blit). Used only by NotificationOverlay so far;
  PlayerHUD / RadarOverlay are NOT yet migrated to it.
- **NotificationOverlay.ahk** — `extends GdiOverlayBase`; map-independent banner layer.
  `SetBanner(text, ms, colorBGR)`; `Tick()` self-resolves the PoE window, foreground-gated,
  hides when idle.

### Edited files
- **SnapshotSerializers.ahk** — rarity via `ReadEntityRarityId`; emit `metaGroup` + `group` per entity.
- **PoE2MemoryReader.ahk** — expose `currentAreaHash` in the radar snapshot Map.
- **AutoFlask.ahk** — `g_notifyOverlay` in the UpdateRadarFast globals; after `TryAutoPilot`,
  call `TryEntityAlerts(radarSnap)` and `g_notifyOverlay.Tick()`.
- **BridgeDispatch.ahk** — `SetGroups` and `SetAlert` cases (apply, persist, refresh header).
- **WebViewBridge.ahk** — add `groups` + `alerts` to the header push.
- **RadarOverlay.ahk** — group-color override: a matching path group wins over the type color.
- **TreeViewWatchlistPanel.ahk** — include EntityFacts / EntityGroups / EntityAlerts.
- **InGameStateMonitor.ahk** — include GdiOverlayBase + NotificationOverlay; `g_notifyOverlay := 0`;
  extend `g_cfgOpenSections` default with `al-conditions,al-timing,al-output`;
  call `LoadEntityGroups()` + `LoadEntityAlertsConfig()` at startup.
- **ui/index.html** — Groups tab (editor, filter, colored pill, shared GGPK color picker,
  pill toggles) and Alerts tab (collapsible Config-style sections, conditional visibility,
  pill toggles, WAV dropdown). The GGPK maphack picker `openColorPicker(which, opts)` was
  generalized so Groups reuses it.

### UI conventions
- Collapsible sections: `.cfg-section > <details> > <summary><div class="cfg-header">` with
  `.cfg-subsection` / `.cfg-row` / `.cfg-label` inside.
- Boolean options use the themed pill toggle (`<label class="toggle"> … <span class="toggle-slider">`).
- Theme text font is `var(--codex-serif)` (labels 13px, `var(--codex-text)`).
- Section open/closed state persists via `_cfgSectionIds` + `syncCfgSections()` → `g_cfgOpenSections`.

### Recent bugfix
- `LoadEntityAlertsConfig()` now seeds all 24 alert globals (and `g_alertsConfigFile`)
  unconditionally before reading the INI — fixes "global not assigned" on a fresh install
  (see the AHK v2 init gotcha).

## Open / pending (needs the game running)

- Verify real alert matches; banner position/size; WAV playback; `FlashWindowEx` struct; the
  `currentAreaHash` zone-change signal; group colors on radar dots.
- Optional deferred refactor: migrate **PlayerHUD**, then **RadarOverlay**, onto `GdiOverlayBase`.

## Reference

- Original C# reference project (authority when unclear):
  `https://github.com/Gordin/GameHelper2` (branch `main`).
  Check it when starting a new feature — solutions / approaches may already exist there.
