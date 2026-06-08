# ggpk-tools — PoE2 game-data extraction & patching

Standalone CLI utilities that read and modify PoE2's `Bundles2/_.index.bin`
(and `Content.ggpk` on legacy installs). Used by the main PoEformance
(AHK) project but deliberately built as **separate executables** invoked
via shell-out so the AGPL-3.0 license of the underlying LibGGPK3 library
stays scoped to this directory.

⚠️  **All code in this directory is AGPL-3.0** — see [LICENSE](LICENSE).
    The rest of PoEformance stays MIT.

## What's here

| Tool | Purpose | Phase |
|---|---|---|
| `PoeDataExtract` | Read DAT tables out of the game data and emit them as TSV for the helper to consume (replaces our dependency on repoe-fork / DAT-Schema dumps). | 1 — ✅ working for `BaseItemTypes` |
| `PoePatcher`     | Apply / revert one-shot modifications to game files (e.g. shader-level maphack, à la PoeRedux). Records originals via `BackupManager` so patches are reversible. | 2 — ⚠ shader substrings verified, apply-test pending |

## Prerequisites

- **.NET 8 SDK** — https://dotnet.microsoft.com/download/dotnet/8.0
- **C++ build tools** (for the AOT publish only) — Visual Studio 2022 with
  the *"Desktop development with C++"* workload, or the standalone
  *Build Tools for Visual Studio*. Native AOT invokes the MSVC linker
  (`link.exe`) as its last step; without the C++ toolchain the
  `-p:PublishAot=true` publish fails at link time even though the .NET SDK
  itself is installed. A plain `dotnet build` (framework-dependent) does
  **not** need this.
- **LibGGPK3 source** — already wired up as a git submodule at
  `external/LibGGPK3` (see `.gitmodules`). After a fresh clone the folder
  is empty until you check it out:

  ```bash
  git submodule update --init --recursive
  ```

  The `.csproj` files reference its sub-projects via the `$(LibGGPK3Root)`
  MSBuild property defined in `Directory.Build.props`.
- **Oodle decompression DLL** — placed next to the compiled
  executables (or anywhere on `PATH` / the working directory).
  LibBundle3 imports it via `DllImport("oo2core")`, so on Windows the
  file must be named **`oo2core.dll`** (no version suffix). If you
  pulled a copy named `oo2core_9_win64.dll` from a game install, just
  rename it. PoE2 statically links Oodle so the DLL is **not** in the
  PoE2 install folder. **`PoeDataExtract` now auto-provisions this on
  first run** — if `oo2core.dll` isn't already loadable it scans your
  local Steam game installs (anchored off the ggpk/index path you pass)
  for an `oo2core*.dll`, copies it next to the exe, and (in an interactive
  terminal) offers a file picker as a fallback. It never downloads or
  bundles the DLL — the copy comes from a game you already own. Legitimate
  manual sources:
  - a Path of Exile **1** install root (free Steam download — but check
    the `Redist/` subfolder if the root looks empty)
  - aianlinb's [VisualGGPK3 release ZIPs](https://github.com/aianlinb/LibGGPK3/releases)
  - any other Oodle-using game you own (Apex Legends, Warframe, Manor
    Lords, Death Stranding, ARK: Survival Ascended, etc. — FIFA 23 and
    Cyberpunk 2077 carry it too)

  The DLL is proprietary (RAD Game Tools / Epic) — we cannot ship it.

## Build

From this directory:

```bash
# One-time after a fresh clone: check out the LibGGPK3 submodule
# (already registered in .gitmodules — this populates external/LibGGPK3)
git submodule update --init --recursive

# Restore + build both tools
dotnet build -c Release

# Single-file AOT publish — smaller binaries, no .NET runtime
# dependency on the user's machine
dotnet publish PoeDataExtract -c Release -r win-x64 --self-contained -p:PublishAot=true
dotnet publish PoePatcher     -c Release -r win-x64 --self-contained -p:PublishAot=true
```

Output binaries land in `*/bin/Release/net8.0/win-x64/publish/`. Drop
`oo2core.dll` next to each `.exe` (rename from `oo2core_9_win64.dll`
if your source has the versioned name).

