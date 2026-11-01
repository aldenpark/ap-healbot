--==============================================================================
--	HealBot action handling functions
--==============================================================================

local actions = {queue=L()}
local resources_lib = _libs.ffxi.resources
local ffxi = _libs.ffxi.ffxi
local resting_status = res.statuses:with('en', 'Resting').id
local stand_pending_at
local rest_tick_due_at
local rest_emergency_hpp = 40
local rest_tick_margin = 2
local critical_cure_hpp = 20
local low_mp_rest_threshold = 10
local divine_seal = resources_lib.action_for('Divine Seal')
local afflatus = {
    ['Afflatus Solace'] = resources_lib.action_for('Afflatus Solace'),
    ['Afflatus Misery'] = resources_lib.action_for('Afflatus Misery')
}


local function desired_afflatus(player, offensive_action)
    if not player or player.main_job ~= 'WHM' then return nil end
    if offensive_action and offensive_action.name == '<t>' then
        local attack = offensive_action.action
        local damaging_magic = attack and (attack.skill == 32 or attack.skill == 36 or attack.skill == 37)
        if damaging_magic or (attack and attack.prefix == '/weaponskill') then
            return 'Afflatus Misery'
        end
    end
    return 'Afflatus Solace'
end


local function get_afflatus_action(player, action_name)
    if not action_name then return nil end
    if healer:buff_active(action_name) then return nil end

    local ability = afflatus[action_name]
    if ability and healer:ready_to_use(ability) then
        return {type='buff', action=ability, name=player.name, buff=action_name, prio=0}
    end
    return nil
end


local function has_enough_mp(action, preserve_reserve)
    -- Ability actions without an MP cost pass through. Optional buffs/offense
    -- stop at the low-MP reserve; needed status-removal spells may still run.
    local mp_cost = action and action.mp_cost
    if type(mp_cost) ~= 'number' or mp_cost <= 0 then return true end
    local player = windower.ffxi.get_player()
    if preserve_reserve and player and player.vitals and player.vitals.mpp and player.vitals.mpp <= 10 then
        return false
    end
    return player and player.vitals and player.vitals.mp >= mp_cost
end


local function is_emergency_cure(action)
    return action and (action.emergency_cure
        or (action.type == 'cure' and action.hpp and action.hpp <= rest_emergency_hpp))
end


local function stand_if_resting(player)
    -- /heal toggles resting, so rate-limit the command while Windower still
    -- reports Resting and let the caller retry after the status changes.
    if player.status == resting_status then
        if not stand_pending_at or os.clock() - stand_pending_at > 2 then
            healer:send_cmd('input /heal')
            stand_pending_at = os.clock()
        end
        return true
    end
    stand_pending_at = nil
    return false
end


local function local_queue_reset()
    actions.queue = L()
end

local function local_queue_insert(action, target)
    actions.queue:append(tostring(action)..' → '..tostring(target))
end

local function local_queue_disp()
    hb.txts.actionQueue:text(getPrintable(actions.queue))
    hb.txts.actionQueue:visible(settings.textBoxes.actionQueue.visible)
end


