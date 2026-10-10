--- Runs one round of evals: lays an arena per task, runs the solvers up
--- to `--jobs` at a time, and only then grades each arena, one after
--- another, so the load of solvers still running cannot flake a check
--- that times something. Each arena then has its summary and its
--- result.json, and <out>/index.txt a line per task.
---
---     cosmic --standalone eval/round.tl <task,...|all> --model M [--tool PATH]
---         [--out DIR] [--run N] [--jobs N] [--max-turns N] [--timeout S]
---
--- It runs [`eval/arena`], [`eval/solve`], the task's `eval/check/<task>`,
--- [`eval/summarize`] and [`eval/result`] as programs, each of which
--- stays usable by hand (eval/README.md). [`eval/round`] runs this on the
--- bootstrap cosmic: it requires `cosmic.*` modules only, so nothing here
--- can call those scripts' functions. [`Round.plan`] is the round as data;
--- [`Round.execute`] carries it out through a [`Round.System`], which a test
--- replaces with a fake.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Proc = require("cosmic.proc")

local record Round
  --- What the command line asked for.
  record Options
    tasks: {string}
    model: string
    --- The cosmic binary under test; nil for this checkout's.
    tool: string
    --- Where the round's arenas and index go; nil for the default.
    out: string
    run: integer
    jobs: integer
    max_turns: integer
    timeout: integer
  end

  --- One task's part of a round: its arena and the commands that lay,
  --- solve, summarize and grade it, as argument lists.
  record Entry
    task: string
    arena: string
    lay: {string}
    solve: {string}
    summarize: {string}
    grade: {string}
    --- The head of [`eval/result`]'s command line; the grade's status and
    --- log follow once known.
    result: {string}
  end

  record Plan
    out: string
    jobs: integer
    entries: {Entry}
  end

  --- The tasks `all` stands for: one for each eval/task/<task>.md
  --- ([`eval/round_test.tl`] holds the list to them).
  all_tasks: {string}

  --- A finished command's exit status and its output (standard
  --- output and error together).
  record Output
    code: integer
    text: string
  end

  --- Which numbered command ended, and its exit status.
  record Done
    id: integer
    code: integer
  end

  --- What a round does to the world. Tests give a fake.
  record System
    --- Runs a command to its end.
    run: function({string}): Round.Output
    --- Starts a command, its output kept in the file `log`: a number
    --- naming it, nil when it could not start.
    start: function({string}, string): integer | nil
    --- Waits for the first of the numbered commands to end.
    wait: function({integer}): Round.Done
    read: function(string): string | nil
    write: function(string, string): boolean
    mkdirs: function(string): boolean
  end
end

Round.all_tasks = { "jobs", "kv", "ledger", "mirror", "notes", "pack", "relay" }

local USAGE <const> = "usage: eval/round <task,...|all> --model M [--tool PATH] [--out DIR] " ..
  "[--run N] [--jobs N] [--max-turns N] [--timeout S]"

local function positive(text: string): integer | nil
  if text == nil or not text:match("^[1-9]%d*$") then return nil end
  return math.tointeger(tonumber(text))
end

