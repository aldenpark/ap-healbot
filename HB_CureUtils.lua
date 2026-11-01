--==============================================================================
--[[
    Author: Alden Park
    HealBot cure handling functions
--]]
--==============================================================================

local cu = {cure_types={'cure','waltz','curaga','waltzga'} }
local Pos = _libs.ffxi.position
local ffxi = _libs.ffxi.ffxi

--==============================================================================
--                  Static Cure Information
--==============================================================================
cu.cure = {
    [1] = {id=1,    en='Cure',              res=res.spells[1]},
    [2] = {id=2,    en='Cure II',           res=res.spells[2]},
    [3] = {id=3,    en='Cure III',          res=res.spells[3]},
    [4] = {id=4,    en='Cure IV',           res=res.spells[4]},
    [5] = {id=5,    en='Cure V',            res=res.spells[5]},
    [6] = {id=6,    en='Cure VI',           res=res.spells[6]}
}
cu.curaga = {
    [1] = {id=7,    en='Curaga',            res=res.spells[7]},
    [2] = {id=8,    en='Curaga II',         res=res.spells[8]},
    [3] = {id=9,    en='Curaga III',        res=res.spells[9]},
    [4] = {id=10,   en='Curaga IV',         res=res.spells[10]},
    [5] = {id=11,   en='Curaga V',          res=res.spells[11]}
}
cu.waltz = {
    [1] = {id=190,  en='Curing Waltz',      res=res.job_abilities[190]},
    [2] = {id=191,  en='Curing Waltz II',   res=res.job_abilities[191]},
    [3] = {id=192,  en='Curing Waltz III',  res=res.job_abilities[192]},
    [4] = {id=193,  en='Curing Waltz IV',   res=res.job_abilities[193]},
    [5] = {id=311,  en='Curing Waltz V',    res=res.job_abilities[311]}
}
cu.waltzga = {
    [1] = {id=195,  en='Divine Waltz',      res=res.job_abilities[195]},
    [2] = {id=262,  en='Divine Waltz II',   res=res.job_abilities[262]}
}

function cu.init_cure_potencies()
    -- Potency is character/job configurable because gear, traits, and job
    -- abilities change how much each tier heals.
    local potency_table = hb.config.cure_potency[healer.name] and hb.config.cure_potency[healer.name][healer.main_job] or hb.config.cure_potency.default
    for spell_group,_ in pairs(potency_table) do
        for spell_tier,_ in pairs(cu[spell_group]) do
            cu[spell_group][spell_tier].hp = potency_table[spell_group][spell_tier]
        end
    end
end


function cu.getDangerLevel(hpp)
    if (hpp <= 20) then
        return 3
    elseif (hpp <= 40) then
        return 2
    elseif (hpp <= 60) then
        return 1
    end
    return 0
end


--[[
    Returns a table with party members and how much hp they are missing
--]]
function cu.get_missing_hps()
    local targets = hb.getMonitoredPlayers()
    local hpTable = {}
    for _,trg in pairs(targets) do
        local hpMissing = 0
        if (trg.hp ~= nil) then
            hpMissing = math.ceil((trg.hp/(trg.hpp/100))-trg.hp)
        else --If the player doesn't have a hp field, guesstimate how much they are missing
            hpMissing = 1500 - math.ceil((trg.hpp/100)*1500)
        end
        hpTable[trg.name] = {['missing']=hpMissing, ['hpp']=trg.hpp}
    end
    return hpTable
end


function cu.injured_pt_members()
    -- Curaga coverage only considers actual party members; monitored trusts
    -- remain eligible for single-target cures but are not spatially clustered.
    local party_members = ffxi.party_member_names()
    local injured = {}
    for _,trg in pairs(hb.getMonitoredPlayers()) do
        if trg.hpp < 95 and party_members:contains(trg.name) then
            local _hp = trg.hp or 1500   --Guesstimate if no value available
            local _missing
            if trg.hp ~= nil then
                _missing = math.ceil(((_hp/(trg.hpp/100))) - _hp)
            else
                _missing = _hp - math.ceil((trg.hpp/100)*_hp)
            end
            injured[trg.name] = {
                name = trg.name, hp = _hp, missing = _missing, hpp = trg.hpp,
                pos = Pos.of(trg.name),
                danger = cu.getDangerLevel(trg.hpp)
            }
        end
    end
    return injured
end


