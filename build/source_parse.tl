--- A source of a build and its parse: what a module's text is read as before any of it is typed.
---
--- [`build.driver`] builds a program over these and gives them under its own names ([`Driver.Source`],
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
local type Scopes = require("lang.scopes")

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
    --- Whether it is an entry point, called with the command line's words ([`Declarations.Input.entry`]): a program's
    --- `cmd/<name>/main.tl`, or a file checked as it is run alone.
    entry: boolean
    --- The other names a `require` may give it: only a declaration file of the globals has any
    --- ([`SourceParse.declarations`]); a module of an index ([`SourceParse.index`]) goes by its whole name alone.
    mut aliases: mut {string}
    --- The name its findings are told under, "" where that is its `filename`. A source the build writes from another
    --- file (a guide's examples, a template, the declarations of a header) is named for the file it comes from, which
    --- the tree has, where its `filename` names the text written.
    pinned: string
  end

  --- What a caller knows of a file of an index that its name does not say: whether it is a test module.
  record Extra
    tests: boolean
    --- Whether it is an entry point ([`SourceParse.Source.entry`]), where its name does not say so.
    entry?: boolean
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
    --- How many bytes from `offset` the place at fault spans: 0 where the error names a point.
    length: integer
    --- The second place the error involves (where a name was first given, where a field is declared), where it has one.
    other?: Scopes.Place
    --- Whether the fix is what to write instead of a name cosmic removed ([`build.removed_fix`]), in place of the checker's own.
    removed: boolean
    --- The call whose argument the checker refused, for an error filed for a value given to a parameter ([`Codes.Argument`]); nil
    --- for any other problem.
    argument?: Codes.Argument
    --- The checker's rewrite of the place that puts the error right ([`Codes.Rewrite`]), where it has one.
    rewrite?: Codes.Rewrite
    --- The module of cosmic ([`cosmic.csv`]) that a name not declared is the capitalized name of (`Csv`), for a caller that
    --- binds the name itself ([`Pipeline.implied`]); nil for any other problem.
    mut module?: string
    --- The name as written there (`Csv`), with `module`.
    mut named?: string
  end

  --- A source, read: its text lexed and parsed.
  record Read
    source: Source
    --- The text the tree is of: the lowered text where a lowering replaced places of it ([`SourceParse.lowering`]).
    text: string
    chunk: Ast.Chunk
    errors: {Parser.Error}
    --- The places a lowering replaced, in order: none where it replaced nothing.
    splices: {Splice}
    --- The fields of the module whose function takes a template, by the field ([`SourceParse.Lowering.takers`]):
    --- none where no lowering is set.
    takers: {string: boolean}
  end

  --- A source as a build reads it, and no more: its text lexed and parsed.
  --- The readers of the syntax tree ([`build.syntax_derivation`]) take their tree from this, with the text it was parsed from.
  record Parsed
    text: string
    chunk: Ast.Chunk
    --- The syntax errors, in source order: none for a tree that is whole.
    syntax: {Problem}
  end

  --- The sources of a tree and the names they go by.
  record Index
    sources: mut {Source}
    by_module: mut {string: Source}
  end

  --- A source with every word given.
  make: function(module: string, filename: string, text: string, dialect: Ast.Dialect, checked: boolean,
    aliases: mut {string}, tests: boolean, pinned: string, entry?: boolean): Source

  --- A source with the defaults: checked, no alias, and a test module only where `tests`.
  source: function(module: string, filename: string, text: string, dialect: Ast.Dialect, tests?: boolean): Source

  --- A declaration file whose globals every module may use ([`Driver.Options.globals`]): not checked, going by `aliases` as
  --- well.
  declarations: function(module: string, filename: string, text: string, aliases: mut {string}): Source

  --- `source` lexed and parsed, from `written` in place of its text when given, and lowered where a lowering is set
  --- ([`SourceParse.lowering`]): the text and the tree are then the lowered ones, the places replaced are its
  --- `splices`, and a template the lowering refused is a syntax error at its literal. `takes` says which functions of
  --- the modules it requires take a template; where it is not given, none does.
  read: function(source: Source, written?: string, takes?: Takes): Read

  --- What lowers a module before it is checked, which [`build.pipeline`] sets to [`build.template_lower`]'s: a build
  --- from the seed has none, and its code calls no [`Template.text`].
  lowering: function(lower: Lowering)

  --- What lowers a module, and what it reads of the modules a module requires.
  record Lowering
    --- `text`, whose tree is `chunk`, lowered: nil where there is nothing to lower. `takes` says whether the field
    --- of a module it requires is a function that takes a template.
    lower: function(text: string, name: string, chunk: Ast.Chunk, takes: Takes): Lowered?
    --- The fields of `module`, whose tree is `chunk`, that are functions that take a template.
    takers: function(module: string, chunk: Ast.Chunk): {string: boolean}
  end

  --- Whether the field `field` of the module `module` (as `require` names it) is a function that takes a template.
  type Takes = function(module: string, field: string): boolean

  --- The place of `length` bytes at `offset` of a text lowered by `splices`, in `written`, the text it was lowered
  --- from: a byte after a splice moves back by what the splices before it grew by, and a place that begins or ends in
  --- what a lowering wrote is the place it replaced, `inside` set. Its line and column are read from `written`.
  placed: function(splices: {Splice}, written: string, offset: integer, length: integer): Placed

  --- A place of a text written, as [`SourceParse.placed`] gives it back.
  record Placed
    y: integer
    x: integer
    offset: integer
    length: integer
    --- Whether the place was in what a lowering wrote, which no rewrite of the text written can edit.
    inside: boolean
  end

  --- What a lowering made of a module.
  record Lowered
    text: string
    --- The places the lowering replaced, which [`SourceParse.placed`] maps a place back through.
    splices: {Splice}
    refused: {Refused}
  end

  --- A place of the text replaced: its first byte, how many bytes it spanned, and what stands there now.
  record Splice
    offset: integer
    length: integer
    text: string
  end

  --- A template the lowering refused, where its reason is about.
  record Refused
    message: string
    y: integer
    x: integer
    offset: integer
    length: integer
  end

  --- [`SourceParse.read`] of a declaration file that declares the globals, kept by the file's name. A process that builds
  --- many trees (a compile of each step of an edit) lowers the same prelude and standard library into each build's own
  --- program, and asks what they declare more than once a build ([`Driver.globals`]), and would parse them again for
  --- each. A program writes nothing to the syntax of a source that depends on the build: the scope builder sets each
  --- name's binding, the same every time, and a build already lowers the same syntax into a new program
  --- ([`Driver.Build`]'s restart). So a read is kept while the text, the dialect and the module are those it was made
  --- from. A file with other text is read again, and replaces the one kept: a changed declaration is never served stale.
  remembered: function(source: Source): Read

  --- [`SourceParse.read`] of `source`, its syntax errors as problems.
  parse: function(source: Source): Parsed

  --- The modules `entries` (pairs of a path below the root and its text) are: each `.tl` and `.d.tl` a module named by its
  --- path ([`Declarations.module_of`]), checked. A module goes by that name alone, the one the run time resolves:
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
                          aliases: mut {string}, tests: boolean, pinned: string, entry?: boolean): SourceParse.Source
  return {
    module = module, filename = filename, text = text, dialect = dialect,
    checked = checked, tests = tests, aliases = aliases, pinned = pinned, entry = entry == true,
  }
end

local make = SourceParse.make

function SourceParse.source(module: string, filename: string, text: string, dialect: Ast.Dialect, tests?: boolean): SourceParse.Source
  return make(module, filename, text, dialect, true, {}, tests == true, "")
end

function SourceParse.declarations(module: string, filename: string, text: string, aliases: mut {string}): SourceParse.Source
  return make(module, filename, text, "decl", false, aliases, false, "")
end

local record Hooks
  mut lower?: SourceParse.Lowering
end

local hooks: Hooks = {}

function SourceParse.lowering(lower: SourceParse.Lowering)
  hooks.lower = lower
end

local function takes_none(_module: string, _field: string): boolean
  return false
end

local none: {string: boolean} = {}

function SourceParse.read(source: SourceParse.Source, written?: string, takes?: SourceParse.Takes): SourceParse.Read
  local text = written or source.text
  local parsed = Parser.parse(Lexer.lex(text, source.filename), source.filename, source.dialect)
  local lower = hooks.lower
  if lower == nil or #parsed.errors > 0 then
    return { source = source, text = text, chunk = parsed.chunk, errors = parsed.errors, splices = {}, takers = none }
  end
  local takers = lower.takers(source.module, parsed.chunk)
  if source.dialect ~= "tl" then
    return { source = source, text = text, chunk = parsed.chunk, errors = parsed.errors, splices = {}, takers = takers }
  end
  local lowered = lower.lower(text, source.filename, parsed.chunk, takes or takes_none)
  if lowered == nil then
    return { source = source, text = text, chunk = parsed.chunk, errors = parsed.errors, splices = {}, takers = takers }
  end
  local again = Parser.parse(Lexer.lex(lowered.text, source.filename), source.filename, source.dialect)
  local errors: mut {Parser.Error} = {}
  for _, e in ipairs(again.errors) do
    local at = SourceParse.placed(lowered.splices, text, e.offset, e.length)
    errors[#errors + 1] = { filename = e.filename, code = e.code, msg = e.msg, fix = e.fix, y = at.y, x = at.x,
      offset = at.offset, length = at.length }
  end
  for _, r in ipairs(lowered.refused) do
    errors[#errors + 1] = { filename = source.filename, code = "template_refused", msg = r.message,
      fix = "write the template as the reason says", y = r.y, x = r.x, offset = r.offset, length = r.length }
  end
  return { source = source, text = lowered.text, chunk = again.chunk, errors = errors, splices = lowered.splices,
    takers = takers }
end

--- Where byte `offset` of a lowered text is in the text written, and whether it is in what a splice wrote.
local function original(splices: {SourceParse.Splice}, offset: integer): (integer, boolean)
  local shift = 0
  for _, s in ipairs(splices) do
    local start = s.offset + shift
    if offset < start then break end
    if offset < start + #s.text then return s.offset, offset > start end
    shift = shift + #s.text - s.length
  end
  return offset - shift, false
end

function SourceParse.placed(splices: {SourceParse.Splice}, written: string, offset: integer, length: integer):
    SourceParse.Placed
  local at, begins_inside = original(splices, offset)
  local stop, ends_inside = original(splices, offset + length)
  local inside = begins_inside or ends_inside or (stop - at ~= length and length > 0)
  if begins_inside or ends_inside then
    -- The whole of what the splice replaced.
    for _, s in ipairs(splices) do
      if s.offset == at then stop = math.max(stop, s.offset + s.length) end
    end
  end
  local before = written:sub(1, at - 1)
  local _, lines = before:gsub("\n", "")
  local line_start = before:match(".*()\n") or 0
  return { y = lines + 1, x = at - line_start, offset = at, length = math.max(stop - at, 0), inside = inside }
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
    return { source = source, text = held.text, chunk = held.chunk, errors = held.errors, splices = held.splices,
      takers = held.takers }
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
      length = e.length, removed = false,
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
        extra.tests or file:match("_test%.tl$") ~= nil, entry[4] or "",
        extra.entry == true or (dialect == "tl" and module:match("^cmd%.[^.]+%.main$") ~= nil))
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
