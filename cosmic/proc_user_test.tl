local Proc = require("cosmic.proc")
local Test = require("cosmic.test")

-- Account lookup can consult more than /etc/passwd, notably on Darwin.
Test.needs{ system = true }

local function test_user_resolves_root_and_copies_numeric_ids()
  local first, trouble = Proc.user("root")
  assert(first ~= nil, trouble)
  assert(first.uid == 0 and math.type(first.gid) == "integer")
  local second = assert(Proc.user("root"))
  assert(first ~= second and first.uid == second.uid and first.gid == second.gid)
  second.uid = 123
  assert(first.uid == 0 and assert(Proc.user("root")).uid == 0)
  local fields = 0
  for key in pairs(first as {string:any}) do
    assert(key == "uid" or key == "gid", key)
    fields = fields + 1
  end
  assert(fields == 2)
end

--- A host may refuse its directory service when a name is not in its
--- local file; that remains an operating failure, not a missing answer.
local function test_user_unknown_name_preserves_the_lookup_answer()
  local result = table.pack(Proc.user("cosmic-test-absent-73c2a0b198"))
  assert(result.n == 2 and result[1] == nil and type(result[2]) == "string")
  local success = table.pack(Proc.user("root"))
  assert(success.n == 2 and success[1] ~= nil and success[2] == "")
end

local function test_user_rejects_malformed_names()
  for _, name in ipairs({ "", "root\0suffix", "\0root" }) do
    local ok, trouble = pcall(Proc.user, name)
    assert(not ok and tostring(trouble):find("user name", 1, true))
  end
  assert(not pcall(Proc.user, 123 as string))
  assert(not pcall(Proc.user, {} as string))
end
