--- Grades the notes task in an arena: the project's tests and format
--- check pass, with recorded tests and examples behind them, cosmic
--- builds it, and the executable runs on its own, including its own
--- `help`.
---
---     cosmic --standalone eval/check/notes.tl <dir>
---
--- `eval/check/notes` runs this on the bootstrap cosmic, as bin/vendor
--- runs build/vendor.tl: it requires `cosmic.*` modules only. The
--- arena's own `bin/cosmic` does the testing and building.
---
--- The executable is copied alone into an empty directory and run with
--- an empty environment -- no PATH, no HOME, no TMPDIR -- so nothing
--- beside it and nothing on PATH can help, as the task promises.
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")

local record Notes
end

local function say(line: string)
  local _, _ = Fs.put(Fs.stdout, "check: " .. line .. "\n")
end

--- A child's exit as a shell reports it: its code, or 128 plus the
--- signal that ended it.
function Notes.status(result: Child.Result): integer
  if result.code ~= nil then
    return result.code
  end
  return 128 + (result.signal or 0)
end

--- Whether a failure's stderr is cosmic's own -- a launcher or
--- runtime failure -- rather than the tool's: a line of it starts with
--- `cosmic`.
function Notes.failed_in_cosmic(err: string): boolean
  return err:find("^cosmic") ~= nil or err:find("\ncosmic") ~= nil
end

--- Whether `cosmic build`'s output names o/bin/notes among the
--- executables it wrote: `build: PASS (o/bin/notes, 433 ms)`.
function Notes.built_notes(output: string): boolean
  for line in output:gmatch("[^\n]+") do
    local wrote = line:match("^build: PASS %((.*)%)$")
    if wrote ~= nil then
      for name in wrote:gmatch("[^,]+") do
        if name:match("^%s*(.-)%s*$") == "o/bin/notes" then
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
--- so what `check_evidence` finds afterward is this grading's own. A
--- database that is not there yet has nothing to clear.
function Notes.reset_evidence(path: string): boolean, string
  local present, trouble = Fs.exists(path)
  if present == nil then
    return false, trouble
  elseif not present then
    return true, ""
  end
  local db, otrouble = Sqlite.open(path, true)
  if db == nil then
    return false, otrouble
  end
  local ok, etrouble = Sqlite.exec(db, "delete from runs")
  local closed, close_trouble = Sqlite.close(db)
  if not ok then return false, etrouble end
  if not closed then return false, close_trouble end
  return true, ""
end

--- How many tests and examples passed in the runs a build database
--- records; a doctest is an example.
function Notes.evidence(path: string): integer | nil, integer, string
  local present, trouble = Fs.exists(path)
  if not present then
    return nil, 0, present == nil and trouble or path .. ": no build database"
  end
  local db, otrouble = Sqlite.open(path)
  if db == nil then
    return nil, 0, otrouble
  end
  local rows, rtrouble = Sqlite.text_rows(db, [[
    select i.kind, i.origin, count(*)
    from runs r join inputs i on i.path = r.path
    where r.passed = 1
    group by i.kind, i.origin
  ]], {})
  local closed, close_trouble = Sqlite.close(db)
  if rows == nil then
    return nil, 0, rtrouble
  end
  if not closed then
    return nil, 0, close_trouble
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

--- One grading run: where it writes its logs, and whether anything
--- has failed yet.
local record Grade
  dir: string
  steps: integer
  failed: boolean
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
    say("FAIL " .. label .. ": " .. trouble)
    g.failed = true
    return false
  end
  local passed = work(out)
  local _, _ = Fs.close(out)
  if passed then
    say("ok   " .. label)
    return true
  end
  say("FAIL " .. label)
  -- A log that cannot be read shows nothing under the failure.
  local read, _ = Fs.read(log)
  local text = read or ""
  if text ~= "" and text:sub(-1) ~= "\n" then
    text = text .. "\n"
  end
  for line in text:gmatch("([^\n]*)\n") do
    local _, _ = Fs.put(Fs.stdout, "check:   " .. line .. "\n")
  end
  g.failed = true
  return false
