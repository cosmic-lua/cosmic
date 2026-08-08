--- The test runner: this cosmic with the project's ROOT payload
--- appended, so `/zip/R` resolves inside a test exactly as inside the
--- artifact (`embed/R` -> `/zip/R`). Assembled by `prepare_stage`
--- before the graph runs, like a generator; the graph's test rules
--- name it as command and prerequisite (project.mk's `testrun` and
--- `testrun_dep` facts), and replace-if-changed keeps its mtime still
--- when neither the toolchain nor the payload moved, so nothing
--- re-runs for an identical runner.
---
--- Root payload only. A per-binary payload (`cmd/<name>/embed/**`) is
--- that artifact's private cargo: two binaries may store different
--- bytes at one zip path, so one shared runner cannot carry either
--- without lying about the other. Spawning `o/bin/<name>` covers
--- those, and stays the way to exercise a binary's CLI surface.

local embedc = require("cosmic.embed")
local fs = require("cosmic.fs")
local artifact = require("_make.artifact")
local project = require("_make.project")
local types = require("_make.types")

local type Project = types.Project

--- Where the runner lives, relative to the project root. Dot-prefixed
--- like every engine-owned entry under `o/`: the mirror cannot reach it.
local PATH < const > = project.BUILD_DIR .. "/.testrun/cosmic"

--- The project's root payload files, in walk order.
--- @param proj Project The scanned project
--- @return {string} Paths under the root `embed/`, relative to the root
local function root_payload(proj: Project): {string}
  local out: {string} = {}
  for _, f in ipairs(proj.files) do
    if f.kind == "payload"
    and project.payload_depth(project.segments(f.path)) == 1 then
      out[#out + 1] = f.path
    end
  end
  return out
end

--- Does this project get a runner at all?
--- @param proj Project The scanned project
--- @return boolean True when the root `embed/` has payload
local function enabled(proj: Project): boolean
  return #root_payload(proj) > 0
end

--- The two project.mk facts in one string: the command every test rule
--- execs, and the prerequisite naming it. The command is ABSOLUTE, like
--- COSMIC — a test re-invoking its interpreter through `arg[-1]` after
--- a chdir must still resolve it. The prerequisite is empty without
--- payload, so the d17 rule against naming the binary as a prerequisite
--- stands untouched; the runner file is content-addressed, so as a
--- prerequisite it moves exactly when the toolchain or the payload did.
--- @param proj Project The scanned project
--- @return string `testrun := …` and `testrun_dep := …`, newline-joined
local function mk_facts(proj: Project): string
  if not enabled(proj) then
    return "testrun := $(COSMIC)\ntestrun_dep :="
  end
  return "testrun := " .. fs.join(proj.root, PATH)
  .. "\ntestrun_dep := " .. PATH
end

--- Assemble the runner, or do nothing for a payload-free project.
--- @param proj Project The scanned project
--- @param cosmic string Absolute path to the running cosmic binary
--- @return boolean True when the runner is ready (or not needed)
--- @return string The error message on failure
local function build(proj: Project, cosmic: string): boolean, string
  local files = root_payload(proj)
  if #files == 0 then
    return true, ""
  end
  -- Stage at stored names, so embed's directory walk stores the
  -- artifact layout — the same one-code-path trade artifact.stage
  -- makes. Clear rather than merge: a payload file removed from the
  -- project must not survive in the runner.
  local dir = fs.join(project.BUILD_DIR, ".testrun", "stage")
  if fs.is_present(dir) then
    local rok, rerr = fs.remove_all(dir)
    if not rok then
      return false, "make: cannot clear " .. dir .. ": " ..
      (rerr or "unknown error")
    end
  end
  for _, rel in ipairs(files) do
    local stored = (rel:gsub("^[^/]+/", ""))
    local dst = fs.join(dir, stored)
    local mok, merr = fs.make_dirs(fs.dirname(dst))
    if not mok then
      return false, "make: cannot create " .. fs.dirname(dst) .. ": " ..
      (merr or "unknown error")
    end
    local content, cerr = fs.read(rel)
    if not content then
      return false, "make: cannot read " .. rel .. ": " ..
      (cerr or "unknown error")
    end
    local wok, werr = fs.write(dst, content)
    if not wok then
      return false, "make: cannot write " .. dst .. ": " ..
      (werr or "unknown error")
    end
  end
  local staged_out = PATH .. ".new"
  local count, terr = embedc.write({dir},
    {output = staged_out, exe_path = cosmic, mtime = embedc.EPOCH_SECONDS})
  if not count then
    local _ok, _err = fs.remove(staged_out)
    return false, "make: test runner: " .. (terr or "embed failed")
  end
  local rerr = artifact.replace_if_changed(staged_out, PATH)
  if rerr then
    return false, "make: " .. rerr
  end
  return true, ""
end

local record TestrunModule
  PATH: string
  enabled: function(proj: Project): boolean
  mk_facts: function(proj: Project): string
  build: function(proj: Project, cosmic: string): boolean, string
end

local M: TestrunModule = {
  PATH = PATH,
  enabled = enabled,
  mk_facts = mk_facts,
  build = build,
}

return M
