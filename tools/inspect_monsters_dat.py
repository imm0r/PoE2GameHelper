import os
import struct
import json
import sys

# reuse extraction helpers
sys.path.insert(0, r'e:\ahk\poe2\GameHelper')
from extract_stats_dat import decompress_bundle, decompress_bundle_partial, parse_index, poe_path_hash, ensure_schema

GAME_DIR = r'H:\SteamLibrary\steamapps\common\Path of Exile 2'
BUNDLES2 = os.path.join(GAME_DIR, 'Bundles2')
SCHEMA_PATH = r'e:\ahk\poe2\GameHelper\schema.min.json'

TYPE_SIZES_DATC64 = {
    'string': 8, 'bool': 1,
    'i8': 1, 'u8': 1, 'i16': 2, 'u16': 2,
    'i32': 4, 'u32': 4, 'f32': 4, 'enumrow': 4, 'rid': 4,
    'row': 8,
    'foreignrow': 16,
    '_': 0,
}
ARRAY_SIZE = 16

def col_size(col):
    if col.get('array', False):
        return ARRAY_SIZE
    return TYPE_SIZES_DATC64.get(col['type'], 0)

def get_table_layout(schema, table_name):
    variants = [t for t in schema['tables'] if t['name'] == table_name]
    t = next(v for v in variants if (v.get('validFor', 0) & 2))
    off = 0
    cols = []
    for c in t['columns']:
        cols.append({
            'name': c.get('name') or '',
            'type': c['type'],
            'array': c.get('array', False),
            'offset': off,
        })
        off += col_size(c)
    return t, cols, off

def find_boundary_and_rowlen(dat):
    row_count = struct.unpack_from('<I', dat, 0)[0]
    if row_count <= 0:
        return row_count, 0, 4
    data = dat[4:]
    seq = b'\xbb' * 8
    start = 0
    while True:
        idx = data.find(seq, start)
        if idx < 0:
            return row_count, 0, 4
        if idx % row_count == 0:
            return row_count, idx, 4 + idx
        start = idx + 1

def read_string_at(data_variable, offset):
    if offset < 0 or offset >= len(data_variable):
        return ''
    # same logic as pathofexile-dat: UTF-16LE until 4 zero bytes, even-length guard
    end = data_variable.find(b'\x00\x00\x00\x00', offset)
    while end != -1 and ((end - offset) % 2 != 0):
        end = data_variable.find(b'\x00\x00\x00\x00', end + 1)
    if end == -1:
        return ''
    raw = data_variable[offset:end]
    try:
        return raw.decode('utf-16-le', errors='ignore').strip()
    except Exception:
        return ''

def main():
    schema = ensure_schema(SCHEMA_PATH)
    table, cols, schema_row = get_table_layout(schema, 'MonsterVarieties')
    print(f"MonsterVarieties validFor={table.get('validFor')} schemaRow={schema_row}")

    id_col = next(c for c in cols if c['name'] == 'Id')
    name_col = next((c for c in cols if c['name'] == 'Name'), None)
    bmi_col = next((c for c in cols if c['name'] == 'BaseMonsterTypeIndex'), None)
    print(f"Id@{id_col['offset']} Name@{name_col['offset'] if name_col else -1} BMI@{bmi_col['offset'] if bmi_col else -1}")

    with open(os.path.join(BUNDLES2, '_.index.bin'), 'rb') as f:
        idx_bundle = f.read()
    idx_data = decompress_bundle(idx_bundle)
    bundles, file_table = parse_index(idx_data)

    target = 'Data/Balance/MonsterVarieties.datc64'
    h = poe_path_hash(target)
    if h not in file_table:
        print('NOT FOUND in index', target)
        return

    bidx, foff, fsize = file_table[h]
    bname = bundles[bidx]['name']
    bpath = os.path.join(BUNDLES2, bname + '.bundle.bin')
    with open(bpath, 'rb') as f:
        bundle = f.read()
    dat = decompress_bundle_partial(bundle, foff, fsize)

    row_count, boundary, fixed_start = find_boundary_and_rowlen(dat)
    row_len = boundary // row_count if row_count else 0
    print(f"row_count={row_count} boundary={boundary} row_len={row_len}")

    data_variable = dat[fixed_start:]

    for i in range(min(40, row_count)):
        rb = 4 + i * row_len
        id_off = struct.unpack_from('<I', dat, rb + id_col['offset'])[0]
        id_txt = read_string_at(data_variable, id_off)

        nm_txt = ''
        if name_col:
            nm_off = struct.unpack_from('<I', dat, rb + name_col['offset'])[0]
            nm_txt = read_string_at(data_variable, nm_off)
        else:
            nm_off = -1

        bmi_txt = ''
        if bmi_col:
            bmi_off = struct.unpack_from('<I', dat, rb + bmi_col['offset'])[0]
            bmi_txt = read_string_at(data_variable, bmi_off)
        else:
            bmi_off = -1

        print(f"[{i:03d}] id={id_txt!r} name={nm_txt!r} bmi={bmi_txt!r} (off id={id_off} name={nm_off} bmi={bmi_off})")

if __name__ == '__main__':
    main()
