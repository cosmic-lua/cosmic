--- Tool identity stamps: "a result is only as fresh as the tool that
--- produced it", at the granularity of the tool.
---
--- Every graph rule used to name the whole binary as a prerequisite
--- (`$(COSMIC_DEP)`). Right in direction — a formatter fix must
--- invalidate every formatting verdict — and maximally coarse in
--- effect: the binary embeds every module in the tree, so editing ANY
--- module invalidated EVERY compile, fmt, lint and test result.
--- Measured on this repo: a one-line edit to a four-importer module
--- cost a full 394-file recompile plus all 182 tests, where its
--- closure costs seconds. The same coupling produced the "echo build":
--- the artifact replaced at a build's end was newer than every output,
--- so the NEXT build recompiled the world to prove nothing changed.
---
--- The refinement: a rule's tool is not the binary, it is the embedded
--- bytes that RUN when the rule's verb runs. Those bytes are readable
--- from the running binary's own /zip, so each verb gets a stamp file
--- under `o/.stamp/` — written only when its hash moves — and the
--- rules name the stamp instead of the binary. Closures are walked
--- over /zip by the same require-scanner the model uses, because
--- behavior comes from what is embedded, not from what the tree says
--- today; a gate that just converged is running exactly the tree's
--- bytes, which is what makes the stamp a statement about the tree.
---
--- Every stamp also folds in the tree's `*_pin.tl` bytes: a pin bump
--- swaps the runtime base and the vendored compiler, and no /zip byte
--- of the already-running binary reflects that.
---
--- The traded edge, stated: a test that SPAWNS the binary and
--- exercises engine code it does not import (a fixture test driving
--- `--make` through a changed `_make` module it never requires) keeps
--- its recorded result until its own closure or the record tool moves.
--- CI is immune — it runs cold — and an engine developer runs the
--- `_make` tests by path; the alternative was tying every test to the
--- dispatcher's whole static closure, which is the old cascade wearing
--- a new name. Recorded in docs/decisions/d17-tool-stamps.md.
---
--- A binary missing a root module (a custom artifact that stripped the
--- toolchain) falls back to hashing the whole binary file — exactly
--- the old behavior: coarse, and correct.

local fs = require("cosmic.fs")
local hash = require("cosmic.hash")
local imports = require("_make.imports")
local project = require("_make.project")
local types = require("_make.types")

local type Project = types.Project

--- The boot surface: what a spawned cosmic loads before it does
--- anything, plus the two entry files the wrapper runs. Every recipe
--- step and every child a step spawns pays this code, so every stamp
--- includes it. MEASURED, not derived — the dispatcher requires the
--- rest of the tree lazily, so a static scan from the entry would pull
--- in nearly everything and the stamps would be the binary again.
--- `stamp_test` ratchets this list against a live child's
--- package.loaded, so it can drift wide but never silently narrow.
local BOOT_MODULES < const >: {string} = {
  "_cli.args", "_cli.help", "_cli.main_handlers", "_cli.require_hints",
  "_cli.run", "_cli.welcome",
  "cosmic._fields", "cosmic.env", "cosmic.errno", "cosmic.fd", "cosmic.fs",
  "cosmic.fs.file", "cosmic.fs.find", "cosmic.fs.ops", "cosmic.fs.path", "cosmic.fs.tree",
  "cosmic.fs.types", "cosmic.fs.walk", "cosmic.fuzzy",
  "cosmic.flags", "cosmic.flags.command", "cosmic.flags.getopt",
  "cosmic.flags.parse", "cosmic.flags.types",
  "cosmic.instrument", "cosmic.searcher", "cosmic.stream", "cosmic.sys",
  "cosmic.tty",
}

--- Entry files the artifact boots through, by zip path: the searcher-
--- installing wrapper and the compiled entry it hands off to.
local BOOT_FILES < const >: {string} = {"/zip/main.lua", "/zip/main.user.lua"}

--- Each tool's roots: the modules whose embedded closure IS the tool,
--- beyond the boot surface and the `-c` dispatcher every rule passes
--- through. `record` carries `cosmic.teal` too: a recorded target may
--- spawn the binary on a `.tl`, and the runtime searcher compiles
--- through the same module.
local ROOTS < const >: {string: {string}} = {
  compile = {"_cli.build", "cosmic.teal"},
  fmt = {"_cli.build", "cosmic.format"},
  lint = {"_cli.build", "_cli.lint", "_tool.lint"},
  record = {"_cli.build", "_tool.testrun", "cosmic.teal"},
  driver = {"_cli.build"},
}

--- Zip files a tool reads that are not modules: the vendored compiler.
local EXTRA_FILES < const >: {string: {string}} = {
  compile = {"/zip/tl.lua"},
  record = {"/zip/tl.lua"},
}

--- The stamp files, in a stable order for make and for tests.
local TOOLS < const >: {string} = {"compile", "driver", "fmt", "lint", "record"}

--- Where a module lives in the artifact: the layout rule, read from
--- the zip side. Directory modules are already flat — `cosmic.fs` is
--- `/zip/cosmic/fs.lua` — because the stored path is the import path.
--- @param name string A module name
--- @return string The zip path
local function zip_path(name: string): string
  return "/zip/" .. name:gsub("%.", "/") .. ".lua"
end

