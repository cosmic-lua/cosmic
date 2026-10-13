--- The programs build/checker_fuzz_test.tl draws, and the draws that reach
--- them: the generator of the checker's fuzz properties, which
--- [`build.checker_verdicts`] also uses to write the same programs to files
--- for two checkers to read. The properties hold what the checker does with
--- them.
---
--- [`programs.drawn`] repeats [`Fuzz.run`]'s seeding (`FUZZ_SEED` makes
--- one source of cases, each case its own source of draws), which
--- build/checker_verdicts_test.tl holds it to: seed `s` and iteration `i`
--- here are the input `FUZZ_SEED=s FUZZ_ITERS=i` checks there.
local Fuzz = require("build.fuzz")
local Rand = require("cosmic.rand")

--- What the program at a point of the draw can name: the locals of type
--- `integer | nil` (`ints`), of type `R | nil` (`recs`), the functions
--- that take nothing and write fields (`procs`), and those that take an
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
  --- The locals of `ints` declared outside the function being drawn, which
  --- it may read and not assign.
  outer: {string}
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
  --- A loop that has a label takes a `goto` to it first.
  want_goto: boolean
  --- The labels a `goto` has been drawn for: a label nothing continues to
  --- is refused, so one is written only for them.
  jumped: {string:boolean}
  --- Depth of the function bodies the draw is inside.
  fn: integer
  --- Whether the program holds a function that assigns a local declared
  --- outside it, which the checker must refuse.
  captures: boolean
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
    "local record State",
    "  count: integer",
    "  sink: integer",
    "end",
    "local st: State = { count = " .. seed .. ", sink = 0 }",
    "local nums: {integer} = { 1, 2, 3 }",
    "local opts: {integer | nil} = { 1, 2, 3 }",
    "local function maybe(): integer | nil",
    "  st.count = st.count + 1",
    "  if st.count % 3 == 0 then return nil end",
    "  return st.count",
    "end",
    "local function pick(): R | nil",
    "  st.count = st.count + 1",
    "  if st.count % 3 == 0 then return nil end",
    "  if st.count % 2 == 0 then return r end",
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

local function has(list: {string}, s: string): boolean
  for _, e in ipairs(list) do
    if e == s then return true end
  end
  return false
end

