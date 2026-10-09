--- Net.resolve against a name server of the test's own. A lookup holds
--- its thread until it is answered, so it runs in a process of its own
--- (this program, standalone), and this one is the server on a loopback
--- port, which answers canned records and sees each query as sent.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local _ = require("cosmic.net") -- in the closure: the scripts require it
local Poll = require("cosmic.poll")
local sys = require("cosmic.sys")
local this_program = require("build.this_program")
local Test = require("cosmic.test")
local Udp = require("build.udp_fixture")
local _ = require("build.standalone")

--- The program itself, which runs the lookup; a loopback alone answers.
Test.policy{ profiles = { "cosmic" }, loopback = { "127.0.0.1" } }

local TYPE_A <const> = 1
local TYPE_AAAA <const> = 28

--- One record of an answer.
local record Record
  type: integer
  data: string
end

--- What the server answers a query for `name` of type `qtype`: nil sends
--- nothing, else a response code and its records.
local record Reply
  rcode: integer
  records: {Record}
end

local function v4(a: integer, b: integer, c: integer, d: integer): Record
  return { type = TYPE_A, data = string.char(a, b, c, d) }
end

local function v6(a: integer, b: integer, c: integer, d: integer,
                  e: integer, f: integer, g: integer, h: integer): Record
  return { type = TYPE_AAAA, data = string.pack(">I2I2I2I2I2I2I2I2", a, b, c, d, e, f, g, h) }
end

