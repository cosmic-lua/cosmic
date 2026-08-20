#!/usr/bin/env cosmic
-- Whether the ordering CONVERGES: not what it answers for one board,
-- which `action_test.tl` pins case by case, but what happens when a
-- session does what it says and asks again, over and over, from boards
-- nobody wrote by hand.
--
-- Two properties, and they are different claims. SAFETY: every action
-- the ordering names is one the verbs would carry out — no move the
-- WIP gate refuses, no verdict on the asking session's own work, no
-- promotion or pull of something an open blocker holds. LIVENESS: a
-- board that holds only finishable work drains to nothing, so the
-- ordering never gives up while work it could hand out remains.
--
-- Safety without liveness is a tool that refuses everything; liveness
-- without safety is the livelock this file exists to keep out, where
-- `next` names a move, the gate rejects it, the board does not move,
-- and the same answer comes back forever.
--
-- The driver here applies an action the way the verbs do and through
-- the same gate they call (`gitgate.wip_refusal`, `dephased_container`,
-- `rephased_parent`), so the refusal these tests assert against is the
-- real one. What it does NOT carry is the git plumbing: a mutation is
-- a table write rather than a commit, which is what lets a walk run
-- hundreds of steps in a test. `gitverbs_test.tl` is where the
-- plumbing itself is proved.

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
--- @param n integer The exclusive upper bound, at least 1
--- @return integer A value in 1..n
local function roll(r: Rng, n: integer): integer
  r.state = (r.state * 48271) % 2147483647
  return r.state % n + 1
end

