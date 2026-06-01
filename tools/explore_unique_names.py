"""
Explore PoE2 dat tables: UniqueStashLayout + BaseItemTypes -> metadata_path -> unique_name
"""

import json, sys, os, struct
from collections import Counter

script_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, script_dir)
from extract_stats_dat import (
    _ensure_ooz, decompress_bundle, decompress_bundle_partial,
    poe_path_hash, parse_index, DAT64_MAGIC
)
_ensure_ooz()

GAME_DIR = r'H:\SteamLibrary\steamapps\common\Path of Exile 2'
BUNDLES2 = os.path.join(GAME_DIR, 'Bundles2')
SCHEMA_PATH = os.path.join(script_dir, 'schema.min.json')

with open(SCHEMA_PATH) as f:
    schema = json.load(f)
with open(os.path.join(BUNDLES2, '_.index.bin'), 'rb') as f:
    idx_data = decompress_bundle(f.read())
bundles, file_table = parse_index(idx_data)

TYPE_SIZES = {
    'string': 8, 'bool': 1, 'i8': 1, 'u8': 1, 'i16': 2, 'u16': 2,
    'i32': 4, 'u32': 4, 'f32': 4, 'enumrow': 4, 'rid': 4,
    'row': 8, 'foreignrow': 16, '_': 0,
}

def load_bundle_file(path):
    h = poe_path_hash(path)
    if h not in file_table: return None
    bundle_idx, file_offset, file_size = file_table[h]
    bundle_file = os.path.join(BUNDLES2, bundles[bundle_idx]['name'] + '.bundle.bin')
    with open(bundle_file, 'rb') as f: raw = f.read()
    return decompress_bundle_partial(raw, file_offset, file_size)

def find_boundary(dat):
    num_rows = struct.unpack_from('<I', dat, 0)[0]
    if num_rows <= 0 or num_rows > 2_000_000: raise ValueError(f"bad num_rows={num_rows}")
    body = dat[4:]
    pos = 0
    while True:
        idx = body.find(DAT64_MAGIC, pos)
        if idx < 0: raise RuntimeError("DAT64_MAGIC not found")
        if idx % num_rows == 0: return num_rows, idx // num_rows, 4 + idx
        pos = idx + 1

def read_utf16(dat, var_base, offset):
    pos = var_base + offset
    if pos < var_base or pos >= len(dat): return ''
    end = pos
    while end + 1 < len(dat) and not (dat[end] == 0 and dat[end+1] == 0): end += 2
    try:
        s = dat[pos:end].decode('utf-16-le')
        return s if '\ubbbb' not in s else ''
    except: return ''

def get_table_schema(name):
    tables = [t for t in schema['tables'] if t['name'] == name]
    if not tables: return None
    return next((t for t in tables if t.get('validFor', 0) & 2), None) or tables[0]

def get_col_offsets(table, *col_names):
    offset = 0
    result = {}
    for c in table['columns']:
        arr = c.get('array', False)
        sz = 16 if arr else TYPE_SIZES.get(c['type'], 0)
        name = c.get('name') or ''
        if name in col_names: result[name] = offset
        offset += sz
    return result

def dump_table_schema(name):
    t = get_table_schema(name)
    if not t:
        print(f"  NOT FOUND: {name}")
        return
    offset = 0
    for c in t['columns']:
        arr = c.get('array', False)
        sz = 16 if arr else TYPE_SIZES.get(c['type'], 0)
        ref = (c.get('references') or {}).get('table', '')
        refstr = f" -> {ref}" if ref else ''
        cname = c.get('name') or '(unnamed)'
        print(f"    +{offset:4d}  {cname:35s}  {c['type']:12s}  arr={arr}  sz={sz}{refstr}")
        offset += sz

# ─────────────────────────────────────────────────────────────────────────────
# Dump schemas
# ─────────────────────────────────────────────────────────────────────────────
print("=== UniqueStashLayout schema ===")
dump_table_schema('UniqueStashLayout')
print("\n=== VillageUniqueDisenchantValues schema ===")
dump_table_schema('VillageUniqueDisenchantValues')

# ─────────────────────────────────────────────────────────────────────────────
# Load Words
# ─────────────────────────────────────────────────────────────────────────────
print("\n--- Loading Words ---")
words_dat = load_bundle_file('Data/Balance/Words.datc64')
words = {}
if words_dat:
    nw, rs, vb = find_boundary(words_dat)
    for i in range(nw):
        base = 4 + i * rs
        wl = struct.unpack_from('<i', words_dat, base)[0]
        so = struct.unpack_from('<I', words_dat, base + 4)[0]
        words[i] = {'wordlist': wl, 'text': read_utf16(words_dat, vb, so)}
    print(f"  {nw} words, {sum(1 for v in words.values() if v['wordlist']==6)} in wordlist 6")

