--- `cosmic sandbox --connect` and `cosmic sandbox connect`, run as this
--- program: the relay's client as the program of a sandbox, as ssh runs it
--- for a ProxyCommand, reaching a server of this test's own at 127.0.0.2
--- (which the sandbox's network does not hold, and the relay's connectors,
--- started in the worker's, reach), the bytes it carries each way with their
--- half-closes, the refusal of a port nothing grants with the relay's own
--- decision line on the verb's standard error, and a caller's `https_proxy`
--- as the relay's upstream. The verb starts a relay, which makes namespaces
--- ("nest"); where the host gives no sandbox the tests skip (Test.skip).
--- The rest of the verb is in build/sandbox_tool_test.tl.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")
local searchable = require("build.searchable")
local this_program = require("build.this_program")

--- The verb is started by its own launch (the grant of o/bin) and starts
--- the relay and the program under it, which nest. The two addresses are
--- those of the servers, and the one the worker's own loopback is.
Test.policy{
  profiles = { "cosmic" },
  promises = { "nest" },
  loopback = { "127.0.0.1", "127.0.0.2" },
  env = { "TMPDIR" },
  grants = { { path = "o/bin", letters = "rx" } },
  requires = { "nest" },
}

--- How a run of the verb ended.
local record Ran
  code: integer
  out: string
  err: string
end

--- Whether `why`, a refusal of the sandbox, is the host giving none.
local function unsandboxable(why: string): boolean
  for _, word in ipairs({ "Landlock", "seccomp", "not implemented", "namespace", "own /proc",
      "root could not be built" }) do
    if why:find(word, 1, true) then return true end
  end
  return false
end

--- Runs `cosmic <words>` in `dir` with `input` on its standard input and the
--- environment `env` (the worker's own where nil), and answers how it ended;
--- ends the test, skipped, where the host gave the sandbox it asked for none.
local function verb(dir: string, words: {string}, input: string, env?: {string:string}): Ran
  searchable.open(dir)
  local started = this_program.program(words, {
    cwd = dir, env = env or this_program.environment(), input = input, stdout = "capture",
    stderr = "capture", timeout_ns = Clock.seconds(60),
  })
  local result = assert(Child.run(started.argv, started.options))
  local err = result.stderr or ""
  if result.code == 125 and unsandboxable(err) then Test.skip(err) end
  return { code = result.code or -1, out = result.stdout or "", err = err }
end

--- Serves each connection `listener` accepts as a task of the run: reads
--- what the client sends to its end, as a half-close, and answers `echo:` and
--- all of it, then closes. `heard` is told each connection's bytes.
local function echoing(listener: Net.Listener, heard: function(data: string)): Poll.Task
  return Poll.spawn(function()
    while true do
      local conn = listener:accept()
      if conn == nil then return end
      Poll.spawn(function()
        conn:set_timeout(Clock.seconds(30))
        local data = ""
        while true do
          local chunk = conn:read(4096)
          if chunk == nil then break end
          data = data .. chunk
        end
        heard(data)
        local _, _ = conn:write("echo:" .. data)
        local _, _ = conn:shutdown("write")
        local _, _ = conn:close()
      end)
    end
  end)
end

--- A server at 127.0.0.2, the one `body` is given the port of.
local function serving(body: function(port: integer, heard: {string}))
  local heard: {string} = {}
  Poll.run(function()
    local listener = assert(Net.listen(Net.tcp("127.0.0.2", 0)))
    local task = echoing(listener, function(data: string) heard[#heard + 1] = data end)
    body(listener.address.port, heard)
    task:cancel()
    assert(listener:close())
  end)
end

--- The command line of a verb that grants `target` and runs the client for
--- `host` and `port` as its program, this program's own file.
local function client(target: string, host: string, port: integer): {string}
  return { "sandbox", "--cosmic", "--connect", target, "--", assert(Proc.executable()), "sandbox", "connect",
    host, tostring(port) }
end

local function test_the_client_carries_bytes_both_ways_with_the_half_close(tmp: string)
  local ran: Ran
  local heard: {string}
  serving(function(port: integer, bytes: {string})
    ran = verb(tmp, client("127.0.0.2:" .. port, "127.0.0.2", port), "ping")
    heard = bytes
  end)
  assert(ran.code == 0, ran.code .. ": " .. ran.err)
  -- The server answered only after the end of what was sent, which is the
  -- half-close, and the client's standard output ended with its end.
  assert(ran.out == "echo:ping", "the output: " .. ran.out)
  assert(heard[1] == "ping" and #heard == 1, "the server heard " .. table.concat(heard, "|"))
  -- Standard error holds the relay's decision lines, and the client's none.
  assert(ran.err:find("relay: #1 socks5 127.0.0.2:", 1, true) and ran.err:find(": allowed", 1, true), ran.err)
  assert(not ran.err:find("sandbox connect", 1, true), ran.err)
end

local function test_a_port_nothing_grants_exits_1_and_the_relay_says_the_remedy(tmp: string)
  local ran: Ran
  local port: integer
  serving(function(granted: integer)
    port = granted + 1
    ran = verb(tmp, client("127.0.0.2:" .. granted, "127.0.0.2", port), "never sent")
  end)
  assert(ran.code == 1, ran.code .. ": " .. ran.err)
  assert(ran.out == "", ran.out)
  -- The relay's own line, on the verb's standard error, names the grant that
  -- would allow it; the client's, the reply's meaning.
  assert(ran.err:find("not granted: --connect 127.0.0.2:" .. port, 1, true), ran.err)
  assert(ran.err:find("sandbox connect: 127.0.0.2:" .. port .. ": connection not allowed by ruleset", 1, true), ran.err)
end

local function test_a_name_is_resolved_by_the_relay_and_never_by_the_program(tmp: string)
  local ran: Ran
  serving(function(port: integer)
    -- No name of this sandbox resolves: the relay is asked for a name and
    -- refuses it as it is not granted, and the program has no DNS to ask.
    ran = verb(tmp, client("127.0.0.2:" .. port, "ungranted.example", 443), "")
  end)
  assert(ran.code == 1, ran.code .. ": " .. ran.err)
  assert(ran.err:find("not granted: --connect ungranted.example:443", 1, true), ran.err)
end

--- What a proxy of the caller's is given: the line of its CONNECT and the
--- bytes it carries, answered `echo:` as the servers do.
local function test_a_callers_https_proxy_is_the_relays_upstream(tmp: string)
  local ran: Ran
  local request: string
  local carried: string
  local proxy: integer
  Poll.run(function()
    local listener = assert(Net.listen(Net.tcp("127.0.0.2", 0)))
    proxy = listener.address.port
    local task = Poll.spawn(function()
      local conn = listener:accept()
      if conn == nil then return end
      conn:set_timeout(Clock.seconds(30))
      local head = ""
      while not head:find("\r\n\r\n", 1, true) do
        local chunk = conn:read(4096)
        if chunk == nil then return end
        head = head .. chunk
      end
      request = head:match("^[^\r]*")
      assert(conn:write("HTTP/1.1 200 Connection established\r\n\r\n"))
      local data = ""
      while true do
        local chunk = conn:read(4096)
        if chunk == nil then break end
        data = data .. chunk
      end
      carried = data
      local _, _ = conn:write("echo:" .. data)
      local _, _ = conn:shutdown("write")
      local _, _ = conn:close()
    end)
    local env = this_program.environment()
    env.https_proxy = "http://127.0.0.2:" .. proxy
    ran = verb(tmp, client("through.example:443", "through.example", 443), "ping", env)
    task:cancel()
    assert(listener:close())
  end)
  assert(ran.code == 0, ran.code .. ": " .. ran.err)
  assert(request == "CONNECT through.example:443 HTTP/1.1", "the proxy was asked: " .. tostring(request))
  assert(carried == "ping" and ran.out == "echo:ping", "the bytes went through it: " .. ran.out)
  -- Said once, as the relay starts, on the verb's standard error.
  local note = "upstream proxy 127.0.0.2:" .. proxy .. ": it resolves the names it is asked for"
  local first, last = ran.err:find(note, 1, true)
  assert(first ~= nil, ran.err)
  assert(ran.err:find(note, last, true) == nil, "said once: " .. ran.err)
end
