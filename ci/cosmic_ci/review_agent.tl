--- The weekly review's publish step: what `ci/agents/weekly-review.md`
--- made, sent to GitHub.
---
--- The review runs in `.github/workflows/review.yml`, in two jobs. The
--- agent's job holds no token that can write: the agent commits each fix
--- on a local `weekly-review/<slug>` branch and writes what it found under
--- `.review-out/`, and the job keeps that directory, with a bundle of the
--- branches, as an artifact. The publish job checks main out again, runs
--- none of the agent's code, and gives `review-publish` the artifact and
--- the token of a GitHub App that cannot bypass main's ruleset. For each
--- pull request the output names, `publish` takes the branch from the
--- bundle, refuses one that changes nothing or changes `.github/` (where
--- a workflow could take a later job's secrets), pushes it, and opens a
--- draft pull request. It then opens the report as an issue, with each
--- pull request, or why it was not opened, added at its end.
---
--- The output is a directory: `report.md`, and `pulls/<slug>.md` for each
--- fix, whose branch `weekly-review/<slug>` is in `review.bundle`. The
--- first line of each file is its title, and the rest its body.
local ChangedPaths = require("cosmic_ci.changed_paths")
local Codec = require("cosmic.codec")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local GithubApi = require("cosmic_ci.github_api")
local Json = require("cosmic.json")
local Plural = require("cosmic_ci.plural")

local record ReviewAgent
  --- A title and its body, as an output file holds them.
  record Text
    title: string
    body: string
  end
  --- A fix the agent made: its branch's slug and its pull request's text.
  record Draft
    slug: string
    title: string
    body: string
  end
  --- What the agent made: the report, the fixes, and each file under
  --- `pulls/` that was refused, with why.
  record Output
    report: Text
    drafts: {Draft}
    refused: {string}
  end
  --- What `publish` reaches the world with. `git` runs in the checkout;
  --- `push` is `git` with the token, for the push alone.
  record Tools
    git: ChangedPaths.Git
    push: ChangedPaths.Git
    github: GithubApi.Client
  end
  --- What `publish` came to: the report's issue (nil where none was
  --- opened, and `trouble` says why) and how many fixes were not opened.
  record Published
    issue?: string
    failed: integer
    trouble: string
  end
  record Pull
    title: string
    head: string
    base: string
    body: string
    draft: boolean
  end
  record Issue
    title: string
    body: string
  end
end

local repository <const> = "cosmic-lua/cosmic"
--- The branches the agent may open a pull request from.
local branch_prefix <const> = "weekly-review/"
--- Where `publish` keeps a fetched branch, apart from every other ref.
local fetched_prefix <const> = "refs/review/"
--- The most pull requests one run opens.
local most_drafts <const> = 3
--- GitHub takes a body of at most 65536 characters: a longer one is cut.
local most_body <const> = 60000
local most_title <const> = 200
--- No run of git is given longer.
local git_seconds <const> = 600

