-- Inventory Manager - Item Analysis add-on
-- Requires Inventory Manager analysis API 10.
--
-- Optional analysis add-on. It reuses the same guarded inventory mutation paths
-- while exposing a denser read-only metadata view and probe cache.

local core = require("InventoryManager/core")
local window = require("InventoryManager/window")
local probe = require("InventoryManager/metadata_probe")

local REQUIRED_ANALYSIS_API = 10
local FIRST_USE_EVER = 4
local TABLE_RESIZABLE = 1 << 0
local TABLE_SORTABLE = 1 << 3
local TABLE_FLAGS = TABLE_RESIZABLE | TABLE_SORTABLE
local WIDTH_STRETCH = 1 << 3
local COLUMN_DEFAULT_SORT = 1 << 2
local COLUMN_NO_SORT = 1 << 9
local COLUMN_PREFER_SORT_ASCENDING = 1 << 14
local SORT_DESCENDING = 2
local HORIZONTAL_SCROLLBAR = 1 << 11

local isOpen = false
local activePage = "Player"
local listSide = "left"
local probeInitialized = false
local localStatus = ""

-- Item Database analysis has its own single-selection state. Player/Storage use the main
-- Inventory Manager's shared multi-selection state and one active/focus item.
local catalogSearch = ""
local catalogRows = {}
local catalogPage = 1
local catalogSelectedId = nil
local catalogProbeGeneration = -1
local catalogSort = nil
local databaseAddAmount = 1
local databaseAddStatus = ""
local refreshAfterMutation = false

-- Names confirmed by the current DD2 SDK dump. These are raw engine labels;
-- the normalized production UI intentionally keeps its user-facing Kind names.
local RAW_ITEM_CATEGORY = { [0] = "Use", [1] = "Material", [2] = "Other", [3] = "Equip" }
local RAW_ITEM_DATA_TYPE = { [0] = "None", [1] = "Item", [2] = "Weapon", [3] = "Armor" }
local RAW_EQUIP_CATEGORY = {
    [0] = "Main", [1] = "Sub", [2] = "Head", [3] = "Upper",
    [4] = "Lower", [5] = "Mantle", [6] = "Jewelry", [7] = "Visual",
}

-- Explicit, one-item-at-a-time SDK validation. Never fan this out across the
-- current multi-selection; a focused item is the only runtime inspection target.
local sdkValidationKey = nil
local sdkValidationResult = nil
local sdkValidationStatus = ""

local function dash(value)
    if value == nil or value == "" then return "—" end
    return tostring(value)
end

local function rawEnum(value, names)
    if value == nil then return nil end
    local n = tonumber(value)
    local label = n ~= nil and names[n] or nil
    if label then return tostring(n) .. " (" .. label .. ")" end
    return tostring(value)
end

local function lower(value)
    return string.lower(tostring(value or ""))
end

local function stretchColumn(label, weight, userId, noSort)
    local flags = WIDTH_STRETCH
    if noSort then
        flags = flags | COLUMN_NO_SORT
    else
        -- Match the main Inventory Manager tables: two-state sorting only,
        -- defaulting to ID Ascending and preferring Ascending on first selection.
        flags = flags | COLUMN_PREFER_SORT_ASCENDING
        if userId == 1 then
            flags = flags | COLUMN_DEFAULT_SORT
        end
    end
    imgui.table_setup_column(label, flags, weight, userId)
end

local function compareValues(a, b, descending, tieA, tieB)
    if a == b then return (tonumber(tieA) or 0) < (tonumber(tieB) or 0) end
    if type(a) == "number" and type(b) == "number" then
        if descending then return a > b end
        return a < b
    end
    local sa, sb = lower(a), lower(b)
    if descending then return sa > sb end
    return sa < sb
end

