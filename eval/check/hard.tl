--- Grades the jobs and mirror tasks in an arena, as tasks.tl grades
--- pack, ledger and kv: the project's tests and format check pass, with
--- recorded tests and examples behind them, cosmic builds the task's
--- executable, and that executable, copied alone into an empty
--- directory, does what the task asks. These two drive processes and
--- sockets, so their checks time what the executable does as well as
--- reading what it answers.
---
---     cosmic --standalone eval/check/hard.tl <task> <dir>
---
--- [`eval/check/jobs`] and `mirror` run this on the bootstrap cosmic:
--- it requires `cosmic.*` modules only. The arena's own `bin/cosmic`
--- does the testing and building.
local Child = require("cosmic.child")
local Compress = require("cosmic.compress")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Net = require("cosmic.net")
local Sqlite = require("cosmic.sqlite")
local String = require("cosmic.string")
local Time = require("cosmic.time")

local record Hard
end

local function say(line: string)
  local _, _ = Fs.put(Fs.stdout, "check: " .. line .. "\n")
end

local function status(result: Child.Result): integer
  if result.code ~= nil then
    return result.code
  end
  return 128 + (result.signal or 0)
end

--- Whether a failure's stderr is cosmic's own rather than the tool's.
local function failed_in_cosmic(err: string): boolean
  return err:find("^cosmic") ~= nil or err:find("\ncosmic") ~= nil
end

local function built(output: string, name: string): boolean
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

local function trimmed(text: string): string
  return (text:gsub("\n+$", ""))
end

local function reset_evidence(path: string): boolean, string
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
  local ok, etrouble = db:exec("delete from runs")
  local closed, close_trouble = db:close()
  if not ok then return false, etrouble end
  if not closed then return false, close_trouble end
  return true, ""
end

local function evidence(path: string): integer, integer, string
  local present, trouble = Fs.exists(path)
  if not present then
    return 0, 0, present == nil and trouble or path .. ": no build database"
  end
  local db, otrouble = Sqlite.open(path)
  if db == nil then
    return 0, 0, otrouble
  end
  local rows, rtrouble = Sqlite.text_rows(db, [[
    select i.kind, i.origin, count(*)
    from runs r join inputs i on i.path = r.path
    where r.passed = 1
    group by i.kind, i.origin
  ]], {})
  local _, _ = db:close()
  if rows == nil then
    return 0, 0, rtrouble
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
  return tests, examples, ""
end

local record Grade
  dir: string
  name: string
  exe: string
  empty: string
  steps: integer
  failed: boolean
end

local function fail(g: Grade, line: string)
  say("FAIL " .. line)
  g.failed = true
end

local function ok(line: string)
  say("ok   " .. line)
end

--- Passes `line` when `holds`, else fails it with `why` after it.
local function check(g: Grade, holds: boolean, line: string, why?: string)
  if holds then
    ok(line)
  else
    fail(g, line .. (why ~= nil and why ~= "" and ": " .. why or ""))
  end
end

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
      timeout_ns = Time.seconds(120) })
    if result == nil then
      local _, _ = Fs.put(out, trouble .. "\n")
      return false
    end
    return status(result) == 0
  end)
end

--- Runs `cosmic fix --check` with the journal set aside: it is prose
--- the task asks for, not a source the task asks to have formatted,
--- and `fix --check` holds a project's Markdown to its link rules.
local function fix_check(g: Grade, cosmic: string, project: string)
  local journal = project .. "/JOURNAL.md"
  local aside = g.dir .. "/JOURNAL.md.aside"
  local moved, _ = Fs.rename(journal, aside)
  command_step(g, { cosmic, "fix", "--check" }, project)
  if moved then
    local back, trouble = Fs.rename(aside, journal)
    if not back then
      say("FAIL could not put JOURNAL.md back from " .. aside .. ": " .. trouble)
      g.failed = true
    end
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
--- empty environment by default), answering its result. Its process
--- group is this one's, so what it leaves behind outlives it as it
--- would outlive a shell's command, for a check to find.
local function run(g: Grade, args: {string}, env?: {string: string}): Child.Result
  local result, trouble = Child.run(argv_of(g, args), { cwd = g.empty, env = env or {},
    stdout = "capture", stderr = "capture", stdin = "null", process_group = false,
    timeout_ns = Time.seconds(15) })
  if result == nil then
    return { code = 127, ok = false, timed_out = false, stdout = "", stderr = trouble,
      captured = {}, truncated = false }
  end
  return result
end

