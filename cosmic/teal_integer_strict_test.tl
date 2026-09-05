#!/usr/bin/env cosmic
--- The integer-strict half of the carried tl patch: gate OFF (the
--- tree's default) must leave `narrowed_declaration` byte-for-byte
--- unaffected; gate ON must refuse a `number`-declared local carrying
--- an integer literal wherever `integer` is later required. Split
--- from teal_test.tl by convention (a new gate gets its own canary),
--- not by the line cap.

local env = require("cosmic.env")
local fs = require("cosmic.fs")
local teal = require("cosmic.teal")

local tmpdir = os.getenv("TEST_TMPDIR")

-- Gate off (the tree's default, no env.set at all): the laundering is
-- unpatched-visible behavior, so this must still check clean.
local function test_gate_off_leaves_narrowing_unpatched()
  local path = fs.join(tmpdir, "integer_strict_off.tl")
  assert(fs.write(path, [[
local n: number = 3
local j: integer = n
print(j)
]]))
  local result = teal.check_file(path)
  local msgs = {}
  for _, e in ipairs(result.errors) do
    msgs[#msgs + 1] = e.message
  end
  assert(result.ok,
    "gate off must leave narrowed_declaration unpatched: "
    .. table.concat(msgs, "; "))
end

-- Gate on: the same source must now be refused, by the EXISTING stock
-- is_a(number, integer) check -- no new error message, just the
-- laundering removed so the check sees the operand honestly.
local function test_gate_on_refuses_laundered_integer()
  local saved = env.get("COSMIC_INTEGER_STRICT")
  local ok, err = env.set("COSMIC_INTEGER_STRICT", "1", true)
  assert(ok, err)
  local pok, perr = pcall(function(): boolean
      local path = fs.join(tmpdir, "integer_strict_on.tl")
      assert(fs.write(path, [[
local n: number = 3
local j: integer = n
print(j)
]]))
      local result = teal.check_file(path)
      local msgs = {}
      for _, e in ipairs(result.errors) do
        msgs[#msgs + 1] = e.message
      end
      local joined = table.concat(msgs, "; ")
      assert(not result.ok,
        "gate on must refuse a number-declared local narrowed by an integer literal")
      assert(joined:find("got number, expected integer", 1, true),
        "must be the stock is_a(number, integer) refusal: " .. joined)
      return true
    end)
  if saved then
    assert(env.set("COSMIC_INTEGER_STRICT", saved, true))
  else
    assert(env.unset("COSMIC_INTEGER_STRICT"))
  end
  if not pok then
    error(perr, 0)
  end
end
