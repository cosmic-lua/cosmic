--- Definite assignment, held to the semantics it is a rule about ("assigned before read" in doc/plans/strict-teal.md).
--- A program of branches, loops, `break`, `return`, `continue` and calls that never return is drawn over one local
--- `x: integer` declared with no value, and run: every way the program's choices (which branch, how often a loop goes
--- round) can fall is followed, and the program is bad when some way reads `x` before it is assigned. A function that
--- names `x` reads it where it is made, since creating a function literal reads every variable it names. The checker
--- must refuse the program exactly when it is bad, and with the one code `not_assigned`.
---
--- Loops and blocks that declare a local of their own, unassigned on each pass, are drawn under names of their own, since
--- the new grammar refuses a declaration that hides another: the statements that follow read the innermost.
---
--- This is the oracle of build/checker_assigned_fuzz_test.tl against the new checker, which keeps it when the fork
--- goes; the fork's reads a function where it is called, and so its oracle ran the functions it had made at each call.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).
--- A few draws run by default so that the test fits a few seconds; the nightly fuzz workflow draws many from a seed of its own.
---
--- The statements are drawn towards what the rule decides: a branch that assigns on one edge and a read after it is a
--- statement of its own, so that a join that forgets an unassigned local is found within a few draws.
local Env = require("cosmic.env")
local Fuzz = require("build.fuzz")
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")

Test.policy{}

--- Reads the drawn bytes one at a time; past the end every byte is 0.
local record Recipe
  bytes: string
  mut at: integer
  -- How many statements the program may still hold.
  mut left: integer
  -- Labels made so far, which name the next, and likewise the locals.
  mut labels: integer
  mut locals: integer
  -- The local the statements being drawn assign and read: the innermost declared without a value.
  mut current: string
  -- The labels some `continue` has been drawn for: a loop nothing continues in has no label to write.
  jumped: mut {string:boolean}
  -- The loops (by their label) some `break` has been drawn for.
  broke: mut {string:boolean}
end

local function draw(r: Recipe, n: integer): integer
  r.at = r.at + 1
  return (r.bytes:byte(r.at) or 0) % n
end

--- The two texts of one program: the new grammar the checker is asked about and the Lua that is run, in which the
--- `continue` is the `goto` of the fork's Teal.
local record Program
  teal: mut {string}
  lua: mut {string}
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

--- The kinds of statement, a kind more often drawn the more times it is listed: at the top of a block and inside one.
local BASIC_KINDS <const>: {string} = {
  "assign", "assign", "assign", "read", "read", "read", "shadow", "closure arg", "closure keep", "closure fn",
  "break", "return", "stop",
}
local KINDS <const>: {string} = {
  "assign", "assign", "assign", "read", "read", "read", "shadow", "closure arg", "closure keep", "closure fn",
  "break", "return", "stop",
  "if", "if", "if", "if else", "if else", "if else", "while", "while true", "repeat", "for",
  "if assigns", "if assigns", "if assigns", "if assigns", "if assigns", "if assigns",
  "continue if", "continue if", "continue if", "continue if", "continue if", "continue", "continue", "scoped local",
}

--- A local of the program's own, unassigned, that the statements that follow in the block read.
local function declare(r: Recipe, p: Program, prefix: string): string
  r.locals = r.locals + 1
  local name = prefix .. tostring(r.locals)
  emit(p, "local " .. name .. ": integer", "local " .. name)
  return name
end

