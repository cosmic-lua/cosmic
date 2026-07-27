--- The `cosmic --make` validator: everything a project can get wrong
--- that the model itself cannot express.
---
--- These messages are the first thing a newcomer — human or agent —
--- hits, so each one names the offending path, what is wrong, and the
--- rule behind it. They are asserted verbatim-enough by
--- validate_test.tl; treat a message change as an interface change.
---
--- Import edges come from a literal scan for `require("…")`. A computed
--- require is invisible here, which is stated rather than papered over:
--- the rules below are about the shape of a project, and a project that
--- computes its module names has already left that shape.

local fs = require("cosmic.fs")
local imports = require("_make.imports")
local project = require("_make.project")
local types = require("_make.types")

local type Issue = types.Issue
local type Project = types.Project

--- Import paths (and namespaces) the base already answers to. A project
--- file resolving at one of these would shadow what the artifact is
--- built on, so each is refused — but for two different reasons, and
--- only one of them is absolute.
local RESERVED < const >: {string} = {"cosmic", "cosmo", "tl", "main.user"}

--- Reserved namespaces a project MAY supply, by defining the
--- namespace's root module (`cosmic/init.tl`, `tl.lua`, ...). These are
--- ordinary Lua trees that happen to ship in the base, and the design
--- requires both to be providable: cosmic builds itself out of its own
--- `cosmic/`, and a project wanting Teal at runtime vendors `tl` the
--- same way.
---
--- Claiming takes the WHOLE namespace. Providing a piece without the
--- root stays refused, because that is the hazard the rule was written
--- for: with `cosmic/fs.tl` and no `cosmic/init.tl`,
--- `require("cosmic.fs")` resolves to the project while
--- `require("cosmic.json")` falls through to the base, and one binary
--- runs two standard libraries.
local PROVIDABLE < const >: {string: boolean} = {cosmic = true, tl = true}

--- Why the rest cannot be claimed at all. Nothing in a zip supplies
--- either, so a file landing there is a shadow by definition with
--- nothing to take over.
local UNPROVIDABLE < const >: {string: string} = {
  cosmo = "a native binding compiled into the interpreter",
  ["main.user"] = "the entry wrapper's slot for the project's own entry",
}

--- Characters a path may not contain. Recipe lines are whitespace-split
--- argv with no quoting anywhere, so a space is not an escaping problem
--- to solve but a filename to refuse — and the shell metacharacters go
--- with it, since the same paths reach a real shell in any project that
--- still has one. Accepted cost, by name: a legitimate `my notes.tl`.
local METACHARACTERS < const > = "#;\"'*?[]&|<>(){}$`^\\!~%:=,"

--- Kinds whose sources are scanned for import edges.
---
--- Every kind whose file is COMPILED, because `deps.tl` follows the
--- edge for all of them: a kind the scanner skips but the graph
--- resolves is a module that can reach into another binary's tree or a
--- foreign `_dir` with nothing to say so -- the scanner/consumer drift
--- `imports.tl`'s header disclaims, arriving through the one kind
--- nobody added here.
local scanned: {string: boolean} = {
  module = true,
  entry = true,
  test = true,
  example = true,
  benchmark = true,
  gen = true,
  ["payload-gen"] = true,
}

--- Kinds that define an import path other files can resolve to.
local defines_import: {string: boolean} = {
  module = true,
  entry = true,
  test = true,
  example = true,
  types = true,
}

--- Kinds that define an import path by carrying its *code*. A `.d.tl`
--- is deliberately absent: declaring types for a `.lua` implementation
--- beside it is the pattern `.d.tl` exists for, not a collision.
local claims_source: {string: boolean} = {
  module = true,
  entry = true,
  test = true,
  example = true,
}

--- Kinds that compile into `o/` without carrying an import path, so
--- two spellings of one collide over their OUTPUT rather than a name.
local compiles_without_import: {string: boolean} = {
  benchmark = true,
  gen = true,
}

