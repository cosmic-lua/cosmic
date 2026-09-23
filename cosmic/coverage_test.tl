--- The trust gate around the raw native collector cosmic.coverage
--- wraps: nobody ever gets it by naming it directly, and a load that is
--- not handed the trusted `extra` table falls through to that same
--- failing name, exactly like `cosmic.store`/`cosmic.sqlite` do today.
---
--- The tests below cover the SEPARATE gap that load-time trust check
--- does not close: this test file's own `require("cosmic.coverage")`
--- resolves trusted, exactly like `build.test`'s does -- caching means
--- it is in fact the very same module table -- so the only thing
--- standing between this file and corrupting a real, already-open
--- collection window is the session token `start`/`stop` check.

local Store = require("cosmic.store")
local Coverage = require("cosmic.coverage")
local sys = require("cosmic.sys")

local function test_internal_debug_not_reachable_by_name()
  local ok = pcall(require, "cosmic.internal.debug")
  assert(not ok, "cosmic.internal.debug must never resolve by name")
end

local function test_untrusted_load_cannot_reach_raw_debug()
  local bytes, trouble = Store.bytecode("cosmic.coverage")
  assert(bytes ~= nil and trouble == "", tostring(trouble))
  local source, source_trouble = Store.source("cosmic.coverage")
  assert(source ~= nil and source_trouble == "", tostring(source_trouble))
  local chunk, load_trouble = load(bytes, "@cosmic.coverage", "b")
  assert(chunk ~= nil, tostring(load_trouble))
  -- Called the way an untrusted loader hands a module its `extra`
  -- argument -- anything but a table -- cosmic.coverage must fall
  -- through to `require("cosmic.internal.debug")` by name, which
  -- never resolves (see test_internal_debug_not_reachable_by_name
  -- above), so the module itself fails to load rather than handing
  -- back a working native collector.
  local ok = pcall(chunk, "cosmic.coverage", "not a table")
  assert(not ok, "an untrusted load must not obtain a working native collector")
end

--- `build.test` already has a genuine collection window open around
--- this exact test's own execution by the time its body runs, this one
--- included. Calling `start` again from in here -- during a window
--- that same caller already opened, not a second caller -- must be
--- refused rather than silently resetting it, which is exactly what
--- corrupted the real run before the session token existed: a single
--- interfering test dropped the whole run's reported coverage to 0.0%.
local function test_start_refused_while_a_window_is_already_open()
  local session, trouble = Coverage.start()
  assert(session == nil, "start must refuse while a real window is open")
  assert(trouble ~= "", "the refusal must explain why")
end

--- Symmetric proof for `stop`: a caller holding anything other than the
--- exact session the open window's own `start` returned -- here, a
--- freshly made lookalike table, standing in for "no argument at all"
--- the way the reproduced defect called it -- must be refused without
--- ending or discarding the real collection.
local function test_stop_with_a_foreign_session_does_not_disrupt_the_window()
  local foreign: Coverage.Session = {}
  local hits, trouble = Coverage.stop(foreign)
  assert(hits == nil, "a foreign session must not get back the real hits")
  assert(trouble ~= "", "the refusal must explain why")
  -- The real window is still open and untouched: start still refuses,
  -- exactly as it did above, rather than succeeding because the
  -- foreign stop() call above tore the window down.
  local session, start_trouble = Coverage.start()
  assert(session == nil, "the genuine window must still be open, unreset")
  assert(start_trouble ~= "", "the refusal must explain why")
end

--- A real correctness check on the native collector itself
--- (core/coverage.c), not just the gate around it: run a small, known
--- function once and confirm the lines it actually executed are
--- marked hit, and a line inside a branch it never took is not.
---
--- This runs the probe function directly, under the real window
--- `build.test` already has open around this test's own execution (the
--- same window test_start_refused_while_a_window_is_already_open and
--- test_stop_with_a_foreign_session_does_not_disrupt_the_window rely
--- on being open) -- no isolation needed, since `Coverage.snapshot`
--- only reads: it returns a copy of every line hit so far in this
--- window, without touching the hook or the collection at all. That is
--- exactly what makes checking specific (file, line) pairs in it safe
--- here: unlike `start`/`stop`, nothing is reset, removed, or handed to
--- a caller that does not hold the session.
local function test_native_collector_hits_executed_lines_only()
  -- Fixture-relative lines stay stable when this test file changes.
  local source = table.concat({
    "local take_branch = ...", -- 1
    "local total = 0", -- 2: always executed
    "if take_branch then", -- 3
    "  total = total + 1", -- 4: taken
    "else", -- 5
    "  total = total - 1", -- 6: untaken
    "end", -- 7
    "return total", -- 8
  }, "\n")
  local tiny, trouble = load(source, "@coverage_probe", "t")
  assert(tiny ~= nil, tostring(trouble))
  assert(tiny(true) == 1)

  local hits = Coverage.snapshot()
  local for_file = hits["coverage_probe"]
  assert(for_file ~= nil, "the collector must attribute hits to the fixture")
  assert(for_file[2] == true, "the always-run line must be hit")
  assert(for_file[4] == true, "the taken branch's line must be hit")
  assert(for_file[6] == nil, "the untaken branch's line must not be hit")
end

--- The worker watches every C entry point through the window it opens
--- around this test, so a C function this test calls is among the hits
--- a snapshot reads back, under the path `called_path` names, and one
--- it never calls is not.
local function test_a_watched_c_function_called_is_among_the_hits()
  sys.getpid()
  local hits = Coverage.snapshot()
  local called = hits[Coverage.called_path("sys.getpid")]
  assert(called ~= nil and called[Coverage.called_line] == true,
    "a watched C function this test called must be recorded")
  assert(hits[Coverage.called_path("sys.exit")] == nil,
    "one it never called must not be")
end

local function test_a_called_path_is_never_a_module_path()
  local path = Coverage.called_path("sys.open")
  assert(Coverage.called_name(path) == "sys.open")
  assert(path:sub(1, 1) == "=", "Lua's own mark for a chunk name that is not a file")
  assert(Coverage.called_name("cosmic.coverage") == nil)
  assert(Coverage.called_name("coverage_probe") == nil)
end
