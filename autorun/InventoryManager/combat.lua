local combat = {}

combat.MODES = {
    "Proper Cheaty",
    "Semi-Cheaty",
    "Semi-Proper",
    "Proper",
}

combat.DESCRIPTIONS = {
    ["Proper Cheaty"] = "Anywhere, including during combat.",
    ["Semi-Cheaty"] = "Anywhere outside combat; field refills occur after combat ends.",
    ["Semi-Proper"] = "Only while at an active camp or in town, outside combat.",
    ["Proper"] = "Only while in town, outside combat.",
}

combat.mode = "Semi-Cheaty"
combat.runtime = {
    tick = 0,
    lastInBattle = nil,
    lastInCamp = nil,
    lastInTown = nil,
    pendingReason = nil,
    lastState = nil,
}

local PawnPartyCombatInfoType = sdk.find_type_definition("app.PawnPartyCombatInfo")
local PartyTalkControllerType = sdk.find_type_definition("app.PLPartyTalkController")
local CampManagerType = sdk.find_type_definition("app.CampManager")
local PawnManagerType = sdk.find_type_definition("app.PawnManager")

local isInBattleField = PawnPartyCombatInfoType and PawnPartyCombatInfoType:get_field("_IsInBattle") or nil
local isInBattleMethod = PawnPartyCombatInfoType and PawnPartyCombatInfoType:get_method("isInBattle()") or nil
local combatInfoField = PartyTalkControllerType and PartyTalkControllerType:get_field("_CombatInfo") or nil
local getCombatInfoMethod = PartyTalkControllerType and PartyTalkControllerType:get_method("get_CombatInfo()") or nil
local talkControllerField = PawnManagerType and PawnManagerType:get_field("TalkController") or nil
local isActiveCampMethod = CampManagerType and CampManagerType:get_method("get_IsActiveCamp()") or nil
local isPlayerInTownField = PawnManagerType and PawnManagerType:get_field("IsPlayerInTownArea") or nil

local cachedCombatInfo = nil
local cachedCampManager = nil
local cachedPawnManager = nil

local function safe_call(fn)
    local ok, value = pcall(fn)
    if ok then return value end
    return nil
end

local function singleton(name, cached)
    if cached then return cached end
    return safe_call(function() return sdk.get_managed_singleton(name) end)
end

local function normalize_mode(value)
    value = tostring(value or "")
    for _, name in ipairs(combat.MODES) do
        if value == name then return name end
    end
    return "Semi-Cheaty"
end

local function read_field_bool(obj, field, fallbackName)
    if not obj then return nil end

    local value = nil
    if field then
        value = safe_call(function() return field:get_data(obj) end)
    end
    if value == nil and fallbackName then
        value = safe_call(function() return obj:get_field(fallbackName) end)
    end
    if value == nil then return nil end
    return value == true
end

function combat.configure(mode)
    combat.mode = normalize_mode(mode)
    combat.resetRuntime()
    return combat.mode
end

function combat.getMode()
    return combat.mode
end

function combat.getModeChoices()
    return combat.MODES
end

function combat.getModeIndex()
    for i, name in ipairs(combat.MODES) do
        if name == combat.mode then return i end
    end
    return 2
end

