--- Fuzz properties for the checker ([`lang.check`]). A program drawn from a typed generator (every expression is built to
--- be of the type its place wants, from the operators, literals, calls and writes the checker types) checks clean.
--- The same program with one mistake put in it, a value of a type its place does not take or a use the rules refuse,
--- is refused. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).
local Fuzz = require("build.fuzz")
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")

Test.policy{}

--- A variable in scope, or a function that can be called.
local record Var
  name: string
  type: string
  --- For a function, the types of its parameters.
  params?: {string}
  --- Whether it is a loop variable, which a program does not assign.
  readonly?: boolean
end

local record Gen
  src: Fuzz.Source
  --- The statements written, one per line.
  lines: mut {string}
  vars: mut {Var}
  mut count: integer
  --- The lines that are `local v: T = e` statements: the line and the type, to put a wrong value in.
  inits: mut {{string | integer}}
end

local PRELUDE <const> = [[
local enum Color "red" "green" end
local record Point
  x: number
  y: number
  color: Color
  mut tag?: string
end
local i0: integer = 1
local n0: number = 1.5
local s0: string = "s"
local b0: boolean = true
local c0: Color = "red"
local sn0: string? = nil
local p0: Point = { x = 1, y = 2, color = "red" }
local a0: mut {integer} = { 1 }
local m0: mut {string: integer} = { k = 1 }
local function f0(a: integer): integer
  return a
end
]]

--- The types a variable may have.
local TYPES <const>: {string} = {
  "integer", "number", "string", "boolean", "Color", "Point", "integer?", "string?", "{integer}", "mut {integer}",
  "mut {string: integer}",
}

local function pick(g: Gen, list: {string}): string
  return Fuzz.pick(g.src, list)
end

