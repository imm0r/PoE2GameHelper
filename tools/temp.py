import json, sys
with open(r'E:\ahk\poe2\GameHelper\schema.min.json') as f:
    s = json.load(f)

# Find ALL Mods tables (any validFor)
for t in s['tables']:
    if t['name'] == 'Mods':
        print(f"\n=== Mods table validFor={t.get('validFor')} ===")
        offset = 0
        for c in t['columns']:
            arr = c.get('array', False)
            typ = c['type']
            sizes = {'string':8,'bool':1,'i8':1,'u8':1,'i16':2,'u16':2,'i32':4,'u32':4,'f32':4,'enumrow':4,'rid':4,'row':8,'foreignrow':16,'_':0}
            sz = 16 if arr else sizes.get(typ, 0)
            name = c.get('name') or '(unnamed)'
            print(f"  +{offset:4d}  {name:40s}  {typ:12s}  array={arr}  size={sz}")
            offset += sz
        print(f"  Total row_size = {offset}")
