#!/usr/bin/env cosmic
-- The item codec is pure: encode omits zero values, decode fills them
-- back in and validates, and the two round-trip through cosmic.literal
-- byte-for-byte. The per-item rules pin the emergent-role invariants a
-- single file can carry: only parented items hold coordination
-- fields, roots hold edges alone, and done items hold no locks.

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

--- Whether a decoded item's `decode_problems` names `needle` anywhere
--- in the list — `problems(it)` can return several at once, so a test
--- of one does not assume it is first.
local function has_problem(it: item.Item, needle: string): boolean
  for _, p in ipairs(it.decode_problems or {}) do
    if p:find(needle, 1, true) then
      return true
    end
  end
  return false
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

local function test_worked_item_round_trips()
  local t = base()
  t.parent = PARENT
  t.claim = "session-a"
  t.pr = 456
  t.verdict = "request changes"
  t.verdict_head = "abc1234"
  t.blocked_by = PARENT .. " " .. OTHER
  local it = check.must(item.decode(t))
  local back = check.must(item.decode(
      check.must(literal.parse(check.must(literal.format(item.encode(it)))))))
  assert(back.parent == PARENT, "position fields")
  assert(back.claim == "session-a" and back.pr == 456, "coordination fields")
  assert(#back.blocked_by == 2 and back.blocked_by[1] == PARENT, "blocked_by")
end

local function test_roots_hold_edges_not_locks()
  local root = base()
  root.beats = PARENT
  local g = check.must(item.decode(root))
  assert(#g.beats == 1 and g.beats[1] == PARENT,
    "a root's priority edge decodes")
  local claimed = base()
  claimed.claim = "session-a"
  local it = check.must(item.decode(claimed))
  assert(has_problem(it, "not roots"),
    "a claimed root decodes flagged: "
    .. table.concat(it.decode_problems or {}, "; "))
end

local function test_priority_edges_name_other_items()
  local looping = base()
  looping.beats = ID
  local it = check.must(item.decode(looping))
  assert(has_problem(it, "nothing outranks itself"),
    "a self-edge decodes flagged: "
    .. table.concat(it.decode_problems or {}, "; "))
  local junk = base()
  junk.beats = "not-an-id"
  local jit = check.must(item.decode(junk))
  assert(has_problem(jit, "beats names a non-id"),
    "a non-id edge decodes flagged: "
    .. table.concat(jit.decode_problems or {}, "; "))
end

local function test_done_items_hold_no_locks()
  local t = base()
  t.parent = PARENT
  t.claim = "session-a"
  t.resolution = "completed"
  local it = check.must(item.decode(t))
  assert(has_problem(it, "no claim"),
    "a done claimed item decodes flagged: "
    .. table.concat(it.decode_problems or {}, "; "))
  t.claim = nil
  local done = check.must(item.decode(t))
  assert(not item.is_open(done), "resolution IS done")
  assert(not item.is_flagged(done), "a clean done item is not flagged")
end

-- A verdict judges a diff when there is a PR, and a claimed item's
-- recorded evidence when there is none — `gitverdict` decides which
-- may be RECORDED; the codec only pins that either shape decodes
-- clean, and stands just as clean once `done` clears the claim after
-- it (already-completed PR-less items are stored state, not
-- re-validated).
local function test_a_verdict_may_stand_with_or_without_a_pr()
  local t = base()
  t.parent = PARENT
  t.claim = "session-a"
  t.verdict = "accept"
  local it = check.must(item.decode(t))
  assert(not item.is_flagged(it),
    "a claimed PR-less verdict decodes clean: "
    .. table.concat(it.decode_problems or {}, "; "))
  t.pr = 7
  local withpr = check.must(item.decode(t))
  assert(withpr.verdict == "accept" and not item.is_flagged(withpr),
    "with a PR it decodes clean too")
  t.pr = nil
  t.claim = nil
  t.resolution = "completed"
  local ended = check.must(item.decode(t))
  assert(not item.is_flagged(ended),
    "and a completed PR-less item's own accept still stands with the claim gone")
end

local function test_repo_scopes_a_workable_items_pr()
  local t = base()
  t.parent = PARENT
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
  garbage.repo = "not-a-slug"
  local gflagged = check.must(item.decode(garbage))
  assert(has_problem(gflagged, "repo must be owner/name"),
    "a malformed repo decodes flagged: "
    .. table.concat(gflagged.decode_problems or {}, "; "))

  local rooted = base()
  rooted.repo = "whilp/cosmopolitan"
  local rflagged = check.must(item.decode(rooted))
  assert(has_problem(rflagged, "not roots"),
    "a repo on a root decodes flagged: "
    .. table.concat(rflagged.decode_problems or {}, "; "))
end

-- `base` mirrors `repo`: a plain branch-name shape, round-trips,
-- omitted at zero, and refused on a root the same way repo is.
local function test_base_names_the_prs_target_branch()
  local t = base()
  t.parent = PARENT
  t.base = "release"
  local it = check.must(item.decode(t))
  assert(it.base == "release", "a well-formed base decodes")
  local back = check.must(item.decode(
      check.must(literal.parse(check.must(literal.format(item.encode(it)))))))
  assert(back.base == "release", "base round-trips")

  local default = check.must(item.decode(base()))
  assert(default.base == "", "unset base defaults to ungated")
  local dt = item.encode(default)
  assert(dt.base == nil, "a default base carries no key at all")

  local garbage = base()
  garbage.parent = PARENT
  garbage.base = "not a branch!"
  local gflagged = check.must(item.decode(garbage))
  assert(has_problem(gflagged, "base must be a branch name"),
    "a malformed base decodes flagged: "
    .. table.concat(gflagged.decode_problems or {}, "; "))

  local rooted = base()
  rooted.base = "release"
  local rflagged = check.must(item.decode(rooted))
  assert(has_problem(rflagged, "not roots"),
    "a base on a root decodes flagged: "
    .. table.concat(rflagged.decode_problems or {}, "; "))
end

-- A list field's invariants hold by validation, not by the writer's
-- convention: `block` rebuilds its list through a `seen` set, but a
-- migration or a hand-edit reaches the file directly, and a repeated
-- entry over-reports the blocker count and renders twice in `show`.
-- Refused rather than folded — silently deduping would hide whichever
-- writer produced them.
local function test_list_fields_flag_a_repeated_entry()
  local blocked = base()
  blocked.blocked_by = PARENT .. " " .. OTHER .. " " .. PARENT
  local bflagged = check.must(item.decode(blocked))
  assert(has_problem(bflagged, "blocked_by repeats " .. PARENT),
    "a repeated blocker decodes flagged: "
    .. table.concat(bflagged.decode_problems or {}, "; "))

  local ranked = base()
  ranked.beats = PARENT .. " " .. OTHER .. " " .. OTHER
  local rflagged = check.must(item.decode(ranked))
  assert(has_problem(rflagged, "beats repeats " .. OTHER),
    "a repeated beat decodes flagged: "
    .. table.concat(rflagged.decode_problems or {}, "; "))

  local distinct = base()
  distinct.blocked_by = PARENT .. " " .. OTHER
  distinct.beats = PARENT .. " " .. OTHER
  local ok = check.must(item.decode(distinct))
  assert(#ok.blocked_by == 2 and #ok.beats == 2 and not item.is_flagged(ok),
    "distinct entries in each list decode clean")
end

local function test_id_discipline()
  local it = check.must(item.decode({id = "not-a-ksuid", title = "t"}))
  assert(has_problem(it, "ksuid"), "a non-ksuid id decodes flagged")
  local blocked = base()
  blocked.blocked_by = "junk"
  local bflagged = check.must(item.decode(blocked))
  assert(has_problem(bflagged, "non-id"), "a non-id blocker decodes flagged: "
    .. table.concat(bflagged.decode_problems or {}, "; "))
end

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

local function test_an_item_cannot_wait_on_itself()
  local t = base()
  t.parent = PARENT
  t.blocked_by = ID
  local it = check.must(item.decode(t))
  assert(has_problem(it, "itself"),
    "a self-block decodes flagged: "
    .. table.concat(it.decode_problems or {}, "; "))
end

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
  local flagged = check.must(item.decode(t))
  assert(has_problem(flagged, "builders repeats"),
    "a repeated builder decodes flagged: "
    .. table.concat(flagged.decode_problems or {}, "; "))
end

-- `speccers` is `builders`' counterpart for spec authorship: same
-- space-joined encoding, same no-repeats rule.
local function test_speccers_round_trip()
  local t = base()
  t.parent = PARENT
  t.speccers = "session-a session-b"
  local it = check.must(item.decode(t))
  assert(#it.speccers == 2 and it.speccers[1] == "session-a"
    and it.speccers[2] == "session-b",
    "the list decodes in order: " .. table.concat(it.speccers, ","))
  assert(item.encode(it).speccers == "session-a session-b",
    "and encodes back to the same string")

  it.speccers = {}
  assert(item.encode(it).speccers == nil, "an empty list is not written")

  t.speccers = "session-a session-a"
  local flagged = check.must(item.decode(t))
  assert(has_problem(flagged, "speccers repeats"),
    "a repeated speccer decodes flagged: "
    .. table.concat(flagged.decode_problems or {}, "; "))
end

-- decode validates through cosmic.shape now: a wrong-typed field is a
-- refusal with a dotted path, not a silent coercion to zero.
local function test_a_wrong_typed_field_is_refused()
  local t = base()
  t.pr = "seven"
  local bad, err = item.decode(t)
  assert(bad == nil and err:find("pr", 1, true) and err:find("integer", 1, true),
    "a wrong-typed pr is refused with its path: " .. tostring(err))
end

-- Every identity shape a real session has presented — enumerated from
-- the board's own log and item files — passes the shape check and
-- records. No grammar unifies them (uuids, uuid/handle pairs, minted
-- wave and handoff names, reviewer names with and without a -revN,
-- scheduled runs, free-form runner names, a user-host pair), which is
-- why `identity_refusal` is a blocklist, not an allowlist.
local LIVE_IDENTITIES: {string} = {
  "0b13d2b4-bb26-5bc1-8635-407acd85452c",
  "05f7c552-0c90-51cb-99b3-e018759c6ed5/3IVEEDO8",
  "wave15-b-1788042780",
  "wave-w1-1788018497",
  "wave2-wa2-1788020861",
  "handoff-b1-1788045000",
  "review-3IbhHpG9-1788043076",
  "review-3IbS3xsB-1788033981-rev2",
  "claude-sched-2026-08-24T0238",
  "magical-bell",
  "qmnmv1",
  "sched-pcoatp",
  "workflow-3q9w2x",
  "9502275599-1-ci",
  "wcmaier-somehost",
}
local function test_every_live_identity_shape_passes()
  for _, name in ipairs(LIVE_IDENTITIES) do
    assert(item.identity_refusal(name) == nil,
      "a live identity must pass: " .. name)
    local list: {string} = {}
    assert(item.record_involvement(list, name), "and record: " .. name)
    assert(item.record_involvement(list, name), "a repeat is a no-op")
    assert(#list == 1 and list[1] == name, "recorded once: " .. name)
  end
end

-- The incident's token: a mangled argv absorbing a literal
-- `--session` as the identity. Refused by shape — dash-led — at the
-- write, and never wired into decode/problems, so the one historical
-- item already carrying it keeps reading.
local function test_a_flag_shaped_identity_is_refused()
  assert(item.identity_refusal("--session") ~= nil, "the incident's token")
  assert(item.identity_refusal("-x") ~= nil, "any dash-led token")
  local list: {string} = {"session-a"}
  local ok, err = item.record_involvement(list, "--session")
  assert(not ok and err:find("--session", 1, true) ~= nil,
    "refused, naming the token: " .. tostring(err))
  assert(#list == 1 and list[1] == "session-a", "and nothing was recorded")
  -- The poisoned historical record still decodes: gating reads would
  -- brick every `store.list` over the one bad item.
  local t = base()
  t.parent = PARENT
  t.builders = "--session builder-a"
  local it = check.must(item.decode(t))
  assert(#it.builders == 2, "a recorded flag-shaped builder still reads")
end

-- Unknown keys stay tolerated: a Spec that does not name a key never
-- looks at it, so a file carrying a retired field still decodes.
local function test_an_unknown_key_still_decodes()
  local t = base()
  t.retired_field = "leftover from an older schema"
  local it = check.must(item.decode(t))
  assert(it.id == ID and it.title == "an item",
    "an unknown key does not block decode")
end

-- The bricking incident itself: a multiline title (the one shape a
-- pre-refusal writer could have committed, crafted here with a valid
-- `\<newline>` escape) must decode, flagged, rather than fail the way
-- it used to — a `store.list` over 172 good items and this one bad
-- record can no longer die on the first bad file it reads.
local function test_a_multiline_title_decodes_flagged_not_refused()
  local t = base()
  t.title = "first line\nsecond line"
  local it = check.must(item.decode(t))
  assert(item.is_flagged(it), "a multiline title decodes flagged")
  assert(has_problem(it, "title must be one line"),
    "naming the reason: " .. table.concat(it.decode_problems or {}, "; "))
  assert(it.title == "first line\nsecond line",
    "the raw title survives decode, so a repair can still see it")
end

-- A clean item never carries `decode_problems` at all — flagged is a
-- read-time fact about THIS decode, not a field every item grows.
local function test_a_clean_item_is_not_flagged()
  local it = check.must(item.decode(base()))
  assert(not item.is_flagged(it) and it.decode_problems == nil,
    "a well-formed item decodes with no problems attached")
end