function cu.get_weighted_curaga_hp(members_info, names)
    -- Weight low-HP members more heavily so a Curaga choice responds to danger,
    -- rather than letting several healthy members dilute one urgent injury.
    local hp, missing, c = 0, 0, 0
    local name_set = S(names)
    for name, minfo in pairs(members_info) do
        if name_set:contains(name) then
            local d = minfo.danger + 1
            missing = missing + (minfo.missing * d)
            hp = hp + (minfo.hp * d)
            c = c + d
        end
    end
    return missing / c, hp / c
end


local function cure_is_worth_the_mp(hp_missing, cure_type, lowest_hpp)
    -- Keep critical injuries eligible, but avoid spending a full Cure/Curaga
    -- cost to replace a small fraction of the spell's minimum-tier healing.
    if lowest_hpp and lowest_hpp <= 40 then return true end
    if cure_type ~= 'cure' and cure_type ~= 'curaga' then return true end

    local minimum = cu.minimum_tier(cure_type)
    local potency = cu[cure_type][minimum] and cu[cure_type][minimum].hp
    if not potency or potency <= 0 then return true end

    local player = windower.ffxi.get_player()
    local mp_percent = player and player.vitals and player.vitals.mpp or 100
    -- Raise the useful-healing threshold as MP falls: half a minimum-tier heal
    -- at full MP, and a full minimum-tier heal once MP is at or below 50%.
    local useful_fraction = math.min(1, 0.5 + (math.max(0, 100 - mp_percent) * 0.01))
    return hp_missing >= potency * useful_fraction
end


function cu.pick_best_curaga_possibility()
    -- Try each injured member as a cast center, then favor the largest group
    -- inside Curaga range. Distance breaks ties before healing need is scored.
    local too_few = settings.healing.curaga_min_targets
    local members = cu.injured_pt_members()
    local member_count = sizeof(members)
    if member_count < too_few then return nil end
    local best = {}
    local coverage, distances = LT(), LT()
    for memberA, a in pairs(members) do
        if a then
            coverage[memberA] = LT{memberA}
            distances[memberA] = LT()
            for memberB, b in pairs(members) do
                if b then
                    if memberA ~= memberB then
                        local dist = a.pos:getDistance(b.pos)
                        distances[memberA]:insert(dist)
                        if dist < 10 then
                            coverage[memberA]:insert(memberB)
                        end
                    end
                end
            end
            local furthest = distances[memberA]:max()
            local avg_dist = distances[memberA]:sum() / distances[memberA]:size()
            local farA = {memberA, furthest}
            local avgA = {memberA, avg_dist}
            local covA = {memberA, coverage[memberA]}
            best.far = best.far or farA
            best.far = (furthest < best.far[2]) and farA or best.far
            best.avg = best.avg or avgA
            best.avg = (avg_dist < best.avg[2]) and avgA or best.avg
            best.cov = best.cov or covA
            best.cov = (coverage[memberA]:size() > best.cov[2]:size()) and covA or best.cov
            if furthest < 10 then break end    --This center already covers everyone.
        end
    end
    if best.cov[2]:size() < too_few then return nil end
    local best_cov_count = best.cov[2]:size()
    local best_target
    if coverage[best.far[1]]:size() == best_cov_count then
        best_target = best.far[1]
    elseif coverage[best.avg[1]]:size() == best_cov_count then
        best_target = best.avg[1]
    else
        best_target = best.cov[1]
    end
    local w_missing, w_hpp = cu.get_weighted_curaga_hp(members, coverage[best_target])
    local tier = cu.get_cure_tier_for_hp(w_missing, settings.healing.modega)
    local min_hpp = 100
    for _,name in pairs(coverage[best_target]) do
        min_hpp = min(min_hpp, members[name].hpp)
    end
    if not cure_is_worth_the_mp(w_missing, settings.healing.modega, min_hpp) then
        return nil
    end
    min_hpp = min_hpp * 0.7 --add extra weight
    local target = {name=best_target, missing=w_missing, hpp=min_hpp}
    return cu.get_usable_cure(tier, settings.healing.modega), target
end


