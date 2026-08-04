--- The `check` verb: strict type-check, in process.
---
--- In process is the point: `check` runs the checker directly against
--- the project model, so it needs nothing installed and reports against
--- the same file list every other verb uses. Emitting a makefile whose
--- check rule shelled out per file would want a host make, a shell
--- loop, and one process start per source, to do work this binary
--- already contains.
---
--- Validation comes first and is fatal: a project whose import paths
--- collide or whose filenames cannot survive a recipe line has problems
--- the type checker would report as a confusing cascade, or not at all.

local records = require("cosmic.records")
local teal = require("cosmic.teal")
local selection = require("_make.select")
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
    return records.verdict("check", false,
      records.detail(0, #issues, "validation error"))
  end

  local files, err = select_files(proj, paths)
  if not files then
    io.stderr:write((err or "make: no such selection") .. "\n")
    return records.verdict("check", false, "bad selection")
  end

  local selected = files as {File} -- cast: record union after the guard
  local failed = check_files(selected)
  return records.verdict("check", failed == 0,
    records.detail(failed, #selected, "file"))
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
