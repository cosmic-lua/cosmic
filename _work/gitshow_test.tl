#!/usr/bin/env cosmic
-- What `show` prints for one item. The output is what a session reads
-- to decide, so the words are the contract — asserted here on the pure
-- report the `cmd_show` wrapper prints: fields, derived state, the
-- take gate's problem list, the sidecar, the git history.

local check = require("cosmic.check")
local alias = require("_work.alias")
local item = require("_work.item")
local ksuid = require("_work.ksuid")
local show = require("_work.gitshow")
local spec = require("_work.spec")
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

--- A spec sidecar whose last section ends at a thematic break.
local SIDECAR < const > = table.concat({
    "## Change", "add the verb", "",
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
--- build, and a fresh todo leaf.
local function a_board(): {item.Item}
  return {
    check.must(item.decode({id = ROOT, title = "an outcome", beats = BEATEN})),
    check.must(item.decode({id = UNDER, title = "a container", parent = ROOT})),
    check.must(item.decode({id = WORK, title = "a slice", parent = UNDER,
          claim = "session-a", pr = 42})),
    check.must(item.decode({id = ADRIFT, title = "a fresh leaf",
          parent = ROOT})),
    check.must(item.decode({id = BEATEN, title = "a lesser outcome"})),
  }
end

local function test_show_prints_fields_role_and_history()
  local all = a_board()
  local events: {store.Event} = {
    {sha = "abc1234", at = "2026-08-17T00:00:00Z", subject = "move it"},
  }
  local lines, verdict = show.show_report(all[3], all, "## Change\ndo it\n",
    events, {})
  assert(lines[1] == alias.of(WORK) .. " a slice ["
    .. alias.chunk(WORK:sub(1, 8)) .. "]",
    "the header carries the alias and the chunked id: " .. lines[1])
  assert(matched(lines, "^role: work$"), table.concat(lines, "\n"))
  assert(matched(lines, "^state: review$"), "its state")
  assert(matched(lines, "^pr: #42$"), "its PR")
  assert(matched(lines, "^%-%-%- spec %-%-%-$"), "the sidecar is the spec")
  assert(matched(lines, "abc1234 move it"), "git log IS the item's history")
  assert(verdict == WORK:sub(1, 8) .. " is review", verdict)
end
test_show_prints_fields_role_and_history()

-- The take gate's problem list renders on the read that precedes the
-- pull, one `bar:` line each — `show` absorbed the old `check` verb,
-- so what would refuse a take is nobody's surprise.
local function test_show_prints_the_take_gates_problems()
  local all = a_board()
  local problems = {"spec: Change is missing or empty",
    "it has no position in the priority order"}
  local lines = show.show_report(all[4], all, "", {}, problems)
  assert(matched(lines, "^bar: spec: Change is missing or empty$"),
    table.concat(lines, "\n"))
  assert(matched(lines, "^bar: it has no position"), "every problem prints")
  local clean = show.show_report(all[4], all, "", {}, {})
  assert(not matched(clean, "^bar:"), "no problems, no bar lines")
end
test_show_prints_the_take_gates_problems()

local function test_show_prints_the_reviewer_lock()
  local all = a_board()
  local under_review = check.must(item.decode({id = WORK, title = "a slice",
        parent = UNDER, claim = "session-a", pr = 42,
        reviewer = "reviewer-b"}))
  local lines = show.show_report(under_review, all, "", {}, {})
  assert(matched(lines, "^reviewer: reviewer%-b$"),
    "the review lock is a fact worth reading: " .. table.concat(lines, "\n"))
end
test_show_prints_the_reviewer_lock()

local function test_show_names_an_items_own_graph_problem()
  local all = a_board()
  local adrift = all[4]
  adrift.parent = next_id()
  local index_problems = {("parent %s does not exist"):format(adrift.parent)}
  local lines, verdict = show.show_report(adrift, all, "", {}, index_problems)
  assert(matched(lines, "bar: parent .* does not exist"),
    "a broken chain says so where it is read: "
    .. table.concat(lines, "\n"))
  assert(verdict:find("is todo", 1, true), verdict)
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
        title = "still open", parent = UNDER}))
  all[#all + 1] = check.must(item.decode({id = ended_blocker,
        title = "landed already", parent = UNDER, resolution = "completed"}))
  local waiting = check.must(item.decode({id = next_id(),
        title = "waits on one of them", parent = UNDER,
        blocked_by = open_blocker .. " " .. ended_blocker}))
  all[#all + 1] = waiting
  local lines = show.show_report(waiting, all, "", {}, {})
  assert(matched(lines, "^blocked by: " .. open_blocker .. "$"),
    "only the open blocker binds: " .. table.concat(lines, "\n"))
  assert(matched(lines, "^blockers cleared: " .. ended_blocker .. "$"),
    "the ended edge is still the record: " .. table.concat(lines, "\n"))

  local settled = check.must(item.decode({id = next_id(),
        title = "waits on nothing open", parent = UNDER,
        blocked_by = ended_blocker}))
  all[#all + 1] = settled
  local settled_lines = show.show_report(settled, all, "", {}, {})
  assert(not matched(settled_lines, "^blocked by:"),
    "nothing open holds it up: " .. table.concat(settled_lines, "\n"))
  assert(matched(settled_lines, "^blockers cleared: " .. ended_blocker .. "$"),
    "and the edge is still shown: " .. table.concat(settled_lines, "\n"))
end
test_show_separates_binding_blockers_from_cleared_ones()

-- A verdict judges a head AND the spec that head is measured against,
-- and `show` is what a re-reviewer reads to decide whether there is
-- anything new to see. A rework answering a bounce on the spec moves
-- the sidecar and no commit, so the head alone cannot answer it.
local function test_show_says_whether_the_spec_moved_since_the_verdict()
  local all = a_board()
  local judged = spec.revision(SIDECAR)
  local reworked = check.must(item.decode({id = WORK, title = "a slice",
        parent = UNDER, claim = "session-a", pr = 42,
        verdict = "request changes", verdict_head = "5364cc21",
        verdict_spec = judged}))
  local moved = show.show_report(reworked, all, SIDECAR .. "\n## Evidence\n",
    {}, {})
  assert(matched(moved, "^verdict: request changes %(head 5364cc21, "
      .. "spec changed since%)$"), table.concat(moved, "\n"))
  local still = show.show_report(reworked, all, SIDECAR, {}, {})
  assert(matched(still, "^verdict: request changes %(head 5364cc21, "
      .. "spec unchanged since%)$"), table.concat(still, "\n"))
  -- An unrecorded revision says nothing rather than guessing: the line
  -- reads exactly as it did before the field existed.
  local legacy = check.must(item.decode({id = WORK, title = "a slice",
        parent = UNDER, claim = "session-a", pr = 42, verdict = "accept",
        verdict_head = "5364cc21"}))
  local plain = show.show_report(legacy, all, SIDECAR, {}, {})
  assert(matched(plain, "^verdict: accept %(head 5364cc21%)$"),
    table.concat(plain, "\n"))
end
test_show_says_whether_the_spec_moved_since_the_verdict()
