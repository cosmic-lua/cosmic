--- Runs every test the tree defines that a stored verdict does not
--- already answer for, each in a process of its own, and records each
--- verdict into the working database, `o/build.db`, which never ships
--- and is never carried in `o/cosmic.db`.
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
--- A test whose key holds a passing verdict, of this checkout or, by
--- that key alone, of another ([`build.shared_verdicts`]), stands; any
--- other runs, and its verdict is kept only when its inputs still digest
--- to the same key once it has run. A test that declares loopback
--- addresses, the only network it may ([`cosmic.test`]), runs offline, as
--- every sandboxed test does, and is keyed. None is assumed, and `--all`
--- (or `COSMIC_TEST_ALL=1`) runs every test the run
--- chooses, whatever stands.

local Child = require("cosmic.child")
local Cli = require("cosmic.cli")
local Clock = require("cosmic.clock")
local Coverage = require("cosmic.coverage")
local Env = require("cosmic.env")
local testing = require("cosmic.internal.testing")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Poll = require("cosmic.poll")
local Proc = require("cosmic.proc")
local type Sandbox = require("cosmic.sandbox")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local String = require("cosmic.string")
local sys = require("cosmic.sys")
local clock = require("build.clock")
local coverage_report = require("build.coverage")
local c_functions = require("build.c_functions")
local importer = require("build.importer")
local plural = require("build.plural")
local reboot = require("build.reboot")
local rebuild_lock = require("build.rebuild_lock")
local schema = require("build.schema")
local teal = require("build.teal")
local tree = require("build.tree")
local work = require("build.work")
local writer = require("build.writer")
local closure_store = require("build.closure_store")
local confine = require("build.confine")
local shared_compiles = require("build.shared_compiles")
local shared_verdicts = require("build.shared_verdicts")
local test_inputs = require("build.test_inputs")
local test_report = require("build.test_report")
local test_policy = require("build.test_policy")
local test_sandbox = require("build.test_sandbox")
local test_sandbox_probe = require("build.test_sandbox_probe")
local declared_key = require("build.declared_key")
local artifact = require("build.artifact")
local hashing = require("build.digest")
local harness_epoch = require("build.harness_epoch")
local host_names = require("build.host_names")
local host_requires = require("build.host_requires")
local host_caches = require("build.caches")
local worker = require("build.test_worker")
local type compiler = require("build.compiler")

local log = require("build.verdict").log
local bind = require("build.bind")
local verb_spec = require("build.verb_spec")

-- Key material -- the tool's identity salting a compile, a checkout's
-- id -- is hashed through build.digest, as build.declared_key's is, not
-- cosmic.hash: a key's value turns on no library module outside the
-- harness (`harness`).
local hex_sha256 = hashing.hex_sha256

local record test
  --- The verb's registration: see build/verb_spec.tl.
  spec: verb_spec.Spec
  --- One verdict ever reached, by key.
  record Verdict
    passed: boolean
    run_at_ns: integer
    --- How long the run that reached this verdict took, so a test
    --- answered from it still has a duration to give `runs`.
    elapsed_ns: integer
  end

  --- Every test id (`"path name"`) whose standing verdict credits a
  --- given run, by that run's `run_at_ns`: what this run still owes
  --- `hits`, gathered while replaying verdicts and resolved against
  --- `coverage_by_test` in one query per run credited, after the loop.
  type Credited = {integer: {string}}

  --- How many tests this run ran, and how many it answered from a
  --- verdict that still stood.
  record Tally
    ran: integer
    cached: integer
    --- Of those that stood, how many on a verdict another checkout
    --- reached ([`build.shared_verdicts`]).
    shared: integer
    --- Of those that ran, how many no key holds, which run every time:
    --- one whose module reaches a network beyond loopback, or reads a
    --- link out of the tree.
    every: integer
    --- Of those that ran, how many passed having said, with
    --- [`Test.skip`], that this host could not check them: no verdict is
    --- kept of one, so each runs every time.
    skipped: integer
    --- Of those that ran, how many passed having made no call to `assert`
    --- ([`worker.Judgement.unchecked`]): no verdict is kept of one
    --- either, and a held run fails it.
    unchecked: integer
    --- Of the tests chosen, how many are not applicable: their module
    --- requires what this platform never has ([`host_requires`]), so none
    --- ran or stood, and no verdict is kept of one. Neither in `ran` nor
    --- in `cached`, but in the run's total.
    na: integer
  end

  --- One of the shares `--shard I/N` splits a run's chosen tests into
  --- ([`test.shard`], [`test.dealt`]).
  record Shard
    --- Which share, from 1.
    index: integer
    --- How many shares there are.
    count: integer
  end

  --- How a run is bounded, from the command line and the environment.
  record Limits
    --- Each test's deadline, in nanoseconds.
    timeout_ns: integer
    --- How many workers run at once.
    jobs: integer
  end
end