--- Draws one statement into `p`; true when it ends its block (no statement may follow a `return`, and none is worth
--- drawn after a `break` or a call that never returns). `loop_end` names the label at the end of the innermost loop's
--- body, which a `continue` leaves a round by, and is "" outside a loop.
function draws.statement(r: Recipe, p: Program, depth: integer, loop_end: string): boolean
  r.left = r.left - 1
  local kinds = BASIC_KINDS
  if depth > 0 then
    kinds = KINDS
  end
  local kind = assert(kinds[draw(r, #kinds) + 1])
  local x = r.current
  if kind == "assign" then
    emit(p, x .. " = 1")
  elseif kind == "read" then
    emit(p, "use(" .. x .. ")")
  elseif kind == "shadow" then
    r.locals = r.locals + 1
    local name = "s" .. tostring(r.locals)
    emit(p, "do local " .. name .. " = 1 use(" .. name .. ") end")
  elseif kind == "closure arg" then
    emit(p, "usef(function(): integer return " .. x .. " end)", "use(" .. x .. ")")
  elseif kind == "closure keep" or kind == "closure fn" then
    r.labels = r.labels + 1
    local name = "g" .. tostring(r.labels)
    if kind == "closure keep" then
      emit(p, "local " .. name .. " = function(): integer return " .. x .. " end", "use(" .. x .. ")")
    else
      emit(p, "local function " .. name .. "(): integer return " .. x .. " end", "use(" .. x .. ")")
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
    -- Nothing is drawn after a statement that ends the block: the code there is dead, and a variable declared in it is
    -- read by no way the run follows.
    return ends
  elseif kind == "if assigns" then
    -- The shape a join of unassigned locals is about: one edge assigns, the other may not, and what follows reads.
    emit(p, "if cond() then")
    emit(p, x .. " = 1")
    if draw(r, 2) == 0 then
      emit(p, "else")
      draws.block(r, p, depth - 1, loop_end)
    end
    emit(p, "end")
    -- Often the read that decides it.
    if draw(r, 2) == 0 then
      emit(p, "use(" .. x .. ")")
    end
    return false
  elseif kind == "while" or kind == "while true" or kind == "repeat" or kind == "for" then
    local opening: {string:string} = {
      ["while"] = "while cond() do", ["while true"] = "while true do", ["repeat"] = "repeat",
      ["for"] = "for _ = 1, count() do",
    }
    r.labels = r.labels + 1
    local continue_label = "c" .. tostring(r.labels)
    local opener = opening[kind]
    assert(opener ~= nil, kind)
    emit(p, opener)
    emit(p, "use(0)")
    -- A body may declare a variable of its own, unassigned on each pass, which its continues and breaks leave behind.
    local outer = r.current
    if draw(r, 3) == 0 then
      r.current = declare(r, p, "y")
    end
    -- The body is a block of its own, so a `continue` needs no statement to stay last, and a `return` may end the body.
    -- The label is written (for the Lua) only if the body jumps to it.
    emit(p, "do")
    local body_ended = draws.block(r, p, depth - 1, continue_label)
    emit(p, "end")
    if r.jumped[continue_label] == true then
      emit(p, "", "::" .. continue_label .. "::")
    end
    -- The condition of a `repeat` may read the variable the body declared, unless every path of the body ended: the
    -- checker reads the dead code after the body from the facts at the jumps that left it, so a read there is refused
    -- (it is no soundness hole to refuse it), and the oracle, which never gets there, would call the program good.
    --
    -- TODO: draw `until condx(y)` after a body that always ends again, once the checker no longer reads the dead code
    -- after it from the facts at the jumps.
    local dead = body_ended and r.jumped[continue_label] ~= true
    local closer = "end"
    if kind == "repeat" then
      closer = "until cond()"
      if draw(r, 2) == 0 and not dead then
        closer = "until condx(" .. r.current .. ")"
      end
    end
    emit(p, closer)
    r.current = outer
    if kind == "repeat" then
      return body_ended and r.broke[continue_label] ~= true and r.jumped[continue_label] ~= true
    end
    return kind == "while true" and r.broke[continue_label] ~= true
  elseif kind == "scoped local" then
    -- A variable of its own in a block inside the body, which a `continue` or a `break` leaves.
    local outer = r.current
    emit(p, "do")
    r.current = declare(r, p, "z")
    -- Often a function that names it, and a continue that leaves with it.
    if draw(r, 2) == 0 then
      r.labels = r.labels + 1
      local name = "g" .. tostring(r.labels)
      emit(p, "local " .. name .. " = function(): integer return " .. r.current .. " end", "use(" .. r.current .. ")")
    end
    if loop_end ~= "" and draw(r, 2) == 0 then
      r.jumped[loop_end] = true
      emit(p, "if cond() then continue end", "if cond() then goto " .. loop_end .. " end")
      -- Only the path that does not continue assigns.
      if draw(r, 2) == 0 then
        emit(p, r.current .. " = 1")
      end
    end
    local ends = draws.block(r, p, depth - 1, loop_end)
    emit(p, "end")
    r.current = outer
    return ends
  elseif kind == "continue if" or kind == "continue" then
    if loop_end == "" then
      emit(p, "use(0)")
    elseif kind == "continue if" then
      r.jumped[loop_end] = true
      emit(p, "if cond() then continue end", "if cond() then goto " .. loop_end .. " end")
    else
      r.jumped[loop_end] = true
      emit(p, "continue", "goto " .. loop_end)
      return true
    end
  end
  return false
end

--- Draws the statements of one block: from none to a few, up to one that ends it.
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

--- What a run of the oracle keeps: whether a read found `x` unassigned, the choices made and the steps taken so far, and
--- the choices this run is to make.
local record Oracle
  mut bad: boolean
  mut made: integer
  mut steps: integer
  mut choices: {boolean}
end

--- The functions the Lua body is run over.
local record Hooks
  use: function(any)
  cond: function(): boolean
  condx: function(any): boolean
  count: function(): integer
  stop: function()
end

--- Whether some way `code` can go reads `x` (or a local of its own) before it is assigned. `code` is a function body
--- over `use`, `condx`, `cond`, `count` and `stop`, with an `x` that starts nil; every way the choices can fall is run.
local function reads_unassigned(code: string): boolean
  local o: Oracle = { bad = false, made = 0, steps = 0, choices = {} }
  local ended: {string: boolean} = {}
  local stopped: {string: boolean} = {}
  local function step()
    o.steps = o.steps + 1
    if o.steps > MOST_STEPS then
      error(ended, 0)
    end
  end
  local function choose(): boolean
    o.made = o.made + 1
    step()
    if o.made > MOST_CHOICES then
      error(ended, 0)
    end
    return o.choices[o.made] == true
  end
  local hooks: Hooks = {
    use = function(v: any)
      step()
      if v == nil then
        o.bad = true
      end
    end,
    cond = choose,
    condx = function(v: any): boolean
      if v == nil then
        o.bad = true
      end
      step()
      return choose()
    end,
    -- No pass, one or two: a second pass is the next round of the loop.
    count = function(): integer
      if not choose() then
        return 0
      end
      return if choose() then 2 else 1 end
    end,
    -- The path ends.
    stop = function()
      error(stopped, 0)
    end,
  }
  local chunk = assert(load("local function f()\n  local x\n" .. code .. "\nend\nreturn f", "oracle", "t", hooks as table))
  local run = chunk() as function()
  local pending: mut {{boolean}} = { {} }
  local runs = 0
  while #pending > 0 and not o.bad do
    o.choices = assert(table.remove(pending))
    o.made, o.steps = 0, 0
    pcall(run)
    runs = runs + 1
    assert(runs < 20000, "the oracle ran too long")
    -- Every call past the choices given took the first way: take the other at each of them in turn.
    for at = #o.choices + 1, math.min(o.made, MOST_CHOICES) do
      local longer: mut {boolean} = {}
      for i = 1, at - 1 do
        longer[#longer + 1] = o.choices[i] == true
      end
      longer[#longer + 1] = true
      pending[#pending + 1] = longer
    end
  end
  return o.bad
end

local head <const> = "local function use(_: integer) end\n" ..
  "local function usef(_: function(): integer) end\n" ..
  "local function cond(): boolean return true end\n" ..
  "local function count(): integer return 1 end\n" ..
  "local function condx(_: integer): boolean return true end\n" ..
  "local function stop(): never error(\"stop\") end\n" ..
  "local function run(_: function()) end\n"

--- The program `input` draws: the text of the new grammar and the Lua body.
local function program_of(input: string): string, string
  local r: Recipe = {
    bytes = input, at = 0, left = 24, labels = 0, locals = 0, current = "x", jumped = {}, broke = {},
  }
  local p: Program = { teal = {}, lua = {} }
  draws.block(r, p, 3, "")
  return head .. "local function f()\n  local x: integer\n" .. table.concat(p.teal, "\n") .. "\nend\nrun(f)\n",
    table.concat(p.lua, "\n")
end

local record Counter
  mut count: integer
end

local check_in = Programs.runner()
local made: Counter = { count = 0 }

local function check(input: string): boolean, string
  local source, code = program_of(input)
  made.count = made.count + 1
  local run = check_in(source, "assigned" .. tostring(made.count))
  if #run.before > 0 then
    return false, "not a program: " .. table.concat(run.before, " ") .. "\n" .. source
  end
  local refused = false
  for _, e in ipairs(run.errors) do
    if e.code ~= "not_assigned" then
      return false, "an error of another kind: " .. e.code .. " " .. e.msg .. "\n" .. source
    end
    refused = true
  end
  local bad = reads_unassigned(code)
  Fuzz.label(if refused then "refused" else "accepted" end)
  if source:find("continue", 1, true) then Fuzz.label("jumps") end
  if source:find("while true", 1, true) then Fuzz.label("endless") end
  if source:find("return x end", 1, true) then Fuzz.label("closures") end
  if source:find("local y", 1, true) then Fuzz.label("loop locals") end
  if refused ~= bad then
    return false, (if refused then "refused a program no way of which reads x before it is assigned\n" else
      "accepted a program some way of which reads x before it is assigned\n" end) .. source
  end
  return true, ""
end

--- Ninety-six bytes, each any, which a program is read from.
local function draw_bytes(src: Fuzz.Source): string
  local chars: mut {string} = {}
  for i = 1, 96 do chars[i] = string.char(src:int(0, 255)) end
  return table.concat(chars)
end

--- How many programs to draw: `FUZZ_ITERS` where it is set, else 24, which a test of a few seconds under coverage
--- allows.
local function iterations(): integer
  return math.tointeger(tonumber(Env.get_or("FUZZ_ITERS", ""))) or 24
end

local function test_the_checker_refuses_exactly_the_programs_that_read_before_they_assign(tmp: string)
  Fuzz.run({
    name = "new checker definite assignment",
    dir = tmp,
    iters = iterations(),
    gen = draw_bytes,
    check = check,
    requires = { "refused", "accepted", "jumps", "endless", "closures", "loop locals" },
    shares = { refused = 0.1, accepted = 0.1, jumps = 0.03, endless = 0.05, closures = 0.1 },
  })
end
