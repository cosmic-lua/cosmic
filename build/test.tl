--- Runs every test the tree defines that a stored verdict does not
--- already answer for, in-process, and records each verdict into the
--- working database, `o/build.db`, which never ships and is never
--- attached to `o/cosmic.db`.
---
--- A verdict is a function of the test module's key -- its source,
--- its import closure, the tool -- and of every file under the root
--- the test was observed to read, by content hash. While that key
--- stands, a passing verdict stands, and the test is not run again:
--- its module is still loaded, so what loading it hits is counted
--- fresh, and the lines the test itself hit in the run that produced
--- the verdict are credited to this one. Verdicts are kept by key, so
--- an edit undone finds its old verdict again. A failing verdict is
--- never reused; the test runs until it passes. Opens, stat queries,
--- and directory listings are observed through the syscall table.
--- Observations outside the root do not enter the key; the tool's own
--- hash, in every module key, invalidates everything at once.
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
--- `open` field, so wrapping it for the duration of one test's call
--- records every path that test caused to be opened, on every caller's
--- behalf, without any of them knowing. `pcall` around the call means
--- control always comes back here -- pass, fail, or an unrelated Lua
--- error -- so the original is always put back before the next test.

local Coverage = require("cosmic.coverage")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Time = require("cosmic.time")
local coverage_report = require("build.coverage.report")
local importer = require("build.importer")
local reboot = require("build.reboot")
local teal = require("build.teal")
local work = require("build.work")
local writer = require("build.writer")
local observations = require("build.filesystem_observations")
local type compiler = require("build.compiler")

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
end

local function report(line: string)
  Fs.put(Fs.stdout, line .. "\n")
end

local function complain(line: string)
  Fs.put(Fs.stderr, "cosmic: " .. line .. "\n")
end

local function text(value: string): Sqlite.Value
  return { text = value }
end

local function elapsed_ms(from: integer): integer
  local now = Time.monotonic_ns()
  if now == nil then
    return 0
  end
  return (now - from) // 1000000
end

local function record_run(handle: Sqlite.Handle, path: string, name: string,
                          passed: boolean, message: string, ran_at_ns: integer,
                          reads: {observations.Observation}, key: string,
                          run_at_ns: integer, cacheable?: boolean): boolean, string
  return Sqlite.run(handle,
    "INSERT OR REPLACE INTO runs (path, test, passed, message, ran_at_ns, " ..
    "reads, key, run_at_ns) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
    { text(path), text(name), { integer = passed and 1 or 0 }, text(message),
      { integer = ran_at_ns }, text(cacheable == false and
        observations.encode_unstable() or observations.encode(reads)), text(key),
      { integer = run_at_ns } })
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
    "SELECT key, passed, run_at_ns FROM verdicts")
  if rows == nil then
    return nil, trouble
  end
  local out: {string:test.Verdict} = {}
  for _, row in ipairs(rows) do
    out[row[1]] = {
      passed = row[2] == "1",
      run_at_ns = math.tointeger(tonumber(row[3]) or 0) or 0,
    }
  end
  return out
end

