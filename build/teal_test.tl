--- Regression tests for [`build.teal.lazy`]: the capsule that loads the
--- compiler on first use has to behave as the compiler itself,
--- including for writes. tl reaches `search_module` and `path` through
--- its own module table, so an override `serve` writes has to land on
--- the loaded compiler rather than on the capsule; a capsule that kept
--- the write for itself would leave the checker searching the
--- filesystem.
local type compiler = require("build.compiler")
local Clock = require("cosmic.clock")
local teal = require("build.teal")

--- A field written through the capsule reaches the loaded compiler:
--- the capsule itself never holds it, and reading it back through the
--- capsule finds the written value, not the compiler's own.
local function test_lazy_write_lands_on_the_compiler()
  local built = teal.lazy()
  local marker = function(_name: string, _search_all: boolean): string | nil, any
    return nil
  end
  built.search_module = marker
  built.path = "lazy-test"
  assert(rawget(built as {any:any}, "search_module") == nil,
    "the capsule kept the write instead of passing it on")
  assert(rawget(built as {any:any}, "path") == nil)
  assert(built.search_module == marker)
  assert(built.path == "lazy-test")
end

--- A read through the capsule answers from the loaded compiler.
local function test_lazy_read_answers_from_the_compiler()
  local built = teal.lazy()
  assert(type(built.new_env) == "function")
  assert(type(built.gen) == "function")
end

--- Two capsules load two compilers: a write through one is not seen
--- through the other, the same as two [`teal.load`] calls.
local function test_lazy_capsules_are_independent()
  local first = teal.lazy()
  local second = teal.lazy()
  first.path = "first"
  second.path = "second"
  assert(first.path == "first")
  assert(second.path == "second")
end

local integer_msg = "in assignment: got number, expected integer"

--- What [`teal.replacement`] says for the first "got number, expected
--- integer" the checker reports for `source`, and where: nil when it
--- reports none, or the hint is nil.
local function hint_for(source: string): string | nil, string
  local built = assert(teal.load())
  local _, result = built.gen(source, nil, nil, "tl")
  for _, e in ipairs(result ~= nil and result.type_errors or {}) do
    if e.msg == integer_msg then
      return teal.replacement(e.msg, source, e.y, e.x), e.y .. ":" .. e.x
    end
  end
  return nil, "no such error"
end

--- What [`teal.replacement`] says of a number where an integer was
--- expected when no declaration explains it.
local converted = "'as integer' converts nothing: math.tointeger(x) does, " ..
  "and is nil unless x is whole; // of two integers is an integer"

local function said(name: string, line: integer, literal: string): string
  return name .. " is an integer, inferred from 'local " .. name .. " = " .. literal ..
    "' at line " .. line .. "; write 'local " .. name .. " = " .. literal ..
    ".0' or 'local " .. name .. ": number = " .. literal .. "' to hold a number"
end

--- An accumulator declared `local peak = 0` is told it was inferred an
--- integer, from which line, and the two spellings that hold a number.
local function test_an_integer_inferred_accumulator_names_the_fix()
  local source = "local n = 1\nlocal peak = 0\nfor _ = 1, n do\n  peak = peak + 1.5\nend\nprint(peak)\n"
  assert(hint_for(source) == said("peak", 2, "0"))
  assert(hint_for("local x = 0\nx = x / 2\nprint(x)\n") == said("x", 1, "0"))
  assert(hint_for("local x = 0\nx = 1.5\nprint(x)\n") == said("x", 1, "0"))
end

--- A literal with digit separators (patch/tl/38a) is quoted as written.
local function test_an_integer_hint_quotes_a_separated_literal()
  assert(hint_for("local x = 1_000\nx = x / 2\nprint(x)\n") == said("x", 1, "1_000"))
end

--- A trailing comment or semicolon on the declaration, an inner
--- function reading the outer local, and an `if` branch all resolve.
local function test_an_integer_hint_reads_the_declaration_through_the_parse()
  assert(hint_for("local x = 0 -- start\nx = x / 2\nprint(x)\n") == said("x", 1, "0"))
  assert(hint_for("local x = 0;\nx = x / 2\nprint(x)\n") == said("x", 1, "0"))
  assert(hint_for("local x = 0\nlocal function f()\n  if x then x = x / 2 end\nend\nf()\n") ==
      said("x", 1, "0"))
end

--- The name is resolved, not searched for: a same-named local of a
--- closed function or block, or in a string or a comment, is not the
--- declaration, and a parameter or loop variable is not one either:
--- each is told only the conversions.
local function test_an_integer_hint_names_the_declaration_in_scope()
  local closed = "local function f()\n  local n = 0\n  return n\nend\n" ..
    "local function g(n: integer): integer\n  n = n / 2\n  return n\nend\nprint(f(), g(1))\n"
  assert(hint_for(closed) == converted)
  local looped = "local n = 0\nlocal xs: {integer} = {}\nfor _, n in ipairs(xs) do\n" ..
    "  n = n / 2\nend\nprint(n)\n"
  assert(hint_for(looped) == converted)
  local block = "do\n  local n = 0\n  print(n)\nend\nlocal n: integer = 1\nn = n / 2\nprint(n)\n"
  assert(hint_for(block) == converted)
  local shadowed = "local n = 0\ndo\n  local n = 1\n  n = n / 2\n  print(n)\nend\nprint(n)\n"
  assert(hint_for(shadowed) == said("n", 3, "1"))
  local text = "local s = [[\nlocal q = 0\n]]\n-- local q = 0\nlocal q: integer = 1\nq = q / 2\nprint(s, q)\n"
  assert(hint_for(text) == converted)
end

