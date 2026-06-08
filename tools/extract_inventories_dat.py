"""
Extract Inventories.datc64 from PoE2 bundles using the dat-schema.

Produces a mapping between an inventory's name (the `Id` string column) and its
index. This is useful for resolving the numeric inventory index the game reports
in memory back to a human-readable inventory name.

IMPORTANT — index base mismatch (see header notes in the output TSV):
  * In the *game*, inventory indices start at 0x01 (1-based).
  * In *Inventories.datc64*, rows start at 0x00 (0-based).
  So:  game_index = dat_row + 1   (equivalently dat_row = game_index - 1).
The output TSV lists both columns explicitly so callers don't have to remember
which side they are on.

Reuses the proven bundle/index/schema helpers from extract_stats_dat.py.

Usage:
  python extract_inventories_dat.py [game_dir] [output_tsv]
"""

import os
import struct
import sys
import time

# Reuse the proven helpers (OOZ decompress, index parse, path hashing, schema).
from extract_stats_dat import (
    ensure_schema,
    decompress_bundle,
    decompress_bundle_partial,
    parse_index,
    poe_path_hash,
    get_dat_column_layout,
)

SCHEMA_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'schema.min.json')

DAT64_MAGIC = b'\xbb' * 8


def read_utf16_string(dat_bytes, var_base, str_offset):
    """Resolve a .datc64 UTF-16LE string given a variable-section offset.

    var_base   – absolute offset of the 0xBB*8 magic (offsets are relative to it).
    str_offset – the uint32 offset stored in the row's string column.
    Returns the decoded string ('' if out of range / empty).
    """
    str_pos = var_base + str_offset
    if str_pos < 0 or str_pos >= len(dat_bytes):
        return ''
    end = str_pos
    while end + 1 < len(dat_bytes) and not (dat_bytes[end] == 0 and dat_bytes[end + 1] == 0):
        end += 2
    raw = dat_bytes[str_pos:end]
    try:
        return raw.decode('utf-16-le').strip()
    except Exception:
        return ''


