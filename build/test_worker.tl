--- One test, run in a process of its own: the other half of
--- `build.test`, which starts this as `cosmic test --worker <root>
--- <module> <test> <tmp> <children> <needs>` and alone records what it
--- reports.
---
--- The worker never opens the build database. It attaches the tree's
--- compiled modules, loads the test's module, calls the one test with
--- its temporary directory, and writes a report to descriptor 3: what
--- the load and the test read, which lines each hit, how long the test
--- took, and whether it passed. Its standard streams are the test's,
--- captured by the runner. A report that is missing or cut short --
--- the test exited the process, crashed it, or ran past its deadline --
--- is itself the runner's answer that the test failed.

local type Child = require("cosmic.child")
local Coverage = require("cosmic.coverage")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Store = require("cosmic.store")
local type raw_store = require("cosmic.internal.store")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local Time = require("cosmic.time")
local confine = require("build.confine")
local declared_key = require("build.declared_key")
local observations = require("build.filesystem_observations")
local test_inputs = require("build.test_inputs")
local log = require("build.verdict").log

--- The store's raw table, which the searcher hands this module as its
--- loader's extra value when it loads trusted (core/store.c's
--- `raw_modules`): `cosmic.store` offers no hold, so what a test loads
--- cannot put one up or take one down. Boot mode, which runs no
--- worker, has it by name alone.
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
    load_reads: {observations.Observation}
    test_reads: {observations.Observation}
    load_hits: Coverage.Hits
    test_hits: Coverage.Hits
    --- The name of every module in the worker's `package.loaded` once
    --- its test has run, sorted: what it ran, which `judge` holds to
    --- what a key holds of it (`loads`).
    modules: {string}
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
    --- its name; what the build read of the module's `needs`
    --- (`test_inputs.canonical`), and what its sandbox holds a
    --- process it starts to, a path a line ("" for none).
    root: string
    cwd: string
    module_path: string
    name: string
    scratch: string
    needs: string
    held: string
    --- Whether it may not run this program (`--worker-no-tool`), and
    --- whether the store's hold is off (`--open`).
    no_tool: boolean
    open: boolean
    --- The names of the module's import closure, of every module of
    --- the tree, and of what only a declaration of the tree answers
    --- for (see `run`).
    closure: {string}
    tree: {string}
    declared: {string}
    --- The worker's sandbox, or nil where it runs unsandboxed.
    sandbox: Child.Sandbox
  end

  --- How a worker starts (`invocation`): its command line and its
  --- start options, for `Child.start`.
  record Command
    argv: {string}
    options: Child.Options
  end

  --- What `judge` reads a finished worker by.
  record Judging
    --- The worker's end, or nil where it could not be started or
    --- supervised.
    result: Child.Result
    --- Why there is no result; with one, what the worker left running
    --- past its end, or "" for nothing.
    trouble: string
    --- Whether `trouble` is why its worker was never started -- its
    --- module declares what cannot be given it -- said as it is.
    refused: boolean
    timeout_ms: integer
    sandboxed: boolean
    --- Where the loaded set is held (`unkeyed`): the modules of the
    --- tree the tool carries and the test's import closure, each a set
    --- of names; nil for no such hold.
    carried: {string:boolean}
    closure: {string:boolean}
  end

  --- A finished worker's verdict: its report, nil where there is none,
  --- and whether its test passed, with what to say of it.
  record Judgement
    report: Report
    passed: boolean
    message: string
  end

  --- The descriptor the report is written to.
  report_fd: integer

  loads: {string}
end

worker.report_fd = 3

local HEADER <const> = "cosmic-test-report-2"

