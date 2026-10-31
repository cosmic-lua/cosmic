--- The rebuild lock between runs of this program in one checkout:
--- `cosmic test`, and a write of the projection, hold it, one run per
--- checkout at a time, and let it go however they end; a verb that only
--- reads waits for none of them. Another process
--- holding or asking for it, or handed it, by a chunk is
--- build/rebuild_lock_lua_test.tl's; the rest is in
--- `rebuild_lock_test.tl`.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local importer = require("build.importer")
local TypeWatch = require("build.type_watch")
local work = require("build.work")
local writer = require("build.writer")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local rebuild_lock = require("build.rebuild_lock")
local this_program = require("build.this_program")
local build_paths = require("build.paths")
local reboot = require("build.reboot")
local tree = require("build.tree")
local rebuild = require("build.rebuild")
local identity = require("build.identity")
local todos = require("build.todos")

--- The program itself, whose runs of a verb or a file hold the lock
--- against this process.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" },
  { path = "lang/prelude.d.tl", letters = "r" }, { path = "lang/stdlib.d.tl", letters = "r" } } }

--- `root`'s build directory ([`build.paths`]), made, with `root` made
--- first where it is not there yet.
local function build_dir(root: string): string
  assert(Fs.mkdirs(root))
  return (assert(build_paths.prepare(root)))
end

--- A project whose one test passes, and sleeps `sleep_ns` first.
local function project(root: string, sleep_ns: integer)
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/slow_test.tl", table.concat({
    'local sys = require("cosmic.sys")',
    "local function test_slow()",
    "  assert(sys.nanosleep(" .. tostring(sleep_ns) .. "))",
    "end",
  }, "\n") .. "\n"))
end

--- Starts `cosmic test` on `root`, its stdout and stderr to `output`.
--- Its workers run unsandboxed (`COSMIC_TEST_SANDBOX=0`): the lock is
--- the run's, not its workers', and a sandbox nested in this test's own
--- is one a host may refuse, so the run means the same everywhere.
local function start_test(root: string, output: string): Child.Handle
  local fd = assert(Fs.open_write(output))
  local env = this_program.environment()
  env.COSMIC_TEST_SANDBOX = "0"
  env.COSMIC_VERDICT_CACHE = "0"
  local started = this_program.program({ "test" }, {
    cwd = root, env = env, stdout = fd, stderr = fd, process_group = true,
  })
  local h = assert(Child.start(started.argv, started.options))
  assert(Fs.close(fd))
  return h
end

--- Waits up to 20 s for `holds` to answer true, checking every 20 ms,
--- and answers true once it has.
local function await(what: string, holds: function(): boolean): boolean
  local deadline = Clock.monotonic_ns() + Clock.seconds(20)
  while not holds() do
    assert(Clock.monotonic_ns() < deadline, "gave up waiting for " .. what)
    assert(sys.nanosleep(Clock.ms(20)))
  end
  return true
end

--- A second run in a checkout waits for the run holding its lock, saying
--- so and naming what that run is doing, and passes once it lets go.
--- The first run is this test, holding the lock as `cosmic test` does.
local function test_a_second_run_waits_for_the_first_then_passes(tmp: string)
  local root = tmp .. "/project"
  project(root, 0)
  assert(rebuild_lock.hold(root, "test", "test"))
  local output = tmp .. "/second.out"
  local h = start_test(root, output)
  local ok, failure = pcall(await, "the second run to wait", function(): boolean
    local text = Fs.read(output) or ""
    return text:find("waiting for it", 1, true) ~= nil
  end)
  local running, _ = h:try_wait()
  rebuild_lock.release()
  local result = assert(h:wait(Clock.seconds(20)))
  local text = assert(Fs.read(output))
  assert(ok, tostring(failure) .. "\n" .. text)
  assert(running ~= nil and not running.finished, "the second run did not wait:\n" .. text)
  assert(result.ok, text)
  assert(text:find("test: another cosmic run (pid " .. tostring(sys.getpid()) ..
      ") in this checkout is running its tests; waiting for it", 1, true), text)
  assert(text:find("test: %d+ tests? passed in "), text)