local function readCatalogSort()
    local specs = imgui.table_get_sort_specs()
    if specs and specs.specs_dirty then
        local chosen = nil
        local rawSpecs = specs:get_specs()
        if rawSpecs then
            for _, spec in pairs(rawSpecs) do
                if spec and (chosen == nil
                    or (tonumber(spec.sort_order) or 0) < (tonumber(chosen.sort_order) or 0)) then
                    chosen = spec
                end
            end
        end
        if chosen then
            catalogSort = {
                userId = tonumber(chosen.user_id),
                descending = tonumber(chosen.sort_direction) == SORT_DESCENDING,
            }
        else
            catalogSort = nil
        end
        specs.specs_dirty = false
    end
    return catalogSort
end

local function rebuildCatalogRows(resetPage)
    if resetPage ~= false then catalogPage = 1 end
    catalogProbeGeneration = probe.generation
    catalogRows = {}

    local needle = lower(catalogSearch)
    for _, record in ipairs(probe.records or {}) do
        local normalized = core.getCatalogEntry(record.id, true)
        local kind = normalized and core.describeItem(normalized) or ""
        local rule = normalized and core.getClassificationRule(normalized) or ""
        local haystack = lower(table.concat({
            tostring(record.id or ""),
            tostring(record.paramId or ""),
            tostring(record.name or ""),
            tostring(record.category or ""),
            tostring(record.subCategory or ""),
            tostring(record.equipCategory or ""),
            tostring(record.dataType or ""),
            tostring(record.typeName or ""),
            tostring(kind),
            tostring(rule),
        }, " "))
        if needle == "" or string.find(haystack, needle, 1, true) ~= nil then
            table.insert(catalogRows, record)
        end
    end
end

local function sortCatalogRows()
    local state = readCatalogSort()
    if not state or not state.userId then return end
    table.sort(catalogRows, function(a, b)
        local function value(record)
            if state.userId == 1 then return tonumber(record.id) or 0 end
            if state.userId == 2 then return record.name or "" end
            if state.userId == 3 then
                local item = core.getCatalogEntry(record.id, true)
                return item and core.describeItem(item) or ""
            end
            if state.userId == 4 then return tonumber(record.category) or -1 end
            if state.userId == 5 then return tonumber(record.subCategory) or -1 end
            if state.userId == 6 then return tonumber(record.equipCategory) or -1 end
            if state.userId == 7 then return record.typeName or "" end
            return 0
        end
        return compareValues(value(a), value(b), state.descending, a.id, b.id)
    end)
end

local function rawValue(item, record, key)
    if record and record[key] ~= nil then return record[key] end
    if item and item[key] ~= nil then return item[key] end
    return nil
end

local function drawGroup(title, fields)
    imgui.text(title)
    for _, field in ipairs(fields) do
        imgui.text(field[1] .. ": " .. dash(field[2]))
    end
end

