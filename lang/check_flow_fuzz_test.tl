--- The soundness property of the flow of [`lang.check`], over the programs of [`build.checker_programs`] that the fork's
--- narrowing fuzz test draws (locals and record fields of `integer | nil`, `if`/`elseif`/`else` on nil tests, `and`/`or`,
--- the four loops with `break` and `continue`, function literals, early exits): the fork's text is put in the new
--- grammar ([`lang.translate`]) and checked; a program the checker takes is written as Lua and run with every read of a
--- narrowed place checked ([`Programs.execute`]), and must run to its end, or to an `assert` that failed, with no
--- `fact violated` and no nil operand. A program the checker refuses is not run: most of the draws are refused, for
--- the narrowing of a field the new grammar declares `mut` is not one. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs
--- (build/fuzz/init.tl).
local Fuzz = require("build.fuzz")
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")
local Translate = require("lang.translate")
local drawn = require("build.checker_programs")

Test.policy{}

--- The last declaration of the header every drawn program starts with.
local HEADER_END <const> = "local function id(v: integer | nil): integer | nil\n  return v\nend\n"

--- The drawn program as the new grammar takes it: the labels `continue`, an array of integers, every field of a record
--- literal given, and the body in a function so that its `return`s are a function's. Nil where the program has not the
--- header (a draw of the totality property).
local function adapted(source: string): string | nil
  local text = source:gsub("local opts: {integer | nil}", "local opts: {integer}"):gsub("next%d+", "continue")
  text = text:gsub("local r: R = { a = 1, n = 0 }", "local r: R = { a = 1, b = nil, n = 0 }")
  text = text:gsub("local s: R = { b = 2, n = 0 }", "local s: R = { a = nil, b = 2, n = 0 }")
  local _, stop = text:find(HEADER_END, 1, true)
  if stop == nil then
    return nil
  end
  return text:sub(1, stop) .. "local function main(): integer\n" .. text:sub(stop + 1) .. "end\nlocal _ = main()\n"
end

--- Constructs of a program that ran.
local CONSTRUCTS <const>: {{string}} = {
  { "while", "while " },
  { "repeat", "repeat" },
  { "numeric for", "for %w+ = " },
  { "break", "break" },
  { "continue", "continue" },
  { "assert", "assert%(" },
  { "function literal", "local function [pfg]%d" },
  { "early exit", "then return st.sink end" },
  { "elseif", "elseif " },
}

