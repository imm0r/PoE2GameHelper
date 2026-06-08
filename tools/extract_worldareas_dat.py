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

This script is fully self-contained (stdlib only) so it can be shared as a
single file. It needs the OOZ decompressor (pip install pyooz) to read bundles.

Usage:
  python extract_worldareas_dat.py [game_dir] [output_tsv] [--maps-only]
"""

import sys, os, struct, json, urllib.request, time


# -----------------------------------------------------------------------
# OOZ decompressor path (installed via 'pip install pyooz')
# -----------------------------------------------------------------------
_OOZ_CANDIDATES = [
    r'C:\Users\m0nsu\AppData\Local\Packages\PythonSoftwareFoundation.Python.3.13_qbz5n2kfra8p0\LocalCache\local-packages\Python313\site-packages',
]
def _ensure_ooz():
    try:
        import ooz
        return ooz
    except ImportError:
        pass
    for p in _OOZ_CANDIDATES:
        if os.path.isdir(p) and p not in sys.path:
            sys.path.insert(0, p)
    import ooz
    return ooz

ooz_mod = _ensure_ooz()


# -----------------------------------------------------------------------
# Bundle decompressor
# -----------------------------------------------------------------------
def decompress_bundle(bundle_bytes: bytes) -> bytes:
    """Decompress a full PoE2 bundle (.bundle.bin) file."""
    uncomp_size = struct.unpack_from('<I', bundle_bytes, 0)[0]
    chunk_count = struct.unpack_from('<I', bundle_bytes, 36)[0]
    chunk_size  = struct.unpack_from('<I', bundle_bytes, 40)[0]
    chunk_sizes = struct.unpack_from(f'<{chunk_count}I', bundle_bytes, 60)
    data_start  = 60 + chunk_count * 4
    result    = bytearray()
    offset    = data_start
    remaining = uncomp_size
    for cs in chunk_sizes:
        dc   = min(chunk_size, remaining)
        dec  = ooz_mod.decompress(bundle_bytes[offset:offset+cs], dc)
        result.extend(dec)
        offset    += cs
        remaining -= dc
    return bytes(result)


def decompress_bundle_partial(bundle_bytes: bytes, file_offset: int, file_size: int) -> bytes:
    """Decompress only the portion of a bundle needed for a specific file."""
    uncomp_size = struct.unpack_from('<I', bundle_bytes, 0)[0]
    chunk_count = struct.unpack_from('<I', bundle_bytes, 36)[0]
    chunk_size  = struct.unpack_from('<I', bundle_bytes, 40)[0]
    chunk_sizes = struct.unpack_from(f'<{chunk_count}I', bundle_bytes, 60)
    data_start  = 60 + chunk_count * 4

    file_end    = file_offset + file_size
    first_chunk = file_offset // chunk_size
    last_chunk  = (file_end - 1) // chunk_size
    last_chunk  = min(last_chunk, chunk_count - 1)

    comp_offset = data_start
    for i in range(first_chunk):
        comp_offset += chunk_sizes[i]

    result    = bytearray()
    remaining = uncomp_size - first_chunk * chunk_size
    for i in range(first_chunk, last_chunk + 1):
        dc  = min(chunk_size, remaining)
        dec = ooz_mod.decompress(bundle_bytes[comp_offset:comp_offset + chunk_sizes[i]], dc)
        result.extend(dec)
        comp_offset += chunk_sizes[i]
        remaining   -= dc

    chunk_start = first_chunk * chunk_size
    local_start = file_offset - chunk_start
    return bytes(result[local_start:local_start + file_size])


# -----------------------------------------------------------------------
# Murmur2_64A – PoE2 path hashing
# -----------------------------------------------------------------------
def murmur2_64a(data: bytes, seed: int = 0x1337B33F) -> int:
    """64-bit Murmur2 hash (PoE2 path hashing algorithm)."""
    M = 0xC6A4A7935BD1E995
    R = 47
    mask64 = 0xFFFFFFFFFFFFFFFF
    h = (seed ^ (len(data) * M)) & mask64
    for i in range(0, len(data) - 7, 8):
        k = struct.unpack_from('<Q', data, i)[0]
        k = (k * M) & mask64
        k ^= k >> R
        k = (k * M) & mask64
        h ^= k
        h = (h * M) & mask64
    rem = len(data) & 7
    if rem:
        # XOR each remainder byte at its little-endian bit position
        a = len(data) - rem
        if rem >= 7: h ^= data[a + 6] << 48
        if rem >= 6: h ^= data[a + 5] << 40
        if rem >= 5: h ^= data[a + 4] << 32
        if rem >= 4: h ^= data[a + 3] << 24
        if rem >= 3: h ^= data[a + 2] << 16
        if rem >= 2: h ^= data[a + 1] << 8
        h ^= data[a + 0]
        h = (h * M) & mask64
    h ^= h >> R
    h = (h * M) & mask64
    h ^= h >> R
    return h


def poe_path_hash(path: str) -> int:
    """Compute the PoE2 bundle path hash for a given file path.

    PoE2 bundle index uses murmur64a(path.toLowerCase()) — no ++ suffix,
    no backslash conversion, just lowercase UTF-8 encoding.
    """
    return murmur2_64a(path.lower().encode('utf-8'))


# -----------------------------------------------------------------------
# Index parser
# -----------------------------------------------------------------------
def parse_index(idx_data: bytes):
    """Parse decompressed _.index.bin data. Returns (bundles, file_table)."""
    pos = 0
    bundle_count = struct.unpack_from('<I', idx_data, pos)[0]; pos += 4
    bundles = []
    for _ in range(bundle_count):
        name_len = struct.unpack_from('<I', idx_data, pos)[0]; pos += 4
        name     = idx_data[pos:pos+name_len].decode('utf-8');  pos += name_len
        unc_size = struct.unpack_from('<I', idx_data, pos)[0];  pos += 4
        bundles.append({'name': name, 'uncompressed_size': unc_size})

    file_count = struct.unpack_from('<I', idx_data, pos)[0]; pos += 4
    file_table = {}  # hash -> (bundle_idx, file_offset, file_size)
    for _ in range(file_count):
        path_hash, bundle_idx, file_offset, file_size = struct.unpack_from('<QIII', idx_data, pos)
        pos += 20
        file_table[path_hash] = (bundle_idx, file_offset, file_size)
    return bundles, file_table


# -----------------------------------------------------------------------
# Schema parser – column layout (.datc64 sizes)
# -----------------------------------------------------------------------
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
ARRAY_SIZE_DATC64 = 16  # 8-byte offset + 8-byte count for array columns


def col_size_datc64(col):
    if col.get('array', False):
        return ARRAY_SIZE_DATC64
    return TYPE_SIZES_DATC64.get(col['type'], 0)


def get_table_layout(schema, table_name):
    """Return (table, columns, row_size) for the named PoE2 table.

    Prefers the PoE2 variant (validFor & 2); falls back to any variant.
    Each column dict gets name/type/array and its fixed-row byte offset.
    """
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


# -----------------------------------------------------------------------
# dat64 helpers
# -----------------------------------------------------------------------
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


# -----------------------------------------------------------------------
# Schema downloader
# -----------------------------------------------------------------------
SCHEMA_URL = 'https://github.com/poe-tool-dev/dat-schema/releases/download/latest/schema.min.json'
SCHEMA_MAX_AGE_HOURS = 24


def ensure_schema(schema_path: str) -> dict:
    """Load schema from disk; download from GitHub if missing or stale."""
    needs_download = True
    if os.path.isfile(schema_path):
        age_hours = (time.time() - os.path.getmtime(schema_path)) / 3600
        if age_hours < SCHEMA_MAX_AGE_HOURS:
            needs_download = False

    if needs_download:
        print('Downloading latest schema from GitHub ...')
        try:
            req = urllib.request.Request(SCHEMA_URL, headers={'User-Agent': 'poeformance/1.0'})
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = resp.read()
            with open(schema_path, 'wb') as f:
                f.write(data)
            print(f'  Saved {len(data):,} bytes to {schema_path}')
        except Exception as e:
            if os.path.isfile(schema_path):
                print(f'  WARNING: Download failed ({e}), using cached schema.')
            else:
                print(f'  ERROR: Download failed and no cached schema: {e}')
                sys.exit(1)

    with open(schema_path, 'r', encoding='utf-8') as f:
        schema = json.load(f)
    print(f'  Schema version: {schema.get("version", "?")} (createdAt={schema.get("createdAt", "?")})')
    return schema


# -----------------------------------------------------------------------
# WorldAreas name-map builder
# -----------------------------------------------------------------------
def build_world_area_name_map(dat_bytes, id_offset, name_offset, maps_only=False):
    """Build {internal Id -> display Name} from WorldAreas.datc64.

    id_offset / name_offset are the fixed-row column offsets of the Id and Name
    string columns. maps_only keeps only atlas-map areas (Id starts with "Map").
    Rows with an empty Id or Name are skipped. Returns a dict.
    """
    row_count, fixed_size, row_len = find_fixed_boundary(dat_bytes)
    data_variable = dat_bytes[4 + fixed_size:]  # variable section (marker at offset 0)

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


# -----------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------
def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    data_dir = os.path.join(os.path.dirname(script_dir), 'data')

    args = [a for a in sys.argv[1:] if a != '--maps-only']
    maps_only = '--maps-only' in sys.argv[1:]

    game_dir = args[0] if len(args) > 0 else r'H:\SteamLibrary\steamapps\common\Path of Exile 2'
    output_tsv = args[1] if len(args) > 1 else os.path.join(data_dir, 'world_area_name_map.tsv')
    schema_path = os.path.join(script_dir, 'schema.min.json')

    if not os.path.isdir(game_dir):
        print(f'ERROR: game directory not found: {game_dir}')
        print('Usage: python extract_worldareas_dat.py [game_dir] [output_tsv] [--maps-only]')
        sys.exit(1)

    bundles2 = os.path.join(game_dir, 'Bundles2')

    # ---- Schema + column layout ----
    print(f'Schema path: {schema_path}')
    schema = ensure_schema(schema_path)
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
