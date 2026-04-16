; TreeView_EntityScanner.ahk
; Entity scanner, NPC watch, offset table, monster analysis helpers
; Included by TreeViewWatchlistPanel.ahk

; TreeViewWatchlistPanel.ahk
; Watchlist-Panel, TreeView-Rendering und Panel-Steuerungsfunktionen

; Populates the offset table ListView with current values for all pinned watch paths.
; Also syncs NPC watch entries and applies column sorting and filter.
UpdateOffsetTable(snapshot)
{
    global offsetTable, pinnedNodePaths, offsetSearchEdit, offsetTableRowPathByRow, offsetPreviousValueByPath, npcWatchRadius
    static columnsInitialized := false

    if !offsetTable
        return

    try
    {

    filter := ""
    try filter := StrLower(Trim(offsetSearchEdit.Value))

    offsetTable.Opt("-Redraw")
    offsetTable.Delete()
    offsetTableRowPathByRow := Map()

    npcWatch := BuildNpcWatchIndex(snapshot, npcWatchRadius)
    npcLookup := npcWatch["lookup"]

    SyncNpcWatchEntries(snapshot, npcLookup)

    stamp := FormatTime(A_Now, "HH:mm:ss")
    added := 0
    for _, watchKey in pinnedNodePaths
    {
        nodeName := BuildWatchNodeName(watchKey)
        pathText := BuildWatchParentPath(watchKey)
        valueText := ""

        if IsNpcWatchKey(watchKey)
        {
            valueText := npcLookup.Has(watchKey) ? npcLookup[watchKey] : "<left-range>"
        }
        else
        {
            value := ResolveNodePathValue(snapshot, watchKey)
            valueText := FormatPinnedValue(value)
        }

        delta := BuildOffsetDelta(watchKey, valueText)

        haystack := StrLower(nodeName " " valueText " " delta["text"] " " pathText)
        if (filter != "" && !InStr(haystack, filter))
            continue

        row := offsetTable.Add(, stamp, nodeName, valueText, delta["text"], pathText, delta["state"])
        offsetTableRowPathByRow[row] := watchKey
        added += 1
    }

    if !columnsInitialized
    {
        offsetTable.ModifyCol(1, 88)
        offsetTable.ModifyCol(2, 130)
        offsetTable.ModifyCol(3, 250)
        offsetTable.ModifyCol(4, 80)
        offsetTable.ModifyCol(5, 360)
        offsetTable.ModifyCol(6, 0)
        columnsInitialized := true
    }

    ApplyOffsetTableSort()
    offsetTable.Opt("+Redraw")
    }
    catch as ex
    {
        try offsetTable.Opt("+Redraw")
        LogError("UpdateOffsetTable", ex)
    }
}

; Computes the delta between the previous and current display value for a watch path.
; Returns: Map with "text" (delta label) and "state" (NEW/UP/DOWN/CHANGED/NONE).
BuildOffsetDelta(path, valueText)
{
    global offsetPreviousValueByPath

    if !offsetPreviousValueByPath.Has(path)
    {
        offsetPreviousValueByPath[path] := valueText
        return Map("text", "NEW", "state", "NEW")
    }

    prevText := offsetPreviousValueByPath[path]
    offsetPreviousValueByPath[path] := valueText

    if (prevText = valueText)
        return Map("text", "=", "state", "NONE")

    oldNum := 0.0
    newNum := 0.0
    if (TryParseScalarNumber(prevText, &oldNum) && TryParseScalarNumber(valueText, &newNum))
    {
        diff := newNum - oldNum
        if (diff > 0)
            return Map("text", "+" FormatNumberDelta(diff), "state", "UP")
        if (diff < 0)
            return Map("text", "-" FormatNumberDelta(Abs(diff)), "state", "DOWN")
    }

    return Map("text", "CHG", "state", "CHANGED")
}

; Returns true if the watch key identifies an NPC watch entry (prefixed with "@npc:").
IsNpcWatchKey(watchKey)
{
    return InStr(watchKey, "@npc:") = 1
}

; Extracts the display name for the watch table row from a watch key.
BuildWatchNodeName(watchKey)
{
    if IsNpcWatchKey(watchKey)
    {
        if RegExMatch(watchKey, "^@npc:(\d+)\|", &m)
            return "NPC #" m[1]
        return "NPC"
    }

    lastSlash := InStr(watchKey, "/", , -1)
    if (lastSlash <= 0)
        return watchKey
    return SubStr(watchKey, lastSlash + 1)
}

; Extracts the parent path portion of a watch key for display in the path column.
BuildWatchParentPath(watchKey)
{
    if IsNpcWatchKey(watchKey)
    {
        if RegExMatch(watchKey, "^@npc:\d+\|(.*)$", &m)
            return m[1]
        return ""
    }

    lastSlash := InStr(watchKey, "/", , -1)
    if (lastSlash <= 1)
        return ""
    return SubStr(watchKey, 1, lastSlash - 1)
}

