#!/usr/bin/env cosmic
-- `commit_and_publish` under a lost push race: the mutation is
-- dropped whole, the checkout re-synced, and the refusal is
-- `store.LOST_RACE` — never a replay of a commit whose preconditions
-- the winner may have falsified. The re-run is the verb's, and it
-- decides afresh against the merged board — where every gate,
-- the doing bound included, is re-applied. The ready bar's owner
-- rule on an item's own `repo` is the second half of this file; the
-- write-time half of the same rule is `_work/gitowner_test.tl`.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local fixture = require("_work.fixture")
local flow = require("_work.flow")
local gate = require("_work.gitgate")
local gitspec = require("_work.gitspec")
local graph = require("_work.gitgraph")
local item = require("_work.item")
local ksuid = require("_work.ksuid")
local owner = require("_work.gitowner")
local publish = require("_work.publish")
local store = require("_work.store")
local verbs = require("_work.gitverbs")

local init_shared = fixture.init_shared
local init_state_repo = fixture.init_state_repo

local counter = 0

--- A fresh deterministic id; later calls sort later.
local function fresh_id(): string
  counter = counter + 1
  return check.must(ksuid.encode(1700000000 + counter, ("\0"):rep(16)))
end

local PARENT = check.must(ksuid.encode(1690000000, ("\1"):rep(16)))

--- A minimal valid workable item — under a parent the store never
--- checks, the same convention `store_test.tl` uses.
local function make_item(over?: {string: any}): item.Item
  local t: {string: any} = {
    id = fresh_id(), title = "filler", parent = PARENT,
  }
  for k, v in pairs(over or {}) do
    t[k] = v
  end
  return check.must(item.decode(t))
end

-- A lost race is a refusal, not a replay: the commit is dropped, the
-- checkout holds the winner's state, and the refusal is LOST_RACE by
-- identity.
local function test_a_lost_race_drops_the_mutation_and_refuses()
  local a, b = init_shared("gate-lost")
  -- `a` moves the remote forward, so `b`'s push below is rejected
  -- against a remote it has not seen.
  local touched = make_item()
  assert(store.save(a, touched, "a moves the remote forward"))
  assert(publish.publish(a))

  local mine = make_item()
  local ok, err = gate.commit_and_publish(b, mine, "a spec touch",
    ("spec %s"):format(mine.id:sub(1, 8)))
  assert(not ok and err == store.LOST_RACE, "got: " .. tostring(err))
  local merged = check.must(store.list(b))
  assert(flow.by_id(merged)[touched.id] ~= nil,
    "the checkout was re-synced onto the winner's state")
  assert(flow.by_id(merged)[mine.id] == nil,
    "and the dropped mutation is gone whole")
end

-- The re-run is the compare-and-swap completing: the same mutation,
-- decided and committed again against the merged state, publishes.
local function test_the_rerun_publishes_against_the_merged_state()
  local a, b = init_shared("gate-rerun")
  local touched = make_item()
  assert(store.save(a, touched, "a moves the remote forward"))
  assert(publish.publish(a))

  local mine = make_item()
  local ok, err = gate.commit_and_publish(b, mine, "a spec touch",
    ("spec %s"):format(mine.id:sub(1, 8)))
  assert(not ok and err == store.LOST_RACE, "got: " .. tostring(err))
  local again, aerr = gate.commit_and_publish(b, mine, "a spec touch",
    ("spec %s"):format(mine.id:sub(1, 8)))
  assert(again, "the re-run publishes: " .. tostring(aerr))
  assert(publish.sync(a))
  assert(check.must(store.load(a, mine.id)).id == mine.id,
    "and the mutation reaches the remote")
end

