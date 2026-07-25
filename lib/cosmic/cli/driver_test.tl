#!/usr/bin/env cosmic
-- Tests for cosmic.cli.driver: the derived fence around a recipe step.
--
-- The derivation is a pure function of (verb, args) and the paths that
-- exist, so it is tested directly rather than through a kernel that may
-- not support Landlock -- `unveil()` no-ops without it, and CI's
-- enforce lane is where the fence is proven live. What matters here is
-- that the plan says the right thing, and that it exists for every verb.

local build = require("cosmic.build")
local driver = require("cosmic.cli.driver")
local fs = require("cosmic.fs")
local sandbox = require("cosmic.sandbox")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

local function touch(name: string): string
  local path = fs.join(tmpdir, name)
  assert(fs.write(path, "x\n"))
  return path
end

local function has(list: {string}, want: string): boolean
  for _, v in ipairs(list or {}) do
    if v == want then
      return true
    end
  end
  return false
end

-- Every verb must have a shape, or its step would run unfenced. The
-- vocabulary lives in cosmic.build and the shapes live here, so a verb
-- added to one without the other fails now rather than silently
-- shipping an unfenced step.
local function test_every_verb_has_a_shape()
  local missing: {string} = {}
  for _, verb in ipairs(build.verbs()) do
    if driver.plan(verb, {"a", "b", "c"}) == nil then
      missing[#missing + 1] = verb
    end
  end
  assert(#missing == 0,
    "verbs with no fence shape: " .. table.concat(missing, ", "))
end
test_every_verb_has_a_shape()

local function test_copy_reads_src_and_writes_dst_parent()
  local src = touch("fence-src.txt")
  local dst = fs.join(tmpdir, "fence-out.txt")
  local p = driver.plan("copy", {src, dst})
  assert(p is sandbox.Fs, "copy must plan a policy")
  assert(has(p.ro, src), "src must be readable")
  -- The DIRECTORY, not the file: creating dst is a right on its parent,
  -- and dst does not exist yet, so a rule naming it could not be opened.
  assert(has(p.rw, tmpdir), "dst's parent must be writable")
  assert(not has(p.rw, dst), "the not-yet-existing file must not be a rule")
  assert(not has(p.rw, src), "src must NOT be writable")
end
test_copy_reads_src_and_writes_dst_parent()

local function test_missing_reads_are_dropped()
  -- A rule naming a path that cannot be opened fails the whole
  -- restrict, and a fence that fails is a fence that is not there. The
  -- verb still reports its own "cannot open" error.
  local absent = fs.join(tmpdir, "fence-absent.txt")
  local p = driver.plan("copy", {absent, fs.join(tmpdir, "o.txt")})
  assert(p is sandbox.Fs, "copy must still plan")
  assert(not has(p.ro, absent), "a missing input must not become a rule")
end
test_missing_reads_are_dropped()

local function test_compile_execs_the_bootstrap()
  local boot = touch("fence-boot")
  local src = touch("fence-a.tl")
  local p = driver.plan("compile", {boot, src, fs.join(tmpdir, "a.lua")})
  assert(p is sandbox.Fs, "compile must plan a policy")
  assert(has(p.exec, boot), "the bootstrap must be executable")
  assert(has(p.ro, src), "the source must be readable")
  assert(has(p.rw, tmpdir), "the output's parent must be writable")
  assert(not has(p.rw, src), "the source must NOT be writable")
end
test_compile_execs_the_bootstrap()

local function test_remove_takes_a_variadic_tail()
  -- unlink is a right on the parent directory, so every path in the
  -- tail contributes its parent.
  local a, b = touch("fence-rm-a"), touch("fence-rm-b")
  local p = driver.plan("remove", {a, b})
  assert(p is sandbox.Fs, "remove must plan a policy")
  assert(has(p.rw, tmpdir), "the parent must be writable to unlink")
end
test_remove_takes_a_variadic_tail()

local function test_list_does_not_read_its_items()
  -- `list <out> [items...]`: the items are text written INTO out, not
  -- paths the step opens, so granting them would widen the fence for
  -- nothing.
  local item = touch("fence-item.tl")
  local p = driver.plan("list", {fs.join(tmpdir, "files.txt"), item})
  assert(p is sandbox.Fs, "list must plan a policy")
  assert(has(p.rw, tmpdir), "the output's parent must be writable")
  assert(not has(p.ro, item), "items are content, not reads")
end
test_list_does_not_read_its_items()

local function test_exec_gets_the_subtree_not_its_argv()
  -- A foreign program's reads are not derivable from its arguments -- a
  -- compiler reads headers nobody listed -- so exec is fenced to the
  -- working tree plus the build root instead.
  local prog = touch("fence-tool")
  local p = driver.plan("exec", {prog, "--flag"})
  assert(p is sandbox.Fs, "exec must plan a policy")
  assert(has(p.exec, prog), "the program must be executable")
  assert(has(p.ro, "."), "the working tree must be readable")
  assert(not has(p.ro, "--flag"), "arguments are not paths")
end
test_exec_gets_the_subtree_not_its_argv()

local function test_an_argumentless_verb_still_plans()
  -- A malformed line still reaches the verb, which reports its own
  -- usage error; the fence must not throw on the way there.
  local p = driver.plan("copy", {})
  assert(p is sandbox.Fs, "an argument-less copy must still plan")
  assert(#p.ro == 0, "no source, no read grant")
end
test_an_argumentless_verb_still_plans()

local function test_the_running_binary_stays_executable()
  -- compile and capture re-exec cosmic; a fence that revoked that would
  -- deny the step its own driver.
  local p = driver.plan("copy", {touch("fence-x"), fs.join(tmpdir, "y")})
  assert(p is sandbox.Fs, "copy must plan a policy")
  if arg[-1] ~= nil then
    assert(has(p.exec, arg[-1]), "the running binary must stay executable")
  end
end
test_the_running_binary_stays_executable()
