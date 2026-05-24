; ItemSizeRegistry.ahk
; Loads inventory dimensions (width × height) for every PoE2 base item from
; the pre-built TSV at data/base_item_sizes.tsv. The source data comes from
; https://repoe-fork.github.io/poe2/base_items.json — we strip it down to
; just the three columns we need at preprocessing time so AHK doesn't have
; to JSON-parse 5.8 MB at startup.
;
; Lookup is case-insensitive — both the TSV keys and the lookup path are
; lowercased. Ground-item entity paths usually match the base-type key
; exactly; for the rare cases that don't, the caller falls back to the
; rarity-based heuristic in LootPickup.
;
; Format of base_item_sizes.tsv:
;   metadata/items/currency/currencyweaponquality<TAB>1<TAB>1
;   metadata/items/armours/bodyarmours/bodydexint5<TAB>2<TAB>3
;   …
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
                key := parts[1]
                w   := Integer(parts[2])
                h   := Integer(parts[3])
                if (w <= 0 || w > 16 || h <= 0 || h > 16)
                {
                    skipped += 1
                    continue
                }
                this.Sizes[key] := Map("w", w, "h", h)
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
