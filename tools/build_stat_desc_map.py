"""
build_stat_desc_map.py
Parses ALL PoE2 StatDescriptions CSD files and generates stat_desc_map.tsv.

Output TSV format (tab-separated):
  stat_id  TAB  template  TAB  arg_index  TAB  group_ids

  stat_id    : stat string id (e.g., maximum_life)
  template   : display template, e.g. "{0} to maximum Life"
               placeholders: {0}, {1}, ... for stat values
               wiki links stripped: [Text|Display] -> Display, [Text] -> Text
  arg_index  : which {N} slot this stat's value fills (0 for first, 1 for second, etc.)
  group_ids  : comma-separated list of ALL stat_ids in the group
               (single-stat entries: just the stat itself)

Usage:
  python build_stat_desc_map.py
  python build_stat_desc_map.py "H:\\custom\\path\\to\\Path of Exile 2"
"""

import json, sys, os, re

script_dir = os.path.dirname(os.path.abspath(__file__))
data_dir    = os.path.join(os.path.dirname(script_dir), 'data')
sys.path.insert(0, script_dir)
from extract_stats_dat import (
    _ensure_ooz, decompress_bundle, decompress_bundle_partial,
    poe_path_hash, parse_index,
)
_ensure_ooz()

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
GAME_DIR = sys.argv[1] if len(sys.argv) > 1 else r'H:\SteamLibrary\steamapps\common\Path of Exile 2'
BUNDLES2 = os.path.join(GAME_DIR, 'Bundles2')
OUT_PATH  = os.path.join(data_dir, 'stat_desc_map.tsv')

# ---------------------------------------------------------------------------
# Bundle index
# ---------------------------------------------------------------------------
print(f"Loading index: {os.path.join(BUNDLES2, '_.index.bin')}")
with open(os.path.join(BUNDLES2, '_.index.bin'), 'rb') as f:
    idx_data = decompress_bundle(f.read())
bundles, file_table = parse_index(idx_data)
print(f"  {len(bundles)} bundles, {len(file_table):,} files")


def load_bundle_file(path):
    h = poe_path_hash(path)
    if h not in file_table:
        return None
    bundle_idx, file_offset, file_size = file_table[h]
    bundle_file = os.path.join(BUNDLES2, bundles[bundle_idx]['name'] + '.bundle.bin')
    with open(bundle_file, 'rb') as f:
        raw = f.read()
    return decompress_bundle_partial(raw, file_offset, file_size)


def decode_csd(data):
    """Try UTF-16-LE (with optional BOM), fall back to UTF-8."""
    if data[:2] == b'\xff\xfe':
        data = data[2:]
    try:
        return data.decode('utf-16-le', errors='replace')
    except Exception:
        return data.decode('utf-8', errors='replace')