local function drawMetadataGrid(item, record, ctx)
    local capturedNativeNoStack = nil
    if item then capturedNativeNoStack = core.getNativeNoStack(item) end
    local s = core.getUiFontSize()
    local paneWidth = imgui.get_window_size().x
    local columns = 1
    if paneWidth >= s * 48 then
        columns = 3
    elseif paneWidth >= s * 31 then
        columns = 2
    end

    local selectedCount = ctx and (tonumber(ctx.selectedCount) or 0) or (item and 1 or 0)
    if selectedCount > 1 then
        imgui.text(string.format(
            "Analysis scope: active item only. Bulk actions still apply to all %d selected items.",
            selectedCount))
    else
        imgui.text("Analysis scope: active item.")
    end

    local normalizedKind = item and core.describeItem(item) or nil
    local rule = item and core.getClassificationRule(item) or nil

    local groups = {
        {
            "Identity",
            {
                { "Param ID", rawValue(item, record, "paramId") },
                { "Runtime Type", rawValue(item, record, "typeName") },
                { "DataType", rawEnum(rawValue(item, record, "dataType"), RAW_ITEM_DATA_TYPE) },
                { "Weight (raw)", rawValue(item, record, "weight") },
            },
        },
        {
            "Classification",
            {
                { "Normalized", normalizedKind },
                { "Rule", rule },
                { "Category", rawEnum(rawValue(item, record, "category"), RAW_ITEM_CATEGORY) },
                { "SubCategory", rawValue(item, record, "subCategory") },
                { "EquipCategory", rawEnum(rawValue(item, record, "equipCategory"), RAW_EQUIP_CATEGORY) },
            },
        },
        {
            "Stack",
            {
                { "Probe _StackNum", rawValue(item, record, "stackNum") },
                { "Probe WarehouseMax", rawValue(item, record, "warehouseStackNum") },
                { "Probe isNoStacItem", rawValue(item, record, "nativeNoStack") },
                { "Captured Vanilla _StackNum", item and item.vanillaStackNum or nil },
                { "Captured Vanilla Warehouse", item and item.vanillaWarehouseStackNum or nil },
                { "Runtime _StackNum", item and item.runtimeStackNum or nil },
                { "Runtime WarehouseMax", item and item.runtimeWarehouseStackNum or nil },
                { "Captured Native NoStac", capturedNativeNoStack },
                { "Effective", item and core.getEffectiveStack(item, ctx and ctx.ownerId or nil) or nil },
            },
        },
        {
            "Use / Recovery",
            {
                { "UseEffect", rawValue(item, record, "useEffect") },
                { "HP", rawValue(item, record, "healWhiteHp") },
                { "MaxHP", rawValue(item, record, "healBlackHp") },
                { "Stamina", rawValue(item, record, "healStamina") },
                { "RemoveStatus", rawValue(item, record, "removeStatus") },
            },
        },
        {
            "Flags",
            {
                { "Currency", item and tostring(item.isCurrency == true) or nil },
                { "Equipment", item and tostring(item.isEquipment == true) or nil },
                { "Curative", item and tostring(item.isCurative == true) or nil },
                { "Decay", item and tostring(item.isDecay == true) or nil },
                { "Lantern", item and tostring(item.isLantern == true) or nil },
                { "Invalid", item and tostring(item.isInvalid == true) or nil },
            },
        },
        {
            "Probe",
            {
                { "Generation", probe.generation > 0 and probe.generation or nil },
                { "Record", record and "Cached" or nil },
                { "Item ID", item and item.id or (record and record.id or nil) },
                { "Name", item and item.name or (record and record.name or nil) },
            },
        },
    }

    if imgui.begin_table("AnalysisMetadataGrid", columns, TABLE_RESIZABLE) then
        for i = 1, columns do
            stretchColumn("Info " .. tostring(i), 1.0, 600 + i, true)
        end
        for index, group in ipairs(groups) do
            if ((index - 1) % columns) == 0 then imgui.table_next_row() end
            imgui.table_next_column()
            drawGroup(group[1], group[2])
        end
        imgui.end_table()
    else
        for _, group in ipairs(groups) do
            drawGroup(group[1], group[2])
            imgui.separator()
        end
    end
end

local function sdkResultText(result)
    if not result then return "—" end
    if result.state == "ok" then
        if result.value == nil then return "nil" end
        return tostring(result.value)
    end
    if result.state == "missing" then return "<method unavailable>" end
    if result.state == "skipped" then return "—" end
    if result.state == "error" then return "ERROR: " .. tostring(result.error or "call failed") end
    return "—"
end

