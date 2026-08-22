#!/usr/bin/env cosmic
-- What `show` prints for one item, whole and narrowed. The output is
-- what a session reads to decide, so the words are the contract —
-- asserted here on the pure reports the `cmd_show` wrapper prints.
--
-- The narrowed reads exist because a ready-bar spec is long by
-- design: `--spec` is the sidecar alone, `--section` one of its
-- sections, `--fields` the record with neither prose block. Each is
-- checked for what it prints AND for what it leaves out, since
-- leaving things out is the whole point.

local check = require("cosmic.check")
local item = require("_work.item")
local ksuid = require("_work.ksuid")
local show = require("_work.gitshow")
local store = require("_work.store")

local seq = 0

--- A deterministic id; later calls sort later.
local function next_id(): string
  seq = seq + 1
  return check.must(ksuid.encode(1700000000 + seq, ("\0"):rep(16)))
end

local ROOT < const > = next_id()
local UNDER < const > = next_id()
local WORK < const > = next_id()
local ADRIFT < const > = next_id()
local BEATEN < const > = next_id()

--- A spec sidecar with two sections, the second ending at a thematic
--- break so a narrowed read has a boundary to respect.
local SIDECAR < const > = table.concat({
    "## Goal", "serves G8", "",
    "## Acceptance", "- `bin/cosmic --make ci` ends `ci: PASS`", "",
    "---", "a footer below the break", "",
  }, "\n")

--- Whether any line matches a Lua pattern.
local function matched(lines: {string}, pattern: string): boolean
  for _, line in ipairs(lines) do
    if line:match(pattern) then
      return true
    end
  end
  return false
end

--- A placed root (it outranks BEATEN, which is what gives everything
--- beneath it a position), a container under it holding one claimed
--- item in `do`, and a leaf left with no phase.
local function a_board(): {item.Item}
  return {
    check.must(item.decode({id = ROOT, title = "an outcome", beats = BEATEN})),
    check.must(item.decode({id = UNDER, title = "a container", parent = ROOT})),
    check.must(item.decode({id = WORK, title = "a slice", parent = UNDER,
          phase = "do", claim = "session-a", pr = 42})),
    check.must(item.decode({id = ADRIFT, title = "off the board",
          parent = ROOT})),
    check.must(item.decode({id = BEATEN, title = "a lesser outcome"})),
  }
end

local function test_show_prints_fields_role_and_history()
  local all = a_board()
  local events: {store.Event} = {
    {sha = "abc1234", at = "2026-08-17T00:00:00Z", subject = "move it"},
  }
  local lines, verdict = show.show_report(all[3], all, "## Goal\nserves G1\n",
    events)
  assert(matched(lines, "^role: work$"), table.concat(lines, "\n"))
  assert(matched(lines, "^phase: do$"), "its phase")
  assert(matched(lines, "^pr: #42$"), "its PR")
  assert(matched(lines, "^%-%-%- spec %-%-%-$"), "the sidecar is the spec")
  assert(matched(lines, "abc1234 move it"), "git log IS the item's history")
  assert(verdict == WORK:sub(1, 8) .. " is do", verdict)
end
test_show_prints_fields_role_and_history()

local function test_show_names_an_items_own_graph_problem()
  local all = a_board()
  local lines, verdict = show.show_report(all[4], all, "", {})
  assert(matched(lines, "graph: .* no phase"),
    "an item off the board says so where it is read: "
    .. table.concat(lines, "\n"))
  assert(verdict:find("is open", 1, true), verdict)
end
test_show_names_an_items_own_graph_problem()

