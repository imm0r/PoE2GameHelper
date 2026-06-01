import json, struct, sys

with open(r'e:\ahk\poe2\GameHelper\schema.min.json', 'r') as f:
    schema = json.load(f)

stats = next(t for t in schema['tables'] if t['name'] == 'Stats')
print(f"validFor: {stats.get('validFor','?')}")
print(f"Columns ({len(stats['columns'])}):\n")

TYPE_SIZES_DAT64 = {
    'string': 8, 'bool': 1,
    'i16': 2, 'u16': 2,
    'i32': 4, 'u32': 4, 'f32': 4,
    'row': 4, 'enumrow': 4,
    'foreignrow': 8, 'rid': 4, '_': 0,
    'array': 8,  # array = offset+size in var section (PoE1)
}

offset = 0
for i, col in enumerate(stats['columns']):
    name = col.get('name') or '(noname)'
    ctype = col['type']
    is_array = col.get('array', False)
    if is_array:
        sz = 16  # array: 8-byte offset + 8-byte count in .datc64
    else:
        sz = TYPE_SIZES_DAT64.get(ctype, 0)
    print(f"  [{i:2d}] offset={offset:3d} sz={sz:2d}  {name:40s}  type={ctype}  array={is_array}")
    offset += sz

print(f"\n  Total row_size = {offset}")

# Also try with row=8, foreignrow=16 (larger sizes)
TYPE_SIZES_ALT = dict(TYPE_SIZES_DAT64)
TYPE_SIZES_ALT['row'] = 8
TYPE_SIZES_ALT['foreignrow'] = 16

offset2 = 0
for col in stats['columns']:
    ctype = col['type']
    is_array = col.get('array', False)
    if is_array:
        sz = 16
    else:
        sz = TYPE_SIZES_ALT.get(ctype, 0)
    offset2 += sz
print(f"  Alt row_size (row=8, foreignrow=16) = {offset2}")

# Actual magic position data:
actual_magic = 2638132
num_rows = 24888
actual_row_size = (actual_magic - 4) / num_rows
print(f"\nActual dat row_size from magic position: {actual_row_size} bytes")
print(f"  (magic_pos={actual_magic}, num_rows={num_rows})")
