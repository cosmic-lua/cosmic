--- Definite assignment, held to the semantics it is a rule about. A program
--- of branches, loops, `break`, `return`, `goto` as a continue and calls that never return is
--- drawn over one local `x: integer` declared with no value, and run: every
--- way the program's choices (which branch, how often a loop goes round) can
--- fall is followed, and the program is bad when some way reads `x` before
--- it is assigned. The checker must refuse the program exactly when it is
--- bad.
---
--- A function that names `x` is not a read where it is made but where it is
--- called, and what may call it is any code of the program's that runs while
--- it exists: each call the program makes (`use`, `cond`, `count`, and `stop`, which
--- never returns and so lets them out), the `return` that lets it out and the
--- end of the function. The run is that: every call, and the end, calls every
--- function made so far, and one that finds `x` still nil is a read too.
--- `FUZZ_SEED` picks the inputs (build/fuzz/init.tl).
local Fuzz = require("build.fuzz")
local teal = require("build.teal")

--- Reads the drawn bytes one at a time; past the end every byte is 0.
local record Recipe
  bytes: string
  at: integer
  -- How many statements the program may still hold.
  left: integer
  -- Labels made so far, which name the next.
  labels: integer
  -- The labels some `goto` has been drawn for: a label nothing continues to
  -- is refused, so it is not written.
  jumped: {string:boolean}
  -- The loops (by their label) some `break` has been drawn for.
  broke: {string:boolean}
end

local function draw(r: Recipe, n: integer): integer
  r.at = r.at + 1
  return (r.bytes:byte(r.at) or 0) % n
end

--- The two texts of one program: the Teal the checker is asked about and
--- the Lua that is run.
local record Program
  teal: {string}
  lua: {string}
end