end

--- A run lets its checkout's lock go however it ends: once it has
--- failed, and once it is interrupted mid-run, a run after it takes the
--- lock at once.
local function test_a_run_lets_the_lock_go_on_failure_and_interrupt(tmp: string)
  local root = tmp .. "/project"
  project(root, Clock.seconds(60))
  local h = start_test(root, tmp .. "/interrupted.out")
  local _ = await("the run to take the lock", function(): boolean
    return Fs.read(build_dir(root) .. "/rebuild.lock.pid") ~= nil and
      rebuild_lock.take(root, 0, "write") == "busy"
  end)
  assert(h:stop(sys.SIGINT))
  local interrupted = assert(h:wait(Clock.seconds(20)))
  assert(not interrupted.ok, "an interrupted run passed")
  -- Each half is let go with its descriptor, which the run opens
  -- close-on-exec: these fail should a process the run starts inherit
  -- it, and keep the flock, which outlives the run in any process
  -- holding the same open file.
  assert(rebuild_lock.take(root, 0, "write") == "held",
    "an interrupted run left the lock held:\n" .. tostring((Fs.read(tmp .. "/interrupted.out"))))
  rebuild_lock.release()

  assert(Fs.write(root .. "/suite/slow_test.tl",
    "local function test_fails()\n  error(\"no\")\nend\n"))
  local failed = assert(start_test(root, tmp .. "/failed.out"):wait(Clock.seconds(20)))
  assert(not failed.ok, tostring((Fs.read(tmp .. "/failed.out"))))
  assert(rebuild_lock.take(root, 0, "write") == "held", "a failed run left the lock held")
  rebuild_lock.release()
end

--- A write of a checkout's projection, cosmic.db, waits while another
--- run holds the checkout's lock, saying so, and lands once it lets go:
--- here a file run, which builds its tree and writes the projection
--- (build/dispatch.tl), while this test holds the lock as `cosmic test`
--- does.
local function test_a_write_of_the_projection_waits_for_the_lock(tmp: string)
  local root = tmp .. "/project"
  assert(build_dir(root))
  assert(Fs.write(root .. "/hello.tl", 'print("hello")\n'))
  assert(rebuild_lock.take(root, 0, "test") == "held")
  local output = tmp .. "/run.out"
  local fd = assert(Fs.open_write(output))
  local started = this_program.program({ "hello.tl" }, {
    cwd = root, env = this_program.environment(), stdout = fd, stderr = fd,
    process_group = true,
  })
  local h = assert(Child.start(started.argv, started.options))
  assert(Fs.close(fd))
  local ok, failure = pcall(await, "the write to wait", function(): boolean
    local text = Fs.read(output) or ""
    return text:find("waiting for it", 1, true) ~= nil
  end)
  local running, _ = h:try_wait()
  local projection, _ = sys.stat(build_dir(root) .. "/cosmic.db")
  local unwritten = projection == nil
  rebuild_lock.release()
  local result = assert(h:wait(Clock.seconds(20)))
  local text = assert(Fs.read(output))
  assert(ok, tostring(failure) .. "\n" .. text)
  assert(running ~= nil and not running.finished, "the write did not wait:\n" .. text)
  assert(unwritten, "the projection was written under the lock")
  assert(result.ok, text)
  assert(text:find(build_dir(root) .. "/cosmic.db: another cosmic run (pid " .. tostring(sys.getpid()) ..
      ") in this checkout is running its tests; waiting for it", 1, true), text)
  assert(text:find("hello\n", 1, true), text)
end

