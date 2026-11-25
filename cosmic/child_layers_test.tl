--- What [`Child.layers`] (cosmic/child.tl) tells of the layers a start would
--- hold its child to, read from the plan the start hands its spawn, with
--- nothing started: the start's own `rx` in the first ruleset, the boot
--- ruleset of a cosmic child, the exec filter, the sockets and the
--- namespaces.

local Array = require("cosmic.array")
local Child = require("cosmic.child")
local Proc = require("cosmic.proc")
local Sandbox = require("cosmic.sandbox")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local searchable = require("build.searchable")
local Fake = require("cosmic.fake")
local Fs = require("cosmic.fs")
local confine = require("build.confine")

--- The temporary directory, and `nest`, which a start of `isolate` file
--- checks for as a root of its own.
Test.policy{ env = { "TMPDIR" }, grants = { { calls = "nest" } }, profiles = { "system" } }

--- Ends the test on macOS, where a Seatbelt profile holds a child and
--- [`Child.layers`] tells none.
local function skip_on_macos()
  if assert(sys.uname()).sysname == "Darwin" then
    Test.skip("a Seatbelt profile holds a child on macOS, which has no layers to tell")
  end
end

--- The layers of a start of `argv` under `policy`.
local function layers_of(argv: {string}, policy: Sandbox.Policy, cwd?: string): Sandbox.Layers
  local layers, why = Child.layers(argv, { policy = policy, timeout_ns = Child.FOREVER, cwd = cwd })
  assert(layers ~= nil, why)
  return layers
end

--- Whether `paths` grants `letters` on `path`.
local function holds(paths: {Sandbox.Path}, path: string, letters: string): boolean
  for _, grant in ipairs(paths) do
    if grant.path == path and grant.letters == letters then return true end
  end
  return false
end

