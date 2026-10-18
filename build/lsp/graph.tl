--- What a build refuses of where a document's `require`s reach, as
--- `cosmic lsp` ([`build.lsp.check`]) finds it among the modules the
--- working database lists ([`source.View`]): a `require` of a module
--- private to a directory the document is not in, or, in cosmic's own
--- tree, of `build/` or a test ([`positions.check`]); and a cycle of
--- imports through the document ([`compilation.ordered`]). Each is the
--- build's own check, worded as a build words it, put at the document's
--- `require`.
---
--- The document's requires are its text's, as the editor holds it; an
--- open document's are those of its last check; every other module's are
--- the stage's (the `requires` rows).

local Store = require("cosmic.store")
local compilation = require("build.compilation")
local plan = require("build.lsp.plan")
local positions = require("build.positions")
local source = require("build.lsp.source")
local type build_module = require("build.module")

local record graph
end

local type Module = build_module.Plan
local type Require = plan.Site
local type Refusal = plan.Refusal

--- The module `path`, the file `file` of `kind`, requiring `requires`, as
--- the build's checks read one.
local function module_of(path: string, file: string, kind: string, requires: {string}): Module
  return { path = path, file = file, kind = kind, source = "", source_hash = "",
    requires = requires, tests = {}, inputs = nil }
end

--- The modules a build checks the positions and order of: every one the
--- database lists but a declaration, which a build's `collect` leaves
--- out, each with no requires, made once a stage.
local record Held
  files: {string:source.Module} | nil
  modules: {Module}
end

local held: Held = { files = nil, modules = {} }

local function listed(src: source.View): {Module}
  if held.files == src.files then return held.modules end
  local out: {Module} = {}
  for file, m in pairs(src.files) do
    if m.kind ~= "decl" and m.kind ~= "vendor" then
      out[#out + 1] = module_of(m.path, file, m.kind, {})
    end
  end
  table.sort(out, function(a: Module, b: Module): boolean return a.file < b.file end)
  held.files, held.modules = src.files, out
  return out
end

--- Whether the running binary carries a row of the module `name`, as a
--- build asks it of a `cosmic.internal.*` name ([`positions.check`]).
local function carried(name: string): boolean
  local bytecode, _ = Store.bytecode(name)
  return bytecode ~= nil
end

--- The refusal `said` at `at`.
local function placed(said: string, at: Require): Refusal
  return { line = at.line, column = at.column, message = plan.refusal_of(said).message }
end

--- The modules every module requires, by import path: `subject` its
--- `requires`, an open document its last check's (`opened`, by file),
--- every other the stage's.
local function edges_of(src: source.View, subject: Module, opened: {string:{string}}): {string:{string}}
  local out: {string:{string}} = {}
  for file, m in pairs(src.files) do
    if m.kind ~= "decl" and m.kind ~= "vendor" then
      out[m.path] = opened[file] or src.requires[m.source_hash] or {}
    end
  end
  out[subject.path] = subject.requires
  return out
end

--- Every module `from` reaches through `edges`, `from` among them.
local function reached(edges: {string:{string}}, from: string): {string:boolean}
  local seen: {string:boolean} = {}
  local stack: {string} = { from }
  while #stack > 0 do
    local at = table.remove(stack)
    if seen[at] == nil and edges[at] ~= nil then
      seen[at] = true
      for _, name in ipairs(edges[at]) do stack[#stack + 1] = name end
    end
  end
  return seen
end

--- Every module that reaches `target` through `edges`: `target` too
--- where it reaches itself.
local function reaching(edges: {string:{string}}, target: string): {string:boolean}
  local into: {string:{string}} = {}
  for from, names in pairs(edges) do
    for _, name in ipairs(names) do
      local list = into[name]
      if list == nil then
        list = {}
        into[name] = list
      end
      list[#list + 1] = from
    end
  end
  local seen: {string:boolean} = {}
  local stack: {string} = { target }
  while #stack > 0 do
    local at = table.remove(stack)
    for _, from in ipairs(into[at] or {}) do
      if seen[from] == nil then
        seen[from] = true
        stack[#stack + 1] = from
      end
    end
  end
  return seen
end

--- The cycle of imports through `subject`, worded as a build words it,
--- at the first of `requires` that closes it; nil where there is none.
--- The build's own [`compilation.ordered`] words it, over the modules
--- that both reach `subject` and are reached by it, `subject` first.
local function cycle(src: source.View, subject: Module, requires: {Require},
                     opened: {string:{string}}): Refusal | nil
  local edges = edges_of(src, subject, opened)
  local back = reaching(edges, subject.path)
  for _, at in ipairs(requires) do
    if back[at.name] == true then
      local forward = reached(edges, subject.path)
      local members: {Module} = { subject }
      local names: {string} = {}
      for name in pairs(back) do
        if forward[name] == true and name ~= subject.path then names[#names + 1] = name end
      end
      table.sort(names)
      for _, name in ipairs(names) do
        members[#members + 1] = module_of(name, name, "module", edges[name] or {})
      end
      local _, why = compilation.ordered(members)
      return placed(why, at)
    end
  end
  return nil
end

--- What a build refuses of the `require`s `requires` of the document
--- `file`, the module `path` of `kind`: each that reaches where position
--- closes to it, or else the cycle of imports through it. `opened` is
--- what each other open document required at its last check, by file.
function graph.refusals(src: source.View, file: string, path: string, kind: string,
                        requires: {Require}, opened: {string:{string}}): {Refusal}
  local out: {Refusal} = {}
  local others = listed(src)
  local names: {string} = {}
  for _, at in ipairs(requires) do names[#names + 1] = at.name end
  local subject = module_of(path, file, kind, names)
  local modules: {Module} = {}
  for _, m in ipairs(others) do
    if m.file ~= file then modules[#modules + 1] = m end
  end
  local checked = module_of(path, file, kind, {})
  modules[#modules + 1] = checked
  local own_tree = source.own_tree(src)
  -- The build's check answers only the first require it refuses: where
  -- it refuses any, each is asked alone.
  local all: {string} = {}
  for _, at in ipairs(requires) do all[#all + 1] = at.name end
  checked.requires = all
  local fine, _ = positions.check(modules, own_tree, carried)
  if not fine then
    for _, at in ipairs(requires) do
      checked.requires = { at.name }
      local ok, why = positions.check(modules, own_tree, carried)
      if not ok then out[#out + 1] = placed(why, at) end
    end
  end
  if #out > 0 then return out end
  local closed = cycle(src, subject, requires, opened)
  if closed ~= nil then out[1] = closed end
  return out
end

return graph