--[[
	Builds an action queue for defensive actions.  Returns the action deemed most important at the time.
--]]
function actions.get_defensive_action(offensive_action)
	-- Build all candidate queues before choosing one, allowing cure urgency to
	-- be compared against debuff/buff priorities consistently.
	local action = {}
	local player = windower.ffxi.get_player()
	local afflatus_name = desired_afflatus(player, offensive_action)
	
	if (not settings.disable.cure) then
		local cureq = CureUtils.get_cure_queue()
		while (not cureq:empty()) do
			local cact = cureq:pop()
            local_queue_insert(cact.action.en, cact.name)
			if (action.cure == nil) and healer:in_casting_range(cact.name) then
				action.cure = cact
			end
		end
	end
	if (not settings.disable.na) then
		local dbuffq = buffs.getDebuffQueue()
		while (not dbuffq:empty()) do
			local dbact = dbuffq:pop()
            local_queue_insert(dbact.action.en, dbact.name)
			if (action.debuff == nil) and healer:in_casting_range(dbact.name)
				and healer:ready_to_use(dbact.action) and has_enough_mp(dbact.action) then
				action.debuff = dbact
			end
		end
	end
	local player_mp = player and player.vitals and player.vitals.mpp
	local conserving_mp = player_mp ~= nil and player_mp <= 10
	if (not settings.disable.buff) and not conserving_mp then
		local buffq = buffs.getBuffQueue()
		while (not buffq:empty()) do
			local bact = buffq:pop()
            local_queue_insert(bact.action.en, bact.name)
			local is_afflatus = bact.action.en == 'Afflatus Solace' or bact.action.en == 'Afflatus Misery'
			if (action.buff == nil) and not is_afflatus and healer:in_casting_range(bact.name)
				and healer:ready_to_use(bact.action) and has_enough_mp(bact.action, true) then
				action.buff = bact
			end
		end
	end

    -- Keep the WHM stance matched to its actual work. This candidate is
    -- synthetic: it does not depend on the user having loaded a buff list.
    local afflatus_action = get_afflatus_action(player, afflatus_name)
    if afflatus_action and (action.buff == nil or afflatus_action.prio < action.buff.prio) then
        action.buff = afflatus_action
        local_queue_insert(afflatus_action.action.en, afflatus_action.name)
    end
	
	local_queue_disp()
	
	if (action.cure ~= nil) then
		local player = windower.ffxi.get_player()
		if player and player.main_job == 'WHM' and action.cure.hpp <= critical_cure_hpp then
			local largest_cure = CureUtils.get_usable_cure(CureUtils.highest_tier('cure'), 'cure')
			if largest_cure then
				action.cure.action = largest_cure
				if divine_seal and not healer:buff_active('Divine Seal') and healer:ready_to_use(divine_seal) then
					return {type='ability', action=divine_seal, name=player.name, emergency_cure=true}
				end
			end
		end
		if player and player.status == resting_status and is_emergency_cure(action.cure) then
			return action.cure
		end
		if (action.debuff ~= nil) and (action.debuff.action.en == 'Paralyna') and (action.debuff.name == healer.name) then
			return action.debuff
		elseif (action.debuff ~= nil) and ((action.debuff.prio + 2) < action.cure.prio) then
			return action.debuff
		elseif (action.buff ~= nil) and ((action.buff.prio + 2) < action.cure.prio) then
			return action.buff
		end
		return action.cure
	elseif (action.debuff ~= nil) then
		if (action.buff ~= nil) and (action.buff.prio < action.debuff.prio) then
			return action.buff
		end
		return action.debuff
	elseif (action.buff ~= nil) then
		return action.buff
	end
	return nil
end


function actions.take_action(player, partner, targ)
    buffs.checkOwnBuffs()
    local_queue_reset()
    local offensive_action
    local low_mp = player.vitals and player.vitals.mpp
        and player.vitals.mpp <= low_mp_rest_threshold
    local assisting_same_target = targ ~= nil and partner ~= nil
        and player.target_index == partner.target_index
    local independently_engaged = targ == nil and hb.modes.independent and player.status == 1
    if assisting_same_target or independently_engaged then
        offensive_action = actions.get_offensive_action(player)
    end
    local action = actions.get_defensive_action(offensive_action)
    if player.status == resting_status then
        -- Rest ticks are separated by about 10 seconds after the initial tick.
        -- Wait for the next tick unless a critical cure is needed; ordinary
        -- healing is allowed then only when its urgency justifies the MP spent.
        local now = os.clock()
        rest_tick_due_at = rest_tick_due_at or (now + 20 + rest_tick_margin)
        if not is_emergency_cure(action) then
            if now < rest_tick_due_at then return false end
            rest_tick_due_at = now + 10 + rest_tick_margin
            local mp_percent = player.vitals and player.vitals.mpp
            local cure_at_tick = action and action.type == 'cure'
                and action.hpp and mp_percent and action.hpp <= mp_percent
            if not cure_at_tick then return false end
        end
    else
        rest_tick_due_at = nil
    end
    if (action ~= nil) then         --If there's a defensive action to perform
        if stand_if_resting(player) then return true end
        --Record attempt time for buffs/debuffs
        buffs.buffList[action.name] = buffs.buffList[action.name] or {}
        if (action.type == 'buff') and (buffs.buffList[action.name][action.buff]) then
            buffs.buffList[action.name][action.buff].attempted = os.clock()
        elseif (action.type == 'debuff') then
            buffs.debuffList[action.name][action.debuff.id].attempted = os.clock()
        end
        healer:take_action(action)
        return true
    else                        --Otherwise, there may be an offensive action
        local action_taken = false
        if (targ ~= nil) or hb.modes.independent then
            local self_engaged = (player.status == 1)
            if (targ ~= nil) then
                local partner_engaged = (partner.status == 1)
                if (player.target_index == partner.target_index) then
                    if offense.assist.engage and partner_engaged and (not self_engaged) and not low_mp then
                        if stand_if_resting(player) then return true end
                        healer:send_cmd('input /attack on')
                        action_taken = true
                    else
                        if offensive_action then
                            if stand_if_resting(player) then return true end
                            healer:take_action(offensive_action, '<t>')
                            action_taken = true
                        end
                    end
                else                            --Different targets
                    if partner_engaged and (not self_engaged) then
                        if stand_if_resting(player) then return true end
                        healer:send_cmd('input /as '..offense.assist.name)
                        action_taken = true
                    end
                end
            elseif self_engaged and hb.modes.independent then
                if offensive_action then
                    if stand_if_resting(player) then return true end
                    healer:take_action(offensive_action, '<t>')
                    action_taken = true
                end
            end
            offense.cleanup()
        end
        return action_taken
    end
