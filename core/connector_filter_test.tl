--- The actual endpoint-connector filter on both Linux architectures.
local type raw_process = require("cosmic.internal.process")
local type _ = require("cosmic.child")
local type Searcher = function(string): any, any
local function process_table(): raw_process
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: the raw table is the loader's extra
    local loader, extra = searcher("cosmic.child")
    if type(loader) == "function" and type(extra) == "table" then
      return extra as raw_process -- cast: core/process.h declares the handed table
    end
  end
  error("no process table")
end
local process = process_table()
local ALLOW <const> = 0x7fff0000
local REFUSE <const> = 0x50001
local KILL <const> = 0x80000000
local BASE <const> = 0x1122334400000800
local CONTROL <const> = 300
local STATUS <const> = 301
local arches: {string} = { "x86_64", "aarch64" }
local audit: {string: integer} = { x86_64 = 0xc000003e, aarch64 = 0xc00000b7 }
local numbers: {string: {integer}} = {
  read = { 0, 63 }, write = { 1, 64 }, close = { 3, 57 }, socket = { 41, 198 },
  connect = { 42, 203 }, getsockopt = { 55, 209 }, sendmsg = { 46, 211 },
  poll = { 7, -1 }, ppoll = { 271, 73 }, clock = { 228, 113 },
  exit = { 60, 93 }, exit_group = { 231, 94 },
}
local type Insn = record
  code: integer
  jt: integer
  jf: integer
  k: integer
