; EntityAlerts.ahk
; Per-tick entity alert engine. Runs off the radar snapshot (every ~100ms) right after
; AutoPilot, OUTSIDE the "claim the tick" chain, so it never blocks automation. It scans
; awake entities, classifies each (type + rarity + group + path), and fires a single
; consolidated alert (banner / sound / window flash / radar highlight / log) for the
; highest-severity match. Reuses _ClassifyEntityType (SnapshotSerializers), ReadEntityRarityId
; (EntityFacts) and ResolveEntityGroupNameByPath (EntityGroups). Self-persists to alerts.ini.
; Included via TreeViewWatchlistPanel.ahk.

; ── Configuration (super-globals; mutated via _ApplyAlertSetting / config load) ──
global g_alertsEnabled          := false
global g_alertOnRare            := false
global g_alertOnUnique          := true
global g_alertCatBoss           := true
global g_alertCatStrongbox      := true
global g_alertCatShrine         := false
global g_alertCatNpc            := false
global g_alertCatChest          := false
global g_alertCatAreaTransition := false
global g_alertPathWatch         := ""        ; comma-separated path substrings
global g_alertGroups            := ""        ; comma-separated group names (see Groups tab)
global g_alertMaxDistance       := 0         ; 0 = no distance gate (units)
global g_alertZoneEntry         := true      ; fire once per area, per entity
global g_alertProximity         := false     ; repeat while in range, cooldown-gated
global g_alertCooldownMs        := 4000
global g_alertBanner            := true
global g_alertSound             := false
global g_alertSoundMode         := "beep"    ; "beep" | "file"
global g_alertSoundFile         := ""
global g_alertBannerMs          := 2500
global g_alertHighlight         := false     ; set g_highlightedEntityPath to the trigger
global g_alertFlash             := false     ; flash the tool window in the taskbar
global g_alertLog               := false     ; append to logs\gamehelper_alerts.log

; INI file owned by this module (self-persist pattern, like LootPickup).
global g_alertsConfigFile := A_ScriptDir "\alerts.ini"

; ── Tick entry point ────────────────────────────────────────────────────────
; Reentrancy-guarded wrapper called from UpdateRadarFast after TryAutoPilot. Never throws.
TryEntityAlerts(radarSnap)
{
    static _running := false
    if _running
        return
    _running := true
    try
        _RunEntityAlerts(radarSnap)
    catch as ex
        try LogError("TryEntityAlerts", ex)
    finally
        _running := false
}

; Core scan. Gates on the master toggle, suppresses town/hideout, resets per-area state on
; zone change (via currentAreaHash), then collects matches and fires one consolidated alert.
_RunEntityAlerts(radarSnap)
{
    global g_alertsEnabled, g_alertMaxDistance, g_alertZoneEntry, g_alertProximity, g_alertCooldownMs
    static _area := 0
    static _alertedAddrs := Map()
    static _lastTick := Map()

    if !g_alertsEnabled
        return
    if !(radarSnap && Type(radarSnap) = "Map")
        return

    inGs := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
    area := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    if !(area && IsObject(area))
        return

    ; Suppress alerts in safe zones (town / hideout).
    wad := radarSnap.Has("worldAreaDat") ? radarSnap["worldAreaDat"] : 0
    if (wad && IsObject(wad) && ((wad.Has("isTown") && wad["isTown"]) || (wad.Has("isHideout") && wad["isHideout"])))
        return

    ; Per-area reset: a new currentAreaHash means a new instance -> clear fire-once state.
    areaHash := area.Has("currentAreaHash") ? area["currentAreaHash"] : 0
    if (areaHash != _area)
    {
        _area := areaHash
        _alertedAddrs := Map()
        _lastTick := Map()
    }

    awake := area.Has("awakeEntities") ? area["awakeEntities"] : 0
    sample := (awake && IsObject(awake) && awake.Has("sample")) ? awake["sample"] : 0
    if !(sample && Type(sample) = "Array")
        return

    now := A_TickCount
    best := 0, bestSev := -1, triggerCount := 0

    for _, entry in sample
    {
        if !(entry && Type(entry) = "Map" && entry.Has("entity"))
            continue
        entity := entry["entity"]
        if !(entity && Type(entity) = "Map")
            continue
        path := entity.Has("path") ? entity["path"] : ""
        if (path = "")
            continue

        dist := entry.Has("distance") ? entry["distance"] : -1
        if (g_alertMaxDistance > 0 && dist >= 0 && dist > g_alertMaxDistance)
            continue

        decoded := (entity.Has("decodedComponents") && entity["decodedComponents"] && Type(entity["decodedComponents"]) = "Map")
            ? entity["decodedComponents"] : Map()

        sev := _AlertSeverityFor(path, decoded)
        if (sev < 0)
            continue

        addr := entity.Has("address") ? entity["address"] : 0
        fire := false
        if (g_alertZoneEntry && !_alertedAddrs.Has(addr))
            fire := true
        else if (g_alertProximity && (!_lastTick.Has(addr) || (now - _lastTick[addr]) > g_alertCooldownMs))
            fire := true
        if !fire
            continue

        _alertedAddrs[addr] := true
        _lastTick[addr] := now
        triggerCount += 1
        if (sev > bestSev)
        {
            bestSev := sev
            best := Map("path", path, "label", _AlertLabelFor(path, decoded, sev), "dist", dist)
        }
    }

    if (best != 0)
        _FireAlert(best, triggerCount)
}