local function drawSdkValidationGrid(result)
    local s = core.getUiFontSize()
    local paneWidth = imgui.get_window_size().x
    local columns = 1
    if paneWidth >= s * 48 then
        columns = 3
    elseif paneWidth >= s * 31 then
        columns = 2
    end

    local param = result and result.param or {}
    local master = result and result.master or {}
    local nested = result and result.nested or {}
    local transfer = result and result.transfer or {}
    local groups = {
        {
            "Stack API",
            {
                { "_StackNum", sdkResultText(param.rawStackNum) },
                { "WarehouseMaxStackNum", sdkResultText(param.warehouseMaxStackNum) },
                { "Captured vanilla _StackNum", sdkResultText(param.capturedVanilla) },
                { "Captured vanilla Warehouse", sdkResultText(param.capturedWarehouseVanilla) },
                { "getDefaultStackNum()", sdkResultText(param.defaultStackNum) },
                { "getStackNum(owner)", sdkResultText(param.ownerStackNum) },
                { "isNoStacItem(current)", sdkResultText(param.nativeNoStack) },
                { "isNoStacItem(captured)", sdkResultText(param.capturedNativeNoStack) },
            },
        },
        {
            "ItemCommonParam",
            {
                { "get_IsEquip()", sdkResultText(param.isEquip) },
                { "get_IsEquipData()", sdkResultText(param.isEquipData) },
                { "get_IsItemData()", sdkResultText(param.isItemData) },
            },
        },
        {
            "Live Master Record",
            {
                { "Resolved", sdkResultText(master.lookup) },
                { "Resolver", sdkResultText(master.source) },
                { "Runtime Type", sdkResultText(master.typeName) },
                { "ItemId", sdkResultText(master.itemId) },
                { "Quantity", sdkResultText(master.num) },
                { "Internal Field ID", sdkResultText(master.internalFieldId) },
                { "Raw field name", "StorageId (meaning unconfirmed)" },
                { "CharaId", sdkResultText(master.charaId) },
                { "IsEquipped", sdkResultText(master.isEquipped) },
                { "EquipSlot", sdkResultText(master.equipSlot) },
                { "UpdateIndex", sdkResultText(master.updateIndex) },
                { "ArisenEquipNo", sdkResultText(master.arisenEquipNo) },
                { "ItemData Type", sdkResultText(master.itemDataType) },
            },
        },
        {
            "Nested StorageData (raw fields)",
            {
                { "Source", sdkResultText(nested.primarySource) },
                { "Routes agree", sdkResultText(nested.routesAgree) },
                { "Runtime Type", sdkResultText(nested.primaryType) },
                { "ItemId", sdkResultText(nested.primaryItemIdField) },
                { "Quantity", sdkResultText(nested.primaryNumField) },
                { "Internal Field ID", sdkResultText(nested.primaryStorageIdField) },
                { "Raw field name", "StorageId (meaning unconfirmed)" },
                { "CharaId", sdkResultText(nested.primaryCharaIdField) },
                { "IsEquipped", sdkResultText(nested.primaryIsEquippedField) },
                { "EquipSlot", sdkResultText(nested.primaryEquipSlotField) },
            },
        },
        {
            "Transfer Guard",
            {
                { "StorageData source", sdkResultText(transfer.passSource) },
                { "isPassEnable(false)", sdkResultText(transfer.passFalse) },
                { "isPassEnable(true)", sdkResultText(transfer.passTrue) },
                { "isPassEnableCommand(false)", sdkResultText(transfer.passCommandFalse) },
                { "isPassEnableCommand(true)", sdkResultText(transfer.passCommandTrue) },
            },
        },
    }

    if imgui.begin_table("SdkValidationGrid", columns, TABLE_RESIZABLE) then
        for i = 1, columns do
            stretchColumn("SDK " .. tostring(i), 1.0, 700 + i, true)
        end
        for index, group in ipairs(groups) do
            if ((index - 1) % columns) == 0 then imgui.table_next_row() end
            imgui.table_next_column()
            drawGroup(group[1], group[2])
        end
        imgui.end_table()
    else
        for _, group in ipairs(groups) do
            drawGroup(group[1], group[2])
            imgui.separator()
        end
    end
end

local function drawSdkValidation(item, ctx)
    imgui.separator()
    imgui.text("SDK Runtime Validation")

    local ownerId = ctx and ctx.ownerId or nil
    local key = item and (tostring(item.id) .. ":" .. tostring(ownerId or "catalog")) or nil
    local current = key ~= nil and key == sdkValidationKey and sdkValidationResult or nil

    if imgui.button("Run Read-Only SDK Checks##ItemAnalysisSdkValidation") then
        if not item then
            sdkValidationStatus = "Select an item first."
            sdkValidationKey = nil
            sdkValidationResult = nil
        else
            local result, err = core.runReadOnlySdkItemChecks(item.id, ownerId)
            sdkValidationKey = key
            sdkValidationResult = result
            sdkValidationStatus = result and "Read-only SDK checks complete. Master-row getters, raw nested StorageData fields, and both transfer-guard methods were probed." or tostring(err or "SDK checks failed.")
            current = result
        end
    end
    imgui.same_line()
    imgui.text("Focused item only; no inventory or metadata writes.")

    if key ~= nil and key ~= sdkValidationKey then current = nil end
    if sdkValidationStatus ~= "" and (key == sdkValidationKey or sdkValidationKey == nil) then
        imgui.text(sdkValidationStatus)
    end
    drawSdkValidationGrid(current)