--- The variable a test deadline's default is read from, in seconds.
local timeout_variable = "COSMIC_TEST_TIMEOUT"
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
local function split(selector: string): string, string
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
  local ranked: {string} = {}
  for i, other in ipairs(names) do ranked[i] = other end
  table.sort(ranked, function(a: string, b: string): boolean
    local left, right = shared(a), shared(b)
    if left ~= right then return left > right end
    return a < b
  end)
  local out: {string} = {}
  for i = 1, math.min(#ranked, shown_names) do out[i] = ranked[i] end
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

--- The share `text`, `--shard`'s value, names: `I/N`, whole numbers with
--- 1 <= I <= N. Nil and why for anything else.
function test.shard(text: string): test.Shard | nil, string
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
  local sorted: {string} = {}
  for i, id in ipairs(ids) do sorted[i] = id end
  table.sort(sorted)
  local out: {string:boolean} = {}
  for k, id in ipairs(sorted) do
    if (k - 1) % shard.count == shard.index - 1 then out[id] = true end
  end
  return out
end

local text = bind.text

--- A run's key as `runs` holds it: its key, then, when it has one,
--- its shared key after a space.
local function run_key(key: string, shared: string | nil): string
  if shared == nil then return key end
  return key .. " " .. shared
end

local function record_run(handle: Sqlite.Handle, path: string, name: string,
                          passed: boolean, message: string, ran_at_ns: integer,
                          key: string, run_at_ns: integer, elapsed: integer): boolean, string
  return Sqlite.run(handle,
    "INSERT OR REPLACE INTO runs (path, test, passed, message, ran_at_ns, " ..
      "key, run_at_ns, elapsed_ns) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
    { text(path), text(name), { integer = passed and 1 or 0 }, text(message),
      { integer = ran_at_ns }, text(key), { integer = run_at_ns }, { integer = elapsed } })
end

--- Every test that has a `runs` row, by "path name": each that ran or
--- stood here before.
local function previous_runs(handle: Sqlite.Handle): {string:boolean} | nil, string
  local rows, trouble = Sqlite.text_rows(handle, "SELECT path, test FROM runs")
  if rows == nil then
    return nil, trouble
  end
  local out: {string:boolean} = {}
  for _, row in ipairs(rows) do out[row[1] .. " " .. row[2]] = true end
  return out
end

--- Every verdict ever reached, by key.
local function known_verdicts(handle: Sqlite.Handle): {string:test.Verdict} | nil, string
  local rows, trouble = Sqlite.text_rows(handle,
    "SELECT key, passed, run_at_ns, elapsed_ns FROM verdicts")
  if rows == nil then
    return nil, trouble
  end
  local out: {string:test.Verdict} = {}
  for _, row in ipairs(rows) do
    out[row[1]] = {
      passed = row[2] == "1",
      run_at_ns = math.tointeger(tonumber(row[3]) or 0) or 0,
      elapsed_ns = math.tointeger(tonumber(row[4]) or 0) or 0,
    }
  end
  return out
end

--- Records one verdict under its key, as relied on by this run.
local function record_verdict(handle: Sqlite.Handle, key: string, passed: boolean,
                              run_at_ns: integer, run: integer,
                              elapsed: integer): boolean, string
  return Sqlite.run(handle,
    "INSERT OR REPLACE INTO verdicts (key, passed, run_at_ns, seen, elapsed_ns) " ..
      "VALUES (?1, ?2, ?3, ?4, ?5)",
    { text(key), { integer = passed and 1 or 0 }, { integer = run_at_ns },
      { integer = run }, { integer = elapsed } })
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
local function prune_history(handle: Sqlite.Handle, run: integer): boolean, string
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
  local pruned_snapshots, snapshots_trouble = handle:exec(
    "DELETE FROM coverage WHERE ran_at_ns NOT IN " ..
      "(SELECT ran_at_ns FROM test_runs ORDER BY ran_at_ns DESC LIMIT " ..
      kept_snapshots .. ")")
  if not pruned_snapshots then
    return false, snapshots_trouble
  end
  return handle:exec(
    "DELETE FROM test_runs WHERE ran_at_ns NOT IN (SELECT ran_at_ns FROM coverage) " ..
      "AND ran_at_ns NOT IN (SELECT ran_at_ns FROM coverage_by_test)")
end

--- The environment every worker this process starts has
--- ([`test.worker_environment`]), which is what a test's read of a
--- variable answers and so what its key holds: defined beside it.
local worker_view: function(): {string:string}

--- One test's hits as `coverage_by_test` holds them: a line per module,
--- in path order, the path, a tab, then the lines it hit, ascending and
--- comma-separated. Module paths hold neither tabs nor newlines. A row
--- [`take_hits`] writes may name a module twice, its load's hits and its
--- test's, which [`decode_hits`] folds together.
local function encode_hits(test_hits: Coverage.Hits): string
  local paths: {string} = {}
  for path in pairs(test_hits) do
    paths[#paths + 1] = path
  end
  table.sort(paths)
  local out: {string} = {}
  for _, path in ipairs(paths) do
    local lines: {integer} = {}
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
    local placeholders: {string} = {}
    local args: {Sqlite.Value} = { { integer = run_at_ns } }
    for index, id in ipairs(tests) do
      placeholders[index] = "?" .. (index + 1)
      args[#args + 1] = text(id)
    end
    local rows, trouble = Sqlite.text_rows(handle,
      "SELECT hits FROM coverage_by_test WHERE ran_at_ns = ?1 " ..
        "AND test IN (" .. table.concat(placeholders, ", ") .. ")", args)
    if rows == nil then
      return trouble
    end
    for _, row in ipairs(rows) do
      decode_hits(row[1], hits)
    end
  end
  return ""
end

--- Reuses `coverage`'s statement for the many rows in a snapshot,
--- checking every operation.
local function insert_coverage(statement: Sqlite.Statement, run_at_ns: integer,
                               path: string, line: integer,
                               last: integer | string): boolean, string
  local ok, trouble = statement:bind_integer(1, run_at_ns)
  if not ok then
    return false, trouble
  end
  ok, trouble = statement:bind_text(2, path)
  if not ok then
    return false, trouble
  end
  ok, trouble = statement:bind_integer(3, line)
  if not ok then
    return false, trouble
  end
  if last is integer then
    ok, trouble = statement:bind_integer(4, last)
  else
    ok, trouble = statement:bind_text(4, last)
  end
  if not ok then
    return false, trouble
  end
  return bind.once(statement)
end

--- How many rows one multi-row INSERT carries before it steps. Modest
--- on purpose: SQLite's parameter ceiling is far higher, but a longer
--- statement costs its own parse time, and the win is already in
--- trading six Lua-to-C calls per row for a fraction of one.
local insert_batch = 100

--- `n` value groups `(<run_at_ns>, ?, ?, ?)`, indexed contiguously from
--- 1, for a batch insert into `coverage`. `ran_at_ns` is the same for
--- every row one run writes, so it is a literal rather than a parameter
--- rebound once per row for nothing.
local function batch_values(run_at_ns: integer, n: integer): string
  local groups: {string} = {}
  for row = 0, n - 1 do
    groups[row + 1] = string.format("(%d, ?%d, ?%d, ?%d)",
      run_at_ns, row * 3 + 1, row * 3 + 2, row * 3 + 3)
  end
  return table.concat(groups, ", ")
end

--- Rows waiting for `coverage`: a full `insert_batch` of them goes in
--- one step of `whole`, and whatever is left when the caller is done
--- goes through `single`, one row at a time.
local record Batch
  whole: Sqlite.Statement
  single: Sqlite.Statement
  run_at_ns: integer
  paths: {string}
  lines: {integer}
  lasts: {integer | string}
  pending: integer
end

local function batch_for(handle: Sqlite.Handle, single: Sqlite.Statement,
                         run_at_ns: integer, into: string,
                         last_column: string): Batch | nil, string
  local whole, trouble = handle:prepare("INSERT INTO " .. into ..
      " (ran_at_ns, path, line, " .. last_column .. ") VALUES " ..
      batch_values(run_at_ns, insert_batch))
  if whole == nil then
    return nil, trouble
  end
  return { whole = whole, single = single, run_at_ns = run_at_ns,
    paths = {}, lines = {}, lasts = {}, pending = 0 }
end

--- Steps `whole` once over a full batch, then empties it.
local function flush(batch: Batch): boolean, string
  local statement = batch.whole
  for row = 1, batch.pending do
    local base = (row - 1) * 3
    local ok, trouble = statement:bind_text(base + 1, batch.paths[row])
    if ok then
      ok, trouble = statement:bind_integer(base + 2, batch.lines[row])
    end
    if ok then
      local last = batch.lasts[row]
      if last is integer then
        ok, trouble = statement:bind_integer(base + 3, last)
      else
        ok, trouble = statement:bind_text(base + 3, last)
      end
    end
    if not ok then
      return false, trouble
    end
  end
  local state, failure = statement:step()
  if state == nil then
    return false, failure
  end
  batch.pending = 0
  return statement:reset()
end

--- Queues one row, writing the batch out when it fills.
local function add(batch: Batch, path: string, line: integer,
                   last: integer | string): boolean, string
  local n = batch.pending + 1
  batch.paths[n] = path
  batch.lines[n] = line
  batch.lasts[n] = last
  batch.pending = n
  if n == insert_batch then
    return flush(batch)
  end
  return true, ""
end

--- Writes the rows short of a full batch, one at a time.
local function drain(batch: Batch): boolean, string
  for row = 1, batch.pending do
    local ok, trouble = insert_coverage(batch.single, batch.run_at_ns,
      batch.paths[row], batch.lines[row], batch.lasts[row])
    if not ok then
      return false, trouble
    end
  end
  batch.pending = 0
  return true, ""
end

--- The keys of `set`, ascending.
local function sorted_lines(set: {integer: any}): {integer}
  local out: {integer} = {}
  for line in pairs(set) do
    out[#out + 1] = line
  end
  table.sort(out)
  return out
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
--- `native_lines` are the core's own C lines ([`Coverage.native_lines`]),
--- or none when the tree is not the one that C belongs to. Returns the
--- overall hit and executable-line counts, over every module written
--- for this run, for the run's own verdict line, and a trouble message.
local function write_coverage(handle: Sqlite.Handle, built: compiler,
                              modules: {importer.Module},
                              native_lines: Coverage.Hits,
                              hits: Coverage.Hits,
                              by_test: {string: string},
                              run_at_ns: integer): integer, integer, string
  local total_hit = 0
  local total_lines = 0
  local recorded, run_trouble = Sqlite.run(handle,
    "INSERT OR REPLACE INTO test_runs (ran_at_ns) VALUES (?1)",
    { { integer = run_at_ns } })
  if not recorded then
    return 0, 0, run_trouble
  end
  local coverage, prepare_trouble = handle:prepare(
    "INSERT INTO coverage (ran_at_ns, path, line, hit) VALUES (?1, ?2, ?3, ?4)")
  if coverage == nil then
    return 0, 0, prepare_trouble
  end
  local per_test, test_trouble = handle:prepare(
    "INSERT INTO coverage_by_test (ran_at_ns, test, hits) VALUES (?1, ?2, ?3)")
  if per_test == nil then
    coverage:finalize()
    return 0, 0, test_trouble
  end
  local coverage_rows, coverage_batch_trouble =
    batch_for(handle, coverage, run_at_ns, "coverage", "hit")
  if coverage_rows == nil then
    coverage:finalize()
    per_test:finalize()
    return 0, 0, coverage_batch_trouble
  end
  -- The core's own C sits among the modules by path: a core that
  -- observes it answers every line a block begins on, and a line is hit
  -- when some window's hits name it (see [`Coverage.native_lines`]).
  local by_source: {string: importer.Module} = {}
  local sorted_paths: {string} = {}
  for _, m in ipairs(modules) do
    by_source[m.path] = m
    sorted_paths[#sorted_paths + 1] = m.path
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
  local test_names: {string} = {}
  for test_name in pairs(by_test) do
    test_names[#test_names + 1] = test_name
  end
  table.sort(test_names)
  local write_rows = function(): boolean, string
    for _, path in ipairs(sorted_paths) do
      local m = by_source[path]
      local per_line: coverage_report.LineHits
      if m ~= nil then
        local lines_trouble: string
        per_line, lines_trouble = coverage_report.lines_of(handle, built, m, hits)
        if per_line == nil then
          return false, m.file .. ": " .. lines_trouble
        end
      else
        local hit_here = hits[path] or {}
        per_line = {}
        for line in pairs(native_lines[path]) do
          per_line[line] = hit_here[line] == true
        end
      end
      for _, line in ipairs(sorted_lines(per_line)) do
        local was_hit = per_line[line]
        local ok, write_trouble = add(coverage_rows, path, line, was_hit and 1 or 0)
        if not ok then
          return false, write_trouble
        end
        total_lines = total_lines + 1
        if was_hit then
          total_hit = total_hit + 1
        end
      end
    end
    local drained, drain_trouble = drain(coverage_rows)
    if not drained then
      return false, drain_trouble
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
  coverage_rows.whole:finalize()
  if not called then
    return 0, 0, tostring(made)
  end
  if not made then
    return 0, 0, trouble
  end
  return total_hit, total_lines, ""
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

--- One test the run has to run: no verdict stands for it.
local record Job
  m: importer.Module
  --- Whether its worker was never started, since a requirement of its
  --- module is absent: it has no key, which is no reason to say it runs
  --- every time.
  unrun: boolean
  name: string
  id: string
  --- The directory the runner made for the test, holding `real` and
  --- `tmp`, a link to it; removed once the test passes.
  scratch: string
  tmp: string
  --- Whether the test's directory is one its worker makes in a tmpfs of its
  --- own ([`test_sandbox.Plan`]'s `own_scratch`), so the runner has none.
  own_scratch: boolean
  --- How its worker is sandboxed, when it is ([`build.test_sandbox`]).
  plan: test_sandbox.Plan
  --- Sandboxed, the key its verdict is reached under, over its
  --- declared inputs as they were before it started
  --- ([`build.declared_key`]); nil for one that reaches a network beyond
  --- loopback, or an unsandboxed run's.
  declared: string
  passed: boolean
  handle: Child.Handle
  started_ns: integer
  deadline_ns: integer
end

--- The digest of the zones and CA roots the running binary's own
--- database carries ([`schema.tables_digest`]), searched alone so no
--- attached database stands in for it.
local function binary_tables(): string | nil, string
  local rows: {{string}} = nil
  local trouble = "the running binary has no database"
  Store.alone(function()
    local databases = Store.databases()
    local binary = databases[#databases]
    if binary ~= nil then
      rows, trouble = Sqlite.text_rows(binary, schema.tables_digest(""))
    end
  end)
  if rows == nil then return nil, trouble end
  return rows[1][1], ""
end

--- What of the running binary a run holds of the code a worker runs,
--- or that writes what it is given ([`binary_harness`]).
local record Harness
  --- A digest of each module of the test harness by its name, source
  --- and bytecode ([`test.harness`]): what a worker runs, and the code
  --- that makes and reads its key. build/harness_epoch.tl's
  --- `acknowledged` records them, one to a line between blank ones, so
  --- two changes to different modules of the harness merge cleanly. No
  --- key holds them; each holds the epoch in their place.
  modules: {string:string}
  --- The modules `modules` holds, and those of them the harness runs
  --- -- what every worker loads and `harness_own` -- whose requires
  --- build/harness_epoch_test.tl holds to `names`.
  names: {string}
  runs: {string}
  --- The digest of the code that writes a closure store, which salts
  --- each store's address ([`build.closure_store`]'s `address`).
  store_salt: string
  --- The set of the names of the modules the binary carries, which
  --- [`worker.judge`] holds what a worker loaded to.
  carried: {string:boolean}
end

--- The modules of the harness beside what every worker loads
--- ([`build.test_worker`]'s [`worker.loads`]): build.test_sandbox and the
--- tree modules it requires, build.test_policy, build.caches and
--- build.zig_caches. build.test_sandbox makes the plan of a worker's
--- sandbox (`plan`): what it binds, unveils and holds, and the
--- environment it gives. build.test_policy turns that plan into the
--- policy a worker is started under.
--- build.caches says where each declared host cache is bound from and
--- makes it; build.zig_caches does so for zig's.
---
--- What else of the runner shapes a worker is the worker's own module's,
--- which [`worker.loads`] names: its command line and start options, and
--- how its report is read into a verdict ([`worker.invocation`],
--- [`worker.judge`]). The rest of build.test passes it only what a key
--- holds by itself (the test's declaration, its closure's names, which
--- the store's address holds, whether it may run this program
--- ([`Spec.runs_tool`]), and its timeout) or what [`key_code`] holds (the
--- names of the tree's modules, which decide what a worker refuses a
--- `require` of).
---
--- None of it is keyed by its code: the epoch stands for it
--- (build/harness_epoch.tl), and an edit to it fails
--- build/harness_epoch_test.tl until the epoch is bumped or the edit
--- acknowledged. That test also fails where a module here or in
--- [`worker.loads`] requires one of the tree the harness does not name.
-- TODO: key the sandbox's plan as data -- its unveils and binds, with
-- the tree, the scratch directory and the host caches named relative to
-- what they stand for, and its environment -- rather than leaving it to
-- the epoch, once the caches' binds name no host location:
-- then a change to a hold or a bind moves every key it touches by
-- itself, where today it moves none unless someone bumps the epoch by
-- hand.
local harness_own <const>: {string} = { "build.test_sandbox", "build.test_policy",
  "build.caches", "build.zig_caches" }

--- The modules of the harness held alone, by their own source and
--- bytecode, their requires not walked: cosmic.child, whose `start`
--- turns a worker's policy into what spawn holds it to -- the
--- unveils, the binds, offline -- so an edit
--- that weakened it would pass a test that reads what it does not
--- declare, and keep and share the pass. What it requires (cosmic.time,
--- cosmic.stream and the rest) applies no sandbox, and stays out. The
--- exception is cosmic.sandbox, held alone too: among others its `merge`
--- (and the profiles it joins), `loaders`, `reach` and `user_id` decide
--- what a worker started under a policy may reach, and
--- [`test_policy.runs`] merges a policy through it. Its own requires are
--- not walked, and none of them decides a grant.
-- TODO: move the translation of a worker's policy into spawn's
-- options into build.confine, which the harness holds already, and
-- drop cosmic.child from here and from build/harness_epoch.tl's
-- `library`, once cosmic.child's `start` takes spawn's sandbox as it is
-- (the TODO above its `raw.spawn` call, which would offer the rest of
-- it): today only cosmic.child reaches spawn for the runner.
local harness_alone <const>: {string} = { "cosmic.child", "cosmic.sandbox" }

--- The code that makes a key and looks a verdict up under one:
--- build.test itself, whose closure is the build's, and the closure of
--- the key's computation ([`build.declared_key`]) and of the shared
--- verdicts' ([`build.shared_verdicts`]), and of what the host answers a
--- module's requirements ([`build.host_requires`]), which a key holds,
--- as the `imports` table has it.
--- What build.test decides of a worker's hold is part of it: which
--- names of the tree a `require` refuses (`tree_names`).
---
--- A key is looked up by its value, but that is not enough. A version
--- of this code that maps some inputs to the key another version
--- computes for other inputs (a digest that misses a rewrite, say)
--- keeps a verdict under that key, in o/build.db and in the verdicts
--- every checkout shares, which would stand after a fix. So a fix to it
--- bumps the epoch (build/harness_epoch.tl), which every key holds.
--- Every version of it is in the harness's digests, which
--- build/harness_epoch_test.tl holds to what was acknowledged: an edit
--- to any of it, a comment's too, fails that test until someone says
--- whether it can move a verdict.
-- TODO: hold only the part of build.test that makes a key, gives a
-- worker its holds and looks a verdict up, walked as `key_roots` are,
-- once it is a module of its own (plan 2.7b): today build.test is held whole and unwalked, so an
-- edit to its remaining census plumbing acknowledges the harness, and
-- what it requires beyond [`key_code`] (cosmic.time, cosmic.cli and the
-- like) is outside build/harness_epoch.tl's `library` rule.
local key_roots <const>: {string} = { "build.declared_key", "build.shared_verdicts",
  "build.host_requires" }
local key_own <const>: {string} = { "build.test" }

--- The module that holds the epoch and the acknowledged digests, which
--- the digests leave out: it would hold itself.
local epoch_module <const> = "build.harness_epoch"

--- The code that writes a closure store: build.closure_store's and the
--- schema it writes it by ([`build.schema`]).
---
--- The store's address holds the rows it carries by their digests
--- ([`closure_store.basis`]), but not which of them, nor which tables,
--- that code copies: a table added to what it copies would move no
--- address. The projection's writer ([`build.writer`]) is none of this
--- code. What it writes reaches a store only through rows and orderings
--- the basis digests: each module's columns, its source's stored bytes
--- among them, and its own docs, catalog and examples in their order,
--- while build.closure_store orders them across modules itself. So an
--- edit to the writer that writes the same rows moves no address, and
--- one that writes others moves only the addresses of the closures that
--- carry them.
---
--- The salt holds the code that writes a closure store with all it
--- requires ([`store_code`]), each module by its source and bytecode.
--- It salts where a store is, not what a key holds of it: what
--- build.closure_store writes passes through cosmic.sqlite, cosmic.fs
--- and cosmic.hash, and an edit to one of them (how a blob is bound, a
--- pragma set) can change a store's bytes while every row's digest
--- stays, so an edit to any of that code writes every store again, at
--- a new address. A key holds each store by its bytes
--- ([`declared_key.store_digest`]), so only an edit that changes them
--- -- not a comment in build/schema.tl -- runs a test again.
local store_writer <const>: {string} = { "build.closure_store", "build.schema" }

--- The names `roots` and `own` hold: each root and every module it
--- requires, directly or not, by `imports` (the names each module
--- requires), and each of `own` alone.
local function closure_of(roots: {string}, own: {string},
                          imports: {string:{string}}): {string}
  local seen: {string:boolean} = {}
  local names: {string} = {}
  local stack: {string} = {}
  for _, name in ipairs(own) do
    seen[name] = true
    names[#names + 1] = name
  end
  for _, name in ipairs(roots) do stack[#stack + 1] = name end
  while #stack > 0 do
    local name = table.remove(stack)
    if not seen[name] then
      seen[name] = true
      names[#names + 1] = name
      for _, required in ipairs(imports[name] or {}) do stack[#stack + 1] = required end
    end
  end
  return names
end

-- The `imports` rows whose importer is a module or main with no
-- occurrence of the required name in its bytecode: Teal erased the
-- require, so the edge is by type alone. [`test.value_imports`] keeps
-- the rows this does not match and [`test.type_only_imports`] the rows
-- it does, so the two cannot drift apart.
local erased_require = "(SELECT 1 FROM modules m WHERE m.path = i.path " ..
  "AND m.kind IN ('module', 'main') " ..
  "AND instr(m.bytecode, CAST(i.requires AS BLOB)) = 0)"

--- The `imports` rows of `db` a module makes by value, by importer: an
--- edge is kept unless the importer's bytecode lacks the name it
--- requires as a string constant. Teal erases a `local type` require,
--- and what the imported type does at run time -- an `is` against a
--- record's `where`, an enum's test -- is compiled into the importer's
--- bytecode, which the harness's digests hold. Any other spelling of a
--- require (`require"x"`, one split across lines, one inside a
--- function) leaves the name in the bytecode, and so does a name that
--- is only a string there: the test errs toward following an edge.
function test.value_imports(db: Sqlite.Handle): {string:{string}} | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT i.path, i.requires FROM imports i WHERE NOT EXISTS " .. erased_require)
  if rows == nil then return nil, trouble end
  local out: {string:{string}} = {}
  for _, row in ipairs(rows) do
    local list = out[row[1]] or {}
    out[row[1]] = list
    list[#list + 1] = row[2]
  end
  return out, ""
end

--- The `imports` rows of `db` a module makes by type alone, as sets by
--- importer: the complement of [`test.value_imports`], and no other
--- rows. A test's closure leaves these edges out
--- ([`build.test_inputs`]'s `closure`): an importer that requires a
--- module only to name its types runs without loading it, so an edit to
--- it that leaves the importer's bytecode as it was moves no key, and a
--- test importing the importer is not run again for it.
function test.type_only_imports(db: Sqlite.Handle): {string:{string:boolean}} | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT i.path, i.requires FROM imports i WHERE EXISTS " .. erased_require)
  if rows == nil then return nil, trouble end
  local out: {string:{string:boolean}} = {}
  for _, row in ipairs(rows) do
    local set = out[row[1]] or {}
    out[row[1]] = set
    set[row[2]] = true
  end
  return out, ""
end

--- [`test.type_only_imports`] of the projection at `path`.
local function projection_type_only(path: string): {string:{string:boolean}} | nil, string
  local opened, trouble = Sqlite.open(path)
  if opened == nil then return nil, path .. ": " .. trouble end
  local db: Sqlite.Handle = opened
  local found, found_trouble = test.type_only_imports(db)
  local _, _ = db:close()
  if found == nil then return nil, found_trouble end
  return found, ""
end

--- The names `key_roots` and `key_own` hold ([`closure_of`]), over the
--- requires each module makes by value ([`test.value_imports`]).
local function key_code(by_value: {string:{string}}): {string}
  return closure_of(key_roots, key_own, by_value)
end

--- The names `store_writer` holds, with what they require ([`closure_of`]).
local function store_code(imports: {string:{string}}): {string}
  return closure_of(store_writer, {}, imports)
end

--- The digests of the test harness's modules and that of the code that
--- writes a closure store ([`Harness`]), over the modules `db` holds, by
--- their `modules` and `imports` rows. `db` is the running binary's
--- database ([`binary_harness`], which fills in `carried`), or the
--- projection, o/cosmic.db, which build/harness_epoch_test.tl reads.
---
--- Each module of the harness is held by its name, its source's hash and
--- its bytecode's, a digest to each (`modules`). That covers what a
--- worker loads, `harness_own`, `harness_alone` and [`key_code`], but not
--- build.harness_epoch, which records the digests. Each digest is the
--- same wherever the tree is, and a compiler that makes other bytecode
--- of the same source moves it as an edit does. The salt holds each
--- module of the store's writer the same way ([`store_code`]), as the
--- store's bytes follow from both. Nil and why where a module either
--- names is none `db` carries, which the digests or the salt would
--- otherwise leave out unnoticed.
function test.harness(db: Sqlite.Handle): Harness | nil, string
  local modules, trouble = Sqlite.text_rows(db,
    "SELECT path, source_hash, lower(hex(sha256(bytecode))) FROM modules " ..
      "WHERE kind IN ('module', 'main')")
  if modules == nil then return nil, trouble end
  local imported, imports_trouble = Sqlite.text_rows(db, "SELECT path, requires FROM imports")
  if imported == nil then return nil, imports_trouble end
  local sources: {string:string} = {}
  local compiled: {string:string} = {}
  local carried: {string:boolean} = {}
  for _, row in ipairs(modules) do
    sources[row[1]] = row[2]
    compiled[row[1]] = row[2] .. " " .. row[3]
    carried[row[1]] = true
  end
  local imports: {string:{string}} = {}
  for _, row in ipairs(imported) do
    local list = imports[row[1]] or {}
    imports[row[1]] = list
    list[#list + 1] = row[2]
  end
  local names: {string} = {}
  local runs: {string} = {}
  for _, list in ipairs({ worker.loads, harness_own }) do
    for _, name in ipairs(list) do runs[#runs + 1] = name end
  end
  local by_value, value_trouble = test.value_imports(db)
  if by_value == nil then return nil, value_trouble end
  for _, list in ipairs({ worker.loads, harness_own, harness_alone, key_code(by_value) }) do
    for _, name in ipairs(list) do
      if sources[name] == nil then
        return nil, name .. ", which a worker runs or which makes or reads a key, " ..
          "is no module the binary carries"
      end
      if name ~= epoch_module then names[#names + 1] = name end
    end
  end
  local each: {string:string} = {}
  for _, name in ipairs(names) do each[name] = declared_key.harness({ name }, compiled) end
  local salted = store_code(imports)
  for _, name in ipairs(salted) do
    if compiled[name] == nil then
      return nil, name .. ", which writes a closure store, is no module the binary carries"
    end
  end
  return { modules = each, names = names, runs = runs,
    store_salt = declared_key.harness(salted, compiled), carried = carried }, ""
end

--- What of the running binary a run holds of the code a worker runs
--- ([`Harness`]), searched alone so no attached database stands in for
--- it. What a worker runs is what every worker loads ([`worker.loads`]),
--- which [`worker.judge`] holds each worker to, and `harness_own`; no
--- `imports` closure of it is walked, which would follow the requires
--- a worker never runs: Teal erases a `local type` one, and what an
--- imported type does at run time (an `is` against a record's `where`,
--- an enum's test) is compiled into the importer's bytecode. None of it
--- is keyed by what it is: the epoch stands for it
--- (build/harness_epoch.tl).
local function binary_harness(): Harness | nil, string
  local harness: Harness = nil
  local trouble = "the running binary has no database"
  Store.alone(function()
    local databases = Store.databases()
    local binary = databases[#databases]
    if binary == nil then return end
    harness, trouble = test.harness(binary)
  end)
  if harness == nil then return nil, trouble end
  return harness, ""
end

--- The harness's epoch every key holds (build/harness_epoch.tl), or
--- the one COSMIC_TEST_HARNESS_EPOCH names in its place, for a test
--- alone, which stands in for a bump without a binary of its own
--- (build/sandboxed_verdicts_test.tl): a count, a dash and hex digits,
--- as the file's is, so the census and key-parts lines, which say it
--- as one word, stay parseable. Nil and why for another.
local function harness_epoch_of(): string | nil, string
  local named = Env.get("COSMIC_TEST_HARNESS_EPOCH") or ""
  if named == "" then return harness_epoch.epoch, "" end
  if not named:match("^%d+%-%x+$") then
    return nil, string.format("COSMIC_TEST_HARNESS_EPOCH is %q, not a count, a dash and " ..
        "hex digits, as build/harness_epoch.tl's `epoch` is", named)
  end
  return named, ""
end

--- The word the census and key-parts lines say a key's harness parts
--- as (`cosmic test --census`): its epoch and the workers' timeout, one
--- word, which ci/cosmic_ci/report.tl compares whole, so a bump from
--- the same count says a moved harness.
function test.harness_word(epoch: string, timeout_ns: integer): string
  return string.format("e%s-t%d", epoch, timeout_ns)
end

--- Why a module's tests are not run on this host: a requirement of its
--- module ([`host_requires`]) it lacks.
local record Unmet
  --- "na" where the platform never has it, "skipped" where this host lacks
  --- it, "refused" where its name breaks the table's rules.
  kind: host_requires.Kind
  --- The requirement and why, as the report says it.
  why: string
end

--- What the sealed databases of a run are made from ([`sealing_for`]).
local record Sealing
  --- The run's own directory, open to the user a sandboxed worker runs as,
  --- where each sealed database and the program's own are written.
  directory: string
  --- The program's own database, written in `directory`.
  program: string
end

--- Everything a finished job's verdict is recorded into.
local record PlanMade
  plan: test_sandbox.Plan
  scratch: string
end

local record Recording
  records: Sqlite.Handle
  root: string
  -- The binary's runtime identity and the digest of its data tables.
  runtime: string
  run_at_ns: integer
  run: integer
  failures: {string}
  errors: {string}
  --- Each skipped test's id and why ([`Test.skip`], or a requirement of
  --- its module the host lacks), as "<id>: <reason>".
  skips: {string}
  --- Each test that passed having made no call to `assert`, by id.
  unchecked: {string}
  --- What each test that passed deliberately without checking
  --- ([`Test.passed_unchecked`]) said, one entry per test.
  deliberate: {string}
  --- Whether the run is held ([`Run.held`]).
  held: boolean
  --- Each not applicable test's id and why, in the same shape.
  nas: {string}
  --- The modules whose requirements ([`host_requires`]) are not all
  --- present on this host, by path, and what each answered: their tests
  --- are not started and have no key.
  unmet: {string:Unmet}
  --- What the host answered to each module's requirements, by path, as
  --- its key holds them: each present answer's name and key text. Empty
  --- for a module that requires nothing.
  answered: {string:{string:string}}
  --- What each failing test printed, by its id.
  outputs: {string:string}
  --- Each failing test's `<file>:<name>` selector, by its id: what
  --- `cosmic test` takes to run that one test again.
  reruns: {string:string}
  --- Each failing test's id, by its entry in `failures`: the id is
  --- carried rather than parsed back out of text a path may put
  --- spaces in.
  failed: {string:string}
  hits: Coverage.Hits
  --- Each test's own hits, encoded as it finishes. Kept as tables, every
  --- test's lines would stay in memory until the run ends: hundreds of
  --- megabytes.
  by_test: {string: string}
  --- The core's C when the tree is not cosmic's own: its hits are kept
  --- out of every record of the run (see [`write_coverage`]).
  unowned: Coverage.Hits
  tally: test.Tally
  --- The verdicts every checkout shares, or nil, and what the run owes
  --- them when it ends.
  shared: shared_verdicts.Cache
  owed: shared_verdicts.Owed
  --- Each key a verdict of this run stands under, its
  --- shared key, for `owed.used`.
  shared_keys: {string:string}
  --- What names this checkout among the rows it shares ([`checkout_id`]).
  origin: string
  --- Each selected module's effective inputs, by path, and the program
  --- running the tests, which `tool` declares.
  effective: {string:test_inputs.Effective}
  tool: {string}
  --- Whether each worker runs sandboxed ([`build.test_sandbox`]): the
  --- switch does not turn it off and the kernel can. `effective` then
  --- holds every selected module's inputs, and `views` the environment
  --- its workers are given, by module path.
  sandbox: boolean
  --- What reruns one test as this run ran it: the switch as the run was
  --- given it ([`test_sandbox.mode`]), or "" when unset.
  rerun_prefix: string
  views: {string:{string:string}}
  --- What keys each verdict ([`build.declared_key`]): the
  --- digests of the tree's files the run has taken, and the compiler's
  --- identity ([`build.identity`]'s `Identities`) as the running tool's `meta`
  --- names it, `compiler` and then `compiled_by`, which a key holds
  --- only where its closure reads it ([`declared_key.reads_compiler`]).
  digests: declared_key.Digests
  compiler: string
  --- The host's identity every key holds
  --- ([`declared_key.host_identity`]), what it has installed, which only
  --- the key of a module given the system's paths holds
  --- ([`declared_key.system_identity`]), and why each module whose tests
  --- have no key has none, but for the network, by module path.
  host: string
  system: string
  --- The harness's epoch (build/harness_epoch.tl), which every key
  --- holds in place of the harness's code, and the timeout each worker
  --- runs under ([`Limits.timeout_ns`]), which every key holds too: a
  --- pass reached under a longer one need not come under a shorter.
  epoch: string
  timeout_ns: integer
  --- The program a test that runs this program runs
  --- ([`declared_key.program_identity`]), worked out once a key needs
  --- it ([`program_of`]).
  program: string
  --- The digest of the code that writes a closure store ([`Harness`]),
  --- and the set of the modules of the tree the binary carries, which
  --- a worker's loads are held to ([`worker.judge`]).
  store_salt: string
  carried: {string:boolean}
  --- Where an artifact runs the tests (o/bin/cosmic, or a
  --- portable cosmic), what runs its core
  --- ([`declared_key.launcher_identity`]), which every key holds; nil
  --- where a host program does.
  launcher: string
  unkeyed: {string:string}
  --- Whether each module's workers can be kept from running this
  --- program ([`can_forbid`]), by module path.
  forbiddable: {string:boolean}
  --- Where the host caches each module declares are ([`build.caches`]),
  --- by module path, as [`caches_of`] resolves them.
  caches: {string:{string}}
  --- Each selected module's import closure, by path: the names of its
  --- modules, which its worker holds its `require`s to
  --- ([`test_inputs.modules`], [`build.test_worker`]).
  closures: {string:{string}}
  --- The requires a closure does not follow, which make no module a
  --- worker loads ([`test.type_only_imports`]).
  type_only: {string:{string:boolean}}
  --- The same, each a set of names, made as a verdict needs one
  --- ([`closure_set`]).
  closure_sets: {string:{string:boolean}}
  --- The sandbox plan of the first worker started of each module, by path,
  --- and the scratch directory it was made for: a later worker of the
  --- module takes it rebound to its own ([`test_sandbox.rebind`]).
  plans: {string:PlanMade}
  --- A module's hit lines as a `coverage_by_test` row holds them, and the
  --- lines [`take_hits`] has folded into `hits`, each by the table
  --- [`worker.decode`] shares among the reports that held them. Per run:
  --- a table folded into another run's `hits` is not in this one's.
  spelled: {{integer:boolean}:string}
  folded: {{integer:boolean}:boolean}
  --- Every module of the tree, by path, sorted: what a worker refuses a
  --- `require` of outside its closure ([`build.test_worker`]).
  tree_names: {string}
  --- The address of the store of each module's import closure its
  --- workers are given at o/cosmic.db, or attach unsandboxed
  --- ([`build.closure_store`]'s `write`), by path, for every test and
  --- example module of the tree that does not declare `store`; the
  --- projection that store is derived from, its basis, and each store
  --- built or found this run, by address ([`store_at`]). A key holds a
  --- store by its bytes ([`declared_key.store_digest`]), the address
  --- only where it is and whether it must be written.
  stores: {string:string}
  --- What sealing the databases of the workers that run on one needs,
  --- made the first time one is: the directory they are written in, the
  --- program's own database written there ([`sealing_for`]); the reason
  --- there is none, or nil before it is made.
  sealing: Sealing | nil
  sealing_trouble: string | nil
  --- The path of the sealed database of each closure store, by its
  --- address ([`sealed_for`]).
  sealed: {string:string}
  --- How many sealed databases this run wrote, their bytes, and the time
  --- taken ([`sealed_for`]).
  sealed_written: integer
  sealed_bytes: integer
  sealed_ns: integer
  projection: string
  basis: closure_store.Basis
  built: {string:string}
  --- The address of the store of no module, which holds what every
  --- closure store holds alike -- the schema, as the code that writes
  --- it lays it out, and the `meta` rows each keeps -- and which the
  --- census names by its bytes ([`base_store_digest`]).
  base_store: string
  --- The digest of the bytes of each store this run keyed a test by, by
  --- address ([`address_digest`]), and whether it may take one from the
  --- shared verdicts: not under `--no-shared`, which stands on nothing
  --- another checkout kept. And the core the stores' addresses are
  --- salted with: the runtime's identity, less the run's other parts.
  store_digests: {string:string}
  consult_shared: boolean
  store_runtime: string
  --- The identity of the core the run's workers run ([`declared_key.runtime_identity`]),
  --- which the key of a worker on a sealed database holds in place of the
  --- launcher ([`seals`]).
  core: string
  --- The digest of the program's modules the tree lacks ([`extras_digest`]).
  extras: string | nil
  --- What the shared verdicts keep of each address this run looked up
  --- ("" for none), the closure and kind each address was keyed for, and
  --- the addresses whose bytes it found to differ, said once each.
  store_kept: {string:string}
  store_names: {string:{string}}
  store_bases: {string:boolean}
  store_mismatched: {string:boolean}
  --- How many of them this run wrote, their bytes, and the time taken.
  written: integer
  written_bytes: integer
  writing_ns: integer
end

--- The environment the workers of `m`'s tests are given, which a
--- variable they read is keyed by: what a sandbox gives one
--- ([`test_sandbox.environment`]), TMPDIR its scratch directory; one
--- unsandboxed has the host's cores cache in place of the sandbox's own
--- ([`test_sandbox.unenforced_view`]), as it is given.
local function view_of(rec: Recording, m: importer.Module): {string:string}
  local view = rec.views[m.path]
  if view == nil then
    local effective = rec.effective[m.path]
    view = rec.sandbox and test_sandbox.environment(worker_view(), effective) or
      test_sandbox.unenforced_view(worker_view(), effective)
    rec.views[m.path] = view
  end
  return view
end

--- Where the tree is, for a `host` path that must not be it, beneath
--- it or above it ([`test_inputs.resolved`]): its path and where that
--- resolves.
local function tree_roots(rec: Recording): {string}
  return { rec.root, confine.resolution(rec.root) }
end

--- Why `m`'s `host` paths cannot all be given to its workers
--- ([`test_inputs.resolved`]): "" where they can. Every test of such a
--- module fails before its worker starts, sandboxed or not.
local function unresolved(rec: Recording, m: importer.Module): string
  local effective = rec.effective ~= nil and rec.effective[m.path] or nil
  if effective ~= nil then return effective.unresolved or "" end
  for _, declared in ipairs(m.inputs ~= nil and m.inputs.host or {}) do
    local path, trouble = test_inputs.resolved(declared, tree_roots(rec))
    if path == nil then return trouble end
  end
  return ""
end

--- Where the host caches `m` declares are ([`build.caches`]), as every
--- worker's environment locates them: what its test may read and write
--- that no key holds.
local function caches_of(rec: Recording, m: importer.Module): {string}
  local found = rec.caches[m.path]
  if found == nil then
    local declared = m.inputs
    found = declared ~= nil and host_caches.all(declared.caches or {}, rec.root, worker_view()) or {}
    rec.caches[m.path] = found
  end
  return found
end

--- What names this checkout among the shared rows: an id made the
--- first time its o/build.db is asked for one and kept in its `meta`,
--- so a checkout made again at the same path is another checkout, and
--- one whose o/ is removed is too.
local function checkout_id(records: Sqlite.Handle, root: string, now_ns: integer): string
  local rows, _ = Sqlite.text_rows(records, "SELECT value FROM meta WHERE key = 'checkout'")
  if rows ~= nil and rows[1] ~= nil then return rows[1][1] end
  local made = hex_sha256(root .. "\0" .. tostring(now_ns) .. "\0" ..
      tostring(Clock.monotonic_ns()) .. "\0" .. tostring({}))
  local _, _ = Sqlite.run(records, "INSERT OR REPLACE INTO meta (key, value) VALUES ('checkout', ?1)",
    { text(made) })
  return made
end

--- Stops using the shared verdicts for the rest of the run, saying why
--- once: a cache that cannot answer -- corrupt, or another format's --
--- costs the run nothing but what it would have saved.
local function drop_shared(rec: Recording, trouble: string)
  if rec.shared == nil then return end
  local path = rec.shared.path
  shared_verdicts.close(rec.shared)
  rec.shared = nil
  -- TODO: retire broken caches automatically once cache-wide lifetime
  -- ownership and identity checks can exclude concurrent users and replacements.
  log:complain("test: shared verdicts: " .. path .. ": " .. trouble ..
      "; running without them")
end

--- Whether a sandboxed worker of `m`'s tests can be kept from running
--- this program where its module does not declare `tool`
--- ([`confine.forbid_running`]): not where it may write a directory
--- the program is in ([`test_sandbox.forbiddable`]), since a core another
--- cosmic extracts there after the worker holds itself could not be
--- run. The cores a portable cosmic extracts, where the program's own
--- core is, are none of them: a worker that declares the `bootstrap`
--- cache has cores of its own ([`test_sandbox.cache_writes`]). Such a
--- worker is keyed as if it declared `tool` instead.
local function can_forbid(rec: Recording, m: importer.Module): boolean
  local found = rec.forbiddable[m.path]
  if found ~= nil then return found end
  rec.tool = rec.tool or confine.itself()
  found = test_sandbox.forbiddable(test_sandbox.cache_writes(rec.effective[m.path],
    worker_view()), rec.tool)
  rec.forbiddable[m.path] = found
  return found
end

--- Whether a worker of `m`'s tests runs on a sealed database of its
--- closure ([`sealed_for`]): the program's core on that database
--- (`core --database`) with nothing of the program's file, so what the
--- worker and every process it starts reads of the program is what its
--- key holds -- its closure's store and the modules every worker loads. It
--- is so wherever the worker is given a closure's store and runs
--- not this program (`tool`), and this program is a portable artifact
--- whose database and core there are to take; a worker that confines
--- processes in roots of its own (`nests`) is sealed too, its policy
--- carrying `nest` beside the `database`. Its key holds the
--- core in place of the launcher ([`declared_of`]), which no such worker
--- runs. Every other worker runs the program.
local function seals(rec: Recording, m: importer.Module): boolean
  local effective = rec.effective[m.path]
  if rec.launcher == nil or rec.stores == nil or rec.stores[m.path] == nil or
      effective == nil or effective.store or effective.tool then
    return false
  end
  local launched, _ = Proc.relaunch()
  return launched ~= nil and launched.argv[2] == "--artifact" and launched.argv[3] ~= nil
end

--- How a sandboxed worker of `m`'s tests stands to running this
--- program: "declared" where its module declares `tool`; "sealed" where
--- it declares `lua` or `nests` and runs on a sealed database of its
--- closure ([`sealed_for`]), which it may run the core on but which holds no
--- more of the program than its closure, so its key holds no more;
--- "forbidden" where it is kept from running it ([`can_forbid`]), and
--- "allowed" where it is not -- its module declares `nests` or `lua` and
--- runs the program whole, or it cannot be -- which its key holds as if
--- its module declared `tool` ([`Spec.runs_tool`]). Its key and its command
--- line ([`hold_of`]) both take it from here.
local enum ToolUse
  "declared"
  "sealed"
  "forbidden"
  "allowed"
end

local function tool_use(rec: Recording, m: importer.Module): ToolUse
  local effective = rec.effective[m.path]
  if effective.tool then return "declared" end
  if effective.lua or effective.nests then return seals(rec, m) and "sealed" or "allowed" end
  return can_forbid(rec, m) and "forbidden" or "allowed"
end

--- How a worker of `m`'s tests is held by a Landlock ruleset
--- ([`worker.Hold`]): not at all unsandboxed, nor where its module declares
--- `nests`, which lets its tests confine a process in a root of its own;
--- to running anything but this program where it may not run it
--- ([`tool_use`]); and otherwise to running anything, which holds it to
--- making no root of its own, since the kernel refuses every mount under
--- a ruleset.
local function hold_of(rec: Recording, m: importer.Module): worker.Hold
  if not rec.sandbox or rec.effective[m.path].nests then return "none" end
  return tool_use(rec, m) == "forbidden" and "forbid" or "mounts"
end

--- Whether a worker of `m`'s tests can read the compiler's identity,
--- which it reads from the running tool ([`declared_key.reads_compiler`]):
--- not one given the whole projection, which carries its own and is
--- keyed by its contents; nor one whose closure holds a reader only by
--- what `lua` adds to it ([`test_inputs.compiler_sought`]).
local function reads_compiler(rec: Recording, m: importer.Module): boolean
  if rec.stores[m.path] == nil then return false end
  return declared_key.reads_compiler(test_inputs.compiler_sought(rec.closures[m.path] or {},
    rec.effective[m.path].lua))
end

--- The digest of the modules of the program's own database that the tree
--- lacks -- the standard library, in a project's tree -- by path, source
--- hash and bytecode, which a sealed database carries whole
--- ([`sealed_fill`]) and so a key of a worker on one holds
--- ([`declared_of`]). Worked out once a run needs it, from the program's
--- own database, which sealing nothing reads; "unread" where it cannot be.
local function extras_digest(rec: Recording): string
  if rec.extras ~= nil then return rec.extras end
  local databases = Store.databases()
  local rows, _ = Sqlite.text_rows(databases[#databases],
    "SELECT path, lower(hex(source_hash)), lower(hex(sha256(bytecode))) FROM modules ORDER BY path")
  local digest = "unread"
  if rows ~= nil then
    local in_tree: {string:boolean} = {}
    for _, name in ipairs(rec.tree_names) do in_tree[name] = true end
    local lines: {string} = {}
    for _, row in ipairs(rows) do
      if not in_tree[row[1]] then lines[#lines + 1] = table.concat(row, "\0") end
    end
    digest = hex_sha256(table.concat(lines, "\n"))
  end
  rec.extras = digest
  return digest
end

--- The digest of the store `m`'s workers are given, which its key holds
--- (defined with the stores, below).
local store_digest: function(rec: Recording, m: importer.Module): string | nil, string

--- The program a test that runs this program runs
--- ([`Recording.program`]), worked out the first time a key holds it.
--- Digesting the program reads every row its database carries, some
--- 0.2 s, which a run none of whose tests runs it need not spend.
local function program_of(rec: Recording): string
  if rec.program == nil then
    rec.tool = rec.tool or confine.itself()
    rec.program = declared_key.program_identity(rec.digests, rec.tool)
  end
  return rec.program
end

--- A sandboxed test's key, over its declared inputs as they are now
--- ([`build.declared_key`]): nil for one that reads a link out of the
--- tree, which no key holds, said once in `rec.unkeyed`.
---
--- A key holds a file of the tree by its contents, and none of what a
--- stat says of it but what its declared inputs' digests do, so a
--- verdict one checkout reached stands in another of the same content.
--- The rule that makes that sound: a test must not depend on the times,
--- inode, device, link count or owner of a file it did not make. One
--- that needs them makes its own files in its temporary directory and
--- sets them -- `utimensat` for the times, a fresh file for a new inode
--- -- so they are the same in every checkout.
-- TODO: enforce the rule in the worker, which holds only `require` to its
-- closure today: have `stat`, `lstat` and `fstat` of a path of the tree
-- answer fixed times and inode there, once core/syscalls_fs.c's stat takes a
-- hold from build.test_worker (C, and a boot):
-- today a test that leans on a file of the tree's times sees what its
-- checkout gave it, and stands on a sibling's verdict where they differ.
local function declared_of(rec: Recording, m: importer.Module, id: string): string | nil
  local effective = rec.effective[m.path]
  local runs_tool = tool_use(rec, m) == "allowed"
  local store, store_trouble = store_digest(rec, m)
  if store == nil and store_trouble ~= "" then
    rec.unkeyed[m.path] = store_trouble
    return nil
  end
  local key, why = declared_key.compute(rec.digests, {
    id = id, group = m.path, module_key = m.graph_key, runtime = rec.runtime,
    compiler = reads_compiler(rec, m) and rec.compiler or "",
    host = rec.host,
    system = rec.system,
    epoch = rec.epoch, timeout_ns = rec.timeout_ns,
    -- Held only where the key holds the program ([`declared_key.compute`]).
    program = (effective.tool or runs_tool) and program_of(rec) or nil,
    launcher = seals(rec, m) and (rec.core .. "\0" .. extras_digest(rec)) or rec.launcher,
    declaration = test_inputs.canonical(m.inputs), effective = effective,
    requires = rec.answered[m.path],
    environment = view_of(rec, m), runs_tool = runs_tool,
    closure_store = store,
    -- Unsandboxed, its worker sees the tree where it is (`launch`).
    tree = not rec.sandbox and rec.root or nil,
  })
  if key == nil then rec.unkeyed[m.path] = why end
  return key
end

--- Records one test answered from its standing verdict.
local function stand(rec: Recording, credited: test.Credited, m: importer.Module,
                     name: string, id: string, stood: test.Verdict, key: string)
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
  kept, keep_trouble = record_verdict(rec.records, key, true, stood.run_at_ns, rec.run,
    stood.elapsed_ns)
  if not kept then
    rec.errors[#rec.errors + 1] = id .. ": verdict: " .. keep_trouble
  end
  local shared_key = rec.shared_keys[key]
  if shared_key ~= nil then rec.owed.used[#rec.owed.used + 1] = shared_key end
end

--- Records one sandboxed test answered from the verdict another
--- checkout reached under its declared `key` (`found`): as this run's
--- own, with the lines that run hit, so a later run of this checkout
--- stands on it without the shared cache.
local function share(rec: Recording, m: importer.Module, name: string, id: string,
                     key: string, found: shared_verdicts.Found)
  rec.tally.cached = rec.tally.cached + 1
  rec.tally.shared = rec.tally.shared + 1
  local hit: Coverage.Hits = {}
  decode_hits(found.hits, hit)
  for path in pairs(rec.unowned) do
    hit[path] = nil
  end
  merge_hits(rec.hits, hit)
  rec.by_test[id] = encode_hits(hit)
  local elapsed = found.elapsed_ns
  local kept, keep_trouble = record_run(rec.records, m.path, name, true, "",
    Clock.now_ns(), run_key(key, key), rec.run_at_ns, elapsed)
  if not kept then
    rec.errors[#rec.errors + 1] = id .. ": record: " .. keep_trouble
  end
  kept, keep_trouble = record_verdict(rec.records, key, true, rec.run_at_ns, rec.run,
    elapsed)
  if not kept then
    rec.errors[#rec.errors + 1] = id .. ": verdict: " .. keep_trouble
  end
  rec.owed.used[#rec.owed.used + 1] = key
end

--- The set of the names of `m`'s import closure (`closures`), made
--- once a run.
local function closure_set(rec: Recording, m: importer.Module): {string:boolean}
  local set = rec.closure_sets[m.path]
  if set == nil then
    set = {}
    for _, name in ipairs(rec.closures[m.path] or {}) do set[name] = true end
    rec.closure_sets[m.path] = set
  end
  return set
end

--- A module's hit lines as a row of `coverage_by_test` holds them
--- ([`encode_hits`]'s line), kept in `spelled` by the table
--- [`worker.decode`] shares among the reports that held them.
local function spell(spelled: {{integer:boolean}:string}, path: string,
                     per_line: {integer:boolean}): string
  local row = spelled[per_line]
  if row == nil then
    local lines: {integer} = {}
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
                        folded: {{integer:boolean}:boolean},
                        spelled: {{integer:boolean}:string},
                        load_hits: Coverage.Hits, test_hits: Coverage.Hits): string
  local out: {string} = {}
  for _, taken in ipairs({ load_hits, test_hits }) do
    local paths: {string} = {}
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

--- Records one finished job: the verdict its worker reported, or a
--- failure that says why there is no report to go by
--- ([`build.test_worker`]'s `judge`). A key holds what a worker
--- runs by [`worker.loads`] and the test's closure, so a worker that ran a
--- module of the tree the tool carries beyond both fails its test.
local function finish(rec: Recording, job: Job, result: Child.Result,
                      trouble: string, limits: test.Limits, refused?: boolean, unavailable?: string)
  rec.tally.ran = rec.tally.ran + 1
  local id = job.id
  local wall_ns = Clock.monotonic_ns() - job.started_ns
  local judged: worker.Judgement
  if unavailable ~= nil then
    judged = { passed = true, skipped = unavailable, message = "" }
  else
    judged = worker.judge({
      result = result, trouble = trouble, timeout_ns = limits.timeout_ns,
      sandboxed = rec.sandbox, refused = refused == true,
      carried = rec.carried,
      closure = closure_set(rec, job.m),
    })
  end
  local reported, passed, message = judged.report, judged.passed, judged.message
  -- A pass the test said it could not check ([`Test.skip`]) is kept as no
  -- verdict, pass or fail, so it runs again on the next run -- and on a
  -- host that can check it, whose key differs, as its own.
  local skipped = judged.passed and judged.skipped or ""
  if skipped ~= "" then
    -- A reason may carry what a failed start printed: the report lists
    -- one line each.
    skipped = skipped:match("^[^\n]+") or "the host refused what the test is about"
    rec.tally.skipped = rec.tally.skipped + 1
    rec.skips[#rec.skips + 1] = id .. ": " .. skipped
    message = "skipped: " .. skipped
  end
  -- A pass that made no call to `assert` is listed, a
  -- held run fails it, and no run keeps a verdict of it, so it is met again
  -- every run -- a standing verdict would hide it from the summary and from
  -- a held run that did not run it.
  -- An example (`*_example.tl`) shows how code is used and is not held to it:
  -- it passes by running.
  local unchecked = passed and judged.unchecked == true and job.m.kind == "test"
  if unchecked then
    rec.tally.unchecked = rec.tally.unchecked + 1
    rec.unchecked[#rec.unchecked + 1] = id
    if rec.held then
      passed = false
      message = "made no call to assert, so its pass shows only that it did not raise" ..
        " (a held run fails that)\n  to fix: assert what it exists to show, a helper that" ..
        " checks through error or pcall calling assert; where this host cannot check it," ..
        " declare `requires` or call Test.skip(reason)"
    end
  end
  -- A test that said why it did not check keeps its verdict: its pass is a
  -- function of its key, and it is counted apart.
  if passed and judged.deliberate ~= nil and judged.deliberate ~= "" then
    rec.deliberate[#rec.deliberate + 1] = judged.deliberate:match("^[^\n]+") or judged.deliberate
  end
  -- What the records keep: a skip is no pass, nor is a pass that made no call to `assert`.
  local kept_pass = passed and skipped == "" and not unchecked
  local elapsed = wall_ns
  if reported ~= nil then
    elapsed = reported.elapsed_ns
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
  if key == nil and not job.unrun then rec.tally.every = rec.tally.every + 1 end
  local held = key ~= nil and declared_of(rec, job.m, id) == key
  local saved, save_trouble = record_run(rec.records, job.m.path, job.name, kept_pass,
    message, Clock.now_ns(), run_key(key or "", key), rec.run_at_ns, elapsed)
  if not saved then
    rec.errors[#rec.errors + 1] = id .. ": record: " .. save_trouble
  end
  if held and skipped == "" and not unchecked then
    saved, save_trouble = record_verdict(rec.records, key, passed, rec.run_at_ns, rec.run,
      elapsed)
    if not saved then
      rec.errors[#rec.errors + 1] = id .. ": verdict: " .. save_trouble
    end
  elseif key ~= nil and not passed then
    -- Its inputs moved while it ran, so the failure is of no one state
    -- of them -- but it may be of the one it started from, and a pass
    -- kept under that key would stand for it: gone.
    saved, save_trouble = Sqlite.run(rec.records, "DELETE FROM verdicts WHERE key = ?1",
      { text(key) })
    if not saved then
      rec.errors[#rec.errors + 1] = id .. ": verdict: " .. save_trouble
    end
  end
  -- A pass another run shared under its key goes too where it failed.
  if key ~= nil and not passed then
    rec.owed.failed[#rec.owed.failed + 1] = key
  elseif kept_pass and held and reported ~= nil then
    rec.owed.kept[#rec.owed.kept + 1] = { key = key, test = id, hits = rec.by_test[id],
      elapsed_ns = elapsed }
  end
  job.passed = passed
  if not passed then
    if job.scratch ~= nil then
      message = message .. "\n  its directory is kept: " .. job.scratch .. "/real"
    elseif job.own_scratch then
      message = message .. "\n  its directory was a tmpfs of its worker's own, gone with it " ..
        "(" .. test_sandbox.switch .. "=0 keeps one on the host; a fuzz failure's \"kept\" path " ..
        "above is in it too: rerun with the FUZZ_CASE it names)"
    end
    local failure = id .. ": " .. message
    rec.failures[#rec.failures + 1] = failure
    rec.failed[failure] = id
    rec.reruns[id] = job.m.file .. ":" .. job.name
    if result ~= nil and result.stdout ~= nil and result.stdout ~= "" then
      rec.outputs[id] = result.stdout
    end
  end
end

--- What of this process's environment says how it was started and
--- nothing a test is given: the marker a tool that rebuilt itself sets
--- for the process it re-enters ([`build.reboot`]), which a run started
--- after a rebuild holds and one started fresh does not, and the
--- directory the invoking shell was in before its last `cd`, and the
--- command it last ran (`_`, which a shell sets to the program it
--- starts: /usr/bin/timeout for `timeout 30 cosmic test`). Kept, each
--- would enter the key of a test that declares it, and such a test would
--- run again after a rebuild, a `cd`, or a run started another way. So too
--- the shell's depth (`SHLVL`): a run from a script, rather than a
--- terminal, would run such a test again.
local launch_only: {string:boolean} = { COSMIC_REBOOTED = true, OLDPWD = true, SHLVL = true, _ = true }

--- The environment a worker starts with: this process's, less
---
--- - the private startup hooks (`COSMIC_PORTABLE_STARTUP_TEST_*`), which
---   pause one startup of a fixture runtime for a handshake and belong to
---   this process's own launch, not to every worker it starts;
--- - what `launch_only` names; and
--- - COSMIC_TEST_NO_SHARED;
---
--- and with the shared verdict cache off (`COSMIC_VERDICT_CACHE=0`) and
--- the shared compiles too (`COSMIC_BUILD_CACHE=0`).
function test.worker_environment(environment: {string:string}): {string:string}
  local out: {string:string} = {}
  for name, value in pairs(environment) do
    if name:sub(1, 29) ~= "COSMIC_PORTABLE_STARTUP_TEST_" and not launch_only[name] then
      out[name] = value
    end
  end
  -- A run of `cosmic test` a test starts neither reads nor writes the
  -- verdicts every checkout shares, unless the test names a cache of
  -- its own.
  shared_verdicts.turn_off(out)
  -- Nor the compiles and parses every checkout shares: a build a test
  -- starts compiles and parses what it does, and reaches no file
  -- outside what the test declares, unless the test names a cache of
  -- its own.
  shared_compiles.turn_off(out)
  -- Nor does it take this run's choice not to stand on them: a test
  -- that runs `cosmic test` says for itself what that run does.
  out.COSMIC_TEST_NO_SHARED = nil
  out.COSMIC_TEST_NOEXEC = nil
  -- Nor a rebuild lock handed to this run (build.rebuild_lock): what a
  -- test starts holds none of this run's.
  return rebuild_lock.unhanded(out)
end

-- Read once, since this process never changes its own environment.
local worker_view_memo: {string:string} = nil
worker_view = function(): {string:string}
  if worker_view_memo == nil then worker_view_memo = test.worker_environment(Env.all()) end
  return worker_view_memo
end

--- A fresh scratch directory for one test, resolved (so nothing in
--- its own path is a link, even where the system temp directory is
--- one), holding `real`, an empty directory, and `tmp`, a link to it
--- by the relative name `real`: the test is handed `<scratch>/tmp`.
--- The worker makes `children` there for the coverage its test's
--- processes report.
--- Removing the scratch directory with [`Fs.remove_tree`] removes the
--- link without following it, and the real directory beside it.
-- TODO: keep the link, which a sandboxed worker sees in [`test_sandbox.scratch`] as an
-- unsandboxed one sees it under the host's temporary directory: it
-- stands in for macOS's /var on every host, and does not depend on
-- where the checkout is. Drop it only once a case of its own on the
-- macOS leg catches a path resolved on one side of a comparison and not
-- the other, which the link catches on every leg today.
function test.scratch(): string | nil, string
  -- Padded so the scratch directory's path is as long on this host as
  -- a sandbox's is, and as macOS's is ([`test_sandbox.scratch_length`]),
  -- past the temporary directory's resolved path and mkdtemp's six.
  local base, base_trouble = Fs.absolute(Env.get_or("TMPDIR", "/tmp"))
  if base == nil then return nil, base_trouble end
  local separator = base:sub(-1) == "/" and 0 or 1
  local made, trouble = Fs.mkdtemp(test_sandbox.padded("cosmic-test-",
    test_sandbox.scratch_length - #base - separator - 6))
  if made == nil then return nil, trouble end
  local scratch, absolute_trouble = Fs.absolute(made)
  if scratch == nil then
    local _, _ = Fs.remove_tree(made)
    return nil, absolute_trouble
  end
  local ok, why = Fs.mkdirs(scratch .. "/real")
  if ok then ok, why = Fs.symlink("real", scratch .. "/tmp") end
  if not ok then
    local _, _ = Fs.remove_tree(scratch)
    return nil, why
  end
  return scratch, ""
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
    if (ended or job.passed) and job.scratch ~= nil then
      local gone, trouble = Fs.remove_tree(job.scratch)
      if not gone then
        rec.errors[#rec.errors + 1] = job.id .. ": could not remove its directory " ..
          job.scratch .. ": " .. trouble
      end
      job.scratch = nil
    end
  end
end

--- Where the tree at `root` keeps the stores of its test modules'
--- import closures, each named by its address ([`build.closure_store`]'s
--- `address`).
local function stores_directory(root: string): string
  return root .. "/o/stores"
end

--- The name in the stores directory of the store of no module
--- ([`Recording.base_store`]), at `address`: apart from the closures'
--- stores, which this run's counts and a test's listing of them leave it
--- out of.
local function base_name(address: string): string
  return "base-" .. address .. ".db"
end

--- The address of the closure store of each test and example module of
--- `modules` that does not declare `store`, by path, over the
--- projection `rec.projection` ([`closure_store.basis`]): every one the tree
--- has, selected or not, so a run that selects some leaves the others'
--- stores, and [`sweep_stores`] takes out only what no module names.
local function address_stores(rec: Recording, modules: {importer.Module},
                              by_path: {string:importer.Module},
                              declarations: {string:string}): boolean, string
  local basis, trouble = closure_store.basis(rec.projection)
  if basis == nil then return false, trouble end
  rec.basis, rec.stores, rec.built, rec.store_digests = basis, {}, {}, {}
  rec.sealed = {}
  rec.sealed_written, rec.sealed_bytes, rec.sealed_ns = 0, 0, 0
  rec.store_kept, rec.store_names, rec.store_bases, rec.store_mismatched = {}, {}, {}, {}
  -- The code that writes a store, and the core that runs it -- SQLite
  -- and its bindings -- whose bytes it follows from too: so one address
  -- names one store's bytes wherever it is written, which a digest kept
  -- by address relies on ([`address_digest`]).
  local salt = hex_sha256(rec.store_salt .. "\0" .. rec.store_runtime)
  rec.base_store = closure_store.address(basis, {}, salt)
  rec.written, rec.written_bytes, rec.writing_ns = 0, 0, 0
  for _, m in ipairs(modules) do
    local declared = m.inputs
    if (m.kind == "test" or m.kind == "example") and
        not (declared ~= nil and declared.store) then
      local names = rec.closures[m.path] or
        test_inputs.modules(m, by_path, declarations, rec.type_only)
      rec.closures[m.path] = names
      rec.stores[m.path] = closure_store.address(basis, names, salt)
    end
  end
  return true, ""
end

--- Takes out of the stores directory every entry no module of this run
--- names ([`address_stores`]): a closure edited since, or a module gone,
--- leaves a store nothing will ask for again, and one cut short (a
--- `.building` file) is written again from the start. A failure to
--- take one out costs only room, and is said once.
local function sweep_stores(rec: Recording)
  local directory = stores_directory(rec.root)
  local named: {string:boolean} = {}
  for _, address in pairs(rec.stores) do named[address .. ".db"] = true end
  named[base_name(rec.base_store)] = true
  local listed, _ = Fs.list(directory)
  for _, entry in ipairs(listed or {}) do
    -- One kept aside for a report ([`mismatch_path`]) stays until removed.
    if not named[entry] and not entry:match("%.mismatch%.db$") then
      local gone, trouble = Fs.remove(directory .. "/" .. entry)
      if not gone then
        log:complain("test: " .. directory .. "/" .. entry .. ": " .. trouble)
        return
      end
    end
  end
end

--- The path of the closure store at `address`, of the import closure
--- `names`, made from the projection where it is not there yet --
--- written aside and moved into place, so a store there is whole; nil
--- and why where it could not be made. `base` names the store of no
--- module ([`base_name`]), which the counts of stores written leave out.
local function store_at(rec: Recording, address: string, names: {string},
                        base?: boolean): string | nil, string
  local path = rec.built[address]
  if path ~= nil then return path, "" end
  local directory = stores_directory(rec.root)
  path = directory .. "/" .. (base and base_name(address) or (address .. ".db"))
  local there, _ = sys.stat(path)
  if there == nil then
    local made, trouble = Fs.mkdirs(directory)
    if not made then return nil, directory .. ": " .. trouble end
    local started = Clock.monotonic_ns()
    local written, write_trouble = closure_store.write(rec.projection, path, names, rec.basis)
    if not written then return nil, "the store of its closure: " .. write_trouble end
    if not base then
      rec.writing_ns = rec.writing_ns + (Clock.monotonic_ns() - started)
      local wrote, _ = sys.stat(path)
      rec.written = rec.written + 1
      rec.written_bytes = rec.written_bytes + (wrote ~= nil and wrote.size or 0)
    end
  end
  rec.built[address] = path
  return path, ""
end

--- The path of the closure store a worker of `m`'s tests is given
--- ([`store_at`]), or nil where `m` declares `store` and is given the
--- whole projection; nil and why where it could not be made.
local function given_store(rec: Recording, m: importer.Module): string | nil, string
  local address = rec.stores ~= nil and rec.stores[m.path] or nil
  if address == nil then return nil, "" end
  return store_at(rec, address, rec.closures[m.path])
end

--- The tables of a sealed database as the core reads them
--- (core/store.c), the columns of build/schema.tl's: [`Store.seal`]'s,
--- which writes the same from the store's search order, restated here
--- since a closure's modules are rows of its store, which the runner's own
--- search order does not carry (the tree's tests are in none of the
--- program's databases).
local sealed_schema <const>: {string} = {
  "PRAGMA page_size = 4096",
  "PRAGMA auto_vacuum = 0",
  "PRAGMA encoding = 'UTF-8'",
  "CREATE TABLE meta (key TEXT PRIMARY KEY, value BLOB) WITHOUT ROWID",
  "CREATE TABLE modules (path TEXT PRIMARY KEY NOT NULL, file TEXT NOT NULL, " ..
    "kind TEXT NOT NULL, source_hash BLOB NOT NULL, key BLOB NOT NULL, " ..
    "bytecode BLOB NOT NULL, tests TEXT NOT NULL, source BLOB NOT NULL)",
  "CREATE TABLE imports (path TEXT NOT NULL, requires TEXT NOT NULL, " ..
    "PRIMARY KEY (path, requires)) WITHOUT ROWID",
  "CREATE TABLE decls (path TEXT PRIMARY KEY, source BLOB NOT NULL) WITHOUT ROWID",
  "CREATE TABLE zoneinfo (name TEXT PRIMARY KEY, data BLOB NOT NULL)",
  "CREATE TABLE ca_roots (sha256 BLOB NOT NULL, label TEXT NOT NULL, der BLOB NOT NULL)",
}

--- The statements [`write_sealed`] runs to fill a sealed database from
--- `closure` (a worker's closure store), `program` (the program's own
--- database) and `whole` (the projection the store was written from), with
--- `temp.extra` the program's modules that go along: what every worker loads
--- and every module the tree lacks (the standard library, in a project's
--- tree), which a worker's key holds by their digest ([`extras_digest`]).
--- The key and the tests of a module are left empty (the compile's, and the
--- tree's own). The time zones and CA roots go only where the set holds the
--- module that reads them, as [`Store.seal`] does: they are most of a small
--- database's bytes.
-- TODO: carry only the standard library a closure requires, in a project's
-- tree, once the projection's `imports` rows record the requires of its
-- modules that name no module of the tree (today they are edges within the
-- tree alone, so what a closure requires of the library is not known without
-- parsing every module's source): every worker of a project's tree reads
-- the whole of the program's library through [`Store.bytecode`] and the
-- rest, as the artifact of a closure it replaced carried it.
local sealed_fill <const>: {string} = {
  "INSERT OR IGNORE INTO temp.extra SELECT path FROM program.modules WHERE path NOT IN " ..
    "(SELECT path FROM whole.modules)",
  "INSERT INTO main.modules SELECT path, file, kind, source_hash, X'', bytecode, '', source " ..
    "FROM closure.modules ORDER BY path",
  "INSERT OR IGNORE INTO main.modules SELECT path, file, kind, source_hash, X'', bytecode, '', " ..
    "source FROM program.modules WHERE path IN temp.extra ORDER BY path",
  "INSERT INTO main.decls SELECT path, source FROM closure.decls ORDER BY path",
  "INSERT OR IGNORE INTO main.imports SELECT path, requires FROM closure.imports " ..
    "WHERE path IN (SELECT path FROM main.modules) AND requires IN " ..
    "(SELECT path FROM main.modules) ORDER BY path, requires",
  "INSERT OR IGNORE INTO main.imports SELECT path, requires FROM program.imports " ..
    "WHERE path IN temp.extra AND requires IN (SELECT path FROM main.modules) " ..
    "ORDER BY path, requires",
  "INSERT INTO main.zoneinfo SELECT name, data FROM program.zoneinfo WHERE EXISTS " ..
    "(SELECT 1 FROM main.modules WHERE path = 'cosmic.time') ORDER BY name",
  "INSERT INTO main.ca_roots SELECT sha256, label, der FROM program.ca_roots WHERE EXISTS " ..
    "(SELECT 1 FROM main.modules WHERE path = 'cosmic.http') ORDER BY sha256",
}

--- What sealing the databases of this run's workers is made from
--- ([`Sealing`]), made the first time one is wanted: this program's own
--- database, taken from its artifact and written in a directory of the
--- run's own that the user a worker runs as can read (a root runner's
--- workers run as a user of their own, which the 0700 directory
--- [`Fs.mkdtemp`] makes is shut to; its parents are the temporary
--- directory's, which must be open to that user too: the start says if
--- not). Nil and why where there is none, said once.
local function sealing_for(rec: Recording): Sealing | nil, string
  if rec.sealing ~= nil then return rec.sealing, "" end
  if rec.sealing_trouble ~= nil then return nil, rec.sealing_trouble end
  local function refuse(why: string): nil, string
    rec.sealing_trouble = why
    return nil, why
  end
  local launched, _ = Proc.relaunch()
  if launched == nil or launched.argv[2] ~= "--artifact" or launched.argv[3] == nil then
    return refuse("this program is no portable artifact to take its database from")
  end
  local bytes, read_trouble = Fs.read(launched.argv[3])
  if bytes == nil then return refuse(launched.argv[3] .. ": " .. read_trouble) end
  local parts, split_trouble = artifact.split(bytes)
  if parts == nil then return refuse(launched.argv[3] .. ": " .. split_trouble) end
  if parts.host then
    return refuse(launched.argv[3] .. ": a host program has no database to seal from")
  end
  local database = parts.database
  -- A root runner's workers run as a user of their own, which must be
  -- able to search every directory above the database: the temporary
  -- directory's, or /tmp's where that is shut to it (a test's own
  -- directory, 0700, is where a nested run's temporary directory is); said
  -- once if neither is, not as an opaque refusal of every worker's start.
  local must_reach = rec.sandbox and sys.getuid() == 0
  --- The first directory above `path` that other users cannot search, as
  --- a sentence, or "".
  local function shut_above(path: string): string
    if not must_reach then return "" end
    local above = Fs.dirname(path)
    while above ~= "/" and above ~= "." do
      local there, _ = sys.stat(above)
      if there ~= nil and there.mode & 1 == 0 then
        return above .. " is not searchable by other users (mode " ..
          string.format("%o", there.mode & 0x1ff) .. "), so the user a worker runs as " ..
          "cannot reach its sealed database below it: open it, or set TMPDIR to a " ..
          "directory that is open"
      end
      above = Fs.dirname(above)
    end
    return ""
  end
  local made, made_trouble = Fs.mkdtemp("sealed-")
  if made == nil then return refuse("a directory for the sealed databases: " .. made_trouble) end
  local directory, real_trouble = sys.realpath(made)
  if directory == nil then
    local _, _ = Fs.remove_tree(made)
    return refuse(made .. ": " .. real_trouble)
  end
  local shut = shut_above(directory)
  if shut ~= "" then
    local _, _ = Fs.remove_tree(directory)
    -- /tmp's own, under a name no other run has.
    local elsewhere = string.format("/tmp/cosmic-sealed-%d-%d", sys.getpid(), Clock.monotonic_ns())
    local ok, mkdir_trouble = sys.mkdir(elsewhere, tonumber("755", 8))
    if not ok then return refuse(shut .. " (nor /tmp: " .. tostring(mkdir_trouble) .. ")") end
    directory = elsewhere
    shut = shut_above(directory)
    if shut ~= "" then
      local _, _ = Fs.remove_tree(directory)
      return refuse(shut)
    end
  end
  local function fail(why: string): nil, string
    local _, _ = Fs.remove_tree(directory)
    return refuse(why)
  end
  local opened, open_trouble = sys.chmod(directory, tonumber("755", 8))
  if not opened then return fail(directory .. ": " .. tostring(open_trouble)) end
  local path = directory .. "/program.db"
  local written, write_trouble = Fs.write(path, database)
  if not written then return fail(write_trouble) end
  rec.sealing = { directory = directory, program = path }
  return rec.sealing, ""
end

--- Takes out the directory of this run's sealed databases, once no worker
--- runs on one.
local function drop_sealing(rec: Recording)
  local sealing = rec.sealing
  if sealing == nil then return end
  rec.sealing, rec.sealed = nil, {}
  local gone, trouble = Fs.remove_tree(sealing.directory)
  if not gone then log:complain("test: " .. sealing.directory .. ": " .. trouble) end
end

--- Writes the sealed database of the closure store at `store`, which was
--- written from the projection `whole`, to `out`: [`sealed_fill`]'s
--- statements over them and the program's own database (`sealing`), the
--- modules every worker loads ([`worker.loads`]) going along, and the meta
--- rows the core on a database reads: the digest of this core, which it
--- checks, the runtime's basis and image, the compiler's identity where
--- the worker's key holds it (`with_compiler`), and the module that
--- runs. Written aside and moved into place, so one at `out` is whole.
local function write_sealed(sealing: Sealing, store: string, whole: string, out: string,
                            with_compiler: boolean): boolean, string
  local core = Store.meta("host_image")
  local basis = Store.meta("runtime_basis")
  if core == nil or core == "" or basis == nil or basis == "" then
    return false, "this process has no core digest or runtime basis to record"
  end
  local meta: {{string}} = { { "core_sha256", core }, { "main", "cmd.cosmic.main" },
    { "runtime_basis", basis } }
  for _, key in ipairs(with_compiler and { "image_hash", "compiler", "compiled_by" } or
        { "image_hash" }) do
    local value = Store.meta(key)
    if value ~= nil then meta[#meta + 1] = { key, value } end
  end
  local aside = out .. ".building"
  local _, _ = Fs.remove(aside)
  local opened, open_trouble = Sqlite.open(aside, { writable = true })
  if opened == nil then return false, aside .. ": " .. open_trouble end
  local db: Sqlite.Handle = opened
  local function fill(): boolean, string
    -- Written aside and moved into place whole, or not at all: a journal
    -- and a sync per commit would only cost time.
    for _, pragma in ipairs({ "PRAGMA journal_mode = OFF", "PRAGMA synchronous = OFF" }) do
      local ok, why = db:exec(pragma)
      if not ok then return false, why end
    end
    for _, statement in ipairs(sealed_schema) do
      local ok, why = db:exec(statement)
      if not ok then return false, why end
    end
    for _, attached in ipairs({ { "closure", store }, { "program", sealing.program },
        { "whole", whole } }) do
      local ok, why = Sqlite.run(db, "ATTACH DATABASE ?1 AS " .. attached[1],
        { { text = attached[2] } })
      if not ok then return false, why end
    end
    local filled, fill_trouble = Sqlite.transact(db, function(): boolean, string
      local ok, why = db:exec("CREATE TEMP TABLE extra (path TEXT PRIMARY KEY)")
      if not ok then return false, why end
      for _, name in ipairs(worker.loads) do
        local inserted, insert_trouble = Sqlite.run(db,
          "INSERT OR IGNORE INTO temp.extra (path) VALUES (?1)", { { text = name } })
        if not inserted then return false, insert_trouble end
      end
      for _, statement in ipairs(sealed_fill) do
        local done, done_trouble = db:exec(statement)
        if not done then return false, done_trouble end
      end
      for _, pair in ipairs(meta) do
        local inserted, insert_trouble = Sqlite.run(db,
          "INSERT INTO main.meta (key, value) VALUES (?1, ?2)",
          { { text = pair[1] }, { text = pair[2] } })
        if not inserted then return false, insert_trouble end
      end
      return true, ""
    end)
    local _, _ = db:exec("DETACH closure")
    local _, _ = db:exec("DETACH program")
    local _, _ = db:exec("DETACH whole")
    if not filled then return false, fill_trouble end
    return true, ""
  end
  local filled, fill_trouble = fill()
  local _, _ = db:close()
  if not filled then
    local _, _ = Fs.remove(aside)
    return false, fill_trouble
  end
  local readable, chmod_trouble = sys.chmod(aside, tonumber("644", 8))
  if not readable then
    local _, _ = Fs.remove(aside)
    return false, aside .. ": " .. tostring(chmod_trouble)
  end
  local moved, move_trouble = Fs.rename(aside, out)
  if not moved then
    local _, _ = Fs.remove(aside)
    return false, move_trouble
  end
  return true, ""
end

--- The path of the sealed database a worker of `m`'s tests runs on, made
--- where it is not there yet in the run's directory ([`sealing_for`]), once
--- per closure store however many modules share it: the modules of its
--- closure store, as its key holds it by its bytes, and the program's own
--- rows of what every worker loads and of what the tree lacks (the
--- standard library's, in a project's tree), which its key holds by the
--- harness's epoch and the runtime's identity. Nothing else of the
--- program goes along, so no `Store` read, searcher or `require` of a
--- worker or of a process it starts reaches a module its key does not hold.
--- Nil where `m`'s worker is not sealed ([`seals`]), and nil and why where
--- its database could not be made.
local function sealed_for(rec: Recording, m: importer.Module): string | nil, string
  if not seals(rec, m) then return nil, "" end
  local with_compiler = reads_compiler(rec, m)
  -- A worker whose key holds the compiler's identity reads it, so its
  -- database holds it: another file than a closure's that does not.
  local name = rec.stores[m.path] .. (with_compiler and "-compiler" or "")
  local kept = rec.sealed[name]
  if kept ~= nil then return kept, "" end
  local started = Clock.monotonic_ns()
  local sealing, sealing_trouble = sealing_for(rec)
  if sealing == nil then return nil, "its sealed database: " .. sealing_trouble end
  local store, store_trouble = given_store(rec, m)
  if store == nil then return nil, store_trouble end
  local path = sealing.directory .. "/" .. name .. ".db"
  local written, trouble = write_sealed(sealing, store, rec.projection, path, with_compiler)
  if not written then return nil, "its sealed database: " .. trouble end
  local wrote, stat_trouble = sys.stat(path)
  if wrote == nil then return nil, "its sealed database: " .. path .. ": " .. stat_trouble end
  rec.sealed_written = rec.sealed_written + 1
  rec.sealed_bytes = rec.sealed_bytes + wrote.size
  rec.sealed_ns = rec.sealed_ns + (Clock.monotonic_ns() - started)
  rec.sealed[name] = path
  return path, ""
end

--- Where a store whose bytes did not match another write of its
--- address is kept aside for a report: beside the stores, which
--- [`sweep_stores`] leaves it.
local function mismatch_path(rec: Recording, address: string): string
  return stores_directory(rec.root) .. "/" .. address .. ".mismatch.db"
end

--- Records, as an error of the run, that the store at `path`, written
--- for `address`, digests to `digest` where another write of the
--- address digested to `kept`, which `where` says where it is, or was
--- kept. The one at `path` is kept aside ([`mismatch_path`]), moved there
--- where `move` says it is this run's own copy, else copied, since a
--- worker may be given it.
local function mismatched(rec: Recording, address: string, path: string, digest: string,
                          kept: string, where: string, move: boolean)
  local aside = mismatch_path(rec, address)
  local saved, trouble: boolean, string = false, ""
  if move then
    saved, trouble = Fs.rename(path, aside)
  else
    local data, read_trouble = Fs.read(path)
    if data == nil then
      trouble = read_trouble
    else
      saved, trouble = Fs.write(aside, data)
    end
  end
  rec.errors[#rec.errors + 1] = "the closure store at address " .. address .. " was written " ..
    "with bytes whose digest is " .. digest .. ", but " .. where .. " has " .. kept ..
    ": a store's bytes must follow from its address alone (build.closure_store's " ..
    "`address`), and these do not. " .. (saved and ("This run's is kept at " .. aside) or
      ("This run's could not be kept aside (" .. trouble .. ")")) .. "; report it with the " ..
    "other, and both digests, and remove it once reported. The next run keeps " .. digest ..
    " for the address in the shared verdicts, in place of " .. kept .. "."
end

--- The digest the shared verdicts keep for the store at `address`, as a
--- run that wrote it kept it, looked up once a run ([`Recording.store_kept`]);
--- nil for none, or where the run has no shared verdicts.
local function shared_digest(rec: Recording, address: string): string | nil
  local kept = rec.store_kept[address]
  if kept == nil then
    kept = ""
    if rec.shared ~= nil then
      local found, trouble = shared_verdicts.store_digest(rec.shared, address)
      if found == nil and trouble ~= "" then drop_shared(rec, trouble) end
      kept = found or ""
    end
    rec.store_kept[address] = kept
  end
  if kept == "" then return nil end
  return kept
end

--- The digest of the bytes of the closure store at `address`, of the
--- import closure `names` (`base` for the store of no module,
--- [`store_at`]): what a key holds of the store, not the address that
--- says where it is.
---
--- A store this checkout has is digested as it is
--- ([`declared_key.store_digest`]). One it has not is taken, where it
--- can be, from the digest a run that wrote it kept by its address in
--- the shared verdicts ([`shared_verdicts.store_digest`]), so a fresh
--- checkout that stands on verdicts writes no store; else it is written
--- and digested. That is sound because the address digests all a
--- store's bytes follow from ([`address_stores`]), and
--- build/closure_store_test.tl holds two writes of it to the same
--- bytes. And it is checked: a test that runs is given its store as
--- written, which its key is computed again from once it ends, so a
--- verdict is kept only under the digest of what it was given; a store
--- this checkout has or writes whose bytes differ from what the shared
--- verdicts keep of its address is an error of the run (`mismatched`),
--- and so is one sampled each run that writes none ([`verify_sample`]).
--- Nil and why where it could not be written.
local function address_digest(rec: Recording, address: string, names: {string},
                              base: boolean): string | nil, string
  local started = Clock.monotonic_ns()
  rec.store_names[address] = names
  rec.store_bases[address] = base
  local path = stores_directory(rec.root) .. "/" .. (base and base_name(address) or
    (address .. ".db"))
  local digest: string = nil
  local there, _ = sys.stat(path)
  if rec.built[address] == nil and there == nil then
    digest = rec.store_digests[address]
    if digest == nil and rec.consult_shared then digest = shared_digest(rec, address) end
  end
  if digest == nil then
    rec.digests.spent_ns = rec.digests.spent_ns + (Clock.monotonic_ns() - started)
    local made, trouble = store_at(rec, address, names, base)
    if made == nil then return nil, trouble end
    started = Clock.monotonic_ns()
    digest = declared_key.store_digest(rec.digests, made)
    -- Held to what this run took for it, else to what the shared
    -- verdicts keep, whether this run wrote it or found it here.
    local took = rec.store_digests[address]
    local kept, where = took, "the digest this run took for it"
    if kept == nil then
      kept = shared_digest(rec, address)
      where = rec.shared ~= nil and ("the shared verdicts at " .. rec.shared.path) or ""
    end
    if kept ~= nil and kept ~= digest and not rec.store_mismatched[address] then
      rec.store_mismatched[address] = true
      mismatched(rec, address, made, digest, kept, where, false)
    end
  end
  rec.store_digests[address] = digest
  rec.owed.stores[address] = digest
  rec.digests.spent_ns = rec.digests.spent_ns + (Clock.monotonic_ns() - started)
  return digest, ""
end

--- Writes one store of this run again, aside, and holds its bytes to
--- the digest the run keyed its tests by: a run that wrote no store
--- would otherwise never see a write, and so never a store whose bytes
--- do not follow from its address. The store is chosen by the run's
--- number among those it keyed, so runs take each in turn; one costs
--- tens of milliseconds, counted with the keys'. A mismatch is an error
--- of the run (`mismatched`); no file is left but one kept aside.
local function verify_sample(rec: Recording)
  if rec.written > 0 then return end
  local addresses: {string} = {}
  for address in pairs(rec.store_digests) do addresses[#addresses + 1] = address end
  if #addresses == 0 then return end
  table.sort(addresses)
  local started = Clock.monotonic_ns()
  local address = addresses[(rec.run or 0) % #addresses + 1]
  local path = stores_directory(rec.root) .. "/" .. address .. ".verify.db"
  local made, _ = Fs.mkdirs(stores_directory(rec.root))
  local written, trouble = false, "no stores directory"
  if made then
    written, trouble = closure_store.write(rec.projection, path, rec.store_names[address],
      rec.basis)
  end
  if not written then
    rec.errors[#rec.errors + 1] = "the closure store at address " .. address ..
      ", written again to check it: " .. trouble
  else
    local data, read_trouble = Fs.read(path)
    local digest = data ~= nil and hex_sha256(data) or ("unreadable: " .. read_trouble)
    local kept = rec.store_digests[address]
    if digest ~= kept and not rec.store_mismatched[address] then
      rec.store_mismatched[address] = true
      local other = stores_directory(rec.root) .. "/" .. (rec.store_bases[address] and
        base_name(address) or (address .. ".db"))
      local there, _ = sys.stat(other)
      mismatched(rec, address, path, digest, kept, there ~= nil and other or
          "the store this run keyed its tests by", true)
    end
  end
  local _, _ = Fs.remove(path)
  rec.digests.spent_ns = rec.digests.spent_ns + (Clock.monotonic_ns() - started)
end

--- The digest of the bytes of the closure store a worker of `m`'s tests
--- is given ([`address_digest`]), which its key holds. Nil where `m`
--- declares `store`; nil and why where it could not be made.
store_digest = function(rec: Recording, m: importer.Module): string | nil, string
  local address = rec.stores ~= nil and rec.stores[m.path] or nil
  if address == nil then return nil, "" end
  return address_digest(rec, address, rec.closures[m.path], false)
end

--- The digest of the bytes of the store of no module (`base_store`),
--- which every closure store holds alike: what the census names as the
--- key part `store`, which moves where every store's bytes move -- the
--- schema a store is laid out by, or the SQLite that writes it -- but
--- not for a comment in the code that writes it. "" where it could
--- not be made.
local function base_store_digest(rec: Recording): string
  local digest, _ = address_digest(rec, rec.base_store, {}, true)
  return digest or ""
end

--- The policy `job`'s worker is started under ([`build.test_policy`]), from
--- the plan of its paths (`job.plan`). Its environment is added by
--- [`worker.invocation`], which gives a policy's `set_env` the whole of the
--- worker's. Nil and why where its directory cannot be made.
local function policy_of(rec: Recording, job: Job): Sandbox.Policy | nil, string
  local effective = rec.effective[job.m.path]
  local policy = test_policy.worker(job.plan, effective)
  if effective.noexec_ready then
    local made, made_trouble = Fs.mkdirs(job.scratch .. "/noexec")
    if not made then return nil, "its private noexec scratch: " .. made_trouble end
  end
  return policy, ""
end

--- Starts one job's worker. False when it could not start, which is
--- recorded as that test's failure.
local function launch(rec: Recording, job: Job, start: Proc.Relaunch,
                      limits: test.Limits): boolean
  -- Set before anything can fail, since `finish` reckons the time from it.
  job.started_ns = Clock.monotonic_ns()
  local scratch, tmp_trouble = test.scratch()
  if scratch == nil then
    finish(rec, job, nil, "could not make a temporary directory: " .. tmp_trouble, limits)
    return false
  end
  job.scratch = scratch
  local tmp = scratch .. "/tmp"
  job.tmp = tmp
  -- Sandboxed, the worker has the tree at /tree, where it runs, and
  -- its scratch directory at [`test_sandbox.scratch`].
  local env: {string:string} = worker_view()
  local root, inside, cwd: string, string, string = rec.root, scratch, nil
  local declares_trouble = unresolved(rec, job.m)
  if declares_trouble ~= "" then
    finish(rec, job, nil, declares_trouble, limits, true)
    return false
  end
  local effective = rec.effective[job.m.path]
  if effective.noexec and not effective.noexec_ready then
    finish(rec, job, nil, "", limits, false, effective.noexec_trouble)
    return false
  end
  -- The store of its closure an unsandboxed worker attaches in place
  -- of the projection ([`worker.Invocation`]'s `store`): nil for none.
  local attached: string = nil
  -- The sealed database of its closure its worker runs on ([`sealed_for`]):
  -- nil for none.
  local sealed: string = nil
  local sealed_trouble = ""
  if rec.sandbox then
    local store, store_trouble = given_store(rec, job.m)
    if store == nil and store_trouble ~= "" then
      finish(rec, job, nil, store_trouble, limits)
      return false
    end
    -- A worker that runs on a sealed database is given no artifact: it
    -- starts the core on that database, which grants the file itself.
    sealed, sealed_trouble = sealed_for(rec, job.m)
    if sealed == nil and sealed_trouble ~= "" then
      finish(rec, job, nil, sealed_trouble, limits)
      return false
    end
    if sealed == nil and rec.effective[job.m.path].lua and not rec.effective[job.m.path].store and
        not rec.effective[job.m.path].tool then
      local launched, _ = Proc.relaunch()
      local why = (launched == nil or launched.argv[2] ~= "--artifact" or launched.argv[3] == nil) and
        "this program is no portable artifact to take its database from" or
        "it is given no closure store to seal"
      finish(rec, job, nil, "its module declares lua, so what its tests start runs a sealed " ..
          "database of its closure, which cannot be made: " .. why, limits)
      return false
    end
    local kept = rec.plans[job.m.path]
    local plan: test_sandbox.Plan
    if kept ~= nil then
      plan = test_sandbox.rebind(kept.plan, kept.scratch, scratch, effective)
    else
      plan = test_sandbox.plan(rec.root, scratch, effective, worker_view(), store)
      if plan.trouble == "" then rec.plans[job.m.path] = { plan = plan, scratch = scratch } end
    end
    if plan.over > 0 then
      finish(rec, job, nil, "its sandbox would give it " .. plural.count(plan.over, "path") ..
          " more than the most one holds", limits)
      return false
    end
    if plan.trouble ~= "" then
      finish(rec, job, nil, plan.trouble, limits, true)
      return false
    end
    job.plan = plan
    if plan.own_scratch then
      -- Its worker makes its directory in a tmpfs of its own, where no
      -- host directory is in its root: the runner keeps none, and nothing
      -- is left of it once the worker ends.
      local gone, gone_trouble = Fs.remove_tree(scratch)
      if not gone then
        finish(rec, job, nil, "could not remove its unused directory " .. scratch .. ": " ..
            gone_trouble, limits)
        return false
      end
      job.scratch, job.tmp, job.own_scratch = nil, nil, true
    end
    env = plan.env
    -- The worker starts in the root of its sandbox, which has no tree to
    -- start in until the worker enters it ([`worker.run`]).
    root, inside, cwd = test_sandbox.tree, test_sandbox.scratch, "/"
  else
    -- Unsandboxed, the worker is given the environment its key holds
    -- (the pinned variables, its declared ones and the host's cores
    -- cache: [`view_of`]) with TMPDIR its scratch directory, as a sandbox gives it at
    -- [`test_sandbox.scratch`]. The key names that, not this path, which
    -- is new every run. Nothing holds it to the rest of what it declares.
    --
    -- It sees the tree where it is, not at /tree, so its key holds that
    -- path ([`declared_of`], [`declared_key.Spec`]'s `tree`): a verdict
    -- that turns on it stands only in a checkout at the same path. No
    -- host this runs on can give it the tree at a fixed path instead:
    -- a bind mount needs the user namespace a sandbox would have had,
    -- and a link at a fixed name is resolved by `getcwd` and `realpath`
    -- to the tree's own path.
    --
    -- A test that declares loopback addresses is keyed as offline, as
    -- a sandbox runs it, but here runs online, in the host's network
    -- namespace: a reach past loopback goes unnoticed here, and a Linux
    -- leg's sandbox, which runs it offline, is what fails it.
    --
    -- It attaches the store of its closure, as a sandbox gives it at
    -- o/cosmic.db ([`given_store`]), and runs the core on the sealed
    -- database of its closure ([`sealed_for`]); nothing keeps it from the
    -- program's own file, which only a sandbox hides.
    -- TODO: hand that store on to what the test starts, once a cosmic
    -- run can be told which store to read in place of its tree's
    -- o/cosmic.db (a variable build.tree_root reads): today a process
    -- the test starts, which a sandbox would give the closure store at
    -- o/cosmic.db, reads the whole projection there, which its key holds
    -- only by the closure store's bytes; a Linux leg's sandbox
    -- enforces what macOS trusts.
    local store, store_trouble = given_store(rec, job.m)
    if store == nil and store_trouble ~= "" then
      finish(rec, job, nil, store_trouble, limits)
      return false
    end
    attached = store
    -- Unsandboxed too it starts the core on the sealed database of its
    -- closure, so what it and its starts read of the program is what its
    -- key holds; only a sandbox keeps it from the program's own file.
    sealed, sealed_trouble = sealed_for(rec, job.m)
    if sealed == nil and sealed_trouble ~= "" then
      finish(rec, job, nil, sealed_trouble, limits)
      return false
    end
    env = test_sandbox.unenforced_environment(worker_view(), rec.effective[job.m.path], scratch)
  end
  job.started_ns = Clock.monotonic_ns()
  job.deadline_ns = job.started_ns + limits.timeout_ns
  -- Sandboxed, a worker whose module does not declare `tool` may not
  -- run this program ([`confine.forbid_running`]): what it would run
  -- is no input of its test's key; and one whose module does not
  -- declare `nests` may not make a root of its own ([`hold_of`]), which
  -- every process it starts learns from its environment
  -- ([`confine.held_variable`]).
  local declared = job.m.inputs
  local hold = hold_of(rec, job.m)
  if rec.sandbox then
    local given: {string:string} = {}
    for name, value in pairs(env) do given[name] = value end
    given[confine.held_variable] = hold ~= "none" and job.m.path or nil
    env = given
  end
  -- The grants hold the worker from its first instruction, but the core it
  -- is started from must be run to start it, so a worker whose module does
  -- not declare `tool` still puts up the ruleset that forbids it running
  -- the program again ([`worker.run`]'s `forbid_running`).
  local policy: Sandbox.Policy = nil
  local runs: {string} = {}
  if rec.sandbox then
    -- A worker that may run the program has nothing to forbid: the ruleset
    -- the policy puts up already refuses it every mount.
    if hold == "mounts" then hold = "none" end
    local made, made_trouble = policy_of(rec, job)
    if made == nil then
      finish(rec, job, nil, made_trouble, limits, true)
      return false
    end
    policy = made
    policy.database = sealed
    if hold == "forbid" then
      local ran, ran_trouble = test_policy.runs(policy)
      if ran == nil then
        finish(rec, job, nil, ran_trouble, limits, true)
        return false
      end
      runs = ran
    end
  end
  -- A worker on a sealed database starts as the core on it, with no
  -- launcher, artifact or descriptor of the program's: a sandboxed one by
  -- this program's name, which its policy's `database` makes the core
  -- ([`Child.start`]); an unsandboxed one by the core itself.
  local started = start
  if sealed ~= nil then
    if rec.sandbox then
      local executable, executable_trouble = Proc.executable()
      if executable == nil then
        finish(rec, job, nil, "this program's name: " .. executable_trouble, limits)
        return false
      end
      started = { argv = { executable }, env = {}, fds = {} }
    else
      started = { argv = { start.argv[1], "--database", sealed }, env = {}, fds = {} }
    end
  end
  local command = worker.invocation({
    start = started, env = env, root = root, cwd = cwd, module_path = job.m.path,
    name = job.name, scratch = inside, own_scratch = job.own_scratch, needs = test_inputs.canonical(declared), hold = hold,
    store = attached, closure = rec.closures[job.m.path], tree = rec.tree_names,
    policy = policy, runs = runs,
    program = job.plan ~= nil and job.plan.program or nil,
  })
  local handle, trouble = Child.start(command.argv, command.options)
  if handle == nil then
    finish(rec, job, nil, trouble, limits)
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
local function run_jobs(rec: Recording, jobs: {Job}, limits: test.Limits,
                        guard: Child.Guard | nil): integer
  if #jobs == 0 then return 0 end
  local start, start_trouble = worker.program()
  if start == nil then
    rec.errors[#rec.errors + 1] = "the test runner cannot find itself: " .. start_trouble
    return 0
  end
  local running: {Job} = {}
  local next_job = 1
  local cancelled = 0
  while next_job <= #jobs or #running > 0 do
    while #running < limits.jobs and next_job <= #jobs do
      local job = jobs[next_job]
      next_job = next_job + 1
      if launch(rec, job, start, limits) then
        running[#running + 1] = job
      end
    end
    if #running == 0 then break end
    if guard ~= nil then
      cancelled = guard:cancelled()
      if cancelled ~= 0 then break end
    end
    local earliest = running[1].deadline_ns
    local handles: {Child.Handle} = {}
    for i, job in ipairs(running) do
      handles[i] = job.handle
      if job.deadline_ns < earliest then earliest = job.deadline_ns end
    end
    local left_ns = earliest - Clock.monotonic_ns()
    local done, trouble = Child.wait_any(handles, math.max(0, math.min(Clock.ms(100), left_ns)))
    local still: {Job} = {}
    for _, job in ipairs(running) do
      if job.handle == done then
        -- Settled already, so this answers at once; the trouble
        -- `wait_any` gave beside the handle is the one reported.
        local result, _ = job.handle:wait()
        finish(rec, job, result, trouble, limits)
      elseif done == nil and trouble ~= Poll.TIMEOUT then
        -- Supervision itself failed; end this worker and say why.
        local _, _ = job.handle:close()
        finish(rec, job, nil, trouble, limits)
      elseif Clock.monotonic_ns() >= job.deadline_ns then
        -- Past its deadline: `wait(0)` ends it, and says why when the
        -- guard's signal came first. `close` makes sure it is gone.
        local result, stop_trouble = job.handle:wait(0)
        if result == nil then local _, _ = job.handle:close() end
        if result == nil and guard ~= nil and guard:cancelled() ~= 0 then
          -- The signal ended it before its timeout could: it is one of
          -- the workers the cancelled run ended, reported on by none.
          still[#still + 1] = job
        else
          finish(rec, job, result, stop_trouble, limits)
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
        local groups: {integer} = {}
        for _, job in ipairs(still) do groups[#groups + 1] = job.handle.pid end
        Child.end_strays(groups)
      end
      sweep(rec, running)
    end
    running = still
  end
  for _, job in ipairs(running) do
    local closed, trouble = job.handle:close()
    if not closed and job.scratch ~= nil then
      -- A member of its group may still be writing into it.
      rec.errors[#rec.errors + 1] = job.id .. ": its directory is kept: " ..
        job.scratch .. ": " .. trouble
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
local function limits_of(values: {string:string}): test.Limits | nil, string
  local limits: test.Limits = {
    timeout_ns = Clock.seconds(default_timeout_s),
    jobs = Proc.cpu_count(),
  }
  local function positive(value: string, what: string): integer | nil, string
    local number = math.tointeger(tonumber(value))
    if number == nil or number < 1 then
      return nil, what .. " must be a positive whole number, not " .. value
    end
    return number, ""
  end
  -- A deadline is kept in nanoseconds and added to the clock's reading,
  -- so seconds past half what an integer holds would wrap.
  local most_seconds = (math.maxinteger // 2) // Clock.seconds(1)
  local function seconds_of(value: string, what: string): integer | nil, string
    local seconds, trouble = positive(value, what)
    if seconds == nil then return nil, trouble end
    if seconds > most_seconds then
      return nil, what .. " must be at most " .. most_seconds .. " seconds, not " .. value
    end
    return seconds, ""
  end
  local from_env = Env.get(timeout_variable)
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
  local env: {string:string} = {}
  for name, value in pairs(worker_view()) do env[name] = value end
  for name, value in pairs(start.env) do env[name] = value end
  env.TMPDIR = test_sandbox.scratch
  local answer = test_sandbox_probe.available(start.argv, env, start.fds, directory)
  local _, _ = Fs.remove_tree(directory)
  return answer
end

--- Reporting receives copies, never the mutable state that judges a run.
local function say_skips(rec: Recording)
  local skips: {string} = {}
  for i, skip in ipairs(rec.skips) do skips[i] = skip end
  for _, line in ipairs(test_report.skips(skips)) do log:say(line) end
  local unchecked: {string} = {}
  for i, id in ipairs(rec.unchecked) do unchecked[i] = id end
  for _, line in ipairs(test_report.unchecked(unchecked)) do log:say(line) end
  local deliberate: {string} = {}
  for i, reason in ipairs(rec.deliberate) do deliberate[i] = reason end
  for _, line in ipairs(test_report.deliberate(deliberate)) do log:say(line) end
  local nas: {string} = {}
  for i, na in ipairs(rec.nas) do nas[i] = na end
  for _, line in ipairs(test_report.nas(nas)) do log:say(line) end
end

local function say_failures(rec: Recording, failures: {string})
  local snapshots: {test_report.Failure} = {}
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
  argv: {integer:string}

  -- The command line ([`read_command`]).
  root: string
  limits: test.Limits
  shard: test.Shard
  sandbox_mode: string
  selectors: {string}
  forced: boolean
  consult: boolean
  census: boolean

  -- The checkout ([`hold_checkout`]).
  started: integer
  own_tree: boolean
  handle: work.Handle
  staged: work.Staged
  built: compiler

  -- The binary's identities ([`read_identities`]).
  tool: string
  compiled_by: string
  identity: string
  runtime: string
  harness: Harness
  database: string

  -- The sandbox ([`choose_sandbox`]).
  --- What asking whether a worker can be sandboxed came to, or nil where
  --- the run was told not to ask ([`require_of_host`] asks then, if a
  --- module needs it).
  sandbox_answer: test_sandbox_probe.Answer
  --- The requirements this run's leg promises (COSMIC_TEST_PROMISES), and
  --- the leg's name (COSMIC_TEST_LEG, "" where none is given), which a held
  --- run fails a module for lacking ([`require_of_host`]).
  promises: {string}
  leg: string
  --- Whether the run is held to the sandbox (COSMIC_TEST_SANDBOX=1,
  --- COSMIC_SANDBOX=must or COSMIC_CI_REQUIRE_SANDBOX=1): it fails what a
  --- leg promises and a test that made no call to `assert`.
  held: boolean
  sandboxed: boolean
  sandbox_summary: string
  shares: boolean
  keying: string

  -- The built tree ([`build_tree`]).
  result: importer.Result

  -- The tests chosen ([`select_tests`]).
  selected_modules: {importer.Module}
  selected_tests: {string:{string}}
  whole: boolean
  share_summary: string

  -- The records the run reads and writes ([`open_records`]).
  records_path: string
  records: Sqlite.Handle
  previous: {string:boolean}
  verdicts: {string:test.Verdict}
  epoch: string
  credited: test.Credited

  -- What the run tallies and reports ([`make_recording`]).
  tally: test.Tally
  failures: {string}
  errors: {string}
  hits: Coverage.Hits
  by_test: {string:string}
  native_lines: Coverage.Hits
  rec: Recording

  -- The tests that run ([`look_up_verdicts`]).
  jobs: {Job}

  -- What the run says last ([`settle`]).
  total: integer
  --- The C functions' prerequisites this host lacks, probed before any
  --- worker starts. Unknown answers and missing promises retain coverage.
  c_unavailable: {string: string}
  function_lines: {string}
  cov_line: string
end

--- The command line read: where the run is, what it is told to do and
--- which tests it is told to choose. The exit code to stop with, or nil
--- to go on.
local function read_command(ctx: Run): integer | nil
  local root, root_trouble = Fs.absolute(".")
  if root == nil then
    log:complain(root_trouble)
    return 1
  end
  ctx.root = root
  local parsed, parse_trouble = Flags.parse(ctx.argv, 2, Cli.verbs.test.spec)
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
  local selectors: {string} = {}
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
  ctx.forced = parsed.set["--all"] == true or Env.get("COSMIC_TEST_ALL") == "1"
  -- A run that stands on nothing another checkout reached, though it
  -- still shares what it reaches: what answers for every test is this
  -- checkout's own evidence, or a run.
  ctx.consult = not (parsed.set["--no-shared"] == true or
    Env.get("COSMIC_TEST_NO_SHARED") == "1")
  ctx.census = parsed.set["--census"] == true
  return nil
end

--- The checkout taken: its rebuild lock held, its working database
--- opened and staged, and a stale tool rebuilt. The exit code to stop
--- with, or nil to go on.
local function hold_checkout(ctx: Run): integer | nil
  local root = ctx.root
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
  local own_tree, own_trouble = tree.is_own(root)
  if own_tree == nil then
    log:complain(own_trouble)
    return 1
  end
  ctx.own_tree = own_tree
  local handle, open_trouble = work.open(root)
  if handle == nil then
    log:complain(open_trouble)
    return 1
  end
  ctx.handle = handle
  local staged, stage_trouble = work.stage(handle, own_tree)
  if staged == nil then
    local _, _ = work.close(handle)
    log:complain(stage_trouble)
    return 1
  end
  ctx.staged = staged

  ctx.built = teal.lazy()

  -- A stale tool refuses, or rebuilds itself or has zig boot the core
  -- and re-enters this command line ([`reboot.guard`]).
  if own_tree then
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
local function read_identities(ctx: Run): integer | nil
  local handle = ctx.handle
  -- Both identities are read before the project's database is attached
  -- ahead of the binary's: they name this binary, and a project's own
  -- projection carries the ones of whichever binary wrote it.
  local tool = Store.meta("compiler") or ""
  local compiled_by = Store.meta("compiled_by") or ""
  -- A compiler a test stands in for, in a tree not cosmic's own, so it
  -- can see a compiler of another identity that makes the same
  -- bytecode move only the keys of a closure that reads it, without a
  -- binary of its own (build/sandboxed_verdicts_test.tl): the tree is
  -- compiled under it, and the run keys by it.
  local compiler_salt = Env.get("COSMIC_TEST_COMPILER_SALT")
  if not ctx.own_tree and compiler_salt ~= nil and compiler_salt ~= "" then
    tool = hex_sha256(tool .. "\0" .. compiler_salt)
    compiled_by = tool
  end
  ctx.tool, ctx.compiled_by = tool, compiled_by
  local identity = Store.meta("runtime")
  if identity == nil or identity == "" then
    local _, _ = work.close(handle)
    log:complain("the running binary names no runtime identity")
    return 1
  end
  ctx.identity = identity
  -- Every verdict is keyed on the data tables the binary carries too
  -- ([`schema.tables_digest`]): `cosmic refresh` replaces its zones and
  -- roots without moving its runtime identity, and a test that read one
  -- could fail on the refreshed binary. Every test, not only one that
  -- read a table: that read goes through `Store`'s own connection, which
  -- no observation sees, and a refresh is rare enough that running
  -- everything once after one costs little. Computed here from the
  -- binary's own rows rather than taken from anything it records of
  -- them, which a refresh or a writer that did not know to update it
  -- would leave stale.
  local tables, tables_trouble = binary_tables()
  if tables == nil then
    local _, _ = work.close(handle)
    log:complain("the running binary's data tables: " .. tables_trouble)
    return 1
  end
  ctx.runtime = identity .. " tables " .. tables
  local harness, harness_trouble = binary_harness()
  if harness == nil then
    local _, _ = work.close(handle)
    log:complain("the running binary's test harness: " .. harness_trouble)
    return 1
  end
  ctx.harness = harness
  ctx.database = ctx.root .. "/o/cosmic.db"
  return nil
end

--- Whether the workers are sandboxed, which the runtime the keys hold
--- says. The exit code to stop with, or nil to go on.
local function choose_sandbox(ctx: Run): integer | nil
  local handle = ctx.handle
  local sandbox_mode = ctx.sandbox_mode
  -- Only a held run reads the promises, which only it fails for: a
  -- project that sets COSMIC_TEST_PROMISES for another reason is no concern of a run
  -- that is not held.
  local promises: {string} = {}
  ctx.held = sandbox_mode == "on" or Env.get("COSMIC_SANDBOX") == "must" or
    Env.get("COSMIC_CI_REQUIRE_SANDBOX") == "1"
  if ctx.held then
    local read, promises_trouble = host_names.read_promises(Env.get("COSMIC_TEST_PROMISES") or "")
    if read == nil then
      local _, _ = work.close(handle)
      log:complain("test: COSMIC_TEST_PROMISES: " .. promises_trouble)
      return 1
    end
    promises = read
  end
  ctx.promises, ctx.leg = promises, Env.get("COSMIC_TEST_LEG") or ""
  -- Each worker runs sandboxed where the kernel can sandbox one, unless
  -- the switch turns it off. Either way each test is keyed by what it
  -- declares; unsandboxed, the run trusts that where a sandboxed run
  -- elsewhere enforces it. A verdict reached sandboxed is kept apart
  -- from one reached without, by a runtime of its own, so neither
  -- stands for the other. An unsandboxed run shares its verdicts only
  -- through a file COSMIC_VERDICT_CACHE names ([`shared_verdicts.chosen`]):
  -- no sandbox held what its tests read, so what it reached is another
  -- checkout's to stand on only where both were asked to.
  local must = Env.get("COSMIC_SANDBOX") == "must"
  local unenforced = "each test is keyed by what it declares, which nothing holds it to"
  local sandboxed, sandbox_summary = false, ""
  -- A run started, however deep, in a worker a Landlock ruleset holds
  -- can sandbox none of its own, whose roots are made of mounts: it
  -- fails, naming what lets that worker's test nest one, rather than
  -- run them unsandboxed and pass having confined nothing.
  local holder = Env.get(confine.held_variable)
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
      -- And whether it is held to confining what it starts
      -- ([`confine.must_confine`]), which a test's verdict turns on. A
      -- verdict so reached is kept apart from one reached without a
      -- sandbox, by a runtime of its own, so neither stands for the other.
      -- The runtime holds what every worker's policy has alike, the
      -- isolation and the promises ([`test_policy.common`]), and the code
      -- that makes a worker's policy, so an edit to a grant runs the
      -- tests again without a bump of the epoch.
      local made = ctx.harness.modules
      ctx.runtime = ctx.runtime .. " sandboxed" .. (must and " must" or "") .. " policy " ..
        hashing.hex_sha256(test_policy.common() .. "\0" ..
            (made["build.test_policy"] or "") .. "\0" .. (made["build.test_sandbox"] or ""))
      sandbox_summary = "; sandboxed, under a policy"
      log:say("test: sandbox: each worker is held to its inputs, the tree at " ..
          test_sandbox.tree)
    else
      -- A run held to sandboxing fails where no worker can be, rather than
      -- run them without and pass having confined nothing.
      local held = sandbox_mode == "on" and test_sandbox.switch .. "=1" or
        must and "COSMIC_SANDBOX=must" or
        Env.get("COSMIC_CI_REQUIRE_SANDBOX") == "1" and "COSMIC_CI_REQUIRE_SANDBOX=1" or nil
      if held ~= nil then
        local _, _ = work.close(handle)
        log:complain("test: " .. held .. ", but no worker can be sandboxed here: " .. why)
        return 1
      end
      sandbox_summary = "; unsandboxed, as no worker can be sandboxed here (" .. why .. ")"
      log:say("test: no worker can be sandboxed here: " .. why .. "; " .. unenforced ..
          "; " .. test_sandbox.switch .. "=0 runs them unsandboxed without asking")
    end
  else
    sandbox_summary = "; unsandboxed (" .. test_sandbox.switch .. "=0)"
    log:say("test: declared: workers run unsandboxed (" .. test_sandbox.switch .. "=0); " ..
        unenforced)
  end
  local shares = sandboxed or shared_verdicts.chosen()
  if not sandboxed then
    -- The pinned COSMIC_TEST_SANDBOX and the " sandboxed" mark already
    -- tell these verdicts from a sandboxed run's; the tag says so in
    -- the key itself (build/declared_unenforced_test.tl).
    ctx.runtime = ctx.runtime .. " declared" .. (must and " must" or "")
    sandbox_summary = sandbox_summary .. ", keyed by declared inputs" ..
      (shares and "" or ", sharing no verdicts")
  end
  ctx.sandboxed, ctx.sandbox_summary, ctx.shares = sandboxed, sandbox_summary, shares
  -- What names what a run says of its keys: the sandbox's, or, with no
  -- sandbox, the declarations'.
  ctx.keying = sandboxed and "test: sandbox: " or "test: declared: "
  return nil
end

--- The tree compiled into the working database and its build said.
--- The exit code to stop with, or nil to go on.
local function build_tree(ctx: Run): integer | nil
  local handle, staged, started = ctx.handle, ctx.staged, ctx.started
  local result, compile_trouble = importer.compile(handle, ctx.built, ctx.tool, false,
    shared_compiles.for_build())
  if result == nil then
    local _, _ = work.record(handle, clock.elapsed_ms(started), staged, 0, 0, "FAIL")
    local _, _ = work.close(handle)
    log:complain(compile_trouble)
    return 1
  end
  local written, write_trouble =
    writer.write_result(handle, ctx.database, result)
  local _, _ = work.record(handle, clock.elapsed_ms(started), staged, result.compiled,
    result.cached, written and "PASS" or "FAIL")
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
local function select_tests(ctx: Run): integer | nil
  local result, selectors, shard = ctx.result, ctx.selectors, ctx.shard
  -- Each selector must match a test module on its own: one mistyped
  -- among good ones would otherwise narrow the run without a word, and
  -- one naming a test must find it there.
  local selected_modules: {importer.Module} = {}
  -- The tests each selected module runs, by its module name.
  local selected_tests: {string:{string}} = {}
  local matched: {string:boolean} = {}
  local found: {string:boolean} = {}
  -- The module each selector matched, for a named test it lacks.
  local module_of: {string:importer.Module} = {}
  for _, m in ipairs(result.modules) do
    if (m.kind == "test" or m.kind == "example") and #m.tests > 0 then
      local chosen: {string} = {}
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
  local unmatched: {string} = {}
  local unfound: {string} = {}
  for _, selector in ipairs(selectors) do
    if not matched[selector] then
      unmatched[#unmatched + 1] = selector
    elseif not found[selector] then
      unfound[#unfound + 1] = selector
    end
  end
  if #unmatched > 0 or #unfound > 0 then
    local _, _ = work.close(ctx.handle)
    if #unmatched > 0 then
      log:complain("no test module matches: " .. table.concat(unmatched, ", "))
    end
    for _, selector in ipairs(unfound) do
      local m = module_of[selector]
      local _, name = split(selector)
      local near = test.nearest(name, m.tests)
      log:complain("no test in " .. m.path .. " is named " .. name .. "; it has " ..
          table.concat(near, ", ") .. (#m.tests > #near and ", ..." or ""))
    end
    return 1
  end
  -- A share of the chosen tests (`--shard`), dealt over all of them
  -- ([`test.dealt`]): the other shares, run elsewhere, run the rest.
  if shard ~= nil then
    local ids: {string} = {}
    for _, m in ipairs(selected_modules) do
      for _, name in ipairs(selected_tests[m.path]) do ids[#ids + 1] = m.path .. " " .. name end
    end
    local dealt = test.dealt(ids, shard)
    local kept: {importer.Module} = {}
    for _, m in ipairs(selected_modules) do
      local names: {string} = {}
      for _, name in ipairs(selected_tests[m.path]) do
        if dealt[m.path .. " " .. name] then names[#names + 1] = name end
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
local function open_records(ctx: Run): integer | nil
  local handle = ctx.handle
  -- Every verdict and every coverage row of this run lands together.
  local begun, begin_trouble = work.begin(handle)
  if not begun then
    local _, _ = work.close(handle)
    log:complain(begin_trouble)
    return 1
  end
  local records_path = ctx.root .. "/o/build.db"
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
  local verdicts, verdicts_trouble = known_verdicts(records)
  if verdicts == nil then
    local _, _ = work.rollback(handle)
    local _, _ = work.close(handle)
    log:complain(records_path .. ": " .. verdicts_trouble)
    return 1
  end
  ctx.verdicts = verdicts
  local epoch, epoch_trouble = harness_epoch_of()
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
  local handle, records = ctx.handle, ctx.records
  ctx.tally = { ran = 0, cached = 0, shared = 0, every = 0,
    skipped = 0, unchecked = 0, na = 0 }
  local tally = ctx.tally
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
  if ctx.own_tree then
    native_lines = Coverage.native_lines()
  else
    unowned = Coverage.native_lines()
  end
  ctx.native_lines = native_lines
  local sandbox_mode = ctx.sandbox_mode
  local rec: Recording = {
    records = records, root = ctx.root, runtime = ctx.runtime,
    run_at_ns = ctx.run_at_ns, run = handle.run,
    failures = failures, errors = errors, outputs = {}, reruns = {},
    failed = {}, skips = {}, unchecked = {}, deliberate = {}, held = ctx.held, nas = {}, unmet = {}, answered = {},
    hits = hits, by_test = by_test, unowned = unowned, tally = tally,
    owed = { kept = {}, used = {}, failed = {}, stores = {} }, shared_keys = {},
    consult_shared = ctx.consult,
    origin = checkout_id(records, ctx.root, ctx.run_at_ns),
    sandbox = ctx.sandboxed, views = {}, caches = {}, unkeyed = {},
    forbiddable = {},
    epoch = ctx.epoch, timeout_ns = ctx.limits.timeout_ns,
    store_salt = ctx.harness.store_salt, carried = ctx.harness.carried,
    closure_sets = {}, plans = {}, spelled = {}, folded = {}, type_only = {},
    rerun_prefix = (sandbox_mode == "on" and (test_sandbox.switch .. "=1 ") or
      sandbox_mode == "off" and (test_sandbox.switch .. "=0 ") or ""),
  }
  ctx.rec = rec
  -- An edit to the code that writes a closure store a test stands in
  -- for, in a tree not cosmic's own, so it can see one that writes the
  -- same bytes move no key without a binary of its own
  -- (build/sandboxed_verdicts_test.tl): mixed into the salt, never in
  -- its place, so one address still names one store's bytes.
  local store_salt = Env.get("COSMIC_TEST_STORE_SALT")
  if not ctx.own_tree and store_salt ~= nil and store_salt ~= "" then
    rec.store_salt = hex_sha256(rec.store_salt .. "\0" .. store_salt)
  end
  -- The verdicts every checkout of the tree shares: one that stands
  -- here, run where another checkout reached it, is not run again.
  -- Without them the run goes on, and says so unless it was asked not
  -- to use them. An unsandboxed run reads and writes them only where
  -- COSMIC_VERDICT_CACHE names them (see [`choose_sandbox`]).
  local cache_path, cache_trouble: string, string = nil, ""
  if ctx.shares then cache_path, cache_trouble = shared_verdicts.location() end
  if cache_path ~= nil then
    rec.shared, cache_trouble = shared_verdicts.open(cache_path)
  end
  if rec.shared == nil and cache_trouble ~= "" then
    log:complain("test: shared verdicts: " .. cache_trouble .. "; running without them")
  end
end

--- What every test's key is made of, read once before any test is
--- keyed: each selected module's closure and declarations, the stores
--- of the closures, and the host, system and launcher identities, then
--- frozen. The exit code to stop with, or nil to go on.
local function gather_key_inputs(ctx: Run): integer | nil
  local handle, records, rec, result = ctx.handle, ctx.records, ctx.rec, ctx.result
  local records_path, selected_modules = ctx.records_path, ctx.selected_modules
  local identity = ctx.identity
  local by_path: {string:importer.Module} = {}
  for _, m in ipairs(result.modules) do by_path[m.path] = m end
  local declaration_rows, declaration_trouble = Sqlite.text_rows(records,
    "SELECT path, file FROM inputs WHERE kind = 'decl'")
  if declaration_rows == nil then
    local _, _ = work.rollback(handle)
    local _, _ = work.close(handle)
    log:complain(records_path .. ": " .. declaration_trouble)
    return 1
  end
  local declarations: {string:string} = {}
  for _, row in ipairs(declaration_rows) do declarations[row[1]] = row[2] end
  rec.closures, rec.tree_names = {}, {}
  for path in pairs(by_path) do rec.tree_names[#rec.tree_names + 1] = path end
  table.sort(rec.tree_names)
  -- A module the binary carries that is no module of the tree -- in a
  -- project's tree, the standard library's -- is no key's either way
  -- (the TODO above build.test_worker's `refusal`): a worker may load
  -- one.
  for name in pairs(rec.carried) do
    if by_path[name] == nil then rec.carried[name] = nil end
  end
  local type_only, type_only_trouble = projection_type_only(ctx.database)
  if type_only == nil then
    local _, _ = work.rollback(handle)
    local _, _ = work.close(handle)
    log:complain(type_only_trouble)
    return 1
  end
  rec.type_only = type_only
  for _, m in ipairs(selected_modules) do
    rec.closures[m.path] = test_inputs.modules(m, by_path, declarations, type_only)
  end
  rec.effective = {}
  local noexec_probes: {string:string} = {}
  for _, m in ipairs(selected_modules) do
    local effective = test_inputs.effective(m, by_path, declarations, type_only)
    effective.cache_paths = caches_of(rec, m)
    test_inputs.resolve(effective, tree_roots(rec))
    test_sandbox_probe.resolve_noexec(effective, rec.sandbox, noexec_probes)
    rec.effective[m.path] = effective
  end
  -- What an earlier run hashed, so a key reads none of it again
  -- ([`build.declared_key`]).
  local remembered, remembered_trouble = Sqlite.text_rows(records,
    "SELECT path, signature, sha256 FROM digests")
  if remembered == nil then
    local _, _ = work.rollback(handle)
    local _, _ = work.close(handle)
    log:complain(records_path .. ": " .. remembered_trouble)
    return 1
  end
  rec.digests = declared_key.digests(ctx.root, remembered)
  -- A core that carries debug information, as the checked core does,
  -- is keyed by its image (build.core_image): its DWARF names the
  -- directory musl was first built in, which moves between CI runs,
  -- and no test's verdict turns on it. A release core, stripped, keys
  -- as the binary names it.
  local host_image = Store.meta("host_image")
  rec.store_runtime = identity
  if host_image ~= nil and String.starts_with(rec.runtime, identity) then
    rec.store_runtime = declared_key.runtime_identity(rec.digests, identity, host_image,
      Store.meta("runtime_basis") or "")
    rec.runtime = rec.store_runtime .. rec.runtime:sub(#identity + 1)
  end
  rec.core = rec.store_runtime
  -- A core that writes stores otherwise a test stands in for, in a tree
  -- not cosmic's own, so it can see the core move every store's address
  -- (build/sandboxed_verdicts_test.tl): mixed into the stores' salt
  -- alone, never in its place.
  local store_core = Env.get("COSMIC_TEST_STORE_RUNTIME")
  if not ctx.own_tree and store_core ~= nil and store_core ~= "" then
    rec.store_runtime = hex_sha256(rec.store_runtime .. "\0" .. store_core)
  end
  -- The store of each test module's closure, by its address, salted with
  -- the core above, and none that no module names any longer.
  rec.projection = ctx.database
  local addressed, address_trouble = address_stores(rec, result.modules, by_path, declarations)
  if not addressed then
    local _, _ = work.rollback(handle)
    local _, _ = work.close(handle)
    log:complain("test: the stores of the test modules' closures: " .. address_trouble)
    return 1
  end
  sweep_stores(rec)
  rec.compiler = ctx.tool .. " " .. ctx.compiled_by
  rec.host = declared_key.host_identity(rec.digests)
  -- What the system's paths hold is walked only for a run that holds
  -- a module given them, whose key alone holds it: half a second of
  -- /usr's entries otherwise spent for nothing.
  local holds_system = false
  for _, m in ipairs(selected_modules) do
    local effective = rec.effective[m.path]
    if effective ~= nil and effective.system then holds_system = true end
  end
  rec.system = declared_key.system_identity(rec.digests, nil, holds_system)
  rec.tool = rec.tool or confine.itself()
  -- The runtime identity holds the core an artifact selects, not the
  -- launcher and manifest that selected it, which a test that does
  -- not run the program is keyed by nowhere else.
  local executable, _ = Proc.executable()
  if Store.meta("runtime_context") == "portable-v1" and executable ~= nil then
    rec.launcher = declared_key.launcher_identity(rec.digests, executable)
  end
  -- Every test is keyed before any starts: one look at each input
  -- serves them all.
  declared_key.freeze(rec.digests)
  return nil
end

--- Which absence a module reports when it has several, the worst first.
local UNMET_RANK <const>: {string:integer} = { refused = 3, na = 2, skipped = 1 }

--- The names a module requires of its host, as its policy declares them
--- ([`host_names.check`]), sorted.
local function requirements_of(m: importer.Module): {string}
  local names: {string} = {}
  local declared = m.inputs
  if declared == nil then return names end
  for _, name in ipairs(declared.requires or {}) do names[#names + 1] = name end
  table.sort(names)
  return names
end

--- Asks the host, once, for every requirement the selected modules declare
--- ([`host_requires`]), before any worker starts,
--- and decides each module: where all are present, it runs, and its key
--- holds each answer (`rec.answered`); otherwise none of its tests is
--- started (`rec.unmet`), as one whose name breaks the table's rules fails
--- (`refused`), one a platform never has is not applicable (`na`), and one
--- this host lacks is skipped. A held run (COSMIC_TEST_SANDBOX=1,
--- COSMIC_SANDBOX=must, COSMIC_CI_REQUIRE_SANDBOX=1) holds the sandbox
--- ([`choose_sandbox`]), and fails a module for an n/a or a skip of a
--- requirement its leg promises (COSMIC_TEST_PROMISES, COSMIC_TEST_LEG),
--- naming the requirement and the leg; an absence of one it does not
--- promise fails nothing.
--- The exit code to stop with, or nil to go on.
local function require_of_host(ctx: Run): integer | nil
  local rec = ctx.rec
  local host: host_requires.Host = nil
  local held = ctx.held
  for _, m in ipairs(ctx.selected_modules) do
    local names = requirements_of(m)
    if #names > 0 then
      if host == nil then
        -- COSMIC_TEST_PLATFORM=other, for a test of this runner alone, stands in
        -- for a platform without Linux's requirements or a portable artifact on
        -- a host that has them: it makes modules not applicable, which keeps
        -- no verdict and fails no run.
        local linux: boolean = nil
        local portable = Store.meta("runtime_context") == "portable-v1"
        local checked = testing.configuration == "sanitized"
        if Env.get("COSMIC_TEST_PLATFORM") == "other" then
          linux, portable, checked = false, false, false
        end
        host = host_requires.new({
          portable = portable,
          checked = checked,
          linux = linux,
          sandbox = function(): host_requires.Sandbox
            if ctx.sandbox_answer == nil then ctx.sandbox_answer = sandbox_here() end
            local answer = ctx.sandbox_answer
            return { ok = answer.ok, why = answer.why, broken = answer.broken }
          end,
        })
      end
      local found: {host_requires.Answer} = nil
      local asked, trouble = pcall(function() found = host_requires.answer(host, names) end)
      if not asked then
        -- A probe that cannot tell (a file it may not read) is no answer: the
        -- modules that name it fail, saying why, and the run goes on.
        found = {}
        rec.unmet[m.path] = { kind = "refused", why = "the probe of what it requires of the host " ..
            "failed: " .. tostring(trouble) }
      end
      local present: {string:string} = {}
      local unmet: Unmet = nil
      for _, answer in ipairs(found) do
        if answer.kind == "present" then
          present[answer.name] = answer.key
        else
          local said = "requires " .. answer.name .. ": " .. answer.why
          local kind = answer.kind
          if held and kind ~= "refused" and host_names.promised(ctx.promises, answer.name) then
            said = said .. " (" .. (ctx.leg == "" and "this run" or "the leg " .. ctx.leg) ..
              " promises " .. answer.name .. ", and a held run fails what its leg promised)"
            kind = "refused"
          end
          if unmet == nil or UNMET_RANK[kind] > UNMET_RANK[unmet.kind] then
            unmet = { kind = kind, why = said }
          end
        end
      end
      if rec.unmet[m.path] ~= nil then
        unmet = nil
      elseif unmet ~= nil then
        rec.unmet[m.path] = unmet
      else
        rec.answered[m.path] = present
      end
    end
  end
  ctx.c_unavailable = {}
  if ctx.own_tree and ctx.whole and host ~= nil then
    local needs: {string: boolean} = {}
    for _, name in pairs(c_functions.prerequisites()) do needs[name] = true end
    local names: {string} = {}
    for name in pairs(needs) do names[#names + 1] = name end
    table.sort(names)
    local asked, trouble = pcall(function()
      local answers = host_requires.answer(host, names)
      ctx.c_unavailable = c_functions.unavailable(answers, ctx.held and ctx.promises or nil)
      for _, answer in ipairs(answers) do
        if answer.kind == "refused" then
          rec.errors[#rec.errors + 1] = "C coverage requires " .. answer.name .. ": " .. answer.why
        elseif answer.kind ~= "present" then
          local why = "requires " .. answer.name .. ": " .. answer.why
          if ctx.held and host_names.promised(ctx.promises, answer.name) then
            rec.failures[#rec.failures + 1] = "C coverage " .. why .. ": this held run promises it"
          end
        end
      end
    end)
    if not asked then
      rec.errors[#rec.errors + 1] = "C coverage prerequisite probe: " .. tostring(trouble)
    end
  end
  return nil
end

--- Settles the test `id` of a module whose requirements are not all
--- present ([`require_of_host`]) without starting a worker or keying it,
--- and keeps no verdict: a refused name fails it, an absence this host has
--- skips it, and one the platform never lacks marks it not applicable.
local function settle_unmet(rec: Recording, m: importer.Module, name: string, id: string,
                            unmet: Unmet, limits: test.Limits)
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
    finish(rec, job, nil, "", limits, false, unmet.why)
  else
    finish(rec, job, nil, unmet.why, limits)
  end
end

--- Each selected test keyed and looked up: a test whose verdict stands,
--- here or in another checkout, is credited or shared, and the rest
--- become the run's jobs. What the keys are made of and how many were
--- looked up is said.
local function look_up_verdicts(ctx: Run)
  local rec, selected_modules, selected_tests = ctx.rec, ctx.selected_modules, ctx.selected_tests
  local verdicts, forced, consult, keying = ctx.verdicts, ctx.forced, ctx.consult, ctx.keying
  local previous, credited, sandboxed = ctx.previous, ctx.credited, ctx.sandboxed
  local jobs: {Job} = {}
  ctx.jobs = jobs
  -- The tests looked up in the shared cache, and whether any was found:
  -- where none was, `unmatched` says why.
  local looked: {string:boolean} = {}
  local keyed_count, looked_count, found_count, ran_here = 0, 0, 0, 0
  for _, m in ipairs(selected_modules) do
    local unmet = rec.unmet[m.path]
    for _, name in ipairs(selected_tests[m.path]) do
      local id = m.path .. " " .. name
      if unmet ~= nil then
        settle_unmet(rec, m, name, id, unmet, ctx.limits)
        goto next_test
      end
      -- A test is keyed by what it is given, and runs unless a verdict
      -- under that key passed, here or in another checkout -- or it is
      -- forced, by --all or COSMIC_TEST_ALL, or reaches a
      -- network beyond loopback, which no key holds. None is assumed.
      local key = declared_of(rec, m, id)
      if key ~= nil then keyed_count = keyed_count + 1 end
      local own = key ~= nil and verdicts[key] or nil
      local elsewhere: shared_verdicts.Found = nil
      if key ~= nil and not forced and own == nil and consult and rec.shared ~= nil then
        local answer, trouble = shared_verdicts.declared(rec.shared, key)
        if answer == nil and trouble ~= "" then drop_shared(rec, trouble) end
        elsewhere = answer
        looked[id], looked_count = true, looked_count + 1
        if previous[id] then ran_here = ran_here + 1 end
        if answer ~= nil then found_count = found_count + 1 end
      end
      if key == nil or forced or (own ~= nil and not own.passed) or
          (own == nil and elsewhere == nil) then
        jobs[#jobs + 1] = { m = m, name = name, id = id, declared = key }
      elseif own ~= nil then
        rec.shared_keys[key] = key
        stand(rec, credited, m, name, id, own, key)
      else
        share(rec, m, name, id, key, elsewhere)
      end
      ::next_test::
    end
  end
  -- The digests the run's keys hold, which each row it keeps in the
  -- shared cache is stamped with ([`shared_verdicts.settle`]): made only
  -- where there is a cache to stamp or a census to say, since
  -- `host_features` reads the processor's whole description.
  local census_asked = ctx.census
  local parts: {{string}} = {}
  if rec.shared ~= nil or census_asked then
    parts = {
      -- As .github/scripts/host-features.sh names CI's verdict cache.
      { "host features", declared_key.host_features() },
      { "host", rec.host:sub(1, 12) },
      { "system", (rec.system or ""):sub(1, 12) },
      { "runtime", hex_sha256(rec.runtime or ""):sub(1, 12) },
      { "compiler", (rec.compiler or ""):sub(1, 12) },
      -- The key's harness parts, its epoch and timeout, as one word.
      { "harness", test.harness_word(rec.epoch, rec.timeout_ns) },
    }
    if rec.launcher ~= nil then parts[#parts + 1] = { "launcher", rec.launcher:sub(1, 12) } end
    -- What every closure store holds alike, by its bytes, which the key
    -- of every test whose module does not declare `store` holds within
    -- its store's digest: named so a run whose stores all moved says
    -- so rather than leaving it to the parts beside it.
    if rec.base_store ~= nil then
      parts[#parts + 1] = { "store", base_store_digest(rec):sub(1, 12) }
    end
    if not sandboxed then parts[#parts + 1] = { "tree", hex_sha256(ctx.root):sub(1, 12) } end
    local runs_tool = false
    for _, m in ipairs(selected_modules) do
      if rec.effective[m.path] ~= nil and rec.effective[m.path].tool then runs_tool = true end
    end
    if runs_tool then
      parts[#parts + 1] = { "program", program_of(rec):sub(1, 12) }
    end
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
  if census_asked or (rec.shared ~= nil and looked_count > 0 and
      looked_count == keyed_count and ran_here == 0 and found_count == 0) then
    local line: string = nil
    if rec.shared ~= nil and found_count == 0 then
      local census, _ = shared_verdicts.census(rec.shared, looked)
      line = census ~= nil and shared_verdicts.unmatched(rec.shared.path, looked_count,
        census, parts) or nil
    end
    if line == nil and census_asked then line = shared_verdicts.key_parts(parts) end
    if line ~= nil then log:say(line) end
    if census_asked and rec.shared ~= nil then
      local held, _ = shared_verdicts.held(rec.shared)
      if held ~= nil then log:say(shared_verdicts.census_line(held)) end
    end
  end
  verify_sample(rec)
  -- From here each key looks again: a verdict is kept only under a
  -- key its inputs still reach once its test has run.
  declared_key.thaw(rec.digests)
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
        not (effective.store or effective.tool) and not seals(rec, m) then
      unsealed = unsealed + #selected_tests[m.path]
    end
  end
  if unsealed > 0 then
    log:say(keying .. plural.count(unsealed, "test") .. " run the whole program, not a sealed " ..
        "database of their closure: this program is no portable artifact")
  end
  log:say(string.format(keying .. "%s keyed by their declared inputs in %.1f ms (%s read)",
    plural.count(tests, "test"), rec.digests.spent_ns / 1e6,
    plural.count(rec.digests.read, "file")))
  local unkeyed: {string} = {}
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
  metamethod __close: function(Removal)
end

local removal_mt: metatable<Removal> = {
  __close = function(removal: Removal) drop_sealing(removal.rec) end,
}

--- An incomplete run contributes no passes or coverage, but its completed
--- failures disprove old passes. Keep only those tombstones after rolling
--- back the run, and remove only their keys from the shared cache.
local function cancel_records(ctx: Run)
  local rec, handle = ctx.rec, ctx.handle
  local ok, trouble = work.rollback(handle)
  if ok and #rec.owed.failed > 0 then
    ok, trouble = work.begin(handle)
    if ok then
      for _, key in ipairs(rec.owed.failed) do
        ok, trouble = record_verdict(rec.records, key, false, rec.run_at_ns, rec.run, 0)
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
  if rec.shared ~= nil then
    local invalidations: shared_verdicts.Owed = { kept = {}, used = {}, failed = rec.owed.failed }
    local settled, settle_trouble = shared_verdicts.settle(rec.shared, rec.origin,
      invalidations, Clock.now_ns())
    shared_verdicts.close(rec.shared)
    if not settled then
      rec.errors[#rec.errors + 1] = "cancelled shared verdicts: " .. rec.shared.path .. ": " .. settle_trouble
    end
  end
end

--- The jobs run. The exit code to stop with, or nil to go on: 130 once
--- a signal has cancelled the run.
local function execute(ctx: Run): integer | nil
  local rec, jobs = ctx.rec, ctx.jobs
  if #jobs > 0 then
    -- Nil only where the guard cannot be had (no descriptor left for
    -- its pipe): the run then goes unguarded, a signal acting as it
    -- would.
    -- Whatever ends the run, an error escaping it included, takes out
    -- the directory of its sealed databases.
    local _removing <close>: Removal = setmetatable({ rec = rec }, removal_mt)
    local opened, _ = Child.guard()
    if opened == nil then
      run_jobs(rec, jobs, ctx.limits, nil)
    else
      -- A signal the guard caught ends this process when it closes,
      -- once the run is aborted; under a guard of its caller's (test's
      -- `run` called in-process), it is left to that one.
      local guard <close> = opened
      if run_jobs(rec, jobs, ctx.limits, guard) ~= 0 then
        cancel_records(ctx)
        -- A test that failed before the signal keeps its directory,
        -- named as a finished run's report names it: the failures on
        -- stdout, as there, and the errors and the cancellation on stderr.
        say_failures(rec, ctx.failures)
        for _, line in ipairs(ctx.errors) do log:complain("test: ERROR  " .. line) end
        log:complain("test: cancelled; every running test was ended")
        return 130
      end
    end
  end
  return nil
end

--- What the finished tests leave: their coverage and the history and
--- digests kept, the working database closed and the shared cache
--- settled. Everything it meets goes in `errors`, never an exit.
local function settle(ctx: Run)
  local rec, records, tally = ctx.rec, ctx.records, ctx.tally
  local failures, errors, hits, handle = ctx.failures, ctx.errors, ctx.hits, ctx.handle
  local result = ctx.result
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

  local credit_trouble = credit_hits(records, ctx.credited, hits)
  if credit_trouble ~= "" then
    errors[#errors + 1] = "coverage credit: " .. credit_trouble
  end

  -- Every C function must be one some test enters, in this run or in
  -- the run whose verdict stands for it: a standing verdict's hits are
  -- among those credited to it just above. Only a whole run of cosmic's
  -- own tree answers that: a run of chosen tests says nothing about the
  -- rest, and another project's tests owe nothing to the C underneath
  -- them. Every core cosmic tests with observes its own C.
  local function_lines: {string} = {}
  ctx.function_lines = function_lines
  local functions = Coverage.native_functions()
  if ctx.own_tree and ctx.whole and #functions > 0 then
    -- A host whose name cannot be had is held to every function.
    local names, uname_trouble = sys.uname()
    if names == nil then errors[#errors + 1] = "uname: " .. uname_trouble end
    local entered = c_functions.tally(functions, hits, c_functions.sources(ctx.root, functions),
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
      function_lines[#function_lines + 1] = "test: C exemptions a test entered on this core: " ..
        table.concat(entered.stale, ", ")
    end
  elseif ctx.own_tree and #ctx.selectors == 0 and #functions > 0 then
    -- A share's tests enter only some of them; a whole run, which CI's
    -- merge queue makes on every leg, holds the core to all of them.
    function_lines[1] = string.format("test: C functions not checked: shard %d of %d " ..
        "runs part of the suite, and only a whole run enters every one",
      ctx.shard.index, ctx.shard.count)
  end

  local cov_hit, cov_total, cov_trouble =
    write_coverage(records, ctx.built, result.modules, ctx.native_lines, hits, ctx.by_test,
      ctx.run_at_ns)
  if cov_trouble ~= "" then
    errors[#errors + 1] = "coverage: " .. cov_trouble
  end
  local pruned, prune_trouble = prune_history(records, handle.run)
  if not pruned then
    errors[#errors + 1] = "prune: " .. prune_trouble
  end
  -- What a sandboxed run hashed, for the next to look up by `lstat`:
  -- a run of the whole tree keeps only what it looked at, and one of
  -- some of it adds to what the rest looked at before.
  if rec.digests ~= nil and rec.digests.read > 0 then
    local kept, keep_trouble = true, ""
    if ctx.whole then kept, keep_trouble = handle.db:exec("DELETE FROM digests") end
    for _, row in ipairs(kept and declared_key.kept(rec.digests) or {}) do
      if kept then
        kept, keep_trouble = Sqlite.run(records,
          "INSERT OR REPLACE INTO digests (path, signature, sha256) VALUES (?1, ?2, ?3)",
          { text(row[1]), text(row[2]), text(row[3]) })
      end
    end
    if not kept then errors[#errors + 1] = "digests: " .. keep_trouble end
  end
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
  if rec.shared ~= nil then
    local settled, settle_trouble = shared_verdicts.settle(rec.shared, rec.origin, rec.owed,
      Clock.now_ns())
    shared_verdicts.close(rec.shared)
    if not settled then
      log:complain("test: shared verdicts: " .. rec.shared.path .. ": " .. settle_trouble)
    end
  end

  -- A module [`importer.compile`] refused ran no tests at all; every
  -- other module still compiled and ran above, so this only turns the
  -- overall verdict to FAIL, one line per refusal, rather than aborting
  -- the whole run the way an unrelated compile error still does.
  for _, line in ipairs(result.refused) do
    failures[#failures + 1] = line
  end

  ctx.cov_line = test_report.coverage(cov_hit, cov_total)
end

--- The run's verdict said, with the skips, failures and errors that
--- bear on it, and its exit code: 0 when every test passed.
local function report(ctx: Run): integer
  local rec, tally, failures, errors = ctx.rec, ctx.tally, ctx.failures, ctx.errors
  local total, started = ctx.total, ctx.started
  if #failures == 0 and #errors == 0 then
    if total == 0 then
      log:say("test: nothing to run: a test is a top-level `local function " ..
          "test_*` of a *_test.tl file, or a function of the `Example` " ..
          "record a *_example.tl file returns")
    end
    say_skips(rec)
    log:say(ctx.cov_line)
    for _, function_line in ipairs(ctx.function_lines) do log:say(function_line) end
    log:verdict("test", true, test_report.passed({ total = total,
      modules = #ctx.selected_modules,
      ran = tally.ran, cached = tally.cached, skipped = tally.skipped, unchecked = tally.unchecked, na = tally.na,
      every = tally.every, shared = tally.shared },
      clock.took(started) .. ctx.sandbox_summary .. ctx.share_summary))
    return 0
  end
  say_skips(rec)
  say_failures(rec, failures)
  for _, line in ipairs(errors) do
    log:say("test: ERROR  " .. ctx.records_path .. ": " .. line)
  end
  if #errors == 0 then
    log:say(ctx.cov_line)
    for _, function_line in ipairs(ctx.function_lines) do log:say(function_line) end
  end
  log:verdict("test", false, test_report.failed(#failures, total + #ctx.result.refused,
    #errors, clock.took(started) .. ctx.sandbox_summary .. ctx.share_summary))
  return 1
end

--- Builds the tree in the working directory and runs every test it
--- discovered that its selectors choose ([`test.selects`]), printing a
--- verdict line and returning the exit code: 0
--- when every test passed. Each phase above does one part, in order,
--- and the first to answer an exit code ends the run.
--- @param argv the command line, which a stale tool re-enters after
---   rebuilding itself
local function run(argv: {integer:string}): integer
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
  run = function(argv: {integer:string}): integer
    local code = run(argv)
    rebuild_lock.release()
    return code
  end,
  bare = false,
  takes = "exact module names, source paths and directories",
}

return test
