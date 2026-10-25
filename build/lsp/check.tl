--- How `cosmic lsp` ([`build.lsp`]) checks a document: as a build checks
--- the module it is, in memory, as the editor holds it, and what it then
--- publishes.
---
--- What it publishes: the checker's syntax and type errors and its
--- warnings, which a build refuses as it refuses errors, each worded as a
--- build words it ([`build.error_render`]), and what else a build refuses of a
--- module: a `global`, a test that returns a value, an example that
--- returns none, a [`Test.policy`] outside a test, a `require` that
--- position refuses or that closes a cycle of imports
--- ([`build.lsp.graph`]), and in cosmic's own tree its contracts and its
--- stub ([`build.pipeline`]'s `review`). A template is checked as a build
--- checks one: compiled ([`Template.compile`]), its refusal where it
--- says, then its Teal checked as the module it is, whose errors a build
--- puts in the Teal, not the template, and which are published at its
--- start.
---
--- The text is checked after the rewrite a build makes of it first
--- ([`build.syntax_shape_specs`]), so a column is the document's own. A `require`
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
--- A session checks every document in one program kept between checks ([`build.lsp.held`]): the document's text is put in it,
--- and each module served is put in it again where what it is served as changes, so that a check lowers the standard library
--- once and the stubs the document reaches, and not the project. A document whose text has not changed since its last check,
--- with no module served dropped since, publishes what it published then.

local Ast = require("lang.ast")
local Driver = require("build.driver")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Pipeline = require("build.pipeline")
local ShapeSpecs = require("build.syntax_shape_specs")
local Sqlite = require("cosmic.sqlite")
local Template = require("cosmic.template")
local analysis_schema = require("build.analysis_schema")
local graph = require("build.lsp.graph")
local held = require("build.lsp.held")
local identity = require("build.identity")
local importer = require("build.importer")
local lines = require("build.lsp.lines")
local plan = require("build.lsp.plan")
local protocol = require("build.lsp.protocol")
local source = require("build.lsp.source")
local syntax_read = require("build.lsp.syntax_read")

local record check
  --- A document the editor holds open.
  record Document
    uri: string
    mut text: string
    --- The name the checker knows it by: its path below the root, or its
    --- absolute path or URI when it is not below it.
    name: string
    --- Whether it is no file below the root, which no build there reads.
    outside: boolean
    --- The SHA-256 of `text`, once asked for.
    mut hash: string?
    --- What it last published, each diagnostic encoded, and the text and
    --- the checker's [`Checker`] `epoch` it was of.
    mut published: {string}?
    mut published_text: string
    mut published_epoch: integer
    --- What its text required at its last check, nil before one.
    mut requires: {string}?
  end

  --- The databases a message's hint looks a name up in, and whether each is read as the public standard library's.
  record Hinted
    databases: {Sqlite.Handle}
    public: {boolean}
  end

  --- One session's checker.
  record Checker
    root: string
    source: source.View
    --- What the checker is made over besides the document: the declarations of the standard library the tool carries.
    mut options: Pipeline.Options?
    --- The program the session checks in ([`build.lsp.held`]), made at its first check.
    mut program: held.Program?
    --- What each project module the checker was served was served from
    --- ([`source.key`]), by name: "" for one not found.
    mut served: mut {string:string}
    --- How many times the modules served were dropped.
    mut epoch: integer
    --- The open documents, by name.
    open: mut {string:Document}
    --- The databases a message's hint looks a name up in.
    hints: function(): Hinted
    --- Whether a check found a document requiring other modules than
    --- before, since [`check.moved`] last asked: a cycle of imports
    --- through another open document may have closed or opened.
    mut graph_moved: boolean
    --- How many times each document was checked, by name, those
    --- answered from its last check among them: what a test reads.
    checks: mut {string:integer}
  end
end

local type Checker = check.Checker
local type Document = check.Document

--- The hints of `checker` as the importer asks for them.
local function importer_hints(checker: Checker): importer.Hints
  return function(): {Sqlite.Handle}, {boolean}
    local hinted = checker.hints()
    return hinted.databases, hinted.public
  end
end

--- A checker of the tree at `root`, made ready on its first check.
function check.new(root: string, err: function(line: string), hints: function(): check.Hinted): Checker
  local view = source.new(root, err)
  return {
    root = root,
    source = view,
    options = nil,
    program = nil,
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
--- dropped at the next check ([`source.refresh`]); its dependents are checked
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
  checker.program = nil
  source.close(checker.source)
end

--- The open documents as [`source.Open`] reads them.
function check.open_files(checker: Checker): source.Open
  return function(file: string): source.Text?
    local document = checker.open[file]
    if document == nil then return nil end
    return { text = document.text, hash = hash_of(document) }
  end
end

--- The modules the session's program holds, served otherwise than they were ([`source.key`]) while there are no more than
--- this many, are put in it again; a program that has more is made again, which costs about what the put of that many does.
local PUT_AT_MOST <const> = 12

--- Makes the session's program agree with what is served now ([`source.key`]): each module served otherwise than it was is
--- put in it again ([`held.put`]), and a program that cannot (`dead` of [`held.Program`]) is made again at the next check. The
--- documents already checked are checked again where one moved ([`Checker`]'s `epoch`).
local function refresh_program(checker: Checker)
  local open = check.open_files(checker)
  local moved = 0
  for name, key in pairs(checker.served) do
    if source.key(checker.source, name, open) ~= key then moved = moved + 1 end
  end
  if moved == 0 then return end
  checker.epoch = checker.epoch + 1
  local program = checker.program
  if program == nil then
    checker.served = {}
    return
  end
  if moved > PUT_AT_MOST then
    program.dead = true
    return
  end
  -- Putting a module serves it, which sets the key of a name `served` has already: nothing is added to the table it walks.
  for name, key in pairs(checker.served) do
    if source.key(checker.source, name, open) ~= key then
      local focus = program.slot.focus
      if focus ~= nil and focus.module == name then
        checker.served[name] = source.key(checker.source, name, open)
      else
        local served = program.serve(name)
        if served == nil then
          program.dead = true
        else
          held.put(program, served)
        end
      end
    end
  end
end

--- What one check of a document found: what the checker and a build refuse of it, and the text and splices they are
--- positioned in.
local record Checked
  refusals: {plan.Refusal}
  --- The Teal checked, after the build's rewrite: a template's is the Teal it compiles to.
  text: string
  splices: {ShapeSpecs.Splice}
  --- Whether the places found are in a template's Teal, not in the
  --- document's own text.
  generated: boolean
end

--- What each other open document required at its last check, by name.
local function opened_requires(checker: Checker, document: Document): {string:{string}}
  local out: mut {string:{string}} = {}
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
  local names: mut {string} = {}
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

--- The options of the session's program: the declarations of the standard library the tool carries, and no ceiling, so that
--- every error of the checker refuses.
local function options_of(checker: Checker): Pipeline.Options
  local reused = checker.options
  if reused ~= nil then return reused end
  local made, trouble = Pipeline.alone()
  if made == nil then error(trouble, 0) end
  checker.options = made
  return made
end

--- What serves the session's program the module a `require` names, other than the document being checked: an open document's,
--- or the working database's ([`source.served`]), as the stub it serves, or the binary's own `cosmic.*` modules. The modules
--- the stage lists are never checked here: what a `require` reads is their type.
local function serve_of(checker: Checker): function(module: string): Driver.Source?
  local open = check.open_files(checker)
  local carried = Pipeline.carried()
  return function(module: string): Driver.Source?
    local listed = checker.source.modules[module]
    if listed == nil then
      local standard = carried(module)
      if standard == nil then checker.served[module] = "" end
      return standard
    end
    local found = source.served(checker.source, module, open)
    if found == nil then
      checker.served[module] = source.key(checker.source, module, open)
      return nil
    end
    checker.served[module] = found.key
    local dialect: Ast.Dialect = "tl"
    if listed.kind == "decl" then dialect = "decl" end
    return Driver.source(module, listed.file, found.text, dialect, listed.kind == "test")
  end
end

--- Whether the program stands for the module `path` in place of a file the stage lists: the document it checked last is none
--- the stage lists, so nothing serves it once another is checked, and a `require` of it must not find it.
local function left_unlisted(checker: Checker, program: held.Program, path: string): boolean
  local focus = program.slot.focus
  return focus ~= nil and focus.module ~= path and checker.source.modules[focus.module] == nil
end

--- The session's program, made at the first check and again where it lost a module (`dead` of [`held.Program`]): the
--- modules served are then served again. `path` is the module of the document to be checked.
local function program_of(checker: Checker, path: string): held.Program
  local program = checker.program
  if program ~= nil and (program.dead or left_unlisted(checker, program, path)) then
    program = nil
    checker.served = {}
    checker.epoch = checker.epoch + 1
  end
  if program == nil then
    program = held.new(options_of(checker), serve_of(checker))
    checker.program = program
  end
  return program
end

--- Checks `document` in the session's program ([`program_of`]), as a build checks it.
local function checked_of(checker: Checker, document: Document): Checked
  local none: {ShapeSpecs.Splice} = {}
  local generated = document.name:match("%.tmpl$") ~= nil
  local text = document.text
  if generated then
    local compiled, trouble = Template.compile(document.text, document.name, { dialects = nil, new_grammar = true })
    if compiled == nil then
      return { refusals = { plan.refusal_of(trouble) }, text = text, splices = none, generated = false }
    end
    text = compiled
  end
  --- What was found, its places in `spliced` as spliced by `splices`.
  local function checked(refusals: {plan.Refusal}, spliced: string, splices: {ShapeSpecs.Splice}): Checked
    return { refusals = refusals, text = spliced, splices = splices, generated = generated }
  end
  local named = plan.named(document.name)
  local path, kind = named.path, named.kind
  local listed = source.module(checker.source, document.name)
  if listed ~= nil then path, kind = listed.path, listed.kind end
  local own_tree = source.own_tree(checker.source)
  local planned = syntax_read.plan_of(document.name, text, path, kind, own_tree, generated)
  remember(checker, document, planned.requires)
  local refusals = planned.refusals
  local subject = planned.plan
  if planned.halted and subject == nil then return checked(refusals, text, none) end
  -- A build checks where every module's requires reach before it checks
  -- any, a declaration's aside ([`plans.collect`]), and stops there.
  if subject ~= nil and kind ~= "decl" then
    local placed = graph.refusals(checker.source, document.name, path, kind, planned.requires,
      opened_requires(checker, document))
    if #placed > 0 then return checked(placed, text, none) end
  end
  if planned.halted then return checked(refusals, text, none) end
  -- A text that does not parse halts the plan, so there is one here.
  local program = program_of(checker, path)
  local dialect: Ast.Dialect = "tl"
  if document.name:match("%.d%.tl$") ~= nil then dialect = "decl" end
  local given = Driver.source(path, document.name, text, dialect, kind == "test")
  if held.document(program, given) == nil then
    -- The program lost the module of the document before this one: a new program reads nothing it held.
    program = program_of(checker, path)
    assert(held.document(program, given), "the checker's program has no module " .. path)
  end
  local tally = checker.source.tally
  local resolution = syntax_read.splices(program.build, document.name, text, path, function()
    tally.whole_splices = tally.whole_splices + 1
  end)
  if resolution.refusal ~= "" then
    local refused = plan.refusal_of(resolution.refusal)
    refusals[#refusals + 1] = { line = resolution.line, column = refused.column, message = refused.message }
    return checked(refusals, text, none)
  end
  local splices = resolution.splices
  local spliced = syntax_read.applied(text, splices)
  if #splices > 0 then held.respell(program, spliced) end
  local reading = held.built(program, document.name, spliced, path, kind == "test")
  local compiled = syntax_read.generated(assert(subject), reading, importer_hints(checker), planned.requires,
    function(name: string): boolean return checker.source.modules[name] ~= nil end)
  for _, refusal in ipairs(compiled.refusals) do refusals[#refusals + 1] = refusal end
  return checked(refusals, spliced, splices)
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
  local outside = source.outside(checker.source)
  source.refresh(checker.source)
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
  refresh_program(checker)
  checker.checks[document.name] = (checker.checks[document.name] or 0) + 1
  local published = document.published
  if published ~= nil and document.published_text == document.text and
      document.published_epoch == checker.epoch then
    return published
  end
  local ok, outcome = pcall(checked_of, checker, document)
  if not ok then error(tostring(outcome), 0) end
  local checked: Checked = outcome
  local text_lines = lines.lines_of(document.text)
  local starts = lines.checker_starts(checked.text)
  local out: {string} = {}
  --- The diagnostic `message` at the checker's line `y` and column `x`.
  local function add(y: integer, x: integer, message: string, code: string?)
    local line = math.min(math.max(y, 1), #starts)
    local at = math.min(assert(starts[line]) + math.max(x, 1) - 1, #checked.text + 1)
    local offset = syntax_read.unspliced(checked.splices, at)
    -- A place in a template's Teal is none in the template.
    if checked.generated then offset = 1 end
    local word = document.text:match("^[%w_]+", offset) or ""
    local diagnostic: protocol.Diagnostic = {
      range = protocol.range(lines.position(text_lines, offset, encoding),
        lines.position(text_lines, offset + math.max(#word, 1), encoding)),
      -- A build refuses a warning as it does an error.
      severity = 1,
      source = "cosmic",
      message = message,
      code = code,
    }
    out[#out + 1] = assert(Json.encode_any(diagnostic))
  end
  for _, refusal in ipairs(checked.refusals) do
    add(refusal.line, refusal.column, refusal.message, refusal.code)
  end
  document.published = out
  document.published_text = document.text
  document.published_epoch = checker.epoch
  return out
end

return check
