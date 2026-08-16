#!/usr/bin/env cosmic
--- Unit tests for _build.size: report() over a synthetic tree with
--- known file/line counts, and format_compare() against two handwritten
--- report fixtures.

local size = require("_build.size")
local check = require("cosmic.check")
local fs = require("cosmic.fs")

-- What report() actually reads: two real .tl files under cosmic/, one
-- real file plus one under _cli/testdata/ (which must not count), a
-- nested cmd/ module alongside a non-.tl file (which must not count),
-- and AGENTS.md.
local function test_report_counts_tl_files_and_lines_by_tree()
  local root = fs.join(check.must(os.getenv("TEST_TMPDIR")), "size")
  for _, dir in ipairs({"cosmic", "_cli/testdata", "cmd/hello"}) do
    assert(fs.make_dirs(fs.join(root, dir)))
  end
  -- cosmic/: 3 lines + 2 lines (no trailing newline still counts) = 5
  assert(fs.write(fs.join(root, "cosmic", "a.tl"), "line1\nline2\nline3\n"))
  assert(fs.write(fs.join(root, "cosmic", "b.tl"), "line1\nline2"))
  -- _cli/: one real file counts; the testdata one does not
  assert(fs.write(fs.join(root, "_cli", "c.tl"), "x\ny\n"))
  assert(fs.write(fs.join(root, "_cli", "testdata", "fixture.tl"), "z\n"))
  -- cmd/: one nested module counts; the non-.tl sibling does not
  assert(fs.write(fs.join(root, "cmd", "hello", "main.tl"), "print(1)\n"))
  assert(fs.write(fs.join(root, "cmd", "hello", "readme.txt"), "not counted\n"))
  assert(fs.write(fs.join(root, "AGENTS.md"), "a\nb\nc\n"))

  local rep = size.report(root)
  assert(rep.trees["cosmic"].tl_files == 2,
    "cosmic tl_files: " .. tostring(rep.trees["cosmic"].tl_files))
  assert(rep.trees["cosmic"].lines == 5,
    "cosmic lines: " .. tostring(rep.trees["cosmic"].lines))
  assert(rep.trees["_cli"].tl_files == 1,
    "_cli tl_files: " .. tostring(rep.trees["_cli"].tl_files))
  assert(rep.trees["_cli"].lines == 2,
    "_cli lines: " .. tostring(rep.trees["_cli"].lines))
  assert(rep.trees["cmd"].tl_files == 1,
    "cmd tl_files: " .. tostring(rep.trees["cmd"].tl_files))
  assert(rep.trees["cmd"].lines == 1,
    "cmd lines: " .. tostring(rep.trees["cmd"].lines))
  assert(rep.agents_md_lines == 3,
    "agents_md_lines: " .. tostring(rep.agents_md_lines))
  -- cosmic/a.tl and cosmic/b.tl are both public module names.
  assert(rep.public_modules == 2,
    "public_modules: " .. tostring(rep.public_modules))
  assert(rep.binary_bytes == nil,
    "no --binary given, expected binary_bytes absent")
end
test_report_counts_tl_files_and_lines_by_tree()

local function test_report_stats_the_binary_when_given()
  local root = fs.join(check.must(os.getenv("TEST_TMPDIR")), "size-binary")
  assert(fs.make_dirs(root))
  local bin_path = fs.join(root, "fake-binary")
  assert(fs.write(bin_path, string.rep("x", 42)))
  local rep = size.report(root, bin_path)
  assert(rep.binary_bytes == 42, "binary_bytes: " .. tostring(rep.binary_bytes))
end
test_report_stats_the_binary_when_given()

-- totals() sums only the tracked trees — an extra key some other caller
-- put on the map (or a corrupt file) does not inflate the summary line.
local function test_totals_sums_only_tracked_trees()
  local rep: size.Report = {
    trees = {
      cosmic = {tl_files = 3, lines = 30},
      _cli = {tl_files = 2, lines = 20},
      untracked = {tl_files = 100, lines = 1000},
    },
    agents_md_lines = 10,
    public_modules = 5,
  }
  local lines, files = size.totals(rep)
  assert(lines == 50, "lines: " .. tostring(lines))
  assert(files == 5, "files: " .. tostring(files))
end
test_totals_sums_only_tracked_trees()

-- format_compare() against two handwritten report files: exact totals,
-- exact signed deltas, exact line text.
local function test_compare_output_against_handwritten_reports()
  local root = check.must(os.getenv("TEST_TMPDIR"))
  local prev_path = fs.join(root, "size-prev.json")
  local cur_path = fs.join(root, "size-cur.json")
  assert(fs.write(prev_path, [[
{
  "trees": {
    "cosmic": {"tl_files": 10, "lines": 1000},
    "_cli": {"tl_files": 5, "lines": 500}
  },
  "agents_md_lines": 400,
  "public_modules": 30,
  "binary_bytes": 1000000
}
]]))
  assert(fs.write(cur_path, [[
{
  "trees": {
    "cosmic": {"tl_files": 12, "lines": 1100},
    "_cli": {"tl_files": 5, "lines": 520}
  },
  "agents_md_lines": 410,
  "public_modules": 31,
  "binary_bytes": 1050000
}
]]))
  local prev = check.must(size.load_report(prev_path))
  local cur = check.must(size.load_report(cur_path))
  local line = size.format_compare(prev, cur)
  assert(line ==
    "size: lines 1620 (+120), files 17 (+2), binary 1050000 (+50000), public modules 31 (+1)",
    "got: " .. line)
end
test_compare_output_against_handwritten_reports()

-- Comparing a report against itself: all deltas read "+0", never a
-- gate (see the module doc comment) — there is no threshold to clear.
local function test_compare_all_zero_deltas_when_reports_match()
  local root = check.must(os.getenv("TEST_TMPDIR"))
  local path = fs.join(root, "size-same.json")
  assert(fs.write(path,
      [[{"trees":{"cosmic":{"tl_files":4,"lines":40}},]] ..
      [["agents_md_lines":5,"public_modules":9,"binary_bytes":222}]]))
  local rep = check.must(size.load_report(path))
  local line = size.format_compare(rep, rep)
  assert(line ==
    "size: lines 40 (+0), files 4 (+0), binary 222 (+0), public modules 9 (+0)",
    "got: " .. line)
end
test_compare_all_zero_deltas_when_reports_match()

print("all size report tests passed")
