local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Predicate = require("cosmic_ci.fs_predicate")
local sys = require("cosmic.sys")
local Fixture = require("cosmic_ci.fixture")

-- Bound subprocess waits and the shorter paused-build handshakes separately.
local child_wait_timeout_ms <const> = 30000
local handshake_timeout_ms <const> = 5000

-- The fixed name, under the shared `TMPDIR` every test in this one `cosmic
-- test` process was started with, that carries the primary run's finished
-- `project` directory to the transported run. `Fs.mkdtemp` (build/test.tl's
-- "fresh, writable directory... made just for it" per test function) always
-- makes each test function its OWN directory, so the two functions below
-- cannot rely on their own `tmp` arguments to agree on a location; TMPDIR
-- itself, however, is one process-wide environment value both share; see
-- `test_identity_transported` below.
local transported_state_name <const> = "cosmic-identity-transported-state"

local function chmod(path: string, mode: integer)
  assert(sys.chmod(path, mode))
end

-- Both inputs must contain the entire prefix; neither must end at its boundary.
local function compare_file_prefixes(left: string, right: string,
    length: integer)
  assert(#left >= length,
    "left file is shorter than the compared prefix: " .. tostring(#left) ..
    " < " .. tostring(length))
  assert(#right >= length,
    "right file is shorter than the compared prefix: " .. tostring(#right) ..
    " < " .. tostring(length))
  assert(left:sub(1, length) == right:sub(1, length),
    "compared file prefixes differ")
end

-- Require one or more digits followed only by optional newlines.
local function read_prefix_length(fixture_dir: string): integer
  local text = Fixture.read(fixture_dir .. "/runtime.old.prefix-length")
  local digits = text:match("^(%d+)\n*$")
  return assert(digits and math.tointeger(tonumber(digits)),
    "invalid prefix length: " .. text)
end

-- Teal has no recursive-copy primitive, so use the standard POSIX utility.
local function copy_tree(label: string, from: string, to: string, cwd: string,
    diagnostics: string)
  Fixture.run(label, { "/usr/bin/env", "cp", "-R", from, to }, cwd, diagnostics)
end

-- Counts the plain files directly inside `directory`. The portable cache is
-- assumed flat, the same assumption launcher_test.tl's `only_core` and
-- `no_private_entries` make about a cache directory.
local function count_cache_files(directory: string): integer
  local count = 0
  for _, name in ipairs(assert(Fs.list(directory))) do
    if assert(Fs.stat(directory .. "/" .. name)).kind == "file" then
      count = count + 1
    end
  end
  return count
end

local function host_uname(work: string, diagnostics: string, flag: string,
    label: string): string
  local answer = Fixture.run("uname-" .. label,
    { "/usr/bin/env", "uname", flag }, work, diagnostics)
  return assert(Fixture.small(answer.out, 256):match("^(%S+)"),
    "uname " .. flag .. " produced no output")
end

-- Find the single generated target whose uname fields match this host.
-- `Fixture.targets` discards those fields, so it cannot perform this lookup.
local function host_target_field(fixture_dir: string, work: string,
    diagnostics: string): string
  local sysname = host_uname(work, diagnostics, "-s", "sysname")
  local arch = host_uname(work, diagnostics, "-m", "arch")
  local found: string | nil = nil
  for line in Fixture.read(fixture_dir .. "/targets.tsv"):gmatch("[^\n]+") do
    local name, uname_os, uname_arch = line:match(
      "^%d+\t%d+\t[^\t]+\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
    assert(name and uname_os and uname_arch,
      "invalid generated target record: " .. line)
    if uname_os == sysname and uname_arch == arch then
      assert(found == nil, "multiple generated targets match this host")
      found = name
    end
  end
  return assert(found, "no generated target matches this host: " ..
    sysname .. " " .. arch)
end

local record Running
  handle: Child.Handle
  out_fd: integer
  err_fd: integer
  out: string
  err: string
  closed: boolean
end

local function start(label: string, argv: {string}, cwd: string,
    values: {string:string}, diagnostics: string): Running
  local out = diagnostics .. "/" .. label .. ".out"
  local err = diagnostics .. "/" .. label .. ".err"
  local out_fd = assert(Fs.open_write(out))
  local err_fd = assert(Fs.open_write(err))
  local options: Child.Options = { cwd = cwd, env = values,
    stdout = out_fd, stderr = err_fd, process_group = false }
  local handle, trouble = Child.start(argv, options)
  if handle == nil then
    Fs.close(out_fd); Fs.close(err_fd)
    error(label .. ": " .. trouble)
  end
  return { handle = handle, out_fd = out_fd, err_fd = err_fd,
    out = out, err = err, closed = false }
end

local function close_descriptors(running: Running)
  if not running.closed then
    assert(Fs.close(running.out_fd)); assert(Fs.close(running.err_fd))
    running.closed = true
  end
end

local function finish(running: Running, timeout?: integer): Child.Result
  local result, trouble = running.handle:wait(timeout or child_wait_timeout_ms)
  if result == nil then
    running.handle:close(); close_descriptors(running)
    error("identity child wait failed: " .. trouble)
  end
  close_descriptors(running)
  return result as Child.Result
end

local function cleanup(running: Running)
  if not running.closed then
    running.handle:close()
    close_descriptors(running)
  end
end

local function supervised(action: function({Running}))
  local active: {Running} = {}
  local called, failure = pcall(function(): boolean
    action(active); return true
  end)
  for _, running in ipairs(active) do cleanup(running) end
  if not called then error(failure) end
end

local function fifo(work: string, diagnostics: string, name: string): string
  local path = work .. "/" .. name
  Fixture.run("mkfifo-" .. name, { "/usr/bin/env", "mkfifo", path }, work,
    diagnostics)
  return path
end

local function await_ready(work: string, diagnostics: string, label: string,
    path: string)
  local answer = Fixture.run("ready-" .. label,
    { "/usr/bin/env", "cat", path }, work, diagnostics, nil,
    handshake_timeout_ms)
  assert(Fixture.small(answer.out, 128) == "ready\n",
    "identity startup hook readiness differs")
end

local function release(work: string, diagnostics: string, label: string,
    path: string)
  local input = work .. "/release-" .. label
  Fixture.write(input, "go\n")
  Fixture.run("release-" .. label, { "/usr/bin/env", "tee", path }, work,
    diagnostics, nil, handshake_timeout_ms, input)
end

-- The unlink-during-build and rename-during-build races: a throwaway copy of
-- `runtime.old` pauses right after adopting its own descriptor, its logical
-- pathname is removed or replaced out from under it, and releasing it lets
-- the build finish reading from the one retained descriptor. `action` is
-- "unlink" or "rename".
local function run_build_race(project: string, cache: string,
    fixture_dir: string, runtime_prefix: string, prefix_length: integer,
    work: string, diagnostics: string, action: string)
  local copy_path = work .. "/" .. action .. "-runtime"
  Fixture.copy(fixture_dir .. "/runtime.old", copy_path, 0x1ed)
  local ready = fifo(work, diagnostics, action .. "-ready")
  local go = fifo(work, diagnostics, action .. "-go")
  supervised(function(active: {Running})
    local values = Fixture.environment({
      COSMIC_PORTABLE_CACHE = cache,
      COSMIC_PORTABLE_STARTUP_TEST_READY = ready,
      COSMIC_PORTABLE_STARTUP_TEST_GO = go,
    })
    local child = start(action .. "-build", { copy_path, "build" }, project,
      values, diagnostics)
    active[#active + 1] = child

    await_ready(work, diagnostics, action, ready)
    if action == "rename" then
      assert(Fs.rename(copy_path, work .. "/" .. action .. "-away"))
    else
      assert(Fs.remove(copy_path))
    end
    release(work, diagnostics, action, go)

    local result = finish(child)
    assert(result.ok, action .. ": build did not exit successfully")
    Fixture.contains(child.out, "build: PASS (o/bin/hello, o/bin/second")
    compare_file_prefixes(runtime_prefix,
      Fixture.read(project .. "/o/bin/hello"), prefix_length)
  end)
end

-- The PASS tally is emitted on stdout; diagnostics are captured separately.
local function run_release(project: string, cache: string, counter: string,
    diagnostics: string, artifact: string, label: string): Fixture.Capture
  return Fixture.run(label, { artifact, "test" }, project, diagnostics,
    { COSMIC_PORTABLE_CACHE = cache, COSMIC_FIXTURE_COUNTER = counter })
end

local function expect_tally(capture: Fixture.Capture, ran: integer,
    stood: integer)
  Fixture.contains(capture.out, "test: PASS (1 tests, 1 modules; " ..
    tostring(ran) .. " ran, " .. tostring(stood) .. " stood")
end

-- Run the raw sanitized core outside its runtime wrapper, with the full private
-- COSMIC_PORTABLE_* contract supplied by hand and the artifact/core opened
-- on descriptors 8/9. `Child.Options` only redirects stdin/stdout/stderr, so
-- opening arbitrary extra descriptors before exec needs a real shell
-- wrapper -- the same approach launcher_test.tl's
-- `test_launcher_descriptors_exit_and_signal` uses for descriptor-passing.
local function run_sanitized(fixture_dir: string, root: string,
    project: string, counter: string, work: string,
    diagnostics: string): Fixture.Capture
  local artifact = fixture_dir .. "/runtime.sanitized"
  local target_id = assert(Fixture.small(
    fixture_dir .. "/sanitized-target-id", 256):match("^(%S+)"),
    "sanitized-target-id is empty")
  local core_name = assert(Fixture.small(
    fixture_dir .. "/sanitized-core-name", 256):match("^(%S+)"),
    "sanitized-core-name is empty")
  local core = fixture_dir .. "/sanitized-cores/" .. core_name ..
    "/cosmic-core"

  local entry_cache = work .. "/entry-cache"
  -- tool.tl's own require("build.artifact")/require("test.portable.
  -- artifact_fixture") resolve relative to the process cwd, so this must
  -- run from `root`, matching identity test's own unwrapped invocation
  -- (no `cd`, so it inherited the whole script's cwd, which is `root`).
  local entry_out = Fixture.run("sanitized-entry",
    { fixture_dir .. "/runtime.old", root .. "/test/portable/tool.tl",
      "entry", artifact, target_id, "2" }, root, diagnostics,
    { COSMIC_PORTABLE_CACHE = entry_cache })
  local offset, length, digest = Fixture.small(entry_out.out, 256):match(
    "^(%d+)[ \t]+(%d+)[ \t]+([0-9a-f]+)\n?$")
  assert(offset and length and digest, "sanitized entry fields are invalid")
  chmod(core, 0x1ed)

  -- Open the artifact and core on the descriptors named by the private contract.
  local script = [[
exec 8< "$1"
exec 9< "$2"
exec "$2" --artifact "$1" test
]]
  return Fixture.run("sanitized", { "/bin/sh", "-c", script, "sh",
      artifact, core }, project, diagnostics, {
    COSMIC_FIXTURE_COUNTER = counter,
    COSMIC_PORTABLE_ARTIFACT_FD = "8",
    COSMIC_PORTABLE_CORE_FD = "9",
    COSMIC_PORTABLE_TARGET_ID = target_id,
    COSMIC_PORTABLE_CONFIGURATION_ID = "2",
    COSMIC_PORTABLE_CORE_OFFSET = offset,
    COSMIC_PORTABLE_CORE_LENGTH = length,
    COSMIC_PORTABLE_CORE_SHA256 = digest,
  })
end

-- Build the primary project, then snapshot it under the shared TMPDIR for the
-- transported test, whose own `tmp` directory is unrelated.
local function test_identity_primary(tmp: string)
  local fixture_dir = Fixture.required("COSMIC_FIXTURE_RUNTIME")
  local root = Fixture.required("COSMIC_FIXTURE_ROOT")
  local work = tmp
  local diagnostics = work .. "/logs"
  Fixture.mkdir(diagnostics)

  local project = work .. "/project"
  Fixture.mkdir(project .. "/cmd/hello")
  Fixture.copy(fixture_dir .. "/runtime_test.tl", project .. "/runtime_test.tl")
  Fixture.copy(fixture_dir .. "/hello_main.tl", project .. "/cmd/hello/main.tl")
  Fixture.mkdir(project .. "/cmd/second")
  Fixture.copy(root .. "/ci/testdata/portable/cmd/second/main.tl",
    project .. "/cmd/second/main.tl")
  local counter = project .. "/test-runs"
  local cache = work .. "/cache"

  -- Run just build/embed_test.tl under the real portable runtime. Its four
  -- cases cover the portable database and retained-prefix expectations.
  local focused = work .. "/focused-embed"
  Fixture.mkdir(focused)
  copy_tree("copy-build", root .. "/build", focused .. "/build", work,
    diagnostics)
  local focused_run = Fixture.run("focused-embed", { fixture_dir .. "/runtime.old",
    "test", "build/embed_test.tl" }, focused, diagnostics,
    { COSMIC_PORTABLE_CACHE = cache })
  Fixture.contains(focused_run.out,
    "test: PASS (4 tests, 1 modules; 4 ran, 0 stood")

  local build1 = Fixture.run("build", { fixture_dir .. "/runtime.old", "build" },
    project, diagnostics, { COSMIC_PORTABLE_CACHE = cache })
  Fixture.contains(build1.out, "build: PASS (o/bin/hello, o/bin/second")

  local prefix_length = read_prefix_length(fixture_dir)
  local runtime_prefix = Fixture.read(fixture_dir .. "/runtime.old.prefix")
  for _, application in ipairs({ "hello", "second" }) do
    local output = project .. "/o/bin/" .. application
    Fixture.assert_executable(output)
    local bytes = Fixture.read(output)
    assert(bytes:sub(1, 10):find("#!/bin/sh", 1, true),
      application .. ": missing shebang")
    compare_file_prefixes(runtime_prefix, bytes, prefix_length)
  end

  local hello_before_edit = Fixture.read(project .. "/o/bin/hello")
  local hello_source = Fixture.read(fixture_dir .. "/hello_main.tl")
  local edited = hello_source:gsub("hello from the portable fixture",
    "hello from the edited portable fixture")
  assert(edited ~= hello_source,
    "hello fixture source substitution did not match")
  Fixture.write(project .. "/cmd/hello/main.tl", edited)
  local rebuild = Fixture.run("rebuild", { fixture_dir .. "/runtime.old", "build" },
    project, diagnostics, { COSMIC_PORTABLE_CACHE = cache })
  Fixture.contains(rebuild.out, "build: PASS (o/bin/hello, o/bin/second")
  local hello_after_edit = Fixture.read(project .. "/o/bin/hello")
  compare_file_prefixes(hello_before_edit, hello_after_edit, prefix_length)
  assert(hello_before_edit ~= hello_after_edit,
    "portable identity: application edit did not change its suffix")

  -- The build consumes the descriptor retained at startup, even after its
  -- logical pathname is unlinked or renamed away. The resulting application
  -- keeps the fixture's exact retained prefix and executes normally.
  run_build_race(project, cache, fixture_dir, runtime_prefix, prefix_length,
    work, diagnostics, "unlink")
  run_build_race(project, cache, fixture_dir, runtime_prefix, prefix_length,
    work, diagnostics, "rename")

  -- A nonselected raw core corruption lets this host start, but the private
  -- prefix reader validates every core before output publication.
  local host_target = host_target_field(fixture_dir, work, diagnostics)
  local corrupt = fixture_dir .. "/runtime.corrupt-" .. host_target
  local corrupt_project = work .. "/corrupt-project"
  Fixture.mkdir(corrupt_project .. "/cmd/hello")
  Fixture.copy(fixture_dir .. "/hello_main.tl",
    corrupt_project .. "/cmd/hello/main.tl")
  local corrupt_outcome = Fixture.call_with_environment("corrupt-build",
    { corrupt, "build" }, corrupt_project, diagnostics,
    Fixture.environment({ COSMIC_PORTABLE_CACHE = work .. "/corrupt-cache" }))
  assert(not corrupt_outcome.result.ok,
    "corrupt-core build unexpectedly succeeded")
  Fixture.contains(corrupt_outcome.err, "retained portable core range ")
  Fixture.contains(corrupt_outcome.err, " digest differs from manifest")
  assert(Fs.exists(corrupt_project .. "/o/bin/hello") == false,
    "corrupt-core build produced an application")

  local hello_run = Fixture.run("hello", { project .. "/o/bin/hello" }, project,
    diagnostics, { COSMIC_PORTABLE_CACHE = cache })
  local second_run = Fixture.run("second", { project .. "/o/bin/second" }, project,
    diagnostics, { COSMIC_PORTABLE_CACHE = cache })
  Fixture.contains(hello_run.out, "hello from the edited portable fixture")
  Fixture.contains(second_run.out, "second portable application")
  local cache_files = count_cache_files(cache)
  assert(cache_files == 1,
    "portable cache must contain exactly one file, found " ..
    tostring(cache_files))
  Fixture.write(project .. "/portable-hello.sha256",
    Fixture.hash(project .. "/o/bin/hello") .. "\n")
  Fixture.write(project .. "/portable-second.sha256",
    Fixture.hash(project .. "/o/bin/second") .. "\n")

  expect_tally(run_release(project, cache, counter, diagnostics,
    fixture_dir .. "/runtime.old", "release"), 1, 0)
  expect_tally(run_release(project, cache, counter, diagnostics,
    fixture_dir .. "/runtime.old", "unchanged"), 0, 1)

  -- These artifact bytes have a different application DB and prefix
  -- padding, but exactly the same selected raw core and runtime basis.
  expect_tally(run_release(project, cache, counter, diagnostics,
    fixture_dir .. "/runtime.new", "application"), 0, 1)

  -- A project database is searched ahead of the binary after attachment. Its
  -- rows must not override validated portable context or the binary's
  -- basis.
  -- Both tool.tl calls below run from `root`, matching identity test's
  -- own unwrapped invocations (no `cd "$project"`, unlike most of this
  -- function): tool.tl's require("build.artifact")/require("test.portable.
  -- artifact_fixture") resolve relative to the process cwd, and `project`
  -- has no build/ or test/ tree for them to find.
  Fixture.run("spoof-database", { fixture_dir .. "/runtime.old",
    root .. "/test/portable/tool.tl", "spoof-database",
    project .. "/o/cosmic.db" }, root, diagnostics,
    { COSMIC_PORTABLE_CACHE = cache })

  expect_tally(run_release(project, cache, counter, diagnostics,
    fixture_dir .. "/runtime.basis", "basis"), 1, 0)
  expect_tally(run_sanitized(fixture_dir, root, project, counter, work,
    diagnostics), 1, 0)

  Fixture.run("verify-verdicts", { fixture_dir .. "/runtime.old",
    root .. "/test/portable/tool.tl", "verify-verdicts",
    project .. "/o/build.db", counter }, root, diagnostics,
    { COSMIC_PORTABLE_CACHE = cache })

  local missing = work .. "/missing-project"
  Fixture.mkdir(missing)
  Fixture.copy(fixture_dir .. "/runtime_test.tl", missing .. "/runtime_test.tl")
  local missing_counter = missing .. "/counter"
  local missing_outcome = Fixture.call_with_environment("missing",
    { fixture_dir .. "/runtime.missing", "test" }, missing, diagnostics,
    Fixture.environment({ COSMIC_PORTABLE_CACHE = work .. "/missing-cache",
      COSMIC_FIXTURE_COUNTER = missing_counter }))
  assert(missing_outcome.result.code == 1,
    "missing-runtime test exit status was " ..
    tostring(missing_outcome.result.code) .. ", want 1")
  Fixture.contains(missing_outcome.err,
    "the running binary names no runtime identity")
  assert(Fs.exists(missing_counter) == false,
    "missing-runtime test wrote a counter file")

  -- Snapshot the finished project for test_identity_transported. TMPDIR is
  -- one process-wide value every test function in this run shares (it is
  -- set once, by orchestration.tl's fixture_test, for the whole `cosmic
  -- test` invocation), so a fixed name under it is the one thing this
  -- function and test_identity_transported -- each called with its own,
  -- otherwise unrelated, `Fs.mkdtemp` directory -- can agree on.
  local state_root = Env.get_or("TMPDIR", "/tmp") .. "/" ..
    transported_state_name
  Fixture.mkdir(state_root)
  copy_tree("snapshot-transported-state", project .. "/.", state_root .. "/",
    work, diagnostics)
end

-- Restoring into a new project location invalidates the old verdict: the first
-- run reruns and the immediate repeat stands. The assertions also ensure that
-- relocation preserves the application database and exact executable bytes.
local function test_identity_transported(tmp: string)
  local fixture_dir = Fixture.required("COSMIC_FIXTURE_RUNTIME")
  local state_root = Env.get_or("TMPDIR", "/tmp") .. "/" ..
    transported_state_name
  local state_exists = Predicate.is_dir(state_root)
  assert(state_exists,
    "identity transported state is missing; test_identity_primary must " ..
    "run first in this same process")

  local work = tmp
  local diagnostics = work .. "/logs"
  Fixture.mkdir(diagnostics)
  -- The destination must not exist so this creates a fresh relocated project.
  local project = work .. "/project"
  copy_tree("restore-transported-state", state_root, project, work,
    diagnostics)
  local counter = project .. "/test-runs"
  local cache = work .. "/cache"

  local projection_before = Fixture.hash(project .. "/o/cosmic.db")
  expect_tally(run_release(project, cache, counter, diagnostics,
    fixture_dir .. "/runtime.old", "transported"), 1, 0)
  expect_tally(run_release(project, cache, counter, diagnostics,
    fixture_dir .. "/runtime.old", "transported-repeat"), 0, 1)
  assert(Fixture.hash(project .. "/o/cosmic.db") == projection_before,
    "transported: a same-context re-run changed the application database")

  -- These are the canonical application bytes transported with the work
  -- database. Every host executes them unchanged through its own core.
  local expected_hello = assert(Fixture.small(
    project .. "/portable-hello.sha256", 256):match("^(%S+)"))
  local expected_second = assert(Fixture.small(
    project .. "/portable-second.sha256", 256):match("^(%S+)"))
  assert(Fixture.hash(project .. "/o/bin/hello") == expected_hello,
    "transported hello bytes differ from the recorded hash")
  assert(Fixture.hash(project .. "/o/bin/second") == expected_second,
    "transported second bytes differ from the recorded hash")

  -- GitHub artifact transport normalizes executable modes; restore only the
  -- launch permission after proving the transported bytes are unchanged.
  -- A local copy preserves modes, but real artifact transport may not.
  chmod(project .. "/o/bin/hello", 0x1ed)
  chmod(project .. "/o/bin/second", 0x1ed)

  local hello_run = Fixture.run("transported-hello",
    { project .. "/o/bin/hello" }, project, diagnostics,
    { COSMIC_PORTABLE_CACHE = cache })
  local second_run = Fixture.run("transported-second",
    { project .. "/o/bin/second" }, project, diagnostics,
    { COSMIC_PORTABLE_CACHE = cache })
  Fixture.contains(hello_run.out, "hello from the edited portable fixture")
  Fixture.contains(second_run.out, "second portable application")
end
