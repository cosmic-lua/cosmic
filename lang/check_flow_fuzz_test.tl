--- The soundness property of the flow of [`lang.check`], over the programs of [`build.check_draws`] (locals and record
--- fields of `integer?`, `if`/`elseif`/`else` on nil tests, `and`/`or`, the four loops with `break` and `continue`, function
--- literals, early exits), put in the new grammar by [`lang.check_drawn`] and checked; a program the checker takes is written
--- as Lua and run with every read of a narrowed place checked ([`Programs.execute`]), and must run to its end, or to an
--- `assert` that failed, with no `fact violated` and no nil operand. A program the checker refuses is not run: most of the
--- draws are refused, for the narrowing of a field the new grammar declares `mut` is not one. `FUZZ_SEED` and `FUZZ_ITERS`
--- pick the inputs (build/fuzz/init.tl). A few draws run by default so that the test fits a few seconds; the nightly fuzz
--- workflow draws from a seed of its own.
---
--- Fixed fields get their own generator: records whose paths (`r.a`, `r.leaf.n`) are tested, read, copied and
--- replaced by an assignment of the record, with reads of a path after that, which the checker has to refuse.
---
--- The wraps are run with the `__fact` hook of the tool's worker ([`build.test_worker`]'s `fact`, which `install_checks`
--- defines), which a violation also records as a row of `type_violations` in a checked run.
---
--- The programs of the corpus the checker takes also run in a real `cosmic test --check-types` run, their Lua written by
--- the tool and not by [`Programs.execute`] ([`build.fact_hook_tool_test`]).
local Env = require("cosmic.env")
local Fuzz = require("build.fuzz")
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")
local adapt = require("lang.check_drawn")
local drawn = require("build.check_draws")
local worker = require("build.test_worker")

Test.policy{}

--- A construct a program may hold: its name, and a Lua pattern that finds it in the source.
local record Construct
  label: string
  pattern: string
end

--- Constructs of a program that ran.
local CONSTRUCTS <const>: {Construct} = {
  { label = "while", pattern = "while " },
  { label = "repeat", pattern = "repeat" },
  { label = "numeric for", pattern = "for %w+ = " },
  { label = "break", pattern = "break" },
  { label = "continue", pattern = "continue" },
  { label = "assert", pattern = "assert%(" },
  { label = "function literal", pattern = "local function [pfg]%d" },
  { label = "early exit", pattern = "then return st.sink end" },
  { label = "elseif", pattern = "elseif " },
}

--- `source` checked and run with every read of a narrowed place checked by the worker's hook.
local function execute(source: string): Programs.Execution
  return Programs.execute(source, true, nil, nil, worker.fact)
end

--- How many programs to draw: `FUZZ_ITERS` where it is set, else `default`, which a test of a few seconds under coverage
--- allows (each is checked and run).
local function iterations(default: integer): integer
  return math.tointeger(tonumber(Env.get_or("FUZZ_ITERS", ""))) or default
end

