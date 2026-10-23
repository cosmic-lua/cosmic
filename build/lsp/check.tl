--- How `cosmic lsp` ([`build.lsp`]) checks a document: as a build checks
--- the module it is, in memory, as the editor holds it, and what it then
--- publishes.
---
--- What it publishes: the checker's syntax and type errors and its
--- warnings, which a build refuses as it refuses errors, each worded as a
--- build words it ([`importer.said`]), and what else a build refuses of a
--- module: a `global`, a test that returns a value, an example that
--- returns none, a [`Test.policy`] outside a test, a `require` that
--- position refuses or that closes a cycle of imports
--- ([`build.lsp.graph`]), and in cosmic's own tree its contracts and its
--- stub ([`compilation.generate`]). A template is checked as a build
--- checks one: compiled ([`Template.compile`]), its refusal where it
--- says, then its Teal checked as the module it is, whose errors a build
--- puts in the Teal, not the template, and which are published at its
--- start.
---
--- The text is checked after the rewrite a build makes of it first
--- ([`build.shape_specs`]), so a column is the document's own. A `require`
--- is answered from an open document, then the working database
--- ([`build.lsp.source`]), then the binary's own `cosmic.*` modules.
---
--- A file a build reads no module from ([`analysis_schema.is_module_file`]:
--- a `testdata` directory's, a site's static files) publishes nothing,
--- and an open one is no module a `require` reads; nor does one in a tree
--- of its own inside cosmic's (`ci/`), nor any of a root that is no
--- project, whose modules no build has found ([`source.outside`]), nor
--- a document that is no file below the root (another directory's, an
--- `untitled:` one, `<root>/../x.tl`), which no build at the root reads.
--- A file below the root that the stage does not list yet, one new and
--- unsaved, is the root's: the build that next stages the tree reads it,
--- so it is checked as the module it will be.
---
--- A module served stays checked between checks, its type in the
--- checker's `modules`, until what it would be served from changes: an
--- open document's text, the document closing, or the stage. Then every
--- module served is checked again, since one that requires the changed
--- one may change with it. A document whose text has not changed since
--- its last check, with no module served dropped since, publishes what
--- it published then.

local Driver = require("build.driver")
local GrammarMode = require("build.grammar_mode")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Pipeline = require("build.pipeline")
local Template = require("cosmic.template")
local TreeProgram = require("build.tree_program")
local analysis_schema = require("build.analysis_schema")
local graph = require("build.lsp.graph")
local identity = require("build.identity")
local importer = require("build.importer")
local lines = require("build.lsp.lines")
local plan = require("build.lsp.plan")
local protocol = require("build.lsp.protocol")
local receivers = require("build.receivers")
local shape_specs = require("build.shape_specs")
local source = require("build.lsp.source")
local splice = require("build.lsp.splice")
local syntax_read = require("build.lsp.syntax_read")
local teal = require("build.teal")
local type compiler = require("build.compiler")

local record check
  --- A document the editor holds open.
  record Document
    uri: string
    text: string
    --- The name the checker knows it by: its path below the root, or its
    --- absolute path or URI when it is not below it.
    name: string
    --- Whether it is no file below the root, which no build there reads.
    outside: boolean
    --- The SHA-256 of `text`, once asked for.
    hash: string | nil
    --- What it last published, each diagnostic encoded, and the text and
    --- the checker's [`Checker`] `epoch` it was of.
    published: {string} | nil
    published_text: string
    published_epoch: integer
    --- What its text required at its last check, nil before one.
    requires: {string} | nil
  end

  --- One session's checker.
  record Checker
    root: string
    source: source.View
    --- The checker the session checks with: the fork's (`teal`), or the new one's (`new`), which reads and checks a text in
    --- the new grammar ([`build.grammar_mode`]).
    grammar: GrammarMode.Mode
    --- The fork's compiler, which the new grammar reads no text with either: it stages the tree ([`source.refresh`]).
    built: compiler | nil
    env: compiler.Env | nil
    --- What the new checker is made over besides the document: the declarations of the standard library the tool carries.
    options: Pipeline.Options | nil
    --- The types the checker reports of the document it checks, which
    --- [`build.contracts`] reads.
    typed: receivers.State | nil
    --- The globals a fresh environment has, so a check drops those an
    --- earlier text declared.
    base_globals: {string:boolean}
    --- What each project module the checker was served was served from
    --- ([`source.key`]), by name: "" for one not found.
    served: {string:string}
    --- How many times the modules served were dropped.
    epoch: integer
    --- The open documents, by name.
    open: {string:Document}
    --- The databases a message's hint looks a name up in.
    hints: importer.Hints
    --- Whether a check found a document requiring other modules than
    --- before, since [`check.moved`] last asked: a cycle of imports
    --- through another open document may have closed or opened.
    graph_moved: boolean
    --- How many times each document was checked, by name, those
    --- answered from its last check among them: what a test reads.
    checks: {string:integer}
  end
