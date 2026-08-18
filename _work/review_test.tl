#!/usr/bin/env cosmic
-- What a pull request must be before a reviewer is handed it. Pure
-- over a fetched request, so these run with no token and no network —
-- which is the point of splitting the judgment from the fetching.

local review = require("_work.review")

local ID < const > = "3I1J6VKzSO5y7dsunDY7fBwFdUz"

--- An open, non-draft request whose body carries the item; `over`
--- replaces any field.
local function pull(over: {string: any}): review.Pull
  local p: review.Pull = {
    number = 42,
    draft = false,
    body = "Board: " .. ID .. "\n\nthe fix, and how it was run.",
    head_sha = "cafe1234",
    state = "open",
  }
  for k, v in pairs(over or {}) do
    if k == "number" and v is integer then p.number = v end
    if k == "draft" and v is boolean then p.draft = v end
    if k == "body" and v is string then p.body = v end
    if k == "state" and v is string then p.state = v end
  end
  return p
end

local function test_a_sound_request_passes()
  assert(review.blocks_check(pull({}), ID) == nil,
    "open, offered, and joined to its item")
end
test_a_sound_request_passes()

local function test_a_draft_is_not_ready_to_read()
  local msg = review.blocks_check(pull({draft = true}), ID)
  assert(msg ~= nil and msg:find("draft", 1, true), "got: " .. tostring(msg))
end
test_a_draft_is_not_ready_to_read()

local function test_a_closed_request_carries_nothing()
  local msg = review.blocks_check(pull({state = "closed"}), ID)
  assert(msg ~= nil and msg:find("closed", 1, true), "got: " .. tostring(msg))
end
test_a_closed_request_carries_nothing()

local function test_a_body_that_names_no_item_is_unjoined()
  local msg = review.blocks_check(pull({body = "a fix"}), ID)
  assert(msg ~= nil and msg:find("Board:", 1, true), "got: " .. tostring(msg))
end
test_a_body_that_names_no_item_is_unjoined()

-- The short form is what a human writes and what the skill's PR
-- convention shows, so it has to join the request too.
local function test_an_eight_character_prefix_joins_it()
  local short = pull({body = "Board: " .. ID:sub(1, 8)})
  assert(review.blocks_check(short, ID) == nil,
    "the prefix names the item as well as the full id does")
end
test_an_eight_character_prefix_joins_it()

local function test_a_concluded_failure_blocks()
  local msg = review.blocks_on_ci({
      {name = "ci", status = "completed", conclusion = "success"},
      {name = "build", status = "completed", conclusion = "failure"},
    })
  assert(msg ~= nil and msg:find("build", 1, true), "got: " .. tostring(msg))
end
test_a_concluded_failure_blocks()

-- Silence is not success, but it is not failure either: a run still
-- going is a reason to come back, never a reason to refuse.
local function test_running_and_absent_checks_do_not_block()
  assert(review.blocks_on_ci({}) == nil, "no runs yet")
  assert(review.blocks_on_ci({
        {name = "ci", status = "in_progress", conclusion = ""},
      }) == nil, "a run in flight")
  assert(review.blocks_on_ci({
        {name = "ci", status = "completed", conclusion = "cancelled"},
      }) == nil, "a cancelled run concluded nothing about the code")
end
test_running_and_absent_checks_do_not_block()
