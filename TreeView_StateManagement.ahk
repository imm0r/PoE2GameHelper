; TreeView_StateManagement.ahk
; Expand/collapse state, tree navigation, TreeView API wrappers, UI helpers
; Included by TreeViewWatchlistPanel.ahk

; Records the expanded state of all TreeView nodes into a path→true Map.
; Returns: Map of currently expanded node paths.
CaptureExpandedPaths()
{
    global valueTree, nodePaths

    paths := Map()
    hwnd := valueTree.Hwnd
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
    global valueTree, nodePaths

    state := Map()
    hwnd := valueTree.Hwnd

    selectedId := TV_GetSelection(hwnd)
    if (selectedId && nodePaths.Has(selectedId))
        state["selectedPath"] := nodePaths[selectedId]

    firstVisibleId := TV_GetFirstVisible(hwnd)
    if (firstVisibleId && nodePaths.Has(firstVisibleId))
        state["firstVisiblePath"] := nodePaths[firstVisibleId]

    return state
}

; Restores the previously focused and first-visible TreeView nodes after a tree refresh.
; Params: state - Map from CaptureTreeFocusState(); volatile entity paths are skipped.
RestoreTreeFocusState(state)
{
    global valueTree

    if !(state && Type(state) = "Map")
        return

    hwnd := valueTree.Hwnd

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
    global nodePaths

    for itemId, itemPath in nodePaths
    {
        if (itemPath = path)
            return itemId
    }

    return 0
}

; Recursive helper: walks sibling and child items and records paths of all expanded nodes.
CaptureExpandedRecursive(hwnd, itemId, paths)
{
    global nodePaths

    current := itemId
    while (current)
    {
        if (nodePaths.Has(current))
        {
            state := TV_GetItemState(hwnd, current, 0x20)
            if (state & 0x20)
                paths[nodePaths[current]] := true
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
    global showTreePane, treeRefreshRequested
    showTreePane := !showTreePane
    if showTreePane
        treeRefreshRequested := true
    ReadAndShow()
}

; Requests an immediate tree snapshot refresh if the tree pane is currently visible.
RequestTreeSnapshotRefresh()
{
    global showTreePane, treeRefreshRequested

    if !showTreePane
        return

    treeRefreshRequested := true
    ForceRefreshActiveTree()
}

; Re-populates the offset table using the last captured snapshot.
RefreshOffsetTableView()
{
    global lastSnapshotForUi

    if (lastSnapshotForUi)
        UpdateOffsetTable(lastSnapshotForUi)
}

; Removes the currently selected row from the pinned watchlist and refreshes the view.
; Also adds the path to the NPC ignore list if it is an NPC watch entry.
RemoveSelectedPinnedFromTable()
{
    global offsetTable, offsetTableRowPathByRow, pinnedNodePaths, npcWatchIgnoredKeys

    if !offsetTable
        return

    row := offsetTable.GetNext(0, "F")
    if (row <= 0 || !offsetTableRowPathByRow.Has(row))
        return

    targetPath := offsetTableRowPathByRow[row]
    idx := 0
    for _, path in pinnedNodePaths
    {
        idx += 1
        if (path = targetPath)
        {
            pinnedNodePaths.RemoveAt(idx)
            break
        }
    }

    if IsNpcWatchKey(targetPath)
        npcWatchIgnoredKeys[targetPath] := true

    ReadAndShow()
}

; Synchronises pinned NPC watch keys with the current NPC lookup, removing stale entries and adding new ones.
; Params: npcLookup - Map of watch key → display value built by BuildNpcWatchIndex.
SyncNpcWatchEntries(snapshot, npcLookup)
{
    global pinnedNodePaths, npcWatchAutoSync, npcWatchIgnoredKeys

    if !npcWatchAutoSync
        return

    ; Entferne verwaiste @npc:-Eintraege (tot, Gebietswechsel, ausser Range)
    i := 1
    while (i <= pinnedNodePaths.Length)
    {
        key := pinnedNodePaths[i]
        if (IsNpcWatchKey(key) && !npcLookup.Has(key))
        {
            if npcWatchIgnoredKeys.Has(key)
                npcWatchIgnoredKeys.Delete(key)
            pinnedNodePaths.RemoveAt(i)
        }
        else
            i += 1
    }

    staleIgnored := []
    for ignoredKey, _ in npcWatchIgnoredKeys
    {
        if !npcLookup.Has(ignoredKey)
            staleIgnored.Push(ignoredKey)
    }
    for _, staleKey in staleIgnored
        npcWatchIgnoredKeys.Delete(staleKey)

    ; Fuege neue NPCs innerhalb der Range hinzu
    for key, _ in npcLookup
    {
        if npcWatchIgnoredKeys.Has(key)
            continue

        exists := false
        for _, current in pinnedNodePaths
        {
            if (current = key)
            {
                exists := true
                break
            }
        }
        if !exists
            pinnedNodePaths.Push(key)
    }

    if (pinnedNodePaths.Length > 256)
    {
        while (pinnedNodePaths.Length > 256)
            pinnedNodePaths.RemoveAt(1)
    }
}

; Toggles NPC auto-sync mode; when enabling, immediately populates the watchlist with nearby NPCs.
AddNearbyNpcScannerToWatchlist()
{
    global pinnedNodePaths, lastSnapshotForUi, npcWatchRadius, npcWatchAutoSync, npcWatchIgnoredKeys

    npcWatchAutoSync := !npcWatchAutoSync
    SaveConfig()

    if !npcWatchAutoSync
    {
        ReadAndShow()
        return
    }

    if !lastSnapshotForUi
    {
        ReadAndShow()
        return
    }

    npcWatchIgnoredKeys := Map()

    npcWatch  := BuildNpcWatchIndex(lastSnapshotForUi, npcWatchRadius)
    npcLookup := npcWatch["lookup"]
    SyncNpcWatchEntries(lastSnapshotForUi, npcLookup)
    ReadAndShow()
}

; Adds the currently selected tree node path to the pinned watchlist (capped at 32 entries).
PinSelectedTreeNodePath()
{
    global pinnedNodePaths

    path := GetSelectedTreeNodePath()
    if (path = "")
        return

    for _, existingPath in pinnedNodePaths
    {
        if (existingPath = path)
            return
    }

    pinnedNodePaths.Push(path)
    if (pinnedNodePaths.Length > 32)
        pinnedNodePaths.RemoveAt(1)

    ReadAndShow()
}

; Clears all pinned watch paths and resets the NPC ignore list.
ClearPinnedNodePaths()
{
    global pinnedNodePaths, npcWatchIgnoredKeys
    pinnedNodePaths := []
    npcWatchIgnoredKeys := Map()
    ReadAndShow()
}

; Returns the node path string of the currently selected TreeView item, or "" if nothing is selected.
GetSelectedTreeNodePath()
{
    global valueTree, nodePaths

    if !valueTree
        return ""

    selectedId := TV_GetSelection(valueTree.Hwnd)
    if (!selectedId || !nodePaths.Has(selectedId))
        return ""

    return nodePaths[selectedId]
}