; Returns a severity score (higher = more important) for an entity, or -1 if it matches no
; enabled condition. Order encodes priority for the consolidated banner.
_AlertSeverityFor(path, decoded)
{
    global g_alertOnUnique, g_alertOnRare, g_alertCatBoss, g_alertCatStrongbox
    global g_alertCatShrine, g_alertCatNpc, g_alertCatChest, g_alertCatAreaTransition
    global g_alertPathWatch, g_alertGroups

    p := StrLower(path)
    type := _ClassifyEntityType(path)
    rar := ReadEntityRarityId(decoded)

    if (g_alertOnUnique && (rar >= 3 || type = "Boss"))
        return 100
    if (g_alertCatStrongbox && InStr(p, "strongbox"))
        return 80
    if (g_alertOnRare && rar = 2)
        return 70
    if (g_alertCatShrine && InStr(p, "shrine"))
        return 60
    if (g_alertGroups != "" && _AlertGroupMatch(path))
        return 55
    if (g_alertPathWatch != "" && _AlertPathWatchMatch(p))
        return 50
    if (g_alertCatBoss && type = "Boss")
        return 45
    if (g_alertCatChest && type = "Chest")
        return 35
    if (g_alertCatNpc && type = "NPC")
        return 30
    if (g_alertCatAreaTransition && type = "AreaTransition")
        return 20
    return -1
}

; True if the entity's resolved group name appears in the comma-separated g_alertGroups list.
_AlertGroupMatch(path)
{
    global g_alertGroups
    name := StrLower(Trim(ResolveEntityGroupNameByPath(path)))
    if (name = "")
        return false
    for _, term in StrSplit(g_alertGroups, ",")
    {
        t := StrLower(Trim(term))
        if (t != "" && t = name)
            return true
    }
    return false
}

; True if any comma-separated term of g_alertPathWatch is a substring of the (lowercased) path.
_AlertPathWatchMatch(pLower)
{
    global g_alertPathWatch
    for _, term in StrSplit(g_alertPathWatch, ",")
    {
        t := StrLower(Trim(term))
        if (t != "" && InStr(pLower, t))
            return true
    }
    return false
}

; Short human label for the banner, derived from the matched severity / type / group.
_AlertLabelFor(path, decoded, sev)
{
    switch sev
    {
        case 100: return "Unique"
        case 80:  return "Strongbox"
        case 70:  return "Rare"
        case 60:  return "Shrine"
        case 55:  return ResolveEntityGroupNameByPath(path)
        case 45:  return "Boss"
        case 35:  return "Chest"
        case 30:  return "NPC"
        case 20:  return "Area transition"
    }
    ; pathWatch (50) or any fallthrough: show the last path segment.
    parts := StrSplit(path, "/")
    return parts.Length ? parts[parts.Length] : path
}