end
local function decode(program: string): {Insn}
  assert(#program > 0 and #program % 8 == 0 and #program // 8 <= 4096)
  local out: {Insn} = {}
  for at = 1, #program, 8 do
    local code, jt, jf, k = string.unpack("<I2I1I1I4", program, at)
    out[#out + 1] = { code = code, jt = jt, jf = jf, k = k }
  end
  return out
end
local function run(code: {Insn}, architecture: integer, number: integer, args: {integer}): integer
  local function word(offset: integer): integer
    if offset == 0 then return number & 0xffffffff end
    if offset == 4 then return architecture end
    assert(offset >= 16 and offset < 64 and offset % 4 == 0)
    local value = args[(offset - 16) // 8 + 1] or 0
    return offset % 8 == 0 and value & 0xffffffff or (value >> 32) & 0xffffffff
  end
  local pc, a = 1, 0
  while true do
    local insn = code[pc]
    assert(insn ~= nil, "a filter path fell off its end")
    pc = pc + 1
    if insn.code == 0x20 then
      a = word(insn.k)
    elseif insn.code == 0x54 then
      a = a & insn.k
    elseif insn.code == 0x05 then
      pc = pc + insn.k
    elseif insn.code == 0x15 then
      pc = pc + (a == insn.k and insn.jt or insn.jf)
    elseif insn.code == 0x35 then
      pc = pc + (a >= insn.k and insn.jt or insn.jf)
    elseif insn.code == 0x06 then
      return insn.k
    else
      error("unknown filter instruction " .. insn.code)
    end
  end
end
local function filter(architecture: string): {Insn}
  return decode(process.connector_filter(architecture, {
    { base = BASE, slots = 4, length = 16 },
    { base = BASE + 4096, slots = 65535, length = 28 },
  }, CONTROL, STATUS))
end
local V4 <const> = 16
local V6 <const> = 32
local function test_connect_accepts_only_whole_immutable_slots_with_exact_sizes()
  for i, architecture in ipairs(arches) do
    local code = filter(architecture)
    local function connect(pointer: integer, length: integer): integer
      return run(code, audit[architecture], numbers.connect[i], { 5, pointer, length })
    end
    for slot = 0, 3 do
      assert(connect(BASE + V4 * slot, 16) == ALLOW)
    end
    for _, pointer in ipairs({ BASE - V4, BASE - 1, BASE + 1, BASE + 8, BASE + 15, BASE + 4 * V4,
        BASE + (1 << 32), BASE - (1 << 32) }) do
      assert(connect(pointer, 16) == REFUSE)
    end
    for _, length in ipairs({ 0, 15, 17, 28, 16 + (1 << 32), -1 }) do
      assert(connect(BASE, length) == REFUSE)
    end
    assert(connect(BASE + 4096, 28) == ALLOW)
    assert(connect(BASE + 4096 + 65534 * V6, 28) == ALLOW)
    assert(connect(BASE + 4096 + 65535 * V6, 28) == REFUSE)
    assert(connect(BASE + 4096, 16) == REFUSE)
    assert(run(code, 0x40000003, numbers.connect[i], { 5, BASE, 16 }) == KILL)
    assert(run(code, audit[architecture], numbers.connect[i] | 0x40000000, { 5, BASE, 16 }) == REFUSE)
  end
end
local function test_a_slot_is_held_to_its_own_ranges_stride_and_length()
  for i, architecture in ipairs(arches) do
    local code = filter(architecture)
    local function connect(pointer: integer, length: integer): integer
      return run(code, audit[architecture], numbers.connect[i], { 5, pointer, length })
    end
    -- Into the other range: an IPv6 slot at the IPv4 length, and the reverse.
    assert(connect(BASE + 4096, 16) == REFUSE)
    assert(connect(BASE + 4096 + V6, 16) == REFUSE)
    assert(connect(BASE, 28) == REFUSE)
    assert(connect(BASE + V4, 28) == REFUSE)
    -- Aligned to the IPv4 stride but not to the IPv6 one.
    assert(connect(BASE + 4096 + V4, 28) == REFUSE)
    assert(connect(BASE + 4096 + V6 + V4, 28) == REFUSE)
    assert(connect(BASE + 4096 + 3 * V6 + 1, 28) == REFUSE)
    -- Between the ranges, and past the last slot of each.
    assert(connect(BASE + 4 * V4, 16) == REFUSE)
    assert(connect(BASE + 2048, 28) == REFUSE)
    assert(connect(BASE + 4096 + 65535 * V6, 28) == REFUSE)
    -- A pointer whose low 32 bits are right in another 4 GiB.
    assert(connect(BASE + 4096 + (1 << 32), 28) == REFUSE)
  end
end
local function test_only_tcp_creation_and_protected_ipc_descriptor_sends_are_allowed()
  for i, architecture in ipairs(arches) do
    local code = filter(architecture)
    for _, family in ipairs({ 2, 10 }) do
      assert(run(code, audit[architecture], numbers.socket[i], { family, 0x80801, 6 }) == ALLOW)
    end
    for _, args in ipairs({ { 1, 0x80801, 6 }, { 2, 0x80802, 17 }, { 2, 0x80801, 0 },
        { 2, 1, 6 }, { 2 + (1 << 32), 0x80801, 6 }, { 2, 0x80801 + (1 << 32), 6 } }) do
      assert(run(code, audit[architecture], numbers.socket[i], args) == REFUSE)
    end
    assert(run(code, audit[architecture], numbers.sendmsg[i], { CONTROL, 1234, 0x4000 }) == ALLOW)
    for _, args in ipairs({ { 5, 1234, 0x4000 }, { STATUS, 1234, 0x4000 },
        { CONTROL + (1 << 32), 1234, 0x4000 }, { CONTROL, 1234, 0x20004000 }, { CONTROL, 1234, 0 } }) do
      assert(run(code, audit[architecture], numbers.sendmsg[i], args) == REFUSE)
    end
    assert(run(code, audit[architecture], numbers.close[i], { CONTROL }) == KILL)
    assert(run(code, audit[architecture], numbers.close[i], { 5 }) == ALLOW)
    assert(run(code, audit[architecture], numbers.read[i], { CONTROL }) == ALLOW)
    assert(run(code, audit[architecture], numbers.read[i], { STATUS }) == REFUSE)
    assert(run(code, audit[architecture], numbers.write[i], { CONTROL }) == ALLOW)
    assert(run(code, audit[architecture], numbers.write[i], { STATUS }) == ALLOW)
    assert(run(code, audit[architecture], numbers.write[i], { 5 }) == REFUSE)
    assert(run(code, audit[architecture], numbers.getsockopt[i], { 5, 1, 4 }) == ALLOW)
    assert(run(code, audit[architecture], numbers.getsockopt[i], { 5, 1, 30 }) == REFUSE)
  end
end
local function test_every_call_outside_the_explicit_allowlist_is_refused()
  for i, architecture in ipairs(arches) do
    local code = filter(architecture)
    local allowed: {integer: boolean} = {}
    for _, by_arch in pairs(numbers) do
      if by_arch[i] >= 0 then allowed[by_arch[i]] = true end
    end
    for number = 0, 1024 do
      if not allowed[number] then
        assert(run(code, audit[architecture], number, { CONTROL, BASE, 16 }) == REFUSE,
          architecture .. " unexpectedly allowed syscall " .. number)
      end
    end
  end
end
local function test_invalid_filter_inputs_are_refused()
  for _, ranges in ipairs({
      {} as {raw_process.ConnectorRange},
      { { base = BASE + 1, slots = 1, length = 16 } },
      { { base = BASE + 16, slots = 1, length = 28 } },
      { { base = BASE, slots = 0, length = 16 } },
      { { base = BASE, slots = 1, length = 128 } },
      { { base = 0x11223344ffffff80, slots = 9, length = 16 } },
      { { base = 0x11223344ffffff80, slots = 5, length = 28 } },
  }) do
    local ok = pcall(process.connector_filter, "x86_64", ranges, CONTROL, STATUS)
    assert(not ok)
  end
end