; Builds the canonical @npc: watch key string from an entity ID and path.
BuildNpcWatchKey(entityId, entityPath)
{
    return "@npc:" entityId "|" entityPath
}

; Builds a short display label for an NPC scanner item (id, distance, short path).
BuildNpcWatchDisplay(item)
{
    id := item.Has("id") ? item["id"] : 0
    distText := item.Has("distanceText") ? item["distanceText"] : "d=-"
    pathShort := item.Has("pathShort") ? item["pathShort"] : "-"
    return "NPC #" id " | " distText " | " pathShort
}

; Builds the full value text for an NPC watch entry (name, level, tags, details, world position).
BuildNpcWatchValue(item)
{
    path := item.Has("path") ? item["path"] : ""
    npcName := "-"
    npcLevel := ""
    ExtractNpcNameAndLevel(path, &npcName, &npcLevel)

    ; Prefer real game display names from MonsterVarieties mapping when available.
    npcName := ResolveMonsterDisplayName(path, npcName)

    nameText := npcName
    if (npcLevel != "")
        nameText .= " (" npcLevel ")"

    tags := item.Has("tags") ? item["tags"] : "NPC"
    details := item.Has("details") ? item["details"] : "-"
    render := item.Has("renderText") ? item["renderText"] : "-"
    if (render = "")
        render := "-"

    return nameText " | " tags " | " details " | pos=" render
}

; Extracts a human-readable name and optional level suffix from a monster/NPC entity path.
; Params: outName - receives the extracted name; outLevel - receives the level string or "".
ExtractNpcNameAndLevel(entityPath, &outName, &outLevel)
{
    outName := "-"
    outLevel := ""

    short := ShortEntityPath(entityPath)
    if (short = "" || short = "(no-path)")
        return

    if RegExMatch(short, "^(.*?)(?:_?@(\d+))?$", &m)
    {
        candidateName := Trim(RegExReplace(m[1], "_+$", ""))
        if (candidateName != "")
            outName := candidateName
        if (m[2] != "")
            outLevel := m[2]
        return
    }

    outName := short
}

; Builds an index of nearby named NPCs within maxDistance grid units of the player.
; Returns: Map with "lookup" (key→value text), "display" (key→short label), and "keys" (ordered list).
BuildNpcWatchIndex(snapshot, maxDistance := 1200)
{
    inGame := (snapshot && snapshot.Has("inGameState")) ? snapshot["inGameState"] : 0
    areaInst := (inGame && inGame.Has("areaInstance")) ? inGame["areaInstance"] : 0
    awake := (areaInst && areaInst.Has("awakeEntities")) ? areaInst["awakeEntities"] : 0
    sleeping := (areaInst && areaInst.Has("sleepingEntities")) ? areaInst["sleepingEntities"] : 0
    playerPos := ExtractPlayerWorldPosition(areaInst)

    scannerItems := []
    awakeSample := (awake && awake.Has("sample")) ? awake["sample"] : 0
    if (awakeSample && Type(awakeSample) = "Array")
        CollectEntityScannerItems(scannerItems, awakeSample, "Awake", playerPos)

    sleepingSample := (sleeping && sleeping.Has("sample")) ? sleeping["sample"] : 0
    if (sleepingSample && Type(sleepingSample) = "Array")
        CollectEntityScannerItems(scannerItems, sleepingSample, "Sleeping", playerPos)

    lookup := Map()
    display := Map()
    keys := []

    for _, item in scannerItems
    {
        tags := item.Has("tags") ? item["tags"] : ""
        if !InStr(tags, "NPC")
            continue

        distance := item.Has("distance") ? item["distance"] : -1
        if (distance >= 0 && distance > maxDistance)
            continue

        key := BuildNpcWatchKey(item["id"], item["path"])
        lookup[key] := BuildNpcWatchValue(item)
        display[key] := BuildNpcWatchDisplay(item)
        keys.Push(key)
    }

    return Map("lookup", lookup, "display", display, "keys", keys)
}

; Attempts to parse a leading numeric value from a text string.
; Params: outNumber - receives the parsed float on success. Returns: true if successful.
TryParseScalarNumber(text, &outNumber)
{
    outNumber := 0.0
    if !RegExMatch(Trim(text), "^-?\d+(?:\.\d+)?", &m)
        return false

    outNumber := m[0] + 0
    return true
}

; Formats a numeric delta value as an integer if whole, or to 3 decimal places otherwise.
FormatNumberDelta(value)
{
    if (Abs(value - Round(value)) < 0.0005)
        return Round(value)

    return Format("{:.3f}", value)
}

; Handles a column header click to toggle sort direction for the offset table.
OnOffsetTableColClick(ctrl, colIndex)
{
    global offsetTableSortCol, offsetTableSortDesc

    if (colIndex < 1 || colIndex > 5)
        return

    if (offsetTableSortCol = colIndex)
        offsetTableSortDesc := !offsetTableSortDesc
    else
    {
        offsetTableSortCol := colIndex
        offsetTableSortDesc := false
    }

    ApplyOffsetTableSort()
}

