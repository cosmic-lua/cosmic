#!/usr/bin/env cosmic
-- What a pull request must be before a reviewer is handed it. Pure
-- over a fetched request, so these run with no token and no network —
-- which is the point of splitting the judgment from the fetching.

local review = require("_work.review")
local spec = require("_work.spec")

local ID < const > = "3I1J6VKzSO5y7dsunDY7fBwFdUz"

--- An open, non-draft request whose body carries the item and the one
--- acceptance command; `over` replaces any field.
local function pull(over: {string: any}): review.Pull
  local p: review.Pull = {
    number = 42,
    draft = false,
    body = "Board: " .. ID .. "\n\n`bin/cosmic --make ci` ends ci: PASS",
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

local COMMANDS: {string} = {"bin/cosmic --make ci"}

local function test_a_sound_request_passes()
  assert(review.blocks_check(pull({}), ID, COMMANDS) == nil,
    "open, offered, joined to its item, quoting its command")
end
test_a_sound_request_passes()

local function test_a_draft_is_not_ready_to_read()
  local msg = review.blocks_check(pull({draft = true}), ID, COMMANDS)
  assert(msg ~= nil and msg:find("draft", 1, true), "got: " .. tostring(msg))
end
test_a_draft_is_not_ready_to_read()

local function test_a_closed_request_carries_nothing()
  local msg = review.blocks_check(pull({state = "closed"}), ID, COMMANDS)
  assert(msg ~= nil and msg:find("closed", 1, true), "got: " .. tostring(msg))
end
test_a_closed_request_carries_nothing()

local function test_a_body_that_names_no_item_is_unjoined()
  local msg = review.blocks_check(pull({body = "a fix"}), ID, COMMANDS)
  assert(msg ~= nil and msg:find("Board:", 1, true), "got: " .. tostring(msg))
end
test_a_body_that_names_no_item_is_unjoined()

-- The short form is what a human writes and what the skill's PR
-- convention shows, so it has to join the request too.
local function test_an_eight_character_prefix_joins_it()
  local short = pull({body = "Board: " .. ID:sub(1, 8)
      .. "\n`bin/cosmic --make ci`"})
  assert(review.blocks_check(short, ID, COMMANDS) == nil,
    "the prefix names the item as well as the full id does")
end
test_an_eight_character_prefix_joins_it()

local function test_an_unquoted_acceptance_command_blocks()
  local msg = review.blocks_check(pull({body = "Board: " .. ID}), ID, COMMANDS)
  assert(msg ~= nil and msg:find("Acceptance", 1, true),
    "got: " .. tostring(msg))
  assert(msg:find("bin/cosmic --make ci", 1, true), "and names one: " .. msg)
end
test_an_unquoted_acceptance_command_blocks()

local function test_a_spec_with_no_commands_asks_for_nothing()
  assert(review.blocks_check(pull({body = "Board: " .. ID}), ID, {}) == nil,
    "nothing to quote is not a refusal")
end
test_a_spec_with_no_commands_asks_for_nothing()

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

-- An Acceptance section quotes commands AND the verdict lines they
-- print; only the first kind is something a PR body must show.
local function test_acceptance_commands_are_the_commands_only()
  local body = [[
## Acceptance
- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -c '^test_' _work/stats_test.tl` returns `12`.
- the new entry appears under `_work/stats.tl`.
]]
  local got = spec.acceptance_commands(body)
  assert(#got == 2, "got " .. #got .. ": " .. table.concat(got, " | "))
  assert(got[1] == "bin/cosmic --make ci", "got: " .. got[1])
  assert(got[2]:find("^grep %-c") ~= nil, "got: " .. got[2])
end
test_acceptance_commands_are_the_commands_only()

local function test_acceptance_commands_read_only_that_section()
  local body = "## Change\n`bin/cosmic --make build`\n## Acceptance\n"
  .. "`bin/cosmic --make ci`\n## Non-goals\n`bin/cosmic --make docs`\n"
  local got = spec.acceptance_commands(body)
  assert(#got == 1 and got[1] == "bin/cosmic --make ci",
    "got: " .. table.concat(got, " | "))
end
test_acceptance_commands_read_only_that_section()
