--- Fuzz properties for the type checker, and a pinned corpus of its
--- verdicts. Programs are drawn over what the narrowing work touches:
--- locals and record fields typed `integer | nil`, `if`/`elseif`/`else`
--- on nil tests, `assert`, `and`/`or`, the four loops with `break` and
--- `goto`, function literals that assign upvalues, calls, field writes
--- and `return`. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs
--- (build/fuzz/init.tl).
---
--- 1. The checker never raises: a program of any shape, well formed or
---    cut and flipped, is accepted or refused with errors, each carrying
---    a code and a place inside the source.
--- 2. Soundness: a well-formed program the checker accepts runs to its
---    end, or to a failed `assert`, without a nil operand. The programs
---    are bounded by construction (loops count up to three, a function
---    calls only those declared before it) and deterministic (nil comes
---    from a counter), so the run needs no hook; [`Fuzz.run`]'s budget ends
---    one that nonetheless does not stop.
--- 3. The corpus pins the verdict (accepted, or the codes of its errors)
---    of each program in it, so a change in what the checker takes or
---    refuses shows up as a change here, to be made on purpose.
local Fuzz = require("build.fuzz")
local Test = require("cosmic.test")
local teal = require("build.teal")
local type compiler = require("build.compiler")

-- The compiler is the tree's own checker, keyed by the core; nothing is read.
Test.policy{}

local built: compiler | nil

local function compiler_of(): compiler
  if built == nil then
    built = assert(teal.load(true))
  end
  return built
end

--- `source` checked as a program in a fresh environment, so that one
--- program's declarations never reach the next. Raises what the checker
--- raises.
local function check(source: string): string | nil, compiler.Result
  local c = compiler_of()
  local env = assert(c.new_env({ defaults = { feat_lax = "off", gen_compat = "off", gen_target = "5.4" } }))
  return c.gen(source, env, nil, "tl")
end

--------------------------------------------------------------------------------
-- The generator
--------------------------------------------------------------------------------

--- What the program at a point of the draw can name: the locals of type
--- `integer | nil` (`ints`), of type `R | nil` (`recs`), the functions
--- that take nothing and assign upvalues (`procs`), and those that take an
--- `integer | nil` and return an `integer` (`funs`). `focus` lists the
--- places a guard around the point says are not nil, `rfocus` the same
--- for `recs`: a bias towards uses that the checker must decide, not a
--- claim that they are accepted.
local record Vis
  ints: {string}
  recs: {string}
  procs: {string}
  funs: {string}
  focus: {string}
  rfocus: {string}
  in_loop: boolean
  cont: string | nil
  ret: string
end

local record Gen
  src: Fuzz.Source
  lines: {string}
  id: integer
  fuel: integer
  depth: integer
  --- A program of this kind never uses a place its guards do not name, nor
  --- clears one it tests, so most are accepted and exercise the constructs.
  calm: boolean
end

--- A guard drawn: its text, and the places it says are not nil when it
--- holds (`yes`) and when it does not (`no`).
local record Cond
  text: string
  yes: {string}
  no: {string}
  ryes: {string}
  rno: {string}
  --- Whether the checker has a guard of the test: not for a call or a comparison.
  guarded: boolean
end

local FIELDS <const>: {string} = { "r.a", "r.b", "s.a", "s.b" }

--- Declares what every program starts with. `count` starts at `seed`,
--- which moves where `maybe` answers nil.
local function header(seed: integer): string
  return table.concat({
    "local record R",
    "  a: integer | nil",
    "  b: integer | nil",
    "  n: integer",
    "end",
    "local r: R = { a = 1, n = 0 }",
    "local s: R = { b = 2, n = 0 }",
    "local count: integer = " .. seed,
    "local sink: integer = 0",
    "local nums: {integer} = { 1, 2, 3 }",
    "local opts: {integer | nil} = { 1, 2, 3 }",
    "local function maybe(): integer | nil",
    "  count = count + 1",
    "  if count % 3 == 0 then return nil end",
    "  return count",
    "end",
    "local function pick(): R | nil",
    "  count = count + 1",
    "  if count % 3 == 0 then return nil end",
    "  if count % 2 == 0 then return r end",
    "  return s",
    "end",
    "local function touch(t: R)",
    "  t.a = nil",
    "  t.b = nil",
    "end",
    "local function id(v: integer | nil): integer | nil",
    "  return v",
    "end",
    "",
  }, "\n")
end

local function dup(list: {string}): {string}
  local out: {string} = {}
  for i, s in ipairs(list) do
    out[i] = s
  end
  return out
end

--- A scope nested in `v`: what its block declares or learns goes when it ends.
local function nest(v: Vis): Vis
  return {
    ints = dup(v.ints), recs = dup(v.recs), procs = dup(v.procs), funs = dup(v.funs),
    focus = dup(v.focus), rfocus = dup(v.rfocus),
    in_loop = v.in_loop, cont = v.cont, ret = v.ret,
  }
end

