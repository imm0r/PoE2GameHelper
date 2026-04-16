"""Debug the string format in Stats.datc64 variable section."""
import sys, struct

sys.path.insert(0, r'C:\Users\m0nsu\AppData\Local\Packages\PythonSoftwareFoundation.Python.3.13_qbz5n2kfra8p0\LocalCache\local-packages\Python313\site-packages')
import ooz

def decompress_bundle_partial(bundle_bytes, file_offset, file_size):
    chunk_count = struct.unpack_from('<I', bundle_bytes, 36)[0]
    chunk_size  = struct.unpack_from('<I', bundle_bytes, 40)[0]
    chunk_sizes = struct.unpack_from(f'<{chunk_count}I', bundle_bytes, 60)
    data_start  = 60 + chunk_count * 4
    first_chunk = file_offset // chunk_size
    last_chunk  = min((file_offset + file_size - 1) // chunk_size, chunk_count - 1)
    comp_offset = data_start
    for i in range(first_chunk): comp_offset += chunk_sizes[i]
    result = bytearray()
    remaining = struct.unpack_from('<I', bundle_bytes, 0)[0] - first_chunk * chunk_size
    for i in range(first_chunk, last_chunk + 1):
        dc = min(chunk_size, remaining)
        result.extend(ooz.decompress(bundle_bytes[comp_offset:comp_offset+chunk_sizes[i]], dc))
        comp_offset += chunk_sizes[i]; remaining -= dc
    chunk_start = first_chunk * chunk_size
    return bytes(result[file_offset - chunk_start:file_offset - chunk_start + file_size])

bundle_path = r'H:\SteamLibrary\steamapps\common\Path of Exile 2\Bundles2\Folders/data/28/balance.datc64.bundle.bin'
with open(bundle_path, 'rb') as f: bdata = f.read()
dat = decompress_bundle_partial(bdata, 5277756, 4807822)

magic_pos = dat.find(b'\xbb' * 8)
var_data_start = magic_pos + 8
row_size = 106
num_rows = struct.unpack_from('<I', dat, 0)[0]
print(f'num_rows={num_rows}, magic_pos={magic_pos}, var_data_start={var_data_start}')

# Look at the first 256 bytes of the variable section
print(f'\nFirst 256 bytes of variable section (hex + ascii):')
vdata = dat[var_data_start:var_data_start+256]
for i in range(0, len(vdata), 16):
    chunk = vdata[i:i+16]
    hex_str = ' '.join(f'{b:02x}' for b in chunk)
    asc_str = ''.join(chr(b) if 32 <= b < 127 else '.' for b in chunk)
    print(f'  [{i:4d}] {hex_str:<48s}  {asc_str}')

print()
# Check first 10 rows - print Id offset and resolve string
print('First 10 rows: Id column (offset 0, size 8):')
for row_idx in range(10):
    row_base = 4 + row_idx * row_size
    id_offset = struct.unpack_from('<Q', dat, row_base + 0)[0]
    hash32_u = struct.unpack_from('<I', dat, row_base + 34)[0]
    hash32 = struct.unpack('<i', struct.pack('<I', hash32_u))[0]

    # Try reading as UTF-16LE
    str_pos = var_data_start + id_offset
    end = str_pos
    while end + 1 < len(dat) and not (dat[end] == 0 and dat[end+1] == 0):
        end += 2
    raw = dat[str_pos:end]
    stat_id_utf16 = raw.decode('utf-16-le', errors='replace')

    # Also try reading as UTF-8/ASCII
    end2 = str_pos
    while end2 < len(dat) and dat[end2] != 0:
        end2 += 1
    stat_id_ascii = dat[str_pos:end2].decode('ascii', errors='replace')

    print(f'  [{row_idx:3d}] id_offset={id_offset:8d}  hash32={hash32:12d}  utf16={stat_id_utf16!r}  ascii={stat_id_ascii!r}')