; Fires the enabled modalities once for the top trigger. Sound/flash are non-blocking so the
; 100ms radar loop is never stalled.
_FireAlert(best, count)
{
    global g_alertBanner, g_alertBannerMs, g_alertSound, g_alertHighlight, g_alertFlash, g_alertLog
    global g_highlightedEntityPath, g_webGui, g_notifyOverlay

    text := best["label"]
    if (best["dist"] >= 0)
        text .= " (" Round(best["dist"]) "m)"
    if (count > 1)
        text .= "   +" (count - 1) " more"

    ; Banner is drawn by the independent notification overlay (own GDI layer, exact game-window
    ; position, click-through, shown even when the radar/map overlay is hidden). Lazy-created.
    if (g_alertBanner)
    {
        if !IsObject(g_notifyOverlay)
            g_notifyOverlay := NotificationOverlay()
        try g_notifyOverlay.SetBanner(text, g_alertBannerMs)
    }
    if (g_alertSound)
        _AlertPlaySound()
    if (g_alertHighlight && best["path"] != "")
        g_highlightedEntityPath := best["path"]
    if (g_alertFlash && IsObject(g_webGui) && g_webGui.HasProp("Hwnd") && g_webGui.Hwnd)
        _AlertFlashWindow(g_webGui.Hwnd)
    if (g_alertLog)
        _AlertLogLine(text, best["path"])
}

; Plays the configured alert sound asynchronously (SoundPlay returns immediately without "Wait").
_AlertPlaySound()
{
    global g_alertSoundMode, g_alertSoundFile
    try
    {
        if (g_alertSoundMode = "file" && g_alertSoundFile != "")
        {
            f := A_ScriptDir "\wav\" g_alertSoundFile
            if FileExist(f)
            {
                SoundPlay(f)
                return
            }
        }
        SoundPlay("*-1")   ; system asterisk (fallback / beep mode)
    }
}

; Flashes the given window in the taskbar via FlashWindowEx (FLASHW_ALL, 3 flashes).
_AlertFlashWindow(hwnd)
{
    fi := Buffer(32, 0)
    NumPut("UInt", 32, fi, 0)      ; cbSize
    NumPut("Ptr", hwnd, fi, 8)     ; hwnd (8-byte aligned on x64)
    NumPut("UInt", 3, fi, 16)      ; dwFlags = FLASHW_ALL
    NumPut("UInt", 3, fi, 20)      ; uCount
    NumPut("UInt", 0, fi, 24)      ; dwTimeout (0 = default blink rate)
    try DllCall("FlashWindowEx", "Ptr", fi)
}

