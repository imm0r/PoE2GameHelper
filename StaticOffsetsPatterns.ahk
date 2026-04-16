#Requires AutoHotkey v2.0

class PoE2StaticOffsetsPatterns
{
    ; Returns an array of named byte-pattern Maps used by FindStaticAddresses().
    ; Each Map has "name" and "pattern" keys; "^" in the pattern marks the RIP-relative operand offset.
    static GetAll()
    {
        return [
            Map("name", "Game States", "pattern", "48 39 2D ^ ?? ?? ?? ?? 0F 85 16 01 00 00"),
            Map("name", "File Root", "pattern", "48 8B 0D ^ ?? ?? ?? ?? E8 ?? ?? ?? ?? E8"),
            Map("name", "AreaChangeCounter", "pattern", "FF 05 ^ ?? ?? ?? ?? 4C 8B 06"),
            Map("name", "Terrain Rotator Helper", "pattern", "48 8D 05 ^ ?? ?? ?? ?? 4F 8D 04 40"),
            Map("name", "Terrain Rotation Selector", "pattern", "48 8D 0D ^ ?? ?? ?? ?? 44 0F B6 04 08"),
            Map("name", "GameCullSize", "pattern", "2B 05 ^ ?? ?? ?? ?? 45 0F 57 C9")
        ]
    }

    ; Returns a Map of pattern names that are non-critical during FindStaticAddresses() scanning.
    ; Patterns listed here will not set critical failure flags if they are missing or ambiguous.
    static GetOptionalNames()
    {
        return Map(
            "NoAtlasFog", true,
            "RevealMap", true,
            "InfiniteZoom", true,
            "ToggleHiddenIcon", true,
            "PlayerLight", true,
            "EnemyHealthBars", true,
            "MiniMapZoom", true
        )
    }
}
