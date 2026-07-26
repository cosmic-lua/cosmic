--- The `check` verb: strict type-check, in process.
---
--- In process is the point. The old generator emitted a Makefile whose
--- check rule shelled out to `cosmic --check types` once per file — a
--- host make, a shell loop, and one process start per source, to do
--- work this binary already contains. `check` runs the checker directly
--- against the project model, so it needs nothing installed and reports
--- against the same file list every other verb will use.
---
--- Validation comes first and is fatal: a project whose import paths
--- collide or whose filenames cannot survive a recipe line has problems
--- the type checker would report as a confusing cascade, or not at all.

local teal = require("cosmic.teal")
local project = require("_make.project")
local validate = require("_make.validate")
local types = require("_make.types")

local type File = types.File
local type Project = types.Project

--- Kinds whose `.tl` sources are type-checked. `.d.tl` is absent: a
--- declaration file is an input to the checker, resolved through the
--- include path by the sources that require it. `.lua` sources are
--- absent too — Lua is not type-checked, by definition.
local checkable: {string: boolean} = {
  module = true,
  entry = true,
  test = true,
  example = true,
  gen = true,
  pin = true,
}

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
  return project.select(all, paths, proj.root)
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
    local result = teal.check(f.path, {include_dirs = include_dirs})
    if #result.warnings > 0 then
      io.stderr:write(teal.format_issues(result.warnings) .. "\n")
    end
    if #result.errors > 0 then
      io.stderr:write(teal.format_issues_with_hints(result.errors) .. "\n")
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
    io.write(string.format("check: FAIL (%d validation %s)\n",
        #issues, #issues == 1 and "error" or "errors"))
    return 1
  end

  local files, err = select_files(proj, paths)
  if not files then
    io.stderr:write((err or "make: no such selection") .. "\n")
    io.write("check: FAIL (bad selection)\n")
    return 1
  end

  local selected = files as {File} -- cast: record union after the guard
  local failed = check_files(selected)
  if failed > 0 then
    io.write(string.format("check: FAIL (%d of %d files)\n", failed, #selected))
    return 1
  end
  io.write(string.format("check: PASS (%d %s)\n",
      #selected, #selected == 1 and "file" or "files"))
  return 0
end

local record CheckModule
  run: function(proj: Project, paths: {string}): integer
  select_files: function(proj: Project, paths: {string}): {File} | nil, string
end

local M: CheckModule = {
  run = run,
  select_files = select_files,
}

return M
