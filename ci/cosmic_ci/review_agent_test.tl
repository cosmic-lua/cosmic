local ChangedPaths = require("cosmic_ci.changed_paths")
local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local GithubApi = require("cosmic_ci.github_api")
local Json = require("cosmic.json")
local ReviewAgent = require("cosmic_ci.review_agent")

--- The string the JSON `body` holds at `steps`, nil where it holds none.
local function at(body: string?, steps: {string | integer}): string?
  local object = assert(Json.decode_object(assert(body)))
  local value, _ = Json.get(object, steps)
  if value is string then return value end
  return nil
end

--- The boolean the JSON `body` holds at `steps`, nil where it holds none.
local function flag(body: string?, steps: {string | integer}): boolean?
  local object = assert(Json.decode_object(assert(body)))
  local value, _ = Json.get(object, steps)
  if value is boolean then return value end
  return nil
end

--- A GitHub client that answers each request with the next of
--- `answers`, the last one again once they run out; `sent` collects the
--- requests.
local function github(answers: {string}): GithubApi.Client, {GithubApi.Request}
  local sent: mut {GithubApi.Request} = {}
  local function send(request: GithubApi.Request): GithubApi.Reply?, string
    sent[#sent + 1] = request
    local answer = answers[#sent] or answers[#answers]
    return { status = 201, headers = {}, body = assert(answer) }, ""
  end
  local function fetch(_url: string, _path: string): boolean, string return false, "no fetch" end
  return { send = send, fetch = fetch, base = "https://api.test" }, sent
end

--- A git that answers `diff` for a branch with `diffs[branch]` (failing
--- where there is none), `rev-list --merges` with a merge for the branch
--- `merged`, and every other command with success; `ran` collects each
--- argv, joined by spaces.
local function git(diffs: {string:string}, merged?: string): ChangedPaths.Git, {string}
  local ran: mut {string} = {}
  return function(argv: {string}, _seconds: integer): ChangedPaths.Ran
    local line = table.concat(argv, " ")
    ran[#ran + 1] = line
    if argv[1] == "rev-list" then
      local merging = merged ~= nil and assert(argv[3]) == "origin/main..refs/review/" .. merged
      if merging then return { ok = true, output = "abc123\n" } end
      return { ok = true, output = "" }
    end
    if argv[1] ~= "diff" then return { ok = true, output = "" } end
    local branch = assert(argv[5]):match("^origin/main%.%.%.refs/review/(.*)$")
    local output = diffs[tostring(branch)]
    if output == nil then return { ok = false, output = "" } end
    return { ok = true, output = output }
  end, ran
end

--- An output directory under `tmp`: `report` as report.md, and each of
--- `pulls` under pulls/.
local function output(tmp: string, report: string, pulls: {string:string}): string
  local dir = tmp .. "/out"
  assert(Fs.mkdirs(dir .. "/pulls"))
  assert(Fs.write(dir .. "/report.md", report))
  for name, text in pairs(pulls) do assert(Fs.write(dir .. "/pulls/" .. name, text)) end
  return dir
end

local function test_a_title_is_the_first_line_without_its_heading()
  local text = assert(ReviewAgent.split("# weekly review 2026-11-28  \n\nthe body\n"))
  assert(text.title == "weekly review 2026-11-28" and text.body == "the body\n", text.title)
  text = assert(ReviewAgent.split("one line"))
  assert(text.title == "one line" and text.body == "")
  local none, why = ReviewAgent.split("#\nbody")
  assert(none == nil and why:find("empty", 1, true) ~= nil, why)
  none, why = ReviewAgent.split(string.rep("x", 201))
  assert(none == nil and why:find("longer", 1, true) ~= nil, why)
  local long = assert(ReviewAgent.split("t\n" .. string.rep("y", 70000)))
  assert(#long.body < 65536 and long.body:find("(cut: the text was 70000 characters)", 1, true) ~= nil)
end

local function test_files_past_the_third_or_with_a_bad_name_are_refused(tmp: string)
  local dir = output(tmp, "report\nbody", { ["a.md"] = "A\n", ["b.md"] = "B\n", ["c.md"] = "C\n",
    ["d.md"] = "D\n", ["-x.md"] = "X\n", ["Up.md"] = "U\n", ["notes.txt"] = "N\n", ["e.md"] = "\n" })
  local read = assert(ReviewAgent.read_output(dir))
  local slugs: mut {string} = {}
  for _, draft in ipairs(read.drafts) do slugs[#slugs + 1] = draft.slug .. "=" .. draft.title end
  assert(table.concat(slugs, ",") == "a=A,b=B,c=C", table.concat(slugs, ","))
  local refused = table.concat(read.refused, "\n")
  for _, name in ipairs({ "-x.md", "Up.md", "notes.txt", "d.md", "e.md" }) do
    assert(refused:find("pulls/" .. name, 1, true) ~= nil, refused)
  end
end

local function test_there_is_no_output_without_a_report(tmp: string)
  local none, why = ReviewAgent.read_output(tmp)
  assert(none == nil and why ~= "", why)
end

local function test_a_branch_is_checked_against_main()
  local run = git({ ok = "lib/a.tl\0lib/a_test.tl\0", empty = "",
    workflow = "lib/a.tl\0.github/workflows/ci.yml\0" })
  assert(ReviewAgent.check(run, "ok") == "")
  assert(ReviewAgent.check(run, "empty") == "it changes nothing")
  assert(ReviewAgent.check(run, "workflow") == "it changes .github/workflows/ci.yml")
  assert(ReviewAgent.check(run, "missing"):find("no such branch", 1, true) ~= nil)
  assert(ReviewAgent.check(git({ ok = "lib/a.tl\0" }, "ok"), "ok") == "it holds a merge")
end

local function test_published_text_mentions_no_one_and_holds_no_token()
  local text = assert(ReviewAgent.split("ask @whilp\nkey sk-ant-api03-abc_D-e and ghs_AbC123 and github_pat_x_1, mail a@b"))
  assert(text.title == "ask @\u{200B}whilp", text.title)
  assert(text.body == "key [redacted] and [redacted] and [redacted], mail a@\u{200B}b", text.body)
end

local function test_publish_pushes_each_good_fix_opens_it_and_then_the_report(tmp: string)
  local dir = output(tmp, "# weekly review 2026-11-28\nthe report", {
    ["2026-11-28-fix.md"] = "fix the thing\nhow", ["2026-11-28-bad.md"] = "touch ci\nwhy" })
  local plain, ran = git({ ["2026-11-28-fix"] = "lib/a.tl\0", ["2026-11-28-bad"] = ".github/x.yml\0" })
  local push, pushed = git({})
  local client, sent = github({ '{"html_url":"https://github.test/o/r/pull/7"}',
    '{"html_url":"https://github.test/o/r/issues/8"}' })
  local published = ReviewAgent.publish({ git = plain, push = push, github = client }, dir, "o/r")
  assert(published.issue == "https://github.test/o/r/issues/8", published.trouble)
  assert(published.failed == 1)
  assert(assert(ran[1]) == "fetch --no-tags -- " .. dir .. "/review.bundle +refs/heads/weekly-review/*:refs/review/*",
    ran[1])
  -- Only the good fix is pushed, and only through `push`.
  assert(#pushed == 1 and pushed[1] == "push -- https://github.com/o/r.git " ..
      "refs/review/2026-11-28-fix:refs/heads/weekly-review/2026-11-28-fix", pushed[1])
  for _, line in ipairs(ran) do assert(line:sub(1, 4) ~= "push", line) end
  assert(#sent == 2)
  local pull = assert(sent[1])
  assert(pull.url == "https://api.test/repos/o/r/pulls", pull.url)
  assert(at(pull.body, { "head" }) == "weekly-review/2026-11-28-fix")
  assert(at(pull.body, { "base" }) == "main")
  assert(at(pull.body, { "title" }) == "fix the thing")
  assert(flag(pull.body, { "draft" }) == true)
  local issue = assert(sent[2])
  assert(issue.url == "https://api.test/repos/o/r/issues", issue.url)
  assert(at(issue.body, { "title" }) == "weekly review 2026-11-28")
  local body = tostring(at(issue.body, { "body" }))
  assert(body:find("the report\n\n## pull requests\n\n", 1, true) == 1, body)
  assert(body:find("- https://github.test/o/r/pull/7", 1, true) ~= nil, body)
  assert(body:find("- weekly-review/2026-11-28-bad: not opened: it changes .github/x.yml", 1, true) ~= nil, body)
end

local function test_a_failed_push_opens_no_pull_request_but_the_report_still_says_so(tmp: string)
  local dir = output(tmp, "r\nbody", { ["x.md"] = "x\n" })
  local plain = git({ x = "a.tl\0" })
  local function push(_argv: {string}, _seconds: integer): ChangedPaths.Ran
    return { ok = false, output = "" }
  end
  local client, sent = github({ '{"html_url":"https://github.test/o/r/issues/9"}' })
  local published = ReviewAgent.publish({ git = plain, push = push, github = client }, dir, "o/r")
  assert(published.issue ~= nil and published.failed == 1)
  assert(#sent == 1 and assert(sent[1]).url == "https://api.test/repos/o/r/issues")
  assert(tostring(at(assert(sent[1]).body, { "body" })):find("the push failed", 1, true) ~= nil)
end

local function test_a_run_with_no_fix_still_opens_the_report(tmp: string)
  local dir = output(tmp, "r\nbody", {})
  local plain, ran = git({})
  local client, sent = github({ '{"html_url":"https://github.test/o/r/issues/9"}' })
  local published = ReviewAgent.publish({ git = plain, push = plain, github = client }, dir, "o/r")
  assert(published.issue ~= nil and published.failed == 0 and #ran == 0)
  assert(tostring(at(assert(sent[1]).body, { "body" })):find("## pull requests\n\nnone\n", 1, true) ~= nil)
end

local function test_the_token_reaches_git_through_the_environment_alone()
  local env = ReviewAgent.push_env({ PATH = "/bin" }, "ghs_x")
  assert(env["PATH"] == "/bin" and env["GIT_CONFIG_COUNT"] == "1" and env["GIT_TERMINAL_PROMPT"] == "0")
  assert(env["GIT_CONFIG_KEY_0"] == "http.https://github.com/.extraheader")
  assert(env["GIT_CONFIG_VALUE_0"] == "AUTHORIZATION: basic " .. Codec.base64("x-access-token:ghs_x"))
end

local function test_a_branch_outside_weekly_review_is_refused_unsent()
  local client, sent = github({ "{}" })
  for _, head in ipairs({ "main", "weekly-review/", "feature/weekly-review/x", "Weekly-review/x", " weekly-review/x" }) do
    local url, why = ReviewAgent.draft_pr(client, "o/r", head, "t", "b")
    assert(url == nil and why:find("must start with weekly-review/", 1, true) ~= nil, head .. ": " .. why)
  end
  assert(#sent == 0)
end
