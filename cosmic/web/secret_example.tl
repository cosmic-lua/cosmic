--- Worked examples for [`cosmic.web.secret`], shown by `cosmic docs` under
--- the symbol each one demonstrates and run by `cosmic test` like any other
--- test.

local Secret = require("cosmic.web.secret")

local Example = {}

--- A fresh key to put in an environment variable, and the check a key must
--- pass.
function Example.generate()
  local key = Secret.generate()
  print(#key, Secret.check(key))
  assert(#key == 64 and Secret.check(key))
  local ok, why = Secret.check("changeme")
  print(why)
  assert(not ok)
end

--- A rotation list, newest first: the first key signs and all verify.
function Example.parse_keys()
  local new, old = Secret.generate(), Secret.generate()
  local keys = assert(Secret.parse_keys(new .. "," .. old, "SESSION_KEYS"))
  print(#keys)
  assert(#keys == 2 and keys[1] == new and keys[2] == old)
end

--- A variable that is not set is a refusal, never a default key.
function Example.keys_from_env()
  local keys, why = Secret.keys_from_env("COSMIC_EXAMPLE_KEYS_NOT_SET")
  print(why)
  assert(keys == nil)
  assert(why:find("not set", 1, true))
end

return Example
