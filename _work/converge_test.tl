#!/usr/bin/env cosmic
-- Whether the ordering CONVERGES: not what it answers for one board,
-- which `action_test.tl` pins case by case, but what happens when a
-- session does what it says and asks again, from boards nobody wrote
-- by hand.
--
-- Two different claims. SAFETY: every action the ordering names is
-- one the verbs would carry out — no take the doing bound refuses, no
-- pull of something blocked or bar-failing, no claim of another
-- session's live work. LIVENESS: a board holding only finishable work
-- drains to nothing. Safety without liveness refuses everything;
-- liveness without safety is the livelock this file keeps out, where
-- `next` names an action, the gate rejects it, and the answer repeats.
--
-- The driver applies an action the way the verbs do and through the
-- same gates they call (`flow.doing_refusal`, the bar), so the
-- refusal asserted here is the real one. It carries no git plumbing:
-- a mutation is a table write, not a commit, which lets a walk run
-- hundreds of steps. `gitverbs_test.tl` proves the plumbing.

local check = require("cosmic.check")
local act = require("_work.action")
local flow = require("_work.flow")
local gate = require("_work.gitgate")
local item = require("_work.item")
local ksuid = require("_work.ksuid")

local type Item = item.Item

local counter = 0

--- A fresh deterministic id; later calls sort later, so creation order
--- is age order exactly as live ksuids behave.
local function fresh_id(): string
  counter = counter + 1
  return check.must(ksuid.encode(1700000000 + counter, ("\0"):rep(16)))
end

--- One valid item.
local function make(over: {string: any}): Item
  local t: {string: any} = {id = fresh_id(), title = "item"}
  for k, v in pairs(over or {}) do
    t[k] = v
  end
  return check.must(item.decode(t))
end

local READY < const > = "## Change\nDo this.\n## Non-goals\nNot that.\n"
.. "## Acceptance\n`ci`\n"

--- A seeded generator, written out rather than taken from `math`, so a
--- failing walk replays from its seed on any build.
local record Rng
  state: integer
end

--- @param seed integer The seed
--- @return Rng The generator
local function rng(seed: integer): Rng
  return {state = seed % 2147483647 + 1}
end

--- The next value in 1..n.
--- @param r Rng The generator
--- @param n integer The upper bound, at least 1
--- @return integer A value in 1..n
local function roll(r: Rng, n: integer): integer
  r.state = (r.state * 48271) % 2147483647
  return r.state % n + 1
end

