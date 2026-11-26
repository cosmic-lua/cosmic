--- Tests of the cuts a refusal makes to the types it shows ([`lang.near_names`]).
local NearNames = require("lang.near_names")
local Test = require("cosmic.test")

Test.policy{}

local function check(text: string, most: integer, wanted: string)
  local got = NearNames.cut_signature(text, most)
  assert(got == wanted, got)
  assert(#got <= most, tostring(#got))
end

local function test_a_function_type_keeps_its_first_parameters_and_its_returns()
  check("function(path: string, mode: integer): string", 100, "function(path: string, mode: integer): string")
  check("function(path: string, mode: integer): string", 35, "function(path: string, ...): string")
  check("function(path: string, mode: integer): string", 25, "function(...): string")
  -- A comma in a parameter's own type is no end of it.
  check("function<T>(xs: {string: T}, f: function(a: T, b: T): T, n: integer): {T}", 50,
    "function<T>(xs: {string: T}, ...): {T}")
end

local function test_an_optional_function_type_is_cut_inside_its_parentheses()
  check("(function(path: string, mode: integer): string)?", 38, "(function(path: string, ...): string)?")
end

local function test_a_type_whose_returns_do_not_fit_or_that_is_no_function_is_cut_at_its_end()
  check("function(): string, integer, boolean", 20, "function(): strin...")
  check("{string: integer}", 8, "{stri...")
  check("function(path: string, mode: integer): string", 2, "")
end
