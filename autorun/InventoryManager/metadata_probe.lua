-- Optional Item Analysis helper for Inventory Manager.
-- Read-only: this module never mutates inventories or ItemCommonParam fields.
-- It owns its own cache so the normalized production UI never depends on it.

local probe = {}

local REPORT_PATH = "InventoryManager_ItemMetadataProbe.txt"
local CSV_PATH = "InventoryManager_ItemMetadataProbe.csv"

local ItemManagerType = sdk.find_type_definition("app.ItemManager")
local ItemCommonParamType = sdk.find_type_definition("app.ItemCommonParam")
local isNoStacItemMethod = ItemManagerType
    and ItemManagerType:get_method("isNoStacItem(app.ItemCommonParam)") or nil
local rawStackNumField = ItemCommonParamType
    and ItemCommonParamType:get_field("_StackNum") or nil
local decayedItemIdField = ItemCommonParamType
    and ItemCommonParamType:get_field("_DecayedItemId") or nil
local warehouseMaxStackNumField = ItemCommonParamType
    and ItemCommonParamType:get_field("WarehouseMaxStackNum") or nil

probe.records = {}
probe.byId = {}
probe.categories = {}
probe.stats = {
    enumerated = 0,
    parsed = 0,
    parseErrors = 0,
    idMismatches = 0,
    duplicateIds = 0,
    categories = 0,
    buckets = 0,
    nativeNoStackTrue = 0,
    nativeNoStackFalse = 0,
    nativeNoStackUnknown = 0,
    noStackStackMismatch = 0,
}
probe.status = "Metadata probe has not been run yet."
probe.generation = 0

local function safe_call(fn, fallback)
    local ok, value = pcall(fn)
    if ok then return value end
    return fallback
end

local function safe_field(obj, fieldName, fallback)
    if obj == nil then return fallback end
    local value = safe_call(function() return obj:get_field(fieldName) end, nil)
    if value ~= nil then return value end
    return fallback
end

local function read_tdb_field(field, obj, fallbackName)
    if field then
        local isStatic = safe_call(function() return field:is_static() == true end, false)
        local value = safe_call(function() return field:get_data(isStatic and nil or obj) end, nil)
        if value ~= nil then return value end
    end
    return safe_field(obj, fallbackName, nil)
end

local function safe_number(value)
    if value == nil then return nil end
    return safe_call(function() return tonumber(value) end, nil)
end

local function type_name(obj)
    if obj == nil then return nil end
    local td = safe_call(function() return obj:get_type_definition() end, nil)
    if not td then return nil end
    return safe_call(function() return td:get_full_name() end,
        safe_call(function() return td:get_name() end, nil))
end

local function item_name(param, id)
    local name = safe_call(function() return param:get_Name() end, nil)
    if name ~= nil then
        name = tostring(name)
        if name ~= "" then return name end
    end
    return "Item " .. tostring(id or "?")
end

local function get_item_manager()
    return safe_call(function() return sdk.get_managed_singleton("app.ItemManager") end, nil)
end

local NIL_KEY = "<nil>"
local function raw_key(value)
    if value == nil then return NIL_KEY end
    return tostring(value)
end

local function increment(tbl, key)
    key = raw_key(key)
    tbl[key] = (tbl[key] or 0) + 1
end

