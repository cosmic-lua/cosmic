--- The `check` verb: strict type-check, in process.
---
--- In process is the point: `check` runs the checker directly against
--- the project model, so it needs nothing installed and reports against
--- the same file list every other verb uses. Emitting a makefile whose
--- check rule shelled out per file would want a host make, a shell
--- loop, and one process start per source, to do work this binary
--- already contains.
---
--- Incremental against the GRAPH, not against itself: a strict compile
--- type-checks (warnings fail too), so a file whose compiled output is
--- up to date against the compile rule's own inputs is a check that
--- already ran. `check` skips those and checks the rest — everything
--- on a tree that never built, only pins and payload generators right
--- after a converged gate. See `proved_by_graph` for the exact
--- freshness question and why it is sound.
---
--- Validation comes first and is fatal: a project whose import paths
--- collide or whose filenames cannot survive a recipe line has problems
--- the type checker would report as a confusing cascade, or not at all.

local fs = require("cosmic.fs")
local records = require("_tool.records")
local teal = require("cosmic.teal")
local deps = require("_make.deps")
local project = require("_make.project")
local selection = require("_make.select")
local stamp = require("_make.stamp")
local validate = require("_make.validate")
local types = require("_make.types")

local type File = types.File
local type Project = types.Project

--- Kinds whose `.tl` sources are type-checked. `.d.tl` is absent: a
--- declaration file is an input to the checker, resolved through the
--- include path by the sources that require it. `.lua` sources are
--- absent too — Lua is not type-checked, by definition.
---
--- Everything else that compiles is here, including the three kinds
--- that are easy to forget: `build` strict-compiles a `benchmark`, so a
--- table without it lets `check` pass a tree `build` rejects; a
--- binary's `payload-gen` is the file that decides what SHIPS, which
--- makes it the last one that should be gated by fmt and lint alone;
--- and `pin` -- a `*_pin.tl` is read as data (never executed) but is
--- still Teal source, so it gets the same strict type-check as
--- everything else here.
local checkable: {string: boolean} = {
  module = true,
  entry = true,
  test = true,
  example = true,
  benchmark = true,
  gen = true,
  ["payload-gen"] = true,
  pin = true,
}

--- Kinds the GRAPH strict-compiles. For these, an up-to-date compiled
--- output IS a passed strict check: `--compile-strict` type-checks
--- (warnings fail, matching `--check types`) and the compile rule's
--- prerequisites — the source, its import closure, the compile stamp,
--- the generated-types stamp — are exactly what a check of the same
--- file reads. `pin` and `payload-gen` are absent because the graph
--- never compiles them; they are always checked directly.
local graph_checked: {string: boolean} = {
  module = true,
  entry = true,
  test = true,
  example = true,
  benchmark = true,
  gen = true,
}

