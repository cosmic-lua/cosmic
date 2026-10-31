--- `cosmic compile`: Lua source for `.tl` files, one text per file, written by this binary's own carried compiler
--- ([`build.compile_grammar`]). It reads only the files it is given and the `cosmic.*` modules the binary carries, never the
--- tree around them, so a released binary runs it in any directory: a release can compile the tool's own source with it,
--- to seed a boot.
---
--- IT EMITS DESPITE TYPE ERRORS. A type error is reported and the Lua is written all the same: a count per file on standard
--- error, and with `--errors` each error as `file:line:column: message`. Only a file the parser refuses -- a syntax error --
--- stops the run: nothing is written for any file, each error is named as `file:line:column: message`, and the exit is 2.
--- Every file is parsed before the first is written, so a refusal never leaves some files written and others not.
---
--- THE LUA IS RAW: one file's text exactly as the generator writes it, no wrapper and nothing joining one file to another.
--- A file is checked as the module its path below the root names (`--root`, the working directory by default: [`lang/flow.tl`]
--- as [`lang.flow`]; the path may be absolute, and one outside the root is refused), and a `require` of another named file is
--- answered with that file's text, so the parts of a program see each other's types as the boot's compile gives them.
---
--- Unlike `cosmic fix` or a build it does not run [`Shape.record_of`]'s resolution, check contracts or hold a file to the
--- tree's other rules: it is the checker and the generator and nothing else.
---
--- THE GRAMMAR is the new checker's, which `--grammar new` names and the verb takes by
--- default; `--grammar teal` is refused, pointing to the project guide. The files named are the
--- whole program, a `.d.tl` among them declares the globals every file may use (the standard library's), and a `cosmic.*`
--- module no file named is the module of is then typed `invalid` and reported, since the checker cannot declare the binary's own
--- modules. With no `.d.tl` named the files are checked as `cosmic --standalone` checks a file: against the globals and the
--- `cosmic.*` modules this binary carries, and a warning is listed with the errors, so `--errors` names what `--standalone` would
--- refuse (still exit 0, the Lua still written). A syntax error refuses and writes nothing, any other error is reported and the Lua written anyway.
---
--- Like `cosmic json` it prints no summary: its standard output is the Lua of a single file written without `-o`, and its
--- exit status says how it went, 0 for Lua written (type errors or none) and 2 for a command line or a file it refuses;
--- after a refusal, or a write that failed, the directory of `-o` must not be used, for an earlier run's files may be in it.
--- Complaints go to standard error as `cosmic: compile: ...`. Its `spec` (build/verb_spec.tl) is `bare`.

local Cli = require("cosmic.cli")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local bare = require("build.bare")
local verb_spec = require("build.verb_spec")
local type Grammar = require("build.compile_grammar")
local type Ast = require("lang.ast")
local type Scopes = require("lang.scopes")

--- The `cosmic compile` verb: `run` is what [`build/dispatch.tl`] calls.
local record verb
  --- The verb's registration: see build/verb_spec.tl.
  spec: verb_spec.Spec
  --- Where `run` writes: what a test stands in for.
  record Io
    --- Writes to standard output, as given: the caller adds newlines.
    --- False and why when the bytes did not all go.
    out: function(text: string): boolean, string
    --- Writes one complaint line, without its newline.
    err: function(line: string)
  end
end

local spec = Cli.verbs.compile.spec or {}

local usage = "cosmic compile [--grammar new] [--errors] [--root <dir>] [-o <dir>] <file.tl>..."

--- What a command line asks for.
local record Request
  files: {string}
  --- The directory to write `<name>.lua` in, or nil for standard output.
  directory: string?
  errors: boolean
  --- The directory module names are relative to, nil for the working directory.
  root: string?
  --- The grammar of every file: "new".
  grammar: string
end

--- The name of the file `path`, without its directory.
local function base_of(path: string): string
  return (assert(path:match("([^/]*)$"), "the pattern matches an empty tail at worst"))
end

--- What `argv` asks for, or nil and why it is refused.
local function arguments(argv: {string}): Request?, string
  local parsed, trouble = Flags.parse(argv, 2, spec)
  if parsed == nil then return nil, trouble end
  local request: Request = {
    files = parsed.words,
    directory = parsed.values["-o"],
    errors = parsed.set["--errors"] or false,
    root = parsed.values["--root"],
    grammar = parsed.values["--grammar"] or "new",
  }
  if request.grammar == "teal" then
    return nil, "--grammar teal: the fork's grammar is gone; rewrite a project to the new grammar by hand, as doc/guides/project.md says"
  elseif request.grammar ~= "new" then
    return nil, "--grammar names new, not " .. request.grammar
  end
  if request.root == "" then
    return nil, "--root needs a directory"
  end
  if #request.files == 0 then
    return nil, "name at least one .tl file to compile"
  end
  if request.directory == "" then
    return nil, "-o needs a directory to write the Lua in"
  end
  local compiled = 0
  for _, path in ipairs(request.files) do
    if not base_of(path):match("%.d%.tl$") then compiled = compiled + 1 end
  end
  if request.directory == nil and compiled > 1 then
    return nil, "give -o <dir> to write one .lua per file, or name one file to print its Lua"
  end
  for _, path in ipairs(request.files) do
    if path == "" then return nil, bare.empty_file end
    if not base_of(path):match("^.+%.tl$") then
      return nil, path .. ": not a .tl source: name the file you want compiled"
    end
  end
  if compiled == 0 then
    return nil, "every file named is a .d.tl, which has no Lua: name a .tl to compile"
  end
  return request, ""
end

--- The path of the absolute `path` below `root` (absolute too), which is
--- what names the file to the checker; nil when it is outside `root`.
local function below(path: string, root: string): string?
  local prefix = if root == "/" then "/" else root .. "/" end
  if path:sub(1, #prefix) ~= prefix then return nil end
  return path:sub(#prefix + 1)
end

--- `why`, a system complaint, with `path` in front unless it already names it.
local function said(path: string, why: string): string
  if why:sub(1, #path) == path then return why end
  return path .. ": " .. why
end

--- The line that names one error of `path`.
local function located(path: string, e: Grammar.Problem): string
  local line = path .. ":" .. tostring(e.y) .. ":" .. tostring(e.x) .. ": " .. e.msg
  if e.fix ~= "" then
    line = line .. " (" .. e.code .. "): " .. e.fix
  end
  if e.code == "module_not_found" or e.code == "require_unknown" then
    line = line .. " -- if it is one of the files you compile, pass that file too; " ..
      "if its name is rooted at another directory, set --root to that directory"
  end
  return line
end

--- The count of `n` type errors, as a phrase.
local function counted(n: integer): string
  return tostring(n) .. (if n == 1 then " type error" else " type errors" end)
end

--- Runs the command line `argv`, `compile` at slot 1, and answers the
--- exit code. `streams` is where it writes: what a test stands in for.
function verb.run(argv: {string}, streams?: verb.Io): integer
  local to = streams or { out = bare.out, err = bare.err }
  local complain = bare.complainer("compile", to.err)
  local request, trouble = arguments(argv)
  if request == nil then
    complain(trouble .. "; " .. usage)
    return bare.refused
  end

  local root, root_why = Fs.absolute(request.root or ".")
  if root == nil then
    complain(root_why .. ": --root must name a directory that exists")
    return bare.refused
  end
  local is_directory, _ = Fs.is_dir(root)
  if is_directory ~= true then
    complain(root .. ": --root must name a directory, not a file")
    return bare.refused
  end
  --- The files in the order given, each with the name the checker knows
  --- it by.
  local todo: mut {Grammar.Source} = {}
  local skipped: mut {string} = {}
  --- The file given for each module name, and for each resolved path.
  local holders: mut {string:string} = {}
  local holder_is_declaration: mut {string:boolean} = {}
  local resolved: mut {string:string} = {}
  local bases: mut {string:string} = {}
  for _, path in ipairs(request.files) do
    local text, why = Fs.read(path)
    if text == nil then
      complain(said(path, why) .. ": check the path, which is read from this directory")
      return bare.refused
    end
    local absolute, absolute_why = Fs.absolute(path)
    if absolute == nil then
      complain(absolute_why)
      return bare.refused
    end
    local same = resolved[absolute]
    if same ~= nil then
      complain(path .. " and " .. same .. " are the same file, named twice: name it once")
      return bare.refused
    end
    resolved[absolute] = path
    local relative = below(absolute, root)
    if relative == nil then
      complain(path .. ": " .. absolute .. " is not under " .. root ..
          ": pass --root <dir> naming a directory above it, or a path below the current directory")
      return bare.refused
    end
    local name = require("build.compile_grammar").module_of(relative)
    local declaration = base_of(path):match("%.d%.tl$") ~= nil
    local holder = holders[name]
    if holder ~= nil then
      local Driver = require("build.driver")
      if holder_is_declaration[name] == declaration then
        complain(path .. " and " .. holder .. " are both the module " .. name ..
            ": a require could mean only one; name one of them, or compile them in two runs")
      elseif declaration then
        complain(Driver.pairing(path, holder, name))
      else
        complain(Driver.pairing(holder, path, name))
      end
      return bare.refused
    end
    holders[name] = path
    holder_is_declaration[name] = declaration
    if declaration then
      skipped[#skipped + 1] = path
    else
      local base = base_of(path)
      local twin = bases[base]
      if twin ~= nil then
        complain(path .. " and " .. twin .. " would both be written as " ..
            base:gsub("%.tl$", ".lua") .. ": compile them in two runs, to two directories")
        return bare.refused
      end
      bases[base] = path
    end
    todo[#todo + 1] = { path = path, relative = relative, text = text, declaration = declaration }
  end
  if #skipped > 0 then
    complain(table.concat(skipped, ", ") .. ": declares globals and types and has no Lua, so none is written; " ..
        "it still types a require of it")
  end

  -- With no `.d.tl` named the files are checked as a standalone run checks one: its globals, its `cosmic.*` modules and
  -- the warnings it refuses ([`build.pipeline`]'s `alone`). The exit contract stays: type errors are listed, not refused.
  local alone: Grammar.Standalone? = nil
  local Pipeline = require("build.pipeline")
  local options, options_why = Pipeline.alone()
  if options == nil then
    complain(options_why)
    return bare.refused
  end
  -- A file named for a module of the language is checked as the project's and run as the binary's.
  local entries: mut {{string}} = {}
  for _, source in ipairs(todo) do
    entries[#entries + 1] = { source.relative, source.text }
  end
  local TreeProgram = require("build.tree_program")
  local reserved = TreeProgram.reserved(entries, TreeProgram.library_modules(options.globals))
  if reserved ~= "" then
    complain(reserved)
    return bare.refused
  end
  if #skipped == 0 then
    local ProjectRefusals = require("build.project_refusals")
    alone = {
      globals = options.globals.sources, adjust = options.globals.adjust, standard = Pipeline.carried(),
      refusals = function(chunk: Ast.Chunk, scoped: Scopes.Scoped): {Grammar.Problem}
        local found: mut {Grammar.Problem} = {}
        for _, at in ipairs(ProjectRefusals.places(chunk, scoped)) do
          found[#found + 1] = { code = "project_refusal", msg = at.text, fix = "", y = at.y, x = at.x, offset = 0 }
        end
        return found
      end,
    }
  end
  local made = require("build.compile_grammar").compile(todo, nil, alone)
  local refused = false
  for _, compiled in ipairs(made) do
    for _, e in ipairs(compiled.syntax_errors) do
      complain(located(compiled.path, e))
    end
    if #compiled.syntax_errors > 0 then
      complain(compiled.path .. ": syntax error, so no Lua was written for any file: fix the line named above " ..
          "(type errors never stop a compile)")
      refused = true
    elseif compiled.trouble ~= "" then
      complain(compiled.path .. ": the generator wrote no Lua: " .. compiled.trouble)
      refused = true
    end
  end
  if refused then return bare.refused end

  for _, compiled in ipairs(made) do
    local count = #compiled.type_errors
    if request.errors then
      for _, e in ipairs(compiled.type_errors) do
        complain(located(compiled.path, e))
      end
    end
    if count > 0 then
      complain(compiled.path .. ": " .. counted(count) ..
          (if compiled.declaration then ", a declaration file, which has no Lua" else ", the Lua is written anyway" end) ..
          (if request.errors then "" else " (--errors lists them)" end))
    end
  end

  local directory = request.directory
  if directory ~= nil then
    local ok, why = Fs.mkdirs(directory)
    if not ok then
      complain(said(directory, why) .. ": name a directory this run can create")
      return bare.refused
    end
  end
  for _, compiled in ipairs(made) do
    local code = compiled.code
    if code == nil then
      -- A declaration file: it has no Lua.
    elseif directory == nil then
      if not bare.delivered(complain, to.out(code)) then return bare.refused end
    else
      local target = directory:gsub("/+$", "") .. "/" .. base_of(compiled.path):gsub("%.tl$", ".lua")
      local ok, why = Fs.write(target, code)
      if not ok then
        complain(said(target, why) .. ": name a directory this run can write in")
        return bare.refused
      end
    end
  end
  return bare.ok
end

--- The `compile` verb as [`build/verb_list.tl`] lists it. Reads the files it
--- is given and the binary's own modules, never the tree: never
--- stale-checked.
verb.spec = {
  name = "compile",
  guide = "the Lua of a Teal file",
  tests = { "build.compile_test", "build.compile_grammar_test", "build.compile_tool_test" },
  run = function(argv: {string}): integer return verb.run(argv) end,
  bare = true,
  takes = "the .tl files to compile",
  exits = "`compile` prints the Lua of one file, or writes one .lua per file under `-o`, and exits 2 for a syntax error.",
  passthrough = "its output is the Lua asked for, so its exit status is the verdict (build/compile_test.tl)",
}

return verb
