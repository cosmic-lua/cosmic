#!/usr/bin/env cosmic
-- The item codec is pure: encode omits zero values, decode fills them
-- back in and validates, and the two round-trip through cosmic.literal
-- byte-for-byte. The per-item rules pin the emergent-role invariants a
-- single file can carry: only parented items hold phases or
-- coordination fields, only roots hold ranks, done items hold neither
-- phase nor claim to a slot.

local check = require("cosmic.check")
local item = require("_work.item")
local ksuid = require("_work.ksuid")
local literal = require("cosmic.literal")

local ZEROS = ("\0"):rep(16)
local ID = check.must(ksuid.encode(1700000001, ZEROS))
local PARENT = check.must(ksuid.encode(1700000000, ZEROS))
local OTHER = check.must(ksuid.encode(1699999999, ZEROS))

local function base(): {string: any}
  return {id = ID, title = "an item"}
end

local function test_root_round_trips_minimal()
  local it = check.must(item.decode(base()))
  assert(item.is_root(it) and item.is_open(it), "a bare item is an open root")
  local t = item.encode(it)
  local keys = 0
  for _ in pairs(t) do
    keys = keys + 1
  end
  assert(keys == 2, "want only id/title, got " .. keys .. " keys")
  local back = check.must(item.decode(
      check.must(literal.parse(check.must(literal.format(t))))))
  assert(back.id == ID and back.title == "an item", "round-trips")
end
test_root_round_trips_minimal()