--- Reads the command line: the tasks, then the options; `--run` is 1,
--- `--jobs` 3, `--max-turns` 150 and `--timeout` 600 (eval/solve's own
--- defaults, stated so result.json records them) unless given.
function Round.parse(argv: {integer: string}): Round.Options | nil, string
  local options: Round.Options = { run = 1, jobs = 3, max_turns = 150, timeout = 600 }
  local i = 1
  while argv[i] ~= nil do
    local word = argv[i]
    if word:sub(1, 2) == "--" then
      local value = argv[i + 1]
      if value == nil then return nil, word .. " needs a value" end
      if word == "--model" then
        options.model = value
      elseif word == "--tool" then
        options.tool = value
      elseif word == "--out" then
        options.out = value
      elseif word == "--run" or word == "--jobs" or word == "--max-turns" or word == "--timeout" then
        local n = positive(value)
        if n == nil then return nil, word .. " takes a positive integer: " .. value end
        if word == "--run" then
          options.run = n
        elseif word == "--jobs" then
          options.jobs = n
        elseif word == "--max-turns" then
          options.max_turns = n
        else
          options.timeout = n
        end
      else
        return nil, "unknown option " .. word
      end
      i = i + 2
    elseif options.tasks ~= nil then
      return nil, "one list of tasks only: " .. word
    else
      options.tasks = {}
      local seen: {string: boolean} = {}
      local names: {string} = word == "all" and Round.all_tasks or {}
      if word ~= "all" then
        for name in word:gmatch("[^,]+") do names[#names + 1] = name end
      end
      for _, name in ipairs(names) do
        local known = false
        for _, each in ipairs(Round.all_tasks) do known = known or each == name end
        if not known then return nil, "no task " .. name end
        if not seen[name] then
          seen[name] = true
          options.tasks[#options.tasks + 1] = name
        end
      end
      i = i + 1
    end
  end
  if options.tasks == nil or #options.tasks == 0 then return nil, "tasks are required" end
  if options.model == nil or options.model == "" then return nil, "--model is required" end
  return options, ""
end

--- The default `--out`: /tmp/cosmic-evals/<model>-<commit>, the model's
--- name with anything but letters, digits, `.`, `_` and `-` as `-`.
function Round.default_out(model: string, commit: string): string
  return "/tmp/cosmic-evals/" .. (model:gsub("[^%w%._-]", "-")) .. "-" .. commit
end

--- The round as data, for `options` with `root` the checkout, `tool` the
--- binary under test, `commit` the checkout's short commit and `out` the
--- round's directory (all absolute): each task's arena at
--- <out>/<task>/run-<NNN> and its commands.
function Round.plan(options: Round.Options, root: string, tool: string, commit: string,
                    out: string): Round.Plan
  local entries: {Round.Entry} = {}
  for _, task in ipairs(options.tasks) do
    local arena = out .. "/" .. task .. "/" .. string.format("run-%03d", options.run)
    local solve = { root .. "/eval/solve", arena, "--model", options.model }
    local result = { root .. "/eval/result", arena, "--model", options.model }
    local function both(flag: string, value: integer | nil)
      if value == nil then return end
      for _, argv in ipairs({ solve, result }) do
        argv[#argv + 1] = flag
        argv[#argv + 1] = tostring(value)
      end
    end
    both("--max-turns", options.max_turns)
    both("--timeout", options.timeout)
    if options.tool == nil then
      result[#result + 1] = "--commit"
      result[#result + 1] = commit
    end
    entries[#entries + 1] = {
      task = task, arena = arena,
      lay = { root .. "/eval/arena", task, tool, arena },
      solve = solve,
      summarize = { root .. "/eval/summarize", arena .. "/transcript.jsonl" },
      grade = { root .. "/eval/check/" .. task, arena },
      result = result,
    }
  end
  return { out = out, jobs = options.jobs, entries = entries }
end

local function say(line: string)
  local _, _ = Fs.put(Fs.stdout, line .. "\n")
end

--- The index line for an arena: its task, and its result.json's status,
--- turns, cost and verdict, `null` where it has none.
local function index_line(system: Round.System, entry: Round.Entry): string
  local text = system.read(entry.arena .. "/result.json")
  local fields: any = nil
  if text ~= nil then
    local decoded, _ = Json.decode(text)
    fields = decoded
  end
  local function field(key: string): string
    local value: any = fields is {string: any} and fields[key] or nil
    if value == nil then return "null" end
    return tostring(value)
  end
  local spent: any = fields is {string: any} and fields["cost_usd"] or nil
  local cost = spent is number and string.format("$%.2f", spent) or "null"
  return entry.task .. " status=" .. field("status") .. " turns=" .. field("turns") ..
    " cost=" .. cost .. " verdict=" .. field("grade_verdict")
end

--- Carries `plan` out: lays each arena, runs the solvers `plan.jobs` at
--- a time, then -- the last solver done -- summarizes, grades and
--- writes the result of each arena in turn, and writes <out>/index.txt.
--- An arena that cannot be laid is not solved, graded or reported but
--- gets an index line saying so. Answers the number of lines that did
--- not end `verdict=PASS`: 0 when everything passed.
function Round.execute(plan: Round.Plan, system: Round.System): integer
  if not system.mkdirs(plan.out) then
    say("round: cannot make " .. plan.out)
    return 2
  end
  local lines: {string} = {}
  local laid: {Round.Entry} = {}
  for _, entry in ipairs(plan.entries) do
    local made = system.run(entry.lay)
    if made.code == 0 then
      laid[#laid + 1] = entry
    else
      lines[#lines + 1] = entry.task .. " status=lay_failed turns=null cost=null verdict=null"
      say("round: " .. entry.task .. ": " .. (made.text:gsub("\n+$", "")))
    end
  end
  local waiting: {Round.Entry} = {}
  for _, entry in ipairs(laid) do waiting[#waiting + 1] = entry end
  local running: {integer} = {}
  local owner: {integer: Round.Entry} = {}
  while #waiting > 0 or #running > 0 do
    while #waiting > 0 and #running < plan.jobs do
      local entry = table.remove(waiting, 1)
      local handle = system.start(entry.solve, entry.arena .. "/solve.log")
      if handle ~= nil then
        running[#running + 1] = handle
        owner[handle] = entry
        say("round: " .. entry.task .. ": solving in " .. entry.arena)
      else
        say("round: " .. entry.task .. ": could not start the solver")
      end
    end
    if #running > 0 then
      local done = system.wait(running)
      for i, handle in ipairs(running) do
        if handle == done.id then
          table.remove(running, i)
          break
        end
      end
      say("round: " .. owner[done.id].task .. ": solver exit " .. done.code)
    end
  end
  local failures = 0
  for _, entry in ipairs(laid) do
    local summary = system.run(entry.summarize)
    system.write(entry.arena .. "/summary.txt", summary.text)
    local graded = system.run(entry.grade)
    local logs = graded.text:match("check: logs ([^\n]+)")
    local log = logs ~= nil and logs .. "/grade.log" or entry.arena .. "/grade.log"
    system.write(log, graded.text)
    say("round: " .. entry.task .. ": grade exit " .. graded.code .. " (" .. log .. ")")
    local result: {string} = {}
    for _, word in ipairs(entry.result) do result[#result + 1] = word end
    -- The log is named from the arena, as the transcript is.
    local relative = log:sub(1, #entry.arena + 1) == entry.arena .. "/" and log:sub(#entry.arena + 2) or log
    for _, word in ipairs({ "--grade-exit", tostring(graded.code), "--grade-log", relative }) do
      result[#result + 1] = word
    end
    local wrote = system.run(result)
    if wrote.code ~= 0 then
      say("round: " .. entry.task .. ": result: " .. (wrote.text:gsub("\n+$", "")))
    end
    lines[#lines + 1] = index_line(system, entry)
  end
  for _, line in ipairs(lines) do
    say(line)
    if not line:find(" verdict=PASS", 1, true) then failures = failures + 1 end
  end
  system.write(plan.out .. "/index.txt", table.concat(lines, "\n") .. "\n")
  return failures
end

--- The System that runs commands for real.
--- The checkout's short commit: `git rev-parse --short HEAD` in `root`,
--- git found on `path` (PATH by default), "unknown" where there is none.
function Round.short_commit(root: string, path?: string): string
  local git, _ = Proc.find("git", path)
  if git == nil then return "unknown" end
  local ran, _ = Child.run({ git, "-C", root, "rev-parse", "--short", "HEAD" },
    { stdout = "capture", stderr = "null", stdin = "null", timeout_ns = Clock.seconds(10) })
  local sha = ran ~= nil and ran.ok and (ran.stdout or ""):match("^(%x+)\n$") or nil
  return sha or "unknown"
end

local function real_system(): Round.System
  local handles: {integer: Child.Handle} = {}
  local streams: {integer: integer} = {}
  local issued = 0
  return {
    run = function(argv: {string}): Round.Output
      local result, trouble = Child.run(argv, { stdout = "capture", stderr = "stdout",
        stdin = "null", timeout_ns = Clock.minutes(15) })
      if result == nil then return { code = 127, text = trouble } end
      return { code = Child.shell_status(result), text = result.stdout or "" }
    end,
    start = function(argv: {string}, log: string): integer | nil
      local fd, _ = Fs.open_write(log)
      if fd == nil then return nil end
      local handle, _ = Child.start(argv, { stdout = fd, stderr = fd, stdin = "null" })
      if handle == nil then
        local _, _ = Fs.close(fd)
        return nil
      end
      issued = issued + 1
      handles[issued] = handle
      streams[issued] = fd
      return issued
    end,
    wait = function(numbers: {integer}): Round.Done
      local live: {Child.Handle} = {}
      for _, number in ipairs(numbers) do live[#live + 1] = handles[number] end
      local done, _ = Child.wait_any(live)
      assert(done, "wait_any")
      local finished = 0
      for _, number in ipairs(numbers) do
        if handles[number] == done then finished = number end
      end
      local result, _ = done:wait()
      local _, _ = Fs.close(streams[finished])
      return { id = finished, code = result ~= nil and Child.shell_status(result) or 127 }
    end,
    read = function(path: string): string | nil
      local text, _ = Fs.read(path)
      return text
    end,
    write = function(path: string, text: string): boolean
      local wrote, _ = Fs.write(path, text)
      return wrote
    end,
    mkdirs = function(path: string): boolean
      local made, _ = Fs.mkdirs(path)
      return made
    end,
  }
end

local function complain(message: string)
  local _, _ = Fs.put(Fs.stderr, "round: " .. message .. "\n")
end

function Round.main(argv: {integer: string}): integer
  local options, trouble = Round.parse(argv)
  if options == nil then
    complain(trouble)
    local _, _ = Fs.put(Fs.stderr, USAGE .. "\n")
    return 2
  end
  local script, strouble = Fs.absolute(argv[0])
  local root = script ~= nil and script:match("^(.*)/eval/[^/]+%.tl$") or nil
  if root == nil then
    complain(script == nil and strouble or argv[0] .. ": expected to run as .../eval/round.tl")
    return 2
  end
  local system = real_system()
  local short = Round.short_commit(root)
  local tool = options.tool
  if tool == nil then
    local built = system.run({ root .. "/bin/cosmic-bootstrap", "--standalone",
      root .. "/build/paths.tl", root })
    if built.code ~= 0 then
      complain("cannot find this checkout's build directory (bin/zig build boot first?): " .. built.text)
      return 2
    end
    tool = built.text:gsub("%s+$", "") .. "/bin/cosmic"
  end
  local absolute, atrouble = Fs.absolute(tool)
  if absolute == nil then
    complain(atrouble)
    return 2
  end
  local out = options.out or Round.default_out(options.model, short)
  -- Fs.absolute resolves a path that is there.
  local made, mtrouble = Fs.mkdirs(out)
  if not made then
    complain(mtrouble)
    return 2
  end
  local absolute_out, otrouble = Fs.absolute(out)
  if absolute_out == nil then
    complain(otrouble)
    return 2
  end
  local plan = Round.plan(options, root, absolute, short, absolute_out)
  local failures = Round.execute(plan, system)
  return failures == 0 and 0 or 1
end

return Round