--- A scope nested in `v`: what its block declares or learns goes when it ends.
local function nest(v: Vis): Vis
  return {
    ints = dup(v.ints), recs = dup(v.recs), procs = dup(v.procs), funs = dup(v.funs),
    focus = dup(v.focus), rfocus = dup(v.rfocus), outer = dup(v.outer),
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

--- A place to write: a field, or a local the function being drawn declares
--- (a function may not assign one it does not).
local function target(g: Gen, v: Vis): string
  local choices: {string} = {}
  for _, p in ipairs(places(v)) do
    if not has(v.outer, p) then choices[#choices + 1] = p end
  end
  return Fuzz.pick(g.src, choices)
end

--- `p` itself where the function being drawn may assign it, else a field.
local function writable(g: Gen, v: Vis, p: string): string
  if has(v.outer, p) then return Fuzz.pick(g.src, FIELDS) end
  return p
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

--- An expression of type `integer | nil`, whichever its form: a local
--- declared from it without a type has that type, where `nil` or a literal
--- would give one that nil is assignable to by the language's own rule.
local function typed_expr(g: Gen, v: Vis): string
  local k = g.src:int(0, 2)
  if k == 0 then return "maybe()" end
  if k == 1 then return "id(" .. place(g, v) .. ")" end
  return "(" .. place(g, v) .. " or nil)"
end

--- An expression of type `integer`: some use a place that must have been
--- narrowed.
--- A place as an operand of `integer` arithmetic: bare when a guard names it,
--- otherwise mostly given a default, so that the draws are not all refused.
local function operand(g: Gen, v: Vis): string
  local p = place(g, v)
  if has(v.focus, p) then return p end
  if not g.calm and g.src:int(0, 1) == 0 then return p end
  return "(" .. p .. " or 0)"
end

local function int_expr(g: Gen, v: Vis): string
  local k = g.src:int(0, 12)
  if k == 0 then return tostring(g.src:int(0, 3)) end
  if k == 1 then return "st.count" end
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
    return { text = "st.count % 2 == 0", yes = NONE, no = NONE, ryes = NONE, rno = NONE, guarded = false }
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

--- A test of up to `depth` levels. An `or` tells nothing when it holds, and
--- when it does not hold, what both sides tell.
local function cond(g: Gen, v: Vis, depth: integer): Cond
  local k = depth <= 0 and 0 or g.src:int(0, 5)
  if k <= 2 then return atom(g, v) end
  if k == 3 then
    local a, b = cond(g, v, depth - 1), cond(g, v, depth - 1)
    return { text = a.text .. " and " .. b.text, yes = union_of(a.yes, b.yes), no = NONE,
      ryes = union_of(a.ryes, b.ryes), rno = NONE, guarded = a.guarded or b.guarded }
  end
  if k == 4 then
    local a, b = cond(g, v, depth - 1), cond(g, v, depth - 1)
    return { text = a.text .. " or " .. b.text, yes = NONE, no = union_of(a.no, b.no),
      ryes = NONE, rno = union_of(a.rno, b.rno), guarded = true }
  end
  local a = cond(g, v, depth - 1)
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

--- A `goto` to `label`, the label that ends the body of the loop around it.
local function jump(g: Gen, label: string): string
  g.jumped[label] = true
  return "goto " .. label
end

--- A loop body: the statements, then the label a `goto` skips to, when one
--- was drawn.
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
  if g.want_goto or g.src:int(0, 1) == 0 then
    local c = cond(g, inner, 1)
    add(g, "if " .. c.text .. " then " .. (label ~= nil and (g.want_goto or g.src:int(0, 1) == 0) and jump(g, label) or "break") .. " end")
  end
  local n = 0
  while g.fuel > 0 and Fuzz.more(g.src, n, 4) do
    n = n + 1
    stmt(g, inner, depth)
  end
  if label and g.jumped[label] then
    g.depth = g.depth - 1
    add(g, "::" .. label .. "::")
    g.depth = g.depth + 1
  end
  g.depth = g.depth - 1
end

--- A function that writes fields (it may not assign a local it does not
--- declare): nil, or what `maybe` answers.
local function proc(g: Gen, outside: Vis)
  local name = fresh(g, "p")
  add(g, "local function " .. name .. "()")
  local v = nest(outside)
  v.outer = dup(outside.ints)
  g.depth = g.depth + 1
  g.fn = g.fn + 1
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
  g.fn = g.fn - 1
  g.depth = g.depth - 1
  add(g, "end")
  outside.procs[#outside.procs + 1] = name
end

--- A function of an `integer | nil` parameter, whose body is drawn like
--- the program's and which calls only what was declared before it.
local function fun(g: Gen, v: Vis, depth: integer)
  local name, param = fresh(g, "f"), fresh(g, "x")
  add(g, "local function " .. name .. "(" .. param .. ": integer | nil): integer")
  local inner = nest(v)
  inner.in_loop = false
  inner.cont = nil
  inner.ret = "return st.sink"
  inner.outer = dup(v.ints)
  inner.ints[#inner.ints + 1] = param
  -- The body is checked where it is made, though it runs wherever it is
  -- called: it begins with none of the tests around it that may change.
  g.depth = g.depth + 1
  g.fn = g.fn + 1
  if g.src:int(0, 2) == 0 then
    -- A parameter tested, read by a function made after the test, and
    -- assigned after that: the function runs after the write.
    local reader = fresh(g, "g")
    add(g, "if " .. param .. " == nil then return st.sink end")
    add(g, "local " .. reader .. " = function(): integer return " .. param .. " + 1 end")
    add(g, param .. " = " .. Fuzz.pick(g.src, { "nil", "maybe()", "1" }))
    add(g, "st.sink = st.sink + " .. reader .. "()")
  end
  local n = 0
  while g.fuel > 0 and Fuzz.more(g.src, n, 4) do
    n = n + 1
    stmt(g, inner, depth + 1)
  end
  add(g, "return st.sink")
  g.fn = g.fn - 1
  g.depth = g.depth - 1
  add(g, "end")
  v.funs[#v.funs + 1] = name
end

local function declare(g: Gen, v: Vis)
  local k = g.src:int(0, 12)
  local name = fresh(g, "x")
  if k == 12 and #v.ints > 0 then
    -- A copy of a local under its own name: it has the type the original has
    -- here, which a test of the original may have narrowed.
    local p = Fuzz.pick(g.src, v.ints)
    -- Mostly of a local a test around the point narrowed, in the scope that
    -- declared it or a scope inside.
    local tested: {string} = {}
    for _, f in ipairs(v.focus) do
      if not f:find(".", 1, true) then tested[#tested + 1] = f end
    end
    if #tested > 0 and g.src:int(0, 2) > 0 then p = Fuzz.pick(g.src, tested) end
    add(g, "local " .. p .. (g.src:int(0, 1) == 0 and "" or ": integer | nil") .. " = " .. p)
    return
  end
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
    add(g, "local " .. name .. ", " .. other .. " = " .. typed_expr(g, v) .. ", " .. typed_expr(g, v))
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

local function if_chain(g: Gen, v: Vis, depth: integer, min_arms?: integer)
  local first = cond(g, v, 2)
  add(g, "if " .. first.text .. " then")
  block(g, v, depth - 1, 4, first)
  local seen: {Cond} = { first }
  local arms = 0
  while g.fuel > 0 and (arms < (min_arms or 0) or Fuzz.more(g.src, arms, 2)) do
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
  local cont = v.cont
  if how == 0 and v.in_loop then
    leave = "break"
  elseif how == 1 and cont ~= nil then
    leave = jump(g, cont)
  else
    leave = v.ret
  end
  add(g, "if not (" .. c.text .. ") then " .. leave .. " end")
  learn(v, c.yes, c.ryes)
end

--- What a function made to clear `p` writes: `p` itself when it is a field, and
--- else, a local being no function's to assign, either a field or, drawn
--- only to be refused (`g.captures`), the local.
local function cleared(g: Gen, p: string): string
  if p:find(".", 1, true) then return p end
  if g.src:int(0, 1) == 0 then
    g.captures = true
    return p
  end
  return Fuzz.pick(g.src, FIELDS)
end

--- Something that may or may not clear `p`: a call that runs other code,
--- a write, a function literal made and called, a loop that writes it.
local function dropper(g: Gen, v: Vis, p: string)
  local k = g.src:int(0, 13)
  if k <= 2 then
    add(g, "touch(" .. Fuzz.pick(g.src, { "r", "s" }) .. ")")
  elseif k == 3 then
    add(g, writable(g, v, p) .. " = " .. opt_expr(g, v))
  elseif k == 4 then
    add(g, target(g, v) .. " = " .. opt_expr(g, v))
  elseif k == 5 then
    local name = fresh(g, "p")
    add(g, "local function " .. name .. "() " .. cleared(g, p) .. " = " .. Fuzz.pick(g.src, { "nil", "maybe()" }) .. " end")
    if g.src:int(0, 4) > 0 then add(g, name .. "()") end
    v.procs[#v.procs + 1] = name
  elseif k == 6 and #v.procs > 0 then
    add(g, Fuzz.pick(g.src, v.procs) .. "()")
  elseif k == 7 then
    add(g, "id(" .. place(g, v) .. ")")
  elseif k == 8 then
    add(g, "while maybe() and st.count % 5 ~= 0 do " .. writable(g, v, p) .. " = maybe() end")
  elseif k == 9 then
    add(g, "for _ = 1, 2 do " .. writable(g, v, p) .. " = " .. opt_expr(g, v) .. " end")
  elseif k == 10 and #v.funs > 0 then
    add(g, "st.sink = st.sink + " .. Fuzz.pick(g.src, v.funs) .. "(" .. place(g, v) .. ")")
  elseif k == 11 then
    add(g, "st.sink = st.sink + (maybe() or 0) + " .. p)
  elseif k == 12 then
    add(g, "local " .. fresh(g, "x") .. " = " .. place(g, v))
  else
    add(g, "r.n = r.n + 1")
  end
end

--- A test of one place, then something that may clear it, then its uses:
--- the shape a narrowing must survive or be refused for.
local function guarded_use(g: Gen, v: Vis, depth: integer)
  local pool = (g.src:int(0, 1) == 0 or #v.ints == 0) and FIELDS or v.ints
  local p = Fuzz.pick(g.src, pool)
  local form = g.src:int(0, 6)
  -- A function that clears the place, declared before the test: one declared
  -- inside the branch is dropped at a call for another reason
  -- (build/checker_narrowing_test.tl pins that limit).
  local helper: string | nil = nil
  if g.src:int(0, 1) == 0 then
    helper = fresh(g, "p")
    add(g, "local function " .. helper .. "() " .. cleared(g, p) .. " = " .. Fuzz.pick(g.src, { "nil", "maybe()", "1" }) .. " end")
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
  if close then
    g.depth = g.depth + 1
  else
    -- What follows the test is held to it from here on.
    learn(v, { p }, NONE)
  end
  local drops = g.src:int(helper ~= nil and 1 or 0, 2)
  for _ = 1, drops do
    if helper ~= nil and g.src:int(0, 3) > 0 then
      add(g, helper .. "()")
    else
      dropper(g, inner, p)
    end
  end
  local wrote = false
  if close and not has(v.outer, p) and g.src:int(0, 3) == 0 then
    -- A function that reads the place under the test, called after a write.
    local reader = fresh(g, "g")
    add(g, "local function " .. reader .. "(): integer return " .. p .. " + 1 end")
    add(g, p .. " = " .. Fuzz.pick(g.src, { "nil", "maybe()" }))
    add(g, "st.sink = st.sink + " .. reader .. "()")
    -- The write undid the test for what follows.
    inner.focus = {}
    wrote = true
  end
  local uses = wrote and 0 or g.src:int(1, 2)
  for _ = 1, uses do
    add(g, "st.sink = st.sink + " .. Fuzz.pick(g.src, { p .. " + 1", p, "(" .. p .. " or 0)", p .. " * 2" }))
  end
  if g.src:int(0, 2) == 0 and depth > 0 then stmt(g, inner, depth - 1) end
  if close then
    g.depth = g.depth - 1
    add(g, "end")
  else
    for _ = 1, drops do
      if helper ~= nil and g.src:int(0, 3) > 0 then
        add(g, helper .. "()")
      else
        dropper(g, v, p)
      end
    end
    add(g, "st.sink = st.sink + " .. Fuzz.pick(g.src, { p .. " + 1", p, "(" .. p .. " or 0)" }))
  end
end

local function assert_stmt(g: Gen, v: Vis)
  local c = cond(g, v, 1)
  add(g, "assert(" .. c.text .. ")")
  learn(v, c.yes, c.ryes)
end

local function loop(g: Gen, v: Vis, depth: integer, kind?: integer, labelled?: boolean)
  local k = kind or g.src:int(0, 6)
  if k == 5 then k = 1 end
  if k == 6 then k = 2 end
  local i = fresh(g, "i")
  local label: string | nil = nil
  if labelled or g.src:int(0, 2) > 0 then label = fresh(g, "next") end
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
  if k == 6 then return add(g, "st.sink = st.sink + " .. int_expr(g, v)) end
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
    return add(g, "st.sink = st.sink + " .. Fuzz.pick(g.src, v.funs) .. "(" .. place(g, v) .. ")")
  end
  local cont = v.cont
  if k >= 26 and cont ~= nil then
    return add(g, "if " .. cond(g, v, 1).text .. " then " .. jump(g, cont) .. " end")
  end
  if k >= 26 and v.in_loop then
    return add(g, "if " .. cond(g, v, 1).text .. " then break end")
  end
  return add(g, "st.sink = st.sink + " .. int_expr(g, v))
end

--- The line that ends a program holding a function that assigns a local
--- declared outside it, which the checker must refuse as such.
local CAPTURES_MARK <const> = "-- captures\n"

--- A well-formed program: the header, statements, and `return sink`.
local function gen_program(src: Fuzz.Source): string
  local g: Gen = { src = src, lines = {}, id = 0, fuel = 45, depth = 0, calm = src:int(0, 3) == 0, want_goto = false,
    jumped = {}, fn = 0, captures = false }
  local text = header(src:int(0, 2))
  local v: Vis = { ints = {}, recs = {}, procs = {}, funs = {}, focus = {}, rfocus = {}, outer = {},
    in_loop = false, cont = nil, ret = "return st.sink" }
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
  if g.calm then
    -- A calm program ends with the constructs the property wants to have run:
    -- a chain with an `elseif`, a loop, a guard that leaves.
    g.fuel = 20
    if_chain(g, v, 2, 1)
    g.want_goto = true
    loop(g, v, 2, 0, true)
    g.want_goto = false
    loop(g, v, 2, 2)
    loop(g, v, 2)
    early_exit(g, v)
  end
  g.lines[#g.lines + 1] = "return st.sink"
  return text .. table.concat(g.lines, "\n") .. "\n" .. (g.captures and CAPTURES_MARK or "")
end

--- A program, one in three edited at random bytes.
local function gen_any(src: Fuzz.Source): string
  local text = gen_program(src)
  if src:int(0, 2) == 0 then
    return Fuzz.mutate(src, text, 3)
  end
  return text
end

local record programs
  --- The line that ends a program holding a function that assigns a local
  --- declared outside it, which the checker must refuse as such.
  captures_mark: string
  --- A well-formed program: the generator of the soundness property.
  well_formed: function(Fuzz.Source): string
  --- A well-formed program, one in three edited at random bytes: the
  --- generator of the totality property.
  any: function(Fuzz.Source): string
  --- The programs of one property for `FUZZ_SEED=seed` and iterations 1
  --- through `iters`: `kind` is `"total"` or `"sound"`, named for the
  --- property whose generator draws them. Raises on another kind.
  drawn: function(kind: string, seed: integer, iters: integer): {string}
end

programs.captures_mark = CAPTURES_MARK
programs.well_formed = gen_program
programs.any = gen_any

function programs.drawn(kind: string, seed: integer, iters: integer): {string}
  local gen: function(Fuzz.Source): string
  if kind == "total" then
    gen = gen_any
  elseif kind == "sound" then
    gen = gen_program
  else
    error("checker programs: " .. kind .. " is neither total nor sound", 2)
  end
  local out: {string} = {}
  local seeds = Rand.new(seed)
  for i = 1, iters do
    local rng = Rand.new(seeds:int(math.mininteger, math.maxinteger))
    local src: Fuzz.Source = {}
    src.int = function(_self: Fuzz.Source, min: integer, max: integer): integer
      return rng:int(min, max)
    end
    out[i] = gen(src)
  end
  return out
end

return programs