end


--[[
	Builds an action queue for offensive actions.
    Returns the action deemed most important at the time.
--]]
function actions.get_offensive_action(player)
	-- Offensive debuffs take precedence; weaponskills and nukes are considered
	-- only after no ready, affordable debuff is queued.
	player = player or windower.ffxi.get_player()
	-- The HUD's low-MP warning marks the reserve point: stop optional offense
	-- so an idle healer can recover instead of spending the last MP on damage.
	if player and player.vitals and player.vitals.mpp and player.vitals.mpp <= 10 then
		return nil
	end
	local target = windower.ffxi.get_mob_by_target()
    if target == nil then return nil end
    local action = {}
    
    --Prioritize debuffs over nukes/ws
    local dbuffq = offense.getDebuffQueue(player, target)
    while not dbuffq:empty() do
        local dbact = dbuffq:pop()
        local_queue_insert(dbact.action.en, target.name)
        if (action.db == nil) and healer:in_casting_range(target)
            and healer:ready_to_use(dbact.action) and has_enough_mp(dbact.action, true) then
            action.db = dbact
        end
    end
    
    local_queue_disp()
    if action.db ~= nil then
        return action.db
    end
    
    if (not settings.disable.ws) and (settings.ws ~= nil) and healer:ready_to_use(resources_lib.action_for(settings.ws.name)) then
        local sign = settings.ws.sign or '>'
        local hp = settings.ws.hp or 0
        local hp_ok = ((sign == '<') and (target.hpp <= hp)) or ((sign == '>') and (target.hpp >= hp))
        
        local partner_ok = true
        if (settings.ws.partner ~= nil) then
            local pname = settings.ws.partner.name
            local partner = ffxi.get_party_member(pname)
            if partner ~= nil then
                partner_ok = partner.tp >= settings.ws.partner.tp
                --partner_ok = partner.tp <= 500
            else
                partner_ok = false
                atc(123,'Unable to locate weaponskill partner '..pname)
            end
        end
        
        if (hp_ok and partner_ok) then
            return {action=resources_lib.action_for(settings.ws.name),name='<t>'}
        end
    elseif (not settings.disable.spam) and settings.spam.active and (settings.spam.name ~= nil) then
        local spam_action = resources_lib.action_for(settings.spam.name)
        if (target.hpp > 0) and healer:ready_to_use(spam_action) and healer:in_casting_range('<t>') then
            local _p_ok = (player.vitals.mp >= spam_action.mp_cost)
            if spam_action.tp_cost ~= nil then
                _p_ok = (_p_ok and (player.vitals.tp >= spam_action.tp_cost))
            end
            if _p_ok then
                return {action=spam_action,name='<t>'}
            else
                atcd('MP/TP not ok for '..settings.spam.name)
            end
        end
    end
    
    atcd('get_offensive_action: no offensive actions to perform')
	return nil
end

return actions
