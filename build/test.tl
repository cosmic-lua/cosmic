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
--- the verdict, loading its module included, are credited to this one. Verdicts are kept by key, so
--- an edit undone finds its old verdict again. A failing verdict is
--- never reused; the test runs until it passes. Opens, stat queries,
--- and directory listings are observed through the syscall table.
--- Observations outside the root do not enter the key; the tool's own
--- hash, in every module key, invalidates everything at once.
--- Environment variables a test reads are part of its key; a test
--- that spawns a process or reads outside the tree beyond its own
--- temporary directories is never answered from a verdict.
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
--- writable directory `Fs.mkdtemp` made just for it, which the runner
--- does not remove afterward, so a failing test's own files stay
--- around to look at. A test that ignores the argument -- the ordinary
--- shape, a bare `assert()` -- is called with it anyway, and Lua drops
--- an argument nobody asked for.
---
--- Every file `cosmic.fs` opens goes through `cosmic.sys`'s shared
--- `open` field, so the worker wraps it, and the other queries a
--- verdict depends on, for the duration of loading the module and of
--- calling the test; see `build.filesystem_observations`.

local Child = require("cosmic.child")
local Coverage = require("cosmic.coverage")
local Env = require("cosmic.env")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local String = require("cosmic.string")
local Time = require("cosmic.time")
local clock = require("build.clock")
local sys = require("cosmic.sys")
local coverage_report = require("build.coverage.report")
local c_functions = require("build.c_functions")
local importer = require("build.importer")
local reboot = require("build.reboot")
local teal = require("build.teal")
local work = require("build.work")
local writer = require("build.writer")
local observations = require("build.filesystem_observations")
local worker = require("build.test_worker")
local type compiler = require("build.compiler")

local log = require("build.verdict").log

local record test
  --- What the last run recorded about one test: what it read, which
  --- is what its key is computed over next time.
  record Previous
    reads: {observations.Observation}
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

--- Whether one test module is named by a selector. A module name and its
--- source path match exactly; a directory matches only at a `/` boundary.
--- This keeps `test foo` from also selecting `foobar_test.tl`.
local function normalized(selector: string): string
  if selector == "" then return selector end
  selector = selector:gsub("/+$", "")
  while selector:sub(1, 2) == "./" do selector = selector:sub(3) end
  return selector
end

function test.matches(selector: string, path: string, file: string): boolean
  selector = normalized(selector)
  if selector == "." then return true end
  if selector == path or selector == file then return true end
  return Fs.within(file, selector)
end

local function selected(m: importer.Module, selectors: {string}): boolean
  if #selectors == 0 then return true end
  for _, selector in ipairs(selectors) do
    if test.matches(selector, m.path, m.file) then return true end
  end
  return false
end

local function text(value: string): Sqlite.Value
  return { text = value }
end

local function record_run(handle: Sqlite.Handle, path: string, name: string,
                          passed: boolean, message: string, ran_at_ns: integer,
                          reads: {observations.Observation}, key: string,
                          run_at_ns: integer, elapsed: integer,
                          cacheable?: boolean): boolean, string
  return Sqlite.run(handle,
    "INSERT OR REPLACE INTO runs (path, test, passed, message, ran_at_ns, " ..
    "reads, key, run_at_ns, elapsed_ns) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
    { text(path), text(name), { integer = passed and 1 or 0 }, text(message),
      { integer = ran_at_ns }, text(cacheable == false and
        observations.encode_unstable() or observations.encode(reads)), text(key),
      { integer = run_at_ns }, { integer = elapsed } })
end

--- What the last run left of every test, by "path name".
local function previous_runs(handle: Sqlite.Handle): {string:test.Previous} | nil, string
  local rows, trouble = Sqlite.text_rows(handle, "SELECT path, test, reads FROM runs")
  if rows == nil then
    return nil, trouble
  end
  local out: {string:test.Previous} = {}
  for _, row in ipairs(rows) do
    local reads = observations.decode(row[3])
    if reads ~= nil then
      out[row[1] .. " " .. row[2]] = { reads = reads }
    end
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