end

local type Checker = check.Checker
local type Document = check.Document

--- A checker of the tree at `root`, made ready on its first check, that checks with the checker `grammar` names: the one
--- `COSMIC_GRAMMAR` asks for where none is given.
function check.new(root: string, err: function(line: string), hints: importer.Hints, grammar?: GrammarMode.Mode): Checker
  local view = source.new(root, err, grammar)
  return {
    root = root,
    source = view,
    grammar = view.grammar,
    built = nil,
    env = nil,
    options = nil,
    typed = nil,
    base_globals = {},
    served = {},
    epoch = 0,
    open = {},
    hints = hints,
    graph_moved = false,
    checks = {},
  }
end

--- A document of `text` at `uri`, named `name`, which is no file below
--- the root where `outside`.
function check.document(uri: string, name: string, text: string, outside?: boolean): Document
  return { uri = uri, text = text, name = name, outside = outside == true, hash = nil, published = nil,
    published_text = "", published_epoch = 0, requires = nil }
end

--- Whether `document` is no module a build at the root reads
--- ([`analysis_schema.is_module_file`]), or is no file below the root.
local function unread(document: Document): boolean
  return document.outside or not analysis_schema.is_module_file(document.name)
end

--- Gives `document` the text `text`.
function check.set_text(document: Document, text: string)
  document.text = text
  document.hash = nil
end

--- Makes `document` one a `require` reads, where it is a module a build
--- at the root reads ([`unread`]).
function check.opened(checker: Checker, document: Document)
  if not unread(document) then checker.open[document.name] = document end
end

--- The SHA-256 of `document`'s text.
local function hash_of(document: Document): string
  local hash = document.hash
  if hash == nil then
    hash = Hash.hex_sha256(document.text)
    document.hash = hash
  end
  return hash
end

--- Whether closing `document`, open as a module a `require` reads, moves
--- what the open documents require: it required other modules than its
--- file as staged.
function check.regraphs(checker: Checker, document: Document): boolean
  if checker.open[document.name] ~= document then return false end
  local listed = source.module(checker.source, document.name)
  if listed == nil then return false end
  local staged = checker.source.requires[listed.source_hash] or {}
  return table.concat(document.requires or staged, "\0") ~= table.concat(staged, "\0")
end

--- Makes `document` one a `require` no longer reads. Where it stood for
--- its file with another text than the stage's, the modules served are
--- dropped at the next check ([`refresh`]); its dependents are checked
--- again where what it serves changed ([`build.lsp.dependents`]). Where
--- it required other modules than the stage's, a cycle of imports may
--- have closed or opened: every other open document is to be checked
--- again ([`check.moved`]).
function check.closed(checker: Checker, document: Document)
  if checker.open[document.name] ~= document then return end
  local regraphs = check.regraphs(checker, document)
  checker.open[document.name] = nil
  local listed = source.module(checker.source, document.name)
  if regraphs then
    checker.graph_moved = true
    checker.epoch = checker.epoch + 1
  elseif listed ~= nil and hash_of(document) ~= listed.source_hash then
    checker.epoch = checker.epoch + 1
  end
end

--- Stages the tree again before the next check: files changed on disk.
function check.stale(checker: Checker)
  source.stale(checker.source)
end