--- Append an issue.
local function add(issues: {Issue}, path: string, message: string)
  issues[#issues + 1] = {path = path, message = message}
end

--- Refuse paths that cannot survive a whitespace-split recipe line.
--- Checked on every discovered path, assets included: an asset is
--- copied by a recipe like everything else.
local function check_names(proj: Project, issues: {Issue})
  for _, f in ipairs(proj.files) do
    if f.path:find("%s") then
      add(issues, f.path,
        "path contains whitespace; recipe lines are whitespace-split argv")
    else
      for i = 1, #METACHARACTERS do
        local c = METACHARACTERS:sub(i, i)
        if f.path:find(c, 1, true) then
          add(issues, f.path,
            "path contains a shell metacharacter: " .. c)
          break
        end
      end
    end
  end
end

--- The providable namespaces this project claims, by defining each
--- one's root module. The artifact half of the rule reads this: a
--- claimed namespace drops the base's copy, so exactly one definition
--- ships. Without that the exemption would be a validator opinion the
--- artifact contradicts — invisibly, since both copies load fine.
--- @param proj Project The scanned project
--- @return {string: boolean} The claimed namespaces
local function claims(proj: Project): {string: boolean}
  local out: {string: boolean} = {}
  for _, f in ipairs(proj.files) do
    if f.import and claims_source[f.kind] and PROVIDABLE[f.import] then
      out[f.import] = true
    end
  end
  return out
end

--- Refuse import paths that shadow the floor, unless the project has
--- claimed the namespace outright.
local function check_reserved(proj: Project, issues: {Issue})
  local claimed = claims(proj)
  for _, f in ipairs(proj.files) do
    local ip = f.import
    if ip then
      for _, r in ipairs(RESERVED) do
        if ip == r or ip:sub(1, #r + 1) == r .. "." then
          local why = UNPROVIDABLE[r]
          if why then
            add(issues, f.path, "reserved import path '" .. ip ..
              "'; '" .. r .. "' is " .. why ..
              ", which no project file can provide")
          elseif not claimed[r] then
            add(issues, f.path, "reserved import path '" .. ip ..
              "'; '" .. r .. "' is the standard library every artifact " ..
              "is built on. define " .. r .. "/init.tl to provide the " ..
              "whole namespace, or rename this file")
          end
          break
        end
      end
    end
  end
end

--- `.lua` sources are first-class, so `foo.tl` beside `foo.lua` is two
--- files claiming one import path. That is an error, not a precedence
--- rule — a precedence rule is a coin flip nobody remembers.
local function check_duplicates(proj: Project, issues: {Issue})
  local seen: {string: string} = {}
  for _, f in ipairs(proj.files) do
    local ip = f.import
    if ip and claims_source[f.kind] then
      local first = seen[ip]
      if first then
        add(issues, f.path, "duplicate import path '" .. ip ..
          "'; also defined by " .. first)
      else
        seen[ip] = f.path
      end
    end
  end
  -- A benchmark and a generator compile but carry no import path, so
  -- the pass above cannot see `foo_benchmark.tl` beside
  -- `foo_benchmark.lua`. Both land on one `o/foo_benchmark.lua`, both
  -- pattern rules match it, and make picks one -- the coin flip this
  -- check exists to refuse, arriving through the kinds that have no
  -- name to collide on. The OUTPUT path is what they actually collide
  -- over, so that is what this asks about.
  local outputs: {string: string} = {}
  for _, f in ipairs(proj.files) do
    if compiles_without_import[f.kind] then
      local out = (f.path:gsub("%.tl$", ""):gsub("%.lua$", "")) .. ".lua"
      local first = outputs[out]
      if first then
        add(issues, f.path, "duplicate build output '" .. out ..
          "'; also produced by " .. first)
      else
        outputs[out] = f.path
      end
    end
  end
end

--- Every `cmd/<name>/` directory builds one binary, so one without an
--- entry is a directory that compiles and ships nothing.
local function check_entries(proj: Project, issues: {Issue})
  local dirs: {string: boolean} = {}
  local order: {string} = {}
  local has_entry: {string: boolean} = {}
  for _, f in ipairs(proj.files) do
    local segs = project.segments(f.path)
    if #segs >= 3 and segs[1] == "cmd" then
      local dir = "cmd/" .. segs[2]
      if not dirs[dir] then
        dirs[dir] = true
        order[#order + 1] = dir
      end
      if f.kind == "entry" then
        has_entry[dir] = true
      end
    end
  end
  for _, dir in ipairs(order) do
    if not has_entry[dir] then
      add(issues, dir, "no entry; expected " .. dir .. "/main.tl")
    end
  end
end

--- Refuse the two shapes that build cleanly and then go missing.
---
--- A root `init.tl` has no import path -- dropping the trailing `init`
--- leaves nothing for the project root to be named -- yet it still
--- classifies as a module, so it type-checks, compiles to `o/init.lua`,
--- and is then silently absent from every artifact. Nothing in the
--- design gives the root a module name to claim, so it is refused
--- rather than given one.
---
--- Two binaries with the same name share `o/stage/<name>` and
--- `o/bin/<name>`: the second overwrites the first, and which is
--- "second" follows iteration order. A project mid-refactor from
--- single- to multi-binary (`myapp/main.tl` plus `cmd/myapp/main.tl`)
--- reports success and ships whichever won.
--- @param proj Project The scanned project
--- @param issues {Issue} Issues to append to
local function check_binaries(proj: Project, issues: {Issue})
  for _, f in ipairs(proj.files) do
    -- Both spellings: `.lua` sources are first-class, so a root
    -- `init.lua` fails the same way -- it compiles, copies to
    -- `o/init.lua`, and silently never ships.
    if f.path == "init.tl" or f.path == "init.lua" then
      add(issues, f.path,
        "a root " .. f.path .. " has no import path, so it can never " ..
        "ship; did you mean main.tl?")
    end
  end
  local seen: {string: string} = {}
  local units: {string: boolean} = {}
  for _, b in ipairs(proj.binaries) do
    local first = seen[b.name]
    if first then
      add(issues, b.entry, "binary '" .. b.name ..
        "' is already declared by " .. first)
    else
      seen[b.name] = b.entry
    end
    units[b.dir] = true
    -- The ROOT payload is staged into EVERY binary, the way a root
    -- package is, so a root `embed_gen.tl` is legitimate whenever the
    -- project builds anything at all -- including a project whose only
    -- binaries live under `cmd/`.
    units[project.ROOT] = true
  end
  -- A payload generator belongs to a BINARY: `build` runs it with that
  -- unit's output directory and stages what it wrote. In a directory
  -- with no binary there is nothing to run it and nothing to stage, so
  -- it is a file that looks load-bearing and is dead -- and it is
  -- reserved, so it cannot be read as an ordinary generation unit
  -- either. Refusing by name is cheaper than either silence.
  for _, f in ipairs(proj.files) do
    if f.kind == "payload-gen" then
      local dir = fs.dirname(f.path)
      if dir == "." then
        dir = project.ROOT
      end
      if not units[dir] then
        add(issues, f.path, "a payload generator belongs to a binary, and " ..
          (dir == project.ROOT and "the project root" or "'" .. dir .. "'") ..
          " declares none; a generation unit is named <something>_gen.tl")
      end
    end
  end
end

--- The container a `_`-prefixed import is private to: the directory
--- holding the innermost `_` segment. Root `_cli/` is project-wide
--- internal; `cosmic/_x/` is internal to `cosmic/`.
--- @param import_name string A dotted import path
--- @return string|nil The container as a `/` path ("" for the root)
local function internal_container(import_name: string): string | nil
  local segs: {string} = {}
  for seg in import_name:gmatch("[^%.]+") do
    segs[#segs + 1] = seg
  end
  local last: integer = nil
  for i = 1, #segs do
    if segs[i]:sub(1, 1) == "_" then
      last = i
    end
  end
  if not last then
    return nil
  end
  local prefix: {string} = {}
  for i = 1, last - 1 do
    prefix[#prefix + 1] = segs[i]
  end
  return table.concat(prefix, "/")
end

--- Is `path` inside `container` ("" meaning the project root)?
local function within(path: string, container: string): boolean
  if container == "" then
    return true
  end
  return path:sub(1, #container + 1) == container .. "/"
end

--- The two import rules the tree's shape carries: `_` marks internal,
--- and a `cmd/` directory is private to its own binary. Both are what
--- lets the artifact layout be derived instead of enumerated.
local function check_imports(proj: Project, issues: {Issue}, defined: {string: boolean})
  for _, f in ipairs(proj.files) do
    if scanned[f.kind] then
      local dir = fs.dirname(f.path)
      if dir == "." then
        dir = ""
      end
      for _, name in ipairs(imports.of_file(fs.join(proj.root, f.path))) do
        if defined[name] then
          local container = internal_container(name)
          if container and not within(f.path, container) then
            local where = container == "" and "the project root"
            or "'" .. container .. "/'"
            add(issues, f.path, "imports '" .. name ..
              "', which is internal to " .. where)
          end
          local segs = project.segments((name:gsub("%.", "/")))
          if #segs >= 2 and segs[1] == "cmd" then
            local owner = "cmd/" .. segs[2]
            if not within(f.path, owner) then
              add(issues, f.path, "imports '" .. name .. "'; " .. owner ..
                " is private to its own binary")
            end
          end
        end
      end
    end
  end
end

--- Validate a scanned project.
---
--- Every rule runs: a project with three problems reports three, so a
--- fresh checkout is fixed in one pass instead of one error at a time.
--- @param proj Project The scanned project
--- @return {Issue} Every complaint, in file order
local function validate(proj: Project): {Issue}
  local issues: {Issue} = {}
  local defined: {string: boolean} = {}
  for _, f in ipairs(proj.files) do
    if f.import and defines_import[f.kind] then
      defined[f.import] = true
    end
  end
  check_names(proj, issues)
  check_reserved(proj, issues)
  check_duplicates(proj, issues)
  check_entries(proj, issues)
  check_binaries(proj, issues)
  check_imports(proj, issues, defined)
  table.sort(issues, function(a: Issue, b: Issue): boolean
      if a.path == b.path then
        return a.message < b.message
      end
      return a.path < b.path
    end)
  return issues
end

--- Render issues as `make: <path>: <message>` lines.
--- @param issues {Issue} Issues from validate
--- @return string One line per issue, newline-separated, no trailing newline
local function format_issues(issues: {Issue}): string
  local lines: {string} = {}
  for _, i in ipairs(issues) do
    lines[#lines + 1] = "make: " .. i.path .. ": " .. i.message
  end
  return table.concat(lines, "\n")
end

local record ValidateModule
  RESERVED: {string}
  PROVIDABLE: {string: boolean}
  METACHARACTERS: string
  claims: function(proj: Project): {string: boolean}
  validate: function(proj: Project): {Issue}
  format_issues: function(issues: {Issue}): string
end

local M: ValidateModule = {
  RESERVED = RESERVED,
  PROVIDABLE = PROVIDABLE,
  METACHARACTERS = METACHARACTERS,
  claims = claims,
  validate = validate,
  format_issues = format_issues,
}

return M
