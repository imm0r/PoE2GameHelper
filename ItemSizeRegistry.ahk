; ItemSizeRegistry.ahk
; Loads inventory dimensions (width × height) for every PoE2 base item from
; the pre-built TSV at data/base_item_sizes.tsv.
;
; Two sources are supported:
;   * **Legacy 3-col format** (id\twidth\theight) — produced from
;     https://repoe-fork.github.io/poe2/base_items.json by a one-shot
;     preprocessing step. Used to be the only source.
;   * **Native 4-col format** (id\tname\twidth\theight) — produced by our
;     own `ggpk-tools/PoeDataExtract` reading the user's local PoE2 install
;     directly. Refreshable from inside the helper via the Config tab.
;
; Lookup is case-insensitive — both the TSV keys and the lookup path are
; lowercased at parse / query time. Ground-item entity paths usually match
; the base-type key exactly; for the rare cases that don't, the caller
; falls back to the rarity-based heuristic in LootPickup.
;
; Example rows of either format:
;   metadata/items/currency/currencyweaponquality<TAB>1<TAB>1                                  (3-col)
;   Metadata/Items/Currency/CurrencyWeaponQuality<TAB>Blacksmith's Whetstone<TAB>1<TAB>1       (4-col)
;
; Included by InGameStateMonitor.ahk; call ItemSizeRegistry.Load() once after
; load-config + reader-construction so the data is in memory before the first
; AutoPilot tick fires.

class ItemSizeRegistry
{
    ; metadata-path-lowercase → Map("w", N, "h", N)
    static Sizes := Map()
    static Loaded := false
    static LoadStats := Map("entries", 0, "skipped", 0, "fileSize", 0)

    static Load()
    {
        if this.Loaded
            return

        path := A_ScriptDir "\data\base_item_sizes.tsv"
        if !FileExist(path)
        {
            this.Loaded := true
            try LogError("ItemSizeRegistry: TSV missing at " path " — fit-check will use rarity heuristic")
            return
        }

        try
        {
            this.LoadStats["fileSize"] := FileGetSize(path)
            entries := 0
            skipped := 0
            f := FileOpen(path, "r-d", "UTF-8")
            if !f
            {
                this.Loaded := true
                return
            }
            firstLine := true
            while !f.AtEOF
            {
                line := f.ReadLine()
                if (line = "")
                    continue
                ; Strip trailing CR/LF from FileOpen line iteration on Windows
                line := RTrim(line, "`r`n")
                parts := StrSplit(line, "`t")
                if (parts.Length < 3)
                {
                    skipped += 1
                    continue
                }
                ; Auto-detect column layout from the parts count:
                ;   3 cols → id, w, h            (legacy repoe-fork dump)
                ;   4 cols → id, name, w, h      (our PoeDataExtract output)
                ; Width/height are always the last two columns.
                key := parts[1]
                w   := Integer(parts[parts.Length - 1])
                h   := Integer(parts[parts.Length])
                ; First non-empty line of the new 4-col format is a
                ; header row ("id\tname\twidth\theight") — skip it.
                if (firstLine && StrLower(parts[1]) = "id"
                    && (parts.Length >= 4 ? StrLower(parts[2]) = "name" : true))
                {
                    firstLine := false
                    continue
                }
                firstLine := false
                if (w <= 0 || w > 16 || h <= 0 || h > 16)
                {
                    skipped += 1
                    continue
                }
                ; Lowercase the key at parse time so Get() doesn't have
                ; to do it on every call AND so 4-col output (mixed-case
                ; "Metadata/Items/...") interops with 3-col data
                ; (already lowercase).
                this.Sizes[StrLower(key)] := Map("w", w, "h", h)
                entries += 1
            }
            f.Close()
            this.LoadStats["entries"] := entries
            this.LoadStats["skipped"] := skipped
            try LogError("ItemSizeRegistry: loaded " entries " entries (skipped " skipped ")")
        }
        catch as ex
        {
            try LogError("ItemSizeRegistry/load", ex)
        }

        this.Loaded := true
    }

    ; Look up a ground item's inventory footprint by its full metadata path.
    ; Returns Map(w, h) on a hit, or 0 on miss / unloaded registry. The caller
    ; should fall back to a rarity-based heuristic when this returns 0.
    static Get(metadataPath)
    {
        if !this.Loaded
            this.Load()
        if (metadataPath = "")
            return 0
        ; Keys are already lowercased at parse time (see Load()) so this
        ; is just normalising the query side.
        key := StrLower(metadataPath)
        if this.Sizes.Has(key)
            return this.Sizes[key]
        ; Some PoE2 ground items append numeric variant suffixes to the base
        ; metadata path (e.g. "…/CurrencyOrb" → "…/CurrencyOrb2"). Drop a
        ; trailing digit run and try again before giving up — this catches the
        ; common "variant" pattern without exploding into a million regexes.
        trimmed := RegExReplace(key, "\d+$", "")
        if (trimmed != key && this.Sizes.Has(trimmed))
            return this.Sizes[trimmed]
        return 0
    }
}
