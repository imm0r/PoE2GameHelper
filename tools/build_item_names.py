"""
Build a complete item name dictionary from PoE2 GGPK bundles.

Extracts and joins:
  - Mods.datc64         → mod prefix/suffix names + tier words (via ModType + Words)
  - BaseItemTypes.datc64 → base item names (e.g. "Life Flask", "Topaz Charm")
  - UniqueItems.datc64   → unique item names (e.g. "Valako's Roar")

Output files:
  mod_name_map.tsv       → mod_id  name  gen_type  (prefix/suffix/unique)
  base_item_name_map.tsv → metadata_path  display_name
  unique_name_map.tsv    → metadata_path  unique_name  base_name

Usage:
  python build_item_names.py [game_dir]
"""

import sys, os, struct, json, time

script_dir = os.path.dirname(os.path.abspath(__file__))
data_dir    = os.path.join(os.path.dirname(script_dir), 'data')
sys.path.insert(0, script_dir)
from extract_stats_dat import (
    _ensure_ooz, decompress_bundle, decompress_bundle_partial,
    poe_path_hash, parse_index, ensure_schema, DAT64_MAGIC
)
_ensure_ooz()

GAME_DIR = sys.argv[1] if len(sys.argv) > 1 else r'H:\SteamLibrary\steamapps\common\Path of Exile 2'
BUNDLES2  = os.path.join(GAME_DIR, 'Bundles2')
SCHEMA_PATH = os.path.join(script_dir, 'schema.min.json')


# ---------------------------------------------------------------------------
# Core helpers
# ---------------------------------------------------------------------------

def read_utf16(dat: bytes, var_base: int, offset: int) -> str:
    pos = var_base + offset
    if pos < var_base or pos >= len(dat):
        return ''
    end = pos
    while end + 1 < len(dat) and not (dat[end] == 0 and dat[end+1] == 0):
        end += 2
    try:
        s = dat[pos:end].decode('utf-16-le')
        return s if '\ubbbb' not in s else ''
    except Exception:
        return ''


def find_boundary(dat: bytes):
    """Return (num_rows, row_size, var_base) by locating the 0xBB*8 magic."""
    num_rows = struct.unpack_from('<I', dat, 0)[0]
    if num_rows <= 0 or num_rows > 2_000_000:
        raise ValueError(f"bad num_rows={num_rows}")
    body = dat[4:]
    marker = DAT64_MAGIC
    pos = 0
    while True:
        idx = body.find(marker, pos)
        if idx < 0:
            raise RuntimeError("DAT64_MAGIC not found")
        if idx % num_rows == 0:
            return num_rows, idx // num_rows, 4 + idx
        pos = idx + 1


def get_schema_col_offsets(schema, table_name, *col_names):
    """
    Returns dict {col_name: offset} for the PoE2 (validFor&2) version of the table.
    Uses same size rules as extract_stats_dat.py.
    """
    TYPE_SIZES = {
        'string': 8, 'bool': 1,
        'i8': 1, 'u8': 1, 'i16': 2, 'u16': 2,
        'i32': 4, 'u32': 4, 'f32': 4, 'enumrow': 4, 'rid': 4,
        'row': 8, 'foreignrow': 16, '_': 0,
    }
    tables = [t for t in schema['tables'] if t['name'] == table_name]
    if not tables:
        return {}
    table = next((t for t in tables if t.get('validFor', 0) & 2), tables[0])
    offset = 0
    result = {}
    for c in table['columns']:
        name = c.get('name') or ''
        sz = 16 if c.get('array') else TYPE_SIZES.get(c['type'], 0)
        if name in col_names:
            result[name] = offset
        offset += sz
    return result


def load_bundle_file(file_table, bundles, path: str) -> bytes | None:
    h = poe_path_hash(path)
    if h not in file_table:
        return None
    bundle_idx, file_offset, file_size = file_table[h]
    bundle_file = os.path.join(BUNDLES2, bundles[bundle_idx]['name'] + '.bundle.bin')
    with open(bundle_file, 'rb') as f:
        raw = f.read()
    return decompress_bundle_partial(raw, file_offset, file_size)


