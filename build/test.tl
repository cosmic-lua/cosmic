--- Runs every test the tree defines that a stored verdict does not
--- already answer for, each in a process of its own, and records each
--- verdict into the working database, `o/build.db`, which never ships
--- and is never carried in `o/cosmic.db`.
---
--- A test runs in a worker, `build.test_worker`: this binary again,
--- started with the test's module, name, and temporary directory, in a
--- process group of its own, with its standard streams captured and a
--- deadline -- `--timeout SECONDS`, or `COSMIC_TEST_TIMEOUT`, 30 by
--- default -- past which the whole group is ended and the test fails.
--- Up to `--jobs N` workers run at once, one per processor by default.
--- A worker reports over a pipe what it read and hit and whether the
--- test passed; this process alone opens the build database and writes
--- the verdict. A test that exits, crashes, or hangs its process fails
--- by itself, and what it printed is shown only when it fails.
---
--- A verdict is a function of the test module's key -- its source,
--- its import closure, the tool -- and of every file under the root
--- the test was observed to read, by content hash, loading its module
--- included. While that key stands, a passing verdict stands, and the
--- test is not run again: the lines it hit in the run that produced
--- the verdict, loading its module included, are credited to this one.
--- Verdicts are kept by key, so an edit undone finds its old verdict
--- again. A failing verdict is never reused; the test runs until it
--- passes.
---
--- Opens, stat queries, and directory listings are observed through the
--- syscall table. Observations outside the root do not enter the key;
--- the tool's own hash, in every module key, invalidates everything at
--- once. Environment variables a test reads are part of its key.
---
--- A key names nothing of where the tree is, so every checkout whose
--- workers run sandboxed shares its passing verdicts too
--- (`build.shared_verdicts`): a test no verdict of this checkout
--- answers for stands on one another checkout of the same content
--- reached, or is assumed on one, on the terms it would on its own, and
--- that verdict is then recorded here as this run's.
---
--- A test that spawns a process no sandbox holds (one an unsandboxed
--- worker starts), reads outside the tree beyond its own temporary
--- directories, or reaches the network has no verdict a key can hold.
--- Its run records what it was compiled from and ran under instead, and
--- while that is unchanged and it last passed, it is assumed to pass
--- again rather than run, unless the run is `--all` (or
--- `COSMIC_TEST_ALL=1`, or `COSMIC_SANDBOX=must`) or names it. `--all`
--- (or `COSMIC_TEST_ALL=1`, or an audit) runs every test the run
--- chooses, one a key holds too, whatever stands. All of this is an
--- unsandboxed run's; a sandboxed one's keys are its tests' declared
--- inputs, below.
---
--- A `local function test_*` at the top level of a `kind = "test"`
--- module is otherwise unreachable from outside the file it sits in:
--- `build.importer` appends a generated `return { test_foo = test_foo,
--- ... }` to the module's COMPILED Lua, using the same names discovery
--- already found, so `require`ing the module hands this runner every
--- test as a table entry. The Teal source a test's author wrote is
--- never touched.
---
--- A test function receives one argument: the path of a fresh,
--- writable directory made just for it, reached through a symbolic
--- link -- `<scratch>/tmp`, a link to `<scratch>/real`, in a scratch
--- directory `Fs.mkdtemp` made -- so that code resolving one path with
--- `Fs.absolute` and not another compares them wrongly on every
--- platform, as it would under macOS's `/var`, a link to `/private/var`.
--- The runner removes the scratch directory once the test passes, and
--- leaves a failing test's behind, so its own files stay around to look
--- at. A test that ignores the argument -- the ordinary shape, a bare
--- `assert()` -- is called with it anyway, and Lua drops an argument
--- nobody asked for.
---
--- Every file `cosmic.fs` opens goes through `cosmic.sys`'s shared
--- `open` field, so the worker wraps it, and the other queries a
--- verdict depends on, for the duration of loading the module and of
--- calling the test; see `build.filesystem_observations`.
---
--- A test's inputs are its default ones -- its module's import closure,
--- as source files, the corpora of the fuzz properties it names, and a
--- pinned environment -- and what its module declares in a top-level
--- `Test.needs { ... }` (`cosmic.test`): paths of the tree and the host,
--- variables, the network, processes no sandbox holds, the tool, the
--- projection. `--audit` runs every test it chooses and names, module by
--- module, whatever one read beyond them (`build.test_inputs`), with the
--- declaration that would hold it, and fails the run when any did:
--- sandboxed, what its sandbox refused it, which is what it reads that
--- its module does not declare (`build.refusals`), and unsandboxed, what
--- `build.filesystem_observations` saw it read. A sandboxed test that
--- fails on the first file it was refused is named for that one: once
--- it is declared, an audit again names the next.
--- Each worker runs sandboxed to them (`build.test_sandbox`), with the
--- tree at /tree and its scratch directory beneath /tmp
--- (`test_sandbox.scratch`), and so does every
--- process it starts: a read of anything else finds nothing.
---
--- Where the kernel cannot sandbox a worker (macOS, a host refusing user
--- namespaces), or `COSMIC_TEST_SANDBOX=0` turns it off, the run says
--- so, runs each unsandboxed, and shares no verdict; with
--- `COSMIC_TEST_SANDBOX=1` it fails there instead. With
--- `COSMIC_TEST_KEY=declared` (`key_mode`), such a run keys, stands and
--- shares as a sandboxed one does, by declared inputs, and gives each
--- worker the environment a sandbox would; its worker sees the tree
--- where it is, so its key holds that path too, and it shares only
--- with a checkout at the same path. Nothing holds a worker to
--- the rest of what it declares: the run trusts the declaration, which a
--- sandboxed run of the same test on another host (CI's Linux legs)
--- enforces. Its verdicts are kept apart from sandboxed ones by a
--- runtime of their own, so neither stands for the other.
---
--- Sandboxed, a verdict is keyed by what its test was given rather than
--- by what it read: the digest of its declared inputs, computed before
--- it runs (`build.declared_key`). A test whose key holds a passing
--- verdict, of this checkout or, by that key alone, of another
--- (`build.shared_verdicts`), stands; any other runs, and its verdict is
--- kept only when its inputs still digest to the same key once it has
--- run. A test that declares loopback addresses, the only network it may
--- (`cosmic.test`), runs offline, as every sandboxed test does, and is
--- keyed. None is assumed, and `--all` (or `COSMIC_TEST_ALL=1`, or an
--- audit) runs every test the run chooses, whatever stands.

local Child = require("cosmic.child")
local Cli = require("cosmic.cli")
local Coverage = require("cosmic.coverage")
local Env = require("cosmic.env")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local String = require("cosmic.string")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")
local clock = require("build.clock")
local coverage_report = require("build.coverage")
local c_functions = require("build.c_functions")
local importer = require("build.importer")
local plural = require("build.plural")
local reboot = require("build.reboot")
local schema = require("build.schema")
local teal = require("build.teal")
local tree = require("build.tree")
local work = require("build.work")
local writer = require("build.writer")
local closure_store = require("build.closure_store")
local confine = require("build.confine")
local observations = require("build.filesystem_observations")
local shared_compiles = require("build.shared_compiles")
local shared_verdicts = require("build.shared_verdicts")
local test_inputs = require("build.test_inputs")
local test_sandbox = require("build.test_sandbox")
local test_sandbox_probe = require("build.test_sandbox_probe")
local declared_key = require("build.declared_key")
local hashing = require("build.digest")
local harness_epoch = require("build.harness_epoch")
local host_caches = require("build.caches")
local worker = require("build.test_worker")
local type compiler = require("build.compiler")

local log = require("build.verdict").log
local bind = require("build.bind")
local verb_spec = require("build.verb_spec")

-- Key material -- a file's contents, an observed key and the one it is
-- shared under, the tool's identity salting a compile -- is hashed
-- through build.digest, as build.declared_key's is, not cosmic.hash: a
-- key's value turns on no library module outside the harness
-- (`harness`).
local hex_sha256 = hashing.hex_sha256

local record test
  --- The verb's registration: see build/verb_spec.tl.
  spec: verb_spec.Spec
  --- A verdict's key, and whether every read it was computed from
  --- still answers as it did when recorded: a key from an unstable
  --- read describes no run, so no verdict is kept or looked up under it.
  record VerdictKey
    key: string
    --- The key every checkout of the tree computes alike, which a
    --- verdict is shared under (`build.shared_verdicts`): `key` but for
    --- a stat, keyed by what `held_stat` keeps of it, unless the test
    --- declared it reads stat's times.
    shared: string
    stable: boolean
    --- A path a confined process was given was first walked after the
    --- test started: its verdict is not kept, though what it read is,
    --- so the next run walks that path before it starts.
    late: boolean
  end
  --- What the last run recorded about one test: what it read, which
  --- is what its key is computed over next time.
  record Previous
    --- Nil for a run no key could hold.
    reads: {observations.Observation}
    --- Whether it passed.
    passed: boolean
    --- For a run no key could hold: its verdict's key, what it was
    --- compiled from and ran under, and what of its
    --- reads a key can hold, for `--all`'s absence to assume it on.
    key: string
    identity: string
    kept: {observations.Observation}
    --- The shared key the run reached (`VerdictKey.shared`), which says
    --- what content this checkout already holds evidence for; nil for
    --- a row written before runs recorded it.
    shared: string
  end

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
    --- Answered from the verdict of a run no key could hold, whose test
    --- has changed in nothing its key would have held.
    assumed: integer
    --- Of those that stood or were assumed, how many on a verdict
    --- another checkout reached (`build.shared_verdicts`).
    shared: integer
    --- Of those that ran sandboxed, how many no key holds, which run
    --- every time: one whose module reads a link out of the tree.
    every: integer
    --- Of those that ran, how many passed having said, with
    --- `Test.skip`, that this host could not check them: no verdict is
    --- kept of one, so each runs every time.
    skipped: integer
  end

  --- How a run is bounded, from the command line and the environment.
  record Limits
    --- Each test's deadline.
    timeout_ms: integer
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

--- The variable that says how an unsandboxed run keys its verdicts
--- (`key_mode`).
local key_switch <const> = "COSMIC_TEST_KEY"

--- How an unsandboxed run keys its verdicts, by `key_switch`: "observed",
--- unset or empty, by what each test was seen to read, sharing none;
--- "declared" by what each declares, as a sandboxed run keys them,
--- standing on and sharing them as it does, though nothing holds a
--- worker to its declaration. A sandboxed run keys by what it declares
--- whatever it says. Any other value is an error, so a misspelt one
--- never passes for either.
local function key_mode(): string | nil, string
  local value = Env.get(key_switch)
  if value == nil or value == "" then return "observed", "" end
  if value == "declared" then return "declared", "" end
  return nil, string.format("%s is %q: set it to declared to key an unsandboxed run by " ..
    "what each test declares, or leave it unset", key_switch, value)
end

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

--- `word` as one word a POSIX shell reads back as it is: itself when
--- it holds nothing a shell treats specially, else single-quoted with
--- each `'` written `'\''`. One starting with `-` is prefixed `./`
--- first, so a command does not take it for an option.
function test.shell_word(word: string): string
  if word:sub(1, 1) == "-" then word = "./" .. word end
  if word ~= "" and not word:find("[^%w_./:@%%+=,-]") then return word end
  return "'" .. (word:gsub("'", "'\\''")) .. "'"
end

local text = bind.text

--- What a run read, as `runs` holds it: marked as a run no key could
--- hold, with what it was compiled from and ran under, unless
--- `cacheable`.
local function encoded_reads(reads: {observations.Observation}, cacheable?: boolean,
                             identity?: string): string
  return cacheable == false and observations.encode_unstable(identity, reads) or
    observations.encode(reads)
end

--- A run's key as `runs` holds it: its key, then, when it has one,
--- its shared key after a space.
local function run_key(key: string, shared: string | nil): string
  if shared == nil then return key end
  return key .. " " .. shared
end

local function record_run(handle: Sqlite.Handle, path: string, name: string,
                          passed: boolean, message: string, ran_at_ns: integer,
                          reads: {observations.Observation}, key: string,
                          run_at_ns: integer, elapsed: integer,
                          cacheable?: boolean, identity?: string): boolean, string
  return Sqlite.run(handle,
    "INSERT OR REPLACE INTO runs (path, test, passed, message, ran_at_ns, " ..
    "reads, key, run_at_ns, elapsed_ns) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
    { text(path), text(name), { integer = passed and 1 or 0 }, text(message),
      { integer = ran_at_ns }, text(encoded_reads(reads, cacheable, identity)), text(key),
      { integer = run_at_ns }, { integer = elapsed } })
end

--- What a run left of a test, from what it read as `runs` holds it,
--- the key it reached and whether it passed; nil for an encoding no
--- verdict can come of.
local function previous_of(encoded: string, key: string, passed: boolean): test.Previous | nil
  local reads = observations.decode(encoded)
  if reads ~= nil then return { reads = reads, passed = passed } end
  local unstable = observations.decode_unstable(encoded)
  if unstable == nil then return nil end
  return { key = key, identity = unstable.identity, passed = passed, kept = unstable.reads }
end

--- What the last run left of every test, by "path name".
local function previous_runs(handle: Sqlite.Handle): {string:test.Previous} | nil, string
  local rows, trouble = Sqlite.text_rows(handle,
    "SELECT path, test, reads, key, passed FROM runs")
  if rows == nil then
    return nil, trouble
  end
  local out: {string:test.Previous} = {}
  for _, row in ipairs(rows) do
    local key, shared = row[4]:match("^(%S+) (%S+)$")
    local was = previous_of(row[3], key or row[4], row[5] == "1")
    if was ~= nil then was.shared = shared end
    out[row[1] .. " " .. row[2]] = was
  end
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

--- The staged tree's hashes by path, which is where a read of a
--- staged file gets its hash without a second read.
local function staged_hashes(handle: Sqlite.Handle): {string:string} | nil, string
  local rows, trouble = Sqlite.text_rows(handle, "SELECT path, sha256 FROM files")
  if rows == nil then
    return nil, trouble
  end
  local out: {string:string} = {}
  for _, row in ipairs(rows) do
    out[row[1]] = row[2]
  end
  return out
end

--- Whether a path names a ".." component, which `Fs.within` and
--- `Fs.relative`, being lexical, cannot follow: "<root>/../out/L" is not
--- within the root, and nor, once through a link, need "a/../b" be.
local function climbs(path: string): boolean
  return ("/" .. path .. "/"):find("/%.%./") ~= nil
end

--- Whether a path under the root names the build's own output, o/:
--- the databases it projects (`o/cosmic.db`, whose rows of every module
--- a test declaring `store` reads, and
--- `o/carried.db`), the tool it writes (`o/bin/cosmic`), and whatever
--- else a build or a test leaves there. None of it is staged, so a read
--- of it is keyed by its bytes (`output_hash`), as any file the stage
--- does not hold is.
local function output(relative: string): boolean
  return relative == "o" or relative:sub(1, 2) == "o/"
end

--- The working database, and SQLite's files beside it: every run
--- rewrites it (its verdicts, its runs), so no key over what a test
--- read of it holds is ever reached again, and a verdict that read it
--- is not kept (`stable` false) rather than hashing it to no purpose.
local function working_database(relative: string): boolean
  return relative == "o/build.db" or relative:sub(1, 11) == "o/build.db-"
end

--- The hash of a file under o/ a test opened, for its line in a key:
--- its bytes', as a build writes the same bytes from the same tree in
--- every checkout (the projections are vacuumed, the tool is the core
--- and its carried database), so a sibling's matches. The build keeps
--- no record of these bytes a run could read instead: `boot_hash` and
--- `image_hash` name what the running tool was built from, which need
--- not be the tool at o/bin/cosmic (o/sanitized's runs the checked
--- suite). What is read here is remembered in `key_parts` by what `stat`
--- says of the file (o/bin/cosmic, the largest, is read once a run), so
--- a test pays a stat and a file rewritten since is read again.
local function output_hash(root: string, relative: string,
                           key_parts: {string:string}): string
  local path = root .. "/" .. relative
  -- What stat says of it, the change time included, which no write
  -- can set back, unlike the modification time `cp -p` or `touch -r`
  -- gives a same-size rewrite.
  local stat = "missing"
  local st, _ = sys.stat(path)
  if st ~= nil then
    stat = table.concat({ tostring(st.size), tostring(st.mode), tostring(st.mtime),
      tostring(st.mtime_ns), tostring(st.ctime), tostring(st.ctime_ns), tostring(st.ino),
      tostring(st.dev) }, " ")
  end
  local memo_key = "\4o\0" .. relative
  local memo = key_parts[memo_key]
  if memo ~= nil and memo:sub(1, #stat + 1) == stat .. "\0" then
    return memo:sub(#stat + 2)
  end
  local data, _ = Fs.read(path)
  local hash = data ~= nil and hex_sha256(data) or "missing"
  key_parts[memo_key] = stat .. "\0" .. hash
  return hash
end

--- A recorded read as a path under the root, or nil when it is not
--- one: a test's own scratch directory, or anything else outside the
--- tree, is not an input to it. An absolute path outside the root as
--- written, or one that climbs with "..", is under it when what it
--- resolved to is (`resolutions`, by path, from its "r" or "t"
--- observation). It is then keyed by that resolved name, so the file's
--- own line is the same for every spelling of it. With no resolution it
--- is outside.
-- TODO: a path under the root as written is keyed by its name there,
-- though it may cross a link in the tree that leads out (proj/x to
-- /out/L to proj/a/f): a test that retargets /out/L after reading
-- proj/x keys proj/x by where it leads at the end. Resolve an in-tree
-- read whose path crosses a link as it is read, noting an "r" for it
-- as for one outside the tree, once that costs less than a realpath
-- per in-tree read (a set of the tree's links, from the stage).
local function under_root(root: string, path: string,
                          resolutions: {string:string}): string | nil
  local relative = path
  local rest, _ = Fs.relative(path, root)
  if rest ~= nil and not climbs(path) then
    relative = rest
  elseif climbs(path) or path:sub(1, 1) == "/" then
    local real = resolutions[path]
    if real == nil or real == "" then return nil end
    local resolved, _ = Fs.relative(real, root)
    if resolved == nil then return nil end
    relative = resolved
  end
  return relative
end

--- What each "r" or "t" observation in `reads` says its path resolved
--- to: the answer the test's own read recorded, or, for an "r" a stored
--- run gives back without its answer, what the path resolves to now. An
--- "r" that resolves into the root enters the key itself, so one that
--- resolves elsewhere since keys differently. A "t", a path under the
--- test's own directory, is stored with its answer and never enters
--- the key: that directory's name is new in every run, and gone after.
--- The second answer is the same of each "v" and "w", an lstat's or a
--- readlink's resolution, which stops short of a link the path ends
--- in: the same path an open or a stat also read resolves elsewhere.
local function resolutions_of(reads: {observations.Observation}): {string:string},
                                                                  {string:string}
  local followed: {string:string} = {}
  local unfollowed: {string:string} = {}
  for _, observation in ipairs(reads) do
    local kind = observation.kind
    local link = kind == "v" or kind == "w"
    local out = link and unfollowed or followed
    if (kind == "r" or kind == "t" or link) and out[observation.path] == nil then
      local answer = observation.answer
      if kind == "r" and answer == "" then
        answer = observations.resolution(observation.path)
      elseif kind == "v" and answer == "" then
        answer = observations.link_resolution(observation.path)
      end
      out[observation.path] = answer
    end
  end
  return followed, unfollowed
end

--- Which of `resolutions_of`'s two answers judges a read of `kind`:
--- the second for an lstat, a readlink or a tree digest.
local function resolved_for(kind: string, followed: {string:string},
                            unfollowed: {string:string}): {string:string}
  if kind == "l" or kind == "k" or kind == "g" or kind == "j" then return unfollowed end
  return followed
end

--- The environment every worker this process starts has
--- (`test.worker_environment`), which is what a test's read of a
--- variable answered and so what its key holds: defined beside it.
local worker_view: function(): {string:string}

--- A stat answer (`observations.stat_answer`) as a shared key holds
--- it: what the path is, its permissions and, but for a directory, its
--- size -- what any checkout of the same tree answers alike. The times,
--- inode, device, link count and owner a checkout's own files were
--- given are no part of what the tree holds, and would keep a verdict
--- from standing in any checkout but the one that reached it; a
--- checkout's own key keeps them, so a file touched there runs what
--- stat'd it again -- but for one under o/, which the build rewrites,
--- and no sandboxed key holds them at all.
---
--- The rule that makes that sound (R5): a test must not depend on the
--- times, inode, device, link count or owner of a file it did not make.
--- One that needs them makes its own files in its temporary directory
--- and sets them -- `utimensat` for the times, a fresh file for a new
--- inode -- so they are the same in every checkout.
-- TODO: enforce the rule under a worker's hold, as the store's is held:
-- have `stat`, `lstat` and `fstat` of a path of the tree answer fixed
-- times and inode there, once core/syscalls_fs.c's stat takes a hold
-- from build.test_worker as core/store.c's lookups do (C, and a boot):
-- today a test that leans on a file of the tree's times sees what its
-- checkout gave it, and stands on a sibling's verdict where they differ.
local function held_stat(answer: string): string
  local size, mode, kind = answer:match("^ok (%S+) (%S+) (%S+)")
  if size == nil then return answer end
  if kind == "dir" then size = "-" end
  return "ok " .. size .. " " .. mode .. " " .. kind
end

--- What one test's verdict is a function of: the test itself, its
--- module's key, the runtime it ran under -- see `build.work`'s
--- `Identities` -- and the current hash of every file under the root
--- it read, by name. A file the stage holds is hashed already; any
--- other is read for it here, and one that is gone says so.
---
--- Nothing in a key names where the tree is: a read under the root is
--- keyed by its name there (`declared_key.tree_name`), a variable by what
--- `observations.held_variable` keeps of it, and a path a confined
--- process was given by what `observations.unveiled_answer` says of
--- it; its `shared` key keeps of a stat only what `held_stat` does,
--- so another checkout of the same content computes the same shared
--- key, and a verdict one reached stands in the other
--- (`build.shared_verdicts`).
---
--- Exposed as `test.verdict_key` (`standing` and `finish` use it the
--- same as any other caller would) so `test_test.tl` can pin two
--- properties directly, without a compiled tree or a work database to
--- reach them through: that distinct inputs never collide on the same
--- key, and that a read whose current answer differs from what was
--- recorded turns `stable` false -- the two ways a wrong key could let
--- a verdict stand for a test it does not describe. Given `started_ns`,
--- when the test's run started, a path a confined process was given
--- that is first walked after it turns `stable` false too. A variable
--- is keyed by what `environment` holds, the environment the test's
--- worker had: every worker's (`test.worker_environment`) when nil.
function test.verdict_key(root: string, hashes: {string:string}, id: string,
                          module_key: string, runtime: string,
                          reads: {observations.Observation},
                          key_parts: {string:string},
                          started_ns?: integer,
                          environment?: {string:string}): test.VerdictKey
  local view = environment or worker_view()
  local followed, unfollowed = resolutions_of(reads)
  local seen: {string:boolean} = {}
  local answers: {string:string} = {}
  local stable = true
  local late = false
  local paths: {string} = {}
  for _, observation in ipairs(reads) do
    local kind = observation.kind
    local keyed = kind == "e" or kind == "u" or kind == "c" or kind == "b"
    if kind == "r" or kind == "v" then
      local real = (kind == "v" and unfollowed or followed)[observation.path]
      keyed = real ~= "" and Fs.within(real, root)
    end
    if keyed then
      local identified = kind .. " " .. observation.path
      if not seen[identified] then
        seen[identified] = true
        paths[#paths + 1] = identified
      end
      if observation.answer ~= "" then
        local before = answers[identified]
        if before ~= nil and before ~= observation.answer then stable = false end
        answers[identified] = observation.answer
      end
    elseif kind == "o" or kind == "s" or kind == "d" or kind == "l" or kind == "k" or
        kind == "a" or kind == "g" or kind == "j" then
      local relative = under_root(root, observation.path,
        resolved_for(kind, followed, unfollowed))
      -- An lstat, a readlink or a walk of a path that ends in "/"
      -- follows a link its last name is, which `Fs.relative` would drop:
      -- kept, so the key asks what the test asked.
      if relative ~= nil and relative ~= "." and
          (kind == "l" or kind == "k" or kind == "g" or kind == "j") and
          observation.path:sub(-1) == "/" and Fs.within(observation.path, root) and
          not climbs(observation.path) then
        relative = relative .. "/"
      end
      if relative ~= nil and working_database(relative) then stable = false end
      local identified = kind .. " " .. (relative or "")
      if relative ~= nil and not seen[identified] then
        seen[identified] = true
        paths[#paths + 1] = identified
      end
      if relative ~= nil and observation.answer ~= "" then
        local before = answers[identified]
        if before ~= nil and before ~= observation.answer then stable = false end
        answers[identified] = observation.answer
      end
    end
  end
  table.sort(paths)
  -- Bump the recording generation when the invariants of a reusable
  -- verdict change, so no verdict of an earlier one stands. A verdict
  -- recorded under this one has these invariants:
  -- - It is never kept without its coverage, whatever infrastructure
  --   error came after it.
  -- - The header is framed through the same `key_part` hex-encoding
  --   every read line uses, so two distinct (id, module_key, runtime)
  --   triples never concatenate to the same string. A raw space would
  --   not do: `id` (a test's own "path name") carries one, and `runtime`
  --   is the runtime identity and the digest of the binary's data tables
  --   joined by " tables " (test's `run`).
  -- - Its test ran in a worker process of its own: its reads and hits
  --   are its module's load and its own call, nothing an earlier test in
  --   the same process loaded.
  -- - No run that reached the network or changed its working directory
  --   is kept.
  -- - A read outside the tree that resolved into it (an "r"
  --   observation) is keyed.
  -- - Nothing in the key names where the tree is (see above), so every
  --   checkout of one tree computes the same key.
  -- - The key holds what the syscall table's queries answered: an
  --   lstat, a readlink, a realpath, the working directory, and whether
  --   the program's own path answered.
  -- - Every call is observed in its binding (core/observed.h), a
  --   reference a module took before the capture included, and a read's
  --   path is resolved as the call is made, not as the capture ends.
  -- - A stat's change time is recorded, and every field of a stat keyed
  --   (the shared key keeps less: `held_stat`).
  -- - Each file a connection opened before the capture holds as it
  --   begins is noted.
  -- - A test's `sys.tree_digest` of a path of the tree is keyed by what
  --   the walk answers ("g" and "j").
  local header = declared_key.key_part("i", id, declared_key.key_part("m", module_key, runtime))
  local lines: {string} = { "recording-12", "module-load-reads-v1", header }
  local shared_lines: {string} = { "shared-recording-6", "module-load-reads-v1", header }
  for _, identified in ipairs(paths) do
    local kind, relative = identified:match("^(.) (.*)$")
    local current: string
    if kind == "e" then
      current = observations.getenv_current(relative, view)
    elseif kind == "r" then
      current = observations.resolution(relative)
    elseif kind == "v" then
      current = observations.link_resolution(relative)
    elseif kind == "u" then
      -- A path a confined process was given may be a whole directory,
      -- one most of a run's tests give theirs (the system's own), so
      -- what it holds is walked once a run.
      local function walk(): string
        local memo_key = "\1u\0" .. relative
        local walked_answer = key_parts[memo_key]
        if walked_answer == nil then
          walked_answer = observations.unveiled_answer(relative, root)
          key_parts[memo_key] = walked_answer
          key_parts["\2u\0" .. relative] = tostring(Time.monotonic_ns())
        end
        -- Walked only after the test started, the answer may be of what
        -- the path became since its process read it: such a verdict is
        -- not kept, and the next run, which walks it first, keeps one.
        -- TODO: walk what a sandboxed worker holds a process to
        -- (`test_sandbox.Plan`'s `held`) before its test starts, once
        -- such a walk is cheap enough to make for every test that might
        -- start one (a digest remembered by what `lstat` says, say):
        -- today a test that starts a process keeps no verdict until its
        -- second run.
        local walked = math.tointeger(key_parts["\2u\0" .. relative]) or 0
        if started_ns ~= nil and walked >= started_ns then late = true end
        return walked_answer
      end
      current = walk()
      if current:sub(1, 10) == "unkeyable " then stable = false end
    elseif kind == "o" then
      current = hashes[relative]
      if current == nil and output(relative) then
        current = output_hash(root, relative, key_parts)
      elseif current == nil then
        local data, _ = Fs.read(root .. "/" .. relative)
        current = data ~= nil and hex_sha256(data) or "missing"
      end
    elseif kind == "s" then
      current = observations.stat_answer(root .. "/" .. relative)
    elseif kind == "l" then
      current = observations.lstat_answer(root .. "/" .. relative)
    elseif kind == "k" then
      current = observations.readlink_answer(root .. "/" .. relative)
    elseif kind == "a" then
      current = observations.realpath_answer(root .. "/" .. relative)
    elseif kind == "c" then
      current = observations.cwd_answer()
    elseif kind == "b" then
      current = observations.executable_answer()
    elseif kind == "g" or kind == "j" then
      -- The walk itself, again: by contents for "g", and by what
      -- `lstat` says of each entry for "j" -- stamps a test that walks
      -- by them reads, so keyed whole in both keys, and never standing
      -- in another checkout, whose inodes and times are its own.
      -- TODO: key a link beneath the path whose target names the tree
      -- by `tree_name` in the shared key, as a readlink's answer is,
      -- once `sys.tree_digest` can answer its entries' lines rather
      -- than their digest alone: today such a link keys the checkout's
      -- location, and the verdict stands only in the checkout that ran it.
      -- Walked once a run, as a path a confined process was given is,
      -- and late for a test that started before the walk.
      local memo_key = "\1" .. kind .. "\0" .. relative
      current = key_parts[memo_key]
      if current == nil then
        current = observations.digest_answer(root .. "/" .. relative, kind == "g")
        key_parts[memo_key] = current
        key_parts["\2" .. kind .. "\0" .. relative] = tostring(Time.monotonic_ns())
      end
      local walked = math.tointeger(key_parts["\2" .. kind .. "\0" .. relative]) or 0
      if started_ns ~= nil and walked >= started_ns then late = true end
    else
      current = observations.directory_answer(root .. "/" .. relative)
    end
    local answer = answers[identified] or current
    if answers[identified] ~= nil and answers[identified] ~= current then
      stable = false
    end
    local named = relative
    local shared_answer: string = nil
    if kind == "e" then
      local memo_held = "\3e\0" .. relative .. "\0" .. answer
      local held = key_parts[memo_held]
      if held == nil then
        held = observations.held_variable(relative, answer, view, root)
        key_parts[memo_held] = held
      end
      answer = held
    elseif (kind == "s" or kind == "l") and output(relative) then
      -- When the build last wrote a file is its own, not the tree's:
      -- held as the shared key holds it here too, lest a test that
      -- stats o/cosmic.db run again after every edit rewrites it.
      answer = held_stat(answer)
    elseif kind == "s" or kind == "l" then
      shared_answer = held_stat(answer)
    elseif kind == "k" or kind == "a" or kind == "c" then
      -- A path a query answered names where the tree is: whole in the
      -- checkout's own key, and by `tree_name` in the shared one, as
      -- every checkout of the tree answers alike.
      local value = answer:match("^ok (.*)$")
      if value ~= nil then shared_answer = "ok " .. declared_key.tree_name(value, root) end
    elseif kind == "r" or kind == "v" then
      answer = declared_key.tree_name(answer, root)
    elseif kind == "u" then
      named = declared_key.tree_name(relative, root)
    end
    -- The same (kind, relative, answer) triple recurs across the run's
    -- tests constantly -- module loads and shared fixtures are read by
    -- most of them -- so its encoded line, which does not depend on
    -- anything but the triple itself, is worth remembering once.
    local function part_of(said: string): string
      local memo_key = kind .. "\0" .. named .. "\0" .. said
      local part = key_parts[memo_key]
      if part == nil then
        part = declared_key.key_part(kind, named, said)
        key_parts[memo_key] = part
      end
      return part
    end
    local part = part_of(answer)
    lines[#lines + 1] = part
    shared_lines[#shared_lines + 1] = shared_answer ~= nil and part_of(shared_answer) or part
  end
  return { key = hex_sha256(table.concat(lines, "\n")),
    shared = hex_sha256(table.concat(shared_lines, "\n")), stable = stable and not late,
    late = late }
end

--- The devices whose every answer is the same, whenever a test reads
--- them: no input a key need hold.
local constant_devices: {string:boolean} = { ["/dev/null"] = true, ["/dev/zero"] = true }

--- Whether `path` names what /proc says of the test's own process and
--- nothing else: its status, its descriptors' flags, its threads. What
--- a test reads there describes the worker running it, no input from
--- outside it. Only these leaves: /proc/self also leads to the host's
--- root, its working directory, its environment and its network.
local function own_process(path: string): boolean
  if ("/" .. path .. "/"):find("/%.%.?/") ~= nil or path:find("//", 1, true) then
    return false
  end
  local rest = path:match("^/proc/self(.*)$") or path:match("^/proc/thread%-self(.*)$")
  if rest == nil then return false end
  return rest == "/status" or rest == "/fdinfo" or rest:match("^/fdinfo/%d+$") ~= nil or
    rest == "/task" or rest:match("^/task/%d+$") ~= nil or
    rest:match("^/task/%d+/status$") ~= nil
end

--- Whether a passing verdict over `reads` is safe to reuse later. False
--- when the run:
---
--- - spawned a process other than a confined one, an input no
---   observation can hash (see `confine.confine`);
--- - made a request over the network, or read a relative path when its
---   working directory could not be told (an "x" observation); or
--- - opened, stat'd, or listed a path outside `root`, `scratch`, and
---   every directory an "m" observation anywhere in the same list shows
---   the test made for itself. The whole list counts, not only what
---   comes earlier: `Fs.mkdirs` stats a directory to see whether it is
---   already there before the "m" observation that creates it, and that
---   check would otherwise count as a foreign read.
---
--- A path with an "r" or "t" observation is judged by what it resolved
--- to as the test read it (see `under_root`), so a link in the test's
--- own directory leading out of it is outside. One that climbs with ".."
--- and has none is outside. A device whose every answer is the same
--- (`constant_devices`) and the test's own process in /proc
--- (`own_process`) are not. An environment read is keyable: its answer
--- enters the verdict key like a file's hash does. So is a read beneath
--- one of `caches`, the host caches the test's module declares
--- (`build.caches`), which are content-addressed and never change a
--- result: excluded as `scratch` is.
---
--- Exposed alongside `test.verdict_key` so `test_test.tl` can exercise
--- it directly.
-- TODO: key a stat or a listing outside the tree by its answer, as the
-- key holds an environment read, rather than refusing the run: a test
-- whose code searches PATH (build/todos_git_test.tl, for git) stats host
-- directories whose answers a key could hold.
function test.keyable(root: string, scratch: string,
                      reads: {observations.Observation}, caches?: {string}): boolean
  local followed, unfollowed = resolutions_of(reads)
  local function under(dir: string, path: string): boolean
    return Fs.within(path, dir)
  end
  local made: {string} = {}
  for _, observation in ipairs(reads) do
    if observation.kind == "p" or observation.kind == "x" then
      return false
    elseif observation.kind == "m" then
      made[#made + 1] = observation.path
    end
  end
  for _, observation in ipairs(reads) do
    local kind = observation.kind
    -- A device whose every answer is the same, and the test's own
    -- process in /proc, are no input to a read of them -- but a walk
    -- goes beneath them, and a walk by stamps reads a device's times.
    local read = kind == "o" or kind == "s" or kind == "d" or kind == "l" or kind == "k" or
      kind == "a"
    if (read and not constant_devices[observation.path] and not own_process(observation.path)) or
        kind == "g" or kind == "j" then
      local path = observation.path
      local real = resolved_for(kind, followed, unfollowed)[path]
      if real == "" or (real == nil and climbs(path)) then return false end
      local judged = real or path
      local cached = false
      for _, cache in ipairs(caches or {}) do
        if under(cache, judged) or under(cache, path) then cached = true end
      end
      if judged:sub(1, 1) == "/" and not under(root, judged) and
          not under(scratch, judged) and not cached then
        local made_here = false
        for _, dir in ipairs(made) do
          if under(dir, judged) or (real ~= nil and
              under(observations.resolution(dir), judged)) then
            made_here = true
            break
          end
        end
        if not made_here then
          return false
        end
      end
    end
  end
  return true
end

--- The files of the tree a worker's own store reads beside the
--- projection it attached before any test began: SQLite's journal and
--- WAL, which it asks after as it reads a page. No test's input.
local function store_probe(relative: string): boolean
  return relative == "o/cosmic.db-journal" or relative == "o/cosmic.db-wal"
end

--- Whether a read found nothing there: what it answered is ENOENT or
--- ENOTDIR, or, for an open, whose answer no observation keeps, what
--- `lstat` says of `path` now is. A sandbox that shows a test only its
--- inputs answers such a read the same whether the path is declared or
--- not, so the audit asks no declaration of it. Not quite the same
--- answer: where the host has a file on the way that the sandbox does
--- not show, ENOTDIR here is ENOENT there, which a test telling the two
--- apart would see.
-- TODO: judge an open by what it answered, once the syscall log keeps
-- an open's errno (core/observed.c) as it keeps a stat's: a file the
-- test made and removed again reads as one never there.
-- TODO: a read that found nothing today may find something tomorrow,
-- when the path appears -- an optional config, a cache not yet made --
-- and a sandbox hides it then too, so a test whose behaviour turns on
-- such a path must declare it though the audit asks nothing of it.
-- Flag an absent path the test's behaviour depends on once the audit
-- can tell one (a read under a declared-optional list in `cosmic.test`,
-- or the audit run again with the path made present).
local function found_nothing(observation: observations.Observation, path: string,
                             sandboxed?: boolean): boolean
  local function nothing(errno: integer): boolean
    return errno == sys.ENOENT or errno == sys.ENOTDIR
  end
  -- A sandboxed read of what was not given found nothing whatever the
  -- host has: what `lstat` says there now is what it would have found.
  local errno = observation.answer:match("^error %x* (%d+)$")
  if errno ~= nil and not sandboxed then return nothing(math.tointeger(tonumber(errno)) or 0) end
  if (observation.kind ~= "o" and not sandboxed) or path:sub(1, 1) ~= "/" then return false end
  local st, _, number = sys.lstat(path)
  return st == nil and nothing(number)
end

--- What of `reads`, one test's observations, `effective` does not hold
--- (`build.test_inputs`), as the field of `cosmic.test`'s `Needs` that
--- would declare it, once each:
---
--- - each read of the tree or the host beyond it;
--- - each variable, each request, and each thing a process was handed
---   past observation;
--- - each program of the system's own a process ran
---   (`confine.in_system`), or the interpreter a script it ran names.
---
--- A read of the system's own paths by the test itself asks `host` of
--- them, which keys a file by its contents. A program run from them asks
--- `system`, since what a host program reads beside itself -- its
--- loader, its libraries, its configuration -- is no observation.
---
--- What no test declares is left out, as `test.keyable` leaves it out of
--- a key:
---
--- - what a read landed on in the test's own directory, `scratch`, or
---   one it made (a link there that leads out is judged by where it
---   leads), and what a stat asks of a directory above them or the tree;
--- - a device whose every answer is the same, and the test's own process
---   in /proc;
--- - each path a confined process was given, which `confine.confine`
---   declares already, or the worker's own sandbox holds it to;
--- - a read that found nothing there (`found_nothing`).
---
--- `tool` names the program running the tests, a read of which is a
--- `tool` finding, as one of o/bin/cosmic is. `sandboxed` says the reads
--- were a sandboxed worker's: what it was refused (`build.refusals`),
--- where the host has each path. It found nothing of what it was not given,
--- so a read that found nothing is judged by what the host has there
--- instead; and its environment is only what its module declares, so a
--- read of all of it, by a process started with the worker's own, is no
--- finding. Exposed so build/test_audit_test.tl can hold it to
--- observations directly.
function test.audited(root: string, scratch: string, effective: test_inputs.Effective,
                      reads: {observations.Observation},
                      tool: {string}, sandboxed?: boolean): {test_inputs.Finding}
  local followed, unfollowed = resolutions_of(reads)
  local made: {string} = {}
  for _, observation in ipairs(reads) do
    if observation.kind == "m" then made[#made + 1] = observation.path end
  end
  local out: {test_inputs.Finding} = {}
  local seen: {string:boolean} = {}
  local function add(field: string, value: string)
    if seen[field .. "\0" .. value] then return end
    seen[field .. "\0" .. value] = true
    out[#out + 1] = { field = field, value = value }
  end
  local function own(path: string): boolean
    if Fs.within(path, scratch) then return true end
    -- A declared cache, the test's to read and write (`build.caches`).
    for _, cache in ipairs(effective.cache_paths or {}) do
      if Fs.within(path, cache) then return true end
    end
    for _, dir in ipairs(made) do
      if Fs.within(path, dir) or Fs.within(path, observations.resolution(dir)) then
        return true
      end
    end
    return false
  end
  -- A directory above the test's own, one it made, or the tree: asking
  -- what it is, or where it leads, is part of reaching them.
  local function on_the_way(path: string): boolean
    if Fs.within(scratch, path) or Fs.within(root, path) then return true end
    for _, cache in ipairs(effective.cache_paths or {}) do
      if Fs.within(cache, path) then return true end
    end
    for _, dir in ipairs(made) do
      if Fs.within(dir, path) or Fs.within(observations.resolution(dir), path) then
        return true
      end
    end
    return false
  end
  -- TODO: hold each path a confined process was given ("u") to the
  -- effective inputs too, once `confine.confine` narrows a
  -- worker's own inputs rather than adding to them: a sandboxed worker
  -- can give its process only what it has (nested confinement). Only
  -- the program itself is held to them today, below.
  local function the_tool(path: string): boolean
    for _, program in ipairs(tool) do
      if path == program then return true end
    end
    return false
  end
  -- This program, started by the test -- given to a confined process
  -- ("u"), as `confine.itself()` gives it, or started unconfined
  -- ("p") -- runs what no key of the test holds but the tool's: a
  -- `tool` finding.
  local function runs_the_tool(path: string): boolean
    return the_tool(path) or the_tool(observations.resolution(path))
  end
  for _, observation in ipairs(reads) do
    local kind, path = observation.kind, observation.path
    -- Sandboxed, every process the test starts is noted "u" of all its
    -- worker's sandbox holds, the program among it, whatever it runs; a
    -- sandboxed worker that may not run the program is refused it
    -- (`confine.forbid_running`) rather than audited.
    if (kind == "p" or (kind == "u" and not sandboxed)) and not effective.tool and
        path:sub(1, 1) == "/" and runs_the_tool(path) then
      add("tool", path)
    end
    if (kind == "p" or kind == "y") and not effective.system and path:sub(1, 1) == "/" and
        confine.in_system(path) then
      -- A program of the system's own, or the interpreter a script's
      -- first line names: a sandboxed worker is given the system's
      -- paths only where its module declares `system`, and one declared
      -- in `host` alone runs without the loader and the libraries it
      -- reads unobserved.
      add("system", path)
    end
    if kind == "p" or kind == "y" then
      -- A process started needs no declaration: a sandboxed worker's is
      -- held by its sandbox, and an unsandboxed one's run never stands
      -- (`cosmic.test`'s `processes`) -- but for what it runs, above.
    elseif kind == "x" then
      -- A start refused a root of its own, which a worker a Landlock
      -- ruleset holds cannot make (`confine.nests_note`); a request's
      -- URL, which names its scheme; any other is what no observation
      -- could account for, which a process is handed.
      if path:sub(1, #confine.nests_note) == confine.nests_note then
        if not effective.nests then add("nests", path:sub(#confine.nests_note + 1)) end
      elseif path:match("^%s*%a[%w+.-]*:") ~= nil then
        if not test_inputs.covers_network(effective, path) then add("network", path) end
      elseif not effective.processes and not sandboxed then
        add("processes", "unobservable: " .. path)
      end
    elseif kind == "e" then
      -- A name no variable can have: the whole environment -- of a
      -- sandboxed worker, only what its module declares and the pinned
      -- variables, which a process it starts inherits.
      local name = path:sub(1, 1) == "\0" and "*" or path
      if not test_inputs.covers_env(effective, name) and not (sandboxed and name == "*") then
        add("env", name)
      end
    elseif (kind == "o" or kind == "s" or kind == "d" or kind == "l" or kind == "k" or
        kind == "a" or kind == "g" or kind == "j") and not constant_devices[path] and
        not own_process(path) then
      local resolved = resolved_for(kind, followed, unfollowed)
      local relative = under_root(root, path, resolved)
      local real = resolved[path]
      local judged = (real ~= nil and real ~= "") and real or path
      if relative ~= nil then relative = test_inputs.plain(relative) end
      -- Where the read landed, not the name it was asked by: a link in
      -- the test's own directory that leads out reads what it leads to.
      if own(judged) or found_nothing(observation, judged, sandboxed) or
          ((kind == "s" or kind == "l" or kind == "a") and on_the_way(judged)) then
        -- The test's own, on the way to it, or nothing there.
      elseif relative ~= nil then
        if not store_probe(relative) and
            not test_inputs.covers_tree(effective, relative, kind) then
          if relative == "o/bin/cosmic" then
            add("tool", relative)
          elseif relative == "o/cosmic.db" then
            add("store", relative)
          else
            add("reads", relative)
          end
        end
      elseif the_tool(judged) or the_tool(path) then
        if not effective.tool then add("tool", judged) end
      elseif not test_inputs.covers_host(effective, test_inputs.plain(judged), kind) and
          not (effective.system and confine.in_system(judged)) then
        local plain = test_inputs.plain(judged)
        -- A program looked for in a directory of the system's programs
        -- (`Proc.find`'s walk of PATH), which the host has there: what
        -- runs it needs its loader too, which `host` would not give.
        if confine.in_system(plain) and plain:match("/s?bin/[^/]+$") ~= nil then
          add("system", plain)
        else
          -- By the variable the module declares that says where it is,
          -- where one does: the same declaration holds it wherever the
          -- host has it.
          add("host", test_inputs.spelling(effective, plain))
        end
      end
    end
  end
  -- Where it asks `system`, that holds each path of the system's it
  -- would ask `host` of too.
  if not effective.system then
    local system = false
    for _, finding in ipairs(out) do
      if finding.field == "system" then system = true end
    end
    if system then
      local kept: {test_inputs.Finding} = {}
      for _, finding in ipairs(out) do
        if not (finding.field == "host" and confine.in_system(finding.value)) then
          kept[#kept + 1] = finding
        end
      end
      out = kept
    end
  end
  return out
end

--- One test's hits as `coverage_by_test` holds them: a line per module,
--- in path order, the path, a tab, then the lines it hit, ascending and
--- comma-separated. Module paths hold neither tabs nor newlines.
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

--- Folds every line `encoded` (as `encode_hits` writes it) names into
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
--- union of hit lines per module matters to `write_coverage`, never
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

--- Every line `build.coverage` found for every non-vendor module
--- `modules` holds, added as a new snapshot for `run_at_ns`. Rows are
--- never replaced, only later pruned by `prune_history`, so a file's
--- coverage trend over the kept window of runs is a plain query away
--- rather than only the latest run's numbers.
---
--- Also writes, for every test that ran, which of the lines it hit into
--- `coverage_by_test`, one row a test, tagged with the test's identity
--- ("path name", as `by_test` is keyed) and its hits as `encode_hits`
--- wrote them when it finished. A test whose verdict stood is not in
--- `by_test`, since its row from the run that produced the verdict
--- still stands for it.
---
--- `native_lines` are the core's own C lines (`Coverage.native_lines`),
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
  -- when some window's hits name it (see `Coverage.native_lines`).
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
  name: string
  id: string
  --- The directory the runner made for the test, holding `real` and
  --- `tmp`, a link to it; removed once the test passes.
  scratch: string
  tmp: string
  --- How its worker is sandboxed, when it is (`build.test_sandbox`).
  plan: test_sandbox.Plan
  --- Sandboxed, the key its verdict is reached under, over its
  --- declared inputs as they were before it started
  --- (`build.declared_key`); nil for one that reaches a network beyond
  --- loopback, or an unsandboxed run's.
  declared: string
  passed: boolean
  handle: Child.Handle
  started_ns: integer
  deadline_ns: integer
end

--- The digest of the zones and CA roots the running binary's own
--- database carries (`schema.tables_digest`), searched alone so no
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
--- or that writes what it is given (`binary_harness`).
local record Harness
  --- A digest of each module of the test harness by its name, source
  --- and bytecode (`test.harness`): what a worker runs, and the code
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
  --- each store's address (`build.closure_store`'s `address`).
  store_salt: string
  --- The set of the names of the modules the binary carries, which
  --- `worker.judge` holds what a worker loaded to.
  carried: {string:boolean}
end

--- The modules of the harness beside what every worker loads
--- (`build.test_worker`'s `worker.loads`): build.test_sandbox and the
--- tree modules it requires, build.caches and build.zig_caches.
--- build.test_sandbox makes the plan of a worker's sandbox (`plan`):
--- what it binds, unveils and holds, and the environment it gives.
--- build.caches says where each declared host cache is bound from and
--- makes it; build.zig_caches does so for zig's.
---
--- What else of the runner shapes a worker is the worker's own module's,
--- which `worker.loads` names: its command line and start options, and
--- how its report is read into a verdict (`worker.invocation`,
--- `worker.judge`). The rest of build.test passes it only what a key
--- holds by itself (the test's declaration, its closure's names, which
--- the store's address holds, whether it may run this program
--- (`Spec.runs_tool`), and its timeout) or what `key_code` holds (the
--- names of the tree's modules and declarations, which decide what a
--- worker's holds refuse).
---
--- None of it is keyed by its code: the epoch stands for it
--- (build/harness_epoch.tl), and an edit to it fails
--- build/harness_epoch_test.tl until the epoch is bumped or the edit
--- acknowledged. That test also fails where a module here or in
--- `worker.loads` requires one of the tree the harness does not name.
-- TODO: key the sandbox's plan as data -- its unveils and binds, with
-- the tree, the scratch directory and the host caches named relative to
-- what they stand for, and its environment -- rather than leaving it to
-- the epoch, once `held` and the caches' binds name no host location:
-- then a change to a hold or a bind moves every key it touches by
-- itself, where today it moves none unless someone bumps the epoch by
-- hand.
local harness_own <const>: {string} = { "build.test_sandbox", "build.caches",
  "build.zig_caches" }

--- The modules of the harness held alone, by their own source and
--- bytecode, their requires not walked: cosmic.child, whose `start`
--- turns a worker's plan (`test_sandbox.Plan`'s `sandbox`) into what
--- spawn holds it to -- the unveils, the binds, offline -- so an edit
--- that weakened it would pass a test that reads what it does not
--- declare, and keep and share the pass. What it requires (cosmic.time,
--- cosmic.stream and the rest) applies no sandbox, and stays out.
-- TODO: move the translation of a plan's `sandbox` into spawn's
-- options into build.confine, which the harness holds already, and
-- drop cosmic.child from here and from build/harness_epoch.tl's
-- `library`, once cosmic.child's `start` takes spawn's sandbox as it is
-- (the TODO above its `raw.spawn` call, which would offer the rest of
-- it): today only cosmic.child reaches spawn for the runner.
local harness_alone <const>: {string} = { "cosmic.child" }

--- The code that makes a key and looks a verdict up under one:
--- build.test itself, whose closure is the build's, and the closure of
--- the key's computation (`build.declared_key`) and of the shared
--- verdicts' (`build.shared_verdicts`), as the `imports` table has it.
--- What build.test decides of a worker's holds is part of it: which
--- names of the tree and its declarations a `require` or a lookup in the
--- store refuses (`tree_names`, `declared_names`).
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
-- once it is a module of its own (plan 2.7b, after plan 4.2 removes the
-- observed path): today build.test is held whole and unwalked, so an
-- edit to its census or report output acknowledges the harness, and
-- what it requires beyond `key_code` (cosmic.time, cosmic.cli and the
-- like) is outside build/harness_epoch.tl's `library` rule.
local key_roots <const>: {string} = { "build.declared_key", "build.shared_verdicts" }
local key_own <const>: {string} = { "build.test" }

--- The module that holds the epoch and the acknowledged digests, which
--- the digests leave out: it would hold itself.
local epoch_module <const> = "build.harness_epoch"

--- The code that writes a closure store: build.closure_store's and the
--- schema it writes it by (`build.schema`).
---
--- The store's address holds the rows it carries by their digests
--- (`closure_store.basis`), but not which of them, nor which tables,
--- that code copies: a table added to what it copies would move no
--- address. The projection's writer (`build.writer`) is none of this
--- code. What it writes reaches a store only through rows and orderings
--- the basis digests: each module's columns, its source's stored bytes
--- among them, and its own docs, catalog and examples in their order,
--- while build.closure_store orders them across modules itself. So an
--- edit to the writer that writes the same rows moves no address, and
--- one that writes others moves only the addresses of the closures that
--- carry them.
---
--- The salt holds the code that writes a closure store with all it
--- requires (`store_code`), each module by its source and bytecode. It
--- salts data, the store's bytes, which the epoch does not stand for:
--- what build.closure_store writes passes through cosmic.sqlite,
--- cosmic.fs and cosmic.hash, and an edit to one of them (how a blob is
--- bound, a pragma set) can change a store's bytes while every row's
--- digest, and so the address, stays. An edit to build/closure_store.tl
--- or build/schema.tl, or to a module they require, runs every test
--- that does not declare `store` again.
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
    "SELECT i.path, i.requires FROM imports i WHERE NOT EXISTS " ..
    "(SELECT 1 FROM modules m WHERE m.path = i.path AND m.kind IN ('module', 'main') " ..
    "AND instr(m.bytecode, CAST(i.requires AS BLOB)) = 0)")
  if rows == nil then return nil, trouble end
  local out: {string:{string}} = {}
  for _, row in ipairs(rows) do
    local list = out[row[1]] or {}
    out[row[1]] = list
    list[#list + 1] = row[2]
  end
  return out, ""
end

--- The names `key_roots` and `key_own` hold (`closure_of`), over the
--- requires each module makes by value (`test.value_imports`).
local function key_code(by_value: {string:{string}}): {string}
  return closure_of(key_roots, key_own, by_value)
end

--- The names `store_writer` holds, with what they require (`closure_of`).
local function store_code(imports: {string:{string}}): {string}
  return closure_of(store_writer, {}, imports)
end

--- The digests of the test harness's modules and that of the code that
--- writes a closure store (`Harness`), over the modules `db` holds, by
--- their `modules` and `imports` rows. `db` is the running binary's
--- database (`binary_harness`, which fills in `carried`), or the
--- projection, o/cosmic.db, which build/harness_epoch_test.tl reads.
---
--- Each module of the harness is held by its name, its source's hash and
--- its bytecode's, a digest to each (`modules`). That covers what a
--- worker loads, `harness_own`, `harness_alone` and `key_code`, but not
--- build.harness_epoch, which records the digests. Each digest is the
--- same wherever the tree is, and a compiler that makes other bytecode
--- of the same source moves it as an edit does. The salt holds each
--- module of the store's writer the same way (`store_code`), as the
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
--- (`Harness`), searched alone so no attached database stands in for
--- it. What a worker runs is what every worker loads (`worker.loads`),
--- which `worker.judge` holds each worker to, and `harness_own`; no
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
function test.harness_word(epoch: string, timeout_ms: integer): string
  return string.format("e%s-t%d", epoch, timeout_ms)
end

--- Everything a finished job's verdict is recorded into.
local record Recording
  records: Sqlite.Handle
  root: string
  hashes: {string:string}
  -- The binary's runtime identity and the digest of its data tables.
  runtime: string
  run_at_ns: integer
  run: integer
  key_parts: {string:string}
  failures: {string}
  errors: {string}
  --- Each skipped test's id and why (`Test.skip`), as "<id>: <reason>".
  skips: {string}
  --- Whether the run is held to sandboxing (`confine.held_to_sandbox`),
  --- which fails a skipped test.
  held: boolean
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
  --- out of every record of the run (see `write_coverage`).
  unowned: Coverage.Hits
  tally: test.Tally
  --- The verdicts every checkout shares, or nil, and what the run owes
  --- them when it ends.
  shared: shared_verdicts.Cache
  owed: shared_verdicts.Owed
  --- Each key a verdict of this run stands or is assumed under, its
  --- shared key, for `owed.used`.
  shared_keys: {string:string}
  --- What names this checkout among the rows it shares (`checkout_id`).
  origin: string
  --- For `--audit`: each test's findings (`test.audited`), by module
  --- path and test name; each selected module's effective inputs, by
  --- path; and the program running the tests, which `tool` declares.
  --- Nil on any other run.
  audit: {string:{string:{test_inputs.Finding}}}
  effective: {string:test_inputs.Effective}
  tool: {string}
  --- Whether each worker runs sandboxed (`build.test_sandbox`): the
  --- switch does not turn it off and the kernel can. `effective` then
  --- holds every selected module's inputs, and `views` the environment
  --- its workers are given, by module path.
  sandbox: boolean
  --- Whether each verdict is keyed by its test's declared inputs
  --- (`build.declared_key`): every sandboxed run's, and an unsandboxed
  --- one's given COSMIC_TEST_KEY=declared (`key_mode`), which gives a
  --- worker the environment a sandbox would and holds it to nothing
  --- else. Each field below said "Sandboxed" is one of a keyed run.
  keyed: boolean
  --- What reruns one test as this run ran it: the switches as the run
  --- was given them (`test_sandbox.mode`, `key_mode`), or "" when unset.
  rerun_prefix: string
  views: {string:{string:string}}
  --- Sandboxed, what keys each verdict (`build.declared_key`): the
  --- digests of the tree's files the run has taken, and the compiler's
  --- identity (`build.work`'s `Identities`) as the running tool's `meta`
  --- names it, `compiler` and then `compiled_by`, which a key holds
  --- only where its closure reads it (`declared_key.reads_compiler`).
  digests: declared_key.Digests
  compiler: string
  --- Sandboxed, the host's identity every key holds
  --- (`declared_key.host_identity`), what it has installed, which only
  --- the key of a module given the system's paths holds
  --- (`declared_key.system_identity`), and why each module whose tests
  --- have no key has none, but for the network, by module path.
  host: string
  system: string
  --- The harness's epoch (build/harness_epoch.tl), which every key
  --- holds in place of the harness's code, and the timeout each worker
  --- runs under (`Limits.timeout_ms`), which every key holds too: a
  --- pass reached under a longer one need not come under a shorter.
  epoch: string
  timeout_ms: integer
  --- Sandboxed, the program a test that runs this program runs
  --- (`declared_key.program_identity`).
  program: string
  --- The digest of the code that writes a closure store (`Harness`),
  --- and the set of the modules of the tree the binary carries, which
  --- a worker's loads are held to (`worker.judge`).
  store_salt: string
  carried: {string:boolean}
  --- Sandboxed, where an artifact runs the tests (o/bin/cosmic, or a
  --- portable cosmic), what runs its core
  --- (`declared_key.launcher_identity`), which every key holds; nil
  --- where a host program does.
  launcher: string
  unkeyed: {string:string}
  --- Whether each module's workers can be kept from running this
  --- program (`can_forbid`), by module path.
  forbiddable: {string:boolean}
  --- Where the host caches each module declares are (`build.caches`),
  --- by module path, as `caches_of` resolves them.
  caches: {string:{string}}
  --- Each selected module's import closure, by path: the names of its
  --- modules, which its worker holds its `require`s to
  --- (`test_inputs.modules`, `build.test_worker`).
  closures: {string:{string}}
  --- The same, each a set of names, made as a verdict needs one
  --- (`closure_set`).
  closure_sets: {string:{string:boolean}}
  --- Every module of the tree, by path, sorted: what a worker refuses a
  --- `require` of outside its closure (`build.test_worker`).
  tree_names: {string}
  --- Every name only a declaration of the tree answers for, sorted:
  --- what a worker's store holds a lookup of outside its closure beside
  --- `tree_names` (`build.test_worker`).
  declared_names: {string}
  --- Sandboxed, the address of the store of each module's import
  --- closure its workers are given at o/cosmic.db
  --- (`build.closure_store`'s `write`), by path, for every test and
  --- example module of the tree that does not declare `store`; the
  --- projection that store is derived from, its basis, and each store
  --- built or found this run, by address (`given_store`).
  stores: {string:string}
  projection: string
  basis: closure_store.Basis
  built: {string:string}
  --- How many of them this run wrote, their bytes, and the time taken.
  written: integer
  written_bytes: integer
  writing_ns: integer
end

--- The environment the workers of `m`'s tests are given, which a
--- variable they read is keyed by: nil for every worker's own, where
--- they run unsandboxed and unkeyed. Keyed, it is what a sandbox gives
--- one (`test_sandbox.environment`), TMPDIR its scratch directory; one
--- keyed but unsandboxed has the host's cores cache in place of the
--- sandbox's own (`test_sandbox.unenforced_view`), as it is given.
local function view_of(rec: Recording, m: importer.Module): {string:string} | nil
  if not rec.keyed then return nil end
  local view = rec.views[m.path]
  if view == nil then
    local effective = rec.effective[m.path]
    view = rec.sandbox and test_sandbox.environment(worker_view(), effective)
      or test_sandbox.unenforced_view(worker_view(), effective)
    rec.views[m.path] = view
  end
  return view
end

--- Where the tree is, for a `host` path that must not be it, beneath
--- it or above it (`test_inputs.resolved`): its path and where that
--- resolves.
local function tree_roots(rec: Recording): {string}
  return { rec.root, observations.resolution(rec.root) }
end

--- Why `m`'s `host` paths cannot all be given to its workers, from
--- where a variable one names says, as a worker's environment has it
--- (`test_inputs.resolved`): "" where they can. Every test of such a
--- module fails before its worker starts, sandboxed or not.
local function unresolved(rec: Recording, m: importer.Module): string
  local effective = rec.effective ~= nil and rec.effective[m.path] or nil
  if effective ~= nil then return effective.unresolved or "" end
  for _, declared in ipairs(m.inputs ~= nil and m.inputs.host or {}) do
    local path, trouble = test_inputs.resolved(declared, worker_view(), tree_roots(rec))
    if path == nil then return trouble end
  end
  return ""
end

--- Where the host caches `m` declares are (`build.caches`), as every
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
    tostring(Time.monotonic_ns()) .. "\0" .. tostring({}))
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
  local aside = ""
  if shared_verdicts.corrupt(trouble) then
    local moved, _ = shared_verdicts.set_aside(path, Time.now_ns())
    if moved ~= nil then aside = "; moved aside to " .. moved end
  end
  log:complain("test: shared verdicts: " .. path .. ": " .. trouble ..
    "; running without them" .. aside)
end

--- What a test was compiled from and ran under: what a verdict no key
--- could hold is assumed on, when it is.
local function identity_of(rec: Recording, m: importer.Module): string
  -- The tool itself too, whole: a test that starts it unconfined
  -- exercises all of it, not only what the test's module loads.
  return m.key .. "\0" .. rec.runtime .. "\0" .. (Store.meta("boot_hash") or "")
end

--- Whether a sandboxed worker of `m`'s tests can be kept from running
--- this program where its module does not declare `tool`
--- (`confine.forbid_running`): not where it may write a directory
--- the program is in (`test_sandbox.forbiddable`), since a core another
--- cosmic extracts there after the worker holds itself could not be
--- run. The cores a portable cosmic extracts, where the program's own
--- core is, are none of them: a worker that declares the `bootstrap`
--- cache has cores of its own (`test_sandbox.cache_writes`). Such a
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

--- How a sandboxed worker of `m`'s tests stands to running this
--- program: "declared" where its module declares `tool`, "forbidden"
--- where it is kept from running it (`can_forbid`), and "allowed" where
--- it is not -- its module declares `nests`, whose worker no Landlock
--- ruleset holds, or it cannot be -- which its key holds as if its
--- module declared `tool` (`Spec.runs_tool`). Its key and its command
--- line (`hold_of`) both take it from here.
local enum ToolUse
  "declared"
  "forbidden"
  "allowed"
end

local function tool_use(rec: Recording, m: importer.Module): ToolUse
  local effective = rec.effective[m.path]
  if effective.tool then return "declared" end
  if effective.nests then return "allowed" end
  return can_forbid(rec, m) and "forbidden" or "allowed"
end

-- TODO: have `--audit` name a `nests` its tests never used -- no start
-- in a root of its own among what they did -- once the capture notes such
-- a start that succeeded, as it notes one refused (`confine.nests_note`):
-- an unneeded `nests` is sound, but leaves the worker unheld and keys it
-- as running the program, so its module runs again on every change to a
-- module the program carries.
--- How a worker of `m`'s tests is held by a Landlock ruleset
--- (`worker.Hold`): not at all unsandboxed, nor where its module declares
--- `nests`, which lets its tests confine a process in a root of its own;
--- to running anything but this program where it may not run it
--- (`tool_use`); and otherwise to running anything, which holds it to
--- making no root of its own, since the kernel refuses every mount under
--- a ruleset.
local function hold_of(rec: Recording, m: importer.Module): worker.Hold
  if not rec.sandbox or rec.effective[m.path].nests then return "none" end
  return tool_use(rec, m) == "forbidden" and "forbid" or "mounts"
end

--- Whether a worker of `m`'s tests can read the compiler's identity,
--- which it reads from the running tool (`declared_key.reads_compiler`):
--- not one given the whole projection, which carries its own and is
--- keyed by its contents.
local function reads_compiler(rec: Recording, m: importer.Module): boolean
  if rec.stores[m.path] == nil then return false end
  return declared_key.reads_compiler(rec.closures[m.path] or {})
end

--- A sandboxed test's key, over its declared inputs as they are now
--- (`build.declared_key`): nil for one that reads a link out of the
--- tree, which no key holds, said once in `rec.unkeyed`.
local function declared_of(rec: Recording, m: importer.Module, id: string): string | nil
  local effective = rec.effective[m.path]
  local key, why = declared_key.compute(rec.digests, {
    id = id, group = m.path, module_key = m.graph_key, runtime = rec.runtime,
    compiler = reads_compiler(rec, m) and rec.compiler or "", host = rec.host,
    system = rec.system,
    epoch = rec.epoch, timeout_ms = rec.timeout_ms, program = rec.program,
    launcher = rec.launcher,
    declaration = test_inputs.canonical(m.inputs), effective = effective,
    environment = view_of(rec, m), runs_tool = tool_use(rec, m) == "allowed",
    closure_store = rec.stores[m.path],
    -- Unsandboxed, its worker sees the tree where it is (`launch`).
    tree = not rec.sandbox and rec.root or nil,
  })
  if key == nil then rec.unkeyed[m.path] = why end
  return key
end

--- What a test read the last time it ran, for its `runs` row where a
--- sandboxed verdict stands without a run: nothing, where there is none.
local function last_reads(previous: {string:test.Previous}, id: string): {observations.Observation}
  local was = previous[id]
  return was ~= nil and was.reads or {}
end

--- A verdict from a stored one that still stands: what the test read
--- last time still hashes the same, and so does everything it was
--- compiled from. Nil when there is none.
local function standing(rec: Recording, previous: {string:test.Previous},
                        verdicts: {string:test.Verdict}, m: importer.Module,
                        id: string): test.Verdict, {observations.Observation}, string
  local was = previous[id]
  if was == nil or was.reads == nil then return nil, nil, "" end
  local verdict_key = test.verdict_key(rec.root, rec.hashes, id, m.key, rec.runtime,
    was.reads, rec.key_parts, nil, view_of(rec, m))
  local key, stable = verdict_key.key, verdict_key.stable
  local stood = stable and verdicts[key] or nil
  if stood == nil or not stood.passed then return nil, nil, "" end
  rec.shared_keys[key] = verdict_key.shared
  return stood, was.reads, key
end

--- Records one test answered from its standing verdict.
local function stand(rec: Recording, credited: test.Credited, m: importer.Module,
                     name: string, id: string, stood: test.Verdict,
                     reads: {observations.Observation}, key: string)
  rec.tally.cached = rec.tally.cached + 1
  local owed = credited[stood.run_at_ns]
  if owed == nil then
    owed = {}
    credited[stood.run_at_ns] = owed
  end
  owed[#owed + 1] = id
  local kept, keep_trouble = record_run(rec.records, m.path, name, true, "",
    Time.now_ns(), reads, run_key(key, rec.shared_keys[key]), stood.run_at_ns,
    stood.elapsed_ns)
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

--- A verdict a test is assumed on, and the key it was reached under.
local record Assumed
  verdict: test.Verdict
  key: string
  kept: {observations.Observation}
end

--- The verdict to assume for a test no key could hold: its last run's,
--- when that passed and the test was compiled from and ran under the
--- same as now; nil and why when there is none.
local function assumable(rec: Recording, previous: {string:test.Previous},
                         verdicts: {string:test.Verdict}, m: importer.Module,
                         id: string): Assumed | nil, string
  local was = previous[id]
  if was == nil or was.identity == nil then return nil, "no run no key could hold" end
  if not was.passed then return nil, "did not pass" end
  if was.identity ~= identity_of(rec, m) then return nil, "changed since" end
  -- What of its reads a key can hold -- files of the tree, the
  -- environment -- must answer as they did.
  local now = test.verdict_key(rec.root, rec.hashes, id, m.key, rec.runtime, was.kept,
    rec.key_parts, nil, view_of(rec, m))
  if not now.stable or now.key ~= was.key then return nil, "what it read changed" end
  local verdict = verdicts[was.key]
  if verdict == nil or not verdict.passed then return nil, "did not pass" end
  rec.shared_keys[was.key] = now.shared
  return { verdict = verdict, key = was.key, kept = was.kept }, ""
end

--- Records one test answered from an assumed verdict, keeping that
--- verdict, its coverage and the mark that lets it be assumed again.
local function assume(rec: Recording, credited: test.Credited, m: importer.Module,
                      name: string, id: string, verdict: test.Verdict, key: string,
                      reads: {observations.Observation})
  rec.tally.assumed = rec.tally.assumed + 1
  local owed = credited[verdict.run_at_ns]
  if owed == nil then
    owed = {}
    credited[verdict.run_at_ns] = owed
  end
  owed[#owed + 1] = id
  local kept, keep_trouble = record_run(rec.records, m.path, name, true, "",
    Time.now_ns(), reads, run_key(key, rec.shared_keys[key]), verdict.run_at_ns,
    verdict.elapsed_ns, false, identity_of(rec, m))
  if not kept then
    rec.errors[#rec.errors + 1] = id .. ": record: " .. keep_trouble
  end
  kept, keep_trouble = record_verdict(rec.records, key, true, verdict.run_at_ns, rec.run,
    verdict.elapsed_ns)
  if not kept then
    rec.errors[#rec.errors + 1] = id .. ": verdict: " .. keep_trouble
  end
  local shared_key = rec.shared_keys[key]
  if shared_key ~= nil then rec.owed.used[#rec.owed.used + 1] = shared_key end
end

--- Records one sandboxed test answered from the verdict another
--- checkout reached under its declared `key` (`found`): as this run's
--- own, with the lines that run hit, so a later run of this checkout
--- stands on it without the shared cache. `reads` is what its last run
--- here read, for its `runs` row.
local function share(rec: Recording, m: importer.Module, name: string, id: string,
                     key: string, found: shared_verdicts.Found,
                     reads: {observations.Observation})
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
    Time.now_ns(), reads, run_key(key, key), rec.run_at_ns, elapsed)
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

--- Records one finished job: the verdict its worker reported, or a
--- failure that says why there is no report to go by
--- (`build.test_worker`'s `judge`). Keyed, a key holds what a worker
--- runs by `worker.loads` and the test's closure, so a worker that ran a
--- module of the tree the tool carries beyond both fails its test.
local function finish(rec: Recording, job: Job, result: Child.Result,
                      trouble: string, limits: test.Limits, refused?: boolean)
  rec.tally.ran = rec.tally.ran + 1
  local id = job.id
  local wall_ns = Time.monotonic_ns() - job.started_ns
  local judged = worker.judge({
    result = result, trouble = trouble, timeout_ms = limits.timeout_ms,
    sandboxed = rec.sandbox, refused = refused == true,
    carried = rec.keyed and rec.carried or nil,
    closure = rec.keyed and closure_set(rec, job.m) or nil,
  })
  local reported, passed, message = judged.report, judged.passed, judged.message
  -- A pass the test said it could not check (`Test.skip`) is kept as no
  -- verdict, pass or fail, so it runs again on the next run -- and on a
  -- host that can check it, whose key differs, as its own; and a run
  -- held to sandboxing, which exists to prove the host checked it all,
  -- fails it.
  local skipped = judged.passed and judged.skipped or ""
  if skipped ~= "" and rec.held then
    passed, skipped = false, ""
    message = "skipped (" .. judged.skipped .. "), but the run is held to sandboxing " ..
      "(COSMIC_TEST_SANDBOX=1, COSMIC_SANDBOX=must or COSMIC_CI_REQUIRE_SANDBOX=1), " ..
      "which fails a test this host could not check"
  elseif skipped ~= "" then
    rec.tally.skipped = rec.tally.skipped + 1
    rec.skips[#rec.skips + 1] = id .. ": " .. skipped
    message = "skipped: " .. skipped
  end
  -- What the records keep: a skip is no pass.
  local kept_pass = passed and skipped == ""
  local reads: {observations.Observation} = {}
  -- What the audit, and a sandboxed test's failure, judge: what a
  -- sandboxed worker was refused (build.refusals), which is what it
  -- read that its module does not declare, or what an unsandboxed one
  -- read.
  local judged_reads: {observations.Observation} = {}
  local elapsed = wall_ns
  local cacheable = false
  if reported ~= nil then
    if job.plan ~= nil and job.scratch ~= nil then
      -- Where the host has what the sandboxed worker read at /tree and
      -- /tmp, so its key and its audit are those of an unsandboxed run.
      reported.load_reads = test_sandbox.to_host(reported.load_reads, rec.root, job.scratch,
        job.plan.kept, job.plan.made)
      reported.test_reads = test_sandbox.to_host(reported.test_reads, rec.root, job.scratch,
        job.plan.kept, job.plan.made)
      judged_reads = test_sandbox.to_host(reported.refusals, rec.root, job.scratch,
        job.plan.kept, job.plan.made)
    end
    reads = observations.join(reported.load_reads, reported.test_reads)
    -- TODO: drop the unsandboxed audit, of what the observation log saw
    -- a worker read, once that log goes (plan 4.2's PR 4): an audit then
    -- needs a worker the kernel can sandbox, and says so where none can
    -- be, as COSMIC_TEST_SANDBOX=1 does.
    if job.plan == nil then judged_reads = reads end
    -- TODO: run a sandboxed test that failed again, given what it was
    -- refused beyond its declarations, until it passes or is refused
    -- nothing more, so that one audit names all it reads undeclared, not
    -- what it met before its first failure, once `test_sandbox.plan` can
    -- give a worker paths no declaration names.
    if rec.audit ~= nil then
      local by_test = rec.audit[job.m.path] or {}
      rec.audit[job.m.path] = by_test
      by_test[job.name] = test.audited(rec.root, job.scratch, rec.effective[job.m.path],
        judged_reads, rec.tool, job.plan ~= nil)
    end
    elapsed = reported.elapsed_ns
    cacheable = reported.loaded and not rec.keyed and
      test.keyable(rec.root, job.scratch, reads, caches_of(rec, job.m))
    local hit: Coverage.Hits = {}
    merge_hits(hit, reported.load_hits)
    merge_hits(hit, reported.test_hits)
    for path in pairs(rec.unowned) do
      hit[path] = nil
    end
    merge_hits(rec.hits, hit)
    rec.by_test[id] = encode_hits(hit)
  end
  if rec.keyed then
    -- Keyed by what it was given: its declared inputs, as they were
    -- before it started -- and still are, or the verdict describes no
    -- one state of them, and is not kept.
    local key = job.declared
    -- One with no key -- it reaches a network beyond loopback -- is
    -- kept under none, and runs every time. What a process it starts
    -- reads, its sandbox holds to what its key holds
    -- (`test_sandbox.Plan`'s `held`).
    if key == nil then rec.tally.every = rec.tally.every + 1 end
    local held = key ~= nil and declared_of(rec, job.m, id) == key
    local saved, save_trouble = record_run(rec.records, job.m.path, job.name, kept_pass,
      message, Time.now_ns(), reads, run_key(key or "", key), rec.run_at_ns, elapsed)
    if not saved then
      rec.errors[#rec.errors + 1] = id .. ": record: " .. save_trouble
    end
    if held and skipped == "" then
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
  else
    local verdict_reached = test.verdict_key(rec.root, rec.hashes, id, job.m.key,
      rec.runtime, reads, rec.key_parts, job.started_ns, view_of(rec, job.m))
    local reached, stable = verdict_reached.key, verdict_reached.stable
    local late = verdict_reached.late
    local saved, save_trouble = record_run(rec.records, job.m.path, job.name, kept_pass,
      message, Time.now_ns(), reads, run_key(reached, verdict_reached.shared), rec.run_at_ns,
      elapsed,
      (stable or late) and cacheable, identity_of(rec, job.m))
    if not saved then
      rec.errors[#rec.errors + 1] = id .. ": record: " .. save_trouble
    end
    if not late and skipped == "" then
      saved, save_trouble = record_verdict(rec.records, reached, passed, rec.run_at_ns, rec.run,
        elapsed)
      if not saved then
        rec.errors[#rec.errors + 1] = id .. ": verdict: " .. save_trouble
      end
    end
  end
  job.passed = passed
  if not passed and reported ~= nil and job.plan ~= nil then
    -- Sandboxed, a read of what the module does not declare found
    -- nothing: name each, and the declaration that would give it.
    rec.tool = rec.tool or confine.itself()
    local findings = test.audited(rec.root, job.scratch, rec.effective[job.m.path],
      judged_reads, rec.tool, true)
    local lines = test_inputs.report(job.m, { [job.name] = findings })
    if #lines > 0 then
      message = message .. "\n  sandboxed, it read what its module does not declare:"
      for i = 2, #lines do message = message .. "\n  " .. lines[i] end
    end
  end
  if not passed then
    if job.scratch ~= nil then
      message = message .. "\n  its directory is kept: " .. job.scratch .. "/real"
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
--- for the process it re-enters (`build.reboot`), which a run started
--- after a rebuild holds and one started fresh does not, and the
--- directory the invoking shell was in before its last `cd`, and the
--- command it last ran (`_`, which a shell sets to the program it
--- starts: /usr/bin/timeout for `timeout 30 cosmic test`). Kept, each
--- would enter the key of every test that reads the whole environment,
--- and such a test would run again after a rebuild, a `cd`, or a run
--- started another way. So too the shell's depth (`SHLVL`): a module
--- that declares `env = {"*"}` would be keyed by it, and a run from a
--- script, rather than a terminal, would run its tests again.
local launch_only: {string:boolean} = { COSMIC_REBOOTED = true, OLDPWD = true, SHLVL = true, _ = true }

--- The environment a worker starts with: this process's, less
---
--- - the private startup hooks (`COSMIC_PORTABLE_STARTUP_TEST_*`), which
---   pause one startup of a fixture runtime for a handshake and belong to
---   this process's own launch, not to every worker it starts;
--- - what `launch_only` names; and
--- - COSMIC_TEST_NO_SHARED and COSMIC_TEST_KEY (`key_switch`);
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
  -- Nor does it take this run's choice not to stand on them, nor how
  -- this run keys its verdicts: a test that runs `cosmic test` says
  -- for itself what that run does.
  out.COSMIC_TEST_NO_SHARED = nil
  out[key_switch] = nil
  return out
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
--- Removing the scratch directory with `Fs.remove_tree` removes the
--- link without following it, and the real directory beside it.
-- TODO: keep the link, which a sandboxed worker sees in `test_sandbox.scratch` as an
-- unsandboxed one sees it under the host's temporary directory: it
-- stands in for macOS's /var on every host, and does not depend on
-- where the checkout is. Drop it only once a case of its own on the
-- macOS leg catches a path resolved on one side of a comparison and not
-- the other, which the link catches on every leg today.
function test.scratch(): string | nil, string
  -- Padded so the scratch directory's path is as long on this host as
  -- a sandbox's is, and as macOS's is (`test_sandbox.scratch_length`),
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
--- of the run, naming the directory; `Fs.remove_tree` stops at the
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
--- import closures, each named by its address (`build.closure_store`'s
--- `address`).
local function stores_directory(root: string): string
  return root .. "/o/stores"
end

--- The address of the closure store of each test and example module of
--- `modules` that does not declare `store`, by path, over the
--- projection `rec.projection` (`closure_store.basis`): every one the tree
--- has, selected or not, so a run that selects some leaves the others'
--- stores, and `sweep_stores` takes out only what no module names.
local function address_stores(rec: Recording, modules: {importer.Module},
                              by_path: {string:importer.Module},
                              declarations: {string:string}): boolean, string
  local basis, trouble = closure_store.basis(rec.projection)
  if basis == nil then return false, trouble end
  rec.basis, rec.stores, rec.built = basis, {}, {}
  rec.written, rec.written_bytes, rec.writing_ns = 0, 0, 0
  for _, m in ipairs(modules) do
    local declared = m.inputs
    if (m.kind == "test" or m.kind == "example") and
        not (declared ~= nil and declared.store) then
      local names = rec.closures[m.path] or test_inputs.modules(m, by_path, declarations)
      rec.closures[m.path] = names
      rec.stores[m.path] = closure_store.address(basis, names, rec.store_salt)
    end
  end
  return true, ""
end

--- Takes out of the stores directory every entry no module of this run
--- names (`address_stores`): a closure edited since, or a module gone,
--- leaves a store nothing will ask for again, and one cut short (a
--- `.building` file) is written again from the start. A failure to
--- take one out costs only room, and is said once.
local function sweep_stores(rec: Recording)
  local directory = stores_directory(rec.root)
  local named: {string:boolean} = {}
  for _, address in pairs(rec.stores) do named[address .. ".db"] = true end
  local listed, _ = Fs.list(directory)
  for _, entry in ipairs(listed or {}) do
    if not named[entry] then
      local gone, trouble = Fs.remove(directory .. "/" .. entry)
      if not gone then
        log:complain("test: " .. directory .. "/" .. entry .. ": " .. trouble)
        return
      end
    end
  end
end

--- The path of the closure store a worker of `m`'s tests is given, made
--- from the projection where it is not there yet -- written aside and
--- moved into place, so a store there is whole -- or nil where `m`
--- declares `store` and is given the whole projection; nil and why
--- where it could not be made.
local function given_store(rec: Recording, m: importer.Module): string | nil, string
  local address = rec.stores ~= nil and rec.stores[m.path] or nil
  if address == nil then return nil, "" end
  local path = rec.built[address]
  if path ~= nil then return path, "" end
  local directory = stores_directory(rec.root)
  path = directory .. "/" .. address .. ".db"
  local there, _ = sys.stat(path)
  if there == nil then
    local made, trouble = Fs.mkdirs(directory)
    if not made then return nil, directory .. ": " .. trouble end
    local started = Time.monotonic_ns()
    local written, write_trouble = closure_store.write(rec.projection, path,
      rec.closures[m.path], rec.basis, address)
    if not written then return nil, "the store of its closure: " .. write_trouble end
    rec.writing_ns = rec.writing_ns + (Time.monotonic_ns() - started)
    local wrote, _ = sys.stat(path)
    rec.written = rec.written + 1
    rec.written_bytes = rec.written_bytes + (wrote ~= nil and wrote.size or 0)
  end
  rec.built[address] = path
  return path, ""
end

--- Starts one job's worker. False when it could not start, which is
--- recorded as that test's failure.
local function launch(rec: Recording, job: Job, start: Proc.Relaunch,
                      limits: test.Limits): boolean
  -- Set before anything can fail, since `finish` reckons the time from it.
  job.started_ns = Time.monotonic_ns()
  local scratch, tmp_trouble = test.scratch()
  if scratch == nil then
    finish(rec, job, nil, "could not make a temporary directory: " .. tmp_trouble, limits)
    return false
  end
  job.scratch = scratch
  local tmp = scratch .. "/tmp"
  job.tmp = tmp
  -- Sandboxed, the worker has the tree at /tree, where it runs, and
  -- its scratch directory at `test_sandbox.scratch`.
  local env: {string:string} = worker_view()
  local root, inside, cwd: string, string, string = rec.root, scratch, nil
  local sandbox: Child.Sandbox = nil
  local declares_trouble = unresolved(rec, job.m)
  if declares_trouble ~= "" then
    finish(rec, job, nil, declares_trouble, limits, true)
    return false
  end
  -- What a process the worker starts is keyed by, where its sandbox
  -- holds one: "" for none.
  local held = ""
  -- The store of its closure an unsandboxed worker attaches in place
  -- of the projection (`worker.Invocation`'s `store`): nil for none.
  local attached: string = nil
  if rec.sandbox then
    local store, store_trouble = given_store(rec, job.m)
    if store == nil and store_trouble ~= "" then
      finish(rec, job, nil, store_trouble, limits)
      return false
    end
    local plan = test_sandbox.plan(rec.root, scratch, rec.effective[job.m.path], worker_view(),
      store)
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
    env, sandbox = plan.env, plan.sandbox
    root, inside, cwd = test_sandbox.tree, test_sandbox.scratch, test_sandbox.tree
    held = table.concat(plan.held, "\n")
  elseif rec.keyed then
    -- Keyed but unsandboxed (COSMIC_TEST_KEY=declared), the worker is
    -- given the environment its key holds (the pinned variables, its
    -- declared ones and the host's cores cache: `view_of`) with TMPDIR
    -- its scratch directory, as a sandbox gives it at
    -- `test_sandbox.scratch`. The key names that, not this path, which
    -- is new every run. Nothing holds it to the rest of what it declares.
    --
    -- It sees the tree where it is, not at /tree, so its key holds that
    -- path (`declared_of`, `declared_key.Spec`'s `tree`): a verdict
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
    -- o/cosmic.db (`given_store`), held as a sandboxed worker's is
    -- (build.test_worker's `hold_store`).
    -- TODO: hand that store on to what the test starts, once a cosmic
    -- run can be told which store to read in place of its tree's
    -- o/cosmic.db (a variable build.tree_root reads): today a process
    -- the test starts, which a sandbox would give the closure store at
    -- o/cosmic.db, reads the whole projection there, which its key holds
    -- only by the closure store's address; a Linux leg's sandbox
    -- enforces what macOS trusts.
    local store, store_trouble = given_store(rec, job.m)
    if store == nil and store_trouble ~= "" then
      finish(rec, job, nil, store_trouble, limits)
      return false
    end
    attached = store
    env = test_sandbox.unenforced_environment(worker_view(), rec.effective[job.m.path], scratch)
  end
  job.started_ns = Time.monotonic_ns()
  job.deadline_ns = job.started_ns + limits.timeout_ms * 1000 * 1000
  -- Sandboxed, a worker whose module does not declare `tool` may not
  -- run this program (`confine.forbid_running`): what it would run
  -- is no input of its test's key; and one whose module does not
  -- declare `nests` may not make a root of its own (`hold_of`), which
  -- every process it starts learns from its environment
  -- (`confine.held_variable`). Only a module whose key holds the whole
  -- projection has no hold on the store (`build.test_worker`): one
  -- that declares `tool` is keyed by the program's modules, not by
  -- the rest of the tree's.
  local declared = job.m.inputs
  local hold = hold_of(rec, job.m)
  if rec.sandbox then
    local given: {string:string} = {}
    for name, value in pairs(env) do given[name] = value end
    given[confine.held_variable] = hold ~= "none" and job.m.path or nil
    env = given
  end
  local command = worker.invocation({
    start = start, env = env, root = root, cwd = cwd, module_path = job.m.path,
    name = job.name, scratch = inside, needs = test_inputs.canonical(declared), held = held,
    hold = hold,
    open = declared ~= nil and declared.store, store = attached,
    closure = rec.closures[job.m.path], tree = rec.tree_names, declared = rec.declared_names,
    sandbox = sandbox, program = job.plan ~= nil and job.plan.program or nil,
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
    local left_ms = (earliest - Time.monotonic_ns()) // (1000 * 1000)
    local done, trouble = Child.wait_any(handles, math.max(0, math.min(100, left_ms)))
    local still: {Job} = {}
    for _, job in ipairs(running) do
      if job.handle == done then
        -- Settled already, so this answers at once; the trouble
        -- `wait_any` gave beside the handle is the one reported.
        local result, _ = job.handle:wait()
        finish(rec, job, result, trouble, limits)
      elseif done == nil and trouble ~= "" then
        -- Supervision itself failed; end this worker and say why.
        local _, _ = job.handle:close()
        finish(rec, job, nil, trouble, limits)
      elseif Time.monotonic_ns() >= job.deadline_ns then
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
      -- it a subreaper (`Child.start`).
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
      -- group too -- in a group a descendant started, a `Child.start`
      -- in a process that ended first, or a session it began (setsid)
      -- -- by the worker's session, once a worker can be started in a
      -- session of its own (`Child.Options` taking one); setsid's
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
    timeout_ms = default_timeout_s * 1000,
    jobs = Proc.cpu_count(),
  }
  local function positive(value: string, what: string): integer | nil, string
    local number = math.tointeger(tonumber(value))
    if number == nil or number < 1 then
      return nil, what .. " must be a positive whole number, not " .. value
    end
    return number, ""
  end
  -- A deadline is kept in milliseconds, so seconds past this would wrap.
  local most_seconds = math.maxinteger // 1000
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
    limits.timeout_ms = seconds * 1000
  end
  if values["--timeout"] ~= nil then
    local seconds, trouble = seconds_of(values["--timeout"], "--timeout")
    if seconds == nil then return nil, trouble end
    limits.timeout_ms = seconds * 1000
  end
  if values["--jobs"] ~= nil then
    local jobs, trouble = positive(values["--jobs"], "--jobs")
    if jobs == nil then return nil, trouble end
    limits.jobs = jobs
  end
  return limits, ""
end

--- Whether this host can run a worker sandboxed
--- (`test_sandbox_probe.available`), and why not where it cannot.
local function sandbox_here(): boolean, string
  local start, start_trouble = worker.program()
  if start == nil then return false, "the test runner cannot find itself: " .. start_trouble end
  local directory, trouble = test_sandbox_probe.directory()
  if directory == nil then return false, "a directory to try it in: " .. trouble end
  local env: {string:string} = {}
  for name, value in pairs(worker_view()) do env[name] = value end
  for name, value in pairs(start.env) do env[name] = value end
  env.TMPDIR = test_sandbox.scratch
  local ok, why = test_sandbox_probe.available(start.argv, env, start.fds, directory)
  local _, _ = Fs.remove_tree(directory)
  if not ok then return false, why end
  return true, ""
end

--- Says each of `failures`, sorted, with the selector that reruns its
--- test and what the test printed; a failed test's message names the
--- directory it kept (`finish`).
--- Says each skipped test, with why (`Test.skip`), sorted.
local function say_skips(rec: Recording)
  table.sort(rec.skips)
  for _, skip in ipairs(rec.skips) do log:say("test: SKIP  " .. skip) end
end

local function say_failures(rec: Recording, failures: {string})
  table.sort(failures)
  for _, failure in ipairs(failures) do
    -- The line keeps its `<module> <name>: <message>` shape; the
    -- selector that reruns that one test follows it on a line of its own.
    log:say("test: FAIL  " .. failure)
    local id = rec.failed[failure]
    local rerun = id ~= nil and rec.reruns[id] or nil
    if rerun ~= nil then
      log:say("  rerun: " .. rec.rerun_prefix ..
        "cosmic test " .. test.shell_word(rerun))
    end
    local printed = id ~= nil and rec.outputs[id] or nil
    if printed ~= nil then
      if #printed > 4096 then
        printed = "..." .. printed:sub(-4096)
      end
      for printed_line in String.lines((printed:gsub("\n$", ""))) do
        log:say("  | " .. printed_line)
      end
    end
  end
end

--- Builds the tree in the working directory and runs every test it
--- discovered that its selectors choose (`test.selects`), printing a
--- verdict line and returning the exit code: 0
--- when every test passed.
--- @param argv the command line, which a stale tool re-enters after
---   rebuilding itself
local function run(argv: {integer:string}): integer
  -- Captured once, up front, and threaded through everything below as
  -- this run's own identifier: see build/work.tl for why a nanosecond
  -- timestamp, not an autoincrement id, identifies a run.
  local run_at_ns = Time.now_ns()

  local root, root_trouble = Fs.absolute(".")
  if root == nil then
    log:complain(root_trouble)
    return 1
  end
  local parsed, parse_trouble = Flags.parse(argv, 2, Cli.options.test)
  if parsed == nil then
    log:complain("test: " .. parse_trouble)
    return 2
  end
  local limits, limits_trouble = limits_of(parsed.values)
  if limits == nil then
    log:complain("test: " .. limits_trouble)
    return 2
  end
  local sandbox_mode, sandbox_trouble = test_sandbox.mode()
  if sandbox_mode == nil then
    log:complain("test: " .. sandbox_trouble)
    return 2
  end
  local key_choice, key_trouble = key_mode()
  if key_choice == nil then
    log:complain("test: " .. key_trouble)
    return 2
  end
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
  -- A test no key can hold is assumed to pass as it last did unless
  -- asked for: by --all, or by name -- a selector narrower than the
  -- whole tree that chooses it. COSMIC_SANDBOX=must asks for all of
  -- them: one assumed may have passed with a process that fell back to
  -- running unconfined, which the mode refuses
  -- (build.confine's `must_confine`).
  -- An audit runs every test it chooses, to observe what each reads.
  local audit = parsed.set["--audit"] == true
  local forced = audit or parsed.set["--all"] == true or Env.get("COSMIC_TEST_ALL") == "1"
  local everything = forced or Env.get("COSMIC_SANDBOX") == "must"
  -- A run that stands on nothing another checkout reached, though it
  -- still shares what it reaches: what answers for every test is this
  -- checkout's own evidence, or a run.
  local consult = not (audit or parsed.set["--no-shared"] == true or
    Env.get("COSMIC_TEST_NO_SHARED") == "1")
  local naming: {string} = {}
  for _, selector in ipairs(selectors) do
    if selector ~= "." then naming[#naming + 1] = selector end
  end
  local started = Time.monotonic_ns()
  local own_tree, own_trouble = tree.is_own(root)
  if own_tree == nil then
    log:complain(own_trouble)
    return 1
  end
  local handle, open_trouble = work.open(root)
  if handle == nil then
    log:complain(open_trouble)
    return 1
  end
  local staged, stage_trouble = work.stage(handle, own_tree)
  if staged == nil then
    local _, _ = work.close(handle)
    log:complain(stage_trouble)
    return 1
  end

  local built = teal.lazy()

  -- A stale tool refuses, or rebuilds itself or has zig boot the core
  -- and re-enters this command line (`reboot.guard`).
  if own_tree then
    local code = reboot.guard(handle, root, argv)
    if code ~= nil then
      return code
    end
  end

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
  if not own_tree and compiler_salt ~= nil and compiler_salt ~= "" then
    tool = hex_sha256(tool .. "\0" .. compiler_salt)
    compiled_by = tool
  end
  local identity = Store.meta("runtime")
  if identity == nil or identity == "" then
    local _, _ = work.close(handle)
    log:complain("the running binary names no runtime identity")
    return 1
  end
  -- Every verdict is keyed on the data tables the binary carries too
  -- (`schema.tables_digest`): `cosmic refresh` replaces its zones and
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
  local runtime = identity .. " tables " .. tables
  local harness, harness_trouble = binary_harness()
  if harness == nil then
    local _, _ = work.close(handle)
    log:complain("the running binary's test harness: " .. harness_trouble)
    return 1
  end
  local database = root .. "/o/cosmic.db"
  -- Each worker runs sandboxed where the kernel can sandbox one, unless
  -- the switch turns it off. A verdict reached so is kept apart from one
  -- reached without, by a runtime of its own, so neither stands for the
  -- other. An unsandboxed run's verdicts are this checkout's alone: no
  -- sandbox held what its tests read, so none is shared, nor stood on.
  -- The exception is a run keyed by its tests' declarations
  -- (`key_mode`), which trusts them where a sandboxed run elsewhere
  -- enforces them. Its verdicts are kept apart from both others' by a
  -- runtime of their own.
  local must = Env.get("COSMIC_SANDBOX") == "must"
  local declared = key_choice == "declared"
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
      "worker's sandbox: declare nests = true in its Test.needs, or start the run with " ..
      test_sandbox.switch .. "=0")
    return 1
  end
  if sandbox_mode ~= "off" then
    local why: string
    sandboxed, why = sandbox_here()
    if sandboxed then
      -- And whether it is held to confining what it starts
      -- (`confine.must_confine`), which a test's verdict turns on.
      runtime = runtime .. " sandboxed" .. (must and " must" or "")
      sandbox_summary = "; sandboxed"
      log:say("test: sandbox: each worker is held to its inputs, the tree at " ..
        test_sandbox.tree)
    elseif sandbox_mode == "on" then
      local _, _ = work.close(handle)
      log:complain("test: " .. test_sandbox.switch .. "=1, but no worker can be sandboxed " ..
        "here: " .. why)
      return 1
    elseif declared then
      log:say("test: no worker can be sandboxed here: " .. why .. "; " .. unenforced ..
        " (" .. key_switch .. "=declared)")
    else
      sandbox_summary = "; unsandboxed, as no worker can be sandboxed here, sharing no verdicts"
      log:say("test: no worker can be sandboxed here: " .. why .. "; " ..
        test_sandbox.switch .. "=0 runs them unsandboxed without asking")
    end
  elseif declared then
    log:say("test: declared: workers run unsandboxed (" .. test_sandbox.switch .. "=0); " ..
      unenforced)
  else
    sandbox_summary = "; unsandboxed (" .. test_sandbox.switch .. "=0), sharing no verdicts"
  end
  local keyed = sandboxed or declared
  if keyed and not sandboxed then
    -- The pinned COSMIC_TEST_SANDBOX and the " sandboxed" mark already
    -- tell these verdicts from a sandboxed run's; the tag says so in
    -- the key itself (build/declared_unenforced_test.tl).
    runtime = runtime .. " declared" .. (must and " must" or "")
    sandbox_summary = "; unsandboxed, keyed by declared inputs (" .. key_switch .. "=declared)"
  end
  -- What names what a keyed run says of its keys: the sandbox's, or,
  -- keyed with no sandbox, the declarations'.
  local keying = sandboxed and "test: sandbox: " or "test: declared: "

  local result, compile_trouble = importer.compile(handle, built, tool, false,
    shared_compiles.for_build())
  if result == nil then
    local _, _ = work.record(handle, clock.elapsed_ms(started), staged, 0, 0, "FAIL")
    local _, _ = work.close(handle)
    log:complain(compile_trouble)
    return 1
  end
  local written, write_trouble =
    writer.write_result(handle, database, result)
  local _, _ = work.record(handle, clock.elapsed_ms(started), staged, result.compiled,
    result.cached, written and "PASS" or "FAIL")
  if not written then
    local _, _ = work.close(handle)
    log:complain(write_trouble)
    return 1
  end
  local parses = result.parses
  log:say("build: " .. plural.count(#result.modules, "module") .. " (" .. result.compiled ..
    " compiled, " .. result.cached .. " cached" ..
    (result.shared > 0 and ", " .. result.shared .. " of them taken from another checkout" or "") ..
    ((parses.parsed > 0 or parses.shared > 0) and "; " ..
      plural.count(parses.parsed, "source") .. " parsed" ..
      (parses.shared > 0 and ", " .. parses.shared .. " taken from another checkout" or "") or "") ..
    "; " .. plural.count(staged.files, "file") .. " staged, " .. staged.read .. " read) in " ..
    clock.took(started))

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
    local _, _ = work.close(handle)
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

  -- Every verdict and every coverage row of this run lands together.
  local begun, begin_trouble = work.begin(handle)
  if not begun then
    local _, _ = work.close(handle)
    log:complain(begin_trouble)
    return 1
  end
  local records_path = root .. "/o/build.db"
  local records = handle.db
  local previous, previous_trouble = previous_runs(records)
  if previous == nil then
    local _, _ = work.rollback(handle)
    local _, _ = work.close(handle)
    log:complain(records_path .. ": " .. previous_trouble)
    return 1
  end
  local hashes, hashes_trouble = staged_hashes(records)
  if hashes == nil then
    local _, _ = work.rollback(handle)
    local _, _ = work.close(handle)
    log:complain(records_path .. ": " .. hashes_trouble)
    return 1
  end
  local verdicts, verdicts_trouble = known_verdicts(records)
  if verdicts == nil then
    local _, _ = work.rollback(handle)
    local _, _ = work.close(handle)
    log:complain(records_path .. ": " .. verdicts_trouble)
    return 1
  end
  local epoch, epoch_trouble = harness_epoch_of()
  if epoch == nil then
    local _, _ = work.rollback(handle)
    local _, _ = work.close(handle)
    log:complain(epoch_trouble)
    return 1
  end
  local credited: test.Credited = {}

  local tally: test.Tally = { ran = 0, cached = 0, assumed = 0, shared = 0, every = 0,
    skipped = 0 }
  local modules_run = #selected_modules
  local failures: {string} = {}
  local errors: {string} = {}
  -- Every hit line of the run, and each test's own, which is what lets
  -- a later run credit a standing verdict's lines to it by name.
  local hits: Coverage.Hits = {}
  local by_test: {string: string} = {}
  -- The core's C is cosmic's own: another project's run neither owns
  -- nor tests it, and counting it would make its lines most of that
  -- project's figure.
  local native_lines: Coverage.Hits = {}
  local unowned: Coverage.Hits = {}
  if own_tree then
    native_lines = Coverage.native_lines()
  else
    unowned = Coverage.native_lines()
  end
  local rec: Recording = {
    records = records, root = root, hashes = hashes, runtime = runtime,
    run_at_ns = run_at_ns, run = handle.run, key_parts = {},
    failures = failures, errors = errors, outputs = {}, reruns = {},
    failed = {}, skips = {}, held = confine.held_to_sandbox(),
    hits = hits, by_test = by_test, unowned = unowned, tally = tally,
    owed = { kept = {}, used = {}, failed = {} }, shared_keys = {},
    origin = checkout_id(records, root, run_at_ns),
    sandbox = sandboxed, keyed = keyed, views = {}, caches = {}, unkeyed = {},
    forbiddable = {},
    epoch = epoch, timeout_ms = limits.timeout_ms,
    store_salt = harness.store_salt, carried = harness.carried,
    closure_sets = {},
    rerun_prefix = (sandbox_mode == "on" and (test_sandbox.switch .. "=1 ") or
      sandbox_mode == "off" and (test_sandbox.switch .. "=0 ") or "") ..
      (keyed and not sandboxed and (key_switch .. "=declared ") or ""),
  }
  -- The verdicts every checkout of the tree shares: one that stands
  -- here, run where another checkout reached it, is not run again.
  -- Without them the run goes on, and says so unless it was asked not
  -- to use them. An unkeyed run neither reads nor writes them (see
  -- above).
  local cache_path, cache_trouble: string, string = nil, ""
  if keyed then cache_path, cache_trouble = shared_verdicts.location() end
  if cache_path ~= nil then
    rec.shared, cache_trouble = shared_verdicts.open(cache_path)
  end
  if rec.shared == nil and cache_trouble ~= "" then
    local aside = ""
    if cache_path ~= nil and shared_verdicts.corrupt(cache_trouble) then
      local moved, _ = shared_verdicts.set_aside(cache_path, Time.now_ns())
      if moved ~= nil then aside = "; moved aside to " .. moved end
    end
    log:complain("test: shared verdicts: " .. cache_trouble .. "; running without them" .. aside)
  end
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
  rec.closures, rec.tree_names, rec.declared_names = {}, {}, {}
  for path in pairs(by_path) do rec.tree_names[#rec.tree_names + 1] = path end
  table.sort(rec.tree_names)
  -- A module the binary carries that is no module of the tree -- in a
  -- project's tree, the standard library's -- is no key's either way
  -- (the TODO above build.test_worker's `refusal`): a worker may load
  -- one.
  for name in pairs(rec.carried) do
    if by_path[name] == nil then rec.carried[name] = nil end
  end
  for name in pairs(declarations) do
    if by_path[name] == nil then rec.declared_names[#rec.declared_names + 1] = name end
  end
  table.sort(rec.declared_names)
  for _, m in ipairs(selected_modules) do
    rec.closures[m.path] = test_inputs.modules(m, by_path, declarations)
  end
  if audit then
    rec.audit, rec.tool = {}, confine.itself()
    for i = 1, #rec.tool do rec.tool[#rec.tool + 1] = observations.resolution(rec.tool[i]) end
  end
  if audit or keyed then
    rec.effective = {}
    for _, m in ipairs(selected_modules) do
      local effective = test_inputs.effective(m, by_path, declarations)
      effective.cache_paths = caches_of(rec, m)
      test_inputs.resolve(effective, worker_view(), tree_roots(rec))
      rec.effective[m.path] = effective
    end
  end
  if keyed then
    -- What an earlier run hashed, so a key reads none of it again
    -- (`build.declared_key`).
    local remembered, remembered_trouble = Sqlite.text_rows(records,
      "SELECT path, signature, sha256 FROM digests")
    if remembered == nil then
      local _, _ = work.rollback(handle)
      local _, _ = work.close(handle)
      log:complain(records_path .. ": " .. remembered_trouble)
      return 1
    end
    -- The store of each test module's closure, by the address its key
    -- holds, and none that no module names any longer.
    rec.projection = database
    local addressed, address_trouble = address_stores(rec, result.modules, by_path, declarations)
    if not addressed then
      local _, _ = work.rollback(handle)
      local _, _ = work.close(handle)
      log:complain("test: the stores of the test modules' closures: " .. address_trouble)
      return 1
    end
    sweep_stores(rec)
    rec.digests = declared_key.digests(root, remembered)
    -- A core that carries debug information, as the checked core does,
    -- is keyed by its image (build.core_image): its DWARF names the
    -- directory musl was first built in, which moves between CI runs,
    -- and no test's verdict turns on it. A release core, stripped, keys
    -- as the binary names it. Only a keyed run: an unkeyed one's
    -- verdicts are this checkout's alone, and hold the core's bytes.
    local host_image = Store.meta("host_image")
    if host_image ~= nil and rec.runtime:sub(1, #identity) == identity then
      rec.runtime = declared_key.runtime_identity(rec.digests, identity, host_image,
        Store.meta("runtime_basis") or "") .. rec.runtime:sub(#identity + 1)
    end
    rec.compiler = tool .. " " .. compiled_by
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
    rec.program = declared_key.program_identity(rec.digests, rec.tool)
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
  end
  local jobs: {Job} = {}
  -- The tests looked up in the shared cache, and whether any was found:
  -- where none was, `unmatched` says why.
  local looked: {string:boolean} = {}
  local keyed_count, looked_count, found_count, ran_here = 0, 0, 0, 0
  for _, m in ipairs(selected_modules) do
    for _, name in ipairs(selected_tests[m.path]) do
      local id = m.path .. " " .. name
      if keyed then
        -- Keyed, a test is keyed by what it is given, and runs
        -- unless a verdict under that key passed, here or in another
        -- checkout -- or it is forced, by --all, COSMIC_TEST_ALL or an
        -- audit, or reaches a network beyond loopback, which no key
        -- holds. None is assumed.
        local key = declared_of(rec, m, id)
        if key ~= nil then keyed_count = keyed_count + 1 end
        local own = key ~= nil and verdicts[key] or nil
        local elsewhere: shared_verdicts.Found = nil
        if key ~= nil and not forced and own == nil and consult and rec.shared ~= nil then
          local answer, trouble = shared_verdicts.declared(rec.shared, key)
          if answer == nil and trouble ~= "" then drop_shared(rec, trouble) end
          elsewhere = answer
          looked[id], looked_count = true, looked_count + 1
          if previous[id] ~= nil then ran_here = ran_here + 1 end
          if answer ~= nil then found_count = found_count + 1 end
        end
        if key == nil or forced or (own ~= nil and not own.passed) or
            (own == nil and elsewhere == nil) then
          jobs[#jobs + 1] = { m = m, name = name, id = id, declared = key }
        elseif own ~= nil then
          rec.shared_keys[key] = key
          stand(rec, credited, m, name, id, own, last_reads(previous, id), key)
        else
          share(rec, m, name, id, key, elsewhere, last_reads(previous, id))
        end
      else
        -- TODO: key every unsandboxed run by its declared inputs, as
        -- COSMIC_TEST_KEY=declared does, and retire the switch with
        -- `standing`, `assumable`, `identity_of` and `test.verdict_key`,
        -- once CI's fixtures run sandboxed, sharing verdicts (plan 4.1),
        -- and every hole plan 3.1 names is closed or accepted (M3):
        -- --audit already finds what a sandboxed test reads undeclared
        -- from what its sandbox refused it (build.refusals), past
        -- build.filesystem_observations' log. Today a run not given it is
        -- keyed by what it was seen to read, and shares no verdict.
        -- Forced (--all, COSMIC_TEST_ALL or an audit), it runs whatever
        -- stands, as a keyed test does.
        local stood, reads, key: test.Verdict, {observations.Observation}, string = nil, nil, nil
        if not forced then stood, reads, key = standing(rec, previous, verdicts, m, id) end
        local assumed: Assumed = nil
        local asked = everything
        for _, selector in ipairs(naming) do
          if test.selects(selector, m.path, m.file, name) then asked = true end
        end
        if stood == nil and not asked then
          local answer, _ = assumable(rec, previous, verdicts, m, id)
          assumed = answer
        end
        if stood ~= nil then
          stand(rec, credited, m, name, id, stood, reads, key)
        elseif assumed ~= nil then
          assume(rec, credited, m, name, id, assumed.verdict, assumed.key, assumed.kept)
        else
          jobs[#jobs + 1] = { m = m, name = name, id = id }
        end
      end
    end
  end
  -- The digests the run's keys hold, which each row it keeps in the
  -- shared cache is stamped with (`shared_verdicts.settle`): made only
  -- where there is a cache to stamp or a census to say, since
  -- `host_features` reads the processor's whole description.
  local census_asked = parsed.set["--census"] == true
  local parts: {{string}} = {}
  if keyed and (rec.shared ~= nil or census_asked) then
    parts = {
      -- As .github/scripts/host-features.sh names CI's verdict cache.
      { "host features", declared_key.host_features() },
      { "host", rec.host:sub(1, 12) },
      { "system", (rec.system or ""):sub(1, 12) },
      { "runtime", hex_sha256(rec.runtime or ""):sub(1, 12) },
      { "compiler", (rec.compiler or ""):sub(1, 12) },
      -- The key's harness parts, its epoch and timeout, as one word.
      { "harness", test.harness_word(rec.epoch, rec.timeout_ms) },
    }
    if rec.launcher ~= nil then parts[#parts + 1] = { "launcher", rec.launcher:sub(1, 12) } end
    if not sandboxed then parts[#parts + 1] = { "tree", hex_sha256(root):sub(1, 12) } end
    local runs_tool = false
    for _, m in ipairs(selected_modules) do
      if rec.effective[m.path] ~= nil and rec.effective[m.path].tool then runs_tool = true end
    end
    if runs_tool and rec.program ~= nil then
      parts[#parts + 1] = { "program", rec.program:sub(1, 12) }
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
  if keyed and (census_asked or (rec.shared ~= nil and looked_count > 0 and
      looked_count == keyed_count and ran_here == 0 and found_count == 0)) then
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
  if keyed then
    -- From here each key looks again: a verdict is kept only under a
    -- key its inputs still reach once its test has run.
    declared_key.thaw(rec.digests)
    local tests = 0
    for _, m in ipairs(selected_modules) do tests = tests + #selected_tests[m.path] end
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
  if #jobs > 0 then
    -- Nil when this process already holds a guard: test's `run` called
    -- in-process under one (build.invoke runs verbs so, though not
    -- `test` today). The run then goes unguarded, a signal acting as it
    -- would, rather than taking the signals from the guard's owner.
    local opened, _ = Child.guard()
    if opened == nil then
      run_jobs(rec, jobs, limits, nil)
    else
      -- A signal the guard caught ends this process when it closes,
      -- once the run is aborted.
      local guard <close> = opened
      if run_jobs(rec, jobs, limits, guard) ~= 0 then
        local _, _ = work.abort(handle)
        if rec.shared ~= nil then shared_verdicts.close(rec.shared) end
        -- A test that failed before the signal keeps its directory,
        -- named as a finished run's report names it: the failures on
        -- stdout, as there, and the errors and the cancellation on stderr.
        say_failures(rec, failures)
        for _, line in ipairs(errors) do log:complain("test: ERROR  " .. line) end
        log:complain("test: cancelled; every running test was ended")
        return 130
      end
    end
  end
  if keyed and rec.written > 0 then
    log:say(string.format("%s%s written (%s) in %.1f ms", keying,
      plural.count(rec.written, "closure store"), plural.count(rec.written_bytes, "byte"),
      rec.writing_ns / 1e6))
  end
  local total = tally.ran + tally.cached + tally.assumed

  local credit_trouble = credit_hits(records, credited, hits)
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
  local functions = Coverage.native_functions()
  if own_tree and #selectors == 0 and #functions > 0 then
    -- A host whose name cannot be had is held to every function.
    local names, uname_trouble = sys.uname()
    if names == nil then errors[#errors + 1] = "uname: " .. uname_trouble end
    local entered = c_functions.tally(functions, hits, c_functions.sources(root, functions),
      names ~= nil and names.sysname or nil)
    for _, key in ipairs(entered.unentered) do
      failures[#failures + 1] = key .. ": a C function no test enters"
    end
    function_lines[1] = string.format("test: C functions %d/%d entered by a test (%d exempt)",
      entered.entered, entered.total - entered.exempted, entered.exempted)
    -- An exemption a test entered is one this core no longer needs. The
    -- other core may still need it, so it is named here, never failed.
    if #entered.stale > 0 then
      function_lines[2] = "test: C exemptions a test entered on this core: " ..
        table.concat(entered.stale, ", ")
    end
  end

  local cov_hit, cov_total, cov_trouble =
    write_coverage(records, built, result.modules, native_lines, hits, by_test, run_at_ns)
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
    if #selectors == 0 then kept, keep_trouble = handle.db:exec("DELETE FROM digests") end
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
      Time.now_ns())
    shared_verdicts.close(rec.shared)
    if not settled then
      log:complain("test: shared verdicts: " .. rec.shared.path .. ": " .. settle_trouble)
    end
  end

  -- A module `importer.compile` refused ran no tests at all; every
  -- other module still compiled and ran above, so this only turns the
  -- overall verdict to FAIL, one line per refusal, rather than aborting
  -- the whole run the way an unrelated compile error still does.
  for _, line in ipairs(result.refused) do
    failures[#failures + 1] = line
  end

  -- What each test read beyond its inputs, module by module.
  local undeclared = 0
  if rec.audit ~= nil then
    local audited_tests = 0
    local modules_undeclared = 0
    for _, m in ipairs(selected_modules) do
      local per_test = rec.audit[m.path] or {}
      for _, findings in pairs(per_test) do
        audited_tests = audited_tests + 1
        if #findings > 0 then undeclared = undeclared + 1 end
      end
      local lines = test_inputs.report(m, per_test)
      if #lines > 0 then modules_undeclared = modules_undeclared + 1 end
      for _, line in ipairs(lines) do log:say(line) end
    end
    if undeclared > 0 then
      log:say(string.format("audit: %d of %d %s, in %s, read what they do not " ..
        "declare; see cosmic.test", undeclared, audited_tests, plural.noun(audited_tests, "test"),
        plural.count(modules_undeclared, "module")))
    else
      log:say(string.format("audit: %s read only %s inputs",
        plural.count(audited_tests, "test"), audited_tests == 1 and "its" or "their"))
    end
  end

  local cov_pct = cov_total > 0 and (cov_hit * 100.0 / cov_total) or 0.0
  local cov_line = string.format("test: coverage %.1f%% (%d/%d %s; informational, never a failure)",
    cov_pct, cov_hit, cov_total, plural.noun(cov_total, "line"))

  if #failures == 0 and #errors == 0 then
    if total == 0 then
      log:say("test: nothing to run: a test is a top-level `local function " ..
        "test_*` of a *_test.tl file, or a function of the `Example` " ..
        "record a *_example.tl file returns")
    end
    say_skips(rec)
    log:say(cov_line)
    for _, function_line in ipairs(function_lines) do log:say(function_line) end
    -- A figure the summary adds goes after `stood`: CI's driver reads the
    -- figures before it by their places (ci/cosmic_ci/suite_output.tl).
    log:verdict("test", true, plural.count(total, "test") .. ", " ..
      plural.count(modules_run, "module") .. "; " ..
      tally.ran .. " ran, " .. tally.cached .. " stood, " ..
      (tally.skipped > 0 and (tally.skipped .. " skipped (this host could not check " ..
        (tally.skipped == 1 and "it" or "them") .. "), ") or "") ..
      (tally.every > 0 and (tally.every .. " run every time (no key holds them), ") or "") ..
      (tally.assumed > 0 and (tally.assumed .. " assumed (--all runs them), ") or "") ..
      (tally.shared > 0 and (tally.shared .. " of them on another checkout's verdict, ") or "") ..
      clock.took(started) .. sandbox_summary)
    return undeclared > 0 and 1 or 0
  end
  say_skips(rec)
  say_failures(rec, failures)
  for _, line in ipairs(errors) do
    log:say("test: ERROR  " .. records_path .. ": " .. line)
  end
  if #errors == 0 then
    log:say(cov_line)
    for _, function_line in ipairs(function_lines) do log:say(function_line) end
  end
  log:verdict("test", false, #failures .. " of " ..
    (total + #result.refused) .. " failed, " .. plural.count(#errors, "infrastructure error") .. ", " ..
    clock.took(started) .. sandbox_summary)
  return 1
end

--- The `test` verb as `build/verb_list.tl` lists it.
test.spec = {
  name = "test",
  guide = "none: the verb is for the tree's own checks and is described by `cosmic help test`; the quickstart is about reading data and writing programs, not running a tree's suite",
  tests = { "build.test_test", "build.test_selection_test" },
  run = function(argv: {integer:string}): integer return run(argv) end,
  bare = false,
  takes = "exact module names, source paths and directories",
}

return test
