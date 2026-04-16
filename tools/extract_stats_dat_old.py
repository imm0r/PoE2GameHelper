"""
Extract Stats.datc64 from PoE2 bundles using the dat-schema.
Uses pyooz (ooz.pyd) for OOZ decompression.

Workflow:
  1. Load schema.min.json (downloaded from GitHub)
    2. Calculate Stats.datc64 column offsets from schema
    3. Decompress _.index.bin to find Stats.datc64 bundle entry
    4. Decompress the relevant bundle
    5. Parse Stats.datc64 binary (Id + HASH32 columns)
  6. Write stat_name_map.tsv

Usage:
  python extract_stats_dat.py [game_dir] [output_tsv]
"""

import sys, os, struct, json
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
    # Determine which chunks we need
    first_chunk = file_offset // chunk_size
    last_chunk  = (file_end - 1) // chunk_size
    last_chunk  = min(last_chunk, chunk_count - 1)

    # Skip to first relevant chunk
    comp_offset = data_start
    for i in range(first_chunk):
        comp_offset += chunk_sizes[i]

    # Decompress needed chunks
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
        # XOR each remainder byte at its little-endian bit position (fall-through switch in TS)
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
    See: poe-dat-viewer/lib/src/index/bundle-index.ts getFileInfo()
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
    # Build hash → entry lookup (binary search on sorted list)
    file_table = {}  # hash -> (bundle_idx, file_offset, file_size)
    for _ in range(file_count):
        path_hash, bundle_idx, file_offset, file_size = struct.unpack_from('<QIII', idx_data, pos)
        pos += 20
        file_table[path_hash] = (bundle_idx, file_offset, file_size)
    return bundles, file_table


# -----------------------------------------------------------------------
# Schema parser – column layout
# -----------------------------------------------------------------------
# .datc64 column sizes (64-bit row/foreignrow references)
TYPE_SIZES_DATC64 = {
    'string': 8, 'bool': 1,
    'i8': 1, 'u8': 1, 'i16': 2, 'u16': 2,
    'i32': 4, 'u32': 4, 'f32': 4, 'enumrow': 4, 'rid': 4,
    'row': 8,          # 64-bit row reference in .datc64
    'foreignrow': 16,  # 64-bit table ref + 64-bit row ref in .datc64
    '_': 0,
}
_ARRAY_SIZE_DATC64 = 16  # 8-byte offset + 8-byte count for array columns

def _col_size_datc64(col: dict) -> int:
    if col.get('array', False):
        return _ARRAY_SIZE_DATC64
    return TYPE_SIZES_DATC64.get(col['type'], 0)

def get_dat_column_layout(schema: dict, table_name: str):
    """Return (columns, row_size) from schema for the named PoE2 table.
    
    Prefers the PoE2 table (validFor & 2), falls back to any table with that name.
    Uses .datc64 sizes (row=8, foreignrow=16, array=16).
    """
    candidates = [t for t in schema['tables'] if t['name'] == table_name]
    if not candidates:
        raise ValueError(f"Table '{table_name}' not found in schema")
    # Prefer PoE2 (validFor bit 1 = 0x2)
    table = next((t for t in candidates if t.get('validFor', 0) & 2), candidates[0])
    offset = 0
    cols = []
    for col in table['columns']:
        sz = _col_size_datc64(col)
        cols.append({'name': col.get('name') or '', 'type': col['type'], 'offset': offset, 'size': sz})
        offset += sz
    return cols, offset   # (columns, row_size)


# -----------------------------------------------------------------------
# dat64 parser
# -----------------------------------------------------------------------
DAT64_MAGIC = b'\xbb' * 8