end

local function command_step(g: Grade, argv: {string}, cwd: string): boolean
  return step(g, table.concat(argv, " "), function(out: integer): boolean
    local result, trouble = Child.run(argv, { cwd = cwd, stdout = out, stderr = "stdout" })
    if result == nil then
      local _, _ = Fs.put(out, trouble .. "\n")
      return false
    end
    return Notes.status(result) == 0
  end)
end

--- Runs `./notes` in `dir` with nothing in its environment but `env`,
--- and checks that it exits 0 printing exactly `want` on stdout and
--- stderr together.
local function expect(g: Grade, dir: string, want: string, args: {string}, env?: {string: string})
  local argv: {string} = { dir .. "/notes" }
  local shown: {string} = { "env -i" }
  local names: {string} = {}
  for name in pairs(env or {}) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    shown[#shown + 1] = name .. "=" .. env[name]
  end
  shown[#shown + 1] = "./notes"
  for _, word in ipairs(args) do
    argv[#argv + 1] = word
    shown[#shown + 1] = word
  end
  local label = table.concat(shown, " ")
  local result, trouble = Child.run(argv, { cwd = dir, env = env or {},
    stdout = "capture", stderr = "stdout" })
  local code = result ~= nil and Notes.status(result) or 127
  local got = result ~= nil and trimmed(result.stdout or "") or trouble
  if code == 0 and got == want then
    say("ok   " .. label .. " -> " .. first_line(want))
  else
    say("FAIL " .. label .. ": exit " .. code .. ", got '" .. got .. "', wanted '" .. want .. "'")
    g.failed = true
  end
end

local function is_executable(path: string): boolean
  local st, _ = Fs.stat(path)
  return st ~= nil and st.kind == "file" and st.mode & 0x49 ~= 0
end

--- Copies the built executable alone into an empty directory and runs
--- it there: add, list, search, rm, an unknown id, NOTES_DB and help.
local function run_alone(g: Grade, exe: string)
  local empty = g.dir .. "/empty"
  local err_path = g.dir .. "/check.err"
  local bytes, trouble = Fs.read(exe)
  local copied = bytes ~= nil
  if copied then copied, trouble = Fs.remove_tree(empty) end
  if copied then copied, trouble = Fs.mkdirs(empty) end
  if copied then copied, trouble = Fs.write(empty .. "/notes", assert(bytes), 0x1ed) end
  if not copied then
    say("FAIL could not copy " .. exe .. " into " .. empty .. ": " .. trouble)
    g.failed = true
    return
  end
  expect(g, empty, "1", { "add", "hello", "world" })
  expect(g, empty, "2", { "add", "second", "note" })
  expect(g, empty, "1\thello world\n2\tsecond note", { "list" })
  expect(g, empty, "2\tsecond note", { "search", "second" })
  expect(g, empty, "", { "rm", "1" })

  -- The message must be the tool's own: a launcher or runtime failure
  -- also exits non-zero with something on stderr.
  local result, _ = Child.run({ empty .. "/notes", "rm", "9" }, { cwd = empty, env = {},
    stdout = "null", stderr = "capture" })
  local err = result ~= nil and result.stderr or ""
  local _, _ = Fs.write(err_path, err)
  if result ~= nil and Notes.status(result) == 0 then
    say("FAIL rm of an unknown id exited 0")
    g.failed = true
  elseif err == "" then
    say("FAIL rm of an unknown id said nothing on stderr")
    g.failed = true
  elseif Notes.failed_in_cosmic(err) then
    say("FAIL rm 9 failed in cosmic, not in notes: " .. first_line(err))
    g.failed = true
  else
    say("ok   rm 9 -> non-zero exit, stderr: " .. first_line(err))
  end
  expect(g, empty, "2\tsecond note", { "list" })

  local _, _ = Fs.remove(empty .. "/notes.db")
  expect(g, empty, "1", { "add", "elsewhere" }, { NOTES_DB = "other.db" })
  local st, _ = Fs.stat(empty .. "/other.db")
  if st ~= nil and st.kind == "file" then
    say("ok   NOTES_DB names the file")
  else
    say("FAIL NOTES_DB was not honored")
    g.failed = true
  end

  local help, _ = Child.run({ empty .. "/notes", "help" }, { cwd = empty, env = {},
    stdout = "capture", stderr = "capture" })
  local _, _ = Fs.write(err_path, help ~= nil and help.stderr or "")
  local out = help ~= nil and trimmed(help.stdout or "") or ""
  if help == nil or Notes.status(help) ~= 0 then
    say("FAIL notes help exited " .. (help ~= nil and Notes.status(help) or 127))
    g.failed = true
  elseif out == "" then
    say("FAIL notes help printed nothing")
    g.failed = true
  else
    local missing = ""
    for _, word in ipairs({ "add", "list", "rm", "search" }) do
      if not out:find(word, 1, true) then
        missing = missing .. " " .. word
      end
    end
    if missing ~= "" then
      say("FAIL notes help did not mention:" .. missing)
      g.failed = true
    else
      say("ok   notes help -> mentions add, list, rm, search")
    end
  end
end

--- Grades the arena at `dir`, printing a line per check and PASS or
--- FAIL last; 0 when everything passed.
function Notes.grade(dir: string): integer
  local project = dir .. "/project"
  local cosmic = dir .. "/bin/cosmic"
  local is_project, project_trouble = Fs.is_dir(project)
  if not is_project then
    say("FAIL no project at " .. project ..
      (project_trouble ~= "" and ": " .. project_trouble or ""))
    say("FAIL")
    return 1
  end
  local g: Grade = { dir = dir, steps = 0, failed = false }
  local db = project .. "/o/build.db"
  local _, _ = Fs.remove(project .. "/notes.db")
  step(g, "evidence reset " .. db, function(out: integer): boolean
    local ok, trouble = Notes.reset_evidence(db)
    if not ok then
      local _, _ = Fs.put(out, trouble .. "\n")
    end
    return ok
  end)
  command_step(g, { cosmic, "test" }, project)
  step(g, "evidence check " .. db, function(out: integer): boolean
    local tests, examples, trouble = Notes.evidence(db)
    if tests == nil then
      local _, _ = Fs.put(out, trouble .. "\n")
      return false
    end
    local _, _ = Fs.put(out, "evidence: " .. tests .. " tests, " .. examples .. " examples\n")
    return tests > 0 and examples > 0
  end)
  command_step(g, { cosmic, "fix", "--check" }, project)
  local built = command_step(g, { cosmic, "build" }, project)
  local exe = project .. "/o/bin/notes"
  -- Only a build that passed and names o/bin/notes among what it wrote
  -- vouches for the file: after a failed build, or one that no longer
  -- builds notes (cmd/notes renamed away), an o/bin/notes still there
  -- is an earlier build's. It stays in place -- it is the solver's
  -- deliverable, not the grader's to delete -- but it is not run.
  -- A build log that cannot be read names no binary.
  local read, _ = Fs.read(g.dir .. "/check-" .. g.steps .. ".out")
  local log = read or ""
  if not built then
    say("skip o/bin/notes: cosmic build failed; not running an earlier build's binary")
  elseif not Notes.built_notes(log) or not is_executable(exe) then
    say("FAIL cosmic build did not produce o/bin/notes; a binary is cmd/<name>/main.tl")
    g.failed = true
  else
    run_alone(g, exe)
  end
  if g.failed then
    say("FAIL")
    return 1
  end
  say("PASS")
  return 0
end

function Notes.main(argv: {integer: string}): integer
  local dir = argv[1]
  if dir == nil or argv[2] ~= nil then
    local _, _ = Fs.put(Fs.stderr, "usage: eval/check/notes <dir>\n")
    return 2
  end
  -- The steps run in other directories, and name the arena's files.
  local absolute, _ = Fs.absolute(dir)
  return Notes.grade(absolute or dir)
end

return Notes
