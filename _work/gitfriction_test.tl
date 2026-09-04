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
