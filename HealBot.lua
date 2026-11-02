_addon.name = 'HealBot'
_addon.author = 'Alden Park'
_addon.command = 'hb'
_addon.lastUpdate = '2026.11.01.0'
_addon.version = '1.0.0'

--[[
TODO:
- !!Fix: Make follow cancellable when in other zones
- Global action queue instead of rebuilding every cycle
- Action sets that must be performed together (e.g., Snake Eye, then Double Up)
- GEO
    - debuff support
    - clean up logic/code
- COR
    - Rolled # detection
- If not in same pt as other instance, send pt list via IPC
- If in alliance, automatically watch other healers?
--]]

require('luau')
require('ffxi/utils')
_libs.ffxi.include_addon_name = true
_libs.ffxi.req('all', {n='packets',v='1.0.0'})
_libs.req('queues')
settings_lib = _libs.ffxi.settings
local ipc_protocol = require('HealBot_ipc')

hb = {
    active = false, configs_loaded = false, partyMemberInfo = {}, ignoreList = S{}, extraWatchList = S{},
    statusMenuOpen = false,
    modes = {['showPacketInfo'] = false, ['debug'] = false, ['mob_debug'] = false, ['independent'] = false},
    _events = {}, txts = {}, config = {}
}
healer = T{}
settings = {}
_libs.ffxi.debug = hb.modes.debug

res = require('resources')
config = require('config')
texts = require('texts')
packets = require('packets')
files = require('files')

require('HealBot_statics')
require('HealBot_utils')
CureUtils = require('HB_CureUtils')
offense = require('HB_Offense')
actions = require('HB_Actions')
buffs = require('HealBot_buffHandling')
require('HealBot_packetHandling')
require('HealBot_queues')
local status_menu = require('HealBot_statusMenu')

local ipc_req = ipc_protocol.encode_request()
local can_act_statuses = S{0, 1, 5, 85}    --0/1/5/85 = idle/engaged/chocobo/other_mount
local resting_status = res.statuses:with('en', 'Resting').id
can_act_statuses:add(resting_status)
local dead_statuses = S{2, 3}
local low_mp_rest_threshold = 10
local pt_keys = {'party1_count', 'party2_count', 'party3_count'}
local pm_keys = {
    {'p0','p1','p2','p3','p4','p5'}, {'a10','a11','a12','a13','a14','a15'}, {'a20','a21','a22','a23','a24','a25'}
}
local party_motion = {members={}, checked_at=0, stationary=false}


local function party_is_stationary(now)
    -- Sample positions at most twice per second. A member counts as settled
    -- only after three seconds without meaningful movement, avoiding rest
    -- toggles during short pauses in party travel.
    if now - party_motion.checked_at < 0.5 then
        return party_motion.stationary
    end
    party_motion.checked_at = now

    local party = windower.ffxi.get_party()
    local my_zone = party.p0 and party.p0.zone
    if my_zone == nil then
        party_motion.stationary = false
        return false
    end

    local active_members = {}
    local stationary = true
    local function check_member(member)
        if not member or member.zone ~= my_zone or not member.name then return end
        active_members[member.name] = true
        local mob = windower.ffxi.get_mob_by_name(member.name)
        if not mob or not mob.x or not mob.y then
            stationary = false
            return
        end

        local state = party_motion.members[member.name]
        if not state then
            party_motion.members[member.name] = {x=mob.x, y=mob.y, last_moved=now}
            stationary = false
            return
        end

        local dx, dy = mob.x - state.x, mob.y - state.y
        if (dx * dx + dy * dy) > 0.25 then
            state.x, state.y, state.last_moved = mob.x, mob.y, now
        end
        if now - state.last_moved < 3 then stationary = false end
    end

    check_member(party.p0)
    for group_index, count_key in ipairs(pt_keys) do
        for member_index = 1, party[count_key] or 0 do
            check_member(party[pm_keys[group_index][member_index]])
        end
    end
    for name in pairs(party_motion.members) do
        if not active_members[name] then party_motion.members[name] = nil end
    end

    party_motion.stationary = stationary
    return stationary
end


