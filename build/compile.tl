--- `cosmic compile`: Lua source for `.tl` files, one text per file, written
--- by this binary's own carried compiler ([`build.teal`]'s `load`) for the
--- tree's Lua, with Teal's compat targets off (`gen_compat = "off"`,
--- `gen_target = "5.4"`: [`teal.defaults`], which every compile of the
--- tree uses). It reads only the files it is given and the `cosmic.*`
--- modules the binary carries, never the tree around them, so a released
--- binary runs it in any directory: a release can compile the checker's
--- source with it, to seed a boot.
---
--- IT EMITS DESPITE TYPE ERRORS. The checker's own source does not obey
--- the rules the checker holds a program to (build/compiler_test.tl pins
--- its type errors), so a type error is reported and the Lua is written
--- all the same: a count per file on standard error, and with `--errors`
--- each error as `file:line:column: message`. Only a file the parser
--- refuses -- a syntax error -- stops the run: nothing is written for any
--- file, each error is named as `file:line:column: message`, and the exit
--- is 2. Every file is parsed before the first is written, so a refusal
--- never leaves some files written and others not.
---
--- THE LUA IS RAW: one file's text exactly as the compiler's generator
--- writes it, no wrapper and nothing joining one file to another. A file
--- is checked as the module its path below the root names (`--root`, the
--- working directory by default: [`checker/flow.tl`] as `checker.flow`; the
--- path may be absolute, and one outside the root is refused), and a
--- `require` of another named file is answered with that file's text, so a
--- checker's parts see each other's types as the boot's compile gives
--- them. A `.d.tl` file named is skipped, with one note, but still types
--- a `require` of it. Any `cosmic.*` name is the binary's own, and any
--- other is a type error (module not found), emitted despite.
---
--- Unlike `cosmic fix` or a build it does not run [`Shape.record_of`]'s
--- resolution, check contracts or hold a file to the tree's other rules:
--- it is the checker and the generator and nothing else.
---
--- THE GRAMMAR is Teal's unless `--grammar new` says otherwise, never
--- guessed from a file's text: files in the new checker's grammar
--- ([`doc/plans/new-checker-grammar.md`]) keep the `.tl` extension, and a
--- run reads all its files in one grammar. The new grammar's pipeline is
--- [`build/compile_grammar.tl`]'s: the files named are the whole program,
--- a `.d.tl` among them declares the globals every file may use (the
--- standard library's), and a `cosmic.*` module no file named is the
--- module of is typed `invalid` and reported, since the new checker
--- cannot declare the binary's own modules. The rest is as above: a
--- syntax error refuses and writes nothing, any other error is reported
--- and the Lua written anyway.
---
--- Like `cosmic json` it prints no summary: its standard output is the Lua
--- of a single file written without `-o`, and its exit status says how it
--- went, 0 for Lua written (type errors or none) and 2 for a command line
--- or a file it refuses; after a refusal, or a write that failed, the
--- directory of `-o` must not be used, for an earlier run's files may be
--- in it. Complaints go to standard error as
--- `cosmic: compile: ...`. Its `spec` (build/verb_spec.tl) is `bare`.

local Cli = require("cosmic.cli")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local bare = require("build.bare")
local teal = require("build.teal")
local verb_spec = require("build.verb_spec")
local type compiler = require("build.compiler")
local type Grammar = require("build.compile_grammar")

--- The `cosmic compile` verb: `run` is what [`build/dispatch.tl`] calls.
local record verb
  --- The verb's registration: see build/verb_spec.tl.
  spec: verb_spec.Spec
  --- The Lua the compiler `built` writes for `text`, the source of the file `name`, as a compile of that file alone
  --- writes it but with no module served: a `require` finds nothing, not even a `cosmic.*` module. The Lua is then
  --- a function of the text and the compiler, which a check that keeps it relies on. Nil and why where the parser
  --- refuses the text or the generator writes none. `built` is the caller's own compiler (from [`build.teal`]'s
  --- `load`), since this sets how it searches for modules.
  lua: function(built: compiler, name: string, text: string): string?, string

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

