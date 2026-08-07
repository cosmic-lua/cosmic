#!/usr/bin/env cosmic
-- Tests for the test runner: a cosmic carrying the project's root
-- payload, so `/zip/R` resolves inside a test as inside the artifact.
-- The end-to-end half (a fixture test actually reading `/zip/...`
-- under `--make test`) lives in fixtures_test; these assert the
-- assembly itself: what the runner carries, what it costs when nothing
-- changed, and that a payload-free project builds none.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local project = require("_make.project")
local testrun = require("_make.testrun")
local types = require("_make.types")
local zip = require("cosmic.zip")

local type Project = types.Project

local cosmic = fs.abspath(fs.join(os.getenv("TEST_BIN"), "cosmic"))
local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- Build a fixture tree, returning its absolute root.
local function fixture(name: string, files: {string: string}): string
  local root = fs.join(tmpdir, "testrun-" .. name)
  assert(fs.remove_all(root))
  assert(fs.make_dirs(root))
  for rel, content in pairs(files) do
    local path = fs.join(root, rel)
    assert(fs.make_dirs(fs.dirname(path)))
    assert(fs.write(path, content))
  end
  return root
end

--- Scan and build the runner from inside the fixture root, restoring
--- the cwd either way: testrun's paths are root-relative, like every
--- graph path.
local function build_in(root: string): boolean, string
  local proj: Project = check.must(project.scan(root))
  local cwd = check.must(fs.cwd())
  assert(fs.chdir(root))
  local ok, err = testrun.build(proj, cosmic)
  assert(fs.chdir(cwd))
  return ok, err
end

local function test_runner_carries_root_payload()
  local root = fixture("payload", {
      ["cmd/app/main.tl"] = "print('x')\n",
      ["embed/data/note.txt"] = "carried\n",
    })
  local ok, err = build_in(root)
  assert(ok, "runner should assemble: " .. tostring(err))
  local runner = fs.join(root, testrun.PATH)
  assert(fs.is_file(runner), "runner exists at " .. testrun.PATH)
  local reader = check.must(zip.open(runner))
  local saw: {string: boolean} = {}
  for _, e in ipairs(reader:list()) do
    saw[e.name] = true
  end
  reader:close()
  assert(saw["data/note.txt"], "payload at its artifact path, prefix stripped")
  assert(saw["cosmic/fs.lua"], "the toolchain rides along un-stripped")
end
test_runner_carries_root_payload()

local function test_unchanged_runner_keeps_its_mtime()
  local root = fixture("still", {
      ["cmd/app/main.tl"] = "print('x')\n",
      ["embed/asset.txt"] = "bytes\n",
    })
  check.must(build_in(root))
  local runner = fs.join(root, testrun.PATH)
  local before = check.must(fs.stat(runner)):mtim()
  check.must(build_in(root))
  local after = check.must(fs.stat(runner)):mtim()
  check.equal(after, before, "identical payload must not move the runner")
end
test_unchanged_runner_keeps_its_mtime()

local function test_no_payload_no_runner()
  local root = fixture("plain", {
      ["cmd/app/main.tl"] = "print('x')\n",
    })
  local proj: Project = check.must(project.scan(root))
  assert(not testrun.enabled(proj), "no root payload, no runner")
  check.must(build_in(root))
  assert(not fs.exists(fs.join(root, testrun.PATH)),
    "a payload-free project assembles nothing")
end
test_no_payload_no_runner()

print("all testrun tests passed")
