"""
Extract Mods.datc64 from PoE2 bundles to build a mod name lookup table.

Extracts: Id (internal name), Affix (display name), GenerationType
Output: mod_name_map.tsv  (tab-separated: id  affix  generation_type)

GenerationType: 1=Prefix, 2=Suffix, 3=Unique/Implicit, others=other

Usage:
  python extract_mods_dat.py [game_dir] [output_tsv]
"""

import sys, os, struct, json, time

# Reuse helpers from extract_stats_dat.py
script_dir = os.path.dirname(os.path.abspath(__file__))
data_dir    = os.path.join(os.path.dirname(script_dir), 'data')
sys.path.insert(0, script_dir)
from extract_stats_dat import (
    _ensure_ooz, decompress_bundle, decompress_bundle_partial,
    poe_path_hash, parse_index, get_dat_column_layout, ensure_schema,
    DAT64_MAGIC
)
_ensure_ooz()


def is_valid_display_string(s: str) -> bool:
    """Return True if string looks like a human-readable affix name (ASCII, short, printable)."""
    if not s or len(s) > 100:
        return False
    # Reject strings with mostly non-ASCII characters (garbage reads)
    ascii_count = sum(1 for c in s if ord(c) < 128)
    if ascii_count < len(s) * 0.8:
        return False
    # Reject strings with control characters
    if any(ord(c) < 32 for c in s):
        return False
    return True


def read_dat_string(dat_bytes: bytes, var_data_base: int, str_offset: int) -> str:
    """Read a UTF-16LE null-terminated string from the variable section."""
    str_pos = var_data_base + str_offset
    if str_pos < var_data_base or str_pos >= len(dat_bytes):
        return ''
    end = str_pos
    while end + 1 < len(dat_bytes) and not (dat_bytes[end] == 0 and dat_bytes[end+1] == 0):
        end += 2
    raw = dat_bytes[str_pos:end]
    try:
        s = raw.decode('utf-16-le')
        if '\ubbbb' in s or len(s) > 512:
            return ''
        return s
    except Exception:
        return ''


def detect_actual_row_size(dat_bytes: bytes) -> tuple:
    """
    Auto-detect the actual row_size by finding the DAT64_MAGIC position.
    Returns (num_rows, actual_row_size, var_data_base) or raises ValueError.
    """
    num_rows = struct.unpack_from('<I', dat_bytes, 0)[0]
    if num_rows == 0 or num_rows > 1_000_000:
        raise ValueError(f"Implausible num_rows={num_rows}")

    magic_pos = dat_bytes.find(DAT64_MAGIC, 4)
    if magic_pos < 0:
        raise ValueError("DAT64_MAGIC not found")

    row_data_size = magic_pos - 4
    if row_data_size < 0 or row_data_size % num_rows != 0:
        raise ValueError(f"row_data_size={row_data_size} not divisible by num_rows={num_rows}")

    actual_row_size = row_data_size // num_rows
    var_data_base = magic_pos
    return num_rows, actual_row_size, var_data_base


def find_string_columns(dat_bytes: bytes, num_rows: int, actual_row_size: int, var_data_base: int):
    """
    Scan all 8-byte-aligned offsets in rows to find genuine string columns.
    Only returns columns where the majority of sampled strings pass ASCII validation.
    Returns dict: column_offset -> list of (row_idx, string_value) samples.
    """
    results = {}
    max_scan_rows = min(num_rows, 300)
    
    for col_off in range(0, actual_row_size, 8):
        valid_strings = []
        total_non_zero = 0
        for row_idx in range(max_scan_rows):
            row_base = 4 + row_idx * actual_row_size
            str_offset = struct.unpack_from('<I', dat_bytes, row_base + col_off)[0]
            if str_offset == 0:
                continue
            total_non_zero += 1
            s = read_dat_string(dat_bytes, var_data_base, str_offset)
            if s and is_valid_display_string(s):
                valid_strings.append((row_idx, s))
        # Only count as a string column if >50% of non-zero offsets give valid strings
        if valid_strings and total_non_zero > 0 and len(valid_strings) / total_non_zero > 0.5:
            results[col_off] = valid_strings
    return results


