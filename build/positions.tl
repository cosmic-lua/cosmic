--- Position is the manifest: whether a file can be reached from outside
--- its own directory is a question of where it sits, not of its name.
---
--- A directory's own `init.tl` is the one path outside code may import,
--- the ordinary way Lua already resolves `require("a.b")` to
--- `a/b/init.tl`, and every other file directly inside that directory
--- is a sibling, reachable only from a file that itself sits inside it.
--- A nested directory with no `init.tl` has no path in at all. The root
--- and a top-level directory with no `init.tl` are namespaces instead:
--- each file directly in one is a flat module of its own, public by
--- construction, as `cosmic/fs.tl` is. See `positions.check`.
---
--- The `Module` shape lives here, not in `build.importer`, so this
--- check can be a plain function of a module list without the two
--- files requiring one another.

local Fs = require("cosmic.fs")
local type analyzer = require("build.analyzer")

local record positions
  record Module
    path: string
    file: string
    kind: string
    source: string
    source_hash: string
    requires: {string}
    --- The names the runner calls, bare: a `kind = "test"` module's own
    --- `local function test_*` names, or a `kind = "example"` module's
    --- `Example.<name>` names -- empty for any other kind. The two
    --- never mix in one module, since a file is only ever one kind.
    tests: {string}
    --- A test or example module's `_inputs` declaration (`build.inputs`),
    --- or nil for none (see `build.test_inputs`).
    inputs: analyzer.Declared | nil
    has_top_level_return: boolean
    --- True only for a module `build.doctest` produced from a
    --- `doc/guides/*.md` file rather than read off disk as `.tl`
    --- source: `build.importer.compile` widens its warning discount for
    --- exactly this module, and only this one, to cover the one
    --- `print`-shadowing warning that generated shape always carries --
    --- see `discount_doctest_shadow_warnings`.
    generated: boolean
    key: string
    --- The compiled Lua, once `build.importer.compile` has it: made
    --- this run or read back from the cache under the same key.
    lua: string
  end
end

--- The file's own name, with no directory in front of it.
local function basename(file: string): string
  return file:match("([^/]+)$") or file
end

--- The directory a file sits in, or "" when it sits at the tree's root.
local function dirname(file: string): string
  return file:match("^(.*)/[^/]+$") or ""
end

--- The directory `file`'s module is a member of: the one it sits in, or,
--- for a directory's own `init.tl`, the one that directory sits in --
--- `a/b/init.tl` is the module `a.b`, a member of `a/`.
local function home_of(file: string): string
  local dir = dirname(file)
  if file == dir .. "/init.tl" then
    return dirname(dir)
  end
  return dir
end

--- Whether a file may import `build.*`: one inside `build/` itself, the
--- binary it implements (`cmd/`), a test, or test support (`test/`).
local function may_import_build(m: positions.Module): boolean
  return m.kind == "test" or Fs.within(m.file, "build") or
    Fs.within(m.file, "cmd") or Fs.within(m.file, "test")
end

--- Whether every require in `modules` respects position, and if not,
--- which one and why. A module's home directory (`home_of`) is open to
--- every importer when it is the root, or a top-level directory with no
--- `init.tl` of its own -- a namespace of flat modules, as `cosmic/` and
--- `build/` are; any other directory is closed, and only a file inside
--- it may import a member of it. A directory's own `init.tl` is a member
--- of the directory around it, so it is the one path into a closed
--- directory from outside, and a nested directory without one has no
--- path in at all. In cosmic's own tree `build/` is private as well:
--- only `may_import_build`'s files may import from it.
---
--- Declarations (`.d.tl`) never reach this check: `collect` leaves
--- them out, and `cosmic/internal/`'s are guarded by the reserved
--- `cosmic.internal.` namespace, which no ordinary `require` satisfies.
--- @param modules every module the tree holds, with its requires
--- @param own_tree whether the tree is cosmic's own
function positions.check(modules: {positions.Module}, own_tree: boolean): boolean, string
  local by_path: {string:positions.Module} = {}
  local entries: {string:boolean} = {}
  for _, m in ipairs(modules) do
    by_path[m.path] = m
    if basename(m.file) == "init.tl" then
      entries[dirname(m.file)] = true
    end
  end
  for _, m in ipairs(modules) do
    for _, name in ipairs(m.requires) do
      local other = by_path[name]
      if other ~= nil then
        local home = home_of(other.file)
        local open = home == "" or (not home:find("/", 1, true) and not entries[home])
        if not open and not Fs.within(m.file, home) then
          local entry = entries[home] and ("its entry is " .. home .. "/init.tl")
            or (home .. "/ has no init.tl entry")
          return false, m.file .. ": " .. name .. " is private to " .. home ..
            "/; only a file inside it may import it (" .. entry .. ")"
        end
        if own_tree and Fs.within(other.file, "build") and not may_import_build(m) then
          return false, m.file .. ": " .. name .. " is private to build/; " ..
            "only build/, cmd/, test/ and tests may import it"
        end
      end
    end
  end
  return true, ""
end

return positions
