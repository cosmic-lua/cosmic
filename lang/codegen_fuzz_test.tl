--- Fuzz properties for the code generator ([`lang.codegen`]). A Teal program drawn from the shapes of Lua's
--- statements and expressions, with a line break in the middle of an expression now and then, and the programs of
--- [`lang.scopes_programs`] translate ([`lang.translate`]) to a program that parses, and the generator writes it as the
--- Lua the fork writes for the Teal ([`build.compile`]'s `lua`), line for line, once the layout of a `continue`
--- is set aside. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).
local Codegen = require("lang.codegen")
local Forked = require("lang.forked")
local Fuzz = require("build.fuzz")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Programs = require("lang.scopes_programs")
local Scopes = require("lang.scopes")
local Test = require("cosmic.test")
local Translate = require("lang.translate")
local Truthy = require("lang.truthy")

Test.policy{ grants = { { path = "testdata/forked/codegen_fuzz.txt", letters = "r" } } }

--- What the fork wrote of each program the properties drew from `FUZZ_SEED=1`, recorded from the tool of main before the
--- switch ([`lang.forked`]): a draw of any other seed has no text of the fork's to be held to.
local record Held
  mut kept: {string: Forked.Said}?
end

local held: Held = { kept = nil }

local function forked(): {string: Forked.Said}
  local kept = held.kept
  if kept == nil then
    kept = Forked.load("testdata/forked/codegen_fuzz.txt")
    held.kept = kept
  end
  return kept
end

local NAMES <const>: {string} = { "a", "b", "c", "d", "t", "u", "f", "g" }
local TYPES <const>: {string} = { "string", "integer", "number", "boolean", "{string}", "{string: integer}", "any" }
local TESTS <const>: {string} = { "string", "integer", "number", "boolean", "nil", "thread", "{integer}", "R", "E" }
local BINARY <const>: {string} = {
  "or", "and", "<", ">", "<=", ">=", "~=", "==", "|", "~", "&", "<<", ">>", "..", "+", "-", "*", "/", "//", "%", "^",
}
local FIELDS <const>: {string} = { "x", "y", "len", "match", "end_", "name" }

local record Gen
  src: Fuzz.Source
  out: mut {string}
  --- For each loop being written, innermost last, whether its body ends with the label `continue` jumps to.
  labels: mut {boolean}
  --- Whether the draw may break a line before the token about to be written.
  breaks: boolean
  --- How many comparisons the expression being written is under: the fork writes `a < b is T` as `a < type(b) == "T"`,
  --- which is no test of `b`, and the generator parenthesizes it, so no test is drawn there.
  mut comparing: integer
end

