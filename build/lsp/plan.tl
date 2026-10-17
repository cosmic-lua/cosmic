--- What a build refuses of a module that one parse of it tells, before it
--- checks it, as `cosmic lsp` ([`build.lsp.check`]) finds it of a
--- document: a `global`, an analysis it refuses, a [`Test.policy`]
--- outside a test, a test that returns a value, an example that returns
--- none; and the plan ([`build.module`]) a build compiles it by, from the
--- import path and kind the working database lists it as. A refusal
--- worded as a build words one is read back into where it is.

local analyzer = require("build.analyzer")
local ast = require("build.ast")
local compilation = require("build.compilation")
local globals = require("build.globals")
local stub = require("build.stub")
local type compiler = require("build.compiler")
local type build_module = require("build.module")

local record plan
  --- What a build refuses beyond the checker's errors: where, in the
  --- checker's lines and columns, and why.
  record Refusal
    line: integer
    column: integer
    message: string
  end

  --- What [`plan.of`] makes of a document: the plan a build makes of it,
  --- nil for a text that does not parse, whose errors the checker reports;
  --- what a build refuses that the parse tells; and whether a build stops
  --- there, checking nothing.
  record Planned
    plan: build_module.Plan | nil
    refusals: {Refusal}
    halted: boolean
  end

  --- A module's import path and its kind, as the `inputs` view names them.
  record Named
    path: string
    kind: string
  end
end

local type Refusal = plan.Refusal
local type Planned = plan.Planned
local type Named = plan.Named

--- The import path and kind a build gives the file `name` below the root
--- that the working database does not list yet: the `inputs` view's
--- reading of a path (build/analysis_schema.tl).
function plan.named(name: string): Named
  local stem = name:gsub("%.d%.tl$", "")
  if stem == name then stem = name:gsub("/init%.tl$", "") end
  if stem == name then stem = name:gsub("%.tl$", "") end
  local path = stem:gsub("/", ".")
  local kind = "module"
  if name:match("%.d%.tl$") ~= nil then
    kind = "decl"
  elseif name:match("_test%.tl$") ~= nil then
    kind = "test"
  elseif name:match("_example%.tl$") ~= nil then
    kind = "example"
  elseif name:match("^cmd/[^/]+/main%.tl$") ~= nil then
    kind = "main"
  end
  return { path = path, kind = kind }
end

--- The number `digits` spell.
local function number_of(digits: string): integer
  local value = math.tointeger(tonumber(digits))
  if value == nil then return 1 end
  return value
end

--- The refusal `said`, as a build words one (`file:line:column: why`,
--- `file:line: why` or `file: why`), at the place it names: the first
--- line, or its first column, where it names none.
function plan.refusal_of(said: string): Refusal
  local y, x, why = said:match("^[^:\n]*:(%d+):(%d+): (.*)$")
  if y ~= nil and x ~= nil and why ~= nil then
    return { line = number_of(y), column = number_of(x), message = why }
  end
  local line, rest = said:match("^[^:\n]*:(%d+): (.*)$")
  if line ~= nil and rest ~= nil then
    return { line = number_of(line), column = 1, message = rest }
  end
  return { line = 1, column = 1, message = said:match("^[^:\n]*: (.*)$") or said }
end

--- The refusals `said` holds, one a line, as [`compilation.generate`]
--- joins its contracts' ([`refusal_of`]): what a build prints, put where
--- it says, since it answers them in no other shape.
function plan.refusals_of(said: string): {Refusal}
  local out: {Refusal} = {}
  for line in said:gmatch("[^\n]+") do out[#out + 1] = plan.refusal_of(line) end
  return out
end

--- The line of the top-level `return` of `parsed`, or 1 where it has none.
local function return_line(parsed: ast.Parsed): integer
  for _, statement in ipairs(parsed.node) do
    if statement.kind == "return" then return statement.y end
  end
  return 1
end

--- The plan a build makes of the document `text`, the file `name` below
--- the root, the module `path` of `kind` ([`compilation.collect`]), from a
--- parse of it, and what a build refuses that the parse tells: a `global`
--- ([`compilation.global_refusal`]), an analysis it refuses (a
--- [`Test.policy`] it does not take), a policy outside a test
--- ([`compilation.policy_refusal`]), a test that returns a value or an
--- example that returns none ([`compilation.refusal`]). A build checks
--- none of these but a global's. With `own_tree`, the plan of a
--- standard-library module carries its stub, which cosmic's own build
--- holds it to.
function plan.of(built: compiler, name: string, text: string, path: string, kind: string,
                 own_tree: boolean): Planned
  local refusals: {Refusal} = {}
  local parsed, _ = ast.parse(built, text, name)
  if parsed == nil then return { plan = nil, refusals = refusals, halted = false } end
  for _, place in ipairs(globals.found(parsed)) do
    refusals[#refusals + 1] = plan.refusal_of(compilation.global_refusal(name .. ":" ..
        tostring(place.line) .. ":" .. tostring(place.column)))
  end
  local analysis, trouble = analyzer.analysis_of(built, parsed, text)
  if analysis == nil then
    refusals[#refusals + 1] = plan.refusal_of(trouble)
    return { plan = nil, refusals = refusals, halted = true }
  end
  local misplaced = compilation.policy_refusal(name, kind, analysis.inputs)
  if misplaced ~= nil then
    refusals[#refusals + 1] = plan.refusal_of(misplaced)
    return { plan = nil, refusals = refusals, halted = true }
  end
  local tests: {string} = {}
  if kind == "test" then
    tests = analysis.tests
  elseif kind == "example" then
    for _, example in ipairs(analysis.examples) do tests[#tests + 1] = example.name end
  end
  -- Only cosmic's own build reads a stub, of a standard-library module
  -- ([`compilation.generate`]); a source that returns nothing has none
  -- ([`build.derivation`]).
  local made: stub.Made | nil = nil
  if own_tree and kind == "module" and path:sub(1, 7) == "cosmic." and
      analysis.has_top_level_return then
    made = stub.made(parsed)
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
    generated = false,
    key = nil,
    graph_key = nil,
    lua = nil,
    stub = made,
  }
  local refused = compilation.refusal(made_plan)
  if refused ~= nil then
    local at = plan.refusal_of(refused)
    at.line = return_line(parsed)
    refusals[#refusals + 1] = at
    return { plan = made_plan, refusals = refusals, halted = true }
  end
  return { plan = made_plan, refusals = refusals, halted = false }
end

return plan
