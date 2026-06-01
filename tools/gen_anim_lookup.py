"""Generate animation_names.js from the C# Animation enum."""
import re, json, urllib.request

url = 'https://gitlab.com/bylafko/gamehelper2/-/raw/main/GameHelper/RemoteEnums/Animation.cs'
with urllib.request.urlopen(url) as resp:
    content = resp.read().decode('utf-8')

entries = re.findall(r'(\w+)\s*=\s*(0x[0-9A-Fa-f]+)', content)

js_entries = []
for name, hexval in entries:
    decimal = int(hexval, 16)
    readable = re.sub(r'(?<!^)(?=[A-Z])', ' ', name)
    js_entries.append(f'{decimal}:{json.dumps(readable)}')

js_obj = 'const ANIM_NAMES={' + ','.join(js_entries) + '};'

out = r'e:\ahk\poe2\GameHelper\ui\animation_names.js'
with open(out, 'w', encoding='utf-8') as f:
    f.write('// Auto-generated from GameHelper2 Animation.cs enum\n')
    f.write('// Maps CastType (int) -> human-readable animation name\n')
    f.write(js_obj + '\n')
    fn_line = 'function animName(id) { return ANIM_NAMES[id] || ("0x" + id.toString(16).toUpperCase()); }\n'
    f.write(fn_line)

print(f'Generated {len(js_entries)} entries -> {out}')
for k in [765, 766, 0, 1, 29]:
    name_map = {int(h, 16): n for n, h in entries}
    name = name_map.get(k, '?')
    readable = re.sub(r'(?<!^)(?=[A-Z])', ' ', name)
    print(f'  {k} (0x{k:X}) -> {readable}')
