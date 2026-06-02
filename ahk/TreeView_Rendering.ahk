; TreeView_Rendering.ahk
; Tree node building and rendering (Add*Node, Build*, Collect*)
; Included by TreeViewWatchlistPanel.ahk

; Iterates over a sample array and appends entities with interesting components to outItems.
; Params: outItems - Array to append to; sourceLabel - "Awake" or "Sleeping".
CollectDecodedEntityHighlights(outItems, sampleArray, sourceLabel, playerPos := 0)
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

        if !HasInterestingDecodedComponent(decoded, componentNames, path)
            continue

        dedupeKey := sourceLabel "|" entityPtr "|" id
        if seen.Has(dedupeKey)
            continue
        seen[dedupeKey] := true

        renderPos := ExtractRenderWorldPosition(decoded, playerPos)
        distance := ComputeDistance3D(playerPos, renderPos)
        distanceText := (distance >= 0) ? ("d=" Format("{:.1f}", distance)) : "d=-"

        outItems.Push(Map(
            "source", sourceLabel,
            "id", id,
            "entityPtr", entityPtr,
            "path", path,
            "pathShort", ShortEntityPath(path),
            "componentLabel", BuildInterestingComponentLabel(decoded, componentNames, path),
            "statusText", BuildInterestingStatusText(decoded, playerPos),
            "renderText", BuildRenderPositionText(decoded, playerPos),
            "distance", distance,
            "distanceText", distanceText
        ))
    }
}

; Sorts an entity item array in-place by distance ascending; entities with unknown distance go last.
SortEntityHighlightsByDistance(items)
{
    ; Insertion sort (small arrays): known distances first (ascending), unknown distances last.
    i := 2
    while (i <= items.Length)
    {
        current := items[i]
        currentDist := current.Has("distance") ? current["distance"] : -1
        j := i - 1

        while (j >= 1)
        {
            prev := items[j]
            prevDist := prev.Has("distance") ? prev["distance"] : -1

            prevUnknown := (prevDist < 0)
            currUnknown := (currentDist < 0)

            movePrev := false
            if (prevUnknown && !currUnknown)
                movePrev := true
            else if (!prevUnknown && !currUnknown && prevDist > currentDist)
                movePrev := true

            if !movePrev
                break

            items[j + 1] := items[j]
            j -= 1
        }

        items[j + 1] := current
        i += 1
    }
}

; Returns true if the entity has a decoded chest, shrine, or active targetable component.
HasInterestingDecodedComponent(decoded, componentNames := 0, entityPath := "")
{
    chestLikePath := IsChestLikePath(entityPath)
    shrineLikePath := IsShrineLikePath(entityPath)

    hasChest := (decoded.Has("chest") && chestLikePath)
        || (HasComponentName(componentNames, "chest") && chestLikePath)
    hasShrine := (decoded.Has("shrine") && shrineLikePath)
        || (HasComponentName(componentNames, "shrine") && shrineLikePath)

    hasActiveTargetable := false
    if decoded.Has("targetable")
    {
        targetable := decoded["targetable"]
        if (targetable && Type(targetable) = "Map")
            hasActiveTargetable := (targetable.Has("isTargetable") && targetable["isTargetable"])
                || (targetable.Has("isHighlightable") && targetable["isHighlightable"])
    }

    return hasChest || hasShrine || hasActiveTargetable || HasComponentName(componentNames, "targetable")
}

; Builds a comma-separated label of interesting component types present on the entity (Chest, Shrine, Targetable).
BuildInterestingComponentLabel(decoded, componentNames := 0, entityPath := "")
{
    names := []
    chestLikePath := IsChestLikePath(entityPath)
    shrineLikePath := IsShrineLikePath(entityPath)

    hasActiveTargetable := false
    if decoded.Has("targetable")
    {
        targetable := decoded["targetable"]
        if (targetable && Type(targetable) = "Map")
            hasActiveTargetable := (targetable.Has("isTargetable") && targetable["isTargetable"])
                || (targetable.Has("isHighlightable") && targetable["isHighlightable"])
    }

    if ((decoded.Has("chest") || HasComponentName(componentNames, "chest")) && chestLikePath)
        names.Push("Chest")
    if ((decoded.Has("shrine") || HasComponentName(componentNames, "shrine")) && shrineLikePath)
        names.Push("Shrine")
    if (hasActiveTargetable || HasComponentName(componentNames, "targetable"))
        names.Push("Targetable")

    out := ""
    for _, name in names
        out .= (out = "" ? "" : ",") name
    return out = "" ? "-" : out
}

; Returns true if the entity path indicates a character, monster, or NPC metadata entry.
IsNpcLikePath(entityPath)
{
    if (entityPath = "")
        return false

    p := StrLower(entityPath)
    if InStr(p, "/player")
        return false
    if InStr(p, "/attachments/") || InStr(p, "/outfits/")
        return false

    return InStr(p, "metadata/characters/") || InStr(p, "metadata/monsters/") || InStr(p, "metadata/npc/")
}

; Returns true if the entity path corresponds to a chest or strongbox.
IsChestLikePath(entityPath)
{
    if (entityPath = "")
        return false

    p := StrLower(entityPath)
    return InStr(p, "/chests/") || InStr(p, "strongbox") || InStr(p, "metadata/chests/")
}

; Returns true if the entity path corresponds to a shrine.
IsShrineLikePath(entityPath)
{
    if (entityPath = "")
        return false

    p := StrLower(entityPath)
    return InStr(p, "/shrines/") || InStr(p, "metadata/shrines/")
}

; Extracts the set of lower-cased component names from an entity Map, keyed by both full and short name.
ExtractEntityComponentNameSet(entity)
{
    set := Map()
    if !(entity && Type(entity) = "Map")
        return set
    if !entity.Has("components")
        return set

    components := entity["components"]
    if !(components && Type(components) = "Array")
        return set

    for _, comp in components
    {
        if !(comp && Type(comp) = "Map" && comp.Has("name"))
            continue

        rawName := StrLower(comp["name"])
        if (rawName = "")
            continue

        set[rawName] := true

        norm := rawName
        if InStr(norm, "::")
        {
            parts := StrSplit(norm, "::")
            norm := parts[parts.Length]
        }
        if InStr(norm, ".")
        {
            parts := StrSplit(norm, ".")
            norm := parts[parts.Length]
        }

        if (norm != "")
            set[norm] := true
    }

    return set
}

