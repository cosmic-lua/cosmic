#!/usr/bin/env cosmic
--- JSON results retain every diagnostic and the actual selected scope.
local check = require("cosmic.check")
local child = require("cosmic.child")
local fs = require("cosmic.fs")
local json = require("cosmic.json")
local check_result = require("_make.check_result")

local cosmic = fs.absolute_path(fs.join(os.getenv("TEST_BIN"), "cosmic"))

local function test_machine_result_contains_all_selected_failures()
  local root = fs.join(os.getenv("TEST_TMPDIR") or "/tmp", "check-result")
  assert(fs.remove_all(root))
  assert(fs.make_dirs(root))
  assert(fs.write(fs.join(root, ".cosmicignore"), ""))
  assert(fs.write(fs.join(root, "a.tl"), "local a: integer = 'bad'\nreturn a\n"))
  assert(fs.write(fs.join(root, "b.tl"), "local b: string = 3\nreturn b\n"))
  local path = fs.join(root, "o", "check.json")
  local process = check.must(child.start({cosmic, "--make", "check", "--report", path}, {cwd = root}))
  local outcome = check.must(process:wait())
  check.equal(outcome.code, 1)
  local raw = check.must(json.decode(check.must(fs.read(path))))
  local result = raw as check_result.Result -- cast: decode the report schema emitted by this fixture
  assert(result.complete)
  assert(not result.ok)
  check.equal(#result.selected, 2)
  check.equal(#result.checked, 2)
  local files: {string: boolean} = {}
  for _, issue in ipairs(result.diagnostics) do files[issue.file] = true end
  assert(files["a.tl"])
  assert(files["b.tl"])
  -- Reports in the ignored build directory can be replaced on a later run.
  local again = check.must(child.start({cosmic, "--make", "check", "--report", path}, {cwd = root}))
  check.equal(check.must(again:wait()).code, 1)
  assert(fs.read(path))
end

local function test_report_cannot_overwrite_selected_source()
  local root = fs.join(os.getenv("TEST_TMPDIR") or "/tmp", "check-result-source")
  assert(fs.remove_all(root))
  assert(fs.make_dirs(root))
  assert(fs.write(fs.join(root, ".cosmicignore"), ""))
  local code = "return 1\n"
  assert(fs.write(fs.join(root, "a.tl"), code))
  local process = check.must(child.start({cosmic, "--make", "check", "--report", "a.tl"}, {cwd = root}))
  check.equal(check.must(process:wait()).code, 1)
  check.equal(check.must(fs.read(fs.join(root, "a.tl"))), code)
end

local function test_unavailable_input_is_explicitly_incomplete()
  local result = check_result.new("/project")
  check_result.failure(result, "gone.tl", "cannot read source")
  assert(not result.complete)
  assert(not result.ok)
  check.equal(#result.failures, 1)
  check.equal(result.failures[1].file, "gone.tl")
end
