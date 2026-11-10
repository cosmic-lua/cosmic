--- A source of a build and its parse: what a module's text is read as before any of it is typed.
---
--- [`build.driver`] builds a program over these and answers them under its own names ([`Driver.Source`],
--- [`Driver.parse`], [`Driver.index`]); the code that writes the rows of a parse ([`build.parse_derive`]) reads them from
--- here. Nothing here requires the checker ([`lang.check`]) or anything that does, a type import included, since a
--- `require` for a type is a row of `requires` like any other: a parse is keyed by the source of the modules its code
--- reaches ([`build.importer`]'s `analyzer_identity`, from [`build.code_walk`]'s `analyzer_roots`), and a module the
--- checker were reached from would make every edit to the checker parse the tree again.
---
--- It is a file of the seed ([`build/seed.txt`]), as [`build.driver`] is.
local AnalysisSchema = require("build.analysis_schema")
local Ast = require("lang.ast")
local Declarations = require("lang.declarations")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local type Codes = require("lang.check_codes")

local record SourceParse
  --- The text of a module and what the driver does with it.
  record Source
    --- The name a `require` gives it, and the name of its file in an error.
    module: string
    filename: string
    text: string
    dialect: Ast.Dialect
    --- Whether its bodies are checked and its result carried. A library, a stub and a binding are lowered and not checked.
    checked: boolean
    --- Whether its top-level `local function test_*` are called from outside the file (a test module), so that they are
    --- not unused.
    mut tests: boolean
    --- The other names a `require` may give it: only a declaration file of the globals has any
    --- ([`SourceParse.declarations`]); a module of an index ([`SourceParse.index`]) answers to its whole name alone.
    mut aliases: mut {string}
    --- The name its findings are told under, "" where that is its `filename`. A source the build writes from another
    --- file (a guide's examples, a template, the declarations of a header) is named for the file it comes from, which
    --- the tree has, where its `filename` names the text written.
    pinned: string
  end

  --- What a caller knows of a file of an index that its name does not say: whether it is a test module.
  record Extra
    tests: boolean
  end

  --- What a caller knows of the file `file`, whose text is `text`.
  type Extras = function(file: string, text: string): Extra

  --- An error or a warning of a module.
  record Problem
    --- `error`, or the kind of the warning (`unused`, `unread`, `branch`, `hint`).
    kind: string
    --- The stage that found an error: `syntax`, `scoped`, `declared` or `checked`; `warning` for a warning.
    stage: string
    code: string
    msg: string
    fix: string
    y: integer
    x: integer
    offset: integer
    --- Whether the fix is what to write instead of a name cosmic removed ([`build.removed_fix`]), in place of the checker's own.
    removed: boolean
    --- The call whose argument the checker refused, for an error filed for a value given to a parameter ([`Codes.Argument`]); nil
    --- for any other problem.
    argument?: Codes.Argument
  end

  --- A source, read: its text lexed and parsed.
  record Read
    source: Source
    text: string
    chunk: Ast.Chunk
    errors: {Parser.Error}
  end

  --- A source as a build reads it, and no more: its text lexed and parsed.
  --- The readers of the syntax tree ([`build.syntax_derivation`]) take their tree from this, with the text it was parsed from.
  record Parsed
    text: string
    chunk: Ast.Chunk
    --- The syntax errors, in source order: none for a tree that is whole.
    syntax: {Problem}
  end

  --- The sources of a tree and the names they answer to.
  record Index
    sources: mut {Source}
    by_module: mut {string: Source}
  end

  --- A source with every word given.
  make: function(module: string, filename: string, text: string, dialect: Ast.Dialect, checked: boolean,
    aliases: mut {string}, tests: boolean, pinned: string): Source

  --- A source with the defaults: checked, no alias, and a test module only where `tests`.
  source: function(module: string, filename: string, text: string, dialect: Ast.Dialect, tests?: boolean): Source

  --- A declaration file whose globals every module may use ([`Driver.Options.globals`]): not checked, answering to `aliases` as
  --- well.
  declarations: function(module: string, filename: string, text: string, aliases: mut {string}): Source

  --- `source` lexed and parsed, from `written` in place of its text when given.
  read: function(source: Source, written?: string): Read

  --- [`SourceParse.read`] of a declaration file that declares the globals, kept by the file's name. A process that builds
  --- many trees (a compile of each step of an edit) lowers the same prelude and standard library into each build's own
  --- program, and would parse them again for each: the syntax of a source is read-only to a program, and a build already
  --- lowers the same one into a new program ([`Driver.Build`]'s restart), so a read is kept while the text, the dialect and
  --- the module are those it was made from. A file with other text is read again, and replaces the one kept: a changed
  --- declaration is never served stale.
  remembered: function(source: Source): Read

  --- [`SourceParse.read`] of `source`, its syntax errors as problems.
  parse: function(source: Source): Parsed

  --- The modules `entries` (pairs of a path below the root and its text) are: each `.tl` and `.d.tl` a module named by its
  --- path ([`Declarations.module_of`]), checked. A module is answered to by that name alone, the one the run time resolves:
  --- `b/m.tl` is `b.m`, never `m`. A project inside the tree names its modules from its own root by being built from there.
  --- `skip` says which paths are left out. A module
  --- given as both `.tl` and `.d.tl` is refused before an index is made ([`SourceParse.declared`]); two files that are one module
  --- otherwise (`x.tl` and `x/init.tl`, or `x.d.tl` and `x/init.d.tl`) are refused by the derive ([`build.derivation`]),
  --- and are not given here. A `*_test.tl` is a test module
  --- ([`SourceParse.Source.tests`]). An entry may give a third word, the module it is, and a fourth, the name its findings
  --- are kept under ([`SourceParse.Source.pinned`]), for a source the build writes from another file, whose path says
  --- neither: the entry's path is then the name of the text, and `.d.tl` still marks a declaration. `extras` says of a file
  --- what its name does not: a test module ([`SourceParse.Source.tests`]).
  index: function(entries: {{string}}, skip: function(path: string): boolean, extras?: Extras): Index

  --- Why a declaration file and a source of one module may not both be given: the complaint of `declaration` (a `.d.tl`)
  --- standing beside `source` (a `.tl`), both the module `module`. It offers both ways out: delete the declaration, or
  --- rename one of the two so that they are different modules.
  pairing: function(declaration: string, source: string, module: string): string

  --- Why the declaration file `file` (below the root) with `text` may not be a build's: "" where its leading comment names
  --- exactly one kind, `--- @kind binding` (a module implemented in C) or `--- @kind language` (the language's own
  --- declarations, allowed only for the two files that are the build's globals, [`build.analysis_schema`]'s
  --- `is_language_file`, and only where `own` says the build is cosmic's own tree: a project has no such declarations,
  --- whatever it names its files). Else the complaint, which offers both ways out: tag it a binding, or write it as a `.tl`,
  --- whose types and code are checked and real at run time; the language's two files that name nothing are told to say
  --- `language`, and a file that names two kinds, to name one. A file that is no `.d.tl` is none of this helper's.
  naming: function(file: string, text: string, own: boolean): string

  --- Every complaint about the declaration files of `entries` (as [`SourceParse.index`] takes them, less the `skip`ped paths):
  --- those of [`SourceParse.pairing`] for a `.d.tl` beside a source of its module, and those of [`SourceParse.naming`] for a `.d.tl`
  --- that is in no pair, one to a line and in the order of the declarations: "" for none. What a build refuses a tree or
  --- project for before an index is made.
  declared: function(entries: {{string}}, skip: function(path: string): boolean, own: boolean): string
end

function SourceParse.make(module: string, filename: string, text: string, dialect: Ast.Dialect, checked: boolean,
                          aliases: mut {string}, tests: boolean, pinned: string): SourceParse.Source
  return {
    module = module, filename = filename, text = text, dialect = dialect,
    checked = checked, tests = tests, aliases = aliases, pinned = pinned,
  }
end

local make = SourceParse.make

function SourceParse.source(module: string, filename: string, text: string, dialect: Ast.Dialect, tests?: boolean): SourceParse.Source
  return make(module, filename, text, dialect, true, {}, tests == true, "")
end

function SourceParse.declarations(module: string, filename: string, text: string, aliases: mut {string}): SourceParse.Source
  return make(module, filename, text, "decl", false, aliases, false, "")
end

function SourceParse.read(source: SourceParse.Source, written?: string): SourceParse.Read
  local text = written or source.text
  local parsed = Parser.parse(Lexer.lex(text, source.filename), source.filename, source.dialect)
  return { source = source, text = text, chunk = parsed.chunk, errors = parsed.errors }
end

--- The last read of each declaration file that declares the globals, by the file's name.
local record Remembered
  mut reads: mut {string: SourceParse.Read}
end

local remembered: Remembered = { reads = {} }

function SourceParse.remembered(source: SourceParse.Source): SourceParse.Read
  local held = remembered.reads[source.filename]
  if held ~= nil and held.text == source.text and held.source.dialect == source.dialect and
      held.source.module == source.module then
    return { source = source, text = held.text, chunk = held.chunk, errors = held.errors }
  end
  local read = SourceParse.read(source)
  remembered.reads[source.filename] = read
  return read
end

function SourceParse.parse(source: SourceParse.Source): SourceParse.Parsed
  local read = SourceParse.read(source)
  local syntax: mut {SourceParse.Problem} = {}
  for _, e in ipairs(read.errors) do
    syntax[#syntax + 1] = {
      kind = "error", stage = "syntax", code = tostring(e.code), msg = e.msg, fix = e.fix, y = e.y, x = e.x, offset = e.offset,
      removed = false,
    }
  end
  return { text = read.text, chunk = read.chunk, syntax = syntax }
end

function SourceParse.index(entries: {{string}}, skip: function(path: string): boolean, extras?: SourceParse.Extras): SourceParse.Index
  local index: SourceParse.Index = { sources = {}, by_module = {} }
  for _, entry in ipairs(entries) do
    local file = entry[1]
    local text = entry[2]
    if file ~= nil and text ~= nil and not skip(file) then
      local dialect: Ast.Dialect = "tl"
      if file:match("%.d%.tl$") then
        dialect = "decl"
      end
      local extra: SourceParse.Extra = { tests = false }
      if extras ~= nil then
        extra = extras(file, text)
      end
      local module = entry[3] or Declarations.module_of(file)
      local source = make(module, file, text, dialect, true, {},
        extra.tests or file:match("_test%.tl$") ~= nil, entry[4] or "")
      index.sources[#index.sources + 1] = source
      if index.by_module[source.module] == nil then
        index.by_module[source.module] = source
      end
    end
  end
  return index
end

function SourceParse.pairing(declaration: string, source: string, module: string): string
  return declaration .. ": " .. source .. " is already the module " .. module .. ". A .d.tl is only for a module " ..
    "implemented in C, and the .tl is what is checked, so one module cannot have both. If the .tl is the module, " ..
    "delete " .. declaration .. ". To keep both, rename one of them so that they are different modules."
end

--- The complaint of each declaration file of `entries` that stands beside a source of its module, keyed by the file.
local function pairs_of(entries: {{string}}, skip: function(path: string): boolean): mut {string: string}
  local sources: mut {string: string} = {}
  for _, entry in ipairs(entries) do
    local file = entry[1]
    if file ~= nil and entry[2] ~= nil and not skip(file) and file:match("%.d%.tl$") == nil then
      local module = entry[3] or Declarations.module_of(file)
      if sources[module] == nil then
        sources[module] = file
      end
    end
  end
  local found: mut {string: string} = {}
  for _, entry in ipairs(entries) do
    local file = entry[1]
    if file ~= nil and entry[2] ~= nil and not skip(file) and file:match("%.d%.tl$") ~= nil then
      local module = entry[3] or Declarations.module_of(file)
      local source = sources[module]
      if source ~= nil then
        found[file] = SourceParse.pairing(file, source, module)
      end
    end
  end
  return found
end

--- The complaints in `found`, one to a line in the order of the files they start with, so that the order does not depend
--- on the order of the entries.
local function lines_of(found: {string: string}): string
  local out: mut {string} = {}
  for _, complaint in pairs(found) do
    out[#out + 1] = complaint
  end
  table.sort(out)
  return table.concat(out, "\n")
end

function SourceParse.naming(file: string, text: string, own: boolean): string
  local named = AnalysisSchema.kinds_named(text)
  if #named > 1 then
    return file .. ": a .d.tl must name exactly one kind, and this one names " .. table.concat(named, " and ") ..
      ": keep the one line that says what it is (`" .. AnalysisSchema.binding_tag() .. "` for a module implemented in C)"
  end
  local kind = AnalysisSchema.kind_of(file, text)
  local how = "If it declares a module implemented in C, add the line `" .. AnalysisSchema.binding_tag() ..
    "` to its leading comment; otherwise write it as a .tl (types and code in a .tl are checked and real at run time)."
  if kind == "decl" and own and AnalysisSchema.is_language_file(file) then
    return file .. ": the language's own declarations must say so: add the line `" .. AnalysisSchema.language_tag() ..
      "` to its leading comment"
  elseif kind == "decl" then
    return file .. ": a .d.tl must name what it is, and this one names nothing. " .. how
  elseif kind == "language" and not own then
    return file .. ": `" .. AnalysisSchema.language_tag() .. "` is accepted only when building cosmic's own tree, and this is " ..
      "not one. " .. how
  elseif kind == "language" and not AnalysisSchema.is_language_file(file) then
    return file .. ": `" .. AnalysisSchema.language_tag() .. "` is only for the language's own declarations, " ..
      AnalysisSchema.prelude_file() .. " and " .. AnalysisSchema.stdlib_file() .. ", which are the build's globals. " .. how
  end
  return ""
end

local function unnamed_of(entries: {{string}}, skip: function(path: string): boolean, own: boolean): mut {string: string}
  local found: mut {string: string} = {}
  for _, entry in ipairs(entries) do
    local file, text = entry[1], entry[2]
    if file ~= nil and text ~= nil and not skip(file) and file:match("%.d%.tl$") ~= nil then
      local complaint = SourceParse.naming(file, text, own)
      if complaint ~= "" then
        found[file] = complaint
      end
    end
  end
  return found
end

function SourceParse.declared(entries: {{string}}, skip: function(path: string): boolean, own: boolean): string
  local found = pairs_of(entries, skip)
  for file, complaint in pairs(unnamed_of(entries, skip, own)) do
    if found[file] == nil then
      found[file] = complaint
    end
  end
  return lines_of(found)
end

return SourceParse
