# Security Policy

## Supported versions

Only the **latest release** receives security fixes. Older builds are not back-patched — if you're on an older version and hit a security issue, the answer will be to update.

| Version  | Supported          |
| -------- | ------------------ |
| latest   | :white_check_mark: |
| < latest | :x:                |

## Reporting a vulnerability

**Please do not open a public GitHub issue for security reports.** Use one of the private channels below so we can ship a fix before details are widely known.

- **Preferred:** GitHub's [private vulnerability reporting](https://github.com/imm0r/PoEformance/security/advisories/new) form (Security tab → "Report a vulnerability"). End-to-end on GitHub, no email round-trip.
- **Email fallback:** `gdthsupp0rt@gmail.com` with `[security]` in the subject line.

A report is more actionable when it includes:

- **What the vulnerability is** in one or two sentences (the impact, not just the symptom).
- **A minimal reproduction** — input file, config snippet, exact steps. The smaller the repro, the faster the fix.
- **Affected version** (in-app header shows the PoEformance version, e.g. `v4.4.0.14`) and **game patch version** if relevant.
- **What you've already tried**, if anything.
- A **suggested fix** if one is obvious to you (very welcome but not required).

You can expect:

- **Acknowledgement within 72 hours** that the report was received and is being looked at.
- **A first assessment within 7 days** — whether it's confirmed, what severity it looks like, and a rough timeline.
- **Credit in the release notes / advisory** when the fix ships, unless you prefer to stay anonymous.
- **Coordinated disclosure**: once a fix is released, the advisory is published with the technical details. We'd appreciate you holding public write-ups until then.

## In scope

The kind of issues we treat as security:

- **Code execution** triggered by something a user could realistically load — a crafted config file (`ConfigManager.ini`), `data/*.tsv`, a malformed memory layout, or a JS payload reaching the WebView2 UI.
- **Path traversal** in the GGPK patch / backup / revert flow (`PoePatcher` writing or reading outside its sandbox).
- **Bridge handler abuse**: arguments to `ahkCall` handlers being forwarded to `Run`, `Shell`, file I/O, or external processes without validation. The `OpenUrl` handler in `BridgeDispatch.ahk` is an example of the shape — anything similar belongs here.
- **WebView2 / UI**: XSS, prototype pollution, or trivial UI redirects via attacker-controlled data piped into the page.
- **Memory-corruption** in the AHK side from a malicious or unexpected response shape from the game process.
- **Supply chain**: a vendored or downloaded library in `external/`, `Lib/`, or the ggpk-tools NuGet/.csproj dependency tree that ships with a known CVE.
- **Privacy regressions**: the tool unexpectedly transmitting user data (memory contents, file paths, etc.) anywhere off the local machine.

## Out of scope

These are *not* security issues for this project — please use a regular issue (or no issue at all):

- **"The tool modifies game files / reads game memory."** That's the whole project. It's by design and clearly documented.
- **"Using it might violate the game's TOS / get me banned."** Also true and outside what we can fix. It's a third-party game tool; use at your own risk.
- **Reports of anti-cheat detection.** Not a vulnerability in this codebase.
- **Self-XSS or local-only "exploits"** that require the attacker to already have control of the user's machine.
- **Issues in the game itself** (Path of Exile 2) — report those to Grinding Gear Games directly.
- **Missing security-hardening features** that don't correspond to an actual exploit (e.g. "you should add CSP headers to the WebView panel" without a demonstrated vector).
- **Crashes in normal operation** — those are bugs, file them as regular issues with the `bug` label.

## Safe harbor

Good-faith security research on this project is welcome. As long as you:

- don't exfiltrate data beyond what's needed to demonstrate the vulnerability,
- don't degrade the experience for other users,
- and give us a reasonable window to ship a fix before going public,

we won't pursue any kind of action against you for the research itself. If you're unsure whether something is in scope, ask first via the channels above — we'd rather hear about a borderline case than not at all.
