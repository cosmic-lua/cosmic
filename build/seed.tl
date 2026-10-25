--- The entry of the tool's seed: the one module the pinned release compiles, with the files it requires
--- ([`build/seed.txt`]), so that a boot can compile the tool's own build code without a checker carried from
--- elsewhere. Every boot starts from it: the bridge ([`core/bridge.lua`]) loads the Lua the pinned release wrote for it, and
--- then the Lua the tree's own generator writes.
---
--- It exposes the two things a boot needs of the new checker:
---
--- - [`Seed.compile`], the compile `cosmic compile --grammar new` makes ([`build.compile_grammar`]). The bridge's first stage runs
---   it over the seed's own files and compares the Lua with what the pinned release wrote, which holds the pin and the
---   tree's generator to each other.
--- - [`Seed.program`], a [`build.driver`] build over the modules of the tree on disk, from which the bridge's searcher answers
---   `require` for the build's code up to [`build.boot`].
---
--- THE FILES ARE READ AS WRITTEN. The tree holds the text the new checker reads, so a source is never translated here
--- (`Driver.Source.translate` is off), and the module a path names is the one [`lang.declarations`]'s `module_of` says.
---
--- THE LUA IS THE BUILD'S. A module is written as the build's own compile writes it ([`build.pipeline`]): a test of a record or
--- an interface is written as the test for a table (`counted`), as the fork writes it and as the pins of `[checked]` count,
--- and a type import that is never read as a value is not loaded (`served`). The type errors of a module are not
--- refused (the code of the tool is held to its ceilings by the checks of the tree, not by a boot); a syntax error is,
--- and so is a construct the generator does not write.

local CompileGrammar = require("build.compile_grammar")
local Driver = require("build.driver")
local Fs = require("cosmic.fs")

local record Seed
  --- The Lua of a module and the file it was written from.
  record Module
    --- The path below the root.
    file: string
    code: string
  end

  --- The modules of a tree, each answered once.
  record Program
    --- The Lua of the module `name`, nil and "" where the tree has no source for it (a binding of C, a declaration
    --- file), nil and why where it has one the compiler refuses.
    module: function(name: string): Module?, string
  end

  --- Compiles `sources` together as `cosmic compile --grammar new` does ([`CompileGrammar.compile`]).
  compile: function(sources: {CompileGrammar.Source}): {CompileGrammar.Compiled}

  --- A program over the tree at `root`. `declared` holds the declarations a boot makes in memory (the syscall table's, by
  --- module name); it is read when a module is asked for, so a declaration made after the program is answered.
  program: function(root: string, declared: {string: string}): Program
end

--- The files of the tree that declare the standard library's globals.
local PRELUDE <const> = "lang/prelude.d.tl"
local STDLIB <const> = "lang/stdlib.d.tl"

--- The declaration file `file` of the tree at `root`, a source of globals.
local function declaration(root: string, file: string): Driver.Source
  local text = assert(Fs.read(root .. "/" .. file))
  return Driver.declarations(CompileGrammar.module_of(file), file, text, {})
end

--- The files a `require` of `name` may name, in the order they are tried: a declaration before the source it stands for.
local function candidates(name: string): {string}
  local stem = name:gsub("%.", "/")
  return { stem .. ".d.tl", stem .. "/init.d.tl", stem .. ".tl", stem .. "/init.tl" }
end

--- One line for an error of the syntax, as the checker's complaints are written.
local function line_of(file: string, p: Driver.Problem): string
  return file .. ":" .. tostring(p.y) .. ":" .. tostring(p.x) .. ": syntax error: " .. p.msg
end

function Seed.compile(sources: {CompileGrammar.Source}): {CompileGrammar.Compiled}
  return CompileGrammar.compile(sources)
end

function Seed.program(root: string, declared: {string: string}): Seed.Program
  -- TODO: give the build the globals adjustment of [`build.tree_program`]'s `globals` (the names the runtime withholds taken
  -- away, `_G` added) once build/withheld.tl, which it reads, is in the seed list (build/seed.txt): the build here declares every name of
  -- the standard library's declarations, so a use of a withheld one is not reported. The Lua is the same either way.
  local build = Driver.new({
    globals = { declaration(root, PRELUDE), declaration(root, STDLIB) }, adjust = nil, external = {}, types = false,
  })
  --- The source of each module asked for, and the names the tree has none of, so that a file is read once.
  local sources: mut {string: Driver.Source} = {}
  local absent: mut {string: boolean} = {}
  build:provide(function(name: string): Driver.Source?
    local held = sources[name]
    if held ~= nil then
      return held
    elseif absent[name] == true then
      return nil
    end
    local text = declared[name]
    if text ~= nil then
      local made = Driver.source(name, name:gsub("%.", "/") .. ".d.tl", text, "decl")
      sources[name] = made
      return made
    end
    for _, file in ipairs(candidates(name)) do
      local read, _ = Fs.read(root .. "/" .. file)
      if read ~= nil then
        local made = Driver.source(name, file, read, if file:match("%.d%.tl$") ~= nil then "decl" else "tl" end)
        sources[name] = made
        return made
      end
    end
    absent[name] = true
    return nil
  end)
  --- The Lua of `name`, its file; nil and why.
  local function module(name: string): Seed.Module?, string
    local found = build:parsed(name)
    if found == nil then
      return nil, ""
    end
    local file = found.source.filename
    -- A declaration file that does not parse is reported too: it has no Lua, but the modules that require it are typed by it.
    if found.broken then
      local said = ""
      for _, p in ipairs(found.syntax) do
        said = said .. (if said == "" then "" else "\n" end) .. line_of(file, p)
      end
      return nil, said
    end
    if found.source.dialect == "decl" then
      return nil, ""
    end
    build:lower({ name })
    local result = build:result(name, true)
    if result == nil then
      return nil, file .. ": the build refused the module " .. name .. " (a require cycle?)"
    end
    local emitted = CompileGrammar.emit(build, result, false, true, true)
    -- What is written is all that a boot needs of the module: its syntax and scopes are not held while the rest load.
    build:retire(name)
    if emitted.code == nil then
      return nil, file .. ": the generator wrote no Lua: " .. emitted.trouble
    end
    return { file = file, code = emitted.code }, ""
  end
  return { module = module }
end

return Seed
