-- Inventory Manager for Dragon's Dogma 2 / REFramework.
-- Inventory data is event-driven; the UI renders only inside REFramework's normal script tree.

local core = require("InventoryManager/core")
local window = require("InventoryManager/window")

local okNick, nickFns = pcall(require, "_NickCore/Functions")
if not okNick or type(nickFns) ~= "table" or type(nickFns.run_once) ~= "table" then
    error("[InventoryManager] _NickCore with Functions.run_once is required.")
end

local CATALOG_PRIME_KEY = "InventoryManager.ItemDBCachePrime"
local LIVE_REFRESH_KEY = "InventoryManager.NativeLiveRefresh"
local PAWN_CLEANER_EVENT_KEY = "InventoryManager.PawnAutoCleanEvent"
local PLAYER_CLEANER_EVENT_KEY = "InventoryManager.PlayerAutoCleanEvent"

-- The Item DB exists independently of a loaded save. Prime the complete static
-- cache (IDs, names, metadata) while DD2 is still in its safe startup/main-menu
-- state, then remove the retry worker permanently for the rest of the session.
local CATALOG_PRIME_INTERVAL = 60
local catalogPrimeTicks = 0

local function reapply_persisted_stack_configuration(reason)
    if not core.stack or core.stack.enabled ~= true then return true end
    local ok = core.reapplyConfiguredStacks()
    core.debugLog("Basic", "Persisted stack reapply after %s: mode=%s result=%s", tostring(reason or "startup"), tostring(core.stack.mode), tostring(ok))
    return ok == true
end

local function catalog_prime_worker()
    catalogPrimeTicks = catalogPrimeTicks + 1
    if catalogPrimeTicks < CATALOG_PRIME_INTERVAL then return false end
    catalogPrimeTicks = 0

    if not core.ensureCatalog(false, true) then
        core.debugLog("Trace", "Item DB startup prime retry: catalog still unavailable.")
        return false
    end

    core.debugLog("Basic", "Item DB cache primed by startup retry worker.")
    reapply_persisted_stack_configuration("catalog-prime retry")
    return true
end

nickFns.run_once[CATALOG_PRIME_KEY] = nil
nickFns.run_once[LIVE_REFRESH_KEY] = nil
nickFns.run_once[PAWN_CLEANER_EVENT_KEY] = nil
nickFns.run_once[PLAYER_CLEANER_EVENT_KEY] = nil

-- Inventory mutations intentionally bypass NickCore's UpdateBehavior dispatcher.
-- NickCore suppresses its own on_update_behavior table while GuiManager reports an
-- active/paused GUI. Inventory Manager must continue working in that state, so this
-- callback is registered directly with REFramework and has no Active-UI/pause gate.
local function mutation_update_worker()
    if not core.hasPendingMutations() then return end
    core.debugLog("Trace", "UpdateBehavior mutation worker tick; steps=%d", core.getMutationStepsPerUpdate())
    core.processMutationQueue(core.getMutationStepsPerUpdate())
end

re.on_application_entry("UpdateBehavior", mutation_update_worker)

local function pawn_retrieval_update_worker()
    if not core.pawnCleaner.enabled then return end

    local due, reason = core.combat.update(core.pawnCleaner.pollTicks)
    if not due then return end
    if core.hasPendingMutations() then return end
    if core.getPlayerId() == nil then return end

    local ok, message = core.pollPawnRetrieval(reason)
    core.combat.markRetrievalChecked()
    if not ok then
        core.debugLog("Basic", "Pawn auto-retrieval check failed: %s", tostring(message))
    end
end

re.on_application_entry("UpdateBehavior", pawn_retrieval_update_worker)

local nativeRefreshReason = "native inventory event"
local nativeRefreshSettleFrames = 0
local NATIVE_REFRESH_SETTLE_FRAMES = 2

local function pawn_cleaner_event_worker()
    if not core.pawnCleaner.enabled then return true end
    if core.hasPendingMutations() then return false end
    if core.getPlayerId() == nil then return false end

    -- Do not establish an empty baseline while the party has not materialized.
    -- A later PawnManager registration hook will schedule us again.
    local party = core.refreshParty() or {}
    local hasPawn = false
    for _, member in ipairs(party) do
        if member.slotKey ~= "Player" then hasPawn = true break end
    end
    if not hasPawn then return true end

    core.pollPawnCleaner()
    return true
end

local function schedule_pawn_cleaner_event()
    if not core.pawnCleaner.enabled then
        nickFns.run_once[PAWN_CLEANER_EVENT_KEY] = nil
        return
    end
    nickFns.run_once[PAWN_CLEANER_EVENT_KEY] = pawn_cleaner_event_worker
end

