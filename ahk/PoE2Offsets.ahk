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
        "UiRootStructPtr", 0x2F0,    ; KB/M UI manager = UserInterface_MouseAndKeyboard
        "GamepadUiRootStructPtr", 0x318, ; controller UI manager
        "WorldData", 0x368
    )

    ; Fields within the AreaLoadingState game-state struct (StateNames[1]).
    static AreaLoadingState := Map(
        "IsLoading", 0x770,                  ; int — non-zero while an area is loading
        "TotalLoadingScreenTimeMs", 0xEC0,   ; uint — cumulative loading-screen time, increases on area change
        "CurrentAreaDetailsPtr", 0xF40       ; IntPtr — details of the area being loaded
    )

    static UiRootStruct := Map(
        "UiRootPtr", 0x340,
        "GameUiPtr", 0xBE0,
        "GameUiControllerPtr", 0xBE8
    )

    static WorldData := Map(
        "WorldAreaDetailsPtr", 0x98,
        "WorldAreaDetailsRowPtr", 0xA0,
        "CameraStructure", 0xA0,
        "W2SMatrix", 0x1A8   ; CameraStructure(0xA0) + Matrix4x4 offset(0x108) — PoE2 v0.5
    )

    static AreaInstance := Map(
        "CurrentAreaLevel", 0xC4,
        "CurrentAreaHash", 0x11C,
        "Environments", 0x4C0,
        "PlayerInfo", 0x580,
        ; EntityListStruct lives at AreaInstance+0x6C0; AwakeEntities is its first
        ; StdMap field (+0x00) and SleepingEntities the second (+0x10).
        "Entities", 0x6C0,
        "AwakeEntities", 0x6C0,
        "SleepingEntities", 0x6D0,
        "TerrainMetadata", 0x8A0   ; Gordin/GameHelper2 reference: TerrainStruct at AreaInstance+0x8A0
    )

    ; Offsets within TerrainStruct (base = AreaInstance + 0x8A0).
    ; Source: https://github.com/Gordin/GameHelper2 -- AreaInstanceOffsets.cs
    ; Each byte encodes 2 grid cells: even-x -> lower nibble, odd-x -> upper nibble.
    ; A nibble value != 0 means the cell is walkable.
    static TerrainMetadata := Map(
        "TotalTilesX", 0x18,   ; int64 — number of tile columns
        "TotalTilesY", 0x20,   ; int64 — number of tile rows
        "TileDetailsPtr", 0x28,   ; StdVector<TileStructure> (each 0x38 bytes)
        "GridWalkableData", 0xD0,   ; StdVector<byte> -- absolute: AreaInstance+0x970
        "GridLandscapeData", 0xE8,   ; StdVector<byte> -- absolute: AreaInstance+0x988
        "BytesPerRow", 0x130,  ; int32 -- absolute: AreaInstance+0x9D0
        "TileHeightMultiplier", 0x134   ; int16 -- absolute: AreaInstance+0x9D4
    )

    ; TileStructure layout (0x38 bytes each, within TileDetailsPtr vector)
    static TileStruct := Map(
        "SubTileDetailsPtr", 0x00,
        "TgtFilePtr", 0x08,  ; pointer to TgtFileStruct
        "TileHeight", 0x30,  ; int16
        "TileIdX", 0x34,  ; byte
        "TileIdY", 0x35,  ; byte
        "RotationSelector", 0x36   ; byte
    )

    ; TgtFileStruct layout (pointed to by TileStruct.TgtFilePtr)
    static TgtFile := Map(
        "Vtable", 0x00,
        "TgtPath", 0x08           ; StdWString — the entity/tile path
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
        "Id", 0x88,
        ; IsValid byte per Gordin/GameHelper2 EntityOffsets.cs (was 0x84).
        ; Semantics unchanged: bit 0 clear => entity valid. NEEDS IN-GAME VERIFY —
        ; the v0.5 client may still use 0x84; revert this commit if validity regresses.
        "Flags", 0x8C
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
        ; NOTE: pre-hotfix (v4.5.1.1.3) values. The v4.5.1.1.4 hotfix moved the
        ; Targetable struct again; the +0x17 guess (0x68) was wrong (those bytes
        ; read 1 for everything). Real offsets pending the chest opened/closed diff
        ; probe. Kept here as a neutral baseline (do not trust these on the hotfix).
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
        "ActiveSkills", 0xB08,        ; ActiveSkillsPtr StdVector start
        "ActiveSkillsLast", 0xB10,
        "Cooldowns", 0xB20,           ; CooldownsPtr StdVector start
        "CooldownsLast", 0xB28,
        "DeployedEntities", 0xC18,    ; DeployedEntityArray StdVector start (Gordin/GameHelper2 Actor.cs)
        "DeployedEntitiesLast", 0xC20
    )

    static ActiveSkillStructure := Map(
        "ActiveSkillPtr", 0x00
    )

    static ActiveSkillDetails := Map(
        "UseStage", 0x08,
        "CastType", 0x0C,
        "ActiveSkillsDatPtr", 0x20,                  ; direct pointer to the ActiveSkills DAT row (currently unused)
        "UnknownIdAndEquipmentInfo", 0x40,
        "GrantedEffectsPerLevelDatRow", 0x48,
        "GrantedEffectStatSetsPerLevelDatRow", 0x50,
        "TotalUses", 0xE4,            ; Gordin/GameHelper2 Actor.cs (was 0x98)
        "TotalCooldownTimeInMs", 0xE8 ; Gordin/GameHelper2 Actor.cs (was 0xA8)
    )

    ; GrantedEffectsPerLevel DAT row — first field is a pointer to the GrantedEffects DAT row
    static GrantedEffectsPerLevelDat := Map(
        "GrantedEffectDatPtr", 0x00
    )

    ; GrantedEffects DAT row — ActiveSkill foreignrow at 0x6F (row_ptr=0x6F, dat_name=0x77)
    static GrantedEffectsDat := Map(
        ; ActiveSkills.dat row pointer inside a GrantedEffects.dat row.
        ; Confirmed from the GameHelper source for PoE2 0.5.x
        ; (GameOffsets/Objects/FilesStructures/GrantedEffectsDatOffset.cs:
        ; [FieldOffset(0x57)] IntPtr ActiveSkillDatPtr).
        "ActiveSkillRowPtr", 0x57
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
        ; PoE2 v4.5.x: vital bases shifted; confirmed in-game via the component
        ; probe (Mana 5771/5771 @0x208 matched the client). Matches Gordin/GameHelper2
        ; Life.cs (Health 0x1B0, Mana 0x208, EnergyShield 0x248).
        "Health", 0x1B0,        ; was 0x1A8
        "Mana", 0x208,          ; was 0x1F8
        "EnergyShield", 0x248   ; was 0x230
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
        "InventoryPtr0", 0x08,
        "InventoryPtr1", 0x10   ; second pointer per upstream layout — usually
        ; points 0x10 bytes before InventoryPtr0;
        ; only the diagnostic dump reads it.
    )

    static Inventory := Map(
        "TotalBoxes", 0x150,          ; Gordin/GameHelper2 InventoryOffset.cs (was 0x14C)
        "TotalBoxesY", 0x154,         ; StdTuple2D<int>.Y of TotalBoxes (was 0x150)
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

    ; All offsets are relative to the KB/M UiRootStructPtr (= ReadPtr(InGameState + 0x2F0)).
    ; Controller-mode UI uses a different manager layout and may not use these KB/M offsets.
    static ImportantUiElements := Map(
        "ChatParentPtr", 0x640,
        "PassiveSkillTreePanel", 0x730,
        "MapParentPtr", 0x7C8,
        "ControllerModeMapParentPtr", 0xAA8
    )

    ; Children of MapParentPtr / ControllerModeMapParentPtr
    ; (read from cache location inside the struct)
    static MapParentStruct := Map(
        "LargeMapPtr", 0x28,   ; 1st child ~ reading from cache location
        "MiniMapPtr", 0x30    ; 2nd child ~ reading from cache location
    )

    ; PassiveSkillTreeStruct: cache location disabled, use ChildNumber to walk children.
    ; ChildNumber = (3 - 1) * 0x08 = 0x10  →  offset into the children pointer array.
    static PassiveSkillTreeStruct := Map(
        "ChildNumber", 0x10
    )

    ; Offsets shared by every UiElement (UiElementBaseOffset.cs)
    static UiElementBase := Map(
        "ChildrenFirst", 0x010,  ; StdVector First ptr → pointer array of child UiElements
        "ParentPtr", 0x0B8,  ; ptr to parent UiElement (for absolute pos traversal)
        "PositionModifier", 0x0F0,  ; StdTuple2D<float> — added to parent pos when child's ShouldModifyPos (bit10) is set
        "RelativePosition", 0x118,  ; StdTuple2D<float> — position relative to parent (UI coords, base 2560×1600)
        "LocalScaleMultiplier", 0x130,  ; float — scale factor applied to children
        "StringIdPtr", 0x0F8,  ; StdWString — UI element identifier (e.g. "LeftPanel", "UltimatumTitle"). 0x140 was the pre-patch offset.
        "FontNamePtr", 0x0C8,  ; StdWString — font family used for text rendering (e.g. "Fontin", "Fontin Smallcaps")
        "Flags", 0x180,  ; uint — bit 10 = SHOULD_MODIFY_POS, bit 11 = IS_VISIBLE
        "ScaleIndex", 0x18A,  ; byte — 1/2/3 for GameWindowScale lookup
        "BackgroundColor", 0x25C,  ; float4 RGBA — .W (alpha, +12) is used for chat-active check
        "UnscaledSize", 0x288   ; StdTuple2D<float> — element size in UI coords
    )

    ; Panels we want to detect for overlay visibility gating.
    ; Each name corresponds to a UiElement StringId discoverable under GameUiPtr.
    ; The offset is discovered at runtime by DiscoverPanelOffsets() and cached per patch.
    static PanelNames := [
        "LeftPanel",                ; Inventory / character sheet container
        "RightPanel",               ; Skill tree / social / other right-side panels
        "InventoryPanel",           ; Inventory grid
        "NpcDialogPanel",           ; NPC / vendor dialog
        "SellWindow",               ; Vendor sell window
        "TradeWindow",              ; Player-to-player trade
        "StashPanel",               ; Stash tab
        "SkillPanel",               ; Skill gem panel
        "SocialPanel",              ; Social / party / friends
        "WorldPanel",               ; Atlas / world map
        "CharacterPanel",           ; Character stats (C screen)
        "QuestPanel",               ; Quest tracker panel
        "MarketPanel",              ; Trade market
        "ChallengesPanel",          ; Challenges / achievements
        "RitualWindow",             ; Ritual encounter UI
        "EscapeMenu"                ; Escape / settings menu
    ]

    ; Runtime-populated: panelName → byte offset from GameUiPtr.
    ; Filled by DiscoverPanelOffsets(), persisted to INI under [PanelOffsets].
    static DiscoveredPanelOffsets := Map(
        "LeftPanel", 0x748,
        "RightPanel", 0x9F8
    )

    ; Extra offsets for Map-type UiElements (MapUiElementOffset.cs)
    ; Base = MapUiElementOffset (UiElementBase @ 0x000, then own fields)
    static MapUiElement := Map(
        ; PoE2 v4.5.x: all three shifted -0x38 (UiElementBase shrank); confirmed
        ; in-game (old Zoom@0x3E0 read 0.000). Matches Gordin/GameHelper2
        ; MapUiElement.cs (Shift 0x368, DefaultShift 0x370, Zoom 0x3A8).
        "Shift", 0x368,  ; StdTuple2D<float> — user/game shift of map center (was 0x3A0)
        "DefaultShift", 0x370,  ; StdTuple2D<float> — default offset PoE2 (0, -20) (was 0x3A8)
        "Zoom", 0x3A8   ; float — current zoom level (default ~0.5) (was 0x3E0)
    )

}