--- The board's whole observable state, so a step that changed nothing
--- reads as a repeat rather than a walk running out its budget. Item
--- order is creation order, so list order is already stable; the spec
--- map joins it because refinement is a spec write.
--- @param items {Item} All items
--- @param specs act.Specs Sidecar body by id
--- @return string The signature
local function signature(items: {Item}, specs: act.Specs): string
  local parts: {string} = {}
  for _, i in ipairs(items) do
    parts[#parts + 1] = ("%s:%s:%s:%s:%d:%s:%d:%d"):format(i.id:sub(1, 8),
      (i.parent or ""):sub(1, 8), i.resolution or "", i.claim or "",
      i.pr or 0, i.verdict or "", #(i.blocked_by or {}),
      #(specs[i.id] or ""))
  end
  return table.concat(parts, "|")
end

--- Carry out one action the way the verbs do, mutating `items` and
--- `specs`, and return what went wrong so a caller asserts on nil
--- rather than finding a silent no-op several steps later.
--- @param items {Item} All items, appended to by intake
--- @param specs act.Specs Sidecar body by id
--- @param a act.Action The action to carry out
--- @param session string The acting session
--- @param r Rng The generator, consulted for the review verdict
--- @return string | nil What refused it, nil when it was carried out
local function apply(items: {Item}, specs: act.Specs, a: act.Action,
    session: string, r: Rng): string | nil
  local it = a.item
  if a.kind == "finish" then
    local sub = flow.substate(it)
    if sub == "accepted" then
      it.resolution = "completed"
      it.claim = ""
      return nil
    end
    if sub == "rework" then
      -- The rework hands back on the same PR: the verdict re-opens.
      it.claim = session
      it.verdict = ""
      return nil
    end
    -- A build in progress hands over: the claim moves to the actor
    -- (a stale takeover is this same write) and the PR is opened.
    it.claim = session
    it.pr = 7
    return nil
  end
  if a.kind == "review" then
    -- Three verdicts; a walk that only ever accepts never exercises
    -- the rework or reject paths the ordering has to pick back up.
    local kind = roll(r, 6)
    if kind == 1 then
      it.verdict = "request changes"
    elseif kind == 2 then
      it.claim = ""
      it.pr = 0
      it.verdict = ""
    else
      it.verdict = "accept"
    end
    it.reviewer = ""
    return nil
  end
  if a.kind == "pull" then
    local no = flow.doing_refusal(items)
    if no then
      return no
    end
    it.claim = session
    return nil
  end
  if a.kind == "refine" then
    -- Refinement is a spec write: the sidecar reaches the bar.
    if #flow.ready_gaps(specs[it.id] or "") == 0 then
      return "refine offered a spec already passing the bar"
    end
    specs[it.id] = READY
    return nil
  end
  if a.kind == "triage" then
    -- Adoption under a placed root, which is the branch of triage that
    -- keeps an item alive; `attach` is ungated, so neither is this.
    local placed = flow.roots(items)
    if #placed == 0 then
      it.resolution = "not-planned"
      return nil
    end
    it.parent = placed[1].id
    gate.containered(placed[1])
    return nil
  end
  if a.kind == "intake" then
    if it == nil then
      return "advice"
    end
    local born = make({parent = it.id})
    items[#items + 1] = born
    gate.containered(it)
    return nil
  end
  if a.kind == "unblock" then
    -- The walk resolves a stall the way a session's `unblock` does
    -- after judging the recorded reasons: edges waiting on the named
    -- chain root are dropped. The verb is ungated, so neither is this.
    for _, i in ipairs(items) do
      local kept: {string} = {}
      for _, b in ipairs(i.blocked_by or {}) do
        if b ~= it.id then
          kept[#kept + 1] = b
        end
      end
      i.blocked_by = kept
    end
    return nil
  end
  return ("unhandled action kind: %s"):format(a.kind)
end

--- A board nobody wrote by hand: three roots chained by comparisons so
--- every one is placed, leaves scattered across the states, most specs
--- already at the bar, a few blocker edges and foreign claims, and a
--- couple of unplaced captures for the triage queue.
--- @param r Rng The generator
--- @param leaves integer How many workable leaves to scatter
--- @param session string The session the walk will ask as
--- @return {Item} A legal board
--- @return act.Specs The sidecars
local function generate(r: Rng, leaves: integer,
    session: string): {Item}, act.Specs
  local alone = roll(r, 3) == 1
  local roots: {Item} = {make({}), make({}), make({})}
  roots[1].beats = {roots[2].id}
  roots[2].beats = {roots[3].id}
  local items: {Item} = {roots[1], roots[2], roots[3]}
  local specs: act.Specs = {}
  local workable: {Item} = {}
  for _ = 1, leaves do
    local parent = roots[roll(r, #roots)]
    local shape = roll(r, 6)
    local over: {string: any} = {parent = parent.id}
    local who = roll(r, 4)
    local name = (alone or who == 1) and session
    or ("wake-%d"):format(roll(r, 3))
    -- Shapes 1-2 are todo; 3 builds, 4 reviews, 5 reworks, 6 stands
    -- accepted — but never past the doing bound, or the generator
    -- would hand the ordering a board the verbs could not have made.
    local doing = 0
    for _, i in ipairs(items) do
      if item.is_open(i) and flow.is_doing(i) then
        doing = doing + 1
      end
    end
    if shape >= 3 and doing >= flow.DOING_LIMIT then
      shape = roll(r, 2)
    end
    if shape == 3 then
      over.claim = name
    elseif shape == 4 then
      over.claim = name
      over.pr = 7
    elseif shape == 5 then
      over.claim = name
      over.pr = 7
      over.verdict = "request changes"
    elseif shape == 6 then
      over.claim = name
      over.pr = 7
      over.verdict = "accept"
    end
    local leaf = make(over)
    items[#items + 1] = leaf
    workable[#workable + 1] = leaf
    if roll(r, 5) > 1 then
      specs[leaf.id] = READY
    end
  end
  for _ = 1, roll(r, 4) do
    local waiter = workable[roll(r, #workable)]
    local on = workable[roll(r, #workable)]
    if waiter.id ~= on.id and #waiter.blocked_by == 0 then
      waiter.blocked_by = {on.id}
    end
  end
  for _ = 1, roll(r, 3) do
    items[#items + 1] = make({})
  end
  return items, specs
end

-- SAFETY. Over boards nobody wrote by hand, every action the ordering
-- names is one the verbs would carry out, and carrying it out moves
-- the board. That second half rules out the livelock: an action
-- leaving the board where it stands comes back identical.
local function test_no_walk_ever_names_an_action_the_gates_refuse()
  for seed = 1, 40 do
    local r = rng(seed)
    local items, specs = generate(r, 18, "wake-0")
    for step = 1, 150 do
      local session = ("wake-%d"):format(step // 3)
      local a = act.next_action(items, specs, session)
      if a.kind == "none" or a.item == nil then
        break
      end
      local index = flow.by_id(items)
      if a.kind == "pull" then
        assert(not flow.is_blocked(a.item, index),
          ("seed %d: pulled a blocked item"):format(seed))
        assert((a.item.claim or "") == "" and (a.item.pr or 0) == 0,
          ("seed %d: pulled in-flight work"):format(seed))
        assert(#flow.ready_gaps(specs[a.item.id] or "") == 0,
          ("seed %d: pulled past the spec bar"):format(seed))
        assert(flow.doing_refusal(items) == nil,
          ("seed %d: pulled past the doing bound"):format(seed))
      end
      if a.kind == "finish" and flow.substate(a.item) ~= "accepted" then
        local mine = (a.item.claim or "") == ""
        or a.item.claim == session
        assert(mine, ("seed %d: finished another session's live claim")
          :format(seed))
      end
      local before = signature(items, specs)
      local bad = apply(items, specs, a, session, r)
      assert(bad == nil, ("seed %d step %d: %s was refused: %s"):format(
          seed, step, a.kind, bad or ""))
      assert(signature(items, specs) ~= before,
        ("seed %d step %d: %s moved nothing"):format(seed, step, a.kind))
    end
  end
end

-- SAFETY, the solo case. One session for the whole walk is the
-- narrowest board there is: it builds, judges what stands for review,
-- and drains what it fills, all under one name. Every answer it gets
-- must still be one it can act on, and acting on it must still move
-- the board.
local function test_a_solo_session_never_names_an_answer_it_cannot_act_on()
  for seed = 1, 25 do
    local r = rng(seed + 900)
    local items, specs = generate(r, 30, "solo")
    for step = 1, 200 do
      local a = act.next_action(items, specs, "solo")
      if a.kind == "none" or a.item == nil then
        break
      end
      local before = signature(items, specs)
      local bad = apply(items, specs, a, "solo", r)
      assert(bad == nil, ("seed %d step %d: %s was refused: %s"):format(
          seed, step, a.kind, bad or ""))
      assert(signature(items, specs) ~= before,
        ("seed %d step %d: %s moved nothing"):format(seed, step, a.kind))
    end
  end
end

--- Who acts next: whoever owns unfinished in-flight work, and a fresh
--- wake only when nobody does. A claim has no expiry, so work a
--- session took and did not finish is actionable by that name alone,
--- and draining needs it back.
--- @param items {Item} All items
--- @param wake integer The next fresh wake number
--- @return string The session that acts
local function actor(items: {Item}, wake: integer): string
  for _, i in ipairs(items) do
    if item.is_open(i) and (i.claim or "") ~= "" then
      return i.claim
    end
  end
  return ("wake-%d"):format(wake)
end

-- LIVENESS. A board whose work is all finishable drains to nothing.
-- The second root is CLOSED: it places the first through the
-- comparison without being an open root itself, which would draw an
-- intake before the first's subtree had finished.
local function test_a_finishable_board_drains_to_nothing()
  for seed = 1, 12 do
    local r = rng(seed + 500)
    local spent = make({resolution = "completed"})
    local root = make({beats = spent.id})
    local items: {Item} = {spent, root}
    local specs: act.Specs = {}
    local children: {Item} = {}
    for _ = 1, 6 do
      local leaf = make({parent = root.id})
      items[#items + 1] = leaf
      children[#children + 1] = leaf
    end
    local steps = 0
    local wake = 0
    local idle = 0
    for step = 1, 400 do
      steps = step
      local session = actor(items, wake)
      local a = act.next_action(items, specs, session)
      -- An `intake`, or nothing at all, ends a WAKE rather than the
      -- walk: the next one is a different session, and what this one
      -- left standing is the first thing it sees. Two idle wakes in a
      -- row is the board having nothing left.
      if a.kind == "none" or a.kind == "intake" or a.item == nil then
        if idle >= 1 then
          break
        end
        idle = idle + 1
        wake = wake + 1
      else
        idle = 0
        local bad = apply(items, specs, a, session, r)
        assert(bad == nil, ("seed %d step %d: %s was refused: %s"):format(
            seed, step, a.kind, bad or ""))
        if roll(r, 3) == 1 then
          wake = wake + 1
        end
      end
    end
    assert(steps < 400, ("seed %d: the walk never settled"):format(seed))
    for _, c in ipairs(children) do
      assert(not item.is_open(c),
        ("seed %d: %s never finished, left %s"):format(
          seed, c.id:sub(1, 8),
          flow.is_doing(c) and flow.substate(c) or "todo"))
    end
  end
end

-- Rework is its builder's while the claim is live: the board cannot
-- see a builder's build-test-push loop, so liveness is the lease's to
-- judge, the same as any other claim. A rework whose claimant stopped
-- waking surfaces when the lease expires, as a takeover.
local function test_a_rework_is_its_builders_until_the_lease_expires()
  local spent = make({resolution = "completed"})
  local root = make({beats = spent.id})
  local reworking = make({parent = root.id, claim = "session-A",
      pr = 7, verdict = "request changes", verdict_head = "abc123"})
  local items: {Item} = {spent, root, reworking}
  local specs: act.Specs = {[reworking.id] = READY}
  local builder = act.next_action(items, specs, "session-A")
  assert(builder.kind == "finish" and builder.item.id == reworking.id,
    "the builder picks its own rework up: " .. builder.kind)
  local other = act.next_action(items, specs, "session-B")
  assert(other.kind ~= "finish",
    "a live rework claim holds like any other: " .. other.kind)
  local stale: {string: integer} = {[reworking.id] = 5 * 60 * 60}
  local takeover = act.next_action(items, specs, "session-B", stale)
  assert(takeover.kind == "finish" and takeover.item.id == reworking.id,
    "a stale rework claim is anyone's: " .. takeover.kind)
end