# ---------------------------------------------------------------------------
# CSD path discovery
# ---------------------------------------------------------------------------
def collect_csd_paths():
    """
    Collect all Data/StatDescriptions/**/*.csd paths.
    Primary source: ggpk_directory_tree.json (contains paths discovered in-game).
    Fallback: hardcoded list of known top-level CSD files.
    """
    paths = set()

    # 1. ggpk_directory_tree.json
    tree_path = os.path.join(script_dir, 'ggpk_directory_tree.json')
    if os.path.exists(tree_path):
        try:
            with open(tree_path, 'r', encoding='utf-8-sig') as f:
                tree = json.load(f)
            ui_files = tree.get('ui_files', [])
            for entry in ui_files:
                p = entry.get('path', '')
                if p.lower().startswith('data/statdescriptions') and p.lower().endswith('.csd'):
                    paths.add(p)
            print(f"  {len(paths)} CSD paths from ggpk_directory_tree.json")
        except Exception as e:
            print(f"  Warning: could not read ggpk_directory_tree.json: {e}")

    # 2. Hardcoded top-level files (always include these — not always in tree)
    hardcoded = [
        'Data/StatDescriptions/stat_descriptions.csd',
        'Data/StatDescriptions/advanced_mod_stat_descriptions.csd',
        'Data/StatDescriptions/active_skill_gem_stat_descriptions.csd',
        'Data/StatDescriptions/passive_skill_stat_descriptions.csd',
        'Data/StatDescriptions/vitals_stat_descriptions.csd',
        'Data/StatDescriptions/chest_stat_descriptions.csd',
        'Data/StatDescriptions/helmet_stat_descriptions.csd',
        'Data/StatDescriptions/flask_stat_descriptions.csd',
        'Data/StatDescriptions/item_stat_descriptions.csd',
        'Data/StatDescriptions/gem_stat_descriptions.csd',
        'Data/StatDescriptions/shield_stat_descriptions.csd',
        'Data/StatDescriptions/sentinel_stat_descriptions.csd',
        'Data/StatDescriptions/atlas_stat_descriptions.csd',
        'Data/StatDescriptions/map_stat_descriptions.csd',
        'Data/StatDescriptions/buff_skill_stat_descriptions.csd',
        'Data/StatDescriptions/hideout_stat_descriptions.csd',
    ]
    for p in hardcoded:
        paths.add(p)

    # Filter: only paths that actually exist in the bundle index
    found = []
    missing = []
    for p in sorted(paths):
        h = poe_path_hash(p)
        if h in file_table:
            found.append(p)
        else:
            missing.append(p)

    if missing:
        print(f"  {len(missing)} paths not in bundle (skipped): {missing[:5]}{'...' if len(missing)>5 else ''}")
    print(f"  {len(found)} CSD files found in bundle")
    return found


# ---------------------------------------------------------------------------
# Template helpers
# ---------------------------------------------------------------------------
_WIKI_LINK_RE1 = re.compile(r'\[(?:[^\]|]+)\|([^\]]+)\]')   # [LinkText|Display] -> Display
_WIKI_LINK_RE2 = re.compile(r'\[([^\]|]+)\]')               # [Text] -> Text


def strip_wiki_links(text):
    text = _WIKI_LINK_RE1.sub(r'\1', text)
    text = _WIKI_LINK_RE2.sub(r'\1', text)
    return text


# ---------------------------------------------------------------------------
# Robust CSD parser
# ---------------------------------------------------------------------------
def parse_csd(text):
    """
    Parse CSD format. Handles both format variants:

    Variant A (older, no lang blocks):
      description
      1 stat_id
      1|# "template with {0}"

    Variant B (newer, with lang blocks):
      description
      1 stat_id
      lang "English"
      1 "template with {0}"
      lang "German"
      1 "Vorlage mit {0}"

    Multi-stat:
      description
      2 stat_id_min stat_id_max
      lang "English"
      1 "Adds {0} to {1} Fire Damage"

    Returns list of (stat_ids_tuple, template_string).
    """
    results = []
    lines = text.splitlines()
    n = len(lines)
    i = 0

    while i < n:
        if lines[i].strip() != 'description':
            i += 1
            continue

        i += 1
        # Skip blank lines after 'description'
        while i < n and not lines[i].strip():
            i += 1
        if i >= n:
            break

        # Expect: "<count> stat_id1 [stat_id2 ...]"
        stat_line = lines[i].strip()
        m = re.match(r'^(\d+)\s+(.+)$', stat_line)
        if not m:
            i += 1
            continue

        stat_ids = tuple(m.group(2).split())
        i += 1

        # Scan forward for English template
        english_text = None
        found_any_lang = False
        in_english = False

        while i < n:
            s = lines[i].strip()

            if s == 'description':
                break

            if s in ('no_description',):
                i += 1
                break

            if s.startswith('include '):
                i += 1
                continue

            # lang "LangName" header
            lm = re.match(r'^lang\s+"([^"]+)"', s)
            if lm:
                found_any_lang = True
                in_english = (lm.group(1).lower() == 'english')
                i += 1
                continue

            # Template line: contains at least one quoted string
            if '"' in s:
                fq = s.index('"')
                lq = s.rindex('"')
                if fq < lq:
                    raw_template = s[fq + 1:lq]
                    # Accept this template if:
                    #   - we're in an English lang block, OR
                    #   - no lang blocks seen yet (variant A) and no template captured yet
                    if english_text is None:
                        if in_english or not found_any_lang:
                            english_text = strip_wiki_links(raw_template)
                            if in_english:
                                i += 1
                                break  # English block found — done with this entry

            i += 1

        if english_text is not None:
            results.append((stat_ids, english_text))

    return results


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
csd_paths = collect_csd_paths()

