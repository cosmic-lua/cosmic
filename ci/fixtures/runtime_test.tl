local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Fixture = require("cosmic_ci.fixture")

-- runtime test's own default subprocess bound, and the bound each paused
-- race and blocking handshake call below stays under.
local child_wait_timeout_ms <const> = 30000
local handshake_timeout_ms <const> = 5000

local function chmod(path: string, mode: integer)
  assert(sys.chmod(path, mode))
end

local function small_line(path: string): string
  return (assert(Fixture.small(path, 256):match("^(%S+)"), path .. " is empty"))
end

-- Opens fd 8 on $1 and fd 9 on $2, then execs the remaining arguments.
-- `Child.Options` only redirects stdin/stdout/stderr, so opening arbitrary
-- extra descriptors before exec needs a real shell wrapper -- the same
-- approach identity_test.tl's `run_sanitized` and launcher_test.tl's
-- descriptor tests use.
local descriptor_exec_script <const> = [[
exec 8< "$1"
exec 9< "$2"
shift 2
exec "$@"
]]

local function run_with_descriptors(label: string, artifact_fd_source: string,
    core_fd_source: string, argv: {string}, cwd: string, diagnostics: string,
    values: {string:string}): Fixture.Outcome
  local full_argv: {string} = { "/bin/sh", "-c", descriptor_exec_script, "sh",
    artifact_fd_source, core_fd_source }
  for _, one in ipairs(argv) do full_argv[#full_argv + 1] = one end
  return Fixture.call_with_environment(label, full_argv, cwd, diagnostics,
    values)
end

--------------------------------------------------------------------------
-- FIFO pause/release and process supervision.
--------------------------------------------------------------------------

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
    error("runtime child wait failed: " .. trouble)
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
    "runtime startup hook readiness differs")
end

local function release(work: string, diagnostics: string, label: string,
    path: string)
  local input = work .. "/release-" .. label
  Fixture.write(input, "go\n")
  Fixture.run("release-" .. label, { "/usr/bin/env", "tee", path }, work,
    diagnostics, nil, handshake_timeout_ms, input)
end

