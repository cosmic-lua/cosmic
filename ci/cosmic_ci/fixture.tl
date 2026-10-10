local Archive = require("cosmic.archive")
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Project = require("cosmic.project")
local Runner = require("cosmic_ci.runner")
local Plural = require("cosmic_ci.plural")
local sys = require("cosmic.sys")

-- Candidate scripts, applications, and decoder executions normally finish in
-- well under a second. Native decoder compilation opts into its larger bound.
local default_child_timeout_ns <const> = Clock.seconds(30)

--- Where this fixture's children build, once [`Fixture.builds_beneath`]
--- names it; nil until then, for them to build where the environment says.
local build_home: string | nil = nil

local record Fixture
  inherited: {string}

  record Target
    id: integer
    configuration: integer
    kind: string
    name: string
  end

  record Capture
    out: string
    err: string
  end

  record Outcome
    result: Child.Result
    out: string
    err: string
  end

  record Entry
    target: integer
    configuration: integer
    offset: integer
    length: integer
    digest: string
  end

  record Inspection
    prefix_length: integer
    manifest_offset: integer
    manifest_length: integer
    database_offset: integer
    database_length: integer
    entries: {string:Entry}
    entry_count: integer
  end
end

function Fixture.required(name: string): string
  return (assert(Env.get(name), "fixture environment is missing " .. name))
end

--- The build directory of the project at `root` under COSMIC_BUILD_HOME
--- `home`, which an absolute `home` outside the project always has.
local function beneath(root: string, home: string): string
  local location, trouble = Project.directory(root, { COSMIC_BUILD_HOME = home })
  assert(location, "build directory: " .. trouble)
  assert(location.none == "", location.none)
  return location.directory
end

