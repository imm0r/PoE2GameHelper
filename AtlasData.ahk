; AtlasData.ahk
; Loads the Atlas biome + content lookup tables (data/atlas_biomes.json,
; data/atlas_content.json) used to label and colour atlas map nodes in the
; overlay. Schema mirrors the reference plugin (github.com/danthespal/Atlas).
;
; Included by InGameStateMonitor.ahk

global g_atlasBiomes := Map()    ; biomeId (string) -> Map(label, color BGR, show)
global g_atlasContent := Map()   ; tag (string)     -> Map(label, abbrev, bg BGR, font BGR, show)
global g_atlasRender := 0        ; render snapshot (see RadarOverlay._RenderAtlas); 0 = nothing to draw

; Loads both lookup tables from data/. Safe to call once at startup; missing or
; malformed files just leave the maps empty (the overlay then skips labels).
AtlasData_Load()
{
    global g_atlasBiomes, g_atlasContent
    g_atlasBiomes := _AtlasLoadJsonMap(A_ScriptDir "\data\atlas_biomes.json", true)
    g_atlasContent := _AtlasLoadJsonMap(A_ScriptDir "\data\atlas_content.json", false)
}

; Parses one JSON object file into a flat lookup Map. isBiome selects which
; fields are read (BorderColor vs Abbrev/BackgroundColor/FontColor).
_AtlasLoadJsonMap(path, isBiome)
{
    out := Map()
    if !FileExist(path)
        return out
    raw := ""
    try raw := FileRead(path, "UTF-8")
    if (raw = "")
        return out
    data := 0
    try data := JsonFull_Parse(raw)
    if !(data is Map)
        return out
    for key, v in data
    {
        if (key = "_comment" || !(v is Map))
            continue
        rec := Map()
        rec["label"] := v.Has("Label") ? v["Label"] : key
        rec["show"] := v.Has("Show") ? (v["Show"] ? true : false) : true
        if isBiome
            rec["color"] := _AtlasRgbaToBgr(v.Has("BorderColor") ? v["BorderColor"] : 0)
        else
        {
            rec["abbrev"] := v.Has("Abbrev") ? v["Abbrev"] : key
            rec["bg"] := _AtlasRgbaToBgr(v.Has("BackgroundColor") ? v["BackgroundColor"] : 0)
            rec["font"] := _AtlasRgbaToBgr(v.Has("FontColor") ? v["FontColor"] : 0)
        }
        out[key] := rec
    }
    return out
}

; Converts a [r,g,b,a] float array (0..1) to a GDI BGR int (alpha dropped — the
; overlay composites separately). Returns white on bad input.
_AtlasRgbaToBgr(arr)
{
    if !(arr is Array) || arr.Length < 3
        return 0xFFFFFF
    r := Max(0, Min(255, Round((arr[1] + 0) * 255)))
    g := Max(0, Min(255, Round((arr[2] + 0) * 255)))
    b := Max(0, Min(255, Round((arr[3] + 0) * 255)))
    return (b << 16) | (g << 8) | r
}

; Biome record for an id (int or string), or 0 if unknown.
AtlasBiome(id)
{
    global g_atlasBiomes
    key := "" id
    return g_atlasBiomes.Has(key) ? g_atlasBiomes[key] : 0
}

; Content record for a tag, or 0 if unknown.
AtlasContent(tag)
{
    global g_atlasContent
    return g_atlasContent.Has(tag) ? g_atlasContent[tag] : 0
}
