"""Test with uint32 offset only (not array)."""
import sys, struct

sys.path.insert(0, r'C:\Users\m0nsu\AppData\Local\Packages\PythonSoftwareFoundation.Python.3.13_qbz5n2kfra8p0\LocalCache\local-packages\Python313\site-packages')
import ooz

def decompress_bundle_partial(bundle_bytes, file_offset, file_size):
    chunk_count = struct.unpack_from('<I', bundle_bytes, 36)[0]
    chunk_size  = struct.unpack_from('<I', bundle_bytes, 40)[0]
    chunk_sizes = struct.unpack_from(f'<{chunk_count}I', bundle_bytes, 60)
    data_start = 60 + chunk_count * 4
    first_chunk = file_offset // chunk_size
    last_chunk = min((file_offset + file_size - 1) // chunk_size, chunk_count - 1)
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

print(f'Test: read first 8 rows as simple strings')
print()

for row_idx in range(8):
    row_base = 4 + row_idx * row_size
    hash32_u = struct.unpack_from('<I', dat, row_base + 34)[0]
    hash32 = struct.unpack('<i', struct.pack('<I', hash32_u))[0]
    
    # Try different interpretations
    # Option 1: first 4 bytes as offset
    offset1 = struct.unpack_from('<I', dat, row_base + 0)[0]
    str_pos1 = var_data_start + offset1
    end1 = str_pos1
    while end1 + 1 < len(dat) and not (dat[end1] == 0 and dat[end1+1] == 0):
        end1 += 2
    raw1 = dat[str_pos1:end1]
    str1 = raw1.decode('utf-16-le', errors='replace')
    
    # Option 2: skip first 4 bytes, read offset from next 4
    offset2 = struct.unpack_from('<I', dat, row_base + 4)[0]
    str_pos2 = var_data_start + offset2
    end2 = str_pos2
    while end2 + 1 < len(dat) and not (dat[end2] == 0 and dat[end2+1] == 0):
        end2 += 2
    raw2 = dat[str_pos2:end2]
    str2 = raw2.decode('utf-16-le', errors='replace')
    
    # Option 3: treat as count@0 + offset@4
    count = struct.unpack_from('<I', dat, row_base + 0)[0]
    offset3 = struct.unpack_from('<I', dat, row_base + 4)[0]
    str_pos3 = var_data_start + offset3
    end3 = str_pos3 + count * 2  # count chars × 2 bytes each
    raw3 = dat[str_pos3:end3]
    str3 = raw3.decode('utf-16-le', errors='replace')
    
    print(f'[{row_idx}] hash={hash32:12d}')
    print(f'  opt1 (off@+0): {str1!r}')
    print(f'  opt2 (off@+4): {str2!r}')
    print(f'  opt3 (cnt@0 off@4, cnt={count}): {str3!r}')
    print()