# ---------------------------------------------------------------------------
# 1. Extract Words.datc64 → {row_index: word_text}
# ---------------------------------------------------------------------------

def extract_words(schema, file_table, bundles) -> dict:
    """Returns {row_index: {'wordlist': id, 'text': str}} for all Words rows."""
    print("\n--- Words.datc64 ---")
    dat = load_bundle_file(file_table, bundles, 'Data/Balance/Words.datc64')
    if not dat:
        print("  NOT FOUND")
        return {}
    num_rows, row_size, var_base = find_boundary(dat)
    print(f"  {num_rows} rows, row_size={row_size}")
    # Schema (validFor=3): Wordlist@0 (enumrow, 4), Text@4 (string, 8)
    words = {}
    for i in range(num_rows):
        base = 4 + i * row_size
        wordlist_id = struct.unpack_from('<i', dat, base + 0)[0]
        str_off = struct.unpack_from('<I', dat, base + 4)[0]
        text = read_utf16(dat, var_base, str_off)
        words[i] = {'wordlist': wordlist_id, 'text': text}

    sample = [(k, v) for k, v in words.items() if v['text'] and v['wordlist'] == 1][:4]
    for k, v in sample:
        print(f"  [{k}] wordlist={v['wordlist']} {v['text']!r}")
    unique_count = sum(1 for v in words.values() if v['wordlist'] == 6)
    print(f"  Wordlist 6 (unique names): {unique_count} entries")
    return words


# ---------------------------------------------------------------------------
# 2. Extract ModType.datc64 → {row_index: [word_row_indices]}
#    ModType schema (validFor=2):
#      +0  Name    (string, 8 bytes)
#      +8  Stat    (foreignrow array, 16 bytes)
#      +24 (unnamed) array of word refs, 16 bytes  ← tier-word array
#      +40 (unnamed) bool, 1 byte
# ---------------------------------------------------------------------------

MODTYPE_WORDS_ARRAY_OFFSET = 24  # hardcoded from schema inspection

def extract_mod_type_words(schema, file_table, bundles, words_count: int) -> dict:
    print("\n--- ModType.datc64 ---")
    dat = load_bundle_file(file_table, bundles, 'Data/Balance/ModType.datc64')
    if not dat:
        print("  NOT FOUND")
        return {}
    num_rows, row_size, var_base = find_boundary(dat)
    print(f"  {num_rows} rows, row_size={row_size}")
    print(f"  Using unnamed Words array @ offset {MODTYPE_WORDS_ARRAY_OFFSET}")

    elem_size = _detect_modtype_elem_size(dat, num_rows, row_size, var_base, words_count)
    print(f"  Detected element size: {elem_size} bytes per word ref")

    result = {}
    for i in range(num_rows):
        base = 4 + i * row_size
        arr_off   = struct.unpack_from('<Q', dat, base + MODTYPE_WORDS_ARRAY_OFFSET)[0]
        arr_count = struct.unpack_from('<Q', dat, base + MODTYPE_WORDS_ARRAY_OFFSET + 8)[0]
        if arr_count == 0 or arr_count > 64:
            result[i] = []
            continue
        word_indices = []
        for j in range(arr_count):
            elem_pos = var_base + arr_off + j * elem_size
            if elem_pos + elem_size > len(dat):
                break
            if elem_size == 4:
                word_row = struct.unpack_from('<I', dat, elem_pos)[0]
            elif elem_size == 8:
                word_row = struct.unpack_from('<Q', dat, elem_pos)[0]
            else:  # 16: foreignrow, row_idx is second 8 bytes
                word_row = struct.unpack_from('<Q', dat, elem_pos + 8)[0]
            if word_row < words_count:
                word_indices.append(int(word_row))
        result[i] = word_indices

    sample = [(k, v) for k, v in result.items() if v][:5]
    for k, v in sample:
        print(f"  ModType[{k}] -> words{v}")
    if not sample:
        print("  WARNING: No ModType rows had valid word references — tier words unavailable")
    return result


