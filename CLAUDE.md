# Project conventions for Claude

Path of Exile 2 memory-reading / overlay assistant. AutoHotkey v2 + a WebView2 UI.
Reimplementation of the original C# project (see Reference). Version `0.45.11.26`.

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
- **Always end a reply that committed & pushed with the exact pull command** so the
  user can grab it locally, e.g. `git pull origin <current-dev-branch>`. Every time a
  change is pushed — no exceptions.
  **Never add the current AI Session to the end of the commit message** — Skip the entire line (e.g. "https://claude.ai/code/session_123456789abcdef")

### Completion-summary format (lean, GitHub-ready)
When wrapping up a task, output the summary as ONE copyable raw GitHub-flavored
markdown block (a fenced ```` ```markdown ```` code block), so it can be pasted
straight into a PR/issue/commit. Because it is destined for GitHub, write it in
**English** (per the Language rules above). Use this fixed, lean structure and
show only the sections that have content — never pad with empty headings:

- **Summary** — one sentence on what was achieved.
- **Changes** — bullet list, `path/file.ext:line — what & why`.
- **Advices** — everything the needs to know about how the changes work.
- **Open / Next steps** only when actually relevant. Any prose outside the block
(chat commentary) may stay German.

## Project structure & conventions

- **Entry point:** `InGameStateMonitor.ahk` (repo root). Run with **AutoHotkey v2**.
- **All other `.ahk` files live in `ahk/`.**
- **UI:** `ui/index.html` — one self-contained file with a single inline `<script>`,
  rendered in a WebView2 control.
- **Sounds:** alert `.wav` files live in the root **`wav/`** folder.
- **Logs:** `.log` files live in the root **`Logs/`** folder.
- **Data:** `.tsv` files needed for translating internal strings by using a dictionary live in the root **`Data/`** folder.
- **Tools:** `.py` files needed for building the dictionaries live in the root **`Tools/`** folder.

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

## Local HTTP API + MCP server (AI assistant integration)

Opt-in feature that lets an external Model-Context-Protocol server (and thus an AI
assistant) read live game data and change settings. Inspired by
NattKh/POE2Radar's `mcp-server` — but PoEformance had no HTTP server, so this adds
both halves.

- **`ahk/LocalApiServer.ahk`** — a tiny HTTP server on `127.0.0.1` (default port
  7777). Winsock + `WSAAsyncSelect`; socket events arrive as window messages on a
  hidden Gui and are dispatched via `OnMessage` on the main thread, so the radar
  hot path is never blocked and reads of `g_radarLastSnap` stay consistent.
  Off by default. `LoadLocalApiConfig()` seeds all globals **and** the `LOCALAPI_*`
  Winsock constants unconditionally (init gotcha). Self-persists `[LocalApi]`
  (`enabled`, `port`) in `poeformance_config.ini`. Endpoints: `GET /state`,
  `GET /entities`, `GET|POST /api/groups`, `GET|POST /api/alerts`,
  `GET|POST /api/config`, `GET|POST|DELETE /api/watchlist`, `GET /api/names`.
  Reads pull from the snapshot / existing `_Build*Json`; writes route through the
  existing bridge commands (`_DispatchBridgeCall`) so side effects + persistence
  match the UI exactly.
- **`mcp-server/`** — Node MCP server (`index.js`, `package.json`, `README.md`)
  that proxies the HTTP API. Tools: `game_state`, `get_entities`, `get_groups`/
  `set_groups`/`add_group`/`remove_group`, `get_alerts`/`set_alert`,
  `get_config`/`update_config`, watchlist tools, `search_names`. Run `npm install`
  in `mcp-server/`; `node_modules` is gitignored.
- **Wiring:** `InGameStateMonitor.ahk` includes the module, seeds
  `g_localApiEnabled`/`g_localApiPort`, calls `LoadLocalApiConfig()`, and
  `StartLocalApiServer()`/`StopLocalApiServer()` (OnExit). `BridgeDispatch.ahk` has
  a `ToggleLocalApi` case; `WebViewBridge.ahk` pushes `localApi`/`localApiPort` in
  the header; `ui/index.html` has the toggle in **Config → General → Integrations**
  (section id `integrations`).
- **Pending (needs the game/Windows):** verify the Winsock listener binds, that
  `OnMessage` fires for the hidden Gui, request/response round-trips, and that the
  config toggle starts/stops the server. The listener only starts at app launch,
  so toggling on requires a restart.

## Open / pending (needs the game running)

- Verify real alert matches; banner position/size; WAV playback; `FlashWindowEx` struct; the
  `currentAreaHash` zone-change signal; group colors on radar dots.
- Optional deferred refactor: migrate **PlayerHUD**, then **RadarOverlay**, onto `GdiOverlayBase`.

## Reference

- Original C# reference project (authority when unclear):
  `https://github.com/Gordin/GameHelper2` (branch `main`).
  Check it when starting a new feature — solutions / approaches may already exist there.
