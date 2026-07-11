#!/usr/bin/env cosmic
--- Tests for the coverage collector.
--- These run correctly both standalone and under an outer coverage run
--- (`bin/make coverage`): start/stop nest, and enable() never re-targets
--- an outer collection's dump directory.
local child = require("cosmic.child")
local coverage = require("cosmic.coverage")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local report = require("cosmic.coverage.report")
local types = require("cosmic.fs.types")

local tmpdir = os.getenv("TEST_TMPDIR") as string

--- Load a chunk under a controlled name, so hit assertions are stable.
local function load_chunk(source: string, name: string): function()
  local chunk = load(source, name)
  assert(chunk, "load failed for " .. name)
  return chunk as function()
end

--- Collect .cov file paths under a directory.
local function cov_files_in(dir: string): {string}
  local found: {string} = {}
  fs.walk(dir, function(path: string, _name: string, st: types.WalkStat, ctx: {string})
      if not st:is_dir() and path:match("%.cov$") then
        ctx[#ctx + 1] = path
      end
    end, found)
  return found
end

local function test_start_stop_counts_lines()
  local run = load_chunk("local s = 0\nfor i = 1, 3 do\n  s = s + i\nend\n",
    "@covtest_chunk.lua")
  coverage.start()
  run()
  coverage.stop()
  local snap = coverage.snapshot()
  local hits = snap["@covtest_chunk.lua"]
  assert(hits, "no hits recorded for the loaded chunk")
  local h = hits as {integer: integer}
  assert(h[1] == 1, "line 1 expected 1 hit, got " .. tostring(h[1]))
  assert(h[3] == 3, "loop body expected 3 hits, got " .. tostring(h[3]))
end
test_start_stop_counts_lines()

local function test_nested_start_keeps_collecting()
  local run = load_chunk("local a = 1\n", "@covtest_nested.lua")
  coverage.start()
  coverage.start()
  coverage.stop()
  assert(coverage.running(), "inner stop must not end the outer collection")
  run()
  coverage.stop()
  local snap = coverage.snapshot()
  assert(snap["@covtest_nested.lua"], "no hits while outer collection active")
end
test_nested_start_keeps_collecting()

local function test_coroutine_lines_counted()
  local dir = fs.join(tmpdir, "cov_co")
  local run = load_chunk("local s = 0\nfor i = 1, 2 do\n  s = s + i\nend\n",
    "@covtest_co.lua")
  -- enable() wraps coroutine.create so new threads inherit the hook
  coverage.enable(dir)
  local co = coroutine.create(run)
  local ok = coroutine.resume(co)
  coverage.stop()
  assert(ok, "coroutine failed")
  local snap = coverage.snapshot()
  local hits = snap["@covtest_co.lua"]
  assert(hits, "no hits recorded inside the coroutine")
  assert((hits as {integer: integer})[3] == 2, "coroutine loop body expected 2 hits")
end
test_coroutine_lines_counted()

local function test_dump_writes_one_stable_file()
  local dir = fs.join(tmpdir, "cov_dump")
  local run = load_chunk("local d = 1\n", "@covtest_dump.lua")
  coverage.start()
  run()
  coverage.stop()
  local ok, err = coverage.dump(dir)
  assert(ok, "dump failed: " .. (err or "?"))
  ok, err = coverage.dump(dir)
  assert(ok, "second dump failed: " .. (err or "?"))
  local names = cov_files_in(dir)
  assert(#names == 1, "expected one .cov file, got " .. #names)
  local hits, rerr = report.read_cov(names[1])
  assert(hits, "read_cov failed: " .. (rerr or "?"))
  local h = hits as {string: {integer: integer}}
  assert(h["@covtest_dump.lua"], "dumped data missing the chunk's hits")
end
test_dump_writes_one_stable_file()

local function test_dump_without_directory_fails()
  local ok, err = coverage.dump()
  -- under an outer coverage run a default directory exists; either
  -- outcome is fine as long as failure carries a message
  if not ok then
    assert(err and #err > 0, "failure must carry an error message")
  end
end
test_dump_without_directory_fails()

local function test_dir_from_env()
  local saved = env.get("COSMIC_COVERAGE")
  local cases: {string: boolean} = {
    ["0"] = false,
    ["1"] = false,
    ["true"] = false,
    ["false"] = false,
    ["o/cov.d"] = true,
  }
  for val, want_dir in pairs(cases) do
    env.set("COSMIC_COVERAGE", val)
    local got = coverage.dir_from_env()
    if want_dir then
      assert(got == val, val .. ": expected directory, got " .. tostring(got))
    else
      assert(got == nil, val .. ": expected nil, got " .. tostring(got))
    end
  end
  env.unset("COSMIC_COVERAGE")
  assert(coverage.dir_from_env() == nil, "unset: expected nil")
  if saved then
    env.set("COSMIC_COVERAGE", saved)
  end
end
test_dir_from_env()

--- End to end through the CLI gate: a child cosmic process with
--- COSMIC_COVERAGE set dumps a .cov file even when the script os.exit()s.
local function test_cli_gate_dumps_on_exit()
  local bin_dir = env.get("TEST_BIN")
  if not bin_dir then
    return -- not running under the make harness
  end
  local cosmic_bin = fs.join(bin_dir, "cosmic")
  local covdir = fs.join(tmpdir, "cov_cli")
  local script = fs.join(tmpdir, "exit_script.lua")
  assert(fs.write(script, "local x = 1\nos.exit(0)\n"))
  local child_env: {string} = {}
  for key, val in pairs(env.all()) do
    if key ~= "COSMIC_COVERAGE" then
      child_env[#child_env + 1] = key .. "=" .. val
    end
  end
  child_env[#child_env + 1] = "COSMIC_COVERAGE=" .. covdir
  local result, err = child.run({cosmic_bin, script}, {env = child_env})
  assert(result, "child failed to start: " .. (err or "?"))
  local r = result as child.Result
  assert(r.code == 0, "child exited " .. tostring(r.code) .. ": " .. r.stderr)
  local names = cov_files_in(covdir)
  assert(#names == 1, "expected one .cov file from the child, got " .. #names)
  local hits, rerr = report.read_cov(names[1])
  assert(hits, "read_cov failed: " .. (rerr or "?"))
  local h = hits as {string: {integer: integer}}
  local script_hits = h["@" .. script]
  assert(script_hits, "child did not record the script's lines")
  assert((script_hits as {integer: integer})[1], "script line 1 not hit")
end
test_cli_gate_dumps_on_exit()

--- Sealing is irreversible for the process, so this stays the last test.
local function test_seal_blocks_later_dumps()
  coverage.seal()
  local ok, err = coverage.dump(fs.join(tmpdir, "cov_sealed"))
  assert(not ok, "dump after seal must fail")
  assert(err and err:find("sealed"), "error should mention sealing: " .. tostring(err))
end
test_seal_blocks_later_dumps()
