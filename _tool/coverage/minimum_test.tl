#!/usr/bin/env cosmic
--- Tests for the coverage minimum-percentage gate.
local check = require("cosmic.check")
local fs = require("cosmic.fs")
local minimum = require("_tool.coverage.minimum")
local rep = require("_tool.coverage.report")

local type FileReport = rep.FileReport

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- One synthetic FileReport -- the shape `report.compute` returns,
--- built directly so `violations` is tested without a filesystem or
--- `.cov` data in play.
--- @param display string The row's path
--- @param covered integer Lines this run covered
--- @param total integer The file's line universe size
--- @return FileReport
local function row(display: string, covered: integer, total: integer): FileReport
  return {display = display, covered = covered, total = total, missing = {}, note = ""}
end

-- violations: the pure percentage math

local function test_violations_empty_with_neither_option()
  local got = minimum.violations({row("a.tl", 1, 10)}, nil, nil)
  assert(#got == 0, "neither option set must never violate, got: " ..
    table.concat(got, "; "))
end

-- Five files, 12 of 15 lines covered: 80.0% on the nose.
local EIGHTY_PERCENT < const >: {FileReport} = {
  row("a.tl", 3, 3), row("b.tl", 3, 3), row("c.tl", 3, 3),
  row("d.tl", 3, 3), row("e.tl", 0, 3),
}

