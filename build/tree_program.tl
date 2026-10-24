--- The program the new checker is measured over, and the one the build's own pipeline ([`build.pipeline`]) checks a module
--- against: which files are modules, how the standard library's declarations reach the checker, which bindings of C are typed.
--- The ceilings of [`build.ceilings`] hold for a [`build.driver`] build configured as [`TreeProgram.build`] configures it, so
--- [`build.tree_checks`], which counts the errors the pins allow, and [`Driver.Build.held`], which refuses what they do not,
--- both configure it here, and read the same program: the same sources, mended by the same steps ([`TreeProgram.index`]) and
--- with the same calls of [`Shape.record_of`] resolved ([`TreeProgram.splice`]), the same globals and bindings. A check of
--- the whole tree holds them to it: for every module the working database stages, the tree's checks refuse it for a count
--- over a ceiling exactly when the pipeline does, and the modules the pipeline refuses for more than a count are named
--- ([`build.pipeline_check`], [`build.pipeline.residue`]).
---
--- The globals are the declarations of the Lua standard library ([`lang/stdlib.d.tl`]) and the prelude ([`lang/prelude.d.tl`]),
--- both in the new grammar, less the names cosmic's runtime withholds ([`teal.withheld`]). A source is the fork's Teal,
--- translated when read ([`lang.translate`]).
local CheckerDeclarations = require("build.checker_declarations")
local Driver = require("build.driver")
local Fs = require("cosmic.fs")
local Memprobe = require("build.memprobe")
local LangProof = require("build.lang_proof")
local NewDeclarations = require("build.new_declarations")
local Scopes = require("lang.scopes")
local Translate = require("lang.translate")
local ShapeSpecs = require("build.syntax_shape_specs")
local Template = require("cosmic.template")
local analysis_schema = require("build.analysis_schema")
local doctest = require("build.doctest")
local gen_syscalls = require("build.gen_syscalls")
local teal = require("build.teal")