def parse_dat64_stats(dat_bytes: bytes, row_size: int, id_col_offset: int, hash32_col_offset: int):
    """
    Parse a Stats.datc64 binary blob.
    Returns list of (hash32: int, stat_id: str) tuples.
    """
    num_rows = struct.unpack_from('<I', dat_bytes, 0)[0]

    # Find the variable section (magic bytes 0xBB×8)
    var_section_start = 4 + num_rows * row_size
    if var_section_start + 8 > len(dat_bytes):
        return []
    if dat_bytes[var_section_start:var_section_start+8] != DAT64_MAGIC:
        # Try scanning for magic
        magic_pos = dat_bytes.find(DAT64_MAGIC, 4)
        if magic_pos < 0:
            return []
        var_section_start = magic_pos

    var_data_start = var_section_start + 8  # skip magic

    results = []
    for row_idx in range(num_rows):
        row_base = 4 + row_idx * row_size

        # Read string offset (Id column)
        # IMPORTANT: .datc64 strings store a 4-byte (uint32) offset, not 8-byte
        # The offset is relative to the dataVariable section (after magic)
        # See poe-dat-viewer/lib/src/dat/reader.ts oneString() function
        str_offset = struct.unpack_from('<I', dat_bytes, row_base + id_col_offset)[0]
        # Read HASH32 (u32 column — unsigned in PoE2 schema)
        # Read as unsigned first, then convert to signed i32 to match
        # how AHK ReadInt() returns it (StatArrayStruct.key is C# 'int' = i32)
        hash32_u = struct.unpack_from('<I', dat_bytes, row_base + hash32_col_offset)[0]
        hash32 = struct.unpack('<i', struct.pack('<I', hash32_u))[0]  # reinterpret as signed

        # Resolve string from variable section
        str_pos = var_data_start + str_offset
        if str_pos >= len(dat_bytes):
            continue
        # .datc64 strings are UTF-16LE, null-terminated (4-byte aligned)
        # Find null sequence, then align to 4-byte boundary as reader.ts does
        end = str_pos
        while end + 1 < len(dat_bytes) and not (dat_bytes[end] == 0 and dat_bytes[end+1] == 0):
            end += 2
        while end < len(dat_bytes) and (end - str_pos) % 4 != 0:
            if not (dat_bytes[end] == 0 and dat_bytes[end+1] == 0):
                break
            end += 2
        while end + 1 < len(dat_bytes) and not (dat_bytes[end] == 0 and dat_bytes[end+1] == 0):
            end += 2
        raw = dat_bytes[str_pos:end]
        try:
            stat_id = raw.decode('utf-16-le')
        except Exception:
            stat_id = ''

        if stat_id:  # include even if hash32==0, some valid stats have hash 0
            results.append((hash32, stat_id))

    return results


# -----------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------
SCHEMA_URL = 'https://github.com/poe-tool-dev/dat-schema/releases/download/latest/schema.min.json'
SCHEMA_MAX_AGE_HOURS = 24  # re-download after this many hours