local function player_cleaner_event_worker()
    if not core.playerCleaner.enabled then return true end
    if core.hasPendingMutations() then return false end
    if core.getPlayerId() == nil then return false end
    core.pollPlayerCleaner()
    return true
end

local function schedule_player_cleaner_event()
    if not core.playerCleaner.enabled then
        nickFns.run_once[PLAYER_CLEANER_EVENT_KEY] = nil
        return
    end
    nickFns.run_once[PLAYER_CLEANER_EVENT_KEY] = player_cleaner_event_worker
end

local function live_refresh_worker()
    -- Native storage callbacks can fire in bursts while DD2 is still finalizing
    -- related state. Wait for a tiny quiet window, then rebuild once from the
    -- settled state. Continuous pickup bursts keep resetting this countdown, so
    -- they do not accidentally turn event-driven refresh into per-frame scanning.
    if core.hasPendingMutations() then return false end
    if nativeRefreshSettleFrames > 0 then
        nativeRefreshSettleFrames = nativeRefreshSettleFrames - 1
        return false
    end
    if core.getPlayerId() == nil then return true end
    core.debugLog("Verbose", "Executing coalesced live inventory refresh: %s", tostring(nativeRefreshReason))
    window.refreshLiveInventory(nativeRefreshReason)
    schedule_pawn_cleaner_event()
    schedule_player_cleaner_event()
    return true
end

local function schedule_live_refresh(reason)
    nativeRefreshReason = tostring(reason or "native inventory event")
    core.debugLog("Trace", "Scheduled native live refresh: %s", nativeRefreshReason)
    nativeRefreshSettleFrames = NATIVE_REFRESH_SETTLE_FRAMES
    window.markNativeInventoryChanged(nativeRefreshReason)
    -- A deterministic NickCore slot coalesces repeated native callbacks into one
    -- delayed refresh after the current burst settles.
    nickFns.run_once[LIVE_REFRESH_KEY] = live_refresh_worker
end

core.setPawnCleanerControlCallback(function(enabled)
    if enabled then schedule_pawn_cleaner_event()
    else nickFns.run_once[PAWN_CLEANER_EVENT_KEY] = nil end
end)
if core.pawnCleaner.enabled == true then schedule_pawn_cleaner_event() end

core.setPlayerCleanerControlCallback(function(enabled)
    if enabled then schedule_player_cleaner_event()
    else nickFns.run_once[PLAYER_CLEANER_EVENT_KEY] = nil end
end)
if core.playerCleaner.enabled == true then schedule_player_cleaner_event() end

-- DD2 exposes a central storage-event path plus separate equipment/party paths.
-- Hooks only schedule a coalesced refresh; they never enumerate inventories from
-- inside the native callback itself.
local ItemManagerType = sdk.find_type_definition("app.ItemManager")
local PawnManagerType = sdk.find_type_definition("app.PawnManager")
local ItemCommonParamType = sdk.find_type_definition("app.ItemCommonParam")

-- DD2's current WarehouseMaxStackNum is a static literal, not a mutable second
-- stack field. Scoped Player/Pawn vs Storage limits therefore belong at the
-- native owner-aware resolver: ItemCommonParam:getStackNum(CharacterID).
local getStackNumOwnerMethod = ItemCommonParamType
    and ItemCommonParamType:get_method("getStackNum(app.CharacterID)") or nil
if getStackNumOwnerMethod then
    sdk.hook(
        getStackNumOwnerMethod,
        function(args)
            local storage = thread.get_hook_storage()
            storage.imStackOverride = nil
            local param = sdk.to_managed_object(args[2])
            local ownerId = args[3] and sdk.to_int64(args[3]) or nil
            local override = core.resolveStackOverride(param, ownerId)
            if override ~= nil then storage.imStackOverride = override end
        end,
        function(retval)
            local storage = thread.get_hook_storage()
            local override = storage.imStackOverride
            storage.imStackOverride = nil
            if override ~= nil then return sdk.to_ptr(override) end
            return retval
        end)
    core.debugLog("Basic", "Installed owner-aware ItemCommonParam.getStackNum stack resolver hook.")
else
    log.error("[InventoryManager] ItemCommonParam.getStackNum(app.CharacterID) was not found; scoped stack overrides are unavailable.")
end

local function hook_inventory_change(typeDef, signature, reason)
    if not typeDef then return false end
    local method = typeDef:get_method(signature)
    if not method then
        log.info("[InventoryManager] Native refresh hook unavailable: " .. tostring(signature))
        return false
    end
    local ok, err = pcall(function()
        sdk.hook(
            method,
            function(args)
                if sdk.PreHookResult then return sdk.PreHookResult.CALL_ORIGINAL end
            end,
            function(retval)
                schedule_live_refresh(reason)
                return retval
            end)
    end)
    if not ok then
        log.info("[InventoryManager] Could not install native refresh hook " .. tostring(signature) .. ": " .. tostring(err))
        return false
    end
    core.debugLog("Trace", "Installed native refresh hook: %s (%s)", tostring(signature), tostring(reason))
    return true