--- Where the driver placed what a setup made for this fixture to read:
--- the absolute path of `fixtures/<kind>` in the build directory of the
--- project the fixture runs in (cosmic_ci/orchestration.tl's `place`),
--- which its declaration names as the grant of `o/fixtures/<kind>`, so
--- its key holds what is there. A child of the fixture, in a directory
--- of its own, is given this path. The driver sets COSMIC_BUILD_HOME in
--- its workers, and has the project's build directory beneath it.
function Fixture.placed(kind: string): string
  return beneath(".", Fixture.required("COSMIC_BUILD_HOME")) .. "/fixtures/" .. kind
end

--- Has every child this fixture starts build under `directory`
--- (COSMIC_BUILD_HOME, [`environment_of`]), made 0700 where it is not
--- there yet. A sandboxed fixture whose children build -- a project, a
--- file run -- calls it first: its worker may write its own directory
--- alone, and a driver whose harness hands its workers no
--- COSMIC_BUILD_HOME leaves them the user's cache, which a sandbox does
--- not give.
function Fixture.builds_beneath(directory: string)
  local made, trouble, errno = sys.mkdir(directory, 0x1c0)
  assert(made or errno == sys.EEXIST, directory .. ": " .. tostring(trouble))
  build_home = (assert(sys.realpath(directory)))
end

--- The build directory of the project at `project` that this fixture's
--- children build in ([`builds_beneath`]).
function Fixture.built(project: string): string
  return beneath(project, (assert(build_home, "Fixture.built: call Fixture.builds_beneath first")))
end

function Fixture.mkdir(path: string)
  assert(Fs.mkdirs(path))
end

function Fixture.read(path: string): string
  return (assert(Fs.read(path)))
end

function Fixture.small(path: string, limit: integer): string
  local size = assert(Fs.stat(path)).size
  assert(size <= limit, path .. ": expected at most " .. Plural.count(limit, "byte") ..
      ", found " .. tostring(size))
  return Fixture.read(path)
end

function Fixture.write(path: string, data: string, mode?: integer)
  assert(Fs.write(path, data, mode))
end

function Fixture.copy(from: string, to: string, mode?: integer)
  Fixture.write(to, Fixture.read(from), mode)
end

--- Unpacks the tar at `tar` into `destination`, which must not exist
--- yet, and answers it: a copy the fixture may write in, of files the
--- runtime setup packed (cosmic_ci/runtime_setup.tl's `pack`).
function Fixture.unpack(tar: string, destination: string): string
  assert(not Fs.exists(destination), "unpack destination already exists: " .. destination)
  Fixture.mkdir(destination)
  local written, trouble = Archive.extract(tar, destination)
  assert(written, tar .. ": " .. tostring(trouble))
  return destination
end

--- The runtime setup's copy of test/portable/tool.tl and the modules of
--- the tree it requires (its `tool.tar`), unpacked beneath `work` once:
--- the directory a tool.tl run starts in, where it resolves its
--- `require`s and writes what it builds (its o/).
function Fixture.tool_tree(fixture_dir: string, work: string): string
  local tree = work .. "/tool-tree"
  if Fs.exists(tree) then return tree end
  return Fixture.unpack(fixture_dir .. "/tool.tar", tree)
end

--- A fresh tree at `tree`, which must not exist yet: a copy of the
--- candidate's tracked source, which the driver unpacks from its
--- `git archive` (COSMIC_FIXTURE_SOURCE, cosmic_ci/orchestration.tl's
--- `phase_fixtures`), the tree the product was booted from.
function Fixture.source_tree(tree: string)
  local copied, trouble = Fs.copy_tree(Fixture.required("COSMIC_FIXTURE_SOURCE"), tree)
  assert(copied, "source tree: " .. tostring(trouble))
end

function Fixture.hash(path: string): string
  return Hash.hex_sha256(Fixture.read(path))
end

--- The variables a fixture's child inherits from the fixture's own
--- environment, and no others: every one that a child the fixtures start
--- reads, on every leg. A module that declares `env` for an unsandboxed
--- fixture (ci/fixtures/*_test.tl) names each of these beside the
--- COSMIC_FIXTURE_* it requires, and cosmic_ci/orchestration_test.tl
--- holds it to that, so the declaration is the truth.
---
--- - PATH, HOME, XDG_CACHE_HOME and TMPDIR: the shell scripts bin/zig,
---   bin/cosmic-bootstrap and the portable launcher, which find their
---   tools and the cores', bootstrap and zig caches by them, and the
---   core's own temporary directory.
--- - COSMIC_PORTABLE_CACHE, COSMIC_VERDICT_CACHE, COSMIC_AUTO_BOOT,
---   COSMIC_TEST_SANDBOX, COSMIC_SANDBOX and COSMIC_TEST_HELD: what a
---   process of the program running the tests reads to run at all
---   (build/this_program.tl's `runtime_environment`, and COSMIC_SANDBOX,
---   which `confine` reads).
--- - COSMIC_BUILD_HOME: the generated-directory base, shared by a child
---   and the driver resolving its products.
--- - COSMIC_BOOTSTRAP: the cosmic bin/zig runs build/zig.tl on, where a
---   run names one (AGENTS.md's Bootstrap).
--- - COSMIC_ZIG, COSMIC_ZIG_CACHE and COSMIC_ZIG_GLOBAL_CACHE: the zig
---   build/zig.tl runs and where it keeps its caches, which CI restores
---   (the driver sets the project cache, cosmic-driver.sh the global).
--- - ZIG_LIB_DIR, ZIG_GLOBAL_CACHE_DIR and ZIG_LOCAL_CACHE_DIR: zig's own,
---   which build/zig.tl leaves as the caller names them.
--- - SDKROOT, DEVELOPER_DIR and MACOSX_DEPLOYMENT_TARGET: where zig and
---   the system's toolchain shims (xcrun) find macOS's SDK, and the
---   target zig builds for there. Unset on the Linux legs.
--- - COSMIC_TEST_TIMEOUT: the deadline the driver gives a fixture's
---   tests (orchestration.tl's `fixture_test`), which the nested
---   `cosmic test` runs in self_rebuild_test inherit, since a rebuild
---   there exceeds the 30 s default.
--- - FUZZ_ITERS: 0 on every operation (orchestration.tl's `environment`),
---   so a nested run draws no fuzz inputs.
--- - COSMIC_BOOTSTRAP_ATTEMPTS, COSMIC_BOOTSTRAP_VERIFY, SSL_CERT_FILE,
---   SSL_CERT_DIR, CURL_CA_BUNDLE and the proxy variables (HTTPS_PROXY,
---   HTTP_PROXY, NO_PROXY, ALL_PROXY, and their lower-case forms): how
---   a cold cache fetches. bin/cosmic-bootstrap's curl or wget read
---   them, core/http.c reads SSL_CERT_FILE, and build/c/init.tl's
---   `passed` names the same set for the C compiles.
-- TODO: list what a macOS leg's zig and system shims read beyond these
-- (TOOLCHAINS for xcrun, say) once a macOS leg's run has been read for
-- it: a variable missing here breaks that leg alone, naming nothing.
Fixture.inherited = {
  "PATH", "HOME", "XDG_CACHE_HOME", "TMPDIR",
  "COSMIC_PORTABLE_CACHE", "COSMIC_VERDICT_CACHE", "COSMIC_AUTO_BOOT",
  "COSMIC_TEST_SANDBOX", "COSMIC_SANDBOX", "COSMIC_TEST_HELD",
  "COSMIC_BOOTSTRAP", "COSMIC_BUILD_HOME",
  "COSMIC_ZIG", "COSMIC_ZIG_CACHE", "COSMIC_ZIG_GLOBAL_CACHE",
  "ZIG_LIB_DIR", "ZIG_GLOBAL_CACHE_DIR", "ZIG_LOCAL_CACHE_DIR",
  "SDKROOT", "DEVELOPER_DIR", "MACOSX_DEPLOYMENT_TARGET",
  "COSMIC_TEST_TIMEOUT", "FUZZ_ITERS",
  "COSMIC_BOOTSTRAP_ATTEMPTS", "COSMIC_BOOTSTRAP_VERIFY",
  "SSL_CERT_FILE", "SSL_CERT_DIR", "CURL_CA_BUNDLE",
  "ALL_PROXY", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY",
  "all_proxy", "https_proxy", "http_proxy", "no_proxy",
}

--- The environment for a child a fixture starts, with `extra` set over
--- it: of `base`, the fixture's own (`environment` makes it of that),
--- the variables of [`inherited`] it has, and nothing else. A copy,
--- which `base` keeps nothing of. The child
--- shares no compiles or parses (COSMIC_BUILD_CACHE=0) unless `extra`
--- says otherwise. The fixture's own run shares one file with the leg's
--- other fixtures (`Orchestration.fixture`), but a tree a child builds (a
--- fresh checkout's boot, the product rebuilding itself) is what a
--- fixture checks compiles, and work another child or fixture left in
--- that file would stand in for it (fixed_point_test's compiler cases,
--- self_rebuild_test's docs verb). A case that checks a rebuild's way and
--- not its compile names a file of its own (self_rebuild_test's
--- `seeded_compiles`, fixed_point_test's COSMIC_FIXTURE_SHARED_COMPILES).
---
--- Nor does a `cosmic test` the child runs sandbox its workers
--- (COSMIC_TEST_SANDBOX=0): what a fixture asserts of such a run is its
--- tally, not its sandbox, and a fixture's own worker is sandboxed
--- (`Orchestration.fixture`), which a sandbox of the child's would nest
--- in only as deep as the host allows. So it means the same on every
--- host, as doc/testing.md asks of a test's own `cosmic test`.
function Fixture.environment_of(base: {string:string},
                                extra?: {string:string}): {string:string}
  local environment: {string:string} = {}
  for _, name in ipairs(Fixture.inherited) do
    if base[name] ~= nil then environment[name] = base[name] end
  end
  if build_home ~= nil then environment.COSMIC_BUILD_HOME = build_home end
  environment.COSMIC_BUILD_CACHE = "0"
  environment.COSMIC_TEST_SANDBOX = "0"
  if extra then
    for name, value in pairs(extra) do environment[name] = value end
  end
  return environment
end

--- [`environment_of`] the fixture's own environment.
function Fixture.environment(extra?: {string:string}): {string:string}
  return Fixture.environment_of(Env.all(), extra)
end

local function preview(path: string): string
  local fd = assert(Fs.open_read(path))
  local called, answer, trouble = pcall(Fs.take, fd, 8192)
  local closed, close_trouble = Fs.close(fd)
  if not called then error(answer) end
  assert(closed, close_trouble)
  return (assert(answer as string | nil, trouble))
end

function Fixture.call_with_environment(label: string, argv: {string},
                                       directory: string, diagnostics: string, environment: {string:string},
                                       timeout_ns?: integer, input?: string,
                                       fds?: {integer:integer}): Fixture.Outcome
  Fixture.mkdir(diagnostics)
  local out = diagnostics .. "/" .. label .. ".out"
  local err = diagnostics .. "/" .. label .. ".err"
  local outcome = Runner.execute({ argv = argv, cwd = directory,
    env = environment, timeout_ns = timeout_ns or default_child_timeout_ns,
    input = input, output = out, error = err, fds = fds })
  if not outcome.result then
    error(label .. ": could not start: " .. tostring(outcome.trouble) ..
        "; stdout=" .. out .. "; stderr=" .. err)
  end
  local finished = outcome.result as Child.Result
  assert(Fs.put(Fs.stderr, "fixture: " .. label .. ": DONE (" ..
      tostring(outcome.elapsed_ns // 1000000) .. " ms; code=" ..
      tostring(finished.code) .. "; signal=" .. tostring(finished.signal) ..
      "; timed_out=" .. tostring(finished.timed_out) .. ")\n"))
  return { result = finished, out = out, err = err }
end

--- [`call_with_environment`] with each file of `paths` open for reading on
--- the descriptor it is keyed by, in the child only.
function Fixture.call_with_descriptors(label: string, argv: {string},
                                       directory: string, diagnostics: string, environment: {string:string},
                                       paths: {integer:string}): Fixture.Outcome
  local fds: {integer:integer} = {}
  local called, answer = pcall(function(): Fixture.Outcome
    for number, path in pairs(paths) do
      fds[number] = assert(Fs.open_read(path))
    end
    return Fixture.call_with_environment(label, argv, directory, diagnostics,
      environment, nil, nil, fds)
  end)
  for _, fd in pairs(fds) do Fs.close(fd) end
  if not called then error(answer) end
  return answer as Fixture.Outcome
end

function Fixture.call(label: string, argv: {string}, directory: string,
                      diagnostics: string, extra?: {string:string}, timeout_ns?: integer,
                      input?: string): Fixture.Outcome
  return Fixture.call_with_environment(label, argv, directory, diagnostics,
    Fixture.environment(extra), timeout_ns, input)
end

--- The streams of a call that succeeded; one that did not raises, naming
--- how it ended and showing the start of what it wrote.
function Fixture.succeeded(label: string, outcome: Fixture.Outcome): Fixture.Capture
  local finished = outcome.result
  if not finished.ok then
    error(label .. ": failed code=" .. tostring(finished.code) ..
        " signal=" .. tostring(finished.signal) ..
        " timed_out=" .. tostring(finished.timed_out) ..
        "; stdout=" .. outcome.out .. "; stderr=" .. outcome.err ..
        "; output preview:\n" .. preview(outcome.out) .. preview(outcome.err))
  end
  return { out = outcome.out, err = outcome.err }
end

function Fixture.run(label: string, argv: {string}, directory: string,
                     diagnostics: string, extra?: {string:string}, timeout_ns?: integer,
                     input?: string): Fixture.Capture
  return Fixture.succeeded(label, Fixture.call(label, argv, directory,
    diagnostics, extra, timeout_ns, input))
end

function Fixture.contains(path: string, expected: string)
  local text = preview(path)
  assert(text:find(expected, 1, true),
    path .. ": missing expected text: " .. expected)
end

function Fixture.targets(path: string): {Fixture.Target}
  local targets: {Fixture.Target} = {}
  local pairs_seen: {string:boolean} = {}
  local names_seen: {string:boolean} = {}
  local contents = Fixture.read(path)
  assert(contents:sub(1, 1) ~= "\n" and contents:sub(-1) == "\n" and
      not contents:find("\n\n", 1, true),
    "generated targets have empty or unterminated records")
  for line in contents:gmatch("[^\n]+") do
    local id_text, configuration_text, kind, name, uname_os, uname_arch =
      line:match("^(%d+)\t(%d+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
    local id = id_text and math.tointeger(tonumber(id_text)) or nil
    local configuration = configuration_text and
      math.tointeger(tonumber(configuration_text)) or nil
    assert(id and configuration and kind and name and uname_os and uname_arch,
      "invalid generated target record: " .. line)
    local pair = tostring(id) .. ":" .. tostring(configuration)
    assert(not pairs_seen[pair], "duplicate target/configuration: " .. pair)
    assert(not names_seen[name], "duplicate target name: " .. name)
    pairs_seen[pair], names_seen[name] = true, true
    targets[#targets + 1] = {
      id = id,
      configuration = configuration,
      kind = kind,
      name = name,
    }
  end
  assert(#targets > 0, "generated targets are empty")
  return targets
end

function Fixture.inspection(path: string): Fixture.Inspection
  local prefix_length: integer | nil = nil
  local manifest_offset: integer | nil = nil
  local manifest_length: integer | nil = nil
  local database_offset: integer | nil = nil
  local database_length: integer | nil = nil
  local declared_count: integer | nil = nil
  local entries: {string:Fixture.Entry} = {}
  local count = 0
  local contents = Fixture.small(path, 8192)
  assert(contents:sub(1, 1) ~= "\n" and contents:sub(-1) == "\n" and
      not contents:find("\n\n", 1, true),
    "decoder inspection has empty or unterminated records")
  for line in contents:gmatch("[^\n]+") do
    if line:sub(1, 7) == "prefix " then
      assert(prefix_length == nil, "duplicate decoder prefix record")
      local p, mo, ml, db, dl, ec = line:match(
        "^prefix (%d+) manifest (%d+) (%d+) database (%d+) (%d+) entries (%d+)$")
      prefix_length = math.tointeger(assert(tonumber(p)))
      manifest_offset = math.tointeger(assert(tonumber(mo)))
      manifest_length = math.tointeger(assert(tonumber(ml)))
      database_offset = math.tointeger(assert(tonumber(db)))
      database_length = math.tointeger(assert(tonumber(dl)))
      declared_count = math.tointeger(assert(tonumber(ec)))
    elseif line:sub(1, 6) == "entry " then
      local target_text, configuration_text, offset_text, length_text, digest =
        line:match("^entry (%d+) (%d+) (%d+) (%d+) ([0-9a-f]+)$")
      local target = math.tointeger(assert(tonumber(target_text)))
      local configuration =
        math.tointeger(assert(tonumber(configuration_text)))
      local offset = math.tointeger(assert(tonumber(offset_text)))
      local length = math.tointeger(assert(tonumber(length_text)))
      assert(target and configuration and offset and length and digest and
          #digest == 64, "invalid decoder entry record: " .. line)
      local key = tostring(target) .. ":" .. tostring(configuration)
      assert(entries[key] == nil, "duplicate decoder entry record: " .. key)
      entries[key] = { target = target, configuration = configuration,
        offset = offset, length = length, digest = digest }
      count = count + 1
    else
      error("unexpected decoder inspection record: " .. line)
    end
  end
  assert(prefix_length and manifest_offset and manifest_length and
      database_offset and database_length and declared_count,
    "decoder prefix record is missing")
  assert(count == declared_count, "decoder entry count differs")
  return { prefix_length = prefix_length, manifest_offset = manifest_offset,
    manifest_length = manifest_length, database_offset = database_offset,
    database_length = database_length, entries = entries, entry_count = count }
end

function Fixture.entry(inspection: Fixture.Inspection, target: integer,
                       configuration: integer): Fixture.Entry | nil
  return inspection.entries[tostring(target) .. ":" .. tostring(configuration)]
end

function Fixture.assert_executable(path: string)
  local st = assert(Fs.stat(path))
  assert(st.kind == "file" and st.mode & 0x49 == 0x49,
    "executable mode is missing: " .. path)
end

return Fixture
