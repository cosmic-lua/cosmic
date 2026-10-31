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
--- construction, as [`cosmic/fs.tl`] is. See [`positions.check`].
---
--- The module shape comes from [`build.module`]; this check is a
--- whole-plan gate, outside the identity of a cached compile.

local Fs = require("cosmic.fs")
local AnalysisSchema = require("build.analysis_schema")
local type module = require("build.module")
local type tree = require("build.tree")
local type Module = module.Plan

local record positions
  Module: Module
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
  if file == dir .. "/init.tl" or file == dir .. "/init.tmpl" then
    return dirname(dir)
  end
  return dir
end

--- Where an `internal` directory scopes a file to: the directory `parent` that holds the `internal` component ("" for the
--- root), and the directory `through` that component.
local record Scope
  parent: string
  through: string
end

--- The directory that scopes `file` by the Go rule: the parent `X` of the last `internal` directory component of its
--- path, and the directory through that component. `a/b/internal/c.tl` is internal to `a/b`; `internal/c.tl` to the
--- root, which is "". Nil for a file with no such component.
local function internal_scope(file: string): Scope?
  local parts: mut {string} = {}
  for part in dirname(file):gmatch("[^/]+") do parts[#parts + 1] = part end
  for at = #parts, 1, -1 do
    if parts[at] == "internal" then
      return { parent = table.concat(parts, "/", 1, at - 1), through = table.concat(parts, "/", 1, at) }
    end
  end
  return nil
end

--- Whether a module of the test kind, or test support ([`analysis_schema.is_support`]): what only a test may require.
local function is_test_side(m: positions.Module): boolean
  return m.kind == "test" or AnalysisSchema.is_support(m.file)
end

--- Whether a file may import `build.*` in cosmic's own tree: one inside `build/` itself, the binary it implements
--- (a main), a test or test support.
--
-- TODO: move `build/` under `internal/` at the root and delete this clause, once the layering it keeps (the standard
-- library and the language must not require the compiler) can be said by the directory rule, which a tree-wide
-- `internal/` does not: every module is under the root.
local function may_import_build(m: positions.Module): boolean
  return m.kind == "main" or is_test_side(m) or Fs.within(m.file, "build")
end

--- Whether every require in `modules` respects position, and if not,
--- which one and why. Two rules hold in every project.
---
--- **A closed directory.** A module's home directory ([`home_of`]) is open
--- to every importer when it is the root, or a top-level directory with no
--- `init.tl` of its own: a namespace of flat modules, as `cosmic/` and
--- `build/` are. Any other directory is closed, and only a file inside
--- it may import a member of it. A directory's own `init.tl` is a member
--- of the directory around it, so it is the one path into a closed
--- directory from outside; a nested directory without one has no path
--- in at all. A module whose opening doc block holds the line `--- @public`
--- ([`build.analysis_schema`]'s `public_tag`) is open to every importer, wherever it sits.
---
--- **An `internal` directory.** A module whose path has an `internal` directory component, `X/internal/...`, may be
--- required only by modules under `X/` (the project's root for a top-level `internal/`), as Go has it. It stands in
--- the place of the closed-directory rule for that module, `X/internal/init.tl` included: the internal package itself
--- is internal to its parent.
---
--- Three more hold in cosmic's own tree alone (`standing.own`). A test and test support (a file of the top-level
--- `test/` directory) may be required only by a test or test support, since the tool carries neither
--- ([`build.work`]'s `is_tool`) and a test the tool carried for a module requiring it could change under that module
--- unseen; a project's program may require a test, its binary being built from its tree whole. And two places do not
--- fit the directory rule and are stated exceptions: the standard library's `cosmic/internal/` is internal to the tree
--- root, not to `cosmic/` (the tool and its tests are the library's implementation too), and `build/` is private to the
--- tool ([`may_import_build`]).
---
--- `cosmic.internal.*` is the standard library's shared machinery that users do not see: a project tree's module
--- requiring one is refused, one of the tree's own, or a Teal module the running binary carries (`carried`). A raw table
--- has neither, and its `.d.tl` is the reserved namespace's to guard.
---
--- Declarations (`.d.tl`) never reach this check: `collect` leaves
--- them out, and `cosmic/internal/`'s are guarded by the reserved
--- `cosmic.internal.` namespace, which no ordinary `require` satisfies.
--- @param modules every module the tree holds, with its requires
--- @param standing what the tree is to the running tool: cosmic's own tree may define `cosmic.*` and holds what that
---   reserves
--- @param carried whether the running binary carries a row of a module,
---   which tells a project tree's Teal `cosmic.internal.*` from a raw table
function positions.check(modules: {positions.Module}, standing: tree.Standing,
                         carried?: function(name: string): boolean): boolean, string
  local by_path: mut {string:positions.Module} = {}
  local entries: mut {string:string} = {}
  for _, m in ipairs(modules) do
    by_path[m.path] = m
    if basename(m.file) == "init.tl" or basename(m.file) == "init.tmpl" then
      entries[dirname(m.file)] = m.file
    end
  end
  for _, m in ipairs(modules) do
    for _, name in ipairs(m.requires) do
      local other = by_path[name]
      if name:sub(1, 16) == "cosmic.internal." and not standing.own and
          (other ~= nil or (carried ~= nil and carried(name))) then
        return false, m.file .. ": " .. name .. " is internal to cosmic's own tree; " ..
          "`cosmic.internal.*` is the standard library's, and a project may not require it"
      end
      if other ~= nil then
        local found = internal_scope(other.file)
        if found ~= nil then
          local scope, through = found.parent, found.through
          -- cosmic's own tree: the library's `cosmic/internal/` is internal to the root, not to `cosmic/`.
          --
          -- TODO: move `cosmic/internal/` to `internal/` at the root and delete this exception, which the Go rule
          -- as it stands then gives for nothing. It waits on the name `internal` being free of the projects that
          -- have a module of that name, since the library's would take it (`cosmic.internal.*` becomes
          -- `internal.*`), and on the reserved `cosmic.internal.` namespace moving with it.
          local library = standing.own and through == "cosmic/internal"
          if library then scope = "" end
          if scope ~= "" and not Fs.within(m.file, scope) then
            return false, m.file .. ": " .. name .. " is internal to " .. scope .. "/ (it sits in " .. through ..
              "/); only a module under " .. scope .. "/ may require it: move " .. m.file .. " under " .. scope ..
              "/, or " .. other.file .. " out of internal/"
          end
        else
          local home = home_of(other.file)
          local open = home == "" or (not home:find("/", 1, true) and entries[home] == nil) or
            AnalysisSchema.declares_public(other.source)
          if not open and not Fs.within(m.file, home) then
            local home_entry = entries[home]
            local entry = if home_entry ~= nil then ("its entry is " .. home_entry) else
              (home .. "/ has no init.tl entry") end
            return false, m.file .. ": " .. name .. " is private to " .. home ..
              "/; only a file inside it may import it (" .. entry .. "), or the module can say `--- @public`"
          end
        end
        if standing.own and Fs.within(other.file, "build") and not may_import_build(m) then
          return false, m.file .. ": " .. name .. " is private to build/ in cosmic's own tree; " ..
            "only build/, a main, a test and test support may import it"
        end
        if standing.own and is_test_side(other) and not is_test_side(m) then
          return false, m.file .. ": " .. name .. " is a test or test support; only a test or test " ..
            "support may import one, since the tool carries none"
        end
      end
    end
  end
  return true, ""
end

return positions