--- The verdicts of the rows in `builds` of the working database at
--- `path`, in run order, joined by spaces; or why they could not be
--- read, which raises nothing, so a caller holding the lock lets it go.
local function build_verdicts(path: string): string
  local db, open_trouble = Sqlite.open(path)
  if db == nil then return "unreadable: " .. open_trouble end
  local rows, trouble = Sqlite.text_rows(db, "SELECT verdict FROM builds ORDER BY run")
  local _, _ = db:close()
  if rows == nil then return "unreadable: " .. trouble end
  local verdicts = ""
  for i, row in ipairs(rows) do
    verdicts = verdicts .. (if i > 1 then " " else "" end) .. row:text(1)
  end
  return verdicts
end

--- A build that holds no rebuild lock, here a file run
--- (build/dispatch.tl), commits its row in `builds` with its compile,
--- before it waits for the lock to publish the projection: read from
--- another connection while it waits, the row is there, and once the
--- build lands it is the run's one row, a pass. A row written after the
--- publication would be lost to a run that removes the file once the
--- locks are free ([`writer.write_recorded`]).
local function test_a_build_commits_its_row_before_it_waits_to_publish(tmp: string)
  local root = tmp .. "/project"
  assert(build_dir(root))
  assert(Fs.write(root .. "/hello.tl", 'print("hello")\n'))
  local working = build_paths.resolve(root).working
  assert(rebuild_lock.take(root, 0, "test") == "held")
  local output = tmp .. "/run.out"
  local fd = assert(Fs.open_write(output))
  local started = this_program.program({ "hello.tl" }, {
    cwd = root, env = this_program.environment(), stdout = fd, stderr = fd,
    process_group = true,
  })
  local h = assert(Child.start(started.argv, started.options))
  assert(Fs.close(fd))
  local ok, failure = pcall(await, "the write to wait", function(): boolean
    local text = Fs.read(output) or ""
    return text:find("waiting for it", 1, true) ~= nil
  end)
  local during = build_verdicts(working)
  rebuild_lock.release()
  local result = assert(h:wait(Clock.seconds(20)))
  local text = assert(Fs.read(output))
  assert(ok, tostring(failure) .. "\n" .. text)
  assert(during == "PASS", "the build's row was not committed before publication: " .. during)
  assert(result.ok, text)
  assert(text:find("hello\n", 1, true), text)
  local after = build_verdicts(working)
  assert(after == "PASS", "the build's rows once published: " .. after)
end

