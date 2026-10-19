--- The build's compile with the new checker (`COSMIC_GRAMMAR=new`, [`build.grammar_mode`]): a module of the staged tree is
--- read, checked against its ceilings and written as Lua and bytecode by [`build.driver`] and [`lang.codegen`], in place of
--- the fork's compiler. [`Pipeline.generate`] answers what [`build.compilation`]'s `generate` answers, so the build's compile
--- can call either.
---
--- THE PROGRAM is every module of the staged tree (the `inputs` of the working database), in the fork's Teal, translated when
--- read ([`lang.translate`]), set up as the pins are measured ([`build.tree_program`]); the `cosmic.*` modules the tree does
--- not hold (a project's `require` of the standard library) are the binary's own, each its stub or its source, and the
--- bindings of C are typed from the declarations the build writes of the headers ([`cosmic.sys`], the raw process and socket
--- tables), the tree's or the binary's. The globals of every module are the declarations of the Lua standard library.
---
--- THERE IS NO FALLBACK TO THE FORK. The mode is meant for any project: one written in a form only the fork reads is to be
--- refused with the new checker's words and fix ([`build.error_catalog`], [`build.error_render`]), and so it will be once the
--- new checker replaces the fork. Until the tool carries the declarations of the standard library ([`Pipeline.options`]) the
--- mode builds cosmic's own tree alone. The three modules of the tree that do not read in the new grammar once translated
--- ([`lang/ast.tl`] and [`lang/types.tl`], which use `where`, and [`cosmic/removed_example.tl`]) go through the mechanical
--- steps that [`build.lang_proof`] makes, so that the checker's own tests run on the Lua the new generator writes.
---
--- A MODULE IS REFUSED for a count of errors above its ceiling ([`build.ceilings`]), for any warning, for a translation
--- that does not parse (a pin lets it be counted, not compiled) and for a construct the generator does not write. The
--- ceilings are held by the tree's checks as they are here; the other refusals are listed in [`build.pipeline.residue`].
--
-- TODO: key a compile by the ceilings of the module and by the declarations it was checked against
-- ([`Pipeline.Options.globals`]), once [`build.compilation`] calls this module: a pin that falls must refuse again a module
-- another run compiled and cached.
--
-- TODO: point to what `cosmic docs` answers for a name and to the worked example of a form in the lines of a refusal, as
-- [`build.error_render`]'s `lines` does with the databases it is given, once [`Driver.Build`] answers the problems over their
-- ceilings and not only the lines that list them: a refusal here prints the lines of [`Driver.Build.held`] and the warnings.
--
-- TODO: fill the references of record fields a module uses ([`Generated.references`], which `cosmic uses` reads) from the
-- type report, and hold a standard-library module to its stub and a module to the discipline of errors
-- ([`build.contracts`]), through [`build.syntax_receivers`], [`build.syntax_stub`] and [`build.syntax_contracts`], once
-- [`build.compilation`] calls this module (doc/plans/strict-teal.md, "the switch").
local Ceilings = require("build.ceilings")
local CompileGrammar = require("build.compile_grammar")
local Driver = require("build.driver")
local ErrorRender = require("build.error_render")
local Fs = require("cosmic.fs")
local GrammarMode = require("build.grammar_mode")
local LuaTail = require("build.lua_tail")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local TreeProgram = require("build.tree_program")
local teal = require("build.teal")
local tree = require("build.tree")
local type Compilation = require("build.compilation")

local record Pipeline
  type Mode = GrammarMode.Mode

  --- The mode `COSMIC_GRAMMAR` asks for ([`GrammarMode.mode`]).
  mode: function(): Mode | nil, string

  --- The tool string a compile in `mode` is keyed by ([`GrammarMode.tool`]).
  tool: function(tool: string, mode: Mode, wraps?: boolean): string

  --- What a pipeline is made of besides the tree.
  record Options
    --- The standard library's declarations, which every module's globals are made of ([`build.tree_program`]).
    globals: TreeProgram.Globals
    --- The ceilings that hold the modules: none for a project outside cosmic's tree, whose every error refuses.
    ceilings: Ceilings.Table
    --- Whether the checker keeps the type of each node, which the readers of the type report need.
    types: boolean
    --- Answers the `cosmic.*` modules the tree does not hold, each its stub or its source: [`Pipeline.carried`] where
    --- not given.
    standard: Driver.Provider | nil
  end

  --- A build over the tree and its ceilings.
  record Built
    build: Driver.Build
    ceilings: Ceilings.Table
  end

  --- The options for the tree at `root`: in cosmic's own tree the declarations and the ceilings it holds. nil and why for any
  --- other tree, a project's, whose globals the tool does not carry yet.
  --
  -- TODO: have the tool carry the declarations of the standard library, as the `decls` of its projection do the bindings of
  -- C, so that a project's globals are the new checker's and not the carried fork's: once the staged tree takes
  -- [`checker/stdlib.d.tl`] as a declaration (build/identity.tl's `is_input`). That moves the identity of the tool, so it
  -- belongs with the change of the switch that boots, reboots and identifies the compiler (doc/plans/strict-teal.md, "the
  -- switch"), and the project fixture of the rehearsal waits on it.
  options: function(root: string): Options | nil, string

  --- The `cosmic.*` modules of the running binary, each its stub or its source, as the fork reads them
  --- ([`teal.standard_text`]), a declaration ([`cosmic.sys`]) as one.
  carried: function(): Driver.Provider

  --- A build over the modules of `entries`: pairs of a file and its text, with the module and the name the ceilings are kept
  --- under for a source written from another file ([`Driver.index`]). `kinds` says of each file what the working database
  --- says of its input (`test`, ...); a `test` has its functions called from outside.
  over: function(entries: {{string}}, kinds: {string: string}, options: Options): Built

  --- A build over the `inputs` of the working database `db`: the tree and what is written from it (the guides, the
  --- templates, the bindings of C).
  build: function(db: Sqlite.Handle, options: Options): Built | nil, string

  --- The modules the pipeline refuses though no ceiling is over: the file and the code of the first line of the refusal.
  --- A ceiling counts the errors of the checker; these are three other refusals of `generate`. Each module fails to
  --- compile with the new checker until its entry is gone:
  ---
  --- - `is_on_record`, from the generator: a test `x is R` of a record, which has no run-time tag to test. The checker
  ---   accepts it up to the pin of the code in `[checked]`; the generator cannot write it (a tag test, a class, or
  ---   validating the data is the fix).
  --- - `unused_function` and `unused_type`, warnings of 14 modules, none of them unused code: 12 are a function or type
  ---   the translated program uses before it declares it (the translator puts a class where its record was, above the
  ---   local functions its methods call, so the Lua reads a global and the scope builder finds no read), and 2 are an
  ---   import whose last use the mend of [`build.tree_program`] rewrote to a tag test.
  --- - `method_dot`, `method_in_record` and `function_path`, warnings of a form the new grammar spells otherwise (a
  ---   method called with `.`, a method declared outside its class, a function assigned to a path of more than one dot):
  ---   in the guide [`doc/guides/project.md`] and [`cosmic/removed_example.tl`] it is the example of the form.
  ---
  --- [`build.pipeline_check`] holds this list to the tree in both directions, so a module fixed leaves it and a module
  --- newly refused is named here with its reason, as the ceilings name a count.
  residue: function(): {string: string}

  --- The Lua and the bytecode of the module `m`, checked and written by the new checker, as [`build.compilation`]'s
  --- `generate` answers them: nil and why where the module is refused. With `facts` each read of a place a test narrowed
  --- is wrapped in a check ([`lang.fact_wraps`]). The references are none.
  generate: function(m: Compilation.Module, built: Built, facts?: boolean): Compilation.Generated | nil, string
end

Pipeline.mode = GrammarMode.mode
Pipeline.tool = GrammarMode.tool

-- TODO: compile each of these modules in the new mode: the wiring's compile step, which calls this module from the
-- build's own compile, takes each up (doc/plans/strict-teal.md, "the switch"), and the entry leaves the list. The tagged
-- unions of the switch cover `is_on_record`; the rewrite of the four forms covers `method_dot`, `method_in_record` and
-- `function_path`; the translator's placement of a class ([`lang.translate`]) covers the unused functions and types.
local RESIDUE <const>: {string: string} = {
  ["build/ast/match.tl"] = "is_on_record",
  ["build/ast/walk.tl"] = "is_on_record",
  ["build/codec.tl"] = "unused_function",
  ["build/compilation.tl"] = "is_on_record",
  ["build/fix/expr.tl"] = "method_dot",
  ["build/sandbox.tl"] = "is_on_record",
  ["build/shape_specs.tl"] = "is_on_record",
  ["build/syntax_typed_fixture.tl"] = "is_on_record",
  ["build/time.tl"] = "is_on_record",
  ["build/tree_root.tl"] = "is_on_record",
  ["build/verbs_store_test.tl"] = "is_on_record",
  ["core/allocation_test.tl"] = "is_on_record",
  ["cosmic/child.tl"] = "unused_function",
  ["cosmic/flags.tl"] = "is_on_record",
  ["cosmic/fs.tl"] = "unused_function",
  ["cosmic/http/multipart.tl"] = "unused_type",
  ["cosmic/http/wire.tl"] = "unused_function",
  ["cosmic/internal/connector.tl"] = "unused_function",
  ["cosmic/json.tl"] = "unused_function",
  ["cosmic/poll.tl"] = "unused_function",
  ["cosmic/removed_example.tl"] = "method_in_record",
  ["cosmic/sqlite.tl"] = "unused_function",
  ["cosmic/stream.tl"] = "unused_function",
  ["cosmic/tar.tl"] = "unused_function",
  ["cosmic/template_build_test.tl"] = "is_on_record",
  ["cosmic/template_check_test.tl"] = "is_on_record",
  ["cosmic/template_go_test.tl"] = "is_on_record",
  ["cosmic/web/htmx.tl"] = "is_on_record",
  ["cosmic/zip.tl"] = "unused_function",
  ["doc/guides/project.md"] = "function_path",
  ["lang/declarations_test.tl"] = "method_dot",
  ["lang/types_programs.tl"] = "unused_type",
  ["lang/warnings_test.tl"] = "unused_type",
  ["test/sqlite_result_test.tl"] = "is_on_record",
}

function Pipeline.residue(): {string: string}
  return RESIDUE
end

function Pipeline.options(root: string): Pipeline.Options | nil, string
  local own, own_why = tree.is_own(root)
  if own == nil then
    return nil, own_why
  end
  if not own then
    return nil, "the tool carries no declaration of the standard library for the new checker yet, so " ..
      "COSMIC_GRAMMAR=new does not build a project outside cosmic's tree: unset COSMIC_GRAMMAR (or set it to teal) to build it"
  end
  local stdlib, stdlib_why = Fs.read(root .. "/checker/stdlib.d.tl")
  if stdlib == nil then
    return nil, stdlib_why
  end
  local ceilings, ceilings_why = Ceilings.read(root)
  if ceilings == nil then
    return nil, ceilings_why
  end
  return {
    globals = TreeProgram.fork_globals(root, Driver.source("checker.stdlib", "checker/stdlib.d.tl", stdlib, "decl")),
    ceilings = ceilings, types = false, standard = nil,
  }
end

--- Whether the binary holds the module `name` as a declaration.
local function declared(name: string): boolean
  local databases = Store.databases()
  local rows, _ = Sqlite.text_rows(databases[#databases], "SELECT 1 FROM decls WHERE path = ?1", { { text = name } })
  return rows ~= nil and #rows > 0
end

function Pipeline.carried(): Driver.Provider
  return Driver.standard(function(module: string): string | nil
    local found = teal.standard_text(module)
    if found == nil then
      return nil
    end
    return found.text
  end, true, declared)
end

function Pipeline.over(entries: {{string}}, kinds: {string: string}, options: Pipeline.Options): Pipeline.Built
  local index = TreeProgram.index(entries, true, kinds)
  local standard = options.standard or Pipeline.carried()
  return {
    build = TreeProgram.build(index, options.globals, options.types, nil, standard), ceilings = options.ceilings,
  }
end

function Pipeline.build(db: Sqlite.Handle, options: Pipeline.Options): Pipeline.Built | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT file, path, kind, origin, source FROM inputs WHERE kind <> 'vendor' ORDER BY file")
  if rows == nil then
    return nil, trouble
  end
  local entries: {{string}} = {}
  local kinds: {string: string} = {}
  for _, row in ipairs(rows) do
    local file, path, kind, origin, source = row:text(1), row:text(2), row:text(3), row:text(4), row:text(5)
    if origin == "syscalls" then
      -- The declaration is the file of the module, named for the header it is written from in the ceilings.
      local named = (path:gsub("%.", "/")) .. ".d.tl"
      entries[#entries + 1] = { named, source, path, file }
      kinds[named] = kind
    elseif origin == "tree" then
      entries[#entries + 1] = { file, source }
      kinds[file] = kind
    else
      entries[#entries + 1] = { file, source, path }
      kinds[file] = kind
    end
  end
  return Pipeline.over(entries, kinds, options)
end

function Pipeline.generate(m: Compilation.Module, built: Pipeline.Built, facts?: boolean):
    Compilation.Generated | nil, string
  local build = built.build
  -- The calls of [`Shape.record_of`] are resolved in the text the checker reads, and the module is read again with them.
  local spliced, spec_trouble = TreeProgram.splice(build, m.path, m.file)
  if spliced == nil then
    return nil, spec_trouble
  end
  build:lower({ m.path })
  local result = build:result(m.path, true)
  if result == nil then
    return nil, m.file .. ": the new checker's build has no module " .. m.path
  end
  local lines: {string} = {}
  if result.broken then
    -- A pin counts the errors of a translation that does not parse; there is no syntax tree to write Lua from.
    for _, p in ipairs(result.syntax) do
      lines[#lines + 1] = ErrorRender.line(m.file, p)
    end
  else
    for _, line in ipairs(build:held(result, built.ceilings)) do
      lines[#lines + 1] = line
    end
    for _, w in ipairs(result.warnings) do
      lines[#lines + 1] = ErrorRender.line(m.file, w)
    end
  end
  if #lines > 0 then
    return nil, m.file .. ": the compiler refused it\n" .. table.concat(lines, "\n")
  end
  local emitted = CompileGrammar.emit(build, result, facts)
  local code = emitted.code
  if code == nil then
    return nil, m.file .. ": the generator wrote no Lua: " .. emitted.trouble
  end
  if m.kind == "test" then
    code = LuaTail.with_test_tail(code, m.tests)
  end
  local bytecode, dump_trouble = LuaTail.bytecode_of(code, m.path, m.file)
  if bytecode == nil then
    return nil, dump_trouble
  end
  return { lua = code, bytecode = bytecode, references = {}, refused = false }, ""
end

return Pipeline