; Returns true if the component name set contains an entry matching expected (exact or suffix match).
HasComponentName(componentNames, expected)
{
    if !(componentNames && Type(componentNames) = "Map")
        return false

    expected := StrLower(expected)
    if (expected = "")
        return false
    if componentNames.Has(expected)
        return true

    for compName, _ in componentNames
    {
        if (compName = expected)
            return true
        if (StrLen(compName) > StrLen(expected))
        {
            suffixStart := StrLen(compName) - StrLen(expected) + 1
            if (SubStr(compName, suffixStart) = expected)
            {
                sep := SubStr(compName, suffixStart - 1, 1)
                if (sep = "." || sep = ":" || sep = "_")
                    return true
            }
        }
    }

    return false
}

; Counts entities with components, decoded components, etc. in a sample array for diagnostic display.
; Returns: Map with keys samples, withEntity, withComponents, withDecoded.
CollectSampleStats(sampleArray)
{
    stats := Map(
        "samples", 0,
        "withEntity", 0,
        "withComponents", 0,
        "withDecoded", 0
    )

    if !(sampleArray && Type(sampleArray) = "Array")
        return stats

    stats["samples"] := sampleArray.Length

    for _, sample in sampleArray
    {
        if !(sample && Type(sample) = "Map" && sample.Has("entity"))
            continue

        entity := sample["entity"]
        if !(entity && Type(entity) = "Map")
            continue

        stats["withEntity"] += 1

        if (entity.Has("components") && entity["components"] && Type(entity["components"]) = "Array" && entity["components"].Length > 0)
            stats["withComponents"] += 1

        if (entity.Has("decodedComponents") && entity["decodedComponents"] && Type(entity["decodedComponents"]) = "Map" && entity["decodedComponents"].Count > 0)
            stats["withDecoded"] += 1
    }

    return stats
}

; Builds a one-line diagnostic probe string describing the first entity in each sample array.
BuildSampleProbeText(awakeSample, sleepingSample)
{
    awakeText := DescribeFirstEntitySample("A", awakeSample)
    sleepText := DescribeFirstEntitySample("S", sleepingSample)

    if (awakeText = "" && sleepText = "")
        return ""
    if (awakeText = "")
        awakeText := "A[-]"
    if (sleepText = "")
        sleepText := "S[-]"

    return "Probe " awakeText " " sleepText
}

; Describes the first valid entity sample in the array as a compact diagnostic string.
; Params: prefix - short label ("A" for awake, "S" for sleeping).
DescribeFirstEntitySample(prefix, sampleArray)
{
    if !(sampleArray && Type(sampleArray) = "Array")
        return ""

    for _, sample in sampleArray
    {
        if !(sample && Type(sample) = "Map")
            continue

        if !sample.Has("entity")
            continue

        entity := sample["entity"]
        if !(entity && Type(entity) = "Map")
            continue

        mapId := sample.Has("id") ? sample["id"] : 0
        nodeLayout := sample.Has("nodeLayout") ? sample["nodeLayout"] : "-"
        entityId := entity.Has("entityId") ? entity["entityId"] : 0
        path := entity.Has("path") ? entity["path"] : ""
        pathShort := (StrLen(path) > 36) ? (SubStr(path, 1, 33) "...") : path
        compCount := entity.Has("componentCount") ? entity["componentCount"] : -1
        namedCount := entity.Has("namedComponentCount") ? entity["namedComponentCount"] : 0
        decCount := entity.Has("decodedComponentCount") ? entity["decodedComponentCount"] : 0

        return prefix "[mid=" mapId ",eid=" entityId ",ly=" nodeLayout ",cc=" compCount ",nc=" namedCount ",dc=" decCount ",p=" pathShort "]"
    }

    return ""
}

; Builds a status text string describing chest/shrine open state, targetability, and world position.
BuildInterestingStatusText(decoded, playerPos := 0)
{
    parts := []

    if decoded.Has("chest")
    {
        chest := decoded["chest"]
        opened := (chest && chest.Has("isOpened") && chest["isOpened"]) ? "1" : "0"
        parts.Push("opened=" opened)
    }

    if decoded.Has("shrine")
    {
        shrine := decoded["shrine"]
        used := (shrine && shrine.Has("isUsed") && shrine["isUsed"]) ? "1" : "0"
        parts.Push("used=" used)
    }

    if decoded.Has("targetable")
    {
        targ := decoded["targetable"]
        targetable := (targ && targ.Has("isTargetable") && targ["isTargetable"]) ? "1" : "0"
        hidden := (targ && targ.Has("hiddenFromPlayer") && targ["hiddenFromPlayer"]) ? "1" : "0"
        parts.Push("targetable=" targetable)
        parts.Push("hidden=" hidden)
    }

    renderText := BuildRenderPositionText(decoded, playerPos)
    if (renderText != "-")
        parts.Push("pos=" renderText)

    out := ""
    for _, part in parts
        out .= (out = "" ? "" : " | ") part
    return out = "" ? "-" : out
}

; Formats the render world position from decoded components as "x=N, y=N, z=N", or "-" if unavailable.
BuildRenderPositionText(decoded, playerPos := 0)
{
    wp := ExtractRenderWorldPosition(decoded, playerPos)
    if !(wp && Type(wp) = "Map")
        return "-"

    x := wp["x"]
    y := wp["y"]
    z := wp["z"]
    if (Type(x) != "Float" && Type(x) != "Integer")
        return "-"
    if (Type(y) != "Float" && Type(y) != "Integer")
        return "-"
    if (Type(z) != "Float" && Type(z) != "Integer")
        return "-"

    text := "x=" Format("{:.1f}", x) ", y=" Format("{:.1f}", y) ", z=" Format("{:.1f}", z)
    if (wp.Has("terrainHeight") && (Type(wp["terrainHeight"]) = "Float" || Type(wp["terrainHeight"]) = "Integer"))
        text .= ", th=" Format("{:.1f}", wp["terrainHeight"])
    return text
}

; Extracts the world position Map from the render decoded component, or returns 0 if invalid or implausible.
ExtractRenderWorldPosition(decoded, playerPos := 0)
{
    if !decoded.Has("render")
        return 0

    render := decoded["render"]
    if !(render && Type(render) = "Map")
        return 0
    if !render.Has("worldPosition")
        return 0

    wp := render["worldPosition"]
    if !(wp && Type(wp) = "Map")
        return 0
    if (!wp.Has("x") || !wp.Has("y") || !wp.Has("z"))
        return 0

    out := Map(
        "x", wp["x"],
        "y", wp["y"],
        "z", wp["z"]
    )
    if (render.Has("terrainHeight"))
        out["terrainHeight"] := render["terrainHeight"]

    if !IsPlausibleWorldPositionForPlayer(playerPos, out)
        return 0

    return out
}

