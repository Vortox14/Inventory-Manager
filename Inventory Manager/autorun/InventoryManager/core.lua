local core = {}
core.combat = require("InventoryManager/combat")

core.VERSION = "0.2.20.17"
core.ANALYSIS_API = 10

local STORAGE_ID = 65535
-- Canonical ItemDefine CharacterIDs from the current DD2 IL2CPP metadata.
-- app.CharacterID is Int32 at method boundaries, while StorageData._CharaId is
-- UInt32. Keep signed values for DD2 calls and compare identities by low32 hex.
local ARISEN_ID = -1403890315   -- 0xAC525575
local MAIN_PAWN_ID = -2011938949 -- 0x88143F7B
local LANTERN_FUEL_ID = 85
local LANTERN_IDS = { [86] = true, [87] = true, [88] = true, [89] = true }
local SEALING_PHIAL_IDS = { [90] = true, [91] = true }
core.SEALING_PHIAL_IDS = SEALING_PHIAL_IDS
local WAKESHARD_ID = 78
local WAKESTONE_ID = 77
local GOLD_ID = 93
local GOLD_CAP = 999999999
local UINT16_MAX = 65535
local UINT32_MAX = 4294967295
local STACK_SOFT_CAP = 10000
local STACK_HARD_CAP = 32000

local function character_id_hex32(value)
    local n = tonumber(value)
    if n == nil then return nil end
    local bits = math.floor(n) % 4294967296
    return string.format("0x%08X", bits)
end

local function normalize_stack_limit(value, fallback)
    local n = math.floor(tonumber(value) or tonumber(fallback) or 1)
    if n < 1 then n = 1 end
    if n > STACK_HARD_CAP then n = STACK_HARD_CAP end
    return n
end

core.STACK_SOFT_CAP = STACK_SOFT_CAP
core.STACK_HARD_CAP = STACK_HARD_CAP
local CONFIG_FILE = "InventoryManager.json"
-- REFramework file APIs are already rooted at reframework/data; never prefix paths with reframework/data/.
local PASS_ITEM_SIGNATURE = "passItem(app.ItemDefine.StorageData, System.Int32, app.CharacterID, System.Boolean)"
local PASS_ITEM_NOLOCK_SIGNATURE = "passItemNoLock(app.ItemDefine.StorageData, System.Int32, app.CharacterID, System.Boolean)"


local ItemManagerType = sdk.find_type_definition("app.ItemManager")
local CharacterManagerType = sdk.find_type_definition("app.CharacterManager")
local PawnManagerType = sdk.find_type_definition("app.PawnManager")
local ItemCommonParamType = sdk.find_type_definition("app.ItemCommonParam")
local StorageDataType = sdk.find_type_definition("app.ItemDefine.StorageData")
local StorageMasterDataType = sdk.find_type_definition("app.ItemManager.StorageMasterData")
local ContextHolderType = sdk.find_type_definition("app.ContextHolder")
local PawnDataContextType = sdk.find_type_definition("app.PawnDataContext")

local getHaveNumMethod = ItemManagerType and ItemManagerType:get_method("getHaveNum(System.Int32, app.CharacterID)") or nil
local getItemMethod = ItemManagerType and ItemManagerType:get_method("getItem(System.Int32, System.Int32, app.CharacterID, app.ItemDefine.GetItemOption)") or nil
local deleteItemNoLockMethod = ItemManagerType and ItemManagerType:get_method("deleteItemNoLock(System.Int32, System.Int32, app.CharacterID)") or nil
core._recreateTransferMethods = {
    getItemCharacter = ItemManagerType and ItemManagerType:get_method("getItem(System.Int32, System.Int32, app.Character, app.ItemDefine.GetItemOption)") or nil,
    deleteItemCharacter = ItemManagerType and ItemManagerType:get_method("deleteItem(System.Int32, System.Int32, app.Character)") or nil,
    deleteItemCharacterId = ItemManagerType and ItemManagerType:get_method("deleteItem(System.Int32, System.Int32, app.CharacterID)") or nil,
    forceWarehouse = ItemManagerType and ItemManagerType:get_method("forceGetItemToWarehouse(System.Int32, System.Int32)") or nil,
    forceWarehouseOption = ItemManagerType and ItemManagerType:get_method("forceGetItemToWarehouse(System.Int32, System.Int32, app.ItemDefine.GetItemOption)") or nil,
}
local isDecayItemMethod = ItemManagerType and ItemManagerType:get_method("isDecayItem(System.Int32)") or nil
local getStorageMasterListMethod = ItemManagerType and ItemManagerType:get_method("getStorageMasterList(app.CharacterID)") or nil
local calcWeightStorageMethod = ItemManagerType and ItemManagerType:get_method("calcWeightStorage(app.CharacterID)") or nil

-- Read-only APIs used by Item Analysis diagnostics. Production mutations stay on
-- the validated inventory paths; live StorageData is resolved through the
-- StorageMasterData row that already backs inventory counts.
local getDefaultStackNumMethod = ItemCommonParamType
    and ItemCommonParamType:get_method("getDefaultStackNum()") or nil
local getStackNumMethod = ItemCommonParamType
    and ItemCommonParamType:get_method("getStackNum(app.CharacterID)") or nil
local getIsEquipMethod = ItemCommonParamType
    and ItemCommonParamType:get_method("get_IsEquip()") or nil
local getIsEquipDataMethod = ItemCommonParamType
    and ItemCommonParamType:get_method("get_IsEquipData()") or nil
local getIsItemDataMethod = ItemCommonParamType
    and ItemCommonParamType:get_method("get_IsItemData()") or nil
local rawStackNumField = ItemCommonParamType
    and ItemCommonParamType:get_field("_StackNum") or nil
local warehouseMaxStackNumField = ItemCommonParamType
    and ItemCommonParamType:get_field("WarehouseMaxStackNum") or nil
local isNoStacItemMethod = ItemManagerType
    and ItemManagerType:get_method("isNoStacItem(app.ItemCommonParam)") or nil

local getStorageDataByIdMethod = ItemManagerType
    and ItemManagerType:get_method("getStorageData(System.Int32, app.CharacterID)") or nil
local getStorageDataByStorageIdMethod = ItemManagerType
    and ItemManagerType:get_method("getStorageDataByStorageId(System.Int32)") or nil
local isPassEnableMethod = ItemManagerType
    and ItemManagerType:get_method("isPassEnable(app.ItemDefine.StorageData, System.Boolean)") or nil
local isPassEnableCommandMethod = ItemManagerType
    and ItemManagerType:get_method("isPassEnableCommand(app.ItemDefine.StorageData, System.Boolean)") or nil
local getEquipLanternStorageIdMethod = ItemManagerType
    and ItemManagerType:get_method("getEquipLanternStorageId(app.CharacterID)") or nil
local getLanternInfoByStorageIdMethod = ItemManagerType
    and ItemManagerType:get_method("getLanternInfo(System.Int32)") or nil

-- Nested StorageData instance getters are intentionally not invoked.
-- Live testing showed their REFramework value/by-ref marshaling returns false/default values,
-- while the same StorageData raw fields and StorageMasterData getters are coherent.

-- StorageMasterData wraps a StorageData value and forwards many of its fields.
-- The master getters remain the canonical live view. Live testing showed
-- nested StorageData raw fields are coherent while invoking StorageData instance
-- getters through REFramework is unreliable for this value/by-ref structure.
local getMasterParamMethod = StorageMasterDataType
    and StorageMasterDataType:get_method("get_Param()") or nil
local getMasterItemIdMethod = StorageMasterDataType
    and StorageMasterDataType:get_method("get_ItemId()") or nil
local getMasterNumMethod = StorageMasterDataType
    and StorageMasterDataType:get_method("get_Num()") or nil
local getMasterStorageIdMethod = StorageMasterDataType
    and StorageMasterDataType:get_method("get_StorageId()") or nil
local getMasterCharaIdMethod = StorageMasterDataType
    and StorageMasterDataType:get_method("get_CharaId()") or nil
local getMasterIsEquippedMethod = StorageMasterDataType
    and StorageMasterDataType:get_method("get_IsEquipped()") or nil
local getMasterEquipSlotMethod = StorageMasterDataType
    and StorageMasterDataType:get_method("get_EquipSlot()") or nil
local getMasterUpdateIndexMethod = StorageMasterDataType
    and StorageMasterDataType:get_method("get_UpdateIndex()") or nil
local getMasterArisenEquipNoMethod = StorageMasterDataType
    and StorageMasterDataType:get_method("get_ArisenEquipNo()") or nil
local getMasterItemDataMethod = StorageMasterDataType
    and StorageMasterDataType:get_method("get_ItemData()") or nil
local getMasterEnhanceMethod = StorageMasterDataType
    and StorageMasterDataType:get_method("get_Enhance()") or nil
local getMasterEnhanceNumMethod = StorageMasterDataType
    and StorageMasterDataType:get_method("get_EnhanceNum()") or nil
local getMasterAbilityMethod = StorageMasterDataType
    and StorageMasterDataType:get_method("get_Ability()") or nil
local getMasterAbilityNumMethod = StorageMasterDataType
    and StorageMasterDataType:get_method("get_AbilityNum()") or nil

core.STORAGE_ID = STORAGE_ID
core.ARISEN_ID = ARISEN_ID
core.MAIN_PAWN_ID = MAIN_PAWN_ID
core.characterIdHex = character_id_hex32
core.LANTERN_FUEL_ID = LANTERN_FUEL_ID
core.GOLD_CAP = GOLD_CAP
core.UINT16_MAX = UINT16_MAX
core.UINT32_MAX = UINT32_MAX
-- Static-ish Item DB cache. This is intentionally separate from the live
-- Player / Storage / Pawn inventory snapshots below.
--
-- catalog / catalogById:
--     normal user-facing entries only ("Invalid" records excluded)
-- catalogAll / catalogAllById:
--     every successfully parsed ItemDataParam record, including Invalid
-- catalogInvalid:
--     records whose game-supplied name is exactly "Invalid"
core.catalog = {}
core.catalogById = {}
core.catalogAll = {}
core.catalogAllById = {}
core.catalogInvalid = {}
core.catalogStats = {
    enumerated = 0,
    parsed = 0,
    valid = 0,
    invalid = 0,
    duplicateIds = 0,
    idMismatches = 0,
    parseErrors = 0,
}
core.snapshots = {
    player = {},
    mainpawn = {},
    pawna = {},
    pawnb = {},
    storage = {},
    -- Pawn automation keeps its own rule-oriented aggregate snapshot here.
    pawns = {},
}
core.party = {}
core.pawnSlots = {
    MainPawn = nil,
    PawnA = nil,
    PawnB = nil,
}
core.catalogReady = false
core.status = "Inventory Manager is idle."
core.lastError = nil
core.lastReport = {}
core.apiReport = {}
core.nativeTransfer = {
    scanned = false,
    method = nil,
    noLockMethod = nil,
    signature = nil,
    reason = "Not resolved yet.",
    boolValue = false,
    sessionFaulted = false,
    sessionFaultReason = nil,
    faultCount = 0,
}

-- All inventory mutations are dispatched from InventoryManager.lua's direct
-- REFramework UpdateBehavior callback. Mutation processing deliberately ignores
-- NickCore's paused/Active-UI state so the project remains fully usable while DD2's
-- inventory and other soft-pause menus are open. The UI only queues work; it never
-- mutates ItemManager/StorageData directly.
-- Stabilization: execute only one native inventory mutation per UpdateBehavior.
-- Even a large cleaner batch therefore gives DD2 a full update boundary between
-- passItem calls instead of performing back-to-back native transfers in one tick.
core.MUTATION_STEPS_PER_UPDATE = 1
core.mutations = {
    queue = {},
    processing = false,
    nextId = 0,
    completed = 0,
    failed = 0,
    lastResult = "Idle.",
    safetyStopped = false,
    safetyStopReason = nil,
}

local transfer_equipment_instances
local get_source_storage_data
local call_native_storage_transfer
local transfer_native_stack
local storage_master_row_item_id
local storage_master_row_quantity
local storage_master_row_storage_id
local storage_master_row_chara_id
local storage_master_row_is_equipped
local storage_master_row_equip_slot
local storage_master_row_update_index
local storage_master_row_arisen_equip_no
local equipped_storage_ids

local savedConfig = json.load_file(CONFIG_FILE) or {}
core.combat.configure(savedConfig.PawnRetrievalMode)

local savedTransferMode = tostring(savedConfig.TransferMode or "Native")
if savedTransferMode ~= "Native" and savedTransferMode ~= "Recreate" then
    savedTransferMode = "Native"
end
core.transferPolicy = {
    -- Native is the normal DD2 path: passItem(StorageData, amount, destination, ...).
    -- Recreate is retained only as an explicit compatibility/user-preference mode.
    mode = savedTransferMode,
}

local DEBUG_LOG_LEVELS = { "Off", "Basic", "Verbose", "Trace" }
local DEBUG_LOG_VALUES = { Off = 0, Basic = 1, Verbose = 2, Trace = 3 }
local DEBUG_LOG_FILE = "InventoryManager_debug.log"
local DEBUG_LOG_MAX_BYTES = 2 * 1024 * 1024
local debugLogFilePrepared = false
local debugLogFileErrorReported = false

local function prepare_debug_log_file()
    if debugLogFilePrepared then return true end
    debugLogFilePrepared = true

    local ok, err = pcall(function()
        local f = io.open(DEBUG_LOG_FILE, "rb")
        if f then
            local size = f:seek("end") or 0
            f:close()
            if size > DEBUG_LOG_MAX_BYTES then
                os.remove(DEBUG_LOG_FILE .. ".old")
                os.rename(DEBUG_LOG_FILE, DEBUG_LOG_FILE .. ".old")
            end
        end
    end)
    if not ok and not debugLogFileErrorReported then
        debugLogFileErrorReported = true
        pcall(function() log.error("[InventoryManager] Diagnostic log rotation failed: " .. tostring(err)) end)
    end
    return ok
end

local function append_debug_log_file(line)
    prepare_debug_log_file()
    local ok, err = pcall(function()
        local f = io.open(DEBUG_LOG_FILE, "ab")
        if not f then error("io.open returned nil") end
        f:write(tostring(line), "\n")
        f:flush()
        f:close()
    end)
    if not ok and not debugLogFileErrorReported then
        debugLogFileErrorReported = true
        pcall(function() log.error("[InventoryManager] Diagnostic log write failed: " .. tostring(err)) end)
    end
    return ok
end

