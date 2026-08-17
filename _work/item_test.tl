#!/usr/bin/env cosmic
-- The item codec is pure: encode omits zero values, decode fills them
-- back in and validates per kind, and the two round-trip through
-- cosmic.literal byte-for-byte. Phase discipline is the point: only an
-- open slice carries one, which is what dissolves the label board's
-- epic and finding carve-outs.

local check = require("cosmic.check")
local item = require("_work.item")
local literal = require("cosmic.literal")

local function base(kind: string): {string: any}
  local t: {string: any} = {
    id = "sample-" .. kind, kind = kind, title = "a " .. kind,
    opened = "2026-08-17T00:00:00Z",
  }
  if kind == "goal" then
    t.rank = 1
  end
  if kind == "epic" then
    t.parent = "sample-goal"
  end
  if kind == "slice" then
    t.parent = "sample-epic"
    t.phase = "plan"
  end
  return t
end

local function test_every_kind_round_trips()
  for _, kind in ipairs({"goal", "epic", "slice", "finding"}) do
    local it = check.must(item.decode(base(kind)))
    local text = check.must(literal.format(item.encode(it)))
    local back = check.must(item.decode(check.must(literal.parse(text))))
    assert(back.id == it.id and back.kind == kind, kind .. " round-trips")
    assert(back.opened == it.opened, "opened survives")
  end
end
test_every_kind_round_trips()

local function test_slice_fields_round_trip()
  local t = base("slice")
  t.phase = "check"
  t.claim = "session-a"
  t.pr = 456
  t.verdict = "request changes"
  t.verdict_head = "abc1234"
  t.blocked_by = "other-slice third-slice"
  local it = check.must(item.decode(t))
  local back = check.must(item.decode(
      check.must(literal.parse(check.must(literal.format(item.encode(it)))))))
  assert(back.claim == "session-a" and back.pr == 456, "coordination fields")
  assert(back.verdict == "request changes", "verdict")
  assert(#back.blocked_by == 2 and back.blocked_by[2] == "third-slice",
    "blocked_by")
end
test_slice_fields_round_trip()

local function test_phase_belongs_to_open_slices_only()
  local goal = base("goal")
  goal.phase = "plan"
  local bad, err = item.decode(goal)
  assert(bad == nil and err:find("only slices are phased", 1, true),
    "a phased goal is refused: " .. tostring(err))
  local slice = base("slice")
  slice.phase = nil
  local unphased, uerr = item.decode(slice)
  assert(unphased == nil and uerr:find("needs a phase", 1, true),
    "an open unphased slice is refused: " .. tostring(uerr))
  slice.phase = "do"
  slice.resolution = "completed"
  local done, derr = item.decode(slice)
  assert(done == nil and derr:find("no phase", 1, true),
    "a done slice keeps no phase: " .. tostring(derr))
end
test_phase_belongs_to_open_slices_only()

local function test_kind_rules()
  local goal = base("goal")
  goal.rank = nil
  local unranked, rerr = item.decode(goal)
  assert(unranked == nil and rerr:find("rank", 1, true), "a goal needs a rank")
  local epic = base("epic")
  epic.parent = nil
  local orphan, perr = item.decode(epic)
  assert(orphan == nil and perr:find("parent", 1, true),
    "an epic needs a parent")
  local epic2 = base("epic")
  epic2.claim = "session-a"
  local claimed, cerr = item.decode(epic2)
  assert(claimed == nil and cerr:find("belong to slices", 1, true),
    "claims belong to slices: " .. tostring(cerr))
  local finding = check.must(item.decode(base("finding")))
  assert(finding.parent == "" and finding.phase == "",
    "a finding is parentless and unphased until adopted")
end
test_kind_rules()

local function test_encode_omits_zero_values()
  local it = check.must(item.decode(base("finding")))
  local t = item.encode(it)
  local keys = 0
  for _ in pairs(t) do
    keys = keys + 1
  end
  assert(keys == 4, "want only id/kind/title/opened, got " .. keys .. " keys")
end
test_encode_omits_zero_values()

local function test_id_grammar()
  assert(item.is_id("fetch-retry-2"), "slugs pass")
  assert(not item.is_id("Fetch"), "uppercase refused")
  assert(not item.is_id("2fast"), "leading digit refused")
  assert(not item.is_id(""), "empty refused")
end
test_id_grammar()
