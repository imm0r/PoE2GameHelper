#!/usr/bin/env python3
"""
compare_offsets.py
Vergleicht PoE2Offsets.ahk / StaticOffsetsPatterns.ahk mit dem aktuellen
C#-Stand von https://gitlab.com/bylafko/gamehelper2.

Führt eine versionierte Änderungshistorie mit Klassifizierung (fix / game_update).
Analysiert Delta-Muster zur Vorhersage zukünftiger Änderungen.

Verwendung:
  python compare_offsets.py              # Aktuellen Diff anzeigen (fetcht automatisch)
  python compare_offsets.py --no-fetch   # Diff ohne Online-Abfrage
  python compare_offsets.py --record     # Diff in History aufnehmen (interaktiv)
  python compare_offsets.py --history    # Historische Änderungen anzeigen
  python compare_offsets.py --predict    # Delta-Muster für Vorhersagen analysieren
"""

import re, json, sys, subprocess, argparse
from pathlib import Path
from datetime import date
from collections import defaultdict

# ── Pfade ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR   = Path(__file__).parent
ROOT_DIR     = SCRIPT_DIR.parent          # GameHelper/ (tools/ liegt eine Ebene höher)
AHK_OFFSETS  = ROOT_DIR / "PoE2Offsets.ahk"
AHK_PATTERNS = ROOT_DIR / "StaticOffsetsPatterns.ahk"
PATCH_FILE   = ROOT_DIR / "last_known_patch.txt"
HISTORY_FILE = ROOT_DIR / "offset_history.json"
CACHE_DIR    = ROOT_DIR / ".upstream_cache"

GITLAB_URL   = "https://gitlab.com/bylafko/gamehelper2"
CS_OFFSETS_REL = "GameOffsets"   # Pfad innerhalb des Repos

# ── Hilfsfunktionen ────────────────────────────────────────────────────────────
CYAN  = "\033[96m"; GREEN = "\033[92m"; RED   = "\033[91m"
YELLOW= "\033[93m"; BOLD  = "\033[1m";  RESET = "\033[0m"

def c(text, color): return f"{color}{text}{RESET}" if sys.stdout.isatty() else text

def norm_hex(val: str) -> str:
    """Normalisiert einen Hex-Wert zu 0xHHH (Großbuchstaben, minimale Stellen)."""
    v = val.strip().lower()
    if v.startswith("0x"):
        stripped = v[2:].lstrip("0") or "0"
        return "0x" + stripped.upper()
    try:
        return "0x" + hex(int(v))[2:].upper()
    except ValueError:
        return val

def norm_struct(name: str) -> str:
    """Entfernt gängige Suffixe für Struct-Namenabgleich."""
    for suf in ("Offsets", "Offset", "Data", "Struct"):
        if name.endswith(suf) and len(name) > len(suf):
            return name[:-len(suf)]
    return name

def game_version() -> str:
    try:
        return PATCH_FILE.read_text(encoding="utf-8-sig").strip()
    except FileNotFoundError:
        return "unknown"

def upstream_commit() -> str:
    try:
        out = subprocess.check_output(
            ["git", "-C", str(CACHE_DIR), "rev-parse", "--short", "HEAD"],
            stderr=subprocess.DEVNULL
        )
        return out.decode().strip()
    except Exception:
        return "unknown"


# ── Git Fetch ──────────────────────────────────────────────────────────────────
def fetch_upstream(verbose=True) -> bool:
    """Klont oder pullt das GitLab-Repo in CACHE_DIR."""
    if not CACHE_DIR.exists():
        print(f"  Klone {GITLAB_URL} …")
        try:
            subprocess.check_call(
                ["git", "clone", "--depth=1", GITLAB_URL, str(CACHE_DIR)],
                stdout=subprocess.DEVNULL if not verbose else None,
                stderr=subprocess.STDOUT if not verbose else None
            )
            print("  ✓ Klon abgeschlossen")
            return True
        except subprocess.CalledProcessError:
            print(c("  ✗ Klon fehlgeschlagen — kein Internet oder git nicht verfügbar", RED))
            return False
    else:
        try:
            result = subprocess.run(
                ["git", "-C", str(CACHE_DIR), "pull", "--depth=1", "--rebase"],
                capture_output=True, text=True, timeout=30
            )
            if "Already up to date" in result.stdout or "up to date" in result.stdout.lower():
                print("  ✓ Upstream bereits aktuell")
            else:
                print("  ✓ Upstream aktualisiert")
            return True
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            print(c("  ⚠ Pull fehlgeschlagen — arbeite mit gecachtem Stand", YELLOW))
            return True  # Cache vorhanden, kann trotzdem vergleichen