--- A token written to the program. A line break may stand before it in place of the blank, except before a token a
--- break would change the meaning of: a `(` or `{` or a string begins a call, an argument or a statement, and
--- a test `is T` on a line of its own would have the fork break its Lua inside the quotes of the type.
local function add(g: Gen, ...: string)
  for i = 1, select("#", ...) do
    local token = (select(i, ...))
    local first = token:sub(1, 1)
    local sticky = first == "(" or first == "{" or first == "\"" or first == "[" or first == "'" or token == "\n" or
      token:sub(1, 3) == "is "
    if g.breaks and not sticky and #g.out > 0 and g.out[#g.out] ~= "\n" and g.src:int(1, 9) == 1 then
      g.out[#g.out + 1] = "\n"
    end
    g.out[#g.out + 1] = token
  end
end

local function pick(g: Gen, list: {string}): string
  return Fuzz.pick(g.src, list)
end

local gen_exp: function(g: Gen, depth: integer)
local gen_block: function(g: Gen, depth: integer, loop: boolean)
local gen_loop_body: function(g: Gen, depth: integer)

local function gen_list(g: Gen, depth: integer, max: integer)
  local n = 0
  while n == 0 or Fuzz.more(g.src, n, max) do
    if n > 0 then
      add(g, ",")
    end
    n = n + 1
    gen_exp(g, depth)
  end
end

local function gen_type(g: Gen)
  local t = pick(g, TYPES)
  if g.src:int(1, 4) == 1 then
    t = t .. "?"
  end
  add(g, t)
end

local function gen_params(g: Gen)
  add(g, "(")
  local n = g.src:int(0, 3)
  for i = 1, n do
    if i > 1 then
      add(g, ",")
    end
    add(g, NAMES[i])
    if g.src:int(1, 3) > 1 then
      add(g, ":")
      gen_type(g)
    end
  end
  add(g, ")")
  if g.src:int(1, 3) == 1 then
    add(g, ":")
    gen_type(g)
  end
end

local function gen_function(g: Gen, depth: integer)
  gen_params(g)
  add(g, "\n")
  gen_block(g, depth - 1, false)
  add(g, "end")
end

local function gen_table(g: Gen, depth: integer)
  add(g, "{")
  local n = 0
  while Fuzz.more(g.src, n, 4) do
    n = n + 1
    local form = g.src:int(1, 4)
    if form == 1 then
      add(g, pick(g, NAMES), "=")
    elseif form == 2 then
      add(g, "[")
      gen_exp(g, depth - 1)
      add(g, "]", "=")
    end
    gen_exp(g, depth - 1)
    if g.src:int(1, 4) > 1 or n < 4 then
      add(g, ",")
    end
  end
  add(g, "}")
end

--- A prefix expression: what a suffix may follow.
local function gen_prefix(g: Gen, depth: integer)
  local k = g.src:int(1, if depth > 0 then 7 else 2 end)
  if k <= 2 then
    add(g, pick(g, NAMES))
  elseif k == 3 then
    add(g, "(")
    gen_exp(g, depth - 1)
    add(g, ")")
  elseif k == 4 then
    gen_prefix(g, depth - 1)
    add(g, ".", pick(g, FIELDS))
  elseif k == 5 then
    gen_prefix(g, depth - 1)
    add(g, "[")
    gen_exp(g, depth - 1)
    add(g, "]")
  elseif k == 6 then
    gen_prefix(g, depth - 1)
    add(g, "(")
    if g.src:int(1, 3) > 1 then
      gen_list(g, depth - 1, 3)
    end
    add(g, ")")
  else
    gen_prefix(g, depth - 1)
    add(g, ":", pick(g, FIELDS), "(")
    if g.src:int(1, 3) > 1 then
      gen_list(g, depth - 1, 3)
    end
    add(g, ")")
  end
end

gen_exp = function(g: Gen, depth: integer)
  local k = g.src:int(1, if depth > 0 then 16 else 6 end)
  if k <= 3 then
    gen_prefix(g, depth)
  elseif k == 4 then
    add(g, pick(g, { "0", "7", "12", "0x1F", "3.5", ".5", "1e3", "1_000", "2." }))
  elseif k == 5 then
    add(g, pick(g, { "\"s\"", "'q'", "\"a\\n\\\"b\"", "[[long]]", "[==[a]]b]==]" }))
  elseif k == 6 then
    add(g, pick(g, { "nil", "true", "false" }))
  elseif k == 7 then
    local op = pick(g, BINARY)
    local comparison = op == "<" or op == ">" or op == "<=" or op == ">=" or op == "~=" or op == "=="
    g.comparing = g.comparing + (if comparison then 1 else 0 end)
    gen_exp(g, depth - 1)
    add(g, op)
    gen_exp(g, depth - 1)
    g.comparing = g.comparing - (if comparison then 1 else 0 end)
  elseif k == 8 then
    add(g, pick(g, { "not", "#", "~" }))
    gen_exp(g, depth - 1)
  elseif k == 9 then
    add(g, "function")
    gen_function(g, depth)
  elseif k == 10 then
    gen_table(g, depth)
  elseif k == 11 then
    gen_prefix(g, depth - 1)
    if g.comparing == 0 then
      add(g, "is " .. pick(g, TESTS))
    end
  elseif k == 12 then
    gen_prefix(g, depth - 1)
    add(g, "as")
    gen_type(g)
  elseif k == 13 then
    -- A ternary of a literal, which the translator writes as an `if` expression.
    gen_prefix(g, depth - 1)
    add(g, "and", pick(g, { "1", "\"s\"", "{}" }), "or")
    gen_exp(g, depth - 1)
  elseif k == 14 then
    add(g, "(")
    local op = pick(g, BINARY)
    local comparison = op == "<" or op == ">" or op == "<=" or op == ">=" or op == "~=" or op == "=="
    g.comparing = g.comparing + (if comparison then 1 else 0 end)
    gen_exp(g, depth - 1)
    add(g, op)
    gen_exp(g, depth - 1)
    g.comparing = g.comparing - (if comparison then 1 else 0 end)
    add(g, ")")
  elseif k == 15 then
    add(g, "-")
    gen_prefix(g, depth - 1)
  else
    gen_prefix(g, depth - 1)
    local op = pick(g, BINARY)
    local comparison = op == "<" or op == ">" or op == "<=" or op == ">=" or op == "~=" or op == "=="
    g.comparing = g.comparing + (if comparison then 1 else 0 end)
    add(g, op)
    gen_exp(g, depth - 1)
    g.comparing = g.comparing - (if comparison then 1 else 0 end)
  end
end

local function gen_statement(g: Gen, depth: integer, loop: boolean)
  local k = g.src:int(1, if depth > 0 then 16 else 5 end)
  if k == 1 then
    add(g, "local", pick(g, NAMES))
    if g.src:int(1, 3) == 1 then
      add(g, "<const>")
    end
    if g.src:int(1, 3) == 1 then
      add(g, ":")
      gen_type(g)
    end
    add(g, "=")
    gen_exp(g, depth)
  elseif k == 2 then
    add(g, "local", pick(g, NAMES), ",", pick(g, NAMES), "=")
    gen_list(g, depth, 3)
  elseif k == 3 then
    gen_prefix(g, 1)
    add(g, pick(g, { ".x", "[1]" }), "=")
    gen_exp(g, depth)
  elseif k == 4 then
    add(g, pick(g, NAMES), ",", pick(g, NAMES), "=")
    gen_list(g, depth, 3)
  elseif k == 5 then
    add(g, pick(g, NAMES), "(")
    gen_list(g, depth - 1, 3)
    add(g, ")")
  elseif k == 6 then
    add(g, "local", "function", pick(g, NAMES))
    gen_function(g, depth)
  elseif k == 7 then
    add(g, "function", "R", ".", pick(g, FIELDS))
    gen_function(g, depth)
  elseif k == 8 then
    add(g, "if")
    gen_exp(g, depth - 1)
    add(g, "then", "\n")
    gen_block(g, depth - 1, loop)
    while g.src:int(1, 3) == 1 do
      add(g, "elseif")
      gen_exp(g, depth - 1)
      add(g, "then", "\n")
      gen_block(g, depth - 1, loop)
    end
    if g.src:int(1, 2) == 1 then
      add(g, "else", "\n")
      gen_block(g, depth - 1, loop)
    end
    add(g, "end")
  elseif k == 9 then
    add(g, "while")
    gen_exp(g, depth - 1)
    add(g, "do", "\n")
    gen_loop_body(g, depth - 1)
    add(g, "end")
  elseif k == 10 then
    add(g, "for", pick(g, NAMES), "=")
    gen_exp(g, depth - 1)
    add(g, ",")
    gen_exp(g, depth - 1)
    if g.src:int(1, 3) == 1 then
      add(g, ",")
      gen_exp(g, depth - 1)
    end
    add(g, "do", "\n")
    gen_loop_body(g, depth - 1)
    add(g, "end")
  elseif k == 11 then
    add(g, "for", pick(g, NAMES), ",", pick(g, NAMES), "in")
    gen_list(g, depth - 1, 2)
    add(g, "do", "\n")
    gen_loop_body(g, depth - 1)
    add(g, "end")
  elseif k == 12 then
    add(g, "repeat", "\n")
    gen_loop_body(g, depth - 1)
    add(g, "until")
    gen_exp(g, depth - 1)
  elseif k == 13 then
    add(g, "do", "\n")
    gen_block(g, depth - 1, loop)
    add(g, "end")
  elseif k == 14 and loop then
    add(g, "break")
  elseif k == 15 and loop and g.labels[#g.labels] then
    add(g, "if")
    gen_exp(g, depth - 1)
    add(g, "then", "goto continue", "end")
  else
    add(g, "print", "(")
    gen_exp(g, depth - 1)
    add(g, ")")
  end
end

gen_block = function(g: Gen, depth: integer, loop: boolean)
  local n = 0
  while Fuzz.more(g.src, n, 4) do
    n = n + 1
    gen_statement(g, depth, loop)
    if g.src:int(1, 5) > 1 then
      add(g, "\n")
    end
  end
end

--- The body of a loop, which may end with the label `continue` jumps to.
gen_loop_body = function(g: Gen, depth: integer)
  g.labels[#g.labels + 1] = g.src:int(1, 3) == 1
  gen_block(g, depth, true)
  if table.remove(g.labels) then
    add(g, "\n", "::continue::", "\n")
  end
end

--- A Teal module: a record and an enum to name in tests, and some statements.
local function gen_module(src: Fuzz.Source): string
  local g: Gen = { src = src, out = {}, labels = {}, comparing = 0, breaks = src:int(0, 1) == 1 }
  add(g, "local record R", "\n", "x: integer", "\n", "end", "\n")
  add(g, "local enum E", "\n", "\"a\"", "\n", "end", "\n")
  gen_block(g, 2, false)
  return table.concat(g.out, " ")
end

--- A program of [`lang.scopes_programs`], which binds and uses names in every way Lua allows.
local function gen_program(src: Fuzz.Source): string
  return Programs.generate(function(min: integer, max: integer): integer
    return src:int(min, max)
  end, { unknown = true, loop_writes = false })
end

--- Asserts the generator writes the fork's Lua for `input`, or labels why it cannot be compared: where no text of the
--- fork's is kept (a draw of another seed) the generator is held not to refuse the program, and nothing more.
local function agrees(input: string): boolean, string
  local made = Translate.translate(input, "p.tl")
  if #made.errors > 0 then
    Fuzz.label("untranslated")
    return true, ""
  end
  local parsed = Parser.parse(Lexer.lex(made.text, "p.tl"), "p.tl", "tl")
  if #parsed.errors > 0 then
    Fuzz.label("unparsed")
    return true, ""
  end
  local said = Forked.said(forked(), input)
  if said.known and said.text == nil then
    Fuzz.label("refused by the fork")
    return true, ""
  end
  local ours = Codegen.generate(parsed.chunk, Scopes.build(parsed.chunk, "p.tl", {}), Truthy.never_false)
  if #ours.errors > 0 then
    return false, "the generator refused: " .. ours.errors[1].msg
  end
  local kept = said.text
  if kept == nil then
    Fuzz.label("not recorded")
    return true, ""
  end
  local lua = kept
  -- The programs are drawn without regard to what Lua refuses (an assignment to a constant), so the Lua must load
  -- where the fork's does.
  local loaded, why = load(ours.text, "=p", "t", {})
  if loaded == nil and load(lua, "=p", "t", {}) ~= nil then
    return false, "the generator wrote Lua that does not load: " .. tostring(why) .. "\n" .. ours.text
  end
  -- Where a test is on a later line than the start of the value it tests, the fork breaks the line inside the
  -- quotes of the type, which is no Lua; the generator keeps the break out of them.
  if lua:find("== \"\n", 1, true) then
    Fuzz.label("broken by the fork")
    return true, ""
  end
  Fuzz.label("compared")
  if Codegen.compared(ours.text) ~= Codegen.compared(lua) then
    return false, "the generator wrote\n" .. ours.text .. "\nthe fork wrote\n" .. lua .. "\nfrom the translation\n" .. made.text
  end
  return true, ""
end

local function test_a_drawn_program_is_written_as_the_fork_writes_it(tmp: string)
  Fuzz.run({
    name = "generate a drawn program",
    dir = tmp,
    gen = gen_module,
    check = agrees,
  })
end

local function test_a_program_that_binds_names_in_every_way_is_written_as_the_fork_writes_it(tmp: string)
  Fuzz.run({
    name = "generate a program of names",
    dir = tmp,
    gen = gen_program,
    check = agrees,
  })
end

--- The programs the properties draw from the default seed are the ones the file keeps the fork's text of, and most are
--- compared: a draw that changed (the generator of programs edited) would leave the file's entries unread.
local function test_the_programs_of_the_default_seed_are_the_ones_the_forks_text_is_kept_of()
  local compared, refused = 0, 0
  for source, said in pairs(forked()) do
    if said.text == nil then
      refused = refused + 1
    else
      local ok, why = agrees(source)
      assert(ok, why)
      compared = compared + 1
    end
  end
  assert(compared >= 60 and refused >= 1, tostring(compared) .. " compared, " .. tostring(refused) .. " refused by the fork")
end

-- programs that run -------------------------------------------------------------------------------------------------

--- Runs `lua`, the text of a program, and answers what it returns; nil and why where it does not load.
local function execute(lua: string): {any}?, string
  local env: {string: any} = { select = select, table = table, math = math, type = type }
  local chunk, why = load(lua, "=r", "t", env)
  if chunk == nil then
    return nil, "does not load: " .. tostring(why) .. "\n" .. lua
  end
  return { chunk() }, ""
end

--- Runs the generator's Lua for `source`, a program of the new grammar, and answers what it returns.
local function generated_run(source: string): {any}?, string
  local parsed = Parser.parse(Lexer.lex(source, "r.tl"), "r.tl", "tl")
  if #parsed.errors > 0 then
    return nil, "the program does not parse: " .. parsed.errors[1].msg .. "\n" .. source
  end
  local ours = Codegen.generate(parsed.chunk, Scopes.build(parsed.chunk, "r.tl", {}))
  if #ours.errors > 0 then
    return nil, "the generator refused: " .. ours.errors[1].msg
  end
  return execute(ours.text)
end

--- Whether two runs returned the same: values alike, tables by kind only.
local function alike(a: {any}, b: {any}): boolean
  for i = 1, math.max(#a, #b) do
    local x, y = a[i], b[i]
    if type(x) ~= type(y) or (type(x) ~= "table" and x ~= y) then
      return false
    end
  end
  return true
end

--- Asserts the program of the new grammar `new` returns what the plain Lua `reference` does.
local function same_run(new: string, reference: string): boolean, string
  local mine, why = generated_run(new)
  if mine == nil then
    return false, why
  end
  local theirs, their_why = execute(reference)
  if theirs == nil then
    return false, "the reference " .. their_why
  end
  if not alike(mine, theirs) then
    return false, "the program returned " .. #mine .. " values, the first " .. tostring(mine[1]) .. " and " .. tostring(mine[2]) ..
      ", where Lua gives " .. tostring(theirs[1]) .. " and " .. tostring(theirs[2]) .. "\n" .. new
  end
  Fuzz.label("ran")
  return true, ""
end

local VALUES <const>: {string} = { "side(false)", "side(nil)", "side(1)", "false", "nil", "1", "\"s\"", "{}", "1 + 2", "true", "x" }

--- The conditions and values of an `if` expression with some arms, one to a line, the `else` value last.
local function gen_ifs(src: Fuzz.Source): string
  local parts: mut {string} = {}
  for _ = 1, src:int(1, 3) do
    parts[#parts + 1] = Fuzz.pick(src, VALUES)
    parts[#parts + 1] = Fuzz.pick(src, VALUES)
  end
  parts[#parts + 1] = Fuzz.pick(src, VALUES)
  return table.concat(parts, "\n")
end

--- An `if` expression runs as the `if` statement it stands for, whatever its values: which are given, which are not
--- evaluated, and a false or nil value is the result.
local function runs_like_an_if_statement(input: string): boolean, string
  local parts: mut {string} = {}
  for part in (input .. "\n"):gmatch("(.-)\n") do
    parts[#parts + 1] = part
  end
  local arms: mut {string} = {}
  local statement: mut {string} = {}
  for i = 1, #parts - 1, 2 do
    arms[#arms + 1] = (if i == 1 then "if " else "elseif " end) .. parts[i] .. " then " .. parts[i + 1]
    statement[#statement + 1] = (if i == 1 then "if " else "elseif " end) .. parts[i] .. " then return (" .. parts[i + 1] .. ")"
  end
  local last = parts[#parts]
  local new = "local n = 0\nlocal x = 5\nlocal function side(v: any): any\n  n = n + 1\n  return v\nend\n" ..
    "local r = " .. table.concat(arms, " ") .. " else " .. last .. " end\nreturn r, n\n"
  local reference = "local n = 0\nlocal x = 5\nlocal function side(v) n = n + 1 return v end\n" ..
    "local r = (function() " .. table.concat(statement, " ") .. " else return (" .. last .. ") end end)()\nreturn r, n\n"
  return same_run(new, reference)
end

local function test_an_if_expression_runs_as_the_if_statement_it_stands_for(tmp: string)
  Fuzz.run({
    name = "run an if expression",
    dir = tmp,
    gen = gen_ifs,
    check = runs_like_an_if_statement,
    requires = { "ran" },
  })
end

--- The variant of a loop with a `continue`, its size, the number it skips at, whether its body ends in a `return` and
--- whether it holds a loop with a `continue` of its own.
local function gen_loop(src: Fuzz.Source): string
  return Fuzz.pick(src, { "for", "while", "repeat" }) .. " " .. src:int(1, 8) .. " " .. src:int(1, 4) .. " " ..
    src:int(0, 1) .. " " .. src:int(0, 1)
end

--- A loop whose pass `continue`s, and may end in a `return`, runs as the loop written with the plain Lua `goto`.
local function runs_like_a_goto(input: string): boolean, string
  local variant, n, m, ends, nested = input:match("^(%a+) (%d+) (%d+) (%d) (%d)$")
  if variant == nil then
    return true, ""
  end
  local last = if ends == "1" then "    return acc\n" else "" end
  local opening: string
  local closing: string
  local step = ""
  if variant == "for" then
    opening, closing = "  for i = 1, " .. n .. " do\n", "  end\n"
  elseif variant == "while" then
    opening, closing, step = "  local i = 0\n  while i < " .. n .. " do\n", "  end\n", "    i = i + 1\n"
  else
    opening, closing, step = "  local i = 0\n  repeat\n", "  until i >= " .. n .. "\n", "    i = i + 1\n"
  end
  -- A loop inside, which also `continue`s, so that each label is its own.
  local inner = if nested == "1" then "    for j = 1, 2 do\n      if j == 1 then continue end\n      acc = acc + 100\n    end\n" else "" end
  local inner_plain = if nested == "1" then "    for j = 1, 2 do\n      if j == 1 then goto continue end\n      acc = acc + 100\n      ::continue::\n    end\n" else "" end
  local function body(skip: string, label: string, tail: string, nest: string): string
    return "local function f(): integer\n  local acc = 0\n" .. opening .. step .. nest ..
      "    if i % " .. m .. " == 0 then " .. skip .. " end\n    acc = acc + i\n" .. tail .. label .. closing ..
      "  return acc\nend\nreturn f()\n"
  end
  local plain = body("goto continue", "    ::continue::\n", if ends == "1" then "    do return acc end\n" else "" end, inner_plain)
  return same_run(body("continue", "", last, inner), (plain:gsub("%(%): integer", "()")))
end

local function test_a_loop_with_a_continue_runs_as_the_loop_with_a_goto(tmp: string)
  Fuzz.run({
    name = "run a loop with a continue",
    dir = tmp,
    gen = gen_loop,
    check = runs_like_a_goto,
    requires = { "ran" },
  })
end

--- A `match` over the arms drawn: `T` and `F` for an arm of `true` and one of `false`, then perhaps `C`.
local function gen_match(src: Fuzz.Source): string
  local arms: mut {string} = {}
  local seen: mut {string: boolean} = {}
  while Fuzz.more(src, #arms, 2) do
    local arm = Fuzz.pick(src, { "T", "F" })
    if not seen[arm] then
      seen[arm] = true
      arms[#arms + 1] = arm
    end
  end
  if src:int(0, 1) == 1 then
    arms[#arms + 1] = "C"
  end
  if #arms == 0 then
    arms[1] = "C"
  end
  return table.concat(arms)
end

local function runs_like_an_if_on_the_flag(input: string): boolean, string
  local lines: mut {string} = {}
  local has: mut {string: boolean} = {}
  for arm in input:gmatch(".") do
    has[arm] = true
    if arm == "T" then
      lines[#lines + 1] = "  | (true, x) then return \"t\" .. x"
    elseif arm == "F" then
      lines[#lines + 1] = "  | (false, x) then return \"f\" .. x"
    else
      lines[#lines + 1] = "  | (x, y) then return \"c\" .. y"
    end
  end
  local new = "local function f(ok: boolean, v: any): boolean, any return ok, v end\n" ..
    "local function g(ok: boolean): string\n  match f(ok, \"v\") do\n" .. table.concat(lines, "\n") ..
    "\n  end\n  return \"none\"\nend\nreturn g(true), g(false)\n"
  local function expect(flag: string): string
    if has[flag] then
      return flag:lower() .. "v"
    elseif has["C"] then
      return "cv"
    end
    return "none"
  end
  local mine, why = generated_run(new)
  if mine == nil then
    return false, why
  end
  if mine[1] ~= expect("T") or mine[2] ~= expect("F") then
    return false, "the match gave " .. tostring(mine[1]) .. " and " .. tostring(mine[2]) .. "\n" .. new
  end
  Fuzz.label("ran")
  return true, ""
end

local function test_a_match_runs_the_arm_that_matches(tmp: string)
  Fuzz.run({
    name = "run a match",
    dir = tmp,
    gen = gen_match,
    check = runs_like_an_if_on_the_flag,
    requires = { "ran" },
  })
end
