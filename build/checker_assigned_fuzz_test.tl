--- Definite assignment, held to the semantics it is a rule about. A program
--- of branches, loops, `break`, `return`, `goto` and calls that never return is
--- drawn over one local `x: integer` declared with no value, and run: every
--- way the program's choices (which branch, how often a loop goes round) can
--- fall is followed, and the program is bad when some way reads `x` before
--- it is assigned. The checker must refuse the program exactly when it is
--- bad. A function literal that names `x` reads it where it is made, as the
--- rule says, and one that assigns it assigns nothing for the code around
--- it, so the programs hold no such function.
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
  block: function(r: Recipe, p: Program, depth: integer, loop_end: string)
end

--- The kinds of statement, a kind more often drawn the more times it is
--- listed: at the top of a block and inside one.
local BASIC_KINDS <const>: {string} = {
  "assign", "assign", "assign", "read", "read", "read", "shadow", "closure", "break", "return", "stop",
}
local KINDS <const>: {string} = {
  "assign", "assign", "assign", "read", "read", "read", "shadow", "closure", "break", "return", "stop",
  "if", "if", "if", "if else", "if else", "if else", "while", "while true", "repeat", "for",
  "continue if", "continue", "forward goto",
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
  elseif kind == "closure" then
    emit(p, "use(function(): integer return x end)", "use(x)")
  elseif kind == "break" then
    if loop_end ~= "" then
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
    draws.block(r, p, depth - 1, loop_end)
    if kind == "if else" then
      emit(p, "else")
      draws.block(r, p, depth - 1, loop_end)
    end
    emit(p, "end")
  elseif kind == "while" or kind == "while true" or kind == "repeat" or kind == "for" then
    local opening: {string:string} = {
      ["while"] = "while cond() do", ["while true"] = "while true do", ["repeat"] = "repeat",
      ["for"] = "for _ = 1, count() do",
    }
    r.labels = r.labels + 1
    local continue = "c" .. r.labels
    emit(p, opening[kind])
    emit(p, "use(0)")
    -- The body is a block of its own, so a `goto` to the label at its end
    -- needs no statement to stay last, and a `return` may end the body.
    emit(p, "do")
    draws.block(r, p, depth - 1, continue)
    emit(p, "end")
    emit(p, "::" .. continue .. "::")
    emit(p, kind == "repeat" and "until cond()" or "end")
  elseif kind == "continue if" or kind == "continue" then
    -- A `goto` to the end of the loop round, which `continue` is.
    if loop_end == "" then
      emit(p, "use(0)")
    elseif kind == "continue if" then
      emit(p, "if cond() then goto " .. loop_end .. " end")
    else
      emit(p, "goto " .. loop_end)
      return true
    end
  else
    -- A `goto` forward past the rest of a block.
    r.labels = r.labels + 1
    local skip = "s" .. r.labels
    emit(p, "do")
    emit(p, "if cond() then goto " .. skip .. " end")
    draws.block(r, p, depth - 1, loop_end)
    emit(p, "end")
    emit(p, "::" .. skip .. "::")
  end
  return false
end

--- Draws the statements of one block: from none to a few, up to one that
--- ends it.
function draws.block(r: Recipe, p: Program, depth: integer, loop_end: string)
  local count = draw(r, 5)
  for _ = 1, count do
    if r.left <= 0 or draws.statement(r, p, depth, loop_end) then
      return
    end
  end
end

--- The most choices a run may make, and the most steps it may take.
local MOST_CHOICES <const> = 11
local MOST_STEPS <const> = 400

--- Whether some way `code` can go reads `x` before it is assigned. `code`
--- is a function body over `use`, `cond`, `count`, `stop` and an `x` that
--- starts nil; every way the choices can fall is run.
local function reads_unassigned(code: string): boolean
  local bad = false
  local choices: {boolean} = {}
  local made = 0
  local steps = 0
  local ended = {}
  local stopped = {}
  local env: {string: any} = {}
  local function choose(): boolean
    made = made + 1
    steps = steps + 1
    if made > MOST_CHOICES or steps > MOST_STEPS then error(ended, 0) end
    return choices[made] or false
  end
  env.use = function(v: any)
    steps = steps + 1
    if steps > MOST_STEPS then error(ended, 0) end
    if v == nil then bad = true end
  end
  env.cond = choose
  env.count = function(): integer return choose() and 1 or 0 end
  env.stop = function() error(stopped, 0) end
  local chunk = assert(load("local function f()\n  local x\n" .. code .. "\nend\nreturn f", "oracle", "t",
    env as table))
  local run = chunk() as function()
  local pending: {{boolean}} = { {} }
  local runs = 0
  while #pending > 0 and not bad do
    choices = table.remove(pending) as {boolean}
    made, steps = 0, 0
    pcall(run)
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
  "local function stop(): never error(\"stop\") end\n"

--- The program `input` draws: the Teal text and the Lua body.
local function program_of(input: string): string, string
  local r: Recipe = { bytes = input, at = 0, left = 24, labels = 0 }
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
  if refused ~= bad then
    return false, (refused and "refused a program no way of reads x before it is assigned\n" or
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
    iters = 400,
    requires = { "refused", "accepted", "jumps", "endless" },
    shares = { refused = 0.1, accepted = 0.1, jumps = 0.05, endless = 0.05 },
  })
end
