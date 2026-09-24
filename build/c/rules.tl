--- The review checklist's mechanical items, checked over a C file's
--- syntax tree (`build.c.tree`) rather than by a reader.
---
--- Each rule is a promise AGENTS.md's C checklist makes, narrowed to what
--- can be decided from one function's tree in source order:
---
--- - "narrowed-integer": an integer taken from Lua is cast straight to a
---   narrower type. A `lua_Integer` that does not fit wraps silently;
---   `cosmic_checkint` and `cosmic_optint` (core/check.h) refuse it.
--- - "above-buffer": a value sits above an open `luaL_Buffer` when a
---   buffer call other than `luaL_addvalue` is made. Every other buffer
---   call needs the buffer's own slot on top.
--- - "held-across-raise": a resource held in a C local -- memory, a
---   descriptor, a stream, a directory, a statement -- is still held at a
---   call that can raise. The raise unwinds past the C frame, and nothing
---   releases what it held; a guard (core/guard.h) does.
--- - "string-after-pop": a pointer into a Lua string, taken from a slot
---   counted from the top, is read after the string has left the stack.
---   Nothing keeps a popped string alive; copy it first.
--- - "returned-shape": a binding of the syscall table returns a count of
---   values its declaration in core/syscalls.h does not, or a fallible
---   one returns two -- a failure without its errno (core/fail.h).
--- - "failure-shape": a fallible binding fails in the other shape than
---   its declaration's: one declared `boolean`, an effect, fails through
---   `cosmic_fail_effect` (false, error, errno); one declared a value
---   fails through `cosmic_fail` (nil, error, errno) and never answers a
---   bare true -- directly, or through a helper of the file that returns
---   only that shape. build/gen_syscalls.tl refuses `boolean|nil`, which is
---   neither.
--- - "pass-fail-int": a function a header declares to return `int` (a
---   file's own helpers are not held to it, only its header's promises)
---   returns only 0, 1 or a truth -- a comparison, a bool, a call of a
---   helper of the file that answers only truths, a local given only
---   truths. It is a pass or a fail, and returns `bool`. One that forwards
---   a library's status stays `int`, its contract said at its declaration.
--- - "constant-return": a function of external linkage returns the same
---   constant on every path, which tells its caller nothing: it returns
---   void. `main`, and a function handed the state first, whose `int`
---   may be a count of the values it left, are not.
--- - "true-alone": a `lua_CFunction` returns `true` and nothing else on
---   every path (`lua_pushboolean(L, 1); return 1;` or `cosmic_ok`), so
---   it returns no values.
--- - "single-file": a function a header declares is referred to by no
---   translation unit but the one defining it, so it belongs to that file,
---   static, out of the header. It is decided over a whole tree at once
---   (`rules.unit`, `rules.single_file`), so `build.c` finds it only when
---   every C file is checked together.
---
--- "pass-fail-int", "constant-return" and "true-alone" read the code
--- one platform's preprocessor leaves (build.c compiles for the host): a
--- function whose returns differ under an `#ifdef` is judged by the
--- branch compiled, and one the other branch makes a real answer is
--- exempted in `exempt`, with the reason.
---
--- The walk is source order, not a flow analysis. A branch that ends --
--- in a `return`, a `goto`, or a call that never returns -- leaves what
--- it did behind it; one that falls through joins the other, holding
--- whatever either holds. A test of a local against NULL, or of a
--- descriptor against 0, says it holds nothing on the side where it is
--- absent. A loop body is walked once, as if it might not run. What this
--- cannot see is said in `exempt`, with the reason, rather than worked
--- around in the code it checks.

local String = require("cosmic.string")
local tree = require("build.c.tree")

local type Node = tree.Node

local record rules
  --- One broken promise.
  record Finding
    file: string
    line: integer
    --- Which rule: "narrowed-integer", "above-buffer",
    --- "held-across-raise", "string-after-pop", "returned-shape",
    --- "failure-shape", "pass-fail-int", "constant-return", "true-alone",
    --- "single-file".
    rule: string
    --- The function it is in.
    within: string
    message: string
  end

  --- The findings a rule cannot see past, and why each is not one, by
  --- `"<file> <function> <rule>"`.
  exempt: {string: string}

  --- What one translation unit defines that a header declares, and
  --- every function it refers to: what "single-file" is read from, once
  --- every unit of the tree has been.
  record Unit
    file: string
    --- The functions it defines that a header declares, neither static
    --- nor inline, to that declaration.
    defines: {string: tree.Node}
    --- The names of the functions it refers to anywhere.
    refers: {string: boolean}
  end

  --- What core/syscalls.h declares a binding returns: how many values,
  --- and whether the last is an errno or a code, so that a failure is
  --- three of them.
  record Declared
    count: integer
    fallible: boolean
    --- Whether what it returns on success is `boolean`: an effect, whose
    --- failure is `false`, rather than a value, whose failure is `nil`.
    effect: boolean
  end
end

--- Why a function the checked core alone refers to is still in a header.
local checked_only <const> = "every file refers to it through a macro of its header " ..
  "that names it only in the checked core (COSMIC_CHECKED); the check compiles " ..
  "the others as a release core does, where the macro names libc's or nothing"

rules.exempt = {
  ["core/boot.c slurp held-across-raise"] =
    "boot runs outside any protected call: a raise there ends the process, " ..
    "which releases everything",
  ["core/syscalls.c cosmic_sys_execve held-across-raise"] =
    "every argv and environment value it reads once argv is taken was checked " ..
    "to be a string before the calloc, so lua_tolstring converts nothing and " ..
    "cannot raise",
  ["core/syscalls.c cosmic_sys_spawn held-across-raise"] =
    "every value it reads once argv is taken was checked to be a string first, " ..
    "so lua_tolstring converts nothing and cannot raise",
  ["core/syscalls_fs.c cosmic_sys_open_temporary held-across-raise"] =
    "its answer, and the answer's \"fd\" key, exist before the file is opened, " ..
    "so setting the descriptor into it allocates nothing",
  ["core/memory.h cosmic_malloc single-file"] = checked_only,
  ["core/memory.h cosmic_calloc single-file"] = checked_only,
  ["core/memory.h cosmic_realloc single-file"] = checked_only,
  ["core/memory.h cosmic_free single-file"] = checked_only,
  ["core/fault.h cosmic_fault single-file"] = checked_only,
  ["core/startup_hook.c cosmic_startup_test_pause constant-return"] =
    "a link-time seam: the product hook always lets startup go on, and " ..
    "test/portable/startup_hook.c, linked in its place, answers whether it may",
}

