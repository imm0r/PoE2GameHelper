class PoE2Offsets
{
    static GameState := Map(
        "States", 0x48,
        "StateEntrySize", 0x10,
        "InGameStateIndex", 4,
        "CurrentStateVecLast", 0x10
    )

    static InGameState := Map(
        "AreaInstanceData", 0x290,
        "WorldData", 0x308,
        "UiRootStructPtr", 0x340
    )

    static UiRootStruct := Map(
        "UiRootPtr", 0x5B8,
        "GameUiPtr", 0xBE0,
        "GameUiControllerPtr", 0xBE8
    )

    static WorldData := Map(
        "WorldAreaDetailsPtr", 0x98,
        "WorldAreaDetailsRowPtr", 0xA0
    )

    static AreaInstance := Map(
        "CurrentAreaLevel", 0xC4,
        "CurrentAreaHash", 0x11C,
        "Environments", 0x970,
        "PlayerInfo", 0xA20,
        "AwakeEntities", 0xB68,
        "SleepingEntities", 0xB78,
        "TerrainMetadata", 0xD50   ; bylafko/gamehelper2 reference: TerrainStruct at AreaInstance+0xD50
    )

    ; Offsets within TerrainStruct (base = AreaInstance + 0xD50).
    ; Source: https://gitlab.com/bylafko/gamehelper2 -- AreaInstanceOffsets.cs
    ; Each byte encodes 2 grid cells: even-x -> lower nibble, odd-x -> upper nibble.
    ; A nibble value != 0 means the cell is walkable.
    static TerrainMetadata := Map(
        "TotalTilesX",      0x18,   ; int64 — number of tile columns
        "TotalTilesY",      0x20,   ; int64 — number of tile rows
        "TileDetailsPtr",   0x28,   ; StdVector<TileStructure> (each 0x38 bytes)
        "GridWalkableData", 0xD0,   ; StdVector<byte> -- absolute: AreaInstance+0xE20
        "BytesPerRow",      0x130   ; int32 -- absolute: AreaInstance+0xE80
    )

    ; TileStructure layout (0x38 bytes each, within TileDetailsPtr vector)
    static TileStruct := Map(
        "SubTileDetailsPtr", 0x00,
        "TgtFilePtr",        0x08,  ; pointer to TgtFileStruct
        "TileHeight",        0x30,  ; int16
        "TileIdX",           0x34,  ; byte
        "TileIdY",           0x35,  ; byte
        "RotationSelector",  0x36   ; byte
    )

    ; TgtFileStruct layout (pointed to by TileStruct.TgtFilePtr)
    static TgtFile := Map(
        "Vtable",   0x00,
        "TgtPath",  0x08           ; StdWString — the entity/tile path
    )

    static LocalPlayerStruct := Map(
        "ServerDataPtr", 0x00,
        "LocalPlayerPtr", 0x20
    )

    static StdMap := Map(
        "Head", 0x00,
        "Size", 0x08
    )

    static StdMapNode := Map(
        "Left", 0x00,
        "Parent", 0x08,
        "Right", 0x10,
        "IsNil", 0x19,
        "KeyId", 0x20,
        "ValueEntityPtr", 0x28
    )

    static Entity := Map(
        "EntityDetailsPtr", 0x08,
        "ComponentsVec", 0x10,
        "ComponentsVecLast", 0x18,
        "Id", 0x80,
        "Flags", 0x84
    )

    static EntityDetails := Map(
        "Path", 0x08,
        "ComponentLookupPtr", 0x28
    )

    static ComponentHeader := Map(
        "StaticPtr", 0x00,
        "EntityPtr", 0x08
    )

    static ComponentLookup := Map(
        "Bucket", 0x28
    )

    static StdBucket := Map(
        "Data", 0x00,
        "DataLast", 0x08,
        "Capacity", 0x20          ; StdVector(24b)@0x00 + unidentified pointer-sized field (8b)@0x18 → int Capacity@0x20. TODO: replace with the concrete field name/type when confirmed.
    )

    static StdVector := Map(
        "First", 0x00,
        "Last", 0x08
    )

    static StatPair := Map(
        "Key", 0x00,
        "Value", 0x04
    )

    static Targetable := Map(
        "IsTargetable", 0x51,
        "IsHighlightable", 0x52,
        "IsTargetedByPlayer", 0x53,
        "MeetsQuestState", 0x56,
        "NeedsTrue", 0x58,
        "HiddenFromPlayer", 0x59,
        "NeedsFalse", 0x5A
    )

    static Render := Map(
        "CurrentWorldPosition", 0x138,
        "CurrentWorldPositionY", 0x13C,
        "CurrentWorldPositionZ", 0x140,
        "CharacterModelBounds", 0x144,
        "CharacterModelBoundsY", 0x148,
        "CharacterModelBoundsZ", 0x14C,
        "TerrainHeight", 0x1B0
    )

    static Chest := Map(
        "ChestDataPtr", 0x160,
        "IsOpened", 0x168
    )

    static ChestData := Map(
        "IsLabelVisible", 0x21,
        "StrongboxDatPtr", 0x50
    )

    static Shrine := Map(
        "IsUsed", 0x24
    )

    static Positioned := Map(
        "Reaction", 0x1E0
    )

    static Transitionable := Map(
        "CurrentState", 0x120
    )

    static StateMachine := Map(
        "StatesPtr", 0x158,         ; ptr → read +0x10 for names array base
        "StatesValues", 0x160,
        "StatesValuesLast", 0x168,
        "StateNamesBaseOffset", 0x10,   ; offset within StatesPtr to the actual names array
        "StateNameStructSize", 0xC0     ; sizeof each StdString entry in the names array
    )

    static Actor := Map(
        "AnimationId", 0x8A0,
        "ActiveSkills", 0xB00,
        "ActiveSkillsLast", 0xB08,
        "Cooldowns", 0xB18,
        "CooldownsLast", 0xB20,
        "DeployedEntities", 0xC10,
        "DeployedEntitiesLast", 0xC18
    )

    static ActiveSkillStructure := Map(
        "ActiveSkillPtr", 0x00
    )

    static ActiveSkillDetails := Map(
        "UseStage", 0x08,
        "CastType", 0x0C,
        "UnknownIdAndEquipmentInfo", 0x10,
        "GrantedEffectsPerLevelDatRow", 0x18,
        "GrantedEffectStatSetsPerLevelDatRow", 0x30,
        "TotalUses", 0x98,
        "TotalCooldownTimeInMs", 0xA8
    )

    ; GrantedEffectsPerLevel DAT row — first field is a pointer to the GrantedEffects DAT row
    static GrantedEffectsPerLevelDat := Map(
        "GrantedEffectDatPtr", 0x00
    )

    ; GrantedEffects DAT row — ActiveSkill foreignrow at 0x6F (row_ptr=0x6F, dat_name=0x77)
    static GrantedEffectsDat := Map(
        "ActiveSkillRowPtr", 0x6F
    )

    ; ActiveSkills DAT row — DisplayedName at 0x08 is the human-readable skill name
    static ActiveSkillsDat := Map(
        "Id", 0x00,
        "DisplayedName", 0x08,
        "IconDDSFile", 0x28
    )

    static ActiveSkillCooldown := Map(
        "ActiveSkillsDatId", 0x08,
        "CooldownsList", 0x10,
        "MaxUses", 0x30,
        "TotalCooldownTimeInMs", 0x34,
        "UnknownIdAndEquipmentInfo", 0x3C
    )

    static DeployedEntity := Map(
        "EntityId", 0x00,
        "ActiveSkillsDatId", 0x04,
        "DeployedObjectType", 0x08,
        "Counter", 0x10
    )

    static Animated := Map(
        "AnimatedEntityPtr", 0x280
    )

    static Buffs := Map(
        "StatusEffectPtr", 0x160,
        "StatusEffectPtrLast", 0x168,
        "StatusEffectStructSize", 0x50
    )

    static StatusEffect := Map(
        "BuffDefinationPtr", 0x08,
        "TotalTime", 0x18,
        "TimeLeft", 0x1C,
        "SourceEntityId", 0x28,
        "Charges", 0x40,
        "FlaskSlot", 0x42,
        "Effectiveness", 0x48,
        "UnknownIdAndEquipmentInfo", 0x4A
    )

    static BuffDefinition := Map(
        "Name", 0x00,
        "BuffVisualsKey", 0x55,
        "BuffType", 0x67
    )

    static BuffVisuals := Map(
        "Id", 0x00,
        "BuffDDSFile", 0x08
    )

    static Stats := Map(
        "StatsByItems", 0x160,
        "CurrentWeaponIndex", 0x168,
        "ShapeshiftPtr", 0x170,
        "StatsByBuffAndActions", 0x1C8,
        "StatsInternalStatsVector", 0xF8,
        "StatsInternalStatsVectorLast", 0x100
    )

    static Life := Map(
        "Health", 0x1A8,
        "Mana", 0x1F8,
        "EnergyShield", 0x230
    )

    static Vital := Map(
        "ReservedFlat", 0x10,
        "ReservedFraction", 0x14,
        "RegenPerMinuteStat", 0x1C,
        "Regen", 0x28,
        "Max", 0x2C,
        "Current", 0x30
    )

    static Charges := Map(
        "ChargesInternalPtr", 0x10,
        "Current", 0x18
    )

    static Stack := Map(
        "UnknownPtr", 0x10,
        "Count", 0x18
    )

    static ChargesInternal := Map(
        "PerUseCharges", 0x18
    )

    static Player := Map(
        "Name", 0x1B0,
        "Xp", 0x1D8,
        "Level", 0x204
    )

    static TriggerableBlockage := Map(
        "IsBlocked", 0x30
    )

    static Mods := Map(
        "Rarity", 0x94,
        "AllMods", 0xA0,
        "StatsFromMods", 0x148
    )

    static ObjectMagicProperties := Map(
        "Rarity", 0x144,
        "AllMods", 0x150,
        "StatsFromMods", 0x1F8
    )

    static ServerData := Map(
        "PlayerServerData", 0x48,
        "PlayerServerDataLast", 0x50
    )

    static ServerDataStructure := Map(
        "PlayerInventories", 0x320,
        "PlayerInventoriesLast", 0x328
    )

    static InventoryArray := Map(
        "EntrySize", 0x18,
        "InventoryId", 0x00,
        "InventoryPtr0", 0x08
    )

    static Inventory := Map(
        "TotalBoxes", 0x14C,
        "TotalBoxesY", 0x150,
        "ItemList", 0x170,
        "ItemListLast", 0x178,
        "ServerRequestCounter", 0x1E8
    )

    static InventoryItem := Map(
        "Item", 0x00,
        "SlotStart", 0x08,
        "SlotStartY", 0x0C,
        "SlotEnd", 0x10,
        "SlotEndY", 0x14
    )

    static ComponentLookupEntry := Map(
        "NamePtr", 0x00,
        "Index", 0x08,
        "Size", 0x10
    )

    static ModArray := Map(
        "Values", 0x00,     ; StdVector (0x18 bytes)
        "Value0", 0x18,     ; int (fallback if Values is empty)
        "ModsPtr", 0x28     ; IntPtr → Mods.dat row → ptr @ 0x00 → unicode name
        ; struct total size = 0x40 (UselessPtr2 @ 0x38 + 8 bytes)
    )

    static WorldAreaDat := Map(
        "IdPtr", 0x00,
        "NamePtr", 0x08,
        "Act", 0x10,
        "IsTown", 0x14,
        "HasWaypoint", 0x15
    )

    static StdWString := Map(
        "Buffer", 0x00,
        "ReservedBytes", 0x08,
        "Length", 0x10,
        "Capacity", 0x18
    )

    ; All offsets are relative to uiRootStructPtr (= ReadPtr(InGameState + 0x340))
    static ImportantUiElements := Map(
        "ChatParentPtr",              0x5C0,
        "PassiveSkillTreePanel",      0x6B0,
        "MapParentPtr",               0x748,
        "ControllerModeMapParentPtr", 0xAA8
    )

    ; Children of MapParentPtr / ControllerModeMapParentPtr
    ; (read from cache location inside the struct)
    static MapParentStruct := Map(
        "LargeMapPtr", 0x28,   ; 1st child ~ reading from cache location
        "MiniMapPtr",  0x30    ; 2nd child ~ reading from cache location
    )

    ; PassiveSkillTreeStruct: cache location disabled, use ChildNumber to walk children.
    ; ChildNumber = (3 - 1) * 0x08 = 0x10  →  offset into the children pointer array.
    static PassiveSkillTreeStruct := Map(
        "ChildNumber", 0x10
    )

    ; Offsets shared by every UiElement (UiElementBaseOffset.cs)
    static UiElementBase := Map(
        "ChildrenFirst",        0x010,  ; StdVector First ptr → pointer array of child UiElements
        "ParentPtr",            0x0B8,  ; ptr to parent UiElement (for absolute pos traversal)
        "PositionModifier",     0x0F0,  ; StdTuple2D<float> — added to parent pos when child's ShouldModifyPos (bit10) is set
        "RelativePosition",     0x118,  ; StdTuple2D<float> — position relative to parent (UI coords, base 2560×1600)
        "LocalScaleMultiplier", 0x130,  ; float — scale factor applied to children
        "Flags",                0x180,  ; uint — bit 10 = SHOULD_MODIFY_POS, bit 11 = IS_VISIBLE
        "ScaleIndex",           0x18A,  ; byte — 1/2/3 for GameWindowScale lookup
        "UnscaledSize",         0x288,  ; StdTuple2D<float> — element size in UI coords
        "BackgroundColor",      0x25C   ; packed RGBA uint — alpha = (value >> 24) & 0xFF
    )

    ; Extra offsets for Map-type UiElements (MapUiElementOffset.cs)
    ; Base = MapUiElementOffset (UiElementBase @ 0x000, then own fields)
    static MapUiElement := Map(
        "Shift",        0x340,  ; StdTuple2D<float> — user/game shift of map center
        "DefaultShift", 0x348,  ; StdTuple2D<float> — default offset (PoE2: 0, -20)
        "Zoom",         0x380   ; float — current zoom level (default ~0.5)
    )

}
