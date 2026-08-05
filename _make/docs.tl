--- `docs` — render every documented source to `o/docs/<path>.md`.
---
--- In process rather than as a rule family. Rendering is a pure function
--- of one file, there is nothing to link or order, and the whole tree
--- takes about as long as spawning the recipe children would; a rule per
--- file would buy incrementality for a job that only ever runs whole,
--- on a push to main.
---
--- The file set comes from the MODEL, which is the point: a doc site
--- that enumerates sources for itself drifts from the project the moment
--- a directory is added, and drifts silently, because a missing page
--- looks like a page nobody wrote.

local doc = require("cosmic.doc")
local fs = require("cosmic.fs")
local project = require("_make.project")
local selection = require("_make.select")
local types = require("_make.types")

local type File = types.File
local type Kind = types.Kind
local type Project = types.Project

--- Which kinds carry documentation worth publishing.
---
--- Modules and entries are the API. Tests and examples are not: an
--- example's value is that it RUNS, and `--examples` already surfaces
--- them. `.d.tl` declarations are included because the `cosmo.*` binding
--- surface is documentation people read.
---
--- A LIST, because the selection law asks the same question the render
--- loop does -- "is this file a page?" -- and two spellings of one
--- answer is how `--make docs cosmic/fs` comes to select over a set the
--- renderer does not use.
local KINDS < const >: {Kind} = {"module", "entry", "types"}

--- The markdown path for a source, under the docs output directory.
--- @param path string Source path, relative to the root
--- @return string Output path, relative to the root
local function page_of(path: string): string
  local stem = path:gsub("%.d%.tl$", ""):gsub("%.tl$", ""):gsub("%.lua$", "")
  return fs.join(project.BUILD_DIR, "docs", stem .. ".md")
end

--- Render the selected documentation.
---
--- A page is a pure function of one source, so `docs` restricts like
--- every other verb: `--make docs cosmic/fs` writes those pages and
--- leaves the rest of `o/docs` alone. Nothing here is whole-project --
--- there is no index to go partial -- which is what makes the
--- restriction meaningful rather than a partial artifact wearing a
--- full one's name.
--- @param proj Project The scanned project
--- @param paths {string} Selection paths, empty for every page
--- @return integer Count of pages written
--- @return string The error message, empty on success
local function render(proj: Project, paths?: {string}): integer, string
  local picked, serr = selection.files(project.of_kind(proj, KINDS),
    paths or {}, proj.root)
  if not picked then
    return 0, serr or "make: no such selection"
  end
  local written = 0
  for _, f in ipairs(picked as {File}) do -- cast: nil ruled out above
    local output, rerr = doc.render_file(f.path)
    if output == nil then
      return written, "make: " .. f.path .. ": " .. tostring(rerr)
    end
    local out = page_of(f.path)
    if not fs.makedirs(fs.dirname(out)) then
      return written, "make: cannot create " .. fs.dirname(out)
    end
    local wok, werr = fs.write(out, output)
    if not wok then
      return written, "make: cannot write " .. out .. ": " ..
      (werr or "unknown error")
    end
    written = written + 1
  end
  return written, ""
end

local record MakeDocsModule
  KINDS: {Kind}
  render: function(proj: Project, paths?: {string}): integer, string
  page_of: function(path: string): string
end

local M: MakeDocsModule = {
  KINDS = KINDS,
  render = render,
  page_of = page_of,
}

return M
