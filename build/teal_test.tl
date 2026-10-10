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

-- These cases assert checker positions and generated code, never the
-- vendor compiler's own Lua traceback lines, which no tree coverage uses.

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
  local built = assert(teal.load(true))
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
  local built = assert(teal.load(true))
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
  local built = assert(teal.load(true))
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
  local built = assert(teal.load(true))
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
  local built = assert(teal.load(true))
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
  local built = assert(teal.load(true))
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
  local built = assert(teal.load(true))
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
  local built = assert(teal.load(true))
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
  local built = assert(teal.load(true))
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
--- no `require` binds is not, nor one whose `local type` require the
--- compile refused.
local function test_a_module_type_named_twice_is_told_its_name()
  local source = 'local Kv = require("kv")\nlocal k: Kv.Kv = Kv\nreturn k\n'
  assert(teal.replacement("unknown type Kv.Kv", source, 2, 10) ==
      "Kv is itself the type of the record its module returns: write Kv, not Kv.Kv")
  assert(teal.replacement("unknown type Kv.Kv", "local Kv = {}\nlocal k: Kv.Kv\n", 2, 10) == nil)
  -- A `local type` require the compile refused holds no type at all.
  local typed = 'local type Kv = require("kv")\nlocal k: Kv.Kv\n'
  assert(teal.replacement("unknown type Kv.Kv", typed, 2, 10) ==
      "Kv is itself the type of the record its module returns: write Kv, not Kv.Kv")
  local answer = teal.replacement("unknown type Kv.Kv", typed, 2, 10, nil, "main.tl", { Kv = true })
  assert(answer == nil, answer)
  -- Another type of the module is told what the module must declare.
  assert(teal.replacement("unknown type Kv.Store", source, 2, 10) ==
      "Kv has no type Store: check its spelling, or declare `record Store ... end` " ..
      "inside the record kv returns (a `local record Store` beside that record is its " ..
      "file's alone)")
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

