--- Tests of the facts and the lengths of arrays a flow state holds ([`lang.flow`]), on the states themselves:
--- [`lang.check_flow_test`] has the programs they decide.
local Flow = require("lang.flow")
local Test = require("cosmic.test")
local Types = require("lang.types")

Test.policy{}

local store = Types.new()

--- `f` with the place `key` narrowed to a boolean, which was declared an integer.
local function narrowed(f: Flow.State, key: string): Flow.State
  return Flow.narrow(f, key, store.boolean, store.integer)
end

local function test_forget_lengths_takes_the_lengths_away_again_on_a_state_changed_after_the_first_call()
  local known = Flow.know_length(Flow.start(), "1", 2, store.boolean, store.integer)
  assert(Flow.knows_length(known, "1", 2))
  local once = Flow.forget_lengths(known)
  assert(not Flow.knows_length(once, "1", 1) and not Flow.knows_length(once, "1", 2))
  -- A fact of a length gained after the first call is gone at the second, on the state the call returned or another.
  local again = Flow.know_length(narrowed(once, "2.a"), "3", 1, store.boolean, store.integer)
  assert(Flow.knows_length(again, "3", 1))
  local twice = Flow.forget_lengths(again)
  assert(not Flow.knows_length(twice, "3", 1))
  assert(Flow.get(twice, "2.a") ~= nil, "a fact of a field is not of a length")
  assert(Flow.forget_lengths(twice) == twice, "a state with none is answered as it is")
  -- The state that was given is not written to: the call before it, on it, leaves it as it was.
  assert(Flow.knows_length(again, "3", 1))
  assert(Flow.knows_length(known, "1", 2))
end

local function test_forget_lengths_after_assignments_and_joins_that_drop_some_of_the_lengths()
  local both = Flow.know_length(Flow.know_length(narrowed(Flow.start(), "4.a"), "5", 2, store.boolean, store.integer),
    "6", 1, store.boolean, store.integer)
  -- An assignment to the array takes its facts away; the facts of the other array are still lengths to forget.
  local assigned = Flow.assign(both, 5, nil)
  assert(not Flow.knows_length(assigned, "5", 1) and Flow.knows_length(assigned, "6", 1))
  assert(not Flow.knows_length(Flow.forget_lengths(assigned), "6", 1))
  -- A join keeps the lengths both edges hold, and the result forgets them as a state of its own.
  local other = Flow.know_length(narrowed(Flow.start(), "4.a"), "6", 1, store.boolean, store.integer)
  local joined = Flow.join(both, other, function(a)
    return a
  end, function()
    return false
  end)
  assert(Flow.knows_length(joined, "6", 1) and not Flow.knows_length(joined, "5", 1))
  local forgot = Flow.forget_lengths(joined)
  assert(not Flow.knows_length(forgot, "6", 1) and Flow.get(forgot, "4.a") ~= nil)
  -- A function made at the point does not inherit the lengths, and the state before it still has them.
  assert(not Flow.knows_length(Flow.enter(both, nil), "6", 1) and Flow.knows_length(both, "6", 1))
  -- A state with no fact at all, and one whose last fact of a length an assignment took, are returned as they are.
  local last = Flow.assign(Flow.know_length(Flow.start(), "7", 1, store.boolean, store.integer), 7, nil)
  assert(Flow.forget_lengths(last) == last)
end

local function test_a_state_of_many_narrowed_places_keeps_each_fact_and_shares_the_states_before_it()
  local states: mut {Flow.State} = { Flow.start() }
  for i = 1, 100 do
    local next_state = narrowed(states[#states]!, "1.f" .. tostring(i))
    states[#states + 1] = next_state
  end
  local last = states[#states]!
  for i = 1, 100 do
    assert(Flow.fact(last, "1.f" .. tostring(i)) ~= nil, "the fact of field " .. tostring(i))
  end
  -- Each state before it holds the facts up to its own, and none after: no narrowing wrote to it.
  local middle = states[51]!
  assert(Flow.fact(middle, "1.f50") ~= nil and Flow.fact(middle, "1.f51") == nil)
  assert(Flow.has_facts(middle) and not Flow.has_facts(states[1]!))
  -- A place narrowed again holds the newer type, and its state counts it once.
  local again = Flow.narrow(last, "1.f7", store.string, store.integer)
  assert(Flow.fact(again, "1.f7")!.type == store.string and Flow.fact(last, "1.f7")!.type == store.boolean)
  assert(again.facts.count == 100)
  -- A place narrowed back to its declared type has no fact, and the others stay.
  local back = Flow.narrow(again, "1.f7", store.integer, store.integer)
  assert(Flow.fact(back, "1.f7") == nil and Flow.fact(back, "1.f8") ~= nil and back.facts.count == 99)
  -- An assignment takes every path from the local away.
  assert(not Flow.has_facts(Flow.assign(last, 1, nil)))
end

local function test_a_join_keeps_the_places_both_edges_hold_whichever_holds_fewer()
  local base = narrowed(narrowed(Flow.start(), "1.a"), "1.b")
  local many = base
  for i = 1, 40 do
    many = narrowed(many, "1.f" .. tostring(i))
  end
  local few = narrowed(base, "2")
  local function same_type(a: Types.Type): Types.Type
    return a
  end
  local function never(): boolean
    return false
  end
  for _, joined in ipairs({ Flow.join(many, few, same_type, never), Flow.join(few, many, same_type, never) }) do
    assert(joined.facts.count == 2 and Flow.fact(joined, "1.a") ~= nil and Flow.fact(joined, "1.b") ~= nil)
    assert(Flow.fact(joined, "1.f1") == nil and Flow.fact(joined, "2") == nil and joined.paths == 2)
    assert(Flow.same(joined, base))
  end
  -- Edges that share their facts join to them, the paths counted as they were.
  local twin = Flow.know_length(many, "3", 1, store.boolean, store.integer)
  local shared = Flow.join(many, twin, same_type, never)
  assert(shared.facts == many.facts and shared.paths == many.paths)
end
