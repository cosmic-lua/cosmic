--- The checker never raises, whatever it is given. Programs are drawn by the fork's generator of its totality property
--- ([`build.check_draws`]: a well-formed program over the narrowing work's shapes, one in three cut and flipped at
--- random bytes) and checked three ways: adapted to the new grammar ([`lang.check_drawn`]), which most of the well-formed
--- ones are taken for, translated ([`lang.translate`]), and as they are, which for most is text the new grammar's
--- parser has never seen. Each is read, scoped, lowered and checked, and none of them raises; each
--- error it gives has a code, a message and a place inside the source. The corpus of programs that once raised in the
--- fork's checker (`testdata/fuzz/checker-total`) is checked first, even at `FUZZ_ITERS=0`. `FUZZ_SEED` and
--- `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).
--- A few draws run by default so that the test fits a few seconds; the full sweep, many draws from several seeds, is
--- [`bin/gate-sweep`] (its result is testdata/gate/sweep.txt), and the nightly fuzz workflow draws from a seed of its own.
---
--- This is the property of build/checker_fuzz_test.tl against the new checker, which keeps it when the fork goes.
local Drawn = require("lang.check_drawn")
local Env = require("cosmic.env")
local Fuzz = require("build.fuzz")
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")
local Translate = require("lang.translate")
local drawn = require("build.check_draws")

Test.policy{}

--- The library, lowered once, and how many programs it has checked, which name their modules.
local record Counter
  mut count: integer
end

local check_in = Programs.runner()
local made: Counter = { count = 0 }

local function count_lines(text: string): integer
  local _, n = text:gsub("\n", "\n")
  return n + 1
end

--- Why an error is not one a reader could act on, or nil.
local function malformed(code: string, msg: string, y: integer, x: integer, lines: integer): string?
  if code == "" then
    return "no code: " .. msg
  end
  if msg == "" then
    return "no message for code " .. code
  end
  if y < 1 or y > lines or x < 1 then
    return ("%s at %d:%d, outside a source of %d lines: %s"):format(code, y, x, lines, msg)
  end
  return nil
end

--- The first error of `run` that is not one a reader could act on, with what is wrong with it.
local function unplaced(run: Programs.Run, lines: integer): string?
  for _, e in ipairs(run.scoped.errors) do
    local why = malformed(e.code, e.msg, e.y, e.x, lines)
    if why ~= nil then
      return why
    end
  end
  for _, e in ipairs(run.lowered.errors) do
    local why = malformed(e.code, e.msg, e.y, e.x, lines)
    if why ~= nil then
      return why
    end
  end
  for _, e in ipairs(run.errors) do
    local why = malformed(e.code, e.msg, e.y, e.x, lines)
    if why ~= nil then
      return why
    end
  end
  return nil
end

--- Checks `source`, in the new grammar, and counts what it was: a program, refused or taken, or not one. Raises what the
--- checker raises, which [`Fuzz.run`] reports (and attributes to its budget when the checker stops terminating).
local function never_raises(source: string, how: string): boolean, string
  made.count = made.count + 1
  local run = check_in(source, "fuzz" .. tostring(made.count))
  if #run.before > 0 then
    Fuzz.label(how .. " not a program")
  elseif #run.errors > 0 then
    Fuzz.label(how .. " refused")
  else
    Fuzz.label(how .. " accepted")
  end
  local why = unplaced(run, count_lines(source))
  if why ~= nil then
    return false, why .. "\n--- program (" .. how .. ") ---\n" .. source
  end
  return true, ""
end

local function check(input: string): boolean, string
  local adapted = Drawn.adapted(input)
  if adapted ~= nil then
    local ok, why = never_raises(Translate.translate(adapted, "fuzz.tl").text, "adapted")
    if not ok then
      return false, why
    end
  end
  local ok, why = never_raises(Translate.translate(input, "fuzz.tl").text, "translated")
  if not ok then
    return false, why
  end
  return never_raises(input, "raw")
end

--- How many programs to draw: `FUZZ_ITERS` where it is set, else 24, which a test of a few seconds under coverage allows
--- (each is checked three ways).
local function iterations(): integer
  return math.tointeger(tonumber(Env.get_or("FUZZ_ITERS", ""))) or 24
end

local function test_the_checker_never_raises_and_places_its_errors(tmp: string)
  Fuzz.run({
    name = "new checker total",
    dir = tmp,
    iters = iterations(),
    corpus = "testdata/fuzz/checker-total",
    gen = drawn.any,
    check = check,
    requires = { "adapted accepted", "adapted refused", "adapted not a program", "translated not a program", "raw not a program" },
    shares = { ["adapted refused"] = 0.1 },
  })
end
