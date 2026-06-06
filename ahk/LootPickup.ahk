; LootPickup.ahk
; Ground-item auto-pickup. Sits between combat and exploration inside AutoPilot:
;   priority — combat > loot > explore
;
; Detection:
;   - scans awakeEntities for WorldItem-paths (path contains "worlditem" or
;     "metadata/items/")
;   - reads decodedComponents.rarityId to classify the item
;   - filters by user-toggled rarity flags (Normal/Magic/Rare/Unique/Currency).
;     "Relic" (id=4) is grouped under "Unique"; "Currency" is id=5
;
; Cache:
;   - keyed by entity address (canonical for an item's lifetime)
;   - each tick, items in the current sample refresh lastSeenTick;
;     entries not seen for STALE_MS get evicted
;   - this is what lets the bot walk back and collect items that were
;     filtered through during combat but became safe later
;
; Pickup action:
;   - target = nearest cached item by terrain-aware distance (falls back to
;     Euclidean when terrain unavailable)
;   - cursor moved to the projected screen position; AvoidZones consulted to
;     skip clicks that would land on HUD / transitions / NPCs
;   - LMB click — the game's own pickup logic walks the character to the
;     item and auto-loots when in range. We throttle to ~400 ms per click so
;     we don't spam clicks while the character is already walking
;
; Engagement gate:
;   - AutoPilot already checks for hostiles via combat first; if combat
;     engages, loot doesn't run that tick. We additionally short-circuit on
;     any hostile inside g_combatRange so a stray non-engaged mob doesn't
;     bait us into a click that ends up walking us into the mob
;
; Globals declared in InGameStateMonitor.ahk:
;   g_lootRarityNormal/Magic/Rare/Unique/Currency — Bool filter flags
;   g_lootCache                                  — Map(entityAddr -> Map)
;   g_lootLastReason                             — short status string

; ── Public entry point ───────────────────────────────────────────────────
; Called from AutoPilot._RunAutoPilot between combat and exploration.
; Returns true if a pickup action was issued this tick (block exploration).
TryLootPickup(radarSnap, gameHwnd)
{
    static _running := false
    if _running
        return false
    _running := true
    try
        return _RunLootPickup(radarSnap, gameHwnd)
    catch as ex
    {
        LogError("TryLootPickup", ex)
        return false
    }
    finally
        _running := false
}

_RunLootPickup(radarSnap, gameHwnd)
{
    global g_lootCache, g_lootLastReason, g_reader
    global g_lootRarityNormal, g_lootRarityMagic, g_lootRarityRare
    global g_lootRarityUnique, g_lootRarityCurrency
    global g_combatRange

    ; Persistent state for picked-up detection and click throttling. Static
    ; locals survive across ticks so we can correlate a click against the
    ; next few snapshots.
    static _lastClickTick    := 0
    static _lastClickedAddr  := 0
    static _lastClickedRarity := ""

    ; Short-circuit if every filter is off — no work to do.
    if !(g_lootRarityNormal || g_lootRarityMagic || g_lootRarityRare
        || g_lootRarityUnique || g_lootRarityCurrency)
    {
        g_lootLastReason := "filter-empty"
        return false
    }

    ; Hostile-proximity gate: even though AutoPilot already runs combat
    ; before us, a stray non-engaged hostile (e.g. one juuust outside
    ; engage range that's still wandering near a fresh drop) should still
    ; postpone pickup. We use the same combat range threshold for symmetry.
    nearestHostileDist := _NearestHostileDistance(radarSnap)
    if (nearestHostileDist < g_combatRange)
    {
        g_lootLastReason := "hostile-nearby(d=" Round(nearestHostileDist) ")"
        ; Even though we won't click, we DO want to keep updating the cache
        ; so items dropped during a fight aren't forgotten. Fall through to
        ; the refresh, but don't issue any action.
        _RefreshLootCache(radarSnap)
        return false
    }

    ; Refresh the cache (also expires stale entries) — does this before
    ; the picked-up check so lastSeenTick reflects the just-arrived snapshot.
    seenStats := _RefreshLootCache(radarSnap)

    ; ── Picked-up detection ─────────────────────────────────────────────
    ; If we issued a click recently and the targeted entity no longer
    ; refreshes in the snapshot, the game picked it up. Drop the cache
    ; entry immediately so we don't keep clicking the same world position.
    if (_lastClickedAddr && g_lootCache.Has(_lastClickedAddr))
    {
        cached := g_lootCache[_lastClickedAddr]
        timeSinceClick    := A_TickCount - _lastClickTick
        timeSinceLastSeen := A_TickCount - cached["lastSeenTick"]
        ; "Clicked recently" (within 5 s) + "not seen for 1.5 s" → assume
        ; pickup completed. The 1.5 s buffer covers snapshot-timing jitter
        ; where one tick might skip an entity that's actually still there.
        if (timeSinceClick < 5000 && timeSinceLastSeen > 1500)
        {
            g_lootCache.Delete(_lastClickedAddr)
            g_lootLastReason := "picked-up(" cached["rarity"] ")"
            _lastClickedAddr := 0
            _lastClickedRarity := ""
            return true   ; claim the tick; next pass picks the next item
        }
    }
    ; Also: clear the click memory after enough time has passed that we
    ; can't reliably correlate (5 s window).
    if (_lastClickedAddr && (A_TickCount - _lastClickTick) > 5000)
    {
        _lastClickedAddr := 0
        _lastClickedRarity := ""
    }

    if (g_lootCache.Count = 0)
    {
        ; Surface what we saw in the snapshot — helps diagnose "cache stays 0"
        ; (e.g. WorldItems present but all filtered out, or filter passes but
        ; no Render decoded yet). Without this all you see is "cache-empty".
        g_lootLastReason := "cache-empty (saw " seenStats["worldItems"]
            . " items, " seenStats["filterPassed"] " passed filter, "
            . seenStats["noRender"] " missing render)"
        return false
    }

    ; ── Free-inventory-space gate ───────────────────────────────────────
    ; Reading inventory is expensive; cached for ~3 s. Returns -1 when the
    ; data isn't readable (no game state yet) — treat that as "don't block".
    ; This call also builds the occupancy grid that the fit-check below uses.
    free := _GetBackpackFreeCells(radarSnap)
    if (free = 0)
    {
        global g_lootInvDiag
        ; Include the raw read so a wrong "inventory-full" can be diagnosed
        ; instead of being mysterious (e.g. wrong inventoryId, glitched item
        ; slot values, …).
        g_lootLastReason := "inventory-full [" g_lootInvDiag "] (" g_lootCache.Count " cached)"
        return true   ; cache stays — once user empties slots, pickup resumes
    }

    playerPos := _GetPlayerPos(radarSnap)
    if !playerPos
    {
        g_lootLastReason := "no-player-pos"
        return false
    }

    target := _NearestCachedItem(g_lootCache, playerPos["x"], playerPos["y"])
    if !target
    {
        g_lootLastReason := "no-target"
        return false
    }

    ; ── Per-item fit-check ──────────────────────────────────────────────
    ; Even when there are free cells, a 2×3 body armor needs a contiguous
    ; 2×3 region — scattered 1×1 holes don't count. Footprint comes from
    ; ItemSizeRegistry (path → real w/h from base_items.json); if a path
    ; doesn't match the registry (rare variants), we fall back to a
    ; rarity-based heuristic. Items that don't fit stay cached so a later
    ; inventory shuffle / pickup can clear a spot.
    rw := (target.Has("w") && target["w"] > 0) ? target["w"] : 0
    rh := (target.Has("h") && target["h"] > 0) ? target["h"] : 0
    fpSrc := "reg"
    if (rw <= 0 || rh <= 0)
    {
        fp := _EstimateItemFootprint(target["rarity"])
        rw := fp["w"]
        rh := fp["h"]
        fpSrc := "rar"   ; rarity fallback (registry miss)
    }
    if !_CanFitInBackpack(rw, rh)
    {
        g_lootLastReason := "no-fit(" target["rarity"]
            . " need=" rw "x" rh "/" fpSrc
            . " free=" free " " g_lootCache.Count "cached)"
        return true   ; engaged — block exploration, retry next tick
    }

    ; Project the item's world position to screen; check AvoidZones.
    inGs   := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
    w2sMat := (inGs && IsObject(inGs) && inGs.Has("w2sMatrix")) ? inGs["w2sMatrix"] : 0
    if !(w2sMat && Type(w2sMat) = "Array" && w2sMat.Length = 16)
    {
        g_lootLastReason := "no-w2s-matrix"
        return false
    }

    sp := _LootWorldToScreen(target["worldX"], target["worldY"], target["worldZ"], w2sMat, gameHwnd)
    if !sp
    {
        g_lootLastReason := "no-screen-pos"
        return false
    }

    avoidRects := GetAvoidZones(radarSnap, gameHwnd)
    if IsPointInAvoidZone(sp["x"], sp["y"], avoidRects)
    {
        ; The item itself wouldn't normally be in an avoid zone, but the
        ; projected position might be — e.g. an item dropped right next to a
        ; waypoint pillar. Skip this tick; either we walk closer first and
        ; the projection geometry shifts, or the cache eventually expires.
        g_lootLastReason := "avoid-zone(" target["rarity"] ")"
        return true   ; block exploration anyway — still want to come back
    }

    ; Throttle: one click every ~400 ms. The game itself walks the character
    ; to the item once it sees the click; spamming clicks would just stop
    ; the walk over and over.
    now := A_TickCount
    if ((now - _lastClickTick) < 400)
    {
        g_lootLastReason := "walking(" target["rarity"] " d=" Round(target["dist"]) ")"
        return true   ; busy walking — block exploration
    }

    ; Aim + click.
    DllCall("SetCursorPos", "int", sp["x"], "int", sp["y"])
    Sleep(20)
    DllCall("mouse_event", "uint", 0x0002, "int", 0, "int", 0, "uint", 0, "uptr", 0) ; LDOWN
    Sleep(20)
    DllCall("mouse_event", "uint", 0x0004, "int", 0, "int", 0, "uint", 0, "uptr", 0) ; LUP
    _lastClickTick     := now
    _lastClickedAddr   := target["addr"]
    _lastClickedRarity := target["rarity"]

    ; Reading the inventory took some time during the just-fired click; force
    ; an early refresh by invalidating the cached value so the next tick
    ; (which may already see the new item) reflects the change without
    ; waiting the full 3 s window.
    _InvalidateInventoryCache()

    freeTag := (free < 0) ? "" : (" free=" free)
    sizeTag := (rw > 0 && rh > 0) ? (" " rw "x" rh "/" fpSrc) : ""
    g_lootLastReason := "pickup(" target["rarity"] sizeTag " d=" Round(target["dist"])
        . " " (g_lootCache.Count) "cached" freeTag ")"
    return true
}

; ── Cache refresh ────────────────────────────────────────────────────────
; For each entity in the current sample:
;   - if it's a WorldItem matching the rarity filter, add or update in cache
;     with current world position and lastSeenTick.
; Stale entries (not seen for STALE_MS) are dropped — that's how we detect
; items that the player or someone else has picked up.
_RefreshLootCache(radarSnap)
{
    global g_lootCache
    global g_lootRarityNormal, g_lootRarityMagic, g_lootRarityRare
    global g_lootRarityUnique, g_lootRarityCurrency

    STALE_MS := 60000   ; drop items not seen for 60 s

    now := A_TickCount

    ; Diagnostic counters returned so the caller can surface the reason
    ; "cache-empty" is happening (e.g. items in sample but all skipped).
    stats := Map("worldItems", 0, "filterPassed", 0, "noRender", 0, "added", 0)

    inGs   := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
    area   := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    awake  := (area && IsObject(area) && area.Has("awakeEntities")) ? area["awakeEntities"] : 0
    sample := (awake && IsObject(awake) && awake.Has("sample")) ? awake["sample"] : []
    if !(sample && Type(sample) = "Array")
    {
        _ExpireStaleEntries(g_lootCache, now, STALE_MS)
        return stats
    }

    for _, entry in sample
    {
        if !(entry && IsObject(entry))
            continue
        entity := entry.Has("entity") ? entry["entity"] : 0
        if !(entity && IsObject(entity))
            continue

        path := entity.Has("path") ? entity["path"] : ""
        if (path = "")
            continue
        if !_IsWorldItemPath(path)
            continue

        stats["worldItems"] := stats["worldItems"] + 1

        decoded := entity.Has("decodedComponents") ? entity["decodedComponents"] : 0
        if !(decoded && IsObject(decoded))
            continue

        ; Rarity decoding is round-robin in PoE2EntityReader — a freshly
        ; spotted item may not have rarityId set yet. Treat that case as
        ; Normal (id 0) instead of skipping the item; if the user has
        ; Normal disabled, the filter will exclude it on this tick AND on
        ; later ticks once a real rarityId is decoded, so the behaviour is
        ; conservative. The previous "rarity = '' → continue" path silently
        ; dropped every freshly-dropped item until a future decoder cycle.
        rarityId := decoded.Has("rarityId") ? decoded["rarityId"] : 0
        rarity := _RarityIdToFilterLabel(rarityId)
        if (rarity = "")
            rarity := "Normal"
        if !_IsRarityEnabled(rarity)
            continue

        stats["filterPassed"] := stats["filterPassed"] + 1

        render := decoded.Has("render") ? decoded["render"] : 0
        if !(render && IsObject(render) && render.Has("worldPosition"))
        {
            stats["noRender"] := stats["noRender"] + 1
            continue
        }
        wp := render["worldPosition"]
        wx := wp.Has("x") ? wp["x"] : 0
        wy := wp.Has("y") ? wp["y"] : 0
        wz := wp.Has("z") ? wp["z"] : 0
        if (wx = 0 && wy = 0)
            continue

        addr := entity.Has("address") ? entity["address"] : 0
        if !addr
            continue

        if g_lootCache.Has(addr)
        {
            cached := g_lootCache[addr]
            cached["worldX"] := wx
            cached["worldY"] := wy
            cached["worldZ"] := wz
            cached["rarity"] := rarity   ; refresh in case it was decoded between ticks
            cached["lastSeenTick"] := now
        }
        else
        {
            ; Resolve actual footprint from the base-item registry on first
            ; sighting. Stored in the cache entry so the per-tick fit check
            ; doesn't need to repeat the lookup. Missing entries get 0/0 here
            ; and fall back to the rarity heuristic at fit-check time.
            sz := ItemSizeRegistry.Get(path)
            sw := (sz && IsObject(sz)) ? sz["w"] : 0
            sh := (sz && IsObject(sz)) ? sz["h"] : 0
            g_lootCache[addr] := Map(
                "addr",         addr,
                "path",         path,
                "rarity",       rarity,
                "worldX",       wx,
                "worldY",       wy,
                "worldZ",       wz,
                "w",            sw,
                "h",            sh,
                "addedTick",    now,
                "lastSeenTick", now
            )
            stats["added"] := stats["added"] + 1
        }
    }

    _ExpireStaleEntries(g_lootCache, now, STALE_MS)
    return stats
}

; Drops cache entries whose lastSeenTick is older than `staleMs`.
_ExpireStaleEntries(cache, now, staleMs)
{
    toDrop := []
    for addr, info in cache
    {
        if !(info && IsObject(info))
        {
            toDrop.Push(addr)
            continue
        }
        if ((now - info["lastSeenTick"]) > staleMs)
            toDrop.Push(addr)
    }
    for _, addr in toDrop
        cache.Delete(addr)
}

; ── Helpers ──────────────────────────────────────────────────────────────

; Maps the numeric rarityId from the Mods/ObjectMagicProperties read into the
; filter-flag label the UI uses. Returns "" when the rarity isn't one we
; track (shouldn't happen — id 0-5 are all known).
_RarityIdToFilterLabel(rarityId)
{
    if (rarityId = 0)
        return "Normal"
    if (rarityId = 1)
        return "Magic"
    if (rarityId = 2)
        return "Rare"
    if (rarityId = 3 || rarityId = 4)   ; Relic shares the Unique filter bit
        return "Unique"
    if (rarityId = 5)
        return "Currency"
    return ""
}

; Reads the per-rarity filter flag for the given label.
_IsRarityEnabled(rarity)
{
    global g_lootRarityNormal, g_lootRarityMagic, g_lootRarityRare
    global g_lootRarityUnique, g_lootRarityCurrency
    switch rarity
    {
        case "Normal":   return g_lootRarityNormal
        case "Magic":    return g_lootRarityMagic
        case "Rare":     return g_lootRarityRare
        case "Unique":   return g_lootRarityUnique
        case "Currency": return g_lootRarityCurrency
    }
    return false
}

_IsWorldItemPath(path)
{
    p := StrLower(path)
    return InStr(p, "worlditem") || InStr(p, "metadata/items/")
}

; Returns Map("x", "y", "z") for the local player or 0 if unavailable.
_GetPlayerPos(radarSnap)
{
    inGs := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
    area := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    prc  := (area && IsObject(area) && area.Has("playerRenderComponent")) ? area["playerRenderComponent"] : 0
    if !(prc && IsObject(prc) && prc.Has("worldPosition"))
        return 0
    pwp := prc["worldPosition"]
    return Map(
        "x", pwp.Has("x") ? pwp["x"] : 0,
        "y", pwp.Has("y") ? pwp["y"] : 0,
        "z", pwp.Has("z") ? pwp["z"] : 0
    )
}

; Returns Euclidean distance to the nearest hostile in the radar sample, or
; a large number when none. Used as a "is it safe to loot now" check. Doesn't
; do terrain pathfinding — that's already happening in CombatAutomation, and
; the cost of an extra A* per tick is too high for what's effectively a
; rough proximity gate.
_NearestHostileDistance(radarSnap)
{
    global g_reader

    inGs := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
    area := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    awake := (area && IsObject(area) && area.Has("awakeEntities")) ? area["awakeEntities"] : 0
    sample := (awake && IsObject(awake) && awake.Has("sample")) ? awake["sample"] : []
    if !(sample && Type(sample) = "Array")
        return 999999.0

    nearest := 999999.0
    for _, entry in sample
    {
        if !(entry && IsObject(entry))
            continue
        entity := entry.Has("entity") ? entry["entity"] : 0
        if !(entity && IsObject(entity))
            continue
        path := entity.Has("path") ? entity["path"] : ""
        if (path = "")
            continue
        if !g_reader.IsNpcLikeEntityPath(path)
            continue
        decoded := entity.Has("decodedComponents") ? entity["decodedComponents"] : 0
        if !(decoded && IsObject(decoded))
            continue
        ; Must be targetable + not friendly (mirror combat's hostile-filter)
        tgt := decoded.Has("targetable") ? decoded["targetable"] : 0
        isTgt := false
        if IsObject(tgt)
            isTgt := (tgt.Has("isTargetable") && tgt["isTargetable"])
        else
            isTgt := tgt ? true : false
        if !isTgt
            continue
        pos := decoded.Has("positioned") ? decoded["positioned"] : 0
        if (pos && IsObject(pos) && pos.Has("isFriendly") && pos["isFriendly"])
            continue
        ; Skip dead via Life if available
        lifeComp := decoded.Has("life") ? decoded["life"] : 0
        if (lifeComp && IsObject(lifeComp) && lifeComp.Has("isAlive") && !lifeComp["isAlive"])
            continue

        d := entry.Has("distance") ? entry["distance"] : -1
        if (d > 0 && d < nearest)
            nearest := d
    }
    return nearest
}

; Picks the cached item with the smallest Euclidean distance to the player.
; Returns the cached Map with a "dist" key added, or 0 when the cache is
; empty. We use Euclidean here for the same reason _NearestHostileDistance
; does — the click-to-move follows the game's own pathing, so an extra A*
; from our side wouldn't change the outcome.
_NearestCachedItem(cache, playerX, playerY)
{
    bestDist := 999999.0
    best := 0
    for addr, info in cache
    {
        if !(info && IsObject(info))
            continue
        dx := info["worldX"] - playerX
        dy := info["worldY"] - playerY
        d := Sqrt(dx * dx + dy * dy)
        if (d < bestDist)
        {
            bestDist := d
            best := info
        }
    }
    if best
        best["dist"] := bestDist
    return best
}

; Local W2S — same matrix math as elsewhere; takes a window handle and
; returns absolute screen coordinates (or 0 if the perspective divide
; degenerates). Clamped to the client rect with a small margin so the
; cursor never gets parked over a window edge.
_LootWorldToScreen(wx, wy, wz, w2sMat, gameHwnd)
{
    clientRect := Buffer(16, 0)
    clientPt   := Buffer(8, 0)
    DllCall("GetClientRect",  "Ptr", gameHwnd, "Ptr", clientRect)
    DllCall("ClientToScreen", "Ptr", gameHwnd, "Ptr", clientPt)
    cX := NumGet(clientPt, 0, "Int"),    cY := NumGet(clientPt, 4, "Int")
    cW := NumGet(clientRect, 8, "Int"),  cH := NumGet(clientRect, 12, "Int")
    if (cW < 100 || cH < 100)
        return 0

    input := [wx, wy, wz, 1.0]
    r := [0.0, 0.0, 0.0, 0.0]
    Loop 4
    {
        i := A_Index
        Loop 4
        {
            j := A_Index
            r[i] := r[i] + w2sMat[(j - 1) * 4 + i] * input[j]
        }
    }
    if (Abs(r[4]) < 0.0001)
        return 0
    Loop 3
        r[A_Index] := r[A_Index] / r[4]

    sx := Round(cX + (r[1] + 1.0) * (cW / 2.0))
    sy := Round(cY + (1.0 - r[2]) * (cH / 2.0))
    margin := 60
    sx := Max(cX + margin, Min(sx, cX + cW - margin))
    sy := Max(cY + margin, Min(sy, cY + cH - margin))
    return Map("x", sx, "y", sy)
}

; ── Inventory free-space gate ───────────────────────────────────────────
; Returns the number of free cells in the player backpack (inventoryId == 1),
; or -1 if the data isn't available yet (game not connected, no snapshot, RPM
; failure). Callers treat -1 as "unknown — don't block pickup".
;
; Cached for INV_CACHE_MS (3 s) because ReadAllPlayerInventories does many
; RPM reads; doing it every loot tick would blow the per-tick budget. The
; cache can be invalidated by _InvalidateInventoryCache() after a pickup
; click so we re-check sooner than the natural window.
;
; Cache state lives in g_lootInv* globals (declared in InGameStateMonitor.ahk)
; instead of function statics so _InvalidateInventoryCache below can reset
; them across calls.
_GetBackpackFreeCells(radarSnap)
{
    global g_reader, g_lootInvFreeCells, g_lootInvLastCheckTick, g_lootInvForceRefresh
    INV_CACHE_MS := 3000

    now := A_TickCount
    if (!g_lootInvForceRefresh
        && g_lootInvFreeCells >= 0
        && (now - g_lootInvLastCheckTick) < INV_CACHE_MS)
        return g_lootInvFreeCells

    free := _ComputeBackpackFreeCells(radarSnap)
    if (free >= 0)
    {
        g_lootInvFreeCells     := free
        g_lootInvLastCheckTick := now
    }
    g_lootInvForceRefresh := false
    return free
}

; Force the next _GetBackpackFreeCells call to do a fresh read. Used right
; after a pickup click so the next tick reflects the inventory delta within
; ~400 ms (the click throttle window) instead of waiting 3 s.
_InvalidateInventoryCache()
{
    global g_lootInvForceRefresh
    g_lootInvForceRefresh := true
}

_ComputeBackpackFreeCells(radarSnap)
{
    global g_reader, g_lootInvDiag
    g_lootInvDiag := ""   ; reset diagnostic each call

    if !(IsObject(g_reader) && IsObject(g_reader.Mem) && g_reader.Mem.Handle)
    {
        g_lootInvDiag := "no-reader"
        return -1
    }

    inGs := radarSnap.Has("inGameState") ? radarSnap["inGameState"] : 0
    area := (inGs && IsObject(inGs) && inGs.Has("areaInstance")) ? inGs["areaInstance"] : 0
    if !(area && IsObject(area))
    {
        g_lootInvDiag := "no-area"
        return -1
    }
    areaAddr := area.Has("address") ? area["address"] : 0
    if !areaAddr
    {
        g_lootInvDiag := "no-area-addr"
        return -1
    }

    try
    {
        ; Same chain WebViewBridge.PushInventoryToWebView uses — copied here
        ; to avoid coupling the loot module to the WebView code path.
        playerInfoPtr    := areaAddr + PoE2Offsets.AreaInstance["PlayerInfo"]
        serverDataRawPtr := g_reader.Mem.ReadPtr(playerInfoPtr + PoE2Offsets.LocalPlayerStruct["ServerDataPtr"])
        sdPtr            := g_reader.ResolveServerDataPointer(playerInfoPtr, serverDataRawPtr)
        if !sdPtr
        {
            g_lootInvDiag := "no-sdptr"
            return -1
        }

        invs := g_reader.ReadAllPlayerInventories(sdPtr)
        if !(invs && Type(invs) = "Array")
        {
            g_lootInvDiag := "no-invs"
            return -1
        }

        ; Backpack is inventoryId == 1. Walk the array, return as soon as we
        ; find it. The other inventories (equipped, flasks, stash tabs)
        ; aren't relevant to ground-loot pickup.
        for _, inv in invs
        {
            if !(inv && IsObject(inv))
                continue
            if !inv.Has("inventoryId")
                continue
            if (inv["inventoryId"] != 1)
                continue

            totalX := inv.Has("totalBoxesX") ? inv["totalBoxesX"] : 0
            totalY := inv.Has("totalBoxesY") ? inv["totalBoxesY"] : 0
            if (totalX <= 0 || totalY <= 0)
            {
                g_lootInvDiag := "bad-grid(" totalX "x" totalY ")"
                return -1
            }
            totalCells := totalX * totalY

            items := inv.Has("items") ? inv["items"] : []
            ; PoE2's InventoryItemList stores ONE entry PER OCCUPIED CELL —
            ; a 2×3 body armor produces 6 entries, all pointing to the same
            ; item entity and reporting the same slotStart/End rectangle.
            ; The existing UI gets away with rendering all entries because
            ; identical rects overlap perfectly on screen.
            ; For free-cell math we must dedupe — count each unique item's
            ; footprint exactly once. Key by itemEntityPtr; fall back to a
            ; slot-rect signature when ptr is missing.
            ;
            ; We also build an occupancy grid here (one bit per cell) so
            ; the fit-check below can verify a target item's actual
            ; footprint fits in some contiguous free region, not just that
            ; enough cells exist scattered around.
            grid := []
            Loop totalY
            {
                row := []
                Loop totalX
                    row.Push(0)
                grid.Push(row)
            }

            seen := Map()
            uniqueItems := 0
            rawEntries  := 0
            if (items && Type(items) = "Array")
            {
                for _, item in items
                {
                    if !(item && IsObject(item))
                        continue
                    rawEntries += 1
                    sx := item.Has("slotStartX") ? item["slotStartX"] : 0
                    sy := item.Has("slotStartY") ? item["slotStartY"] : 0
                    ex := item.Has("slotEndX")   ? item["slotEndX"]   : sx
                    ey := item.Has("slotEndY")   ? item["slotEndY"]   : sy
                    ; Reject obviously bogus slot values that would otherwise
                    ; eat all available cells. Backpack slots are 0..bxX-1 /
                    ; 0..boxY-1; any item that claims to span the entire grid
                    ; or has negative coords is a memory-read glitch.
                    if (sx < 0 || sy < 0 || ex < sx || ey < sy
                        || ex >= totalX || ey >= totalY)
                        continue
                    w := ex - sx + 1
                    h := ey - sy + 1
                    if (w <= 0 || h <= 0 || w > totalX || h > totalY)
                        continue

                    ; Dedup key: prefer the item entity pointer (canonical),
                    ; fall back to slot-rect signature if missing.
                    ptr := item.Has("itemEntityPtr") ? item["itemEntityPtr"] : 0
                    key := ptr ? ("p:" ptr) : ("r:" sx "," sy "," ex "," ey)
                    if seen.Has(key)
                        continue
                    seen[key] := true

                    ; Stamp the occupancy grid for every cell this item
                    ; covers. Duplicates are harmless because the dedup
                    ; above only runs the stamp once per unique item.
                    yy := sy
                    while (yy <= ey)
                    {
                        xx := sx
                        while (xx <= ex)
                        {
                            grid[yy + 1][xx + 1] := 1
                            xx += 1
                        }
                        yy += 1
                    }

                    uniqueItems += 1
                }
            }

            ; Count free cells from the grid (single source of truth — keeps
            ; the count + grid in agreement even when items have weird
            ; overlaps).
            free := 0
            yy := 0
            while (yy < totalY)
            {
                xx := 0
                while (xx < totalX)
                {
                    if !grid[yy + 1][xx + 1]
                        free += 1
                    xx += 1
                }
                yy += 1
            }

            ; Publish grid + dimensions for _CanFitInBackpack.
            global g_lootInvGrid, g_lootInvGridX, g_lootInvGridY
            g_lootInvGrid  := grid
            g_lootInvGridX := totalX
            g_lootInvGridY := totalY

            ; Largest free rectangle (max area) — surfaced in diag for
            ; visibility and for the future "show me what fits" UI.
            maxRect := _FindLargestFreeRect(grid, totalX, totalY)
            g_lootInvDiag := "id=1 " totalX "x" totalY "=" totalCells
                . " entries=" rawEntries " unique=" uniqueItems
                . " free=" free
                . " maxRect=" maxRect["w"] "x" maxRect["h"]
            return free
        }
        g_lootInvDiag := "no-id1 (" invs.Length " invs total)"
        return -1
    }
    catch as ex
    {
        msg := ex.HasOwnProp("Message") ? ex.Message : "?"
        g_lootInvDiag := "exception: " msg
        return -1
    }
}

; ── Fit-check against the cached backpack grid ───────────────────────────
; Returns true iff there's a contiguous free reqW × reqH region somewhere
; in the backpack. Brute-force scans every possible top-left corner — O(W*H*reqW*reqH)
; which is trivial for a 12 × 5 grid (60 cells).
;
; A null/empty grid (inventory not yet read) returns true ("unknown — don't
; block pickup") to match the policy used by _GetBackpackFreeCells.
_CanFitInBackpack(reqW, reqH)
{
    global g_lootInvGrid, g_lootInvGridX, g_lootInvGridY

    if !g_lootInvGrid
        return true   ; grid not built yet — be optimistic
    if (reqW <= 0 || reqH <= 0)
        return true   ; degenerate request — assume yes
    if (reqW > g_lootInvGridX || reqH > g_lootInvGridY)
        return false  ; required size exceeds the entire grid

    maxY := g_lootInvGridY - reqH
    maxX := g_lootInvGridX - reqW
    sy := 0
    while (sy <= maxY)
    {
        sx := 0
        while (sx <= maxX)
        {
            if _IsRectFree(g_lootInvGrid, sx, sy, reqW, reqH)
                return true
            sx += 1
        }
        sy += 1
    }
    return false
}

_IsRectFree(grid, sx, sy, w, h)
{
    yy := sy
    yyEnd := sy + h
    while (yy < yyEnd)
    {
        xx := sx
        xxEnd := sx + w
        while (xx < xxEnd)
        {
            if grid[yy + 1][xx + 1]
                return false
            xx += 1
        }
        yy += 1
    }
    return true
}

; Histogram-based largest-rectangle finder. Returns Map(w, h, area). Walks
; the grid row-by-row, maintaining a "heights" array (consecutive free cells
; above), then for each row solves the classic "largest rectangle in
; histogram" problem with a stack. O(W*H).
_FindLargestFreeRect(grid, totalX, totalY)
{
    bestW := 0, bestH := 0, bestArea := 0
    heights := []
    Loop totalX
        heights.Push(0)

    yy := 0
    while (yy < totalY)
    {
        ; Update heights for this row.
        xx := 0
        while (xx < totalX)
        {
            if grid[yy + 1][xx + 1]
                heights[xx + 1] := 0
            else
                heights[xx + 1] := heights[xx + 1] + 1
            xx += 1
        }

        ; Largest rectangle in histogram for this row.
        stack := []         ; indices (0-based)
        i := 0
        while (i <= totalX)
        {
            h := (i = totalX) ? 0 : heights[i + 1]
            while (stack.Length > 0 && heights[stack[stack.Length] + 1] > h)
            {
                topIdx := stack.Pop()
                topH := heights[topIdx + 1]
                width := (stack.Length = 0) ? i : (i - stack[stack.Length] - 1)
                area := topH * width
                if (area > bestArea)
                {
                    bestArea := area
                    bestW    := width
                    bestH    := topH
                }
            }
            stack.Push(i)
            i += 1
        }
        yy += 1
    }
    return Map("w", bestW, "h", bestH, "area", bestArea)
}

; Estimates the worst-case footprint of an item by rarity. Without
; per-item base-type reading (which would require dat-table traversal),
; we use a conservative default per rarity:
;   - Currency: 1×1 (orbs, scrolls, shards — all stackable singles)
;   - everything else: 2×2 (catches most rings/amulets/wands/helmets;
;     a 2×3 armor or 2×4 two-hander might still fit if there's room,
;     but if even a 2×2 can't fit we definitely shouldn't try)
;
; Returns Map(w, h).
_EstimateItemFootprint(rarity)
{
    if (rarity = "Currency")
        return Map("w", 1, "h", 1)
    return Map("w", 2, "h", 2)
}

; ── Config persistence ──────────────────────────────────────────────────
LoadLootPickupConfig()
{
    global g_lootRarityNormal, g_lootRarityMagic, g_lootRarityRare
    global g_lootRarityUnique, g_lootRarityCurrency

    iniFile := A_ScriptDir "\poeformance_config.ini"
    section := "LootPickup"

    ; Sensible defaults: all enabled except Normal (Normal items are usually
    ; vendor trash; users who want them can flip the flag).
    g_lootRarityNormal   := IniRead(iniFile, section, "Normal",   "0") = "1"
    g_lootRarityMagic    := IniRead(iniFile, section, "Magic",    "1") = "1"
    g_lootRarityRare     := IniRead(iniFile, section, "Rare",     "1") = "1"
    g_lootRarityUnique   := IniRead(iniFile, section, "Unique",   "1") = "1"
    g_lootRarityCurrency := IniRead(iniFile, section, "Currency", "1") = "1"
}

SaveLootPickupConfig()
{
    global g_lootRarityNormal, g_lootRarityMagic, g_lootRarityRare
    global g_lootRarityUnique, g_lootRarityCurrency

    iniFile := A_ScriptDir "\poeformance_config.ini"
    section := "LootPickup"

    IniWrite(g_lootRarityNormal   ? "1" : "0", iniFile, section, "Normal")
    IniWrite(g_lootRarityMagic    ? "1" : "0", iniFile, section, "Magic")
    IniWrite(g_lootRarityRare     ? "1" : "0", iniFile, section, "Rare")
    IniWrite(g_lootRarityUnique   ? "1" : "0", iniFile, section, "Unique")
    IniWrite(g_lootRarityCurrency ? "1" : "0", iniFile, section, "Currency")
}
