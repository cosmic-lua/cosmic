--- What a build refuses of a module that one parse of it tells, before it
--- checks it, as `cosmic lsp` ([`build.lsp.check`]) finds it of a
--- document: a `global`, an analysis it refuses, a [`Test.policy`]
--- outside a test, a test that returns a value, an example that returns
--- none; the plan ([`build.module`]) a build compiles it by, from the
--- import path and kind the working database lists it as; and that
--- compile ([`plan.compiled`]). A refusal worded as a build words one is
--- read back into where it is.

local analyzer = require("build.analyzer")
local ast = require("build.ast")
local compilation = require("build.compilation")
local globals = require("build.globals")
local stub = require("build.stub")
local type compiler = require("build.compiler")
local type receivers = require("build.receivers")
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
    --- What it requires and where, in order ([`ast.require_sites`]): none
    --- for a text that does not parse.
    requires: {Site}
  end

  --- A `require` of a document: the module it names, and where.
  record Site
    name: string
    line: integer
    column: integer
  end

  --- What [`plan.compiled`] makes of a text: the checker's reading of
  --- it, nil where the compile handed it none, and what else the build
  --- refused.
  record Compiled
    result: compiler.Result | nil
    refusals: {Refusal}
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
local type Site = plan.Site

--- The import path and kind a build gives the file `name` below the root
--- that the working database does not list yet: the `inputs` view's
--- reading of a path (build/analysis_schema.tl), and a template's
--- (build/derivation.tl), the convention a `.tl` file gets with its
--- extension swapped.
function plan.named(name: string): Named
  if name:match("%.tmpl$") ~= nil then
    local template = name:gsub("%.tmpl$", ""):gsub("/init$", "")
    return { path = (template:gsub("/", ".")), kind = "module" }
  end
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
local function refusals_of(said: string): {Refusal}
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

--- What `parsed` requires and where, in source order, each name once, as
--- [`ast.require_sites`] finds them: read off its tokens, a fraction of a
--- walk of its tree, but from the tree where a name is spelled with an
--- escape or in long brackets, which only the tree reads. A `require`
--- after `.` or `:` is a field, and one given anything but one string
--- names nothing.
local function sites_of(built: compiler, parsed: ast.Parsed): {Site}
  local tokens = parsed.tokens
  local out: {Site} = {}
  local seen: {string:boolean} = {}
  for i, token in ipairs(tokens) do
    local before = tokens[i - 1]
    if token.kind == "identifier" and token.tk == "require" and
        (before == nil or (before.kind ~= "." and before.kind ~= ":")) then
      local literal = tokens[i + 1]
      if literal ~= nil and literal.kind == "(" then
        local closing = tokens[i + 3]
        literal = tokens[i + 2]
        if closing == nil or closing.kind ~= ")" then literal = nil end
      end
      if literal ~= nil and literal.kind == "string" then
        local quote = literal.tk:sub(1, 1)
        if (quote ~= '"' and quote ~= "'") or literal.tk:find("\\", 1, true) ~= nil then
          local found, _ = ast.require_sites(built, parsed)
          local whole: {Site} = {}
          for _, site in ipairs(found or {}) do
            whole[#whole + 1] = { name = site.name, line = site.y, column = site.x }
          end
          return whole
        end
        local name = literal.tk:sub(2, -2)
        if seen[name] == nil then
          seen[name] = true
          out[#out + 1] = { name = name, line = literal.y, column = literal.x }
        end
      end
    end
  end
  return out
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
--- holds it to. A `generated` text is a template's Teal, whose warnings a
--- build discounts as it does a generated module's.
function plan.of(built: compiler, name: string, text: string, path: string, kind: string,
                 own_tree: boolean, generated: boolean): Planned
  local refusals: {Refusal} = {}
  local parsed, _ = ast.parse(built, text, name)
  if parsed == nil then
    return { plan = nil, refusals = refusals, halted = false, requires = {} }
  end
  local requires = sites_of(built, parsed)
  for _, place in ipairs(globals.found(parsed)) do
    refusals[#refusals + 1] = plan.refusal_of(compilation.global_refusal(name .. ":" ..
        tostring(place.line) .. ":" .. tostring(place.column)))
  end
  local analysis, trouble = analyzer.analysis_of(built, parsed, text)
  if analysis == nil then
    refusals[#refusals + 1] = plan.refusal_of(trouble)
    return { plan = nil, refusals = refusals, halted = true, requires = requires }
  end
  local misplaced = compilation.policy_refusal(name, kind, analysis.inputs)
  if misplaced ~= nil then
    refusals[#refusals + 1] = plan.refusal_of(misplaced)
    return { plan = nil, refusals = refusals, halted = true, requires = requires }
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
    generated = generated,
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
    return { plan = made_plan, refusals = refusals, halted = true, requires = requires }
  end
  return { plan = made_plan, refusals = refusals, halted = false, requires = requires }
end

--- The checker's reading of a text [`compilation.generate`] refused for
--- the checker's errors, which it hands its renderer.
local record Rendered
  result: compiler.Result | nil
end

--- Compiles the text `spliced` of `compiled` in `env` as a build compiles
--- it, which drops the warnings a build discounts and refuses what a
--- build refuses beyond the checker's errors: in cosmic's own tree its
--- stub and its contracts, and Lua's refusal of the code. The checker's
--- reading is the one a refusal for the checker's errors hands the
--- renderer. The type the checker records of the module is put back,
--- whatever the compile does: an open document is read through
--- `search_module`.
function plan.compiled(compiled: build_module.Plan, built: compiler, env: compiler.Env,
                       typed: receivers.State, own_tree: boolean,
                       spliced: string): plan.Compiled
  local rendered: Rendered = { result = nil }
  local kept = env.modules[compiled.path]
  local function generate(): compilation.Generated | nil, string
    return compilation.generate(compiled, built, env, typed, own_tree, true,
      function(_file: string, _source: string, seen: compiler.Result): string
        rendered.result = seen
        return ""
      end, spliced, true)
  end
  local ok, made, trouble = pcall(generate)
  env.modules[compiled.path] = kept
  if not ok then error(made, 0) end
  local result = rendered.result
  if made == nil and result == nil then
    return { result = nil, refusals = refusals_of(trouble or "") }
  end
  return { result = result, refusals = {} }
end

return plan
