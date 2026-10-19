--- Regression tests for [`build.teal.lazy`]: the capsule that loads the
--- compiler on first use has to behave as the compiler itself,
--- including for writes. tl reaches `search_module` and `path` through
--- its own module table, so an override `serve` writes has to land on
--- the loaded compiler rather than on the capsule; a capsule that kept
--- the write for itself would leave the checker searching the
--- filesystem.
local type compiler = require("build.compiler")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local teal = require("build.teal")

--- The declarations of the error record, which the drift test and the
--- keys every diagnostic test sees are held to.
Test.policy{ grants = {
  { path = "checker/tl.tl", letters = "r" },
  { path = "build/compiler.d.tl", letters = "r" },
} }

-- These cases assert checker positions and generated code, never the
-- vendor compiler's own Lua traceback lines, which no tree coverage uses.

--- A field written through the capsule reaches the loaded compiler:
--- the capsule itself never holds it, and reading it back through the
--- capsule finds the written value, not the compiler's own.
local function test_lazy_write_lands_on_the_compiler()
  local built = teal.lazy()
  local marker = function(_name: string, _search_all: boolean): string | nil, compiler.Handle | nil
    return nil
  end
  built.search_module = marker
  assert(rawget(built as {any:any}, "search_module") == nil,
    "the capsule kept the write instead of passing it on")
  assert(built.search_module == marker)
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
  local function one(_name: string, _search_all: boolean): string | nil, compiler.Handle | nil
    return nil
  end
  local function other(_name: string, _search_all: boolean): string | nil, compiler.Handle | nil
    return nil
  end
  first.search_module = one
  second.search_module = other
  assert(first.search_module == one)
  assert(second.search_module == other)
end

--- The field names of `record Error` and the members of `enum ErrorCode`
--- in the source text `text`, whose declarations sit `indent` deep.
local function error_declarations(text: string, indent: string): {string:boolean}, {string:boolean}
  local fields: {string:boolean} = {}
  local codes: {string:boolean} = {}
  local inside: string | nil = nil
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if line == indent .. "record Error" then
      inside = "record"
    elseif line == indent .. "enum ErrorCode" then
      inside = "enum"
    elseif line == indent .. "end" then
      inside = nil
    elseif inside == "record" then
      local name = line:match("^%s+([%a_]+)%??:")
      if name ~= nil then
        fields[name] = true
      end
    elseif inside == "enum" then
      local member = line:match('^%s+"([%a_]+)"$')
      if member ~= nil then
        codes[member] = true
      end
    end
  end
  return fields, codes
end

--- Whether `a` and `b` hold the same names; the first that one holds
--- and the other lacks, otherwise.
local function same_names(a: {string:boolean}, b: {string:boolean}): boolean, string | nil
  for name in pairs(a) do
    if not b[name] then
      return false, name
    end
  end
  for name in pairs(b) do
    if not a[name] then
      return false, name
    end
  end
  return true
end

--- Holds every error and warning in `result` to the fields `record Error`
--- declares, so a field misspelt at any site the checker sets it is caught
--- by whichever test reaches the site.
local function vet(result: compiler.Result | nil)
  if result == nil then
    return
  end
  local declared = error_declarations(assert(Fs.read("build/compiler.d.tl")), "  ")
  for _, group in ipairs({ result.syntax_errors, result.type_errors, result.warnings }) do
    for _, e in ipairs(group) do
      for key in pairs(e as {string:any}) do
        assert(declared[key], "the checker set `" .. tostring(key) .. "`, which record Error lacks: " .. e.msg)
      end
    end
  end
end

--- What the checker reports for `source`, each error held to [`vet`].
local function generate(built: compiler, source: string): string | nil, compiler.Result
  local code, result = built.gen(source, nil, nil, "tl")
  vet(result)
  return code, result
end

local integer_msg = "in assignment: got number, expected integer"