local function test_min_passes_at_the_exact_floor()
  local got = minimum.violations(EIGHTY_PERCENT, 80, nil)
  assert(#got == 0, "80.0% must pass --min 80, got: " .. table.concat(got, "; "))
end

local function test_min_fails_one_point_above()
  local got = minimum.violations(EIGHTY_PERCENT, 81, nil)
  assert(#got == 1, "80.0% must fail --min 81, got " .. #got)
  assert(got[1]:find("total: 80.0%% under %-%-min 81"),
    "must name the overall percentage: " .. got[1])
end

local function test_min_file_names_the_file_under_floor()
  local reports = {row("half.tl", 1, 2), row("full.tl", 3, 3)}
  local got = minimum.violations(reports, nil, 60)
  assert(#got == 1, "exactly one file is under 60%%, got " .. #got)
  assert(got[1]:find("half.tl", 1, true),
    "must name the file under the floor: " .. got[1])
  assert(not got[1]:find("full.tl", 1, true),
    "must not name a file that clears the floor: " .. got[1])
  assert(got[1]:find("50.0%%"), "must report its percentage: " .. got[1])
end

local function test_min_file_passes_at_the_exact_floor()
  local got = minimum.violations({row("half.tl", 1, 2)}, nil, 50)
  assert(#got == 0, "50.0%% must pass --min-file 50, got: " ..
    table.concat(got, "; "))
end

local function test_both_floors_report_independently()
  local reports = {row("half.tl", 1, 2), row("full.tl", 3, 3)}
  local got = minimum.violations(reports, 90, 60)
  assert(#got == 2, "the file and the total must both violate, got " .. #got)
end

-- A file with no executable lines counts as fully covered, the same
-- convention `report.render` uses, so it never drags --min-file down.
local function test_a_file_with_no_lines_is_never_under_the_floor()
  local got = minimum.violations({row("empty.tl", 0, 0)}, nil, 100)
  assert(#got == 0, "a total of zero must read as 100%%, got: " ..
    table.concat(got, "; "))
end

-- gate: the same math, end to end against real `.cov` data, no
-- committed floor anywhere -- `minimum.gate` needs none.

--- Build a project root with one module per entry, a `.cov` file
--- recording lines 1..`covered` as hit for each, and no baseline file
--- of any kind.
--- @param name string Subdirectory of TEST_TMPDIR to build it in
--- @param modules {{string, string, integer}} path (under lib/), source body, lines to mark hit
--- @return string The fixture root
--- @return {string} Report inputs for `minimum.gate`: the .cov dir, then "lib"
local function corpus(name: string,
    modules: {{string, string, integer}}): string, {string}
  local root = fs.join(tmpdir, name)
  check.must(fs.remove_all(root))
  check.must(fs.make_dirs(fs.join(root, "lib")))
  check.must(fs.make_dirs(fs.join(root, "o", ".coverage")))
  local hits: {string} = {}
  for _, m in ipairs(modules) do
    local rel, body, covered = "lib/" .. m[1], m[2], m[3]
    check.must(fs.write(fs.join(root, rel), body))
    local lines: {string} = {}
    for line = 1, covered do
      lines[#lines + 1] = "[" .. line .. "]=1"
    end
    hits[#hits + 1] = '["@' .. rel .. '"]={' .. table.concat(lines, ",") .. "}"
  end
  check.must(fs.write(fs.join(root, "o/.coverage/run.cov"),
      "return {version=1,hits={" .. table.concat(hits, ",") .. "}}"))
  return root, {fs.join("o", ".coverage"), "lib"}
end

local THREE_LINES < const > = "local x = 1\nlocal y = 2\nreturn x + y\n"
local TWO_LINES < const > = "local x = 1\nreturn x\n"
local SIX_ANALYZED_LINES < const > = "local a = 1\nlocal b = 2\nlocal c = 3\n" ..
"-- not executable\nlocal d = 4\nlocal e = 5\n-- not executable\n" ..
"return a + b + c + d + e\n"

--- Run `minimum.gate` with cwd at `root`, capturing stdout and stderr
--- to files under it -- restoring cwd and both streams unconditionally,
--- even when `gate` throws, so a failure here cannot leave a later test
--- in the fixture directory or writing to a closed file.
--- @param root string The fixture root to chdir into
--- @param paths {string} Report inputs, see `corpus`
--- @param min number|nil Overall floor, percent
--- @param min_file number|nil Per-file floor, percent
--- @return integer The exit code `minimum.gate` returned
--- @return string Captured stderr
local function run_gate(root: string, paths: {string}, min: number | nil,
    min_file: number | nil): integer, string
  local cwd = check.must(fs.cwd())
  check.must(fs.set_cwd(root))
  local stderr_path = fs.join(root, "stderr.txt")
  local real_stdout = io.output()
  local real_stderr = io.stderr
  io.stderr = assert(io.open(stderr_path, "w"))
  io.output(assert(io.open(fs.join(root, "stdout.txt"), "w")))

  local ok, code_or_err = pcall(minimum.gate, paths, min, min_file)

  io.output():close()
  io.output(real_stdout)
  io.stderr:close()
  io.stderr = real_stderr
  check.must(fs.set_cwd(cwd))

  if not ok then
    error(code_or_err, 0)
  end
  return code_or_err as integer, check.must(fs.read(stderr_path)) -- cast: pcall's return is `any`, and gate always returns an integer
end

local function test_gate_corpus_at_eighty_percent_passes_min_eighty()
  local root, paths = corpus("min-corpus-80", {
      {"a.tl", THREE_LINES, 3}, {"b.tl", THREE_LINES, 3},
      {"c.tl", THREE_LINES, 3}, {"d.tl", THREE_LINES, 3},
      {"e.tl", THREE_LINES, 0},
    })
  local code, printed = run_gate(root, paths, 80, nil)
  assert(code == 0, "80%% must pass --min 80: " .. printed)
end

local function test_gate_corpus_at_eighty_percent_fails_min_eighty_one()
  local root, paths = corpus("min-corpus-81", {
      {"a.tl", THREE_LINES, 3}, {"b.tl", THREE_LINES, 3},
      {"c.tl", THREE_LINES, 3}, {"d.tl", THREE_LINES, 3},
      {"e.tl", THREE_LINES, 0},
    })
  local code, printed = run_gate(root, paths, 81, nil)
  assert(code ~= 0, "80%% must fail --min 81")
  assert(printed:find("under %-%-min 81"), "must name the miss: " .. printed)
  assert(printed:find("declined:", 1, true),
    "the last line must survive truncation: " .. printed)
end

local function test_gate_names_the_file_under_min_file()
  local root, paths = corpus("min-corpus-file", {
      {"half.tl", TWO_LINES, 1}, {"full.tl", THREE_LINES, 3},
    })
  local code, printed = run_gate(root, paths, nil, 60)
  assert(code ~= 0, "a 50%% file must fail --min-file 60")
  assert(printed:find("lib/half.tl", 1, true),
    "must name the file under the floor: " .. printed)
  assert(not printed:find("lib/full.tl", 1, true),
    "must not name the file that clears the floor: " .. printed)
end

local function test_gate_names_exact_uncovered_ranges_without_changing_summary()
  local root, paths = corpus("min-corpus-gaps", {
      {"declined.tl", SIX_ANALYZED_LINES, 1}, {"full.tl", THREE_LINES, 3},
    })
  check.must(fs.write(fs.join(root, "o/.coverage/second.cov"),
      'return {version=1,hits={["@lib/declined.tl"]={[2]=1}}}'))
  local code, printed = run_gate(root, paths, nil, 100)
  assert(code ~= 0, "a 2/6 file must still fail --min-file 100")
  assert(printed:find(
      "lib/declined.tl: 33.3% under --min-file 100.0% (2/6)  " ..
      "uncovered: 3,5-6,8", 1, true),
    "must append exact compact missing ranges: " .. printed)
  assert(not printed:find("coverage minimum: lib/full.tl:", 1, true),
    "a fully covered companion must emit no refusal: " .. printed)
  assert(printed:sub(-#("coverage minimum: 1 problem(s); " ..
        "declined: lib/declined.tl\n")) ==
    "coverage minimum: 1 problem(s); declined: lib/declined.tl\n",
    "the trailing declined summary must stay unchanged: " .. printed)
end

local function test_gate_reports_and_passes_with_neither_option()
  local root, paths = corpus("min-corpus-report", {{"a.tl", THREE_LINES, 3}})
  local code, _printed = run_gate(root, paths, nil, nil)
  assert(code == 0, "no floor at all must report and pass")
end

print("all minimum tests passed")
