--- Fuzz properties for what `cosmic fix` writes ([`build.fix.source`]):
--- on a Teal program drawn from every kind of statement the parser
--- produces, with comments, blank lines and line breaks drawn between and
--- inside them, the fix either refuses by name or writes a text that
--- parses to the same program, and fixing it again leaves it as it is
--- (both of which [`build.fix.source`] checks itself, the second by
--- rendering its output once more, which is all fixing it again would
--- do while [`build.fix.rule`] holds no rules); and every comment's text
--- reaches it.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local ast = require("build.ast")
local equiv = require("build.fix.equiv")
local fix = require("build.fix")
local teal = require("build.teal")

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

--- One program being drawn: its source, the count of comments marked so
--- far, and what the enclosing function and loop allow.
local record Gen
  src: Fuzz.Source
  marks: integer
  vararg: boolean
  loop: boolean
end

local NAMES <const> = { "a", "b", "x", "y", "t", "M", "_", "n1", "value", "self",
  "a_name_long_enough_to_push_a_line_past_any_width" }
local FIELDS <const> = { "f", "g", "name", "go", "k2" }
local NUMBERS <const> = { "0", "1", "42", "3.5", "0x1F", "1e10", "0.5e-3", ".5", "0xA.8p1" }
local STRINGS <const> = { '"s"', "'q'", '"a\\"b"', '"\\n\\t"', '"-- not a comment"', '"--[[ nor this ]]"',
  "'\\65'", '"\\u{e9}"', '"\\z\n     joined"', '"\\\n"', '""' }
--- Long strings, whose bytes are the value: trailing spaces and lines
--- that read as comments included.
local LONG_STRINGS <const> = { "[[long]]", "[==[ a ]] b ]==]", "[[\nline one  \n  line two\n]]",
  "[[ trailing   ]]", "[=[\n--[[ not a comment ]]\n-- nor this\n]=]", "[[]]" }
local BINOPS <const> = { "+", "-", "*", "/", "//", "%", "^", "..", "==", "~=", "<", "<=", ">", ">=",
  "and", "or", "&", "|", "~", "<<", ">>" }
local UNOPS <const> = { "-", "not", "#", "~" }
local ATTRIBUTES <const> = { "<const>", "< const >", "<close>", "<total>", "<const >" }
--- A comment's words: none holds a `]]`, so any fits a long comment too.
local WORDS <const> = { "why", "a note", "keep -- this", "x = 1 end", "\"q\"", "it's", "\u{e9}t\u{e9}",
  "see `a.b`", "[[ half", "end)", "return", "  spaced  out" }
local TYPES <const> = { "integer", "string", "number", "boolean", "any", "nil", "{string}",
  "{string: integer}", "{integer, string}", "function(integer): string", "string | integer",
  "Mod.Type", "R<integer>", "T", "function(...: any)", "{string:any}", "thread" }

local function chance(g: Gen, one_in: integer): boolean
  return g.src:int(1, one_in) == 1
end

local function pick<T>(g: Gen, choices: {T}): T
  return Fuzz.pick(g.src, choices)
end

--- Where a line starts: any column from 0 to 8, or a tab.
local function indent(g: Gen): string
  local k = g.src:int(0, 9)
  if k == 9 then return "\t" end
  return string.rep(" ", k)
end

--- A comment's own text, marked `@n@` so that losing it is found by
--- the bytes alone, whatever the lexer made of it.
local function mark(g: Gen): string
  g.marks = g.marks + 1
  return "@" .. g.marks .. "@"
end

--- A comment that runs to the end of its line: the caller writes the
--- line break after it.
local function line_comment(g: Gen): string
  local k = g.src:int(1, 7)
  if k == 1 then return "-- " .. mark(g) .. " " .. pick(g, WORDS) end
  if k == 2 then return "--- " .. mark(g) .. " " .. pick(g, WORDS) end
  if k == 3 then return "--" .. mark(g) end
  if k == 4 then return "--#region " .. mark(g) end
  if k == 5 then return "--" end
  if k == 6 then return "---" .. mark(g) .. pick(g, WORDS) end
  return "-- " .. mark(g) .. " --[[ " .. pick(g, WORDS)
end

