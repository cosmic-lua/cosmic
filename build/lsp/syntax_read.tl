--- What `cosmic lsp` ([`build.lsp.check`]) reads of a document: what a build refuses of a text before it checks it and the plan
--- it compiles it by, the stub a `require` of it reads, the key of what it serves its dependents, the rewrite a build makes of
--- it ([`build.syntax_shape_specs`]) and the pipeline's compile of it ([`build.pipeline`]). All of it is read off the new
--- checker's syntax tree.
local Ast = require("lang.ast")
local ErrorRender = require("build.error_render")
local Globals = require("build.syntax_globals")
local Lexer = require("lang.lexer")
local Node = require("build.syntax_node")
local Pipeline = require("build.pipeline")
local ShapeSpecs = require("build.syntax_shape_specs")
local Sqlite = require("cosmic.sqlite")
local SyntaxAnalyzer = require("build.syntax_analyzer")
local SyntaxStub = require("build.syntax_stub")
local plans = require("build.plans")
local plan = require("build.lsp.plan")
local type build_module = require("build.module")
local type Driver = require("build.driver")

local record syntax_read
end

local type Refusal = plan.Refusal
local type Planned = plan.Planned
local type Site = plan.Site

--- The line of the top-level `return` of `chunk`, or 0 where it has none: a statement that starts with the word.
local function return_line(chunk: Ast.Chunk): integer
  for _, statement in ipairs(chunk.body.stats) do
    local first = Node.base(statement).first
    if Lexer.text(chunk.tokens, first) == "return" and Lexer.kind(chunk.tokens, first) == "keyword" then
      return Lexer.y(chunk.tokens, first)
    end
  end
  return 0
end

--- The stub of `text`, the file `file`: "" for a text that does not parse or returns nothing at its top level, which has
--- none ([`build.derivation`]).
function syntax_read.stub_of(file: string, text: string): string
  local chunk, _ = Node.parse(text, file)
  if chunk == nil then return "" end
  if return_line(chunk) > 0 then return SyntaxStub.made(chunk).text end
  return ""
end

--- The tokens of `text`, the file `file`, each with its place, in order, as the key of what a module serves ([`build.lsp.dependents`]) is
--- made of: none of the comments or the whitespace between them.
function syntax_read.token_parts(text: string, file: string): {string}
  local parts: mut {string} = {}
  local tokens = Lexer.lex(text, file).tokens
  for k, kind in ipairs(tokens.kind) do
    if kind ~= "$EOF$" then
      parts[#parts + 1] = tostring(Lexer.y(tokens, k)) .. ":" .. tostring(Lexer.x(tokens, k)) .. " " .. Lexer.text(tokens, k)
    end
  end
  return parts
end

--- What [`ShapeSpecs.splices`] finds of `text`, the file `name`, the module `path`, which `build` holds as that text: the calls of
--- [`Shape.record_of`] are found in the whole text, which the new checker reads fast enough that a stub of it is not worth the
--- reading. `count` is called when the text has a call, to tell the session how many it found whole.
function syntax_read.splices(build: Driver.Build, name: string, text: string, path: string,
                             count: function()): ShapeSpecs.Found
  if text:find("record_of(", 1, true) ~= nil then count() end
  return ShapeSpecs.splices(build, path, name, text)
end

--- The byte of the document's own text at byte `offset` of it as spliced (`splices`, the last first, as
--- [`ShapeSpecs.splices`] answers them). A byte a splice put in is the byte the splice follows.
function syntax_read.unspliced(splices: {ShapeSpecs.Splice}, offset: integer): integer
  local shift = 0
  for i = #splices, 1, -1 do
    local one = assert(splices[i])
    local first = one.at + shift + 1
    if offset < first then break end
    if offset < first + #one.text then return one.at end
    shift = shift + #one.text
  end
  return offset - shift
end

