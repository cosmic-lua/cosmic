--- How `cosmic lsp` ([`build.lsp`]) checks a document: as a build checks
--- the module it is, in memory, as the editor holds it, and what it then
--- publishes.
---
--- What it publishes: the checker's syntax and type errors and its
--- warnings, which a build refuses as it refuses errors, each worded as a
--- build words it ([`importer.said`]), and what else a build refuses of a
--- module: a `global`, a test that returns a value, an example that
--- returns none, a [`Test.policy`] outside a test, and in cosmic's own
--- tree its contracts and its stub ([`compilation.generate`]).
---
--- The text is checked after the rewrite a build makes of it first
--- ([`build.shape_specs`]), so a column is the document's own. A `require`
--- is answered from an open document, then the working database
--- ([`build.lsp.source`]), then the binary's own `cosmic.*` modules.
---
--- A module served stays checked between checks, its type in the
--- checker's `modules`, until what it would be served from changes: an
--- open document's text, or the stage. Then every module served is
--- checked again, since one that requires the changed one may change
--- with it. A document whose text has not changed since its last check,
--- with no module served dropped since, publishes what it published then.

local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local ast = require("build.ast")
local compilation = require("build.compilation")
local importer = require("build.importer")
local plan = require("build.lsp.plan")
local protocol = require("build.lsp.protocol")
local receivers = require("build.receivers")
local shape_specs = require("build.shape_specs")
local source = require("build.lsp.source")
local stub = require("build.stub")
local teal = require("build.teal")
local tree = require("build.tree")
local type compiler = require("build.compiler")
local type build_module = require("build.module")

local record check
  --- A document the editor holds open.
  record Document
    uri: string
    text: string
    --- The name the checker knows it by: its path below the root, or its
    --- absolute path when it is not below it.
    name: string
    --- The SHA-256 of `text`, once asked for.
    hash: string | nil
    --- What it last published, each diagnostic encoded, and the text and
    --- the checker's [`Checker`] `epoch` it was of.
    published: {string} | nil
    published_text: string
    published_epoch: integer
  end

  --- One session's checker.
  record Checker
    root: string
    source: source.View
    built: compiler | nil
    env: compiler.Env | nil
    --- The types the checker reports of the document it checks, which
    --- [`build.contracts`] reads.
    typed: receivers.State | nil
    --- Whether the root is cosmic's own tree, which a build holds to its
    --- contracts and its stubs as well.
    own_tree: boolean
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
  end
end

local type Checker = check.Checker
local type Document = check.Document

--- A checker of the tree at `root`, made ready on its first check.
function check.new(root: string, err: function(line: string), hints: importer.Hints): Checker
  return {
    root = root,
    source = source.new(root, err),
    built = nil,
    env = nil,
    typed = nil,
    own_tree = false,
    base_globals = {},
    served = {},
    epoch = 0,
    open = {},
    hints = hints,
  }
end

--- A document of `text` at `uri`, named `name`.
function check.document(uri: string, name: string, text: string): Document
  return { uri = uri, text = text, name = name, hash = nil, published = nil, published_text = "",
    published_epoch = 0 }
end

--- Gives `document` the text `text`.
function check.set_text(document: Document, text: string)
  document.text = text
  document.hash = nil
end

--- Makes `document` one a `require` reads, or one it no longer does.
function check.opened(checker: Checker, document: Document)
  checker.open[document.name] = document
end

function check.closed(checker: Checker, document: Document)
  if checker.open[document.name] == document then checker.open[document.name] = nil end
end

--- Stages the tree again before the next check: files changed on disk.
function check.stale(checker: Checker)
  source.stale(checker.source)
end

--- Lets go of what the checker holds open.
function check.close(checker: Checker)
  source.close(checker.source)
end

--- The open documents as [`source.Open`] reads them.
local function open_of(checker: Checker): source.Open
  return function(file: string): source.Text | nil
    local document = checker.open[file]
    if document == nil then return nil end
    local hash = document.hash
    if hash == nil then
      hash = Hash.hex_sha256(document.text)
      document.hash = hash
    end
    return { text = document.text, hash = hash }
  end
end

--- What the checker reads for a module: its text, then a close.
local record Handle
  text: string
  read: function(Handle, what: string): string
  close: function(Handle): boolean
end

local function handle_of(text: string): Handle
  return {
    text = text,
    read = function(self: Handle, _what: string): string return self.text end,
    close = function(_self: Handle): boolean return true end,
  }
end

--- `served` as a build rewrites it ([`shape_specs.resolve`]). A rewrite
--- that fails leaves the text as it is: the module's refusal is its own,
--- not the document's.
local function rewritten(checker: Checker, name: string, served: source.Served): string
  local built, env = checker.built, checker.env
  if built == nil or env == nil then return served.text end
  local ok, resolved, _ = pcall(shape_specs.resolve, built, env, served.file, name, served.text)
  if ok and resolved ~= nil then return resolved end
  return served.text
end