local usage = "cosmic compile [--grammar teal|new] [--errors] [--root <dir>] [-o <dir>] <file.tl>..."

-- TODO: at the switch (doc/plans/strict-teal.md, "the switch"): have build.zig's `seedCompiler` run `compile --grammar new`
-- over the files of build/seed.txt in place of `checker/*.tl` (no declaration file is needed: the Lua does not depend on
-- them; the pinned release's `compile` reads the grammar, and writes for the translated tree, which is committed, the
-- Lua this verb writes). `seedCompiler` runs `compile` over `checker/*.tl` until that step is made.

--- What a command line asks for.
local record Request
  files: {string}
  --- The directory to write `<name>.lua` in, or nil for standard output.
  directory: string?
  errors: boolean
  --- The directory module names are relative to, nil for the working directory.
  root: string?
  --- The grammar of every file: "teal" or "new".
  grammar: string
end

--- The name of the file `path`, without its directory.
local function base_of(path: string): string
  return (path:match("([^/]*)$"))
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
    grammar = parsed.values["--grammar"] or "teal",
  }
  if request.grammar ~= "teal" and request.grammar ~= "new" then
    return nil, "--grammar names teal or new, not " .. request.grammar
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

--- The module name a checker finds the file `relative` under when another
--- file requires it: the path without `.tl` or `.d.tl`, its slashes as dots.
local function module_of(relative: string): string
  local stem = relative:gsub("%.d%.tl$", ""):gsub("%.tl$", "")
  return (stem:gsub("/+", "."))
end