; Applies the current sort column and direction to the offset table ListView.
ApplyOffsetTableSort()
{
    global offsetTable, offsetTableSortCol, offsetTableSortDesc

    if !offsetTable
        return

    opt := offsetTableSortDesc ? "SortDesc" : "Sort"
    offsetTable.ModifyCol(offsetTableSortCol, opt)
}

; WM_NOTIFY custom-draw handler for the offset table; colours rows by their delta state (UP/DOWN/CHANGED/NEW).
OnOffsetTableWmNotify(wParam, lParam, msg, hwnd)
{
    global offsetTable

    static NM_CUSTOMDRAW := -12
    static CDDS_PREPAINT := 0x00000001
    static CDDS_ITEMPREPAINT := 0x00010001
    static CDRF_DODEFAULT := 0x00000000
    static CDRF_NOTIFYITEMDRAW := 0x00000020

    try
    {
        if !offsetTable
            return
        if !lParam
            return

        hwndFrom := NumGet(lParam, 0, "UPtr")
        if (hwndFrom != offsetTable.Hwnd)
            return

        code := NumGet(lParam, A_PtrSize * 2, "Int")
        if (code != NM_CUSTOMDRAW)
            return

        dwDrawStage := NumGet(lParam, A_PtrSize * 3, "UInt")
        if (dwDrawStage = CDDS_PREPAINT)
            return CDRF_NOTIFYITEMDRAW

        if (dwDrawStage != CDDS_ITEMPREPAINT)
            return CDRF_DODEFAULT

        ; NMCUSTOMDRAW offsets (32/64-bit)
        itemSpecOffset := (A_PtrSize = 8) ? 56 : 36
        clrTextOffset := (A_PtrSize = 8) ? 72 : 48

        rowIndexZeroBased := NumGet(lParam, itemSpecOffset, "UPtr")
        row := rowIndexZeroBased + 1
        state := ""
        try state := offsetTable.GetText(row, 6)

        color := 0x00202020
        if (state = "UP")
            color := 0x0000A000
        else if (state = "DOWN")
            color := 0x000000CC
        else if (state = "CHANGED" || state = "NEW")
            color := 0x0000A0A0

        NumPut("UInt", color, lParam, clrTextOffset)
        return CDRF_DODEFAULT
    }
    catch as ex
    {
        LogError("OnOffsetTableWmNotify", ex)
        return CDRF_DODEFAULT
    }
}

; Builds the Pinned Watch section of the TreeView, listing each watched path with its current value.
AddPinnedWatchNode(parentId, snapshot, expandedPaths)
{
    global valueTree, nodePaths, pinnedNodePaths

    basePath := "snapshot/pinnedWatch"
    node := valueTree.Add("Pinned Watch: " pinnedNodePaths.Length, parentId)
    nodePaths[node] := basePath

    if (pinnedNodePaths.Length = 0)
    {
        valueTree.Add("Nutze 'PinSel', um den aktuell selektierten Tree-Knoten live zu verfolgen", node)
        if (expandedPaths.Has(basePath))
            valueTree.Modify(node, "Expand")
        return
    }

    npcWatch := BuildNpcWatchIndex(snapshot, 1200)
    npcLookup := npcWatch["lookup"]
    npcDisplay := npcWatch["display"]

    idx := 0
    for _, path in pinnedNodePaths
    {
        idx += 1
        if IsNpcWatchKey(path)
        {
            label := npcDisplay.Has(path) ? npcDisplay[path] : path
            valueText := npcLookup.Has(path) ? npcLookup[path] : "<left-range>"
            line := idx ". " label " = " valueText
        }
        else
        {
            value := ResolveNodePathValue(snapshot, path)
            line := idx ". " path " = " FormatPinnedValue(value)
        }

        childPath := basePath "/" idx
        childId := valueTree.Add(line, node)
        nodePaths[childId] := childPath
    }

    if (expandedPaths.Has(basePath) || pinnedNodePaths.Length <= 6)
        valueTree.Modify(node, "Expand")
}

; Resolves a slash-delimited node path against the snapshot Map and returns the value at that location.
; Returns: the resolved value, or "<missing>" / "<invalid-path>" if the path cannot be followed.
ResolveNodePathValue(snapshot, nodePath)
{
    if !(snapshot && nodePath != "")
        return "<n/a>"

    parts := StrSplit(nodePath, "/")
    if (parts.Length = 0 || parts[1] != "snapshot")
        return "<invalid-path>"

    cur := snapshot
    i := 2
    while (i <= parts.Length)
    {
        token := parts[i]
        if RegExMatch(token, "^\[(\d+)\]$", &m)
        {
            idx := Integer(m[1])
            if !(IsObject(cur) && Type(cur) = "Array" && idx >= 1 && idx <= cur.Length)
                return "<missing>"
            cur := cur[idx]
        }
        else
        {
            if !(IsObject(cur) && Type(cur) = "Map" && cur.Has(token))
                return "<missing>"
            cur := cur[token]
        }
        i += 1
    }

    return cur
}

