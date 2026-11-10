--- One test, run in a process of its own: the other half of
--- [`build.test`], which starts this as `cosmic test --worker <root>
--- <module> <test> <tmp> <children> <needs>` and alone records what it
--- reports. With `--fork` the worker runs several tests of its module, each
--- in a copy of itself made once the module has loaded ([`worker.run`]).
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
local process = require("cosmic.internal.process")
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
local extra: any = select(2, ...) -- checked: any_use
local store: raw_store
if type(extra) == "table" then
  store = extra as raw_store -- checked: cast_refused
else
  store = require("cosmic.internal.store")
end

local record worker
  --- What one worker found, as the runner reads it back.
  record Report
    mut loaded: boolean
    mut passed: boolean
    mut message: string
    mut elapsed_ns: integer
    mut load_hits: Coverage.Hits
    mut test_hits: Coverage.Hits
    --- The name of every module in the worker's `package.loaded` once
    --- its test has run, sorted: what it ran, which `judge` holds to
    --- what a key holds of it (`loads`).
    mut modules: mut {string}
    --- Why its test is skipped ([`Test.skip`]): each reason it was given,
    --- once, joined by "; "; "" or nil where it called none.
    mut skipped?: string
    --- How many calls to `assert` the test made while it ran, through
    --- every helper and fixture it called: 0 for one that did not run.
    --- A test that passes with none made no call to `assert`
    --- ([`Judgement.unchecked`]).
    mut asserted?: integer
    --- What [`Test.passed_unchecked`] said, "" where it was not called: the
    --- test passed having deliberately not checked, which is no
    --- [`Judgement.unchecked`].
    mut deliberate?: string
    --- The violations a checked run's worker met, in the order met, and
    --- how many more it kept no record of ([`worker.install_checks`]).
    mut violations?: {Violation}
    mut dropped?: integer
    --- Whether the hooks this process defines are the harness's own: `__fact` and `__cosmic_tc`
    --- are [`worker.fact`] and the parameter hook, not the stub that a wrapped chunk defines where
    --- none is. Set where the report is made, so a worker that installed nothing, or lost the
    --- hooks, reports false ([`worker.judge`] fails a checked run's test for it).
    mut checked?: boolean
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
    mut at: string
    target: string
    declared: string
    actual: string
    mut count: integer
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
    --- The tests a forking worker runs, in order, each in a copy of itself
    --- (`--fork`, [`worker.run`]); nil for a worker that runs the one test
    --- `name`.
    forks?: {string}
    --- The descriptor of the runner's the worker reports on, where the
    --- runner reads it as it comes; nil for a report captured whole.
    report?: integer
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
    --- Whether the run is checked (`--check-types`): a report that does not say its hooks are the
    --- harness's fails its test.
    checks?: boolean
  end

  --- A finished worker's verdict: its report, nil where there is none,
  --- and whether its test passed, with what to say of it; and, of one
  --- that passed, why it is skipped instead ([`Report.skipped`]), "" for
  --- a pass.
  record Judgement
    report?: Report
    mut passed: boolean
    mut message: string
    mut skipped?: string
    --- Whether it passed, and was not skipped, without one call to `assert`
    --- ([`Report.asserted`]): it ran and made no call to `assert`, which a held run
    --- fails and no run keeps a verdict of.
    mut unchecked?: boolean
    --- Of one that passed, what it said it deliberately did not check
    --- for ([`Report.deliberate`]), "" for none.
    mut deliberate?: string
  end

  --- One record a forking worker writes its runner ([`worker.run`]'s `--fork`), as [`worker.record_at`] reads it:
  ---
  --- - "forks": its module loaded and it will run its tests, each in a copy of itself;
  --- - "unforkable": it will run none, `why`, and its runner starts a worker for each;
  --- - "test": the copy for the test `name` is about to be made, at `started_ns` on the monotonic clock;
  --- - "output": that copy, or what it started, printed `output`, the next of it;
  --- - "result": that copy ended, by its exit status `code` or the `signal` that ended it (-1 for the other), having
  ---   written `report` ([`worker.encode`]) and, with what it started, the last of its `output`;
  --- - "retire": the worker runs no more of its tests, `why`, and its runner starts another for the rest;
  --- - "malformed": bytes no forking worker writes.
  record Forked
    kind: string
    name?: string
    started_ns?: integer
    code?: integer
    signal?: integer
    report?: string
    output?: string
    why?: string
    --- Where the next record starts.
    after: integer
  end

  --- The descriptor the report is written to.
  mut report_fd: integer

  record_at: function(buffer: string, at: integer): Forked?
  forked_result: function(record: Forked, printed: string): Child.Result
  unreported_result: function(ended: Child.Result?, printed: string): Child.Result?
  forks_here: function(): boolean, string

  --- The pipe a forking worker's records come to its runner on ([`worker.relay`]).
  record Relay
    --- The end the runner reads, which does not wait.
    reader: integer
    --- The end the worker is given as its report descriptor, which the runner closes once the worker has started.
    writer: integer
  end

  relay: function(): Relay?, string

  --- The most distinct violations a worker keeps a record of: any more are
  --- counted ([`worker.dropped_violations`]) and nothing else.
  mut most_kept: integer

  install_checks: function()
  hooks_held: function(): boolean
  --- Crosses a boundary by hand, as the Lua of a checked function does by calling the `__cosmic_tc` that [`install_checks`]
  --- defines ([`lang.boundary_checks`]): `text` is the spec ("p" parameters, "r" return values, "f" a field written) and
  --- `values` the values crossing it. It answers nothing, where the global answers the values: a test that needs them keeps
  --- them. A violation of a parameter is placed at the line that called `cross`, where a checked function's is placed at its
  --- caller's.
  cross: function(text: string, ...: any)
  --- The `__fact` that [`install_checks`] defines: the hook the calls of [`lang.fact_wraps`] run, for a test that runs
  --- the Lua of a program with them.
  mut fact: function(v: any, taken: string, place: string, strings?: {string}, classes?: {any}, tag?: string,
                 tags?: {string} | string, at?: string): any
  violations: function(): {Violation}
  dropped_violations: function(): integer

  mut loads: {string}
end

worker.report_fd = 3

local HEADER <const> = "cosmic-test-report-5"
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
--- harness's epoch (build/harness_epoch.tl) and the harness's digest,
--- which holds each by its bytecode stripped of debug information
--- ([`build.test_key`]'s `harness`). `judge` fails a sandboxed test whose
--- worker loaded a module of the tree the tool carries that is neither
--- here nor in its closure, so what a worker runs is in its closure or
--- in those digests. A module added to the worker's way is named here by
--- the first test that reaches it, not found by a walk of the `imports`
--- table, which follows `local type` requires Teal erases and requires
--- inside functions no worker calls.
worker.loads = {
  "build.assertions", "build.cache_names", "build.code_walk", "build.confine", "build.key_parts", "build.load_module",
  "build.test_inputs",
  "build.test_worker", "build.this_program", "cmd.cosmic.main", "cosmic.coverage",
  "cosmic.env", "cosmic.fs", "cosmic.internal.source_run", "cosmic.proc", "cosmic.test",
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
  --- The declared kinds, the kinds as a set and whether the declaration names `integer` alone, by position: a position
  --- declared `-` has none, so these are sparse.
  declared: mut {integer: string}
  kinds: mut {integer: {string:boolean}}
  integral: mut {integer: boolean}
  -- The violations met at each position, by the value's kind and then the
  -- place that sent it, so a repeated one is found without building a key.
  memo: mut {mut {string:mut {string:worker.Violation}}}
end

-- The library the hook runs on, taken as the module loads: a test that
-- replaces `string.match` or `table.concat` with a wrapper of its own, as
-- one counts the string work of what it measures, must not have the hook
-- call it, for the wrapper's own checked parameters would call the hook.
local gmatch, lua_match = string.gmatch, string.match
local lua_type, math_type = type, math.type
local lua_char, lua_error = string.char, error
local lua_ipairs, lua_remove = ipairs, table.remove
-- These are overloaded in the library, so each is declared with the one signature the hook calls it by.
local lua_byte: function(string, integer): integer? = string.byte -- checked: overload_value
local lua_gsub: function(string, string, any): string, integer = string.gsub -- checked: overload_value
local lua_tonumber: function(string, integer): number? = tonumber -- checked: overload_value
local lua_pcall: function(any, ...: any): boolean, any... = pcall -- checked: overload_value
local lua_select = select -- checked: overload_value
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
local tally = 0
-- The place that sent a value is asked of the stack for every violation of
-- a parameter, in constant time, so the report names it however often a
-- boundary is violated; what is bounded is how many distinct violations one
-- worker keeps ([`worker.most_kept`]).

local function parse_check(text: string): Check
  local fields: mut {string} = {}
  for field in gmatch(text .. ";", "([^;]*);") do fields[#fields + 1] = field end
  -- A spec is `kind;place;...`, so a text with no place is no spec: the parse raises, and `hook` reports it unreadable.
  local spec_kind, spec_at = fields[1], fields[2]
  if spec_kind == nil or spec_at == nil then lua_error("a check of no place") end
  local check: Check = { kind = spec_kind, at = spec_at, name = "", n = 0, labels = {},
    declared = {}, kinds = {}, integral = {}, memo = {} }
  if check.kind ~= "p" and check.kind ~= "r" and check.kind ~= "f" then
    error("a check of no kind")
  end
  -- What is left of `fields` after the kind, the place and any name is one field for each position.
  lua_remove(fields, 1)
  lua_remove(fields, 1)
  if check.kind == "p" or check.kind == "f" then
    local name = fields[1]
    if name == nil then lua_error("a check of no name") end
    check.name = name
    lua_remove(fields, 1)
  end
  for index, field in lua_ipairs(fields) do
    local label, declared = field, field
    if check.kind == "p" then
      local parameter, kinds_text = lua_match(field, "^([^=]*)=(.*)$")
      if parameter == nil or kinds_text == nil then lua_error("a parameter of no kinds") end
      label, declared = parameter, kinds_text
    elseif check.kind == "r" then
      label = "return value " .. tostring(index)
    else
      label = check.name
    end
    check.n = index
    check.memo[#check.memo + 1] = {}
    check.labels[#check.labels + 1] = label
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
        kinds.number = true -- checked: map_field
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
-- TODO: read the class with whatever form the runtime keeps for the code the compiler writes, once the runtime no longer
-- exposes text `load` to programs (the runtime then has no reserved form that text can spell): the `@` of text is
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
    tally = tally + 1
    return
  end
  sites[at] = met
  found[#found + 1] = met
end

local function note(check: Check, index: integer, value: any, absent: boolean)
  local actual = lua_type(value)
  if actual == "number" then
    local subtype = math_type(value)
    -- `assert` is no call to make here: the test's count of them is read after it ran, and this runs inside it.
    if subtype == nil then lua_error("a number has an integer or float subtype", 0) end
    actual = subtype
  end
  if absent then actual = "absent" end
  local at = check.at
  if check.kind == "p" then
    -- The frame that called the checked function: this, the `pcall` that
    -- calls it, the hook, the checked function, its caller (a caller that
    -- runs C is passed over, as one that tail-called the function is no
    -- frame and names its own caller).
    at = raw_errors.where(5) or "?"
  end
  -- [`parse_check`] gives each position `hook` notes (1 to `check.n`) a memo, a label and, where it checks a kind, a declaration.
  local by_kind = check.memo[index]
  if by_kind == nil then lua_error("a violation is noted at a position of its check", 0) end
  local sites = by_kind[actual] or {}
  by_kind[actual] = sites
  local known = sites[at]
  if known ~= nil then
    again(known)
    latest.met = known
    return
  end
  local label = check.labels[index]
  if label == nil then lua_error("a position of a check has a label", 0) end
  local declared = check.declared[index]
  if declared == nil then
    lua_error("a position that met a kind its check refuses declares kinds", 0)
  end
  local target: string
  if check.kind == "p" then
    target = "parameter " .. label .. " of " .. check.name .. " (" .. check.at .. ")"
  elseif check.kind == "r" then
    target = label
  else
    target = "field " .. check.name
  end
  local met: worker.Violation = { kind = if check.kind == "p" then "parameter" elseif check.kind == "r" then "return" else "field" end,
    at = at, target = target, declared = declared, actual = actual, count = 1 }
  keep(sites, at, met)
  latest.met = met
end

local function parse_fact(text: string)
  local at, name, declared = lua_match(text, "^n;([^;]*);([^;]*);([^;]*)$")
  if at == nil or name == nil or declared == nil then error("a fact of no place") end
  local negated = lua_byte(declared, 1) == 126
  local fact: Fact = { at = (lua_gsub(at, "%%(%x%x)", function(digits: string): string
    local byte = lua_tonumber(digits, 16)
    return if byte is integer then lua_char(byte) else "?" end
  end)), name = name, declared = if negated then "not " .. declared:sub(2) else declared end,
    kinds = {}, negated = negated, integral = false }
  local integer, number = false, false
  for kind in gmatch(if negated then declared:sub(2) else declared end, "[^|]+") do
    if kind == "integer" then
      integer = true
    else
      fact.kinds[kind] = true
      number = number or kind == "number"
    end
  end
  if integer and not number then
    if negated then
      fact.kinds.integer = true -- checked: map_field
    else
      fact.kinds.number = true -- checked: map_field
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
    broken = kinds[kind] == true or (kind == "number" and kinds.integer == true and math_type(value) == "integer") -- checked: map_field
  else
    broken = kinds[kind] ~= true or (kind == "number" and fact.integral and math_type(value) ~= "integer")
  end
  if not broken then return value end
  local actual = kind
  if actual == "number" then
    local subtype = math_type(value)
    if subtype == nil then lua_error("a number has an integer or float subtype", 0) end
    actual = subtype
  end
  lua_error("fact violated at " .. fact.at .. ": " .. fact.name .. " is " .. actual ..
      ", the checker proved " .. fact.declared, 0)
end

local unreadable_sites: mut {string:worker.Violation} = {}

-- Records a check the hook could not use, a spec that does not parse or a violation it could not
-- record, as a row of kind "unreadable". The test goes on as it did, but its run reports the row and
-- keeps no verdict of it, so a check that checks nothing is never taken for one that held.
local function note_unreadable(what: string, text: string)
  local shown_text = lua_sub(text, 1, 60)
  local key = what .. "\0" .. shown_text
  local known = unreadable_sites[key]
  if known ~= nil then
    again(known)
    return
  end
  keep(unreadable_sites, key, { kind = "unreadable", at = "?", target = what, declared = shown_text,
    actual = "unreadable", count = 1 })
end

local function hook(_: integer, text: string, ...: any): any...
  local check = checks[text]
  if check == nil then
    local fact = facts[text]
    if fact ~= nil then return verify(fact, (...)) end
    if malformed[text] ~= true then
      if lua_byte(text, 1) == 110 then
        if lua_pcall(parse_fact, text) then
          local parsed = facts[text]
          if parsed == nil then lua_error("a fact spec that parsed is kept in facts", 0) end
          return verify(parsed, (...))
        end
        malformed[text] = true
        note_unreadable("a fact spec", text)
      -- A parse that succeeds leaves its check in `checks`.
      elseif lua_pcall(parse_check, text) then
        check = checks[text]
      else
        malformed[text] = true
        -- "-" is the spec of a boundary the declared types leave nothing to check at, not a spec gone wrong.
        if text ~= "-" then note_unreadable("a check spec", text) end
      end
    end
    -- A spec that does not parse checks nothing and is no failure of the
    -- test: the values pass as they came.
    if check == nil then
      if lua_byte(text, 1) == 102 then return (...) end
      return ...
    end
  end
  local given = lua_select("#", ...) -- untyped: call
  for index = 1, check.n do
    local kinds = check.kinds[index]
    if kinds ~= nil then
      local value = (lua_select(index, ...)) -- untyped: call
      local kind = lua_type(value)
      if kinds[kind] ~= true or (kind == "number" and check.integral[index] == true and
          math_type(value) ~= "integer") then
        -- A check that fails to say so is no failure of the test.
        latest.met = nil
        local noted = lua_pcall(note, check, index, value, index > given)
        -- Reachable only when recording runs out of memory; the row keeps the verdict out, which fails safe.
        if not noted then note_unreadable("a violation it could not record", check.at) end
        local met = latest.met
        -- A parameter of the standard library that meets a kind its declaration refuses ends the call, at the first
        -- one: either the caller or the declaration is wrong, and both are fixed.
        --
        -- TODO: once the checker lists each declared return and field write and lang/codegen.tl writes a check for it
        -- in a checked compile, raise for those kinds too: until then a return value or
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

local fact_sites: mut {string:worker.Violation} = {}

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
  if v is {string:any} then -- checked: is_on_record
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
-- Whether the globals hold the harness's own hooks now, once [`install_checks`] has said which globals: no before.
local hooks_are_held: function(): boolean = function(): boolean return false end

--- Whether `__fact` and `__cosmic_tc` are the harness's own hooks now ([`worker.install_checks`] defines them): what a
--- worker reports as `checked`.
function worker.hooks_held(): boolean
  return hooks_are_held()
end

function worker.install_checks()
  local globals = _G as {string:any} -- checked: cast_refused, unchecked_binding
  hooks_are_held = function(): boolean
    return rawget(globals, "__fact") == fact and rawget(globals, "__cosmic_tc") == hook
  end
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
  return tally
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

--- One more than the most lines a run of a report's hits names ([`worker.decode`] refuses a longer one): no chunk the
--- core loads holds this many instructions, nor a source this many lines.
local longest_run <const> = 1 << 24

local function encode_hits(lines: mut {string}, tag: string, hits: Coverage.Hits)
  if hits == nil then return end -- checked: compare_disjoint
  local paths: mut {string} = {}
  for path in pairs(hits) do paths[#paths + 1] = path end
  table.sort(paths)
  for _, path in ipairs(paths) do
    local numbers: mut {integer} = {}
    -- `path` is a key of `hits`, listed above.
    local hit_lines = hits[path]
    if hit_lines == nil then lua_error("a path listed from hits is in hits", 0) end
    local count, low, high = 0, math.maxinteger, math.mininteger
    for line in pairs(hit_lines) do
      count = count + 1
      if line < low then low = line end
      if line > high then high = line end
    end
    -- A module with no line hit names none: an empty list of lines is no report.
    if count == 0 then continue end
    -- In order: by a walk from the lowest to the highest where they are as dense as the instructions a pure
    -- store's import runs (each counted on a line of its own), else sorted.
    if count > 0 and high - low < 4 * count then
      for line = low, high do
        if hit_lines[line] == true then numbers[#numbers + 1] = line end
      end
    else
      for line in pairs(hit_lines) do numbers[#numbers + 1] = line end
      table.sort(numbers)
    end
    -- Each run of consecutive lines as its first and last, `first-last`.
    local text: mut {string} = {}
    local at = 1
    while at <= #numbers do
      local first = assert(numbers[at], "a line at each place up to the count")
      local last = first
      while numbers[at + 1] == last + 1 do
        at = at + 1
        last = last + 1
      end
      text[#text + 1] = if last > first then tostring(first) .. "-" .. tostring(last) else tostring(first) end
      at = at + 1
    end
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
            into[path] = here -- checked: view_written
          end
          local number = math.tointeger(tonumber(line))
          if number ~= nil then here[number] = true end -- checked: view_written
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
  for _, name in ipairs(report.modules) do table.insert(lines, "module " .. hex(name)) end
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
  if report.checked == true then table.insert(lines, "checked 1") end
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
  if text == nil or text == "" then return nil, "no report" end -- checked: compare_disjoint
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
      -- A line that begins with a space has no tag, and is as unknown as one with a tag that is none of these.
      if tag == nil or rest == nil then return nil, "an unknown line: " .. line end
      if tag == "loaded" then
        report.loaded = rest == "1"
      elseif tag == "passed" then
        report.passed = rest == "1"
      elseif tag == "elapsed" then
        report.elapsed_ns = math.tointeger(tonumber(rest)) or 0
      elseif tag == "message" then
        report.message = unhex(rest) or ""
      elseif tag == "load-hit" or tag == "test-hit" then
        local into = tag == "load-hit" and report.load_hits or report.test_hits -- checked: and_ternary
        local known = decoded_hits[rest]
        if known == nil then
          local path, numbers = rest:match("^([0-9a-f]*) ([0-9,%-]*)$")
          local decoded = if path ~= nil then unhex(path) else nil end
          if decoded == nil or numbers == nil then return nil, "a malformed hit: " .. line end
          -- Every item a line or a run, none empty, and none a run longer than the instructions of a chunk can be.
          if numbers == "" or numbers:find(",,", 1, true) ~= nil or numbers:sub(1, 1) == "," or
              numbers:sub(-1) == "," then
            return nil, "a malformed hit: " .. line
          end
          local per_line: mut {integer:boolean} = {}
          for item in numbers:gmatch("[^,]+") do
            local low, high = item:match("^(%d+)%-(%d+)$")
            if low == nil then low, high = item:match("^(%d+)$"), nil end
            local from = math.tointeger(tonumber(low))
            local to = if high ~= nil then math.tointeger(tonumber(high)) else from end
            if from == nil or to == nil or to < from or to - from >= longest_run then
              return nil, "a malformed hit: " .. line
            end
            for number = from, to do per_line[number] = true end
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
        local decoded = if packed ~= nil then unhex(packed) else nil end
        local kind, at, target, declared, actual: string?, string?, string?, string?, string?
        if decoded ~= nil then
          kind, at, target, declared, actual =
            decoded:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
        end
        if kind == nil or at == nil or target == nil or declared == nil or actual == nil then
          return nil, "a malformed violation: " .. line
        end
        local met = report.violations or {}
        report.violations = met
        local entry: worker.Violation = { kind = kind, at = at, target = target, declared = declared,
          actual = actual, count = math.tointeger(tonumber(count)) or 1 }
        met[#met + 1] = entry -- checked: view_written
      elseif tag == "checked" then
        report.checked = rest == "1"
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
    -- TODO: drop `nil_not_allowed` from this line once lang/stdlib.d.tl:314 declares the loader a `package.searchers`
    -- entry returns as optional: it declares one always, so returning none, as a searcher that knows nothing of the name
    -- does, is refused here (`any_use` stays).
    if why == nil then return nil, nil end -- checked: any_use, nil_not_allowed
    return function(_?: string, _?: any): any
      -- Level 3: the caller of `require`, past this loader and it.
      error(why, 3)
    end, nil -- checked: any_use
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
    for name in pairs(set_aside) do package.loaded[name] = nil end -- checked: view_written
    -- The table `require` and a hand-made loop both read is replaced for the call, by the gate and a guarded
    -- copy of each searcher, and put back as it was.
    local held_searchers = package.searchers
    local guarded_searchers: mut {function(string): (function(arg1?: string, arg2?: any): (any), any)} = { gate }
    for _, searcher in ipairs(held_searchers) do
      guarded_searchers[#guarded_searchers + 1] = guarded(searcher)
    end
    package.searchers = guarded_searchers
    local ok, produced = pcall(fn, argument) -- checked: overload_none -- untyped: call
    package.searchers = held_searchers
    for name, value in pairs(set_aside) do package.loaded[name] = value end -- checked: view_written
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
  for _, value in ipairs(given.start.argv) do argv[#argv + 1] = value end
  local program = given.program
  -- A relaunch's argv is the core, `--artifact` and the artifact's path,
  -- which the worker's startup takes as it is given.
  if program ~= nil and argv[2] == "--artifact" and argv[3] ~= nil then
    table.remove(argv, 3)
    table.insert(argv, 3, program)
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
  local forks = given.forks
  if forks ~= nil then
    argv[#argv + 1] = "--fork"
    argv[#argv + 1] = tostring(#forks)
    for _, test in ipairs(forks) do argv[#argv + 1] = test end
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
  env.COSMIC_COVERAGE_STARTUP = "1" -- checked: map_field
  env.COSMIC_TEST_TYPES = if given.checks == true then "1" else nil end -- checked: map_field
  local fds: mut {integer:integer | string} = { [worker.report_fd] = "capture" }
  local relayed_to = given.report
  if relayed_to ~= nil then fds[worker.report_fd] = relayed_to end
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
    policy.set_env = env -- checked: field_fixed
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
  local captured = result.captured[worker.report_fd]
  local report: worker.Report? = nil
  local decode_trouble = "no report"
  if captured ~= nil then report, decode_trouble = worker.decode(captured) end
  if report == nil then
    return { passed = false, skipped = "", message = "the test process " .. ending(result) ..
        " before it reported (" .. decode_trouble .. ")" }
  end
  if report.passed and judging.checks == true and report.checked ~= true then
    return { report = report, passed = false, skipped = "", message = "its worker was to run with the checks of " ..
        "a checked run, but `__fact` or `__cosmic_tc` was not the harness's own hook when it reported, so its pass " ..
        "would have checked nothing" }
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
  judgement.skipped = (if judgement.passed then report.skipped else nil end) or ""
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
  if module is {string:any} then module.__runner = runner end -- checked: is_on_record, map_field
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

--- The first line a forking worker writes its runner once it will fork.
local FORKS <const> = "cosmic-test-forks-1"

--- The most bytes kept of what one test of a forking worker printed, the newest: what [`cosmic.child`] keeps of a
--- captured stream.
local OUTPUT_LIMIT <const> = 16 * 1024 * 1024

--- Reads the record of a forking worker that starts at byte `at` of `buffer`, what its runner has read of the
--- worker's report so far: the record, or nil where it is not whole yet.
function worker.record_at(buffer: string, at: integer): worker.Forked?
  local stop = buffer:find("\n", at, true)
  if stop == nil then return nil end
  local line = buffer:sub(at, stop - 1)
  local after = stop + 1
  if line == FORKS then return { kind = "forks", after = after } end
  local reason = line:match("^unforkable ([0-9a-f]*)$")
  local kind = "unforkable"
  if reason == nil then reason, kind = line:match("^retire ([0-9a-f]*)$"), "retire" end
  local why = if reason ~= nil then unhex(reason) else nil end
  if why ~= nil then return { kind = kind, why = why, after = after } end
  local name, started = line:match("^test ([0-9a-f]+) (%d+)$")
  local decoded = if name ~= nil then unhex(name) else nil end
  local started_ns = math.tointeger(tonumber(started))
  if decoded ~= nil and started_ns ~= nil then
    return { kind = "test", name = decoded, started_ns = started_ns, after = after }
  end
  local printed = math.tointeger(tonumber(line:match("^output (%d+)$")))
  if printed ~= nil then
    if #buffer < after + printed - 1 then return nil end
    return { kind = "output", output = buffer:sub(after, after + printed - 1), after = after + printed }
  end
  local code_text, signal_text, report_text, output_text = line:match("^result (%-?%d+) (%-?%d+) (%d+) (%d+)$")
  local code, signal = math.tointeger(tonumber(code_text)), math.tointeger(tonumber(signal_text))
  local report_size, output_size = math.tointeger(tonumber(report_text)), math.tointeger(tonumber(output_text))
  if code ~= nil and signal ~= nil and report_size ~= nil and output_size ~= nil then
    local done = after + report_size + output_size
    if #buffer < done + 4 then return nil end
    if buffer:sub(done, done + 4) == "done\n" then
      return { kind = "result", code = code, signal = signal,
        report = buffer:sub(after, after + report_size - 1),
        output = buffer:sub(after + report_size, done - 1), after = done + 5 }
    end
  end
  return { kind = "malformed", why = line:sub(1, 80), after = after }
end

--- The end of a copy as [`worker.judge`] reads a worker's: `record`, a "result" record, with `printed`, all the copy
--- printed. It is made here, in the harness, since it is what a pass is read from.
function worker.forked_result(record: worker.Forked, printed: string): Child.Result
  local code, signal = record.code, record.signal
  return { code = if code ~= nil and code >= 0 then code else nil end,
    signal = if signal ~= nil and signal >= 0 then signal else nil end,
    ok = code == 0, timed_out = false, stdout = printed,
    captured = { [worker.report_fd] = record.report or "" }, truncated = false }
end

--- The end of a copy whose worker ended, as `ended`, before it wrote the copy's result: the worker's end with no
--- report, and `printed`, what the copy had printed. Nil where the worker's end is not known.
function worker.unreported_result(ended: Child.Result?, printed: string): Child.Result?
  if ended == nil then return nil end
  return { code = ended.code, signal = ended.signal, ok = false, timed_out = ended.timed_out,
    stdout = printed, captured = {}, truncated = ended.truncated }
end

--- Whether a worker on this host can run its tests in copies of itself: where Landlock scopes signals (ABI 6), so
--- that a copy can be held to signalling itself and what it starts ([`process.fork`]'s `scoped`), and its worker's
--- promises filter, which then leaves signals to that scope, lets a copy signal itself. False and why where not.
local cannot_fork: string? = nil
function worker.forks_here(): boolean, string
  local known = cannot_fork
  if known == nil then
    local abi, trouble = process.landlock_abi()
    if abi == nil then
      known = "no Landlock: " .. trouble
    elseif abi < 6 then
      known = "this kernel's Landlock scopes no signal (ABI " .. tostring(abi) .. ")"
    else
      known = ""
    end
    cannot_fork = known
  end
  if known ~= "" then return false, known end
  return true, ""
end

--- A pipe for a forking worker's records ([`worker.Invocation`]'s `report`), or nil and why.
function worker.relay(): worker.Relay?, string
  local pipe, trouble = process.pipe()
  if pipe == nil then return nil, trouble end
  local set, set_trouble = sys.set_nonblocking(pipe.reader, true)
  if not set then
    local _, _ = sys.close(pipe.reader)
    local _, _ = sys.close(pipe.writer)
    return nil, set_trouble
  end
  return { reader = pipe.reader, writer = pipe.writer }, ""
end

--- What of this process a copy of it would carry and a process started afresh would not have changed by loading
--- its module: the lines of /proc/thread-self/status that say its threads, its filters, its mask and how it takes
--- each signal, what each open descriptor names and where it is. "" where /proc cannot be read, which no two
--- readings equal.
local function carried(): string
  local status, _ = Fs.read("/proc/thread-self/status")
  local open, _ = sys.readdir("/proc/thread-self/fd")
  if status == nil or open == nil then return "" end
  local lines: mut {string} = {}
  for line in status:gmatch("[^\n]+") do
    local field = line:match("^([%w_]+):")
    if field == "Threads" or field == "Seccomp_filters" or field == "NoNewPrivs" or field == "Umask" or
        field == "SigBlk" or field == "SigIgn" or field == "SigCgt" then
      lines[#lines + 1] = line
    end
  end
  local numbers: mut {string} = {}
  for number in pairs(open) do numbers[#numbers + 1] = number end
  table.sort(numbers)
  for _, number in ipairs(numbers) do
    local named, _ = sys.readlink("/proc/thread-self/fd/" .. number)
    -- The listing's own descriptor is gone by now, and names nothing.
    if named ~= nil and named:find("/fd$") == nil then
      table.insert(lines, number .. " " .. named)
    end
  end
  local cwd, _ = sys.getcwd()
  table.insert(lines, "cwd " .. (cwd or "?"))
  return table.concat(lines, "\n")
end

--- The first line of `after` that `before` does not have at its place, beside the line `before` has there.
local function differing(before: string, after: string): string
  local was: mut {string} = {}
  for line in before:gmatch("[^\n]+") do was[#was + 1] = line end
  local at = 0
  for line in after:gmatch("[^\n]+") do
    at = at + 1
    if was[at] ~= line then
      return "`" .. line .. "`, which was `" .. (was[at] or "nothing") .. "`"
    end
  end
  return "`" .. (was[at + 1] or "nothing") .. "` is gone"
end

--- What an entry of the tmpfs was before any test ran, which [`restore`] gives it again.
local record Was
  kind: string
  mode: integer
  atime: integer
  atime_ns: integer
  mtime: integer
  mtime_ns: integer
end

--- Adds to `lines` what `path` is and, of a directory, what is beneath it, in order: each entry's kind, its mode,
--- the size of a file and where a link points; and to `held`, where given, each by its path.
local function shape(path: string, lines: mut {string}, depth: integer, held?: mut {string:Was})
  local there, why = sys.lstat(path)
  if there == nil then
    table.insert(lines, path .. " " .. why)
    return
  end
  local detail = ""
  if there.kind == "link" then
    local target, _ = sys.readlink(path)
    detail = target or "?"
  elseif there.kind ~= "dir" then
    detail = tostring(there.size)
  end
  table.insert(lines, path .. " " .. there.kind .. " " .. tostring(there.mode) .. " " .. detail)
  if held ~= nil then
    held[path] = { kind = there.kind, mode = there.mode, atime = there.atime, atime_ns = there.atime_ns,
      mtime = there.mtime, mtime_ns = there.mtime_ns }
  end
  if there.kind ~= "dir" or depth > 16 then return end
  local entries, _ = sys.readdir(path)
  local names: mut {string} = {}
  for name in pairs(entries or {}) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do shape(path .. "/" .. name, lines, depth + 1, held) end
end

--- What the sandbox's tmpfs holds, /tmp and all beneath it ([`shape`]): the one place a worker with a scratch
--- directory of its own can write.
local function written(held?: mut {string:Was}): string
  local lines: mut {string} = {}
  shape("/tmp", lines, 0, held)
  return table.concat(lines, "\n")
end

--- Whether a process other than this one and its namespace's init runs in this pid namespace, as its /proc lists
--- them; true where /proc cannot be listed, since none can then be ruled out.
local function others_run(): boolean
  local entries, _ = sys.readdir("/proc")
  if entries == nil then return true end
  local own = tostring(sys.getpid())
  for name in pairs(entries) do
    if name:find("^%d+$") ~= nil and name ~= "1" and name ~= own then return true end
  end
  return false
end

--- Everything `fd`, a descriptor that does not wait, holds now, added to `chunks`: whether it is still open, false
--- once its writers have all closed it.
local function take(fd: integer, chunks: mut {string}): boolean
  while true do
    local data, _ = sys.read(fd, 65536)
    if data == nil then return true end
    if data == "" then return false end
    chunks[#chunks + 1] = data
  end
end

--- The process's standard output and error set aside while a file takes what is written to them ([`keep_output`]).
local record Kept
  --- The file, open to read.
  file: integer
  out: integer
  err: integer
end

--- Points this process's standard output and error at a new file in `directory` that has no name, until [`put_back`]
--- puts them back: nil where it cannot, with both as they were.
local function keep_output(directory: string): Kept?
  local made, _ = sys.open_temporary(directory .. "/load-output", 0x180)
  if made == nil then return nil end
  -- Written through the descriptor it was made with, and read back through another.
  local reading, _ = sys.open(made.path, sys.O_RDONLY)
  local _, _ = sys.unlink(made.path)
  local out, _ = sys.dup(1)
  local err, _ = sys.dup(2)
  if reading == nil or out == nil or err == nil then
    if reading ~= nil then local _, _ = sys.close(reading) end
    if out ~= nil then local _, _ = sys.close(out) end
    if err ~= nil then local _, _ = sys.close(err) end
    local _, _ = sys.close(made.fd)
    return nil
  end
  local _, _ = sys.dup2(made.fd, 1)
  local _, _ = sys.dup2(made.fd, 2)
  local _, _ = sys.close(made.fd)
  return { file = reading, out = out, err = err }
end

--- Puts the standard output and error back as `held` found them and answers what was written meanwhile, the
--- newest [`OUTPUT_LIMIT`] bytes of it; nil where it cannot be read.
local function put_back(held: Kept): string?
  local _, _ = sys.dup2(held.out, 1)
  local _, _ = sys.dup2(held.err, 2)
  local _, _ = sys.close(held.out)
  local _, _ = sys.close(held.err)
  local size_of, _ = sys.fstat(held.file)
  local text: string? = nil
  if size_of ~= nil then
    local from = math.max(0, size_of.size - OUTPUT_LIMIT)
    local chunks: mut {string} = {}
    local whole = true
    while from < size_of.size do
      local data, _ = sys.pread(held.file, size_of.size - from, from)
      if data == nil or data == "" then
        whole = false
        break
      end
      chunks[#chunks + 1] = data
      from = from + #data
    end
    if whole then text = table.concat(chunks) end
  end
  local _, _ = sys.close(held.file)
  return text
end

--- Removes from `directory` and beneath it every entry `kept` does not name by its path, each with what is beneath
--- it, and gives each directory it names the mode it had. False and why at the first that cannot be.
local function sweep_new(directory: string, kept: {string:Was}, depth: integer): boolean, string
  local entries, list_trouble = sys.readdir(directory)
  if entries == nil then return false, directory .. ": " .. list_trouble end
  for name, kind in pairs(entries) do
    local path = directory .. "/" .. name
    local was = kept[path]
    if was == nil then
      local gone, trouble = Fs.remove_tree(path)
      if not gone then return false, path .. ": " .. trouble end
    elseif kind == "dir" then
      -- Its mode first, which a test may have changed, and which may be what keeps it from being listed.
      local there, _ = sys.lstat(path)
      if there ~= nil and there.mode ~= was.mode then
        local set, trouble = sys.chmod(path, was.mode & 0xfff)
        if not set then return false, path .. ": " .. trouble end
      end
      if depth < 16 then
        local swept, trouble = sweep_new(path, kept, depth + 1)
        if not swept then return false, trouble end
      end
    end
  end
  return true, ""
end

--- Puts the sandbox's tmpfs back as it was before a test that passed ran: nothing there but what `kept` names by
--- its path, which is what was there before any test ran, each directory of those with the mode it had, each entry
--- but a link with the times it was read and changed at, and the directory `children` there again. A test's own
--- directory is emptied so, and what it made beside it (`TMPDIR`), in /tmp or in its build directories. What else
--- it changed of an entry that was there is not put back: its worker finds a file of another size or kind
--- ([`written`]) and retires. False and why where an entry cannot be put back.
---
--- Not put back, since nothing can: the time an entry's status last changed, which a test that removed or made a
--- file beside it moved.
local function restore(children: string?, kept: {string:Was}): boolean, string
  local top = kept["/tmp"]
  local now_top, _ = sys.lstat("/tmp")
  if top ~= nil and now_top ~= nil and now_top.mode ~= top.mode then
    local _, _ = sys.chmod("/tmp", top.mode & 0xfff)
  end
  local swept, trouble = sweep_new("/tmp", kept, 0)
  if not swept then return false, trouble end
  if children ~= nil then
    local there, _ = sys.lstat(children)
    if there == nil then
      local remade, remade_trouble = sys.mkdir(children, 0x1c0)
      if not remade then return false, children .. ": " .. remade_trouble end
    end
  end
  for path, was in pairs(kept) do
    -- Only where a time moved: an entry no test can write, a mount to read, takes no time and has none to take.
    local now, _ = sys.lstat(path)
    if was.kind ~= "link" and now ~= nil and (now.mtime ~= was.mtime or now.mtime_ns ~= was.mtime_ns or
        now.atime ~= was.atime or now.atime_ns ~= was.atime_ns) then
      local timed, time_trouble = sys.utimensat(path, was.atime, was.atime_ns, was.mtime, was.mtime_ns)
      if not timed then return false, path .. ": " .. time_trouble end
    end
  end
  return true, ""
end

--- Runs each of `names`, a module's tests, in a copy of this process, one after another, and writes the runner a
--- record of each ([`worker.Forked`]). `tested` runs one test here and answers its report, `children` is where
--- what a test starts writes its coverage, and `before` is what
--- [`carried`] and [`written`] answered before the module loaded, and `preface` what the load printed, nil where
--- that could not be kept.
---
--- It forks only where a copy is what a worker started afresh would be once it had loaded the module: the load
--- left this process as it was but for its memory (`carried`), wrote nothing (`written`), and started no process,
--- none that runs and none that ended. Otherwise it says why ("unforkable") and runs nothing.
---
--- Each copy is held to signalling itself and what it starts ([`process.fork`]'s `scoped`), has a pipe of its own
--- for its output and one for its report, and no descriptor of the runner's. Once it has ended, this process
--- writes what it reported and printed. It goes on to the next test only after one that passed and left no
--- process running, once the tmpfs is as it was before any test ran ([`restore`]); after any other, or where the
--- tmpfs cannot be put back, it retires, saying why, and its namespace ends with it as a worker's does.
---
--- In the copy it answers nil, the test's report written: the copy returns from [`worker.run`] as any worker does.
local function fork_tests(names: {string}, tested: function(string): (worker.Report), children: string?,
                          before: string, preface: string?): integer?
  local relay = worker.report_fd
  local why = ""
  local now = carried()
  if preface == nil then
    why = "what its load printed could not be kept for its tests"
  elseif before == "" or now == "" then
    why = "its /proc could not be read, to say what its load left"
  elseif now .. "\n" .. written() ~= before then
    why = "its load left a descriptor, a file, a filter or a signal's handling changed: " ..
      differing(before, now .. "\n" .. written())
  elseif others_run() then
    why = "a process beside it runs in its namespace"
  else
    -- A worker is the second process of a pid namespace of its own, so the first it starts is the third: any other
    -- number says its load started one, which has ended since. A copy would not be what a worker that started it
    -- is ([`cosmic.child`] remembers that it adopts orphans, which the kernel forgets of a copy).
    local probe, _ = process.fork(false)
    if probe == 0 then sys.exit(0) end
    if probe ~= nil then local _, _ = process.waitpid(probe, false) end
    if probe ~= 3 or sys.getpid() ~= 2 then why = "its load started a process" end
    -- What the probe wrote of its own coverage, as a process a test starts does, is no test's.
    if children ~= nil then
      local reports, _ = sys.readdir(children)
      for name in pairs(reports or {}) do
        local _, _ = Fs.remove(children .. "/" .. name)
      end
    end
  end
  if why ~= "" then
    local _, _ = put(relay, "unforkable " .. hex(why) .. "\n")
    return 0
  end
  -- What is still to write the runner, in order. The runner is one process that records each result as it reads
  -- it, and a worker that waited for it to read would leave its processor idle meanwhile: so the descriptor does
  -- not wait, a record goes out as the pipe takes it, while the next test runs, and what is left goes out, waited
  -- for, before this worker ends.
  local outbox: mut {string} = {}
  local _, _ = sys.set_nonblocking(relay, true)
  -- Writes what the pipe takes now. False once the runner is gone.
  local sent_of_first = 0
  local function send(): boolean
    while true do
      local data = outbox[1]
      if data == nil then return true end
      -- A pipe takes a part of a large record at a time: what is left of it is cut once, not at every write.
      local piece = if sent_of_first > 0 then data:sub(sent_of_first + 1, sent_of_first + 65536) else
        data:sub(1, 65536) end
      local sent, _, number = sys.write(relay, piece)
      if sent == nil then return number == sys.EAGAIN or number == sys.EINTR end
      sent_of_first = sent_of_first + sent
      if sent_of_first >= #data then
        table.remove(outbox, 1)
        sent_of_first = 0
      end
    end
  end
  -- Writes all that is left, waiting for the runner to read.
  local function send_all()
    while outbox[1] ~= nil and send() do
      if outbox[1] ~= nil then local _, _ = sys.poll({ relay }, { sys.POLLOUT }, -1) end
    end
  end
  -- What the tmpfs holds now, before any test runs, and each entry of it.
  local kept: mut {string:Was} = {}
  local tmpfs = written(kept)
  outbox[#outbox + 1] = FORKS .. "\n"
  for index, name in ipairs(names) do
    local output, output_trouble = process.pipe()
    local report, report_trouble = process.pipe()
    if output == nil or report == nil then
      table.insert(outbox, "retire " .. hex("a pipe: " .. output_trouble .. report_trouble) .. "\n")
      send_all()
      return 0
    end
    table.insert(outbox, "test " .. hex(name) .. " " .. tostring(monotonic_ns()) .. "\n")
    local pid, fork_trouble = process.fork(true)
    if pid == nil then
      table.insert(outbox, "result -1 -1 0 0\ndone\nretire " .. hex("fork: " .. fork_trouble) .. "\n")
      send_all()
      return 0
    end
    if pid == 0 then
      -- The test's own streams, and nothing of the runner's: what it writes, its worker relays.
      local _, _ = sys.close(output.reader)
      local _, _ = sys.close(report.reader)
      local _, _ = sys.close(relay)
      local _, _ = sys.dup2(output.writer, 1)
      local _, _ = sys.dup2(output.writer, 2)
      local _, _ = sys.close(output.writer)
      if preface ~= nil and preface ~= "" then local _, _ = put(1, preface) end
      local wrote, write_trouble = put(report.writer, worker.encode(tested(name)))
      local _, _ = sys.close(report.writer)
      if not wrote then
        complain("the test report: " .. write_trouble)
        return 2
      end
      return nil
    end
    local _, _ = sys.close(output.writer)
    local _, _ = sys.close(report.writer)
    local _, _ = sys.set_nonblocking(output.reader, true)
    local _, _ = sys.set_nonblocking(report.reader, true)
    local reported: mut {string} = {}
    -- What it prints goes to the runner as it comes, so that the runner has it of a test whose worker it ends.
    local function relay_output(): boolean
      local printed: mut {string} = {}
      local open = take(output.reader, printed)
      for _, data in ipairs(printed) do
        table.insert(outbox, "output " .. tostring(#data) .. "\n" .. data)
      end
      return open
    end
    local watch, _ = process.exit_watch(pid)
    local ended: process.ChildStatus? = nil
    local printing, reporting = true, true
    while ended == nil do
      local fds: mut {integer} = {}
      local events: mut {integer} = {}
      if printing then fds[#fds + 1], events[#events + 1] = output.reader, sys.POLLIN end
      if reporting then fds[#fds + 1], events[#events + 1] = report.reader, sys.POLLIN end
      if watch ~= nil then fds[#fds + 1], events[#events + 1] = watch, sys.POLLIN end
      if outbox[1] ~= nil then fds[#fds + 1], events[#events + 1] = relay, sys.POLLOUT end
      -- With no watch of its exit, its end is looked for every millisecond.
      local _, _ = sys.poll(fds, events, if watch ~= nil then -1 else 1 end)
      if printing then printing = relay_output() end
      local _ = send()
      if reporting then reporting = take(report.reader, reported) end
      local status, _ = process.waitpid(pid, true)
      if status == nil then
        ended = { pid = pid, code = -1, signal = -1 }
      elseif status.pid == pid then
        ended = status
      end
    end
    -- What it and the processes it started wrote before it ended; one still running may hold a pipe open, and is
    -- not waited for.
    local _ = relay_output()
    local _ = take(report.reader, reported)
    local _, _ = sys.close(output.reader)
    local _, _ = sys.close(report.reader)
    if watch ~= nil then local _, _ = sys.close(watch) end
    local said = table.concat(reported)
    local strays = others_run()
    -- Its result goes out before the tmpfs is put back, which is no part of its test's time.
    table.insert(outbox, "result " .. tostring(ended.code) .. " " .. tostring(ended.signal) .. " " ..
        tostring(#said) .. " 0\n" .. said .. "done\n")
    local _ = send()
    local retire = ""
    if ended.code ~= 0 or said:find("\npassed 1\n", 1, true) == nil or said:sub(-5) ~= "\nend\n" then
      retire = "its test did not pass"
    elseif strays then
      retire = "its test left a process running"
    elseif index < #names then
      local restored, restore_trouble = restore(children, kept)
      if not restored then
        retire = "its test's directory could not be emptied: " .. restore_trouble
      else
        local left = written()
        if left ~= tmpfs then
          retire = "its test left the sandbox's tmpfs changed: " .. differing(tmpfs, left)
        end
      end
    end
    if retire ~= "" then table.insert(outbox, "retire " .. hex(retire) .. "\n") end
    if retire ~= "" or not send() then break end
  end
  send_all()
  return 0
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
--- - `--fork <count> <test>...` after `--sandboxed` and what follows it names the module's tests to run, in
---   place of `test`: the worker loads the module, then runs each in a copy of itself (a fork), one after
---   another, and writes the runner a record of each ([`worker.Forked`]) on its report descriptor, which the
---   runner reads as it comes; where a copy would not be what a worker of the test's own is, it runs none and
---   says why.
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
      local given: mut {string} = {}
      for i = 1, count do given[#given + 1] = argv[first + 1 + i] or "" end
      runs = given
      first = first + 2 + count
    end
  end
  local forks: mut {string}? = nil
  if argv[first] == "--fork" then
    local count = math.tointeger(tonumber(argv[first + 1] or "")) or 0
    if count < 1 then
      complain("test --worker: --fork needs a count and that many tests")
      return 2
    end
    local named: mut {string} = {}
    for i = 1, count do named[#named + 1] = argv[first + 1 + i] or "" end
    forks = named
    first = first + 2 + count
  end
  local holding = argv[2]
  if holding ~= nil and (holding == "--worker-no-tool" or holding == "--worker-held") then
    local no_tool = holding == "--worker-no-tool"
    local forbidden, forbid_trouble = confine.forbid_running(if no_tool then confine.itself() else {} end, runs)
    if not forbidden then
      complain("test " .. holding .. ": this program cannot be held by a Landlock " ..
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
  local db_path = argv[first + 1]
  if argv[first] ~= "--store" or db_path == nil then
    complain("test --worker: --store needs a path")
    return 2
  end
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
    local closure: mut {string:boolean} = {}
    local tree: mut {string:boolean} = {}
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
  local children = if made then children_path else nil end
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
  setmetatable(ended_by_skip, { -- checked: setmetatable_call -- untyped: call
    __tostring = function(): string return "the test was skipped" end,
  })
  local runner = { -- checked: arms_differ
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
  -- A forking worker forks only where its load left the process as it was ([`fork_tests`]): what it is before.
  local before = ""
  if forks ~= nil then
    local carries = carried()
    if carries ~= "" then before = carries .. "\n" .. written() end
  end
  -- What its load prints is each of its tests' to show, as the worker of one test shows it: kept in a file with
  -- no name while the module loads, and written ahead of each test's own output ([`fork_tests`]).
  local kept_output: Kept? = nil
  if forks ~= nil then kept_output = keep_output(Fs.dirname(tmp)) end
  local loading = confine.call(function(): any -- checked: not_assignable
    return held(function(): any return load_module.load(module_path) end) -- checked: not_assignable
  end, nil, own, sandboxed)
  local preface = if kept_output ~= nil then put_back(kept_output) else nil end
  local loaded, produced = loading.ok, loading.produced
  runner.loaded = true
  if load_session ~= nil then
    local hits, _ = Coverage.stop(load_session)
    if hits ~= nil then
      report.load_hits = hits
      child_into = hits
    end
  end
  local needs = loaded and test_inputs.canonical(test_inputs.as_declared(handed_over.handed)) or "" -- checked: and_ternary
  if loaded and needs ~= expected_needs then
    loaded = false
    produced = "its cosmic.test policy call stands for what the build did not read " ..
      "from its source -- the build reads only a top-level Test.policy { ... } " ..
      "on a local bound to require(\"cosmic.test\") (see cosmic.test):\n" ..
      "  handed:\n    " .. (if needs == "" then "nothing" else needs:gsub("\n", "\n    ") end) .. -- untyped: call
      "\n  read:\n    " .. (if expected_needs == "" then "nothing" else
        expected_needs:gsub("\n", "\n    ") end)
  end
  local function tested(chosen: string): worker.Report
    report.loaded = loaded
    if not loaded then
      report.message = "the module failed to load: " .. tostring(produced)
      if sandboxed then
        report.message = report.message .. unseen_note(report.message, loading.unseen)
      end
    else
      local fn: any = produced is {string: any} and produced[chosen] or nil -- checked: and_ternary, is_on_record
      if not (fn is function(...: any): (any...)) then -- checked: is_on_record
        report.message = module_path .. " has no test named " .. chosen
      else
        local test_session, _ = Coverage.start()
        local started = monotonic_ns()
        Assertions.reset()
        local ran = confine.call(function(argument: any): any -- checked: not_assignable
          return held(fn, argument)
        end, tmp, own, sandboxed)
        local finished = monotonic_ns()
        if test_session ~= nil then
          local hits, _ = Coverage.stop(test_session)
          if hits ~= nil then
            report.test_hits = hits
            child_into = hits
          end
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
    report.checked = worker.hooks_held()
    return report
  end
  if forks ~= nil then
    -- A module that did not load forks nothing: each of its tests' workers says so of its own load.
    if not loaded then
      local _, _ = put(worker.report_fd, "unforkable " .. hex("its module did not load") .. "\n")
      return 0
    end
    local status = fork_tests(forks, tested, children, before, preface)
    if status ~= nil then return status end
    return 0
  end
  local wrote, trouble = put(worker.report_fd, worker.encode(tested(name)))
  if not wrote then
    complain("the test report: " .. trouble)
    return 2
  end
  return 0
end

return worker
