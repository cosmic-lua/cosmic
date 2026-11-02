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
--- (the scheduled run, a manual run of main and a push to main), whose changes the merge queue held to their base before
--- they landed. In every other CI run (a branch push, the merge queue, a manual run of a branch) a missing base fails the check: a skip there would let a
--- raise through whenever the base could not be found, and a CI run is repeated at no cost. Where a base is named, its
--- commit is fetched (`--depth=1` from origin) if the checkout lacks it, and a base that cannot be read fails.
---
--- The base is what CI says it is; the check cannot tell a base the workflow was edited to name from the real one
--- (the workflow's edits are in the diff a reviewer reads). It does refuse a name that is not a full commit hash, and,
--- where the checkout holds enough history to tell (a shallow one, as CI's branch pushes are, cannot), a base that is not an
--- ancestor of HEAD.
local Ceilings = require("build.ceilings")
local Markers = require("build.markers")
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Clock = require("cosmic.clock")

local record CeilingsBase
  --- Runs git with `args` in the checkout at `root`, feeding it `input` as its standard input where given: its exit status
  --- (-1 where git could not run, or ran out of time) and what it wrote to standard output.
  type Git = function(root: string, args: {string}, input?: string): integer, string

  --- What the markers of a tree hold: a file to a code to how many findings its markers hold ([`build.tree_checks`]'s
  --- `markers`).
  type Held = {string: {string: integer}}

  --- What the check found.
  record Verdict
    --- The refusals, one line each; none where the file only falls or the check was skipped.
    lines: {string}
    --- What the check did when it refused nothing, one line: the base it held the file to, or why it did not.
    note: string
  end

  --- [`CeilingsBase.Git`] for the host's own `git`.
  live_git: function(): Git

  --- Holds the ceilings file of the tree at `root` to the file at the base `env` names, or that `git` finds, and the markers
  --- the tree `held` to the markers of the files at that base: a file may hold no more markers of a code than it did there.
  check: function(root: string, env: {string:string}, git: Git, held?: Held): Verdict
end

--- How long one git call may take: a local lookup, or a fetch of one commit.
local git_timeout_ns <const> = Clock.seconds(60)

function CeilingsBase.live_git(): CeilingsBase.Git
  return function(root: string, args: {string}, input?: string): integer, string
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
    -- The files of a base read together (`cat-file --batch`) come back in one stream, so the limit is raised for them.
    local result, _ = Child.run(argv, if input == nil then
      { env = env, stdin = "null", stdout = "capture", stderr = "null", timeout_ns = git_timeout_ns }
      else
      { env = env, input = input, stdout = "capture", stderr = "null", timeout_ns = git_timeout_ns, capture_limit = 1 << 28 }
      end)
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

--- Whether a run of CI is the run of main itself, which has no base to hold: the scheduled run, and a push to main or a
--- manual run of it, whose change the merge queue held to its base. A manual run of a branch holds a change and is not.
local function mains_own(env: {string:string}): boolean
  local event = named(env, { "COSMIC_CI_EVENT", "GITHUB_EVENT_NAME" })
  if event == "schedule" then
    return true
  end
  return (event == "push" or event == "workflow_dispatch") and env["GITHUB_REF"] == "refs/heads/main"
end

--- Whether `name` is a full commit hash (SHA-1 or SHA-256), which git resolves to the one commit and not to an abbreviation.
local function full_hash(name: string): boolean
  return name:match("^%x+$") ~= nil and (#name == 40 or #name == 64)
end

local function skipped(why: string): CeilingsBase.Verdict
  return { lines = {}, note = "not held to a merge base: " .. why }
end

local function failed(why: string): CeilingsBase.Verdict
  return { lines = { Ceilings.path .. ": cannot hold the ceilings to the merge base, so they are refused: " .. why }, note = "" }
end

--- The markers each file holds at `base`, by file and code, read from the commit with git alone: the files that mention the
--- keyword (`git grep`), then their blobs in one stream (`git cat-file --batch`). nil and why where git fails.
local function base_marks(root: string, base: string, held: CeilingsBase.Held, git: CeilingsBase.Git):
    CeilingsBase.Held?, string
  local args: mut {string} = { "grep", "-l", "-F" }
  for _, key in ipairs(Markers.keys()) do
    args[#args + 1] = "-e"
    args[#args + 1] = key
  end
  for _, word in ipairs({ base, "--", "*.tl", ":(exclude)vendor", ":(exclude)ci" }) do
    args[#args + 1] = word
  end
  local status, listed = git(root, args)
  -- Status 1 is "no match", which a base without markers answers.
  if status ~= 0 and status ~= 1 then
    return nil, "git grep of the markers at " .. base .. " failed"
  end
  local paths: mut {string} = {}
  for line in listed:gmatch("[^\n]+") do
    if line:sub(1, #base + 1) == base .. ":" then
      paths[#paths + 1] = line:sub(#base + 2)
    end
  end
  local out: mut {string: {string: integer}} = {}
  if #paths == 0 then
    return out, ""
  end
  local wanted: mut {string} = {}
  for _, path in ipairs(paths) do
    wanted[#wanted + 1] = base .. ":" .. path
  end
  local shown, stream = git(root, { "cat-file", "--batch" }, table.concat(wanted, "\n") .. "\n")
  if shown ~= 0 then
    return nil, "git cat-file of the markers at " .. base .. " failed"
  end
  local at = 1
  for _, path in ipairs(paths) do
    local header_end = stream:find("\n", at, true)
    if header_end == nil then
      return nil, "git cat-file answered fewer files than asked at " .. base
    end
    local size = stream:sub(at, header_end - 1):match("^%x+ blob (%d+)$")
    if size == nil then
      -- `<name> missing`: a path the listing named and the commit lacks does not happen; leave it out.
      at = header_end + 1
    else
      local n = math.tointeger(tonumber(size)) or 0
      local content = stream:sub(header_end + 1, header_end + n)
      -- A file the change left as it was holds the markers the tree's holds: no lexing for it.
      local there, _ = Fs.read(root .. "/" .. path)
      local mine = held[path]
      if there == content and mine ~= nil then
        out[path] = mine
      else
        local counts = Markers.counts(content, path)
        if next(counts) ~= nil then
          out[path] = counts
        end
      end
      at = header_end + n + 2
    end
  end
  return out, ""
end

--- The lines that refuse the markers `held` of the tree where a file holds more of a code than it did at `base`, or nil and
--- why where the base cannot be read. A moved line keeps its marker and so its count; a marker never added is how a pin never
--- rose. The count of a file is its own: a marker of a file renamed or split is new where it lands.
local function marks_rise(root: string, base: string, held: CeilingsBase.Held, git: CeilingsBase.Git): {string}?, string
  local was, why = base_marks(root, base, held, git)
  if was == nil then
    return nil, why
  end
  local files: mut {string} = {}
  for file in pairs(held) do
    files[#files + 1] = file
  end
  table.sort(files)
  local out: mut {string} = {}
  for _, file in ipairs(files) do
    local codes: mut {string} = {}
    for code in pairs(assert(held[file])) do
      codes[#codes + 1] = code
    end
    table.sort(codes)
    for _, code in ipairs(codes) do
      local now = assert(held[file])[code] or 0
      local before = (was[file] or {})[code] or 0
      if now > before then
        out[#out + 1] = file .. ": " .. tostring(now) .. " of its markers hold " .. code .. " and the merge base's file held " ..
          tostring(before) .. "; a marker is never added and a count only falls: fix the finding instead"
      end
    end
  end
  return out, ""
end

function CeilingsBase.check(root: string, env: {string:string}, git: CeilingsBase.Git, held?: CeilingsBase.Held):
    CeilingsBase.Verdict
  local in_ci = env["GITHUB_ACTIONS"] == "true"
  local base = named(env, { "COSMIC_CEILINGS_BASE", "COSMIC_CI_BASE_SHA" })
  if base ~= "" and not full_hash(base) then
    if in_ci then
      return failed("the base CI names is `" .. base .. "`, no full commit hash (COSMIC_CEILINGS_BASE or " ..
          "COSMIC_CI_BASE_SHA; `unknown` is a base GitHub could not name); run the job again, or fix where the workflow finds the base")
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
  -- A shallow checkout (a branch push's holds HEAD and the fetched base alone) cannot say whether one commit is another's
  -- ancestor, so the question is asked only where the answer is known.
  local _, shallow = git(root, { "rev-parse", "--is-shallow-repository" })
  if shallow:match("^false") ~= nil then
    local ancestor, _ = git(root, { "merge-base", "--is-ancestor", base, "HEAD" })
    if ancestor ~= 0 then
      return failed("the base " .. base .. " is not an ancestor of HEAD, so it is not where this change grew from")
    end
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
  -- The comparison reads rows leniently; the file it judges is read as the compile reads it first.
  local parsed, parse_why = Ceilings.parse(text)
  if parsed == nil then
    return failed(parse_why)
  end
  local lines: mut {string} = {}
  for _, line in ipairs(Ceilings.rises(was, text)) do
    lines[#lines + 1] = line
  end
  if held ~= nil and next(held) ~= nil then
    local rose, rose_why = marks_rise(root, base, held, git)
    if rose == nil then
      return failed(rose_why)
    end
    for _, line in ipairs(rose) do
      lines[#lines + 1] = line
    end
  end
  return { lines = lines, note = "held to the ceilings of " .. base:sub(1, 12) }
end

return CeilingsBase