; Formats a pinned watch value for display as a string (handles scalars, Maps, Arrays, and Buffers).
FormatPinnedValue(value)
{
    if !IsObject(value)
        return FormatScalar(value)

    typeName := Type(value)
    if (typeName = "Map")
        return "{Map, count=" value.Count "}"
    if (typeName = "Array")
        return "[Array, len=" value.Length "]"
    if (typeName = "Buffer")
        return "<Buffer size=" value.Size ">"

    return "<" typeName ">"
}

; Builds the Entity Highlights tab tree node from awake and sleeping entity samples, sorted by distance.
AddDecodedEntityHighlightsNode(parentId, snapshot, expandedPaths)
{
    global valueTree, nodePaths

    inGame := (snapshot && snapshot.Has("inGameState")) ? snapshot["inGameState"] : 0
    areaInst := (inGame && inGame.Has("areaInstance")) ? inGame["areaInstance"] : 0
    awake := (areaInst && areaInst.Has("awakeEntities")) ? areaInst["awakeEntities"] : 0
    sleeping := (areaInst && areaInst.Has("sleepingEntities")) ? areaInst["sleepingEntities"] : 0
    playerPos := ExtractPlayerWorldPosition(areaInst)

    items := []

    awakeSample := (awake && awake.Has("sample")) ? awake["sample"] : 0
    if (awakeSample && Type(awakeSample) = "Array")
        CollectDecodedEntityHighlights(items, awakeSample, "Awake", playerPos)

    sleepingSample := (sleeping && sleeping.Has("sample")) ? sleeping["sample"] : 0
    if (sleepingSample && Type(sleepingSample) = "Array")
        CollectDecodedEntityHighlights(items, sleepingSample, "Sleeping", playerPos)

    SortEntityHighlightsByDistance(items)

    basePath := "snapshot/entityHighlights"
    highlightsNode := valueTree.Add("Entity Highlights (dist sorted): " items.Length, parentId)
    nodePaths[highlightsNode] := basePath

    awakeStats := CollectSampleStats(awakeSample)
    sleepStats := CollectSampleStats(sleepingSample)
    diagText := "Diag A[s=" awakeStats["samples"] ",e=" awakeStats["withEntity"] ",c=" awakeStats["withComponents"] ",d=" awakeStats["withDecoded"] "]"
        . " S[s=" sleepStats["samples"] ",e=" sleepStats["withEntity"] ",c=" sleepStats["withComponents"] ",d=" sleepStats["withDecoded"] "]"
    valueTree.Add(diagText, highlightsNode)

    probeText := BuildSampleProbeText(awakeSample, sleepingSample)
    if (probeText != "")
        valueTree.Add(probeText, highlightsNode)

    if (items.Length = 0)
    {
        valueTree.Add("Keine passenden Entities in den aktuellen Samples", highlightsNode)
    }
    else
    {
        idx := 0
        for _, info in items
        {
            idx += 1
            distText := info.Has("distanceText") ? info["distanceText"] : "d=-"
            label := idx ". [" info["source"] "] " distText " | id=" info["id"] " | " info["pathShort"] " | " info["componentLabel"]
            itemPath := basePath "/" idx
            itemNode := valueTree.Add(label, highlightsNode)
            nodePaths[itemNode] := itemPath

            valueTree.Add("entityPtr: " FormatScalar(info["entityPtr"], "entityPtr"), itemNode)
            valueTree.Add("path: " info["path"], itemNode)
            valueTree.Add("status: " info["statusText"], itemNode)
            if (info.Has("renderText") && info["renderText"] != "-")
                valueTree.Add("position: " info["renderText"], itemNode)

            if (expandedPaths.Has(itemPath))
                valueTree.Modify(itemNode, "Expand")
        }
    }

    if (expandedPaths.Has(basePath) || items.Length <= 8)
        valueTree.Modify(highlightsNode, "Expand")
}

