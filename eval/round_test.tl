--- [`eval/round.tl`] with a fake System: the plan's layout and commands,
--- the `--jobs` limit, and that no grade starts before the last solver
--- has ended. No claude is started.
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Test = require("cosmic.test")
local Round = require("eval.round")

Test.policy{ grants = { { path = "eval/task/", letters = "r" } } }

local function options(list: {string}): Round.Options
  local parsed, why = Round.parse(list)
  return (assert(parsed, why))
end

local function test_the_command_line_names_tasks_and_a_model()
  local o = options({ "notes,kv", "--model", "m", "--jobs", "2", "--run", "4" })
  assert(#o.tasks == 2 and o.tasks[1] == "notes" and o.tasks[2] == "kv")
  assert(o.model == "m" and o.jobs == 2 and o.run == 4 and o.max_turns == 150 and o.timeout == 600)
  assert(#options({ "all", "--model", "m" }).tasks == #Round.all_tasks)
  assert(options({ "all", "--model", "m" }).jobs == 3)
  assert(#options({ "kv,kv", "--model", "m" }).tasks == 1, "a task listed twice runs once")
  for _, bad in ipairs({ { "notes" }, { "--model", "m" }, { "nope", "--model", "m" },
      { "notes", "--model", "m", "--jobs", "0" }, { "notes", "--model", "m", "--x", "1" },
      { "notes", "--model" } }) do
    assert(Round.parse(bad) == nil, table.concat(bad, " "))
  end
end

--- `all` is each task eval/task holds, no more and no fewer.
local function test_all_is_every_task_there_is()
  local names: {string} = {}
  local listing = assert(Fs.list("eval/task"))
  for _, entry in ipairs(listing) do
    names[#names + 1] = entry:match("^(.*)%.md$")
  end
  table.sort(names)
  local listed: {string} = {}
  for _, name in ipairs(Round.all_tasks) do listed[#listed + 1] = name end
  table.sort(listed)
  assert(table.concat(listed, ",") == table.concat(names, ","), table.concat(listed, ","))
end

local function test_the_default_out_names_the_model_and_the_commit()
  assert(Round.default_out("claude-opus-4/x", "abc1234") == "/tmp/cosmic-evals/claude-opus-4-x-abc1234")
end

local function test_the_plan_lays_one_arena_a_task_and_passes_the_flags_on()
  local o = options({ "notes,jobs", "--model", "m", "--max-turns", "9", "--timeout", "60", "--run", "2" })
  local plan = Round.plan(o, "/repo", "/tool/cosmic", "abc", "/out")
  assert(plan.out == "/out" and plan.jobs == 3 and #plan.entries == 2)
  local first = plan.entries[1]
  assert(first.arena == "/out/notes/run-002", first.arena)
  assert(table.concat(first.lay, " ") == "/repo/eval/arena notes /tool/cosmic /out/notes/run-002")
  assert(table.concat(first.solve, " ") ==
      "/repo/eval/solve /out/notes/run-002 --model m --max-turns 9 --timeout 60")
  assert(table.concat(first.grade, " ") == "/repo/eval/check/notes /out/notes/run-002")
  assert(table.concat(first.summarize, " ") == "/repo/eval/summarize /out/notes/run-002/transcript.jsonl")
  assert(table.concat(first.result, " ") ==
      "/repo/eval/result /out/notes/run-002 --model m --max-turns 9 --timeout 60 --commit abc")
  assert(plan.entries[2].arena == "/out/jobs/run-002")
  local given = Round.plan(options({ "notes", "--model", "m", "--tool", "/t" }), "/repo", "/t", "abc", "/out")
  assert(not table.concat(given.entries[1].result, " "):find("--commit", 1, true),
    "the checkout's commit is not the binary's when a tool was named")
end

--- A System whose commands are recorded as events, `events`, in the
--- order they happened. Each solver started stays running until the
--- round waits for one; the first started ends first. `most` is the
--- most running at once. A task named in `fails` has its grade fail.
local record Fake
  system: Round.System
  events: {string}
  files: {string: string}
  most: integer
end

local function fake(fails: {string: boolean}, lay_fails: {string: boolean}): Fake
  local f: Fake = { events = {}, files = {}, most = 0, system = nil }
  local running: {integer: string} = {}
  local count, issued = 0, 0
  local function task_of(argv: {string}): string
    return (argv[2]:match("/([^/]+)/run%-%d+")) or argv[2]:match("/([^/]+)$")
  end
  f.system = {
    mkdirs = function(path: string): boolean
      f.events[#f.events + 1] = "mkdirs " .. path
      return true
    end,
    read = function(path: string): string | nil return f.files[path] end,
    write = function(path: string, text: string): boolean
      f.files[path] = text
      return true
    end,
    run = function(argv: {string}): Round.Output
      local verb = argv[1]:match("([^/]+)$")
      local task = verb == "summarize" and argv[2]:match("/([^/]+)/run%-%d+") or task_of(argv)
      if verb == "arena" then task = argv[2] end
      f.events[#f.events + 1] = verb .. " " .. task
      if verb == "arena" and lay_fails[task] then return { code = 2, text = "no such task\n" } end
      if verb == "summarize" then return { code = 0, text = "turns=1\n" } end
      if verb == "notes" or verb == "kv" or verb == "pack" or verb == "ledger" then
        local failed = fails[task]
        return { code = failed and 1 or 0, text = "check: logs " .. argv[2] .. "/grades/1\ncheck: " ..
            (failed and "FAIL" or "PASS") .. "\n" }
      end
      if verb == "result" then
        local code = argv[#argv - 2 + 0]
        local text = assert(Json.encode({ status = "completed", turns = 3, cost_usd = 1.5,
          grade_verdict = code == "0" and "PASS" or "FAIL" }))
        f.files[argv[2] .. "/result.json"] = text
        return { code = 0, text = "" }
      end
      return { code = 0, text = "" }
    end,
    start = function(argv: {string}, _log: string): integer | nil
      issued = issued + 1
      running[issued] = task_of(argv)
      count = count + 1
      if count > f.most then f.most = count end
      f.events[#f.events + 1] = "solve " .. running[issued]
      return issued
    end,
    wait = function(ids: {integer}): Round.Done
      local id = ids[1]
      count = count - 1
      f.events[#f.events + 1] = "solved " .. running[id]
      return { id = id, code = 0 }
    end,
  }
  return f
end

local function position(events: {string}, prefix: string, from?: integer): integer
  for i = from or 1, #events do
    if events[i]:sub(1, #prefix) == prefix then return i end
  end
  return 0
end

local function test_no_more_solvers_run_than_jobs_and_no_grade_starts_before_the_last_ends()
  local o = options({ "notes,kv,pack,ledger", "--model", "m", "--jobs", "2" })
  local plan = Round.plan(o, "/repo", "/t", "abc", "/out")
  local f = fake({}, {})
  assert(Round.execute(plan, f.system) == 0, table.concat(f.events, "\n"))
  assert(f.most == 2, "most solvers at once: " .. f.most)
  local last_solved, first_graded, first_summary = 0, #f.events, #f.events
  for i, event in ipairs(f.events) do
    if event:sub(1, 7) == "solved " then last_solved = i end
    if event == "notes notes" or event == "kv kv" or event == "pack pack" or event == "ledger ledger" then
      if i < first_graded then first_graded = i end
    end
    if event:sub(1, 10) == "summarize " and i < first_summary then first_summary = i end
  end
  assert(last_solved > 0 and last_solved < first_graded and last_solved < first_summary,
    table.concat(f.events, "\n"))
  -- Every arena was laid before the first solver started, and one grade
  -- ran after another rather than alongside.
  assert(position(f.events, "arena ", 1) < position(f.events, "solve "))
  assert(position(f.events, "arena ", position(f.events, "solve ")) == 0, "a lay after a solve")
end

local function test_the_index_has_a_line_a_task_and_the_log_is_kept_in_the_grades_directory()
  local o = options({ "notes,kv", "--model", "m" })
  local plan = Round.plan(o, "/repo", "/t", "abc", "/out")
  local f = fake({ kv = true }, {})
  assert(Round.execute(plan, f.system) == 1, "a failed grade is a failed round")
  local index = assert(f.files["/out/index.txt"])
  assert(index == "notes status=completed turns=3 cost=$1.50 verdict=PASS\n" ..
      "kv status=completed turns=3 cost=$1.50 verdict=FAIL\n", index)
  assert(f.files["/out/notes/run-001/grades/1/grade.log"]:find("check: PASS", 1, true))
  assert(f.files["/out/kv/run-001/summary.txt"] == "turns=1\n")
end

local function test_an_arena_that_cannot_be_laid_is_not_solved()
  local o = options({ "notes,kv", "--model", "m" })
  local plan = Round.plan(o, "/repo", "/t", "abc", "/out")
  local f = fake({}, { notes = true })
  assert(Round.execute(plan, f.system) == 1)
  assert(position(f.events, "solve notes") == 0 and position(f.events, "solve kv") > 0)
  assert(assert(f.files["/out/index.txt"]):find("notes status=lay_failed", 1, true))
end