--- The transitive closure of `roots` over /zip, as sorted zip paths.
---
--- Walks literal `require` edges with the model's own scanner
--- (`_make.imports`), following only names that resolve to a /zip
--- file: `cosmo.*` and the Lua stdlib are C — the pins vouch for them
--- — and a tree-only module is not part of the running tool.
--- @param roots {string} Module names to start from
--- @return {string}|nil The closure's zip paths, nil when a ROOT is missing
local function closure_of(roots: {string}): {string} | nil
  local seen: {string: boolean} = {}
  local queue: {string} = {}
  for _, r in ipairs(roots) do
    if not fs.is_file(zip_path(r)) then
      return nil
    end
    queue[#queue + 1] = r
  end
  local out: {string} = {}
  while #queue > 0 do
    local name = table.remove(queue)
    if not seen[name] then
      seen[name] = true
      local path = zip_path(name)
      if fs.is_file(path) then
        out[#out + 1] = path
        for _, dep in ipairs(imports.of_file(path)) do
          if not seen[dep] then
            queue[#queue + 1] = dep
          end
        end
      end
    end
  end
  table.sort(out)
  return out
end

--- One tool's identity, hashed: its closure, the boot surface, its
--- extra files, and the project's pins — (path, bytes) pairs in a
--- stable order, so the stamp is a pure function of what would run.
--- @param tool string A TOOLS entry
--- @param pins {string} The project's pin sources, as tree paths
--- @param cosmic string Absolute path to the running binary
--- @return string The stamp content (a hex digest plus its inputs' names)
local function identity(tool: string, pins: {string}, cosmic: string): string
  local paths: {string} = {}
  local add_all = function(list: {string})
    for _, p in ipairs(list) do
      paths[#paths + 1] = p
    end
  end
  local closed = closure_of(ROOTS[tool])
  local booted = closure_of(BOOT_MODULES)
  if closed == nil or booted == nil then
    -- The old rule, kept honest: no per-tool identity without the
    -- tool's modules, so the whole binary is the tool.
    local body = fs.read(cosmic)
    if body is string then
      return "binary " .. hash.sha256_hex(body) .. "\n"
    end
    -- Not a readable file (a cleaned tree's engine, a PATH-less exec):
    -- a constant stamp, which is what an empty COSMIC_DEP meant.
    return "binary unknown\n"
  end
  add_all(closed)
  add_all(booted)
  add_all(BOOT_FILES)
  add_all(EXTRA_FILES[tool] or {})
  add_all(pins)
  table.sort(paths)
  local parts: {string} = {}
  local counted = 0
  local last = ""
  for _, p in ipairs(paths) do
    if p ~= last then
      last = p
      local body = fs.read(p)
      if body is string then
        parts[#parts + 1] = p
        parts[#parts + 1] = "\0"
        parts[#parts + 1] = body
        parts[#parts + 1] = "\0"
        counted = counted + 1
      end
    end
  end
  return tool .. " " .. hash.sha256_hex(table.concat(parts)) ..
  " over " .. counted .. " inputs\n"
end

--- Write `path` only when the bytes differ — the same contract the
--- makefiles get, for the same reason: an unmoved tool must not touch
--- the mtime the graph schedules on.
--- @param path string Destination
--- @param content string Desired contents
--- @return boolean, string Success, or false plus the error
local function write_if_changed(path: string, content: string): boolean, string
  if fs.read(path) == content then
    return true
  end
  local ok, err = fs.make_dirs(fs.dirname(path))
  if not ok then
    return false, "make: cannot create " .. fs.dirname(path) .. ": " ..
    (err or "unknown error")
  end
  local wok, werr = fs.write(path, content)
  if not wok then
    return false, "make: cannot write " .. path .. ": " ..
    (werr or "unknown error")
  end
  return true
end

--- A stamp's path under the build directory. Dot-prefixed for the same
--- reason `o/.coverage` is: the mirror maps `o/<path>` to the source at
--- `<path>`, and a dot name is one the mirror cannot reach, so the
--- engine may own it without colliding with any project file.
--- @param tool string A TOOLS entry
--- @return string The stamp file, relative to the project root
local function path_of(tool: string): string
  return fs.join(project.BUILD_DIR, ".stamp", tool)
end

--- Write every tool's stamp for this project and binary.
---
--- Called from `materialize`, before make runs, so the prerequisites
--- exist by the time the rules are read. Cost: one /zip closure walk
--- and one hash per tool over a few dozen embedded files — memoized
--- nothing, measured in milliseconds.
--- @param proj Project The scanned project
--- @param cosmic string Absolute path to the running binary
--- @return boolean, string Success, or false plus the error
local function write_all(proj: Project, cosmic: string): boolean, string
  local pins: {string} = {}
  for _, f in ipairs(proj.files) do
    if f.kind == "pin" then
      pins[#pins + 1] = f.path
    end
  end
  table.sort(pins)
  for _, tool in ipairs(TOOLS) do
    local ok, err = write_if_changed(path_of(tool), identity(tool, pins, cosmic))
    if not ok then
      return false, err
    end
  end
  return true
end

local record StampModule
  BOOT_MODULES: {string}
  TOOLS: {string}
  closure_of: function(roots: {string}): {string} | nil
  identity: function(tool: string, pins: {string}, cosmic: string): string
  path_of: function(tool: string): string
  write_all: function(proj: Project, cosmic: string): boolean, string
end

local M: StampModule = {
  BOOT_MODULES = BOOT_MODULES,
  TOOLS = TOOLS,
  closure_of = closure_of,
  identity = identity,
  path_of = path_of,
  write_all = write_all,
}

return M