def get_modtype_row_from_mods(dat_mods, row_size_mods, var_base_mods, modtype_off, modtype_count) -> int:
    """Given a Mods row's raw data, return the ModType row index using both byte positions."""
    # Try first 8 bytes then second 8 bytes of the 16-byte foreignrow
    for try_off in (0, 8):
        val = struct.unpack_from('<Q', dat_mods, modtype_off + try_off)[0]
        if val < modtype_count:
            return val, try_off
    return None, None


def _detect_modtype_elem_size(dat, num_rows, row_size, var_base, words_count):
    """Probe element sizes 4, 8, 16 — return whichever yields valid word row indices."""
    for elem_size in (4, 8, 16):
        hits = 0
        for i in range(min(num_rows, 200)):
            base = 4 + i * row_size
            arr_off   = struct.unpack_from('<Q', dat, base + MODTYPE_WORDS_ARRAY_OFFSET)[0]
            arr_count = struct.unpack_from('<Q', dat, base + MODTYPE_WORDS_ARRAY_OFFSET + 8)[0]
            if arr_count == 0 or arr_count > 16:
                continue
            elem_pos = var_base + arr_off
            if elem_pos + elem_size > len(dat):
                continue
            if elem_size == 4:
                val = struct.unpack_from('<I', dat, elem_pos)[0]
            elif elem_size == 8:
                val = struct.unpack_from('<Q', dat, elem_pos)[0]
            else:
                val = struct.unpack_from('<Q', dat, elem_pos + 8)[0]
            if val < words_count:
                hits += 1
        if hits > 0:
            return elem_size
    return 4  # fallback


# ---------------------------------------------------------------------------
# 3. Extract Mods.datc64 → mod_name_map.tsv
# ---------------------------------------------------------------------------

def extract_mods(schema, file_table, bundles, words: dict, modtype_words: dict) -> list:
    print("\n--- Mods.datc64 ---")
    dat = load_bundle_file(file_table, bundles, 'Data/Balance/Mods.datc64')
    if not dat:
        print("  NOT FOUND")
        return []
    num_rows, row_size, var_base = find_boundary(dat)
    print(f"  {num_rows} rows, row_size={row_size}")

    cols = get_schema_col_offsets(schema, 'Mods', 'Id', 'Name', 'GenerationType', 'ModType')
    id_off       = cols.get('Id', 0)
    name_off     = cols.get('Name', 98)
    gen_type_off = cols.get('GenerationType', 106)
    modtype_off  = cols.get('ModType', 10)
    print(f"  Id@{id_off}, Name@{name_off}, GenType@{gen_type_off}, ModType@{modtype_off}")

    modtype_count = max(modtype_words.keys()) + 1 if modtype_words else 0

    # Auto-detect which 8-byte half of the ModType foreignrow holds the row index.
    # We expect diverse values (different ModType rows) rather than all-same.
    modtype_row_off = 8  # default: second 8 bytes
    if modtype_count > 1:
        vals_at_0 = set()
        vals_at_8 = set()
        for i in range(min(num_rows, 200)):
            base = 4 + i * row_size
            v0 = struct.unpack_from('<Q', dat, base + modtype_off)[0]
            v8 = struct.unpack_from('<Q', dat, base + modtype_off + 8)[0]
            if v0 < modtype_count: vals_at_0.add(v0)
            if v8 < modtype_count: vals_at_8.add(v8)
        # The correct offset gives MORE unique valid values
        if len(vals_at_0) > len(vals_at_8):
            modtype_row_off = 0
            print(f"  ModType row_idx: using first 8 bytes (offset +0), {len(vals_at_0)} distinct values vs {len(vals_at_8)}")
        else:
            modtype_row_off = 8
            print(f"  ModType row_idx: using second 8 bytes (offset +8), {len(vals_at_8)} distinct values vs {len(vals_at_0)}")

    results = []
    for i in range(num_rows):
        base = 4 + i * row_size

        id_str_off = struct.unpack_from('<I', dat, base + id_off)[0]
        mod_id = read_utf16(dat, var_base, id_str_off)
        if not mod_id:
            continue

        name_str_off = struct.unpack_from('<I', dat, base + name_off)[0]
        mod_name = read_utf16(dat, var_base, name_str_off)

        gen_type = struct.unpack_from('<i', dat, base + gen_type_off)[0]

        modtype_row = struct.unpack_from('<Q', dat, base + modtype_off + modtype_row_off)[0]

        tier_word = ''
        if modtype_row < modtype_count and modtype_row in modtype_words:
            word_indices = modtype_words[modtype_row]
            for widx in word_indices:
                entry = words.get(widx, {})
                wl = entry.get('wordlist', -1)
                text = entry.get('text', '')
                if not text:
                    continue
                # Wordlist 1/3/7 = tier qualifier words (e.g. "Transcendent", "Dire")
                # Wordlist 6 = unique item names — NOT reliably mapped via ModType in PoE2
                if wl in (1, 3, 7) and not tier_word:
                    tier_word = text

        display_name = mod_name
        results.append((mod_id, display_name, gen_type, tier_word))

    with_name   = sum(1 for _, n, _, _ in results if n)
    with_tier   = sum(1 for _, _, _, t in results if t)
    with_unique = sum(1 for _, n, g, _ in results if g == 3 and n)
    print(f"  {len(results)} mods, {with_name} with name, {with_tier} with tier word, {with_unique} unique names")

    sample = [(i, n, g, t) for i, n, g, t in results if n and t][:5]
    for mod_id, name, gen_type, tier in sample:
        print(f"  {mod_id!r} -> name={name!r}, tier={tier!r}, genType={gen_type}")

    return results


