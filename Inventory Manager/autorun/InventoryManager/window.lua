local core = require("InventoryManager/core")

local window = {}
local isOpen = false
local activePage = "Player"
local lastInventoryPage = "Player"

local inventoryRefreshText = "Inventory has not been refreshed yet."
local inventoryRefreshCount = 0
local inventoryCatalogCount = 0
local FIRST_USE_EVER = 4
local HORIZONTAL_SCROLLBAR = 1 << 11
local WIDTH_STRETCH = 1 << 3
local COLUMN_DEFAULT_SORT = 1 << 2
local COLUMN_NO_SORT = 1 << 9
local COLUMN_PREFER_SORT_ASCENDING = 1 << 14
local TABLE_RESIZABLE = 1 << 0
local TABLE_SORTABLE = 1 << 3
local SORTABLE_TABLE_FLAGS = TABLE_RESIZABLE | TABLE_SORTABLE
local SORT_DESCENDING = 2

local search = {
    Player = "", MainPawn = "", PawnA = "", PawnB = "", Storage = "",
    Pawns = "", PlayerRules = "", Catalog = "", Stack = "",
}
local pageIndex = {
    Player = 1, MainPawn = 1, PawnA = 1, PawnB = 1, Storage = 1,
    Pawns = 1, PlayerRules = 1, Catalog = 1, Stack = 1,
}
local filtered = {
    Player = {}, MainPawn = {}, PawnA = {}, PawnB = {}, Storage = {},
    Pawns = {}, PlayerRules = {}, Catalog = {}, Stack = {},
}
local sortState = {}
local selected = {
    Player = nil, MainPawn = nil, PawnA = nil, PawnB = nil, Storage = nil,
    Catalog = nil,
}

-- Player/Storage selection is separate from the active/primary row.
-- selected[page] remains the row whose editor/actions are shown at the top.
-- selectedRows is the persistent multi-selection set across pagination.
local selectedRows = {
    Player = {}, MainPawn = {}, PawnA = {}, PawnB = {}, Storage = {},
}
local selectionAnchor = {
    Player = nil, MainPawn = nil, PawnA = nil, PawnB = nil, Storage = nil,
}

local editQuantity = {
    Player = 0, MainPawn = 0, PawnA = 0, PawnB = 0, Storage = 0,
}
local autoApplyPending = {
    Player = false, MainPawn = false, PawnA = false, PawnB = false, Storage = false,
}
local bulkStatus = {
    Player = "", MainPawn = "", PawnA = "", PawnB = "", Storage = "",
}
local refreshPending = {
    Player = false, MainPawn = false, PawnA = false, PawnB = false, Storage = false,
}
local lastOwnerId = {
    Player = nil, MainPawn = nil, PawnA = nil, PawnB = nil, Storage = core.STORAGE_ID,
}
local lastNativeRefreshReason = "startup"
local automationScope = "Player"
local playerStatus = ""
local playerRuleSelection = {}
local playerRuleAnchor = nil
local playerRulePrimary = nil
local playerOverrideMode = "transfer"
local playerOverrideKeep = 0
local playerConfirmDefaults = false
local pawnStatus = ""
local pawnRuleSelection = {}
local pawnRuleAnchor = nil
local pawnRulePrimary = nil
local pawnOverrideMode = "transfer"
local pawnOverrideDestination = "Storage"
local pawnOverrideKeep = 0
local pawnConfirmDefaults = false
local catalogStatus = ""
local addAmount = 1
local stackLimit = core.stack.globalLimit or 9999
local actorStackLimit = core.stack.actorLimit or 99
local storageStackLimit = core.stack.storageLimit or 999
local storageTransferTargetIndex = 1
local storageTransferAmount = 1
local refreshStorageTargets
local initialLoaded = false
local initialLiveRefreshComplete = false

local fontControlStatus = ""

local function lower(v)
    return string.lower(tostring(v or ""))
end

local LIVE_INVENTORY_PAGES = { "Player", "MainPawn", "PawnA", "PawnB", "Storage" }
local PAWN_INVENTORY_PAGES = { MainPawn = true, PawnA = true, PawnB = true }
local SNAPSHOT_KEY_BY_PAGE = {
    Player = "player",
    MainPawn = "mainpawn",
    PawnA = "pawna",
    PawnB = "pawnb",
    Storage = "storage",
}

local function isLiveInventoryPage(page)
    return SNAPSHOT_KEY_BY_PAGE[page] ~= nil
end

local function isPawnInventoryPage(page)
    return PAWN_INVENTORY_PAGES[page] == true
end

local function snapshotKeyForPage(page)
    return SNAPSHOT_KEY_BY_PAGE[page] or lower(page)
end

local function inventoryRole(page)
    if page == "Player" then return "Player" end
    if page == "Storage" then return "Storage" end
    if isPawnInventoryPage(page) then return "Pawn" end
    return tostring(page or "")
end

local function partyMemberUiLabel(member)
    if not member then return "?" end
    return tostring(member.displayName or member.label or "?")
end

local function matchesPrepared(item, preparedText)
    if preparedText == "" then return true end

    -- Catalog entries cache this lowercase haystack once. Player/Storage rows point
    -- at those same item objects, so filtering never has to lowercase item names
    -- or build metadata strings repeatedly while the user types.
    local haystack = item and item.searchText
    if not haystack then
        haystack = lower((item and item.id or "") .. " " .. (item and item.name or ""))
    end
    return string.find(haystack, preparedText, 1, true) ~= nil
end

local function stretchColumn(label, weight, userId, noSort)
    local flags = WIDTH_STRETCH
    if noSort then
        flags = flags | COLUMN_NO_SORT
    else
        -- Sortable columns are deliberately two-state (Descending <-> Ascending).
        -- ID is the default sort column; every column starts with Ascending when selected.
        flags = flags | COLUMN_PREFER_SORT_ASCENDING
        if userId == 1 then
            flags = flags | COLUMN_DEFAULT_SORT
        end
    end
    imgui.table_setup_column(label, flags, weight, userId)
end

local function setupStandardColumns(includeAction, actionLabel, includeStorageId)
    local columns = includeStorageId and 7 or 5
    if includeAction then columns = columns + 1 end

    stretchColumn("ID", 0.7, 1, false)
    stretchColumn("Name", 4.1, 2, false)
    stretchColumn("Kind", 1.5, 3, false)
    stretchColumn("Qty", 0.7, 4, false)
    stretchColumn("Stack", 0.9, 5, false)
    if includeStorageId then
        stretchColumn("Instance ID", 1.0, 6, false)
        stretchColumn("Eq", 0.55, 7, false)
    end
    if includeAction then stretchColumn(actionLabel or "Action", 1.6, 99, true) end
    return columns
end

local function readTableSortState(tableKey)
    local specs = imgui.table_get_sort_specs()
    if specs and specs.specs_dirty then
        local chosen = nil
        local rawSpecs = specs:get_specs()
        if rawSpecs then
            for _, spec in pairs(rawSpecs) do
                if spec and (chosen == nil or (tonumber(spec.sort_order) or 0) < (tonumber(chosen.sort_order) or 0)) then
                    chosen = spec
                end
            end
        end
        if chosen then
            sortState[tableKey] = {
                userId = tonumber(chosen.user_id),
                descending = tonumber(chosen.sort_direction) == SORT_DESCENDING,
            }
        else
            sortState[tableKey] = nil
        end
        specs.specs_dirty = false
    end
    return sortState[tableKey]
end

local function compareSortValues(a, b, descending, tieA, tieB)
    if a == b then
        return (tonumber(tieA) or 0) < (tonumber(tieB) or 0)
    end
    if type(a) == "number" and type(b) == "number" then
        if descending then
            return a > b
        end
        return a < b
    end
    local sa = string.lower(tostring(a or ""))
    local sb = string.lower(tostring(b or ""))
    if descending then
        return sa > sb
    end
    return sa < sb
end

local function sortRowsBySpecs(tableKey, rows, valueFn)
    local state = readTableSortState(tableKey)
    if not state or not state.userId or type(valueFn) ~= "function" then return end
    table.sort(rows, function(a,b)
        local av = valueFn(a, state.userId)
        local bv = valueFn(b, state.userId)
        local aid = a.storageId or (a.item and a.item.id) or a.id or 0
        local bid = b.storageId or (b.item and b.item.id) or b.id or 0
        return compareSortValues(av, bv, state.descending, aid, bid)
    end)
end

local function standardSortValue(rowOrItem, userId)
    local item = rowOrItem.item or rowOrItem
    local quantity = rowOrItem.quantity
    if userId == 1 then return tonumber(item and item.id) or 0 end
    if userId == 2 then return item and item.name or "" end
    if userId == 3 then return item and core.describeItem(item) or "" end
    if userId == 4 then return tonumber(quantity) or 0 end
    if userId == 5 then return item and tonumber(core.getEffectiveStack(item, rowOrItem.ownerId)) or 0 end
    if userId == 6 then return tonumber(rowOrItem.storageId) or -1 end
    if userId == 7 then return rowOrItem.isEquipped and 1 or 0 end
    return 0
end

local function drawStandardIdentity(item, quantity, storageId, includeStorageId, storageIdDuplicate, isEquipped, ownerId)
    imgui.table_next_column(); imgui.text(tostring(item.id))
    imgui.table_next_column(); imgui.text(item.name)
    imgui.table_next_column(); imgui.text(core.describeItem(item))
    imgui.table_next_column(); imgui.text(tostring(quantity ~= nil and quantity or "-"))
    imgui.table_next_column(); imgui.text(core.getStackDisplay(item, ownerId))
    if includeStorageId then
        local text = storageId ~= nil and tostring(storageId) or "—"
        if storageIdDuplicate then text = text .. "  DUP" end
        imgui.table_next_column(); imgui.text(text)
        imgui.table_next_column(); imgui.text(isEquipped and "Yes" or "—")
    end
end

-- ImGuiTableBgTarget_RowBg0 / RowBg1.
local ROW_BG_BASE = 1
local ROW_BG_OVERLAY = 2

-- Neutral greys keep hover/selection readable across REFramework themes.
local ROW_HOVER_BG = 0x40383838
local ROW_SELECTED_BG = 0x70505050
local ROW_PRIMARY_BG = 0x90606060

-- Windows virtual key codes; REFramework exposes is_key_down(VK).
local VK_SHIFT = 0x10
local VK_CONTROL = 0x11

local function inventoryRowKey(row)
    if not row then return nil end
    if row.rowKey ~= nil then return tostring(row.rowKey) end
    if row.item and row.item.id ~= nil then return "S:" .. tostring(row.item.id) end
    return nil
end

local function findSnapshotRowByKey(page, key)
    if key == nil then return nil end
    local snapshotKey = snapshotKeyForPage(page)
    for _, row in ipairs(core.snapshots[snapshotKey] or {}) do
        if inventoryRowKey(row) == tostring(key) then return row end
    end
    return nil
end

local function selectionCount(page)
    local count = 0
    for _, active in pairs(selectedRows[page] or {}) do
        if active then count = count + 1 end
    end
    return count
end

local function findFilteredRowIndex(page, rowKey)
    if rowKey == nil then return nil end
    for i, row in ipairs(filtered[page] or {}) do
        if inventoryRowKey(row) == tostring(rowKey) then return i end
    end
    return nil
end

local function setPrimaryRow(page, row)
    if not row or not row.item then
        selected[page] = nil
        return
    end

    selected[page] = inventoryRowKey(row)
    editQuantity[page] = row.quantity
    if page == "Storage" then
        storageTransferAmount = math.max(1, row.quantity)
    end
    autoApplyPending[page] = false
    bulkStatus[page] = ""
end

local function clearInventorySelection(page, clearPrimary)
    selectedRows[page] = {}
    selectionAnchor[page] = nil
    if clearPrimary ~= false then
        selected[page] = nil
        autoApplyPending[page] = false
    end
end

local function chooseFirstSelectedAsPrimary(page)
    for _, row in ipairs(filtered[page] or {}) do
        local key = inventoryRowKey(row)
        if key ~= nil and selectedRows[page] and selectedRows[page][key] then
            setPrimaryRow(page, row)
            return row
        end
    end
    selected[page] = nil
    return nil
end

local function reconcileInventorySelection(page)
    local snapshotKey = snapshotKeyForPage(page)
    local snapshotRows = core.snapshots[snapshotKey] or {}
    local valid = {}

    for _, row in ipairs(snapshotRows) do
        local key = inventoryRowKey(row)
        if key then valid[key] = row end
    end

    for key in pairs(selectedRows[page] or {}) do
        if not valid[key] then selectedRows[page][key] = nil end
    end

    if selectionAnchor[page] and not valid[selectionAnchor[page]] then
        selectionAnchor[page] = nil
    end

    if selected[page] and valid[selected[page]] then
        selectedRows[page][selected[page]] = true
        setPrimaryRow(page, valid[selected[page]])
    elseif selectionCount(page) > 0 then
        for _, row in ipairs(snapshotRows) do
            local key = inventoryRowKey(row)
            if key and selectedRows[page][key] then
                setPrimaryRow(page, row)
                return
            end
        end
        selected[page] = nil
    else
        selected[page] = nil
    end
end

local function getSelectedInventoryRows(page)
    local snapshotKey = snapshotKeyForPage(page)
    local rows = core.snapshots[snapshotKey] or {}
    local out = {}

    for _, row in ipairs(rows) do
        local key = inventoryRowKey(row)
        if key ~= nil and selectedRows[page] and selectedRows[page][key] then
            table.insert(out, row)
        end
    end
    return out
end

local function visibleSelectionCount(page)
    local count = 0
    for _, row in ipairs(filtered[page] or {}) do
        local key = inventoryRowKey(row)
        if key ~= nil and selectedRows[page] and selectedRows[page][key] then
            count = count + 1
        end
    end
    return count
end

