; TreeView_StateManagement.ahk
; Expand/collapse state, tree navigation, TreeView API wrappers, UI helpers
; Included by TreeViewWatchlistPanel.ahk

; Records the expanded state of all TreeView nodes into a path→true Map.
; Returns: Map of currently expanded node paths.
CaptureExpandedPaths()
{
    global g_valueTree, g_nodePaths

    paths := Map()
    hwnd := g_valueTree.Hwnd
    root := TV_GetRoot(hwnd)
    if (!root)
        return paths

    CaptureExpandedRecursive(hwnd, root, paths)
    return paths
}

; Captures the currently selected and first-visible node paths for later restoration.
; Returns: Map with keys "selectedPath" and "firstVisiblePath".
CaptureTreeFocusState()
{
    global g_valueTree, g_nodePaths

    state := Map()
    hwnd := g_valueTree.Hwnd

    selectedId := TV_GetSelection(hwnd)
    if (selectedId && g_nodePaths.Has(selectedId))
        state["selectedPath"] := g_nodePaths[selectedId]

    firstVisibleId := TV_GetFirstVisible(hwnd)
    if (firstVisibleId && g_nodePaths.Has(firstVisibleId))
        state["firstVisiblePath"] := g_nodePaths[firstVisibleId]

    return state
}

; Restores the previously focused and first-visible TreeView nodes after a tree refresh.
; Params: state - Map from CaptureTreeFocusState(); volatile entity paths are skipped.
RestoreTreeFocusState(state)
{
    global g_valueTree

    if !(state && Type(state) = "Map")
        return

    hwnd := g_valueTree.Hwnd

    if (state.Has("selectedPath"))
    {
        selectedPath := state["selectedPath"]
        if !IsVolatileTreePath(selectedPath)
        {
            selectedId := FindNodeIdByPath(selectedPath)
            if (selectedId)
                TV_SelectItem(hwnd, selectedId)
        }
    }

    if (state.Has("firstVisiblePath"))
    {
        firstVisiblePath := state["firstVisiblePath"]
        if !IsVolatileTreePath(firstVisiblePath)
        {
            firstVisibleId := FindNodeIdByPath(firstVisiblePath)
            if (firstVisibleId)
                TV_SetFirstVisible(hwnd, firstVisibleId)
        }
    }
}

; Returns true for tree paths that change every refresh and should not be restored (entity scanner, highlights, pinned watch).
IsVolatileTreePath(path)
{
    if (path = "")
        return false

    return (InStr(path, "snapshot/entityScanner") = 1)
        || (InStr(path, "snapshot/entityHighlights") = 1)
        || (InStr(path, "snapshot/pinnedWatch") = 1)
}

; Looks up a TreeView item ID by its node path string.
; Returns: the item ID, or 0 if not found.
FindNodeIdByPath(path)
{
    global g_nodePaths

    for itemId, itemPath in g_nodePaths
    {
        if (itemPath = path)
            return itemId
    }

    return 0
}

; Recursive helper: walks sibling and child items and records paths of all expanded nodes.
CaptureExpandedRecursive(hwnd, itemId, paths)
{
    global g_nodePaths

    current := itemId
    while (current)
    {
        if (g_nodePaths.Has(current))
        {
            state := TV_GetItemState(hwnd, current, 0x20)
            if (state & 0x20)
                paths[g_nodePaths[current]] := true
        }

        child := TV_GetChild(hwnd, current)
        if (child)
            CaptureExpandedRecursive(hwnd, child, paths)

        current := TV_GetNext(hwnd, current)
    }
}

; Returns the root item handle of the TreeView (TVM_GETNEXTITEM / TVGN_ROOT).
TV_GetRoot(hwnd)
{
    return SendMessage(0x110A, 0x0, 0, , "ahk_id " hwnd)
}

; Returns the next sibling item handle (TVM_GETNEXTITEM / TVGN_NEXT).
TV_GetNext(hwnd, itemId)
{
    return SendMessage(0x110A, 0x1, itemId, , "ahk_id " hwnd)
}

; Returns the first child item handle (TVM_GETNEXTITEM / TVGN_CHILD).
TV_GetChild(hwnd, itemId)
{
    return SendMessage(0x110A, 0x4, itemId, , "ahk_id " hwnd)
}

; Returns the currently selected item handle (TVM_GETNEXTITEM / TVGN_CARET).
TV_GetSelection(hwnd)
{
    return SendMessage(0x110A, 0x9, 0, , "ahk_id " hwnd)
}

; Returns the first visible item handle (TVM_GETNEXTITEM / TVGN_FIRSTVISIBLE).
TV_GetFirstVisible(hwnd)
{
    return SendMessage(0x110A, 0x5, 0, , "ahk_id " hwnd)
}

; Selects the specified item (TVM_SELECTITEM / TVGN_CARET).
TV_SelectItem(hwnd, itemId)
{
    return SendMessage(0x110B, 0x9, itemId, , "ahk_id " hwnd)
}

; Scrolls the TreeView so the specified item becomes the first visible (TVM_SELECTITEM / TVGN_FIRSTVISIBLE).
TV_SetFirstVisible(hwnd, itemId)
{
    return SendMessage(0x110B, 0x5, itemId, , "ahk_id " hwnd)
}

; Returns the item state flags masked by the given state mask (TVM_GETITEMSTATE).
TV_GetItemState(hwnd, itemId, mask)
{
    return SendMessage(0x1127, itemId, mask, , "ahk_id " hwnd)
}


; --- Panel-Steuerung ---