def find_affix_column(string_cols: dict, id_off: int):
    """
    Among the valid string columns, find the one that looks most like human-readable
    affix names (short, starts with capital, contains spaces like 'of the X').
    Returns the best offset or None.
    """
    best_off = None
    best_score = -1

    for off, samples in sorted(string_cols.items()):
        if off == id_off:
            continue
        strs = [s for _, s in samples[:50]]
        if not strs:
            continue
        # Score: prefer short strings with spaces (like "of the Abundant", "Potent")
        score = 0
        for s in strs:
            if 1 <= len(s) <= 60:
                score += 1
            if ' ' in s:
                score += 2  # "of the X" style
            if s[0].isupper() or s.startswith('of '):
                score += 1
        score /= len(strs)
        print(f"    Offset {off}: score={score:.2f}, samples={strs[:3]}")
        if score > best_score:
            best_score = score
            best_off = off

    return best_off


def find_int_columns(dat_bytes: bytes, num_rows: int, actual_row_size: int):
    """
    Find columns that look like GenerationType (small int, mostly 0-5).
    Returns dict: column_offset -> list of values (first N rows).
    """
    results = {}
    max_scan = min(num_rows, 500)
    for col_off in range(0, actual_row_size - 3, 4):
        values = []
        for row_idx in range(max_scan):
            row_base = 4 + row_idx * actual_row_size
            v = struct.unpack_from('<i', dat_bytes, row_base + col_off)[0]
            values.append(v)
        # GenerationType is small (0-5 typically), check distribution
        unique_vals = set(values)
        if len(unique_vals) <= 10 and all(-1 <= v <= 10 for v in unique_vals):
            results[col_off] = values
    return results


def parse_mods_dat(dat_bytes: bytes, schema_cols):
    """
    Parse Mods.datc64 with auto-detected row_size.
    Returns list of (id, affix, generation_type) tuples.
    """
    num_rows, actual_row_size, var_data_base = detect_actual_row_size(dat_bytes)
    print(f"  num_rows={num_rows}, actual_row_size={actual_row_size}, var_data_base=0x{var_data_base:X}")

    # Schema offsets for PoE2 Mods table (validFor=2):
    #   Id           @ +0   (string)
    #   Name         @ +98  (string) ← display name like "Potent Transcendent", "of the Abundant"
    #   GenerationType @ +106 (enumrow/i32)  1=Prefix, 2=Suffix
    # Extra bytes in actual vs schema are appended at the end — offsets near the start are correct.
    id_off       = 0
    name_off     = None
    gen_type_off = None

    for c in schema_cols:
        if c['name'] == 'Name' and c['offset'] < actual_row_size:
            name_off = c['offset']
        if c['name'] == 'GenerationType' and c['offset'] < actual_row_size:
            gen_type_off = c['offset']

    # Hardcode fallback if schema lookup fails
    if name_off is None:
        name_off = 98
    if gen_type_off is None:
        gen_type_off = 106

    print(f"  Using: Id@{id_off}, Name@{name_off}, GenerationType@{gen_type_off}")

    results = []
    for row_idx in range(num_rows):
        row_base = 4 + row_idx * actual_row_size

        id_offset = struct.unpack_from('<I', dat_bytes, row_base + id_off)[0]
        mod_id = read_dat_string(dat_bytes, var_data_base, id_offset)
        if not mod_id:
            continue

        name = ''
        name_offset = struct.unpack_from('<I', dat_bytes, row_base + name_off)[0]
        name = read_dat_string(dat_bytes, var_data_base, name_offset)

        gen_type = struct.unpack_from('<i', dat_bytes, row_base + gen_type_off)[0]

        results.append((mod_id, name, gen_type))

    return results


