"""Regenerate PoE2_Inspector.CT from poe2_ce_inspector.lua"""
import pathlib, textwrap, re

ROOT   = pathlib.Path(__file__).parent
LUA    = (ROOT / "poe2_ce_inspector.lua").read_text(encoding="utf-8")
CT_OUT = ROOT / "PoE2_Inspector.CT"

BUTTONS = [
    (10, "[Btn] Scan + Refresh",        "poe2_scan()\npoe2_refresh()"),
    (11, "[Btn] List Entities (20)",     "poe2_list_entities(20)"),
    (12, "[Btn] Chain Only",             "poe2_refresh()"),
    (13, "[Toggle] Live Refresh (2s)",
         "_liveTimer=createTimer(nil,false)\n_liveTimer.Interval=2000\n"
         "_liveTimer.OnTimer=function() poe2_refresh() end\n_liveTimer.Enabled=true\n"
         'print("[PoE2] Live-Refresh aktiv")',
         'if _liveTimer then _liveTimer.Enabled=false _liveTimer.destroy() '
         '_liveTimer=nil print("[PoE2] Live-Refresh gestoppt") end'),
]

def btn_xml(btn):
    eid, desc, script = btn[0], btn[1], btn[2]
    drop = btn[3] if len(btn) > 3 else None
    drop_tag = f"""\n      <DropScript>{{$lua}}\n{drop}\n{{$asm}}\n</DropScript>""" if drop else ""
    return (
        f'      <CheatEntry><ID>{eid}</ID><Description>"{desc}"</Description>'
        f'<Script>{{$lua}}\n{script}\n{{$asm}}\n</Script>'
        f'{drop_tag}'
        f'<VariableType>Auto Assembler Script</VariableType></CheatEntry>'
    )

btn_xml_all = "\n".join(btn_xml(b) for b in BUTTONS)

ct = f"""<?xml version="1.0" encoding="utf-8"?>
<CheatTable CheatEngineTableVersion="45">
  <CheatEntries>
    <CheatEntry><ID>1</ID><Description>"=== PoE2 Inspector ==="</Description><GroupHeader>1</GroupHeader><Options moHideChildren="0"/><Entries>
      <CheatEntry><ID>2</ID><Description>"[INFO] Lua Engine -&gt; View -&gt; Output"</Description><GroupHeader>1</GroupHeader><Options moHideChildren="0"/><Entries/></CheatEntry>
{btn_xml_all}
      <CheatEntry><ID>20</ID><Description>"--- Dynamische Adressen ---"</Description><GroupHeader>1</GroupHeader><Options moHideChildren="0"/><Entries/></CheatEntry>
    </Entries></CheatEntry>
  </CheatEntries>
  <LuaScript><![CDATA[
{LUA}
]]></LuaScript>
</CheatTable>
"""

CT_OUT.write_text(ct, encoding="utf-8")
print(f"Written {CT_OUT}  ({CT_OUT.stat().st_size} bytes)")