local function selectInventoryRange(page, fromIndex, toIndex, additive)
    local rows = filtered[page] or {}
    if not additive then selectedRows[page] = {} end

    local lo = math.max(1, math.min(fromIndex, toIndex))
    local hi = math.min(#rows, math.max(fromIndex, toIndex))
    for i = lo, hi do
        local key = inventoryRowKey(rows[i])
        if key then selectedRows[page][key] = true end
    end
end

local function handleInventoryRowClick(page, row, rowIndex)
    if not row or not row.item then return end

    local key = inventoryRowKey(row)
    if key == nil then return end
    local ctrlDown = reframework:is_key_down(VK_CONTROL)
    local shiftDown = reframework:is_key_down(VK_SHIFT)

    if shiftDown then
        local anchorKey = selectionAnchor[page] or selected[page] or key
        local anchorIndex = findFilteredRowIndex(page, anchorKey) or rowIndex
        selectInventoryRange(page, anchorIndex, rowIndex, ctrlDown)
        setPrimaryRow(page, row)
        if selectionAnchor[page] == nil then selectionAnchor[page] = key end
        return
    end

    if ctrlDown then
        if selectedRows[page][key] then
            selectedRows[page][key] = nil
            if selected[page] == key then chooseFirstSelectedAsPrimary(page) end
        else
            selectedRows[page][key] = true
            setPrimaryRow(page, row)
        end
        selectionAnchor[page] = key
        return
    end

    selectedRows[page] = { [key] = true }
    selectionAnchor[page] = key
    setPrimaryRow(page, row)
end

local function registerInventoryRowHitbox(page, row, rowIndex, rowScreenY, rowHeight)
    local s = core.getUiFontSize()
    local windowPos = imgui.get_window_pos()
    local windowSize = imgui.get_window_size()
    local mouse = imgui.get_mouse()

    local x1 = windowPos.x + s * 0.35
    local x2 = windowPos.x + windowSize.x - s * 1.55
    local y1 = rowScreenY - s * 0.10
    local y2 = y1 + rowHeight
    local clipY1 = math.max(y1, windowPos.y)
    local clipY2 = math.min(y2, windowPos.y + windowSize.y)

    local hovered =
        mouse ~= nil
        and clipY2 > clipY1
        and mouse.x >= x1
        and mouse.x < x2
        and mouse.y >= clipY1
        and mouse.y < clipY2

    local key = inventoryRowKey(row)
    local isSelected = key ~= nil and selectedRows[page][key] == true
    local isPrimary = key ~= nil and selected[page] == key

    if hovered then
        imgui.table_set_bg_color(ROW_BG_BASE, isSelected and ROW_PRIMARY_BG or ROW_HOVER_BG, -1)
    elseif isSelected then
        imgui.table_set_bg_color(ROW_BG_BASE, isPrimary and ROW_PRIMARY_BG or ROW_SELECTED_BG, -1)
    end

    if hovered and imgui.is_mouse_clicked(0) then
        handleInventoryRowClick(page, row, rowIndex)
    end

    return hovered
end

local function playerRuleSelectionCount()
    local count = 0
    for _, active in pairs(playerRuleSelection) do
        if active then count = count + 1 end
    end
    return count
end

local function findPlayerRuleFilteredIndex(itemId)
    if itemId == nil then return nil end
    for i, item in ipairs(filtered.PlayerRules or {}) do
        if item and item.id == itemId then return i end
    end
    return nil
end

local function loadPlayerOverrideEditor(item)
    if not item then return end
    playerRulePrimary = item.id
    local rule = core.getPlayerCleanerRule(item.id)
    if rule.isOverride and rule.mode == "ignore" then
        playerOverrideMode = "ignore"
    else
        playerOverrideMode = "transfer"
        playerOverrideKeep = math.max(0, math.floor(tonumber(rule.keep) or 0))
    end
end

local function clearPlayerRuleSelection()
    playerRuleSelection = {}
    playerRuleAnchor = nil
    playerRulePrimary = nil
end

local function selectPlayerRuleRange(fromIndex, toIndex, additive)
    local rows = filtered.PlayerRules or {}
    if not additive then playerRuleSelection = {} end
    local lo = math.max(1, math.min(fromIndex, toIndex))
    local hi = math.min(#rows, math.max(fromIndex, toIndex))
    for i = lo, hi do
        local item = rows[i]
        if item then playerRuleSelection[item.id] = true end
    end
end

local function chooseFirstPlayerRulePrimary()
    for _, item in ipairs(filtered.PlayerRules or {}) do
        if item and playerRuleSelection[item.id] then
            loadPlayerOverrideEditor(item)
            return
        end
    end
    playerRulePrimary = nil
end

local function handlePlayerRuleRowClick(item, rowIndex)
    if not item then return end
    local itemId = item.id
    local ctrlDown = reframework:is_key_down(VK_CONTROL)
    local shiftDown = reframework:is_key_down(VK_SHIFT)

    if shiftDown then
        local anchorId = playerRuleAnchor or playerRulePrimary or itemId
        local anchorIndex = findPlayerRuleFilteredIndex(anchorId) or rowIndex
        selectPlayerRuleRange(anchorIndex, rowIndex, ctrlDown)
        loadPlayerOverrideEditor(item)
        if playerRuleAnchor == nil then playerRuleAnchor = itemId end
        return
    end

    if ctrlDown then
        if playerRuleSelection[itemId] then
            playerRuleSelection[itemId] = nil
            if playerRulePrimary == itemId then chooseFirstPlayerRulePrimary() end
        else
            playerRuleSelection[itemId] = true
            loadPlayerOverrideEditor(item)
        end
        playerRuleAnchor = itemId
        return
    end

    playerRuleSelection = { [itemId] = true }
    playerRuleAnchor = itemId
    loadPlayerOverrideEditor(item)
end

local function registerPlayerRuleRowHitbox(item, rowIndex, rowScreenY, rowHeight)
    local s = core.getUiFontSize()
    local windowPos = imgui.get_window_pos()
    local windowSize = imgui.get_window_size()
    local mouse = imgui.get_mouse()

    local x1 = windowPos.x + s * 0.35
    local x2 = windowPos.x + windowSize.x - s * 1.55
    local y1 = rowScreenY - s * 0.10
    local y2 = y1 + rowHeight
    local clipY1 = math.max(y1, windowPos.y)
    local clipY2 = math.min(y2, windowPos.y + windowSize.y)

    local hovered =
        mouse ~= nil
        and clipY2 > clipY1
        and mouse.x >= x1
        and mouse.x < x2
        and mouse.y >= clipY1
        and mouse.y < clipY2

    local itemId = item and item.id
    local isSelected = itemId ~= nil and playerRuleSelection[itemId] == true
    local isPrimary = itemId ~= nil and playerRulePrimary == itemId

    if hovered then
        imgui.table_set_bg_color(ROW_BG_BASE, isSelected and ROW_PRIMARY_BG or ROW_HOVER_BG, -1)
    elseif isSelected then
        imgui.table_set_bg_color(ROW_BG_BASE, isPrimary and ROW_PRIMARY_BG or ROW_SELECTED_BG, -1)
    end

    if hovered and imgui.is_mouse_clicked(0) then
        handlePlayerRuleRowClick(item, rowIndex)
    end
end

local function pawnRuleSelectionCount()
    local count = 0
    for _, active in pairs(pawnRuleSelection) do
        if active then count = count + 1 end
    end
    return count
end

local function findPawnRuleFilteredIndex(itemId)
    if itemId == nil then return nil end
    for i, item in ipairs(filtered.Pawns or {}) do
        if item and item.id == itemId then return i end
    end
    return nil
end

local function loadPawnOverrideEditor(item)
    if not item then return end
    pawnRulePrimary = item.id
    local rule = core.getPawnCleanerRule(item.id)
    if rule.isOverride and rule.mode == "ignore" then
        pawnOverrideMode = "ignore"
    else
        pawnOverrideMode = "transfer"
        pawnOverrideDestination = rule.destination == "Player" and "Player" or "Storage"
        pawnOverrideKeep = math.max(0, math.floor(tonumber(rule.keep) or 0))
    end
end

local function clearPawnRuleSelection()
    pawnRuleSelection = {}
    pawnRuleAnchor = nil
    pawnRulePrimary = nil
end

local function selectPawnRuleRange(fromIndex, toIndex, additive)
    local rows = filtered.Pawns or {}
    if not additive then pawnRuleSelection = {} end
    local lo = math.max(1, math.min(fromIndex, toIndex))
    local hi = math.min(#rows, math.max(fromIndex, toIndex))
    for i = lo, hi do
        local item = rows[i]
        if item then pawnRuleSelection[item.id] = true end
    end
end

local function chooseFirstPawnRulePrimary()
    for _, item in ipairs(filtered.Pawns or {}) do
        if item and pawnRuleSelection[item.id] then
            loadPawnOverrideEditor(item)
            return
        end
    end
    pawnRulePrimary = nil
end

local function handlePawnRuleRowClick(item, rowIndex)
    if not item then return end
    local itemId = item.id
    local ctrlDown = reframework:is_key_down(VK_CONTROL)
    local shiftDown = reframework:is_key_down(VK_SHIFT)

    if shiftDown then
        local anchorId = pawnRuleAnchor or pawnRulePrimary or itemId
        local anchorIndex = findPawnRuleFilteredIndex(anchorId) or rowIndex
        selectPawnRuleRange(anchorIndex, rowIndex, ctrlDown)
        loadPawnOverrideEditor(item)
        if pawnRuleAnchor == nil then pawnRuleAnchor = itemId end
        return
    end

    if ctrlDown then
        if pawnRuleSelection[itemId] then
            pawnRuleSelection[itemId] = nil
            if pawnRulePrimary == itemId then chooseFirstPawnRulePrimary() end
        else
            pawnRuleSelection[itemId] = true
            loadPawnOverrideEditor(item)
        end
        pawnRuleAnchor = itemId
        return
    end

    pawnRuleSelection = { [itemId] = true }
    pawnRuleAnchor = itemId
    loadPawnOverrideEditor(item)
end

local function registerPawnRuleRowHitbox(item, rowIndex, rowScreenY, rowHeight)
    local s = core.getUiFontSize()
    local windowPos = imgui.get_window_pos()
    local windowSize = imgui.get_window_size()
    local mouse = imgui.get_mouse()

    local x1 = windowPos.x + s * 0.35
    local x2 = windowPos.x + windowSize.x - s * 1.55
    local y1 = rowScreenY - s * 0.10
    local y2 = y1 + rowHeight
    local clipY1 = math.max(y1, windowPos.y)
    local clipY2 = math.min(y2, windowPos.y + windowSize.y)

    local hovered =
        mouse ~= nil
        and clipY2 > clipY1
        and mouse.x >= x1
        and mouse.x < x2
        and mouse.y >= clipY1
        and mouse.y < clipY2

    local itemId = item and item.id
    local isSelected = itemId ~= nil and pawnRuleSelection[itemId] == true
    local isPrimary = itemId ~= nil and pawnRulePrimary == itemId

    if hovered then
        imgui.table_set_bg_color(ROW_BG_BASE, isSelected and ROW_PRIMARY_BG or ROW_HOVER_BG, -1)
    elseif isSelected then
        imgui.table_set_bg_color(ROW_BG_BASE, isPrimary and ROW_PRIMARY_BG or ROW_SELECTED_BG, -1)
    end

    if hovered and imgui.is_mouse_clicked(0) then
        handlePawnRuleRowClick(item, rowIndex)
    end
end

local function rebuildPlayerRuleFilter(resetPage)
    local preparedText = lower(search.PlayerRules)
    local out = {}
    local valid = {}
    for _, item in ipairs(core.catalog or {}) do
        valid[item.id] = true
        if matchesPrepared(item, preparedText) then table.insert(out, item) end
    end
    filtered.PlayerRules = out

    for itemId in pairs(playerRuleSelection) do
        if not valid[itemId] then playerRuleSelection[itemId] = nil end
    end
    if playerRulePrimary and not valid[playerRulePrimary] then playerRulePrimary = nil end
    if playerRuleAnchor and not valid[playerRuleAnchor] then playerRuleAnchor = nil end

    if resetPage ~= false then pageIndex.PlayerRules = 1 end
end

local function rebuildPawnRuleFilter(resetPage)
    local preparedText = lower(search.Pawns)
    local out = {}
    local valid = {}
    for _, item in ipairs(core.catalog or {}) do
        valid[item.id] = true
        if matchesPrepared(item, preparedText) then table.insert(out, item) end
    end
    filtered.Pawns = out

    for itemId in pairs(pawnRuleSelection) do
        if not valid[itemId] then pawnRuleSelection[itemId] = nil end
    end
    if pawnRulePrimary and not valid[pawnRulePrimary] then pawnRulePrimary = nil end
    if pawnRuleAnchor and not valid[pawnRuleAnchor] then pawnRuleAnchor = nil end

    if resetPage ~= false then pageIndex.Pawns = 1 end
end

local function rebuildInventoryFilter(page, resetPage)
    local key = snapshotKeyForPage(page)
    local rows = core.snapshots[key] or {}

    -- A hired-pawn slot can be occupied by a different character after a dismiss/
    -- hire cycle. Never carry the old pawn's selection into the new pawn merely
    -- because an ItemID/Instance ID happens to match.
    local ownerId = core.getInventoryOwnerId(page)
    if isLiveInventoryPage(page) and lastOwnerId[page] ~= ownerId then
        clearInventorySelection(page, true)
        pageIndex[page] = 1
        lastOwnerId[page] = ownerId
    end
    local preparedText = lower(search[page])
    local out = {}
    for _, row in ipairs(rows) do
        local storageMatch = row.storageId ~= nil
            and string.find(string.lower(tostring(row.storageId)), preparedText, 1, true) ~= nil
        if matchesPrepared(row.item, preparedText) or storageMatch then table.insert(out, row) end
    end
    filtered[page] = out
    reconcileInventorySelection(page)
    if resetPage ~= false then pageIndex[page] = 1 end
end

local function rebuildCatalogFilter(resetPage)
    local preparedText = lower(search.Catalog)
    local out = {}
    for _, item in ipairs(core.catalog) do
        if matchesPrepared(item, preparedText) then table.insert(out, item) end
    end
    filtered.Catalog = out
    if resetPage ~= false then pageIndex.Catalog = 1 end
end

local function rebuildStackFilter(resetPage)
    local preparedText = lower(search.Stack)
    local out = {}
    for _, item in ipairs(core.catalog) do
        if matchesPrepared(item, preparedText) then table.insert(out, item) end
    end
    filtered.Stack = out
    if resetPage ~= false then pageIndex.Stack = 1 end
end

local function refreshPage(page, preservePage)
    if page == "Player" then
        core.refreshPlayer()
        rebuildInventoryFilter("Player", preservePage ~= true)
    elseif page == "Storage" then
        core.refreshStorage()
        rebuildInventoryFilter("Storage", preservePage ~= true)
    elseif isPawnInventoryPage(page) then
        core.refreshPawnInventorySlot(page, true)
        rebuildInventoryFilter(page, preservePage ~= true)
    elseif page == "Catalog" then
        core.ensureCatalog(false)
        rebuildCatalogFilter()
    elseif page == "Stack" then
        core.refreshRuntimeStacks()
        rebuildStackFilter()
    end
end

local function requestRefresh(...)
    for i = 1, select("#", ...) do
        local page = select(i, ...)
        if refreshPending[page] ~= nil then
            refreshPending[page] = true
        end
    end
end

local function flushPendingRefreshes()
    -- Mutation callbacks only set these tiny flags. Actual snapshot enumeration
    -- remains event/UI-driven and happens here on the next UI draw.
    for _, page in ipairs(LIVE_INVENTORY_PAGES) do
        if refreshPending[page] then
            refreshPending[page] = false
            refreshPage(page, true)
            if isLiveInventoryPage(page) and selected[page] then
                local row = findSnapshotRowByKey(page, selected[page])
                if row then
                    editQuantity[page] = math.max(0, math.floor(tonumber(row.quantity) or 0))
                    if page == "Storage" then
                        storageTransferAmount = math.max(1, editQuantity[page])
                    end
                end
            end
        end
    end
end

local function queueBusyText()
    local status = core.getMutationStatus()
    if not status.busy then return nil end
    if status.total and status.total > 1 then
        return string.format(
            "Mutation queue busy: %s (%d/%d)",
            tostring(status.label or "work"),
            tonumber(status.index) or 0,
            tonumber(status.total) or 0
        )
    end
    return "Mutation queue busy: " .. tostring(status.label or "work")
end

local function queueSingleMutation(label, fn, refreshPages, onComplete)
    local busy = queueBusyText()
    if busy then return false, busy end

    local id, err = core.enqueueMutation(label, fn, {
        onComplete = function(summary)
            for _, page in ipairs(refreshPages or {}) do
                requestRefresh(page)
            end
            if type(onComplete) == "function" then
                local okCb, cbErr = pcall(onComplete, summary)
                if not okCb then
                    log.error("[InventoryManager] UI completion callback failed: " .. tostring(cbErr))
                end
            end
        end,
    })
    if not id then return false, tostring(err) end
    return true, id
end


local function mutationNoticeSuffix(notices)
    if type(notices) ~= "table" or #notices == 0 then return "" end
    if #notices == 1 then return "; " .. tostring(notices[1]) end
    return string.format("; %d notices; last: %s", #notices, tostring(notices[#notices]))
end

local function queueSelectedBatch(page, label, jobs, refreshPages, summaryPrefix, stats)
    local busy = queueBusyText()
    if busy then
        bulkStatus[page] = busy
        return false
    end

    stats = stats or {}
    if #jobs == 0 then
        bulkStatus[page] = string.format(
            "%s: no mutation steps needed%s.",
            tostring(summaryPrefix or label),
            stats.note and ("; " .. tostring(stats.note)) or "")
        return true
    end

    local total = #jobs
    local id, err = core.enqueueMutationBatch(label, jobs, {
        onProgress = function(progress)
            if progress.success then
                local notice = type(progress.result) == "string" and progress.result or nil
                bulkStatus[page] = string.format(
                    "%s: %d/%d complete%s.",
                    tostring(summaryPrefix or label),
                    progress.processed or 0,
                    total,
                    notice and ("; " .. notice) or "")
            else
                bulkStatus[page] = string.format(
                    "%s ABORTING at %d/%d on %s: %s",
                    tostring(summaryPrefix or label),
                    progress.index or 0,
                    total,
                    tostring(progress.jobLabel or "?"),
                    tostring(progress.error or "unknown error"))
            end
        end,
        onComplete = function(summary)
            for _, refreshPageName in ipairs(refreshPages or {}) do
                requestRefresh(refreshPageName)
            end

            if summary.success then
                bulkStatus[page] = string.format(
                    "%s complete: %d/%d mutation steps%s%s.",
                    tostring(summaryPrefix or label),
                    summary.processed or 0,
                    total,
                    stats.note and ("; " .. tostring(stats.note)) or "",
                    mutationNoticeSuffix(summary.notices))
            else
                bulkStatus[page] = string.format(
                    "%s ABORTED after %d/%d successful mutations; failed on %s: %s%s.",
                    tostring(summaryPrefix or label),
                    summary.processed or 0,
                    total,
                    tostring(summary.failedLabel or "?"),
                    tostring(summary.error or "unknown error"),
                    stats.note and ("; " .. tostring(stats.note)) or "")
            end
        end,
    })

    if not id then
        bulkStatus[page] = "Could not queue selected-item operation: " .. tostring(err)
        return false
    end

    bulkStatus[page] = string.format(
        "%s queued: %d mutation steps%s.",
        tostring(summaryPrefix or label),
        total,
        stats.note and ("; " .. tostring(stats.note)) or "")
    return true
end

local function selectedItemTarget(item, target, ownerId)
    target = math.max(0, math.floor(tonumber(target) or 0))
    if item.isCurrency then target = math.min(target, core.GOLD_CAP) end
    if item.isDecay then target = math.min(target, core.UINT16_MAX) end
    if ownerId ~= nil and not core.isInstanceBacked(item) then
        local cap = tonumber(core.getEffectiveStack(item, ownerId))
        if cap ~= nil and cap > 0 then target = math.min(target, math.floor(cap)) end
    end
    return target
end

-- UI inventory rows are snapshots. They are useful for presentation and selection,
-- but they are not authoritative for deciding whether a mutation is necessary.
-- Some DD2 item paths can change the live ItemManager count without the cached
-- StorageMasterList representation immediately matching it. Always prefer the
-- live count for stack-like mutation decisions and fall back to the row only if
-- ItemManager is temporarily unavailable.
local function liveStackQuantity(row, ownerId)
    local fallback = math.max(0, math.floor(tonumber(row and row.quantity) or 0))
    local item = row and row.item or nil
    if not item or core.isInstanceBacked(item) then return fallback end

    local live = core.getCount(item.id, ownerId)
    if live == nil then return fallback end
    return math.max(0, math.floor(tonumber(live) or 0))
end

local function setSelectedQuantities(page, ownerId, target)
    local rows = getSelectedInventoryRows(page)
    local jobs = {}
    local skippedEquipment = 0
    local alreadyMatched = 0
    local clamped = 0

    for _, row in ipairs(rows) do
        local item = row.item
        if core.isInstanceBacked(item) then
            skippedEquipment = skippedEquipment + 1
        else
            local itemTarget = selectedItemTarget(item, target, ownerId)
            if itemTarget ~= math.max(0, math.floor(tonumber(target) or 0)) then
                clamped = clamped + 1
            end

            local current = liveStackQuantity(row, ownerId)
            if current == itemTarget then
                alreadyMatched = alreadyMatched + 1
            else
                local itemId = item.id
                local itemName = tostring(item.name)
                local frozenTarget = itemTarget
                table.insert(jobs, {
                    label = string.format("%s (%d)", itemName, itemId),
                    fn = function()
                        return core.setQuantity(itemId, frozenTarget, ownerId)
                    end,
                })
            end
        end
    end

    local note = string.format(
        "%d already matched; %d instance-backed skipped; %d target clamp(s)",
        alreadyMatched, skippedEquipment, clamped)

    return queueSelectedBatch(
        page,
        string.format("Set %d selected %s item(s) -> %d", #rows, page, math.floor(tonumber(target) or 0)),
        jobs,
        { page },
        "Set Selected",
        { note = note }
    )
end

local function adjustSelectedQuantities(page, ownerId, delta)
    local rows = getSelectedInventoryRows(page)
    local jobs = {}
    local skippedEquipment = 0
    local skippedBoundary = 0

    for _, row in ipairs(rows) do
        local item = row.item
        local current = liveStackQuantity(row, ownerId)
        local nativeCap = tonumber(core.getEffectiveStack(item, ownerId))

        if core.isInstanceBacked(item) then
            skippedEquipment = skippedEquipment + 1
        elseif delta > 0 and nativeCap ~= nil and nativeCap > 0 and current >= math.floor(nativeCap) then
            skippedBoundary = skippedBoundary + 1
        elseif delta > 0 and item.isCurrency and current >= core.GOLD_CAP then
            skippedBoundary = skippedBoundary + 1
        elseif delta > 0 and item.isDecay and current >= core.UINT16_MAX then
            skippedBoundary = skippedBoundary + 1
        elseif delta < 0 and current <= 0 then
            skippedBoundary = skippedBoundary + 1
        else
            local itemId = item.id
            local itemName = tostring(item.name)
            table.insert(jobs, {
                label = string.format("%s (%d)", itemName, itemId),
                fn = function()
                    if delta > 0 then
                        return core.addItem(itemId, 1, ownerId)
                    end
                    return core.removeItem(itemId, 1, ownerId)
                end,
            })
        end
    end

    local note = string.format(
        "%d instance-backed skipped; %d boundary/no-op skipped",
        skippedEquipment, skippedBoundary)

    return queueSelectedBatch(
        page,
        string.format("%s1 to %d selected %s item(s)", delta > 0 and "+" or "-", #rows, page),
        jobs,
        { page },
        delta > 0 and "+1 Selected" or "-1 Selected",
        { note = note }
    )
end

local function moveSelectedInventoryToTarget(page, sourceId, targetId, targetLabel, refreshPages)
    local rows = getSelectedInventoryRows(page)
    local jobs = {}
    local skippedProtected = 0
    local skippedEquipped = 0
    local skippedOwnerMismatch = 0

    -- Re-resolve the page owner at click time. Pawn slots can refresh while the UI
    -- remains open; never let an older ownerId captured by a previous draw frame
    -- decide a mutation source. Each queued row is then bound to its snapshot owner.
    local pageSourceId = core.getInventoryOwnerId(page) or sourceId
    if pageSourceId == nil or targetId == nil then
        bulkStatus[page] = "Source or destination CharacterID is unavailable."
        return false
    end

    local pageSourceHex = core.characterIdHex and core.characterIdHex(pageSourceId) or tostring(pageSourceId)
    local targetHex = core.characterIdHex and core.characterIdHex(targetId) or tostring(targetId)
    core.debugLog("Basic",
        "Manual transfer queue page=%s source=%s target=%s selectedRows=%d",
        tostring(page), tostring(pageSourceHex), tostring(targetHex), #rows)

    for _, row in ipairs(rows) do
        local item = row.item
        local amount = math.max(0, math.floor(tonumber(row.quantity) or 0))
        local rowSourceId = row.ownerId or pageSourceId
        local rowSourceHex = core.characterIdHex and core.characterIdHex(rowSourceId) or tostring(rowSourceId)

        if rowSourceHex ~= pageSourceHex then
            skippedOwnerMismatch = skippedOwnerMismatch + 1
            core.debugLog("Basic",
                "Manual transfer refused stale row page=%s item=%s rowOwner=%s pageOwner=%s amount=%s",
                tostring(page), tostring(item and item.id), tostring(rowSourceHex),
                tostring(pageSourceHex), tostring(amount))
        elseif item.id == 78 then
            skippedProtected = skippedProtected + 1
        elseif row.instanceBacked then
            if row.storageId == nil or row.storageIdDuplicate then
                skippedProtected = skippedProtected + 1
            elseif core.isInstanceEquipped(item.id, row.storageId, rowSourceId) then
                skippedEquipped = skippedEquipped + 1
            else
                local itemId, storageId = item.id, row.storageId
                local itemName = tostring(item.name)
                local frozenSourceId = rowSourceId
                table.insert(jobs, {
                    label = string.format("%s [Instance ID %s]", itemName, tostring(storageId)),
                    fn = function()
                        core.debugLog("Basic",
                            "Manual transfer execute page=%s item=%s amount=1 source=%s target=%s storageId=%s",
                            tostring(page), tostring(itemId),
                            tostring(core.characterIdHex and core.characterIdHex(frozenSourceId) or frozenSourceId),
                            tostring(targetHex), tostring(storageId))
                        return core.transferInstance(itemId, storageId, frozenSourceId, targetId)
                    end,
                })
            end
        elseif amount > 0 then
            local itemId = item.id
            local itemName = tostring(item.name)
            local frozenAmount = amount
            local frozenSourceId = rowSourceId
            table.insert(jobs, {
                label = string.format("%s x%d", itemName, frozenAmount),
                fn = function()
                    core.debugLog("Basic",
                        "Manual transfer execute page=%s item=%s amount=%d source=%s target=%s",
                        tostring(page), tostring(itemId), frozenAmount,
                        tostring(core.characterIdHex and core.characterIdHex(frozenSourceId) or frozenSourceId),
                        tostring(targetHex))
                    return core.transferStack(itemId, frozenAmount, frozenSourceId, targetId)
                end,
            })
        end
    end

    local note = string.format(
        "%d protected row(s) skipped; %d equipped instance(s) left in place; %d stale-owner row(s) refused",
        skippedProtected, skippedEquipped, skippedOwnerMismatch)

    return queueSelectedBatch(
        page,
        string.format("Move %d selected %s item row(s) to %s", #rows, page, tostring(targetLabel)),
        jobs,
        refreshPages or { page },
        "Move Selected -> " .. tostring(targetLabel),
        { note = note }
    )
end

local function moveSelectedPlayerToStorage()
    return moveSelectedInventoryToTarget(
        "Player",
        core.getPlayerId(),
        core.STORAGE_ID,
        "Storage",
        { "Player", "Storage" })
end

local function giveSelectedStorageToTarget(targetMember, requestedAmount, giveAll)
    local page = "Storage"
    local rows = getSelectedInventoryRows(page)
    local jobs = {}
    local skippedProtected = 0
    local clamped = 0

    if not targetMember or not targetMember.id then
        bulkStatus[page] = "No valid destination is selected."
        return false
    end

    requestedAmount = math.max(1, math.floor(tonumber(requestedAmount) or 1))

    for _, row in ipairs(rows) do
        local item = row.item
        local current = math.max(0, math.floor(tonumber(row.quantity) or 0))

        if item.id == 78 then
            skippedProtected = skippedProtected + 1
        elseif row.instanceBacked then
            if row.storageId == nil or row.storageIdDuplicate then
                skippedProtected = skippedProtected + 1
            else
                local itemId, storageId = item.id, row.storageId
                local itemName = tostring(item.name)
                local targetId = targetMember.id
                table.insert(jobs, {
                    label = string.format("%s [Instance ID %s]", itemName, tostring(storageId)),
                    fn = function()
                        return core.transferInstance(itemId, storageId, core.STORAGE_ID, targetId)
                    end,
                })
            end
        elseif current > 0 then
            local amount = giveAll and current or math.min(requestedAmount, current)
            if not giveAll and amount ~= requestedAmount then clamped = clamped + 1 end

            local itemId = item.id
            local itemName = tostring(item.name)
            local frozenAmount = amount
            local targetId = targetMember.id
            table.insert(jobs, {
                label = string.format("%s x%d", itemName, frozenAmount),
                fn = function()
                    return core.transferStack(itemId, frozenAmount, core.STORAGE_ID, targetId)
                end,
            })
        end
    end

    local targetLabel = partyMemberUiLabel(targetMember)
    local refreshPages = targetMember.slotKey == "Player"
        and { "Storage", "Player" }
        or { "Storage", targetMember.slotKey }
    local note = string.format("%d protected row(s) skipped; %d quantity clamp(s)", skippedProtected, clamped)
    local prefix = giveAll and ("Give Selected All -> " .. targetLabel) or ("Give Selected Quantity -> " .. targetLabel)

    return queueSelectedBatch(
        page,
        string.format("%s (%d selected row(s))", prefix, #rows),
        jobs,
        refreshPages,
        prefix,
        { note = note }
    )
end

local function countPawnInventoryRows()
    return #(core.snapshots.mainpawn or {})
        + #(core.snapshots.pawna or {})
        + #(core.snapshots.pawnb or {})
end

local function updateInventoryRefreshSummary(success)
    inventoryRefreshCount =
        #(core.snapshots.player or {})
        + #(core.snapshots.storage or {})
        + countPawnInventoryRows()

    local stats = core.getCatalogStats()
    inventoryCatalogCount = stats.valid

    if success then
        inventoryRefreshText = string.format(
            "Refreshed %d occupied live inventory entries | Item DB cache: %d named / %d invalid",
            inventoryRefreshCount,
            stats.valid,
            stats.invalid)
    else
        inventoryRefreshText = string.format(
            "Refresh incomplete: %d occupied live inventory entries | Item DB cache: %d named / %d invalid",
            inventoryRefreshCount,
            stats.valid,
            stats.invalid)
    end
end

local function refreshInventoryWorkspace()
    -- The Item DB and live inventories have different lifecycles.
    -- ensureCatalog(false) is only a cache check after the first successful load.
    local okCatalog = core.ensureCatalog(false)

    if okCatalog and core.stack.enabled and (core.stack.appliedCount or 0) == 0 then
        -- Main-menu priming caches the full ItemDataParam catalog. Reapply a
        -- persisted stack override once when the live inventory workspace starts.
        core.reapplyConfiguredStacks()
    end

    if not okCatalog then
        updateInventoryRefreshSummary(false)
        return false
    end

    local okPlayer = core.refreshPlayer()
    local okPawns = core.refreshPawnInventorySlots()
    local okStorage = core.refreshStorage()

    refreshStorageTargets()

    -- Preserve searches, selection, and pagination where possible.
    for _, page in ipairs(LIVE_INVENTORY_PAGES) do
        rebuildInventoryFilter(page, false)
    end
    rebuildPawnRuleFilter(false)
    rebuildPlayerRuleFilter(false)
    rebuildCatalogFilter(false)
    rebuildStackFilter(false)

    local success =
        okPlayer == true
        and okStorage == true
        and okPawns == true

    updateInventoryRefreshSummary(success)
    return success
end

local function initializeUiState()
    if initialLoaded then return end

    -- Preparing UI state is not a live-inventory refresh request. Static Item DB
    -- state can be prepared safely at the main menu without touching live owners.
    stackLimit = core.stack.globalLimit or stackLimit
    actorStackLimit = core.stack.actorLimit or actorStackLimit
    storageStackLimit = core.stack.storageLimit or storageStackLimit

    if core.catalogReady then
        rebuildPawnRuleFilter(false)
        rebuildPlayerRuleFilter(false)
        rebuildCatalogFilter(false)
        rebuildStackFilter(false)
        local stats = core.getCatalogStats()
        inventoryRefreshText = string.format(
            "Item DB cached: %d named / %d Invalid. Live inventory auto-refresh uses DD2 inventory events.",
            stats.valid,
            stats.invalid)
    else
        inventoryRefreshText =
            "Item DB cache is waiting for app.ItemManager during startup/main menu. No live inventory access is attempted."
    end

    initialLoaded = true
end

function window.initializeUiState()
    initializeUiState()
end

function window.ensureLiveInventoryReady()
    initializeUiState()
    if initialLiveRefreshComplete then return true end
    if core.getPlayerId() == nil then return false end

    local ok = refreshInventoryWorkspace()
    if ok then initialLiveRefreshComplete = true end
    return ok
end

function window.setOpen(open)
    isOpen = open == true
    if isOpen then
        initializeUiState()
        window.ensureLiveInventoryReady()
    end
end

function window.toggle()
    window.setOpen(not isOpen)
end

function window.isOpen()
    return isOpen
end

function window.isRefUiOpen()
    if not reframework then return true end
    local ok, visible = pcall(function() return reframework:is_drawing_ui() end)
    if not ok then return true end
    return visible == true
end


function window.drawRefUiControls()
    imgui.separator()
    imgui.text("Inventory Manager Font")
    imgui.text("Independent of REFramework's global font scalar.")
    local changed, value = imgui.slider_int(
        "Font Size##InventoryManagerOwnFontSize",
        core.getUiFontSize(),
        10,
        48,
        "%d px")
    if changed then core.setUiFontSize(value) end
    imgui.same_line()
    if imgui.button("24 px##InventoryManagerFontReset") then core.setUiFontSize(24) end

    local fontChoices = core.getUiFontChoices()
    local fontChoiceIndex = core.getUiFontChoiceIndex()
    changed, fontChoiceIndex = imgui.combo(
        "Font Face##InventoryManagerFontFace",
        fontChoiceIndex,
        fontChoices)
    if changed then
        core.setUiFontChoiceIndex(fontChoiceIndex)
        local ok, message = core.reloadUiFont()
        fontControlStatus = tostring(message or (ok and "Font applied." or "Font load failed."))
    end

    imgui.text("Available faces are read from " .. core.getUiFontDirectory() .. ".")
    if imgui.button("Refresh Fonts##InventoryManagerRefreshFonts") then
        local ok, message = core.refreshUiFonts()
        fontControlStatus = tostring(message or (ok and "Font list refreshed." or "Font scan failed."))
    end
    imgui.same_line()
    if imgui.button("Default Face##InventoryManagerDefaultFont") then
        core.setUiFontFile("")
        core.reloadUiFont()
        fontControlStatus = "Using REFramework's default face at Inventory Manager's fixed size."
    end

    local configuredFont = core.getUiFontFile()
    if configuredFont ~= "" and core.getUiFontChoiceIndex() == 1 then
        imgui.text("Configured font is not currently present in Fonts: " .. configuredFont)
    end
    imgui.text(core.getUiFontScanStatus())
    if #core.getAvailableUiFonts() == 0 then
        local candidates = core.getUiFontScanCandidates and core.getUiFontScanCandidates() or {}
        if #candidates > 0 and imgui.tree_node("Font scan paths##InventoryManagerFontScanPaths") then
            for _, path in ipairs(candidates) do imgui.text(tostring(path)) end
            imgui.tree_pop()
        end
    end
    imgui.text(core.getUiFontStatus())
    if fontControlStatus ~= "" then imgui.text(fontControlStatus) end

    imgui.separator()
    imgui.text("Diagnostics / Public Support Logging")
    local debugChoices = core.getDebugLogChoices()
    local debugIndex = core.getDebugLogLevelIndex()
    local debugChanged
    debugChanged, debugIndex = imgui.combo(
        "Diagnostic Logging##InventoryManagerDebugLogLevel",
        debugIndex,
        debugChoices)
    if debugChanged then
        core.setDebugLogLevelIndex(debugIndex)
    end
    imgui.text("Off: no diagnostic chatter | Basic: lifecycle/failures | Verbose: each transfer | Trace: guards/raw transfer state")
    imgui.text("Support log: " .. tostring(core.getDebugLogDisplayPath and core.getDebugLogDisplayPath() or "reframework/data/InventoryManager_debug.log"))
    imgui.text("Each diagnostic line is flushed immediately and also mirrored through print() for REFramework's script/debug stream.")
    if imgui.button("Clear support log##InventoryManagerClearDebugLog") then
        local ok, err = core.clearDebugLogFile()
        if ok then
            if core.getDebugLogLevel() ~= "Off" then
                core.debugLog("Basic", "Support log cleared by user; version=%s configuredLevel=%s", tostring(core.VERSION or "?"), core.getDebugLogLevel())
            end
        else
            log.error("[InventoryManager] Could not clear support log: " .. tostring(err))
        end
    end
    imgui.text("Normal safety/error reports remain logged even when diagnostics are Off.")

    local safety = core.getMutationSafetyStatus and core.getMutationSafetyStatus() or {}
    if safety.stopped then
        imgui.text("Mutation safety stop: ACTIVE")
        imgui.text("Reason: " .. tostring(safety.reason or "native transfer fault"))
        imgui.text("Further inventory mutations are blocked for this Lua session; restart DD2 after a native passItem exception.")
    else
        imgui.text("Mutation safety stop: Ready")
    end
end

-- Production UI: deliberately small, normalized, and guarded. The optional
-- Item Analysis add-on owns raw metadata/probe presentation.
local ITEM_PAGES = { "Inventory", "Automation", "Item Database", "Settings" }


local function drawControlsNav()
    for i, name in ipairs(ITEM_PAGES) do
        if i > 1 then imgui.same_line() end
        local active = name == "Inventory" and isLiveInventoryPage(activePage) or activePage == name
        local label = active and ("[" .. name .. "]") or name
        if imgui.button(label .. "##ItemControlPage" .. name) then
            if name == "Inventory" then
                if not isLiveInventoryPage(lastInventoryPage) then lastInventoryPage = "Player" end
                activePage = lastInventoryPage
            else
                activePage = name
            end
        end
    end
end

local function drawInventorySubNav()
    local descriptors = core.getInventoryTabDescriptors(false)
    for i, desc in ipairs(descriptors) do
        if i > 1 then imgui.same_line() end
        local label = tostring(desc.label or desc.key)
        if not desc.available and isPawnInventoryPage(desc.key) then label = label .. " —" end
        local shown = activePage == desc.key and ("[" .. label .. "]") or label
        if imgui.button(shown .. "##InventorySubPage" .. tostring(desc.key)) then
            activePage = desc.key
            lastInventoryPage = desc.key
            refreshPage(desc.key, true)
        end
    end
    imgui.same_line()
    if imgui.button("Refresh##InventoryCurrent") then
        refreshPage(activePage, true)
        lastNativeRefreshReason = "manual current-tab refresh"
    end
end


local function drawPager(page, total, pageSize)
    pageSize = pageSize or core.ui.rowsPerPage or 40
    local pages = math.max(1, math.ceil(total / pageSize))
    pageIndex[page] = math.max(1, math.min(pageIndex[page] or 1, pages))

    if imgui.button("<##prev" .. page) and pageIndex[page] > 1 then
        pageIndex[page] = pageIndex[page] - 1
    end
    imgui.same_line()
    imgui.text(string.format("Page %d / %d   (%d entries)", pageIndex[page], pages, total))
    imgui.same_line()
    if imgui.button(">##next" .. page) and pageIndex[page] < pages then
        pageIndex[page] = pageIndex[page] + 1
    end
end

local function drawRowsPerPage()
    imgui.text("Rows / page:")
    for _, count in ipairs(core.ROWS_PER_PAGE_OPTIONS or { 20, 40, 60, 80, 100, 120 }) do
        imgui.same_line()
        local active = (core.ui.rowsPerPage or 40) == count
        local label = active and ("[" .. tostring(count) .. "]") or tostring(count)
        if imgui.button(label .. "##RowsPerPage" .. tostring(count)) then
            core.setRowsPerPage(count)
            -- A changed page size changes page boundaries. Reset all item-list
            -- pages so the result is deterministic and never lands past the end.
            pageIndex.Player = 1
            pageIndex.MainPawn = 1
            pageIndex.PawnA = 1
            pageIndex.PawnB = 1
            pageIndex.Storage = 1
            pageIndex.Catalog = 1
            pageIndex.Stack = 1
        end
    end
end


refreshStorageTargets = function()
    local party = core.refreshParty() or {}
    if #party == 0 then
        storageTransferTargetIndex = 1
        return party
    end
    storageTransferTargetIndex = math.max(1, math.min(storageTransferTargetIndex or 1, #party))
    return party
end

local function getStorageTransferTarget()
    local party = core.party or {}
    if #party == 0 then return nil end
    storageTransferTargetIndex = math.max(1, math.min(storageTransferTargetIndex or 1, #party))
    return party[storageTransferTargetIndex]
end

local function applySelectedQuantity(page, item, ownerId)
    autoApplyPending[page] = false
    local target = math.max(0, math.floor(tonumber(editQuantity[page]) or 0))
    return setSelectedQuantities(page, ownerId, target)
end

local function setAllFilteredQuantities(page, ownerId, target)
    target = math.max(0, math.floor(tonumber(target) or 0))

    -- Freeze the FULL filtered inventory now. Pagination is only a presentation
    -- concern; the work list never uses first/last visible-row indices.
    local rows = filtered[page] or {}
    local jobs = {}
    local skippedEquipment = 0
    local decayManaged = 0
    local alreadyMatched = 0

    for _, row in ipairs(rows) do
        local item = row.item
        if core.isInstanceBacked(item) then
            skippedEquipment = skippedEquipment + 1
        else
            local isDecay = item.isDecay == true or core.isDecayItem(item.id)
            if isDecay then
                item.isDecay = true
                decayManaged = decayManaged + 1
            end

            local itemTarget = target
            if item.isCurrency then
                itemTarget = math.min(target, core.GOLD_CAP)
            elseif isDecay then
                itemTarget = math.min(target, core.UINT16_MAX)
            end
            local nativeCap = tonumber(core.getEffectiveStack(item, ownerId))
            if nativeCap ~= nil and nativeCap > 0 then
                itemTarget = math.min(itemTarget, math.floor(nativeCap))
            end

            local current = liveStackQuantity(row, ownerId)
            if current == itemTarget then
                alreadyMatched = alreadyMatched + 1
            else
                local itemId = item.id
                local itemName = tostring(item.name)
                local frozenTarget = itemTarget
                table.insert(jobs, {
                    label = string.format("%s (%d)", itemName, itemId),
                    meta = {
                        itemId = itemId,
                        itemName = itemName,
                        target = frozenTarget,
                        isDecay = isDecay,
                    },
                    fn = function()
                        return core.setQuantity(itemId, frozenTarget, ownerId)
                    end,
                })
            end
        end
    end

    if #jobs == 0 then
        bulkStatus[page] = string.format(
            "Apply All: 0 mutations needed; %d already matched; skipped %d instance-backed; %d decay-managed rows inspected.",
            alreadyMatched, skippedEquipment, decayManaged)
        return true
    end

    local busy = queueBusyText()
    if busy then
        bulkStatus[page] = busy
        return false
    end

    local totalTargets = #jobs
    local id, err = core.enqueueMutationBatch(
        string.format("Apply All %s -> %d", page, target),
        jobs,
        {
            onProgress = function(progress)
                if progress.success then
                    bulkStatus[page] = string.format(
                        "Apply All: %d/%d mutation steps complete; %d already matched; %d instance-backed skipped.",
                        progress.processed or 0, totalTargets, alreadyMatched, skippedEquipment)
                else
                    bulkStatus[page] = string.format(
                        "Apply All ABORTING at %d/%d on %s: %s",
                        progress.index or 0,
                        totalTargets,
                        tostring(progress.jobLabel or "?"),
                        tostring(progress.error or "unknown error"))
                end
            end,
            onComplete = function(summary)
                requestRefresh(page)
                if summary.success then
                    bulkStatus[page] = string.format(
                        "Apply All complete: %d/%d changed; %d already matched; skipped %d instance-backed; %d decay-managed rows.",
                        summary.processed or 0,
                        totalTargets,
                        alreadyMatched,
                        skippedEquipment,
                        decayManaged)
                else
                    bulkStatus[page] = string.format(
                        "Apply All ABORTED after %d/%d successful mutations; failed on %s: %s | %d already matched; %d instance-backed skipped.",
                        summary.processed or 0,
                        totalTargets,
                        tostring(summary.failedLabel or "?"),
                        tostring(summary.error or "unknown error"),
                        alreadyMatched,
                        skippedEquipment)
                end
            end,
        }
    )

    if not id then
        bulkStatus[page] = "Could not queue Apply All: " .. tostring(err)
        return false
    end

    bulkStatus[page] = string.format(
        "Apply All queued: %d mutation steps across ALL filtered rows; %d already matched; %d instance-backed skipped.",
        totalTargets, alreadyMatched, skippedEquipment)
    return true
end


local function inventoryWorkspaceWidthClass()
    local s = core.getUiFontSize()
    local width = tonumber(imgui.get_window_size().x) or 0

    -- Responsive bands are based on the actual normalized IM window rather than
    -- desktop-scale widths. At the default 24 px IM font these resolve to about
    -- 912 px (wide) and 672 px (medium), so a half-screen 1024 px window can
    -- actually use horizontal room instead of being incorrectly classified narrow.
    if width >= s * 38.0 then return 3 end
    if width >= s * 28.0 then return 2 end
    return 1
end

local function inventoryResponsiveSameLine(minClass)
    if inventoryWorkspaceWidthClass() >= (tonumber(minClass) or 2) then
        imgui.same_line()
        return true
    end
    return false
end

local function drawSelectedItemEditor(page, ownerId, suppressSelectionHeader, role)
    local selectedCount = selectionCount(page)
    local visibleCount = visibleSelectionCount(page)

    if not suppressSelectionHeader and selectedCount > 0 then
        local activeRow = selected[page] and findSnapshotRowByKey(page, selected[page]) or nil
        local activeItem = activeRow and activeRow.item or nil
        local activeName = activeItem and activeItem.name or "<none>"

        local hiddenCount = math.max(0, selectedCount - visibleCount)
        if hiddenCount > 0 then
            imgui.text(string.format(
                "Selected: %d item%s (%d visible, %d hidden by current search)   Active: %s",
                selectedCount,
                selectedCount == 1 and "" or "s",
                visibleCount,
                hiddenCount,
                tostring(activeName)))
        else
            imgui.text(string.format(
                "Selected: %d item%s   Active: %s",
                selectedCount,
                selectedCount == 1 and "" or "s",
                tostring(activeName)))
        end

        inventoryResponsiveSameLine(2)
        if imgui.button("Clear Selection##" .. page) then
            clearInventorySelection(page, true)
            imgui.text("Select one or more inventory rows to edit them.")
            return
        end
    end

    local primaryRow = selected[page] and findSnapshotRowByKey(page, selected[page]) or nil
    local item = primaryRow and primaryRow.item or nil
    if not item or selectedCount == 0 then
        imgui.separator()
        imgui.text("Select one or more inventory rows to enable item controls.")
        return
    end

    local current = primaryRow and math.max(0, math.floor(tonumber(primaryRow.quantity) or 0)) or 0
    local activeOwnerId = primaryRow and primaryRow.ownerId or ownerId
    if primaryRow and not primaryRow.instanceBacked then
        current = core.getCount(item.id, activeOwnerId) or current
    end

    imgui.separator()
    if selectedCount > 1 then
        imgui.text("Bulk actions apply to ALL selected items, including selections hidden by the current search.")
        imgui.text("Quantity edits skip instance-backed items; transfer actions retain their normal safeguards.")
    else
        imgui.text("Active quantity: " .. tostring(current))
    end

    if selectedCount == 1 and primaryRow and primaryRow.instanceBacked then
        imgui.text("Instance-backed row; direct quantity editing is disabled.")
        imgui.text("Instance ID: " .. tostring(primaryRow.storageId ~= nil and primaryRow.storageId or "—"))
    else
        local qChanged
        local maxTarget
        if selectedCount > 1 then
            -- One shared target is applied to each selected stack-like item. Per-item
            -- Gold/decay limits are clamped by setSelectedQuantities().
            maxTarget = 999999
        else
            maxTarget = item.isCurrency and core.GOLD_CAP
                or (item.isDecay and core.UINT16_MAX)
                or math.max(999999, current, tonumber(item.runtimeStackNum) or 0)
        end
    
        qChanged, editQuantity[page] = imgui.drag_int(
            "Target quantity##" .. page,
            editQuantity[page] or current,
            1,
            0,
            maxTarget)
    
        local quantityActive = imgui.is_item_active()
    
        inventoryResponsiveSameLine(2)
        local autoChanged
        autoChanged, core.ui.autoApplyQuantity = imgui.checkbox(
            "Auto Apply##" .. page,
            core.ui.autoApplyQuantity == true)
    
        if autoChanged then
            core.setAutoApplyQuantity(core.ui.autoApplyQuantity)
            if not core.ui.autoApplyQuantity then
                autoApplyPending[page] = false
            end
        end
    
        if qChanged and core.ui.autoApplyQuantity then
            autoApplyPending[page] = true
        end
    
        if core.ui.autoApplyQuantity
            and autoApplyPending[page]
            and not quantityActive then
            applySelectedQuantity(page, item, ownerId)
            current = core.getCount(item.id, ownerId) or 0
        end
    
        local setLabel = selectedCount > 1
            and string.format("Set Selected (%d)##%s", selectedCount, page)
            or ("Set Quantity##" .. page)
    
        if imgui.button(setLabel) then
            applySelectedQuantity(page, item, ownerId)
            current = core.getCount(item.id, ownerId) or 0
        end
    
        inventoryResponsiveSameLine(2)
        local plusLabel = selectedCount > 1
            and string.format("+1 Selected (%d)##%s", selectedCount, page)
            or ("+1##" .. page)
        if imgui.button(plusLabel) then
            autoApplyPending[page] = false
            adjustSelectedQuantities(page, ownerId, 1)
        end
    
        inventoryResponsiveSameLine(2)
        local minusLabel = selectedCount > 1
            and string.format("-1 Selected (%d)##%s", selectedCount, page)
            or ("-1##" .. page)
        if imgui.button(minusLabel) then
            autoApplyPending[page] = false
            adjustSelectedQuantities(page, ownerId, -1)
        end
    
        inventoryResponsiveSameLine(3)
        imgui.text("(quantity edits skip instance-backed items)")
    
        if imgui.button(string.format("Set All Filtered -> %d##%s", editQuantity[page] or 0, page)) then
            autoApplyPending[page] = false
            setAllFilteredQuantities(page, ownerId, editQuantity[page])
            current = core.getCount(item.id, ownerId) or 0
        end
        inventoryResponsiveSameLine(3)
        imgui.text("(filtered list, not selection; instance-backed skipped)")
    
        end

    if bulkStatus[page] ~= "" then
        imgui.text(bulkStatus[page])
    end

    -- Transfers are selection-aware too.
    role = role or inventoryRole(page)
    if role == "Player" then
        if selectedCount > 1 then
            if imgui.button(string.format("Move Selected (%d) -> Storage##Player", selectedCount)) then
                autoApplyPending[page] = false
                moveSelectedPlayerToStorage()
            end
            inventoryResponsiveSameLine(3)
            imgui.text("(stack rows move whole stacks; equipped instances stay in place)")
        elseif item.id ~= 78 and current > 0 then
            local instanceEquipped = primaryRow and primaryRow.instanceBacked
                and core.isInstanceEquipped(item.id, primaryRow.storageId, ownerId)
            local transferAmount = primaryRow and primaryRow.instanceBacked and 1 or current
            local transferLabel = primaryRow and primaryRow.instanceBacked and "Move Instance -> Storage" or "Move All -> Storage"
            if primaryRow and primaryRow.instanceBacked and primaryRow.storageIdDuplicate then
                transferAmount = 0
                imgui.text("Duplicate Instance ID detected; exact transfer is disabled.")
            elseif instanceEquipped then
                transferAmount = 0
                imgui.text("Equipped instance protected.")
            elseif not (primaryRow and primaryRow.instanceBacked) and core.isInstanceBacked(item) then
                transferAmount = math.max(0, current - core.getEquippedCount(ownerId, item.id))
                transferLabel = "Move Unequipped -> Storage"
            end
            if transferAmount > 0 and imgui.button(transferLabel .. "##" .. page) then
                autoApplyPending[page] = false
                local itemIdSingle, itemName, frozenAmount = item.id, tostring(item.name), transferAmount
                local instanceStorageId = primaryRow and primaryRow.instanceBacked and primaryRow.storageId or nil
                local queued, err = queueSingleMutation(
                    string.format("Move %d x %s to Storage", frozenAmount, itemName),
                    function()
                        if instanceStorageId ~= nil then
                            return core.transferInstance(itemIdSingle, instanceStorageId, ownerId, core.STORAGE_ID)
                        end
                        return core.transferPlayerStorage(itemIdSingle, frozenAmount, true)
                    end,
                    { "Player", "Storage" },
                    function(summary)
                        if summary.success then
                            bulkStatus[page] = type(summary.result) == "string" and summary.result or string.format(
                                "Transferred %d x %s to Storage.",
                                frozenAmount, itemName)
                        else
                            bulkStatus[page] = "Transfer failed: " .. tostring(summary.error)
                        end
                    end
                )
                if queued then
                    bulkStatus[page] = string.format(
                        "Queued transfer of %d x %s to Storage.",
                        frozenAmount, itemName)
                else
                    bulkStatus[page] = tostring(err)
                end
            end
        end
    elseif role == "Storage" then
        imgui.separator()
        imgui.text("Transfer from Storage")

        if imgui.button("Refresh Targets##Storage") then
            refreshStorageTargets()
        end

        local party = core.party or {}
        if #party == 0 then
            imgui.text("No live party targets are cached. Use Refresh Targets.")
        else
            local widthClass = inventoryWorkspaceWidthClass()
            local targetsPerRow = widthClass >= 3 and 4 or (widthClass == 2 and 2 or 1)
            for i, member in ipairs(party) do
                if i > 1 and ((i - 1) % targetsPerRow) ~= 0 then imgui.same_line() end
                local label =
                    (storageTransferTargetIndex == i and "[" .. partyMemberUiLabel(member) .. "]" or partyMemberUiLabel(member))
                if imgui.button(label .. "##StorageTarget" .. tostring(i)) then
                    storageTransferTargetIndex = i
                end
            end

            local targetMember = getStorageTransferTarget()
            if targetMember and targetMember.id then
                local maxSelected = current
                if selectedCount > 1 then
                    maxSelected = 1
                    for _, row in ipairs(getSelectedInventoryRows("Storage")) do
                        maxSelected = math.max(
                            maxSelected,
                            math.max(0, math.floor(tonumber(row.quantity) or 0)))
                    end
                end

                storageTransferAmount = math.max(
                    1,
                    math.min(storageTransferAmount or current, math.max(1, maxSelected)))

                local amountChanged
                amountChanged, storageTransferAmount = imgui.drag_int(
                    selectedCount > 1
                        and "Transfer quantity EACH##Storage"
                        or "Transfer quantity##Storage",
                    storageTransferAmount,
                    1,
                    1,
                    math.max(1, maxSelected))

                if selectedCount > 1 then
                    local targetLabel = partyMemberUiLabel(targetMember)

                    if imgui.button(
                        string.format(
                            "Give up to %d EACH (%d selected) -> %s##StorageGiveSelectedQty",
                            storageTransferAmount,
                            selectedCount,
                            targetLabel)) then
                        autoApplyPending[page] = false
                        giveSelectedStorageToTarget(
                            targetMember,
                            storageTransferAmount,
                            false)
                    end

                    inventoryResponsiveSameLine(2)

                    if imgui.button(
                        string.format(
                            "Give ALL Selected (%d) -> %s##StorageGiveSelectedAll",
                            selectedCount,
                            targetLabel)) then
                        autoApplyPending[page] = false
                        giveSelectedStorageToTarget(targetMember, 1, true)
                    end
                elseif item.id ~= 78 and current > 0 then
                    if primaryRow and primaryRow.instanceBacked and primaryRow.storageIdDuplicate then
                        imgui.text("Duplicate Instance ID detected; exact transfer is disabled.")
                    else
                    local giveLabel = "Give Quantity -> " .. partyMemberUiLabel(targetMember)
                    if imgui.button(giveLabel .. "##StorageGiveQty") then
                        autoApplyPending[page] = false
                        local itemIdSingle = item.id
                        local itemName = tostring(item.name)
                        local instanceStorageId = primaryRow and primaryRow.instanceBacked and primaryRow.storageId or nil
                        local frozenAmount = instanceStorageId ~= nil and 1 or math.max(
                            1,
                            math.floor(tonumber(storageTransferAmount) or 1))
                        local targetId = targetMember.id
                        local targetLabel = partyMemberUiLabel(targetMember)
                        local refreshPages = targetMember.slotKey == "Player"
                            and { "Storage", "Player" }
                            or { "Storage", targetMember.slotKey }

                        local queued, err = queueSingleMutation(
                            string.format(
                                "Give %d x %s to %s",
                                frozenAmount, itemName, targetLabel),
                            function()
                                if instanceStorageId ~= nil then
                                    return core.transferInstance(itemIdSingle, instanceStorageId, core.STORAGE_ID, targetId)
                                end
                                return core.transferStack(itemIdSingle, frozenAmount, core.STORAGE_ID, targetId)
                            end,
                            refreshPages,
                            function(summary)
                                if summary.success then
                                    bulkStatus[page] = type(summary.result) == "string" and summary.result or string.format(
                                        "Transferred %d x %s to %s.",
                                        frozenAmount, itemName, targetLabel)
                                else
                                    bulkStatus[page] =
                                        "Transfer failed: " .. tostring(summary.error)
                                end
                            end
                        )

                        if queued then
                            bulkStatus[page] = string.format(
                                "Queued transfer of %d x %s to %s.",
                                frozenAmount, itemName, targetLabel)
                        else
                            bulkStatus[page] = tostring(err)
                        end
                    end

                    inventoryResponsiveSameLine(2)

                    if imgui.button(
                        ("Give All -> " .. partyMemberUiLabel(targetMember))
                        .. "##StorageGiveAll") then
                        autoApplyPending[page] = false
                        local itemIdSingle = item.id
                        local itemName = tostring(item.name)
                        local instanceStorageId = primaryRow and primaryRow.instanceBacked and primaryRow.storageId or nil
                        local frozenAmount = instanceStorageId ~= nil and 1 or current
                        local targetId = targetMember.id
                        local targetLabel = partyMemberUiLabel(targetMember)
                        local refreshPages = targetMember.slotKey == "Player"
                            and { "Storage", "Player" }
                            or { "Storage", targetMember.slotKey }

                        local queued, err = queueSingleMutation(
                            string.format(
                                "Give all %d x %s to %s",
                                frozenAmount, itemName, targetLabel),
                            function()
                                if instanceStorageId ~= nil then
                                    return core.transferInstance(itemIdSingle, instanceStorageId, core.STORAGE_ID, targetId)
                                end
                                return core.transferStack(itemIdSingle, frozenAmount, core.STORAGE_ID, targetId)
                            end,
                            refreshPages,
                            function(summary)
                                if summary.success then
                                    bulkStatus[page] = type(summary.result) == "string" and summary.result or string.format(
                                        "Transferred all %d x %s to %s.",
                                        frozenAmount, itemName, targetLabel)
                                else
                                    bulkStatus[page] =
                                        "Transfer failed: " .. tostring(summary.error)
                                end
                            end
                        )

                        if queued then
                            bulkStatus[page] = string.format(
                                "Queued transfer of all %d x %s to %s.",
                                frozenAmount, itemName, targetLabel)
                        else
                            bulkStatus[page] = tostring(err)
                        end
                    end
                    end -- duplicate Instance ID guard
                end
            end
        end
    elseif role == "Pawn" then
        imgui.separator()
        imgui.text("Transfer from Pawn")
        local playerId = core.getPlayerId()
        if imgui.button(string.format("Move Selected (%d) -> Storage##%sPawnToStorage", selectedCount, page)) then
            autoApplyPending[page] = false
            moveSelectedInventoryToTarget(page, ownerId, core.STORAGE_ID, "Storage", { page, "Storage" })
        end
        if playerId ~= nil then
            inventoryResponsiveSameLine(2)
            if imgui.button(string.format("Move Selected (%d) -> Player##%sPawnToPlayer", selectedCount, page)) then
                autoApplyPending[page] = false
                moveSelectedInventoryToTarget(page, ownerId, playerId, "Player", { page, "Player" })
            end
        end
        imgui.text("Equipped instances stay on the pawn; exact Instance IDs are used for non-stackable items.")
    end
end

local function selectedWorkspaceContext(page, ownerId)
    local selectedCount = selectionCount(page)
    local row = selected[page] and findSnapshotRowByKey(page, selected[page]) or nil
    local item = row and row.item or nil
    local current = row and row.quantity or nil
    local rowOwnerId = row and row.ownerId or ownerId
    if item and not row.instanceBacked and rowOwnerId then
        current = core.getCount(item.id, rowOwnerId) or current
    end
    return {
        page = page,
        ownerId = rowOwnerId,
        selectedCount = selectedCount,
        visibleSelectedCount = visibleSelectionCount(page),
        rowKey = row and inventoryRowKey(row) or nil,
        row = row,
        itemId = item and item.id or nil,
        item = item,
        quantity = current,
        instanceBacked = row and row.instanceBacked == true or false,
        storageId = row and row.storageId or nil,
        charaId = row and row.charaId or nil,
        isEquipped = row and row.isEquipped or false,
        equipSlot = row and row.equipSlot or nil,
    }
end

local function drawSelectedItemSummary(page, ownerId)
    local ctx = selectedWorkspaceContext(page, ownerId)
    local item = ctx.item
    local dash = "—"
    local selectedCount = tonumber(ctx.selectedCount) or 0
    local visibleCount = tonumber(ctx.visibleSelectedCount) or 0
    local hiddenCount = math.max(0, selectedCount - visibleCount)

    imgui.text("Selected Item")
    imgui.separator()

    if selectedCount <= 0 then
        imgui.text("Selection: 0")
    elseif hiddenCount > 0 then
        imgui.text(string.format(
            "Selection: %d items (%d visible, %d hidden) | Details: active item only",
            selectedCount, visibleCount, hiddenCount))
        imgui.same_line()
        if imgui.button("Clear##SelectedSummary" .. page) then
            clearInventorySelection(page, true)
            ctx = selectedWorkspaceContext(page, ownerId)
            item = nil
            selectedCount = 0
        end
    elseif selectedCount > 1 then
        imgui.text(string.format(
            "Selection: %d items | Details: active item only",
            selectedCount))
        imgui.same_line()
        if imgui.button("Clear##SelectedSummary" .. page) then
            clearInventorySelection(page, true)
            ctx = selectedWorkspaceContext(page, ownerId)
            item = nil
            selectedCount = 0
        end
    else
        imgui.text("Selection: 1 item")
        imgui.same_line()
        if imgui.button("Clear##SelectedSummary" .. page) then
            clearInventorySelection(page, true)
            ctx = selectedWorkspaceContext(page, ownerId)
            item = nil
            selectedCount = 0
        end
    end

    imgui.text("Name: " .. tostring(item and item.name or dash))

    if imgui.begin_table("SelectedItemSummary##" .. page, 2, TABLE_RESIZABLE) then
        stretchColumn("Identity", 1.0, 201, true)
        stretchColumn("State", 1.0, 202, true)

        imgui.table_next_row()
        imgui.table_next_column()
        imgui.text("Item ID: " .. tostring(item and item.id or dash))
        imgui.text("Type: " .. tostring(item and core.describeItem(item) or dash))
        if ctx.instanceBacked then
            local storageText = tostring(ctx.storageId ~= nil and ctx.storageId or dash)
            if ctx.row and ctx.row.storageIdDuplicate then storageText = storageText .. " (DUPLICATE)" end
            imgui.text("Instance ID: " .. storageText)
        end

        imgui.table_next_column()
        imgui.text("Quantity: " .. tostring(ctx.quantity ~= nil and ctx.quantity or dash))
        imgui.text("Stack: " .. tostring(item and core.getStackDisplay(item, ownerId) or dash))

        imgui.end_table()
    end

    return ctx
end

local function drawInventoryListPane(page)
    local changed
    changed, search[page] = imgui.input_text(
        "Search ID / Name / Kind / Instance ID##" .. page,
        search[page])
    if changed then rebuildInventoryFilter(page, true) end

    local rows = filtered[page] or {}
    local pageSize = core.ui.rowsPerPage or 40

    drawRowsPerPage()
    drawPager(page, #rows, pageSize)
    imgui.separator()

    -- The outer workspace pane already owns the vertical bounds. A zero-height
    -- child consumes exactly the remaining room after search/pager controls,
    -- avoiding the old extra bottom reservation.
    if imgui.begin_child_window("InventoryList##" .. page, Vector2f.new(0, 0), false) then
        local columnCount = 7
        if imgui.begin_table("InventoryTable##" .. page, columnCount, SORTABLE_TABLE_FLAGS) then
            setupStandardColumns(false, nil, true)
            imgui.table_headers_row()
            sortRowsBySpecs("Inventory:" .. page, rows, standardSortValue)

            local first = (pageIndex[page] - 1) * pageSize + 1
            local last = math.min(#rows, first + pageSize - 1)
            local rowHeight = core.getUiFontSize() * 1.35

            for i = first, last do
                local row = rows[i]
                imgui.table_next_row(0, rowHeight)
                local rowPos = imgui.get_cursor_screen_pos()
                drawStandardIdentity(row.item, row.quantity, row.storageId, true, row.storageIdDuplicate, row.isEquipped, row.ownerId or ownerId)
                registerInventoryRowHitbox(page, row, i, rowPos.y, rowHeight)
            end
            imgui.end_table()
        end
    end
    imgui.end_child_window()
end

local function remainingWorkspaceHeight()
    local s = core.getUiFontSize()
    local windowSize = imgui.get_window_size()
    local cursorPos = imgui.get_cursor_pos()
    return math.max(s * 16.0, windowSize.y - cursorPos.y - s * 1.5)
end

local function drawInventoryActionPane(page, ownerId, options)
    options = options or {}
    local ctx = selectedWorkspaceContext(page, ownerId)
    local selectedCount = tonumber(ctx.selectedCount) or 0
    local visibleCount = tonumber(ctx.visibleSelectedCount) or 0
    local hiddenCount = math.max(0, selectedCount - visibleCount)
    local activeName = ctx.item and tostring(ctx.item.name) or "—"

    imgui.text("Item Actions")
    imgui.separator()

    if selectedCount <= 0 then
        imgui.text("Selection: 0")
    elseif hiddenCount > 0 then
        imgui.text(string.format(
            "Selection: %d items (%d visible, %d hidden) | Active: %s",
            selectedCount, visibleCount, hiddenCount, activeName))
        inventoryResponsiveSameLine(2)
        if imgui.button("Clear##InventoryAction" .. page) then
            clearInventorySelection(page, true)
            ctx = selectedWorkspaceContext(page, ownerId)
        end
    else
        imgui.text(string.format(
            "Selection: %d item%s | Active: %s",
            selectedCount, selectedCount == 1 and "" or "s", activeName))
        inventoryResponsiveSameLine(2)
        if imgui.button("Clear##InventoryAction" .. page) then
            clearInventorySelection(page, true)
            ctx = selectedWorkspaceContext(page, ownerId)
        end
    end

    drawSelectedItemEditor(page, ownerId, true, options.role or inventoryRole(page))
    return ctx
end

local function infoValueText(value)
    if value == nil then return "—" end
    if type(value) == "number" then
        if math.floor(value) == value then return tostring(math.floor(value)) end
        return string.format("%.2f", value)
    end
    return tostring(value)
end

local function drawInventoryItemInfoContent(page, ownerId, options)
    options = options or {}
    local ctx = selectedWorkspaceContext(page, ownerId)
    local item = ctx.item

    imgui.text("Item Info")
    imgui.separator()

    if not item then
        imgui.text("Select an item to inspect its base and instance data.")
        return ctx
    end

    local info = core.getItemInfo and core.getItemInfo(item.id, ownerId, ctx.storageId) or nil
    imgui.text(tostring(item.name or "Unknown Item"))

    if info then
        local widthClass = inventoryWorkspaceWidthClass()
        local identityColumns = widthClass >= 2 and 2 or 1
        if imgui.begin_table("ItemInfoIdentity##" .. page, identityColumns, TABLE_RESIZABLE) then
            stretchColumn("Base Item", 1.0, 411, true)
            if identityColumns == 2 then stretchColumn("Data", 1.0, 412, true) end
            imgui.table_next_row()
            imgui.table_next_column()
            imgui.text("Item ID: " .. tostring(info.itemId or item.id or "—"))
            imgui.text("Kind: " .. tostring(info.kind or item.kind or "—"))
            if identityColumns == 2 then
                imgui.table_next_column()
            else
                imgui.table_next_row()
                imgui.table_next_column()
            end
            imgui.text("Param: " .. tostring(info.typeName or item.typeName or "—"))
            if info.weight ~= nil then imgui.text("Base Weight: " .. infoValueText(info.weight)) end
            imgui.end_table()
        end

        if type(info.baseStats) == "table" and #info.baseStats > 0 then
            imgui.separator()
            imgui.text("Base Stats")
            local statColumns = widthClass >= 3 and 3 or (widthClass == 2 and 2 or 1)
            if imgui.begin_table("ItemInfoStats##" .. page, statColumns, TABLE_RESIZABLE) then
                for column = 1, statColumns do
                    stretchColumn("Stat " .. tostring(column), 1.0, 420 + column, true)
                end
                for index, stat in ipairs(info.baseStats) do
                    if ((index - 1) % statColumns) == 0 then imgui.table_next_row() end
                    imgui.table_next_column()
                    imgui.text(string.format("%s +%s", tostring(stat.label), infoValueText(stat.value)))
                end
                imgui.end_table()
            end
        end

        local function drawEnhancementBlock()
            if not info.enhancement then return end
            imgui.text("Enhancement")
            imgui.text("Enhancement count: " .. tostring(info.enhancement.num or 0))
            local shown = 0
            for _, stage in ipairs(info.enhancement.stages or {}) do
                if tonumber(stage.index) <= math.max(tonumber(info.enhancement.num) or 0, 0) then
                    imgui.text(string.format("Stage %d: %s", tonumber(stage.index) or 0, tostring(stage.label or stage.raw or "?")))
                    shown = shown + 1
                end
            end
            if shown == 0 and (tonumber(info.enhancement.num) or 0) <= 0 then
                imgui.text("None")
            end
        end

        local function drawAbilitiesBlock()
            if not info.abilities then return end
            imgui.text("Equipment Abilities")
            local slots = info.abilities.slots or {}
            if #slots == 0 then
                imgui.text("None")
            else
                for _, slot in ipairs(slots) do
                    imgui.text(string.format("Slot %d: Ability ID %s", tonumber(slot.slot) or 0, tostring(slot.id or slot.raw or "?")))
                end
            end

            local bonusParts = {}
            for _, entry in ipairs({
                { "STR", info.abilities.physical },
                { "MAG", info.abilities.magic },
                { "Knockdown", info.abilities.blow },
                { "Weight", info.abilities.weight },
            }) do
                local value = tonumber(entry[2])
                if value ~= nil and value ~= 0 then
                    table.insert(bonusParts, string.format("%s %+d", entry[1], value))
                end
            end
            if #bonusParts > 0 then
                imgui.text("Ability modifiers: " .. table.concat(bonusParts, " | "))
            end
        end

        if info.enhancement or info.abilities then
            imgui.separator()
            if widthClass >= 3 and info.enhancement and info.abilities
                and imgui.begin_table("ItemInfoInstance##" .. page, 2, TABLE_RESIZABLE) then
                stretchColumn("Enhancement", 1.0, 431, true)
                stretchColumn("Abilities", 1.0, 432, true)
                imgui.table_next_row()
                imgui.table_next_column(); drawEnhancementBlock()
                imgui.table_next_column(); drawAbilitiesBlock()
                imgui.end_table()
            else
                if info.enhancement then drawEnhancementBlock() end
                if info.enhancement and info.abilities then imgui.separator() end
                if info.abilities then drawAbilitiesBlock() end
            end
        end
    else
        imgui.text("Item data is unavailable for this catalog entry.")
    end

    if type(options.detailRenderer) == "function" then
        imgui.separator()
        local ok, err = pcall(options.detailRenderer, ctx)
        if not ok then
            imgui.text("Item Analysis renderer error: " .. tostring(err))
        end
    end

    return ctx
end

local function drawInventoryDetailPane(page, ownerId, options)
    drawInventoryActionPane(page, ownerId, options)
    imgui.separator()
    drawInventoryItemInfoContent(page, ownerId, options)
end

local function inventoryActionStaticHeight(role, s, widthClass)
    widthClass = tonumber(widthClass) or 2

    -- The normalized controls block is intentionally selection-stable. Its outer
    -- height may change when the window crosses a responsive width band, but not
    -- when the selected item/type changes. Dense states scroll inside the block.
    if role == "Storage" then
        if widthClass >= 3 then return s * 13.0 end
        if widthClass == 2 then return s * 16.0 end
        return s * 21.0
    elseif role == "Pawn" then
        if widthClass >= 3 then return s * 9.5 end
        if widthClass == 2 then return s * 12.0 end
        return s * 16.0
    end

    if widthClass >= 3 then return s * 9.5 end
    if widthClass == 2 then return s * 12.0 end
    return s * 16.0
end

local function inventoryInfoStaticHeight(s, widthClass)
    widthClass = tonumber(widthClass) or 2

    -- Item Info follows the same rule: stable while clicking between items. Wider
    -- windows need less vertical room because identity/stats can use more columns.
    -- Data-heavy items simply scroll inside this fixed-height pane.
    if widthClass >= 3 then return s * 10.5 end
    if widthClass == 2 then return s * 13.0 end
    return s * 16.0
end

local function drawInventoryPage(page, options)
    options = options or {}
    local ownerId = options.ownerId
    if ownerId == nil then ownerId = core.getInventoryOwnerId(page) end
    if ownerId == nil and isPawnInventoryPage(page) then
        imgui.text("No pawn is currently available in this slot.")
        imgui.text("The tab will populate automatically when the pawn joins the party.")
        return
    end

    local s = core.getUiFontSize()
    local windowSize = imgui.get_window_size()
    local workspaceHeight = remainingWorkspaceHeight()
    local wide = windowSize.x >= (tonumber(options.wideThreshold) or (s * 68))

    -- Keep the dedicated Item Analysis window's wide two-column workspace. The
    -- normalized Inventory window below stays a full-width vertical flow at every
    -- width; only the controls/stat rows reflow within that flow.
    if wide and type(options.detailRenderer) == "function" then
        local listWeight = tonumber(options.listWeight) or 1.65
        local detailWeight = tonumber(options.detailWeight) or 1.0
        local listOnRight = options.listSide == "right"

        local function drawListColumn()
            if imgui.begin_child_window(
                "InventoryListPane##" .. page,
                Vector2f.new(0, workspaceHeight),
                false) then
                drawInventoryListPane(page)
            end
            imgui.end_child_window()
        end

        local function drawDetailColumn()
            if imgui.begin_child_window(
                "InventoryDetailPane##" .. page,
                Vector2f.new(0, workspaceHeight),
                true,
                HORIZONTAL_SCROLLBAR) then
                drawInventoryDetailPane(page, ownerId, options)
            end
            imgui.end_child_window()
        end

        if imgui.begin_table("InventoryWorkspaceSplit##" .. page, 2, TABLE_RESIZABLE) then
            if listOnRight then
                stretchColumn("Details", detailWeight, 302, true)
                stretchColumn("Items", listWeight, 301, true)
            else
                stretchColumn("Items", listWeight, 301, true)
                stretchColumn("Details", detailWeight, 302, true)
            end
            imgui.table_next_row()
            imgui.table_next_column()
            if listOnRight then drawDetailColumn() else drawListColumn() end
            imgui.table_next_column()
            if listOnRight then drawListColumn() else drawDetailColumn() end
            imgui.end_table()
        end
        return
    end

    -- Normalized Inventory layout:
    --   1) Static Controls Block: full-width and width-aware internally.
    --   2) Item Info: full-width, moved directly beneath the controls.
    --   3) Item List: last in the flow and consumes every remaining pixel to the
    --      bottom of the Inventory workspace. Nothing is reserved beneath it.
    --
    -- The heavier Item Analysis/debugger workspace above deliberately keeps its
    -- own split layout; these rules are for the normalized Inventory UI only.
    local role = options.role or inventoryRole(page)
    local widthClass = inventoryWorkspaceWidthClass()

    local actionHeight = inventoryActionStaticHeight(role, s, widthClass)
    if imgui.begin_child_window(
        "InventoryActionPane##" .. page,
        Vector2f.new(0, actionHeight),
        true) then
        drawInventoryActionPane(page, ownerId, options)
    end
    imgui.end_child_window()

    imgui.spacing()

    local remainingAfterAction = remainingWorkspaceHeight()
    local listFloor = s * 8.0
    local infoPreferred = inventoryInfoStaticHeight(s, widthClass)
    local infoMax = math.max(s * 5.0, remainingAfterAction - listFloor - s * 0.55)
    local infoHeight = math.max(s * 5.0, math.min(infoPreferred, infoMax))

    if imgui.begin_child_window(
        "InventoryItemInfoPane##" .. page,
        Vector2f.new(0, infoHeight),
        true,
        HORIZONTAL_SCROLLBAR) then
        drawInventoryItemInfoContent(page, ownerId, options)
    end
    imgui.end_child_window()

    imgui.spacing()

    -- Zero height is deliberate here: because this is the final child in the
    -- normalized workspace, ImGui gives the Item List all remaining vertical room
    -- down to the bottom edge. There is no reserved pane below it.
    if imgui.begin_child_window(
        "InventoryListPaneNarrow##" .. page,
        Vector2f.new(0, 0),
        false) then
        drawInventoryListPane(page)
    end
    imgui.end_child_window()
end

function window.drawInventoryWorkspace(page, options)
    if not isLiveInventoryPage(page) then return false end
    initializeUiState()
    options = options or {}
    options.ownerId = options.ownerId or core.getInventoryOwnerId(page)
    options.role = options.role or inventoryRole(page)
    drawInventoryPage(page, options)
    return true
end


function window.getInventoryTabs(refreshPartyFirst)
    return core.getInventoryTabDescriptors(refreshPartyFirst == true)
end

function window.refreshInventoryPage(page)
    if not isLiveInventoryPage(page) then return false end
    refreshPage(page, true)
    return true
end

local function playerRuleLabel(rule)
    if not rule then return "Keep All" end
    if rule.isOverride then
        if rule.mode == "ignore" then return "Keep All (Custom)" end
        return "Move Excess (Custom)"
    end
    return rule.enabled and "Move Excess (Default)" or "Keep All (Default)"
end

local function queuePlayerCleanup()
    local busy = queueBusyText()
    if busy then
        playerStatus = busy
        return false
    end

    local ok, message, total = core.cleanPlayerByRules()
    if ok then
        playerStatus = total and total > 0
            and tostring(message)
            or "Player cleanup: nothing eligible to move."
        return true
    end

    playerStatus = "Could not queue Player cleanup: " .. tostring(message)
    return false
end

local function drawPlayerRuleEditor()
    local count = playerRuleSelectionCount()
    imgui.text(string.format("Selected: %d", count))

    local transferLabel = playerOverrideMode == "transfer" and "[Move Excess]" or "Move Excess"
    local keepLabel = playerOverrideMode == "ignore" and "[Keep All]" or "Keep All"
    if imgui.button(transferLabel .. "##PlayerOverrideModeTransfer") then
        playerOverrideMode = "transfer"
    end
    imgui.same_line()
    if imgui.button(keepLabel .. "##PlayerOverrideModeKeep") then
        playerOverrideMode = "ignore"
    end

    if playerOverrideMode == "transfer" then
        imgui.text("Move excess to: Storage")
        local changed
        imgui.text("Keep at least this many on Player:")
        imgui.same_line()
        changed, playerOverrideKeep = imgui.drag_int(
            "##PlayerOverrideKeep",
            playerOverrideKeep,
            1,
            0,
            999999)
        if changed then playerOverrideKeep = math.max(0, playerOverrideKeep) end
    end

    if imgui.button("Apply Rule##PlayerRulesSave") then
        if count == 0 then
            playerStatus = "Select one or more items first."
        else
            local ok, err, changed = core.setPlayerCleanerOverrides(
                playerRuleSelection,
                playerOverrideMode,
                playerOverrideKeep)
            if ok then
                playerStatus = string.format("Saved Player override for %d item%s.", changed or 0, (changed or 0) == 1 and "" or "s")
            else
                playerStatus = "Could not save Player override: " .. tostring(err)
            end
        end
    end
    imgui.same_line()
    if imgui.button("Restore Default##PlayerRulesRemove") then
        if count == 0 then
            playerStatus = "Select one or more items first."
        else
            local ok, err, changed = core.clearPlayerCleanerRules(playerRuleSelection)
            if ok then
                playerStatus = string.format("Removed %d Player override%s.", changed or 0, (changed or 0) == 1 and "" or "s")
                if playerRulePrimary then
                    local item = core.getCatalogEntry(playerRulePrimary, true)
                    if item then loadPlayerOverrideEditor(item) end
                end
            else
                playerStatus = "Could not remove Player override: " .. tostring(err)
            end
        end
    end
    imgui.same_line()
    if imgui.button("Clear Selection##PlayerRulesClearSelection") then
        clearPlayerRuleSelection()
    end
end

local function drawPlayerRuleList()
    local changed
    changed, search.PlayerRules = imgui.input_text(
        "Search ID / Name / Kind##PlayerRules",
        search.PlayerRules)
    if changed then rebuildPlayerRuleFilter(true) end

    local rows = filtered.PlayerRules or {}
    local pageSize = core.ui.rowsPerPage or 40
    drawRowsPerPage()
    drawPager("PlayerRules", #rows, pageSize)

    local s = core.getUiFontSize()
    if imgui.begin_child_window("PlayerRuleList##PlayerRules", Vector2f.new(0, 0), false) then
        local columns = 5
        if imgui.begin_table("PlayerRuleTable", columns, SORTABLE_TABLE_FLAGS) then
            stretchColumn("ID", 0.7, 1, false)
            stretchColumn("Name", 4.0, 2, false)
            stretchColumn("Kind", 1.5, 3, false)
            stretchColumn("Rule", 1.8, 4, false)
            stretchColumn("Keep Qty", 0.9, 5, false)
            imgui.table_headers_row()
            sortRowsBySpecs("PlayerRules", rows, function(item, userId)
                local rule = core.getPlayerCleanerRule(item.id)
                if userId == 1 then return tonumber(item.id) or 0 end
                if userId == 2 then return item.name or "" end
                if userId == 3 then return core.describeItem(item) end
                if userId == 4 then return playerRuleLabel(rule) end
                if userId == 5 then return tonumber(rule.keep) or 0 end
                return 0
            end)

            local first = (pageIndex.PlayerRules - 1) * pageSize + 1
            local last = math.min(#rows, first + pageSize - 1)
            local rowHeight = s * 1.35
            for i = first, last do
                local item = rows[i]
                local rule = core.getPlayerCleanerRule(item.id)
                imgui.table_next_row(0, rowHeight)
                local rowPos = imgui.get_cursor_screen_pos()
                imgui.table_next_column(); imgui.text(tostring(item.id))
                imgui.table_next_column(); imgui.text(tostring(item.name))
                imgui.table_next_column(); imgui.text(tostring(core.describeItem(item)))
                imgui.table_next_column(); imgui.text(playerRuleLabel(rule))
                imgui.table_next_column(); imgui.text(rule.enabled and tostring(rule.keep or 0) or "-")
                registerPlayerRuleRowHitbox(item, i, rowPos.y, rowHeight)
            end
            imgui.end_table()
        end
    end
    imgui.end_child_window()
end

local function drawPlayerAutomationControls()
    local cleaner = core.getPlayerCleanerStatus()

    imgui.text("Player -> Storage Automation")
    imgui.separator()
    imgui.text(string.format(
        "Default: Keep all items on Player | Custom rules: %d",
        cleaner.overrideCount or 0))

    if imgui.button("Restore All Defaults##PlayerRulesDefaults") then
        if (cleaner.overrideCount or 0) > 0 then
            playerConfirmDefaults = true
        else
            playerStatus = "No Player overrides to clear."
        end
    end

    if playerConfirmDefaults then
        imgui.same_line()
        imgui.text(string.format("Clear all %d Player overrides?", cleaner.overrideCount or 0))
        imgui.same_line()
        if imgui.button("Confirm##PlayerRulesDefaultsConfirm") then
            core.clearPlayerCleanerOverrides()
            clearPlayerRuleSelection()
            playerConfirmDefaults = false
            playerStatus = "All Player overrides removed."
        end
        imgui.same_line()
        if imgui.button("Cancel##PlayerRulesDefaultsCancel") then
            playerConfirmDefaults = false
        end
    end

    local changed
    changed, cleaner.enabled = imgui.checkbox("Enable automatic Player cleanup##PlayerCleaner", cleaner.enabled == true)
    if changed then
        core.setPlayerCleanerEnabled(cleaner.enabled)
        cleaner = core.getPlayerCleanerStatus()
    end

    imgui.text("Move Excess rules keep the chosen quantity on Player and send only the excess to Storage.")
    imgui.text("Keep All rules never move that item automatically. Equipped items are never transferred.")
    imgui.text("Runs from DD2 inventory events; Player and Pawn automation are independent.")

    if imgui.button("Run Player Cleanup Now") then queuePlayerCleanup() end
    imgui.same_line()
    if imgui.button("Refresh Player Inventory##PlayerRules") then
        if core.refreshPlayer() then
            rebuildInventoryFilter("Player", false)
            playerStatus = "Player inventory refreshed."
        else
            playerStatus = tostring(core.lastError or "Player refresh failed.")
        end
    end

    local liveCleaner = core.getPlayerCleanerStatus()
    local liveStatus = tostring(liveCleaner.status or "")
    local liveStatusLower = lower(liveStatus)
    if string.find(liveStatusLower, "failure", 1, true)
        or string.find(liveStatusLower, "failed", 1, true)
        or string.find(liveStatusLower, "aborted", 1, true)
        or string.find(liveStatusLower, "could not", 1, true)
        or string.find(liveStatus, "DISABLED", 1, true) then
        imgui.text(liveStatus)
    end
    if playerStatus ~= "" then imgui.text(playerStatus) end
end

local function drawPlayerRuleInfoPane()
    local dash = "—"
    local primary = playerRulePrimary and core.getCatalogEntry(playerRulePrimary, true) or nil
    local primaryRule = primary and core.getPlayerCleanerRule(primary.id) or nil
    local count = playerRuleSelectionCount()

    imgui.text("Selected Item Rule")
    imgui.text(string.format(
        "Selection: %d item%s | Details: active item only",
        count,
        count == 1 and "" or "s"))
    imgui.text("Name: " .. tostring(primary and primary.name or dash))

    if imgui.begin_table("PlayerSelectedRuleSummary", 2, TABLE_RESIZABLE) then
        stretchColumn("Identity", 1.0, 451, true)
        stretchColumn("Rule", 1.0, 452, true)
        imgui.table_next_row()
        imgui.table_next_column()
        imgui.text("Item ID: " .. tostring(primary and primary.id or dash))
        imgui.text("Kind: " .. tostring(primary and core.describeItem(primary) or dash))
        imgui.table_next_column()
        imgui.text("Current: " .. tostring(primaryRule and playerRuleLabel(primaryRule) or dash))
        imgui.text("Destination: " .. tostring(
            primaryRule and primaryRule.enabled and "Storage" or dash))
        imgui.text("Player Keep Quantity: " .. tostring(
            primaryRule and primaryRule.enabled and (primaryRule.keep or 0) or dash))
        imgui.end_table()
    end

    imgui.separator()
    drawPlayerRuleEditor()
end

local function pawnRuleLabel(rule)
    if not rule then return "Unmanaged" end
    if rule.isOverride then
        if rule.mode == "ignore" then return "Unmanaged (Custom)" end
        return "Maintain Target (Custom)"
    end
    return rule.enabled and "Maintain Target (Default)" or "Unmanaged (Default)"
end


local function queuePawnCleanup()
    local busy = queueBusyText()
    if busy then
        pawnStatus = busy
        return false
    end

    local ok, message, total = core.cleanPawnsByRules()
    if ok then
        pawnStatus = total and total > 0
            and tostring(message)
            or "Pawn cleanup: nothing eligible to move."
        return true
    end

    pawnStatus = "Could not queue pawn cleanup: " .. tostring(message)
    return false
end

local function drawPawnRuleEditor()
    local count = pawnRuleSelectionCount()
    imgui.text(string.format("Selected: %d", count))

    local transferLabel = pawnOverrideMode == "transfer" and "[Maintain Target]" or "Maintain Target"
    local ignoreLabel = pawnOverrideMode == "ignore" and "[Leave Unmanaged]" or "Leave Unmanaged"
    if imgui.button(transferLabel .. "##PawnOverrideModeTransfer") then
        pawnOverrideMode = "transfer"
    end
    imgui.same_line()
    if imgui.button(ignoreLabel .. "##PawnOverrideModeIgnore") then
        pawnOverrideMode = "ignore"
    end

    if pawnOverrideMode == "transfer" then
        imgui.text("Balance with:")
        imgui.same_line()
        local storageLabel = pawnOverrideDestination == "Storage" and "[Storage]" or "Storage"
        local playerLabel = pawnOverrideDestination == "Player" and "[Player]" or "Player"
        if imgui.button(storageLabel .. "##PawnOverrideDestinationStorage") then
            pawnOverrideDestination = "Storage"
        end
        imgui.same_line()
        if imgui.button(playerLabel .. "##PawnOverrideDestinationPlayer") then
            pawnOverrideDestination = "Player"
        end
        local changed
        imgui.text("Desired quantity on each Pawn:")
        imgui.same_line()
        changed, pawnOverrideKeep = imgui.drag_int(
            "##PawnOverrideKeep",
            pawnOverrideKeep,
            1,
            0,
            999999)
        if changed then pawnOverrideKeep = math.max(0, pawnOverrideKeep) end
    end

    if imgui.button("Apply Rule##PawnRulesSave") then
        if count == 0 then
            pawnStatus = "Select one or more items first."
        else
            local ok, err, changed = core.setPawnCleanerOverrides(
                pawnRuleSelection,
                pawnOverrideMode,
                pawnOverrideDestination,
                pawnOverrideKeep)
            if ok then
                pawnStatus = string.format("Saved %d override%s.", changed, changed == 1 and "" or "s")
            else
                pawnStatus = tostring(err)
            end
        end
    end
    imgui.same_line()
    if imgui.button("Restore Default##PawnRulesRemove") then
        if count == 0 then
            pawnStatus = "Select one or more items first."
        else
            local ok, err, changed = core.clearPawnCleanerRules(pawnRuleSelection)
            if ok then
                pawnStatus = changed > 0
                    and string.format("Removed %d override%s.", changed, changed == 1 and "" or "s")
                    or "Selected items already use the default rules."
            else
                pawnStatus = tostring(err)
            end
        end
    end
    imgui.same_line()
    if imgui.button("Clear Selection##PawnRulesClearSelection") then
        clearPawnRuleSelection()
    end
end


local function drawPawnRuleList()
    local changed
    changed, search.Pawns = imgui.input_text(
        "Search ID / Name / Kind##Pawns",
        search.Pawns)
    if changed then rebuildPawnRuleFilter(true) end

    local rows = filtered.Pawns or {}
    local pageSize = core.ui.rowsPerPage or 40
    drawRowsPerPage()
    drawPager("Pawns", #rows, pageSize)

    local s = core.getUiFontSize()
    if imgui.begin_child_window("PawnRuleList##Pawns", Vector2f.new(0, 0), false) then
        local columns = 6
        if imgui.begin_table("PawnRuleTable", columns, SORTABLE_TABLE_FLAGS) then
            stretchColumn("ID", 0.7, 1, false)
            stretchColumn("Name", 4.0, 2, false)
            stretchColumn("Kind", 1.5, 3, false)
            stretchColumn("Rule", 1.8, 4, false)
            stretchColumn("Balance With", 1.2, 5, false)
            stretchColumn("Pawn Target", 1.0, 6, false)
            imgui.table_headers_row()
            sortRowsBySpecs("PawnRules", rows, function(item, userId)
                local rule = core.getPawnCleanerRule(item.id)
                if userId == 1 then return tonumber(item.id) or 0 end
                if userId == 2 then return item.name or "" end
                if userId == 3 then return core.describeItem(item) end
                if userId == 4 then return pawnRuleLabel(rule) end
                if userId == 5 then return rule.destination or "" end
                if userId == 6 then return tonumber(rule.keep) or 0 end
                return 0
            end)

            local first = (pageIndex.Pawns - 1) * pageSize + 1
            local last = math.min(#rows, first + pageSize - 1)
            local rowHeight = s * 1.35
            for i = first, last do
                local item = rows[i]
                local rule = core.getPawnCleanerRule(item.id)
                imgui.table_next_row(0, rowHeight)
                local rowPos = imgui.get_cursor_screen_pos()
                imgui.table_next_column(); imgui.text(tostring(item.id))
                imgui.table_next_column(); imgui.text(tostring(item.name))
                imgui.table_next_column(); imgui.text(tostring(core.describeItem(item)))
                imgui.table_next_column(); imgui.text(pawnRuleLabel(rule))
                imgui.table_next_column(); imgui.text(rule.enabled and tostring(rule.destination or "Storage") or "-")
                imgui.table_next_column(); imgui.text(rule.enabled and tostring(rule.keep or 0) or "-")
                registerPawnRuleRowHitbox(item, i, rowPos.y, rowHeight)
            end
            imgui.end_table()
        end
    end
    imgui.end_child_window()
end

local function drawPawnAutomationControls()
    local cleaner = core.getPawnCleanerStatus()

    imgui.text("Pawn Inventory Automation")
    imgui.separator()
    imgui.text(string.format(
        "Built-in managed-item rules: %d | Custom rules: %d",
        cleaner.defaultCount or 0,
        cleaner.overrideCount or 0))

    if imgui.button("Restore All Defaults##PawnRulesDefaults") then
        if (cleaner.overrideCount or 0) > 0 then
            pawnConfirmDefaults = true
        else
            pawnStatus = "No overrides to clear."
        end
    end

    if pawnConfirmDefaults then
        imgui.same_line()
        imgui.text(string.format("Clear all %d overrides?", cleaner.overrideCount or 0))
        imgui.same_line()
        if imgui.button("Confirm##PawnRulesDefaultsConfirm") then
            core.clearPawnCleanerOverrides()
            clearPawnRuleSelection()
            pawnConfirmDefaults = false
            pawnStatus = "All overrides removed."
        end
        imgui.same_line()
        if imgui.button("Cancel##PawnRulesDefaultsCancel") then
            pawnConfirmDefaults = false
        end
    end

    local changed
    changed, cleaner.enabled = imgui.checkbox("Enable Pawn inventory automation##PawnCleaner", cleaner.enabled == true)
    if changed then
        -- The control callback schedules one safe LateUpdate pass when enabled;
        -- do not enumerate pawn inventories directly from the UI callback.
        core.setPawnCleanerEnabled(cleaner.enabled)
        cleaner = core.getPawnCleanerStatus()
    end

    local retrievalDisplayChoices = {
        "Anywhere (including combat)",
        "Outside combat",
        "At camp or in town (outside combat)",
        "In town only (outside combat)",
    }
    local retrievalIndex = core.getPawnRetrievalModeIndex()
    local retrievalChanged
    retrievalChanged, retrievalIndex = imgui.combo(
        "Refill Timing##PawnRetrievalPolicy",
        retrievalIndex,
        retrievalDisplayChoices)
    if retrievalChanged then
        core.setPawnRetrievalMode(retrievalIndex)
        cleaner = core.getPawnCleanerStatus()
    end

    local retrieval = cleaner.retrieval or core.getPawnRetrievalStatus()
    imgui.text("Maintain Target rules move excess away immediately; shortages refill only when timing allows it.")
    imgui.text("The inventory selected under Balance With is used as both the excess destination and the refill source.")
    imgui.text(string.format(
        "Current state: Battle=%s | Camp=%s | Town=%s | Refill=%s",
        retrieval.inBattle == nil and "?" or tostring(retrieval.inBattle),
        retrieval.inCamp == nil and "?" or tostring(retrieval.inCamp),
        retrieval.inTown == nil and "?" or tostring(retrieval.inTown),
        retrieval.allowed and "Allowed" or "Locked"))
    imgui.text("Automation reacts to DD2 inventory/state events; it does not repeatedly scan every Pawn inventory.")
    imgui.text("Equipped items are never moved out of a Pawn inventory.")

    if imgui.button("Run Pawn Cleanup Now") then queuePawnCleanup() end
    imgui.same_line()
    if imgui.button("Refresh Pawn Inventories") then
        if core.analyzePawns() then
            pawnStatus = "Pawn inventories refreshed."
        else
            pawnStatus = tostring(core.lastError or "Pawn refresh failed.")
        end
    end

    local liveCleaner = core.getPawnCleanerStatus()
    local liveStatus = tostring(liveCleaner.status or "")
    local liveStatusLower = lower(liveStatus)
    if string.find(liveStatusLower, "failure", 1, true)
        or string.find(liveStatusLower, "failed", 1, true)
        or string.find(liveStatusLower, "aborted", 1, true)
        or string.find(liveStatusLower, "could not", 1, true)
        or string.find(liveStatus, "DISABLED", 1, true) then
        imgui.text(liveStatus)
    end
    local refillStatus = tostring(liveCleaner.refillStatus or "")
    if refillStatus ~= "" and refillStatus ~= "Pawn auto-retrieval is idle." then
        imgui.text(refillStatus)
    end
    if pawnStatus ~= "" then imgui.text(pawnStatus) end
end

local function drawPawnRuleInfoPane()
    local dash = "—"
    local primary = pawnRulePrimary and core.getCatalogEntry(pawnRulePrimary, true) or nil
    local primaryRule = primary and core.getPawnCleanerRule(primary.id) or nil
    local count = pawnRuleSelectionCount()

    imgui.text("Selected Item Rule")
    imgui.text(string.format(
        "Selection: %d item%s | Details: active item only",
        count,
        count == 1 and "" or "s"))
    imgui.text("Name: " .. tostring(primary and primary.name or dash))

    if imgui.begin_table("PawnSelectedRuleSummary", 2, TABLE_RESIZABLE) then
        stretchColumn("Identity", 1.0, 401, true)
        stretchColumn("Rule", 1.0, 402, true)
        imgui.table_next_row()
        imgui.table_next_column()
        imgui.text("Item ID: " .. tostring(primary and primary.id or dash))
        imgui.text("Kind: " .. tostring(primary and core.describeItem(primary) or dash))
        imgui.table_next_column()
        imgui.text("Current: " .. tostring(primaryRule and pawnRuleLabel(primaryRule) or dash))
        imgui.text("Balance With: " .. tostring(
            primaryRule and primaryRule.enabled and (primaryRule.destination or "Storage") or dash))
        imgui.text("Pawn Target Quantity: " .. tostring(
            primaryRule and primaryRule.enabled and (primaryRule.keep or 0) or dash))
        imgui.end_table()
    end

    imgui.separator()
    drawPawnRuleEditor()

    if next(core.lastReport or {}) ~= nil then
        imgui.separator()
        imgui.text("Last Cleanup Report")
        for label, report in pairs(core.lastReport) do
            imgui.text(string.format("%s: %d stacks / %d units moved; %d units skipped; %d errors",
                label, report.movedStacks or 0, report.movedUnits or 0,
                report.skippedUnits or 0, #(report.errors or {})))
            for _, err in ipairs(report.errors or {}) do imgui.text("  ERROR: " .. err) end
        end
    end
end

local function automationControlsStaticHeight(scope, s, widthClass)
    widthClass = tonumber(widthClass) or 2

    -- Match the normalized Inventory workspace: controls stay full-width and
    -- selection-stable. Width bands may change the outer height; status/help
    -- overflow scrolls inside instead of pushing the rule list around.
    if scope == "Pawns" then
        if widthClass >= 3 then return s * 14.5 end
        if widthClass == 2 then return s * 17.5 end
        return s * 22.0
    end

    if widthClass >= 3 then return s * 10.5 end
    if widthClass == 2 then return s * 13.0 end
    return s * 17.0
end

local function automationRuleStaticHeight(scope, s, widthClass)
    widthClass = tonumber(widthClass) or 2

    -- Selected-rule editing mirrors Inventory's Item Info block: one stable
    -- full-width pane above the list, with dense content scrolling internally.
    if scope == "Pawns" then
        if widthClass >= 3 then return s * 12.0 end
        if widthClass == 2 then return s * 14.5 end
        return s * 18.0
    end

    if widthClass >= 3 then return s * 10.5 end
    if widthClass == 2 then return s * 13.0 end
    return s * 16.0
end

local function drawPlayerAutomationPage(options)
    options = options or {}

    if not core.catalogReady then
        imgui.text("Item DB cache is not loaded.")
        if imgui.button("Load Item DB Cache##PlayerRules") then
            local ok = core.ensureCatalog(false)
            if ok then rebuildPlayerRuleFilter(false) end
        end
        return
    end

    local s = core.getUiFontSize()
    local widthClass = inventoryWorkspaceWidthClass()

    local controlsHeight = automationControlsStaticHeight("Player", s, widthClass)
    if imgui.begin_child_window(
        "PlayerAutomationControlsPane",
        Vector2f.new(0, controlsHeight),
        true,
        HORIZONTAL_SCROLLBAR) then
        drawPlayerAutomationControls()
    end
    imgui.end_child_window()

    imgui.spacing()

    local remainingAfterControls = remainingWorkspaceHeight()
    local listFloor = s * 8.0
    local rulePreferred = automationRuleStaticHeight("Player", s, widthClass)
    local ruleMax = math.max(s * 6.0, remainingAfterControls - listFloor - s * 0.55)
    local ruleHeight = math.max(s * 6.0, math.min(rulePreferred, ruleMax))

    if imgui.begin_child_window(
        "PlayerAutomationRulePane",
        Vector2f.new(0, ruleHeight),
        true,
        HORIZONTAL_SCROLLBAR) then
        drawPlayerRuleInfoPane()
    end
    imgui.end_child_window()

    imgui.spacing()

    -- Final pane consumes all remaining Automation workspace height, matching the
    -- normalized Inventory page's controls -> info -> list flow.
    if imgui.begin_child_window(
        "PlayerRulesListPaneNormalized",
        Vector2f.new(0, 0),
        false) then
        drawPlayerRuleList()
    end
    imgui.end_child_window()
end

local function drawPawnsPage(options)
    options = options or {}

    if not core.catalogReady then
        imgui.text("Item DB cache is not loaded.")
        if imgui.button("Load Item DB Cache##PawnRules") then
            local ok = core.ensureCatalog(false)
            if ok then rebuildPawnRuleFilter(false); rebuildPlayerRuleFilter(false) end
        end
        return
    end

    local s = core.getUiFontSize()
    local widthClass = inventoryWorkspaceWidthClass()

    local controlsHeight = automationControlsStaticHeight("Pawns", s, widthClass)
    if imgui.begin_child_window(
        "PawnAutomationControlsPane",
        Vector2f.new(0, controlsHeight),
        true,
        HORIZONTAL_SCROLLBAR) then
        drawPawnAutomationControls()
    end
    imgui.end_child_window()

    imgui.spacing()

    local remainingAfterControls = remainingWorkspaceHeight()
    local listFloor = s * 8.0
    local rulePreferred = automationRuleStaticHeight("Pawns", s, widthClass)
    local ruleMax = math.max(s * 6.0, remainingAfterControls - listFloor - s * 0.55)
    local ruleHeight = math.max(s * 6.0, math.min(rulePreferred, ruleMax))

    if imgui.begin_child_window(
        "PawnAutomationRulePane",
        Vector2f.new(0, ruleHeight),
        true,
        HORIZONTAL_SCROLLBAR) then
        drawPawnRuleInfoPane()
    end
    imgui.end_child_window()

    imgui.spacing()

    if imgui.begin_child_window(
        "PawnRulesListPaneNormalized",
        Vector2f.new(0, 0),
        false) then
        drawPawnRuleList()
    end
    imgui.end_child_window()
end


function window.refreshLiveInventory(reason)
    initializeUiState()
    if reason ~= nil then lastNativeRefreshReason = tostring(reason) end
    return refreshInventoryWorkspace()
end

function window.markNativeInventoryChanged(reason)
    lastNativeRefreshReason = tostring(reason or "native inventory event")
end


function window.processPendingRefreshes()
    flushPendingRefreshes()
end

local function registerCatalogRowHitbox(item, rowScreenY, rowHeight)
    local s = core.getUiFontSize()
    local windowPos = imgui.get_window_pos()
    local windowSize = imgui.get_window_size()
    local mouse = imgui.get_mouse()

    local x1 = windowPos.x + s * 0.35
    local x2 = windowPos.x + windowSize.x - s * 1.55
    local y1 = rowScreenY - s * 0.10
    local y2 = y1 + rowHeight
    local clipY1 = math.max(y1, windowPos.y)
    local clipY2 = math.min(y2, windowPos.y + windowSize.y)

    local hovered = mouse ~= nil
        and clipY2 > clipY1
        and mouse.x >= x1 and mouse.x < x2
        and mouse.y >= clipY1 and mouse.y < clipY2

    local isSelected = item and selected.Catalog == item.id
    if hovered then
        imgui.table_set_bg_color(ROW_BG_BASE, isSelected and ROW_PRIMARY_BG or ROW_HOVER_BG, -1)
    elseif isSelected then
        imgui.table_set_bg_color(ROW_BG_BASE, ROW_PRIMARY_BG, -1)
    end

    if hovered and imgui.is_mouse_clicked(0) and item then
        selected.Catalog = item.id
        catalogStatus = ""
    end
end

local function drawItemDatabaseListPane()
    -- Keep the detail pane aligned with the actual item-list box, not with the
    -- search/paging controls above it. Measure this header live so font scaling
    -- and future control changes cannot desynchronize the two columns.
    local headerStartY = tonumber(imgui.get_cursor_pos().y) or 0

    local changed
    changed, search.Catalog = imgui.input_text(
        "Search ID / Name / Kind##ItemDatabase",
        search.Catalog)
    if changed then rebuildCatalogFilter() end

    local rows = filtered.Catalog or {}
    local pageSize = core.ui.rowsPerPage or 40
    drawRowsPerPage()
    drawPager("Catalog", #rows, pageSize)
    imgui.separator()

    local listStartY = tonumber(imgui.get_cursor_pos().y) or headerStartY
    local headerHeight = math.max(0, listStartY - headerStartY)

    if imgui.begin_child_window("ItemDatabaseList", Vector2f.new(0, 0), false) then
        if imgui.begin_table("ItemDatabaseTable", 4, SORTABLE_TABLE_FLAGS) then
            stretchColumn("ID", 0.7, 1, false)
            stretchColumn("Name", 4.6, 2, false)
            stretchColumn("Kind", 1.6, 3, false)
            stretchColumn("Stack", 1.0, 5, false)
            imgui.table_headers_row()
            sortRowsBySpecs("Catalog", rows, function(item, userId)
                if userId == 1 then return tonumber(item.id) or 0 end
                if userId == 2 then return item.name or "" end
                if userId == 3 then return core.describeItem(item) end
                if userId == 5 then return tonumber(core.getEffectiveStack(item)) or 0 end
                return 0
            end)

            local first = (pageIndex.Catalog - 1) * pageSize + 1
            local last = math.min(#rows, first + pageSize - 1)
            local rowHeight = core.getUiFontSize() * 1.35
            for i = first, last do
                local item = rows[i]
                imgui.table_next_row(0, rowHeight)
                local rowPos = imgui.get_cursor_screen_pos()
                imgui.table_next_column(); imgui.text(tostring(item.id))
                imgui.table_next_column(); imgui.text(tostring(item.name))
                imgui.table_next_column(); imgui.text(tostring(core.describeItem(item)))
                imgui.table_next_column(); imgui.text(tostring(core.getStackDisplay(item)))
                registerCatalogRowHitbox(item, rowPos.y, rowHeight)
            end
            imgui.end_table()
        end
    end
    imgui.end_child_window()
    return headerHeight
end

local function queueCatalogAdd(item, amount, destination)
    if not item then
        catalogStatus = "Select an item first."
        return
    end

    local itemId = item.id
    local itemName = tostring(item.name)
    local frozenAmount = math.max(1, math.floor(tonumber(amount) or 1))
    local targetId = destination == "Player" and core.getPlayerId() or core.STORAGE_ID
    if destination == "Player" and not targetId then
        catalogStatus = "Player CharacterID is unavailable."
        return
    end

    local queued, err = queueSingleMutation(
        string.format("Item Database add %d x %s to %s", frozenAmount, itemName, destination),
        function() return core.addItem(itemId, frozenAmount, targetId) end,
        { destination },
        function(summary)
            if summary.success then
                catalogStatus = string.format("Added %d x %s to %s.", frozenAmount, itemName, destination)
            else
                catalogStatus = "Add Item failed: " .. tostring(summary.error)
            end
        end
    )

    if queued then
        catalogStatus = string.format("Queued %d x %s -> %s.", frozenAmount, itemName, destination)
    else
        catalogStatus = tostring(err)
    end
end

local function itemDatabaseWrapText(value, width)
    local text = tostring(value or "")
    local s = core.getUiFontSize()
    width = math.max(s * 8, tonumber(width) or ((tonumber(imgui.get_window_size().x) or (s * 20)) - s * 1.5))

    for paragraph in (text .. "\n"):gmatch("(.-)\n") do
        if paragraph == "" then
            imgui.text("")
        else
            local line = ""
            for word in paragraph:gmatch("%S+") do
                local candidate = line == "" and word or (line .. " " .. word)
                if line ~= "" and imgui.calc_text_size(candidate).x > width then
                    imgui.text(line)
                    line = word
                else
                    line = candidate
                end
            end
            if line ~= "" then imgui.text(line) end
        end
    end
end

local function drawItemDatabaseDetailPane()
    local dash = "—"
    local item = selected.Catalog and core.getCatalogEntry(selected.Catalog, true) or nil
    local stats = core.getCatalogStats()
    local s = core.getUiFontSize()
    local paneWidth = tonumber(imgui.get_window_size().x) or 0
    local textWidth = math.max(s * 8, paneWidth - s * 1.5)
    local roomy = paneWidth >= s * 26
    local buttonsFit = paneWidth >= s * 20

    imgui.text("Selected Item")
    imgui.separator()
    itemDatabaseWrapText("Name: " .. tostring(item and item.name or dash), textWidth)

    if roomy then
        if imgui.begin_table("ItemDatabaseSelectedSummary", 2, TABLE_RESIZABLE) then
            stretchColumn("Identity", 1.0, 501, true)
            stretchColumn("Stack", 1.0, 502, true)
            imgui.table_next_row()
            imgui.table_next_column()
            imgui.text("Item ID: " .. tostring(item and item.id or dash))
            itemDatabaseWrapText("Kind: " .. tostring(item and core.describeItem(item) or dash), math.max(s * 8, paneWidth * 0.46))
            imgui.table_next_column()
            imgui.text("Vanilla: " .. tostring(item and item.vanillaStackNum or dash))
            imgui.text("Runtime: " .. tostring(item and item.runtimeStackNum or dash))
            imgui.text("Effective: " .. tostring(item and core.getStackDisplay(item) or dash))
            imgui.end_table()
        end
    else
        imgui.text("Item ID: " .. tostring(item and item.id or dash))
        itemDatabaseWrapText("Kind: " .. tostring(item and core.describeItem(item) or dash), textWidth)
        imgui.text("Vanilla: " .. tostring(item and item.vanillaStackNum or dash))
        imgui.text("Runtime: " .. tostring(item and item.runtimeStackNum or dash))
        imgui.text("Effective: " .. tostring(item and core.getStackDisplay(item) or dash))
    end

    imgui.separator()
    imgui.text("Add Item")
    itemDatabaseWrapText(
        "Creates new item instances. Back up your save before spawning unreached quest/story items.",
        textWidth)

    local changed
    changed, addAmount = imgui.drag_int("Quantity##ItemDatabaseAdd", addAmount, 1, 1, 999999)
    if changed then addAmount = math.max(1, math.floor(tonumber(addAmount) or 1)) end

    if imgui.button("Add to Player##ItemDatabaseAddPlayer") then
        queueCatalogAdd(item, addAmount, "Player")
    end
    if buttonsFit then imgui.same_line() end
    if imgui.button("Add to Storage##ItemDatabaseAddStorage") then
        queueCatalogAdd(item, addAmount, "Storage")
    end

    if catalogStatus ~= "" then itemDatabaseWrapText(catalogStatus, textWidth) end

    imgui.separator()
    imgui.text("Item Database")
    itemDatabaseWrapText(string.format(
        "%d records | %d named | %d Invalid",
        stats.parsed or 0,
        stats.valid or 0,
        stats.invalid or 0), textWidth)
    local dbLabel = stats.ready and "Rebuild Item Database" or "Load Item Database"
    if imgui.button(dbLabel .. "##ItemDatabase") then
        local wasReady = core.catalogReady == true
        local ok = core.ensureCatalog(stats.ready)
        if ok then
            if not wasReady and core.stack.enabled then core.reapplyConfiguredStacks() end
            rebuildPawnRuleFilter(false)
            rebuildPlayerRuleFilter(false)
            rebuildCatalogFilter(false)
            rebuildStackFilter(false)
            local readyStats = core.getCatalogStats()
            catalogStatus = string.format(
                "Item Database ready: %d named / %d Invalid.",
                readyStats.valid,
                readyStats.invalid)
        else
            catalogStatus = tostring(core.lastError or "Item Database is not ready in the current game state.")
        end
    end
end

local function drawCatalogPage(options)
    options = options or {}
    if not core.catalogReady then
        local stats = core.getCatalogStats()
        imgui.text("Item Database cache is not loaded.")
        if imgui.button((stats.ready and "Rebuild Item Database" or "Load Item Database") .. "##ItemDatabaseInitial") then
            local ok = core.ensureCatalog(stats.ready)
            if ok then
                rebuildPawnRuleFilter(false)
                rebuildPlayerRuleFilter(false)
                rebuildCatalogFilter(false)
                rebuildStackFilter(false)
            end
        end
        if not core.catalogReady then return end
    end

    local s = core.getUiFontSize()
    local windowSize = imgui.get_window_size()
    local workspaceHeight = remainingWorkspaceHeight()
    local windowWidth = tonumber(windowSize.x) or 0

    -- Item Database gets its own responsive bands. The middle band keeps the
    -- working side-by-side layout but gives the detail pane more room; only
    -- genuinely narrow windows stack the panes vertically.
    local widthClass = 1
    if windowWidth >= s * 52 then
        widthClass = 3
    elseif windowWidth >= s * 38 then
        widthClass = 2
    end

    local split = widthClass >= 2
    local listWeight = tonumber(options.listWeight) or 1.65
    local detailWeight = tonumber(options.detailWeight) or 1.0
    if widthClass == 2 then
        listWeight = math.min(listWeight, 1.35)
    end
    local listOnRight = options.listSide == "right"
    local measuredListHeaderHeight = nil

    local function drawListColumn()
        if imgui.begin_child_window("ItemDatabaseListPane", Vector2f.new(0, workspaceHeight), false) then
            measuredListHeaderHeight = drawItemDatabaseListPane()
        end
        imgui.end_child_window()
    end

    local function drawDetailColumn()
        -- In the normal side-by-side layout, start the Selected Item box flush
        -- with the item-list box. The blank area above it mirrors the list's
        -- search/paging header and gives the right side some breathing room.
        local topOffset = tonumber(measuredListHeaderHeight) or (s * 3.35)
        topOffset = math.max(0, math.min(topOffset, workspaceHeight - s * 8))

        if topOffset > 0 then
            if imgui.begin_child_window(
                "ItemDatabaseDetailTopSpacer",
                Vector2f.new(0, topOffset),
                false) then
                -- Deliberately empty. This is layout space, not a visible panel.
            end
            imgui.end_child_window()
        end

        local detailHeight = math.max(s * 8, workspaceHeight - topOffset - s * 0.35)
        if imgui.begin_child_window(
            "ItemDatabaseDetailPane",
            Vector2f.new(0, detailHeight),
            true) then
            drawItemDatabaseDetailPane()
        end
        imgui.end_child_window()
    end

    if split then
        if imgui.begin_table("ItemDatabaseWorkspaceSplit", 2, TABLE_RESIZABLE) then
            if listOnRight then
                stretchColumn("Details", detailWeight, 512, true)
                stretchColumn("Items", listWeight, 511, true)
            else
                stretchColumn("Items", listWeight, 511, true)
                stretchColumn("Details", detailWeight, 512, true)
            end
            imgui.table_next_row()
            imgui.table_next_column()
            if listOnRight then drawDetailColumn() else drawListColumn() end
            imgui.table_next_column()
            if listOnRight then drawListColumn() else drawDetailColumn() end
            imgui.end_table()
        end
        return
    end

    -- On genuinely narrow windows, preserve the existing vertical fallback.
    local listHeight = math.max(s * 10, workspaceHeight * 0.62)
    local detailHeight = math.max(s * 8, workspaceHeight - listHeight - s * 0.75)
    if imgui.begin_child_window("ItemDatabaseListPaneNarrow", Vector2f.new(0, listHeight), false) then
        drawItemDatabaseListPane()
    end
    imgui.end_child_window()
    if imgui.begin_child_window(
        "ItemDatabaseDetailPaneNarrow",
        Vector2f.new(0, detailHeight),
        true) then
        drawItemDatabaseDetailPane()
    end
    imgui.end_child_window()
end

local STACK_SOFT_CAP = tonumber(core.STACK_SOFT_CAP) or 10000
local STACK_HARD_CAP = tonumber(core.STACK_HARD_CAP) or 32000
local STACK_WARNING_ORANGE = 0xFF00A5FF
local STACK_WARNING_RED = 0xFF0000FF

local function drawStackLimitWarning(label, value)
    value = tonumber(value) or 0
    if value >= STACK_HARD_CAP then
        imgui.text_colored(string.format("%s hard cap reached: %d", label, STACK_HARD_CAP), STACK_WARNING_RED)
    elseif value > STACK_SOFT_CAP then
        imgui.text_colored(string.format("%s is above the recommended soft cap (%d). Use with caution.", label, STACK_SOFT_CAP), STACK_WARNING_ORANGE)
    end
end

local function drawStackOverrideControls(idSuffix)
    idSuffix = tostring(idSuffix or "")

    imgui.text("Global uses DD2's native _StackNum. Scoped mode resolves Player/Pawn vs Storage through getStackNum(owner).")
    imgui.text(string.format(
        "Mode: %s | Captured vanilla entries: %d | Last applied: %d",
        tostring(core.stack.mode or (core.stack.enabled and "Global" or "Vanilla")),
        core.stack.capturedCount or 0,
        core.stack.appliedCount or 0))

    local globalMode = core.stack.mode == "Global"
    local changed, value = imgui.checkbox("Global override" .. idSuffix, globalMode)
    if changed then
        core.setStackMode(value and "Global" or "Scoped")
        globalMode = value
    end

    if globalMode then
        changed, stackLimit = imgui.drag_int(
            "Global limit" .. idSuffix,
            stackLimit or core.stack.globalLimit or 9999,
            1,
            1,
            STACK_HARD_CAP)
        if changed then core.setPendingStackLimit(stackLimit) end
        drawStackLimitWarning("Global stack", stackLimit)
        imgui.text("Global mutates DD2's native _StackNum and applies to both actor and storage resolution.")
    else
        local actorEnabled = core.stack.actorEnabled == true
        changed, value = imgui.checkbox("Player / Pawn override" .. idSuffix, actorEnabled)
        if changed then
            core.setActorStackOverrideEnabled(value)
            actorEnabled = value
        end
        if actorEnabled then
            changed, actorStackLimit = imgui.drag_int(
                "Player / Pawn limit" .. idSuffix,
                actorStackLimit or core.stack.actorLimit or 99,
                1,
                1,
                STACK_HARD_CAP)
            if changed then core.setPendingActorStackLimit(actorStackLimit) end
            drawStackLimitWarning("Player / Pawn stack", actorStackLimit)
        else
            imgui.text("Player / Pawn: captured vanilla _StackNum values.")
        end

        local storageEnabled = core.stack.storageEnabled == true
        changed, value = imgui.checkbox("Storage / Warehouse override" .. idSuffix, storageEnabled)
        if changed then
            core.setStorageStackOverrideEnabled(value)
            storageEnabled = value
        end
        if storageEnabled then
            changed, storageStackLimit = imgui.drag_int(
                "Storage / Warehouse limit" .. idSuffix,
                storageStackLimit or core.stack.storageLimit or 999,
                1,
                1,
                STACK_HARD_CAP)
            if changed then core.setPendingStorageStackLimit(storageStackLimit) end
            drawStackLimitWarning("Storage / Warehouse stack", storageStackLimit)
        else
            imgui.text("Storage / Warehouse: vanilla owner-aware getStackNum result.")
        end
    end

    if imgui.button("Apply Stack Configuration" .. idSuffix) then
        core.applyStackConfiguration()
        rebuildCatalogFilter(false)
        rebuildStackFilter(false)
    end
    imgui.same_line()
    if imgui.button("Restore Vanilla Stack Limits" .. idSuffix) then
        core.restoreVanillaStacks()
        rebuildCatalogFilter(false)
        rebuildStackFilter(false)
    end
    imgui.same_line()
    if imgui.button("Refresh Runtime Values" .. idSuffix) then
        core.refreshRuntimeStacks()
        rebuildCatalogFilter(false)
        rebuildStackFilter(false)
    end
end


local function drawAutomationPage()
    imgui.text("Automation")
    imgui.separator()
    imgui.text("Choose which inventory automation rules to edit. Player and Pawn rules are independent.")

    local playerLabel = automationScope == "Player" and "[Player -> Storage]" or "Player -> Storage"
    local pawnLabel = automationScope == "Pawns" and "[Pawns]" or "Pawns"
    if imgui.button(playerLabel .. "##AutomationScopePlayer") then
        automationScope = "Player"
    end
    imgui.same_line()
    if imgui.button(pawnLabel .. "##AutomationScopePawns") then
        automationScope = "Pawns"
    end

    if automationScope == "Player" then
        drawPlayerAutomationPage({ listWeight = 1.55, detailWeight = 1.0 })
    else
        drawPawnsPage({ listWeight = 1.55, detailWeight = 1.0 })
    end
end


local function drawSettingsPage()
    imgui.text("Settings")
    imgui.separator()
    imgui.text("Stack Limits")
    drawStackOverrideControls("##Settings")
    imgui.text("Preferred override values are retained when Vanilla mode is restored.")
    imgui.text("Scoped Player/Pawn and Storage/Warehouse limits are returned from DD2 getStackNum(owner) without mutating WarehouseMaxStackNum.")
    imgui.text("DD2 getStackNum(owner) remains the effective-capacity resolver. Native no-stack items and Gold are excluded.")

    imgui.separator()
    imgui.text("Transfer Method")
    local transferMode = core.getTransferMode()
    local nativeLabel = transferMode == "Native" and "[Native passItem]" or "Native passItem"
    local recreateLabel = transferMode == "Recreate" and "[Delete + recreate]" or "Delete + recreate"
    if imgui.button(nativeLabel .. "##TransferModeNative") then
        transferMode = core.setTransferMode("Native")
    end
    imgui.same_line()
    if imgui.button(recreateLabel .. "##TransferModeRecreate") then
        transferMode = core.setTransferMode("Recreate")
    end
    if transferMode == "Native" then
        imgui.text("Default: DD2 passItem transfers the exact live StorageData record and preserves native transfer bookkeeping/decay state.")
    else
        imgui.text("Compatibility mode: removes quantity then recreates it at the destination. This can reset decay metadata and is not used as an automatic fallback.")
    end

    imgui.separator()
    imgui.text("Live Inventory")
    if imgui.button("Force Refresh Live Inventory##Settings") then
        refreshInventoryWorkspace()
        lastNativeRefreshReason = "manual force refresh"
    end
    imgui.same_line()
    imgui.text("Auto-refresh: native storage/equip/party events")
end


local function drawDiagnosticsPage()
    imgui.text("Runtime/API diagnostics. Resolution occurs only when this page or a native StorageData transfer requests it.")

    if imgui.tree_node("Item DB Cache") then
        imgui.text("Lifecycle: complete static Item DB is cached at startup/main menu; live Player/Storage/Pawn inventories require a loaded save.")
        local stats = core.getCatalogStats()
        imgui.text(string.format(
            "Ready: %s | Enumerated: %d | Parsed: %d | Named: %d | Invalid: %d",
            stats.ready and "YES" or "NO",
            stats.enumerated,
            stats.parsed,
            stats.valid,
            stats.invalid))
        imgui.text(string.format(
            "Duplicate IDs: %d | Dictionary-key/_Id mismatches: %d | Parse errors: %d",
            stats.duplicateIds,
            stats.idMismatches,
            stats.parseErrors))

        local diagDbLabel = stats.ready
            and "Force Rebuild Item DB Cache##Diagnostics"
            or "Load Item DB Cache##Diagnostics"
        if imgui.button(diagDbLabel) then
            local ok = core.ensureCatalog(stats.ready)
            if ok then
                rebuildPawnRuleFilter(false)
                rebuildPlayerRuleFilter(false)
                rebuildCatalogFilter(false)
                rebuildStackFilter(false)
            end
        end

        if #(core.catalogInvalid or {}) > 0 then
            imgui.text("Invalid records are cached for Debug inspection but excluded from normal Catalog/live scans.")
        end
        imgui.tree_pop()
    end

    if imgui.tree_node("Runtime Status") then
        imgui.text("Core status: " .. tostring(core.status or ""))
        local mutationStatus = core.getMutationStatus()
        if mutationStatus.busy then
            if mutationStatus.total and mutationStatus.total > 1 then
                imgui.text(string.format(
                    "Mutation queue: %s (%d/%d)",
                    tostring(mutationStatus.label or "work"),
                    tonumber(mutationStatus.index) or 0,
                    tonumber(mutationStatus.total) or 0))
            else
                imgui.text("Mutation queue: " .. tostring(mutationStatus.label or "working"))
            end
        else
            imgui.text("Mutation queue: idle")
        end
        if core.lastError then
            imgui.text("Last error: " .. tostring(core.lastError))
        else
            imgui.text("Last error: none")
        end
        imgui.tree_pop()
    end

    if imgui.tree_node("UI State") then
        imgui.text(string.format(
            "Page: %s | Rows/Page: %d",
            tostring(activePage),
            tonumber(core.ui.rowsPerPage) or 40))
        imgui.text(string.format(
            "Player: page %d | filtered %d | selected %d | search '%s'",
            pageIndex.Player or 1,
            #(filtered.Player or {}),
            selectionCount("Player"),
            tostring(search.Player or "")))
        imgui.text(string.format(
            "Pawn tabs: Main %d | A %d | B %d",
            #(filtered.MainPawn or {}), #(filtered.PawnA or {}), #(filtered.PawnB or {})))
        imgui.text(string.format(
            "Storage: page %d | filtered %d | selected %d | search '%s'",
            pageIndex.Storage or 1,
            #(filtered.Storage or {}),
            selectionCount("Storage"),
            tostring(search.Storage or "")))
        imgui.text(string.format(
            "Catalog: page %d | filtered %d | search '%s' | Stack: page %d | filtered %d | search '%s'",
            pageIndex.Catalog or 1,
            #(filtered.Catalog or {}),
            tostring(search.Catalog or ""),
            pageIndex.Stack or 1,
            #(filtered.Stack or {}),
            tostring(search.Stack or "")))
        imgui.tree_pop()
    end
    imgui.text(string.format("Mutation worker: direct REFramework UpdateBehavior; Active-UI independent; %d mutation steps/update.",
        core.getMutationStepsPerUpdate()))
    local transfer = core.getNativeTransferStatus()
    imgui.text("Fungible transfer mode: " .. tostring(core.getTransferMode()))
    imgui.text("StorageData transfer API: " .. tostring(transfer.reason or "?"))
    if imgui.button("Resolve StorageData Transfer API") then
        core.resolveNativeEquipmentTransfer(true)
        transfer = core.getNativeTransferStatus()
    end
    imgui.same_line()
    if imgui.button("Build Inventory API Report") then
        core.buildApiReport()
    end
    imgui.text("Output: reframework/data/InventoryManager_API.txt")
    if #(core.apiReport or {}) > 0 then
        imgui.separator()
        imgui.text("Matching runtime methods/fields:")
        imgui.begin_child_window("ApiReport", Vector2f.new(0, 0), true, HORIZONTAL_SCROLLBAR)
        for _, line in ipairs(core.apiReport) do imgui.text(line) end
        imgui.end_child_window()
    end
end


function window.drawDiagnosticsWorkspace()
    initializeUiState()
    drawDiagnosticsPage()
end

function window.drawSettingsWorkspace()
    initializeUiState()
    drawSettingsPage()
end


function window.draw()
    if not isOpen or not window.isRefUiOpen() then return end

    flushPendingRefreshes()
    initializeUiState()
    window.ensureLiveInventoryReady()

    local fontPush = core.pushUiFont()
    local s = core.getUiFontSize()
    imgui.set_next_window_size(Vector2f.new(s * 82, s * 46), FIRST_USE_EVER)

    local stillOpen = imgui.begin_window(
        "Inventory Manager v" .. tostring(core.VERSION or "?") .. "###InventoryManagerWindow",
        true,
        0)
    if not stillOpen then
        imgui.end_window()
        window.setOpen(false)
        core.popUiFont(fontPush)
        return
    end

    imgui.text(inventoryRefreshText)
    imgui.text("Multi-select: Click = one | Ctrl+Click = toggle | Shift+Click = range | Ctrl+Shift+Click = add range.")

    drawControlsNav()

    if isLiveInventoryPage(activePage) then
        drawInventorySubNav()
        drawInventoryPage(activePage, {
            listWeight = 1.65,
            detailWeight = 1.0,
            role = inventoryRole(activePage),
        })
    elseif activePage == "Automation" then
        drawAutomationPage()
    elseif activePage == "Item Database" then
        drawCatalogPage({ listWeight = 1.65, detailWeight = 1.0 })
    elseif activePage == "Settings" then
        drawSettingsPage()
    else
        activePage = "Player"
        lastInventoryPage = "Player"
        drawInventorySubNav()
        drawInventoryPage("Player", { listWeight = 1.65, detailWeight = 1.0, role = "Player" })
    end

    imgui.end_window()
    core.popUiFont(fontPush)
end

return window
