--- The shapes of what a build refuses of a module that one parse of it tells, before it checks it, as `cosmic lsp`
--- ([`build.lsp.check`]) finds it of a document ([`build.lsp.syntax_read`]): a `global`, an analysis it refuses, a
--- [`Test.policy`] outside a test, a test that returns a value, an example that returns none; the plan ([`build.module`])
--- a build compiles it by, from the import path and kind the working database lists it as. A refusal worded as a build words
--- one is read back into where it is ([`plan.refusal_of`]).

local type build_module = require("build.module")

local record plan
  --- What a build refuses beyond the checker's errors: where, in the
  --- checker's lines and columns, and why.
  record Refusal
    line: integer
    column: integer
    message: string
  end

  --- What [`build.lsp.syntax_read`]'s `plan_of` makes of a document: the plan a build makes of it,
  --- nil for a text that does not parse, whose errors the checker reports;
  --- what a build refuses that the parse tells; and whether a build stops
  --- there, checking nothing.
  record Planned
    plan: build_module.Plan?
    refusals: {Refusal}
    halted: boolean
    --- What it requires and where, in order: none for a text that does not parse.
    requires: {Site}
  end

  --- A `require` of a document: the module it names, and where.
  record Site
    name: string
    line: integer
    column: integer
  end

  --- What the new checker's compile of a text refused it for.
  record Compiled
    refusals: {Refusal}
  end

  --- A module's import path and its kind, as the `inputs` view names them.
  record Named
    path: string
    kind: string
  end
end

local type Refusal = plan.Refusal
local type Named = plan.Named

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

return plan