; Returns false if worldPos is near the origin while the player is far away, or if the delta exceeds sanity bounds.
IsPlausibleWorldPositionForPlayer(playerPos, worldPos)
{
    if !(worldPos && Type(worldPos) = "Map")
        return false
    if (!worldPos.Has("x") || !worldPos.Has("y") || !worldPos.Has("z"))
        return false

    x := worldPos["x"]
    y := worldPos["y"]
    z := worldPos["z"]
    if ((Type(x) != "Float" && Type(x) != "Integer")
        || (Type(y) != "Float" && Type(y) != "Integer")
        || (Type(z) != "Float" && Type(z) != "Integer"))
        return false

    if !(playerPos && Type(playerPos) = "Map")
        return true
    if (!playerPos.Has("x") || !playerPos.Has("y") || !playerPos.Has("z"))
        return true

    px := playerPos["x"]
    py := playerPos["y"]
    pz := playerPos["z"]
    if ((Type(px) != "Float" && Type(px) != "Integer")
        || (Type(py) != "Float" && Type(py) != "Integer")
        || (Type(pz) != "Float" && Type(pz) != "Integer"))
        return true

    playerFarFromOrigin := (Abs(px) > 512) || (Abs(py) > 512)
    entityNearOrigin := (Abs(x) < 64) && (Abs(y) < 64) && (Abs(z) < 512)
    if (playerFarFromOrigin && entityNearOrigin)
        return false

    dx := Abs(px - x)
    dy := Abs(py - y)
    dz := Abs(pz - z)
    if (dx > 25000 || dy > 25000 || dz > 10000)
        return false

    return true
}

; Extracts the player's world position from the area instance's playerRenderComponent.
; Returns: Map with x/y/z keys, or 0 if unavailable.
ExtractPlayerWorldPosition(areaInst)
{
    if !(areaInst && Type(areaInst) = "Map")
        return 0
    if !areaInst.Has("playerRenderComponent")
        return 0

    pr := areaInst["playerRenderComponent"]
    if !(pr && Type(pr) = "Map")
        return 0
    if !pr.Has("worldPosition")
        return 0

    wp := pr["worldPosition"]
    if !(wp && Type(wp) = "Map")
        return 0
    if (!wp.Has("x") || !wp.Has("y") || !wp.Has("z"))
        return 0

    return Map("x", wp["x"], "y", wp["y"], "z", wp["z"])
}

; Builds a formatted world and grid position text string for the player from the area instance.
BuildPlayerPositionText(areaInst)
{
    if !(areaInst && Type(areaInst) = "Map")
        return "-"
    if !areaInst.Has("playerRenderComponent")
        return "-"

    pr := areaInst["playerRenderComponent"]
    if !(pr && Type(pr) = "Map")
        return "-"
    if !pr.Has("worldPosition")
        return "-"

    wp := pr["worldPosition"]
    if !(wp && Type(wp) = "Map")
        return "-"
    if (!wp.Has("x") || !wp.Has("y") || !wp.Has("z"))
        return "-"

    worldText := "W(x=" Format("{:.1f}", wp["x"]) ", y=" Format("{:.1f}", wp["y"]) ", z=" Format("{:.1f}", wp["z"]) ")"

    gridText := ""
    if (pr.Has("gridPosition"))
    {
        gp := pr["gridPosition"]
        if (gp && Type(gp) = "Map" && gp.Has("x") && gp.Has("y"))
            gridText := " | G(x=" Format("{:.1f}", gp["x"]) ", y=" Format("{:.1f}", gp["y"]) ")"
    }

    return worldText gridText
}

; Computes the 3D Euclidean distance between two {x,y,z} position Maps.
; Returns: distance as float, or -1 if either position Map is invalid.
ComputeDistance3D(posA, posB)
{
    if !(posA && Type(posA) = "Map")
        return -1
    if !(posB && Type(posB) = "Map")
        return -1
    if (!posA.Has("x") || !posA.Has("y") || !posA.Has("z"))
        return -1
    if (!posB.Has("x") || !posB.Has("y") || !posB.Has("z"))
        return -1

    dx := posA["x"] - posB["x"]
    dy := posA["y"] - posB["y"]
    dz := posA["z"] - posB["z"]
    return Sqrt((dx * dx) + (dy * dy) + (dz * dz))
}

; Returns the last path segment of an entity path string, or "(no-path)" for an empty path.
ShortEntityPath(path)
{
    if (path = "")
        return "(no-path)"

    last := path
    if InStr(path, "/")
    {
        parts := StrSplit(path, "/")
        if (parts.Length)
            last := parts[parts.Length]
    }

    return last = "" ? path : last
}

