--- The kv task's hidden API test: eval/check/grade.tl runs it against
--- a copy of a solver's project, never shown to the solver.
local kv = require("kv")

local function keys_of(lru: kv.Lru<string, integer>): string
  return table.concat(lru:keys(), ",")
end

local function test_a_full_lru_evicts_the_least_recently_used()
  local lru: kv.Lru<string, integer> = kv.Lru.new(2)
  assert(lru:put("a", 1) == nil, "a put into room evicted something")
  assert(lru:put("b", 2) == nil, "a put into room evicted something")
  assert(lru:get("a") == 1, "get a")
  local gone, value = lru:put("c", 3)
  assert(gone == "b" and value == 2, "put c evicted " .. tostring(gone) .. "=" .. tostring(value))
  assert(lru:get("b") == nil, "b is still there")
  assert(keys_of(lru) == "a,c", "keys " .. keys_of(lru))
  assert(lru:len() == 2, "len " .. lru:len())
end

local function test_a_get_and_a_replacing_put_use_a_key()
  local lru: kv.Lru<string, integer> = kv.Lru.new(3)
  lru:put("a", 1)
  lru:put("b", 2)
  lru:put("c", 3)
  assert(keys_of(lru) == "a,b,c", "keys " .. keys_of(lru))
  assert(lru:get("a") == 1)
  assert(keys_of(lru) == "b,c,a", "after get a: " .. keys_of(lru))
  assert(lru:put("b", 20) == nil, "replacing b evicted something")
  assert(keys_of(lru) == "c,a,b", "after put b: " .. keys_of(lru))
  assert(lru:get("missing") == nil)
  assert(keys_of(lru) == "c,a,b", "a miss moved a key: " .. keys_of(lru))
  local gone = lru:put("d", 4)
  assert(gone == "c", "put d evicted " .. tostring(gone))
  assert(lru:get("b") == 20)
end

local function test_delete_frees_room_and_answers_whether_it_was_there()
  local lru: kv.Lru<string, integer> = kv.Lru.new(2)
  lru:put("a", 1)
  lru:put("b", 2)
  assert(lru:delete("a") == true, "delete a")
  assert(lru:delete("a") == false, "delete a twice")
  assert(lru:len() == 1)
  assert(lru:put("c", 3) == nil, "a put after a delete evicted something")
  assert(keys_of(lru) == "b,c", "keys " .. keys_of(lru))
end

local function test_an_lru_holds_any_key_and_value_types()
  local lru: kv.Lru<integer, {string}> = kv.Lru.new(1)
  lru:put(7, { "seven" })
  local gone, value = lru:put(8, { "eight" })
  assert(gone == 7 and value[1] == "seven", "evicted " .. tostring(gone))
  assert(lru:get(8)[1] == "eight")
  local keys: {integer} = lru:keys()
  assert(#keys == 1 and keys[1] == 8)
end

local function test_two_lrus_keep_apart()
  local one: kv.Lru<string, integer> = kv.Lru.new(1)
  local two: kv.Lru<string, integer> = kv.Lru.new(5)
  one:put("x", 1)
  two:put("y", 2)
  two:put("z", 3)
  assert(one:get("y") == nil and two:get("x") == nil)
  assert(one:len() == 1 and two:len() == 2)
end