--- A long comment, closed on its own line or another.
local function long_comment(g: Gen): string
  local k = g.src:int(1, 5)
  if k == 1 then return "--[[ " .. mark(g) .. " " .. pick(g, WORDS) .. " ]]" end
  if k == 2 then
    return "--[[ " .. mark(g) .. "\n" .. pick(g, WORDS) .. "\n" .. indent(g) .. "]]"
  end
  if k == 3 then return "--[==[ " .. mark(g) .. " a ]] b ]==]" end
  if k == 4 then return "--[[" .. mark(g) .. "]]" end
  return "--[=[ " .. mark(g) .. "\n\n" .. indent(g) .. pick(g, WORDS) .. " ]=]"
end

--- What separates two tokens: a space mostly, else a line break, a blank
--- line, a run of spaces or a tab, or a comment.
local function gap(g: Gen): string
  local k = g.src:int(0, 24)
  if k <= 15 then return " " end
  if k <= 18 then return "\n" .. indent(g) end
  if k == 19 then return " " .. long_comment(g) .. " " end
  if k == 20 then return " " .. line_comment(g) .. "\n" .. indent(g) end
  if k == 21 then return "\n\n" .. indent(g) end
  if k == 22 then return "\n" .. indent(g) .. long_comment(g) .. "\n" .. indent(g) end
  if k == 23 then return "    " end
  return "\t"
end

--- What may separate two tokens that need nothing between them.
local function tight(g: Gen): string
  if g.src:int(0, 5) > 0 then return "" end
  return gap(g)
end