--- A result waiting to publish keeps the rows and signature it compiled,
--- even when another run commits a failed or a different successful plan.
local function test_a_waiting_projection_keeps_its_compiled_snapshot(tmp: string)
  -- TODO: check this on a checked run too. It waits on a way to read the
  -- tree's projection and the binary's own modules there, as the checked
  -- worker is given the checked ones (build/test.tl's TODO on the same).
  if TypeWatch.checked() then
    Test.skip("a checked run's modules carry checks, so their bytecode is not the binary's")
  end
  for _, succeeds in ipairs({ false, true }) do
    local root = tmp .. (if succeeds then "/valid" else "/failed" end)
    assert(build_dir(root))
    local original = 'print("original")\n'
    assert(Fs.write(root .. "/main.tl", original))
    assert(rebuild_lock.take(root, 0, "test") == "held")
    local output = root .. "/a.out"
    local fd = assert(Fs.open_write(output))
    local started = this_program.program({ "main.tl" }, {
      cwd = root, env = this_program.environment(), stdout = fd, stderr = fd,
      process_group = true,
    })
    local a = assert(Child.start(started.argv, started.options))
    assert(Fs.close(fd))
    local ok, failure = pcall(function()
      assert(await("the compiled result to wait for publication", function(): boolean
        return (Fs.read(output) or ""):find("waiting for it", 1, true) ~= nil
      end))
      local staged = assert(work.open(root))
      -- A project: the signature is of the rows the run left, and no stage of this handle's adds to them.
      staged.standing = { own = false }
      local first: importer.Result = {
        main = nil, tool = "", modules = {}, refused = {}, left_out = {},
        compiled = 0, cached = 0, shared = 0, fact_wraps = 0, parameter_checks = 0,
        parses = { parsed = 0, shared = 0 },
      }
      local first_signature = assert(writer.signature(staged, first, Store.meta("writer") or ""))
      assert(work.close(staged))
      if succeeds then
        assert(Fs.write(root .. "/main.tl", 'print("replacement")\n'))
        local b = assert(work.open(root))
        assert(work.stage(b, { own = false }))
        local result = assert(importer.compile(b, "snapshot-test"))
        local alternate = root .. "/b.db"
        assert(writer.write_result(b, alternate, result))
        assert(work.close(b))
        local db = assert(Sqlite.open(alternate))
        local rows = assert(Sqlite.text_rows(db,
          "SELECT inflate(source) FROM modules WHERE path = 'main'"))
        assert(rows[1]:text(1) == 'print("replacement")\n')
        assert(db:close())
      else
        assert(Fs.write(root .. "/main.tl", 'local broken: string = 42\nprint(broken)\n'))
        local command = this_program.program({ "main.tl" }, {
          cwd = root, env = this_program.environment(), stdout = "capture", stderr = "capture",
        })
        local failed = assert(Child.run(command.argv, command.options))
        assert(not failed.ok, (failed.stdout or "") .. (failed.stderr or ""))
      end
      rebuild_lock.release()
      local result = assert(a:wait(Clock.seconds(20)))
      local text = assert(Fs.read(output))
      assert(result.ok, text)
      assert(text:find("original\n", 1, true), text)
      local db = assert(Sqlite.open(build_dir(root) .. "/cosmic.db"))
      local rows = assert(Sqlite.text_rows(db,
        "SELECT inflate(source) FROM modules WHERE path = 'main'"))
      assert(rows[1]:text(1) == original, "published another run's source")
      local signed = assert(Sqlite.text_rows(db,
        "SELECT value FROM meta WHERE key = 'projected'"))
      assert(signed[1]:text(1) == first_signature, "published another run's signature")
      assert(db:close())
    end)
    rebuild_lock.release()
    if not ok then
      local _ = a:stop(sys.SIGKILL)
      local _ = a:wait(Clock.seconds(20))
      error(failure)
    end
  end
end

--- A run of this program in `root`, `args` after it, its output captured
--- and bounded by `limit_ns`, so a run that waits fails rather than hangs.
local function bounded(root: string, args: {string}, limit_ns: integer): Child.Result
  local started = this_program.program(args, {
    cwd = root, env = this_program.environment(), stdout = "capture", stderr = "capture",
    timeout_ns = limit_ns,
  })
  return (assert(Child.run(started.argv, started.options)))
end

--- A module whose doc comment says `word`, with a TODO beside it.
local function thing(word: string): string
  return "local Fs = require(\"cosmic.fs\")\n\n--- " .. word .. " words.\nlocal record thing\nend\n\n" ..
    "-- TODO: say more, once there is more to say.\n" ..
    "--- Reads.\nfunction thing.read(): string\n  local text, why = Fs.read(\"x\") if text == nil then return why end return text\nend\n\nreturn thing\n"
end

--- A verb that only reads ([`verb_spec.Spec`]'s `reads`) answers while
--- another run holds the checkout's rebuild lock, as `cosmic test` does
--- for its whole run, and while that run holds the working database's
--- write lock too, as its build does: it waits for neither, and reads
--- what is there. Here this test is that run, and each verb a run of
--- the program. `docs` after an edit writes no projection under the
--- lock, so it answers from the last one, saying once why, and from the
--- edit once the lock is free.
local function test_a_reading_verb_answers_while_another_run_holds_the_lock(tmp: string)
  local root = tmp .. "/project"
  assert(build_dir(root))
  assert(Fs.write(root .. "/thing.tl", thing("First")))
  local built = bounded(root, { "build" }, Clock.seconds(20))
  assert(built.ok, (built.stdout or "") .. (built.stderr or ""))
  assert(Fs.write(root .. "/thing.tl", thing("Second")))
  local verbs: {{string}} = {
    { "docs", "thing" }, { "uses", "cosmic.fs.read" }, { "todos" }, { "db" },
    { "sql", "--build", "SELECT count(*) FROM files" },
  }
  -- Opened here, holding nothing until the second phase begins on it.
  local writer_db = assert(Sqlite.open(build_paths.resolve(root).working, { writable = true }))
  local ok, failure = pcall(function()
    assert(rebuild_lock.take(root, 0, "test") == "held")
    for _, phase in ipairs({ "rebuild lock", "both locks" }) do
      if phase == "both locks" then
        assert(writer_db:exec("BEGIN IMMEDIATE"))
      end
      for _, words in ipairs(verbs) do
        local result = bounded(root, words, Clock.seconds(10))
        local said = table.concat(words, " ") .. " with the " .. phase .. " held: " ..
          (result.stdout or "") .. (result.stderr or "")
        assert(not result.timed_out, "waited: " .. said)
        assert(result.ok, said)
        local out = result.stdout or ""
        if words[1] == "docs" then
          assert(out:find("First words.", 1, true), said)
          if phase == "rebuild lock" then
            assert((result.stderr or ""):find("docs: another cosmic run (pid " .. tostring(sys.getpid()) ..
                ") in this checkout is running its tests; not waiting for it", 1, true), said)
          end
        elseif words[1] == "uses" or words[1] == "todos" then
          assert(out:find("thing.tl:", 1, true), said)
        end
      end
    end
  end)
  local _, _ = writer_db:exec("ROLLBACK")
  local _, _ = writer_db:close()
  rebuild_lock.release()
  if not ok then error(failure) end
  local after = bounded(root, { "docs", "thing" }, Clock.seconds(20))
  local after_text = (after.stdout or "") .. (after.stderr or "")
  assert(after.ok, after_text)
  assert((after.stdout or ""):find("Second words.", 1, true), after_text)
end

--- How many builds the working database of `root` records.
local function builds_of(root: string): integer
  local db = assert(Sqlite.open(build_paths.resolve(root).working))
  local rows = assert(Sqlite.text_rows(db, "SELECT count(*) FROM builds"))
  assert(db:close())
  return assert(math.tointeger(tonumber(assert(rows[1]):text(1))))
end

--- The check before a verb that only reads, finding the tree's own tool
--- older than the tree while another run holds the checkout's rebuild
--- lock, as a `cosmic test` run does for its whole run, waits for none:
--- it rebuilds nothing, and the verb goes on. Its lookup then
--- builds nothing and `cosmic lsp`'s stage stages nothing, which would
--- compile or derive with that older code. The running tool is named, as
--- the test runner's own is not the tree's ([`reboot.Seen`]).
local function test_a_reading_verbs_check_goes_on_with_a_stale_tool_while_the_lock_is_held(tmp: string)
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root .. "/core"))
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/importer.tl", "return {}\n"))
  assert(work.close((assert(work.open(root)))))
  local layout = build_paths.resolve(root)
  assert(Fs.mkdirs(layout.bin))
  local before = builds_of(root)
  -- Held as another process holds it: one this process holds through
  -- build.rebuild_lock is one it takes as its own.
  local lock = assert(sys.open(layout.lock, sys.O_RDWR | sys.O_CREAT, 0x1a4))
  assert(sys.flock(lock, "exclusive"))
  local started = Clock.monotonic_ns()
  local ok, failure = pcall(function()
    local code = reboot.stale_exit({ "docs", "Fs.read" }, true, root,
      { tool = layout.tool, environment = {}, meta = { built_from = assert(tree.built_from(root)) } })
    local took = Clock.monotonic_ns() - started
    assert(code == nil, tostring(code))
    assert(took < Clock.seconds(10), tostring(took) .. " ns")
    assert(reboot.unchecked(root), "the stale tool is not remembered")
    local built, trouble = rebuild.here("docs", false, root)
    assert(built, trouble)
    assert(builds_of(root) == before, "a lookup built with a stale tool")
    local staged = assert(rebuild.stage(root))
    assert(staged.unchecked, "lsp's stage staged with a stale tool")
  end)
  assert(sys.close(lock))
  if not ok then error(failure) end
