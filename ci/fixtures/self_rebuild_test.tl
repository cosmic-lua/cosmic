local Clock = require("cosmic.clock")
local Sqlite = require("cosmic.sqlite")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Fixture = require("cosmic_ci.fixture")
local Process = require("cosmic_ci.process")

local Test = require("cosmic.test")

--- Run unsandboxed and sharing nothing (cosmic_ci/orchestration.tl's
--- `fixture`), its workers are given the environment they declare:
--- all of it, which says where the candidate and its products are
--- (COSMIC_FIXTURE_*) and where the host's toolchain is. A release that
--- keys every unsandboxed run by declaration gives a worker only that.
-- TODO: name the variables this fixture reads, and drop the wildcard
-- (then the wildcard in Test.needs and the policy path's refusal of it,
-- build/test_policy.tl): beside the COSMIC_FIXTURE_* it is handed, its
-- nested builds and runs inherit whatever the host's toolchain reads
-- (the fixture's environment functions copy the whole environment on),
-- which only a run on every leg, macOS's included, lists; a list read
-- off the Linux leg's alone would fail the others.
Test.needs{ env = { "*" } }

local type Running = Process.Running
local start, finish, supervised = Process.start, Process.finish, Process.supervised
local fifo, await_ready, release = Process.fifo, Process.await_ready, Process.release
-- A call that finds the tool stale rebuilds it from the tree first. Every
-- case but the docs verb's takes back the compiles the leg's boot made of
-- the tree ([`seeded_compiles`]), so it compiles only what it edited: what
-- they check is the rebuild's way through the lock, the artifact and the
-- re-entry, which a compile of every module only slows. The docs verb's
-- compiles the whole tree cold, as the product rebuilding itself on a
-- fresh checkout does: 55 to 60 s of one core for the tree's modules
-- (some 500 in October 2026), on a runner or under ci/run-local on a
-- four-core host, which this bound holds 1.5 times over. Five cold
-- compiles at once on four cores would take 86 to 90 s each, past it.
-- The driver bounds each test here at 120 s (orchestration.tl), which
-- this leaves room inside.
local rebuild_timeout_ns <const> = Clock.seconds(90)

--- A copy of the leg's compiles (COSMIC_FIXTURE_COMPILES, orchestration.tl's
--- `seed_compiles`) for one case's rebuild to take back
--- (COSMIC_BUILD_CACHE), so one case's rows never stand in another's,
--- and the rows it holds. Its directory is its own and 0700, since
--- build/shared_compiles.tl's `open` refuses a file in a directory
--- another user could write, as a umask of 002 leaves the case's.
local record Seed
  path: string
  rows: integer
end

--- How many compiles `path` holds, and how many of them a build took
--- or made at `since_ns` or later. The table's name carries its
--- format's version (build/cache_formats.tl), so each that matches is
--- counted.
local function compiles_in(path: string, since_ns: integer): integer, integer
  local db = assert(Sqlite.open(path))
  local total, used = 0, 0
  local ok, failure = pcall(function(): boolean
    local tables = assert(Sqlite.text_rows(db,
      "SELECT name FROM sqlite_schema WHERE type = 'table' AND name GLOB 'compiled_v*'"))
    for _, row in ipairs(tables) do
      local counts = assert(Sqlite.text_rows(db, "SELECT count(*), " ..
          "count(*) FILTER (WHERE used_ns >= ?1) FROM \"" .. row[1] .. "\"",
        { { integer = since_ns } }))
      total = total + math.tointeger(tonumber(counts[1][1]))
      used = used + math.tointeger(tonumber(counts[1][2]))
    end
    return true
  end)
  local _, _ = db:close()
  if not ok then error(failure) end
  return total, used
end

local function seeded_compiles(case_root: string): Seed
  local dir = case_root .. "/compiles"
  assert(sys.mkdir(dir, 0x1c0))
  local path = dir .. "/cache.db"
  Fixture.copy(Fixture.required("COSMIC_FIXTURE_COMPILES"), path, 0x180)
  local rows, _ = compiles_in(path, 0)
  assert(rows > 0, path .. ": the seed holds no compiles")
  return { path = path, rows = rows }