--- The modules of the tree a worker loads besides its test's import
--- closure: cosmic's own main, which every process runs first and
--- which starts this ahead of build.dispatch, which a worker never
--- loads (cmd/cosmic/main.tl), nor what only it requires; this module and
--- what it requires, directly or not, at its top level or on the way
--- its `run` takes; and `cosmic.removed`, which the core loads in any
--- test that reaches for a removed global, to say what to write
--- instead (`diagnostics`): the code a worker runs of the tree but its
--- test's. No key holds them by what they are: every sandboxed key
--- holds the harness's epoch in their place (build/harness_epoch.tl),
--- and the harness's digests, which build/harness_epoch_test.tl holds
--- to those acknowledged there, hold each by its source and bytecode
--- (`build.test`'s `harness`). `judge` fails a sandboxed test whose
--- worker loaded a module of the tree the tool carries that is neither
--- here nor in its closure, so what a worker runs is in its closure or
--- in those digests, and a module
--- added to its way is named here by the first test that reaches it,
--- rather than trusted to a walk of the `imports` table, which follows
--- `local type` requires Teal erases and requires inside functions no
--- worker calls.
-- TODO: drop build.declared_key, and build.artifact, build.core_image
-- and build.launcher, which it requires, once no worker reaches its
-- `key_part` and `tree_name`: `encode_reads` goes with the worker's report of its reads
-- (removing the observation log, step 4), build.filesystem_observations
-- with the log (step 5).
worker.loads = {
  "build.artifact", "build.cache_names", "build.confine", "build.core_image", "build.declared_key",
  "build.filesystem_observations", "build.launcher", "build.test_inputs", "build.test_worker",
  "build.this_program", "build.verdict", "cmd.cosmic.main", "cosmic.codec", "cosmic.coverage", "cosmic.env",
  "cosmic.errors", "cosmic.fs", "cosmic.hash", "cosmic.log", "cosmic.proc", "cosmic.removed",
  "cosmic.sqlite", "cosmic.store", "cosmic.string", "cosmic.test", "cosmic.time",
}

local hex_byte: {string:string} = {}
for byte = 0, 255 do
  hex_byte[string.char(byte)] = string.format("%02x", byte)
end

local function hex(data: string): string
  return (data:gsub(".", hex_byte))
end

local function unhex(data: string): string | nil
  if #data % 2 ~= 0 or data:find("[^0-9a-f]") ~= nil then
    return nil
  end
  return (data:gsub("..", function(byte: string): string
    return string.char(tonumber(byte, 16) or 0)
  end))
end

-- TODO: a report longer than Child's capture limit (16 MB) loses its
-- head, and its test fails as one that never reported: an archive
-- fuzz test's reads overran it under FUZZ_ITERS=2000 while every read
-- of the test's own directory was noted twice, and its extraction
-- property still does past about 5000 (fuzz.yml runs 2000 until this
-- is fixed). So does a test of distinct reads alone: 20000 stats of
-- distinct paths outside the tree, each noted with its resolution,
-- report about 30 MB and fail so, which dropping repeats cannot help.
-- Under FUZZ_ITERS=8000 build/declared_key_fuzz_test.tl and
-- build/locator_fuzz_test.tl fail so too ("exited with status 0 before
-- it reported (not a test report)"), their properties having held.
-- Stream the report, read as it arrives, rather than capture it
-- whole; dropping repeated observations here, as `observations.join`
-- does on the runner's side, shrinks the rest.
local function encode_reads(lines: {string}, tag: string, found: {observations.Observation})
  for _, observation in ipairs(found) do
    lines[#lines + 1] = tag .. " " ..
      declared_key.key_part(observation.kind, observation.path, observation.answer)
  end
end

local function encode_hits(lines: {string}, tag: string, hits: Coverage.Hits)
  if hits == nil then return end
  local paths: {string} = {}
  for path in pairs(hits) do paths[#paths + 1] = path end
  table.sort(paths)
  for _, path in ipairs(paths) do
    local numbers: {integer} = {}
    for line in pairs(hits[path]) do numbers[#numbers + 1] = line end
    table.sort(numbers)
    local text: {string} = {}
    for i, line in ipairs(numbers) do text[i] = tostring(line) end
    lines[#lines + 1] = tag .. " " .. hex(path) .. " " .. table.concat(text, ",")
  end
end

--- Folds into `into` every line the processes the test started wrote
--- into `directory` (see `Coverage.children`), removing each file and
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
  local lines: {string} = { HEADER,
    "loaded " .. (report.loaded and "1" or "0"),
    "passed " .. (report.passed and "1" or "0"),
    "elapsed " .. tostring(report.elapsed_ns),
    "message " .. hex(report.message),
  }
  encode_reads(lines, "load-read", report.load_reads)
  encode_reads(lines, "test-read", report.test_reads)
  encode_hits(lines, "load-hit", report.load_hits)
  encode_hits(lines, "test-hit", report.test_hits)
  for _, name in ipairs(report.modules or {}) do lines[#lines + 1] = "module " .. hex(name) end
  lines[#lines + 1] = "end"
  return table.concat(lines, "\n") .. "\n"
end

--- Reads a report back; nil and why when it is not a whole one.
function worker.decode(text: string): worker.Report | nil, string
  if text == nil or text == "" then return nil, "no report" end
  local report: worker.Report = {
    loaded = false, passed = false, message = "", elapsed_ns = 0,
    load_reads = {}, test_reads = {}, load_hits = {}, test_hits = {}, modules = {},
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
      elseif tag == "load-read" or tag == "test-read" then
        local kind, path, answer = rest:match("^(.) ([0-9a-f]*) ([0-9a-f]*)$")
        local decoded_path = path ~= nil and unhex(path) or nil
        local decoded_answer = answer ~= nil and unhex(answer) or nil
        if decoded_path == nil or decoded_answer == nil then
          return nil, "a malformed read: " .. line
        end
        local into = tag == "load-read" and report.load_reads or report.test_reads
        into[#into + 1] = { kind = kind, path = decoded_path, answer = decoded_answer }
      elseif tag == "load-hit" or tag == "test-hit" then
        local path, numbers = rest:match("^([0-9a-f]*) ([0-9,]*)$")
        local decoded = path ~= nil and unhex(path) or nil
        if decoded == nil then return nil, "a malformed hit: " .. line end
        local into = tag == "load-hit" and report.load_hits or report.test_hits
        local per_line: {integer:boolean} = {}
        for number in numbers:gmatch("%d+") do
          per_line[math.tointeger(tonumber(number)) or 0] = true
        end
        into[decoded] = per_line
      elseif tag == "module" then
        local decoded = unhex(rest)
        if decoded == nil or decoded == "" then return nil, "a malformed module: " .. line end
        report.modules[#report.modules + 1] = decoded
      else
        return nil, "an unknown line: " .. line
      end
    end
  end
  if first then return nil, "not a test report" end
  if not finished then return nil, "the report was cut short" end
  return report, ""
end

--- Modules of the tree any test may `require` beyond its closure:
--- `cosmic.removed`, which core/surface.c requires to say what to
--- write instead of a removed global (`os.getenv`) a test reached for.
--- It is a diagnostic the core loads, which any test may reach, so
--- every key holds it among what every worker loads (`loads`) rather
--- than a test's closure: what it says is what a test that catches the
--- error sees.
local diagnostics <const>: {string:boolean} = { ["cosmic.removed"] = true }

--- Why the module `module_path`'s tests may not `require` `name`, or
--- nil when they may: `closure` is the set of module names its import
--- closure holds (`test_inputs.modules`), and `tree` the set of the
--- modules of the tree's projection. A module of the tree outside the
--- closure is refused, since the build does not follow it and a change
--- to it would leave the test's verdict standing; anything else --
--- the core's own modules, and whatever another database a test
--- attaches holds -- is no input of the tree and loads as ever.
-- TODO: hold a module the running program carries that is no module
-- of the tree -- in a project's tree, the standard library's -- once
-- a key holds the program's own modules (a digest of its `modules`
-- and `decls` beside the runtime identity, which names only the core
-- and the pins): today a release that changes only the standard
-- library's Teal leaves standing a verdict that read one of them
-- outside its closure. In this tree every module the program carries
-- is a module of the tree, and `vendor.tl`, which is not, is carried
-- by its bytecode in the store of a closure that holds build.teal, the
-- one module that loads it (`build.closure_store`'s `loaded_beside`).
local function refusal(name: string, module_path: string, closure: {string:boolean},
                        tree: {string:boolean}): string | nil
  if closure[name] or diagnostics[name] or not tree[name] then return nil end
  return string.format("module '%s' is outside the import closure of %s: the build " ..
    "follows a require only when it is called directly on a literal name, so neither a " ..
    "computed name nor pcall(require, ...) is followed, and a change to %s would not run " ..
    "%s's tests again. Require it so at the top level of the module this is raised in, " ..
    "or of %s itself: local _ = require(%q)",
    name, module_path, name, module_path, module_path, name)
end

--- A call made with the `require`s of the tree's modules held to
--- `closure`, the set of the names `module_path`'s import closure
--- holds.
local type Held = function(fn: function(any...): (any...), argument?: any): any

--- Answers a `Held`, `tree` the set of the tree's modules: it calls
--- `fn` with `argument`
--- while a searcher ahead of every other answers a module `refusal`
--- refuses with a loader that raises why, where it was required, and
--- while each such module the worker itself has loaded already is out
--- of `package.loaded`, so a `require` of it reaches the searcher too;
--- then puts both back, whether `fn` returned or raised, and returns
--- or raises as it did. A lookup that is not a `require` is the
--- store's hold's (`hold_store`).
local function hold_requires(module_path: string, closure: {string:boolean},
                             tree: {string:boolean}): Held
  -- A refusal is a loader that raises, not a searcher that does: a
  -- caller that asks every searcher by hand for the raw value one
  -- hands a wrapper (core/syscalls_test.tl's `raw_behind`) finds none
  -- beside it and asks the next, as it would of a searcher that knew
  -- nothing of the name.
  local function gate(name: string): (function(? string, ? any): (any), any)
    local why = refusal(name, module_path, closure, tree)
    if why == nil then return nil, nil end
    return function(_?: string, _?: any): any
      -- Level 3: the caller of `require`, past this loader and it.
      error(why, 3)
    end, nil
  end
  return function(fn: function(any...): (any...), argument?: any): any
    local set_aside: {string:any} = {}
    for name, value in pairs(package.loaded) do
      if refusal(name, module_path, closure, tree) ~= nil then set_aside[name] = value end
    end
    for name in pairs(set_aside) do package.loaded[name] = nil end
    local searchers = package.searchers
    table.insert(searchers, 1, gate)
    local ok, produced = pcall(fn, argument)
    for i = #searchers, 1, -1 do
      if searchers[i] == gate then table.remove(searchers, i) end
    end
    for name, value in pairs(set_aside) do package.loaded[name] = value end
    -- Level 0: the value raised, as it was raised.
    if not ok then error(produced, 0) end
    return produced
  end
end

--- The `meta` rows a held worker's `Store.meta` reads of the databases
--- the store's hold covers (`hold_store`), whatever its closure: those
--- a closure store keeps of the projection (`build.closure_store`'s
--- `closure_meta`), which its address digests, and `boot_hash`. The
--- rows the running program answers itself, from its core and the
--- database it carries -- `runtime_context`, `host`, `host_image`,
--- `runtime`, `runtime_basis` and `artifact` -- are answered ahead of
--- any hold, since the runtime identity and the launcher's hold them
--- (`build.declared_key`'s `runtime` and `launcher`), but for
--- `artifact`, the program's own path, which `Proc.executable()` answers
--- a test as well. Every other row -- `projected` and `written_by`
--- among them -- is the running tool's or the whole projection's, which
--- no key of a test without `store` holds, but for `compiler_meta` and
--- `writer_meta`, each where the closure holds what it digests.
---
--- `runtime_basis` is here for a program started with no artifact
--- descriptor alone, whose `Store.meta` reads it from the databases in
--- search order rather than from the one it carries: with one, it is
--- answered ahead of the hold. And library code a held test reaches
--- that read a row outside this set as nil -- build.reboot's
--- `unsettled`, which reads `written_by` and `writer`, or its
--- `replaced`, which reads the tool's identity rows -- now raises
--- there, loudly and naming `store = true`, rather than deciding on a
--- value no key of the test holds.
-- TODO: hold `boot_hash` too, once build.importer and build.writer tell
-- a built tool from a boot, and a tool fresh against a tree from one
-- that is not, by other means than its `boot_hash`: no key of a test
-- without `store` holds it, though it moves with every edit to the
-- tree, and it is let through only on build.declared_key's
-- `tree_wide_meta` account of why no read of it turns a verdict.
local held_meta <const>: {string} = { "boot_hash", "image_hash", "main", "runtime_basis" }

--- The `meta` rows that name the compiler's identity, which a closure
--- store does not carry: a held worker reads them only where its closure
--- holds a module that reads them, whose key holds the tool's
--- (`build.declared_key`'s `compiler_readers`).
local compiler_meta <const>: {string} = { "compiled_by", "compiler" }

--- The `meta` row that names the writer's identity (`build.work`'s
--- `Identities`), a digest of the sources of `build.writer`'s import
--- closure and of the core image, as the running tool -- fresh against
--- the tree it tests, or refusing -- carries it: a held worker reads it
--- only where its closure holds `build.writer`, whose key holds those
--- sources, and the image through its closure store's `image_hash`.
local writer_meta <const> = "writer"

--- The set of the `meta` rows a held worker whose import closure is
--- the set `closure` reads (`held_meta`, `compiler_meta`, `writer_meta`).
local function meta_keys(closure: {string:boolean}): {string:boolean}
  local keys: {string:boolean} = {}
  for _, key in ipairs(held_meta) do keys[key] = true end
  if closure["build.writer"] then keys[writer_meta] = true end
  local names: {string} = {}
  for name in pairs(closure) do names[#names + 1] = name end
  if declared_key.reads_compiler(names) then
    for _, key in ipairs(compiler_meta) do keys[key] = true end
  end
  return keys
end

--- Puts up the store's hold (core/store.c's `store_hold`) for the tests
--- of `module_path`, whose module declares neither `store`, whose key
--- holds the whole projection, nor `tool`, whose key holds the program
--- and the modules it carries; answers what takes it down. `closure`
--- is the set of the names its import closure holds, `tree` of the
--- tree's modules, and `declared` of the names only a declaration of
--- the tree answers for (`cosmic.sys`, the core's raw modules).
---
--- While it is up, a lookup in the store of a module of the tree
--- outside the closure, or of such a declaration's source, that is not
--- a `require` -- `Store.bytecode` or `Store.source`, the store's
--- searcher called by hand or taken out of `package.searchers`, those
--- of the raw table such a searcher hands a wrapper -- answers none,
--- and `Store.databases()` raises, since a handle reads every module's
--- rows. Without it such a read reaches, sandboxed, the program's own
--- database, since the store at o/cosmic.db holds the closure alone,
--- and unsandboxed the whole projection: rows no key of the test holds.
--- A declaration rides along for `Store.source` alone: `require` of a
--- name only one answers for loads the core's own C, which the
--- runtime's identity keys. Nothing takes it down: the worker puts it
--- up before the module loads and keeps it until the process has
--- ended, since what the test leaves behind -- a finalizer, which runs
--- whenever the worker allocates, and as the process closes after its
--- report -- runs past the test and can still exit or write the report
--- itself.
---
--- `Store.meta` is held too: the databases the hold covers answer only
--- the rows of `held_meta` and, where the closure holds what each
--- digests, of `compiler_meta` and `writer_meta`; a lookup of any other
--- row reaches only a database the test attached itself, keyed by what
--- it declares it reads, and raises when none answers it.
local function hold_store(module_path: string, closure: {string:boolean},
                          tree: {string:boolean}, declared: {string:boolean})
  local names: {string:boolean} = {}
  for _, set in ipairs({ tree, declared }) do
    for name in pairs(set) do
      if not closure[name] and not diagnostics[name] then names[name] = true end
    end
  end
  store.hold(names, string.format("%s's verdict is keyed by what the " ..
    "store holds of its import closure alone. Require a module at the top level of %s " ..
    "to read that module, or declare store = true in its Test.needs to read the whole " ..
    "projection, at the cost of running its tests again on every edit to the tree",
    module_path, module_path), string.format("a handle reads every module's rows, and " ..
    "%s's verdict is keyed by what the store holds of its import closure alone. " ..
    "Declare store = true in its Test.needs to read them, at the cost of running its " ..
    "tests again on every edit to the tree", module_path), meta_keys(closure),
    string.format("%s's verdict is keyed by what the store holds of its import closure " ..
    "alone and by the runtime, and neither holds that row -- nor the compiler's " ..
    "identity, unless the closure holds a module build/declared_key.tl's " ..
    "`compiler_readers` names, nor the writer's, unless it holds build.writer. " ..
    "Declare store = true in its Test.needs to read it, at the cost of running its " ..
    "tests again on every edit to the tree", module_path))
end

--- How a worker is started: this exact program again -- the same core,
--- whose runtime identity every verdict of the run is keyed under. A
--- process not started from a portable artifact starts its logical
--- executable instead. What it answers is the relaunch's own: the
--- arguments that lead its command line, the variables it adds, and
--- the descriptors it hands on.
function worker.program(): Proc.Relaunch | nil, string
  local relaunch, _ = Proc.relaunch()
  if relaunch ~= nil then
    local env: {string:string} = {}
    for name, value in pairs(relaunch.env) do env[name] = value end
    return { argv = relaunch.argv, env = env, fds = relaunch.fds }, ""
  end
  local executable, trouble = Proc.executable()
  if executable == nil then return nil, trouble end
  return { argv = { executable }, env = {}, fds = {} }, ""
end

--- The command line and the start options of the worker `given`
--- describes: `start`'s program (`program`), then `test --worker
--- <root> <module> <test> <scratch>/tmp <scratch>/children <needs>
--- <held> [--open] <closure>... --tree <tree>... --declared
--- <declared>...` (`run`), with the report captured at `report_fd`,
--- and its environment `env` with `start`'s variables added and
--- coverage collected from its first instruction (core/coverage.c,
--- COSMIC_COVERAGE_STARTUP), so its first window holds the Lua that
--- loaded before it could open. An
--- unsandboxed worker leads a process group of its own, which its end
--- ends; a sandboxed one is pid 2 of a pid namespace of its own, which
--- ends with it, ending all it started: no group to end, and no stray
--- left for the runner to adopt (`build.test`'s `run_jobs`).
function worker.invocation(given: worker.Invocation): worker.Command
  local argv: {string} = {}
  for i, value in ipairs(given.start.argv) do argv[i] = value end
  for _, value in ipairs({ "test", given.no_tool and "--worker-no-tool" or "--worker",
                           given.root, given.module_path, given.name, given.scratch .. "/tmp",
                           given.scratch .. "/children", given.needs, given.held }) do
    argv[#argv + 1] = value
  end
  if given.open then argv[#argv + 1] = "--open" end
  for _, name in ipairs(given.closure) do argv[#argv + 1] = name end
  argv[#argv + 1] = "--tree"
  for _, name in ipairs(given.tree) do argv[#argv + 1] = name end
  argv[#argv + 1] = "--declared"
  for _, name in ipairs(given.declared) do argv[#argv + 1] = name end
  local env: {string:string} = {}
  for name, value in pairs(given.env) do env[name] = value end
  for name, value in pairs(given.start.env) do env[name] = value end
  env.COSMIC_COVERAGE_STARTUP = "1"
  local fds: {integer:integer | string} = { [worker.report_fd] = "capture" }
  for number, fd in pairs(given.start.fds) do fds[number] = fd end
  return { argv = argv, options = {
    env = env, cwd = given.cwd, stdin = "null", stdout = "capture", stderr = "stdout",
    fds = fds, sandbox = given.sandbox, process_group = given.sandbox == nil,
  } }
end

--- The modules of `modules`, a worker's `Report.modules`, that it ran
--- and no key of its test holds, sorted: each of the tree the tool
--- carries (`carried`) that is neither in `loads` nor in the test's
--- import closure (`closure`). A module the tool does not carry is the core's own,
--- or Lua's, which the runtime's identity holds; one it carries that is
--- no module of the tree is the TODO above `refusal`.
local function unkeyed(modules: {string}, carried: {string:boolean},
                       closure: {string:boolean}): {string}
  local listed: {string:boolean} = {}
  for _, name in ipairs(worker.loads) do listed[name] = true end
  local out: {string} = {}
  for _, name in ipairs(modules) do
    if carried[name] and not listed[name] and not closure[name] then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

local function ending(result: Child.Result): string
  if result.signal ~= nil then return "was killed by signal " .. tostring(result.signal) end
  return "exited with status " .. tostring(result.code)
end

--- Reads a finished worker (`judging`) into its test's verdict: what it
--- reported, unless it could not be supervised, ran past its deadline,
--- or ended before it reported; a pass fails where what it started
--- outlived it, or where it ran a module no key of its test holds
--- (`unkeyed`), which would let an edit to that module leave the pass
--- standing.
function worker.judge(judging: worker.Judging): worker.Judgement
  local result = judging.result
  if result == nil and judging.refused then
    return { passed = false, message = judging.trouble }
  elseif result == nil then
    return { passed = false,
      message = "the test process could not be supervised: " .. judging.trouble }
  end
  if result.timed_out then
    return { passed = false, message = "timed out after " ..
      tostring(judging.timeout_ms // 1000) .. " s; " ..
      (judging.sandboxed and "its pid namespace" or "its process group") .. " was ended" }
  end
  local report, decode_trouble = worker.decode(result.captured[worker.report_fd])
  if report == nil then
    return { passed = false, message = "the test process " .. ending(result) ..
      " before it reported (" .. decode_trouble .. ")" }
  end
  local judgement: worker.Judgement = { report = report, passed = report.passed,
    message = report.message }
  if judgement.passed and judging.carried ~= nil and judging.closure ~= nil then
    local names = unkeyed(report.modules, judging.carried, judging.closure)
    if #names > 0 then
      judgement.passed = false
      judgement.message = "its worker ran " .. table.concat(names, ", ") .. ", which the " ..
        "tool carries and neither its module's import closure nor the modules every " ..
        "worker loads hold, so no key of its test does: require " ..
        (#names == 1 and "it" or "each") .. " at the top level of its module, or, where " ..
        "every worker loads it, name it in build/test_worker.tl's `worker.loads`"
    end
  end
  if judgement.passed and judging.trouble ~= "" then
    -- The test passed, but what it started outlived it.
    judgement.passed, judgement.message = false, judging.trouble
  end
  return judgement
end

--- Runs the one test the command line names and writes its report.
--- Exits 0 once the report is written, whatever the verdict; anything
--- else means there is no report to read.
--- Installs `runner` as `__runner` on `module`, `cosmic.test`'s table,
--- where `needs` looks for a runner: no member of its type.
local function install(module: any, runner: any)
  if module is {string:any} then module.__runner = runner end
end

--- @param argv `cosmic test --worker <root> <module> <test> <tmp> <children>
--- <needs> <held> [--open] <closure>... --tree <tree>... --declared <declared>...`,
--- `children` a directory,
--- not yet there, to
--- collect the coverage of the processes the test starts in, `needs` what
--- the build read of the module's `cosmic.test` declaration
--- (`test_inputs.canonical`), "" or absent for none: a module whose
--- `needs` call was handed anything else fails to load; `held` what this
--- worker's own sandbox holds a process it starts to, one path a line
--- (`test_sandbox.Plan`'s `held`), "" or absent where it runs
--- unsandboxed (`observations.Resolving`'s `held`); `closure` the names
--- of the module's import closure (`test_inputs.modules`), one argument
--- each, which its load and its test may `require` of the tree and
--- nothing else of it (`refusal`), absent for no such hold -- a closure
--- holds its module at least; and `tree` the names of every module of
--- the tree, one argument each, which the store a sandboxed worker is
--- given does not hold beyond its closure, and which a key need not
--- hold: a name there only turns a `require` of a module outside the
--- closure into a refusal, never into a load; and `declared` the names
--- only a declaration of the tree answers for, which the store's hold
--- holds too (`hold_store`), unless `--open` comes ahead of the closure:
--- its module declares `store` or `tool`. `--worker-no-tool` in
--- place of `--worker` holds the worker, before anything of the test
--- loads, to running anything but this very program
--- (`confine.forbid_running`): a sandboxed worker's whose module
--- does not declare `tool`, so what the program would run -- the tool's
--- own modules, which no key of the test holds -- is none of its test's.
function worker.run(argv: {integer:string}): integer
  local root, module_path, name, tmp = argv[3], argv[4], argv[5], argv[6]
  local children_path = argv[7]
  local expected_needs = argv[8] or ""
  local held_paths = argv[9] or ""
  if root == nil or module_path == nil or name == nil or tmp == nil or
      children_path == nil then
    log:complain("test --worker needs a root, a module, a test and two directories")
    return 2
  end
  if argv[2] == "--worker-no-tool" then
    local forbidden, forbid_trouble = confine.forbid_running(confine.itself())
    if not forbidden then
      log:complain("test --worker-no-tool: this program cannot be kept from running itself: " ..
        forbid_trouble)
      return 2
    end
  end
  local attached, attach_trouble = Store.attach(root .. "/o/cosmic.db")
  if not attached then
    log:complain(attach_trouble)
    return 2
  end
  -- Without a closure, a call as it is.
  local held: Held = function(fn: function(any...): (any...), argument?: any): any
    return fn(argument)
  end
  -- Once the closure is read, what puts up the store's hold.
  local hold: function() = nil
  if argv[10] ~= nil then
    local closure: {string:boolean} = {}
    local tree: {string:boolean} = {}
    local declared: {string:boolean} = {}
    local into = closure
    local open = argv[10] == "--open"
    local i = open and 11 or 10
    while argv[i] ~= nil do
      if argv[i] == "--tree" and into == closure then
        into = tree
      elseif argv[i] == "--declared" and into == tree then
        into = declared
      else
        into[argv[i]] = true
      end
      i = i + 1
    end
    held = hold_requires(module_path, closure, tree)
    if not open then
      hold = function() hold_store(module_path, closure, tree, declared) end
    end
  end
  -- The worker's own connection: no test is keyed by all of it (see
  -- `observations.exclude_held_files`; a query of it is the TODO above
  -- core/sqlite.c's `cosmic_sqlite_push_borrowed`).
  observations.exclude_held_files()
  local report: worker.Report = {
    loaded = false, passed = false, message = "", elapsed_ns = 0,
    load_reads = {}, test_reads = {},
  }
  -- Processes the test starts report the core's C they ran here, so it
  -- counts for the test like the C it runs itself.
  local made, _ = sys.mkdir(children_path, 0x1c0)
  local children = made and children_path or nil
  if children ~= nil then Coverage.children(children) end
  local load_session, _ = Coverage.start()
  -- A read outside the tree is resolved as it is read, in case it
  -- names a file of the tree through a link: the test's own directory's
  -- links included.
  local resolving: observations.Resolving = { tree = root, own = { tmp } }
  local resolved_tmp, _ = Fs.absolute(tmp)
  if resolved_tmp ~= nil then resolving.own[#resolving.own + 1] = resolved_tmp end
  -- A confined process writes its coverage beside the test's own.
  if children ~= nil then resolving.own[#resolving.own + 1] = children end
  -- Sandboxed, a process the test starts has this worker's sandbox.
  if held_paths ~= "" then
    resolving.held = {}
    for line in held_paths:gmatch("[^\n]+") do resolving.held[#resolving.held + 1] = line end
  end
  -- What the module's `needs` call is handed as it loads, through the
  -- hook `cosmic.test` leaves for a runner; once it has loaded, a call
  -- is refused.
  local handed: Test.Needs = nil
  local runner = { loaded = false, handed = function(needs: Test.Needs) handed = needs end }
  install(Test, runner)
  -- The hold on `require` is up for the module's load and its test
  -- alone, not for the worker's own work around them; the store's is
  -- up from here until the process ends (`hold_store`).
  if hold ~= nil then hold() end
  local captured = observations.capture(function(): any
    return held(function(): any return require(module_path) end)
  end, resolving)
  runner.loaded = true
  local loaded, produced, load_reads = captured.ok, captured.produced, captured.reads
  if load_session ~= nil then
    local hits, _ = Coverage.stop(load_session)
    report.load_hits = hits
  end
  report.load_reads = load_reads
  local needs = loaded and test_inputs.canonical(test_inputs.as_declared(handed)) or ""
  if loaded and needs ~= expected_needs then
    loaded = false
    produced = "its cosmic.test needs call was handed what the build did not read " ..
      "from its source -- the build reads only a top-level Test.needs { ... } " ..
      "on a local bound to require(\"cosmic.test\") (see cosmic.test):\n" ..
      "  handed:\n    " .. (needs == "" and "nothing" or needs:gsub("\n", "\n    ")) ..
      "\n  read:\n    " .. (expected_needs == "" and "nothing" or
        expected_needs:gsub("\n", "\n    "))
  end
  report.loaded = loaded
  if not loaded then
    report.message = "the module failed to load: " .. tostring(produced)
  else
    local fn: any = produced is {string: any} and produced[name] or nil
    if not (fn is function(any...): (any...)) then
      report.message = module_path .. " has no test named " .. name
    else
      local test_session, _ = Coverage.start()
      local started = Time.monotonic_ns()
      local run = observations.call(function(argument: any): any
        return held(fn, argument)
      end, tmp, resolving)
      local finished = Time.monotonic_ns()
      if test_session ~= nil then
        local hits, _ = Coverage.stop(test_session)
        report.test_hits = hits
      end
      report.passed, report.message = run.passed, run.message
      report.test_reads = run.reads
      report.elapsed_ns = finished - started
    end
  end
  if children ~= nil then
    local into = report.test_hits or report.load_hits
    child_hits(children, into or {})
  end
  -- What it ran, as `judge` holds it: taken last, so it holds what the
  -- test loaded as well as what this did.
  local modules: {string} = {}
  for loaded_name in pairs(package.loaded) do
    if loaded_name is string then modules[#modules + 1] = loaded_name end
  end
  table.sort(modules)
  report.modules = modules
  local written, trouble = Fs.put(worker.report_fd, worker.encode(report))
  if not written then
    log:complain("the test report: " .. trouble)
    return 2
  end
  return 0
end

return worker
