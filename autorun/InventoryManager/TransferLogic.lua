-- Inventory Manager automation transfer controller.
--
-- This module owns Inventory Manager transfer mechanics plus Player/Pawn
-- automation orchestration. core.lua supplies shared state/mutation services;
-- native reflection lives in NativeBindings.lua and catalog/rule interpretation
-- lives in CatalogLogic.lua.
--
-- Safety model:
--   * every queued job freezes its own item/owner/amount values;
--   * Pawn jobs carry a party-generation token captured from live owner IDs;
--   * execution refreshes the live party before touching inventory;
--   * stale jobs are skipped rather than mutating a replacement/dismissed Pawn;
--   * equipped quantities are rechecked immediately before each transfer.

local M = {}
local native = require("InventoryManager/NativeBindings")

function M.attach(core)
    if type(core) ~= "table" then
        error("[InventoryManager] TransferLogic.attach requires core table.")
    end
    if core._transferLogicAttached then return core end
    core._transferLogicAttached = true

    local STORAGE_ID = tonumber(core.STORAGE_ID) or 65535
    local WAKESHARD_ID = tonumber(core.WAKESHARD_ID) or 78

    local runtime = {
        partyGeneration = 0,
        partySignature = nil,
        nextOperationId = 0,
    }
    core.transferLogic = runtime

    local S = assert(core._transferServices, "InventoryManager transfer services are unavailable")

    local function storage_data_item_id(storageData)
        if not storageData then return nil end
        local id = tonumber(S.safeField(storageData, "_ItemId", nil))
        if id ~= nil then return id end
        local itemData = S.safeField(storageData, "_ItemData", nil)
        return S.itemIdFromParam(itemData)
    end

    local function storage_data_storage_id(storageData)
        if not storageData then return nil end
        return tonumber(S.safeField(storageData, "_StorageId", nil))
    end

    local function storage_data_chara_id(storageData)
        if not storageData then return nil end
        return tonumber(S.safeField(storageData, "_CharaId", nil))
    end

    local function storage_data_num(storageData)
        if not storageData then return nil end
        return tonumber(S.safeField(storageData, "_Num", nil))
    end

    local function equipped_storage_ids(ownerId)
        local ids = {}
        local im = S.getItemManager()
        if not im or ownerId == nil or ownerId == native.STORAGE_ID then return ids end

        local equipData = S.safeCall(function() return im:getEquipData(ownerId) end, nil)
        local equipList = equipData and S.safeCall(function() return equipData:get_EquipList() end, nil) or nil
        for i = 0, S.managedListCount(equipList) - 1 do
            local storageData = S.managedListAt(equipList, i)
            local storageId = storage_data_storage_id(storageData)
            if storageId ~= nil then ids[storageId] = true end
        end

        -- Lanterns are equipped through a separate ItemManager subsystem and do not
        -- set generic StorageData.IsEquipped. Include the native equipped-lantern
        -- StorageId so instance transfers cannot move the active lantern.
        if native.getEquipLanternStorageIdMethod then
            local lanternStorageId = S.safeCall(function()
                return tonumber(native.getEquipLanternStorageIdMethod:call(im, ownerId))
            end, nil)
            if lanternStorageId ~= nil and lanternStorageId >= 0 then
                ids[lanternStorageId] = true
            end
        end
        return ids
    end

    function core.getEquippedLanternStorageId(ownerId)
        if ownerId == nil or ownerId == native.STORAGE_ID or not native.getEquipLanternStorageIdMethod then return nil end
        local im = S.getItemManager()
        if not im then return nil end
        return S.safeCall(function() return tonumber(native.getEquipLanternStorageIdMethod:call(im, ownerId)) end, nil)
    end

    function core.isInstanceEquipped(itemId, storageId, ownerId)
        if ownerId == nil or ownerId == native.STORAGE_ID or storageId == nil then return false end
        storageId = tonumber(storageId)
        local row = S.getStorageMasterRow(tonumber(itemId), ownerId, storageId)
        if row and S.storageMasterRowIsEquipped(row) then return true end
        return equipped_storage_ids(ownerId)[storageId] == true
    end

    function core.getEquippedCount(ownerId, itemId)
        if ownerId == nil or ownerId == native.STORAGE_ID then return 0 end
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

        if not native.ItemManagerType then
            core.nativeTransfer.reason = "app.ItemManager type is unavailable."
            return false, core.nativeTransfer.reason
        end

        -- Resolve only the exact live TypeDB method reported by DD2.
        -- Do not heuristically score vaguely transfer-like names: equipment is
        -- instance-backed StorageData and guessing the wrong API could destroy state.
        local method = S.safeCall(function() return native.ItemManagerType:get_method(native.PASS_ITEM_SIGNATURE) end, nil)
        local noLock = S.safeCall(function() return native.ItemManagerType:get_method(native.PASS_ITEM_NOLOCK_SIGNATURE) end, nil)
        core.nativeTransfer.noLockMethod = noLock

        if not method then
            core.nativeTransfer.reason = "Exact ItemManager." .. native.PASS_ITEM_SIGNATURE .. " was not found in the current runtime."
            return false, core.nativeTransfer.reason
        end

        core.nativeTransfer.method = method
        core.nativeTransfer.signature = native.methodSignature(method)
        core.nativeTransfer.paramNames = native.methodParamNames(method)
        core.nativeTransfer.reason = "Resolved exact native API: " .. core.nativeTransfer.signature
        return true, core.nativeTransfer.reason
    end

    function core.getNativeTransferStatus()
        if not core.nativeTransfer.scanned then core.resolveNativeEquipmentTransfer(false) end
        return core.nativeTransfer
    end

    local function get_source_storage_data(itemId, sourceId)
        local im = S.getItemManager()
        if not im then return nil, "ItemManager not ready." end
        if not native.getStorageDataByIdMethod then
            return nil, "Exact ItemManager.getStorageData(System.Int32, app.CharacterID) method is unavailable."
        end

        local ok, storageData = pcall(function()
            return native.getStorageDataByIdMethod:call(im, itemId, sourceId)
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
        if actualSourceId ~= nil and native.characterIdHex32(actualSourceId) ~= native.characterIdHex32(sourceId) then
            return nil, string.format(
                "StorageData owner mismatch: expected %s (%s), got %s (%s).",
                tostring(sourceId), tostring(native.characterIdHex32(sourceId)),
                tostring(actualSourceId), tostring(native.characterIdHex32(actualSourceId)))
        end
        return storageData
    end


    function core._recreateAdd(itemManager, itemId, amount, ownerId)
        if ownerId == native.STORAGE_ID then
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
        if core.isDecayItem(itemId) then
            return core.removeItem(itemId, amount, ownerId)
        end

        if ownerId == native.STORAGE_ID then
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

        local im = S.getItemManager()
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
            S.tripMutationSafetyStop(reason)
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
                S.tripMutationSafetyStop(reason)
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
            S.tripMutationSafetyStop(reason)
            return false, reason
        end

        local destDelta = destAfter - destBefore
        if destDelta < 0 then
            local reason = string.format(
                "Destination recreation unexpectedly reduced destination quantity (item=%s before=%d after=%d); automatic rollback is unsafe.",
                tostring(itemId), destBefore, destAfter)
            S.tripMutationSafetyStop(reason)
            return false, reason
        end

        if destDelta > 0 then
            local cleanupOk, cleanupErr = core._recreateRemove(im, itemId, destDelta, destId)
            local cleanupCount = core.getCount(itemId, destId)
            if not cleanupOk or cleanupCount ~= destBefore then
                local reason = string.format(
                    "Destination recreation partially succeeded and cleanup failed (item=%s delta=%d before=%d after=%d cleanup_error=%s cleanup_count=%s).",
                    tostring(itemId), destDelta, destBefore, destAfter, tostring(cleanupErr), tostring(cleanupCount))
                S.tripMutationSafetyStop(reason)
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
        S.tripMutationSafetyStop(reason)
        return false, reason
    end


    local function call_native_storage_transfer(storageData, destId, amount)
        if core.nativeTransfer.sessionFaulted or core.mutations.safetyStopped then
            return false, "Native transfer circuit breaker is active: " .. tostring(core.nativeTransfer.sessionFaultReason or core.mutations.safetyStopReason or "previous native transfer fault")
        end

        local okResolve, resolveReason = core.resolveNativeEquipmentTransfer(false)
        if not okResolve then return false, resolveReason end

        local im = S.getItemManager()
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
        if not native.isPassEnableMethod then
            return false, "DD2 isPassEnable(StorageData, Boolean) is unavailable; refusing unsafe passItem call."
        end

        local guardOk, passAllowed = pcall(function()
            -- IL2CPP dump marks isPassEnable(in StorageData, Boolean) STATIC; the
            -- StorageData parameter is ByRef/In. REFramework therefore receives nil
            -- as the method instance and the live value as the declared parameter.
            return native.isPassEnableMethod:call(nil, storageData, core.nativeTransfer.boolValue == true)
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
            S.tripMutationSafetyStop(reason)
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
        if not native.getStorageDataByIdMethod then
            return nil, "Exact ItemManager.getStorageData(System.Int32, app.CharacterID) method is unavailable."
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

        local im = S.getItemManager()
        if not im then return nil, "ItemManager not ready." end
        -- StorageId is not assumed to be globally unique across inventories.
        -- Resolve the value-type record through DD2's owner-aware lookup, then use
        -- the StorageId from the live master row only as a verification key.
        local storageData = S.safeCall(function()
            return native.getStorageDataByIdMethod:call(im, itemId, sourceId)
        end, nil)
        if not storageData then
            return nil, string.format(
                "getStorageData(%d, %s) returned no StorageData.",
                itemId, tostring(sourceId))
        end

        local actualItemId = storage_data_item_id(storageData)
        local actualSourceId = storage_data_chara_id(storageData)
        local actualStorageId = storage_data_storage_id(storageData)
        local actualNum = math.floor(tonumber(storage_data_num(storageData)) or -1)
        if actualItemId ~= itemId then
            return nil, string.format("Exact StorageData ItemID mismatch: expected %d, got %s.", itemId, tostring(actualItemId))
        end
        if native.characterIdHex32(actualSourceId) ~= native.characterIdHex32(sourceId) then
            return nil, string.format(
                "Exact StorageData owner mismatch: expected %s (%s), got %s (%s).",
                tostring(sourceId), tostring(native.characterIdHex32(sourceId)),
                tostring(actualSourceId), tostring(native.characterIdHex32(actualSourceId)))
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

    local function transfer_native_stack(itemId, amount, sourceId, destId)
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
            S.tripMutationSafetyStop(reason)
            return false, reason
        end

        local expectedSource = sourceBefore - amount
        local expectedDest = destBefore + amount
        if sourceAfter ~= expectedSource or destAfter ~= expectedDest then
            local reason = string.format(
                "Native passItem returned an unexpected quantity delta (item=%s amount=%d source %d->%d expected=%d, destination %d->%d expected=%d).",
                tostring(itemId), amount, sourceBefore, sourceAfter, expectedSource, destBefore, destAfter, expectedDest)
            S.tripMutationSafetyStop(reason)
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

        local row = S.getStorageMasterRow(itemId, sourceId, storageId)
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
        if equippedIds[storageId] or S.storageMasterRowIsEquipped(row) then
            return false, string.format("Instance ID %d is equipped; refusing to transfer this instance.", storageId)
        end

        local im = S.getItemManager()
        if not im then return false, "ItemManager not ready." end

        -- The StorageMasterData row was resolved from the requested source owner
        -- and exact local StorageId. Use its inline StorageData value directly:
        -- StorageId can collide across different owners, so a global
        -- getStorageDataByStorageId(StorageId) lookup is not authoritative here.
        local storageData = S.getStorageMasterParam(row)
        if not storageData then
            storageData = S.safeField(row, "_Param", nil)
        end
        if not storageData then return false, "Could not resolve the source row's exact StorageData instance." end
        if storage_data_item_id(storageData) ~= itemId then
            return false, "Exact instance StorageData ItemID mismatch."
        end
        local actualCharaId = tonumber(S.safeField(storageData, "_CharaId", nil))
        local expectedCharaId = tonumber(sourceId)
        if actualCharaId ~= nil and expectedCharaId ~= nil
            and native.characterIdHex32(actualCharaId) ~= native.characterIdHex32(expectedCharaId) then
            return false, string.format(
                "Exact instance owner mismatch: expected CharaId %s (%s), got %s (%s).",
                tostring(expectedCharaId), tostring(native.characterIdHex32(expectedCharaId)),
                tostring(actualCharaId), tostring(native.characterIdHex32(actualCharaId)))
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

    local function transfer_equipment_instances(itemId, amount, sourceId, destId)
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
        if itemId == native.WAKESHARD_ID then
            return false, "Existing Wakestone Shards are protected by the transfer safeguard."
        end

        local safeAmount, capacityResult = S.capacityLimitedDestinationAmount(
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
            return core.transferStack(itemId, amount, playerId, native.STORAGE_ID)
        end
        return core.transferStack(itemId, amount, native.STORAGE_ID, playerId)
    end



        core._storageDataItemId = storage_data_item_id
        core._storageDataStorageId = storage_data_storage_id
        core._equippedStorageIds = equipped_storage_ids

    local function owner_hex(value)
        if type(core.characterIdHex) == "function" then
            return tostring(core.characterIdHex(value))
        end
        local n = math.floor(tonumber(value) or 0) % 4294967296
        return string.format("0x%08X", n)
    end

    local function same_owner(a, b)
        if a == nil or b == nil then return a == b end
        return owner_hex(a) == owner_hex(b)
    end

    local function next_operation_id()
        runtime.nextOperationId = runtime.nextOperationId + 1
        return runtime.nextOperationId
    end

    local function make_party_signature(party)
        local parts = {}
        for _, member in ipairs(party or {}) do
            local slot = tostring(member.slotKey or member.label or "?")
            local owner = member.id ~= nil and owner_hex(member.id) or "nil"
            parts[#parts + 1] = slot .. "=" .. owner
        end
        table.sort(parts)
        return table.concat(parts, "|")
    end

    local function refresh_party_generation()
        local party = core.refreshParty() or {}
        local signature = make_party_signature(party)
        if runtime.partySignature ~= signature then
            runtime.partySignature = signature
            runtime.partyGeneration = runtime.partyGeneration + 1
            core.debugLog(
                "Verbose",
                "Automation party generation advanced to %d (%s)",
                runtime.partyGeneration,
                signature ~= "" and signature or "empty")
        end
        return party, runtime.partyGeneration, signature
    end

    local function find_party_member(party, slotKey)
        for _, member in ipairs(party or {}) do
            if tostring(member.slotKey or "") == tostring(slotKey or "") then
                return member
            end
        end
        return nil
    end

    local function validate_pawn_job(expectedGeneration, slotKey, expectedOwner)
        local party, generation = refresh_party_generation()
        if generation ~= expectedGeneration then
            return false, string.format(
                "Skipped stale Pawn transfer: party changed after queueing (generation %d -> %d).",
                tonumber(expectedGeneration) or -1,
                tonumber(generation) or -1)
        end

        local member = find_party_member(party, slotKey)
        if not member or member.id == nil then
            return false, string.format(
                "Skipped stale Pawn transfer: %s is no longer present.",
                tostring(slotKey or "Pawn"))
        end
        if not same_owner(member.id, expectedOwner) then
            return false, string.format(
                "Skipped stale Pawn transfer: %s owner changed (%s -> %s).",
                tostring(slotKey or "Pawn"), owner_hex(expectedOwner), owner_hex(member.id))
        end
        return true, member
    end

    local function build_equipped_counts(ownerId)
        local counts = {}
        local rows = core.getInventoryRows(ownerId)
        if type(rows) ~= "table" then return counts end
        for _, row in ipairs(rows) do
            if row and row.isEquipped and row.item and row.item.id then
                local itemId = tonumber(row.item.id)
                local quantity = math.max(1, math.floor(tonumber(row.quantity) or 1))
                if itemId then counts[itemId] = (counts[itemId] or 0) + quantity end
            end
        end
        return counts
    end

    local function capture_pawn_inventory_state(updateSnapshot)
        if not core.ensureCatalog(false) then return nil, "Item DB cache is unavailable." end

        local party, generation, signature = refresh_party_generation()
        local pawnResults = {}
        for _, member in ipairs(party) do
            if member.slotKey ~= "Player" and member.id ~= nil then
                local counts, countErr = core.getInventoryCounts(member.id)
                if not counts then
                    return nil, string.format("%s inventory scan failed: %s", tostring(member.label or member.slotKey), tostring(countErr))
                end

                local equipCounts = build_equipped_counts(member.id)
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
                        rows[#rows + 1] = {
                            item = item,
                            quantity = count,
                            equipped = equipped,
                            keep = keep,
                            move = move,
                            reason = reason,
                            skipped = skipped,
                            skipReason = skipReason,
                            rule = rule,
                        }
                    end
                end

                table.sort(rows, function(a, b)
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
                    partyGeneration = generation,
                    partySignature = signature,
                }
            end
        end

        if updateSnapshot ~= false then core.snapshots.pawns = pawnResults end
        return pawnResults
    end

    local function set_public_error(message)
        core.lastError = tostring(message or "Unknown automation error.")
        core.status = "ERROR: " .. core.lastError
        pcall(function() log.error("[InventoryManager] " .. core.lastError) end)
    end

    function core.analyzePawns()
        local pawnResults, err = capture_pawn_inventory_state(true)
        if not pawnResults then
            set_public_error("Pawn inventory scan failed: " .. tostring(err))
            return false
        end
        core.lastError = nil
        core.status = "Pawn inventories refreshed from occupied StorageMasterList rows."
        return true
    end

    local function pawn_state_signature(state)
        local sig = {}
        for label, data in pairs(state or {}) do
            local counts = {}
            for itemId, quantity in pairs(data.counts or {}) do counts[itemId] = quantity end
            sig[label] = {
                memberId = data.member and data.member.id or nil,
                slotKey = data.member and data.member.slotKey or nil,
                partyGeneration = data.partyGeneration,
                counts = counts,
            }
        end
        return sig
    end

    local function queue_pawn_rule_cleanup(state, automatic)
        local jobs = {}
        local detected = 0
        local operationId = next_operation_id()

        for label, data in pairs(state or {}) do
            local baseline = core.pawnCleaner.baseline and core.pawnCleaner.baseline[label] or nil
            local member = data.member
            local memberId = member and member.id or nil
            local samePawn = baseline ~= nil
                and baseline.memberId ~= nil
                and same_owner(baseline.memberId, memberId)

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
                        if move > 0 and memberId ~= nil then
                            -- Freeze every value consumed by the deferred closure.
                            local frozenItemId = itemId
                            local frozenMove = move
                            local frozenKeep = keep
                            local frozenSourceId = memberId
                            local frozenSlotKey = member.slotKey
                            local frozenGeneration = data.partyGeneration or runtime.partyGeneration
                            local frozenDestination = rule.destination == "Player" and "Player" or "Storage"
                            local frozenDestId = frozenDestination == "Player" and core.getPlayerId() or STORAGE_ID
                            local frozenName = tostring(item.name)

                            jobs[#jobs + 1] = {
                                label = string.format(
                                    "%s: %s (%d) x%d -> %s",
                                    label, frozenName, frozenItemId, frozenMove, frozenDestination),
                                meta = {
                                    operationId = operationId,
                                    pawnLabel = label,
                                    pawnSlot = frozenSlotKey,
                                    partyGeneration = frozenGeneration,
                                    itemId = frozenItemId,
                                    itemName = frozenName,
                                    amount = frozenMove,
                                    sourceId = frozenSourceId,
                                    sourceHex = owner_hex(frozenSourceId),
                                    destination = frozenDestination,
                                    destinationId = frozenDestId,
                                    destinationHex = frozenDestId and owner_hex(frozenDestId) or nil,
                                },
                                fn = function()
                                    local valid, memberOrReason = validate_pawn_job(
                                        frozenGeneration, frozenSlotKey, frozenSourceId)
                                    if not valid then return true, memberOrReason end
                                    if not frozenDestId then
                                        return false, "Player CharacterID is unavailable."
                                    end

                                    local currentCount, countErr = core.getCount(frozenItemId, frozenSourceId)
                                    if currentCount == nil then return false, tostring(countErr) end
                                    local currentEquipped = math.min(
                                        currentCount,
                                        math.max(0, core.getEquippedCount(frozenSourceId, frozenItemId) or 0))
                                    local currentKeep = math.max(currentEquipped, frozenKeep)
                                    local safeMove = math.min(
                                        frozenMove,
                                        math.max(0, currentCount - currentKeep))
                                    if safeMove <= 0 then
                                        return true, "Skipped transfer because the live keep/equipment requirement consumed the available excess."
                                    end

                                    core.debugLog(
                                        "Basic",
                                        "Automation op=%d Pawn clean item=%d amount=%d source=%s dest=%s generation=%d",
                                        operationId, frozenItemId, safeMove,
                                        owner_hex(frozenSourceId), owner_hex(frozenDestId), frozenGeneration)
                                    return core.transferStack(frozenItemId, safeMove, frozenSourceId, frozenDestId)
                                end,
                            }
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
                            core.setPawnCleanerEnabled(false)
                            core.pawnCleaner.status = string.format(
                                "AUTO-CLEAN DISABLED after transfer failure on %s: %s",
                                tostring(summary.failedLabel or "?"), tostring(summary.error or "unknown error"))
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
            equippedCounts = build_equipped_counts(player.id),
        }
        if updateSnapshot ~= false then core.refreshSnapshot("player", player.id) end
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
        local memberId = state.member and state.member.id or nil
        local samePlayer = baseline ~= nil
            and baseline.memberId ~= nil
            and same_owner(baseline.memberId, memberId)
        local operationId = next_operation_id()

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
                    if move > 0 and memberId ~= nil then
                        local frozenItemId = itemId
                        local frozenMove = move
                        local frozenKeep = keep
                        local frozenSourceId = memberId
                        local frozenName = tostring(item.name)

                        jobs[#jobs + 1] = {
                            label = string.format(
                                "Player: %s (%d) x%d -> Storage",
                                frozenName, frozenItemId, frozenMove),
                            meta = {
                                operationId = operationId,
                                player = true,
                                itemId = frozenItemId,
                                itemName = frozenName,
                                amount = frozenMove,
                                sourceId = frozenSourceId,
                                sourceHex = owner_hex(frozenSourceId),
                                destination = "Storage",
                                destinationId = STORAGE_ID,
                                destinationHex = owner_hex(STORAGE_ID),
                            },
                            fn = function()
                                local livePlayerId = core.getPlayerId()
                                if not same_owner(livePlayerId, frozenSourceId) then
                                    return true, string.format(
                                        "Skipped stale Player transfer: owner changed (%s -> %s).",
                                        owner_hex(frozenSourceId), owner_hex(livePlayerId))
                                end

                                local currentCount, countErr = core.getCount(frozenItemId, frozenSourceId)
                                if currentCount == nil then return false, tostring(countErr) end
                                local currentEquipped = math.min(
                                    currentCount,
                                    math.max(0, core.getEquippedCount(frozenSourceId, frozenItemId) or 0))
                                local currentKeep = math.max(currentEquipped, frozenKeep)
                                local safeMove = math.min(
                                    frozenMove,
                                    math.max(0, currentCount - currentKeep))
                                if safeMove <= 0 then
                                    return true, "Skipped transfer because the live keep/equipment requirement consumed the available excess."
                                end

                                core.debugLog(
                                    "Basic",
                                    "Automation op=%d Player clean item=%d amount=%d source=%s dest=%s",
                                    operationId, frozenItemId, safeMove,
                                    owner_hex(frozenSourceId), owner_hex(STORAGE_ID))
                                return core.transferStack(frozenItemId, safeMove, frozenSourceId, STORAGE_ID)
                            end,
                        }
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
                            core.setPlayerCleanerEnabled(false)
                            core.playerCleaner.status = string.format(
                                "PLAYER AUTO-CLEAN DISABLED after transfer failure on %s: %s",
                                tostring(summary.failedLabel or "?"), tostring(summary.error or "unknown error"))
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

        local party, generation = refresh_party_generation()
        local playerId = core.getPlayerId()
        local jobs = {}
        local operationId = next_operation_id()

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

                                        local frozenItemId = itemId
                                        local frozenKeep = keep
                                        local frozenRequested = requested
                                        local frozenSourceId = sourceId
                                        local frozenTargetId = member.id
                                        local frozenSlotKey = member.slotKey
                                        local frozenGeneration = generation
                                        local frozenSourceName = override.destination == "Player" and "Player" or "Storage"
                                        local frozenPawnLabel = tostring(member.label or member.slotKey or "Pawn")
                                        local frozenItemName = tostring(item and item.name or "Item")

                                        jobs[#jobs + 1] = {
                                            label = string.format(
                                                "%s refill: %s (%d) x%d <- %s",
                                                frozenPawnLabel,
                                                frozenItemName,
                                                frozenItemId,
                                                frozenRequested,
                                                frozenSourceName),
                                            meta = {
                                                operationId = operationId,
                                                pawnRefill = true,
                                                pawnLabel = frozenPawnLabel,
                                                pawnSlot = frozenSlotKey,
                                                partyGeneration = frozenGeneration,
                                                itemId = frozenItemId,
                                                target = frozenKeep,
                                                requested = frozenRequested,
                                                source = frozenSourceName,
                                                sourceId = frozenSourceId,
                                                sourceHex = owner_hex(frozenSourceId),
                                                destinationId = frozenTargetId,
                                                destinationHex = owner_hex(frozenTargetId),
                                                reason = tostring(reason or "policy poll"),
                                            },
                                            fn = function()
                                                local valid, memberOrReason = validate_pawn_job(
                                                    frozenGeneration, frozenSlotKey, frozenTargetId)
                                                if not valid then return true, memberOrReason end

                                                local targetNow, targetErr = core.getCount(frozenItemId, frozenTargetId)
                                                if targetNow == nil then return false, tostring(targetErr) end
                                                local needNow = math.max(0, frozenKeep - targetNow)
                                                if needNow <= 0 then return true end

                                                if frozenSourceName == "Player" then
                                                    local livePlayerId = core.getPlayerId()
                                                    if not same_owner(livePlayerId, frozenSourceId) then
                                                        return true, string.format(
                                                            "Skipped stale refill: Player owner changed (%s -> %s).",
                                                            owner_hex(frozenSourceId), owner_hex(livePlayerId))
                                                    end
                                                end

                                                local sourceNow, sourceErr = core.getCount(frozenItemId, frozenSourceId)
                                                if sourceNow == nil then return false, tostring(sourceErr) end
                                                local moveNow = math.min(
                                                    frozenRequested,
                                                    needNow,
                                                    math.max(0, sourceNow))
                                                if moveNow <= 0 then
                                                    return true, "Refill source no longer has available quantity."
                                                end

                                                core.debugLog(
                                                    "Basic",
                                                    "Automation op=%d Pawn refill item=%d amount=%d source=%s dest=%s generation=%d",
                                                    operationId, frozenItemId, moveNow,
                                                    owner_hex(frozenSourceId), owner_hex(frozenTargetId), frozenGeneration)
                                                return core.transferStack(
                                                    frozenItemId, moveNow, frozenSourceId, frozenTargetId)
                                            end,
                                        }
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
                        core.setPawnCleanerEnabled(false)
                        core.pawnCleaner.refillStatus = string.format(
                            "PAWN AUTO-RETRIEVAL DISABLED after transfer failure on %s: %s",
                            tostring(summary.failedLabel or "?"), tostring(summary.error or "unknown error"))
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

    core.debugLog(
        "Basic",
        "TransferLogic attached; automation controller isolated from core.lua (party generation=%d).",
        runtime.partyGeneration)
    return core
end

return M
