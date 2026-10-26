local FieldPath = require("cosmic.internal.field_path")
local Sandbox = require("cosmic.sandbox")

local function test_a_path_runs_from_the_root_by_member_and_element()
  local rows = FieldPath.field(FieldPath.root, "rows")
  assert(rows == "$.rows", rows)
  assert(FieldPath.field(FieldPath.index(rows, 2), "id") == "$.rows[1].id")
  assert(FieldPath.index(FieldPath.root, 1) == "$[0]")
end

local function test_a_key_that_is_no_identifier_is_quoted_as_json_quotes_it()
  assert(FieldPath.field("$", "a b") == '$["a b"]')
  assert(FieldPath.field("$", "1st") == '$["1st"]')
  assert(FieldPath.field("$", "") == '$[""]')
  assert(FieldPath.field("$", 'q"\\\n') == '$["q\\"\\\\\\u000a"]', FieldPath.field("$", 'q"\\\n'))
end

--- A policy failure names a key that is no identifier the way a Shape
--- failure does, whatever its bytes.
local function test_a_policy_failure_quotes_a_variable_name_that_is_no_identifier()
  local ok, why = Sandbox.check({ set_env = { ["A=B"] = "1" } })
  assert(not ok and why:find('^sandbox: %$%.set_env%["A=B"%]: ') ~= nil, why)
  ok, why = Sandbox.check({ set_env_digests = { ["A=\"B"] = string.rep("a", 64) } })
  assert(not ok and why:find('^sandbox: %$%.set_env_digests%["A=\\"B"%]: ') ~= nil, why)
end
