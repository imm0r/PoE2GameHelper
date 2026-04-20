; ConfigManager.ahk
; Persists all user-configurable settings to/from gamehelper_config.ini.
;
; Included by InGameStateMonitor.ahk

; Returns the full path to the configuration INI file.
_ConfigPath() => A_ScriptDir "\gamehelper_config.ini"

; Writes all current global settings to the INI file.
SaveConfig()
{
    global g_debugMode, g_autoFlaskEnabled, g_autoFlaskPerformanceMode
    global g_lifeThresholdPercent, g_manaThresholdPercent, g_radarEnabled, g_radarAlpha
    global g_playerHudEnabled
    global g_updatesPaused, g_npcWatchAutoSync
    global g_radarShowEnemyNormal, g_radarShowEnemyRare, g_radarShowEnemyBoss
    global g_radarShowMinions, g_radarShowNpcs, g_radarShowChests
    global g_entityShowPlayer, g_entityShowMinion, g_entityShowEnemy
    global g_entityShowNPC, g_entityShowChest, g_entityShowWorldItem, g_entityShowOther
    global g_skillBuffBlacklist, g_zoneNavEnabled, g_mapHackEnabled
    global g_panelDetectionEnabled
    global g_cfgOpenSections
    global g_winX, g_winY, g_winW, g_winH, g_winMaximized

    f := _ConfigPath()
    IniWrite(g_debugMode             ? "1" : "0",  f, "General",       "debugMode")
    IniWrite(g_updatesPaused         ? "1" : "0",  f, "General",       "updatesPaused")
    IniWrite(g_npcWatchAutoSync      ? "1" : "0",  f, "General",       "npcWatchAutoSync")
    IniWrite(g_lifeThresholdPercent,               f, "General",       "lifeThreshold")
    IniWrite(g_manaThresholdPercent,               f, "General",       "manaThreshold")
    IniWrite(g_autoFlaskEnabled      ? "1" : "0",  f, "AutoFlask",     "enabled")
    IniWrite(g_autoFlaskPerformanceMode ? "1":"0", f, "AutoFlask",     "performanceMode")
    IniWrite(g_radarEnabled          ? "1" : "0",  f, "Radar",         "enabled")
    IniWrite(g_playerHudEnabled     ? "1" : "0",  f, "Radar",         "playerHud")
    IniWrite(g_radarAlpha,                         f, "Radar",         "alpha")
    IniWrite(g_radarShowEnemyNormal  ? "1" : "0",  f, "Radar",         "showNormal")
    IniWrite(g_radarShowEnemyRare    ? "1" : "0",  f, "Radar",         "showRare")
    IniWrite(g_radarShowEnemyBoss    ? "1" : "0",  f, "Radar",         "showBoss")
    IniWrite(g_radarShowMinions      ? "1" : "0",  f, "Radar",         "showMinions")
    IniWrite(g_radarShowNpcs         ? "1" : "0",  f, "Radar",         "showNpcs")
    IniWrite(g_radarShowChests       ? "1" : "0",  f, "Radar",         "showChests")
    IniWrite(g_zoneNavEnabled        ? "1" : "0",  f, "Radar",         "zoneNav")
    IniWrite(g_mapHackEnabled        ? "1" : "0",  f, "Radar",         "mapHack")
    IniWrite(g_panelDetectionEnabled ? "1" : "0",  f, "PanelDetection", "enabled")
    IniWrite(g_entityShowPlayer      ? "1" : "0",  f, "EntityFilters", "showPlayer")
    IniWrite(g_entityShowMinion      ? "1" : "0",  f, "EntityFilters", "showMinion")
    IniWrite(g_entityShowEnemy       ? "1" : "0",  f, "EntityFilters", "showEnemy")
    IniWrite(g_entityShowNPC         ? "1" : "0",  f, "EntityFilters", "showNPC")
    IniWrite(g_entityShowChest       ? "1" : "0",  f, "EntityFilters", "showChest")
    IniWrite(g_entityShowWorldItem   ? "1" : "0",  f, "EntityFilters", "showWorldItem")
    IniWrite(g_entityShowOther       ? "1" : "0",  f, "EntityFilters", "showOther")

    ; Blacklist: pipe-separated (names may contain commas)
    blStr := ""
    for i, name in g_skillBuffBlacklist
    {
        if (i > 1)
            blStr .= "|"
        blStr .= name
    }
    IniWrite(blStr, f, "SkillBuffBlacklist", "names")

    IniWrite(g_cfgOpenSections, f, "ConfigUI", "openSections")

    ; Window geometry (always the normal/restored rect, not the maximized rect)
    IniWrite(g_winX,                               f, "Window",        "x")
    IniWrite(g_winY,                               f, "Window",        "y")
    IniWrite(g_winW,                               f, "Window",        "w")
    IniWrite(g_winH,                               f, "Window",        "h")
    IniWrite(g_winMaximized      ? "1" : "0",      f, "Window",        "maximized")

    ; Panel offsets: save discovered offsets with patch version for cache invalidation
    SavePanelOffsetsToConfig()
}

