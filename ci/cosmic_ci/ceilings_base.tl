--- The base ci.yml's format check holds the markers of the tree to
--- (build/ceilings_base.tl): the merge base of the run's commit with main,
--- which `driver.tl ceilings-base` asks the API for (GH_TOKEN, with
--- contents: read; REPOSITORY, SHA, EVENT, REF and, in the merge queue,
--- BASE_REF), with no history needed in the checkout. Never the merge
--- queue's own base (`merge_group.base_sha`): that is the entry ahead,
--- whose markers the commit already holds. It writes `sha=<base>` to
--- $GITHUB_OUTPUT (standard output, for a run by hand), or nothing, which
--- the check fails on where it must hold one. The call is cut off after
--- CALL_SECONDS (15).
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Github = require("cosmic_ci.github")
local Shape = require("cosmic.shape")
local StepEnv = require("cosmic_ci.step_env")

local record CeilingsBase
  --- Writes `sha=<base>` to $GITHUB_OUTPUT, or nothing.
  ceilings_base: function(env: {string:string}, host: Github.Host): integer
  --- `driver.tl ceilings-base`, in the process's environment.
  ceilings_base_command: function(argv: {string}): integer
end

--- The part of the API's comparison of main with a commit that names the
--- commit the tree grew from.
local record BaseCommit
  sha: string
end
local record Comparison
  merge_base_commit?: BaseCommit
end
local COMPARISON <const> = Shape.record_of("Comparison")

local whole <const> = StepEnv.whole

--- The branch of main a run is held to: `main` for a push or a manual run, and for the merge queue the branch its entries
--- are queued for (BASE_REF, `refs/heads/main`), nil where it names none.
local function main_of(event: string, base_ref: string): string?
  if event ~= "merge_group" then return "main" end
  local name = base_ref:match("^refs/heads/([%w][%w._/-]*)$")
  return name
end

function CeilingsBase.ceilings_base(env: {string:string}, host: Github.Host): integer
  local call, why = whole(env, "CALL_SECONDS", 15)
  if call == nil then
    local _, _ = Fs.put(Fs.stderr, "ceilings-base: " .. why .. "\n")
    return 2
  end
  local event, ref = env["EVENT"] or "", env["REF"] or ""
  local base = ""
  -- A run of main itself is held to nothing (its changes were held in the queue); a pull request's run, a manual run of a
  -- branch and the queue's run each ask for the merge base of the commit with main. The queue's own base (`merge_group.base_sha`) is the entry
  -- ahead, whose markers the commit already holds, so it is never named here.
  local asks = event == "merge_group" or event == "pull_request" or
    ((event == "push" or event == "workflow_dispatch") and ref ~= "refs/heads/main")
  local main = main_of(event, env["BASE_REF"] or "")
  if asks and main ~= nil then
    local pages = Github.ask(host, "repos/" .. (env["REPOSITORY"] or "") .. "/compare/" .. main .. "..." .. (env["SHA"] or "") ..
        "?per_page=1", false, call)
    local first = pages and pages[1]
    if first ~= nil then
      local compared, _ = COMPARISON:decode_into(first)
      local commit = compared and compared.merge_base_commit
      if commit ~= nil then base = commit.sha end
    end
  end
  if Github.is_commit(base) then
    host.output("sha=" .. base)
    host.print("the base the markers are held to: " .. base .. ", the merge base with " .. (main or "main"))
  else
    host.print("no base on main found: the markers of the tree are held to none, which fails the check where it must hold one")
  end
  return 0
end

function CeilingsBase.ceilings_base_command(_argv: {string}): integer
  local env = Env.all()
  return CeilingsBase.ceilings_base(env, Github.live(env))
end

return CeilingsBase