--- No hint names a declaration falsely: an annotated or uninitialized
--- declaration, a computed initializer, several names, a field or a
--- multiple assignment is told only the conversions, and a neighbour
--- of a multiple assignment or a table's own `name = ...` line does not
--- stand for a declaration.
local function test_an_integer_hint_never_misleads()
  assert(hint_for("local x: integer = 0\nx = x / 2\nprint(x)\n") == converted)
  assert(hint_for("local x: integer\nx = 1\nx = x / 2\nprint(x)\n") == converted)
  assert(hint_for("local x = #arg\nx = x / 2\nprint(x)\n") == converted)
  assert(hint_for("local x, y = 0, 1\nx = x / 2\nprint(x, y)\n") == converted)
  assert(hint_for("local t = {n = 0}\nt.n = t.n + 0.5\nprint(t)\n") == converted)
  assert(hint_for("local a, b = 0, 0\na, b = 1.5, 2\nprint(a, b)\n") == converted)
  assert(hint_for("local a = 0\nlocal b = 0\nprint(a)\nlocal a2 = 1.5; b = b + 0.5\nprint(b, a2)\n") ==
      said("b", 2, "0"))
  assert(hint_for("local n = 0\nlocal t = {\n  n = 1,\n}\nn = n / 2\nprint(t, n)\n") ==
      said("n", 1, "0"))
  assert(teal.replacement("in assignment: got string, expected integer",
    "local x = 0\nx = 'a'\n", 2, 5) == nil)
end

--- An expression the checker reports at the target itself (a call, an
--- index) or inside parentheses is hinted like a binary one; a field
--- read through a record is no different.
local function test_an_integer_hint_reads_a_non_binary_right_hand_side()
  assert(hint_for("local x = 0\nlocal function f(): number\n  return 1.5\nend\nx = f()\nprint(x)\n") ==
      said("x", 1, "0"))
  assert(hint_for("local x = 0\nlocal t = {n = 1.5}\nx = t.n\nprint(x)\n") == said("x", 1, "0"))
  assert(hint_for("local x = 0\nx = (1.5)\nprint(x)\n") == said("x", 1, "0"))
end

--- `repeat ... until` bodies resolve their own locals; a method's
--- `self` is its own, whatever an outer local is called.
local function test_an_integer_hint_reads_repeat_and_method_scopes()
  assert(hint_for("local x = 0\nrepeat\n  x = x / 2\nuntil x < 1\nprint(x)\n") == said("x", 1, "0"))
  assert(hint_for("repeat\n  local x: integer = 0\n  x = x / 2\nuntil x < 1\nlocal x = 0\nprint(x)\n") ==
      converted)
  -- The checker refuses a method's `self` for another reason, so ask
  -- [`teal.replacement`] for the integer message at the literal's position.
  assert(teal.replacement(integer_msg,
    "local self = 0\nfunction R:m()\n  self = 1.5\nend\n", 3, 10) == converted)
end

--- The type errors the checker reports for `source`, failing the test
--- where it raises instead.
local function type_errors(source: string): {compiler.Error}
  local built = assert(teal.load())
  local ok, code, result = pcall(built.gen, source, nil, nil, "tl")
  assert(ok, tostring(code))
  return assert(result).type_errors
end