; Appends a timestamped alert line to logs\gamehelper_alerts.log (created on demand).
_AlertLogLine(text, path)
{
    try
    {
        dir := A_ScriptDir "\logs"
        if !DirExist(dir)
            DirCreate(dir)
        FileAppend(FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") " | " text " | " path "`n", dir "\gamehelper_alerts.log", "UTF-8")
    }
}

; ── Bridge apply / persistence / header ──────────────────────────────────────
; Applies one setting from the UI (key + value). Toggles coerce truthy; numbers/strings as-is.
_ApplyAlertSetting(key, value)
{
    global g_alertsEnabled, g_alertOnRare, g_alertOnUnique, g_alertCatBoss, g_alertCatStrongbox
    global g_alertCatShrine, g_alertCatNpc, g_alertCatChest, g_alertCatAreaTransition
    global g_alertPathWatch, g_alertGroups, g_alertMaxDistance, g_alertZoneEntry, g_alertProximity
    global g_alertCooldownMs, g_alertBanner, g_alertSound, g_alertSoundMode, g_alertSoundFile
    global g_alertBannerMs, g_alertHighlight, g_alertFlash, g_alertLog

    b := (value = true || value = 1 || value = "1" || value = "true")
    switch key
    {
        case "enabled":           g_alertsEnabled := b
        case "onRare":            g_alertOnRare := b
        case "onUnique":          g_alertOnUnique := b
        case "catBoss":           g_alertCatBoss := b
        case "catStrongbox":      g_alertCatStrongbox := b
        case "catShrine":         g_alertCatShrine := b
        case "catNpc":            g_alertCatNpc := b
        case "catChest":          g_alertCatChest := b
        case "catAreaTransition": g_alertCatAreaTransition := b
        case "zoneEntry":         g_alertZoneEntry := b
        case "proximity":         g_alertProximity := b
        case "banner":            g_alertBanner := b
        case "sound":             g_alertSound := b
        case "flash":             g_alertFlash := b
        case "highlight":         g_alertHighlight := b
        case "log":               g_alertLog := b
        case "pathWatch":         g_alertPathWatch := "" value
        case "groups":            g_alertGroups := "" value
        case "soundMode":         g_alertSoundMode := (value = "file") ? "file" : "beep"
        case "soundFile":         g_alertSoundFile := "" value
        case "maxDistance":       g_alertMaxDistance := Round(value + 0)
        case "cooldownMs":        g_alertCooldownMs := Round(value + 0)
        case "bannerMs":          g_alertBannerMs := Round(value + 0)
    }
}

; Persists the full alert config to alerts.ini ([Alerts] section).
SaveEntityAlertsConfig()
{
    global g_alertsConfigFile, g_alertsEnabled, g_alertOnRare, g_alertOnUnique, g_alertCatBoss
    global g_alertCatStrongbox, g_alertCatShrine, g_alertCatNpc, g_alertCatChest, g_alertCatAreaTransition
    global g_alertPathWatch, g_alertGroups, g_alertMaxDistance, g_alertZoneEntry, g_alertProximity
    global g_alertCooldownMs, g_alertBanner, g_alertSound, g_alertSoundMode, g_alertSoundFile
    global g_alertBannerMs, g_alertHighlight, g_alertFlash, g_alertLog

    f := g_alertsConfigFile
    try
    {
        IniWrite(g_alertsEnabled ? 1 : 0,          f, "Alerts", "enabled")
        IniWrite(g_alertOnRare ? 1 : 0,            f, "Alerts", "onRare")
        IniWrite(g_alertOnUnique ? 1 : 0,          f, "Alerts", "onUnique")
        IniWrite(g_alertCatBoss ? 1 : 0,           f, "Alerts", "catBoss")
        IniWrite(g_alertCatStrongbox ? 1 : 0,      f, "Alerts", "catStrongbox")
        IniWrite(g_alertCatShrine ? 1 : 0,         f, "Alerts", "catShrine")
        IniWrite(g_alertCatNpc ? 1 : 0,            f, "Alerts", "catNpc")
        IniWrite(g_alertCatChest ? 1 : 0,          f, "Alerts", "catChest")
        IniWrite(g_alertCatAreaTransition ? 1 : 0, f, "Alerts", "catAreaTransition")
        IniWrite(g_alertZoneEntry ? 1 : 0,         f, "Alerts", "zoneEntry")
        IniWrite(g_alertProximity ? 1 : 0,         f, "Alerts", "proximity")
        IniWrite(g_alertBanner ? 1 : 0,            f, "Alerts", "banner")
        IniWrite(g_alertSound ? 1 : 0,             f, "Alerts", "sound")
        IniWrite(g_alertFlash ? 1 : 0,             f, "Alerts", "flash")
        IniWrite(g_alertHighlight ? 1 : 0,         f, "Alerts", "highlight")
        IniWrite(g_alertLog ? 1 : 0,               f, "Alerts", "log")
        IniWrite(g_alertMaxDistance,               f, "Alerts", "maxDistance")
        IniWrite(g_alertCooldownMs,                f, "Alerts", "cooldownMs")
        IniWrite(g_alertBannerMs,                  f, "Alerts", "bannerMs")
        IniWrite(g_alertSoundMode,                 f, "Alerts", "soundMode")
        ; Strings that may be empty are stored verbatim.
        IniWrite(g_alertPathWatch,                 f, "Alerts", "pathWatch")
        IniWrite(g_alertGroups,                    f, "Alerts", "groups")
        IniWrite(g_alertSoundFile,                 f, "Alerts", "soundFile")
    }
}

; Loads the alert config from alerts.ini, falling back to the in-code defaults per key.
LoadEntityAlertsConfig()
{
    global g_alertsConfigFile, g_alertsEnabled, g_alertOnRare, g_alertOnUnique, g_alertCatBoss
    global g_alertCatStrongbox, g_alertCatShrine, g_alertCatNpc, g_alertCatChest, g_alertCatAreaTransition
    global g_alertPathWatch, g_alertGroups, g_alertMaxDistance, g_alertZoneEntry, g_alertProximity
    global g_alertCooldownMs, g_alertBanner, g_alertSound, g_alertSoundMode, g_alertSoundFile
    global g_alertBannerMs, g_alertHighlight, g_alertFlash, g_alertLog

    ; Seed defaults unconditionally. This file is #Include'd after the main script's
    ; auto-execute return, so its top-level initializers never run; without this the
    ; globals stay unassigned whenever alerts.ini is missing (fresh install).
    g_alertsConfigFile      := A_ScriptDir "\alerts.ini"
    g_alertsEnabled         := false
    g_alertOnRare           := false
    g_alertOnUnique         := true
    g_alertCatBoss          := true
    g_alertCatStrongbox     := true
    g_alertCatShrine        := false
    g_alertCatNpc           := false
    g_alertCatChest         := false
    g_alertCatAreaTransition := false
    g_alertPathWatch        := ""
    g_alertGroups           := ""
    g_alertMaxDistance      := 0
    g_alertZoneEntry        := true
    g_alertProximity        := false
    g_alertCooldownMs       := 4000
    g_alertBanner           := true
    g_alertSound            := false
    g_alertSoundMode        := "beep"
    g_alertSoundFile        := ""
    g_alertBannerMs         := 2500
    g_alertHighlight        := false
    g_alertFlash            := false
    g_alertLog              := false

    f := g_alertsConfigFile
    if !FileExist(f)
        return
    try
    {
        g_alertsEnabled          := IniRead(f, "Alerts", "enabled",          g_alertsEnabled ? 1 : 0) + 0 ? true : false
        g_alertOnRare            := IniRead(f, "Alerts", "onRare",            g_alertOnRare ? 1 : 0) + 0 ? true : false
        g_alertOnUnique          := IniRead(f, "Alerts", "onUnique",          g_alertOnUnique ? 1 : 0) + 0 ? true : false
        g_alertCatBoss           := IniRead(f, "Alerts", "catBoss",           g_alertCatBoss ? 1 : 0) + 0 ? true : false
        g_alertCatStrongbox      := IniRead(f, "Alerts", "catStrongbox",      g_alertCatStrongbox ? 1 : 0) + 0 ? true : false
        g_alertCatShrine         := IniRead(f, "Alerts", "catShrine",         g_alertCatShrine ? 1 : 0) + 0 ? true : false
        g_alertCatNpc            := IniRead(f, "Alerts", "catNpc",            g_alertCatNpc ? 1 : 0) + 0 ? true : false
        g_alertCatChest          := IniRead(f, "Alerts", "catChest",          g_alertCatChest ? 1 : 0) + 0 ? true : false
        g_alertCatAreaTransition := IniRead(f, "Alerts", "catAreaTransition", g_alertCatAreaTransition ? 1 : 0) + 0 ? true : false
        g_alertZoneEntry         := IniRead(f, "Alerts", "zoneEntry",         g_alertZoneEntry ? 1 : 0) + 0 ? true : false
        g_alertProximity         := IniRead(f, "Alerts", "proximity",         g_alertProximity ? 1 : 0) + 0 ? true : false
        g_alertBanner            := IniRead(f, "Alerts", "banner",            g_alertBanner ? 1 : 0) + 0 ? true : false
        g_alertSound             := IniRead(f, "Alerts", "sound",             g_alertSound ? 1 : 0) + 0 ? true : false
        g_alertFlash             := IniRead(f, "Alerts", "flash",             g_alertFlash ? 1 : 0) + 0 ? true : false
        g_alertHighlight         := IniRead(f, "Alerts", "highlight",         g_alertHighlight ? 1 : 0) + 0 ? true : false
        g_alertLog               := IniRead(f, "Alerts", "log",               g_alertLog ? 1 : 0) + 0 ? true : false
        g_alertMaxDistance       := IniRead(f, "Alerts", "maxDistance",       g_alertMaxDistance) + 0
        g_alertCooldownMs        := IniRead(f, "Alerts", "cooldownMs",        g_alertCooldownMs) + 0
        g_alertBannerMs          := IniRead(f, "Alerts", "bannerMs",          g_alertBannerMs) + 0
        g_alertSoundMode         := IniRead(f, "Alerts", "soundMode",         g_alertSoundMode)
        g_alertPathWatch         := IniRead(f, "Alerts", "pathWatch",         g_alertPathWatch)
        g_alertGroups            := IniRead(f, "Alerts", "groups",            g_alertGroups)
        g_alertSoundFile         := IniRead(f, "Alerts", "soundFile",         g_alertSoundFile)
    }
}

; Returns a JSON array of *.wav file names found in the root \wav\ folder (for the UI dropdown).
_AlertWavFilesJson()
{
    dir := A_ScriptDir "\wav"
    j := "["
    if DirExist(dir)
    {
        first := true
        Loop Files, dir "\*.wav"
        {
            j .= (first ? "" : ",") _JsStr(A_LoopFileName)
            first := false
        }
    }
    return j "]"
}

; Builds the "alerts" object for the WebView header push (consumed by the Alerts tab).
BuildAlertsHeaderJson()
{
    global g_alertsEnabled, g_alertOnRare, g_alertOnUnique, g_alertCatBoss, g_alertCatStrongbox
    global g_alertCatShrine, g_alertCatNpc, g_alertCatChest, g_alertCatAreaTransition
    global g_alertPathWatch, g_alertGroups, g_alertMaxDistance, g_alertZoneEntry, g_alertProximity
    global g_alertCooldownMs, g_alertBanner, g_alertSound, g_alertSoundMode, g_alertSoundFile
    global g_alertBannerMs, g_alertHighlight, g_alertFlash, g_alertLog

    j := "{"
    j .= '"enabled":'          (g_alertsEnabled ? "true" : "false")
    j .= ',"onRare":'          (g_alertOnRare ? "true" : "false")
    j .= ',"onUnique":'        (g_alertOnUnique ? "true" : "false")
    j .= ',"catBoss":'         (g_alertCatBoss ? "true" : "false")
    j .= ',"catStrongbox":'    (g_alertCatStrongbox ? "true" : "false")
    j .= ',"catShrine":'       (g_alertCatShrine ? "true" : "false")
    j .= ',"catNpc":'          (g_alertCatNpc ? "true" : "false")
    j .= ',"catChest":'        (g_alertCatChest ? "true" : "false")
    j .= ',"catAreaTransition":' (g_alertCatAreaTransition ? "true" : "false")
    j .= ',"zoneEntry":'       (g_alertZoneEntry ? "true" : "false")
    j .= ',"proximity":'       (g_alertProximity ? "true" : "false")
    j .= ',"banner":'          (g_alertBanner ? "true" : "false")
    j .= ',"sound":'           (g_alertSound ? "true" : "false")
    j .= ',"flash":'           (g_alertFlash ? "true" : "false")
    j .= ',"highlight":'       (g_alertHighlight ? "true" : "false")
    j .= ',"log":'             (g_alertLog ? "true" : "false")
    j .= ',"maxDistance":'     (g_alertMaxDistance + 0)
    j .= ',"cooldownMs":'      (g_alertCooldownMs + 0)
    j .= ',"bannerMs":'        (g_alertBannerMs + 0)
    j .= ',"soundMode":'       _JsStr(g_alertSoundMode)
    j .= ',"soundFile":'       _JsStr(g_alertSoundFile)
    j .= ',"pathWatch":'       _JsStr(g_alertPathWatch)
    j .= ',"groups":'          _JsStr(g_alertGroups)
    j .= ',"wavFiles":'        _AlertWavFilesJson()
    j .= "}"
    return j
}
