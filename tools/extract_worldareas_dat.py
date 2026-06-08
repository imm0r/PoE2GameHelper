"""
Extract WorldAreas.datc64 from PoE2 bundles to build a translation dictionary
from internal area Ids to in-game display names.

This is primarily meant for atlas maps: the game (and the Atlas overlay) sees a
map's *internal* name like "MapHiddenGrotto", and this dictionary maps it to the
real in-game name like "Hidden Grotto". It covers every WorldArea, so atlas maps
are simply the rows whose Id starts with "Map".

Source columns (WorldAreas, schema validFor=2 / PoE2):
  Id   (string)  – internal name, e.g. "MapHiddenGrotto"  (the dictionary key)
  Name (string)  – in-game display name, e.g. "Hidden Grotto"  (the value)

The same Id/Name pair is what PoE2InventoryReader.ReadWorldAreaDat reads live
from memory, so the keys here line up with the runtime area id.

Reuses the proven bundle/index/schema helpers from the other extractors.

Usage:
  python extract_worldareas_dat.py [game_dir] [output_tsv] [--maps-only]
"""

import os
import sys
import time

# Core bundle/index/schema helpers.
from extract_stats_dat import (
    ensure_schema,
    decompress_bundle,
    decompress_bundle_partial,
    parse_index,
    poe_path_hash,
)
# Table-layout + two-string-column reader (same ones extract_monster_names uses).
from extract_monster_names import (
    get_table_layout,
    find_fixed_boundary,
    read_utf16_var_string,
)

SCHEMA_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'schema.min.json')


def build_world_area_name_map(dat_bytes, id_offset, name_offset, maps_only=False):
    """Build {internal Id -> display Name} from WorldAreas.datc64.

    id_offset / name_offset are the fixed-row column offsets of the Id and Name
    string columns. maps_only keeps only atlas-map areas (Id starts with "Map").
    Rows with an empty Id or Name are skipped. Returns a dict.
    """
    row_count, fixed_size, row_len = find_fixed_boundary(dat_bytes)
    data_variable = dat_bytes[4 + fixed_size:]  # variable section (marker at offset 0)

    import struct
    out = {}
    for row in range(row_count):
        row_base = 4 + row * row_len
        id_var_off = struct.unpack_from('<I', dat_bytes, row_base + id_offset)[0]
        name_var_off = struct.unpack_from('<I', dat_bytes, row_base + name_offset)[0]

        area_id = read_utf16_var_string(data_variable, id_var_off)
        area_name = read_utf16_var_string(data_variable, name_var_off)
        if not area_id or not area_name:
            continue
        if maps_only and not area_id.startswith('Map'):
            continue
        # First write wins (the PoE2 WorldArea Id is unique).
        if area_id not in out:
            out[area_id] = area_name
    return out


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    data_dir = os.path.join(os.path.dirname(script_dir), 'data')

    args = [a for a in sys.argv[1:] if a != '--maps-only']
    maps_only = '--maps-only' in sys.argv[1:]

    game_dir = args[0] if len(args) > 0 else r'H:\SteamLibrary\steamapps\common\Path of Exile 2'
    output_tsv = args[1] if len(args) > 1 else os.path.join(data_dir, 'world_area_name_map.tsv')

    if not os.path.isdir(game_dir):
        print(f'ERROR: game directory not found: {game_dir}')
        print('Usage: python extract_worldareas_dat.py [game_dir] [output_tsv] [--maps-only]')
        sys.exit(1)

    bundles2 = os.path.join(game_dir, 'Bundles2')

    # ---- Schema + column layout ----
    print(f'Schema path: {SCHEMA_PATH}')
    schema = ensure_schema(SCHEMA_PATH)
    table, cols, _ = get_table_layout(schema, 'WorldAreas')
    id_col = next(c for c in cols if c['name'] == 'Id')
    name_col = next(c for c in cols if c['name'] == 'Name')
    print(f'WorldAreas: Id@{id_col["offset"]}, Name@{name_col["offset"]}')

    # ---- Decompress index ----
    index_path = os.path.join(bundles2, '_.index.bin')
    print(f'Loading index: {index_path}')
    with open(index_path, 'rb') as f:
        idx_bundle = f.read()
    idx_data = decompress_bundle(idx_bundle)
    bundles, file_table = parse_index(idx_data)
    print(f'  {len(bundles)} bundles, {len(file_table):,} files')

    # ---- Find WorldAreas.datc64 ----
    candidates = [
        'Data/WorldAreas.datc64',          # core data (PoE2 typical)
        'Data/Balance/WorldAreas.datc64',  # fallback (Balance subdir)
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
        print('ERROR: WorldAreas table not found in bundle index!')
        print('  Tried:', candidates)
        sys.exit(1)

    bundle_idx, file_offset, file_size = file_table[target_hash]
    bundle_name = bundles[bundle_idx]['name']
    print(f'  Found in bundle #{bundle_idx} ({bundle_name}) at offset {file_offset}, size {file_size:,}')

    # ---- Decompress + parse ----
    bundle_file = os.path.join(bundles2, bundle_name + '.bundle.bin')
    if not os.path.isfile(bundle_file):
        print(f'ERROR: Bundle file not found: {bundle_file}')
        sys.exit(1)
    with open(bundle_file, 'rb') as f:
        bundle_bytes = f.read()
    dat_bytes = decompress_bundle_partial(bundle_bytes, file_offset, file_size)
    print(f'  Got {len(dat_bytes):,} bytes of dat data')

    print(f'Parsing WorldAreas.datc64 (maps_only={maps_only}) ...')
    mapping = build_world_area_name_map(dat_bytes, id_col['offset'], name_col['offset'], maps_only)
    print(f'  Extracted {len(mapping):,} area name mappings')
    if not mapping:
        print('ERROR: no WorldArea name mappings extracted. The dat format may have changed.')
        sys.exit(1)

    # Show a few atlas-map samples.
    shown = 0
    for k in sorted(mapping):
        if k.startswith('Map'):
            print(f'  {k} -> {mapping[k]}')
            shown += 1
            if shown >= 5:
                break

    # ---- Write TSV ----
    with open(output_tsv, 'w', encoding='utf-8', newline='\n') as f:
        f.write('# world_area_name_map.tsv - auto-generated by extract_worldareas_dat.py\n')
        f.write(f'# schema: {schema.get("version", "?")} / {schema.get("createdAt", "")}\n')
        f.write(f'# source: {target_path} in {bundle_name}\n')
        f.write(f'# generated: {time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}\n')
        f.write('# maps: internal WorldArea Id (e.g. "MapHiddenGrotto") -> in-game name (e.g. "Hidden Grotto")\n')
        f.write('# atlas maps are the rows whose Id starts with "Map".\n')
        f.write('# columns: internal_id\tdisplay_name\n')
        for k in sorted(mapping):
            f.write(f'{k}\t{mapping[k]}\n')

    print(f'Written: {output_tsv}  ({len(mapping)} entries)')


if __name__ == '__main__':
    main()