# ─────────────────────────────────────────────────────────────────────────────
# Load UniqueStashLayout: build IVI_row -> unique_name map
# ─────────────────────────────────────────────────────────────────────────────
print("\n--- Loading UniqueStashLayout ---")
usl_dat = load_bundle_file('Data/Balance/UniqueStashLayout.datc64') or \
          load_bundle_file('Data/UniqueStashLayout.datc64')
usl_ivi_to_names = {}  # IVI_row -> list of unique names (could be multiple)
usl_row_count = 0
if usl_dat:
    t = get_table_schema('UniqueStashLayout')
    offs = get_col_offsets(t, 'WordsKey', 'ItemVisualIdentityKey')
    words_off = offs.get('WordsKey', 0)
    ivi_off   = offs.get('ItemVisualIdentityKey', 16)
    print(f"  WordsKey@{words_off}, ItemVisualIdentityKey@{ivi_off}")
    nr, rs, vb = find_boundary(usl_dat)
    usl_row_count = nr
    print(f"  {nr} rows, row_size={rs}")
    for i in range(nr):
        base = 4 + i * rs
        words_row = struct.unpack_from('<Q', usl_dat, base + words_off)[0]
        ivi_row   = struct.unpack_from('<Q', usl_dat, base + ivi_off)[0]
        entry = words.get(int(words_row), {})
        name = entry.get('text', '') if isinstance(entry, dict) else ''
        if name and ivi_row < 1_000_000:
            ivi_key = int(ivi_row)
            if ivi_key not in usl_ivi_to_names:
                usl_ivi_to_names[ivi_key] = []
            usl_ivi_to_names[ivi_key].append(name)
    print(f"  {len(usl_ivi_to_names)} distinct IVI keys with unique names")
    multi = {k: v for k, v in usl_ivi_to_names.items() if len(v) > 1}
    print(f"  IVI keys with MULTIPLE unique names: {len(multi)}")
    for k, v in list(multi.items())[:5]:
        print(f"    IVI[{k}] -> {v}")
else:
    print("  NOT FOUND")

# ─────────────────────────────────────────────────────────────────────────────
# Load BaseItemTypes: join metadata_path -> IVI -> unique_name
# ─────────────────────────────────────────────────────────────────────────────
print("\n--- Loading BaseItemTypes ---")
bit_dat = load_bundle_file('Data/Balance/BaseItemTypes.datc64') or \
          load_bundle_file('Data/BaseItemTypes.datc64')
path_to_uniques = {}
if bit_dat and usl_ivi_to_names:
    t = get_table_schema('BaseItemTypes')
    offs = get_col_offsets(t, 'Id', 'ItemVisualIdentity')
    id_off  = offs.get('Id', 0)
    ivi_off = offs.get('ItemVisualIdentity', 0)
    print(f"  Id@{id_off}, ItemVisualIdentity@{ivi_off}")
    nr, rs, vb = find_boundary(bit_dat)
    print(f"  {nr} rows, row_size={rs}")
    for i in range(nr):
        base = 4 + i * rs
        id_str_off = struct.unpack_from('<I', bit_dat, base + id_off)[0]
        item_id = read_utf16(bit_dat, vb, id_str_off)
        if not item_id: continue
        ivi_row = int(struct.unpack_from('<Q', bit_dat, base + ivi_off)[0])
        if ivi_row in usl_ivi_to_names:
            path_to_uniques[item_id] = usl_ivi_to_names[ivi_row]

    print(f"\n  Total metadata_path -> unique_name mappings: {len(path_to_uniques)}")

    print("\n  Flask/Charm entries:")
    for path, names in sorted(path_to_uniques.items()):
        if 'flask' in path.lower() or 'charm' in path.lower():
            print(f"    {path.split('/')[-1]:30s} -> {names}")

    print("\n  First 15 entries (any type):")
    for path, names in list(path_to_uniques.items())[:15]:
        print(f"    {path.split('/')[-1]:40s} -> {names}")

    # Count single vs multiple
    single = sum(1 for v in path_to_uniques.values() if len(v) == 1)
    multi  = sum(1 for v in path_to_uniques.values() if len(v) > 1)
    print(f"\n  Single unique per base: {single}, Multiple per base: {multi}")

