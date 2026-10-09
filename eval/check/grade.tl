--- Grades a task in an arena: the project keeps a journal, its tests
--- and format check pass, with recorded tests and examples behind them,
--- cosmic builds the task's executable, and that executable, copied
--- alone into an empty directory and run there, does what the task
--- asks.
---
---     cosmic --standalone eval/check/grade.tl <task> <dir>
---
--- [`eval/check/notes`] and its siblings, one for each task under
--- eval/task/, run this on the bootstrap cosmic, as bin/vendor runs
--- build/vendor.tl. `--standalone` loads no module beside this file, so
--- every task's checks live here, after the plumbing they share, and
--- the file requires `cosmic.*` modules only. The arena's own
--- [`bin/cosmic`] does the testing and building.
---
--- The executable runs with an empty environment -- no PATH, no HOME,
--- no TMPDIR -- unless a check names one, so nothing beside it and
--- nothing on PATH can help, as each task promises.
---
--- A task whose spec names a library API has a hidden test of it,
--- eval/check/testdata/<task>_api_test.tl, which the solver never
--- sees: it runs against a copy of the project, so it must compile
--- against the module the solver exported, types and all.
local Archive = require("cosmic.archive")
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Compress = require("cosmic.compress")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Sqlite = require("cosmic.sqlite")
local String = require("cosmic.string")
local sys = require("cosmic.sys")

local record Grader
  --- How many tests and examples passed.
  record Evidence
    tests: integer
    examples: integer
  end
end

--- One grading run: the arena, the task's executable and the empty
--- directory it runs in, how it is run, and whether anything has failed
--- yet.
local record Grade
  dir: string
  name: string
  exe: string
  empty: string
  steps: integer
  failed: boolean
  --- How long one run of the executable may take.
  timeout_ns: integer
  --- Whether each run's stdin is /dev/null rather than this process's.
  null_stdin: boolean
  --- Whether each run leads a process group of its own, ended with
  --- it; without one, what a run leaves behind outlives it, as it
  --- would outlive a shell's command, for a check to find.
  own_group: boolean
end

local function say(line: string)
  local _, _ = Fs.put(Fs.stdout, "check: " .. line .. "\n")
end

local function ok(line: string)
  say("ok   " .. line)
end

local function fail(g: Grade, line: string)
  say("FAIL " .. line)
  g.failed = true
end

--- Passes `line` when `holds`, else fails it with `why` after it.
local function check(g: Grade, holds: boolean, line: string, why?: string)
  if holds then
    ok(line)
  else
    fail(g, line .. (why ~= nil and why ~= "" and ": " .. why or ""))
  end
end

local status = Child.shell_status

--- Whether a failure's stderr is cosmic's own -- a launcher or
--- runtime failure -- rather than the tool's: a line of it starts with
--- `cosmic`.
function Grader.failed_in_cosmic(err: string): boolean
  return err:find("^cosmic") ~= nil or err:find("\ncosmic") ~= nil
end

--- Whether `cosmic build`'s output names o/bin/<name> among the
--- executables it wrote: `build: PASS (o/bin/notes, 433 ms)`.
function Grader.built(output: string, name: string): boolean
  for line in output:gmatch("[^\n]+") do
    local wrote = line:match("^build: PASS %((.*)%)$")
    if wrote ~= nil then
      for each in wrote:gmatch("[^,]+") do
        if String.trim(each) == "o/bin/" .. name then
          return true
        end
      end
    end
  end
  return false
end

local function first_line(text: string): string
  return text:match("^[^\n]*")
end

--- Text as `$(...)` gives it: without its trailing newlines.
local function trimmed(text: string): string
  return (text:gsub("\n+$", ""))
end

--- Clears the runs a build database records, keeping its verdicts:
--- `cosmic test` credits a verdict that still stands into runs again,
--- so what `evidence` finds afterward is this grading's own. A
--- database that is not there yet has nothing to clear.
function Grader.reset_evidence(path: string): boolean, string
  local present, trouble = Fs.exists(path)
  if present == nil then
    return false, trouble
  elseif not present then
    return true, ""
  end
  local db, otrouble = Sqlite.open(path, { writable = true })
  if db == nil then
    return false, otrouble
  end
  local done, etrouble = db:exec("delete from runs")
  local closed, close_trouble = db:close()
  if not done then return false, etrouble end
  if not closed then return false, close_trouble end
  return true, ""
end

--- How many tests and examples passed in the runs a build database
--- records; a doctest is an example.
function Grader.evidence(path: string): Grader.Evidence | nil, string
  local present, trouble = Fs.exists(path)
  if not present then
    return nil, present == nil and trouble or path .. ": no build database"
  end
  local db, otrouble = Sqlite.open(path)
  if db == nil then
    return nil, otrouble
  end
  local rows, rtrouble = Sqlite.text_rows(db, [[
    select i.kind, i.origin, count(*)
    from runs r join inputs i on i.path = r.path
    where r.passed = 1
    group by i.kind, i.origin
  ]], {})
  -- A read-only handle has nothing to lose in closing; the query's own
  -- answer is the one that counts.
  local _, _ = db:close()
  if rows == nil then
    return nil, rtrouble
  end
  local tests, examples = 0, 0
  for _, row in ipairs(rows) do
    local kind, origin, n = row[1], row[2], math.tointeger(tonumber(row[3])) or 0
    if kind == "test" and origin ~= "doctest" then
      tests = tests + n
    end
    if kind == "example" or origin == "doctest" then
      examples = examples + n
    end
  end
  return { tests = tests, examples = examples }, ""
end

local function exists(path: string): boolean
  local present, _ = Fs.exists(path)
  return present == true
end

--- Runs one step, its output kept in the arena as check-<n>.out and
--- shown beneath the step when it fails. A step is a command, or a
--- function standing for one under `label`, answering whether it
--- passed and what it printed. Answers whether it passed.
local function step(g: Grade, label: string, work: function(out: integer): boolean): boolean
  g.steps = g.steps + 1
  local log = g.dir .. "/check-" .. g.steps .. ".out"
  local out, trouble = Fs.open_write(log)
  if out == nil then
    fail(g, label .. ": " .. trouble)
    return false
  end
  local passed = work(out)
  local _, _ = Fs.close(out)
  if passed then
    ok(label)
    return true
  end
  fail(g, label)
  -- A log that cannot be read shows nothing under the failure.
  local read, _ = Fs.read(log)
  local text = read or ""
  if text ~= "" and text:sub(-1) ~= "\n" then
    text = text .. "\n"
  end
  for line in text:gmatch("([^\n]*)\n") do
    local _, _ = Fs.put(Fs.stdout, "check:   " .. line .. "\n")
  end
  return false
end

local function command_step(g: Grade, argv: {string}, cwd: string): boolean
  return step(g, table.concat(argv, " "), function(out: integer): boolean
    local result, trouble = Child.run(argv, { cwd = cwd, stdout = out, stderr = "stdout",
      timeout_ns = Clock.seconds(120) })
    if result == nil then
      local _, _ = Fs.put(out, trouble .. "\n")
      return false
    end
    return status(result) == 0
  end)
end

--- Checks the journal eval/journal.md's contract, appended to every
--- task's TASK.md, asks for: a regular file at `path` with something
--- in it. Answers why not when it is not one. A link, a pipe or a
--- device is refused unread, so no journal can stall the grader or
--- stand in for one kept elsewhere.
---
--- The contract labels its two parts in bold, not as headings a
--- journal must spell one way, and what they say is its reader's to
--- judge, so nothing past this is required of the text.
function Grader.journal(path: string): boolean, string
  local st, trouble, number = sys.lstat(path)
  if st == nil then
    if number == sys.ENOENT then
      return false, "no " .. path
    end
    return false, path .. ": " .. trouble
  end
  if st.kind ~= "file" then
    return false, path .. " is not a regular file"
  end
  local text, unread = Fs.read(path)
  if text == nil then
    return false, unread
  end
  if text:match("^%s*$") then
    return false, path .. " is empty"
  end
  return true, ""
end

--- Puts back a journal an earlier grading, killed while it had the
--- journal set aside for `fix --check`, left in the arena. Answers
--- whether [`fix_check`] may set the journal aside: not when the aside
--- is kept beside a new journal.
local function put_back_journal(g: Grade, project: string): boolean
  local journal = project .. "/JOURNAL.md"
  local aside = g.dir .. "/JOURNAL.md.aside"
  if not exists(aside) then
    return true
  end
  if exists(journal) then
    fail(g, aside .. " is an earlier grading's, beside a new JOURNAL.md; " ..
        "keeping both, and checking the new one")
    return false
  end
  local back, trouble = Fs.rename(aside, journal)
  if not back then
    fail(g, "could not put JOURNAL.md back from " .. aside .. ": " .. trouble)
  end
  return true
end

--- Runs `cosmic fix --check`, with the journal set aside when
--- `set_aside`: it is prose the task asks for, not a source the task
--- asks to have formatted, and `fix --check` holds a project's
--- Markdown to its link rules.
local function fix_check(g: Grade, cosmic: string, project: string, set_aside: boolean)
  local journal = project .. "/JOURNAL.md"
  local aside = g.dir .. "/JOURNAL.md.aside"
  local moved = false
  if set_aside then
    local renamed, _ = Fs.rename(journal, aside)
    moved = renamed
  end
  command_step(g, { cosmic, "fix", "--check" }, project)
  if moved then
    local back, trouble = Fs.rename(aside, journal)
    if not back then
      fail(g, "could not put JOURNAL.md back from " .. aside .. ": " .. trouble)
    end
  end
end