--- Has the graph already proved this file? True when its compiled
--- output is at least as new as everything its strict compile read:
--- the source, every source in its import closure (`.d.tl` included —
--- the SOURCE closure keeps declarations), the compile tool's stamp,
--- and the generated-types stamp. Any input missing — a tree that has
--- never built, a check running before any graph verb — answers
--- false, and the file is checked directly, which is exactly the old
--- behavior.
---
--- Sound for the same reason the incremental build is: mtime
--- schedules, and the compile rule restamps its output even when the
--- bytes did not change, so "output not older than every input" means
--- "a strict compile of these exact inputs succeeded".
--- @param proj Project The scanned project
--- @param f File The candidate file
--- @param by_import {string: {File}} Index from deps.index()
--- @return boolean True when the check may be skipped
local function proved_by_graph(proj: Project, f: File,
    by_import: {string: {File}}): boolean
  if not graph_checked[f.kind] then
    return false
  end
  local out = fs.stat(deps.built_path(f.path, project.BUILD_DIR))
  if not out then
    return false
  end
  local base = out:modify_time()
  local inputs = deps.source_paths(deps.closure(proj, f, by_import))
  inputs[#inputs + 1] = f.path
  inputs[#inputs + 1] = stamp.path_of("compile")
  inputs[#inputs + 1] = fs.join(project.BUILD_DIR, "_types", "types_gen.stamp")
  for _, p in ipairs(inputs) do
    local st = fs.stat(p)
    if not st then
      return false
    end
    local it = st:modify_time()
    if it.secs > base.secs or (it.secs == base.secs and it.nsecs > base.nsecs) then
      return false
    end
  end
  return true
end

--- Does this path select that file? A selection entry is either the
--- file itself or a directory containing it. Selection itself lives in
--- the model, where every verb shares it.
--- @param proj Project The scanned project
--- @param paths {string} Selection paths, relative to the root or absolute
--- @return {File}|nil The selected checkable files
--- @return string An error naming a selection path that matched nothing
local function select_files(proj: Project, paths: {string}): {File} | nil, string
  local all: {File} = {}
  for _, f in ipairs(proj.files) do
    if checkable[f.kind] and f.path:sub(-3) == ".tl" then
      all[#all + 1] = f
    end
  end
  return selection.files(all, paths, proj.root)
end

--- Type-check the selected files, writing issues to stderr as they are
--- found rather than at the end — a long check reports its first error
--- while the rest is still running.
--- @param files {File} Files to check
--- @return integer Number of files that failed
local function check_files(files: {File}): integer
  -- The project root is the module root, so "." is what makes
  -- require("pkg.db") resolve to pkg/db.tl. It goes first: a project's
  -- own module wins over anything the include path would otherwise
  -- offer under the same name.
  local include_dirs = {"."}
  local failed = 0
  for _, f in ipairs(files) do
    local result = teal.check_file(f.path, {include_dirs = include_dirs})
    if #result.warnings > 0 then
      io.stderr:write(teal.format_issues(result.warnings, {hints = true}) .. "\n")
    end
    if #result.errors > 0 then
      io.stderr:write(teal.format_issues(result.errors, {hints = true}) .. "\n")
    end
    if not result.ok then
      failed = failed + 1
    end
  end
  return failed
end

--- Run `check` against an already-scanned project.
---
--- The caller has chdir'd to the root, so every path here is relative
--- to it and every message reads the way the user typed it.
--- @param proj Project The scanned project
--- @param paths {string} Selection paths (empty for the whole project)
--- @return integer Exit code: 0 on success, 1 on any failure
local function run(proj: Project, paths: {string}): integer
  local issues = validate.validate(proj)
  if #issues > 0 then
    io.stderr:write(validate.format_issues(issues) .. "\n")
    io.write(records.format_verdict("check", false,
        records.detail(0, #issues, "validation error")) .. "\n")
    return records.exit_code(false)
  end

  local files, err = select_files(proj, paths)
  if not files then
    io.stderr:write((err or "make: no such selection") .. "\n")
    io.write(records.format_verdict("check", false, "bad selection") .. "\n")
    return records.exit_code(false)
  end

  local selected = files
  -- The graph's half first: a file whose strict compile is up to date
  -- against the same inputs is already checked, so re-deriving the
  -- answer in process is pure duplication — measured at 2m40s of a
  -- 2m16s no-op `--make ci` before this skip existed. Gate verbs
  -- converge before they run, so on a just-built tree this leaves the
  -- kinds the graph never compiles (pins, payload generators) plus
  -- whatever actually changed.
  local by_import = deps.index(proj)
  local to_check: {File} = {}
  local proved = 0
  for _, f in ipairs(selected) do
    if proved_by_graph(proj, f, by_import) then
      proved = proved + 1
    else
      to_check[#to_check + 1] = f
    end
  end
  if proved > 0 then
    io.write("check: " .. proved .. " of " .. #selected ..
      " already proved by their strict compile\n")
  end
  local failed = check_files(to_check)
  io.write(records.format_verdict("check", failed == 0,
      records.detail(failed, #selected, "file")) .. "\n")
  return records.exit_code(failed == 0)
end

local record CheckModule
  run: function(proj: Project, paths: {string}): integer
  select_files: function(proj: Project, paths: {string}): {File} | nil, string
  proved_by_graph: function(proj: Project, f: File,
  by_import: {string: {File}}): boolean
end

local M: CheckModule = {
  run = run,
  select_files = select_files,
  proved_by_graph = proved_by_graph,
}

return M