end

--- A tree shaped as cosmic's own at `root`, its working database made
--- and staged: the fingerprint the stage recorded of it.
local function own_tree(root: string): identity.Fingerprint
  assert(Fs.mkdirs(root .. "/core"))
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/importer.tl", "local record importer\nend\nlocal i: importer = {}\nreturn i\n"))
  -- The declarations a tree of cosmic's own is checked against ([`build.checker_declarations`]).
  assert(Fs.mkdirs(root .. "/lang"))
  local prelude = assert(Fs.read("lang/prelude.d.tl"))
  local stdlib = assert(Fs.read("lang/stdlib.d.tl"))
  assert(Fs.write(root .. "/build/ceilings.txt", ""))
  assert(Fs.write(root .. "/lang/prelude.d.tl", prelude))
  assert(Fs.write(root .. "/lang/stdlib.d.tl", stdlib))
  assert(Fs.mkdirs(build_paths.resolve(root).bin))
  local handle = assert(work.open(root))
  assert(work.stage(handle, { own = true }))
  local fingerprint = assert(identity.record_fingerprint(handle.db, handle.root))
  assert(work.close(handle))
  return fingerprint
end

--- Runs `body` while the rebuild lock of `root` is held as another process
--- holds it, then lets it go, raising what `body` raised.
local function held_elsewhere(root: string, body: function())
  local lock = assert(sys.open(build_paths.resolve(root).lock, sys.O_RDWR | sys.O_CREAT, 0x1a4))
  assert(sys.flock(lock, "exclusive"))
  local ok, failure = pcall(function(): boolean
    body()
    return true
  end)
  assert(sys.close(lock))
  if not ok then error(failure) end