; Builds the Important UI Elements tab tree node (chat activity, passive tree panel, map pointers).
AddImportantUiElementsNode(parentId, snapshot, expandedPaths)
{
    global g_valueTree, g_nodePaths

    inGame := (snapshot && snapshot.Has("inGameState")) ? snapshot["inGameState"] : 0
    uiElems := (inGame && inGame.Has("importantUiElements")) ? inGame["importantUiElements"] : 0

    basePath := "snapshot/inGameState/importantUiElements"
    rootNode := g_valueTree.Add("Important UI Elements", parentId)
    g_nodePaths[rootNode] := basePath

    if !uiElems
    {
        g_valueTree.Add("(keine Daten)", rootNode)
        g_valueTree.Modify(rootNode, "Expand")
        return
    }

    ; --- Chat ---
    chatPtr       := uiElems.Has("chatParentPtr")  ? uiElems["chatParentPtr"]  : 0
    chatAlpha     := uiElems.Has("chatAlpha")      ? uiElems["chatAlpha"]      : 0
    isChatActive  := uiElems.Has("isChatActive")   ? uiElems["isChatActive"]   : false
    chatPath      := basePath "/chat"
    chatLabel     := isChatActive ? "YES" : "no"
    chatNode      := g_valueTree.Add("Chat (active: " chatLabel ")", rootNode)
    g_nodePaths[chatNode] := chatPath
    g_valueTree.Add("ChatParentPtr: " PoE2GameStateReader.Hex(chatPtr), chatNode)
    g_valueTree.Add("BackgroundColor alpha: 0x" Format("{:02X}", chatAlpha) " (" chatAlpha "/255)  — threshold 0x8C", chatNode)
    g_valueTree.Add("IsChatActive: " (isChatActive ? "true" : "false"), chatNode)
    g_valueTree.Modify(chatNode, "Expand")

    ; --- Passive Skill Tree Panel ---
    passivePtr := uiElems.Has("passiveSkillTreePanel") ? uiElems["passiveSkillTreePanel"] : 0
    passiveNode := g_valueTree.Add("PassiveSkillTreePanel: " PoE2GameStateReader.Hex(passivePtr), rootNode)
    g_nodePaths[passiveNode] := basePath "/passiveSkillTreePanel"

    ; --- Map ---
    mapPath := basePath "/map"
    mapNode := g_valueTree.Add("Map", rootNode)
    g_nodePaths[mapNode] := mapPath

    mapParentPtr     := uiElems.Has("mapParentPtr") ? uiElems["mapParentPtr"] : 0
    ctrlMapParentPtr := uiElems.Has("controllerModeMapParentPtr") ? uiElems["controllerModeMapParentPtr"] : 0
    activeMapPtr     := uiElems.Has("activeMapParentPtr") ? uiElems["activeMapParentPtr"] : 0
    largeMapPtr      := uiElems.Has("largeMapPtr") ? uiElems["largeMapPtr"] : 0
    miniMapPtr       := uiElems.Has("miniMapPtr") ? uiElems["miniMapPtr"] : 0

    isController := (inGame && inGame.Has("isControllerMode") && inGame["isControllerMode"])
    modeText := isController ? "controller" : "mouse+keyboard"

    g_valueTree.Add("MapParentPtr: " PoE2GameStateReader.Hex(mapParentPtr), mapNode)
    g_valueTree.Add("ControllerModeMapParentPtr: " PoE2GameStateReader.Hex(ctrlMapParentPtr), mapNode)
    g_valueTree.Add("activeMapParentPtr (" modeText "): " PoE2GameStateReader.Hex(activeMapPtr), mapNode)
    g_valueTree.Add("LargeMapPtr: " PoE2GameStateReader.Hex(largeMapPtr), mapNode)
    g_valueTree.Add("MiniMapPtr: " PoE2GameStateReader.Hex(miniMapPtr), mapNode)
    if (expandedPaths.Has(mapPath))
        g_valueTree.Modify(mapNode, "Expand")
    else
        g_valueTree.Modify(mapNode, "Expand")   ; immer aufgeklappt, da wenig Einträge

    if (expandedPaths.Has(basePath))
        g_valueTree.Modify(rootNode, "Expand")
    else
        g_valueTree.Modify(rootNode, "Expand")
}

; Builds the Active Effects tab tree node, separating buffs into positive and negative groups.
AddActiveBuffsNode(parentId, snapshot, expandedPaths)
{
    global g_valueTree, g_nodePaths

    inGame := (snapshot && snapshot.Has("inGameState")) ? snapshot["inGameState"] : 0
    areaInst := (inGame && inGame.Has("areaInstance")) ? inGame["areaInstance"] : 0
    buffsComp := (areaInst && areaInst.Has("playerBuffsComponent")) ? areaInst["playerBuffsComponent"] : 0
    effects := (buffsComp && buffsComp.Has("effects")) ? buffsComp["effects"] : 0

    positiveItems := []
    negativeItems := []
    if (effects && Type(effects) = "Array")
    {
        for effect in effects
        {
            if !effect
                continue

            timeLeft := effect.Has("timeLeft") ? effect["timeLeft"] : 0.0
            totalTime := effect.Has("totalTime") ? effect["totalTime"] : 0.0
            isActive := (timeLeft > 0.0) || (totalTime = 0.0)
            if (isActive)
            {
                if IsLikelyNegativeEffect(effect)
                    negativeItems.Push(effect)
                else
                    positiveItems.Push(effect)
            }
        }
    }

    basePath := "snapshot/activeBuffs"
    totalCount := positiveItems.Length + negativeItems.Length
    buffsNode := g_valueTree.Add("Active Effects (" totalCount ")", parentId)
    g_nodePaths[buffsNode] := basePath

    positivePath := basePath "/positive"
    negativePath := basePath "/negative"

    positiveNode := g_valueTree.Add("Positive Buffs (" positiveItems.Length ")", buffsNode)
    g_nodePaths[positiveNode] := positivePath
    AddBuffGroupNodes(positiveNode, positivePath, positiveItems, expandedPaths)

    negativeNode := g_valueTree.Add("Negative Buffs (" negativeItems.Length ")", buffsNode)
    g_nodePaths[negativeNode] := negativePath
    AddBuffGroupNodes(negativeNode, negativePath, negativeItems, expandedPaths)

    if (expandedPaths.Has(positivePath) || positiveItems.Length <= 6)
        g_valueTree.Modify(positiveNode, "Expand")
    if (expandedPaths.Has(negativePath) || negativeItems.Length <= 6)
        g_valueTree.Modify(negativeNode, "Expand")

    if (expandedPaths.Has(basePath) || totalCount <= 8)
        g_valueTree.Modify(buffsNode, "Expand")
}

; Adds a set of buff effect nodes under a parent group node, including per-buff detail lines.
AddBuffGroupNodes(parentNode, basePath, items, expandedPaths)
{
    global g_valueTree, g_nodePaths

    idx := 0
    for effect in items
    {
        idx += 1
        rawBuffName := effect.Has("name") ? effect["name"] : ""
        buffName := GetReadableBuffName(rawBuffName)

        timeLeft := effect.Has("timeLeft") ? effect["timeLeft"] : 0.0
        totalTime := effect.Has("totalTime") ? effect["totalTime"] : 0.0
        buffLabel := idx ". " buffName " | " Format("{:.2f}", timeLeft) "s/" Format("{:.2f}", totalTime) "s"

        safeName := RegExReplace(buffName, "[/\\]", "_")
        itemPath := basePath "/" idx "-" safeName
        buffNode := g_valueTree.Add(buffLabel, parentNode)
        g_nodePaths[buffNode] := itemPath

        AddBuffStatLine(buffNode, "name", buffName)
        AddBuffStatLine(buffNode, "internalName", rawBuffName)
        AddBuffStatLine(buffNode, "buffType", effect.Has("buffType") ? effect["buffType"] : "")
        AddBuffStatLine(buffNode, "sourceEntityId", effect.Has("sourceEntityId") ? effect["sourceEntityId"] : "")
        AddBuffStatLine(buffNode, "charges", effect.Has("charges") ? effect["charges"] : "")
        AddBuffStatLine(buffNode, "flaskSlotRaw", effect.Has("flaskSlotRaw") ? effect["flaskSlotRaw"] : "")
        AddBuffStatLine(buffNode, "effectivenessRaw", effect.Has("effectivenessRaw") ? effect["effectivenessRaw"] : "")
        AddBuffStatLine(buffNode, "timeLeft", Format("{:.3f}", timeLeft))
        AddBuffStatLine(buffNode, "totalTime", Format("{:.3f}", totalTime))

        if (expandedPaths.Has(itemPath))
            g_valueTree.Modify(buffNode, "Expand")
    }
}