function combat.setMode(value)
    if type(value) == "number" then
        value = combat.MODES[math.max(1, math.min(#combat.MODES, math.floor(value)))]
    end
    combat.mode = normalize_mode(value)
    combat.resetRuntime()
    return combat.mode
end

function combat.getDescription(mode)
    return combat.DESCRIPTIONS[normalize_mode(mode or combat.mode)] or ""
end

function combat.resetRuntime()
    combat.runtime.tick = 0
    combat.runtime.lastInBattle = nil
    combat.runtime.lastInCamp = nil
    combat.runtime.lastInTown = nil
    combat.runtime.pendingReason = nil
    combat.runtime.lastState = nil
end

function combat.readState()
    cachedCampManager = singleton("app.CampManager", cachedCampManager)
    cachedPawnManager = singleton("app.PawnManager", cachedPawnManager)

    if not cachedCombatInfo and cachedPawnManager then
        local talkController = nil
        if talkControllerField then
            talkController = safe_call(function() return talkControllerField:get_data(cachedPawnManager) end)
        end
        if talkController == nil then
            talkController = safe_call(function() return cachedPawnManager:get_field("TalkController") end)
        end
        if talkController then
            if combatInfoField then
                cachedCombatInfo = safe_call(function() return combatInfoField:get_data(talkController) end)
            end
            if not cachedCombatInfo and getCombatInfoMethod then
                cachedCombatInfo = safe_call(function() return getCombatInfoMethod:call(talkController) end)
            end
            if not cachedCombatInfo then
                cachedCombatInfo = safe_call(function() return talkController:get_field("_CombatInfo") end)
            end
        end
    end
    if not cachedCombatInfo then
        cachedCombatInfo = singleton("app.PawnPartyCombatInfo", cachedCombatInfo)
    end

    local inBattle = read_field_bool(cachedCombatInfo, isInBattleField, "_IsInBattle")
    if inBattle == nil and cachedCombatInfo and isInBattleMethod then
        local value = safe_call(function() return isInBattleMethod:call(cachedCombatInfo) end)
        if value ~= nil then inBattle = value == true end
    end

    local inCamp = nil
    if cachedCampManager and isActiveCampMethod then
        local value = safe_call(function() return isActiveCampMethod:call(cachedCampManager) end)
        if value ~= nil then inCamp = value == true end
    end

    local inTown = read_field_bool(cachedPawnManager, isPlayerInTownField, "IsPlayerInTownArea")

    local state = {
        inBattle = inBattle,
        inCamp = inCamp,
        inTown = inTown,
        combatAvailable = cachedCombatInfo ~= nil and (isInBattleField ~= nil or isInBattleMethod ~= nil),
        campAvailable = cachedCampManager ~= nil and isActiveCampMethod ~= nil,
        townAvailable = cachedPawnManager ~= nil and isPlayerInTownField ~= nil,
    }
    combat.runtime.lastState = state
    return state
end

function combat.isRetrievalAllowed(mode, state)
    mode = normalize_mode(mode or combat.mode)
    state = state or combat.readState()

    if mode == "Proper Cheaty" then
        return true, state.inBattle == true and "mid-combat" or "anywhere"
    end

    if state.inBattle ~= false then
        return false, state.inBattle == true and "combat-locked" or "combat-state-unavailable"
    end

    if mode == "Semi-Cheaty" then
        return true, "out-of-combat"
    end

    if mode == "Semi-Proper" then
        if state.inCamp == true then return true, "active-camp" end
        if state.inTown == true then return true, "town" end
        return false, "camp-or-town-required"
    end

    if mode == "Proper" then
        if state.inTown == true then return true, "town" end
        return false, "town-required"
    end

    return false, "unknown-policy"
end

function combat.update(pollTicks)
    pollTicks = math.max(15, math.floor(tonumber(pollTicks) or 60))
    local state = combat.readState()
    local rt = combat.runtime

    local battleEnded = rt.lastInBattle == true and state.inBattle == false
    local enteredCamp = rt.lastInCamp ~= true and state.inCamp == true
    local enteredTown = rt.lastInTown ~= true and state.inTown == true

    rt.lastInBattle = state.inBattle
    rt.lastInCamp = state.inCamp
    rt.lastInTown = state.inTown

    local allowed, gateReason = combat.isRetrievalAllowed(combat.mode, state)
    if not allowed then
        rt.tick = 0
        rt.pendingReason = nil
        return false, gateReason, state
    end

    rt.tick = rt.tick + 1

    if battleEnded then
        rt.pendingReason = "battle-ended"
    elseif enteredCamp then
        rt.pendingReason = "entered-camp"
    elseif enteredTown then
        rt.pendingReason = "entered-town"
    elseif rt.pendingReason == nil and rt.tick >= pollTicks then
        rt.pendingReason = gateReason
    end

    return rt.pendingReason ~= nil, rt.pendingReason or gateReason, state
end

function combat.markRetrievalChecked()
    combat.runtime.tick = 0
    combat.runtime.pendingReason = nil
end

function combat.getStatus()
    local state = combat.runtime.lastState or combat.readState()
    local allowed, reason = combat.isRetrievalAllowed(combat.mode, state)
    return {
        mode = combat.mode,
        description = combat.getDescription(combat.mode),
        allowed = allowed == true,
        reason = reason,
        inBattle = state.inBattle,
        inCamp = state.inCamp,
        inTown = state.inTown,
        combatAvailable = state.combatAvailable == true,
        campAvailable = state.campAvailable == true,
        townAvailable = state.townAvailable == true,
    }
end

return combat