end

--- A tool as new as the tree but unsettled, its database written by
--- other code than it carries, goes on as a stale one does while another
--- run holds the rebuild lock, rebuilding nothing; but its code is the
--- tree's, so the tree is not left unchecked and its lookup builds,
--- publishing nothing under the lock ([`writer.write_result`]). Its
--- running binary's `meta` is named ([`reboot.Seen`]), as the test
--- runner's is not this tree's.
local function test_a_reading_verbs_check_goes_on_with_a_fresh_unsettled_tool_and_builds(tmp: string)
  local root = tmp .. "/tree"
  local fingerprint = own_tree(root)
  local layout = build_paths.resolve(root)
  held_elsewhere(root, function()
    local started = Clock.monotonic_ns()
    local code = reboot.stale_exit({ "docs", "Fs.read" }, true, root, {
      tool = layout.tool, environment = {},
      meta = { boot_hash = fingerprint.boot, written_by = "an older writer", writer = "this writer",
        built_from = assert(tree.built_from(root)) },
    })
    local took = Clock.monotonic_ns() - started
    assert(code == nil, tostring(code))
    assert(took < Clock.seconds(10), tostring(took) .. " ns")
    assert(not reboot.unchecked(root), "a fresh tool's tree is left unchecked")
    local before = builds_of(root)
    local built, trouble = rebuild.here("docs", false, root, (assert(tree.built_from(root))))
    assert(built, trouble)
    assert(builds_of(root) == before + 1, "a fresh tool's lookup built nothing")
  end)
end

--- What `run` wrote to the descriptor `fd` (1 or 2), which is pointed at
--- a file in `dir` while it runs, raising what it raised once `fd` is
--- put back.
local function captured(fd: integer, dir: string, run: function()): string
  local path = dir .. "/captured." .. tostring(fd)
  local file = assert(sys.open(path, sys.O_RDWR | sys.O_CREAT | sys.O_TRUNC, 0x180))
  local saved = assert(sys.dup(fd))
  assert(sys.dup2(file, fd))
  local ok, failure = pcall(function(): boolean
    run()
    return true
  end)
  assert(sys.dup2(saved, fd))
  assert(sys.close(saved))
  assert(sys.close(file))
  if not ok then error(failure) end
  return (assert(Fs.read(path)))
