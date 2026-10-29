--- What a module's functions reach of the statics it has yet to define, for [`lang.check`]'s `static_before_definition`.
--- A `function R.m(...)` statement gives `R` its function when the statement runs, so a read of `R.m` that runs while the
--- module loads, above that statement, finds nil. The read need not be written at the top of the module: a function that
--- reads `R.m` and is called there reads it as well, and so does any function it calls.
---
--- The checker notes, for each function it walks, the statics it reads that were not yet defined where the function was
--- written ([`LoadOrder.read`]) and the functions it mentions ([`LoadOrder.use`]). Where the module's own code mentions a
--- function while it loads ([`LoadOrder.mention`]), the functions that function mentions are followed, and the first read
--- that is still of an undefined static is refused.
---
--- A function is mentioned by what the module can name it by: a local that holds it, the static `R.m` it defines or is
--- stored in, or the literal that makes it. A mention counts as a call, since the function may be called by the code it is
--- handed to, except where the function is only stored: a local or a static of a declaration takes it, and its mentions
--- are those of the place ([`LoadOrder.bind`], [`LoadOrder.store`]). A function stored anywhere else (a field of a value, an
--- element of a table) is mentioned where it is stored.
---
--- Lua also runs the `__tostring` and `__close` of a class by itself, at a `tostring` of a value or the end of a `<close>`
--- local, so a table literal that makes a value of a class mentions both ([`lang.check`]).
local Ast = require("lang.ast")
local Types = require("lang.types")

local record LoadOrder
  --- A read of the static `name` of `decl`, whose first token is `first`.
  record Read
    decl: Types.Decl
    name: string
    first: integer
  end

  --- A mention of the functions `fn` is, or the local `binding` holds, or the static `name` of `decl` is, whichever is
  --- given, spelled `spelled` (quoted, as a message names it) where it was written. A local or a static is looked up when
  --- the mention is followed: it may take its function after the mention is written.
  record Use
    fn: integer
    binding: integer
    decl: Types.Decl?
    name: string
    spelled: string
  end

  --- What one function reads of undefined statics, and the functions it mentions.
  record Effects
    reads: {Read}
    uses: {Use}
  end

  --- What a walk of a module has noted.
  record State
    --- How many statics the walk has yet to pass.
    mut waiting: integer
    --- By the id of the function.
    effects: {integer: Effects}
    --- The functions a local holds, by the id of the local.
    held: {integer: {integer}}
    --- The functions a static of a declaration is, or holds: `function R.m(...)`, a method of a class, `R.m = f`.
    statics: {Types.Decl: {string: {integer}}}
    --- The classes of the module that list an interface, directly or through the interfaces it extends, by the interface.
    implementers: {Types.Decl: {Types.Decl}}
    --- The nodes (function literals and names) that only store a function, by id: the place that takes it is mentioned
    --- instead.
    given: mut {integer: boolean}
    --- Whether the static `name` of `decl` is still to be defined.
    undefined: function(decl: Types.Decl, name: string): boolean
    --- Reports a mention at `node`, spelled `spelled`, that reaches the read found.
    refuse: function(node: Ast.Node, spelled: string, found: Found)
  end

  --- A read that is still of an undefined static, and the functions the walk went through to reach it: the spelling of
  --- each mention after the first.
  record Found
    read: Read
    via: {string}
  end

  new: function(waiting: integer, undefined: function(decl: Types.Decl, name: string): boolean,
                refuse: function(node: Ast.Node, spelled: string, found: LoadOrder.Found)): State
  read: function(state: State, within: integer, read: Read)
  use: function(state: State, within: integer, use: Use)
  hold: function(state: State, binding: integer, fn: integer)
  bind: function(state: State, binding: integer, value: Ast.Exp)
  store: function(state: State, decl: Types.Decl, name: string, value: Ast.Exp)
  define: function(state: State, decl: Types.Decl, name: string, fn: integer)
  implement: function(state: State, interface: Types.Decl, class: Types.Decl)
  mention: function(state: State, within: integer, node: Ast.Node, use: Use)
  of_function: function(fn: integer, spelled: string): Use
  of_local: function(binding: integer, spelled: string): Use
  of_static: function(decl: Types.Decl, name: string, spelled: string): Use
end

function LoadOrder.new(waiting: integer, undefined: function(decl: Types.Decl, name: string): boolean,
                       refuse: function(node: Ast.Node, spelled: string, found: LoadOrder.Found)): LoadOrder.State
  return {
    waiting = waiting, effects = {}, held = {}, statics = {}, implementers = {}, given = {}, undefined = undefined, refuse = refuse,
  }
end

local function effects_of(state: LoadOrder.State, fn: integer): LoadOrder.Effects
  local effects = state.effects
  local held = effects[fn]
  if held == nil then
    held = { reads = {}, uses = {} }
    effects[fn] = held
  end
  return held
end

