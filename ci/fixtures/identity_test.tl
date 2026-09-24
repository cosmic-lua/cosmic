local Fs = require("cosmic.fs")
local Fixture = require("cosmic_ci.fixture")
local Process = require("cosmic_ci.process")

local type Running = Process.Running
local start, finish, supervised = Process.start, Process.finish, Process.supervised
local fifo, await_ready, release = Process.fifo, Process.await_ready, Process.release
local chmod, host_uname = Process.chmod, Process.host_uname

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
  return (assert(digits and math.tointeger(tonumber(digits)),
    "invalid prefix length: " .. text))
end

-- TODO: copy in this process once cosmic.fs carries a recursive copy.
local function copy_tree(label: string, from: string, to: string, cwd: string,
    diagnostics: string)
  Fixture.run(label, { "/usr/bin/env", "cp", "-R", from, to }, cwd, diagnostics)
end

-- Counts the plain files directly inside `directory`. The portable cache is
-- assumed flat, the same assumption launcher_test.tl's `only_core` and
-- `no_private_entries` make about a cache directory.
-- The cores a cache holds: its public entries. A name beginning with "."
-- is the launcher's or startup's own (a verified stamp, a repair lock).
local function count_cache_files(directory: string): integer
  local count = 0
  for _, name in ipairs((assert(Fs.list(directory)))) do
    if name:sub(1, 1) ~= "." and
        assert(Fs.stat(directory .. "/" .. name)).kind == "file" then
      count = count + 1
    end
  end
  return count
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
  return (assert(found, "no generated target matches this host: " ..
    sysname .. " " .. arch))
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
-- on descriptors 8/9.
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

  -- The artifact and core open on the descriptors the private contract names.
  return Fixture.succeeded("sanitized", Fixture.call_with_descriptors("sanitized",
    { core, "--artifact", artifact, "test" }, project, diagnostics,
    Fixture.environment({
    COSMIC_FIXTURE_COUNTER = counter,
    COSMIC_PORTABLE_ARTIFACT_FD = "8",
    COSMIC_PORTABLE_CORE_FD = "9",
    COSMIC_PORTABLE_TARGET_ID = target_id,
    COSMIC_PORTABLE_CONFIGURATION_ID = "2",
    COSMIC_PORTABLE_CORE_OFFSET = offset,
    COSMIC_PORTABLE_CORE_LENGTH = length,
    COSMIC_PORTABLE_CORE_SHA256 = digest,
  }), { [8] = artifact, [9] = core }))
end

-- Restoring into a new project location invalidates the old verdict: the first
-- run reruns and the immediate repeat stands. The assertions also ensure that
-- relocation preserves the application database and exact executable bytes.
-- It runs on the finished primary project, from inside the same test: each
-- test runs in a process of its own, so no other test can hand it one.
local function check_transported(fixture_dir: string, finished: string,
    work: string, diagnostics: string)
  -- The destination must not exist so this creates a fresh relocated project.
  local project = work .. "/transported-project"
  copy_tree("restore-transported-state", finished, project, work,
    diagnostics)
  local counter = project .. "/test-runs"
  local cache = work .. "/transported-cache"

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

-- Build the primary project, check every runtime context against it, then
-- check it again transported to a new location.
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

  -- Run just build/embed_test.tl under the real portable runtime. Its cases
  -- cover the portable database, the retained prefix, and host programs
  -- made from the running core; every one of them must run, none answered
  -- from a verdict, however many the file holds.
  local focused = work .. "/focused-embed"
  Fixture.mkdir(focused)
  copy_tree("copy-build", root .. "/build", focused .. "/build", work,
    diagnostics)
  local focused_run = Fixture.run("focused-embed", { fixture_dir .. "/runtime.old",
    "test", "build/embed_test.tl" }, focused, diagnostics,
    { COSMIC_PORTABLE_CACHE = cache })
  local cases = 0
  for _ in Fixture.read(focused .. "/build/embed_test.tl"):gmatch("\nlocal function test_") do
    cases = cases + 1
  end
  assert(cases > 0, "build/embed_test.tl holds no tests")
  Fixture.contains(focused_run.out, "test: PASS (" .. cases .. " tests, 1 modules; " ..
    cases .. " ran, 0 stood")

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

  check_transported(fixture_dir, project, work, diagnostics)
end