; Reads all settings from the INI file into globals. Keeps defaults if file missing.
LoadConfig()
{
    global g_debugMode, g_autoFlaskEnabled, g_autoFlaskPerformanceMode
    global g_lifeThresholdPercent, g_manaThresholdPercent, g_radarEnabled, g_radarAlpha
    global g_playerHudEnabled
    global g_updatesPaused, g_npcWatchAutoSync
    global g_radarShowEnemyNormal, g_radarShowEnemyRare, g_radarShowEnemyBoss
    global g_radarShowMinions, g_radarShowNpcs, g_radarShowChests
    global g_entityShowPlayer, g_entityShowMinion, g_entityShowEnemy
    global g_entityShowNPC, g_entityShowChest, g_entityShowWorldItem, g_entityShowOther
    global g_skillBuffBlacklist, g_zoneNavEnabled, g_mapHackEnabled
    global g_panelDetectionEnabled
    global g_cfgOpenSections
    global g_winX, g_winY, g_winW, g_winH, g_winMaximized

    f := _ConfigPath()
    if !FileExist(f)
        return  ; no file yet — keep defaults

    ; Helper closures for reading INI values
    _Ini(sec, key, defVal) => IniRead(f, sec, key, defVal)
    _B(sec, key, defVal) => (_Ini(sec, key, defVal ? "1" : "0") = "1")

    g_debugMode                := _B("General",       "debugMode",       false)
    g_updatesPaused            := _B("General",       "updatesPaused",   false)
    g_npcWatchAutoSync         := _B("General",       "npcWatchAutoSync",false)
    g_lifeThresholdPercent     := Integer(_Ini("General",   "lifeThreshold",   55))
    g_manaThresholdPercent     := Integer(_Ini("General",   "manaThreshold",   35))
    g_autoFlaskEnabled         := _B("AutoFlask",     "enabled",         false)
    g_autoFlaskPerformanceMode := _B("AutoFlask",     "performanceMode", false)
    g_radarEnabled             := _B("Radar",         "enabled",         true)
    g_playerHudEnabled         := _B("Radar",         "playerHud",       true)
    g_radarAlpha               := Max(0, Min(255, Integer(_Ini("Radar", "alpha", 255))))
    g_radarShowEnemyNormal     := _B("Radar",         "showNormal",      true)
    g_radarShowEnemyRare       := _B("Radar",         "showRare",        true)
    g_radarShowEnemyBoss       := _B("Radar",         "showBoss",        true)
    g_radarShowMinions         := _B("Radar",         "showMinions",     true)
    g_radarShowNpcs            := _B("Radar",         "showNpcs",        true)
    g_radarShowChests          := _B("Radar",         "showChests",      true)
    g_zoneNavEnabled           := _B("Radar",         "zoneNav",         true)
    g_mapHackEnabled           := _B("Radar",         "mapHack",         true)
    g_panelDetectionEnabled    := _B("PanelDetection","enabled",         true)
    g_entityShowPlayer         := _B("EntityFilters", "showPlayer",      true)
    g_entityShowMinion         := _B("EntityFilters", "showMinion",      true)
    g_entityShowEnemy          := _B("EntityFilters", "showEnemy",       true)
    g_entityShowNPC            := _B("EntityFilters", "showNPC",         true)
    g_entityShowChest          := _B("EntityFilters", "showChest",       true)
    g_entityShowWorldItem      := _B("EntityFilters", "showWorldItem",   true)
    g_entityShowOther          := _B("EntityFilters", "showOther",       true)

    ; Blacklist: pipe-separated list
    blStr := _Ini("SkillBuffBlacklist", "names", "")
    g_skillBuffBlacklist := []
    if (blStr != "")
    {
        loop parse, blStr, "|"
        {
            if (A_LoopField != "")
                g_skillBuffBlacklist.Push(A_LoopField)
        }
    }

    g_cfgOpenSections := _Ini("ConfigUI", "openSections", "status,overview,toggles,autoflask,radar,entities,actions")

    ; Window geometry
    g_winX         := Integer(_Ini("Window", "x", 20))
    g_winY         := Integer(_Ini("Window", "y", 20))
    g_winW         := Max(400, Integer(_Ini("Window", "w", 1080)))
    g_winH         := Max(300, Integer(_Ini("Window", "h", 850)))
    g_winMaximized := _B("Window", "maximized", false)

    ; Load cached panel offsets (if patch version matches)
    LoadPanelOffsetsFromConfig()

    ; Clamp position so the window isn't completely off-screen
    g_winX := Max(-g_winW + 100, g_winX)
    g_winY := Max(-g_winH + 100, g_winY)
}