--- `text` cut to `most` characters, saying so where it was cut.
local function clip(text: string, most: integer): string
  if #text <= most then return text end
  return text:sub(1, most) .. "\n\n(cut: the text was " .. Plural.count(#text, "character") .. ")"
end

--- The token shapes a published text must not hold: Claude API keys and
--- GitHub tokens.
local secret_patterns <const> = { "sk%-ant%-[%w_%-]+", "gh[opsur]_[%w]+", "github_pat_[%w_]+" }

--- `text` made fit to publish in a public repository: each secret's
--- shape redacted, and each `@` that would mention or notify someone
--- followed by a zero-width space, so it does not.
function ReviewAgent.tame(text: string): string
  local out = text
  for _, pattern in ipairs(secret_patterns) do out = (out:gsub(pattern, "[redacted]")) end
  return (out:gsub("@([%w_%-])", "@\u{200B}%1"))
end

--- The title and body of an output file: its first line, without a
--- Markdown heading's `#`s, and the rest. Nil and why where the title is
--- empty or too long.
function ReviewAgent.split(text: string): ReviewAgent.Text?, string
  local newline = text:find("\n", 1, true)
  local first, rest = text, ""
  if newline ~= nil then first, rest = text:sub(1, newline - 1), text:sub(newline + 1) end
  local title = ReviewAgent.tame((first:gsub("^#+%s*", ""):gsub("%s+$", "")))
  if title == "" then return nil, "the first line, the title, is empty" end
  if #title > most_title then
    return nil, "the title is longer than " .. Plural.count(most_title, "character")
  end
  return { title = title, body = clip(ReviewAgent.tame((rest:gsub("^%s+", ""))), most_body) }, ""
end

--- Whether `slug` may name a branch: lower-case letters, digits and
--- dashes, from a letter or a digit, so git reads it as no option.
local function good_slug(slug: string): boolean
  return #slug <= 80 and slug:match("^[a-z0-9][a-z0-9-]*$") ~= nil
end

--- The output in `dir`, or nil and why where it has no report. A file
--- under `pulls/` that names no slug, and those past the third, are
--- refused, each with why.
function ReviewAgent.read_output(dir: string): ReviewAgent.Output?, string
  local text, why = Fs.read(dir .. "/report.md")
  if text == nil then return nil, why end
  local report, trouble = ReviewAgent.split(text)
  if report == nil then return nil, "report.md: " .. trouble end
  local drafts: mut {ReviewAgent.Draft} = {}
  local refused: mut {string} = {}
  local names: {string} = {}
  local present, _ = Fs.exists(dir .. "/pulls")
  if present == true then
    local listed, list_trouble = Fs.list(dir .. "/pulls")
    if listed == nil then return nil, list_trouble end
    names = listed
  end
  for _, name in ipairs(names) do
    local slug = name:match("^(.*)%.md$")
    if slug == nil or not good_slug(slug) then
      refused[#refused + 1] = "pulls/" .. name .. ": not <slug>.md, with a slug of a-z, 0-9 and -"
    elseif #drafts == most_drafts then
      refused[#refused + 1] = "pulls/" .. name .. ": past the " .. tostring(most_drafts) .. " a run opens"
    else
      local file, read_trouble = Fs.read(dir .. "/pulls/" .. name)
      local split: ReviewAgent.Text? = nil
      local split_trouble = read_trouble
      if file ~= nil then split, split_trouble = ReviewAgent.split(file) end
      if split == nil then
        refused[#refused + 1] = "pulls/" .. name .. ": " .. split_trouble
      else
        drafts[#drafts + 1] = { slug = slug, title = split.title, body = split.body }
      end
    end
  end
  return { report = report, drafts = drafts, refused = refused }, ""
end

--- Why the fetched branch of `slug` may not be pushed, or "" where it
--- may: it must share history with main, hold no merge (whose many
--- bases could hide a change from the diff), change something, and
--- change nothing under `.github/`.
function ReviewAgent.check(git: ChangedPaths.Git, slug: string): string
  local merges = git({ "rev-list", "--merges", "origin/main.." .. fetched_prefix .. slug, "--" }, git_seconds)
  if not merges.ok then return "the bundle holds no such branch" end
  if merges.output ~= "" then return "it holds a merge" end
  local ran = git({ "diff", "--name-only", "--no-renames", "-z",
    "origin/main..." .. fetched_prefix .. slug, "--" }, git_seconds)
  if not ran.ok then return "the bundle holds no such branch, or it shares no history with main" end
  if ran.output == "" then return "it changes nothing" end
  for path in ran.output:gmatch("[^%z]+") do
    if path:sub(1, #".github/") == ".github/" then return "it changes " .. path end
  end
  return ""
end

--- The string at `field` of the JSON object `text`, nil where there is none.
local function field_of(text: string, field: string): string?
  local object, _ = Json.decode_object(text)
  if object == nil then return nil end
  local value, _ = Json.get(object, { field })
  if value is string and value ~= "" then return value end
  return nil
end

--- Opens a draft pull request from `head` into main of `repo`: its URL,
--- or nil and why. A branch outside `weekly-review/` is refused unsent.
function ReviewAgent.draft_pr(client: GithubApi.Client, repo: string, head: string,
                              title: string, body: string): string?, string
  if head:sub(1, #branch_prefix) ~= branch_prefix or #head == #branch_prefix then
    return nil, "the branch must start with " .. branch_prefix .. ": " .. head
  end
  local pull: ReviewAgent.Pull = { title = title, head = head, base = "main", body = body, draft = true }
  local answer, why = GithubApi.object(client, "POST", "repos/" .. repo .. "/pulls", pull)
  if answer == nil then return nil, why end
  local url = field_of(answer, "html_url")
  if url == nil then return nil, "the answer names no html_url" end
  return url, ""
end

--- Opens an issue in `repo`: its URL, or nil and why.
function ReviewAgent.issue(client: GithubApi.Client, repo: string, title: string,
                           body: string): string?, string
  local issue: ReviewAgent.Issue = { title = title, body = body }
  local answer, why = GithubApi.object(client, "POST", "repos/" .. repo .. "/issues", issue)
  if answer == nil then return nil, why end
  local url = field_of(answer, "html_url")
  if url == nil then return nil, "the answer names no html_url" end
  return url, ""
end

--- Publishes the output in `dir` to `repo`: each fix that passes
--- [`ReviewAgent.check`] pushed and opened as a draft, then the report.
function ReviewAgent.publish(tools: ReviewAgent.Tools, dir: string, repo: string): ReviewAgent.Published
  local output, why = ReviewAgent.read_output(dir)
  if output == nil then return { failed = 0, trouble = why } end
  if #output.drafts > 0 then
    -- A bundle that is missing, or holds no weekly-review/ branch, fetches
    -- nothing: each check below then finds no branch.
    local _ = tools.git({ "fetch", "--no-tags", "--", dir .. "/review.bundle",
      "+refs/heads/" .. branch_prefix .. "*:" .. fetched_prefix .. "*" }, git_seconds)
  end
  local lines: mut {string} = {}
  local failed = #output.refused
  for _, draft in ipairs(output.drafts) do
    local head = branch_prefix .. draft.slug
    local trouble = ReviewAgent.check(tools.git, draft.slug)
    local url: string? = nil
    if trouble == "" then
      local pushed = tools.push({ "push", "--", "https://github.com/" .. repo .. ".git",
        fetched_prefix .. draft.slug .. ":refs/heads/" .. head }, git_seconds)
      if not pushed.ok then trouble = "the push failed (the job's log says why)" end
    end
    if trouble == "" then
      url, trouble = ReviewAgent.draft_pr(tools.github, repo, head, draft.title, draft.body)
    end
    if url ~= nil then
      lines[#lines + 1] = "- " .. url
    else
      failed = failed + 1
      lines[#lines + 1] = "- " .. head .. ": not opened: " .. trouble
    end
  end
  for _, refusal in ipairs(output.refused) do
    lines[#lines + 1] = "- " .. refusal .. ": not opened"
  end
  if #lines == 0 then lines[1] = "none" end
  local body = output.report.body .. "\n\n## pull requests\n\n" .. table.concat(lines, "\n") .. "\n"
  local issued, trouble = ReviewAgent.issue(tools.github, repo, output.report.title, body)
  return { issue = issued, failed = failed, trouble = trouble }
end

--- `env` with git told to send `token` to github.com, through the
--- environment: neither argv nor `.git/config` holds it.
function ReviewAgent.push_env(env: {string:string}, token: string): {string:string}
  local out: mut {string:string} = {}
  for key, value in pairs(env) do out[key] = value end
  out["GIT_TERMINAL_PROMPT"] = "0"
  out["GIT_CONFIG_COUNT"] = "1"
  out["GIT_CONFIG_KEY_0"] = "http.https://github.com/.extraheader"
  out["GIT_CONFIG_VALUE_0"] = "AUTHORIZATION: basic " .. Codec.base64("x-access-token:" .. token)
  return out
end

local function complain(text: string): integer
  local _, _ = Fs.put(Fs.stderr, "review: " .. text .. "\n")
  return 1
end

--- `review-publish DIR`, from `ci/`, with the App's token as GH_TOKEN.
function ReviewAgent.publish_command(argv: {string}): integer
  local dir = argv[1]
  if dir == nil or argv[2] ~= nil then return complain("usage: review-publish DIR") end
  local env = Env.all()
  local github, why = GithubApi.live(env)
  if github == nil then return complain(why) end
  -- The App's token alone: the workflow's own, as GITHUB_TOKEN, cannot push.
  local token = env["GH_TOKEN"]
  if token == nil or token == "" then return complain("set GH_TOKEN to the App's token") end
  local tools: ReviewAgent.Tools = { git = ChangedPaths.live_git(env),
    push = ChangedPaths.live_git(ReviewAgent.push_env(env, token)), github = github }
  local published = ReviewAgent.publish(tools, dir, repository)
  local issue = published.issue
  if issue == nil then return complain(published.trouble) end
  local _, _ = Fs.put(Fs.stdout, "review: the report is " .. issue .. "\n")
  if published.failed > 0 then
    return complain(Plural.count(published.failed, "fix", "fixes") .. " not opened; the report says why")
  end
  return 0
end

return ReviewAgent