# ---------------------------------------------------------------------------
# 4. Extract BaseItemTypes.datc64 → base_item_name_map.tsv
# ---------------------------------------------------------------------------

def extract_base_items(schema, file_table, bundles) -> list:
    print("\n--- BaseItemTypes.datc64 ---")
    dat = load_bundle_file(file_table, bundles, 'Data/Balance/BaseItemTypes.datc64')
    if not dat:
        dat = load_bundle_file(file_table, bundles, 'Data/BaseItemTypes.datc64')
    if not dat:
        print("  NOT FOUND")
        return []
    num_rows, row_size, var_base = find_boundary(dat)
    print(f"  {num_rows} rows, row_size={row_size}")

    cols = get_schema_col_offsets(schema, 'BaseItemTypes', 'Id', 'Name')
    id_off   = cols.get('Id', 0)
    name_off = cols.get('Name', 8)
    print(f"  Id@{id_off}, Name@{name_off}")

    results = []
    for i in range(num_rows):
        base = 4 + i * row_size
        id_off_ = struct.unpack_from('<I', dat, base + id_off)[0]
        item_id = read_utf16(dat, var_base, id_off_)
        if not item_id:
            continue
        name_off_ = struct.unpack_from('<I', dat, base + name_off)[0]
        item_name = read_utf16(dat, var_base, name_off_)
        results.append((item_id, item_name))

    sample = [(i, n) for i, n in results if n][:8]
    for item_id, name in sample:
        print(f"  {item_id!r} -> {name!r}")
    return results


# ---------------------------------------------------------------------------
# 5. Extract UniqueGoldPrices.datc64 → unique_name_map.tsv
#    UniqueGoldPrices (validFor=2) is the only PoE2 table with a direct
#    Words→Unique-Name reference. Schema:
#      +0   Name  (foreignrow→Words, 16 bytes): row index in Words table
#      +16  Price (i32, 4 bytes)
#    Gives us the authoritative list of PoE2 unique item names.
#    Note: there is no static metadata_path→unique_name mapping in PoE2 data;
#    the actual unique name of a held item must be read from the entity at runtime.
# ---------------------------------------------------------------------------