--- The checker's record for `_G` has the place it is read at (patch/tl's
--- 27-g-has-a-place.txt). Without one, an error about it -- reported,
--- or only tried, as narrowing a variable a loop assigns tries one --
--- failed an assertion instead.
local function test_g_is_checked_where_it_is_read()
  local errors = type_errors("local n: integer = _G\nprint(n)\n")
  assert(#errors == 1, tostring(#errors))
  assert(errors[1].y == 1 and errors[1].x == 20, errors[1].y .. ":" .. errors[1].x)
  assert(errors[1].msg:find("expected integer$") ~= nil, errors[1].msg)
  for _, found in ipairs(type_errors("local value: any = _G\nfor _ = 1, 2 do\n" ..
        "  if value is {any: any} then value = value[1] end\nend\n")) do
    assert(found.filename ~= nil and found.y ~= nil and found.x ~= nil, found.msg)
  end
end

--- What the parser refuses in `source`, each as "line:column message".
local function syntax_errors(source: string): {string}
  local built = assert(teal.load())
  local _, result = built.gen(source, nil, nil, "tl")
  local out: {string} = {}
  for _, e in ipairs(assert(result).syntax_errors) do
    out[#out + 1] = e.y .. ":" .. e.x .. " " .. e.msg
  end
  return out
end

--- A `return` closed by a `;` may end any block, as it may end the file
--- (patch/tl's 28-return-semicolon-before-end.txt), and a statement
--- after one is still refused.
local function test_a_return_closed_by_a_semicolon_ends_its_block()
  for _, source in ipairs({
      "local function f() return 1; end\n",
      "local function f() return; end\n",
      "if a then return 1; elseif b then return; else return 2; end\n",
      "repeat return; until a\n",
      "return 1;\n",
  }) do
    local found = syntax_errors(source)
    assert(#found == 0, source .. table.concat(found, "; "))
  end
  local found = syntax_errors("local function f() return 1; f() end\n")
  assert(#found > 0 and found[1]:find("return must be the last statement") ~= nil,
    table.concat(found, "; "))
end

--- A `(` on the line a string spanning lines ends on calls what the
--- string is an argument of, and one on a later line starts a new
--- statement, the `;` tl inserts there right after the string's last
--- byte (patch/tl's 29-call-after-a-token-spanning-lines.txt).
local function test_a_call_after_a_string_spanning_lines()
  local built = assert(teal.load())
  for _, source in ipairs({ "f [[a\nb]](1)\n", "f 'a\\z\n  b'(1)\n", "f [==[\n]==]{}(1)\n" }) do
    local found = syntax_errors(source)
    assert(#found == 0, source .. table.concat(found, "; "))
    local code = assert(built.gen(source, nil, nil, "tl"))
    assert(code:find(";", 1, true) == nil, code)
  end
  local tokens, errs = built.lex("f [[a\nbc]]\n(g)(1)\n", "t.tl")
  built.parse_program(tokens, errs, "t.tl")
  assert(#errs == 0, tostring(errs[1] and errs[1].msg))
  local inserted: compiler.Token = nil
  for _, t in ipairs(tokens) do
    if t.tk == ";" then inserted = t end
  end
  assert(inserted ~= nil and inserted.y == 2 and inserted.x == 5,
    inserted and inserted.y .. ":" .. inserted.x or "no ';'")
end

--- A function type's return types end before a `,` and a parameter
--- spelled `name?:`, `?T` or `...`, as before one spelled `name:`
--- (patch/tl's 30-return-types-end-before-a-parameter.txt); none of
--- those can start a type. A bare name after the `,` is still a second
--- return type.
local function test_return_types_end_before_the_next_parameter()
  for _, source in ipairs({
      "local function f(cb: function(): integer, n?: string) return cb, n end\n",
      "local function f(cb: function(): integer, ...: any) return cb end\n",
      "local function f(cb: function(): integer, ...) return cb end\n",
      "local type F = function(cb: function(): integer, n?: string)\n",
      "local type G = function(function(): integer, ?string)\n",
      "local type H = function(): integer...\n",
  }) do
    local found = syntax_errors(source)
    assert(#found == 0, source .. table.concat(found, "; "))
  end
  local built = assert(teal.load())
  local _, result = built.gen("local type F = function(cb: function(): integer, string)\n" ..
      "local f: F = function(_cb: function(): (integer, string)) end\nprint(f)\n", nil, nil, "tl")
  assert(#assert(result).syntax_errors == 0 and #result.type_errors == 0,
    tostring((result.type_errors[1] or result.syntax_errors[1] or {}).msg))
end

--- `record`, `interface` and `enum` name variables as well as start
--- types: one after `=` is read as the type syntax 0.7.1 dropped only
--- where a type body declaring something follows it (patch/tl's
--- 31a-old-type-syntax-needs-a-body.txt and 31b), so a loop's
--- `record` can be assigned, and the old declaration still says what
--- to write instead.
local function test_a_keyword_named_variable_is_no_old_type_declaration()
  local built = assert(teal.load())
  local code, result = built.gen("local rows = { 1 }\n" ..
      "for _, record in ipairs(rows) do\n" ..
      "  local category = record\n" ..
      "  local t = { v = record }\n" ..
      "  print(category, t.v)\n" ..
      "end\n", nil, nil, "tl")
  assert(#assert(result).syntax_errors == 0 and #result.type_errors == 0,
    tostring((result.syntax_errors[1] or result.type_errors[1] or {}).msg))
  local printed: {string} = {}
  local env = setmetatable({
    print = function(a: any, b: any) printed[#printed + 1] = tostring(a) .. " " .. tostring(b) end,
  } as {string:any}, { __index = _G as {string:any} })
  assert(load(assert(code), "repro", "t", env))()
  assert(printed[1] == "1 1" and #printed == 1, table.concat(printed, "; "))
  -- A look for a type body that fails leaves the tokens as they were
  -- for the expression: it rewrites a type argument list's `>>` to `>`,
  -- and inserts a `>` it misses at a line break.
  for _, case in ipairs({
      { "local record: A<A<integer>> | integer = 1\nlocal b = record is A<A<integer>>\n", "false" },
      { "local record = 1\nlocal b = record < n >> 1\n", "true" },
      { "local record = 1\nlocal b = record < n\nprint(b)\n", "true" },
      { "local function record(t: {boolean}): integer return #t end\n" ..
            "local b = record {\n  1 < n,\n  true\n}\n", "2" },
  }) do
    local case_code, checked = built.gen("local type A<T> = {T}\nlocal n = 4\n" .. case[1] .. "return tostring(b)\n",
      nil, nil, "tl")
    assert(#assert(checked).syntax_errors == 0 and #checked.type_errors == 0,
      case[1] .. tostring((checked.syntax_errors[1] or checked.type_errors[1] or {}).msg))
    local got = assert(load(assert(case_code), "case", "t", _G as {string:any}))()
    assert(got == case[2], case[1] .. tostring(got))
  end
  for _, word in ipairs({ "record", "interface", "enum" }) do
    for _, source in ipairs({
        "local x = WORD\nprint(x)\n",
        "local x = WORD.field\nprint(x)\n",
        "local x = WORD:method()\nprint(x)\n",
        "local x = WORD\nx:m()\n",
        "local x = WORD < 3, WORD > 2\nprint(x)\n",
        "local x = WORD is string\nprint(x)\n",
        "if WORD then local x = WORD end\n",
        "if WORD then local x = WORD is string end\n",
        "print(WORD)\n",
        "local t = { WORD }\nprint(t)\n",
        "local t = { v = WORD, w = 1 }\nprint(t)\n",
        "local t = { v = WORD \"a\" }\nprint(t)\n",
        "local b = WORD == nil\nprint(b)\n",
        "global g = WORD\n",
    }) do
      local found = syntax_errors((source:gsub("WORD", word)))
      assert(#found == 0, source:gsub("WORD", word) .. table.concat(found, "; "))
    end
  end
  for _, case in ipairs({
      { "local Point = record\n  x: number\nend\n", "use 'local record Point'" },
      { "global Point = record\n  x: number\nend\n", "use 'global record Point'" },
      { "local P = record <T>\n  x: T\nend\n", "use 'local record P'" },
      { "local I = interface\n  metamethod __call: function(I)\nend\n", "use 'local interface I'" },
      { "local E = enum\n  \"a\"\n  \"b\"\nend\n", "use 'local enum E'" },
      { "local t = { P = record\n  x: number\nend }\n", "declare nested record inside a record" },
      { "local t = { E = enum \"a\" end }\n", "declare nested enum inside a record" },
      { "local F = functiontype(number): string\n", "use 'local type F = function('" },
  }) do
    local found = syntax_errors(case[1])
    assert(found[1] ~= nil and found[1]:find(case[2], 1, true) ~= nil,
      case[1] .. table.concat(found, "; "))
  end
  for _, source in ipairs({
      "local functiontype = 1\nlocal f = functiontype\nprint(f)\n",
      "local functiontype = function(n: integer): integer return n end\nlocal f = functiontype(1)\nprint(f)\n",
  }) do
    local found = syntax_errors(source)
    assert(#found == 0, source .. table.concat(found, "; "))
  end
end

--- The look for an old type body costs what it reads, not the rest of
--- the file: a file naming `record` or `enum` on many lines, or in
--- nested functions, compiles in about the time of one naming a plain
--- variable. A look that read past its body, copied or shifted every
--- token, or parsed the function bodies in a `where` clause would grow
--- with the square of the lines or double with each level; one begun
--- within another would read each token through every look around it.
--- The bound is mostly on the ratio of two compiles of files alike in
--- length, so it holds on a slow core and a loaded host. Each shape is a
--- test of its own: together they compile fourteen files of thousands of
--- lines, which on the checked core passes a test's whole time.
local keyword_head = "local record, recd, enum, enmd, n, a = 1, 1, 1, 1, 2, 1\n" ..
  "local function where(_x: any) end\nlocal function b() end\n"

-- TODO: count the tokens a look reads, once patch/tl's look_ahead
-- reports them, and bound that count rather than compile times, which
-- a slow or loaded host still moves.
local function costs_what_it_reads(source: string)
  local built = assert(teal.load())
  local function took(text: string): integer
    local started = Clock.monotonic_ns()
    local _, result = built.gen(keyword_head .. text, nil, nil, "tl")
    assert(#assert(result).syntax_errors == 0, text:sub(1, 200) ..
        tostring((result.syntax_errors[1] or {}).msg))
    return Clock.monotonic_ns() - started
  end
  local plain = (source:gsub("record", "recd"):gsub("enum", "enmd"))
  -- The least of up to three of each, taken in turn, so neither a first
  -- compile's warm-up nor a pause elsewhere on the host lands on one
  -- side alone. A ratio within the bound ends the tries, so a pass
  -- costs one of each, and so does one four times past it, which no
  -- pause explains, so a failure is told well inside the deadline.
  local t, base = math.maxinteger, math.maxinteger
  for _ = 1, 3 do
    t = math.min(t, took(source))
    base = math.min(base, took(plain))
    local bound = base * 20 + 50000000
    if t < bound or t > 4 * bound then break end
  end
  assert(t < base * 20 + 50000000, source:sub(1, 80) .. ": " .. t .. " ns against " .. base .. " ns")
end

--- `line` 2000 times, each `N` in it the line's number.
local function repeated(line: string): string
  local parts: {string} = {}
  for k = 1, 2000 do
    parts[#parts + 1] = (line:gsub("N", tostring(k)))
  end
  return table.concat(parts)
end

local function test_an_enum_named_variable_costs_what_it_reads()
  costs_what_it_reads(repeated("local xN = enum\n"))
  costs_what_it_reads(repeated("local tN = { k = enum }\n"))
end

local function test_a_record_named_variable_costs_what_it_reads()
  costs_what_it_reads(repeated("local xN = record < n\n"))
  costs_what_it_reads(repeated("local xN = record\n"))
end

local function test_a_record_named_variable_in_a_function_costs_what_it_reads()
  costs_what_it_reads(repeated("local function fN() local x = record return x end\n"))
  costs_what_it_reads(repeated("local xN = record\nwhere(a)\n(b)()\nprint(xN)\n"))
end

--- Old declarations nested in each other's bodies are refused, each
--- look reading the tokens itself rather than through the one around
--- it; and a `where` around each of sixteen levels does not double the
--- cost with each.
local function test_nested_record_named_variables_cost_what_they_read()
  local within = "1"
  for k = 1, 120 do
    within = "(function(): integer local y" .. k .. " = record\n" ..
      "  f: function(integer): integer = macroexp(_a: integer): integer return " .. within .. " end\n" ..
      "end\nreturn 1 end)()"
  end
  assert(#syntax_errors(keyword_head .. "local x = " .. within .. "\nprint(x)\n") > 0)
  local nested = "local x0 = 1\n"
  for k = 1, 16 do
    nested = "local xN = record\nwhere(function()\n" .. nested .. "end)\nprint(xN)\n"
    nested = nested:gsub("xN", "x" .. k)
  end
  costs_what_it_reads(nested)
end

--- A test whose import closure does not hold [`cosmic.removed`] is not
--- told what the catalog says: build.teal names it by no `require` a
--- parse records, so no closure that reaches build.teal holds it, and
--- the worker refuses it to this one. Its key leaves the catalog out, so
--- an edit there must change nothing such a test sees; a refusal's
--- replacement is quoted only where the test requires the catalog
--- (build/teal_catalog_test.tl).
local function test_a_refusal_quotes_no_catalog_this_test_does_not_hold()
  assert(teal.replacement("unknown variable: os", "return os.getenv('HOME')\n", 1, 8) == nil)
  assert(teal.replacement("invalid key 'hex' in record 'Hash' of type Hash",
    'local Hash = require("cosmic.hash")\nreturn Hash.hex\n', 2, 13) == nil)
  assert(package.loaded["cosmic.removed"] == nil)
end

--- What [`teal.replacement`] says for the first diagnostic the checker
--- reports for `source` (an error or a warning) whose message is
--- `msg`: "no such diagnostic" when it reports none.
local function replacement_for(source: string, msg: string): string | nil
  local built = assert(teal.load())
  local _, result = built.gen(source, nil, nil, "tl")
  local found = result ~= nil
  for _, group in ipairs(found and { result.type_errors, result.warnings } or {}) do
    for _, e in ipairs(group) do
      if e.msg == msg then
        return teal.replacement(e.msg, source, e.y, e.x, e.fields)
      end
    end
  end
  return "no such diagnostic"
end

--- A number where an integer was expected -- a call's argument, a
--- declaration, a return value, `tonumber(s)` or `/` -- is told the
--- conversions, not a cast, which only silences the checker.
local function test_a_number_for_an_integer_names_the_conversions()
  local f = "local function f(n: integer): integer\n  return n\nend\n"
  assert(replacement_for(f .. "print(f(tonumber('3')))\n",
    "argument 1: got number, expected integer") == converted)
  assert(replacement_for("local n: integer = tonumber('3')\nprint(n)\n",
    "in local declaration: n: got number, expected integer") == converted)
  assert(replacement_for("local function g(): integer\n  return 7 / 2\nend\nprint(g())\n",
    "in return value: got number, expected integer") == converted)
  assert(replacement_for("local m: {string:integer} = {x = 7 / 2}\nprint(m)\n",
    "in local declaration: m: in map value: got number, expected integer") == converted)
  assert(teal.replacement("argument 1: got number (inferred at :2:11), expected integer",
    "", 3, 9) == converted)
  assert(replacement_for(f:gsub("n: integer%)", "n: integer | nil)") .. "print(f(7 / 2))\n",
    "argument 1: got number, expected integer | nil") == converted)
  assert(teal.replacement("argument 1: got string, expected integer", "", 1, 1) == nil)
end

local hides_table = "this hides the standard library's table for the rest of its scope: rename it"

--- A local, argument, loop variable or local function named for a
--- standard global is told what it hides where it is declared, and a
--- library's name used as one (`table.insert` on a local `table`) that
--- the name is a local.
local function test_a_standard_global_shadowed_is_named_where_declared()
  local shadows = "variable shadows previous declaration of 'table'"
  assert(replacement_for("local table = {1}\nprint(#table)\n", shadows) == hides_table)
  assert(replacement_for("local function f(table: {integer}): integer\n  return #table\nend\n" ..
      "print(f({}))\n", shadows) == hides_table)
  assert(replacement_for("for _, table in ipairs({{1}}) do\n  print(#table)\nend\n", shadows) ==
      hides_table)
  assert(replacement_for("local function print(s: string)\n  io.stderr:write(s)\nend\nprint('x')\n",
    "function shadows previous declaration of 'print'") ==
      "this hides the standard library's print for the rest of its scope: rename it")
  assert(replacement_for("local tonumber = 1\nprint(tonumber)\n",
    "variable shadows previous declaration of 'tonumber'") ==
      "this hides the standard library's tonumber for the rest of its scope: rename it")
  assert(teal.replacement("variable shadows previous declaration of 'total' " ..
      "(originally declared at 1:7)", "", 2, 7) == nil)
  assert(replacement_for("local table = {1}\ntable.insert(table, 2)\n",
    "cannot index key 'insert' in variable 'table' of type {integer}") ==
      "'table' here is a local that hides the standard library's table: rename it")
  local record_named_table = "local record Rows\n  n: integer\nend\n" ..
    "local table: Rows = {n = 1}\ntable.insert(table, 2)\n"
  assert(replacement_for(record_named_table, "invalid key 'insert' in record 'table' of type Rows") ==
      "'table' here is a local that hides the standard library's table: rename it")
  assert(replacement_for("table.nope({})\n", "invalid key 'nope' in record 'table' of type table") ==
      "table's fields: concat, insert, move, pack, remove, sort, unpack")
  -- cosmic withholds `io` from the checker ([`teal.withheld`]): a local
  -- of that name hides nothing.
  assert(teal.replacement("invalid key 'write' in record 'io' of type R", "", 3, 9) == nil)
  assert(teal.replacement("variable shadows previous declaration of 'io'", "", 2, 7) == nil)
end

--- tl checked no value named for a simple type for shadowing, and so
--- never warned of one named `string`, the string library
--- (patch/tl/32-a-value-named-string-shadows.txt). `any` and `thread`
--- are interfaces, which no value hides, and a localized `string` hides
--- nothing.
local function test_a_value_named_string_shadows_the_library()
  local shadows = "variable shadows previous declaration of 'string'"
  local hides = "this hides the standard library's string for the rest of its scope: rename it"
  assert(replacement_for("local string = 5\nprint(string)\n", shadows) == hides)
  assert(replacement_for("local function f(string: string): string\n  return string\nend\n" ..
      "print(f('a'))\n", shadows) == hides)
  assert(replacement_for("local string = string\nprint(string.upper('a'))\n", shadows) ==
      "no such diagnostic")
  local built = assert(teal.load())
  local _, result = built.gen("local any = 1\nlocal thread = 2\nprint(any, thread)\n", nil, nil, "tl")
  local warnings = assert(result).warnings
  assert(#warnings == 0, warnings[1] ~= nil and warnings[1].msg or "")
end

--- One nominal type refused for another of the same name is told they
--- are two types, naming the qualified one when the message shows it.
local function test_two_types_of_one_name_are_told_apart()
  local nested = "local record Kv\n  record Store\n    n: integer\n  end\nend\n" ..
    "local record Store\n  n: integer\nend\n" ..
    "local function put(s: Kv.Store): Kv.Store\n  return s\nend\n" ..
    "local s: Store = {n = 1}\nprint(put(s))\n"
  assert(replacement_for(nested, "argument 1: Store is not a Kv.Store") ==
      "two distinct types are both named Store: use Kv.Store rather than declaring Store " ..
      "again, as 'local type Store = Kv.Store'")
  local scoped = "local record Store\n  n: integer\nend\n" ..
    "local function put(s: Store): Store\n  return s\nend\n" ..
    "do\n  local record Store\n    n: integer\n  end\n  local s: Store = {n = 1}\n  print(put(s))\nend\n"
  local twice = "two distinct types are both named Store: declare it once and name that one " ..
    "everywhere, as 'local type Store = Kv.Store' for one declared in a module required as Kv"
  assert(replacement_for(scoped,
    "argument 1: Store (defined in :8) is not a Store (defined in :1)") == twice)
  assert(teal.replacement("argument 1: Store (defined in :7) is not a Store " ..
      "(defined in /abs/path/kv.tl:3)", "", 8, 8) == twice)
  assert(teal.replacement("argument 1: Kv.Store is not a Store", "", 1, 1) ==
      "two distinct types are both named Store: use Kv.Store rather than declaring Store " ..
      "again, as 'local type Store = Kv.Store'")
  assert(teal.replacement("argument 1: Store is not a Kv.Entry", "", 1, 1) == nil)
  assert(teal.replacement("argument 1: A.Node is not a B.Node", "", 1, 1) == nil)
end

--- `Kv.Kv` for a module bound to `Kv` is told `Kv` is the type; a name
--- no `require` binds is not.
local function test_a_module_type_named_twice_is_told_its_name()
  local source = 'local Kv = require("kv")\nlocal k: Kv.Kv = Kv\nreturn k\n'
  assert(teal.replacement("unknown type Kv.Kv", source, 2, 10) ==
      "Kv is itself the type of the record its module returns: write Kv, not Kv.Kv")
  assert(teal.replacement("unknown type Kv.Kv", "local Kv = {}\nlocal k: Kv.Kv\n", 2, 10) == nil)
  assert(teal.replacement("unknown type Kv.Store", source, 2, 10) == nil)
end

local rec = "local record R\n  alpha: integer\n  beta: string\n  record Inner\n    n: integer\n  end\nend\n" ..
  "local r: R = {alpha = 1}\n"

--- A key a record lacks, read, written or called, is told the nearest
--- of the record's value fields and what they are (a nested type is no
--- value); a key near none is told the fields alone.
local function test_a_missing_field_names_the_nearest()
  local fields = "R's fields: alpha, beta"
  assert(replacement_for(rec .. "print(r.alpah)\n", "invalid key 'alpah' in record 'r' of type R") ==
      "did you mean 'alpha'? " .. fields)
  assert(replacement_for(rec .. "r.betta = 'x'\n", "invalid key 'betta' in record 'r' of type R") ==
      "did you mean 'beta'? " .. fields)
  assert(replacement_for(rec .. "r:alpah()\n", "invalid key 'alpah' in record 'r' of type R") ==
      "did you mean 'alpha'? " .. fields)
  assert(replacement_for(rec .. "r.gamma = 2\n", "invalid key 'gamma' in record 'r' of type R") ==
      fields)
  local made = rec .. "local function make(): R\n  return r\nend\nprint(make().ALPHA)\n"
  assert(replacement_for(made, "invalid key 'ALPHA' in type R") == "did you mean 'alpha'? " .. fields)
  assert(replacement_for("local interface Named\n  name: string\nend\n" ..
      "local n: Named = {name = 'x'}\nprint(n.nmae)\n",
    "invalid key 'nmae' in 'n' of interface type Named") == "did you mean 'name'? Named's fields: name")
  assert(replacement_for("local s = 'x'\nprint(s.lenn)\n", "invalid key 'lenn' in record 's' of type string") ==
      "did you mean 'len'? string's fields: byte, char, dump, find, format, gmatch, gsub, len, " ..
      "lower, match and 7 more")
  -- A field one edit past the limit is not offered: none for a key of
  -- one letter, one for four.
  assert(replacement_for("local t = {x = 1, y = 2}\nprint(t.z)\n",
    "invalid key 'z' in record 't' of type record (x: integer; y: integer)") ==
      "t's fields: x, y")
  assert(teal.replacement("invalid key 'nope' in record 'r' of type R", "", 1, 1, { "move" }) ==
      "R's fields: move")
  -- An inferred type is named without where it was inferred, and a
  -- record no variable names as "the record".
  assert(teal.replacement("invalid key 'lenn' in record 's' of type string \"x\" (inferred at :2:9)",
    "", 1, 1, { "len" }) == "did you mean 'len'? string \"x\"'s fields: len")
  assert(replacement_for("print(({a = 1}).b)\n", "invalid key 'b' in type record (a: integer)") ==
      "the record's fields: a")
  -- Without the fields the checker gives, nothing is guessed.
  assert(teal.replacement("invalid key 'alpah' in record 'r' of type R", "", 1, 1) == nil)
end

--- `type`, which nothing in the standard library names a field, is told
--- `kind`, which a record holding one names what it is with; a record
--- with no `kind` is told only its fields. Several fields equally near
--- are each named, up to three.
local function test_a_missing_type_is_told_kind()
  local stat = "local record Stat\n  kind: string\n  size: integer\nend\n" ..
    "local st: Stat = {kind = 'file', size = 0}\n"
  assert(replacement_for(stat .. "print(st.type)\n", "invalid key 'type' in record 'st' of type Stat") ==
      "did you mean 'kind'? Stat's fields: kind, size")
  assert(replacement_for(rec .. "print(r.type)\n", "invalid key 'type' in record 'r' of type R") ==
      "R's fields: alpha, beta")
  assert(teal.replacement("invalid key 'ab' in record 'r' of type R", "", 1, 1, { "ac", "ad", "aa" }) ==
      "did you mean 'aa', 'ac' or 'ad'? R's fields: aa, ac, ad")
  assert(teal.replacement("invalid key 'ab' in record 'r' of type R", "", 1, 1,
    { "ac", "ad", "aa", "ae" }) == "R's fields: aa, ac, ad, ae")
  assert(teal.replacement("invalid key 'stats' in record 'fs' of type fs", "", 1, 1,
    { "Stat", "stat" }) == "did you mean 'stat'? fs's fields: Stat, stat")
end

--- A record of many fields lists the first ten alphabetically and says
--- how many more it has; a module record described rather than named
--- (`record Module`) is named by its variable.
local function test_a_missing_field_lists_a_bounded_few()
  local names: {string} = {}
  for i = 12, 1, -1 do
    names[#names + 1] = string.format("f%02d", i)
  end
  assert(teal.replacement("invalid key 'zzzzzz' in record 'big' of type Big", "", 1, 1, names) ==
      "Big's fields: f01, f02, f03, f04, f05, f06, f07, f08, f09, f10 and 2 more")
  assert(teal.replacement("invalid key 'parsee' in record 'Cli' of type record Module", "", 1, 1,
    { "parse" }) == "did you mean 'parse'? Cli's fields: parse")
end

--- An assignment to a for loop's control variable -- a numeric for's,
--- or the first of a generic for's -- is refused at its own line
--- (patch/tl's 34), as Lua 5.5, which makes it read-only, would refuse
--- only the generated chunk. A generic for's other variables, a local
--- declared over the variable, and a parameter of its name are
--- assignable.
local function test_a_loop_control_variable_is_read_only()
  local refused = "cannot assign to for-loop variable 'item': it is read-only; copy it to a local first"
  for _, source in ipairs({
      "local xs = {'a'}\nfor item in ipairs(xs) do\n  print(item)\n  item = 2\nend\n",
      "for item = 1, 2 do\n  print(item)\n\n  item = 2\nend\n",
      "local function each(): function(): integer | string return nil end\n" ..
        "for item in each() do\n  if item is string then\n  item = 'x' end\nend\n",
      "local function each(): function(): integer | string return nil end\n" ..
        "for item in each() do\n  assert(item is string)\n  item = 'x'\nend\n",
      "for item = 1, 2 do\n  local function f() print(item)\n  end\n  item = f() end\n",
      "local xs: {integer|string} = {}\nfor item, v in ipairs(xs) do\n  print(v)\n" ..
        "  if v is integer then item = v end\nend\n",
  }) do
    local errors = type_errors(source)
    assert(#errors == 1 and errors[1].y == 4 and errors[1].msg == refused,
      source .. (errors[1] and errors[1].y .. ": " .. errors[1].msg or "no error"))
  end
  for _, source in ipairs({
      "local xs: {integer} = {}\nfor _, item in ipairs(xs) do item = item + 1; print(item) end\n",
      "for item = 1, 2 do local item = item; item = item + 1; print(item) end\n",
      "for item = 1, 2 do\n  print(item)\n  do local item = item; item = item + 1; print(item) end\nend\n",
      "local function each(): function(): integer | string return nil end\n" ..
        "for item in each() do\n  assert(item is string)\n  local item = item\n  item = item .. 'x'\n" ..
        "  print(item)\nend\n",
      "local function each(): function(): integer | string return nil end\n" ..
        "for item in each() do\n  if item is string then\n    local item = item\n" ..
        "    item = item .. 'x'\n    print(item)\n  end\nend\n",
      "for item = 1, 2 do\n  local function f(item: integer) item = item + 1; print(item) end\n" ..
        "  f(item)\nend\n",
      "local item = 0\nfor item = 1, 2 do print(item) end\nitem = 1\nprint(item)\n",
  }) do
    local errors = type_errors(source)
    assert(#errors == 0, source .. (errors[1] and errors[1].msg or ""))
  end
end

local short = "wrong number of arguments (given 1, expects 2)"

--- A call short of parameters its callee's declaration lets be nil is
--- told to declare them optional, spelled as written less their nil,
--- for a local, a module's or a method's function and one bound to a
--- name; one short of a parameter that cannot be nil is told nothing,
--- since the call is what is short.
local function test_a_short_call_names_the_optional_parameter()
  assert(replacement_for("local function f(a: string, b: string | nil) print(a, b) end\nf('x')\n", short) ==
      "a parameter a caller may leave out is written 'b?: string'")
  assert(replacement_for("local M = {}\n" ..
      "function M.g(a: string, b: string | nil,\n  c: {string: integer} | nil) print(a, b, c) end\nM.g('x')\n",
    "wrong number of arguments (given 1, expects 3)") ==
      "parameters a caller may leave out are written 'b?: string, c?: {string: integer}'")
  assert(replacement_for("local record R\n  n: integer\nend\n" ..
      "function R:m(b: nil | function(string, integer): string) print(self, b) end\n" ..
      "local r: R = {n = 1}\nr:m()\n", "wrong number of arguments (given 1, expects 2)") ==
      "a parameter a caller may leave out is written 'b?: function(string, integer): string'")
  assert(replacement_for("local h = function(a: string, b: string | nil) print(a, b) end\nh('x')\n", short) ==
      "a parameter a caller may leave out is written 'b?: string'")
  assert(replacement_for("local M = {}\nM.h = function(a: string, b: string | nil) print(a, b) end\nM.h('x')\n",
    short) == "a parameter a caller may leave out is written 'b?: string'")
  assert(replacement_for("local function f(a: string, -- what\n  b: string | nil -- why, if any\n) " ..
      "print(a, b) end\nf('x')\n", short) == "a parameter a caller may leave out is written 'b?: string'")
  assert(replacement_for("local function f(a: string, b: nil) print(a, b) end\nf('x')\n", short) == nil)
  assert(replacement_for("local function f(a: string, b: nil | string --[[x]], c: string | nil)\n" ..
      "  print(a, b, c)\nend\nf('x', 'y')\n", "wrong number of arguments (given 2, expects 3)") ==
      "a parameter a caller may leave out is written 'c?: string'")
  assert(replacement_for("local function f(a: string, b: string) print(a, b) end\nf('x')\n", short) == nil)
  assert(replacement_for("local function f(a: string, b: string | nil) print(a, b) end\nf()\n",
    "wrong number of arguments (given 0, expects 2)") == nil)
end

--- A callee the file declares no function for in the call's form --
--- a record field's type, a standard library's, a module's, a local
--- of the name called as a member -- is told nothing, as is a call
--- given too many or one whose declarations disagree.
local function test_a_short_call_to_an_unseen_callee()
  assert(replacement_for("local record C\n  run: function(a: string, b: string)\nend\n" ..
      "local c: C = {run = function(a: string, b: string) print(a, b) end}\nc.run('x')\n", short) == nil)
  assert(replacement_for("print(setmetatable({}))\n", short) == nil)
  assert(teal.replacement(short, 'local Fs = require("cosmic.fs")\nFs.put("x")\n', 2, 7) == nil)
  assert(replacement_for("local record File\n  open: function(path: string, mode: string)\nend\n" ..
      "local function open(a: string, b: string | nil) print(a, b) end\nprint(open)\n" ..
      "local f: File = {open = function(p: string, m: string) print(p, m) end}\nf.open('x')\n", short) == nil)
  assert(replacement_for("local M = {}\nfunction M.put(path: string, data: string | nil) print(path, data) end\n" ..
      "local N = {}\nN.put = function(path: string, data: string) print(path, data) end\nN.put('x')\n", short) ==
      nil)
  assert(replacement_for("local function cb(a: string, b: string | nil) print(a, b) end\nprint(cb)\n" ..
      "local function apply(cb: function(string, string)) cb('x') end\nprint(apply)\n", short) == nil)
  assert(replacement_for("local function f(a: string) print(a) end\nf('x', 'y')\n",
    "wrong number of arguments (given 2, expects 1)") == nil)
  assert(replacement_for("global function g(a: string, b: string | nil) print(a, b) end\n" ..
      "global function g(a: string, b: integer | nil) print(a, b) end\ng('x')\n", short) == nil)
end

--- The callee is the function in scope at the call: a local of a
--- closed block is not, and a method is found through the type its
--- receiver was declared of, a local's, a parameter's or `self`'s.
local function test_a_short_call_reads_the_callee_in_scope()
  assert(replacement_for("do\n  local function f(a: string, b: string | nil) print(a, b) end\n" ..
      "  print(f)\nend\nlocal function f(a: string, b: integer | nil) print(a, b) end\nf('x')\n", short) ==
      "a parameter a caller may leave out is written 'b?: integer'")
  assert(replacement_for("local record R\n  n: integer\nend\n" ..
      "function R:m(b: string | nil) print(self, b) end\nlocal r: R = {n = 1}\nr:m()\n",
    "wrong number of arguments (given 1, expects 2)") ==
      "a parameter a caller may leave out is written 'b?: string'")
  local record_r = "local record R\n  n: integer\nend\nfunction R:b(x: string | nil) print(self, x) end\n"
  assert(replacement_for(record_r .. "function R:a() self:b() end\n",
    "wrong number of arguments (given 1, expects 2)") ==
      "a parameter a caller may leave out is written 'x?: string'")
  assert(replacement_for(record_r .. "local function g(r: R) r:b() end\nprint(g)\n",
    "wrong number of arguments (given 1, expects 2)") ==
      "a parameter a caller may leave out is written 'x?: string'")
end

--- A key no field is near by spelling is told the fields that hold it
--- or that it holds as whole words, shortest first, ahead of the
--- alphabetical list that may stop before them; a key of fewer than
--- three letters is not.
local function test_a_missing_field_names_one_that_holds_it()
  local fields = { "collect", "copy", "from_fd", "from_string", "lines", "open" }
  local listed = "Stream's fields: collect, copy, from_fd, from_string, lines, open"
  assert(teal.replacement("invalid key 'string' in record 'Stream' of type Stream", "", 1, 1, fields) ==
      "did you mean 'from_string'? " .. listed)
  assert(teal.replacement("invalid key 'from' in record 'Stream' of type Stream", "", 1, 1, fields) ==
      "did you mean 'from_fd' or 'from_string'? " .. listed)
  assert(teal.replacement("invalid key 'read_lines' in record 'Stream' of type Stream", "", 1, 1, fields) ==
      "did you mean 'lines'? " .. listed)
  assert(teal.replacement("invalid key 'pe' in record 'Stream' of type Stream", "", 1, 1, fields) ==
      listed)
  assert(teal.replacement("invalid key 'get' in record 'T' of type T", "", 1, 1, { "target", "set_get" }) ==
      "did you mean 'set_get'? T's fields: set_get, target")
end
