#!/usr/bin/env node
// MCP server exposing PoEformance live game data + write surface to an AI
// assistant. It talks to the local HTTP API that PoEformance serves on
// 127.0.0.1 (enable it in Config -> General -> Integrations -> "Local API").
//
// Mirrors the approach of NattKh/POE2Radar's mcp-server, adapted to
// PoEformance's data model (groups / alerts / config / watchlist).
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const HOST = "127.0.0.1";
const PORT = process.env.POEFORMANCE_API_PORT || "7777";

// Build the request URL from a constant loopback origin. Only the path and
// query string come from the caller; the scheme/host/port are fixed literals,
// so the request destination can never be redirected away from the local app
// (avoids the server-side request forgery class CodeQL flags on tainted URLs).
function buildUrl(path) {
  const q = path.indexOf("?");
  const url = new URL("http://localhost");
  url.hostname = HOST;
  url.port = String(PORT);
  url.pathname = q === -1 ? path : path.slice(0, q);
  url.search = q === -1 ? "" : path.slice(q);
  return url;
}

// Thin fetch wrapper. Returns parsed JSON, or a small error object when the
// app/API is unreachable (so tool calls degrade gracefully instead of throwing).
async function api(path, method = "GET", body = null) {
  const opts = { method, headers: {} };
  if (body) {
    opts.headers["Content-Type"] = "application/json";
    opts.body = JSON.stringify(body);
  }
  try {
    const r = await fetch(buildUrl(path), opts);
    const text = await r.text();
    try {
      return JSON.parse(text);
    } catch {
      return text;
    }
  } catch (e) {
    return { error: `Cannot reach PoEformance at http://${HOST}:${PORT}. Is the app running with the Local API enabled? (${e.message})` };
  }
}

function jsonText(obj) {
  return { content: [{ type: "text", text: JSON.stringify(obj, null, 2) }] };
}

const server = new McpServer({ name: "poeformance", version: "1.0.0" });

// ── Game state ────────────────────────────────────────────────────────────────

server.tool(
  "game_state",
  "Get the current game state: connection, area name/level/hash, town/hideout flags, player life/mana/energy-shield, and awake/sleeping entity counts.",
  {},
  async () => jsonText(await api("/state"))
);

// ── Entities ──────────────────────────────────────────────────────────────────

server.tool(
  "get_entities",
  "List entities in the current zone. Optional filters: type (Player/Minion/Enemy/Boss/NPC/Chest/Strongbox/WorldItem/AreaTransition/Waypoint/Checkpoint/Object), alive only, free-text search over path/name, max distance, and a result limit.",
  {
    type: z.string().optional().describe("Classification filter, e.g. Enemy, Boss, NPC, Chest"),
    alive: z.boolean().optional().describe("Only alive entities"),
    search: z.string().optional().describe("Substring matched against metadata path and name"),
    radius: z.number().optional().describe("Max distance (game units) from the player"),
    limit: z.number().optional().describe("Max results (default 100)"),
    includeComponents: z.boolean().optional().describe("Include the verbose per-entity component dump (default false)"),
  },
  async ({ type, alive, search, radius, limit, includeComponents }) => {
    const data = await api("/entities");
    if (data && data.error) return jsonText(data);
    let items = (data && Array.isArray(data.items)) ? data.items : [];
    if (type) items = items.filter((e) => (e.type || "").toLowerCase() === type.toLowerCase());
    if (alive) items = items.filter((e) => e.alive);
    if (typeof radius === "number") items = items.filter((e) => e.dist >= 0 && e.dist <= radius);
    if (search) {
      const q = search.toLowerCase();
      items = items.filter((e) => (e.path || "").toLowerCase().includes(q) || (e.name || "").toLowerCase().includes(q));
    }
    if (!includeComponents) items = items.map(({ components, ...rest }) => rest);
    items = items.slice(0, limit || 100);
    return jsonText({ total: items.length, items });
  }
);

// ── Groups (path-based entity grouping with colors) ─────────────────────────────

server.tool(
  "get_groups",
  "List the user's entity groups (name, comma-separated match terms, color, enabled).",
  {},
  async () => jsonText(await api("/api/groups"))
);