local function should_rest(player, moving, now)
    -- Rest only while active, idle, recovering, and not following combat; a
    -- nearby follow target also makes party movement safe to tolerate.
    local vitals = player.vitals or {}
    local hp_percent = player.hpp or vitals.hpp
    if hp_percent == nil and vitals.hp and vitals.mhp and vitals.mhp > 0 then
        hp_percent = (vitals.hp / vitals.mhp) * 100
    end
    if hp_percent == nil and player.id then
        local self_mob = windower.ffxi.get_mob_by_id(player.id)
        hp_percent = self_mob and self_mob.hpp
    end
    local mp_percent = vitals.mpp
    if mp_percent == nil and vitals.mp and vitals.mmp and vitals.mmp > 0 then
        mp_percent = (vitals.mp / vitals.mmp) * 100
    end
    local needs_recovery = (hp_percent ~= nil and hp_percent < 100)
        or (mp_percent ~= nil and mp_percent < 100)
    local low_mp = mp_percent ~= nil and mp_percent <= low_mp_rest_threshold
    local idle_or_resting = player.status == 0 or player.status == resting_status
    local follow_target_in_range = false
    if player.status == resting_status and settings.follow.active and settings.follow.target then
        local target = windower.ffxi.get_mob_by_name(settings.follow.target)
        local distance = target and healer:dist_from(target.id) or -1
        follow_target_in_range = distance >= 0 and distance <= (settings.follow.distance or 3)
    end
    local party_is_quiet = party_is_stationary(now) or follow_target_in_range
    -- At the HUD's LOW MP threshold, pause auto-engage while idle so resting
    -- can recover MP; engagement resumes automatically when MP rises.
    return hb.active and idle_or_resting and not moving and needs_recovery
        and (not offense.assist.engage or low_mp)
        and party_is_quiet
end


hb._events['load'] = windower.register_event('load', function()
    if not _libs.ffxi then
        local err_msg = 'HealBot ERROR: Missing core requirement: https://github.com/aldenpark/ffxi-libs'
        windower.add_to_chat(39, err_msg)
        error(err_msg)
    end
    atcc(262, 'Welcome to HealBot! To see a list of commands, type //hb help')

    _G["healer"] = _libs.ffxi.actor.Actor.new()
    utils.load_configs()
    CureUtils.init_cure_potencies()
end)


hb._events['unload'] = windower.register_event('unload', function()
    for _,event in pairs(hb._events) do
        windower.unregister_event(event)
    end
end)


hb._events['logout'] = windower.register_event('logout', function()
    windower.send_command('lua unload healBot')
end)


hb._events['zone'] = windower.register_event('zone change', function(new_id, old_id)
    healer.zone_enter = os.clock()
    local zone_info = windower.ffxi.get_info()
    if zone_info ~= nil then
        if zone_info.zone == 131 then
            windower.send_command('lua unload healBot')
        elseif zone_info.mog_house == true then
            hb.active = false
        elseif settings.deactivateIndoors and indoor_zones:contains(zone_info.zone) then
            hb.active = false
        elseif settings.activateOutdoors and not indoor_zones:contains(zone_info.zone) then
            hb.active = true
        end
    end
end)


hb._events['job'] = windower.register_event('job change', function()
    hb.active = false
    healer:update_job()
    printStatus()
end)

hb._events['inc'] = windower.register_event('incoming chunk', handle_incoming_chunk)
hb._events['cmd'] = windower.register_event('addon command', processCommand)
hb._events['mouse'] = windower.register_event('mouse', function(event_type, x, y)
    if event_type == 2 and hb.ui_dragged then
        hb.ui_dragged = false
        utils.save_settings()
    end

    local status_text = hb.txts.actionInfo
    if event_type ~= 2 or not status_text or not status_text:visible() then return end

    local text_x, text_y = windower.text.get_location(status_text._name)
    local text_width, text_height = windower.text.get_extents(status_text._name)
    local flags = status_text:settings().flags
    if flags.right then text_x = text_x - text_width end
    if flags.bottom then text_y = text_y - text_height end
    if x < text_x or x > text_x + text_width or y < text_y or y > text_y + text_height then return end

    local row_count = 2 + (hb.statusMenuOpen and status_menu:size() or 0)
    local row = math.floor((y - text_y) / (text_height / row_count)) + 1
    if row == 1 then
        if hb.active then
            hb.active = false
            printStatus()
        else
            hb.activate()
        end
    elseif row == 2 then
        hb.statusMenuOpen = not hb.statusMenuOpen
    else
        status_menu:toggle(row - 2)
    end
    return true
end)


