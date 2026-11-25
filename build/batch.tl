--- Integration batches: several ready pull requests land through the
--- merge queue as one pull request, one commit for each.
---
---     bin/cosmic build/batch.tl stack BRANCH N...
---     bin/cosmic build/batch.tl close BATCH
---
--- `stack` checks out BRANCH fresh from origin's main and squashes each
--- pull request N onto it in the order given, as one commit titled
--- `<title> (#N)` whose body is the member's own commit messages. A
--- member is left out, and the reason said, when it is not
--- open, has no green `ci` check at its head, or does not apply on what
--- is stacked before it. It writes the batch pull request's body to
--- standard output; the caller pushes BRANCH and opens the pull request.
--- The repository's squash setting (COMMIT_MESSAGES) keeps each
--- member's message in main's commit.
---
--- `close` reads a merged batch pull request's commits, and closes each
--- member whose head is still the one batched, with a comment that names
--- the batch's commit on main. A member pushed since it was batched
--- stays open, and is named.
---
--- It runs the host's `git` and `gh` (its REST API alone), found on PATH.
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Shape = require("cosmic.shape")

local REPO <const> = "cosmic-lua/cosmic"
local TIMEOUT_NS <const> = 120 * 1000000000

local record Ran
  ok: boolean
  out: string
  err: string
end

local record Head
  sha: string
end

local record Base
  ref: string
end

local record Pull
  title: string
  base: Base
  state: string
  draft: boolean
  merged: boolean?
  merge_commit_sha: string?
  head: Head
end
local PULL <const> = Shape.record_of("Pull"):lenient()

local record CheckRun
  name: string
  status: string
  conclusion: string?
end

local record CheckRuns
  check_runs: {CheckRun}
end
local CHECK_RUNS <const> = Shape.record_of("CheckRuns"):lenient()

local record CommitText
  message: string
end

local record Commit
  commit: CommitText
end

local record Commits
  commits: {Commit}
end
local COMMITS <const> = Shape.record_of("Commits"):lenient()

local function say(text: string)
  local _, _ = Fs.put(Fs.stderr, "batch: " .. text .. "\n")
end

local function run(argv: {string}, input?: string): Ran
  local name = argv[1]
  if name == nil then return { ok = false, out = "", err = "no program" } end
  local path, missing = Proc.find(name, Env.get("PATH"))
  if path == nil then return { ok = false, out = "", err = tostring(missing) } end
  local full: mut {string} = { path }
  for i = 2, #argv do full[#full + 1] = argv[i] end
  local result, failure = Child.run(full, { timeout_ns = TIMEOUT_NS, stdout = "capture",
    stderr = "capture", input = input })
  if result == nil then return { ok = false, out = "", err = tostring(failure) } end
  return { ok = result.ok, out = result.stdout or "", err = result.stderr or "" }
end

