# Contributing to PoEformance

Thanks for taking the time to look at this. Patches, bug reports, ideas — all welcome. The notes below are the conventions the project has settled into; following them keeps reviews short and the history readable.

---

## Reporting issues

A useful bug report includes:

- **What happened** vs. **what you expected** — one sentence each is fine.
- **Game patch version** the bug shows up on (PoE2's UI footer, e.g. `0.9.1a.2026.33.13`). Memory layouts and shader markers shift between patches, so this is the single most important field.
- **PoEformance version** (top-left of the in-app header, e.g. `v4.4.0.14`).
- **Reproduction steps** — even three lines is enough most of the time.
- **Logs / screenshots** if they're handy. `InGameStateMonitor.error.log` next to the exe captures most crash details automatically.

If you're not sure whether it's a bug or a config quirk, open the issue anyway — clarifying is cheaper than gating.

## Suggesting features

Open an issue describing the use-case, not the implementation. "I want to see X while doing Y, currently I have to Z" lands better than "add a button that calls function W."

If you have a concrete design in mind, sketch it in the issue body or comment with a screenshot mock-up — saves a round-trip.

---

## Development setup

### Prerequisites
- **AutoHotkey v2** — the project is AHK v2 throughout, **not** v1. v1 scripts won't run.
- **WebView2 Runtime** — ships with modern Windows, but verify with `Get-AppxPackage *WebView2*` if the UI panel is blank.
- **.NET 8 SDK** — only if you're touching `ggpk-tools/` (the C# data extractor + GGPK patcher).
- **Python 3.10+** — only for the legacy data-extraction scripts under `tools/` (the C# port in `ggpk-tools/` is the preferred path now).

### Running uncompiled
```
AutoHotkey64.exe InGameStateMonitor.ahk
```
Drop `InGameStateMonitor.ahk` onto AHK or set it as the file association — that's the development loop. Source edits take effect on the next launch, no build step.

### Building the compiled `.exe`
```
Ahk2Exe.exe /in InGameStateMonitor.ahk /out InGameStateMonitor.exe
```
Most users will never need to do this; `DEV_README.md` covers the production-packaging details.

### Building `ggpk-tools`
```
cd ggpk-tools
dotnet publish PoeDataExtract -c Release -r win-x64 --self-contained -p:PublishAot=true
dotnet publish PoePatcher     -c Release -r win-x64 --self-contained -p:PublishAot=true
```
The AHK side shells out to these binaries — rebuild whenever you change the C# source, otherwise the running app keeps using the previous binary.

---

## Code conventions

### Language
**Everything committed is in English.** Source code, comments, commit messages, PR titles/bodies, issue text. The native language of contributors is mixed (the maintainer is a German speaker), but the project stays in English so future contributors and public reviewers aren't blocked. If you're more comfortable writing in another language, draft locally then translate inline before committing — don't ask for translation help, just do it.

### File layout
- Keep `.ahk` files reasonably small. When a file grows past a few hundred lines and develops obvious feature boundaries, split it into a new module and `#Include` it from the entry point.
- Functions get a **short 2–3 line comment** explaining purpose, parameters, and return value. Not a doc-comment ceremony; just enough that the next reader doesn't have to trace the body to understand intent.
- Variable names follow the **existing camelCase / snake_case style of the surrounding code** — don't try to normalise the codebase to one style in your PR.

### AHK-specific
- AHK v2 only. If you find yourself writing `MsgBox, %var%` (comma-and-percent syntax), you're on v1.
- Prefer `Map()` over plain objects when the keys are dynamic or non-identifier.
- Use `try`/`catch` around external calls (memory reads, Run, etc.); raw exceptions kill the script.
- For new shared state, declare a global in the obvious place (usually `InGameStateMonitor.ahk` near the top), then `global` it into the function that uses it — AHK v2 does not auto-capture globals.

### C# (ggpk-tools)
Standard `.editorconfig`-style formatting. No hard rules beyond "match the surrounding file." Public types/methods get XML doc-comments; private helpers usually just need an inline `//` if their intent isn't obvious from the name.

### Reverse-engineering changes
When you add or change a pattern scan, offset, or shader-marker string:
- Comment the **what** (which game version you verified against) and the **why** (what the structure represents).
- If you replaced an old marker because the shader/struct changed in a patch, leave a one-line note about the previous form so the next person debugging a regression has a trail.

A good live example sits in `ggpk-tools/PoePatcher/Patches/MinimapPatch.cs` — the docstring there carries the pipeline diagram for the minimap shaders, which is what made the last round of debugging tractable.

---

## Commit messages

- **Title:** under 70 chars, imperative mood, no trailing period. `Header: pin window controls top-right` reads better than `Pinned the window controls`.
- **Body:** wrap at ~72 chars. Explain the *why* and any non-obvious context. The diff already shows the *what*. Multi-paragraph bodies are fine and encouraged for non-trivial changes.
- Group prefixes by area when it helps scanning: `MinimapPatch:`, `Header:`, `Config tab:`, `AutoPilot:`, etc. The existing log is a good reference for tone.
- Prefer **new commits** over `--amend` once a branch has been pushed. The exception is a typo fix in the head commit before the first push.

---

## Pull requests

1. **Branch off `master`.** Name it descriptively (`fix/maphack-bleed`, `feat/loot-filter`, etc.).
2. **Keep PRs focused.** One conceptual change per PR is the goal. If you find yourself writing the body in three unrelated sections, split it into two PRs.
3. **PR title** follows the same conventions as a commit title.
4. **PR body** explains the problem, the approach, and any caveats. A short test plan as a checkbox list at the bottom is appreciated — even just three boxes — so the maintainer knows what you actually verified.
5. **Self-review first.** Read your own diff in the GitHub UI before requesting review; you'll catch half the issues a reviewer would have flagged.
6. **CI / hooks** must pass. If a hook fails, fix the underlying issue rather than skipping it.

A merged PR's commits land in `master` as-is (or as a single squash, at the maintainer's discretion), so good commit hygiene during development pays off at merge time.

---

## Repository structure (quick orientation)

```
InGameStateMonitor.ahk     Entry point — boots the main loop, owns most globals
*.ahk                      Feature modules (#Included from the entry point)
ui/index.html              The WebView2 UI (HTML/CSS/JS, single file)
ggpk-tools/                .NET 8 CLI tools (data extractor + GGPK patcher) — AGPL-3.0
Lib/                       Third-party AHK helpers (WebViewToo, JsonParser, etc.)
data/                      TSVs the extractor writes; read at runtime
external/                  Vendored upstream libs (LibGGPK3, etc.)
assets/                    Icons, logos
DEV_README.md              Architecture deep-dive: memory layout, pattern scanning, panel discovery
CLAUDE.md                  Project conventions distilled for AI pair-programming sessions
```

`DEV_README.md` is the right starting point if you're touching the memory reader, overlay engine, or anything that talks to the game directly.

---

## Licensing

- The **AHK side** of the project (`*.ahk`, `ui/`, `Lib/`, `data/`, `assets/`) is — barring third-party vendored libs that carry their own headers — under the project root license. Check the repo root for the current declaration.
- **`ggpk-tools/`** is **AGPL-3.0** (see `ggpk-tools/LICENSE`). Contributions to that subtree are accepted under the same license. If your contribution mixes both subtrees, the AGPL-3.0 applies to the `ggpk-tools/` portion.
- Vendored upstream libraries (`external/LibGGPK3` and similar) keep their original licenses; don't relicense them.

By submitting a contribution you confirm that you have the right to license it under the terms above.

---

## Reference projects

When you start on a new feature, it's worth a quick look at **`https://gitlab.com/g0rdin/gamehelper2`** (branch `arsenic`) — the C# reference project this codebase originated from. Solutions or pattern-scanning approaches you'll need may already be solved there in a form you can port.

For PoE2-specific data structures, `DEV_README.md` carries the running inventory of known offsets and components.

---

## Getting help

- **Code questions:** open a draft PR or an issue tagged `question`. Lower-friction than landing in chat.
- **Sensitive reports** (e.g. you found something that could harm other users): email the maintainer at the address in the GitHub profile, don't open a public issue.

That's everything. Thanks again for contributing.
