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
--- THE FILES ARE READ AS WRITTEN. The tree holds the text the new checker reads, so a source is read here exactly as it is written,
--- and the module a path names is the one [`lang.declarations`]'s `module_of` says.
---
--- THE LUA IS THE BUILD'S. A module is written as the build's own compile writes it ([`build.pipeline`]): a test of a record or
--- an interface is written as the test for a table (`counted`), as the fork writes it and as the pins of `[checked]` count,
--- and a type import that is never read as a value is not loaded (`served`). The type errors of a module are not
--- refused (the code of the tool is held to its ceilings by the checks of the tree, not by a boot); a syntax error is,
--- and so is a construct the generator does not write.

local AnalysisSchema = require("build.analysis_schema")
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
local PRELUDE <const> = AnalysisSchema.prelude_file()
local STDLIB <const> = AnalysisSchema.stdlib_file()

--- The declaration file `file` of the tree at `root`, a source of globals.
local function declaration(root: string, file: string): Driver.Source
  local text = assert(Fs.read(root .. "/" .. file))
  return Driver.declarations(CompileGrammar.module_of(file), file, text, {})
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
  local prelude, stdlib = declaration(root, PRELUDE), declaration(root, STDLIB)
  -- The two files of the globals must say they are the language's, as a tree's build holds them to ([`Driver.naming`]); every
  -- module the seed is asked for is then refused, as a seed that cannot trust its globals types nothing. The seed reads the
  -- other declarations of the tree as it is asked for them (below), and does not list the tree: it has no walk of it, and the
  -- build that follows the seed's stage lists every file and holds each declaration to the same helper.
  local globals_refused = ""
  for _, each in ipairs({ prelude, stdlib }) do
    local complaint = Driver.naming(each.filename, each.text, true)
    if complaint ~= "" and globals_refused == "" then
      globals_refused = complaint
    end
  end
  local build = Driver.new({
    globals = { prelude, stdlib }, adjust = nil, external = {}, types = false,
  })
  --- The source of each module asked for, and the names the tree has none of, so that a file is read once.
  local sources: mut {string: Driver.Source} = {}
  local absent: mut {string: boolean} = {}
  --- Why the tree has no one module for a name: a declaration file and a source of it (the complaint of [`Driver.pairing`]),
  --- or a declaration file that names no kind ([`Driver.naming`]).
  local paired: mut {string: string} = {}
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
    local first: string? = nil
    local first_text = ""
    local others: mut {string} = {}
    -- A module is a declaration or a source, never both: one that has both is refused when it is asked for, as a build
    -- refuses it ([`build.driver.declared`]); so is a declaration that says nothing of what it is ([`build.driver.naming`]).
    for _, file in ipairs(Driver.candidates(name)) do
      if first == nil then
        local read, _ = Fs.read(root .. "/" .. file)
        if read ~= nil then
          first, first_text = file, read
        end
      else
        local there, _ = Fs.exists(root .. "/" .. file)
        if there == true then
          others[#others + 1] = file
        end
      end
    end
    if first == nil then
      absent[name] = true
      return nil
    end
    -- The declaration comes first among the candidates, so a pair is a declaration first and a source after it.
    local code: string? = nil
    for _, file in ipairs(others) do
      if code == nil and file:match("%.d%.tl$") == nil then
        code = file
      end
    end
    if first:match("%.d%.tl$") ~= nil and code ~= nil then
      paired[name] = Driver.pairing(first, code, name)
    end
    if first:match("%.d%.tl$") ~= nil and paired[name] == nil then
      local unnamed = Driver.naming(first, first_text, true)
      if unnamed ~= "" then
        paired[name] = unnamed
      end
    end
    local made = Driver.source(name, first, first_text, if first:match("%.d%.tl$") ~= nil then "decl" else "tl" end)
    sources[name] = made
    return made
  end)
  --- The Lua of `name`, its file; nil and why.
  local function module(name: string): Seed.Module?, string
    if globals_refused ~= "" then
      return nil, globals_refused
    end
    local found = build:parsed(name)
    if found == nil then
      return nil, ""
    end
    local refused = paired[name]
    if refused ~= nil then
      return nil, refused
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