def extract_unique_gold_prices(file_table, bundles, words: dict) -> list:
    print("\n--- UniqueGoldPrices.datc64 ---")
    dat = load_bundle_file(file_table, bundles, 'Data/Balance/UniqueGoldPrices.datc64')
    if not dat:
        dat = load_bundle_file(file_table, bundles, 'Data/UniqueGoldPrices.datc64')
    if not dat:
        print("  NOT FOUND")
        return []
    num_rows, row_size, var_base = find_boundary(dat)
    print(f"  {num_rows} rows, row_size={row_size}")

    # Probe first row to detect correct foreignrow byte layout.
    # Try offset 0 (first 8 bytes = row_idx) vs offset 8 (second 8 bytes = row_idx).
    # The correct offset is the one that yields a Words row in the Wordlist 6 range.
    words6_indices = {idx for idx, v in words.items() if v.get('wordlist') == 6}
    words_count = len(words)

    row_idx_offset = None
    for try_off in (0, 8):
        hits = 0
        for i in range(min(num_rows, 50)):
            base = 4 + i * row_size
            val = struct.unpack_from('<Q', dat, base + try_off)[0]
            if val in words6_indices:
                hits += 1
        if hits > 0:
            row_idx_offset = try_off
            print(f"  Detected row_idx at foreignrow offset +{try_off} ({hits} hits from first 50 rows)")
            break

    if row_idx_offset is None:
        # Fallback: try 4-byte row index
        for try_off in (0, 4, 8, 12):
            hits = 0
            for i in range(min(num_rows, 50)):
                base = 4 + i * row_size
                val = struct.unpack_from('<I', dat, base + try_off)[0]
                if val in words6_indices:
                    hits += 1
            if hits > 0:
                row_idx_offset = try_off
                print(f"  Detected 4-byte row_idx at offset +{try_off} ({hits} hits)")
                break
        if row_idx_offset is None:
            # Dump raw bytes to help debug
            base = 4
            print(f"  Could not detect format. Raw bytes of row 0: {dat[base:base+row_size].hex()}")
            return []

    results = []
    for i in range(num_rows):
        base = 4 + i * row_size
        if row_idx_offset is not None and row_idx_offset < 8:
            words_row = struct.unpack_from('<I' if row_idx_offset <= 4 else '<Q', dat, base + row_idx_offset)[0]
        else:
            words_row = struct.unpack_from('<Q', dat, base + row_idx_offset)[0]
        price = struct.unpack_from('<i', dat, base + 16)[0]
        entry = words.get(int(words_row), {})
        name = entry.get('text', '') if isinstance(entry, dict) else ''
        if name:
            results.append((name, price))

    sample = results[:8]
    for name, price in sample:
        print(f"  {name!r} -> {price} gold")
    print(f"  Total: {len(results)} unique names")
    return results


# ---------------------------------------------------------------------------
# 5b. Extract UniqueStashLayout → unique_item_name_map.tsv
#     Join chain:
#       BaseItemTypes (path → IVI_row) + ItemVisualIdentity (IVI_row → ivi_id_str)
#       UniqueStashLayout (IVI_row → unique_name) + ItemVisualIdentity (IVI_row → ivi_id_str)
#     Match key: sorted CamelCase words from ivi_id_str, excluding "Four"/"Unique" + trailing number
#     Example: FourCharm10 ↔ FourUniqueCharm10 → both key = (('Charm',), '10')
#              FourFlaskLife1 ↔ FourUniqueLifeFlask1 → both key = (('Flask','Life'), '1')
# ---------------------------------------------------------------------------