--- What separates two statements: a line break mostly, with a trailing
--- comment before it and blank lines and comments of their own lines
--- after it, else a space or a `;`, a comment in front of it or not.
local function sep(g: Gen): string
  local k = g.src:int(0, 11)
  if k == 0 then return " " end
  if k == 1 then return chance(g, 2) and "; " or " " .. long_comment(g) .. " ; " end
  if k == 2 then return ";\n" .. indent(g) end
  local parts: {string} = {}
  if chance(g, 5) then parts[#parts + 1] = " " .. line_comment(g) end
  parts[#parts + 1] = "\n"
  local lines = 0
  while Fuzz.more(g.src, lines, 3) do
    lines = lines + 1
    local w = g.src:int(0, 3)
    if w == 0 then
      parts[#parts + 1] = "\n"
    elseif w == 1 then
      parts[#parts + 1] = indent(g) .. long_comment(g) .. "\n"
    else
      parts[#parts + 1] = indent(g) .. line_comment(g) .. "\n"
    end
  end
  parts[#parts + 1] = indent(g)
  return table.concat(parts)
end

--- What separates two entries of a record's body: a line break, with
--- what may follow one.
local function entry_sep(g: Gen): string
  local s = sep(g)
  if s:sub(1, 1) == ";" or s == " " then return "\n" .. indent(g) end
  return s
end

--- A type; one followed by a `,` and a type or a bare name (`listed`)
--- is never a function type. A function type's return list takes in
--- what follows a `,` unless it starts a parameter (`name:`, `name?:`,
--- `?T`, `...`), so `function(): function(): integer, string` returns
--- two values from the inner function, not one from each. That is
--- Teal's grammar, not a bug, and no rendering can spell the other
--- reading.
local function typ(g: Gen, listed?: boolean): string
  local t = pick(g, TYPES)
  if listed and t:find("^function") ~= nil then t = "integer" end
  if chance(g, 15) then
    -- A type broken over lines: its bytes are what is written.
    t = "{string:" .. gap(g) .. t .. "}"
  end
  return t
end

local expr: function(Gen, integer): string
local block: function(Gen, integer): string

local function atom(g: Gen): string
  local k = g.src:int(1, 9)
  if k <= 3 then return pick(g, NAMES) end
  if k == 4 then return pick(g, NUMBERS) end
  if k == 5 then return pick(g, STRINGS) end
  if k == 6 then return pick(g, LONG_STRINGS) end
  if k == 7 then return pick(g, { "nil", "true", "false" }) end
  if k == 8 and g.vararg then return "..." end
  return pick(g, NAMES) .. "." .. pick(g, FIELDS)
end

--- A list of up to `max` expressions, each after a comma, the first
--- always there.
local function exprs(g: Gen, d: integer, max: integer): string
  local out: {string} = { expr(g, d) }
  while Fuzz.more(g.src, #out, max) do
    out[#out + 1] = tight(g) .. "," .. gap(g) .. expr(g, d)
  end
  return table.concat(out)
end

--- A call's arguments, glued to what is called: a newline before the `(`
--- would be a second statement.
local function args(g: Gen, d: integer): string
  local k = g.src:int(1, 8)
  if k == 1 then return " " .. pick(g, STRINGS) end
  if k == 2 then return " " .. pick(g, LONG_STRINGS) end
  if k == 3 then return "()" end
  if k == 4 then
    local tbl = expr(g, 0)
    return "{" .. tight(g) .. tbl .. tight(g) .. "}"
  end
  return "(" .. tight(g) .. exprs(g, d, 4) .. tight(g) .. ")"
end

--- Something that can be called or indexed: a name, a field, an index,
--- a call; and whether it ends in a call.
local function prefix(g: Gen, d: integer): string, boolean
  local p = pick(g, NAMES)
  local called = false
  local n = 0
  while Fuzz.more(g.src, n, 3) do
    n = n + 1
    local k = g.src:int(1, 4)
    called = k >= 3
    if k == 1 then
      p = p .. tight(g) .. "." .. pick(g, FIELDS)
    elseif k == 2 then
      local key = expr(g, d - 1)
      -- `t[[` would open a long string.
      if key:sub(1, 1) == "[" then key = " " .. key .. " " end
      p = p .. "[" .. tight(g) .. key .. tight(g) .. "]"
    elseif k == 3 then
      p = p .. args(g, d - 1)
    else
      p = p .. tight(g) .. ":" .. pick(g, FIELDS) .. args(g, d - 1)
    end
  end
  return p, called
end

local function call(g: Gen, d: integer): string
  local p, _ = prefix(g, d)
  if chance(g, 3) then
    return p .. tight(g) .. ":" .. pick(g, FIELDS) .. args(g, d)
  end
  return p .. args(g, d)
end

local function generics(g: Gen): string
  if not chance(g, 4) then return "" end
  return pick(g, { "<T>", "<T, U>", "< T >" })
end

--- A parameter list and return types.
local function signature(g: Gen): string, boolean
  local names: {string} = {}
  local kinds: {integer} = {}
  local optional = false
  while Fuzz.more(g.src, #names, 4) do
    local p = pick(g, NAMES)
    if p == "self" or p == "_" then p = "p" .. #names end
    -- Only an optional parameter may follow an optional one.
    local k = g.src:int(optional and 3 or 1, 3)
    optional = k == 3
    names[#names + 1] = p
    kinds[#kinds + 1] = k
  end
  -- A typed parameter is a function type only where what follows it is
  -- no bare name, which its return list would take in.
  local params: {string} = {}
  for i, p in ipairs(names) do
    local listed = kinds[i + 1] == 1
    if kinds[i] == 2 then
      p = p .. ":" .. gap(g) .. typ(g, listed)
    elseif kinds[i] == 3 then
      p = p .. "?:" .. tight(g) .. typ(g, listed)
    end
    params[#params + 1] = p
  end
  local vararg = chance(g, 4)
  if vararg then params[#params + 1] = chance(g, 2) and "..." or "...: any" end
  local out = generics(g) .. "(" .. tight(g)
  for i, p in ipairs(params) do
    if i > 1 then out = out .. tight(g) .. "," .. gap(g) end
    out = out .. p
  end
  out = out .. tight(g) .. ")"
  local r = g.src:int(0, 3)
  if r == 1 then
    out = out .. tight(g) .. ":" .. gap(g) .. typ(g)
  elseif r == 2 then
    -- A function type first would take the second type into its own
    -- return list: Teal's grammar, not a bug in tl.
    out = out .. ": " .. typ(g, true) .. "," .. gap(g) .. typ(g)
  end
  return out, vararg
end

--- A signature and a body down to its `end`, with what the body allows.
local function body(g: Gen, d: integer): string
  local s, vararg = signature(g)
  local was_vararg, was_loop = g.vararg, g.loop
  g.vararg, g.loop = vararg, false
  local b = block(g, d - 1)
  g.vararg, g.loop = was_vararg, was_loop
  return s .. b .. "end"
end

local function table_constructor(g: Gen, d: integer): string
  local out: {string} = { "{" }
  local n = 0
  while Fuzz.more(g.src, n, 5) do
    out[#out + 1] = n == 0 and tight(g) or gap(g)
    n = n + 1
    local k = g.src:int(1, 3)
    if k == 1 then
      out[#out + 1] = pick(g, FIELDS) .. gap(g) .. "=" .. gap(g) .. expr(g, d - 1)
    elseif k == 2 then
      local key = expr(g, d - 1)
      if key:sub(1, 1) == "[" then key = " " .. key .. " " end
      out[#out + 1] = "[" .. key .. "]" .. gap(g) .. "=" .. gap(g) .. expr(g, d - 1)
    else
      out[#out + 1] = expr(g, d - 1)
    end
    if Fuzz.more(g.src, 0, 4) then
      out[#out + 1] = tight(g) .. pick(g, { ",", ",", ";" })
    else
      -- The last entry may go without a separator; any other needs one.
      out[#out + 1] = tight(g) .. ","
    end
  end
  out[#out + 1] = tight(g) .. "}"
  return table.concat(out)
end

--- A sum of many terms on one line, longer than any width a line keeps
--- to.
local function long_line(g: Gen): string
  local out: {string} = {}
  -- Twelve names reach past any width whichever are drawn.
  for i = 1, 12 do
    out[i] = pick(g, NAMES)
  end
  while Fuzz.more(g.src, #out, 30) do
    out[#out + 1] = pick(g, NAMES)
  end
  return table.concat(out, " + ")
end

expr = function(g: Gen, d: integer): string
  if d <= 0 then return atom(g) end
  local k = g.src:int(1, 30)
  if k <= 8 then return atom(g) end
  if k <= 12 then
    local left, right = expr(g, d - 1), expr(g, d - 1)
    return left .. gap(g) .. pick(g, BINOPS) .. gap(g) .. right
  end
  if k <= 14 then
    local op = pick(g, UNOPS)
    local operand = expr(g, d - 1)
    -- `--x` would be a comment, `not` a name with what follows.
    local between = (op == "not" or operand:sub(1, 1) == "-") and gap(g) or tight(g)
    return op .. between .. operand
  end
  if k == 15 then return "(" .. tight(g) .. expr(g, d - 1) .. tight(g) .. ")" end
  if k <= 18 then return (prefix(g, d)) end
  if k <= 20 then return call(g, d) end
  if k <= 22 then return "function" .. body(g, d) end
  if k <= 25 then return table_constructor(g, d) end
  if k == 26 then return pick(g, NAMES) .. gap(g) .. "as" .. gap(g) .. typ(g) end
  if k == 27 then return pick(g, NAMES) .. " is " .. typ(g) end
  if k == 28 then return long_line(g) end
  return "(" .. expr(g, d - 1) .. ")" .. gap(g) .. pick(g, BINOPS) .. gap(g) .. expr(g, d - 1)
end

--- One or more names, each with an attribute or not, and a type list
--- of as many types or none.
local function declared(g: Gen): string
  local names: {string} = {}
  repeat
    local n = pick(g, NAMES)
    if chance(g, 4) then n = n .. pick(g, { " ", "  ", "" }) .. pick(g, ATTRIBUTES) end
    names[#names + 1] = n
  until not Fuzz.more(g.src, #names, 3)
  local out = ""
  for i, n in ipairs(names) do
    out = out .. (i > 1 and tight(g) .. "," .. gap(g) or "") .. n
  end
  if chance(g, 3) then
    out = out .. tight(g) .. ":" .. gap(g)
    for i = 1, #names do
      out = out .. (i > 1 and "," .. gap(g) or "") .. typ(g, i < #names)
    end
  end
  return out
end

--- A record's, an interface's or an enum's body, down to its `end`.
local function record_body(g: Gen, d: integer, is_enum: boolean): string
  local out: {string} = {}
  local n = 0
  while Fuzz.more(g.src, n, 4) do
    n = n + 1
    out[#out + 1] = entry_sep(g)
    if is_enum then
      local q = pick(g, { '"', "'" })
      out[#out + 1] = q .. pick(g, { "a", "b c", "-- d" }) .. n .. q
    else
      local k = g.src:int(1, 8)
      if k <= 3 then
        out[#out + 1] = pick(g, FIELDS) .. n .. ":" .. gap(g) .. typ(g)
      elseif k == 4 and d > 0 then
        out[#out + 1] = "record Inner" .. n .. generics(g) .. record_body(g, d - 1, false)
      elseif k == 5 then
        out[#out + 1] = "enum Kind" .. n .. record_body(g, 0, true)
      elseif k == 6 then
        out[#out + 1] = "type Alias" .. n .. " = " .. typ(g)
      elseif k == 7 and n == 1 then
        out[#out + 1] = "metamethod __call: function(R, integer): string"
      else
        out[#out + 1] = pick(g, FIELDS) .. n .. ": function(self, x: integer): " .. typ(g)
      end
    end
  end
  out[#out + 1] = entry_sep(g)
  return table.concat(out) .. "end"
end

--- A `type` declaration's name and what it binds, after its keyword.
local function type_declaration(g: Gen, d: integer, is_global: boolean): string
  local k = g.src:int(1, 9)
  if k == 1 then
    local implements = chance(g, 4) and " is I" or ""
    return "record R" .. generics(g) .. implements .. record_body(g, d, false)
  end
  if k == 2 then return "enum E" .. record_body(g, 0, true) end
  -- An interface holds no record.
  if k == 3 then return "interface I" .. record_body(g, 0, false) end
  if k == 4 then return "type T" .. gap(g) .. "=" .. gap(g) .. typ(g) end
  if k == 5 then return "type L<X> = {X}" end
  if k == 6 then return "type c" .. gap(g) .. "=" .. gap(g) .. 'require("cosmic.fs")' end
  if k == 7 then return "type T = record" .. record_body(g, d, false) end
  if k == 8 and is_global then return "type U" end
  return "type G = enum" .. record_body(g, 0, true)
end

--- One statement, not a `return`: those end a block.
local function statement(g: Gen, d: integer): string
  local k = g.src:int(1, 24)
  if k <= 2 then
    local out = "local" .. gap(g) .. declared(g)
    if chance(g, 4) then return out end
    return out .. gap(g) .. "=" .. gap(g) .. exprs(g, d, 3)
  end
  if k == 3 then
    local out = "global" .. gap(g) .. pick(g, NAMES)
    if chance(g, 2) then return out .. ":" .. gap(g) .. typ(g) end
    return out .. gap(g) .. "=" .. gap(g) .. expr(g, d)
  end
  if k == 4 and d > 0 then
    return "local" .. gap(g) .. "function" .. gap(g) .. pick(g, NAMES) .. body(g, d)
  end
  if k == 5 and d > 0 then
    local name = pick(g, { "f", "M.f", "M.go", "M:m", "M.a.b" })
    local lead = name:find("[.:]") == nil and pick(g, { "global function ", "function " }) or "function "
    return lead .. name .. body(g, d)
  end
  if k == 6 then return "local " .. type_declaration(g, d, false) end
  if k == 7 then return "global " .. type_declaration(g, d, true) end
  if k == 8 then
    return "local macroexp m(a: integer)" .. tight(g) .. ":" .. gap(g) .. "integer" ..
      gap(g) .. "return" .. gap(g) .. expr(g, d - 1) .. gap(g) .. "end"
  end
  if k == 9 then
    -- A pragma is a line of its own.
    return "\n" .. indent(g) .. "--#pragma" .. pick(g, { " arity on", " arity off", "   arity   on" }) ..
      "\n" .. indent(g) .. "print(1)"
  end
  if k == 10 and d > 0 then
    local out = "if" .. gap(g) .. expr(g, d - 1) .. gap(g) .. "then" .. block(g, d - 1)
    local n = 0
    while Fuzz.more(g.src, n, 2) do
      n = n + 1
      out = out .. "elseif" .. gap(g) .. expr(g, d - 1) .. gap(g) .. "then" .. block(g, d - 1)
    end
    if chance(g, 2) then out = out .. "else" .. block(g, d - 1) end
    return out .. "end"
  end
  local was_loop = g.loop
  if k == 11 and d > 0 then
    g.loop = true
    local out = "while" .. gap(g) .. expr(g, d - 1) .. gap(g) .. "do" .. block(g, d - 1) .. "end"
    g.loop = was_loop
    return out
  end
  if k == 12 and d > 0 then
    g.loop = true
    local out = "repeat" .. block(g, d - 1) .. "until" .. gap(g) .. expr(g, d - 1)
    g.loop = was_loop
    return out
  end
  if k == 13 and d > 0 then
    g.loop = true
    local step = chance(g, 2) and (tight(g) .. "," .. gap(g) .. expr(g, 0)) or ""
    local out = "for" .. gap(g) .. "i" .. gap(g) .. "=" .. gap(g) .. expr(g, d - 1) .. tight(g) .. "," ..
      gap(g) .. expr(g, d - 1) .. step .. gap(g) .. "do" .. block(g, d - 1) .. "end"
    g.loop = was_loop
    return out
  end
  if k == 14 and d > 0 then
    g.loop = true
    local out = "for" .. gap(g) .. "k" .. tight(g) .. "," .. gap(g) .. "v" .. gap(g) .. "in" .. gap(g) ..
      exprs(g, d - 1, 3) .. gap(g) .. "do" .. block(g, d - 1) .. "end"
    g.loop = was_loop
    return out
  end
  if k == 15 and d > 0 then return "do" .. block(g, d - 1) .. "end" end
  if k == 16 then return "goto" .. gap(g) .. "continue" .. sep(g) .. "::continue::" end
  if k == 17 then return "::" .. tight(g) .. "top" .. tight(g) .. "::" end
  if k == 18 and g.loop then return "break" end
  if k <= 20 then
    local targets: {string} = {}
    repeat
      local target, called = prefix(g, d)
      -- A call is no place to assign to.
      if called then target = target .. ".f" end
      targets[#targets + 1] = target
    until not Fuzz.more(g.src, #targets, 3)
    local out = table.concat(targets, tight(g) .. "," .. gap(g))
    return out .. gap(g) .. "=" .. gap(g) .. exprs(g, d, 3)
  end
  return call(g, d)
end

block = function(g: Gen, d: integer): string
  local out: {string} = {}
  local n = 0
  while Fuzz.more(g.src, n, d >= 2 and 6 or 3) do
    n = n + 1
    out[#out + 1] = sep(g) .. statement(g, d)
  end
  if chance(g, 4) then
    out[#out + 1] = sep(g) .. "return"
    if chance(g, 3) then out[#out + 1] = gap(g) .. exprs(g, d, 3) end
    if chance(g, 3) then out[#out + 1] = tight(g) .. ";" end
    out[#out + 1] = "\n" .. indent(g)
    return table.concat(out)
  end
  out[#out + 1] = sep(g)
  return table.concat(out)
end

--- A whole program: a block at the top level, a shebang line or not.
local function program(src: Fuzz.Source): string
  local g: Gen = { src = src, marks = 0, vararg = true, loop = false }
  local text = block(g, 3)
  if chance(g, 20) then text = "#!/usr/bin/env cosmic\n" .. text end
  return text
end

--- What [`build.fix.source`] makes of `input`: nil, and true, when the
--- input does not parse or is refused by name; nil, false and why when
--- it is refused for any other reason, which is a renderer's failure.
local function fixed(input: string): string, boolean, string
  local parsed, _ = ast.parse(built, input, "fuzz.tl")
  if parsed == nil then
    Fuzz.label("unparsed")
    return nil, true, ""
  end
  Fuzz.label("parsed")
  local result, trouble = fix.source(built, input, "fuzz.tl")
  if result == nil then
    if trouble:find("^this renderer has no spelling for ") ~= nil then
      Fuzz.label("refused")
      return nil, true, ""
    end
    return nil, false, "fix refused it: " .. trouble
  end
  Fuzz.label("rendered")
  if result.changed then Fuzz.label("changed") end
  return result.source, true, ""
end

local function writes_the_same_program(input: string): boolean, string
  local _, held, why = fixed(input)
  return held, why
end

--- Every `@n@` mark in `text`, counted.
local function marks(text: string): {string: integer}
  local out: {string: integer} = {}
  for m in text:gmatch("@%d+@") do out[m] = (out[m] or 0) + 1 end
  return out
end

local function keeps_every_comment(input: string): boolean, string
  local out, held, why = fixed(input)
  if out == nil then return held, why end
  local before, after = marks(input), marks(out)
  for m, count in pairs(before) do
    if after[m] ~= count then
      return false, ("the comment marked %s is in the input %d times and the output %d"):
        format(m, count, after[m] or 0)
    end
  end
  local parsed = assert(ast.parse(built, input, "fuzz.tl"))
  for _, text in ipairs(equiv.comments(parsed.tokens)) do
    if out:find(text, 1, true) == nil then return false, "lost the comment " .. text end
    Fuzz.label("commented")
  end
  return true, ""
end

--- The most inputs a run draws: on the checked core one input costs
--- about 0.1 s, so the nightly 10000 would take most of the 1200 s a
--- test is given, and of the hour the whole fuzz job has.
local MAX_ITERS <const> = 2000

local function test_fix_writes_the_same_program_or_refuses_by_name(tmp: string)
  Fuzz.run({
    name = "fix renders",
    dir = tmp,
    gen = program,
    check = writes_the_same_program,
    max_iters = MAX_ITERS,
    requires = { "parsed", "rendered", "changed" },
    shares = { parsed = 0.9, rendered = 0.9 },
  })
end

local function test_fix_keeps_every_comment(tmp: string)
  Fuzz.run({
    name = "fix keeps comments",
    dir = tmp,
    gen = program,
    check = keeps_every_comment,
    max_iters = MAX_ITERS,
    requires = { "parsed", "rendered", "commented" },
    shares = { parsed = 0.9, rendered = 0.9, commented = 0.5 },
  })
end