def main():
    game_dir   = sys.argv[1] if len(sys.argv) > 1 else r'H:\SteamLibrary\steamapps\common\Path of Exile 2'
    output_tsv = sys.argv[2] if len(sys.argv) > 2 else os.path.join(data_dir, 'mod_name_map.tsv')
    schema_path = os.path.join(script_dir, 'schema.min.json')

    if not os.path.isdir(game_dir):
        print(f'ERROR: Game directory not found: {game_dir}')
        print('Usage: python extract_mods_dat.py [game_dir] [output_tsv]')
        sys.exit(1)

    bundles2 = os.path.join(game_dir, 'Bundles2')

    print(f'Schema: {schema_path}')
    schema = ensure_schema(schema_path)

    # Get schema column layout (for offset hints)
    try:
        cols, schema_row_size = get_dat_column_layout(schema, 'Mods')
        print(f'Schema Mods: {len(cols)} columns, row_size={schema_row_size}')
        for c in cols:
            if c['name'] in ('Id', 'Affix', 'GenerationType'):
                print(f'  {c["name"]} @ {c["offset"]} size={c["size"]}')
    except ValueError as e:
        print(f'  Schema warning: {e}')
        cols = []

    # Decompress index
    index_path = os.path.join(bundles2, '_.index.bin')
    print(f'Loading index: {index_path}')
    with open(index_path, 'rb') as f:
        idx_bundle = f.read()
    idx_data = decompress_bundle(idx_bundle)
    bundles, file_table = parse_index(idx_data)
    print(f'  {len(bundles)} bundles, {len(file_table):,} files')

    # Find Mods.datc64
    candidates = [
        'Data/Mods.datc64',
        'Data/Balance/Mods.datc64',
        'Data/English/Mods.datc64',
        'Data/Mods.dat64',
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
        print('ERROR: Mods.datc64 not found in bundle index!')
        sys.exit(1)

    bundle_idx, file_offset, file_size = file_table[target_hash]
    bundle_name = bundles[bundle_idx]['name']
    print(f'  Found in bundle #{bundle_idx} ({bundle_name}) at offset {file_offset}, size {file_size:,}')

    bundle_file = os.path.join(bundles2, bundle_name + '.bundle.bin')
    print(f'Reading bundle: {bundle_file}')
    with open(bundle_file, 'rb') as f:
        bundle_bytes = f.read()

    print(f'  Decompressing file slice ...')
    dat_bytes = decompress_bundle_partial(bundle_bytes, file_offset, file_size)
    print(f'  Got {len(dat_bytes):,} bytes')

    print('Parsing Mods.datc64 ...')
    entries = parse_mods_dat(dat_bytes, cols)
    print(f'  Parsed {len(entries)} mod entries')

    if not entries:
        print('ERROR: No entries found.')
        sys.exit(1)

    # Show samples with affix
    shown = 0
    for mod_id, affix, gen_type in entries:
        if affix:
            gt_name = {1: 'Prefix', 2: 'Suffix', 3: 'UniqueImplicit'}.get(gen_type, str(gen_type))
            print(f'  [{gt_name}] {mod_id!r} -> {affix!r}')
            shown += 1
            if shown >= 15:
                break

    # Write TSV
    with open(output_tsv, 'w', encoding='utf-8', newline='\n') as f:
        f.write('# mod_name_map.tsv – auto-generated by extract_mods_dat.py\n')
        f.write(f'# schema: {schema.get("version", "?")} / {schema.get("createdAt", "")}\n')
        f.write(f'# source: {target_path} in {bundle_name}\n')
        f.write(f'# generated: {time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}\n')
        f.write('# columns: mod_id  affix  generation_type(1=Prefix,2=Suffix)\n')
        for mod_id, affix, gen_type in entries:
            f.write(f'{mod_id}\t{affix}\t{gen_type}\n')

    print(f'Written: {output_tsv}  ({len(entries)} entries)')


if __name__ == '__main__':
    main()