def extract_unique_item_names(schema, file_table, bundles, words: dict) -> list:
    import re

    print("\n--- Unique item name map (UniqueStashLayout + IVI + BaseItemTypes) ---")

    def ivi_match_key(ivi_id_str):
        parts = re.findall('[A-Z][a-z0-9]*|[0-9]+', ivi_id_str)
        num = next((p for p in parts if p.isdigit()), '')
        rest = tuple(sorted(p for p in parts if p not in ('Four', 'Unique') and not p.isdigit()))
        return (rest, num)

    # Load ItemVisualIdentity — build ivi_row → match_key
    ivi_dat = (load_bundle_file(file_table, bundles, 'Data/Balance/ItemVisualIdentity.datc64') or
               load_bundle_file(file_table, bundles, 'Data/ItemVisualIdentity.datc64'))
    if not ivi_dat:
        print("  ItemVisualIdentity.datc64 NOT FOUND")
        return []
    ivi_nr, ivi_rs, ivi_vb = find_boundary(ivi_dat)
    print(f"  IVI: {ivi_nr} rows, row_size={ivi_rs}")

    ivi_row_to_key = {}
    for i in range(ivi_nr):
        base = 4 + i * ivi_rs
        str_off = struct.unpack_from('<I', ivi_dat, base)[0]   # Id is first field (string, offset 0)
        ivi_id_str = read_utf16(ivi_dat, ivi_vb, str_off)
        if ivi_id_str:
            ivi_row_to_key[i] = ivi_match_key(ivi_id_str)

    # Load UniqueStashLayout — build match_key → unique_name (prefer non-alternate-art)
    usl_dat = (load_bundle_file(file_table, bundles, 'Data/Balance/UniqueStashLayout.datc64') or
               load_bundle_file(file_table, bundles, 'Data/UniqueStashLayout.datc64'))
    if not usl_dat:
        print("  UniqueStashLayout.datc64 NOT FOUND")
        return []
    usl_nr, usl_rs, usl_vb = find_boundary(usl_dat)
    print(f"  USL: {usl_nr} rows, row_size={usl_rs}")

    # USL schema: +0 WordsKey (foreignrow,16), +16 ItemVisualIdentityKey (foreignrow,16), +82 IsAlternateArt (bool,1)
    key_to_unique: dict = {}   # match_key → (name, is_alt)
    for i in range(usl_nr):
        base = 4 + i * usl_rs
        words_row = int(struct.unpack_from('<Q', usl_dat, base + 0)[0])
        ivi_row   = int(struct.unpack_from('<Q', usl_dat, base + 16)[0])
        is_alt    = bool(usl_dat[base + 82]) if (base + 82) < len(usl_dat) else False

        entry = words.get(words_row, {})
        name = entry.get('text', '') if isinstance(entry, dict) else ''
        if not name or ivi_row >= ivi_nr:
            continue

        key = ivi_row_to_key.get(ivi_row)
        if key is None:
            continue

        existing = key_to_unique.get(key)
        # Prefer non-alternate-art; if both same alt-status, keep first (already stored)
        if existing is None or (not is_alt and existing[1]):
            key_to_unique[key] = (name, is_alt)

    print(f"  USL: {len(key_to_unique)} unique match keys built")

    # Load BaseItemTypes — join via IVI match_key
    bit_dat = (load_bundle_file(file_table, bundles, 'Data/Balance/BaseItemTypes.datc64') or
               load_bundle_file(file_table, bundles, 'Data/BaseItemTypes.datc64'))
    if not bit_dat:
        print("  BaseItemTypes.datc64 NOT FOUND")
        return []

    cols = get_schema_col_offsets(schema, 'BaseItemTypes', 'Id', 'ItemVisualIdentity')
    id_off  = cols.get('Id', 0)
    ivi_off = cols.get('ItemVisualIdentity', 124)
    bit_nr, bit_rs, bit_vb = find_boundary(bit_dat)
    print(f"  BIT: {bit_nr} rows, Id@{id_off}, ItemVisualIdentity@{ivi_off}")

    results = []
    for i in range(bit_nr):
        base = 4 + i * bit_rs
        id_str_off = struct.unpack_from('<I', bit_dat, base + id_off)[0]
        item_id = read_utf16(bit_dat, bit_vb, id_str_off)
        if not item_id:
            continue
        ivi_row = int(struct.unpack_from('<Q', bit_dat, base + ivi_off)[0])
        if ivi_row >= ivi_nr:
            continue
        key = ivi_row_to_key.get(ivi_row)
        if key is None:
            continue
        match = key_to_unique.get(key)
        if match:
            results.append((item_id, match[0]))

    flask_charm = [(p, n) for p, n in results if 'charm' in p.lower() or 'flask' in p.lower()]
    print(f"  Mapped {len(results)} base item paths to unique names ({len(flask_charm)} flask/charm)")
    for path, name in flask_charm[:10]:
        print(f"    {path.split('/')[-1]:30s} -> {name!r}")
    return results



