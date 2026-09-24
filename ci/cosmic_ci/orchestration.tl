local ContextEnv = require("cosmic_ci.context")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Predicate = require("cosmic_ci.fs_predicate")
local Hash = require("cosmic.hash")
local LauncherSetup = require("cosmic_ci.launcher_setup")
local ProductSetup = require("cosmic_ci.product_setup")
local Proc = require("cosmic.proc")
local Runner = require("cosmic_ci.runner")
local RuntimeSetup = require("cosmic_ci.runtime_setup")
local State = require("cosmic_ci.state")
local Time = require("cosmic.time")

local record Orchestration
end

local function mkdir(path: string) assert(Fs.mkdirs(path)) end

local exists = Predicate.exists
local is_dir = Predicate.is_dir
local function read(path: string): string return (assert(Fs.read(path))) end
local function hash(path: string): string return Hash.hex_sha256(read(path)) end
local function write(path: string, data: string) assert(Fs.write(path, data)) end
local function environment(extra?: {string:string}): {string:string}
  local all = Env.all()
  if extra then for k, v in pairs(extra) do all[k] = v end end
  return all
end

local record Context
  db: string
  worker: string
  run: string
  attempt: string
  root: string
  driver: string
end

local function operation(c: Context, phase: string, command: {string},
    timeout: integer, cwd?: string, env?: {string:string}, output?: string,
    error_output?: string): integer
  local runner: Runner.Context = { database = c.db, worker = c.worker,
    run = c.run, attempt = c.attempt, candidate = c.root }
  local child_environment: {string:string}
  if env then child_environment = env else child_environment = environment() end
  -- bin/zig shares one project cache among checkouts unless told otherwise
  -- (build/zig.tl); a candidate keeps its own under o/, which the build
  -- phase seeds and cache-save copies back.
  if not child_environment.COSMIC_ZIG_CACHE then
    child_environment.COSMIC_ZIG_CACHE = c.root .. "/o/zig-cache"
  end
  -- The driver boots the candidate itself; a tool that finds its core
  -- stale is a fault to report, not one to boot past (build/reboot.tl).
  if not child_environment.COSMIC_AUTO_BOOT then
    child_environment.COSMIC_AUTO_BOOT = "0"
  end
  return Runner.operation(runner, phase, { argv = command, cwd = cwd or c.root,
    env = child_environment, timeout_ms = timeout,
    output = output, error = error_output }).code
end

local function checked(c: Context, phase: string, command: {string},
    timeout?: integer, cwd?: string, env?: {string:string}): integer
  return operation(c, phase, command, timeout or 0, cwd, env)
end

local function logged(c: Context, phase: string, command: {string}, out: string,
    err: string, timeout: integer, cwd?: string, env?: {string:string}): integer
  local status = operation(c, phase, command, timeout, cwd, env, out, err)
  local replay_ok = Env.get("COSMIC_CI_SELFTEST_REPLAY_FAILURE") ~= "true"
  if replay_ok then
    replay_ok = Fs.put(Fs.stdout, read(out)) and Fs.put(Fs.stderr, read(err))
  end
  if not replay_ok then Fs.put(Fs.stderr, "could not replay retained output\n") end
  if status ~= 0 then return status end
  assert(replay_ok, "could not replay retained output")
  return status
end

local function capture_small(c: Context, phase: string, command: {string},
    path: string, timeout: integer, cwd?: string): integer
  return operation(c, phase, command, timeout, cwd, environment(), path)
end

-- Whole-project guards include compilation and test-runner overhead. The
-- direct children inside them have the shorter bounds defined by fixture.tl.
local product_test_timeout_ms <const> = 60000
local format_test_timeout_ms <const> = 300000
local launcher_test_timeout_ms <const> = 180000
local self_rebuild_test_timeout_ms <const> = 180000
local runtime_test_timeout_ms <const> = 180000
local identity_test_timeout_ms <const> = 120000

-- A whole `cosmic test` run takes 12-16 s on a runner and its slowest test
-- about a second. Each test gets far less than the whole run, so a test that
-- hangs is ended and named by the runner, not hidden under a cancelled run;
-- the run's own bound leaves room for a runner several times slower.
local suite_timeout_ms <const> = 120000
local suite_test_timeout_s <const> = "10"

