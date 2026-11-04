local status_menu = {}

local options = {
    {
        label = function()
            return ('Curing: %s | %s'):format(settings.disable.cure and 'OFF' or 'ON', utils.singleTargetHealingStatus())
        end,
        toggle = function() disableCommand('cure', not settings.disable.cure) end,
    },
    {
        label = function() return ('Curaga: %s'):format(settings.disable.curaga and 'OFF' or 'ON') end,
        toggle = function() disableCommand('curaga', not settings.disable.curaga) end,
    },
    {
        label = function() return ('Status removal: %s'):format(settings.disable.na and 'OFF' or 'ON') end,
        toggle = function() disableCommand('na', not settings.disable.na) end,
    },
    {
        label = function() return ('Buffing: %s'):format(settings.disable.buff and 'OFF' or 'ON') end,
        toggle = function() disableCommand('buff', not settings.disable.buff) end,
    },
    {
        label = function() return ('Debuffing: %s'):format(settings.disable.debuff and 'OFF' or 'ON') end,
        toggle = function() disableCommand('debuff', not settings.disable.debuff) end,
    },
    {
        label = function()
            return ('Spell spam: %s'):format(settings.spam.active and not settings.disable.spam and 'ON' or 'OFF')
        end,
        toggle = function()
            local is_on = settings.spam.active and not settings.disable.spam
            if is_on then
                settings.spam.active = false
            else
                settings.disable.spam = false
                settings.spam.active = true
            end
            atc('Spell spam is now '..(settings.spam.active and 'on.' or 'off.'))
        end,
    },
    {
        label = function()
            local ws = settings.ws or {}
            local state = not ws.name and 'NOT SET' or (settings.disable.ws and ('OFF ('..ws.name..')') or ws.name)
            return ('Weaponskills: %s'):format(state)
        end,
        toggle = function()
            local ws = settings.ws or {}
            if ws.name then
                disableCommand('ws', not settings.disable.ws)
            else
                atc('Set a weaponskill first with //hb ws use <name>.')
            end
        end,
    },
    {
        label = function()
            local target = offense.assist.name
            local state = not target and 'NO TARGET' or (offense.assist.active and target or ('OFF ('..target..')'))
            return ('Assist: %s'):format(state)
        end,
        toggle = function()
            if offense.assist.name then
                offense.assist.active = not offense.assist.active
                atc('Assist is now '..(offense.assist.active and 'on.' or 'off.'))
            else
                atc('Set an assist target first with //hb assist <player>.')
            end
        end,
    },
    {
        label = function() return ('Auto-engage: %s'):format(offense.assist.engage and 'ON' or 'OFF') end,
        toggle = function()
            offense.assist.engage = not offense.assist.engage
            atc('Auto-engage is now '..(offense.assist.engage and 'on.' or 'off.'))
        end,
    },
    {
        label = function()
            local target = settings.follow.target
            local state = not target and 'NO TARGET' or (settings.follow.active and target or ('OFF ('..target..')'))
            return ('Follow: %s | distance %sy'):format(state, tostring(settings.follow.distance or 3))
        end,
        toggle = function()
            if settings.follow.target then
                settings.follow.active = not settings.follow.active
                atc('Follow is now '..(settings.follow.active and 'on.' or 'off.'))
            else
                atc('Set a follow target first with //hb follow <player>.')
            end
        end,
    },
    {
        label = function() return ('Ignore Trusts: %s'):format(settings.ignoreTrusts and 'ON' or 'OFF') end,
        toggle = function()
            settings.ignoreTrusts = not settings.ignoreTrusts
            hb.refreshMonitoredPlayers()
            atc('Ignoring Trusts is now '..(settings.ignoreTrusts and 'on.' or 'off.'))
        end,
    },
}

function status_menu:size()
    return #options
end

function status_menu:text()
    local lines = {}
    for index, option in ipairs(options) do
        lines[index] = ('  %d. %s'):format(index, option.label())
    end
    return table.concat(lines, '\n')
end

function status_menu:toggle(index)
    local option = options[index]
    if option then
        option.toggle()
        utils.save_settings()
    end
end

return status_menu
