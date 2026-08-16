--- The env stamp: a test's declared environment values, hashed, so a
--- changed value is a changed prerequisite.
---
--- `--make test` schedules on the graph's file prerequisites. Nothing
--- in the tree depends on `FUZZ_ITERS` or `FUZZ_SEED`, so a run that
--- only changes one replays a cached verdict: every prerequisite of
--- `o/<path>.test.got` is unmoved, and even a forced recipe hits D18's
--- content skip, whose environment contribution is the fixed
--- `ENV_SWITCHES` list only. A declared name
--- (`_make.imports.env_of_file`) needs a FILE on the dependency list
--- for its value to become a prerequisite (mtime scheduling), a
--- content-key input (D18's `--deps` bytes), and a fence grant, the
--- same three answers one stroke gives a declared `reads:` path.
---
--- Mirrors `_make/stamp.tl`'s write-if-changed contract exactly: a
--- stamp is rewritten only when its bytes change, so an unmoved value
--- never touches the mtime the graph schedules on.

local env = require("cosmic.env")
local fs = require("cosmic.fs")
local hash = require("cosmic.hash")
local imports = require("_make.imports")
local project = require("_make.project")
local types = require("_make.types")

local type Project = types.Project

--- A stamp's path, relative to the project root. Dot-prefixed for the
--- same reason `o/.stamp/` and `o/.coverage/` are: the source-tree
--- mirror under `o/` maps `o/<path>` to the source at `<path>`, and a
--- dot-prefixed name is one the mirror cannot reach, so the engine may
--- own it without colliding with a project file.
--- @param stem string The make-variable stem (path with its extension removed)
--- @return string The stamp file, relative to the project root
local function path_of(stem: string): string
  return fs.join(project.BUILD_DIR, ".env", stem .. ".env")
end

--- The declared names' current values, reduced to one digest — never
--- plaintext, since `o/` must not collect secrets (`env.d/*` is
--- gitignored for exactly this reason). Built from one line per name,
--- sorted, `NAME=value` for a set variable (empty string included, as
--- `NAME=`) or bare `NAME` for an unset one: unset and empty must hash
--- differently, since a step branching on "is this set at all" and one
--- branching on its value are reading different questions.
--- @param names {string} Declared environment variable names
--- @return string The stamp content: one hex digest, newline-terminated
local function content(names: {string}): string
  local sorted: {string} = {}
  for _, n in ipairs(names) do
    sorted[#sorted + 1] = n
  end
  table.sort(sorted)
  local lines: {string} = {}
  for _, n in ipairs(sorted) do
    local v = env.get(n)
    lines[#lines + 1] = v == nil and n or (n .. "=" .. v)
  end
  return hash.sha256_hex(table.concat(lines, "\n")) .. "\n"
end

--- Write `path` only when the bytes differ, so an unmoved value does
--- not touch the mtime the graph schedules on.
--- @param path string Destination
--- @param body string Desired contents
--- @return boolean, string Success, or false plus the error
local function write_if_changed(path: string, body: string): boolean, string
  if fs.read(path) == body then
    return true
  end
  local ok, err = fs.make_dirs(fs.dirname(path))
  if not ok then
    return false, "make: cannot create " .. fs.dirname(path) .. ": " ..
    (err or "unknown error")
  end
  local wok, werr = fs.write(path, body)
  if not wok then
    return false, "make: cannot write " .. path .. ": " ..
    (werr or "unknown error")
  end
  return true
end

--- Write every declaring file's stamp, for the whole project.
---
--- Called from `materialize`, before make runs. Written for every file
--- with a non-empty declaration regardless of the run's selection:
--- selection narrows `tests`, never `deps_<stem>`, and make hard-errors
--- on a named-but-missing prerequisite. `o/.env/` is never cleared; a
--- stamp orphaned by a deleted test is inert and dies with
--- `--make clean`.
--- @param proj Project The scanned project
--- @return boolean, string Success, or false plus the error
local function write_all(proj: Project): boolean, string
  for _, f in ipairs(proj.files) do
    if types.runs_against_the_stage[f.kind] then
      local names, err = imports.env_of_file(proj.root, f.path)
      if not names then
        return false, "make: " .. (err or "bad env declaration")
      end
      if #names > 0 then
        local stem = (f.path:gsub("%.tl$", ""):gsub("%.lua$", ""))
        local ok, werr = write_if_changed(path_of(stem), content(names))
        if not ok then
          return false, werr
        end
      end
    end
  end
  return true
end

local record EnvstampModule
  path_of: function(stem: string): string
  content: function(names: {string}): string
  write_all: function(proj: Project): boolean, string
end

local M: EnvstampModule = {
  path_of = path_of,
  content = content,
  write_all = write_all,
}

return M