--[[
    Executes before each frame is rendered for display.
    Acts as the run() method of a threaded application.
--]]
hb._events['render'] = windower.register_event('prerender', function()
    if not hb.configs_loaded then return end
    local now = os.clock()
    local moving = hb.isMoving()
    local acting = hb.isPerformingAction(moving)
    local player = windower.ffxi.get_player()
    healer.name = player and player.name or 'Player'
    if (player ~= nil) and can_act_statuses:contains(player.status) then
        if player.status == resting_status and hb.resting_by_healbot and not hb.active then
            healer:send_cmd('input /heal')
            hb.resting_by_healbot = false
        elseif player.status ~= resting_status and hb.resting_by_healbot
            and now - (hb.rest_attempt_at or now) > 2 then
            hb.resting_by_healbot = false
        end
        local partner, targ = offense.assistee_and_target()
        hb.follow_target_exists()   --Attempts to prevent autorun problems
        local follow = settings.follow
        if hb.auto_movement_active() then
            if ((now - healer.last_move_check) > follow.delay) then
                local should_move = false
                if (targ ~= nil) and (player.target_index == partner.target_index) then
                    if offense.assist.engage and (partner.status == 1) then
                        if healer:dist_from(targ.id) > 3 then
                            should_move = true
                            healer:move_towards(targ.id)
                        end
                    end
                end
                if (not should_move) and follow.active and (healer:dist_from(follow.target) > follow.distance) then
                    should_move = true
                    healer:move_towards(follow.target)
                end
                if (not should_move) then
                    if follow.active then
                        windower.ffxi.run(false)
                    end
                else
                    moving = true
                end
                healer.last_move_check = now      --Refresh stored movement check time
            end
        end
        
        if hb.active and not (moving or acting) then
            --hb.active = false    --Quick stop when debugging
            if healer:action_delay_passed() then
                healer.last_action = now                    --Refresh stored action check time
                local action_taken = actions.take_action(player, partner, targ)
                if action_taken then
                    hb.resting_by_healbot = false
                elseif should_rest(player, moving, now) then
                    if player.status ~= resting_status and not hb.resting_by_healbot then
                        healer:send_cmd('input /heal')
                        hb.resting_by_healbot = true
                        hb.rest_attempt_at = now
                    end
                elseif player.status == resting_status and hb.resting_by_healbot then
                    healer:send_cmd('input /heal')
                    hb.resting_by_healbot = false
                end
            end
        end
        
        if hb.active and ((now - healer.last_ipc_sent) > healer.ipc_delay) then
            windower.send_ipc_message(ipc_req)
            healer.last_ipc_sent = now
        end
    end
end)


function hb.activate()
    local player = windower.ffxi.get_player()
    if player ~= nil then
        settings.healing.max = {}
        for _,cure_type in pairs(CureUtils.cure_types) do
            settings.healing.max[cure_type] = CureUtils.highest_tier(cure_type)
        end
        if (settings.healing.max.cure == 0) then
            if settings.healing.max.waltz > 0 then
                settings.healing.mode = 'waltz'
                settings.healing.modega = 'waltzga'
            else
                disableCommand('cure', true)
            end
        else
            settings.healing.mode = 'cure'
            settings.healing.modega = 'curaga'
        end
        hb.active = true
    end
    printStatus()
end


function hb.addPlayer(list, player)
    if (player == nil) or list:contains(player.name) or hb.ignoreList:contains(player.name) then return end
    local is_trust = player.mob and player.mob.spawn_type == 14 or false    --13 = players; 14 = Trust NPC
    if (settings.ignoreTrusts and is_trust and (not hb.extraWatchList:contains(player.name))) then return end
    local status = player.mob and player.mob.status or player.status
    if dead_statuses:contains(status) or (player.hpp <= 0) then
        --Player is dead.  Reset their buff/debuff lists and don't include them in monitored list
        buffs.resetDebuffTimers(player.name)
        buffs.resetBuffTimers(player.name)
    else
        player.trust = is_trust
        list[player.name] = player
    end
end


