--- The reads stamp: a declared `reads:` tree's LISTING, hashed, so a
--- rename, add, or delete inside it is a changed prerequisite even
--- when every file's own mtime survives the edit untouched.
---
--- `reads_of_file` expands a declared directory into the sorted files
--- under it, and those files already ride `deps_<stem>` by mtime and
--- by content (D18's `--deps` bytes). That covers an in-place edit —
--- the changed file is newer than the recorded `.got`. It does not
--- cover `mv`/`git mv`: both preserve the moved file's mtime, so a
--- rename inside the tree can swap one already-old-mtime path for
--- another already-old-mtime path and leave nothing newer than the
--- `.got` — make never schedules the recipe, and the cached verdict
--- replays. The content key would catch it (it hashes input NAMES),
--- but only once make decides to run the recipe at all.
---
--- The fix is the same shape `_make/envstamp.tl` uses for a declared
--- value: a stamp file that captures the ANSWER (here, the sorted
--- list of paths the declaration currently expands to) rather than
--- relying on mtimes to reconstruct it, written only when the answer
--- changes. A rename changes the list -- one path drops out, another
--- appears -- so the stamp's bytes change, `write_if_changed` gives it
--- a fresh mtime, and that fresh mtime is what make schedules on.
---
--- Reuses `_make/stamp.tl`'s `write_if_changed`: an unmoved listing
--- never touches the mtime the graph schedules on, so a warm tree with
--- no structural change to any declared tree pays nothing extra.

local fs = require("cosmic.fs")
local hash = require("cosmic.hash")
local imports = require("_make.imports")
local project = require("_make.project")
local stamp = require("_make.stamp")
local types = require("_make.types")

local type Project = types.Project

--- A stamp's path, relative to the project root. Dot-prefixed for the
--- same reason `o/.env/` and `o/.coverage/` are: the source-tree
--- mirror under `o/` maps `o/<path>` to the source at `<path>`, and a
--- dot-prefixed name is one the mirror cannot reach, so the engine may
--- own it without colliding with a project file.
--- @param stem string The make-variable stem (path with its extension removed)
--- @return string The stamp file, relative to the project root
local function path_of(stem: string): string
  return fs.join(project.BUILD_DIR, ".reads", stem .. ".reads")
end

--- The declared reads' current expansion, reduced to one digest.
--- Hashes NAMES only, never bytes -- the files' own bytes are already
--- in the content key by their own mtime and `--deps` entry; this
--- stamp exists solely to notice that the SET of names changed.
--- @param paths {string} A declaration's expanded, root-relative paths
--- @return string The stamp content: one hex digest, newline-terminated
local function content(paths: {string}): string
  local sorted: {string} = {}
  for _, p in ipairs(paths) do
    sorted[#sorted + 1] = p
  end
  table.sort(sorted)
  return hash.sha256_hex(table.concat(sorted, "\n")) .. "\n"
end

--- Write every declaring file's stamp, for the whole project.
---
--- Called from `materialize`, before make runs -- same timing as
--- `envstamp.write_all`, for the same reason: `deps_<stem>` already
--- names the stamp file (project_mk), so it must exist with an honest
--- mtime before make reads a rule. Written for every file with a
--- non-empty `reads:` declaration regardless of the run's selection,
--- same as envstamp; `o/.reads/` is never cleared, and a stamp
--- orphaned by a deleted test is inert and dies with `--make clean`.
--- @param proj Project The scanned project
--- @return boolean, string Success, or false plus the error
local function write_all(proj: Project): boolean, string
  for _, f in ipairs(proj.files) do
    if types.runs_against_the_stage[f.kind] then
      local extra, err = imports.reads_of_file(proj.root, f.path)
      if not extra then
        return false, "make: " .. (err or "bad reads declaration")
      end
      if #extra > 0 then
        local stem = (f.path:gsub("%.tl$", ""):gsub("%.lua$", ""))
        local ok, werr = stamp.write_if_changed(path_of(stem), content(extra))
        if not ok then
          return false, werr
        end
      end
    end
  end
  return true
end

local record ReadstampModule
  path_of: function(stem: string): string
  content: function(paths: {string}): string
  write_all: function(proj: Project): boolean, string
end

local M: ReadstampModule = {
  path_of = path_of,
  content = content,
  write_all = write_all,
}

return M
