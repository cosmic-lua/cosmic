#!/usr/bin/env cosmic
-- The stall verb converts "next handed out nothing" into one standing
-- board capture: created the first time, refreshed after, refused
-- whenever the board still has work — and blind to its own capture, or
-- "triage the stall record" would answer "are we stalled?".

local check = require("cosmic.check")
local fixture = require("_work.fixture")
local item = require("_work.item")
local stall = require("_work.gitstall")
local store = require("_work.store")

--- The open stall captures on a board.
local function captures(s: store.Store): {item.Item}
  local out: {item.Item} = {}
  for _, i in ipairs(check.must(store.list(s))) do
    if item.is_open(i) and i.title:find("flow stalled: ", 1, true) == 1 then
      out[#out + 1] = i
    end
  end
  return out
end

local function test_stall_records_once_and_refreshes_after()
  local s = fixture.init_state_repo("stall")
  -- An empty board hands out nothing, which is exactly a stall.
  assert(stall.cmd_stall(s) == 0, "an empty board records its stall")
  local first = captures(s)
  assert(#first == 1, "one standing capture: " .. #first)
  local body = store.read_spec(s, first[1].id)
  local _, lines = body:gsub("`gitboard next`", "")
  assert(lines == 1, "one evidence line: " .. body)
  local t = check.must(store.touched_at(s, first[1].id))
  assert(os.time() - t < 300, "touched_at reads the commit just made")
  assert(stall.cmd_stall(s) == 0, "a standing stall refreshes")
  local second = captures(s)
  assert(#second == 1, "still one capture: " .. #second)
  assert(second[1].id == first[1].id, "the same one")
  local grown = store.read_spec(s, second[1].id)
  local _, more = grown:gsub("`gitboard next`", "")
  assert(more == 2, "the refresh appends evidence: " .. grown)
end
test_stall_records_once_and_refreshes_after()

local function test_stall_is_refused_while_the_board_has_work()
  local s = fixture.init_state_repo("stall-busy")
  local _, leaf = fixture.root_with_leaf(s)
  assert(leaf ~= "", "fixture files a workable leaf")
  assert(stall.cmd_stall(s) ~= 0,
    "a plan item to refine means the board is not stalled")
  assert(#captures(s) == 0, "and nothing was recorded")
end
test_stall_is_refused_while_the_board_has_work()