end

--- The check before a verb that only reads, finding the tool stale by the
--- tree's Teal alone -- an edit while `cosmic test` holds the rebuild lock,
--- the commonest case -- waits for none: it rebuilds nothing, says that
--- this tool is older than the tree, and leaves the tree unchecked. It
--- says once a process that it does not wait for the lock's holder,
--- however many times it is asked ([`rebuild_lock.tell_not_waiting`]).
--- The running binary's `image_hash` is the tree's and its `boot_hash` is
--- not ([`reboot.Seen`]).
local function test_a_reading_verbs_check_goes_on_with_a_tool_stale_by_its_teal(tmp: string)
  local root = tmp .. "/tree"
  local fingerprint = own_tree(root)
  local seen: reboot.Seen = { tool = build_paths.resolve(root).tool, environment = {},
    meta = { image_hash = fingerprint.image, boot_hash = "not the tree's", built_from = assert(tree.built_from(root)) } }
  local said = captured(2, tmp, function()
    held_elsewhere(root, function()
      for _ = 1, 2 do
        local started = Clock.monotonic_ns()
        local code = reboot.stale_exit({ "docs", "Fs.read" }, true, root, seen)
        local took = Clock.monotonic_ns() - started
        assert(code == nil, tostring(code))
        assert(took < Clock.seconds(10), tostring(took) .. " ns")
      end
    end)
  end)
  assert(reboot.unchecked(root), "the stale tool is not remembered")
  assert(said:find("docs: this tool is older than the tree", 1, true), said)
  local _, waiting = said:gsub("not waiting for it", "")
  assert(waiting == 1, said)
end

--- What a run wrote to its standard error, kept apart from what it wrote
--- to its standard output.
local record Said
  mut err: string
end

--- How many rows of blame the working database of `root` keeps.
local function blames_of(root: string): integer
  local db = assert(Sqlite.open(build_paths.resolve(root).working))
  local rows = assert(Sqlite.text_rows(db, "SELECT count(*) FROM blames"))
  assert(db:close())
  return assert(math.tointeger(tonumber(assert(rows[1]):text(1))))
end

--- `todos` in a tree its check left unchecked, the tool older than the
--- tree while another run holds the rebuild lock, blames and prunes
--- nothing though the working database is free: a row of blame from an
--- earlier `HEAD`, which a listing that blames would drop, is kept. It
--- lists the TODOs that are indexed, and says nothing of a write lock no
--- run holds.
local function test_todos_in_an_unchecked_tree_writes_nothing(tmp: string)
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/kept.tl", "-- TODO: indexed by the last stage\n"))
  own_tree(root)
  local db = assert(Sqlite.open(build_paths.resolve(root).working, { writable = true }))
  assert(Sqlite.run(db, "INSERT INTO blames (path, line, sha256, head, commit_id, author_time, " ..
      "summary, boundary) VALUES ('kept.tl', 1, 'x', 'an earlier head', 'c', 0, 's', 0)"))
  assert(db:close())
  local seen: reboot.Seen = { tool = build_paths.resolve(root).tool, environment = {}, meta = { built_from = assert(tree.built_from(root)) } }
  local said: Said = { err = "" }
  local out = captured(1, tmp, function()
    said.err = captured(2, tmp, function()
      held_elsewhere(root, function()
        assert(todos.run({ "todos" }, root, seen) == 0)
      end)
    end)
  end)
  assert(reboot.unchecked(root), "the stale tool is not remembered")
  assert(out:find("kept.tl:1:", 1, true), out .. said.err)
  assert(blames_of(root) == 1, "blamed an unchecked tree")
  assert(not said.err:find("holds the write lock", 1, true), said.err)
end
