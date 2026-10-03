--- [`cosmic.net`] in a process of this program's own, started with
--- SIGPIPE at its default, which ends a process it is sent to: a write
--- to a peer that has gone fails there rather than ending it. The
--- worker running cosmic/net_test.tl may itself have SIGPIPE ignored
--- (as a CI runner can start it), where the same write passes whether
--- the socket's send asks for no signal or not.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local this_program = require("build.this_program")
local Clock = require("cosmic.clock")

--- The program itself, which the test starts, running a file `--standalone`
--- (`standalone`).
Test.needs{ lua = true, standalone = true }

local function test_a_write_to_a_closed_peer_does_not_end_the_process(tmp: string)
  local script = tmp .. "/write.tl"
  assert(Fs.write(script, [[
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
return function(argv: {string}): integer
  -- SIGPIPE ignored from outside (its bit, 13, of /proc's SigIgn), the
  -- write below would pass whatever the socket asks: say so, and stop.
  local status = Fs.read("/proc/self/status")
  local ignored = status ~= nil and status:match("SigIgn:%s*(%x+)")
  if ignored and (tonumber(ignored, 16) // 0x1000) % 2 == 1 then
    Fs.put(Fs.stdout, "ignored")
    return 0
  end
  local server <close> = assert(Net.listen(Net.unix(argv[1] .. "/s.sock")))
  local client <close> = assert(Net.connect(server.address))
  local accepted = assert(server:accept())
  assert(accepted:close())
  local ok, why = client:write(string.rep("x", 1 << 20))
  Fs.put(Fs.stdout, tostring(ok) .. " " .. why)
  return 0
end
]]))
  local started = this_program.program({ "--standalone", script, tmp },
    { stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.signal ~= sys.SIGPIPE, "the write ended the process with SIGPIPE")
  assert(result.code == 0, tostring(result.code) .. " " .. tostring(result.stderr))
  local said = result.stdout or ""
  if said == "ignored" then return end
  assert(said:find("^false ") ~= nil and #said > #"false ", said)
end

--- A connection's protocol runs a child while the server holds its
--- signal guard: the run holds one of its own inside the server's.
local function test_a_protocol_runs_a_child_under_the_server_s_guard(tmp: string)
  local answer = ""
  assert(Net.serve{
    listeners = { Net.unix(tmp .. "/s.sock") },
    serve = function(conn: Net.Conn)
      local started = this_program.program({ "-e", "return 6" }, { timeout_ns = Clock.seconds(30) })
      local r, why = Child.run(started.argv, started.options)
      assert(conn:write((r ~= nil and tostring(r.code) or why) .. "\n"))
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local conn <close> = assert(Net.connect(addresses[1], { timeout_ns = Clock.seconds(30) }))
      answer = assert(Stream.lines(conn):read())
      server:stop()
    end,
  })
  assert(answer == "6", answer)
end

--- Runs `script`, a Teal file taking the scratch directory, in a
--- process of this program's own, and answers how it ended.
local function run_script(tmp: string, script: string): Child.Result
  local started = this_program.program({ "--standalone", script, tmp },
    { stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
  return (assert(Child.run(started.argv, started.options)))
end

--- A signal the server never stopped on is not swallowed: where
--- on_ready raises after SIGTERM, the process dies of the signal, as it
--- would without the server's guard.
local function test_a_signal_is_delivered_where_on_ready_raises(tmp: string)
  local script = tmp .. "/raises.tl"
  assert(Fs.write(script, [[
local Net = require("cosmic.net")
local sys = require("cosmic.sys")
return function(argv: {string}): integer
  local _, _ = pcall(Net.serve, {
    listeners = { Net.unix(argv[1] .. "/s.sock") },
    serve = function(_conn: Net.Conn) end,
    on_ready = function(_addresses: {Net.Address}, _server: Net.Server)
      assert(sys.kill(sys.getpid(), sys.SIGTERM))
      error("on_ready failed")
    end,
  } as Net.ServeSpec)
  return 0
end
]]))
  local r = run_script(tmp, script)
  assert(r.signal == sys.SIGTERM, "code=" .. tostring(r.code) .. " " .. tostring(r.stderr))
end

--- A signal during a drain that Server.stop began is delivered once the
--- drain ends: the connection in flight finishes, and the process then
--- dies of the signal.
local function test_a_signal_in_a_drain_stop_began_is_delivered(tmp: string)
  local script = tmp .. "/stopped.tl"
  local report = tmp .. "/report"
  assert(Fs.write(script, [[
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Stream = require("cosmic.stream")
local sys = require("cosmic.sys")
return function(argv: {string}): integer
  local started = false
  assert(Net.serve{
    listeners = { Net.unix(argv[1] .. "/s.sock") },
    serve = function(conn: Net.Conn)
      local line = assert(Stream.lines(conn):read())
      started = true
      assert(Poll.delay(Clock.ms(100)))
      assert(conn:write(line .. "\n"))
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local conn <close> = assert(Net.connect(addresses[1], { timeout_ns = Clock.seconds(5) }))
      assert(conn:write("slow\n"))
      while not started do assert(Poll.delay(Clock.ms(1))) end
      server:stop()
      assert(sys.kill(sys.getpid(), sys.SIGTERM))
      local answer = assert(Stream.lines(conn):read())
      assert(Fs.write(argv[1] .. "/report", answer))
    end,
  })
  return 0
end
]]))
  local r = run_script(tmp, script)
  local got = Fs.read(report)
  assert(got == "slow", tostring(got) .. " " .. tostring(r.stderr))
  assert(r.signal == sys.SIGTERM, "code=" .. tostring(r.code) .. " " .. tostring(r.stderr))
end