; Builds the Entity Scanner tab tree node listing NPCs, rares, uniques, and blocked entities.
AddEntityScannerNode(parentId, snapshot, expandedPaths)
{
    global valueTree, nodePaths

    inGame := (snapshot && snapshot.Has("inGameState")) ? snapshot["inGameState"] : 0
    areaInst := (inGame && inGame.Has("areaInstance")) ? inGame["areaInstance"] : 0
    awake := (areaInst && areaInst.Has("awakeEntities")) ? areaInst["awakeEntities"] : 0
    sleeping := (areaInst && areaInst.Has("sleepingEntities")) ? areaInst["sleepingEntities"] : 0
    playerPos := ExtractPlayerWorldPosition(areaInst)

    scannerItems := []

    awakeSample := (awake && awake.Has("sample")) ? awake["sample"] : 0
    if (awakeSample && Type(awakeSample) = "Array")
        CollectEntityScannerItems(scannerItems, awakeSample, "Awake", playerPos)

    sleepingSample := (sleeping && sleeping.Has("sample")) ? sleeping["sample"] : 0
    if (sleepingSample && Type(sleepingSample) = "Array")
        CollectEntityScannerItems(scannerItems, sleepingSample, "Sleeping", playerPos)

    SortEntityHighlightsByDistance(scannerItems)

    basePath := "snapshot/entityScanner"
    node := valueTree.Add("Entity Scanner (NPC/Rare+Unique/Blocked): " scannerItems.Length, parentId)
    nodePaths[node] := basePath

    awakeStats := CollectSampleStats(awakeSample)
    sleepStats := CollectSampleStats(sleepingSample)
    diagText := "Diag A[s=" awakeStats["samples"] ",e=" awakeStats["withEntity"] ",c=" awakeStats["withComponents"] ",d=" awakeStats["withDecoded"] "]"
        . " S[s=" sleepStats["samples"] ",e=" sleepStats["withEntity"] ",c=" sleepStats["withComponents"] ",d=" sleepStats["withDecoded"] "]"
    valueTree.Add(diagText, node)

    probeText := BuildSampleProbeText(awakeSample, sleepingSample)
    if (probeText != "")
        valueTree.Add(probeText, node)

    nearbyInfo := BuildNearbyMonsterInfo(awakeSample, playerPos)
    nearbySummary := BuildNearbyMonsterInfoSummaryText(nearbyInfo)
    valueTree.Add(nearbySummary, node)

    if (scannerItems.Length = 0)
    {
        valueTree.Add("Keine Scanner-Treffer in den aktuellen Samples", node)
    }
    else
    {
        idx := 0
        for _, info in scannerItems
        {
            idx += 1
            label := idx ". [" info["source"] "] " info["distanceText"] " | id=" info["id"] " | " info["pathShort"] " | " info["tags"]
            itemPath := basePath "/" idx
            itemNode := valueTree.Add(label, node)
            nodePaths[itemNode] := itemPath

            valueTree.Add("entityPtr: " FormatScalar(info["entityPtr"], "entityPtr"), itemNode)
            valueTree.Add("path: " info["path"], itemNode)
            valueTree.Add("details: " info["details"], itemNode)
            if (info.Has("renderText") && info["renderText"] != "-")
                valueTree.Add("position: " info["renderText"], itemNode)

            if (expandedPaths.Has(itemPath))
                valueTree.Modify(itemNode, "Expand")
        }
    }

    if (expandedPaths.Has(basePath) || scannerItems.Length <= 10)
        valueTree.Modify(node, "Expand")
}

; Collects entity scanner items from a sample array, filtering to entities that have notable tags.
; Params: outItems - Array to append results to; sourceLabel - "Awake" or "Sleeping".
CollectEntityScannerItems(outItems, sampleArray, sourceLabel, playerPos := 0)
{
    seen := Map()

    for _, sample in sampleArray
    {
        if !(sample && Type(sample) = "Map")
            continue
        if !sample.Has("entity")
            continue

        entity := sample["entity"]
        if !(entity && Type(entity) = "Map")
            continue

        id := entity.Has("entityId") ? entity["entityId"] : (sample.Has("id") ? sample["id"] : 0)
        entityPtr := entity.Has("address") ? entity["address"] : (sample.Has("entityPtr") ? sample["entityPtr"] : 0)
        path := entity.Has("path") ? entity["path"] : ""

        decoded := (entity.Has("decodedComponents") && entity["decodedComponents"] && Type(entity["decodedComponents"]) = "Map")
            ? entity["decodedComponents"]
            : Map()
        componentNames := ExtractEntityComponentNameSet(entity)

        renderPos := ExtractRenderWorldPosition(decoded, playerPos)
        distance := ComputeDistance3D(playerPos, renderPos)
        distanceText := (distance >= 0) ? ("d=" Format("{:.1f}", distance)) : "d=-"

        tags := BuildEntityScannerTags(decoded, componentNames, path, distance)
        if (tags = "")
            continue

        dedupeKey := sourceLabel "|" entityPtr "|" id
        if seen.Has(dedupeKey)
            continue
        seen[dedupeKey] := true

        outItems.Push(Map(
            "source", sourceLabel,
            "id", id,
            "entityPtr", entityPtr,
            "path", path,
            "pathShort", ShortEntityPath(path),
            "tags", tags,
            "details", BuildEntityScannerDetails(decoded, componentNames),
            "renderText", BuildRenderPositionText(decoded, playerPos),
            "distance", distance,
            "distanceText", distanceText
        ))
    }
}

