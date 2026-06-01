"""Scan Tiny bundles for ANY dat64 with 65-byte rows (Stats.dat64 schema)."""
import sys, os, struct

OOZ_PATH = r'C:\Users\m0nsu\AppData\Local\Packages\PythonSoftwareFoundation.Python.3.13_qbz5n2kfra8p0\LocalCache\local-packages\Python313\site-packages'
sys.path.insert(0, OOZ_PATH)
import ooz

GAME_PATH   = r'H:\SteamLibrary\steamapps\common\Path of Exile 2'
BUNDLES2    = os.path.join(GAME_PATH, 'Bundles2')
DAT64_MAGIC = b'\xbb' * 8
ROW_SIZE    = 65


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


def try_read_utf16le_str(data, pos, max_len=100):
    end = pos
    while end + 1 < len(data) and end - pos < max_len * 2:
        if data[end] == 0 and data[end + 1] == 0:
            break
        end += 2
    if end == pos:
        return ''
    try:
        return data[pos:end].decode('utf-16-le')
    except Exception:
        return ''


def find_stats_dat64(decomp):
    """Search decompressed bundle for a dat with row_size=65 and stat-like Id strings."""
    results = []
    pos = 0
    while True:
        mp = decomp.find(DAT64_MAGIC, pos)
        if mp < 0:
            break

        # Try all plausible num_rows values
        for num_rows in range(500, 10001):
            dat_start = mp - 4 - num_rows * ROW_SIZE
            if dat_start < 0:
                break  # As num_rows grows, dat_start shrinks → break when negative
            hdr = struct.unpack_from('<I', decomp, dat_start)[0]
            if hdr == num_rows:
                # Valid header! Check if it looks like Stats.dat64
                var_start = mp + 8
                if var_start + 10 >= len(decomp):
                    continue
                # Row 0: Id at offset 0 (8-byte string offset)
                str_off = struct.unpack_from('<Q', decomp, dat_start + 4)[0]
                if str_off > 1024 * 1024:
                    continue
                str_pos = var_start + str_off
                if str_pos >= len(decomp):
                    continue
                st = try_read_utf16le_str(decomp, str_pos)
                # Stats.dat64 IDs look like: 'minimum_added_physical_damage'
                # They are lowercase, alpha/underscore, contain underscore
                if (st and len(st) >= 3 and all(c.isalnum() or c == '_' for c in st)):
                    # Read 5 more sample IDs and HASH32
                    h32 = struct.unpack_from('<i', decomp, dat_start + 4 + 26)[0]
                    results.append({
                        'dat_start': dat_start, 'magic_pos': mp,
                        'num_rows': num_rows, 'var_start': var_start,
                        'sample_id_0': st, 'hash32_0': h32,
                    })
                    break  # Found one valid interpretation for this magic pos

        pos = mp + 1
    return results


# Only scan Tiny.V0.bundle.bin first as a quick check
print('Scanning Tiny.V0.bundle.bin ...')
bpath = os.path.join(BUNDLES2, 'Tiny.V0.bundle.bin')
with open(bpath, 'rb') as f:
    bdata = f.read()
decomp = decompress_bundle(bdata)
print(f'Decompressed: {len(decomp)//1024}KB')
print(f'DAT64 magic occurrences: {decomp.count(DAT64_MAGIC)}')

# Show ALL magic positions first
pos = 0
all_magic = []
while True:
    mp = decomp.find(DAT64_MAGIC, pos)
    if mp < 0:
        break
    all_magic.append(mp)
    pos = mp + 1

print(f'Magic positions (first 20): {all_magic[:20]}')

# For first few magic pos, show what's before them
for mp in all_magic[:5]:
    before4 = struct.unpack_from('<I', decomp, max(0, mp-4))[0] if mp >= 4 else 0
    print(f'  magic@{mp}: before4={before4}, before4%65={before4%65}')
    # Try best matching num_rows
    for num_rows in range(100, 20001):
        ds = mp - 4 - num_rows * ROW_SIZE
        if ds < 0:
            break
        hdr = struct.unpack_from('<I', decomp, ds)[0]
        if hdr == num_rows:
            print(f'    -> MATCH: num_rows={num_rows}, dat_start={ds}')
            break
