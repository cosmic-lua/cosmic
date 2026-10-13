--- The codes the carried checker gives the refusals that are no matter of
--- narrowing: each program is refused (or fails to parse) for the code
--- shown and no other, so a change in what the checker reports of a plain
--- mistake is made on purpose. The fuzz property of
--- build/checker_fuzz_test.tl keeps these programs' places well-formed;
--- build/teal_test.tl builds errors of its own, which no checker gave.
local Test = require("cosmic.test")
local teal = require("build.teal")
local type compiler = require("build.compiler")

-- The compiler is the tree's own checker, keyed by the core; nothing is read.
Test.policy{}

local built = { value = nil as compiler | nil }

--- What the checker says of `source`: `accepted`, `refused: ` and the codes
--- of its type errors, or `syntax: ` and those of its syntax errors, each
--- list sorted.
local function verdict(source: string): string
  local c = built.value or assert(teal.load(true))
  built.value = c
  local env = assert(c.new_env({ defaults = { feat_lax = "off", gen_compat = "off", gen_target = "5.4" } }))
  local code, result = c.gen(source, env, nil, "tl")
  local codes: {string} = {}
  for _, e in ipairs(code == nil and result.syntax_errors or result.type_errors) do
    codes[#codes + 1] = tostring(e.code)
  end
  table.sort(codes)
  if code == nil then return "syntax: " .. table.concat(codes, ",") end
  if #codes == 0 then return "accepted" end
  return "refused: " .. table.concat(codes, ",")
end

local function gives(want: string, source: string)
  local got = verdict(source)
  assert(got == want, "wanted " .. want .. " but got " .. got .. " for:\n" .. source)
end

local head <const> = table.concat({
  "local record R",
  "  a: integer | nil",
  "  n: integer",
  "end",
  "local r: R = { n = 0 }",
  "local function maybe(): integer | nil return nil end",
  "local x: integer | nil = maybe()",
  "",
}, "\n")

local function test_a_program_that_does_not_parse_is_a_syntax_error()
  gives("syntax: other", "local x: integer =\n")
  gives("syntax: syntax_error", "if x then\n")
end

local function test_a_value_of_the_wrong_type_is_a_mismatch()
  gives("refused: mismatch", "local n: integer = \"a\"\nprint(n)\n")
end

local function test_a_name_that_is_not_declared_is_unknown()
  gives("refused: unknown_variable", "print(nope)\n")
  gives("refused: unknown_type", "local v: Nope = nil\nprint(v)\n")
end

local function test_a_call_with_too_many_arguments_is_an_arity_error()
  gives("refused: arity", "local function f(a: integer) print(a) end\nf(1, 2)\n")
end

local function test_a_key_the_record_lacks_is_an_invalid_key()
  gives("refused: invalid_key", head .. "r.zzz = 1\n")
end

local function test_ipairs_of_a_number_is_not_an_array()
  gives("refused: not_array,unknown_variable", "local n: integer = 1\nfor _, v in ipairs(n) do print(v) end\n")
end

local function test_an_optional_loop_bound_is_refused()
  gives("refused: for_bound", head .. "for i = x, 2 do print(i) end\n")
end

local function test_a_type_for_the_first_of_two_names_is_refused_not_raised()
  gives("refused: other,unknown_variable", "local x: integer | nil, y = 1, 2\nprint(x, y)\n")
end

local function test_an_optional_with_no_guard_is_no_number()
  gives("refused: operator_binary", head .. "print(x + 1)\n")
  gives("refused: operator_binary", head .. "if x or r.a then print(x + 1) end\n")
end
