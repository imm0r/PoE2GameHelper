import json

schema_path = r'e:\ahk\poe2\GameHelper\schema.min.json'
with open(schema_path, 'r', encoding='utf-8') as f:
    schema = json.load(f)

rows = [t for t in schema['tables'] if t['name'] == 'MonsterVarieties']
print(f'MonsterVarieties variants: {len(rows)}')
for t in rows:
    print(f"\nvalidFor={t.get('validFor')} columns={len(t['columns'])}")
    for i, c in enumerate(t['columns']):
        name = c.get('name') or '(noname)'
        ref = ((c.get('references') or {}).get('table') or '')
        print(f"  [{i:02d}] {name:36s} type={c['type']:10s} array={str(c.get('array', False)):5s} localized={str(c.get('localized', False)):5s} ref={ref}")