--- A recorded read as a path under the root, or nil when it is not
--- one: a test's own scratch directory, or anything else outside the
--- tree, is not an input to it, and nor is the build's own output.
local function under_root(root: string, path: string): string | nil
  local relative = path
  local rest, _ = Fs.relative(path, root)
  if rest ~= nil then
    relative = rest
  elseif path:sub(1, 1) == "/" then
    return nil
  end
  if relative == "o" or relative:sub(1, 2) == "o/" then
    return nil
  end
  return relative
end

--- What one test's verdict is a function of: the test itself, its
--- module's key, the runtime it ran under -- see `build.work`'s
--- `Identities` -- and the current hash of every file under the root
--- it read, by name. A file the stage holds is hashed already; any
--- other is read for it here, and one that is gone says so.
---
--- Exposed as `test.verdict_key` (`run_module`'s two call sites use it
--- the same as any other caller would) so `test_test.tl` can pin two
--- properties directly, without a compiled tree or a work database to
--- reach them through: that distinct inputs never collide on the same
--- key, and that a read whose current answer differs from what was
--- recorded turns `stable` false -- the two ways a wrong key could let
--- a verdict stand for a test it does not describe.
function test.verdict_key(root: string, hashes: {string:string}, id: string,
                          module_key: string, runtime: string,
                          reads: {observations.Observation},
                          key_parts: {string:string}):
                          string, boolean
  local seen: {string:boolean} = {}
  local answers: {string:string} = {}
  local stable = true
  local paths: {string} = {}
  for _, observation in ipairs(reads) do
    local kind = observation.kind
    if kind == "e" then
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
    elseif kind == "o" or kind == "s" or kind == "d" then
      local relative = under_root(root, observation.path)
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
  -- Bump the recording generation when the invariants of a reusable verdict
  -- change. Generation 1 runners could commit a verdict without its coverage
  -- after an infrastructure error, so none of their verdicts can stand.
  -- Generation 2 framed this header as a raw `id .. " " .. module_key .. " "
  -- .. runtime`: every caller today only ever passes a fixed-width hex
  -- digest for module_key and runtime, so no real collision was reachable,
  -- but nothing enforced that, and `id` (a test's own "path name") already
  -- carries a raw space of its own. Framed instead through the same
  -- `key_part` hex-encoding every read line already uses, so two distinct
  -- (id, module_key, runtime) triples can never concatenate to the same
  -- string regardless of what future caller or identity format hands them.
  -- Generation 4 runs each test in a worker process of its own: its reads
  -- and hits are its module's load and its own call, nothing an earlier
  -- test in the same process loaded, so no earlier verdict describes one.
  -- Generation 5 refuses a run that reached the network or changed its
  -- working directory, which generation 4 recorded without either.
  local lines: {string} = { "recording-5", "module-load-reads-v1",
    observations.key_part("i", id, observations.key_part("m", module_key, runtime)) }
  for _, identified in ipairs(paths) do
    local kind, relative = identified:match("^(.) (.*)$")
    local current: string
    if kind == "e" then
      current = observations.getenv_current(relative)
    elseif kind == "o" then
      current = hashes[relative]
      if current == nil then
        local data, _ = Fs.read(root .. "/" .. relative)
        current = data ~= nil and Hash.hex_sha256(data) or "missing"
      end
    elseif kind == "s" then
      current = observations.stat_answer(root .. "/" .. relative)
    else
      current = observations.directory_answer(root .. "/" .. relative)
    end
    local answer = answers[identified] or current
    if answers[identified] ~= nil and answers[identified] ~= current then
      stable = false
    end
    -- The same (kind, relative, answer) triple recurs across the run's
    -- tests constantly -- module loads and shared fixtures are read by
    -- most of them -- so its encoded line, which does not depend on
    -- anything but the triple itself, is worth remembering once.
    local memo_key = kind .. "\0" .. relative .. "\0" .. answer
    local part = key_parts[memo_key]
    if part == nil then
      part = observations.key_part(kind, relative, answer)
      key_parts[memo_key] = part
    end
    lines[#lines + 1] = part
  end
  return Hash.hex_sha256(table.concat(lines, "\n")), stable
end

--- Whether a passing verdict over `reads` is safe to reuse later: false
--- when the run spawned a process (an input no observation can hash),
--- made a request over the network or changed its working directory
--- (an "x" observation), or opened, stat'd, or listed a path outside `root`, `scratch`,
--- and every directory an "m" observation anywhere in the same list
--- shows the test made for itself (not only one earlier in the list:
--- `Fs.mkdirs` stats a directory to see whether it is already there
--- before the "m" observation that creates it, so the existence check
--- for a directory a test is about to make of its own would otherwise
--- count as a foreign read). An environment read is keyable: its
--- answer enters the verdict key like a file's hash does. Exposed
--- alongside `test.verdict_key` so `test_test.tl` can exercise it
--- directly.
function test.keyable(root: string, scratch: string,
                      reads: {observations.Observation}): boolean
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
    if kind == "o" or kind == "s" or kind == "d" then
      local path = observation.path
      if path:sub(1, 1) == "/" and not under(root, path) and not under(scratch, path) then
        local made_here = false
        for _, dir in ipairs(made) do
          if under(dir, path) then
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
  local state, failure = statement:step()
  if state == nil then
    return false, failure
  end
  return statement:reset()
end

--- How many rows one multi-row INSERT carries before it steps. Modest
--- on purpose: SQLite's parameter ceiling is far higher, but a longer
--- statement costs its own parse time, and the win is already in
--- trading six Lua-to-C calls per row for a fraction of one.
local insert_batch = 100

--- `n` value groups `(<run_at_ns>, ?, ?, ?)`, indexed contiguously from
--- 1, for a batch insert into `coverage`. `ran_at_ns` is the
--- same for every row one run writes, so it is a literal rather than a
--- parameter rebound once per row for nothing.
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

--- Every line `build.coverage.report` found for every non-vendor module
--- `modules` holds, added as a new snapshot for `run_at_ns`: rows here
--- are never replaced, only later pruned by `prune_history`, so a
--- file's coverage trend over the kept window of runs is a plain
--- query away rather than only the latest run's numbers. Also writes,
--- for every test that ran, which of the lines it hit into
--- `coverage_by_test`, tagged with that test's own identity (`by_test`,
--- keyed by "path name" the same way a failure line already identifies
--- a test elsewhere in this file); a test whose verdict stood is not
--- in `by_test`, since its row from the run that produced it still
--- stands for it. One row a test, its hits encoded by `encode_hits`.
--- Returns the overall hit and executable-line counts, over every
--- module written for this run, for the run's own verdict line.
local function write_coverage(handle: Sqlite.Handle, built: compiler,
                              modules: {importer.Module},
                              hits: Coverage.Hits,
                              by_test: {string: Coverage.Hits},
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
  -- `coverage` is WITHOUT ROWID, keyed (ran_at_ns, path, line):
  -- rows written in key order append at the right edge of the B-tree
  -- instead of splitting pages at random positions, which alone is
  -- most of the cost of writing them in hash order.
  -- The core's own C sits among the modules by path: a core that
  -- observes it answers every line a block begins on, and a line is hit
  -- when some window's hits name it (see `Coverage.native_lines`).
  local native_lines = Coverage.native_lines()
  local by_source: {string: importer.Module} = {}
  local sorted_paths: {string} = {}
  for _, m in ipairs(modules) do
    if m.kind ~= "vendor" then
      by_source[m.path] = m
      sorted_paths[#sorted_paths + 1] = m.path
    end
  end
  for path in pairs(native_lines) do
    if by_source[path] == nil then
      sorted_paths[#sorted_paths + 1] = path
    end
  end
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
        ok, write_trouble = per_test:bind_text(3, encode_hits(by_test[test_name]))
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
--- module-load's own coverage window hands back. Used to build the
--- whole-run accumulator up one small window's worth at a time.
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
  tmp: string
  handle: Child.Handle
  started_ns: integer
  deadline_ns: integer
end

--- Everything a finished job's verdict is recorded into.
local record Recording
  records: Sqlite.Handle
  root: string
  hashes: {string:string}
  runtime: string
  run_at_ns: integer
  run: integer
  key_parts: {string:string}
  failures: {string}
  errors: {string}
  --- What each failing test printed, by its id.
  outputs: {string:string}
  hits: Coverage.Hits
  by_test: {string: Coverage.Hits}
  tally: test.Tally
end

--- A verdict from a stored one that still stands: what the test read
--- last time still hashes the same, and so does everything it was
--- compiled from. Nil when there is none.
local function standing(rec: Recording, previous: {string:test.Previous},
                        verdicts: {string:test.Verdict}, m: importer.Module,
                        id: string): test.Verdict, {observations.Observation}, string
  local was = previous[id]
  if was == nil then return nil, nil, "" end
  local key, stable = test.verdict_key(rec.root, rec.hashes, id, m.key, rec.runtime,
    was.reads, rec.key_parts)
  local stood = stable and verdicts[key] or nil
  if stood == nil or not stood.passed then return nil, nil, "" end
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
    Time.now_ns(), reads, key, stood.run_at_ns, stood.elapsed_ns)
  if not kept then
    rec.errors[#rec.errors + 1] = id .. ": record: " .. keep_trouble
  end
  kept, keep_trouble = record_verdict(rec.records, key, true, stood.run_at_ns, rec.run,
    stood.elapsed_ns)
  if not kept then
    rec.errors[#rec.errors + 1] = id .. ": verdict: " .. keep_trouble
  end
end

--- How a worker's process ended, for a failure that has no report.
local function ending(result: Child.Result): string
  if result.signal ~= nil then return "was killed by signal " .. tostring(result.signal) end
  return "exited with status " .. tostring(result.code)
end

--- Records one finished job: the verdict its worker reported, or a
--- failure that says why there is no report to go by.
local function finish(rec: Recording, job: Job, result: Child.Result,
                      trouble: string, limits: test.Limits)
  rec.tally.ran = rec.tally.ran + 1
  local id = job.id
  local wall_ns = Time.monotonic_ns() - job.started_ns
  local reported: worker.Report
  local message: string
  if result == nil then
    message = "the test process could not be supervised: " .. trouble
  elseif result.timed_out then
    message = "timed out after " .. tostring(limits.timeout_ms // 1000) ..
      " s; its process group was ended"
  else
    local decoded, decode_trouble = worker.decode(result.captured[worker.report_fd])
    if decoded == nil then
      message = "the test process " .. ending(result) .. " before it reported (" ..
        decode_trouble .. ")"
    else
      reported = decoded
    end
  end
  local passed = false
  local reads: {observations.Observation} = {}
  local elapsed = wall_ns
  local cacheable = false
  if reported ~= nil then
    passed, message = reported.passed, reported.message
    reads = observations.join(reported.load_reads, reported.test_reads)
    elapsed = reported.elapsed_ns
    cacheable = reported.loaded and test.keyable(rec.root, job.tmp, reads)
    local hit: Coverage.Hits = {}
    merge_hits(hit, reported.load_hits)
    merge_hits(hit, reported.test_hits)
    merge_hits(rec.hits, hit)
    rec.by_test[id] = hit
    if passed and trouble ~= "" then
      -- The test passed, but what it started outlived it.
      passed, message = false, trouble
    end
  end
  local reached, stable = test.verdict_key(rec.root, rec.hashes, id, job.m.key,
    rec.runtime, reads, rec.key_parts)
  local saved, save_trouble = record_run(rec.records, job.m.path, job.name, passed,
    message, Time.now_ns(), reads, reached, rec.run_at_ns, elapsed,
    stable and cacheable)
  if not saved then
    rec.errors[#rec.errors + 1] = id .. ": record: " .. save_trouble
  end
  saved, save_trouble = record_verdict(rec.records, reached, passed, rec.run_at_ns, rec.run,
    elapsed)
  if not saved then
    rec.errors[#rec.errors + 1] = id .. ": verdict: " .. save_trouble
  end
  if not passed then
    rec.failures[#rec.failures + 1] = id .. ": " .. message
    if result ~= nil and result.stdout ~= nil and result.stdout ~= "" then
      rec.outputs[id] = result.stdout
    end
  end
end

--- The environment a worker starts with: this process's, less the
--- private startup hooks (`COSMIC_PORTABLE_STARTUP_TEST_*`), which pause
--- one startup of a fixture runtime for a handshake and belong to this
--- process's own launch, not to every worker it starts.
function test.worker_environment(environment: {string:string}): {string:string}
  local out: {string:string} = {}
  for name, value in pairs(environment) do
    if name:sub(1, 29) ~= "COSMIC_PORTABLE_STARTUP_TEST_" then out[name] = value end
  end
  return out
end

--- How a worker is started: this exact program again -- the same core,
--- whose runtime identity every verdict of the run is keyed under -- with
--- `test.worker_environment`. A process not started from a portable
--- artifact starts its logical executable instead. The worker also
--- collects coverage from its first instruction (core/coverage.c), so
--- its first window holds the Lua that loaded before it could open.
local function worker_start(environment: {string:string}): Proc.Relaunch | nil, string
  local env = test.worker_environment(environment)
  env.COSMIC_COVERAGE_STARTUP = "1"
  local relaunch, _ = Proc.relaunch()
  if relaunch ~= nil then
    for name, value in pairs(relaunch.env) do env[name] = value end
    return { argv = relaunch.argv, env = env, fds = relaunch.fds }, ""
  end
  local executable, trouble = Proc.executable()
  if executable == nil then return nil, trouble end
  return { argv = { executable }, env = env, fds = {} }, ""
end

--- Starts one job's worker. False when it could not start, which is
--- recorded as that test's failure.
local function launch(rec: Recording, job: Job, start: Proc.Relaunch,
                      limits: test.Limits): boolean
  local tmp, tmp_trouble = Fs.mkdtemp("cosmic-test-")
  if tmp == nil then
    finish(rec, job, nil, "could not make a temporary directory: " .. tmp_trouble, limits)
    return false
  end
  job.tmp = tmp
  job.started_ns = Time.monotonic_ns()
  job.deadline_ns = job.started_ns + limits.timeout_ms * 1000 * 1000
  local argv: {string} = {}
  for i, value in ipairs(start.argv) do argv[i] = value end
  for _, value in ipairs({ "test", "--worker", rec.root, job.m.path, job.name, tmp }) do
    argv[#argv + 1] = value
  end
  local fds: {integer:integer | string} = { [worker.report_fd] = "capture" }
  for number, fd in pairs(start.fds) do fds[number] = fd end
  local handle, trouble = Child.start(argv,
    { env = start.env, stdin = "null", stdout = "capture", stderr = "stdout", fds = fds })
  if handle == nil then
    finish(rec, job, nil, trouble, limits)
    return false
  end
  job.handle = handle
  return true
end

--- Runs every job, `limits.jobs` at a time, each to its verdict or its
--- deadline. SIGINT or SIGTERM ends every worker still running before
--- this process is ended by it; the signal comes back as the return.
local function run_jobs(rec: Recording, jobs: {Job}, limits: test.Limits): integer
  if #jobs == 0 then return 0 end
  local start, start_trouble = worker_start(Env.all())
  if start == nil then
    rec.errors[#rec.errors + 1] = "the test runner cannot find itself: " .. start_trouble
    return 0
  end
  local guarded, _ = sys.guard_child_signals()
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
    if guarded then
      local signal, _ = sys.cancelled_child_signal()
      cancelled = signal or 0
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
      elseif done == nil and trouble ~= "timeout" then
        -- Supervision itself failed; end this worker and say why.
        local _, _ = job.handle:close()
        finish(rec, job, nil, trouble, limits)
      elseif Time.monotonic_ns() >= job.deadline_ns then
        local result, stop_trouble = job.handle:wait(0)
        finish(rec, job, result, stop_trouble, limits)
      else
        still[#still + 1] = job
      end
    end
    if #still < #running then
      -- A worker that is gone may have left processes of its own
      -- behind, outside the group its end reached; this process
      -- adopted them, and ends them before the next test starts.
      Child.end_strays()
    end
    running = still
  end
  for _, job in ipairs(running) do local _, _ = job.handle:close() end
  Child.end_strays()
  if guarded then
    local late, _ = sys.unguard_child_signals()
    if cancelled == 0 then cancelled = late or 0 end
  end
  return cancelled
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
  local from_env = Env.get(timeout_variable)
  if from_env ~= nil and from_env ~= "" then
    local seconds, trouble = positive(from_env, timeout_variable)
    if seconds == nil then return nil, trouble end
    limits.timeout_ms = seconds * 1000
  end
  if values["--timeout"] ~= nil then
    local seconds, trouble = positive(values["--timeout"], "--timeout")
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

--- Builds the tree in the working directory and runs every test it
--- discovered, printing a verdict line and returning the exit code: 0
--- when every test passed.
--- @param argv the command line, which a stale tool re-enters after
---   rebuilding itself
function test.run(argv: {integer:string}): integer
  -- Captured once, up front, and threaded through everything below as
  -- this run's own identifier: see build/work.tl for why a nanosecond
  -- timestamp, not an autoincrement id, identifies a run.
  local run_at_ns = Time.now_ns()

  local root, root_trouble = Fs.absolute(".")
  if root == nil then
    log:complain(root_trouble)
    return 1
  end
  local parsed, parse_trouble = Flags.parse(argv, 2, { ["--timeout"] = true, ["--jobs"] = true })
  if parsed == nil then
    log:complain("test: " .. parse_trouble)
    return 2
  end
  local limits, limits_trouble = limits_of(parsed.values)
  if limits == nil then
    log:complain("test: " .. limits_trouble)
    return 2
  end
  local selectors: {string} = {}
  for _, word in ipairs(parsed.words) do
    local selector = normalized(word)
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
    selectors[#selectors + 1] = selector
  end
  local started = Time.monotonic_ns()
  local own_tree, own_trouble = importer.is_own_tree(root)
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

  -- Same staleness guard `cosmic <file.tl>` applies when the tree under
  -- test is cosmic's own: a stale tool would check and compile it with
  -- a checker the tree no longer agrees with, and execute embedded
  -- cosmic.* implementations and tests from an old tree. When only
  -- Teal moved, the tool rebuilds itself and re-enters this command
  -- line; when the C core moved, it has zig boot it (`build.reboot`).
  if own_tree then
    local state, state_trouble = reboot.state(handle)
    if state == nil then
      local _, _ = work.close(handle)
      log:complain(state_trouble)
      return 1
    end
    if state == "core" then
      local _, _ = work.close(handle)
      if not reboot.auto_boot() then
        log:complain(reboot.core_refusal)
        return 3
      end
      log:complain(reboot.boot_into(root, argv))
      return 3
    end
    if state == "teal" then
      log:complain("the tool is stale; rebuilding it from the tree")
      local reboot_trouble = reboot.into(handle, built, argv)
      log:complain(reboot_trouble)
      return 3
    end
  end

  -- Both identities are read before the project's database is attached
  -- ahead of the binary's: they name this binary, and a project's own
  -- projection carries the ones of whichever binary wrote it.
  local tool = Store.meta("compiler") or ""
  local runtime = Store.meta("runtime")
  if runtime == nil or runtime == "" then
    local _, _ = work.close(handle)
    log:complain("the running binary names no runtime identity")
    return 1
  end
  local database = root .. "/o/cosmic.db"

  local result, compile_trouble = importer.compile(handle, built, tool)
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
  log:say("build: " .. #result.modules .. " modules (" .. result.compiled ..
    " compiled, " .. result.cached .. " cached; " .. staged.files ..
    " files staged, " .. staged.read .. " read) in " ..
    clock.elapsed_ms(started) .. " ms")

  local selected_modules: {importer.Module} = {}
  for _, m in ipairs(result.modules) do
    if (m.kind == "test" or m.kind == "example") and #m.tests > 0 and
       selected(m, selectors) then
      selected_modules[#selected_modules + 1] = m
    end
  end
  -- Each selector must match a test module on its own: one mistyped
  -- among good ones would otherwise narrow the run without a word.
  local unmatched: {string} = {}
  for _, selector in ipairs(selectors) do
    local matched = false
    for _, m in ipairs(result.modules) do
      if (m.kind == "test" or m.kind == "example") and #m.tests > 0 and
         test.matches(selector, m.path, m.file) then
        matched = true
        break
      end
    end
    if not matched then
      unmatched[#unmatched + 1] = selector
    end
  end
  if #unmatched > 0 then
    local _, _ = work.close(handle)
    log:complain("no test module matches: " .. table.concat(unmatched, ", "))
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
  local credited: test.Credited = {}

  local tally: test.Tally = { ran = 0, cached = 0 }
  local modules_run = #selected_modules
  local failures: {string} = {}
  local errors: {string} = {}
  -- Every hit line of the run, and each test's own, which is what lets
  -- a later run credit a standing verdict's lines to it by name.
  local hits: Coverage.Hits = {}
  local by_test: {string: Coverage.Hits} = {}
  local rec: Recording = {
    records = records, root = root, hashes = hashes, runtime = runtime,
    run_at_ns = run_at_ns, run = handle.run, key_parts = {},
    failures = failures, errors = errors, outputs = {},
    hits = hits, by_test = by_test, tally = tally,
  }
  local jobs: {Job} = {}
  for _, m in ipairs(selected_modules) do
    for _, name in ipairs(m.tests) do
      local id = m.path .. " " .. name
      local stood, reads, key = standing(rec, previous, verdicts, m, id)
      if stood ~= nil then
        stand(rec, credited, m, name, id, stood, reads, key)
      else
        jobs[#jobs + 1] = { m = m, name = name, id = id }
      end
    end
  end
  local cancelled = run_jobs(rec, jobs, limits)
  if cancelled ~= 0 then
    local _, _ = work.abort(handle)
    log:complain("test: cancelled; every running test was ended")
    local _, _ = sys.kill(sys.getpid(), cancelled)
    return 130
  end
  local total = tally.ran + tally.cached

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
    local entered = c_functions.tally(functions, hits, c_functions.sources(root, functions))
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
    write_coverage(records, built, result.modules, hits, by_test, run_at_ns)
  if cov_trouble ~= "" then
    errors[#errors + 1] = "coverage: " .. cov_trouble
  end
  local pruned, prune_trouble = prune_history(records, handle.run)
  if not pruned then
    errors[#errors + 1] = "prune: " .. prune_trouble
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

  -- A module `importer.compile` refused ran no tests at all; every
  -- other module still compiled and ran above, so this only turns the
  -- overall verdict to FAIL, one line per refusal, rather than aborting
  -- the whole run the way an unrelated compile error still does.
  for _, line in ipairs(result.refused) do
    failures[#failures + 1] = line
  end

  local cov_pct = cov_total > 0 and (cov_hit * 100.0 / cov_total) or 0.0
  local cov_line = string.format("test: coverage %.1f%% (%d/%d lines; informational, never a failure)",
    cov_pct, cov_hit, cov_total)

  if #failures == 0 and #errors == 0 then
    if total == 0 then
      log:say("test: nothing to run: a test is a top-level `local function " ..
        "test_*` of a *_test.tl file, or a function of the `Example` " ..
        "record a *_example.tl file returns")
    end
    log:say(cov_line)
    for _, function_line in ipairs(function_lines) do log:say(function_line) end
    log:verdict("test", true, total .. " tests, " .. modules_run .. " modules; " ..
      tally.ran .. " ran, " .. tally.cached .. " stood, " .. clock.elapsed_ms(started) .. " ms")
    return 0
  end
  table.sort(failures)
  for _, failure in ipairs(failures) do
    log:say("test: FAIL  " .. failure)
    local id = failure:match("^(%S+ %S+):")
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
  for _, line in ipairs(errors) do
    log:say("test: ERROR  " .. records_path .. ": " .. line)
  end
  if #errors == 0 then
    log:say(cov_line)
    for _, function_line in ipairs(function_lines) do log:say(function_line) end
  end
  log:verdict("test", false, #failures .. " of " ..
    (total + #result.refused) .. " failed, " .. #errors .. " infrastructure errors, " ..
    clock.elapsed_ms(started) .. " ms")
  return 1
end

return test
