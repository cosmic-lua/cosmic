--- `spawn`'s `promises` beside the namespaces a child makes for itself
--- (core/promises.h's COSMIC_HELD_ bits), on a live child: the kernel's own
--- verdict on the calls the filter lets through only where a namespace or
--- a ruleset holds what they reach. The child is a stand-in
--- (build/stand_in.tl). A host that gives no user namespace or seccomp
--- skips them (Test.skip). The filter's own rules, on both
--- architectures, are core/promises_test.tl's.

local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Test = require("cosmic.test")
local unix_socket = require("build.unix_socket")
local sys = require("cosmic.sys")
local confine = require("build.confine")
local stand_in = require("build.stand_in")
local type raw_process = require("cosmic.internal.process")
-- Required, so the module whose loader is handed the raw table is of this
-- test's import closure, and the store has it to hand it from.
local type _ = require("cosmic.child")

--- `nests`, since the children these tests start make namespaces of their
--- own, which a worker held by a Landlock ruleset cannot start; and a
--- `network`, which gives the worker a network namespace of its own, one
--- its filter lets it make a unix socket in (the children it starts inherit
--- that filter).
Test.policy{
  promises = { "nest" },
  loopback = { "127.0.0.1" },
}

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
local function in_sandbox(tmp: string, probe: string, sandbox: raw_process.Sandbox, script: string,
                          fds?: {integer:integer}): Outcome
  local path = tmp .. "/said"
  local output = assert(sys.open(path, sys.O_CREAT | sys.O_RDWR | sys.O_TRUNC, 420))
  local pid, trouble = process.spawn(probe, { probe, script }, nil, "/", nil, output, output, false,
    fds, sandbox)
  if pid == nil then
    sys.close(output)
    if confine.sandbox_platform() then
      Test.skip("this host gives no such sandbox: " .. tostring(trouble))
    end
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
    if confine.sandbox_platform() then Test.skip("no Landlock here: " .. tostring(trouble)) end
    return
  end
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local script = "connect /none.sock"
  local held = in_sandbox(tmp, probe, rooted(probe, true), script)
  if held.code == -1 then return end
  -- A root that shows no directory and no socket file holds it on every ABI,
  -- and Landlock does from ABI 9 whatever the root shows.
  -- A worker whose own filter refuses unix sockets passes that on to every
  -- process it starts, so nothing here can be made: the refusals below stand.
  if not unix_socket.skipped(tmp) then
    assert(held.said:find("not permitted", 1, true) == nil, "made where held: " .. held.said)
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

--- `rooted`, whose root shows a /tmp of its own of a mebibyte, and each of
--- `shown`, files or directories of the host, at their own names.
local function rooted_with(probe: string, shown: {string}): raw_process.Sandbox
  local sandbox = rooted(probe, true)
  for _, path in ipairs(shown) do sandbox.unveil.reads[#sandbox.unveil.reads + 1] = path end
  sandbox.unveil.tmp = 1 << 20
  return sandbox
end

--- A socket file of the host, made in a directory of `tmp`'s that holds
--- nothing else: its path and its listener, which stays open.
local function host_socket(tmp: string): string, Net.Listener
  assert(Fs.mkdirs(tmp .. "/socks"))
  local path = tmp .. "/socks/host.sock"
  return path, (assert(Net.listen(Net.unix(path), { timeout_ns = 1000000000 })))
end

--- Whether `said` is the filter's refusal of the socket call, which a
--- connect that reached the kernel is not.
local function refused(said: string): boolean
  return said:find("not permitted", 1, true) ~= nil
end

local function test_a_root_of_its_own_tmpfs_alone_makes_a_unix_socket_there(tmp: string)
  local abi, trouble = process.landlock_abi()
  if abi == nil then
    if confine.sandbox_platform() then Test.skip("no Landlock here: " .. tostring(trouble)) end
    return
  end
  if unix_socket.skipped(tmp) then return end
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  -- What it makes in its own /tmp it also reaches there, whatever Landlock's ABI.
  local made = in_sandbox(tmp, probe, rooted_with(probe, {}), "loopback-unix /tmp/pair.sock")
  if made.code == -1 then return end
  assert(made.code == 0 and made.said == "connected\n", "made in its own tmpfs: " .. made.said)
  -- A file that is no socket beside it changes nothing.
  local beside = in_sandbox(tmp, probe, rooted_with(probe, { "/dev/zero" }), "loopback-unix /tmp/pair.sock")
  assert(beside.code == 0 and beside.said == "connected\n", "beside a file: " .. beside.said)
  -- Never beyond its own network: an abstract name is the namespace's.
  local shared = rooted_with(probe, {})
  shared.offline = false
  local open = in_sandbox(tmp, probe, shared, "loopback-unix /tmp/pair.sock")
  assert(refused(open.said), "refused without its own network: " .. open.said)
end

--- [`rooted_with`], as a start that promises `nest` makes it: no Landlock
--- ruleset holds it, so its root alone does.
local function nesting(probe: string, shown: {string}): raw_process.Sandbox
  local sandbox = rooted_with(probe, shown)
  sandbox.grants = nil
  sandbox.promises = { "nest" }
  return sandbox
end

local function test_a_nest_start_with_a_root_of_files_alone_makes_a_unix_socket(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local made = in_sandbox(tmp, probe, nesting(probe, {}), "loopback-unix /tmp/pair.sock")
  if made.code == -1 then return end
  assert(made.code == 0 and made.said == "connected\n", "made in its own tmpfs: " .. made.said)
  -- A file that is no socket beside it changes nothing.
  local beside = in_sandbox(tmp, probe, nesting(probe, { "/dev/zero" }), "loopback-unix /tmp/pair.sock")
  assert(beside.code == 0 and beside.said == "connected\n", "beside a file: " .. beside.said)
  -- Never without a network namespace of its own, where an abstract name is the host's.
  local shared = nesting(probe, {})
  shared.offline = false
  local open = in_sandbox(tmp, probe, shared, "loopback-unix /tmp/pair.sock")
  assert(refused(open.said), "refused without its own network: " .. open.said)
end

local function test_a_nest_start_whose_root_shows_a_host_directory_or_socket_is_refused_a_unix_socket(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local socket, listener = host_socket(tmp)
  local control = in_sandbox(tmp, probe, nesting(probe, {}), "connect /none.sock")
  if control.code == -1 then
    assert(listener:close())
    return
  end
  assert(not refused(control.said), "held, with nothing shown: " .. control.said)
  -- No Landlock ABI tells the host's socket from the program's own, whatever
  -- the kernel gives: the root is all that holds a nest start.
  local directory = in_sandbox(tmp, probe, nesting(probe, { tmp .. "/socks" }), "connect " .. socket)
  assert(refused(directory.said), "a directory of the host: " .. directory.said)
  local file = in_sandbox(tmp, probe, nesting(probe, { socket }), "connect " .. socket)
  assert(refused(file.said), "a socket file of the host: " .. file.said)
  assert(listener:close())
end

local function test_a_root_that_shows_a_directory_of_the_host_is_held_by_landlock_alone(tmp: string)
  local abi = process.landlock_abi()
  if abi == nil or unix_socket.skipped(tmp) then return end
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local socket, listener = host_socket(tmp)
  local control = in_sandbox(tmp, probe, rooted_with(probe, {}), "connect /none.sock")
  if control.code == -1 then
    assert(listener:close())
    return
  end
  assert(not refused(control.said), "held, with nothing shown: " .. control.said)
  -- The directory holds a socket a host service made: below ABI 9 nothing
  -- else tells it from the program's own, so socket() is refused; from
  -- ABI 9 it is made and the connect is refused by Landlock.
  local shown = in_sandbox(tmp, probe, rooted_with(probe, { tmp .. "/socks" }), "connect " .. socket)
  assert(shown.said ~= "connected\n", "not reached: " .. shown.said)
  if abi < 9 then assert(refused(shown.said), "socket() refused below ABI 9: " .. shown.said) end
  assert(listener:close())
end

local function test_a_socket_file_in_the_root_is_not_held_below_abi_9(tmp: string)
  local abi = process.landlock_abi()
  if abi == nil or unix_socket.skipped(tmp) then return end
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local socket, listener = host_socket(tmp)
  local control = in_sandbox(tmp, probe, rooted_with(probe, {}), "connect /none.sock")
  if control.code == -1 then
    assert(listener:close())
    return
  end
  assert(not refused(control.said), "held, with nothing shown: " .. control.said)
  local shown = in_sandbox(tmp, probe, rooted_with(probe, { socket }), "connect " .. socket)
  assert(shown.said ~= "connected\n", "not reached: " .. shown.said)
  if abi < 9 then assert(refused(shown.said), "socket() refused below ABI 9: " .. shown.said) end
  assert(listener:close())
end

--- O_PATH, which sys.open takes as a number.
local O_PATH <const> = 2097152

local function test_a_descriptor_that_opens_a_directory_or_a_socket_is_not_held_below_abi_9(tmp: string)
  local abi = process.landlock_abi()
  if abi == nil or unix_socket.skipped(tmp) then return end
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local socket, listener = host_socket(tmp)
  local sandbox = rooted_with(probe, {})
  -- A file descriptor leads nowhere beyond its file.
  local file = assert(sys.open(tmp .. "/file", sys.O_CREAT | sys.O_RDWR, 420))
  local plain = in_sandbox(tmp, probe, sandbox, "connect /none.sock", { [3] = file })
  sys.close(file)
  if plain.code == -1 then
    assert(listener:close())
    return
  end
  assert(not refused(plain.said), "held with a file handed: " .. plain.said)
  -- A directory is a way to its sockets (/proc/self/fd/N/host.sock), and
  -- an O_PATH descriptor of a socket file is a way to connect to it.
  local directory = assert(sys.open(tmp .. "/socks", sys.O_RDONLY))
  local named = assert(sys.open(socket, O_PATH))
  local ways: {{integer | string}} = { { directory, "/proc/self/fd/3/host.sock" },
    { named, "/proc/self/fd/3" } }
  for _, way in ipairs(ways) do
    local result = in_sandbox(tmp, probe, rooted_with(probe, {}), "connect " .. (way[2] as string),
      { [3] = way[1] as integer })
    assert(result.said ~= "connected\n", "not reached: " .. result.said)
    if abi < 9 then
      assert(refused(result.said), "socket() refused below ABI 9: " .. result.said)
    end
  end
  sys.close(directory)
  sys.close(named)
  assert(listener:close())
end

--- Starts `sandbox` with the stand-in, with no script of weight: the pid,
--- or nil and why the start failed.
local function start(probe: string, sandbox: raw_process.Sandbox): integer | nil, string
  local null = assert(sys.open("/dev/null", sys.O_RDWR))
  local pid, trouble = process.spawn(probe, { probe, "print started" }, nil, "/", nil, null, null, false,
    nil, sandbox)
  sys.close(null)
  if pid ~= nil then assert(process.waitpid(pid, false)) end
  return pid, trouble
end

local function test_a_unix_socket_below_abi_9_fails_a_start_that_binds_a_directory(tmp: string)
  local abi, trouble = process.landlock_abi()
  if abi == nil then
    if confine.sandbox_platform() then Test.skip("no Landlock here: " .. tostring(trouble)) end
    return
  end
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  assert(Fs.mkdirs(tmp .. "/socks") and Fs.write(tmp .. "/u.file", "x"))
  -- A `u` grant allows unix sockets (the start's `sockets`), so the root alone must
  -- show no directory below ABI 9: Lua's check of it is one stat of a path, which a
  -- swap may outrun, so the child refuses a path that is a directory when bound.
  local function with_u(shown: {string}): raw_process.Sandbox
    local sandbox = rooted_with(probe, shown)
    sandbox.sockets = { "unix" }
    sandbox.grants = { { path = probe, access = "rx" }, { path = tmp .. "/u.file", access = "u" } }
    sandbox.unveil.reads[#sandbox.unveil.reads + 1] = tmp .. "/u.file"
    return sandbox
  end
  local pid, why = start(probe, with_u({}))
  if pid == nil and confine.sandbox_platform() then
    Test.skip("no such sandbox: " .. tostring(why))
  end
  if pid == nil then return end
  local shown, refusal = start(probe, with_u({ tmp .. "/socks" }))
  if abi < 9 then
    assert(shown == nil and tostring(refusal):find("changed kind", 1, true), "refused: " .. tostring(refusal))
  else
    assert(shown ~= nil, "Landlock holds it from ABI 9: " .. tostring(refusal))
  end
end

local function test_a_path_swapped_for_a_directory_after_the_check_fails_the_start(tmp: string)
  local abi, trouble = process.landlock_abi()
  if abi == nil then
    if confine.sandbox_platform() then Test.skip("no Landlock here: " .. tostring(trouble)) end
    return
  end
  if abi >= 9 then return end
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  assert(Fs.write(tmp .. "/swap-a", "x") and Fs.mkdirs(tmp .. "/swap-b"))
  local null = assert(sys.open("/dev/null", sys.O_RDWR))
  local racer, started = process.spawn(probe, { probe, "flip " .. tmp .. "/swap-a " .. tmp .. "/swap-b" },
    nil, "/", nil, null, null, false, nil, nil)
  sys.close(null)
  assert(racer ~= nil, tostring(started))
  -- The racer puts a file and a directory at the path in turn, and leaves it
  -- absent for an instant between: a start whose check meets the file and whose
  -- bind meets the directory is the one this holds. Where the racer is slow to
  -- run (a host of one processor) most starts meet the gap or no change and
  -- fail or succeed with nothing to judge, so the test says it lost the race
  -- rather than fail: a start that binds a directory and was held to a root
  -- of files alone is refused ("changed kind"), and the other outcomes are the
  -- kernel's own (the path absent, or a directory made for a file) or a start
  -- whose check met the directory, which is held to nothing. The check itself
  -- is the deterministic test above's.
  local caught = false
  for _ = 1, 1500 do
    local pid, why = start(probe, rooted_with(probe, { tmp .. "/swap-a" }))
    if pid == nil and tostring(why):find("changed kind", 1, true) then
      caught = true
      break
    end
  end
  sys.kill(racer, 9)
  assert(process.waitpid(racer, false))
  if not caught and confine.sandbox_platform() then
    Test.skip("the racer won no start in 1500: this host runs it too seldom to meet the " ..
        "window between the start's check and its bind")
  end
end
