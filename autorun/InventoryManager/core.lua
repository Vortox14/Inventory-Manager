local core = {}
core.combat = require("InventoryManager/combat")
local native = require("InventoryManager/NativeBindings")

core.VERSION = "0.3.0.1"
core.VERSION_MONIKER = "The Modulation Update"
core.ANALYSIS_API = 10

core.SEALING_PHIAL_IDS = native.SEALING_PHIAL_IDS

local function normalize_stack_limit(value, fallback)
    local n = math.floor(tonumber(value) or tonumber(fallback) or 1)
    if n < 1 then n = 1 end
    if n > native.STACK_HARD_CAP then n = native.STACK_HARD_CAP end
    return n
end

core.STACK_SOFT_CAP = native.STACK_SOFT_CAP
core.STACK_HARD_CAP = native.STACK_HARD_CAP
local CONFIG_FILE = "InventoryManager.json"
-- REFramework file APIs are already rooted at reframework/data; never prefix paths with reframework/data/.

core._recreateTransferMethods = native.recreateTransferMethods
core.STORAGE_ID = native.STORAGE_ID
core.ARISEN_ID = native.ARISEN_ID
core.MAIN_PAWN_ID = native.MAIN_PAWN_ID
core.characterIdHex = native.characterIdHex32
core.LANTERN_FUEL_ID = native.LANTERN_FUEL_ID
core.WAKESHARD_ID = native.WAKESHARD_ID
core.GOLD_CAP = native.GOLD_CAP
core.UINT16_MAX = native.UINT16_MAX
core.UINT32_MAX = native.UINT32_MAX
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

local storage_master_row_item_id
local storage_master_row_quantity
local storage_master_row_storage_id
local storage_master_row_chara_id
local storage_master_row_is_equipped
local storage_master_row_equip_slot
local storage_master_row_update_index
local storage_master_row_arisen_equip_no

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
    return read_stack_field(native.rawStackNumField, param, "_StackNum")
end

local function read_warehouse_max_stack(param)
    return read_stack_field(native.warehouseMaxStackNumField, param, "WarehouseMaxStackNum")
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
    return write_param_field(native.rawStackNumField, param, "_StackNum", value, read_raw_stack_num)
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
    native.ContextHolderType,
    "getContext",
    "app.PawnDataContext")

local PawnDataContextRuntimeType = native.PawnDataContextType
    and safe_call(function() return native.PawnDataContextType:get_runtime_type() end, nil) or nil

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
    if not ctx or not native.PawnDataContextType then return nil end
    local method = native.PawnDataContextType:get_method(methodName .. "()")
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
    if not param or not native.isNoStacItemMethod then return nil end
    local im = get_item_manager()
    if not im then return nil end
    local value = safe_call(function() return native.isNoStacItemMethod:call(im, param) end, nil)
    if value == nil then return nil end
    return value == true
end

