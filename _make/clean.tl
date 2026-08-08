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
  for _, path in ipairs(entries) do
    if KEEP[fs.basename(path)] then
      kept = kept + 1
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
    detail = detail .. ", kept the verified bootstrap"
  end
  return stage.verdict("clean", true, detail)
end

local record CleanModule
  KEEP: {string: boolean}
  run: function(proj: Project, paths: {string}, cosmic: string): integer
end

local M: CleanModule = {
  KEEP = KEEP,
  run = run,
}

return M
