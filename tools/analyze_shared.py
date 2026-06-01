"""Analyze Shared.bundle.bin to understand dat64 structure in PoE2."""
import sys, struct, os

OOZ_PATH = r'C:\Users\m0nsu\AppData\Local\Packages\PythonSoftwareFoundation.Python.3.13_qbz5n2kfra8p0\LocalCache\local-packages\Python313\site-packages'
sys.path.insert(0, OOZ_PATH)
import ooz

BUNDLES2 = r'H:\SteamLibrary\steamapps\common\Path of Exile 2\Bundles2'
MAGIC = bytes([0xbb] * 8)


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


with open(os.path.join(BUNDLES2, 'Shared.bundle.bin'), 'rb') as f:
    bdata = f.read()
decomp = decompress_bundle(bdata)
print(f'Shared decompressed: {len(decomp):,} bytes')
print(f'Magic occurrences: {decomp.count(MAGIC)}')

mp = decomp.find(MAGIC)
print(f'First magic at: {mp}')
if mp > 0:
    print(f'Before 20 bytes: {decomp[max(0,mp-20):mp].hex()}')
    print(f'Magic 8 bytes:   {decomp[mp:mp+8].hex()}')
    print(f'After 40 bytes:  {decomp[mp+8:mp+48].hex()}')
    # Check header
    u4 = struct.unpack_from('<I', decomp, max(0, mp-4))[0]
    print(f'uint32 before magic: {u4}')

print(f'\nFirst 100 bytes: {decomp[:100].hex()}')
print(f'uint32[0]: {struct.unpack_from("<I", decomp, 0)[0]}')

# Try to find Stats identifier string
for search_bytes in [b'Stats', b'score', b'active_skill']:
    pos = decomp.find(search_bytes)
    if pos >= 0:
        print(f'\nFound {search_bytes} at offset {pos}')
        print(f'Context: {decomp[max(0,pos-20):pos+50].hex()}')
        txt = bytes([c if 32<=c<127 else 46 for c in decomp[max(0,pos-10):pos+30]])
        print(f'As text: {txt}')
