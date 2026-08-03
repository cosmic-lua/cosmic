--- Narrowing a file list to the caller's selection.
---
--- Selection is the one rule every verb shares: `V S` must be the
--- `S`-restriction of a full `V`, so there is one implementation of
--- "which of these files did you mean" and every verb calls it. It
--- lives beside the model rather than inside it because the model
--- answers what a project HAS, and this answers what a run is ABOUT.

local fs = require("cosmic.fs")
local types = require("_make.types")

local type File = types.File

--- Does a selection path cover this file? An entry is either the file
--- itself or a directory containing it, both relative to the root.
--- @param sel string A selection path, relative to the root
--- @param path string A project file path, relative to the root
--- @return boolean True when sel covers path
local function covers(sel: string, path: string): boolean
  if sel == "" or sel == "." then
    return true
  end
  return path == sel or path:sub(1, #sel + 1) == sel .. "/"
end

--- Narrow a file list to the caller's selection.
---
--- Selection changes which files a verb acts on, never what the project
--- IS: the model is always scanned whole, so a partial run resolves
--- imports exactly the way a full one does. A path matching nothing is
--- an error rather than a silent empty set — "0 files, PASS" is how a
--- typo becomes a green build.
--- @param files {File} The candidate files for this verb
--- @param paths {string} Selection paths, relative to the root or absolute
--- @param root string Absolute project root, for resolving absolute paths
--- @return {File}|nil The selected files, in path order
--- @return string An error naming a selection path that matched nothing
local function select_files(files: {File}, paths: {string}, root: string): {File} | nil, string
  if #paths == 0 then
    return files
  end
  local picked: {File} = {}
  local seen: {string: boolean} = {}
  for _, raw in ipairs(paths) do
    local rel = raw
    if fs.is_absolute(rel) then
      rel = fs.relpath(fs.abspath(rel), root)
    end
    rel = rel:gsub("^%./", ""):gsub("/+$", "")
    local hit = false
    for _, f in ipairs(files) do
      if covers(rel, f.path) then
        hit = true
        if not seen[f.path] then
          seen[f.path] = true
          picked[#picked + 1] = f
        end
      end
    end
    if not hit then
      return nil, "make: nothing to do under: " .. raw
    end
  end
  table.sort(picked, function(a: File, b: File): boolean
      return a.path < b.path
    end)
  return picked
end

local record SelectModule
  covers: function(sel: string, path: string): boolean
  files: function(files: {File}, paths: {string}, root: string): {File} | nil, string
end

local M: SelectModule = {
  covers = covers,
  files = select_files,
}

return M