local function add(g: Gen, text: string)
  g.lines[#g.lines + 1] = ("  "):rep(g.depth) .. text
  g.fuel = g.fuel - 1
end

local function fresh(g: Gen, prefix: string): string
  g.id = g.id + 1
  return prefix .. g.id
end

local function places(v: Vis): {string}
  local out = dup(v.ints)
  for _, f in ipairs(FIELDS) do
    out[#out + 1] = f
  end
  return out
end

--- A place of type `integer | nil`, biased to those a guard names.
local function place(g: Gen, v: Vis): string
  if #v.focus > 0 and g.src:int(0, 2) > 0 then
    return Fuzz.pick(g.src, v.focus)
  end
  return Fuzz.pick(g.src, places(v))
end

--- A place to write: any, with no bias.
local function target(g: Gen, v: Vis): string
  return Fuzz.pick(g.src, places(v))
end

local function opt_expr(g: Gen, v: Vis): string
  local k = g.src:int(0, 8)
  if k == 0 then return "nil" end
  if k == 1 then return tostring(g.src:int(0, 3)) end
  if k == 2 or k == 3 then return "maybe()" end
  if k == 4 then return place(g, v) end
  if k == 5 then return "id(" .. place(g, v) .. ")" end
  if k == 6 then return place(g, v) .. " and " .. place(g, v) end
  if k == 7 and #v.funs > 0 then return Fuzz.pick(g.src, v.funs) .. "(" .. place(g, v) .. ")" end
  return "(" .. place(g, v) .. " or nil)"
end

--- An expression of type `integer`: some use a place that must have been
--- narrowed.
--- A place as an operand of `integer` arithmetic: bare when a guard names it,
--- otherwise mostly given a default, so that the draws are not all refused.
local function operand(g: Gen, v: Vis): string
  local p = place(g, v)
  for _, f in ipairs(v.focus) do
    if f == p then return p end
  end
  if g.calm or g.src:int(0, 3) > 0 then return "(" .. p .. " or 0)" end
  return p
end

local function int_expr(g: Gen, v: Vis): string
  local k = g.src:int(0, 12)
  if k == 0 then return tostring(g.src:int(0, 3)) end
  if k == 1 then return "count" end
  if k == 2 or k == 3 then return operand(g, v) .. " + 1" end
  if k == 4 then return "(" .. place(g, v) .. " or 0)" end
  if k == 5 or k == 6 then return operand(g, v) end
  if k == 7 then return operand(g, v) .. " * 2" end
  if k == 8 then
    local p = place(g, v)
    return "(" .. p .. " and " .. p .. " + 1 or 0)"
  end
  if k == 9 and #v.funs > 0 then return Fuzz.pick(g.src, v.funs) .. "(" .. place(g, v) .. ")" end
  if k == 10 and #v.recs > 0 and (#v.rfocus > 0 or (not g.calm and g.src:int(0, 2) == 0)) then
    local pool = #v.rfocus > 0 and g.src:int(0, 2) > 0 and v.rfocus or v.recs
    return Fuzz.pick(g.src, pool) .. ".n"
  end
  if k == 11 then return "-" .. operand(g, v) end
  return "r.n"
end

local function union_of(a: {string}, b: {string}): {string}
  local out = dup(a)
  for _, s in ipairs(b) do
    out[#out + 1] = s
  end
  return out
end

local NONE <const>: {string} = {}

local function atom(g: Gen, v: Vis): Cond
  local k = g.src:int(0, 14)
  if k <= 2 then
    local p = place(g, v)
    return { text = p, yes = { p }, no = NONE, ryes = NONE, rno = NONE, guarded = true }
  end
  if k == 3 or k == 4 then
    local p = place(g, v)
    return { text = p .. " ~= nil", yes = { p }, no = NONE, ryes = NONE, rno = NONE, guarded = true }
  end
  if k == 5 or k == 6 then
    local p = place(g, v)
    return { text = p .. " == nil", yes = NONE, no = { p }, ryes = NONE, rno = NONE, guarded = true }
  end
  if k == 7 then
    local p = place(g, v)
    return { text = "not " .. p, yes = NONE, no = { p }, ryes = NONE, rno = NONE, guarded = true }
  end
  if k == 8 then
    local p = place(g, v)
    return { text = "type(" .. p .. ") == \"number\"", yes = { p }, no = NONE, ryes = NONE, rno = NONE, guarded = true }
  end
  if k == 9 then
    return { text = "maybe()", yes = NONE, no = NONE, ryes = NONE, rno = NONE, guarded = false }
  end
  if k == 10 then
    return { text = "count % 2 == 0", yes = NONE, no = NONE, ryes = NONE, rno = NONE, guarded = false }
  end
  if k == 11 then
    local p = place(g, v)
    return { text = "(" .. p .. " or 0) > 0", yes = NONE, no = NONE, ryes = NONE, rno = NONE, guarded = false }
  end
  if #v.recs > 0 then
    local o = Fuzz.pick(g.src, v.recs)
    if k == 12 then
      return { text = o, yes = NONE, no = NONE, ryes = { o }, rno = NONE, guarded = true }
    end
    if k == 13 then
      return { text = o .. " ~= nil", yes = NONE, no = NONE, ryes = { o }, rno = NONE, guarded = true }
    end
    return { text = o .. " == nil", yes = NONE, no = NONE, ryes = NONE, rno = { o }, guarded = true }
  end
  local p = place(g, v)
  return { text = p .. " ~= nil", yes = { p }, no = NONE, ryes = NONE, rno = NONE, guarded = true }
end

-- TODO: draw `or` in an `assert`, and an `or` whose right operand is a call or a
-- comparison, once the checker reads the true branch of `a or b` as nothing
-- where `b` gives no guard: `evaluate` in checker/narrowing.tl reads it as
-- `not a`, so `assert(x == nil or y)` and `if x == nil or maybe()` narrow `x` to
-- non-nil. Making `evaluate` return nothing there breaks the tree's own build
-- (build/shape_specs.tl's `at == nil and why or (...at.typename...)`), which
-- would first be written to need no narrowing from it.

--- A test of up to `depth` levels, drawn with `or` unless `plain`.
local function cond(g: Gen, v: Vis, depth: integer, plain?: boolean): Cond
  local k = depth <= 0 and 0 or g.src:int(0, 5)
  if k <= 2 then return atom(g, v) end
  if k == 3 or (k == 4 and plain) then
    local a, b = cond(g, v, depth - 1, plain), cond(g, v, depth - 1, plain)
    return { text = a.text .. " and " .. b.text, yes = union_of(a.yes, b.yes), no = NONE,
      ryes = union_of(a.ryes, b.ryes), rno = NONE, guarded = a.guarded or b.guarded }
  end
  if k == 4 then
    local a, b = cond(g, v, depth - 1), cond(g, v, depth - 1)
    if not b.guarded then
      local p = place(g, v)
      b = { text = p .. " ~= nil", yes = { p }, no = NONE, ryes = NONE, rno = NONE, guarded = true }
    end
    return { text = a.text .. " or " .. b.text, yes = NONE, no = union_of(a.no, b.no),
      ryes = NONE, rno = union_of(a.rno, b.rno), guarded = true }
  end
  local a = cond(g, v, depth - 1, plain)
  return { text = "not (" .. a.text .. ")", yes = a.no, no = a.yes, ryes = a.rno, rno = a.ryes, guarded = a.guarded }
end

local function learn(v: Vis, places_: {string}, recs: {string})
  for _, p in ipairs(places_) do
    v.focus[#v.focus + 1] = p
  end
  for _, o in ipairs(recs) do
    v.rfocus[#v.rfocus + 1] = o
  end
end

local stmt: function(Gen, Vis, integer)

--- Statements into a scope of its own.
local function block(g: Gen, v: Vis, depth: integer, max: integer, facts?: Cond, negated?: boolean)
  local inner = nest(v)
  if facts then
    if negated then learn(inner, facts.no, facts.rno) else learn(inner, facts.yes, facts.ryes) end
  end
  g.depth = g.depth + 1
  local n = 0
  while g.fuel > 0 and Fuzz.more(g.src, n, max) do
    n = n + 1
    stmt(g, inner, depth)
  end
  g.depth = g.depth - 1
end

--- A loop body: the statements, then the label a `goto` skips to.
local function loop_body(g: Gen, v: Vis, depth: integer, label: string | nil, facts?: Cond)
  local inner = nest(v)
  inner.in_loop = true
  inner.cont = label
  -- A test made before the loop may be undone by the body, where the loop
  -- comes round: only the loop's own test is carried in.
  inner.focus = {}
  inner.rfocus = {}
  if facts then learn(inner, facts.yes, facts.ryes) end
  g.depth = g.depth + 1
  if g.src:int(0, 1) == 0 then
    local c = cond(g, inner, 1)
    add(g, "if " .. c.text .. " then " .. (label ~= nil and g.src:int(0, 1) == 0 and "goto " .. label or "break") .. " end")
  end
  local n = 0
  while g.fuel > 0 and Fuzz.more(g.src, n, 4) do
    n = n + 1
    stmt(g, inner, depth)
  end
  if label then
    g.depth = g.depth - 1
    add(g, "::" .. label .. "::")
    g.depth = g.depth + 1
  end
  g.depth = g.depth - 1
end

--- A function that assigns upvalues: nil, or what `maybe` answers.
local function proc(g: Gen, v: Vis)
  local name = fresh(g, "p")
  add(g, "local function " .. name .. "()")
  g.depth = g.depth + 1
  local n = 0
  while Fuzz.more(g.src, n, 3) do
    n = n + 1
    if g.src:int(0, 3) == 0 then
      add(g, "touch(" .. Fuzz.pick(g.src, { "r", "s" }) .. ")")
    else
      add(g, target(g, v) .. " = " .. Fuzz.pick(g.src, { "nil", "maybe()", "1" }))
    end
  end
  add(g, "r.n = r.n + 1")
  g.depth = g.depth - 1
  add(g, "end")
  v.procs[#v.procs + 1] = name
end

--- A function of an `integer | nil` parameter, whose body is drawn like
--- the program's and which calls only what was declared before it.
local function fun(g: Gen, v: Vis, depth: integer)
  local name, param = fresh(g, "f"), fresh(g, "x")
  add(g, "local function " .. name .. "(" .. param .. ": integer | nil): integer")
  local inner = nest(v)
  inner.in_loop = false
  inner.cont = nil
  inner.ret = "return sink"
  inner.ints[#inner.ints + 1] = param
  g.depth = g.depth + 1
  local n = 0
  while g.fuel > 0 and Fuzz.more(g.src, n, 4) do
    n = n + 1
    stmt(g, inner, depth + 1)
  end
  add(g, "return sink")
  g.depth = g.depth - 1
  add(g, "end")
  v.funs[#v.funs + 1] = name
end

local function declare(g: Gen, v: Vis)
  local k = g.src:int(0, 11)
  local name = fresh(g, "x")
  if k == 0 then
    add(g, "local " .. name .. ": integer | nil")
  elseif k == 1 then
    -- Two names under one type annotation.
    local other = fresh(g, "x")
    add(g, "local " .. name .. ", " .. other .. ": integer | nil = " .. opt_expr(g, v) .. ", " .. opt_expr(g, v))
    v.ints[#v.ints + 1] = other
  elseif k == 2 then
    -- A type for the first name only: refused, and once raised.
    add(g, "local " .. name .. ": integer | nil, " .. fresh(g, "y") .. " = " .. opt_expr(g, v) .. ", 2")
    return
  elseif k == 3 then
    local other = fresh(g, "x")
    add(g, "local " .. name .. ", " .. other .. " = " .. opt_expr(g, v) .. ", " .. opt_expr(g, v))
    v.ints[#v.ints + 1] = other
  else
    add(g, "local " .. name .. ": integer | nil = " .. opt_expr(g, v))
  end
  v.ints[#v.ints + 1] = name
end

local function assign(g: Gen, v: Vis)
  local k = g.src:int(0, 7)
  if k == 0 then
    local a, b = target(g, v), target(g, v)
    add(g, a .. ", " .. b .. " = " .. b .. ", " .. a)
  elseif k == 1 then
    add(g, "r.n = r.n + " .. int_expr(g, v))
  elseif k == 2 and #v.recs > 0 then
    local o = Fuzz.pick(g.src, v.recs)
    add(g, o .. ".n = " .. int_expr(g, v))
  elseif k == 3 then
    add(g, target(g, v) .. " = nil")
  else
    add(g, target(g, v) .. " = " .. opt_expr(g, v))
  end
end

local function if_chain(g: Gen, v: Vis, depth: integer)
  local first = cond(g, v, 2)
  add(g, "if " .. first.text .. " then")
  block(g, v, depth - 1, 4, first)
  local seen: {Cond} = { first }
  local arms = 0
  while g.fuel > 0 and Fuzz.more(g.src, arms, 2) do
    arms = arms + 1
    local c = cond(g, v, 1)
    add(g, "elseif " .. c.text .. " then")
    -- A later arm holds what its own test says, and the negation of the
    -- earlier ones for what they fail by being a nil test.
    local inner = nest(v)
    for _, e in ipairs(seen) do
      learn(inner, e.no, e.rno)
    end
    block(g, inner, depth - 1, 3, c)
    seen[#seen + 1] = c
  end
  if g.src:int(0, 2) > 0 then
    add(g, "else")
    local inner = nest(v)
    for _, e in ipairs(seen) do
      learn(inner, e.no, e.rno)
    end
    block(g, inner, depth - 1, 3)
  end
  add(g, "end")
  -- A branch that ends leaves its negation to what follows.
  if first.no ~= NONE and #first.no > 0 and g.src:int(0, 3) == 0 then
    learn(v, first.no, first.rno)
  end
end

--- A guard that leaves the block when it fails, and what follows it.
local function early_exit(g: Gen, v: Vis)
  local c = cond(g, v, 1)
  local how = g.src:int(0, 3)
  local leave: string
  if how == 0 and v.in_loop then
    leave = "break"
  elseif how == 1 and v.cont ~= nil then
    leave = "goto " .. (v.cont as string)
  else
    leave = v.ret
  end
  add(g, "if not (" .. c.text .. ") then " .. leave .. " end")
  learn(v, c.yes, c.ryes)
end

--- Something that may or may not clear `p`: a call that runs other code,
--- a write, a function literal made and called, a loop that writes it.
local function dropper(g: Gen, v: Vis, p: string)
  local k = g.src:int(0, 13)
  if k <= 2 then
    add(g, "touch(" .. Fuzz.pick(g.src, { "r", "s" }) .. ")")
  elseif k == 3 then
    add(g, p .. " = " .. opt_expr(g, v))
  elseif k == 4 then
    add(g, target(g, v) .. " = " .. opt_expr(g, v))
  elseif k == 5 then
    local name = fresh(g, "p")
    add(g, "local function " .. name .. "() " .. p .. " = " .. Fuzz.pick(g.src, { "nil", "maybe()" }) .. " end")
    if g.src:int(0, 4) > 0 then add(g, name .. "()") end
    v.procs[#v.procs + 1] = name
  elseif k == 6 and #v.procs > 0 then
    add(g, Fuzz.pick(g.src, v.procs) .. "()")
  elseif k == 7 then
    add(g, "id(" .. place(g, v) .. ")")
  elseif k == 8 then
    add(g, "while maybe() and count % 5 ~= 0 do " .. p .. " = maybe() end")
  elseif k == 9 then
    add(g, "for _ = 1, 2 do " .. p .. " = " .. opt_expr(g, v) .. " end")
  elseif k == 10 and #v.funs > 0 then
    add(g, "sink = sink + " .. Fuzz.pick(g.src, v.funs) .. "(" .. place(g, v) .. ")")
  elseif k == 11 then
    add(g, "sink = sink + (maybe() or 0) + " .. p)
  elseif k == 12 then
    add(g, "local " .. fresh(g, "x") .. " = " .. place(g, v))
  else
    add(g, "r.n = r.n + 1")
  end
end

--- A test of one place, then something that may clear it, then its uses:
--- the shape a narrowing must survive or be refused for.
local function guarded_use(g: Gen, v: Vis, depth: integer)
  local pool = (g.src:int(0, 2) == 0 or #v.ints == 0) and FIELDS or v.ints
  local p = Fuzz.pick(g.src, pool)
  local form = g.src:int(0, 6)
  -- A function that clears the place, declared before the test: one declared
  -- inside the branch is dropped at a call for another reason (see the corpus).
  local helper: string | nil = nil
  if g.src:int(0, 2) == 0 then
    helper = fresh(g, "p")
    add(g, "local function " .. helper .. "() " .. p .. " = " .. Fuzz.pick(g.src, { "nil", "maybe()", "1" }) .. " end")
    v.procs[#v.procs + 1] = helper
  end
  local inner = nest(v)
  inner.focus[#inner.focus + 1] = p
  local close = true
  if form <= 1 then
    add(g, "if " .. p .. " then")
  elseif form == 2 then
    add(g, "if " .. p .. " ~= nil then")
  elseif form == 3 then
    add(g, "if " .. p .. " == nil then")
    add(g, "  " .. inner.ret)
    add(g, "end")
    close = false
  elseif form == 4 then
    add(g, "assert(" .. p .. ")")
    close = false
  elseif form == 5 then
    add(g, "if type(" .. p .. ") == \"number\" then")
  else
    add(g, "if " .. p .. " and maybe() then")
  end
  if close then g.depth = g.depth + 1 end
  local drops = g.src:int(0, 2)
  for _ = 1, drops do
    if helper ~= nil and g.src:int(0, 1) == 0 then
      add(g, helper .. "()")
    else
      dropper(g, inner, p)
    end
  end
  local wrote = false
  -- TODO: read a field in such a function too, once a function literal's body
  -- begins with none of the facts of the places outside it (the roadmap item,
  -- and the TODO at `narrowing.enter_function` in checker/narrowing.tl): the
  -- body is checked under the test, runs after the write, and the checker
  -- accepts `r.a + 1` there.
  if close and not p:find(".", 1, true) and g.src:int(0, 3) == 0 then
    -- A function that reads the place under the test, called after a write.
    local reader = fresh(g, "g")
    add(g, "local function " .. reader .. "(): integer return " .. p .. " + 1 end")
    add(g, p .. " = " .. Fuzz.pick(g.src, { "nil", "maybe()" }))
    add(g, "sink = sink + " .. reader .. "()")
    -- The write undid the test for what follows.
    inner.focus = {}
    wrote = true
  end
  local uses = wrote and 0 or g.src:int(1, 2)
  for _ = 1, uses do
    add(g, "sink = sink + " .. Fuzz.pick(g.src, { p .. " + 1", p, "(" .. p .. " or 0)", p .. " * 2" }))
  end
  if g.src:int(0, 2) == 0 and depth > 0 then stmt(g, inner, depth - 1) end
  if close then
    g.depth = g.depth - 1
    add(g, "end")
  else
    learn(v, { p }, NONE)
    for _ = 1, drops do
      if helper ~= nil and g.src:int(0, 1) == 0 then
        add(g, helper .. "()")
      else
        dropper(g, v, p)
      end
    end
    add(g, "sink = sink + " .. Fuzz.pick(g.src, { p .. " + 1", p, "(" .. p .. " or 0)" }))
  end
end

local function assert_stmt(g: Gen, v: Vis)
  local c = cond(g, v, 1, true)
  add(g, "assert(" .. c.text .. ")")
  learn(v, c.yes, c.ryes)
end

local function loop(g: Gen, v: Vis, depth: integer)
  local k = g.src:int(0, 6)
  if k == 5 then k = 1 end
  if k == 6 then k = 2 end
  local i = fresh(g, "i")
  local label: string | nil = nil
  if g.src:int(0, 2) > 0 then label = fresh(g, "next") end
  if k == 0 then
    local c = cond(g, v, 1)
    add(g, "local " .. i .. " = 0")
    add(g, "while " .. i .. " < 3 and (" .. c.text .. ") do")
    g.depth = g.depth + 1
    add(g, i .. " = " .. i .. " + 1")
    g.depth = g.depth - 1
    loop_body(g, v, depth - 1, label, c)
    add(g, "end")
  elseif k == 1 then
    local c = cond(g, v, 1)
    add(g, "local " .. i .. " = 0")
    add(g, "repeat")
    g.depth = g.depth + 1
    add(g, i .. " = " .. i .. " + 1")
    g.depth = g.depth - 1
    -- A `goto` to a label before `until` would jump into the scope of the
    -- locals the condition can see.
    loop_body(g, v, depth - 1, nil)
    add(g, "until " .. i .. " >= 3 or " .. c.text)
  elseif k == 2 then
    add(g, "for " .. i .. " = " .. Fuzz.pick(g.src, { "1, 3", "3, 1, -1", "1, 2", "0, 3, 2" }) .. " do")
    local inner = nest(v)
    local loopvar = fresh(g, "x")
    -- Not the index itself: nil is assignable to its type, `integer`, so a use after
    -- that write is no fault of the narrowing.
    add(g, "  local " .. loopvar .. ": integer | nil = " .. i)
    inner.ints[#inner.ints + 1] = loopvar
    loop_body(g, inner, depth - 1, label)
    add(g, "end")
  else
    local value = fresh(g, "x")
    local inner = nest(v)
    if k == 3 then
      -- Elements of type `integer`: a copy typed `integer | nil` is the place, since nil is
      -- assignable to `integer` and a use after that is no fault of the checker's.
      local element = fresh(g, "e")
      add(g, "for _, " .. element .. " in ipairs(nums) do")
      add(g, "  local " .. value .. ": integer | nil = " .. element)
    else
      add(g, "for _, " .. value .. " in ipairs(opts) do")
    end
    inner.ints[#inner.ints + 1] = value
    loop_body(g, inner, depth - 1, label)
    add(g, "end")
  end
end

stmt = function(g: Gen, v: Vis, depth: integer)
  local k = g.src:int(0, 39)
  if k >= 28 and not g.calm then return guarded_use(g, v, depth) end
  if k >= 28 and k <= 30 then k = 7 + k % 3 end
  if k >= 31 then k = 15 + k % 5 end
  if k <= 2 then return declare(g, v) end
  if k <= 5 then return assign(g, v) end
  if k == 6 then return add(g, "sink = sink + " .. int_expr(g, v)) end
  if k <= 10 and depth > 0 then return if_chain(g, v, depth) end
  if k <= 12 then return assert_stmt(g, v) end
  if k <= 14 then return early_exit(g, v) end
  if k <= 19 and depth > 0 then return loop(g, v, depth) end
  if k == 20 then
    local name = fresh(g, "o")
    add(g, "local " .. name .. ": R | nil = pick()")
    v.recs[#v.recs + 1] = name
    return
  end
  if k == 21 then return proc(g, v) end
  if k == 22 and #v.procs > 0 then return add(g, Fuzz.pick(g.src, v.procs) .. "()") end
  if k == 23 then return add(g, "touch(" .. Fuzz.pick(g.src, { "r", "s" }) .. ")") end
  if k == 24 and depth > 0 then return fun(g, v, depth) end
  if k == 25 and #v.funs > 0 then
    return add(g, "sink = sink + " .. Fuzz.pick(g.src, v.funs) .. "(" .. place(g, v) .. ")")
  end
  if k >= 26 and v.cont ~= nil then
    return add(g, "if " .. cond(g, v, 1).text .. " then goto " .. (v.cont as string) .. " end")
  end
  if k >= 26 and v.in_loop then
    return add(g, "if " .. cond(g, v, 1).text .. " then break end")
  end
  return add(g, "sink = sink + " .. int_expr(g, v))
end

--- A well-formed program: the header, statements, and `return sink`.
local function gen_program(src: Fuzz.Source): string
  local g: Gen = { src = src, lines = {}, id = 0, fuel = 45, depth = 0, calm = src:int(0, 1) == 0 }
  local text = header(src:int(0, 2))
  local v: Vis = { ints = {}, recs = {}, procs = {}, funs = {}, focus = {}, rfocus = {},
    in_loop = false, cont = nil, ret = "return sink" }
  -- Two locals to begin with, so that the draws have places to test.
  for _ = 1, 2 do
    local name = fresh(g, "x")
    add(g, "local " .. name .. ": integer | nil = " .. opt_expr(g, v))
    v.ints[#v.ints + 1] = name
  end
  local n = 0
  while g.fuel > 0 and Fuzz.more(src, n, 8) do
    n = n + 1
    stmt(g, v, 3)
  end
  g.lines[#g.lines + 1] = "return sink"
  return text .. table.concat(g.lines, "\n") .. "\n"
end

--- A program, one in three edited at random bytes.
local function gen_any(src: Fuzz.Source): string
  local text = gen_program(src)
  if src:int(0, 2) == 0 then
    return Fuzz.mutate(src, text, 3)
  end
  return text
end

--------------------------------------------------------------------------------
-- Properties
--------------------------------------------------------------------------------

--- The most inputs a deep run draws, whatever `FUZZ_ITERS` asks. A test has
--- 30 seconds. At `FUZZ_ITERS=10000` this module took 11 to 23 seconds with
--- this cap (500), and 22 to 30 with 1000, on four shared cores, about 4 of
--- them startup; a larger cap risks the deadline.
local MAX_ITERS <const> = 500

local function count_lines(text: string): integer
  local _, n = text:gsub("\n", "\n")
  return n + 1
end

--- Why an error is not one a reader could act on, or nil.
local function malformed(e: compiler.Error, lines: integer): string | nil
  if e.code == nil then return "no code: " .. e.msg end
  if e.msg == nil or e.msg == "" then return "no message for code " .. e.code end
  if e.y < 1 or e.y > lines or e.x < 1 then
    return ("%s at %d:%d, outside a source of %d lines: %s"):format(e.code, e.y, e.x, lines, e.msg)
  end
  return nil
end

local function never_raises(source: string): boolean, string
  local ok, code, result = pcall(check, source)
  if not ok then
    return false, "the checker raised: " .. tostring(code) .. "\n--- program ---\n" .. source
  end
  local r = result as compiler.Result
  if code == nil then
    if #r.syntax_errors == 0 then
      return false, "no code and no syntax error\n--- program ---\n" .. source
    end
    Fuzz.label("syntax error")
  elseif #r.type_errors == 0 then
    Fuzz.label("accepted")
  else
    Fuzz.label("refused")
  end
  local lines = count_lines(source)
  for _, list in ipairs({ r.syntax_errors, r.type_errors }) do
    for _, e in ipairs(list) do
      local why = malformed(e, lines)
      if why then return false, why .. "\n--- program ---\n" .. source end
    end
  end
  return true, ""
end

--- Constructs a program that ran is said to have exercised.
local CONSTRUCTS <const>: {{string}} = {
  { "while", "while " },
  { "repeat", "repeat" },
  { "numeric for", "for %w+ = " },
  { "generic for", "for _, " },
  { "goto", "goto next" },
  { "break", "break" },
  { "assert", "assert%(" },
  { "function literal", "local function [pfg]%d" },
  { "early exit", "then return sink end" },
  { "elseif", "elseif " },
}

local NIL_FAULT <const> = "attempt to"

local function runs_safely(source: string): boolean, string
  local ok, code, result = pcall(check, source)
  if not ok then
    return false, "the checker raised: " .. tostring(code) .. "\n--- program ---\n" .. source
  end
  local r = result as compiler.Result
  if code == nil or #r.syntax_errors > 0 or #r.type_errors > 0 then
    Fuzz.label("refused")
    return true, ""
  end
  Fuzz.label("accepted")
  if source:find("assert%(") then Fuzz.label("accepted with assert") end
  local env: {string:any} = { assert = assert, ipairs = ipairs, tostring = tostring, type = type }
  local chunk, why = load(code, "=fuzz", "t", env)
  if chunk == nil then
    return false, "the checker accepted a program whose Lua does not load: " .. tostring(why) ..
      "\n--- program ---\n" .. source
  end
  local ran, err = pcall(chunk)
  if ran then
    Fuzz.label("ran")
    for _, c in ipairs(CONSTRUCTS) do
      if source:find(c[2]) then Fuzz.label("ran with " .. c[1]) end
    end
    return true, ""
  end
  local message = tostring(err)
  if message:find("assertion failed", 1, true) then
    Fuzz.label("stopped by assert")
    return true, ""
  end
  local what = message:find(NIL_FAULT, 1, true) and "accepted a program that fails at run time: " or
    "an accepted program raised: "
  return false, what .. message .. "\n--- program ---\n" .. source
end

local function test_the_checker_never_raises_and_places_its_errors(tmp: string)
  Fuzz.run({
    name = "checker total",
    dir = tmp,
    gen = gen_any,
    check = never_raises,
    max_iters = MAX_ITERS,
    requires = { "accepted", "refused", "syntax error" },
    shares = { accepted = 0.05, refused = 0.1 },
  })
end

local function test_an_accepted_program_does_not_fail_on_a_nil(tmp: string)
  Fuzz.run({
    name = "checker sound",
    dir = tmp,
    gen = gen_program,
    check = runs_safely,
    max_iters = MAX_ITERS,
    requires = { "accepted", "ran", "refused", "ran with while", "ran with repeat", "ran with numeric for",
      "ran with generic for", "ran with goto", "ran with break", "ran with assert",
      "ran with function literal", "ran with early exit", "ran with elseif" },
    shares = { accepted = 0.2 },
  })
end

--------------------------------------------------------------------------------
-- The corpus
--------------------------------------------------------------------------------

local record Case
  name: string
  expect: string
  source: string
end

--- What a program has to say of the checker: `accepted`, `refused: ` and
--- the codes of its type errors in order, or `syntax: ` and those of its
--- syntax errors.
local function verdict(source: string): string
  local ok, code, result = pcall(check, source)
  if not ok then
    return "raised: " .. tostring(code)
  end
  local r = result as compiler.Result
  local codes: {string} = {}
  for _, e in ipairs(code == nil and r.syntax_errors or r.type_errors) do
    codes[#codes + 1] = tostring(e.code)
  end
  table.sort(codes)
  if code == nil then return "syntax: " .. table.concat(codes, ",") end
  if #codes == 0 then return "accepted" end
  return "refused: " .. table.concat(codes, ",")
end

--- The places most cases read: a record with an optional field, a local
--- of type `integer | nil`, a function that may write the field and one
--- that answers a number or nil.
local HEAD <const> = table.concat({
  "local record R",
  "  a: integer | nil",
  "  n: integer",
  "end",
  "local r: R = { n = 0 }",
  "local function maybe(): integer | nil return nil end",
  "local x: integer | nil = maybe()",
  "local y: integer | nil = maybe()",
  "local function touch(t: R) t.a = nil end",
  "",
}, "\n")

--- Programs chosen for what they cover, each with the verdict it has
--- today. A verdict changes on purpose: the change that makes the checker
--- take or refuse one of these edits its line.
local CORPUS <const>: {Case} = {
  -- Accepted: what narrowing is for.
  { name = "assignment narrows a local", expect = "accepted",
    source = "local v: integer | nil = 1\nprint(v + 1)\n" },
  { name = "a truthy test narrows", expect = "accepted",
    source = HEAD .. "if x then print(x + 1) end\n" },
  { name = "a nil test narrows both ways", expect = "accepted",
    source = HEAD .. "if x == nil then print(0) else print(x + 1) end\n" },
  { name = "a negated test narrows", expect = "accepted",
    source = HEAD .. "if not x then print(0) else print(x + 1) end\n" },
  { name = "an early return narrows the rest", expect = "accepted",
    source = HEAD .. "local function f(): integer\n  if x == nil then return 0 end\n  return x + 1\nend\nprint(f)\n" },
  { name = "assert narrows", expect = "accepted",
    source = HEAD .. "assert(x)\nprint(x + 1)\n" },
  { name = "or gives a default", expect = "accepted",
    source = HEAD .. "local n: integer = x or 0\nprint(n + 1)\n" },
  { name = "and narrows its right side", expect = "accepted",
    source = HEAD .. "print(x and x + 1)\n" },
  { name = "both of two tests", expect = "accepted",
    source = HEAD .. "if x and y then print(x + y) end\n" },
  { name = "an elseif chain", expect = "accepted",
    source = HEAD .. "if x == nil then print(1) elseif y == nil then print(x + 1) else print(x + y) end\n" },
  { name = "an early exit of two tests", expect = "accepted",
    source = HEAD .. "if x == nil then return elseif y == nil then return end\nprint(x + y)\n" },
  { name = "a field test narrows the field", expect = "accepted",
    source = HEAD .. "if r.a then print(r.a + 1) end\n" },
  { name = "assert narrows a field", expect = "accepted",
    source = HEAD .. "assert(r.a)\nprint(r.a + 1)\n" },
  { name = "a write of another field keeps it", expect = "accepted",
    source = HEAD .. "if r.a then\n  r.n = 1\n  print(r.a + 1)\nend\n" },
  { name = "a call that runs nothing of ours keeps it", expect = "accepted",
    source = HEAD .. "if r.a then\n  print(1)\n  print(r.a + 1)\nend\n" },
  { name = "an unrelated function declared before the test keeps it", expect = "accepted",
    source = HEAD .. "local function own() local z: integer | nil = nil z = 1 print(z) end\nif x then\n  own()\n  print(x + 1)\nend\n" },
  { name = "a type test narrows a union", expect = "accepted",
    source = "local function f(u: string | number)\n  if type(u) == \"number\" then print(u + 1) else print(#u) end\nend\nprint(f)\n" },
  { name = "is narrows a union", expect = "accepted",
    source = "local function f(u: string | number | nil)\n  if u is number then print(u + 1) end\nend\nprint(f)\n" },
  { name = "a while test holds in its body", expect = "accepted",
    source = HEAD .. "local i = 0\nwhile x and i < 3 do\n  i = i + 1\n  print(x + i)\nend\n" },
  { name = "repeat until with a break", expect = "accepted",
    source = HEAD .. "local i = 0\nrepeat\n  i = i + 1\n  if i > 1 then break end\nuntil i >= 3\nprint(i)\n" },
  { name = "numeric for with a guarded use", expect = "accepted",
    source = HEAD .. "for i = 1, 3 do\n  if x then print(x + i) end\nend\n" },
  { name = "generic for over an array of optionals", expect = "accepted",
    source = "local opts: {integer | nil} = { 1, 2 }\nfor _, v in ipairs(opts) do\n  if v then print(v + 1) end\nend\n" },
  { name = "goto continue", expect = "accepted",
    source = HEAD .. "for i = 1, 3 do\n  if i == 2 then goto next end\n  print(i)\n  ::next::\nend\n" },

  -- Refused: the checker holds a use to what the program has shown.
  -- TODO: accept this once a call to a function declared inside the narrowed
  -- branch drops only what its body can assign: it drops `x` though its
  -- body assigns nothing of it.
  { name = "a function declared inside the branch drops it at a call", expect = "refused: operator_binary",
    source = HEAD .. "if x then\n  local function own() print(1) end\n  own()\n  print(x + 1)\nend\n" },
  { name = "an unguarded optional is no number", expect = "refused: operator_binary",
    source = HEAD .. "print(x + 1)\n" },
  { name = "or of two tests narrows neither", expect = "refused: operator_binary",
    source = HEAD .. "if x or y then print(x + 1) end\n" },
  { name = "a nil test without an exit narrows nothing after", expect = "refused: operator_binary",
    source = HEAD .. "if x == nil then print(1) end\nprint(x + 1)\n" },
  { name = "an assignment widens the local again", expect = "refused: narrowing_dropped",
    source = HEAD .. "if x then\n  x = maybe()\n  print(x + 1)\nend\n" },
  { name = "a call drops a narrowed field", expect = "refused: narrowing_dropped",
    source = HEAD .. "if r.a then\n  touch(r)\n  print(r.a + 1)\nend\n" },
  { name = "a write of the field drops it", expect = "refused: narrowing_dropped",
    source = HEAD .. "if r.a then\n  r.a = nil\n  print(r.a + 1)\nend\n" },
  { name = "a write through another reference drops it", expect = "refused: narrowing_dropped",
    source = HEAD .. "local p: R = { n = 1 }\nif r.a then\n  p.a = nil\n  print(r.a + 1)\nend\n" },
  { name = "a function literal assigning the local drops it at a call", expect = "refused: narrowing_dropped",
    source = HEAD .. "local function reset() x = nil end\nif x then\n  reset()\n  print(x + 1)\nend\n" },
  { name = "a later write in a loop widens it at the top", expect = "refused: operator_binary",
    source = HEAD .. "if x then\n  while maybe() do\n    print(x + 1)\n    x = nil\n  end\nend\n" },
  -- TODO: accept this once `type(x) == "..."` guards a field: it waits on the
  -- roadmap item that makes every guard read every place alike
  -- (checker/narrowing.tl).
  { name = "a field under type() is not narrowed yet", expect = "refused: operator_binary",
    source = HEAD .. "if type(r.a) == \"number\" then print(r.a + 1) end\n" },
  -- TODO: accept this once the left operand of `and` guards a field: it waits
  -- on the roadmap item that makes every guard read every place alike
  -- (checker/narrowing.tl).
  { name = "a field on the left of and is not narrowed yet", expect = "refused: operator_binary",
    source = HEAD .. "print(r.a and r.a + 1)\n" },
  { name = "a string is no integer", expect = "refused: mismatch",
    source = "local n: integer = \"a\"\nprint(n)\n" },
  { name = "an unknown variable", expect = "refused: unknown_variable",
    source = "print(nope)\n" },
  { name = "too many arguments", expect = "refused: arity",
    source = "local function f(a: integer) print(a) end\nf(1, 2)\n" },
  { name = "a key the record lacks", expect = "refused: invalid_key",
    source = HEAD .. "r.zzz = 1\n" },
  { name = "an unknown type", expect = "refused: unknown_type",
    source = "local v: Nope = nil\nprint(v)\n" },
  { name = "ipairs of a number", expect = "refused: not_array,unknown_variable",
    source = "local n: integer = 1\nfor _, v in ipairs(n) do print(v) end\n" },
  { name = "an optional bound", expect = "refused: for_bound",
    source = HEAD .. "for i = x, 2 do print(i) end\n" },

  -- TODO: refuse these two once the checker reads the true branch of `a or b`
  -- as nothing where `b` gives no guard (checker/narrowing.tl `evaluate`
  -- reads it as `not a`); `cond` above holds the details. Each is accepted
  -- and fails at run time when `x` is nil.
  -- TODO: refuse this once a function literal's body begins with none of the
  -- facts of the places outside it (the roadmap item, and the TODO at
  -- `narrowing.enter_function` in checker/narrowing.tl): `g` reads `r.a` under
  -- the test, runs after `r.a = nil`, and fails at run time. The same body
  -- over a local is refused.
  { name = "a function declared under a field test reads it after a write", expect = "accepted",
    source = HEAD .. "if r.a then\n  local function g(): integer return r.a + 1 end\n  r.a = nil\n  print(g())\nend\n" },
  { name = "a function declared under a local test reads it after a write", expect = "refused: operator_binary",
    source = HEAD .. "if x then\n  local function g(): integer return x + 1 end\n  x = nil\n  print(g())\nend\n" },
  { name = "assert of an or narrows its left side by mistake", expect = "accepted",
    source = HEAD .. "assert(x == nil or y)\nprint(x + 1)\n" },
  { name = "an or with a call on its right narrows its left side by mistake", expect = "accepted",
    source = HEAD .. "if x == nil or maybe() then print(x + 1) end\n" },

  -- Syntax errors, and programs that once raised in the checker.
  { name = "an expression missing", expect = "syntax: other",
    source = "local x: integer =\n" },
  { name = "an end missing", expect = "syntax: syntax_error",
    source = "if x then\n" },
  { name = "a type for the first of two names", expect = "refused: other,unknown_variable",
    source = "local x: integer | nil, y = 1, 2\nprint(x, y)\n" },
  { name = "a narrowed field written, then a function reassigned", expect = "accepted",
    source = HEAD .. "assert(r.a)\nr.a = 1\nlocal g = function() end\ng = function() print(g) end\n" },
  { name = "a narrowed field written, then read", expect = "refused: narrowing_dropped",
    source = HEAD .. "assert(r.a)\nr.a = nil\nprint(r.a + 1)\n" },
}

local function test_the_checker_keeps_its_verdict_on_each_program_of_the_corpus()
  local seen: {string:boolean} = {}
  local changed: {string} = {}
  local accepted, refused = 0, 0
  for _, case in ipairs(CORPUS) do
    assert(not seen[case.name], "the corpus names '" .. case.name .. "' twice")
    seen[case.name] = true
    local now = verdict(case.source)
    if now ~= case.expect then
      changed[#changed + 1] = ("'%s' was %s and is now %s:\n%s"):format(case.name, case.expect, now, case.source)
    end
    if case.expect == "accepted" then accepted = accepted + 1 else refused = refused + 1 end
  end
  assert(accepted > 10 and refused > 10, "the corpus holds too few of one verdict")
  assert(#changed == 0, "the checker's verdict changed; edit CORPUS in build/checker_fuzz_test.tl if on purpose:\n" .. table.concat(changed, "\n"))
end
