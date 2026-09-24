--- Seeded, shrinking property fuzzing for the parsers that face untrusted
--- bytes. A property names a generator, which builds one input from a
--- `Source`'s draws, and a check that must hold for every input. `run`
--- draws `FUZZ_ITERS` inputs (64 by default) from `FUZZ_SEED` (1 by
--- default), so the same seed reaches the same input at the same
--- iteration on every host. A check that returns false or raises fails
--- the run; so does one that spends more VM instructions than its budget,
--- which is how a parser that stops terminating is attributed to its
--- input instead of hanging the suite.
---
--- A failing input is shrunk before it is reported: the draws that built
--- it are cut and lowered for as long as the input they build still
--- fails, so the report names a small case rather than the first one
--- found. The report gives the seed, the iteration, and the input in
--- hex, and keeps the input in a file.
---
--- Crash containment is the test runner's: every test runs in a worker
--- process of its own under a deadline. Before each check `run` writes
--- the input about to be checked into the test's own directory, which
--- the runner keeps, so a check that crashes the process in C, or hangs
--- inside one C call where the budget cannot reach, leaves the input
--- that did it behind; `run` names that file in what it prints, which
--- the runner shows for a failing test.

local Codec = require("cosmic.codec")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Rand = require("cosmic.rand")
local shrink = require("build.fuzz.shrink")
local type Budget = require("cosmic.internal.budget")

--- The instruction budget, handed to this module only when it loads from
--- the binary's own tree (core/store.c's `raw_modules`). It shares the
--- VM's one hook with coverage collection, so it holds under `cosmic test`.
--- Loaded any other way there is none, and a check that never ends is
--- ended by the test runner's deadline instead.
local extra: any = select(2, ...)
local arm: function(count?: integer)
if type(extra) == "table" then
  arm = (extra as Budget).budget
end

--- What a spent budget raises (core/coverage.c). `coroutine.wrap`
--- prefixes a position when it passes the raise on, so it is matched as
--- the end of what was raised.
local BUDGET_MESSAGE <const> = "instruction budget exceeded"

local DEFAULT_SEED <const> = 1
local DEFAULT_ITERS <const> = 64

--- VM instructions one check may spend: seconds of work even under
--- coverage, far past what one parse of a small input should need.
local DEFAULT_BUDGET <const> = 50000000

--- How many candidate inputs shrinking may check before it reports the
--- smallest failing one found so far.
local SHRINK_TRIES <const> = 2000

--- The most bytes of a failing input a report spells out in hex; the
--- file it is kept in holds all of it.
local SHOWN_BYTES <const> = 512

local record Fuzz
  --- Where a generator's choices come from. Every choice is an integer
  --- draw, so a failing input can be replayed from its draws, and shrunk
  --- by replaying smaller ones.
  record Source
    --- An integer from `min` through `max`, both included. Raises when
    --- `min` is greater than `max`.
    int: function(Source, min: integer, max: integer): integer
  end

  --- One property to fuzz.
  record Property
    --- Names the property in every report and in its kept input's file.
    name: string
    --- Builds one input from the source's draws. Deterministic: the same
    --- draws build the same input.
    gen: function(Source): string
    --- True when the property holds for `input`, or false and what
    --- failed. A raise fails it the same way.
    check: function(input: string): boolean, string
    --- The directory the input under test is kept in: a test's own
    --- temporary directory. Nothing is kept without one.
    dir: string
    --- Iterations, in place of `FUZZ_ITERS`.
    iters: integer
    --- The most iterations `FUZZ_ITERS` may ask for, for a property whose
    --- every input costs a process or a file the size of a core: a deep
    --- run raises every other property's count, and this one's only to
    --- here.
    max_iters: integer
    --- VM instructions one check may spend.
    budget: integer
  end
end

local type Draw = shrink.Draw

