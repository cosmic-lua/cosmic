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

--- The native collector's own shape (cosmic/internal/debug.d.tl),
--- declared again here rather than imported: it is never `require`d by
--- name, only ever handed to `cosmic.coverage` itself as its trusted
--- `extra`, so this file's own use of it below (to reach the exact
--- collector `build.test`'s open window already uses -- see
--- test_native_collector_hits_executed_lines_only) needs its own
--- declared shape to cast that `extra` into.
local record NativeCoverage
  start: function()
  stop: function(): Coverage.Hits
end

local function test_internal_debug_not_reachable_by_name()
  local ok = pcall(require, "cosmic.internal.debug")
  assert(not ok, "cosmic.internal.debug must never resolve by name")
end

local function test_untrusted_load_cannot_reach_raw_debug()
  local bytes, trouble = Store.bytecode("cosmic.coverage")
  assert(bytes ~= nil, tostring(trouble))
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

--- `build.test` already has a genuine collection window open for the
--- whole run by the time any `*_test.tl` file's own tests run, this one
--- included. Calling `start` from here -- an ordinary test file, not
--- the caller that opened that window -- must be refused rather than
--- silently resetting it, which is exactly what corrupted the real run
--- before the session token existed: a single interfering test dropped
--- the whole run's reported coverage to 0.0%.
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
--- This cannot go through `Coverage.start`/`stop`: as the comment above
--- test_start_refused_while_a_window_is_already_open explains,
--- `build.test`'s own window is already open for the whole run by the
--- time this test runs, and a second `start` is refused by design.
--- Instead this reaches the exact same native collector that window
--- already uses, the way `require("cosmic.coverage")` itself would
--- have on a first load: calling `package.searchers[2]` (the store
--- searcher core/store.c installs) directly, by name. The trust check
--- it applies keys on the module being resolved and its own recorded
--- kind, never on who is asking (see the file comment above), so this
--- succeeds here exactly where the direct `require` in
--- test_internal_debug_not_reachable_by_name above does not.
---
--- Driving the real collector this way for a moment necessarily
--- discards whatever it had already collected for the rest of the run
--- (`start` always begins from empty; there is no way to read the
--- current hits without removing the hook), so this run's own reported
--- coverage undercounts by whatever ran before this test. It restarts
--- collection again immediately after reading its own result, before
--- returning, so every module that runs after this one keeps counting
--- normally and `build.test`'s own `stop` at the end of the run still
--- succeeds.
local function test_native_collector_hits_executed_lines_only()
  local _, extra = package.searchers[2]("cosmic.coverage")
  assert(type(extra) == "table", "cosmic.coverage must load trusted here")
  local native = extra as NativeCoverage

  native.start()
  local function tiny(take_branch: boolean): integer
    local total = 0
    if take_branch then
      total = total + 1
    else
      total = total - 1
    end
    return total
  end
  tiny(true)
  local hits = native.stop()
  native.start() -- re-arm before this function returns; see comment above

  local for_file = hits["cosmic.coverage_test"]
  assert(for_file ~= nil, "the collector must attribute hits to this module")
  assert(for_file[113] == true, "the always-run line must be hit")
  assert(for_file[115] == true, "the taken branch's line must be hit")
  assert(for_file[117] == nil, "the untaken branch's line must not be hit")
end