local function emit(p: Program, teal_line: string, lua_line?: string)
  p.teal[#p.teal + 1] = teal_line
  p.lua[#p.lua + 1] = lua_line or teal_line
end

--- Draws a program, a statement and a block calling each other.
local record draws
  statement: function(r: Recipe, p: Program, depth: integer, loop_end: string): boolean
  block: function(r: Recipe, p: Program, depth: integer, loop_end: string): boolean
end

--- The kinds of statement, a kind more often drawn the more times it is
--- listed: at the top of a block and inside one.
local BASIC_KINDS <const>: {string} = {
  "assign", "assign", "assign", "read", "read", "read", "shadow", "closure arg", "closure keep", "closure fn",
  "break", "return", "stop",
}
local KINDS <const>: {string} = {
  "assign", "assign", "assign", "read", "read", "read", "shadow", "closure arg", "closure keep", "closure fn",
  "break", "return", "stop",
  "if", "if", "if", "if else", "if else", "if else", "while", "while true", "repeat", "for",
  "continue if", "continue if", "continue if", "continue", "scoped local",
}

--- Draws one statement into `p`; true when it ends its block (no statement
--- may follow a `return`, and none is worth drawing after a `break` or a
--- call that never returns). `loop_end` names the label at the end of the
--- innermost loop's body, which a `goto` leaves a round by, and is "" outside
--- a loop.
function draws.statement(r: Recipe, p: Program, depth: integer, loop_end: string): boolean
  r.left = r.left - 1
  local kind = depth > 0 and KINDS[draw(r, #KINDS) + 1] or BASIC_KINDS[draw(r, #BASIC_KINDS) + 1]
  if kind == "assign" then
    emit(p, "x = 1")
  elseif kind == "read" then
    emit(p, "use(x)")
  elseif kind == "shadow" then
    emit(p, "do local x = 1 use(x) end")
  elseif kind == "closure arg" then
    -- Given to a call, which may call it at once.
    emit(p, "use(function(): integer return x end)", "use(mk(function() return touch(x) end))")
  elseif kind == "closure keep" or kind == "closure fn" then
    r.labels = r.labels + 1
    local name = "g" .. r.labels
    if kind == "closure keep" then
      emit(p, "local " .. name .. " = function(): integer return x end",
        "local " .. name .. " = mk(function() return touch(x) end)")
    else
      emit(p, "local function " .. name .. "(): integer return x end", "mk(function() return touch(x) end)")
    end
  elseif kind == "break" then
    if loop_end ~= "" then
      r.broke[loop_end] = true
      emit(p, "break")
      return true
    end
    emit(p, "use(0)")
  elseif kind == "return" then
    emit(p, "return")
    return true
  elseif kind == "stop" then
    emit(p, "stop()")
    return true
  elseif kind == "if" or kind == "if else" then
    emit(p, "if cond() then")
    local ends = draws.block(r, p, depth - 1, loop_end)
    if kind == "if else" then
      emit(p, "else")
      ends = draws.block(r, p, depth - 1, loop_end) and ends
    else
      ends = false
    end
    emit(p, "end")
    -- Nothing is drawn after a statement that ends the block: the code there
    -- is dead, and a variable declared in it is read by no way the run follows.
    return ends
  elseif kind == "while" or kind == "while true" or kind == "repeat" or kind == "for" then
    local opening: {string:string} = {
      ["while"] = "while cond() do", ["while true"] = "while true do", ["repeat"] = "repeat",
      ["for"] = "for _ = 1, count() do",
    }
    r.labels = r.labels + 1
    local continue = "c" .. r.labels
    emit(p, opening[kind])
    emit(p, "use(0)")
    -- A body may declare a variable of its own, unassigned on each pass, which
    -- its continues and breaks leave behind.
    if draw(r, 3) == 0 then
      emit(p, "local x: integer", "local x")
    end
    -- The body is a block of its own, so a `goto` to the label at its end
    -- needs no statement to stay last, and a `return` may end the body. The
    -- label is written only if the body jumps to it.
    emit(p, "do")
    local body_ended = draws.block(r, p, depth - 1, continue)
    emit(p, "end")
    if r.jumped[continue] then
      emit(p, "::" .. continue .. "::")
    end
    -- The condition of a `repeat` may read the variable the body declared.
    emit(p, kind ~= "repeat" and "end" or draw(r, 2) == 0 and "until condx(x)" or "until cond()")
    if kind == "repeat" then
      return body_ended and not r.broke[continue] and not r.jumped[continue]
    end
    return kind == "while true" and not r.broke[continue]
  elseif kind == "scoped local" then
    -- A variable of its own in a block inside the body, which a `goto` or a
    -- `break` leaves.
    emit(p, "do")
    emit(p, "local x: integer", "local x")
    -- Often a function that names it, and a continue that leaves with it.
    if draw(r, 2) == 0 then
      r.labels = r.labels + 1
      local name = "g" .. r.labels
      emit(p, "local " .. name .. " = function(): integer return x end",
        "local " .. name .. " = mk(function() return touch(x) end)")
    end
    if loop_end ~= "" and draw(r, 2) == 0 then
      r.jumped[loop_end] = true
      -- `math.random` is a choice that runs no code of the program's, so no
      -- call lets out the function between its making and the jump.
      emit(p, "if math.random(2) == 1 then goto " .. loop_end .. " end")
      -- Only the path that does not continue assigns.
      if draw(r, 2) == 0 then
        emit(p, "x = 1")
      end
    end
    local ends = draws.block(r, p, depth - 1, loop_end)
    emit(p, "end")
    return ends
  elseif kind == "continue if" or kind == "continue" then
    -- A `goto` to the end of the loop round, which `continue` is.
    if loop_end == "" then
      emit(p, "use(0)")
    elseif kind == "continue if" then
      r.jumped[loop_end] = true
      emit(p, "if cond() then goto " .. loop_end .. " end")
    else
      r.jumped[loop_end] = true
      emit(p, "goto " .. loop_end)
      return true
    end
  end
  return false
end

--- Draws the statements of one block: from none to a few, up to one that
--- ends it.
function draws.block(r: Recipe, p: Program, depth: integer, loop_end: string): boolean
  local count = draw(r, 5)
  for _ = 1, count do
    if r.left <= 0 then
      return false
    elseif draws.statement(r, p, depth, loop_end) then
      return true
    end
  end
  return false
end

--- The most choices a run may make, and the most steps it may take.
local MOST_CHOICES <const> = 11
local MOST_STEPS <const> = 400

--- Whether some way `code` can go reads `x` before it is assigned. `code`
--- is a function body over `use`, `cond`, `count`, `stop`, `mk`, `touch` and
--- an `x` that starts nil; every way the choices can fall is run. `mk` keeps
--- the function it is given, and every call but `stop`, and the end of the
--- body, calls those kept.
local function reads_unassigned(code: string): boolean
  local bad = false
  local choices: {boolean} = {}
  local made = 0
  local steps = 0
  local ended = {}
  local stopped = {}
  local kept: {function()} = {}
  local env: {string: any} = {}
  local function escape()
    for _, fn in ipairs(kept) do
      fn()
    end
  end
  local function choose(): boolean
    made = made + 1
    steps = steps + 1
    escape()
    if made > MOST_CHOICES or steps > MOST_STEPS then error(ended, 0) end
    return choices[made] or false
  end
  env.use = function(v: any)
    steps = steps + 1
    if steps > MOST_STEPS then error(ended, 0) end
    if v == nil then bad = true end
    escape()
  end
  env.mk = function(fn: function()): function()
    kept[#kept + 1] = fn
    return fn
  end
  env.touch = function(v: any): any
    if v == nil then bad = true end
    return v
  end
  env.cond = choose
  env.math = {
    random = function(): integer
      made = made + 1
      steps = steps + 1
      if made > MOST_CHOICES or steps > MOST_STEPS then error(ended, 0) end
      return choices[made] and 1 or 2
    end,
  }
  env.condx = function(v: any): boolean
    if v == nil then bad = true end
    steps = steps + 1
    return choose()
  end
  -- No pass, one or two: a second pass is the next round of the loop.
  env.count = function(): integer
    if not choose() then return 0 end
    return choose() and 2 or 1
  end
  -- The path ends, but a function made may be out, and called later.
  env.stop = function()
    escape()
    error(stopped, 0)
  end
  local chunk = assert(load("local function f()\n  local x\n" .. code .. "\nend\nreturn f", "oracle", "t",
    env as table))
  local run = chunk() as function()
  local pending: {{boolean}} = { {} }
  local runs = 0
  while #pending > 0 and not bad do
    choices = table.remove(pending) as {boolean}
    made, steps = 0, 0
    kept = {}
    if pcall(run) then
      escape()
    end
    runs = runs + 1
    assert(runs < 20000, "the oracle ran too long")
    -- Every call past the choices given took the first way: take the other
    -- at each of them in turn.
    for at = #choices + 1, math.min(made, MOST_CHOICES) do
      local longer: {boolean} = {}
      for i = 1, at - 1 do longer[i] = choices[i] or false end
      longer[at] = true
      pending[#pending + 1] = longer
    end
  end
  return bad
end

local head <const> = "local function use(_: any) end\n" ..
  "local function cond(): boolean return true end\n" ..
  "local function count(): integer return 1 end\n" ..
  "local function condx(_: integer): boolean return true end\n" ..
  "local function stop(): never error(\"stop\") end\n"

--- The program `input` draws: the Teal text and the Lua body.
local function program_of(input: string): string, string
  local r: Recipe = { bytes = input, at = 0, left = 24, labels = 0, jumped = {}, broke = {} }
  local p: Program = { teal = {}, lua = {} }
  draws.block(r, p, 3, "")
  return head .. "local function f()\n  local x: integer\n" .. table.concat(p.teal, "\n") .. "\nend\nuse(f)\n",
    table.concat(p.lua, "\n")
end

local type compiler = require("build.compiler")

local compiled: compiler | nil

--- The carried compiler, loaded once.
local function carried(): compiler
  if compiled ~= nil then
    return compiled
  end
  local loaded = assert(teal.load(true))
  compiled = loaded
  return loaded
end

local function check(input: string): boolean, string
  local source, code = program_of(input)
  local built = carried()
  local _, result = built.gen(source, nil, nil, "tl")
  assert(result ~= nil)
  local refused = false
  for _, e in ipairs(result.type_errors) do
    if e.code ~= "not_assigned" then
      return false, "an error of another kind: " .. e.msg .. "\n" .. source
    end
    refused = true
  end
  local bad = reads_unassigned(code)
  Fuzz.label(refused and "refused" or "accepted")
  if source:find("goto ", 1, true) then Fuzz.label("jumps") end
  if source:find("while true", 1, true) then Fuzz.label("endless") end
  if source:find("return x end", 1, true) then Fuzz.label("closures") end
  if refused ~= bad then
    return false, (refused and "refused a program no way of reads x before it is assigned or lets a function that names it read it\n" or
      "accepted a program some way of reads x before it is assigned\n") .. source
  end
  return true, ""
end

--- Ninety-six bytes, each any, which a program is read from.
local function draw_bytes(src: Fuzz.Source): string
  local chars: {string} = {}
  for i = 1, 96 do chars[i] = string.char(src:int(0, 255)) end
  return table.concat(chars)
end

local function test_the_checker_refuses_exactly_the_programs_that_read_before_they_assign(tmp: string)
  Fuzz.run({
    name = "definite assignment",
    dir = tmp,
    gen = draw_bytes,
    check = check,
    requires = { "refused", "accepted", "jumps", "endless", "closures" },
    shares = { refused = 0.1, accepted = 0.1, jumps = 0.03, endless = 0.05, closures = 0.1 },
  })
end
