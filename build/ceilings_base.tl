--- The check that the markers only fall: the markers each file of the tree holds ([`build.markers`]) are held to the files at
--- the merge base with main, and a file that holds more of a code than it did there is refused. The compile and the check of
--- the tree already refuse a finding no marker holds, so the only way to let code through is to add a marker, and this closes
--- it.
---
--- Where the base comes from, in order:
---
--- 1. `COSMIC_CEILINGS_BASE`: a commit CI names, the merge base of the run's commit with main (.github/workflows/ci.yml, from
---    `driver.tl ceilings-base`), for a branch push, a manual run of a branch and the merge queue alike. The queue's own base
---    (`merge_group.base_sha`, `COSMIC_CI_BASE_SHA`) is no base here: it is the commit of the entry ahead, which already
---    holds that entry's markers, so a marker added by one entry would pass the entries behind it. A name that is no commit is
---    a failure, not a skip.
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
local Markers = require("build.markers")
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Git = require("cosmic.git")
local Proc = require("cosmic.proc")

local record CeilingsBase
  --- What the check asks of the checkout it holds the markers in: the history of the tree. [`CeilingsBase.live`] answers
  --- from the checkout's own files ([`cosmic.git`]); the one thing it cannot do without a git program is fetch a commit.
  interface Source
    --- Whether the tree is a git checkout.
    checkout: function(Source): boolean
    --- The commit that `a` and `b` (revisions) grew from, or nil where they share none or either cannot be read.
    merge_base: function(Source, a: string, b: string): string?
    --- Whether the checkout holds the commit `base`.
    has: function(Source, base: string): boolean
    --- Brings the commit `base` from origin (`--depth=1`) into the checkout, if it can; the caller asks `has` again.
    fetch: function(Source, base: string)
    --- Whether the checkout is shallow: its history is cut, so ancestry cannot be told.
    shallow: function(Source): boolean
    --- Whether the commit `base` is an ancestor of HEAD.
    ancestor: function(Source, base: string): boolean
    --- Every file of the commit `base`, by path; nil where it cannot be read.
    paths: function(Source, base: string): {string: boolean}?
    --- The contents of the files `paths` of the commit `base`, by path; nil where one cannot be read.
    blobs: function(Source, base: string, paths: {string}): {string: string}?
  end

  --- What the markers of a tree hold: a file to a code to how many findings its markers hold ([`build.tree_checks.checked`]'s
  --- `markers`).
  type Held = {string: {string: integer}}

  --- What the check found.
  record Verdict
    --- The refusals, one line each; none where the file only falls or the check was skipped.
    lines: {string}
    --- What the check did when it refused nothing, one line: the base it held the file to, or why it did not.
    note: string
  end

  --- The [`CeilingsBase.Source`] of the checkout at `root`.
  live: function(root: string): Source

  --- Holds the markers the tree at `root` `held` to the markers of the files at the base `env` names, or that `source`
  --- finds: a file may hold no more markers of a code than it did there.
  check: function(root: string, env: {string:string}, source: Source, held?: Held): Verdict

  --- What `check` asks `source` of the tree at `root` to find its base, and what it hears, as one text; a fetch is not
  --- asked but said to be. All else `check` reads is the files on disk and those of the base, which the base's commit
  --- names, so two trees with the same files and the same text are held alike ([`build.fix.verdict`]).
  inputs: function(root: string, env: {string:string}, source: Source): string
end

--- How long the fetch of one commit may take.
local fetch_timeout_ns <const> = Clock.seconds(60)

