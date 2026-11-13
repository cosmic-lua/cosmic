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

local Globals = require("cosmic.internal.globals")
local Store = require("cosmic.store")
local Coverage = require("cosmic.coverage")
local Hits = require("build.coverage_hits")
local Test = require("cosmic.test")

local function test_internal_debug_not_reachable_by_name()
  Test.raises(function() require("cosmic.internal.debug") end)
end

local function test_untrusted_load_cannot_reach_raw_debug()
  local bytes, trouble = Store.bytecode("cosmic.coverage")
  assert(bytes ~= nil and trouble == "", tostring(trouble))
  local chunk, load_trouble = load(bytes, "@cosmic.coverage", "b", Globals.table())
  assert(chunk ~= nil, tostring(load_trouble))
  -- Given anything but a table as `extra`, as an untrusted loader does,
  -- cosmic.coverage requires "cosmic.internal.debug" by name, which
  -- never resolves (test_internal_debug_not_reachable_by_name), so the
  -- module fails to load instead of returning a working collector.
  Test.raises(function() chunk("cosmic.coverage", "not a table") end)
end

--- The collector's other wrapper, [`build.coverage_hits`], is gated the
--- same way: an untrusted load of it fails rather than answering hits.
local function test_untrusted_load_of_the_hits_reader_cannot_reach_raw_debug()
  local bytes, trouble = Store.bytecode("build.coverage_hits")
  assert(bytes ~= nil and trouble == "", tostring(trouble))
  local chunk, load_trouble = load(bytes, "@build.coverage_hits", "b", Globals.table())
  assert(chunk ~= nil, tostring(load_trouble))
  Test.raises(function() chunk("build.coverage_hits", "not a table") end)
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

--- The lines the collector holds hit of the chunk named `name`.
local function hit_of(name: string): {integer:boolean}
  local lines = assert(Hits.snapshot()[name], "the collector holds no line of " .. name)
  return lines
end

--- A line a loop first reaches on a later turn is marked with its source and its page held already, where the core
--- marks a line without calling the line hook; a line no turn reaches stays unmarked, and so does one after the loop.
local function test_a_line_first_reached_on_a_later_turn_of_a_loop_is_hit()
  local source = table.concat({
    "local total = 0", -- 1
    "for turn = 1, 3 do", -- 2
    "  if turn == 3 then", -- 3
    "    total = total + turn", -- 4: on the last turn alone
    "  end", -- 5
    "end", -- 6
    "if total == 0 then", -- 7
    "  total = -1", -- 8: never
    "end", -- 9
    "return total", -- 10
  }, "\n")
  local loop = assert(load(source, "@coverage_loop_probe", "t", {}))
  assert(loop() == 3)
  local hit = hit_of("coverage_loop_probe")
  for _, line in ipairs({ 1, 2, 3, 4, 7, 10 }) do
    assert(hit[line] == true, "line " .. tostring(line) .. " ran and is not hit")
  end
  assert(hit[8] == nil, "a line that never ran is hit")
end

--- Lines whose source and page the collector holds are marked with no call of the line hook, whatever the number of
--- times they run and jump back: the hook, which Lua calls through a save and a restore of the state's stack, is for
--- a line that needs a source or a page made.
local function test_lines_the_collector_holds_are_marked_without_the_line_hook()
  local source = table.concat({
    "local total = 0", -- 1
    "for turn = 1, 1000 do", -- 2
    "  if turn % 2 == 0 then", -- 3
    "    total = total + turn", -- 4
    "  end", -- 5
    "end", -- 6
    "return total", -- 7
  }, "\n")
  local loop = assert(load(source, "@coverage_held_probe", "t", {}))
  -- Once for the hook to make the source and its page, and the count read once so that reading it runs no new line.
  assert(loop() == 250500 and Hits.line_hook_calls() > 0)
  local before = Hits.line_hook_calls()
  local total = loop()
  local calls = Hits.line_hook_calls() - before
  assert(total == 250500 and calls == 0, "the line hook was called " .. tostring(calls) .. " times for lines held")
  local hit = hit_of("coverage_held_probe")
  assert(hit[1] == true and hit[4] == true and hit[7] == true and hit[5] == nil)
end

--- A line on a page of the bitmap the collector does not hold yet (core/coverage.c keeps 4096 lines a page) is one
--- only the line hook can mark, since it must allocate; the lines after it on that page need the hook no more.
local function test_a_line_on_a_page_not_yet_held_is_hit()
  local source = "local total = 1\n" .. string.rep("\n", 5000) .. "total = total + 1\nreturn total\n"
  local far = assert(load(source, "@coverage_page_probe", "t", {}))
  assert(far() == 2)
  local hit = hit_of("coverage_page_probe")
  assert(hit[1] == true, "the first page's line is not hit")
  assert(hit[5002] == true, "the first line reached on a page not yet held is not hit")
  assert(hit[5003] == true, "the line after it is not hit")
  assert(hit[2] == nil and hit[5001] == nil, "a blank line is hit")
end

--- A coroutine's lines are hit on both sides of a yield, with another chunk's lines run between its resumes: each
--- thread keeps its own place, and the collector's last source is the other chunk's when the coroutine goes on.
local function test_lines_are_hit_on_both_sides_of_a_yield()
  local source = table.concat({
    "local yield = ...", -- 1
    "local seen = 0", -- 2
    "yield(seen)", -- 3
    "seen = seen + 1", -- 4
    "yield(seen)", -- 5
    "if seen == 0 then", -- 6
    "  seen = -1", -- 7: never
    "end", -- 8
    "return seen + 1", -- 9
  }, "\n")
  local between = assert(load("local turn = ...\nlocal next_turn = turn + 1\nreturn next_turn\n",
    "@coverage_resumer_probe", "t", {}))
  local body = assert(load(source, "@coverage_yield_probe", "t", {}))
  -- Lua's own yield, which the chunk is handed: a typed body yields through a handle the checker alone knows.
  local yield = assert(load("return coroutine.yield", "=coverage_yield_library", "t"))()
  local thread = coroutine.create(function(): any
    return body(yield)
  end)
  local _, first = coroutine.resume(thread)
  assert(first == 0 and between(1) == 2)
  local _, second = coroutine.resume(thread)
  assert(second == 1 and between(2) == 3)
  local _, last = coroutine.resume(thread)
  assert(last == 2 and coroutine.status(thread) == "dead")
  local hit = hit_of("coverage_yield_probe")
  for _, line in ipairs({ 1, 2, 3, 4, 5, 6, 9 }) do
    assert(hit[line] == true, "line " .. tostring(line) .. " ran and is not hit")
  end
  assert(hit[7] == nil, "a line that never ran is hit")
  local resumer = hit_of("coverage_resumer_probe")
  assert(resumer[1] == true and resumer[2] == true and resumer[3] == true, "the resumer's lines are not hit")
end