--- Whether a check since the last ask found a document requiring other
--- modules than before ([`Checker`]'s `graph_moved`): every other open
--- document is then to be checked again.
function check.moved(checker: Checker): boolean
  local moved = checker.graph_moved
  checker.graph_moved = false
  return moved
end

--- Lets go of what the checker holds open.
function check.close(checker: Checker)
  source.close(checker.source)
end

--- The open documents as [`source.Open`] reads them.
function check.open_files(checker: Checker): source.Open
  return function(file: string): source.Text | nil
    local document = checker.open[file]
    if document == nil then return nil end
    return { text = document.text, hash = hash_of(document) }
  end
end

--- The fork's compiler, made on first use. A session of the new grammar holds it to stage the tree
--- ([`source.refresh`]) and to read nothing with.
local function compiler_of(checker: Checker): compiler
  local held = checker.built
  if held ~= nil then return held end
  local loaded = assert(teal.load())
  checker.built = loaded
  return loaded
end

--- The fork's checker and its environment, made on first use.
local function prepared(checker: Checker): compiler, compiler.Env
  local built, env = checker.built, checker.env
  if built ~= nil and env ~= nil then return built, env end
  local loaded = compiler_of(checker)
  local open = check.open_files(checker)
  loaded.search_module = function(name: string, _search_all: boolean): string | nil, compiler.Handle | nil
    local listed = checker.source.modules[name] ~= nil
    local found = source.served(checker.source, loaded, name, open)
    if found ~= nil then
      checker.served[name] = found.key
      return found.file, teal.served(splice.rewritten(checker.built, checker.env, name, found))
    end
    if listed then
      checker.served[name] = source.key(checker.source, name, open)
      return nil, nil
    end
    local standard = teal.standard_text(name)
    if standard == nil then
      checker.served[name] = ""
      return nil, nil
    end
    return name:gsub("%.", "/") .. ".tl", teal.served(standard.text)
  end
  local made, env_trouble = loaded.new_env({ defaults = teal.defaults() })
  if made == nil then error(env_trouble, 0) end
  teal.strip(made)
  for name in pairs(made.globals) do checker.base_globals[name] = true end
  checker.typed = receivers.install(made)
  checker.built, checker.env = loaded, made
  return loaded, made
end

--- The fork's compiler, made on first use: the checker of a session of the fork's grammar, and what stages the tree of one of
--- the new.
function check.compiler(checker: Checker): compiler
  if checker.grammar == "new" then return compiler_of(checker) end
  local built, _ = prepared(checker)
  return built
end

--- Readies `env` for a check: drops the globals an earlier text declared,
--- which would be declared twice, and the project modules served before
--- when one of them would now be served otherwise ([`source.key`]), all
--- of them. A module whose global was dropped is checked again too, to
--- declare it again: the served modules are dropped whenever an earlier
--- check declared a global, the document's own or a module's. The
--- `cosmic.*` modules the binary serves stay, which is most of what a
--- check costs.
---
--- A session of the new grammar has no environment (`env` is nil): each check is made over a program of its own
--- ([`program_of`]), which holds no global an earlier text declared, so a module served is dropped only when it would
--- now be served otherwise.
local function refresh(checker: Checker, env: compiler.Env | nil)
  local stale = false
  if env ~= nil then
    for name in pairs(env.globals) do
      if checker.base_globals[name] ~= true then
        env.globals[name] = nil
        stale = true
      end
    end
  end
  local open = check.open_files(checker)
  for name, key in pairs(checker.served) do
    if stale then break end
    if source.key(checker.source, name, open) ~= key then stale = true end
  end
  if not stale then return end
  if env ~= nil then
    for name in pairs(checker.served) do
      env.modules[name] = nil
      env.module_filenames[name] = nil
    end
  end
  checker.served = {}
  checker.epoch = checker.epoch + 1
end

--- What one check of a document found: the errors of the document
--- itself, and the text and splices they are positioned in.
local record Checked
  errors: {compiler.Error}
  --- What a build refuses beyond the checker's errors.
  refusals: {plan.Refusal}
  --- The Teal checked, before and after the build's rewrite: a
  --- template's is the Teal it compiles to.
  source: string
  text: string
  splices: {shape_specs.Splice}
  refused: {string:boolean}
  --- Whether the places found are in a template's Teal, not in the
  --- document's own text.
  generated: boolean
end

--- What each other open document required at its last check, by name.
local function opened_requires(checker: Checker, document: Document): {string:{string}}
  local out: {string:{string}} = {}
  for name, other in pairs(checker.open) do
    local requires = other.requires
    if other ~= document and requires ~= nil then out[name] = requires end
  end
  return out
end

--- Keeps what `document` requires now (`sites`), and says the graph moved
--- where that is not what it required before: at its last check, or, at
--- its first, as staged.
local function remember(checker: Checker, document: Document, sites: {plan.Site})
  local names: {string} = {}
  for _, site in ipairs(sites) do names[#names + 1] = site.name end
  local before: {string} = {}
  local had = document.requires
  if had ~= nil then
    before = had
  else
    local listed = source.module(checker.source, document.name)
    if listed ~= nil then before = checker.source.requires[listed.source_hash] or before end
  end
  if table.concat(before, "\0") ~= table.concat(names, "\0") then
    checker.graph_moved = true
    checker.epoch = checker.epoch + 1
  end
  document.requires = names
end

--- The options of the new checker's program: the declarations of the standard library the tool carries, and no ceiling,
--- so that every error of the checker refuses, as `cosmic lsp` refuses every error of the fork's.
local function options_of(checker: Checker): Pipeline.Options
  local held = checker.options
  if held ~= nil then return held end
  local made, trouble = Pipeline.alone()
  if made == nil then error(trouble, 0) end
  checker.options = made
  return made
end

--- What answers the new checker for a module a `require` names: the working database's, or an open document's, as the fork's
--- `search_module` answers it ([`source.served`]), or the binary's own `cosmic.*` modules. The modules the stage lists are
--- read in the fork's Teal where they are, translated as a build translates them, and never checked: what a `require` reads
--- is their type.
local function provider_of(checker: Checker, built: compiler): Driver.Provider
  local open = check.open_files(checker)
  local carried = Pipeline.carried()
  local listed = Driver.standard(function(module: string): string | nil
    local found = source.served(checker.source, built, module, open)
    if found == nil then return nil end
    checker.served[module] = found.key
    return found.text
  end, true, function(module: string): boolean
    local named = checker.source.modules[module]
    return named ~= nil and named.kind == "decl"
  end)
  return function(module: string): Driver.Source | nil
    if checker.source.modules[module] ~= nil then
      local made = listed(module)
      if made == nil then checker.served[module] = source.key(checker.source, module, open) end
      return made
    end
    local standard = carried(module)
    if standard == nil then checker.served[module] = "" end
    return standard
  end
end

--- A program of the new checker over the document `text`, the file `name`, the module `path` of `kind`, with the modules it
--- requires served ([`provider_of`]).
--
-- TODO: hold one program for the session and put the document's text in it with [`Driver.Build.replace`], with the modules
-- the stage lists served as stubs, once [`build.lsp.check`] is rebuilt on the driver (the next piece of the `cosmic lsp` port,
-- doc/plans/strict-teal.md, "the switch"): a program made for each check lowers the library's declarations again each time. A check
-- of a 17-line document that requires cosmic.fs and cosmic.json takes ~350 ms in the new grammar (the fork's ~7 ms), ~150 ms of it
-- the program lowering the globals (~70 ms) and the two modules; the stubs and `replace` of the next piece take it to ~70 ms.
local function program_of(checker: Checker, built: compiler, name: string, text: string, path: string,
                          kind: string): Pipeline.Built
  local options = options_of(checker)
  local provider = provider_of(checker, built)
  local index = Driver.index({ { name, text, path } }, false, function(_: string): boolean
    return false
  end,
    function(_: string, _: string): Driver.Extra return { tests = kind == "test", mend = nil } end)
  return {
    build = TreeProgram.build(index, options.globals, true, nil, provider),
    ceilings = options.ceilings, index = index, globals = options.globals, standard = provider, types = true,
    given = {}, stubs = nil, stubbed = nil,
  }
end

--- What a build refuses of `text` before it checks it ([`plan.of`]), as the checker of the session reads it.
local function planned_of(checker: Checker, built: compiler, name: string, text: string, path: string, kind: string,
                          own_tree: boolean, generated: boolean): plan.Planned
  if checker.grammar == "new" then
    return syntax_read.plan_of(name, text, path, kind, own_tree, generated)
  end
  return plan.of(built, name, text, path, kind, own_tree, generated)
end

--- Checks `document` in `env`, as a build checks it; in the new grammar `env` is nil, and a program of the new checker
--- ([`program_of`]) is the environment.
local function checked_of(checker: Checker, built: compiler, env: compiler.Env | nil,
                          document: Document): Checked
  local none: {shape_specs.Splice} = {}
  local found: {compiler.Error} = {}
  local generated = document.name:match("%.tmpl$") ~= nil
  local text = document.text
  if generated then
    -- A project is held to the new grammar with no ceiling to excuse the fork's: a template of the new checker writes it.
    local compiled, trouble = Template.compile(document.text, document.name, { dialects = nil, new_grammar = checker.grammar == "new" })
    if compiled == nil then
      return { errors = found, refusals = { plan.refusal_of(trouble) }, source = text, text = text,
        splices = none, refused = {}, generated = false }
    end
    text = compiled
  end
  --- What was found, its places in `spliced` as spliced by `splices`.
  local function checked(refusals: {plan.Refusal}, spliced: string, splices: {shape_specs.Splice},
                         refused: {string:boolean}): Checked
    return { errors = found, refusals = refusals, source = text, text = spliced, splices = splices,
      refused = refused, generated = generated }
  end
  local named = plan.named(document.name)
  local path, kind = named.path, named.kind
  local listed = source.module(checker.source, document.name)
  if listed ~= nil then path, kind = listed.path, listed.kind end
  local own_tree = source.own_tree(checker.source)
  local planned = planned_of(checker, built, document.name, text, path, kind, own_tree, generated)
  remember(checker, document, planned.requires)
  local refusals = planned.refusals
  local subject = planned.plan
  if planned.halted and subject == nil then return checked(refusals, text, none, {}) end
  -- A build checks where every module's requires reach before it checks
  -- any, a declaration's aside ([`compilation.collect`]), and stops there.
  if subject ~= nil and kind ~= "decl" then
    local placed = graph.refusals(checker.source, document.name, path, kind, planned.requires,
      opened_requires(checker, document))
    if #placed > 0 then return checked(placed, text, none, {}) end
  end
  if planned.halted then return checked(refusals, text, none, {}) end
  if checker.grammar == "new" then
    -- A text that does not parse halts the plan, so there is one here.
    local program = program_of(checker, built, document.name, text, path, kind)
    local tally = checker.source.tally
    local resolution = syntax_read.splices(program.build, document.name, text, path, function()
      tally.whole_splices = tally.whole_splices + 1
    end)
    if resolution.refusal ~= "" then
      local refused = plan.refusal_of(resolution.refusal)
      refusals[#refusals + 1] = { line = resolution.line, column = refused.column, message = refused.message }
      return checked(refusals, text, none, {})
    end
    local splices = resolution.splices
    local spliced = syntax_read.applied(text, splices)
    -- The program splices the same calls again when it writes the module ([`Pipeline.generate`]), to the same text.
    local compiled = syntax_read.generated(assert(subject), program, checker.hints, planned.requires,
      function(name: string): boolean return checker.source.modules[name] ~= nil end)
    for _, refusal in ipairs(compiled.refusals) do refusals[#refusals + 1] = refusal end
    return checked(refusals, spliced, splices, {})
  end
  local fork = assert(env, "the fork's checker has no environment")
  local resolution = splice.found(built, fork, document.name, text, path, checker.source.tally)
  if resolution.refusal ~= "" then
    local refused = plan.refusal_of(resolution.refusal)
    refused.line = resolution.line
    refusals[#refusals + 1] = refused
    return checked(refusals, text, none, {})
  end
  local splices = resolution.splices
  local spliced = shape_specs.spliced(text, splices)
  local result: compiler.Result | nil = nil
  if subject == nil or subject.kind == "decl" then
    result = built.check_string(spliced, fork, document.name, "tl")
  else
    local compiled = plan.compiled(subject, built, fork, assert(checker.typed), own_tree, spliced)
    result = compiled.result
    for _, refusal in ipairs(compiled.refusals) do refusals[#refusals + 1] = refusal end
  end
  if result == nil then return checked(refusals, spliced, splices, {}) end
  -- A text with a syntax error has no warnings, nor a list of them: the
  -- list of lists ends there.
  for _, group in ipairs({ result.syntax_errors, result.type_errors, result.warnings }) do
    for _, e in ipairs(group) do found[#found + 1] = e end
  end
  return checked(refusals, spliced, splices, teal.refused_type_requires(document.name, text, result))
end

--- Whether the file `name` is in a tree of its own inside cosmic's
--- ([`identity.is_foreign_tree`]), which a build of it never reads.
local function apart(checker: Checker, name: string): boolean
  return source.own_tree(checker.source) and identity.is_foreign_tree(identity.first_of(name))
end

--- The diagnostics of `document`, each encoded, its positions counted in
--- `encoding`'s units.
function check.diagnose(checker: Checker, document: Document, encoding: string): {string}
  local none: {string} = {}
  if unread(document) then
    document.published = none
    return none
  end
  local built = compiler_of(checker)
  local env: compiler.Env | nil = nil
  if checker.grammar ~= "new" then
    local _, made = prepared(checker)
    env = made
  end
  local outside = source.outside(checker.source)
  source.refresh(checker.source, built)
  if source.outside(checker.source) or apart(checker, document.name) then
    document.published = none
    return none
  end
  -- A build was started where there was none: every open document is
  -- checked again, against the modules now found.
  if outside then
    checker.graph_moved = true
    checker.epoch = checker.epoch + 1
  end
  refresh(checker, env)
  checker.checks[document.name] = (checker.checks[document.name] or 0) + 1
  local published = document.published
  if published ~= nil and document.published_text == document.text and
      document.published_epoch == checker.epoch then
    return published
  end
  -- What the check adds to `loaded` is dropped after it, its results'
  -- trees with it: a module's type stays in `modules`, which is what a
  -- later check reads, and a text read again is checked again.
  local order: {string} = {}
  if env ~= nil then order = env.loaded_order end
  local before = #order
  local ok, outcome = pcall(checked_of, checker, built, env, document)
  if env ~= nil then
    for i = #order, before + 1, -1 do
      local name = order[i]
      if name ~= nil then env.loaded[name] = nil end
      table.remove(order, i)
    end
  end
  if not ok then error(tostring(outcome), 0) end
  local checked: Checked = outcome
  local held = lines.lines_of(document.text)
  local starts = lines.checker_starts(checked.text)
  local out: {string} = {}
  --- The diagnostic `message` at the checker's line `y` and column `x`.
  local function add(y: integer, x: integer, message: string, code: string | nil)
    local line = math.min(math.max(y, 1), #starts)
    local at = math.min(assert(starts[line]) + math.max(x, 1) - 1, #checked.text + 1)
    local offset = splice.unspliced(checked.splices, at)
    -- A place in a template's Teal is none in the template.
    if checked.generated then offset = 1 end
    local word = document.text:match("^[%w_]+", offset) or ""
    local diagnostic: protocol.Diagnostic = {
      range = protocol.range(lines.position(held, offset, encoding),
        lines.position(held, offset + math.max(#word, 1), encoding)),
      -- A build refuses a warning as it does an error.
      severity = 1,
      source = "cosmic",
      message = message,
      code = code,
    }
    out[#out + 1] = assert(Json.encode(diagnostic))
  end
  for _, refusal in ipairs(checked.refusals) do
    add(refusal.line, refusal.column, refusal.message, nil)
  end
  for _, e in ipairs(checked.errors) do
    local code: string | nil = e.code
    if code == nil then code = e.tag end
    add(e.y, e.x, importer.said(e, document.name, checked.source, checked.refused, checker.hints), code)
  end
  document.published = out
  document.published_text = document.text
  document.published_epoch = checker.epoch
  return out
end

return check