local record TreeProgram
  --- The global sources of a build and what is done to the globals they declare ([`Driver.Options`]).
  record Globals
    sources: {Driver.Source}
    adjust: function(globals: {string: Scopes.Global})
  end

  --- The sources of `entries`: pairs of a path below the root and its text, or with the module and the name the
  --- ceilings are kept under as well for a source the build writes from another file ([`Driver.index`]), all in the fork's
  --- Teal, less the programs of a `testdata/` directory. With `steps`, which cosmic's own tree takes and a project does
  --- not, [`checker/tl.tl`] and [`checker/stdlib.d.tl`] are left out too and the files that cannot be read in the new grammar once translated
  --- (lang/ast.tl and lang/types.tl, which use `where`, and cosmic/removed_example.tl) have their `where` clauses blanked, and
  --- each test of a record those clauses told apart is written as the test of its tag, wherever it is written
  --- ([`build.lang_proof`]'s steps): the program the pipeline checks. `kinds` says of a file what the working database says
  --- of its input; a `test` has its functions called from outside.
  index: function(entries: {{string}}, steps: boolean, kinds: {string: string}): Driver.Index

  --- The tags the rewrite of [`build.lang_proof`] needs, read from lang/ast.tl and lang/types.tl among `entries`: none where
  --- either is missing.
  tags_of: function(entries: {{string}}): {string: LangProof.Tags}

  --- What the pipeline reads for a file: the text, and the translation it was made from.
  record Read
    --- The translation's text with the steps done that the file needs: its `where` clauses blanked, the tests of their records
    --- written as the tests of their tags, the lines the new checker reads otherwise replaced. [`TreeProgram.index`] hands the
    --- same steps to the driver as the file's mend.
    text: string
    --- The translation, whose `text` is the text before the steps.
    translation: Translate.Result
  end

  --- The text the pipeline reads for the file `file` of cosmic's own tree, whose text in the fork's Teal is `text`: its
  --- translation ([`lang.translate`], or `translator`'s) and then the steps of the program. [`build.tree_writer`] writes this
  --- text, so what the tree commits is what the pipeline read.
  read: function(file: string, text: string, tags: {string: LangProof.Tags},
    translator?: function(source: string, name: string): Translate.Result): TreeProgram.Read

  --- Whether the file `file` of cosmic's own tree uses `where`, which its translation has blanked before it is read
  --- ([`build.lang_proof`]'s `blank_where`).
  blanked: function(file: string): boolean

  --- Resolves the calls of [`Shape.record_of`] of the module `module` (the file `file`) of `build` ([`build.syntax_shape_specs`]),
  --- reading the module in the build's scratch build ([`Driver.Build.scratch`]), and reads the module again with them. nil and
  --- why where a call cannot be resolved; true where the module was read again and false where it has no such call.
  splice: function(build: Driver.Build, module: string, file: string): boolean | nil, string

  --- `files` and `written` as one list of entries, and which files of it are `written`: the sources the build writes
  --- from other files ([`TreeProgram.derived_of`]) are files of the tree, named for the file each comes from.
  record Joined
    files: {{string}}
    derived: {string: boolean}
  end
  joined: function(files: {{string}}, written: {{string}}): Joined

  --- The global sources and what is done to the globals they declare, from the texts themselves: the prelude and `stdlib`
  --- (nil for none). The withheld names are taken away, and `_G` is answered by the checker itself. A project outside
  --- cosmic's tree has the texts of the tool that builds it ([`build.checker_declarations`]).
  globals: function(prelude: string | nil, stdlib: string | nil): Globals

  --- The same globals from the files of the tree at `root`, [`lang/prelude.d.tl`] and [`lang/stdlib.d.tl`]: a source for
  --- each that is there, none for one that is not.
  tree_globals: function(root: string): Globals

  --- The declarations of the bindings of C ([`cosmic.sys`], the raw process and socket tables), written from the headers under
  --- `root` as the build derives them ([`build.gen_syscalls`]), as the entries [`TreeProgram.index`] takes: the file they stand
  --- for, the module, and the header the ceilings are kept under; none where the tree has no header.
  bindings_of: function(root: string): {{string}}

  --- The Teal the build writes from the doc guides (`doc/guides/*.md`, [`build.doctest`]) and the templates (`*.tmpl`,
  --- [`cosmic.template`]) under `root`, as the entries [`TreeProgram.index`] takes: the file each is written from, as the
  --- name of the text, the module it is, and nothing else. nil and why where one is refused.
  derived_of: function(root: string): {{string}} | nil, string


  --- A build over `index` with the global sources and adjustment [`TreeProgram.tree_globals`] answered: the modules of `stubs`,
  --- whose stub is read in place of their source, are answered ahead of the index, and `standard` after it. The bindings of C
  --- that neither declares are left untyped (`external`). With `types` the checker keeps the type of each node.
  build: function(index: Driver.Index, globals: Globals, types?: boolean, stubs?: {string: Driver.Source},
    standard?: Driver.Provider): Driver.Build

  --- Hands each of `modules` to `each`, in the order they require one another, once it is lowered after
  --- the modules it requires, and retires it when `each` is done with it ([`Driver.Build.retire`]): a build then holds the
  --- syntax of one module at a time, and not of the tree. With `spliced` the calls of [`Shape.record_of`] of each module are
  --- resolved before it is lowered ([`TreeProgram.splice`]); the lines that say why one could not are answered, and are among
  --- the build's problems too. The collector is generational while it runs.
  stream: function(build: Driver.Build, index: Driver.Index, modules: {string}, spliced: boolean,
    each: function(module: string)): {string}
end

local function skipped(file: string): boolean
  return file:find("^testdata/") ~= nil or file:find("/testdata/", 1, true) ~= nil
end

--- What cosmic's own tree leaves out as well: the fork's checker and its copy of the standard library's declarations,
--- which are no module of the tree it compiles.
local function skipped_in_own_tree(file: string): boolean
  return file == "checker/tl.tl" or file == "checker/stdlib.d.tl" or skipped(file)
end

--- The text of the file `file` among `entries`.
local function text_of(entries: {{string}}, file: string): string | nil
  for _, entry in ipairs(entries) do
    if entry[1] == file then
      return entry[2]
    end
  end
  return nil
end

--- The files that cannot be read in the new grammar once translated, and need the `where` clauses of their records blanked
--- ([`build.lang_proof`]'s `blank_where`).
local BLANKED <const>: {string: boolean} = {
  ["lang/ast.tl"] = true, ["lang/types.tl"] = true, ["cosmic/removed_example.tl"] = true,
}

function TreeProgram.blanked(file: string): boolean
  return BLANKED[file] == true
end

--- What is done to the translation of the file `file`, whose text is `text`: its `where` clauses are blanked where it needs
--- it, each test of a record they told apart is written as the tag test they were, and the lines it spells for the fork that
--- the new checker reads otherwise are replaced ([`build.new_declarations`]). nil for a file that needs none.
local function mended(file: string, text: string, tags: {string: LangProof.Tags}): Driver.Mend | nil
  local blank = BLANKED[file] == true
  local mentions = text:find("lang.ast\"", 1, true) ~= nil or text:find("lang.types\"", 1, true) ~= nil
  local declared: Driver.Mend | nil = nil
  if NewDeclarations.edited(file) then
    declared = function(translated: string): string
      return NewDeclarations.apply(file, translated, true)
    end
  end
  if not blank and not mentions then
    return declared
  end
  -- The two modules that hold the clauses are known to the rewrite by the name of their file.
  local name = file
  if file == "lang/ast.tl" then
    name = "ast.tl"
  elseif file == "lang/types.tl" then
    name = "types.tl"
  end
  return function(translated: string): string
    local out = translated
    if blank then
      out = LangProof.blank_where(out).text
    end
    out = LangProof.rewrite(out, name, tags).text
    if declared ~= nil then
      out = declared(out)
    end
    return out
  end
end

function TreeProgram.tags_of(entries: {{string}}): {string: LangProof.Tags}
  local ast_text, types_text = text_of(entries, "lang/ast.tl"), text_of(entries, "lang/types.tl")
  if ast_text ~= nil and types_text ~= nil then
    return LangProof.tags(ast_text, types_text)
  end
  return {}
end

function TreeProgram.read(file: string, text: string, tags: {string: LangProof.Tags},
                          translator?: function(source: string, name: string): Translate.Result): TreeProgram.Read
  local translate = translator or Translate.translate
  local result = translate(text, file)
  local mend = mended(file, text, tags)
  if mend == nil then
    return { text = result.text, translation = result }
  end
  return { text = mend(result.text), translation = result }
end

function TreeProgram.index(entries: {{string}}, steps: boolean, kinds: {string: string}): Driver.Index
  local tags: {string: LangProof.Tags} = {}
  if steps then
    tags = TreeProgram.tags_of(entries)
  end
  local skip = skipped
  if steps then
    skip = skipped_in_own_tree
  end
  return Driver.index(entries, true, skip, function(file: string, text: string): Driver.Extra
    local mend: Driver.Mend | nil = nil
    if steps then
      mend = mended(file, text, tags)
    end
    return { tests = kinds[file] == "test", mend = mend }
  end)
end

function TreeProgram.splice(build: Driver.Build, module: string, file: string): boolean | nil, string
  local read = build:parsed(module)
  if read == nil then
    return nil, file .. ": the new checker's build has no module " .. module
  end
  if read.text:find("record_of", 1, true) == nil then
    return false
  end
  -- The calls are read in a build of its own, where the module is lowered as it stands and then retired: this build has not
  -- met the module when its text is replaced, so the replacement keeps its program, and what the reading lowered of the
  -- modules the module requires is not kept here as syntax.
  local scratch = build:scratch()
  local resolved, trouble = ShapeSpecs.resolve(scratch, module, file, read.text)
  -- A module the reading lowered in passing that has calls of its own to resolve is read here again, when its turn comes.
  scratch:retire_all(function(other: Driver.Outcome): boolean
    return other.module ~= module and other.text:find("record_of", 1, true) ~= nil
  end)
  if resolved == nil then
    return nil, trouble
  end
  if resolved ~= read.text and build:replace(module, resolved) == nil then
    return nil, file .. ": the new checker's build lost the module " .. module
  end
  return true
end

--- `modules` in an order in which each comes after the modules among them that its text requires by a literal name, and
--- otherwise as they stand. A module the index lacks keeps its place, and a cycle of requires is broken where it is met. The
--- requires are found in the text by their pattern, so one in a comment or a string counts too: that costs a module being
--- retired later than it could be, and never a verdict. Only the modules asked for are ordered, so a chain through a module
--- left out ([`Driver.Build.lower`] lowers it as it is needed) is not followed.
local function ordered(index: Driver.Index, modules: {string}): {string}
  local wanted: {string: boolean} = {}
  for _, module in ipairs(modules) do
    wanted[module] = true
  end
  local out: {string} = {}
  local state: {string: boolean} = {}
  local function visit(module: string)
    if state[module] == true or wanted[module] ~= true then
      return
    end
    state[module] = true
    local source = index.by_module[module]
    if source ~= nil then
      for _, name in source.text:gmatch("require%s*%(?%s*([\"'])([%w_%.%-]+)%1") do
        local required = index.by_module[name]
        if required ~= nil then
          visit(required.module)
        end
      end
    end
    out[#out + 1] = module
  end
  for _, module in ipairs(modules) do
    visit(module)
  end
  return out
end

function TreeProgram.stream(build: Driver.Build, index: Driver.Index, modules: {string}, spliced: boolean,
                            each: function(module: string)): {string}
  local refused: {string} = {}
  -- The garbage of a module is freed as the next is read, and not when the heap has doubled: the memory the default
  -- collector waits to free is the resident set the process keeps. A collector already in this mode is left in it.
  local previous = collectgarbage("generational")
  local count = 0
  for _, module in ipairs(ordered(index, modules)) do
    if spliced then
      local read = build:parsed(module)
      if read ~= nil then
        local done, refusal = TreeProgram.splice(build, module, read.source.filename)
        if done == nil then
          refused[#refused + 1] = refusal
          build.problems[#build.problems + 1] = refusal
        end
      end
    end
    build:lower({ module })
    each(module)
    build:retire(module)
    count = count + 1
    if count % 100 == 0 then
      Memprobe.mark(("stream: %d"):format(count))
    end
  end
  if previous == "incremental" then
    collectgarbage("incremental")
  end
  return refused
end

function TreeProgram.joined(files: {{string}}, written: {{string}}): TreeProgram.Joined
  local out: {{string}} = {}
  local derived: {string: boolean} = {}
  for _, entry in ipairs(files) do
    out[#out + 1] = entry
  end
  for _, entry in ipairs(written) do
    out[#out + 1] = entry
    derived[entry[1]] = true
  end
  return { files = out, derived = derived }
end

local function globals_of(prelude: string | nil, stdlib: string | nil): TreeProgram.Globals
  local sources: {Driver.Source} = {}
  if prelude ~= nil then
    sources[#sources + 1] = Driver.declarations(CheckerDeclarations.prelude_module(), CheckerDeclarations.prelude_file(), prelude,
      false, {})
  end
  if stdlib ~= nil then
    sources[#sources + 1] = Driver.declarations(CheckerDeclarations.stdlib_module(), CheckerDeclarations.stdlib_file(), stdlib,
      false, {})
  end
  return { sources = sources, adjust = function(globals: {string: Scopes.Global})
    for _, name in ipairs(teal.withheld) do
      globals[name] = nil
    end
    globals["_G"] = { space = "value", const = false }
  end }
end

function TreeProgram.globals(prelude: string | nil, stdlib: string | nil): TreeProgram.Globals
  return globals_of(prelude, stdlib)
end

function TreeProgram.tree_globals(root: string): TreeProgram.Globals
  local prelude, _ = Fs.read(root .. "/" .. CheckerDeclarations.prelude_file())
  local stdlib, _ = Fs.read(root .. "/" .. CheckerDeclarations.stdlib_file())
  return globals_of(prelude, stdlib)
end

--
-- TODO: have build.gen_syscalls write a field that may be nil as `name?: T` and a table a binding fills in as `mut`, once
-- the build compiles with the new checker (doc/plans/strict-teal.md, "the switch"): it writes `name: T | nil` and no
-- `mut`, so a literal of such a record that leaves the field out (literal_missing) and a write to a stand-in's field
-- (field_fixed) are refused, and the [checked] ceilings of the files that use the bindings hold those counts.
function TreeProgram.bindings_of(root: string): {{string}}
  local out: {{string}} = {}
  for _, derivation in ipairs(gen_syscalls.targets) do
    local header, _ = Fs.read(root .. "/" .. derivation.target.header)
    if header ~= nil then
      local text, _ = gen_syscalls.declaration(header, derivation.target)
      if text ~= nil then
        out[#out + 1] = { (derivation.path:gsub("%.", "/")) .. ".d.tl", text, derivation.path, derivation.target.header }
      end
    end
  end
  return out
end

--- The module the doc guide `file` is.
local function guide_module(file: string): string
  return (file:gsub("%.md$", ""):gsub("/", "."))
end

--- The module the template `file` is.
local function template_module(file: string): string
  local stem = file:gsub("%.tmpl$", "")
  if stem:sub(-5) == "/init" then
    stem = stem:sub(1, -6)
  end
  return (stem:gsub("/", "."))
end

function TreeProgram.derived_of(root: string): {{string}} | nil, string
  local out: {{string}} = {}
  local guides, _ = Fs.list(root .. "/doc/guides")
  for _, name in ipairs(guides or {}) do
    local file = "doc/guides/" .. name
    if name:match("%.md$") ~= nil then
      local text, why = Fs.read(root .. "/" .. file)
      if text == nil then
        return nil, why
      end
      local made, made_why = doctest.extract(text, file)
      if made == nil then
        return nil, file .. ": " .. made_why
      end
      out[#out + 1] = { file, made, guide_module(file) }
    end
  end
  local listed, walk_trouble = Fs.walk(root, function(relative: string, name: string, kind: Fs.Kind): boolean
    return kind == "dir" and (name:sub(1, 1) == "." or relative == "vendor" or relative == "o" or relative == "ci/o")
  end)
  if listed == nil then
    return nil, walk_trouble
  end
  for _, file in ipairs(listed) do
    if file:match("%.tmpl$") ~= nil and analysis_schema.is_module_file(file) then
      local text, why = Fs.read(root .. "/" .. file)
      if text == nil then
        return nil, why
      end
      local made, made_why = Template.compile(text, file)
      if made == nil then
        return nil, made_why
      end
      out[#out + 1] = { file, made, template_module(file) }
    end
  end
  return out
end

function TreeProgram.build(index: Driver.Index, globals: TreeProgram.Globals, types?: boolean,
                           stubs?: {string: Driver.Source}, standard?: Driver.Provider): Driver.Build
  -- A binding of C is typed when the tree has the header its declaration is derived from, and is left untyped (`external`)
  -- where it does not.
  local external: {string} = {}
  for _, derivation in ipairs(gen_syscalls.targets) do
    if index.by_module[derivation.path] == nil and (standard == nil or standard(derivation.path) == nil) then
      external[#external + 1] = derivation.path
    end
  end
  local build = Driver.new({ globals = globals.sources, adjust = globals.adjust, external = external, types = types == true })
  if stubs ~= nil then
    -- The modules whose stub is read in place of their source are answered ahead of the tree's files.
    build:provide(function(module: string): Driver.Source | nil
      return stubs[module]
    end)
  end
  build:provide(Driver.files(index))
  if standard ~= nil then
    build:provide(standard)
  end
  return build
end

return TreeProgram