-- `hook == "after_validation"`
-- pauses through the native `COSMIC_PORTABLE_STARTUP_TEST_READY`/`_GO` hook
-- (test/portable/startup_hook.c), which fires at one fixed point in real
-- startup regardless of a hook name, and runs `tool.tl retained-prefix-probe`
-- from `root`. Every other hook name (e.g. "after_select") instead goes
-- through the named `COSMIC_PORTABLE_TEST_HOOK`/`_READY`/`_GO` mechanism
-- (the same one launcher_test.tl's `hook_environment` drives), running
-- the copied `probe.tl` fixture script from `work/run space`.
local function run_paused(root: string, work: string, diagnostics: string,
    hook: string, program: string, cache: string, expected_hash: string,
    expected_marker: string): Running, string
  local ready = fifo(work, diagnostics, "ready")
  local go = fifo(work, diagnostics, "go")
  local child: Running
  if hook == "after_validation" then
    local values = Fixture.environment({
      COSMIC_PORTABLE_CACHE = cache,
      COSMIC_PORTABLE_STARTUP_TEST_READY = ready,
      COSMIC_PORTABLE_STARTUP_TEST_GO = go,
    })
    child = start("paused", { program, root .. "/test/portable/tool.tl",
      "retained-prefix-probe", expected_hash, expected_marker }, root,
      values, diagnostics)
  else
    local values = Fixture.environment({
      COSMIC_PORTABLE_CACHE = cache,
      COSMIC_PORTABLE_TEST_HOOK = hook,
      COSMIC_PORTABLE_TEST_READY = ready,
      COSMIC_PORTABLE_TEST_GO = go,
    })
    child = start("paused", { program, "probe.tl", expected_hash,
      expected_marker }, work .. "/run space", values, diagnostics)
  end
  await_ready(work, diagnostics, "paused", ready)
  return child, go
end

local function release_paused(work: string, diagnostics: string, go: string)
  release(work, diagnostics, "paused", go)
end

--------------------------------------------------------------------------
-- Manifest-header parsing, shared by the private-contract and
-- corrupt-range checks.
--------------------------------------------------------------------------

local function host_uname(work: string, diagnostics: string, flag: string,
    label: string): string
  local answer = Fixture.run("uname-" .. label,
    { "/usr/bin/env", "uname", flag }, work, diagnostics)
  return (assert(Fixture.small(answer.out, 256):match("^(%S+)"),
    "uname " .. flag .. " produced no output"))
end

local function host_identifier(work: string, diagnostics: string): string
  local sysname = host_uname(work, diagnostics, "-s", "sysname")
  local arch = host_uname(work, diagnostics, "-m", "arch")
  -- A launcher arm is the quoted `uname -sm` answer it selects.
  return "'" .. sysname .. " " .. arch .. "'"
end

-- The manifest header is a run of human-readable lines within the first
-- 16384 bytes, each beginning "  HOST" for the target it selects. This
-- mirrors launcher_test.tl's own already-proven header scan (same
-- `"  " .. host` prefix check).
local function selected_header_line(artifact_bytes: string, host: string):
    string
  local header = artifact_bytes:sub(1, 16384)
  local line: string | nil = nil
  for candidate in header:gmatch("[^\n]+") do
    if candidate:sub(1, #host + 2) == "  " .. host then
      assert(line == nil, "duplicate selected manifest header line")
      line = candidate
    end
  end
  return (assert(line, "no manifest header line selected for host: " .. host))
end

-- Each of the four integer fields is `NAME=DIGITS;` and
-- the digest is `NAME=HEX ` (space-terminated, not semicolon-terminated).
local function parse_selected_header(artifact_bytes: string, host: string):
    string, string, integer, integer, string
  local line = selected_header_line(artifact_bytes, host)
  local target_id = assert(line:match("cosmic_target_id=(%d+);"),
    "manifest header line is missing cosmic_target_id")
  local configuration_id = assert(
    line:match("cosmic_configuration_id=(%d+);"),
    "manifest header line is missing cosmic_configuration_id")
  -- `assert(f(x), "message")` returns BOTH values when it succeeds; passing
  -- that call directly as tonumber's sole argument leaks "message" in as
  -- tonumber's base argument. Capture the matched text first instead.
  local offset_text = assert(line:match("cosmic_offset=(%d+);"),
    "manifest header line is missing cosmic_offset")
  local offset = math.tointeger(assert(tonumber(offset_text)))
  local length_text = assert(line:match("cosmic_length=(%d+);"),
    "manifest header line is missing cosmic_length")
  local length = math.tointeger(assert(tonumber(length_text)))
  local digest = assert(line:match("cosmic_sha256=([0-9a-f]+) "),
    "manifest header line is missing cosmic_sha256")
  return target_id, configuration_id, assert(offset), assert(length), digest
end

local function target_name_for_id(targets_path: string,
    target_id: string): string
  local wanted = assert(math.tointeger(tonumber(target_id)))
  for _, target in ipairs(Fixture.targets(targets_path)) do
    if target.id == wanted then return target.name end
  end
  error("no target record for id " .. target_id)
end

--------------------------------------------------------------------------
-- 1. Startup phase probe.
--------------------------------------------------------------------------

-- The selectable fixture TU owns every diagnostic phase, including the one
-- after the retained artifact has closed; production cores carry none of
-- it. `cmp` in the shell is an exact whole-file comparison, so this checks
-- the full captured stderr for exact equality rather than a substring.
local function test_runtime_startup_phases(tmp: string)
  local fixture_dir = Fixture.required("COSMIC_FIXTURE_RUNTIME")
  local work = tmp
  local diagnostics = work .. "/logs"
  Fixture.mkdir(diagnostics)
  chmod(fixture_dir .. "/runtime.old", 0x1ed)

  local phases = Fixture.run("phases", { fixture_dir .. "/runtime.old",
    "help" }, work, diagnostics,
    { COSMIC_PORTABLE_CACHE = work .. "/cache-phases" })
  local expected = table.concat({
    "cosmic portable test phase: artifact adopted",
    "cosmic portable test phase: startup released",
    "cosmic portable test phase: database opened",
    "cosmic portable test phase: store installed",
    "cosmic portable test phase: main entering",
    "cosmic portable test phase: main returned",
    "cosmic portable test phase: lua closed",
    "cosmic portable test phase: database closed",
    "cosmic portable test phase: artifact closed",
  }, "\n") .. "\n"
  assert(Fixture.read(phases.err) == expected,
    "startup phase sequence differs from the expected 9-line sequence")
end

--------------------------------------------------------------------------
-- 2. Logical-path/descriptor-reuse checks.
--------------------------------------------------------------------------

local function test_runtime_logical_paths(tmp: string)
  local fixture_dir = Fixture.required("COSMIC_FIXTURE_RUNTIME")
  local work = tmp
  local diagnostics = work .. "/logs"
  Fixture.mkdir(diagnostics)
  local release_hash =
    small_line(fixture_dir .. "/runtime.release.prefix-sha256")

  Fixture.mkdir(work .. "/bin")
  Fixture.mkdir(work .. "/run space")
  Fixture.copy(fixture_dir .. "/runtime.release", work .. "/bin/cosmic-runtime",
    0x1ed)
  Fixture.copy(fixture_dir .. "/probe.tl", work .. "/run space/probe.tl")
  local cache = work .. "/cache-release"

  local help_absolute = Fixture.run("help-absolute",
    { work .. "/bin/cosmic-runtime", "help" }, work, diagnostics,
    { COSMIC_PORTABLE_CACHE = cache })
  Fixture.contains(help_absolute.out, "cosmic -- a runtime")

  -- Occupied 8 and 9 no longer conflict with the portable contract: the
  -- shell chooses another pair and the real runtime adopts the exported
  -- numbers.
  local occupied = run_with_descriptors("help-occupied-descriptors",
    fixture_dir .. "/runtime.release", fixture_dir .. "/runtime.release",
    { work .. "/bin/cosmic-runtime", "help" }, work, diagnostics,
    Fixture.environment({ COSMIC_PORTABLE_CACHE = cache }))
  assert(occupied.result.ok, "help with occupied descriptors 8/9 failed")

  local docs = Fixture.run("docs", { work .. "/bin/cosmic-runtime", "docs",
    "Fs.read" }, work, diagnostics, { COSMIC_PORTABLE_CACHE = cache })
  Fixture.contains(docs.out, "Fs.read")

  Fixture.run("help-cwd-relative", { "./cosmic-runtime", "help" },
    work .. "/bin", diagnostics, { COSMIC_PORTABLE_CACHE = cache })

  -- `Child.start`/`Child.run` never do a PATH search of their own ("argv[1]
  -- is used exactly as given: there is no PATH search" -- cosmic.child), so
  -- PATH-based execution uses `/usr/bin/env`, with the runtime's directory
  -- prepended to PATH.
  Fixture.run("help-path", { "/usr/bin/env", "cosmic-runtime", "help" }, work,
    diagnostics, { COSMIC_PORTABLE_CACHE = cache,
      PATH = work .. "/bin:" .. Env.get_or("PATH", "") })

  Fixture.run("symlink-alias", { "/usr/bin/env", "ln", "-s",
    work .. "/bin/cosmic-runtime", work .. "/cosmic-alias" }, work,
    diagnostics)
  Fixture.run("help-symlink", { work .. "/cosmic-alias", "help" }, work,
    diagnostics, { COSMIC_PORTABLE_CACHE = cache })

  local script_run = Fixture.run("probe-script",
    { work .. "/bin/cosmic-runtime", "probe.tl", release_hash, "old" },
    work .. "/run space", diagnostics, { COSMIC_PORTABLE_CACHE = cache })
  assert(Fixture.small(script_run.out, 256) ==
    "script " .. release_hash .. " old\n",
    "probe script output did not match exactly")
end

--------------------------------------------------------------------------
-- 3. Environment-scrubbing check.
--------------------------------------------------------------------------

-- Startup removes the whole reserved prefix without a count or length cap,
-- keeps the public cache setting, and leaves ordinary variables alone.
-- tool.tl's `environment_clean` reads the cache value as its own first
-- positional argument and checks it against `COSMIC_PORTABLE_CACHE` in the
-- real environment -- both are set to the same string here, matching the
-- shell's own double plumbing (`COSMIC_PORTABLE_CACHE=$cache ... "$cache"
-- $names`).
local function test_runtime_environment_scrubbing(tmp: string)
  local fixture_dir = Fixture.required("COSMIC_FIXTURE_RUNTIME")
  local root = Fixture.required("COSMIC_FIXTURE_ROOT")
  local work = tmp
  local diagnostics = work .. "/logs"
  Fixture.mkdir(diagnostics)
  chmod(fixture_dir .. "/runtime.old", 0x1ed)

  local cache = work .. "/cache-environment"
  local names = { "COSMIC_PORTABLE_ADJACENT_A", "COSMIC_PORTABLE_ADJACENT_B" }
  local values: {string:string} = {
    COSMIC_PORTABLE_ADJACENT_A = "a",
    COSMIC_PORTABLE_ADJACENT_B = "b",
  }
  for i = 0, 39 do
    local name = string.format("COSMIC_PORTABLE_MANY_%02d", i)
    names[#names + 1] = name
    values[name] = "many"
  end
  local long_name = "COSMIC_PORTABLE_" .. string.format("%080d", 0)
  names[#names + 1] = long_name
  values[long_name] = "long"
  values.COSMIC_PORTABLE_CACHE = cache

  local argv: {string} = { fixture_dir .. "/runtime.old",
    root .. "/test/portable/tool.tl", "environment-clean", cache }
  for _, name in ipairs(names) do argv[#argv + 1] = name end

  -- tool.tl's own require("build.artifact")/require("test.portable.
  -- artifact_fixture") resolve relative to the process cwd, so this (like
  -- every other tool.tl invocation here) must run from `root`, not `work`.
  local outcome = Fixture.run("environment-clean", argv, root, diagnostics,
    values)
  Fixture.contains(outcome.out, "portable environment: clean")
end

--------------------------------------------------------------------------
-- 4. Private-field/descriptor-contract rejection checks.
--------------------------------------------------------------------------

local function expect_contract_error(fixture_dir: string, work: string,
    diagnostics: string, wrong_core: string, target_id: string,
    configuration_id: string, offset: integer, length: integer,
    digest: string, name: string, artifact_fd: string, core_fd: string,
    pattern: string)
  local values = Fixture.environment({
    COSMIC_PORTABLE_ARTIFACT_FD = artifact_fd,
    COSMIC_PORTABLE_CORE_FD = core_fd,
    COSMIC_PORTABLE_TARGET_ID = target_id,
    COSMIC_PORTABLE_CONFIGURATION_ID = configuration_id,
    COSMIC_PORTABLE_CORE_OFFSET = tostring(offset),
    COSMIC_PORTABLE_CORE_LENGTH = tostring(length),
    COSMIC_PORTABLE_CORE_SHA256 = digest,
  })
  local outcome = run_with_descriptors("contract-" .. name,
    fixture_dir .. "/runtime.release", wrong_core,
    { wrong_core, "--artifact", fixture_dir .. "/runtime.release", "help" },
    work, diagnostics, values)
  assert(not outcome.result.ok,
    name .. ": contract violation unexpectedly succeeded")
  Fixture.contains(outcome.err, pattern)
end

local function test_runtime_private_contract(tmp: string)
  local fixture_dir = Fixture.required("COSMIC_FIXTURE_RUNTIME")
  local work = tmp
  local diagnostics = work .. "/logs"
  Fixture.mkdir(diagnostics)

  local host = host_identifier(work, diagnostics)
  local release_bytes = Fixture.read(fixture_dir .. "/runtime.release")
  local target_id, configuration_id, offset, length, digest =
    parse_selected_header(release_bytes, host)
  local target = target_name_for_id(fixture_dir .. "/hooked-build/targets.tsv",
    target_id)
  local wrong_core = fixture_dir .. "/hooked-build/core/" .. target ..
    "/cosmic-core"
  chmod(wrong_core, 0x1ed)

  -- Any private field marks a strict portable launch, even without
  -- --artifact; it cannot propagate through or enter the raw-core --boot
  -- bridge.
  local partial = Fixture.call_with_environment("partial-artifact",
    { wrong_core, "--boot", "x", "y" }, work, diagnostics,
    Fixture.environment({ COSMIC_PORTABLE_TARGET_ID = target_id }))
  assert(not partial.result.ok, "partial-artifact boot unexpectedly succeeded")
  Fixture.contains(partial.err, "portable startup names no artifact")

  -- Startup accepts representable nonstandard descriptors, while standard,
  -- equal, and unrepresentable fields are rejected before descriptor
  -- adoption.
  expect_contract_error(fixture_dir, work, diagnostics, wrong_core, target_id,
    configuration_id, offset, length, digest, "standard", "2", "9",
    "portable artifact descriptor field is invalid")
  expect_contract_error(fixture_dir, work, diagnostics, wrong_core, target_id,
    configuration_id, offset, length, digest, "equal", "8", "8",
    "portable descriptor fields are equal")
  expect_contract_error(fixture_dir, work, diagnostics, wrong_core, target_id,
    configuration_id, offset, length, digest, "unrepresentable",
    "2147483648", "9", "portable artifact descriptor field is invalid")

  -- A different build of the same target/configuration is the executing
  -- inode and FD9, but differs from the manifest's exact core bytes and is
  -- rejected. The shell checks this with `grep -Eq
  -- 'executing core (length|digest) differs from manifest'`; Fixture.contains
  -- is a plain substring match, so this uses a direct Lua pattern instead to
  -- keep the same length-or-digest alternation.
  local wrong_core_run = run_with_descriptors("wrong-core",
    fixture_dir .. "/runtime.release", wrong_core,
    { wrong_core, "--artifact", fixture_dir .. "/runtime.release", "help" },
    work, diagnostics, Fixture.environment({
      COSMIC_PORTABLE_ARTIFACT_FD = "8", COSMIC_PORTABLE_CORE_FD = "9",
      COSMIC_PORTABLE_TARGET_ID = target_id,
      COSMIC_PORTABLE_CONFIGURATION_ID = configuration_id,
      COSMIC_PORTABLE_CORE_OFFSET = tostring(offset),
      COSMIC_PORTABLE_CORE_LENGTH = tostring(length),
      COSMIC_PORTABLE_CORE_SHA256 = digest,
    }))
  assert(not wrong_core_run.result.ok,
    "wrong-core: contract violation unexpectedly succeeded")
  assert(Fixture.read(wrong_core_run.err):find(
    "executing core %a+ differs from manifest") ~= nil,
    "wrong-core: expected error message not found")
end

--------------------------------------------------------------------------
-- 5. Corrupt-range checks.
--------------------------------------------------------------------------

local function test_runtime_corrupt_ranges(tmp: string)
  local fixture_dir = Fixture.required("COSMIC_FIXTURE_RUNTIME")
  local root = Fixture.required("COSMIC_FIXTURE_ROOT")
  local work = tmp
  local diagnostics = work .. "/logs"
  Fixture.mkdir(diagnostics)
  chmod(fixture_dir .. "/runtime.release", 0x1ed)

  local host = host_identifier(work, diagnostics)
  local release_bytes = Fixture.read(fixture_dir .. "/runtime.release")
  local release_hash =
    small_line(fixture_dir .. "/runtime.release.prefix-sha256")
  local _target_id, _configuration_id, offset =
    parse_selected_header(release_bytes, host)

  local cache = work .. "/cache-release"
  Fixture.run("corrupt-ranges", { fixture_dir .. "/runtime.release",
    root .. "/test/portable/tool.tl", "corrupt-ranges",
    fixture_dir .. "/runtime.release", work, tostring(offset) }, root,
    diagnostics, { COSMIC_PORTABLE_CACHE = cache })

  local selected_corrupt: string | nil = nil
  local nonselected_count = 0
  local index = 0
  for line in Fixture.read(work .. "/corrupt-ranges"):gmatch("[^\n]+") do
    index = index + 1
    local path, kind = line:match("^(.*) (%a+)$")
    assert(path and kind, "invalid corrupt-ranges listing line: " .. line)

    -- A warm cached core remains independently usable when any artifact
    -- core range is corrupt: `help` never touches the manifest core body,
    -- only the (uncorrupted) selected header.
    Fixture.run("corrupt-help-" .. tostring(index), { path, "help" }, work,
      diagnostics, { COSMIC_PORTABLE_CACHE = cache })

    local probe = Fixture.call_with_environment("corrupt-probe-" ..
      tostring(index),
      { path, root .. "/test/portable/tool.tl", "retained-prefix-probe",
        release_hash, "corrupt" }, root, diagnostics,
      Fixture.environment({ COSMIC_PORTABLE_CACHE = cache }))
    assert(not probe.result.ok,
      "retained-prefix-probe against a corrupt range unexpectedly succeeded")
    assert(Fixture.read(probe.err):find(
      "retained portable core range .* digest differs from manifest") ~= nil,
      "corrupt-range probe: expected error message not found")

    if kind == "selected" then
      assert(selected_corrupt == nil, "multiple selected corrupt-range entries")
      selected_corrupt = path
    elseif kind == "nonselected" then
      nonselected_count = nonselected_count + 1
    else
      error("unexpected corrupt-ranges kind: " .. kind)
    end
  end
  assert(selected_corrupt ~= nil, "no selected corrupt-range entry found")
  assert(nonselected_count >= 1,
    "expected at least one nonselected corrupt-range entry")

  -- A cold launch still rejects corruption in the selected range while
  -- extracting it.
  local cold = Fixture.call_with_environment("selected-corrupt-cold",
    { assert(selected_corrupt), "help" }, work, diagnostics,
    Fixture.environment({
      COSMIC_PORTABLE_CACHE = work .. "/cache-selected-corrupt" }))
  assert(not cold.result.ok, "cold corrupted-core help unexpectedly succeeded")
  Fixture.contains(cold.err, "extracted core digest differs")
end

-- The launcher does not hash a warm core; startup does, once. A cached core
-- damaged in place keeps its length, so it runs, and startup refuses it by
-- naming the entry; removing that entry lets the next launch extract it
-- again. The damage is the core's last byte: on Linux it lies outside every
-- loaded segment, so the core still starts; on macOS it is the code
-- signature, and the kernel refuses the core before startup can speak.
local function test_runtime_warm_core_damaged_in_place(tmp: string)
  local fixture_dir = Fixture.required("COSMIC_FIXTURE_RUNTIME")
  local work = tmp
  local diagnostics = work .. "/logs"
  Fixture.mkdir(diagnostics)
  chmod(fixture_dir .. "/runtime.release", 0x1ed)
  local cache = work .. "/cache-damaged"
  local values = { COSMIC_PORTABLE_CACHE = cache }
  local program = fixture_dir .. "/runtime.release"
  Fixture.run("damaged-cold", { program, "help" }, work, diagnostics, values)

  local core: string | nil = nil
  for _, name in ipairs((assert(Fs.list(cache)))) do
    if name:sub(1, 5) == "core-" then core = cache .. "/" .. name end
  end
  local path = assert(core, "cold launch published no core")
  local bytes = Fixture.read(path)
  local last = string.char(bytes:byte(#bytes) ~ 0xff)
  Fixture.write(path, bytes:sub(1, #bytes - 1) .. last, 0x140)

  local damaged = Fixture.call_with_environment("damaged-warm",
    { program, "help" }, work, diagnostics, Fixture.environment(values))
  assert(not damaged.result.ok, "a damaged cached core ran")
  if host_uname(work, diagnostics, "-s", "damaged-sysname") == "Linux" then
    Fixture.contains(damaged.err,
      "executing core digest differs from manifest; remove ")
    Fixture.contains(damaged.err, path:match("[^/]+$") .. " to extract it again")
  end

  assert(Fs.remove(path))
  Fixture.run("damaged-removed", { program, "help" }, work, diagnostics, values)
  assert(Fixture.read(path) == bytes, "re-extracted core differs")
end

--------------------------------------------------------------------------
-- 6. Atomic replace/unlink/mismatch races.
--------------------------------------------------------------------------

-- Once the artifact descriptor is open, atomic replacement cannot mix the
-- new pathname's database or prefix into the paused process. A subsequent
-- launch selects all-new bytes.
local function test_runtime_replace_while_paused(tmp: string)
  local fixture_dir = Fixture.required("COSMIC_FIXTURE_RUNTIME")
  local root = Fixture.required("COSMIC_FIXTURE_ROOT")
  local work = tmp
  local diagnostics = work .. "/logs"
  Fixture.mkdir(diagnostics)

  local old_hash = small_line(fixture_dir .. "/runtime.old.prefix-sha256")
  local new_hash = small_line(fixture_dir .. "/runtime.new.prefix-sha256")
  assert(old_hash ~= new_hash, "old and new prefix hashes must differ")

  local cache = work .. "/cache-replace"
  Fixture.mkdir(work .. "/replace space")
  local program = work .. "/replace space/cosmic"
  Fixture.copy(fixture_dir .. "/runtime.old", program, 0x1ed)

  supervised(function(active: {Running})
    local child, go = run_paused(root, work, diagnostics, "after_validation",
      program, cache, old_hash, "old")
    active[#active + 1] = child

    local replacement = work .. "/replacement"
    Fixture.copy(fixture_dir .. "/runtime.new", replacement, 0x1ed)
    assert(Fs.rename(replacement, program))

    release_paused(work, diagnostics, go)
    local result = finish(child)
    assert(result.ok,
      "replace-while-paused: paused process did not exit successfully")
    assert(Fixture.small(child.out, 256) == "old " .. old_hash .. "\n",
      "replace-while-paused: paused probe output differs")

    local fresh = Fixture.call_with_environment("post-replace",
      { program, root .. "/test/portable/tool.tl", "retained-prefix-probe",
        new_hash, "new" }, root, diagnostics,
      Fixture.environment({ COSMIC_PORTABLE_CACHE = cache }))
    assert(fresh.result.ok, "post-replace probe failed")
    assert(Fixture.small(fresh.out, 256) == "new " .. new_hash .. "\n",
      "post-replace probe output differs")
  end)
end

-- Unlink after adoption also leaves database and private prefix reads on the
-- retained descriptor.
local function test_runtime_unlink_while_paused(tmp: string)
  local fixture_dir = Fixture.required("COSMIC_FIXTURE_RUNTIME")
  local root = Fixture.required("COSMIC_FIXTURE_ROOT")
  local work = tmp
  local diagnostics = work .. "/logs"
  Fixture.mkdir(diagnostics)

  local old_hash = small_line(fixture_dir .. "/runtime.old.prefix-sha256")
  local cache = work .. "/cache-unlink"
  local program = work .. "/unlinked"
  Fixture.copy(fixture_dir .. "/runtime.old", program, 0x1ed)

  supervised(function(active: {Running})
    local child, go = run_paused(root, work, diagnostics, "after_validation",
      program, cache, old_hash, "old")
    active[#active + 1] = child

    assert(Fs.remove(program))

    release_paused(work, diagnostics, go)
    local result = finish(child)
    assert(result.ok,
      "unlink-while-paused: paused process did not exit successfully")
    assert(Fixture.small(child.out, 256) == "old " .. old_hash .. "\n",
      "unlink-while-paused: paused probe output differs")
  end)
end

-- Replacement after shell selection but before open cannot pair old
-- launcher claims with an incompatible complete artifact and never reaches
-- boot mode. This is the one race that uses the "after_select" hook rather
-- than "after_validation" (an earlier point in startup), so it runs the
-- copied `probe.tl` fixture script from `work/run space` via the bare
-- `COSMIC_PORTABLE_TEST_HOOK` mechanism instead of `tool.tl
-- retained-prefix-probe` from `root`.
local function test_runtime_mismatch_after_select(tmp: string)
  local fixture_dir = Fixture.required("COSMIC_FIXTURE_RUNTIME")
  local root = Fixture.required("COSMIC_FIXTURE_ROOT")
  local work = tmp
  local diagnostics = work .. "/logs"
  Fixture.mkdir(diagnostics)
  Fixture.mkdir(work .. "/run space")
  Fixture.copy(fixture_dir .. "/probe.tl", work .. "/run space/probe.tl")

  local old_hash = small_line(fixture_dir .. "/runtime.old.prefix-sha256")
  local cache = work .. "/cache-mismatch"
  local program = work .. "/mismatch"
  Fixture.copy(fixture_dir .. "/runtime.old", program, 0x1ed)

  supervised(function(active: {Running})
    local child, go = run_paused(root, work, diagnostics, "after_select",
      program, cache, old_hash, "old")
    active[#active + 1] = child

    local replacement = work .. "/mismatch.new"
    Fixture.copy(fixture_dir .. "/runtime.incompatible", replacement, 0x1ed)
    assert(Fs.rename(replacement, program))

    release_paused(work, diagnostics, go)
    local result = finish(child)
    assert(not result.ok,
      "mismatch-after-select: paused process unexpectedly succeeded")
    local err = Fixture.read(child.err)
    assert(err:find("extracted core digest differs", 1, true) ~= nil,
      "mismatch-after-select: expected failure message not found")
    -- A hard bug (startup falling all the way back to treating this as no
    -- tree to boot at all) rather than the expected rejection; surfaced
    -- loudly, matching the shell's own `if grep ...; then exit 1; fi`.
    assert(err:find("no tree to boot", 1, true) == nil,
      "mismatch-after-select: startup fell back to \"no tree to boot\" " ..
      "instead of rejecting the mismatched replacement")
  end)
end

--------------------------------------------------------------------------
-- 7. Timing observations.
--------------------------------------------------------------------------

-- Record real runtime.release entry cost independently of the tiny launcher
-- payload timings. These observations are informational and set no
-- threshold.
local function test_runtime_timing(tmp: string)
  local fixture_dir = Fixture.required("COSMIC_FIXTURE_RUNTIME")
  local root = Fixture.required("COSMIC_FIXTURE_ROOT")
  local work = tmp
  local diagnostics = work .. "/logs"
  Fixture.mkdir(diagnostics)
  chmod(fixture_dir .. "/runtime.release", 0x1ed)

  local runtime_bytes = #Fixture.read(fixture_dir .. "/runtime.release")
  local driver_cache = work .. "/runtime-timing-driver-cache"
  local timing_cache = work .. "/runtime-timing-cache"

  local cold = Fixture.run("timing-cold", { fixture_dir .. "/runtime.release",
    root .. "/test/portable/tool.tl", "time-runtime",
    fixture_dir .. "/runtime.release", timing_cache }, root, diagnostics,
    { COSMIC_PORTABLE_CACHE = driver_cache })
  local warm = Fixture.run("timing-warm", { fixture_dir .. "/runtime.release",
    root .. "/test/portable/tool.tl", "time-runtime",
    fixture_dir .. "/runtime.release", timing_cache }, root, diagnostics,
    { COSMIC_PORTABLE_CACHE = driver_cache })

  assert(Fs.put(Fs.stderr, "portable runtime.release entry cold timing (" ..
    tostring(runtime_bytes) .. " bytes): " ..
    Fixture.small(cold.out, 256):gsub("\n", " ") .. "\n"))
  assert(Fs.put(Fs.stderr, "portable runtime.release entry warm timing (" ..
    tostring(runtime_bytes) .. " bytes): " ..
    Fixture.small(warm.out, 256):gsub("\n", " ") .. "\n"))
end
