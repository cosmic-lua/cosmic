--- Root discovery for `cosmic --make`.
---
--- The root is the current directory. There is no search upward for a
--- marker file: "which project am I in" answered by a search can
--- silently resolve to an ancestor project, and a build that scans one
--- directory but writes its output into another is the failure mode to
--- avoid.
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
local proc = require("cosmic.proc")
local project = require("_make.project")
local validate = require("_make.validate")

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
  return fs.is_file(fs.join(dir, "cosmic.mk")) and
  fs.is_file(fs.join(dir, "project.mk"))
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
  if fs.is_file(fs.join(dir, ".cosmicignore")) then
    return true
  end
  if fs.is_file(fs.join(dir, "main.tl")) or fs.is_file(fs.join(dir, "main.lua")) then
    return true
  end
  local cmd = fs.join(dir, "cmd")
  if fs.is_dir(cmd) then
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

--- Refuse a root make cannot name.
---
--- A makefile's prerequisite list is whitespace-separated and there is
--- no escape that survives it, so a root with a space in its path
--- cannot be expressed at all: `o/project.mk` assigns `COSMIC` to that
--- path and every recipe line starts with `$(COSMIC)`, so make would
--- read one path as two. The recipe side agrees — a line is argv,
--- whitespace-split, by design.
---
--- Said up front, because the alternative is a make error reporting a
--- missing prerequisite named after the first word of your home
--- directory, which explains nothing about the path being the problem.
--- `/Users/me/My Projects/thing` is an ordinary place to keep a
--- checkout, and "cosmic does not support this" is a fine answer;
--- "no rule to make target `/Users/me/My'" is not.
---
--- Whitespace is not the only character make reads specially in that
--- same `COSMIC` assignment and every recipe line: `$`
--- starts a make expansion, `(` `)` close one, `:` and `=` can end a
--- rule or assignment early, and `%` is a pattern wildcard in a target
--- position. `validate.METACHARACTERS` is the same list a project path
--- is refused for, reused here rather than kept as a second copy that
--- could drift from it — a root corrupting the makefile it names is the
--- same hazard as a source path doing it, one level up.
--- @param root string The absolute root
--- @return string|nil The refusal, or nil when the path is expressible
local function unnameable(root: string): string | nil
  if root:find("%s") then
    return "make: unusable project root: " .. root ..
    "\nmake: the path contains whitespace, and make prerequisites are" ..
    " whitespace-separated with no escape that survives" ..
    "\nmake: move or link the checkout to a path without spaces"
  end
  for i = 1, #validate.METACHARACTERS do
    local c = validate.METACHARACTERS:sub(i, i)
    if root:find(c, 1, true) then
      return "make: unusable project root: " .. root ..
      "\nmake: the path contains '" .. c .. "', a make-significant" ..
      " character with no escape that survives a recipe line or a" ..
      " variable assignment" ..
      "\nmake: move or link the checkout to a path without it"
    end
  end
  return nil
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
    local named = fs.absolute_path(override)
    if not fs.is_dir(named) then
      return nil, "make: not a directory: " .. override
    end
    local bad = unnameable(named)
    if bad then
      return nil, bad
    end
    return named
  end
  local cwd, err = fs.cwd()
  if not cwd then
    return nil, "make: cannot determine the current directory: " ..
    (err or "unknown error")
  end
  local abs = fs.absolute_path(cwd)
  local bad = unnameable(abs)
  if bad then
    return nil, bad
  end
  local ancestor = ancestor_root(abs)
  if ancestor then
    return nil, "make: ambiguous root: " .. abs ..
    " is inside a project rooted at " .. ancestor ..
    "\nmake: run it from that root: cd " .. ancestor ..
    " && cosmic --make " .. verb ..
    "\nmake: or name this one: " .. ROOT_ENV .. "=" .. abs ..
    " cosmic --make " .. verb
  end
  -- The twin of the refusal above: the cwd itself must be asked
  -- whether it is a project, or EVERY directory would be one. Without
  -- this check, `--make build` in an empty directory would report PASS
  -- over nothing, and `--make test` would write `o/` plus a 1.5 MB
  -- extracted engine into whatever directory you were standing in --
  -- your home directory, if that is where you typed it. A typo that
  -- becomes a green build is the failure selection already refuses;
  -- this is that failure applied to the largest selection of all.
  --
  -- `COSMIC_MAKE_ROOT` is the escape hatch and returns above, which is
  -- what makes it usable here: naming a root is how you say you meant
  -- a directory that does not declare itself.
  if not is_root(abs) then
    return nil, "make: not a project: " .. abs ..
    "\nmake: a project declares itself with main.tl, cmd/<name>/main.tl," ..
    " or .cosmicignore" ..
    "\nmake: to build this directory anyway: " .. ROOT_ENV .. "=" .. abs ..
    " cosmic --make " .. verb
  end
  return abs
end

--- Resolve the running cosmic binary from `argv0` (`arg[-1]`, as the
--- kernel saw it) into an absolute, existing path.
---
--- A bare PATH-invoked name (`cosmic`, no directory component -- the
--- ordinary shape of a shebang, or a shell that found it on $PATH) is
--- not a path to resolve against the cwd: `fs.absolute_path` alone turns it
--- into a PHANTOM `<cwd>/cosmic` that happens not to exist wherever cwd
--- is not the install directory, and everything downstream that
--- assumes the result names a real file quietly degrades -- a tool
--- stamp that cannot read its binary falls back to its constant
--- no-binary form, dropping tool freshness from the graph, silently.
--- A real $PATH search is what argv0 actually meant in that shape.
--- @param argv0 string `arg[-1]`, or a fallback name
--- @return string|nil The absolute path, or nil when unresolvable
local function resolve_self(argv0: string): string | nil
  local abs = fs.absolute_path(argv0)
  if fs.is_file(abs) then
    return abs
  end
  return (proc.which(argv0))
end

local record RootModule
  ROOT_ENV: string
  is_root: function(dir: string): boolean
  ancestor_root: function(dir: string): string | nil
  discover: function(verb: string): string | nil, string
  resolve_self: function(argv0: string): string | nil
end

local M: RootModule = {
  ROOT_ENV = ROOT_ENV,
  is_root = is_root,
  ancestor_root = ancestor_root,
  discover = discover,
  resolve_self = resolve_self,
}

return M