function cu.get_cure_queue()
    -- Queue only meaningful HP deficits; tier selection estimates the missing
    -- HP first, then availability/cooldown checks can step down to a usable spell.
    local cq = ActionQueue.new()
    local hp_table = cu.get_missing_hps()
    for name,p in pairs(hp_table) do
        if p.hpp < 95 and cure_is_worth_the_mp(p.missing, settings.healing.mode, p.hpp) then
            local tier = cu.get_cure_tier_for_hp(p.missing, settings.healing.mode)
            if tier >= settings.healing.min[settings.healing.mode] then
                local spell = cu.get_usable_cure(tier, settings.healing.mode)
                if spell ~= nil then
                    cq:enqueue('cure', spell, name, p.hpp, (' (%s)'):format(p.missing))
                end
            end
        end
    end
    if (not settings.disable.curaga) and (settings.healing.max[settings.healing.modega] > 0) then
        local spell, p = cu.pick_best_curaga_possibility()
        if spell ~= nil then
            cq:enqueue('cure', spell, p.name, p.hpp, (' (%s)'):format(p.missing))
        end
    end
    return cq:getQueue()
end

--[[
    Determines the MP/TP multiplier in effect for the given cure_type based on job and active buffs.
--]]
function cu.get_multiplier(cure_type)
    local mult = 1
    if cure_type:startswith('waltz') then
        if healer:buff_active('Trance') then
            mult = 0
        end
    else --it starts with 'cur'
        local p = windower.ffxi.get_player()
        if (p.main_job == 'BLM') and healer:buff_active('Manafont') then
            mult = 0
        elseif healer:buff_active('Manawell') then
            mult = 0
        elseif S{p.main_job, p.sub_job}:contains('SCH') then
            if healer:buff_active('Light Arts','Addendum: White') then
                mult = healer:buff_active('Penury') and 0.5 or 0.9
            elseif healer:buff_active('Dark Arts','Addendum: Black') then
                mult = 1.1
            end
        end
    end
    return mult
end


--[[
    Determines the tier of cure_type to use for the given amount of missing HP.
    Whether or not to accept this tier, based on settings.healing.min[cure_type], is handled elsewhere.
--]]
function cu.get_cure_tier_for_hp(hp_missing, cure_type)
    -- Start at the configured ceiling and step down while the next lower tier
    -- is predicted to cover the deficit. minimum_tier enforces the two-tier cap.
    local tier = settings.healing.max[cure_type]
    local min_tier = cu.minimum_tier(cure_type)
    while tier > min_tier and cu[cure_type][tier-1].hp >= hp_missing do
        tier = tier - 1
    end
    return tier
end


function cu.minimum_tier(cure_type)
    -- For direct Cure spells, keep the configured minimum at most one tier below
    -- the highest learned tier, so low-tier spells are not selected unnecessarily.
    local minimum = settings.healing.min[cure_type] or 1
    local maximum = settings.healing.max[cure_type] or 0
    if cure_type == 'cure' and maximum > 0 then
        minimum = math.max(minimum, math.max(1, maximum - 1))
    end
    return minimum
end


--[[
    Returns resource info for the chosen cure/waltz tier
--]]
function cu.get_usable_cure(orig_tier, cure_type)
    -- If the preferred tier is unaffordable or cooling down, try lower allowed
    -- tiers until one is ready; never cross the configured minimum.
    local min_tier = cu.minimum_tier(cure_type)
    if orig_tier < min_tier then return nil end
    
    local player = windower.ffxi.get_player()
    local mult = cu.get_multiplier(cure_type)
    local _p, recasts
    if cure_type:startswith('waltz') then
        _p = 'tp'
        recasts = windower.ffxi.get_ability_recasts()
    else --it starts with 'cur'
        _p = 'mp'
        recasts = windower.ffxi.get_spell_recasts()
    end
    
    local tier = orig_tier
    while tier >= min_tier do
        local action = cu[cure_type][tier].res
        local rctime = recasts[action.recast_id] or 0               --Cooldown remaining for current tier
        local mod_cost = action[_p..'_cost'] * mult                 --Modified cost of current tier in MP/TP
        if (mod_cost <= player.vitals[_p]) and (rctime == 0) then   --Sufficient MP/TP and cooldown is ready
            return action
        end
        tier = tier - 1
    end
    return nil
end


--[[
    Returns the tier of the highest usable spell of type cure_type
--]]
function cu.highest_tier(cure_type)
    local highest = 0
    for tier,spell in pairs(cu[cure_type]) do
        if healer:can_use(spell.res) then
            highest = (tier > highest) and tier or highest
        end
    end
    return highest
end


return cu