; Returns true if the effect name matches known debuff, curse, or ailment keywords.
IsLikelyNegativeEffect(effect)
{
    name := effect.Has("name") ? StrLower(GetReadableBuffName(effect["name"])) : ""
    buffType := effect.Has("buffType") ? effect["buffType"] : -1

    if InStr(name, "debuff")
        return true

    negativeKeywords := [
        "curse", "poison", "bleed", "ignite", "shock", "chill", "freeze", "sap", "scorch",
        "electrocute", "hinder", "maim", "wither", "vulnerability", "temporal", "exposure",
        "corrupted blood", "desecrated", "burning ground", "caustic"
    ]
    for kw in negativeKeywords
    {
        if InStr(name, kw)
            return true
    }

    ; Flask buffs are positive in this data model.
    if (buffType = 0x4)
        return false

    return false
}

; Converts a raw internal buff name to a human-readable title-cased string.
GetReadableBuffName(rawName)
{
    if (rawName = "")
        return "Unnamed Buff"

    name := rawName
    if InStr(name, "/")
    {
        parts := StrSplit(name, "/")
        if (parts.Length)
            name := parts[parts.Length]
    }

    lower := StrLower(name)
    ; Targeted mappings (requested examples)
    if InStr(lower, "heraldofthunder")
        return "Herald of Thunder"
    if InStr(lower, "heraldofash")
        return "Herald of Ash"
    if InStr(lower, "blasphemy")
        return "Blasphemy"
    if InStr(lower, "lingeringillusion")
        return "Lingering Illusion"
    if InStr(lower, "lightningconflux")
        return "Lightning Conflux"

    cleaned := RegExReplace(name, "^buff[_\-]?", "")
    cleaned := RegExReplace(cleaned, "[_\-]+", " ")
    cleaned := RegExReplace(cleaned, "([a-z])([A-Z])", "$1 $2")
    cleaned := RegExReplace(cleaned, "\s+", " ")
    cleaned := Trim(cleaned)

    if (cleaned = "")
        return rawName

    return TitleCaseWords(cleaned)
}

; Title-cases a space-separated string, keeping small connector words lowercase unless they are first.
TitleCaseWords(text)
{
    smallWords := Map("of", true, "the", true, "and", true, "or", true, "in", true, "on", true, "to", true)
    parts := StrSplit(StrLower(text), " ")
    out := ""
    loop parts.Length
    {
        word := parts[A_Index]
        if (word = "")
            continue

        if (A_Index > 1 && smallWords.Has(word))
            cap := word
        else
            cap := StrUpper(SubStr(word, 1, 1)) SubStr(word, 2)

        out .= (out = "" ? "" : " ") cap
    }
    return out
}

; Adds a single "key: value" child node to a buff tree node.
AddBuffStatLine(parentId, key, value)
{
    global g_valueTree
    g_valueTree.Add(key ": " value, parentId)
}