--- Holds the checker to reporting `msg` for `source`, and
--- [`teal.replacement`] to answering it `want`.
local function answers(source: string, msg: string, want: string | nil)
  local got = replacement_for(source, msg)
  if got == "no such diagnostic" then
    local seen: {string} = {}
    for _, e in ipairs(type_errors(source)) do seen[#seen + 1] = e.msg end
    error("no '" .. msg .. "' among: " .. table.concat(seen, "; "))
  end
  assert(got == want, tostring(got))
end

--- What every refusal of an untyped value is told for a variable named
--- `name`: the check and the cast, written out.
local function untyped(name: string): string
  return "'" .. name .. "' is any (untyped, as Json.decode answers): check it against a " ..
    "record with `local spec, err = Shape.record_of(\"Spec\"):into(" .. name .. ")` " ..
    "(local Shape = require(\"cosmic.shape\")), or cast it unchecked: `" .. name .. " as Spec`"
end

--- A field read of `any`, what [`Json.decode`] answers, is told the line
--- that checks it into a record and the cast that does not, whether the
--- value may also be nil or not; a value with no variable is called
--- `value`, and one handed where a type is expected names that type.
local function test_an_untyped_value_is_told_the_check_and_the_cast()
  local decoded = "local function decode(_: string): any | nil, string return nil, '' end\n"
  answers(decoded .. "local cfg = decode('')\nprint(cfg.cmd)\n",
    "cannot index key 'cmd' in variable 'cfg' of type <any type> | nil", untyped("cfg"))
  answers("local function f(cfg: any) print(cfg.cmd) end\nprint(f)\n",
    "cannot index key 'cmd' in variable 'cfg' of type <any type>", untyped("cfg"))
  local record_spec = "local record Spec\n  cmd: string\nend\n" ..
    "local function run(s: Spec) print(s) end\n"
  answers(decoded .. record_spec .. "local cfg = decode('')\nrun(cfg)\n",
    "argument 1: got <any type> | nil, expected Spec",
    "the value is any (untyped): cast it unchecked: `value as Spec`; if Spec is a record, " ..
      "`Shape.record_of(\"Spec\"):into(value)` checks it (local Shape = require(\"cosmic.shape\"))")
  -- A qualified record is named for `record_of` by its module's path,
  -- which the alias is bound to; an unbound alias is only cast.
  assert(teal.replacement("argument 1: got <any type>, expected L.Month",
    'local L = require("app.ledger")\n', 1, 1) ==
      "the value is any (untyped): cast it unchecked: `value as L.Month`; if L.Month is a record, " ..
      "`Shape.record_of(\"app.ledger.Month\"):into(value)` checks it " ..
      "(local Shape = require(\"cosmic.shape\"))")
  assert(teal.replacement("argument 1: got <any type>, expected L.Month", "", 1, 1) ==
      "the value is any (untyped): cast it unchecked: `value as L.Month`")
  answers(decoded .. "local n: integer = decode('')\nprint(n)\n",
    "in local declaration: n: got <any type> | nil, expected integer",
    "the value is any (untyped): narrow it with `if value is integer then ... end`, " ..
      "or cast it unchecked: `value as integer`")
  answers(decoded .. "local n: {string} = decode('')\nprint(n)\n",
    "in local declaration: n: got <any type> | nil, expected {string}",
    "the value is any (untyped): cast it unchecked: `value as {string}`")
end

--- A value that may be nil, read, closed or iterated, is told the
--- check and the `assert` that drop it.
local function test_a_value_that_may_be_nil_is_told_the_check()
  local record_r = "local record R\n  n: integer\nend\n" ..
    "local function find(): R | nil, string return nil, 'none' end\n" ..
    "local function list(): {string} | nil, string return nil, 'none' end\n"
  answers(record_r .. "local r = find()\nprint(r.n)\n",
    "cannot index key 'n' in variable 'r' of type R | nil",
    "'r' may be nil: check it first (`if r == nil then return nil, err end`), " ..
      "or, where a call answers it, take it with `local r = assert(<the call>)`")
  answers(record_r .. "print(find().n)\n",
    "cannot index key 'n' in type R | nil",
    "the value may be nil: check it first (`if value == nil then return nil, err end`), " ..
      "or, where a call answers it, take it with `local value = assert(<the call>)`")
  answers(record_r .. "for _, s in ipairs(list()) do print(s) end\n",
    "attempting ipairs on something that's not an array: {string} | nil",
    "the table may be nil: check it first (`if t == nil then return nil, err end`) " ..
      "or loop over `ipairs(t or {})`")
  -- Checking for nil leaves `string | R` unusable still: no nil hint.
  local both = record_r .. "local function both(): string | R | nil return nil end\n"
  answers(both .. "local b = both()\nprint(b.n)\n",
    "cannot index key 'n' in variable 'b' of type string | R | nil", nil)
  -- The checker's target here is 5.3, which has no `<close>`: the
  -- message is the one a cosmic compile reports.
  assert(teal.replacement("to-be-closed variable g has a non-closable type R | nil", "", 1, 1) ==
      "the call may answer nil: `local g <close> = assert(<the call>)` closes what it " ..
      "answers, and raises its error in place of the nil")
end

--- An operator refused an operand of a union is told to narrow it.
local function test_a_union_operand_is_told_to_narrow_it()
  answers("local function f(x: string | integer): integer\n  return x + 1\nend\nprint(f)\n",
    "cannot use operator '+' for types string | integer and integer",
    "an operand is a union: narrow it first, as `if v is string then ... end` " ..
      "or `type(v) == \"string\"` does")
  answers("local function f(g: function(string | nil): integer): integer\n  return g + 1\nend\nprint(f)\n",
    "cannot use operator '+' for types function(string | nil): integer and integer", nil)
end

--- A module's type named but declared beside its record, not inside, is
--- told to move it there; one named through a `require` of a module of
--- the program's own is told what that module must declare. A
--- `cosmic.*` module's is left to the catalog.
local function test_a_module_type_is_told_to_nest_inside_the_record()
  answers("local record Transaction\n  amount: integer\nend\nlocal record Ledger\nend\n" ..
      "function Ledger.total(t: Ledger.Transaction): integer\n  return t.amount\nend\n" ..
      "print(Transaction)\nreturn Ledger\n",
    "unknown type Ledger.Transaction",
    "Transaction is declared beside Ledger, not inside it: move `record Transaction ... end` " ..
      "into `local record Ledger ... end` to name it Ledger.Transaction")
  -- The checker here has no module `ledger`: the message is the one a
  -- project's compile reports (build/importer_test.tl).
  assert(teal.replacement("unknown type Ledger.Transaction",
    'local Ledger = require("ledger")\n', 1, 1) ==
      "Ledger has no type Transaction: check its spelling, or declare `record Transaction ... end` " ..
      "inside the record ledger returns (a `local record Transaction` beside that record is its " ..
      "file's alone)")
  -- Bound by a type-only `require` alike.
  assert(teal.replacement("unknown type Ledger.Month", 'local type Ledger = require("ledger")\n',
    1, 1) == "Ledger has no type Month: check its spelling, or declare `record Month ... end` " ..
      "inside the record ledger returns (a `local record Month` beside that record is its " ..
      "file's alone)")
  -- An enum beside the record is told to move as itself.
  answers("local enum Month\n  \"may\"\nend\nlocal record Ledger\nend\n" ..
      "local m: Ledger.Month = \"may\"\nprint(m)\nlocal x: Month = \"may\"\nprint(x)\nreturn Ledger\n",
    "unknown type Ledger.Month",
    "Month is declared beside Ledger, not inside it: move `enum Month ... end` " ..
      "into `local record Ledger ... end` to name it Ledger.Month")
  assert(teal.replacement("unknown type Http.Address", 'local Http = require("cosmic.http")\n',
    1, 1) == nil)
end

--- What [`teal.replacement`] says of the first syntax error in `source`.
local function syntax_hint(source: string): string | nil
  local built = assert(teal.load(true))
  local _, result = built.gen(source, nil, nil, "tl")
  local e = assert(assert(result).syntax_errors[1], source)
  assert(e.msg == "syntax error, expected one of: ')', ','", e.msg)
  return teal.replacement(e.msg, source, e.y, e.x)
end

--- A vararg given a name is refused by the parser with only its list of
--- expected tokens; the hint says a vararg takes none.
local function test_a_named_vararg_is_told_it_takes_no_name()
  local hint = syntax_hint("local function f(...names: string) end\n")
  assert(hint ~= nil and hint:find("write `...: string`", 1, true) ~= nil, tostring(hint))
  hint = syntax_hint("local M = {}\nfunction M.f(a: integer, ...rest: string) end\n")
  assert(hint ~= nil and hint:find("write `...: string`", 1, true) ~= nil, tostring(hint))
  hint = syntax_hint("local function f(... rest: {string}) end\n")
  assert(hint ~= nil and hint:find("write `...: {string}`", 1, true) ~= nil, tostring(hint))
  hint = syntax_hint("local function f(...rest?: string | nil, b: integer) end\n")
  assert(hint ~= nil and hint:find("write `...: string | nil`", 1, true) ~= nil, tostring(hint))
  hint = syntax_hint("local function f(...names: function(string): string) end\n")
  assert(hint ~= nil and hint:find("write `...: function(string): string`", 1, true) ~= nil,
    tostring(hint))
  hint = syntax_hint("local f = function<T>(...names: Map<T>) end\n")
  assert(hint ~= nil and hint:find("write `...: Map<T>`", 1, true) ~= nil, tostring(hint))
end

--- Other `expected one of: ')', ','` errors are not about a vararg.
local function test_other_missing_comma_errors_get_no_vararg_hint()
  assert(syntax_hint("local function f(a b) end\n") == nil)
  assert(syntax_hint("f(a b)\n") == nil)
  assert(syntax_hint("local function g(...: string) print(... x) end\n") == nil)
  assert(syntax_hint("f(...x)\n") == nil)
end

--- Everything the parser and the checker refuse in `source`, each as
--- "line:column message".
local function refusals(source: string): {string}
  local built = assert(teal.load(true))
  local ok, code, result = pcall(built.gen, source, nil, nil, "tl")
  assert(ok, tostring(code))
  local out: {string} = {}
  for _, e in ipairs(assert(result).syntax_errors) do
    out[#out + 1] = e.y .. ":" .. e.x .. " " .. e.msg
  end
  for _, e in ipairs(result.type_errors) do
    out[#out + 1] = e.y .. ":" .. e.x .. " " .. e.msg
  end
  return out
end

local function assert_accepted(source: string)
  local found = refusals(source)
  assert(#found == 0, source .. table.concat(found, "; "))
end

local function assert_refused(source: string, text: string)
  local found = refusals(source)
  assert(found[1] ~= nil and found[1]:find(text, 1, true) ~= nil,
    source .. "refused as: " .. (found[1] or "accepted"))
end

--- `: never` is a return list that says a function does not return
--- (patch/tl's 43b3): it parses on a declaration, a method, a function
--- type and a function-typed parameter that another follows, and the
--- Lua it generates is the Lua of the same function without it.
local function test_never_is_a_return_list()
  assert_accepted("local record Guard\n  die: function(self: Guard, why: string): never\nend\n" ..
      "function Guard:die(why: string): never\n  error(why)\nend\n" ..
      "local function run(f: function(): never, x: integer): integer\n  f()\n  return x\nend\n" ..
      "local h: function(): never = function(): never error('x') end\nprint(run, h)\n")
  local built = assert(teal.load(true))
  local with = assert(built.gen("local function fail(m: string): never\n  error(m)\nend\nfail('x')\n",
    nil, nil, "tl"))
  local without = assert(built.gen("local function fail(m: string)\n  error(m)\nend\nfail('x')\n",
    nil, nil, "tl"))
  assert(with == without, with)
end

--- `never` is the flag only as the whole of an unparenthesized return
--- list: in a list, in parentheses, in a union, as a vararg, as a
--- parameter or in a container it is a name no type has (43b3).
local function test_never_is_only_the_whole_return_list()
  assert_refused("local function f(): never, string error('x') end\nprint(f)\n",
    "'never' is the whole return list")
  for _, source in ipairs({
      "local function f(): (never) error('x') end\nprint(f)\n",
      "local function f(): never | nil error('x') end\nprint(f)\n",
      "local function f(): never... error('x') end\nprint(f)\n",
      "local function f(x: never) print(x) end\nprint(f)\n",
      "local x: {never}\nprint(x)\n",
      "local x: {string: never}\nprint(x)\n",
  }) do
    assert_refused(source, "unknown type never")
  end
  -- A `,` before a parameter ends the list, as it ends any return list.
  assert_accepted("local function f(cb: function(): never, n?: string) print(cb, n) end\n" ..
      "local function g(cb: function(): never, ...: any) print(cb) end\nprint(f, g)\n")
end

--- `never.x` and `never<T>` are names that start a longer type, not the
--- flag, so they are read as the nominal type they spell.
local function test_never_followed_by_a_dot_or_arguments_is_a_name()
  assert_refused("local function f(): never.x end\nprint(f)\n", "unknown type never.x")
  assert_refused("local function f(): never<integer> end\nprint(f)\n", "unknown type never<integer>")
  assert(#syntax_errors("local function f(): never.x end\nlocal function g(): never<integer> end\n") == 0)
end

--- No type is named `never`: a declaration of one would have `: never`
--- silently mean something else (43c1). Another name that starts with
--- the word is a type like any.
local function test_no_type_is_named_never()
  for _, source in ipairs({
      "local record never\n  x: integer\nend\n",
      "global record never\n  x: integer\nend\n",
      "local interface never\n  x: integer\nend\n",
      "local enum never\n  \"a\"\nend\n",
      "local type never = integer\n",
      "global type never = integer\n",
      "local record R\n  record never\n    x: integer\n  end\nend\n",
      "local record R\n  type never = integer\nend\n",
      "local function f<never>(x: never): never return x end\n",
      "local record Box<never>\n  v: never\nend\n",
  }) do
    assert_refused(source, "a type cannot be named 'never'")
  end
  assert_accepted("local record nevermore\n  x: integer\nend\nlocal type never_ = integer\n" ..
      "local n: nevermore = { x = 1 }\nprint(n)\n")
end

local never_fail = "local function fail(m: string): never\n  error(m)\nend\n"

--- A function that never returns stands for a function of any returns
--- (patch/tl's 43e2), `pcall`'s parameter among them; one that may return
--- does not stand for one that never does, which would make `f("x")` end
--- a block that `print` returns from.
local function test_a_never_function_is_a_subtype_of_any_function()
  assert_accepted(never_fail .. "local g: function(string) = fail\n" ..
      "local h: function(string): integer = fail\nprint(pcall(fail, 'x'))\nprint(g, h)\n")
  assert_refused("local f: function(): never = print\nprint(f)\n", "may return, where")
  assert_refused(never_fail .. "local f: function(string): never = fail\n" ..
      "local g: function(string) = print\nf = g\n", "may return, where")
end

--- Two function types are the same type only when both or neither
--- never return (43e3): a record function is held to its field, which
--- must say `: never` as the function does, and the reverse.
local function test_a_record_function_agrees_with_its_field_on_never()
  local record_with_field = "local record Guard\n  die: function(why: string)%s\nend\n"
  assert_refused(record_with_field:format("") ..
      "function Guard.die(why: string): never error(why) end\n", "only one of them never returns")
  assert_refused(record_with_field:format(": never") ..
      "function Guard.die(why: string) print(why) end\n", "only one of them never returns")
  assert_accepted(record_with_field:format(": never") ..
      "function Guard.die(why: string): never error(why) end\nprint(Guard)\n")
end

--- An overloaded function stands for one that never returns only when
--- every overload does (43e4); the overload a call picks decides
--- whether the call ends a block (43f1).
local function test_a_poly_function_is_never_only_when_every_overload_is()
  local poly = "local record P\n  f: function(string): never\n  f: function(%s)%s\nend\nlocal p: P\n"
  assert_accepted(poly:format("integer", ": never") .. "local g: function(any): never = p.f\nprint(g)\n")
  assert_refused(poly:format("integer", ": string") .. "local g: function(string): never = p.f\nprint(g)\n",
    "polymorphic function with an overload that may return")
end

--- A type nested in another keeps its never-ness: a function that never
--- returns does not stand for one that may inside an array, a map, a
--- record, a union, an alias or a generic's type argument, as a
--- parameter or as a return, in either direction (43e5). Teal compares
--- what is nested through is_a in whichever direction passes, so
--- without this `{function(): never}` stood for `{function(): string}`.
local function test_never_agrees_when_nested()
  local prelude = "local record Box<X>\n  v: X\nend\n" ..
    "local record RecN\n  f: function(): never\nend\nlocal record RecS\n  f: function(): string\nend\n" ..
    "local type AliasN = {function(): never}\nlocal type AliasS = {function(): string}\n"
  local kinds: {string:{string}} = {
    array = { "{function(): never}", "{function(): string}" },
    map = { "{string:function(): never}", "{string:function(): string}" },
    union = { "nil | function(): never", "nil | function(): string" },
    alias = { "AliasN", "AliasS" },
    generic = { "Box<function(): never>", "Box<function(): string>" },
    record = { "RecN", "RecS" },
  }
  local seen = 0
  for _, pair in pairs(kinds) do
    for _, place in ipairs({ "param", "return" }) do
      local function declared(t: string): string
        return place == "param" and "function(p: " .. t .. ")" or "function(): " .. t
      end
      for _, direction in ipairs({ { 1, 2 }, { 2, 1 } }) do
        local source = prelude .. "local a: " .. declared(pair[direction[1]]) ..
          "\nlocal b: " .. declared(pair[direction[2]]) .. "\nb = a\nprint(a, b)\n"
        assert_refused(source, "do not stand for each other inside another type")
        seen = seen + 1
      end
      for i = 1, 2 do
        assert_accepted(prelude .. "local a: " .. declared(pair[i]) .. "\nlocal b: " ..
            declared(pair[i]) .. "\nb = a\nprint(a, b)\n")
      end
    end
  end
  assert(seen == 24, tostring(seen))
end

--- A parameter that is itself a never-function compares with the callback
--- a function expects: the forward direction forges too (a function taking
--- a never-callback stands for one taking a callback that returns).
local function test_never_agrees_in_a_callback_parameter()
  assert_refused("local a: function(cb: function(): never)\n" ..
      "local b: function(cb: function(): string)\nb = a\n",
    "got function(): never, expected function(): string: a function that never returns")
  assert_refused("local a: function(cb: function(): string)\n" ..
      "local b: function(cb: function(): never)\nb = a\n", "do not stand for each other")
end

--- `as` and `is` give any target type unchecked, so one that contains a
--- never-function forges the guarantee: `print as function(): never`, `is`
--- on an `any`, and a record whose field is one (`q as P`, with `P.die`
--- never and `Q.die` returning). The hole is accepted until doc/roadmap.md's
--- cast policy closes it for `as` and `is` alike; this pins what the
--- compiler does today.
local function test_as_and_is_forge_a_never_function()
  assert_accepted("local function f(v: any): integer\n  if v is function(): never then\n" ..
      "    v()\n  end\n  return 1\nend\nprint(f)\n")
  assert_accepted("local v = print as function(): never\nprint(v)\n")
  local records = "local record P\n  die: function(): never\nend\n" ..
    "local record Q\n  die: function()\nend\n"
  assert_accepted(records .. "local function f(q: Q): P\n  local p: P = q as P\n  return p\nend\nprint(f)\n")
  assert_accepted(records .. "local function f(v: any): integer\n  if v is P then\n" ..
      "    v.die()\n  end\n  return 1\nend\nprint(f)\n")
end

--- A function declared `: never` contains no `return`, not even a bare
--- one, and must not reach its end: its last statement ends the block
--- (43g). A closure inside has its own returns.
local function test_a_never_function_neither_returns_nor_reaches_its_end()
  assert_refused("local function f(m: string): never\n  if m == '' then return end\n  error(m)\nend\n",
    "cannot return")
  assert_refused("local function f(): never\n  return 1\nend\n", "cannot return")
  assert_refused("local function f(m: string): never\n  print(m)\nend\n", "can reach its end")
  assert_refused("local function f(n: integer): never\n  if n > 1 then error('a') end\nend\n",
    "can reach its end")
  assert_refused("local function f(): never\n  while true do break end\nend\n", "can reach its end")
  assert_refused("local record R\nend\nfunction R.f(): never\n  print('x')\nend\n", "can reach its end")
  assert_accepted("local function a(): never\n  error('x')\nend\n" ..
      "local function b(): never\n  while true do end\nend\n" ..
      "local function c(): never\n  c()\nend\n" ..
      "local function d(): never\n  repeat until false\nend\n" ..
      "local function e(n: integer): never\n  if n > 1 then error('a') else error('b') end\nend\n" ..
      "local function g(): never\n  do error('x') end\nend\n" ..
      "local function h(m: string): never\n  local k = function(): integer return 1 end\n" ..
      "  print(k())\n  error(m)\nend\nprint(a, b, c, d, e, g, h)\n")
  -- the type inside its own body carries the flag, and so does a method's
  assert_accepted("local record R\n  die: function(self: R): never\nend\n" ..
      "function R:die(): never\n  self:die()\nend\nprint(R)\n")
end

--- A function literal that omits its return list takes `never` from its
--- context as it takes the returns (43h): it must not return and must not
--- reach its end, and its type never returns. The seam shape:
--- `sys.exit = function(_?: integer) refuse("sys.exit") end`.
local function test_a_literal_takes_never_from_its_context()
  local seam = "local record Seam\n  exit: function(status?: integer)%s\nend\n"
  local refuse = "local function refuse(m: string): never error(m) end\n"
  assert_accepted(seam:format(": never") .. refuse ..
      "local s: Seam = { exit = function(_?: integer) refuse('exit') end }\n" ..
      "s.exit = function(_?: integer) error('y') end\nprint(s)\n")
  assert_refused(seam:format(": never") ..
      "local s: Seam = { exit = function(_?: integer) print('x') end }\n", "missing never")
  assert_refused(seam:format(": never") ..
      "local s: Seam = { exit = function(_?: integer) return end }\n", "cannot return")
  -- A context that may return asks nothing of the literal.
  assert_accepted(seam:format("") .. "local s: Seam = { exit = function(_?: integer) print('x') end }\nprint(s)\n")
end

--- A macroexp declared `: never` must be a call that never returns, which
--- replaces the call of it (43g3).
local function test_a_never_macroexp_is_a_never_call()
  assert_accepted("local macroexp die(m: string): never return error(m) end\ndie('x')\n")
  assert_refused("local macroexp die(m: string): never return m end\n", "its expression is no call")
  assert_refused("local macroexp die(m: string): never return (error(m)) end\n", "its expression is no call")
end

--- The standard `error` never returns (patch/tl's 44a): it stands for a
--- never-function, and a variable holding it keeps that.
local function test_error_is_a_never_function()
  assert_accepted("local e: function(string): never = error\nlocal f = error\nprint(e, f)\n")
  assert_accepted("print(pcall(error, 'x'))\nlocal g: function(any) = error\nprint(g)\n")
  assert_refused("local f = error\nf = print\n", "may return, where")
  assert(#syntax_errors("local g: function(string): never = error\n") == 0)
end

--- A record's method refused against an interface method with an unnamed
--- receiver is told to name the receiver `self`.
local function test_an_unnamed_interface_receiver_is_told_to_name_self()
  local msg = "type signature of 'm' does not match its declaration in R: " ..
    "argument 0: R is not a I"
  local hint = teal.replacement(msg, "function R:m(s: string): string end\n", 1, 1)
  assert(hint ~= nil and hint:find("m: function(self: I, ...)", 1, true) ~= nil, tostring(hint))
  assert(hint:find("function R:m", 1, true) ~= nil, hint)
  assert(teal.replacement("type signature of 'm' does not match its declaration in R: " ..
      "argument 0: S is not a I", "", 1, 1) == nil)
  assert(teal.replacement("type signature of 'm' does not match its declaration in R: " ..
      "argument 1: R is not a I", "", 1, 1) == nil)
end

--- A type parameter the expected result fixed is told to bind it in a local.
local function test_a_fixed_type_parameter_is_told_to_bind_in_a_local()
  local hint = teal.replacement("argument 2: type parameter <T>: R is not a I", "", 1, 1)
  assert(hint ~= nil and hint:find("local v: R = setmetatable(t, mt)", 1, true) ~= nil,
    tostring(hint))
  assert(teal.replacement("argument 2: type parameter <T>: got R, expected R | nil", "", 1, 1) ~= nil)
  assert(teal.replacement("argument 2: got R, expected S", "", 1, 1) == nil)
end

--- `coroutine.wrap` is declared `F -> F`, which is wrong for any type
--- (its wrapper returns whatever the coroutine yields), so a wrapped
--- never-function is typed never, as a wrapped function returning a string
--- is typed to return one whatever it yields. Never is exactly as sound as
--- Teal's other types: the plan lists this among the holes every type has,
--- and this pins that the compiler accepts it today.
local function test_coroutine_wrap_forges_a_never_function_as_it_forges_any_type()
  local wrapped = "local function nv(): never\n  coroutine.yield(1)\n  error('x')\nend\n"
  assert_accepted(wrapped .. "local c: function(): never = coroutine.wrap(nv)\nprint(c)\n")
  local never_signature = "function(function(): never): function(): never"
  assert_accepted(wrapped .. "local w: " .. never_signature .. " = coroutine.wrap\nprint(w)\n")
  assert_accepted("local w = coroutine.wrap(function(a: integer): integer return a end)\n" ..
      "local n: integer = w(1)\nprint(n)\n")
end

--- A generic that writes a value into a container of never-functions
--- refuses a function that may return, since the type variable binds the
--- never-function type with its flag: `put<T>(t: {T}, v: T)`, `table.insert`
--- and `table.remove` on `{function(): never}`, a map, a record's field
--- read as a map, a copy of the array, and a generic record, with the
--- value or the container first, nested twice, and as a callback's parameter.
local function test_a_generic_cannot_write_a_returning_function_into_a_never_container()
  local head = "local function nv(): never error('x') end\nlocal function ret() end\nprint(nv, ret)\n"
  for _, body in ipairs({
      "local a: {function(): never} = { nv }\ntable.insert(a, 1, ret)\n",
      "local a: {function(): never} = { nv }\ntable.insert(a, ret)\n",
      "local a: {function(): never} = { nv, nv }\nlocal function put<T>(t: {T}, v: T) t[1] = v end\nput(a, ret)\n",
      "local a: {string:function(): never} = { k = nv }\n" ..
        "local function put<T>(t: {string:T}, v: T) t.k = v end\nput(a, ret)\n",
      "local a: {function(): never} = { nv }\nlocal function cp<T>(x: {T}): {T} return x end\n" ..
        "local b = cp(a)\nb[1] = ret\n",
      "local record R<T> f: T end\nlocal r: R<function(): never> = { f = nv }\n" ..
        "local function swap<T>(x: R<T>, v: T) x.f = v end\nswap(r, ret)\n",
      "local record R die: function(): never end\nlocal r: R = { die = nv }\n" ..
        "local function setk<K,V>(t: {K:V}, k: K, v: V) t[k] = v end\nsetk(r, 'die', ret)\n",
      "local record R f: function(): never end\nlocal r: R = { f = nv }\n" ..
        "local function put<T>(t: {string:T}, v: T) t.f = v end\nput(r, ret)\n",
      -- the value first: T is bound by a returning function before the container
      "local function put3<T>(v: T, t: {T}) t[1] = v end\nlocal u = { nv }\nput3(ret, u)\n",
      "local function mput<K, V>(v: V, m: {K: V}, k: K) m[k] = v end\n" ..
        "local m: {string: function(): never} = { a = nv }\nmput(ret, m, 'a')\n",
      "local t: {function(): never} = { nv }\nlocal u = { ret }\ntable.move(u, 1, 1, 1, t)\n",
      "local function nest<T>(v: T, r: {{T}}) r[1][1] = v end\n" ..
        "local r: {{function(): never}} = {{ nv }}\nnest(ret, r)\n",
      "local function cb<T>(v: T, f: function(T)) f(v) end\n" ..
        "cb(ret, function(g: function(): never) print(g) end)\n",
  }) do
    assert_refused(head .. body, "never")
  end
end

--- A macroexp field declared `never` is held to the rule of a macroexp: its
--- expression must be a call that never returns (43g3).
local function test_a_never_macroexp_field_is_a_never_call()
  local record_with = "local record Guard\n  die: function(why: string): never = macroexp(why: string): never\n" ..
    "    return %s\n  end\nend\nprint(Guard)\n"
  assert_accepted(record_with:format("error(why)"))
  assert_refused(record_with:format("why"), "its expression is no call that never returns")
end

--- `function(): never | nil` is a function returning the unknown type `never | nil`;
--- the hint says how to write a function that never returns, or nil.
local function test_never_or_nil_is_told_to_name_the_function_type()
  local hint = teal.replacement("unknown type never", "local f: function(): never | nil\n", 1, 21)
  assert(hint ~= nil and hint:find("local type Fail = function(): never", 1, true) ~= nil, tostring(hint))
  assert_accepted("local type Fail = function(): never\nlocal f: Fail | nil\nprint(f)\n")
end

--- A poly value stands for a function type when some overload is a subtype
--- of it (patch/tl's 43e6): `string -> nothing` overloads do not stand for a
--- function that returns a string, which the row used to accept by asking
--- for the reverse.
local function test_a_poly_function_stands_for_what_an_overload_stands_for()
  local poly = "local record P\n  f: function(string)\n  f: function(integer)\nend\nlocal p: P\n"
  assert_accepted(poly .. "local g: function(string) = p.f\nprint(g)\n")
  assert_refused(poly .. "local g: function(string): string = p.f\nprint(g)\n",
    "cannot match against any alternatives of the polymorphic type")
end

--- The messages the checker reports for `source`, each with its hint
--- appended as the importer prints it, in the order they are reported.
local function checker_says(source: string): {string}
  local built = assert(teal.load(true))
  local _, result = built.gen(source, nil, nil, "tl")
  local out: {string} = {}
  for _, group in ipairs({ assert(result).syntax_errors, result.type_errors }) do
    for _, e in ipairs(group) do
      local instead = teal.replacement(e.msg, source, e.y, e.x, e.fields)
      out[#out + 1] = e.msg .. (instead ~= nil and " -- " .. instead or "")
    end
  end
  return out
end

--- Whether any of `lines` has `part` in it.
local function says(lines: {string}, part: string): boolean
  for _, line in ipairs(lines) do
    if line:find(part, 1, true) ~= nil then
      return true
    end
  end
  return false
end

local two_values = "local function two(): string, string\n  return \"a\", \"b\"\nend\n" ..
  "local function one(s: string): boolean\n  return #s > 0\nend\n"

--- A call whose last argument returns several values and has room for
--- one is told, on the arity error itself, to parenthesize that argument.
local function test_a_spilled_last_argument_is_told_to_parenthesize()
  local lines = checker_says(two_values .. "print(one(two()))\n")
  assert(#lines == 1, table.concat(lines, "\n"))
  assert(lines[1]:find("^wrong number of arguments %(given 2, expects 1%) %-%- the last argument " ..
      "two%(%.%.%.%) returns 2 values"), lines[1])
  assert(lines[1]:find("`(two(...))`", 1, true) ~= nil, lines[1])
  local method = checker_says(two_values .. "local o = { f = one }\nprint(o.f(two()))\n")
  assert(says(method, "the last argument two(...) returns 2 values"), table.concat(method, "\n"))
  local qualified = checker_says("local record M\n  two: function(): string, string\n" ..
      "  one: function(string): boolean\nend\nlocal m: M = {}\nprint(m.one(m.two()))\n")
  assert(says(qualified, "the last argument m.two(...) returns 2 values"),
    table.concat(qualified, "\n"))
end

--- An assert in the last position is told the same on the arity error,
--- and its own message, which `cosmic fix` reads, stays.
local function test_a_spilled_assert_is_told_on_the_arity_error()
  local lines = checker_says(two_values .. "local function pair(): string | nil, string\n" ..
      "  return \"a\", \"b\"\nend\nprint(one(assert(pair())))\n")
  assert(lines[1]:find("^wrong number of arguments %(given 2, expects 1%) %-%- the last " ..
      "argument assert%(%.%.%.%)"), lines[1])
  assert(lines[1]:find("`cosmic fix` writes the parentheses", 1, true) ~= nil, lines[1])
  assert(says(lines, "write (assert(...)) to keep only the first"), table.concat(lines, "\n"))
end

--- A call that is short, or given one value by each argument, or whose
--- last argument is parenthesized or returns one value, gets no such hint.
local function test_other_arity_errors_get_no_spill_hint()
  for _, body in ipairs({
      "print(one())\n",
      "print(one(\"a\", \"b\"))\n",
      "print(one(tostring(1), tostring(2)))\n",
      "print(one(two(), \"b\"))\n",
  }) do
    local lines = checker_says(two_values .. body)
    assert(#lines > 0, body)
    assert(not says(lines, "the last argument"), body .. table.concat(lines, "\n"))
  end
  assert(#checker_says(two_values .. "print(one((two())))\n") == 0)
end

local nested_generic = "local record Kv\n  record Lru<K, V>\n    map: {K: V}\n  end\nend\n"

--- A method declared on a generic record nested in another is told the
--- form that works, with the type arguments and owner as written.
local function test_a_nested_generic_method_is_told_its_form()
  local lines = checker_says(nested_generic ..
      "function Kv.Lru:get(k: K): V\n  return self.map[k]\nend\nreturn Kv\n")
  assert(says(lines, "missing type arguments in record<K, V> Lru -- a generic record's method"),
    table.concat(lines, "\n"))
  assert(says(lines, "`function Kv.Lru.get<K, V>(self: Kv.Lru<K, V>, ...)`"), table.concat(lines, "\n"))
  assert(#checker_says(nested_generic .. "function Kv.Lru.get<K, V>(self: Kv.Lru<K, V>, k: K): V\n" ..
      "  return self.map[k]\nend\nreturn Kv\n") == 0)
end

--- The same message on a line that declares no method is told nothing.
local function test_missing_type_arguments_elsewhere_get_no_method_hint()
  local lines = checker_says(nested_generic .. "local l: Kv.Lru = nil\nreturn l\n")
  assert(says(lines, "missing type arguments in record<K, V> Lru"), table.concat(lines, "\n"))
  assert(not says(lines, "a generic record's method"), table.concat(lines, "\n"))
end

--- `<close>` on a record is told to declare a `__close`; a type that
--- cannot have one, or an enum, is not.
local function test_a_non_closable_record_is_told_to_declare_close()
  local source = "local record S\n  n: integer\nend\nlocal s <close> = nil\n"
  local hint = teal.replacement("to-be-closed variable s has a non-closable type S", source, 4, 7)
  assert(hint ~= nil and hint:find("^`<close>` calls a `__close` the value's metatable holds"), tostring(hint))
  assert(hint:find("metamethod __close: function(S)", 1, true) ~= nil, hint)
  assert(hint:find("metatable<S> = { __close = function(self: S)", 1, true) ~= nil, hint)
  assert(hint:find("cosmic docs Fs.Scratch.__close", 1, true) ~= nil, hint)
  assert(hint:find("is a record of yours", 1, true) == nil, hint)
  local qualified = teal.replacement("to-be-closed variable s has a non-closable type Fs.Scratch",
    source, 4, 7)
  assert(qualified ~= nil and qualified:find("^if Fs.Scratch is a record of yours, "), tostring(qualified))
  local enum = "to-be-closed variable e has a non-closable type E"
  assert(teal.replacement(enum, 'local enum E "a" end\n', 1, 1) == nil)
  assert(teal.replacement(enum, 'local type E = integer\n', 1, 1) == nil)
  for _, plain in ipairs({ "integer", "string", "{string}", "function(): integer", "boolean" }) do
    assert(teal.replacement("to-be-closed variable n has a non-closable type " .. plain, source, 4, 7) == nil,
      plain)
  end
end

--- A string literal in a type position is told to declare an enum.
local function test_a_string_literal_type_is_told_to_declare_an_enum()
  local lines = checker_says("local s: integer | \"null\" = \"null\"\nprint(s)\n")
  assert(lines[1]:find("^expected a type list %-%- a string literal is not a type"), lines[1])
  assert(says(lines, "`local enum Name \"null\" end`"), table.concat(lines, "\n"))
  local two = checker_says("local x: \"a\" | \"b\" = \"a\"\nprint(x)\n")
  assert(says(two, "`local enum Name \"a\" \"b\" end`"), table.concat(two, "\n"))
end

--- A missing type that is no string literal is told nothing about one.
local function test_a_missing_type_without_a_literal_gets_no_enum_hint()
  local lines = checker_says("local s: = \"null\"\nprint(s)\n")
  assert(says(lines, "expected a type list"), table.concat(lines, "\n"))
  assert(not says(lines, "string literal"), table.concat(lines, "\n"))
end

--- Type arguments at a call are told Teal has none.
local function test_call_site_type_arguments_are_told_there_are_none()
  local lines = checker_says("local function f<K>(k: K): K\n  return k\nend\nprint(f<string>(\"a\"))\n")
  assert(says(lines, "for types function<K>(K): K and string -- Teal has no type arguments at a call"),
    table.concat(lines, "\n"))
  local comparison = checker_says("local function f<K>(k: K): K\n  return k\nend\nprint(f < 1)\n")
  assert(not says(comparison, "no type arguments"), table.concat(comparison, "\n"))
end

--- A method used above its definition is told to move it or declare it.
local function test_a_method_used_before_its_definition_is_told_so()
  local lines = checker_says("local record Store\n  db: integer\nend\n" ..
      "local mt = { __gc = function(s: Store) s:close() end }\n" ..
      "function Store:close()\n  print(self.db)\nend\nprint(mt)\n")
  assert(says(lines, "invalid key 'close' in record 's' of type Store -- `close` is defined below, " ..
      "at line 5"), table.concat(lines, "\n"))
  assert(says(lines, "`close: function(self: Store, ...)`"), table.concat(lines, "\n"))
  local declared = checker_says("local record Store\n  db: integer\n  close: function(self: Store)\nend\n" ..
      "local mt = { __gc = function(s: Store) s:close() end }\n" ..
      "function Store:close()\n  print(self.db)\nend\nprint(mt)\n")
  assert(#declared == 0, table.concat(declared, "\n"))
end

--- A key the file never defines, or defines above, is told only its fields.
local function test_a_missing_key_not_defined_below_gets_no_order_hint()
  local lines = checker_says("local record Store\n  db: integer\nend\n" ..
      "local mt = { __gc = function(s: Store) s:close() end }\nprint(mt)\n")
  assert(says(lines, "invalid key 'close'"), table.concat(lines, "\n"))
  assert(not says(lines, "defined below"), table.concat(lines, "\n"))
end

--- Parenthesizing cures only too many arguments for a callee that takes
--- some: a short call, or one to a callee taking none, is told nothing,
--- and a call a special function handler checks twice is told once.
local function test_a_spill_hint_is_for_too_many_arguments_only()
  local callees = "local function four(a: string, b: string, c: string, d: string) end\n" ..
    "local function many(a: string, b: string, c: string, ...: string) end\n" ..
    "local function none() end\n"
  for _, body in ipairs({ "four(\"x\", two())\n", "many(two())\n", "none(two())\n" }) do
    local lines = checker_says(two_values .. callees .. body)
    assert(says(lines, "wrong number of arguments"), body .. table.concat(lines, "\n"))
    assert(not says(lines, "the last argument"), body .. table.concat(lines, "\n"))
  end
  local lines = checker_says(two_values .. callees .. "pcall(one, two())\n")
  local seen = 0
  for _, line in ipairs(lines) do
    local _, count = line:gsub(" %-%- the last argument", "")
    seen = seen + count
  end
  assert(seen <= 1, table.concat(lines, "\n"))
end

--- A method defined below with a dot is offered as the template it is.
local function test_a_later_dotted_function_is_told_as_written()
  local lines = checker_says("local record Store\n  db: integer\nend\n" ..
      "local function use(s: Store) s.later(1) end\n" ..
      "function Store.later(n: integer)\n  print(n)\nend\nprint(use)\n")
  assert(says(lines, "define `function Store.later` above this use"), table.concat(lines, "\n"))
  assert(says(lines, "`later: function(...)` in the record, with the definition's own parameters"),
    table.concat(lines, "\n"))
  assert(not says(lines, "self: Store"), table.concat(lines, "\n"))
end

--- A type argument at a call that the checker reads as a variable is
--- told the same, and a comparison of unknown names is not.
local function test_a_call_site_type_name_is_told_there_are_none()
  local lines = checker_says("local function f<K>(k: K): K\n  return k\nend\nprint(f<integer>(1))\n")
  assert(says(lines, "unknown variable: integer -- Teal has no type arguments at a call"),
    table.concat(lines, "\n"))
  local compared = checker_says("print(missing < 1)\n")
  assert(says(compared, "unknown variable: missing"), table.concat(compared, "\n"))
  assert(not says(compared, "no type arguments"), table.concat(compared, "\n"))
end