--- The checker and its environment, made on first use.
local function prepared(checker: Checker): compiler, compiler.Env
  local built, env = checker.built, checker.env
  if built ~= nil and env ~= nil then return built, env end
  local loaded = assert(teal.load())
  local open = open_of(checker)
  loaded.search_module = function(name: string, _search_all: boolean): string | nil, any
    local listed = checker.source.modules[name] ~= nil
    local found = source.served(checker.source, loaded, name, open)
    if found ~= nil then
      checker.served[name] = found.key
      return found.file, handle_of(rewritten(checker, name, found))
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
    return name:gsub("%.", "/") .. ".tl", handle_of(standard.text)
  end
  local made, env_trouble = loaded.new_env({
    defaults = { feat_lax = "off", gen_compat = "off", gen_target = "5.4" },
  })
  if made == nil then error(env_trouble, 0) end
  teal.strip(made)
  for name in pairs(made.globals) do checker.base_globals[name] = true end
  checker.typed = receivers.install(made)
  local own, _ = tree.is_own(checker.root)
  checker.own_tree = own == true
  checker.built, checker.env = loaded, made
  return loaded, made
end

--- The checker, made on first use.
function check.compiler(checker: Checker): compiler
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
local function refresh(checker: Checker, env: compiler.Env)
  local stale = false
  for name in pairs(env.globals) do
    if checker.base_globals[name] ~= true then
      env.globals[name] = nil
      stale = true
    end
  end
  local open = open_of(checker)
  for name, key in pairs(checker.served) do
    if stale then break end
    if source.key(checker.source, name, open) ~= key then stale = true end
  end
  if not stale then return end
  for name in pairs(checker.served) do
    env.modules[name] = nil
    env.module_filenames[name] = nil
  end
  checker.served = {}
  checker.epoch = checker.epoch + 1
end

