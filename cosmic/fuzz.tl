--- Seeded, shrinking property fuzzing for the parsers that face untrusted
--- bytes. A property names a generator, which builds one input from a
--- [`Source`]'s draws, and a check that must hold for every input. `run`
--- draws `FUZZ_ITERS` inputs (64 by default) from `FUZZ_SEED` (1 by
--- default), so the same seed reaches the same input at the same
--- iteration on every host. A check that returns false or raises fails
--- the run; so does one that spends more VM instructions than its budget,
--- which is how a parser that stops terminating is attributed to its
--- input instead of hanging the suite.
---
--- `FUZZ_SECONDS` bounds the seconds a property spends drawing and checking
--- inputs, not counting its corpus. Once the property has drawn 64 inputs and
--- used up the seconds, it draws no more: it prints a line starting
--- "fuzz stopped: " saying how many inputs it drew of those asked for, which
--- `cosmic test` lists at the end of the run even when the test passes, and
--- holds its labels to the inputs drawn. A property may always draw 64
--- inputs, however long they take. The limit is for a deep run (cosmic's nightly fuzz
--- workflow, say) over properties whose every input costs a tenth of a second or
--- more, where `FUZZ_ITERS=10000` would take hours. It never fails a property
--- by itself, and the inputs drawn are the first ones of the seed.
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
--- directory of inputs under `testdata/fuzz/` (from the directory the
--- tests run in, the tree's root under `cosmic test`) that `run` checks before
--- it draws anything: the report says how to copy the shrunk input
--- there, so a fixed bug stays fixed whatever seed a later run draws.
---
--- On the checked core, a property's `starved` runs on each input the
--- check holds for, drawn or of the corpus, with its allocations cut short
--- at a point drawn from the input's case, so the code that handles a
--- refused allocation is fuzzed too: it must return what an unstarved run
--- returns, or say that memory ran out. `run` prints how many runs were
--- starved and how many a refusal ended.
---
--- A check can `label` what an input reached ("opened", "read a
--- body"); `run` prints how many inputs reached each label, and a
--- property that `requires` a label fails when no input reached it, so
--- a generator whose inputs all stop at the first refusal is found out
--- rather than passing while it checks nothing; one whose `shares`
--- names a label fails when too few did, so one whose inputs mostly
--- stop there is found out too.
---
--- A project fuzzes its own parser from a `fuzz_*` function, which a plain
--- `cosmic test` checks at a few inputs and `cosmic test --fuzz-deep` at
--- many, in a file named
--- `*_fuzz_test.tl`:
---
--- ```teal
--- local Fuzz = require("cosmic.fuzz")
--- local Parse = require("app.parse")
---
--- local function fuzz_parse_never_raises(): Fuzz.Target
---   return Fuzz.target({
---     name = "parse total",
---     gen = function(src: Fuzz.Source): string return Fuzz.bytes(src, 200) end,
---     check = function(input: string): boolean, string
---       local ok, why = pcall(Parse.read, input)
---       return ok, tostring(why)
---     end,
---   })
--- end
--- ```

local Array = require("cosmic.array")
local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Rand = require("cosmic.rand")
local shrink = require("cosmic.internal.fuzz_shrink")
local type Budget = require("cosmic.internal.budget")
local testing = require("cosmic.internal.testing")
local String = require("cosmic.string")
local Test = require("cosmic.test")
local Globals = require("cosmic.internal.globals")

--- The instruction budget, handed to this module only when it loads from
--- the binary's own tree (core/store.c's `raw_modules`). It shares the
--- VM's one hook with coverage collection, so it holds under `cosmic test`.
--- Loaded any other way there is none, and a check that never ends is
--- ended by the test runner's deadline instead.
local extra: any = select(2, ...) -- checked: any_use
local type Arm = function(count?: integer)
local arm: Arm?
if type(extra) == "table" then
  arm = (extra as Budget).budget -- checked: cast_refused
end

--- What a spent budget raises (core/coverage.c). `coroutine.wrap`
--- prefixes a position when it passes the raise on, so it is matched as
--- the end of what was raised.
local BUDGET_MESSAGE <const> = "instruction budget exceeded"

local DEFAULT_SEED <const> = 1
local DEFAULT_ITERS <const> = 64

--- The fewest inputs a run bounded by `FUZZ_SECONDS` draws before it may
--- stop: the default count, which `requires` and `shares` are held to.
local MIN_BUDGETED <const> = DEFAULT_ITERS

--- What the line a stopped run prints starts with; `cosmic test` lists the
--- properties that printed it even when their tests pass
--- (build/test_report.tl's `stopped_prefix`).
local STOPPED_PREFIX <const> = "fuzz stopped: "

--- VM instructions one check may spend: seconds of work even under
--- coverage, far past what one parse of a small input should need.
local DEFAULT_BUDGET <const> = 50000000

--- How many times the budget a checked run (`cosmic test --check-types`)
--- allows: the code it compiles spends instructions on its checks, the
--- hook call at each narrowed read and typed boundary, that the budget is
--- not meant to count. The "wide" corpus input of core/sqlite_functions_fuzz_test.tl's
--- rtree property (40 rows) spends over 50M with them and under 100M.
local CHECKED_BUDGET_FACTOR <const> = 4

--- Reads the hook a checked run defines as a global, which a chunk reads,
--- since it is no field of the checker's `_G`.
local read_hook = assert(load("return __cosmic_tc", "=fuzz", "t", Globals.table()))

--- How many candidate inputs shrinking may check before it reports the
--- smallest failing one found so far.
local SHRINK_TRIES <const> = 2000

--- The most bytes of a failing input a report spells out in hex; the
--- file it is kept in holds all of it.
local SHOWN_BYTES <const> = 512

--- Where a property's corpus is, by default: one directory per
--- property, named for it, under this one at the tree's root.
local CORPUS_ROOT <const> = "testdata/fuzz"

--- A property that a test file's `fuzz_*` function returns, made by [`Fuzz.target`]: the test runner checks it
--- ([`Fuzz.run_target`]).
local class Target
  --- The property the runner checks.
  property: Fuzz.Property
end

local record Fuzz
  type Target = Target

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
    -- TODO: say, for a worker whose directory is a tmpfs of its own
    -- (build/test_sandbox.tl's `own_scratch`), that the kept input went with
    -- it, and keep it in the report instead (FUZZ_CASE names the case): the
    -- "kept at" paths below are gone once such a worker ends.
    --- The directory the input under test is kept in: a test's own
    --- temporary directory. Nothing is kept without one.
    dir?: string
    --- Work to run on an input with its allocations cut short, on the
    --- checked core: the input's own code under test, such as the decode
    --- the check calls, returning what it found as lines of text, each
    --- result or refusal its own line. After `check` holds for an input,
    --- `run` runs this once to learn what it returns and how many
    --- allocations it makes, then again with the first n of them granted,
    --- Lua's and the core's C heap's ([`testing.fail_allocations`]), and
    --- either the one after them or every one after them refused. For a
    --- drawn input, n and which are drawn from its case; a corpus input is
    --- starved at 16 points spread over its allocations, both ways. The
    --- starved run must return what the first did, but that a line may
    --- say memory ran out instead (and, when every later allocation was
    --- refused too, the lines after it are free), or raise that memory ran
    --- out; and `check` must hold again after it, as a refusal that left
    --- shared state broken would make it not. When every allocation after
    --- the n-th is refused, what the work raises after it handles the
    --- refusal is itself refused, and reads as memory running out: the
    --- runs that refuse one are those that see it. A crash in C is the
    --- sanitizer's to report. Any other core skips it.
    starved?: function(input: string): string
    --- Iterations, in place of `FUZZ_ITERS`.
    iters?: integer
    --- The most iterations `FUZZ_ITERS` may ask for, for a property whose
    --- every input costs a process or a file the size of a core: a deep
    --- run raises every other property's count, and this one's only to
    --- here.
    max_iters?: integer
    --- VM instructions one check may spend.
    budget?: integer
    --- Seconds the property may spend drawing, in place of
    --- `FUZZ_SECONDS` (none by default); see the module doc. Not held
    --- before 64 inputs have been drawn.
    seconds?: integer
    --- The directory of inputs checked before any is drawn: failures
    --- found before, kept so they stay fixed. `testdata/fuzz/` and the
    --- property's name, slugged, by default; one that does not exist
    --- holds nothing.
    corpus?: string
    --- One input to check in place of a run, as a report's `reproduce`
    --- line names it: `<property>:<case seed>`. `FUZZ_CASE` sets it for
    --- every property run, so it is for the one test file a report
    --- names: a property whose name it does not match checks nothing,
    --- its corpus included.
    case?: string
    --- Labels (see `label`) at least one drawn input must reach, or the
    --- run fails: what the property is meant to exercise. Not held when
    --- `FUZZ_ITERS` asks for fewer inputs than the default 64, as
    --- reproducing one failure does.
    requires?: {string}
    --- The least share of the drawn inputs, above 0 and at most 1, that
    --- must reach each label named, held when `requires` is: for a
    --- property whose generator could come to reach what it exists to
    --- exercise rarely rather than never. Set it well under the share
    --- a run reaches, so that another seed does not fall under it by
    --- chance.
    shares?: {string: number}
  end
end

local type Draw = shrink.Draw

--- A source over `values` that records what it hands out into `draws`.
--- A value outside the range asked for is clamped to its lower end, and
--- a draw past the end of `values` is its lower end, so any list of
--- integers replays to some input.
local function replaying(values: {integer}, draws: mut {Draw}): Fuzz.Source
  local replayed: integer = 0
  return {
    int = function(_self: Fuzz.Source, min: integer, max: integer): integer
      if min > max then
        error(("fuzz: int(%d, %d): min is greater than max"):format(min, max), 2)
      end
      replayed = replayed + 1
      local v = values[replayed]
      if v == nil or v < min or v > max then v = min end
      draws[#draws + 1] = { min = min, max = max, value = v }
      return v
    end,
  }
end

--- A source drawing from `rng` that records what it hands out.
local function recording(rng: Rand.Source, draws: mut {Draw}): Fuzz.Source
  return {
    int = function(_self: Fuzz.Source, min: integer, max: integer): integer
      local v = rng:int(min, max)
      draws[#draws + 1] = { min = min, max = max, value = v }
      return v
    end,
  }
end

--- An integer from the environment, or `otherwise` when it is unset.
--- Raises when it is set to anything but a non-negative integer, so a
--- typo is never a silent default.
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
local record Counting
  mut reached?: {string: boolean}
end

local counting: Counting = {}
--- Records that the input under check reached `name`: an outcome worth
--- counting ("opened", "refused at the header", "read a body"). `run`
--- prints how many inputs reached each label and fails a property that
--- `requires` one no input reached, or whose `shares` names one fewer
--- than that share of its inputs reached. Outside `run`'s drawn inputs it
--- does nothing.
--- @param name string The label
function Fuzz.label(name: string)
  local reached = counting.reached
  if reached ~= nil then reached[name] = true end -- checked: view_written
end

--- Runs `check` on `input` once, under the budget.
local function attempt(check: function(string): boolean, string, input: string,
                       budget: integer): boolean, string
  if arm then
    arm(if (read_hook()) ~= nil then budget * CHECKED_BUDGET_FACTOR else budget end)
  end
  local ok, held, why = pcall(check, input)
  if arm then arm() end
  if not ok then
    local raised = tostring(held)
    if String.ends_with(raised, BUDGET_MESSAGE) then
      return false, ("spent its budget of %d VM instructions"):format(budget)
    end
    return false, "raised: " .. raised
  end
  if held ~= true then
    return false, if why ~= "" then why else "check returned false" end
  end
  return true, ""
end

--- Whether this core has allocations to refuse: only the checked one does.
local CHECKED <const> = testing.configuration == "sanitized"

--- Whether `text` says that memory ran out: Lua's "not enough memory",
--- the coverage collector's "out of memory", an errno's "Out of memory",
--- a library's "no memory for ...".
local function names_memory(text: string): boolean
  local lower = text:lower()
  return lower:find("out of memory", 1, true) ~= nil or lower:find("not enough memory", 1, true) ~= nil or
    lower:find("no memory", 1, true) ~= nil
end

--- `text` as lines.
local function lines_of(text: string): {string}
  local out: mut {string} = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
  return out
end

--- Why a starved run's text `got` is not one the unstarved run's `want`
--- allows, or nil when it is, compared line by line. A line may differ
--- where it says that memory ran out and its unstarved line does not.
--- When every allocation after the refused one was refused too, the
--- lines after the first such line may differ as they will. When only
--- that one was, a later line must be the same or say that memory ran
--- out, though the lines may end early: a refusal may end what was being
--- read. A starved function writes one line for each step that could go
--- on after a refusal, so that a step after it is held to its result.
local function starved_differs(got: string, want: string, once: boolean): string?
  if got == want then return nil end
  local got_lines, want_lines = lines_of(got), lines_of(want)
  local refused_at: integer? = nil
  for i = 1, math.max(#got_lines, #want_lines) do
    local g, w = got_lines[i], want_lines[i]
    if g == nil then
      if refused_at ~= nil then return nil end
      return ("it ends at line %d, where unstarved it goes on"):format(i)
    end
    if g ~= w then
      if w == nil or not names_memory(g) or names_memory(w) then
        return ("line %d is %q, where unstarved it is %q"):format(i, g, w or "(none)")
      end
      if not once then return nil end
      refused_at = i
    end
  end
  return nil
end

--- How a starved run of an input is cut short: after which share of the
--- allocations an unstarved run of it makes, in 2^-30ths, and whether
--- only that one allocation is refused or every one after it too.
local record Starve
  share: integer
  once: boolean
end

--- The [`Starve`] of the input `case` names, from a source of its own so
--- the input's draws are the same with it or without.
local function starve_of(case: integer): Starve
  local rng = Rand.new(case ~ 0x73746172766564)
  return { share = rng:int(0, 1 << 30), once = rng:int(0, 1) == 1 }
end

--- At how many shares of its allocations each corpus input is starved,
--- each both ways.
local CORPUS_STARVES <const> = 16

--- What starved runs a property has made: how many, how many had an
--- allocation refused, and how many a refusal ended with a raise.
local record Starving
  mut runs: integer
  mut refused: integer
  mut raised: integer
end
local starving: Starving = { runs = 0, refused = 0, raised = 0 }

--- One run of a property's `starved`: whether it returned, what it
--- returned or raised, and how many allocations were refused and granted.
local record Run
  returned: boolean
  text: string
  refused: integer
  used: integer
end

--- Runs `work` on `input` with `fail_allocations(after, once)` under the budget.
local function starved_run(work: function(string): string, input: string, budget: integer, after: integer,
                           once: boolean): Run
  if arm then
    arm(if (read_hook()) ~= nil then budget * CHECKED_BUDGET_FACTOR else budget end)
  end
  testing.fail_allocations(after, once)
  local returned, text = pcall(work, input)
  local refused, used = testing.allow_allocations()
  if arm then arm() end
  collectgarbage("collect")
  return { returned = returned, text = tostring(text), refused = refused, used = used }
end

--- What an input of a property was found to do: whether it held, why
--- not, and whether the starved run or the check after it failed rather
--- than the first check.
local record Verdict
  held: boolean
  why: string
  by_starving: boolean
end

--- [`attempt`] of `check`, then, on the checked core, of `starved` cut
--- short as `starve` says and of `check` again: what an input of a
--- property with `starved` must hold to. `by_starving` is true when
--- the starved run or the check after it failed, not the first check.
local function attempt_all(p: Fuzz.Property, input: string, budget: integer, starve: Starve): Verdict
  local held, why = attempt(p.check, input, budget)
  local starved = p.starved
  if not held then return { held = false, why = why, by_starving = false } end
  if starved == nil or not CHECKED then return { held = true, why = "", by_starving = false } end
  local reached = counting.reached
  counting.reached = nil
  -- Unstarved first: what the work returns, and how many allocations it makes.
  local want = starved_run(starved, input, budget, math.maxinteger, false)
  local after = (starve.share * want.used) >> 30
  local got = want
  if want.returned then got = starved_run(starved, input, budget, after, starve.once) end
  counting.reached = reached
  local function failed(text: string): Verdict
    return { held = false, why = text, by_starving = true }
  end
  if not want.returned then
    if String.ends_with(want.text, BUDGET_MESSAGE) then
      return failed(("starved, unstarved run: spent its budget of %d VM instructions"):format(budget))
    end
    return failed("starved, unstarved run: raised: " .. want.text)
  end
  local how = ("starved after %s of %d%s (%d refused)"):format(String.counted(after, "allocation"), want.used,
    if starve.once then ", refusing one" else "" end, got.refused)
  starving.runs = starving.runs + 1
  if got.refused > 0 then starving.refused = starving.refused + 1 end
  if not got.returned then
    starving.raised = starving.raised + 1
    if String.ends_with(got.text, BUDGET_MESSAGE) then
      return failed(("%s: spent its budget of %d VM instructions"):format(how, budget))
    end
    if got.refused == 0 or not names_memory(got.text) then
      return failed(("%s: raised: %s"):format(how, got.text))
    end
  else
    local differs: string? = nil
    if got.refused > 0 then
      differs = starved_differs(got.text, want.text, starve.once)
    elseif got.text ~= want.text then
      differs = "it returned otherwise with no allocation refused"
    end
    if differs ~= nil then
      return failed(("%s: returned %q, where unstarved it returns %q: %s"):format(how, got.text, want.text, differs))
    end
  end
  local again, again_why = attempt(p.check, input, budget)
  if not again then
    return failed(("after a run %s, the check no longer holds: %s"):format(how, again_why))
  end
  return { held = true, why = "", by_starving = false }
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

--- Raises the report of a corpus input that failed its property, which the
--- check of the input hands to `assert`, so a failure is the one raised and
--- an input that held is a call to it made.
local function corpus_failed(p: Fuzz.Property, path: string, why: string, input: string): boolean
  error(("fuzz %s: corpus input %s: %s\n  input (hex, %s): %s"):
      format(p.name, path, why, String.counted(#input, "byte"), shown(input)), 0)
  return false -- checked: unreachable
end

--- Checks every `.input` file in the property's corpus, in name order,
--- raising a report on the first that fails; each is written to `kept`
--- first, as a drawn input is. Returns how many were checked.
--- The paths of the `.input` files in the property's corpus, in name
--- order: none when it has no corpus. Raises when the corpus cannot be
--- listed.
local function corpus_paths(p: Fuzz.Property): {string}
  local dir = corpus_of(p)
  local there, look_trouble = Fs.status(dir)
  local trouble = if there == nil then tostring(look_trouble) else "" end
  if there ~= nil and not there.exists then return {} end
  local names: {string}?
  if there ~= nil then
    local listed, why = Fs.list(dir)
    names = listed
    if listed == nil then trouble = tostring(why) end
  end
  if names == nil then
    error(("fuzz %s: corpus %s: %s"):format(p.name, dir, trouble), 0)
  end
  local paths: mut {string} = {}
  for _, name in ipairs(names) do
    if name:sub(-6) == ".input" then paths[#paths + 1] = dir .. "/" .. name end
  end
  return paths
end

--- The input kept at `path` in the property's corpus. Raises when it
--- cannot be read.
local function corpus_input(p: Fuzz.Property, path: string): string
  local input, trouble = Fs.read(path)
  if input == nil then
    error(("fuzz %s: corpus %s: %s"):format(p.name, path, trouble), 0)
  end
  return input
end

local function check_corpus(p: Fuzz.Property, budget: integer, kept: string?): integer
  local checked = 0
  for _, path in ipairs(corpus_paths(p)) do
    local input = corpus_input(p, path)
    if kept ~= nil then local _, _ = Fs.write(kept, input) end
    -- A kept input is starved at a spread of points, in both ways: the
    -- one that failed when it was found among them, or near it.
    local starves: {Starve} = { { share = 0, once = false } }
    if p.starved ~= nil and CHECKED then
      local spread: mut {Starve} = {}
      for k = 0, CORPUS_STARVES - 1 do
        local share = (k << 30) // CORPUS_STARVES
        spread[#spread + 1] = { share = share, once = false }
        spread[#spread + 1] = { share = share, once = true }
      end
      starves = spread
    end
    for _, starve in ipairs(starves) do
      local verdict = attempt_all(p, input, budget, starve)
      assert(verdict.held or corpus_failed(p, path, verdict.why, input))
    end
    checked = checked + 1
  end
  return checked
end

--- The line `run` prints of how many inputs reached each label, in
--- name order, or nil when no label was reached and none is required.
local function label_counts(counts: {string: integer}, required: {string},
                            iters: integer): string?
  local names: mut {string} = {}
  for name in pairs(counts) do names[#names + 1] = name end
  for _, name in ipairs(required) do
    if counts[name] == nil then names[#names + 1] = name end
  end
  if #names == 0 then return nil end
  table.sort(names)
  local parts: mut {string} = {}
  for i, name in ipairs(names) do
    parts[i] = ("%s %d"):format(name, counts[name] or 0)
  end
  return ("%s (of %s)"):format(table.concat(parts, ", "), String.counted(iters, "input"))
end

--- Builds the input `values` replay to, with the draws that built it.
local function build(gen: function(Fuzz.Source): string, values: {integer}): string, {Draw}
  local draws: mut {Draw} = {}
  local input = gen(replaying(values, draws))
  return input, draws
end

--- [`build`] for a candidate of shrinking, under `budget`: the input it
--- builds and its draws, or nil when the generator spent the budget on it.
--- A replay gives a draw past the end of its list the low end of its
--- range, so a generator that loops until a draw is not the low end (a
--- `while src:int(1, 3) == 1 do`) never ends on a list cut short, and
--- grows without bound; the candidate is then no failing input, and the
--- shrink goes on. A generator must stop at the low end of a draw (see
--- [`Fuzz.more`]), but this is what keeps one that does not from taking
--- the machine. A generator that raises otherwise raises here as before.
local record Built
  mut input?: string
  mut draws: {Draw}
end

local function build_within(gen: function(Fuzz.Source): string, values: {integer}, budget: integer): string?, {Draw}
  local made: Built = { draws = {} }
  if arm then
    arm(if (read_hook()) ~= nil then budget * CHECKED_BUDGET_FACTOR else budget end)
  end
  local ok, raised = pcall(function()
    local input, draws = build(gen, values)
    made.input, made.draws = input, draws
  end)
  if arm then arm() end
  if not ok then
    if String.ends_with(tostring(raised), BUDGET_MESSAGE) then
      return nil, {}
    end
    error(raised, 0)
  end
  return made.input, made.draws
end

--- The one input a case names -- `p.case`, else `FUZZ_CASE` -- as the
--- property's slug and the seed of the source that drew it, as a report
--- prints them. Nil when neither is set; raises when one is set to
--- anything else, so a typo is never a silent full run.
local function named_case(p: Fuzz.Property): string?, integer?
  local text = p.case or (Env.read("FUZZ_CASE") or "")
  if text == "" then return nil, nil end
  local raw = text
  local name = text:match("^(.-):%-?%d+$")
  local digits = text:match(":(%-?%d+)$")
  local n: integer? = if digits ~= nil then math.tointeger(tonumber(digits)) else nil end
  if name == nil or not name:match("^[%w%-]+$") or n == nil then
    error(("fuzz: FUZZ_CASE=%q is not <property>:<case seed>, as a report prints it"):format(raw), 0)
  end
  return name, n
end

--- A label of `shares` and the share of the inputs it must reach.
local record SharedLabel
  name: string
  share: number
end

--- `run`'s work, with no labels being counted when it starts.
local function run(p: Fuzz.Property, given_dir?: string): integer
  local case_name, case_seed = named_case(p)
  -- TODO: a well-formed case naming no property in the file passes
  -- silently, every property skipping it; the runner could fail a run in
  -- which none matched, once a test can report such a thing to it.
  for name, share in pairs(p.shares or {}) do
    if not (share > 0 and share <= 1) then
      error(("fuzz %s: the share of %q is %s, not in (0, 1]"):format(p.name, name, tostring(share)), 0)
    end
  end
  if case_name ~= nil and case_name ~= slug(p.name) then return 0 end
  local seed = nonnegative_env("FUZZ_SEED", DEFAULT_SEED)
  local iters = p.iters or nonnegative_env("FUZZ_ITERS", DEFAULT_ITERS)
  -- Fewer inputs than the default, as reproducing one failure asks for,
  -- may reach no label at all by chance: `requires` holds of a whole run.
  local whole = p.iters ~= nil or iters >= DEFAULT_ITERS
  local max_iters = p.max_iters
  if p.iters == nil and max_iters ~= nil and iters > max_iters then
    iters = max_iters
  end
  if case_name ~= nil then iters, whole = 1, false end
  local budget = p.budget or DEFAULT_BUDGET
  local seconds = p.seconds or nonnegative_env("FUZZ_SECONDS", 0)
  local asked = iters
  local kept: string?
  local dir = p.dir or given_dir
  if dir ~= nil then
    kept = dir .. "/" .. slug(p.name) .. ".input"
    print(("fuzz %s: seed=%d iters=%d; the input under test is kept at %s"):
        format(p.name, seed, iters, kept))
  end
  local replayed = 0
  starving.runs, starving.refused, starving.raised = 0, 0, 0
  if case_name == nil then replayed = check_corpus(p, budget, kept) end
  -- After the corpus: its inputs spend none of the seconds, nor skew the cost of a drawn one.
  local began_ns = Clock.monotonic_ns()
  local counts: mut {string: integer} = {}
  local seeds = Rand.new(seed)
  for i = 1, asked do
    if seconds > 0 and i > MIN_BUDGETED and Clock.monotonic_ns() - began_ns >= Clock.seconds(seconds) then
      iters = i - 1
      print(("%s%s drew %d of %d %s in %d s (FUZZ_SECONDS=%d): each cost about %.2f s"):
          format(STOPPED_PREFIX, p.name, iters, asked, (if asked == 1 then "input" else "inputs" end), (Clock.monotonic_ns() - began_ns) // Clock.seconds(1),
            seconds, (Clock.monotonic_ns() - began_ns) / 1e9 / iters))
      break
    end
    local draws: mut {Draw} = {}
    local mine: {string: boolean} = {}
    local case = case_seed or seeds:int(math.mininteger, math.maxinteger)
    local where = if case_name ~= nil then ("FUZZ_CASE=%s:%d"):format(case_name, case) else
      ("seed=%d iteration=%d"):format(seed, i) end
    local reproduce = ("FUZZ_CASE=%s:%d (this input alone)"):format(slug(p.name), case)
    if case_name == nil then
      reproduce = reproduce .. (", or FUZZ_SEED=%d FUZZ_ITERS=%d"):format(seed, i)
    end
    counting.reached = mine
    local ok, input = pcall(p.gen, recording(Rand.new(case), draws))
    if not ok then
      counting.reached = nil
      error(input, 0)
    end
    if kept ~= nil then local _, _ = Fs.write(kept, input) end
    local starve = starve_of(case)
    local verdict = attempt_all(p, input, budget, starve)
    local held, why, by_starving = verdict.held, verdict.why, verdict.by_starving
    counting.reached = nil
    for name in pairs(mine) do counts[name] = (counts[name] or 0) + 1 end
    -- Raises the report of an input that failed, after shrinking it; the
    -- check of the input hands it to `assert` below, so an input that held
    -- is a call to `assert` made, and a failure is the report raised.
    local function failure(): boolean
      local reason = why
      -- A check that fails an input once and holds for it the next time
      -- depends on something beside the input: shrinking would chase
      -- noise, so the report says so and stops.
      local again = attempt_all(p, input, budget, starve).held
      if again then
        error(("fuzz %s: %s: flaky: failed (%s), then held when the same input was " ..
          "checked again; it depends on something beside its input\n" ..
          "  input (%s, hex): %s\n  %s\n  reproduce: %s"):
            format(p.name, where, reason, String.counted(#input, "byte"), shown(input),
              if kept ~= nil then ("kept at " .. kept) else "not kept: the property names no dir" end,
              reproduce), 0)
      end
      local function fails(values: {integer}): boolean, {Draw}
        local candidate, used = build_within(p.gen, values, budget)
        if candidate == nil then return false, used end
        -- A failure of the check is shrunk as one; a starved one keeps
        -- its share of the allocations, which falls where it may.
        if not by_starving then
          local still, _ = attempt(p.check, candidate, budget)
          return not still, used
        end
        -- Only a starved failure: one of the check is another failure.
        local candidate_verdict = attempt_all(p, candidate, budget, starve)
        return not candidate_verdict.held and candidate_verdict.by_starving, used
      end
      local shrunk = shrink.shrink(draws, fails, SHRINK_TRIES)
      local smallest, tries = shrunk.draws, shrunk.tries
      local small = build(p.gen, shrink.values_of(smallest))
      local small_verdict = attempt_all(p, small, budget, starve)
      local small_held, small_why = small_verdict.held, small_verdict.why
      local flaky = ""
      if not small_held then
        reason = small_why
      else
        -- The shrunk input failed while shrinking and held just now:
        -- report the input that first failed, and say why.
        small, smallest = input, draws
        flaky = "\n  flaky: the shrunk input held when checked again, so this is the input that first failed"
      end
      if kept ~= nil then local _, _ = Fs.write(kept, small) end
      local keep = corpus_of(p) .. "/" .. corpus_name(small)
      error(("fuzz %s: %s: %s\n" ..
        "  shrunk in %s from %s and %s to %s and %s; input (hex): %s%s\n" ..
        "  %s\n  reproduce: %s\n" ..
        "  once fixed, keep it as a regression case: %s"):
          format(p.name, where, reason, String.counted(tries, "try", "tries"), String.counted(#draws, "draw"),
            String.counted(#input, "byte"), String.counted(#smallest, "draw"), String.counted(#small, "byte"), shown(small), flaky,
            if kept ~= nil then ("kept at " .. kept) else "not kept: the property names no dir" end,
            reproduce,
            if kept ~= nil then ("mkdir -p %s && cp %s %s"):format(corpus_of(p), kept, keep) else
              ("write the input above to " .. keep) end), 0)
      return false -- checked: unreachable
    end
    assert(held or failure())
  end
  -- An input checked is a call to `assert` made; a run that drew none and
  -- replayed none (FUZZ_ITERS=0, as CI's gating runs set) says so.
  if iters == 0 and replayed == 0 then
    Test.passed_unchecked("fuzz properties drew no input (FUZZ_ITERS=0, no corpus)")
  end
  local named: mut {string} = {}
  local is_named: mut {string: boolean} = {}
  for _, name in ipairs(p.requires or {}) do named[#named + 1], is_named[name] = name, true end
  local shares = p.shares or {}
  local shared: mut {SharedLabel} = {}
  for name, share in pairs(shares) do shared[#shared + 1] = { name = name, share = share } end
  table.sort(shared, function(x, y): boolean return x.name < y.name end)
  for _, label in ipairs(shared) do
    if is_named[label.name] ~= true then named[#named + 1] = label.name end
  end
  if starving.runs > 0 then
    print(("fuzz %s: starved: %s, %d with an allocation refused, %d ended by a refusal"):
        format(p.name, String.counted(starving.runs, "run"), starving.refused, starving.raised))
  end
  local line = label_counts(counts, named, iters)
  if line ~= nil then print(("fuzz %s: labels: %s"):format(p.name, line)) end
  if whole and iters > 0 then
    for _, name in ipairs(p.requires or {}) do
      if counts[name] == nil then
        -- The kept input held, so it is no failing input to keep.
        if kept ~= nil then local _, _ = Fs.remove(kept) end
        error(("fuzz %s: seed=%d: no input of %d reached %q, which the property requires: " ..
          "its inputs do not exercise what it is meant to"):format(p.name, seed, iters, name), 0)
      end
    end
    for _, label in ipairs(shared) do
      local name = label.name
      local reached_by = counts[name] or 0
      if reached_by < label.share * iters then
        if kept ~= nil then local _, _ = Fs.remove(kept) end
        error(("fuzz %s: seed=%d: %s of %d reached %q, under the share of %g the property " ..
          "requires: its inputs exercise it too rarely"):format(p.name, seed, String.counted(reached_by, "input"), iters, name,
            label.share), 0)
      end
    end
  end
  return iters
end

--- Checks every `.input` file in the property's corpus, then draws
--- `p.iters` (or `FUZZ_ITERS`) inputs from `FUZZ_SEED` and checks each,
--- raising a report on the first that fails (after shrinking it), when
--- no drawn input reached a label the property requires, or when fewer
--- than a label's share in `p.shares` did. Raises at once on a share
--- outside (0, 1]. Returns how many drawn inputs were checked.
--- @param p Property The property to fuzz
--- @param dir string The directory the input under test is kept in where `p.dir` names none
--- @return integer How many inputs held
function Fuzz.run(p: Fuzz.Property, dir?: string): integer
  -- A check may run a property of its own: its labels are its own, and
  -- the enclosing input's count again once it is done.
  local enclosing = counting.reached
  counting.reached = nil
  local ok, n = pcall(run, p, dir)
  counting.reached = enclosing
  if not ok then error(n, 0) end
  return n
end

--- What a test file's `fuzz_*` function returns: `p`, for the test runner to check at `FUZZ_ITERS` inputs, a plain
--- `cosmic test`'s few or `cosmic test --fuzz-deep`'s many.
---
---     local function fuzz_parse_is_total(): Fuzz.Target
---       return Fuzz.target({ name = "parse total", gen = gen, check = check })
---     end
function Fuzz.target(p: Fuzz.Property): Fuzz.Target
  return { property = p }
end

--- Checks the property `value` holds, a [`Fuzz.Target`] that a `fuzz_*` function returned, as [`Fuzz.run`] does,
--- keeping the input under test in `dir` where the property names no directory of its own. Raises when `value`
--- is no target. The test runner's call of a `fuzz_*` function.
function Fuzz.run_target(value: any, dir: string): integer
  if not (value is Target) then
    error("a fuzz_* function returns a Fuzz.Target, made by Fuzz.target(property), and this returned a " ..
        type(value), 0)
  end
  return Fuzz.run(value.property, dir)
end

--- The inputs a run of `target` checks, for another body of its file to
--- use: a bench that times the module on them, say. They are the
--- property's corpus, in name order, then `n` drawn as `run` draws them
--- from `seed` (`FUZZ_SEED`, else 1), so the drawn ones are the inputs a
--- run checks at iterations 1 through `n`. Raises when the corpus cannot
--- be read, or the generator raises.
---
---     local function bench_decode_drawn(b: Bench.B)
---       local inputs = Fuzz.inputs(fuzz_decode_is_total(), 256)
---       b.reset()
---       for _ = 1, b.n do
---         for _, input in ipairs(inputs) do Codec.decode(input) end
---       end
---     end
function Fuzz.inputs(target: Fuzz.Target, n: integer, seed?: integer): {string}
  local p = target.property
  local inputs: mut {string} = {}
  for _, path in ipairs(corpus_paths(p)) do inputs[#inputs + 1] = corpus_input(p, path) end
  local seeds = Rand.new(seed or nonnegative_env("FUZZ_SEED", DEFAULT_SEED))
  for _ = 1, n do
    local case = seeds:int(math.mininteger, math.maxinteger)
    inputs[#inputs + 1] = p.gen(recording(Rand.new(case), {}))
  end
  return inputs
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
  return Array.at(choices, src:int(1, #choices))
end

--- Whether a generator holding `have` elements of a collection of at
--- most `max` draws one more: a draw of its own before each element,
--- whose low end stops. A count drawn up front would tie every element
--- to it, so no element but the last could be cut; with a draw before
--- each, cutting an element is cutting two adjacent draws, and lowering
--- one to its low end cuts every element after it -- both of which
--- shrinking tries. The count is geometric: before the cap its mean is
--- `max` / 2 (at least 1), and the cap takes it lower (17 for a `max` of
--- 40).
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
  local out: mut {string} = {}
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
      s = s:sub(1, at - 1) .. string.char(Array.at(SPECIAL, src:int(1, #SPECIAL))) .. s:sub(at + 1)
    elseif kind == 3 then
      local at = src:int(1, #s)
      s = s:sub(1, at - 1) .. string.char(String.byte_at(s, at) ~ (1 << src:int(0, 7))) .. s:sub(at + 1)
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
  local parts: mut {string} = {}
  for i, f in ipairs(fields) do parts[i] = string.pack("<s4", f) end
  return table.concat(parts)
end

--- The fields `pack` packed into `input`.
function Fuzz.unpack(input: string): {string}
  local out: mut {string} = {}
  local at = 1
  while at <= #input do
    local f: string
    f, at = string.unpack("<s4", input, at)
    out[#out + 1] = f
  end
  return out
end

return Fuzz