--- What `cosmic test` printed of a hidden API test that did not pass,
--- a line for each failure: a test that failed, with the first line
--- of why, or one of the first five lines the compiler refused, and
--- how many more it refused. Output with neither, of a run that
--- failed, answers its last line.
function Grader.api_failures(output: string): {string}
  local failures: {string} = {}
  local refused = 0
  local last = ""
  for line in output:gmatch("[^\n]+") do
    local failed = line:match("^test: FAIL  %S+ (.+)$")
    if failed ~= nil then
      failures[#failures + 1] = failed
    elseif line:match("^[^%s:]+%.tl:%d+:%d+: ") then
      refused = refused + 1
      if refused <= 5 then
        failures[#failures + 1] = "does not compile: " .. line
      end
    end
    last = line
  end
  if refused > 5 then
    failures[#failures + 1] = "does not compile: " .. (refused - 5) .. " more lines"
  end
  if #failures == 0 and not last:match("^test: PASS") then
    failures[#failures + 1] = "cosmic test failed: " .. last
  end
  return failures
end

--- The project's files a copy for the hidden API test takes: all but
--- what a build of it wrote, under `o/`. Only regular files are
--- copied, as [`Fs.walk`] lists them: a link could reach outside the
--- project, and a task's sources have no need of one.
local function copy_project(project: string, copy: string): boolean, string
  local files, trouble = Fs.walk(project, function(rel: string): boolean
    return rel == "o"
  end)
  if files == nil then return false, trouble end
  for _, rel in ipairs(files) do
    local data, rtrouble = Fs.read(project .. "/" .. rel)
    if data == nil then return false, rtrouble end
    local parent = (copy .. "/" .. rel):match("^(.*)/[^/]*$")
    local made, mtrouble = Fs.mkdirs(parent)
    if not made then return false, mtrouble end
    local wrote, wtrouble = Fs.write(copy .. "/" .. rel, data)
    if not wrote then return false, wtrouble end
  end
  return true, ""
end

--- Runs the hidden test at `test` against a copy of the project in a
--- directory of its own, so neither the test nor what running it
--- writes reaches the project, and the solver's own tests are not run
--- again. Its output is kept as the next check-<n>.out; each failure
--- is a `hidden api:` line.
local function hidden_api(g: Grade, cosmic: string, project: string, test: string)
  g.steps = g.steps + 1
  local log = g.dir .. "/check-" .. g.steps .. ".out"
  local source, trouble = Fs.read(test)
  if source == nil then
    fail(g, "hidden api: " .. trouble)
    return
  end
  local scratch, strouble = Fs.mkdtemp("cosmic-eval-api-")
  if scratch == nil then
    fail(g, "hidden api: " .. strouble)
    return
  end
  local name = test:match("([^/]+)$")
  local copy = scratch .. "/project"
  local ready, why = copy_project(project, copy)
  if ready then ready, why = Fs.write(copy .. "/" .. name, source) end
  if ready then ready, why = Fs.mkdirs(scratch .. "/tmp") end
  local output = ""
  if ready then
    -- A failing test's directory is kept under TMPDIR, which goes with
    -- the copy; no shared cache keeps the test's compile or verdict
    -- where a solver run by hand, with this HOME, could read it. A test
    -- that hangs is cut short well within the grading's own budget.
    local env = Env.all()
    env.TMPDIR = scratch .. "/tmp"
    env.COSMIC_BUILD_CACHE = "0"
    env.COSMIC_VERDICT_CACHE = "0"
    local result, rtrouble = Child.run({ cosmic, "test", "--timeout", "5", name }, { cwd = copy,
      env = env, stdout = "capture", stderr = "stdout", timeout_ns = Clock.seconds(20) })
    if result == nil then
      ready, why = false, rtrouble
    else
      output = result.stdout or ""
    end
  end
  local _, _ = Fs.write(log, output)
  local _, _ = Fs.remove_tree(scratch)
  if not ready then
    fail(g, "hidden api: could not run " .. name .. ": " .. why)
    return
  end
  local failures = Grader.api_failures(output)
  if #failures == 0 then
    ok("hidden api: " .. name .. " passes")
  end
  for _, failure in ipairs(failures) do
    fail(g, "hidden api: " .. failure)
  end
end

local function argv_of(g: Grade, args: {string}): {string}
  local argv: {string} = { g.empty .. "/" .. g.name }
  for _, word in ipairs(args) do
    argv[#argv + 1] = word
  end
  return argv
end

--- Runs the task's executable in the empty directory with `env` (an
--- empty environment by default), answering its result.
local function run(g: Grade, args: {string}, env?: {string: string}): Child.Result
  local options: Child.Options = { cwd = g.empty, env = env or {}, stdout = "capture",
    stderr = "capture", process_group = g.own_group, timeout_ns = g.timeout_ns }
  if g.null_stdin then options.stdin = "null" end
  local result, trouble = Child.run(argv_of(g, args), options)
  if result == nil then
    return { code = 127, ok = false, timed_out = false, stdout = "", stderr = trouble,
      captured = {}, truncated = false }
  end
  return result
end

local function label(g: Grade, args: {string}): string
  return "./" .. g.name .. " " .. table.concat(args, " ")
end

--- Checks that the executable exits 0 printing exactly `want` on stdout.
local function expect(g: Grade, want: string, args: {string})
  local result = run(g, args)
  local got = trimmed(result.stdout or "")
  if status(result) == 0 and got == want then
    ok(label(g, args) .. " -> " .. first_line(want))
  else
    fail(g, label(g, args) .. ": exit " .. status(result) .. ", got '" .. got ..
        "', wanted '" .. want .. "'; stderr: " .. first_line(result.stderr or ""))
  end
end

--- Checks that the executable exits 0, whatever it prints: for a
--- command whose task promises no output of it.
local function succeeds(g: Grade, args: {string})
  local result = run(g, args)
  if status(result) == 0 then
    ok(label(g, args) .. " -> exit 0")
  else
    fail(g, label(g, args) .. ": exit " .. status(result) .. "; stderr: " ..
        first_line(result.stderr or ""))
  end
end

--- Checks that the executable fails with a message of its own on
--- stderr, answering that message.
local function refuses(g: Grade, args: {string}): string
  local result = run(g, args)
  local err = result.stderr or ""
  if status(result) == 0 then
    fail(g, label(g, args) .. " exited 0")
  elseif err == "" then
    fail(g, label(g, args) .. " said nothing on stderr")
  elseif Grader.failed_in_cosmic(err) then
    fail(g, label(g, args) .. " failed in cosmic, not in " .. g.name .. ": " .. first_line(err))
  else
    ok(label(g, args) .. " -> exit " .. status(result) .. ", stderr: " .. first_line(err))
  end
  return err
end

--- Checks that `help` exits 0 printing usage that names every one of
--- `words`.
local function help(g: Grade, words: {string})
  local result = run(g, { "help" })
  local out = trimmed(result.stdout or "")
  if status(result) ~= 0 then
    fail(g, g.name .. " help exited " .. status(result))
    return
  elseif out == "" then
    fail(g, g.name .. " help printed nothing")
    return
  end
  local missing = ""
  for _, word in ipairs(words) do
    if not out:find(word, 1, true) then
      missing = missing .. " " .. word
    end
  end
  if missing ~= "" then
    fail(g, g.name .. " help did not mention:" .. missing)
  else
    ok(g.name .. " help -> mentions " .. table.concat(words, ", "))
  end
end

--- Writes `data` at `path` under the empty directory, making its parents.
local function write(g: Grade, path: string, data: string)
  local dir = path:match("^(.*)/[^/]*$")
  if dir ~= nil then
    local _, _ = Fs.mkdirs(g.empty .. "/" .. dir)
  end
  local written, trouble = Fs.write(g.empty .. "/" .. path, data)
  if not written then
    fail(g, "could not write " .. path .. ": " .. trouble)
  end
end

local function is_executable(path: string): boolean
  local st, _ = Fs.stat(path)
  return st ~= nil and st.kind == "file" and st.mode & 0x49 ~= 0
end

local function field(value: any, key: string): any
  if value is {string: any} then
    return value[key]
  end
  return nil
end

local function shown(value: any): string
  if value == nil then return "null" end
  return tostring(value)
end

local function since_ms(started: integer): integer
  return (Clock.monotonic_ns() - started) // Clock.ms(1)
end

--- Sleeps until `deadline` on the monotonic clock.
local function sleep_until(deadline: integer)
  local left = deadline - Clock.monotonic_ns()
  if left > 0 then
    local _, _ = Clock.sleep_ns(left)
  end
end

--- Whether two decoded JSON values are equal, numbers by value.
local function same(a: any, b: any): boolean
  if a is {any: any} and b is {any: any} then
    for k, v in pairs(a) do
      if not same(v, b[k]) then return false end
    end
    for k in pairs(b) do
      if a[k] == nil then return false end
    end
    return true
  end
  return a == b
end

-- servers

--- Starts `./<name> <args>` in the empty directory, its output kept in
--- the arena as `log` (check-serve.out by default), and waits up to
--- 5 s for the line naming the port it listens on. Answers the server
--- and its port, or nil once it has failed.
local function serves(g: Grade, args: {string}, log?: string): Child.Handle, integer
  local what = g.name .. " " .. table.concat(args, " ")
  local out_path = g.dir .. "/" .. (log or "check-serve.out")
  local out = assert(Fs.open_write(out_path))
  local options: Child.Options = { cwd = g.empty, env = {}, stdout = out, stderr = out }
  if g.null_stdin then options.stdin = "null" end
  local server, trouble = Child.start(argv_of(g, args), options)
  local _, _ = Fs.close(out)
  if server == nil then
    fail(g, what .. " did not start: " .. trouble)
    return nil, 0
  end
  local deadline = Clock.monotonic_ns() + Clock.seconds(5)
  while Clock.monotonic_ns() < deadline do
    local text, _ = Fs.read(out_path)
    local found = text ~= nil and text:match("listening on 127%.0%.0%.1:(%d+)\n")
    if found then
      local port = math.tointeger(tonumber(found))
      ok(what .. " -> listening on 127.0.0.1:" .. port)
      return server, port
    end
    local _, _ = Clock.sleep_ns(Clock.ms(50))
  end
  local text, _ = Fs.read(out_path)
  fail(g, what .. " printed no 'listening on 127.0.0.1:<port>' line in 5s: " ..
      first_line(text or ""))
  local _, _ = server:close()
  return nil, 0
end

--- Checks that the server, `what` (`<name> serve` by default), exits 0
--- within 3 s of SIGTERM.
local function stops(g: Grade, server: Child.Handle, what?: string)
  what = what or g.name .. " serve"
  local stopped, _ = server:stop()
  local result, _ = server:wait(Clock.seconds(3))
  if not stopped or result == nil or result.timed_out then
    fail(g, what .. " did not exit within 3s of SIGTERM")
  elseif status(result) ~= 0 then
    fail(g, what .. " exited " .. status(result) .. " on SIGTERM, not 0")
  else
    ok(what .. " exits 0 on SIGTERM")
  end
  local _, _ = server:close()
end

--- One response as the grader read it off the wire.
local record Answer
  status: integer
  headers: {string: string}
  body: string
  --- Whether the server closed the connection after it.
  closed: boolean
end

--- Reads one response off `conn`: its head, then up to its
--- Content-Length (none for a HEAD, a 304, or a 204 without one). With
--- `to_close`, for a request that asked for its connection closed, it
--- reads on past that until the server closes or 300 ms pass, so a body
--- after a HEAD's headers shows, and a response with no length is read
--- to its close; without, a response with no length is an error.
local function receive(conn: Net.Conn, head_only: boolean, to_close: boolean): Answer | nil, string
  local got = ""
  local answer: Answer = nil
  local body_length: integer = nil
  while true do
    if answer == nil then
      local head, rest = got:match("^(.-)\r\n\r\n(.*)$")
      if head ~= nil then
        local code = math.tointeger(tonumber(head:match("^HTTP/1%.[01] (%d%d%d)")))
        if code == nil then
          return nil, "no status line: " .. first_line(head)
        end
        local headers: {string: string} = {}
        for name, value in head:gmatch("\r\n([^:\r\n]+):[ \t]*([^\r\n]*)") do
          headers[name:lower()] = String.trim(value)
        end
        answer = { status = code, headers = headers, body = rest, closed = false }
        if head_only or code == 304 then
          body_length = 0
        else
          body_length = math.tointeger(tonumber(headers["content-length"] or ""))
          -- RFC 9110 forbids a Content-Length on a 204, which has no body.
          if body_length == nil and code == 204 then
            body_length = 0
          end
          if body_length == nil and not to_close then
            return nil, "no Content-Length in " .. first_line(head)
          end
        end
      end
    end
    if answer ~= nil and body_length ~= nil and #answer.body >= body_length then
      break
    end
    local chunk, trouble = conn:read()
    if chunk == nil then
      if answer == nil then
        return nil, trouble ~= "" and trouble or "closed before a response"
      elseif trouble ~= "" and to_close then
        return nil, trouble
      end
      answer.closed = true
      return answer, ""
    end
    if answer == nil then got = got .. chunk else answer.body = answer.body .. chunk end
  end
  if to_close then
    conn:set_timeout(Clock.ms(300))
    while true do
      local chunk, _ = conn:read()
      if chunk == nil then break end
      answer.body = answer.body .. chunk
    end
    local again, trouble = conn:read()
    answer.closed = again == nil and trouble == ""
  end
  return answer, ""
end

--- Sends `request` raw on a connection of its own and reads one
--- response, as [`receive`] reads it.
local function exchange(port: integer, request: string, head_only: boolean,
                        to_close: boolean): Answer | nil, string
  local conn, ctrouble = Net.connect(Net.tcp("127.0.0.1", port), { timeout_ns = Clock.seconds(3) })
  if conn == nil then return nil, ctrouble end
  local sent, strouble = conn:write(request)
  if not sent then
    local _, _ = conn:close()
    return nil, strouble
  end
  local answer, trouble = receive(conn, head_only, to_close)
  local _, _ = conn:close()
  if answer == nil then return nil, trouble end
  return answer, ""
end

-- notes

--- Runs [`./notes`] with nothing in its environment but `env`, and
--- checks that it exits 0 printing exactly `want` on stdout and stderr
--- together, or anything when `want` is nil.
local function notes_expect(g: Grade, want: string, args: {string}, env?: {string: string})
  local shown_args: {string} = { "env -i" }
  local names: {string} = {}
  for name in pairs(env or {}) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    shown_args[#shown_args + 1] = name .. "=" .. env[name]
  end
  shown_args[#shown_args + 1] = "./notes"
  for _, word in ipairs(args) do
    shown_args[#shown_args + 1] = word
  end
  local what = table.concat(shown_args, " ")
  local result, trouble = Child.run(argv_of(g, args), { cwd = g.empty, env = env or {},
    stdout = "capture", stderr = "stdout", process_group = g.own_group,
    timeout_ns = g.timeout_ns })
  local code = result ~= nil and status(result) or 127
  local got = result ~= nil and trimmed(result.stdout or "") or trouble
  if code == 0 and want == nil then
    ok(what .. " -> exit 0")
  elseif code == 0 and got == want then
    ok(what .. " -> " .. first_line(want))
  else
    fail(g, what .. ": exit " .. code .. ", got '" .. got .. "', wanted '" .. (want or "exit 0") .. "'")
  end
end

--- add, list, search, rm, an unknown id, NOTES_DB and help.
local function notes(g: Grade)
  notes_expect(g, "1", { "add", "hello", "world" })
  notes_expect(g, "2", { "add", "second", "note" })
  notes_expect(g, "1\thello world\n2\tsecond note", { "list" })
  notes_expect(g, "2\tsecond note", { "search", "second" })
  notes_expect(g, nil, { "rm", "1" })

  -- The message must be the tool's own: a launcher or runtime failure
  -- also exits non-zero with something on stderr.
  local result, _ = Child.run(argv_of(g, { "rm", "9" }), { cwd = g.empty, env = {},
    stdout = "null", stderr = "capture", process_group = g.own_group, timeout_ns = g.timeout_ns })
  local err = result ~= nil and result.stderr or ""
  local _, _ = Fs.write(g.dir .. "/check.err", err)
  if result ~= nil and status(result) == 0 then
    fail(g, "rm of an unknown id exited 0")
  elseif err == "" then
    fail(g, "rm of an unknown id said nothing on stderr")
  elseif Grader.failed_in_cosmic(err) then
    fail(g, "rm 9 failed in cosmic, not in notes: " .. first_line(err))
  else
    ok("rm 9 -> non-zero exit, stderr: " .. first_line(err))
  end
  notes_expect(g, "2\tsecond note", { "list" })
  notes_expect(g, "3", { "add", "50%", "off" })
  notes_expect(g, "4", { "add", "500", "off" })
  -- A LIKE pattern built from the word reads % and _ as wildcards.
  notes_expect(g, "3\t50% off", { "search", "50%" })
  notes_expect(g, "", { "search", "0_" })

  local _, _ = Fs.remove(g.empty .. "/notes.db")
  notes_expect(g, "1", { "add", "elsewhere" }, { NOTES_DB = "other.db" })
  local st, _ = Fs.stat(g.empty .. "/other.db")
  if st ~= nil and st.kind == "file" then
    ok("NOTES_DB names the file")
  else
    fail(g, "NOTES_DB was not honored")
  end
  help(g, { "add", "list", "rm", "search" })
end

-- pack

--- One ustar header and body for a file named `name` holding `data`.
local function ustar(name: string, data: string): string
  local function padded(text: string, width: integer): string
    return text .. string.rep("\0", width - #text)
  end
  local function octal(n: integer, width: integer): string
    return padded(string.format("%0" .. (width - 1) .. "o", n), width)
  end
  local head = padded(name, 100) .. octal(420, 8) .. octal(0, 8) .. octal(0, 8) ..
    octal(#data, 12) .. octal(0, 12) .. "        " .. "0" .. padded("", 100) ..
    "ustar\0" .. "00" .. padded("", 32) .. padded("", 32) .. octal(0, 8) .. octal(0, 8) ..
    padded("", 155)
  head = padded(head, 512)
  local sum = 0
  for i = 1, #head do
    sum = sum + head:byte(i)
  end
  head = head:sub(1, 148) .. string.format("%06o\0 ", sum) .. head:sub(157)
  local padding = (512 - #data % 512) % 512
  return head .. data .. string.rep("\0", padding)
end

local function pack(g: Grade)
  local bytes: {string} = {}
  for i = 0, 255 do
    bytes[#bytes + 1] = string.char(i)
  end
  local files: {{string}} = {
    { "a.txt", "alpha\n" },
    { "sub/b.txt", "bravo bravo\n" },
    { "sub/deep/c.bin", table.concat(bytes) },
  }
  local listing, sums: {string}, {string} = {}, {}
  for _, f in ipairs(files) do
    write(g, "src/" .. f[1], f[2])
    listing[#listing + 1] = #f[2] .. "\t" .. f[1]
    sums[#sums + 1] = Hash.hex_sha256(f[2]) .. "\t" .. f[1]
  end
  local want_list = table.concat(listing, "\n")
  local want_sum = table.concat(sums, "\n")
  local magic: {string: function(string): boolean} = {
    ["tar"] = function(s: string): boolean return s:sub(258, 262) == "ustar" end,
    ["tar.gz"] = function(s: string): boolean return s:sub(1, 2) == "\31\139" end,
    ["tgz"] = function(s: string): boolean return s:sub(1, 2) == "\31\139" end,
    ["zip"] = function(s: string): boolean return s:sub(1, 4) == "PK\3\4" end,
  }
  for _, ext in ipairs({ "tar", "tar.gz", "tgz", "zip" }) do
    local archive = "out." .. ext
    succeeds(g, { "create", archive, "src" })
    local data, _ = Fs.read(g.empty .. "/" .. archive)
    if data == nil or not magic[ext](data) then
      fail(g, archive .. " is not a " .. ext .. " file")
    else
      ok(archive .. " is a " .. ext .. " file")
    end
    expect(g, want_list, { "list", archive })
    expect(g, want_sum, { "sum", archive })
    local dest = "dest-" .. ext
    succeeds(g, { "extract", archive, dest })
    local whole = true
    for _, f in ipairs(files) do
      local got, _ = Fs.read(g.empty .. "/" .. dest .. "/" .. f[1])
      if got ~= f[2] then
        whole = false
        fail(g, "extract " .. archive .. ": " .. dest .. "/" .. f[1] .. " differs")
      end
    end
    if whole then ok("extract " .. archive .. " recreates every file") end
  end
  local gz, _ = Fs.read(g.empty .. "/out.tar.gz")
  write(g, "data.bin", gz or "")
  expect(g, want_list, { "list", "data.bin" })
  refuses(g, { "create", "out.rar", "src" })
  refuses(g, { "list", "src/a.txt" })
  refuses(g, { "list", "missing.tar" })

  write(g, "evil.tar", ustar("ok.txt", "fine\n") .. ustar("../evil.txt", "escaped\n") ..
      string.rep("\0", 1024))
  local err = refuses(g, { "extract", "evil.tar", "dest-evil" })
  check(g, err:find("../evil.txt", 1, true) ~= nil, "extract evil.tar names the entry ../evil.txt",
    first_line(err))
  local escaped, _ = Fs.exists(g.empty .. "/evil.txt")
  if escaped then
    fail(g, "extract evil.tar wrote evil.txt outside its destination")
  else
    ok("extract evil.tar wrote nothing outside its destination")
  end
  help(g, { "create", "list", "sum", "extract" })
end

-- ledger

local LEDGER_CSV <const> = table.concat({
  "when,amount,category,note",
  "2026-01-31T23:30:00-05:00,12.50,food,\"late dinner, downtown\"",
  "2026-02-01T10:00:00Z,-3.5,food,refund",
  "2026-02-15T12:00:00+01:00,1000,rent,\"multi",
  "line \"\"note\"\"\"",
  "not-a-date,5,food,bad",
  "2026-03-01T00:30:00+01:00,0.25,misc,",
  "2026-02-10T09:00:00Z,abc,food,bad amount",
}, "\n") .. "\n"

local function reports(g: Grade, args: {string}, want: string): string
  local result = run(g, args)
  local got, trouble = Json.decode(result.stdout or "")
  local wanted = assert(Json.decode(want))
  if status(result) ~= 0 then
    fail(g, label(g, args) .. ": exit " .. status(result) .. "; stderr: " ..
        first_line(result.stderr or ""))
  elseif got == nil then
    fail(g, label(g, args) .. ": stdout is no JSON (" .. trouble .. "): " ..
        first_line(result.stdout or ""))
  elseif not same(got, wanted) then
    fail(g, label(g, args) .. ": got " .. trimmed(result.stdout or "") .. ", wanted " .. want)
  else
    ok(label(g, args) .. " -> " .. (want:gsub("%s*\n%s*", "")))
  end
  return result.stderr or ""
end

local function ledger(g: Grade)
  write(g, "tx.csv", LEDGER_CSV)
  local err = reports(g, { "report", "tx.csv" }, [[{"months":[
    {"month":"2026-02","total_cents":100925,"categories":{"food":900,"rent":100000,"misc":25}}],
    "rows":4,"skipped":2}]])
  for _, line in ipairs({ "line 6", "line 8" }) do
    if err:find(line .. "%f[^%d]") then
      ok("stderr names " .. line)
    else
      fail(g, "stderr did not name " .. line .. ": " .. trimmed(err))
    end
  end
  reports(g, { "report", "--zone", "America/New_York", "tx.csv" }, [[{"months":[
    {"month":"2026-01","total_cents":1250,"categories":{"food":1250}},
    {"month":"2026-02","total_cents":99675,"categories":{"food":-350,"rent":100000,"misc":25}}],
    "rows":4,"skipped":2}]])
  reports(g, { "report", "tx.csv", "--zone", "Europe/Berlin" }, [[{"months":[
    {"month":"2026-02","total_cents":100900,"categories":{"food":900,"rent":100000}},
    {"month":"2026-03","total_cents":25,"categories":{"misc":25}}],
    "rows":4,"skipped":2}]])
  reports(g, { "report", "tx.csv", "--zone", "Europe/Berlin", "--from", "2026-02-02",
    "--to", "2026-03-01" }, [[{"months":[
    {"month":"2026-02","total_cents":100000,"categories":{"rent":100000}},
    {"month":"2026-03","total_cents":25,"categories":{"misc":25}}],
    "rows":2,"skipped":2}]])
  reports(g, { "report", "tx.csv", "--to", "2026-01-31", "--zone", "America/New_York" },
    [[{"months":[{"month":"2026-01","total_cents":1250,"categories":{"food":1250}}],
    "rows":1,"skipped":2}]])
  write(g, "wrong.csv", "date,amount,category,note\n2026-01-01T00:00:00Z,1,a,\n")
  refuses(g, { "report", "tx.csv", "--zone", "Mars/Olympus" })
  refuses(g, { "report", "missing.csv" })
  refuses(g, { "report", "wrong.csv" })
  refuses(g, { "report", "tx.csv", "--from", "yesterday" })
  help(g, { "report", "--zone", "--from", "--to" })
end

-- kv

--- Sends `request` raw, and checks the status is one of `codes` and, when
--- given, the body is `body`.
local function answers(g: Grade, port: integer, request: string, codes: {string}, body?: string)
  local what = first_line(request)
  local answer, trouble = exchange(port, request, false, false)
  if answer == nil then
    fail(g, what .. ": " .. trouble)
    return
  end
  local code = tostring(answer.status)
  local matched = false
  for _, c in ipairs(codes) do
    if c == code then matched = true end
  end
  local got_body = trimmed(answer.body)
  if not matched then
    fail(g, what .. ": status " .. code .. ", wanted " .. table.concat(codes, " or "))
  elseif body ~= nil and got_body ~= body then
    fail(g, what .. ": body '" .. got_body .. "', wanted '" .. body .. "'")
  else
    ok(what .. " -> " .. code)
  end
end

--- A GET that waits answers once a PUT sets its key, holding up no
--- other client meanwhile, or 404 once its time has passed.
local function kv_wait(g: Grade, port: integer)
  local waiting, trouble = Net.connect(Net.tcp("127.0.0.1", port), { timeout_ns = Clock.seconds(8) })
  if waiting == nil then
    fail(g, "GET /later?wait=5: " .. trouble)
    return
  end
  local _, _ = waiting:write("GET /later?wait=5 HTTP/1.1\r\nHost: x\r\n\r\n")
  local _, _ = Clock.sleep_ns(Clock.ms(300))
  local started = Clock.monotonic_ns()
  answers(g, port, "GET /beta HTTP/1.1\r\nHost: x\r\n\r\n", { "200" }, "two words")
  check(g, since_ms(started) < 1000, "GET /beta while another GET waits answered in " ..
      since_ms(started) .. " ms")
  answers(g, port, "PUT /later HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\nsoon", { "204" })
  local answer, why = receive(waiting, false, false)
  local took = since_ms(started)
  local _, _ = waiting:close()
  if answer == nil then
    fail(g, "GET /later?wait=5 after a PUT of it: " .. why)
  else
    check(g, answer.status == 200 and answer.body == "soon" and took < 1500,
      "GET /later?wait=5 answers the PUT's value once it is set, in " .. took .. " ms",
      "status " .. answer.status .. ", body '" .. answer.body .. "'")
  end
  started = Clock.monotonic_ns()
  answers(g, port, "GET /never?wait=0.5 HTTP/1.1\r\nHost: x\r\n\r\n", { "404" })
  took = since_ms(started)
  check(g, took >= 450 and took < 2500, "GET /never?wait=0.5 answered 404 after " .. took .. " ms",
    "wanted about 500 ms")
  started = Clock.monotonic_ns()
  answers(g, port, "GET /beta?wait=5 HTTP/1.1\r\nHost: x\r\n\r\n", { "200" }, "two words")
  check(g, since_ms(started) < 1000, "GET /beta?wait=5 of a key set answered at once")
  for _, query in ipairs({ "wait=soon", "wait=61", "wait=-1", "color=red" }) do
    answers(g, port, "GET /beta?" .. query .. " HTTP/1.1\r\nHost: x\r\n\r\n", { "400" })
  end
end

--- The keys `GET /` lists, one line.
local function listed(port: integer): string
  local answer, trouble = exchange(port, "GET / HTTP/1.1\r\nHost: x\r\n\r\n", false, false)
  if answer == nil then return "(" .. trouble .. ")" end
  return (trimmed(answer.body):gsub("\n", ","))
end

--- With --max-keys 2, a PUT of a new key into a full store evicts the
--- least recently used, a GET that finds a key and a PUT use it, and
--- nothing else does.
local function kv_lru(g: Grade)
  refuses(g, { "serve", "0", "--max-keys", "0" })
  refuses(g, { "serve", "0", "--max-keys", "two" })
  local server, port = serves(g, { "serve", "0", "--max-keys", "2" })
  if server == nil then
    return
  end
  local function put(key: string, value: string)
    answers(g, port, "PUT /" .. key .. " HTTP/1.1\r\nHost: x\r\nContent-Length: " .. #value ..
        "\r\n\r\n" .. value, { "204" })
  end
  local function keys_are(want: string, after: string)
    local got = listed(port)
    check(g, got == want, "--max-keys 2: after " .. after .. ", GET / lists " .. want, "got " .. got)
  end
  put("a", "1")
  put("b", "2")
  answers(g, port, "GET /a HTTP/1.1\r\nHost: x\r\n\r\n", { "200" }, "1")
  put("c", "3")
  keys_are("a,c", "PUT a, PUT b, GET a, PUT c")
  answers(g, port, "GET /b HTTP/1.1\r\nHost: x\r\n\r\n", { "404" })
  answers(g, port, "GET /c HTTP/1.1\r\nHost: x\r\n\r\n", { "200" }, "3")
  put("a", "10")
  keys_are("a,c", "GET c, PUT a again")
  put("d", "4")
  keys_are("a,d", "PUT d")
  answers(g, port, "GET /a HTTP/1.1\r\nHost: x\r\n\r\n", { "200" }, "10")
  answers(g, port, "DELETE /a HTTP/1.1\r\nHost: x\r\n\r\n", { "204" })
  put("e", "5")
  keys_are("d,e", "DELETE a, PUT e")
  answers(g, port, "GET /nothing HTTP/1.1\r\nHost: x\r\n\r\n", { "404" })
  local _ = listed(port)
  put("f", "6")
  keys_are("e,f", "GET of a missing key, GET /, PUT f")
  stops(g, server)
end

local function kv(g: Grade)
  local server, port = serves(g, { "serve", "0" })
  if server == nil then
    return
  end
  local base = "http://127.0.0.1:" .. port

  succeeds(g, { "put", base .. "/alpha", "hello" })
  expect(g, "hello", { "get", base .. "/alpha" })
  succeeds(g, { "put", base .. "/beta", "two words" })
  expect(g, "two words", { "get", base .. "/beta" })
  succeeds(g, { "rm", base .. "/alpha" })
  refuses(g, { "get", base .. "/alpha" })
  refuses(g, { "rm", base .. "/alpha" })

  answers(g, port, "GET / HTTP/1.1\r\nHost: x\r\n\r\n", { "200" }, "beta")
  answers(g, port, "PUT /raw HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc", { "204" })
  answers(g, port, "GET /raw HTTP/1.1\r\nHost: x\r\n\r\n", { "200" }, "abc")
  answers(g, port, "GET /nothing HTTP/1.1\r\nHost: x\r\n\r\n", { "404" })
  answers(g, port, "POST /raw HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n", { "400", "405" })
  answers(g, port, "DELETE /raw HTTP/1.1\r\nHost: x\r\n\r\n", { "204" })

  -- A client that sends half a request and waits must not hold up the next.
  local idle, itrouble = Net.connect(Net.tcp("127.0.0.1", port), { timeout_ns = Clock.seconds(3) })
  if idle == nil then
    fail(g, "idle connection: " .. itrouble)
  else
    local _, _ = idle:write("GET /beta HTTP/1.1\r\nHo")
    local started = Clock.monotonic_ns()
    local result = run(g, { "get", base .. "/beta" })
    local took = since_ms(started)
    if status(result) == 0 and trimmed(result.stdout or "") == "two words" and took < 3000 then
      ok("get while another client idles mid-request -> answered in " .. took .. " ms")
    else
      fail(g, "get while another client idles mid-request: exit " .. status(result) ..
          " after " .. took .. " ms; stderr: " .. first_line(result.stderr or ""))
    end
    local _, _ = idle:close()
  end

  kv_wait(g, port)
  stops(g, server)
  refuses(g, { "get", base .. "/beta" })
  kv_lru(g)
  help(g, { "serve", "put", "get", "rm", "--max-keys" })
end
-- jobs

local function sh(script: string): {string}
  return { "/bin/sh", "-c", script }
end

--- A jobfile's text for `jobs`, each of which is a table the JSON
--- encoder takes.
local function jobfile(g: Grade, path: string, jobs: {string: any})
  write(g, path, (assert(Json.encode(jobs))))
end

--- The report `jobs` printed, by job name, or nil and why.
local function jobs_report(result: Child.Result): {string: any} | nil, string
  local doc, trouble = Json.decode(result.stdout or "")
  if doc == nil then
    return nil, "stdout is no JSON (" .. trouble .. "): " .. first_line(result.stdout or "")
  end
  local jobs = field(doc, "jobs")
  if not jobs is {string: any} then
    return nil, "no \"jobs\" object in " .. first_line(result.stdout or "")
  end
  return jobs, ""
end

--- Checks one field of each named job's report.
local function each_job(g: Grade, report: {string: any}, key: string, want: {string: any})
  local names: {string} = {}
  for name in pairs(want) do names[#names + 1] = name end
  table.sort(names)
  local wrong: {string} = {}
  for _, name in ipairs(names) do
    local got = field(report[name], key)
    local expected = want[name]
    if expected == Json.null then expected = nil end
    if got ~= expected then
      wrong[#wrong + 1] = name .. " " .. shown(got) .. " (wanted " .. shown(expected) .. ")"
    end
  end
  check(g, #wrong == 0, "report " .. key .. " of " .. table.concat(names, ", "),
    table.concat(wrong, "; "))
end

local function number_of(value: any): number
  if value is number then return value end
  return nil
end

--- Runs main.json and checks its report and what its jobs left;
--- answers when, on the monotonic clock, the timed-out job's grandchild
--- would have written w/late had it outlived its job.
local function jobs_main(g: Grade, w: string): integer
  jobfile(g, "w/main.json", {
    first = { cmd = sh("echo first-out; echo first-err >&2; : > " .. w .. "/first.done") },
    second = { cmd = sh("[ -e " .. w .. "/first.done ] && : > " .. w .. "/second.ok"),
      needs = { "first" } },
    envcheck = { cmd = sh("[ \"$ONLY\" = yes ] && [ -z \"${LEAK+x}\" ] && : > " .. w ..
        "/env.ok"), env = { ONLY = "yes" } },
    here = { cmd = sh(": > here.txt"), cwd = w .. "/sub" },
    flaky = { cmd = sh("if [ -e " .. w .. "/f2 ]; then exit 0; elif [ -e " .. w ..
        "/f1 ]; then : > " .. w .. "/f2; exit 1; else : > " .. w .. "/f1; exit 1; fi"),
      retries = 3 },
    broken = { cmd = sh("exit 3"), retries = 1 },
    missing = { cmd = { "/nonexistent/program" } },
    after_broken = { cmd = sh(": > " .. w .. "/after_broken.ran"), needs = { "broken" } },
    after_after = { cmd = sh(": > " .. w .. "/after_after.ran"),
      needs = { "first", "after_broken" } },
    slow = { cmd = sh("(/bin/sleep 2; : > " .. w .. "/late) & /bin/sleep 30"), timeout = 0.5 },
  })
  local _, _ = Fs.mkdirs(w .. "/sub")
  local args = { "run", "w/main.json", "--parallel", "3", "--logs", "w/logs" }
  local started = Clock.monotonic_ns()
  local result = run(g, args, { LEAK = "from jobs" })
  local took = since_ms(started)
  check(g, status(result) ~= 0, label(g, args) .. " exits non-zero when a job failed",
    "exit 0")
  check(g, took < 4000, label(g, args) .. " finished in " .. took .. " ms",
    "a 0.5 s timeout should end it within a few seconds")
  local report, trouble = jobs_report(result)
  if report == nil then
    fail(g, label(g, args) .. ": " .. trouble .. "; stderr: " .. first_line(result.stderr or ""))
    return started + Clock.ms(took + 2600)
  end
  each_job(g, report, "status", { first = "ok", second = "ok", envcheck = "ok", here = "ok",
    flaky = "ok", broken = "failed", missing = "failed", after_broken = "skipped",
    after_after = "skipped", slow = "timeout" })
  each_job(g, report, "attempts", { first = 1, flaky = 3, broken = 2, missing = 1,
    after_broken = 0, after_after = 0, slow = 1 })
  each_job(g, report, "code", { first = 0, broken = 3, after_broken = Json.null,
    slow = Json.null })
  each_job(g, report, "start_ms", { after_broken = Json.null })
  local first_end = number_of(field(report.first, "end_ms"))
  local second_start = number_of(field(report.second, "start_ms"))
  check(g, first_end ~= nil and second_start ~= nil and second_start >= first_end,
    "second (needs first) started at " .. shown(second_start) .. " ms, after first ended at " ..
      shown(first_end) .. " ms")
  check(g, exists(w .. "/second.ok"), "second saw first's file when it ran")
  check(g, not exists(w .. "/after_broken.ran") and not exists(w .. "/after_after.ran"),
    "skipped jobs never ran")
  check(g, exists(w .. "/env.ok"), "a job sees its env and nothing of jobs's own")
  check(g, exists(w .. "/sub/here.txt"), "a job runs in its cwd")
  local slow_start = number_of(field(report.slow, "start_ms"))
  local slow_end = number_of(field(report.slow, "end_ms"))
  local slow_ran = slow_start ~= nil and slow_end ~= nil and slow_end - slow_start or nil
  check(g, slow_ran ~= nil and slow_ran >= 400 and slow_ran < 1500,
    "a job with a 0.5 s timeout ran " .. shown(slow_ran) .. " ms")
  local log, _ = Fs.read(w .. "/logs/first.log")
  check(g, log ~= nil and log:find("first-out", 1, true) ~= nil and
      log:find("first-err", 1, true) ~= nil, "w/logs/first.log holds first's stdout and stderr",
    log == nil and "no such file" or "got '" .. trimmed(log or "") .. "'")
  check(g, not (result.stdout or ""):find("first-out", 1, true),
    "a job's output stays out of jobs's stdout")
  -- slow waits its turn among ten jobs three at a time; without its
  -- start, it may have started as late as the run ended, and a start
  -- the report puts outside the run (epoch milliseconds) is not slept on.
  local slow_at = math.floor(math.min(math.max(slow_start or took, 0), took))
  return started + Clock.ms(slow_at + 2600)
end

--- Runs term.json and sends it SIGTERM; answers when the interrupted
--- job's grandchild would have written w/term.late had it outlived its
--- job, or 0 when it never started.
local function jobs_interrupt(g: Grade, w: string): integer
  jobfile(g, "w/term.json", {
    long = { cmd = sh("(/bin/sleep 1.5; : > " .. w .. "/term.late) & /bin/sleep 30") },
    quick = { cmd = sh(": > " .. w .. "/quick.done") },
    next = { cmd = sh(": > " .. w .. "/next.ran"), needs = { "long" } },
  })
  local args = { "run", "w/term.json" }
  local started = Clock.monotonic_ns()
  local handle, trouble = Child.start(argv_of(g, args), { cwd = g.empty, env = {},
    stdout = "capture", stderr = "capture", stdin = "null", process_group = false })
  if handle == nil then
    fail(g, label(g, args) .. " did not start: " .. trouble)
    return 0
  end
  local deadline = Clock.monotonic_ns() + Clock.seconds(3)
  while not exists(w .. "/quick.done") and Clock.monotonic_ns() < deadline do
    local _, _ = Clock.sleep_ns(Clock.ms(20))
  end
  local _, _ = Clock.sleep_ns(Clock.ms(300))
  local signalled = Clock.monotonic_ns()
  local _, _ = handle:stop()
  local result, _ = handle:wait(Clock.seconds(5))
  local took = since_ms(signalled)
  local _, _ = handle:close()
  -- long starts with the run; it has no needs.
  local late = started + Clock.ms(1500 + 600)
  if result == nil or result.timed_out then
    fail(g, label(g, args) .. " was still running 5 s after SIGTERM")
    return late
  end
  check(g, status(result) ~= 0 and took < 3000, label(g, args) .. " ended on SIGTERM in " ..
      took .. " ms, exit " .. status(result), "wanted a non-zero exit within 3 s")
  local report, rtrouble = jobs_report(result)
  if report == nil then
    fail(g, "report after SIGTERM: " .. rtrouble)
    return late
  end
  each_job(g, report, "status", { long = "interrupted", quick = "ok", next = "skipped" })
  check(g, not exists(w .. "/next.ran"), "no job starts after SIGTERM")
  return late
end

local function jobs_refusals(g: Grade, w: string)
  jobfile(g, "w/cycle.json", {
    alpha = { cmd = sh("exit 0"), needs = { "beta" } },
    beta = { cmd = sh("exit 0"), needs = { "gamma" } },
    gamma = { cmd = sh("exit 0"), needs = { "alpha" } },
    free = { cmd = sh(": > " .. w .. "/free.ran") },
  })
  local err = refuses(g, { "run", "w/cycle.json" })
  local named = false
  for _, job in ipairs({ "alpha", "beta", "gamma" }) do
    if err:find("job " .. job .. ": needs form a cycle", 1, true) then named = true end
  end
  check(g, named, "the cycle's refusal is 'job <a job in it>: needs form a cycle'", trimmed(err))
  check(g, not exists(w .. "/free.ran"), "nothing runs from a jobfile with a cycle")
  -- Each jobfile holds a job that would write free.ran, and one
  -- problem, refused with exactly the message the task names.
  local free = "\"free\": {\"cmd\": [\"/bin/sh\", \"-c\", \": > " .. w .. "/free.ran\"]}"
  local ok_cmd = "\"cmd\": [\"/bin/true\"]"
  local malformed: {{string}} = {
    { "[" .. "{" .. ok_cmd .. "}]", "jobfile: must be an object of jobs" },
    { "{" .. free .. ", \"build\": 5}", "job build: must be an object" },
    { "{" .. free .. ", \"build\": {\"cmd\": \"make\"}}",
      "job build: cmd must be a non-empty array of strings" },
    { "{" .. free .. ", \"build\": {\"cmd\": []}}",
      "job build: cmd must be a non-empty array of strings" },
    { "{" .. free .. ", \"build\": {\"cmd\": [\"/bin/true\", 7]}}",
      "job build: cmd must be a non-empty array of strings" },
    { "{" .. free .. ", \"build\": {" .. ok_cmd .. ", \"needs\": \"free\"}}",
      "job build: needs must be an array of strings" },
    { "{" .. free .. ", \"build\": {" .. ok_cmd .. ", \"timeout\": \"5\"}}",
      "job build: timeout must be a positive number" },
    { "{" .. free .. ", \"build\": {" .. ok_cmd .. ", \"timeout\": -1}}",
      "job build: timeout must be a positive number" },
    { "{" .. free .. ", \"build\": {" .. ok_cmd .. ", \"retries\": 1.5}}",
      "job build: retries must be a non-negative integer" },
    { "{" .. free .. ", \"build\": {" .. ok_cmd .. ", \"env\": {\"A\": 1}}}",
      "job build: env must be an object of strings" },
    { "{" .. free .. ", \"build\": {" .. ok_cmd .. ", \"cwd\": 5}}",
      "job build: cwd must be a string" },
    { "{" .. free .. ", \"build\": {" .. ok_cmd .. ", \"tiemout\": 5}}",
      "job build: unknown field tiemout" },
    { "{" .. free .. ", \"build\": {\"cmd\": 1, \"cwd\": 5}, \"alpha\": {" .. ok_cmd ..
        ", \"retries\": -2}}", "job alpha: retries must be a non-negative integer" },
    { "{" .. free .. ", \"a\": {" .. ok_cmd .. ", \"needs\": [\"ghost\"]}}",
      "job a: needs unknown job ghost" },
  }
  for i, case in ipairs(malformed) do
    local path = "w/malformed-" .. i .. ".json"
    write(g, path, case[1])
    local said = refuses(g, { "run", path })
    check(g, said:find(case[2], 1, true) ~= nil, path .. " is refused with '" .. case[2] .. "'",
      "stderr: " .. trimmed(said))
  end
  check(g, not exists(w .. "/free.ran"), "nothing runs from a malformed jobfile")
  write(g, "w/notjson.json", "jobs: [")
  refuses(g, { "run", "w/notjson.json" })
  refuses(g, { "run", "w/missing.json" })
end

--- Three one-second jobs at the default bound of two take about two
--- seconds: one when the bound is ignored, three when they run in turn.
local function jobs_parallel(g: Grade)
  jobfile(g, "w/par.json", {
    one = { cmd = { "/bin/sleep", "1" } },
    two = { cmd = { "/bin/sleep", "1" } },
    three = { cmd = { "/bin/sleep", "1" } },
  })
  local started = Clock.monotonic_ns()
  local args = { "run", "w/par.json" }
  local result = run(g, args)
  local took = since_ms(started)
  check(g, status(result) == 0, label(g, args) .. " exits 0 when every job is ok",
    "exit " .. status(result) .. "; stderr: " .. first_line(result.stderr or ""))
  check(g, took >= 1800 and took < 2900, label(g, args) .. " took " .. took ..
      " ms for three 1 s jobs two at a time", "wanted about 2000 ms")
  local report, trouble = jobs_report(result)
  if report == nil then
    fail(g, label(g, args) .. ": " .. trouble)
    return
  end
  local spans: {{number}} = {}
  for _, name in ipairs({ "one", "two", "three" }) do
    local s, e = number_of(field(report[name], "start_ms")), number_of(field(report[name], "end_ms"))
    if s ~= nil and e ~= nil then spans[#spans + 1] = { s, e } end
  end
  local most = 0
  for _, a in ipairs(spans) do
    local at = 0
    for _, b in ipairs(spans) do
      -- Ended within 50 ms of another's start counts as before it.
      if b[1] <= a[1] and a[1] < b[2] - 50 then at = at + 1 end
    end
    most = math.max(most, at)
  end
  check(g, #spans == 3 and most == 2, "report offsets show at most and at least two at once",
    #spans .. " spans, " .. most .. " at once")
end

local function jobs(g: Grade)
  local w = g.empty .. "/w"
  local _, _ = Fs.mkdirs(w)
  -- The timed-out job's grandchild writes w/late 2 s after the job
  -- started, and the interrupted one's w/term.late 1.5 s after it did,
  -- unless they were killed with their jobs: each is looked for once
  -- its own time has passed, timed from just before its run started,
  -- with 600 ms to spare less what jobs takes to start its jobs.
  local main_late = jobs_main(g, w)
  local term_late = jobs_interrupt(g, w)
  jobs_refusals(g, w)
  sleep_until(math.max(main_late, term_late))
  check(g, not exists(w .. "/late"), "a timed-out job's own children are killed with it")
  check(g, not exists(w .. "/term.late"), "an interrupted job's own children are killed with it")
  jobs_parallel(g)
  help(g, { "run", "--parallel", "--logs" })
end

-- mirror

--- One request to the server with `Connection: close`, and its answer.
local function request(port: integer, method: string, target: string,
                       headers?: {string: string}): Answer | nil, string
  local lines = { method .. " " .. target .. " HTTP/1.1", "Host: 127.0.0.1",
    "Connection: close" }
  local names: {string} = {}
  for name in pairs(headers or {}) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do lines[#lines + 1] = name .. ": " .. headers[name] end
  return exchange(port, table.concat(lines, "\r\n") .. "\r\n\r\n", method == "HEAD", true)
end

local record Site
  port: integer
  files: {string: string}
  closes: boolean
end

--- Asks the server, checks the status is one of `codes`, and answers
--- what came back for more checks, or nil once it has failed.
local function asks(g: Grade, site: Site, method: string, target: string,
                    headers: {string: string}, codes: {integer}): Answer
  local shown_headers: {string} = {}
  for name, value in pairs(headers) do shown_headers[#shown_headers + 1] = name .. ": " .. value end
  table.sort(shown_headers)
  local what = method .. " " .. target ..
    (#shown_headers > 0 and " (" .. table.concat(shown_headers, ", ") .. ")" or "")
  local answer, trouble = request(site.port, method, target, headers)
  if answer == nil then
    fail(g, what .. ": " .. trouble)
    return nil
  end
  if not answer.closed then site.closes = false end
  for _, code in ipairs(codes) do
    if answer.status == code then
      ok(what .. " -> " .. answer.status)
      return answer
    end
  end
  local wanted: {string} = {}
  for _, code in ipairs(codes) do wanted[#wanted + 1] = tostring(code) end
  fail(g, what .. ": status " .. answer.status .. ", wanted " .. table.concat(wanted, " or "))
  return nil
end

local function has(g: Grade, answer: Answer, what: string, name: string, want: string)
  if answer == nil then return end
  local got = answer.headers[name:lower()]
  check(g, got == want, what .. " " .. name .. ": " .. shown(got),
    "wanted " .. shown(want))
end

local function body_is(g: Grade, answer: Answer, what: string, want: string)
  if answer == nil then return end
  check(g, answer.body == want, what .. " body is the " .. #want .. " bytes wanted",
    "got " .. #answer.body .. " bytes")
end

local function tag(data: string): string
  return "\"" .. Hash.hex_sha256(data) .. "\""
end

local function mirror_files(site: Site)
  local bytes: {string} = {}
  for i = 0, 255 do bytes[#bytes + 1] = string.char(i) end
  local lines: {string} = {}
  for i = 1, 250 do lines[#lines + 1] = string.format("line %04d of the big file\n", i) end
  site.files = {
    ["a.txt"] = "alpha\n",
    ["big.txt"] = table.concat(lines),
    ["sub/b.bin"] = table.concat(bytes),
    ["sub/deep/c.txt"] = "charlie\n",
    ["two words.txt"] = "spaced out\n",
  }
end

local function mirror_listings(g: Grade, site: Site)
  local function entry(name: string, path: string): any
    local data = site.files[path]
    return { name = name, type = "file", size = #data, sha256 = Hash.hex_sha256(data) }
  end
  local wants: {{string | {any}}} = {
    { "/", { entry("a.txt", "a.txt"), entry("big.txt", "big.txt"), { name = "sub", type = "dir" },
      entry("two words.txt", "two words.txt") } },
    { "/sub", { entry("b.bin", "sub/b.bin"), { name = "deep", type = "dir" } } },
    { "/sub/deep/", { entry("c.txt", "sub/deep/c.txt") } },
  }
  for _, want in ipairs(wants) do
    local target, entries = want[1], want[2]
    if target is string and entries is {any} then
      local answer = asks(g, site, "GET", target, {}, { 200 })
      if answer ~= nil then
        local got, trouble = Json.decode(answer.body)
        local expected = assert(Json.decode((assert(Json.encode(entries)))))
        check(g, got ~= nil and same(got, expected), "GET " .. target ..
            " lists its entries by name", got == nil and trouble or "got " .. answer.body)
      end
    end
  end
end

local function mirror_requests(g: Grade, site: Site)
  local small, big = site.files["a.txt"], site.files["big.txt"]
  local a = asks(g, site, "GET", "/a.txt", {}, { 200 })
  body_is(g, a, "GET /a.txt", small)
  has(g, a, "GET /a.txt", "ETag", tag(small))
  has(g, a, "GET /a.txt", "Content-Length", tostring(#small))
  local spaced = asks(g, site, "GET", "/two%20words.txt", {}, { 200 })
  body_is(g, spaced, "GET /two%20words.txt", site.files["two words.txt"])
  local deep = asks(g, site, "GET", "/sub/deep/c.txt", {}, { 200 })
  body_is(g, deep, "GET /sub/deep/c.txt", site.files["sub/deep/c.txt"])

  local head = asks(g, site, "HEAD", "/big.txt", {}, { 200 })
  has(g, head, "HEAD /big.txt", "Content-Length", tostring(#big))
  has(g, head, "HEAD /big.txt", "ETag", tag(big))
  body_is(g, head, "HEAD /big.txt", "")

  local fresh = asks(g, site, "GET", "/big.txt", { ["If-None-Match"] = tag(big) }, { 304 })
  body_is(g, fresh, "GET /big.txt with its own tag", "")
  local stale = asks(g, site, "GET", "/big.txt", { ["If-None-Match"] = tag("old") }, { 200 })
  body_is(g, stale, "GET /big.txt with another tag", big)

  local ranges: {{string}} = {
    { "bytes=0-9", "0-9" },
    { "bytes=" .. (#big - 10) .. "-", (#big - 10) .. "-" .. (#big - 1) },
    { "bytes=-7", (#big - 7) .. "-" .. (#big - 1) },
    { "bytes=100-199", "100-199" },
  }
  for _, r in ipairs(ranges) do
    local first, last = r[2]:match("^(%d+)-(%d+)$")
    local answer = asks(g, site, "GET", "/big.txt", { Range = r[1] }, { 206 })
    has(g, answer, "Range " .. r[1], "Content-Range", "bytes " .. r[2] .. "/" .. #big)
    body_is(g, answer, "Range " .. r[1],
      big:sub(math.tointeger(tonumber(first)) + 1, math.tointeger(tonumber(last)) + 1))
  end
  local past = asks(g, site, "GET", "/big.txt", { Range = "bytes=" .. #big .. "-" }, { 416 })
  has(g, past, "Range bytes=" .. #big .. "-", "Content-Range", "bytes */" .. #big)

  local zipped = asks(g, site, "GET", "/big.txt", { ["Accept-Encoding"] = "gzip, deflate" },
    { 200 })
  if zipped ~= nil then
    has(g, zipped, "GET /big.txt accepting gzip", "Content-Encoding", "gzip")
    has(g, zipped, "GET /big.txt accepting gzip", "Content-Length", tostring(#zipped.body))
    local plain, trouble = Compress.inflate("gzip", zipped.body)
    check(g, plain == big, "GET /big.txt accepting gzip inflates to the file",
      plain == nil and trouble or #plain .. " bytes")
  end
  local identity = asks(g, site, "GET", "/big.txt", {}, { 200 })
  has(g, identity, "GET /big.txt", "Content-Encoding", nil)
  body_is(g, identity, "GET /big.txt", big)
  local small_zip = asks(g, site, "GET", "/a.txt", { ["Accept-Encoding"] = "gzip" }, { 200 })
  has(g, small_zip, "GET /a.txt accepting gzip", "Content-Encoding", nil)
  body_is(g, small_zip, "GET /a.txt accepting gzip", small)

  for _, target in ipairs({ "/../secret.txt", "/%2e%2e/secret.txt", "/sub/..%2f..%2fsecret.txt",
      "/sub/%2E%2E/%2E%2E/secret.txt" }) do
    local answer = asks(g, site, "GET", target, {}, { 403, 404 })
    if answer ~= nil then
      check(g, not answer.body:find("TOP SECRET", 1, true), "GET " .. target ..
          " gives nothing of the file outside", "its body holds the secret")
    end
  end
  asks(g, site, "GET", "/nothing.txt", {}, { 404 })
  asks(g, site, "POST", "/a.txt", { ["Content-Length"] = "0" }, { 405 })
  check(g, site.closes, "the server closes each connection a request asked to close",
    "a connection stayed open past its response")

  -- A client that sends half a request and waits must not hold up the next.
  local idle, itrouble = Net.connect(Net.tcp("127.0.0.1", site.port),
    { timeout_ns = Clock.seconds(3) })
  if idle == nil then
    fail(g, "idle connection: " .. itrouble)
  else
    local _, _ = idle:write("GET /a.txt HTTP/1.1\r\nHo")
    local started = Clock.monotonic_ns()
    local answer, trouble = request(site.port, "GET", "/a.txt")
    local took = since_ms(started)
    local code = 0
    if answer ~= nil then
      code = answer.status
      trouble = "status " .. code
    end
    check(g, code == 200 and took < 2000,
      "GET /a.txt while another client idles mid-request answered in " .. took .. " ms", trouble)
    local _, _ = idle:close()
  end
end

--- Whether the directory at `path` holds exactly `files`, by path
--- relative to it.
local function holds(path: string, files: {string: string}): boolean, string
  local found, trouble = Fs.walk(path)
  if found == nil then return false, trouble end
  local seen = 0
  for _, rel in ipairs(found) do
    local data, _ = Fs.read(path .. "/" .. rel)
    if files[rel] == nil then return false, "unexpected " .. rel end
    if data ~= files[rel] then return false, rel .. " differs" end
    seen = seen + 1
  end
  local want = 0
  for _ in pairs(files) do want = want + 1 end
  if seen ~= want then return false, seen .. " of " .. want .. " files" end
  return true, ""
end

--- Checks a pull's exit and the lines it printed, as sorted words.
local function pulls(g: Grade, args: {string}, lines: {string})
  local result = run(g, args)
  local got: {string} = {}
  for line in (result.stdout or ""):gmatch("[^\n]+") do got[#got + 1] = String.trim(line) end
  table.sort(got)
  table.sort(lines)
  local want = table.concat(lines, "; ")
  local said = table.concat(got, "; ")
  check(g, status(result) == 0 and said == want, label(g, args) .. " -> " .. want,
    "exit " .. status(result) .. ", printed '" .. said .. "'; stderr: " ..
      first_line(result.stderr or ""))
end

local function mirror_pulls(g: Grade, site: Site)
  local base = "http://127.0.0.1:" .. site.port
  local fetched, skipped: {string}, {string} = {}, {}
  for path in pairs(site.files) do
    fetched[#fetched + 1] = "fetched " .. path
    skipped[#skipped + 1] = "skipped " .. path
  end
  pulls(g, { "pull", base .. "/", "copy" }, fetched)
  local same_files, trouble = holds(g.empty .. "/copy", site.files)
  check(g, same_files, "pull into an empty directory copies every file", trouble)
  pulls(g, { "pull", base .. "/", "copy" }, skipped)
  write(g, "copy/sub/b.bin", "changed")
  local again: {string} = {}
  for _, line in ipairs(skipped) do
    again[#again + 1] = line == "skipped sub/b.bin" and "fetched sub/b.bin" or line
  end
  pulls(g, { "pull", base, "copy" }, again)
  same_files, trouble = holds(g.empty .. "/copy", site.files)
  check(g, same_files, "a pull fetches a changed file again", trouble)
  pulls(g, { "pull", base .. "/sub", "part" }, { "fetched b.bin", "fetched deep/c.txt" })
end

--- Serves a listing that lies about bad.txt's hash, and pulls from it.
local function mirror_lie(g: Grade)
  local good, bad = "good\n", "right"
  local listing = assert(Json.encode({
    { name = "bad.txt", type = "file", size = #bad, sha256 = Hash.hex_sha256("wrong") },
    { name = "good.txt", type = "file", size = #good, sha256 = Hash.hex_sha256(good) },
  }))
  local bodies: {string: string} = { ["/"] = listing, ["/bad.txt"] = bad, ["/good.txt"] = good }
  local result: Child.Result = nil
  local args: {string} = {}
  local served, trouble = Net.serve({
    listeners = { Net.tcp("127.0.0.1", 0) },
    timeout_ns = Clock.seconds(5),
    grace_ns = Clock.ms(200),
    serve = function(conn: Net.Conn)
      local got = ""
      while not got:find("\r\n\r\n", 1, true) do
        local chunk, _ = conn:read()
        if chunk == nil then return end
        got = got .. chunk
      end
      local target = got:match("^%u+ (%S+)") or ""
      local body = bodies[target]
      local head = body ~= nil and "200 OK" or "404 Not Found"
      body = body or ""
      local _, _ = conn:write("HTTP/1.1 " .. head .. "\r\nContent-Length: " .. #body ..
          "\r\nConnection: close\r\n\r\n" .. body)
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      args = { "pull", "http://127.0.0.1:" .. addresses[1].port .. "/", "lied" }
      result = run(g, args)
      server:stop()
    end,
  })
  if not served or result == nil then
    fail(g, "the lying server did not serve: " .. trouble)
    return
  end
  local err = result.stderr or ""
  check(g, status(result) ~= 0 and err:find("bad.txt", 1, true) ~= nil,
    label(g, args) .. " from a listing with a wrong hash fails naming bad.txt",
    "exit " .. status(result) .. ", stderr: " .. first_line(err))
  local left, _ = Fs.walk(g.empty .. "/lied")
  local stray: {string} = {}
  for _, rel in ipairs(left or {}) do
    if rel ~= "good.txt" then stray[#stray + 1] = "lied/" .. rel end
  end
  check(g, #stray == 0, "a file failing its hash leaves nothing behind",
    table.concat(stray, ", "))
end

--- Writes the site's files as an archive at `name` under the empty
--- directory, its format chosen by the name; with `dirs`, with an
--- entry for each directory too.
local function packed(g: Grade, site: Site, name: string, dirs: boolean): boolean
  local writer, trouble = Archive.create(g.empty .. "/" .. name)
  if writer == nil then
    fail(g, "could not write " .. name .. ": " .. trouble)
    return false
  end
  local paths: {string} = {}
  for path in pairs(site.files) do paths[#paths + 1] = path end
  table.sort(paths)
  if dirs then
    for _, dir in ipairs({ "sub", "sub/deep" }) do
      local added, why = writer:add_dir(dir)
      if not added then trouble = why end
    end
  end
  for _, path in ipairs(paths) do
    local added, why = writer:add_file(path, site.files[path])
    if not added then trouble = why end
  end
  local closed, why = writer:close()
  if not closed or trouble ~= "" then
    fail(g, "could not write " .. name .. ": " .. (closed and trouble or why))
    return false
  end
  return true
end

--- Serves the site from archives: each answers as the directory does,
--- and pulls whole; an archive that would reach outside is refused.
local function mirror_archives(g: Grade, site: Site)
  for _, case in ipairs({ { "site.tar.gz", "dirs" }, { "site.zip", "" }, { "site.tar", "dirs" } }) do
    local name = case[1]
    if packed(g, site, name, case[2] == "dirs") then
      local server, port = serves(g, { "serve", name, "0" })
      if server ~= nil then
        local served: Site = { port = port, files = site.files, closes = true }
        mirror_listings(g, served)
        local b = asks(g, served, "GET", "/sub/b.bin", {}, { 200 })
        body_is(g, b, name .. ": GET /sub/b.bin", site.files["sub/b.bin"])
        has(g, b, name .. ": GET /sub/b.bin", "ETag", tag(site.files["sub/b.bin"]))
        local big = site.files["big.txt"]
        local part = asks(g, served, "GET", "/big.txt", { Range = "bytes=100-199" }, { 206 })
        body_is(g, part, name .. ": Range bytes=100-199", big:sub(101, 200))
        asks(g, served, "GET", "/nothing.txt", {}, { 404 })
        local escape = asks(g, served, "GET", "/%2e%2e/secret.txt", {}, { 403, 404 })
        if escape ~= nil then
          check(g, not escape.body:find("TOP SECRET", 1, true), name ..
              ": GET /%2e%2e/secret.txt gives nothing of the file outside",
            "its body holds the secret")
        end
        local dest = "from-" .. name:gsub("%.", "-")
        local fetched: {string} = {}
        for path in pairs(site.files) do fetched[#fetched + 1] = "fetched " .. path end
        pulls(g, { "pull", "http://127.0.0.1:" .. port .. "/", dest }, fetched)
        local same_files, trouble = holds(g.empty .. "/" .. dest, site.files)
        check(g, same_files, "pull from " .. name .. " copies every file", trouble)
        stops(g, server)
      end
    end
  end
  write(g, "evil.tar", ustar("ok.txt", "fine\n") .. ustar("../evil.txt", "escaped\n") ..
      string.rep("\0", 1024))
  write(g, "rooted.tar", ustar("/evil.txt", "escaped\n") .. string.rep("\0", 1024))
  write(g, "site.rar", "not an archive")
  for _, name in ipairs({ "evil.tar", "rooted.tar", "site.rar", "missing.zip" }) do
    refuses(g, { "serve", name, "0" })
  end
end

local function mirror(g: Grade)
  local site: Site = { closes = true }
  mirror_files(site)
  for path, data in pairs(site.files) do write(g, "site/" .. path, data) end
  write(g, "secret.txt", "TOP SECRET\n")
  local server, port = serves(g, { "serve", "site", "0" })
  if server == nil then
    return
  end
  site.port = port
  mirror_requests(g, site)
  mirror_listings(g, site)
  mirror_pulls(g, site)
  stops(g, server)
  refuses(g, { "pull", "http://127.0.0.1:" .. site.port .. "/", "gone" })
  mirror_archives(g, site)
  mirror_lie(g)
  help(g, { "serve", "pull" })
end

-- relay

--- The grader's own target, an echo server: each connection's bytes
--- come back as they arrive, and once the client ends what it sends,
--- `<eof>` follows and the connection closes. A connection opening
--- with `SPLIT` is answered `bye` and ended from this side at once, and
--- what the client sends after that is kept in `split`.
local record Target
  split: {string}
end

local function echo(target: Target, conn: Net.Conn)
  local chunk, ended = conn:read()
  if chunk ~= nil and chunk:sub(1, 5) == "SPLIT" then
    local _, _ = conn:write("bye")
    local _, _ = conn:shutdown("write")
    local parts: {string} = {}
    while true do
      local more, _ = conn:read()
      if more == nil then break end
      parts[#parts + 1] = more
    end
    target.split[#target.split + 1] = table.concat(parts)
    return
  end
  while chunk ~= nil do
    local sent, _ = conn:write(chunk)
    if not sent then return end
    chunk, ended = conn:read()
  end
  if ended == "" then
    local _, _ = conn:write("<eof>")
  end
end

--- A connection to the relay at `port`, whose every wait lasts 5 s at
--- most.
local function dial(port: integer): Net.Conn | nil, string
  return Net.connect(Net.tcp("127.0.0.1", port), { timeout_ns = Clock.seconds(5) })
end

--- Reads `conn` until `n` bytes have come or it ends; answers what
--- came, and why it ended early: "" at the end of what the peer sent.
local function read_n(conn: Net.Conn, n: integer): string, string
  local parts: {string} = {}
  local got = 0
  while got < n do
    local chunk, trouble = conn:read()
    if chunk == nil then return table.concat(parts), trouble end
    parts[#parts + 1] = chunk
    got = got + #chunk
  end
  return table.concat(parts), "ok"
end

--- Reads `conn` to the end of what the peer sends; answers what came,
--- and "" once it ended there, or why not.
local function read_all(conn: Net.Conn): string, string
  return read_n(conn, math.maxinteger)
end

local function relay_echo(g: Grade, port: integer)
  local conn, trouble = dial(port)
  if conn == nil then
    fail(g, "connect to the relay: " .. trouble)
    return
  end
  local _, _ = conn:write("hello")
  local got, why = read_n(conn, 5)
  check(g, got == "hello", "bytes sent through the relay come back from the echo target",
    "got '" .. got .. "' (" .. why .. ")")
  local _, _ = conn:write("abc")
  local _, _ = conn:shutdown("write")
  local rest, ended = read_all(conn)
  check(g, rest == "abc<eof>" and ended == "",
    "a client's half-close reaches the target, whose answer after it comes back",
    "got '" .. rest .. "' (" .. (ended == "" and "ended" or ended) .. ")")
  local _, _ = conn:close()
end

local function relay_split(g: Grade, target: Target, port: integer)
  local conn, trouble = dial(port)
  if conn == nil then
    fail(g, "connect to the relay: " .. trouble)
    return
  end
  local _, _ = conn:write("SPLIT")
  local got, ended = read_all(conn)
  check(g, got == "bye" and ended == "",
    "a target that speaks first and half-closes: its bytes and its end reach the client",
    "got '" .. got .. "' (" .. (ended == "" and "ended" or ended) .. ")")
  local before = #target.split
  local _, _ = conn:write("after")
  local _, _ = conn:shutdown("write")
  local deadline = Clock.monotonic_ns() + Clock.seconds(2)
  while #target.split == before and Clock.monotonic_ns() < deadline do
    local _, _ = Poll.delay(Clock.ms(20))
  end
  local kept = target.split[before + 1]
  check(g, kept == "after", "what a client sends after its target half-closed still reaches it",
    "the target got '" .. shown(kept) .. "'")
  local _, _ = conn:close()
end

--- A client that sends without reading holds up no other connection.
local function relay_stalled(g: Grade, port: integer)
  local stalled, trouble = dial(port)
  if stalled == nil then
    fail(g, "connect to the relay: " .. trouble)
    return
  end
  local block = string.rep("z", 64 * 1024)
  local writer = Poll.spawn(function()
    for _ = 1, 64 do
      local sent, _ = stalled:write(block)
      if not sent then return end
    end
  end)
  local _, _ = Poll.delay(Clock.ms(300))
  local started = Clock.monotonic_ns()
  local other, otrouble = dial(port)
  local got, why = "", otrouble
  if other ~= nil then
    other:set_timeout(Clock.seconds(2))
    local _, _ = other:write("ping")
    got, why = read_n(other, 4)
    local _, _ = other:close()
  end
  local took = since_ms(started)
  check(g, got == "ping" and took < 2000,
    "while a client sends without reading, another is answered in " .. took .. " ms",
    "got '" .. got .. "' (" .. why .. ")")
  writer:kill()
  local _, _ = stalled:close()
end

--- Megabytes sent while their echo is read arrive whole and in order.
local function relay_large(g: Grade, port: integer)
  local conn, trouble = dial(port)
  if conn == nil then
    fail(g, "connect to the relay: " .. trouble)
    return
  end
  local unit: {string} = {}
  for i = 0, 65535 do
    unit[#unit + 1] = string.char((i * 7919 + i // 251) % 256)
  end
  local block = table.concat(unit)
  local blocks: {string} = {}
  for k = 1, 48 do
    blocks[#blocks + 1] = string.format("%08d", k) .. block:sub(9)
  end
  local data = table.concat(blocks)
  local writer = Poll.spawn(function()
    local _, _ = conn:write(data)
    local _, _ = conn:shutdown("write")
  end)
  local got, ended = read_all(conn)
  writer:kill()
  local _, _ = conn:close()
  check(g, got == data .. "<eof>" and ended == "", "3 MiB written while its echo is read " ..
      "comes back whole", #got .. " bytes, sha256 " .. Hash.hex_sha256(got) ..
      (ended == "" and "" or " (" .. ended .. ")"))
end

--- A connection with nothing moving for --idle is closed; one with
--- something moving is not; SIGTERM ends the relay with its count.
local function relay_idle(g: Grade, target_port: integer)
  local server, port = serves(g, { "0", "127.0.0.1:" .. target_port, "--idle", "0.5" },
    "check-relay-idle.out")
  if server == nil then return end
  local quiet, trouble = dial(port)
  if quiet == nil then
    fail(g, "connect to the relay: " .. trouble)
  else
    local _, _ = quiet:write("x")
    local got, _ = read_n(quiet, 1)
    local started = Clock.monotonic_ns()
    local more, ended = quiet:read()
    local took = since_ms(started)
    check(g, got == "x" and more == nil and ended == "" and took >= 350 and took < 2000,
      "--idle 0.5 closes a connection with nothing moving, after " .. took .. " ms",
      "got '" .. got .. "', then " .. (more ~= nil and "'" .. more .. "'" or ended))
    local _, _ = quiet:close()
  end
  local busy, btrouble = dial(port)
  if busy == nil then
    fail(g, "connect to the relay: " .. btrouble)
  else
    local echoed = ""
    for _ = 1, 8 do
      local _, _ = busy:write("a")
      local got, _ = read_n(busy, 1)
      echoed = echoed .. got
      local _, _ = Poll.delay(Clock.ms(150))
    end
    local _, _ = busy:shutdown("write")
    local rest, ended = read_all(busy)
    check(g, echoed == "aaaaaaaa" and rest == "<eof>" and ended == "",
      "--idle 0.5 keeps a connection with a byte moving every 150 ms for 1.2 s",
      "echoed '" .. echoed .. "', then '" .. rest .. "'")
    local _, _ = busy:close()
  end
  stops(g, server, "relay --idle 0.5")
  local said, _ = Fs.read(g.dir .. "/check-relay-idle.out")
  local want = "relayed 2 connections, 9 bytes up, 14 bytes down"
  check(g, said ~= nil and said:find(want .. "\n", 1, true) ~= nil,
    "on SIGTERM it printed '" .. want .. "'", "printed '" .. trimmed(said or "") .. "'")
end

--- A target that refuses: the client's connection is closed, and the
--- relay goes on.
local function relay_refused(g: Grade)
  local listener, trouble = Net.listen(Net.tcp("127.0.0.1", 0))
  if listener == nil then
    fail(g, "could not find a free port: " .. trouble)
    return
  end
  local dead = listener.address.port
  local _, _ = listener:close()
  local server, port = serves(g, { "0", "127.0.0.1:" .. dead }, "check-relay-refused.out")
  if server == nil then return end
  for i = 1, 2 do
    local conn, ctrouble = dial(port)
    if conn == nil then
      fail(g, "connect to the relay: " .. ctrouble)
    else
      local started = Clock.monotonic_ns()
      local got, ended = read_all(conn)
      local took = since_ms(started)
      check(g, got == "" and took < 2000, "connection " .. i .. " to a refusing target is " ..
          "closed in " .. took .. " ms", "got '" .. got .. "' (" .. ended .. ")")
      local _, _ = conn:close()
    end
  end
  stops(g, server, "relay to a refusing target")
  local said, _ = Fs.read(g.dir .. "/check-relay-refused.out")
  -- stdout and stderr share the log: a line that is neither stdout's
  -- `listening` nor its `relayed` is stderr's.
  local lines = 0
  for line in (said or ""):gmatch("[^\n]+") do
    if not line:find("^listening on ") and not line:find("^relayed ") then lines = lines + 1 end
  end
  check(g, lines >= 1, "a refused target is a line on stderr",
    "printed '" .. trimmed(said or "") .. "'")
end

local function relay(g: Grade)
  refuses(g, { "0" })
  refuses(g, { "0", "nowhere" })
  refuses(g, { "0", "127.0.0.1:99999" })
  refuses(g, { "0", "127.0.0.1:9", "--idle", "0" })
  refuses(g, { "0", "127.0.0.1:9", "--idle", "soon" })
  local target: Target = { split = {} }
  local served, trouble = Net.serve({
    listeners = { Net.tcp("127.0.0.1", 0) },
    timeout_ns = Clock.seconds(10),
    grace_ns = Clock.ms(200),
    serve = function(conn: Net.Conn)
      echo(target, conn)
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local target_port = addresses[1].port
      local main, port = serves(g, { "0", "127.0.0.1:" .. target_port }, "check-relay.out")
      if main ~= nil then
        relay_echo(g, port)
        relay_split(g, target, port)
        relay_stalled(g, port)
        relay_large(g, port)
        local open, otrouble = dial(port)
        if open == nil then
          fail(g, "connect to the relay: " .. otrouble)
          stops(g, main, "relay")
        else
          local _, _ = open:write("hold")
          local held, _ = read_n(open, 4)
          stops(g, main, "relay")
          local rest, ended = read_all(open)
          check(g, held == "hold" and ended == "",
            "a connection open at SIGTERM is closed with the relay",
            "got '" .. held .. rest .. "' (" .. ended .. ")")
          local _, _ = open:close()
        end
      end
      relay_idle(g, target_port)
      relay_refused(g)
      server:stop()
    end,
  })
  if not served then
    fail(g, "the grader's echo target did not serve: " .. trouble)
  end
  help(g, { "--idle" })
end

-- tasks

--- A task the grader knows: its checks, run once the executable is
--- copied into the empty directory, and how they run it.
local record Task
  checks: function(Grade)
  --- How long one run of the executable may take, in seconds.
  timeout: integer
  null_stdin: boolean
  own_group: boolean
  --- Files of the project's a solver's own runs may leave behind, which
  --- would answer for the executable if left there.
  stale: {string}
  --- Whether the task names a library API, which a hidden test,
  --- testdata/<task>_api_test.tl, checks.
  api: boolean
end

local TASKS <const>: {string: Task} = {
  notes = { checks = notes, timeout = 10, null_stdin = false, own_group = true,
    stale = { "notes.db" }, api = true },
  pack = { checks = pack, timeout = 10, null_stdin = false, own_group = true, stale = {},
    api = false },
  ledger = { checks = ledger, timeout = 10, null_stdin = false, own_group = true, stale = {},
    api = true },
  kv = { checks = kv, timeout = 10, null_stdin = false, own_group = true, stale = {}, api = true },
  -- jobs's checks look for what a job left after its run, so it must
  -- outlive the run; both drive processes and sockets that wait out
  -- timeouts of their own, so a run may take longer.
  jobs = { checks = jobs, timeout = 15, null_stdin = true, own_group = false, stale = {},
    api = true },
  mirror = { checks = mirror, timeout = 15, null_stdin = true, own_group = false, stale = {},
    api = true },
  relay = { checks = relay, timeout = 10, null_stdin = true, own_group = true, stale = {},
    api = true },
}

--- Grades the arena at `dir` for the task `name`, with the hidden API
--- tests in `testdata`, printing a line per check and PASS or FAIL
--- last; 0 when everything passed.
function Grader.grade(name: string, dir: string, testdata: string): integer
  local task = assert(TASKS[name], name)
  local project = dir .. "/project"
  local cosmic = dir .. "/bin/cosmic"
  local is_project, project_trouble = Fs.is_dir(project)
  if not is_project then
    say("FAIL no project at " .. project ..
        (project_trouble ~= "" and ": " .. project_trouble or ""))
    say("FAIL")
    return 1
  end
  -- TODO: ask the arena's cosmic where it built the project (`cosmic db`
  -- names its databases there) once #2864's step 3 moves a project's
  -- build directory out of it: here and below the grader spells it as
  -- the project's o/. The checkout's bin/cosmic cannot answer it, since
  -- the arena holds a bare binary and no checkout.
  local g: Grade = { dir = dir, name = name, exe = project .. "/o/bin/" .. name,
    empty = dir .. "/empty", steps = 0, failed = false,
    timeout_ns = Clock.seconds(task.timeout), null_stdin = task.null_stdin, own_group = task.own_group }
  local set_aside = put_back_journal(g, project)
  local kept, why = Grader.journal(project .. "/JOURNAL.md")
  check(g, kept, "JOURNAL.md kept, as TASK.md's journal contract asks", why)
  for _, file in ipairs(task.stale) do
    local _, _ = Fs.remove(project .. "/" .. file)
  end
  local db = project .. "/o/build.db"
  step(g, "evidence reset " .. db, function(out: integer): boolean
    local reset, trouble = Grader.reset_evidence(db)
    if not reset then
      local _, _ = Fs.put(out, trouble .. "\n")
    end
    return reset
  end)
  command_step(g, { cosmic, "test" }, project)
  step(g, "evidence check " .. db, function(out: integer): boolean
    local evidence, trouble = Grader.evidence(db)
    if evidence == nil then
      local _, _ = Fs.put(out, trouble .. "\n")
      return false
    end
    local _, _ = Fs.put(out, "evidence: " .. evidence.tests .. " tests, " ..
        evidence.examples .. " examples\n")
    return evidence.tests > 0 and evidence.examples > 0
  end)
  fix_check(g, cosmic, project, set_aside)
  if task.api then
    hidden_api(g, cosmic, project, testdata .. "/" .. name .. "_api_test.tl")
  end
  local passed = command_step(g, { cosmic, "build" }, project)
  -- Only a build that passed and names o/bin/<name> among what it wrote
  -- vouches for the file: after a failed build, or one that no longer
  -- builds it (cmd/<name> renamed away), an o/bin/<name> still there
  -- is an earlier build's. It stays in place -- it is the solver's
  -- deliverable, not the grader's to delete -- but it is not run.
  -- A build log that cannot be read names no binary.
  local read, _ = Fs.read(g.dir .. "/check-" .. g.steps .. ".out")
  if not passed then
    say("skip o/bin/" .. name .. ": cosmic build failed; not running an earlier build's binary")
  elseif not Grader.built(read or "", name) or not is_executable(g.exe) then
    fail(g, "cosmic build did not produce o/bin/" .. name .. "; a binary is cmd/<name>/main.tl")
  else
    local bytes, trouble = Fs.read(g.exe)
    local copied = bytes ~= nil
    if copied then copied, trouble = Fs.remove_tree(g.empty) end
    if copied then copied, trouble = Fs.mkdirs(g.empty) end
    if copied then copied, trouble = Fs.write(g.empty .. "/" .. name, assert(bytes), 0x1ed) end
    if not copied then
      fail(g, "could not copy " .. g.exe .. " into " .. g.empty .. ": " .. trouble)
    else
      task.checks(g)
    end
  end
  if g.failed then
    say("FAIL")
    return 1
  end
  say("PASS")
  return 0
end

function Grader.main(argv: {integer: string}): integer
  local name, dir = argv[1], argv[2]
  if name == nil or TASKS[name] == nil or dir == nil or argv[3] ~= nil then
    local names: {string} = {}
    for each in pairs(TASKS) do names[#names + 1] = each end
    table.sort(names)
    local _, _ = Fs.put(Fs.stderr, "usage: eval/check/<task> <dir>, where <task> is one of " ..
        table.concat(names, ", ") .. "\n")
    return 2
  end
  local script, trouble = Fs.absolute(argv[0])
  local here = script ~= nil and script:match("^(.*)/[^/]+%.tl$")
  if here == nil then
    local _, _ = Fs.put(Fs.stderr, "grade: " .. (script == nil and trouble or
      argv[0] .. ": expected to run as .../eval/check/grade.tl") .. "\n")
    return 2
  end
  -- The steps run in other directories, and name the arena's files.
  local absolute, _ = Fs.absolute(dir)
  return Grader.grade(name, absolute or dir, here .. "/testdata")
end

return Grader
