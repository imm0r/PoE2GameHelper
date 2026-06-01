"""
Explore PoE2 StatDescriptions bundle files.
Goal: find a mapping from stat_id -> human-readable display text.
"""

import json, sys, os, struct, re

script_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, script_dir)
from extract_stats_dat import (
    _ensure_ooz, decompress_bundle, decompress_bundle_partial,
    poe_path_hash, parse_index, DAT64_MAGIC
)
_ensure_ooz()

GAME_DIR = r'H:\SteamLibrary\steamapps\common\Path of Exile 2'
BUNDLES2 = os.path.join(GAME_DIR, 'Bundles2')

with open(os.path.join(BUNDLES2, '_.index.bin'), 'rb') as f:
    idx_data = decompress_bundle(f.read())

from extract_stats_dat import parse_index
bundles, file_table = parse_index(idx_data)
print(f"Index loaded: {len(bundles)} bundles, {len(file_table):,} files")

def load_bundle_file(path):
    h = poe_path_hash(path)
    if h not in file_table: return None
    bundle_idx, file_offset, file_size = file_table[h]
    bundle_file = os.path.join(BUNDLES2, bundles[bundle_idx]['name'] + '.bundle.bin')
    with open(bundle_file, 'rb') as f: raw = f.read()
    return decompress_bundle_partial(raw, file_offset, file_size)

# --- Find all stat description files in the index ---
print("\n=== Searching for StatDescription files in bundle index ===")
# Build a reverse lookup: hash -> path (we need to scan all known paths)
# Common stat description paths in PoE2:
candidates = [
    # PoE2 uses Data/ not Metadata/ prefix
    'Data/StatDescriptions/stat_descriptions.csd',
    'Data/StatDescriptions/stat_descriptions.txt',
    'Data/StatDescriptions/advanced_mod_stat_descriptions.csd',
    'Data/StatDescriptions/advanced_mod_stat_descriptions.txt',
    'Data/StatDescriptions/active_skill_gem_stat_descriptions.csd',
    'Data/StatDescriptions/active_skill_gem_stat_descriptions.txt',
    'Data/StatDescriptions/passive_skill_stat_descriptions.csd',
    'Data/StatDescriptions/passive_skill_stat_descriptions.txt',
    'Data/StatDescriptions/vitals_stat_descriptions.csd',
    'Data/StatDescriptions/chest_stat_descriptions.csd',
    'Data/StatDescriptions/helmet_stat_descriptions.csd',
    'Data/StatDescriptions/flask_stat_descriptions.csd',
    'Data/StatDescriptions/item_stat_descriptions.csd',
    'Data/StatDescriptions/gem_stat_descriptions.csd',
    'Data/StatDescriptions/shield_stat_descriptions.csd',
    'Data/StatDescriptions/sentinel_stat_descriptions.csd',
    'Data/StatDescriptions/specific_skill_stat_descriptions/ancestral_cry_shockwave.csd',
    'Data/StatDescriptions/specific_skill_stat_descriptions/leap_slam.csd',
]
found_paths = []
for path in candidates:
    h = poe_path_hash(path)
    if h in file_table:
        print(f"  FOUND: {path}")
        found_paths.append(path)
    else:
        print(f"  not found: {path}")

def decode_csd(data):
    """Decode CSD file bytes to text (tries UTF-16-LE then UTF-8)."""
    raw = data[2:] if data[:2] == b'\xff\xfe' else data
    try:
        return raw.decode('utf-16-le', errors='replace')
    except:
        return data.decode('utf-8', errors='replace')

def parse_csd_english(text):
    """
    Parse CSD format: extract stat_id(s) -> English display text.
    Returns list of (stat_ids_tuple, english_text) pairs.
    Multi-stat entries are included — each stat gets the same template.
    """
    import re
    results = []
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line == 'description':
            i += 1
            # Skip blank lines
            while i < len(lines) and not lines[i].strip():
                i += 1
            if i >= len(lines): break
            # "<N> stat_id1 [stat_id2...]"
            stat_line = lines[i].strip()
            m = re.match(r'^(\d+)\s+(.+)$', stat_line)
            if not m:
                i += 1
                continue
            stat_ids = tuple(m.group(2).split())
            i += 1
            # Find first English format string (first 1|# "..." line we encounter)
            english_text = None
            while i < len(lines):
                s = lines[i].strip()
                if s == 'description' or s.startswith('no_description') or s.startswith('include '):
                    break
                tm = re.match(r'^\d+\|[^"]*"(.*)"', s) or re.match(r'^"(.*)"$', s)
                if tm:
                    if english_text is None:
                        english_text = tm.group(1)
                        # Don't break — keep scanning to find next description block
                        # but we already have English, so stop after this match
                        i += 1
                        break
                i += 1
            if english_text is not None:
                results.append((stat_ids, english_text))
            continue
        i += 1
    return results

# --- Parse all found CSD files and show sample + stats ---
print("\n=== Parsing CSD files (English only) ===")
all_stat_display = {}  # stat_id -> display_text
for path in found_paths:
    data = load_bundle_file(path)
    if not data: continue
    text = decode_csd(data)
    entries = parse_csd_english(text)
    print(f"\n  {path}: {len(entries)} entries parsed")
    # Show first 10
    for stat_ids, eng_text in entries[:10]:
        ids_str = ', '.join(stat_ids)
        print(f"    [{ids_str}] -> \"{eng_text}\"")
    # Collect ALL entries — multi-stat too (each stat_id gets the template)
    for stat_ids, eng_text in entries:
        for sid in stat_ids:
            if sid not in all_stat_display:  # first found wins
                all_stat_display[sid] = eng_text

print(f"\n=== Total display names collected: {len(all_stat_display)} ===")
# Show stats from statsByItems screenshot as test
test_stats = [
    'local_minimum_added_fire_damage', 'local_maximum_added_fire_damage',
    'local_minimum_added_cold_damage', 'local_maximum_added_cold_damage',
    'armour', 'maximum_life', 'maximum_mana', 'movement_velocity_+permyriad',
    'energy_shield_delay_-%', 'local_attack_speed_+%',
]
print("\n  Test lookups (from screenshot stats):")
for sid in test_stats:
    found = all_stat_display.get(sid, '(not found)')
    print(f"    {sid:45s} -> {found}")

# Diagnose: check if 'armour' / 'maximum_life' text appears in stat_descriptions.csd at all
print("\n=== Diagnostic: searching raw text for missing stats ===")
main_path = 'Data/StatDescriptions/stat_descriptions.csd'
if main_path in found_paths:
    data = load_bundle_file(main_path)
    text = decode_csd(data)
    lines = text.splitlines()
    desc_count = sum(1 for l in lines if l.strip() == 'description')
    print(f"  stat_descriptions.csd: {len(lines)} lines, {desc_count} 'description' blocks")
    for needle in ['armour', 'maximum_life', 'maximum_mana', 'movement_velocity']:
        hits = [l.strip() for l in lines if needle in l.strip() and not l.strip().startswith('1|') and not l.strip().startswith('"')]
        if hits:
            print(f"  '{needle}' found in stat lines: {hits[:3]}")
        else:
            print(f"  '{needle}' NOT found in any stat line")
