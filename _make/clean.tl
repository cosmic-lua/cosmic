--- `clean` — remove the build directory, in process.
---
--- Its own file because it is the one verb that is about the OUTPUT
--- rather than about the model: it reads no sources, needs no make
--- binary, and driving it through the graph would mean reading rules
--- out of the directory being deleted.

local fs = require("cosmic.fs")
local project = require("_make.project")
local stage = require("_make.stage")
local types = require("_make.types")

local type Project = types.Project

--- What `clean` leaves behind: the verified bootstrap.
---
--- `o/bootstrap/cosmic` is not build OUTPUT. It is the one pinned
--- artifact `bin/cosmic` downloads, checksums against `bin/cosmic.pin`
--- and assimilates -- the root of the trust chain -- and no verb
--- reproduces it. `--make fetch` re-obtains `o/3p`, so removing that
--- costs a command; removing this costs a NETWORK, and on a machine
--- without one it costs the tree. Cleaning a build should never make a
--- project unbuildable offline.
local KEEP < const >: {string: boolean} = {bootstrap = true}

--- Is `path` the root of a git checkout? A checkout root carries a
--- `.git` entry directly inside it -- a FILE (`gitdir: <path>`) for a
--- linked worktree, a DIRECTORY for a plain clone or the main checkout
--- -- so a bare filesystem check is enough; no `git` invocation, no
--- registry read. `skills/work/SKILL.md` has callers run `git clone
--- https://github.com/cosmic-lua/work o/board`, so a live board clone
--- can sit directly under `o/` and must survive a clean.
--- @param path string A direct child of the build directory
--- @return boolean True when path/.git is present
local function is_worktree_root(path: string): boolean
  return fs.is_present(fs.join(path, ".git"))
end

--- The summary detail's "kept ..." clause, naming only what was
--- actually kept -- the unconditional "kept the verified bootstrap"
--- used to run even when the only thing kept was a worktree.
--- @param bootstrap boolean Whether `o/bootstrap` was kept
--- @param worktrees integer How many git worktrees were kept
--- @return string "the verified bootstrap", "N git worktree(s)", both
---   joined with "and", or "" when nothing was kept
local function kept_detail(bootstrap: boolean, worktrees: integer): string
  local parts: {string} = {}
  if bootstrap then
    parts[#parts + 1] = "the verified bootstrap"
  end
  if worktrees > 0 then
    local noun = worktrees == 1 and "git worktree" or "git worktrees"
    parts[#parts + 1] = worktrees .. " " .. noun
  end
  if #parts == 2 then
    return parts[1] .. " and " .. parts[2]
  end
  return parts[1] or ""
end

--- `clean` — remove the build directory, in process. Driving this
--- through the graph would mean reading rules out of the directory
--- being deleted.
--- @param _proj Project Unused: clean is about the output, not the model
--- @param _paths {string} Unused: `_make.law` refuses a selection here
--- @param _cosmic string Unused: clean needs no make binary
--- @return integer Exit code
local function run(_proj: Project, _paths: {string},
    _cosmic: string): integer
  if not fs.is_present(project.BUILD_DIR) then
    return stage.verdict("clean", true, "nothing to remove")
  end
  local entries, gerr = fs.glob(project.BUILD_DIR, "*")
  if not entries then
    io.stderr:write("make: cannot read " .. project.BUILD_DIR .. ": " ..
      (gerr or "unknown error") .. "\n")
    return stage.verdict("clean", false, project.BUILD_DIR)
  end
  local removed = 0
  local kept = 0
  local kept_bootstrap = false
  local kept_worktrees = 0
  for _, path in ipairs(entries) do
    if KEEP[fs.basename(path)] then
      kept = kept + 1
      kept_bootstrap = true
    elseif is_worktree_root(path) then
      print("clean: kept " .. fs.basename(path) .. " (git worktree)")
      kept = kept + 1
      kept_worktrees = kept_worktrees + 1
    else
      local ok, err = fs.remove_all(path)
      if not ok then
        io.stderr:write("make: cannot remove " .. path .. ": " ..
          (err or "unknown error") .. "\n")
        return stage.verdict("clean", false, fs.basename(path))
      end
      removed = removed + 1
    end
  end
  -- Nothing kept means nothing to keep the directory FOR: remove it
  -- too, so a clean tree looks like one that was never built. Keeping
  -- an empty `o/` would be a difference with no meaning that every
  -- caller then has to know about.
  if kept == 0 then
    local ok, err = fs.remove_all(project.BUILD_DIR)
    if not ok then
      io.stderr:write("make: cannot remove " .. project.BUILD_DIR .. ": " ..
        (err or "unknown error") .. "\n")
      return stage.verdict("clean", false, project.BUILD_DIR)
    end
  end
  if removed == 0 then
    return stage.verdict("clean", true, "nothing to remove")
  end
  local detail = project.BUILD_DIR
  if kept > 0 then
    detail = detail .. ", kept " .. kept_detail(kept_bootstrap, kept_worktrees)
  end
  return stage.verdict("clean", true, detail)
end

local record CleanModule
  KEEP: {string: boolean}
  run: function(proj: Project, paths: {string}, cosmic: string): integer
  kept_detail: function(bootstrap: boolean, worktrees: integer): string
end

local M: CleanModule = {
  KEEP = KEEP,
  run = run,
  kept_detail = kept_detail,
}

return M
