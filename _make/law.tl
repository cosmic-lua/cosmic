--- The selection law, in one place: `V S` is the S-restriction of a
--- full `V`.
---
--- Every verb already narrows through `_make.select`. What this file
--- adds is the two halves of the law that a per-verb implementation
--- cannot state:
---
--- **Every verb answers about paths.** A verb that ignores a selection
--- is the worst of the three possible behaviours -- `--make docs
--- cosmic/fs` rendered the whole tree and reported success, so the
--- reader learns a spelling that does something else. Either the verb
--- restricts (most of them), or it says it cannot and why.
---
--- **The answer comes FIRST.** Selection is resolved against the
--- scanned model before the gate converges, so `--make ci nosuch`
--- refuses in two lines instead of after a full rebuild. That ordering
--- is only available here: a verb's own runner is downstream of the
--- build it triggered.
---
--- The verbs still resolve their own selections, because they need the
--- FILES where this needs only the answer. That leaves each verb's own
--- refusal branch unreachable from the CLI -- the pre-flight has
--- spoken by then -- and it stays anyway: `check.run` and `fetch.run`
--- are module functions, and a module function may not assume its
--- caller pre-flighted. `_make/check_test.tl` calls them directly, so
--- the guard is tested at the level where it can still fire.

local binaries = require("_make.binaries")
local check = require("_make.check")
local docs = require("_make.docs")
local project = require("_make.project")
local runverb = require("_make.runverb")
local selection = require("_make.select")
local stage = require("_make.stage")
local types = require("_make.types")

local type Project = types.Project
local type Selection = types.Selection
local type Verb = types.Verb

--- Verbs whose product is the whole project, with the reason.
---
--- Not an exemption from the law -- an application of it. There is no
--- S-restriction of "remove the build directory" or of a verdict over
--- every gate, so the honest answer to a path is a refusal naming why,
--- which is what `--baseline` already says about the coverage floor.
local WHOLE < const >: {string: string} = {
  clean = "it removes the build directory",
  ci = "it is the whole gate",
}

--- How a verb that is not a graph verb turns paths into targets.
---
--- Data rather than a chain of names: each of these owns a candidate
--- set the shared narrowing cannot derive from a `Selection` -- build's
--- targets are binaries, check's are the checkable sources, fetch's are
--- pins -- and every one of them still refuses a path that names
--- nothing, in the same sentence shape.
local RESOLVERS < const >: {string: function(Project, {string}): boolean, string} = {
  build = function(proj: Project, paths: {string}): boolean, string
    local picked, err = binaries.select(proj, paths)
    if not picked then
      return false, err
    end
    return true, ""
  end,
  check = function(proj: Project, paths: {string}): boolean, string
    local picked, err = check.select_files(proj, paths)
    if not picked then
      return false, err
    end
    return true, ""
  end,
  fetch = function(proj: Project, paths: {string}): boolean, string
    local picked, err = selection.files(project.of_kind(proj, {"pin"}),
      paths, proj.root)
    if not picked then
      return false, err
    end
    return true, ""
  end,
  run = runverb.resolve,
  docs = function(proj: Project, paths: {string}): boolean, string
    local picked, err = selection.files(project.of_kind(proj, docs.KINDS),
      paths, proj.root)
    if not picked then
      return false, err
    end
    return true, ""
  end,
}

--- Resolve a verb's selection without running the verb.
---
--- The pre-flight: it answers "does this selection name anything" using
--- the scanned model alone, so the answer costs a walk that has already
--- happened. Every verb reaches one of the three arms -- a whole-project
--- refusal, its own resolver, or the shared narrowing over its
--- `Selection` -- and a verb added without either is a verb this
--- function cannot check, which is why the fallback is `true` only for
--- an empty selection.
--- @param v Verb The verb about to run
--- @param proj Project The scanned project
--- @param paths {string} The selection paths, as typed
--- @return boolean Whether the selection names something
--- @return string The complaint, ready for stderr
local function resolve(v: Verb, proj: Project, paths: {string}): boolean, string
  local why = WHOLE[v.name]
  if why ~= nil then
    if #paths > 0 then
      return false, "make: " .. v.name .. " takes no paths; " .. why
    end
    return true, ""
  end
  if #paths == 0 then
    return true, ""
  end
  local own = RESOLVERS[v.name]
  if own ~= nil then
    return own(proj, paths)
  end
  if v.select ~= nil then
    local sel = v.select as Selection -- cast: nil ruled out above
    local picked, err = selection.files(stage.candidates(proj, sel),
      paths, proj.root)
    if not picked then
      return false, err or "make: no such selection"
    end
    return true, ""
  end
  return false, "make: " .. v.name .. " takes no paths"
end

local record LawModule
  WHOLE: {string: string}
  resolve: function(v: Verb, proj: Project, paths: {string}): boolean, string
end

local M: LawModule = {
  WHOLE = WHOLE,
  resolve = resolve,
}

return M