end

local function drawInventoryAnalysis(ctx)
    local item = ctx and ctx.item or nil
    local record = item and probe.get(item.id) or nil
    drawMetadataGrid(item, record, ctx)
    drawSdkValidation(item, ctx)
end

local function catalogContext()
    local record = catalogSelectedId and probe.get(catalogSelectedId) or nil
    local item = catalogSelectedId and core.getCatalogEntry(catalogSelectedId, true) or nil
    return item, record
end

local function queueDatabaseAdd(item, amount, destination)
    if not item then
        databaseAddStatus = "Select an item first."
        return
    end

    local mutation = core.getMutationStatus()
    if mutation and mutation.busy then
        databaseAddStatus = "Mutation queue busy: " .. tostring(mutation.label or "work")
        return
    end

    local itemId = tonumber(item.id)
    local itemName = tostring(item.name or ("Item " .. tostring(itemId or "?")))
    local frozenAmount = math.max(1, math.floor(tonumber(amount) or 1))
    local targetId = destination == "Player" and core.getPlayerId() or core.STORAGE_ID
    if destination == "Player" and not targetId then
        databaseAddStatus = "Player CharacterID is unavailable."
        return
    end

    local label = string.format(
        "Item Database add %d x %s to %s",
        frozenAmount,
        itemName,
        destination)

    local id, err = core.enqueueMutation(label, function()
        return core.addItem(itemId, frozenAmount, targetId)
    end, {
        onComplete = function(summary)
            refreshAfterMutation = true
            if summary and summary.success then
                databaseAddStatus = string.format(
                    "Added %d x %s to %s.",
                    frozenAmount,
                    itemName,
                    destination)
            else
                databaseAddStatus = "Add Item failed: " .. tostring(summary and summary.error or "unknown error")
            end
        end,
    })

    if id then
        databaseAddStatus = string.format(
            "Queued %d x %s -> %s.",
            frozenAmount,
            itemName,
            destination)
    else
        databaseAddStatus = tostring(err or "Could not queue Add Item mutation.")
    end
end

local function drawCatalogDetails()
    local item, record = catalogContext()
    local displayName = item and item.name or (record and record.name or nil)
    local displayId = item and item.id or (record and record.id or nil)

    imgui.text("Selected Item")
    imgui.separator()
    imgui.text("Selection: " .. (displayId and "1 item" or "0"))
    imgui.text("Name: " .. dash(displayName))
    imgui.text("Item ID: " .. dash(displayId))
    imgui.separator()
    local catalogCtx = { selectedCount = displayId and 1 or 0, page = "Item Database", ownerId = nil }
    drawMetadataGrid(item, record, catalogCtx)
    drawSdkValidation(item, catalogCtx)

    imgui.separator()
    imgui.text("Add Item")
    imgui.text("Creates new item instances. Back up your save before spawning unreached quest/story items.")

    local changed
    changed, databaseAddAmount = imgui.drag_int(
        "Quantity##AnalysisItemDatabaseAdd",
        databaseAddAmount,
        1,
        1,
        999999)
    if changed then
        databaseAddAmount = math.max(1, math.floor(tonumber(databaseAddAmount) or 1))
    end

    if imgui.button("Add to Player##AnalysisItemDatabaseAddPlayer") then
        queueDatabaseAdd(item, databaseAddAmount, "Player")
    end
    imgui.same_line()
    if imgui.button("Add to Storage##AnalysisItemDatabaseAddStorage") then
        queueDatabaseAdd(item, databaseAddAmount, "Storage")
    end

    if databaseAddStatus ~= "" then imgui.text(databaseAddStatus) end
end