--- A source over `values` that records what it hands out into `draws`.
--- A value outside the range asked for is clamped to its lower end, and
--- a draw past the end of `values` is its lower end, so any list of
--- integers replays to some input.
local function replaying(values: {integer}, draws: {Draw}): Fuzz.Source
  local at = 0
  local src: Fuzz.Source = {}
  src.int = function(_self: Fuzz.Source, min: integer, max: integer): integer
    if min > max then
      error(("fuzz: int(%d, %d): min is greater than max"):format(min, max), 2)
    end
    at = at + 1
    local v = values[at]
    if v == nil or v < min or v > max then v = min end
    draws[#draws + 1] = { min = min, max = max, value = v }
    return v
  end
  return src
end

--- A source drawing from `rng` that records what it hands out.
local function recording(rng: Rand.Source, draws: {Draw}): Fuzz.Source
  local src: Fuzz.Source = {}
  src.int = function(_self: Fuzz.Source, min: integer, max: integer): integer
    local v = rng:int(min, max)
    draws[#draws + 1] = { min = min, max = max, value = v }
    return v
  end
  return src
end

--- An integer from the environment, or `otherwise` when it is unset.
--- Raises when it is set to anything but a positive integer, so a typo
--- is never a silent default.
local function nonnegative_env(name: string, otherwise: integer): integer
  local raw = Env.get(name)
  if raw == nil or raw == "" then return otherwise end
  local n = math.tointeger(tonumber(raw))
  if n == nil or n < 0 then
    error(("fuzz: %s=%q is not a non-negative integer"):format(name, raw), 0)
  end
  return n
end

--- Runs `check` on `input` once, under the budget.
local function attempt(check: function(string): boolean, string, input: string,
    budget: integer): boolean, string
  if arm then arm(budget) end
  local ok, held, why = pcall(check, input)
  if arm then arm() end
  if not ok then
    local raised = tostring(held)
    if raised:sub(-#BUDGET_MESSAGE) == BUDGET_MESSAGE then
      return false, ("spent its budget of %d VM instructions"):format(budget)
    end
    return false, "raised: " .. raised
  end
  if held ~= true then
    return false, why ~= nil and why ~= "" and tostring(why) or "check returned false"
  end
  return true, ""
end

--- A file name for the property, from its name.
local function slug(name: string): string
  local s = name:gsub("[^%w]+", "-"):gsub("^-+", ""):gsub("-+$", "")
  if s == "" then s = "property" end
  return s
end

--- Builds the input `values` replay to, with the draws that built it.
local function build(gen: function(Fuzz.Source): string, values: {integer}): string, {Draw}
  local draws: {Draw} = {}
  local input = gen(replaying(values, draws))
  return input, draws
end

--- Draws `p.iters` (or `FUZZ_ITERS`) inputs from `FUZZ_SEED` and checks
--- each, raising a report on the first that fails, after shrinking it.
--- Returns how many inputs were checked.
--- @param p Property The property to fuzz
--- @return integer How many inputs held
function Fuzz.run(p: Fuzz.Property): integer
  local seed = nonnegative_env("FUZZ_SEED", DEFAULT_SEED)
  local iters = p.iters or nonnegative_env("FUZZ_ITERS", DEFAULT_ITERS)
  if p.iters == nil and p.max_iters ~= nil and iters > p.max_iters then
    iters = p.max_iters
  end
  local budget = p.budget or DEFAULT_BUDGET
  local kept: string
  if p.dir ~= nil then
    kept = p.dir .. "/" .. slug(p.name) .. ".input"
    print(("fuzz %s: seed=%d iters=%d; the input under test is kept at %s"):
       format(p.name, seed, iters, kept))
  end
  local seeds = Rand.new(seed)
  for i = 1, iters do
    local draws: {Draw} = {}
    local input = p.gen(recording(Rand.new(seeds:int(math.mininteger, math.maxinteger)), draws))
    if kept ~= nil then local _, _ = Fs.write(kept, input) end
    local held, why = attempt(p.check, input, budget)
    if not held then
      local function fails(values: {integer}): boolean, {Draw}
        local candidate, used = build(p.gen, values)
        local still, _ = attempt(p.check, candidate, budget)
        return not still, used
      end
      local smallest, tries = shrink.shrink(draws, fails, SHRINK_TRIES)
      local small = build(p.gen, shrink.values_of(smallest))
      local small_held, small_why = attempt(p.check, small, budget)
      if not small_held then
        why = small_why
      else
        -- A check that fails only sometimes: report what first failed.
        small, smallest = input, draws
      end
      if kept ~= nil then local _, _ = Fs.write(kept, small) end
      local shown = Codec.hex(small:sub(1, SHOWN_BYTES))
      if #small > SHOWN_BYTES then shown = shown .. "..." end
      error(("fuzz %s: seed=%d iteration=%d: %s\n" ..
        "  shrunk in %d tries from %d draws and %d bytes to %d draws and %d bytes; input (hex): %s\n" ..
        "  %s\n  reproduce: FUZZ_SEED=%d FUZZ_ITERS=%d"):
         format(p.name, seed, i, why, tries, #draws, #input, #smallest, #small, shown,
          kept ~= nil and ("kept at " .. kept) or "not kept: the property names no dir",
          seed, i), 0)
    end
  end
  return iters
end

--- Checks one input directly, under the same budget and with the same
--- report shape as `run`: what reproducing a kept input needs.
--- @param p Property The property; its generator is not used
--- @param input string The input to check
--- @return boolean True when the property held
--- @return string What failed, when it did not
function Fuzz.replay(p: Fuzz.Property, input: string): boolean, string
  return attempt(p.check, input, p.budget or DEFAULT_BUDGET)
end

--- Draws one of `choices`, which must not be empty.
function Fuzz.pick<T>(src: Fuzz.Source, choices: {T}): T
  return choices[src:int(1, #choices)]
end

--- Up to `max` arbitrary bytes, the length drawn first.
function Fuzz.bytes(src: Fuzz.Source, max: integer): string
  local n = src:int(0, max)
  local out: {string} = {}
  for i = 1, n do out[i] = string.char(src:int(0, 255)) end
  return table.concat(out)
end

--- Bytes parsers single out: the ends of a byte's range, octal and
--- decimal digits' neighbors, path separators, and padding.
local SPECIAL <const> = { 0, 1, 0x7f, 0x80, 0xff, 0x20, 0x2f, 0x2e, 0x30, 0x37, 0x38, 0x39, 0x5c }

--- Up to `max_edits` edits of `sample`, drawn one at a time: a byte
--- replaced (by any byte or one of the bytes parsers single out), a
--- bit flipped, a byte inserted or deleted, a run duplicated, or the
--- tail cut. No edits leaves `sample` as it was, which is what a
--- property that also holds for well-formed input wants some of.
function Fuzz.mutate(src: Fuzz.Source, sample: string, max_edits: integer): string
  local s = sample
  for _ = 1, src:int(0, max_edits) do
    local kind = src:int(1, 7)
    if #s == 0 then kind = 4 end
    if kind == 1 then
      local at = src:int(1, #s)
      s = s:sub(1, at - 1) .. string.char(src:int(0, 255)) .. s:sub(at + 1)
    elseif kind == 2 then
      local at = src:int(1, #s)
      s = s:sub(1, at - 1) .. string.char(SPECIAL[src:int(1, #SPECIAL)]) .. s:sub(at + 1)
    elseif kind == 3 then
      local at = src:int(1, #s)
      s = s:sub(1, at - 1) .. string.char(s:byte(at) ~ (1 << src:int(0, 7))) .. s:sub(at + 1)
    elseif kind == 4 then
      local at = src:int(1, #s + 1)
      s = s:sub(1, at - 1) .. string.char(src:int(0, 255)) .. s:sub(at)
    elseif kind == 5 then
      local at = src:int(1, #s)
      s = s:sub(1, at - 1) .. s:sub(at + 1)
    elseif kind == 6 then
      local at = src:int(1, #s)
      local len = src:int(1, math.min(64, #s - at + 1))
      s = s:sub(1, at + len - 1) .. s:sub(at, at + len - 1) .. s:sub(at + len)
    else
      s = s:sub(1, src:int(0, #s - 1))
    end
  end
  return s
end

--- Packs `fields` into one input, for a property whose generator draws
--- a structure (entries, say) and whose check builds from it: shrinking
--- then works on the structure's draws, not on bytes a writer made.
function Fuzz.pack(fields: {string}): string
  local parts: {string} = {}
  for i, f in ipairs(fields) do parts[i] = string.pack("<s4", f) end
  return table.concat(parts)
end

--- The fields `pack` packed into `input`.
function Fuzz.unpack(input: string): {string}
  local out: {string} = {}
  local at = 1
  while at <= #input do
    local f: string
    f, at = string.unpack("<s4", input, at)
    out[#out + 1] = f
  end
  return out
end

return Fuzz
