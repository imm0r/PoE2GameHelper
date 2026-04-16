"""Scan Tiny bundles for Stats.dat64 by looking for dat64 magic + matching row structure."""
import sys, os, struct

OOZ_PATH = r'C:\Users\m0nsu\AppData\Local\Packages\PythonSoftwareFoundation.Python.3.13_qbz5n2kfra8p0\LocalCache\local-packages\Python313\site-packages'
sys.path.insert(0, OOZ_PATH)
import ooz

GAME_PATH  = r'H:\SteamLibrary\steamapps\common\Path of Exile 2'
BUNDLES2   = os.path.join(GAME_PATH, 'Bundles2')
DAT64_MAGIC = b'\xbb' * 8
ROW_SIZE    = 65   # from schema: Stats.dat64 row size

def decompress_bundle(bundle_bytes):
    uncomp_size = struct.unpack_from('<I', bundle_bytes, 0)[0]
    chunk_count = struct.unpack_from('<I', bundle_bytes, 36)[0]
    chunk_size  = struct.unpack_from('<I', bundle_bytes, 40)[0]
    chunk_sizes = struct.unpack_from(f'<{chunk_count}I', bundle_bytes, 60)
    data_start  = 60 + chunk_count * 4
    result = bytearray(); offset = data_start; remaining = uncomp_size
    for cs in chunk_sizes:
        dc  = min(chunk_size, remaining)
        dec = ooz.decompress(bundle_bytes[offset:offset+cs], dc)
        result.extend(dec); offset += cs; remaining -= dc
    return bytes(result)

def try_read_utf16le_str(data, pos, max_len=200):
    end = pos
    while end + 1 < len(data) and end - pos < max_len * 2:
        if data[end] == 0 and data[end+1] == 0:
            break
        end += 2
    if end == pos:
        return ''
    try:
        return data[pos:end].decode('utf-16-le')
    except:
        return ''

def check_dat64_at(data, magic_pos):
    """Check if there's a valid Stats.dat64 at magic_pos."""
    raw_rows = magic_pos - 4
    if raw_rows <= 0 or raw_rows % ROW_SIZE != 0:
        return False, 0, 0, 0
    num_rows = raw_rows // ROW_SIZE
    if not (200 <= num_rows <= 15000):
        return False, 0, 0, 0
    dat_start = magic_pos - 4 - raw_rows
    if dat_start < 0:
        return False, 0, 0, 0
    hdr = struct.unpack_from('<I', data, dat_start)[0]
    if hdr != num_rows:
        return False, 0, 0, 0
    var_start = magic_pos + 8
    if var_start + 10 >= len(data):
        return False, 0, 0, 0
    str_off = struct.unpack_from('<Q', data, dat_start + 4)[0]
    if str_off > 10 * 1024 * 1024:
        return False, 0, 0, 0
    str_pos = var_start + str_off
    if str_pos >= len(data):
        return False, 0, 0, 0
    st = try_read_utf16le_str(data, str_pos)
    if st and all(c.isalnum() or c == '_' for c in st) and len(st) >= 3:
        return True, num_rows, dat_start, var_start
    return False, 0, 0, 0

# Scan ALL Tiny bundles (base + .1 variants)
all_tiny = sorted(
    f for f in os.listdir(BUNDLES2)
    if f.startswith('Tiny.') and f.endswith('.bundle.bin')
)
print(f'Scanning {len(all_tiny)} Tiny bundles for Stats.dat64 (row_size={ROW_SIZE}) ...\n')

for bname in all_tiny:
    bpath = os.path.join(BUNDLES2, bname)
    sz_kb = os.path.getsize(bpath) // 1024
    print(f'  [{bname}] ({sz_kb}KB) ...', end=' ', flush=True)
    with open(bpath, 'rb') as f:
        bdata = f.read()
    try:
        decomp = decompress_bundle(bdata)
    except Exception as e:
        print(f'ERR: {e}'); continue

    print(f'decomp={len(decomp)//1024}KB, searching ...', end=' ', flush=True)
    found_count = 0
    pos = 0
    while True:
        mp = decomp.find(DAT64_MAGIC, pos)
        if mp < 0:
            break
        ok, nrows, dat_start, var_start = check_dat64_at(decomp, mp)
        if ok:
            found_count += 1
            sample_ids = []
            for ri in range(min(5, nrows)):
                off0 = struct.unpack_from('<Q', decomp, dat_start + 4 + ri * ROW_SIZE)[0]
                st = try_read_utf16le_str(decomp, var_start + off0)
                sample_ids.append(st or '?')
            h32 = struct.unpack_from('<i', decomp, dat_start + 4 + 26)[0]
            print(f'\n    >>> FOUND at magic_pos={mp}, rows={nrows}, HASH32[0]={h32}')
            print(f'        IDs: {sample_ids}')
        pos = mp + 1

    if found_count == 0:
        print('no candidates')