--- The members of a type shown as the checker shows it, less where it
--- was inferred: the shown types here are simple, so a union splits at its
--- ` | `.
local function members_of(shown: string): {string}
  local bare = shown:gsub(" %(inferred at [^)]*%)$", "")
  local found: {string} = {}
  for member in (bare .. " | "):gmatch("(.-) | ") do
    found[#found + 1] = member
  end
  return found
end

--- A refusal of kind `code` at 1:1 with nothing else set; the helpers
--- below fill in what the kind names.
local function blank(code: compiler.ErrorCode): compiler.Error
  return { code = code, msg = "", filename = "", y = 1, x = 1 }
end

--- `e` at line `y`, column `x`.
local function at(e: compiler.Error, y: integer, x: integer): compiler.Error
  e.y, e.x = y, x
  return e
end

--- The refusal of a value shown `got` where `expected` is wanted, in the
--- place the checker names `context` ("argument", with its `index`, or
--- "in assignment", "in local declaration" with the variable `name`).
local function mismatch(got: string, expected: string, context: string, index?: integer,
                        name?: string): compiler.Error
  local e = blank("mismatch")
  e.got, e.got_members = got, members_of(got)
  e.expected, e.expected_members = expected, members_of(expected)
  e.context, e.index, e.context_name = context, index, name
  return e
end

--- The refusal of a nominal type shown `got` for one shown `expected`, as
--- an argument.
local function not_a(got: string, expected: string, index: integer): compiler.Error
  local e = blank("not_a")
  e.got, e.expected, e.context, e.index = got, expected, "argument", index
  return e
end

--- The refusal of the key `key` of the record shown `subject`, read
--- through the variable `variable` (nil for an expression that is none),
--- whose value fields are `fields`.
local function invalid_key(key: string, variable: string | nil, subject: string,
                           fields?: {string}): compiler.Error
  local e = blank("invalid_key")
  e.key, e.variable, e.subject, e.fields = key, variable, subject, fields
  e.subject_kind = subject:match("^record ") ~= nil and "record" or "nominal"
  e.resolved_kind = "record"
  return e
end

--- The refusal of the name `variable`, as a variable declared nowhere or a
--- declaration that hides another.
local function named(code: compiler.ErrorCode, variable: string): compiler.Error
  local e = blank(code)
  e.variable = variable
  return e
end

local function unknown_variable(variable: string): compiler.Error
  return named("unknown_variable", variable)
end

--- The refusal of a call given `given` arguments for a callee that takes `expects`.
local function arity(given: integer, expects: integer): compiler.Error
  local e = blank("arity")
  e.given, e.expects, e.expects_most = given, expects, expects
  return e
end

--- The refusal of the type name `Owner.Member`.
local function unknown_type(...: string): compiler.Error
  local e = blank("unknown_type")
  local names: {string} = { ... }
  e.names = names
  e.subject = table.concat(names, ".")
  return e
end

--- The refusal of a type shown `subject`, which a code that is about one
--- type reads the `members` of.
local function about(code: compiler.ErrorCode, subject: string, variable?: string): compiler.Error
  local e = blank(code)
  e.subject, e.members, e.variable = subject, members_of(subject), variable
  return e
end

--- What [`teal.replacement`] says for the first "got number, expected
--- integer" the checker reports for `source`, and where: nil when it
--- reports none, or the hint is nil.
local function hint_for(source: string): string | nil, string
  local built = assert(teal.load(true))
  local _, result = generate(built, source)
  for _, e in ipairs(result ~= nil and result.type_errors or {}) do
    if e.msg == integer_msg then
      return teal.replacement(e, source), e.y .. ":" .. e.x
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

--- A literal with digit separators is quoted as written.
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
  assert(teal.replacement(at(mismatch("string", "integer", "in assignment"), 2, 5),
    "local x = 0\nx = 'a'\n") == nil)
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
  assert(teal.replacement(at(mismatch("number", "integer", "in assignment"), 3, 10),
    "local self = 0\nfunction R:m()\n  self = 1.5\nend\n") == converted)
end

--- The type errors the checker reports for `source`, failing the test
--- where it raises instead.
local function type_errors(source: string): {compiler.Error}
  local built = assert(teal.load(true))
  local ok, code, result = pcall(generate, built, source)
  assert(ok, tostring(code))
  return assert(result).type_errors
end

--- The checker's record for `_G` has the place it is read at. Without one, an
--- error about it -- reported, or only tried, as narrowing a variable a loop
--- assigns tries one -- failed an assertion instead.
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
  local _, result = generate(built, source)
  local out: {string} = {}
  for _, e in ipairs(assert(result).syntax_errors) do
    out[#out + 1] = e.y .. ":" .. e.x .. " " .. e.msg
  end
  return out
end

--- A `return` closed by a `;` may end any block, as it may end the file, and a statement
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
--- byte.
local function test_a_call_after_a_string_spanning_lines()
  local built = assert(teal.load(true))
  for _, source in ipairs({ "f [[a\nb]](1)\n", "f 'a\\z\n  b'(1)\n", "f [==[\n]==]{}(1)\n" }) do
    local found = syntax_errors(source)
    assert(#found == 0, source .. table.concat(found, "; "))
    local code = assert(generate(built, source))
    assert(code:find(";", 1, true) == nil, code)
  end
  local tokens, errs = built.lex("f [[a\nbc]]\n(g)(1)\n", "t.tl")
  built.parse_program(tokens, errs, "t.tl")
  assert(#errs == 0, tostring(errs[1] and errs[1].msg))
  local inserted: compiler.Token | nil = nil
  for _, t in ipairs(tokens) do
    if t.tk == ";" then inserted = t end
  end
  assert(inserted ~= nil and inserted.y == 2 and inserted.x == 5,
    inserted and inserted.y .. ":" .. inserted.x or "no ';'")
end

--- A function type's return types end before a `,` and a parameter
--- spelled `name?:`, `?T` or `...`, as before one spelled `name:`; none of
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

--- A table literal that gives a key twice is refused, whatever the literal is checked against: a name and the same string
--- in brackets are one key, as are a number and a boolean written twice. The new checker holds the same rule
--- (`literal_repeated`, [`lang.check`]), which the switch's gate reads from this test's programs.
local function test_a_table_literal_repeating_a_key_is_refused()
  local built = assert(teal.load(true))
  for _, source in ipairs({
      "local t = { a = 1, a = 2 }\nprint(t)\n",
      "local t = { [\"a\"] = 1, [\"a\"] = 2 }\nprint(t)\n",
      "local t = { a = 1, [\"a\"] = 2 }\nprint(t)\n",
      "local t: {integer: string} = { [1] = \"x\", [1] = \"y\" }\nprint(t)\n",
      "local t: {boolean: string} = { [true] = \"x\", [true] = \"y\" }\nprint(t)\n",
      "local t: {string: integer} = { a = 1, b = 2, a = 3 }\nprint(t)\n",
      "local record R\n  a: integer\nend\nlocal r: R = { a = 1, a = 2 }\nprint(r)\n",
      "local t = { inner = { a = 1, a = 2 } }\nprint(t)\n",
  }) do
    local _, result = built.gen(source, nil, nil, "tl")
    local message = tostring((assert(result).type_errors[1] or result.syntax_errors[1] or {}).msg)
    assert(message:find("redeclared key", 1, true) ~= nil, source .. message)
  end
  local _, fine = built.gen("local t = { a = 1, b = 2 }\nlocal u = { [1] = \"x\", [2] = \"y\" }\nprint(t, u)\n", nil, nil, "tl")
  assert(#assert(fine).type_errors == 0 and #fine.syntax_errors == 0)
end

--- `record`, `interface` and `enum` name variables as well as start
--- types: one after `=` is read as the type syntax 0.7.1 dropped only
--- where a type body declaring something follows it, so a loop's
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

-- TODO: count the tokens a look reads, once the checker's look_ahead
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
  assert(teal.replacement(at(unknown_variable("os"), 1, 8),
    "return os.getenv('HOME')\n") == nil)
  assert(teal.replacement(at(invalid_key("hex", "Hash", "Hash"), 2, 13),
    'local Hash = require("cosmic.hash")\nreturn Hash.hex\n') == nil)
  assert(package.loaded["cosmic.removed"] == nil)
end

--- A refused `local type` require is read from the parsed source, so
--- the text of one in a long string or comment at the refusal's position
--- is never taken for it.
local function test_a_type_require_in_a_string_or_comment_is_no_require()
  local refusal = blank("require_not_type")
  refusal.got, refusal.got_kind = "integer", "integer"
  local declared = 'local type X = require("x")\n'
  assert(teal.replacement(at(refusal, 1, 16), declared) ==
      "x returns a value, not a type: a `local type` require needs the module to return one, " ..
      "as `local record M ... end return M` or a `.d.tl` does")
  assert(teal.replacement(at(refusal, 2, 16), "local s = [[\n" .. declared .. "]]\nreturn s\n") == nil)
  assert(teal.replacement(at(refusal, 2, 16), "--[[\n" .. declared .. "]]\nreturn 1\n") == nil)
end

--- What [`teal.replacement`] says for the first diagnostic the checker
--- reports for `source` (an error or a warning) whose message is
--- `msg`: "no such diagnostic" when it reports none.
local function replacement_for(source: string, msg: string): string | nil
  local built = assert(teal.load(true))
  local _, result = generate(built, source)
  local found = result ~= nil
  for _, group in ipairs(found and { result.type_errors, result.warnings } or {}) do
    for _, e in ipairs(group) do
      if e.msg == msg then
        return teal.replacement(e, source)
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
  assert(teal.replacement(at(mismatch("number (inferred at :2:11)", "integer", "argument", 1), 3, 9),
    "") == converted)
  assert(replacement_for(f:gsub("n: integer%)", "n: integer | nil)") .. "print(f(7 / 2))\n",
    "argument 1: got number, expected integer | nil") == converted)
  assert(teal.replacement(mismatch("string", "integer", "argument", 1), "") == nil)
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
  assert(teal.replacement(at(named("shadows", "total"), 2, 7), "") == nil)
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
  assert(teal.replacement(at(invalid_key("write", "io", "R"), 3, 9), "") == nil)
  assert(teal.replacement(at(named("shadows", "io"), 2, 7), "") == nil)
end

--- tl checked no value named for a simple type for shadowing, and so
--- never warned of one named `string`, the string library. `any` and `thread`
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
  assert(teal.replacement(at(not_a("Store", "Store", 1), 8, 8), "") == twice)
  assert(teal.replacement(not_a("Kv.Store", "Store", 1), "") ==
      "two distinct types are both named Store: use Kv.Store rather than declaring Store " ..
      "again, as 'local type Store = Kv.Store'")
  assert(teal.replacement(not_a("Store", "Kv.Entry", 1), "") == nil)
  assert(teal.replacement(not_a("A.Node", "B.Node", 1), "") == nil)
end

--- `Kv.Kv` for a module bound to `Kv` is told `Kv` is the type; a name
--- no `require` binds is not, nor one whose `local type` require the
--- compile refused.
local function test_a_module_type_named_twice_is_told_its_name()
  local source = 'local Kv = require("kv")\nlocal k: Kv.Kv = Kv\nreturn k\n'
  assert(teal.replacement(at(unknown_type("Kv", "Kv"), 2, 10), source) ==
      "Kv is itself the type of the record its module returns: write Kv, not Kv.Kv")
  assert(teal.replacement(at(unknown_type("Kv", "Kv"), 2, 10), "local Kv = {}\nlocal k: Kv.Kv\n") == nil)
  -- A `local type` require the compile refused holds no type at all.
  local typed = 'local type Kv = require("kv")\nlocal k: Kv.Kv\n'
  assert(teal.replacement(at(unknown_type("Kv", "Kv"), 2, 10), typed) ==
      "Kv is itself the type of the record its module returns: write Kv, not Kv.Kv")
  local answer = teal.replacement(at(unknown_type("Kv", "Kv"), 2, 10), typed, "main.tl", { Kv = true })
  assert(answer == nil, answer)
  -- Another type of the module is told what the module must declare.
  assert(teal.replacement(at(unknown_type("Kv", "Store"), 2, 10), source) ==
      "Kv has no type Store: check its spelling, or declare `record Store ... end` " ..
      "inside the record kv returns (a `local record Store` beside that record is its " ..
      "file's alone)")
end

--- A module bound by a `require` written over two lines, without
--- parentheses or with a comment between its tokens is named as one on a
--- line is; the text of one in a long string or comment binds nothing,
--- nor declares a type.
local function test_a_module_bound_however_written_is_named()
  local itself = "Kv is itself the type of the record its module returns: write Kv, not Kv.Kv"
  local no_store = "Kv has no type Store: check its spelling, or declare `record Store ... end` " ..
    "inside the record kv returns (a `local record Store` beside that record is its " ..
    "file's alone)"
  for _, binding in ipairs({
      'local Kv =\n  require("kv")',
      'local Kv = require "kv"',
      "local Kv <const> = require'kv'",
      'local Kv = --[[ the store ]] require(\n  "kv"\n)',
      'local type Kv =\n  require "kv"',
  }) do
    local source = binding .. "\nlocal k: Kv.Kv\n"
    assert(teal.replacement(at(unknown_type("Kv", "Kv"), 2, 10), source) == itself, source)
    assert(teal.replacement(at(unknown_type("Kv", "Store"), 2, 10), source) == no_store, source)
  end
  for _, source in ipairs({
      'local s = [[\nlocal Kv = require("kv")\n]]\nlocal k: Kv.Kv\n',
      '--[[\nlocal Kv <const> = require("kv")\n]]\nlocal k: Kv.Kv\n',
      '--[[\nlocal type Kv = require("kv")\n]]\nlocal k: Kv.Kv\n',
  }) do
    assert(teal.replacement(at(unknown_type("Kv", "Kv"), 4, 10), source) == nil, source)
    assert(teal.replacement(at(unknown_type("Kv", "Store"), 4, 10), source) == nil, source)
  end
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
  assert(teal.replacement(invalid_key("nope", "r", "R", { "move" }), "") ==
      "R's fields: move")
  -- An inferred type is named without where it was inferred, and a
  -- record no variable names as "the record".
  assert(teal.replacement(invalid_key("lenn", "s", "string \"x\"", { "len" }), "") ==
      "did you mean 'len'? string \"x\"'s fields: len")
  assert(replacement_for("print(({a = 1}).b)\n", "invalid key 'b' in type record (a: integer)") ==
      "the record's fields: a")
  -- Without the fields the checker gives, nothing is guessed.
  assert(teal.replacement(invalid_key("alpah", "r", "R"), "") == nil)
  -- A table literal's field its record lacks is told the same.
  assert(replacement_for("local record R\n  alpha: integer\n  beta: string\nend\n" ..
      "local r: R = {alpah = 1}\nprint(r)\n", "in local declaration: r: unknown field alpah") ==
      "did you mean 'alpha'? " .. fields)
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
  assert(teal.replacement(invalid_key("ab", "r", "R", { "ac", "ad", "aa" }), "") ==
      "did you mean 'aa', 'ac' or 'ad'? R's fields: aa, ac, ad")
  assert(teal.replacement(invalid_key("ab", "r", "R", { "ac", "ad", "aa", "ae" }), "") ==
      "R's fields: aa, ac, ad, ae")
  assert(teal.replacement(invalid_key("stats", "fs", "fs", { "Stat", "stat" }), "") ==
      "did you mean 'stat'? fs's fields: Stat, stat")
end

--- A record of many fields lists the first ten alphabetically and says
--- how many more it has; a module record described rather than named
--- (`record Module`) is named by its variable.
local function test_a_missing_field_lists_a_bounded_few()
  local names: {string} = {}
  for i = 12, 1, -1 do
    names[#names + 1] = string.format("f%02d", i)
  end
  assert(teal.replacement(invalid_key("zzzzzz", "big", "Big", names), "") ==
      "Big's fields: f01, f02, f03, f04, f05, f06, f07, f08, f09, f10 and 2 more")
  assert(teal.replacement(invalid_key("parsee", "Cli", "record Module", { "parse" }), "") ==
      "did you mean 'parse'? Cli's fields: parse")
end

--- An assignment to a for loop's control variable -- a numeric for's, or the
--- first of a generic for's -- is refused at its own line, as Lua 5.5, which
--- makes it read-only, would refuse only the generated chunk. A generic for's
--- other variables, a local declared over the variable, and a parameter of
--- its name are assignable.
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
  assert(teal.replacement(at(arity(1, 2), 2, 7),
    'local Fs = require("cosmic.fs")\nFs.put("x")\n') == nil)
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
  assert(teal.replacement(invalid_key("string", "Stream", "Stream", fields), "") ==
      "did you mean 'from_string'? " .. listed)
  assert(teal.replacement(invalid_key("from", "Stream", "Stream", fields), "") ==
      "did you mean 'from_fd' or 'from_string'? " .. listed)
  assert(teal.replacement(invalid_key("read_lines", "Stream", "Stream", fields), "") ==
      "did you mean 'lines'? " .. listed)
  assert(teal.replacement(invalid_key("pe", "Stream", "Stream", fields), "") ==
      listed)
  assert(teal.replacement(invalid_key("get", "T", "T", { "target", "set_get" }), "") ==
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
  local month = mismatch("<any type>", "L.Month", "argument", 1)
  month.expected_names = { "L", "Month" }
  assert(teal.replacement(month, 'local L = require("app.ledger")\n') ==
      "the value is any (untyped): cast it unchecked: `value as L.Month`; if L.Month is a record, " ..
      "`Shape.record_of(\"app.ledger.Month\"):into(value)` checks it " ..
      "(local Shape = require(\"cosmic.shape\"))")
  assert(teal.replacement(month, "") ==
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
  assert(teal.replacement(about("not_closable", "R | nil", "g"), "") ==
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
  assert(teal.replacement(unknown_type("Ledger", "Transaction"),
    'local Ledger = require("ledger")\n') ==
      "Ledger has no type Transaction: check its spelling, or declare `record Transaction ... end` " ..
      "inside the record ledger returns (a `local record Transaction` beside that record is its " ..
      "file's alone)")
  -- Bound by a type-only `require` alike.
  assert(teal.replacement(unknown_type("Ledger", "Month"), 'local type Ledger = require("ledger")\n') ==
      "Ledger has no type Month: check its spelling, or declare `record Month ... end` " ..
      "inside the record ledger returns (a `local record Month` beside that record is its " ..
      "file's alone)")
  -- An enum beside the record is told to move as itself.
  answers("local enum Month\n  \"may\"\nend\nlocal record Ledger\nend\n" ..
      "local m: Ledger.Month = \"may\"\nprint(m)\nlocal x: Month = \"may\"\nprint(x)\nreturn Ledger\n",
    "unknown type Ledger.Month",
    "Month is declared beside Ledger, not inside it: move `enum Month ... end` " ..
      "into `local record Ledger ... end` to name it Ledger.Month")
  assert(teal.replacement(unknown_type("Http", "Address"), 'local Http = require("cosmic.http")\n') == nil)
end

--- What [`teal.replacement`] says of the first syntax error in `source`.
local function syntax_hint(source: string): string | nil
  local built = assert(teal.load(true))
  local _, result = generate(built, source)
  local e = assert(assert(result).syntax_errors[1], source)
  assert(e.code == "expected_one_of", e.msg)
  return teal.replacement(e, source)
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
  local ok, code, result = pcall(generate, built, source)
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

--- `: never` is a return list that says a function does not return: it parses
--- on a declaration, a method, a function type and a function-typed parameter
--- that another follows, and the Lua it generates is the Lua of the same
--- function without it.
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

--- A function that never returns stands for a function of any returns,
--- `pcall`'s parameter among them; one that may return does not stand for one
--- that never does, which would make `f("x")` end a block that `print`
--- returns from.
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
      "function Guard.die(why: string): never error(why) end\n", "which differ in whether the function never returns")
  assert_refused(record_with_field:format(": never") ..
      "function Guard.die(why: string) print(why) end\n", "which differ in whether the function never returns")
  assert_accepted(record_with_field:format(": never") ..
      "function Guard.die(why: string): never error(why) end\nprint(Guard)\n")
end

--- An overloaded function stands for one that never returns only when
--- every overload does (43e4); the overload a call picks decides
--- whether the call ends a block (43f1).
local function test_a_poly_function_is_never_only_when_every_overload_is()
  local poly = "local record P\n  f: function(string): never\n  f: function(%s)%s\nend\nlocal function probe(p: P)\n"
  local read = "local g: function(string): never = p.f\nprint(g)\nend\nprint(probe)\n"
  assert_accepted(poly:format("integer", ": never") .. read)
  assert_refused(poly:format("integer", ": string") .. read, "polymorphic function with an overload that may return")
end

--- A function type takes the parameters of the one it stands for
--- contravariantly: it must accept all that one is
--- given, so one that takes a narrower type is refused, where a wider
--- one is fine. `cb` is called by `f`'s caller with a function returning
--- a number, which the body would use as an integer.
local function test_a_function_parameter_is_contravariant()
  assert_refused("local f: function(cb: function(): number) = function(cb: function(): integer) print(cb) end\n" ..
      "print(f)\n", "argument 1")
  assert_refused("local f: function(number) = function(n: integer) print(n) end\nprint(f)\n", "argument 1")
  assert_refused("local f: function(string, number) = function(s: string, n: integer) print(s, n) end\n" ..
      "print(f)\n", "argument 2")
  assert_accepted("local f: function(integer) = function(n: number) print(n) end\nprint(f)\n")
  assert_accepted("local f: function(cb: function(): integer) = function(cb: function(): number) print(cb) end\n" ..
      "print(f)\n")
end

--- A function type gives its returns covariantly: a
--- narrower return is accepted, and a wider one refused, since its
--- caller would use the number as the integer it was promised.
local function test_a_function_return_is_covariant()
  assert_accepted("local f: function(): number = function(): integer return 1 end\nprint(f)\n")
  assert_refused("local f: function(): integer = function(): number return 1.5 end\nprint(f)\n", "return 1")
  assert_refused("local f: function(): (integer, string) = function(): (integer, number) return 1, 2.5 end\n" ..
      "print(f)\n", "return 2")
end

local receiver_types = "local interface Reader\n  read: function(Reader, integer): string\nend\n" ..
  "local record Mine is Reader\n  extra: integer\nend\n"

--- The first parameter of a function-typed field is the receiver, and
--- may be narrower than the field declares: the record
--- that holds the function is what it is called with. A record that
--- redeclares the field with its own type as the receiver is an
--- implementation of the interface that declares it.
local function test_a_field_function_takes_a_narrower_receiver()
  assert_accepted("local interface Reader\n  read: function(Reader, integer): string\nend\n" ..
      "local record Mine is Reader\n  extra: integer\n  read: function(Mine, integer): string\nend\n" ..
      "print(Mine)\n")
end

--- Only the first parameter of a field's function is exempt, and only
--- where the function is compared as a field: its other parameters, its
--- returns, and a function of a variable are held to the rule (48a, 48b).
local function test_only_a_record_receiver_of_a_field_function_is_exempt()
  assert_accepted("local interface Reader\n  read: function(Reader, integer): string\nend\n" ..
      "local record Mine is Reader\n  read: function(Mine, number): string\nend\nprint(Mine)\n")
  assert_refused("local interface Reader\n  read: function(Reader, number): string\nend\n" ..
      "local record Mine is Reader\n  read: function(Mine, integer): string\nend\nprint(Mine)\n",
    "field 'read' does not match definition in interface Reader")
  assert_refused("local interface Reader\n  read: function(Reader): integer\nend\n" ..
      "local record Mine is Reader\n  read: function(Mine): number\nend\nprint(Mine)\n",
    "field 'read' does not match definition in interface Reader")
  assert_refused(receiver_types .. "local f: function(Reader) = function(m: Mine) print(m) end\nprint(f)\n",
    "argument 1")
  assert_refused(receiver_types .. "local record Box\n  run: function(Box, function(Mine))\nend\n" ..
      "local b: Box = { run = function(self: Box, f: function(Reader)) print(self, f) end }\nprint(b)\n",
    "argument 2")
  -- a first parameter that is no record or interface is no receiver
  assert_refused("local record Opts\n  cb: function(number): number\nend\n" ..
      "local o: Opts = { cb = function(n: integer): number return n end }\nprint(o)\n", "argument 1")
  assert_refused("local record Opts\n  cb: function(number): number\nend\nlocal function probe(o: Opts)\n" ..
      "o.cb = function(n: integer): number return n end\nprint(o)\nend\nprint(probe)\n", "argument 1")
  assert_refused("local interface Named\n  f: function(string): string\nend\n" ..
      "local record Impl is Named\n  f: function(integer): string\nend\nprint(Impl)\n",
    "field 'f' does not match definition in interface Named")
end

--- The fields of a record are compared as fields wherever a record is
--- compared with another type: a table
--- whose function takes a narrower receiver is taken for the interface,
--- as a literal of it and as an assignment to its field.
local function test_a_narrower_receiver_is_taken_wherever_fields_are_compared()
  -- 48g: an inferred table, compared with the interface structurally
  assert_accepted(receiver_types ..
      "local t = { read = function(self: Mine, n: integer): string print(self, n) return '' end }\n" ..
      "local r: Reader = t\nprint(r)\n")
  -- 48h is the record that declares the interface's field itself, above
  -- 48i: a literal of the interface's own type
  assert_accepted(receiver_types ..
      "local r: Reader = { read = function(self: Mine, n: integer): string print(self, n) return '' end }\n" ..
      "print(r)\n")
  -- 48k: an assignment to a field of a value
  assert_accepted(receiver_types .. "local function probe(m: Mine)\n" ..
      "m.read = function(self: Mine, n: integer): string print(self, n) return '' end\nprint(m)\nend\nprint(probe)\n")
  assert_refused(receiver_types .. "local function probe(m: Mine)\nlocal set: function(Reader) = function(_: Reader) end\n" ..
      "local f: function(Reader, integer): string = m.read\n" ..
      "f = function(self: Mine, n: integer): string print(self, n) return '' end\nprint(f, set)\nend\nprint(probe)\n",
    "argument 1")
end

--- The receiver exemption cannot tell a receiver from another record
--- parameter of a field's function, so a callback field that takes an
--- interface also takes a function over one of its records: a known limit,
--- as on main, that named receivers (doc/roadmap.md) close. A record
--- unrelated to the expected one is refused.
local function test_a_callback_field_with_a_record_parameter_is_the_known_limit()
  local events = "local interface Event\n  name: string\nend\n" ..
    "local record KeyEvent is Event\n  key: string\nend\n" ..
    "local record MouseEvent is Event\n  x: integer\nend\n" ..
    "local record Opts\n  cb: function(Event)\n  cb2: function(KeyEvent)\nend\n"
  assert_refused(events .. "local o: Opts = { cb2 = function(m: MouseEvent) print(m) end }\nprint(o)\n", "argument 1")
  assert_accepted(events .. "local o: Opts = { cb = function(k: KeyEvent) print(k.key) end }\nprint(o)\n")
end

--- A parameter expected as `any` is satisfied by a function of any
--- parameter type, as `any` is the unchecked type: the
--- standard library's callbacks take it, so `coroutine.create` of a
--- function with typed parameters and a `__call` metamethod with them are
--- accepted. A parameter expected as a `number` is still not.
local function test_an_any_parameter_takes_any_parameter()
  assert_accepted("local co = coroutine.create(function(a: string, b: integer) print(a, b) end)\n" ..
      "print(coroutine.resume(co, 'x', 1))\n")
  assert_accepted("local o = setmetatable({}, { __call = function(_: {any:any}, a: string) print(a) end })\nprint(o)\n")
  assert_accepted("local f: function(any...): any... = function(a: string, b: integer): string print(b) return a end\n" ..
      "print(f)\n")
  assert_refused("local f: function(number, any) = function(n: integer, s: string) print(n, s) end\nprint(f)\n",
    "argument 1")
end

--- `string.gsub`'s replacement function takes strings,
--- as `string.gmatch` returns its captures, so a function over strings
--- stands for it when the pattern is not a literal that is read capture by
--- capture; a literal pattern with a position capture gives an integer.
local function test_a_gsub_replacement_takes_strings()
  assert_accepted("local pattern: string = '%d'\n" ..
      "print(('a1'):gsub(pattern, function(c: string): string return c end))\n")
  assert_refused("local pattern: string = '%d'\n" ..
      "print(('a1'):gsub(pattern, function(c: integer): string return tostring(c) end))\n", "got function(integer): string")
  assert_accepted("print(('a1'):gsub('()%d', function(at: integer): string return tostring(at) end))\n")
end

--- A type nested in another keeps its never-ness: a function that never
--- returns does not stand for one that may inside an array, a map, a
--- record, a union, an alias or a generic's type argument, as a
--- parameter or as a return, in either direction (43e5). Teal compares
--- what is nested through is_a, an element covariantly, so without this
--- `{function(): never}` stood for `{function(): string}`.
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
        local source = prelude .. "local function probe(a: " .. declared(pair[direction[1]]) ..
          ", b: " .. declared(pair[direction[2]]) .. ")\nb = a\nprint(a, b)\nend\nprint(probe)\n"
        assert_refused(source, "which differ in whether the function never returns, inside another type")
        seen = seen + 1
      end
      for i = 1, 2 do
        assert_accepted(prelude .. "local function probe(a: " .. declared(pair[i]) .. ", b: " ..
            declared(pair[i]) .. ")\nb = a\nprint(a, b)\nend\nprint(probe)\n")
      end
    end
  end
  assert(seen == 24, tostring(seen))
end

--- A parameter that is itself a never-function compares with the callback
--- a function expects: the forward direction forges too (a function taking
--- a never-callback stands for one taking a callback that returns).
local function test_never_agrees_in_a_callback_parameter()
  assert_refused("local function probe(a: function(cb: function(): never), b: function(cb: function(): string))\n" ..
      "b = a\nend\nprint(probe)\n",
    "got function(): never, expected function(): string, which differ in whether")
  assert_refused("local function probe(a: function(cb: function(): string), b: function(cb: function(): never))\n" ..
      "b = a\nend\nprint(probe)\n", "which differ in whether the function never returns, inside another type")
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

--- The standard `error` never returns: it stands for a
--- never-function, and a variable holding it keeps that.
local function test_error_is_a_never_function()
  assert_accepted("local e: function(string): never = error\nlocal f = error\nprint(e, f)\n")
  assert_accepted("print(pcall(error, 'x'))\nlocal g: function(any) = error\nprint(g)\n")
  assert_refused("local f = error\nf = print\n", "may return, where")
  assert(#syntax_errors("local g: function(string): never = error\n") == 0)
end

--- `local x = fail()` is refused as any call that answers nothing is,
--- which says nothing of why a never-function has no value: the hint
--- says it never returns. A function that merely returns nothing gets none.
local function test_a_never_call_has_no_value_to_assign()
  local function hint(source: string): string | nil
    local found = type_errors(source)[1]
    assert(found ~= nil and found.code == "no_initial_value" and found.variable == "x",
      source .. (found and found.msg or "accepted"))
    return teal.replacement(found, source)
  end
  local never_said = "`fail` never returns, so it has no value to assign"
  local declared = hint("local function fail(m: string): never\n  error(m)\nend\nlocal x = fail('a')\nprint(x)\n")
  assert(declared ~= nil and declared:find(never_said, 1, true) ~= nil, tostring(declared))
  local method = hint("local record G\n  fail: function(self: G, m: string): never\nend\n" ..
      "local g: G = {}\nlocal x = g:fail('a')\nprint(x)\n")
  assert(method ~= nil and method:find("`g:fail` never returns", 1, true) ~= nil, tostring(method))
  local standard = hint("local x = error('a')\nprint(x)\n")
  assert(standard ~= nil and standard:find("`error` never returns", 1, true) ~= nil, tostring(standard))
  assert(hint("local function nothing(m: string)\nend\nlocal x = nothing('a')\nprint(x)\n") == nil)
  assert(hint("local function fail(m: string): never\n  error(m)\nend\n" ..
      "local function other(m: string)\nend\nlocal x = other('a')\nprint(x)\n") == nil)
  -- a longer name that ends in the callee's is another function
  assert(hint("local function xfail(m: string): never\n  error(m)\nend\n" ..
      "local function fail(m: string)\nend\nlocal x = fail('a')\nprint(x)\n") == nil)
  -- a field is not the bare name it shares its last segment with
  assert(hint("local function fail(m: string): never\n  error(m)\nend\n" ..
      "local o = { fail = function(m: string) end }\nlocal x = o.fail('a')\nprint(x)\n") == nil)
  local dotted = hint("local o = {}\nfunction o.fail(m: string): never\n  error(m)\nend\n" ..
      "local x = o.fail('a')\nprint(x)\n")
  assert(dotted ~= nil and dotted:find("`o.fail` never returns", 1, true) ~= nil, tostring(dotted))
  -- a local that hides the standard error
  assert(hint("local function error(m: string)\nend\nlocal x = error('a')\nprint(x)\n") == nil)
  -- a never-function that no declaration of the file names, held by a local
  -- of its function type
  local held = hint("local stop: function(string): never = error\nlocal x = stop('a')\nprint(x)\n")
  assert(held ~= nil and held:find("`stop` never returns", 1, true) ~= nil, tostring(held))
end

--- A record's method refused against an interface method with an unnamed
--- receiver is told to name the receiver `self`.
local function test_an_unnamed_interface_receiver_is_told_to_name_self()
  local function signature(got: string, index: integer): compiler.Error
    local e = not_a(got, "I", index)
    e.signature_of, e.declared_in = "m", "R"
    return e
  end
  local hint = teal.replacement(signature("R", 0), "function R:m(s: string): string end\n")
  assert(hint ~= nil and hint:find("m: function(self: I, ...)", 1, true) ~= nil, tostring(hint))
  assert(hint:find("function R:m", 1, true) ~= nil, hint)
  assert(teal.replacement(signature("S", 0), "") == nil)
  assert(teal.replacement(signature("R", 1), "") == nil)
end

--- A type parameter the expected result fixed is told to bind it in a local.
local function test_a_fixed_type_parameter_is_told_to_bind_in_a_local()
  local refused = not_a("R", "I", 2)
  refused.type_parameter, refused.nested = "T", true
  local hint = teal.replacement(refused, "")
  assert(hint ~= nil and hint:find("local v: R = setmetatable(t, mt)", 1, true) ~= nil,
    tostring(hint))
  local nil_too = mismatch("R", "R | nil", "argument", 2)
  nil_too.type_parameter, nil_too.nested = "T", true
  assert(teal.replacement(nil_too, "") ~= nil)
  assert(teal.replacement(mismatch("R", "S", "argument", 2), "") == nil)
end

--- `coroutine.wrap` gives a function that answers what the coroutine yields
--- or finally returns, so a wrapped function's results are
--- `any...`: a wrapped function returning a string is not typed to return
--- one, and a wrapped never-function is not typed never. The wrapper keeps
--- the parameters of the function passed.
local function test_coroutine_wrap_answers_any_and_not_what_the_function_returns()
  local yields = "local g = coroutine.wrap(function(): string coroutine.yield(1) return 'x' end)\n"
  assert_refused(yields .. "local s: string = g()\nprint(s)\n", "got <any type>")
  assert_accepted(yields .. "local s = g() as string\nprint(s)\n")
  local wrapped = "local function nv(): never\n  coroutine.yield(1)\n  error('x')\nend\n"
  assert_refused(wrapped .. "local c: function(): never = coroutine.wrap(nv)\nprint(c)\n", "function")
  assert_refused(wrapped .. "local w: function(function(): never): function(): never = coroutine.wrap\nprint(w)\n",
    "function")
end

local function test_a_wrapped_function_refuses_wrong_arguments()
  local head = "local g = coroutine.wrap(function(a: string, b?: integer) coroutine.yield(a) end)\n"
  assert_refused(head .. "g(1)\n", "argument 1")
  assert_refused(head .. "g('a', 'b')\n", "argument 2")
  assert_refused(head .. "g()\n", "wrong number of arguments")
  assert_refused(head .. "g('a', 1, 2)\n", "wrong number of arguments")
end

--- The handler of `coroutine.wrap` meets no argument, a
--- `nil`, an `any`, a union, an overloaded function and a vararg of unknown
--- arity without raising: each is refused, or accepted as the call check
--- of the declaration decides.
local function test_wrap_meets_degenerate_arguments()
  assert_refused("local g = coroutine.wrap()\nprint(g)\n", "wrong number of arguments")
  assert_refused("local g = coroutine.wrap(nil)\nprint(g)\n", "argument 1: got nil, expected Function")
  assert_refused("local function f(x: any) local g = coroutine.wrap(x)\nprint(g()) end\nf(1)\n",
    "argument 1: got <any type>, expected Function")
  assert_refused("local type A = function(): string\nlocal type B = function(a: integer)\n" ..
      "local function f(x: A | B)\n" ..
      "local g = coroutine.wrap(x)\nprint(g) end\nf(print)\n",
    "cannot discriminate a union")
  assert_accepted("local g = coroutine.wrap(string.format)\nprint(g('%d', 1))\n")
  assert_refused("local function f(...: any) local g = coroutine.wrap(...)\nprint(g) end\nf(print)\n",
    "argument 1: got <any type>, expected Function")
end

--- A generic function wrapped stays generic in its parameters, so the
--- arity of a call of the wrapper is still checked.
local function test_a_wrapped_generic_function_keeps_its_arity()
  local head = "local c = coroutine.wrap(function<T>(x: T): T coroutine.yield(x) return x end)\n"
  assert_accepted(head .. "c(1)\nc('a')\n")
  assert_refused(head .. "c(1, 2)\n", "wrong number of arguments")
  assert_refused(head .. "c()\n", "wrong number of arguments")
end

local function test_an_ordinary_wrap_call_type_checks()
  assert_accepted("local g = coroutine.wrap(function(a: string, b?: integer) coroutine.yield(a) end)\n" ..
      "g('a')\ng('a', 1)\nlocal v = g('a')\nprint(v)\n")
  assert_accepted("local h = coroutine.wrap(function() end)\nh()\nlocal ok = pcall(h)\nprint(ok)\n")
  assert_accepted("for v in coroutine.wrap(function() coroutine.yield(1) end) do print(v) end\n")
  assert_accepted("local co = coroutine.wrap(coroutine.yield)\nprint(co)\n")
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
    local found = refusals(head .. body)
    -- A container's own comparison drops the reason and reports the two
    -- types (`got {function(): never}, expected {T}`), so they name never.
    assert(found[1] ~= nil and found[1]:find("function(): never", 1, true) ~= nil,
      body .. "refused as: " .. (found[1] or "accepted"))
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
  local hint = teal.replacement(at(unknown_type("never"), 1, 21), "local f: function(): never | nil\n")
  assert(hint ~= nil and hint:find("local type Fail = function(): never", 1, true) ~= nil, tostring(hint))
  assert_accepted("local type Fail = function(): never\nlocal f: Fail | nil\nprint(f)\n")
end

--- A poly value stands for a function type when some overload is a subtype
--- of it: `string -> nothing` overloads do not stand for a
--- function that returns a string, which the row used to accept by asking
--- for the reverse.
local function test_a_poly_function_stands_for_what_an_overload_stands_for()
  local poly = "local record P\n  f: function(string)\n  f: function(integer)\nend\nlocal function probe(p: P)\n"
  assert_accepted(poly .. "local g: function(string) = p.f\nprint(g)\nend\nprint(probe)\n")
  assert_refused(poly .. "local g: function(string): string = p.f\nprint(g)\nend\nprint(probe)\n",
    "cannot match against any alternatives of the polymorphic type")
end

--- The messages the checker reports for `source`, each with its hint
--- appended as the importer prints it, in the order they are reported.
local function checker_says(source: string): {string}
  local built = assert(teal.load(true))
  local _, result = generate(built, source)
  local out: {string} = {}
  for _, group in ipairs({ assert(result).syntax_errors, result.type_errors }) do
    for _, e in ipairs(group) do
      local instead = teal.replacement(e, source)
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
  local hint = teal.replacement(at(about("not_closable", "S", "s"), 4, 7), source)
  assert(hint ~= nil and hint:find("^`<close>` calls a `__close` the value's metatable holds"), tostring(hint))
  assert(hint:find("metamethod __close: function(S)", 1, true) ~= nil, hint)
  assert(hint:find("metatable<S> = { __close = function(self: S)", 1, true) ~= nil, hint)
  assert(hint:find("cosmic docs Fs.Scratch.__close", 1, true) ~= nil, hint)
  assert(hint:find("is a record of yours", 1, true) == nil, hint)
  local qualified = teal.replacement(at(about("not_closable", "Fs.Scratch", "s"), 4, 7), source)
  assert(qualified ~= nil and qualified:find("^if Fs.Scratch is a record of yours, "), tostring(qualified))
  local enum = about("not_closable", "E", "e")
  assert(teal.replacement(enum, 'local enum E "a" end\n') == nil)
  assert(teal.replacement(enum, 'local type E = integer\n') == nil)
  for _, plain in ipairs({ "integer", "string", "{string}", "function(): integer", "boolean" }) do
    assert(teal.replacement(at(about("not_closable", plain, "n"), 4, 7), source) == nil,
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

local meta_record = "local record R\n  name?: string\n  metamethod __call: function(R, string): string\nend\n" ..
  "local record Other\n  x: number\nend\n"

--- A table given as `__index` is checked against the record's fields: one
--- that serves a number for a string field is refused where it is written in
--- the call, and in a variable typed `metatable<R>`, which is how a variable
--- reaches setmetatable; a record of another type is no base for it.
local function test_a_forged_index_is_refused()
  assert_refused(meta_record .. "local r: R = setmetatable({}, { __index = { name = 1 } })\nprint(r)\n",
    "name: got integer, expected string")
  assert_refused(meta_record .. "local mt: metatable<R> = { __index = { name = 1 } }\n" ..
      "local r: R = setmetatable({}, mt)\nprint(r)\n", "name: got integer, expected string")
  assert_refused(meta_record .. "local r: R = setmetatable({}, { __index = Other })\nprint(r)\n",
    "__index: got Other")
end

--- A metatable variable that is no `metatable<T>` is refused (47d), whatever
--- it holds: its `__index` forge and its wrong `__call` both passed
--- because T was a variable when the record was compared.
local function test_an_untyped_metatable_variable_is_refused()
  assert_refused(meta_record .. "local mt = { __index = { name = 1 } }\n" ..
      "local r: R = setmetatable({}, mt)\nprint(r)\n", "must be typed metatable<")
  assert_refused(meta_record ..
      "local mt = { __call = function(_r: R, n: integer): integer return n end }\n" ..
      "local r: R = setmetatable({}, mt)\nprint(r)\n", "must be typed metatable<")
end

--- A wrong `__call` in a variable typed `metatable<R>` is held to the
--- record's declared one.
local function test_a_wrong_call_through_a_typed_variable_is_refused()
  assert_refused(meta_record ..
      "local mt: metatable<R> = { __call = function(_r: R, n: integer): integer return n end }\n" ..
      "local r: R = setmetatable({}, mt)\nprint(r)\n", "__call")
end

--- The class pattern, a function `__index`, a matching table and a weak
--- table still compile. `__index` as a `{string:any}` proxy or as another
--- record used as a base does not: write the proxy as a function
--- `function(t: R, k: any): any`, and copy a base's fields into the record.
local function test_the_sound_metatables_still_compile()
  assert_accepted(meta_record .. "local mt: metatable<R> = { __index = R }\n" ..
      "local r: R = setmetatable({}, mt)\nprint(r)\n" ..
      "local f: metatable<R> = { __index = function(_r: R, _k: any): any return nil end }\n" ..
      "local g: R = setmetatable({}, f)\nprint(g)\n" ..
      "local lit: R = setmetatable({}, { __index = { name = 'x' } })\nprint(lit)\n" ..
      "local weak: {string:R} = setmetatable({}, { __mode = 'v' })\nprint(weak)\n" ..
      "local call: metatable<R> = { __call = function(_r: R, s: string): string return s end }\n" ..
      "local c: R = setmetatable({}, call)\nprint(c)\n")
  assert_refused(meta_record .. "local proxy: {string:any} = {}\n" ..
      "local mt: metatable<R> = { __index = proxy }\nprint(mt)\n", "__index")
end

--- A never `__call` is held to a metatable's function that can return, in
--- a variable typed `metatable<C>` and in one that is not (47d).
local function test_a_never_call_is_not_given_a_function_that_returns()
  local never_rec = "local record C\n  metamethod __call: function(self: C): never\nend\n"
  assert_refused(never_rec .. "local mt = { __call = function(_s: any) end }\n" ..
      "local c: C = setmetatable({}, mt)\nprint(c)\n", "must be typed metatable<")
  assert_refused(never_rec .. "local mt: metatable<C> = { __call = function(_s: any) end }\n" ..
      "local c: C = setmetatable({}, mt)\nprint(c)\n", "missing never")
end

--- The `__index` of a generic record is built from the record as written,
--- type arguments included: `v = 1` for `G<string>` is refused in a
--- typed variable, in the call, and under a type variable.
--- A generic record's metamethods are not held to a metatable yet (the TODO
--- is in the checker, where `meta_fields` is read), which the last case pins.
local function test_a_generic_records_index_is_checked_with_its_arguments()
  local g = "local record G<T>\n  v?: T\nend\n"
  assert_refused(g .. "local mt: metatable<G<string>> = { __index = { v = 1 } }\nprint(mt)\n",
    "v: got integer, expected string")
  assert_refused(g .. "local g: G<string> = setmetatable({}, { __index = { v = 1 } })\nprint(g)\n",
    "v: got integer, expected string")
  assert_refused(g .. "local function mk<T>(): G<T>\n  return setmetatable({}, { __index = { v = 1 } })\nend\nprint(mk)\n",
    "v: got")
  assert_accepted(g .. "local mt: metatable<G<string>> = { __index = { v = 'x' } }\nprint(mt)\n")
  assert_accepted("local record M<T>\n  metamethod __call: function(M<T>, string): string\nend\n" ..
      "local mt: metatable<M<string>> = { __call = function(_m: M<string>, n: integer): integer return n end }\n" ..
      "print(mt)\n")
end

--- What a function `__index` serves is declared `any` and not checked;
--- recorded so closing it moves this case to a refusal.
local function test_a_function_index_serves_any()
  assert_accepted(meta_record .. "local mt: metatable<R> = { __index = function(_r: R, _k: any): any return 1 end }\n" ..
      "local r: R = setmetatable({}, mt)\nprint(r.name)\n")
end

--- The classic class idiom with an untyped table is refused (47d), as is a
--- base record as `__index` (47a). Write `local Class: metatable<R> = {}`
--- with `Class.__index = R`, and copy the base's fields into the record.
local function test_the_untyped_class_idiom_and_a_base_index_are_refused()
  assert_refused(meta_record .. "local Class = {}\nClass.__index = Class\n" ..
      "function Class.new(x: integer): integer\n  return x\nend\n" ..
      "local r: R = setmetatable({}, Class)\nprint(r)\n", "must be typed metatable<R>")
  assert_refused("local interface Base\n  name: string\nend\nlocal record Dog\n  is Base\n  bark: string\nend\n" ..
      "local mt: metatable<Dog> = { __index = Base }\nprint(mt)\n", "__index")
end

--- `rawset` takes a map and writes the key's value type: a record's declared
--- field cannot be written through it with a value of another type, whether
--- the record's fields share a type (it reads as a map of it) or not.
local function test_rawset_refuses_a_record()
  local head = "local record R\n  name: string\n  n: integer\nend\nlocal r: R = { name = 'a', n = 1 }\n"
  assert_refused(head .. "rawset(r, 'name', 1)\n", "argument 1")
  local same = "local record S\n  name: string\nend\nlocal s: S = { name = 'a' }\n"
  assert_refused(same .. "rawset(s, 'name', 1)\n", "argument 3")
end

--- A map takes `rawset` of its own key and value types and refuses any
--- other value.
local function test_rawset_checks_a_maps_value_type()
  local head = "local m: {string:integer} = {}\n"
  assert_refused(head .. "rawset(m, 'k', 'text')\n", "argument 3")
  assert_accepted(head .. "rawset(m, 'k', 2)\nlocal n: {string:integer} = rawset(m, 'j', 3)\nprint(n)\n")
end

--- A record is refused where the same record cast to `{any:any}` or to a
--- map of `any` still takes `rawset`, as does an `{any:any}` table: the
--- cast is where a write that the declaration does not describe is said.
local function test_rawset_takes_a_cast_table()
  local head = "local record R\n  name: string\n  n: integer\nend\nlocal r: R = { name = 'a', n = 1 }\n"
  assert_refused(head .. "rawset(r, 'n', 'x')\n", "argument 1")
  assert_accepted(head .. "rawset(r as {any:any}, 'name', 1)\nrawset(r as {string:any}, 'extra', true)\n")
  assert_accepted("local t: {any:any} = {}\nrawset(t, 1, 'x')\nrawset(t, 'k', 2)\n")
end

--- `name?: T` declares a field that a table literal may omit and whose
--- type admits nil, as `name: T | nil` does: a
--- read is `T | nil`, a guard narrows its copy in a local, and nil may be
--- assigned to it.
--- Its record is open, so the literal omitting a plain field compiles
--- too; what tells the two apart is the type a read has.
local function test_an_optional_field_admits_nil()
  local declared = "local record R\n  name?: string\nend\nlocal r: R = {}\n"
  assert_accepted(declared .. "r.name = nil\nr.name = 'x'\nprint(r)\n")
  assert_refused(declared .. "print(r.name:upper())\n", "cannot index key 'upper' in type string | nil")
  assert_refused(declared .. "r.name = 1\n", "in assignment: got integer")
  assert_refused(declared .. "if r.name then\n  print(r.name:upper())\nend\n", "cannot index key 'upper' in type string | nil")
  assert_accepted(declared .. "local name = r.name\nif name then\n  print(name:upper())\nend\n")
  assert_accepted(declared .. "local n: string = r.name or 'none'\nprint(n)\n")
  assert_accepted("local record P\n  name: string\nend\nlocal p: P = { name = 'a' }\nprint(p.name:upper())\n")
end

--- The optional field written with its nil spelled out is the same
--- field: its generated Lua is the plain one, and a union that already
--- holds nil gains no second member.
local function test_an_optional_field_is_the_union_with_nil()
  local built = assert(teal.load(true))
  local function lua(field: string): string
    return (assert(built.gen("local record R\n  " .. field .. "\nend\nlocal r: R = {}\nprint(r)\n",
      nil, nil, "tl")))
  end
  assert(lua("name?: string") == lua("name: string | nil"))
  local function read_as(field: string): string
    return refusals("local record R\n  " .. field .. "\nend\nlocal r: R = {}\nprint(r.name.x)\n")[1] or ""
  end
  assert(read_as("name?: string | number"):find("in type string | number | nil", 1, true) ~= nil)
  assert(read_as("name?: string | number | nil"):find("in type string | number | nil", 1, true) ~= nil)
  assert(read_as("name?: string | nil"):find("in type string | nil", 1, true) ~= nil)
end

--- An interface field may be optional, and a record that implements
--- the interface inherits the field, optional.
local function test_an_optional_interface_field()
  local source = "local interface Named\n  name?: string\nend\n" ..
    "local record Dog\n  is Named\n  age: integer\nend\n" ..
    "local d: Dog = { age = 3 }\nlocal n: Named = d\n"
  assert_accepted(source .. "local name = d.name\nif name then\n  print(name:upper())\nend\nprint(n)\n")
  assert_refused(source .. "print(d.name:upper(), n)\n", "cannot index key 'upper' in type string | nil")
  assert_accepted("local interface Named\n  name?: string\nend\nlocal n: Named = {}\nprint(n)\n")
end

--- A field of a nested or generic record may be optional, as may one
--- of a record type, whose own fields are read after a guard.
local function test_an_optional_field_in_nested_and_generic_records()
  local nested = "local record Outer\n  record Inner\n    depth?: integer\n  end\n" ..
    "  inner?: Inner\nend\nlocal o: Outer = {}\n"
  assert_accepted(nested .. "o.inner = {}\nlocal i = o.inner\nif i then\n  local d: integer = i.depth or 0\n  print(d)\nend\n")
  assert_refused(nested .. "local d = o.inner.depth\nprint(d)\n", "cannot index")
  local generic = "local record Box<T>\n  value?: T\nend\nlocal b: Box<string> = {}\n"
  assert_accepted(generic .. "b.value = 's'\nlocal value = b.value\nif value then\n  print(value:upper())\nend\n")
  assert_refused(generic .. "print(b.value:upper())\n", "cannot index key 'upper' in type string | nil")
  assert_refused(generic .. "b.value = 1\n", "in assignment: got integer")
end

--- A key written as a string may be optional too, and so may a function
--- field, which is called after a guard as any function that may be nil.
local function test_an_optional_field_with_a_string_key_or_a_function_type()
  assert_accepted("local record R\n  [\"a b\"]?: integer\nend\nlocal r: R = {}\nprint(r[\"a b\"])\n")
  local callback = "local record R\n  done?: function(code: integer)\nend\nlocal r: R = {}\n"
  assert_accepted(callback .. "local done = r.done\nif done then\n  done(1)\nend\n")
  assert_refused(callback .. "if r.done then\n  r.done(1)\nend\n", "not a function: function(integer) | nil")
  assert_refused(callback .. "r.done(1)\n", "not a function: function(integer) | nil")
end

--- `<total>` asks for every field, the optional ones too: `name?: T` is
--- `name: T | nil` and a total literal states a nil-admitting field,
--- `name = nil` where it has no value.
local function test_a_total_literal_states_its_optional_fields()
  local declared = "local record R\n  id: integer\n  name?: string\nend\n"
  assert_refused(declared .. "local r <total>: R = { id = 1 }\nprint(r)\n", "missing: name")
  assert_accepted(declared .. "local r <total>: R = { id = 1, name = nil }\nprint(r)\n")
  assert_accepted(declared .. "local r <total>: R = { id = 1, name = 'x' }\nprint(r)\n")
end

--- A table literal gives every field of its record that does not admit
--- nil, and the refusal names the record and the fields
--- left out, in declaration order.
local function test_a_literal_omitting_a_required_field_is_refused()
  local declared = "local record Person\n  name: string\n  age: integer\n  nick?: string\nend\n"
  assert_refused(declared .. "local p: Person = {}\nprint(p)\n",
    "table literal omits field(s) of record Person that do not admit nil: name, age")
  assert_refused(declared .. "local p: Person = { age = 3 }\nprint(p)\n",
    "of record Person that do not admit nil: name (")
  assert_accepted(declared .. "local p: Person = { name = 'a', age = 3 }\nprint(p)\n")
  assert_refused(declared .. "local function f(p: Person) print(p) end\nf({ name = 'a' })\n",
    "of record Person that do not admit nil: age")
end

--- A field marked `name?:` or typed `T | nil` may be omitted, and a
--- function field may be too: a callback is optional and a method is
--- served by `__index`.
local function test_a_literal_may_omit_what_admits_nil_or_is_a_function()
  assert_accepted("local record R\n  id: integer\n  name?: string\nend\nlocal r: R = { id = 1 }\nprint(r)\n")
  assert_accepted("local record R\n  name: string | nil\nend\nlocal r: R = {}\nprint(r)\n")
  assert_accepted("local record R\n  done: function(code: integer)\n  id: integer\nend\n" ..
      "local r: R = { id = 1 }\nprint(r)\n")
  assert_accepted("local record R\n  pick: function<T>(T): T\n  id: integer\nend\n" ..
      "local r: R = { id = 1 }\nprint(r)\n")
  assert_accepted("local record R\n  id: integer\n  record Inner\n    x: integer\n  end\n" ..
      "  size: function(self: R): integer\nend\nlocal r: R = { id = 1 }\nprint(r)\n")
  assert_refused("local record R\n  id: integer\n  done: function(code: integer)\nend\n" ..
      "local r: R = { done = nil }\nprint(r)\n", "omits field(s) of record R that do not admit nil: id")
end

--- A literal passed for a type variable is held to the record the call
--- binds it to: `table.insert`'s value, a generic
--- function's, and a literal nested in one.
local function test_a_literal_argument_of_a_type_variable_is_checked()
  local declared = "local record R\n  name: string\n  tag?: string\nend\nlocal list: {R} = {}\n"
  assert_refused(declared .. "table.insert(list, {})\n", "of record R that do not admit nil: name")
  assert_refused(declared .. "table.insert(list, 1, {})\n", "of record R that do not admit nil: name")
  assert_refused(declared .. "local function push<T>(l: {T}, v: T) table.insert(l, v) end\npush(list, {})\n",
    "of record R that do not admit nil: name")
  assert_accepted(declared .. "table.insert(list, { name = 'a' })\ntable.insert(list, 1, { name = 'b' })\n")
  assert_accepted(declared .. "local function push<T>(l: {T}, v: T) table.insert(l, v) end\npush(list, { name = 'a' })\n")
  local outer = "local record Inner\n  x: integer\nend\nlocal record Outer\n  inner: Inner\nend\n" ..
    "local list: {Outer} = {}\n"
  assert_refused(outer .. "table.insert(list, { inner = {} })\n", "of record Inner that do not admit nil: x")
  assert_accepted(outer .. "table.insert(list, { inner = { x = 1 } })\n")
end

--- A literal nested in an array, map or tuple literal passed for a
--- parameter that holds a type variable is held to the record the call
--- binds it to too, to any depth.
local function test_a_literal_nested_in_an_argument_literal_is_checked()
  local declared = "local record R\n  name: string\n  tag?: string\nend\nlocal list: {R} = {}\n" ..
    "local function push_all<T>(l: {T}, vs: {T}) for _, v in ipairs(vs) do table.insert(l, v) end end\n"
  assert_refused(declared .. "push_all(list, { {} })\n", "of record R that do not admit nil: name")
  assert_refused(declared .. "push_all(list, { { name = 'a' }, {} })\n", "of record R that do not admit nil: name")
  assert_accepted(declared .. "push_all(list, { { name = 'a' }, { name = 'b', tag = 'c' } })\npush_all(list, {})\n")
  assert_refused(declared .. "local function by_key<T>(l: {T}, vs: {string:T}) print(l, vs) end\n" ..
      "by_key(list, { a = {} })\n", "of record R that do not admit nil: name")
  assert_accepted(declared .. "local function by_key<T>(l: {T}, vs: {string:T}) print(l, vs) end\n" ..
      "by_key(list, { a = { name = 'a' } })\n")
  assert_refused(declared .. "local function nested<T>(l: {T}, vs: {{T}}) print(l, vs) end\n" ..
      "nested(list, { { {} } })\n", "of record R that do not admit nil: name")
  assert_accepted(declared .. "local function nested<T>(l: {T}, vs: {{T}}) print(l, vs) end\n" ..
      "nested(list, { { { name = 'a' } } })\n")
  assert_refused(declared .. "local function pair<T>(l: {T}, vs: {T, integer}) print(l, vs) end\n" ..
      "pair(list, { {}, 1 })\n", "of record R that do not admit nil: name")
  -- The one member of a union parameter that holds a table or a type
  -- variable is the one the literal is held to.
  assert_refused(declared .. "local function pu<T>(l: {T}, vs: {T} | nil) print(l, vs) end\npu(list, { {} })\n",
    "of record R that do not admit nil: name")
  assert_refused(declared .. "local function pt<T>(l: {T}, v: T | string) print(l, v) end\npt(list, {})\n",
    "of record R that do not admit nil: name")
  assert_accepted(declared .. "local function pu<T>(l: {T}, vs: {T} | nil) print(l, vs) end\n" ..
      "pu(list, { { name = 'a' } })\n")
  -- A method call counts its receiver out of the arguments.
  assert_refused(declared .. "local record Bag\n  add: function<T>(self: Bag, l: {T}, vs: {T})\nend\n" ..
      "local b: Bag = {}\nb:add(list, { {} })\n", "of record R that do not admit nil: name")
  assert_accepted(declared .. "local record Bag\n  add: function<T>(self: Bag, l: {T}, vs: {T})\nend\n" ..
      "local b: Bag = {}\nb:add(list, { { name = 'a' } })\n")
  -- An alias of the array type, written with the record or with the
  -- variable, is refused too (by the literal's own check or the call's).
  assert_refused(declared .. "local type Alias<T> = {T}\n" ..
      "local function pa<T>(l: {T}, vs: Alias<T>) print(l, vs) end\npa(list, { {} })\n", "got {}, expected R")
  assert_refused(declared .. "local type Alias<T> = {T}\n" ..
      "local function pa(l: {R}, vs: Alias<R>) print(l, vs) end\npa(list, { {} })\n",
    "of record R that do not admit nil: name")
  -- The elements of the literal are the only record that binds the
  -- variable: no one declared it, so none is held to it.
  assert_accepted("for _, c in ipairs({ { ok = true }, { ok = false, why = 'x' } }) do print(c) end\n")
end

--- Only the `__index` type of a metatable (47a) takes a part of its
--- record: a union with another function is held to all of it.
local function test_a_union_with_a_function_is_held_to_its_record()
  local declared = "local record R\n  name: string\nend\n"
  assert_refused(declared .. "local t: R | function() = {}\nprint(t)\n", "do not admit nil: name")
  assert_refused(declared .. "local record H\n  make: R | function(): R\nend\n" ..
      "local h: H = { make = {} }\nprint(h)\n", "do not admit nil: name")
  assert_accepted(declared .. "local mt: metatable<R> = { __index = {} }\nprint(mt)\n")
end

--- A literal that stands where a function would also do is a table served
--- for the keys it holds (the `__index` of a metatable, 47a), so it may
--- give a part of its record; a literal given only where the record is
--- wanted may not.
local function test_an_index_literal_may_give_part_of_its_record()
  local declared = "local record R\n  name: string\n  n: integer\n  size: function(self: R): integer\nend\n"
  assert_accepted(declared .. "local mt: metatable<R> = { __index = {} }\nprint(mt)\n")
  assert_accepted(declared .. "local mt: metatable<R> = { __index = { name = 'x' } }\nprint(mt)\n")
  assert_accepted(declared ..
      "local mt: metatable<R> = { __index = { size = function(self: R): integer return 1 end } }\nprint(mt)\n")
  assert_refused(declared .. "local mt: metatable<R> = { __index = { name = 1 } }\nprint(mt)\n", "name")
  assert_refused(declared .. "local x: R = {}\nprint(x)\n", "do not admit nil: name, n")
  assert_refused(declared .. "local x: R = { name = 'a' }\nprint(x)\n", "do not admit nil: n (")
end

--- A literal nested in another is checked against its own field's record,
--- and an interface is checked as a record is.
local function test_a_nested_literal_and_an_interface_are_checked()
  local declared = "local record Inner\n  x: integer\n  y?: integer\nend\n" ..
    "local record Outer\n  inner: Inner\n  tag?: string\nend\n"
  assert_accepted(declared .. "local o: Outer = { inner = { x = 1 } }\nprint(o)\n")
  assert_refused(declared .. "local o: Outer = { inner = {} }\nprint(o)\n",
    "of record Inner that do not admit nil: x")
  assert_refused(declared .. "local o: Outer = {}\nprint(o)\n", "of record Outer that do not admit nil: inner")
  assert_refused("local interface Named\n  name: string\nend\nlocal n: Named = {}\nprint(n)\n",
    "of interface Named that do not admit nil: name")
  assert_accepted("local interface Named\n  name: string\nend\nlocal n: Named = { name = 'a' }\nprint(n)\n")
  assert_accepted("local record Box<T>\n  value: T\n  note?: string\nend\n" ..
      "local b: Box<string> = { value = 'a' }\nprint(b)\n")
  assert_refused("local record Box<T>\n  value: T\nend\nlocal b: Box<string> = {}\nprint(b)\n",
    "of record Box that do not admit nil: value")
end

--- What `?` cannot mark: a metamethod, a generic function type, and a
--- name with no `:` after it.
local function test_what_an_optional_field_refuses()
  assert_refused("local record R\n  metamethod __index?: function(R, string): any\nend\n",
    "a metamethod cannot be optional")
  assert_refused("local record R\n  pick?: function<T>(T): T\nend\n",
    "an optional field cannot have a generic type")
  assert_refused("local record R\n  name? string\nend\n", "expected ':'")
  assert_accepted("local function f(a?: string) print(a) end\nprint(f)\n")
end

--- A field named by a word that starts a declaration (`type`, `record`,
--- `enum`, `interface`, `userdata`, `metamethod`) may be optional, as it
--- may be plain.
local function test_an_optional_field_may_be_named_for_a_declaration_word()
  for _, word in ipairs({ "type", "record", "enum", "interface", "userdata", "metamethod" }) do
    assert_accepted("local record R\n  " .. word .. "?: integer\n  other?: string\nend\n" ..
        "local r: R = {}\nlocal v = r." .. word .. "\nif v then\n  print(v + 1)\nend\n")
    assert_refused("local record R\n  " .. word .. "?: integer\nend\nlocal r: R = {}\n" ..
        "print(r." .. word .. ".x)\n", "in type integer | nil")
    assert_accepted("local interface I\n  " .. word .. "?: string\nend\nlocal i: I = {}\nprint(i)\n")
  end
  assert_accepted("local record R\n  userdata\n  type?: string\n  record Inner\n    x?: integer\n  end\nend\nprint(R)\n")
end

--- A value that may be nil, whatever holds it, is no operand of `..`, `#`,
--- arithmetic, a bit operator or an ordered comparison: the operator raises
--- at run time when it is nil.
local function test_an_operand_that_may_be_nil_is_refused()
  local head = "local record R\n  name?: string\n  n?: integer\n  items?: {string}\nend\n" ..
    "local r: R = {}\nlocal function find(): string | nil return nil end\n" ..
    "local function count(): integer | nil return nil end\nlocal s = find()\nlocal n = count()\n"
  for _, use in ipairs({
      "s .. 'x'", "'x' .. s", "r.name .. 'x'", "'x' .. r.name", "#s", "#r.items", "-r.n", "~r.n",
      "r.n + 1", "1 + r.n", "n * 2", "r.n // 2", "r.n % 2", "r.n ^ 2", "r.n & 1", "r.n << 1",
      "r.n < 3", "3 <= r.n", "r.n > 3", "3 >= r.n", "r.name < 'a'", "s .. s",
  }) do
    assert_refused(head .. "print(" .. use .. ")\n", "cannot use operator")
  end
  assert_refused(head .. "print(#s)\n", "cannot use operator '#' on type string | nil")
  assert_refused(head .. "print(s .. 'x')\n", "for types string | nil and string")
end

--- What narrows a nil-admitting operand stays accepted: a guard, an
--- `assert`, a default, a comparison with nil, and a value that is not a
--- union with nil (`any` among them).
local function test_a_narrowed_operand_is_accepted()
  local head = "local record R\n  name?: string\n  n?: integer\n  items?: {string}\nend\n" ..
    "local r: R = {}\nlocal function find(): string | nil return nil end\n" ..
    "local s = find()\nlocal a: any = 1\n"
  assert_accepted(head .. "if s then\n  print(s .. 'x', #s)\nend\n")
  assert_accepted(head .. "if s ~= nil then\n  print('x' .. s)\nend\n")
  assert_accepted(head .. "if s == nil then return end\nprint(s .. 'x', #s)\n")
  assert_accepted(head .. "assert(s)\nprint(s .. 'x')\n")
  assert_accepted(head .. "local t = assert(find())\nprint(t .. 'x')\n")
  assert_accepted(head .. "print((s or '') .. 'x', #(r.items or {}), (r.n or 0) + 1)\n")
  assert_accepted(head .. "local field = r.n\nif field then\n  print(field + 1, field < 3)\nend\n")
  assert_accepted(head .. "local field = r.n\nif field ~= nil and field > 1 then\n  print(field - 1)\nend\n")
  assert_accepted(head .. "local list = r.items\nif list then\n  print(#list)\nend\n")
  assert_refused(head .. "if r.n then\n  print(r.n + 1)\nend\n", "cannot use operator")
  assert_accepted(head .. "print(s == nil, s ~= 'a', not s, s and #s, s or 'none')\n")
  assert_accepted(head .. "print(a .. 'x', a + 1, a < 2, -a)\n")
  assert_accepted(head .. "local plain: string = 'p'\nprint(plain .. 'x', #plain)\n")
end

--- `a and b` yields a when a is falsy, so a nil a makes the result nil: the
--- result is refused as an operand where a is a nil-admitting union, and
--- keeps its type under a guard, an `or`, or a left operand without nil.
local function test_a_conjunction_with_a_nil_left_operand_may_be_nil()
  local head = "local function find(): string | nil return nil end\n" ..
    "local x = find()\nlocal y = find()\nlocal z: string = 'z'\nlocal plain: string = 'p'\n"
  assert_accepted(head .. "print(x and x .. 'a')\nprint(x and #x)\n")
  assert_accepted(head .. "if x then\n  print((x and x) .. 'a')\nend\n")
  assert_accepted(head .. "print((plain and z) .. 'a')\n")
  assert_refused(head .. "print((x and x) .. 'a')\n", "cannot use operator '..' for types string (inferred at")
  assert_refused(head .. "print((x and y) .. 'a')\n", "cannot use operator '..'")
  assert_refused(head .. "print('a' .. (x and z))\n", "cannot use operator '..'")
  assert_refused(head .. "print(#(x and z))\n", "cannot use operator '#'")
  assert_refused(head .. "print((x and x and y) .. 'a')\n", "cannot use operator '..'")
  assert_accepted(head .. "local v: string = x and y or z\nprint(v .. 'a')\n")
  assert_accepted(head .. "print((x and y or z) .. 'a', #(x and y or 'none'))\n")
  assert_accepted(head .. "local w = x and y\nif w then\n  print(w .. 'a')\nend\n")
  assert_accepted(head .. "local flag: boolean = (x and y) == z\nprint(flag)\n")
end

--- An `and` whose right operand is already an error is not given a nil
--- too: one mistake is one error.
local function test_a_conjunction_with_an_invalid_right_operand_reports_once()
  local found = refusals("local record T\n  f?: string\nend\nlocal function takes(s: string) print(s) end\n" ..
      "local t: T = {}\ntakes(t.f and t.f:nosuch())\n")
  assert(#found == 1, table.concat(found, "; "))
  assert(found[1]:find("nosuch", 1, true) ~= nil, found[1])
end

--- `m ~= nil and m.f ~= nil` narrows `m`, a local that is itself a union with
--- nil, and not `m.f`: the field is copied to a local, read through `m` where
--- `m` is not nil.
local function test_a_field_guard_after_its_nil_base_check_narrows_the_base_only()
  local head = "local record Node\n  tk?: string\n  e2?: Node\nend\n" ..
    "local function f(owner: Node): string\n  local m = owner.e2\n"
  assert_refused(head .. "  if m ~= nil and m.tk ~= nil then\n    return '.' .. m.tk\n  end\n  return ''\nend\nprint(f)\n",
    "cannot use operator '..'")
  assert_refused(head .. "  if m and m.tk then\n    return '.' .. m.tk\n  end\n  return ''\nend\nprint(f)\n",
    "cannot use operator '..'")
  assert_accepted(head .. "  local tk = m ~= nil and m.tk or nil\n  if tk ~= nil then\n    return '.' .. tk\n  end\n  return ''\nend\nprint(f)\n")
  assert_refused(head .. "  if m ~= nil then\n    return '.' .. m.tk\n  end\n  return ''\nend\nprint(f)\n",
    "cannot use operator '..'")
  assert_refused(head .. "  if m.tk ~= nil then\n    return ''\n  end\n  return ''\nend\nprint(f)\n",
    "cannot index key 'tk' in variable 'm' of type Node | nil")
end

--- A value that may be nil is no argument of `table.insert` or
--- `table.concat` where the list it joins or extends takes none.
local function test_a_table_argument_that_may_be_nil_is_refused()
  local head = "local record R\n  name?: string\n  items?: {string}\nend\nlocal r: R = {}\n" ..
    "local function find(): string | nil return nil end\nlocal s = find()\n" ..
    "local list: {string} = {}\n"
  for _, use in ipairs({
      "table.insert(list, s)", "table.insert(list, r.name)", "table.insert(list, 1, s)",
      "table.insert(r.items, 'x')", "print(table.concat(r.items, ','))",
  }) do
    assert_refused(head .. use .. "\n", "argument")
  end
  assert_refused(head .. "table.insert(list, s)\n", "argument 2: got string | nil, expected string")
  assert_accepted(head .. "if s then\n  table.insert(list, s)\nend\n")
  assert_accepted(head .. "assert(s)\ntable.insert(list, s)\n")
  assert_accepted(head .. "table.insert(list, s or 'none')\n")
  assert_accepted(head .. "table.insert(assert(r.items), 'x')\nprint(table.concat(r.items or {}, ','))\n")
  assert_accepted(head .. "local list = r.items\nif list then\n  print(table.concat(list, ','))\nend\n")
  assert_accepted(head .. "local maybe: {string | nil} = {}\ntable.insert(maybe, s)\n")
  assert_accepted(head .. "local anything: {any} = {}\ntable.insert(anything, s)\n")
end

local nil_head = "local function find(): string | nil return nil end\nlocal s = find()\n" ..
  "local list: {string} = {}\n"

--- A refusal of a value that may be nil tells the check that drops it.
local function test_a_nil_operand_or_argument_is_told_the_check()
  local head = "local function find(): string | nil return nil end\nlocal s = find()\n" ..
    "local list: {string} = {}\n"
  local left = "the left operand may be nil: check it first (`if value == nil then return nil, err end`), " ..
    "or, where a call answers it, take it with `local value = assert(<the call>)`"
  local right = (left:gsub("left", "right"))
  answers(head .. "print(s .. 'x')\n", "cannot use operator '..' for types string | nil and string \"x\"", left)
  answers(head .. "print('x' .. s)\n", "cannot use operator '..' for types string \"x\" and string | nil", right)
  answers(head .. "print(#s)\n", "cannot use operator '#' on type string | nil",
    "the operand may be nil: check it first (`if value == nil then return nil, err end`), " ..
      "or, where a call answers it, take it with `local value = assert(<the call>)`")
  answers(head .. "table.insert(list, s)\n", "argument 2: got string | nil, expected string",
    "the argument may be nil: check it first (`if value == nil then return nil, err end`); " ..
      "where a call answers it, take it with `local value = assert(<the call>)`; " ..
      "or, where a default fits, write `value = value or <default>`")
  answers(head .. "table.insert(list, nil)\n", "argument 2: got nil, expected string",
    "the parameter takes no nil: pass a value, or, where the callee handles nil, " ..
      "declare the parameter `name?: T` or `T | nil`")
end

--- `require` is checked by its own handler, which refuses a name that is
--- nil or may be; a name it cannot read stays `any`.
local function test_require_takes_a_string_that_is_not_nil()
  local head = nil_head
  assert_refused(head .. "local m = require(s)\nprint(m)\n", "require: argument 1: got string | nil, expected string")
  assert_refused("local m = require(nil)\nprint(m)\n", "require: argument 1: got nil, expected string")
  assert_accepted(head .. "if s then\n  print(require(s))\nend\n")
  assert_accepted("local name = 'x' .. tostring(1)\nlocal m = require(name)\nprint(m)\n")
  answers(head .. "local m = require(s)\nprint(m)\n", "require: argument 1: got string | nil, expected string",
    "the name may be nil: check it first (`if name == nil then return nil, err end`), " ..
      "or, where a call answers it, take it with `local name = assert(<the call>)`")
  answers("local m = require(nil)\nprint(m)\n", "require: argument 1: got nil, expected string",
    "require takes a module name: pass a string")
end

--- A value narrowed to nil is a nil that is passed, wherever it came from.
local function test_a_value_narrowed_to_nil_is_refused_as_an_argument()
  local greet = nil_head .. "local function greet(name: string): string return name end\n"
  assert_refused(greet .. "if s == nil then\n  print(greet(s))\nend\n", "argument 1: got nil")
  assert_refused(greet .. "if not s then\n  print(greet(s))\nend\n", "argument 1: got nil")
  assert_refused(greet .. "local x = s == nil and s\nprint(greet(x))\n", "argument 1: got")
end

--- A value made non-nil by an assignment at a join is refused, as the checker
--- does not narrow there; `x = x or default` is the fix.
local function test_a_value_made_non_nil_at_a_join_is_a_known_limit()
  local greet = nil_head .. "local function greet(name: string): string return name end\n"
  local refused = "argument 1: got string | nil, expected string"
  assert_refused(greet .. "local x = s\nif x == nil then\n  x = 'd'\nend\nprint(greet(x))\n", refused)
  assert_refused(greet .. "local x = s\nif not x then\n  x = 'd'\nend\nprint(greet(x))\n", refused)
  assert_refused(greet .. "local m = s\nwhile m == nil do\n  m = find()\nend\nprint(greet(m))\n", refused)
  assert_refused(greet .. "local m = s\nrepeat\n  m = find()\nuntil m ~= nil\nprint(greet(m))\n", refused)
  assert_accepted(greet .. "local x = s\nx = x or 'd'\nprint(greet(x))\n")
end

--- `setmetatable` takes a nil metatable, which removes one; so does any
--- parameter typed `metatable<T>`, a user function's too.
local function test_setmetatable_takes_a_nil_metatable()
  local head = "local record R\n  n?: integer\nend\nlocal r: R = {}\n"
  assert_accepted(head .. "setmetatable(r, nil)\nprint(r)\n")
  assert_accepted(head .. "local function adopt(_r: R, _mt: metatable<R>) end\n" ..
      "local function maybe(): metatable<R> | nil return nil end\nadopt(r, maybe())\nadopt(r, nil)\n")
end

--- The optional parameters of `table.concat` take nil: the separator and
--- the bounds.
local function test_an_optional_table_parameter_takes_nil()
  local head = "local list: {string} = {}\nlocal function sep(): string | nil return nil end\n" ..
    "local function at(): integer | nil return nil end\n"
  assert_accepted(head .. "print(table.concat(list, sep()))\n")
  assert_accepted(head .. "print(table.concat(list, ',', at(), at()))\n")
  assert_refused(head .. "table.insert(list, sep())\n", "argument")
end

--- A value that may be nil is no argument for a parameter that does not
--- take nil, whatever the callee is: an ordinary function, a method, a
--- function reached through an alias or through a record that is not
--- `table`, and a parameter of the varargs.
local function test_an_argument_that_may_be_nil_is_refused_for_any_parameter()
  local greet = nil_head .. "local function greet(name: string): string return name end\n"
  assert_refused(greet .. "print(greet(s))\n", "argument 1: got string | nil, expected string")
  assert_accepted(greet .. "if s then\n  print(greet(s))\nend\n")
  assert_accepted(greet .. "assert(s)\nprint(greet(s))\n")
  assert_accepted(greet .. "print(greet(s or 'none'))\n")

  -- A parameter after the first is checked, and so is a generic function's
  -- once the arguments before it bind its type variable.
  local later = nil_head .. "local function put(n: integer, name: string) print(n, name) end\n"
  assert_refused(later .. "put(1, s)\n", "argument 2: got string | nil, expected string")
  assert_refused(nil_head .. "local function push<T>(l: {T}, v: T) table.insert(l, v) end\npush(list, s)\n",
    "argument 2: got string | nil, expected string")

  local method = nil_head .. "local record Box\n  put: function(self: Box, name: string)\nend\n" ..
    "local box: Box = { put = function(_self: Box, _name: string) end }\n"
  assert_refused(method .. "box:put(s)\n", "argument 1: got string | nil, expected string")
  assert_refused(method .. "box.put(box, s)\n", "argument 2: got string | nil, expected string")
  assert_accepted(method .. "if s then\n  box:put(s)\nend\n")

  -- The callee's name is no part of the rule: an alias of `table.insert` is
  -- checked, and so is a function that merely has its name.
  assert_refused(nil_head .. "local ins = table.insert\nins(list, s)\n", "argument 2: got string | nil")
  assert_refused(nil_head .. "local bag = { insert = function(_l: {string}, _v: string) end }\n" ..
      "bag.insert(list, s)\n", "argument 2: got string | nil, expected string")
  assert_accepted(nil_head .. "local bag = { insert = function(_l: {string}, _v: string | nil) end }\n" ..
      "bag.insert(list, s)\n")
  -- A local that hides `table` is refused for hiding it and for nothing
  -- else: the callee is no longer matched by the name `table`.
  for _, found in ipairs(refusals(nil_head ..
        "local table = { insert = function(_l: {string}, _v: string | nil) end }\ntable.insert(list, s)\n")) do
    assert(found:find("argument", 1, true) == nil, found)
  end
end

--- Every element of a varargs parameter is checked as the parameter's type,
--- and one that takes nil, or none, is not.
local function test_a_varargs_element_that_may_be_nil_is_refused()
  local all = nil_head .. "local function all(...: string): integer return select('#', ...) end\n"
  assert_refused(all .. "print(all('a', s))\n", "argument 2: got string | nil, expected string")
  assert_refused(all .. "print(all(s))\n", "argument 1: got string | nil, expected string")
  assert_accepted(all .. "print(all())\nprint(all('a', 'b'))\n")
  assert_accepted(all .. "if s then\n  print(all('a', s))\nend\n")
  assert_accepted(nil_head .. "local function some(...: string | nil): integer return select('#', ...) end\n" ..
      "print(some('a', s))\n")
  assert_accepted(nil_head .. "local function kinds(...: any): integer return select('#', ...) end\n" ..
      "print(kinds('a', s))\n")
end

--- A value tested against nil and then against a string is not nil in the
--- branch where both tests fail, and is where only the second does.
local function test_a_value_tested_against_nil_and_a_string_is_not_nil_where_both_fail()
  local greet = nil_head .. "local function greet(name: string): string return name end\n" ..
    "local function run(): boolean\n"
  assert_accepted(greet .. "  if s == nil then\n    return false\n  elseif s == '' then\n    return true\n" ..
      "  else\n    print(greet(s))\n  end\n  return false\nend\nprint(run)\n")
  assert_accepted(greet .. "  if s == nil or s == '' then\n    return false\n  end\n" ..
      "  print(greet(s))\n  return true\nend\nprint(run)\n")
  assert_accepted(greet .. "  if s ~= nil and s ~= '' then\n    print(greet(s))\n  end\n  return true\nend\nprint(run)\n")
  assert_refused(greet .. "  if s == '' then\n    return true\n  end\n  print(greet(s))\n  return false\nend\n" ..
      "print(run)\n", "argument 1: got string | nil, expected string")
end

--- A parameter that is optional, or that admits nil, takes a value that may
--- be nil.
local function test_a_parameter_that_takes_nil_is_given_one()
  assert_accepted(nil_head .. "local function opt(name?: string) print(name) end\nopt(s)\nopt(nil)\nopt()\n")
  assert_accepted(nil_head .. "local function opt(n: integer, name?: string) print(n, name) end\nopt(1, s)\nopt(1, nil)\n")
  assert_accepted(nil_head .. "local function open(name: string | nil) print(name) end\nopen(s)\nopen(nil)\n")
  assert_accepted(nil_head .. "local function open(name: any) print(name) end\nopen(s)\nopen(nil)\n")
  assert_accepted(nil_head .. "local function generic<T>(v: T) print(v) end\ngeneric(s)\ngeneric(nil)\n")
  assert_accepted(nil_head .. "local f: function(string, ? string) = nil\nprint(f)\n")
  -- A function type's optional parameters are the ones that take nil, wherever
  -- the first of them stands, and a required one may not follow it.
  assert_accepted(nil_head .. "local function probe(f: function(a: string, b?: string, c?: string))\n" ..
      "f('a', s, s)\nf('a')\nend\nprint(probe)\n")
  assert_refused(nil_head .. "local f: function(a: string, b?: string, c: string)\nprint(f)\n",
    "non-optional arguments cannot follow optional arguments")
  assert_accepted(nil_head .. "local function probe(f: function(a: string, b?: string, ...: string))\n" ..
      "f('a', s, 'c')\nend\nprint(probe)\n")
end

--- A literal `nil` is no argument for a parameter that does not take nil,
--- as a value that may be nil is not: the call sites of the tree that pass
--- one are positions of a parameter that is optional or that takes nil, and
--- the few that check a refusal give the value through a variable whose
--- type admits it.
local function test_a_literal_nil_is_refused_for_a_parameter_that_does_not_take_it()
  local greet = "local function greet(name: string): string return name end\n"
  assert_refused(greet .. "print(greet(nil))\n", "argument 1: got nil, expected string")
  assert_refused(greet .. "local ok, err = pcall(greet, nil)\nprint(ok, err)\n", "got nil, expected string")
  assert_refused("local list: {string} = {}\ntable.insert(list, nil)\n", "argument 2: got nil, expected string")
  assert_accepted(greet .. "local function absent(): string return nil end\nprint(pcall(greet, absent()))\n")
  assert_accepted("local function opt(name?: string) print(name) end\nopt(nil)\n")
  assert_accepted("local function open(name: string | nil) print(name) end\nopen(nil)\n")
  assert_accepted("local function open(a: string, name: any) print(a, name) end\nopen('a', nil)\n")
  assert_accepted("local function maybe(): string | nil return nil end\nlocal s = maybe()\n" ..
      "local record R\n  name?: string\nend\nlocal r: R = { name = nil }\nprint(s, r)\n")
end

--- A numeric `for` takes no start, limit or step that may be nil.
local function test_a_numeric_for_bound_that_may_be_nil_is_refused()
  local head = "local function count(): number | nil return nil end\nlocal n = count()\n"
  assert_refused(head .. "for i = 1, n do print(i) end\n", "cannot use number | nil as the 'for' limit")
  assert_refused(head .. "for i = n, 3 do print(i) end\n", "as the 'for' start")
  assert_refused(head .. "for i = 1, 3, n do print(i) end\n", "as the 'for' step")
  assert_accepted(head .. "if n then\n  for i = 1, n do print(i) end\nend\n")
  assert_accepted(head .. "for i = 1, n or 0 do print(i) end\n")
  answers(head .. "for i = 1, n do print(i) end\n", "cannot use number | nil as the 'for' limit",
    "the bound may be nil: check it first (`if value == nil then return nil, err end`), " ..
      "or, where a call answers it, take it with `local value = assert(<the call>)`")
end

--- Every diagnostic of kind `code` the parser or the checker reports for
--- `source`, an error or a warning, compiled for Lua 5.4 where `five_four`;
--- the test fails when there is none. Each holds only fields `record Error`
--- declares, so a field misspelt where the checker sets it is caught by
--- the test of its code.
local function diagnostics(source: string, code: compiler.ErrorCode, five_four?: boolean): {compiler.Error}
  local built = assert(teal.load(true))
  local env = five_four and assert(built.new_env({ defaults = teal.defaults() })) or nil
  local ok, _, result = pcall(built.gen, source, env, nil, "tl")
  assert(ok and result ~= nil, source)
  vet(result)
  local declared = error_declarations(assert(Fs.read("build/compiler.d.tl")), "  ")
  local found: {compiler.Error} = {}
  local seen: {string} = {}
  for _, group in ipairs({ result.syntax_errors, result.type_errors, result.warnings }) do
    for _, e in ipairs(group) do
      if e.code == code then
        for key in pairs(e as {string:any}) do
          assert(declared[key], "the checker set `" .. tostring(key) .. "`, which record Error lacks")
        end
        found[#found + 1] = e
      end
      seen[#seen + 1] = tostring(e.code) .. " " .. e.msg
    end
  end
  assert(#found > 0, "no " .. code .. " among: " .. table.concat(seen, "; ") .. "\n" .. source)
  return found
end

--- The first diagnostic of kind `code` (see [`diagnostics`]).
local function diagnostic(source: string, code: compiler.ErrorCode, five_four?: boolean): compiler.Error
  return diagnostics(source, code, five_four)[1]
end

--- The mirror of `record Error` and `enum ErrorCode` in
--- build/compiler.d.tl holds the checker's fields and codes, no more and
--- no fewer: a field the checker sets that the mirror lacks would be
--- unreadable to a hint, and one only the mirror has would never be set.
local function test_the_declared_error_matches_the_checkers()
  local checker_fields, checker_codes = error_declarations(assert(Fs.read("checker/tl.tl")), "   ")
  local mirror_fields, mirror_codes = error_declarations(assert(Fs.read("build/compiler.d.tl")), "  ")
  assert(next(checker_fields) ~= nil and next(checker_codes) ~= nil, "no declarations found")
  local fields_agree, field = same_names(checker_fields, mirror_fields)
  assert(fields_agree, "record Error differs at the field " .. tostring(field))
  local codes_agree, code = same_names(checker_codes, mirror_codes)
  assert(codes_agree, "enum ErrorCode differs at " .. tostring(code))
end

--- Whether `found` holds the strings `want`, in order.
local function listed(found: {string} | nil, ...: string): boolean
  local want = { ... }
  if found == nil or #found ~= #want then
    return false
  end
  for i, member in ipairs(want) do
    if found[i] ~= member then
      return false
    end
  end
  return true
end

--- The hints read what the checker says of a refused value, not its
--- words, so each refusal carries where the value was wanted and the types
--- involved: a hint that parsed the message would go on working while the
--- error lost these, so they are pinned here.
local function test_a_refused_value_carries_its_place_and_types()
  local f = "local function f(n: integer) print(n) end\n"
  local argument = diagnostic(f .. "f(\"x\")\n", "mismatch")
  assert(argument.context == "argument" and argument.index == 1 and not argument.nested,
    tostring(argument.context))
  assert(argument.expected == "integer" and listed(argument.expected_members, "integer"))
  local got_members = argument.got_members
  assert(got_members ~= nil and #got_members == 1, argument.msg)
  local declared = diagnostic("local n: integer = \"x\"\nprint(n)\n", "mismatch")
  assert(declared.context == "in local declaration" and declared.context_name == "n" and
      not declared.nested, tostring(declared.context))
  local assigned = diagnostic("local n = 0\nn = \"x\"\nprint(n)\n", "mismatch")
  assert(assigned.context == "in assignment" and assigned.context_name == nil and
      not assigned.nested and assigned.got == "string \"x\"" and assigned.expected == "integer",
    tostring(assigned.context) .. " " .. tostring(assigned.got))
  local returned = diagnostic("local function g(): integer\n  return \"a\"\nend\nprint(g())\n", "mismatch")
  assert(returned.context == "in return value" and not returned.nested, tostring(returned.context))
  -- Words of the checker's between the place and the mismatch make it nested.
  local nested = diagnostic("local m: {string:integer} = {x = \"a\"}\nprint(m)\n", "mismatch")
  assert(nested.nested and nested.context == "in local declaration", tostring(nested.context))
  local maybe = diagnostic("local function find(): string | nil return nil end\n" .. f ..
      "f(find())\n", "mismatch")
  assert(listed(maybe.got_members, "string", "nil") and maybe.context == "argument", maybe.msg)
  local absent = diagnostic("local function greet(name: string): string return name end\n" ..
      "print(greet(nil))\n", "mismatch")
  assert(absent.got == "nil" and absent.context == "argument" and absent.index == 1, absent.msg)
  local number = diagnostic(f .. "f(tonumber('3'))\n", "mismatch")
  assert(listed(number.got_members, "number") and number.expected == "integer", number.msg)
end

--- A nominal type refused for another carries both, and what a function
--- declared against an interface was refused for.
local function test_a_nominal_refusal_carries_both_names()
  local scoped = "local record Store\n  n: integer\nend\n" ..
    "local function put(s: Store): Store\n  return s\nend\n" ..
    "do\n  local record Store\n    n: integer\n  end\n  local s: Store = {n = 1}\n  print(put(s))\nend\n"
  local twice = diagnostic(scoped, "not_a")
  assert(twice.got == "Store" and twice.expected == "Store" and twice.context == "argument" and
      twice.index == 1, twice.msg)
  local nested = diagnostic("local record Kv\n  record Store\n    n: integer\n  end\nend\n" ..
      "local record Store\n  n: integer\nend\n" ..
      "local function put(s: Kv.Store): Kv.Store\n  return s\nend\n" ..
      "local s: Store = {n = 1}\nprint(put(s))\n", "not_a")
  assert(nested.got == "Store" and nested.expected == "Kv.Store", nested.msg)
  local unnamed = diagnostic("local interface I\n  m: function(I, string): string\nend\n" ..
      "local record R is I\n  n: integer\nend\nfunction R:m(s: string): string return s end\n", "not_a")
  assert(unnamed.signature_of == "m" and unnamed.declared_in == "R" and unnamed.index == 0 and
      unnamed.context == "argument" and unnamed.got == "R" and unnamed.expected == "I", unnamed.msg)
end

--- A key a record lacks carries the key, the variable and the type, the
--- record's value fields, and what the type is; a key read of a value
--- that is no record carries the types its members are.
local function test_a_missing_key_carries_the_key_and_the_record()
  local lacked = diagnostic(rec .. "print(r.alpah)\n", "invalid_key")
  assert(lacked.key == "alpah" and lacked.variable == "r" and lacked.subject == "R" and
      lacked.resolved_kind == "record" and lacked.subject_kind == "nominal", lacked.msg)
  local fields = lacked.fields or {}
  table.sort(fields)
  assert(listed(fields, "alpha", "beta"), table.concat(fields, ","))
  local made = diagnostic(rec .. "local function make(): R\n  return r\nend\nprint(make().ALPHA)\n",
    "invalid_key")
  assert(made.key == "ALPHA" and made.variable == nil and made.subject == "R", made.msg)
  local interface = diagnostic("local interface Named\n  name: string\nend\n" ..
      "local n: Named = {name = 'x'}\nprint(n.nmae)\n", "invalid_key")
  assert(interface.resolved_kind == "interface" and interface.variable == "n", interface.msg)
  local described = diagnostic("local t = {x = 1}\nprint(t.z)\n", "invalid_key")
  assert(described.subject_kind == "record" and described.variable == "t", described.msg)
  local maybe = "local record R\n  n: integer\nend\n" ..
    "local function find(): R | nil return nil end\n"
  local key = diagnostic(maybe .. "local r = find()\nprint(r.n)\n", "cannot_index_key")
  assert(key.key == "n" and key.variable == "r" and listed(key.members, "R", "nil"), key.msg)
  local bare = diagnostic(maybe .. "print(find().n)\n", "cannot_index_key")
  assert(bare.variable == nil and listed(bare.members, "R", "nil"), bare.msg)
  local indexed = diagnostic("local function f(t: {integer} | nil): integer\n  return t[1]\nend\nprint(f)\n",
    "cannot_index_object")
  assert(listed(indexed.members, "{integer}", "nil"), indexed.msg)
  local lacking = diagnostic("local record R\n  alpha: integer\nend\nlocal r: R = {alpah = 1}\nprint(r)\n",
    "unknown_field")
  assert(lacking.key == "alpah" and lacking.subject == "R" and listed(lacking.fields, "alpha"),
    lacking.msg)
end

--- A call refused for its number of arguments carries the counts.
local function test_a_call_with_the_wrong_number_of_arguments_carries_its_counts()
  local too_few = diagnostic("local function f(a: string, b: string | nil) print(a, b) end\nf('x')\n", "arity")
  assert(too_few.given == 1 and too_few.expects == 2 and too_few.expects_most == 2, too_few.msg)
  local range = diagnostic("local function f(a: string, b?: string) print(a, b) end\nf()\n", "arity")
  assert(range.given == 0 and range.expects == nil and range.expects_most == 2, range.msg)
  local long = diagnostic("local function f(a: string) print(a) end\nf('x', 'y')\n", "arity")
  assert(long.given == 2 and long.expects == 1 and long.expects_most == 1, long.msg)
  local special = diagnostic("print(pcall())\n", "arity")
  assert(special.given == 0 and special.expects == nil and special.expects_most == 1, special.msg)
end

--- The names a refusal mentions: a variable declared nowhere, a hidden
--- one, a module and a type no declaration provides.
local function test_a_refused_name_is_carried_by_its_code()
  assert(diagnostic("print(nope)\n", "unknown_variable").variable == "nope")
  assert(diagnostic("local table = {1}\nprint(table)\n", "shadows").variable == "table")
  assert(diagnostic("local m = require('nope')\nprint(m)\n", "module_not_found").key == "nope")
  assert(listed(diagnostic("local x: Nope = nil\nprint(x)\n", "unknown_type").names, "Nope"))
  assert(listed(diagnostic("local Kv = {}\nlocal k: Kv.Kv\nprint(k)\n", "unknown_type").names, "Kv", "Kv"))
  assert(listed(diagnostic("local f: function(): never | nil\nprint(f)\n", "unknown_type").names, "never"))
  local generic = diagnostic(nested_generic .. "local l: Kv.Lru = nil\nreturn l\n", "missing_type_arguments")
  assert(listed(generic.names, "Lru") and listed(generic.type_arguments, "K", "V") and
      generic.subject_kind == "record", generic.msg)
end

--- What the parser refuses carries its kind: the tokens a list wanted
--- instead of a named vararg, and a type list that is not there.
local function test_a_syntax_error_carries_its_kind()
  local vararg = diagnostic("local function f(...names: string) end\n", "expected_one_of")
  assert(listed(vararg.expected_tokens, ")", ","), vararg.msg)
  diagnostic("local s: integer | \"null\" = \"null\"\nprint(s)\n", "type_list_expected")
end

--- A value that may be nil, or is untyped, where a table, a number or an
--- operand is wanted carries its members, and a call that never returns
--- carries its callee. (`<close>` on a type with no `__close` is not
--- reachable here: the checker's target has no `<close>`.)
local function test_a_value_that_may_be_nil_carries_its_members()
  local count = "local function count(): number | nil return nil end\nlocal n = count()\n"
  local bound = diagnostic(count .. "for i = 1, n do print(i) end\n", "for_bound")
  assert(listed(bound.members, "number", "nil") and bound.index == 3, bound.msg)
  local unary = diagnostic("local function f(x: integer | nil): integer\n  return -x\nend\nprint(f)\n",
    "operator_unary")
  assert(unary.operator == "-" and listed(unary.members, "integer", "nil"), unary.msg)
  local binary = diagnostic("local function f(x: string | integer): integer\n  return x + 1\nend\nprint(f)\n",
    "operator_binary")
  assert(binary.operator == "+" and listed(binary.left_members, "string", "integer") and
      listed(binary.right_members, "integer") and not binary.left_is_generic_function, binary.msg)
  local call = diagnostic("local function f<K>(k: K): K\n  return k\nend\nprint(f<string>(\"a\"))\n",
    "operator_binary")
  assert(call.operator == "<" and call.left_is_generic_function, call.msg)
  local list = diagnostic("local function list(): {string} | nil return nil end\n" ..
      "for _, s in ipairs(list()) do print(s) end\n", "not_array")
  assert(listed(list.members, "{string}", "nil"), list.msg)
  local pairs_of = diagnostic("local function list(): {string} | nil return nil end\n" ..
      "for _, s in pairs(list()) do print(s) end\n", "pairs_of_non_table")
  assert(listed(pairs_of.members, "{string}", "nil"), pairs_of.msg)
  local module = diagnostic("local function name(): string | nil return nil end\nprint(require(name()))\n",
    "require_argument")
  assert(listed(module.got_members, "string", "nil"), module.msg)
  local never = diagnostic("local function fail(m: string): never\n  error(m)\nend\n" ..
      "local x = fail('a')\nprint(x)\n", "no_initial_value")
  assert(never.variable == "x" and never.callee == "fail" and never.callee_never, never.msg)
  local plain = diagnostic("local function nothing(m: string)\nend\nlocal x = nothing('a')\nprint(x)\n",
    "no_initial_value")
  assert(plain.callee == nil and not plain.callee_never, plain.msg)
end

--- A call refused for its type parameter is told to bind the result in a
--- local only where the parameter is a name (`T` bound to `A` and `B`): one
--- bound to a shown type (`Box<string>` for a `Box<integer | string>`) has
--- no result to bind, and is told nothing.
local function test_a_type_parameter_hint_is_for_a_parameter_that_is_a_name()
  local boxes = "local record A\n  n: integer\nend\nlocal record B\n  m: integer\nend\n" ..
    "local record Box<T>\n  v: T\nend\n" ..
    "local function wrap<T>(a: Box<T>, b: Box<T>) print(a, b) end\n" ..
    "local x: Box<A> = {v = {n = 1}}\nlocal y: Box<B> = {v = {m = 1}}\nwrap(x, y)\n"
  local bound = diagnostic(boxes, "not_a")
  assert(bound.type_parameter == "T" and bound.context == "argument" and bound.index == 2, bound.msg)
  local hint = teal.replacement(bound, boxes)
  assert(hint ~= nil and hint:find("local v: R = setmetatable(t, mt)", 1, true) ~= nil, tostring(hint))
  local widened = "local record Box<T>\n  v: T\nend\nlocal a: Box<string> = {v = \"a\"}\n" ..
    "local b: Box<integer | string> = a\nprint(b)\n"
  local shown = diagnostic(widened, "mismatch")
  assert(shown.type_parameter == "integer | string" and shown.nested, shown.msg)
  assert(teal.replacement(shown, widened) == nil)
end

--- A name that hides another is told it hides the standard library's only
--- when the earlier one is not the program's own.
local function test_a_shadowed_name_is_told_it_hides_the_library_only_if_it_does()
  local own = "local table = {1}\nlocal table = {2}\nprint(table)\n"
  local both = diagnostics(own, "shadows")
  assert(#both == 2 and not both[1].declared_before and both[2].declared_before, both[2].msg)
  assert(teal.replacement(both[1], own) == hides_table)
  assert(teal.replacement(both[2], own) == nil)
  local functions = "local function table() end\nlocal function table() end\n"
  local twice = diagnostics(functions, "shadows")
  assert(twice[1].declares == "function" and twice[2].declared_before, twice[2].msg)
  assert(teal.replacement(twice[2], functions) == nil)
end

--- `Owner.Member` is told its hint only as the checker shows it bare: the
--- name with type arguments, or with where it was inferred, is another type.
local function test_an_unknown_type_with_arguments_is_told_nothing()
  local bound = "local Kv = require(\"kv\")\nlocal k: Kv.Kv = nil\nprint(k)\n"
  local bare = diagnostic(bound, "unknown_type")
  assert(listed(bare.names, "Kv", "Kv") and bare.subject == "Kv.Kv", bare.msg)
  local itself = "Kv is itself the type of the record its module returns: write Kv, not Kv.Kv"
  assert(teal.replacement(bare, bound) == itself)
  local arguments = "local Kv = require(\"kv\")\nlocal k: Kv.Kv<integer> = nil\nprint(k)\n"
  local generic = diagnostic(arguments, "unknown_type")
  assert(generic.subject == "Kv.Kv<integer>", generic.msg)
  assert(teal.replacement(generic, arguments) == nil)
  local inferred = unknown_type("Kv", "Kv")
  inferred.subject = "Kv.Kv (inferred at :2:10)"
  assert(teal.replacement(inferred, bound) == nil)
  local never = unknown_type("never")
  never.subject = "never<integer>"
  assert(teal.replacement(never, "local f: function(): never<integer>\n") == nil)
end

--- `<close>` on a type with no `__close` is refused with the type, and told
--- what to declare; a function type that returns a union is one type, not
--- a nil-able one.
local function test_a_non_closable_value_carries_its_type_end_to_end()
  local record = "local record S\n  n: integer\nend\nlocal function make(): S return { n = 1 } end\n" ..
    "local s <close> = make()\nprint(s)\n"
  local plain = diagnostic(record, "not_closable", true)
  assert(plain.variable == "s" and plain.subject == "S" and listed(plain.members, "S"), plain.msg)
  local hint = teal.replacement(plain, record)
  assert(hint ~= nil and hint:find("^`<close>` calls a `__close` the value's metatable holds"), tostring(hint))
  local maybe = "local record S\n  n: integer\nend\nlocal function find(): S | nil return nil end\n" ..
    "local s <close> = find()\nprint(s)\n"
  local nilable = diagnostic(maybe, "not_closable", true)
  assert(listed(nilable.members, "S", "nil"), nilable.msg)
  assert(teal.replacement(nilable, maybe) == "the call may answer nil: `local s <close> = " ..
      "assert(<the call>)` closes what it answers, and raises its error in place of the nil")
  local returning = "local function fn(): integer | string return 1 end\n" ..
    "local g: function(): integer | string = fn\nlocal c <close> = g\nprint(c)\n"
  local callable = diagnostic(returning, "not_closable", true)
  assert(listed(callable.members, "function(): integer | string"), table.concat(callable.members or {}, ","))
  assert(teal.replacement(callable, returning) == nil)
end

--- A call to a function that never returns, whose value is wanted, is
--- told so wherever the call stands in the declaration and however the
--- function is held.
local function test_a_never_call_is_told_wherever_it_stands()
  local later = diagnostic("local function die(): never error('x') end\nlocal c, d = 1, die()\nprint(c, d)\n",
    "no_initial_value")
  assert(later.variable == "d" and later.callee == "die" and later.callee_never, later.msg)
  local hint = teal.replacement(later, "")
  assert(hint ~= nil and hint:find("`die` never returns", 1, true) ~= nil, tostring(hint))
  local held = diagnostic("local h = error\nlocal i = h('x')\nprint(i)\n", "no_initial_value")
  assert(held.callee == "h" and held.callee_never, held.msg)
  assert(teal.replacement(held, "") ~= nil)
end

--- Each site that refuses an operand or a name sets the fields its code
--- names, and only declared ones ([`vet`] holds every error a test sees to
--- that): an operator no type takes, a function declared on an owner that is
--- declared nowhere, and a type compared with one declared nowhere.
local function test_each_site_that_refuses_an_operand_or_a_name_sets_declared_fields()
  local unary = diagnostic("local s = \"a\"\nprint(-s)\n", "operator_unary")
  assert(unary.operator == "-" and listed(unary.members, "string"), unary.msg)
  local owner = diagnostic("function Nope.f() end\n", "unknown_variable")
  assert(owner.variable == "Nope", owner.msg)
  local result = diagnostic("local record R\nend\nlocal function f(a: R): Nope2 return a end\nprint(f)\n",
    "unknown_type")
  assert(listed(result.names, "Nope2") and result.subject == "Nope2", result.msg)
  local parameter = diagnostic("local record R\nend\nlocal function f(a: Nope1): R return a end\nprint(f)\n",
    "unknown_type")
  assert(listed(parameter.names, "Nope1") and parameter.subject == "Nope1", parameter.msg)
end

--- A narrowed value's type is named without where it was inferred, as the
--- checker's own message names it with.
local function test_a_missing_key_of_a_narrowed_value_names_the_type_alone()
  local source = "local function f(a: integer | string)\n  if a is string then\n    print(a.lenn)\n  end\nend\nprint(f)\n"
  local found = diagnostic(source, "invalid_key")
  assert(found.msg:find("(inferred at", 1, true) ~= nil, found.msg)
  assert(found.subject == "string", tostring(found.subject))
  local hint = teal.replacement(found, source)
  assert(hint ~= nil and hint:find("^did you mean 'len'%? string's fields: "), tostring(hint))
end

--- An index key that may be nil, where the value indexed may be too, is
--- told to check for nil; the checker's refusal names the key's type with a
--- union, which the hint does not depend on.
local function test_an_index_that_may_be_nil_is_told_the_check()
  local source = "local function f(t: {integer} | nil, i: integer | nil): integer\n  return t[i]\nend\nprint(f)\n"
  local found = diagnostic(source, "cannot_index_object")
  assert(found.msg:find("with integer | nil", 1, true) ~= nil, found.msg)
  assert(listed(found.members, "{integer}", "nil"), found.msg)
  assert(teal.replacement(found, source) == "the value may be nil: check it first (`if value == nil then " ..
      "return nil, err end`), or, where a call answers it, take it with `local value = assert(<the call>)`")
end

--- The compiler's own record of an error documents nothing: the docs
--- pointer an unresolved name earns looks a symbol up by its last name, and
--- a field called `i` or `key` is none a program meant.
local function test_the_compilers_error_record_has_no_docs_for_a_pointer_to_find()
  local inside = false
  local text = assert(Fs.read("build/compiler.d.tl"))
  local seen = 0
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if line == "  record Error" or line == "  enum ErrorCode" then
      inside = true
    elseif line == "  end" then
      inside = false
    elseif inside then
      seen = seen + 1
      assert(line:match("^%s*%-%-%-") == nil, "a doc comment on " .. line)
    end
  end
  assert(seen > 50, "found no declarations to hold")
end