; Captures the normal (restored) window rect from the OS, even when maximized.
_CaptureWindowGeometry()
{
    global g_webGui, g_winX, g_winY, g_winW, g_winH, g_winMaximized
    if !g_webGui || !g_webGui.Hwnd
        return
    state := WinGetMinMax("ahk_id " g_webGui.Hwnd)
    if (state = -1)
        return  ; minimized — don't overwrite saved geometry
    g_winMaximized := (state = 1)
    ; GetWindowPlacement gives the normal (restored) rect regardless of state
    wp := Buffer(44, 0)
    NumPut("UInt", 44, wp, 0)
    DllCall("GetWindowPlacement", "Ptr", g_webGui.Hwnd, "Ptr", wp)
    g_winX := NumGet(wp, 28, "Int")
    g_winY := NumGet(wp, 32, "Int")
    g_winW := NumGet(wp, 36, "Int") - g_winX
    g_winH := NumGet(wp, 40, "Int") - g_winY
}

; Saves discovered panel offsets to INI with the current patch version.
; Format: [PanelOffsets] patchVersion=X.X.X, PanelName=0xNNN, ...
; Struct offsets (relative to GameUiPtr) are stable within a patch version.
SavePanelOffsetsToConfig()
{
    f := _ConfigPath()
    offsets := PoE2Offsets.DiscoveredPanelOffsets

    ; Read current patch version from file
    patchFile := A_ScriptDir "\last_known_patch.txt"
    patchVer := ""
    if FileExist(patchFile)
    {
        try
        {
            patchVer := Trim(FileRead(patchFile), " `t`r`n")
        }
        catch
        {
            patchVer := ""
        }
    }
    IniWrite(patchVer, f, "PanelOffsets", "patchVersion")

    ; Clear old entries first — delete and recreate section
    ; Write count so we know how many to load
    count := 0
    for name, off in offsets
        count += 1
    IniWrite(count, f, "PanelOffsets", "count")

    idx := 0
    for name, off in offsets
    {
        IniWrite(name, f, "PanelOffsets", "name" idx)
        IniWrite(Format("0x{:X}", off), f, "PanelOffsets", "offset" idx)
        idx += 1
    }
}

