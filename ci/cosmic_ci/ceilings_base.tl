--- The base ci.yml's format check holds the markers of the tree to
--- (build/ceilings_base.tl): the merge base of the run's commit with main,
--- which `driver.tl ceilings-base` finds with the checkout's git alone
--- (SHA, EVENT, REF, in the merge queue BASE_REF, and on a pull request
--- PR_BASE_REF, the branch it is for), from origin with the credentials
--- actions/checkout keeps. It asks GitHub's API nothing: the API's
--- comparison of main with a commit is one GitHub refuses under load
--- (HTTP 500, "this diff is temporarily unavailable"), which failed the
--- job. Never the merge queue's own base (`merge_group.base_sha`): that
--- is the entry ahead, whose markers the commit already holds.
---
--- A pull request for main reads it from the checkout as it is: the run's
--- commit is GitHub's merge of the branch into main, whose first parent is
--- the main it was merged into, and the checkout holds both parents
--- (ci.yml's fetch-depth of 2). Every other run that holds a change (the
--- merge queue's, a manual run of a branch, a pull request for another
--- branch) fetches the commit's history down to main and no further
--- (`git fetch --shallow-exclude=refs/heads/main origin <SHA>`): the
--- commits that fetch cuts off are those with a parent on main, so where
--- they name one parent between them, that parent is the merge base. Where
--- they name several (the branch merged main, or a commit with a parent
--- on main and another off it), the base is main's tip if that is one of
--- them, and otherwise the one parent that main's own history, fetched
--- down to the run's ref, is cut off at, which must be one of them. A
--- commit that is on main already is its own base.
---
--- A fetch is cut off after FETCH_SECONDS (60, 0 for no limit), and one
--- that fails is made again, TRIES (3) in all, after waits of 2 and 4
--- seconds. It writes `sha=<base>` to $GITHUB_OUTPUT (standard output, for
--- a run by hand). A run that must hold a base and finds none fails here,
--- status 1, saying so, and not minutes later in the check, which refuses
--- a change with no base all the same (run the job again); a run of main
--- itself holds none, writes nothing and succeeds.
local ChangedPaths = require("cosmic_ci.changed_paths")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Github = require("cosmic_ci.github")
local StepEnv = require("cosmic_ci.step_env")

local record CeilingsBase
  --- Writes `sha=<base>` to $GITHUB_OUTPUT: 0, or 1 where the run must
  --- hold a base and none was found, 2 where the step cannot be read.
  ceilings_base: function(env: {string:string}, host: Github.Host, git: ChangedPaths.Git): integer
  --- `driver.tl ceilings-base`, in the process's environment.
  ceilings_base_command: function(argv: {string}): integer
end

local whole <const> = StepEnv.whole

--- The branch of main a run is held to: `main` for a push or a manual run, and for the merge queue the branch its entries
--- are queued for (BASE_REF, `refs/heads/main`), nil where it names none.
local function main_of(event: string, base_ref: string): string?
  if event ~= "merge_group" then return "main" end
  local name = base_ref:match("^refs/heads/([%w][%w._/-]*)$")
  return name
end

--- How long a read of the checkout may take, in seconds: a lookup with
--- no fetch.
local LOCAL_SECONDS <const> = 30

--- How a step fetches: the seconds one fetch may take, and how many are
--- made of one that fails.
local record Fetching
  seconds: integer
  tries: integer
end

--- The main a pull request's merge commit `sha` was merged into, its
--- first parent, as the checkout at the working directory holds it; ""
--- where the checkout does not hold it, or it is not a merge of two.
local function merged_into(git: ChangedPaths.Git, sha: string): string
  local ran = git({ "rev-list", "--parents", "-n", "1", sha }, LOCAL_SECONDS)
  if not ran.ok then return "" end
  local commit, first, second, more = ran.output:match("^(%x+) (%x+) (%x+)( ?)")
  if commit ~= sha or more ~= "" or not (Github.is_commit(first or "") and Github.is_commit(second or "")) then
    return ""
  end
  return first or ""
end

--- Whether `git fetch` of `want` from origin, its history cut off at what
--- the ref `exclude` reaches, succeeded: made again after a wait that
--- doubles from 2 seconds, `fetching.tries` in all. A fetch that would
--- bring nothing (all of `want` is reached by `exclude`) fails as one the
--- network failed does.
local function fetched(git: ChangedPaths.Git, host: Github.Host, fetching: Fetching, exclude: string, want: string): boolean
  local wait = 2
  for try = 1, fetching.tries do
    if git({ "fetch", "--quiet", "--no-tags", "--shallow-exclude=" .. exclude, "origin", want }, fetching.seconds).ok then
      return true
    end
    host.print("could not fetch " .. want .. " down to " .. exclude .. " (try " .. tostring(try) .. " of " ..
        tostring(fetching.tries) .. ")")
    if try < fetching.tries then
      host.sleep(wait)
      wait = wait * 2
    end
  end
  return false
end