def parse_inventories(dat_bytes, row_size, id_offset, invidkey_offset):
    """Parse Inventories.datc64.

    Returns a list of dicts: {dat_row, game_index, name, inventory_id_key}.
      dat_row   – 0-based row index inside the .dat file.
      game_index– 1-based index as used by the game (dat_row + 1, i.e. 0x01-based).
      name      – the `Id` string column.
      inventory_id_key – the i32 `InventoryIdKey` column (best-effort).
    """
    num_rows = struct.unpack_from('<I', dat_bytes, 0)[0]

    # Locate the variable-data section (string offsets are relative to the magic).
    var_base = 4 + num_rows * row_size
    if var_base + 8 > len(dat_bytes) or dat_bytes[var_base:var_base + 8] != DAT64_MAGIC:
        magic_pos = dat_bytes.find(DAT64_MAGIC, 4)
        if magic_pos < 0:
            return []
        var_base = magic_pos

    rows = []
    for row in range(num_rows):
        row_base = 4 + row * row_size
        str_offset = struct.unpack_from('<I', dat_bytes, row_base + id_offset)[0]
        name = read_utf16_string(dat_bytes, var_base, str_offset)
        inv_id_key = struct.unpack_from('<i', dat_bytes, row_base + invidkey_offset)[0]
        rows.append({
            'dat_row': row,
            'game_index': row + 1,
            'name': name,
            'inventory_id_key': inv_id_key,
        })
    return rows


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    data_dir = os.path.join(os.path.dirname(script_dir), 'data')

    game_dir = sys.argv[1] if len(sys.argv) > 1 else r'H:\SteamLibrary\steamapps\common\Path of Exile 2'
    output_tsv = sys.argv[2] if len(sys.argv) > 2 else os.path.join(data_dir, 'inventory_name_map.tsv')

    if not os.path.isdir(game_dir):
        print(f'ERROR: game directory not found: {game_dir}')
        print('Usage: python extract_inventories_dat.py [game_dir] [output_tsv]')
        sys.exit(1)

    bundles2 = os.path.join(game_dir, 'Bundles2')

    # ---- Load schema + column layout ----
    print(f'Schema path: {SCHEMA_PATH}')
    schema = ensure_schema(SCHEMA_PATH)

    cols, row_size = get_dat_column_layout(schema, 'Inventories')
    id_col = next(c for c in cols if c['name'] == 'Id')
    invidkey_col = next((c for c in cols if c['name'] == 'InventoryIdKey'), id_col)
    print(f'Inventories row_size={row_size}, Id@{id_col["offset"]}, '
          f'InventoryIdKey@{invidkey_col["offset"]}')

    # ---- Decompress index ----
    index_path = os.path.join(bundles2, '_.index.bin')
    print(f'Loading index: {index_path}')
    with open(index_path, 'rb') as f:
        idx_bundle = f.read()
    idx_data = decompress_bundle(idx_bundle)
    bundles, file_table = parse_index(idx_data)
    print(f'  {len(bundles)} bundles, {len(file_table):,} files')

    # ---- Find Inventories.datc64 ----
    candidates = [
        'Data/Balance/Inventories.datc64',  # PoE2 layout (Balance subdir)
        'Data/Inventories.datc64',          # fallback (no Balance subdir)
    ]
    target_hash = None
    target_path = None
    for c in candidates:
        h = poe_path_hash(c)
        print(f'  Trying {c!r} -> hash {h:016x} ... ', end='')
        if h in file_table:
            target_hash, target_path = h, c
            print('FOUND!')
            break
        print('not found')
    if target_hash is None:
        print('ERROR: Inventories table not found in bundle index!')
        print('  Tried:', candidates)
        sys.exit(1)

    bundle_idx, file_offset, file_size = file_table[target_hash]
    bundle_name = bundles[bundle_idx]['name']
    print(f'  Found in bundle #{bundle_idx} ({bundle_name}) at offset {file_offset}, size {file_size:,}')

    # ---- Decompress the dat slice ----
    bundle_file = os.path.join(bundles2, bundle_name + '.bundle.bin')
    if not os.path.isfile(bundle_file):
        print(f'ERROR: Bundle file not found: {bundle_file}')
        sys.exit(1)
    with open(bundle_file, 'rb') as f:
        bundle_bytes = f.read()
    dat_bytes = decompress_bundle_partial(bundle_bytes, file_offset, file_size)
    print(f'  Got {len(dat_bytes):,} bytes of dat data')

    # ---- Parse ----
    print('Parsing Inventories.datc64 ...')
    rows = parse_inventories(dat_bytes, row_size, id_col['offset'], invidkey_col['offset'])
    print(f'  Parsed {len(rows)} inventory rows')
    if not rows:
        print('ERROR: No inventory rows found. The dat format may have changed.')
        sys.exit(1)

    for r in rows[:5]:
        print(f'  dat_row={r["dat_row"]:3d}  game_index=0x{r["game_index"]:02X}  id={r["name"]}')

    # ---- Write TSV ----
    with open(output_tsv, 'w', encoding='utf-8', newline='\n') as f:
        f.write('# inventory_name_map.tsv - auto-generated by extract_inventories_dat.py\n')
        f.write(f'# schema: {schema.get("version", "?")} / {schema.get("createdAt", "")}\n')
        f.write(f'# source: {target_path} in {bundle_name}\n')
        f.write(f'# generated: {time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}\n')
        f.write('# NOTE: game inventory index is 1-based (starts at 0x01);\n')
        f.write('#       dat_row is 0-based (starts at 0x00).  game_index = dat_row + 1.\n')
        f.write('# columns: game_index(decimal)\tdat_row(decimal)\tname(Id)\tinventory_id_key\n')
        for r in rows:
            f.write(f'{r["game_index"]}\t{r["dat_row"]}\t{r["name"]}\t{r["inventory_id_key"]}\n')

    print(f'Written: {output_tsv}  ({len(rows)} entries)')


if __name__ == '__main__':
    main()
