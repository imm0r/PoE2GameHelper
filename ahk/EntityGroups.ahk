; EntityGroups.ahk
; User-defined, path-based entity grouping. Each group has a name, comma-separated match
; terms (matched against the entity path and its metaGroup), a color and an enabled flag.
; The web entity table, the radar coloring and the alert engine consume the resolved group.
; Managed from the Groups tab in the web UI; self-persisting to gamehelper_config.ini [Groups]
; (same pattern as LootPickup). Depends on ExtractMetaGroup (EntityFacts.ahk) and _JsStr
; (WebViewBridge.ahk). Included via TreeViewWatchlistPanel.ahk.

; Ordered list of group Maps: {name, terms, color, enabled}. First match wins.
global g_entityGroups := []

; Resolves the first enabled group whose any term is a substring of the entity path or its
; metaGroup. Early-returns when no groups exist so the per-entity radar cost stays near zero.
; Param: entityPath - full metadata path. Returns: the group Map, or 0 if none match.
ResolveEntityGroupByPath(entityPath)
{
    global g_entityGroups
    if (g_entityGroups.Length = 0)
        return 0
    return _ResolveGroupForHay(StrLower(entityPath) "|" StrLower(ExtractMetaGroup(entityPath)))
}

; Convenience wrapper: returns the resolved group name for a path, or "" when none matches.
ResolveEntityGroupNameByPath(entityPath)
{
    grp := ResolveEntityGroupByPath(entityPath)
    return (grp && grp.Has("name")) ? grp["name"] : ""
}

; Core matcher shared by the resolvers. hay is the lowercased "path|metaGroup" string.
; Returns the first enabled group with a matching term, or 0.
_ResolveGroupForHay(hay)
{
    global g_entityGroups
    for _, grp in g_entityGroups
    {
        if !(grp.Has("enabled") && grp["enabled"])
            continue
        for _, term in StrSplit(grp.Has("terms") ? grp["terms"] : "", ",")
        {
            t := Trim(StrLower(term))
            if (t != "" && InStr(hay, t))
                return grp
        }
    }
    return 0
}

; Converts an HTML "#RRGGBB" color string to a BGR integer (0xBBGGRR) for the GDI radar.
GroupColorToBgr(hex)
{
    h := Trim(hex)
    if (SubStr(h, 1, 1) = "#")
        h := SubStr(h, 2)
    if (StrLen(h) < 6)
        return 0xFFFFFF
    r := Integer("0x" SubStr(h, 1, 2))
    g := Integer("0x" SubStr(h, 3, 2))
    b := Integer("0x" SubStr(h, 5, 2))
    return (b << 16) | (g << 8) | r
}

; Rebuilds the group list from the web UI payload (an Array of {name,terms,color,enabled} Maps).
; Invalid/blank rows are skipped. Used by the BridgeDispatch "SetGroups" case.
_ApplyEntityGroups(arr)
{
    global g_entityGroups
    g_entityGroups := []
    if !(arr && Type(arr) = "Array")
        return

    for _, g in arr
    {
        if !(g && Type(g) = "Map")
            continue
        name    := g.Has("name")  ? String(g["name"])  : ""
        terms   := g.Has("terms") ? String(g["terms"]) : ""
        color   := g.Has("color") ? String(g["color"]) : "#3aa0ff"
        enabled := g.Has("enabled") ? (g["enabled"] ? true : false) : true
        if (name = "" && terms = "")
            continue
        g_entityGroups.Push(Map("name", name, "terms", terms, "color", color, "enabled", enabled))
    }
}

; Builds the "groups" JSON array for the header push so the Groups tab mirrors the saved list.
BuildGroupsHeaderJson()
{
    global g_entityGroups
    json := "["
    first := true
    for _, g in g_entityGroups
    {
        if !first
            json .= ","
        first := false
        json .= "{"
            . '"name":' _JsStr(g["name"]) ","
            . '"terms":' _JsStr(g["terms"]) ","
            . '"color":' _JsStr(g["color"]) ","
            . '"enabled":' (g["enabled"] ? "true" : "false")
            . "}"
    }
    return json "]"
}

; Persists the group list to the INI ([Groups] "list") as one line using control-char
; delimiters (field = US 0x1F, record = RS 0x1E) so user text with commas/pipes survives.
SaveEntityGroups()
{
    global g_entityGroups
    FS := Chr(31), RS := Chr(30)
    s := ""
    for i, g in g_entityGroups
    {
        if (i > 1)
            s .= RS
        s .= g["name"] FS g["terms"] FS g["color"] FS (g["enabled"] ? "1" : "0")
    }
    IniWrite((s = "" ? " " : s), A_ScriptDir "\gamehelper_config.ini", "Groups", "list")
}

; Loads the group list from the INI back into g_entityGroups (inverse of SaveEntityGroups).
LoadEntityGroups()
{
    global g_entityGroups
    g_entityGroups := []
    FS := Chr(31), RS := Chr(30)
    raw := IniRead(A_ScriptDir "\gamehelper_config.ini", "Groups", "list", "")
    if (raw = "" || raw = " ")
        return

    for _, rec in StrSplit(raw, RS)
    {
        if (rec = "")
            continue
        parts := StrSplit(rec, FS)
        name    := parts.Has(1) ? parts[1] : ""
        terms   := parts.Has(2) ? parts[2] : ""
        color   := parts.Has(3) ? parts[3] : "#3aa0ff"
        enabled := parts.Has(4) ? (parts[4] = "1") : true
        if (name = "" && terms = "")
            continue
        g_entityGroups.Push(Map("name", name, "terms", terms, "color", color, "enabled", enabled))
    }
}
