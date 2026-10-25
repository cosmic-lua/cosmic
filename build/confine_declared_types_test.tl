--- The declarations of the stand-ins build.confine and the relay client
--- hand out tell the truth about nil: a process that started is its pid
--- alone, with no reason or errno beside it, and a reader of the relay's
--- answer has a reason only where it refused. A checked run
--- (`cosmic test --check-types`) says whether a value crossed a typed
--- boundary under build/ as a kind its type does not admit; in any other
--- run the tests skip.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Test = require("cosmic.test")
local RelayWire = require("cosmic.internal.relay_wire")
local TypeWatch = require("build.type_watch")
local confine = require("build.confine")
local connect = require("build.sandbox_connect")
local this_program = require("build.this_program")

--- Each child only runs a chunk through this program's core, and the relay
--- is a listener of this test's own.
Test.policy{ profiles = { "cosmic" }, loopback = { "127.0.0.1" } }

--- Fails, listing what `during` met under build/, unless it met nothing.
local function honest(what: string, fn: function())
  local found = TypeWatch.during(fn, "build/")
  assert(#found == 0, what .. ": " .. #found .. " violations:\n" .. table.concat(found, "\n"))
end

--- A process started under the stand-in is its pid and no more.
local function test_a_process_started_under_the_stand_in_is_as_declared(tmp: string)
  honest("build.confine", function()
    local ran = confine.call(function()
      local started = this_program.program({ "-e", "return" }, { stdout = "capture" })
      assert(Child.run(started.argv, started.options))
    end, nil, { tmp })
    assert(ran.ok, tostring(ran.produced))
  end)
end

--- Exactly `count` bytes of `conn`, fewer where it ends first.
local function bytes(conn: Net.Conn, count: integer): string
  local data = ""
  while #data < count do
    local chunk = conn:read(count - #data)
    if chunk == nil then break end
    data = data .. chunk
  end
  return data
end

--- Runs a client that asks a relay for a host and is answered, the relay's
--- readers having no reason to give: with a login in the proxy's userinfo
--- the relay's token reader answers too.
local function tunnels(userinfo?: string)
  local code = { value = -1 }
  local waiting = { value = "" }
  local ended = { value = false }
  Poll.run(function()
    local listener = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local variables: {string:string} = { ALL_PROXY = "socks5h://" ..
        (if userinfo ~= nil then (userinfo .. "@") else "" end) .. "127.0.0.1:" .. assert(listener.address.port) }
    local client = Poll.spawn(function()
      code.value = connect.run({ "host.example", "80" }, {
        getenv = function(name: string): string? return variables[name] end,
        err = function(_line: string) end,
        read = function(): string?, string
          while waiting.value == "" and not ended.value do
            local ok, why = Poll.delay(Clock.ms(1))
            if not ok then return nil, why end
          end
          local data = waiting.value
          waiting.value = ""
          return data, ""
        end,
        write = function(_data: string): boolean, string return true, "" end,
        finish = function(): boolean, string return true, "" end,
      })
    end)
    local relay = assert(listener:accept(Clock.seconds(4)))
    relay:set_timeout(Clock.seconds(4))
    if userinfo == nil then
      assert(bytes(relay, 3) == "\5\1\0")
      assert(relay:write(RelayWire.socks_method_reply(0)))
    else
      assert(bytes(relay, 3) == "\5\1\2")
      assert(relay:write(RelayWire.socks_method_reply(2)))
      assert(bytes(relay, 1) == "\1")
      bytes(relay, bytes(relay, 1):byte(1))
      bytes(relay, bytes(relay, 1):byte(1))
      assert(relay:write("\1\0"))
    end
    local head = bytes(relay, 4)
    assert(head:byte(4) == 3)
    local length = bytes(relay, 1)
    bytes(relay, length:byte(1) + 2)
    assert(relay:write(RelayWire.socks_reply("succeeded")))
    ended.value = true
    assert(relay:shutdown("write"))
    assert(client:join(Clock.seconds(4)), "the client did not end")
    local _, _ = relay:close()
    local _, _ = listener:close()
  end)
  assert(code.value == 0, tostring(code.value))
end

local function test_the_relay_clients_readers_are_as_declared()
  honest("build.sandbox_connect", function()
    tunnels()
    tunnels("user:token")
  end)
end
