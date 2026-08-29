#!/usr/bin/env cosmic
-- Lane health as board state: mint's idempotency and auto-close
-- guards, record's change-gated commit, and observe's offline path.
-- The network call itself (`observe_one`'s GET) is exercised only
-- live, against a real GitHub token; these tests drive `record` and
-- `mint` with a fake facts table, the way `cmd_sync` would after a
-- real `observe` returned one.

local check = require("cosmic.check")
local child = require("cosmic.child")
local action = require("_work.action")
local cmp = require("_work.gitcompare")
local fixture = require("_work.fixture")
local flow = require("_work.flow")
local fs = require("cosmic.fs")
local gate = require("_work.gitgate")
local item = require("_work.item")
local lanes = require("_work.lanes")
local spec = require("_work.spec")
local store = require("_work.store")

local init_state_repo = fixture.init_state_repo

local RED: {string: string} = {["release.yml"] = "failure",
  ["fuzz.yml"] = "success", ["docs.yml"] = "success"}
local GREEN: {string: string} = {["release.yml"] = "success",
  ["fuzz.yml"] = "success", ["docs.yml"] = "success"}

--- The one open repair item carrying `lane`, nil when there is none.
local function repair_for(all: {item.Item}, lane: string): item.Item
  for _, it in ipairs(all) do
    if item.is_open(it) and it.lane == lane then
      return it
    end
  end
  return nil
end

-- Two red observations of the same lane mint exactly one repair item:
-- the lane's filename is the idempotency key `mint` searches on
-- before ever filing one — five red days cost one item, not five.
local function test_mint_is_idempotent_per_lane()
  local s = init_state_repo("mint-idempotent")
  assert(lanes.mint(s, RED))
  local repair = repair_for(check.must(store.list(s)), "release.yml")
  assert(repair ~= nil, "one repair item filed for the red lane")

  -- The minted sidecar clears the spec bar honestly — `_work.spec`'s
  -- real check, not a copy of its rule — which is what lets `next`
  -- offer the item and `take` admit it without disagreeing.
  local body = store.read_spec(s, repair.id)
  local gaps = spec.ready_gaps(body)
  assert(#gaps == 0,
    "the minted sidecar passes the spec bar: " .. table.concat(gaps, "; "))

  assert(lanes.mint(s, RED))
  local all = check.must(store.list(s))
  local count = 0
  for _, it in ipairs(all) do
    if it.lane == "release.yml" then count = count + 1 end
  end
  assert(count == 1,
    "a second red observation mints nothing new: " .. tostring(count))
end
test_mint_is_idempotent_per_lane()

-- A lane back to green closes its UNCLAIMED repair item, as
-- not-planned — the monitor observed a fact, it never completed work.
local function test_green_closes_an_unclaimed_repair()
  local s = init_state_repo("mint-closes")
  assert(lanes.mint(s, RED))
  local repair = repair_for(check.must(store.list(s)), "release.yml")
  assert(repair ~= nil and item.is_open(repair), "the repair starts open")

  assert(lanes.mint(s, GREEN))
  local closed = check.must(store.load(s, repair.id))
  assert(not item.is_open(closed), "the green lane closes its repair")
  assert(closed.resolution == "not-planned",
    "auto-closed as not-planned, never completed: " .. closed.resolution)
end
test_green_closes_an_unclaimed_repair()

-- A CLAIMED repair is left alone even when its lane goes green: the
-- monitor never undoes a builder's in-flight claim.
local function test_a_claimed_repair_is_left_alone_on_green()
  local s = init_state_repo("mint-claimed")
  assert(lanes.mint(s, RED))
  local repair = repair_for(check.must(store.list(s)), "release.yml")
  assert(repair ~= nil)
  repair.claim = "session-a"
  assert(store.save(s, repair, ("take %s by session-a"):format(
        repair.id:sub(1, 8))))

  assert(lanes.mint(s, GREEN))
  local still = check.must(store.load(s, repair.id))
  assert(item.is_open(still), "a claimed repair stays open on green")
  assert(still.claim == "session-a", "and the claim is untouched")
end
test_a_claimed_repair_is_left_alone_on_green()

-- record writes and commits ONLY when the facts changed from what is
-- already recorded; a re-observation that agrees with the last one
-- commits nothing, so the log records a fact CHANGING, not a fact
-- being re-confirmed every sync.
local function test_record_commits_only_on_change()
  local s = init_state_repo("record-change")
  local facts: {string: string} = {["release.yml"] = "success",
    ["fuzz.yml"] = "success", ["docs.yml"] = "success"}
  local before = fixture.commits(s)
  assert(lanes.record(s, facts), "the first observation is new, and commits")
  assert(fixture.commits(s) == before + 1, "exactly one commit")

  local ok, err = lanes.record(s, facts)
  assert(not ok, "an unchanged observation records nothing")
  assert(err == "", "and carries no error — this is a no-op, not a failure")
  assert(fixture.commits(s) == before + 1, "so the commit count does not move")

  facts["fuzz.yml"] = "failure"
  assert(lanes.record(s, facts), "a real change commits again")
  assert(fixture.commits(s) == before + 2)
end
test_record_commits_only_on_change()

-- record's commit subject is a grammar other code will eventually
-- parse (a future consumer of `lanes_state.tl`'s history): pin the
-- exact string — `sync lanes: <lane>=<conclusion> ...`, space-joined
-- in LANES order — so the format cannot drift silently before that
-- consumer exists to notice.
local function test_record_commit_subject_is_exact()
  local s = init_state_repo("record-subject")
  assert(lanes.record(s, RED), "a new observation commits")
  local r = check.must(child.run({"git", "log", "-1", "--format=%s"},
      {cwd = s.root}))
  assert(r.ok, "git log failed: " .. r.stderr)
  local subject = r.stdout:gsub("%s+$", "")
  assert(subject == "sync lanes: release.yml=failure "
    .. "fuzz.yml=success docs.yml=success", "got: " .. subject)
end
test_record_commit_subject_is_exact()

-- `report` is what `cmd_sync` calls (via `at_sync`) after a real
-- `observe` returns facts; a `record` failure must show up in its
-- lines rather than vanish the way `cmd_sync` used to discard it.
-- Forced by a directory sitting where `record` wants to write its
-- state FILE — an EISDIR even root cannot bypass, unlike a chmod,
-- which a root-run test (as this one may be) would sail through.
local function test_report_surfaces_a_record_failure()
  local s = init_state_repo("report-record-fails")
  assert(fs.make_dirs(fs.join(s.root, "lanes_state.tl")),
    "a directory in the way makes record's write fail with EISDIR")
  local lines = lanes.report(s, RED)
  local found = false
  for _, line in ipairs(lines) do
    if line:find("lanes record failed", 1, true) then found = true end
  end
  assert(found, "a record failure is printed, not discarded: "
    .. table.concat(lines, " | "))
end
test_report_surfaces_a_record_failure()

-- Symmetric case: `items/` replaced by a plain file makes `mint`'s
-- `store.list` fail with ENOTDIR (opendir on a non-directory, also
-- root-proof) without touching `record`, which writes at the store
-- root instead. `report` must surface this one too.
local function test_report_surfaces_a_mint_failure()
  local s = init_state_repo("report-mint-fails")
  local items_dir = fs.join(s.root, "items")
  assert(fs.remove_all(items_dir))
  assert(fs.write(items_dir, "not a directory"))
  local lines = lanes.report(s, RED)
  local found = false
  for _, line in ipairs(lines) do
    if line:find("lanes mint failed", 1, true) then found = true end
  end
  assert(found, "a mint failure is printed, not discarded: "
    .. table.concat(lines, " | "))
end
test_report_surfaces_a_mint_failure()

-- observe needs a slug to address GitHub with; a checkout with no
-- origin has none, so the whole observation comes back "unknown" —
-- the same shape a token-less or offline sync sees — with no network
-- ever touched, which is what makes this safe to run in CI.
local function test_observe_with_no_origin_is_unknown_not_red()
  local s = init_state_repo("observe-no-origin")
  local facts, err = lanes.observe(s)
  assert(facts == nil, "no slug to address means no facts")
  assert(err:find("no origin remote", 1, true) ~= nil, "got: " .. err)
end
test_observe_with_no_origin_is_unknown_not_red()

-- A minted repair is coherent with the two verbs that decide its
-- fate: `next` (`_work.action.next_action`) offers it, and `take`
-- (`_work.gitgate.ready_problems` plus `flow.doing_refusal`, the exact
-- pair `cmd_take` calls) admits it. Placed the way the real repair
-- parent (G8) already is on the live board — one comparison on the
-- parent, inherited by every child minted under it — so the only
-- variable under test is the sidecar `file_repair` now writes.
local function test_a_minted_repair_is_offered_and_admitted()
  local s = init_state_repo("mint-admitted")
  local parent = check.must(item.decode({id = lanes.LANE_PARENT,
        title = "lane repair outcome"}))
  assert(store.save(s, parent, "new " .. parent.id:sub(1, 8) .. " lane repairs"))
  local peer_id = fixture.file_item(s, "a peer outcome", "")
  assert(cmp.cmd_compare(s, parent.id, peer_id) == 0,
    "compare should be accepted")

  assert(lanes.mint(s, RED))
  local all = check.must(store.list(s))
  local repair = repair_for(all, "release.yml")
  assert(repair ~= nil, "the red lane minted a repair")

  local specs: {string: string} = {}
  for _, it in ipairs(all) do
    specs[it.id] = store.read_spec(s, it.id)
  end
  local a = action.next_action(all, specs)
  assert(a.kind == "pull" and a.item.id == repair.id,
    "next offers the minted repair: " .. a.kind
    .. " " .. (a.item and a.item.id or ""))

  local problems = gate.ready_problems(s, repair, all)
  assert(#problems == 0,
    "take admits it too: " .. table.concat(problems, "; "))
  assert(flow.doing_refusal(all, repair) == nil,
    "and the doing bound never holds a lane repair back")
end
test_a_minted_repair_is_offered_and_admitted()