local function label(g: Grade, args: {string}): string
  return "./" .. g.name .. " " .. table.concat(args, " ")
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
  elseif failed_in_cosmic(err) then
    fail(g, label(g, args) .. " failed in cosmic, not in " .. g.name .. ": " .. first_line(err))
  else
    ok(label(g, args) .. " -> exit " .. status(result) .. ", stderr: " .. first_line(err))
  end
  return err
end

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

local function exists(path: string): boolean
  local present, _ = Fs.exists(path)
  return present == true
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
  return (Time.monotonic_ns() - started) // Time.ms(1)
end

local function sleep_until(started: integer, ms: integer)
  local left = started + Time.ms(ms) - Time.monotonic_ns()
  if left > 0 then
    local _, _ = Time.sleep_ns(left)
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

local function jobs_main(g: Grade, w: string)
  local started = Time.monotonic_ns()
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
  local result = run(g, args, { LEAK = "from jobs" })
  local took = since_ms(started)
  check(g, status(result) ~= 0, label(g, args) .. " exits non-zero when a job failed",
    "exit 0")
  check(g, took < 4000, label(g, args) .. " finished in " .. took .. " ms",
    "a 0.5 s timeout should end it within a few seconds")
  local report, trouble = jobs_report(result)
  if report == nil then
    fail(g, label(g, args) .. ": " .. trouble .. "; stderr: " .. first_line(result.stderr or ""))
    return
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
end

local function jobs_interrupt(g: Grade, w: string)
  jobfile(g, "w/term.json", {
    long = { cmd = sh("(/bin/sleep 1.5; : > " .. w .. "/term.late) & /bin/sleep 30") },
    quick = { cmd = sh(": > " .. w .. "/quick.done") },
    next = { cmd = sh(": > " .. w .. "/next.ran"), needs = { "long" } },
  })
  local args = { "run", "w/term.json" }
  local handle, trouble = Child.start(argv_of(g, args), { cwd = g.empty, env = {},
    stdout = "capture", stderr = "capture", stdin = "null", process_group = false })
  if handle == nil then
    fail(g, label(g, args) .. " did not start: " .. trouble)
    return
  end
  local deadline = Time.monotonic_ns() + Time.seconds(3)
  while not exists(w .. "/quick.done") and Time.monotonic_ns() < deadline do
    local _, _ = Time.sleep_ns(Time.ms(20))
  end
  local _, _ = Time.sleep_ns(Time.ms(300))
  local signalled = Time.monotonic_ns()
  local _, _ = handle:stop()
  local result, _ = handle:wait(Time.seconds(5))
  local took = since_ms(signalled)
  local _, _ = handle:close()
  if result == nil or result.timed_out then
    fail(g, label(g, args) .. " was still running 5 s after SIGTERM")
    return
  end
  check(g, status(result) ~= 0 and took < 3000, label(g, args) .. " ended on SIGTERM in " ..
    took .. " ms, exit " .. status(result), "wanted a non-zero exit within 3 s")
  local report, rtrouble = jobs_report(result)
  if report == nil then
    fail(g, "report after SIGTERM: " .. rtrouble)
    return
  end
  each_job(g, report, "status", { long = "interrupted", quick = "ok", next = "skipped" })
  check(g, not exists(w .. "/next.ran"), "no job starts after SIGTERM")
end

local function jobs_refusals(g: Grade, w: string)
  jobfile(g, "w/cycle.json", {
    alpha = { cmd = sh("exit 0"), needs = { "beta" } },
    beta = { cmd = sh("exit 0"), needs = { "gamma" } },
    gamma = { cmd = sh("exit 0"), needs = { "alpha" } },
    free = { cmd = sh(": > " .. w .. "/free.ran") },
  })
  local err = refuses(g, { "run", "w/cycle.json" })
  check(g, err:find("alpha", 1, true) ~= nil or err:find("beta", 1, true) ~= nil or
    err:find("gamma", 1, true) ~= nil, "the cycle's refusal names a job in it", trimmed(err))
  check(g, not exists(w .. "/free.ran"), "nothing runs from a jobfile with a cycle")
  jobfile(g, "w/unknown.json", {
    a = { cmd = sh("exit 0"), needs = { "ghost" } },
    free = { cmd = sh(": > " .. w .. "/free.ran") },
  })
  err = refuses(g, { "run", "w/unknown.json" })
  check(g, err:find("ghost", 1, true) ~= nil, "an unknown need's refusal names it", trimmed(err))
  check(g, not exists(w .. "/free.ran"), "nothing runs from a jobfile with an unknown need")
  write(g, "w/bad.json", "{\"a\": {\"cmd\": \"not an array\"}}")
  refuses(g, { "run", "w/bad.json" })
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
  local started = Time.monotonic_ns()
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
  local started = Time.monotonic_ns()
  jobs_main(g, w)
  jobs_interrupt(g, w)
  jobs_refusals(g, w)
  -- The timed-out job's grandchild writes w/late 2 s after it started,
  -- and the interrupted one's w/term.late 1.5 s after it did, unless
  -- they were killed with their jobs.
  sleep_until(started, 2600)
  check(g, not exists(w .. "/late"), "a timed-out job's own children are killed with it")
  check(g, not exists(w .. "/term.late"), "an interrupted job's own children are killed with it")
  jobs_parallel(g)
  help(g, { "run", "--parallel", "--logs" })