local class Live is CeilingsBase.Source
  root: string
  --- The checkout, opened when first asked and again after a fetch, which may have added a pack.
  mut repo?: Git.Repo
  mut opened: boolean
  --- The files of the last commit asked about, with that commit.
  mut listing?: {string: Git.TreeEntry}
  mut listed?: string

  function listing_of(self, base: string): {string: Git.TreeEntry}?
    if self.listed == base then return self.listing end
    local repo = self:open()
    if repo == nil then return nil end
    local files, _ = repo:files(base)
    self.listing = files
    self.listed = if files == nil then nil else base end
    return files
  end

  function open(self): Git.Repo?
    if not self.opened then
      self.opened = true
      -- `plain`: no GIT_DIR or GIT_WORK_TREE of a hook may name another repository.
      local repo, _ = Git.open(self.root, true)
      self.repo = repo
    end
    return self.repo
  end

  function checkout(self): boolean
    return self:open() ~= nil
  end

  function merge_base(self, a: string, b: string): string?
    local repo = self:open()
    if repo == nil then return nil end
    local found, _ = repo:merge_base(a, b)
    if found == nil or found == false then return nil end
    return found
  end

  function has(self, base: string): boolean
    local repo = self:open()
    if repo == nil then return false end
    local commit, _ = repo:commit_info(base)
    return commit ~= nil
  end

  function fetch(self, base: string)
    local git, _ = Proc.find("git")
    if git == nil then return end
    -- A fetch never asks for credentials: it works with what the checkout keeps or fails.
    local env = Env.all()
    env["GIT_TERMINAL_PROMPT"] = "0"
    local _, _ = Child.run({ git, "-C", self.root, "fetch", "--quiet", "--no-tags", "--depth=1", "origin", base },
      { env = env, stdin = "null", stdout = "null", stderr = "null", timeout_ns = fetch_timeout_ns })
    self.opened = false
    self.repo = nil
    self.listed = nil
    self.listing = nil
  end

  function shallow(self): boolean
    local repo = self:open()
    return repo ~= nil and repo:is_shallow()
  end

  function ancestor(self, base: string): boolean
    local repo = self:open()
    if repo == nil then return false end
    local found, _ = repo:merge_base(base, "HEAD")
    return found == base
  end

  function paths(self, base: string): {string: boolean}?
    local files = self:listing_of(base)
    if files == nil then return nil end
    local out: mut {string: boolean} = {}
    -- Files only: a link or a submodule has no text to hold markers.
    for path, entry in pairs(files) do
      if entry.mode == "100644" or entry.mode == "100755" then out[path] = true end
    end
    return out
  end

  function blobs(self, base: string, paths: {string}): {string: string}?
    local repo = self:open()
    local files = self:listing_of(base)
    if repo == nil or files == nil then return nil end
    local out: mut {string: string} = {}
    for _, path in ipairs(paths) do
      local entry = files[path]
      if entry == nil then return nil end
      local object, _ = repo:read(entry.oid)
      if object == nil then return nil end
      out[path] = object.data
    end
    return out
  end
end

function CeilingsBase.live(root: string): CeilingsBase.Source
  local source: Live = { root = root, repo = nil, opened = false, listing = nil, listed = nil }
  return source
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
  return { lines = { "cannot hold the markers to the merge base, so they are refused: " .. why }, note = "" }
end

--- The markers of `text` by the code they hold and the line they hold, written as `<stage> <code>`, a NUL and the line with
--- its marker comment and the space around it removed: what a line that moved to another file still matches.
local function marked_lines(text: string, name: string): {string: integer}
  local out: mut {string: integer} = {}
  local marks = Markers.read(text, name).marks
  if #marks == 0 then return out end
  local lines: mut {string} = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
  for _, mark in ipairs(marks) do
    local held = (Markers.bare(lines[mark.line] or "")):match("^%s*(.-)%s*$") or ""
    for _, segment in ipairs(mark.segments) do
      for code, n in pairs(segment.counts) do
        local key = segment.stage .. " " .. code .. "\0" .. held
        out[key] = (out[key] or 0) + n
      end
    end
  end
  return out
end

--- What the markers of the base are.
local record Based
  --- The markers each file holds, by file and code.
  counts: CeilingsBase.Held
  --- The marked lines ([`marked_lines`]) the files held at the base and no longer hold on disk: what moved out of them, or
  --- was fixed, which a new file may carry ([`marks_rise`]).
  gone: {string: integer}
end

--- Whether `path` is a file whose markers count: a Teal source outside `vendor/` and `ci/` (the tree `ci/` is its own).
local function counted(path: string): boolean
  return path:sub(-3) == ".tl" and path:sub(1, 7) ~= "vendor/" and path:sub(1, 3) ~= "ci/"
end

