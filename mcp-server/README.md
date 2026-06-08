# PoEformance MCP server

A [Model Context Protocol](https://modelcontextprotocol.io) server that lets an
AI assistant (Claude Desktop, Claude Code, etc.) read PoEformance's **live game
data** and change its settings while you play.

It is a thin proxy in front of the small HTTP API that PoEformance itself serves
on `127.0.0.1`. That API is **off by default** — it only listens once you opt in.

## How it fits together

```
AI client  ──stdio──▶  mcp-server (node)  ──HTTP──▶  PoEformance (AHK)  ──▶  PoE2 memory
                                            127.0.0.1:7777
```

PoEformance hosts the HTTP server in `ahk/LocalApiServer.ahk` (Winsock, loopback
only, event-driven so the radar hot path is never blocked).

## 1. Enable the API in PoEformance

In the app: **Config → General → Integrations → "Local API (MCP backend)"** → on.
The server binds `127.0.0.1:7777`. **Restart the app** after enabling (the
listener starts at launch). The port can be changed in
`poeformance_config.ini` under `[LocalApi] port=...`.

## 2. Install the MCP server

Requires Node.js 18+ (global `fetch`).

```sh
cd mcp-server
npm install
```

## 3. Register it with your AI client

Example `claude_desktop_config.json` / MCP client config entry:

```json
{
  "mcpServers": {
    "poeformance": {
      "command": "node",
      "args": ["C:/path/to/PoEformance/mcp-server/index.js"],
      "env": { "POEFORMANCE_API_PORT": "7777" }
    }
  }
}
```

`POEFORMANCE_API_PORT` is optional (defaults to `7777`).

### Local Claude Code (same machine as the game)

The repo ships a project-scoped [`.mcp.json`](../.mcp.json) at its root:

```json
{
  "mcpServers": {
    "poeformance": { "command": "node", "args": ["mcp-server/index.js"] }
  }
}
```

When you run Claude Code **locally on the machine that runs PoEformance**, it
picks this up automatically (it prompts once to approve the project MCP server).
The relative path works because Claude Code launches MCP servers with the
project root as the working directory — so the same coding session can edit the
code *and* call the live tools. This only works locally: a remote/cloud Claude
Code session has no network path to your PC's `127.0.0.1:7777`, and the API is
loopback-only by design (it can write settings), so don't expose it to reach it
from the cloud.

## Tools

| Tool | What it does |
|------|--------------|
| `game_state` | Area, town/hideout, life/mana/ES, entity counts |
| `get_entities` | Entities in zone, filter by type/alive/search/radius/limit |
| `get_groups` / `set_groups` / `add_group` / `remove_group` | Path-based entity groups |
| `get_alerts` / `set_alert` | Entity-alert engine config |
| `get_config` / `update_config` | Thresholds, radar/overlay toggles, alpha, automation |
| `get_watchlist` / `pin_entity` / `unpin_entity` / `clear_watchlist` | Pinned entity paths |
| `search_names` | Look up monster metadata path ↔ display name |

## HTTP API reference

| Method | Path | Body / query | Purpose |
|--------|------|--------------|---------|
| GET | `/state` | — | Live game state |
| GET | `/entities` | — | `{ total, items[] }` of zone entities |
| GET | `/api/groups` | — | Entity group list |
| POST | `/api/groups` | `[{name,terms,color,enabled}]` | Replace group list |
| GET | `/api/alerts` | — | Alert config |
| POST | `/api/alerts` | `{key,value}` | Set one alert setting |
| GET | `/api/config` | — | Current settings |
| POST | `/api/config` | `{key:value,…}` | Update settings |
| GET | `/api/watchlist` | — | Pinned paths |
| POST | `/api/watchlist` | `{path}` | Pin a path |
| DELETE | `/api/watchlist` | `?path=…` (omit to clear all) | Unpin |
| GET | `/api/names` | `?q=…` | Search monster name table |

## Security

The API is loopback-only (`127.0.0.1`) and opt-in. It still exposes a write
surface (settings, groups, alerts, watchlist), so only enable it when you want an
assistant — or other local tooling — to drive the app.