--- What the modules `sites` (the `require`s of a document) name that the stage lists are refused for when the program lowers
--- them, the errors of reading their declarations (a type they name that is none): each at the `require` that reaches it, since
--- the module is not checked and its own errors show only where it is open. The fork checked the document against the
--- module's type and flagged the use. `listed` says which modules the stage lists: the binary's own are not looked at.
local function broken(pipeline: Pipeline.Built, sites: {Site}, listed: function(name: string): boolean): {Refusal}
  local out: mut {Refusal} = {}
  for _, site in ipairs(sites) do
    if listed(site.name) then
      pipeline.build:lower({ site.name })
      local outcome = pipeline.build:result(site.name, false)
      if outcome ~= nil then
        for _, problem in ipairs(outcome.errors) do
          out[#out + 1] = { line = site.line, column = site.column, message = site.name .. " is refused (" ..
              outcome.source.filename .. ":" .. tostring(problem.y) .. ":" .. tostring(problem.x) .. "): " ..
              problem.msg .. " (" .. problem.code .. "): " .. problem.fix }
        end
      end
    end
  end
  return out
end

--- `text` with each of `splices` put in, as [`ShapeSpecs.spliced`] does.
function syntax_read.applied(text: string, splices: {ShapeSpecs.Splice}): string
  return ShapeSpecs.spliced(text, splices)
end