local function drawCatalogList()
    if catalogProbeGeneration ~= probe.generation then rebuildCatalogRows(false) end

    local changed
    changed, catalogSearch = imgui.input_text(
        "Search ID / Name / raw metadata##AnalysisCatalog",
        catalogSearch)
    if changed then rebuildCatalogRows(true) end

    local pageSize = math.max(20, tonumber(core.ui and core.ui.rowsPerPage) or 40)
    local pages = math.max(1, math.ceil(#catalogRows / pageSize))
    catalogPage = math.max(1, math.min(catalogPage, pages))

    if imgui.button("<##AnalysisCatalogPrev") and catalogPage > 1 then
        catalogPage = catalogPage - 1
    end
    imgui.same_line()
    imgui.text(string.format("Page %d / %d   (%d entries)", catalogPage, pages, #catalogRows))
    imgui.same_line()
    if imgui.button(">##AnalysisCatalogNext") and catalogPage < pages then
        catalogPage = catalogPage + 1
    end

    imgui.separator()
    local s = core.getUiFontSize()
    local size = imgui.get_window_size()
    local cursor = imgui.get_cursor_pos()
    local listHeight = math.max(s * 10, size.y - cursor.y - s * 1.0)

    if imgui.begin_child_window(
        "AnalysisCatalogList",
        Vector2f.new(0, listHeight),
        false,
        HORIZONTAL_SCROLLBAR) then
        if imgui.begin_table("AnalysisCatalogTable", 7, TABLE_FLAGS) then
            stretchColumn("ID", 0.7, 1, false)
            stretchColumn("Name", 3.8, 2, false)
            stretchColumn("Type", 1.7, 3, false)
            stretchColumn("Cat", 0.6, 4, false)
            stretchColumn("Sub", 0.6, 5, false)
            stretchColumn("Equip", 0.7, 6, false)
            stretchColumn("Runtime Type", 2.2, 7, false)
            imgui.table_headers_row()
            sortCatalogRows()

            local first = (catalogPage - 1) * pageSize + 1
            local last = math.min(#catalogRows, first + pageSize - 1)
            for i = first, last do
                local record = catalogRows[i]
                local item = core.getCatalogEntry(record.id, true)
                imgui.table_next_row()
                imgui.table_next_column(); imgui.text(tostring(record.id))
                imgui.table_next_column()
                local selectedLabel = catalogSelectedId == record.id
                    and ("> " .. tostring(record.name))
                    or tostring(record.name)
                if imgui.button(selectedLabel .. "##AnalysisCatalog" .. tostring(record.id)) then
                    catalogSelectedId = record.id
                end
                imgui.table_next_column(); imgui.text(item and core.describeItem(item) or "—")
                imgui.table_next_column(); imgui.text(dash(record.category))
                imgui.table_next_column(); imgui.text(dash(record.subCategory))
                imgui.table_next_column(); imgui.text(dash(record.equipCategory))
                imgui.table_next_column(); imgui.text(dash(record.typeName))
            end
            imgui.end_table()
        end
    end
    imgui.end_child_window()
end

local function drawCatalogWorkspace()
    local s = core.getUiFontSize()
    local size = imgui.get_window_size()
    local cursor = imgui.get_cursor_pos()
    local workspaceHeight = math.max(s * 16, size.y - cursor.y - s * 1.5)
    local wide = size.x >= s * 68

    if not wide then
        local listHeight = math.max(s * 10, workspaceHeight * 0.58)
        local detailHeight = math.max(s * 8, workspaceHeight - listHeight - s * 0.75)
        if imgui.begin_child_window("AnalysisCatalogListNarrow", Vector2f.new(0, listHeight), false) then
            drawCatalogList()
        end
        imgui.end_child_window()
        if imgui.begin_child_window(
            "AnalysisCatalogDetailsNarrow",
            Vector2f.new(0, detailHeight),
            true,
            HORIZONTAL_SCROLLBAR) then
            drawCatalogDetails()
        end
        imgui.end_child_window()
        return
    end

    local function drawList()
        if imgui.begin_child_window("AnalysisCatalogListPane", Vector2f.new(0, workspaceHeight), false) then
            drawCatalogList()
        end
        imgui.end_child_window()
    end

    local function drawDetails()
        if imgui.begin_child_window(
            "AnalysisCatalogDetailsPane",
            Vector2f.new(0, workspaceHeight),
            true,
            HORIZONTAL_SCROLLBAR) then
            drawCatalogDetails()
        end
        imgui.end_child_window()
    end

    if imgui.begin_table("AnalysisCatalogSplit", 2, TABLE_RESIZABLE) then
        if listSide == "right" then
            stretchColumn("Details", 1.25, 901, true)
            stretchColumn("Items", 1.0, 902, true)
        else
            stretchColumn("Items", 1.0, 902, true)
            stretchColumn("Details", 1.25, 901, true)
        end
        imgui.table_next_row()
        imgui.table_next_column()
        if listSide == "right" then drawDetails() else drawList() end
        imgui.table_next_column()
        if listSide == "right" then drawList() else drawDetails() end
        imgui.end_table()
    end
end

local lastInventoryPage = "Player"

local function getInventoryTabs(refreshPartyFirst)
    return window.getInventoryTabs(refreshPartyFirst == true) or {}
end

local function isLiveInventoryPage(page)
    for _, desc in ipairs(getInventoryTabs(false)) do
        if desc.key == page then return true end
    end
    return false
end

local function drawInventorySubNav()
    local tabs = getInventoryTabs(false)
    for i, desc in ipairs(tabs) do
        if i > 1 then imgui.same_line() end
        local label = tostring(desc.label or desc.key)
        if not desc.available and desc.key ~= "Player" and desc.key ~= "Storage" then
            label = label .. " —"
        end
        local shown = activePage == desc.key and ("[" .. label .. "]") or label
        if imgui.button(shown .. "##ItemAnalysisInventoryPage" .. tostring(desc.key)) then
            activePage = desc.key
            lastInventoryPage = desc.key
            window.refreshInventoryPage(desc.key)
        end
    end
end

local function drawListSideControls()
    imgui.text("List:")
    imgui.same_line()
    if imgui.button((listSide == "left" and "[Left]" or "Left") .. "##ItemAnalysisListLeft") then
        listSide = "left"
    end
    imgui.same_line()
    if imgui.button((listSide == "right" and "[Right]" or "Right") .. "##ItemAnalysisListRight") then
        listSide = "right"
    end
end

local function drawTopBar()
    local pages = { "Inventory", "Item Database", "Settings", "Diagnostics" }
    for i, page in ipairs(pages) do
        if i > 1 then imgui.same_line() end
        local active = page == "Inventory" and isLiveInventoryPage(activePage) or activePage == page
        local label = active and ("[" .. page .. "]") or page
        if imgui.button(label .. "##ItemAnalysisPage" .. page) then
            if page == "Inventory" then
                if not isLiveInventoryPage(lastInventoryPage) then lastInventoryPage = "Player" end
                activePage = lastInventoryPage
            else
                activePage = page
            end
        end
    end

    if isLiveInventoryPage(activePage) then
        drawInventorySubNav()
    end

    if isLiveInventoryPage(activePage) or activePage == "Item Database" then
        drawListSideControls()
    end
end

local function drawAnalysisDiagnostics()
    imgui.text("Analysis Diagnostics")
    imgui.separator()

    local ignoreCapacity = core.getIgnoreTransferCapacitySafety()
    local capacityChanged, capacityValue = imgui.checkbox(
        "Ignore transfer capacity safeguard##AnalysisIgnoreTransferCapacity",
        ignoreCapacity)
    if capacityChanged then
        core.setIgnoreTransferCapacitySafety(capacityValue)
        localStatus = capacityValue
            and "WARNING: transfer capacity safeguard bypassed for this session."
            or "Transfer capacity safeguard restored."
    end
    imgui.text("Debug override only. Resets to protected mode when the script reloads.")
    imgui.separator()

    if imgui.button("Refresh Live Inventory##AnalysisDiagnosticsRefresh") then
        local ok = window.refreshLiveInventory("Item Analysis diagnostics refresh")
        localStatus = ok and "Live inventory refreshed." or tostring(core.lastError or "Live inventory refresh failed.")
    end
    imgui.same_line()
    if imgui.button("Rebuild Metadata Probe##AnalysisDiagnosticsProbe") then
        local ok, err = probe.rebuild()
        localStatus = ok and probe.status or tostring(err)
        if ok then rebuildCatalogRows(false) end
    end
    imgui.same_line()
    if imgui.button("Export CSV##AnalysisDiagnosticsExportCsv") then
        local _, message = probe.exportCSV()
        localStatus = tostring(message or probe.status)
    end
    imgui.same_line()
    if imgui.button("Export TXT##AnalysisDiagnosticsExportTxt") then
        local _, message = probe.exportTXT()
        localStatus = tostring(message or probe.status)
    end

    imgui.text(probe.status)
    if localStatus ~= "" and localStatus ~= probe.status then imgui.text(localStatus) end

    imgui.separator()
    window.drawDiagnosticsWorkspace()
end


local function setOpen(open)
    isOpen = open == true
    if isOpen then
        window.initializeUiState()
        window.ensureLiveInventoryReady()
        if not probeInitialized then
            probeInitialized = true
            probe.ensure()
            rebuildCatalogRows(true)
        end
    end
end

local function drawStandaloneWindow()
    if not isOpen or not window.isRefUiOpen() then return end

    if tonumber(core.ANALYSIS_API) ~= REQUIRED_ANALYSIS_API then
        setOpen(false)
        return
    end

    window.processPendingRefreshes()
    window.ensureLiveInventoryReady()
    if refreshAfterMutation then
        refreshAfterMutation = false
        window.refreshLiveInventory()
    end

    local fontPush = core.pushUiFont()
    local s = core.getUiFontSize()
    imgui.set_next_window_size(Vector2f.new(s * 104, s * 52), FIRST_USE_EVER)
    local stillOpen = imgui.begin_window(
        "Inventory Manager - Item Analysis v" .. tostring(core.VERSION or "?") .. "###InventoryManagerItemAnalysisWindow",
        true,
        0)
    if not stillOpen then
        imgui.end_window()
        setOpen(false)
        core.popUiFont(fontPush)
        return
    end

    drawTopBar()
    imgui.separator()

    if isLiveInventoryPage(activePage) then
        imgui.text("Multi-select details show the active item only; bulk operations still use the full selection.")
        window.drawInventoryWorkspace(activePage, {
            listWeight = 1.0,
            detailWeight = 1.25,
            listSide = listSide,
            wideThreshold = s * 68,
            detailRenderer = drawInventoryAnalysis,
        })
    elseif activePage == "Item Database" then
        drawCatalogWorkspace()
    elseif activePage == "Settings" then
        window.drawSettingsWorkspace()
    elseif activePage == "Diagnostics" then
        drawAnalysisDiagnostics()
    else
        activePage = "Player"
        lastInventoryPage = "Player"
        window.drawInventoryWorkspace("Player", {
            listWeight = 1.0,
            detailWeight = 1.25,
            listSide = listSide,
            wideThreshold = s * 68,
            detailRenderer = drawInventoryAnalysis,
        })
    end

    imgui.end_window()
    core.popUiFont(fontPush)
end

re.on_frame(function()
    drawStandaloneWindow()
end)

re.on_draw_ui(function()
    if imgui.tree_node("Inventory Manager - Item Analysis") then
        if tonumber(core.ANALYSIS_API) ~= REQUIRED_ANALYSIS_API then
            imgui.text(string.format(
                "Base mod API mismatch. Required %d, found %s.",
                REQUIRED_ANALYSIS_API,
                tostring(core.ANALYSIS_API)))
        else
            if imgui.button(isOpen and "Close Item Analysis" or "Open Item Analysis") then
                setOpen(not isOpen)
            end
            imgui.separator()
            imgui.text("Standalone analysis workspace; launch/close it from this REF entry.")
            imgui.text("Uses Inventory Manager's own font settings.")
        end
        imgui.tree_pop()
    end
end)

log.info("[InventoryManager Item Analysis] Loaded for Inventory Manager v" .. tostring(core.VERSION or "?") .. ".")