-- What a re-run's take would see: the doing bound, applied to the
-- merged board — a board another session filled while this one was
-- deciding refuses the take the stale read would have admitted.
local function test_the_merged_board_carries_the_doing_bound()
  local a, b = init_shared("gate-bound")
  for k = 1, flow.DOING_LIMIT do
    assert(store.save(a, make_item({claim = ("wake-%d"):format(k)}),
        "filler " .. fresh_id():sub(1, 8)))
  end
  assert(publish.publish(a))
  assert(publish.sync(b))
  local merged = check.must(store.list(b))
  assert(flow.doing_refusal(merged) ~= nil,
    "a take against the merged board is the verb's to refuse")
end

-- A decomposition clears the locks on the item that became a
-- container: a claim or review standing on it locks nothing anyone
-- can build. The write travels with the child's commit, which is why
-- it is returned rather than saved.
local function test_containered_clears_the_locks()
  local untouched = make_item()
  assert(#gate.containered(untouched) == 0,
    "an unclaimed parent has nothing to clear")
  local held = make_item({claim = "session-A", reviewer = "review-1"})
  local out = gate.containered(held)
  assert(#out == 1 and out[1].claim == "" and out[1].reviewer == "",
    "the claim and the review clear together")
end

-- The take refusal counts what awaits a verdict by KIND: a research
-- handover outranking a take must be named "handover", never "diff"
-- — the noun `next`'s review reason already gets right (#1625).
local function test_review_debt_refusal_names_a_handover_not_a_diff()
  local handed = make_item({claim = "other", builders = "other",
      result = ("ab"):rep(32)})
  local taking = make_item()
  local refusal = gate.review_debt_refusal({handed, taking}, "me", taking)
  assert(refusal ~= nil, "the handover outranks the todo take")
  assert(refusal:find("1 handover(s) await a verdict", 1, true) ~= nil,
    "names it a handover: " .. tostring(refusal))
  assert(not refusal:find("diff", 1, true),
    "never calls a handover a diff: " .. refusal)
  local diffed = make_item({claim = "other", builders = "other", pr = 3})
  local diff_refusal = gate.review_debt_refusal({diffed, taking}, "me", taking)
  assert(diff_refusal:find("1 diff(s) await a verdict", 1, true) ~= nil,
    "a diff's wording is unchanged: " .. tostring(diff_refusal))
end

-- The distance guard: named on either involvement list refuses,
-- either half is enough, and an unnamed session is never involved.
local function test_distance_refusal_covers_builders_and_speccers()
  local built = make_item({builders = "me"})
  assert(gate.distance_refusal(built, "me") ~= nil, "a builder is refused")
  local specced = make_item({speccers = "me"})
  assert(gate.distance_refusal(specced, "me") ~= nil, "a speccer is refused")
  local stranger = make_item({builders = "someone-else"})
  assert(gate.distance_refusal(stranger, "me") == nil,
    "a session named on neither list is not refused")
  assert(gate.distance_refusal(stranger, "") == nil,
    "an unnamed session is never involved")
end

-- The one-claim-per-session guard: a live claim on ANOTHER open item
-- refuses; the item being claimed itself, and a session with no live
-- claim anywhere, are excluded.
local function test_second_claim_refusal_scopes_to_other_open_claims()
  local s = init_state_repo("gate-second-claim")
  local mine = make_item({claim = "me"})
  local theirs = make_item({claim = "someone-else"})
  local unclaimed = make_item()
  assert(store.save(s, mine, "fixture: mine"))
  assert(store.save(s, theirs, "fixture: theirs"))
  assert(store.save(s, unclaimed, "fixture: unclaimed"))
  local all = check.must(store.list(s))
  assert(gate.second_claim_refusal(s, all, unclaimed.id, "me") ~= nil,
    "a live claim on another item refuses")
  assert(gate.second_claim_refusal(s, all, mine.id, "me") == nil,
    "the item being claimed itself is excluded")
  assert(gate.second_claim_refusal(s, all, unclaimed.id, "someone-else") ~= nil,
    "symmetric for the other session")
  assert(gate.second_claim_refusal(s, all, unclaimed.id, "nobody-yet") == nil,
    "a session with no live claim anywhere is free to take")
end

local ACCESS_SPEC < const > = fixture.READY_SPEC
.. "## Access\n- whilp/cosmopolitan (the fork the diff deliberately targets)\n"

