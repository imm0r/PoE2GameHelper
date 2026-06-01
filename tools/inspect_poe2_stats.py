import json

with open(r'e:\ahk\poe2\GameHelper\schema.min.json') as f:
    s = json.load(f)

# PoE2 Stats table (validFor=2)
stats_poe2 = next(t for t in s['tables'] if t['name'] == 'Stats' and t.get('validFor', 0) == 2)
print(f'PoE2 Stats table: validFor={stats_poe2["validFor"]}  columns={len(stats_poe2["columns"])}')
print()

# .datc64 sizes: row=8, foreignrow=16, array=16 (8 offset + 8 count)
def col_sz(col):
    ctype = col['type']
    is_array = col.get('array', False)
    if is_array: return 16
    return {'string':8,'bool':1,'i16':2,'u16':2,'i32':4,'u32':4,'f32':4,
            'row':8,'enumrow':4,'foreignrow':16,'rid':4,'_':0}.get(ctype, 0)

off = 0
for i, col in enumerate(stats_poe2['columns']):
    name = col.get('name') or '(noname)'
    sz = col_sz(col)
    is_array = col.get('array', False)
    print(f'  [{i:2d}] offset={off:3d}  sz={sz:2d}  {name:40s}  {col["type"]}  array={is_array}')
    off += sz

print(f'\nTotal row_size = {off}')
