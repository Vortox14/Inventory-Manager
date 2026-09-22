-- Inventory Manager DD2 / REFramework native binding table.
--
-- Keep reflected types, method handles, and canonical native constants here so
-- core.lua does not spend its top-level local budget on static bindings.

local N = {}

N.STORAGE_ID = 65535
N.ARISEN_ID = -1403890315    -- low32 0xAC525575
N.MAIN_PAWN_ID = -2011938949 -- low32 0x88143F7B
N.LANTERN_FUEL_ID = 85
N.LANTERN_IDS = { [86] = true, [87] = true, [88] = true, [89] = true }
N.SEALING_PHIAL_IDS = { [90] = true, [91] = true }
N.WAKESHARD_ID = 78
N.WAKESTONE_ID = 77
N.GOLD_ID = 93
N.GOLD_CAP = 999999999
N.UINT16_MAX = 65535
N.UINT32_MAX = 4294967295
N.STACK_SOFT_CAP = 10000
N.STACK_HARD_CAP = 32000

N.PASS_ITEM_SIGNATURE = "passItem(app.ItemDefine.StorageData, System.Int32, app.CharacterID, System.Boolean)"
N.PASS_ITEM_NOLOCK_SIGNATURE = "passItemNoLock(app.ItemDefine.StorageData, System.Int32, app.CharacterID, System.Boolean)"

function N.characterIdHex32(value)
    local n = tonumber(value)
    if n == nil then return nil end
    return string.format("0x%08X", math.floor(n) % 4294967296)
end

N.ItemManagerType = sdk.find_type_definition("app.ItemManager")
N.CharacterManagerType = sdk.find_type_definition("app.CharacterManager")
N.PawnManagerType = sdk.find_type_definition("app.PawnManager")
N.ItemCommonParamType = sdk.find_type_definition("app.ItemCommonParam")
N.StorageDataType = sdk.find_type_definition("app.ItemDefine.StorageData")
N.StorageMasterDataType = sdk.find_type_definition("app.ItemManager.StorageMasterData")
N.ContextHolderType = sdk.find_type_definition("app.ContextHolder")
N.PawnDataContextType = sdk.find_type_definition("app.PawnDataContext")

N.getHaveNumMethod = N.ItemManagerType and N.ItemManagerType:get_method("getHaveNum(System.Int32, app.CharacterID)") or nil
N.getItemMethod = N.ItemManagerType and N.ItemManagerType:get_method("getItem(System.Int32, System.Int32, app.CharacterID, app.ItemDefine.GetItemOption)") or nil
N.deleteItemNoLockMethod = N.ItemManagerType and N.ItemManagerType:get_method("deleteItemNoLock(System.Int32, System.Int32, app.CharacterID)") or nil
N.recreateTransferMethods = {
    getItemCharacter = N.ItemManagerType and N.ItemManagerType:get_method("getItem(System.Int32, System.Int32, app.Character, app.ItemDefine.GetItemOption)") or nil,
    deleteItemCharacter = N.ItemManagerType and N.ItemManagerType:get_method("deleteItem(System.Int32, System.Int32, app.Character)") or nil,
    deleteItemCharacterId = N.ItemManagerType and N.ItemManagerType:get_method("deleteItem(System.Int32, System.Int32, app.CharacterID)") or nil,
    forceWarehouse = N.ItemManagerType and N.ItemManagerType:get_method("forceGetItemToWarehouse(System.Int32, System.Int32)") or nil,
    forceWarehouseOption = N.ItemManagerType and N.ItemManagerType:get_method("forceGetItemToWarehouse(System.Int32, System.Int32, app.ItemDefine.GetItemOption)") or nil,
}
N.isDecayItemMethod = N.ItemManagerType and N.ItemManagerType:get_method("isDecayItem(System.Int32)") or nil
N.getStorageMasterListMethod = N.ItemManagerType and N.ItemManagerType:get_method("getStorageMasterList(app.CharacterID)") or nil
N.calcWeightStorageMethod = N.ItemManagerType and N.ItemManagerType:get_method("calcWeightStorage(app.CharacterID)") or nil

N.getDefaultStackNumMethod = N.ItemCommonParamType and N.ItemCommonParamType:get_method("getDefaultStackNum()") or nil
N.getStackNumMethod = N.ItemCommonParamType and N.ItemCommonParamType:get_method("getStackNum(app.CharacterID)") or nil
N.getIsEquipMethod = N.ItemCommonParamType and N.ItemCommonParamType:get_method("get_IsEquip()") or nil
N.getIsEquipDataMethod = N.ItemCommonParamType and N.ItemCommonParamType:get_method("get_IsEquipData()") or nil
N.getIsItemDataMethod = N.ItemCommonParamType and N.ItemCommonParamType:get_method("get_IsItemData()") or nil
N.rawStackNumField = N.ItemCommonParamType and N.ItemCommonParamType:get_field("_StackNum") or nil
N.warehouseMaxStackNumField = N.ItemCommonParamType and N.ItemCommonParamType:get_field("WarehouseMaxStackNum") or nil
N.isNoStacItemMethod = N.ItemManagerType and N.ItemManagerType:get_method("isNoStacItem(app.ItemCommonParam)") or nil