end

-- mirror

--- One response as the grader read it off the wire.
local record Answer
  status: integer
  headers: {string: string}
  body: string
  closed: boolean
end

--- Reads one response to a request sent with `Connection: close`: up to
--- its Content-Length (none for a HEAD or a 304), then whatever follows
--- before the server closes, so a body after a HEAD's headers shows.
local function receive(conn: Net.Conn, head_only: boolean): Answer | nil, string
  local got = ""
  local answer: Answer = nil
  local body_length: integer = nil
  while true do
    if answer == nil then
      local head, rest = got:match("^(.-)\r\n\r\n(.*)$")
      if head ~= nil then
        local code = math.tointeger(tonumber(head:match("^HTTP/1%.[01] (%d%d%d)")))
        if code == nil then return nil, "no status line: " .. first_line(head) end
        local headers: {string: string} = {}
        for name, value in head:gmatch("\r\n([^:\r\n]+):[ \t]*([^\r\n]*)") do
          headers[name:lower()] = String.trim(value)
        end
        answer = { status = code, headers = headers, body = rest, closed = false }
        if head_only or code == 304 then
          body_length = 0
        else
          body_length = math.tointeger(tonumber(headers["content-length"] or ""))
        end
      end
    end
    if answer ~= nil and body_length ~= nil and #answer.body >= body_length then
      break
    end
    local chunk, trouble = conn:read()
    if chunk == nil then
      if trouble ~= "" or answer == nil then
        return nil, trouble ~= "" and trouble or "closed before a response"
      end
      answer.closed = true
      return answer, ""
    end
    if answer == nil then got = got .. chunk else answer.body = answer.body .. chunk end
  end
  conn:set_timeout(Time.ms(300))
  while true do
    local chunk, _ = conn:read()
    if chunk == nil then break end
    answer.body = answer.body .. chunk
  end
  local again, trouble = conn:read()
  answer.closed = again == nil and trouble == ""
  return answer, ""
end

--- One request to the server with `Connection: close`, and its answer.
local function request(port: integer, method: string, target: string,
  headers?: {string: string}): Answer | nil, string
  local conn, trouble = Net.connect(Net.tcp("127.0.0.1", port), { timeout_ns = Time.seconds(3) })
  if conn == nil then return nil, trouble end
  local lines = { method .. " " .. target .. " HTTP/1.1", "Host: 127.0.0.1",
    "Connection: close" }
  local names: {string} = {}
  for name in pairs(headers or {}) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do lines[#lines + 1] = name .. ": " .. headers[name] end
  local sent, strouble = conn:write(table.concat(lines, "\r\n") .. "\r\n\r\n")
  if not sent then
    local _, _ = conn:close()
    return nil, strouble
  end
  local answer, rtrouble = receive(conn, method == "HEAD")
  local _, _ = conn:close()
  if answer == nil then return nil, rtrouble end
  return answer, ""
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
    { timeout_ns = Time.seconds(3) })
  if idle == nil then
    fail(g, "idle connection: " .. itrouble)
  else
    local _, _ = idle:write("GET /a.txt HTTP/1.1\r\nHo")
    local started = Time.monotonic_ns()
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
    timeout_ns = Time.seconds(5),
    grace_ns = Time.ms(200),
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