local function check_source(source: string): boolean, string
  local x = execute(source)
  if not x.ran then
    Fuzz.label(if #x.run.before > 0 then "not a program" else "refused" end)
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
      if source:find(c.pattern) then
        Fuzz.label("ran with " .. c.label)
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

local function check_program(input: string): boolean, string
  -- A drawn program has the header; an input cut short may lack it, and is checked as it is.
  return check_source(adapt.adapted(input) or input)
end

local function test_a_program_the_flow_takes_does_not_fail_at_a_narrowed_read(tmp: string)
  Fuzz.run({
    name = "flow sound",
    dir = tmp,
    -- Half the default: a draw is a program of the generator of the fork's shapes, put in the new grammar, checked and run.
    iters = iterations(32),
    gen = drawn.well_formed,
    check = check_program,
    requires = { "accepted", "ran", "refused" },
    shares = { accepted = 0.05 },
  })
end

--- The programs whose narrowing must stay refused, and some that must keep running, that the soundness property found once
--- (`testdata/fuzz/checker-sound`), in the new grammar and checked: refused, or run to its end or to a failed `assert`. The
--- programs are not drawn again.
local function test_the_corpus_of_programs_found_unsound_is_refused_or_runs_clean(tmp: string)
  Fuzz.run({
    name = "flow sound corpus",
    dir = tmp,
    iters = 0,
    corpus = "testdata/fuzz/checker-sound",
    gen = drawn.well_formed,
    check = check_source,
  })
end

-- programs of the new grammar --------------------------------------------------------------------------------------

--- What a statement being drawn can name: the locals of type `integer?` in scope, and those a guard around the point (or a
--- test that ended the block) says are not nil, a bias towards the reads the checker must decide, not a claim that they are
--- accepted.
local record Scope
  vars: mut {string}
  mut focus: mut {string}
  --- Paths a test showed not nil that an assignment of their record has replaced since: a read of one, bare, is a read
  --- the checker must refuse, and a program that takes it can fault.
  stale: mut {string}
end

local record Gen
  src: Fuzz.Source
  lines: mut {string}
  mut id: integer
  mut fuel: integer
  mut depth: integer
  --- Whether a `break` and a `continue` leave a loop of the function being drawn.
  mut in_loop: boolean
  --- Whether the program holds records `r` and `s` of fixed optional fields, whose paths (`r.a`, `s.leaf.n`) the
  --- statements test and read as they do the locals, and which an assignment of `r` or `s` replaces.
  fixed: boolean
end

local function copy(list: {string}): {string}
  local out: mut {string} = {}
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
  return { vars = copy(scope.vars), focus = copy(scope.focus), stale = copy(scope.stale) }
end

local function add(g: Gen, text: string)
  table.insert(g.lines, ("  "):rep(g.depth + 1) .. text)
  g.fuel = g.fuel - 1
end

local function fresh(g: Gen, prefix: string): string
  g.id = g.id + 1
  return prefix .. tostring(g.id)
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
  local open: mut {string} = {}
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
  if g.fixed and #scope.stale > 0 and g.src:int(0, 2) == 0 then
    return Fuzz.pick(g.src, scope.stale)
  end
  local v = var_of(g, scope)
  if has(scope.focus, v) or g.src:int(0, 3) == 0 then
    return v
  end
  return "(" .. v .. " or 0)"
end

--- A test of up to `depth` levels: its text, and the locals it says are not nil when it holds. A bare local is a test
--- only at the top, since `and` and `or` of an optional and a boolean are refused; `avoid` are the locals the test it
--- is part of has tested.
local function cond(g: Gen, scope: Scope, depth: integer, avoid: mut {string}, top: boolean): string, {string}
  local k = if depth <= 0 then 0 else g.src:int(0, 6) end
  if k <= 3 then
    local v = tested(g, scope)
    for _ = 1, 3 do
      if has(avoid, v) then
        v = tested(g, scope)
      end
    end
    avoid[#avoid + 1] = v
    local form = g.src:int(0, if top then 5 else 3 end)
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
  local k = g.src:int(0, if g.depth >= 3 then 7 else 13 end)
  -- Over fixed fields a quarter of the statements replace a record, since what they are for is a test of a path that a
  -- replacement then ends.
  if g.fixed and g.depth > 0 and g.src:int(0, 3) == 0 then
    k = 2
  end
  if k <= 1 then
    local name = fresh(g, "v")
    local init = Fuzz.pick(g.src, { "maybe()", "maybe()", "nil", scope.vars[1] })
    add(g, "local " .. name .. ": integer? = " .. init)
    scope.vars[#scope.vars + 1] = name
  elseif k == 2 then
    do
      -- A local is assigned a value; a record of fixed fields is replaced, which ends what a test of its paths showed.
      local v = Fuzz.pick(g.src, scope.vars)
      local drops = v .. "."
      if g.fixed and (v:find(".", 1, true) ~= nil or g.src:int(0, 2) == 0) then
        v = Fuzz.pick(g.src, { "r", "s" })
        drops = v .. "."
        add(g, v .. " = " .. Fuzz.pick(g.src, { "node()", "empty()" }))
      else
        add(g, v .. " = " .. Fuzz.pick(g.src, { "maybe()", "nil", "1" }))
      end
      local kept: mut {string} = {}
      for _, f in ipairs(scope.focus) do
        if f ~= v and f:sub(1, #drops) ~= drops then
          kept[#kept + 1] = f
        else
          scope.stale[#scope.stale + 1] = f
        end
      end
      scope.focus = kept
      -- Often at once: a read of a path the replaced record was tested for, as the checker must refuse.
      if g.fixed and #scope.stale > 0 and g.src:int(0, 2) > 0 then
        add(g, "total = total + " .. Fuzz.pick(g.src, scope.stale))
      end
    end
  elseif k <= 4 then
    add(g, "total = total + " .. operand(g, scope))
  elseif k == 5 then
    local c, yes = cond(g, scope, 2, {}, true)
    add(g, "assert(" .. c .. ")")
    -- What the test shows holds from here on.
    for _, v in ipairs(yes) do
      scope.focus[#scope.focus + 1] = v
    end
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
    add(g, if kind == 2 then "until " .. counter .. " >= 2" else "end" end)
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
  local g: Gen = { src = src, lines = {}, id = 0, fuel = 40, depth = 0, in_loop = false, fixed = false }
  local scope: Scope = { vars = { "a", "b" }, focus = {}, stale = {} }
  gen_block(g, scope, src:int(4, 12))
  return table.concat({
    "local record State",
    "  mut count: integer",
    "end",
    "local st: State = { count = " .. tostring(src:int(0, 5)) .. " }",
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

--- A program of the new grammar over fixed optional fields: records `r` and `s` whose paths `r.a` and `r.leaf.n` are places
--- a test narrows, until an assignment of the record replaces what the test was about. The statements are those over locals,
--- and the paths are drawn as the locals are, tested, read, copied and assigned around.
local function gen_fixed(src: Fuzz.Source): string
  local g: Gen = { src = src, lines = {}, id = 0, fuel = 40, depth = 0, in_loop = false, fixed = true }
  local scope: Scope = { vars = { "a", "r.a", "s.a", "r.leaf.n", "s.leaf.n" }, focus = {}, stale = {} }
  gen_block(g, scope, src:int(4, 12))
  return table.concat({
    "local record Leaf",
    "  n?: integer",
    "end",
    "local record Node",
    "  a?: integer",
    "  leaf: Leaf",
    "end",
    "local record State",
    "  mut count: integer",
    "end",
    "local st: State = { count = " .. tostring(src:int(0, 5)) .. " }",
    "local function maybe(): integer?",
    "  st.count = st.count + 1",
    "  if st.count % 3 == 0 then",
    "    return nil",
    "  end",
    "  return st.count",
    "end",
    "local function node(): Node",
    "  return { a = maybe(), leaf = { n = maybe() } }",
    "end",
    "local function empty(): Node",
    "  return { a = nil, leaf = { n = nil } }",
    "end",
    "local function main(): integer",
    "  local total = 0",
    "  local a: integer? = maybe()",
    "  local b: integer? = maybe()",
    "  local r: Node = node()",
    "  local s: Node = node()",
    table.concat(g.lines, "\n"),
    "  return total",
    "end",
    "print(main())",
    "",
  }, "\n")
end

local LOCAL_CONSTRUCTS <const>: {Construct} = {
  { label = "while", pattern = "while " },
  { label = "repeat", pattern = "repeat\n" },
  { label = "for", pattern = "for c%d+ = " },
  { label = "break", pattern = "break" },
  { label = "continue", pattern = "continue" },
  { label = "assert", pattern = "assert%(" },
  { label = "function literal", pattern = "= function%(%)" },
  { label = "elseif", pattern = "elseif " },
  { label = "early exit", pattern = "== nil then return" },
  { label = "const", pattern = "<const>" },
  { label = "copy", pattern = "local v%d+: integer%? = [abv]%d*\n" },
}

local function check_locals(source: string): boolean, string
  local x = execute(source)
  if not x.ran then
    local first = x.run.errors[1]
    Fuzz.label(if #x.run.before > 0 then "not a program" else "refused" end)
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
  if fault == nil or fault:find("assertion failed", 1, true) ~= nil then
    Fuzz.label(if fault == nil then "ran" else "stopped by assert" end)
    for _, c in ipairs(LOCAL_CONSTRUCTS) do
      if source:find(c.pattern) then
        Fuzz.label("ran with " .. c.label)
      end
    end
    return true, ""
  end
  return false, "the checker took a program that fails at run time: " .. fault .. "\n--- program ---\n" .. source ..
    "\n--- lua ---\n" .. x.lua
end

--- Whether the checker narrowed a read of a path of fixed fields in the program that ran.
local function narrowed_a_path(x: Programs.Execution): boolean
  for _, n in ipairs(x.run.result.narrowed) do
    if n.text:find(".", 1, true) ~= nil then
      return true
    end
  end
  return false
end

local function check_fixed(source: string): boolean, string
  local ok, why = check_locals(source)
  if ok then
    local x = execute(source)
    if x.ran and narrowed_a_path(x) then
      Fuzz.label("narrowed path read")
    end
    if x.ran and source:find("\n%s*[rs] = %a+%(%)\n") ~= nil then
      Fuzz.label("replaced a record")
    end
  end
  return ok, why
end

local function test_a_program_over_fixed_fields_the_flow_takes_does_not_fail_at_a_narrowed_path(tmp: string)
  Fuzz.run({
    name = "flow sound fixed fields",
    dir = tmp,
    -- Under 3 s with coverage; a replaced record is drawn so often that the mutant that stops it ending a test is found by
    -- the 8th draw.
    iters = iterations(24),
    gen = gen_fixed,
    check = check_fixed,
    requires = { "accepted", "ran", "refused", "narrowed read", "narrowed path read", "replaced a record" },
    shares = { accepted = 0.05, ["narrowed path read"] = 0.05 },
  })
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

-- programs over arrays ------------------------------------------------------------------------------------------------

--- What every array program starts with: `shared`, which a function reaches as a view `v`, as a `mut` array `o` and by
--- its own name at once, and the code that shortens it: `shorten`, `trim`, a `table.remove`, and the `__tostring` of an
--- `Eater`, which `tostring` runs. `pure` and `touch` run code that touches no array.
local ARRAYS_HEAD <const> = [[
local record Counter
  mut n: integer
end
local st: Counter = { n = 0 }
local shared: mut {string} = { "a", "b", "c", "d", "e", "f" }
local function reset(n: integer)
  while #shared > n do
    table.remove(shared)
  end
  while #shared < n do
    shared[#shared + 1] = "s"
  end
end
local function touch()
  st.n = st.n + 1
end
local function pure(x: integer): integer
  return x + 1
end
local function shorten()
  table.remove(shared)
end
local function trim(a: mut {string})
  table.remove(a)
end
local class Eater
  n: integer
  function __tostring(self): string
    table.remove(shared)
    return "x"
  end
end
local eater: Eater = { n = 0 }
]]

--- Statements that may shorten `shared`, which `v`, `o` and `shared` all are.
local SHORTENERS <const>: {string} = {
  "shorten()", "table.remove(shared)", "table.remove(o)", "table.remove(o, 1)", "o[#o] = nil", "shared[#shared] = nil",
  "trim(o)", "trim(shared)", "reset(0)", "pcall(shorten)", "total = total + #tostring(eater)",
}

--- Statements that run no code that shortens an array, or that the checker must take to.
local KEEPERS <const>: {string} = {
  "touch()", "total = total + pure(1)", "total = total + #tostring(total)", "total = total + #tostring(#v)",
  "total = total + #string.upper(\"a\")", "total = total + #(\"b\"):upper()", "total = total + math.max(1, 2)",
  "total = total + #table.concat(v)", "total = total + #string.format(\"%d\", total)", "o[#o + 1] = \"q\"",
  "table.insert(o, \"q\")", "table.insert(o, 1, \"q\")", "for _ in ipairs(v) do end",
}

--- The statements of a function over arrays, which call each other, over the array `s` (`v`, `o` or `shared`).
local record Arrays
end

--- A test that `s` has an element, of the forms the checker reads, some with a call in the test, and the index it is about.
function Arrays.test(g: Gen, s: string): string, integer
  local n = g.src:int(1, 6)
  local k, below = tostring(n), tostring(n - 1)
  local len = "#" .. s
  return Fuzz.pick(g.src, {
    len .. " >= " .. k, len .. " > " .. below, len .. " == " .. k, k .. " <= " .. len, len .. " >= " .. k .. " and " .. len .. " < 9",
    len .. " >= " .. k .. " and #tostring(eater) > 0", len .. " ~= 0", len .. " >= " .. k .. " and #tostring(total) > 0",
  }), n
end

--- The read of an element of `s`: of `at` if given, of `loop` (or the next or last one) where a numeric `for` has one. A
--- statement passes it to `tostring`, which takes the optional element a read the checker cannot prove is, so that only the
--- reads it proves can fail.
function Arrays.read(g: Gen, s: string, loop: string?, at?: integer): string
  if loop ~= nil and g.src:int(0, 2) > 0 then
    return s .. "[" .. Fuzz.pick(g.src, { loop, loop, loop .. " + 1", loop .. " - 1" }) .. "]"
  elseif at ~= nil then
    return s .. "[" .. tostring(at) .. "]"
  end
  return Fuzz.pick(g.src, { s .. "[1]", s .. "[2]", s .. "[3]", s .. "[5]", s .. "[#" .. s .. "]" })
end

--- A statement that shortens an array, or that may: of `SHORTENERS` or the alias and the closure, each given a name.
function Arrays.shorten(g: Gen)
  local k = g.src:int(0, 5)
  if k == 0 then
    local u = fresh(g, "u")
    add(g, "local " .. u .. ": mut {string} = " .. Fuzz.pick(g.src, { "o", "shared" }))
    add(g, u .. "[#" .. u .. "] = nil")
  elseif k == 1 then
    local c = fresh(g, "cut")
    add(g, "local " .. c .. " = function() table.remove(" .. Fuzz.pick(g.src, { "shared", "o" }) .. ") end")
    add(g, c .. "()")
  else
    add(g, Fuzz.pick(g.src, SHORTENERS))
  end
end

function Arrays.block(g: Gen, s: string, loop: string?, n: integer)
  for _ = 1, n do
    if g.fuel > 0 then
      Arrays.statement(g, s, loop)
    end
  end
end

--- `body` drawn one level in, between the line `head` and an `end`.
function Arrays.nested(g: Gen, s: string, loop: string?, head: string, n: integer)
  add(g, head)
  g.depth = g.depth + 1
  Arrays.block(g, s, loop, n)
  g.depth = g.depth - 1
  add(g, "end")
end

function Arrays.statement(g: Gen, s: string, loop: string?)
  local k = g.src:int(0, if g.depth >= 2 then 6 else 11 end)
  local len = "#" .. s
  if k <= 1 then
    add(g, "total = total + #tostring(" .. Arrays.read(g, s, loop) .. ")")
  elseif k == 2 then
    add(g, "assert(" .. Arrays.test(g, s) .. Fuzz.pick(g.src, { "", ", \"assertion failed: m\"", ", \"assertion failed: \" .. tostring(" .. len .. ")",
      ", \"assertion failed: \" .. tostring(eater)" }) .. ")")
  elseif k == 3 then
    Arrays.nested(g, s, loop, "if " .. Arrays.test(g, s) .. " then", g.src:int(1, 3))
  elseif k == 4 then
    add(g, "if " .. len .. " " .. Fuzz.pick(g.src, { "< 1", "== 0", "< 2", "<= 2", "< 4" }) .. " then return total end")
  elseif k == 5 then
    if g.src:int(0, 1) == 0 then
      Arrays.shorten(g)
    else
      add(g, Fuzz.pick(g.src, KEEPERS))
    end
  elseif k == 6 then
    -- A test, code that may shorten the array, and the read the test was for: the one shape a rule that keeps a fact too long
    -- gets wrong.
    local test, at = Arrays.test(g, s)
    local form = g.src:int(0, 2)
    if form == 0 then
      add(g, "assert(" .. test .. ")")
      Arrays.shorten(g)
    elseif form == 1 then
      add(g, "if not (" .. test .. ") then return total end")
      Arrays.shorten(g)
    else
      add(g, "if " .. test .. " then")
      g.depth = g.depth + 1
      Arrays.shorten(g)
    end
    add(g, "total = total + #tostring(" .. Arrays.read(g, s, nil, at) .. ")")
    if form == 2 then
      g.depth = g.depth - 1
      add(g, "end")
    end
  elseif k == 7 then
    local i = fresh(g, "i")
    local other = if s == "v" then "o" else "v" end
    local head = Fuzz.pick(g.src, {
      "for " .. i .. " = 1, " .. len .. " do", "for " .. i .. " = " .. len .. ", 1, -1 do", "for " .. i .. " = 2, " .. len .. " do",
      "for " .. i .. " = 1, " .. len .. " - 1 do", "for " .. i .. " = 0, " .. len .. " do", "for " .. i .. " = 1, " .. len .. " + 1 do",
      "for " .. i .. " = 1, " .. len .. ", 2 do", "for " .. i .. " = 1, #" .. other .. " do", "for " .. i .. " = 1, #shared do",
    })
    Arrays.nested(g, s, i, head, g.src:int(1, 3))
  elseif k == 8 then
    -- Bounded by a counter, since a body that shortens nothing would not end.
    local w = fresh(g, "w")
    add(g, "local " .. w .. " = 0")
    add(g, "while " .. Arrays.test(g, s) .. " and " .. w .. " < 3 do")
    g.depth = g.depth + 1
    add(g, w .. " = " .. w .. " + 1")
    Arrays.block(g, s, loop, g.src:int(1, 3))
    g.depth = g.depth - 1
    add(g, "end")
  elseif k == 9 then
    add(g, "if " .. Arrays.test(g, s) .. " then")
    g.depth = g.depth + 1
    Arrays.block(g, s, loop, g.src:int(1, 2))
    g.depth = g.depth - 1
    add(g, "else")
    g.depth = g.depth + 1
    Arrays.block(g, s, loop, g.src:int(1, 2))
    g.depth = g.depth - 1
    add(g, "end")
  elseif k == 10 then
    -- The length bound in a local, and an index that is not a literal.
    local m = fresh(g, "m")
    add(g, "local " .. m .. " = " .. len)
    add(g, "if " .. m .. " >= 1 then")
    g.depth = g.depth + 1
    add(g, "total = total + #tostring(" .. s .. "[" .. m .. "])")
    g.depth = g.depth - 1
    add(g, "end")
  else
    add(g, "total = total + #tostring(" .. Arrays.read(g, s, loop) .. ")")
    Arrays.shorten(g)
    add(g, "total = total + #tostring(" .. Arrays.read(g, s, loop) .. ")")
  end
end

--- A program of [`ARRAYS_HEAD`] and functions of statements over `v`, `o` and `shared`, called with `shared` at every length from
--- six to none.
local function gen_arrays(src: Fuzz.Source): string
  local out: mut {string} = { ARRAYS_HEAD }
  for count = 1, src:int(1, 3) do
    local n = tostring(count)
    local g: Gen = { src = src, lines = {}, id = 0, fuel = 30, depth = 0, in_loop = false, fixed = false }
    for _ = 1, src:int(3, 8) do
      if g.fuel > 0 then
        Arrays.statement(g, Fuzz.pick(src, { "v", "v", "o", "shared" }), nil)
      end
    end
    out[#out + 1] = "local function f" .. n .. "(v: {string}, o: mut {string}): integer\n  local total = 0"
    out[#out + 1] = table.concat(g.lines, "\n")
    out[#out + 1] = "  return total\nend"
    -- A failed `assert` ends a call, not the program; a violated fact is raised again.
    out[#out + 1] = "for n = 6, 0, -1 do\n  reset(n)\n  local ok, why = pcall(f" .. n ..
      ", shared, shared)\n  if not ok and tostring(why):find(\"fact violated\", 1, true) ~= nil then\n    error(why)\n  end\nend"
  end
  return table.concat(out, "\n") .. "\n"
end

local ARRAY_CONSTRUCTS <const>: {Construct} = {
  { label = "numeric for", pattern = "for i%d+ = " }, { label = "while", pattern = "while " },
  { label = "message call", pattern = "assert%([^\n]*%.%. tostring" }, { label = "class tostring", pattern = "tostring%(eater%)" },
  { label = "removal", pattern = "table%.remove" }, { label = "nil write", pattern = "%] = nil" },
}

local function check_arrays(source: string): boolean, string
  local x = execute(source)
  if not x.ran then
    local first = x.run.errors[1]
    if first ~= nil then
      Fuzz.label("refused for " .. first.code)
    end
    Fuzz.label(if #x.run.before > 0 then "not a program" else "refused" end)
    return true, ""
  end
  Fuzz.label("accepted")
  for _, n in ipairs(x.run.result.narrowed) do
    if n.text:find("[", 1, true) ~= nil then
      Fuzz.label("length read")
      break
    end
  end
  local fault = x.fault
  if fault == nil or fault:find("fact violated", 1, true) == nil and fault:find("assertion failed", 1, true) ~= nil then
    Fuzz.label(if fault == nil then "ran" else "stopped by assert" end)
    for _, c in ipairs(ARRAY_CONSTRUCTS) do
      if source:find(c.pattern) then
        Fuzz.label("ran with " .. c.label)
      end
    end
    return true, ""
  end
  return false, "the checker took a program that fails at run time: " .. fault .. "\n--- program ---\n" .. source ..
    "\n--- lua ---\n" .. x.lua
end

--- The corpus is `testdata/fuzz/flow-sound-arrays`: one program for each rule that keeps a length fact too long, which fails at
--- run time when the checker has the rule, and runs clean otherwise. The inputs are programs, not draws, so they run at
--- every budget, `FUZZ_ITERS=0` of the merge gate included.
local function test_a_program_over_arrays_the_flow_takes_does_not_read_nil_where_a_length_fact_said_it_was_not(tmp: string)
  Fuzz.run({
    name = "flow sound arrays",
    dir = tmp,
    iters = iterations(32),
    gen = gen_arrays,
    check = check_arrays,
    requires = { "accepted", "ran", "length read" },
    shares = { accepted = 0.05 },
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
  local choice = assert(param[g.src:int(2, #param)], "the argument is one of the parameter's")
  return choice
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
    local declared = assert(param[1], "a parameter type")
    line("local function " .. n .. "(v: " .. declared .. "): string")
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
  local g: Gen = { src = src, lines = {}, id = 0, fuel = 0, depth = 0, in_loop = false, fixed = false }
  for _ = 1, src:int(2, 5) do
    gen_shape(g)
  end
  return SHAPES_HEAD .. table.concat(g.lines, "\n") .. "\n"
end

local SHAPE_CONSTRUCTS <const>: {Construct} = {
  { label = "enum", pattern = "is Color" }, { label = "type test", pattern = "type%(v%) == " }, { label = "class", pattern = "v is A" }, { label = "tag", pattern = "v.kind" }, { label = "table", pattern = "is table" },
  { label = "closure", pattern = "local g = function" }, { label = "coroutine", pattern = "coroutine.wrap" }, { label = "assignment", pattern = "o = " }, { label = "declaration", pattern = "v is string" },
  { label = "assignment after closure", pattern = "  x = " },
}

local function check_shapes(source: string): boolean, string
  local x = execute(source)
  if not x.ran then
    local first = x.run.errors[1]
    Fuzz.label(if #x.run.before > 0 then "not a program" else "refused" end)
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
      if source:find(c.pattern) then
        Fuzz.label("ran with " .. c.label)
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