--- The calls that take a resource, and the argument that receives it
--- when it is not the call's value: `sqlite3_prepare_v2(db, sql, n,
--- &statement, tail)` hands its statement back through its fourth.
local acquires: {string: integer} = {
  malloc = 0, calloc = 0, realloc = 0, strdup = 0, strndup = 0,
  fopen = 0, fdopen = 0, opendir = 0, fdopendir = 0,
  open = 0, openat = 0, mkstemp = 0, mkostemp = 0, dup = 0, socket = 0,
  sqlite3_prepare = 4, sqlite3_prepare_v2 = 4, sqlite3_prepare_v3 = 5,
  sqlite3_open = 2, sqlite3_open_v2 = 2,
}

--- The calls that take nothing when they fail: SQLite leaves a statement
--- it could not prepare NULL. A connection it could not open is not, and
--- must still be closed.
local absent_on_failure: {string: boolean} = {
  sqlite3_prepare = true, sqlite3_prepare_v2 = true, sqlite3_prepare_v3 = true,
}

--- The calls that release a resource passed to them.
local releases: {string: boolean} = {
  free = true, realloc = true, fclose = true, closedir = true, close = true,
  sqlite3_finalize = true, sqlite3_close = true, sqlite3_close_v2 = true,
}

--- The calls that take a `lua_State *` and still cannot raise: they
--- neither allocate nor run a metamethod or a finalizer. Every other
--- call handed the state is taken to raise, the tree's own included.
local quiet: {string: boolean} = {
  lua_absindex = true, lua_gettop = true, lua_settop = true, lua_rotate = true,
  lua_copy = true, lua_checkstack = true, lua_xmove = true,
  lua_type = true, lua_typename = true, lua_isnumber = true, lua_isstring = true,
  lua_iscfunction = true, lua_isinteger = true, lua_isuserdata = true,
  lua_rawlen = true, lua_rawequal = true, lua_toboolean = true,
  lua_tointegerx = true, lua_tonumberx = true, lua_touserdata = true,
  lua_tothread = true, lua_topointer = true, lua_tocfunction = true,
  lua_pushnil = true, lua_pushboolean = true, lua_pushinteger = true,
  lua_pushnumber = true, lua_pushlightuserdata = true, lua_pushvalue = true,
  lua_rawget = true, lua_rawgeti = true, lua_rawgetp = true, lua_next = true,
  lua_status = true, lua_getallocf = true, lua_setallocf = true,
  -- Pushes a light userdata, which allocates nothing.
  luaL_buffinit = true,
  -- Protected: a failure, memory included, comes back as a status.
  lua_load = true, luaL_loadbufferx = true, luaL_loadstring = true,
  luaL_loadfilex = true, lua_pcallk = true,
}

--- The calls that never return to their caller.
local ending: {string: boolean} = {
  luaL_error = true, lua_error = true, luaL_argerror = true,
  luaL_typeerror = true, abort = true, exit = true, _exit = true,
}

--- The calls past `lua_push*`, `lua_new*`, `lua_get*` and `lua_rawget*`
--- that leave a value on the stack.
local pushing: {string: boolean} = {
  lua_createtable = true, luaL_tolstring = true, luaL_newmetatable = true,
  luaL_getmetafield = true, luaL_getsubtable = true, luaL_gsub = true,
  luaL_traceback = true, luaL_loadbufferx = true, luaL_loadstring = true,
  luaL_requiref = true,
}

--- Whether a call leaves a value on the stack, as far as a buffer is
--- concerned.
local function pushes(name: string): boolean
  if name:match("^lua_push") or name:match("^lua_new") or name:match("^lua_rawget") then
    return true
  end
  if name:match("^lua_get") and name ~= "lua_gettop" and name ~= "lua_getallocf" then
    return true
  end
  return pushing[name] == true
end

--- The narrow integer types a `lua_Integer` does not always fit.
local narrow: {string: boolean} = {
  ["int"] = true, ["unsigned int"] = true, ["short"] = true,
  ["unsigned short"] = true, ["char"] = true, ["signed char"] = true,
  ["unsigned char"] = true,
}

local function name_of(decl: Node): string
  return decl.text:match("([%w_]+) '")
end

--- Visits `node` and everything under it, children first: the order an
--- expression's calls are made in.
local function after(node: Node, visit: function(Node))
  for _, child in ipairs(node.children) do
    after(child, visit)
  end
  visit(node)
end

--- The arguments of a call, its callee left out.
local function arguments(call: Node): {Node}
  local out: {Node} = {}
  for i = 2, #call.children do
    out[#out + 1] = call.children[i]
  end
  return out
end

--- What `node` refers to once conversions and an `&` are seen through:
--- a variable's address, or nil.
local function referenced(node: Node): string
  local bare = tree.bare(node)
  if bare == nil then return nil end
  if bare.kind == "UnaryOperator" and bare.text:match("'&'") and #bare.children == 1 then
    bare = tree.bare(bare.children[1])
  end
  local kind, id = tree.referent(bare)
  if kind == "Var" or kind == "ParmVar" then return id end
  return nil
end

--- Whether a call is handed the state, directly or through a buffer,
--- which allocates through the state it was opened on.
local function takes_state(call: Node): boolean
  for _, argument in ipairs(arguments(call)) do
    local t = tree.canonical_type(argument)
    if t == "lua_State *" or t == "struct lua_State *" or t == "luaL_Buffer *"
        or t == "struct luaL_Buffer *" then
      return true
    end
  end
  return false
end

--- Whether a call is one that never returns: by name, or by the
--- `noreturn` its callee's type carries.
local function ends(call: Node): boolean
  local name = tree.callee(call)
  if name ~= nil and ending[name] then return true end
  local callee = call.children[1] and tree.bare(call.children[1])
  return callee ~= nil and callee.text:find("noreturn", 1, true) ~= nil
end

local record Context
  file: string
  within: string
  findings: {rules.Finding}
  --- What the tree's own functions release, by name and argument index.
  releasing: {string: {integer: boolean}}
  --- The functions of the file that return `int` and only truths.
  truthful: {string: boolean}
  --- The failure shape each function of the file returns in.
  shapes: {string: string}
end

local function report(ctx: Context, node: Node, rule: string, message: string)
  local file, line = tree.place(node)
  ctx.findings[#ctx.findings + 1] = {
    file = file or ctx.file, line = line or 0, rule = rule,
    within = ctx.within, message = message,
  }
end

-- narrowed-integer -----------------------------------------------------

local function narrowed(ctx: Context, body: Node)
  -- A variable compared against a bound before it is cast has had its
  -- range checked: `value > INT_MAX` then `(int)value`.
  local bounded: {string: boolean} = {}
  after(body, function(node: Node)
    if node.kind == "BinaryOperator" and #node.children == 2 then
      local op = node.text:match("'([^']*)'$")
      if op == "<" or op == ">" or op == "<=" or op == ">=" then
        for _, side in ipairs(node.children) do
          local id = referenced(side)
          if id ~= nil then bounded[id] = true end
        end
      end
      return
    end
    if node.kind ~= "CStyleCastExpr" or not node.text:find("<IntegralCast>", 1, true) then
      return
    end
    local to = tree.canonical_type(node)
    local operand = node.children[1] and tree.bare(node.children[1])
    if not narrow[to] or operand == nil
        or not (tree.type_of(operand) or ""):find("lua_Integer", 1, true) then
      return
    end
    local id = referenced(operand)
    if id == nil or not bounded[id] then
      report(ctx, node, "narrowed-integer", "casts a lua_Integer to " .. to ..
        " without checking its range first, which wraps one that does not fit: " ..
        "take it with cosmic_checkint or cosmic_optint (core/check.h)")
    end
  end)
end

-- above-buffer ---------------------------------------------------------

local function is_buffer(node: Node): boolean
  local t = tree.canonical_type(node) or ""
  return t == "struct luaL_Buffer" or t == "struct luaL_Buffer *" or t == "luaL_Buffer *"
end

--- The buffer a call is handed, by address, or nil.
local function buffer_of(call: Node): string
  for _, argument in ipairs(arguments(call)) do
    local bare = tree.bare(argument)
    local inner = bare
    if bare ~= nil and bare.kind == "UnaryOperator" and #bare.children == 1 then
      inner = tree.bare(bare.children[1])
    end
    if inner ~= nil and inner.kind == "DeclRefExpr" and is_buffer(inner) then
      local _, id = tree.referent(inner)
      return id
    end
  end
  return nil
end

local function above_buffer(ctx: Context, body: Node, params: {Node})
  local open: {string: boolean} = {}
  -- A buffer handed in is open for as long as this function has it.
  for _, param in ipairs(params) do
    if is_buffer(param) then open[param.id] = true end
  end
  local above = 0
  after(body, function(node: Node)
    if node.kind ~= "CallExpr" then return end
    local name = tree.callee(node)
    if name == nil then return end
    local buffer = buffer_of(node)
    if name == "luaL_buffinit" or name == "luaL_buffinitsize" then
      if buffer ~= nil then open[buffer] = true end
      above = 0
    elseif name == "luaL_addvalue" then
      above = math.max(above - 1, 0)
    elseif buffer ~= nil and open[buffer] then
      if above > 0 then
        report(ctx, node, "above-buffer", name .. " finds a value above the open buffer: " ..
          "only luaL_addvalue may, so add it with luaL_addvalue or pop it first")
        above = 0
      end
      if name == "luaL_pushresult" or name == "luaL_pushresultsize" then
        open[buffer] = nil
      end
    elseif name == "lua_settop" then
      above = 0
    elseif next(open) ~= nil and pushes(name) then
      above = above + 1
    end
  end)
end

-- held-across-raise ----------------------------------------------------

local record Held
  name: string
  from: string
  line: integer
end

--- A pointer into a string on the stack, and how many values sit above
--- that string -- or where it left the stack.
local record Pointer
  name: string
  line: integer
  above: integer
  --- The line the string was popped on, or 0 while it is on the stack.
  gone: integer
end

local record State
  held: {string: Held}
  --- The locals of this function, by address: only they can hold.
  locals: {string: boolean}
  --- What has been reported, so each resource is reported once.
  reported: {string: boolean}
  --- The local each status was stored in, to the resource that status
  --- says was never taken when it is a failure.
  status: {string: string}
  --- The locals pointing into a string on the stack, by address.
  strings: {string: Pointer}
end

local function copy(state: State): State
  local held: {string: Held} = {}
  for id, h in pairs(state.held) do held[id] = h end
  local strings: {string: Pointer} = {}
  for id, s in pairs(state.strings) do
    strings[id] = { name = s.name, line = s.line, above = s.above, gone = s.gone }
  end
  return { held = held, locals = state.locals, reported = state.reported,
           status = state.status, strings = strings }
end

--- The local a call's value is given to: the variable it initializes,
--- or the one it is assigned to.
local function receiver(state: State, call: Node): string, string
  local child = call
  local at = call.parent
  while at ~= nil and (at.kind == "ImplicitCastExpr" or at.kind == "CStyleCastExpr"
      or at.kind == "ParenExpr") do
    child = at
    at = at.parent
  end
  if at == nil then return nil, nil end
  if at.kind == "VarDecl" and state.locals[at.id] then
    return at.id, name_of(at)
  end
  if at.kind == "BinaryOperator" and at.text:match("'='$") and at.children[2] == child then
    local target = tree.bare(at.children[1])
    local kind, id, name = tree.referent(target)
    if kind == "Var" and state.locals[id] then return id, name end
  end
  return nil, nil
end

--- The local a call hands a resource back through, as its `slot`th
--- argument (`&statement`), and the local's name.
local function given(call: Node, slot: integer, state: State): string, string
  local argument = call.children[slot + 1]
  if argument == nil then return nil, nil end
  local id = referenced(argument)
  if id == nil or not state.locals[id] then return nil, nil end
  local bare = tree.bare(argument)
  if bare.kind == "UnaryOperator" and #bare.children == 1 then
    bare = tree.bare(bare.children[1])
  end
  local _, _, name = tree.referent(bare)
  return id, name
end

--- The value of an integer constant expression, or nil: `-1`, `-(1)-1`.
local function constant(node: Node): integer
  local bare = tree.bare(node)
  if bare == nil then return nil end
  if bare.kind == "IntegerLiteral" then
    return math.tointeger(tonumber(bare.text:match("(%d+)$")))
  end
  if bare.kind == "UnaryOperator" and bare.text:match("'%-'") and #bare.children == 1 then
    local v = constant(bare.children[1])
    return v ~= nil and -v or nil
  end
  if bare.kind == "BinaryOperator" and #bare.children == 2 then
    local op = bare.text:match("'([^']*)'$")
    local a, b = constant(bare.children[1]), constant(bare.children[2])
    if a == nil or b == nil then return nil end
    if op == "+" then return a + b end
    if op == "-" then return a - b end
  end
  return nil
end

--- The calls that pop the value on top and push nothing, by how many.
local popping: {string: integer} = {
  lua_setfield = 1, lua_seti = 1, lua_rawseti = 1, lua_rawsetp = 1,
  lua_setglobal = 1, lua_setmetatable = 1, lua_setiuservalue = 1, luaL_ref = 1,
  lua_settable = 2, lua_rawset = 2,
}

--- What a call does to the stack above what is already there: how many
--- values it leaves (negative for what it takes), or nil when that cannot
--- be told from the call, and whether it may take everything (a
--- `lua_settop` to a height no constant says).
local function stack_effect(name: string, call: Node): integer, boolean
  local args = arguments(call)
  if name == "lua_settop" then
    local n = args[2] and constant(args[2])
    if n ~= nil and n < 0 then return n + 1, false end
    return nil, true
  elseif name == "lua_callk" or name == "lua_pcallk" then
    local nargs, nresults = args[2] and constant(args[2]), args[3] and constant(args[3])
    if nargs == nil or nresults == nil or nresults < 0 then return nil, false end
    return nresults - nargs - 1, false
  elseif name == "lua_concat" then
    local n = args[2] and constant(args[2])
    if n == nil then return nil, false end
    return 1 - n, false
  elseif name == "lua_next" then
    return nil, false
  elseif popping[name] ~= nil then
    return -popping[name], false
  elseif pushes(name) then
    return 1, false
  end
  return 0, false
end

--- The calls that hand back a pointer into a string on the stack, and
--- whether they push that string themselves.
local string_pointers: {string: boolean} = {
  lua_tolstring = false, luaL_checklstring = false, luaL_optlstring = false,
  luaL_tolstring = true,
}

--- What one call does to the pointers into strings on the stack: moves
--- them up or down, marks the ones whose string it takes, and takes a
--- new one.
local function track_strings(state: State, call: Node, name: string, line: integer)
  local delta, clears = stack_effect(name, call)
  for id, p in pairs(state.strings) do
    if p.gone == 0 then
      if clears then
        p.gone = line
      elseif delta == nil then
        -- What the call does to the stack cannot be told: the pointer
        -- is no longer followed, rather than reported on a guess.
        state.strings[id] = nil
      else
        p.above = p.above + delta
        if p.above < 0 then p.gone = line end
      end
    end
  end
  local pushed = string_pointers[name]
  if pushed == nil then return end
  local id, var = receiver(state, call)
  if id == nil then return end
  if pushed then
    state.strings[id] = { name = var, line = line, above = 0, gone = 0 }
    return
  end
  local index = arguments(call)[2]
  local at = index and constant(index)
  if at ~= nil and at < 0 then
    state.strings[id] = { name = var, line = line, above = -at - 1, gone = 0 }
  else
    -- An argument's slot, or one counted from the bottom, stays.
    state.strings[id] = nil
  end
end

--- Reads what one expression does to `state`: what it takes, releases,
--- hands on, and whether it calls something that can raise while a
--- resource is held.
local function expression(ctx: Context, node: Node, state: State)
  after(node, function(n: Node)
    if n.kind == "CallExpr" then
      local name = tree.callee(n)
      -- Released first: `realloc(buffer, n)` gives up the old buffer
      -- before it takes the new one.
      local released = name ~= nil and (releases[name] or ctx.releasing[name] ~= nil)
      if released then
        for i, argument in ipairs(arguments(n)) do
          local id = referenced(argument)
          if id ~= nil and (releases[name] or ctx.releasing[name][i]) then
            state.held[id] = nil
          end
        end
      end
      if name ~= nil then
        local _, line = tree.place(n)
        track_strings(state, n, name, line or 0)
      end
      if takes_state(n) and not (name ~= nil and quiet[name]) then
        for id, h in pairs(state.held) do
          if not state.reported[id] then
            state.reported[id] = true
            report(ctx, n, "held-across-raise", "holds " .. h.name .. " (from " .. h.from ..
              " on line " .. h.line .. ") across " .. (name or "a call") ..
              ", which can raise and would leak it: hold it in a guard (core/guard.h), " ..
              "or acquire it after everything that allocates")
          end
        end
      end
      local slot: integer = nil
      if name ~= nil then slot = acquires[name] end
      if slot ~= nil then
        local id, var: string, string
        if slot == 0 then
          id, var = receiver(state, n)
        else
          id, var = given(n, slot, state)
          local status = receiver(state, n)
          if id ~= nil and status ~= nil and absent_on_failure[name] then
            state.status[status] = id
          end
        end
        if id ~= nil then
          local _, line = tree.place(n)
          state.held[id] = { name = var or "a resource", from = name as string, line = line or 0 }
        end
      end
    elseif n.kind == "DeclRefExpr" then
      local _, id = tree.referent(n)
      local p = id ~= nil and state.strings[id] or nil
      local assigned = n.parent ~= nil and n.parent.kind == "BinaryOperator"
        and n.parent.text:match("'='$") ~= nil and n.parent.children[1] == n
      if p ~= nil and p.gone ~= 0 and not assigned and not state.reported["s" .. id] then
        state.reported["s" .. id] = true
        report(ctx, n, "string-after-pop", "reads " .. p.name .. " (from line " .. p.line ..
          "), which points into a string that left the stack on line " .. p.gone ..
          ": copy it first, or keep the string on the stack while it is read")
      end
    elseif n.kind == "BinaryOperator" and n.text:match("'='$") then
      -- A pointer given another value points into nothing on the stack.
      local lhs_kind, lhs_id = tree.referent(tree.bare(n.children[1]))
      local rhs = tree.bare(n.children[2])
      if lhs_kind == "Var" and state.strings[lhs_id] ~= nil and not (rhs ~= nil
          and rhs.kind == "CallExpr" and string_pointers[tree.callee(rhs) or ""] ~= nil) then
        state.strings[lhs_id] = nil
      end
      -- A held resource stored anywhere but in a local has been handed
      -- on: to a record, a guard, an array that owns it.
      local id = referenced(n.children[2])
      local target = tree.bare(n.children[1])
      local tkind, tid = tree.referent(target)
      if id ~= nil and state.held[id] ~= nil and not (tkind == "Var" and state.locals[tid]) then
        state.held[id] = nil
      end
    end
  end)
end

--- The local a condition says is absent on its true side, and the one
--- it says is absent on its false side.
local function tested(cond: Node, state: State): string, string
  local bare = tree.bare(cond)
  if bare == nil then return nil, nil end
  if bare.kind == "UnaryOperator" and bare.text:match("'!'") then
    return referenced(bare.children[1]), nil
  end
  if bare.kind ~= "BinaryOperator" or #bare.children ~= 2 then
    if bare.kind == "DeclRefExpr" then return nil, referenced(bare) end
    return nil, nil
  end
  local op = bare.text:match("'([^']*)'$")
  local left, right = bare.children[1], bare.children[2]
  -- A failed status says what the call that returned it never took.
  if op == "!=" or op == "==" then
    for _, side in ipairs({ left, right }) do
      local b = tree.bare(side)
      local absent: string = nil
      if b.kind == "CallExpr" then
        local name = tree.callee(b)
        if name ~= nil and absent_on_failure[name] then
          absent = given(b, acquires[name], state)
        end
      else
        local id = referenced(b)
        if id ~= nil then absent = state.status[id] end
      end
      if absent ~= nil then
        if op == "!=" then return absent, nil end
        return nil, absent
      end
    end
  end
  local function nothing(n: Node): boolean
    local b = tree.bare(n)
    if b == nil then return false end
    if b.kind == "CStyleCastExpr" and b.text:find("<NullToPointer>", 1, true) then return true end
    if b.kind == "CStyleCastExpr" and #b.children == 1 then b = tree.bare(b.children[1]) end
    return b ~= nil and b.kind == "IntegerLiteral" and b.text:match(" 0$") ~= nil
  end
  local id: string = nil
  if nothing(right) then
    id = referenced(left)
  elseif nothing(left) then
    id = referenced(right)
  end
  if id == nil then return nil, nil end
  if op == "==" or op == "<" then return id, nil end
  if op == "!=" or op == ">=" then return nil, id end
  return nil, nil
end

local statement: function(Context, Node, State): boolean

local function merge(into: State, from: {State})
  local held: {string: Held} = {}
  local strings: {string: Pointer} = {}
  for _, s in ipairs(from) do
    for id, h in pairs(s.held) do held[id] = h end
    for id, p in pairs(s.strings) do
      local seen = strings[id]
      if seen == nil then
        strings[id] = { name = p.name, line = p.line, above = p.above, gone = p.gone }
      else
        -- Gone on either side is gone; otherwise the nearer the top.
        seen.gone = math.max(seen.gone, p.gone)
        seen.above = math.min(seen.above, p.above)
      end
    end
  end
  into.held = held
  into.strings = strings
end

statement = function(ctx: Context, node: Node, state: State): boolean
  local kind = node.kind
  if kind == "CompoundStmt" then
    for _, child in ipairs(node.children) do
      if statement(ctx, child, state) then return true end
    end
    return false
  elseif kind == "IfStmt" then
    local n = #node.children
    local cond = node.children[1]
    local yes = node.children[2]
    local no: Node = n >= 3 and node.children[3] or nil
    expression(ctx, cond, state)
    local absent_yes, absent_no = tested(cond, state)
    local a = copy(state)
    if absent_yes ~= nil then a.held[absent_yes] = nil end
    local ended_a = statement(ctx, yes, a)
    local b = copy(state)
    if absent_no ~= nil then b.held[absent_no] = nil end
    local ended_b = no ~= nil and statement(ctx, no, b)
    local open: {State} = {}
    if not ended_a then open[#open + 1] = a end
    if not ended_b then open[#open + 1] = b end
    merge(state, open)
    return ended_a and ended_b
  elseif kind == "ForStmt" or kind == "WhileStmt" or kind == "DoStmt" or kind == "SwitchStmt" then
    local body = copy(state)
    for _, child in ipairs(node.children) do
      statement(ctx, child, body)
    end
    merge(state, { state, body })
    return false
  elseif kind == "ReturnStmt" then
    for _, child in ipairs(node.children) do
      expression(ctx, child, state)
      after(child, function(n: Node)
        local id = n.kind == "DeclRefExpr" and referenced(n)
        if id then state.held[id as string] = nil end
      end)
    end
    return true
  elseif kind == "GotoStmt" then
    return true
  elseif kind == "DeclStmt" then
    for _, decl in ipairs(node.children) do
      if decl.kind == "VarDecl" and not decl.text:find(" static", 1, true) then
        state.locals[decl.id] = true
      end
      expression(ctx, decl, state)
    end
    return false
  elseif kind == "LabelStmt" or kind == "CaseStmt" or kind == "DefaultStmt" then
    for _, child in ipairs(node.children) do
      if statement(ctx, child, state) then return true end
    end
    return false
  elseif kind == "<<<NULL>>>" or kind == "NullStmt" or kind == "BreakStmt"
      or kind == "ContinueStmt" then
    return false
  end
  expression(ctx, node, state)
  local bare = tree.bare(node)
  return bare ~= nil and bare.kind == "CallExpr" and ends(bare)
end

-- over a whole file ----------------------------------------------------

local record Function
  name: string
  params: {Node}
  body: Node
  --- Its definition.
  decl: Node
  --- Its type as written: `int (lua_State *)`.
  type: string
  --- Whether it is `static`, and whether it is `inline`.
  static: boolean
  inline: boolean
  --- A declaration of it in a header, or nil when no header declares it.
  prototype: Node
end

--- Whether a function declaration says `static`, or `inline`: the words
--- after its type.
local function storage(decl: Node): boolean, boolean
  local words = decl.text:match("'([^']*)$") or ""
  return words:find("static", 1, true) ~= nil, words:find("inline", 1, true) ~= nil
end

local function functions(decls: {Node}): {Function}
  -- The first header declaration of each function, by name.
  local prototypes: {string: Node} = {}
  for _, decl in ipairs(decls) do
    if decl.kind == "FunctionDecl" and String.ends_with(decl.file or "", ".h") then
      local name = name_of(decl)
      if name ~= nil and prototypes[name] == nil then prototypes[name] = decl end
    end
  end
  local out: {Function} = {}
  for _, decl in ipairs(decls) do
    if decl.kind == "FunctionDecl" then
      local params: {Node} = {}
      local body: Node
      for _, child in ipairs(decl.children) do
        if child.kind == "ParmVarDecl" then params[#params + 1] = child end
        if child.kind == "CompoundStmt" then body = child end
      end
      if body ~= nil then
        local name = name_of(decl)
        local static, inline = storage(decl)
        local prototype = prototypes[name]
        if prototype == decl then prototype = nil end
        out[#out + 1] = {
          name = name, params = params, body = body, decl = decl,
          type = tree.canonical_type(decl) or "", static = static, inline = inline,
          prototype = prototype,
        }
      end
    end
  end
  return out
end

--- Which of its parameters each function releases, directly.
local function releasing(fns: {Function}): {string: {integer: boolean}}
  local out: {string: {integer: boolean}} = {}
  for _, fn in ipairs(fns) do
    local index: {string: integer} = {}
    for i, param in ipairs(fn.params) do index[param.id] = i end
    after(fn.body, function(n: Node)
      local name = n.kind == "CallExpr" and tree.callee(n)
      if name and releases[name as string] then
        for _, argument in ipairs(arguments(n)) do
          local i = index[referenced(argument) or ""]
          if i ~= nil then
            out[fn.name] = out[fn.name] or {}
            out[fn.name][i] = true
          end
        end
      end
    end)
  end
  return out
end

-- constant-return, pass-fail-int, true-alone ---------------------------

--- Whether a function is a `lua_CFunction`: its `int` is how many values
--- it leaves on the stack, not a status.
local function lua_facing(fn: Function): boolean
  return fn.type == "int (lua_State *)" or fn.type == "int (struct lua_State *)"
end

--- Whether a function is handed the state first: its `int` may be a
--- count of values it left, as a lua_CFunction's is.
local function state_first(fn: Function): boolean
  return fn.type:match("^int %(lua_State %*") ~= nil
    or fn.type:match("^int %(struct lua_State %*") ~= nil
end

--- Every `return` in a body.
local function returns_in(body: Node): {Node}
  local out: {Node} = {}
  after(body, function(n: Node)
    if n.kind == "ReturnStmt" then out[#out + 1] = n end
  end)
  return out
end

--- The operators whose value is a truth.
local truths: {string: boolean} = {
  ["=="] = true, ["!="] = true, ["<"] = true, [">"] = true, ["<="] = true,
  [">="] = true, ["&&"] = true, ["||"] = true,
}

--- What an expression may be read as a truth through: the functions of
--- the file that return only truths, and the locals of the function
--- that are only ever given one, by address.
local record Truths
  functions: {string: boolean}
  locals: {string: boolean}
end

--- Whether an expression is a truth: the literal 0 or 1, a comparison,
--- a logical operator, a value of type bool, a call of a function that
--- returns only truths, or a local only ever given one.
local function truth(node: Node, known: Truths): boolean
  local bare = tree.bare(node)
  if bare == nil then return false end
  local v = constant(bare)
  if v ~= nil then return v == 0 or v == 1 end
  if bare.kind == "BinaryOperator" and truths[bare.text:match("'([^']*)'$") or ""] then
    return true
  end
  if bare.kind == "UnaryOperator" and bare.text:find("'!'", 1, true) ~= nil then
    return true
  end
  if bare.kind == "CallExpr" and known.functions[tree.callee(bare) or ""] then
    return true
  end
  local kind, id = tree.referent(bare)
  if kind == "Var" and known.locals[id] then return true end
  local t = tree.canonical_type(bare)
  return t == "_Bool" or t == "bool"
end

--- The locals of `body` given only truths: at their declaration, and at
--- every assignment.
local function truth_locals(body: Node, known: Truths): {string: boolean}
  local offered: {string: boolean} = {}
  local refused: {string: boolean} = {}
  after(body, function(n: Node)
    if n.kind == "VarDecl" then
      local init = n.children[#n.children]
      if init ~= nil and init.kind ~= "ParmVarDecl" and truth(init, known) then
        offered[n.id] = true
      else
        refused[n.id] = true
      end
    elseif n.kind == "BinaryOperator" and n.text:match("'='$") then
      local kind, id = tree.referent(tree.bare(n.children[1]))
      if kind == "Var" and not truth(n.children[2], known) then refused[id] = true end
    elseif n.kind == "CompoundAssignOperator" or (n.kind == "UnaryOperator"
        and (n.text:find("'++'", 1, true) or n.text:find("'--'", 1, true)
          or n.text:find("'&'", 1, true))) then
      -- Changed in place, or handed out by address to be written
      -- anything at all: `fetch(&status)`.
      local kind, id = tree.referent(tree.bare(n.children[1]))
      if kind == "Var" then refused[id] = true end
    end
  end)
  local out: {string: boolean} = {}
  for id in pairs(offered) do
    if not refused[id] then out[id] = true end
  end
  return out
end

--- Whether every `return` of `fn` returns a truth, of which there is at
--- least one.
local function returns_truths(fn: Function, known: Truths): boolean
  local returns = returns_in(fn.body)
  if #returns == 0 then return false end
  local mine: Truths = { functions = known.functions, locals = truth_locals(fn.body, known) }
  for _, r in ipairs(returns) do
    if #r.children ~= 1 or not truth(r.children[1], mine) then return false end
  end
  return true
end

--- The functions of a file that return `int` and only truths, found
--- until no more are: a helper that returns 0 on every failure makes the
--- function returning it one too.
local function truthful(fns: {Function}): {string: boolean}
  local known: Truths = { functions = {}, locals = {} }
  local changed = true
  while changed do
    changed = false
    for _, fn in ipairs(fns) do
      if not known.functions[fn.name] and fn.type:match("^int %(") and not lua_facing(fn)
          and returns_truths(fn, known) then
        known.functions[fn.name] = true
        changed = true
      end
    end
  end
  return known.functions
end

--- A function of external linkage whose every `return` returns one
--- constant is a function that returns nothing; one declared in a header
--- to return `int` that returns only truths is a pass or a fail, which
--- is a `bool`.
local function returned_constant(ctx: Context, fn: Function)
  if fn.static or fn.name == "main" or state_first(fn) then return end
  local returns = returns_in(fn.body)
  if #returns == 0 then return end
  local same: integer = nil
  local all_same = true
  for _, r in ipairs(returns) do
    local v = #r.children == 1 and constant(r.children[1]) or nil
    if v == nil or (same ~= nil and v ~= same) then all_same = false end
    same = same or v
  end
  if all_same then
    report(ctx, fn.decl, "constant-return", fn.name .. " returns " .. same ..
      " on every path, which tells its caller nothing: return void")
  elseif fn.prototype ~= nil and fn.type:match("^int %(") and ctx.truthful[fn.name] then
    report(ctx, fn.decl, "pass-fail-int", fn.name .. " returns only 0, 1 or a truth, " ..
      "a pass or a fail: return bool (<stdbool.h>), true for success, rather than int")
  end
end

--- Whether a `return` leaves `true` alone on the stack: `return
--- cosmic_ok(L)`, or `return 1` just after `lua_pushboolean(L, 1)`.
local function returns_true_alone(r: Node): boolean
  local value = #r.children == 1 and tree.bare(r.children[1]) or nil
  if value == nil then return false end
  if value.kind == "CallExpr" and tree.callee(value) == "cosmic_ok" then return true end
  if constant(value) ~= 1 then return false end
  local block = r.parent
  if block == nil or block.kind ~= "CompoundStmt" then return false end
  local before: Node = nil
  for i, child in ipairs(block.children) do
    if child == r then before = block.children[i - 1] break end
  end
  local call = before and tree.bare(before)
  if call == nil or call.kind ~= "CallExpr" or tree.callee(call) ~= "lua_pushboolean" then
    return false
  end
  local flag = arguments(call)[2]
  local v = flag and constant(flag)
  return v ~= nil and v ~= 0
end

--- A `lua_CFunction` that, whenever it returns, returns `true` and
--- nothing else tells its caller nothing: it returns no values.
local function true_alone(ctx: Context, fn: Function)
  -- A header's inline helper is a piece of a binding's return, such as
  -- cosmic_ok (core/fail.h), not a binding.
  if not lua_facing(fn) or fn.inline then return end
  local any = false
  for _, r in ipairs(returns_in(fn.body)) do
    local value = #r.children == 1 and tree.bare(r.children[1]) or nil
    if value ~= nil and value.kind == "CallExpr" and ends(value) then
      -- A raise is no return.
    elseif returns_true_alone(r) then
      any = true
    else
      return
    end
  end
  if any then
    report(ctx, fn.decl, "true-alone", fn.name .. " returns true and nothing else " ..
      "on every path, which tells its caller nothing: return no values")
  end
end

-- returned-shape -------------------------------------------------------

--- The failure shape each function of a file returns in: "fail" for one
--- whose every shaped `return` is `cosmic_fail` (nil, error, errno) or a
--- helper of that shape, "effect" for `cosmic_fail_effect`, "ok" for
--- `cosmic_ok`; a function with no shaped return, or more than one
--- shape, has none. Found until no more are, so a wrapper of a wrapper
--- is seen through.
local function failure_shapes(fns: {Function}): {string: string}
  local shapes: {string: string} = {
    cosmic_fail = "fail", cosmic_fail_effect = "effect", cosmic_ok = "ok",
  }
  local changed = true
  while changed do
    changed = false
    for _, fn in ipairs(fns) do
      if shapes[fn.name] == nil and not fn.name:match("^cosmic_sys_") then
        local shape: string = nil
        local mixed = false
        for _, r in ipairs(returns_in(fn.body)) do
          local value = #r.children == 1 and tree.bare(r.children[1]) or nil
          local helper = value ~= nil and value.kind == "CallExpr" and tree.callee(value) or nil
          local this = helper ~= nil and shapes[helper] or nil
          if this ~= nil then
            if shape ~= nil and shape ~= this then mixed = true end
            shape = shape or this
          end
        end
        if shape ~= nil and not mixed then
          shapes[fn.name] = shape
          changed = true
        end
      end
    end
  end
  return shapes
end

--- Every `return` of a count in a binding of the syscall table, against
--- what the binding is declared to return. A count is what a binding
--- returns only when it returns a literal: `return cosmic_fail(...)` is
--- the shape fail.h makes.
local function returned_shape(ctx: Context, name: string, body: Node,
                              declared: {string: rules.Declared})
  local call = name:match("^cosmic_sys_(.+)$")
  local d = call ~= nil and declared[call] or nil
  if d == nil then return end
  after(body, function(n: Node)
    if n.kind ~= "ReturnStmt" or #n.children ~= 1 then return end
    local value = tree.bare(n.children[1])
    local helper = value ~= nil and value.kind == "CallExpr" and tree.callee(value) or nil
    local shape = helper ~= nil and ctx.shapes[helper] or nil
    local through = helper ~= nil and ctx.shapes[helper] ~= nil and not helper:match("^cosmic_")
      and " (through " .. helper .. ")" or ""
    if d.fallible and d.effect and shape == "fail" then
      report(ctx, n, "failure-shape", "cosmic.sys." .. call .. " is declared an effect " ..
        "(boolean), whose failure is false, a message and an errno: return " ..
        "cosmic_fail_effect, not cosmic_fail" .. through .. " (core/fail.h)")
    elseif d.fallible and not d.effect and (shape == "effect" or shape == "ok") then
      report(ctx, n, "failure-shape", "cosmic.sys." .. call .. " is declared to return " ..
        "a value, whose failure is nil, a message and an errno, and never a bare true: " ..
        "return the value, or cosmic_fail" .. through .. " (core/fail.h)")
    end
    local count = constant(n.children[1])
    if count == nil then return end
    if count > d.count then
      report(ctx, n, "returned-shape", "returns " .. count .. " values where cosmic.sys." ..
        call .. " is declared to return " .. d.count .. " (core/syscalls.h)")
    elseif d.fallible and count == 2 then
      report(ctx, n, "returned-shape", "returns 2 values where a failure of cosmic.sys." ..
        call .. " is nil or false, a message and an errno: return cosmic_fail or " ..
        "cosmic_fail_effect (core/fail.h)")
    end
  end)
end

-- single-file ----------------------------------------------------------

--- What the translation unit `file`, whose own declarations are `decls`,
--- defines for others and refers to.
function rules.unit(decls: {Node}, file: string,
                    declared?: {string: rules.Declared}): rules.Unit
  local u: rules.Unit = { file = file, defines = {}, refers = {} }
  for _, fn in ipairs(functions(decls)) do
    -- A binding's declaration in core/syscalls.h carries the annotation
    -- the Teal declaration is made from, whoever refers to it.
    local call = fn.name:match("^cosmic_sys_(.+)$")
    local binding = call ~= nil and declared ~= nil and declared[call] ~= nil
    if fn.prototype ~= nil and not fn.static and not fn.inline and not binding then
      u.defines[fn.name] = fn.prototype
    end
  end
  for _, decl in ipairs(decls) do
    after(decl, function(n: Node)
      local kind, _, name = tree.referent(n)
      if kind == "Function" then u.refers[name] = true end
    end)
  end
  return u
end

--- The functions a header declares that no translation unit but the one
--- defining it refers to, over `units`, every translation unit of a tree:
--- such a function is the defining file's own, and belongs in it as
--- `static`, out of the header. What `exempt` excuses is left out.
function rules.single_file(units: {rules.Unit}): {rules.Finding}
  local out: {rules.Finding} = {}
  for _, u in ipairs(units) do
    for name, prototype in pairs(u.defines) do
      local elsewhere = false
      for _, other in ipairs(units) do
        if other.file ~= u.file and other.refers[name] then
          elsewhere = true
          break
        end
      end
      local file, line = tree.place(prototype)
      file = file or u.file
      if not elsewhere and rules.exempt[file .. " " .. name .. " single-file"] == nil then
        out[#out + 1] = {
          file = file, line = line or 0, rule = "single-file", within = name,
          message = name .. " is used only by " .. u.file .. ", which defines it: " ..
            "make it static there and take it out of the header",
        }
      end
    end
  end
  table.sort(out, function(a: rules.Finding, b: rules.Finding): boolean
    if a.file ~= b.file then return a.file < b.file end
    return a.line < b.line
  end)
  return out
end

--- Every finding in `decls`, a translation unit's own declarations, that
--- `exempt` does not excuse, sorted by place. `declared` is what
--- core/syscalls.h declares each binding returns, by the binding's name.
function rules.check(decls: {Node}, file: string,
                     declared?: {string: rules.Declared}): {rules.Finding}
  local fns = functions(decls)
  local findings: {rules.Finding} = {}
  local ctx: Context = { file = file, within = "", findings = findings,
                         releasing = releasing(fns), truthful = truthful(fns),
                         shapes = failure_shapes(fns) }
  for _, fn in ipairs(fns) do
    ctx.within = fn.name
    narrowed(ctx, fn.body)
    above_buffer(ctx, fn.body, fn.params)
    returned_shape(ctx, fn.name, fn.body, declared or {})
    returned_constant(ctx, fn)
    true_alone(ctx, fn)
    local state: State = { held = {}, locals = {}, reported = {}, status = {}, strings = {} }
    statement(ctx, fn.body, state)
  end
  local out: {rules.Finding} = {}
  for _, f in ipairs(findings) do
    if rules.exempt[f.file .. " " .. f.within .. " " .. f.rule] == nil then
      out[#out + 1] = f
    end
  end
  table.sort(out, function(a: rules.Finding, b: rules.Finding): boolean
    if a.file ~= b.file then return a.file < b.file end
    if a.line ~= b.line then return a.line < b.line end
    return a.rule < b.rule
  end)
  return out
end

return rules