local function mirror(g: Grade)
  local site: Site = { closes = true }
  mirror_files(site)
  for path, data in pairs(site.files) do write(g, "site/" .. path, data) end
  write(g, "secret.txt", "TOP SECRET\n")
  local out_path = g.dir .. "/check-serve.out"
  local out = assert(Fs.open_write(out_path))
  local server, trouble = Child.start(argv_of(g, { "serve", "site", "0" }), { cwd = g.empty,
    env = {}, stdout = out, stderr = out, stdin = "null" })
  local _, _ = Fs.close(out)
  if server == nil then
    fail(g, "mirror serve site 0 did not start: " .. trouble)
    return
  end
  local deadline = Time.monotonic_ns() + Time.seconds(5)
  while Time.monotonic_ns() < deadline do
    local text, _ = Fs.read(out_path)
    local found = text ~= nil and text:match("listening on 127%.0%.0%.1:(%d+)\n")
    if found then
      site.port = math.tointeger(tonumber(found))
      break
    end
    local _, _ = Time.sleep_ns(Time.ms(50))
  end
  if site.port == nil then
    local text, _ = Fs.read(out_path)
    fail(g, "mirror serve site 0 printed no 'listening on 127.0.0.1:<port>' line in 5s: " ..
      first_line(text or ""))
    local _, _ = server:close()
    return
  end
  ok("mirror serve site 0 -> listening on 127.0.0.1:" .. site.port)
  mirror_requests(g, site)
  mirror_listings(g, site)
  mirror_pulls(g, site)

  local stopped, _ = server:stop()
  local result, _ = server:wait(Time.seconds(3))
  if not stopped or result == nil or result.timed_out then
    fail(g, "mirror serve did not exit within 3s of SIGTERM")
  elseif status(result) ~= 0 then
    fail(g, "mirror serve exited " .. status(result) .. " on SIGTERM, not 0")
  else
    ok("mirror serve exits 0 on SIGTERM")
  end
  local _, _ = server:close()
  refuses(g, { "pull", "http://127.0.0.1:" .. site.port .. "/", "gone" })
  mirror_lie(g)
  help(g, { "serve", "pull" })
end

local TASKS <const>: {string: function(Grade)} = { jobs = jobs, mirror = mirror }

local function grade(name: string, dir: string): integer
  local project = dir .. "/project"
  local cosmic = dir .. "/bin/cosmic"
  local is_project, project_trouble = Fs.is_dir(project)
  if not is_project then
    say("FAIL no project at " .. project ..
      (project_trouble ~= "" and ": " .. project_trouble or ""))
    say("FAIL")
    return 1
  end
  local g: Grade = { dir = dir, name = name, exe = project .. "/o/bin/" .. name,
    empty = dir .. "/empty", steps = 0, failed = false }
  local db = project .. "/o/build.db"
  step(g, "evidence reset " .. db, function(out: integer): boolean
    local reset, trouble = reset_evidence(db)
    if not reset then
      local _, _ = Fs.put(out, trouble .. "\n")
    end
    return reset
  end)
  command_step(g, { cosmic, "test" }, project)
  step(g, "evidence check " .. db, function(out: integer): boolean
    local tests, examples, trouble = evidence(db)
    local _, _ = Fs.put(out, "evidence: " .. tests .. " tests, " .. examples .. " examples " ..
      trouble .. "\n")
    return tests > 0 and examples > 0
  end)
  fix_check(g, cosmic, project)
  local passed = command_step(g, { cosmic, "build" }, project)
  local read, _ = Fs.read(g.dir .. "/check-" .. g.steps .. ".out")
  local st, _ = Fs.stat(g.exe)
  if not passed then
    say("skip o/bin/" .. name .. ": cosmic build failed; not running an earlier build's binary")
  elseif not built(read or "", name) or st == nil or st.kind ~= "file" then
    fail(g, "cosmic build did not produce o/bin/" .. name)
  else
    local bytes, trouble = Fs.read(g.exe)
    local copied = bytes ~= nil
    if copied then copied, trouble = Fs.remove_tree(g.empty) end
    if copied then copied, trouble = Fs.mkdirs(g.empty) end
    if copied then copied, trouble = Fs.write(g.empty .. "/" .. name, assert(bytes), 0x1ed) end
    if not copied then
      fail(g, "could not copy " .. g.exe .. " into " .. g.empty .. ": " .. trouble)
    else
      TASKS[name](g)
    end
  end
  if g.failed then
    say("FAIL")
    return 1
  end
  say("PASS")
  return 0
end

function Hard.main(argv: {integer: string}): integer
  local name, dir = argv[1], argv[2]
  if name == nil or TASKS[name] == nil or dir == nil or argv[3] ~= nil then
    local _, _ = Fs.put(Fs.stderr, "usage: eval/check/hard.tl jobs|mirror <dir>\n")
    return 2
  end
  local absolute, _ = Fs.absolute(dir)
  return grade(name, absolute or dir)
end

return Hard
