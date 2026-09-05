#!/usr/bin/env cosmic
-- `cosmic._teal_symptoms` against the real embedded guide: the four
-- messages from a classic four-trap file each get a hint naming the
-- right section, a message no section claims gets none, and a
-- malformed symptom block is skipped rather than thrown.

local symptoms = require("cosmic._teal_symptoms")

-- Measured against `--check types` on a small file mixing a {integer}
-- array indexed by a number, `ipairs` over `json.decode`'s `any`, an
-- unrelated cascading reference, and a one-value function captured
-- into two locals (docs/agent-usability.md's four-trap fixture).
local function test_four_trap_messages_each_name_their_section()
  local cases < const >: {{string, string}} = {
    {"cannot index object of type {integer} with number", "integer-vs-number"},
    {"attempting ipairs on something that's not an array: <any type>",
      "any-from-json-decode"},
    {"assignment in declaration did not produce an initial value for variable 'b'",
      "multi-return-capture"},
  }
  for _, case in ipairs(cases) do
    local msg, want_slug = case[1], case[2]
    local hint = symptoms.hint_for_message(msg)
    assert(hint, "expected a hint for: " .. msg)
    assert(hint:find(want_slug, 1, true),
      "wrong section for '" .. msg .. "': " .. tostring(hint))
  end
end

-- The fourth message from the same file — a cascading reference to a
-- name the failed `ipairs` loop never bound — is not itself a trap any
-- section documents; no symptom line should claim it.
local function test_unclaimed_message_gets_no_hint()
  assert(symptoms.hint_for_message("unknown variable: k") == nil)
  assert(symptoms.hint_for_message("a message no gotcha documents") == nil)
end

-- Malformed input is skipped, never thrown: an unterminated fence
-- contributes nothing, a heading with no fence contributes nothing,
-- and a well-formed block elsewhere in the same text still parses.
local function test_malformed_block_is_skipped_not_thrown()
  local text = table.concat({
      "## unterminated-slug",
      "",
      "```text",
      "some shape that never closes",
      "",
      "## bare-heading-slug",
      "",
      "prose with no fence at all.",
      "",
      "## well-formed-slug",
      "",
      "```text",
      "a distinctive real shape",
      "```",
      "",
      "prose.",
    }, "\n")

  local ok, shapes = pcall(symptoms.parse_shapes, text)
  assert(ok, "parse_shapes threw on malformed input: " .. tostring(shapes))

  local slugs: {string: boolean} = {}
  for _, shape in ipairs(shapes) do
    slugs[shape.slug] = true
  end
  assert(not slugs["unterminated-slug"],
    "an unterminated fence must contribute nothing")
  assert(not slugs["bare-heading-slug"],
    "a heading with no fence must contribute nothing")
  assert(slugs["well-formed-slug"],
    "a well-formed block elsewhere in the same text must still parse")
end

print("all teal symptoms tests passed")
