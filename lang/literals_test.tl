--- Tests of [`lang.literals`]: the reads of a pattern, a replacement, a format and a pack format, held to what Lua does
--- with them. A literal read as right must never make Lua raise, and each one read as wrong comes with a subject or a
--- value on which Lua raises the error the read names.
local Literals = require("lang.literals")
local Test = require("cosmic.test")

Test.policy{}

local function has(text: string, part: string): boolean
  return text:find(part, 1, true) ~= nil
end

--- What Lua says when it runs `find`, `match`, `gmatch` or `gsub` with `pattern` on `subject`: "" where it does not raise.
local function pattern_error(pattern: string, subject: string): string
  local said: mut {string} = {}
  local functions: {function(string, string): any} = {
    function(s: string, p: string): any return (s:find(p)) end,
    function(s: string, p: string): any return (s:match(p)) end,
    function(s: string, p: string): any
      for _ in s:gmatch(p) do
      end
      return nil
    end,
    function(s: string, p: string): any return (s:gsub(p, "")) end,
  }
  for _, each in ipairs(functions) do
    local ok, why = pcall(each, subject, pattern)
    if not ok then
      said[#said + 1] = tostring(why)
    end
  end
  return table.concat(said, "|")
end

--- A deterministic draw from 1 to `n`.
local function drawer(seed: integer): function(n: integer): integer
  local held = { state = seed }
  return function(n: integer): integer
    held.state = (held.state * 1103515245 + 12345) % 2147483648
    return held.state % n + 1
  end
end

--- The pack format with each `!` that names no alignment naming 16, the widest a build of cosmic has: the check reads a bare
--- `!` as that build's (a program runs on every build), and this host's own may be narrower (8 on macOS on arm64, whose
--- `long double` is a `double`), so its Lua answers for the widest build only when told the alignment.
local function at_widest(format: string): string
  local wide = ""
  for i = 1, #format do
    local c = format:sub(i, i)
    wide = wide .. c
    if c == "!" and format:sub(i + 1, i + 1):match("%d") == nil then
      wide = wide .. "16"
    end
  end
  return wide
end

--- What a problem says, or "".
local function message(problem: Literals.Problem?): string
  return problem ~= nil and problem.msg or ""
end

-- patterns -------------------------------------------------------------------------------------------------------------

--- Each wrong pattern, a subject on which Lua raises, and the part of the message of the problem and of Lua's error.
local WRONG_PATTERNS <const>: {{string}} = {
  { "a)", "a", "closes no capture", "invalid pattern capture" },
  { "(a", "a", "never closed (at character 1)", "unfinished capture" },
  { "((a)", "a", "capture 1 is never closed (at character 1)", "unfinished capture" },
  { "[a", "a", "no closing `]`", "missing ']'" },
  { "[%", "a", "no closing `]`", "missing ']'" },
  { "[^", "a", "no closing `]`", "missing ']'" },
  { "a%", "a", "ends with `%`", "ends with '%'" },
  { "%b", "a", "two characters", "missing arguments to '%b'" },
  { "%bx", "a", "two characters", "missing arguments to '%b'" },
  { "%f", "a", "not followed by a set", "missing '[' after '%f'" },
  { "%fa", "a", "not followed by a set", "missing '[' after '%f'" },
  { "%f[a", "a", "no closing `]`", "missing ']'" },
  { "%1", "a", "not closed before it", "invalid capture index %1" },
  { "(a%2)", "a", "not closed before it", "invalid capture index %2" },
  { "(a%1)", "a", "not closed before it", "invalid capture index %1" },
  { "a%0", "a", "not closed before it", "invalid capture index %0" },
  { "()()()()()()()()()()()()()()()()()()()()()()()()()()()()()()()()()", "a", "more than 32 captures",
    "too many captures" },
}

local function test_a_pattern_that_lua_raises_on_is_found_and_says_what_lua_says()
  for _, each in ipairs(WRONG_PATTERNS) do
    local pattern, subject, ours, lua = each[1], each[2], each[3], each[4]
    local read = Literals.pattern(pattern)
    local problem = read.problem
    assert(problem ~= nil, "taken: " .. pattern)
    assert(has(problem.msg, ours), pattern .. ": " .. problem.msg)
    assert(has(problem.msg, "(at character"), problem.msg)
    assert(#problem.fix > 10, pattern)
    local said = pattern_error(pattern, subject)
    assert(has(said, lua), pattern .. ": Lua says " .. said)
  end
end

local RIGHT_PATTERNS <const>: {string} = {
  "", "a", "^a$", "a*", "a+b-c?", "%a+", "%d%d", "(a)", "()", "(a)(b)%2%1", "%b()", "%f[%w]", "[a-z]", "[]]", "[^]]",
  "[%]]", "[a%-z]", "(a(b)c)", "a$b", "$", "^", "%%", "%(", "%)", "%[", "]", "(()a)", "[%a_][%w_]*", "^%s*(.-)%s*$",
}

local function test_a_pattern_lua_reads_is_taken_and_does_not_make_it_raise()
  for _, pattern in ipairs(RIGHT_PATTERNS) do
    local read = Literals.pattern(pattern)
    assert(read.problem == nil, "refused: " .. pattern .. ": " .. message(read.problem))
    for _, subject in ipairs({ "", "a", "ab", "abc123", "(a)", "a b" }) do
      assert(pattern_error(pattern, subject) == "", pattern .. " on " .. subject)
    end
  end
end

local function test_a_pattern_the_walk_takes_never_makes_lua_raise_whatever_the_subject()
  local draw = drawer(12345)
  local parts: {string} = { "a", "a", "%", "(", ")", "[", "]", "^", "$", "*", "-", "+", "?", ".", "%f", "%b", "%1", "%a", "%%" }
  local subjects: {string} = { "", "a", "aa", "aaa", "a.a", "a)a", "(", "[", "]", "^", "$", "a]", "a[a", "aaaa", "a-a", "a%a" }
  local taken, refused = 0, 0
  for _ = 1, 3000 do
    local pieces: mut {string} = {}
    for _ = 1, draw(6) do
      local piece = assert(parts[draw(#parts)])
      pieces[#pieces + 1] = piece
    end
    local pattern = table.concat(pieces)
    if Literals.pattern(pattern).problem == nil then
      taken = taken + 1
      for _, subject in ipairs(subjects) do
        assert(pattern_error(pattern, subject) == "", pattern .. " on " .. subject .. ": " .. pattern_error(pattern, subject))
      end
    else
      refused = refused + 1
    end
  end
  -- both sides were drawn, so the comparison compared something
  assert(taken > 100 and refused > 100, tostring(taken) .. " taken, " .. tostring(refused) .. " refused")
end

local function test_the_captures_of_a_pattern_are_texts_and_positions_in_order()
  local read = Literals.pattern("(a)()(%w+)")
  assert(read.problem == nil and table.concat(read.captures, " ") == "string position string", table.concat(read.captures, " "))
  assert(#Literals.pattern("abc").captures == 0)
  assert(Literals.key("%w") == "string" and Literals.key("(%w)") == "string" and Literals.key("()") == "integer")
  assert(Literals.key("()(a)") == "integer" and Literals.key("(a)()") == "string")
  assert(Literals.key("(a") == nil)
end

local function test_a_replacement_names_only_the_captures_the_pattern_has_and_escapes_its_percent()
  assert(Literals.replacement("x%0y%%z", 0) == nil)
  assert(Literals.replacement("%1", 0) == nil, "%1 is the whole match when the pattern has no capture")
  assert(Literals.replacement("%1%2", 2) == nil)
  local past = Literals.replacement("%3", 2)
  assert(past ~= nil and has(past.msg, "`%3` is used") and has(past.msg, "2 captures"), tostring(past ~= nil and past.msg))
  local none = Literals.replacement("%2", 0)
  assert(none ~= nil and has(none.msg, "no capture"))
  local stray = Literals.replacement("100%", 0)
  assert(stray ~= nil and has(stray.msg, "followed by nothing"), tostring(stray ~= nil and stray.msg))
  local letter = Literals.replacement("%a", 1)
  assert(letter ~= nil and has(letter.msg, "followed by `a`"), tostring(letter ~= nil and letter.msg))
  -- Lua agrees on each
  local function replaces(replacement: string, pattern: string): string
    local ok, why = pcall(function(): string
      return (("abc"):gsub(pattern, replacement))
    end)
    return if ok then "" else tostring(why) end
  end
  assert(replaces("%3", "(a)(b)") ~= "" and replaces("%1", "a") == "" and replaces("100%", "a") ~= "" and replaces("%a", "a") ~= "")
end

-- formats --------------------------------------------------------------------------------------------------------------

local function test_a_format_the_walk_takes_is_the_one_lua_takes_and_the_other_way()
  local draw = drawer(777)
  local parts: {string} = { "%", "%", "d", "5", ".", "-", "0", "q", "s", "y", "c", "#", "+", " ", "x", "f", "1", "i", "u", "a",
    "e", "g", "p", "%%", "12", "3", "F" }
  local agreed, refused = 0, 0
  for _ = 1, 4000 do
    local pieces: mut {string} = {}
    for _ = 1, draw(7) do
      local piece = assert(parts[draw(#parts)])
      pieces[#pieces + 1] = piece
    end
    local format = table.concat(pieces)
    local read = Literals.format(format)
    local values: mut {any} = {}
    for i = 1, #read.kinds + 1 do
      values[i] = 1
    end
    local ok, why = pcall(string.format, format, table.unpack(values))
    local lua_refuses = not ok and (has(tostring(why), "invalid conversion") or has(tostring(why), "cannot have modifiers") or
      has(tostring(why), "too long"))
    assert((read.problem ~= nil) == lua_refuses, format .. ": " .. tostring(why))
    agreed = agreed + 1
    if read.problem ~= nil then
      refused = refused + 1
    end
  end
  assert(agreed == 4000 and refused > 500 and refused < 3500, tostring(refused))
end

local function test_a_format_says_which_conversion_is_wrong_and_how_many_values_it_takes()
  local function problem_of(format: string): string
    return message(Literals.format(format).problem)
  end
  assert(has(problem_of("%"), "`%` is no conversion"))
  assert(has(problem_of("%y"), "`%y` is no conversion"))
  assert(has(problem_of("%F"), "`%F` is no conversion"))
  assert(has(problem_of("%10q"), "cannot have modifiers"))
  assert(has(problem_of("%5.1c"), "flag, width or precision that `%c` does not take"))
  assert(has(problem_of("%123d"), "a flag, width or precision"))
  assert(problem_of("%5.2f%-8s%q%x%c%i%u%o%e%g%a%p%%") == "")
  assert(table.concat(Literals.format("%5.2f %% %s %d %q %c %x %e %p").kinds, " ") ==
      "number any integer quoted integer integer number any")
  assert(#Literals.format("plain").kinds == 0)
end

-- pack formats ---------------------------------------------------------------------------------------------------------

local function test_a_pack_format_the_walk_takes_is_the_one_lua_takes_and_the_other_way()
  local draw = drawer(31)
  local parts: {string} = { "b", "B", "h", "H", "i", "I", "l", "L", "j", "J", "T", "f", "d", "n", "c", "x", "X", "<", ">", "=",
    "!", " ", "1", "2", "3", "4", "5", "8", "16", "17", "0", "y", "9", "12" }
  local refused = 0
  for _ = 1, 4000 do
    local pieces: mut {string} = {}
    for _ = 1, draw(6) do
      local piece = assert(parts[draw(#parts)])
      pieces[#pieces + 1] = piece
    end
    local format = table.concat(pieces)
    local read = Literals.pack(format)
    local ok, why = pcall(string.packsize, at_widest(format))
    assert((read.problem ~= nil) == not ok, format .. ": " .. tostring(why))
    if read.problem ~= nil then
      refused = refused + 1
    end
  end
  assert(refused > 500 and refused < 3500, tostring(refused))
end

local function test_a_pack_format_that_has_a_size_that_depends_on_the_value_is_variable_and_counts_its_values()
  local read = Literals.pack("<i4 s z c3 x Xi4 !4 d")
  assert(read.problem == nil and read.variable and #read.kinds == 5, tostring(#read.kinds))
  assert(not Literals.pack("<i4 c3").variable and #Literals.pack("<i4 c3").kinds == 2)
  local function problem_of(format: string): string
    return message(Literals.pack(format).problem)
  end
  assert(has(problem_of("i17"), "out of range") and has(problem_of("i0"), "out of range"))
  assert(has(problem_of("c"), "has no size") and has(problem_of("y"), "no option of `string.pack`"))
  assert(has(problem_of("X"), "aligns to nothing") and has(problem_of("Xc3"), "no alignment") and has(problem_of("Xz"), "no alignment"))
  assert(has(problem_of("!i3"), "alignment of 3") and problem_of("i3") == "" and problem_of("!8i3") ~= "")
  -- a fault after a variable option is found too
  assert(has(problem_of("sy"), "no option"))
end

-- the call -------------------------------------------------------------------------------------------------------------

--- The codes the literals of a call have, space separated.
local function codes_of(fn: string, literals: {integer: string}, plain?: string): string
  local codes: mut {string} = {}
  for _, found in ipairs(Literals.check({ fn = fn, literals = literals, plain = plain or "none" })) do
    codes[#codes + 1] = found.code .. "@" .. tostring(found.place)
  end
  return table.concat(codes, " ")
end

local function test_a_call_is_read_where_it_is_a_pattern_a_replacement_a_format_or_a_pack_format()
  assert(codes_of("find", { "abc", "a)" }) == "pattern_malformed@2")
  assert(codes_of("match", { [2] = "(" }) == "pattern_malformed@2")
  assert(codes_of("gmatch", { [2] = "[" }) == "pattern_malformed@2")
  assert(codes_of("gsub", { [2] = "%w", [3] = "%2" }) == "pattern_malformed@3")
  assert(codes_of("gsub", { [2] = "(", [3] = "%2" }) == "pattern_malformed@2", "a replacement is read only for a pattern that is right")
  assert(codes_of("format", { "%y" }) == "format_malformed@1")
  assert(codes_of("pack", { "y" }) == "pack_malformed@1")
  assert(codes_of("unpack", { "y", "" }) == "pack_malformed@1")
  assert(codes_of("packsize", { "s" }) == "pack_malformed@1")
  -- a pattern that is no literal is not read, nor one `find` is asked to take as plain text
  assert(codes_of("find", {}) == "")
  assert(codes_of("find", { [2] = "a)" }, "true") == "")
  assert(codes_of("find", { [2] = "a)" }, "other") == "")
  assert(codes_of("find", { [2] = "a)" }, "false") == "pattern_malformed@2")
  assert(codes_of("gsub", { [2] = "%w", [3] = "x" }) == "")
end

local function test_each_conversion_with_each_flag_width_and_precision_is_read_as_lua_reads_it()
  local checked = 0
  for _, conversion in ipairs({ "c", "d", "i", "u", "o", "x", "X", "a", "A", "e", "E", "f", "F", "g", "G", "p", "q", "s", "y", "n" }) do
    for _, flag in ipairs({ "", "-", "+", "#", " ", "0", "-0", "+ " }) do
      for _, size in ipairs({ "", "5", "05", ".3", "5.3", "123", ".123", "5.", ".", "00", "99.99", "100" }) do
        local format = "%" .. flag .. size .. conversion
        local ok, why = pcall(string.format, format, 1)
        local lua_refuses = not ok and (has(tostring(why), "invalid conversion") or has(tostring(why), "cannot have modifiers"))
        assert((Literals.format(format).problem ~= nil) == lua_refuses, format .. ": " .. tostring(why))
        checked = checked + 1
      end
    end
  end
  assert(checked == 20 * 8 * 12, tostring(checked))
  -- a conversion Lua finds too long: twenty flags are read, twenty-one are not
  for _, count in ipairs({ 20, 21, 22, 30 }) do
    local format = "%" .. string.rep("-", count) .. "d"
    local ok, why = pcall(string.format, format, 1)
    assert((Literals.format(format).problem ~= nil) == not ok, tostring(count) .. ": " .. tostring(why))
  end
end

local function test_the_default_alignment_of_a_bang_is_the_widest_of_the_build()
  -- `!` with no number is the alignment of the widest type of the widest build, 16: a size that is no power of 2 under it
  -- raises there, and a build with a narrower one clamps it, so the format is refused for every build
  for _, format in ipairs({ "!i12", "!i9", "!s13h", "!bi16", "!i16", "!i8", "!i3", "!s12", "!i4i12" }) do
    local ok, why = pcall(string.packsize, at_widest(format))
    local variable = format:find("s", 1, true) ~= nil
    local read = Literals.pack(format)
    assert((read.problem ~= nil) == (not ok and not has(tostring(why), "variable-length")), format .. ": " .. tostring(why))
    assert(variable or (read.problem ~= nil) == not ok, format)
  end
  assert(Literals.pack("!i12").problem ~= nil and Literals.pack("!8i12").problem == nil and Literals.pack("!i16").problem == nil)
end

local function test_a_pack_format_is_variable_for_s_and_z_only()
  assert(Literals.pack("z").variable and Literals.pack("s").variable and Literals.pack("s4").variable)
  assert(not Literals.pack("c3").variable and not Literals.pack("i4").variable and not Literals.pack("x").variable)
  assert(table.concat(Literals.pack("bBhHlLjJTiI4 f d n s z c3 x X i4").kinds, " ") ==
      "integer integer integer integer integer integer integer integer integer integer integer number number number string string string")
  assert(#Literals.pack("x").kinds == 0)
end

--- The programs that give a literal a type, as Lua runs them: each raises, or answers the type the literal says.
local function test_each_program_the_fork_types_from_its_literal_is_one_lua_faults_on_or_answers_as_typed()
  local function formats(format: string, ...: any): boolean
    return (pcall(string.format, format, ...))
  end
  local function packs(format: string, ...: any): boolean
    return (pcall(string.pack, format, ...))
  end
  local function finds(subject: string, pattern: string): boolean
    return (pcall(string.find, subject, pattern))
  end
  assert(not formats("%d", "x"))
  assert(not formats("%d", 1.5))
  assert(not formats("%c", "a"))
  assert(not formats("%f", true))
  assert(not packs("i", "x"))
  assert(not formats("%d %d", 1))
  assert(formats("%d %s %q", 1, {}, "x"), "an argument of %s may be any value")
  assert(not finds("abc", "%b("))
  assert(not formats("%y", 1))
  -- a position capture is an integer
  local iterate = ("abc"):gmatch("()")
  assert(math.type(iterate()) == "integer")
  local _, _, position = ("abc"):find("()")
  assert(math.type(position) == "integer")
  local replaced = ("abc"):gsub("()", function(at: integer): string
    return tostring(at)
  end)
  assert(replaced == "1a2b3c4")
  -- and the results of unpack are the integer and the string the format says
  local packed = string.pack("i4z", 7, "s")
  local number, text, next_at = string.unpack("i4z", packed)
  assert(math.type(number) == "integer" and text == "s" and next_at == #packed + 1)
end
