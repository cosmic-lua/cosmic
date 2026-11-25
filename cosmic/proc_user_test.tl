local Proc = require("cosmic.proc")
local Test = require("cosmic.test")

-- The account file a lookup reads here. On Darwin it consults a directory
-- service too, which an unsandboxed worker reaches undeclared.
Test.policy{ grants = { { path = "/etc/passwd", letters = "r" } } }

local function test_user_resolves_root_and_copies_numeric_ids()
  local first, trouble = Proc.user("root")
  assert(first ~= nil, tostring(trouble))
  assert(first.uid == 0 and math.type(first.gid) == "integer")
  local second = assert(Proc.user("root"))
  assert(first ~= second and first.uid == second.uid and first.gid == second.gid)
  second.uid = 123 -- checked: field_fixed
  assert(first.uid == 0 and assert(Proc.user("root")).uid == 0)
  local fields = 0
  for key in pairs(first as {string:any}) do -- checked: cast_refused
    assert(key == "uid" or key == "gid", key)
    fields = fields + 1
  end
  assert(fields == 2)
end

--- A host may refuse its directory service when a name is not in its
--- local file; that remains an operating failure, not a missing account.
local function test_user_unknown_name_preserves_the_lookup_answer()
  local user, why = Proc.user("cosmic-test-absent-73c2a0b198")
  assert(user == nil and why.path == "cosmic-test-absent-73c2a0b198", tostring(why))
  local root, none = Proc.user("root")
  assert(root ~= nil and none == nil, tostring(none))
end

local function test_user_rejects_malformed_names()
  for _, name in ipairs({ "", "root\0suffix", "\0root" }) do
    Test.raises(function() local _, _ = Proc.user(name) end, "user name")
  end
end
