#!/usr/bin/env cosmic
-- Tests for `cosmic --find`, spawned against fixture trees with cwd
-- inside the fixture -- the same shape `_make/check_test.tl` uses for
-- the flag it borrows its default file selection from.

local check = require("cosmic.check")
local child = require("cosmic.child")
local find_mod = require("_cli.find")
local fs = require("cosmic.fs")

local cosmic = fs.absolute_path(fs.join(os.getenv("TEST_BIN"), "cosmic"))
local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

local record Run
  code: integer
  out: string
  err: string
end

--- Build a fixture tree, returning its absolute root.
--- @param name string A name unique to this test, for the fixture's own directory
--- @param files {string: string} Relative path -> file contents
--- @return string The fixture's absolute root
local function fixture(name: string, files: {string: string}): string
  local root = fs.join(tmpdir, "find-" .. name)
  assert(fs.remove_all(root))
  assert(fs.make_dirs(root))
  for rel, content in pairs(files) do
    assert(fs.write(fs.join(root, rel), content))
  end
  return root
end

--- Run `cosmic --find ...` with cwd inside `dir`.
--- @param dir string The fixture root
--- @param ... string The flag's own arguments (pattern, then paths)
--- @return Run The exit code and captured output
local function find(dir: string, ...: string): Run
  local argv: {string} = {cosmic, "--find"}
  for _, a in ipairs({...}) do
    argv[#argv + 1] = a
  end
  local h = check.must(child.start(argv, {cwd = dir}))
  local r = check.must(h:wait())
  return {code = r.code or 128, out = r.stdout or "", err = r.stderr or ""}
end

--- Three files: two `print(...)` call statements and one `output(...)`
--- call -- a `print($X)` pattern hits the first and third only.
--- @return string The fixture's absolute root
local function three_file_tree(): string
  return fixture("hits", {
      ["a.tl"] = "print(1)\n",
      ["b.tl"] = "output(2)\n",
      ["c.tl"] = "print(3)\n",
    })
end

local function test_pattern_hits_two_of_three_files_in_path_order()
  local root = three_file_tree()
  local r = find(root, "print($X)", "a.tl", "b.tl", "c.tl")
  assert(r.code == 0, "expected exit 0, got " .. tostring(r.code) .. ": " .. r.err)
  local a_at = r.out:find("a.tl:1:1: print(1)", 1, true)
  local c_at = r.out:find("c.tl:1:1: print(3)", 1, true)
  assert(a_at ~= nil, "expected a hit in a.tl: " .. r.out)
  assert(c_at ~= nil, "expected a hit in c.tl: " .. r.out)
  assert(a_at < c_at, "a.tl must sort before c.tl: " .. r.out)
  assert(not r.out:find("b.tl:", 1, true), "b.tl must not match print($X): " .. r.out)
  assert(r.out:find("find: 2 hit(s) in 3 file(s)", 1, true),
    "expected verdict line: " .. r.out)
end

local function test_pattern_with_no_hits_exits_1()
  local root = three_file_tree()
  local r = find(root, "nonexistent_call($X)", "a.tl", "b.tl", "c.tl")
  assert(r.code == 1, "expected exit 1, got " .. tostring(r.code) .. ": " .. r.err)
  assert(r.out:find("find: 0 hit(s)", 1, true),
    "expected the zero-hit verdict: " .. r.out)
end

local function test_broken_pattern_refuses_with_exit_2()
  local root = three_file_tree()
  local r = find(root, "if $C then", "a.tl")
  assert(r.code == 2, "expected exit 2, got " .. tostring(r.code) .. ": " .. r.err)
  assert(r.out:find("find: refused:", 1, true),
    "expected a refusal verdict naming the parse error: " .. r.out)
end

--- The same three cases run IN PROCESS, `fs.set_cwd` saved and
--- restored around the call -- the shape `_make/check_test.tl` uses so
--- a run's own lines land in coverage instead of vanishing into the
--- spawned binary's embedded copy (`find_mod.run` always scans the
--- CURRENT directory, so there is no root argument to pass instead).
--- This is also the only exercise of the no-PATH default: the whole
--- project's own `.tl` sources, by way of `_make.check`'s own
--- `select_files`.
local function test_run_in_process_matches_and_refuses()
  local root = three_file_tree()
  local cwd = check.must(fs.cwd())
  assert(fs.set_cwd(root))
  local hit_code = find_mod.run("print($X)", {"a.tl", "b.tl", "c.tl"})
  assert(hit_code == 0, "expected exit 0 in process, got " .. tostring(hit_code))
  local no_hit_code = find_mod.run("nonexistent_call($X)", {})
  assert(no_hit_code == 1,
    "expected exit 1 in process over the default file walk, got " .. tostring(no_hit_code))
  local refuse_code = find_mod.run("if $C then", {"a.tl"})
  assert(refuse_code == 2, "expected exit 2 in process, got " .. tostring(refuse_code))
  assert(fs.set_cwd(cwd))
end