--- A spec sidecar with the given body, through the spec verb.
local function write_spec(s: store.Store, id: string, name: string,
    body: string)
  local path = fs.join(fixture.tmpdir, ("owner-%s.md"):format(name))
  assert(fs.write(path, body))
  assert(gitspec.cmd_spec(s, id, path) == 0, "spec should be accepted")
end

--- A workable, placed, specced leaf whose `repo` was written the way
--- stale data got there — straight into the file, past the verbs —
--- on a board that reads its origin as `cosmic-lua/cosmic`.
local function foreign_leaf(name: string, body: string): store.Store, string
  local s = init_shared("owner-" .. name)
  fixture.github_origin(s, "cosmic-lua/cosmic")
  local _, leaf = fixture.root_with_leaf(s)
  write_spec(s, leaf, name, body)
  local it = check.must(store.load(s, leaf))
  it.repo = "whilp/cosmopolitan"
  assert(store.save(s, it, "fixture: a repo written before the rule"))
  return s, leaf
end

-- The item's own `repo` under a foreign owner is a ready-bar problem
-- naming the field, the value and the repair, and the take is refused.
local function test_a_foreign_owner_repo_misses_the_bar()
  local s, leaf = foreign_leaf("foreign", fixture.READY_SPEC)
  local problems = gate.ready_problems(s, check.must(store.load(s, leaf)),
    check.must(store.list(s)))
  assert(#problems == 1, "one problem: " .. table.concat(problems, "; "))
  assert(problems[1]:find("repo: whilp/cosmopolitan", 1, true)
    and problems[1]:find(("gitboard set %s --repo cosmic-lua/cosmopolitan")
      :format(leaf:sub(1, 8)), 1, true),
    "the problem names the value and the repair: " .. problems[1])
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") ~= 0,
    "and the take is refused")
  assert(check.must(store.load(s, leaf)).claim == "", "nothing was written")
end

-- The same owner as the board passes, whatever the repository's name.
local function test_a_same_owner_repo_passes_the_bar()
  local s, leaf = foreign_leaf("same", fixture.READY_SPEC)
  assert(graph.cmd_set(s, leaf, nil, "cosmic-lua/cosmopolitan", nil) == 0,
    "the repair the problem names is accepted")
  local problems = gate.ready_problems(s, check.must(store.load(s, leaf)),
    check.must(store.list(s)))
  assert(#problems == 0, "a same-owner repo is no problem: "
    .. table.concat(problems, "; "))
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0,
    "and the take proceeds")
end

-- The deliberate cross-owner case: the spec names the slug under
-- `## Access`, and the field is accepted as stated.
local function test_a_foreign_owner_declared_under_access_passes_the_bar()
  local s, leaf = foreign_leaf("declared", ACCESS_SPEC)
  local problems = gate.ready_problems(s, check.must(store.load(s, leaf)),
    check.must(store.list(s)))
  assert(#problems == 0, "a declared cross-owner repo is no problem: "
    .. table.concat(problems, "; "))
  assert(verbs.cmd_take(s, leaf, "session-a", 0, false, "") == 0,
    "and the take proceeds")
end

-- A board with no GitHub origin has no owner to compare against and
-- skips the rule — the local-only waiver the handover gate uses.
local function test_a_board_with_no_origin_skips_the_owner_rule()
  local s = init_state_repo("owner-local")
  local _, leaf = fixture.root_with_leaf(s)
  write_spec(s, leaf, "local", fixture.READY_SPEC)
  local it = check.must(store.load(s, leaf))
  it.repo = "whilp/cosmopolitan"
  assert(store.save(s, it, "fixture: a repo on a local-only board"))
  assert(owner.board_owner(s) == nil, "no origin, no owner")
  local problems = gate.ready_problems(s, check.must(store.load(s, leaf)),
    check.must(store.list(s)))
  assert(#problems == 0, "nothing to compare against: "
    .. table.concat(problems, "; "))
end