-- The fuzz properties again on the checked core, over many more inputs
-- than a suite run's 64 (build/fuzz/init.tl). FUZZ_ITERS is part of each
-- fuzz test's key, so a whole run re-runs exactly those, and the tests
-- that start processes, which never stand; every other verdict the
-- checked suite just reached stands.
local deep_fuzz_iters <const> = "2000"
local deep_fuzz_timeout_ms <const> = 900000
local deep_fuzz_test_timeout_s <const> = "300"

local function parent(path: string): string
  return (assert(path:match("^(.*)/[^/]+$"), path .. ": no parent directory"))
end

local function copy_flat_tl_dir(source: string, destination: string)
  local names: {string} = {}
  for _, name in ipairs((assert(Fs.list(source)))) do
    assert(name:match("%.tl$") and
      assert(Fs.stat(source .. "/" .. name)).kind == "file",
      "invalid fixture source entry: " .. name)
    names[#names + 1] = name
  end
  mkdir(destination)
  for _, name in ipairs(names) do
    write(destination .. "/" .. name, read(source .. "/" .. name))
  end
end

local function fixture_project(c: Context, work: string): string
  local project = work .. "/fixture-project"
  local driver_namespace = parent(c.driver)
  local fixtures_source = parent(driver_namespace) .. "/fixtures"
  local removed = Runner.execute({ argv = { "/bin/rm", "-rf", project },
    cwd = work })
  assert(removed.code == 0, "could not clear fixture project")
  copy_flat_tl_dir(driver_namespace, project .. "/cosmic_ci")
  copy_flat_tl_dir(fixtures_source, project .. "/fixtures")
  return project
end

local function fixture_test(c: Context, work: string, name: string,
    source: string, timeout_ms: integer, extra: {string:string}): integer
  assert(name:match("^[%w-]+$"), "invalid fixture test name")
  assert(source:match("^[%w_]+$"), "invalid fixture test source")
  local project = fixture_project(c, work)
  local diagnostics = work .. "/fixture-test-diagnostics/" .. name
  mkdir(diagnostics); mkdir(diagnostics .. "/tmp")
  local fixture_environment = environment(extra)
  fixture_environment.TMPDIR = diagnostics .. "/tmp"
  local out, err = diagnostics .. "/test.out", diagnostics .. "/test.err"
  local status = logged(c, "fixture: " .. name,
    { assert(Proc.executable()), "test",
      "fixtures/" .. source .. "_test.tl" }, out, err, timeout_ms, project,
    fixture_environment)
  if status ~= 0 then return status end
  return 0
end

local function checked_suite(c: Context, target: string, work: string): integer
  local sanitized = c.root .. "/o/sanitized"
  local targets_path = sanitized .. "/targets.tsv"
  local target_id: string | nil = nil
  local checked_target: string | nil = nil
  local target_records = read(targets_path)
  for line in target_records:gmatch("[^\n]+") do
    local id, configuration, name, _target_name =
      line:match("^(%d+)\t(%d+)\t([^\t]+)\t([^\t]+)")
    if configuration == "2" and name == "sanitized" then
      assert(not target_id, "multiple sanitized target records"); target_id = id
    end
  end
  for line in target_records:gmatch("[^\n]+") do
    local id, configuration, name, target_name =
      line:match("^(%d+)\t(%d+)\t([^\t]+)\t([^\t]+)")
    if id == target_id and configuration == "1" and name == "release" then
      assert(not checked_target, "multiple checked target records")
      checked_target = target_name
    end
  end
  assert(target_id and checked_target == target, "checked target mapping differs")
  local cosmic = sanitized .. "/bin/cosmic"
  local core = sanitized .. "/cosmic-core"
  local entry = work .. "/checked-entry.txt"
  -- TODO: this bound also covers the sanitized cosmic's first, cold
  -- compile of the tree tool.tl sits in, 41 s on a 4-core host under
  -- ci/run-local against under a second warm. Give the compile a bound of
  -- its own (a warm-up run beside this one), or raise this one, so a
  -- slower host times out only on the entry itself.
  local s = capture_small(c, "checked manifest entry", { cosmic,
    c.root .. "/test/portable/tool.tl", "entry", cosmic, target_id, "2" },
    entry, 30000)
  if s ~= 0 then return s end
  local offset_text, length_text, digest =
    read(entry):match("^(%d+)[ \t]+(%d+)[ \t]+([0-9a-f]+)\n$")
  local offset = math.tointeger(assert(tonumber(offset_text)))
  local length = math.tointeger(assert(tonumber(length_text)))
  assert(offset and length and digest and offset % 16384 == 0,
    "checked manifest entry is malformed or unaligned: " .. read(entry))
  local artifact = read(cosmic); local raw = read(core)
  assert(length == #raw and #digest == 64, "checked core length/digest invalid")
  local extracted = artifact:sub(offset + 1, offset + length)
  assert(#extracted == length and Hash.hex_sha256(extracted) == digest and
    extracted == raw, "checked core range differs")
  write(work .. "/checked.core", extracted)
  s = checked(c, "checked runtime context", { cosmic,
    c.root .. "/test/portable/tool.tl", "checked-context", core, target }, 30000)
  if s ~= 0 then return s end
  local diagnostics = work .. "/checked-diagnostics"; mkdir(diagnostics)
  -- c.root/o is not cleared: the sanitized binary's runtime identity
  -- differs from the release one's, so no release verdict can stand.
  s = logged(c, "checked suite", { cosmic, "test" },
    diagnostics .. "/checked-test.out", diagnostics .. "/checked-test.err",
    90000, c.root, environment())
  write(diagnostics .. "/checked-test.status", tostring(s) .. "\n")
  if s ~= 0 then return s end
  s = logged(c, "checked deep fuzz", { cosmic, "test" },
    diagnostics .. "/checked-fuzz.out", diagnostics .. "/checked-fuzz.err",
    deep_fuzz_timeout_ms, c.root, environment({ FUZZ_ITERS = deep_fuzz_iters,
      COSMIC_TEST_TIMEOUT = deep_fuzz_test_timeout_s }))
  write(diagnostics .. "/checked-fuzz.status", tostring(s) .. "\n")
  if s ~= 0 then return s end
  return 0
end

local function snapshot(c: Context, diagnostics: string, label: string,
    cosmic: string): integer
  assert(label:match("^[%w-]+$"), "invalid snapshot label")
  local candidate = assert(Fs.absolute(c.root))
  local destination = assert(Fs.absolute(diagnostics))
  assert(destination ~= candidate and
    destination:sub(1, #candidate + 1) ~= candidate .. "/",
    "snapshot path must be outside candidate checkout")
  local out = destination .. "/" .. label
  assert(not exists(out), "snapshot already exists: " .. out); mkdir(out)
  write(out .. "/build.db", read(c.root .. "/o/build.db"))
  if exists(c.root .. "/o/build.db-journal") then
    write(out .. "/build.db-journal", read(c.root .. "/o/build.db-journal"))
  end
  local hashes = hash(out .. "/build.db") .. "  build.db\n"
  if exists(out .. "/build.db-journal") then
    hashes = hashes .. hash(out .. "/build.db-journal") .. "  build.db-journal\n"
  end
  write(out .. "/hashes.sha256", hashes)
  local temporary_root = Env.get_or("TMPDIR", "/tmp")
  State.external_path(temporary_root .. "/probe", c.root)
  local inspect = assert(Fs.mkdtemp("cosmic-work-db-integrity-"))
  local called, answer = pcall(function(): integer
    write(inspect .. "/build.db", read(out .. "/build.db"))
    if exists(out .. "/build.db-journal") then
      write(inspect .. "/build.db-journal", read(out .. "/build.db-journal"))
    end
    write(inspect .. "/work_db_integrity.tl",
      read(c.root .. "/ci/testdata/portable/work_db_integrity.tl"))
    return logged(c, label .. " integrity",
      { cosmic, "work_db_integrity.tl", "--recover-copy", "build.db" },
      out .. "/integrity.out", out .. "/integrity.err", 30000, inspect)
  end)
  local removed = Runner.execute({ argv = { "/bin/rm", "-rf", inspect },
    cwd = c.root })
  assert(removed.code == 0 and not exists(inspect),
    "could not remove disposable integrity directory")
  if not called then error(answer) end
  return answer
end

local function suite(c: Context, name: string, executable: string,
    diagnostics: string, env?: {string:string}): integer
  mkdir(diagnostics)
  local out = diagnostics .. "/" .. name .. "-test.out"
  local err = diagnostics .. "/" .. name .. "-test.err"
  local values = environment(env)
  values.COSMIC_TEST_TIMEOUT = suite_test_timeout_s
  local status = logged(c, name .. " suite", { executable, "test" }, out, err,
    suite_timeout_ms, c.root, values)
  write(diagnostics .. "/" .. name .. "-test.status", tostring(status) .. "\n")
  local snap_called, snap_answer = pcall(snapshot, c, diagnostics,
    name .. "-immediate", executable)
  local snapshot_status = snap_called and snap_answer or 1
  if not snap_called then Fs.put(Fs.stderr, tostring(snap_answer) .. "\n") end
  if status == 124 then Fs.put(Fs.stderr, name .. " suite: timed out (status 124)\n")
  elseif status ~= 0 then Fs.put(Fs.stderr,
name .. " suite: failed (status " .. status .. ")\n") end
  if status ~= 0 then return status end
  if snapshot_status ~= 0 then return snapshot_status end
  return 0
end

local function archive(c: Context, destination: string): integer
  assert(not exists(destination), "archive destination already exists: " .. destination)
  mkdir(destination)
  local tar = destination .. ".tar"
  local status = checked(c, "tracked source archive",
    { "/usr/bin/env", "git", "-C", c.root, "archive", "--output", tar, "HEAD" })
  if status ~= 0 then return status end
  status = checked(c, "tracked source extract",
    { "/usr/bin/env", "tar", "-xf", tar, "-C", destination })
  assert(not exists(destination .. "/o"), "tracked source archive holds o/")
  return status
end

local targets: {string:boolean} = {
 ["x86_64-linux-musl"] = true, ["aarch64-linux-musl"] = true, ["aarch64-macos"] = true }

local record PlatformContext
  trailing: string | nil
  operation: Context
  root: string
  target: string
  work: string
  product: string
  contract: string
  runtime: string
  local_diagnostics: string
  portable_diagnostics: string
  fresh: string
end

local function phase_build(p: PlatformContext): integer
  local c = p.operation
  local root = p.root
  local local_d = p.local_diagnostics
  assert(not exists(root .. "/o"), "build requires fresh checkout without o")
  -- Only the project cache is seeded into o/: zig's global cache is used
  -- where it was restored (COSMIC_ZIG_GLOBAL_CACHE, build/zig.tl). It
  -- comes from the zig-cache under COSMIC_ZIG_CACHE_SEED, as CI restored
  -- it, or from the project cache COSMIC_ZIG_CACHE_FROM names, as a local
  -- run finds a developer's shared one.
  local seed = Env.get("COSMIC_ZIG_CACHE_SEED")
  local from = Env.get("COSMIC_ZIG_CACHE_FROM")
  if not from and seed then from = seed .. "/zig-cache" end
  if from and is_dir(from) then
    mkdir(root .. "/o")
    local copied = checked(c, "restore zig-cache",
      { "/usr/bin/env", "cp", "-a", from, root .. "/o/zig-cache" })
    if copied ~= 0 then return copied end
  end
  local s = checked(c, "core build and boot", { root .. "/bin/zig", "build", "cores", "boot" }, 0)
  if s ~= 0 then return s end
  return suite(c, "local", root .. "/o/bin/cosmic", local_d)
end

local function phase_local_boundary(p: PlatformContext): integer
  local c = p.operation
  local root = p.root
  local local_d = p.local_diagnostics
  local s = snapshot(c, local_d, "local-boundary", root .. "/o/bin/cosmic"); if s ~= 0 then return s end
  assert(read(local_d .. "/local-immediate/hashes.sha256") == read(local_d .. "/local-boundary/hashes.sha256"), "local database changed across boundary"); return 0
end

local function phase_assemble(p: PlatformContext): integer
  local c = p.operation
  local root = p.root
  local target = p.target
  local work = p.work
  local product = p.product
  local contract = p.contract
  local runtime = p.runtime
  local local_d = p.local_diagnostics
  local portable_d = p.portable_diagnostics
  local fresh = p.fresh
  assert(exists(local_d .. "/local-boundary/hashes.sha256"),
    "no local-boundary snapshot; run the local-boundary phase first")
  local s = checked(c, "format check",
    { root .. "/o/bin/cosmic", "fix", "--check", "." })
  if s ~= 0 then return s end
  s = checked(c, "codesign verification",
    { root .. "/bin/verify-codesign",
      root .. "/o/core/aarch64-macos/cosmic-core" })
  if s ~= 0 then return s end
  assert(ProductSetup.build(root, product, work .. "/product-setup") == product,
    "product setup returned the wrong product")
  write(work .. "/cosmic.before.sha256", hash(product .. "/cosmic") .. "\n")
  s = fixture_test(c, work, "format-contract", "format",
    format_test_timeout_ms, {
    COSMIC_FIXTURE_ROOT = root,
    COSMIC_FIXTURE_FORMAT = contract .. "/format",
    COSMIC_FIXTURE_TARGET = target,
  })
  if s ~= 0 then return s end
  assert(LauncherSetup.build(root, contract .. "/launcher", target,
    work .. "/launcher-setup") == contract .. "/launcher",
    "launcher setup returned the wrong output")
  local after_product: {{string}} = {
    { root .. "/bin/zig", "build", "sanitized" },
  }
  local after_labels = { "checked build" }
  for i, cmd in ipairs(after_product) do
    s = checked(c, after_labels[i], cmd); if s ~= 0 then return s end
  end
  s = checked_suite(c, target, work)
  if s ~= 0 then return s end
  s = checked(c, "hook-core build", { root .. "/bin/zig", "build", "portable-hook-cores", "--prefix", work .. "/prebuilt" }); if s ~= 0 then return s end
  mkdir(work .. "/prebuilt/portable-fixture/sanitized")
  write(work .. "/prebuilt/portable-fixture/sanitized/cosmic-core", read(root .. "/o/sanitized/cosmic-core"))
  assert(RuntimeSetup.build(root, work .. "/prebuilt", product .. "/cosmic",
    product .. "/cosmic.db", runtime, work .. "/runtime-setup") == runtime,
    "runtime setup returned the wrong output")
  s = fixture_test(c, work, "product-verification", "product",
    product_test_timeout_ms, {
    COSMIC_FIXTURE_PRODUCT = product,
    COSMIC_FIXTURE_TARGET = target,
    COSMIC_FIXTURE_DECODER = contract .. "/format/format-test-" .. target,
    COSMIC_FIXTURE_CODESIGN = target == "aarch64-macos" and "true" or "false",
  }); if s ~= 0 then return s end
  s = checked(c, "selected format mutation", { contract .. "/format/format-test-" .. target, contract .. "/format/program" }); if s ~= 0 then return s end
  s = archive(c, fresh); if s ~= 0 then return s end
  mkdir(portable_d); write(portable_d .. "/cosmic-portable", read(product .. "/cosmic"));
  s = checked(c, "portable executable mode",
    { "/usr/bin/env", "chmod", "755", portable_d .. "/cosmic-portable" })
  if s ~= 0 then return s end
  write(portable_d .. "/portable-artifact.before.sha256", hash(portable_d .. "/cosmic-portable") .. "\n"); return 0
end

local function phase_portable(p: PlatformContext): integer
  local c = p.operation
  local portable_d = p.portable_diagnostics
  local fresh = p.fresh
  local executable = portable_d .. "/cosmic-portable"
  local portable_context: Context = { db = c.db, worker = c.worker, run = c.run,
    attempt = c.attempt, root = fresh, driver = c.driver }
  local s = suite(portable_context, "portable", executable, portable_d,
    { COSMIC_PORTABLE_CACHE = portable_d .. "/portable-full-suite-cache" })
  local hash_called, hash_error = pcall(function(): boolean
    write(portable_d .. "/portable-artifact.after.sha256", hash(executable) .. "\n")
    assert(read(portable_d .. "/portable-artifact.before.sha256") ==
      read(portable_d .. "/portable-artifact.after.sha256"),
      "portable artifact changed")
    return true
  end)
  if not hash_called then Fs.put(Fs.stderr, tostring(hash_error) .. "\n") end
  if s ~= 0 then return s end
  if not hash_called then return 1 end
  return s
end

local function phase_portable_boundary(p: PlatformContext): integer
  local c = p.operation
  local portable_d = p.portable_diagnostics
  local fresh = p.fresh
  local portable_context: Context = { db = c.db, worker = c.worker, run = c.run,
    attempt = c.attempt, root = fresh, driver = c.driver }
  local s = snapshot(portable_context, portable_d, "portable-boundary",
    portable_d .. "/cosmic-portable"); if s ~= 0 then return s end
  if p.trailing == "success" then
    assert(read(portable_d .. "/portable-immediate/hashes.sha256") == read(portable_d .. "/portable-boundary/hashes.sha256"), "portable database changed across boundary")
    local executable = portable_d .. "/cosmic-portable"
    local cache = portable_d .. "/portable-full-suite-cache"
    local locked = checked(portable_context, "portable cache read-only mode",
      { "/usr/bin/env", "chmod", "500", cache })
    if locked ~= 0 then return locked end
    local help = checked(portable_context, "read-only cache execution",
      { executable, "help" }, 30000, fresh, environment({ COSMIC_PORTABLE_CACHE = cache }))
    local restored = checked(portable_context, "portable cache restore mode",
      { "/usr/bin/env", "chmod", "700", cache })
    if help ~= 0 then return help end
    if restored ~= 0 then return restored end
  end
  return 0
end

local function phase_fixtures(p: PlatformContext): integer
  local c = p.operation
  local root = p.root
  local target = p.target
  local work = p.work
  local product = p.product
  local contract = p.contract
  local runtime = p.runtime
  local s = fixture_test(c, work, "self-rebuild-regression", "self_rebuild",
    self_rebuild_test_timeout_ms, {
    COSMIC_FIXTURE_ROOT = root,
    COSMIC_FIXTURE_RUNTIME = runtime,
  }); if s ~= 0 then return s end
  s = fixture_test(c, work, "runtime-regression", "runtime",
    runtime_test_timeout_ms, {
    COSMIC_FIXTURE_ROOT = root,
    COSMIC_FIXTURE_RUNTIME = runtime,
  }); if s ~= 0 then return s end
  s = fixture_test(c, work, "launcher-regression", "launcher",
    launcher_test_timeout_ms, {
    COSMIC_FIXTURE_LAUNCHER = contract .. "/launcher/launcher.test",
    COSMIC_FIXTURE_LAUNCHER_SOCKET = contract ..
      "/launcher/payloads/socket-" .. target,
    COSMIC_FIXTURE_TARGET = target,
  }); if s ~= 0 then return s end
  s = fixture_test(c, work, "identity-regression", "identity",
    identity_test_timeout_ms, {
    COSMIC_FIXTURE_ROOT = root,
    COSMIC_FIXTURE_RUNTIME = runtime,
  }); if s ~= 0 then return s end
  s = fixture_test(c, work, "product-regression", "product",
    product_test_timeout_ms, {
    COSMIC_FIXTURE_PRODUCT = product,
    COSMIC_FIXTURE_TARGET = target,
    COSMIC_FIXTURE_DECODER = contract .. "/format/format-test-" .. target,
    COSMIC_FIXTURE_CODESIGN = target == "aarch64-macos" and "true" or "false",
  }); if s ~= 0 then return s end
  assert(hash(product .. "/cosmic") .. "\n" == read(work .. "/cosmic.before.sha256"), "product mutated by fixtures"); return 0
end

local function phase_attest(p: PlatformContext): integer
  local work = p.work
  local product = p.product
  local portable_d = p.portable_diagnostics
  local before = read(work .. "/cosmic.before.sha256"); local digest = hash(product .. "/cosmic") .. "\n"
  assert(before == digest and before == read(portable_d .. "/portable-artifact.before.sha256") and before == read(portable_d .. "/portable-artifact.after.sha256"), "executed artifact attestation differs")
  write(product .. "/executed-cosmic.sha256", digest:sub(1, 64) .. "  cosmic\n"); write(product .. "/expected-platforms", assert(p.trailing) .. "\n"); return 0
end

local function phase_cache_save(p: PlatformContext): integer
  local c = p.operation
  local root = p.root
  -- Only the project cache is copied back: zig's global cache was used
  -- in place, under the seed, and is saved as it stands.
  local seed = assert(Env.get("COSMIC_ZIG_CACHE_SEED"), "cache seed is required")
  mkdir(seed)
  local removed = checked(c, "remove saved zig-cache",
    { "/bin/rm", "-rf", seed .. "/zig-cache" })
  if removed ~= 0 then return removed end
  if is_dir(root .. "/o/zig-cache") then
    local copied = checked(c, "save zig-cache",
      { "/usr/bin/env", "cp", "-a", root .. "/o/zig-cache", seed .. "/" })
    if copied ~= 0 then return copied end
  end
  return 0
end

local function platform_impl(phase: string, p: PlatformContext): integer
  assert(targets[p.target], "unsupported target"); mkdir(p.work)
  if phase == "build" then return phase_build(p)
  elseif phase == "local-boundary" then return phase_local_boundary(p)
  elseif phase == "assemble" then return phase_assemble(p)
  elseif phase == "portable" then return phase_portable(p)
  elseif phase == "portable-boundary" then return phase_portable_boundary(p)
  elseif phase == "fixtures" then return phase_fixtures(p)
  elseif phase == "attest" then return phase_attest(p)
  elseif phase == "cache-save" then return phase_cache_save(p)
  end
  error("unknown platform phase: " .. phase)
end

local function provenance_impl(c: Context, products: string): integer
  local entries = assert(Fs.list(products)); local count = 0; local expected: integer|nil = nil; local baseline: string|nil = nil
  for _, name in ipairs(entries) do if name:match("^portable%-product%-.+") then
      local p = products .. "/" .. name; local att = p .. "/executed-cosmic.sha256"; local exp = p .. "/expected-platforms"
      assert(exists(att) and exists(exp) and exists(p .. "/cosmic"), "incomplete product: " .. p)
      local line = read(att); local digest = line:match("^([0-9a-f]+)  cosmic\n$"); assert(digest and #digest == 64, "invalid attestation: " .. att)
      assert(hash(p .. "/cosmic") == digest, "changed artifact: " .. p)
      local n = math.tointeger(assert(tonumber(read(exp)))); assert(n and n > 0, "invalid expected count")
      if expected then assert(expected == n, "inconsistent expected count") else expected = n end
      if baseline then assert(baseline == digest, "worker artifact hashes differ") else baseline = digest end
      count = count + 1
    end end
  assert(expected and count == expected, "expected " .. tostring(expected) .. " products, found " .. count)
  return checked(c, "provenance comparison", { "/usr/bin/env", "true" })
end

local function logical(c: Context, phase: string,
    action: function(): integer): integer
  local started = assert(Time.monotonic_ns())
  local database = State.external_path(c.db, c.root)
  local id = State.start(database, c.worker, c.run, c.attempt, phase, started)
  local called, answer = pcall(action)
  local code = called and answer or 1
  local status = code == 0 and "success" or (called and "exit" or "error")
  local detail: string | nil = nil
  if not called then detail = tostring(answer) end
  local finished = assert(Time.monotonic_ns())
  State.complete(database, id, c.worker, c.run, c.attempt, phase, finished,
    finished - started, status, code, nil, 0, detail)
  if detail then Fs.put(Fs.stderr, detail .. "\n") end
  return code
end

function Orchestration.platform(a: {string}): integer
  local phase = assert(a[1], "usage: driver.tl platform PHASE [ARG]")
  local ctx = ContextEnv.read()
  local target = ContextEnv.target()
  local c: Context = { db = ctx.db, worker = ctx.worker, run = ctx.run,
    attempt = ctx.attempt, root = ctx.root, driver = assert(Fs.absolute(assert(a[0]))) }
  local p: PlatformContext = { trailing = a[2], operation = c, root = ctx.root,
    target = target, work = ctx.work, product = ctx.work .. "/product",
    contract = ctx.work .. "/contract", runtime = ctx.work .. "/runtime",
    local_diagnostics = ctx.work .. "/local-diagnostics",
    portable_diagnostics = ctx.work .. "/portable-diagnostics",
    fresh = ctx.work .. "/portable-source" }
  return logical(c, "platform: " .. phase, function(): integer
    return platform_impl(phase, p)
  end)
end

function Orchestration.provenance(a: {string}): integer
  local ctx = ContextEnv.read()
  local c: Context = { db = ctx.db, worker = ctx.worker, run = ctx.run,
    attempt = ctx.attempt, root = ctx.root, driver = assert(Fs.absolute(assert(a[0]))) }
  return logical(c, "provenance", function(): integer
    return provenance_impl(c, ctx.products)
  end)
end

return Orchestration
