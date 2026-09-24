local Fs = require("cosmic.fs")
local Fixture = require("cosmic_ci.fixture")
local Process = require("cosmic_ci.process")

local type Running = Process.Running
local start, finish, supervised = Process.start, Process.finish, Process.supervised
local fifo, await_ready, release = Process.fifo, Process.await_ready, Process.release
-- The second readiness comes only after the paused tool has rebuilt itself
-- from the tree: a whole compile, 3-5 s on a runner, not a handshake.
local rebuild_timeout_ms <const> = 30000

-- Compares exactly the first `length` bytes of `program` against `expected`,
-- which must itself be exactly `length` bytes: a length mismatch on either
-- side, or a byte difference within the compared range, is a failure with a
-- message; a program longer than `length` still passes, since only its
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

-- Splits text into lines without dropping empty ones (unlike
-- `gmatch("[^\n]+")`, which every other fixture-test's line-oriented parsing
-- uses on inputs that are known not to contain blank lines). Assumes the
-- text ends with a trailing newline, as every source file in the tree does;
-- joining the result with "\n" and appending one final "\n" reproduces it.
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

-- `git archive HEAD | tar -xf -` the candidate root into a fresh tree, the
-- same fixture every rebuild/refusal case starts from.
local function archive_tree(root: string, tree: string, diagnostics: string)
  Fixture.mkdir(tree)
  Fixture.run("git-archive", { "/bin/sh", "-c",
    "git -C \"$1\" archive HEAD | tar -xf - -C \"$2\"", "sh", root, tree },
    root, diagnostics)
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
  lines = insert_after(lines, "local Time = require(\"cosmic.time\")",
    { "local step8_sys = require(\"cosmic.sys\")" })
  lines = insert_after(lines,
    "function test.run(argv: {integer:string}): integer", {
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
    "function docs.run(argv: {integer:string}): integer",
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
local function run_rebuild_case(root: string, fixture_dir: string,
    tmp: string, action: string)
  local case_root = tmp .. "/case-" .. action
  local tree = case_root .. "/tree"
  local cache = case_root .. "/cache"
  local diagnostics = case_root .. "/logs"
  Fixture.mkdir(diagnostics)
  archive_tree(root, tree, diagnostics)
  local program = place_runtime(fixture_dir, tree)
  local original_hash = Fixture.hash(program)
  local prefix_length = read_prefix_length(fixture_dir)
  apply_step8_edit(tree)

  local ready = fifo(case_root, diagnostics, "ready-" .. action)
  local go = fifo(case_root, diagnostics, "go-" .. action)

  supervised(function(active: {Running})
    local values = Fixture.environment({
      COSMIC_PORTABLE_CACHE = cache,
      COSMIC_PORTABLE_STARTUP_TEST_READY = ready,
      COSMIC_PORTABLE_STARTUP_TEST_GO = go,
      COSMIC_STEP8_REENTRY = "kept with spaces",
    })
    local child = start("rebuild-" .. action,
      { program, "test", "build/embed_test.tl", "argument with spaces" }, tree, values,
      diagnostics)
    active[#active + 1] = child

    await_ready(case_root, diagnostics, "first-" .. action, ready)
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
      rebuild_timeout_ms)
    release(case_root, diagnostics, "second-" .. action, go)

    local result = finish(child)
    assert(result.ok, action .. ": self-rebuild child did not exit " ..
      "successfully")

    Fixture.assert_executable(program)
    assert(Fixture.read(child.out):match(
      "test: PASS %([^;]+; [1-9][0-9]* ran, 0 stood"),
      action .. ": self-rebuild output did not match the expected pattern")
    local err = Fixture.read(child.err)
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
  end)
end

-- One of the three ways a stale tool (a pinned tl version, an unapplied
-- patch, or an edited launcher generator) is refused outright, when
-- COSMIC_AUTO_BOOT=0 says not to boot, without ever reaching `test.run` or
-- touching the artifact.
local function run_refusal_case(root: string, fixture_dir: string,
    tmp: string, name: string)
  local case_root = tmp .. "/refuse-" .. name
  local tree = case_root .. "/tree"
  local cache = case_root .. "/cache"
  local diagnostics = case_root .. "/logs"
  Fixture.mkdir(diagnostics)
  archive_tree(root, tree, diagnostics)
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

-- A pure unit test of `compare_prefix` itself, with three synthetic cases: an
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
  run_rebuild_case(Fixture.required("COSMIC_FIXTURE_ROOT"),
    Fixture.required("COSMIC_FIXTURE_RUNTIME"), tmp, "rename")
end

local function test_self_rebuild_after_an_unlink(tmp: string)
  run_rebuild_case(Fixture.required("COSMIC_FIXTURE_ROOT"),
    Fixture.required("COSMIC_FIXTURE_RUNTIME"), tmp, "unlink")
end

local function test_self_rebuild_refusals(tmp: string)
  local root = Fixture.required("COSMIC_FIXTURE_ROOT")
  local fixture_dir = Fixture.required("COSMIC_FIXTURE_RUNTIME")
  for _, name in ipairs({ "tl-pin", "tl-patch", "launcher" }) do
    run_refusal_case(root, fixture_dir, tmp, name)
  end
end

-- `cosmic docs` never compiles the tree itself, unlike `test`, so it relies
-- entirely on `build.reboot.stale_exit` to notice a stale embedded copy of
-- `build.docs` and rebuild before running -- the case `AGENTS.md`'s "an
-- edit to Teal needs no boot" promise depends on for a verb other than
-- `test`. A first call against an edited tree rebuilds once and shows the
-- edit; a second, now-fresh call shows it again without rebuilding again.
local function test_self_rebuild_docs_verb(tmp: string)
  local root = Fixture.required("COSMIC_FIXTURE_ROOT")
  local fixture_dir = Fixture.required("COSMIC_FIXTURE_RUNTIME")
  local case_root = tmp .. "/case-docs"
  local tree = case_root .. "/tree"
  local cache = case_root .. "/cache"
  local diagnostics = case_root .. "/logs"
  Fixture.mkdir(diagnostics)
  archive_tree(root, tree, diagnostics)
  local program = place_runtime(fixture_dir, tree)
  local before_hash = Fixture.hash(program)
  apply_docs_marker_edit(tree)

  local values = Fixture.environment({ COSMIC_PORTABLE_CACHE = cache })
  local outcome = Fixture.call_with_environment("docs-rebuild",
    { program, "docs", "cosmic.child" }, tree, diagnostics, values)
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

-- Marks `build/fix/init.tl`'s verb with an extra line, as the docs marker
-- does for `docs`: a `fix` the stale tool ran itself would not print it.
local function apply_fix_marker_edit(tree: string)
  local path = tree .. "/build/fix/init.tl"
  local lines = split_lines(Fixture.read(path))
  lines = insert_after(lines,
    "function fix.run(argv: {integer:string}): integer",
    { "  local _, _ = Fs.put(Fs.stdout, \"step8-fix-marker\\n\")" })
  Fixture.write(path, table.concat(lines, "\n") .. "\n")
end

-- `fix` in cosmic's own tree fixes with the tree's rules and layout, so a
-- tool older than the tree rebuilds itself before it fixes anything.
local function test_self_rebuild_fix_verb(tmp: string)
  local root = Fixture.required("COSMIC_FIXTURE_ROOT")
  local fixture_dir = Fixture.required("COSMIC_FIXTURE_RUNTIME")
  local case_root = tmp .. "/case-fix"
  local tree = case_root .. "/tree"
  local cache = case_root .. "/cache"
  local diagnostics = case_root .. "/logs"
  Fixture.mkdir(diagnostics)
  archive_tree(root, tree, diagnostics)
  local program = place_runtime(fixture_dir, tree)
  local before_hash = Fixture.hash(program)
  apply_fix_marker_edit(tree)

  local values = Fixture.environment({ COSMIC_PORTABLE_CACHE = cache })
  local outcome = Fixture.call_with_environment("fix-rebuild",
    { program, "fix", "--check", "build/clock.tl" }, tree, diagnostics, values)
  assert(outcome.result.code == 0, "fix: exit status was " ..
    tostring(outcome.result.code) .. ", want 0")
  Fixture.contains(outcome.out, "step8-fix-marker")
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

-- A stale cosmic that is not the tree's own tool -- one outside `o/`, as a
-- release, the bootstrap cache's or one on PATH is -- refuses rather than
-- rebuild, since the rebuild would write the tree's tool over its own
-- file. `docs` meets it in `build.reboot.stale_exit`, `test` in its own check,
-- and `db` with an option it lacks in the check cmd/cosmic/main.tl makes
-- before it calls a refused command line a usage error.
local function test_a_stale_tool_outside_the_tree_refuses(tmp: string)
  local root = Fixture.required("COSMIC_FIXTURE_ROOT")
  local fixture_dir = Fixture.required("COSMIC_FIXTURE_RUNTIME")
  local case_root = tmp .. "/case-foreign"
  local tree = case_root .. "/tree"
  local cache = case_root .. "/cache"
  local diagnostics = case_root .. "/logs"
  Fixture.mkdir(diagnostics)
  archive_tree(root, tree, diagnostics)
  local program = case_root .. "/elsewhere/cosmic"
  Fixture.mkdir(case_root .. "/elsewhere")
  Fixture.copy(fixture_dir .. "/runtime.old", program, 0x1ed)
  local before_hash = Fixture.hash(program)
  apply_docs_marker_edit(tree)

  local values = Fixture.environment({ COSMIC_PORTABLE_CACHE = cache })
  for _, verb in ipairs({
    { "docs", "cosmic.child" },
    { "test", "build/embed_test.tl" },
    -- An option the tree may have added is not refused as a usage error.
    { "db", "--an-option-this-tool-lacks" },
  }) do
    local argv = { program }
    for _, word in ipairs(verb) do argv[#argv + 1] = word end
    local outcome = Fixture.call_with_environment("foreign-" .. verb[1],
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