; Recursively builds a tree node hierarchy from a snapshot value (Map, Array, or scalar).
; Handles special cases for stats arrays, flask slots, mods info, and state machine components.
BuildTreeNode(parentId, name, value, depth, counters, expandedPaths, nodePath)
{
    global g_valueTree, g_nodePaths, g_debugMode, g_autoFlaskPerformanceMode

    if (g_autoFlaskPerformanceMode && !IsAutoFlaskRelevantPath(nodePath))
        return

    if (!g_debugMode && ShouldHideNode(nodePath, name))
        return

    maxDepth := 15
    maxNodes := 20000

    if (counters["nodes"] >= maxNodes)
        return

    if (depth > maxDepth)
    {
        nodeId := g_valueTree.Add(name ": <max depth reached>", parentId)
        g_nodePaths[nodeId] := nodePath
        counters["nodes"] += 1
        return
    }

    if !IsObject(value)
    {
        ; Empty flask slot: show "Slot N - (empty)" instead of "N: 0"
        if (RegExMatch(StrLower(nodePath), "/flaskslots/(\d+)$", &m) && value = 0)
        {
            nodeId := g_valueTree.Add("Slot " m[1] " - (empty)", parentId)
            g_nodePaths[nodeId] := nodePath
            counters["nodes"] += 1
            return
        }
        nodeId := g_valueTree.Add(name ": " FormatScalar(value, name, nodePath), parentId)
        g_nodePaths[nodeId] := nodePath
        counters["nodes"] += 1
        return
    }

    typeName := Type(value)
    nameLower := StrLower(name)

    if (typeName = "Map" && nameLower = "modsinfo")
    {
        RenderModsInfoNode(parentId, name, value, depth, counters, expandedPaths, nodePath)
        return
    }

    ; Flask slot entry: path ends in /flaskslots/N — use displayName as label
    if (typeName = "Map" && RegExMatch(StrLower(nodePath), "/flaskslots/\d+$"))
    {
        slotNum := name
        displayLabel := "Slot " slotNum
        if (value.Has("itemDetails") && IsObject(value["itemDetails"]) && value["itemDetails"].Has("displayName"))
            displayLabel := "Slot " slotNum " - " value["itemDetails"]["displayName"]
        else if (value = 0 || !IsObject(value))
            displayLabel := "Slot " slotNum " - (empty)"
        nodeId := g_valueTree.Add(displayLabel " {Map, count=" value.Count "}", parentId)
        g_nodePaths[nodeId] := nodePath
        counters["nodes"] += 1
        for key, val in value
        {
            childPath := nodePath "/" key
            BuildTreeNode(nodeId, key, val, depth + 1, counters, expandedPaths, childPath)
            if (counters["nodes"] >= maxNodes)
                break
        }
        autoExpand := expandedPaths.Has(nodePath)
        if autoExpand
            g_valueTree.Modify(nodeId, "Expand")
        return
    }

    if (typeName = "Map" && (nameLower = "playerstatemachinecomponent" || InStr(StrLower(nodePath), "/playerstatemachinecomponent")))
    {
        RenderStateMachineComponentNode(parentId, name, value, depth, counters, expandedPaths, nodePath)
        return
    }

    ; Stat pair: {key: statRowIndex, value: statValue} — render as flat leaf "statName: value"
    nodePathLower := StrLower(nodePath)
    if (typeName = "Map" && value.Count = 2 && value.Has("key") && value.Has("value")
        && !IsObject(value["key"]) && !IsObject(value["value"])
        && (InStr(nodePathLower, "statsbyitems") || InStr(nodePathLower, "statsbybuffandactions")))
    {
        label := FormatStatEntry(value["key"], value["value"])
        if (label = "")
            return  ; suppressed — already rendered as part of a multi-stat group by sibling
        nodeId := g_valueTree.Add(name ": " label, parentId)
        g_nodePaths[nodeId] := nodePath
        counters["nodes"] += 1
        return
    }

    if (typeName = "Map")
    {
        if (StrLower(nodePath) = "snapshot/ingamestate/areainstance")
        {
            if (!value.Has("vitalStruct") && value.Has("playerVitals"))
                value["vitalStruct"] := value["playerVitals"]

            if (!value.Has("playerStruct") && value.Has("playerVitals"))
            {
                playerStruct := Map(
                    "localPlayerPtr", value.Has("localPlayerPtr") ? value["localPlayerPtr"] : 0,
                    "localPlayerRawPtr", value.Has("localPlayerRawPtr") ? value["localPlayerRawPtr"] : 0,
                    "vitalStruct", value["playerVitals"],
                    "playerVitals", value["playerVitals"]
                )

                value["playerStruct"] := playerStruct
            }
        }

        nodeId := g_valueTree.Add(name " {Map, count=" value.Count "}", parentId)
        g_nodePaths[nodeId] := nodePath
        counters["nodes"] += 1
        if (StrLower(nodePath) = "snapshot/ingamestate")
        {
            ; Leichte Felder zuerst rendern — areaInstance ist teuer und kommt ans Ende
            preferredKeys := [
                "address",
                "areaInstanceData",
                "worldData",
                "worldDataDetails",
                "uiRootStructPtr",
                "uiRootPtr",
                "gameUiPtr",
                "gameUiControllerPtr",
                "activeGameUiPtr",
                "isControllerMode",
                "areaInstance"
            ]
            emitted := Map()

            for _, prefKey in preferredKeys
            {
                if !value.Has(prefKey)
                    continue
                emitted[prefKey] := true
                childPath := nodePath "/" prefKey
                BuildTreeNode(nodeId, prefKey, value[prefKey], depth + 1, counters, expandedPaths, childPath)
                if (counters["nodes"] >= maxNodes)
                    break
            }

            if (counters["nodes"] < maxNodes)
            {
                for key, val in value
                {
                    if emitted.Has(key)
                        continue
                    childPath := nodePath "/" key
                    BuildTreeNode(nodeId, key, val, depth + 1, counters, expandedPaths, childPath)
                    if (counters["nodes"] >= maxNodes)
                        break
                }
            }

            autoExpand := (depth <= 1 || expandedPaths.Has(nodePath))
            if autoExpand
                g_valueTree.Modify(nodeId, "Expand")
            return
        }
        if (StrLower(nodePath) = "snapshot/ingamestate/areainstance")
        {
            preferredKeys := [
                "vitalStruct",
                "playerStruct",
                "playerVitals",
                "localPlayerPtr",
                "localPlayerRawPtr",
                "serverDataPtr",
                "serverDataRawPtr",
                "address",
                "currentAreaLevel",
                "currentAreaHash",
                "flaskSlotsFromBuffs",
                "playerBuffsComponent",
                "playerStatsComponent",
                "playerStateMachineComponent",
                "playerComponent",
                "awakeEntities",
                "sleepingEntities"
            ]
            emitted := Map()

            for _, prefKey in preferredKeys
            {
                if !value.Has(prefKey)
                    continue

                emitted[prefKey] := true
                childPath := nodePath "/" prefKey
                BuildTreeNode(nodeId, prefKey, value[prefKey], depth + 1, counters, expandedPaths, childPath)
                if (counters["nodes"] >= maxNodes)
                    break
            }

            if (counters["nodes"] < maxNodes)
            {
                for key, val in value
                {
                    if emitted.Has(key)
                        continue

                    childPath := nodePath "/" key
                    BuildTreeNode(nodeId, key, val, depth + 1, counters, expandedPaths, childPath)
                    if (counters["nodes"] >= maxNodes)
                        break
                }
            }
        }
        else
        {
            pathLower := StrLower(nodePath)
            if (pathLower = "snapshot")
            {
                ; Leichte Felder zuerst, inGameState (teuerste) zuletzt
                preferredKeys := [
                    "snapshotMode",
                    "gameStatesAddress",
                    "gameStateObject",
                    "currentStateAddress",
                    "currentStateName",
                    "inGameStateAddress",
                    "allStates",
                    "staticAddresses",
                    "inGameState"
                ]
                emitted := Map()
                for _, prefKey in preferredKeys
                {
                    if !value.Has(prefKey)
                        continue
                    emitted[prefKey] := true
                    childPath := nodePath "/" prefKey
                    BuildTreeNode(nodeId, prefKey, value[prefKey], depth + 1, counters, expandedPaths, childPath)
                    if (counters["nodes"] >= maxNodes)
                        break
                }
                if (counters["nodes"] < maxNodes)
                {
                    for key, val in value
                    {
                        if emitted.Has(key)
                            continue
                        childPath := nodePath "/" key
                        BuildTreeNode(nodeId, key, val, depth + 1, counters, expandedPaths, childPath)
                        if (counters["nodes"] >= maxNodes)
                            break
                    }
                }
            }
            else
            {
                for key, val in value
                {
                    childPath := nodePath "/" key
                    BuildTreeNode(nodeId, key, val, depth + 1, counters, expandedPaths, childPath)
                    if (counters["nodes"] >= maxNodes)
                        break
                }
            }
        }
        autoExpand := (depth <= 1 || expandedPaths.Has(nodePath))
        ; allStates ist ein statischer Satz von Slots und sollte standardmaessig eingeklappt bleiben.
        if (nameLower = "allstates")
            autoExpand := expandedPaths.Has(nodePath)

        if autoExpand
            g_valueTree.Modify(nodeId, "Expand")
        return
    }

    if (typeName = "Array")
    {
        nodeId := g_valueTree.Add(name " [Array, len=" value.Length "]", parentId)
        g_nodePaths[nodeId] := nodePath
        counters["nodes"] += 1

        ; Pre-build sibling context for stats arrays so multi-stat groups can be resolved
        nodePathLower := StrLower(nodePath)
        isStatsArray := (InStr(nodePathLower, "statsbyitems") || InStr(nodePathLower, "statsbybuffandactions"))
        if isStatsArray
            BuildStatSiblingContext(value)

        loop value.Length
        {
            idx := A_Index
            childPath := nodePath "/[" idx "]"
            ; For allStates: use the state's name field as label if available
            childName := "[" idx "]"
            if (nameLower = "allstates" && Type(value[idx]) = "Map" && value[idx].Has("name"))
                childName := value[idx]["name"]
            BuildTreeNode(nodeId, childName, value[idx], depth + 1, counters, expandedPaths, childPath)
            if (counters["nodes"] >= maxNodes)
                break
        }

        if isStatsArray
        {
            global _statsFormatted, _statsRaw, _statsSuppressed, _rawStatIds
            total := value.Length
            debugLabel := name " [Array, len=" total " | " _statsFormatted " fmt, " _statsRaw " raw, " _statsSuppressed " hidden]"
            g_valueTree.Modify(nodeId, , debugLabel)
            ; Write raw stat IDs to debug file for analysis
            if (Type(_rawStatIds) = "Array" && _rawStatIds.Length > 0)
            {
                logFile := A_ScriptDir "\\data\\raw_stats_debug.tsv"
                logContent := "stat_id`tvalue`n"
                for _, line in _rawStatIds
                    logContent .= line "`n"
                try {
                    fh := FileOpen(logFile, "w", "UTF-8")
                    fh.Write(logContent)
                    fh.Close()
                }
            }
            ClearStatSiblingContext()
        }

        autoExpand := (depth <= 1 || expandedPaths.Has(nodePath))
        if (nameLower = "allstates")
            autoExpand := expandedPaths.Has(nodePath)

        if autoExpand
            g_valueTree.Modify(nodeId, "Expand")
        return
    }

    nodeId := g_valueTree.Add(name " {" typeName "}", parentId)
    g_nodePaths[nodeId] := nodePath
    counters["nodes"] += 1
    try
    {
        for key, val in value
        {
            childPath := nodePath "/" key
            BuildTreeNode(nodeId, key, val, depth + 1, counters, expandedPaths, childPath)
            if (counters["nodes"] >= maxNodes)
                break
        }
    }
    catch
    {
        g_valueTree.Add("<not enumerable>", nodeId)
        counters["nodes"] += 1
    }

    if (depth <= 1 || expandedPaths.Has(nodePath))
        g_valueTree.Modify(nodeId, "Expand")
}

