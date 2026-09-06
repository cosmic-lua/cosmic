#!/usr/bin/env cosmic

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local vis = require("_cli.visibility")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- Build a fixture root under TEST_TMPDIR holding `cosmic/x/<name>` for
--- each name given, `set_cwd` into it, and return a restorer that puts
--- the caller's cwd back — `check_shard_dir_init` resolves its sibling
--- `init.tl` check relative to cwd, the same way the real gate runs
--- from the repo root.
--- @param dir_name string Subdirectory of TEST_TMPDIR to build the fixture in
--- @param names {string} File names to write under `cosmic/x/`, empty content
--- @return function Restores the original cwd when called
local function fixture(dir_name: string, names: {string}): function()
  local root = fs.join(tmpdir, dir_name)
  check.must(fs.remove_all(root))
  check.must(fs.make_dirs(fs.join(root, "cosmic/x")))
  for _, name in ipairs(names) do
    check.must(fs.write(fs.join(root, "cosmic/x/" .. name), "return {}\n"))
  end
  local cwd = check.must(fs.cwd())
  check.must(fs.set_cwd(root))
  return function()
    check.must(fs.set_cwd(cwd))
  end
end

-- A `cosmic/<name>/` directory holding a non-test shard and no
-- `init.tl` is unreachable from outside `cosmic/` by construction:
-- there is no `cosmic.<name>` to require instead.
local function test_shard_dir_without_init_is_flagged()
  local restore = fixture("vis_no_init", {"a.tl"})
  local diagnostics = vis.check_shard_dir_init("cosmic/x/a.tl")
  restore()
  assert(#diagnostics == 1, "expected one finding, got " .. #diagnostics)
  local d = diagnostics[1]
  assert(d.rule == "visibility", "rule name is visibility")
  assert(d.message:find("cosmic/x/", 1, true), "message names the directory")
  assert(d.message:find("init.tl", 1, true), "message names the fix")
end

-- The same shard, with an `init.tl` beside it, is a public parent
-- already — no finding.
local function test_shard_dir_with_init_is_not_flagged()
  local restore = fixture("vis_with_init", {"a.tl", "init.tl"})
  local diagnostics = vis.check_shard_dir_init("cosmic/x/a.tl")
  restore()
  assert(#diagnostics == 0, "an init.tl beside the shard needs no finding")
end

-- A directory holding only tests has no shard for anything outside
-- `cosmic/` to reach, so it needs no `init.tl` and no finding.
local function test_shard_dir_with_only_tests_is_not_flagged()
  local restore = fixture("vis_only_tests", {"a_test.tl"})
  local diagnostics = vis.check_shard_dir_init("cosmic/x/a_test.tl")
  restore()
  assert(#diagnostics == 0, "a lone test file is not itself a shard")
end

-- `init.tl` itself is never flagged, whatever else sits beside it.
local function test_init_file_itself_is_not_flagged()
  local restore = fixture("vis_init_itself", {"init.tl"})
  local diagnostics = vis.check_shard_dir_init("cosmic/x/init.tl")
  restore()
  assert(#diagnostics == 0, "init.tl is the public parent, not a shard")
end

print("all visibility tests passed")