# ─────────────────────────────────────────────────────────────────────────────
# Strategy 7: Debug IVI join — print IVI row indices for known items
# This confirms whether BIT IVI and USL IVI overlap at all
# ─────────────────────────────────────────────────────────────────────────────
print("\n=== Strategy 7: IVI row index debug ===")
if bit_dat and usl_ivi_to_names:
    t2 = get_table_schema('BaseItemTypes')
    offs2 = get_col_offsets(t2, 'Id', 'ItemVisualIdentity')
    id_off2  = offs2.get('Id', 0)
    ivi_off2 = offs2.get('ItemVisualIdentity', 0)
    nr2, rs2, vb2 = find_boundary(bit_dat)
    print("  BIT IVI rows for flask/charm items:")
    for i in range(nr2):
        base = 4 + i * rs2
        id_str_off = struct.unpack_from('<I', bit_dat, base + id_off2)[0]
        item_id = read_utf16(bit_dat, vb2, id_str_off)
        if not item_id: continue
        if 'charm' in item_id.lower() or 'fourflask' in item_id.lower():
            ivi = int(struct.unpack_from('<Q', bit_dat, base + ivi_off2)[0])
            in_usl = ivi in usl_ivi_to_names
            print(f"    {item_id.split('/')[-1]:30s}  IVI_row={ivi}  in_USL={in_usl}")
    print(f"\n  USL IVI key range: {min(usl_ivi_to_names)}-{max(usl_ivi_to_names)}")
    print(f"  USL sample (charm/flask names):")
    for k, v in usl_ivi_to_names.items():
        if any('roar' in n.lower() or 'charm' in n.lower() or 'flask' in n.lower() for n in v):
            print(f"    IVI[{k}] -> {v}")
            if len([k2 for k2 in usl_ivi_to_names if any('roar' in n.lower() or 'charm' in n.lower() for n in usl_ivi_to_names[k2])]) > 10:
                break

# ─────────────────────────────────────────────────────────────────────────────
# Strategy 8: ItemVisualIdentity.dat — get art paths for USL IVI rows
# and BIT IVI rows, to see if paths share a common identifier
# ─────────────────────────────────────────────────────────────────────────────
print("\n=== Strategy 8: ItemVisualIdentity art paths ===")
ivi_dat = (load_bundle_file('Data/Balance/ItemVisualIdentity.datc64') or
           load_bundle_file('Data/ItemVisualIdentity.datc64'))
if ivi_dat and usl_ivi_to_names:
    print("  IVI schema:")
    dump_table_schema('ItemVisualIdentity')
    nr_ivi, rs_ivi, vb_ivi = find_boundary(ivi_dat)
    print(f"  {nr_ivi} IVI rows, row_size={rs_ivi}")
    t_ivi = get_table_schema('ItemVisualIdentity')
    offs_ivi = get_col_offsets(t_ivi, 'Id', 'DDSFile', 'AOFile')
    id_off_ivi = offs_ivi.get('Id', 0)
    dds_off = offs_ivi.get('DDSFile', offs_ivi.get('AOFile', 8))
    print(f"  Id@{id_off_ivi}, DDSFile/AOFile@{dds_off}")

    print("\n  IVI paths for USL unique keys (first 15):")
    shown = 0
    for ivi_key in sorted(usl_ivi_to_names.keys())[:50]:
        if ivi_key >= nr_ivi: continue
        base = 4 + ivi_key * rs_ivi
        path_off = struct.unpack_from('<I', ivi_dat, base + id_off_ivi)[0]
        path = read_utf16(ivi_dat, vb_ivi, path_off)
        if path:
            names = usl_ivi_to_names[ivi_key]
            print(f"    IVI[{ivi_key:5d}] {names[0]:35s} -> {path}")
            shown += 1
            if shown >= 15: break

    # Flask/charm USL entries specifically
    print("\n  USL IVI paths for charm/flask uniques:")
    for ivi_key, names in usl_ivi_to_names.items():
        if ivi_key >= nr_ivi: continue
        base = 4 + ivi_key * rs_ivi
        path_off = struct.unpack_from('<I', ivi_dat, base + id_off_ivi)[0]
        path = read_utf16(ivi_dat, vb_ivi, path_off)
        if path and ('charm' in path.lower() or 'flask' in path.lower() or 'valako' in path.lower()):
            print(f"    IVI[{ivi_key}] {names} -> {path}")

    # Also show BIT IVI paths for charms
    if bit_dat:
        t2 = get_table_schema('BaseItemTypes')
        offs2 = get_col_offsets(t2, 'Id', 'ItemVisualIdentity')
        nr2, rs2, vb2 = find_boundary(bit_dat)
        print("\n  BIT IVI paths for charm items:")
        for i in range(nr2):
            base = 4 + i * rs2
            id_str_off = struct.unpack_from('<I', bit_dat, base + offs2['Id'])[0]
            item_id = read_utf16(bit_dat, vb2, id_str_off)
            if not item_id or 'charm' not in item_id.lower(): continue
            ivi_row = int(struct.unpack_from('<Q', bit_dat, base + offs2['ItemVisualIdentity'])[0])
            if ivi_row >= nr_ivi: continue
            base_ivi = 4 + ivi_row * rs_ivi
            path_off = struct.unpack_from('<I', ivi_dat, base_ivi + id_off_ivi)[0]
            path = read_utf16(ivi_dat, vb_ivi, path_off)
            print(f"    {item_id.split('/')[-1]:30s}  IVI[{ivi_row}] -> {path}")