; Counts live non-friendly monsters within two radius zones (inner and outer) around the player.
; Returns: Map with per-rarity counts for both zones plus friendly entity counts.
BuildNearbyMonsterInfo(sampleArray, playerPos := 0, innerRadius := 600, outerRadius := 1200)
{
    smallCircleMonsterCount := [0, 0, 0, 0] ; Normal, Magic, Rare, Unique
    largeCircleMonsterCount := [0, 0, 0, 0]
    friendlyCount := [0, 0] ; Inner, Outer

    if !(sampleArray && Type(sampleArray) = "Array")
    {
        return Map(
            "innerRadius", innerRadius,
            "outerRadius", outerRadius,
            "smallCircleMonsterCount", smallCircleMonsterCount,
            "largeCircleMonsterCount", largeCircleMonsterCount,
            "friendlyCount", friendlyCount
        )
    }

    for _, sample in sampleArray
    {
        if !(sample && Type(sample) = "Map" && sample.Has("entity"))
            continue

        entity := sample["entity"]
        if !(entity && Type(entity) = "Map")
            continue

        path := entity.Has("path") ? entity["path"] : ""
        if !IsMonsterEntityPath(path)
            continue

        decoded := (entity.Has("decodedComponents") && entity["decodedComponents"] && Type(entity["decodedComponents"]) = "Map")
            ? entity["decodedComponents"]
            : Map()

        if HasDecodedDeadLife(decoded)
            continue

        renderPos := ExtractRenderWorldPosition(decoded, playerPos)
        distance := ComputeDistance3D(playerPos, renderPos)
        if (distance < 0)
            continue

        inInner := (distance <= innerRadius)
        inOuter := (distance <= outerRadius)
        if (!inInner && !inOuter)
            continue

        if IsFriendlyMonsterDecoded(decoded)
        {
            if inInner
                friendlyCount[1] += 1
            if inOuter
                friendlyCount[2] += 1
            continue
        }

        rarityIdx := GetMonsterRarityIndexFromDecoded(decoded)
        if (rarityIdx < 1 || rarityIdx > 4)
            rarityIdx := 1

        if inInner
            smallCircleMonsterCount[rarityIdx] += 1
        if inOuter
            largeCircleMonsterCount[rarityIdx] += 1
    }

    return Map(
        "innerRadius", innerRadius,
        "outerRadius", outerRadius,
        "smallCircleMonsterCount", smallCircleMonsterCount,
        "largeCircleMonsterCount", largeCircleMonsterCount,
        "friendlyCount", friendlyCount
    )
}

; Returns true if the entity path is under the monsters or characters metadata folder.
IsMonsterEntityPath(entityPath)
{
    p := StrLower(entityPath)
    if (p = "")
        return false

    return InStr(p, "metadata/monsters/") || InStr(p, "metadata/characters/")
}

; Returns true if the decoded positioned component marks the entity as friendly.
IsFriendlyMonsterDecoded(decoded)
{
    if !(decoded && Type(decoded) = "Map")
        return false
    if !decoded.Has("positioned")
        return false

    positioned := decoded["positioned"]
    return (positioned && Type(positioned) = "Map" && positioned.Has("isFriendly") && positioned["isFriendly"])
}

; Returns the rarity index (1=Normal, 2=Magic, 3=Rare, 4=Unique) from decoded components.
GetMonsterRarityIndexFromDecoded(decoded)
{
    rarityText := GetDecodedEntityRarityText(decoded)
    switch rarityText
    {
        case "Magic":
            return 2
        case "Rare":
            return 3
        case "Unique":
            return 4
        default:
            return 1
    }
}

; Returns the monster count matching a rarity bitmask (1=Normal,2=Magic,4=Rare,8=Unique) in the given zone (1=inner, 2=outer).
GetNearbyMonsterCount(nearbyInfo, rarityMask, zone)
{
    ; rarityMask flags: 1=Normal, 2=Magic, 4=Rare, 8=Unique
    ; zone: 1=InnerCircle, 2=OuterCircle
    if !(nearbyInfo && Type(nearbyInfo) = "Map")
        return 0

    counterArray := (zone = 1)
        ? nearbyInfo["smallCircleMonsterCount"]
        : nearbyInfo["largeCircleMonsterCount"]

    sum := 0
    if (rarityMask & 1)
        sum += counterArray[1]
    if (rarityMask & 2)
        sum += counterArray[2]
    if (rarityMask & 4)
        sum += counterArray[3]
    if (rarityMask & 8)
        sum += counterArray[4]
    return sum
}

; Builds a human-readable summary string from a BuildNearbyMonsterInfo result Map.
BuildNearbyMonsterInfoSummaryText(nearbyInfo)
{
    if !(nearbyInfo && Type(nearbyInfo) = "Map")
        return "NearbyMonsterInfo: n/a"

    inner := nearbyInfo["smallCircleMonsterCount"]
    outer := nearbyInfo["largeCircleMonsterCount"]
    friendly := nearbyInfo["friendlyCount"]
    innerR := nearbyInfo["innerRadius"]
    outerR := nearbyInfo["outerRadius"]

    innerTotal := GetNearbyMonsterCount(nearbyInfo, 1 | 2 | 4 | 8, 1)
    outerTotal := GetNearbyMonsterCount(nearbyInfo, 1 | 2 | 4 | 8, 2)

    return "NearbyMonsterInfo I<=" innerR " O<=" outerR
        . " | Friendly(I/O)=" friendly[1] "/" friendly[2]
        . " | Inner(N/M/R/U)=" inner[1] "/" inner[2] "/" inner[3] "/" inner[4]
        . " | Outer(N/M/R/U)=" outer[1] "/" outer[2] "/" outer[3] "/" outer[4]
        . " | Total(I/O)=" innerTotal "/" outerTotal
}

