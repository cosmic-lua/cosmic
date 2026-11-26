--- [`Fuzz.run`]'s starved runs (a property's `starved`), which only the
--- checked core makes: a raise that is no refusal's fails the input, and
--- so does a check that a starved run broke.

local Fs = require("cosmic.fs")
local Fuzz = require("cosmic.fuzz")
local Test = require("cosmic.test")

Test.policy{ requires = { "checked" } }

--- The report [`Fuzz.run`] raises for `p`, which must fail.
local function report(p: Fuzz.Property): string
  local ok, err = pcall(Fuzz.run, p)
  assert(not ok, "the property held")
  return tostring(err)
end

local function any_bytes(src: Fuzz.Source): string
  return Fuzz.bytes(src, 64)
end

local function holds(_input: string): boolean, string
  return true, ""
end

--- Allocates once per byte of `input`, so a run of most inputs is refused.
local function allocate(input: string): {string}
  local out: mut {string} = {}
  for i = 1, #input do out[#out + 1] = input:sub(1, i) .. "!" end
  return out
end

local function test_a_starved_run_that_raises_that_memory_ran_out_holds()
  local seen = { refused = 0 }
  local n = Fuzz.run({ name = "starved holds", iters = 64, gen = any_bytes, check = holds,
    starved = function(input: string): string
      local ok, _ = pcall(allocate, input)
      if not ok then
        seen.refused = seen.refused + 1
        error("not enough memory", 0)
      end
      return "read"
    end })
  assert(n == 64)
  assert(seen.refused > 0, "no starved run was refused an allocation")
end

local function test_a_starved_run_that_raises_anything_else_fails()
  -- Seen in a run that refuses only one allocation: in one that refuses
  -- all after it, the formatting of the message is refused too.
  local err = report({ name = "starved raises", iters = 64, gen = any_bytes, check = holds,
    starved = function(input: string): string
      local ok, _ = pcall(allocate, input)
      if not ok then error(("decoder bug at byte %d"):format(#input), 0) end
      return "read"
    end })
  assert(err:find("starved after %d+ allocations? of %d+, refusing one %(%d+ refused%): raised: decoder bug at byte") ~= nil, err)
end

local function test_a_starved_run_that_answers_otherwise_fails()
  local err = report({ name = "starved answers", iters = 64, gen = any_bytes, check = holds,
    starved = function(input: string): string
      local ok, _ = pcall(allocate, input)
      return if ok then "all of it" else "part of it" end
    end })
  assert(err:find('returned "part of it", where unstarved it returns "all of it"', 1, true) ~= nil, err)
end

local function test_a_check_that_a_starved_run_broke_fails()
  local state = { broken = false }
  local err = report({ name = "starved breaks", iters = 64, gen = any_bytes,
    check = function(_input: string): boolean, string
      if state.broken then return false, "broken" end
      return true, ""
    end,
    starved = function(input: string): string
      state.broken = true
      local _ = allocate(input)
      state.broken = false
      return "read"
    end })
  -- The run fails at the first input a starved run broke; shrinking then
  -- meets the state it left, so the report's reason may be the check's own.
  assert(err:find("fuzz starved breaks: seed=1 iteration=", 1, true) ~= nil and err:find("broken", 1, true) ~= nil, err)
end

local function test_a_line_may_say_memory_ran_out_and_the_lines_after_it_are_held()
  -- Each line a step of its own: the first refused, the second after it.
  local function starved_with(second: function(boolean): string): function(string): string
    return function(input: string): string
      local ok, _ = pcall(allocate, input)
      return (if ok then "read" else "out of memory" end) .. "\n" .. second(ok)
    end
  end
  local n = Fuzz.run({ name = "starved lines hold", iters = 64, gen = any_bytes, check = holds,
    starved = starved_with(function(_ok: boolean): string return "next" end) })
  assert(n == 64)
  local err = report({ name = "starved lines differ", iters = 64, gen = any_bytes, check = holds,
    starved = starved_with(function(ok: boolean): string
      return if ok then "next" else "wrong" end
    end) })
  assert(err:find('line 2 is "wrong", where unstarved it is "next"', 1, true) ~= nil, err)
end

local function test_a_corpus_input_is_starved_too(tmp: string)
  local corpus = tmp .. "/corpus"
  assert(Fs.mkdirs(corpus))
  assert(Fs.write(corpus .. "/a.input", string.rep("x", 40)))
  local err = report({ name = "starved corpus", corpus = corpus, iters = 0, gen = any_bytes, check = holds,
    starved = function(input: string): string
      local ok, _ = pcall(allocate, input)
      if not ok then error(("decoder bug at byte %d"):format(#input), 0) end
      return "read"
    end })
  assert(err:find("fuzz starved corpus: corpus input " .. corpus .. "/a.input: starved after", 1, true) ~= nil, err)
  assert(err:find("raised: decoder bug at byte 40", 1, true) ~= nil, err)
end
