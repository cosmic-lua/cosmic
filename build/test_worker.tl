--- One test, run in a process of its own: the other half of
--- [`build.test`], which starts this as `cosmic test --worker <root>
--- <module> <test> <tmp> <children> <needs>` and alone records what it
--- reports.
---
--- The worker never opens the build database. It attaches the tree's
--- compiled modules, loads the test's module, calls the one test with
--- its temporary directory, and writes a report to descriptor 3: which
--- lines the load and the test hit, how long the test took, and whether
--- it passed. Its standard streams are the test's,
--- captured by the runner. A report that is missing or cut short --
--- the test exited the process, crashed it, or ran past its deadline --
--- is itself the runner's answer that the test failed. A whole report
--- passes only if the process then exits successfully.

local type Child = require("cosmic.child")
local type Sandbox = require("cosmic.sandbox")
local Coverage = require("cosmic.coverage")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local env_get = Env.get
local Proc = require("cosmic.proc")
local type raw_store = require("cosmic.internal.store")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local raw_errors = require("cosmic.internal.errors")
local Assertions = require("build.assertions")
local confine = require("build.confine")
local load_module = require("build.load_module")
local key_parts = require("build.key_parts")
local test_inputs = require("build.test_inputs")

--- The store's raw table, which the searcher hands this module as its
--- loader's extra value when it loads trusted (core/store.c's
--- `raw_modules`): the worker attaches the store it is given through it, as
--- a loader no test can replace on [`cosmic.store`]'s table. Boot mode,
--- which runs no worker, has it by name alone.
local extra: any = select(2, ...)
local store: raw_store
if type(extra) == "table" then
  store = extra as raw_store
else
  store = require("cosmic.internal.store")
end

