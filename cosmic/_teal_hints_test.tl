#!/usr/bin/env cosmic
--- reads: _build/testdata/gotchas
-- `cosmic._teal_hints.hint_for_message` is what `--check types` actually
-- calls (`cosmic.teal`'s `format_issues` wires it in) — the 13 hand
-- patterns run BEFORE the `cosmic._teal_symptoms` fall-through, so a
-- pattern that matches a message a gotcha section also documents can
-- shadow the section's hint forever, silently, even while
-- `_teal_symptoms_test.tl` (which calls the fall-through module
-- directly, skipping the hand patterns) stays green. This test goes
-- through the real entry point against the real fixtures, so a
-- shadowing hand pattern fails here instead of shipping quietly.

local hints = require("cosmic._teal_hints")
local teal = require("cosmic.teal")

local FIXTURE_DIR < const > = "_build/testdata/gotchas"

--- Every hint `hints.hint_for_message` produces for a fixture's issues.
--- @param path string Path to a Teal fixture
--- @return {string}
local function hints_for_fixture(path: string): {string}
  local result = teal.check_file(path)
  local out: {string} = {}
  for _, issue in ipairs(result.errors) do
    local hint = hints.hint_for_message(issue.message)
    if hint then
      out[#out + 1] = hint
    end
  end
  return out
end

-- Three sections whose sole checker-message shape used to be
-- intercepted by an older hand pattern that returns before the
-- fall-through: the ipairs-on-`any` branch of Pattern 4a, the
-- `cannot index` + `| nil` branch of Pattern 2b, and the
-- `unknown type %w+%.%w+` branch of Pattern 2d. Each must now name its
-- own section instead of the bare `guide.checking` pointer (or no
-- pointer at all, for the any-from-json-decode branch).
local function test_previously_shadowed_sections_now_name_themselves()
  local cases < const >: {{string, string}} = {
    {"any-from-json-decode.tl", "any-from-json-decode"},
    {"record-fields-dont-narrow.tl", "record-fields-dont-narrow"},
    {"exported-record-types.tl", "exported-record-types"},
  }
  for _, case in ipairs(cases) do
    local fixture_name, want_slug = case[1], case[2]
    local path = FIXTURE_DIR .. "/" .. fixture_name
    local produced = hints_for_fixture(path)
    assert(#produced > 0, path .. ": no hint produced at all")

    local named_section = false
    for _, hint in ipairs(produced) do
      if hint:find("section " .. want_slug, 1, true) then
        named_section = true
      end
    end
    assert(named_section, path .. ": no hint from `_teal_hints.hint_for_message` " ..
      "names section '" .. want_slug .. "' -- got:\n  " ..
      table.concat(produced, "\n  "))
  end
end

-- A hand pattern with a real fix still wins over the fall-through when
-- the two message shapes are genuinely different traps, e.g. the
-- plain number/integer mismatch (Pattern 1) is untouched by any of the
-- three fixes above.
local function test_unrelated_hand_pattern_is_unaffected()
  local hint = hints.hint_for_message("got number, expected integer")
  assert(hint, "expected a hint for the number/integer pattern")
  assert(hint:find("math.tointeger", 1, true),
    "unrelated hand pattern changed shape: " .. tostring(hint))
end

print("all teal hints tests passed")
