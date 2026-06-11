; EntityFocus.ahk
; Focused-entity readout for the test overlay (and groundwork for hardening
; auto-combat). Two signals:
;   * GetTargetedMonster - the awake monster with Targetable.IsTargetedByPlayer (0x6B)
;   * _FocusResolveHovered - the hovered WORLD OBJECT via PoE2Offsets.HoverTracker
;     (tracker+0x648). NOTE: that slot tracks chests/ground-items/shrines, NOT
;     monsters (monster targeting is IsTargetedByPlayer).
;
; The monster scan reads the ALREADY-DECODED radar snapshot (no second enumeration);
; only a single fresh Targetable byte is read per monster. The hover resolve is a
; short pointer chain. BuildFocusLines() is consumed by FocusOverlay (driven by OverlayManager).
; Included by InGameStateMonitor.ahk.

; Returns the Targetable component address cached on a snapshot entity, or 0.
; Uses the entity's components array — no component-lookup walk, no extra cost.
_FocusTargetableAddr(entity)
{
    if !(entity && entity.Has("components") && Type(entity["components"]) = "Array")
        return 0
    for _, comp in entity["components"]
    {
        if (comp && comp.Has("name") && comp.Has("address") && InStr(comp["name"], "Targetable"))
            return comp["address"]
    }
    return 0
}