def ensure_schema(schema_path: str) -> dict:
    """Load schema from disk; download from GitHub if missing or stale."""
    needs_download = True
    if os.path.isfile(schema_path):
        age_hours = (time.time() - os.path.getmtime(schema_path)) / 3600
        if age_hours < SCHEMA_MAX_AGE_HOURS:
            needs_download = False

    if needs_download:
        print(f'Downloading latest schema from GitHub ...')
        try:
            req = urllib.request.Request(SCHEMA_URL, headers={'User-Agent': 'poe2-gamehelper/1.0'})
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

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
data_dir    = os.path.join(os.path.dirname(script_dir), 'data')

    # Detect defaults
    game_dir    = sys.argv[1] if len(sys.argv) > 1 else r'H:\SteamLibrary\steamapps\common\Path of Exile 2'
    output_tsv  = sys.argv[2] if len(sys.argv) > 2 else os.path.join(data_dir, 'stat_name_map.tsv')
    schema_path = os.path.join(script_dir, 'schema.min.json')

    if not os.path.isdir(game_dir):
        print(f'ERROR: Game directory not found: {game_dir}')
        print('Usage: python extract_stats_dat.py [game_dir] [output_tsv]')
        sys.exit(1)

    bundles2 = os.path.join(game_dir, 'Bundles2')

    # ---- Load schema ----
    print(f'Schema path: {schema_path}')
    schema = ensure_schema(schema_path)

    cols, row_size = get_dat_column_layout(schema, 'Stats')
    id_col     = next(c for c in cols if c['name'] == 'Id')
    hash32_col = next(c for c in cols if c['name'] == 'HASH32')
    print(f'Stats row_size={row_size}, Id@{id_col["offset"]}, HASH32@{hash32_col["offset"]}')

    # ---- Decompress index ----
    index_path = os.path.join(bundles2, '_.index.bin')
    print(f'Loading index: {index_path}')
    with open(index_path, 'rb') as f:
        idx_bundle = f.read()
    print(f'  Decompressing {len(idx_bundle):,} bytes ...')
    idx_data = decompress_bundle(idx_bundle)
    print(f'  Decompressed: {len(idx_data):,} bytes')

    bundles, file_table = parse_index(idx_data)
    print(f'  {len(bundles)} bundles, {len(file_table):,} files')

    # ---- Find Stats.dat64 ----
    # ---- Find Stats.datc64 (PoE2 uses Data/Balance/ prefix) ----
    # Hash uses: murmur64a(path.toLowerCase()) — no backslash, no ++ suffix
    candidates = [
        'Data/Balance/Stats.datc64',   # PoE2 English
        'Data/Stats.datc64',           # fallback (no Balance subdir)
        'Data/Stats.dat64',            # old PoE1 format (unlikely)
    ]
    target_hash = None
    target_path = None
    for c in candidates:
        h = poe_path_hash(c)
        print(f'  Trying {c!r} -> hash {h:016x} ... ', end='')
        if h in file_table:
            target_hash = h
            target_path = c
            print('FOUND!')
            break
        print('not found')
    if target_hash is None:
        print('ERROR: Stats table not found in bundle index!')
        print('  Tried:', candidates)
        sys.exit(1)

    bundle_idx, file_offset, file_size = file_table[target_hash]
    bundle_name = bundles[bundle_idx]['name']
    print(f'  Found in bundle #{bundle_idx} ({bundle_name}) at offset {file_offset}, size {file_size:,}')

    # ---- Decompress the dat ----
    bundle_file = os.path.join(bundles2, bundle_name + '.bundle.bin')
    if not os.path.isfile(bundle_file):
        print(f'ERROR: Bundle file not found: {bundle_file}')
        sys.exit(1)

    print(f'Reading bundle: {bundle_file}')
    with open(bundle_file, 'rb') as f:
        bundle_bytes = f.read()

    print(f'  Decompressing file slice (offset={file_offset}, size={file_size:,}) ...')
    dat_bytes = decompress_bundle_partial(bundle_bytes, file_offset, file_size)
    print(f'  Got {len(dat_bytes):,} bytes of dat data')

    # ---- Parse dat64 ----
    print('Parsing Stats.datc64 ...')
    entries = parse_dat64_stats(dat_bytes, row_size, id_col['offset'], hash32_col['offset'])
    print(f'  Parsed {len(entries)} stat entries')

    if not entries:
        print('ERROR: No stat entries found. The dat format may have changed.')
        sys.exit(1)

    # Show sample
    for h, name in entries[:5]:
        print(f'  hash={h:12d}  id={name}')

    # ---- Write TSV ----
    with open(output_tsv, 'w', encoding='utf-8', newline='\n') as f:
        f.write('# stat_name_map.tsv – auto-generated by extract_stats_dat.py\n')
        f.write(f'# schema: {schema.get("version", "?")} / {schema.get("createdAt", "")}\n')
        f.write(f'# source: {target_path} in {bundle_name}\n')
        f.write(f'# generated: {time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}\n')
        for hash32, stat_id in entries:
            f.write(f'{hash32}\t{stat_id}\n')

    print(f'Written: {output_tsv}  ({len(entries)} entries)')


if __name__ == '__main__':
    main()