; Builds a comma-separated tag string for an entity (Hostile, NPC, Rare, Unique, Blocked).
; Returns "" if the entity is dead or has no notable tags.
BuildEntityScannerTags(decoded, componentNames := 0, entityPath := "", distance := -1)
{
    tags := []
    if HasDecodedDeadLife(decoded)
        return ""

    isCombat := IsLikelyCombatEntity(decoded, componentNames, entityPath)
    isNpcLike := HasComponentName(componentNames, "npc") || IsNpcLikePath(entityPath)
    hasActiveTargetable := HasDecodedActiveTargetable(decoded)
    hasAliveLife := HasDecodedAliveLife(decoded)
    isNearKnown := (distance >= 0 && distance <= 1200)

    if (isCombat)
        tags.Push("Hostile")

    if (isNpcLike && (isCombat || hasActiveTargetable || hasAliveLife || isNearKnown))
        tags.Push("NPC")

    rarityText := GetDecodedEntityRarityText(decoded)
    if (rarityText = "Rare" || rarityText = "Unique")
        tags.Push(rarityText)

    if decoded.Has("triggerableblockage")
    {
        tb := decoded["triggerableblockage"]
        if (tb && tb.Has("isBlocked") && tb["isBlocked"])
            tags.Push("Blocked")
    }

    out := ""
    for _, tag in tags
        out .= (out = "" ? "" : ",") tag
    return out
}

; Returns true if the decoded life component is present and reports isAlive = false.
HasDecodedDeadLife(decoded)
{
    if !(decoded && Type(decoded) = "Map" && decoded.Has("life"))
        return false

    life := decoded["life"]
    if !(life && Type(life) = "Map")
        return false
    if !life.Has("isAlive")
        return false

    return !life["isAlive"]
}

; Returns true if the decoded targetable component is present and active (targetable or highlightable).
HasDecodedActiveTargetable(decoded)
{
    if !(decoded && Type(decoded) = "Map" && decoded.Has("targetable"))
        return false

    t := decoded["targetable"]
    if !(t && Type(t) = "Map")
        return false

    return (t.Has("isTargetable") && t["isTargetable"])
        || (t.Has("isHighlightable") && t["isHighlightable"])
}

; Returns true if the decoded life component is present and reports isAlive = true.
HasDecodedAliveLife(decoded)
{
    if !(decoded && Type(decoded) = "Map" && decoded.Has("life"))
        return false

    life := decoded["life"]
    if !(life && Type(life) = "Map")
        return false

    return life.Has("isAlive") && life["isAlive"]
}

; Returns true if the entity is likely a hostile combat target based on decoded components and entity path.
IsLikelyCombatEntity(decoded, componentNames := 0, entityPath := "")
{
    if !(decoded && Type(decoded) = "Map")
        return false

    if IsChestLikePath(entityPath) || IsShrineLikePath(entityPath)
        return false

    if decoded.Has("positioned")
    {
        positioned := decoded["positioned"]
        if (positioned && Type(positioned) = "Map" && positioned.Has("isFriendly") && positioned["isFriendly"])
            return false
    }

    hasAliveLife := false
    if decoded.Has("life")
    {
        life := decoded["life"]
        if (life && Type(life) = "Map" && life.Has("isAlive") && life["isAlive"])
            hasAliveLife := true
    }

    hasActiveTargetable := false
    if decoded.Has("targetable")
    {
        t := decoded["targetable"]
        if (t && Type(t) = "Map")
            hasActiveTargetable := (t.Has("isTargetable") && t["isTargetable"])
                || (t.Has("isHighlightable") && t["isHighlightable"])
    }

    if (hasActiveTargetable && hasAliveLife)
        return true

    p := StrLower(entityPath)
    pathHostileHint := InStr(p, "metadata/monsters/") || InStr(p, "metadata/characters/")
    if (pathHostileHint && (hasActiveTargetable || hasAliveLife))
        return true

    if HasComponentName(componentNames, "npc") && hasActiveTargetable
        return true

    return false
}

; Returns the rarity string ("Normal", "Magic", "Rare", "Unique", or "") from decoded components.
GetDecodedEntityRarityText(decoded)
{
    rarityId := -1
    if decoded.Has("objectmagicproperties")
    {
        omp := decoded["objectmagicproperties"]
        if (omp && omp.Has("rarityId"))
            rarityId := omp["rarityId"]
    }
    if (rarityId < 0 && decoded.Has("mods"))
    {
        mods := decoded["mods"]
        if (mods && mods.Has("rarityId"))
            rarityId := mods["rarityId"]
    }

    switch rarityId
    {
        case 0:
            return "Normal"
        case 1:
            return "Magic"
        case 2:
            return "Rare"
        case 3:
            return "Unique"
        default:
            return ""
    }
}