N.getStorageDataByIdMethod = N.ItemManagerType and N.ItemManagerType:get_method("getStorageData(System.Int32, app.CharacterID)") or nil
N.getStorageDataByStorageIdMethod = N.ItemManagerType and N.ItemManagerType:get_method("getStorageDataByStorageId(System.Int32)") or nil
N.isPassEnableMethod = N.ItemManagerType and N.ItemManagerType:get_method("isPassEnable(app.ItemDefine.StorageData, System.Boolean)") or nil
N.isPassEnableCommandMethod = N.ItemManagerType and N.ItemManagerType:get_method("isPassEnableCommand(app.ItemDefine.StorageData, System.Boolean)") or nil
N.getEquipLanternStorageIdMethod = N.ItemManagerType and N.ItemManagerType:get_method("getEquipLanternStorageId(app.CharacterID)") or nil
N.getLanternInfoByStorageIdMethod = N.ItemManagerType and N.ItemManagerType:get_method("getLanternInfo(System.Int32)") or nil

N.getMasterParamMethod = N.StorageMasterDataType and N.StorageMasterDataType:get_method("get_Param()") or nil
N.getMasterItemIdMethod = N.StorageMasterDataType and N.StorageMasterDataType:get_method("get_ItemId()") or nil
N.getMasterNumMethod = N.StorageMasterDataType and N.StorageMasterDataType:get_method("get_Num()") or nil
N.getMasterStorageIdMethod = N.StorageMasterDataType and N.StorageMasterDataType:get_method("get_StorageId()") or nil
N.getMasterCharaIdMethod = N.StorageMasterDataType and N.StorageMasterDataType:get_method("get_CharaId()") or nil
N.getMasterIsEquippedMethod = N.StorageMasterDataType and N.StorageMasterDataType:get_method("get_IsEquipped()") or nil
N.getMasterEquipSlotMethod = N.StorageMasterDataType and N.StorageMasterDataType:get_method("get_EquipSlot()") or nil
N.getMasterUpdateIndexMethod = N.StorageMasterDataType and N.StorageMasterDataType:get_method("get_UpdateIndex()") or nil
N.getMasterArisenEquipNoMethod = N.StorageMasterDataType and N.StorageMasterDataType:get_method("get_ArisenEquipNo()") or nil
N.getMasterItemDataMethod = N.StorageMasterDataType and N.StorageMasterDataType:get_method("get_ItemData()") or nil
N.getMasterEnhanceMethod = N.StorageMasterDataType and N.StorageMasterDataType:get_method("get_Enhance()") or nil
N.getMasterEnhanceNumMethod = N.StorageMasterDataType and N.StorageMasterDataType:get_method("get_EnhanceNum()") or nil
N.getMasterAbilityMethod = N.StorageMasterDataType and N.StorageMasterDataType:get_method("get_Ability()") or nil
N.getMasterAbilityNumMethod = N.StorageMasterDataType and N.StorageMasterDataType:get_method("get_AbilityNum()") or nil

function N.typeName(typeDef)
    if not typeDef then return "?" end
    local ok, value = pcall(function() return typeDef:get_full_name() end)
    if ok and value ~= nil then return tostring(value) end
    ok, value = pcall(function() return typeDef:get_name() end)
    return ok and value ~= nil and tostring(value) or "?"
end

function N.methodSignature(method)
    if not method then return "?" end
    local okName, name = pcall(function() return method:get_name() end)
    local okTypes, paramTypes = pcall(function() return method:get_param_types() end)
    local params = {}
    if okTypes and paramTypes then
        for _, ptype in pairs(paramTypes) do params[#params + 1] = N.typeName(ptype) end
    end
    local okRet, retType = pcall(function() return method:get_return_type() end)
    return string.format("%s %s(%s)", N.typeName(okRet and retType or nil), tostring(okName and name or "?"), table.concat(params, ", "))
end

function N.methodParamNames(method)
    if not method then return {} end
    local ok, names = pcall(function() return method:get_param_names() end)
    if not ok or not names then return {} end
    local keyed = {}
    for key, value in pairs(names) do
        keyed[#keyed + 1] = { order = tonumber(key) or 1000000, value = tostring(value or "") }
    end
    table.sort(keyed, function(a, b) return a.order < b.order end)
    local out = {}
    for _, entry in ipairs(keyed) do out[#out + 1] = entry.value end
    return out
end

return N