# Priority order: stat_descriptions.csd first (general), then more specific files.
# First-found wins for each stat_id.
priority_first = [p for p in csd_paths if 'stat_descriptions.csd' in p]
priority_rest  = [p for p in csd_paths if p not in priority_first]
ordered_paths  = priority_first + priority_rest

all_entries = {}   # stat_id -> (template, arg_index, group_ids_tuple)
total_parsed = 0

print(f"\nParsing {len(ordered_paths)} CSD files...")
for path in ordered_paths:
    data = load_bundle_file(path)
    if not data:
        continue
    text  = decode_csd(data)
    entries = parse_csd(text)
    new_in_file = 0
    for stat_ids, template in entries:
        for idx, sid in enumerate(stat_ids):
            if sid not in all_entries:
                all_entries[sid] = (template, idx, stat_ids)
                new_in_file += 1
    total_parsed += len(entries)
    print(f"  {path}: {len(entries)} blocks, {new_in_file} new stat_ids")

print(f"\nTotal blocks parsed : {total_parsed}")
print(f"Total unique stat_ids: {len(all_entries)}")

# ---------------------------------------------------------------------------
# Add base_ aliases: if CSD has "base_maximum_life" but memory stat is "maximum_life",
# add "maximum_life" -> same entry (only if not already present).
# ---------------------------------------------------------------------------
alias_added = 0
for sid in list(all_entries.keys()):
    if sid.startswith('base_'):
        plain = sid[5:]
        if plain not in all_entries:
            all_entries[plain] = all_entries[sid]
            alias_added += 1
print(f"\nAdded {alias_added} base_* aliases")

# ---------------------------------------------------------------------------
# Validation: test known stats (after aliases)
# ---------------------------------------------------------------------------
test_stats = [
    'maximum_life', 'maximum_mana', 'armour',
    'local_minimum_added_fire_damage', 'local_maximum_added_fire_damage',
    'local_minimum_added_cold_damage', 'local_maximum_added_cold_damage',
    'movement_velocity_+permyriad', 'energy_shield_delay_-%',
    'local_attack_speed_+%', 'base_maximum_life',
]
print("\nValidation lookups:")
for sid in test_stats:
    if sid in all_entries:
        tmpl, idx, grp = all_entries[sid]
        print(f"  {sid:45s} [{idx}] -> \"{tmpl}\"")
    else:
        print(f"  {sid:45s} -> (not found)")

# Write TSV
with open(OUT_PATH, 'w', encoding='utf-8', newline='\n') as f:
    f.write('# stat_desc_map.tsv - generated by build_stat_desc_map.py\n')
    f.write('# Format: stat_id TAB template TAB arg_index TAB group_ids\n')
    f.write('# template placeholders: {0} {1} = stat values; wiki links stripped\n')
    f.write('# arg_index: which {N} this stat fills (0=first, 1=second, ...)\n')
    f.write('# group_ids: comma-separated group (multi-stat entries share a template)\n')
    for sid in sorted(all_entries):
        tmpl, idx, grp = all_entries[sid]
        group_str = ','.join(grp)
        f.write(f'{sid}\t{tmpl}\t{idx}\t{group_str}\n')

print(f"\nWritten: {OUT_PATH} ({len(all_entries)} entries)")
