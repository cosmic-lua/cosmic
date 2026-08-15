#!/usr/bin/env cosmic
-- Tests for the compile-batch step: per-member skips byte-compatible
-- with the per-file path, all-errors failure semantics, the fail-fast
-- switch, and the closed flag vocabulary.

local batch = require("_cli.build.batch")
local cenv = require("cosmic.env")
local check = require("cosmic.check")
local fs = require("cosmic.fs")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- The seconds+nanoseconds of a path, as one comparable string.
local function mtime_of(path: string): string
  local mt = check.must(fs.stat(path)):modify_time()
  return tostring(mt.secs) .. "." .. tostring(mt.nsecs)
end

--- Lay out a group of sources plus the facts file the verb reads, and
--- return the argv prefix for a batch over them.
--- @param name string A directory name unique to the calling test
--- @param sources {string: string} Source bodies by bare name (no .tl)
--- @return {string} The verb argv
--- @return string The group's output directory
local function batch_args(name: string, sources: {string: string}): {string}, string
  local root = fs.join(tmpdir, name)
  local srcdir = fs.join(root, "grp")
  local outdir = fs.join(root, "o/grp")
  assert(fs.make_dirs(srcdir))
  local facts = fs.join(root, "project.mk")
  local facts_lines: {string} = {}
  local args: {string} = {"cosmic-unused", fs.join(root, "o/.groups/grp.compiled"),
    outdir, "--facts", facts, "--srcs"}
  local names: {string} = {}
  for bare in pairs(sources) do
    names[#names + 1] = bare
  end
  table.sort(names)
  for _, bare in ipairs(names) do
    local src = fs.join(srcdir, bare .. ".tl")
    assert(fs.write(src, sources[bare]))
    facts_lines[#facts_lines + 1] =
    "srcdeps_" .. fs.join(srcdir, bare) .. " := "
    args[#args + 1] = src
  end
  assert(fs.write(facts, table.concat(facts_lines, "\n") .. "\n"))
  return args, outdir
end

local GOOD_A = "return { a = 1 }\n"
local GOOD_B = "return { b = 2 }\n"
local BAD = "local n: number = \"not a number\"\nreturn { n = n }\n"

local function test_batch_compiles_skips_and_restamps()
  local args, outdir = batch_args("batch-ok", {a = GOOD_A, b = GOOD_B})
  assert(batch.compile_batch(args) == 0, "first batch")
  local out_a = fs.join(outdir, "a.lua")
  assert(fs.is_file(out_a), "member output written")
  assert(fs.is_file(out_a .. ".in"), "member record written")
  local stamp = args[2]
  assert(fs.is_file(stamp), "group stamp written")
  local body = check.must(fs.read(stamp))
  assert(body:find("compiled 2 skipped 0 of 2", 1, true), "counts: " .. body)

  local key1 = mtime_of(out_a .. ".in")
  local out1 = mtime_of(out_a)
  assert(batch.compile_batch(args) == 0, "second batch")
  assert(mtime_of(out_a .. ".in") == key1,
    "identical inputs must skip: the record must not be rewritten")
  assert(mtime_of(out_a) ~= out1, "and the member must be restamped for make")
  local body2 = check.must(fs.read(stamp))
  assert(body2:find("compiled 0 skipped 2 of 2", 1, true),
    "second run skips both: " .. body2)
end
test_batch_compiles_skips_and_restamps()

local function test_batch_reports_all_failures_and_writes_no_stamp()
  local args, outdir = batch_args("batch-bad", {aa = GOOD_A, bad = BAD, zz = GOOD_B})
  assert(batch.compile_batch(args) ~= 0, "a broken member fails the batch")
  assert(not fs.is_present(args[2]), "no stamp on failure")
  assert(fs.is_file(fs.join(outdir, "aa.lua")),
    "members before the failure keep their outputs")
  assert(fs.is_file(fs.join(outdir, "zz.lua")),
    "members after the failure are still attempted")
  assert(not fs.is_present(fs.join(outdir, "bad.lua")),
    "the broken member writes nothing")
end
test_batch_reports_all_failures_and_writes_no_stamp()

local function test_fail_fast_stops_at_the_first_failure()
  local args, outdir = batch_args("batch-ff", {aa = BAD, zz = GOOD_B})
  local _ok, _err = cenv.set("COSMIC_FAIL_FAST", "1")
  local code = batch.compile_batch(args)
  local _ok2, _err2 = cenv.unset("COSMIC_FAIL_FAST")
  assert(code ~= 0, "fail-fast still fails the batch")
  assert(not fs.is_present(fs.join(outdir, "zz.lua")),
    "members after the first failure are not attempted")
end
test_fail_fast_stops_at_the_first_failure()

local function test_batch_refuses_unknown_flags_and_bad_usage()
  local args = batch_args("batch-flags", {a = GOOD_A})
  table.insert(args, 4, "--mystery")
  assert(batch.compile_batch(args) ~= 0, "unknown flags are refused")
  assert(batch.compile_batch({"cosmic-unused", "stamp"}) ~= 0, "usage errors fail")
  local no_srcs, _ = batch_args("batch-nosrcs", {})
  assert(batch.compile_batch(no_srcs) ~= 0, "an empty member list is refused")
end
test_batch_refuses_unknown_flags_and_bad_usage()
