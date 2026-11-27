local GithubApi = require("cosmic_ci.github_api")
local MainRed = require("cosmic_ci.main_red")

local base <const> = "https://api.test"

--- What a fake returns: the open `main-red` issues, the run's jobs, and
--- main's newest completed push runs.
local record Answers
  issues?: string
  jobs?: string
  runs?: string
  label_status?: integer
end

--- A run context of a push run of main that ended `conclusion`, run 77,
--- whose client returns `answers`, recording each request as
--- "METHOD path" and each body sent.
local function fake(conclusion: string, answers: Answers, event_name?: string, branch?: string): MainRed.Context, {string}, {string}
  local calls: mut {string} = {}
  local bodies: mut {string} = {}
  local client: GithubApi.Client = {
    base = base,
    send = function(request: GithubApi.Request): GithubApi.Reply?, string
      local path = request.url:sub(#base + 1)
      calls[#calls + 1] = request.method .. " " .. path
      local body = "{}"
      if request.method == "POST" and path:sub(-7) == "/labels" then
        return { status = answers.label_status or 201, headers = {}, body = '{"name":"main-red"}' }, ""
      elseif request.method ~= "GET" then
        bodies[#bodies + 1] = request.body or ""
        body = '{"number":12}'
      elseif path:find("/issues?", 1, true) ~= nil then
        body = answers.issues or "[]"
      elseif path:find("/jobs?", 1, true) ~= nil then
        body = answers.jobs or '{"jobs":[]}'
      elseif path:find("/runs?", 1, true) ~= nil then
        body = answers.runs or '{"workflow_runs":[]}'
      end
      return { status = 200, headers = {}, body = body }, ""
    end,
    fetch = function(_url: string, _to: string): boolean, string return false, "no fetch" end,
  }
  local c: MainRed.Context = { client = client, repository = "owner/repo", event = event_name or "push",
    conclusion = conclusion, branch = branch or "main", sha = "aea966032c2327b377465e1105f70ce7db414ed2",
    title = "eval: a project of its own (#4403)\n\nmore", url = "https://github.test/runs/77", run_id = "77" }
  return c, calls, bodies
end

local failed_jobs <const> = '{"jobs":[{"name":"linux-x86_64-checked","conclusion":"failure"},' ..
  '{"name":"alpine-x86_64","conclusion":"failure"},{"name":"linux-aarch64","conclusion":"success"},' ..
  '{"name":"ci","conclusion":"failure"}]}'
local open_issue <const> = '[{"number":12}]'

--- A failed push run with no issue open opens one, labelled, that names
--- the commit and the jobs that failed but not the gate.
local function test_a_red_run_opens_an_issue_naming_its_failed_jobs()
  local c, calls, bodies = fake("failure", { jobs = failed_jobs })
  local said = MainRed.follow(c)
  assert(said == "main is red at aea966032: opened an issue (alpine-x86_64, linux-x86_64-checked)", said)
  assert(calls[#calls - 1] == "POST /repos/owner/repo/labels" and
      calls[#calls] == "POST /repos/owner/repo/issues", table.concat(calls, "|"))
  local body = assert(bodies[1])
  assert(body:find('"title":"main is red: alpine-x86_64, linux-x86_64-checked at aea966032"', 1, true) ~= nil, body)
  assert(body:find('"labels":["main-red"]', 1, true) ~= nil, body)
  assert(body:find("eval: a project of its own (#4403))", 1, true) ~= nil, body)
  assert(body:find("https://github.test/runs/77", 1, true) ~= nil, body)
  assert(body:find("more", 1, true) == nil, body)
end

--- With the issue open, a red run comments on it and opens no other.
local function test_a_red_run_comments_on_the_open_issue()
  local c, calls, bodies = fake("timed_out", { issues = open_issue, jobs = failed_jobs })
  local said = MainRed.follow(c)
  assert(said == "main is still red at aea966032: commented on #12", said)
  assert(calls[#calls] == "POST /repos/owner/repo/issues/12/comments", table.concat(calls, "|"))
  assert(assert(bodies[1]):find("Still red.", 1, true) ~= nil, bodies[1])
end

--- A passing run, the newest of main's that passed or failed, comments
--- and closes the open issue.
local function test_a_green_run_closes_the_issue()
  local c, calls, bodies = fake("success", { issues = open_issue,
    runs = '{"workflow_runs":[{"id":80,"conclusion":"cancelled"},{"id":77,"conclusion":"success"}]}' })
  local said = MainRed.follow(c)
  assert(said == "main is green again at aea966032: closed #12", said)
  assert(calls[#calls - 1] == "POST /repos/owner/repo/issues/12/comments" and
      calls[#calls] == "PATCH /repos/owner/repo/issues/12", table.concat(calls, "|"))
  assert(assert(bodies[2]) == '{"state":"closed"}', bodies[2])
end

--- A passing run of an older commit (made again) leaves the issue open
--- while a newer run of main has failed.
local function test_an_older_green_run_leaves_the_issue_open()
  local c, calls = fake("success", { issues = open_issue,
    runs = '{"workflow_runs":[{"id":80,"conclusion":"failure"},{"id":77,"conclusion":"success"}]}' })
  local said = MainRed.follow(c)
  assert(said:find("a newer push run ended since", 1, true) ~= nil, said)
  for _, call in ipairs(calls) do assert(call:sub(1, 4) == "GET ", call) end
end

--- A failed run of an older commit, made again, opens no issue while a
--- newer run of main passed, and comments on none.
local function test_an_older_red_run_says_nothing_of_main()
  local c, calls = fake("failure", { jobs = failed_jobs,
    runs = '{"workflow_runs":[{"id":80,"conclusion":"success"},{"id":77,"conclusion":"failure"}]}' })
  local said = MainRed.follow(c)
  assert(said:find("a newer push run ended since", 1, true) ~= nil, said)
  for _, call in ipairs(calls) do assert(call:sub(1, 4) == "GET ", call) end
end

--- A pull request labelled `main-red` is not the issue: a red run opens
--- one, and a green run closes nothing.
local function test_a_labelled_pull_request_is_not_the_issue()
  local listed = '[{"number":9,"pull_request":{"url":"x"}}]'
  local c, calls = fake("failure", { issues = listed, jobs = failed_jobs })
  assert(MainRed.follow(c):find("opened an issue", 1, true) ~= nil)
  assert(calls[#calls] == "POST /repos/owner/repo/issues", table.concat(calls, "|"))
  local green, asked = fake("success", { issues = listed })
  assert(MainRed.follow(green) == "main is green at aea966032: no issue is open")
  for _, call in ipairs(asked) do assert(call:sub(1, 4) == "GET ", call) end
end

--- A label that is there already (a 422) does not stop the issue; any
--- other refusal of it fails the job.
local function test_a_label_there_already_is_taken()
  local c, calls = fake("failure", { jobs = failed_jobs, label_status = 422 })
  assert(MainRed.follow(c):find("opened an issue", 1, true) ~= nil)
  assert(calls[#calls] == "POST /repos/owner/repo/issues", table.concat(calls, "|"))
  local refused, _ = fake("failure", { jobs = failed_jobs, label_status = 403 })
  assert(MainRed.command({}, refused) == 1)
end

--- With no issue open, a green run does nothing; a cancelled run, or a
--- run of another event or branch, says nothing of main.
local function test_what_says_nothing_of_main_changes_nothing()
  local c, calls = fake("success", {})
  assert(MainRed.follow(c) == "main is green at aea966032: no issue is open")
  assert(#calls == 1, table.concat(calls, "|"))
  local cancelled, asked = fake("cancelled", { issues = open_issue })
  assert(MainRed.follow(cancelled):find("says nothing of main", 1, true) ~= nil)
  for _, call in ipairs(asked) do assert(call:sub(1, 4) == "GET ", call) end
  local other, none = fake("failure", {}, "workflow_dispatch")
  assert(MainRed.follow(other) == "a workflow_dispatch run of main: nothing follows")
  local branch, nothing = fake("failure", {}, "push", "claude/x")
  assert(MainRed.follow(branch) == "a push run of claude/x: nothing follows")
  assert(#none == 0 and #nothing == 0)
end

--- The command runs on a context, and refuses an argument.
local function test_the_command_takes_no_argument()
  local c, _ = fake("failure", { jobs = failed_jobs })
  assert(MainRed.command({}, c) == 0)
  assert(MainRed.command({ "extra" }, c) == 1)
end

--- The context names a variable the job's environment lacks.
local function test_the_context_names_what_is_missing()
  local env: mut {string:string} = { GH_TOKEN = "t", REPOSITORY = "owner/repo", EVENT = "push",
    CONCLUSION = "failure", BRANCH = "main", SHA = "abc", URL = "https://github.test/runs/1" }
  local ok, why = pcall(MainRed.context, env)
  assert(not ok and tostring(why):find("RUN_ID is not set", 1, true) ~= nil, tostring(why))
  env["RUN_ID"] = "1"
  local c = MainRed.context(env)
  assert(c.run_id == "1" and c.title == "", c.run_id)
end