; Builds a detail string for an entity scanner item (rarity, mod count, blockage state, top stats).
BuildEntityScannerDetails(decoded, componentNames := 0)
{
    parts := []

    rarityText := GetDecodedEntityRarityText(decoded)
    if (rarityText != "")
        parts.Push("rarity=" rarityText)

    if decoded.Has("mods")
    {
        m := decoded["mods"]
        if (m && m.Has("totalMods"))
            parts.Push("mods=" m["totalMods"])
    }
    else if decoded.Has("objectmagicproperties")
    {
        o := decoded["objectmagicproperties"]
        if (o && o.Has("totalMods"))
            parts.Push("mods=" o["totalMods"])
    }

    if decoded.Has("triggerableblockage")
    {
        tb := decoded["triggerableblockage"]
        if (tb && tb.Has("isBlocked"))
            parts.Push("blocked=" (tb["isBlocked"] ? "1" : "0"))
    }

    statsSummary := BuildEntityScannerStatsSummary(decoded, 4)
    if (statsSummary != "")
        parts.Push("stats=" statsSummary)

    if (parts.Length = 0)
    {
        if HasComponentName(componentNames, "npc")
            parts.Push("hasNpcComp=1")
        if HasComponentName(componentNames, "triggerableblockage")
            parts.Push("hasBlockageComp=1")
    }

    out := ""
    for _, part in parts
        out .= (out = "" ? "" : " | ") part
    return out = "" ? "-" : out
}

; Builds a semicolon-separated summary of the top-N stats by absolute value from a decoded entity.
BuildEntityScannerStatsSummary(decoded, maxEntries := 4)
{
    if !(decoded && Type(decoded) = "Map")
        return ""

    stats := []

    if decoded.Has("stats")
    {
        st := decoded["stats"]
        if (st && Type(st) = "Map")
        {
            if (st.Has("statsByItemsSample") && st["statsByItemsSample"] && Type(st["statsByItemsSample"]) = "Array")
                CollectStatPreviewEntries(stats, st["statsByItemsSample"], "items", 8)
            if (st.Has("statsByBuffAndActionsSample") && st["statsByBuffAndActionsSample"] && Type(st["statsByBuffAndActionsSample"]) = "Array")
                CollectStatPreviewEntries(stats, st["statsByBuffAndActionsSample"], "buffs", 8)
        }
    }

    if decoded.Has("mods")
    {
        mods := decoded["mods"]
        if (mods && Type(mods) = "Map" && mods.Has("statsFromMods") && mods["statsFromMods"] && Type(mods["statsFromMods"]) = "Array")
            CollectStatPreviewEntries(stats, mods["statsFromMods"], "mods", 8)
    }
    else if decoded.Has("objectmagicproperties")
    {
        omp := decoded["objectmagicproperties"]
        if (omp && Type(omp) = "Map" && omp.Has("statsFromMods") && omp["statsFromMods"] && Type(omp["statsFromMods"]) = "Array")
            CollectStatPreviewEntries(stats, omp["statsFromMods"], "mods", 8)
    }

    if (stats.Length = 0)
        return ""

    SortStatPreviewEntries(stats)

    out := ""
    maxKeep := Min(maxEntries, stats.Length)
    idx := 1
    while (idx <= maxKeep)
    {
        entry := stats[idx]
        label := ResolveStatDisplayName(entry["key"])
        src := entry["source"]
        part := src ":" label "=" entry["value"]
        out .= (out = "" ? "" : "; ") part
        idx += 1
    }

    return out
}

; Collects numeric stat pairs from a stats array into outEntries for preview display.
; Params: source - label string ("items", "buffs", "mods"); maxRead - max pairs to read.
CollectStatPreviewEntries(outEntries, pairs, source, maxRead := 8)
{
    if !(pairs && Type(pairs) = "Array")
        return

    idx := 1
    while (idx <= pairs.Length && idx <= maxRead)
    {
        pair := pairs[idx]
        idx += 1
        if !(pair && Type(pair) = "Map")
            continue
        if !pair.Has("key") || !pair.Has("value")
            continue

        key := pair["key"]
        val := pair["value"]
        if (Type(key) != "Integer" && Type(key) != "Float")
            continue
        if (Type(val) != "Integer" && Type(val) != "Float")
            continue
        if (val = 0)
            continue

        outEntries.Push(Map(
            "key", key,
            "value", val,
            "absValue", Abs(val),
            "source", source
        ))
    }
}

; Sorts stat preview entries in-place by absValue descending (selection sort).
SortStatPreviewEntries(entries)
{
    if !(entries && Type(entries) = "Array")
        return

    i := 1
    while (i <= entries.Length)
    {
        j := i + 1
        while (j <= entries.Length)
        {
            if (entries[j]["absValue"] > entries[i]["absValue"])
            {
                tmp := entries[i]
                entries[i] := entries[j]
                entries[j] := tmp
            }
            j += 1
        }
        i += 1
    }
}
