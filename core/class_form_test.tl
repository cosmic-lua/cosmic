--- The reserved form the patched Lua parser (patch/lua/) reads for the code the compiler writes for a class:
--- `{ ... } @ C` makes the table the constructor makes with the table `C` as its metatable, and `@v` is the
--- metatable of `v`. A chunk loaded from text reaches both, which a program written in Teal cannot spell.
local Test = require("cosmic.test")

Test.policy{}

--- Runs `source` as a chunk and answers what it returns.
local function run(source: string): any, any, any, any, any, any
  local env: {string: any} = { setmetatable = setmetatable, tostring = tostring, string = string, print = print }
  local chunk, why = load(source, "=class_form", "t", env)
  assert(chunk ~= nil, tostring(why))
  return chunk()
end

local function test_a_constructor_followed_by_at_and_a_name_is_a_table_with_that_table_as_its_metatable()
  local method, same, other = run([[
local C = {}; C.__index = C
function C.get(self) return self.n end
local v = { n = 7 } @ C
local w = {} @ C
return v:get(), @v == C and @w == C, @{} == C
]])
  assert(method == 7 and same == true and other == false)
end

local function test_the_class_table_is_the_metatable_of_what_it_is_given_to()
  local shown, closed = run([[
local C = {}; C.__index = C
function C.__tostring(self) return "C#" .. self.n end
function C.__close(self) self.log[#self.log + 1] = "closed " .. self.n end
local log = {}
do
  local a <close> = { n = 1, log = log } @ C
  local b <close> = { n = 2, log = log } @ C
  log[#log + 1] = tostring(a) .. tostring(b)
end
return log[1], log[2] .. "," .. log[3]
]])
  assert(shown == "C#1C#2" and closed == "closed 2,closed 1", tostring(shown) .. " " .. tostring(closed))
end

local function test_the_class_may_be_a_local_an_upvalue_a_global_or_a_path_of_fields()
  local a, b, c, d = run([[
local C = {}; C.__index = C; C.name = "local"
local function make() return {} @ C end
G = {}; G.__index = G; G.name = "global"
local M = { K = {} }; M.K.__index = M.K; M.K.name = "path"
local D = { Inner = { Deep = {} } }; D.Inner.Deep.__index = D.Inner.Deep; D.Inner.Deep.name = "deep"
return make().name, ({} @ G).name, ({} @ M.K).name, ({} @ D.Inner.Deep).name
]])
  assert(a == "local" and b == "global" and c == "path" and d == "deep")
end

local function test_a_class_literal_is_an_expression_that_nests_and_stays_in_its_register()
  local sum, kinds, count = run([[
local A = {}; A.__index = A; function A.v(self) return self.x end
local B = {}; B.__index = B
local function pair(x, y) return x, y end
local t = { { x = 1 } @ A, { x = 2 } @ A, inner = { x = 3, nested = { x = 4 } @ A } @ A }
local first, second = pair({ x = 10 } @ A, { x = 20 } @ B)
local total = t[1]:v() + t[2]:v() + t.inner:v() + t.inner.nested:v() + first:v()
local n = 0
for i = 1, 100 do
  local item = { x = i } @ A
  n = n + item:v()
end
return total, (@first == A and @second == B and @t.inner == A), n
]])
  assert(sum == 1 + 2 + 3 + 4 + 10 and kinds == true and count == 5050, tostring(sum) .. " " .. tostring(count))
end

local function test_at_before_a_value_is_its_metatable_whatever_the_value_is()
  local table_mt, string_mt, number_mt, nil_mt, function_mt, boolean_mt = run([[
local C = {}
return @setmetatable({}, C) == C, (@"x").__index == string, @1 == nil, @nil, @print, @true
]])
  assert(table_mt == true, "a table has its own metatable")
  assert(string_mt == true, "a string has the one the string library gives it")
  assert(number_mt == true and nil_mt == nil and function_mt == nil and boolean_mt == nil)
end

local function test_at_binds_tighter_than_a_comparison_and_looser_than_a_call()
  local a, b, c = run([[
local C = {}; C.__index = C
local function make() return {} @ C end
return @make() == C, @(make()) == C, not (@make() ~= C)
]])
  assert(a == true and b == true and c == true)
end

local function test_a_class_that_is_no_table_is_an_error_naming_it()
  local ok, why = pcall(run, "local D = nil\nreturn {} @ D\n")
  assert(not ok and tostring(why):find("attempt to use as a class a nil value (local 'D')", 1, true) ~= nil, tostring(why))
  local again, trouble = pcall(run, "local D = 'text'\nreturn {} @ D\n")
  assert(not again and tostring(trouble):find("attempt to use as a class a string value", 1, true) ~= nil, tostring(trouble))
end

local function test_a_dumped_chunk_runs_after_it_is_loaded_and_names_the_format_of_the_machine_that_wrote_it()
  local chunk = assert(load("local C = {}; C.__index = C; C.m = function() return 1 end; return ({} @ C):m()", "=dump", "t", {}))
  local bytes = string.dump(chunk)
  -- the signature, the version, then the format byte: 1 where this machine's instructions follow Lua's
  assert(bytes:byte(5) == 0x55 and bytes:byte(6) == 1, "format " .. tostring(bytes:byte(6)))
  local again = assert(load(bytes, "=dump", "b", {}))
  assert(again() == 1)
  local official = bytes:sub(1, 5) .. string.char(0) .. bytes:sub(7)
  local loaded, why = load(official, "=dump", "b", {})
  assert(loaded == nil and tostring(why):find("format mismatch", 1, true) ~= nil, tostring(why))
end

local function test_the_form_needs_a_constructor_before_the_at_and_a_class_after_it()
  local bad = { "return @", "return {} @", "return 1 @ C", "local C = {}\nreturn {} @ C()\n", "return {} @ 1", "return ({}) @ C" }
  local refused = 0
  for _, source in ipairs(bad) do
    local chunk = load(source, "=bad", "t", {})
    if chunk == nil or not pcall(chunk) then
      refused = refused + 1
    end
  end
  assert(refused == #bad, "a form was taken: " .. (#bad - refused))
end