## Usage

Both tools accept either the legacy `Content.ggpk` (PoE1, older PoE2
beta installs) or the bare `Bundles2/_.index.bin` (current PoE2 Steam)
— passed via `--ggpk`. The opener auto-detects which it's looking at
based on the file extension.

### Refresh ALL data files in one go (the common case)

Just hand `PoeDataExtract` the path to your game data file — no verb,
no flags — and it extracts every TSV the helper consumes straight into
the repo's `data/` folder:

```bash
poe-data-extract.exe "C:\path\to\Bundles2\_.index.bin"
```

This runs all six extractors and writes `base_item_sizes.tsv`,
`monster_name_map.tsv`, `stat_name_map.tsv`, `mod_name_map.tsv`,
`unique_item_name_map.tsv` and `map_mod_list.tsv`. The `data/` folder is
auto-located by walking up from the exe to the repo root; override it
with `--output-dir <dir>` if needed. `map_mod_list.tsv` is best-effort
(it's the most schema-fragile table and a failure there won't fail the
batch). Equivalent explicit form:

```bash
poe-data-extract.exe extract-all --ggpk "C:\path\to\Bundles2\_.index.bin"
```

### Listing files inside the GGPK / bundle index

Useful when an expected internal path 404s — GGG moves things between
patches.

```bash
poe-data-extract.exe ls ^
    --ggpk "C:\path\to\Bundles2\_.index.bin" ^
    --match baseitem
```

### Extracting base-item dimensions

```bash
poe-data-extract.exe extract ^
    --ggpk "C:\path\to\Bundles2\_.index.bin" ^
    --table BaseItemTypes ^
    --output ..\data\base_item_sizes.tsv
```

TSV output: `id<TAB>name<TAB>width<TAB>height` per row, header row first.
Example:

```
id                                                  name                    width  height
Metadata/Items/Currency/CurrencyWeaponQuality       Blacksmith's Whetstone  1      1
Metadata/Items/Armours/BodyArmours/BodyDex2         Quilted Vest            2      3
...
```

### Inspecting an unknown DAT (reverse-engineering aid)

When a future PoE patch shuffles columns and the extractor returns
garbage, the inspector helps re-derive the schema:

```bash
poe-data-extract.exe inspect ^
    --ggpk "C:\path\to\Bundles2\_.index.bin" ^
    --table BaseItemTypes ^
    --output baseitemtypes-inspect.txt
```

The dump shows: header bytes, BB marker location, auto-detected
`rowSize`, side-by-side hex of the first 3 rows, the start of the data
section, and a heuristic guess at which 8-byte row positions look like
string refs into the data section.

### Extracting raw files (e.g. shaders)

```bash
poe-patcher.exe extract ^
    --ggpk "C:\path\to\Bundles2\_.index.bin" ^
    --path  shaders/minimap_visibility_pixel.hlsl ^
    --output minimap_visibility_pixel.hlsl
```

### Applying the shader maphack patch (Phase 2)

```bash
# Apply
poe-patcher.exe apply  --ggpk "C:\path\to\Bundles2\_.index.bin" --patch minimap

# Revert (uses BackupManager — originals are stored next to the GGPK
# under backups/<patch-name>/)
poe-patcher.exe revert --ggpk "C:\path\to\Bundles2\_.index.bin" --patch minimap
```

## What we learned about PoE2's `.datc64`

Documenting this so the next person who hits a schema break has a
head-start.

- **Location**: under `data/balance/` (lowercase!), not `Data/`.
- **Extension**: `.datc64` — the `c` is **not** a compression marker.
  Byte format is identical to PoE1 `.dat64` (uncompressed UTF-16
  strings, `FE FE FE FE FE FE FE FE` null-string sentinels, an
  `0xBBBBBBBBBBBBBBBB` boundary marker between rows and data section).
