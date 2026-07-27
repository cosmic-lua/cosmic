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
local types = require("_make.types")

local type Project = types.Project

--- Which kinds carry documentation worth publishing.
---
--- Modules and entries are the API. Tests and examples are not: an
--- example's value is that it RUNS, and `--examples` already surfaces
--- them. `.d.tl` declarations are included because the `cosmo.*` binding
--- surface is documentation people read.
local DOCUMENTED < const >: {string: boolean} = {
  ["module"] = true,
  ["entry"] = true,
  ["types"] = true,
}

--- The markdown path for a source, under the docs output directory.
--- @param path string Source path, relative to the root
--- @return string Output path, relative to the root
local function page_of(path: string): string
  local stem = path:gsub("%.d%.tl$", ""):gsub("%.tl$", ""):gsub("%.lua$", "")
  return fs.join(project.BUILD_DIR, "docs", stem .. ".md")
end

--- Render the project's documentation.
--- @param proj Project The scanned project
--- @return integer Count of pages written
--- @return string The error message, empty on success
local function render(proj: Project): integer, string
  local written = 0
  for _, f in ipairs(proj.files) do
    if DOCUMENTED[f.kind] then
      local ok, output = doc.render_file(f.path)
      if not ok then
        return written, "make: " .. f.path .. ": " .. output
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
  end
  return written, ""
end

local record MakeDocsModule
  render: function(proj: Project): integer, string
  page_of: function(path: string): string
end

local M: MakeDocsModule = {
  render = render,
  page_of = page_of,
}

return M