; Returns true if the node path is relevant to AutoFlask mode, used to skip unrelated tree nodes.
IsAutoFlaskRelevantPath(nodePath)
{
    pathLower := StrLower(Trim(nodePath))
    if (pathLower = "")
        return false

    prefixes := [
        "snapshot",
        "snapshot/snapshotmode",
        "snapshot/currentstateaddress",
        "snapshot/currentstatename",
        "snapshot/ingamestateaddress",
        "snapshot/ingamestate",
        "snapshot/ingamestate/worlddatadetails",
        "snapshot/ingamestate/worlddatadetails/worldareadat",
        "snapshot/ingamestate/areainstance",
        "snapshot/ingamestate/areainstance/currentarealevel",
        "snapshot/ingamestate/areainstance/currentareahash",
        "snapshot/ingamestate/areainstance/localplayerptr",
        "snapshot/ingamestate/areainstance/playervitals",
        "snapshot/ingamestate/areainstance/vitalstruct",
        "snapshot/ingamestate/areainstance/playerstruct",
        "snapshot/ingamestate/areainstance/playerbuffscomponent",
        "snapshot/ingamestate/areainstance/flaskslotsfrombuffs",
        "snapshot/ingamestate/areainstance/serverdata",
        "snapshot/ingamestate/areainstance/serverdata/flaskinventory",
        "snapshot/ingamestate/areainstance/serverdata/flaskinventory/flaskslots"
    ]

    for _, prefix in prefixes
    {
        if (pathLower = prefix)
            return true

        if (InStr(pathLower, prefix "/") = 1)
            return true

        if (InStr(prefix, pathLower "/") = 1)
            return true
    }

    return false
}

; Renders a modsInfo Map as a specialised tree node showing rarity, mod names, and grouped mod lists.
RenderModsInfoNode(parentId, name, modsInfo, depth, counters, expandedPaths, nodePath)
{
    global g_valueTree, g_nodePaths

    if (counters["nodes"] >= 20000)
        return

    sourceType:= (modsInfo.Has("sourceType") ? modsInfo["sourceType"] : "unknown")
    rarity := (modsInfo.Has("rarity") ? modsInfo["rarity"] : "Unknown")
    rarityId := (modsInfo.Has("rarityId") ? modsInfo["rarityId"] : -1)
    totalMods := 0

    countKeys := ["implicitCount", "explicitCount", "enchantCount", "hellscapeCount", "crucibleCount"]
    for _, key in countKeys
    {
        if (modsInfo.Has(key) && (Type(modsInfo[key]) = "Integer" || Type(modsInfo[key]) = "Float"))
            totalMods += modsInfo[key]
    }

    title := name " {" sourceType ", " rarity "(" rarityId "), total=" totalMods "}"
    nodeId := g_valueTree.Add(title, parentId)
    g_nodePaths[nodeId] := nodePath
    counters["nodes"] += 1

    g_valueTree.Add("sourceType: " sourceType, nodeId)
    counters["nodes"] += 1
    g_valueTree.Add("rarity: " rarity " (" rarityId ")", nodeId)
    counters["nodes"] += 1

    if (modsInfo.Has("allModNames") && Type(modsInfo["allModNames"]) = "Array")
    {
        allNames := modsInfo["allModNames"]
        preview := BuildModNamesPreview(allNames, 6)
        g_valueTree.Add("modNames: " preview, nodeId)
        counters["nodes"] += 1
    }

    AddModGroupNode(nodeId, modsInfo, "Implicit", "implicitMods", counters, expandedPaths, nodePath)
    AddModGroupNode(nodeId, modsInfo, "Explicit", "explicitMods", counters, expandedPaths, nodePath)
    AddModGroupNode(nodeId, modsInfo, "Enchant", "enchantMods", counters, expandedPaths, nodePath)
    AddModGroupNode(nodeId, modsInfo, "Hellscape", "hellscapeMods", counters, expandedPaths, nodePath)
    AddModGroupNode(nodeId, modsInfo, "Crucible", "crucibleMods", counters, expandedPaths, nodePath)

    if (depth <= 1 || expandedPaths.Has(nodePath))
        g_valueTree.Modify(nodeId, "Expand")
}