--- A host program keeps the start's `rx` on itself, so execve is not
--- refused: it has no boot ruleset to give it up.
local function test_a_host_program_keeps_rx_on_itself(tmp: string)
  skip_on_macos()
  local program = assert(Fake.build(searchable.open(tmp) .. "/fake"))
  local layers = layers_of({ program }, { grants = { { path = tmp, letters = "r" } } })
  local real = assert(sys.realpath(program))
  local listed: mut {string} = {}
  for _, grant in ipairs(layers.landlock) do
    listed[#listed + 1] = grant.letters .. " " .. grant.path
  end
  assert(holds(layers.landlock, program, "rx") or holds(layers.landlock, real, "rx"),
    "the start's rx on " .. program .. " is not in the ruleset: " .. table.concat(listed, ", "))
  assert(#layers.boot == 0 and not layers.exec_refused)
end

--- A cosmic child's core holds itself at boot to the policy alone, with no
--- `x`, so execve is refused, its own core included.
local function test_a_cosmic_child_gives_up_its_core_at_boot(tmp: string)
  skip_on_macos()
  local layers = layers_of({ assert(Proc.executable()), "print hi" }, { grants = { { path = tmp, letters = "r" } } })
  assert(#layers.boot > 0 and layers.exec_refused)
  for _, grant in ipairs(layers.boot) do
    assert(grant.letters:find("x", 1, true) == nil, grant.path)
  end
  local ran = false
  for _, grant in ipairs(layers.landlock) do
    if grant.letters:find("x", 1, true) ~= nil then ran = true end
  end
  assert(ran, "the start's rx on the core is not in the first ruleset")
end

--- A loopback address is an inet socket in a network of the child's own,
--- in a user namespace; the rest of the namespaces come with unveiling.
local function test_a_loopback_is_inet_in_a_network_of_its_own(tmp: string)
  skip_on_macos()
  local program = assert(Fake.build(searchable.open(tmp) .. "/fake"))
  local layers = layers_of({ program }, { loopback = { "127.0.0.2" } })
  assert(table.concat(layers.sockets, " ") == "inet", table.concat(layers.sockets, " "))
  local named = table.concat(layers.namespaces, " ")
  local want = if sys.getuid() == 0 then "user pid mount ipc net" else "user net" end
  assert(named == want, named .. ", not " .. want)
  assert(Array.at(layers.loopback, 1) == "127.0.0.2" and #layers.relay == 0 and not layers.root)
end

--- `isolate` file is a root of the child's own, unveiled, and a cosmic
--- child's core gives up its `rx` there too, holding itself at boot to the
--- grants by their names in the root, with the root's own /proc.
local function test_isolate_file_is_a_root_whose_core_gives_up_its_rx(tmp: string)
  skip_on_macos()
  local layers = layers_of({ assert(Proc.executable()), "print hi" },
    { isolate = { "file" }, grants = { { path = tmp, letters = "r" } } }, "/")
  assert(layers.root and #layers.boot > 0 and layers.exec_refused)
  -- A grant with no `from` is placed at its real path, which the layer names.
  local placed = assert(sys.realpath(tmp))
  assert(holds(layers.boot, placed, "r") and holds(layers.boot, "/proc", "r"))
  assert(table.concat(layers.namespaces, " "):find("^user pid mount ipc") ~= nil, table.concat(layers.namespaces, " "))
end

--- A start with no policy, or one that would be refused, tells no layers.
local function test_a_start_that_holds_nothing_or_is_refused_tells_none(tmp: string)
  skip_on_macos()
  local none, why = Child.layers({ assert(Proc.executable()) }, { timeout_ns = Child.FOREVER })
  assert(none == nil and why:find("no policy", 1, true) ~= nil, why)
  local refused, refusal = Child.layers({ tmp .. "/absent" }, { policy = {}, timeout_ns = Child.FOREVER })
  assert(refused == nil and refusal:find("^child: layers: ") ~= nil, refusal)
end

--- The directory `tmp` makes is in both rulesets of a cosmic child, which
--- can then write there; under `isolate` file the /tmp it mounts, and its
--- own /proc, are in the ruleset as the child is given them.
local function test_tmp_is_granted_where_the_start_grants_it(tmp: string)
  skip_on_macos()
  local own = assert(Proc.executable())
  local made = layers_of({ own, "print hi" }, { tmp = true, grants = { { path = tmp, letters = "r" } } })
  local function written(paths: {Sandbox.Path}): boolean
    for _, grant in ipairs(paths) do
      if grant.letters == "rwc" and grant.path:find("TMPDIR", 1, true) ~= nil then return true end
    end
    return false
  end
  assert(written(made.landlock) and written(made.boot), "the directory tmp makes is not granted")
  local rooted = layers_of({ own, "print hi" }, { isolate = { "file" }, tmp = true,
    grants = { { path = tmp, letters = "r" }, { path = "/tmp", letters = "rwxc" } } }, "/")
  assert(holds(rooted.landlock, "/tmp", "rwxc") and holds(rooted.landlock, "/proc", "r"))
end

--- A policy with as many grants as a start takes, which the start then
--- adds its own to (the program's start files, a cosmic child's core), is
--- refused with the count, not raised inside spawn.
local function test_grants_past_the_most_with_the_starts_own_are_refused(tmp: string)
  skip_on_macos()
  local base = searchable.open(tmp)
  local grants: mut {Sandbox.Grant} = {}
  for i = 1, confine.unveil_max do
    local dir = base .. "/g" .. tostring(i)
    assert(Fs.mkdirs(dir))
    grants[#grants + 1] = { path = dir, letters = "r" }
  end
  local program = assert(Fake.build(base .. "/fake"))
  local refused, why = Child.layers({ program }, { policy = { grants = grants }, timeout_ns = Child.FOREVER })
  assert(refused == nil and why:find("past the most a start takes, " .. tostring(confine.unveil_max), 1, true) ~= nil, why)
  local started, failure = Child.run({ program }, { policy = { grants = grants }, timeout_ns = Child.FOREVER })
  assert(started == nil and tostring(failure):find("past the most", 1, true) ~= nil, tostring(failure))
  -- Under `isolate` file each grant is a bind of the root, beside its
  -- /proc: one short of the most, with a cosmic child's core, is past it.
  local fewer: mut {Sandbox.Grant} = {}
  for i = 1, confine.unveil_max - 1 do fewer[i] = assert(grants[i]) end
  local rooted, rooted_why = Child.layers({ assert(Proc.executable()), "-e", "return 0" },
    { policy = { isolate = { "file" }, grants = fewer }, cwd = base, timeout_ns = Child.FOREVER })
  assert(rooted == nil and rooted_why:find("past the most a start takes", 1, true) ~= nil, rooted_why)
end
