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
--- with none of the modules it reads, its own listing or the hints moved since ([`Basis`]), publishes what it published then,
--- and answers the questions asked of its types from the result of that check ([`check.read`]), kept in memory for the few
--- documents asked of last ([`KEPT_AT_MOST`]): it depends on the editor's unsaved text, which the working database does
--- not hold. A text being typed does not parse: completion reads the last text of the document that did
--- ([`check.last`]).

local Ast = require("lang.ast")
local Declarations = require("lang.declarations")
local Driver = require("build.driver")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Node = require("build.syntax_node")
local Pipeline = require("build.pipeline")
local ShapeSpecs = require("build.syntax_shape_specs")
local Sqlite = require("cosmic.sqlite")
local Template = require("cosmic.template")
local TreeProgram = require("build.tree_program")
local analysis_schema = require("build.analysis_schema")
local graph = require("build.lsp.graph")
local held = require("build.lsp.held")
local hover = require("build.lsp.hover")
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
    --- What it last published, each diagnostic encoded, and what that was of ([`Basis`]): it is published again, and not
    --- checked again, while the basis stands, whether or not the result of the check is still kept.
    mut published: {string}?
    mut published_basis: Basis?
    --- What its text required at its last check, nil before one.
    mut requires: {string}?
    --- What its text requires now, read of the text itself for the modules a check of another document reads
    --- ([`reads_of`]), and the hash of the text it was read of.
    mut scanned: {string}?
    mut scanned_hash: string?
    --- The result of its last check, for the questions asked of its types ([`check.read`]), while its [`Basis`] stands.
    --- It is the session's and not the working database's, since the text is the editor's and not a staged file's. Only
    --- the documents most recently asked of keep one ([`KEPT_AT_MOST`]).
    mut kept: Kept?
    --- The last check of it whose text parsed, kept as `kept` is: a text being typed often does not parse, and completion
    --- reads what the text was before ([`check.last`]).
    mut parsed: Kept?
    --- Whether it is a probe ([`check.probe`]): a check made of it is counted toward no document's kept result.
    mut probe?: boolean
  end

  --- What a check of a document was of: the result stands while every part of it is as it was. It holds no more than the
  --- names of the modules read and a digest of their keys, so that a document keeps one for what it published whether or
  --- not its result is kept.
  record Basis
    text: string
    --- The checker's `epoch` ([`Checker`]), which stands for what the modules served do not: the imports of the open
    --- documents, and the program made again.
    epoch: integer
    --- What the stage lists the document as, and whether the tree is cosmic's own ([`listing_of`]).
    listing: string
    --- The databases a message's hint looks a name up in ([`hints_key`]).
    hints: string
    --- The names of the modules the document reads, sorted: the modules it requires and those they require, in turn
    --- ([`reads_of`]).
    reads: {string}
    --- The SHA-256 of the key ([`source.key`]) of each of `reads`, in order ([`digest_of`]).
    digest: string
  end

  --- What a document's check found, and what it was of.
  record Kept
    basis: Basis
    checked: Checked
  end

  --- What one check of a document found: what the checker and a build refuse of it, and the text and splices they are
  --- positioned in.
  record Checked
    refusals: {plan.Refusal}
    --- The Teal checked, after the build's rewrite: a template's is the Teal it compiles to.
    text: string
    splices: {ShapeSpecs.Splice}
    --- Whether the places found are in a template's Teal, not in the
    --- document's own text.
    generated: boolean
    --- The program's result for the module, with the types of its nodes: nil where nothing was checked.
    outcome: Driver.Outcome?
    --- The program the outcome is of: a later check in the session begins another ([`Driver.Build.replace`]), and the
    --- declarations the outcome's types name (a type's statics, its store) are in the one it was made in. Nil with `outcome`.
    program: Declarations.Program?
  end

  --- What one check of a document read, for the questions asked of the types of its nodes ([`build.lsp.definition`],
  --- [`build.lsp.completion`]).
  record Reading
    --- The program's result for the document's module: its tree, scopes and the type of each node. It is the document's
    --- ([`Document`]'s `kept`), and outlives the check of another document.
    outcome: Driver.Outcome
    --- What a build put in the document's text before the checker read it (the `text` of the outcome), the last first
    --- ([`ShapeSpecs.Splice`]).
    splices: {ShapeSpecs.Splice}
    --- The program the outcome is of ([`Checked`]'s `program`).
    program: Declarations.Program
  end

  --- The reading [`check.last`] answers, and the text of the document it was of.
  record Last
    reading: Reading
    text: string
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
    --- How many times what the modules served cannot say moved: an open document's imports (a cycle of imports through
    --- another open document may have closed or opened), the stage found a project, the program made again. A kept
    --- result is also keyed by the modules it reads ([`Basis`]'s `reads`), so that a module it does not read moves
    --- nothing of it.
    mut epoch: integer
    --- Whether the stage last staged nothing ([`source.refused`]), which moves `epoch` when it changes, so that a publish kept
    --- for a document of a refused pair is made again.
    mut refused: boolean
    --- The documents with a kept result, the least recently asked first ([`KEPT_AT_MOST`]).
    recent: mut {Document}
    --- The open documents, by name.
    open: mut {string:Document}
    --- The document the last probe was made by, kept so that a probe of the same text is answered from its kept result.
    mut probed: Document?
    --- The databases a message's hint looks a name up in.
    hints: function(): Hinted
    --- Whether a check found a document requiring other modules than
    --- before, since [`check.moved`] last asked: a cycle of imports
    --- through another open document may have closed or opened.
    mut graph_moved: boolean
    --- How many times each document was checked, by name, those
    --- answered from its last check among them: what a test reads.
    checks: mut {string:integer}
    --- How many times each document was checked for real, by name: the checks [`Checker`]'s `checks` counts that were
    --- not answered from a kept result ([`Document`]'s `kept`). What a test reads.
    ran: mut {string:integer}
  end
end

local type Checker = check.Checker
local type Document = check.Document
local type Checked = check.Checked
local type Basis = check.Basis

--- The hints of `checker` as the importer asks for them.
local function importer_hints(checker: Checker): importer.Hints
  return function(): {Sqlite.Handle}, {boolean}
    local hinted = checker.hints()
    return hinted.databases, hinted.public
  end
end

--- A checker of the tree at `root`, made ready on its first check.
function check.new(root: string, err: function(line: string), hints: function(): check.Hinted,
                   carried?: string, store?: {Sqlite.Handle}): Checker
  local view = source.new(root, err, carried, store)
  return {
    root = root,
    source = view,
    options = nil,
    program = nil,
    served = {},
    epoch = 0,
    refused = false,
    recent = {},
    probed = nil,
    open = {},
    hints = hints,
    graph_moved = false,
    checks = {},
    ran = {},
  }
end

--- A document of `text` at `uri`, named `name`, which is no file below
--- the root where `outside`.
function check.document(uri: string, name: string, text: string, outside?: boolean): Document
  return { uri = uri, text = text, name = name, outside = outside == true, hash = nil, published = nil,
    published_basis = nil, requires = nil, scanned = nil, scanned_hash = nil, kept = nil, parsed = nil }
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

--- The most documents that keep the result of their check at once: the documents asked of least recently drop theirs ([`bounded`]).
--- Each holds the whole [`Declarations.Program`] of its check, two where the text last asked of does not parse. A larger cap
--- holds more programs for every session; a smaller one checks again the documents a person returns to, which a sweep of more
--- open documents than the cap does for all of them. A document dropped publishes what it published where nothing it read
--- moved ([`Document`]'s `published_basis`), so only a question about its types checks it again. A document whose current text
--- has no result (it does not parse, or a build refuses it before it checks it) keeps its `parsed` (completion reads it,
--- [`check.last`]), so the bound is the cap and the open documents with no result.
local KEPT_AT_MOST <const> = 8

--- Lets go of the result kept for `document`, and of its place among the most recently asked. Where `closing` it lets go of
--- the last that parsed too, which otherwise stays while the current text does not parse.
local function forget(checker: Checker, document: Document, closing: boolean)
  local kept = document.kept
  local typing = kept ~= nil and kept.checked.outcome == nil
  document.kept = nil
  if closing or not typing then document.parsed = nil end
  for n, other in ipairs(checker.recent) do
    if other == document then
      table.remove(checker.recent, n)
      return
    end
  end
end

--- Makes `document` the document most recently asked of, and drops the results kept for the one asked of least recently
--- while more than [`KEPT_AT_MOST`] documents keep one.
local function bounded(checker: Checker, document: Document)
  -- A probe takes no place from the documents the person has open.
  if document.probe == true then return end
  for n, other in ipairs(checker.recent) do
    if other == document then
      table.remove(checker.recent, n)
      break
    end
  end
  table.insert(checker.recent, document)
  while #checker.recent > KEPT_AT_MOST do forget(checker, assert(checker.recent[1]), false) end
end

--- Makes `document` one a `require` no longer reads. Where it stood for
--- its file with another text than the stage's, the modules served are
--- dropped at the next check ([`source.refresh`]); its dependents are checked
--- again where what it serves changed ([`build.lsp.dependents`]). Where
--- it required other modules than the stage's, a cycle of imports may
--- have closed or opened: every other open document is to be checked
--- again ([`check.moved`]).
function check.closed(checker: Checker, document: Document)
  forget(checker, document, true)
  -- The probe made for the document goes with it.
  local probed = checker.probed
  if probed ~= nil and probed.name == document.name then checker.probed = nil end
  if checker.open[document.name] ~= document then return end
  local regraphs = check.regraphs(checker, document)
  checker.open[document.name] = nil
  source.release(checker.source, document.name)
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
  checker.probed = nil
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
--- documents already checked are checked again where a module they read moved ([`Basis`]'s `reads`).
local function refresh_program(checker: Checker)
  local open = check.open_files(checker)
  local moved = 0
  for name, key in pairs(checker.served) do
    if source.key(checker.source, name, open) ~= key then moved = moved + 1 end
  end
  if moved == 0 then return end
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

--- What each other open document required at its last check, by name.
local function opened_requires(checker: Checker, document: Document): {string:{string}}
  local out: mut {string:{string}} = {}
  for name, other in pairs(checker.open) do
    local requires = other.requires
    if other ~= document and requires ~= nil then out[name] = requires end
  end
  return out
end

--- Keeps what `document` requires now, and says the graph moved
--- where that is not what it required before: at its last check, or, at
--- its first, as staged. What it requires is read of the rows of its text ([`source.requires_of`]) where it `derivable`
--- (its text parses and is no template's Teal), else is the names of the `sites` the check read.
local function remember(checker: Checker, document: Document, sites: {plan.Site}, derivable: boolean)
  local names: {string} = {}
  local listed = source.module(checker.source, document.name)
  local rows: {string}? = nil
  if listed ~= nil and derivable then
    rows = source.requires_of(checker.source, listed, document.text, hash_of(document))
  end
  if rows ~= nil then
    names = rows
  else
    local read: mut {string} = {}
    for _, site in ipairs(sites) do read[#read + 1] = site.name end
    names = read
  end
  local before: {string} = {}
  local had = document.requires
  if had ~= nil then
    before = had
  elseif listed ~= nil then
    before = checker.source.requires[listed.source_hash] or before
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
  -- A project file named for a module of the language is never what a `require` of it reads, as in a build ([`Driver.reserved`]).
  local library = TreeProgram.library_modules(options_of(checker).globals)
  return function(module: string): Driver.Source?
    local listed = checker.source.modules[module]
    if listed == nil or library[module] == true then
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
    if analysis_schema.is_declaration(listed.kind) then dialect = "decl" end
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
    local compiled, trouble = Template.compile(document.text, document.name, { dialects = nil })
    if compiled == nil then
      return { refusals = { plan.refusal_of(trouble) }, text = text, splices = none, generated = false,
        outcome = nil, program = nil }
    end
    text = compiled
  end
  --- What was found, its places in `spliced` as spliced by `splices`.
  local function checked(refusals: {plan.Refusal}, spliced: string, splices: {ShapeSpecs.Splice},
                         outcome?: Driver.Outcome, declarations?: Declarations.Program): Checked
    return { refusals = refusals, text = spliced, splices = splices, generated = generated, outcome = outcome,
      program = declarations }
  end
  -- A file of a pair the stage refused is told so at its first line, whatever else it holds.
  local pair_refusal = source.refusal(checker.source, document.name)
  if pair_refusal ~= nil then return checked({ plan.refusal_of(pair_refusal) }, text, none) end
  local named = plan.named(document.name)
  local path, kind = named.path, named.kind
  local listed = source.module(checker.source, document.name)
  if listed ~= nil then path, kind = listed.path, listed.kind end
  local own_tree = source.standing(checker.source).own
  local planned = syntax_read.plan_of(document.name, text, path, kind, own_tree, generated)
  remember(checker, document, planned.requires, planned.parsed and not generated)
  local refusals = planned.refusals
  local subject = planned.plan
  if planned.halted and subject == nil then return checked(refusals, text, none) end
  -- A build checks where every module's requires reach before it checks
  -- any, a declaration's aside ([`plans.collect`]), and stops there.
  if subject ~= nil and not analysis_schema.is_declaration(kind) then
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
  return checked(refusals, spliced, splices, program.build:result(path, true), program.build.program)
end

--- What the stage lists `document` as, and whether the tree is cosmic's own: what a check reads of the document's own file
--- besides its text. "" for a file the stage lists none of.
local function listing_of(checker: Checker, document: Document): string
  local listed = source.module(checker.source, document.name)
  local own = if source.standing(checker.source).own then "own" else "other" end
  if listed == nil then return own end
  return table.concat({ own, listed.path, listed.kind, listed.file }, "\0")
end

--- The databases a message's hint looks a name up in now ([`importer_hints`]), by identity and by the version each handle reads
--- ([`hover.version`]): a restage that opens them again changes the first, a database written in place under the same
--- handle the second.
local function hints_key(checker: Checker): string
  local hinted = checker.hints()
  local parts: mut {string} = {}
  for n, handle in ipairs(hinted.databases) do
    parts[#parts + 1] = tostring(handle) .. (if hinted.public[n] == true then "+" else "-" end) .. hover.version(handle)
  end
  return table.concat(parts, "\0")
end

--- The modules the open document `other` requires now, of its text: not those of its last check, which a text edited since
--- has not moved. A template is read as the Teal it compiles to. A text that does not parse requires none, and its key
--- moves when it does.
local function requires_of_open(other: Document): {string}
  local hash = hash_of(other)
  local scanned = other.scanned
  if scanned ~= nil and other.scanned_hash == hash then return scanned end
  local text = other.text
  if other.name:match("%.tmpl$") ~= nil then
    local compiled, _ = Template.compile(text, other.name, { dialects = nil })
    text = compiled or ""
  end
  local names: mut {string} = {}
  local chunk, _ = Node.parse(text, other.name)
  if chunk ~= nil then
    for _, site in ipairs(Node.require_sites(chunk)) do names[#names + 1] = site.name end
  end
  other.scanned, other.scanned_hash = names, hash
  return names
end

--- The names of the modules `document` reads, sorted: the modules it requires now and those they require, as an open document's
--- text or the stage has them ([`requires_of_open`]). A module the program already held is not served again, so the modules
--- served in a check are no account of what the check read.
local function reads_of(checker: Checker, document: Document): {string}
  local reads: mut {string:boolean} = {}
  local pending: mut {string} = {}
  for _, name in ipairs(document.requires or {}) do pending[#pending + 1] = name end
  while #pending > 0 do
    local name = assert(table.remove(pending))
    if reads[name] == nil then
      reads[name] = true
      local listed = checker.source.modules[name]
      if listed ~= nil then
        local opened = checker.open[listed.file]
        local requires: {string}? = nil
        if opened ~= nil then requires = requires_of_open(opened) end
        for _, further in ipairs(requires or checker.source.requires[listed.source_hash] or {}) do
          pending[#pending + 1] = further
        end
      end
    end
  end
  local names: mut {string} = {}
  for name in pairs(reads) do names[#names + 1] = name end
  table.sort(names)
  return names
end

--- The digest of the key ([`source.key`]) of each of `names` now, "" for a name no module is found for.
local function digest_of(checker: Checker, names: {string}): string
  local open = check.open_files(checker)
  local keys: mut {string} = {}
  for _, name in ipairs(names) do keys[#keys + 1] = source.key(checker.source, name, open) end
  return Hash.hex_sha256(table.concat(keys, "\1"))
end

--- What the check of `document` just made was of. `hints` is the hints key ([`hints_key`]) read before the check: a docs
--- database committed to during the check is then seen as moved by the next ask, not recorded as already read.
--- TODO: read `reads` and `digest` before the check as well, once the requires a check finds can be known before it runs:
--- a module's file written between the check's read and this call is recorded as already seen.
local function basis_of(checker: Checker, document: Document, hints: string): Basis
  local reads = reads_of(checker, document)
  return { text = document.text, epoch = checker.epoch, listing = listing_of(checker, document),
    hints = hints, reads = reads, digest = digest_of(checker, reads) }
end

--- Whether a check of `document` that was of `basis` would find what it found: nothing it was of moved.
local function stands(checker: Checker, document: Document, basis: Basis): boolean
  if basis.text ~= document.text or basis.epoch ~= checker.epoch then return false end
  if basis.listing ~= listing_of(checker, document) or basis.hints ~= hints_key(checker) then
    return false
  end
  return basis.digest == digest_of(checker, basis.reads)
end

--- The check of `document` as it stands: the one kept from the last, where what it was of stands ([`stands`]), else a check
--- made now and kept. A text that does not parse is kept as well, its outcome nil. The document becomes the one most
--- recently asked of ([`bounded`]).
local function checked_now(checker: Checker, document: Document): Checked
  local kept = document.kept
  if kept ~= nil and stands(checker, document, kept.basis) then
    bounded(checker, document)
    return kept.checked
  end
  checker.ran[document.name] = (checker.ran[document.name] or 0) + 1
  local hints = hints_key(checker)
  local checked = checked_of(checker, document)
  -- The basis after the check, which may move the epoch (`remember`, [`program_of`]): the next ask is of the same program.
  document.kept = { basis = basis_of(checker, document, hints), checked = checked }
  if checked.outcome ~= nil and not checked.generated then document.parsed = document.kept end
  bounded(checker, document)
  return checked
end

--- Whether the file `name` is in a tree of its own inside cosmic's
--- ([`identity.is_foreign_tree`]), which a build of it never reads.
local function apart(checker: Checker, name: string): boolean
  return source.standing(checker.source).own and identity.is_foreign_tree(identity.first_of(name))
end

--- Brings the stage up to the files on disk, and answers whether `document` is checked against it: false in a root no build
--- was started in and for a file in a tree of its own. A build started where there was none moves every open document, which
--- is checked again against the modules now found; the check that finds it says so, and no other need.
local function staged(checker: Checker, document: Document): boolean
  local outside = source.outside(checker.source)
  source.refresh(checker.source)
  local refused = source.refused(checker.source)
  if refused ~= checker.refused then
    checker.refused = refused
    checker.epoch = checker.epoch + 1
  end
  if source.outside(checker.source) or apart(checker, document.name) then return false end
  if outside then
    checker.graph_moved = true
    checker.epoch = checker.epoch + 1
  end
  return true
end

--- The diagnostics of `document`, each encoded, its positions counted in
--- `encoding`'s units.
function check.diagnose(checker: Checker, document: Document, encoding: string): {string}
  local none: {string} = {}
  if unread(document) then
    document.published = none
    return none
  end
  if not staged(checker, document) then
    document.published = none
    return none
  end
  refresh_program(checker)
  checker.checks[document.name] = (checker.checks[document.name] or 0) + 1
  local published = document.published
  local basis = document.published_basis
  if published ~= nil and basis ~= nil and stands(checker, document, basis) then
    return published
  end
  local checked = checked_now(checker, document)
  local text_lines = lines.lines_of(document.text)
  local starts = lines.checker_starts(checked.text)
  local out: mut {string} = {}
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
    table.insert(out, (assert(Json.encode_any(diagnostic))))
  end
  for _, refusal in ipairs(checked.refusals) do
    add(refusal.line, refusal.column, refusal.message, refusal.code)
  end
  document.published = out
  document.published_basis = assert(document.kept).basis
  return out
end

--- What the check of `document` read of it ([`check.diagnose`] checks it, and the last check is read where the text and the
--- program are those it was of), or nil where nothing was: a file no build reads, a root with no build, a template (whose
--- places are in its Teal), a text that does not parse or whose `require`s are refused. The result outlives the check of
--- another document: a replacement in the program ([`Driver.Build.replace`]) begins another and leaves an outcome
--- answered before as it was.
function check.read(checker: Checker, document: Document): check.Reading?
  if unread(document) or document.name:match("%.tmpl$") ~= nil then return nil end
  if not staged(checker, document) then return nil end
  refresh_program(checker)
  local checked = checked_now(checker, document)
  local found = checked.outcome
  local declarations = checked.program
  if found == nil or declarations == nil or checked.generated then return nil end
  return { outcome = found, splices = checked.splices, program = declarations }
end

--- What completion reads of `document`: the reading of its text ([`check.read`]), else, where the text does not parse (it
--- is being typed), the reading of the last text that did, with that text so that a place in the one is found in the other.
--- That reading may be of a program older than the present one: its types are what the person last saw. nil where there is
--- none.
function check.last(checker: Checker, document: Document): check.Last?
  local current = check.read(checker, document)
  if current ~= nil then return { reading = current, text = document.text } end
  local parsed = document.parsed
  if parsed == nil then return nil end
  local outcome, declarations = parsed.checked.outcome, parsed.checked.program
  if outcome == nil or declarations == nil then return nil end
  return { reading = { outcome = outcome, splices = parsed.checked.splices, program = declarations },
    text = parsed.basis.text }
end

--- What completion reads of `document` when its text does not parse (it is being typed): the reading of `text`, the text of the
--- document with what is needed to parse it (a name where the word is being typed, a statement made of a receiver), checked
--- as it would be if the person had typed it. nil where that is no text a build reads or its check read nothing. The check is
--- made by a document of its own that nothing opens, so that what the document last published and what it kept stand, and that
--- takes no place of a document's kept result ([`bounded`]); the last is kept, so that a probe of the same text, as an
--- editor asks again for each key typed or for an item's documentation, is answered from its result. It counts as no check
--- of the document, and the program reads the document's text again at the next real check
--- ([`held.document`]).
function check.probe(checker: Checker, document: Document, text: string): check.Reading?
  local probe = checker.probed
  if probe == nil or probe.name ~= document.name or probe.text ~= text then
    probe = check.document(document.uri, document.name, text, document.outside)
    probe.probe = true
    checker.probed = probe
  end
  probe.requires = document.requires
  local checks, ran = checker.checks[document.name], checker.ran[document.name]
  local reading = check.read(checker, probe)
  if checks == nil then
    checker.checks[document.name] = nil
  else
    checker.checks[document.name] = checks
  end
  if ran == nil then checker.ran[document.name] = nil else checker.ran[document.name] = ran end
  return reading
end

--- The SHA-256 of the text of `document`.
function check.hash(document: Document): string
  return hash_of(document)
end

--- The byte `offset` (from 1) of the text the reading was of, as the checker's text has it: a build put text in the one
--- the person has before the checker read it, which moves the bytes after it ([`Reading`]'s `splices`).
function check.checker_offset(reading: check.Reading, offset: integer): integer
  local moved = offset
  for _, splice in ipairs(reading.splices) do
    if splice.at < offset then moved = moved + #splice.text end
  end
  return moved
end

return check