local function normalize_debug_log_level(value)
    if type(value) == "number" then
        local index = math.max(1, math.min(#DEBUG_LOG_LEVELS, math.floor(value)))
        return DEBUG_LOG_LEVELS[index]
    end
    value = tostring(value or "Off")
    for _, name in ipairs(DEBUG_LOG_LEVELS) do
        if string.lower(value) == string.lower(name) then return name end
    end
    return "Off"
end

core.debug = {
    level = normalize_debug_log_level(savedConfig.DebugLogLevel),
}

local function debug_level_value(level)
    if type(level) == "number" then
        return math.max(0, math.min(3, math.floor(level)))
    end
    return DEBUG_LOG_VALUES[normalize_debug_log_level(level)] or 0
end

function core.debugLog(level, fmt, ...)
    local eventLevel = normalize_debug_log_level(level)
    local required = debug_level_value(eventLevel)
    local current = DEBUG_LOG_VALUES[core.debug.level] or 0
    if current < required or required <= 0 then return false end

    local ok, message = pcall(string.format, tostring(fmt or ""), ...)
    if not ok then message = tostring(fmt or "") end
    local timestamp = os.date and os.date("%Y-%m-%d %H:%M:%S") or "time-unavailable"
    local line = string.format("[%s] [InventoryManager][DBG:%s] %s", tostring(timestamp), tostring(eventLevel), tostring(message))

    -- REFramework builds/configurations can omit Lua log.info() lines from
    -- re2_framework_log.txt. print() is mirrored into the script/debug stream,
    -- while the dedicated file is flushed and closed on every entry so a native
    -- crash cannot strand the most recent diagnostic breadcrumbs in a buffer.
    pcall(print, line)
    append_debug_log_file(line)
    return true
end

function core.getDebugLogChoices()
    return DEBUG_LOG_LEVELS
end

function core.getDebugLogLevel()
    return tostring(core.debug.level or "Off")
end

function core.getDebugLogLevelIndex()
    local current = core.getDebugLogLevel()
    for i, name in ipairs(DEBUG_LOG_LEVELS) do
        if name == current then return i end
    end
    return 1
end


function core.getDebugLogDisplayPath()
    return "reframework/data/" .. DEBUG_LOG_FILE
end

function core.clearDebugLogFile()
    local ok, err = pcall(function()
        os.remove(DEBUG_LOG_FILE)
        os.remove(DEBUG_LOG_FILE .. ".old")
    end)
    debugLogFilePrepared = false
    debugLogFileErrorReported = false
    if not ok then return false, tostring(err) end
    return true
end

local savedStackMode = tostring(savedConfig.StackMode or "Vanilla")
if savedStackMode ~= "Vanilla" and savedStackMode ~= "Global" and savedStackMode ~= "Scoped" then
    savedStackMode = "Vanilla"
end

core.stack = {
    mode = savedStackMode,
    enabled = false,
    globalLimit = normalize_stack_limit(savedConfig.StackGlobalLimit, 9999),
    actorEnabled = savedConfig.StackActorEnabled == true,
    actorLimit = normalize_stack_limit(savedConfig.StackActorLimit, 99),
    storageEnabled = savedConfig.StackStorageEnabled == true,
    storageLimit = normalize_stack_limit(savedConfig.StackStorageLimit, 999),
    -- Captured before this mod mutates either native stack field. getDefaultStackNum()
    -- mirrors the mutable _StackNum, so it cannot reconstruct vanilla afterward.
    vanillaById = {},
    warehouseVanillaById = {},
    warehouseVanillaGlobal = nil,
    nativeNoStackById = {},
    warehouseFieldStatic = nil,
    capturedCount = 0,
    appliedCount = 0,
}
core.stack.enabled = core.stack.mode == "Global"
    or (core.stack.mode == "Scoped" and (core.stack.actorEnabled or core.stack.storageEnabled))

local function normalize_pawn_cleaner_overrides(raw)
    local out = {}
    if type(raw) ~= "table" then return out end
    for key, value in pairs(raw) do
        local id = math.floor(tonumber(key) or -1)
        if id > 0 and type(value) == "table" then
            local mode = tostring(value.mode or "")
            if mode == "transfer" or mode == "ignore" then
                local destination = tostring(value.destination or "Storage")
                if destination ~= "Player" then destination = "Storage" end
                out[id] = {
                    mode = mode,
                    destination = destination,
                    keep = mode == "transfer"
                        and math.max(0, math.floor(tonumber(value.keep) or 0))
                        or 0,
                }
            end
        end
    end
    return out
end

core.pawnCleaner = {
    enabled = savedConfig.PawnCleanerEnabled == true,
    pollTicks = math.max(15, math.min(600, math.floor(tonumber(savedConfig.PawnCleanerPollTicks) or 60))),
    overrides = normalize_pawn_cleaner_overrides(savedConfig.PawnCleanerOverrides),
    defaultIds = {},
    baseline = nil,
    status = "Pawn auto-clean is disabled.",
    lastDetected = 0,
    lastQueued = 0,
    completedBatches = 0,
    completedRefills = 0,
    lastRefillQueued = 0,
    refillStatus = "Pawn auto-retrieval is idle.",
    controlCallback = nil,
}

local function normalize_player_cleaner_overrides(raw)
    local out = {}
    if type(raw) ~= "table" then return out end
    for key, value in pairs(raw) do
        local id = math.floor(tonumber(key) or -1)
        if id > 0 and type(value) == "table" then
            local mode = tostring(value.mode or "")
            if mode == "transfer" or mode == "ignore" then
                out[id] = {
                    mode = mode,
                    destination = "Storage",
                    keep = mode == "transfer"
                        and math.max(0, math.floor(tonumber(value.keep) or 0))
                        or 0,
                }
            end
        end
    end
    return out
end

-- Player automation is intentionally independent from Pawn automation.
-- Its default policy is Keep All; only explicit Player overrides transfer items.
core.playerCleaner = {
    enabled = savedConfig.PlayerCleanerEnabled == true,
    overrides = normalize_player_cleaner_overrides(savedConfig.PlayerCleanerOverrides),
    defaultIds = {},
    baseline = nil,
    status = "Player auto-clean is disabled.",
    lastDetected = 0,
    lastQueued = 0,
    completedBatches = 0,
    controlCallback = nil,
}

local function clamp_ui_percent(value, fallback)
    value = math.floor(tonumber(value) or fallback or 62)
    return math.max(25, math.min(80, value))
end

local function clamp_ui_font_size(value, fallback)
    value = math.floor(tonumber(value) or fallback or 24)
    return math.max(10, math.min(48, value))
end


local ROWS_PER_PAGE_OPTIONS = { 20, 40, 60, 80, 100, 120 }

local function clamp_rows_per_page(value, fallback)
    value = math.floor(tonumber(value) or fallback or 40)
    local best = ROWS_PER_PAGE_OPTIONS[1]
    local bestDelta = math.abs(value - best)
    for _, option in ipairs(ROWS_PER_PAGE_OPTIONS) do
        local delta = math.abs(value - option)
        if delta < bestDelta then
            best = option
            bestDelta = delta
        end
    end
    return best
end

core.ROWS_PER_PAGE_OPTIONS = ROWS_PER_PAGE_OPTIONS

core.ui = {
    -- Inventory Manager owns these values. They are intentionally independent
    -- from REFramework's global UI font scalar, which can be captured at DD2's
    -- temporary 1280x720 bootstrap resolution.
    fontSize = clamp_ui_font_size(savedConfig.UiFontSize, 24),
    fontFile = tostring(savedConfig.UiFontFile or ""),
    fontHandle = nil,
    fontHandleFile = nil,
    fontLoadAttemptedFile = nil,
    fontLoadError = nil,
    availableFonts = nil,
    fontScanStatus = "Fonts not scanned yet.",
    fontDirectory = "reframework\\fonts",
    fontResolvedDirectory = nil,
    fontScanCandidates = {},
    inventorySplit = {
        Player = clamp_ui_percent(savedConfig.PlayerInventorySplit, 62),
        Storage = clamp_ui_percent(savedConfig.StorageInventorySplit, 62),
    },
    autoApplyQuantity = savedConfig.AutoApplyQuantity == true,
    rowsPerPage = clamp_rows_per_page(savedConfig.RowsPerPage, 40),
}

-- Transfer capacity protection is intentionally runtime-only. The Analysis window
-- can bypass it for modder/debug work, but every script reload starts protected.
core.transferSafety = {
    ignoreCapacity = false,
}

function core.setIgnoreTransferCapacitySafety(enabled)
    core.transferSafety.ignoreCapacity = enabled == true
    return core.transferSafety.ignoreCapacity
end

function core.getIgnoreTransferCapacitySafety()
    return core.transferSafety.ignoreCapacity == true
end

local function save_config()
    local ok, err = pcall(json.dump_file, CONFIG_FILE, {
        StackMode = core.stack.mode,
        StackGlobalLimit = core.stack.globalLimit,
        StackActorEnabled = core.stack.actorEnabled == true,
        StackActorLimit = core.stack.actorLimit,
        StackStorageEnabled = core.stack.storageEnabled == true,
        StackStorageLimit = core.stack.storageLimit,
        UiFontSize = core.ui.fontSize,
        UiFontFile = core.ui.fontFile,
        PlayerInventorySplit = core.ui.inventorySplit.Player,
        StorageInventorySplit = core.ui.inventorySplit.Storage,
        AutoApplyQuantity = core.ui.autoApplyQuantity == true,
        RowsPerPage = core.ui.rowsPerPage,
        DebugLogLevel = core.getDebugLogLevel(),
        PawnCleanerEnabled = core.pawnCleaner.enabled == true,
        PawnCleanerPollTicks = core.pawnCleaner.pollTicks,
        PawnCleanerOverrides = core.pawnCleaner.overrides,
        PawnRetrievalMode = core.combat.getMode(),
        PlayerCleanerEnabled = core.playerCleaner.enabled == true,
        PlayerCleanerOverrides = core.playerCleaner.overrides,
        TransferMode = core.transferPolicy and core.transferPolicy.mode or "Native",
    })
    if not ok then
        log.error("[InventoryManager] Failed to save " .. CONFIG_FILE .. ": " .. tostring(err))
    end
end

function core.getTransferMode()
    local mode = core.transferPolicy and tostring(core.transferPolicy.mode or "Native") or "Native"
    if mode ~= "Native" and mode ~= "Recreate" then mode = "Native" end
    return mode
end

function core.setTransferMode(mode)
    mode = tostring(mode or "Native")
    if mode ~= "Native" and mode ~= "Recreate" then mode = "Native" end
    core.transferPolicy.mode = mode
    save_config()
    core.debugLog("Basic", "Fungible transfer mode changed to %s", mode)
    return mode
end

function core.setDebugLogLevel(value)
    local level
    if type(value) == "number" then
        local index = math.max(1, math.min(#DEBUG_LOG_LEVELS, math.floor(value)))
        level = DEBUG_LOG_LEVELS[index]
    else
        level = normalize_debug_log_level(value)
    end

    if core.debug.level ~= level then
        core.debug.level = level
        save_config()
        if level ~= "Off" then
            core.debugLog("Basic", "Diagnostic logging enabled; configured level=%s version=%s", level, tostring(core.VERSION or "?"))
        end
    end
    return core.debug.level
end

function core.setDebugLogLevelIndex(index)
    return core.setDebugLogLevel(tonumber(index) or 1)
end

local function trip_mutation_safety_stop(reason)
    reason = tostring(reason or "Unknown native inventory fault.")
    core.nativeTransfer.sessionFaulted = true
    core.nativeTransfer.sessionFaultReason = reason
    core.nativeTransfer.faultCount = (core.nativeTransfer.faultCount or 0) + 1
    core.mutations.safetyStopped = true
    core.mutations.safetyStopReason = reason
    core.lastError = reason
    core.status = "SAFETY STOP: " .. reason
    log.error("[InventoryManager] SAFETY STOP: " .. reason .. " Further inventory mutations are blocked for this Lua session.")
    core.debugLog("Basic", "Native transfer circuit breaker tripped; pending/future mutations are blocked. reason=%s", reason)
end

function core.getMutationSafetyStatus()
    return {
        stopped = core.mutations.safetyStopped == true,
        reason = core.mutations.safetyStopReason,
        nativeTransferFaulted = core.nativeTransfer.sessionFaulted == true,
        nativeTransferReason = core.nativeTransfer.sessionFaultReason,
        faultCount = core.nativeTransfer.faultCount or 0,
    }
end

local function trim_text(value)
    value = tostring(value or "")
    return value:gsub("^%s+", ""):gsub("%s+$", "")
end

function core.getUiFontSize()
    return clamp_ui_font_size(core.ui.fontSize, 24)
end

function core.setUiFontSize(value)
    value = clamp_ui_font_size(value, core.ui.fontSize or 24)
    if core.ui.fontSize ~= value then
        core.ui.fontSize = value
        save_config()
    end
    return core.ui.fontSize
end

function core.getUiFontFile()
    return tostring(core.ui.fontFile or "")
end

local UI_FONT_EXTENSIONS = {
    [".ttf"] = true,
    [".otf"] = true,
}

local function normalize_font_relative_path(path)
    path = tostring(path or ""):gsub("/", "\\")
    path = path:gsub("^[\\]+", ""):gsub("[\\]+$", "")
    return path
end

local function is_supported_font_file(path)
    path = tostring(path or "")
    local ext = path:match("(%.[^%.\\/]+)$")
    if not ext then return false end
    return UI_FONT_EXTENSIONS[string.lower(ext)] == true
end

-- REFramework's imgui.load_font() resolves paths relative to:
--   <persistent dir>/reframework/fonts
--
-- Inventory Manager enumerates that same directory through the REFramework
-- Lua filesystem binding. The patched REFramework build adds a dedicated
-- "$fonts" fs.glob root so this script never needs to guess the process path
-- or depend on System.IO reflection.
function core.refreshUiFonts()
    local names, seen = {}, {}
    core.ui.fontDirectory = "reframework\\fonts"
    core.ui.fontResolvedDirectory = core.ui.fontDirectory
    core.ui.fontScanCandidates = { "$fonts -> reframework\\fonts" }

    if not fs or type(fs.glob) ~= "function" then
        core.ui.availableFonts = names
        core.ui.fontScanStatus = "Font scan failed: this REFramework build does not expose fs.glob()."
        return false, core.ui.fontScanStatus
    end

    local ok, entries = pcall(fs.glob, ".*", "$fonts")
    if not ok then
        core.ui.availableFonts = names
        core.ui.fontScanStatus = "Font scan failed through REFramework $fonts root: " .. tostring(entries)
        return false, core.ui.fontScanStatus
    end

    for _, entry in ipairs(entries or {}) do
        local relative = normalize_font_relative_path(entry)
        if relative ~= ""
            and string.find(relative, "..", 1, true) == nil
            and is_supported_font_file(relative) then
            local key = string.lower(relative)
            if not seen[key] then
                seen[key] = true
                names[#names + 1] = relative
            end
        end
    end

    table.sort(names, function(a, b)
        return string.lower(tostring(a)) < string.lower(tostring(b))
    end)

    core.ui.availableFonts = names
    if #names > 0 then
        core.ui.fontScanStatus = string.format(
            "Found %d supported font%s in reframework\\fonts via REFramework fs.glob($fonts).",
            #names,
            #names == 1 and "" or "s")
        return true, core.ui.fontScanStatus
    end

    core.ui.fontScanStatus =
        "Found 0 supported fonts via REFramework fs.glob($fonts). If reframework\\fonts is not empty, the running REFramework DLL is missing the $fonts filesystem root."
    return false, core.ui.fontScanStatus
end

function core.getAvailableUiFonts()
    if core.ui.availableFonts == nil then core.refreshUiFonts() end
    return core.ui.availableFonts or {}
end

function core.getUiFontScanStatus()
    return tostring(core.ui.fontScanStatus or "")
end

function core.getUiFontDirectory()
    return tostring(core.ui.fontResolvedDirectory or core.ui.fontDirectory or "reframework\\fonts")
end

function core.getUiFontScanCandidates()
    return core.ui.fontScanCandidates or {}
end

function core.getUiFontChoiceIndex()
    local current = string.lower(trim_text(core.ui.fontFile))
    if current == "" then return 1 end
    for i, name in ipairs(core.getAvailableUiFonts()) do
        if string.lower(tostring(name)) == current then return i + 1 end
    end
    return 1
end

function core.getUiFontChoices()
    local choices = { "REFramework Default" }
    for _, name in ipairs(core.getAvailableUiFonts()) do choices[#choices + 1] = name end
    return choices
end

function core.setUiFontChoiceIndex(index)
    index = math.floor(tonumber(index) or 1)
    if index <= 1 then return core.setUiFontFile("") end
    local fonts = core.getAvailableUiFonts()
    local name = fonts[index - 1]
    if name == nil then return core.getUiFontFile() end
    return core.setUiFontFile(name)
end

function core.setUiFontFile(value)
    value = trim_text(value)
    if core.ui.fontFile ~= value then
        core.ui.fontFile = value
        core.ui.fontHandle = nil
        core.ui.fontHandleFile = nil
        core.ui.fontLoadAttemptedFile = nil
        core.ui.fontLoadError = nil
        save_config()
    end
    return core.ui.fontFile
end

function core.reloadUiFont()
    local file = trim_text(core.ui.fontFile)
    core.ui.fontHandle = nil
    core.ui.fontHandleFile = nil
    core.ui.fontLoadAttemptedFile = file
    core.ui.fontLoadError = nil

    if file == "" then return true, "REFramework default font face" end
    if string.find(file, "..", 1, true) ~= nil then
        core.ui.fontLoadError = "Font path cannot contain '..'."
        return false, core.ui.fontLoadError
    end
    if not imgui or type(imgui.load_font) ~= "function" then
        core.ui.fontLoadError = "This REFramework build does not expose imgui.load_font()."
        return false, core.ui.fontLoadError
    end

    local ok, handle = pcall(imgui.load_font, file, core.getUiFontSize())
    if not ok or type(handle) ~= "number" or handle < 0 then
        core.ui.fontLoadError = ok and ("Font loader returned invalid handle: " .. tostring(handle))
            or tostring(handle)
        return false, core.ui.fontLoadError
    end

    core.ui.fontHandle = handle
    core.ui.fontHandleFile = file
    return true, "Loaded " .. file
end

function core.getUiFontStatus()
    local file = trim_text(core.ui.fontFile)
    if file == "" then
        return "REFramework default face; Inventory Manager fixed-size rendering"
    end
    if core.ui.fontHandle ~= nil and core.ui.fontHandleFile == file then
        return "Custom font: " .. file
    end
    if core.ui.fontLoadError then return "Font fallback: " .. tostring(core.ui.fontLoadError) end
    return "Custom font pending: " .. file
end

-- Returns the push kind so the caller can always pair it with popUiFont().
-- push_font_size() fixes our text size even if REFramework's own UI scalar changes.
function core.pushUiFont()
    local size = core.getUiFontSize()
    local file = trim_text(core.ui.fontFile)

    if file ~= "" and core.ui.fontHandle == nil and core.ui.fontLoadAttemptedFile ~= file then
        core.reloadUiFont()
    end

    if file ~= "" and core.ui.fontHandle ~= nil and core.ui.fontHandleFile == file
        and imgui and type(imgui.push_font) == "function" then
        imgui.push_font(core.ui.fontHandle, size)
        return "font"
    end

    if imgui and type(imgui.push_font_size) == "function" then
        imgui.push_font_size(size)
        return "size"
    end
    return nil
end

function core.popUiFont(kind)
    if kind == "font" and imgui and type(imgui.pop_font) == "function" then
        imgui.pop_font()
    elseif kind == "size" and imgui and type(imgui.pop_font_size) == "function" then
        imgui.pop_font_size()
    end
end

-- Populate the selector once at script load. A manual Refresh button remains
-- available in case the user adds/removes font files while DD2 is running.
pcall(core.refreshUiFonts)


function core.setAutoApplyQuantity(enabled)
    core.ui.autoApplyQuantity = enabled == true
    save_config()
    return core.ui.autoApplyQuantity
end

function core.setRowsPerPage(value)
    core.ui.rowsPerPage = clamp_rows_per_page(value, core.ui.rowsPerPage or 40)
    save_config()
    return core.ui.rowsPerPage
end


local function set_status(message)
    core.lastError = nil
    core.status = tostring(message or "")
    log.info("[InventoryManager] " .. core.status)
end

local function set_error(message)
    core.lastError = tostring(message or "Unknown error")
    core.status = "ERROR: " .. core.lastError
    log.error("[InventoryManager] " .. core.lastError)
end

local function invoke_callback(callback, ...)
    if type(callback) ~= "function" then return end
    local ok, err = pcall(callback, ...)
    if not ok then
        log.error("[InventoryManager] Mutation completion callback failed: " .. tostring(err))
    end
end

local function mutation_task_count()
    return #(core.mutations.queue or {})
end


function core.getMutationStepsPerUpdate()
    return core.MUTATION_STEPS_PER_UPDATE
end

function core.hasPendingMutations()
    return core.mutations.processing == true or mutation_task_count() > 0
end

function core.getMutationStatus()
    local queue = core.mutations.queue or {}
    local task = queue[1]
    local status = {
        busy = core.hasPendingMutations(),
        queuedTasks = #queue,
        processing = core.mutations.processing == true,
        label = nil,
        index = nil,
        total = nil,
        completed = core.mutations.completed or 0,
        failed = core.mutations.failed or 0,
        lastResult = core.mutations.lastResult or "",
    }
    if task then
        status.label = task.label
        if task.kind == "batch" then
            status.index = math.min(task.index or 1, task.total or 0)
            status.total = task.total or 0
        else
            status.index = 1
            status.total = 1
        end
    end
    return status
end

local function next_mutation_id()
    core.mutations.nextId = (core.mutations.nextId or 0) + 1
    return core.mutations.nextId
end

function core.enqueueMutation(label, fn, options)
    if core.mutations.safetyStopped then
        return nil, "Inventory mutation safety stop is active: " .. tostring(core.mutations.safetyStopReason or "native transfer fault")
    end
    if type(fn) ~= "function" then
        return nil, "Mutation job must provide a function."
    end
    options = options or {}
    local task = {
        kind = "single",
        id = next_mutation_id(),
        label = tostring(label or "Inventory mutation"),
        fn = fn,
        onComplete = options.onComplete,
    }
    table.insert(core.mutations.queue, task)
    core.status = "Queued: " .. task.label
    core.debugLog("Verbose", "Queued single mutation id=%s label=%s queue=%d", tostring(task.id), tostring(task.label), #(core.mutations.queue or {}))
    return task.id
end

function core.enqueueMutationBatch(label, jobs, options)
    if core.mutations.safetyStopped then
        return nil, "Inventory mutation safety stop is active: " .. tostring(core.mutations.safetyStopReason or "native transfer fault")
    end
    options = options or {}
    local clean = {}
    for _, job in ipairs(jobs or {}) do
        if type(job) == "function" then
            table.insert(clean, { label = "Mutation " .. tostring(#clean + 1), fn = job })
        elseif type(job) == "table" and type(job.fn) == "function" then
            table.insert(clean, {
                label = tostring(job.label or ("Mutation " .. tostring(#clean + 1))),
                fn = job.fn,
                meta = job.meta,
            })
        end
    end

    if #clean == 0 then
        return nil, "Mutation batch contains no executable jobs."
    end

    local task = {
        kind = "batch",
        id = next_mutation_id(),
        label = tostring(label or "Inventory mutation batch"),
        jobs = clean,
        index = 1,
        total = #clean,
        succeeded = 0,
        notices = {},
        onProgress = options.onProgress,
        onComplete = options.onComplete,
    }
    table.insert(core.mutations.queue, task)
    core.status = string.format("Queued: %s (%d steps)", task.label, task.total)
    core.debugLog("Basic", "Queued mutation batch id=%s label=%s steps=%d queue=%d", tostring(task.id), tostring(task.label), task.total or 0, #(core.mutations.queue or {}))
    return task.id
end

local function execute_mutation_function(fn)
    local callOk, opOk, opResult = pcall(fn)

    if not callOk then
        return false, tostring(opOk)
    end
    if opOk == false then
        return false, tostring(opResult or "Mutation returned false.")
    end
    return true, opResult
end

-- Executes exactly one queued mutation step. InventoryManager.lua invokes this
-- from its direct REFramework UpdateBehavior callback while queue work is active.
local function process_one_mutation_step()
    if core.mutations.processing == true then return false end
    if core.mutations.safetyStopped then
        local dropped = #(core.mutations.queue or {})
        core.mutations.queue = {}
        core.mutations.processing = false
        core.mutations.lastResult = "Safety stop active; dropped " .. tostring(dropped) .. " queued mutation task(s)."
        core.status = "SAFETY STOP: " .. tostring(core.mutations.safetyStopReason or "native transfer fault")
        core.debugLog("Basic", "Mutation worker halted by safety stop; droppedTasks=%d", dropped)
        return false
    end

    local queue = core.mutations.queue
    local task = queue and queue[1] or nil
    if not task then return false end

    core.mutations.processing = true

    if task.kind == "batch" then
        local job = task.jobs[task.index]
        if not job then
            table.remove(queue, 1)
            core.mutations.completed = (core.mutations.completed or 0) + 1
            core.mutations.lastResult = string.format("%s completed (%d/%d).", task.label, task.succeeded or 0, task.total or 0)
            core.lastError = nil
            core.status = core.mutations.lastResult
            core.mutations.processing = false
            invoke_callback(task.onComplete, {
                id = task.id,
                label = task.label,
                success = true,
                aborted = false,
                processed = task.succeeded or 0,
                total = task.total or 0,
                notices = task.notices or {},
            })
            return true
        end

        local stepIndex = task.index
        core.debugLog("Trace", "Mutation step begin batch=%s id=%s step=%d/%d job=%s", tostring(task.label), tostring(task.id), stepIndex, task.total or 0, tostring(job.label))
        local ok, result = execute_mutation_function(job.fn)
        if ok then
            task.succeeded = (task.succeeded or 0) + 1
            task.index = stepIndex + 1
            if type(result) == "string" and result ~= "" then
                table.insert(task.notices, result)
            end
            core.mutations.lastResult = string.format(
                "%s: %d/%d complete (%s).",
                task.label,
                task.succeeded,
                task.total,
                tostring(job.label)
            )
            core.status = core.mutations.lastResult
            core.debugLog("Verbose", "Mutation step success batch=%s step=%d/%d job=%s result=%s", tostring(task.label), stepIndex, task.total or 0, tostring(job.label), tostring(result))
            invoke_callback(task.onProgress, {
                id = task.id,
                label = task.label,
                success = true,
                index = stepIndex,
                processed = task.succeeded,
                total = task.total,
                jobLabel = job.label,
                meta = job.meta,
                result = result,
            })

            if task.index > task.total then
                table.remove(queue, 1)
                core.mutations.completed = (core.mutations.completed or 0) + 1
                core.mutations.lastResult = string.format("%s completed (%d/%d).", task.label, task.succeeded, task.total)
                core.lastError = nil
                core.status = core.mutations.lastResult
                core.mutations.processing = false
                invoke_callback(task.onComplete, {
                    id = task.id,
                    label = task.label,
                    success = true,
                    aborted = false,
                    processed = task.succeeded,
                    total = task.total,
                    notices = task.notices or {},
                })
                return true
            end
        else
            table.remove(queue, 1)
            core.mutations.failed = (core.mutations.failed or 0) + 1
            core.mutations.lastResult = string.format(
                "%s ABORTED at %d/%d (%s): %s",
                task.label,
                stepIndex,
                task.total,
                tostring(job.label),
                tostring(result)
            )
            core.lastError = tostring(result)
            core.status = "ERROR: " .. core.mutations.lastResult
            core.debugLog("Basic", "Mutation step FAILED batch=%s id=%s step=%d/%d job=%s error=%s", tostring(task.label), tostring(task.id), stepIndex, task.total or 0, tostring(job.label), tostring(result))
            log.error("[InventoryManager] " .. core.mutations.lastResult)
            invoke_callback(task.onProgress, {
                id = task.id,
                label = task.label,
                success = false,
                index = stepIndex,
                processed = task.succeeded or 0,
                total = task.total,
                jobLabel = job.label,
                meta = job.meta,
                error = tostring(result),
            })
            core.mutations.processing = false
            invoke_callback(task.onComplete, {
                id = task.id,
                label = task.label,
                success = false,
                aborted = true,
                processed = task.succeeded or 0,
                total = task.total,
                failedIndex = stepIndex,
                failedLabel = job.label,
                failedMeta = job.meta,
                error = tostring(result),
                notices = task.notices or {},
            })
            return true
        end

        core.mutations.processing = false
        return true
    end

    local ok, result = execute_mutation_function(task.fn)
    table.remove(queue, 1)

    local summary = {
        id = task.id,
        label = task.label,
        success = ok,
        aborted = not ok,
        processed = ok and 1 or 0,
        total = 1,
        result = ok and result or nil,
        error = ok and nil or tostring(result),
    }

    if ok then
        core.mutations.completed = (core.mutations.completed or 0) + 1
        core.mutations.lastResult = task.label .. " completed."
        core.lastError = nil
        core.status = core.mutations.lastResult
    else
        core.mutations.failed = (core.mutations.failed or 0) + 1
        core.mutations.lastResult = task.label .. " FAILED: " .. tostring(result)
        core.lastError = tostring(result)
        core.status = "ERROR: " .. core.mutations.lastResult
        log.error("[InventoryManager] " .. core.mutations.lastResult)
    end

    core.mutations.processing = false
    invoke_callback(task.onComplete, summary)
    return true
end

-- Process a small bounded burst per LateUpdateBehavior. This is intentionally NOT an
-- unbounded drain: large Apply All / pawn-clean batches are spread across game
-- updates so DD2 gets breathing room between native ItemManager mutations.
function core.processMutationQueue(maxSteps)
    maxSteps = math.max(1, math.floor(tonumber(maxSteps) or core.MUTATION_STEPS_PER_UPDATE or 1))
    local didWork = false

    for _ = 1, maxSteps do
        if not core.hasPendingMutations() then break end

        local failedBefore = core.mutations.failed or 0
        local worked = process_one_mutation_step()
        if not worked then break end

        didWork = true

        -- Preserve fail-fast semantics. Never continue into another queued operation
        -- in the same update after a native/Lua mutation failure.
        if (core.mutations.failed or 0) > failedBefore then
            break
        end
    end

    return didWork
end

local function safe_call(fn, fallback)
    local ok, value = pcall(fn)
    if ok then return value end
    return fallback
end

local function sdk_readonly_result(method, instance, ...)
    if not method then
        return { state = "missing", value = nil, error = "Method not resolved in current TypeDB." }
    end

    local args = { ... }
    local ok, value = pcall(function()
        return method:call(instance, table.unpack(args))
    end)
    if not ok then
        return { state = "error", value = nil, error = tostring(value) }
    end

    local normalized = value
    if value ~= nil then
        local t = type(value)
        if t ~= "boolean" and t ~= "number" and t ~= "string" then
            normalized = safe_call(function() return tonumber(value) end, nil)
                or safe_call(function() return tostring(value) end, "<value>")
        end
    end
    return { state = "ok", value = normalized, error = nil, raw = value }
end

local function sdk_skipped(reason)
    return { state = "skipped", value = nil, error = tostring(reason or "Not applicable.") }
end

local function safe_field(obj, name, fallback)
    if not obj then return fallback end
    local value = safe_call(function() return obj:get_field(name) end, nil)
    if value ~= nil then return value end
    -- REFramework value types (including StorageData on some return paths) can
    -- expose fields through the index metamethod rather than get_field().
    return safe_call(function() return obj[name] end, fallback)
end

local function field_flag(field, methodName)
    if not field then return nil end
    if methodName == "is_static" then
        return safe_call(function() return field:is_static() == true end, nil)
    end
    if methodName == "is_literal" then
        return safe_call(function() return field:is_literal() == true end, nil)
    end
    return nil
end

local function read_stack_field(field, param, fallbackName)
    if field then
        local isStatic = field_flag(field, "is_static") == true
        local value = safe_call(function() return field:get_data(isStatic and nil or param) end, nil)
        value = tonumber(value)
        if value ~= nil then return value end
    end
    return tonumber(safe_field(param, fallbackName, nil))
end

local function read_raw_stack_num(param)
    return read_stack_field(rawStackNumField, param, "_StackNum")
end

local function read_warehouse_max_stack(param)
    return read_stack_field(warehouseMaxStackNumField, param, "WarehouseMaxStackNum")
end

local function write_param_field(field, param, name, value, verifyReader)
    if not param then return false, "ItemCommonParam is unavailable." end

    -- Prefer REField:set_data so a static WarehouseMaxStackNum is written as a
    -- true static field (nil instance) instead of relying on an instance setter.
    -- Fall back to the ordinary managed-object field paths for TypeDB variants
    -- where set_data is unavailable or rejects this field representation.
    local ok, err = false, nil
    if field then
        local isStatic = field_flag(field, "is_static") == true
        ok, err = pcall(function() field:set_data(isStatic and nil or param, value) end)
    end
    if not ok then
        ok, err = pcall(function() param:set_field(name, value) end)
    end
    if not ok then
        ok, err = pcall(function() param[name] = value end)
    end
    if not ok then return false, tostring(err) end

    if verifyReader then
        local actual = tonumber(verifyReader(param))
        if actual ~= tonumber(value) then
            return false, string.format("%s write verification failed: expected %s, got %s.", name, tostring(value), tostring(actual))
        end
    end
    return true
end

local function write_raw_stack_num(param, value)
    return write_param_field(rawStackNumField, param, "_StackNum", value, read_raw_stack_num)
end


local function safe_full_type_name(obj)
    if not obj then return "" end
    return safe_call(function()
        local td = obj:get_type_definition()
        return td and td:get_full_name() or ""
    end, "")
end

-- ContextHolder has many AOT-specialized getContext() methods whose parameter
-- lists are identical and whose return types differ. Resolve the PawnDataContext
-- specialization by return type instead of relying on ambiguous name lookup.
local function find_method_by_return_type(typeDef, methodName, returnTypeName)
    if not typeDef then return nil end
    local methods = safe_call(function() return typeDef:get_methods() end, {}) or {}
    for _, method in pairs(methods) do
        local name = safe_call(function() return method:get_name() end, "")
        if name == methodName then
            local ret = safe_call(function() return method:get_return_type() end, nil)
            local full = ret and safe_call(function() return ret:get_full_name() end, "") or ""
            if full == returnTypeName then return method end
        end
    end
    return nil
end

local getPawnDataContextMethod = find_method_by_return_type(
    ContextHolderType,
    "getContext",
    "app.PawnDataContext")

local PawnDataContextRuntimeType = PawnDataContextType
    and safe_call(function() return PawnDataContextType:get_runtime_type() end, nil) or nil

local function normalize_pawn_text(value)
    if value == nil or type(value) == "number" or type(value) == "boolean" then return nil end
    local text = tostring(value)
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    -- DD2 can expose '-' while a hired pawn's real name is available through
    -- the PawnDataContext nickname field. Do not let UI placeholders become
    -- literal tab names.
    if text == "" or text == "-" or text == "--" or text == "---"
        or text == "Invalid" or text == "nil" then
        return nil
    end
    return text
end

local function get_pawn_data_context(character)
    if not character then return nil end

    -- Hired pawns expose their active PawnDataContext reliably through the
    -- GenerateInfo -> ContextHolder -> Contexts[runtime type] path. This is
    -- preferable to ContextHolder.getContext<T>() because the AOT-specialized
    -- overloads can be ambiguous through REFramework.
    if PawnDataContextRuntimeType then
        local generateInfo = safe_call(function() return character:get_GenerateInfo() end, nil)
        local holder = generateInfo and safe_call(function() return generateInfo:get_Context() end, nil) or nil
        local entry = holder and safe_call(function()
            return holder.Contexts and holder.Contexts[PawnDataContextRuntimeType] or nil
        end, nil) or nil
        local ctx = entry and safe_call(function() return entry:get_CurrentContext() end, nil) or nil
        if ctx then return ctx end

        -- Some pawn objects also cache the same holder directly.
        holder = safe_field(character, "CachedContextHolder", nil)
        entry = holder and safe_call(function()
            return holder.Contexts and holder.Contexts[PawnDataContextRuntimeType] or nil
        end, nil) or nil
        ctx = entry and safe_call(function() return entry:get_CurrentContext() end, nil) or nil
        if ctx then return ctx end
    end

    -- Use the direct context getter when the runtime-type dictionary is unavailable.
    if getPawnDataContextMethod then
        local holder = safe_call(function() return character:get_Context() end, nil)
        local ctx = holder and safe_call(function() return getPawnDataContextMethod:call(holder) end, nil) or nil
        if ctx then return ctx end
    end

    return nil
end

local function call_pawn_text_method(ctx, methodName)
    if not ctx or not PawnDataContextType then return nil end
    local method = PawnDataContextType:get_method(methodName .. "()")
    if not method then return nil end
    return normalize_pawn_text(safe_call(function() return method:call(ctx) end, nil))
end

local function read_pawn_text_field(ctx, fieldName)
    if not ctx then return nil end
    return normalize_pawn_text(safe_field(ctx, fieldName, nil))
end

local function get_pawn_display_name(character)
    local ctx = get_pawn_data_context(character)
    if not ctx then return nil end

    -- Prefer the pawn's real name. If DD2 exposes a placeholder instead, fall
    -- back to the nickname/moniker stored in the same live PawnDataContext.
    local name = normalize_pawn_text(safe_call(function() return ctx:get_Name() end, nil))
    if not name then name = read_pawn_text_field(ctx, "_Name") end
    if name then return name end

    for _, methodName in ipairs({ "get_Nickname", "get_NickName", "get_Moniker", "get_MonikerName" }) do
        local value = call_pawn_text_method(ctx, methodName)
        if value then return value end
    end
    for _, fieldName in ipairs({
        "Nickname", "_Nickname", "NickName", "_NickName",
        "Moniker", "_Moniker", "MonikerName", "_MonikerName",
    }) do
        local value = read_pawn_text_field(ctx, fieldName)
        if value then return value end
    end
    return nil
end

local function get_item_manager()
    return sdk.get_managed_singleton("app.ItemManager")
end

local function read_native_no_stack(param)
    if not param or not isNoStacItemMethod then return nil end
    local im = get_item_manager()
    if not im then return nil end
    local value = safe_call(function() return isNoStacItemMethod:call(im, param) end, nil)
    if value == nil then return nil end
    return value == true
end

local function is_decay_item(itemId)
    itemId = math.floor(tonumber(itemId) or 0)
    if itemId <= 0 or not isDecayItemMethod then return false end
    local im = get_item_manager()
    if not im then return false end
    return safe_call(function() return isDecayItemMethod:call(im, itemId) == true end, false)
end

local function get_character_manager()
    return sdk.get_managed_singleton("app.CharacterManager")
end

local function get_pawn_manager()
    return sdk.get_managed_singleton("app.PawnManager")
end

local function get_player()
    local cm = get_character_manager()
    if not cm then return nil end
    return safe_call(function() return cm:get_ManualPlayer() end, nil)
end

local function get_chara_id(character)
    if not character then return nil end
    return safe_call(function() return tonumber(character:get_CharaID()) end, nil)
end

local function managed_list_count(list)
    if not list then return 0 end
    local count = safe_call(function() return tonumber(list:get_field("_size")) end, nil)
    if count == nil then
        count = safe_call(function() return tonumber(list:call("get_Count")) end, nil)
    end
    return count or 0
end

local function managed_list_at(list, index)
    if not list or index == nil or index < 0 then return nil end
    local count = managed_list_count(list)
    if index >= count then return nil end

    local value = safe_call(function()
        local items = list:get_field("_items")
        return items and items:get_element(index) or nil
    end, nil)
    if value ~= nil then return value end

    return safe_call(function() return list[index] end, nil)
end

local function item_id_from_param(param)
    if not param then return nil end
    local id = tonumber(safe_field(param, "_Id", nil))
    if id ~= nil then return id end
    return safe_call(function() return tonumber(param:get_ItemId()) end, nil)
end

local function item_name_from_param(param, id)
    if not param then return "Item " .. tostring(id or "?") end
    local name = safe_call(function() return param:get_Name() end, nil)
    name = name and tostring(name) or nil
    if not name or name == "" then return "Item " .. tostring(id or "?") end
    return name
end

-- Normalized user-facing classification. Raw DD2 metadata stays on each catalog
-- entry for Item Analysis; the production UI only consumes the conservative
-- result below. Unknown values deliberately fall back instead of guessing.
local CATEGORY_NAMES = {
    [0] = "Other",
    [1] = "Material",
    [2] = "Quest",
    [3] = "Equipment",
}

local CATEGORY0_SUBTYPE_NAMES = {
    [1] = "Buff",
    [3] = "Special Item",
    [4] = "Quest",
    [6] = "Arrow",
    [7] = "Vocation Skill Tome",
    [8] = "Pawn Specialization Tome",
    [9] = "Magic Tome",
}

local EQUIP_CATEGORY_NAMES = {
    [0] = "Weapon",
    [1] = "Shield",
    [2] = "Head Armor",
    [3] = "Body Armor",
    [4] = "Leg Armor",
    [5] = "Cloak",
    [6] = "Ring",
    [7] = "Accessory",
}

local function classify_item_kind(item)
    if not item then return "<none>", "No item" end
    if item.isInvalid then return "Invalid", "DD2 name == Invalid" end
    if item.isCurrency then return "Currency", "Explicit currency ItemID" end

    -- Category 3 is the clean equipment bucket. The probe confirmed that its
    -- SubCategory is empty and EquipCategory 0..7 carries the useful subtype.
    if item.category == 3 then
        local equipName = EQUIP_CATEGORY_NAMES[item.equipCategory]
        if equipName then
            return equipName,
                string.format("Category 3 / EquipCategory %s", tostring(item.equipCategory))
        end
        return "Equipment",
            string.format("Category 3 / unknown EquipCategory %s", tostring(item.equipCategory))
    end

    -- Safety fallback for an equipment-shaped native record whose Category is
    -- unexpected. Do not manufacture a more specific subtype from partial data.
    if item.isEquipment then
        return "Equipment", "Native equipment parameter / DataType fallback"
    end

    if item.category == 1 then return "Material", "Category 1" end
    if item.category == 2 then return "Quest", "Category 2" end

    -- Category 0 is heterogeneous. Prefer explicit functional facts first, then
    -- only the raw subcategories we have actually observed and identified.
    if item.category == 0 then
        if item.isLantern then
            return item.isCurative and "Curative, Lantern" or "Lantern",
                "Category 0 / explicit lantern ItemID"
        end
        if item.isCurative and item.isDecay then
            return "Curative, Decay", "Category 0 / recovery metadata + decay list"
        end
        if item.isCurative then
            return "Curative", "Category 0 / recovery metadata"
        end
        if item.isDecay then
            return "Decay Item", "Category 0 / decay list"
        end

        local subtype = CATEGORY0_SUBTYPE_NAMES[item.subCategory]
        if subtype then
            return subtype,
                string.format("Category 0 / SubCategory %s", tostring(item.subCategory))
        end
        return "Other",
            string.format("Category 0 / unmapped SubCategory %s", tostring(item.subCategory))
    end

    return "Other",
        string.format("Unknown Category %s", tostring(item.category))
end

local function describe_item_kind(item)
    local kind = classify_item_kind(item)
    return kind
end

local function update_catalog_entry_search(entry)
    local kind, rule = classify_item_kind(entry)
    entry.kind = kind
    entry.classificationRule = rule
    entry.searchText = string.lower(table.concat({
        tostring(entry.id or ""),
        tostring(entry.name or ""),
        tostring(entry.kind or ""),
        tostring(entry.classificationRule or ""),
        tostring(entry.typeName or ""),
        tostring(entry.dataType or ""),
        tostring(entry.category or ""),
        tostring(entry.subCategory or ""),
        tostring(entry.equipCategory or ""),
        entry.isEquipment and "equipment" or "",
        entry.isCurative and "curative" or "",
        entry.isDecay and "decay perishable" or "",
        entry.isLantern and "lantern" or "",
        entry.isLanternFuel and "lantern fuel oil" or "",
        entry.isCurrency and "gold currency" or "",
        entry.nativeNoStack == true and "native nostac nostack nonstack" or "",
        entry.nativeNoStack == false and "native stackable" or "",
        entry.isInvalid and "invalid unused internal" or "",
    }, " "))
end

local function build_catalog_entry(param, canonicalId)
    local paramId = item_id_from_param(param)
    local id = math.floor(tonumber(canonicalId) or tonumber(paramId) or -1)
    if id < 0 then return nil end

    local typeName = safe_full_type_name(param)
    local dataType = tonumber(safe_field(param, "<DataType>k__BackingField", nil))
    local category = tonumber(safe_field(param, "_Category", nil))
    local subCategory = tonumber(safe_field(param, "_SubCategory", nil))
    local equipCategory = tonumber(safe_field(param, "_EquipCategory", nil))
    local weight = tonumber(safe_field(param, "_Weight", nil))
    local stackNum = read_raw_stack_num(param)
    local defaultStackNum = getDefaultStackNumMethod and safe_call(function()
        return tonumber(getDefaultStackNumMethod:call(param))
    end, nil) or nil
    local warehouseStackNum = read_warehouse_max_stack(param)

    -- getDefaultStackNum() mirrors _StackNum at the time of the call. Capture it
    -- before this mod changes anything and retain that snapshot for restoration.
    local vanillaCapture = defaultStackNum or stackNum
    if core.stack.vanillaById[id] == nil and vanillaCapture ~= nil then
        core.stack.vanillaById[id] = vanillaCapture
        core.stack.capturedCount = core.stack.capturedCount + 1
    end

    if core.stack.warehouseFieldStatic == nil and warehouseMaxStackNumField then
        core.stack.warehouseFieldStatic = field_flag(warehouseMaxStackNumField, "is_static") == true
    end
    if warehouseStackNum ~= nil then
        if core.stack.warehouseFieldStatic == true then
            if core.stack.warehouseVanillaGlobal == nil then
                core.stack.warehouseVanillaGlobal = warehouseStackNum
            end
        elseif core.stack.warehouseVanillaById[id] == nil then
            core.stack.warehouseVanillaById[id] = warehouseStackNum
        end
    end

    local nativeNoStack = core.stack.nativeNoStackById[id]
    if nativeNoStack == nil then
        nativeNoStack = read_native_no_stack(param)
        if nativeNoStack ~= nil then
            core.stack.nativeNoStackById[id] = nativeNoStack
        end
    end

    local vanillaStackNum = core.stack.vanillaById[id] or stackNum
    local vanillaWarehouseStackNum = core.stack.warehouseFieldStatic == true
        and core.stack.warehouseVanillaGlobal
        or core.stack.warehouseVanillaById[id]
        or warehouseStackNum
    local useEffect = tonumber(safe_field(param, "_UseEffect", nil))
    local healWhiteHp = tonumber(safe_field(param, "_HealWhiteHp", nil)) or 0
    local healBlackHp = tonumber(safe_field(param, "_HealBlackHp", nil)) or 0
    local healStamina = tonumber(safe_field(param, "_HealStamina", nil)) or 0
    local removeStatus = tonumber(safe_field(param, "_RemoveStatus", nil)) or 0

    local isEquipment = (dataType == 2 or dataType == 3
        or typeName == "app.ItemWeaponParam"
        or typeName == "app.ItemArmorParam")
    local hasCurativeUseEffect = (useEffect == 1 or useEffect == 2 or useEffect == 3)
    local hasRecoveryValue = (healWhiteHp ~= 0 or healBlackHp ~= 0 or healStamina ~= 0)
    local hasStatusRemoval = (removeStatus ~= 0)
    local isCurative = (not isEquipment and typeName == "app.ItemDataParam"
        and (hasCurativeUseEffect or hasRecoveryValue or hasStatusRemoval))

    -- Live probing confirmed ItemDataParam:get_Name() already
    -- resolves correctly before a save is loaded. "Invalid" therefore means DD2
    -- itself reports that record as Invalid; it is not a temporary menu state.
    local name = item_name_from_param(param, id)
    local isDecay = is_decay_item(id)

    local entry = {
        id = id,
        paramId = paramId,
        name = name,
        nameResolved = true,
        typeName = typeName,
        dataType = dataType,
        category = category,
        subCategory = subCategory,
        equipCategory = equipCategory,
        weight = weight,
        stackNum = stackNum,
        runtimeStackNum = stackNum,
        vanillaStackNum = vanillaStackNum,
        capturedDefaultStackNum = defaultStackNum,
        warehouseStackNum = warehouseStackNum,
        runtimeWarehouseStackNum = warehouseStackNum,
        vanillaWarehouseStackNum = vanillaWarehouseStackNum,
        nativeNoStack = nativeNoStack,
        useEffect = useEffect,
        healWhiteHp = healWhiteHp,
        healBlackHp = healBlackHp,
        healStamina = healStamina,
        removeStatus = removeStatus,
        isEquipment = isEquipment,
        isCurative = isCurative,
        isDecay = isDecay,
        isLantern = LANTERN_IDS[id] == true,
        isLanternFuel = id == LANTERN_FUEL_ID,
        isCurrency = id == GOLD_ID,
        isInvalid = name == "Invalid",
        param = param,
    }
    update_catalog_entry_search(entry)
    return entry
end

local function rebuild_default_pawn_transfer_ids()
    local defaults = {}
    for _, item in ipairs(core.catalogAll or {}) do
        local allowed =
            item.id > 0
            and not item.isInvalid
            and item.category == 1
            and item.subCategory ~= 4
            and not item.isEquipment
            and not item.isCurative
            and not item.isDecay
            and not item.isCurrency
            and not item.isLantern
            and not item.isLanternFuel
            and item.id ~= WAKESHARD_ID
        if allowed then defaults[item.id] = true end
    end
    core.pawnCleaner.defaultIds = defaults
end

local function classify_catalog(all)
    local catalog, byId, invalid = {}, {}, {}
    local valid, invalidCount = 0, 0

    for _, entry in ipairs(all or {}) do
        if entry.isInvalid then
            invalidCount = invalidCount + 1
            table.insert(invalid, entry)
        elseif byId[entry.id] == nil then
            valid = valid + 1
            byId[entry.id] = entry
            table.insert(catalog, entry)
        end
    end

    table.sort(invalid, function(a, b)
        if a.id == b.id then return tostring(a.typeName) < tostring(b.typeName) end
        return a.id < b.id
    end)
    table.sort(catalog, function(a, b)
        if a.name == b.name then return a.id < b.id end
        return string.lower(a.name) < string.lower(b.name)
    end)

    return catalog, byId, invalid, valid, invalidCount
end

function core.ensureCatalog(force, quiet)
    if core.catalogReady and not force then return true end

    local function catalog_fail(message)
        if not quiet then set_error(message) end
        return false
    end

    local im = get_item_manager()
    if not im then
        return catalog_fail("app.ItemManager is not ready; Item DB cache was not changed.")
    end

    local dict = safe_call(function() return im:get_ItemDataDict() end, nil)
    if not dict then dict = safe_field(im, "_ItemDataDict", nil) end
    if not dict then
        return catalog_fail("Could not resolve ItemManager item-data dictionary; previous Item DB cache was preserved.")
    end

    -- The probe confirmed Dictionary enumeration works. We still traverse the
    -- backing entries directly because the dictionary key is immediately
    -- available as the canonical ItemID for each cached ItemDataParam.
    local entries = safe_field(dict, "_entries", nil)
    if not entries then
        return catalog_fail("Item-data dictionary backing entries are unavailable; previous cache was preserved.")
    end

    local all, allById = {}, {}
    local stats = {
        enumerated = 0,
        parsed = 0,
        valid = 0,
        invalid = 0,
        duplicateIds = 0,
        idMismatches = 0,
        parseErrors = 0,
    }

    for _, slot in pairs(entries) do
        local param = slot and safe_field(slot, "value", nil) or nil
        if param then
            stats.enumerated = stats.enumerated + 1
            local canonicalId = tonumber(safe_field(slot, "key", nil))
            local okEntry, entry = pcall(build_catalog_entry, param, canonicalId)

            if okEntry and entry then
                stats.parsed = stats.parsed + 1
                if entry.paramId ~= nil and canonicalId ~= nil
                        and tonumber(entry.paramId) ~= tonumber(canonicalId) then
                    stats.idMismatches = stats.idMismatches + 1
                end

                table.insert(all, entry)
                if allById[entry.id] == nil then
                    allById[entry.id] = entry
                else
                    stats.duplicateIds = stats.duplicateIds + 1
                end
            elseif not okEntry then
                stats.parseErrors = stats.parseErrors + 1
                log.error("[InventoryManager] Item DB record skipped: " .. tostring(entry))
            end
        end
    end

    if stats.parsed == 0 then
        return catalog_fail("Item DB rebuild produced zero parsed records; previous cache was preserved.")
    end

    table.sort(all, function(a, b)
        if a.id == b.id then return tostring(a.typeName) < tostring(b.typeName) end
        return a.id < b.id
    end)

    local catalog, byId, invalid, valid, invalidCount = classify_catalog(all)
    stats.valid = valid
    stats.invalid = invalidCount

    core.catalogAll = all
    core.catalogAllById = allById
    core.catalog = catalog
    core.catalogById = byId
    core.catalogInvalid = invalid
    core.catalogStats = stats
    core.catalogReady = true

    rebuild_default_pawn_transfer_ids()

    if not quiet then
        set_status(string.format(
            "Item DB cached: %d records (%d named, %d Invalid).",
            stats.parsed,
            stats.valid,
            stats.invalid))
    end
    return true
end

function core.getCatalogEntry(itemId, includeInvalid)
    itemId = math.floor(tonumber(itemId) or -1)
    if itemId < 0 then return nil end
    if includeInvalid then
        return core.catalogAllById[itemId]
    end
    return core.catalogById[itemId]
end

function core.getCatalogStats()
    return {
        ready = core.catalogReady == true,
        enumerated = tonumber(core.catalogStats.enumerated) or 0,
        parsed = tonumber(core.catalogStats.parsed) or 0,
        valid = tonumber(core.catalogStats.valid) or 0,
        invalid = tonumber(core.catalogStats.invalid) or 0,
        duplicateIds = tonumber(core.catalogStats.duplicateIds) or 0,
        idMismatches = tonumber(core.catalogStats.idMismatches) or 0,
        parseErrors = tonumber(core.catalogStats.parseErrors) or 0,
    }
end

local function pawn_cleaner_default_rule(item)
    local enabled = item ~= nil and core.pawnCleaner.defaultIds[item.id] == true
    return {
        enabled = enabled,
        mode = enabled and "transfer" or "keep",
        destination = enabled and "Storage" or nil,
        keep = 0,
        source = "Default",
        isOverride = false,
    }
end

function core.getPawnCleanerRule(itemId)
    itemId = math.floor(tonumber(itemId) or -1)
    local item = core.catalogAllById[itemId]
    if not item then
        return { enabled = false, mode = "keep", destination = nil, keep = 0, source = "Unknown", isOverride = false }
    end
    if item.nameResolved and item.isInvalid then
        return { enabled = false, mode = "keep", destination = nil, keep = 0, source = "Invalid", isOverride = false }
    end

    local override = core.pawnCleaner.overrides[itemId]
    if override then
        local mode = override.mode == "transfer" and "transfer" or "ignore"
        local destination = tostring(override.destination or "Storage")
        if destination ~= "Player" then destination = "Storage" end
        return {
            enabled = mode == "transfer",
            mode = mode,
            destination = mode == "transfer" and destination or nil,
            keep = mode == "transfer" and math.max(0, math.floor(tonumber(override.keep) or 0)) or 0,
            source = "Override",
            isOverride = true,
        }
    end

    return pawn_cleaner_default_rule(item)
end


function core.setPawnCleanerOverrides(itemIds, mode, destination, keep)
    if type(itemIds) ~= "table" then return false, "No ItemIDs were supplied.", 0 end

    mode = tostring(mode or "")
    if mode ~= "transfer" and mode ~= "ignore" then
        return false, "Override mode must be Transfer or Ignore.", 0
    end

    destination = tostring(destination or "Storage")
    if destination ~= "Player" then destination = "Storage" end
    keep = math.max(0, math.floor(tonumber(keep) or 0))

    local changed = 0
    for key, active in pairs(itemIds) do
        if active then
            local itemId = math.floor(tonumber(key) or -1)
            if itemId > 0 and core.catalogAllById[itemId] then
                core.pawnCleaner.overrides[itemId] = {
                    mode = mode,
                    destination = destination,
                    keep = mode == "transfer" and keep or 0,
                }
                changed = changed + 1
            end
        end
    end

    if changed == 0 then return false, "No valid selected ItemIDs were found.", 0 end
    save_config()
    core.pawnCleaner.baseline = nil
    return true, nil, changed
end

function core.clearPawnCleanerRules(itemIds)
    if type(itemIds) ~= "table" then return false, "No ItemIDs were supplied.", 0 end
    local changed = 0
    for key, active in pairs(itemIds) do
        if active then
            local itemId = math.floor(tonumber(key) or -1)
            if itemId > 0 and core.pawnCleaner.overrides[itemId] ~= nil then
                core.pawnCleaner.overrides[itemId] = nil
                changed = changed + 1
            end
        end
    end
    if changed > 0 then
        save_config()
        core.pawnCleaner.baseline = nil
    end
    return true, nil, changed
end

function core.clearPawnCleanerOverrides()
    core.pawnCleaner.overrides = {}
    save_config()
    core.pawnCleaner.baseline = nil
    return true
end

function core.getPawnCleanerDefaultCount()
    local count = 0
    for _, enabled in pairs(core.pawnCleaner.defaultIds or {}) do
        if enabled then count = count + 1 end
    end
    return count
end

function core.setPawnCleanerControlCallback(callback)
    core.pawnCleaner.controlCallback = type(callback) == "function" and callback or nil
end

local function notify_pawn_cleaner_control()
    local callback = core.pawnCleaner.controlCallback
    if type(callback) ~= "function" then return end
    local ok, err = pcall(callback, core.pawnCleaner.enabled == true)
    if not ok then
        log.error("[InventoryManager] Pawn-cleaner worker callback failed: " .. tostring(err))
    end
end

function core.setPawnCleanerEnabled(enabled)
    core.pawnCleaner.enabled = enabled == true
    core.pawnCleaner.baseline = nil
    core.combat.resetRuntime()
    core.pawnCleaner.status = core.pawnCleaner.enabled
        and "Pawn auto-clean enabled; the next pawn inventory event establishes a fresh baseline."
        or "Pawn auto-clean disabled."
    save_config()
    notify_pawn_cleaner_control()
    return core.pawnCleaner.enabled
end


function core.getPawnCleanerStatus()
    local overrideCount = 0
    for _ in pairs(core.pawnCleaner.overrides or {}) do overrideCount = overrideCount + 1 end
    return {
        enabled = core.pawnCleaner.enabled == true,
        pollTicks = core.pawnCleaner.pollTicks,
        status = core.pawnCleaner.status,
        defaultCount = core.getPawnCleanerDefaultCount(),
        overrideCount = overrideCount,
        lastDetected = core.pawnCleaner.lastDetected or 0,
        lastQueued = core.pawnCleaner.lastQueued or 0,
        completedBatches = core.pawnCleaner.completedBatches or 0,
        completedRefills = core.pawnCleaner.completedRefills or 0,
        lastRefillQueued = core.pawnCleaner.lastRefillQueued or 0,
        refillStatus = core.pawnCleaner.refillStatus or "",
        retrieval = core.combat.getStatus(),
    }
end

function core.getPawnRetrievalModeChoices()
    return core.combat.getModeChoices()
end

function core.getPawnRetrievalModeIndex()
    return core.combat.getModeIndex()
end

function core.setPawnRetrievalMode(value)
    local mode = core.combat.setMode(value)
    core.pawnCleaner.refillStatus = "Pawn auto-retrieval is idle."
    save_config()
    return mode
end

function core.getPawnRetrievalStatus()
    return core.combat.getStatus()
end

local function player_cleaner_default_rule(item)
    local enabled = item ~= nil and core.playerCleaner.defaultIds[item.id] == true
    return {
        enabled = enabled,
        mode = enabled and "transfer" or "keep",
        destination = enabled and "Storage" or nil,
        keep = 0,
        source = "Default",
        isOverride = false,
    }
end

function core.getPlayerCleanerRule(itemId)
    itemId = math.floor(tonumber(itemId) or -1)
    local item = core.catalogAllById[itemId]
    if not item then
        return { enabled = false, mode = "keep", destination = nil, keep = 0, source = "Unknown", isOverride = false }
    end
    if item.nameResolved and item.isInvalid then
        return { enabled = false, mode = "keep", destination = nil, keep = 0, source = "Invalid", isOverride = false }
    end

    local override = core.playerCleaner.overrides[itemId]
    if override then
        local mode = override.mode == "transfer" and "transfer" or "ignore"
        return {
            enabled = mode == "transfer",
            mode = mode,
            destination = mode == "transfer" and "Storage" or nil,
            keep = mode == "transfer" and math.max(0, math.floor(tonumber(override.keep) or 0)) or 0,
            source = "Override",
            isOverride = true,
        }
    end

    return player_cleaner_default_rule(item)
end


function core.setPlayerCleanerOverrides(itemIds, mode, keep)
    if type(itemIds) ~= "table" then return false, "No ItemIDs were supplied.", 0 end

    mode = tostring(mode or "")
    if mode ~= "transfer" and mode ~= "ignore" then
        return false, "Override mode must be Transfer or Ignore.", 0
    end
    keep = math.max(0, math.floor(tonumber(keep) or 0))

    local changed = 0
    for key, active in pairs(itemIds) do
        if active then
            local itemId = math.floor(tonumber(key) or -1)
            if itemId > 0 and core.catalogAllById[itemId] then
                core.playerCleaner.overrides[itemId] = {
                    mode = mode,
                    destination = "Storage",
                    keep = mode == "transfer" and keep or 0,
                }
                changed = changed + 1
            end
        end
    end

    if changed == 0 then return false, "No valid selected ItemIDs were found.", 0 end
    save_config()
    core.playerCleaner.baseline = nil
    return true, nil, changed
end

function core.clearPlayerCleanerRules(itemIds)
    if type(itemIds) ~= "table" then return false, "No ItemIDs were supplied.", 0 end
    local changed = 0
    for key, active in pairs(itemIds) do
        if active then
            local itemId = math.floor(tonumber(key) or -1)
            if itemId > 0 and core.playerCleaner.overrides[itemId] ~= nil then
                core.playerCleaner.overrides[itemId] = nil
                changed = changed + 1
            end
        end
    end
    if changed > 0 then
        save_config()
        core.playerCleaner.baseline = nil
    end
    return true, nil, changed
end

function core.clearPlayerCleanerOverrides()
    core.playerCleaner.overrides = {}
    save_config()
    core.playerCleaner.baseline = nil
    return true
end

function core.getPlayerCleanerDefaultCount()
    local count = 0
    for _, enabled in pairs(core.playerCleaner.defaultIds or {}) do
        if enabled then count = count + 1 end
    end
    return count
end

function core.setPlayerCleanerControlCallback(callback)
    core.playerCleaner.controlCallback = type(callback) == "function" and callback or nil
end

local function notify_player_cleaner_control()
    local callback = core.playerCleaner.controlCallback
    if type(callback) ~= "function" then return end
    local ok, err = pcall(callback, core.playerCleaner.enabled == true)
    if not ok then
        log.error("[InventoryManager] Player-cleaner worker callback failed: " .. tostring(err))
    end
end

function core.setPlayerCleanerEnabled(enabled)
    core.playerCleaner.enabled = enabled == true
    core.playerCleaner.baseline = nil
    core.playerCleaner.status = core.playerCleaner.enabled
        and "Player auto-clean enabled; the next Player inventory event establishes a fresh baseline."
        or "Player auto-clean disabled."
    save_config()
    notify_player_cleaner_control()
    return core.playerCleaner.enabled
end

function core.getPlayerCleanerStatus()
    local overrideCount = 0
    for _ in pairs(core.playerCleaner.overrides or {}) do overrideCount = overrideCount + 1 end
    return {
        enabled = core.playerCleaner.enabled == true,
        status = core.playerCleaner.status,
        defaultCount = core.getPlayerCleanerDefaultCount(),
        overrideCount = overrideCount,
        lastDetected = core.playerCleaner.lastDetected or 0,
        lastQueued = core.playerCleaner.lastQueued or 0,
        completedBatches = core.playerCleaner.completedBatches or 0,
    }
end

local function refresh_runtime_stack(entry)
    if not entry or not entry.param then return nil end
    local raw = read_raw_stack_num(entry.param)
    local warehouse = read_warehouse_max_stack(entry.param)
    entry.runtimeStackNum = raw
    entry.stackNum = raw
    entry.runtimeWarehouseStackNum = warehouse
    entry.warehouseStackNum = warehouse
    return raw
end

function core.refreshRuntimeStacks()
    if not core.ensureCatalog(false) then return false end
    for _, entry in ipairs(core.catalog) do refresh_runtime_stack(entry) end
    set_status("Runtime actor/warehouse stack metadata refreshed.")
    return true
end

local function read_owner_stack_limit(item, ownerId)
    if not item or not item.param or ownerId == nil or not getStackNumMethod then return nil end
    local ok, value = pcall(function()
        return getStackNumMethod:call(item.param, ownerId)
    end)
    if not ok then return nil end
    value = tonumber(value)
    if value == nil or value <= 0 then return nil end
    return math.floor(value)
end

function core.getNativeNoStack(itemOrId)
    local item = itemOrId
    if type(itemOrId) == "number" then
        item = core.catalogAllById[itemOrId] or core.catalogById[itemOrId]
    end
    if not item then return nil end
    local cached = core.stack.nativeNoStackById[item.id]
    if cached ~= nil then return cached end
    if item.nativeNoStack ~= nil then return item.nativeNoStack end
    return nil
end

function core.getNativeStackLimit(item, ownerId)
    if not item then return nil end
    if item.isCurrency then return GOLD_CAP end

    if ownerId ~= nil then
        local native = read_owner_stack_limit(item, ownerId)
        if native ~= nil then return native end
    end

    if ownerId == STORAGE_ID then
        return read_warehouse_max_stack(item.param)
            or item.runtimeWarehouseStackNum
            or item.vanillaWarehouseStackNum
            or core.stack.warehouseVanillaGlobal
            or 999
    end

    return read_raw_stack_num(item.param)
        or item.runtimeStackNum
        or item.vanillaStackNum
        or core.stack.vanillaById[item.id]
end

function core.getEffectiveStack(item, ownerId)
    if not item then return nil end
    if item.isCurrency then return GOLD_CAP end

    -- DD2 exposes its own no-stack classifier. Use the pre-override snapshot so
    -- changing _StackNum cannot redefine an item's structural stackability.
    if core.isInstanceBacked(item) then return 1 end

    local native = core.getNativeStackLimit(item, ownerId)
    if native ~= nil then return native end
    return item.runtimeStackNum ~= nil and item.runtimeStackNum or item.stackNum
end

function core.isInstanceBacked(itemOrId)
    local item = itemOrId
    if type(itemOrId) == "number" then
        item = core.catalogAllById[itemOrId] or core.catalogById[itemOrId]
    end
    if not item or item.isCurrency then return false end
    if item.isEquipment or item.isLantern then return true end

    local nativeNoStack = core.getNativeNoStack(item)
    if nativeNoStack == true then return true end

    -- Track false results too, but until live probe output confirms exactly what
    -- Capcom means by isNoStacItem(false), do not let a false result relax an
    -- existing singleton safeguard. The captured pre-override _StackNum remains
    -- the conservative fallback for stack==1 edge cases.
    local vanilla = core.stack.vanillaById[item.id]
        or item.vanillaStackNum
        or item.stackNum
    vanilla = tonumber(vanilla)
    return vanilla ~= nil and vanilla <= 1
end


-- Gear, lanterns, and both known Sealing Phial ItemIDs preserve exact
-- StorageData identity. Vanilla can report an occupied Phial as ItemID 90, so
-- neither 90 nor 91 is treated as fungible until the occupancy field is mapped.
function core.requiresIdentityTransfer(itemOrId)
    local item = itemOrId
    if type(itemOrId) == "number" then
        item = core.catalogAllById[itemOrId] or core.catalogById[itemOrId]
    end
    if not item then return false end
    return item.isEquipment == true
        or item.isLantern == true
        or SEALING_PHIAL_IDS[tonumber(item.id)] == true
end

function core.getStackDisplay(item, ownerId)
    local value = core.getEffectiveStack(item, ownerId)
    if value == nil then return "?" end
    if item and item.isCurrency then return "999,999,999" end
    return tostring(value)
end


local function refresh_stack_enabled_state()
    core.stack.enabled = core.stack.mode == "Global"
        or (core.stack.mode == "Scoped" and (core.stack.actorEnabled or core.stack.storageEnabled))
end

function core.setStackMode(mode)
    mode = tostring(mode or "Vanilla")
    if mode ~= "Vanilla" and mode ~= "Global" and mode ~= "Scoped" then mode = "Vanilla" end
    core.stack.mode = mode
    refresh_stack_enabled_state()
    return core.stack.mode
end

function core.setPendingStackLimit(value)
    local limit = normalize_stack_limit(value, core.stack.globalLimit or 9999)
    core.stack.globalLimit = limit
end

function core.setPendingActorStackLimit(value)
    core.stack.actorLimit = normalize_stack_limit(value, core.stack.actorLimit or 99)
end

function core.setPendingStorageStackLimit(value)
    core.stack.storageLimit = normalize_stack_limit(value, core.stack.storageLimit or 999)
end

function core.setActorStackOverrideEnabled(enabled)
    core.stack.actorEnabled = enabled == true
    if core.stack.mode ~= "Global" then core.stack.mode = "Scoped" end
    refresh_stack_enabled_state()
end

function core.setStorageStackOverrideEnabled(enabled)
    core.stack.storageEnabled = enabled == true
    if core.stack.mode ~= "Global" then core.stack.mode = "Scoped" end
    refresh_stack_enabled_state()
end

local function desired_actor_stack(entry)
    local vanilla = tonumber(core.stack.vanillaById[entry.id])
        or tonumber(entry.vanillaStackNum)
        or tonumber(entry.stackNum)
        or 1
    if core.stack.mode == "Global" then
        return normalize_stack_limit(core.stack.globalLimit, vanilla)
    end
    -- Scoped mode no longer mutates _StackNum. DD2's getStackNum(owner) query
    -- is the only place that can distinguish an actor owner from Storage. Keep
    -- the raw native field at its captured vanilla value and resolve scoped
    -- actor/storage limits in the getStackNum hook instead.
    return math.max(1, math.floor(vanilla))
end


function core.resolveStackOverride(param, ownerId)
    if not param or not core.stack or core.stack.mode == "Vanilla" then return nil end

    local id = math.floor(tonumber(item_id_from_param(param)) or -1)
    if id < 0 then return nil end
    local item = core.catalogAllById[id] or core.catalogById[id]
    if not item or item.isCurrency or core.isInstanceBacked(item) then return nil end

    if core.stack.mode == "Global" then
        return normalize_stack_limit(core.stack.globalLimit, nil)
    end

    if core.stack.mode ~= "Scoped" then return nil end
    ownerId = tonumber(ownerId)
    local isStorage = ownerId == STORAGE_ID or ownerId == -1
    if isStorage then
        if core.stack.storageEnabled then
            return normalize_stack_limit(core.stack.storageLimit, nil)
        end
        return nil
    end

    if core.stack.actorEnabled then
        return normalize_stack_limit(core.stack.actorLimit, nil)
    end
    return nil
end


local function apply_native_warehouse_stack()
    -- Current DD2 exposes WarehouseMaxStackNum as a static literal constant. It
    -- is not an independent mutable per-item warehouse limit. Scoped storage
    -- limits are therefore resolved through ItemCommonParam:getStackNum(owner)
    -- and this function intentionally performs no WarehouseMaxStackNum writes.
    return 0, 0, nil
end

function core.applyStackConfiguration()
    if not core.ensureCatalog(false) then return false end

    -- The catalog capture is the restore source of truth. getDefaultStackNum()
    -- simply reflects mutable _StackNum, so no post-mutation getter is trusted as
    -- a vanilla source. WarehouseMaxStackNum is captured independently as well.
    local actorModified, actorFailed = 0, 0
    for _, entry in ipairs(core.catalog or {}) do
        if entry.param and not core.isInstanceBacked(entry) and not entry.isCurrency then
            local desired = desired_actor_stack(entry)
            local current = read_raw_stack_num(entry.param)
            if tonumber(current) ~= tonumber(desired) then
                local ok = write_raw_stack_num(entry.param, desired)
                if ok then
                    entry.runtimeStackNum = desired
                    entry.stackNum = desired
                    actorModified = actorModified + 1
                else
                    actorFailed = actorFailed + 1
                end
            end
        end
    end

    local warehouseModified, warehouseFailed, warehouseErr = apply_native_warehouse_stack()

    refresh_stack_enabled_state()
    core.stack.appliedCount = actorModified + warehouseModified
    save_config()

    local actorText = "Vanilla"
    local storageText = "Vanilla"
    if core.stack.mode == "Global" then
        actorText = tostring(core.stack.globalLimit)
        storageText = actorText
    elseif core.stack.mode == "Scoped" then
        if core.stack.actorEnabled then actorText = tostring(core.stack.actorLimit) end
        if core.stack.storageEnabled then storageText = tostring(core.stack.storageLimit) end
    end

    local message = string.format(
        "Stack configuration applied: Player/Pawn=%s, Storage/Warehouse=%s; raw actor writes=%d, scoped resolver active=%s.",
        actorText, storageText, actorModified, tostring(core.stack.mode == "Scoped"))
    if actorFailed > 0 or warehouseFailed > 0 then
        message = message .. string.format(" Failures: actor=%d, warehouse=%d%s.",
            actorFailed, warehouseFailed,
            warehouseErr and (" (" .. tostring(warehouseErr) .. ")") or "")
    end
    set_status(message)
    core.debugLog("Basic", "Stack apply mode=%s actorModified=%d actorFailed=%d warehouseModified=%d warehouseFailed=%d", tostring(core.stack.mode), actorModified, actorFailed, warehouseModified, warehouseFailed)
    return actorFailed == 0 and warehouseFailed == 0
end


local function restore_native_warehouse_stack()
    -- WarehouseMaxStackNum is not mutated at runtime.
    return 0, 0
end

function core.restoreVanillaStacks()
    if not core.ensureCatalog(false) then return false end

    local restored, failed = 0, 0
    for _, entry in ipairs(core.catalogAll or {}) do
        local vanilla = entry and core.stack.vanillaById[entry.id] or nil
        if entry and entry.param and vanilla ~= nil then
            local current = read_raw_stack_num(entry.param)
            if tonumber(current) ~= tonumber(vanilla) then
                local ok = write_raw_stack_num(entry.param, vanilla)
                if ok then
                    entry.runtimeStackNum = vanilla
                    entry.stackNum = vanilla
                    entry.vanillaStackNum = vanilla
                    restored = restored + 1
                else
                    failed = failed + 1
                end
            end
        end
    end

    local warehouseRestored, warehouseFailed = restore_native_warehouse_stack()
    restored = restored + warehouseRestored
    failed = failed + warehouseFailed

    core.stack.mode = "Vanilla"
    core.stack.enabled = false
    core.stack.appliedCount = 0
    save_config()
    set_status(string.format(
        "Restored captured vanilla stack fields: %d write(s) restored, %d failed.",
        restored, failed))
    return failed == 0
end

-- Script Reset is an explicit teardown boundary for this mod. Runtime stack
-- edits must not survive that boundary: otherwise the next Lua state can see
-- our modified _StackNum / WarehouseMaxStackNum values and mistake them for
-- vanilla. Use only the startup snapshots captured before this mod wrote either.
function core.restoreStacksForScriptReset()
    local restored = 0
    local failed = 0

    for _, entry in ipairs(core.catalogAll or {}) do
        local vanilla = entry and core.stack.vanillaById[entry.id] or nil
        if entry and entry.param and vanilla ~= nil then
            local current = read_raw_stack_num(entry.param)
            if tonumber(current) ~= tonumber(vanilla) then
                local ok = write_raw_stack_num(entry.param, vanilla)
                if ok then
                    entry.runtimeStackNum = vanilla
                    entry.stackNum = vanilla
                    entry.vanillaStackNum = vanilla
                    restored = restored + 1
                else
                    failed = failed + 1
                end
            end
        end
    end

    local warehouseRestored, warehouseFailed = restore_native_warehouse_stack()
    restored = restored + warehouseRestored
    failed = failed + warehouseFailed

    -- Reset Scripts restores DD2's native fields before this Lua state dies so
    -- the replacement state can capture genuine vanilla values. Preserve the
    -- user's configured StackMode/limits in InventoryManager.json; the new Lua
    -- state will re-apply that persisted configuration after its catalog is ready.
    core.stack.appliedCount = 0
    core.debugLog("Basic", "Script reset restored native stack fields; preserved configured mode=%s actorEnabled=%s storageEnabled=%s", tostring(core.stack.mode), tostring(core.stack.actorEnabled), tostring(core.stack.storageEnabled))

    if failed > 0 then
        log.error(string.format(
            "[InventoryManager] Script reset restored %d stack-field writes; %d restores failed.",
            restored, failed))
    else
        log.info(string.format(
            "[InventoryManager] Script reset restored %d captured stack-field writes to vanilla.",
            restored))
    end

    return failed == 0, restored, failed
end

function core.reapplyConfiguredStacks()
    if not core.stack.enabled then return true end
    return core.applyStackConfiguration()
end

function core.getPlayerId()
    -- Gate on the live player object so startup behavior stays unchanged, but use
    -- ItemDefine.ArisenCharaId as the authoritative owner identity. This avoids a
    -- transient/wrong Character:get_CharaID() value routing inventory mutations.
    if not get_player() then return nil end
    return ARISEN_ID
end

function core.getCount(itemId, ownerId)
    if not getHaveNumMethod then return nil, "getHaveNum method was not found" end
    local im = get_item_manager()
    if not im then return nil, "ItemManager not ready" end
    local ok, count = pcall(function()
        return getHaveNumMethod:call(im, itemId, ownerId)
    end)
    if not ok then return nil, tostring(count) end
    return tonumber(count) or 0
end

function core.isDecayItem(itemId)
    return is_decay_item(itemId)
end

local function get_storage_master_list(ownerId)
    if ownerId == nil or not getStorageMasterListMethod then return nil end
    local im = get_item_manager()
    if not im then return nil end
    return safe_call(function() return getStorageMasterListMethod:call(im, ownerId) end, nil)
end

local function get_storage_master_row(itemId, ownerId, storageId)
    local list = get_storage_master_list(ownerId)
    if not list then return nil end

    for i = 0, managed_list_count(list) - 1 do
        local row = managed_list_at(list, i)
        if row then
            local rowItemId = storage_master_row_item_id(row)
            if rowItemId == itemId then
                if storageId == nil or storage_master_row_storage_id(row) == storageId then
                    return row
                end
            end
        end
    end
    return nil
end

local function get_storage_master_param(row)
    if not row then return nil end
    local param = safe_call(function() return row:get_Param() end, nil)
    if param ~= nil then return param end
    return safe_field(row, "_Param", nil)
end

function core.getLiveItemRecords(itemId, ownerId)
    itemId = math.floor(tonumber(itemId) or -1)
    if itemId < 0 or ownerId == nil then return {} end
    local list = get_storage_master_list(ownerId)
    if not list then return {} end
    local records = {}
    for i = 0, managed_list_count(list) - 1 do
        local row = managed_list_at(list, i)
        if row and storage_master_row_item_id(row) == itemId then
            table.insert(records, {
                itemId = itemId,
                storageId = storage_master_row_storage_id(row),
                quantity = storage_master_row_quantity(row),
                charaId = storage_master_row_chara_id(row),
                isEquipped = storage_master_row_is_equipped(row),
                equipSlot = storage_master_row_equip_slot(row),
                updateIndex = storage_master_row_update_index(row),
                arisenEquipNo = storage_master_row_arisen_equip_no(row),
                recordIndex = i,
            })
        end
    end
    table.sort(records, function(a,b)
        local ai, bi = tonumber(a.storageId), tonumber(b.storageId)
        if ai ~= nil and bi ~= nil and ai ~= bi then return ai < bi end
        return (tonumber(a.recordIndex) or 0) < (tonumber(b.recordIndex) or 0)
    end)
    return records
end

-- Read-only data used by the main Inventory Item Info panel. This deliberately
-- keeps identity/ownership UI out of the result: the Inventory sub-tab already
-- supplies that context. ItemDataParam (or its derived Weapon/Armor Param) is the
-- canonical base definition; StorageMasterData supplies per-instance enhancement
-- and equipment-ability state.
local ENHANCE_TYPE_LABELS = {
    [0] = "Vernworth",
    [1] = "Battahl",
    [2] = "Elf",
    [3] = "Dragon",
    [4] = "Unlimit",
}

local function info_number(value)
    if value == nil then return nil end
    local n = tonumber(value)
    if n ~= nil then return n end
    return tonumber(safe_field(value, "value__", nil))
end

local function info_field(obj, name)
    if obj == nil then return nil end
    local value = safe_field(obj, name, nil)
    if value == nil then return nil end
    return info_number(value) or value
end

local function info_enhance_label(value)
    local n = info_number(value)
    if n == nil then return tostring(value or "?") end
    return ENHANCE_TYPE_LABELS[n] or ("Type " .. tostring(n))
end

function core.getItemInfo(itemId, ownerId, storageId)
    itemId = math.floor(tonumber(itemId) or -1)
    if itemId < 0 then return nil end
    local item = core.getCatalogEntry(itemId, true)
    if not item then return nil end

    local param = item.param
    local info = {
        itemId = item.id,
        name = item.name,
        kind = item.kind or describe_item_kind(item),
        typeName = item.typeName or (param and safe_full_type_name(param)) or "?",
        weight = item.weight,
        buyPrice = info_field(param, "_BuyPrice"),
        sellPrice = info_field(param, "_SellPrice"),
        baseStats = {},
        enhancement = nil,
        abilities = nil,
    }

    local function add_stat(label, fieldName, includeZero)
        local value = info_field(param, fieldName)
        if value ~= nil and (includeZero == true or tonumber(value) ~= 0) then
            table.insert(info.baseStats, { label = label, value = value, field = fieldName })
        end
    end

    if info.typeName == "app.ItemWeaponParam" then
        add_stat("STR", "_PhysicalAttack", true)
        add_stat("MAG", "_MagicAttack", true)
        add_stat("Knockdown", "_Blow", true)
        add_stat("Stamina Damage", "_StaminaReduce", false)
        add_stat("Element", "_ElementStore", false)
        add_stat("Poison", "_PoisonStore", false)
        add_stat("Sleep", "_SleepStore", false)
        add_stat("Silence", "_SilentStore", false)
        add_stat("Petrification", "_StoneStore", false)
    elseif info.typeName == "app.ItemArmorParam" then
        add_stat("DEF", "_PhysicalDefence", true)
        add_stat("M.DEF", "_MagicDefence", true)
        add_stat("Knockdown Resist", "_BlowResistRate", true)
        add_stat("Stagger Resist", "_ShakeResistRate", false)
        add_stat("Fire DEF", "_FireDefence", false)
        add_stat("Ice DEF", "_IceDefence", false)
        add_stat("Thunder DEF", "_ThunderDefence", false)
        add_stat("Light DEF", "_LightDefence", false)
        add_stat("Dark DEF", "_DarkDefence", false)
        add_stat("Poison Resist", "_PoisonResist", false)
        add_stat("Sleep Resist", "_SleepResist", false)
        add_stat("Silence Resist", "_SilentResist", false)
        add_stat("Petrification Resist", "_StoneResist", false)
    end

    if ownerId ~= nil and storageId ~= nil and core.isInstanceBacked(item) then
        local row = get_storage_master_row(itemId, ownerId, storageId)
        if row then
            local nested = get_storage_master_param(row)
            local enhance = safe_call(function()
                return getMasterEnhanceMethod and getMasterEnhanceMethod:call(row) or nil
            end, nil)
            if enhance == nil and nested ~= nil then enhance = safe_field(nested, "_Enhance", nil) end
            local enhanceNum = safe_call(function()
                return getMasterEnhanceNumMethod and tonumber(getMasterEnhanceNumMethod:call(row)) or nil
            end, nil)
            if enhanceNum == nil then enhanceNum = info_field(enhance, "_Num") end

            if enhance ~= nil or enhanceNum ~= nil then
                local stages = {}
                for index = 0, 2 do
                    local raw = info_field(enhance, "_Type" .. tostring(index))
                    if raw ~= nil then
                        table.insert(stages, {
                            index = index + 1,
                            raw = raw,
                            label = info_enhance_label(raw),
                        })
                    end
                end
                info.enhancement = {
                    num = tonumber(enhanceNum) or 0,
                    stages = stages,
                }
            end

            local ability = safe_call(function()
                return getMasterAbilityMethod and getMasterAbilityMethod:call(row) or nil
            end, nil)
            if ability == nil and nested ~= nil then ability = safe_field(nested, "_Ability", nil) end
            local abilityNum = safe_call(function()
                return getMasterAbilityNumMethod and tonumber(getMasterAbilityNumMethod:call(row)) or nil
            end, nil)
            if abilityNum == nil and ability ~= nil then
                local count = 0
                for i = 1, 4 do
                    local slot = info_field(ability, "Slot" .. tostring(i))
                    local sid = info_number(slot)
                    if sid ~= nil and sid ~= 0 then count = count + 1 end
                end
                abilityNum = count
            end

            if ability ~= nil or abilityNum ~= nil then
                local slots = {}
                for i = 1, 4 do
                    local raw = info_field(ability, "Slot" .. tostring(i))
                    local id = info_number(raw)
                    if id ~= nil and id ~= 0 then
                        table.insert(slots, { slot = i, id = id, raw = raw })
                    end
                end
                info.abilities = {
                    num = tonumber(abilityNum) or #slots,
                    slots = slots,
                    physical = info_field(ability, "PhysicalParameter"),
                    magic = info_field(ability, "MagicParameter"),
                    blow = info_field(ability, "BlowParameter"),
                    weight = info_field(ability, "WeightParameter"),
                    bonus = info_field(ability, "Bonus"),
                    isAppraised = info_field(ability, "IsAppraised"),
                }
            end
        end
    end

    return info
end

local function get_decay_rows(itemId, ownerId)
    local im = get_item_manager()
    if not im then return {} end
    local list = safe_field(im, "DecayStorageList", nil)
    local rows = {}

    for i = 0, managed_list_count(list) - 1 do
        local row = managed_list_at(list, i)
        if row then
            local id = tonumber(safe_field(row, "Id", nil))
            local charaId = tonumber(safe_field(row, "CharaId", nil))
            if id == itemId and charaId == ownerId then
                table.insert(rows, row)
            end
        end
    end

    table.sort(rows, function(a, b)
        local al = tonumber(safe_field(a, "Limit", 0)) or 0
        local bl = tonumber(safe_field(b, "Limit", 0)) or 0
        return al < bl
    end)
    return rows
end

local function decay_total(rows)
    local total = 0
    for _, row in ipairs(rows or {}) do
        total = total + math.max(0, math.floor(tonumber(safe_field(row, "Num", 0)) or 0))
    end
    return total
end

local function set_decay_num(row, value)
    value = math.max(0, math.floor(tonumber(value) or 0))
    local ok = pcall(function() row:set_field("Num", value) end)
    if ok then return true end
    return pcall(function() row.Num = value end)
end

function core.getDecaySummary(itemId, ownerId)
    itemId = math.floor(tonumber(itemId) or 0)
    if itemId <= 0 or ownerId == nil then
        return { isDecay = false, batches = 0, total = 0 }
    end
    if not is_decay_item(itemId) then
        return { isDecay = false, batches = 0, total = 0 }
    end

    local rows = get_decay_rows(itemId, ownerId)
    local minLimit, maxLimit = nil, nil
    for _, row in ipairs(rows) do
        local limit = tonumber(safe_field(row, "Limit", nil))
        if limit ~= nil then
            minLimit = minLimit == nil and limit or math.min(minLimit, limit)
            maxLimit = maxLimit == nil and limit or math.max(maxLimit, limit)
        end
    end

    return {
        isDecay = true,
        batches = #rows,
        total = decay_total(rows),
        minLimit = minLimit,
        maxLimit = maxLimit,
    }
end

function core.reconcileDecayMetadata(itemId, ownerId, target)
    itemId = math.floor(tonumber(itemId) or 0)
    target = math.max(0, math.floor(tonumber(target) or 0))
    if not is_decay_item(itemId) then return true, "Not a decay-managed item." end

    local rows = get_decay_rows(itemId, ownerId)
    local before = decay_total(rows)
    if before == target then
        return true, string.format("DecayData already matches quantity (%d).", target)
    end
    if target > 0 and #rows == 0 then
        return false, "No DecayData batch exists for this decay item."
    end

    local original = {}
    for i, row in ipairs(rows) do
        original[i] = math.max(0, math.floor(tonumber(safe_field(row, "Num", 0)) or 0))
    end

    local function rollback()
        for i, row in ipairs(rows) do
            set_decay_num(row, original[i] or 0)
        end
    end

    if target > before then
        -- Preserve every existing expiry boundary. Extra edited quantity joins the
        -- latest-expiring batch so older items do not suddenly become "younger".
        local row = rows[#rows]
        local oldNum = math.max(0, math.floor(tonumber(safe_field(row, "Num", 0)) or 0))
        if not set_decay_num(row, oldNum + (target - before)) then
            rollback()
            return false, "Could not increase the latest DecayData batch."
        end
    else
        -- Remove edited quantity from latest-expiring batches first, preserving
        -- older decay history and leaving Limit ordering untouched.
        local remaining = before - target
        for i = #rows, 1, -1 do
            if remaining <= 0 then break end
            local row = rows[i]
            local oldNum = math.max(0, math.floor(tonumber(safe_field(row, "Num", 0)) or 0))
            local take = math.min(oldNum, remaining)
            if take > 0 and not set_decay_num(row, oldNum - take) then
                rollback()
                return false, "Could not reduce DecayData batch " .. tostring(i) .. "."
            end
            remaining = remaining - take
        end
        if remaining > 0 then
            rollback()
            return false, "DecayData did not contain enough units to reconcile the requested target."
        end
    end

    local after = decay_total(get_decay_rows(itemId, ownerId))
    if after ~= target then
        rollback()
        return false, string.format("DecayData verification failed: expected %d units, found %d.", target, after)
    end
    return true, string.format("DecayData reconciled from %d to %d units.", before, target)
end

local function set_storage_master_num(itemId, ownerId, target)
    local row = get_storage_master_row(itemId, ownerId)
    if not row then return false, "StorageMasterData row was not found." end

    local ok, err = pcall(function() row:set_Num(target) end)
    if not ok then
        local param = safe_call(function() return row:get_Param() end, nil)
        if not param then return false, tostring(err) end
        local okParam, paramErr = pcall(function() param:set_Num(target) end)
        if not okParam then return false, tostring(paramErr) end
    end

    local im = get_item_manager()
    if im and calcWeightStorageMethod then
        pcall(function() calcWeightStorageMethod:call(im, ownerId) end)
    end

    local verify, verifyErr = core.getCount(itemId, ownerId)
    if verify == nil then return false, verifyErr end
    if verify ~= target then
        return false, string.format("Direct quantity verification failed: expected %d, got %d.", target, verify)
    end
    return true
end

local function make_get_item_option()
    local optionType = sdk.find_type_definition("app.ItemDefine.GetItemOption")
    local eventType = sdk.find_type_definition("app.ItemManager.GetItemEventType")
    if not optionType or not eventType then return nil end

    local defaultField = optionType:get_field("Default")
    local treasureField = eventType:get_field("TreasureBox")
    if not defaultField or not treasureField then return nil end

    local option = safe_call(function() return defaultField:get_data() end, nil)
    local event = safe_call(function() return treasureField:get_data() end, nil)
    if not option then return nil end

    -- Suppress UI/history where the current GetItemOption supports these fields.
    pcall(function() option.IsNotice = false end)
    pcall(function() option.IsHistory = false end)
    if event ~= nil then pcall(function() option.EventType = event end) end
    return option
end


function core._makeRecreateTransferOption()
    local optionType = sdk.find_type_definition("app.ItemDefine.GetItemOption")
    local eventType = sdk.find_type_definition("app.ItemManager.GetItemEventType")
    if not optionType or not eventType then return nil end

    local defaultField = optionType:get_field("Default")
    local noneField = eventType:get_field("None")
    if not defaultField then return nil end

    local option = safe_call(function() return defaultField:get_data() end, nil)
    if not option then return nil end

    pcall(function() option.IsNotice = false end)
    pcall(function() option.IsHistory = false end)
    if noneField then
        local event = safe_call(function() return noneField:get_data() end, nil)
        if event ~= nil then pcall(function() option.EventType = event end) end
    end
    return option
end

local function capacity_limited_destination_amount(itemId, requested, destId, allowAnalysisBypass, operationName)
    requested = math.max(0, math.floor(tonumber(requested) or 0))
    if requested <= 0 then return 0, nil end
    if allowAnalysisBypass and core.getIgnoreTransferCapacitySafety() then return requested, nil end

    local item = core.catalogAllById[itemId] or core.catalogById[itemId]
    if not item then
        core.ensureCatalog(false)
        item = core.catalogAllById[itemId] or core.catalogById[itemId]
    end
    if not item then
        return nil, "Capacity safeguard could not validate the item because it is missing from the catalog."
    end

    -- Identity-preserved objects are distinct instances, so a stack limit of 1
    -- does not cap how many separate gear/lantern/phial instances may exist.
    if core.requiresIdentityTransfer(item) then return requested, nil end

    local limit = math.floor(tonumber(core.getEffectiveStack(item, destId)) or 0)
    if limit <= 0 then
        return nil, string.format(
            "Capacity safeguard could not resolve a destination limit for %s (%d).",
            tostring(item.name or "Item"), tonumber(itemId) or 0)
    end

    local destCount, destErr = core.getCount(itemId, destId)
    if destCount == nil then
        return nil, "Capacity safeguard could not read the destination quantity: " .. tostring(destErr)
    end
    destCount = math.max(0, math.floor(tonumber(destCount) or 0))

    local room = math.max(0, limit - destCount)
    local actual = math.min(requested, room)
    if actual >= requested then return requested, nil end

    local name = tostring(item.name or ("Item " .. tostring(itemId)))
    local verb = tostring(operationName or "Mutation")
    if actual <= 0 then
        return 0, string.format(
            "%s blocked: destination is full for %s (%d/%d); accepted 0/%d.",
            verb, name, destCount, limit, requested)
    end

    return actual, string.format(
        "%s clamped by destination capacity for %s: %d/%d accepted; destination becomes %d/%d.",
        verb, name, actual, requested, destCount + actual, limit)
end

local function native_add_item(itemId, amount, ownerId)
    itemId = math.floor(tonumber(itemId) or 0)
    amount = math.floor(tonumber(amount) or 0)
    if itemId <= 0 or amount <= 0 then return false, "Item ID and amount must be positive." end
    if not getItemMethod then return false, "Current getItem overload was not found." end

    local im = get_item_manager()
    if not im then return false, "ItemManager not ready." end

    if itemId == GOLD_ID then
        local current, countErr = core.getCount(GOLD_ID, ownerId)
        if current == nil then return false, countErr end
        if current + amount > GOLD_CAP then
            return false, string.format("Gold is limited by Inventory Manager to %d G.", GOLD_CAP)
        end
    end

    -- Directly asking DD2 to add 3+ Wakestone Shards is known to be crash-prone.
    if itemId == WAKESHARD_ID then
        local current, err = core.getCount(WAKESHARD_ID, ownerId)
        if current == nil then return false, err end
        local total = current + amount
        local stones = math.floor(total / 3)
        local desiredShards = total - stones * 3
        local delta = desiredShards - current

        if delta > 0 then
            local option = make_get_item_option()
            if not option then return false, "Could not create GetItemOption." end
            local ok, e = pcall(function() getItemMethod:call(im, WAKESHARD_ID, delta, ownerId, option) end)
            if not ok then return false, tostring(e) end
        elseif delta < 0 then
            if not deleteItemNoLockMethod then return false, "deleteItemNoLock method was not found." end
            local ok, e = pcall(function() deleteItemNoLockMethod:call(im, WAKESHARD_ID, -delta, ownerId) end)
            if not ok then return false, tostring(e) end
        end

        if stones > 0 then
            local option = make_get_item_option()
            if not option then return false, "Could not create GetItemOption." end
            local ok, e = pcall(function() getItemMethod:call(im, WAKESTONE_ID, stones, ownerId, option) end)
            if not ok then return false, tostring(e) end
        end
        return true
    end

    local safeAmount, capacityMessage = capacity_limited_destination_amount(
        itemId, amount, ownerId, false, "Add Item")
    if safeAmount == nil then return false, capacityMessage end
    if safeAmount <= 0 then return true, capacityMessage end

    local before, beforeErr = core.getCount(itemId, ownerId)
    if before == nil then return false, beforeErr end

    local option = make_get_item_option()
    if not option then return false, "Could not create GetItemOption." end
    local ok, err = pcall(function()
        getItemMethod:call(im, itemId, safeAmount, ownerId, option)
    end)
    if not ok then return false, tostring(err) end

    local after, verifyErr = core.getCount(itemId, ownerId)
    if after == nil then
        return false, "getItem returned, but the resulting quantity could not be verified: " .. tostring(verifyErr)
    end
    local expected = before + safeAmount
    if after ~= expected then
        return false, string.format(
            "getItem did not produce the requested quantity: before=%d, add=%d, expected=%d, actual=%d.",
            before, safeAmount, expected, after)
    end

    if capacityMessage then return true, capacityMessage end
    return true, string.format("Added %d unit(s): %d -> %d.", safeAmount, before, after)
end

local function native_remove_item(itemId, amount, ownerId)
    itemId = math.floor(tonumber(itemId) or 0)
    amount = math.floor(tonumber(amount) or 0)
    if itemId <= 0 or amount <= 0 then return false, "Item ID and amount must be positive." end
    if not deleteItemNoLockMethod then return false, "Current deleteItemNoLock overload was not found." end

    local current, countErr = core.getCount(itemId, ownerId)
    if current == nil then return false, countErr end
    if amount > current then return false, "Cannot remove more than the current quantity." end

    local entry = core.catalogById[itemId]
    if entry and core.isInstanceBacked(entry) then
        return false, "Direct removal is disabled for instance-backed items."
    end

    local im = get_item_manager()
    if not im then return false, "ItemManager not ready." end

    -- A successful Lua/SDK call is not proof that DD2 actually removed anything.
    -- Use the native no-lock mutation path and verify the live ItemManager count
    -- afterward so a silent rejection can never be reported as success.
    local ok, callErr = pcall(function()
        deleteItemNoLockMethod:call(im, itemId, amount, ownerId)
    end)
    if not ok then return false, tostring(callErr) end

    local after, verifyErr = core.getCount(itemId, ownerId)
    if after == nil then
        return false, "deleteItemNoLock returned, but the resulting quantity could not be verified: " .. tostring(verifyErr)
    end

    local expected = current - amount
    if after ~= expected then
        return false, string.format(
            "deleteItemNoLock did not produce the requested quantity: before=%d, remove=%d, expected=%d, actual=%d. " ..
            "The native deletion call completed without changing the stored quantity as requested.",
            current, amount, expected, after)
    end

    return true, string.format("Removed %d unit(s): %d -> %d.", amount, current, after)
end

local function set_decay_managed_quantity(itemId, target, ownerId)
    if target > UINT16_MAX then
        return false, string.format("Decay-managed StorageData._Num is UInt16; target must be <= %d.", UINT16_MAX)
    end

    local current, err = core.getCount(itemId, ownerId)
    if current == nil then return false, err end

    local capacityMessage = nil
    if target > current then
        local requestedAdd = target - current
        local safeAdd, capacityErr = capacity_limited_destination_amount(
            itemId, requestedAdd, ownerId, false, "Set Quantity")
        if safeAdd == nil then return false, capacityErr end
        if safeAdd < requestedAdd then
            target = current + safeAdd
            capacityMessage = capacityErr
        end
        if safeAdd <= 0 then return true, capacityMessage end
    end

    local rows = get_decay_rows(itemId, ownerId)

    -- A trainer/direct edit can leave a visible stack with no DecayData at all.
    -- Seed exactly ONE native item so DD2 creates a valid batch/Limit for us.
    if target > 0 and #rows == 0 then
        local okSeed, seedErr = native_add_item(itemId, 1, ownerId)
        if not okSeed then
            return false, "Could not seed a DecayData batch: " .. tostring(seedErr)
        end
        current = core.getCount(itemId, ownerId) or (current + 1)
        rows = get_decay_rows(itemId, ownerId)
        if #rows == 0 then
            return false, "DD2 added the seed item but did not create readable DecayData; refusing a direct quantity edit."
        end
    end

    if target == 0 and current == 0 then
        local okDecay, decayErr = core.reconcileDecayMetadata(itemId, ownerId, 0)
        if not okDecay then return false, decayErr end
        return true
    end

    local originalCount = core.getCount(itemId, ownerId) or current
    local beforeRows = get_decay_rows(itemId, ownerId)
    local originalNums = {}
    for i, row in ipairs(beforeRows) do
        originalNums[i] = math.max(0, math.floor(tonumber(safe_field(row, "Num", 0)) or 0))
    end

    local okDecay, decayErr = core.reconcileDecayMetadata(itemId, ownerId, target)
    if not okDecay then return false, decayErr end

    local okCount, countErr = set_storage_master_num(itemId, ownerId, target)
    if not okCount then
        for i, row in ipairs(beforeRows) do
            set_decay_num(row, originalNums[i] or 0)
        end
        return false, "Quantity write failed; DecayData rollback attempted: " .. tostring(countErr)
    end

    local summary = core.getDecaySummary(itemId, ownerId)
    if summary.total ~= target then
        local repairOk, repairErr = core.reconcileDecayMetadata(itemId, ownerId, target)
        if not repairOk then
            return false, "Stack changed, but final DecayData verification failed: " .. tostring(repairErr)
        end
    end

    local message = string.format(
        "Decay-managed quantity changed from %d to %d with metadata reconciled.",
        originalCount, target)
    if capacityMessage then message = message .. " " .. capacityMessage end
    return true, message
end

function core.addItem(itemId, amount, ownerId)
    itemId = math.floor(tonumber(itemId) or 0)
    amount = math.floor(tonumber(amount) or 0)
    if itemId <= 0 or amount <= 0 then return false, "Item ID and amount must be positive." end

    if is_decay_item(itemId) then
        local current, err = core.getCount(itemId, ownerId)
        if current == nil then return false, err end
        return core.setQuantity(itemId, current + amount, ownerId)
    end
    return native_add_item(itemId, amount, ownerId)
end

function core.removeItem(itemId, amount, ownerId)
    itemId = math.floor(tonumber(itemId) or 0)
    amount = math.floor(tonumber(amount) or 0)
    if itemId <= 0 or amount <= 0 then return false, "Item ID and amount must be positive." end

    local current, err = core.getCount(itemId, ownerId)
    if current == nil then return false, err end
    if amount > current then return false, "Cannot remove more than the current quantity." end

    if is_decay_item(itemId) then
        return core.setQuantity(itemId, current - amount, ownerId)
    end
    return native_remove_item(itemId, amount, ownerId)
end

function core.setQuantity(itemId, target, ownerId)
    itemId = math.floor(tonumber(itemId) or 0)
    target = math.max(0, math.floor(tonumber(target) or 0))
    if itemId == GOLD_ID and target > GOLD_CAP then
        return false, string.format("Gold is limited by Inventory Manager to %d G.", GOLD_CAP)
    end

    local entry = core.catalogById[itemId]
    if entry and core.isInstanceBacked(entry) then
        return false, "Set Quantity is disabled for instance-backed items."
    end

    if is_decay_item(itemId) then
        return set_decay_managed_quantity(itemId, target, ownerId)
    end

    local current, err = core.getCount(itemId, ownerId)
    if current == nil then return false, err end
    if target == current then return true end

    if target > current then
        return native_add_item(itemId, target - current, ownerId)
    end
    return native_remove_item(itemId, current - target, ownerId)
end

storage_master_row_item_id = function(row)
    if not row then return nil end
    local id = safe_call(function() return tonumber(row:get_ItemId()) end, nil)
    if id ~= nil then return id end
    local param = safe_field(row, "_Param", nil)
    id = tonumber(safe_field(param, "_ItemId", nil))
    if id ~= nil then return id end
    local itemData = safe_field(row, "_ItemData", nil)
    return item_id_from_param(itemData)
end

storage_master_row_quantity = function(row)
    if not row then return 0 end
    local num = safe_call(function() return tonumber(row:get_Num()) end, nil)
    if num ~= nil then return math.max(0, math.floor(num)) end
    num = tonumber(safe_field(row, "_Num", nil))
    if num ~= nil then return math.max(0, math.floor(num)) end
    local param = safe_field(row, "_Param", nil)
    num = tonumber(safe_field(param, "_Num", nil))
    return math.max(0, math.floor(num or 0))
end

storage_master_row_storage_id = function(row)
    if not row then return nil end
    local value = safe_call(function() return tonumber(row:get_StorageId()) end, nil)
    if value ~= nil then return value end
    local param = safe_field(row, "_Param", nil)
    return tonumber(safe_field(param, "_StorageId", nil))
end

storage_master_row_chara_id = function(row)
    if not row then return nil end
    local value = safe_call(function() return tonumber(row:get_CharaId()) end, nil)
    if value ~= nil then return value end
    local param = safe_field(row, "_Param", nil)
    return tonumber(safe_field(param, "_CharaId", nil))
end

storage_master_row_is_equipped = function(row)
    if not row then return false end
    local value = safe_call(function() return row:get_IsEquipped() end, nil)
    if value ~= nil then return value == true end
    local param = safe_field(row, "_Param", nil)
    return safe_field(param, "_IsEquipped", false) == true
end

storage_master_row_equip_slot = function(row)
    if not row then return nil end
    local value = safe_call(function() return tonumber(row:get_EquipSlot()) end, nil)
    if value ~= nil then return value end
    local param = safe_field(row, "_Param", nil)
    return tonumber(safe_field(param, "_EquipSlot", nil))
end

storage_master_row_update_index = function(row)
    if not row then return nil end
    return safe_call(function() return tonumber(row:get_UpdateIndex()) end, nil)
end

storage_master_row_arisen_equip_no = function(row)
    if not row then return nil end
    return safe_call(function() return tonumber(row:get_ArisenEquipNo()) end, nil)
end

local function make_inventory_row_key(itemId, storageId, recordIndex, instanceBacked)
    if instanceBacked then
        if storageId ~= nil then
            return string.format("I:%d:%s", tonumber(itemId) or 0, tostring(storageId))
        end
        return string.format("I:%d:R%d", tonumber(itemId) or 0, tonumber(recordIndex) or 0)
    end
    return string.format("S:%d", tonumber(itemId) or 0)
end

function core.getInventoryCounts(ownerId)
    if ownerId == nil then return nil, "Owner CharacterID is unavailable." end
    local list = get_storage_master_list(ownerId)
    if not list then return nil, "StorageMasterList is unavailable for this owner." end
    local counts = {}
    for i = 0, managed_list_count(list) - 1 do
        local row = managed_list_at(list, i)
        local itemId = storage_master_row_item_id(row)
        local quantity = storage_master_row_quantity(row)
        if itemId and itemId > 0 and quantity > 0 then
            counts[itemId] = (counts[itemId] or 0) + quantity
        end
    end
    return counts
end

function core.getInventoryRows(ownerId)
    if ownerId == nil then return nil, "Owner CharacterID is unavailable." end
    if not core.ensureCatalog(false) then return nil, "Item catalog is unavailable." end

    local list = get_storage_master_list(ownerId)
    if not list then return nil, "StorageMasterList is unavailable for this owner." end

    local rows = {}
    local stackRowsById = {}
    local equippedIds = equipped_storage_ids and equipped_storage_ids(ownerId) or {}
    for i = 0, managed_list_count(list) - 1 do
        local master = managed_list_at(list, i)
        local itemId = storage_master_row_item_id(master)
        local quantity = storage_master_row_quantity(master)
        local item = itemId and core.catalogById[itemId] or nil
        if item and quantity > 0 then
            local instanceBacked = core.isInstanceBacked(item)
            if instanceBacked then
                local storageId = storage_master_row_storage_id(master)
                local rawEquipped = storage_master_row_is_equipped(master)
                table.insert(rows, {
                    item = item,
                    quantity = quantity,
                    ownerId = ownerId,
                    instanceBacked = true,
                    storageId = storageId,
                    rowKey = make_inventory_row_key(itemId, storageId, i, true),
                    recordIndex = i,
                    charaId = storage_master_row_chara_id(master),
                    rawIsEquipped = rawEquipped,
                    isEquipped = rawEquipped or (storageId ~= nil and equippedIds[storageId] == true),
                    equipSlot = storage_master_row_equip_slot(master),
                    updateIndex = storage_master_row_update_index(master),
                    arisenEquipNo = storage_master_row_arisen_equip_no(master),
                })
            else
                local row = stackRowsById[itemId]
                if not row then
                    row = {
                        item = item,
                        quantity = 0,
                        ownerId = ownerId,
                        instanceBacked = false,
                        storageId = nil,
                        rowKey = make_inventory_row_key(itemId, nil, i, false),
                    }
                    stackRowsById[itemId] = row
                    table.insert(rows, row)
                end
                row.quantity = row.quantity + quantity
            end
        end
    end

    -- StorageId is the candidate instance identity we are validating in 0.2.1.
    -- Do not assume uniqueness while testing: if two same-ItemID records expose the
    -- same StorageId, append the raw master-list index so both rows remain selectable.
    local identityCounts = {}
    for _, row in ipairs(rows) do
        if row.instanceBacked then
            local token = tostring(row.item.id) .. ":" .. tostring(row.storageId)
            identityCounts[token] = (identityCounts[token] or 0) + 1
        end
    end
    for _, row in ipairs(rows) do
        if row.instanceBacked then
            local token = tostring(row.item.id) .. ":" .. tostring(row.storageId)
            if (identityCounts[token] or 0) > 1 then
                row.storageIdDuplicate = true
                row.rowKey = string.format(
                    "I:%d:%s:R%d",
                    tonumber(row.item.id) or 0,
                    tostring(row.storageId),
                    tonumber(row.recordIndex) or 0)
            end
        end
    end

    table.sort(rows, function(a,b)
        local an = string.lower(tostring(a.item and a.item.name or ""))
        local bn = string.lower(tostring(b.item and b.item.name or ""))
        if an ~= bn then return an < bn end
        local aid = tonumber(a.item and a.item.id) or 0
        local bid = tonumber(b.item and b.item.id) or 0
        if aid ~= bid then return aid < bid end
        local asid = tonumber(a.storageId)
        local bsid = tonumber(b.storageId)
        if asid ~= nil and bsid ~= nil and asid ~= bsid then return asid < bsid end
        return tostring(a.rowKey or "") < tostring(b.rowKey or "")
    end)
    return rows
end

function core.refreshSnapshot(key, ownerId)
    if not core.ensureCatalog(false) then return false end
    if ownerId == nil then
        set_error("Cannot refresh " .. tostring(key) .. ": owner CharacterID is unavailable.")
        return false
    end

    local rows, err = core.getInventoryRows(ownerId)
    if not rows then
        set_error("Cannot refresh " .. tostring(key) .. ": " .. tostring(err))
        return false
    end

    core.snapshots[key] = rows
    local instanceRows = 0
    for _, row in ipairs(rows) do
        if row.instanceBacked then instanceRows = instanceRows + 1 end
    end
    set_status(string.format(
        "Refreshed %s: %d occupied rows (%d instance-backed).",
        tostring(key), #rows, instanceRows))
    return true
end

function core.refreshPlayer()
    local id = core.getPlayerId()
    if not id then
        set_error("Player CharacterID is not available yet.")
        return false
    end
    return core.refreshSnapshot("player", id)
end

function core.refreshStorage()
    return core.refreshSnapshot("storage", STORAGE_ID)
end


local function character_key(character)
    if not character then return nil end
    return safe_call(function() return tostring(character:get_address()) end, tostring(get_chara_id(character)))
end

function core.refreshParty()
    local result = {}
    local seen = {}
    local slots = { MainPawn = nil, PawnA = nil, PawnB = nil }
    local player = get_player()
    if player then
        local runtimePlayerId = get_chara_id(player)
        if runtimePlayerId ~= nil and character_id_hex32(runtimePlayerId) ~= character_id_hex32(ARISEN_ID) then
            core.debugLog("Basic",
                "Player runtime CharacterID mismatch: runtime=%s canonical=%s; using canonical ItemDefine.ArisenCharaId.",
                tostring(character_id_hex32(runtimePlayerId)), tostring(character_id_hex32(ARISEN_ID)))
        end
        table.insert(result, {
            label = "Player",
            displayName = "Player",
            slotKey = "Player",
            character = player,
            id = ARISEN_ID,
        })
        seen[character_key(player)] = true
    end

    local pm = get_pawn_manager()
    if not pm then
        core.party = result
        core.pawnSlots = slots
        return result
    end

    local mainPawn = safe_call(function()
        local pawn = pm:get_MainPawn()
        return pawn and pawn:get_CachedCharacter() or nil
    end, nil)
    if mainPawn then
        local key = character_key(mainPawn)
        seen[key] = true
        local runtimeMainPawnId = get_chara_id(mainPawn)
        if runtimeMainPawnId ~= nil and character_id_hex32(runtimeMainPawnId) ~= character_id_hex32(MAIN_PAWN_ID) then
            core.debugLog("Basic",
                "Main Pawn runtime CharacterID mismatch: runtime=%s canonical=%s; using canonical ItemDefine.MainPawnCharaId.",
                tostring(character_id_hex32(runtimeMainPawnId)), tostring(character_id_hex32(MAIN_PAWN_ID)))
        end
        local member = {
            label = "Main Pawn",
            displayName = get_pawn_display_name(mainPawn) or "Main Pawn",
            slotKey = "MainPawn",
            character = mainPawn,
            id = MAIN_PAWN_ID,
        }
        slots.MainPawn = member
        table.insert(result, member)
    end

    local pawnList = safe_call(function() return pm:get_PawnCharacterList() end, nil)
    local hiredIndex = 1
    for i = 0, managed_list_count(pawnList) - 1 do
        local character = managed_list_at(pawnList, i)
        if character then
            local key = character_key(character)
            if not seen[key] then
                seen[key] = true
                local slotKey = hiredIndex == 1 and "PawnA"
                    or (hiredIndex == 2 and "PawnB" or ("Pawn" .. tostring(hiredIndex)))
                local member = {
                    -- Keep the stable label used by automation/report output.
                    label = "Hired Pawn " .. tostring(hiredIndex),
                    -- Leave unresolved names nil so the tab descriptor can retry
                    -- once the hired pawn's live PawnDataContext finishes loading.
                    displayName = get_pawn_display_name(character),
                    slotKey = slotKey,
                    character = character,
                    id = get_chara_id(character),
                }
                if hiredIndex == 1 then slots.PawnA = member end
                if hiredIndex == 2 then slots.PawnB = member end
                table.insert(result, member)
                hiredIndex = hiredIndex + 1
            end
        end
    end

    core.party = result
    core.pawnSlots = slots
    return result
end

local PAWN_SNAPSHOT_KEYS = {
    MainPawn = "mainpawn",
    PawnA = "pawna",
    PawnB = "pawnb",
}
core.PAWN_SNAPSHOT_KEYS = PAWN_SNAPSHOT_KEYS

function core.getInventoryOwnerId(pageKey)
    if pageKey == "Player" then return core.getPlayerId() end
    if pageKey == "Storage" then return STORAGE_ID end
    if pageKey == "MainPawn" then
        local member = core.pawnSlots and core.pawnSlots.MainPawn or nil
        return member and MAIN_PAWN_ID or nil
    end
    local member = core.pawnSlots and core.pawnSlots[pageKey] or nil
    return member and member.id or nil
end

local function pawn_tab_label(member)
    if not member then return "Pawn" end

    local name = normalize_pawn_text(member.displayName)
    if not name and member.character then
        -- Hired-pawn contexts may become available a few frames after the
        -- character enters the party. Retry only while the name is unresolved.
        name = get_pawn_display_name(member.character)
        if name then member.displayName = name end
    end

    return "Pawn " .. tostring(name or "Unknown")
end

function core.getInventoryTabDescriptors(refreshPartyFirst)
    if refreshPartyFirst == true then core.refreshParty() end
    local slots = core.pawnSlots or {}
    return {
        { key = "Player", label = "Player", ownerId = core.getPlayerId(), available = core.getPlayerId() ~= nil },
        { key = "MainPawn", label = "Main Pawn", ownerId = slots.MainPawn and MAIN_PAWN_ID or nil, available = slots.MainPawn ~= nil },
        { key = "PawnA", label = pawn_tab_label(slots.PawnA), ownerId = slots.PawnA and slots.PawnA.id or nil, available = slots.PawnA ~= nil },
        { key = "PawnB", label = pawn_tab_label(slots.PawnB), ownerId = slots.PawnB and slots.PawnB.id or nil, available = slots.PawnB ~= nil },
        { key = "Storage", label = "Storage", ownerId = STORAGE_ID, available = true },
    }
end

function core.refreshPawnInventorySlot(slotKey, refreshPartyFirst)
    if refreshPartyFirst ~= false then core.refreshParty() end
    local snapshotKey = PAWN_SNAPSHOT_KEYS[slotKey]
    if not snapshotKey then return false end
    local member = core.pawnSlots and core.pawnSlots[slotKey] or nil
    if not member or not member.id then
        core.snapshots[snapshotKey] = {}
        return true
    end
    return core.refreshSnapshot(snapshotKey, member.id)
end

function core.refreshPawnInventorySlots()
    core.refreshParty()
    local ok = true
    for _, slotKey in ipairs({ "MainPawn", "PawnA", "PawnB" }) do
        if not core.refreshPawnInventorySlot(slotKey, false) then ok = false end
    end
    return ok
end

local function equipped_counts(character)
    local counts = {}
    local im = get_item_manager()
    local charaId = get_chara_id(character)
    if not im or not charaId then return counts end

    local equipData = safe_call(function() return im:getEquipData(charaId) end, nil)
    local equipList = equipData and safe_call(function() return equipData:get_EquipList() end, nil) or nil
    for i = 0, managed_list_count(equipList) - 1 do
        local storageData = managed_list_at(equipList, i)
        if storageData then
            local itemData = safe_field(storageData, "_ItemData", nil)
            local itemId = item_id_from_param(itemData)
            if itemId then counts[itemId] = (counts[itemId] or 0) + 1 end
        end
    end
    return counts
end

local function capture_pawn_inventory_state(updateSnapshot)
    if not core.ensureCatalog(false) then return nil, "Item DB cache is unavailable." end

    core.refreshParty()
    local pawnResults = {}
    for _, member in ipairs(core.party) do
        if member.label ~= "Player" and member.id then
            local counts, countErr = core.getInventoryCounts(member.id)
            if not counts then
                return nil, string.format("%s inventory scan failed: %s", member.label, tostring(countErr))
            end

            local equipCounts = equipped_counts(member.character)
            local rows = {}
            for itemId, count in pairs(counts) do
                local item = core.catalogById[itemId]
                if item then
                    local equipped = math.min(count, equipCounts[itemId] or 0)
                    local rule = core.getPawnCleanerRule(itemId)
                    local keep = math.max(equipped, math.max(0, tonumber(rule.keep) or 0))
                    local move = rule.enabled and math.max(0, count - keep) or 0
                    local reason = rule.enabled
                        and (rule.source .. (keep > 0 and ("; keep " .. tostring(keep)) or ""))
                        or rule.source
                    local skipped, skipReason = false, nil
                    if itemId == WAKESHARD_ID and move > 0 then
                        skipped = true
                        skipReason = "Wakestone Shard safeguard"
                        move = 0
                    end
                    table.insert(rows, {
                        item = item,
                        quantity = count,
                        equipped = equipped,
                        keep = keep,
                        move = move,
                        reason = reason,
                        skipped = skipped,
                        skipReason = skipReason,
                        rule = rule,
                    })
                end
            end

            table.sort(rows, function(a,b)
                local an = string.lower(tostring(a.item and a.item.name or ""))
                local bn = string.lower(tostring(b.item and b.item.name or ""))
                if an == bn then return (a.item.id or 0) < (b.item.id or 0) end
                return an < bn
            end)

            pawnResults[member.label] = {
                member = member,
                rows = rows,
                counts = counts,
                equippedCounts = equipCounts,
            }
        end
    end

    if updateSnapshot ~= false then core.snapshots.pawns = pawnResults end
    return pawnResults
end

function core.analyzePawns()
    local pawnResults, err = capture_pawn_inventory_state(true)
    if not pawnResults then
        set_error("Pawn inventory scan failed: " .. tostring(err))
        return false
    end
    set_status("Pawn inventories refreshed from occupied StorageMasterList rows.")
    return true
end

local function pawn_state_signature(state)
    local sig = {}
    for label, data in pairs(state or {}) do
        local counts = {}
        for itemId, quantity in pairs(data.counts or {}) do counts[itemId] = quantity end
        sig[label] = {
            memberId = data.member and data.member.id or nil,
            counts = counts,
        }
    end
    return sig
end

local function queue_pawn_rule_cleanup(state, automatic)
    local jobs = {}
    local detected = 0

    for label, data in pairs(state or {}) do
        local baseline = core.pawnCleaner.baseline and core.pawnCleaner.baseline[label] or nil
        local samePawn = baseline ~= nil
            and baseline.memberId ~= nil
            and baseline.memberId == (data.member and data.member.id or nil)

        for itemId, count in pairs(data.counts or {}) do
            local previous = samePawn and (baseline.counts[itemId] or 0) or count
            local increased = count > previous

            if (not automatic) or increased then
                if increased then detected = detected + 1 end
                local item = core.catalogById[itemId]
                local rule = item and core.getPawnCleanerRule(itemId) or nil
                if item and rule and rule.enabled and itemId ~= WAKESHARD_ID then
                    local equipped = math.min(count, (data.equippedCounts or {})[itemId] or 0)
                    local keep = math.max(equipped, math.max(0, tonumber(rule.keep) or 0))
                    local move = math.max(0, count - keep)
                    if move > 0 then
                        local sourceId = data.member.id
                        local destination = rule.destination == "Player" and "Player" or "Storage"
                        local destId = STORAGE_ID
                        if destination == "Player" then
                            destId = core.getPlayerId()
                        end

                        table.insert(jobs, {
                            label = string.format(
                                "%s: %s (%d) x%d -> %s",
                                label, tostring(item.name), itemId, move, destination),
                            meta = {
                                pawnLabel=label,
                                itemId=itemId,
                                itemName=tostring(item.name),
                                amount=move,
                                destination=destination,
                            },
                            fn = function()
                                if not destId then
                                    return false, "Player CharacterID is unavailable."
                                end

                                -- Hard automation safeguard: equipment state may
                                -- change after the inventory snapshot but before
                                -- this queued mutation executes. Re-check it now
                                -- and never include equipped instances in the move.
                                local currentCount, countErr = core.getCount(itemId, sourceId)
                                if currentCount == nil then return false, tostring(countErr) end
                                local currentEquipped = math.min(
                                    currentCount,
                                    math.max(0, core.getEquippedCount(sourceId, itemId) or 0))
                                local currentKeep = math.max(
                                    currentEquipped,
                                    math.max(0, tonumber(rule.keep) or 0))
                                local safeMove = math.min(move, math.max(0, currentCount - currentKeep))
                                if safeMove <= 0 then return true end

                                return core.transferStack(itemId, safeMove, sourceId, destId)
                            end,
                        })
                    end
                end
            end
        end
    end

    core.pawnCleaner.lastDetected = detected
    core.pawnCleaner.lastQueued = #jobs

    if #jobs == 0 then
        core.pawnCleaner.baseline = pawn_state_signature(state)
        return true, "No eligible increased items required transfer.", 0
    end

    local total = #jobs
    local id, err = core.enqueueMutationBatch(
        automatic and "Pawn auto-clean" or "Pawn filtered clean",
        jobs,
        {
            onProgress = function(progress)
                if progress.success then
                    local notice = type(progress.result) == "string" and progress.result or nil
                    core.pawnCleaner.status = string.format(
                        "%s: %d/%d transfers complete%s.",
                        automatic and "Pawn auto-clean" or "Pawn filtered clean",
                        progress.processed or 0, total,
                        notice and ("; " .. notice) or "")
                end
            end,
            onComplete = function(summary)
                if summary.success then
                    core.pawnCleaner.completedBatches = (core.pawnCleaner.completedBatches or 0) + 1
                    local fresh = capture_pawn_inventory_state(true)
                    core.pawnCleaner.baseline = fresh and pawn_state_signature(fresh) or nil
                    core.refreshStorage()
                    core.refreshPlayer()
                    local noticeSuffix = ""
                    if type(summary.notices) == "table" and #summary.notices > 0 then
                        noticeSuffix = #summary.notices == 1
                            and ("; " .. tostring(summary.notices[1]))
                            or string.format("; %d capacity notices; last: %s", #summary.notices, tostring(summary.notices[#summary.notices]))
                    end
                    core.pawnCleaner.status = string.format(
                        "%s complete: %d/%d transfer stacks%s.",
                        automatic and "Pawn auto-clean" or "Pawn filtered clean",
                        summary.processed or 0, total, noticeSuffix)
                else
                    core.pawnCleaner.baseline = nil
                    if automatic then
                        core.pawnCleaner.enabled = false
                        core.pawnCleaner.status = string.format(
                            "AUTO-CLEAN DISABLED after transfer failure on %s: %s",
                            tostring(summary.failedLabel or "?"), tostring(summary.error or "unknown error"))
                        save_config()
                        notify_pawn_cleaner_control()
                    else
                        core.pawnCleaner.status = string.format(
                            "Pawn filtered clean aborted on %s: %s",
                            tostring(summary.failedLabel or "?"), tostring(summary.error or "unknown error"))
                    end
                end
            end,
        })

    if not id then return false, tostring(err), 0 end
    core.pawnCleaner.status = string.format(
        "%s queued: %d transfer stacks.",
        automatic and "Pawn auto-clean" or "Pawn filtered clean", total)
    return true, core.pawnCleaner.status, total
end

local function capture_player_inventory_state(updateSnapshot)
    if not core.ensureCatalog(false) then return nil, "Item DB cache is unavailable." end

    local party = core.refreshParty() or {}
    local player = nil
    for _, member in ipairs(party) do
        if member.slotKey == "Player" then
            player = member
            break
        end
    end
    if not player or not player.id then return nil, "Player CharacterID is unavailable." end

    local counts, countErr = core.getInventoryCounts(player.id)
    if not counts then return nil, "Player inventory scan failed: " .. tostring(countErr) end

    local state = {
        member = player,
        counts = counts,
        equippedCounts = equipped_counts(player.character),
    }
    if updateSnapshot ~= false then
        core.refreshSnapshot("player", player.id)
    end
    return state
end

local function player_state_signature(state)
    if not state then return nil end
    local counts = {}
    for itemId, quantity in pairs(state.counts or {}) do counts[itemId] = quantity end
    return {
        memberId = state.member and state.member.id or nil,
        counts = counts,
    }
end

local function queue_player_rule_cleanup(state, automatic)
    local jobs = {}
    local detected = 0
    local baseline = core.playerCleaner.baseline
    local samePlayer = baseline ~= nil
        and baseline.memberId ~= nil
        and baseline.memberId == (state.member and state.member.id or nil)

    for itemId, count in pairs(state.counts or {}) do
        local previous = samePlayer and (baseline.counts[itemId] or 0) or count
        local increased = count > previous
        if (not automatic) or increased then
            if increased then detected = detected + 1 end
            local item = core.catalogById[itemId]
            local rule = item and core.getPlayerCleanerRule(itemId) or nil
            if item and rule and rule.enabled and itemId ~= WAKESHARD_ID then
                local equipped = math.min(count, (state.equippedCounts or {})[itemId] or 0)
                local keep = math.max(equipped, math.max(0, tonumber(rule.keep) or 0))
                local move = math.max(0, count - keep)
                if move > 0 then
                    local sourceId = state.member.id
                    table.insert(jobs, {
                        label = string.format(
                            "Player: %s (%d) x%d -> Storage",
                            tostring(item.name), itemId, move),
                        meta = {
                            player=true,
                            itemId=itemId,
                            itemName=tostring(item.name),
                            amount=move,
                            destination="Storage",
                        },
                        fn = function()
                            local currentCount, countErr = core.getCount(itemId, sourceId)
                            if currentCount == nil then return false, tostring(countErr) end
                            local currentEquipped = math.min(
                                currentCount,
                                math.max(0, core.getEquippedCount(sourceId, itemId) or 0))
                            local currentKeep = math.max(
                                currentEquipped,
                                math.max(0, tonumber(rule.keep) or 0))
                            local safeMove = math.min(move, math.max(0, currentCount - currentKeep))
                            if safeMove <= 0 then return true end
                            return core.transferStack(itemId, safeMove, sourceId, STORAGE_ID)
                        end,
                    })
                end
            end
        end
    end

    core.playerCleaner.lastDetected = detected
    core.playerCleaner.lastQueued = #jobs

    if #jobs == 0 then
        core.playerCleaner.baseline = player_state_signature(state)
        return true, "No eligible increased Player items required transfer.", 0
    end

    local total = #jobs
    local id, err = core.enqueueMutationBatch(
        automatic and "Player auto-clean" or "Player filtered clean",
        jobs,
        {
            onProgress = function(progress)
                if progress.success then
                    local notice = type(progress.result) == "string" and progress.result or nil
                    core.playerCleaner.status = string.format(
                        "%s: %d/%d transfers complete%s.",
                        automatic and "Player auto-clean" or "Player filtered clean",
                        progress.processed or 0, total,
                        notice and ("; " .. notice) or "")
                end
            end,
            onComplete = function(summary)
                if summary.success then
                    core.playerCleaner.completedBatches = (core.playerCleaner.completedBatches or 0) + 1
                    local fresh = capture_player_inventory_state(true)
                    core.playerCleaner.baseline = fresh and player_state_signature(fresh) or nil
                    core.refreshStorage()
                    local noticeSuffix = ""
                    if type(summary.notices) == "table" and #summary.notices > 0 then
                        noticeSuffix = #summary.notices == 1
                            and ("; " .. tostring(summary.notices[1]))
                            or string.format("; %d capacity notices; last: %s", #summary.notices, tostring(summary.notices[#summary.notices]))
                    end
                    core.playerCleaner.status = string.format(
                        "%s complete: %d/%d transfer stacks%s.",
                        automatic and "Player auto-clean" or "Player filtered clean",
                        summary.processed or 0, total, noticeSuffix)
                else
                    core.playerCleaner.baseline = nil
                    if automatic then
                        core.playerCleaner.enabled = false
                        core.playerCleaner.status = string.format(
                            "PLAYER AUTO-CLEAN DISABLED after transfer failure on %s: %s",
                            tostring(summary.failedLabel or "?"), tostring(summary.error or "unknown error"))
                        save_config()
                        notify_player_cleaner_control()
                    else
                        core.playerCleaner.status = string.format(
                            "Player filtered clean aborted on %s: %s",
                            tostring(summary.failedLabel or "?"), tostring(summary.error or "unknown error"))
                    end
                end
            end,
        })

    if not id then return false, tostring(err), 0 end
    core.playerCleaner.status = string.format(
        "%s queued: %d transfer stacks.",
        automatic and "Player auto-clean" or "Player filtered clean", total)
    return true, core.playerCleaner.status, total
end

function core.cleanPlayerByRules()
    if core.hasPendingMutations() then
        return false, "Another inventory mutation is already queued."
    end
    local state, err = capture_player_inventory_state(true)
    if not state then return false, err end
    return queue_player_rule_cleanup(state, false)
end

function core.pollPlayerCleaner()
    if not core.playerCleaner.enabled then return false end
    if core.hasPendingMutations() then return false end

    local state, err = capture_player_inventory_state(true)
    if not state then
        core.playerCleaner.status = "Player auto-clean scan skipped: " .. tostring(err)
        return false
    end

    if core.playerCleaner.baseline == nil then
        core.playerCleaner.baseline = player_state_signature(state)
        core.playerCleaner.status = "Player auto-clean baseline established; waiting for inventory additions."
        return true
    end

    local ok, message = queue_player_rule_cleanup(state, true)
    if not ok then core.playerCleaner.status = "Player auto-clean could not queue: " .. tostring(message) end
    return ok
end

function core.cleanPawnsByRules()
    if core.hasPendingMutations() then
        return false, "Another inventory mutation is already queued."
    end
    local state, err = capture_pawn_inventory_state(true)
    if not state then return false, err end
    return queue_pawn_rule_cleanup(state, false)
end

function core.pollPawnCleaner()
    if not core.pawnCleaner.enabled then return false end
    if core.hasPendingMutations() then return false end

    local state, err = capture_pawn_inventory_state(true)
    if not state then
        core.pawnCleaner.status = "Pawn auto-clean scan skipped: " .. tostring(err)
        return false
    end

    if core.pawnCleaner.baseline == nil then
        core.pawnCleaner.baseline = pawn_state_signature(state)
        core.pawnCleaner.status = "Pawn auto-clean baseline established; waiting for inventory additions."
        return true
    end

    local ok, message = queue_pawn_rule_cleanup(state, true)
    if not ok then core.pawnCleaner.status = "Pawn auto-clean could not queue: " .. tostring(message) end
    return ok
end

function core.pollPawnRetrieval(reason)
    if not core.pawnCleaner.enabled then return false, "Pawn automation is disabled." end
    if core.hasPendingMutations() then return false, "Another inventory mutation is already queued." end
    if not core.ensureCatalog(false) then return false, "Item DB cache is unavailable." end

    local party = core.refreshParty() or {}
    local playerId = core.getPlayerId()
    local jobs = {}

    for _, member in ipairs(party) do
        if member.slotKey ~= "Player" and member.id ~= nil then
            for itemId, override in pairs(core.pawnCleaner.overrides or {}) do
                if override.mode == "transfer" then
                    local keep = math.max(0, math.floor(tonumber(override.keep) or 0))
                    if keep > 0 and itemId ~= WAKESHARD_ID then
                        local current = core.getCount(itemId, member.id)
                        if current ~= nil and current < keep then
                            local sourceId = override.destination == "Player" and playerId or STORAGE_ID
                            if sourceId ~= nil then
                                local available = core.getCount(itemId, sourceId) or 0
                                local requested = math.min(keep - current, math.max(0, available))
                                if requested > 0 then
                                    local item = core.catalogAllById[itemId] or core.catalogById[itemId]
                                    table.insert(jobs, {
                                        label = string.format(
                                            "%s refill: %s (%d) x%d <- %s",
                                            tostring(member.label or member.slotKey or "Pawn"),
                                            tostring(item and item.name or "Item"),
                                            itemId,
                                            requested,
                                            override.destination == "Player" and "Player" or "Storage"),
                                        meta = {
                                            pawnRefill = true,
                                            pawnLabel = tostring(member.label or member.slotKey or "Pawn"),
                                            itemId = itemId,
                                            target = keep,
                                            requested = requested,
                                            source = override.destination == "Player" and "Player" or "Storage",
                                            reason = tostring(reason or "policy poll"),
                                        },
                                        fn = function()
                                            local targetNow, targetErr = core.getCount(itemId, member.id)
                                            if targetNow == nil then return false, tostring(targetErr) end
                                            local needNow = math.max(0, keep - targetNow)
                                            if needNow <= 0 then return true end

                                            local sourceNow, sourceErr = core.getCount(itemId, sourceId)
                                            if sourceNow == nil then return false, tostring(sourceErr) end
                                            local moveNow = math.min(requested, needNow, math.max(0, sourceNow))
                                            if moveNow <= 0 then
                                                return true, "Refill source no longer has available quantity."
                                            end

                                            return core.transferStack(itemId, moveNow, sourceId, member.id)
                                        end,
                                    })
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    core.pawnCleaner.lastRefillQueued = #jobs
    if #jobs == 0 then
        core.pawnCleaner.refillStatus = string.format(
            "No Pawn shortfalls eligible for retrieval (%s).",
            tostring(reason or "policy poll"))
        return true, core.pawnCleaner.refillStatus, 0
    end

    local total = #jobs
    local id, err = core.enqueueMutationBatch(
        "Pawn auto-retrieval",
        jobs,
        {
            onProgress = function(progress)
                if progress.success then
                    core.pawnCleaner.refillStatus = string.format(
                        "Pawn auto-retrieval: %d/%d refill transfers complete.",
                        progress.processed or 0, total)
                end
            end,
            onComplete = function(summary)
                if summary.success then
                    core.pawnCleaner.completedRefills = (core.pawnCleaner.completedRefills or 0) + 1
                    core.pawnCleaner.refillStatus = string.format(
                        "Pawn auto-retrieval complete: %d/%d refill transfers (%s).",
                        summary.processed or 0, total, tostring(reason or "policy poll"))
                    core.analyzePawns()
                    core.refreshStorage()
                    core.refreshPlayer()
                else
                    core.pawnCleaner.enabled = false
                    core.pawnCleaner.baseline = nil
                    core.pawnCleaner.refillStatus = string.format(
                        "PAWN AUTO-RETRIEVAL DISABLED after transfer failure on %s: %s",
                        tostring(summary.failedLabel or "?"), tostring(summary.error or "unknown error"))
                    save_config()
                    notify_pawn_cleaner_control()
                end
            end,
        })

    if not id then
        core.pawnCleaner.refillStatus = "Pawn auto-retrieval could not queue: " .. tostring(err)
        return false, tostring(err), 0
    end

    core.pawnCleaner.refillStatus = string.format(
        "Pawn auto-retrieval queued: %d refill transfer%s (%s).",
        total, total == 1 and "" or "s", tostring(reason or "policy poll"))
    return true, core.pawnCleaner.refillStatus, total
end

-- Gear, lanterns, and Sealing Phial instances preserve exact StorageData identity.
-- Normal fungible stacks now use DD2's own passItem(StorageData, amount, destination)
-- path as well. This lets DD2 own all transfer side effects, including decay migration
-- (setupPassItemDecayData -> popStorageDecayData/addStorageDecayData), storage-row
-- removal, pass events, and any other native bookkeeping. Delete/recreate remains an
-- explicit compatibility/user-preference mode; it is never an automatic fallback.
function core.transferStack(itemId, amount, sourceId, destId)
    amount = math.floor(tonumber(amount) or 0)
    local item = core.catalogAllById[itemId] or core.catalogById[itemId]
    if not item then
        core.ensureCatalog(false)
        item = core.catalogAllById[itemId] or core.catalogById[itemId]
    end
    if item and core.requiresIdentityTransfer(item) then
        core.debugLog("Basic", "Transfer policy item=%s path=identity-preserve-native source=%s dest=%s amount=%s", tostring(itemId), tostring(sourceId), tostring(destId), tostring(amount))
        return transfer_equipment_instances(itemId, amount, sourceId, destId)
    end
    if itemId == WAKESHARD_ID then
        return false, "Existing Wakestone Shards are protected by the transfer safeguard."
    end

    local safeAmount, capacityResult = capacity_limited_destination_amount(
        itemId, amount, destId, true, "Transfer")
    if safeAmount == nil then return false, capacityResult end
    if safeAmount <= 0 then return true, capacityResult end

    local mode = core.getTransferMode()
    local ok, result
    if mode == "Recreate" then
        core.debugLog("Basic", "Transfer policy item=%s path=delete-recreate-explicit source=%s dest=%s amount=%s", tostring(itemId), tostring(sourceId), tostring(destId), tostring(safeAmount))
        ok, result = core._transferRecreatedStack(itemId, safeAmount, sourceId, destId)
    else
        core.debugLog("Basic", "Transfer policy item=%s path=native-passItem source=%s dest=%s amount=%s", tostring(itemId), tostring(sourceId), tostring(destId), tostring(safeAmount))
        ok, result = transfer_native_stack(itemId, safeAmount, sourceId, destId)
    end

    if not ok then return false, result end
    if capacityResult then return true, capacityResult end
    return true, result
end

function core.transferPlayerStorage(itemId, amount, toStorage)
    local playerId = core.getPlayerId()
    if not playerId then return false, "Player CharacterID is unavailable." end
    if toStorage then
        return core.transferStack(itemId, amount, playerId, STORAGE_ID)
    end
    return core.transferStack(itemId, amount, STORAGE_ID, playerId)
end


local function type_name(td)
    if not td then return "?" end
    return safe_call(function() return td:get_full_name() end, safe_call(function() return td:get_name() end, "?"))
end

local function method_signature(method)
    local name = safe_call(function() return method:get_name() end, "?")
    local params = {}
    local paramTypes = safe_call(function() return method:get_param_types() end, {}) or {}
    for _, ptype in pairs(paramTypes) do
        table.insert(params, type_name(ptype))
    end
    local ret = type_name(safe_call(function() return method:get_return_type() end, nil))
    return string.format("%s %s(%s)", ret, tostring(name), table.concat(params, ", "))
end

local function method_param_names(method)
    local names = safe_call(function() return method:get_param_names() end, {}) or {}
    local keyed = {}
    for key, value in pairs(names) do
        table.insert(keyed, { order = tonumber(key) or 1000000, value = tostring(value or "") })
    end
    table.sort(keyed, function(a, b) return a.order < b.order end)
    local out = {}
    for _, entry in ipairs(keyed) do table.insert(out, entry.value) end
    return out
end

local function storage_data_item_id(storageData)
    if not storageData then return nil end
    local id = tonumber(safe_field(storageData, "_ItemId", nil))
    if id ~= nil then return id end
    local itemData = safe_field(storageData, "_ItemData", nil)
    return item_id_from_param(itemData)
end

local function storage_data_storage_id(storageData)
    if not storageData then return nil end
    return tonumber(safe_field(storageData, "_StorageId", nil))
end

local function storage_data_chara_id(storageData)
    if not storageData then return nil end
    return tonumber(safe_field(storageData, "_CharaId", nil))
end

local function storage_data_num(storageData)
    if not storageData then return nil end
    return tonumber(safe_field(storageData, "_Num", nil))
end

equipped_storage_ids = function(ownerId)
    local ids = {}
    local im = get_item_manager()
    if not im or ownerId == nil or ownerId == STORAGE_ID then return ids end

    local equipData = safe_call(function() return im:getEquipData(ownerId) end, nil)
    local equipList = equipData and safe_call(function() return equipData:get_EquipList() end, nil) or nil
    for i = 0, managed_list_count(equipList) - 1 do
        local storageData = managed_list_at(equipList, i)
        local storageId = storage_data_storage_id(storageData)
        if storageId ~= nil then ids[storageId] = true end
    end

    -- Lanterns are equipped through a separate ItemManager subsystem and do not
    -- set generic StorageData.IsEquipped. Include the native equipped-lantern
    -- StorageId so instance transfers cannot move the active lantern.
    if getEquipLanternStorageIdMethod then
        local lanternStorageId = safe_call(function()
            return tonumber(getEquipLanternStorageIdMethod:call(im, ownerId))
        end, nil)
        if lanternStorageId ~= nil and lanternStorageId >= 0 then
            ids[lanternStorageId] = true
        end
    end
    return ids
end

function core.getEquippedLanternStorageId(ownerId)
    if ownerId == nil or ownerId == STORAGE_ID or not getEquipLanternStorageIdMethod then return nil end
    local im = get_item_manager()
    if not im then return nil end
    return safe_call(function() return tonumber(getEquipLanternStorageIdMethod:call(im, ownerId)) end, nil)
end

function core.isInstanceEquipped(itemId, storageId, ownerId)
    if ownerId == nil or ownerId == STORAGE_ID or storageId == nil then return false end
    storageId = tonumber(storageId)
    local row = get_storage_master_row(tonumber(itemId), ownerId, storageId)
    if row and storage_master_row_is_equipped(row) then return true end
    return equipped_storage_ids(ownerId)[storageId] == true
end

function core.getEquippedCount(ownerId, itemId)
    if ownerId == nil or ownerId == STORAGE_ID then return 0 end
    local equippedIds = equipped_storage_ids(ownerId)
    if next(equippedIds) == nil then return 0 end

    local count = 0
    local records = core.getLiveItemRecords(itemId, ownerId)
    for _, record in ipairs(records) do
        if record.storageId ~= nil and equippedIds[record.storageId] then
            count = count + 1
        end
    end
    return count
end


function core.resolveNativeEquipmentTransfer(force)
    if core.nativeTransfer.scanned and not force then
        return core.nativeTransfer.method ~= nil, core.nativeTransfer.reason
    end

    core.nativeTransfer.scanned = true
    core.nativeTransfer.method = nil
    core.nativeTransfer.noLockMethod = nil
    core.nativeTransfer.signature = nil
    core.nativeTransfer.paramNames = nil

    if not ItemManagerType then
        core.nativeTransfer.reason = "app.ItemManager type is unavailable."
        return false, core.nativeTransfer.reason
    end

    -- Resolve only the exact live TypeDB method reported by DD2.
    -- Do not heuristically score vaguely transfer-like names: equipment is
    -- instance-backed StorageData and guessing the wrong API could destroy state.
    local method = safe_call(function() return ItemManagerType:get_method(PASS_ITEM_SIGNATURE) end, nil)
    local noLock = safe_call(function() return ItemManagerType:get_method(PASS_ITEM_NOLOCK_SIGNATURE) end, nil)
    core.nativeTransfer.noLockMethod = noLock

    if not method then
        core.nativeTransfer.reason = "Exact ItemManager." .. PASS_ITEM_SIGNATURE .. " was not found in the current runtime."
        return false, core.nativeTransfer.reason
    end

    core.nativeTransfer.method = method
    core.nativeTransfer.signature = method_signature(method)
    core.nativeTransfer.paramNames = method_param_names(method)
    core.nativeTransfer.reason = "Resolved exact native API: " .. core.nativeTransfer.signature
    return true, core.nativeTransfer.reason
end

function core.getNativeTransferStatus()
    if not core.nativeTransfer.scanned then core.resolveNativeEquipmentTransfer(false) end
    return core.nativeTransfer
end

get_source_storage_data = function(itemId, sourceId)
    local im = get_item_manager()
    if not im then return nil, "ItemManager not ready." end
    if not getStorageDataByIdMethod then
        return nil, "Exact ItemManager.getStorageData(System.Int32, app.CharacterID) method is unavailable."
    end

    local ok, storageData = pcall(function()
        return getStorageDataByIdMethod:call(im, itemId, sourceId)
    end)
    if not ok then
        core.debugLog("Basic", "getStorageData exact invocation failed item=%s source=%s error=%s", tostring(itemId), tostring(sourceId), tostring(storageData))
        return nil, "Exact getStorageData invocation failed: " .. tostring(storageData)
    end
    if not storageData then
        core.debugLog("Verbose", "getStorageData returned nil item=%s source=%s", tostring(itemId), tostring(sourceId))
        return nil, "Could not resolve source StorageData for this item."
    end

    local actualItemId = storage_data_item_id(storageData)
    local actualSourceId = storage_data_chara_id(storageData)
    local storageId = storage_data_storage_id(storageData)
    local quantity = storage_data_num(storageData)
    core.debugLog("Trace", "StorageData resolved item=%s source=%s rawItem=%s rawChara=%s storageId=%s num=%s", tostring(itemId), tostring(sourceId), tostring(actualItemId), tostring(actualSourceId), tostring(storageId), tostring(quantity))

    if actualItemId == nil then
        return nil, "StorageData ItemID is unavailable; refusing native transfer."
    end
    if actualItemId ~= itemId then
        return nil, string.format("StorageData item mismatch: expected %d, got %d.", itemId, actualItemId)
    end
    if actualSourceId ~= nil and character_id_hex32(actualSourceId) ~= character_id_hex32(sourceId) then
        return nil, string.format(
            "StorageData owner mismatch: expected %s (%s), got %s (%s).",
            tostring(sourceId), tostring(character_id_hex32(sourceId)),
            tostring(actualSourceId), tostring(character_id_hex32(actualSourceId)))
    end
    return storageData
end

-- Read-only helpers for the live StorageMasterData row. The SDK dump shows
-- StorageMasterData._Param is an app.ItemDefine.StorageData *value* and that the
-- master row forwards ItemId/Num/StorageId/CharaId/IsEquipped/EquipSlot itself.
-- REFramework can expose value-type returns differently from normal managed
-- objects. Diagnostics still compare get_Param() with the raw _Param field, but only raw
-- StorageData fields are treated as meaningful diagnostics; the master row remains
-- the canonical live record.
local function readonly_value(value, missingReason)
    if value == nil then return sdk_skipped(missingReason or "Value unavailable.") end
    return { state = "ok", value = value }
end

local function readonly_type_result(value, missingReason)
    if value == nil then return sdk_skipped(missingReason or "Object unavailable.") end
    local name = safe_full_type_name(value)
    if name == nil or name == "" then
        name = tostring(type(value)) .. " / " .. tostring(value)
    end
    return { state = "ok", value = name, raw = value }
end

local function storage_value_field_result(storageData, fieldName)
    if storageData == nil then return sdk_skipped("StorageData route unavailable.") end
    local value = safe_field(storageData, fieldName, nil)
    if value == nil then return sdk_skipped(fieldName .. " unavailable on this StorageData route.") end
    return { state = "ok", value = value, raw = value }
end

local function resolve_readonly_master_row(itemId, ownerId, storageId)
    local row = get_storage_master_row(itemId, ownerId, storageId)
    if not row then
        return nil, {
            state = "error",
            error = storageId ~= nil and "No matching StorageMasterData row for this ItemID/owner/StorageId." or "No matching StorageMasterData row for this ItemID/owner.",
        }
    end

    local rowItemId = storage_master_row_item_id(row)
    local rowNum = storage_master_row_quantity(row)
    local rowStorageId = safe_call(function() return tonumber(row:get_StorageId()) end, nil)
    if rowStorageId == nil then rowStorageId = tonumber(safe_field(row, "_StorageId", nil)) end

    if rowItemId ~= itemId then
        return nil, {
            state = "error",
            error = string.format(
                "StorageMasterData identity mismatch: expected %d, row reports %s.",
                itemId, tostring(rowItemId)),
            masterItemId = rowItemId,
            masterNum = rowNum,
            masterStorageId = rowStorageId,
        }
    end

    return row, {
        state = "ok",
        value = true,
        source = storageId ~= nil and "ItemManager.getStorageMasterList(owner) / matching ItemID + StorageId" or "ItemManager.getStorageMasterList(owner) / matching ItemID",
        masterItemId = rowItemId,
        masterNum = rowNum,
        masterStorageId = rowStorageId,
    }
end

-- Read-only live validation for APIs discovered in the SDK dump. Nothing in this
-- function writes ItemCommonParam, StorageData, StorageMasterData, inventory, or
-- configuration. The Item Analysis add-on invokes it only on explicit user request.
function core.runReadOnlySdkItemChecks(itemId, ownerId, storageId)
    itemId = math.floor(tonumber(itemId) or -1)
    if itemId < 0 then return nil, "Invalid ItemID." end

    core.ensureCatalog(false, true)
    local item = core.getCatalogEntry(itemId, true)
    if not item or not item.param then
        return nil, "ItemCommonParam is unavailable for this ItemID."
    end

    if ownerId ~= nil then ownerId = math.floor(tonumber(ownerId) or -1) end
    if storageId ~= nil then storageId = math.floor(tonumber(storageId) or -1) end
    if ownerId ~= nil and ownerId < 0 then ownerId = nil end

    local result = {
        itemId = itemId,
        ownerId = ownerId,
        param = {},
        master = {},
        nested = {},
        transfer = {},
        instance = {},
        lantern = {},
    }

    result.param.rawStackNum = { state = "ok", value = read_raw_stack_num(item.param) }
    result.param.warehouseMaxStackNum = { state = "ok", value = read_warehouse_max_stack(item.param) }
    result.param.capturedVanilla = { state = "ok", value = core.stack.vanillaById[itemId] }
    result.param.capturedWarehouseVanilla = { state = "ok", value = item.vanillaWarehouseStackNum or core.stack.warehouseVanillaGlobal }
    result.param.defaultStackNum = sdk_readonly_result(getDefaultStackNumMethod, item.param)
    local diagIm = get_item_manager()
    result.param.nativeNoStack = diagIm
        and sdk_readonly_result(isNoStacItemMethod, diagIm, item.param)
        or sdk_skipped("ItemManager is unavailable.")
    result.param.capturedNativeNoStack = { state = "ok", value = core.getNativeNoStack(item) }
    result.param.isEquip = sdk_readonly_result(getIsEquipMethod, item.param)
    result.param.isEquipData = sdk_readonly_result(getIsEquipDataMethod, item.param)
    result.param.isItemData = sdk_readonly_result(getIsItemDataMethod, item.param)

    if ownerId ~= nil then
        result.param.ownerStackNum = sdk_readonly_result(getStackNumMethod, item.param, ownerId)
    else
        result.param.ownerStackNum = sdk_skipped("No live owner context.")
    end

    if ownerId == nil then
        result.master.lookup = sdk_skipped("No live owner context.")
        result.master.source = sdk_skipped("No live owner context.")
        result.master.typeName = sdk_skipped("No live owner context.")
        result.master.itemId = sdk_skipped("No live owner context.")
        result.master.num = sdk_skipped("No live owner context.")
        result.master.internalFieldId = sdk_skipped("No live owner context.")
        result.master.charaId = sdk_skipped("No live owner context.")
        result.master.isEquipped = sdk_skipped("No live owner context.")
        result.master.equipSlot = sdk_skipped("No live owner context.")
        result.master.updateIndex = sdk_skipped("No live owner context.")
        result.master.arisenEquipNo = sdk_skipped("No live owner context.")
        result.master.itemDataType = sdk_skipped("No live owner context.")
        result.nested.getterPresent = sdk_skipped("No live owner context.")
        result.nested.getterType = sdk_skipped("No live owner context.")
        result.nested.fieldPresent = sdk_skipped("No live owner context.")
        result.nested.fieldType = sdk_skipped("No live owner context.")
        result.transfer.passSource = sdk_skipped("No live owner context.")
        result.transfer.passFalse = sdk_skipped("No live owner context.")
        result.transfer.passTrue = sdk_skipped("No live owner context.")
        result.transfer.passCommandFalse = sdk_skipped("No live owner context.")
        result.transfer.passCommandTrue = sdk_skipped("No live owner context.")
        return result
    end

    local im = get_item_manager()
    if not im then
        result.master.lookup = { state = "error", error = "ItemManager not ready." }
        return result
    end

    local row, resolved = resolve_readonly_master_row(itemId, ownerId, storageId)
    result.master.lookup = {
        state = resolved and resolved.state or "error",
        value = resolved and resolved.value or nil,
        error = resolved and resolved.error or "Live master-row resolution failed.",
    }
    result.master.source = {
        state = resolved and resolved.source and "ok" or "skipped",
        value = resolved and resolved.source or nil,
        error = resolved and resolved.error or nil,
    }
    result.master.typeName = readonly_type_result(row, "No validated master row.")

    if not row or not resolved or resolved.state ~= "ok" then
        result.master.itemId = readonly_value(resolved and resolved.masterItemId, "Master ItemID unavailable.")
        result.master.num = readonly_value(resolved and resolved.masterNum, "Master quantity unavailable.")
        result.master.internalFieldId = readonly_value(resolved and resolved.masterStorageId, "Master raw StorageId unavailable.")
        result.master.charaId = sdk_skipped("No validated master row.")
        result.master.isEquipped = sdk_skipped("No validated master row.")
        result.master.equipSlot = sdk_skipped("No validated master row.")
        result.master.updateIndex = sdk_skipped("No validated master row.")
        result.master.arisenEquipNo = sdk_skipped("No validated master row.")
        result.master.itemDataType = sdk_skipped("No validated master row.")
        result.nested.getterPresent = sdk_skipped("No validated master row.")
        result.nested.getterType = sdk_skipped("No validated master row.")
        result.nested.fieldPresent = sdk_skipped("No validated master row.")
        result.nested.fieldType = sdk_skipped("No validated master row.")
        result.transfer.passSource = sdk_skipped("No validated StorageData route.")
        result.transfer.passFalse = sdk_skipped("No validated StorageData route.")
        result.transfer.passTrue = sdk_skipped("No validated StorageData route.")
        result.transfer.passCommandFalse = sdk_skipped("No validated StorageData route.")
        result.transfer.passCommandTrue = sdk_skipped("No validated StorageData route.")
        return result
    end

    -- Direct StorageMasterData getters are the canonical live record view.
    result.master.itemId = sdk_readonly_result(getMasterItemIdMethod, row)
    result.master.num = sdk_readonly_result(getMasterNumMethod, row)
    result.master.internalFieldId = sdk_readonly_result(getMasterStorageIdMethod, row)
    result.master.charaId = sdk_readonly_result(getMasterCharaIdMethod, row)
    result.master.isEquipped = sdk_readonly_result(getMasterIsEquippedMethod, row)
    result.master.equipSlot = sdk_readonly_result(getMasterEquipSlotMethod, row)
    result.master.updateIndex = sdk_readonly_result(getMasterUpdateIndexMethod, row)
    result.master.arisenEquipNo = sdk_readonly_result(getMasterArisenEquipNoMethod, row)
    local masterItemData = sdk_readonly_result(getMasterItemDataMethod, row)
    result.master.itemDataType = masterItemData.state == "ok"
        and readonly_type_result(masterItemData.raw, "Master ItemData is nil.")
        or masterItemData

    -- Probe the nested StorageData two ways. Do not assume either route is valid.
    local getterParamResult = sdk_readonly_result(getMasterParamMethod, row)
    local getterParam = getterParamResult.state == "ok" and getterParamResult.raw or nil
    local fieldParam = safe_field(row, "_Param", nil)

    result.nested.getterPresent = {
        state = "ok",
        value = getterParam ~= nil,
        error = getterParamResult.state == "error" and getterParamResult.error or nil,
    }
    result.nested.getterType = readonly_type_result(getterParam, "get_Param() returned nil/unusable value.")
    result.nested.fieldPresent = { state = "ok", value = fieldParam ~= nil }
    result.nested.fieldType = readonly_type_result(fieldParam, "_Param field returned nil/unusable value.")

    local function fill_nested(prefix, value)
        result.nested[prefix .. "ItemIdField"] = storage_value_field_result(value, "_ItemId")
        result.nested[prefix .. "StorageIdField"] = storage_value_field_result(value, "_StorageId")
        result.nested[prefix .. "NumField"] = storage_value_field_result(value, "_Num")
        result.nested[prefix .. "CharaIdField"] = storage_value_field_result(value, "_CharaId")
        result.nested[prefix .. "IsEquippedField"] = storage_value_field_result(value, "_IsEquipped")
        result.nested[prefix .. "EquipSlotField"] = storage_value_field_result(value, "_EquipSlot")
    end

    if getterParam ~= nil then
        fill_nested("getter", getterParam)
    else
        for _, suffix in ipairs({
            "ItemIdField", "StorageIdField", "NumField", "CharaIdField",
            "IsEquippedField", "EquipSlotField",
        }) do
            result.nested["getter" .. suffix] = sdk_skipped("get_Param() route unavailable.")
        end
    end

    if fieldParam ~= nil then
        fill_nested("field", fieldParam)
    else
        for _, suffix in ipairs({
            "ItemIdField", "StorageIdField", "NumField", "CharaIdField",
            "IsEquippedField", "EquipSlotField",
        }) do
            result.nested["field" .. suffix] = sdk_skipped("_Param field route unavailable.")
        end
    end

    -- Both routes have repeatedly exposed the same raw StorageData fields in live
    -- testing. Keep comparing them as a sanity check, but invoke transfer guards only
    -- once against a canonical parameter (raw _Param preferred, get_Param fallback).
    local function nested_value(prefix, suffix)
        local entry = result.nested[prefix .. suffix]
        if entry and entry.state == "ok" then return entry.value end
        return nil
    end

    local rawKeys = {
        "ItemIdField", "StorageIdField", "NumField", "CharaIdField",
        "IsEquippedField", "EquipSlotField",
    }
    local routesAgree = getterParam ~= nil and fieldParam ~= nil
    if routesAgree then
        for _, suffix in ipairs(rawKeys) do
            if nested_value("getter", suffix) ~= nested_value("field", suffix) then
                routesAgree = false
                break
            end
        end
    end
    result.nested.routesAgree = { state = "ok", value = routesAgree }

    local primaryParam = fieldParam or getterParam
    local primaryPrefix = fieldParam ~= nil and "field" or (getterParam ~= nil and "getter" or nil)
    result.nested.primarySource = primaryPrefix
        and { state = "ok", value = primaryPrefix == "field" and "_Param raw field" or "get_Param()" }
        or sdk_skipped("No StorageData route available.")
    result.nested.primaryType = primaryPrefix == "field" and result.nested.fieldType
        or (primaryPrefix == "getter" and result.nested.getterType or sdk_skipped("No StorageData route available."))
    if primaryPrefix then
        for _, suffix in ipairs(rawKeys) do
            result.nested["primary" .. suffix] = result.nested[primaryPrefix .. suffix]
        end
    else
        for _, suffix in ipairs(rawKeys) do
            result.nested["primary" .. suffix] = sdk_skipped("No StorageData route available.")
        end
    end

    if primaryParam ~= nil then
        result.transfer.passSource = { state = "ok", value = primaryPrefix == "field" and "_Param raw field" or "get_Param()" }
        result.transfer.passFalse = sdk_readonly_result(isPassEnableMethod, nil, primaryParam, false)
        result.transfer.passTrue = sdk_readonly_result(isPassEnableMethod, nil, primaryParam, true)
        result.transfer.passCommandFalse = sdk_readonly_result(isPassEnableCommandMethod, nil, primaryParam, false)
        result.transfer.passCommandTrue = sdk_readonly_result(isPassEnableCommandMethod, nil, primaryParam, true)
    else
        result.transfer.passSource = sdk_skipped("No StorageData route available.")
        result.transfer.passFalse = sdk_skipped("No StorageData route available.")
        result.transfer.passTrue = sdk_skipped("No StorageData route available.")
        result.transfer.passCommandFalse = sdk_skipped("No StorageData route available.")
        result.transfer.passCommandTrue = sdk_skipped("No StorageData route available.")
    end

    local records = ownerId ~= nil and core.getLiveItemRecords(itemId, ownerId) or {}
    local storageIds = {}
    local unique = {}
    local duplicateStorageId = false
    for _, record in ipairs(records) do
        local sid = record.storageId
        if sid ~= nil then
            table.insert(storageIds, tostring(sid))
            if unique[sid] then duplicateStorageId = true else unique[sid] = true end
        else
            table.insert(storageIds, "—")
        end
    end
    result.instance.focusedStorageId = readonly_value(storageId, "No focused StorageId (catalog/stack row).")
    if storageId ~= nil and getStorageDataByStorageIdMethod then
        local exactStorageData = safe_call(function()
            return getStorageDataByStorageIdMethod:call(im, storageId)
        end, nil)
        result.instance.byStorageIdResolved = { state = "ok", value = exactStorageData ~= nil }
        result.instance.byStorageIdItemId = exactStorageData
            and readonly_value(storage_data_item_id(exactStorageData), "Exact StorageData ItemID unavailable.")
            or sdk_skipped("getStorageDataByStorageId returned no record.")
        result.instance.byStorageIdStorageId = exactStorageData
            and readonly_value(storage_data_storage_id(exactStorageData), "Exact StorageData StorageId unavailable.")
            or sdk_skipped("getStorageDataByStorageId returned no record.")
    else
        result.instance.byStorageIdResolved = sdk_skipped("No focused StorageId or method unavailable.")
        result.instance.byStorageIdItemId = sdk_skipped("No focused StorageId or method unavailable.")
        result.instance.byStorageIdStorageId = sdk_skipped("No focused StorageId or method unavailable.")
    end
    result.instance.recordCount = { state = "ok", value = #records }
    result.instance.storageIds = { state = "ok", value = #storageIds > 0 and table.concat(storageIds, ", ") or "—" }
    result.instance.storageIdsUnique = { state = "ok", value = not duplicateStorageId }
    result.instance.instanceBacked = { state = "ok", value = core.isInstanceBacked(item) }

    if item.isLantern and ownerId ~= nil then
        local equipSid = core.getEquippedLanternStorageId(ownerId)
        result.lantern.equippedStorageId = readonly_value(equipSid, "Equipped lantern StorageId unavailable.")
        result.lantern.focusIsEquippedLantern = storageId ~= nil and equipSid ~= nil
            and { state = "ok", value = storageId == equipSid }
            or sdk_skipped("Focused/equipped lantern StorageId unavailable.")

        if storageId ~= nil and getLanternInfoByStorageIdMethod then
            local im = get_item_manager()
            local info = im and safe_call(function()
                return getLanternInfoByStorageIdMethod:call(im, storageId)
            end, nil) or nil
            if info ~= nil then
                result.lantern.infoStorageId = readonly_value(tonumber(safe_field(info, "StorageId", nil)), "LanternInfo.StorageId unavailable.")
                result.lantern.charaId = readonly_value(tonumber(safe_field(info, "CharaId", nil)), "LanternInfo.CharaId unavailable.")
                result.lantern.isEquip = readonly_value(safe_field(info, "IsEquip", nil), "LanternInfo.IsEquip unavailable.")
                result.lantern.oil = readonly_value(tonumber(safe_field(info, "Oil", nil)), "LanternInfo.Oil unavailable.")
                result.lantern.itemType = readonly_value(tonumber(safe_field(info, "ItemType", nil)), "LanternInfo.ItemType unavailable.")
                result.lantern.dateTimer = readonly_value(tonumber(safe_field(info, "DateTimer", nil)), "LanternInfo.DateTimer unavailable.")
            else
                result.lantern.infoStorageId = sdk_skipped("getLanternInfo(StorageId) returned no record.")
            end
        end
    end

    return result
end

function core._characterForOwnerId(ownerId)
    ownerId = tonumber(ownerId)
    if ownerId == nil or ownerId == STORAGE_ID then return nil end

    local player = get_player()
    if player and get_chara_id(player) == ownerId then return player end

    local party = core.refreshParty() or {}
    for _, member in ipairs(party) do
        if member.id == ownerId and member.character then return member.character end
    end
    return nil
end

function core._recreateAdd(itemManager, itemId, amount, ownerId)
    if ownerId == STORAGE_ID then
        if not core._recreateTransferMethods.forceWarehouse then
            return false, "forceGetItemToWarehouse(System.Int32,System.Int32) is unavailable."
        end
        local option = core._makeRecreateTransferOption()
        if option and core._recreateTransferMethods.forceWarehouseOption then
            local ok, err = pcall(function()
                core._recreateTransferMethods.forceWarehouseOption:call(itemManager, itemId, amount, option)
            end)
            if ok then return true end
            core.debugLog("Basic", "forceGetItemToWarehouse(option) failed item=%s amount=%s error=%s; falling back to plain overload", tostring(itemId), tostring(amount), tostring(err))
        end
        local ok, err = pcall(function()
            core._recreateTransferMethods.forceWarehouse:call(itemManager, itemId, amount)
        end)
        return ok, err
    end

    local character = core._characterForOwnerId(ownerId)
    if not character then return false, "Destination app.Character could not be resolved." end
    if not core._recreateTransferMethods.getItemCharacter then
        return false, "getItem(System.Int32,System.Int32,app.Character,GetItemOption) is unavailable."
    end
    local option = core._makeRecreateTransferOption()
    if not option then return false, "Could not create transfer GetItemOption." end
    local ok, err = pcall(function()
        core._recreateTransferMethods.getItemCharacter:call(itemManager, itemId, amount, character, option)
    end)
    return ok, err
end

function core._recreateRemove(itemManager, itemId, amount, ownerId)
    -- Decay-managed stacks cannot reliably be removed through deleteItem(...).
    -- Reuse IM's verified decay-aware quantity path, which reconciles DecayData
    -- before changing StorageMasterData._Num. The destination is still recreated
    -- independently, so source decay metadata is never transferred across owners.
    if is_decay_item(itemId) then
        return core.removeItem(itemId, amount, ownerId)
    end

    if ownerId == STORAGE_ID then
        if not core._recreateTransferMethods.deleteItemCharacterId then
            return false, "deleteItem(System.Int32,System.Int32,app.CharacterID) is unavailable."
        end
        local ok, err = pcall(function()
            core._recreateTransferMethods.deleteItemCharacterId:call(itemManager, itemId, amount, ownerId)
        end)
        return ok, err
    end

    local character = core._characterForOwnerId(ownerId)
    if not character then return false, "Source app.Character could not be resolved." end
    if not core._recreateTransferMethods.deleteItemCharacter then
        return false, "deleteItem(System.Int32,System.Int32,app.Character) is unavailable."
    end
    local ok, err = pcall(function()
        core._recreateTransferMethods.deleteItemCharacter:call(itemManager, itemId, amount, character)
    end)
    return ok, err
end

core._transferRecreatedStack = function(itemId, amount, sourceId, destId)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 or sourceId == nil or destId == nil or sourceId == destId then
        return false, "Invalid recreate-transfer request."
    end

    local im = get_item_manager()
    if not im then return false, "ItemManager not ready." end

    local sourceBefore, sourceErr = core.getCount(itemId, sourceId)
    if sourceBefore == nil then return false, sourceErr end
    local destBefore, destErr = core.getCount(itemId, destId)
    if destBefore == nil then return false, destErr end
    if sourceBefore < amount then return false, "Source does not contain that many items." end

    core.debugLog("Verbose", "Recreate transfer begin item=%s amount=%d source=%s dest=%s sourceBefore=%s destBefore=%s", tostring(itemId), amount, tostring(sourceId), tostring(destId), tostring(sourceBefore), tostring(destBefore))

    local removeOk, removeErr = core._recreateRemove(im, itemId, amount, sourceId)
    if not removeOk then return false, "Source removal failed: " .. tostring(removeErr) end

    local sourceAfter, sourceVerifyErr = core.getCount(itemId, sourceId)
    if sourceAfter == nil then
        local reason = string.format(
            "Source removal returned but source quantity became unreadable; destination was NOT created (item=%s amount=%d source=%s error=%s).",
            tostring(itemId), amount, tostring(sourceId), tostring(sourceVerifyErr))
        trip_mutation_safety_stop(reason)
        return false, reason
    end

    local expectedSource = sourceBefore - amount
    if sourceAfter ~= expectedSource then
        local removed = sourceBefore - sourceAfter
        if removed > 0 then
            local rollbackOk, rollbackErr = core._recreateAdd(im, itemId, removed, sourceId)
            local rollbackCount = core.getCount(itemId, sourceId)
            if rollbackOk and rollbackCount == sourceBefore then
                return false, string.format(
                    "Source removal produced the wrong delta and was restored (before=%d requested=%d actualRemoved=%d).",
                    sourceBefore, amount, removed)
            end
            local reason = string.format(
                "Source removal produced the wrong delta and rollback failed (item=%s requested=%d before=%d after=%s rollback_error=%s rollback_count=%s).",
                tostring(itemId), amount, sourceBefore, tostring(sourceAfter), tostring(rollbackErr), tostring(rollbackCount))
            trip_mutation_safety_stop(reason)
            return false, reason
        end
        return false, string.format(
            "Source removal did not produce the requested quantity; destination was NOT created (before=%d requested=%d expected=%d actual=%d).",
            sourceBefore, amount, expectedSource, sourceAfter)
    end

    local addOk, addErr = core._recreateAdd(im, itemId, amount, destId)
    local destAfter, destVerifyErr = core.getCount(itemId, destId)
    if addOk and destAfter == destBefore + amount then
        core.debugLog("Verbose", "Recreate transfer verified item=%s amount=%d source=%s->%s dest=%s->%s", tostring(itemId), amount, tostring(sourceBefore), tostring(sourceAfter), tostring(destBefore), tostring(destAfter))
        return true
    end

    if destAfter == nil then
        local reason = string.format(
            "Destination recreation returned but destination quantity became unreadable; source remains reduced and automatic rollback is unsafe (item=%s amount=%d dest=%s add_error=%s verify_error=%s).",
            tostring(itemId), amount, tostring(destId), tostring(addErr), tostring(destVerifyErr))
        trip_mutation_safety_stop(reason)
        return false, reason
    end

    local destDelta = destAfter - destBefore
    if destDelta < 0 then
        local reason = string.format(
            "Destination recreation unexpectedly reduced destination quantity (item=%s before=%d after=%d); automatic rollback is unsafe.",
            tostring(itemId), destBefore, destAfter)
        trip_mutation_safety_stop(reason)
        return false, reason
    end

    if destDelta > 0 then
        local cleanupOk, cleanupErr = core._recreateRemove(im, itemId, destDelta, destId)
        local cleanupCount = core.getCount(itemId, destId)
        if not cleanupOk or cleanupCount ~= destBefore then
            local reason = string.format(
                "Destination recreation partially succeeded and cleanup failed (item=%s delta=%d before=%d after=%d cleanup_error=%s cleanup_count=%s).",
                tostring(itemId), destDelta, destBefore, destAfter, tostring(cleanupErr), tostring(cleanupCount))
            trip_mutation_safety_stop(reason)
            return false, reason
        end
    end

    local rollbackOk, rollbackErr = core._recreateAdd(im, itemId, amount, sourceId)
    local rollbackCount = core.getCount(itemId, sourceId)
    if rollbackOk and rollbackCount == sourceBefore then
        return false, string.format(
            "Destination recreation failed; destination was cleaned and source restored (add_ok=%s expectedDest=%s actualDest=%s add_error=%s).",
            tostring(addOk), tostring(destBefore + amount), tostring(destAfter), tostring(addErr))
    end

    local reason = string.format(
        "Recreate transfer failed and source rollback could not restore the original quantity (item=%s amount=%d source=%s dest=%s add_error=%s rollback_error=%s rollback_count=%s expected=%s).",
        tostring(itemId), amount, tostring(sourceId), tostring(destId), tostring(addErr), tostring(rollbackErr), tostring(rollbackCount), tostring(sourceBefore))
    trip_mutation_safety_stop(reason)
    return false, reason
end

call_native_storage_transfer = function(storageData, destId, amount)
    if core.nativeTransfer.sessionFaulted or core.mutations.safetyStopped then
        return false, "Native transfer circuit breaker is active: " .. tostring(core.nativeTransfer.sessionFaultReason or core.mutations.safetyStopReason or "previous native transfer fault")
    end

    local okResolve, resolveReason = core.resolveNativeEquipmentTransfer(false)
    if not okResolve then return false, resolveReason end

    local im = get_item_manager()
    if not im then return false, "ItemManager not ready." end

    -- passItem is the public/locking wrapper exposed by the live DD2 TypeDB:
    --   passItem(StorageData, amount, CharacterID, bool)
    amount = math.max(1, math.floor(tonumber(amount) or 1))
    local sourceItemId = storage_data_item_id(storageData)
    local sourceOwnerId = storage_data_chara_id(storageData)
    local sourceStorageId = storage_data_storage_id(storageData)
    local sourceNum = storage_data_num(storageData)
    core.debugLog("Verbose", "passItem prepare item=%s amount=%d sourceOwner=%s sourceStorageId=%s sourceNum=%s dest=%s bool=%s", tostring(sourceItemId), amount, tostring(sourceOwnerId), tostring(sourceStorageId), tostring(sourceNum), tostring(destId), tostring(core.nativeTransfer.boolValue == true))

    -- StorageData._Num is UInt16 in the live value type. Never feed passItem an
    -- empty/stale record or an amount larger than the exact record being passed.
    -- Historical crashes included single-item transfers, so quantity alone is not
    -- treated as the safety condition; the source record itself must be coherent.
    if sourceItemId == nil or sourceOwnerId == nil or sourceStorageId == nil or sourceNum == nil then
        return false, "StorageData is incomplete; refusing native passItem."
    end
    sourceNum = math.floor(tonumber(sourceNum) or 0)
    if sourceNum <= 0 then
        return false, string.format("StorageData %s/%s has Num=%s; refusing native passItem on a zero/stale record.", tostring(sourceItemId), tostring(sourceStorageId), tostring(sourceNum))
    end
    if amount > sourceNum then
        return false, string.format("Requested transfer amount %d exceeds exact StorageData Num %d (item=%s storageId=%s).", amount, sourceNum, tostring(sourceItemId), tostring(sourceStorageId))
    end

    -- Fail closed. passItem must never run unless DD2's own eligibility predicate
    -- resolves successfully and explicitly returns true. A marshaling exception,
    -- nil result, or missing guard is a safety rejection rather than permission.
    if not isPassEnableMethod then
        return false, "DD2 isPassEnable(StorageData, Boolean) is unavailable; refusing unsafe passItem call."
    end

    local guardOk, passAllowed = pcall(function()
        -- IL2CPP dump marks isPassEnable(in StorageData, Boolean) STATIC; the
        -- StorageData parameter is ByRef/In. REFramework therefore receives nil
        -- as the method instance and the live value as the declared parameter.
        return isPassEnableMethod:call(nil, storageData, core.nativeTransfer.boolValue == true)
    end)
    if not guardOk then
        core.debugLog("Basic", "isPassEnable invocation failed item=%s dest=%s error=%s", tostring(sourceItemId), tostring(destId), tostring(passAllowed))
        return false, "DD2 isPassEnable invocation failed; passItem was NOT called: " .. tostring(passAllowed)
    end
    core.debugLog("Trace", "isPassEnable result item=%s dest=%s result=%s", tostring(sourceItemId), tostring(destId), tostring(passAllowed))
    if passAllowed ~= true then
        if passAllowed == false then
            return false, "DD2 isPassEnable rejected this StorageData transfer before passItem was called."
        end
        return false, "DD2 isPassEnable returned a non-boolean/unknown result; refusing passItem."
    end

    -- passItem is also DD2's correct stack-transfer path. Decay-managed stacks
    -- therefore go through setupPassItemDecayData rather than getItem/deleteItem.
    local ok, result = pcall(function()
        return core.nativeTransfer.method:call(im, storageData, amount, destId, core.nativeTransfer.boolValue == true)
    end)
    if not ok then
        local reason = string.format(
            "app.ItemManager.passItem threw an exception (item=%s amount=%d sourceOwner=%s storageId=%s dest=%s): %s",
            tostring(sourceItemId), amount, tostring(sourceOwnerId), tostring(sourceStorageId), tostring(destId), tostring(result))
        trip_mutation_safety_stop(reason)
        return false, reason
    end

    core.debugLog("Verbose", "passItem returned item=%s amount=%d dest=%s result=%s", tostring(sourceItemId), amount, tostring(destId), tostring(result))
    return true, result
end

local function resolve_native_stack_storage_data(itemId, amount, sourceId)
    itemId = math.floor(tonumber(itemId) or 0)
    amount = math.floor(tonumber(amount) or 0)
    if itemId <= 0 or amount <= 0 or sourceId == nil then
        return nil, "Invalid native stack source request."
    end
    if not getStorageDataByStorageIdMethod then
        return nil, "Exact ItemManager.getStorageDataByStorageId(System.Int32) method is unavailable."
    end

    -- A healthy fungible inventory stack is represented by one positive
    -- StorageMasterData row. Zero-quantity ghosts are deliberately ignored when
    -- looking for the live source, but their presence is logged. Multiple positive
    -- rows are rejected instead of guessing which value-type record passItem should
    -- receive.
    local records = core.getLiveItemRecords(itemId, sourceId)
    local positive = {}
    local zeroRows = 0
    for _, record in ipairs(records or {}) do
        local qty = math.max(0, math.floor(tonumber(record.quantity) or 0))
        if qty > 0 then
            positive[#positive + 1] = record
        else
            zeroRows = zeroRows + 1
        end
    end

    if #positive == 0 then
        return nil, string.format(
            "No positive StorageMasterData row exists for item %d/source %s (%d zero-quantity row%s found).",
            itemId, tostring(sourceId), zeroRows, zeroRows == 1 and "" or "s")
    end
    if zeroRows > 0 then
        return nil, string.format(
            "Item %d/source %s has %d zero-quantity sibling StorageData row%s. This is a known bad-state pattern; native passItem was NOT called.",
            itemId, tostring(sourceId), zeroRows, zeroRows == 1 and "" or "s")
    end
    if #positive ~= 1 then
        local parts = {}
        for _, record in ipairs(positive) do
            parts[#parts + 1] = string.format("StorageId=%s Num=%s", tostring(record.storageId), tostring(record.quantity))
        end
        return nil, string.format(
            "Item %d/source %s has %d positive StorageData rows (%s); refusing ambiguous native stack transfer.",
            itemId, tostring(sourceId), #positive, table.concat(parts, ", "))
    end

    local record = positive[1]
    local storageId = tonumber(record.storageId)
    local rowNum = math.max(0, math.floor(tonumber(record.quantity) or 0))
    if storageId == nil or storageId < 0 then
        return nil, "Positive source StorageMasterData row has no valid StorageId."
    end
    if amount > rowNum then
        return nil, string.format(
            "Requested %d unit(s), but exact source row StorageId %s contains only %d.",
            amount, tostring(storageId), rowNum)
    end

    local im = get_item_manager()
    if not im then return nil, "ItemManager not ready." end
    local storageData = safe_call(function()
        return getStorageDataByStorageIdMethod:call(im, storageId)
    end, nil)
    if not storageData then
        return nil, string.format("getStorageDataByStorageId(%s) returned no StorageData.", tostring(storageId))
    end

    local actualItemId = storage_data_item_id(storageData)
    local actualSourceId = storage_data_chara_id(storageData)
    local actualStorageId = storage_data_storage_id(storageData)
    local actualNum = math.floor(tonumber(storage_data_num(storageData)) or -1)
    if actualItemId ~= itemId then
        return nil, string.format("Exact StorageData ItemID mismatch: expected %d, got %s.", itemId, tostring(actualItemId))
    end
    if character_id_hex32(actualSourceId) ~= character_id_hex32(sourceId) then
        return nil, string.format(
            "Exact StorageData owner mismatch: expected %s (%s), got %s (%s).",
            tostring(sourceId), tostring(character_id_hex32(sourceId)),
            tostring(actualSourceId), tostring(character_id_hex32(actualSourceId)))
    end
    if tonumber(actualStorageId) ~= storageId then
        return nil, string.format("Exact StorageData StorageId mismatch: expected %s, got %s.", tostring(storageId), tostring(actualStorageId))
    end
    if actualNum <= 0 then
        return nil, string.format("Exact StorageData StorageId %s has Num=%s; refusing stale/zero source.", tostring(storageId), tostring(actualNum))
    end
    if actualNum ~= rowNum then
        return nil, string.format(
            "Source record changed while resolving transfer: StorageMasterData Num=%d, exact StorageData Num=%d.",
            rowNum, actualNum)
    end
    if amount > actualNum then
        return nil, string.format("Requested %d unit(s), exact StorageData contains %d.", amount, actualNum)
    end

    return storageData, nil, record
end

transfer_native_stack = function(itemId, amount, sourceId, destId)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 or sourceId == nil or destId == nil or sourceId == destId then
        return false, "Invalid native stack-transfer request."
    end

    local sourceBefore, sourceErr = core.getCount(itemId, sourceId)
    if sourceBefore == nil then return false, sourceErr end
    local destBefore, destErr = core.getCount(itemId, destId)
    if destBefore == nil then return false, destErr end
    if sourceBefore < amount then
        return false, string.format("Source contains %d unit(s), requested %d.", sourceBefore, amount)
    end

    local storageData, resolveErr = resolve_native_stack_storage_data(itemId, amount, sourceId)
    if not storageData then return false, resolveErr end

    local okMove, moveErr = call_native_storage_transfer(storageData, destId, amount)
    if not okMove then return false, tostring(moveErr) end

    local sourceAfter, sourceAfterErr = core.getCount(itemId, sourceId)
    local destAfter, destAfterErr = core.getCount(itemId, destId)
    if sourceAfter == nil or destAfter == nil then
        local reason = string.format(
            "Native passItem returned but post-transfer counts are unreadable (item=%s amount=%d sourceErr=%s destErr=%s).",
            tostring(itemId), amount, tostring(sourceAfterErr), tostring(destAfterErr))
        trip_mutation_safety_stop(reason)
        return false, reason
    end

    local expectedSource = sourceBefore - amount
    local expectedDest = destBefore + amount
    if sourceAfter ~= expectedSource or destAfter ~= expectedDest then
        local reason = string.format(
            "Native passItem returned an unexpected quantity delta (item=%s amount=%d source %d->%d expected=%d, destination %d->%d expected=%d).",
            tostring(itemId), amount, sourceBefore, sourceAfter, expectedSource, destBefore, destAfter, expectedDest)
        trip_mutation_safety_stop(reason)
        return false, reason
    end

    core.debugLog("Verbose", "Native stack transfer verified item=%s amount=%d source=%s %d->%d dest=%s %d->%d", tostring(itemId), amount, tostring(sourceId), sourceBefore, sourceAfter, tostring(destId), destBefore, destAfter)
    return true
end

function core.transferInstance(itemId, storageId, sourceId, destId)
    itemId = math.floor(tonumber(itemId) or 0)
    storageId = storageId ~= nil and math.floor(tonumber(storageId) or -1) or nil
    if itemId <= 0 or storageId == nil or storageId < 0 then
        return false, "A valid ItemID and Instance ID are required for an instance transfer."
    end
    if sourceId == nil or destId == nil or sourceId == destId then
        return false, "Invalid instance-transfer owners."
    end

    local item = core.catalogAllById[itemId] or core.catalogById[itemId]
    if item and not core.requiresIdentityTransfer(item) then
        core.debugLog("Basic", "TransferInstance rerouted item=%s instance=%s path=stack-policy source=%s dest=%s", tostring(itemId), tostring(storageId), tostring(sourceId), tostring(destId))
        return core.transferStack(itemId, 1, sourceId, destId)
    end

    local row = get_storage_master_row(itemId, sourceId, storageId)
    if not row then
        return false, string.format("StorageMasterData instance %d/%d was not found in the source inventory.", itemId, storageId)
    end

    -- StorageId is now treated as the local instance identity, but keep the
    -- transfer path defensive while that assumption is still being validated.
    -- If the source contains more than one record with the same ItemID +
    -- StorageId, there is no safe way to know which record the native resolver
    -- will return, so refuse the mutation instead of guessing.
    local identityMatches = 0
    for _, record in ipairs(core.getLiveItemRecords(itemId, sourceId)) do
        if tonumber(record.storageId) == storageId then
            identityMatches = identityMatches + 1
        end
    end
    if identityMatches ~= 1 then
        return false, string.format(
            "Instance ID %d is ambiguous in the source inventory (%d matching records); refusing transfer.",
            storageId, identityMatches)
    end

    local equippedIds = equipped_storage_ids(sourceId)
    if equippedIds[storageId] or storage_master_row_is_equipped(row) then
        return false, string.format("Instance ID %d is equipped; refusing to transfer this instance.", storageId)
    end

    local im = get_item_manager()
    if not im then return false, "ItemManager not ready." end

    -- DD2 exposes an exact StorageId resolver. Prefer it over borrowing the raw
    -- nested _Param value from StorageMasterData; this is the native path that
    -- makes 0.2.1's per-instance selection meaningful.
    local storageData = getStorageDataByStorageIdMethod and safe_call(function()
        return getStorageDataByStorageIdMethod:call(im, storageId)
    end, nil) or nil
    if not storageData then
        storageData = safe_field(row, "_Param", nil) or get_storage_master_param(row)
    end
    if not storageData then return false, "Could not resolve the exact StorageData instance." end
    if storage_data_item_id(storageData) ~= itemId then
        return false, "Exact instance StorageData ItemID mismatch."
    end
    local actualCharaId = tonumber(safe_field(storageData, "_CharaId", nil))
    local expectedCharaId = tonumber(sourceId)
    if actualCharaId ~= nil and expectedCharaId ~= nil
        and character_id_hex32(actualCharaId) ~= character_id_hex32(expectedCharaId) then
        return false, string.format(
            "Exact instance owner mismatch: expected CharaId %s (%s), got %s (%s).",
            tostring(expectedCharaId), tostring(character_id_hex32(expectedCharaId)),
            tostring(actualCharaId), tostring(character_id_hex32(actualCharaId)))
    end
    local actualStorageId = storage_data_storage_id(storageData)
    if actualStorageId ~= storageId then
        return false, string.format("Exact instance ID mismatch: expected %d, got %s.", storageId, tostring(actualStorageId))
    end

    local sourceBefore, sourceErr = core.getCount(itemId, sourceId)
    if sourceBefore == nil then return false, sourceErr end
    local destBefore, destErr = core.getCount(itemId, destId)
    if destBefore == nil then return false, destErr end

    local okMove, moveErr = call_native_storage_transfer(storageData, destId, 1)
    if not okMove then return false, tostring(moveErr) end

    local sourceAfter = core.getCount(itemId, sourceId)
    local destAfter = core.getCount(itemId, destId)
    if sourceAfter ~= sourceBefore - 1 or destAfter ~= destBefore + 1 then
        return false, string.format(
            "Native instance transfer returned without the expected delta (source %s->%s, destination %s->%s).",
            tostring(sourceBefore), tostring(sourceAfter), tostring(destBefore), tostring(destAfter))
    end
    return true
end

transfer_equipment_instances = function(itemId, amount, sourceId, destId)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return false, "Invalid instance transfer amount." end
    if sourceId == nil or destId == nil or sourceId == destId then return false, "Invalid instance transfer owners." end

    local sourceBefore, sourceErr = core.getCount(itemId, sourceId)
    if sourceBefore == nil then return false, sourceErr end
    local destBefore, destErr = core.getCount(itemId, destId)
    if destBefore == nil then return false, destErr end
    if sourceBefore < amount then return false, "Source does not contain that many item instances." end

    local moved = 0
    for _ = 1, amount do
        local records = core.getLiveItemRecords(itemId, sourceId)
        local equippedIds = equipped_storage_ids(sourceId)
        local chosen = nil
        for _, record in ipairs(records) do
            if record.storageId ~= nil
                and not record.isEquipped
                and not equippedIds[record.storageId] then
                chosen = record
                break
            end
        end
        if not chosen then
            return false, string.format(
                "Instance transfer stopped after %d/%d: no unequipped transferable instance remains.",
                moved, amount)
        end

        local okMove, moveErr = core.transferInstance(itemId, chosen.storageId, sourceId, destId)
        if not okMove then
            return false, string.format("Instance transfer stopped after %d/%d: %s", moved, amount, tostring(moveErr))
        end
        moved = moved + 1
    end

    local sourceAfter = core.getCount(itemId, sourceId)
    local destAfter = core.getCount(itemId, destId)
    if sourceAfter ~= sourceBefore - amount or destAfter ~= destBefore + amount then
        return false, "Instance transfer completed with an unexpected final quantity; inspect inventory before continuing."
    end
    return true
end

local function should_report_name(name)
    local s = string.lower(tostring(name or ""))
    local words = { "storage", "warehouse", "trade", "transfer", "give", "move", "pass", "item", "equip", "stack" }
    for _, word in ipairs(words) do
        if string.find(s, word, 1, true) then return true end
    end
    return false
end

function core.buildApiReport()
    local report = {}
    core.resolveNativeEquipmentTransfer(true)
    table.insert(report, "=== Native equipment transfer API ===")
    table.insert(report, core.nativeTransfer.reason or "?")
    if core.nativeTransfer.signature then table.insert(report, "Selected: " .. core.nativeTransfer.signature) end
    if core.nativeTransfer.paramNames and #core.nativeTransfer.paramNames > 0 then
        table.insert(report, "Parameter names: " .. table.concat(core.nativeTransfer.paramNames, ", "))
    end
    table.insert(report, "Boolean argument used by Inventory Manager: " .. tostring(core.nativeTransfer.boolValue == true))
    table.insert(report, "No-lock companion present: " .. tostring(core.nativeTransfer.noLockMethod ~= nil))
    table.insert(report, "")

    local typeNames = {
        "app.ItemManager",
        "app.ItemCommonParam",
        "app.ui060301_00",
        "app.GUIBase.ItemWindowRef",
        "app.ItemDefine.StorageData",
        "app.ItemManager.StorageMasterData",
    }

    for _, fullName in ipairs(typeNames) do
        table.insert(report, "=== " .. fullName .. " ===")
        local td = sdk.find_type_definition(fullName)
        if not td then
            table.insert(report, "<type not found>")
        else
            table.insert(report, "-- methods --")
            local methods = safe_call(function() return td:get_methods() end, {}) or {}
            local signatures = {}
            for _, method in pairs(methods) do
                local name = safe_call(function() return method:get_name() end, "")
                if should_report_name(name) then
                    table.insert(signatures, method_signature(method))
                end
            end
            table.sort(signatures)
            for _, sig in ipairs(signatures) do table.insert(report, sig) end

            table.insert(report, "-- fields --")
            local fields = safe_call(function() return td:get_fields() end, {}) or {}
            local fieldNames = {}
            for _, field in pairs(fields) do
                local name = safe_call(function() return field:get_name() end, "")
                if should_report_name(name) then table.insert(fieldNames, tostring(name)) end
            end
            table.sort(fieldNames)
            for _, name in ipairs(fieldNames) do table.insert(report, name) end
        end
        table.insert(report, "")
    end

    core.apiReport = report
    local path = "InventoryManager_API.txt" -- REFramework resolves io.open relative to reframework/data
    local ok, err = pcall(function()
        local f = assert(io.open(path, "w"))
        f:write("Inventory Manager API report\n")
        f:write("TDB version: " .. tostring(sdk.get_tdb_version and sdk.get_tdb_version() or "?") .. "\n\n")
        f:write(table.concat(report, "\n"))
        f:write("\n")
        f:close()
    end)
    if not ok then
        set_error("API report built but could not be written: " .. tostring(err))
        return false
    end

    set_status("API report written to reframework/data/InventoryManager_API.txt")
    return true
end


function core.describeItem(item)
    if not item then return "<none>" end
    if item.kind ~= nil then return item.kind end
    return describe_item_kind(item)
end

function core.getClassificationRule(item)
    if not item then return "No item" end
    if item.classificationRule ~= nil then return item.classificationRule end
    local _, rule = classify_item_kind(item)
    return rule
end

return core