--- The variables of `t` in scope.
local function variables(g: Gen, t: string): {string}
  local out: mut {string} = {}
  for _, v in ipairs(g.vars) do
    if v.type == t and v.params == nil then
      out[#out + 1] = v.name
    end
  end
  return out
end

--- The functions in scope that answer `t`.
local function functions(g: Gen, t: string): {Var}
  local out: mut {Var} = {}
  for _, v in ipairs(g.vars) do
    if v.type == t and v.params ~= nil then
      out[#out + 1] = v
    end
  end
  return out
end

local gen_expr: function(g: Gen, t: string, depth: integer): string

--- A number or an integer, which a number operator takes.
local function numeric(g: Gen, depth: integer): string
  return gen_expr(g, if g.src:int(1, 2) == 1 then "integer" else "number" end, depth)
end

--- An expression of the optional type `t` that may be nil: an index read. A variable of the type is no source: its
--- initializer narrows it to the type of the value, which a test of nil then refuses.
local function maybe(g: Gen, t: string): string
  return t == "integer?" and Fuzz.pick(g.src, { "a0[1]", "m0[\"k\"]" }) or "sn0"
end

--- An expression that is a literal or a variable.
local function leaf(g: Gen, t: string): string
  local names = variables(g, t)
  if #names > 0 and g.src:int(1, 3) > 1 then
    return Fuzz.pick(g.src, names)
  end
  if t == "integer" then
    return tostring(g.src:int(0, 99))
  elseif t == "number" then
    return pick(g, { "1.5", "2.0", "0.25" })
  elseif t == "string" then
    return pick(g, { "\"a\"", "\"bc\"", "\"\"" })
  elseif t == "boolean" then
    return pick(g, { "true", "false" })
  elseif t == "Color" then
    return pick(g, { "\"red\"", "\"green\"" })
  elseif t == "Point" then
    return "{ x = 1, y = 2.5, color = \"red\" }"
  elseif t == "integer?" or t == "string?" then
    return "nil"
  elseif t == "{integer}" or t == "mut {integer}" then
    return "{ 1, 2 }"
  end
  return "{ a = 1 }"
end

gen_expr = function(g: Gen, t: string, depth: integer): string
  if depth <= 0 or g.src:int(1, 3) == 1 then
    return leaf(g, t)
  end
  local d = depth - 1
  local k = g.src:int(1, 6)
  local called = functions(g, t)
  if #called > 0 and k == 1 then
    local f = Fuzz.pick(g.src, called)
    local args: mut {string} = {}
    for i, p in ipairs(f.params or {}) do
      args[i] = gen_expr(g, p, d)
    end
    return f.name .. "(" .. table.concat(args, ", ") .. ")"
  end
  if t == "integer" then
    if k == 2 then
      return "(" .. gen_expr(g, "integer", d) .. " " .. pick(g, { "+", "-", "*" }) .. " " .. gen_expr(g, "integer", d) .. ")"
    elseif k == 3 then
      return "#(" .. gen_expr(g, "string", d) .. ")"
    elseif k == 4 then
      return "(" .. maybe(g, "integer?") .. " or " .. gen_expr(g, "integer", d) .. ")"
    elseif k == 5 then
      return "(if " .. gen_expr(g, "boolean", d) .. " then " .. gen_expr(g, "integer", d) .. " else " ..
        gen_expr(g, "integer", d) .. " end)"
    end
    return "(" .. gen_expr(g, "integer", d) .. " // 2)"
  elseif t == "number" then
    if k == 2 then
      return "(" .. numeric(g, d) .. " " .. pick(g, { "+", "-", "*", "/" }) .. " " .. numeric(g, d) .. ")"
    elseif k == 3 then
      return "-(" .. gen_expr(g, "number", d) .. ")"
    end
    return "(" .. gen_expr(g, "integer", d) .. " / 2)"
  elseif t == "string" then
    if k == 2 then
      return "(" .. gen_expr(g, "string", d) .. " .. " .. gen_expr(g, "string", d) .. ")"
    elseif k == 3 then
      return "tostring(" .. gen_expr(g, "integer", d) .. ")"
    elseif k == 4 then
      return "(" .. gen_expr(g, "string", d) .. "):upper()"
    elseif k == 5 then
      return "(" .. maybe(g, "string?") .. " or " .. gen_expr(g, "string", d) .. ")"
    end
    return "string.format(\"%d\", " .. gen_expr(g, "integer", d) .. ")"
  elseif t == "boolean" then
    if k == 2 then
      return "(" .. numeric(g, d) .. " " .. pick(g, { "<", "<=", ">", ">=" }) .. " " .. numeric(g, d) .. ")"
    elseif k == 3 then
      return "(" .. gen_expr(g, "string", d) .. " " .. pick(g, { "==", "~=" }) .. " " .. gen_expr(g, "string", d) .. ")"
    elseif k == 4 then
      return "(not " .. gen_expr(g, "boolean", d) .. ")"
    elseif k == 5 then
      return "(" .. gen_expr(g, "boolean", d) .. " " .. pick(g, { "and", "or" }) .. " " .. gen_expr(g, "boolean", d) .. ")"
    end
    return "(" .. maybe(g, "string?") .. " == nil)"
  elseif t == "Color" then
    return "(if " .. gen_expr(g, "boolean", d) .. " then " .. gen_expr(g, "Color", d) .. " else " ..
      gen_expr(g, "Color", d) .. " end)"
  elseif t == "Point" then
    local tag = if g.src:int(1, 2) == 1 then ", tag = " .. gen_expr(g, "string", d) else "" end
    return "{ x = " .. numeric(g, d) .. ", y = " .. numeric(g, d) .. ", color = " .. gen_expr(g, "Color", d) .. tag .. " }"
  elseif t == "integer?" then
    return k == 2 and maybe(g, "integer?") or gen_expr(g, "integer", d)
  elseif t == "string?" then
    return gen_expr(g, "string", d)
  elseif t == "{integer}" or t == "mut {integer}" then
    return "{ " .. gen_expr(g, "integer", d) .. ", " .. gen_expr(g, "integer", d) .. " }"
  end
  return "{ k = " .. gen_expr(g, "integer", d) .. ", j = " .. gen_expr(g, "integer", d) .. " }"
end

--- Writes `line` to the program.
local function add(g: Gen, line: string)
  g.lines[#g.lines + 1] = line
end

local function fresh(g: Gen, prefix: string): string
  g.count = g.count + 1
  return prefix .. g.count
end

local gen_statements: function(g: Gen, n: integer, depth: integer, indent: string)

--- A statement.
local function gen_statement(g: Gen, depth: integer, indent: string)
  local k = g.src:int(1, if depth > 0 then 10 else 7 end)
  if k <= 3 then
    local t = pick(g, TYPES)
    local name = fresh(g, "v")
    add(g, indent .. "local " .. name .. ": " .. t .. " = " .. gen_expr(g, t, 3))
    if indent == "" then
      g.inits[#g.inits + 1] = { #g.lines, t }
    end
    g.vars[#g.vars + 1] = { name = name, type = t }
  elseif k == 4 then
    local names: mut {string} = {}
    for _, v in ipairs(g.vars) do
      if v.type == "integer" and v.params == nil and not v.readonly then
        names[#names + 1] = v.name
      end
    end
    if #names > 0 then
      add(g, indent .. Fuzz.pick(g.src, names) .. " = " .. gen_expr(g, "integer", 2))
    else
      add(g, indent .. "print(" .. gen_expr(g, "integer", 2) .. ")")
    end
  elseif k == 5 then
    add(g, indent .. "p0.tag = " .. gen_expr(g, "string?", 2))
  elseif k == 6 then
    add(g, indent .. "a0[#a0 + 1] = " .. gen_expr(g, "integer", 2))
  elseif k == 7 then
    add(g, indent .. "m0[" .. gen_expr(g, "string", 2) .. "] = " .. (if g.src:int(1, 3) == 1 then "nil" else gen_expr(g, "integer", 2) end))
  elseif k == 8 then
    add(g, indent .. "if " .. gen_expr(g, "boolean", 2) .. " then")
    local saved = #g.vars
    gen_statements(g, g.src:int(1, 2), depth - 1, indent .. "  ")
    for i = #g.vars, saved + 1, -1 do
      g.vars[i] = nil
    end
    add(g, indent .. "end")
  elseif k == 9 then
    local i = fresh(g, "i")
    add(g, indent .. "for " .. i .. " = 1, " .. gen_expr(g, "integer", 2) .. " do")
    local saved = #g.vars
    g.vars[#g.vars + 1] = { name = i, type = "integer", readonly = true }
    gen_statements(g, g.src:int(1, 2), depth - 1, indent .. "  ")
    for j = #g.vars, saved + 1, -1 do
      g.vars[j] = nil
    end
    add(g, indent .. "end")
  else
    if indent ~= "" then
      return
    end
    local name = fresh(g, "f")
    local ret = pick(g, TYPES)
    local params = { pick(g, TYPES), pick(g, TYPES) }
    add(g, "local function " .. name .. "(a: " .. params[1] .. ", b: " .. params[2] .. "): " .. ret)
    local saved = #g.vars
    g.vars[#g.vars + 1] = { name = "a", type = params[1] }
    g.vars[#g.vars + 1] = { name = "b", type = params[2] }
    add(g, "  return " .. gen_expr(g, ret, 3))
    for j = #g.vars, saved + 1, -1 do
      g.vars[j] = nil
    end
    add(g, "end")
    g.vars[#g.vars + 1] = { name = name, type = ret, params = params }
  end
end

gen_statements = function(g: Gen, n: integer, depth: integer, indent: string)
  for _ = 1, n do
    gen_statement(g, depth, indent)
  end
end

--- The program of the draws and its lines that put a value in a variable.
local function program(src: Fuzz.Source): Gen
  local g: Gen = {
    src = src, lines = {}, count = 0, inits = {},
    vars = {
      { name = "i0", type = "integer" }, { name = "n0", type = "number" }, { name = "s0", type = "string" },
      { name = "b0", type = "boolean" }, { name = "c0", type = "Color" }, { name = "sn0", type = "string?" },
      { name = "p0", type = "Point" }, { name = "a0", type = "mut {integer}" },
      { name = "m0", type = "mut {string: integer}" },
      { name = "f0", type = "integer", params = { "integer" } },
    },
  }
  gen_statements(g, src:int(3, 12), 2, "")
  return g
end

local function gen_clean(src: Fuzz.Source): string
  return PRELUDE .. table.concat(program(src).lines, "\n") .. "\n"
end

--- A wrong value for a place that wants `t`.
local function wrong(t: string): string
  if t == "string" or t == "string?" or t == "Color" then
    return "1"
  end
  return "\"x\""
end

--- The mistakes that add a statement: a use the rules refuse, built from the variables every program has.
local MISTAKES <const>: {string} = {
  "local bad: integer = s0",
  "local bad: string = sn0",
  "p0.x = 1",
  "local bad = s0 .. i0",
  "if i0 then\nend",
  "local bad = p0.z",
  "a0[1] = 2",
  "local bad = f0(1, 2)",
  "local bad: Color = \"blue\"",
  "local bad: {integer} = { 1, \"a\" }",
  "local bad: integer = a0[1]",
  "local bad: integer = 3.5",
  "local bad = i0 + s0",
  "local bad = m0.k",
}

local function gen_mistaken(src: Fuzz.Source): string
  local g = program(src)
  local lines = g.lines
  local choice = src:int(1, #MISTAKES + 1)
  if choice > #MISTAKES and #g.inits > 0 then
    local init = g.inits[src:int(1, #g.inits)]
    local at, t = init[1], init[2]
    if at is integer and t is string then
      local name = lines[at]:match("^local ([%w_]+):")
      lines[at] = "local " .. tostring(name) .. ": " .. t .. " = " .. wrong(t)
    end
  else
    lines[#lines + 1] = MISTAKES[math.min(choice, #MISTAKES)]
  end
  return PRELUDE .. table.concat(lines, "\n") .. "\n"
end

local function checks_clean(input: string): boolean, string
  local r = Programs.run(input)
  if #r.before > 0 then
    return false, "the program has " .. table.concat(r.before, " ") .. " in\n" .. input
  end
  if #r.errors > 0 then
    local e = r.errors[1]
    return false, e.y .. ":" .. e.x .. " " .. e.code .. ": " .. e.msg .. " in\n" .. input
  end
  Fuzz.label("clean")
  return true, ""
end

local function is_refused(input: string): boolean, string
  local r = Programs.run(input)
  if #r.before > 0 then
    return false, "the program has " .. table.concat(r.before, " ") .. " in\n" .. input
  end
  if #r.errors == 0 then
    return false, "the program is accepted:\n" .. input
  end
  Fuzz.label("refused")
  for _, e in ipairs(r.errors) do
    Fuzz.label(e.code)
  end
  return true, ""
end

local function test_a_program_drawn_from_the_typed_generator_checks_clean(tmp: string)
  Fuzz.run({
    name = "check of a typed program",
    dir = tmp,
    gen = gen_clean,
    check = checks_clean,
    requires = { "clean" },
  })
end

local function test_the_same_program_with_one_mistake_is_refused(tmp: string)
  Fuzz.run({
    name = "check of a mistaken program",
    dir = tmp,
    gen = gen_mistaken,
    check = is_refused,
    requires = { "refused", "not_assignable", "nil_not_allowed", "field_fixed", "concat_type", "condition_type",
      "field_unknown", "array_hole", "arity" },
    shares = { refused = 0.9 },
  })
end
