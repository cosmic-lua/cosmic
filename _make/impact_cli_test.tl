#!/usr/bin/env cosmic
--- A changed API must diagnose its unchanged callers.
local check = require("cosmic.check")
local child = require("cosmic.child")
local fs = require("cosmic.fs")

local cosmic = fs.absolute_path(fs.join(os.getenv("TEST_BIN"), "cosmic"))

local function test_changed_api_checks_callers_and_reports_exclusions()
  local root = fs.join(os.getenv("TEST_TMPDIR") or "/tmp", "impact-cli")
  assert(fs.remove_all(root))
  assert(fs.make_dirs(root))
  assert(fs.write(fs.join(root, ".cosmicignore"), ""))
  assert(fs.write(fs.join(root, "api.tl"), "return 'new contract'\n"))
  assert(fs.write(fs.join(root, "caller.tl"),
      "local n: integer = require('api')\nreturn n\n"))
  assert(fs.write(fs.join(root, "unrelated.tl"), "return 1\n"))
  local ordinary = check.must(child.start({cosmic, "--make", "check", "api.tl"}, {cwd = root}))
  check.equal(check.must(ordinary:wait()).code, 0)
  local changed = check.must(child.start({cosmic, "--make", "check", "--changed", "api.tl"}, {cwd = root}))
  local result = check.must(changed:wait())
  check.equal(result.code, 1)
  assert((result.stderr or ""):find("caller.tl", 1, true))
  assert((result.stdout or ""):find("2 checkable file(s)", 1, true))
  assert((result.stdout or ""):find("excluded file(s)", 1, true))
end

local function test_deleted_path_selects_all_instead_of_empty_pass()
  local root = fs.join(os.getenv("TEST_TMPDIR") or "/tmp", "impact-cli-deleted")
  assert(fs.remove_all(root))
  assert(fs.make_dirs(root))
  assert(fs.write(fs.join(root, ".cosmicignore"), ""))
  assert(fs.write(fs.join(root, "caller.tl"), "return require('gone')\n"))
  local process = check.must(child.start({cosmic, "--make", "check", "--changed", "gone.tl"}, {cwd = root}))
  local result = check.must(process:wait())
  check.equal(result.code, 1)
  assert((result.stdout or ""):find("full selection:", 1, true))
  assert((result.stderr or ""):find("caller.tl", 1, true))
end
