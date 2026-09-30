--- [`cosmic.net`] in a process of this program's own, started with
--- SIGPIPE at its default, which ends a process it is sent to: a write
--- to a peer that has gone fails there rather than ending it. The
--- worker running cosmic/net_test.tl may itself have SIGPIPE ignored
--- (as a CI runner can start it), where the same write passes whether
--- the socket's send asks for no signal or not.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local this_program = require("build.this_program")

--- The program itself, which the test starts.
Test.needs{ tool = true }

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
    { stdout = "capture", stderr = "capture", timeout_ms = 30000 })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.signal ~= sys.SIGPIPE, "the write ended the process with SIGPIPE")
  assert(result.code == 0, tostring(result.code) .. " " .. tostring(result.stderr))
  local said = result.stdout or ""
  if said == "ignored" then return end
  assert(said:find("^false ") ~= nil and #said > #"false ", said)
end