--- What a build refuses of `text` before it checks it, and the plan it compiles it by: a `global`, an analysis it refuses (a
--- [`Test.policy`] it does not take), a policy outside a test, a test that returns a value or an example that returns none.
--- With `own_tree`, the plan of a standard-library module carries its stub, which cosmic's own build holds it to. A `generated`
--- text is a template's Teal, whose warnings a build discounts as it does a generated module's. A text the new checker does
--- not parse has no plan, and is refused with the parser's error, which stops the build there.
function syntax_read.plan_of(name: string, text: string, path: string, kind: string, own_tree: boolean,
                             generated: boolean): Planned
  local refusals: mut {Refusal} = {}
  local chunk, why = Node.parse(text, name)
  if chunk == nil then
    refusals[1] = plan.refusal_of(why)
    return { plan = nil, refusals = refusals, halted = true, requires = {} }
  end
  local requires: mut {Site} = {}
  for _, site in ipairs(Node.require_sites(chunk)) do
    requires[#requires + 1] = { name = site.name, line = site.y, column = site.x }
  end
  for _, place in ipairs(Globals.found(chunk)) do
    table.insert(refusals, plan.refusal_of(plans.global_refusal(name .. ":" ..
        tostring(place.line) .. ":" .. tostring(place.column))))
  end
  local analysis, trouble = SyntaxAnalyzer.analysis_of(chunk, Node.scope(chunk, name), text, name)
  if analysis == nil then
    table.insert(refusals, plan.refusal_of(trouble))
    return { plan = nil, refusals = refusals, halted = true, requires = requires }
  end
  local misplaced = plans.policy_refusal(name, kind, analysis.inputs)
  if misplaced ~= nil then
    table.insert(refusals, plan.refusal_of(misplaced))
    return { plan = nil, refusals = refusals, halted = true, requires = requires }
  end
  local tests: mut {string} = {}
  if kind == "test" then
    tests = analysis.tests
  elseif kind == "example" then
    for _, example in ipairs(analysis.examples) do tests[#tests + 1] = example.name end
  end
  local made: SyntaxStub.Made? = nil
  if own_tree and kind == "module" and path:sub(1, 7) == "cosmic." and analysis.has_top_level_return then
    made = SyntaxStub.made(chunk)
  end
  local made_plan: build_module.Plan = {
    path = path,
    file = name,
    kind = kind,
    source = text,
    source_hash = "",
    requires = {},
    tests = tests,
    inputs = analysis.inputs,
    has_top_level_return = analysis.has_top_level_return,
    generated = generated,
    key = nil,
    graph_key = nil,
    lua = nil,
    stub = made,
  }
  local refused = plans.refusal(made_plan)
  if refused ~= nil then
    local at = plan.refusal_of(refused)
    table.insert(refusals, { line = math.max(return_line(chunk), 1), column = at.column, message = at.message })
    return { plan = made_plan, refusals = refusals, halted = true, requires = requires }
  end
  return { plan = made_plan, refusals = refusals, halted = false, requires = requires }
end

--- Whether `line` counts the errors of a code ([`build.ceilings.over`]: `file: 2 errors of arity in its bodies; follow the fix
--- above`), which a list of the errors in an editor, each at its place, has no use for.
local function counts_errors(line: string): boolean
  return line:match("^[^:\n]*: %d+ errors? of [%a][%w_]* in its [%a ]+[;,]") ~= nil
end

--- The refusals of the lines `lines`, one each but for the lines that count errors ([`counts_errors`]).
local function refusals_of_lines(lines: {string}): {Refusal}
  local out: mut {Refusal} = {}
  for _, line in ipairs(lines) do
    if not counts_errors(line) then out[#out + 1] = plan.refusal_of(line) end
  end
  return out
end

--- The refusals of `trouble`, what [`Pipeline.review`] answers for a module it refuses: the header line it puts before the
--- checker's lines is dropped, and each line left is one refusal.
local function refusals_of_generated(trouble: string): {Refusal}
  local lines: mut {string} = {}
  for line in trouble:gmatch("[^\n]+") do
    if lines[1] ~= nil or line:match(": the compiler refused it$") == nil then
      lines[#lines + 1] = line
    end
  end
  return refusals_of_lines(lines)
end

--- What the new checker refuses of the module `compiled` in the program of `pipeline` that a session holds ([`build.lsp.held`]),
--- whose text is the document's as spliced ([`build.lsp.syntax_read`]): every error and warning the checker finds and what else the pipeline
--- refuses ([`Pipeline.review`]: in a module of the discipline its contracts and the calls it judged no rule of, in a
--- standard-library module its stub, the generator's own refusals), each worded as a build words it and read back into where
--- it is. The checker's errors are refusals here: the new checker words them itself ([`build.error_render`]). A declaration
--- file is checked and written nothing.
local function generated_of(compiled: build_module.Plan, pipeline: Pipeline.Built,
                            hints?: function(): {Sqlite.Handle}, {boolean}): plan.Compiled
  if compiled.kind ~= "decl" then
    local made, trouble = Pipeline.review(compiled, pipeline, hints)
    if made == nil then
      return { refusals = refusals_of_generated(trouble) }
    end
    return { refusals = {} }
  end
  local build = pipeline.build
  build:lower({ compiled.path })
  local outcome = build:result(compiled.path, true)
  local lines: mut {string} = {}
  if outcome == nil then
    return { refusals = {} }
  elseif outcome.broken then
    for _, problem in ipairs(outcome.syntax) do
      lines[#lines + 1] = ErrorRender.line(compiled.file, problem)
    end
  else
    for _, line in ipairs(build:held(outcome, pipeline.ceilings)) do lines[#lines + 1] = line end
    for _, warning in ipairs(outcome.warnings) do
      lines[#lines + 1] = ErrorRender.line(compiled.file, warning)
    end
  end
  return { refusals = refusals_of_lines(lines) }
end

--- [`generated_of`] and what the modules `sites` (the document's `require`s) are refused for ([`broken`]), where `listed` says
--- which the stage lists.
function syntax_read.generated(compiled: build_module.Plan, pipeline: Pipeline.Built,
                               hints: function(): {Sqlite.Handle}, {boolean}, sites: {Site},
                               listed: function(name: string): boolean): plan.Compiled
  local made = generated_of(compiled, pipeline, hints)
  for _, refusal in ipairs(broken(pipeline, sites, listed)) do
    made.refusals[#made.refusals + 1] = refusal
  end
  return made
end

return syntax_read
