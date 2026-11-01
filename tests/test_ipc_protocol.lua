local protocol = dofile('addons/HealBot/HealBot_ipc.lua')

local request = protocol.decode(protocol.encode_request())
assert(request.method == 'GET' and request.pk == 'buff_ids')

local encoded = protocol.encode_response({
    id=1234, spawn_type=1, name='TestPlayer', buffs={4, 2, 7}
})
local response = protocol.decode(encoded)
assert(response.method == 'POST' and response.pk == 'buff_ids')
assert(response.pid == 1234 and response.spawn_type == 1)
assert(response.name == 'TestPlayer' and #response.val == 3)
assert(response.val[1] == 2 and response.val[2] == 4 and response.val[3] == 7)

assert(protocol.decode('return os.execute("bad")') == nil)
assert(protocol.decode('POST|buff_ids|1|1|TestPlayer|2); os.execute("bad")') == nil)
assert(protocol.decode('GET|buff_ids|os.execute') == nil)
assert(protocol.decode('POST|buff_ids|1|1|TestPlayer|2,,4') == nil)
assert(protocol.decode('POST|buff_ids|x|1|TestPlayer|2,4') == nil)
assert(protocol.decode('POST|buff_ids|1|1|TestPlayer|65536') == nil)
assert(protocol.decode('POST|buff_ids|1|1|TestPlayer|2|extra') == nil)
assert(protocol.encode_response({id=1234, spawn_type=1, name='bad|name', buffs={4}}) == nil)
assert(protocol.decode(string.rep('x', 2049)) == nil)

print('HealBot IPC protocol checks passed')