# ── AHK Parsing ───────────────────────────────────────────────────────────────
def parse_ahk_offsets(path: Path) -> dict:
    """Returns {map_name: {field: "0xHH"}} aus PoE2Offsets.ahk."""
    text = path.read_text(encoding="utf-8")
    result = {}
    for m in re.finditer(r'static\s+(\w+)\s*:=\s*Map\s*\((.*?)\)', text, re.DOTALL):
        map_name = m.group(1)
        body = m.group(2)
        fields = {}
        for entry in re.finditer(r'"(\w+)"\s*,\s*(0x[0-9A-Fa-f]+|-?\d+)', body):
            key, val = entry.group(1), entry.group(2).strip()
            fields[key] = norm_hex(val)
        if fields:
            result[map_name] = fields
    return result

def parse_ahk_patterns(path: Path) -> dict:
    """Returns {name: pattern_str} aus StaticOffsetsPatterns.ahk."""
    if not path.exists():
        return {}
    text = path.read_text(encoding="utf-8")
    result = {}
    for m in re.finditer(
        r'Map\s*\(\s*"name"\s*,\s*"([^"]+)"\s*,\s*"pattern"\s*,\s*"([^"]+)"\s*\)', text
    ):
        result[m.group(1)] = m.group(2).strip()
    return result


# ── C# Parsing ────────────────────────────────────────────────────────────────
def parse_cs_offsets(cs_dir: Path) -> dict:
    """
    Returns {struct_name: {"_file": rel_path, field: "0xHH"}}
    aus allen .cs-Dateien im GameOffsets-Verzeichnis.
    """
    if not cs_dir.exists():
        return {}
    result = {}
    field_re  = re.compile(
        r'\[FieldOffset\s*\(\s*(0x[0-9A-Fa-f]+|\d+)\s*\)\]\s+public\s+[\w<>, *?]+\s+(\w+)'
    )
    struct_re = re.compile(r'public\s+struct\s+(\w+)')

    for cs_file in sorted(cs_dir.rglob("*.cs")):
        if any(p in cs_file.parts for p in ("bin", "obj")):
            continue
        text = cs_file.read_text(encoding="utf-8")
        fields = re.findall(field_re, text)
        if not fields:
            continue
        # Primären Struct-Namen ermitteln (Dateiname bevorzugt)
        stem = cs_file.stem
        structs = struct_re.findall(text)
        primary = stem
        for s in structs:
            if s.lower() == stem.lower():
                primary = s
                break
        else:
            if structs:
                primary = structs[0]

        entry = {"_file": str(cs_file.relative_to(cs_dir))}
        for raw_off, field_name in fields:
            if field_name.startswith("PAD_"):
                continue
            entry[field_name] = norm_hex(raw_off)
        if len(entry) > 1:
            result[primary] = entry
    return result

def parse_cs_patterns(cs_dir: Path) -> dict:
    """Returns {name: pattern_str} aus StaticOffsetsPatterns.cs."""
    path = cs_dir / "StaticOffsetsPatterns.cs"
    if not path.exists():
        return {}
    text = path.read_text(encoding="utf-8")
    result = {}
    for m in re.finditer(r'new\s*\(\s*"([^"]+)"\s*,\s*\n?\s*"([^"]+)"', text):
        result[m.group(1)] = m.group(2).strip()
    return result