local function check_program(input: string): boolean, string
  local text = adapted(input)
  if text == nil then
    return true, ""
  end
  local source = Translate.translate(text, "fuzz.tl").text
  local x = Programs.execute(source, true)
  if not x.ran then
    Fuzz.label(#x.run.before > 0 and "not a program" or "refused")
    return true, ""
  end
  Fuzz.label("accepted")
  if #x.run.result.narrowed > 0 then
    Fuzz.label("narrowed read")
  end
  local fault = x.fault
  if fault == nil then
    Fuzz.label("ran")
    for _, c in ipairs(CONSTRUCTS) do
      for i = 2, #c do
        if source:find(c[i]) then
          Fuzz.label("ran with " .. c[1])
          break
        end
      end
    end
    return true, ""
  elseif fault:find("assertion failed", 1, true) then
    Fuzz.label("stopped by assert")
    return true, ""
  end
  return false, "the checker took a program that fails at run time: " .. fault .. "\n--- program ---\n" .. source ..
    "\n--- lua ---\n" .. x.lua
end

local function test_a_program_the_flow_takes_does_not_fail_at_a_narrowed_read(tmp: string)
  Fuzz.run({
    name = "flow sound",
    dir = tmp,
    -- Half the default: a draw is a program of the fork's generator, put in the new grammar, checked and run.
    iters = 32,
    gen = drawn.well_formed,
    check = check_program,
    requires = { "accepted", "ran", "refused" },
    shares = { accepted = 0.05 },
  })
end

-- programs of the new grammar --------------------------------------------------------------------------------------

--- What a statement being drawn can name: the locals of type `integer?` in scope, and those a guard around the point (or a
--- test that ended the block) says are not nil, a bias towards the reads the checker must decide, not a claim that they are
--- accepted.
local record Scope
  vars: {string}
  focus: {string}
end

local record Gen
  src: Fuzz.Source
  lines: {string}
  id: integer
  fuel: integer
  depth: integer
  --- Whether a `break` and a `continue` leave a loop of the function being drawn.
  in_loop: boolean
end

local function copy(list: {string}): {string}
  local out: {string} = {}
  for i, s in ipairs(list) do
    out[i] = s
  end
  return out
end

local function has(list: {string}, name: string): boolean
  for _, s in ipairs(list) do
    if s == name then
      return true
    end
  end
  return false
end

local function nested(scope: Scope): Scope
  return { vars = copy(scope.vars), focus = copy(scope.focus) }
end

local function add(g: Gen, text: string)
  g.lines[#g.lines + 1] = ("  "):rep(g.depth + 1) .. text
  g.fuel = g.fuel - 1
end

local function fresh(g: Gen, prefix: string): string
  g.id = g.id + 1
  return prefix .. g.id
end

--- A local of `scope`, biased to those a guard names.
local function var_of(g: Gen, scope: Scope): string
  if #scope.focus > 0 and g.src:int(0, 2) > 0 then
    return Fuzz.pick(g.src, scope.focus)
  end
  return Fuzz.pick(g.src, scope.vars)
end

--- A local to test: one no guard names, so that a test is not a dead one, which is refused.
local function tested(g: Gen, scope: Scope): string
  local open: {string} = {}
  for _, v in ipairs(scope.vars) do
    if not has(scope.focus, v) then
      open[#open + 1] = v
    end
  end
  if #open > 0 and g.src:int(0, 4) > 0 then
    return Fuzz.pick(g.src, open)
  end
  return Fuzz.pick(g.src, scope.vars)
end

--- An `integer` that reads a local: bare where a guard names it, else mostly given a default.
local function operand(g: Gen, scope: Scope): string
  local v = var_of(g, scope)
  if has(scope.focus, v) or g.src:int(0, 3) == 0 then
    return v
  end
  return "(" .. v .. " or 0)"
end

--- A test of up to `depth` levels: its text, and the locals it says are not nil when it holds. A bare local is a test
--- only at the top, since `and` and `or` of an optional and a boolean are refused; `avoid` are the locals the test it
--- is part of has tested.
local function cond(g: Gen, scope: Scope, depth: integer, avoid: {string}, top: boolean): string, {string}
  local k = depth <= 0 and 0 or g.src:int(0, 6)
  if k <= 3 then
    local v = tested(g, scope)
    for _ = 1, 3 do
      if has(avoid, v) then
        v = tested(g, scope)
      end
    end
    avoid[#avoid + 1] = v
    local form = g.src:int(0, top and 5 or 3)
    if form <= 1 then
      return v .. " ~= nil", { v }
    elseif form == 2 then
      return v .. " == nil", {}
    elseif form == 3 then
      return "st.count % 2 == 0", {}
    elseif form == 4 then
      return v, { v }
    end
    return "not " .. v, {}
  elseif k == 4 then
    local a, ya = cond(g, scope, depth - 1, avoid, false)
    local b, yb = cond(g, scope, depth - 1, avoid, false)
    local yes = copy(ya)
    for _, v in ipairs(yb) do
      yes[#yes + 1] = v
    end
    return a .. " and " .. b, yes
  elseif k == 5 then
    local a = cond(g, scope, depth - 1, avoid, false)
    local b = cond(g, scope, depth - 1, avoid, false)
    return a .. " or " .. b, {}
  end
  local a = cond(g, scope, depth - 1, avoid, false)
  return "not (" .. a .. ")", {}
end

local gen_block: function(g: Gen, scope: Scope, n: integer)

--- Draws `n` statements in the scope `scope`, which the statements add to.
local function gen_statement(g: Gen, scope: Scope)
  local k = g.src:int(0, g.depth >= 3 and 7 or 13)
  if k <= 1 then
    local name = fresh(g, "v")
    local init = Fuzz.pick(g.src, { "maybe()", "maybe()", "nil", scope.vars[1] })
    add(g, "local " .. name .. ": integer? = " .. init)
    scope.vars[#scope.vars + 1] = name
  elseif k == 2 then
    do
      local v = Fuzz.pick(g.src, scope.vars)
      add(g, v .. " = " .. Fuzz.pick(g.src, { "maybe()", "nil", "1" }))
      local kept: {string} = {}
      for _, f in ipairs(scope.focus) do
        if f ~= v then
          kept[#kept + 1] = f
        end
      end
      scope.focus = kept
    end
  elseif k <= 4 then
    add(g, "total = total + " .. operand(g, scope))
  elseif k == 5 then
    local c = cond(g, scope, 2, {}, true)
    add(g, "assert(" .. c .. ")")
  elseif k == 6 then
    local c, yes = cond(g, scope, 2, {}, true)
    add(g, "if " .. c .. " then")
    local inner = nested(scope)
    for _, v in ipairs(yes) do
      inner.focus[#inner.focus + 1] = v
    end
    g.depth = g.depth + 1
    gen_block(g, inner, g.src:int(1, 3))
    g.depth = g.depth - 1
    if g.src:int(0, 2) == 0 then
      add(g, "else")
      g.depth = g.depth + 1
      gen_block(g, nested(scope), g.src:int(1, 2))
      g.depth = g.depth - 1
    end
    add(g, "end")
  elseif k == 7 then
    -- A test that ends the block: what follows reads the local as the test left it.
    local v = tested(g, scope)
    local exit = "return total"
    if g.in_loop then
      exit = Fuzz.pick(g.src, { "return total", "break", "continue" })
    end
    add(g, "if " .. v .. " == nil then " .. exit .. " end")
    scope.focus[#scope.focus + 1] = v
  elseif k == 8 then
    local c, yes = cond(g, scope, 2, {}, true)
    add(g, "if " .. c .. " then")
    local inner = nested(scope)
    for _, v in ipairs(yes) do
      inner.focus[#inner.focus + 1] = v
    end
    g.depth = g.depth + 1
    gen_block(g, inner, g.src:int(1, 2))
    g.depth = g.depth - 1
    add(g, "elseif " .. cond(g, scope, 1, {}, true) .. " then")
    g.depth = g.depth + 1
    gen_block(g, nested(scope), 1)
    g.depth = g.depth - 1
    add(g, "end")
  elseif k <= 10 then
    local counter = fresh(g, "c")
    local kind = g.src:int(0, 2)
    local saved = g.in_loop
    g.in_loop = true
    if kind == 0 then
      add(g, "local " .. counter .. " = 0")
      add(g, "while " .. counter .. " < 3 do")
      g.depth = g.depth + 1
      add(g, counter .. " = " .. counter .. " + 1")
    elseif kind == 1 then
      add(g, "for " .. counter .. " = 1, 3 do")
      g.depth = g.depth + 1
    else
      add(g, "local " .. counter .. " = 0")
      add(g, "repeat")
      g.depth = g.depth + 1
      add(g, counter .. " = " .. counter .. " + 1")
    end
    gen_block(g, nested(scope), g.src:int(1, 4))
    g.depth = g.depth - 1
    g.in_loop = saved
    add(g, kind == 2 and "until " .. counter .. " >= 2" or "end")
  elseif k == 11 then
    local f = fresh(g, "f")
    local body = operand(g, scope)
    add(g, "local " .. f .. " = function(): integer")
    add(g, "  return " .. body)
    add(g, "end")
    add(g, "total = total + " .. f .. "()")
  elseif k == 12 then
    local name = fresh(g, "v")
    local v = var_of(g, scope)
    add(g, "local " .. name .. ": integer? = " .. v)
    scope.vars[#scope.vars + 1] = name
  else
    local name = fresh(g, "k")
    add(g, "local " .. name .. " <const> = maybe()")
    scope.vars[#scope.vars + 1] = name
  end
end

gen_block = function(g: Gen, scope: Scope, n: integer)
  for _ = 1, n do
    if g.fuel > 0 then
      gen_statement(g, scope)
    end
  end
end

--- A program of the new grammar over locals of type `integer?`: tests, assignments, loops, closures and exits.
local function gen_locals(src: Fuzz.Source): string
  local g: Gen = { src = src, lines = {}, id = 0, fuel = 40, depth = 0, in_loop = false }
  local scope: Scope = { vars = { "a", "b" }, focus = {} }
  gen_block(g, scope, src:int(4, 12))
  return table.concat({
    "local record State",
    "  mut count: integer",
    "end",
    "local st: State = { count = " .. src:int(0, 5) .. " }",
    "local function maybe(): integer?",
    "  st.count = st.count + 1",
    "  if st.count % 3 == 0 then",
    "    return nil",
    "  end",
    "  return st.count",
    "end",
    "local function main(): integer",
    "  local total = 0",
    "  local a: integer? = maybe()",
    "  local b: integer? = maybe()",
    table.concat(g.lines, "\n"),
    "  return total",
    "end",
    "print(main())",
    "",
  }, "\n")
end

local LOCAL_CONSTRUCTS <const>: {{string}} = {
  { "while", "while " },
  { "repeat", "repeat\n" },
  { "for", "for c%d+ = " },
  { "break", "break" },
  { "continue", "continue" },
  { "assert", "assert%(" },
  { "function literal", "= function%(%)" },
  { "elseif", "elseif " },
  { "early exit", "== nil then return" },
  { "const", "<const>" },
  { "copy", "local v%d+: integer%? = [abv]%d*\n" },
}

local function check_locals(source: string): boolean, string
  local x = Programs.execute(source, true)
  if not x.ran then
    local first = x.run.errors[1]
    Fuzz.label(#x.run.before > 0 and "not a program" or "refused")
    if first ~= nil then
      Fuzz.label("refused for " .. first.code)
    end
    return true, ""
  end
  Fuzz.label("accepted")
  if #x.run.result.narrowed > 0 then
    Fuzz.label("narrowed read")
  end
  local fault = x.fault
  if fault == nil or fault:find("assertion failed", 1, true) then
    Fuzz.label(fault == nil and "ran" or "stopped by assert")
    for _, c in ipairs(LOCAL_CONSTRUCTS) do
      if source:find(c[2]) then
        Fuzz.label("ran with " .. c[1])
      end
    end
    return true, ""
  end
  return false, "the checker took a program that fails at run time: " .. fault .. "\n--- program ---\n" .. source ..
    "\n--- lua ---\n" .. x.lua
end

local function test_a_program_over_locals_the_flow_takes_does_not_fail_at_a_narrowed_read(tmp: string)
  Fuzz.run({
    name = "flow sound locals",
    dir = tmp,
    gen = gen_locals,
    check = check_locals,
    requires = { "accepted", "ran", "refused", "narrowed read", "ran with while", "ran with for", "ran with repeat",
      "ran with break", "ran with continue", "ran with assert", "ran with function literal", "ran with elseif",
      "ran with early exit", "ran with const", "ran with copy" },
    shares = { accepted = 0.1, ["narrowed read"] = 0.1 },
  })
end

-- programs of shapes over enums, classes, tags, tables and closures -----------------------------------------------------

--- What every shaped program starts with: sources of values that vary with a counter, an enum, two classes, two tagged
--- records, a function that makes a narrowing declaration, and `paint`, which takes only a member of the enum.
local SHAPES_HEAD <const> = [[
local enum Color "red" "green" end
local record Counter
  mut n: integer
end
local st: Counter = { n = 0 }
local function tick(): integer
  st.n = st.n + 1
  return st.n
end
local function pick_str(): string
  local i = tick() % 4
  if i == 0 then
    return "red"
  elseif i == 1 then
    return "purple"
  elseif i == 2 then
    return "green"
  end
  return "x"
end
local function pick_opt(): string?
  local i = tick() % 3
  if i == 0 then
    return nil
  elseif i == 1 then
    return "red"
  end
  return "purple"
end
local function maybe(): integer?
  if tick() % 3 == 0 then
    return nil
  end
  return st.n
end
local function paint(c: Color): string
  return c
end
local class A
  a: integer
end
local class B
  b: integer
end
local function pick_u(): A | B | integer?
  local i = tick() % 4
  if i == 0 then
    local made: A = { a = 3 }
    return made
  elseif i == 1 then
    local made: B = { b = 5 }
    return made
  elseif i == 2 then
    return 9
  end
  return nil
end
local enum AK "a" end
local enum BK "b" end
local record TA
  kind: AK
  n: integer
end
local record TB
  kind: BK
  s: string
end
local function pick_t(): TA | TB
  if tick() % 2 == 0 then
    return { kind = "a", n = 3 }
  end
  return { kind = "b", s = "xy" }
end
]]

--- The types a parameter that is tested for an enum may have, and the arguments that fit one.
local ENUM_PARAMS <const>: {{string}} = {
  { "string", "\"red\"", "\"purple\"", "pick_str()" }, { "string?", "nil", "\"red\"", "\"purple\"", "pick_opt()" },
  { "any", "\"red\"", "7", "\"purple\"", "{ 1, 2 }", "true", "nil" },
  { "string | integer", "\"green\"", "\"nope\"", "4" }, { "Color | integer", "\"green\"", "3" }, { "Color?", "\"red\"", "nil" },
}

--- An argument for the parameter type `param` of [`ENUM_PARAMS`].
local function argument(g: Gen, param: {string}): string
  return param[g.src:int(2, #param)]
end

--- A shape: a function with a test and a call that runs it, drawn over the sources of [`SHAPES_HEAD`].
local function gen_shape(g: Gen)
  local k = g.src:int(0, 9)
  local n = fresh(g, "f")
  local test = Fuzz.pick(g.src, { "is", "type" })
  local line = function(text: string)
    g.lines[#g.lines + 1] = text
  end
  if k <= 1 then
    local param = Fuzz.pick(g.src, ENUM_PARAMS)
    line("local function " .. n .. "(v: " .. param[1] .. "): string")
    if test == "is" or param[1] == "Color | integer" or param[1] == "Color?" then
      line("  if v is Color then")
      line("    return paint(v)")
      line("  end")
    else
      line("  if type(v) == \"string\" then")
      line("    return v")
      line("  end")
    end
    line("  return \"other\"")
    line("end")
    line("print(" .. n .. "(" .. argument(g, param) .. "), " .. n .. "(" .. argument(g, param) .. "), " .. n .. "(" ..
        argument(g, param) .. "))")
  elseif k == 2 then
    local param = Fuzz.pick(g.src, { "A | B | integer?", "any" })
    line("local function " .. n .. "(v: " .. param .. "): integer")
    line("  if v is A then")
    line("    return v.a")
    line("  elseif v is B then")
    line("    return v.b")
    line("  end")
    line("  return 0")
    line("end")
    line("print(" .. n .. "(pick_u()), " .. n .. "(pick_u()), " .. n .. "(pick_u()))")
  elseif k == 3 then
    line("local function " .. n .. "(v: TA | TB): integer")
    if g.src:int(0, 1) == 0 then
      line("  if v.kind == \"a\" then")
      line("    return v.n")
      line("  end")
      line("  return #v.s")
    else
      line("  if v.kind ~= \"a\" then")
      line("    return #v.s")
      line("  end")
      line("  return v.n")
    end
    line("end")
    line("print(" .. n .. "(pick_t()), " .. n .. "(pick_t()))")
  elseif k == 4 then
    line("local function " .. n .. "(v: any): integer")
    line("  if v is table then")
    line("    return 1")
    line("  elseif type(v) == \"string\" then")
    line("    return #v")
    line("  end")
    line("  return 0")
    line("end")
    local values: {string} = { "\"red\"", "7", "\"purple\"", "{ 1, 2 }", "true", "nil", "\"\"" }
    line("print(" .. n .. "(" .. Fuzz.pick(g.src, values) .. "), " .. n .. "(" .. Fuzz.pick(g.src, values) .. "), " .. n .. "(" ..
        Fuzz.pick(g.src, values) .. "))")
  elseif k <= 6 then
    -- A closure tests a captured local; the local is assigned after the closure is made, or not.
    local after = Fuzz.pick(g.src, { "", "x = maybe()", "x = nil" })
    line("local function " .. n .. "(): integer")
    line("  local x: integer? = maybe()")
    line("  local g = function(): integer")
    line("    if x ~= nil then")
    line("      return x")
    line("    end")
    line("    return 0")
    line("  end")
    if after ~= "" then
      line("  " .. after)
    end
    line("  return g()")
    line("end")
    line("print(" .. n .. "(), " .. n .. "())")
  elseif k == 7 then
    -- A function that is suspended between a test and a read of a captured local the code around then assigns.
    local after = Fuzz.pick(g.src, { "", "x = maybe()", "x = nil" })
    line("local function " .. n .. "()")
    line("  local x: integer? = maybe()")
    line("  local step = coroutine.wrap(function(y: Yielder<nil, nil>)")
    line("    if x ~= nil then")
    line("      y:yield(nil)")
    line("      print(x + 1)")
    line("    else")
    line("      y:yield(nil)")
    line("    end")
    line("  end)")
    line("  step()")
    if after ~= "" then
      line("  " .. after)
    end
    line("  step()")
    line("end")
    line(n .. "()")
    line(n .. "()")
  elseif k == 8 then
    -- The value given to a local, and a test that follows or does not.
    line("local function " .. n .. "(): integer")
    line("  local o: string? = " .. Fuzz.pick(g.src, { "pick_opt()", "nil", "\"k\"" }))
    for _ = 1, g.src:int(1, 3) do
      local step = g.src:int(0, 3)
      if step == 0 then
        line("  if o == nil then")
        line("    o = " .. Fuzz.pick(g.src, { "\"d\"", "pick_str()", "pick_opt()" }))
        line("  end")
      elseif step == 1 then
        line("  o = " .. Fuzz.pick(g.src, { "pick_opt()", "\"z\"", "nil" }))
      elseif step == 2 then
        line("  if o ~= nil then")
        line("    print(#o)")
        line("  end")
      else
        line("  o = o or \"e\"")
      end
    end
    line("  return #o")
    line("end")
    line("print(" .. n .. "())")
  else
    -- A narrowing declaration, and a body that may assign the parameter it narrows.
    local body = Fuzz.pick(g.src, { "", "  v = \"x\"" })
    line("local function " .. n .. "(v: string?): v is string")
    if body ~= "" then
      line(body)
    end
    line("  return v ~= nil")
    line("end")
    line("local function " .. n .. "_use(): integer")
    line("  local o: string? = pick_opt()")
    line("  if " .. n .. "(o) then")
    line("    return #o")
    line("  end")
    line("  return 0")
    line("end")
    line("print(" .. n .. "_use(), " .. n .. "_use())")
  end
end

--- A program of [`SHAPES_HEAD`] and some shapes.
local function gen_shapes(src: Fuzz.Source): string
  local g: Gen = { src = src, lines = {}, id = 0, fuel = 0, depth = 0, in_loop = false }
  for _ = 1, src:int(2, 5) do
    gen_shape(g)
  end
  return SHAPES_HEAD .. table.concat(g.lines, "\n") .. "\n"
end

local SHAPE_CONSTRUCTS <const>: {{string}} = {
  { "enum", "is Color" }, { "type test", "type%(v%) == " }, { "class", "v is A" }, { "tag", "v.kind" }, { "table", "is table" },
  { "closure", "local g = function" }, { "coroutine", "coroutine.wrap" }, { "assignment", "o = " }, { "declaration", "v is string" },
  { "assignment after closure", "  x = " },
}

local function check_shapes(source: string): boolean, string
  local x = Programs.execute(source, true)
  if not x.ran then
    local first = x.run.errors[1]
    Fuzz.label(#x.run.before > 0 and "not a program" or "refused")
    if first ~= nil then
      Fuzz.label("refused for " .. first.code)
    end
    return true, ""
  end
  Fuzz.label("accepted")
  if #x.run.result.narrowed > 0 then
    Fuzz.label("narrowed read")
  end
  local fault = x.fault
  if fault == nil then
    Fuzz.label("ran")
    for _, c in ipairs(SHAPE_CONSTRUCTS) do
      if source:find(c[2]) then
        Fuzz.label("ran with " .. c[1])
      end
    end
    return true, ""
  end
  return false, "the checker took a program that fails at run time: " .. fault .. "\n--- program ---\n" .. source ..
    "\n--- lua ---\n" .. x.lua
end

local function test_a_program_of_enum_class_tag_and_closure_shapes_the_flow_takes_does_not_fail_at_a_narrowed_read(tmp: string)
  Fuzz.run({
    name = "flow sound shapes",
    dir = tmp,
    gen = gen_shapes,
    check = check_shapes,
    requires = { "accepted", "ran", "refused", "narrowed read", "ran with enum", "ran with class", "ran with tag", "ran with table",
      "ran with closure", "ran with coroutine", "ran with assignment", "ran with declaration" },
    shares = { accepted = 0.1, ["narrowed read"] = 0.1 },
  })
end
