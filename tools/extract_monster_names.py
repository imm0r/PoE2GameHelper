"""
Extract monster display names from PoE2 MonsterVarieties.datc64.

Output:
  monster_name_map.tsv with key->displayName pairs.
  Keys include both full metadata path and short basename variants.

Usage:
  python extract_monster_names.py [game_dir] [output_tsv]
"""

import os
import struct
import sys
import time

# Reuse proven helpers from extract_stats_dat.py
from extract_stats_dat import (
    ensure_schema,
    decompress_bundle,
    decompress_bundle_partial,
    parse_index,
    poe_path_hash,
)

SCHEMA_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'schema.min.json')

TYPE_SIZES_DATC64 = {
    'string': 8,
    'bool': 1,
    'i8': 1,
    'u8': 1,
    'i16': 2,
    'u16': 2,
    'i32': 4,
    'u32': 4,
    'f32': 4,
    'enumrow': 4,
    'rid': 4,
    'row': 8,
    'foreignrow': 16,
    '_': 0,
}
ARRAY_SIZE_DATC64 = 16


def col_size_datc64(col):
    if col.get('array', False):
        return ARRAY_SIZE_DATC64
    return TYPE_SIZES_DATC64.get(col['type'], 0)


def get_table_layout(schema, table_name):
    variants = [t for t in schema['tables'] if t['name'] == table_name]
    if not variants:
        raise ValueError(f"table not found: {table_name}")

    table = next((t for t in variants if t.get('validFor', 0) & 2), variants[0])

    offset = 0
    cols = []
    for c in table['columns']:
        cols.append({
            'name': c.get('name') or '',
            'type': c['type'],
            'array': c.get('array', False),
            'offset': offset,
        })
        offset += col_size_datc64(c)
    return table, cols, offset


def find_fixed_boundary(dat_bytes):
    """Return (row_count, fixed_size, row_len) based on aligned BB*8 separator."""
    row_count = struct.unpack_from('<I', dat_bytes, 0)[0]
    if row_count <= 0:
        return 0, 0, 0

    data = dat_bytes[4:]
    marker = b'\xbb' * 8
    pos = 0
    while True:
        idx = data.find(marker, pos)
        if idx < 0:
            raise RuntimeError('could not find variable-data boundary marker')
        if idx % row_count == 0:
            fixed_size = idx
            row_len = fixed_size // row_count
            return row_count, fixed_size, row_len
        pos = idx + 1


def read_utf16_var_string(data_variable, offset):
    """PoE datc64 string decoding (same strategy as pathofexile-dat)."""
    if offset < 0 or offset >= len(data_variable):
        return ''

    end = data_variable.find(b'\x00\x00\x00\x00', offset)
    while end != -1 and ((end - offset) % 2 != 0):
        end = data_variable.find(b'\x00\x00\x00\x00', end + 1)
    if end < 0:
        return ''

    raw = data_variable[offset:end]
    if not raw:
        return ''
    return raw.decode('utf-16-le', errors='ignore').strip()


def normalize_key(s):
    return (s or '').strip().replace('\\', '/').lower()


def add_mapping(mapping, key, value):
    k = normalize_key(key)
    v = (value or '').strip()
    if not k or not v:
        return
    if k not in mapping:
        mapping[k] = v


def build_monster_name_map(dat_bytes, id_offset, name_offset):
    row_count, fixed_size, row_len = find_fixed_boundary(dat_bytes)

    data_variable = dat_bytes[4 + fixed_size:]  # includes marker at offset 0

    out = {}
    for row in range(row_count):
        row_base = 4 + row * row_len

        id_var_off = struct.unpack_from('<I', dat_bytes, row_base + id_offset)[0]
        name_var_off = struct.unpack_from('<I', dat_bytes, row_base + name_offset)[0]

        monster_id = read_utf16_var_string(data_variable, id_var_off)
        monster_name = read_utf16_var_string(data_variable, name_var_off)

        if not monster_id or not monster_name:
            continue

        add_mapping(out, monster_id, monster_name)

        short = monster_id.rsplit('/', 1)[-1]
        add_mapping(out, short, monster_name)
        add_mapping(out, short.rstrip('_'), monster_name)

    return out


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
data_dir    = os.path.join(os.path.dirname(script_dir), 'data')
    game_dir = sys.argv[1] if len(sys.argv) > 1 else r'H:\SteamLibrary\steamapps\common\Path of Exile 2'
    output_tsv = sys.argv[2] if len(sys.argv) > 2 else os.path.join(data_dir, 'monster_name_map.tsv')

    if not os.path.isdir(game_dir):
        print(f'ERROR: game directory not found: {game_dir}')
        sys.exit(1)

    schema = ensure_schema(SCHEMA_PATH)
    table, cols, _ = get_table_layout(schema, 'MonsterVarieties')

    id_col = next(c for c in cols if c['name'] == 'Id')
    name_col = next(c for c in cols if c['name'] == 'Name')

    bundles2 = os.path.join(game_dir, 'Bundles2')
    idx_path = os.path.join(bundles2, '_.index.bin')
    with open(idx_path, 'rb') as f:
        idx_bundle = f.read()
    idx_data = decompress_bundle(idx_bundle)
    bundles, file_table = parse_index(idx_data)

    target_path = 'Data/Balance/MonsterVarieties.datc64'
    target_hash = poe_path_hash(target_path)
    if target_hash not in file_table:
        print(f'ERROR: {target_path} not found in bundle index')
        sys.exit(1)

    bundle_idx, file_offset, file_size = file_table[target_hash]
    bundle_name = bundles[bundle_idx]['name']

    bundle_file = os.path.join(bundles2, bundle_name + '.bundle.bin')
    with open(bundle_file, 'rb') as f:
        bundle_bytes = f.read()

    dat_bytes = decompress_bundle_partial(bundle_bytes, file_offset, file_size)
    mapping = build_monster_name_map(dat_bytes, id_col['offset'], name_col['offset'])

    if not mapping:
        print('ERROR: no monster name mappings extracted')
        sys.exit(1)

    with open(output_tsv, 'w', encoding='utf-8', newline='\n') as f:
        f.write('# monster_name_map.tsv - auto-generated by extract_monster_names.py\n')
        f.write(f'# schema: {schema.get("version", "?")} / {schema.get("createdAt", "")}\n')
        f.write(f'# source: {target_path} in {bundle_name}\n')
        f.write(f'# generated: {time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}\n')
        for k in sorted(mapping.keys()):
            f.write(f'{k}\t{mapping[k]}\n')

    print(f'Extracted {len(mapping):,} mappings -> {output_tsv}')


if __name__ == '__main__':
    main()