--- Notes that the function `within` reads a static not yet defined.
function LoadOrder.read(state: LoadOrder.State, within: integer, read: LoadOrder.Read)
  local reads = effects_of(state, within).reads
  reads[#reads + 1] = read
end

--- The mention of the function `fn`.
function LoadOrder.of_function(fn: integer, spelled: string): LoadOrder.Use
  return { fn = fn, binding = 0, decl = nil, name = "", spelled = spelled }
end

--- The mention of the functions the local `binding` holds.
function LoadOrder.of_local(binding: integer, spelled: string): LoadOrder.Use
  return { fn = 0, binding = binding, decl = nil, name = "", spelled = spelled }
end

--- The mention of the functions the static `name` of `decl` is.
function LoadOrder.of_static(decl: Types.Decl, name: string, spelled: string): LoadOrder.Use
  return { fn = 0, binding = 0, decl = decl, name = name, spelled = spelled }
end

--- Notes that the function `within` makes `use`.
function LoadOrder.use(state: LoadOrder.State, within: integer, use: LoadOrder.Use)
  local uses = effects_of(state, within).uses
  uses[#uses + 1] = use
end

--- Adds `fn` to `list` unless it is there.
local function add(list: mut {integer}, fn: integer)
  for _, held in ipairs(list) do
    if held == fn then
      return
    end
  end
  list[#list + 1] = fn
end

--- The functions `value` is, where it is a function literal or a local that holds some; nil for any other expression.
local function functions_of(state: LoadOrder.State, value: Ast.Exp): {integer}?
  if (value.kind == "FunctionLit") then
    return { value.fn.id }
  elseif (value.kind == "Name") then
    local binding = value.binding
    if binding ~= nil then
      return state.held[binding]
    end
  end
  return nil
end

--- Notes that the local `binding` holds the function `fn`.
function LoadOrder.hold(state: LoadOrder.State, binding: integer, fn: integer)
  local held = state.held
  local list = held[binding]
  if list == nil then
    list = {}
    held[binding] = list
  end
  add(list, fn)
end

--- Notes that the local `binding` takes `value`: if that is a function, or a local that holds some, the local holds them
--- and `value` is no mention.
function LoadOrder.bind(state: LoadOrder.State, binding: integer, value: Ast.Exp)
  local fns = functions_of(state, value)
  if fns == nil then
    return
  end
  state.given[value.id] = true
  for _, fn in ipairs(fns) do
    LoadOrder.hold(state, binding, fn)
  end
end

--- Notes that `fn` is the static `name` of `decl`, or a method of it.
function LoadOrder.define(state: LoadOrder.State, decl: Types.Decl, name: string, fn: integer)
  local statics = state.statics
  local named = statics[decl]
  if named == nil then
    named = {}
    statics[decl] = named
  end
  local list = named[name]
  if list == nil then
    list = {}
    named[name] = list
  end
  add(list, fn)
end

--- Notes that the class `class` lists the interface `interface`: a method called through the interface is the method of
--- the class.
function LoadOrder.implement(state: LoadOrder.State, interface: Types.Decl, class: Types.Decl)
  local implementers = state.implementers
  local list = implementers[interface]
  if list == nil then
    list = {}
    implementers[interface] = list
  end
  for _, held in ipairs(list) do
    if held == class then
      return
    end
  end
  list[#list + 1] = class
end

--- Notes that the static `name` of `decl` takes `value`: if that is a function, or a local that holds some, the static is
--- them and `value` is no mention.
function LoadOrder.store(state: LoadOrder.State, decl: Types.Decl, name: string, value: Ast.Exp)
  local fns = functions_of(state, value)
  if fns == nil then
    return
  end
  state.given[value.id] = true
  for _, fn in ipairs(fns) do
    LoadOrder.define(state, decl, name, fn)
  end
end

--- The functions `use` mentions now.
local function followed(state: LoadOrder.State, use: LoadOrder.Use): {integer}
  if use.fn ~= 0 then
    return { use.fn }
  end
  local decl = use.decl
  if decl ~= nil then
    -- The methods of an interface are those of the classes that list it.
    local out: mut {integer} = {}
    local owners: mut {Types.Decl} = { decl }
    for _, class in ipairs(state.implementers[decl] or {}) do
      owners[#owners + 1] = class
    end
    for _, owner in ipairs(owners) do
      local named = state.statics[owner]
      if named ~= nil then
        for _, fn in ipairs(named[use.name] or {}) do
          out[#out + 1] = fn
        end
      end
    end
    return out
  end
  return state.held[use.binding] or {}
end

local function search(state: LoadOrder.State, fn: integer, seen: mut {integer: boolean}, via: mut {string}): LoadOrder.Found?
  if seen[fn] == true then
    return nil
  end
  seen[fn] = true
  local effects = state.effects[fn]
  if effects == nil then
    return nil
  end
  for _, read in ipairs(effects.reads) do
    if state.undefined(read.decl, read.name) then
      local path: mut {string} = {}
      for i, spelled in ipairs(via) do
        path[i] = spelled
      end
      return { read = read, via = path }
    end
  end
  for _, use in ipairs(effects.uses) do
    via[#via + 1] = use.spelled
    for _, next_fn in ipairs(followed(state, use)) do
      local found = search(state, next_fn, seen, via)
      if found ~= nil then
        return found
      end
    end
    table.remove(via)
  end
  return nil
end

--- A mention, `use`, at `node`, in the function `within` or, where that is 0, in the chunk. In the chunk it runs as the
--- module loads: it is called, or handed to code that may call it, so the reads it reaches must be of statics already
--- defined, and the first that is not is refused. In a function it is noted for the day that function runs.
function LoadOrder.mention(state: LoadOrder.State, within: integer, node: Ast.Node, use: LoadOrder.Use)
  if state.waiting == 0 then
    return
  end
  if within ~= 0 then
    LoadOrder.use(state, within, use)
    return
  end
  local seen: {integer: boolean} = {}
  for _, fn in ipairs(followed(state, use)) do
    local found = search(state, fn, seen, {})
    if found ~= nil then
      state.refuse(node, use.spelled, found)
      return
    end
  end
end

return LoadOrder