end

local hookCount = 0
local function add_hook(typeDef, signature, reason)
    if hook_inventory_change(typeDef, signature, reason) then hookCount = hookCount + 1 end
end

add_hook(ItemManagerType,
    "addStorageEvent(app.ItemManager.StorageEventType, System.Int32, System.Int32, System.Int32, app.ItemCommonParam, app.CharacterID, app.Character, app.CharacterID)",
    "storage event")
add_hook(ItemManagerType, "applyEquipChange()", "equipment change")
add_hook(ItemManagerType, "equipLantern(System.Int32)", "lantern equip")
add_hook(ItemManagerType, "equipOffLantern(app.CharacterID)", "lantern unequip")
add_hook(PawnManagerType, "registPawn(app.Character)", "pawn joined party")
add_hook(PawnManagerType, "unregistPawn(app.Character)", "pawn left party")
add_hook(PawnManagerType, "dismissPawn(app.CharacterID)", "pawn dismissed")

log.info(string.format("[InventoryManager] Native live-refresh hooks installed: %d.", hookCount))

-- First try immediately. If app.ItemManager is not ready yet, a throttled
-- NickCore run_once callback retries from LateUpdateBehavior, which still runs
-- before NickCore's Player-valid gate and therefore works at the main menu.
-- This primes only the static Item DB: no live inventory APIs are touched.
if not core.ensureCatalog(false, true) then
    nickFns.run_once[CATALOG_PRIME_KEY] = catalog_prime_worker
    core.debugLog("Basic", "Item DB cache unavailable at startup; retry worker armed.")
else
    log.info("[InventoryManager] Item DB cache primed immediately during startup.")
    reapply_persisted_stack_configuration("immediate startup prime")
end

-- Mutation processing is driven directly by REFramework's UpdateBehavior entry.
-- No wake/registration step is needed when the queue becomes non-empty.

log.info(string.format(
    "[InventoryManager] Loaded v%s - %s (combat/camp/town gated Pawn retrieval; fail-closed native transfer guard; transfer safety stop; persistent stack reapply after Reset Scripts; %d mutation steps/update).",
    tostring(core.VERSION or "?"),
    tostring(core.VERSION_MONIKER or ""),
    core.getMutationStepsPerUpdate()
))
core.debugLog("Basic", "SESSION START version=%s moniker=%s configuredLevel=%s mutationStepsPerUpdate=%d", tostring(core.VERSION or "?"), tostring(core.VERSION_MONIKER or ""), core.getDebugLogLevel(), core.getMutationStepsPerUpdate())

-- REFramework's Reset Scripts tears down this Lua state but leaves DD2's native
-- ItemDataParam objects alive. Restore our runtime stack edits before teardown so
-- the replacement Lua state can safely capture the game's vanilla _StackNum data.
if re.on_script_reset then
    re.on_script_reset(function()
        -- Stop the auxiliary NickCore run-once services while stack values are
        -- being restored. REFramework tears down this script's direct
        -- UpdateBehavior callback as part of Reset Scripts.
        nickFns.run_once[CATALOG_PRIME_KEY] = nil
        nickFns.run_once[LIVE_REFRESH_KEY] = nil
        nickFns.run_once[PAWN_CLEANER_EVENT_KEY] = nil
        nickFns.run_once[PLAYER_CLEANER_EVENT_KEY] = nil
        core.combat.resetRuntime()

        core.debugLog("Basic", "Reset Scripts teardown: restoring native stack fields before Lua state replacement.")
        local ok, restored, failed = core.restoreStacksForScriptReset()
        if not ok then
            log.error(string.format(
                "[InventoryManager] Script-reset stack cleanup incomplete: %d restored, %d failed.",
                tonumber(restored) or 0, tonumber(failed) or 0))
        end
    end)
end

-- The working UI remains a standalone ImGui window; the REF tree only launches it
-- and exposes support settings. No keyboard toggle path is registered.
re.on_frame(function()
    window.draw()
end)

re.on_draw_ui(function()
    if imgui.tree_node("Inventory Manager") then
        if imgui.button(window.isOpen() and "Close Inventory Manager" or "Open Inventory Manager") then
            window.toggle()
        end
        imgui.text("Main-menu Item DB cache + native-transfer Player/Pawn automation + sortable inventory")
        imgui.text(core.status or "")
        window.drawRefUiControls()
        imgui.tree_pop()
    end
end)