local function test_worked_item_round_trips()
  local t = base()
  t.parent = PARENT
  t.phase = "check"
  t.claim = "session-a"
  t.pr = 456
  t.verdict = "request changes"
  t.verdict_head = "abc1234"
  t.blocked_by = PARENT .. " " .. OTHER
  local it = check.must(item.decode(t))
  local back = check.must(item.decode(
      check.must(literal.parse(check.must(literal.format(item.encode(it)))))))
  assert(back.parent == PARENT and back.phase == "check", "position fields")
  assert(back.claim == "session-a" and back.pr == 456, "coordination fields")
  assert(#back.blocked_by == 2 and back.blocked_by[1] == PARENT, "blocked_by")
end
test_worked_item_round_trips()

local function test_roots_hold_edges_not_phases()
  local root = base()
  root.beats = PARENT
  local g = check.must(item.decode(root))
  assert(#g.beats == 1 and g.beats[1] == PARENT,
    "a root's priority edge decodes")
  local phased = base()
  phased.phase = "plan"
  local bad, err = item.decode(phased)
  assert(bad == nil and err:find("root is never phased", 1, true),
    "a phased root is refused: " .. tostring(err))
  local claimed = base()
  claimed.claim = "session-a"
  local cbad, cerr = item.decode(claimed)
  assert(cbad == nil and cerr:find("not roots", 1, true),
    "a claimed root is refused: " .. tostring(cerr))
end
test_roots_hold_edges_not_phases()

local function test_priority_edges_name_other_items()
  local looping = base()
  looping.beats = ID
  local bad, err = item.decode(looping)
  assert(bad == nil and err:find("nothing outranks itself", 1, true),
    "a self-edge is refused: " .. tostring(err))
  local junk = base()
  junk.beats = "not-an-id"
  local jbad, jerr = item.decode(junk)
  assert(jbad == nil and jerr:find("beats names a non-id", 1, true),
    "a non-id edge is refused: " .. tostring(jerr))
end
test_priority_edges_name_other_items()

local function test_done_items_carry_no_phase()
  local t = base()
  t.parent = PARENT
  t.phase = "land"
  t.resolution = "completed"
  local bad, err = item.decode(t)
  assert(bad == nil and err:find("no phase", 1, true),
    "a done phased item is refused: " .. tostring(err))
  t.phase = nil
  local done = check.must(item.decode(t))
  assert(not item.is_open(done), "resolution IS done")
end
test_done_items_carry_no_phase()

local function test_repo_scopes_a_workable_items_pr()
  local t = base()
  t.parent = PARENT
  t.phase = "plan"
  t.repo = "whilp/cosmopolitan"
  local it = check.must(item.decode(t))
  assert(it.repo == "whilp/cosmopolitan", "a well-formed repo decodes")
  local back = check.must(item.decode(
      check.must(literal.parse(check.must(literal.format(item.encode(it)))))))
  assert(back.repo == "whilp/cosmopolitan", "repo round-trips")

  local default = check.must(item.decode(base()))
  assert(default.repo == "", "unset repo defaults to the board's origin")
  local dt = item.encode(default)
  assert(dt.repo == nil, "a default repo carries no key at all")

  local garbage = base()
  garbage.parent = PARENT
  garbage.phase = "plan"
  garbage.repo = "not-a-slug"
  local gbad, gerr = item.decode(garbage)
  assert(gbad == nil and gerr:find("repo must be owner/name", 1, true),
    "a malformed repo is refused: " .. tostring(gerr))

  local rooted = base()
  rooted.repo = "whilp/cosmopolitan"
  local rbad, rerr = item.decode(rooted)
  assert(rbad == nil and rerr:find("not roots", 1, true),
    "a repo on a root is refused: " .. tostring(rerr))
end
test_repo_scopes_a_workable_items_pr()

-- A list field's invariants hold by validation, not by the writer's
-- convention: `block` rebuilds its list through a `seen` set, but a
-- migration or a hand-edit reaches the file directly, and a repeated
-- entry over-reports the blocker count and renders twice in `show`.
-- Refused rather than folded — silently deduping would hide whichever
-- writer produced them.
local function test_list_fields_refuse_a_repeated_entry()
  local blocked = base()
  blocked.blocked_by = PARENT .. " " .. OTHER .. " " .. PARENT
  local bbad, berr = item.decode(blocked)
  assert(bbad == nil and berr:find("blocked_by repeats " .. PARENT, 1, true),
    "a repeated blocker is refused: " .. tostring(berr))

  local ranked = base()
  ranked.beats = PARENT .. " " .. OTHER .. " " .. OTHER
  local rbad, rerr = item.decode(ranked)
  assert(rbad == nil and rerr:find("beats repeats " .. OTHER, 1, true),
    "a repeated beat is refused: " .. tostring(rerr))

  local distinct = base()
  distinct.blocked_by = PARENT .. " " .. OTHER
  distinct.beats = PARENT .. " " .. OTHER
  local ok = check.must(item.decode(distinct))
  assert(#ok.blocked_by == 2 and #ok.beats == 2,
    "distinct entries in each list are accepted")
end
test_list_fields_refuse_a_repeated_entry()

local function test_id_discipline()
  local bad, err = item.decode({id = "not-a-ksuid", title = "t"})
  assert(bad == nil and err:find("ksuid", 1, true), "ids are ksuids")
  local blocked = base()
  blocked.blocked_by = "junk"
  local bbad, berr = item.decode(blocked)
  assert(bbad == nil and berr:find("non%-id"), "blocker ids are ksuids: "
    .. tostring(berr))
end
test_id_discipline()

local function test_block_reason_rides_the_edge_and_round_trips()
  local t = base()
  t.parent = PARENT
  t.blocked_by = OTHER
  t.block_reason = {[OTHER] = "the API lands there first"}
  local it = check.must(item.decode(t))
  assert(it.block_reason[OTHER] == "the API lands there first",
    "the reason decodes")
  local back = check.must(item.decode(
      check.must(literal.parse(check.must(literal.format(item.encode(it)))))))
  assert(back.block_reason[OTHER] == "the API lands there first",
    "and round-trips through the literal")
  -- A reason whose edge is gone heals on the next write, like a
  -- duplicate blocker does.
  it.blocked_by = {}
  local healed = item.encode(it)
  assert(healed.block_reason == nil and healed.blocked_by == nil,
    "an orphaned reason is not written")
end
test_block_reason_rides_the_edge_and_round_trips()

local function test_an_item_cannot_wait_on_itself()
  local t = base()
  t.parent = PARENT
  t.blocked_by = ID
  local bad, err = item.decode(t)
  assert(bad == nil and err:find("itself", 1, true),
    "a self-block is invalid: " .. tostring(err))
end
test_an_item_cannot_wait_on_itself()

-- `builders` is the durable half of authorship: a space-joined list
-- like `beats` and `blocked_by`, omitted when empty, and refusing the
-- repeat that would let one session appear to have built an item
-- twice.
local function test_builders_round_trip()
  local t = base()
  t.parent = PARENT
  t.claim = "session-b"
  t.builders = "session-a session-b"
  local it = check.must(item.decode(t))
  assert(#it.builders == 2 and it.builders[1] == "session-a"
    and it.builders[2] == "session-b",
    "the list decodes in order: " .. table.concat(it.builders, ","))
  assert(item.encode(it).builders == "session-a session-b",
    "and encodes back to the same string")

  it.builders = {}
  assert(item.encode(it).builders == nil, "an empty list is not written")

  t.builders = "session-a session-a"
  local bad, err = item.decode(t)
  assert(bad == nil and err:find("builders repeats", 1, true),
    "a repeated builder is invalid: " .. tostring(err))
end
test_builders_round_trip()
