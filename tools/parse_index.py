"""Parse _.index.bin from PoE2 bundles to find Stats.dat64"""
import sys, struct, os

OOZ_PATH = r'C:\Users\m0nsu\AppData\Local\Packages\PythonSoftwareFoundation.Python.3.13_qbz5n2kfra8p0\LocalCache\local-packages\Python313\site-packages'
if OOZ_PATH not in sys.path:
    sys.path.insert(0, OOZ_PATH)

import ooz

GAME_PATH = r'H:\SteamLibrary\steamapps\common\Path of Exile 2'
BUNDLES2 = os.path.join(GAME_PATH, 'Bundles2')


def decompress_bundle(bundle_bytes):
    uncomp_size = struct.unpack_from('<I', bundle_bytes, 0)[0]
    chunk_count = struct.unpack_from('<I', bundle_bytes, 36)[0]
    chunk_size  = struct.unpack_from('<I', bundle_bytes, 40)[0]
    chunk_sizes = struct.unpack_from(f'<{chunk_count}I', bundle_bytes, 60)
    data_start  = 60 + chunk_count * 4
    result    = bytearray()
    offset    = data_start
    remaining = uncomp_size
    for cs in chunk_sizes:
        chunk_dc   = min(chunk_size, remaining)
        chunk_data = bundle_bytes[offset:offset+cs]
        dec = ooz.decompress(chunk_data, chunk_dc)
        result.extend(dec)
        offset    += cs
        remaining -= chunk_dc
    return bytes(result)


print('Loading _.index.bin ...')
with open(os.path.join(BUNDLES2, '_.index.bin'), 'rb') as f:
    idx_bundle = f.read()
print(f'  bundle size: {len(idx_bundle):,}')

print('Decompressing index ...')
idx_data = decompress_bundle(idx_bundle)
print(f'  decompressed: {len(idx_data):,} bytes')

# --- Parse bundle table ---
pos = 0
bundle_count = struct.unpack_from('<I', idx_data, pos)[0]; pos += 4
print(f'Bundle count: {bundle_count}')

bundles = []
for _ in range(bundle_count):
    name_len = struct.unpack_from('<I', idx_data, pos)[0]; pos += 4
    name     = idx_data[pos:pos+name_len].decode('utf-8'); pos += name_len
    unc_size = struct.unpack_from('<I', idx_data, pos)[0]; pos += 4
    bundles.append({'name': name, 'uncompressed_size': unc_size})

print(f'First 5 bundles: {[b["name"] for b in bundles[:5]]}')
print(f'Last  5 bundles: {[b["name"] for b in bundles[-5:]]}')

# --- Parse file table ---
file_count = struct.unpack_from('<I', idx_data, pos)[0]; pos += 4
print(f'File count: {file_count:,}')
print(f'File table starts at offset {pos}')

# Each file entry: uint64 hash, uint32 bundle_idx, uint32 file_offset, uint32 file_size
FILE_ENTRY_SIZE = 20  # 8 + 4 + 4 + 4
files = []
for i in range(file_count):
    entry = struct.unpack_from('<QIII', idx_data, pos); pos += FILE_ENTRY_SIZE
    files.append({'hash': entry[0], 'bundle_idx': entry[1], 'file_offset': entry[2], 'file_size': entry[3]})

print(f'Path data starts at offset {pos}')
print(f'Remaining bytes: {len(idx_data) - pos:,}')

# Show first few file entries
for fe in files[:3]:
    print(f'  hash={fe["hash"]:016x} bundle={fe["bundle_idx"]} offset={fe["file_offset"]} size={fe["file_size"]}')

# --- Suche Stats.dat64 im Pfad-Abschnitt ---
path_section = idx_data[pos:]
needle = b'Stats.dat64'
found_at = path_section.find(needle)
print(f'\nSearch "Stats.dat64" in path section: offset={found_at}')
if found_at >= 0:
    ctx = path_section[max(0,found_at-60):found_at+80]
    txt = bytes([c if 32<=c<127 else 46 for c in ctx])
    print(f'  context: {txt}')
    print(f'  hex:     {ctx.hex()}')

# Ersten 200 Bytes des Pfad-Abschnitts
print(f'\nFirst 200 bytes of path section (hex): {path_section[:200].hex()}')
print(f'First 200 bytes (text): {bytes([c if 32<=c<127 else 46 for c in path_section[:200]])}')
