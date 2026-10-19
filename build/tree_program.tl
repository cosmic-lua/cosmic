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
--- The globals are the declarations of the Lua standard library ([`checker/stdlib.d.tl`], corrected by
--- [`lang.stdlib_corrections`] where the driver reads it) and the prelude of the fork ([`checker/tl.tl`]'s `prelude`), less
--- the names cosmic's runtime withholds ([`teal.withheld`]). A source is the fork's Teal, translated when read
--- ([`lang.translate`]).
local Driver = require("build.driver")
local Fs = require("cosmic.fs")
local LangProof = require("build.lang_proof")
local Scopes = require("lang.scopes")
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
  --- Teal, less what `skip` leaves out. With `steps` the files that cannot be read in the new grammar once translated
  --- (lang/ast.tl and lang/types.tl, which use `where`, and cosmic/removed_example.tl) have their `where` clauses blanked, and
  --- each test of a record those clauses told apart is written as the test of its tag, wherever it is written
  --- ([`build.lang_proof`]'s steps): the program the pipeline checks. `kinds` says of a file what the working database says
  --- of its input; a `test` has its functions called from outside.
  index: function(entries: {{string}}, steps: boolean, kinds: {string: string}): Driver.Index

  --- Resolves the calls of [`Shape.record_of`] of the module `module` (the file `file`) of `build` ([`build.syntax_shape_specs`]),
  --- and reads the module again with them. nil and why where a call cannot be resolved; true where the module was read
  --- again and false where it has no such call.
  splice: function(build: Driver.Build, module: string, file: string): boolean | nil, string

  --- [`TreeProgram.splice`] of each of `modules`, in the file the build read it from: the lines that say why a call could not
  --- be resolved, none where all were. They are among the build's problems too ([`Driver.Build.problems`]).
  splice_all: function(build: Driver.Build, modules: {string}): {string}

  --- `files` and `written` as one list of entries, and which files of it are `written`: the sources the build writes
  --- from other files ([`TreeProgram.derived_of`]) are files of the tree, named for the file each comes from.
  record Joined
    files: {{string}}
    derived: {string: boolean}
  end
  joined: function(files: {{string}}, written: {{string}}): Joined

  --- The global sources and what is done to the globals they declare: the prelude of the fork, read from
  --- [`checker/tl.tl`] below `root` (none where the file is not there), and `stdlib`, the source of the standard library's
  --- declarations, nil for none. The prelude declares `interface userdata is userdata` in a way the new parser reads as the
  --- declaration of `interface`, so the name is withdrawn and `userdata` declared by hand; the withheld names are taken
  --- away, and `_G` is answered by the checker itself.
  fork_globals: function(root: string, stdlib: Driver.Source | nil): Globals

  --- The declarations of the bindings of C ([`cosmic.sys`], the raw process and socket tables), written from the headers under
  --- `root` as the build derives them ([`build.gen_syscalls`]), as the entries [`TreeProgram.index`] takes: the file they stand
  --- for, the module, and the header the ceilings are kept under; none where the tree has no header.
  bindings_of: function(root: string): {{string}}

  --- The Teal the build writes from the doc guides (`doc/guides/*.md`, [`build.doctest`]) and the templates (`*.tmpl`,
  --- [`cosmic.template`]) under `root`, as the entries [`TreeProgram.index`] takes: the file each is written from, as the
  --- name of the text, the module it is, and nothing else. nil and why where one is refused.
  derived_of: function(root: string): {{string}} | nil, string


  --- A build over `index` with the global sources and adjustment [`TreeProgram.fork_globals`] answered: the modules of `stubs`,
  --- whose stub is read in place of their source, are answered ahead of the index, and `standard` after it. The bindings of C
  --- that neither declares are left untyped (`external`). With `types` the checker keeps the type of each node.
  build: function(index: Driver.Index, globals: Globals, types?: boolean, stubs?: {string: Driver.Source},
    standard?: Driver.Provider): Driver.Build
end

local function skipped(file: string): boolean
  return file == "checker/tl.tl" or file:find("^testdata/") ~= nil or file:find("/testdata/", 1, true) ~= nil
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

--- What is done to the translation of the file `file`, whose text is `text`: its `where` clauses are blanked where it needs
--- it, and each test of a record they told apart is written as the tag test they were. nil for a file that needs neither.
local function mended(file: string, text: string, tags: {string: LangProof.Tags}): Driver.Mend | nil
  local blank = BLANKED[file] == true
  local mentions = text:find("lang.ast\"", 1, true) ~= nil or text:find("lang.types\"", 1, true) ~= nil
  if not blank and not mentions then
    return nil
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
    return LangProof.rewrite(out, name, tags).text
  end
end

function TreeProgram.index(entries: {{string}}, steps: boolean, kinds: {string: string}): Driver.Index
  local ast_text, types_text = text_of(entries, "lang/ast.tl"), text_of(entries, "lang/types.tl")
  local tags: {string: LangProof.Tags} = {}
  if steps and ast_text ~= nil and types_text ~= nil then
    tags = LangProof.tags(ast_text, types_text)
  end
  local mending = steps and ast_text ~= nil and types_text ~= nil
  return Driver.index(entries, true, skipped, function(file: string, text: string): Driver.Extra
    local mend: Driver.Mend | nil = nil
    if mending then
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
  local resolved, trouble = ShapeSpecs.resolve(build, module, file, read.text)
  if resolved == nil then
    return nil, trouble
  end
  if resolved ~= read.text and build:replace(module, resolved) == nil then
    return nil, file .. ": the new checker's build lost the module " .. module
  end
  return true
end

function TreeProgram.splice_all(build: Driver.Build, modules: {string}): {string}
  local out: {string} = {}
  for _, module in ipairs(modules) do
    local read = build:parsed(module)
    if read ~= nil then
      local spliced, refusal = TreeProgram.splice(build, module, read.source.filename)
      if spliced == nil then
        out[#out + 1] = refusal
        build.problems[#build.problems + 1] = refusal
      end
    end
  end
  return out
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

--- The text between the `[=====[` marks of `tl`, the text of [`checker/tl.tl`]: the prelude of the fork, nil where it has none.
local function prelude_of(tl: string): string | nil
  return tl:match("%[=====%[\n(.-)%]=====%]")
end

--
-- TODO: read the globals from the declaration files of the new checker, once it replaces
-- checker/tl.tl, whose prelude is a string that declares `interface userdata is userdata`
-- in a way the new parser reads as the declaration of `interface`.
local function globals_of(prelude: string | nil, stdlib: Driver.Source | nil): TreeProgram.Globals
  local sources: {Driver.Source} = {}
  if prelude ~= nil then
    sources[#sources + 1] = Driver.declarations("checker.prelude", "prelude.d.tl", prelude, false, false, {})
  end
  if stdlib ~= nil then
    -- The corrections of [`lang.stdlib_corrections`] are made by the driver, which reports what it could not apply.
    sources[#sources + 1] = Driver.declarations(stdlib.module, stdlib.filename, stdlib.text, true, true, stdlib.aliases)
  end
  local has_prelude = prelude ~= nil
  return { sources = sources, adjust = function(globals: {string: Scopes.Global})
    if has_prelude then
      globals["interface"] = nil
      globals["userdata"] = { space = "type", const = false }
    end
    for _, name in ipairs(teal.withheld) do
      globals[name] = nil
    end
    globals["_G"] = { space = "value", const = false }
  end }
end

function TreeProgram.fork_globals(root: string, stdlib: Driver.Source | nil): TreeProgram.Globals
  local tl, _ = Fs.read(root .. "/checker/tl.tl")
  return globals_of(tl ~= nil and prelude_of(tl) or nil, stdlib)
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