else:
    print("  IVI dat not found")

# ─────────────────────────────────────────────────────────────────────────────
# Strategy 9: ModFamily approach — genType=3 mod → ModFamily.Id → unique_name?
# ─────────────────────────────────────────────────────────────────────────────
print("\n=== Strategy 9: ModFamily schema and sample data ===")
dump_table_schema('ModFamily')
mf_dat = (load_bundle_file('Data/Balance/ModFamily.datc64') or
          load_bundle_file('Data/ModFamily.datc64'))
if mf_dat:
    t_mf = get_table_schema('ModFamily')
    offs_mf = get_col_offsets(t_mf, 'Id', 'Name')
    nr_mf, rs_mf, vb_mf = find_boundary(mf_dat)
    print(f"  {nr_mf} ModFamily rows, row_size={rs_mf}")
    print(f"  Id@{offs_mf.get('Id',0)}, Name@{offs_mf.get('Name','?')}")
    # Print first 10 ModFamily rows
    print("  First 10 ModFamily entries:")
    for i in range(min(10, nr_mf)):
        base = 4 + i * rs_mf
        id_off_mf = offs_mf.get('Id', 0)
        id_str_off = struct.unpack_from('<I', mf_dat, base + id_off_mf)[0]
        fam_id = read_utf16(mf_dat, vb_mf, id_str_off)
        name_str = ''
        if 'Name' in offs_mf:
            n_off = struct.unpack_from('<I', mf_dat, base + offs_mf['Name'])[0]
            name_str = read_utf16(mf_dat, vb_mf, n_off)
        print(f"    [{i}] Id={fam_id!r:50s}  Name={name_str!r}")

    # Now load Mods.dat and for genType=3 mods, get their ModFamily rows
    mods_dat = load_bundle_file('Data/Balance/Mods.datc64')
    if mods_dat:
        t_mods = get_table_schema('Mods')
        offs_mods = get_col_offsets(t_mods, 'Id', 'GenerationType', 'Families')
        nr_mods, rs_mods, vb_mods = find_boundary(mods_dat)
        print("\n  genType=3 mods with their ModFamily (first 15):")
        shown = 0
        for i in range(nr_mods):
            base = 4 + i * rs_mods
            gen = struct.unpack_from('<i', mods_dat, base + offs_mods.get('GenerationType', 106))[0]
            if gen != 3: continue
            id_off_m = offs_mods.get('Id', 0)
            id_str_off = struct.unpack_from('<I', mods_dat, base + id_off_m)[0]
            mod_id = read_utf16(mods_dat, vb_mods, id_str_off)
            # Families is an array foreignrow: offset gives (count, ptr) to var section
            fam_off = offs_mods.get('Families', 110)
            fam_count = struct.unpack_from('<Q', mods_dat, base + fam_off)[0]
            fam_ptr   = struct.unpack_from('<Q', mods_dat, base + fam_off + 8)[0]
            fam_names = []
            for j in range(min(int(fam_count), 4)):
                fam_row = struct.unpack_from('<Q', mods_dat, vb_mods + int(fam_ptr) + j * 16)[0]
                fam_row = int(fam_row)
                if 0 <= fam_row < nr_mf:
                    fb = 4 + fam_row * rs_mf
                    fid_off = struct.unpack_from('<I', mf_dat, fb + offs_mf.get('Id', 0))[0]
                    fam_names.append(read_utf16(mf_dat, vb_mf, fid_off))
            print(f"    {mod_id:55s}  families={fam_names}")
            shown += 1
            if shown >= 15: break
else:
    print("  ModFamily dat not found")