def main():
    if not os.path.isdir(GAME_DIR):
        print(f'ERROR: Game dir not found: {GAME_DIR}')
        sys.exit(1)

    print(f'Loading schema: {SCHEMA_PATH}')
    schema = ensure_schema(SCHEMA_PATH)

    print(f'Loading bundle index...')
    with open(os.path.join(BUNDLES2, '_.index.bin'), 'rb') as f:
        idx_data = decompress_bundle(f.read())
    bundles, file_table = parse_index(idx_data)
    print(f'  {len(bundles)} bundles, {len(file_table):,} files')

    # Step 1: Words (tier names + unique names via Wordlist 6)
    words = extract_words(schema, file_table, bundles)

    # Step 2: ModType → Words mapping
    modtype_words = extract_mod_type_words(schema, file_table, bundles, len(words))

    # Step 3: Mods (with tier words joined)
    mods = extract_mods(schema, file_table, bundles, words, modtype_words)

    # Write mod_name_map.tsv
    mod_tsv = os.path.join(data_dir, 'mod_name_map.tsv')
    with open(mod_tsv, 'w', encoding='utf-8', newline='\n') as f:
        f.write('# mod_name_map.tsv – generated by build_item_names.py\n')
        f.write(f'# generated: {time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}\n')
        f.write('# columns: mod_id\tname\tgen_type(1=Prefix,2=Suffix,3=Unique)\ttier_word\n')
        for mod_id, name, gen_type, tier_word in mods:
            f.write(f'{mod_id}\t{name}\t{gen_type}\t{tier_word}\n')
    print(f'\nWritten: {mod_tsv} ({len(mods)} entries)')

    # Step 4: Base item types
    base_items = extract_base_items(schema, file_table, bundles)
    base_tsv = os.path.join(data_dir, 'base_item_name_map.tsv')
    with open(base_tsv, 'w', encoding='utf-8', newline='\n') as f:
        f.write('# base_item_name_map.tsv – generated by build_item_names.py\n')
        f.write(f'# generated: {time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}\n')
        f.write('# columns: metadata_path\tdisplay_name\n')
        for item_id, name in base_items:
            f.write(f'{item_id}\t{name}\n')
    print(f'Written: {base_tsv} ({len(base_items)} entries)')

    # Step 5: Unique names — all of Words Wordlist 6 (1780 entries = complete PoE2 unique name list)
    #   UniqueGoldPrices only covers a subset (547). Wordlist 6 is the canonical source.
    #   NOTE: No static metadata_path→unique_name mapping exists in PoE2 bundle data.
    #   The unique name of a specific item must be read from the entity in memory at runtime.
    #   This file serves as a lookup/validation set.
    unique_names_all = sorted(
        {v['text'] for v in words.values() if isinstance(v, dict) and v.get('wordlist') == 6 and v.get('text')}
    )

    # Also build gold price map from UniqueGoldPrices for enrichment
    unique_gold = extract_unique_gold_prices(file_table, bundles, words)
    gold_map = {name: price for name, price in unique_gold}

    unique_tsv = os.path.join(data_dir, 'unique_name_map.tsv')
    with open(unique_tsv, 'w', encoding='utf-8', newline='\n') as f:
        f.write('# unique_name_map.tsv – generated by build_item_names.py\n')
        f.write(f'# generated: {time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}\n')
        f.write('# Source: Words.datc64 Wordlist 6 (all PoE2 unique names)\n')
        f.write('# columns: unique_name\tgold_price\n')
        for name in unique_names_all:
            price = gold_map.get(name, '')
            f.write(f'{name}\t{price}\n')
    print(f'Written: {unique_tsv} ({len(unique_names_all)} unique names)')

    # Step 5b: Unique item names (metadata_path → unique_name)
    unique_items = extract_unique_item_names(schema, file_table, bundles, words)
    unique_item_tsv = os.path.join(data_dir, 'unique_item_name_map.tsv')
    with open(unique_item_tsv, 'w', encoding='utf-8', newline='\n') as f:
        f.write('# unique_item_name_map.tsv – generated by build_item_names.py\n')
        f.write(f'# generated: {time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}\n')
        f.write('# columns: metadata_path\tunique_name\n')
        for item_id, unique_name in unique_items:
            f.write(f'{item_id}\t{unique_name}\n')
    print(f'Written: {unique_item_tsv} ({len(unique_items)} entries)')

    print('\nDone! Files written:')
    print(f'  {mod_tsv}')
    print(f'  {base_tsv}')
    print(f'  {unique_tsv}')
    print(f'  {unique_item_tsv}')


if __name__ == '__main__':
    main()
