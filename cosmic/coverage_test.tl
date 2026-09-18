--- The trust gate around the raw debug table cosmic.coverage wraps:
--- nobody ever gets it by naming it directly, and a load that is not
--- handed the trusted `extra` table falls through to that same failing
--- name, exactly like `cosmic.store`/`cosmic.sqlite` do today.
---
--- The tests below cover the SEPARATE gap that load-time trust check
--- does not close: this test file's own `require("cosmic.coverage")`
--- resolves trusted, exactly like `build.test`'s does -- caching means
--- it is in fact the very same module table -- so the only thing
--- standing between this file and corrupting a real, already-open
--- collection window is the session token `start`/`stop` check.

local Store = require("cosmic.store")
local Coverage = require("cosmic.coverage")

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
  -- back a working raw debug table.
  local ok = pcall(chunk, "cosmic.coverage", "not a table")
  assert(not ok, "an untrusted load must not obtain a working raw debug table")
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
