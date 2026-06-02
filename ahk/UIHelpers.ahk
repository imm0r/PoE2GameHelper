; UIHelpers.ahk — Threshold parsing, value formatters, tree-node filters, and click delegates.
;
; Included by InGameStateMonitor.ahk.
; Heavy logic has been extracted to: ToggleHandlers.ahk, DebugDump.ahk,
; WebViewBridge.ahk, SnapshotSerializers.ahk, ConfigManager.ahk.

; Click handler for the Apply Threshold button; delegates to ApplyThresholdsFromUI.
OnApplyThresholdClick(*)
{
    ApplyThresholdsFromUI()
}

; Applies life/mana thresholds from provided values and triggers a UI refresh.
ApplyThresholdsFromUI(lifeRaw := "", manaRaw := "")
{
    global g_lifeThresholdPercent, g_manaThresholdPercent

    if (lifeRaw != "")
        g_lifeThresholdPercent := ParseThresholdPercent(lifeRaw, g_lifeThresholdPercent)
    if (manaRaw != "")
        g_manaThresholdPercent := ParseThresholdPercent(manaRaw, g_manaThresholdPercent)

    SaveConfig()
    ReadAndShow()
}

; Parses a percentage string from a UI input field and clamps the result to [1, 100].
; Params: raw - raw string value from the edit control; fallback - returned when parsing fails
; Returns: integer percentage in [1, 100]
ParseThresholdPercent(raw, fallback)
{
    text := Trim(raw)
    if !RegExMatch(text, "^-?\d+$")
        return fallback

    val := Integer(text)
    if (val < 1)
        val := 1
    if (val > 100)
        val := 100
    return val
}

; Returns (current / max) * 100 as a float, or -1 if max is zero to avoid division by zero.
SafePercent(current, max)
{
    if (max <= 0)
        return -1
    return (current * 100.0) / max
}

; Returns true if the given tree node should be suppressed from the display.
; Hides noise nodes such as patternScanReport, inventory ID lists, and duplicate vitals paths.
ShouldHideNode(nodePath, name)
{
    pathLower := StrLower(nodePath)
    nameLower := StrLower(name)

    if (nameLower = "patternscanreport")
        return true

    if (nameLower = "inventoryidsseen" || nameLower = "flaskinventoryselectreason")
        return true

    if InStr(pathLower, "/patternscanreport")
        return true

    ; Legacy-Compat: Vitaldaten nur einmal anzeigen (top-level vitalStruct unter areaInstance).
    if (pathLower = "snapshot/ingamestate/areainstance/playervitals")
        return true
    if (pathLower = "snapshot/ingamestate/areainstance/playerstruct/playervitals")
        return true
    if (pathLower = "snapshot/ingamestate/areainstance/playerstruct/vitalstruct")
        return true

    return false
}

; Formats a raw memory value for TreeView display; renders large integers and address-like fields as hex.
; Params: fieldName - optional field name hint; nodePath - optional path used by the address heuristic
FormatScalar(value, fieldName := "", nodePath := "")
{
    valueType := Type(value)

    if (valueType = "String")
        return value

    if (valueType = "Integer")
    {
        if (value > 0x10000 || IsAddressLikeField(fieldName, nodePath))
            return PoE2GameStateReader.Hex(value)
        return value
    }

    if (valueType = "Float")
        return value

    if (valueType = "Buffer")
        return "<Buffer size=" value.Size ">"

    return value
}

; Heuristic: returns true if the field name or path suggests the value is a memory pointer or address.
IsAddressLikeField(fieldName, nodePath := "")
{
    nameLower := StrLower(Trim(fieldName))
    pathLower := StrLower(Trim(nodePath))

    if (nameLower != "")
    {
        if (InStr(nameLower, "address") || InStr(nameLower, "addr") || InStr(nameLower, "ptr") || InStr(nameLower, "pointer"))
            return true
    }

    if (pathLower != "")
    {
        if (InStr(pathLower, "/address") || InStr(pathLower, "address/") || InStr(pathLower, "/ptr") || InStr(pathLower, "ptr/"))
            return true
    }

    return false
}

; Builds the hotkey legend string shown in the status row, reflecting all current toggle states.
; Returns: formatted legend string with Debug/Updates/AutoFlask/AF Perf/Tree/TreeMode/Pinned status
BuildHotkeyLegendText()
{
    global g_debugMode, g_updatesPaused, g_autoFlaskEnabled, g_autoFlaskPerformanceMode, g_pinnedNodePaths, g_showTreePane, g_activeTreeTabKey

    return (
        "Buttons: "
        . "Debug(" (g_debugMode ? "ON" : "OFF") ") | "
        . "Updates(" (g_updatesPaused ? "PAUSED" : "LIVE") ") | "
        . "AutoFlask(" (g_autoFlaskEnabled ? "ON" : "OFF") ") | "
        . "AFPerf(" (g_autoFlaskPerformanceMode ? "ON" : "OFF") ") | "
        . "Tree(" (g_showTreePane ? "ON" : "OFF") ") | "
        . "TreeMode(MANUAL:" g_activeTreeTabKey ") | "
        . "Pinned(" g_pinnedNodePaths.Length ")"
    )
}

; Pushes the current toggle states to the WebView header area.
UpdateActionButtonLabels()
{
    PushHeaderToWebView()
}

OnDebugButtonClick(*) => ToggleDebugMode()
OnPauseButtonClick(*) => ToggleUpdatesPause()
OnAutoFlaskButtonClick(*) => ToggleAutoFlaskMode()
OnAutoFlaskPerfButtonClick(*) => ToggleAutoFlaskPerformanceMode()
OnPinSelectedButtonClick(*) => PinSelectedTreeNodePath()
OnWatchNearbyNpcButtonClick(*) => AddNearbyNpcScannerToWatchlist()
OnTreeToggleButtonClick(*) => ToggleTreePaneVisibility()
OnTreeSnapButtonClick(*) => ForceRefreshActiveTree()
OnClearPinsButtonClick(*) => ClearPinnedNodePaths()

OnOffsetSearchChanged(*) => RefreshOffsetTableView()
OnRemovePinnedSelectedClick(*) => RemoveSelectedPinnedFromTable()

; No-op: radar filter state is now set directly via the JS bridge (SetRadarFilter).
OnRadarFilterChanged(*)
{
}

; (Toggle handlers moved to ToggleHandlers.ahk)
; (Debug dump functions moved to DebugDump.ahk)

; (WebView push helpers moved to WebViewBridge.ahk)

; Switches the active tree tab by key name and triggers a refresh.
SwitchTreeTab(key)
{
    global g_activeTreeTabIdx, g_treeTabKeys

    loop g_treeTabKeys.Length
    {
        if (g_treeTabKeys[A_Index] = key)
        {
            g_activeTreeTabIdx := A_Index
            break
        }
    }
    SetActiveTreeContextFromTab()
    ForceRefreshActiveTree()
}

; GameHelperBridge is no longer used — JS→AHK is handled via postMessage / OnWebMessage.
; Kept as empty stub for any legacy references.
/*
class GameHelperBridge
{
}
*/

; (Snapshot serializers + special-tab push functions moved to SnapshotSerializers.ahk + WebViewBridge.ahk)

; (Config persistence moved to ConfigManager.ahk)