server.tool(
  "set_groups",
  "Replace the entire entity-group list. Pass the full array; persisted and reflected on the radar/UI.",
  {
    groups: z.array(z.object({
      name: z.string(),
      terms: z.string().describe("Comma-separated substrings matched against the entity path/metaGroup"),
      color: z.string().optional().describe("Hex color like #3aa0ff"),
      enabled: z.boolean().optional(),
    })).describe("The complete groups list"),
  },
  async ({ groups }) => {
    const payload = groups.map((g) => ({ name: g.name, terms: g.terms, color: g.color || "#3aa0ff", enabled: g.enabled !== false }));
    return jsonText(await api("/api/groups", "POST", payload));
  }
);

server.tool(
  "add_group",
  "Add a single entity group (fetches the current list, appends, saves).",
  {
    name: z.string(),
    terms: z.string().describe("Comma-separated match substrings"),
    color: z.string().optional().describe("Hex color like #ff5555"),
  },
  async ({ name, terms, color }) => {
    const cur = await api("/api/groups");
    const list = Array.isArray(cur) ? cur : [];
    list.push({ name, terms, color: color || "#3aa0ff", enabled: true });
    return jsonText(await api("/api/groups", "POST", list));
  }
);

server.tool(
  "remove_group",
  "Remove an entity group by name (fetches the current list, filters, saves).",
  { name: z.string().describe("Group name to remove") },
  async ({ name }) => {
    const cur = await api("/api/groups");
    const list = Array.isArray(cur) ? cur.filter((g) => g.name !== name) : [];
    return jsonText(await api("/api/groups", "POST", list));
  }
);

// ── Alerts ──────────────────────────────────────────────────────────────────

server.tool(
  "get_alerts",
  "Get the entity-alert engine configuration (conditions, timing, outputs) and the available WAV files.",
  {},
  async () => jsonText(await api("/api/alerts"))
);

server.tool(
  "set_alert",
  "Set one alert setting by key (e.g. g_alertsEnabled, g_alertOnUnique, g_alertPathWatch, g_alertMaxDistance, g_alertBanner, g_alertSound). Booleans accept true/false.",
  {
    key: z.string().describe("Alert config key, e.g. g_alertsEnabled"),
    value: z.union([z.string(), z.number(), z.boolean()]).describe("New value"),
  },
  async ({ key, value }) => jsonText(await api("/api/alerts", "POST", { key, value }))
);

// ── Settings ──────────────────────────────────────────────────────────────────

server.tool(
  "get_config",
  "Get the current adjustable settings (thresholds, radar/overlay toggles, alpha, automation flags).",
  {},
  async () => jsonText(await api("/api/config"))
);

server.tool(
  "update_config",
  "Update settings. Pass any subset. Booleans: radarEnabled, playerHud, mapHack, zoneNav, rangeCircles, autoFlask, autoPilot, debug, paused, overlayStatusText, panelDetection. Numbers: lifeThreshold (0-100), manaThreshold (0-100), radarAlpha (0-255).",
  { settings: z.record(z.any()).describe("Key-value pairs to change, e.g. {radarEnabled: true, lifeThreshold: 60}") },
  async ({ settings }) => jsonText(await api("/api/config", "POST", settings))
);

// ── Watchlist (pinned entity paths shown in the tree/overlay) ───────────────────

server.tool(
  "get_watchlist",
  "List the currently pinned entity node paths (the watchlist).",
  {},
  async () => jsonText(await api("/api/watchlist"))
);

server.tool(
  "pin_entity",
  "Pin an entity node path to the watchlist.",
  { path: z.string().describe("The node path to pin") },
  async ({ path }) => jsonText(await api("/api/watchlist", "POST", { path }))
);

server.tool(
  "unpin_entity",
  "Remove one path from the watchlist.",
  { path: z.string().describe("The pinned path to remove") },
  async ({ path }) => jsonText(await api(`/api/watchlist?path=${encodeURIComponent(path)}`, "DELETE"))
);

server.tool(
  "clear_watchlist",
  "Remove every pinned path from the watchlist.",
  {},
  async () => jsonText(await api("/api/watchlist", "DELETE"))
);

// ── Name database ──────────────────────────────────────────────────────────────

server.tool(
  "search_names",
  "Search the monster name table (metadata path <-> display name) by keyword. Useful for finding the right path/term for a group or path-watch alert.",
  { query: z.string().describe("Search term, e.g. 'Zombie', 'Primate', 'Boss'") },
  async ({ query }) => jsonText(await api(`/api/names?q=${encodeURIComponent(query)}`))
);

const transport = new StdioServerTransport();
await server.connect(transport);