local function git(argv: {string}): Ran
  local full: mut {string} = { "git" }
  for _, word in ipairs(argv) do full[#full + 1] = word end
  return run(full)
end

local function trimmed(text: string): string
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- The text of the REST API's reply at `path`, or nil and why.
local function api(path: string): string?, string
  local ran = run({ "gh", "api", path })
  if not ran.ok then return nil, trimmed(ran.err) end
  return ran.out, ""
end

local function pull(n: string): Pull?, string
  local text, why = api("repos/" .. REPO .. "/pulls/" .. n)
  if text == nil then return nil, why end
  local value, wrong = PULL:decode_into(text)
  if value == nil then return nil, tostring(wrong) end
  return value, ""
end

--- Why pull request `pr` cannot be batched, or nil.
local function refusal(pr: Pull): string?
  if pr.state ~= "open" then return "not open" end
  if pr.base.ref ~= "main" then return "for " .. pr.base.ref .. ", not main" end
  local text, why = api("repos/" .. REPO .. "/commits/" .. pr.head.sha .. "/check-runs?per_page=100")
  if text == nil then return "its checks could not be read: " .. why end
  local checks, wrong = CHECK_RUNS:decode_into(text)
  if checks == nil then return "its checks could not be read: " .. tostring(wrong) end
  local green = false
  for _, check in ipairs(checks.check_runs) do
    if check.name == "ci" then
      if check.status ~= "completed" then return "its ci check is still running" end
      if check.conclusion ~= "success" then
        return "a ci check at its head is " .. tostring(check.conclusion)
      end
      green = true
    end
  end
  if not green then return "no green ci check at its head" end
  return nil
end

--- The member's own commit messages since `base`, without session and
--- co-author lines, which the batch commit carries once.
local function messages(base: string, head: string): string
  local ran = git({ "log", "--no-merges", "--format=%B%x00", base .. ".." .. head })
  local kept: mut {string} = {}
  for message in ran.out:gmatch("([^%z]*)%z") do
    local lines: mut {string} = {}
    for line in (message .. "\n"):gmatch("([^\n]*)\n") do
      if not line:match("^Claude%-Session:") and not line:match("^Co%-Authored%-By:") and
          not line:match("Batched from #") then
        lines[#lines + 1] = line
      end
    end
    local text = trimmed(table.concat(lines, "\n"))
    if text ~= "" then kept[#kept + 1] = text end
  end
  return table.concat(kept, "\n\n")
end

--- Stacks one member on the checked-out batch: its line for the body,
--- or nil and why it was left out.
local function stack_one(main: string, n: string): string?, string
  local pr, unread = pull(n)
  if pr == nil then return nil, "cannot be read: " .. unread end
  local why = refusal(pr)
  if why ~= nil then return nil, why end
  local head = pr.head.sha
  if not git({ "fetch", "-q", "origin", head }).ok then return nil, "its head cannot be fetched" end
  local merged = git({ "merge", "--squash", "-q", head })
  if not merged.ok then
    local conflicted = trimmed(git({ "diff", "--name-only", "--diff-filter=U" }).out):gsub("\n", " ")
    git({ "reset", "-q", "--hard", "HEAD" })
    if conflicted == "" then return nil, "it does not apply: " .. trimmed(merged.err) end
    return nil, "conflicts in " .. conflicted
  end
  local base = trimmed(git({ "merge-base", main, head }).out)
  if base == "" then
    git({ "reset", "-q", "--hard", "HEAD" })
    return nil, "it shares no history with main"
  end
  local message = pr.title .. " (#" .. n .. ")\n\n" .. messages(base, head) ..
    "\n\nBatched from #" .. n .. " at " .. head:sub(1, 9) .. ".\n"
  local committed = run({ "git", "commit", "-q", "-F", "-" }, message)
  if not committed.ok then
    git({ "reset", "-q", "--hard", "HEAD" })
    return nil, "its commit failed: " .. trimmed(committed.err)
  end
  return "- #" .. n .. " " .. pr.title .. " (head " .. head:sub(1, 9) .. ")", ""
end

local function stack(branch: string, numbers: {string}): integer
  if not git({ "fetch", "-q", "origin", "main" }).ok then
    say("cannot fetch main")
    return 1
  end
  if trimmed(git({ "status", "--porcelain", "--untracked-files=no" }).out) ~= "" then
    say("the working tree has changes; commit or stash them first")
    return 1
  end
  local main = trimmed(git({ "rev-parse", "origin/main" }).out)
  if not main:match("^%x+$") then
    say("cannot read origin/main")
    return 1
  end
  if not git({ "checkout", "-q", "-B", branch, main }).ok then
    say("cannot check out " .. branch)
    return 1
  end
  local taken: mut {string} = {}
  for _, n in ipairs(numbers) do
    local line, why = stack_one(main, n)
    if line == nil then
      say("#" .. n .. " left out: " .. why)
    else
      taken[#taken + 1] = line
      say("#" .. n .. " stacked")
    end
  end
  if #taken == 0 then
    say("nothing stacked")
    return 1
  end
  local _, _ = Fs.put(Fs.stdout, "An integration batch on main " .. main:sub(1, 9) ..
      ": each member below is one commit, run through the merge queue once. When it lands, each member " ..
      "is closed with a link; if its run fails, the culprit is dropped and the rest goes again.\n\n" ..
      table.concat(taken, "\n") .. "\n")
  return 0
end

local function close_one(batch: string, landed: string, n: string, head: string): boolean
  local member, why = pull(n)
  if member == nil then
    say("#" .. n .. " cannot be read: " .. why)
    return false
  end
  if member.state ~= "open" then
    say("#" .. n .. " is not open")
    return true
  end
  if #head ~= 9 or member.head.sha:sub(1, 9) ~= head then
    say("#" .. n .. " moved to " .. member.head.sha:sub(1, 9) .. " since it was batched at " .. head ..
        "; left open")
    return false
  end
  local body = "Landed on main in " .. landed:sub(1, 9) .. " as part of batch #" .. batch ..
    ", which carried this pull request at " .. head ..
    ".\n\n---\n_Generated by [Claude Code](https://claude.ai/code)_"
  local shut = run({ "gh", "api", "-X", "PATCH", "repos/" .. REPO .. "/pulls/" .. n, "-f", "state=closed" })
  if not shut.ok then
    say("#" .. n .. " could not be closed: " .. trimmed(shut.err))
    return false
  end
  local said = run({ "gh", "api", "-X", "POST", "repos/" .. REPO .. "/issues/" .. n .. "/comments",
    "-f", "body=" .. body })
  if not said.ok then
    say("#" .. n .. " closed, but its comment failed: " .. trimmed(said.err))
    return false
  end
  say("#" .. n .. " closed")
  return true
end

local function close(batch: string): integer
  local pr, why = pull(batch)
  if pr == nil then
    say("#" .. batch .. " cannot be read: " .. why)
    return 1
  end
  local landed = pr.merge_commit_sha
  if pr.merged ~= true or landed == nil then
    say("#" .. batch .. " is not merged")
    return 1
  end
  local text, unread = api("repos/" .. REPO .. "/pulls/" .. batch .. "/commits?per_page=100")
  if text == nil then
    say("its commits cannot be read: " .. unread)
    return 1
  end
  local commits, wrong = COMMITS:decode_into('{"commits":' .. text .. "}")
  if commits == nil then
    say("its commits cannot be read: " .. tostring(wrong))
    return 1
  end
  local status = 0
  for _, commit in ipairs(commits.commits) do
    -- The trailer is the message's last line, which stack writes; a
    -- member's own text above it cannot name another pull request.
    local n, head = commit.commit.message:match("\nBatched from #(%d+) at (%x%x%x%x%x%x%x%x%x)%.%s*$")
    if n ~= nil and head ~= nil and not close_one(batch, landed, n, head) then status = 1 end
  end
  return status
end

return function(argv: {string}): integer
  local verb = argv[1]
  local first = argv[2]
  if verb == "stack" and first ~= nil and #argv >= 3 then
    if first == "main" or not first:match("^[%w][%w._/-]*$") then
      say("BRANCH must be a new branch's name, not main: " .. first)
      return 2
    end
    local numbers: mut {string} = {}
    for i, word in ipairs(argv) do
      if i >= 3 then
        if not word:match("^%d+$") then
          say("N must be a pull request's number: " .. word)
          return 2
        end
        numbers[#numbers + 1] = word
      end
    end
    return stack(first, numbers)
  elseif verb == "close" and first ~= nil and #argv == 2 and first:match("^%d+$") ~= nil then
    return close(first)
  end
  say("usage: batch.tl stack BRANCH N... | close BATCH")
  return 2
end
