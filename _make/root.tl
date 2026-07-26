--- Root discovery for `cosmic --make`.
---
--- The root is the current directory. There is no search upward for a
--- marker file, because "which project am I in" answered by a search is
--- the bug that makes a build write into the wrong tree — the shape
--- #795 hit here when a scan of one directory produced output in
--- another.
---
--- What the search upward IS for is refusing: if an ancestor also looks
--- like a project, running from a subdirectory would build a *different*
--- project than the one the user meant, quietly and with a smaller file
--- list. So the ancestor scan exists only to say no, and to name the
--- likely root and the exact command.
---
--- `COSMIC_MAKE_ROOT` names the root explicitly, for callers that
--- cannot chdir (tests, and any tool driving make from elsewhere). It
--- suppresses the guard, because the guard exists to catch an *implied*
--- root — a cwd the user did not think about. Naming one is thinking
--- about it.

local fs = require("cosmic.fs")
local project = require("_make.project")

--- Environment override for the project root.
local ROOT_ENV < const > = "COSMIC_MAKE_ROOT"

--- Whether a directory is some project's build output.
---
--- It has to be asked, because a build directory is a MIRROR of the
--- project that produced it: `o/cmd/foo/main.lua` exists precisely
--- because `cmd/foo/main.tl` compiled, so every marker `is_root` looks
--- for is on both sides and the two are indistinguishable by shape.
--- What distinguishes them is authorship — `--make` writes its own two
--- makefiles into the directory it builds into, and nothing else does.
---
--- Without this, anything running under `o/` (which is where a test's
--- scratch directory lives) finds `o/` above it, and `--make` refuses
--- with "ambiguous root" naming the build directory as the project.
--- @param dir string Absolute directory to test
--- @return boolean True when dir is a `--make` output tree
local function is_build_dir(dir: string): boolean
  return fs.isfile(fs.join(dir, "cosmic.mk")) and
  fs.isfile(fs.join(dir, "project.mk"))
end

--- Files and directories a project declares itself with. A stray `.tl`
--- is deliberately NOT one of them: a directory of Teal files is a
--- package inside some project, and treating it as a root is what makes
--- the guard fire on ordinary source trees.
--- @param dir string Absolute directory to test
--- @return boolean True when dir looks like a project root
local function is_root(dir: string): boolean
  if is_build_dir(dir) then
    return false
  end
  if fs.isfile(fs.join(dir, ".cosmicignore")) then
    return true
  end
  if fs.isfile(fs.join(dir, "main.tl")) or fs.isfile(fs.join(dir, "main.lua")) then
    return true
  end
  local cmd = fs.join(dir, "cmd")
  if fs.isdir(cmd) then
    for _, pattern in ipairs({"*/main.tl", "*/main.lua"}) do
      local hits = (fs.glob(cmd, pattern) or {}) as {string} -- cast: or keeps the nil union
      if #hits > 0 then
        return true
      end
    end
  end
  return false
end

--- The nearest strict ancestor of `dir` that looks like a project root.
---
--- The walk stops at an output directory. Anything under `<root>/o/` is
--- something a build PUT there — a staged tree, a generator's output, a
--- test's scratch directory — and a project inside it is deliberate,
--- not the accident the guard exists to catch. Without this, every
--- nested `--make` run inside a test's own scratch directory refused
--- with "ambiguous root", naming the repo whose build put it there.
--- @param dir string Absolute directory
--- @return string|nil The ancestor's path, or nil when there is none
local function ancestor_root(dir: string): string | nil
  local cur = dir
  while true do
    local parent = fs.dirname(cur)
    if parent == cur or parent == "" then
      return nil
    end
    if fs.basename(parent) == project.BUILD_DIR then
      return nil
    end
    if is_root(parent) then
      return parent
    end
    cur = parent
  end
end

--- Resolve the project root for this run.
---
--- Returns the absolute root, or nil plus the refusal. The refusal is
--- multi-line on purpose: the second line is the command to run.
--- @param verb string The verb being run, used in the suggested command
--- @return string|nil The absolute project root
--- @return string The refusal message when discovery failed
local function discover(verb: string): string | nil, string
  local override = os.getenv(ROOT_ENV)
  if override and override ~= "" then
    local named = fs.abspath(override)
    if not fs.isdir(named) then
      return nil, "make: not a directory: " .. override
    end
    return named
  end
  local cwd, err = fs.getcwd()
  if not cwd then
    return nil, "make: cannot determine the current directory: " ..
    (err or "unknown error")
  end
  local abs = fs.abspath(cwd)
  local ancestor = ancestor_root(abs)
  if ancestor then
    return nil, "make: ambiguous root: " .. abs ..
    " is inside a project rooted at " .. ancestor ..
    "\nmake: run it from that root: cd " .. ancestor ..
    " && cosmic --make " .. verb ..
    "\nmake: or name this one: " .. ROOT_ENV .. "=" .. abs ..
    " cosmic --make " .. verb
  end
  return abs
end

local record RootModule
  ROOT_ENV: string
  is_root: function(dir: string): boolean
  ancestor_root: function(dir: string): string | nil
  discover: function(verb: string): string | nil, string
end

local M: RootModule = {
  ROOT_ENV = ROOT_ENV,
  is_root = is_root,
  ancestor_root = ancestor_root,
  discover = discover,
}

return M