--- The parents of the commits the checkout's history of `tip` is cut off
--- at, each once: after a fetch that cut it off at a ref, every commit of
--- it with a parent the ref reaches is one, and its parents are hidden
--- from a walk but written in the commit. Nil where git cannot say.
local function cut_off_at(git: ChangedPaths.Git, tip: string): {string}?
  local walked = git({ "rev-list", "--parents", tip }, LOCAL_SECONDS)
  if not walked.ok then return nil end
  local parents: mut {string} = {}
  local seen: mut {string:boolean} = {}
  for line in walked.output:gmatch("[^\n]+") do
    if Github.is_commit(line) then
      local commit = git({ "cat-file", "commit", line }, LOCAL_SECONDS)
      if not commit.ok then return nil end
      -- The header ends at the first empty line; the message after it may hold anything.
      local header = commit.output:match("^(.-)\n\n") or commit.output
      for parent in (header .. "\n"):gmatch("parent (%x+)\n") do
        if seen[parent] ~= true then
          seen[parent] = true
          parents[#parents + 1] = parent
        end
      end
    end
  end
  return parents
end

local function holds(list: {string}, item: string): boolean
  for _, each in ipairs(list) do
    if each == item then return true end
  end
  return false
end

--- The commits origin's `refs` name now, by ref; empty where git cannot
--- say.
local function named_now(git: ChangedPaths.Git, fetching: Fetching, refs: {string}): {string:string}
  local argv: mut {string} = { "ls-remote", "origin" }
  for _, ref in ipairs(refs) do argv[#argv + 1] = ref end
  local ran = git(argv, fetching.seconds)
  local names: mut {string:string} = {}
  if not ran.ok then return names end
  for commit, ref in ran.output:gmatch("(%x+)\t([^\n]+)") do names[ref] = commit end
  return names
end

--- The merge base of the run's commit `sha`, which origin's `ref` names,
--- with origin's branch `main`, and how it was found; "" where it cannot
--- be.
local function grew_from(git: ChangedPaths.Git, host: Github.Host, fetching: Fetching, main: string, sha: string,
                         ref: string): string, string
  local branch = "refs/heads/" .. main
  -- Every way from the commit down to main leaves the fetched history through one of these parents, so one alone is the
  -- merge base. Several may hold a parent that is off main (a commit cut off has all its parents hidden), so they only
  -- bound it.
  local parents: {string} = {}
  local reached = fetched(git, host, fetching, branch, sha)
  if reached then
    parents = cut_off_at(git, sha) or {}
    if #parents == 1 then
      return assert(parents[1]), "the one commit of " .. main .. " its history grew from"
    end
  end
  local now = named_now(git, fetching, { branch, ref })
  local tip = now[branch] or ""
  -- The tip of main as a parent in the commit's history, or as the commit, is an ancestor no commit of main is above.
  if Github.is_commit(tip) and (tip == sha or holds(parents, tip)) then
    return tip, "the tip of " .. main .. ", which its history holds"
  end
  -- Main's own history down to the run's ref: main is one line of commits, so it is cut off at one, whose parent is the
  -- newest commit of main the ref reaches. The ref must still name the run's commit, or that parent says nothing of it.
  if ref:match("^refs/") == nil or not fetched(git, host, fetching, ref, branch) then
    return "", ""
  end
  local head = git({ "rev-parse", "--verify", "--quiet", "FETCH_HEAD^{commit}" }, LOCAL_SECONDS)
  local top = head.output:match("^(%x+)") or ""
  if not head.ok or not Github.is_commit(top) then return "", "" end
  local under = cut_off_at(git, top) or {}
  local base = under[1] or ""
  if #under ~= 1 or not (holds(parents, base) or (not reached and base == sha)) then
    return "", ""
  end
  if named_now(git, fetching, { ref })[ref] ~= sha then
    host.print(ref .. " no longer names " .. sha .. ", so main's history down to it says nothing of this commit")
    return "", ""
  end
  return base, "the commit " .. main .. "'s history down to " .. ref .. " is cut off at"
end

function CeilingsBase.ceilings_base(env: {string:string}, host: Github.Host, git: ChangedPaths.Git): integer
  local seconds, why = whole(env, "FETCH_SECONDS", 60)
  local tries: integer?
  if seconds ~= nil then tries, why = whole(env, "TRIES", 3) end
  if seconds == nil or tries == nil then
    local _, _ = Fs.put(Fs.stderr, "ceilings-base: " .. why .. "\n")
    return 2
  end
  local event, ref, sha = env["EVENT"] or "", env["REF"] or "", env["SHA"] or ""
  -- A run of main itself is held to nothing (its changes were held in the queue); a pull request's run, a manual run of a
  -- branch and the queue's run each hold the merge base of the commit with main. The queue's own base (`merge_group.base_sha`) is the entry
  -- ahead, whose markers the commit already holds, so it is never named here.
  local asks = event == "merge_group" or event == "pull_request" or
    ((event == "push" or event == "workflow_dispatch") and ref ~= "refs/heads/main")
  if not asks then
    host.print("a run of main itself: the markers of the tree are held to no base")
    return 0
  end
  local main = main_of(event, env["BASE_REF"] or "")
  local base, from = "", ""
  if Github.is_commit(sha) and main ~= nil then
    if event == "pull_request" and env["PR_BASE_REF"] == "main" then
      base, from = merged_into(git, sha), "the main this pull request's merge commit was merged into (its first parent)"
      if base == "" then
        host.print("the checkout does not show the commit as a merge of two: fetching its history down to main")
      end
    end
    if base == "" then
      base, from = grew_from(git, host, { seconds = seconds, tries = tries }, main, sha, ref)
    end
  end
  if not Github.is_commit(base) then
    Github.say(host, "no base on main found, so the markers of the tree cannot be held to it and the job fails here: " ..
        "the format check refuses a change with no base rather than let a raised marker through. Run the job again")
    return 1
  end
  host.output("sha=" .. base)
  host.print("the base the markers are held to: " .. base .. ", " .. from)
  return 0
end

function CeilingsBase.ceilings_base_command(_argv: {string}): integer
  local env = Env.all()
  return CeilingsBase.ceilings_base(env, Github.live(env), ChangedPaths.live_git(env))
end

return CeilingsBase