local function _getMonitoredPlayers()
    local pt = windower.ffxi.get_party()
    local my_zone = pt.p0.zone
    local targets = S{}
    for p = 1, #pt_keys do
        for m = 1, pt[pt_keys[p]] do
            local pt_member = pt[pm_keys[p][m]]
            if pt_member and my_zone == pt_member.zone then
                if p == 1 or hb.extraWatchList:contains(pt_member.name) then
                    hb.addPlayer(targets, pt_member)
                end
            end
        end
    end
    for extraName,_ in pairs(hb.extraWatchList) do
        hb.addPlayer(targets, windower.ffxi.get_mob_by_name(extraName))
    end
    hb.txts.montoredBox:text(getPrintable(targets, true))
    hb.txts.montoredBox:visible(settings.textBoxes.montoredBox.visible)
    return targets
end
hb.getMonitoredPlayers = _libs.ffxi.advutils.tcached(1, _getMonitoredPlayers)


local function _getMonitoredIds()
    local ids = S{}
    for name, player in pairs(hb.getMonitoredPlayers()) do
        local id = player.mob and player.mob.id or player.id or utils.get_player_id[name]
        if id ~= nil then
            ids[id] = true
        end
    end
    return ids
end
hb.getMonitoredIds = _libs.ffxi.advutils.tcached(1, _getMonitoredIds)


function hb.follow_target_exists()
    if (settings.follow.target == nil) then return end
    local ft = windower.ffxi.get_mob_by_name(settings.follow.target)
    if settings.follow.active and (ft == nil) then
        settings.follow.pause = true
        settings.follow.active = false
    elseif settings.follow.pause and (ft ~= nil) then
        settings.follow.pause = nil
        settings.follow.active = true
    end
end


function hb.auto_movement_active()
    return settings.follow.active or (offense.assist.active and offense.assist.engage)
end


function hb.isMoving()
    local timeAtPos = healer:time_at_pos()
    if timeAtPos == nil then
        hb.txts.moveInfo:hide()
        return true
    end
    local moving = healer:is_moving()
    hb.txts.moveInfo:text(('Time @ %s: %.1fs'):format(tostring(healer:pos()), timeAtPos))
    hb.txts.moveInfo:visible(settings.textBoxes.moveInfo.visible)
    return moving
end


function hb.isPerformingAction(moving)
    local acting = healer:is_acting()
    local player = windower.ffxi.get_player()
    local resting = player and player.status == resting_status
    local engaged = player and player.status == 1
    local activity = acting and 'performing an action'
        or (resting and 'resting' or (engaged and 'engaged' or (moving and 'moving' or 'idle')))
    local status = ('is %s'):format(activity)
    
    if (os.clock() - healer.zone_enter) < 25 then
        acting = true
        status = 'zoned recently'
        healer.zone_wait = true
    elseif healer.zone_wait then
        healer.zone_wait = false
        buffs.resetBuffTimers('ALL', S{'Protect V', 'Shell V'})
    elseif healer:buff_active('Sleep','Petrification','Charm','Terror','Lullaby','Stun','Silence','Mute') then
        acting = true
        status = 'is disabled'
    end
    
    if (player ~= nil) then
        local mpp = player.vitals.mpp
        if (mpp <= 10) then
            status = status..' | \\cs(255,0,0)LOW MP\\cr'
        end
    end
    
    local hb_status = hb.active and '\\cs(0,0,255)[ON]\\cr' or '\\cs(255,0,0)[OFF]\\cr'
    local menu_status = hb.statusMenuOpen and 'Options [-]' or 'Options [+]'
    local text = (' %s %s %s\n  %s'):format(hb_status, healer.name, status, menu_status)
    if hb.statusMenuOpen then
        text = text..'\n'..status_menu:text()
    end
    hb.txts.actionInfo:text(text)
    hb.txts.actionInfo:visible(settings.textBoxes.actionInfo.visible)
    return acting
end


function hb.process_ipc(msg)
    local loaded = ipc_protocol.decode(msg)
    if loaded == nil then
        return
    elseif loaded.method == 'GET' then
        local player = windower.ffxi.get_player()
        if player == nil then return end
        local response = ipc_protocol.encode_response(player)
        if response ~= nil then
            windower.send_ipc_message(response)
        end
    elseif loaded.method == 'POST' then
        for _,buff_id in ipairs(loaded.val) do
            if res.buffs[buff_id] == nil then
                return
            end
        end
        local player = windower.ffxi.get_mob_by_name(loaded.name)
        player = player or {id=loaded.pid,name=loaded.name,spawn_type=loaded.spawn_type}
        buffs.review_active_buffs(player, loaded.val)
    end
end

hb._events['ipc'] = windower.register_event('ipc message', hb.process_ipc)
