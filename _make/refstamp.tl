--- The ref stamp: a declared git ref's current commit, written to a
--- prerequisite so a moved ref is a moved dependency.
---
--- A test that reads a git ref at run time (`_build/doc_paths_test.tl`
--- checks the prose's `_work/` pointers against cosmic-lua/work's
--- fetched `refs/remotes/work/main` through `git ls-tree`) has an
--- input no path names: the ref is not a file
--- under the project root, so no `reads:` path can cover it, and a
--- fetch that moves it leaves every prerequisite of
--- `o/<path>.test.got` unmoved -- the cached verdict replays over a
--- tree the test never checked. A `--- ref: <name>` line
--- (`_make.imports.refs_of_file`) declares the ref; this module
--- resolves each declared name ONCE per graph build (`git rev-parse`)
--- and writes the answer to `o/.ref/<stem>.ref`, which joins
--- `deps_<stem>` exactly like an env stamp: a prerequisite (mtime
--- scheduling), a content-key input (its bytes ride in via `--deps`),
--- and a fence grant, in one stroke.
---
--- A ref that does not resolve -- not fetched, no repository, no git,
--- a probe timeout -- stamps as the bare name: "absent" keys
--- differently from every commit, and the declaring test's own skip
--- path answers for the run. Plaintext, unlike the env stamp's hash: a
--- commit id is no secret, and a stamp a reader can `cat` is the one
--- that explains its own re-run.
---
--- Reuses `_make/stamp.tl`'s `write_if_changed`: an unmoved ref never
--- touches the mtime the graph schedules on.

local child = require("cosmic.child")
local fs = require("cosmic.fs")
local imports = require("_make.imports")
local project = require("_make.project")
local stamp = require("_make.stamp")
local types = require("_make.types")

local type Project = types.Project

--- How long one `git rev-parse` may take. A hung `git` (a lock held by
--- another process) must not hang every graph build.
local PROBE_MS < const > = 10000

--- A stamp's path, relative to the project root. Dot-prefixed for the
--- reason `o/.env/` is: the source-tree mirror under `o/` cannot reach a
--- dot-prefixed name, so the engine may own it without colliding with a
--- project file.
--- @param stem string The make-variable stem (path with its extension removed)
--- @return string The stamp file, relative to the project root
local function path_of(stem: string): string
  return fs.join(project.BUILD_DIR, ".ref", stem .. ".ref")
end

--- The commit a ref names right now: one bounded `git rev-parse
--- --verify -q <name>` in the current directory, which is the project
--- root (`--make` enters it before the graph is built). Nil for every
--- way git can fail to answer -- no such ref, no repository, no git, a
--- timeout -- because the stamp treats them all as "absent" and the
--- declaring test tells them apart at run time. Follows
--- `_make/vcs.tl`'s `run_git`: empty stdin, a wait timeout, `h:stop()`
--- on the timeout path so the child does not leak.
--- @param name string The ref name, as declared
--- @return string | nil The commit id, or nil when git cannot say
local function resolve(name: string): string | nil
  local h, serr = child.start({"git", "rev-parse", "--verify", "-q", name},
    {stdin = ""})
  if not (h is child.Handle) then
    local _ = serr
    return nil
  end
  local r = h:wait(PROBE_MS)
  if not (r is child.Result) then
    local _ok, _err = h:stop() -- start's partner, so the child does not leak
    return nil
  end
  if not r.ok then
    return nil
  end
  return (r.stdout or ""):match("^(%x+)%s*$")
end

--- The stamp's bytes: one line per declared name, sorted --
--- `name=commit` for a ref that resolved, the bare `name` for one that
--- did not. Absent must key differently from every commit, and a stamp
--- that reads `refs/remotes/work/main=<commit>` explains its own
--- re-run.
--- @param names {string} Declared ref names
--- @param commits {string: string} Each name's commit; absent when unresolved
--- @return string The stamp content, newline-terminated
local function content(names: {string}, commits: {string: string}): string
  local sorted: {string} = {}
  for _, n in ipairs(names) do
    sorted[#sorted + 1] = n
  end
  table.sort(sorted)
  local lines: {string} = {}
  for _, n in ipairs(sorted) do
    local sha = commits[n]
    lines[#lines + 1] = sha and (n .. "=" .. sha) or n
  end
  return table.concat(lines, "\n") .. "\n"
end

--- Write every declaring file's stamp, resolving each distinct ref once
--- for the whole project: the channel costs one `git rev-parse` per
--- declared ref per graph build, not per declaring test.
---
--- Called from `materialize`, before make runs, for every declaring
--- file regardless of the run's selection: selection narrows `tests`,
--- never `deps_<stem>`, and make hard-errors on a named-but-missing
--- prerequisite. `o/.ref/` is never cleared; a stamp orphaned by a
--- deleted test is inert and dies with `--make clean`.
--- @param proj Project The scanned project
--- @return boolean, string Success, or false plus the error
local function write_all(proj: Project): boolean, string
  local commits: {string: string} = {}
  local asked: {string: boolean} = {}
  for _, f in ipairs(proj.files) do
    if types.runs_against_the_stage[f.kind] then
      local names, err = imports.refs_of_file(proj.root, f.path)
      if not names then
        return false, "make: " .. (err or "bad ref declaration")
      end
      if #names > 0 then
        for _, n in ipairs(names) do
          if not asked[n] then
            asked[n] = true
            local sha = resolve(n)
            if sha then
              commits[n] = sha
            end
          end
        end
        local stem = (f.path:gsub("%.tl$", ""):gsub("%.lua$", ""))
        local ok, werr = stamp.write_if_changed(path_of(stem),
          content(names, commits))
        if not ok then
          return false, werr
        end
      end
    end
  end
  return true
end

local record RefstampModule
  path_of: function(stem: string): string
  resolve: function(name: string): string | nil
  content: function(names: {string}, commits: {string: string}): string
  write_all: function(proj: Project): boolean, string
end

local M: RefstampModule = {
  path_of = path_of,
  resolve = resolve,
  content = content,
  write_all = write_all,
}

return M
