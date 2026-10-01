--- [`Net.serve`] with `workers`: a supervisor in a process of this
--- program's own, serving in workers it starts again from the same
--- program, each of which the test reaches as a client.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local this_program = require("build.this_program")

--- The program itself, which the test and the supervisor start (a file
--- `--standalone` among them: `standalone`), and a TCP listener on the
--- worker's own loopback.
Test.needs{ lua = true, standalone = true, network = { "127.0.0.1" } }

--- Answers each line with itself, the pid of the worker answering, and
--- what the worker and a child it starts find of COSMIC_NET_WORKER;
--- closes its connection at "bye". Its arguments: the directory to
--- listen in, grace_ms, and "chdir" to move to / before serving, as a
--- program may that was started with a path relative to where it
--- started.
local SERVER <const> = [[
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Proc = require("cosmic.proc")
local Stream = require("cosmic.stream")
local sys = require("cosmic.sys")

--- What a process this worker starts finds of COSMIC_NET_WORKER.
local function child_sees(): string
  local relaunch = assert(Proc.relaunch())
  local argv: {string} = {}
  for _, word in ipairs(relaunch.argv) do argv[#argv + 1] = word end
  argv[#argv + 1] = "-e"
  argv[#argv + 1] = "return require('cosmic.env').get('COSMIC_NET_WORKER') == nil and 0 or 7"
  local env = Env.all()
  for name, value in pairs(relaunch.env) do env[name] = value end
  local r = assert(Child.run(argv, { env = env, fds = relaunch.fds, timeout_ms = 30000 }))
  return r.code == 0 and "unset" or "set"
end

return function(argv: {string}): integer
  if argv[3] == "chdir" then assert(sys.chdir("/")) end
  local ok, why = Net.serve{
    listeners = { Net.unix(argv[1] .. "/s.sock"), Net.tcp("127.0.0.1", 0) },
    workers = 2,
    limits = { connections = 1 },
    grace_ms = math.tointeger(tonumber(argv[2])),
    serve = function(conn: Net.Conn)
      local lines = Stream.lines(conn)
      for line in lines:each() do
        if line == "bye" then return end
        assert(conn:write(line .. " " .. sys.getpid() .. " " ..
          tostring(Env.get("COSMIC_NET_WORKER")) .. " " .. child_sees() .. "\n"))
      end
    end,
    on_ready = function(addresses: {Net.Address}, _server: Net.Server)
      assert(Fs.put(Fs.stdout, "ready " .. addresses[2].port .. "\n"))
    end,
  }
  assert(Fs.put(Fs.stdout, "served " .. tostring(ok) .. " " .. why .. "\n"))
  return ok and 0 or 1
end
]]

--- `script`, written to `tmp` as `name`, started in a process of this
--- program's own with `args` after it, and `opts`.
local function started(tmp: string, name: string, script: string, args: {string},
    opts: Child.Options): Child.Handle
  assert(Fs.write(tmp .. "/" .. name, script))
  local words: {string} = { "--standalone", opts.cwd ~= nil and name or tmp .. "/" .. name }
  for _, word in ipairs(args) do words[#words + 1] = word end
  local program = this_program.program(words, opts)
  return (assert(Child.start(program.argv, program.options)))
end

--- Workers the test has met, each sent SIGKILL, with its group, as the
--- test ends, however it ends, so none outlives a failed assertion.
local record Workers
  pids: {integer}
  metamethod __close: function(Workers)
end

local workers_mt: metatable<Workers> = {
  __close = function(self: Workers)
    for _, pid in ipairs(self.pids) do local _, _ = sys.kill(-pid, sys.SIGKILL) end
  end,
}

local function workers(): Workers
  return setmetatable({ pids = {} }, workers_mt)
end

--- A connection to `address`, and the lines it reads.
local record Client
  conn: Net.Conn
  lines: Stream.Lines
  metamethod __close: function(Client)
end

local client_mt: metatable<Client> = {
  __close = function(self: Client)
    local _, _ = self.conn:close()
  end,
}

local function client(address: Net.Address): Client
  local conn = assert(Net.connect(address, { timeout_ms = 30000 }))
  return setmetatable({ conn = conn, lines = Stream.lines(conn) }, client_mt)
end

--- What `c` is answered for `line`, as its words.
local function asked(c: Client, line: string): {string}
  assert(c.conn:write(line .. "\n"))
  local answer = assert(c.lines:read())
  local words: {string} = {}
  for word in answer:gmatch("%S+") do words[#words + 1] = word end
  return words
end

local function now_ms(): integer
  return assert(sys.clock_gettime(sys.CLOCK_MONOTONIC)) // 1000000
end

--- A running server of SERVER's: its supervisor, what it prints, its
--- TCP port, and a client at each listener, each served by a worker of
--- its own -- one at its limit of one connection leaves the next to the
--- other -- whose pids `met` holds.
local record Running
  supervisor: Child.Handle
  out: Stream.Lines
  port: integer
  first: Client
  second: Client
end

local function running(tmp: string, met: Workers, args: {string},
    opts: Child.Options): Running
  opts.stdout = "stream"
  local h = started(tmp, "server.tl", SERVER, args, opts)
  local out = Stream.lines(assert(h.stdout_stream))
  local ready = assert(out:read())
  local port = math.tointeger(tonumber(ready:match("^ready (%d+)$")))
  assert(port ~= nil, ready)
  local first = client(Net.unix(tmp .. "/s.sock"))
  local second = client(Net.tcp("127.0.0.1", port))
  local one = asked(first, "one")
  local two = asked(second, "two")
  for i, words in ipairs({ one, two }) do
    local pid = assert(math.tointeger(tonumber(words[2])), table.concat(words, " "))
    met.pids[i] = pid
    assert(pid ~= h.pid, "the supervisor answered")
    assert(words[3] == "nil" and words[4] == "unset", table.concat(words, " "))
  end
  assert(met.pids[1] ~= met.pids[2], "one worker answered both: " .. met.pids[1])
  return { supervisor = h, out = out, port = port, first = first, second = second }
end

--- Waits until nothing listens at `address` any longer.
local function refused_at(address: Net.Address)
  local deadline = now_ms() + 30000
  while true do
    local conn, why = Net.connect(address, { timeout_ms = 1000 })
    if conn == nil and why:find("Connection refused", 1, true) ~= nil then return end
    if conn ~= nil then local _, _ = conn:close() end
    assert(now_ms() < deadline, "something still listens: " .. tostring(why))
    assert(sys.nanosleep(20 * 1000000))
  end
end

--- Two workers answer, one at each listener, and neither they nor a
--- child one starts sees COSMIC_NET_WORKER. SIGTERM to the supervisor
--- removes its socket file at once, while the connections open are
--- served to their end; it then returns true, having reaped both.
local function test_workers_serve_and_drain_at_sigterm(tmp: string)
  local met <close> = workers()
  local r = running(tmp, met, { tmp, "20000" }, {})
  local h <close> = r.supervisor
  local _first <close> = r.first
  local _second <close> = r.second
  assert(h:stop(sys.SIGTERM))
  local deadline = now_ms() + 30000
  while Fs.stat(tmp .. "/s.sock") ~= nil do
    assert(now_ms() < deadline, "the socket file outlived the stop")
    assert(sys.nanosleep(10 * 1000000))
  end
  assert(asked(r.first, "after")[1] == "after")
  assert(asked(r.second, "later")[1] == "later")
  assert(r.first.conn:write("bye\n"))
  assert(r.second.conn:write("bye\n"))
  local result = assert(h:wait(60000))
  local seen: {string} = {}
  for line in r.out:each() do seen[#seen + 1] = line end
  local rest = table.concat(seen, "\n")
  assert(result.code == 0,
    "code=" .. tostring(result.code) .. " signal=" .. tostring(result.signal) .. " " .. rest)
  -- Each worker's own Net.serve returns true too, and says so.
  local _, served = rest:gsub("served true", "")
  assert(served == 3, rest)
  for _, pid in ipairs(met.pids) do
    local alive, _, errno = sys.kill(pid, 0)
    assert(not alive and errno == sys.ESRCH, "worker " .. pid .. " outlived the supervisor")
  end
end

--- A supervisor that moved from where it started before serving starts
--- its workers where it started, so the script it names by a relative
--- path is there for them.
local function test_workers_start_where_the_supervisor_started(tmp: string)
  local met <close> = workers()
  local r = running(tmp, met, { tmp, "20000", "chdir" }, { cwd = tmp })
  local h <close> = r.supervisor
  local _first <close> = r.first
  local _second <close> = r.second
  assert(r.first.conn:write("bye\n"))
  assert(r.second.conn:write("bye\n"))
  assert(h:stop(sys.SIGTERM))
  local result = assert(h:wait(60000))
  assert(result.code == 0, "code=" .. tostring(result.code))
end

--- Workers whose supervisor is killed outright -- SIGKILL, which it
--- cannot act on -- find their lifeline closed, and stop as at SIGTERM:
--- a connection open is drained at grace_ms and closed, and nothing
--- listens at either listener once they have exited.
local function test_workers_stop_once_their_supervisor_is_killed(tmp: string)
  local met <close> = workers()
  local r = running(tmp, met, { tmp, "200" }, {})
  local h <close> = r.supervisor
  local _first <close> = r.first
  local _second <close> = r.second
  assert(h:stop(sys.SIGKILL))
  local result = assert(h:wait(60000))
  assert(result.signal == sys.SIGKILL, tostring(result.signal))
  local data, why = r.first.lines:read()
  assert(data == nil, data)
  assert(why == "" or why:find("reset", 1, true) ~= nil, why)
  refused_at(Net.tcp("127.0.0.1", r.port))
  refused_at(Net.unix(tmp .. "/s.sock"))
end

--- A worker that exits before the stop is reported, with how it ended,
--- and once every one has, the supervisor stops and says why. Each
--- worker here finds the marker the supervisor left, and so a spec
--- whose listener is not the one it is handed.
local function test_the_server_stops_once_every_worker_has_exited(tmp: string)
  local h <close> = started(tmp, "quits.tl", [[
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
return function(argv: {string}): integer
  local marker = argv[1] .. "/supervised"
  local name = Fs.stat(marker) == nil and "/s.sock" or "/other.sock"
  assert(Fs.write(marker, ""))
  local troubles: {string} = {}
  local ok, why = Net.serve{
    listeners = { Net.unix(argv[1] .. name) },
    workers = 2,
    serve = function(_conn: Net.Conn) end,
    on_error = function(trouble: string) troubles[#troubles + 1] = trouble end,
  }
  if name ~= "/s.sock" then
    assert(Fs.write(argv[1] .. "/worker-" .. require("cosmic.sys").getpid(), why))
    return 3
  end
  table.sort(troubles)
  assert(Fs.put(Fs.stdout, tostring(ok) .. " " .. why .. "\n" .. table.concat(troubles, "\n")))
  return 0
end
]], { tmp }, { stdout = "capture", stderr = "capture" })
  local r = assert(h:wait(60000))
  assert(r.code == 0, tostring(r.code) .. " " .. tostring(r.stderr))
  local said = r.stdout or ""
  assert(said:find("^false every worker exited before the server stopped\n") ~= nil, said)
  local _, exits = said:gsub("\nworker %d+ exited with status 3", "")
  assert(exits == 2, said)
  assert(Fs.stat(tmp .. "/s.sock") == nil, "the socket file outlived the server")
  local reports = 0
  for entry in pairs((assert(sys.readdir(tmp)))) do
    if entry:find("^worker%-") then
      local why = assert(Fs.read(tmp .. "/" .. entry))
      assert(why:find("^descriptor 4, handed for listeners%[1%] %(.*/other%.sock%): it listens at ")
        ~= nil, why)
      reports = reports + 1
    end
  end
  assert(reports == 2, tostring(reports))
end

--- What a process started with COSMIC_NET_WORKER set to `variable`,
--- and `fds`, says of its Net.serve: whether it served, why not, whether
--- descriptor 4 is still open, and whether it sees the variable.
local function handed(tmp: string, variable: string, fds: {integer: integer | string}): string
  local env = this_program.environment()
  env.COSMIC_NET_WORKER = variable
  local h <close> = started(tmp, "worker.tl", [[
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local sys = require("cosmic.sys")
return function(argv: {string}): integer
  local ok, why = Net.serve{
    listeners = { Net.unix(argv[1] .. "/s.sock") },
    serve = function(_conn: Net.Conn) end,
    on_ready = function(_addresses: {Net.Address}, server: Net.Server) server:stop() end,
  }
  assert(Fs.put(Fs.stdout, tostring(ok) .. " " .. why .. "|" .. tostring(sys.fstat(4) ~= nil) ..
    "|" .. tostring(Env.get("COSMIC_NET_WORKER"))))
  return 0
end
]], { tmp }, { env = env, fds = fds, stdout = "capture", stderr = "capture" })
  local r = assert(h:wait(60000))
  assert(r.code == 0, tostring(r.code) .. " " .. tostring(r.stderr))
  return r.stdout or ""
end

--- A worker handed a descriptor that is no listening socket fails,
--- naming it, and leaves it open; so does one handed a list it cannot
--- read, or a variable naming a supervisor that is not its parent --
--- one gone, or a value set by hand -- which neither listens nor
--- touches a descriptor. None sees the variable.
local function test_a_worker_handed_what_is_no_listener_fails(tmp: string)
  local file = assert(sys.open(tmp .. "/plain", sys.O_CREAT | sys.O_RDWR, 420))
  local me = tostring(sys.getpid())
  local both: {integer: integer | string} = { [3] = file, [4] = file }
  local plain = handed(tmp, me .. ":3:4", both)
  assert(plain == "false descriptor 4, handed for listeners[1] (" .. tmp ..
    "/s.sock): Not a socket|true|nil", plain)
  local two = handed(tmp, me .. ":3:4,5", both)
  assert(two == "false COSMIC_NET_WORKER must name a descriptor for each listener: " ..
    "it names 2, and the spec has 1|true|nil", two)
  local bad = handed(tmp, me .. ":3:x", both)
  assert(bad:find("^false COSMIC_NET_WORKER must name the supervisor's pid") ~= nil, bad)
  local garbled = handed(tmp, "3,4", both)
  assert(garbled == "false COSMIC_NET_WORKER must name the supervisor's pid, a descriptor and " ..
    "then one for each listener, each from 3 to 253 and each once, as \"<pid>:3:4,5\", " ..
    "not \"3,4\"|true|nil", garbled)
  local stray = handed(tmp, "1:3:4", both)
  assert(stray == "false COSMIC_NET_WORKER names supervisor 1, not this process's parent " ..
    me .. ": its supervisor is gone, or it was set by another|true|nil", stray)
  assert(Fs.stat(tmp .. "/s.sock") == nil, "a process refused as a worker listened")
  assert(sys.close(file))
end

--- A worker whose protocol never ends -- it holds the thread rather
--- than wait through the run, so its task cannot be killed at grace_ms
--- -- is sent SIGKILL a second past grace_ms after the stop, and
--- reported; the supervisor then returns true.
local function test_a_worker_outlasting_the_stop_is_killed(tmp: string)
  local h <close> = started(tmp, "stuck.tl", [[
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Stream = require("cosmic.stream")
local Time = require("cosmic.time")
return function(argv: {string}): integer
  local troubles: {string} = {}
  local ok, why = Net.serve{
    listeners = { Net.unix(argv[1] .. "/s.sock") },
    workers = 1,
    grace_ms = 0,
    serve = function(conn: Net.Conn)
      assert(Stream.lines(conn):read())
      assert(conn:write("held\n"))
      while true do local _, _ = Time.sleep_ns(10000000) end
    end,
    on_error = function(trouble: string) troubles[#troubles + 1] = trouble end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local conn <close> = assert(Net.connect(addresses[1], { timeout_ms = 30000 }))
      assert(conn:write("hold\n"))
      assert(Stream.lines(conn):read() == "held")
      server:stop()
    end,
  }
  assert(Fs.put(Fs.stdout, tostring(ok) .. " " .. why .. "\n" .. table.concat(troubles, "\n")))
  return 0
end
]], { tmp }, { stdout = "capture", stderr = "capture" })
  local r = assert(h:wait(60000))
  assert(r.code == 0, tostring(r.code) .. " " .. tostring(r.stderr))
  local said = r.stdout or ""
  assert(said:find("^true \nworker %d+ was still running 1000 ms past grace_ms after the stop, " ..
    "and was killed$") ~= nil, said)
end

--- A worker whose protocol waits on through the run after the stop,
--- ignoring every failure, has its task killed at grace_ms and exits
--- on its own, before the supervisor would send it SIGKILL.
local function test_a_worker_waiting_past_the_stop_exits_at_grace_ms(tmp: string)
  local h <close> = started(tmp, "waits.tl", [[
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Stream = require("cosmic.stream")
return function(argv: {string}): integer
  local troubles: {string} = {}
  local ok, why = Net.serve{
    listeners = { Net.unix(argv[1] .. "/s.sock") },
    workers = 1,
    grace_ms = 0,
    serve = function(conn: Net.Conn)
      assert(Stream.lines(conn):read())
      assert(conn:write("held\n"))
      while true do local _, _ = Poll.delay(10) end
    end,
    on_error = function(trouble: string) troubles[#troubles + 1] = trouble end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local conn <close> = assert(Net.connect(addresses[1], { timeout_ms = 30000 }))
      assert(conn:write("hold\n"))
      assert(Stream.lines(conn):read() == "held")
      server:stop()
    end,
  }
  assert(Fs.put(Fs.stdout, tostring(ok) .. " " .. why .. "\n" .. table.concat(troubles, "\n")))
  return 0
end
]], { tmp }, { stdout = "capture", stderr = "capture" })
  local r = assert(h:wait(60000))
  assert(r.code == 0, tostring(r.code) .. " " .. tostring(r.stderr))
  -- The worker's line and the supervisor's, neither reporting trouble.
  assert(r.stdout == "true \ntrue \n", string.format("%q", r.stdout))
end
