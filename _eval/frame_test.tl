local fs = require("cosmic.fs")
local check = require("cosmic.check")

local SKILL_PATH < const > = "skills/agent-eval/SKILL.md"
local FRAME_PATH < const > = "_eval/tasks/frame.md"
local HEADING < const > = "## The prompt template"

--- Extract SKILL.md's fenced prompt template: the content between the
--- first ``` fence after the "## The prompt template" heading and its
--- closing ```. Located by the fence, not by hardcoding the template's
--- own bytes, so this test fails loudly (missing heading/fence) rather
--- than silently passing on an edited SKILL.md.
--- @return string The fenced block's content, trailing newline kept
local function skill_fenced_template(): string
  local body = check.must(fs.read(SKILL_PATH))
  local heading_at = body:find(HEADING, 1, true)
  assert(heading_at ~= nil, SKILL_PATH .. ": missing '" .. HEADING .. "' heading")
  local fence_start = body:find("```\n", heading_at, true)
  assert(fence_start ~= nil, SKILL_PATH .. ": missing opening fence after the heading")
  local content_start = fence_start + 4
  local fence_end = body:find("\n```", content_start, true)
  assert(fence_end ~= nil, SKILL_PATH .. ": missing closing fence")
  return body:sub(content_start, fence_end)
end

local function test_frame_byte_equals_skill_template()
  local frame = check.must(fs.read(FRAME_PATH))
  local want = skill_fenced_template()
  assert(frame == want,
    "_eval/tasks/frame.md must be byte-identical to " .. SKILL_PATH ..
    "'s fenced prompt template (the copy has drifted)")
end
test_frame_byte_equals_skill_template()

print("OK frame_test")
