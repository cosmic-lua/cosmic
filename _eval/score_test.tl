local fs = require("cosmic.fs")
local json = require("cosmic.json")
local check = require("cosmic.check")
local score = require("_eval.score")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- Copy a committed _eval/testdata fixture run dir into a scratch
--- directory. score.main never writes into the run dir it is given --
--- it stages its own scoring copy under o/_eval/scored/ (see
--- score.out_dir_for) -- so this is purely test isolation: a test that
--- mutates its input (e.g. rewriting probe.txt) before scoring must do
--- so on a private copy, never the committed fixture.
--- @param name string The fixture's directory name under _eval/testdata
--- @return string The scratch copy's path
local function copy_fixture(name: string): string
  local src = fs.join("_eval/testdata", name)
  local dst = fs.join(tmpdir,
    "score-" .. name .. "-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000000)))
  check.must(fs.copy_tree(src, dst))
  return dst
end

--- @param dir string The run dir argument a scoring call was given
--- @return {string: any} The decoded results.json from that call's
--- staged scoring copy (see score.out_dir_for)
local function read_results(dir: string): {string: any}
  local body = check.must(fs.read(fs.join(score.out_dir_for(dir), "results.json")))
  return check.must(json.decode_object(body)) as {string: any} -- cast: from any
end

--- Run score.main(dir) and capture exactly what it prints via print()
--- -- the verdict line, and nothing io.stderr:write reports -- the same
--- swap-and-restore pattern _tool/example.tl and _tool/benchmark.tl use
--- to pin a CLI's exact console output, without paying for a real
--- subprocess spawn.
--- @param dir string The run dir to score
--- @return integer score.main's exit code
--- @return string Every print()'d line, newline-joined, no trailing newline
local function score_and_capture(dir: string): integer, string
  local old_print = _G.print
  local lines: {string} = {}
  _G.print = function(...: any)
    local parts: {string} = {}
    for i = 1, select("#", ...) do
      parts[i] = tostring((select(i, ...)))
    end
    lines[#lines + 1] = table.concat(parts, "\t")
  end
  local ok, result = pcall(score.main, dir)
  _G.print = old_print
  if not ok then
    error(result, 0)
  end
  return result as integer, table.concat(lines, "\n") -- cast: pcall result
end

local function test_run_pass_ends_pass_exit_zero()
  local dir = copy_fixture("run_pass")
  local code, printed = score_and_capture(dir)
  assert(code == 0, "run_pass should exit 0, got " .. code)
  assert(printed == "eval: PASS",
    "expected the exact verdict line 'eval: PASS', got " .. string.format("%q", printed))
  local results = read_results(dir)
  assert(results.verdict == "PASS", "expected verdict PASS, got " .. tostring(results.verdict))
end
test_run_pass_ends_pass_exit_zero()

local function test_run_fail_ends_fail_nonzero_with_silent_bug()
  local dir = copy_fixture("run_fail")
  local code, printed = score_and_capture(dir)
  assert(code ~= 0, "run_fail should exit non-zero, got " .. code)
  assert(printed == "eval: FAIL (json-cli)",
    "expected the exact verdict line naming the failing task id, got " ..
    string.format("%q", printed))
  local results = read_results(dir)
  assert(results.verdict == "FAIL", "expected verdict FAIL, got " .. tostring(results.verdict))
  local rows = results.rows as {{string: any}} -- cast: from any
  local found: {string: any} = nil
  for _, row in ipairs(rows) do
    if row.task == "json-cli" then
      found = row
    end
  end
  assert(found ~= nil, "expected a json-cli row")
  local bugs = found.silent_bugs as number -- cast: from any
  assert(bugs >= 1, "json-cli's row should carry >= 1 silent_bugs from the check, got " ..
    tostring(bugs))
  assert(found.status == "completed",
    "json-cli should still be completed (built, just wrong), got " .. tostring(found.status))
  -- run_fail is seeded with exactly ONE defect. Every other row must
  -- score clean, or a marker a later check learns to look for -- added
  -- to run_pass only -- would silently record unintended defects here
  -- too, invisible for as long as the affected task stays "new" and
  -- never gates the verdict.
  for _, row in ipairs(rows) do
    if row.task ~= "json-cli" then
      local row_bugs = row.silent_bugs as number -- cast: from any
      assert(row_bugs == 0, tostring(row.task) ..
        ": run_fail should only seed a defect in json-cli, got silent_bugs = " ..
        tostring(row_bugs))
    end
  end
end
test_run_fail_ends_fail_nonzero_with_silent_bug()

local function test_run_partial_writes_complete_results_and_fails()
  local dir = copy_fixture("run_partial")
  local code, printed = score_and_capture(dir)
  assert(code ~= 0, "run_partial should exit non-zero (an unrun suite is not a clean window)")
  -- sqlite-indexer is the only PROVEN task missing its built artifact
  -- (see below); an incomplete proven task fails the gate on its own,
  -- and the verdict line must name it, not a bug count that reads 0
  -- here and would misreport this as clean.
  assert(printed == "eval: FAIL (sqlite-indexer)",
    "expected the exact verdict line naming the failing task id, got " ..
    string.format("%q", printed))
  assert(fs.is_file(fs.join(score.out_dir_for(dir), "results.json")),
    "results.json must still be written")
  local results = read_results(dir)
  assert(results.verdict == "FAIL", "expected verdict FAIL, got " .. tostring(results.verdict))
  local rows = results.rows as {{string: any}} -- cast: from any
  assert(#rows == 7, "expected all 7 manifest tasks represented, got " .. #rows)
  local by_task: {string: {string: any}} = {}
  for _, row in ipairs(rows) do
    by_task[row.task as string] = row -- cast: from any
  end
  assert(by_task["multi-module-build"].status == "error",
    "a missing workspace should score status = error, got " ..
    tostring(by_task["multi-module-build"].status))
  assert(by_task["sqlite-indexer"].status == "incomplete",
    "a proven task missing its built artifact should score status = incomplete, got " ..
    tostring(by_task["sqlite-indexer"].status))
  assert((by_task["sqlite-indexer"].silent_bugs as number) == 0, -- cast: from any
    "an incomplete row must not carry silent bugs")
  assert(by_task["text-report"].attempts_first_build == nil,
    "an unparseable final.txt should leave attempts_first_build nil, got " ..
    tostring(by_task["text-report"].attempts_first_build))
end
test_run_partial_writes_complete_results_and_fails()

local function test_every_meta_field_is_present()
  local dir = copy_fixture("run_pass")
  local scored = score.main(dir)
  assert(scored == 0, "scoring run_pass should succeed, got exit " .. scored)
  local results = read_results(dir)
  local meta = results.meta as {string: any} -- cast: from any
  local want < const >: {string} = {
    "timestamp", "suite_version", "bin", "bin_sha", "cosmic_version",
    "os", "isa", "model", "agent_tool", "timeout_secs",
    "probe_output", "leaked",
  }
  for _, field in ipairs(want) do
    assert(meta[field] ~= nil, "results.json meta is missing field: " .. field)
  end
  assert(meta.leaked == false, "run_pass's clean READY/NONE probe should not read as leaked")
end
test_every_meta_field_is_present()

local function test_every_row_field_is_present()
  local dir = copy_fixture("run_pass")
  local scored = score.main(dir)
  assert(scored == 0, "scoring run_pass should succeed, got exit " .. scored)
  local results = read_results(dir)
  local rows = results.rows as {{string: any}} -- cast: from any
  assert(#rows == 7, "expected 7 rows, got " .. #rows)
  local want < const >: {string} = {
    "task", "status", "silent_bugs", "journal_path", "friction",
  }
  for _, row in ipairs(rows) do
    for _, field in ipairs(want) do
      assert(row[field] ~= nil,
        tostring(row.task) .. ": results.json row is missing field: " .. field)
    end
    assert(row.status == "completed",
      tostring(row.task) .. ": run_pass should score every row completed, got " ..
      tostring(row.status))
    assert((row.silent_bugs as number) == 0, -- cast: from any
      tostring(row.task) .. ": run_pass should score 0 silent_bugs, got " ..
      tostring(row.silent_bugs))
  end
end
test_every_row_field_is_present()

local function test_leaked_probe_is_recorded()
  local dir = copy_fixture("run_pass")
  check.must(fs.write(fs.join(dir, "probe.txt"), "READY\n\"cosmic is a Lua distribution\"\n"))
  local code = score.main(dir)
  local results = read_results(dir)
  local meta = results.meta as {string: any} -- cast: from any
  assert(meta.leaked == true, "a probe reply beyond READY/NONE must read as leaked")
  local _ = code
end
test_leaked_probe_is_recorded()

local function test_missing_probe_reads_as_leaked()
  local dir = copy_fixture("run_pass")
  check.must(fs.remove(fs.join(dir, "probe.txt")))
  score.main(dir)
  local results = read_results(dir)
  local meta = results.meta as {string: any} -- cast: from any
  assert(meta.leaked == true, "a missing probe.txt must never read as clean")
  assert(meta.probe_output == "", "a missing probe.txt should read as empty, not guessed")
end
test_missing_probe_reads_as_leaked()

local function test_missing_meta_json_fails_cleanly()
  local dir = copy_fixture("run_pass")
  check.must(fs.remove(fs.join(dir, "meta.json")))
  local code = score.main(dir)
  assert(code ~= 0, "scoring a run dir with no meta.json must fail")
  assert(not fs.is_file(fs.join(score.out_dir_for(dir), "results.json")),
    "no results.json should be written when meta.json cannot be loaded")
end
test_missing_meta_json_fails_cleanly()

local function test_missing_run_dir_fails_cleanly()
  local code = score.main(fs.join(tmpdir, "no-such-run-dir-at-all"))
  assert(code ~= 0, "scoring a nonexistent run dir must fail")
end
test_missing_run_dir_fails_cleanly()

--- The one test that scores through a genuinely RELATIVE path into a
--- COMMITTED fixture, unlike every test above (copy_fixture's scratch
--- copies are always absolute TEST_TMPDIR paths and cannot reach this
--- shape). Proves both halves of the fix at once: a relative run dir
--- argument scores correctly (the cwd-independence fix), and nothing
--- lands in the committed tree afterward (the never-writes-into-input
--- fix) -- results.json, and the fixture inputs contained-task's check
--- materializes into its workspace.
local function test_relative_rundir_scores_without_touching_committed_tree()
  local rel = "_eval/testdata/run_pass"
  local code, printed = score_and_capture(rel)
  assert(code == 0, "run_pass via a relative path should exit 0, got " .. code)
  assert(printed == "eval: PASS",
    "expected the exact verdict line 'eval: PASS', got " .. string.format("%q", printed))
  assert(not fs.is_file(fs.join(rel, "results.json")),
    "scoring must never write results.json into the committed run dir")
  assert(not fs.is_dir(fs.join(rel, "contained-task", "testdata")),
    "scoring must never materialize a check's fixture inputs into the committed run dir")
  local results = read_results(rel)
  assert(results.verdict == "PASS", "expected verdict PASS, got " .. tostring(results.verdict))
end
test_relative_rundir_scores_without_touching_committed_tree()

local function test_requires_exactly_one_argument()
  assert(score.parse_args({}).err ~= nil, "no arguments should be an error")
  assert(score.parse_args({"a", "b"}).err ~= nil, "two arguments should be an error")
  assert(score.parse_args({"a"}).err == nil, "one argument should parse cleanly")
end
test_requires_exactly_one_argument()
