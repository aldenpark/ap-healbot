local protocol = {}

local max_message_length = 2048
local max_buff_count = 256

local function integer_in_range(value, min_value, max_value)
    return type(value) == 'number'
        and value == math.floor(value)
        and value >= min_value
        and value <= max_value
end

function protocol.encode_request()
    return 'GET|buff_ids'
end

function protocol.encode_response(player)
    if type(player) ~= 'table'
        or not integer_in_range(player.id, 1, 4294967295)
        or not integer_in_range(player.spawn_type or 0, 0, 255)
        or type(player.name) ~= 'string'
        or #player.name > 32
        or not player.name:match('^[%w_%-]+$')
        or type(player.buffs) ~= 'table' then
        return nil
    end

    local buff_ids = {}
    for _, id in pairs(player.buffs) do
        if not integer_in_range(id, 0, 65535) or #buff_ids >= max_buff_count then
            return nil
        end
        buff_ids[#buff_ids + 1] = tostring(id)
    end
    table.sort(buff_ids)

    local message = ('POST|buff_ids|%d|%d|%s|%s'):format(
        player.id,
        player.spawn_type or 0,
        player.name,
        table.concat(buff_ids, ',')
    )
    if #message > max_message_length then
        return nil
    end
    return message
end

function protocol.decode(message)
    if type(message) ~= 'string' or #message > max_message_length then
        return nil
    end

    if message == 'GET|buff_ids' then
        return {method='GET', pk='buff_ids'}
    end

    local pid, spawn_type, name, ids = message:match('^POST|buff_ids|(%d+)|(%d+)|([%w_%-]+)|(.*)$')
    if pid == nil then
        return nil
    end

    pid = tonumber(pid)
    spawn_type = tonumber(spawn_type)
    if not integer_in_range(pid, 1, 4294967295)
        or not integer_in_range(spawn_type, 0, 255)
        or #name > 32 then
        return nil
    end

    local buff_ids = {}
    if ids ~= '' then
        for id in (ids .. ','):gmatch('(.-),') do
            if not id:match('^%d+$')
                or #buff_ids >= max_buff_count then
                return nil
            end
            local buff_id = tonumber(id)
            if not integer_in_range(buff_id, 0, 65535) then
                return nil
            end
            buff_ids[#buff_ids + 1] = buff_id
        end
    end

    return {
        method='POST', pk='buff_ids', pid=pid, spawn_type=spawn_type,
        name=name, val=buff_ids
    }
end

return protocol
