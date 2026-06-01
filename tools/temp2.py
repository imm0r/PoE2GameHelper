import json, sys, os, struct

script_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, script_dir)
from extract_stats_dat import (
    _ensure_ooz, decompress_bundle, decompress_bundle_partial,
    poe_path_hash, parse_index, ensure_schema, DAT64_MAGIC
)
_ensure_ooz()

GAME_DIR = r'H:\SteamLibrary\steamapps\common\Path of Exile 2'
BUNDLES2 = os.path.join(GAME_DIR, 'Bundles2')
SCHEMA_PATH = os.path.join(script_dir, 'schema.min.json')

with open(SCHEMA_PATH) as f:
    s = json.load(f)

TYPE_SIZES = {
    'string': 8, 'bool': 1, 'i8': 1, 'u8': 1, 'i16': 2, 'u16': 2,
    'i32': 4, 'u32': 4, 'f32': 4, 'enumrow': 4, 'rid': 4,
    'row': 8, 'foreignrow': 16, '_': 0,
}

def dump_table(name):
    tables = [t for t in s['tables'] if t['name'] == name]
    if not tables:
        print(f"  TABLE {name!r} NOT FOUND")
        return
    table = next((t for t in tables if t.get('validFor', 0) & 2), None)
    if not table:
        table = tables[0]
    print(f"\n=== {name} (validFor={table.get('validFor')}) ===")
    offset = 0
    for c in table['columns']:
        arr = c.get('array', False)
        sz = 16 if arr else TYPE_SIZES.get(c['type'], 0)
        cname = c.get('name') or '(unnamed)'
        ref = (c.get('references') or {}).get('table', '')
        refstr = f"  -> {ref}" if ref else ''
        print(f"  +{offset:4d}  {cname:40s}  {c['type']:12s}  array={arr}  sz={sz}{refstr}")
        offset += sz
    print(f"  total={offset}")

dump_table('UniqueGoldPrices')
dump_table('UniqueMapRelicLimits')

# Also find ALL validFor=2 tables and show which have a foreignrow -> Words
print("\n\n=== All validFor=2 tables with any Words reference ===")
for t in s['tables']:
    if not (t.get('validFor', 0) & 2):
        continue
    offset = 0
    for c in t['columns']:
        arr = c.get('array', False)
        sz = 16 if arr else TYPE_SIZES.get(c['type'], 0)
        ref = (c.get('references') or {}).get('table', '')
        if ref == 'Words':
            cname = c.get('name') or '(unnamed)'
            print(f"  {t['name']:40s}  +{offset}  {cname}")
        offset += sz
