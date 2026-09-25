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
--- found. The report gives the seed, the iteration, the input's own
--- case (`FUZZ_CASE`, which checks that one input alone), and the input
--- in hex, and keeps the input in a file. A check that fails an input
--- and then holds for it is reported flaky rather than shrunk.
---
--- Crash containment is the test runner's: every test runs in a worker
--- process of its own under a deadline. Before each check `run` writes
--- the input about to be checked into the test's own directory, which
--- the runner keeps, so a check that crashes the process in C, or hangs
--- inside one C call where the budget cannot reach, leaves the input
--- that did it behind; `run` names that file in what it prints, which
--- the runner shows for a failing test.
---
--- A failure found once is kept for good in the property's corpus, a
--- directory of inputs under `testdata/fuzz/` that `run` checks before
--- it draws anything: the report says how to copy the shrunk input
--- there, so a fixed bug stays fixed whatever seed a later run draws.
---
--- A check can `label` what an input reached ("opened", "read a
--- body"); `run` prints how many inputs reached each label, and a
--- property that `requires` a label fails when no input reached it, so
--- a generator whose inputs all stop at the first refusal is found out
--- rather than passing while it checks nothing.

local Codec = require("cosmic.codec")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
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

--- Where a property's corpus is, by default: one directory per
--- property, named for it, under this one at the tree's root.
local CORPUS_ROOT <const> = "testdata/fuzz"

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
    --- The directory of inputs checked before any is drawn: failures
    --- found before, kept so they stay fixed. `testdata/fuzz/` and the
    --- property's name, slugged, by default; one that does not exist
    --- holds nothing.
    corpus: string
    --- One input to check in place of a run, as a report's `reproduce`
    --- line names it: `<property>:<case seed>`. `FUZZ_CASE` sets it for
    --- every property; one whose name it does not match checks nothing,
    --- its corpus included.
    case: string
    --- Labels (see `label`) at least one drawn input must reach, or the
    --- run fails: what the property is meant to exercise. Not held when
    --- `FUZZ_ITERS` asks for fewer inputs than the default 64, as
    --- reproducing one failure does.
    requires: {string}
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

--- The labels the input being drawn and checked has reached, while
--- `run` is counting them; nil otherwise, so shrinking and replay count
--- nothing.
local reached: {string: boolean} = nil

--- Records that the input under check reached `name`: an outcome worth
--- counting ("opened", "refused at the header", "read a body"). `run`
--- prints how many inputs reached each label and fails a property that
--- `requires` one no input reached. Outside `run`'s drawn inputs it
--- does nothing.
--- @param name string The label
function Fuzz.label(name: string)
  if reached ~= nil then reached[name] = true end
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

--- The property's corpus directory.
local function corpus_of(p: Fuzz.Property): string
  return p.corpus or (CORPUS_ROOT .. "/" .. slug(p.name))
end

--- The name an input is kept under in a corpus: its digest's head, so
--- keeping one input twice keeps one file.
local function corpus_name(input: string): string
  return Hash.hex_sha256(input):sub(1, 16) .. ".input"
end

--- The input in hex, as a report shows it: at most SHOWN_BYTES of it.
local function shown(input: string): string
  local hex = Codec.hex(input:sub(1, SHOWN_BYTES))
  if #input > SHOWN_BYTES then hex = hex .. "..." end
  return hex
end

--- Checks every `.input` file in the property's corpus, in name order,
--- raising a report on the first that fails; each is written to `kept`
--- first, as a drawn input is. Returns how many were checked.
local function check_corpus(p: Fuzz.Property, budget: integer, kept: string): integer
  local dir = corpus_of(p)
  local there, trouble = Fs.exists(dir)
  if there == false then return 0 end
  local names: {string}
  if there then names, trouble = Fs.list(dir) end
  if names == nil then
    error(("fuzz %s: corpus %s: %s"):format(p.name, dir, trouble), 0)
  end
  local checked = 0
  for _, name in ipairs(names) do
    if name:sub(-6) ~= ".input" then goto continue end
    local path = dir .. "/" .. name
    local input, rtrouble = Fs.read(path)
    if input == nil then
      error(("fuzz %s: corpus %s: %s"):format(p.name, path, rtrouble), 0)
    end
    if kept ~= nil then local _, _ = Fs.write(kept, input) end
    local held, why = attempt(p.check, input, budget)
    if not held then
      error(("fuzz %s: corpus input %s: %s\n  input (hex, %d bytes): %s"):
        format(p.name, path, why, #input, shown(input)), 0)
    end
    checked = checked + 1
    ::continue::
  end
  return checked
end

--- The line `run` prints of how many inputs reached each label, in
--- name order, or nil when no label was reached and none is required.
local function label_counts(counts: {string: integer}, required: {string},
    iters: integer): string | nil
  local names: {string} = {}
  for name in pairs(counts) do names[#names + 1] = name end
  for _, name in ipairs(required or {}) do
    if counts[name] == nil then names[#names + 1] = name end
  end
  if #names == 0 then return nil end
  table.sort(names)
  local parts: {string} = {}
  for i, name in ipairs(names) do
    parts[i] = ("%s %d"):format(name, counts[name] or 0)
  end
  return ("%s (of %d inputs)"):format(table.concat(parts, ", "), iters)
end

--- Builds the input `values` replay to, with the draws that built it.
local function build(gen: function(Fuzz.Source): string, values: {integer}): string, {Draw}
  local draws: {Draw} = {}
  local input = gen(replaying(values, draws))
  return input, draws
end

--- The one input a case names -- `p.case`, else `FUZZ_CASE` -- as the
--- property's slug and the seed of the source that drew it, as a report
--- prints them. Nil when neither is set; raises when one is set to
--- anything else, so a typo is never a silent full run.
local function named_case(p: Fuzz.Property): string, integer
  local text = p.case or Env.get_or("FUZZ_CASE", "")
  if text == "" then return nil, nil end
  local raw = text
  local name = text:match("^(.-):%-?%d+$")
  local digits = text:match(":(%-?%d+)$")
  local n: integer = digits ~= nil and math.tointeger(tonumber(digits)) or nil
  if name == nil or name == "" or n == nil then
    error(("fuzz: FUZZ_CASE=%q is not <property>:<case seed>, as a report prints it"):format(raw), 0)
  end
  return name, n
end

--- `run`'s work, with no labels being counted when it starts.
local function run(p: Fuzz.Property): integer
  local case_name, case_seed = named_case(p)
  if case_name ~= nil and case_name ~= slug(p.name) then return 0 end
  local seed = nonnegative_env("FUZZ_SEED", DEFAULT_SEED)
  local iters = p.iters or nonnegative_env("FUZZ_ITERS", DEFAULT_ITERS)
  -- Fewer inputs than the default, as reproducing one failure asks for,
  -- may reach no label at all by chance: `requires` holds of a whole run.
  local whole = p.iters ~= nil or iters >= DEFAULT_ITERS
  if p.iters == nil and p.max_iters ~= nil and iters > p.max_iters then
    iters = p.max_iters
  end
  if case_name ~= nil then iters, whole = 1, false end
  local budget = p.budget or DEFAULT_BUDGET
  local kept: string
  if p.dir ~= nil then
    kept = p.dir .. "/" .. slug(p.name) .. ".input"
    print(("fuzz %s: seed=%d iters=%d; the input under test is kept at %s"):
       format(p.name, seed, iters, kept))
  end
  if case_name == nil then check_corpus(p, budget, kept) end
  local counts: {string: integer} = {}
  local seeds = Rand.new(seed)
  for i = 1, iters do
    local draws: {Draw} = {}
    local mine: {string: boolean} = {}
    local case = case_seed or seeds:int(math.mininteger, math.maxinteger)
    local where = case_name ~= nil and ("FUZZ_CASE=%s:%d"):format(case_name, case) or
      ("seed=%d iteration=%d"):format(seed, i)
    local reproduce = ("FUZZ_CASE=%s:%d (this input alone), or FUZZ_SEED=%d FUZZ_ITERS=%d"):
      format(slug(p.name), case, seed, i)
    reached = mine
    local ok, input = pcall(p.gen, recording(Rand.new(case), draws))
    if not ok then reached = nil; error(input, 0) end
    if kept ~= nil then local _, _ = Fs.write(kept, input) end
    local held, why = attempt(p.check, input, budget)
    reached = nil
    for name in pairs(mine) do counts[name] = (counts[name] or 0) + 1 end
    if not held then
      -- A check that fails an input once and holds for it the next time
      -- depends on something beside the input: shrinking would chase
      -- noise, so the report says so and stops.
      local again, _ = attempt(p.check, input, budget)
      if again then
        error(("fuzz %s: %s: flaky: failed (%s), then held when the same input was " ..
          "checked again; it depends on something beside its input\n" ..
          "  input (%d bytes, hex): %s\n  %s\n  reproduce: %s"):
           format(p.name, where, why, #input, shown(input),
            kept ~= nil and ("kept at " .. kept) or "not kept: the property names no dir",
            reproduce), 0)
      end
      local function fails(values: {integer}): boolean, {Draw}
        local candidate, used = build(p.gen, values)
        local still, _ = attempt(p.check, candidate, budget)
        return not still, used
      end
      local shrunk = shrink.shrink(draws, fails, SHRINK_TRIES)
      local smallest, tries = shrunk.draws, shrunk.tries
      local small = build(p.gen, shrink.values_of(smallest))
      local small_held, small_why = attempt(p.check, small, budget)
      local flaky = ""
      if not small_held then
        why = small_why
      else
        -- The shrunk input failed while shrinking and held just now:
        -- report the input that first failed, and say why.
        small, smallest = input, draws
        flaky = "\n  flaky: the shrunk input held when checked again, so this is the input that first failed"
      end
      if kept ~= nil then local _, _ = Fs.write(kept, small) end
      local keep = corpus_of(p) .. "/" .. corpus_name(small)
      error(("fuzz %s: %s: %s\n" ..
        "  shrunk in %d tries from %d draws and %d bytes to %d draws and %d bytes; input (hex): %s%s\n" ..
        "  %s\n  reproduce: %s\n" ..
        "  once fixed, keep it as a regression case: %s"):
         format(p.name, where, why, tries, #draws, #input, #smallest, #small, shown(small), flaky,
          kept ~= nil and ("kept at " .. kept) or "not kept: the property names no dir",
          reproduce,
          kept ~= nil and ("mkdir -p %s && cp %s %s"):format(corpus_of(p), kept, keep)
            or ("write the input above to " .. keep)), 0)
    end
  end
  local line = label_counts(counts, p.requires, iters)
  if line ~= nil then print(("fuzz %s: labels: %s"):format(p.name, line)) end
  if whole and iters > 0 then
    for _, name in ipairs(p.requires or {}) do
      if counts[name] == nil then
        -- What is kept held; it is no failing input to keep.
        if kept ~= nil then local _, _ = Fs.remove(kept) end
        error(("fuzz %s: seed=%d: no input of %d reached %q, which the property requires: " ..
          "its inputs do not exercise what it is meant to"):format(p.name, seed, iters, name), 0)
      end
    end
  end
  return iters
end

--- Checks every `.input` file in the property's corpus, then draws
--- `p.iters` (or `FUZZ_ITERS`) inputs from `FUZZ_SEED` and checks each,
--- raising a report on the first that fails, after shrinking it, or when
--- no drawn input reached a label the property requires. Returns how many drawn inputs were
--- checked.
--- @param p Property The property to fuzz
--- @return integer How many inputs held
function Fuzz.run(p: Fuzz.Property): integer
  -- A check may run a property of its own: its labels are its own, and
  -- the enclosing input's count again once it is done.
  local enclosing = reached
  reached = nil
  local ok, n = pcall(run, p)
  reached = enclosing
  if not ok then error(n, 0) end
  return n
end

--- Checks one input directly, under the same budget as `run`: what
--- reproducing a kept input needs.
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

--- Whether a generator holding `have` elements of a collection of at
--- most `max` draws one more: a draw of its own before each element,
--- whose low end stops. A count drawn up front would tie every element
--- to it, so no element but the last could be cut; with a draw before
--- each, cutting an element is cutting two adjacent draws, and lowering
--- one to its low end cuts every element after it -- both of which
--- shrinking tries. The count is geometric, `max` / 2 on average
--- before the cap.
--- @param src Source The source
--- @param have integer How many elements the collection holds so far
--- @param max integer The most it may hold
--- @return boolean True to draw another element
function Fuzz.more(src: Fuzz.Source, have: integer, max: integer): boolean
  if have >= max then return false end
  return src:int(0, math.max(1, (max + 1) // 2)) ~= 0
end

--- Up to `max` arbitrary bytes, each after a `more` draw.
function Fuzz.bytes(src: Fuzz.Source, max: integer): string
  local out: {string} = {}
  while Fuzz.more(src, #out, max) do out[#out + 1] = string.char(src:int(0, 255)) end
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
  local edits = 0
  while Fuzz.more(src, edits, max_edits) do
    edits = edits + 1
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
