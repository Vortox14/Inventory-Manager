-- Inventory Manager item catalog, classification, and automation-rule definitions.
-- Static item interpretation lives here so core.lua can retain local-variable headroom.

local M = {}
local native = require("InventoryManager/NativeBindings")

function M.attach(core)
    if type(core) ~= "table" then
        error("[InventoryManager] CatalogLogic.attach requires core table.")
    end
    if core._catalogLogicAttached then return core end
    core._catalogLogicAttached = true

    local S = assert(core._catalogServices, "InventoryManager catalog services are unavailable")

    local function item_id_from_param(param)
        if not param then return nil end
        local id = tonumber(S.safeField(param, "_Id", nil))
        if id ~= nil then return id end
        return S.safeCall(function() return tonumber(param:get_ItemId()) end, nil)
    end

    local function item_name_from_param(param, id)
        if not param then return "Item " .. tostring(id or "?") end
        local name = S.safeCall(function() return param:get_Name() end, nil)
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

        local typeName = S.safeFullTypeName(param)
        local dataType = tonumber(S.safeField(param, "<DataType>k__BackingField", nil))
        local category = tonumber(S.safeField(param, "_Category", nil))
        local subCategory = tonumber(S.safeField(param, "_SubCategory", nil))
        local equipCategory = tonumber(S.safeField(param, "_EquipCategory", nil))
        local weight = tonumber(S.safeField(param, "_Weight", nil))
        local stackNum = S.readRawStackNum(param)
        local defaultStackNum = native.getDefaultStackNumMethod and S.safeCall(function()
            return tonumber(native.getDefaultStackNumMethod:call(param))
        end, nil) or nil
        local warehouseStackNum = S.readWarehouseMaxStack(param)

        -- getDefaultStackNum() mirrors _StackNum at the time of the call. Capture it
        -- before this mod changes anything and retain that snapshot for restoration.
        local vanillaCapture = defaultStackNum or stackNum
        if core.stack.vanillaById[id] == nil and vanillaCapture ~= nil then
            core.stack.vanillaById[id] = vanillaCapture
            core.stack.capturedCount = core.stack.capturedCount + 1
        end

        if core.stack.warehouseFieldStatic == nil and native.warehouseMaxStackNumField then
            core.stack.warehouseFieldStatic = S.fieldFlag(native.warehouseMaxStackNumField, "is_static") == true
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
            nativeNoStack = S.readNativeNoStack(param)
            if nativeNoStack ~= nil then
                core.stack.nativeNoStackById[id] = nativeNoStack
            end
        end

        local vanillaStackNum = core.stack.vanillaById[id] or stackNum
        local vanillaWarehouseStackNum = core.stack.warehouseFieldStatic == true
            and core.stack.warehouseVanillaGlobal
            or core.stack.warehouseVanillaById[id]
            or warehouseStackNum
        local useEffect = tonumber(S.safeField(param, "_UseEffect", nil))
        local healWhiteHp = tonumber(S.safeField(param, "_HealWhiteHp", nil)) or 0
        local healBlackHp = tonumber(S.safeField(param, "_HealBlackHp", nil)) or 0
        local healStamina = tonumber(S.safeField(param, "_HealStamina", nil)) or 0
        local removeStatus = tonumber(S.safeField(param, "_RemoveStatus", nil)) or 0

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
        local isDecay = S.isDecayItem(id)

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
            isLantern = native.LANTERN_IDS[id] == true,
            isLanternFuel = id == native.LANTERN_FUEL_ID,
            isCurrency = id == native.GOLD_ID,
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
                and item.id ~= native.WAKESHARD_ID
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
            if not quiet then S.setError(message) end
            return false
        end

        local im = S.getItemManager()
        if not im then
            return catalog_fail("app.ItemManager is not ready; Item DB cache was not changed.")
        end

        local dict = S.safeCall(function() return im:get_ItemDataDict() end, nil)
        if not dict then dict = S.safeField(im, "_ItemDataDict", nil) end
        if not dict then
            return catalog_fail("Could not resolve ItemManager item-data dictionary; previous Item DB cache was preserved.")
        end

        -- The probe confirmed Dictionary enumeration works. We still traverse the
        -- backing entries directly because the dictionary key is immediately
        -- available as the canonical ItemID for each cached ItemDataParam.
        local entries = S.safeField(dict, "_entries", nil)
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
            local param = slot and S.safeField(slot, "value", nil) or nil
            if param then
                stats.enumerated = stats.enumerated + 1
                local canonicalId = tonumber(S.safeField(slot, "key", nil))
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
            S.setStatus(string.format(
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
        S.saveConfig()
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
            S.saveConfig()
            core.pawnCleaner.baseline = nil
        end
        return true, nil, changed
    end

    function core.clearPawnCleanerOverrides()
        core.pawnCleaner.overrides = {}
        S.saveConfig()
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
        S.saveConfig()
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
        S.saveConfig()
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
        S.saveConfig()
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
            S.saveConfig()
            core.playerCleaner.baseline = nil
        end
        return true, nil, changed
    end

    function core.clearPlayerCleanerOverrides()
        core.playerCleaner.overrides = {}
        S.saveConfig()
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
        S.saveConfig()
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
        return tonumber(S.safeField(value, "value__", nil))
    end

    local function info_field(obj, name)
        if obj == nil then return nil end
        local value = S.safeField(obj, name, nil)
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
            typeName = item.typeName or (param and S.safeFullTypeName(param)) or "?",
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
            local row = S.getStorageMasterRow(itemId, ownerId, storageId)
            if row then
                local nested = S.getStorageMasterParam(row)
                local enhance = S.safeCall(function()
                    return native.getMasterEnhanceMethod and native.getMasterEnhanceMethod:call(row) or nil
                end, nil)
                if enhance == nil and nested ~= nil then enhance = S.safeField(nested, "_Enhance", nil) end
                local enhanceNum = S.safeCall(function()
                    return native.getMasterEnhanceNumMethod and tonumber(native.getMasterEnhanceNumMethod:call(row)) or nil
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

                local ability = S.safeCall(function()
                    return native.getMasterAbilityMethod and native.getMasterAbilityMethod:call(row) or nil
                end, nil)
                if ability == nil and nested ~= nil then ability = S.safeField(nested, "_Ability", nil) end
                local abilityNum = S.safeCall(function()
                    return native.getMasterAbilityNumMethod and tonumber(native.getMasterAbilityNumMethod:call(row)) or nil
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


    core._catalogItemIdFromParam = item_id_from_param
    return core
end

return M