--- `splices`, found in `from`, moved to the same lines and columns of
--- `text`, which holds every token of `from` where `from` has it (a stub
--- of it, [`stub.made`]); nil where a splice does not follow the same
--- token in both.
local function moved(from: string, text: string, splices: {shape_specs.Splice}): {shape_specs.Splice} | nil
  local from_starts, starts = protocol.checker_starts(from), protocol.checker_starts(text)
  local out: {shape_specs.Splice} = {}
  for _, splice in ipairs(splices) do
    local line = 1
    while from_starts[line + 1] ~= nil and from_starts[line + 1] <= splice.at do line = line + 1 end
    local start, from_start = starts[line], from_starts[line]
    if start == nil or from_start == nil then return nil end
    local at = start + (splice.at - from_start)
    local token = from:sub(from_start, splice.at):match("[^%s]*$")
    if text:sub(at - #token + 1, at) ~= token then return nil end
    out[#out + 1] = { at = at, text = splice.text }
  end
  return out
end

--- What [`shape_specs.splices`] finds of `document`, the module `path`.
--- Where every call to resolve is a top-level statement's, they are found
--- in the document with every function body left out, which the checker
--- reads in a fraction of the time and which declares the same records;
--- otherwise, or where that finds other calls, in the whole document.
local function splices_of(built: compiler, env: compiler.Env, document: Document,
                          path: string): shape_specs.Found
  local text = document.text
  local _, wanted = text:gsub("record_of%(", "")
  if wanted > 0 then
    local parsed, _ = ast.parse(built, text, document.name)
    if parsed ~= nil then
      local bodiless = stub.made(parsed, true).text
      local _, kept = bodiless:gsub("record_of%(", "")
      if kept == wanted then
        local found = shape_specs.splices(built, env, document.name, path, bodiless)
        if found.refusal == "" and #found.splices == wanted then
          local splices = moved(bodiless, text, found.splices)
          if splices ~= nil then return { splices = splices, refusal = "", line = 0 } end
        end
      end
    end
  end
  return shape_specs.splices(built, env, document.name, path, text)
end

--- What one check of a document found: the errors of the document
--- itself, and the text and splices they are positioned in.
local record Checked
  errors: {compiler.Error}
  --- What a build refuses beyond the checker's errors.
  refusals: {plan.Refusal}
  --- The text as checked, after the build's rewrite.
  text: string
  splices: {shape_specs.Splice}
  refused: {string:boolean}
end

--- The checker's reading of a text [`compilation.generate`] refused for
--- the checker's errors, which it hands its renderer.
local record Rendered
  result: compiler.Result | nil
end

--- Checks `document` in `env`, as a build checks it.
local function checked_of(checker: Checker, built: compiler, env: compiler.Env,
                          document: Document): Checked
  -- TODO: a build also refuses a `require` that reaches into a closed
  -- directory, or into build/ or a test in cosmic's own tree
  -- (build/positions.tl), which wants every module the root holds: it
  -- waits on build/positions.tl reading them from the working database,
  -- as the session does ([`source.View`]'s `modules`).
  local none: {shape_specs.Splice} = {}
  local found: {compiler.Error} = {}
  local named = plan.named(document.name)
  local path, kind = named.path, named.kind
  local listed = source.module(checker.source, document.name)
  if listed ~= nil then path, kind = listed.path, listed.kind end
  local planned = plan.of(built, document.name, document.text, path, kind, checker.own_tree)
  local refusals = planned.refusals
  if planned.halted then
    return { errors = found, refusals = refusals, text = document.text, splices = none, refused = {} }
  end
  local subject = planned.plan
  local resolution = splices_of(built, env, document, path)
  if resolution.refusal ~= "" then
    local refused = plan.refusal_of(resolution.refusal)
    refused.line = resolution.line
    refusals[#refusals + 1] = refused
    return { errors = found, refusals = refusals, text = document.text, splices = none, refused = {} }
  end
  local splices = resolution.splices
  local text = shape_specs.spliced(document.text, splices)
  local result: compiler.Result | nil = nil
  if subject == nil or subject.kind == "decl" then
    result = built.check_string(text, env, document.name, "tl")
  else
    -- Compiled as a build compiles it, which drops the warnings a build
    -- discounts and refuses what a build refuses beyond the checker's
    -- errors: in cosmic's own tree its stub and its contracts, and Lua's
    -- refusal of the code. The checker's reading of a text it refuses is
    -- what it hands the renderer. The type it records of the module is
    -- put back, whatever the compile does: an open document is read
    -- through `search_module`.
    local compiled: build_module.Plan = subject
    local rendered: Rendered = { result = nil }
    local kept = env.modules[compiled.path]
    local typed = assert(checker.typed)
    local function generated(): compilation.Generated | nil, string
      return compilation.generate(compiled, built, env, typed, checker.own_tree, true,
        function(_file: string, _source: string, seen: compiler.Result): string
          rendered.result = seen
          return ""
        end, text, true)
    end
    local ok, made, trouble = pcall(generated)
    env.modules[compiled.path] = kept
    if not ok then error(made, 0) end
    result = rendered.result
    if made == nil and result == nil then
      for _, refusal in ipairs(plan.refusals_of(trouble)) do refusals[#refusals + 1] = refusal end
    end
  end
  if result == nil then
    return { errors = found, refusals = refusals, text = text, splices = splices, refused = {} }
  end
  -- A text with a syntax error has no warnings, nor a list of them: the
  -- list of lists ends there.
  for _, group in ipairs({ result.syntax_errors, result.type_errors, result.warnings }) do
    for _, e in ipairs(group) do found[#found + 1] = e end
  end
  return { errors = found, refusals = refusals, text = text, splices = splices,
    refused = teal.refused_type_requires(document.name, document.text, result) }
end

--- The byte of the document's own text at byte `offset` of it as
--- spliced (`splices`, the last first, as [`shape_specs.splices`] answers
--- them). A byte a splice put in is the byte the splice follows.
local function unspliced(splices: {shape_specs.Splice}, offset: integer): integer
  local shift = 0
  for i = #splices, 1, -1 do
    local splice = splices[i]
    local first = splice.at + shift + 1
    if offset < first then break end
    if offset < first + #splice.text then return splice.at end
    shift = shift + #splice.text
  end
  return offset - shift
end

--- The diagnostics of `document`, each encoded, its positions counted in
--- `encoding`'s units.
function check.diagnose(checker: Checker, document: Document, encoding: string): {string}
  local built, env = prepared(checker)
  source.refresh(checker.source, built)
  refresh(checker, env)
  local published = document.published
  if published ~= nil and document.published_text == document.text and
      document.published_epoch == checker.epoch then
    return published
  end
  -- What the check adds to `loaded` is dropped after it, its results'
  -- trees with it: a module's type stays in `modules`, which is what a
  -- later check reads, and a text read again is checked again.
  local order = env.loaded_order
  local before = #order
  local ok, outcome = pcall(checked_of, checker, built, env, document)
  for i = #order, before + 1, -1 do
    local name = order[i]
    if name ~= nil then env.loaded[name] = nil end
    order[i] = nil
  end
  if not ok then error(tostring(outcome), 0) end
  local checked: Checked = outcome
  local lines = protocol.lines_of(document.text)
  local starts = protocol.checker_starts(checked.text)
  local out: {string} = {}
  --- The diagnostic `message` at the checker's line `y` and column `x`.
  local function add(y: integer, x: integer, message: string, code: string | nil)
    local line = math.min(math.max(y, 1), #starts)
    local at = math.min(starts[line] + math.max(x, 1) - 1, #checked.text + 1)
    local offset = unspliced(checked.splices, at)
    local word = document.text:match("^[%w_]+", offset) or ""
    local diagnostic: protocol.Diagnostic = {
      range = protocol.range(protocol.position(lines, offset, encoding),
        protocol.position(lines, offset + math.max(#word, 1), encoding)),
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
    add(e.y, e.x, importer.said(e, document.name, document.text, checked.refused, checker.hints), code)
  end
  document.published = out
  document.published_text = document.text
  document.published_epoch = checker.epoch
  return out
end

return check