end

--- Fails `label` unless the rebuilds since `since_ns` took back more of
--- `seed`'s compiles than they compiled: a rebuild that could not open the
--- copy, or whose keys no longer match the boot's, compiles every module
--- and passes, slowly, until it meets the bound this file exists to keep
--- it under. A row a build evicts or drops as damaged counts as one it
--- took, which only loosens the check. `err` is what the rebuilding run
--- said.
local function took_compiles(label: string, seed: Seed, since_ns: integer, err: string)
  assert(not err:find("build: shared compiles:", 1, true),
    label .. ": the rebuild could not take back its compiles; it said:\n" .. err)
  local total, used = compiles_in(seed.path, since_ns)
  local made = total - seed.rows
  local taken = used - made
  assert(taken > made, label .. ": the rebuild took back " .. tostring(taken) ..
      " compiles and made " .. tostring(made))
end

-- Compares exactly the first `length` bytes of `program` against `expected`,
-- which must itself be exactly `length` bytes. A length mismatch on either
-- side, or a byte difference within the compared range, fails with a
-- message. A program longer than `length` still passes, since only its
-- prefix matters.
local function compare_prefix(expected: string, program: string,
                              length: integer): boolean, string
  if #expected ~= length then
    return false, "expected prefix has " .. tostring(#expected) ..
      " bytes, want " .. tostring(length)
  end
  if #program < length then
    return false, "rebuilt artifact prefix has " .. tostring(#program) ..
      " bytes, want " .. tostring(length)
  end
  if program:sub(1, length) ~= expected then
    return false, "rebuilt artifact prefix bytes differ"
  end
  return true, ""
end

-- Splits text into lines without dropping empty ones, as
-- `gmatch("[^\n]+")` does. Assumes the text ends with a trailing newline,
-- as every source file in the tree does: joining the result with "\n" and
-- appending one final "\n" reproduces it.
local function split_lines(text: string): {string}
  local lines: {string} = {}
  local at = 1
  while true do
    local newline = text:find("\n", at, true)
    if newline == nil then
      if at <= #text then lines[#lines + 1] = text:sub(at) end
      break
    end
    lines[#lines + 1] = text:sub(at, newline - 1)
    at = newline + 1
  end
  return lines
end

-- Splices `extra` immediately after the first line that equals `marker`.
-- Fails loudly if `marker` is not found, rather than silently leaving the
-- edit unapplied.
local function insert_after(lines: {string}, marker: string,
                            extra: {string}): {string}
  local out: {string} = {}
  local found = false
  for _, line in ipairs(lines) do
    out[#out + 1] = line
    if line == marker then
      found = true
      for _, one in ipairs(extra) do out[#out + 1] = one end
    end
  end
  assert(found, "marker line not found: " .. marker)
  return out
end

-- A fresh tree, the tree the product was booted from
-- (COSMIC_FIXTURE_SOURCE), the same fixture every rebuild/refusal case
-- starts from.
local function archive_tree(tree: string)
  Fixture.source_tree(tree)
end

-- Copies the fixture-only runtime into the archived tree's `o/bin/cosmic`,
-- executable, and returns its path.
local function place_runtime(fixture_dir: string, tree: string): string
  local program = tree .. "/o/bin/cosmic"
  Fixture.mkdir(tree .. "/o/bin")
  Fixture.copy(fixture_dir .. "/runtime.old", program, 0x1ed)
  return program
end

-- Make the fixture runtime stale and verify argv and environment on re-entry.
local function apply_step8_edit(tree: string)
  local path = tree .. "/build/test.tl"
  local lines = split_lines(Fixture.read(path))
  lines = insert_after(lines, "local Clock = require(\"cosmic.clock\")",
    { "local step8_sys = require(\"cosmic.sys\")" })
  lines = insert_after(lines,
    "local function run(argv: {integer:string}): integer", {
      "  assert(argv[1] == \"test\")",
      "  assert(argv[2] == \"build/embed_test.tl\")",
      "  assert(argv[3] == \"argument with spaces\")",
      "  assert(argv[4] == nil)",
      "  assert(step8_sys.getenv(\"COSMIC_STEP8_REENTRY\") == \"kept with spaces\")",
    })
  Fixture.write(path, table.concat(lines, "\n") .. "\n")
  -- The spaced argument is a selector too, and `cosmic test` fails on a
  -- selector that matches no test module, so it names one.
  Fixture.mkdir(tree .. "/argument with spaces")
  Fixture.write(tree .. "/argument with spaces/step8_test.tl",
    "local function test_selected()\n  assert(true)\nend\n")
end

-- Marks `build/docs.tl`'s verdict with an extra line, distinguishable from
-- the runtime's own stale embedded copy -- so a self-rebuilt `docs` verb's
-- output can be told apart from a docs table it merely read unchanged.
local function apply_docs_marker_edit(tree: string)
  local path = tree .. "/build/docs.tl"
  local lines = split_lines(Fixture.read(path))
  lines = insert_after(lines,
    "local function run(argv: {integer:string}): integer",
    { "  local _, _ = Fs.put(Fs.stdout, \"step8-docs-marker\\n\")" })
  Fixture.write(path, table.concat(lines, "\n") .. "\n")
end

-- Rejects the whole value if it is anything but digits: a loose `%d+` search
-- would instead silently accept and truncate a malformed value (e.g. extra
-- trailing text).
local function read_prefix_length(fixture_dir: string): integer
  local text = Fixture.read(fixture_dir .. "/runtime.old.prefix-length")
  local digits = text:match("^(%d+)\n*$")
  return (assert(digits and math.tointeger(tonumber(digits)),
    "invalid prefix length: " .. text))
end

local function cache_entries(cache: string): integer
  local count = 0
  for _, name in ipairs((assert(Fs.list(cache)))) do
    if name:match("^core%-") then count = count + 1 end
  end
  return count
end

local function count_occurrences(text: string, needle: string): integer
  local count = 0
  local at = 1
  while true do
    local from = text:find(needle, at, true)
    if from == nil then break end
    count = count + 1
    at = from + #needle
  end
  return count
end

-- The `rename`/`unlink` self-rebuild race: the fixture-only runtime pauses
-- right after adopting its own descriptors, the artifact is renamed away or
-- unlinked from under it, and the release makes it re-enter and rebuild
-- itself from the database at the same logical path. Then, in the same
-- case, a core input edit is checked to be refused without touching the
-- artifact.
local function run_rebuild_case(fixture_dir: string,
                                tmp: string, action: string)
  local case_root = tmp .. "/case-" .. action
  local tree = case_root .. "/tree"
  local cache = case_root .. "/cache"
  local diagnostics = case_root .. "/logs"
  Fixture.mkdir(diagnostics)
  archive_tree(tree)
  local program = place_runtime(fixture_dir, tree)
  local original_hash = Fixture.hash(program)
  local prefix_length = read_prefix_length(fixture_dir)
  apply_step8_edit(tree)

  local ready = fifo(case_root, diagnostics, "ready-" .. action)
  local go = fifo(case_root, diagnostics, "go-" .. action)

  local seed = seeded_compiles(case_root)
  local since = Clock.now_ns()
  supervised(function(active: {Running})
    local values = Fixture.environment({
      COSMIC_BUILD_CACHE = seed.path,
      COSMIC_PORTABLE_CACHE = cache,
      COSMIC_PORTABLE_STARTUP_TEST_READY = ready,
      COSMIC_PORTABLE_STARTUP_TEST_GO = go,
      COSMIC_STEP8_REENTRY = "kept with spaces",
    })
    local child = start("rebuild-" .. action,
      { program, "test", "build/embed_test.tl", "argument with spaces" }, tree, values,
      diagnostics)
    active[#active + 1] = child

    await_ready(case_root, diagnostics, "first-" .. action, ready, child)
    local entries_before = cache_entries(cache)
    assert(entries_before == 1,
      action .. ": expected exactly one cache entry before rebuild, found " ..
        tostring(entries_before))

    if action == "rename" then
      assert(Fs.rename(program, case_root .. "/adopted-artifact"))
    else
      assert(Fs.remove(program))
    end

    release(case_root, diagnostics, "first-" .. action, go)
    -- The rebuilt artifact starts once more at the same logical path.
    await_ready(case_root, diagnostics, "second-" .. action, ready,
      child, rebuild_timeout_ns)
    release(case_root, diagnostics, "second-" .. action, go)

    local result = finish(child)
    assert(result.ok, action .. ": self-rebuild child did not exit " ..
        "successfully")

    Fixture.assert_executable(program)
    assert(Fixture.read(child.out):match(
      "test: PASS %([^;]+; [1-9][0-9]* ran, 0 stood"),
      action .. ": self-rebuild output did not match the expected pattern")
    local err = Fixture.read(child.err)
    took_compiles(action, seed, since, err)
    local stale_lines = count_occurrences(err,
      "the tool is stale; rebuilding it from the tree")
    assert(stale_lines == 1, action .. ": self-rebuild reported " ..
        tostring(stale_lines) .. " stale-rebuild lines, want 1")
    assert(not err:find("the tool is still stale after a reboot", 1, true),
      action .. ": the tool is still stale after its own rebuild")

    local expected_prefix = Fixture.read(fixture_dir .. "/runtime.old.prefix")
    local matched, mismatch =
      compare_prefix(expected_prefix, Fixture.read(program), prefix_length)
    assert(matched, action .. ": " .. mismatch)

    local entries_after = cache_entries(cache)
    assert(entries_after == entries_before,
      action .. ": self-rebuild changed the cache entry count from " ..
        tostring(entries_before) .. " to " .. tostring(entries_after))
    assert(Fixture.hash(program) ~= original_hash,
      action .. ": self-rebuild did not change the artifact")

    -- A core input cannot be represented by a database-only rebuild; with
    -- COSMIC_AUTO_BOOT=0 the tool refuses rather than running zig.
    local startup_h = tree .. "/core/startup.h"
    Fixture.write(startup_h, Fixture.read(startup_h) ..
        "\n/* step-8 core-change fixture */\n")
    local before_refusal = Fixture.hash(program)
    local refusal_values = Fixture.environment({
      COSMIC_PORTABLE_CACHE = cache,
      COSMIC_STEP8_REENTRY = "kept with spaces",
      COSMIC_AUTO_BOOT = "0",
    })
    local refused = Fixture.call_with_environment("core-change-" .. action,
      { program, "test", "build/embed_test.tl", "argument with spaces" }, tree, diagnostics,
      refusal_values)
    assert(refused.result.code == 3,
      action .. ": core-change refusal exit status was " ..
        tostring(refused.result.code) .. ", want 3")
    Fixture.contains(refused.err, "the tool is stale; run bin/zig build boot")
    assert(Fixture.hash(program) == before_refusal,
      action .. ": core-change refusal touched the artifact")
    assert(cache_entries(cache) == entries_before,
      action .. ": core-change refusal changed the cache entry count")
    -- An option the tree may have added is not refused by a stale tool
    -- as a usage error: the staleness is found first.
    local optioned = Fixture.call_with_environment("core-change-option-" .. action,
      { program, "db", "--an-option-this-tool-lacks" }, tree, diagnostics,
      refusal_values)
    assert(optioned.result.code == 3,
      action .. ": a stale tool refused an unknown option with exit status " ..
        tostring(optioned.result.code) .. ", want 3")
    Fixture.contains(optioned.err, "the tool is stale; run bin/zig build boot")
    -- Running a file builds the tree as `test` does, and meets the same guard.
    local ran = Fixture.call_with_environment("core-change-file-" .. action,
      { program, "build/embed_test.tl" }, tree, diagnostics, refusal_values)
    assert(ran.result.code == 3,
      action .. ": a stale tool ran a file with exit status " ..
        tostring(ran.result.code) .. ", want 3")
    Fixture.contains(ran.err, "the tool is stale; run bin/zig build boot")
  end)
end

-- One of the three ways a stale tool (a pinned tl version, an unapplied
-- patch, or an edited launcher generator) is refused outright, when
-- COSMIC_AUTO_BOOT=0 says not to boot, without ever reaching `test.run` or
-- touching the artifact.
local function run_refusal_case(fixture_dir: string,
                                tmp: string, name: string)
  local case_root = tmp .. "/refuse-" .. name
  local tree = case_root .. "/tree"
  local cache = case_root .. "/cache"
  local diagnostics = case_root .. "/logs"
  Fixture.mkdir(diagnostics)
  archive_tree(tree)
  local program = place_runtime(fixture_dir, tree)
  local before = Fixture.hash(program)

  if name == "tl-pin" then
    local pin = tree .. "/vendor/tl/PIN"
    Fixture.write(pin, Fixture.read(pin) .. "\n# refusal fixture\n")
  elseif name == "tl-patch" then
    Fixture.mkdir(tree .. "/patch/tl")
    Fixture.write(tree .. "/patch/tl/refusal-fixture.patch",
      "refusal fixture\n")
  elseif name == "launcher" then
    local launcher = tree .. "/build/launcher.tl"
    Fixture.write(launcher, Fixture.read(launcher) ..
        "\n-- refusal fixture\n")
  else
    error("unknown refusal fixture: " .. name)
  end

  local values = Fixture.environment({ COSMIC_PORTABLE_CACHE = cache,
    COSMIC_AUTO_BOOT = "0" })
  local outcome = Fixture.call_with_environment(name .. "-refusal",
    { program, "test" }, tree, diagnostics, values)
  assert(outcome.result.code == 3, name .. ": refusal exit status was " ..
      tostring(outcome.result.code) .. ", want 3")
  Fixture.contains(outcome.err, "the tool is stale; run bin/zig build boot")
  assert(Fixture.hash(program) == before, name .. ": refusal touched the " ..
      "artifact")
end

-- A pure unit test of [`compare_prefix`] itself, with three synthetic cases: an
-- exact match, a program too short to hold the expected prefix, and a mutated
-- byte within the compared range.
local function test_self_rebuild_prefix_comparison(_tmp: string)
  local expected = "abc"
  local matched, mismatch = compare_prefix(expected, "abc-suffix", 3)
  assert(matched, mismatch)

  local short_ok = compare_prefix(expected, "ab", 3)
  assert(not short_ok, "short prefix comparison unexpectedly passed")

  local mutated_ok = compare_prefix(expected, "axc-suffix", 3)
  assert(not mutated_ok, "mutated prefix comparison unexpectedly passed")
end

-- Each way of losing the artifact is a test of its own, so each self-rebuild
-- has a test's whole time limit to itself rather than half of one.
local function test_self_rebuild_after_a_rename(tmp: string)
  run_rebuild_case(Fixture.required("COSMIC_FIXTURE_RUNTIME"), tmp, "rename")
end

local function test_self_rebuild_after_an_unlink(tmp: string)
  run_rebuild_case(Fixture.required("COSMIC_FIXTURE_RUNTIME"), tmp, "unlink")
end

local function test_self_rebuild_refusals(tmp: string)
  local fixture_dir = Fixture.required("COSMIC_FIXTURE_RUNTIME")
  for _, name in ipairs({ "tl-pin", "tl-patch", "launcher" }) do
    run_refusal_case(fixture_dir, tmp, name)
  end
end

-- `cosmic docs` never compiles the tree itself, unlike `test`, so it relies
-- entirely on `build.reboot.stale_exit` to notice a stale embedded copy of
-- `build.docs` and rebuild before running. That is the case AGENTS.md's
-- promise that a tool older than the tree rebuilds itself depends on for
-- a verb other than `test`. A first call against an edited tree rebuilds
-- once and shows the edit; a second, now-fresh call shows it again without
-- rebuilding again. It alone takes back no compiles, so the product
-- compiles every module of the tree itself.
local function test_self_rebuild_docs_verb(tmp: string)
  local fixture_dir = Fixture.required("COSMIC_FIXTURE_RUNTIME")
  local case_root = tmp .. "/case-docs"
  local tree = case_root .. "/tree"
  local cache = case_root .. "/cache"
  local diagnostics = case_root .. "/logs"
  Fixture.mkdir(diagnostics)
  archive_tree(tree)
  local program = place_runtime(fixture_dir, tree)
  local before_hash = Fixture.hash(program)
  apply_docs_marker_edit(tree)

  local values = Fixture.environment({ COSMIC_PORTABLE_CACHE = cache })
  local outcome = Fixture.call_with_environment("docs-rebuild",
    { program, "docs", "cosmic.child" }, tree, diagnostics, values,
    rebuild_timeout_ns)
  assert(outcome.result.code == 0, "docs: exit status was " ..
      tostring(outcome.result.code) .. ", want 0")
  Fixture.contains(outcome.out, "step8-docs-marker")
  local stale_lines = count_occurrences(Fixture.read(outcome.err),
    "the tool is stale; rebuilding it from the tree")
  assert(stale_lines == 1, "docs: reported " .. tostring(stale_lines) ..
      " stale-rebuild lines, want 1")
  assert(Fixture.hash(program) ~= before_hash,
    "docs: self-rebuild did not change the artifact")

  local second = Fixture.call_with_environment("docs-fresh",
    { program, "docs", "cosmic.child" }, tree, diagnostics, values)
  assert(second.result.code == 0, "docs: second exit status was " ..
      tostring(second.result.code) .. ", want 0")
  Fixture.contains(second.out, "step8-docs-marker")
  assert(not Fixture.read(second.err):find("the tool is stale", 1, true),
    "docs: second invocation reported staleness though the tool is fresh")
end

-- Runs of one stale tool started at once in one checkout -- an editor's,
-- a watcher's and a terminal's -- rebuild it one at a time: each either
-- rebuilds it or waits for the run that is and re-enters on the tool that
-- run wrote, and every one shows the edit. Unserialized, their rebuilds
-- would write o/cosmic.db, o/carried.db and the tool under one another,
-- and end in "disk I/O error" or "portable program database has no SQLite
-- header" and a spurious "(the tool is stale)" failure.
local function test_self_rebuild_by_concurrent_runs(tmp: string)
  local fixture_dir = Fixture.required("COSMIC_FIXTURE_RUNTIME")
  local case_root = tmp .. "/case-concurrent"
  local tree = case_root .. "/tree"
  local cache = case_root .. "/cache"
  local diagnostics = case_root .. "/logs"
  Fixture.mkdir(diagnostics)
  archive_tree(tree)
  local program = place_runtime(fixture_dir, tree)
  local before_hash = Fixture.hash(program)
  apply_docs_marker_edit(tree)

  local seed = seeded_compiles(case_root)
  local since = Clock.now_ns()
  local values = Fixture.environment({ COSMIC_PORTABLE_CACHE = cache,
    COSMIC_BUILD_CACHE = seed.path })
  local said: {string} = {}
  supervised(function(active: {Running})
    for n = 1, 3 do
      active[#active + 1] = start("concurrent-" .. tostring(n),
        { program, "docs", "cosmic.child" }, tree, values, diagnostics)
    end
    local rebuilt = 0
    for _, child in ipairs(active) do
      local result = finish(child, rebuild_timeout_ns)
      local err = Fixture.read(child.err)
      assert(result.ok, child.label .. ": exit status " ..
          tostring(result.code) .. ", want 0; it said:\n" .. err)
      said[#said + 1] = err
      Fixture.contains(child.out, "step8-docs-marker")
      -- Started together, before any rebuild could land, each run meets
      -- the tool stale: it rebuilds, waits for the run that does (or for
      -- one writing o/cosmic.db, which holds the same lock), or finds
      -- that run's rebuild already landed and enters it.
      assert(err:find("the tool is stale; rebuilding it from the tree", 1, true) or
          err:find("in this checkout is [^\n]*; waiting for it") or
          err:find("rebuilt the tool; entering it", 1, true),
        child.label .. ": neither rebuilt the tool, waited nor entered " ..
          "another's; it said:\n" .. err)
      rebuilt = rebuilt + count_occurrences(err,
        "the tool is stale; rebuilding it from the tree")
    end
    assert(rebuilt >= 1, "concurrent: no run rebuilt the tool")
  end)
  took_compiles("concurrent", seed, since, table.concat(said, "\n"))
  assert(Fixture.hash(program) ~= before_hash,
    "concurrent: no run changed the artifact")
end

-- A run a reboot entered (COSMIC_REBOOTED) that would refuse as still
-- stale refuses at once, though another run holds the rebuild lock: it
-- neither waits for that run nor, re-entering after it, rebuilds, so
-- runs that cannot settle the tool do not rebuild it by turns for good.
local function test_a_rebooted_run_refuses_without_waiting(tmp: string)
  local fixture_dir = Fixture.required("COSMIC_FIXTURE_RUNTIME")
  local case_root = tmp .. "/case-rebooted"
  local tree = case_root .. "/tree"
  local cache = case_root .. "/cache"
  local diagnostics = case_root .. "/logs"
  Fixture.mkdir(diagnostics)
  archive_tree(tree)
  local program = place_runtime(fixture_dir, tree)
  local before_hash = Fixture.hash(program)
  apply_docs_marker_edit(tree)

  -- The rebuild lock's SQLite half, which a tool from before the flock
  -- holds alone and every run still waits for (build.rebuild_lock).
  local lock = assert(Sqlite.open(tree .. "/o/rebuild.lock", { writable = true }))
  assert(lock:exec("BEGIN IMMEDIATE"))
  local held_ok, failure = pcall(function(): boolean
    for _, entered in ipairs({ "1", "2" }) do
      local values = Fixture.environment({ COSMIC_PORTABLE_CACHE = cache,
        COSMIC_REBOOTED = entered })
      local outcome = Fixture.call_with_environment("rebooted-" .. entered,
        { program, "docs", "cosmic.child" }, tree, diagnostics, values)
      assert(outcome.result.code == 3, "rebooted " .. entered ..
          ": exit status was " .. tostring(outcome.result.code) .. ", want 3")
      Fixture.contains(outcome.err, "the tool is still stale after a reboot")
      assert(not Fixture.read(outcome.err):find("waiting for it", 1, true),
        "rebooted " .. entered .. ": waited for the rebuild lock")
    end
    return true
  end)
  local _, _ = lock:close()
  if not held_ok then error(failure) end
  assert(Fixture.hash(program) == before_hash,
    "rebooted: a refusing run changed the artifact")
end

-- Marks `build/fix/init.tl`'s verb with an extra line, as the docs marker
-- does for `docs`: a `fix` the stale tool ran itself would not print it.
local function apply_fix_marker_edit(tree: string)
  local path = tree .. "/build/fix/init.tl"
  local lines = split_lines(Fixture.read(path))
  lines = insert_after(lines,
    "local function run(argv: {integer:string}): integer",
    { "  local _, _ = Fs.put(Fs.stdout, \"step8-fix-marker\\n\")" })
  Fixture.write(path, table.concat(lines, "\n") .. "\n")
end

-- `fix` in cosmic's own tree fixes with the tree's rules and layout, so a
-- tool older than the tree rebuilds itself before it fixes anything.
local function test_self_rebuild_fix_verb(tmp: string)
  local fixture_dir = Fixture.required("COSMIC_FIXTURE_RUNTIME")
  local case_root = tmp .. "/case-fix"
  local tree = case_root .. "/tree"
  local cache = case_root .. "/cache"
  local diagnostics = case_root .. "/logs"
  Fixture.mkdir(diagnostics)
  archive_tree(tree)
  local program = place_runtime(fixture_dir, tree)
  local before_hash = Fixture.hash(program)
  apply_fix_marker_edit(tree)

  local seed = seeded_compiles(case_root)
  local since = Clock.now_ns()
  local values = Fixture.environment({ COSMIC_PORTABLE_CACHE = cache,
    COSMIC_BUILD_CACHE = seed.path })
  local outcome = Fixture.call_with_environment("fix-rebuild",
    { program, "fix", "--check", "build/clock.tl" }, tree, diagnostics, values,
    rebuild_timeout_ns)
  assert(outcome.result.code == 0, "fix: exit status was " ..
      tostring(outcome.result.code) .. ", want 0")
  Fixture.contains(outcome.out, "step8-fix-marker")
  took_compiles("fix", seed, since, Fixture.read(outcome.err))
  local stale_lines = count_occurrences(Fixture.read(outcome.err),
    "the tool is stale; rebuilding it from the tree")
  assert(stale_lines == 1, "fix: reported " .. tostring(stale_lines) ..
      " stale-rebuild lines, want 1")
  assert(Fixture.hash(program) ~= before_hash,
    "fix: self-rebuild did not change the artifact")

  local second = Fixture.call_with_environment("fix-fresh",
    { program, "fix", "--check", "build/clock.tl" }, tree, diagnostics, values)
  assert(second.result.code == 0, "fix: second exit status was " ..
      tostring(second.result.code) .. ", want 0")
  Fixture.contains(second.out, "step8-fix-marker")
  assert(not Fixture.read(second.err):find("the tool is stale", 1, true),
    "fix: second invocation reported staleness though the tool is fresh")
end

-- A stale cosmic that is not the tree's own tool (one outside `o/`, as a
-- release, the bootstrap cache's or one on PATH is) refuses rather than
-- rebuild, since the rebuild would write the tree's tool over its own
-- file. `docs` meets the refusal in `build.reboot.stale_exit`, `test` and
-- a file run in `build.reboot.guard`, and `db` with an option it lacks in
-- the check build/dispatch.tl makes before it calls a refused command
-- line a usage error.
local function test_a_stale_tool_outside_the_tree_refuses(tmp: string)
  local fixture_dir = Fixture.required("COSMIC_FIXTURE_RUNTIME")
  local case_root = tmp .. "/case-foreign"
  local tree = case_root .. "/tree"
  local cache = case_root .. "/cache"
  local diagnostics = case_root .. "/logs"
  Fixture.mkdir(diagnostics)
  archive_tree(tree)
  local program = case_root .. "/elsewhere/cosmic"
  Fixture.mkdir(case_root .. "/elsewhere")
  Fixture.copy(fixture_dir .. "/runtime.old", program, 0x1ed)
  local before_hash = Fixture.hash(program)
  apply_docs_marker_edit(tree)

  local values = Fixture.environment({ COSMIC_PORTABLE_CACHE = cache })
  for _, verb in ipairs({
      { "docs", "cosmic.child" },
      { "test", "build/embed_test.tl" },
      { "build/embed_test.tl" },
      -- An option the tree may have added is not refused as a usage error.
      { "db", "--an-option-this-tool-lacks" },
  }) do
    local argv = { program }
    for _, word in ipairs(verb) do argv[#argv + 1] = word end
    local outcome = Fixture.call_with_environment("foreign-" .. (verb[1]:gsub("/", "-")),
      argv, tree, diagnostics, values)
    assert(outcome.result.code == 3, verb[1] .. ": exit status was " ..
        tostring(outcome.result.code) .. ", want 3")
    Fixture.contains(outcome.err, "is not the tree's own tool")
    assert(not Fixture.read(outcome.err):find("rebuilding it from the tree", 1, true),
      verb[1] .. ": a tool outside the tree rebuilt itself")
    assert(Fixture.hash(program) == before_hash,
      verb[1] .. ": a tool outside the tree was overwritten")
    assert(Fs.exists(tree .. "/o/bin/cosmic") == false,
      verb[1] .. ": a tool outside the tree wrote one into it")
  end
end