local record worker
  --- What one worker found, as the runner reads it back.
  record Report
    loaded: boolean
    passed: boolean
    message: string
    elapsed_ns: integer
    load_hits: Coverage.Hits
    test_hits: Coverage.Hits
    --- The name of every module in the worker's `package.loaded` once
    --- its test has run, sorted: what it ran, which `judge` holds to
    --- what a key holds of it (`loads`).
    modules: {string}
    --- Why its test is skipped ([`Test.skip`]): each reason it was given,
    --- once, joined by "; "; "" or nil where it called none.
    skipped?: string
    --- How many calls to `assert` the test made while it ran, through
    --- every helper and fixture it called: 0 for one that did not run.
    --- A test that passes with none made no call to `assert`
    --- ([`Judgement.unchecked`]).
    asserted?: integer
    --- What [`Test.passed_unchecked`] said, "" where it was not called: the
    --- test passed having deliberately not checked, which is no
    --- [`Judgement.unchecked`].
    deliberate?: string
    --- The violations a checked run's worker met, in the order met, and
    --- how many more it kept no record of ([`worker.install_checks`]).
    violations?: {Violation}
    dropped?: integer
  end

  --- One value that crossed a typed boundary of a checked run
  --- ([`importer.compile`]'s `checks`) as a kind its declared type does
  --- not admit, which the run reports, and fails where it is a parameter
  --- declared under "cosmic/" ([`worker.install_checks`]). `at` is the place
  --- that sent it: the caller's file and line for a parameter, the `return`
  --- or the write for a return value and a field. The same boundary, place
  --- and kinds again count up `count`.
  ---
  --- A "fact" is the exception: a read whose type the new checker narrowed
  --- ([`lang.fact_wraps`]), of a value the conclusion is false of. `at` is
  --- the read (`file:line:column`), `target` the place as written, `declared`
  --- what the checker proved ("not nil", "one of a|b") and `actual` what the
  --- value was; the read raises, which fails its test.
  record Violation
    kind: string
    at: string
    target: string
    declared: string
    actual: string
    count: integer
  end

  --- How a sandboxed worker is held by a Landlock ruleset
  --- ([`confine.forbid_running`]) before anything of its test loads:
  --- "forbid" to running anything but this very program, for one whose
  --- module does not declare `tool`; "mounts", running anything, for one
  --- that declares `tool` -- which holds it, as any ruleset does, to
  --- confining nothing in a root of its own; and "none" for one whose
  --- module declares `nests`, or that runs unsandboxed.
  enum Hold
    "forbid"
    "mounts"
    "none"
  end

  --- What starts one test's worker (`invocation`).
  record Invocation
    --- How this program is started again (`program`).
    start: Proc.Relaunch
    --- The environment the worker is given, less what starting it adds
    --- (`invocation`).
    env: {string:string}
    --- The tree and the test's scratch directory as the worker sees
    --- them, and where it runs (nil for here); the test's module and
    --- its name; and what the build read of the module's `policy`
    --- ([`test_inputs.canonical`]).
    root: string
    cwd?: string
    module_path: string
    name: string
    scratch: string
    --- Whether the worker makes the directory `scratch` names itself, in
    --- a tmpfs of its own (`--own-scratch`), where the runner made none.
    own_scratch?: boolean
    needs: string
    --- How its Landlock ruleset holds it (`hold_flag`).
    hold: worker.Hold
    --- The store it attaches (`--store`): where its sandbox gives it
    --- one, or, unsandboxed, the store of its module's closure, or the
    --- projection for a module that declares `store`. The runner names
    --- it, so the worker resolves no build directory itself.
    store?: string
    --- The names of the module's import closure and of every module of
    --- the tree (see `run`).
    closure: {string}
    tree: {string}
    --- The policy the worker is started under ([`build.test_policy`]),
    --- whose `set_env` is its whole environment but for what `env` and
    --- `start` add; nil where it runs unsandboxed.
    policy?: Sandbox.Policy
    --- The paths the policy lets the worker run, which a worker held to
    --- running nothing but what its test may (`hold` "forbid") is told,
    --- since a worker the policy holds cannot list / to find them
    --- (`--runs`).
    runs?: {string}
    --- Whether the worker reports the violations of the run-time checks
    --- its modules carry (`COSMIC_TEST_TYPES`).
    checks?: boolean
    --- The name the worker is to have its program by, in place of the
    --- artifact path `start` names (build.test_sandbox's
    --- [`Plan.program`]), or nil to keep that.
    program?: string
  end

  --- How a worker starts (`invocation`): its command line and its
  --- start options, for [`Child.start`].
  record Command
    argv: {string}
    options: Child.Options
  end

  --- What `judge` reads a finished worker by.
  record Judging
    --- The worker's end, or nil where it could not be started or
    --- supervised.
    result?: Child.Result
    --- Why there is no result; with one, what the worker left running
    --- past its end, or "" for nothing.
    trouble: string
    --- Whether `trouble` is why its worker was never started -- its
    --- module declares what cannot be given it -- said as it is.
    refused?: boolean
    timeout_ns: integer
    sandboxed: boolean
    --- Where the loaded set is held (`unkeyed`): the modules of the
    --- tree the tool carries and the test's import closure, each a set
    --- of names; nil for no such hold.
    carried?: {string:boolean}
    closure?: {string:boolean}
  end

  --- A finished worker's verdict: its report, nil where there is none,
  --- and whether its test passed, with what to say of it; and, of one
  --- that passed, why it is skipped instead ([`Report.skipped`]), "" for
  --- a pass.
  record Judgement
    report?: Report
    passed: boolean
    message: string
    skipped?: string
    --- Whether it passed, and was not skipped, without one call to `assert`
    --- ([`Report.asserted`]): it ran and made no call to `assert`, which a held run
    --- fails and no run keeps a verdict of.
    unchecked?: boolean
    --- Of one that passed, what it said it deliberately did not check
    --- for ([`Report.deliberate`]), "" for none.
    deliberate?: string
  end

  --- The descriptor the report is written to.
  report_fd: integer

  --- The most distinct violations a worker keeps a record of: any more are
  --- counted ([`worker.dropped_violations`]) and nothing else.
  most_kept: integer

  install_checks: function()
  --- Crosses a boundary by hand, as the Lua of a checked function does by calling the `__cosmic_tc` that [`install_checks`]
  --- defines ([`lang.boundary_checks`]): `text` is the spec ("p" parameters, "r" return values, "f" a field written) and
  --- `values` the values crossing it. It answers nothing, where the global answers the values: a test that needs them keeps
  --- them. A violation of a parameter is placed at the line that called `cross`, where a checked function's is placed at its
  --- caller's.
  cross: function(text: string, ...: any)
  --- The `__fact` that [`install_checks`] defines: the hook the calls of [`lang.fact_wraps`] run, for a test that runs
  --- the Lua of a program with them.
  fact: function(v: any, taken: string, place: string, strings?: {string}, classes?: {any}, tag?: string,
                 tags?: {string} | string, at?: string): any
  violations: function(): {Violation}
  dropped_violations: function(): integer

  loads: {string}
end

worker.report_fd = 3

local HEADER <const> = "cosmic-test-report-4"
-- A second in nanoseconds, which a timeout is counted in: cosmic.clock,
-- whose `seconds` this is, is no module the harness may reach
-- (build/harness_epoch.tl's `library`).
local SECOND_NS <const> = 1000 * 1000 * 1000

--- The modules of the tree a worker loads besides its test's import
--- closure, which is the code a worker runs of the tree but its test's:
---
--- - cosmic's own main (cmd/cosmic/main.tl), which every process runs
---   first and which starts this ahead of build.dispatch. A worker never
---   loads build.dispatch, nor what only it requires;
--- - this module and what it requires, directly or not, at its top level
---   or on the way its `run` takes.
---
--- Not [`cosmic.removed`], though the core requires it to say what to
--- write instead of a removed global a test reached for (core/surface.c's
--- `removed_message`), and the pipeline to say the same of a refusal:
--- a test whose closure does not hold it is refused it like any other
--- module (`refusal`), and is told only that the name is not available.
--- A test that reads what the catalog says requires it, so that its key
--- holds what it read, and an edit to the catalog runs every other test
--- no more.
---
--- No key holds them by what they are. Every sandboxed key holds the
--- harness's epoch in their place (build/harness_epoch.tl), and the
--- harness's digests, which build/harness_epoch_test.tl holds to those
--- acknowledged there, hold each by its source and bytecode
--- ([`build.test_key`]'s `harness`). `judge` fails a sandboxed test whose
--- worker loaded a module of the tree the tool carries that is neither
--- here nor in its closure, so what a worker runs is in its closure or
--- in those digests. A module added to the worker's way is named here by
--- the first test that reaches it, not found by a walk of the `imports`
--- table, which follows `local type` requires Teal erases and requires
--- inside functions no worker calls.
worker.loads = {
  "build.assertions", "build.cache_names", "build.confine", "build.key_parts", "build.load_module",
  "build.test_inputs",
  "build.test_worker", "build.this_program", "cmd.cosmic.main", "cosmic.coverage",
  "cosmic.env", "cosmic.fs", "cosmic.proc", "cosmic.test",
}

-- Taken at load, ahead of any test that could replace them on the
-- module's table, which a test whose closure holds it shares.
local hex = key_parts.hex
local unhex_either = key_parts.unhex

--- The bytes `hex` spelled, or nil for text it would not have written.
local function unhex(data: string): string?
  if data:find("[^0-9a-f]") ~= nil then return nil end
  local bytes, _ = unhex_either(data)
  return bytes
end

--- Writes `line` to stderr, as cosmic's own complaints are: the
--- worker's trouble before or after its test, which the runner captures
--- with its test's output. The write is taken as it loads, ahead of any
--- test that could replace it on the shared `Fs` table.
local put = Fs.put
local function complain(line: string)
  local _, _ = put(2, "cosmic: " .. line .. "\n")
end

--- What the test's own calls hand the runner while it loads and runs: the
--- needs its `policy` stands for, and the reason it gave for passing
--- unchecked.
local record Given
  mut handed?: Test.Needs
  mut deliberate: string
end

--- The run-time checks of a checked run. A module compiled with them calls
--- the global `__cosmic_tc` at each typed boundary ([`importer.compile`]'s
--- `checks`), with the check's spec and the values crossing it: a string of
--- fields joined by ";", the kind of boundary ("p" parameters, "r" return
--- values, "f" a record field written), the place, and for each value its
--- label and the kinds its declared type admits, joined by "|" (`type`'s
--- names, and "integer" for a number that `math.type` says is one). The
--- hook answers the values (the first, for a field) and records a value of
--- another kind: "absent" for a return value the `return` gave none of,
--- which Lua reads as nil, apart from a nil it gave. A violation is
--- recorded, and the value passes on, except for a parameter declared in the
--- standard library (a place under "cosmic/"): the call raises "parameter
--- violated at <caller>: parameter <name> of <function> (<declaration>) is
--- <kind>, declared <kinds>", so the first one fails the test that met it.
--- A return value and a field written, which a checked compile does not
--- check yet, and a parameter declared elsewhere are reported only.
---
--- Another kind of check fails: "n", a read whose type a test narrowed (an
--- `if x then`, a `~= nil`, an `is`, `assert`, a type test; the checker's
--- `Node.rt_fact`), with the place, its name and what the test says of the
--- value: "~" and the kinds the test took out, joined by "|" (a value of
--- one of them breaks it; "integer" among them takes out integers alone),
--- or the kinds the value has. The hook answers the value, or raises "fact
--- violated at <place>" for one the fact is false of, since the checker's
--- own proof was wrong there.
local record Check
  kind: string
  at: string
  mut name: string
  mut n: integer
  labels: mut {string}
  declared: mut {string}
  kinds: mut {{string:boolean}}
  integral: mut {boolean}
  -- The violations met at each position, by the value's kind and then the
  -- place that sent it, so a repeated one is found without building a key.
  memo: mut {{string:{string:worker.Violation}}}
end

-- The library the hook runs on, taken as the module loads: a test that
-- replaces `string.match` or `table.concat` with a wrapper of its own, as
-- one counts the string work of what it measures, must not have the hook
-- call it, for the wrapper's own checked parameters would call the hook.
local gmatch, lua_match = string.gmatch, string.match
local lua_type, math_type = type, math.type
local lua_char, lua_error = string.char, error
-- These are overloaded in the library, so each is declared with the one signature the hook calls it by.
local lua_byte: function(string, integer): integer? = string.byte
local lua_gsub: function(string, string, any): string, integer = string.gsub
local lua_tonumber: function(string, integer): number? = tonumber
local lua_pcall: function(any, ...: any): boolean, any... = pcall
local lua_select = select
local lua_concat, lua_format, lua_sub, lua_getmetatable, lua_tostring, lua_find =
  table.concat, string.format, string.sub, getmetatable, tostring, string.find

--- A fact of a narrowed read, parsed.
local record Fact
  at: string
  name: string
  --- The kinds the value may have, or those it may not (`negated`).
  kinds: mut {string:boolean}
  negated: boolean
  declared: string
  mut integral: boolean
end

--- Where the standard library's sources are: a declaration there is held ([`hook`]).
local LIBRARY <const> = "cosmic/"

-- The violation `note` last met, which the hook reads after it, since `note` runs under a `pcall`.
local record Latest
  mut met?: worker.Violation
end
local latest: Latest = {}

local checks: mut {string:Check} = {}
local facts: mut {string:Fact} = {}
local malformed: mut {string:boolean} = {}
local found: mut {worker.Violation} = {}
-- TODO: hold this in a `Cell<integer>` once a change to the harness that bumps the epoch for another reason can add cosmic.cell to [`worker.loads`] and `library` in build/harness_epoch.tl: a harness module may not require it before, and a bump for this alone reruns every test.
local tally = { dropped = 0 }
-- The place that sent a value is asked of the stack for every violation of
-- a parameter, in constant time, so the report names it however often a
-- boundary is violated; what is bounded is how many distinct violations one
-- worker keeps ([`worker.most_kept`]).

local function parse_check(text: string): Check
  local fields: mut {string} = {}
  for field in gmatch(text .. ";", "([^;]*);") do fields[#fields + 1] = field end
  local check: Check = { kind = fields[1], at = fields[2], name = "", n = 0, labels = {},
    declared = {}, kinds = {}, integral = {}, memo = {} }
  if check.kind ~= "p" and check.kind ~= "r" and check.kind ~= "f" then
    error("a check of no kind")
  end
  local first = 3
  if check.kind == "p" or check.kind == "f" then
    check.name = fields[3]
    first = 4
  end
  for i = first, #fields do
    local index = i - first + 1
    local label, declared = fields[i], fields[i]
    if check.kind == "p" then
      label, declared = lua_match(fields[i], "^([^=]*)=(.*)$")
    elseif check.kind == "r" then
      label = "return value " .. tostring(index)
    else
      label = check.name
    end
    check.n = index
    check.memo[index] = {}
    check.labels[index] = label
    if declared ~= "-" then
      local kinds: mut {string:boolean} = {}
      local integer, number = false, false
      for kind in gmatch(declared, "[^|]+") do
        if kind == "integer" then
          integer = true
        else
          kinds[kind] = true
          number = number or kind == "number"
        end
      end
      if integer and not number then
        kinds.number = true
        check.integral[index] = true
      end
      check.kinds[index] = kinds
      check.declared[index] = declared
    end
  end
  checks[text] = check
  return check
end

-- The metatable of a value is read as the code of a class does: `@v`, which answers
-- the metatable whatever its `__metatable` says, where the runtime's parser takes
-- the form from text. Where it does not, `getmetatable`, which a class that hides
-- its metatable would fail.
--
-- TODO: read the class with whatever form the runtime keeps for the code the compiler writes, once the runtime cut takes
-- text `load` from programs (doc/plans/strict-teal.md, "no implicit conversion or hidden code"): the `@` of text is
-- then gone, and a class that hides its metatable is a false "fact violated" again.
local raw_reader = load("local v = ... return @v")

-- Counts up a violation met again.
local function again(known: worker.Violation)
  known.count = known.count + 1
end

-- Keeps `met`, the first violation of its kind at `at` among `sites`, unless
-- the worker keeps as many as it may: then it is only counted.
local function keep(sites: mut {string:worker.Violation}, at: string, met: worker.Violation)
  if #found >= worker.most_kept then
    tally.dropped = tally.dropped + 1
    return
  end
  sites[at] = met
  found[#found + 1] = met
end

local function note(check: Check, index: integer, value: any, absent: boolean)
  local actual = lua_type(value)
  if actual == "number" then actual = math_type(value) end
  if absent then actual = "absent" end
  local at = check.at
  if check.kind == "p" then
    -- The frame that called the checked function: this, the `pcall` that
    -- calls it, the hook, the checked function, its caller (a caller that
    -- runs C is passed over, as one that tail-called the function is no
    -- frame and names its own caller).
    at = raw_errors.where(5) or "?"
  end
  local sites = check.memo[index][actual]
  if sites == nil then
    sites = {}
    check.memo[index][actual] = sites
  end
  local known = sites[at]
  if known ~= nil then
    again(known)
    latest.met = known
    return
  end
  local target: string
  if check.kind == "p" then
    target = "parameter " .. check.labels[index] .. " of " .. check.name .. " (" .. check.at .. ")"
  elseif check.kind == "r" then
    target = check.labels[index]
  else
    target = "field " .. check.name
  end
  local met: worker.Violation = { kind = if check.kind == "p" then "parameter" elseif check.kind == "r" then "return" else "field" end,
    at = at, target = target, declared = check.declared[index], actual = actual, count = 1 }
  keep(sites, at, met)
  latest.met = met
end

local function parse_fact(text: string)
  local at, name, declared = lua_match(text, "^n;([^;]*);([^;]*);([^;]*)$")
  if at == nil or name == nil or declared == nil then error("a fact of no place") end
  local negated = lua_byte(declared, 1) == 126
  local fact: Fact = { at = (lua_gsub(at, "%%(%x%x)", function(digits: string): string
    local byte = lua_tonumber(digits, 16)
    return byte is integer and lua_char(byte) or "?"
  end)), name = name, declared = if negated then "not " .. declared:sub(2) else declared end,
    kinds = {}, negated = negated, integral = false }
  local integer, number = false, false
  for kind in gmatch(negated and declared:sub(2) or declared, "[^|]+") do
    if kind == "integer" then
      integer = true
    else
      fact.kinds[kind] = true
      number = number or kind == "number"
    end
  end
  if integer and not number then
    if negated then
      fact.kinds.integer = true
    else
      fact.kinds.number = true
    end
    fact.integral = true
  end
  facts[text] = fact
end

-- The value of a read whose fact holds of it, else the failure.
local function verify(fact: Fact, value: any): any
  local kind = lua_type(value)
  local kinds = fact.kinds
  local broken: boolean
  if fact.negated then
    broken = kinds[kind] == true or (kind == "number" and kinds.integer == true and math_type(value) == "integer")
  else
    broken = kinds[kind] ~= true or (kind == "number" and fact.integral and math_type(value) ~= "integer")
  end
  if not broken then return value end
  local actual = kind
  if actual == "number" then actual = math_type(value) end
  lua_error("fact violated at " .. fact.at .. ": " .. fact.name .. " is " .. actual ..
      ", the checker proved " .. fact.declared, 0)
end

local function hook(_: integer, text: string, ...: any): any...
  local check = checks[text]
  if check == nil then
    local fact = facts[text]
    if fact ~= nil then return verify(fact, (...)) end
    if malformed[text] ~= true then
      if lua_byte(text, 1) == 110 then
        if lua_pcall(parse_fact, text) then
          return verify(facts[text], (...))
        end
        malformed[text] = true
      -- A parse that succeeds leaves its check in `checks`.
      elseif lua_pcall(parse_check, text) then
        check = checks[text]
      else
        malformed[text] = true
      end
    end
    -- A spec that does not parse checks nothing and is no failure of the
    -- test: the values pass as they came.
    if check == nil then
      if lua_byte(text, 1) == 102 then return (...) end
      return ...
    end
  end
  local given = lua_select("#", ...)
  for index = 1, check.n do
    local kinds = check.kinds[index]
    if kinds ~= nil then
      local value = (lua_select(index, ...))
      local kind = lua_type(value)
      if kinds[kind] ~= true or (kind == "number" and check.integral[index] == true and
          math_type(value) ~= "integer") then
        -- A check that fails to say so is no failure of the test.
        latest.met = nil
        local noted = lua_pcall(note, check, index, value, index > given)
        local met = latest.met
        -- A parameter of the standard library that meets a kind its declaration refuses ends the call, at the first
        -- one: either the caller or the declaration is wrong, and both are fixed.
        --
        -- TODO: once the checker lists each declared return and field write and lang/codegen.tl writes a check for it
        -- in a checked compile (doc/plans/strict-teal.md), raise for those kinds too: until then a return value or
        -- field of cosmic/ that is of a kind its declaration refuses is recorded and let through.
        if noted and check.kind == "p" and lua_sub(check.at, 1, #LIBRARY) == LIBRARY and met ~= nil then
          lua_error("parameter violated at " .. met.at .. ": " .. met.target .. " is " .. met.actual ..
              ", declared " .. met.declared, 0)
        end
      end
    end
  end
  if check.kind == "f" then return (...) end
  return ...
end

local fact_sites: {string:worker.Violation} = {}

local function among(list: {any}, value: any): boolean
  for i = 1, #list do
    if list[i] == value then return true end
  end
  return false
end

-- Whether the metatable of `v` is one of `classes`, as the code of a class reads it.
local function of_class(v: any, classes: {any}): boolean
  if raw_reader == nil then return among(classes, lua_getmetatable(v)) end
  return among(classes, (raw_reader(v)))
end

local function among_strings(list: {string}, value: any): boolean
  for i = 1, #list do
    if list[i] == value then return true end
  end
  return false
end

-- A value as a row says it: a string quoted and cut short, a boolean as it
-- prints, a number by its kind, any other value by its type. A row is keyed by
-- it, so it names no address.
local function shown(value: any): string
  if value is string then
    local text = lua_format("%q", value)
    if #text > 40 then text = lua_sub(text, 1, 37) .. "..." end
    return "string " .. text
  elseif value is boolean then
    return lua_tostring(value)
  elseif lua_type(value) == "number" then
    if math_type(value) == "integer" then return "integer" end
    return "float"
  end
  return lua_type(value)
end

-- Records a fact false of a value, the same place, read and what was seen
-- again counted up in the row it made.
local function note_fact(at: string, name: string, declared: string, actual: string)
  local key = at .. "\0" .. name .. "\0" .. declared .. "\0" .. actual
  local known = fact_sites[key]
  if known ~= nil then
    again(known)
    return
  end
  keep(fact_sites, key, { kind = "fact", at = at, target = name, declared = declared, actual = actual, count = 1 })
end

-- Records the fact `declared` false of the read of `name` at `at`, which was
-- `actual`, and fails the test.
local function fact_broken(at: string, name: string, declared: string, actual: string)
  note_fact(at, name, declared, actual)
  lua_error("fact violated at " .. at .. ": " .. name .. " is " .. actual .. ", the checker proved " .. declared, 0)
end

-- The hook the code of the new checker calls at each read of a place whose
-- type a test narrowed: `__fact(v, taken, place, strings, classes, tag, tags,
-- at)` ([`lang.fact_wraps`]). It answers `v`, or records the violation and
-- raises as the fork's "n" check does, since the checker's own conclusion
-- was wrong there: a kind `taken` names (joined by ","; no kind is part of
-- another's name), a string that is no member of `strings`, a table of another
-- metatable than the `classes`', a table whose field `tag` is none of `tags`.
-- `at` is the place of the read; a call that gives none is placed by the frame
-- that made it.
local tag_sets: mut {string: {string: boolean}} = {}

--- Whether `field` is one of the values joined by "," in `tags`. The set of a joined text is built once: a read of a
--- union of many members would otherwise scan its list at every evaluation.
local function among_joined(tags: string, field: any): boolean
  if not (field is string) then return false end
  local set = tag_sets[tags]
  if set == nil then
    local made: mut {string: boolean} = {}
    lua_gsub(tags, "[^,]+", function(word: string): string?
      made[word] = true
      return nil
    end)
    tag_sets[tags] = made
    set = made
  end
  return set[field] == true
end

local function fact(v: any, taken?: string, name: string, strings?: {string}, classes?: {any}, tag?: string,
                    tags?: {string} | string, at?: string): any
  if taken == nil then return v end
  -- A read of a tagged union has no kind taken, and no string: nothing here asks the kind of the value.
  if taken ~= "" or strings ~= nil then
    local kind = lua_type(v)
    if lua_find(taken, kind, 1, true) ~= nil then
      local actual = kind
      if kind == "number" then actual = shown(v) end
      fact_broken(at or raw_errors.where(2) or "?", name, "not " .. (lua_gsub(taken, ",", "|")), actual)
    end
    if strings ~= nil and kind == "string" and not among_strings(strings, v) then
      fact_broken(at or raw_errors.where(2) or "?", name, "one of " .. lua_concat(strings, "|"), shown(v))
    end
  end
  if v is {string:any} then
    if classes ~= nil and not of_class(v, classes) then
      fact_broken(at or raw_errors.where(2) or "?", name, "a table of one of its classes", "a table of another class")
    end
    if tag ~= nil and tags ~= nil then
      local field = v[tag]
      if tags is string then
        if not among_joined(tags, field) then
          fact_broken(at or raw_errors.where(2) or "?", name, tag .. " one of " .. (lua_gsub(tags, ",", "|")),
            "a table whose " .. tag .. " is " .. shown(field))
        end
      elseif not among_strings(tags, field) then
        fact_broken(at or raw_errors.where(2) or "?", name, tag .. " one of " .. lua_concat(tags, "|"),
          "a table whose " .. tag .. " is " .. shown(field))
      end
    end
  end
  return v
end

worker.most_kept = 2000
worker.fact = fact

function worker.cross(text: string, ...: any)
  local _ = hook(2, text, ...)
end

--- Defines the global `__cosmic_tc` the Lua of a checked run calls, with the `__cosmic_ty` and `__cosmic_mt` (`type` and
--- `math.type`, as the module took them) that the tests ahead of its call read ([`lang.boundary_checks`]). `__cosmic_tc`
--- is defined last, since the tests run only where it is. The hook records what [`worker.violations`] answers, and `__fact`, which the Lua the
--- new checker's code generator writes calls at a read it narrowed
--- ([`lang.fact_wraps`]) and which records a violation of kind "fact" (the
--- place of the read, the place as written, what the checker proved and what
--- the value was) before it fails the read. Install them before a test's
--- module loads: the boundaries its load crosses are checked too.
function worker.install_checks()
  local globals = _G as {string:any}
  rawset(globals, "__cosmic_ty", lua_type)
  rawset(globals, "__cosmic_mt", math_type)
  rawset(globals, "__cosmic_tc", hook)
  rawset(globals, "__fact", fact)
end

--- The violations this process has met since it installed its checks, in
--- the order met.
function worker.violations(): {worker.Violation}
  local out: mut {worker.Violation} = {}
  for i, met in ipairs(found) do out[i] = met end
  return out
end

--- How many kinds of violation this process met past the number it keeps
--- a record of.
function worker.dropped_violations(): integer
  return tally.dropped
end

--- The monotonic clock, in nanoseconds, straight from the binding.
--- build.declared_key spells the same five lines, as cosmic.clock's
--- monotonic_ns does: a harness module reaches the clock through the raw
--- binding, and cosmic.clock is no library module the harness may load.
local function monotonic_ns(): integer
  local reading, trouble = sys.clock_gettime(sys.CLOCK_MONOTONIC)
  if reading == nil then error("clock_gettime(CLOCK_MONOTONIC): " .. trouble, 2) end
  return reading
end

local function encode_hits(lines: mut {string}, tag: string, hits: Coverage.Hits)
  if hits == nil then return end
  local paths: mut {string} = {}
  for path in pairs(hits) do paths[#paths + 1] = path end
  table.sort(paths)
  for _, path in ipairs(paths) do
    local numbers: mut {integer} = {}
    for line in pairs(hits[path]) do numbers[#numbers + 1] = line end
    table.sort(numbers)
    local text: mut {string} = {}
    for i, line in ipairs(numbers) do text[i] = tostring(line) end
    table.insert(lines, tag .. " " .. hex(path) .. " " .. table.concat(text, ","))
  end
end

--- Folds into `into` every line the processes the test started wrote
--- into `directory` (see [`Coverage.children`]), removing each file and
--- then the directory. A file cut short by a process killed mid-write
--- yields the whole lines it holds.
local function child_hits(directory: string, into: Coverage.Hits)
  local names, _ = Fs.list(directory)
  if names ~= nil then
    for _, name in ipairs(names) do
      local file = directory .. "/" .. name
      local text, _ = Fs.read(file)
      if text ~= nil then
        for path, line in text:gmatch("([^\t\n]+)\t(%d+)\n") do
          local here = into[path]
          if here == nil then
            here = {}
            into[path] = here
          end
          local number = math.tointeger(tonumber(line))
          if number ~= nil then here[number] = true end
        end
      end
      local _, _ = Fs.remove(file)
    end
  end
  local _, _ = sys.rmdir(directory)
end

--- The report as text: a header, one line per fact, and a closing line
--- whose absence says the worker never finished writing it.
function worker.encode(report: worker.Report): string
  local lines: mut {string} = { HEADER,
    "loaded " .. (if report.loaded then "1" else "0" end),
    "passed " .. (if report.passed then "1" else "0" end),
    "elapsed " .. tostring(report.elapsed_ns),
    "message " .. hex(report.message),
  }
  encode_hits(lines, "load-hit", report.load_hits)
  encode_hits(lines, "test-hit", report.test_hits)
  for _, name in ipairs(report.modules or {}) do table.insert(lines, "module " .. hex(name)) end
  local skipped = report.skipped
  if skipped ~= nil and skipped ~= "" then
    table.insert(lines, "skipped " .. hex(skipped))
  end
  table.insert(lines, "asserted " .. tostring(report.asserted or 0))
  local deliberate = report.deliberate
  if deliberate ~= nil and deliberate ~= "" then
    table.insert(lines, "deliberate " .. hex(deliberate))
  end
  for _, met in ipairs(report.violations or {}) do
    table.insert(lines, "violation " .. hex(table.concat({ met.kind, met.at, met.target,
      met.declared, met.actual }, "\t")) .. " " .. tostring(met.count))
  end
  local dropped = report.dropped
  if dropped ~= nil and dropped > 0 then
    table.insert(lines, "dropped " .. tostring(dropped))
  end
  lines[#lines + 1] = "end"
  return table.concat(lines, "\n") .. "\n"
end

--- The hits of every line a report held, by the text that spelled it: every
--- worker of a module reports the same lines for what its load ran, so
--- one run reads each once, and the runner can tell a line it has folded
--- by its table ([`build.test`]'s `take_hits`). The memo outlives a run,
--- which is safe since a table is a function of the text that keys it and
--- is never changed; the runner's own memos of what it did with one are
--- a run's.
local record DecodedHit
  path: string
  lines: {integer:boolean}
end
local decoded_hits: mut {string:DecodedHit} = {}

--- Reads a report back; nil and why when it is not a whole one. The
--- tables of its `load_hits` and `test_hits` are shared with every other
--- report read, so a caller does not change them.
function worker.decode(text: string): worker.Report?, string
  if text == nil or text == "" then return nil, "no report" end
  local report: worker.Report = {
    loaded = false, passed = false, message = "", elapsed_ns = 0,
    load_hits = {}, test_hits = {}, modules = {}, skipped = "",
    asserted = 0, deliberate = "",
  }
  local first = true
  local finished = false
  for line in text:gmatch("[^\n]+") do
    if finished then return nil, "text after the end of the report" end
    if first then
      if line ~= HEADER then return nil, "not a test report" end
      first = false
    elseif line == "end" then
      finished = true
    else
      local tag, rest = line:match("^(%S+) ?(.*)$")
      if tag == "loaded" then
        report.loaded = rest == "1"
      elseif tag == "passed" then
        report.passed = rest == "1"
      elseif tag == "elapsed" then
        report.elapsed_ns = math.tointeger(tonumber(rest)) or 0
      elseif tag == "message" then
        report.message = unhex(rest) or ""
      elseif tag == "load-hit" or tag == "test-hit" then
        local into = tag == "load-hit" and report.load_hits or report.test_hits
        local known = decoded_hits[rest]
        if known == nil then
          local path, numbers = rest:match("^([0-9a-f]*) ([0-9,]*)$")
          local decoded = path ~= nil and unhex(path) or nil
          if decoded == nil then return nil, "a malformed hit: " .. line end
          local per_line: mut {integer:boolean} = {}
          for number in numbers:gmatch("%d+") do
            per_line[math.tointeger(tonumber(number)) or 0] = true
          end
          known = { path = decoded, lines = per_line }
          decoded_hits[rest] = known
        end
        into[known.path] = known.lines
      elseif tag == "module" then
        local decoded = unhex(rest)
        if decoded == nil or decoded == "" then return nil, "a malformed module: " .. line end
        report.modules[#report.modules + 1] = decoded
      elseif tag == "skipped" then
        local decoded = unhex(rest)
        if decoded == nil or decoded == "" then return nil, "a malformed skip: " .. line end
        report.skipped = decoded
      elseif tag == "deliberate" then
        local decoded = unhex(rest)
        if decoded == nil or decoded == "" then return nil, "a malformed deliberate: " .. line end
        report.deliberate = decoded
      elseif tag == "violation" then
        local packed, count = rest:match("^([0-9a-f]+) (%d+)$")
        local decoded = packed ~= nil and unhex(packed) or nil
        local kind, at, target, declared, actual: string?, string?, string?, string?, string?
        if decoded ~= nil then
          kind, at, target, declared, actual =
            decoded:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
        end
        if actual == nil then return nil, "a malformed violation: " .. line end
        local met = report.violations or {}
        report.violations = met
        met[#met + 1] = { kind = kind, at = at, target = target, declared = declared,
          actual = actual, count = math.tointeger(tonumber(count)) or 1 }
      elseif tag == "dropped" then
        local count = math.tointeger(tonumber(rest))
        if count == nil or count < 0 then return nil, "a malformed count: " .. line end
        report.dropped = count
      elseif tag == "asserted" then
        local count = math.tointeger(tonumber(rest))
        if count == nil or count < 0 then return nil, "a malformed count: " .. line end
        report.asserted = count
      else
        return nil, "an unknown line: " .. line
      end
    end
  end
  if first then return nil, "not a test report" end
  if not finished then return nil, "the report was cut short" end
  return report, ""
end

--- Why the module `module_path`'s tests may not `require` `name`, or
--- nil when they may: `closure` is the set of module names its import
--- closure holds ([`test_inputs.modules`]), and `tree` the set of the
--- modules of the tree's projection. A module of the tree outside the
--- closure is refused, since the build does not follow it and a change
--- to it would leave the test's verdict standing; anything else --
--- the core's own modules, and whatever another database a test
--- attaches holds -- is no input of the tree and loads as ever.
-- TODO: hold a module the running program carries that is no module
-- of the tree -- in a project's tree, the standard library's -- for the
-- workers that run the program whole (`store`, `tool`, and a program
-- that is no portable artifact), once their keys hold the program's own
-- modules (a digest of its `modules` and `decls` beside the runtime
-- identity, which names only the core and the pins): the key of a worker
-- on a sealed database holds them already (build.test_key's `extras_digest`),
-- but today a release that changes only the standard library's Teal leaves
-- standing a verdict of one of the others that read one of them outside its
-- closure. In this tree every module the program carries is a module of
-- the tree.
local function refusal(name: string, module_path: string, closure: {string:boolean},
                       tree: {string:boolean}): string?
  if closure[name] == true or tree[name] ~= true then return nil end
  return string.format("module '%s' is outside the import closure of %s: the build " ..
      "follows a require only when it is called directly on a literal name, or through " ..
      "pcall(require, \"<name>\"), so a name computed at run time is not followed, and a change to %s " ..
      "would not run %s's tests again. Require it so at the top level of the module this is " ..
      "raised in, or of %s itself: local _ = require(%q)",
    name, module_path, name, module_path, module_path, name)
end

--- A call made with the `require`s of the tree's modules held to
--- `closure`, the set of the names `module_path`'s import closure
--- holds.
local type Held = function(fn: function(...: any): (any...), argument?: any): any

--- Answers a [`Held`], `tree` the set of the tree's modules. It calls `fn`
--- with `argument` while two things hold: a searcher ahead of every
--- other answers a module `refusal` refuses with a loader that raises
--- why, where it was required, and each searcher after it hands such a
--- module's loader as a loader that raises too (with no raw value beside
--- it), so a loop over `package.searchers` that calls what
--- it is handed loads nothing outside the closure; and each such module the worker itself
--- has loaded already is out of `package.loaded`, so a `require` of it
--- reaches the searcher too. It then puts both back, whether `fn`
--- returned or raised, and returns or raises as `fn` did. A lookup that
--- is not a `require` reads the store the worker is given, and the
--- program's own, which a sealed database narrows to the closure
--- (build.test_key's `sealed_for`): this hold is its second guard there, which
--- says why, and the only one for a worker that declares `store`, `tool` or
--- `nests`.
local function hold_requires(module_path: string, closure: {string:boolean},
                             tree: {string:boolean}): Held
  -- A refusal is a loader that raises, not a searcher that does: a
  -- caller that asks every searcher by hand for the raw value one
  -- hands a wrapper (core/syscalls_test.tl's `raw_behind`) finds none
  -- beside it and asks the next, as it would of a searcher that knew
  -- nothing of the name.
  local function gate(name: string): (function(arg1?: string, arg2?: any): (any), any)
    local why = refusal(name, module_path, closure, tree)
    if why == nil then return nil, nil end
    return function(_?: string, _?: any): any
      -- Level 3: the caller of `require`, past this loader and it.
      error(why, 3)
    end, nil
  end
  -- A searcher after the gate, handing the loader of a module `refusal` refuses as a loader that raises why, and nothing
  -- beside it: a loop over every searcher finds the loader of the store and calls it, or reads the core's raw table.
  local function guarded(searcher: function(string): (function(arg1?: string, arg2?: any): (any), any)):
      function(string): (function(arg1?: string, arg2?: any): (any), any)
    return function(name: string): (function(arg1?: string, arg2?: any): (any), any)
      local loader, raw = searcher(name)
      local why = refusal(name, module_path, closure, tree)
      if type(loader) == "function" and why ~= nil then
        -- The gate's own: a loader that raises, and no raw value beside it (the core's table behind a module is
        -- the module's, and goes to a test whose closure holds the module).
        return gate(name)
      end
      return loader, raw
    end
  end
  return function(fn: function(...: any): (any...), argument?: any): any
    local set_aside: mut {string:any} = {}
    for name, value in pairs(package.loaded) do
      if refusal(name, module_path, closure, tree) ~= nil then set_aside[name] = value end
    end
    for name in pairs(set_aside) do package.loaded[name] = nil end
    -- The table `require` and a hand-made loop both read is replaced for the call, by the gate and a guarded
    -- copy of each searcher, and put back as it was.
    local held_searchers = package.searchers
    local guarded_searchers: mut {function(string): (function(arg1?: string, arg2?: any): (any), any)} = { gate }
    for _, searcher in ipairs(held_searchers) do
      guarded_searchers[#guarded_searchers + 1] = guarded(searcher)
    end
    package.searchers = guarded_searchers
    local ok, produced = pcall(fn, argument)
    package.searchers = held_searchers
    for name, value in pairs(set_aside) do package.loaded[name] = value end
    -- Level 0: the value raised, as it was raised.
    if not ok then error(produced, 0) end
    return produced
  end
end

--- How a worker is started: this exact program again -- the same core,
--- whose runtime identity every verdict of the run is keyed under. A
--- process not started from a portable artifact starts its logical
--- executable instead. What it answers is the relaunch's own: the
--- arguments that lead its command line, the variables it adds, and
--- the descriptors it hands on.
function worker.program(): Proc.Relaunch?, string
  local relaunch, _ = Proc.relaunch()
  if relaunch ~= nil then
    local env: mut {string:string} = {}
    for name, value in pairs(relaunch.env) do env[name] = value end
    return { argv = relaunch.argv, env = env, fds = relaunch.fds }, ""
  end
  local executable, trouble = Proc.executable()
  if executable == nil then return nil, trouble end
  return { argv = { executable }, env = {}, fds = {} }, ""
end

--- What stands for `--worker` on a worker's command line for each
--- [`Hold`] but "none".
local hold_flag: {worker.Hold:string} = { forbid = "--worker-no-tool", mounts = "--worker-held" }

--- Whether `policy` promises `nest`.
local function promises_nest(policy: Sandbox.Policy): boolean
  for _, promise in ipairs(policy.promises or {}) do
    if promise == "nest" then return true end
  end
  return false
end

--- The command line and the start options of the worker `given`
--- describes: `start`'s program (`program`), then `test --worker
--- <root> <module> <test> <scratch>/tmp <scratch>/children <needs>
--- [--sandboxed [--runs <count> <path>...]] --store <store> <closure>... --tree <tree>...`
--- (`run`), with the report captured at `report_fd`,
--- and its environment `env` with `start`'s variables added and
--- coverage collected from its first instruction (core/coverage.c,
--- COSMIC_COVERAGE_STARTUP), so its first window holds the Lua that
--- loaded before it could open.
---
--- An unsandboxed worker leads a process group of its own, which its
--- end ends. A sandboxed one is pid 2 of a pid namespace of its own,
--- which ends with it, ending all it started: it has no group to end,
--- and no stray is left for the runner to adopt ([`build.test`]'s
--- `run_jobs`).
function worker.invocation(given: worker.Invocation): worker.Command
  local argv: mut {string} = {}
  for i, value in ipairs(given.start.argv) do argv[i] = value end
  local program = given.program
  -- A relaunch's argv is the core, `--artifact` and the artifact's path,
  -- which the worker's startup takes as it is given.
  if program ~= nil and argv[2] == "--artifact" and argv[3] ~= nil then
    argv[3] = program
  end
  for _, value in ipairs({ "test", hold_flag[given.hold] or "--worker",
      given.root, given.module_path, given.name, given.scratch .. "/tmp",
      given.scratch .. "/children", given.needs }) do
    argv[#argv + 1] = value
  end
  if given.policy ~= nil then argv[#argv + 1] = "--sandboxed" end
  if given.own_scratch == true then argv[#argv + 1] = "--own-scratch" end
  if given.policy ~= nil and given.hold == "forbid" then
    local runs = given.runs or {}
    argv[#argv + 1] = "--runs"
    argv[#argv + 1] = tostring(#runs)
    for _, path in ipairs(runs) do argv[#argv + 1] = path end
  end
  local given_store = given.store
  if given_store ~= nil then
    argv[#argv + 1] = "--store"
    argv[#argv + 1] = given_store
  end
  for _, name in ipairs(given.closure) do argv[#argv + 1] = name end
  argv[#argv + 1] = "--tree"
  for _, name in ipairs(given.tree) do argv[#argv + 1] = name end
  local env: mut {string:string} = {}
  for name, value in pairs(given.env) do env[name] = value end
  for name, value in pairs(given.start.env) do env[name] = value end
  env.COSMIC_COVERAGE_STARTUP = "1"
  env.COSMIC_TEST_TYPES = if given.checks then "1" else nil end
  local fds: mut {integer:integer | string} = { [worker.report_fd] = "capture" }
  for number, fd in pairs(given.start.fds) do fds[number] = fd end
  local given_policy = given.policy
  if given_policy ~= nil and promises_nest(given_policy) then
    -- A worker that builds roots of its own is handed no descriptor of the
    -- program ([`Child.start`] refuses it any file open for reading alone:
    -- its owner could reopen it for writing through /proc/self/fd). Its
    -- startup, told of none, opens the artifact by its path and the core
    -- by itself, inside its own root (core/startup.c's `by_path`).
    for _, name in ipairs({ "COSMIC_PORTABLE_ARTIFACT_FD", "COSMIC_PORTABLE_CORE_FD" }) do
      local number = math.tointeger(tonumber(env[name] or ""))
      if number ~= nil then fds[number] = nil end
      env[name] = nil
    end
  end
  local given_policy2 = given.policy
  if given_policy2 ~= nil then
    -- A policy is the whole of its child's environment, which `env` beside
    -- it would contradict: what the worker is given, the one place it is
    -- made whole, goes in the policy's `set_env`.
    local held = given_policy2
    local policy: Sandbox.Policy = { profiles = held.profiles, grants = held.grants,
      isolate = held.isolate, promises = held.promises, connect = held.connect,
      loopback = held.loopback, env = held.env, tmp = held.tmp, limits = held.limits,
      database = held.database }
    policy.set_env = env
    return { argv = argv, options = {
      policy = policy, cwd = given.cwd, stdin = "null", stdout = "capture", stderr = "stdout",
      fds = fds, process_group = false,
    } }
  end
  return { argv = argv, options = {
    env = env, cwd = given.cwd, stdin = "null", stdout = "capture", stderr = "stdout",
    fds = fds, process_group = true,
  } }
end

--- The modules of `modules`, a worker's [`Report.modules`], that it ran
--- and no key of its test holds, sorted: each of the tree the tool
--- carries (`carried`) that is neither in `loads` nor in the test's
--- import closure (`closure`). A module the tool does not carry is the
--- core's own, or Lua's, which the runtime's identity holds; one it
--- carries that is no module of the tree is the TODO above `refusal`.
local function unkeyed(modules: {string}, carried: {string:boolean},
                       closure: {string:boolean}): {string}
  local listed: mut {string:boolean} = {}
  for _, name in ipairs(worker.loads) do listed[name] = true end
  local out: mut {string} = {}
  for _, name in ipairs(modules) do
    if carried[name] == true and listed[name] ~= true and closure[name] ~= true then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

local function ending(result: Child.Result): string
  local signal = result.signal
  if signal ~= nil then return "was killed by signal " .. tostring(signal) end
  return "exited with status " .. tostring(result.code)
end

--- Reads a finished worker (`judging`) into its test's verdict: what it
--- reported, unless it could not be supervised, ran past its deadline,
--- or ended before it reported; a pass fails where what it started
--- outlived it, its process ended unsuccessfully, or it ran a module no key of its test holds
--- (`unkeyed`), which would let an edit to that module leave the pass
--- standing.
function worker.judge(judging: worker.Judging): worker.Judgement
  local result = judging.result
  if result == nil and judging.refused == true then
    return { passed = false, message = judging.trouble, skipped = "" }
  elseif result == nil then
    return { passed = false, skipped = "",
      message = "the test process could not be supervised: " .. judging.trouble }
  end
  if result.timed_out then
    return { passed = false, skipped = "", message = "timed out after " ..
        tostring(judging.timeout_ns // SECOND_NS) .. " s; " ..
        (if judging.sandboxed then "its pid namespace" else "its process group" end) .. " was ended" }
  end
  local report, decode_trouble = worker.decode(result.captured[worker.report_fd])
  if report == nil then
    return { passed = false, skipped = "", message = "the test process " .. ending(result) ..
        " before it reported (" .. decode_trouble .. ")" }
  end
  local judgement: worker.Judgement = { report = report, passed = report.passed,
    message = report.message }
  if not result.ok or result.code ~= 0 or result.signal ~= nil then
    local message = "the test process " .. ending(result) .. " after it reported"
    judgement.passed = false
    judgement.message = if report.message ~= "" then report.message .. "\n  " .. message else message end
  end
  local closure = judging.closure
  local carried = judging.carried
  if judgement.passed and carried ~= nil and closure ~= nil then
    local names = unkeyed(report.modules, carried, closure)
    if #names > 0 then
      judgement.passed = false
      judgement.message = "its worker ran " .. table.concat(names, ", ") .. ", which the " ..
        "tool carries and neither its module's import closure nor the modules every " ..
        "worker loads hold, so no key of its test does: require " ..
        (if #names == 1 then "it" else "each" end) .. " at the top level of its module, or, where " ..
        "every worker loads it, name it in build/test_worker.tl's `worker.loads`"
    end
  end
  if judgement.passed and judging.trouble ~= "" then
    -- The test passed, but what it started outlived it.
    judgement.passed, judgement.message = false, judging.trouble
  end
  -- Only a pass is skipped instead: a failure is one, skip or not.
  judgement.skipped = judgement.passed and report.skipped or ""
  judgement.deliberate = ""
  -- A test that also asserted checked something: it is no deliberate non-check.
  if judgement.passed and judgement.skipped == "" and report.asserted == 0 then
    judgement.deliberate = report.deliberate
  end
  judgement.unchecked = judgement.passed and judgement.skipped == "" and report.loaded and
    report.asserted == 0 and judgement.deliberate == ""
  return judgement
end

--- Installs `runner` as `__runner` on `module`, [`cosmic.test`]'s table,
--- where `policy` looks for a runner: no member of its type.
local function install(module: any, runner: any)
  if module is {string:any} then module.__runner = runner end
end

--- [`confine.unseen`] and the message ENOENT stands for, as this module
--- loads: what a failure's report says is not its test's to change.
local unseen = confine.unseen
local not_found = sys.errno_message(sys.ENOENT)

--- What the failure `message` of a sandboxed worker's load or test
--- gains: why each start it made found nothing for what the sandbox left
--- out (`heard`), and why each absolute path the message says was not
--- found was not, where the sandbox is why ([`confine.unseen`]) -- a
--- line each, but for what the message says already. A bare `assert`
--- on a start's result says nothing of it itself.
local function unseen_note(message: string, heard: {string}): string
  local lines: mut {string} = {}
  local function add(why: string)
    if message:find(why, 1, true) ~= nil then return end
    for _, line in ipairs(lines) do
      if line == why then return end
    end
    lines[#lines + 1] = why
  end
  for _, why in ipairs(heard) do add(why) end
  -- A path starts the message or follows a space, a quote or a
  -- parenthesis: the tail of a relative path or a URL is none.
  for path in ("\n" .. message):gmatch("[%s'\"(](/[^%s:'\"]+): " ..
        not_found:gsub("%p", "%%%0")) do
    local why = unseen(path, "reads")
    if why ~= nil then add(why) end
  end
  if #lines == 0 then return "" end
  return "\n  " .. table.concat(lines, "\n  ")
end

--- Runs the one test the command line names and writes its report.
--- Exits 0 once the report is written, whatever the verdict; anything
--- else fails even if a finalizer ends the process after the report was
--- written.
---
--- @param argv `cosmic test --worker <root> <module> <test> <tmp> <children>
--- <needs> [--sandboxed] --store <store> <closure>... --tree <tree>...`:
---
--- - `children` is a directory, not yet there, to collect the coverage
---   of the processes the test starts in.
--- - `needs` is what the build read of the module's [`cosmic.test`]
---   declaration ([`test_inputs.canonical`]), "" or absent for none. A
---   module whose `policy` call stands for anything else fails to load.
--- - `--sandboxed` says the worker runs in a sandbox, which every
---   process its test starts inherits ([`confine.call`]'s `sandboxed`).
--- - `closure` is the names of the module's import closure
---   ([`test_inputs.modules`]), one argument each. Its load and its test
---   may `require` these of the tree and nothing else of it
---   (`refusal`). Absent for no such hold; a closure holds its module
---   at least.
--- - `tree` is the names of every module of the tree, one argument
---   each. The store a sandboxed worker is given does not hold them
---   beyond its closure, and a key need not hold them: a name there
---   only turns a `require` of a module outside the closure into a
---   refusal, never into a load.
--- - `--store <store>` ahead of the closure names the store to attach:
---   where a sandboxed worker's sandbox gives it, or, unsandboxed, the
---   store of the module's closure ([`build.closure_store`]), whose key
---   holds it by that store's address, or the projection for a module
---   that declares `store`. A worker resolves no build directory itself
---   ([`worker.loads`] holds no hashing but the key's own).
---
--- `--worker-no-tool` in place of `--worker` holds the worker, before
--- anything of the test loads, to running anything but this very
--- program ([`confine.forbid_running`]). That is a sandboxed worker whose
--- module does not declare `tool`, so what the program would run, the
--- tool's own modules, which no key of the test holds, is none of its
--- test's. `--worker-held` holds it by a ruleset that forbids running
--- nothing: one whose module declares `tool` but not `nests`, which may
--- confine no process in a root of its own ([`Hold`]).
function worker.run(argv: {string}): integer
  local root, module_path, name, tmp = argv[3], argv[4], argv[5], argv[6]
  local children_path = argv[7]
  local expected_needs = argv[8] or ""
  if root == nil or module_path == nil or name == nil or tmp == nil or
      children_path == nil then
    complain("test --worker needs a root, a module, a test and two directories")
    return 2
  end
  -- The closure's names start after `--store` and its path.
  local first = 9
  local sandboxed = argv[first] == "--sandboxed"
  local runs: mut {string}? = nil
  local own_scratch = false
  if sandboxed then
    first = first + 1
    if argv[first] == "--own-scratch" then
      own_scratch, first = true, first + 1
    end
    if argv[first] == "--runs" then
      local count = math.tointeger(tonumber(argv[first + 1] or "")) or -1
      if count < 0 then
        complain("test --worker: --runs needs a count")
        return 2
      end
      runs = {}
      for i = 1, count do runs[i] = argv[first + 1 + i] or "" end
      first = first + 2 + count
    end
  end
  if argv[2] == "--worker-no-tool" or argv[2] == "--worker-held" then
    local no_tool = argv[2] == "--worker-no-tool"
    local forbidden, forbid_trouble = confine.forbid_running(no_tool and confine.itself() or {}, runs)
    if not forbidden then
      complain("test " .. argv[2] .. ": this program cannot be held by a Landlock " ..
          "ruleset: " .. forbid_trouble)
      return 2
    end
  end
  if sandboxed then
    -- A worker started under a policy starts in the root of its sandbox,
    -- which has the tree at `root` but not as a directory to start in
    -- ([`build.test_policy`]).
    local entered, enter_trouble = sys.chdir(root)
    if not entered then
      complain("test --worker: " .. root .. ": " .. enter_trouble)
      return 2
    end
  end
  if own_scratch then
    -- The runner made no directory for it: the worker's scratch directory is
    -- one of the tmpfs it has, as the runner would have made it ([`build.test_key`]'s
    -- `scratch`), `tmp` a link to `real`.
    local scratch = Fs.dirname(tmp)
    local made_scratch, scratch_trouble = Fs.mkdirs(scratch .. "/real")
    -- 0700, as the runner's own is.
    if made_scratch then made_scratch, scratch_trouble = sys.chmod(scratch, 0x1c0) end
    if made_scratch then made_scratch, scratch_trouble = Fs.symlink("real", tmp) end
    if not made_scratch then
      complain("test --worker: its directory " .. scratch .. ": " .. scratch_trouble)
      return 2
    end
  end
  if argv[first] ~= "--store" or argv[first + 1] == nil then
    complain("test --worker: --store needs a path")
    return 2
  end
  local db_path = argv[first + 1]
  first = first + 2
  local attached, attach_trouble = store.attach(db_path)
  if not attached then
    complain(db_path .. ": " .. attach_trouble)
    return 2
  end
  -- Without a closure, a call as it is.
  local held: Held = function(fn: function(...: any): (any...), argument?: any): any
    return fn(argument)
  end
  if argv[first] ~= nil then
    local closure: {string:boolean} = {}
    local tree: {string:boolean} = {}
    local into = closure
    local i = first
    while argv[i] ~= nil do
      if argv[i] == "--tree" and into == closure then
        into = tree
      else
        into[argv[i]] = true
      end
      i = i + 1
    end
    held = hold_requires(module_path, closure, tree)
  end
  local report: worker.Report = {
    loaded = false, passed = false, message = "", elapsed_ns = 0, skipped = "",
    asserted = 0, deliberate = "", load_hits = {}, test_hits = {}, modules = {},
  }
  -- Where the C hits of the processes the test starts are folded: the
  -- test's coverage once it ran, else the load's, else nowhere.
  local child_into: Coverage.Hits? = nil
  Assertions.install()
  if env_get("COSMIC_TEST_TYPES") == "1" then worker.install_checks() end
  -- Processes the test starts report the core's C they ran here, so it
  -- counts for the test like the C it runs itself.
  local made, _ = sys.mkdir(children_path, 0x1c0)
  local children = made and children_path or nil
  if children ~= nil then Coverage.children(children) end
  local load_session, _ = Coverage.start()
  -- The directories the test owns, which a process it confines may
  -- change ([`confine.call`]): its own, as it is handed it and as it
  -- resolves, and where a process it starts writes its coverage.
  local own: mut {string} = { tmp }
  if sandboxed and ("\n" .. expected_needs .. "\n"):find("\nnoexec true\n", 1, true) ~= nil then
    own[#own + 1] = "/noexec"
  end
  local resolved_tmp, _ = Fs.absolute(tmp)
  if resolved_tmp ~= nil then own[#own + 1] = resolved_tmp end
  if children ~= nil then own[#own + 1] = children end
  -- The base of the build directories its runner gave it
  -- (COSMIC_BUILD_HOME, beneath its scratch directory): a project the
  -- test builds, or a process it starts builds, is built there, so what
  -- one process builds the next finds.
  local home = env_get("COSMIC_BUILD_HOME")
  if home ~= nil and home ~= "" then
    local made_home, _ = Fs.mkdirs(home)
    if made_home then own[#own + 1] = home end
  end
  -- What the module's `policy` call stands for as it loads, through the
  -- hook [`cosmic.test`] leaves for a runner; once it has loaded, a call
  -- is refused.
  local handed_over: Given = { deliberate = "" }
  -- Each reason the test gives [`Test.skip`], once, in order.
  local reasons: mut {string} = {}
  -- What [`Test.skip`] raises to end its test. Only this table counts as
  -- a skip; any other error is a failure, and a test cannot make this one.
  local ended_by_skip: {string:string} = {}
  setmetatable(ended_by_skip, {
    __tostring = function(): string return "the test was skipped" end,
  })
  local runner = {
    loaded = false,
    deliberate = function(reason: string) handed_over.deliberate = reason end,
    handed = function(needs: Test.Needs) handed_over.handed = needs end,
    -- Where the files above the project are, for a module that declares
    -- some ([`Test.parent`]).
    parent = env_get("COSMIC_TEST_PARENT"),
    skipped = function(reason: string): {string:string}
      local seen = false
      for _, given in ipairs(reasons) do
        if given == reason then seen = true end
      end
      if not seen then reasons[#reasons + 1] = reason end
      return ended_by_skip
    end,
  }
  install(Test, runner)
  -- The hold on `require` is up for the module's load and its test
  -- alone, not for the worker's own work around them.
  -- Each under a stand-in for `spawn` ([`confine.call`]), which holds what
  -- the test starts.
  local loading = confine.call(function(): any
    return held(function(): any return load_module.load(module_path) end)
  end, nil, own, sandboxed)
  local loaded, produced = loading.ok, loading.produced
  runner.loaded = true
  if load_session ~= nil then
    local hits, _ = Coverage.stop(load_session)
    report.load_hits = hits
    child_into = hits
  end
  local needs = loaded and test_inputs.canonical(test_inputs.as_declared(handed_over.handed)) or ""
  if loaded and needs ~= expected_needs then
    loaded = false
    produced = "its cosmic.test policy call stands for what the build did not read " ..
      "from its source -- the build reads only a top-level Test.policy { ... } " ..
      "on a local bound to require(\"cosmic.test\") (see cosmic.test):\n" ..
      "  handed:\n    " .. (if needs == "" then "nothing" else needs:gsub("\n", "\n    ") end) ..
      "\n  read:\n    " .. (if expected_needs == "" then "nothing" else
        expected_needs:gsub("\n", "\n    ") end)
  end
  report.loaded = loaded
  if not loaded then
    report.message = "the module failed to load: " .. tostring(produced)
    if sandboxed then
      report.message = report.message .. unseen_note(report.message, loading.unseen)
    end
  else
    local fn: any = produced is {string: any} and produced[name] or nil
    if not (fn is function(...: any): (any...)) then
      report.message = module_path .. " has no test named " .. name
    else
      local test_session, _ = Coverage.start()
      local started = monotonic_ns()
      Assertions.reset()
      local ran = confine.call(function(argument: any): any
        return held(fn, argument)
      end, tmp, own, sandboxed)
      local finished = monotonic_ns()
      if test_session ~= nil then
        local hits, _ = Coverage.stop(test_session)
        report.test_hits = hits
        child_into = hits or child_into
      end
      -- A test that skipped ends by raising `ended_by_skip`: it passed as far
      -- as it ran, and `report.skipped` says it checked less than it exists to.
      report.passed = ran.ok or ran.produced == ended_by_skip
      report.message = if report.passed then "" else tostring(ran.produced) end
      if sandboxed and not report.passed then
        report.message = report.message .. unseen_note(report.message, ran.unseen)
      end
      report.skipped = table.concat(reasons, "; ")
      report.asserted = Assertions.count()
      report.deliberate = handed_over.deliberate
      report.elapsed_ns = finished - started
    end
  end
  if children ~= nil then
    child_hits(children, child_into or {})
  end
  -- What it ran, as `judge` holds it: taken last, so it holds what the
  -- test loaded as well as what this did.
  local modules: mut {string} = {}
  for loaded_name in pairs(package.loaded) do
    if loaded_name is string then modules[#modules + 1] = loaded_name end
  end
  table.sort(modules)
  report.modules = modules
  report.violations, report.dropped = worker.violations(), worker.dropped_violations()
  local written, trouble = put(worker.report_fd, worker.encode(report))
  if not written then
    complain("the test report: " .. trouble)
    return 2
  end
  return 0
end

return worker