--- The name and type a query asks, or nil for a message that is none.
local function question(query: string): string, integer, integer
  local labels: {string} = {}
  local at = 13
  while true do
    local size = query:byte(at)
    if size == nil then return nil, 0, 0 end
    if size == 0 then break end
    labels[#labels + 1] = query:sub(at + 1, at + size)
    at = at + size + 1
  end
  local qtype = string.unpack(">I2", query, at + 1)
  return table.concat(labels, "."), qtype, at + 4
end

--- The response to `query` that says `reply`.
local function response(query: string, reply: Reply, question_end: integer): string
  local id = string.unpack(">I2", query)
  local records = reply.records
  local parts: {string} = {
    string.pack(">I2I2I2I2I2I2", id, 0x8180 | reply.rcode, 1, #records, 0, 0),
    query:sub(13, question_end),
  }
  for _, record in ipairs(records) do
    parts[#parts + 1] = string.pack(">I2I2I2I4s2", 0xC00C, record.type, 1, 60, record.data)
  end
  return table.concat(parts)
end

--- Prints what [`Net.resolve`] made of argv: the name, the port of the
--- server (or "" for the system's), the timeout in milliseconds.
local SCRIPT <const> = [[
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
return function(argv: {string}): integer
  local opts: Net.ResolveOptions = { timeout_ns = Clock.ms(assert(math.tointeger(argv[3]))) }
  if argv[2] ~= "" then
    opts.servers = { { host = "127.0.0.1", port = assert(math.tointeger(argv[2])) } }
  end
  local found, why = Net.resolve(argv[1], opts)
  local lines: {string} = {}
  for _, resolved in ipairs(found or {}) do lines[#lines + 1] = resolved.family .. " " .. resolved.address end
  table.sort(lines)
  if found == nil then lines[1] = "error " .. why end
  Fs.put(Fs.stdout, table.concat(lines, "\n"))
  return 0
end
]]

--- The same under a guard that a SIGINT, sent once the server has seen
--- a query, ends the wait of: prints what it answered.
local GUARDED <const> = [[
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Signal = require("cosmic.signal")
return function(argv: {string}): integer
  local guard = assert(Signal.guard())
  local found, why = Net.resolve(argv[1],
    { servers = { { host = "127.0.0.1", port = assert(math.tointeger(argv[2])) } } })
  Fs.put(Fs.stdout, found == nil and "error " .. why or "found")
  assert(guard:release())
  return 0
end
]]

--- What `Net.resolve(name)` answers, as the lines the child printed,
--- against a server that answers each query as `serve` says, and the
--- "type name" of each query the server saw.
local function lookup(tmp: string, name: string, timeout_ms: integer,
                      serve: function(string, integer): Reply,
                      guarded?: boolean): {string}, {string}
  local script = tmp .. "/resolve.tl"
  assert(Fs.write(script, guarded and GUARDED or SCRIPT))
  local server <close> = assert(Udp.bind("127.0.0.1", 0))
  local started = this_program.program({ "--standalone", script, name,
    tostring(server.address.port), tostring(timeout_ms) },
    { stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60) })
  local child <close> = assert(Child.start(started.argv, started.options))
  local seen: {string} = {}
  local result: Child.Result
  while result == nil do
    local state = assert(child:try_wait())
    if state.finished then
      result = state.result
    else
      local packet, why = Udp.receive(server, Clock.ms(20))
      if packet ~= nil then
        local asked, qtype, question_end = question(packet.data)
        assert(asked ~= nil, "a malformed query")
        seen[#seen + 1] = qtype .. " " .. asked
        if guarded and #seen == 1 then assert(child:stop(sys.SIGINT)) end
        local reply = serve(asked, qtype)
        if reply ~= nil then
          assert(Udp.send(server, response(packet.data, reply, question_end), packet.address))
        end
      else
        assert(why == Poll.TIMEOUT, why)
      end
    end
  end
  assert(result.code == 0, tostring(result.code) .. " " .. tostring(result.stderr))
  local lines: {string} = {}
  for line in ((result.stdout or "") .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
  table.sort(seen)
  return lines, seen
end

local function test_every_address_of_both_families_is_answered_unfiltered(tmp: string)
  local lines, seen = lookup(tmp, "many.example.test", 20000, function(_: string, qtype: integer): Reply
    if qtype == TYPE_A then
      return { rcode = 0, records = { v4(10, 0, 0, 1), v4(127, 0, 0, 1), v4(169, 254, 169, 254), v4(93, 184, 216, 34) } }
    end
    return { rcode = 0, records = { v6(0, 0, 0, 0, 0, 0, 0, 1), v6(0x2606, 0x2800, 0x220, 1, 0x248, 0x1893, 0x25c8, 0x1946),
      v6(0xfe80, 0, 0, 0, 0, 0, 0, 1) } }
  end)
  assert(table.concat(lines, ",") == table.concat({
    "ipv4 10.0.0.1", "ipv4 127.0.0.1", "ipv4 169.254.169.254", "ipv4 93.184.216.34",
    "ipv6 2606:2800:220:1:248:1893:25c8:1946", "ipv6 ::1", "ipv6 fe80::1",
  }, ","), table.concat(lines, ","))
  assert(table.concat(seen, ",") == "1 many.example.test,28 many.example.test", table.concat(seen, ","))
end

local function test_one_family_alone_is_answered_when_the_other_has_no_records(tmp: string)
  local lines = lookup(tmp, "v6only.example.test", 20000, function(_: string, qtype: integer): Reply
    if qtype == TYPE_A then return { rcode = 0, records = {} } end
    return { rcode = 0, records = { v6(0x2001, 0xdb8, 0, 0, 0, 0, 0, 5) } }
  end)
  assert(table.concat(lines, ",") == "ipv6 2001:db8::5", table.concat(lines, ","))
end

local function test_a_name_that_does_not_exist_is_not_found(tmp: string)
  local lines = lookup(tmp, "missing.example.test", 20000, function(): Reply
    return { rcode = 3, records = {} }
  end)
  assert(lines[1] == "error name not found", lines[1])
end

local function test_a_name_with_no_address_says_so(tmp: string)
  local lines = lookup(tmp, "empty.example.test", 20000, function(): Reply
    return { rcode = 0, records = {} }
  end)
  assert(lines[1] == "error name has no address", lines[1])
end

local function test_a_failing_server_is_a_failure_not_an_answer(tmp: string)
  local lines = lookup(tmp, "broken.example.test", 20000, function(): Reply
    return { rcode = 2, records = {} }
  end)
  assert(lines[1] == "error name server failed", lines[1])
end

local function test_a_server_that_never_answers_times_out(tmp: string)
  local lines, seen = lookup(tmp, "silent.example.test", 400, function(): Reply return nil end)
  assert(lines[1] == "error " .. Poll.TIMEOUT, lines[1])
  assert(#seen >= 1, "the server was never asked")
end

local function test_one_family_failing_leaves_the_addresses_of_the_other(tmp: string)
  local lines = lookup(tmp, "half.example.test", 20000, function(_: string, qtype: integer): Reply
    if qtype == TYPE_A then return { rcode = 0, records = { v4(192, 0, 2, 9) } } end
    return { rcode = 2, records = {} }
  end)
  assert(table.concat(lines, ",") == "ipv4 192.0.2.9", table.concat(lines, ","))
end

local function test_a_caught_signal_ends_a_lookup_that_waits(tmp: string)
  local lines = lookup(tmp, "stalled.example.test", 20000, function(): Reply return nil end, true)
  assert(lines[1] == "error interrupted", lines[1])
end
