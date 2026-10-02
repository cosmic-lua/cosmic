--- The trust gate around the raw native collector cosmic.coverage
--- wraps: the collector cannot be required by name, and a load that is
--- not handed the trusted `extra` table falls through to that same
--- failing name, as [`cosmic.store`] and [`cosmic.sqlite`] do.
---
--- The load-time check does not cover this file's own
--- `require("cosmic.coverage")`. That resolves trusted, as [`build.test`]'s
--- does, and returns the same cached module table. Only the session
--- token that `start` and `stop` check stands between this file and the
--- collection window [`build.test`] has open.

local Store = require("cosmic.store")
local Coverage = require("cosmic.coverage")
local Hits = require("build.coverage_hits")

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
  -- Given anything but a table as `extra`, as an untrusted loader does,
  -- cosmic.coverage requires "cosmic.internal.debug" by name, which
  -- never resolves (test_internal_debug_not_reachable_by_name), so the
  -- module fails to load instead of returning a working collector.
  local ok = pcall(chunk, "cosmic.coverage", "not a table")
  assert(not ok, "an untrusted load must not obtain a working native collector")
end

--- The collector's other wrapper, [`build.coverage_hits`], is gated the
--- same way: an untrusted load of it fails rather than answering hits.
local function test_untrusted_load_of_the_hits_reader_cannot_reach_raw_debug()
  local bytes, trouble = Store.bytecode("build.coverage_hits")
  assert(bytes ~= nil and trouble == "", tostring(trouble))
  local chunk, load_trouble = load(bytes, "@build.coverage_hits", "b")
  assert(chunk ~= nil, tostring(load_trouble))
  local ok = pcall(chunk, "build.coverage_hits", "not a table")
  assert(not ok, "an untrusted load must not obtain a working native collector")
end

--- [`build.test`] has a collection window open around every test body,
--- this one included. A `start` from inside it must be refused, not
--- reset the window: a reset would drop the whole run's reported
--- coverage to 0.0%.
local function test_start_refused_while_a_window_is_already_open()
  local session, trouble = Coverage.start()
  assert(session == nil, "start must refuse while a real window is open")
  assert(trouble == "coverage: collection is already active", trouble)
end

--- A `stop` given anything but the session that opened the window, here
--- a fresh lookalike table, is refused and leaves the window open.
local function test_stop_with_a_foreign_session_does_not_disrupt_the_window()
  local foreign: Coverage.Session = {}
  local hits, trouble = Coverage.stop(foreign)
  assert(hits == nil, "a foreign session must not get back the real hits")
  assert(trouble == "coverage: no matching open collection for this session", trouble)
  -- The window is still open: `start` still refuses.
  local session, start_trouble = Coverage.start()
  assert(session == nil, "the genuine window must still be open, unreset")
  assert(start_trouble ~= "", "the refusal must explain why")
end

--- The native collector itself (core/coverage.c): a small known function
--- run once has the lines it executed marked hit, and a line in a branch
--- it never took not.
---
--- It runs under the window [`build.test`] has open. [`build.coverage_hits`]'s `snapshot`
--- only copies the lines hit so far, so reading it here leaves the
--- window as it was.
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

  local hits = Hits.snapshot()
  local for_file = hits["coverage_probe"]
  assert(for_file ~= nil, "the collector must attribute hits to the fixture")
  assert(for_file[2] == true, "the always-run line must be hit")
  assert(for_file[4] == true, "the taken branch's line must be hit")
  assert(for_file[6] == nil, "the untaken branch's line must not be hit")
end