; Toggles the tree pane visibility, updates the overlay layout, and triggers a refresh.
ToggleTreePaneVisibility()
{
    global g_showTreePane, g_treeRefreshRequested
    g_showTreePane := !g_showTreePane
    if g_showTreePane
        g_treeRefreshRequested := true
    ReadAndShow()
}

; Requests an immediate tree snapshot refresh if the tree pane is currently visible.
RequestTreeSnapshotRefresh()
{
    global g_showTreePane, g_treeRefreshRequested

    if !g_showTreePane
        return

    g_treeRefreshRequested := true
    ForceRefreshActiveTree()
}

; Re-populates the offset table using the last captured snapshot.
RefreshOffsetTableView()
{
    global g_lastSnapshotForUi

    if (g_lastSnapshotForUi)
        UpdateOffsetTable(g_lastSnapshotForUi)
}

; Removes the currently selected row from the pinned watchlist and refreshes the view.
; Also adds the path to the NPC ignore list if it is an NPC watch entry.
RemoveSelectedPinnedFromTable()
{
    global g_offsetTable, g_offsetTableRowPathByRow, g_pinnedNodePaths, g_npcWatchIgnoredKeys

    if !g_offsetTable
        return

    row := g_offsetTable.GetNext(0, "F")
    if (row <= 0 || !g_offsetTableRowPathByRow.Has(row))
        return

    targetPath := g_offsetTableRowPathByRow[row]
    idx := 0
    for _, path in g_pinnedNodePaths
    {
        idx += 1
        if (path = targetPath)
        {
            g_pinnedNodePaths.RemoveAt(idx)
            break
        }
    }

    if IsNpcWatchKey(targetPath)
        g_npcWatchIgnoredKeys[targetPath] := true

    ReadAndShow()
}

; Synchronises pinned NPC watch keys with the current NPC lookup, removing stale entries and adding new ones.
; Params: npcLookup - Map of watch key → display value built by BuildNpcWatchIndex.
SyncNpcWatchEntries(snapshot, npcLookup)
{
    global g_pinnedNodePaths, g_npcWatchAutoSync, g_npcWatchIgnoredKeys

    if !g_npcWatchAutoSync
        return

    ; Entferne verwaiste @npc:-Eintraege (tot, Gebietswechsel, ausser Range)
    i := 1
    while (i <= g_pinnedNodePaths.Length)
    {
        key := g_pinnedNodePaths[i]
        if (IsNpcWatchKey(key) && !npcLookup.Has(key))
        {
            if g_npcWatchIgnoredKeys.Has(key)
                g_npcWatchIgnoredKeys.Delete(key)
            g_pinnedNodePaths.RemoveAt(i)
        }
        else
            i += 1
    }

    staleIgnored := []
    for ignoredKey, _ in g_npcWatchIgnoredKeys
    {
        if !npcLookup.Has(ignoredKey)
            staleIgnored.Push(ignoredKey)
    }
    for _, staleKey in staleIgnored
        g_npcWatchIgnoredKeys.Delete(staleKey)

    ; Fuege neue NPCs innerhalb der Range hinzu
    for key, _ in npcLookup
    {
        if g_npcWatchIgnoredKeys.Has(key)
            continue

        exists := false
        for _, current in g_pinnedNodePaths
        {
            if (current = key)
            {
                exists := true
                break
            }
        }
        if !exists
            g_pinnedNodePaths.Push(key)
    }

    if (g_pinnedNodePaths.Length > 256)
    {
        while (g_pinnedNodePaths.Length > 256)
            g_pinnedNodePaths.RemoveAt(1)
    }
}

; Toggles NPC auto-sync mode; when enabling, immediately populates the watchlist with nearby NPCs.
AddNearbyNpcScannerToWatchlist()
{
    global g_pinnedNodePaths, g_lastSnapshotForUi, g_npcWatchRadius, g_npcWatchAutoSync, g_npcWatchIgnoredKeys

    g_npcWatchAutoSync := !g_npcWatchAutoSync
    SaveConfig()

    if !g_npcWatchAutoSync
    {
        ReadAndShow()
        return
    }

    if !g_lastSnapshotForUi
    {
        ReadAndShow()
        return
    }

    g_npcWatchIgnoredKeys := Map()

    npcWatch  := BuildNpcWatchIndex(g_lastSnapshotForUi, g_npcWatchRadius)
    npcLookup := npcWatch["lookup"]
    SyncNpcWatchEntries(g_lastSnapshotForUi, npcLookup)
    ReadAndShow()
}

; Adds the currently selected tree node path to the pinned watchlist (capped at 32 entries).
PinSelectedTreeNodePath()
{
    global g_pinnedNodePaths

    path := GetSelectedTreeNodePath()
    if (path = "")
        return

    for _, existingPath in g_pinnedNodePaths
    {
        if (existingPath = path)
            return
    }

    g_pinnedNodePaths.Push(path)
    if (g_pinnedNodePaths.Length > 32)
        g_pinnedNodePaths.RemoveAt(1)

    ReadAndShow()
}

; Clears all pinned watch paths and resets the NPC ignore list.
ClearPinnedNodePaths()
{
    global g_pinnedNodePaths, g_npcWatchIgnoredKeys
    g_pinnedNodePaths := []
    g_npcWatchIgnoredKeys := Map()
    ReadAndShow()
}

; Returns the node path string of the currently selected TreeView item, or "" if nothing is selected.
GetSelectedTreeNodePath()
{
    global g_valueTree, g_nodePaths

    if !g_valueTree
        return ""

    selectedId := TV_GetSelection(g_valueTree.Hwnd)
    if (!selectedId || !g_nodePaths.Has(selectedId))
        return ""

    return g_nodePaths[selectedId]
}