# ── Struct-Matching ────────────────────────────────────────────────────────────
def build_struct_mapping(ahk: dict, cs: dict) -> dict:
    """Baut {ahk_map_name: cs_struct_name} via normalisiertem Namenabgleich."""
    cs_norm = {norm_struct(k).lower(): k for k in cs}
    mapping = {}
    for ahk_name in ahk:
        key = norm_struct(ahk_name).lower()
        if key in cs_norm:
            mapping[ahk_name] = cs_norm[key]
        elif ahk_name in cs:
            mapping[ahk_name] = ahk_name
    return mapping


# ── Diff ───────────────────────────────────────────────────────────────────────
def compute_diff(ahk: dict, cs: dict, mapping: dict) -> dict:
    """
    Gibt {ahk_map/field: {ahk, cs, cs_struct, cs_file}} zurück.
    Nur Einträge wo ahk != cs oder cs nicht vorhanden.
    """
    diffs = {}
    for ahk_map, fields in ahk.items():
        cs_struct = mapping.get(ahk_map)
        cs_entry  = cs.get(cs_struct, {}) if cs_struct else {}
        cs_file   = cs_entry.get("_file", "?")
        for field, ahk_val in fields.items():
            cs_val = cs_entry.get(field)
            if cs_val is None:
                # Feld existiert nicht in C# — kein Diff, sondern AHK-only
                continue
            if ahk_val != cs_val:
                key = f"{ahk_map}/{field}"
                diffs[key] = {
                    "ahk_map": ahk_map, "field": field,
                    "ahk_val": ahk_val, "cs_val": cs_val,
                    "cs_struct": cs_struct or "?", "cs_file": cs_file
                }
    return diffs

def compute_pattern_diff(ahk_pats: dict, cs_pats: dict) -> dict:
    diffs = {}
    for name, ahk_p in ahk_pats.items():
        cs_p = cs_pats.get(name)
        if cs_p and cs_p != ahk_p:
            diffs[name] = {"ahk": ahk_p, "cs": cs_p}
    return diffs


# ── Diff-Anzeige ───────────────────────────────────────────────────────────────
def show_diff(offset_diff: dict, pattern_diff: dict):
    if not offset_diff and not pattern_diff:
        print(c("✓ Keine Unterschiede — AHK ist synchron mit C#", GREEN))
        return

    if offset_diff:
        print(c(f"\n{'='*60}", BOLD))
        print(c(f"  OFFSET-UNTERSCHIEDE ({len(offset_diff)})", BOLD))
        print(c(f"{'='*60}", BOLD))
        current_map = None
        for key, d in sorted(offset_diff.items()):
            if d["ahk_map"] != current_map:
                current_map = d["ahk_map"]
                print(f"\n  {c(current_map, CYAN)}  →  {d['cs_struct']}  [{d['cs_file']}]")
            pad = " " * 4
            print(f"{pad}{d['field']:<40} AHK={c(d['ahk_val'], RED)}  CS={c(d['cs_val'], GREEN)}")

    if pattern_diff:
        print(c(f"\n{'='*60}", BOLD))
        print(c(f"  PATTERN-UNTERSCHIEDE ({len(pattern_diff)})", BOLD))
        print(c(f"{'='*60}", BOLD))
        for name, d in pattern_diff.items():
            print(f"\n  {c(name, CYAN)}")
            print(f"    AHK: {c(d['ahk'], RED)}")
            print(f"    CS:  {c(d['cs'],  GREEN)}")

    print()


# ── History ───────────────────────────────────────────────────────────────────
def load_history() -> dict:
    if HISTORY_FILE.exists():
        return json.loads(HISTORY_FILE.read_text(encoding="utf-8"))
    return {"schema": 1, "offsets": {}, "patterns": {}}