; Loads cached panel offsets from INI. Only loads if patch version matches.
; Returns true if offsets were loaded, false if stale/missing.
LoadPanelOffsetsFromConfig()
{
    f := _ConfigPath()
    if !FileExist(f)
        return false

    ; Check patch version
    patchFile := A_ScriptDir "\last_known_patch.txt"
    currentPatch := ""
    if FileExist(patchFile)
    {
        try
        {
            currentPatch := Trim(FileRead(patchFile), " `t`r`n")
        }
        catch
        {
            currentPatch := ""
        }
    }
    savedPatch := IniRead(f, "PanelOffsets", "patchVersion", "")
    if (savedPatch = "" || savedPatch != currentPatch)
        return false

    ; parseNum removed — inline parsing used in-place below

    offsets := Map()

    ; Try reading count first. If count missing or <=0, fall back to scanning sequential nameN keys.
    count := Integer(IniRead(f, "PanelOffsets", "count", "0"))
    if (count > 0)
    {
        idx := 0
        while (idx < count)
        {
            name := IniRead(f, "PanelOffsets", "name" idx, "")
            offStr := IniRead(f, "PanelOffsets", "offset" idx, "")
            if (name != "" && offStr != "")
            {
                ; parse offStr -> offVal (supports 0xHEX and decimal)
                offVal := 0
                s := Trim(offStr)
                if (s != "")
                {
                    if RegExMatch(s, "i)^\s*0x([0-9A-Fa-f]+)\s*$", m)
                    {
                        hex := StrUpper(m1)
                        offVal := 0
                        i2 := 1
                        len2 := StrLen(hex)
                        while (i2 <= len2)
                        {
                            c := SubStr(hex, i2, 1)
                            asc := Asc(c)
                            if (asc >= 48 && asc <= 57)
                                d := asc - 48
                            else if (asc >= 65 && asc <= 70)
                                d := asc - 55
                            else
                                d := 0
                            offVal := offVal * 16 + d
                            i2 += 1
                        }
                    }
                    else
                    {
                        try
                    {
                        offVal := Integer(s)
                    }
                    catch
                    {
                        offVal := 0
                    }
                    }
                }
                if (offVal > 0)
                    offsets[name] := offVal
            }
            idx += 1
        }
    }
    else
    {
        idx := 0
        while (idx < 128)
        {
            name := IniRead(f, "PanelOffsets", "name" idx, "")
            offStr := IniRead(f, "PanelOffsets", "offset" idx, "")
            if (name = "" && offStr = "")
                break
            if (name != "" && offStr != "")
            {
                ; parse offStr -> offVal (supports 0xHEX and decimal)
                offVal := 0
                s := Trim(offStr)
                if (s != "")
                {
                    if RegExMatch(s, "i)^\s*0x([0-9A-Fa-f]+)\s*$", m)
                    {
                        hex := StrUpper(m1)
                        offVal := 0
                        i2 := 1
                        len2 := StrLen(hex)
                        while (i2 <= len2)
                        {
                            c := SubStr(hex, i2, 1)
                            asc := Asc(c)
                            if (asc >= 48 && asc <= 57)
                                d := asc - 48
                            else if (asc >= 65 && asc <= 70)
                                d := asc - 55
                            else
                                d := 0
                            offVal := offVal * 16 + d
                            i2 += 1
                        }
                    }
                    else
                    {
                        try
                    {
                        offVal := Integer(s)
                    }
                    catch
                    {
                        offVal := 0
                    }
                    }
                }
                if (offVal > 0)
                    offsets[name] := offVal
            }
            idx += 1
        }
    }

    if (offsets.Count > 0)
    {
        PoE2Offsets.DiscoveredPanelOffsets := offsets
        ; Push to WebView if it's ready so UI shows saved panels immediately
        try
        {
            _PushSavedPanelOffsets()
        }
        catch
        {
            ; ignore
        }
        return true
    }

    return false
}

