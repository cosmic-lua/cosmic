local Secret = require("cosmic.web.secret")

local GOOD <const> = "k3Jf9Lq0Zx7Rw2Ub8Tn5Vc1Hd6Ym4Ga0"

local function test_check_refuses_short_keys_naming_the_length_not_the_key()
  local ok, why = Secret.check("hunter2-hunter2")
  assert(not ok and why:find("15 bytes", 1, true) ~= nil, why)
  assert(not why:find("hunter2", 1, true), "the key is not in the message")
  assert(Secret.check(("x"):rep(31)) == false)
end

local function test_check_refuses_low_variety_keys()
  local ok, why = Secret.check(("a"):rep(64))
  assert(not ok and why:find("1 distinct", 1, true) ~= nil, why)
  assert(Secret.check(("changeme"):rep(8)) == false, "7 distinct values")
  assert(Secret.check("0123456789" .. ("0123456789"):rep(3)) == true, "10 distinct values is the floor")
end

local function test_check_accepts_a_generated_key_and_generate_differs()
  local first, second = Secret.generate(), Secret.generate()
  assert(#first == 64 and first:match("^%x+$") ~= nil)
  assert(first ~= second)
  assert(Secret.check(first))
  assert(Secret.check(GOOD))
end

local function test_parse_keys_splits_trims_and_orders_newest_first()
  local other = Secret.generate()
  local keys = assert(Secret.parse_keys(GOOD .. " , " .. other))
  assert(#keys == 2 and keys[1] == GOOD and keys[2] == other)
end

local function test_parse_keys_refuses_an_empty_weak_or_surplus_entry()
  local keys, why = Secret.parse_keys(GOOD .. ",,", "KEYS")
  assert(keys == nil and why:find("entry 2 of KEYS", 1, true) ~= nil, why)
  keys, why = Secret.parse_keys(GOOD .. ",short", "KEYS")
  assert(keys == nil and why:find("entry 2", 1, true) ~= nil and not why:find("short,", 1, true), why)
  local six: mut {string} = {}
  for i = 1, 6 do six[i] = Secret.generate() end
  keys, why = Secret.parse_keys(table.concat(six, ","))
  assert(keys == nil and why:find("at most 5", 1, true) ~= nil, why)
end

local function test_keys_from_env_names_an_unset_variable_and_has_no_default()
  local keys, why = Secret.keys_from_env("COSMIC_WEB_SECRET_TEST_UNSET")
  assert(keys == nil and why:find("COSMIC_WEB_SECRET_TEST_UNSET is not set", 1, true) ~= nil, why)
end