def save_history(h: dict):
    HISTORY_FILE.write_text(
        json.dumps(h, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    print(c(f"  History gespeichert → {HISTORY_FILE.name}", GREEN))

def _last_value(events: list) -> str | None:
    return events[-1]["ahk_value"] if events else None

def record_changes(offset_diff: dict, pattern_diff: dict,
                   ahk: dict, cs: dict, mapping: dict,
                   ahk_pats: dict, cs_pats: dict,
                   change_type: str | None = None):
    """
    Nimmt aktuellen Diff in die History auf.
    Fragt interaktiv nach Typ (fix/game_update) wenn change_type=None.
    """
    h = load_history()
    gv = game_version()
    commit = upstream_commit()
    today = str(date.today())

    # ── Neue/geänderte Offsets ────────────────────────────────────────────────
    changed_count = 0
    for key, d in offset_diff.items():
        entry = h["offsets"].setdefault(key, {
            "ahk_map": d["ahk_map"], "field": d["field"],
            "cs_struct": d["cs_struct"], "cs_file": d["cs_file"],
            "events": []
        })
        last_val = _last_value(entry["events"])
        if last_val == d["ahk_val"]:
            continue  # Noch nicht gefixt, nichts Neues
        if change_type:
            ct = change_type
            notes = ""
        else:
            print(f"\n  {c(key, CYAN)}: AHK={c(d['ahk_val'], RED)}  CS={c(d['cs_val'], GREEN)}")
            ct = _ask_type()
            notes = input("  Notizen (Enter = leer): ").strip()
        event = {
            "date": today,
            "game_version": gv,
            "cs_commit": commit,
            "ahk_value": d["ahk_val"],
            "cs_value": d["cs_val"],
            "change_type": ct,
            "notes": notes
        }
        entry["events"].append(event)
        changed_count += 1

    # ── Unveränderte (aktuell in Sync) als Initial aufnehmen ─────────────────
    init_count = 0
    for ahk_map, fields in ahk.items():
        cs_struct = mapping.get(ahk_map)
        cs_entry  = cs.get(cs_struct, {}) if cs_struct else {}
        cs_file   = cs_entry.get("_file", "?")
        for field, ahk_val in fields.items():
            cs_val = cs_entry.get(field)
            if cs_val is None or cs_val != ahk_val:
                continue
            key = f"{ahk_map}/{field}"
            entry = h["offsets"].setdefault(key, {
                "ahk_map": ahk_map, "field": field,
                "cs_struct": cs_struct or "?", "cs_file": cs_file,
                "events": []
            })
            if not entry["events"]:
                entry["events"].append({
                    "date": today,
                    "game_version": gv,
                    "cs_commit": commit,
                    "ahk_value": ahk_val,
                    "cs_value": cs_val,
                    "change_type": "initial",
                    "notes": ""
                })
                init_count += 1

    # ── Patterns ──────────────────────────────────────────────────────────────
    for name, d in pattern_diff.items():
        entry = h["patterns"].setdefault(name, {"events": []})
        if change_type:
            ct, notes = change_type, ""
        else:
            print(f"\n  PATTERN {c(name, CYAN)}")
            ct = _ask_type()
            notes = input("  Notizen (Enter = leer): ").strip()
        entry["events"].append({
            "date": today,
            "game_version": gv,
            "cs_commit": commit,
            "ahk_value": d["ahk"],
            "cs_value": d["cs"],
            "change_type": ct,
            "notes": notes
        })

    for name, ahk_p in ahk_pats.items():
        cs_p = cs_pats.get(name)
        if cs_p and cs_p == ahk_p:
            entry = h["patterns"].setdefault(name, {"events": []})
            if not entry["events"]:
                entry["events"].append({
                    "date": today, "game_version": gv, "cs_commit": commit,
                    "ahk_value": ahk_p, "cs_value": cs_p,
                    "change_type": "initial", "notes": ""
                })

    save_history(h)
    print(f"  {changed_count} Änderungen aufgezeichnet, {init_count} Baseline-Einträge angelegt")

def _ask_type() -> str:
    while True:
        t = input("  Typ [f=fix / g=game_update]: ").strip().lower()
        if t in ("f", "fix"):    return "fix"
        if t in ("g", "game_update", "gu"): return "game_update"
        print("  Bitte 'f' oder 'g' eingeben.")


# ── History-Anzeige ───────────────────────────────────────────────────────────
def show_history(filter_type: str | None = None):
    h = load_history()
    all_events = []
    for key, entry in h.get("offsets", {}).items():
        for ev in entry["events"]:
            if filter_type and ev["change_type"] != filter_type:
                continue
            if ev["change_type"] == "initial":
                continue
            all_events.append((ev["date"], "offset", key, ev))
    for name, entry in h.get("patterns", {}).items():
        for ev in entry["events"]:
            if filter_type and ev["change_type"] != filter_type:
                continue
            if ev["change_type"] == "initial":
                continue
            all_events.append((ev["date"], "pattern", name, ev))

    if not all_events:
        print(c("Keine Änderungen in der History (nur initial-Einträge).", YELLOW))
        return

    all_events.sort(key=lambda x: x[0], reverse=True)
    current_gv = None
    for d, kind, key, ev in all_events:
        if ev["game_version"] != current_gv:
            current_gv = ev["game_version"]
            print(c(f"\n── Spielversion {current_gv} ({'game_update' if ev['change_type']=='game_update' else 'fix'}) ──", BOLD))
        sym = c("▲ FIX", YELLOW) if ev["change_type"] == "fix" else c("⚡ GAME_UPDATE", CYAN)
        print(f"  {sym}  {key}")
        print(f"         AHK: {c(ev['ahk_value'], RED)}  →  CS: {c(ev['cs_value'], GREEN)}  [{d}]")
        if ev.get("notes"):
            print(f"         📝 {ev['notes']}")
    print()


# ── Predict ───────────────────────────────────────────────────────────────────
def show_predictions():
    h = load_history()
    # Für jedes Struct: sammle alle game_update-Ereignisse nach Datum
    struct_deltas = defaultdict(list)
    for key, entry in h.get("offsets", {}).items():
        ahk_map = entry.get("ahk_map", key.split("/")[0])
        updates = [e for e in entry["events"] if e["change_type"] == "game_update"]
        for ev in updates:
            try:
                old = int(ev["ahk_value"], 16)
                new = int(ev["cs_value"], 16)
                delta = new - old
                struct_deltas[ahk_map].append({
                    "field": entry["field"],
                    "game_version": ev["game_version"],
                    "date": ev["date"],
                    "old": ev["ahk_value"],
                    "new": ev["cs_value"],
                    "delta": delta
                })
            except (ValueError, TypeError):
                pass

    if not struct_deltas:
        print(c("Noch keine game_update-Ereignisse in der History.", YELLOW))
        print("  Führe erst '--record' aus und klassifiziere Änderungen als game_update.")
        return

    print(c(f"\n{'='*60}", BOLD))
    print(c("  DELTA-MUSTER (game_update-Analyse)", BOLD))
    print(c(f"{'='*60}", BOLD))

    for struct_name in sorted(struct_deltas):
        events = struct_deltas[struct_name]
        print(f"\n  {c(struct_name, CYAN)}")

        # Gruppiere nach game_version um gleichzeitige Shifts zu erkennen
        by_version = defaultdict(list)
        for ev in events:
            by_version[ev["game_version"]].append(ev)

        for gv in sorted(by_version):
            batch = by_version[gv]
            deltas = [e["delta"] for e in batch]
            unique_deltas = set(deltas)
            print(f"    Version {c(gv, YELLOW)}  ({len(batch)} Felder geändert)")
            if len(unique_deltas) == 1:
                d = deltas[0]
                sign = "+" if d >= 0 else ""
                print(f"    {c(f'→ GLEICHFÖRMIGER SHIFT: {sign}{hex(d)} ({sign}{d} bytes)', GREEN)}")
                print(f"       Betroffene Felder: {', '.join(e['field'] for e in batch)}")
            else:
                for e in batch:
                    sign = "+" if e["delta"] >= 0 else ""
                    print(f"    {e['field']}: {e['old']} → {e['new']}  Δ={sign}{hex(e['delta'])}")

    # Vorhersage: Structs mit konsistenten Shifts
    print(c(f"\n{'='*60}", BOLD))
    print(c("  VORHERSAGE-KANDIDATEN", BOLD))
    print(c(f"{'='*60}", BOLD))
    for struct_name in sorted(struct_deltas):
        events = struct_deltas[struct_name]
        by_version = defaultdict(list)
        for ev in events:
            by_version[ev["game_version"]].append(ev)
        consistent = []
        for gv, batch in by_version.items():
            deltas = set(e["delta"] for e in batch)
            if len(deltas) == 1 and len(batch) > 1:
                consistent.append((gv, list(deltas)[0], len(batch)))
        if consistent:
            print(f"\n  {c(struct_name, CYAN)}")
            for gv, delta, count in consistent:
                sign = "+" if delta >= 0 else ""
                print(f"    Patch {gv}: alle {count} bekannten Felder um {sign}{hex(delta)} verschoben")
            print(f"    → Bei zukünftigem Update: alle {struct_name}-Offsets zunächst um")
            all_deltas = [d for _, d, _ in consistent]
            if len(set(all_deltas)) == 1:
                d = all_deltas[0]
                sign = "+" if d >= 0 else ""
                print(c(f"      {sign}{hex(d)} ({sign}{d} bytes) probieren!", BOLD))
    print()


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser(description="Vergleicht AHK-Offsets mit C# GameOffsets (GitLab)")
    ap.add_argument("--no-fetch",  action="store_true", help="Kein Online-Abruf, nur Cache verwenden")
    ap.add_argument("--record",    action="store_true", help="Diff in offset_history.json aufnehmen")
    ap.add_argument("--history",   action="store_true", help="Änderungshistorie anzeigen")
    ap.add_argument("--predict",   action="store_true", help="Delta-Muster analysieren")
    ap.add_argument("--type",      choices=["fix","game_update"], help="Änderungstyp für --record (nicht interaktiv)")
    ap.add_argument("--filter",    choices=["fix","game_update"], help="History nach Typ filtern")
    args = ap.parse_args()

    if args.history:
        show_history(args.filter)
        return
    if args.predict:
        show_predictions()
        return

    # ── Upstream fetchen ──────────────────────────────────────────────────────
    if not args.no_fetch:
        print(c("Upstream-Synchronisation …", BOLD))
        fetch_upstream(verbose=False)

    cs_dir = CACHE_DIR / CS_OFFSETS_REL
    if not cs_dir.exists():
        print(c(f"✗ C#-Quelldaten nicht gefunden: {cs_dir}", RED))
        print("  Führe zuerst ohne --no-fetch aus, um den Upstream zu klonen.")
        sys.exit(1)

    # ── Parsen ────────────────────────────────────────────────────────────────
    print(c("Parsen …", BOLD))
    ahk        = parse_ahk_offsets(AHK_OFFSETS)
    ahk_pats   = parse_ahk_patterns(AHK_PATTERNS)
    cs         = parse_cs_offsets(cs_dir)
    cs_pats    = parse_cs_patterns(cs_dir)
    mapping    = build_struct_mapping(ahk, cs)

    print(f"  AHK:  {sum(len(v) for v in ahk.values())} Offsets in {len(ahk)} Maps")
    print(f"  C#:   {sum(len(v)-1 for v in cs.values())} Felder in {len(cs)} Structs")
    print(f"  Match:{len(mapping)} von {len(ahk)} Maps zugeordnet")
    print(f"  Commit: {upstream_commit()}  |  Spielversion: {game_version()}")

    # ── Diff ──────────────────────────────────────────────────────────────────
    offset_diff  = compute_diff(ahk, cs, mapping)
    pattern_diff = compute_pattern_diff(ahk_pats, cs_pats)

    show_diff(offset_diff, pattern_diff)

    # ── Record ────────────────────────────────────────────────────────────────
    if args.record:
        if not offset_diff and not pattern_diff:
            print("  Alles synchron — keine Änderungen zum Aufnehmen.")
            # Trotzdem Baseline anlegen falls noch keine History
            record_changes({}, {}, ahk, cs, mapping, ahk_pats, cs_pats,
                           change_type="initial")
        else:
            record_changes(offset_diff, pattern_diff, ahk, cs, mapping, ahk_pats, cs_pats,
                           change_type=args.type)
    elif offset_diff or pattern_diff:
        print(c(f"  Tipp: 'python compare_offsets.py --record' um Diff in History aufzunehmen", YELLOW))


if __name__ == "__main__":
    main()