local function is_decay_item(itemId)
    itemId = math.floor(tonumber(itemId) or 0)
    if itemId <= 0 or not native.isDecayItemMethod then return false end
    local im = get_item_manager()
    if not im then return false end
    return safe_call(function() return native.isDecayItemMethod:call(im, itemId) == true end, false)
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
    if not item or not item.param or ownerId == nil or not native.getStackNumMethod then return nil end
    local ok, value = pcall(function()
        return native.getStackNumMethod:call(item.param, ownerId)
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
    if item.isCurrency then return native.GOLD_CAP end

    if ownerId ~= nil then
        local native = read_owner_stack_limit(item, ownerId)
        if native ~= nil then return native end
    end

    if ownerId == native.STORAGE_ID then
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
    if item.isCurrency then return native.GOLD_CAP end

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
        or native.SEALING_PHIAL_IDS[tonumber(item.id)] == true
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

    local id = math.floor(tonumber(core._catalogItemIdFromParam(param)) or -1)
    if id < 0 then return nil end
    local item = core.catalogAllById[id] or core.catalogById[id]
    if not item or item.isCurrency or core.isInstanceBacked(item) then return nil end

    if core.stack.mode == "Global" then
        return normalize_stack_limit(core.stack.globalLimit, nil)
    end

    if core.stack.mode ~= "Scoped" then return nil end
    ownerId = tonumber(ownerId)
    local isStorage = ownerId == native.STORAGE_ID or ownerId == -1
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
    return native.ARISEN_ID
end

function core.getCount(itemId, ownerId)
    if not native.getHaveNumMethod then return nil, "getHaveNum method was not found" end
    local im = get_item_manager()
    if not im then return nil, "ItemManager not ready" end
    local ok, count = pcall(function()
        return native.getHaveNumMethod:call(im, itemId, ownerId)
    end)
    if not ok then return nil, tostring(count) end
    return tonumber(count) or 0
end

function core.isDecayItem(itemId)
    return is_decay_item(itemId)
end

local function get_storage_master_list(ownerId)
    if ownerId == nil or not native.getStorageMasterListMethod then return nil end
    local im = get_item_manager()
    if not im then return nil end
    return safe_call(function() return native.getStorageMasterListMethod:call(im, ownerId) end, nil)
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
    if im and native.calcWeightStorageMethod then
        pcall(function() native.calcWeightStorageMethod:call(im, ownerId) end)
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
    if not native.getItemMethod then return false, "Current getItem overload was not found." end

    local im = get_item_manager()
    if not im then return false, "ItemManager not ready." end

    if itemId == native.GOLD_ID then
        local current, countErr = core.getCount(native.GOLD_ID, ownerId)
        if current == nil then return false, countErr end
        if current + amount > native.GOLD_CAP then
            return false, string.format("Gold is limited by Inventory Manager to %d G.", native.GOLD_CAP)
        end
    end

    -- Directly asking DD2 to add 3+ Wakestone Shards is known to be crash-prone.
    if itemId == native.WAKESHARD_ID then
        local current, err = core.getCount(native.WAKESHARD_ID, ownerId)
        if current == nil then return false, err end
        local total = current + amount
        local stones = math.floor(total / 3)
        local desiredShards = total - stones * 3
        local delta = desiredShards - current

        if delta > 0 then
            local option = make_get_item_option()
            if not option then return false, "Could not create GetItemOption." end
            local ok, e = pcall(function() native.getItemMethod:call(im, native.WAKESHARD_ID, delta, ownerId, option) end)
            if not ok then return false, tostring(e) end
        elseif delta < 0 then
            if not native.deleteItemNoLockMethod then return false, "deleteItemNoLock method was not found." end
            local ok, e = pcall(function() native.deleteItemNoLockMethod:call(im, native.WAKESHARD_ID, -delta, ownerId) end)
            if not ok then return false, tostring(e) end
        end

        if stones > 0 then
            local option = make_get_item_option()
            if not option then return false, "Could not create GetItemOption." end
            local ok, e = pcall(function() native.getItemMethod:call(im, native.WAKESTONE_ID, stones, ownerId, option) end)
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
        native.getItemMethod:call(im, itemId, safeAmount, ownerId, option)
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
    if not native.deleteItemNoLockMethod then return false, "Current deleteItemNoLock overload was not found." end

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
        native.deleteItemNoLockMethod:call(im, itemId, amount, ownerId)
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
    if target > native.UINT16_MAX then
        return false, string.format("Decay-managed StorageData._Num is UInt16; target must be <= %d.", native.UINT16_MAX)
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
    if itemId == native.GOLD_ID and target > native.GOLD_CAP then
        return false, string.format("Gold is limited by Inventory Manager to %d G.", native.GOLD_CAP)
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
    return core._catalogItemIdFromParam(itemData)
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
    local equippedIds = core._equippedStorageIds and core._equippedStorageIds(ownerId) or {}
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
    return core.refreshSnapshot("storage", native.STORAGE_ID)
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
        if runtimePlayerId ~= nil and native.characterIdHex32(runtimePlayerId) ~= native.characterIdHex32(native.ARISEN_ID) then
            core.debugLog("Basic",
                "Player runtime CharacterID mismatch: runtime=%s canonical=%s; using canonical ItemDefine.ArisenCharaId.",
                tostring(native.characterIdHex32(runtimePlayerId)), tostring(native.characterIdHex32(native.ARISEN_ID)))
        end
        table.insert(result, {
            label = "Player",
            displayName = "Player",
            slotKey = "Player",
            character = player,
            id = native.ARISEN_ID,
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
        if runtimeMainPawnId ~= nil and native.characterIdHex32(runtimeMainPawnId) ~= native.characterIdHex32(native.MAIN_PAWN_ID) then
            core.debugLog("Basic",
                "Main Pawn runtime CharacterID mismatch: runtime=%s canonical=%s; using canonical ItemDefine.MainPawnCharaId.",
                tostring(native.characterIdHex32(runtimeMainPawnId)), tostring(native.characterIdHex32(native.MAIN_PAWN_ID)))
        end
        local member = {
            label = "Main Pawn",
            displayName = get_pawn_display_name(mainPawn) or "Main Pawn",
            slotKey = "MainPawn",
            character = mainPawn,
            id = native.MAIN_PAWN_ID,
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
    if pageKey == "Storage" then return native.STORAGE_ID end
    if pageKey == "MainPawn" then
        local member = core.pawnSlots and core.pawnSlots.MainPawn or nil
        return member and native.MAIN_PAWN_ID or nil
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
        { key = "MainPawn", label = "Main Pawn", ownerId = slots.MainPawn and native.MAIN_PAWN_ID or nil, available = slots.MainPawn ~= nil },
        { key = "PawnA", label = pawn_tab_label(slots.PawnA), ownerId = slots.PawnA and slots.PawnA.id or nil, available = slots.PawnA ~= nil },
        { key = "PawnB", label = pawn_tab_label(slots.PawnB), ownerId = slots.PawnB and slots.PawnB.id or nil, available = slots.PawnB ~= nil },
        { key = "Storage", label = "Storage", ownerId = native.STORAGE_ID, available = true },
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

-- Transfer mechanics and automation orchestration live in TransferLogic.lua.
-- The module attaches the public core.* transfer/automation methods after the
-- shared inventory primitives and catalog services are ready.

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
    result.param.defaultStackNum = sdk_readonly_result(native.getDefaultStackNumMethod, item.param)
    local diagIm = get_item_manager()
    result.param.nativeNoStack = diagIm
        and sdk_readonly_result(native.isNoStacItemMethod, diagIm, item.param)
        or sdk_skipped("ItemManager is unavailable.")
    result.param.capturedNativeNoStack = { state = "ok", value = core.getNativeNoStack(item) }
    result.param.isEquip = sdk_readonly_result(native.getIsEquipMethod, item.param)
    result.param.isEquipData = sdk_readonly_result(native.getIsEquipDataMethod, item.param)
    result.param.isItemData = sdk_readonly_result(native.getIsItemDataMethod, item.param)

    if ownerId ~= nil then
        result.param.ownerStackNum = sdk_readonly_result(native.getStackNumMethod, item.param, ownerId)
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
    result.master.itemId = sdk_readonly_result(native.getMasterItemIdMethod, row)
    result.master.num = sdk_readonly_result(native.getMasterNumMethod, row)
    result.master.internalFieldId = sdk_readonly_result(native.getMasterStorageIdMethod, row)
    result.master.charaId = sdk_readonly_result(native.getMasterCharaIdMethod, row)
    result.master.isEquipped = sdk_readonly_result(native.getMasterIsEquippedMethod, row)
    result.master.equipSlot = sdk_readonly_result(native.getMasterEquipSlotMethod, row)
    result.master.updateIndex = sdk_readonly_result(native.getMasterUpdateIndexMethod, row)
    result.master.arisenEquipNo = sdk_readonly_result(native.getMasterArisenEquipNoMethod, row)
    local masterItemData = sdk_readonly_result(native.getMasterItemDataMethod, row)
    result.master.itemDataType = masterItemData.state == "ok"
        and readonly_type_result(masterItemData.raw, "Master ItemData is nil.")
        or masterItemData

    -- Probe the nested StorageData two ways. Do not assume either route is valid.
    local getterParamResult = sdk_readonly_result(native.getMasterParamMethod, row)
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
        result.transfer.passFalse = sdk_readonly_result(native.isPassEnableMethod, nil, primaryParam, false)
        result.transfer.passTrue = sdk_readonly_result(native.isPassEnableMethod, nil, primaryParam, true)
        result.transfer.passCommandFalse = sdk_readonly_result(native.isPassEnableCommandMethod, nil, primaryParam, false)
        result.transfer.passCommandTrue = sdk_readonly_result(native.isPassEnableCommandMethod, nil, primaryParam, true)
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
    if storageId ~= nil and native.getStorageDataByStorageIdMethod then
        local exactStorageData = safe_call(function()
            return native.getStorageDataByStorageIdMethod:call(im, storageId)
        end, nil)
        result.instance.byStorageIdResolved = { state = "ok", value = exactStorageData ~= nil }
        result.instance.byStorageIdItemId = exactStorageData
            and readonly_value(core._storageDataItemId(exactStorageData), "Exact StorageData ItemID unavailable.")
            or sdk_skipped("getStorageDataByStorageId returned no record.")
        result.instance.byStorageIdStorageId = exactStorageData
            and readonly_value(core._storageDataStorageId(exactStorageData), "Exact StorageData StorageId unavailable.")
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

        if storageId ~= nil and native.getLanternInfoByStorageIdMethod then
            local im = get_item_manager()
            local info = im and safe_call(function()
                return native.getLanternInfoByStorageIdMethod:call(im, storageId)
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
    if ownerId == nil or ownerId == native.STORAGE_ID then return nil end

    local player = get_player()
    if player and get_chara_id(player) == ownerId then return player end

    local party = core.refreshParty() or {}
    for _, member in ipairs(party) do
        if member.id == ownerId and member.character then return member.character end
    end
    return nil
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
                    table.insert(signatures, native.methodSignature(method))
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


-- Internal service surface for the item catalog / rule module.
core._catalogServices = {
    safeCall = safe_call,
    safeField = safe_field,
    safeFullTypeName = safe_full_type_name,
    readRawStackNum = read_raw_stack_num,
    readWarehouseMaxStack = read_warehouse_max_stack,
    fieldFlag = field_flag,
    readNativeNoStack = read_native_no_stack,
    isDecayItem = is_decay_item,
    setError = set_error,
    setStatus = set_status,
    getItemManager = get_item_manager,
    saveConfig = save_config,
    getStorageMasterRow = get_storage_master_row,
    getStorageMasterParam = get_storage_master_param,
}
require("InventoryManager/CatalogLogic").attach(core)

-- Internal service surface for focused submodules. These are implementation
-- details, not user-facing API; keeping them on one table avoids re-aliasing
-- dozens of locals back into core.lua.
core._transferServices = {
    safeCall = safe_call,
    safeField = safe_field,
    itemIdFromParam = core._catalogItemIdFromParam,
    managedListCount = managed_list_count,
    managedListAt = managed_list_at,
    getItemManager = get_item_manager,
    getStorageMasterRow = get_storage_master_row,
    getStorageMasterParam = get_storage_master_param,
    storageMasterRowItemId = storage_master_row_item_id,
    storageMasterRowQuantity = storage_master_row_quantity,
    storageMasterRowStorageId = storage_master_row_storage_id,
    storageMasterRowCharaId = storage_master_row_chara_id,
    storageMasterRowIsEquipped = storage_master_row_is_equipped,
    capacityLimitedDestinationAmount = capacity_limited_destination_amount,
    tripMutationSafetyStop = trip_mutation_safety_stop,
    makeGetItemOption = make_get_item_option,
}

require("InventoryManager/TransferLogic").attach(core)

return core
