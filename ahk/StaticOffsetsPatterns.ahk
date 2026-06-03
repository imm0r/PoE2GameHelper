#Requires AutoHotkey v2.0

class PoE2StaticOffsetsPatterns
{
    ; Returns an array of named byte-pattern Maps used by FindStaticAddresses().
    ; Each Map has "name" and "pattern" keys; "^" in the pattern marks the RIP-relative operand offset.
    static GetAll()
    {
        return [
            Map("name", "Game States", "pattern", "48 39 2D ^ ?? ?? ?? ?? 0F 85 ?? ?? ?? ?? B9 40 01 00 00"),
            Map("name", "File Root", "pattern", "48 8D 0D ?? ?? ?? ?? E8 ?? ?? ?? ?? 48 8B 05 ^ ?? ?? ?? ?? 48 83 C4 28"),
            Map("name", "AreaChangeCounter", "pattern", "FF 05 ^ ?? ?? ?? ?? 4D 8B 06"),
            ; Terrain Rotator Helper resolves the larger terrain-rotation array.
            Map("name", "Terrain Rotator Helper", "pattern", "48 83 EC 38 41 0F B6 C0 4C 8B D1 4C 8B CA 48 8D 0D ?? ?? ?? ?? 44 0F B6 04 08 B8 08 00 00 00 8B 0A 44 3B C0 89 4C 24 24 BA 16 00 00 00 44 0F 47 C0 48 8D 05 ^ ?? ?? ?? ??"),
            ; Terrain Rotation Selector resolves the rotation lookup table (e.g. 00 03 02 01 04 05 06 07 08).
            Map("name", "Terrain Rotation Selector", "pattern", "48 83 EC 38 41 0F B6 C0 4C 8B D1 4C 8B CA 48 8D 0D ^ ?? ?? ?? ??"),
            Map("name", "GameCullSize", "pattern", "2B 0D ?? ?? ?? ?? 8B 05 ?? ?? ?? ?? 2B 05 ^ ?? ?? ?? ?? 0F 57 FF")
        ]
    }

    ; Returns a Map of pattern names that are non-critical during FindStaticAddresses() scanning.
    ; Patterns listed here will not set critical failure flags if they are missing or ambiguous.
    ;
    ; Currently empty: all six scan patterns in GetStaticPatterns() are critical
    ; anchors (the GameHelper source confirms exactly those six). The previous
    ; entries (NoAtlasFog / RevealMap / InfiniteZoom / ToggleHiddenIcon /
    ; PlayerLight / EnemyHealthBars / MiniMapZoom) were client graphics tweaks
    ; with no corresponding pattern here — dead placeholders — and were removed.
    static GetOptionalNames()
    {
        return Map()
    }
}