--- Records one verdict under its key, as relied on by this run.
local function record_verdict(handle: Sqlite.Handle, key: string, passed: boolean,
                              run_at_ns: integer, run: integer): boolean, string
  return Sqlite.run(handle,
    "INSERT OR REPLACE INTO verdicts (key, passed, run_at_ns, seen) " ..
    "VALUES (?1, ?2, ?3, ?4)",
    { text(key), { integer = passed and 1 or 0 }, { integer = run_at_ns },
      { integer = run } })
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
  local relative: string
  if path == root then
    relative = "."
  elseif path:sub(1, #root + 1) == root .. "/" then
    relative = path:sub(#root + 2)
  elseif path:sub(1, 1) ~= "/" then
    relative = path
  else
    return nil
  end
  if relative == "o" or relative:sub(1, 2) == "o/" then
    return nil
  end
  return relative
end

--- Adds observations that can affect a verdict to the process-wide set.
--- Module loads are shared by every later test, so this set is cumulative;
--- keeping it small prevents every test from repeatedly walking irrelevant or
--- identical queries. Distinct answers remain distinct and make the run
--- unstable when `verdict_key` sees them.
local function append_process_reads(root: string,
                                    into: {observations.Observation},
                                    seen: {string:{string:{string:boolean}}},
                                    found: {observations.Observation})
  for _, observation in ipairs(found) do
    if under_root(root, observation.path) ~= nil then
      local by_path = seen[observation.kind]
      if by_path == nil then
        by_path = {}
        seen[observation.kind] = by_path
      end
      local by_answer = by_path[observation.path]
      if by_answer == nil then
        by_answer = {}
        by_path[observation.path] = by_answer
      end
      if not by_answer[observation.answer] then
        by_answer[observation.answer] = true
        into[#into + 1] = observation
      end
    end
  end
end

--- What one test's verdict is a function of: the test itself, its
--- module's key, the runtime it ran under -- see `build.work`'s
--- `Identities` -- and the current hash of every file under the root
--- it read, by name. A file the stage holds is hashed already; any
--- other is read for it here, and one that is gone says so.
local function verdict_key(root: string, hashes: {string:string}, id: string,
                           module_key: string, runtime: string,
                           reads: {observations.Observation}):
                           string, boolean
  local seen: {string:boolean} = {}
  local answers: {string:string} = {}
  local stable = true
  local paths: {string} = {}
  for _, observation in ipairs(reads) do
    local relative = under_root(root, observation.path)
    local identified = observation.kind .. " " .. (relative or "")
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
  table.sort(paths)
  -- Bump the recording generation when the invariants of a reusable verdict
  -- change. Generation 1 runners could commit a verdict without its coverage
  -- after an infrastructure error, so none of their verdicts can stand.
  local lines: {string} = { "recording-2", "module-load-reads-v1",
    id .. " " .. module_key .. " " .. runtime }
  for _, identified in ipairs(paths) do
    local kind, relative = identified:match("^(.) (.*)$")
    local current: string
    if kind == "o" then
      current = hashes[relative]
      if current == nil then
        local data = Fs.read(root .. "/" .. relative)
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
    lines[#lines + 1] = observations.key_part(kind, relative, answer)
  end
  return Hash.hex_sha256(table.concat(lines, "\n")), stable
end

--- Resolves every run `credited` names against `coverage_by_test`,
--- folding the distinct lines its named tests hit into `hits`: only the
--- run-wide union of hit lines per module matters to `write_coverage`,
--- never which test hit which line, so this asks for exactly that
--- instead of loading every row of a credited run (a run's rows number
--- in the hundred thousands) to re-derive it in Lua. One query per run
--- credited, each naming only the tests this run actually still owes
--- it, rather than one per standing verdict.
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
      "SELECT DISTINCT path, line FROM coverage_by_test WHERE ran_at_ns = ?1 " ..
      "AND test IN (" .. table.concat(placeholders, ", ") .. ")", args)
    if rows == nil then
      return trouble
    end
    for _, row in ipairs(rows) do
      local per_line = hits[row[1]]
      if per_line == nil then
        per_line = {}
        hits[row[1]] = per_line
      end
      per_line[math.tointeger(tonumber(row[2]) or 0) or 0] = true
    end
  end
  return ""
end

--- The two coverage tables share their first three fields. Reuse their
--- statements for the many rows in a snapshot, checking every operation.
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

--- Every line `build.coverage.report` found for every non-vendor module
--- `modules` holds, added as a new snapshot for `run_at_ns`: rows here
--- are never replaced, only later pruned by `prune_history`, so a
--- file's coverage trend over the kept window of runs is a plain
--- query away rather than only the latest run's numbers. Also writes,
--- for every test that ran, which of the lines it hit into
--- `coverage_by_test`, tagged with that test's own identity (`by_test`,
--- keyed by "path name" the same way a failure line already identifies
--- a test elsewhere in this file); a test whose verdict stood is not
--- in `by_test`, since its rows from the run that produced them still
--- stand for it. Two statements, prepared once, since this is a
--- hundred thousand rows a run. Returns the overall hit and
--- executable-line counts, over every module written for this run,
--- for the run's own verdict line.
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
    "INSERT INTO coverage_by_test (ran_at_ns, path, line, test) " ..
    "VALUES (?1, ?2, ?3, ?4)")
  if per_test == nil then
    coverage:finalize()
    return 0, 0, test_trouble
  end
  local write_rows = function(): boolean, string
    for _, m in ipairs(modules) do
      if m.kind ~= "vendor" then
        local per_line, lines_trouble = coverage_report.lines_of(handle, built, m, hits)
        if per_line == nil then
          return false, m.file .. ": " .. lines_trouble
        end
        for line, was_hit in pairs(per_line) do
          local ok, write_trouble = insert_coverage(coverage, run_at_ns,
            m.path, line, was_hit and 1 or 0)
          if not ok then
            return false, write_trouble
          end
          total_lines = total_lines + 1
          if was_hit then
            total_hit = total_hit + 1
          end
        end
      end
    end
    for test_name, test_hits in pairs(by_test) do
      for path, per_line in pairs(test_hits) do
        for line in pairs(per_line) do
          local ok, write_trouble = insert_coverage(per_test, run_at_ns,
            path, line, test_name)
          if not ok then
            return false, write_trouble
          end
        end
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

--- Calls one test function with a fresh temporary directory as its one
--- argument, through `pcall`, and reports what it observed opening.
local function call_test(fn: function(any...): (any...)):
                         boolean, string, {observations.Observation}
  local tmp, tmp_trouble = Fs.mkdtemp("cosmic-test-")
  if tmp == nil then
    return false, "could not make a temporary directory: " .. tmp_trouble, {}
  end
  return observations.call(fn, tmp)
end

--- Runs every test one `kind = "test"` or `kind = "example"` module
--- found whose stored verdict does not stand, recording each into
--- `records` and appending
--- a line to `failures` for any that did not pass. Every hit line,
--- from this module's own one-time load and from each test in it, is
--- folded into `hits`, the whole-run accumulator; a test's own hits
--- are additionally kept in `by_test`, keyed by that test's own
--- identity, so `write_coverage` can credit specific lines to specific
--- tests. A test answered from its verdict has the hits of the run
--- that produced it folded into `hits`, and keeps pointing at that
--- run. Counts into `tally`.
local function run_module(records: Sqlite.Handle, m: importer.Module,
                          failures: {string}, errors: {string}, hits: Coverage.Hits,
                          by_test: {string: Coverage.Hits}, root: string,
                          previous: {string:test.Previous},
                          verdicts: {string:test.Verdict}, credited: test.Credited,
                          hashes: {string:string}, runtime: string,
                          run_at_ns: integer, run: integer, tally: test.Tally,
                          process_reads: {observations.Observation},
                          process_seen: {string:{string:{string:boolean}}})
  -- A module's own top-level code -- `local record X ... end`, `local Y
  -- = require(...)` and the like -- runs exactly once, right here, at
  -- first require, not once per test below. Left outside every
  -- coverage window, it would run in the gap between one test's window
  -- and the next and never be recorded as hit at all -- silently
  -- deflating the aggregate percentage. Folded into `hits` like any
  -- other window's hits; not attributed to `by_test`, since there is no
  -- single test to credit module-load code to.
  local module_session, module_start_trouble = Coverage.start()
  if module_session == nil then
    errors[#errors + 1] = m.path .. ": coverage start: " .. module_start_trouble
  end
  local ok, produced, newly_read = observations.capture(function(): any
    return require(m.path)
  end)
  append_process_reads(root, process_reads, process_seen, newly_read)
  if module_session ~= nil then
    local collected, stop_trouble = Coverage.stop(module_session)
    if collected == nil then
      errors[#errors + 1] = m.path .. ": coverage stop: " .. stop_trouble
    else
      merge_hits(hits, collected)
    end
  end
  if not ok then
    local message = "the module failed to load: " .. tostring(produced)
    for _, name in ipairs(m.tests) do
      failures[#failures + 1] = m.path .. " " .. name .. ": " .. message
      tally.ran = tally.ran + 1
      local saved, trouble = record_run(records, m.path, name, false, message,
        Time.now_ns() or 0, {}, "", run_at_ns)
      if not saved then
        errors[#errors + 1] = m.path .. " " .. name .. ": record: " .. trouble
      end
    end
    return
  end
  local mod = produced as {string:any}
  for _, name in ipairs(m.tests) do
    local id = m.path .. " " .. name
    local was = previous[id]
    local prior_reads = was ~= nil and
      observations.join(process_reads, was.reads) or process_reads
    local key = ""
    local prior_stable = false
    if was ~= nil then
      key, prior_stable = verdict_key(root, hashes, id, m.key, runtime, prior_reads)
    end
    local stood = prior_stable and verdicts[key] or nil
    if was ~= nil and stood ~= nil and stood.passed then
      -- The verdict stands: what the test read last time still hashes
      -- the same, and so does everything it was compiled from.
      tally.cached = tally.cached + 1
      local owed = credited[stood.run_at_ns]
      if owed == nil then
        owed = {}
        credited[stood.run_at_ns] = owed
      end
      owed[#owed + 1] = id
      local kept, keep_trouble = record_run(records, m.path, name, true, "",
        Time.now_ns() or 0, prior_reads, key, stood.run_at_ns)
      if not kept then
        errors[#errors + 1] = id .. ": record: " .. keep_trouble
      end
      kept, keep_trouble = record_verdict(records, key, true, stood.run_at_ns, run)
      if not kept then
        errors[#errors + 1] = id .. ": verdict: " .. keep_trouble
      end
    else
      tally.ran = tally.ran + 1
      local fn = mod[name] as function(any...): (any...)
      local test_session, test_start_trouble = Coverage.start()
      if test_session == nil then
        errors[#errors + 1] = id .. ": coverage start: " .. test_start_trouble
      end
      local passed, message, reads = call_test(fn)
      local test_reads = reads
      reads = observations.join(process_reads, test_reads)
      append_process_reads(root, process_reads, process_seen, test_reads)
      if test_session ~= nil then
        local collected, stop_trouble = Coverage.stop(test_session)
        if collected == nil then
          errors[#errors + 1] = id .. ": coverage stop: " .. stop_trouble
        else
          merge_hits(hits, collected)
          by_test[id] = collected
        end
      end
      local reached, stable = verdict_key(root, hashes, id, m.key, runtime, reads)
      local saved, trouble = record_run(records, m.path, name, passed, message,
        Time.now_ns() or 0, reads, reached, run_at_ns, stable)
      if not saved then
        errors[#errors + 1] = id .. ": record: " .. trouble
      end
      saved, trouble = record_verdict(records, reached, passed, run_at_ns, run)
      if not saved then
        errors[#errors + 1] = id .. ": verdict: " .. trouble
      end
      if not passed then
        failures[#failures + 1] = id .. ": " .. message
      end
    end
  end
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
  local run_at_ns = Time.now_ns() or 0

  local root, root_trouble = Fs.absolute(".")
  if root == nil then
    complain(root_trouble)
    return 1
  end
  local started = Time.monotonic_ns() or 0
  local own_tree = importer.is_own_tree(root)
  local handle, open_trouble = work.open(root)
  if handle == nil then
    complain(open_trouble)
    return 1
  end
  local staged, stage_trouble = work.stage(handle, own_tree)
  if staged == nil then
    work.close(handle)
    complain(stage_trouble)
    return 1
  end

  local built = teal.lazy()

  -- Same staleness guard `cosmic <file.tl>` applies when the tree under
  -- test is cosmic's own: a stale tool would check and compile it with
  -- a checker the tree no longer agrees with, and execute embedded
  -- cosmic.* implementations and tests from an old tree. When only
  -- Teal moved, the tool rebuilds itself and re-enters this command
  -- line; when the C core moved, zig has to.
  if own_tree then
    local state, state_trouble = reboot.state(handle)
    if state == nil then
      work.close(handle)
      complain(state_trouble)
      return 1
    end
    if state == "core" then
      work.close(handle)
      complain("the tool is stale; run bin/zig build boot")
      return 3
    end
    if state == "teal" then
      complain("the tool is stale; rebuilding it from the tree")
      local reboot_trouble = reboot.into(handle, built, argv)
      complain(reboot_trouble)
      return 3
    end
  end

  -- Both identities are read before the project's database is attached
  -- ahead of the binary's: they name this binary, and a project's own
  -- projection carries the ones of whichever binary wrote it.
  local tool = Store.meta("compiler") or ""
  local runtime = Store.meta("runtime") or ""
  local database = root .. "/o/cosmic.db"

  local result, compile_trouble = importer.compile(handle, built, tool)
  if result == nil then
    work.record(handle, elapsed_ms(started), staged, 0, 0, "FAIL")
    work.close(handle)
    complain(compile_trouble)
    return 1
  end
  local written, write_trouble =
    writer.write_result(handle, database, result)
  work.record(handle, elapsed_ms(started), staged, result.compiled,
    result.cached, written and "PASS" or "FAIL")
  if not written then
    work.close(handle)
    complain(write_trouble)
    return 1
  end
  report("build: " .. #result.modules .. " modules (" .. result.compiled ..
    " compiled, " .. result.cached .. " cached; " .. staged.files ..
    " files staged, " .. staged.read .. " read) in " ..
    elapsed_ms(started) .. " ms")

  local attached, attach_trouble = Store.attach(database)
  if not attached then
    work.close(handle)
    complain(attach_trouble)
    return 1
  end

  -- Every verdict and every coverage row of this run lands together.
  local begun, begin_trouble = work.begin(handle)
  if not begun then
    work.close(handle)
    complain(begin_trouble)
    return 1
  end
  local records_path = root .. "/o/build.db"
  local records = handle.db
  local previous, previous_trouble = previous_runs(records)
  if previous == nil then
    work.rollback(handle)
    work.close(handle)
    complain(records_path .. ": " .. previous_trouble)
    return 1
  end
  local hashes, hashes_trouble = staged_hashes(records)
  if hashes == nil then
    work.rollback(handle)
    work.close(handle)
    complain(records_path .. ": " .. hashes_trouble)
    return 1
  end
  local verdicts, verdicts_trouble = known_verdicts(records)
  if verdicts == nil then
    work.rollback(handle)
    work.close(handle)
    complain(records_path .. ": " .. verdicts_trouble)
    return 1
  end
  local credited: test.Credited = {}

  local tally: test.Tally = { ran = 0, cached = 0 }
  local modules_run = 0
  local failures: {string} = {}
  local errors: {string} = {}
  -- One collection window per test, not one for the whole run: each
  -- `start`/`stop` pair is a handful of cheap C calls (core/coverage.c),
  -- and the real cost is proportional to lines executed, not to how
  -- many times the hook toggles on and off, so this is not meaningfully
  -- slower than the one-window-per-run design it replaces. What it buys
  -- is attribution: a window scoped to exactly one test's own execution
  -- means the hits it collects can be credited to that test by name,
  -- which one continuous whole-suite window never could. The session
  -- each `start` hands back is what keeps a window its own opener's:
  -- an ordinary test elsewhere in the tree that also calls
  -- `start`/`stop` cannot reset or end a window it did not open, since
  -- it never has that same session value.
  local hits: Coverage.Hits = {}
  local by_test: {string: Coverage.Hits} = {}
  -- Requires are cached process-wide. Keeping every read observed while test
  -- modules or test bodies execute means a helper loaded earlier remains an
  -- input to later code that receives that already-loaded helper.
  local process_reads: {observations.Observation} = {}
  local process_seen: {string:{string:{string:boolean}}} = {}
  for _, m in ipairs(result.modules) do
    if (m.kind == "test" or m.kind == "example") and #m.tests > 0 then
      modules_run = modules_run + 1
      run_module(records, m, failures, errors, hits, by_test, root, previous,
        verdicts, credited, hashes, runtime, run_at_ns, handle.run, tally,
        process_reads, process_seen)
    end
  end
  local total = tally.ran + tally.cached

  local credit_trouble = credit_hits(records, credited, hits)
  if credit_trouble ~= "" then
    errors[#errors + 1] = "coverage credit: " .. credit_trouble
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
  local cov_line = string.format("test: coverage %.1f%% (%d/%d lines)",
    cov_pct, cov_hit, cov_total)

  if #failures == 0 and #errors == 0 then
    if total == 0 then
      report("test: nothing to run: a test is a top-level `local function " ..
        "test_*` of a *_test.tl file, or a function of the `Example` " ..
        "record a *_example.tl file returns")
    end
    report("test: PASS (" .. total .. " tests, " .. modules_run .. " modules; " ..
      tally.ran .. " ran, " .. tally.cached .. " stood)")
    report(cov_line)
    return 0
  end
  for _, line in ipairs(failures) do
    report("test: FAIL  " .. line)
  end
  for _, line in ipairs(errors) do
    report("test: ERROR  " .. records_path .. ": " .. line)
  end
  report("test: FAIL (" .. #failures .. " of " ..
    (total + #result.refused) .. " failed, " .. #errors .. " infrastructure errors)")
  if #errors == 0 then
    report(cov_line)
  end
  return 1
end

return test
