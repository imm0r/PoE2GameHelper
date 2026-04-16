import json

with open(r'e:\ahk\poe2\GameHelper\schema.min.json') as f:
    s = json.load(f)

all_stats = [t for t in s['tables'] if t['name'] == 'Stats']
print(f'Found {len(all_stats)} Stats table(s):')
for t in all_stats:
    ncols = len(t['columns'])
    vf = t.get('validFor', '?')
    print(f'  validFor={vf}  columns={ncols}')

# Also compute .datc64 row_size for the PoE2 table
# In .datc64: string=8, row=8, foreignrow=16, array prefix is 16 bytes
# In .dat64: string=8, row=4, foreignrow=8
print()
print('=== All variants row_size computation ===')
for t in all_stats:
    vf = t.get('validFor', '?')
    for row_sz, foreign_sz in [(4,8),(8,16)]:
        off = 0
        for col in t['columns']:
            ctype = col['type']
            is_array = col.get('array', False)
            if is_array:
                sz = 8 + 8  # offset + count in variable section
            elif ctype == 'string': sz = 8
            elif ctype == 'bool': sz = 1
            elif ctype in ('i16','u16'): sz = 2
            elif ctype in ('i32','u32','f32','enumrow'): sz = 4
            elif ctype == 'row': sz = row_sz
            elif ctype == 'foreignrow': sz = foreign_sz
            else: sz = 0
            off += sz
        print(f'  validFor={vf}  row={row_sz}  foreignrow={foreign_sz}  => row_size={off}')

print()
print(f'Actual row_size from dat file: 106.0 bytes')