--- The markers each file holds at `base`, by file and code, read from the commit: the files that mention the keyword,
--- then their blobs. nil and why where the checkout cannot say.
local function base_marks(root: string, base: string, held: CeilingsBase.Held, source: CeilingsBase.Source):
    Based?, string
  local listed = source:paths(base)
  if listed == nil then
    return nil, "the files at " .. base .. " cannot be listed"
  end
  local names: mut {string} = {}
  for path in pairs(listed) do
    if counted(path) then names[#names + 1] = path end
  end
  table.sort(names)
  local contents = source:blobs(base, names)
  if contents == nil then
    return nil, "the files at " .. base .. " cannot be read"
  end
  local keys = Markers.keys()
  local out: mut {string: {string: integer}} = {}
  local gone: mut {string: integer} = {}
  for _, path in ipairs(names) do
    local content = assert(contents[path])
    local mentions = false
    for _, key in ipairs(keys) do
      if content:find(key, 1, true) ~= nil then
        mentions = true
        break
      end
    end
    if mentions then
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
        -- What the file on disk, read whether or not the run names it, no longer holds.
        local none: {string: integer} = {}
        local now = if there ~= nil then marked_lines(there, path) else none end
        for key, count in pairs(marked_lines(content, path)) do
          local lost = count - (now[key] or 0)
          if lost > 0 then gone[key] = (gone[key] or 0) + lost end
        end
      end
    end
  end
  return { counts = out, gone = gone }, ""
end

--- Which of `files` the commit `base` lacks, by name: files that are new since it. nil where the checkout cannot tell, which
--- holds every file to its own count.
local function new_files(base: string, files: {string}, source: CeilingsBase.Source): {string: boolean}?
  local listed = source:paths(base)
  if listed == nil then return nil end
  local out: mut {string: boolean} = {}
  for _, file in ipairs(files) do
    if listed[file] ~= true then out[file] = true end
  end
  return out
end

--- The lines that refuse the markers `held` of the tree where a file holds more of a code than the merge base held in its
--- markers, or nil and why where the base cannot be read. A moved line keeps its marker and so its count; a marker is never
--- added, and one for a code no file held at the base (a closed code) says its rule has no exceptions. The count of a file is
--- its own, with one exception for code that moved to a file the base lacks (a file renamed, or split out of another): a
--- marker there is carried where a file of the base held the same code on the same line ([`marked_lines`]) and no longer
--- does. A fixed finding frees its line too, so a new file may copy that line with its marker; it cannot carry a marker to a
--- line of its own.
local function marks_rise(root: string, base: string, held: CeilingsBase.Held, source: CeilingsBase.Source):
    {string}?, string
  local based, why = base_marks(root, base, held, source)
  if based == nil then
    return nil, why
  end
  local was = based.counts
  local gone: mut {string: integer} = {}
  for key, count in pairs(based.gone) do gone[key] = count end
  local files: mut {string} = {}
  for file in pairs(held) do
    files[#files + 1] = file
  end
  table.sort(files)
  -- The codes some file held a marker of at the base, in any stage: a code in none is closed, and its rule has no exceptions.
  local anywhere: mut {string: boolean} = {}
  for _, counts in pairs(was) do
    for key in pairs(counts) do
      anywhere[key:match(" (%S+)$") or key] = true
    end
  end
  -- What each new file carries, by code: its marked lines that lines the base lost match, drawn in the order of the files.
  local carried: mut {string: mut {string: integer}} = {}
  if next(gone) ~= nil then
    local unmarked: mut {string} = {}
    for _, file in ipairs(files) do
      if was[file] == nil then unmarked[#unmarked + 1] = file end
    end
    local new: {string: boolean} = {}
    if #unmarked > 0 then new = new_files(base, unmarked, source) or {} end
    for _, file in ipairs(unmarked) do
      local text: string? = nil
      if new[file] == true then
        local read, _ = Fs.read(root .. "/" .. file)
        text = read
      end
      if text ~= nil then
        local own: mut {string: integer} = {}
        local lines = marked_lines(text, file)
        local keys: mut {string} = {}
        for key in pairs(lines) do keys[#keys + 1] = key end
        table.sort(keys)
        for _, key in ipairs(keys) do
          local took = math.min(assert(lines[key]), gone[key] or 0)
          if took > 0 then
            gone[key] = (gone[key] or 0) - took
            local code = key:match("^([^%z]*)") or key
            own[code] = (own[code] or 0) + took
          end
        end
        carried[file] = own
      end
    end
  end
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
      local moved = (carried[file] or {})[code] or 0
      if now > before + moved then
        local held_there = "the merge base held " .. tostring(before)
        if carried[file] ~= nil then
          held_there = "the merge base lacks the file, which carries only the " .. tostring(moved) ..
            " that hold the same line as a marker a file of the base lost"
        end
        local line = file .. ": " .. tostring(now) .. " of its markers hold " .. code .. " and " .. held_there ..
          "; a marker is never added and a count only falls: fix the finding instead"
        if anywhere[code:match(" (%S+)$") or code] ~= true then
          line = file .. ": " .. tostring(now) .. " of its markers hold " .. code .. " and no file held one at the merge base: " ..
            "this rule has no exceptions, so fix the code and write no marker"
        end
        out[#out + 1] = line
      end
    end
  end
  return out, ""
end

function CeilingsBase.check(root: string, env: {string:string}, source: CeilingsBase.Source, held?: CeilingsBase.Held):
    CeilingsBase.Verdict
  local in_ci = env["GITHUB_ACTIONS"] == "true"
  local base = named(env, { "COSMIC_CEILINGS_BASE" })
  if base ~= "" and not full_hash(base) then
    if in_ci then
      return failed("the base CI names is `" .. base .. "`, no full commit hash (COSMIC_CEILINGS_BASE; " ..
          "`unknown` is a base GitHub could not name); run the job again, or fix where the workflow finds the base")
    end
    base = ""
  end
  -- The checkout names a commit in lower case.
  base = base:lower()
  if base == "" then
    if in_ci then
      if mains_own(env) then
        return skipped("this is a run of main itself, whose changes the merge queue held to their base")
      end
      return failed("CI names no base (COSMIC_CEILINGS_BASE) for this run, which holds a change; " ..
          "a run that cannot find its base fails and is run again, since skipping the check there would let a raise through")
    end
    if not source:checkout() then
      return skipped("this tree is no git checkout, so it has no base to grow from; CI holds the markers on every branch")
    end
    local sha = source:merge_base("HEAD", "origin/main")
    if sha == nil then
      return skipped("this checkout has no merge base with origin/main (no such branch fetched, or too shallow a clone); " ..
          "`git fetch origin main` to hold the markers here, as CI does on every branch")
    end
    base = sha
  end
  if not source:has(base) then
    source:fetch(base)
    if not source:has(base) then
      return failed("the base " .. base .. " is not in this checkout and `git fetch origin " .. base .. "` did not bring it")
    end
  end
  -- A shallow checkout (a branch push's holds HEAD and the fetched base alone) cannot say whether one commit is another's
  -- ancestor, so the question is asked only where the result is known.
  if not source:shallow() and not source:ancestor(base) then
    return failed("the base " .. base .. " is not an ancestor of HEAD, so it is not where this change grew from")
  end
  local lines: mut {string} = {}
  if held ~= nil and next(held) ~= nil then
    local rose, rose_why = marks_rise(root, base, held, source)
    if rose == nil then
      return failed(rose_why)
    end
    for _, line in ipairs(rose) do
      lines[#lines + 1] = line
    end
  end
  return { lines = lines, note = "held to the markers of " .. base:sub(1, 12) }
end

--- A [`CeilingsBase.Source`] that asks `inner` and writes each question and its answer to `heard`.
local class Recorded is CeilingsBase.Source
  inner: CeilingsBase.Source
  heard: mut {string}

  function say(self, line: string)
    self.heard[#self.heard + 1] = line
  end

  function checkout(self): boolean
    local found = self.inner:checkout()
    self:say("checkout\0" .. tostring(found))
    return found
  end

  function merge_base(self, a: string, b: string): string?
    local found = self.inner:merge_base(a, b)
    self:say("merge_base " .. a .. " " .. b .. "\0" .. (found or "none"))
    return found
  end

  function has(self, base: string): boolean
    local found = self.inner:has(base)
    self:say("has " .. base .. "\0" .. tostring(found))
    return found
  end

  -- A fetch changes the checkout, so it is not asked: the base it would bring is missing, which the answer before it says.
  function fetch(self, _base: string)
    self:say("fetch not asked")
  end

  function shallow(self): boolean
    local found = self.inner:shallow()
    self:say("shallow\0" .. tostring(found))
    return found
  end

  function ancestor(self, base: string): boolean
    local found = self.inner:ancestor(base)
    self:say("ancestor " .. base .. "\0" .. tostring(found))
    return found
  end

  -- The files of a base are what its commit names, which the answers before say.
  function paths(self, base: string): {string: boolean}?
    return self.inner:paths(base)
  end

  function blobs(self, base: string, paths: {string}): {string: string}?
    return self.inner:blobs(base, paths)
  end
end

function CeilingsBase.inputs(root: string, env: {string:string}, source: CeilingsBase.Source): string
  local recorded: Recorded = { inner = source, heard = {} }
  local verdict = CeilingsBase.check(root, env, recorded, nil)
  recorded:say("verdict\0" .. verdict.note .. "\0" .. table.concat(verdict.lines, "\0"))
  return table.concat(recorded.heard, "\n")
end

return CeilingsBase
