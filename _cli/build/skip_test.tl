#!/usr/bin/env cosmic
-- Tests for _cli.build.work's content-keyed skip.
--
-- `.in` is written plainly on every REAL run, so its mtime is the
-- probe these tests read: it moves exactly when the step spawned a
-- child, and holds exactly when the skip stood in. The output's mtime
-- moves either way -- that is the restamp make schedules on.

local check = require("cosmic.check")
local cenv = require("cosmic.env")
local fs = require("cosmic.fs")
local work = require("_cli.build.work")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"
local cosmic = fs.absolute_path(fs.join(os.getenv("TEST_BIN") or "o/bin", "cosmic"))

-- The record skip keys the tool stamp the graph writes; without a
-- built tree there is nothing to key against and nothing to test.
check.needs("a built cosmic at " .. cosmic, fs.is_file(cosmic))
check.needs("the record stamp at o/.stamp/record",
  fs.is_file("o/.stamp/record"))

--- The seconds+nanoseconds of a path, as one comparable string.
local function mtime_of(path: string): string
  local mt = check.must(fs.stat(path)):modify_time()
  return tostring(mt.secs) .. "." .. tostring(mt.nsecs)
end

-- compile: a second run with identical bytes skips (no child, `.in`
-- untouched, output restamped); a corrupted output or changed source
-- runs for real (`.in` rewritten); a line with no --deps never keys.
local function test_compile_skips_and_unskips()
  local src = fs.join(tmpdir, "skip-src.tl")
  local out = fs.join(tmpdir, "skip-out.lua")
  assert(fs.write(src, "return { n = 1 }\n"))
  local args = {cosmic, src, out, "--deps"}
  assert(work.compile(args) == 0, "first compile")
  assert(fs.is_file(out .. ".in"), "a keyed compile records itself")
  local key1 = mtime_of(out .. ".in")
  local out1 = mtime_of(out)

  assert(work.compile(args) == 0, "second compile")
  assert(mtime_of(out .. ".in") == key1,
    "identical inputs must SKIP: the record must not be rewritten")
  assert(mtime_of(out) ~= out1,
    "and the output must be restamped for make")

  assert(fs.write(out, "-- corrupted\n"))
  assert(work.compile(args) == 0, "recompile over a corrupted output")
  assert(mtime_of(out .. ".in") ~= key1,
    "an output that does not match its record must be rebuilt")
  local body = check.must(fs.read(out))
  assert(not body:find("corrupted", 1, true), "and really rebuilt")

  local key2 = mtime_of(out .. ".in")
  assert(fs.write(src, "return { n = 2 }\n"))
  assert(work.compile(args) == 0, "recompile after a source edit")
  assert(mtime_of(out .. ".in") ~= key2,
    "changed source bytes must miss the key")

  local bare_out = fs.join(tmpdir, "skip-bare.lua")
  assert(work.compile({cosmic, src, bare_out}) == 0, "bare compile")
  assert(not fs.is_present(bare_out .. ".in"),
    "a line that declares no inputs must not key: the mini-graph " ..
    "expects a dispatched compile to compile")
end
test_compile_skips_and_unskips()

-- record: only a recorded PASS stands in. A pass skips the second run;
-- a failure drops the record and runs every time; a behavior switch in
-- the environment is part of the key.
local function test_record_skips_only_a_pass()
  local target = fs.join(tmpdir, "skip-pass.lua")
  assert(fs.write(target, "print('ok')\n"))
  local out = fs.join(tmpdir, "skip-pass-result.test")
  local args = {out, cosmic, target, "--deps"}
  assert(work.record(args) == 0, "first record")
  local got = check.must(fs.read(out .. ".got"))
  assert(got:match("^0%s*$"), "the run passed; err: "
    .. tostring((fs.read(out .. ".err"))))
  assert(fs.is_file(out .. ".in"), "a pass records itself")
  local key1 = mtime_of(out .. ".in")
  local ran1 = mtime_of(out .. ".out")

  assert(work.record(args) == 0, "second record")
  assert(mtime_of(out .. ".in") == key1 and mtime_of(out .. ".out") == ran1,
    "identical inputs and a recorded pass must SKIP the child")

  local saved = cenv.get("COSMIC_FIXPOINT")
  assert(cenv.set("COSMIC_FIXPOINT", "1"))
  assert(work.record(args) == 0, "record under a flipped switch")
  if saved == nil then
    assert(cenv.unset("COSMIC_FIXPOINT"))
  else
    assert(cenv.set("COSMIC_FIXPOINT", saved))
  end
  assert(mtime_of(out .. ".in") ~= key1,
    "a behavior switch is part of the key, so the child must re-run")

  local bad = fs.join(tmpdir, "skip-fail.lua")
  assert(fs.write(bad, "error('boom')\n"))
  local bout = fs.join(tmpdir, "skip-fail-result.test")
  local bargs = {bout, cosmic, bad, "--deps"}
  assert(work.record(bargs) == 0, "record always exits 0; grading is later")
  local bgot = check.must(fs.read(bout .. ".got"))
  assert(not bgot:match("^0%s*$"), "the run failed")
  assert(not fs.is_present(bout .. ".in"),
    "a failure must not record: a red test deserves its re-run")
  local err1 = mtime_of(bout .. ".err")
  assert(work.record(bargs) == 0, "second failing record")
  assert(mtime_of(bout .. ".err") ~= err1,
    "and it really re-ran rather than standing on the old result")
end
test_record_skips_only_a_pass()

print("all skip tests passed")