- **Marker alignment**: PoE1 scanners step 8 bytes from offset 4 to
  find the marker. PoE2's `BaseItemTypes.datc64` has its marker at
  file offset `0x141028` — that's **8-byte-aligned from file start,
  NOT 8-aligned-from-offset-4**. `DatReader` here scans in 4-byte
  steps, which catches both layouts. (See the comment in
  `DatReader.cs::FindMarker` for the historical bug.)
- **String-ref encoding**: legacy PoE1 reserved the first 8 bytes of
  the data section as a null/empty-string sentinel, and ref values
  were absolute byte offsets. PoE2 packs the first real string at
  byte 0 of the data section but kept the original ref encoding —
  effectively `ref = actual_offset + 8`. `DatReader.RowString` strips
  the bias transparently. `ref == 0` is reserved for null/empty.
- **`BaseItemTypes` schema (PoE2 0.x, May 2026)**:
  - `rowSize = 308` (auto-detected via the BB-marker scan above)
  - `@0x00`  int64 string-ref → Id   ("Metadata/Items/Currency/...")
  - `@0x18`  int32             → InventoryWidth
  - `@0x1C`  int32             → InventoryHeight
  - `@0x20`  int64 string-ref → display Name

## Usage from PoEformance

The AHK host invokes these tools via `Run` / `RunWait`. Communication
is **file-based only** — args in, files out, exit code for success /
failure. No stdin/stdout streaming, no shared memory. This keeps the
AGPL boundary unambiguous.

## ⚠ Detection & TOS notes (for `PoePatcher` users)

`PoeDataExtract` is read-only — it only opens `Content.ggpk` /
`_.index.bin` for reading and writes its output to disk. **No game
files are modified.** This is the same kind of operation the game
itself performs at every startup.

`PoePatcher`, by contrast, **modifies game files**. Two things to know:

1. GGG can — and does — verify game file integrity by hash. A modified
   `Content.ggpk` / bundle is detectable server-side regardless of how
   the patch was applied.
2. Modifying client files is more explicitly forbidden by the PoE2
   Terms of Service than passive memory reading.

If you decide to ship `PoePatcher` patches publicly, make sure your
release notes are crystal clear about what's modified and why.

## Layout

```
ggpk-tools/
├── LICENSE                       AGPL-3.0 notice
├── README.md                     this file
├── .gitignore                    bin/ obj/ + extract / inspect output
├── Directory.Build.props         shared .NET settings + LibGGPK3 root path
├── PoE2Tools.sln                 solution
├── PoeDataExtract/               Phase 1 — read GGPK / bundle index → TSV
│   ├── PoeDataExtract.csproj
│   ├── Program.cs                CLI entry — extract / inspect / ls
│   ├── GgpkOpener.cs             opens .ggpk OR .index.bin uniformly
│   ├── DatReader.cs              .dat64 / .datc64 parser (auto-rowSize)
│   ├── DatInspector.cs           schema reverse-engineering helper
│   └── Extractors/
│       ├── IExtractor.cs
│       └── BaseItemSizes.cs      writes base_item_sizes.tsv
└── PoePatcher/                   Phase 2 — write GGPK / bundle index
    ├── PoePatcher.csproj
    ├── Program.cs                CLI entry — apply / revert / extract / list
    ├── GgpkOpener.cs             (duplicate of the one in PoeDataExtract)
    ├── BackupManager.cs          stores originals in <ggpkdir>/backups/
    └── Patches/
        ├── IPatch.cs             interface
        └── MinimapPatch.cs       full-minimap-reveal via shader edits
```

## License boundary — how it's enforced

- This directory has its own `LICENSE` (AGPL-3.0). The repo-root
  `LICENSE` (MIT) governs everything outside.
- The AHK host (root project) **never links** any binary or DLL built
  from this directory. Communication is shell-out + filesystem only.
- Build artefacts (`bin/`, `obj/`, `*/publish/`) are git-ignored.
- Local extracts (`*.tsv`, `*.datc64`, `*.hlsl`, `*-inspect.txt`) are
  git-ignored — they're either derived data we don't want to vendor or
  output of running the tools against a live install.
- `oo2core_*.dll` is git-ignored — proprietary, users supply their own.
