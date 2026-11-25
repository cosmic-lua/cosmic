--- A relay behind an upstream its starter resolved once: the upstream's
--- host is looked up once however many connections go through it, a name
--- no grant opens is never looked up, and a granted one is. A relay whose
--- lookups go to a name server of this test's own holds its thread while
--- it looks up, so it runs in a process of its own (this program, running
--- a child of build.relay_children_test) while this one is the name server,
--- on a loopback port it binds for UDP, to see each query.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Poll = require("cosmic.poll")
local Test = require("cosmic.test")
local Udp = require("build.udp_fixture")
local _ = require("build.relay_children_test")
local test_child = require("build.test_child")
local this_program = require("build.this_program")

--- The program itself, which runs a relay; only a loopback is reachable.
Test.policy{ profiles = { "cosmic" }, loopback = { "127.0.0.1" }, promises = { "fork" } }

local TYPE_A <const> = 1

--- The name and type a query asks, and where its question ends.
local function question(query: string): string, integer, integer
  local asked = Udp.question(query)
  return asked.name, asked.qtype, asked.after
end

--- The reply to `query`: an A query for proxy.test is 127.0.0.1, where
--- the program's proxy listens, and for any other name 192.0.2.7; an AAAA
--- query has no records.
local function answer(query: string): string
  local name, qtype, question_end = question(query)
  local id = string.unpack(">I2", query)
  local head = query:sub(13, question_end)
  if qtype ~= TYPE_A then
    return string.pack(">I2I2I2I2I2I2", id, 0x8180, 1, 0, 0, 0) .. head
  end
  local data = if name == "proxy.test" then string.char(127, 0, 0, 1) else string.char(192, 0, 2, 7) end
  return string.pack(">I2I2I2I2I2I2", id, 0x8180, 1, 1, 0, 0) .. head ..
    string.pack(">I2I2I2I4s2", 0xC00C, qtype, 1, 60, data)
end

--- The upstream's host is looked up once, by the starter, however many
--- connections go through it; a name no grant opens is never looked up;
--- and a granted one is.
local function test_the_upstream_is_resolved_once_and_an_ungranted_name_never(tmp: string)
  local queries: mut {string} = {}
  local lines: mut {string} = {}
  Poll.run(function()
    local udp = assert(Udp.bind("127.0.0.1", 0))
    local port = assert(udp.address.port)
    local serving = Poll.spawn(function()
      while true do
        local packet, why = Udp.receive(udp, Clock.ms(20))
        if packet ~= nil then
          local asked, qtype = question(packet.data)
          table.insert(queries, tostring(qtype) .. " " .. asked)
          assert(Udp.send(udp, answer(packet.data), packet.address))
        elseif why ~= Poll.TIMEOUT then
          return
        end
      end
    end)
    local started = this_program.program(test_child.words(tmp, "build.relay_children_test", "serve", { tostring(port) }),
      { stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60) })
    local child <close> = assert(Child.start(started.argv, started.options))
    local result: Child.Result?
    while result == nil do
      local state = assert(child:try_wait())
      if state.finished then
        result = state.result
      else
        assert(Clock.sleep(Clock.ms(10)))
      end
    end
    local finished = assert(result)
    assert(finished.code == 0, tostring(finished.code) .. " " .. tostring(finished.stderr))
    for line in ((finished.stdout or "") .. "\n"):gmatch("([^\n]*)\n") do
      lines[#lines + 1] = line
    end
    serving:cancel()
    udp:close()
  end)
  table.sort(queries)
  assert(table.concat(lines, "|") == "upstream 127.0.0.1|api.test:443 200|api.test:443 200|api.test:443 200|" ..
      "ungranted.test:443 403|direct.test:443 403", table.concat(lines, "|"))
  assert(table.concat(queries, ",") == "1 direct.test,1 proxy.test,28 direct.test,28 proxy.test",
    table.concat(queries, ","))
end
