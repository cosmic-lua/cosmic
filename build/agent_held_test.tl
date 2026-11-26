--- `cosmic agent`'s session runs held (build/agent.tl's `held`): run
--- as this program, ask, chat, resume and rpc start themselves again in a
--- child held to the session's own policy ([`Policy.session`]), which
--- says why it cannot go on where nothing is wrong but the run; one that
--- cannot be held runs unheld and says why. The session's child nests the
--- worker's sandbox, so the module needs a host that lets one nest, and
--- the system in its key.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local searchable = require("build.searchable")
local sys = require("cosmic.sys")
local ChildPolicy = require("build.child_policy_fixture")

Test.policy{
  profiles = { "system", "cosmic" },
  env = { "PATH", "TMPDIR" },
  -- The relay of the session's connect makes its listeners in a network
  -- namespace of the session's own, which needs inet sockets.
  loopback = { "127.0.0.1" },
  grants = { { path = "o/bin", letters = "rx" }, { calls = "nest" } },
  requires = { "nest" },
}

--- What `cosmic agent` printed on standard error, and how it ended.
local record Ran
  code: integer
  err: string
end

--- Runs `cosmic agent` with `args` in a project of `tmp`, its home there
--- too, with no credential.
local function agent(tmp: string, args: {string}): Ran
  local base = assert(Fs.absolute(searchable.open(tmp)))
  local work, home = base .. "/work", base .. "/home"
  assert(Fs.mkdirs(work))
  assert(Fs.mkdirs(home))
  searchable.share(work)
  searchable.share(home)
  local env: mut {string: string} = { HOME = home }
  for name, value in pairs(Test.environment()) do
    if name ~= "HOME" and name ~= "XDG_CACHE_HOME" then env[name] = value end
  end
  local argv: mut {string} = { "agent" }
  for _, word in ipairs(args) do argv[#argv + 1] = word end
  local started = Test.cosmic(argv, { env = env, cwd = work, timeout_ns = Child.FOREVER,
    stdin = "null", stdout = "capture", stderr = "capture" })
  local result = assert(Child.run(started.argv, started.options))
  return { code = result.code or -1, err = result.stderr or "" }
end

--- A held session says what the run says: here, that there is no
--- credential, which it finds in its child.
local function test_a_held_session_says_why_it_cannot_go_on(tmp: string)
  local ran = agent(tmp, { "ask", "--new", "hi" })
  if ran.err:find("the session's sandbox", 1, true) ~= nil and ChildPolicy.unsandboxable(ran.err) then
    Test.skip(ran.err)
  end
  assert(ran.code == 2 and ran.err:find("no credential", 1, true) ~= nil, tostring(ran.code) .. ": " .. ran.err)
  assert(not ran.err:find("unheld", 1, true) and not ran.err:find("the session's sandbox", 1, true), ran.err)
end

--- One with an MCP server that runs unsandboxed, with the agent's rights,
--- runs unheld and says so.
local function test_a_session_with_an_unsandboxed_server_runs_unheld(tmp: string)
  local config = assert(Fs.absolute(searchable.open(tmp))) .. "/mcp.json"
  assert(Fs.write(config, '{"servers": {"mine": {"command": ["/bin/true"], "sandbox": "off"}}}'))
  local ran = agent(tmp, { "ask", "--new", "--mcp", config, "hi" })
  assert(ran.code == 2 and ran.err:find("no credential", 1, true) ~= nil, tostring(ran.code) .. ": " .. ran.err)
  assert(ran.err:find("the session runs unheld: the MCP server mine runs unsandboxed", 1, true), ran.err)
end

--- A standard stream that is a file open for writing alone, which a
--- child that nests may not hold, reaches the file through a pump.
local function test_a_held_session_writes_to_a_file_open_for_writing_alone(tmp: string)
  local base = assert(Fs.absolute(searchable.open(tmp)))
  local work, home = base .. "/work", base .. "/home"
  assert(Fs.mkdirs(work))
  assert(Fs.mkdirs(home))
  searchable.share(work)
  searchable.share(home)
  local log = base .. "/err.txt"
  local fd = assert(sys.open(log, sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC, 0x1a4))
  local env: mut {string: string} = { HOME = home }
  for name, value in pairs(Test.environment()) do
    if name ~= "HOME" and name ~= "XDG_CACHE_HOME" then env[name] = value end
  end
  local started = Test.cosmic({ "agent", "ask", "--new", "hi" }, { env = env, cwd = work,
    timeout_ns = Child.FOREVER, stdin = "null", stdout = "null", stderr = fd })
  local result = assert(Child.run(started.argv, started.options))
  local _, _ = sys.close(fd)
  local said = assert(Fs.read(log))
  if said:find("the session's sandbox", 1, true) ~= nil and ChildPolicy.unsandboxable(said) then
    Test.skip(said)
  end
  assert(result.code == 2 and said:find("no credential", 1, true) ~= nil, tostring(result.code) .. ": " .. said)
end
