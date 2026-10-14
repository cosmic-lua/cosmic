--- Fuzz properties for the type checker. Programs are drawn over what the
--- narrowing work touches:
--- locals and record fields typed `integer | nil`, `if`/`elseif`/`else`
--- on nil tests, `assert`, `and`/`or`, the four loops with `break` and
--- `goto`, function literals that write fields of what they read, calls,
--- field writes and `return`, and, drawn only to be refused, a function
--- literal that assigns a local declared outside it. A quarter of the
--- programs also draw shapes where narrowing bugs have lived (see
--- build/checker_programs.tl): a nested test of a string local that is
--- assigned under it, a new binding of a name whose field is narrowed, a
--- global `G` written through `_G` or hidden by a local, metamethods that
--- write, and a loop that reads a fact and clears it. `FUZZ_SEED` and
--- `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).
---
--- 1. The checker never raises: a program of any shape, well formed or
---    cut and flipped, is accepted or refused with errors, each carrying
---    a code and a place inside the source.
--- 2. A function that assigns a local declared outside it is refused with
---    the code `captured_assigned`, and no program without one is.
--- 3. Soundness: a well-formed program the checker accepts runs to its
---    end, or to a failed `assert`, without a nil operand (a string
---    narrowed to a literal is held to a map keyed by the literals, which
---    reads nil for any other). The programs
---    are bounded by construction (loops count up to three, a function
---    calls only those declared before it) and deterministic (nil comes
---    from a counter), so the run needs no hook; [`Fuzz.run`]'s budget ends
---    one that nonetheless does not stop.
---
--- Each property's corpus (`testdata/fuzz/checker-total/` and
--- `testdata/fuzz/checker-sound/`) is checked before anything is drawn,
--- even at `FUZZ_ITERS=0`, so it gates a merge. `checker-total` holds the
--- programs that once raised in the checker and the diagnostics' shapes;
--- `checker-sound` the programs whose narrowing must stay refused (each
--- fails at run time on a nil if accepted), and some that must keep
--- running. What the checker takes or refuses beyond those, and the
--- limits it has today, are pinned by build/checker_narrowing_test.tl.
local Fuzz = require("build.fuzz")
local programs = require("build.checker_programs")
local Test = require("cosmic.test")
local teal = require("build.teal")
local type compiler = require("build.compiler")

local CAPTURES_MARK <const> = programs.captures_mark
local gen_program <const> = programs.well_formed
local gen_any <const> = programs.any

-- The compiler is the tree's own checker, keyed by the core; [`Fuzz.run`] reads the corpus.
Test.policy{}

local built = { value = nil as compiler | nil }

local function compiler_of(): compiler
  if built.value == nil then
    built.value = assert(teal.load(true))
  end
  return built.value
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
-- Properties
--------------------------------------------------------------------------------

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

--- `why` and the program it is about: a report spells out only the first
--- 512 bytes of an input, in hex, and the header of a program alone is
--- longer.
local function about(why: string, source: string): string
  return why .. "\n--- program ---\n" .. source
end

-- TODO: the checker raises "attempt to perform arithmetic on a nil value" on
-- a string whose `\u` is not followed by `{` (`return "\ux"`), which a byte
-- edit of `"number"` writes; this property fails on it. It waits on the
-- lexer refusing a malformed escape with a syntax error.

--- A raise of the checker is [`Fuzz.run`]'s to report (and to attribute to
--- the budget when the checker stops terminating), so it is not caught here.
local function never_raises(source: string): boolean, string
  local code, r = check(source)
  if code == nil then
    if #r.syntax_errors == 0 then
      return false, about("no code and no syntax error", source)
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
      if why then return false, about(why, source) end
    end
  end
  return true, ""
end

--- Shapes of the generator beyond those: each the patterns that show a
--- program holds it. A program that holds one is said to have drawn it,
--- accepted or not, since most are refused; one that ran, to have exercised it.
local SHAPES <const>: {{string}} = {
  { "shape", "global G" },
  { "string test", "== \"'\"" },
  { "rebinding", "local [rs] = [rs]\n", "for _, [rs] in ipairs%({ [rs] }%)", "%([rs]: R%)" },
  { "metamethod", "[#(]mm[ .)\n]", "\n%s*mm%.zz", "if mm ==" },
  { "loop drop", "for k%d+ ", "k%d+ [<>]" },
  { "write through _G", "_G%.G", "_G%[", "= _G" },
  { "shadowed global", "local G: " },
  { "close", "<close>" },
}

--- Whether `source` holds a construct of `list`, by one of its patterns.
local function holds(entry: {string}, source: string): boolean
  for i = 2, #entry do
    if source:find(entry[i]) then return true end
  end
  return false
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
  { "early exit", "then return st.sink end" },
  { "elseif", "elseif " },
}

local NIL_FAULT <const> = "attempt to"

local function runs_safely(source: string): boolean, string
  local code, r = check(source)
  -- A function that assigns a local it does not declare is refused as that,
  -- and nothing else is.
  local marked = source:sub(-#CAPTURES_MARK) == CAPTURES_MARK
  local captured = false
  for _, e in ipairs(r.type_errors) do
    if e.code == "captured_assigned" then captured = true end
  end
  if marked and not captured then
    return false, about("a function assigns a local declared outside it and the checker took it", source)
  end
  if captured and not marked then
    return false, about("the checker refused a function as assigning a local declared outside it, " ..
        "and none does", source)
  end
  if marked then Fuzz.label("captured refused") end
  for _, c in ipairs(SHAPES) do
    if holds(c, source) then Fuzz.label("drew " .. c[1]) end
  end
  if code == nil or #r.syntax_errors > 0 or #r.type_errors > 0 then
    Fuzz.label("refused")
    return true, ""
  end
  Fuzz.label("accepted")
  if source:find("assert%(") then Fuzz.label("accepted with assert") end
  local env: {string:any} = { assert = assert, ipairs = ipairs, tostring = tostring, type = type,
    setmetatable = setmetatable }
  -- A program reaches its globals through `_G` as well.
  env["_G"] = env
  local chunk, why = load(code, "=fuzz", "t", env)
  if chunk == nil then
    return false, about("the checker accepted a program whose Lua does not load: " .. tostring(why), source)
  end
  local ran, err = pcall(chunk)
  if ran then
    Fuzz.label("ran")
    for _, c in ipairs(CONSTRUCTS) do
      if holds(c, source) then Fuzz.label("ran with " .. c[1]) end
    end
    for _, c in ipairs(SHAPES) do
      if holds(c, source) then Fuzz.label("ran with " .. c[1]) end
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
  return false, about(what .. message, source)
end

local function test_the_checker_never_raises_and_places_its_errors(tmp: string)
  Fuzz.run({
    name = "checker total",
    dir = tmp,
    gen = gen_any,
    check = never_raises,
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
    requires = { "accepted", "ran", "refused", "captured refused", "ran with while", "ran with repeat", "ran with numeric for",
      "ran with generic for", "ran with goto", "ran with break", "ran with assert",
      "ran with function literal", "ran with early exit", "ran with elseif", "drew shape" },
    shares = { accepted = 0.2 },
  })
end