; Finds the awake monster currently targeted by the player (IsTargetedByPlayer 0x6B).
; Prefers a fresh 1-byte read off the cached Targetable address; falls back to the
; decoded snapshot flag. Returns the snapshot entity Map (with decodedComponents)
; or 0. Params: reader (g_reader), snap (radar snapshot).
GetTargetedMonster(reader, snap)
{
    if !(IsObject(reader) && IsObject(snap) && snap.Has("inGameState"))
        return 0
    inGs := snap["inGameState"]
    area := (IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    awake := (IsObject(area) && area.Has("awakeEntities")) ? area["awakeEntities"] : 0
    sample := (IsObject(awake) && awake.Has("sample")) ? awake["sample"] : 0
    if !(IsObject(sample) && Type(sample) = "Array")
        return 0

    tgtOff := PoE2Offsets.Targetable["IsTargetedByPlayer"]
    scanned := 0
    for _, en in sample
    {
        if !(en && Type(en) = "Map" && en.Has("entity"))
            continue
        entity := en["entity"]
        if !(entity && Type(entity) = "Map")
            continue
        path := entity.Has("path") ? entity["path"] : ""
        if !InStr(StrLower(path), "/monsters/")
            continue
        scanned += 1
        if (scanned > 500)
            break

        isTgt := 0
        tAddr := _FocusTargetableAddr(entity)
        if (tAddr && reader.IsProbablyValidPointer(tAddr))
        {
            try isTgt := reader.Mem.ReadUChar(tAddr + tgtOff)
        }
        else
        {
            dc := entity.Has("decodedComponents") ? entity["decodedComponents"] : 0
            if (dc && dc.Has("targetable") && Type(dc["targetable"]) = "Map"
                && dc["targetable"].Has("isTargetedByPlayer") && dc["targetable"]["isTargetedByPlayer"])
                isTgt := 1
        }
        if (isTgt = 1)
            return entity
    }
    return 0
}

; Last path segment as a short display name. "Metadata/Monsters/Foo/Bar" -> "Bar".
_FocusLeaf(path)
{
    if (path = "")
        return "?"
    parts := StrSplit(path, "/")
    return parts.Length ? parts[parts.Length] : path
}

; Formats a life string "cur/max HP (pct%)" from decoded components, or "" if none.
_FocusLifeStr(dc)
{
    if !(dc && Type(dc) = "Map" && dc.Has("life") && Type(dc["life"]) = "Map")
        return ""
    lf := dc["life"]
    lStruct := (lf.Has("life") && Type(lf["life"]) = "Map") ? lf["life"] : 0
    if !lStruct
        return ""
    cur := lStruct.Has("current") ? lStruct["current"] : "?"
    max := lStruct.Has("max") ? lStruct["max"] : "?"
    s := cur "/" max " HP"
    if (IsInteger(cur) && IsInteger(max) && max > 0)
        s .= " (" Round(cur * 100 / max) "%)"
    return s
}

; Resolves the hovered WORLD OBJECT via the HoverTracker chain (tracker+0x648).
; Returns Map("ptr","path") or 0. Monsters are NOT tracked here.
_FocusResolveHovered(reader, snap)
{
    inGs := (IsObject(snap) && snap.Has("inGameState")) ? snap["inGameState"] : 0
    inGsAddr := (IsObject(inGs) && inGs.Has("address")) ? inGs["address"] : 0
    if !(inGsAddr && reader.IsProbablyValidPointer(inGsAddr))
        return 0
    uiRoot := reader.Mem.ReadPtr(inGsAddr + PoE2Offsets.InGameState["UiRootStructPtr"])
    if !reader.IsProbablyValidPointer(uiRoot)
        return 0
    tracker := reader.Mem.ReadPtr(uiRoot + PoE2Offsets.HoverTracker["FromUiRoot"])
    if !reader.IsProbablyValidPointer(tracker)
        return 0
    hov := reader.Mem.ReadPtr(tracker + PoE2Offsets.HoverTracker["HoveredEntityFromTracker"])
    if !(hov && reader.IsPlausibleEntityPointer(hov))
        return 0
    path := ""
    try {
        e := reader.ReadEntityBasic(hov)
        if (IsObject(e) && e.Has("path"))
            path := e["path"]
    }
    return path != "" ? Map("ptr", hov, "path", path) : 0
}

; Resolves the entity currently UNDER THE CURSOR via the game-state MouseOver chain
; (verified against the trusted Cheat-Engine screenToWorldPtrMouseOverEntityPtr table):
;   [[[ inGameState + 0x300 ] + 0x3F0 ] + 0xA8 ]  -> Entity*  (0 = nothing hovered)
; Unlike _FocusResolveHovered (tracker+0x648, world objects only), this DOES resolve
; hovered monsters. The hovered entity is decoded FRESH off its own pointer (never the
; cached snapshot — that produced stale life and recycled-pointer rarity mismatches).
; Returns Map("ptr","path","id","decodedComponents") or 0. Params: reader, snap.
_FocusResolveMouseOverEntity(reader, snap)
{
    inGs := (IsObject(snap) && snap.Has("inGameState")) ? snap["inGameState"] : 0
    inGsAddr := (IsObject(inGs) && inGs.Has("address")) ? inGs["address"] : 0
    if !(inGsAddr && reader.IsProbablyValidPointer(inGsAddr))
        return 0
    host := reader.Mem.ReadPtr(inGsAddr + PoE2Offsets.MouseOver["HostFromInGameState"])
    if !reader.IsProbablyValidPointer(host)
        return 0
    sub := reader.Mem.ReadPtr(host + PoE2Offsets.MouseOver["SubFromHost"])
    if !reader.IsProbablyValidPointer(sub)
        return 0
    ent := reader.Mem.ReadPtr(sub + PoE2Offsets.MouseOver["EntityFromSub"])
    if !(ent && reader.IsPlausibleEntityPointer(ent))
        return 0
    ; Identity (path/id) + a FRESH component decode off the live pointer. Use the RADAR
    ; decoder explicitly rather than ReadEntityBasic — ReadEntityBasic's decode path
    ; depends on the transient _radarMode flag, and its non-radar branch misreads chest
    ; rarity as Normal. DecodeSampleEntityComponentsRadar reads ObjectMagicProperties/Mods
    ; rarity correctly (Magic) AND fresh life, matching exactly what the snapshot showed.
    ident := 0
    try ident := reader.ReadEntityIdentityBasic(ent)
    if !(IsObject(ident) && ident.Has("path") && ident["path"] != "")
        return 0
    dc := 0
    try {
        components := reader.ReadEntityComponentLookupBasic(ent, 64)
        dc := reader.DecodeSampleEntityComponentsRadar(components)
    }
    return Map("ptr", ent,
        "path", ident["path"],
        "id", ident.Has("entityId") ? ident["entityId"] : 0,
        "decodedComponents", (IsObject(dc) && Type(dc) = "Map") ? dc : 0)
}

; Builds the focus-overlay lines: the targeted monster (name/type/rarity/life), the
; entity under the cursor (MouseOver chain), and the hovered world object. Returns an
; array of strings.
BuildFocusLines(reader, snap)
{
    lines := []

    mon := GetTargetedMonster(reader, snap)
    if (mon && Type(mon) = "Map")
    {
        path := mon.Has("path") ? mon["path"] : ""
        dc := mon.Has("decodedComponents") ? mon["decodedComponents"] : 0
        type := ExtractMetaGroup(path)
        rarity := RarityIdToName(ReadEntityRarityId(dc))
        hp := _FocusLifeStr(dc)
        lines.Push("TARGET: " _FocusLeaf(path))
        lines.Push("  type: " (type != "" ? type : "?") "   rarity: " rarity)
        if (hp != "")
            lines.Push("  life: " hp)
    }
    else
        lines.Push("TARGET: (none)")

    mo := _FocusResolveMouseOverEntity(reader, snap)
    if (mo && Type(mo) = "Map" && mo.Has("path") && mo["path"] != "")
    {
        lines.Push("MOUSEOVER: " _FocusLeaf(mo["path"]))
        dc := (mo.Has("decodedComponents") && Type(mo["decodedComponents"]) = "Map") ? mo["decodedComponents"] : 0
        mg := ExtractMetaGroup(mo["path"])
        rarity := dc ? RarityIdToName(ReadEntityRarityId(dc)) : ""
        if (mg != "" || rarity != "")
            lines.Push("  type: " (mg != "" ? mg : "?") (rarity != "" ? "   rarity: " rarity : ""))
        moLife := dc ? _FocusLifeStr(dc) : ""
        if (moLife != "")
            lines.Push("  life: " moLife)
    }

    hov := _FocusResolveHovered(reader, snap)
    if (hov && Type(hov) = "Map" && hov.Has("path") && hov["path"] != "")
    {
        lines.Push("HOVER: " _FocusLeaf(hov["path"]))
        mg := ExtractMetaGroup(hov["path"])
        if (mg != "")
            lines.Push("  type: " mg)
    }

    return lines
}

; NOTE: the focus overlay is now driven by OverlayManager through the FocusOverlay
; class itself (it builds its lines from the snapshot in ShouldShow via
; BuildFocusLines). The old TickFocusOverlay() driver has been removed.

; Toggles the focused-entity test overlay on/off (bridge case ToggleFocusOverlay).
ToggleFocusOverlay()
{
    global g_focusOverlayEnabled, g_focusOverlay
    g_focusOverlayEnabled := !g_focusOverlayEnabled
    if (!g_focusOverlayEnabled && IsObject(g_focusOverlay))
        g_focusOverlay.Hide()
    try ToolTip("Focus overlay: " (g_focusOverlayEnabled ? "ON" : "OFF"))
    SetTimer(() => ToolTip(), -1500)
}