; Adds a collapsible group node for one mod category (implicit/explicit/enchant/hellscape/crucible).
AddModGroupNode(parentId, modsInfo, label, modsKey, counters, expandedPaths, basePath)
{
    global g_valueTree, g_nodePaths

    mods := (modsInfo.Has(modsKey) ? modsInfo[modsKey] : 0)
    if !(mods && Type(mods) = "Array")
    {
        g_valueTree.Add(label ": 0", parentId)
        counters["nodes"] += 1
        return
    }

    groupPath := basePath "/" modsKey
    groupNode := g_valueTree.Add(label " (" mods.Length ")", parentId)
    g_nodePaths[groupNode] := groupPath
    counters["nodes"] += 1

    maxShown := 20
    shown := Min(mods.Length, maxShown)
    idx := 0
    while (idx < shown)
    {
        idx += 1
        mod := mods[idx]
        if !(mod && Type(mod) = "Map")
        {
            g_valueTree.Add(idx ". <invalid>", groupNode)
            counters["nodes"] += 1
            continue
        }

        modName := mod.Has("name") ? mod["name"] : "(unnamed)"
        displayName := (mod.Has("displayName") && mod["displayName"] != "") ? " [" mod["displayName"] "]" : ""
        value0 := mod.Has("value0") ? mod["value0"] : ""
        value1 := mod.Has("value1") ? mod["value1"] : ""
        valuesCount := mod.Has("valuesCount") ? mod["valuesCount"] : 0

        if (value1 = "" || valuesCount < 2)
            line := idx ". " modName displayName " | v0=" value0
        else
            line := idx ". " modName displayName " | v0=" value0 ", v1=" value1

        modNode := g_valueTree.Add(line, groupNode)
        g_nodePaths[modNode] := groupPath "/mod" idx
        counters["nodes"] += 1

        if (counters["nodes"] >= 20000)
            break
    }

    if (mods.Length > shown && counters["nodes"] < 20000)
    {
        g_valueTree.Add("... +" (mods.Length - shown) " more", groupNode)
        counters["nodes"] += 1
    }

    if (expandedPaths.Has(groupPath) || mods.Length <= 6)
        g_valueTree.Modify(groupNode, "Expand")
}

; Builds a comma-separated preview string of the first maxNames mod names from the names array.
BuildModNamesPreview(names, maxNames := 6)
{
    if !(names && Type(names) = "Array")
        return "-"

    if (names.Length = 0)
        return "-"

    shown := Min(names.Length, maxNames)
    out := ""
    loop shown
    {
        n := names[A_Index]
        out .= (A_Index = 1 ? "" : ", ") n
    }

    if (names.Length > shown)
        out .= " ... (+" (names.Length - shown) ")"

    return out
}

; Renders a player state machine component as a tree node listing all named states and their values.
RenderStateMachineComponentNode(parentId, name, stateComp, depth, counters, expandedPaths, nodePath)
{
    global g_valueTree, g_nodePaths

    if (counters["nodes"] >= 20000)
        return
    stateCount := stateComp.Has("stateCount") ? stateComp["stateCount"] : 0
    resolvedNamesCount := stateComp.Has("resolvedNamesCount") ? stateComp["resolvedNamesCount"] : 0
    score := stateComp.Has("score") ? stateComp["score"] : ""
    title := name " {states=" stateCount ", named=" resolvedNamesCount (score = "" ? "" : ", score=" score) "}"

    nodeId := g_valueTree.Add(title, parentId)
    g_nodePaths[nodeId] := nodePath
    counters["nodes"] += 1

    if (stateComp.Has("address"))
    {
        g_valueTree.Add("address: " FormatScalar(stateComp["address"], "address", nodePath "/address"), nodeId)
        counters["nodes"] += 1
    }

    if (stateComp.Has("statesPtr"))
    {
        g_valueTree.Add("statesPtr: " FormatScalar(stateComp["statesPtr"], "statesPtr", nodePath "/statesPtr"), nodeId)
        counters["nodes"] += 1
    }

    states := (stateComp.Has("states") ? stateComp["states"] : 0)
    if (states && Type(states) = "Array")
    {
        statesPath := nodePath "/states"
        statesNode := g_valueTree.Add("States (" states.Length ")", nodeId)
        g_nodePaths[statesNode] := statesPath
        counters["nodes"] += 1

        shown := Min(states.Length, 40)
        idx := 0
        while (idx < shown)
        {
            idx += 1
            entry := states[idx]
            if !(entry && Type(entry) = "Map")
            {
                g_valueTree.Add(idx ". <invalid>", statesNode)
                counters["nodes"] += 1
                continue
            }

            stateName := entry.Has("name") ? entry["name"] : ""
            stateValue := entry.Has("value") ? entry["value"] : ""
            if (stateName = "" || stateName = "todo")
                line := idx ". value=" stateValue
            else
                line := idx ". " stateName " = " stateValue

            g_valueTree.Add(line, statesNode)
            counters["nodes"] += 1

            if (counters["nodes"] >= 20000)
                break
        }

        if (states.Length > shown && counters["nodes"] < 20000)
        {
            g_valueTree.Add("... +" (states.Length - shown) " more", statesNode)
            counters["nodes"] += 1
        }

        if (expandedPaths.Has(statesPath) || states.Length <= 12)
            g_valueTree.Modify(statesNode, "Expand")
    }

    if (depth <= 1 || expandedPaths.Has(nodePath))
        g_valueTree.Modify(nodeId, "Expand")
}
