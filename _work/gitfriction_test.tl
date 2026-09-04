#!/usr/bin/env cosmic
-- The `friction:` roll-call gate `_work.gitgraph.cmd_new` applies
-- through `_work.gitfriction`: naming fewer minted agents than the
-- session claimed work under is refused, naming all of them files it,
-- and `--force --why` files an incomplete roll call anyway. Split
-- from `_work.gitgraph_test`, which sits against the file cap.

local check = require("cosmic.check")
local env = require("cosmic.env")
local cmp = require("_work.gitcompare")
local fixture = require("_work.fixture")
local graph = require("_work.gitgraph")
local store = require("_work.store")
local tail = require("_work.tail")
local verbs = require("_work.gitverbs")

local init_state_repo = fixture.init_state_repo
local file_item = fixture.file_item
local give_spec = fixture.give_spec

--- Pin the session identity `_work.session` derives, so a minted
--- claim's `<orch8>` in this test is a known, fixed value rather than
--- whatever ambient identity this process happens to carry.
--- @param id string The session identity to pin
local function pin_session(id: string)
  check.must(env.set("GITBOARD_SESSION", id))
end

--- Undo `pin_session`.
local function unpin_session()
  local _ok, _err = env.unset("GITBOARD_SESSION")
end

--- Three items claimed under labels ending in `orch8`, for a
--- `friction:` filing to be measured against.
--- @param s store.Store The store
--- @param orch8 string The pinned session's own `<orch8>`
--- @return {string} The three claimed leaves' bare tails
local function three_minted_claims(s: store.Store, orch8: string): {string}
  local goal = file_item(s, "an outcome", "")
  local peer = file_item(s, "a lesser outcome", "")
  assert(cmp.cmd_compare(s, goal, peer) == 0, "compare should be accepted")
  local handles: {string} = {}
  for i = 1, 3 do
    local leaf = file_item(s, ("slice %d"):format(i), goal)
    give_spec(s, leaf)
    local handle = tail.bare(leaf)
    local label = ("build-%s-%s"):format(handle, orch8)
    assert(verbs.cmd_take(s, leaf, label, 0, false, "") == 0,
      "minting claim " .. tostring(i))
    handles[#handles + 1] = handle
  end
  return handles
end

-- A `friction:` filing must name every agent this session claimed
-- work under since the pass began, one `## build <handle>` heading
-- each: naming 2 of 3 minted claims is refused (and writes nothing),
-- naming all 3 files it.
local function test_friction_filing_names_every_minted_agent()
  local s = init_state_repo("friction-roll-call")
  pin_session("orch1234")
  local handles = three_minted_claims(s, "orch1234")
  local before = check.must(store.list(s))
  local two_of_three = ("## build %s\nnothing to report\n\n## build %s\n"
    .. "nothing to report\n"):format(handles[1], handles[2])
  assert(graph.cmd_new(s, "friction: roll call", "", two_of_three, "") ~= 0,
    "naming 2 of 3 minted agents is refused")
  assert(#check.must(store.list(s)) == #before,
    "the refused filing wrote no item")
  local all_three = two_of_three
  .. ("## build %s\nnothing to report\n"):format(handles[3])
  assert(graph.cmd_new(s, "friction: roll call", "", all_three, "") == 0,
    "naming every minted agent passes")
  assert(#check.must(store.list(s)) == #before + 1,
    "the passing filing landed as its own item")
  unpin_session()
end

-- `--force --why` files a `friction:` item over an incomplete roll
-- call anyway — a pass whose transcripts are gone.
local function test_friction_filing_force_bypasses_the_roll_call()
  local s = init_state_repo("friction-force")
  pin_session("orch5678")
  three_minted_claims(s, "orch5678")
  local before = check.must(store.list(s))
  assert(graph.cmd_new(s, "friction: incomplete pass", "", "nothing here",
      "") ~= 0, "naming nobody is refused")
  assert(#check.must(store.list(s)) == #before, "the refusal wrote no item")
  assert(graph.cmd_new(s, "friction: incomplete pass", "", "nothing here",
      "", true, "the transcripts are gone") == 0,
    "--force --why files it anyway")
  assert(#check.must(store.list(s)) == #before + 1,
    "the forced filing landed as its own item")
  unpin_session()
end

--- Claim one leaf under `goal` and mint it to `orch8`.
--- @param s store.Store The store
--- @param goal string The parent to attach the leaf under
--- @param title string The leaf's title
--- @param orch8 string The claiming session's own `<orch8>`
--- @return string The claimed leaf's bare tail
local function mint_claim(s: store.Store, goal: string, title: string,
    orch8: string): string
  local leaf = file_item(s, title, goal)
  give_spec(s, leaf)
  local handle = tail.bare(leaf)
  assert(verbs.cmd_take(s, leaf, ("build-%s-%s"):format(handle, orch8), 0,
      false, "") == 0, "minting claim " .. handle)
  return handle
end

-- Two orchestrators filing on overlapping days must not satisfy one
-- another's roll call: A claims one agent and correctly names it; A
-- claims a second; a DIFFERENT orchestrator B, having minted nothing
-- of its own, correctly files an empty log in between; A's own next
-- filing must still name A's second, still-unaccounted-for claim — B's
-- unrelated, more recent filing does not stand in for it.
local function test_friction_filing_is_not_satisfied_by_another_orchestrator()
  local s = init_state_repo("friction-concurrent")
  local goal = file_item(s, "an outcome", "")
  local peer = file_item(s, "a lesser outcome", "")
  assert(cmp.cmd_compare(s, goal, peer) == 0, "compare should be accepted")

  pin_session("orchAAAA")
  local first = mint_claim(s, goal, "slice one", "orchAAAA")
  assert(graph.cmd_new(s, "friction: pass one", "",
      ("## build %s\nnothing to report\n"):format(first), "") == 0,
    "naming the one claim minted so far passes")
  local second = mint_claim(s, goal, "slice two", "orchAAAA")
  unpin_session()

  pin_session("orchBBBB")
  local before_b = check.must(store.list(s))
  assert(graph.cmd_new(s, "friction: nothing minted", "", "nothing here",
      "") == 0, "a session that minted no claims may correctly name none")
  assert(#check.must(store.list(s)) == #before_b + 1,
    "the other orchestrator's correct empty filing landed")
  unpin_session()

  pin_session("orchAAAA")
  local before_a = check.must(store.list(s))
  assert(graph.cmd_new(s, "friction: pass two", "", "nothing here", "") ~= 0,
    "B's unrelated filing must not hide A's own unnamed second claim")
  assert(#check.must(store.list(s)) == #before_a,
    "the refused filing wrote no item")
  assert(graph.cmd_new(s, "friction: pass two", "",
      ("## build %s\nnothing to report\n"):format(second), "") == 0,
    "naming the outstanding second claim passes")
  assert(#check.must(store.list(s)) == #before_a + 1,
    "the passing filing landed as its own item")
  unpin_session()
end