local function collect_records()
    local im = get_item_manager()
    if not im then return nil, "app.ItemManager is not ready." end

    local dict = safe_call(function() return im:get_ItemDataDict() end, nil)
    if not dict then dict = safe_field(im, "_ItemDataDict", nil) end
    if not dict then return nil, "Could not resolve app.ItemManager ItemDataDict." end

    local entries = safe_field(dict, "_entries", nil)
    if not entries then return nil, "ItemDataDict backing entries are unavailable." end

    local records = {}
    local stats = {
        enumerated = 0,
        parsed = 0,
        parseErrors = 0,
        idMismatches = 0,
        duplicateIds = 0,
        categories = 0,
        buckets = 0,
        nativeNoStackTrue = 0,
        nativeNoStackFalse = 0,
        nativeNoStackUnknown = 0,
        noStackStackMismatch = 0,
    }
    local seenIds = {}

    for _, slot in pairs(entries) do
        local param = slot and safe_field(slot, "value", nil) or nil
        if param then
            stats.enumerated = stats.enumerated + 1
            local ok, record = pcall(function()
                local canonicalId = safe_number(safe_field(slot, "key", nil))
                local paramId = safe_number(safe_field(param, "_Id", nil))
                if paramId == nil then
                    paramId = safe_call(function() return tonumber(param:get_ItemId()) end, nil)
                end

                local id = canonicalId or paramId
                if id == nil then return nil end
                id = math.floor(id)

                return {
                    id = id,
                    paramId = paramId,
                    name = item_name(param, id),
                    category = safe_number(safe_field(param, "_Category", nil)),
                    subCategory = safe_number(safe_field(param, "_SubCategory", nil)),
                    equipCategory = safe_number(safe_field(param, "_EquipCategory", nil)),
                    dataType = safe_number(safe_field(param, "<DataType>k__BackingField", nil)),
                    stackNum = safe_number(read_tdb_field(rawStackNumField, param, "_StackNum")),
                    decayedItemId = safe_number(read_tdb_field(decayedItemIdField, param, "_DecayedItemId")),
                    warehouseStackNum = safe_number(read_tdb_field(warehouseMaxStackNumField, param, "WarehouseMaxStackNum")),
                    nativeNoStack = isNoStacItemMethod and safe_call(function()
                        return isNoStacItemMethod:call(im, param) == true
                    end, nil) or nil,
                    weight = safe_number(safe_field(param, "_Weight", nil)),
                    useEffect = safe_number(safe_field(param, "_UseEffect", nil)),
                    healWhiteHp = safe_number(safe_field(param, "_HealWhiteHp", nil)),
                    healBlackHp = safe_number(safe_field(param, "_HealBlackHp", nil)),
                    healStamina = safe_number(safe_field(param, "_HealStamina", nil)),
                    removeStatus = safe_number(safe_field(param, "_RemoveStatus", nil)),
                    typeName = type_name(param),
                }
            end)

            if ok and record then
                stats.parsed = stats.parsed + 1
                if record.paramId ~= nil and tonumber(record.paramId) ~= tonumber(record.id) then
                    stats.idMismatches = stats.idMismatches + 1
                end
                if seenIds[record.id] then
                    stats.duplicateIds = stats.duplicateIds + 1
                else
                    seenIds[record.id] = true
                end
                if record.nativeNoStack == true then
                    stats.nativeNoStackTrue = stats.nativeNoStackTrue + 1
                elseif record.nativeNoStack == false then
                    stats.nativeNoStackFalse = stats.nativeNoStackFalse + 1
                else
                    stats.nativeNoStackUnknown = stats.nativeNoStackUnknown + 1
                end
                if record.nativeNoStack ~= nil and record.stackNum ~= nil then
                    local stackImpliesNoStack = tonumber(record.stackNum) <= 1
                    if stackImpliesNoStack ~= record.nativeNoStack then
                        stats.noStackStackMismatch = stats.noStackStackMismatch + 1
                    end
                end
                table.insert(records, record)
            else
                stats.parseErrors = stats.parseErrors + 1
            end
        end
    end

    table.sort(records, function(a, b)
        if a.id == b.id then return tostring(a.typeName or "") < tostring(b.typeName or "") end
        return a.id < b.id
    end)

    return records, stats
end

local function build_buckets(records)
    local categories = {}
    local categoryCount = 0
    local bucketCount = 0

    for _, record in ipairs(records or {}) do
        local catKey = raw_key(record.category)
        local subKey = raw_key(record.subCategory)
        local cat = categories[catKey]
        if not cat then
            cat = { count = 0, sub = {} }
            categories[catKey] = cat
            categoryCount = categoryCount + 1
        end
        cat.count = cat.count + 1

        local bucket = cat.sub[subKey]
        if not bucket then
            bucket = {
                count = 0,
                equipCounts = {},
                dataTypeCounts = {},
                typeCounts = {},
                stackCounts = {},
                warehouseStackCounts = {},
                decayedItemIdCounts = {},
                nativeNoStackCounts = {},
            }
            cat.sub[subKey] = bucket
            bucketCount = bucketCount + 1
        end

        bucket.count = bucket.count + 1
        increment(bucket.equipCounts, record.equipCategory)
        increment(bucket.dataTypeCounts, record.dataType)
        increment(bucket.typeCounts, record.typeName)
        increment(bucket.stackCounts, record.stackNum)
        increment(bucket.warehouseStackCounts, record.warehouseStackNum)
        increment(bucket.decayedItemIdCounts, record.decayedItemId)
        increment(bucket.nativeNoStackCounts, record.nativeNoStack)
    end

    return categories, categoryCount, bucketCount
