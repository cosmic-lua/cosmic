--- The check that the ceilings only fall: [`build/ceilings.txt`] as the tree has it is held to the file at the merge base
--- with main, and a count raised or a row added is refused ([`Ceilings.rises`]). The compile and the check of the tree
--- already refuse code over its ceiling, so the only way to let code through is to edit the data, and this closes it.
---
--- Where the base comes from, in order:
---
--- 1. `COSMIC_CEILINGS_BASE`, then `COSMIC_CI_BASE_SHA`: a commit CI names, the merge queue's base or the main commit a
---    branch push grew from (.github/workflows/ci.yml). A name that is no commit is a failure, not a skip.
--- 2. In a checkout of a developer, `git merge-base HEAD origin/main`.
---
--- Where no base can be named the check does not hold the file, and says why in its note, but only where none can
--- exist: a tree that is no git checkout, a checkout with no `origin/main` to grow from, and, in CI, the runs of main itself
--- (the scheduled run, a manual run and a push to main), whose changes the merge queue held to their base before they
--- landed. In every other CI run (a branch push, the merge queue) a missing base fails the check: a skip there would let a
--- raise through whenever the base could not be found, and a CI run is repeated at no cost. Where a base is named, its
--- commit is fetched (`--depth=1` from origin) if the checkout lacks it, and a base that cannot be read fails.
---
--- The base is what CI says it is; the check cannot tell a base the workflow was edited to name from the real one
--- (the workflow's edits are in the diff a reviewer reads). It does refuse a base that is not an ancestor of HEAD.
local Ceilings = require("build.ceilings")
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Time = require("cosmic.time")

local record CeilingsBase
  --- Runs git with `args` in the checkout at `root`: its exit status (-1 where git could not run, or ran out of time) and
  --- what it wrote to standard output.
  type Git = function(root: string, args: {string}): integer, string

  --- What the check found.
  record Verdict
    --- The refusals, one line each; none where the file only falls or the check was skipped.
    lines: {string}
    --- What the check did when it refused nothing, one line: the base it held the file to, or why it did not.
    note: string
  end

  --- [`CeilingsBase.Git`] for the host's own `git`.
  live_git: function(): Git

  --- Holds the ceilings file of the tree at `root` to the file at the base `env` names, or that `git` finds.
  check: function(root: string, env: {string:string}, git: Git): Verdict
end

--- How long one git call may take: a local lookup, or a fetch of one commit.
local git_timeout_ns <const> = Time.seconds(60)

function CeilingsBase.live_git(): CeilingsBase.Git
  return function(root: string, args: {string}): integer, string
    local git, _ = Proc.find("git")
    if git == nil then
      return -1, ""
    end
    local argv: mut {string} = { git, "-C", root }
    for _, word in ipairs(args) do
      argv[#argv + 1] = word
    end
    -- A fetch never asks for credentials: it works with what the checkout keeps or fails.
    local env = Env.all()
    env["GIT_TERMINAL_PROMPT"] = "0"
    local result, _ = Child.run(argv, { env = env, stdin = "null", stdout = "capture", stderr = "null",
      timeout_ns = git_timeout_ns })
    if result == nil or result.timed_out then
      return -1, ""
    end
    if not result.ok then
      return result.code or 1, ""
    end
    return 0, result.stdout or ""
  end
end

--- The first of `names` that `env` sets to something.
local function named(env: {string:string}, names: {string}): string
  for _, name in ipairs(names) do
    local value = env[name]
    if value ~= nil and value ~= "" then
      return value
    end
  end
  return ""
end

--- Whether a run of CI is the run of main itself, which has no base to hold: the scheduled run and a manual one, and a push
--- to main, whose change the merge queue held to its base.
local function mains_own(env: {string:string}): boolean
  local event = named(env, { "COSMIC_CI_EVENT", "GITHUB_EVENT_NAME" })
  return event == "schedule" or event == "workflow_dispatch" or (event == "push" and env["GITHUB_REF"] == "refs/heads/main")
end

local function skipped(why: string): CeilingsBase.Verdict
  return { lines = {}, note = "not held to a merge base: " .. why }
end

local function failed(why: string): CeilingsBase.Verdict
  return { lines = { Ceilings.path .. ": cannot hold the ceilings to the merge base, so they are refused: " .. why }, note = "" }
end

function CeilingsBase.check(root: string, env: {string:string}, git: CeilingsBase.Git): CeilingsBase.Verdict
  local in_ci = env["GITHUB_ACTIONS"] == "true"
  local base = named(env, { "COSMIC_CEILINGS_BASE", "COSMIC_CI_BASE_SHA" })
  if base ~= "" and base:match("^%x+$") == nil then
    if in_ci then
      return failed("the base CI names is `" .. base .. "`, no commit (COSMIC_CEILINGS_BASE or COSMIC_CI_BASE_SHA); " ..
          "run the check again, or fix where the workflow finds the base")
    end
    base = ""
  end
  if base == "" then
    if in_ci then
      if mains_own(env) then
        return skipped("this is a run of main itself, whose changes the merge queue held to their base")
      end
      return failed("CI names no base (COSMIC_CEILINGS_BASE, COSMIC_CI_BASE_SHA) for this run, which holds a change; " ..
          "a run that cannot find its base fails and is run again, since skipping the check there would let a raise through")
    end
    local inside, _ = git(root, { "rev-parse", "--git-dir" })
    if inside ~= 0 then
      return skipped("this tree is no git checkout, so it has no base to grow from; CI holds the ceilings on every branch")
    end
    local found, out = git(root, { "merge-base", "HEAD", "origin/main" })
    local sha = out:match("^(%x+)")
    if found ~= 0 or sha == nil then
      return skipped("this checkout has no merge base with origin/main (no such branch fetched, or too shallow a clone); " ..
          "`git fetch origin main` to hold the ceilings here, as CI does on every branch")
    end
    base = sha
  end
  local present, _ = git(root, { "cat-file", "-e", base .. "^{commit}" })
  if present ~= 0 then
    local _, _ = git(root, { "fetch", "--quiet", "--no-tags", "--depth=1", "origin", base })
    present, _ = git(root, { "cat-file", "-e", base .. "^{commit}" })
    if present ~= 0 then
      return failed("the base " .. base .. " is not in this checkout and `git fetch origin " .. base .. "` did not bring it")
    end
  end
  local ancestor, _ = git(root, { "merge-base", "--is-ancestor", base, "HEAD" })
  if ancestor == 1 then
    return failed("the base " .. base .. " is not an ancestor of HEAD, so it is not where this change grew from")
  end
  -- A base without the file holds no row, so every row of the tree's is one it lacks.
  local shown, was = git(root, { "cat-file", "-p", base .. ":" .. Ceilings.path })
  if shown ~= 0 then
    was = ""
  end
  local text, why = Fs.read(root .. "/" .. Ceilings.path)
  if text == nil then
    return failed("cannot read " .. Ceilings.path .. ": " .. why)
  end
  return { lines = Ceilings.rises(was, text), note = "held to the ceilings of " .. base:sub(1, 12) }
end

return CeilingsBase
