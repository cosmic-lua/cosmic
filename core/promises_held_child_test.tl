--- `spawn`'s `promises` beside the namespaces a child makes for itself
--- (core/promises.h's COSMIC_HELD_ bits), on a live child: the kernel's own
--- verdict on the calls the filter lets through only where a namespace or
--- a ruleset holds what they reach. The child is a stand-in
--- (build/stand_in.tl). A host that gives no user namespace or seccomp
--- skips them (build.sandbox_skip). The filter's own rules, on both
--- architectures, are core/promises_test.tl's.

local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local sandbox_skip = require("build.sandbox_skip")
local stand_in = require("build.stand_in")
local type raw_process = require("cosmic.internal.process")
-- Required, so the module whose loader is handed the raw table is of this
-- test's import closure, and the store has it to hand it from.
local type _ = require("cosmic.child")

--- `nests`, since the children these tests start make namespaces of their
--- own, which a worker held by a Landlock ruleset cannot start.
Test.needs{ nests = true }

local type Searcher = function(string): any, any

--- The raw table the store's searcher hands `wrapper`'s loader.
local function raw_behind(wrapper: string): any
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher(wrapper)
    if type(loader) == "function" and type(extra) == "table" then return extra end
  end
  error(wrapper .. " is handed no raw table")
end

local process = raw_behind("cosmic.child") as raw_process -- cast: the table core/process.h declares

--- What a script left on stdout and stderr, and how its program ended.
local record Outcome
  code: integer
  signal: integer
  said: string
end

--- Runs `script` in a stand-in held to no promise, in a directory of `tmp`'s: its
--- output and how it ended, with the host's own pid namespace.
local function under(tmp: string, probe: string, script: string): Outcome
  local path = tmp .. "/said"
  local output = assert(sys.open(path, sys.O_CREAT | sys.O_RDWR | sys.O_TRUNC, 420))
  local pid = assert(process.spawn(probe, { probe, script }, nil, nil, nil, output, output, false, nil,
    { promises = {} }))
  local status = assert(process.waitpid(pid, false))
  sys.close(output)
  return { code = status.code, signal = status.signal, said = (Fs.read(path)) or "" }
end

--- Runs `script` in a stand-in started with `sandbox` (its `promises`
--- among them): its output and how it ended. Skips the test where the
--- start is refused, as the host gives no sandbox of that kind.
local function in_sandbox(tmp: string, probe: string, sandbox: raw_process.Sandbox, script: string): Outcome
  local path = tmp .. "/said"
  local output = assert(sys.open(path, sys.O_CREAT | sys.O_RDWR | sys.O_TRUNC, 420))
  local pid, trouble = process.spawn(probe, { probe, script }, nil, "/", nil, output, output, false,
    nil, sandbox)
  if pid == nil then
    sys.close(output)
    sandbox_skip.refused("this host gives no such sandbox: " .. tostring(trouble))
    return { code = -1, signal = -1, said = "" }
  end
  local status = assert(process.waitpid(pid, false))
  sys.close(output)
  return { code = status.code, signal = status.signal, said = (Fs.read(path)) or "" }
end

local function test_a_child_in_a_user_namespace_of_its_own_sets_its_own_limits(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local lowers = in_sandbox(tmp, probe, { promises = {}, offline = true },
    "setrlimit nofile 64; rlimit nofile")
  if lowers.code == -1 then return end
  -- Whoever started it, whatever capability that has: the namespace's are the
  -- initial one's no more.
  assert(lowers.code == 0 and lowers.said == "set\nnofile 64 64\n", "it lowers them: " .. lowers.said)
  local raises = in_sandbox(tmp, probe, { promises = {}, offline = true },
    "setrlimit nofile 64; setrlimit nofile 128")
  assert(raises.code == 1 and raises.said:find("not permitted", 1, true), "it raises none: " .. raises.said)
end

local function test_a_child_asks_after_any_pid_only_in_a_pid_namespace_of_its_own(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  -- The first process of the namespace is pid 1, which this one is not.
  local own = in_sandbox(tmp, probe, { promises = {}, unveil = { reads = { probe, "/proc", "/dev/null" } } },
    "getpgid 1")
  if own.code == -1 then return end
  assert(own.code == 0 and own.said:find("pgid ", 1, true) == 1, "pid 1 is its own: " .. own.said)
  local host = under(tmp, probe, "getpgid 1")
  assert(host.code == 1 and host.said:find("not permitted", 1, true),
    "in the host's, no pid but its own: " .. host.said)
  local itself = under(tmp, probe, "getpgid 0")
  assert(itself.code == 0, itself.said)
end

--- A start that is isolated and held to `grants`: a root of its own that
--- shows the stand-in alone, and Landlock's ruleset over it, in a network
--- namespace of its own where `offline`.
local function rooted(probe: string, offline: boolean): raw_process.Sandbox
  return { strict = true, offline = offline, promises = {},
    unveil = { reads = { probe, "/proc", "/dev/null" } },
    grants = { { path = probe, access = "rx" } } }
end

local function test_a_unix_socket_is_made_only_where_the_root_the_network_and_landlock_hold_it(tmp: string)
  local abi, trouble = process.landlock_abi()
  if abi == nil then
    sandbox_skip.refused("no Landlock here: " .. tostring(trouble))
    return
  end
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local script = "connect /none.sock"
  local held = in_sandbox(tmp, probe, rooted(probe, true), script)
  if held.code == -1 then return end
  -- Landlock decides what a unix socket reaches by path from ABI 9 only; before it
  -- a granted directory's sockets would be reachable, so the filter keeps socket()
  -- refused.
  if abi >= 9 then
    assert(held.said:find("not permitted", 1, true) == nil, "made where held: " .. held.said)
  else
    assert(held.said:find("not permitted", 1, true), "refused below ABI 9: " .. held.said)
  end
  -- Never without the network namespace, where a name it binds is the host's to find.
  local shared = in_sandbox(tmp, probe, rooted(probe, false), script)
  assert(shared.said:find("not permitted", 1, true), "refused without its own network: " .. shared.said)
  -- Nor without a root of its own, whose files are the host's.
  local open: raw_process.Sandbox = { offline = true, promises = {},
    grants = { { path = probe, access = "rx" } } }
  local unrooted = in_sandbox(tmp, probe, open, script)
  assert(unrooted.said:find("not permitted", 1, true), "refused without a root of its own: " .. unrooted.said)
end