end

function probe.rebuild()
    probe.status = "Reading DD2 ItemDataDict..."

    local ok, recordsOrError, stats = pcall(collect_records)
    if not ok then
        probe.status = "Probe failed: " .. tostring(recordsOrError)
        log.error("[InventoryManager Item Analysis] " .. probe.status)
        return false, probe.status
    end

    local records = recordsOrError
    if records == nil then
        probe.status = "Probe failed: " .. tostring(stats)
        log.error("[InventoryManager Item Analysis] " .. probe.status)
        return false, probe.status
    end

    local categories, categoryCount, bucketCount = build_buckets(records)
    local byId = {}
    for _, record in ipairs(records) do
        if byId[record.id] == nil then byId[record.id] = record end
    end

    stats.categories = categoryCount
    stats.buckets = bucketCount

    probe.records = records
    probe.byId = byId
    probe.categories = categories
    probe.stats = stats
    probe.generation = probe.generation + 1
    probe.status = string.format(
        "Probe ready: %d records, %d categories, %d category/subcategory buckets.",
        #records, categoryCount, bucketCount)
    log.info("[InventoryManager Item Analysis] " .. probe.status)
    return true
end

function probe.ensure()
    if probe.generation > 0 then return true end
    return probe.rebuild()
end

function probe.get(itemId)
    itemId = math.floor(tonumber(itemId) or -1)
    if itemId < 0 then return nil end
    return probe.byId[itemId]
end

function probe.getStats()
    return probe.stats
end

local function csv_escape(value)
    if value == nil then return "" end
    local s = tostring(value)
    if s:find('[,\"\r\n]') then s = '"' .. s:gsub('"', '""') .. '"' end
    return s
end

local function build_csv()
    local lines = {
        "ItemID,ParamID,Name,Category,SubCategory,EquipCategory,DataType,StackNum,DecayedItemId,WarehouseMaxStackNum,NativeNoStack,Weight,UseEffect,HealWhiteHp,HealBlackHp,HealStamina,RemoveStatus,TypeName"
    }
    for _, r in ipairs(probe.records or {}) do
        table.insert(lines, table.concat({
            csv_escape(r.id),
            csv_escape(r.paramId),
            csv_escape(r.name),
            csv_escape(r.category),
            csv_escape(r.subCategory),
            csv_escape(r.equipCategory),
            csv_escape(r.dataType),
            csv_escape(r.stackNum),
            csv_escape(r.decayedItemId),
            csv_escape(r.warehouseStackNum),
            csv_escape(r.nativeNoStack),
            csv_escape(r.weight),
            csv_escape(r.useEffect),
            csv_escape(r.healWhiteHp),
            csv_escape(r.healBlackHp),
            csv_escape(r.healStamina),
            csv_escape(r.removeStatus),
            csv_escape(r.typeName),
        }, ","))
    end
    return table.concat(lines, "\n") .. "\n"
end

local function sorted_keys(tbl)
    local keys = {}
    for key in pairs(tbl or {}) do table.insert(keys, key) end
    table.sort(keys, function(a, b)
        if a == NIL_KEY then return false end
        if b == NIL_KEY then return true end
        local an, bn = tonumber(a), tonumber(b)
        if an ~= nil and bn ~= nil then return an < bn end
        if an ~= nil then return true end
        if bn ~= nil then return false end
        return tostring(a) < tostring(b)
    end)
    return keys
end

local function counts_string(counts)
    local out = {}
    for _, key in ipairs(sorted_keys(counts)) do
        table.insert(out, tostring(key) .. "=" .. tostring(counts[key]))
    end
    return #out > 0 and table.concat(out, ", ") or "<none>"
end

local function build_text_report()
    local lines = {
        "Inventory Manager - Item Metadata Probe",
        "Read-only DD2 item metadata + native stack classification",
        "",
        "Records: " .. tostring(#(probe.records or {})),
        "Categories: " .. tostring(probe.stats.categories or 0),
        "Buckets: " .. tostring(probe.stats.buckets or 0),
        "Duplicate ItemIDs: " .. tostring(probe.stats.duplicateIds or 0),
        "ID mismatches: " .. tostring(probe.stats.idMismatches or 0),
        "Parse errors: " .. tostring(probe.stats.parseErrors or 0),
        "Native isNoStacItem true: " .. tostring(probe.stats.nativeNoStackTrue or 0),
        "Native isNoStacItem false: " .. tostring(probe.stats.nativeNoStackFalse or 0),
        "Native isNoStacItem unknown: " .. tostring(probe.stats.nativeNoStackUnknown or 0),
        "isNoStacItem vs _StackNum<=1 mismatches: " .. tostring(probe.stats.noStackStackMismatch or 0),
        "WarehouseMaxStackNum field static: " .. tostring(warehouseMaxStackNumField and safe_call(function() return warehouseMaxStackNumField:is_static() == true end, nil) or nil),
        "WarehouseMaxStackNum field literal: " .. tostring(warehouseMaxStackNumField and safe_call(function() return warehouseMaxStackNumField:is_literal() == true end, nil) or nil),
        "",
        "=== CATEGORY / SUBCATEGORY SUMMARY ===",
    }

    for _, catKey in ipairs(sorted_keys(probe.categories)) do
        local cat = probe.categories[catKey]
        table.insert(lines, "")
        table.insert(lines, string.format("Category %s : %d item(s)", catKey, cat.count))
        for _, subKey in ipairs(sorted_keys(cat.sub)) do
            local bucket = cat.sub[subKey]
            table.insert(lines, string.format(
                "  SubCategory %s : %d | Equip {%s} | DataType {%s} | Type {%s} | Stack {%s} | DecayedItemId {%s} | WarehouseStack {%s} | NoStac {%s}",
                subKey,
                bucket.count,
                counts_string(bucket.equipCounts),
                counts_string(bucket.dataTypeCounts),
                counts_string(bucket.typeCounts),
                counts_string(bucket.stackCounts),
                counts_string(bucket.decayedItemIdCounts),
                counts_string(bucket.warehouseStackCounts),
                counts_string(bucket.nativeNoStackCounts)))
        end
    end

    table.insert(lines, "")
    table.insert(lines, "=== ITEMS ===")
    for _, r in ipairs(probe.records or {}) do
        table.insert(lines, string.format(
            "%d | %s | ParamID=%s | Category=%s | SubCategory=%s | EquipCategory=%s | DataType=%s | Stack=%s | DecayedItemId=%s | WarehouseStack=%s | NativeNoStac=%s | Weight=%s | UseEffect=%s | HP=%s | MaxHP=%s | Stamina=%s | RemoveStatus=%s | %s",
            r.id,
            tostring(r.name),
            tostring(r.paramId),
            tostring(r.category),
            tostring(r.subCategory),
            tostring(r.equipCategory),
            tostring(r.dataType),
            tostring(r.stackNum),
            tostring(r.decayedItemId),
            tostring(r.warehouseStackNum),
            tostring(r.nativeNoStack),
            tostring(r.weight),
            tostring(r.useEffect),
            tostring(r.healWhiteHp),
            tostring(r.healBlackHp),
            tostring(r.healStamina),
            tostring(r.removeStatus),
            tostring(r.typeName)))
    end
    table.insert(lines, "")
    return table.concat(lines, "\n")
end

local function write_file(path, contents)
    local ok, err = pcall(function()
        local f = assert(io.open(path, "w"))
        f:write(contents)
        f:close()
    end)
    if ok then return true end
    return false, tostring(err)
end

function probe.exportCSV()
    if probe.generation == 0 then
        local ok, err = probe.rebuild()
        if not ok then return false, err end
    end
    local ok, err = write_file(CSV_PATH, build_csv())
    if ok then
        probe.status = "CSV written to reframework/data/" .. CSV_PATH
        return true, probe.status
    end
    probe.status = "CSV export failed: " .. tostring(err)
    return false, probe.status
end

function probe.exportTXT()
    if probe.generation == 0 then
        local ok, err = probe.rebuild()
        if not ok then return false, err end
    end
    local ok, err = write_file(REPORT_PATH, build_text_report())
    if ok then
        probe.status = "TXT written to reframework/data/" .. REPORT_PATH
        return true, probe.status
    end
    probe.status = "TXT export failed: " .. tostring(err)
    return false, probe.status
end

return probe