--- `why`, a system complaint, with `path` in front unless it already names it.
local function said(path: string, why: string): string
  if why:sub(1, #path) == path then return why end
  return path .. ": " .. why
end

--- Makes `built` answer a `require` of a named file with that file's
--- text, and any other name from the binary's own `cosmic.*` modules.
local function serving(built: compiler, texts: {string:string}, paths: {string:string})
  teal.serve_standard(built)
  local standard = built.search_module
  built.search_module = function(name: string, search_all: boolean): string?, compiler.Handle?
    local text = texts[name]
    if text == nil then
      return standard(name, search_all)
    end
    return paths[name], teal.served(text)
  end
end

--- The error of the fork `e`, as this verb reports it.
local function problem(e: compiler.Error): Grammar.Problem
  return { code = e.code, msg = e.msg, fix = "", y = e.y, x = e.x, offset = 0 }
end

--- The errors `list` of the fork, as this verb reports them.
local function problems(list: {compiler.Error}): {Grammar.Problem}
  local out: mut {Grammar.Problem} = {}
  for index, e in ipairs(list) do
    out[index] = problem(e)
  end
  return out
end

--- Checks and generates `text`, the file `path`, in an environment of its
--- own so no file sees another's declarations but through a `require`.
local function compile_one(built: compiler, path: string, filename: string, text: string): Grammar.Compiled
  local env, trouble = built.new_env({ defaults = teal.defaults() })
  if env == nil then
    return {
      path = path, declaration = false, code = nil, syntax_errors = {}, type_errors = {},
      trouble = "the checker made no environment: " .. tostring(trouble),
    }
  end
  local result = built.check_string(text, env, filename, "tl")
  local code: string? = nil
  local why_not = ""
  local ast = result.ast
  if #result.syntax_errors == 0 and ast ~= nil then
    local generated, why = built.generate(ast, env.defaults.gen_target, nil)
    code = generated
    if generated == nil then
      why_not = tostring(why)
    end
  end
  return {
    path = path, declaration = false, code = code, syntax_errors = problems(result.syntax_errors),
    type_errors = problems(result.type_errors), trouble = why_not,
  }
end

function verb.lua(built: compiler, name: string, text: string): string?, string
  built.search_module = function(_name: string, _search_all: boolean): string?, compiler.Handle?
    return nil
  end
  local compiled = compile_one(built, name, name, text)
  if #compiled.syntax_errors > 0 then
    return nil, name .. ":" .. compiled.syntax_errors[1].y .. ": " .. compiled.syntax_errors[1].msg
  end
  local code = compiled.code
  if code == nil then
    return nil, compiled.trouble
  end
  return code, ""
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
--- exit code. `built` is the compiler to use, or this binary's own when
--- nil: what a test stands in for.
function verb.run(argv: {string}, streams?: verb.Io, built?: compiler): integer
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
  local texts: mut {string:string} = {}
  local paths: mut {string:string} = {}
  --- The files in the order given, each with the name the checker knows
  --- it by.
  local todo: mut {Grammar.Source} = {}
  local skipped: mut {string} = {}
  --- The file given for each module name, and for each resolved path.
  local holders: mut {string:string} = {}
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
    if resolved[absolute] ~= nil then
      complain(path .. " and " .. resolved[absolute] .. " are the same file, named twice: name it once")
      return bare.refused
    end
    resolved[absolute] = path
    local relative = below(absolute, root)
    if relative == nil then
      complain(path .. ": " .. absolute .. " is not under " .. root ..
          ": pass --root <dir> naming a directory above it, or a path below the current directory")
      return bare.refused
    end
    local new_grammar = request.grammar == "new"
    local name = module_of(relative)
    if new_grammar then
      name = require("build.compile_grammar").module_of(relative)
    end
    local declaration = base_of(path):match("%.d%.tl$") ~= nil
    -- The new grammar's program has one file for a module.
    local kind = name .. (if (declaration and not new_grammar) then "\0d" else "\0t" end)
    if holders[kind] ~= nil then
      complain(path .. " and " .. holders[kind] .. " are both the module " .. name ..
          ": a require could mean only one; name one of them, or compile them in two runs")
      return bare.refused
    end
    holders[kind] = path
    -- As the build does, a declaration beside its source is what a
    -- `require` sees, whichever was named first.
    if texts[name] == nil or declaration then
      texts[name] = text
      paths[name] = relative
    end
    if declaration then
      skipped[#skipped + 1] = path
    else
      local base = base_of(path)
      if bases[base] ~= nil then
        complain(path .. " and " .. bases[base] .. " would both be written as " ..
            base:gsub("%.tl$", ".lua") .. ": compile them in two runs, to two directories")
        return bare.refused
      end
      bases[base] = path
    end
    todo[#todo + 1] = { path = path, relative = relative, text = text, declaration = declaration }
  end
  if #skipped > 0 then
    complain(table.concat(skipped, ", ") .. ": declares " ..
        (if request.grammar == "new" then "globals and types" else "types" end) .. " and has no Lua, so none is written; " ..
        "it still types a require of it")
  end

  local made: mut {Grammar.Compiled} = {}
  if request.grammar == "new" then
    made = require("build.compile_grammar").compile(todo)
  else
    local compiler_in_use = built
    if compiler_in_use == nil then
      local loaded, why = teal.load()
      if loaded == nil then
        complain(why)
        return bare.refused
      end
      compiler_in_use = loaded
    end
    serving(compiler_in_use, texts, paths)
    for _, entry in ipairs(todo) do
      if not entry.declaration then
        made[#made + 1] = compile_one(compiler_in_use, entry.path, entry.relative, entry.text)
      end
    end
  end
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
  tests = { "build.compile_test", "build.compile_grammar_test", "build.compile_lang_test", "build.compile_tool_test" },
  run = function(argv: {string}): integer return verb.run(argv) end,
  bare = true,
  takes = "the .tl files to compile",
  exits = "`compile` prints the Lua of one file, or writes one .lua per file under `-o`, and exits 2 for a syntax error.",
  passthrough = "its output is the Lua asked for, so its exit status is the verdict (build/compile_test.tl)",
}

return verb
