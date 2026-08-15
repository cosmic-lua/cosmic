--- The module manifest: the closure a child resolves its requires
--- through.
---
--- `docs/design/make/resolution.md` settles the rule — in a project the
--- tree answers, outside one the binary does — and this is the channel.
--- The closure is already in the recipe line as `--deps <built…>`,
--- computed by `_make.deps` for the graph (so a test re-runs when what
--- it imports changes) and for the fence (so it may read what it
--- imports). This makes it three consumers of one list: schedule,
--- fence, resolve. Nothing new is declared; the argument positions stay
--- the declaration.
---
--- **Argv, never the environment.** Ten of this repo's own tests spawn
--- a cosmic against a DIFFERENT project root under `/tmp`. Carried in
--- the environment, this tree's `o/` would answer their imports while
--- they built something else. A manifest named on one command line
--- cannot leak into a grandchild.

local fs = require("cosmic.fs")

--- Suffix of the manifest a step writes beside its own output.
---
--- Beside `<out>`, so it lands inside the write grant the step already
--- has: `record`'s shape names `<out>` as its one writable position and
--- a write grants the parent directory. A manifest anywhere else would
--- need a grant of its own, which is a rule the fence should not have
--- to learn.
local SUFFIX < const > = ".modules"

--- The build directory, duplicated from `_make.project.BUILD_DIR`.
---
--- Duplicated rather than required: `_cli/build/steps.tl` states, at the
--- top, that the recipe steps depend on the embedded stdlib and nothing
--- being built, and reaching into `_make` from a step would be the first
--- exception. `modules_test.tl` asserts the two agree, which is the
--- repo's usual answer for a constant that must exist in two places.
local BUILD_DIR < const > = "o"

--- The import path a built file answers to.
---
--- The inverse of the graph's own layout rule: `o/<path>.lua` is the
--- output for the source at `<path>`, and a source's path relative to
--- the root IS its import path. So stripping the build directory and
--- the extension, and turning `/` into `.`, is not a heuristic — it is
--- that rule read backwards.
--- @param built string A built path, relative to the root (`o/x/y.lua`)
--- @param build_dir string The build directory name (`o`)
--- @return string|nil The import path, or nil when it is not one
local function import_path(built: string, build_dir: string): string | nil
  local prefix = build_dir .. "/"
  if built:sub(1, #prefix) ~= prefix then
    return nil
  end
  local rel = built:sub(#prefix + 1)
  local stem = rel:match("^(.*)%.lua$")
  if not stem then
    return nil
  end
  -- `x/init.lua` is the package `x`, the same way `x/init.tl` is.
  stem = stem:gsub("/init$", "")
  return (stem:gsub("/", "."))
end

--- Render a manifest.
---
--- Three line kinds, so a reader never infers one from another:
--- `root <absolute path>`, `build <dir>`, `mod <import.path> <file>`.
--- The build directory is here rather than assumed by the reader
--- because the reader is the bootstrap and may not require anything
--- that knows it. The `mod` lines are sorted, so
--- the bytes are a function of the closure and not of the order make
--- happened to list it — a manifest that churns is a file whose mtime
--- lies about what changed.
--- @param root string The absolute project root
--- @param built {string} Built paths, relative to the root
--- @param build_dir string The build directory name
--- @return string The manifest text
local function render(root: string, built: {string},
    build_dir: string): string
  local lines: {string} = {"root " .. root, "build " .. build_dir}
  local mods: {string} = {}
  for _, path in ipairs(built) do
    local name = import_path(path, build_dir)
    if name ~= nil then
      mods[#mods + 1] = "mod " .. name .. " " .. fs.join(root, path)
    end
  end
  table.sort(mods)
  for _, line in ipairs(mods) do
    lines[#lines + 1] = line
  end
  return table.concat(lines, "\n") .. "\n"
end

--- Write the manifest for a step and return the path to name on the
--- child's command line.
---
--- A failure to write is a MISS, not an error: the child then runs as
--- an ordinary cosmic and resolves without a manifest. Refusing the
--- step instead would turn a full disk into a build failure in the one
--- place that cannot explain itself.
--- @param out string The step's output base
--- @param root string The absolute project root
--- @param built {string} Built paths from `--deps`, relative to the root
--- @return string|nil The manifest path, or nil when it could not be written
local function write(out: string, root: string,
    built: {string}): string | nil
  local path = out .. SUFFIX
  local dir = fs.dirname(path)
  if dir ~= "" and dir ~= "." and not fs.is_dir(dir) then
    if not fs.make_dirs(dir) then
      return nil
    end
  end
  if not fs.write(path, render(root, built, BUILD_DIR)) then
    return nil
  end
  return path
end

--- Write the manifest and put `--modules <path>` on a child's argv.
---
--- Both halves of the channel in one place: the file format above and
--- the argument convention here. It goes right after the program, ahead
--- of everything the child parses -- the dispatcher acts on it before
--- its first require, and the child's own positionals are untouched
--- because getopt takes the flag's argument with it.
--- @param argv {string} The child's argv, modified in place
--- @param out string The step's output base
--- @param root string The absolute project root
--- @param built {string} Built paths from `--deps`, relative to the root
local function attach(argv: {string}, out: string, root: string,
    built: {string})
  local path = write(out, root, built)
  if path == nil then
    return
  end
  table.insert(argv, 2, "--modules")
  table.insert(argv, 3, path)
end

local record ModulesModule
  BUILD_DIR: string
  SUFFIX: string
  attach: function(argv: {string}, out: string, root: string, built: {string})
  import_path: function(built: string, build_dir: string): string | nil
  render: function(root: string, built: {string}, build_dir: string): string
  write: function(out: string, root: string, built: {string}): string | nil
end

local M: ModulesModule = {
  BUILD_DIR = BUILD_DIR,
  SUFFIX = SUFFIX,
  attach = attach,
  import_path = import_path,
  render = render,
  write = write,
}

return M