--- The board's whole observable state, so a step that changed nothing
--- is visible as a repeat rather than as a walk that runs its budget
--- out. Item order is creation order and never changes, so
--- concatenating in list order is already stable.
--- @param items {Item} All items
--- @return string The signature
local function signature(items: {Item}): string
  local parts: {string} = {}
  for _, i in ipairs(items) do
    parts[#parts + 1] = ("%s:%s:%s:%s:%d"):format(i.id:sub(1, 8), i.phase or "",
      i.resolution or "", i.claim or "", #(i.blocked_by or {}))
  end
  return table.concat(parts, "|")
end

--- The refusal a phase move earns from the REAL gate, or nil when the
--- verbs would carry it out. Every move the driver makes goes through
--- here, which is what makes "the ordering never names a refused move"
--- a claim about the shipped gate rather than about a copy of it.
--- @param items {Item} All items
--- @param from string The phase left, nil for an entry
--- @param to string The phase entered
--- @return string | nil The refusal
local function refusal(items: {Item}, from: string, to: string): string | nil
  return gate.wip_refusal(flow.board(items), from, to)
end

--- Carry out one action the way the verbs do, mutating `items`.
--- Returns what went wrong, so a caller asserts on nil rather than
--- discovering a silent no-op several steps later.
--- @param items {Item} All items, appended to by intake
--- @param a act.Action The action to carry out
--- @param session string The acting session
--- @param r Rng The generator, consulted for the review verdict
--- @return string | nil What refused it, nil when it was carried out
local function apply(items: {Item}, a: act.Action, session: string,
    r: Rng): string | nil
  local it = a.item
  if a.kind == "finish" and it.phase == "land" then
    it.phase = ""
    it.resolution = "completed"
    gate.rephased_parent(it, items)
    return nil
  end
  if a.kind == "finish" then
    local no = refusal(items, "do", "check")
    if no then
      return no
    end
    it.phase = "check"
    it.pr = 7
    return nil
  end
  if a.kind == "review" then
    -- Three verdicts leave `check`; two of them go backwards, and a
    -- walk that only ever accepts never exercises the rework path the
    -- ordering has to pick back up.
    local to = "land"
    if roll(r, 4) == 1 then
      to = "do"
    end
    local no = refusal(items, "check", to)
    if no then
      return no
    end
    it.phase = to
    return nil
  end
  if a.kind == "pull" then
    local no = refusal(items, "ready", "do")
    if no then
      return no
    end
    it.phase = "do"
    it.claim = session
    return nil
  end
  if a.kind == "refine" then
    local no = refusal(items, "plan", "ready")
    if no then
      return no
    end
    it.phase = "ready"
    return nil
  end
  if a.kind == "triage" then
    -- Adoption under a placed root, which is the branch of triage that
    -- keeps an item alive; `attach` is not WIP-gated, so neither is
    -- this.
    local placed = flow.roots(items)
    if #placed == 0 then
      it.resolution = "not-planned"
      return nil
    end
    it.parent = placed[1].id
    it.phase = "plan"
    gate.dephased_container(placed[1])
    return nil
  end
  if a.kind == "intake" then
    local no = refusal(items, nil, "plan")
    if no then
      return no
    end
    local born = make({parent = it.id, title = "slice", phase = "plan"})
    items[#items + 1] = born
    gate.dephased_container(it)
    return nil
  end
  if a.kind == "unblock" then
    -- The walk resolves the starvation the way a session's `unblock`
    -- does after judging the recorded reasons: the edges waiting on
    -- the named chain root are dropped. The verb is not WIP-gated, so
    -- neither is this.
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
--- every one of them is placed, leaves scattered across the phases
--- within their limits, a few blocker edges and a few foreign claims,
--- and a couple of unplaced captures for the triage queue to hold.
--- Some claims are the asking session's own, because a phase full of
--- work the asker may not judge is a STARTING state rather than one a
--- walk arrives at: the ordering finishes a `do` item into `check`
--- before pulling another, so `do` empties as `check` fills and a walk
--- never holds both at once.
--- @param r Rng The generator
--- @param leaves integer How many workable leaves to scatter
--- @param session string The session the walk will ask as
--- @return {Item} A legal board
local function generate(r: Rng, leaves: integer, session: string): {Item}
  -- Some boards are the asking session's ALONE. Drawing each claim
  -- independently makes "every item in `check` is mine" vanishingly
  -- rare at ten items, and that is precisely the state where no
  -- verdict the asker may write drains the phase it is filling.
  local alone = roll(r, 3) == 1
  local roots: {Item} = {make({}), make({}), make({})}
  roots[1].beats = {roots[2].id}
  roots[2].beats = {roots[3].id}
  local items: {Item} = {roots[1], roots[2], roots[3]}
  local workable: {Item} = {}
  for _ = 1, leaves do
    local parent = roots[roll(r, #roots)]
    local phase = item.PHASES[roll(r, #item.PHASES)]
    -- Generate a LEGAL board: the walk has to start inside the limits
    -- or the first assertion is about this function, not the ordering.
    if #(flow.board(items)[phase] or {}) >= flow.LIMITS[phase] then
      phase = "plan"
    end
    if #(flow.board(items)[phase] or {}) < flow.LIMITS[phase] then
      local over: {string: any} = {parent = parent.id, phase = phase}
      if phase == "do" or phase == "check" then
        local who = roll(r, 4)
        if alone or who == 1 then
          over.claim = session
        elseif who < 4 then
          over.claim = ("wake-%d"):format(roll(r, 3))
        end
        if phase == "check" then
          over.pr = 7
        end
      end
      local leaf = make(over)
      items[#items + 1] = leaf
      workable[#workable + 1] = leaf
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
  return items
end

--- The two ordinary STARTING moves, and whether either is open to this
--- session: an unblocked, unheld `ready` item with room for it in `do`
--- and room for its handover in `check`, or an unblocked `plan` item
--- with room in `ready`. Answering `none` while one of these stands is
--- the ordering giving up on work it could have handed out.
--- @param items {Item} All items
--- @param session string The asking session
--- @return string | nil What was open, nil when neither was
local function starting_work(items: {Item}, session: string): string | nil
  local b = flow.board(items)
  local index = flow.by_id(items)
  if #(b["do"] or {}) < flow.LIMITS["do"]
  and #(b["check"] or {}) < flow.LIMITS["check"] then
    for _, i in ipairs(b["ready"] or {}) do
      local held = (i.claim or "") ~= "" and i.claim ~= session
      if not held and not flow.is_blocked(i, index) then
        return ("ready item %s was pullable"):format(i.id:sub(1, 8))
      end
    end
  end
  if #(b["ready"] or {}) < flow.LIMITS["ready"] then
    for _, i in ipairs(b["plan"] or {}) do
      if not flow.is_blocked(i, index) then
        return ("plan item %s was refinable"):format(i.id:sub(1, 8))
      end
    end
  end
  return nil
end

-- SAFETY. Over boards nobody wrote by hand, every action the ordering
-- names is one the verbs would carry out, and carrying it out moves
-- the board. The second half is what rules out the livelock: an action
-- that leaves the board where it stands is an answer that will come
-- back identical next time it is asked.
local function test_no_walk_ever_names_a_move_the_gate_refuses()
  for seed = 1, 40 do
    local r = rng(seed)
    local items = generate(r, 18, "wake-0")
    for step = 1, 150 do
      -- A session per wake, not one for the whole walk: the claim rule
      -- routes a verdict away from the session that built the item, so
      -- a single name could never review anything and the walk would
      -- never reach `land`.
      local session = ("wake-%d"):format(step // 3)
      local a = act.next_action(items, session)
      if a.kind == "none" or a.item == nil then
        local open = starting_work(items, session)
        assert(open == nil, ("seed %d step %d: answered %s but %s"):format(
            seed, step, a.kind, open or ""))
        break
      end
      local index = flow.by_id(items)
      if a.kind == "review" then
        assert(a.item.claim ~= session,
          ("seed %d: handed its own work to review"):format(seed))
      end
      if a.kind == "pull" then
        assert(not flow.is_blocked(a.item, index),
          ("seed %d: pulled a blocked item"):format(seed))
        assert((a.item.claim or "") == "" or a.item.claim == session,
          ("seed %d: pulled another session's claim"):format(seed))
      end
      if a.kind == "refine" then
        assert(not flow.is_blocked(a.item, index),
          ("seed %d: refined a blocked item into ready"):format(seed))
      end
      if a.kind == "finish" and a.item.phase == "do" then
        assert((a.item.claim or "") == "" or a.item.claim == session,
          ("seed %d: finished another session's claim"):format(seed))
      end
      local before = signature(items)
      local bad = apply(items, a, session, r)
      assert(bad == nil, ("seed %d step %d: %s was refused: %s"):format(
          seed, step, a.kind, bad or ""))
      assert(signature(items) ~= before,
        ("seed %d step %d: %s moved nothing"):format(seed, step, a.kind))
    end
  end
end
test_no_walk_ever_names_a_move_the_gate_refuses()

--- Who acts next: whoever owns an unfinished `do` claim, and a fresh
--- wake only when nobody does.
---
--- A claim has no expiry, so work a session PULLED and did not hand
--- over is actionable by that name alone, and draining needs it back.
--- Rework is not in that set — a non-accept verdict makes the item
--- anyone's, which is what `test_a_rework_is_offered_to_any_session`
--- pins — so this resumes a builder only for work still in progress.
--- The narrower this has to be, the less the walk assumes about the
--- sessions and the more of the drain the ORDERING is doing.
--- @param items {Item} All items
--- @param wake integer The next fresh wake number
--- @return string The session that acts
local function actor(items: {Item}, wake: integer): string
  for _, i in ipairs(items) do
    local verdict = i.verdict or ""
    if item.is_open(i) and i.phase == "do" and (i.claim or "") ~= ""
    and (verdict == "" or verdict == "accept") then
      return i.claim
    end
  end
  return ("wake-%d"):format(wake)
end

-- SAFETY, the solo case. One session for the whole walk is the state
-- the two halves of the claim rule meet in: it builds into `check`,
-- may not judge its own work, and so cannot drain the phase it is
-- filling. Once `check` is full every handover into it is refused, and
-- an ordering that still named one would repeat that answer forever.
-- The rotating walk above cannot reach this — its wakes review each
-- other's work and keep `check` moving.
local function test_a_solo_session_never_names_an_answer_it_cannot_act_on()
  for seed = 1, 25 do
    local r = rng(seed + 900)
    -- Enough leaves that `check` and `do` both reach their limits at
    -- generation: the stall needs a full `check` AND something in `do`
    -- at the same instant, which a smaller board never holds.
    local items = generate(r, 44, "solo")
    for step = 1, 200 do
      local a = act.next_action(items, "solo")
      if a.kind == "none" or a.item == nil then
        local open = starting_work(items, "solo")
        assert(open == nil, ("seed %d step %d: answered %s but %s"):format(
            seed, step, a.kind, open or ""))
        break
      end
      local before = signature(items)
      local bad = apply(items, a, "solo", r)
      assert(bad == nil, ("seed %d step %d: %s was refused: %s"):format(
          seed, step, a.kind, bad or ""))
      assert(signature(items) ~= before,
        ("seed %d step %d: %s moved nothing"):format(seed, step, a.kind))
    end
  end
end
test_a_solo_session_never_names_an_answer_it_cannot_act_on()

-- LIVENESS. A board whose work is all finishable drains to nothing.
-- The second root is CLOSED: it places the first through the
-- comparison without being an open root of its own, which would draw
-- an intake before the subtree under the first had finished.
--
-- A wake here ends only when it holds nothing in `do`, which is the
-- slice loop the skill describes — pull, build, hand over — rather
-- than an arbitrary cut. Rotating mid-slice would strand the claim and
-- prove nothing about the ORDERING, only that the claim gap is real,
-- which `_work.flow` already records.
local function test_a_finishable_board_drains_to_nothing()
  for seed = 1, 12 do
    local r = rng(seed + 500)
    local spent = make({resolution = "completed"})
    local root = make({beats = spent.id})
    local items: {Item} = {spent, root}
    local children: {Item} = {}
    for _ = 1, 6 do
      local leaf = make({parent = root.id, phase = "plan"})
      items[#items + 1] = leaf
      children[#children + 1] = leaf
    end
    local steps = 0
    local wake = 0
    local idle = 0
    for step = 1, 400 do
      steps = step
      local session = actor(items, wake)
      local a = act.next_action(items, session)
      -- An `intake`, or nothing at all, ends a WAKE rather than the
      -- walk: the next one is a different session, and the review this
      -- one was refused on its own work is the first thing it sees. Two
      -- idle wakes in a row is the board having nothing left.
      if a.kind == "none" or a.kind == "intake" or a.item == nil then
        if idle >= 1 then
          break
        end
        idle = idle + 1
        wake = wake + 1
      else
        idle = 0
        local bad = apply(items, a, session, r)
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
        ("seed %d: %s never finished, left in %s"):format(
          seed, c.id:sub(1, 8), c.phase == "" and "no phase" or c.phase))
    end
  end
end
test_a_finishable_board_drains_to_nothing()

-- Rework is anyone's. A `request changes` verdict returns the item to
-- `do` and leaves the claim naming who built it, so the claim alone
-- would make the rework actionable by one session and strand it — with
-- everything blocked on it — the moment that session stopped waking.
-- The claim still routes the next VERDICT away from the builder, which
-- is why the reason tells whoever takes it over to move the claim.
local function test_a_rework_is_offered_to_any_session()
  local root = make({})
  local reworking = make({parent = root.id, phase = "do", claim = "session-A",
      pr = 7, verdict = "request changes", verdict_head = "abc123",
      enable = "none: this item's own spec was the fault"})
  local items: {Item} = {root, reworking}
  local builder = act.next_action(items, "session-A")
  assert(builder.kind == "finish" and builder.item.id == reworking.id,
    "the builder may still pick its own rework up: " .. builder.kind)
  local other = act.next_action(items, "session-B")
  assert(other.kind == "finish" and other.item.id == reworking.id,
    "and so may anybody else: " .. other.kind)
  assert(other.reason:find("--claim session-B", 1, true),
    "who is told to take the claim with it: " .. other.reason)
  -- A claim with no verdict standing on it is work in progress, and
  -- that is still one session's.
  local fresh = make({parent = root.id, phase = "do", claim = "session-A"})
  local building: {Item} = {root, fresh}
  local nope = act.next_action(building, "session-B")
  assert(nope.kind ~= "finish",
    "work in progress stays its claimant's: " .. nope.kind)
end
test_a_rework_is_offered_to_any_session()
