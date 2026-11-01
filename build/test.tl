--- Runs every test the tree defines that a stored verdict does not
--- already answer for, each in a process of its own, and records each
--- verdict into the working database, `build.db`, which never ships
--- and is never carried in the projection, `cosmic.db`.
---
--- A test runs in a worker, [`build.test_worker`]: this binary again,
--- started with the test's module, name, and temporary directory, in a
--- process group of its own, with its standard streams captured and a
--- deadline -- `--timeout SECONDS`, or `COSMIC_TEST_TIMEOUT`, 30 by
--- default -- past which the whole group is ended and the test fails.
--- Up to `--jobs N` workers run at once, one per processor by default.
--- A worker reports over a pipe what it hit and whether the test
--- passed; this process alone opens the build database and writes
--- the verdict. A test that exits, crashes, or hangs its process fails
--- by itself, and what it printed is shown only when it fails.
---
--- What makes a verdict's key, looks a verdict up under it and decides
--- what a worker is given is [`build.test_key`], which build/harness_epoch.tl
--- holds; this module is the runner around it -- the schedule, the history
--- and the coverage, the summary -- and an edit to it moves no digest of the
--- harness. The types the two share are [`build.test_state`]'s.
---
--- A verdict is keyed by what its test was given rather than by what
--- it read: the digest of its declared inputs (below), computed before
--- it runs ([`build.declared_key`]). While that key stands, a passing
--- verdict stands, and the test is not run again: the lines it hit in
--- the run that produced the verdict, loading its module included, are
--- credited to this one. Verdicts are kept by key, so an edit undone
--- finds its old verdict again. A failing verdict is never reused; the
--- test runs until it passes.
---
--- A sandboxed run's key names nothing of where the tree is, so every
--- checkout whose workers run sandboxed shares its passing verdicts too
--- ([`build.shared_verdicts`]): a test no verdict of this checkout answers
--- for stands on one another checkout of the same content reached, on
--- the terms it would on its own, and that verdict is then recorded here
--- as this run's.
---
--- A `local function test_*` at the top level of a `kind = "test"`
--- module is otherwise unreachable from outside the file it sits in:
--- [`build.importer`] appends a generated `return { test_foo = test_foo,
--- ... }` to the module's COMPILED Lua, using the same names discovery
--- already found, so `require`ing the module hands this runner every
--- test as a table entry. The Teal source a test's author wrote is
--- never touched.
---
--- A test function receives one argument: the path of a fresh,
--- writable directory made just for it, reached through a symbolic
--- link -- `<scratch>/tmp`, a link to `<scratch>/real`, in a scratch
--- directory [`Fs.mkdtemp`] made -- so that code resolving one path with
--- [`Fs.absolute`] and not another compares them wrongly on every
--- platform, as it would under macOS's `/var`, a link to `/private/var`.
--- The runner removes the scratch directory once the test passes, and
--- leaves a failing test's behind, so its own files stay around to look
--- at -- but for a worker that has it in a tmpfs of its own, which makes the
--- directory itself ([`test_sandbox.Plan`]'s `own_scratch`) and leaves none
--- on the host: `COSMIC_TEST_SANDBOX=0` keeps one. A test that ignores the argument -- the ordinary shape, a bare
--- `assert()` -- is called with it anyway, and Lua drops an argument
--- nobody asked for.
---
--- A test's inputs are its default ones -- its module's import closure,
--- as source files, the corpora of the fuzz properties it names, and a
--- pinned environment -- and what its module declares in a top-level
--- `Test.policy { ... }` ([`cosmic.test`]): paths of the tree and the host,
--- variables, the network, the tool, the projection. A sandboxed test
--- that reads what its module does not declare finds nothing there, and
--- fails with its own error.
--- Each worker runs sandboxed to them, under a policy
--- ([`build.test_policy`]) made of the paths [`build.test_sandbox`] plans,
--- with the tree at /tree and its scratch directory beneath /tmp
--- ([`test_sandbox.scratch`]), and so does every
--- process it starts: a read of anything else finds nothing.
---
--- Where no worker can be started under a policy (macOS, a host refusing
--- user namespaces or Landlock, a root that cannot map the user a policy
--- runs as), or `COSMIC_TEST_SANDBOX=0` turns it off, the run says
--- so, and why, and runs each unsandboxed; with `COSMIC_TEST_SANDBOX=1`,
--- `COSMIC_SANDBOX=must` or `COSMIC_CI_REQUIRE_SANDBOX=1` it fails
--- there instead. Such a run keys and stands as a sandboxed one does, by
--- declared inputs, and gives each worker the environment a sandbox
--- would; its worker sees the tree where it is, so its key holds that
--- path too. Nothing holds a worker to the rest of what it declares:
--- the run trusts the declaration, which a sandboxed run of the same
--- test on another host (CI's Linux legs) enforces. Its verdicts are
--- kept apart from sandboxed ones by a runtime of their own, so neither
--- stands for the other, and it shares them only through a file
--- `COSMIC_VERDICT_CACHE` names, never through the cache every
--- sandboxed checkout shares by default: it is held to nothing, so a
--- verdict it reached is another checkout's to trust only where it was
--- asked to (CI's macOS leg).
---
--- With `--check-types` (or `COSMIC_TEST_CHECK_TYPES=1`) the run compiles
--- the tree with a check of each declared parameter, return value and record
--- field write ([`importer.compile`]'s `checks`), and ends with what the workers
--- reported: the values whose kind their declared type does not admit. A
--- checked run stands on verdicts of its own kind, held apart by a part of the
--- key that names the mode ([`build.test_key`]); a test that meets any
--- violation keeps none, so it runs again and reports it again.
--- It changes a verdict only where a read's narrowing fact is false (the
--- test fails there, "fact violated"); every other check reports and fails
--- nothing, so a test passes or fails as it does without. The
--- tree's projection is left as it was, and the run's own is written beside
--- it, so no tool or executable is made of checked modules.
---
--- A test whose key holds a passing verdict, of this checkout or, by
--- that key alone, of another ([`build.shared_verdicts`]), stands; any
--- other runs, and its verdict is kept only when its inputs still digest
--- to the same key once it has run. A test that declares loopback
--- addresses, the only network it may ([`cosmic.test`]), runs offline, as
--- every sandboxed test does, and is keyed. None is assumed, and `--all`
--- (or `COSMIC_TEST_ALL=1`) runs every test the run
--- chooses, whatever stands.

local Child = require("cosmic.child")
local Signal = require("cosmic.signal")
local Cli = require("cosmic.cli")
local Clock = require("cosmic.clock")
local Coverage = require("cosmic.coverage")
local Env = require("cosmic.env")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local build_paths = require("build.paths")
local cache_lifetime = require("build.cache_lifetime")
local Poll = require("cosmic.poll")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local sys = require("cosmic.sys")
local clock = require("build.clock")
local progress = require("build.progress")
local coverage_report = require("build.coverage")
local c_functions = require("build.c_functions")
local importer = require("build.importer")
local type Module = importer.Module
local GrammarMode = require("build.grammar_mode")
local plural = require("build.plural")
local reboot = require("build.reboot")
local rebuild_lock = require("build.rebuild_lock")
local tree = require("build.tree")
local work = require("build.work")
local writer = require("build.writer")
local confine = require("build.confine")
local shared_compiles = require("build.shared_compiles")
local shared_verdicts = require("build.shared_verdicts")
local test_report = require("build.test_report")
local type_violations = require("build.type_violations")
local test_sandbox = require("build.test_sandbox")
local test_sandbox_probe = require("build.test_sandbox_probe")
local declared_key = require("build.declared_key")
local hashing = require("build.digest")
local host_names = require("build.host_names")
local host_requires = require("build.host_requires")
local worker = require("build.test_worker")
local test_key = require("build.test_key")
local type State = require("build.test_state")

local logger = require("build.logger")
local log = logger.log
local bind = require("build.bind")
local verb_spec = require("build.verb_spec")

-- A checkout's id and the census's digests are hashed through build.digest,
-- as build.declared_key's key material is.
local hex_sha256 = hashing.hex_sha256

local type Recording = State.Recording
local type Job = State.Job
local type Unmet = State.Unmet

local record test
  --- The verb's registration: see build/verb_spec.tl.
  spec: verb_spec.Spec
  --- How many tests this run ran, and how many it answered from a
  --- verdict that still stood ([`build.test_state`]'s [`Tally`]).
  type Tally = State.Tally

  --- Every test id (`"path name"`) whose standing verdict credits a
  --- given run, by that run's `run_at_ns`: what this run still owes
  --- `hits`, gathered while replaying verdicts and resolved against
  --- `coverage_by_test` in one query per run credited, after the loop.
  type Credited = {integer: {string}}

  --- One of the shares `--shard I/N` splits a run's chosen tests into
  --- ([`test.shard`], [`test.dealt`]).
  record Shard
    --- Which share, from 1.
    index: integer
    --- How many shares there are.
    count: integer
  end
end

--- The variable a test deadline's default is read from, in seconds.
local timeout_variable <const>: Env.Name = "COSMIC_TEST_TIMEOUT"
--- A test's deadline when neither the command line nor the
--- environment names one, in seconds: the slowest test in this tree
--- takes about a second, so this leaves a loaded CI host ample room
--- while still ending a hung test well inside any whole-run budget.
local default_timeout_s = 30

--- A selector without its trailing slashes and leading "./".
local function normalized(selector: string): string
  if selector == "" then return selector end
  selector = selector:gsub("/+$", "")
  while selector:sub(1, 2) == "./" do selector = selector:sub(3) end
  return selector
end

--- A selector's module part and the one test it names, if any. A
--- selector whose last `:` has something before it and a Lua name
--- after it names that test, as the runner identifies it -- `test_*`,
--- or an example's name, with or without `Example.` -- in the one
--- module the part before names by its module name or source path; any
--- other selector, `C:\dir` or `a:b/c` among them, is a path or module
--- whole.
local function split(selector: string): string, string?
  local module, name = selector:match("^(.+):Example%.([%a_][%w_]*)$")
  if module == nil then module, name = selector:match("^(.+):([%a_][%w_]*)$") end
  if module == nil then return selector, nil end
  return module, name
end

--- How many of a module's test names a refused name is shown beside.
local shown_names = 10

--- The names of `names` a mistyped `name` most likely meant, at most
--- `shown_names` of them: the longest prefix shared with it first,
--- then in order by name.
function test.nearest(name: string, names: {string}): {string}
  local function shared(other: string): integer
    local length = 0
    while length < #name and length < #other and
        name:byte(length + 1) == other:byte(length + 1) do
      length = length + 1
    end
    return length
  end
  local ranked: mut {string} = {}
  for i, other in ipairs(names) do ranked[i] = other end
  table.sort(ranked, function(a: string, b: string): boolean
    local left, right = shared(a), shared(b)
    if left ~= right then return left > right end
    return a < b
  end)
  local out: mut {string} = {}
  for i = 1, math.min(#ranked, shown_names) do out[#out + 1] = ranked[i] end
  return out
end

--- Whether one test module is named by a selector. A module name and its
--- source path match exactly; a directory matches only at a `/` boundary.
--- This keeps `test foo` from also selecting `foobar_test.tl`. A selector
--- naming one test (`split`) matches its module only exactly.
function test.matches(selector: string, path: string, file: string): boolean
  local module, name = split(selector)
  selector = normalized(module)
  if selector == path or selector == file then return true end
  if name ~= nil then return false end
  if selector == "." then return true end
  return Fs.within(file, selector)
end

--- Whether a selector chooses the test `name` of one test module: every
--- test of a module it matches, or only the one it names.
function test.selects(selector: string, path: string, file: string, name: string): boolean
  local _, named = split(selector)
  return test.matches(selector, path, file) and (named == nil or named == name)
end

--- Of the compile's refusals `lines` ([`importer.Result`]'s `refused`, each beginning with its file), those a run fails
--- for: all of them for a run that names no test, and for one that does the refusals of the files its selectors choose. A test
--- module that requires a refused module is refused itself, which a selector that names it says, so a refusal elsewhere in the
--- tree is no failure of that run.
function test.refusals_of(lines: {string}, selectors: {string}): {string}
  local out: mut {string} = {}
  for _, line in ipairs(lines) do
    local file = line:match("^([^:\n]+)") or line
    local named = #selectors == 0
    for _, selector in ipairs(selectors) do
      if test.matches(selector, "", file) then
        named = true
      end
    end
    if named then
      out[#out + 1] = line
    end
  end
  return out
end

--- The share `text`, `--shard`'s value, names: `I/N`, whole numbers with
--- 1 <= I <= N. Nil and why for anything else.
function test.shard(text: string): test.Shard?, string
  local trouble = "--shard must be I/N, whole numbers with 1 <= I <= N, not " .. text
  local i, n = text:match("^(%d+)/(%d+)$")
  if i == nil or n == nil then return nil, trouble end
  local index, count = math.tointeger(tonumber(i)), math.tointeger(tonumber(n))
  if index == nil or count == nil or index < 1 or index > count then
    return nil, trouble
  end
  return { index = index, count = count }, ""
end

--- Of `ids`, the tests a run chose, each `"<module> <name>"`, the ones
--- `shard` runs: dealt in turn, in sorted order, to shares 1 to N, so
--- the N shares of one choice run each test exactly once, a module's
--- tests are spread across them, and one share holds at most one test
--- more than another. It turns on the ids alone, never on what a run
--- recorded of their cost, which another host's run need not have read
--- alike: so every share of one tree deals the same.
function test.dealt(ids: {string}, shard: test.Shard): {string:boolean}
  local sorted: mut {string} = {}
  for i, id in ipairs(ids) do sorted[i] = id end
  table.sort(sorted)
  local out: mut {string:boolean} = {}
  for k, id in ipairs(sorted) do
    if (k - 1) % shard.count == shard.index - 1 then out[id] = true end
  end
  return out
end

local text = bind.text

--- A run's key as `runs` holds it: its key, then, when it has one,
--- its shared key after a space.
local function run_key(key: string, shared: string?): string
  if shared == nil then return key end
  return key .. " " .. shared
end

local function record_run(handle: Sqlite.Handle, path: string, name: string,
                          passed: boolean, message: string, ran_at_ns: integer,
                          key: string, run_at_ns: integer, elapsed: integer): boolean, string
  return Sqlite.run(handle,
    "INSERT OR REPLACE INTO runs (path, test, passed, message, ran_at_ns, " ..
      "key, run_at_ns, elapsed_ns) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
    { text(path), text(name), { integer = if passed then 1 else 0 end }, text(message),
      { integer = ran_at_ns }, text(key), { integer = run_at_ns }, { integer = elapsed } })
end

--- Every test that has a `runs` row, by "path name": each that ran or
--- stood here before.
local function previous_runs(handle: Sqlite.Handle): {string:boolean}?, string
  local rows, trouble = Sqlite.text_rows(handle, "SELECT path, test FROM runs")
  if rows == nil then
    return nil, trouble
  end
  local out: mut {string:boolean} = {}
  for _, row in ipairs(rows) do out[row:text(1) .. " " .. row:text(2)] = true end
  return out, ""
end

--- How many runs a verdict stays after the last one that relied on it.
local kept_runs = 10

--- How many of the newest `test_runs` a `coverage` snapshot is kept for.
local kept_snapshots = 10

--- Drops every verdict no run has relied on lately, the
--- `coverage_by_test` rows that only such verdicts credited, every
--- `coverage` snapshot older than the newest `kept_snapshots` runs,
--- and any `test_runs` row neither table references any more. A
--- standing verdict's `coverage_by_test` rows are never dropped out
--- from under it: only a verdict already gone can lose them.
function test.prune_history(handle: Sqlite.Handle, run: integer): boolean, string
  local dropped, drop_trouble = Sqlite.run(handle,
    "DELETE FROM verdicts WHERE seen < ?1", { { integer = run - kept_runs } })
  if not dropped then
    return false, drop_trouble
  end
  local pruned_credits, credits_trouble = handle:exec(
    "DELETE FROM coverage_by_test WHERE ran_at_ns NOT IN " ..
      "(SELECT run_at_ns FROM verdicts)")
  if not pruned_credits then
    return false, credits_trouble
  end
  -- By range, not `NOT IN`: the key leads with `ran_at_ns`, so this reads
  -- the rows it drops, where `NOT IN` read every kept snapshot's as well,
  -- some two million rows a run.
  local pruned_snapshots, snapshots_trouble = handle:exec(
    "DELETE FROM coverage WHERE ran_at_ns < " ..
      "(SELECT min(ran_at_ns) FROM (SELECT ran_at_ns FROM test_runs ORDER BY ran_at_ns DESC LIMIT " ..
      tostring(kept_snapshots) .. "))")
  if not pruned_snapshots then
    return false, snapshots_trouble
  end
  return handle:exec(
    "DELETE FROM test_runs WHERE ran_at_ns NOT IN (SELECT ran_at_ns FROM coverage) " ..
      "AND ran_at_ns NOT IN (SELECT ran_at_ns FROM coverage_by_test)")
end

--- One test's hits as `coverage_by_test` holds them: a line per module,
--- in path order, the path, a tab, then the lines it hit, ascending and
--- comma-separated. Module paths hold neither tabs nor newlines. A row
--- [`take_hits`] writes may name a module twice, its load's hits and its
--- test's, which [`decode_hits`] folds together.
local function encode_hits(test_hits: Coverage.Hits): string
  local paths: mut {string} = {}
  for path in pairs(test_hits) do
    paths[#paths + 1] = path
  end
  table.sort(paths)
  local out: mut {string} = {}
  for _, path in ipairs(paths) do
    local lines: mut {integer} = {}
    for line in pairs(test_hits[path]) do
      lines[#lines + 1] = line
    end
    table.sort(lines)
    out[#out + 1] = path .. "\t" .. table.concat(lines, ",") .. "\n"
  end
  return table.concat(out)
end

--- Folds every line `encoded` (as [`encode_hits`] writes it) names into
--- `hits`.
local function decode_hits(encoded: string, hits: Coverage.Hits)
  for path, lines in encoded:gmatch("([^\t\n]+)\t([^\n]*)\n") do
    local per_line = hits[path]
    if per_line == nil then
      per_line = {}
      hits[path] = per_line
    end
    for line in lines:gmatch("%d+") do
      per_line[math.tointeger(tonumber(line)) or 0] = true
    end
  end
end

--- Resolves every run `credited` names against `coverage_by_test`,
--- folding the lines its named tests hit into `hits`: only the run-wide
--- union of hit lines per module matters to [`write_coverage`], never
--- which test hit which line. One query per run credited, each naming
--- only the tests this run actually still owes it, rather than one per
--- standing verdict.
local function credit_hits(handle: Sqlite.Handle, credited: test.Credited,
                           hits: Coverage.Hits): string
  for run_at_ns, tests in pairs(credited) do
    local placeholders: mut {string} = {}
    local args: mut {Sqlite.Value} = { { integer = run_at_ns } }
    for index, id in ipairs(tests) do
      placeholders[index] = "?" .. tostring((index + 1))
      args[#args + 1] = text(id)
    end
    local rows, trouble = Sqlite.text_rows(handle,
      "SELECT hits FROM coverage_by_test WHERE ran_at_ns = ?1 " ..
        "AND test IN (" .. table.concat(placeholders, ", ") .. ")", args)
    if rows == nil then
      return trouble
    end
    for _, row in ipairs(rows) do
      decode_hits(row:text(1), hits)
    end
  end
  return ""
end

--- The keys of `set`, ascending.
local function sorted_lines(set: {integer: any}): {integer}
  local out: mut {integer} = {}
  for line in pairs(set) do
    out[#out + 1] = line
  end
  table.sort(out)
  return out
end

--- Writes `coverage`'s rows of every module `each` visits (by path and source
--- hash) for `run_at_ns` with one statement, as [`coverage_report.lines_of`]
--- answers them one module at a time: each executable line, 1 where `hits` has
--- it and else 0. The lines are those the syntax tree gives of each source
--- ([`build.coverage.syntax_lines`]), kept by its hash in the working database's
--- `executable`, which SQLite spreads into rows (`json_each`) rather than Lua
--- making and sorting a table for each of a thousand modules: some 0.45 s of
--- a run that ran one test. A module whose source the cache does not hold
--- yet is read first by `ensure`, which keeps it and answers why it could
--- not, or "". Returns the hit and executable-line counts of what it wrote,
--- and a trouble message.
local function write_module_coverage(handle: Sqlite.Handle,
                                     each: function(function(string, string): boolean, string): boolean, string,
                                     ensure: function(string): string,
                                     hits: Coverage.Hits, run_at_ns: integer): integer, integer, string
  local made, made_trouble = handle:exec(
    "CREATE TEMP TABLE IF NOT EXISTS run_modules (path TEXT PRIMARY KEY, source_hash TEXT NOT NULL) " ..
      "WITHOUT ROWID; CREATE TEMP TABLE IF NOT EXISTS run_hits (path TEXT NOT NULL, line INTEGER NOT NULL, " ..
      "PRIMARY KEY (path, line)) WITHOUT ROWID; DELETE FROM temp.run_modules; DELETE FROM temp.run_hits")
  if not made then return 0, 0, made_trouble end
  local prepared_modules, modules_trouble = handle:prepare(
    "INSERT INTO temp.run_modules (path, source_hash) VALUES (?1, ?2)")
  if prepared_modules == nil then return 0, 0, modules_trouble end
  local into_modules: Sqlite.Statement = prepared_modules
  local prepared_hits, hits_trouble = handle:prepare("INSERT OR IGNORE INTO temp.run_hits (path, line) VALUES (?1, ?2)")
  if prepared_hits == nil then
    into_modules:finalize()
    return 0, 0, hits_trouble
  end
  local into_hits: Sqlite.Statement = prepared_hits
  local filled, fill_trouble = each(function(path: string, hash: string): boolean, string
    local ok, trouble = into_modules:bind_text(1, path)
    if ok then ok, trouble = into_modules:bind_text(2, hash) end
    if ok then ok, trouble = bind.once(into_modules) end
    if not ok then return false, trouble end
    for line, hit in pairs(hits[path] or {}) do
      if hit then
        ok, trouble = into_hits:bind_text(1, path)
        if ok then ok, trouble = into_hits:bind_integer(2, line) end
        if ok then ok, trouble = bind.once(into_hits) end
        if not ok then return false, trouble end
      end
    end
    return true, ""
  end)
  into_modules:finalize()
  into_hits:finalize()
  if not filled then return 0, 0, fill_trouble end
  local missing, missing_trouble = Sqlite.text_rows(handle,
    "SELECT m.path FROM temp.run_modules m LEFT JOIN executable e ON e.source_hash = m.source_hash " ..
      "WHERE e.source_hash IS NULL ORDER BY m.path")
  if missing == nil then return 0, 0, missing_trouble end
  for _, row in ipairs(missing) do
    local trouble = ensure(row:text(1))
    if trouble ~= "" then return 0, 0, trouble end
  end
  local written, write_trouble = Sqlite.run(handle,
    "INSERT INTO coverage (ran_at_ns, path, line, hit) " ..
      "SELECT ?1, m.path, j.value, EXISTS (SELECT 1 FROM temp.run_hits h WHERE h.path = m.path AND h.line = j.value) " ..
      "FROM temp.run_modules m JOIN executable e ON e.source_hash = m.source_hash, " ..
      "json_each('[' || replace(e.lines, ' ', ',') || ']') j ORDER BY m.path, j.value",
    { { integer = run_at_ns } })
  if not written then return 0, 0, write_trouble end
  -- How many rows that wrote, and how many of them are hit: the lines
  -- `run_hits` names that a module's executable lines hold.
  local totals, totals_trouble = Sqlite.text_rows(handle,
    "SELECT changes(), (SELECT count(*) FROM temp.run_hits h JOIN temp.run_modules m ON m.path = h.path " ..
      "JOIN executable e ON e.source_hash = m.source_hash WHERE EXISTS (SELECT 1 FROM " ..
      "json_each('[' || replace(e.lines, ' ', ',') || ']') j WHERE j.value = h.line))")
  local cleaned, clean_trouble = handle:exec("DELETE FROM temp.run_modules; DELETE FROM temp.run_hits")
  if totals == nil then return 0, 0, totals_trouble end
  if not cleaned then return 0, 0, clean_trouble end
  local counted = totals[1]
  if counted == nil then return 0, 0, "the count of the rows written came back empty" end
  return math.tointeger(tonumber(counted:text(2))) or 0, math.tointeger(tonumber(counted:text(1))) or 0, ""
end

--- Every line [`build.coverage`] found for every non-vendor module
--- `modules` holds, added as a new snapshot for `run_at_ns`. Rows are
--- never replaced, only later pruned by [`prune_history`], so a file's
--- coverage trend over the kept window of runs is a plain query away
--- rather than only the latest run's numbers.
---
--- Also writes, for every test that ran, which of the lines it hit into
--- `coverage_by_test`, one row a test, tagged with the test's identity
--- ("path name", as `by_test` is keyed) and its hits as [`encode_hits`]
--- wrote them when it finished. A test whose verdict stood is not in
--- `by_test`, since its row from the run that produced the verdict
--- still stands for it.
---
--- The lines each module has to hit are those of the text the checker read ([`coverage.lines_of`]).
---
--- `native_lines` are the core's own C lines ([`Coverage.native_lines`]),
--- or none when the tree is not the one that C belongs to. Returns the
--- overall hit and executable-line counts, over every module written
--- for this run, for the run's own summary, and a trouble message.
local function write_coverage(handle: Sqlite.Handle, modules: {Module},
                              native_lines: Coverage.Hits,
                              hits: Coverage.Hits,
                              by_test: {string: string},
                              run_at_ns: integer): integer, integer, string
  local totals = { hit = 0, lines = 0 }
  local recorded, run_trouble = Sqlite.run(handle,
    "INSERT OR REPLACE INTO test_runs (ran_at_ns) VALUES (?1)",
    { { integer = run_at_ns } })
  if not recorded then
    return 0, 0, run_trouble
  end
  -- One statement a module: its lines as a JSON array, ascending, and
  -- whether each was hit as a string of 0s and 1s, which SQLite spreads into
  -- rows in a loop of its own (`json_each`) rather than Lua binding four
  -- values and stepping for each of some two hundred thousand.
  local coverage, prepare_trouble = handle:prepare(
    "INSERT INTO coverage (ran_at_ns, path, line, hit) " ..
      "SELECT ?1, ?2, j.value, CAST(substr(?4, j.key + 1, 1) AS INTEGER) FROM json_each(?3) j")
  if coverage == nil then
    return 0, 0, prepare_trouble
  end
  local per_test, test_trouble = handle:prepare(
    "INSERT INTO coverage_by_test (ran_at_ns, test, hits) VALUES (?1, ?2, ?3)")
  if per_test == nil then
    coverage:finalize()
    return 0, 0, test_trouble
  end
  -- The core's own C sits among the modules by path: a core that
  -- observes it answers every line a block begins on, and a line is hit
  -- when some window's hits name it (see [`Coverage.native_lines`]).
  local by_source: mut {string: Module} = {}
  local sorted_paths: mut {string} = {}
  for _, m in ipairs(modules) do
    by_source[m.path] = m
  end
  for path in pairs(native_lines) do
    if by_source[path] == nil then
      sorted_paths[#sorted_paths + 1] = path
    end
  end
  -- `coverage` is WITHOUT ROWID, keyed (ran_at_ns, path, line):
  -- rows written in key order append at the right edge of the B-tree
  -- instead of splitting pages at random positions, which alone is
  -- most of the cost of writing them in hash order.
  table.sort(sorted_paths)
  local test_names: mut {string} = {}
  for test_name in pairs(by_test) do
    test_names[#test_names + 1] = test_name
  end
  table.sort(test_names)
  local write_rows = function(): boolean, string
    -- The modules in one statement; the core's C one at a time below.
    local hit_lines, executable_lines, module_trouble = write_module_coverage(handle,
      function(visit: function(string, string): boolean, string): boolean, string
        for _, m in ipairs(modules) do
          local visited, visit_trouble = visit(m.path, m.source_hash)
          if not visited then return false, visit_trouble end
        end
        return true, ""
      end,
      function(path: string): string
        local m = by_source[path]
        if m == nil then return path .. ": not a module of this run" end
        local found, trouble = coverage_report.lines_of(handle, m, hits)
        if found == nil then return m.file .. ": " .. trouble end
        return ""
      end,
      hits, run_at_ns)
    if module_trouble ~= "" then return false, module_trouble end
    totals["hit"] = (totals["hit"] or 0) + hit_lines
    totals["lines"] = (totals["lines"] or 0) + executable_lines
    for _, path in ipairs(sorted_paths) do
      local hit_here = hits[path] or {}
      local per_line: coverage_report.LineHits = {}
      for line in pairs(native_lines[path]) do
        per_line[line] = hit_here[line] == true
      end
      local lines = sorted_lines(per_line)
      if #lines > 0 then
        local flags: mut {string} = {}
        for _, line in ipairs(lines) do
          if per_line[line] == true then
            flags[#flags + 1] = "1"
            totals.hit = totals.hit + 1
          else
            flags[#flags + 1] = "0"
          end
        end
        totals.lines = totals.lines + #lines
        local ok, write_trouble = coverage:bind_integer(1, run_at_ns)
        if ok then ok, write_trouble = coverage:bind_text(2, path) end
        if ok then
          ok, write_trouble = coverage:bind_text(3, "[" .. table.concat(lines, ",") .. "]")
        end
        if ok then ok, write_trouble = coverage:bind_text(4, table.concat(flags)) end
        if not ok then
          return false, write_trouble
        end
        local state, failure = coverage:step()
        if state == nil then
          return false, failure
        end
        ok, write_trouble = coverage:reset()
        if not ok then
          return false, write_trouble
        end
      end
    end
    for _, test_name in ipairs(test_names) do
      local ok, write_trouble = per_test:bind_integer(1, run_at_ns)
      if ok then
        ok, write_trouble = per_test:bind_text(2, test_name)
      end
      if ok then
        ok, write_trouble = per_test:bind_text(3, by_test[test_name])
      end
      if not ok then
        return false, write_trouble
      end
      local state, failure = per_test:step()
      if state == nil then
        return false, failure
      end
      ok, write_trouble = per_test:reset()
      if not ok then
        return false, write_trouble
      end
    end
    return true, ""
  end
  -- Keep the prepared statements from escaping when reporting a module's
  -- lines itself throws. Turn that exception into the same infrastructure
  -- error returned by an unsuccessful insert so the caller aborts the whole
  -- recording transaction.
  local called, made, trouble = pcall(write_rows)
  coverage:finalize()
  per_test:finalize()
  if not called then
    return 0, 0, tostring(made)
  end
  if not made then
    return 0, 0, trouble
  end
  return totals.hit, totals.lines, ""
end

--- Folds every line `from` holds into `into`, both keyed by module
--- import path then line number -- the shape one test's or one
--- module-load's own coverage window hands back.
local function merge_hits(into: Coverage.Hits, from: Coverage.Hits)
  for path, per_line in pairs(from) do
    local existing = into[path]
    if existing == nil then
      existing = {}
      into[path] = existing
    end
    for line in pairs(per_line) do
      existing[line] = true
    end
  end
end

--- What names this checkout among the shared rows: an id made the
--- first time its build.db is asked for one and kept in its `meta`,
--- so a checkout made again at the same path is another checkout, and
--- one whose o/ is removed is too.
local function checkout_id(records: Sqlite.Handle, root: string, now_ns: integer): string
  local rows, _ = Sqlite.text_rows(records, "SELECT value FROM meta WHERE key = 'checkout'")
  if rows ~= nil and rows[1] ~= nil then return rows[1]:text(1) end
  local made = hex_sha256(root .. "\0" .. tostring(now_ns) .. "\0" ..
      tostring(Clock.monotonic_ns()) .. "\0" .. tostring({}))
  local _, _ = Sqlite.run(records, "INSERT OR REPLACE INTO meta (key, value) VALUES ('checkout', ?1)",
    { text(made) })
  return made
end

--- Records one test answered from its standing verdict (`found`, whose
--- lookup says it stands: [`test_key.lookup`]).
local function stand(rec: Recording, credited: test.Credited, m: Module,
                     name: string, id: string, found: test_key.Lookup)
  local key, stood = assert(found.key), assert(found.own)
  rec.tally.cached = rec.tally.cached + 1
  local owed = credited[stood.run_at_ns]
  if owed == nil then
    owed = {}
    credited[stood.run_at_ns] = owed
  end
  owed[#owed + 1] = id
  local kept, keep_trouble = record_run(rec.records, m.path, name, true, "",
    Clock.now_ns(), run_key(key, rec.shared_keys[key]), stood.run_at_ns, stood.elapsed_ns)
  if not kept then
    rec.errors[#rec.errors + 1] = id .. ": record: " .. keep_trouble
  end
  kept, keep_trouble = test_key.stand_verdict(rec, found)
  if not kept then
    rec.errors[#rec.errors + 1] = id .. ": verdict: " .. keep_trouble
  end
end

--- Records one sandboxed test answered from the verdict another
--- checkout reached under its declared key (`found`, whose lookup says to
--- share it: [`test_key.lookup`]): as this run's own, with the lines that
--- run hit, so a later run of this checkout stands on it without the
--- shared cache.
local function share(rec: Recording, m: Module, name: string, id: string,
                     found: test_key.Lookup)
  local key, elsewhere = assert(found.key), assert(found.elsewhere)
  rec.tally.cached = rec.tally.cached + 1
  rec.tally.shared = rec.tally.shared + 1
  local hit: Coverage.Hits = {}
  decode_hits(elsewhere.hits, hit)
  for path in pairs(rec.unowned) do
    hit[path] = nil
  end
  merge_hits(rec.hits, hit)
  rec.by_test[id] = encode_hits(hit)
  local kept, keep_trouble = record_run(rec.records, m.path, name, true, "",
    Clock.now_ns(), run_key(key, key), rec.run_at_ns, elsewhere.elapsed_ns)
  if not kept then
    rec.errors[#rec.errors + 1] = id .. ": record: " .. keep_trouble
  end
  kept, keep_trouble = test_key.share_verdict(rec, found)
  if not kept then
    rec.errors[#rec.errors + 1] = id .. ": verdict: " .. keep_trouble
  end
end

--- A module's hit lines as a row of `coverage_by_test` holds them
--- ([`encode_hits`]'s line), kept in `spelled` by the table
--- [`worker.decode`] shares among the reports that held them.
local function spell(spelled: mut {{integer:boolean}:string}, path: string,
                     per_line: {integer:boolean}): string
  local row = spelled[per_line]
  if row == nil then
    local lines: mut {integer} = {}
    for line in pairs(per_line) do lines[#lines + 1] = line end
    table.sort(lines)
    row = path .. "\t" .. table.concat(lines, ",") .. "\n"
    spelled[per_line] = row
  end
  return row
end

--- Folds the hits of a finished worker, those its load made and those its
--- test did (the tables [`worker.decode`] shares, never changed here), into
--- `hits` but for the modules `unowned` names (the core's), and answers the
--- test's own `coverage_by_test` row, in [`encode_hits`]'s form but with
--- a module the load and the test both hit on a line of each. A worker's
--- load hits are the same lines in every worker of a module, so each is
--- folded once and spelled once, whatever the number of tests: the work
--- of one test is its own few lines. `folded` and `spelled` remember
--- which tables have been, and are one run's, since a table folded into
--- another run's `hits` is not in this one's.
function test.take_hits(hits: Coverage.Hits, unowned: Coverage.Hits,
                        folded: mut {{integer:boolean}:boolean},
                        spelled: {{integer:boolean}:string},
                        load_hits: Coverage.Hits, test_hits: Coverage.Hits): string
  local out: mut {string} = {}
  for _, taken in ipairs({ load_hits, test_hits }) do
    local paths: mut {string} = {}
    for path in pairs(taken) do
      if unowned[path] == nil then paths[#paths + 1] = path end
    end
    table.sort(paths)
    for _, path in ipairs(paths) do
      local per_line = taken[path]
      if not folded[per_line] then
        folded[per_line] = true
        local into = hits[path]
        if into == nil then
          into = {}
          hits[path] = into
        end
        for line in pairs(per_line) do into[line] = true end
      end
      out[#out + 1] = spell(spelled, path, per_line)
    end
  end
  return table.concat(out)
end

--- Folds the violations a finished worker reported into the run's, by
--- what they are and where, adding the counts of the ones met before.
local function take_violations(rec: Recording, id: string, reported: worker.Report)
  for _, met in ipairs(reported.violations or {}) do
    -- A frame a traceback names by its module's name, as the file it was
    -- read from, as a statement the compiler placed is.
    local named, line = met.at:match("^([%w_%.]+):(%d+)$")
    if named ~= nil and rec.files[named] ~= nil then met.at = rec.files[named] .. ":" .. line end
    local key = table.concat({ met.kind, met.at, met.target, met.declared, met.actual }, "\t")
    local known = rec.violations[key]
    if known ~= nil then
      known.count = known.count + met.count
    else
      rec.violations[key] = { kind = met.kind, at = met.at, target = met.target,
        declared = met.declared, actual = met.actual, count = met.count }
      rec.violation_order[#rec.violation_order + 1] = key
      rec.violation_tests[key] = id
    end
    rec.violation_met[#rec.violation_met + 1] = { key = key, test = id, count = met.count }
    rec.violators[id] = (rec.violators[id] or 0) + met.count
  end
  local unrecorded = reported.dropped or 0
  if unrecorded > 0 then rec.violators[id] = (rec.violators[id] or 0) + unrecorded end
  rec.violations_dropped = rec.violations_dropped + unrecorded
end

--- How long a test runs before its end is said on a line of its own.
local slow_ns <const> = Clock.minutes(5)
--- How many of the longest-running tests a progress line names.
local named <const> = 3

--- What a progress line adds to its count: how many tests have failed
--- (their reports come at the end of the run), and the longest-running
--- of `running`, each with how long it has run, so that a run that stops
--- moving names the tests that hold it.
local function running_detail(rec: Recording, running: {Job}): string
  local under_way: mut {progress.Running} = {}
  for i, job in ipairs(running) do
    under_way[i] = { name = job.id, started_ns = assert(job.started_ns) }
  end
  local parts: mut {string} = {}
  if #rec.failures > 0 then
    parts[1] = tostring(#rec.failures) .. " failed so far"
  end
  local longest = progress.longest(under_way, Clock.monotonic_ns(), named)
  if longest ~= "" then
    parts[#parts + 1] = "longest running: " .. longest
  end
  return table.concat(parts, "; ")
end

--- Records one finished job: the verdict its worker reported, or a
--- failure that says why there is no report to go by
--- ([`test_key.judge`], which also says whether it checked, and
--- [`test_key.keep`], which keeps its verdict).
local function finish(rec: Recording, job: Job, result: Child.Result?,
                      trouble: string, refused?: boolean, unavailable?: string)
  rec.tally.ran = rec.tally.ran + 1
  local id = job.id
  local wall_ns = Clock.monotonic_ns() - assert(job.started_ns)
  if wall_ns >= slow_ns then
    -- Said when it ends, so that a run cut short still names the tests
    -- that took the time it spent.
    local _, _ = logger.summary("test", "slow: " .. id .. " took " .. progress.elapsed(wall_ns))
  end
  local judged = test_key.judge(rec, job, result, trouble, refused, unavailable)
  local reported, passed, message = judged.report, judged.passed, judged.message
  local skipped, unchecked = judged.skipped, judged.unchecked
  if skipped ~= "" then
    rec.tally.skipped = rec.tally.skipped + 1
    rec.skips[#rec.skips + 1] = id .. ": " .. skipped
  end
  -- A pass that made no call to `assert` is listed, a held run fails it,
  -- and no run keeps a verdict of it, so it is met again every run -- a
  -- standing verdict would hide it from the summary and from a held run
  -- that did not run it.
  if unchecked then
    rec.tally.unchecked = rec.tally.unchecked + 1
    rec.unchecked[#rec.unchecked + 1] = id
  end
  local deliberate = judged.deliberate
  local printed = result and result.stdout
  if passed and printed ~= nil and printed ~= "" then
    local prefix = test_report.stopped_prefix()
    for line in printed:gmatch("[^\n]+") do
      if line:sub(1, #prefix) == prefix then
        table.insert(rec.stopped, line:sub(#prefix + 1))
      end
    end
  end
  -- A test that said why it did not check keeps its verdict: its pass is a
  -- function of its key, and it is counted apart.
  if passed and deliberate ~= "" then
    table.insert(rec.deliberate, deliberate:match("^[^\n]+") or deliberate)
  end
  -- What the records keep: a skip is no pass, nor is a pass that made no call to `assert`.
  local kept_pass = passed and skipped == "" and not unchecked
  local elapsed = wall_ns
  if reported ~= nil then
    elapsed = reported.elapsed_ns
    if rec.checks then
      take_violations(rec, id, reported)
      if rec.violators[id] ~= nil then rec.violator_ns[id] = elapsed end
    end
    rec.by_test[id] = test.take_hits(rec.hits, rec.unowned, rec.folded, rec.spelled,
      reported.load_hits, reported.test_hits)
  end
  -- Keyed by what it was given: its declared inputs, as they were
  -- before it started -- and still are, or the verdict describes no
  -- one state of them, and is not kept.
  local key = job.declared
  -- One with no key -- it reaches a network beyond loopback -- is
  -- kept under none, and runs every time. What a process it starts
  -- reads, its sandbox holds to what its key holds
  -- ([`test_sandbox.Plan`]'s `held`); unsandboxed, nothing does, and the
  -- key trusts its declaration as it trusts the test's own.
  if key == nil and job.unrun ~= true then rec.tally.every = rec.tally.every + 1 end
  local saved, save_trouble = record_run(rec.records, job.m.path, job.name, kept_pass,
    message, Clock.now_ns(), run_key(key or "", key), rec.run_at_ns, elapsed)
  if not saved then
    rec.errors[#rec.errors + 1] = id .. ": record: " .. save_trouble
  end
  test_key.keep(rec, job, judged, elapsed)
  job.passed = passed
  if not passed then
    local scratch = job.scratch
    if scratch ~= nil then
      message = message .. "\n  its directory is kept: " .. scratch .. "/real"
    elseif job.own_scratch == true then
      message = message .. "\n  its directory was a tmpfs of its worker's own, gone with it " ..
        "(" .. test_sandbox.switch .. "=0 keeps one on the host; a fuzz failure's \"kept\" path " ..
        "above is in it too: rerun with the FUZZ_CASE it names)"
    end
    local failure = id .. ": " .. message
    rec.failures[#rec.failures + 1] = failure
    rec.failed[failure] = id
    rec.reruns[id] = job.m.file .. ":" .. job.name
    local stdout = result and result.stdout
    if result ~= nil and stdout ~= nil and stdout ~= "" then
      rec.outputs[id] = stdout
    end
  end
end

--- Removes the scratch directory of each job in `jobs` whose test
--- finished and passed; a failing one's is left to look at, and one
--- still running is not finished. With `ended`, every job's goes: each
--- is a worker a cancelled run ended before its result was collected,
--- so nothing reports on it, pass or fail. A directory that cannot be
--- removed (a test left something in it it may not delete) is an error
--- of the run, naming the directory; [`Fs.remove_tree`] stops at the
--- first entry it cannot remove, so the rest of that directory stays
--- too.
local function sweep(rec: Recording, jobs: {Job}, ended?: boolean)
  for _, job in ipairs(jobs) do
    local scratch = job.scratch
    if (ended == true or job.passed == true) and scratch ~= nil then
      local gone, trouble = Fs.remove_tree(scratch)
      if not gone then
        rec.errors[#rec.errors + 1] = job.id .. ": could not remove its directory " ..
          scratch .. ": " .. trouble
      end
      job.scratch = nil
    end
  end
end

--- Starts one job's worker. False when it could not start, which is
--- recorded as that test's failure. What the worker is given is
--- [`test_key.prepare`]'s.
local function launch(rec: Recording, job: Job): boolean
  -- Set before anything can fail, since `finish` reckons the time from it.
  job.started_ns = Clock.monotonic_ns()
  local prepared = test_key.prepare(rec, job)
  local command = prepared.command
  if command == nil then
    finish(rec, job, nil, prepared.trouble, prepared.refused, prepared.unavailable)
    return false
  end
  local handle, start_trouble = Child.start(command.argv, command.options)
  if handle == nil then
    finish(rec, job, nil, start_trouble)
    return false
  end
  job.handle = handle
  return true
end

--- Runs every job, `limits.jobs` at a time, each to its verdict or its
--- deadline. A SIGINT or SIGTERM `guard` catches ends every worker
--- still running; the signal comes back as the return, for the caller
--- to be ended by it when the guard closes. Without a guard, a signal
--- acts as it would, and the return is 0.
---
--- With `bail`, a failure (any entry in `rec.failures`, one recorded
--- before the run included) stops the starting of jobs. Those already running finish with their
--- own verdicts, and the jobs never started are counted in
--- `rec.not_run` and recorded as nothing.
local function run_jobs(rec: Recording, jobs: {Job}, limits: State.Limits,
                        guard: Signal.Guard?, bail?: boolean): integer
  if #jobs == 0 then return 0 end
  local program, program_trouble = worker.program()
  if program == nil then
    rec.errors[#rec.errors + 1] = "the test runner cannot find itself: " .. program_trouble
    return 0
  end
  local running: mut {Job} = {}
  local next_job = 1
  local cancelled = 0
  -- A failure recorded before any job starts (an unmet requirement, say)
  -- stops a bailing run as one a job makes does: baseline 0.
  local failures_before = 0
  local phase = progress.phase("test", "running", "test")
  while next_job <= #jobs or #running > 0 do
    while #running < limits.jobs and next_job <= #jobs and
        not (bail == true and #rec.failures > failures_before) do
      local job = jobs[next_job]
      next_job = next_job + 1
      if launch(rec, job) then
        running[#running + 1] = job
      end
    end
    if #running == 0 then break end
    if guard ~= nil then
      cancelled = guard:cancelled()
      if cancelled ~= 0 then break end
    end
    local earliest = assert(running[1].deadline_ns)
    local handles: mut {Child.Handle} = {}
    for i, job in ipairs(running) do
      handles[i] = assert(job.handle)
      local deadline = assert(job.deadline_ns)
      if deadline < earliest then earliest = deadline end
    end
    local left_ns = earliest - Clock.monotonic_ns()
    local done, trouble = Child.wait_any(handles, math.max(0, math.min(Clock.ms(100), left_ns)))
    local still: mut {Job} = {}
    for _, job in ipairs(running) do
      local job_handle = job.handle
      local handle = assert(job_handle)
      if job_handle == done then
        -- Settled already, so this answers at once; the trouble
        -- `wait_any` gave beside the handle is the one reported.
        local result, _ = handle:wait()
        finish(rec, job, result, trouble)
      elseif done == nil and trouble ~= Poll.TIMEOUT then
        -- Supervision itself failed; end this worker and say why.
        local _, _ = handle:close()
        finish(rec, job, nil, trouble)
      elseif Clock.monotonic_ns() >= assert(job.deadline_ns) then
        -- Past its deadline: `wait(0)` ends it, and says why when the
        -- guard's signal came first. `close` makes sure it is gone.
        local result, stop_trouble = handle:wait(0)
        if result == nil then local _, _ = handle:close() end
        if result == nil and guard ~= nil and guard:cancelled() ~= 0 then
          -- The signal ended it before its timeout could: it is one of
          -- the workers the cancelled run ended, reported on by none.
          still[#still + 1] = job
        else
          finish(rec, job, result, stop_trouble)
        end
      else
        still[#still + 1] = job
      end
    end
    if #still < #running then
      -- An unsandboxed worker that is gone may have left processes of
      -- its own behind, outside the group its end reached. This process
      -- adopted them, and ends them before the next test starts and, on
      -- Linux, before what they could still write into is removed.
      -- A worker still running may have left some here too, orphaned
      -- when the process that started them ended, which its test may
      -- still be waiting on: those in the group it leads are spared,
      -- until its end ends them with its group. An orphan in a group
      -- the worker itself started is its own to adopt: starting one made
      -- it a subreaper ([`Child.start`]).
      -- A sandboxed worker leaves none: it is pid 2 of a pid namespace
      -- of its own, whose init ends when it does, ending everything
      -- left there, before `wait` answers for it. Nothing adopts them
      -- here, since no worker was started with a group.
      -- TODO: a stray still writing into a passing test's directory
      -- (or, on a cancelled run, an ended worker's, below) can race
      -- its removal: end_strays is a no-op on macOS and on
      -- Linux gives up on a stray that outlives it by a second. Remove
      -- the directory only once no stray is left, once end_strays can
      -- end or wait for strays on macOS and report the ones it gave up on.
      -- TODO: spare an orphan of a running worker that is outside its
      -- group too -- in a group a descendant started, a [`Child.start`]
      -- in a process that ended first, or a session it began (setsid)
      -- -- by the worker's session, once a worker can be started in a
      -- session of its own ([`Child.Options`] taking one); setsid's
      -- orphan would still escape.
      if not rec.sandbox then
        local groups: mut {integer} = {}
        for _, job in ipairs(still) do groups[#groups + 1] = assert(job.handle).pid end
        Child.end_strays(groups)
      end
      sweep(rec, running)
    end
    running = still
    phase.tick(next_job - 1 - #running, #jobs, function(): string
      return running_detail(rec, running)
    end)
  end
  if cancelled == 0 and next_job <= #jobs then rec.not_run = #jobs - next_job + 1 end
  for _, job in ipairs(running) do
    local closed, trouble = assert(job.handle):close()
    local scratch = job.scratch
    if not closed and scratch ~= nil then
      -- A member of its group may still be writing into it.
      rec.errors[#rec.errors + 1] = job.id .. ": its directory is kept: " ..
        scratch .. ": " .. trouble
      job.scratch = nil
    end
  end
  if not rec.sandbox then Child.end_strays() end
  -- Only a cancelled run ends here with workers running, none of them
  -- collected, so nothing reports on what is in their directories. A
  -- stray can race this removal as it can the one above (see the TODO
  -- there).
  sweep(rec, running, true)
  if guard == nil then return 0 end
  return guard:cancelled()
end

--- The run's bounds: `--timeout SECONDS` and `--jobs N` from the
--- command line's options; the deadline's default from
--- `COSMIC_TEST_TIMEOUT`. Nil and why for a value that is not a
--- positive whole number.
local function limits_of(values: {string:string}): State.Limits?, string
  local limits: State.Limits = {
    timeout_ns = Clock.seconds(default_timeout_s),
    jobs = Proc.cpu_count(),
  }
  local function positive(value: string, what: string): integer?, string
    local number = math.tointeger(tonumber(value))
    if number == nil or number < 1 then
      return nil, what .. " must be a positive whole number, not " .. value
    end
    return number, ""
  end
  -- A deadline is kept in nanoseconds and added to the clock's reading,
  -- so seconds past half what an integer holds would wrap.
  local most_seconds = (math.maxinteger // 2) // Clock.seconds(1)
  local function seconds_of(value: string, what: string): integer?, string
    local seconds, trouble = positive(value, what)
    if seconds == nil then return nil, trouble end
    if seconds > most_seconds then
      return nil, what .. " must be at most " .. tostring(most_seconds) .. " seconds, not " .. value
    end
    return seconds, ""
  end
  local from_env = Env.read(timeout_variable)
  if from_env ~= nil and from_env ~= "" then
    local seconds, trouble = seconds_of(from_env, timeout_variable)
    if seconds == nil then return nil, trouble end
    limits.timeout_ns = Clock.seconds(seconds)
  end
  if values["--timeout"] ~= nil then
    local seconds, trouble = seconds_of(values["--timeout"], "--timeout")
    if seconds == nil then return nil, trouble end
    limits.timeout_ns = Clock.seconds(seconds)
  end
  if values["--jobs"] ~= nil then
    local jobs, trouble = positive(values["--jobs"], "--jobs")
    if jobs == nil then return nil, trouble end
    limits.jobs = jobs
  end
  return limits, ""
end

--- Whether this host can run a worker sandboxed
--- ([`test_sandbox_probe.available`]), and why not where it cannot, and
--- whether that is a defect rather than a limit of the host.
local function sandbox_here(): test_sandbox_probe.Answer
  local start, start_trouble = worker.program()
  if start == nil then
    return { ok = false, why = "the test runner cannot find itself: " .. start_trouble, broken = true }
  end
  local directory, trouble = test_sandbox_probe.directory()
  if directory == nil then
    return { ok = false, why = "a directory to try it in: " .. trouble, broken = true }
  end
  local env: mut {string:string} = {}
  for name, value in pairs(test_key.worker_view()) do env[name] = value end
  for name, value in pairs(start.env) do env[name] = value end
  env.TMPDIR = test_sandbox.scratch
  local answer = test_sandbox_probe.available(start.argv, env, start.fds, directory)
  local _, _ = Fs.remove_tree(directory)
  return answer
end

--- Reporting receives copies, never the mutable state that judges a run.
local function say_skips(rec: Recording)
  local skips: mut {string} = {}
  for i, skip in ipairs(rec.skips) do skips[i] = skip end
  for _, line in ipairs(test_report.skips(skips)) do log:say(line) end
  local unchecked: mut {string} = {}
  for i, id in ipairs(rec.unchecked) do unchecked[i] = id end
  for _, line in ipairs(test_report.unchecked(unchecked)) do log:say(line) end
  local deliberate: mut {string} = {}
  for i, reason in ipairs(rec.deliberate) do deliberate[i] = reason end
  for _, line in ipairs(test_report.deliberate(deliberate)) do log:say(line) end
  local stopped: mut {string} = {}
  for i, entry in ipairs(rec.stopped) do stopped[i] = entry end
  for _, line in ipairs(test_report.stopped(stopped)) do log:say(line) end
  local nas: mut {string} = {}
  for i, na in ipairs(rec.nas) do nas[i] = na end
  for _, line in ipairs(test_report.nas(nas)) do log:say(line) end
end

local function say_failures(rec: Recording, failures: {string})
  local snapshots: mut {test_report.Failure} = {}
  for _, failure in ipairs(failures) do
    local id = rec.failed[failure]
    snapshots[#snapshots + 1] = {
      message = failure,
      rerun = id ~= nil and rec.reruns[id] or nil,
      printed = id ~= nil and rec.outputs[id] or nil,
    }
  end
  for _, line in ipairs(test_report.failures(snapshots, rec.rerun_prefix)) do
    log:say(line)
  end
end

--- What one run of the verb carries from phase to phase: each of
--- [`run`]'s phases fills the fields it owns, and reads only fields the
--- driver or an earlier phase has set.
local record Run
  run_at_ns: integer
  --- The command line, which a stale tool re-enters after rebuilding itself.
  argv: {string}

  -- The command line ([`read_command`]).
  mut root?: string
  mut limits?: State.Limits
  mut shard?: test.Shard
  mut sandbox_mode?: string
  mut selectors?: {string}
  --- The compile's refusals this run fails for ([`importer.Result`]'s `refused`): all of them, or with selectors those of the
  --- files they choose.
  mut refusals?: {string}
  mut forced?: boolean
  mut consult?: boolean
  --- Whether a verdict is also looked up under the key of another host of
  --- the same rest (COSMIC_TEST_FOREIGN_FEATURES=1).
  mut accept_foreign?: boolean
  mut census?: boolean
  --- Whether the run compiles the tree with run-time checks and reports
  --- what they find (`--check-types`).
  mut checks?: boolean
  --- Whether the run starts no job after the first failure (`--bail`).
  mut bail?: boolean

  -- The checkout ([`hold_checkout`]).
  mut started?: integer
  mut own_tree?: boolean
  mut handle?: work.Handle
  mut staged?: work.Staged

  -- The binary's identities ([`read_identities`]).
  mut tool?: string
  mut compiled_by?: string
  --- The checker the run compiles with (COSMIC_GRAMMAR), which is part of every compile's key
  --- ([`GrammarMode.tool`]) and so of every verdict's.
  mut grammar?: GrammarMode.Mode
  mut identity?: string
  mut runtime?: string
  mut harness?: test_key.Harness
  mut database?: string

  -- The sandbox ([`choose_sandbox`]).
  --- What asking whether a worker can be sandboxed came to, or nil where
  --- the run was told not to ask ([`require_of_host`] asks then, if a
  --- module needs it).
  mut sandbox_answer?: test_sandbox_probe.Answer
  --- The requirements this run's leg promises (COSMIC_TEST_PROMISES), and
  --- the leg's name (COSMIC_TEST_LEG, "" where none is given), which a held
  --- run fails a module for lacking ([`require_of_host`]).
  mut promises?: {string}
  mut leg?: string
  --- Whether the run is held to the sandbox (COSMIC_TEST_SANDBOX=1,
  --- COSMIC_SANDBOX=must or COSMIC_CI_REQUIRE_SANDBOX=1): it fails what a
  --- leg promises and a test that made no call to `assert`.
  mut held?: boolean
  mut sandboxed?: boolean
  mut sandbox_summary?: string
  mut shares?: boolean
  mut keying?: string

  -- The built tree ([`build_tree`]).
  mut result?: importer.Result

  -- The tests chosen ([`select_tests`]).
  mut selected_modules?: {Module}
  mut selected_tests?: {string:{string}}
  mut whole?: boolean
  mut share_summary?: string

  -- The records the run reads and writes ([`open_records`]).
  mut records_path?: string
  mut records?: Sqlite.Handle
  mut previous?: {string:boolean}
  mut verdicts?: {string:State.Verdict}
  mut epoch?: string
  mut credited?: test.Credited

  -- What the run tallies and reports ([`make_recording`]).
  mut tally?: State.Tally
  mut failures?: {string}
  mut errors?: {string}
  mut hits?: Coverage.Hits
  mut by_test?: {string:string}
  mut native_lines?: Coverage.Hits
  mut rec?: Recording

  -- The tests that run ([`look_up_verdicts`]).
  mut jobs?: {Job}

  -- What the run says last ([`settle`]).
  mut total?: integer
  --- The C functions' prerequisites this host lacks, probed before any
  --- worker starts. Unknown answers and missing promises retain coverage.
  mut c_unavailable?: {string: string}
  mut function_lines?: {string}
  mut cov_line?: string
end

--- The command line read: where the run is, what it is told to do and
--- which tests it is told to choose. The exit code to stop with, or nil
--- to go on.
local function read_command(ctx: Run): integer?
  local root, root_trouble = Fs.absolute(".")
  if root == nil then
    log:complain(root_trouble)
    return 1
  end
  ctx.root = root
  local parsed, parse_trouble = Flags.parse(ctx.argv, 2, assert(Cli.verbs.test.spec))
  if parsed == nil then
    log:complain("test: " .. parse_trouble)
    return 2
  end
  local limits, limits_trouble = limits_of(parsed.values)
  if limits == nil then
    log:complain("test: " .. limits_trouble)
    return 2
  end
  ctx.limits = limits
  if parsed.values["--shard"] ~= nil then
    local chosen, shard_trouble = test.shard(parsed.values["--shard"])
    if chosen == nil then
      log:complain("test: " .. shard_trouble)
      return 2
    end
    ctx.shard = chosen
  end
  local sandbox_mode, sandbox_trouble = test_sandbox.mode()
  if sandbox_mode == nil then
    log:complain("test: " .. sandbox_trouble)
    return 2
  end
  ctx.sandbox_mode = sandbox_mode
  local selectors: mut {string} = {}
  for _, word in ipairs(parsed.words) do
    local module, name = split(word)
    local selector = normalized(module)
    local absolute, _ = Fs.absolute(selector)
    if absolute == root then
      selector = "."
    elseif absolute ~= nil then
      selector = normalized(absolute)
    end
    local rest, _ = Fs.relative(selector, root)
    if rest ~= nil then
      selector = rest
    end
    if name ~= nil then selector = selector .. ":" .. name end
    selectors[#selectors + 1] = selector
  end
  ctx.selectors = selectors
  ctx.forced = parsed.set["--all"] == true or Env.read("COSMIC_TEST_ALL") == "1"
  -- A run that stands on nothing another checkout reached, though it
  -- still shares what it reaches: what answers for every test is this
  -- checkout's own evidence, or a run.
  ctx.consult = not (parsed.set["--no-shared"] == true or
    Env.read("COSMIC_TEST_NO_SHARED") == "1")
  -- Only the CI gathering run asks this (ci/cosmic_ci/orchestration.tl's
  -- `checked_suite`); it reads verdicts the shares of the same run kept.
  ctx.accept_foreign = Env.read("COSMIC_TEST_FOREIGN_FEATURES") == "1"
  ctx.census = parsed.set["--census"] == true
  -- TODO: run a checked run's three tests that compare the bytecode of a
  -- module with the binary's (build/harness_epoch_test.tl,
  -- cosmic/store_seal_test.tl, build/rebuild_lock_tool_test.tl), which skip
  -- there. A checked worker is given the checked projection (`ctx.database`
  -- below) where they read the tree's, so their bytecode is not the one they
  -- compare it with: it waits on a way for a test to read the tree's
  -- projection and the binary's own modules in a checked run.
  ctx.checks = parsed.set["--check-types"] == true or Env.read("COSMIC_TEST_CHECK_TYPES") == "1"
  ctx.bail = parsed.set["--bail"] == true or Env.read("COSMIC_TEST_BAIL") == "1"
  return nil
end

--- Removes the build directories no run has used for thirty days
--- ([`build.cache_lifetime`]), saying so when it removes any. It holds
--- this checkout's rebuild lock, and fails no run.
local function prune_trees(root: string)
  local own, _ = build_paths.directory(root)
  if own == nil then return end
  local report = cache_lifetime.prune(own)
  if #report.removed > 0 then
    log:say("test: removed " .. plural.count(#report.removed, "build directory") ..
        " unused for thirty days")
  end
  for _, line in ipairs(report.troubles) do
    log:complain("test: pruning build directories: " .. line)
  end
end

--- The checkout taken: its rebuild lock held, its working database
--- opened and staged, and a stale tool rebuilt. The exit code to stop
--- with, or nil to go on.
local function hold_checkout(ctx: Run): integer?
  local root = assert(ctx.root)
  -- One run per checkout at a time: this one holds the rebuild lock to
  -- its end, and one that finds another holding it waits for it, so
  -- two never write or sweep one another's closure stores, verdicts or
  -- projection. Taken before the working database is opened, since the
  -- holder may be waiting for that. A run a rebuild of the tool
  -- re-enters takes it again, the exec having let it go.
  local _, lock_trouble = rebuild_lock.hold(root, "test", "test")
  if lock_trouble ~= "" then
    log:complain("test: " .. lock_trouble)
    return 1
  end
  ctx.started = Clock.monotonic_ns()
  prune_trees(root)
  local standing, standing_trouble = tree.standing(root)
  if standing == nil then
    log:complain(standing_trouble)
    return 1
  end
  ctx.own_tree = standing.own
  local handle, open_trouble = work.open(root)
  if handle == nil then
    log:complain(open_trouble)
    return 1
  end
  ctx.handle = handle
  local staged, stage_trouble = work.stage(handle, standing)
  if staged == nil then
    local _, _ = work.close(handle)
    log:complain(stage_trouble)
    return 1
  end
  ctx.staged = staged

  -- A stale tool refuses, or rebuilds itself or has zig boot the core
  -- and re-enters this command line ([`reboot.guard`]).
  if standing.own then
    local code = reboot.guard(handle, root, ctx.argv)
    if code ~= nil then
      return code
    end
  end
  return nil
end

--- What the running binary is, which every verdict is keyed by: its
--- compiler, runtime, data tables and harness. The exit code to stop
--- with, or nil to go on.
local function read_identities(ctx: Run): integer?
  local handle = assert(ctx.handle)
  -- Both identities are read before the project's database is attached
  -- ahead of the binary's: they name this binary, and a project's own
  -- projection carries the ones of whichever binary wrote it.
  local names = test_key.compiler_identity(ctx.own_tree == true)
  ctx.tool, ctx.compiled_by = names.tool, names.compiled_by
  local grammar, grammar_trouble = GrammarMode.mode()
  if grammar == nil then
    local _, _ = work.close(handle)
    log:complain(grammar_trouble)
    return 1
  end
  ctx.grammar = grammar
  local runtime, runtime_trouble = test_key.runtime_of()
  if runtime == nil then
    local _, _ = work.close(handle)
    log:complain(runtime_trouble)
    return 1
  end
  ctx.identity, ctx.runtime = runtime.identity, runtime.runtime
  local harness, harness_trouble = test_key.binary_harness()
  if harness == nil then
    local _, _ = work.close(handle)
    log:complain("the running binary's test harness: " .. harness_trouble)
    return 1
  end
  ctx.harness = harness
  -- A checked run's modules carry checks, which no tool may be made of
  -- nor the tree's own projection hold: it writes its projection aside.
  ctx.database = handle.dir .. (if ctx.checks == true then "/cosmic.checked.db" else "/cosmic.db" end)
  return nil
end

--- Whether the workers are sandboxed, which the runtime the keys hold
--- says. The exit code to stop with, or nil to go on.
local function choose_sandbox(ctx: Run): integer?
  local handle = assert(ctx.handle)
  local sandbox_mode = ctx.sandbox_mode
  -- Only a held run reads the promises, which only it fails for: a
  -- project that sets COSMIC_TEST_PROMISES for another reason is no concern of a run
  -- that is not held.
  local promises: {string} = {}
  ctx.held = sandbox_mode == "on" or Env.read("COSMIC_SANDBOX") == "must" or
    Env.read("COSMIC_CI_REQUIRE_SANDBOX") == "1"
  if ctx.held == true then
    local read, promises_trouble = host_names.read_promises(Env.read("COSMIC_TEST_PROMISES") or "")
    if read == nil then
      local _, _ = work.close(handle)
      log:complain("test: COSMIC_TEST_PROMISES: " .. promises_trouble)
      return 1
    end
    promises = read
  end
  ctx.promises, ctx.leg = promises, Env.read("COSMIC_TEST_LEG") or ""
  -- Each worker runs sandboxed where the kernel can sandbox one, unless
  -- the switch turns it off. Either way each test is keyed by what it
  -- declares; unsandboxed, the run trusts that where a sandboxed run
  -- elsewhere enforces it. A verdict reached sandboxed is kept apart
  -- from one reached without, by a runtime of its own, so neither
  -- stands for the other. An unsandboxed run shares its verdicts only
  -- through a file COSMIC_VERDICT_CACHE names ([`shared_verdicts.chosen`]):
  -- no sandbox held what its tests read, so what it reached is another
  -- checkout's to stand on only where both were asked to.
  local must = Env.read("COSMIC_SANDBOX") == "must"
  local unenforced = "each test is keyed by what it declares, which nothing holds it to"
  local sandboxed, sandbox_summary = false, ""
  -- A run started, however deep, in a worker a Landlock ruleset holds
  -- can sandbox none of its own, whose roots are made of mounts: it
  -- fails, naming what lets that worker's test nest one, rather than
  -- run them unsandboxed and pass having confined nothing.
  local holder = Env.read(confine.held_variable)
  if sandbox_mode ~= "off" and holder ~= nil and holder ~= "" then
    local _, _ = work.close(handle)
    log:complain("test: this run was started in " .. holder .. "'s worker, which a " ..
        "Landlock ruleset holds, under which the kernel refuses every mount, and so every " ..
        "worker's sandbox: declare the promise \"nest\" in its Test.policy, or start the run with " ..
        test_sandbox.switch .. "=0")
    return 1
  end
  if sandbox_mode ~= "off" then
    local answer = sandbox_here()
    ctx.sandbox_answer = answer
    local why = answer.why
    sandboxed = answer.ok
    if answer.broken then
      -- Neither a limit of the host nor a sandbox: a run that went on
      -- unsandboxed would pass having confined nothing.
      local _, _ = work.close(handle)
      log:complain("test: the probe of whether workers can be sandboxed failed: " .. why)
      return 1
    end
    if sandboxed then
      -- The runtime holds whether it is held to confining what it starts
      -- ([`confine.must_confine`]), which a test's verdict turns on.
      ctx.runtime = test_key.sandboxed_runtime(assert(ctx.runtime), assert(ctx.harness).modules,
        must)
      sandbox_summary = "; sandboxed, under a policy"
      log:say("test: sandbox: each worker is held to its inputs, the tree at " ..
          test_sandbox.tree)
    else
      -- A run held to sandboxing fails where no worker can be, rather than
      -- run them without and pass having confined nothing.
      local held = if sandbox_mode == "on" then test_sandbox.switch .. "=1" elseif
        must then "COSMIC_SANDBOX=must" elseif
        Env.read("COSMIC_CI_REQUIRE_SANDBOX") == "1" then "COSMIC_CI_REQUIRE_SANDBOX=1" else nil end
      if held ~= nil then
        local _, _ = work.close(handle)
        log:complain("test: " .. held .. ", but no worker can be sandboxed here: " .. why)
        return 1
      end
      -- The head line below holds `why`; the summary points back to it.
      sandbox_summary = "; unsandboxed, as no worker can be sandboxed here (see the head line)"
      log:say("test: running unsandboxed: no worker can be sandboxed here: " .. why .. "; " ..
          unenforced .. "; " .. test_sandbox.switch .. "=0 chooses this on purpose, " ..
          test_sandbox.switch .. "=1 makes it a failure")
    end
  else
    sandbox_summary = "; unsandboxed (" .. test_sandbox.switch .. "=0)"
    log:say("test: declared: workers run unsandboxed (" .. test_sandbox.switch .. "=0); " ..
        unenforced)
  end
  local shares = sandboxed or shared_verdicts.chosen()
  if not sandboxed then
    ctx.runtime = test_key.declared_runtime(assert(ctx.runtime), must)
    sandbox_summary = sandbox_summary .. ", keyed by declared inputs" ..
      (if shares then "" else ", sharing no verdicts" end)
  end
  ctx.sandboxed, ctx.sandbox_summary, ctx.shares = sandboxed, sandbox_summary, shares
  -- What names what a run says of its keys: the sandbox's, or, with no
  -- sandbox, the declarations'.
  ctx.keying = if sandboxed then "test: sandbox: " else "test: declared: " end
  return nil
end

--- The tree compiled into the working database and its build said.
--- The exit code to stop with, or nil to go on.
local function build_tree(ctx: Run): integer?
  local handle, staged, started = assert(ctx.handle), assert(ctx.staged), assert(ctx.started)
  local result, compile_trouble = importer.compile(handle,
    GrammarMode.tool(assert(ctx.tool), assert(ctx.grammar)), false, shared_compiles.for_build(), ctx.checks)
  if result == nil then
    local _, _ = work.record(handle, clock.elapsed_ms(started), staged, 0, 0, "FAIL")
    local _, _ = work.close(handle)
    log:complain(compile_trouble)
    return 1
  end
  local written, write_trouble =
    writer.write_result(handle, assert(ctx.database), result)
  local _, _ = work.record(handle, clock.elapsed_ms(started), staged, result.compiled,
    result.cached, if written then "PASS" else "FAIL" end)
  if not written then
    local _, _ = work.close(handle)
    log:complain(write_trouble)
    return 1
  end
  ctx.result = result
  local parses = result.parses
  log:say(test_report.build({ modules = #result.modules, compiled = result.compiled,
    cached = result.cached, shared = result.shared, parsed = parses.parsed,
    shared_parses = parses.shared, files = staged.files, read = staged.read },
    clock.took(started)))
  return nil
end

--- The tests the selectors and the shard choose, each selector held to
--- matching one. The exit code to stop with, or nil to go on.
local function select_tests(ctx: Run): integer?
  local result, selectors, shard = assert(ctx.result), assert(ctx.selectors), ctx.shard
  -- Each selector must match a test module on its own: one mistyped
  -- among good ones would otherwise narrow the run without a word, and
  -- one naming a test must find it there.
  local selected_modules: mut {Module} = {}
  -- The tests each selected module runs, by its module name.
  local selected_tests: mut {string:{string}} = {}
  local matched: mut {string:boolean} = {}
  local found: mut {string:boolean} = {}
  -- The module each selector matched, for a named test it lacks.
  local module_of: mut {string:Module} = {}
  for _, m in ipairs(result.modules) do
    if (m.kind == "test" or m.kind == "example") and #m.tests > 0 then
      local chosen: mut {string} = {}
      for _, name in ipairs(m.tests) do
        local wanted = #selectors == 0
        for _, selector in ipairs(selectors) do
          if test.matches(selector, m.path, m.file) then
            matched[selector] = true
            module_of[selector] = m
          end
          if test.selects(selector, m.path, m.file, name) then
            found[selector] = true
            wanted = true
          end
        end
        if wanted then chosen[#chosen + 1] = name end
      end
      if #chosen > 0 then
        selected_modules[#selected_modules + 1] = m
        selected_tests[m.path] = chosen
      end
    end
  end
  local unmatched: mut {string} = {}
  local unfound: mut {string} = {}
  for _, selector in ipairs(selectors) do
    if matched[selector] ~= true then
      unmatched[#unmatched + 1] = selector
    elseif found[selector] ~= true then
      unfound[#unfound + 1] = selector
    end
  end
  if #unmatched > 0 or #unfound > 0 then
    local _, _ = work.close(assert(ctx.handle))
    if #unmatched > 0 then
      log:complain("no test module matches: " .. table.concat(unmatched, ", "))
      -- A module the compile refused (the new checker's) has no tests to match, which its refusal says.
      for _, line in ipairs(result.refused) do
        local head = line:match("^[^\n]*") or line
        for _, selector in ipairs(unmatched) do
          if head:find(selector, 1, true) ~= nil then
            log:complain(line)
          end
        end
      end
    end
    for _, selector in ipairs(unfound) do
      local m = assert(module_of[selector])
      local _, asked = split(selector)
      local name = assert(asked)
      local near = test.nearest(name, m.tests)
      log:complain("no test in " .. m.path .. " is named " .. name .. "; it has " ..
          table.concat(near, ", ") .. (if #m.tests > #near then ", ..." else "" end))
    end
    return 1
  end
  -- A share of the chosen tests (`--shard`), dealt over all of them
  -- ([`test.dealt`]): the other shares, run elsewhere, run the rest.
  if shard ~= nil then
    local ids: mut {string} = {}
    for _, m in ipairs(selected_modules) do
      for _, name in ipairs(selected_tests[m.path]) do ids[#ids + 1] = m.path .. " " .. name end
    end
    local dealt = test.dealt(ids, shard)
    local kept: mut {Module} = {}
    for _, m in ipairs(selected_modules) do
      local names: mut {string} = {}
      for _, name in ipairs(selected_tests[m.path]) do
        if dealt[m.path .. " " .. name] == true then names[#names + 1] = name end
      end
      if #names > 0 then
        kept[#kept + 1] = m
        selected_tests[m.path] = names
      else
        selected_tests[m.path] = nil
      end
    end
    selected_modules = kept
  end
  ctx.selected_modules, ctx.selected_tests = selected_modules, selected_tests
  -- Whether this run chose every test of the tree: what only the whole
  -- suite answers for is checked on such a run alone.
  ctx.whole = #selectors == 0 and shard == nil
  -- Said after the sandbox, last on the summary line, whichever verdict.
  ctx.share_summary = shard ~= nil and
    string.format("; shard %d of %d", shard.index, shard.count) or ""
  return nil
end

--- The verdict transaction begun and what earlier runs left in the
--- records read. The exit code to stop with, or nil to go on.
local function open_records(ctx: Run): integer?
  local handle = assert(ctx.handle)
  -- Every verdict and every coverage row of this run lands together.
  local begun, begin_trouble = work.begin(handle)
  if not begun then
    local _, _ = work.close(handle)
    log:complain(begin_trouble)
    return 1
  end
  local records_path = handle.dir .. "/build.db"
  local records = handle.db
  ctx.records_path, ctx.records = records_path, records
  local previous, previous_trouble = previous_runs(records)
  if previous == nil then
    local _, _ = work.rollback(handle)
    local _, _ = work.close(handle)
    log:complain(records_path .. ": " .. previous_trouble)
    return 1
  end
  ctx.previous = previous
  local verdicts, verdicts_trouble = test_key.known_verdicts(records)
  if verdicts == nil then
    local _, _ = work.rollback(handle)
    local _, _ = work.close(handle)
    log:complain(records_path .. ": " .. verdicts_trouble)
    return 1
  end
  ctx.verdicts = verdicts
  local epoch, epoch_trouble = test_key.epoch_of()
  if epoch == nil then
    local _, _ = work.rollback(handle)
    local _, _ = work.close(handle)
    log:complain(epoch_trouble)
    return 1
  end
  ctx.epoch = epoch
  ctx.credited = {}
  return nil
end

--- The recording every test's outcome is kept in, with the tallies and
--- coverage it reports, and the verdicts shared with other checkouts
--- opened where they are used.
local function make_recording(ctx: Run)
  local handle, records = assert(ctx.handle), assert(ctx.records)
  local limits, harness = assert(ctx.limits), assert(ctx.harness)
  ctx.tally = { ran = 0, cached = 0, shared = 0, every = 0,
    skipped = 0, unchecked = 0, na = 0 }
  local tally = assert(ctx.tally)
  local failures: {string} = {}
  local errors: {string} = {}
  ctx.failures, ctx.errors = failures, errors
  -- Every hit line of the run, and each test's own, which is what lets
  -- a later run credit a standing verdict's lines to it by name.
  local hits: Coverage.Hits = {}
  local by_test: {string: string} = {}
  ctx.hits, ctx.by_test = hits, by_test
  -- The core's C is cosmic's own: another project's run neither owns
  -- nor tests it, and counting it would make its lines most of that
  -- project's figure.
  local native_lines: Coverage.Hits = {}
  local unowned: Coverage.Hits = {}
  if ctx.own_tree == true then
    native_lines = Coverage.native_lines()
  else
    unowned = Coverage.native_lines()
  end
  ctx.native_lines = native_lines
  local sandbox_mode = ctx.sandbox_mode
  local ctx_root = ctx.root
  local rec: Recording = {
    records = records, root = assert(ctx_root),
    -- What every key holds of the harness and the runtime, which
    -- [`test_key.begin`] sets below and is the only code that does.
    runtime = "", sandbox = false, epoch = "", timeout_ns = 0, store_salt = "", carried = {},
    run_at_ns = ctx.run_at_ns, run = handle.run,
    checks = ctx.checks == true, files = {}, violations = {}, violation_order = {}, violation_tests = {},
    violations_dropped = 0, fact_wraps = assert(ctx.result).fact_wraps,
    parameter_checks = assert(ctx.result).parameter_checks, violation_met = {}, violators = {}, violator_ns = {},
    failures = failures, errors = errors, outputs = {}, reruns = {},
    failed = {}, skips = {}, unchecked = {}, deliberate = {}, stopped = {}, held = ctx.held, nas = {}, unmet = {}, answered = {},
    hits = hits, by_test = by_test, unowned = unowned, tally = tally, not_run = 0,
    owed = { kept = {}, used = {}, failed = {}, stores = {} }, shared_keys = {},
    consult_shared = ctx.consult,
    accept_foreign = ctx.accept_foreign == true and ctx.consult == true and ctx.sandboxed == true,
    origin = checkout_id(records, assert(ctx_root), ctx.run_at_ns),
    views = {}, caches = {}, unkeyed = {},
    forbiddable = {},
    closure_sets = {}, plans = {}, spelled = {}, folded = {}, type_only = {},
    closures = {}, tree_names = {}, effective = {},
    stores = {}, built = {}, store_digests = {}, store_kept = {}, store_names = {},
    store_bases = {}, store_mismatched = {}, sealed = {},
    sealed_written = 0, sealed_bytes = 0, sealed_ns = 0,
    written = 0, written_bytes = 0, writing_ns = 0,
    rerun_prefix = (if sandbox_mode == "on" then (test_sandbox.switch .. "=1 ") elseif
      sandbox_mode == "off" then (test_sandbox.switch .. "=0 ") else "" end),
  }
  ctx.rec = rec
  if ctx.checks == true then
    for _, m in ipairs(assert(ctx.result).modules) do rec.files[m.path] = m.file end
  end
  test_key.begin(rec, { runtime = assert(ctx.runtime), sandbox = ctx.sandboxed == true,
    epoch = assert(ctx.epoch), timeout_ns = limits.timeout_ns, harness = harness,
    own_tree = ctx.own_tree == true })
  -- The verdicts every checkout of the tree shares: one that stands
  -- here, run where another checkout reached it, is not run again.
  -- Without them the run goes on, and says so unless it was asked not
  -- to use them. An unsandboxed run reads and writes them only where
  -- COSMIC_VERDICT_CACHE names them (see [`choose_sandbox`]).
  local cache_path, cache_trouble: string?, string = nil, ""
  if ctx.shares == true then
    cache_path, cache_trouble = shared_verdicts.location(nil, ctx.checks == true)
  end
  if cache_path ~= nil then
    rec.shared, cache_trouble = shared_verdicts.open(cache_path)
  end
  if rec.shared == nil and cache_trouble ~= "" then
    log:complain("test: shared verdicts: " .. cache_trouble .. "; running without them")
  end
end

--- What every test's key is made of, read once before any test is
--- keyed ([`test_key.gather`]). The exit code to stop with, or nil to go
--- on.
local function gather_key_inputs(ctx: Run): integer?
  local handle = assert(ctx.handle)
  local trouble = test_key.gather(assert(ctx.rec), {
    records = assert(ctx.records), records_path = assert(ctx.records_path),
    modules = assert(ctx.result).modules, selected = assert(ctx.selected_modules),
    database = assert(ctx.database), root = assert(ctx.root), own_tree = ctx.own_tree == true,
    identity = assert(ctx.identity), tool = assert(ctx.tool),
    compiled_by = assert(ctx.compiled_by), grammar = assert(ctx.grammar),
    checks = ctx.checks == true,
  })
  if trouble ~= nil then
    local _, _ = work.rollback(handle)
    local _, _ = work.close(handle)
    log:complain(trouble)
    return 1
  end
  return nil
end

--- Asks the host, once, for every requirement the selected modules declare
--- ([`test_key.ask_host`]), before any worker starts, and then, for a
--- whole run of cosmic's own tree, for what C coverage needs of it. A held
--- run (COSMIC_TEST_SANDBOX=1, COSMIC_SANDBOX=must,
--- COSMIC_CI_REQUIRE_SANDBOX=1) holds the sandbox ([`choose_sandbox`]),
--- and fails a module for an n/a or a skip of a requirement its leg
--- promises (COSMIC_TEST_PROMISES, COSMIC_TEST_LEG).
--- The exit code to stop with, or nil to go on.
local function require_of_host(ctx: Run): integer?
  local rec = assert(ctx.rec)
  local host = test_key.ask_host(rec, assert(ctx.selected_modules), function(): host_requires.Sandbox
    local answer = ctx.sandbox_answer or sandbox_here()
    ctx.sandbox_answer = answer
    return { ok = answer.ok, why = answer.why, broken = answer.broken }
  end, ctx.held == true, ctx.promises or {}, ctx.leg or "", ctx.sandboxed == true)
  ctx.c_unavailable = {}
  if ctx.own_tree == true and ctx.whole == true and host ~= nil then
    -- The probe below runs later, when `host` may have been assigned.
    local probed = host
    local needs: mut {string: boolean} = {}
    for _, name in pairs(c_functions.prerequisites()) do needs[name] = true end
    local names: mut {string} = {}
    for name in pairs(needs) do names[#names + 1] = name end
    table.sort(names)
    local asked, trouble = pcall(function()
      local answers = host_requires.answer(probed, names)
      ctx.c_unavailable = c_functions.unavailable(answers, ctx.held and ctx.promises or nil)
      for _, answer in ipairs(answers) do
        if answer.kind == "refused" then
          rec.errors[#rec.errors + 1] = "C coverage requires " .. answer.name .. ": " .. answer.why
        elseif answer.kind ~= "present" then
          local why = "requires " .. answer.name .. ": " .. answer.why
          if ctx.held == true and host_names.promised(assert(ctx.promises), answer.name) then
            rec.failures[#rec.failures + 1] = "C coverage " .. why .. ": this held run promises it"
          end
        end
      end
    end)
    if not asked then
      local message = "C coverage prerequisite probe: " .. tostring(trouble)
      rec.errors[#rec.errors + 1] = message
    end
  end
  return nil
end

--- Settles the test `id` of a module whose requirements are not all
--- present ([`require_of_host`]) without starting a worker or keying it,
--- and keeps no verdict: a refused name fails it, an absence this host has
--- skips it, and one the platform never lacks marks it not applicable.
local function settle_unmet(rec: Recording, m: Module, name: string, id: string,
                            unmet: Unmet)
  if unmet.kind == "na" then
    rec.tally.na = rec.tally.na + 1
    rec.nas[#rec.nas + 1] = id .. ": " .. unmet.why
    local saved, trouble = record_run(rec.records, m.path, name, false, "n/a: " .. unmet.why,
      Clock.now_ns(), "", rec.run_at_ns, 0)
    if not saved then rec.errors[#rec.errors + 1] = id .. ": record: " .. trouble end
    return
  end
  local job: Job = { m = m, name = name, id = id, unrun = true, started_ns = Clock.monotonic_ns() }
  if unmet.kind == "skipped" then
    finish(rec, job, nil, "", false, unmet.why)
  else
    finish(rec, job, nil, unmet.why)
  end
end

--- Each selected test keyed and looked up: a test whose verdict stands,
--- here or in another checkout, is credited or shared, and the rest
--- become the run's jobs. What the keys are made of and how many were
--- looked up is said.
local function look_up_verdicts(ctx: Run)
  local rec, selected_modules = assert(ctx.rec), assert(ctx.selected_modules)
  local selected_tests = assert(ctx.selected_tests)
  local verdicts, forced, consult, keying = assert(ctx.verdicts), ctx.forced, ctx.consult, assert(ctx.keying)
  local previous, credited, sandboxed = assert(ctx.previous), assert(ctx.credited), ctx.sandboxed
  local jobs: mut {Job} = {}
  ctx.jobs = jobs
  -- The tests looked up in the shared cache, and whether any was found:
  -- where none was, `unmatched` says why.
  local looked: mut {string:boolean} = {}
  local keyed_count, looked_count, found_count, ran_here = 0, 0, 0, 0
  for _, m in ipairs(selected_modules) do
    local unmet = rec.unmet[m.path]
    for _, name in ipairs(selected_tests[m.path]) do
      local id = m.path .. " " .. name
      if unmet ~= nil then
        settle_unmet(rec, m, name, id, unmet)
      else
        -- Keyed, and looked up under its key ([`test_key.lookup`]): it
        -- runs, stands on this checkout's verdict, or on another's.
        local found = test_key.lookup(rec, m, id, verdicts, forced, consult)
        local key = found.key
        if key ~= nil then keyed_count = keyed_count + 1 end
        if found.asked then
          looked[id], looked_count = true, looked_count + 1
          if previous[id] == true then ran_here = ran_here + 1 end
          if found.elsewhere ~= nil then found_count = found_count + 1 end
        end
        if found.outcome == "run" then
          table.insert(jobs, test_key.job_of(found, m, name, id))
        elseif found.outcome == "stand" then
          rec.shared_keys[assert(key)] = key
          stand(rec, credited, m, name, id, found)
        else
          share(rec, m, name, id, found)
        end
      end
    end
  end
  -- The digests the run's keys hold, which each row it keeps in the
  -- shared cache is stamped with ([`shared_verdicts.settle`]): made only
  -- where there is a cache to stamp or a census to say, since
  -- `host_features` reads the processor's whole description.
  local census_asked = ctx.census
  local parts: mut {{string}} = {}
  if rec.shared ~= nil or census_asked == true then
    parts = {
      -- As ci/cosmic_ci/host_id.tl names CI's verdict cache.
      { "host features", declared_key.host_features() },
      { "host", assert(rec.host):sub(1, 12) },
      { "system", (rec.system or ""):sub(1, 12) },
      { "runtime", hex_sha256(rec.runtime or ""):sub(1, 12) },
      { "compiler", (rec.compiler or ""):sub(1, 12) },
      -- The key's harness parts, its epoch and timeout, as one word.
      { "harness", test_key.harness_word(rec.epoch, rec.timeout_ns) },
    }
    local launcher = rec.launcher
    if launcher ~= nil then table.insert(parts, { "launcher", launcher:sub(1, 12) }) end
    -- What every closure store holds alike, by its bytes, which the key
    -- of every test whose module does not declare `store` holds within
    -- its store's digest: named so a run whose stores all moved says
    -- so rather than leaving it to the parts beside it.
    if rec.base_store ~= nil then
      table.insert(parts, { "store", test_key.base_store_digest(rec):sub(1, 12) })
    end
    if sandboxed ~= true then
      table.insert(parts, { "tree", hex_sha256(assert(ctx.root)):sub(1, 12) })
    end
    local runs_tool = false
    for _, m in ipairs(selected_modules) do
      if rec.effective[m.path] ~= nil and rec.effective[m.path].tool then runs_tool = true end
    end
    if runs_tool then
      table.insert(parts, { "program", test_key.program_of(rec):sub(1, 12) })
    end
    -- Last, so the parts above keep their places: the identity itself,
    -- which a gathering run keys other hosts' verdicts by
    -- ([`shared_verdicts.hosts_like`]), and the rest of it that is no
    -- feature.
    table.insert(parts, { "host identity", assert(rec.host) })
    table.insert(parts, { "host rest", assert(rec.host_rest) })
    rec.owed.parts = shared_verdicts.named(parts)
  end
  -- In a fresh checkout (as CI's is), where every keyed test was looked
  -- up in the shared cache, none ever ran or stood here, and none was
  -- found though the cache holds rows, say what every key holds, so two
  -- runs' lines say which part moved. An edit in a checkout says
  -- nothing: what it moved ran here before.
  -- Under `--census` (as CI's checked suite is, in a checkout the local
  -- suite already ran in), say it wherever none was found, and say the
  -- parts alone wherever the line would not be said. Then say the key
  -- parts the cache's rows name, as this run found them, so a report
  -- tells whether its own were among what CI restored
  -- (ci/cosmic_ci/report.tl's `qualify`).
  local shared = rec.shared
  if census_asked == true or (shared ~= nil and looked_count > 0 and
      looked_count == keyed_count and ran_here == 0 and found_count == 0) then
    local line: string? = nil
    if shared ~= nil and found_count == 0 then
      local census, _ = shared_verdicts.census(shared, looked)
      line = census ~= nil and shared_verdicts.unmatched(shared.path, looked_count,
        census, parts) or nil
    end
    if line == nil and census_asked == true then line = shared_verdicts.key_parts(parts) end
    if line ~= nil then log:say(line) end
    local rec_shared = rec.shared
    if census_asked == true and rec_shared ~= nil then
      local held, _ = shared_verdicts.held(rec_shared)
      if held ~= nil then log:say(shared_verdicts.census_line(held)) end
    end
  end
  test_key.close_keying(rec)
  local tests = 0
  for _, m in ipairs(selected_modules) do
    if rec.unmet[m.path] == nil then tests = tests + #selected_tests[m.path] end
  end
  -- Workers that would run on a sealed database but run the whole
  -- program, as this one is no portable artifact to take its database from.
  local unsealed = 0
  for _, m in ipairs(selected_modules) do
    local effective = rec.effective[m.path]
    if rec.unmet[m.path] == nil and rec.stores[m.path] ~= nil and effective ~= nil and
        not (effective.store or effective.tool) and not test_key.seals(rec, m) then
      unsealed = unsealed + #selected_tests[m.path]
    end
  end
  if unsealed > 0 then
    log:say(keying .. plural.count(unsealed, "test") .. " run the whole program, not a sealed " ..
        "database of their closure: this program is no portable artifact")
  end
  log:say(string.format(keying .. "%s keyed by their declared inputs in %.1f ms (%s read)",
    plural.count(tests, "test"), test_key.digests_of(rec).spent_ns / 1e6,
    plural.count(test_key.digests_of(rec).read, "file")))
  local unkeyed: mut {string} = {}
  for path in pairs(rec.unkeyed) do unkeyed[#unkeyed + 1] = path end
  table.sort(unkeyed)
  for _, path in ipairs(unkeyed) do
    log:say(keying .. path .. " has no key, so its tests run every time: " ..
        rec.unkeyed[path])
  end
end

--- What takes out the directory of a run's sealed databases when the scope
--- it is closed in ends, an error escaping it included ([`execute`]).
local record Removal
  rec: Recording
  __close: function(Removal)
end

local removal_mt: metatable<Removal> = {
  __close = function(removal: Removal) test_key.drop_sealing(removal.rec) end,
}

--- An incomplete run contributes no passes or coverage, but its completed
--- failures disprove old passes. Keep only those tombstones after rolling
--- back the run, and remove only their keys from the shared cache.
local function cancel_records(ctx: Run)
  local rec, handle = assert(ctx.rec), assert(ctx.handle)
  local ok, trouble = work.rollback(handle)
  if ok and #rec.owed.failed > 0 then
    ok, trouble = work.begin(handle)
    if ok then
      for _, key in ipairs(rec.owed.failed) do
        ok, trouble = test_key.record_verdict(rec.records, key, false, rec.run_at_ns, rec.run, 0)
        if not ok then break end
      end
    end
  end
  if ok then
    ok, trouble = work.close(handle)
  else
    local _, _ = work.abort(handle)
  end
  if not ok then rec.errors[#rec.errors + 1] = "cancelled verdicts: " .. trouble end
  local shared = rec.shared
  if shared ~= nil then
    local invalidations: shared_verdicts.Owed = { kept = {}, used = {}, failed = rec.owed.failed }
    local settled, settle_trouble = shared_verdicts.settle(shared, rec.origin,
      invalidations, Clock.now_ns())
    shared_verdicts.close(shared)
    if not settled then
      rec.errors[#rec.errors + 1] = "cancelled shared verdicts: " .. shared.path .. ": " .. settle_trouble
    end
  end
end

--- The jobs run. The exit code to stop with, or nil to go on: 130 once
--- a signal has cancelled the run.
local function execute(ctx: Run): integer?
  local rec, jobs = assert(ctx.rec), assert(ctx.jobs)
  if #jobs > 0 then
    -- Nil only where the guard cannot be had (no descriptor left for
    -- its pipe): the run then goes unguarded, a signal acting as it
    -- would.
    -- Whatever ends the run, an error escaping it included, takes out
    -- the directory of its sealed databases.
    local _removing <close>: Removal = setmetatable({ rec = rec }, removal_mt)
    local opened, _ = Signal.guard()
    if opened == nil then
      run_jobs(rec, jobs, assert(ctx.limits), nil, ctx.bail)
    else
      -- A signal the guard caught ends this process when it closes,
      -- once the run is aborted; under a guard of its caller's (test's
      -- `run` called in-process), it is left to that one.
      local guard <close> = opened
      if run_jobs(rec, jobs, assert(ctx.limits), guard, ctx.bail) ~= 0 then
        cancel_records(ctx)
        -- A test that failed before the signal keeps its directory,
        -- named as a finished run's report names it: the failures on
        -- stdout, as there, and the errors and the cancellation on stderr.
        say_failures(rec, assert(ctx.failures))
        for _, line in ipairs(assert(ctx.errors)) do log:complain("test: ERROR  " .. line) end
        log:complain("test: cancelled; every running test was ended")
        return 130
      end
    end
  end
  return nil
end

--- Keeps what a checked run's workers reported in the working database's
--- `type_violations`, one row to a distinct violation, replacing the last
--- checked run's: the table holds the latest report, which
--- `cosmic sql --build` reads.
local function keep_violations(records: Sqlite.Handle, rec: Recording,
                               run_at_ns: integer): boolean, string
  local cleared, clear_trouble = records:exec("DELETE FROM type_violations")
  if not cleared then return false, clear_trouble end
  for _, key in ipairs(rec.violation_order) do
    local met = rec.violations[key]
    local saved, save_trouble = Sqlite.run(records,
      "INSERT INTO type_violations (ran_at_ns, kind, site, target, declared, actual, " ..
        "count, test) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
      { { integer = run_at_ns }, text(met.kind), text(met.at), text(met.target),
        text(met.declared), text(met.actual), { integer = met.count },
        text(rec.violation_tests[key]) })
    if not saved then return false, save_trouble end
  end
  local cleared_tests, clear_tests_trouble = records:exec("DELETE FROM type_violation_tests")
  if not cleared_tests then return false, clear_tests_trouble end
  for _, met in ipairs(rec.violation_met) do
    local row = assert(rec.violations[met.key])
    local saved, save_trouble = Sqlite.run(records,
      "INSERT OR REPLACE INTO type_violation_tests (test, kind, site, target, declared, actual, count) " ..
        "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
      { text(met.test), text(row.kind), text(row.at), text(row.target), text(row.declared),
        text(row.actual), { integer = met.count } })
    if not saved then return false, save_trouble end
  end
  return true, ""
end

--- The violations a checked run met, as [`type_violations`] reads them.
local function library_violation(rec: Recording): string
  local rows: mut {type_violations.Row} = {}
  for _, key in ipairs(rec.violation_order) do
    local met = assert(rec.violations[key])
    rows[#rows + 1] = { kind = met.kind, at = met.at, target = met.target, declared = met.declared,
      actual = met.actual, test = assert(rec.violation_tests[key]) }
  end
  return type_violations.library(rows)
end

--- The most violations a checked run lists beneath its summary.
local SAMPLE_VIOLATIONS <const> = 10

--- A checked run's report of the values that crossed a typed boundary as a
--- kind its declared type does not admit: how many, at how many distinct
--- places and boundaries, and the commonest. A parameter declared under
--- "cosmic/" fails the test that met it when the hook meets it
--- ([`build.test_worker`]); this reports it, and every other row, and
--- changes no verdict itself.
local function say_violations(rec: Recording)
  if not rec.checks then return end
  local total, places = 0, 0
  local seen: mut {string:boolean} = {}
  for _, key in ipairs(rec.violation_order) do
    local met = rec.violations[key]
    total = total + met.count
    if seen[met.at] ~= true then
      seen[met.at] = true
      places = places + 1
    end
  end
  local distinct = #rec.violation_order
  log:say(string.format("test: run-time types: %s, %d distinct, at %s (a parameter declared under cosmic/ " ..
      "fails the test that meets it; the rest are reported only)%s; all of them: cosmic sql --build 'SELECT * FROM " ..
      "type_violations'",
    plural.count(total, "violation"), distinct, plural.count(places, "place"),
    rec.violations_dropped > 0 and string.format("; %s more went unrecorded",
      plural.count(rec.violations_dropped, "kind")) or ""))
  log:say(string.format("test: run-time types: %s and %s written in the compile; %s stood on checked verdicts",
    plural.count(rec.fact_wraps, "fact wrap"), plural.count(rec.parameter_checks, "parameter check"),
    plural.count(rec.tally.cached, "test")))
  local tests, seconds = 0, 0
  for id, _ in pairs(rec.violators) do
    tests = tests + 1
    seconds = seconds + (rec.violator_ns[id] or 0)
  end
  if tests > 0 then
    log:say(string.format("test: run-time types: %s met one (%.1f s), which never stand on a checked verdict; " ..
        "cosmic sql --build 'SELECT * FROM type_violation_tests'", plural.count(tests, "test"), seconds / 1e9))
  end
  local order: mut {string} = {}
  for i, key in ipairs(rec.violation_order) do order[i] = key end
  table.sort(order, function(a: string, b: string): boolean
    local ca, cb = rec.violations[a].count, rec.violations[b].count
    if ca ~= cb then return ca > cb end
    return a < b
  end)
  for i = 1, math.min(SAMPLE_VIOLATIONS, #order) do
    local met = rec.violations[order[i]]
    log:say(string.format("test:   %s: %s declared %s got %s (%s)", met.at, met.target,
      met.declared, met.actual, plural.count(met.count, "time")))
  end
end

--- What the finished tests leave: their coverage and the history and
--- digests kept, the working database closed and the shared cache
--- settled. Everything it meets goes in `errors`, never an exit.
local function settle(ctx: Run)
  local rec, records, tally = assert(ctx.rec), assert(ctx.records), assert(ctx.tally)
  local failures, errors = assert(ctx.failures), assert(ctx.errors)
  local hits, handle = assert(ctx.hits), assert(ctx.handle)
  local result = assert(ctx.result)
  if rec.written > 0 then
    log:say(string.format("%s%s written (%s) in %.1f ms", ctx.keying,
      plural.count(rec.written, "closure store"), plural.count(rec.written_bytes, "byte"),
      rec.writing_ns / 1e6))
  end
  if rec.sealed_written > 0 then
    log:say(string.format("%s%s written (%s) in %.1f ms", ctx.keying,
      plural.count(rec.sealed_written, "sealed database"), plural.count(rec.sealed_bytes, "byte"),
      rec.sealed_ns / 1e6))
  end
  ctx.total = tally.ran + tally.cached + tally.na

  local credit_trouble = credit_hits(records, assert(ctx.credited), hits)
  if credit_trouble ~= "" then
    errors[#errors + 1] = "coverage credit: " .. credit_trouble
  end

  -- Every C function must be one some test enters, in this run or in
  -- the run whose verdict stands for it: a standing verdict's hits are
  -- among those credited to it just above. Only a whole run of cosmic's
  -- own tree answers that: a run of chosen tests says nothing about the
  -- rest, and another project's tests owe nothing to the C underneath
  -- them. Every core cosmic tests with observes its own C.
  local function_lines: mut {string} = {}
  ctx.function_lines = function_lines
  local functions = Coverage.native_functions()
  if ctx.own_tree == true and rec.not_run > 0 then
    -- The tests not started are the ones that would have entered some.
    function_lines[1] = string.format("test: C functions not checked: %s not run " ..
        "after the first failure", plural.count(rec.not_run, "test"))
  elseif ctx.own_tree == true and ctx.whole == true and #functions > 0 then
    -- A host whose name cannot be had is held to every function.
    local names, uname_trouble = sys.uname()
    if names == nil then errors[#errors + 1] = "uname: " .. uname_trouble end
    local entered = c_functions.tally(functions, hits, c_functions.sources(assert(ctx.root), functions),
      names ~= nil and names.sysname or nil, ctx.c_unavailable)
    for _, key in ipairs(entered.unentered) do
      failures[#failures + 1] = key .. ": a C function no test enters"
    end
    function_lines[1] = string.format("test: C functions %d/%d entered by a test (%d exempt, %d unavailable)",
      entered.entered, entered.total - entered.exempted - #entered.unavailable,
      entered.exempted, #entered.unavailable)
    for _, why in ipairs(entered.unavailable) do
      function_lines[#function_lines + 1] = "test: C function SKIP " .. why
    end
    -- An exemption a test entered is one this core no longer needs. The
    -- other core may still need it, so it is named here, never failed.
    if #entered.stale > 0 then
      table.insert(function_lines, "test: C exemptions a test entered on this core: " ..
          table.concat(entered.stale, ", "))
    end
  elseif ctx.own_tree == true and #assert(ctx.selectors) == 0 and #functions > 0 then
    -- A share's tests enter only some of them; a whole run, which CI's
    -- merge queue makes on every leg, holds the core to all of them.
    function_lines[1] = string.format("test: C functions not checked: shard %d of %d " ..
        "runs part of the suite, and only a whole run enters every one",
      assert(ctx.shard).index, assert(ctx.shard).count)
  end

  local cov_hit, cov_total, cov_trouble =
    write_coverage(records, result.modules, assert(ctx.native_lines), hits,
      assert(ctx.by_test), ctx.run_at_ns)
  if cov_trouble ~= "" then
    errors[#errors + 1] = "coverage: " .. cov_trouble
  end
  if rec.checks then
    local kept, keep_trouble = keep_violations(records, rec, ctx.run_at_ns)
    -- The hook raises at the first violation of a parameter of cosmic/, which a `pcall` in the code under test can
    -- swallow: the run fails all the same.
    local violated = library_violation(rec)
    if not kept or violated ~= "" then
      errors[#errors + 1] = if not kept then "type violations: " .. keep_trouble else violated end
    end
  end
  local pruned, prune_trouble = test.prune_history(records, handle.run)
  if not pruned then
    errors[#errors + 1] = "prune: " .. prune_trouble
  end
  -- What a sandboxed run hashed, for the next to look up by `lstat`.
  local kept_digests, digests_trouble = test_key.persist_digests(records, rec, ctx.whole)
  if not kept_digests then errors[#errors + 1] = "digests: " .. digests_trouble end
  local finished: boolean
  local finish_trouble: string
  if #errors == 0 then
    finished, finish_trouble = work.close(handle)
  else
    finished, finish_trouble = work.abort(handle)
  end
  if not finished then
    errors[#errors + 1] = "close: " .. finish_trouble
  end
  -- What this run reached is the shared cache's too, whether or not
  -- this checkout's own records took it: a passing verdict is one
  -- whatever went wrong with keeping it here.
  local shared = rec.shared
  if shared ~= nil then
    local settled, settle_trouble = shared_verdicts.settle(shared, rec.origin, rec.owed,
      Clock.now_ns())
    shared_verdicts.close(shared)
    if not settled then
      log:complain("test: shared verdicts: " .. shared.path .. ": " .. settle_trouble)
    end
  end

  -- A module [`importer.compile`] refused ran no tests at all; every
  -- other module still compiled and ran above, so this only turns the
  -- overall verdict to FAIL, one line per refusal, rather than aborting
  -- the whole run the way an unrelated compile error still does.
  local refusals = test.refusals_of(result.refused, assert(ctx.selectors))
  for _, line in ipairs(refusals) do
    failures[#failures + 1] = line
  end
  ctx.refusals = refusals

  ctx.cov_line = test_report.coverage(cov_hit, cov_total)
end

--- The run's summary said, last on stdout, with the skips, failures and
--- errors that bear on it, and its exit code: 0 when every test passed.
local function report(ctx: Run): integer
  local rec, tally = assert(ctx.rec), assert(ctx.tally)
  local failures, errors = assert(ctx.failures), assert(ctx.errors)
  local total, started = assert(ctx.total), assert(ctx.started)
  if #failures == 0 and #errors == 0 then
    if total == 0 then
      log:say("test: nothing to run: a test is a top-level `local function " ..
          "test_*` of a *_test.tl file, or a function of the `Example` " ..
          "record a *_example.tl file returns")
    end
    say_skips(rec)
    say_violations(rec)
    log:say(assert(ctx.cov_line))
    for _, function_line in ipairs(assert(ctx.function_lines)) do log:say(function_line) end
    local _, _ = log:say("test: " .. test_report.passed({ total = total,
      modules = #assert(ctx.selected_modules),
      ran = tally.ran, cached = tally.cached, skipped = tally.skipped, unchecked = tally.unchecked, na = tally.na,
      every = tally.every, shared = tally.shared },
      clock.took(started) .. assert(ctx.sandbox_summary) .. assert(ctx.share_summary)))
    return 0
  end
  say_skips(rec)
  say_violations(rec)
  say_failures(rec, failures)
  for _, line in ipairs(errors) do
    log:say("test: ERROR  " .. assert(ctx.records_path) .. ": " .. line)
  end
  if #errors == 0 then
    log:say(assert(ctx.cov_line))
    for _, function_line in ipairs(assert(ctx.function_lines)) do log:say(function_line) end
  end
  local _, _ = log:say("test: " .. test_report.failed(#failures, total + #assert(ctx.refusals),
    #errors, clock.took(started) .. assert(ctx.sandbox_summary) .. assert(ctx.share_summary), rec.not_run))
  return 1
end

--- Builds the tree in the working directory and runs every test it
--- discovered that its selectors choose ([`test.selects`]), printing its
--- summary and returning the exit code: 0
--- when every test passed. Each phase above does one part, in order,
--- and the first to answer an exit code ends the run.
--- @param argv the command line, which a stale tool re-enters after
---   rebuilding itself
local function run(argv: {string}): integer
  -- Captured once, up front, and threaded through everything below as
  -- this run's own identifier: see build/work.tl for why a nanosecond
  -- timestamp, not an autoincrement id, identifies a run.
  local ctx: Run = { run_at_ns = Clock.now_ns(), argv = argv }
  local code = read_command(ctx)
  if code ~= nil then return code end
  code = hold_checkout(ctx)
  if code ~= nil then return code end
  code = read_identities(ctx)
  if code ~= nil then return code end
  code = choose_sandbox(ctx)
  if code ~= nil then return code end
  code = build_tree(ctx)
  if code ~= nil then return code end
  code = select_tests(ctx)
  if code ~= nil then return code end
  code = open_records(ctx)
  if code ~= nil then return code end
  make_recording(ctx)
  code = require_of_host(ctx)
  if code ~= nil then return code end
  code = gather_key_inputs(ctx)
  if code ~= nil then return code end
  look_up_verdicts(ctx)
  code = execute(ctx)
  if code ~= nil then return code end
  settle(ctx)
  return report(ctx)
end

--- The `test` verb as [`build/verb_list.tl`] lists it.
test.spec = {
  name = "test",
  guide = "none: the verb is for the tree's own checks and is described by `cosmic help test`; the quickstart is about reading data and writing programs, not running a tree's suite",
  tests = { "build.test_test", "build.test_selection_test" },
  run = function(argv: {string}): integer
    local code = run(argv)
    rebuild_lock.release()
    return code
  end,
  bare = false,
  takes = "exact module names, source paths and directories",
}

return test