-- `blocked by` means what `flow.is_blocked` means: an edge whose
-- blocker has ended does not hold the item up, and printing it beside
-- the ones that do reads as a chain far deeper than it is. The closed
-- edges stay visible under their own heading — they are the record of
-- what the item waited on — and an item every blocker of which has
-- ended prints no `blocked by` line at all.
local function test_show_separates_binding_blockers_from_cleared_ones()
  local all = a_board()
  local open_blocker = next_id()
  local ended_blocker = next_id()
  all[#all + 1] = check.must(item.decode({id = open_blocker,
        title = "still open", parent = UNDER, phase = "plan"}))
  all[#all + 1] = check.must(item.decode({id = ended_blocker,
        title = "landed already", parent = UNDER, resolution = "completed"}))
  local waiting = check.must(item.decode({id = next_id(),
        title = "waits on one of them", parent = UNDER, phase = "plan",
        blocked_by = open_blocker .. " " .. ended_blocker}))
  all[#all + 1] = waiting
  local lines = show.show_report(waiting, all, "", {})
  assert(matched(lines, "^blocked by: " .. open_blocker .. "$"),
    "only the open blocker binds: " .. table.concat(lines, "\n"))
  assert(matched(lines, "^blockers cleared: " .. ended_blocker .. "$"),
    "the ended edge is still the record: " .. table.concat(lines, "\n"))

  local settled = check.must(item.decode({id = next_id(),
        title = "waits on nothing open", parent = UNDER, phase = "plan",
        blocked_by = ended_blocker}))
  all[#all + 1] = settled
  local settled_lines = show.show_report(settled, all, "", {})
  assert(not matched(settled_lines, "^blocked by:"),
    "nothing open holds it up: " .. table.concat(settled_lines, "\n"))
  assert(matched(settled_lines, "^blockers cleared: " .. ended_blocker .. "$"),
    "and the edge is still shown: " .. table.concat(settled_lines, "\n"))
end
test_show_separates_binding_blockers_from_cleared_ones()

-- `--fields` answers what phase, whose claim, which PR — questions the
-- RECORD answers — so it drops the two prose blocks and keeps
-- everything else, graph problems included. Asserting only that the
-- fields survive would pass on a report that dropped nothing.
local function test_fields_keeps_the_record_and_drops_both_prose_blocks()
  local all = a_board()
  local events: {store.Event} = {
    {sha = "def5678", at = "2026-08-18T00:00:00Z", subject = "claim it"},
  }
  local lines, verdict = show.show_report(all[3], all, SIDECAR, events, "fields")
  assert(matched(lines, "^phase: do$"), table.concat(lines, "\n"))
  assert(matched(lines, "^claim: session%-a$"), "the claim is a field")
  assert(not matched(lines, "^%-%-%- spec %-%-%-$"),
    "the sidecar is prose: " .. table.concat(lines, "\n"))
  assert(not matched(lines, "def5678"),
    "so is the history: " .. table.concat(lines, "\n"))
  assert(verdict == WORK:sub(1, 8) .. " is do", verdict)
end
test_fields_keeps_the_record_and_drops_both_prose_blocks()

-- The sidecar verbatim, and one section of it. A section read stops at
-- the next heading and at a thematic break, because that is where
-- `_work.spec`'s grammar says a section ends.
local function test_spec_lines_narrows_to_the_body_or_one_section()
  local all = a_board()
  local whole = check.must(show.spec_lines(all[3], SIDECAR, ""))
  assert(whole[1] == "## Goal", table.concat(whole, "\n"))
  assert(matched(whole, "^## Acceptance$"), "the whole body is the whole body")

  local one = check.must(show.spec_lines(all[3], SIDECAR, "Acceptance"))
  assert(one[1] == "## Acceptance", table.concat(one, "\n"))
  assert(not matched(one, "^## Goal$"),
    "one section only: " .. table.concat(one, "\n"))
  assert(not matched(one, "a footer below the break"),
    "the break ends it: " .. table.concat(one, "\n"))

  local lower = check.must(show.spec_lines(all[3], SIDECAR, "acceptance"))
  assert(lower[1] == "## Acceptance", "headings match case-insensitively")
end
test_spec_lines_narrows_to_the_body_or_one_section()

-- No sidecar and no such section are different answers, so they carry
-- different messages: one says the item has no spec, the other that
-- the spec it has does not go by that name.
local function test_spec_lines_tells_no_spec_from_no_such_section()
  local all = a_board()
  local none, why = show.spec_lines(all[3], "", "")
  assert(none == nil, "an item with no sidecar has nothing to print")
  assert(why == WORK:sub(1, 8) .. " has no spec", why)

  local absent, absent_why = show.spec_lines(all[3], SIDECAR, "Nonesuch")
  assert(absent == nil, "a section the body lacks has nothing to print")
  assert(absent_why == WORK:sub(1, 8) .. " spec has no section: Nonesuch",
    absent_why)
end
test_spec_lines_tells_no_spec_from_no_such_section()

-- Two narrowing flags name no single read, so `cmd_show` refuses
-- rather than letting a precedence rule pick silently — the failure
-- mode the flags exist to remove is a session not knowing which read
-- it got.
local function test_two_narrowing_flags_are_refused()
  local s = check.must(store.open("."))
  local code = show.cmd_show(s, ROOT, "spec+fields", "")
  assert(code ~= 0, "a read naming two narrowings is refused")
end
test_two_narrowing_flags_are_refused()
