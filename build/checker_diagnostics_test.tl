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
  local env = assert(c.new_env({ defaults = teal.defaults() }))
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

--- What `verdict` says of `source`, or the error the checker raised: a
--- program the checker cannot answer for must be refused, not raise.
local function verdict_or_raise(source: string): string
  local ok, got = pcall(verdict, source)
  return ok and got or "raised: " .. tostring(got)
end

local function test_a_u_escape_with_no_brace_is_a_syntax_error_not_a_raise()
  for _, source in ipairs({ "return \"\\ux\"", "local s = \"\\u\"", "return \"\\u12\"", "return '\\u'" }) do
    local got = verdict_or_raise(source)
    assert(got:sub(1, 7) == "syntax:", got .. " for: " .. source)
  end
end

local function test_a_u_escape_with_no_brace_is_reported_at_the_string()
  local c = built.value or assert(teal.load(true))
  built.value = c
  local env = assert(c.new_env({ defaults = teal.defaults() }))
  local code, result = c.gen("return \"\\ux\"", env, nil, "tl")
  assert(code == nil)
  local e = assert(result.syntax_errors[1])
  assert(e.msg == "malformed string", tostring(e.msg))
  assert(e.y == 1 and e.x == 8, tostring(e.y) .. ":" .. tostring(e.x))
end

local function test_a_well_formed_string_escape_is_accepted()
  for _, escape in ipairs({
      "\\x41", "\\u{41}", "\\u{0000000041}", "\\u{7FFFFFFF}", "\\255", "\\065", "\\z", "\\n",
  }) do
    for _, quote in ipairs({ "\"", "'" }) do
      gives("accepted", "return " .. quote .. escape .. quote)
    end
  end
end

local function test_a_malformed_string_escape_is_a_syntax_error_not_a_raise()
  for _, escape in ipairs({
      "\\x", "\\xg1", "\\x1", "\\x1g", "\\u", "\\u{", "\\u{}", "\\u{41", "\\u{4g}",
      "\\u{80000000}", "\\u{110000000000}", "\\u{FFFFFFFFFFFFFFFFFFFFF}", "\\256", "\\999", "\\q",
  }) do
    for _, quote in ipairs({ "\"", "'" }) do
      local source = "return " .. quote .. escape .. quote
      gives("syntax: other", source)
    end
    -- Unfinished: the string ends where the escape does.
    gives("syntax: other", "return \"" .. escape)
  end
  gives("syntax: other", "return \"\\")
end

local function test_an_argument_with_no_name_before_a_question_mark_is_refused_not_raised()
  for _, source in ipairs({ "function x~(?", "function*???", "function>+.?", "function f(?) end", "function f(a, ?) end" }) do
    local got = verdict_or_raise(source)
    assert(got:sub(1, 7) == "syntax:", got .. " for: " .. source)
  end
end

local function test_an_interface_list_that_ends_early_is_refused_not_raised()
  for _, source in ipairs({
      "record is", "local record R is", "local record R is end", "local interface I is end", "local record R is\nend", "local record R is A.", "local record R is A.x.", "local interface I is A.(",
      "local record R is a. end", "local record R is A.,", "local function f<T is>() end",
  }) do
    local got = verdict_or_raise(source)
    assert(got:sub(1, 7) == "syntax:", got .. " for: " .. source)
  end
end

local function test_a_close_local_of_an_unresolved_type_is_an_unknown_type_not_a_raise()
  gives("refused: unknown_type", "local function f(): r end\nlocal c <close> = f()\n")
  gives("refused: unknown_type", "local c <close> = (nil as r)\n")
end
