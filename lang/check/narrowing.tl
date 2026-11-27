--- The narrowing of the flow: the facts a test, a comparison or a tie proves on each edge out of a condition.

local Ast = require("lang.ast")
local Flow = require("lang.flow")
local Lexer = require("lang.lexer")
local Types = require("lang.types")
local Context = require("lang.check.context")
local Naming = require("lang.check.naming")
local Lookup = require("lang.check.members")
local TableLiterals = require("lang.check.table_literals")
local Fields = require("lang.check.fields")
local Places = require("lang.check.places")
local Writes = require("lang.check.writes")
local Tests = require("lang.check.tests")
local Operands = require("lang.check.operands")
local type Type = Types.Type
local type Ctx = Context.Ctx
local accepts = Context.accepts
local base_of = Context.base_of
local below = Context.below
local id_key = Context.id_key
local is_bool = Context.is_bool
local members_of = Context.members_of
local nilable = Context.nilable
local peel = Context.peel
local quoted = Context.quoted
local report = Naming.report
local show = Context.show
local subject = Context.subject
local text_of = Context.text_of
local tq = Context.tq
local view = Context.view
local type Place = Places.Place
local condition_kind = Operands.condition_kind
local current = Places.current
local field_unknown = Fields.field_unknown
local join = TableLiterals.join
local key_names = Fields.key_names
local key_ok = Fields.key_ok
local member_types = Fields.member_types
local members_index = Lookup.members_index
local place_of = Places.place_of
local put_in = Lookup.put_in
local readable = TableLiterals.readable

--- The flow states a test of a place leaves where it holds and where it fails, and the note that a test narrowed.
local record Narrowing
end

--- Checks the condition `node`.
function Narrowing.condition(ctx: Ctx, node: Ast.Exp): Type
  -- Each operand of `not`, `and` and `or` of a condition is only asked whether it holds: a field read there is a probe.
  local function mark_probes(operand: Ast.Exp)
    local at = peel(operand)
    if (at.kind == "Field") then
      ctx.probes[at.id] = true
    elseif (at.kind == "Unary") and at.op == "not" then
      mark_probes(at.operand)
    elseif (at.kind == "Binary") and (at.op == "and" or at.op == "or") then
      mark_probes(at.left)
      mark_probes(at.right)
    end
  end
  mark_probes(node)
  local t = ctx.walk.expr(ctx, node, nil)
  -- Of `a and b` and `a or b`, the left is checked where it is walked, and the right is the operand whose value is asked:
  -- so `ok and why == nil` of an effect's `true?` holds, and `ok and flag` of a `boolean?` flag is refused.
  local asked, asked_type = node, t
  local at = peel(node)
  while (at.kind == "Binary") and (at.op == "and" or at.op == "or") and asked_type.tag ~= "invalid" do
    local right = ctx.right_types[at.id]
    if right == nil then
      break
    end
    asked, asked_type = at.right, right
    at = peel(at.right)
  end
  local _ = condition_kind(ctx, asked, asked_type)
  return t
end

local LUA_KINDS <const>: {string} = { "nil", "number", "string", "boolean", "table", "function", "userdata" }

--- Notes that the read `node` of a place declared `declared` has the type `narrowed`, for a run that checks it.
function Narrowing.note_narrowed(ctx: Ctx, node: Ast.Node, declared: Type, narrowed: Type)
  if ctx.quiet > 0 then
    return
  end
  local after = Tests.kinds_of(ctx, narrowed)
  if after == nil then
    return
  end
  local before = Tests.kinds_of(ctx, declared)
  local taken: mut {string} = {}
  for _, kind in ipairs(LUA_KINDS) do
    if after[kind] ~= true and (before == nil or before[kind] == true) then
      taken[#taken + 1] = kind
    end
  end
  -- An enum, a class or a tag the test narrowed to: what the declared type left a string or a table to be.
  local strings = Tests.enum_strings(ctx, narrowed)
  local was = Tests.enum_strings(ctx, declared)
  if strings ~= nil and was ~= nil and table.concat(strings, "\0") == table.concat(was, "\0") then
    strings = nil
  end
  local classes: {string}? = nil
  local tag: string? = nil
  local tags: {string}? = nil
  local now = Tests.table_members(ctx, narrowed)
  local old = Tests.table_members(ctx, declared)
  if now ~= nil and #now > 0 and (old == nil or #old > #now) then
    local names: mut {string} = {}
    for _, m in ipairs(now) do
      local m_body = if (m.tag == "named") then m.decl.body else nil end
      if (m.tag == "named") and m.decl.kind == "class" and #m.decl.names == 1 and m.decl.module == ctx.input.module and not m.value and
          (m_body == nil or m_body.schema == nil) then
        names[#names + 1] = m.decl.name
      end
    end
    if #names == #now then
      classes = names
    end
    if old ~= nil then
      tag, tags = Tests.tag_field(ctx, now)
      if tag ~= nil then
        local field = tag
        for _, m in ipairs(old) do
          if Tests.tag_values(ctx, m, field) == nil then
            tag, tags = nil, nil
          end
        end
      end
    end
  end
  if #taken == 0 and strings == nil and classes == nil and tag == nil then
    return
  end
  local b = base_of(node)
  local tokens = ctx.tokens
  local first, last = b.first, math.max(b.first, b.last)
  local start = Lexer.offset(tokens, first)
  ctx.narrowed[b.id] = {
    id = b.id, offset = start, length = math.max(0, Lexer.stop(tokens, last) - start), text = text_of(ctx, node),
    taken = taken, strings = strings, classes = classes, tag = tag, tags = tags,
  }
end

--- `f` where the place is known to have the type `t`. A type no value has makes the edge unreachable, with the place
--- kept at it so that the code there reads it as `never` and reports nothing of it.
function Narrowing.narrowed_flow(f: Flow.State, place: Place, t: Type): Flow.State
  if t.tag == "never" then
    return Flow.dead(Flow.narrow(f, place.key, t, place.declared))
  end
  return Flow.narrow(f, place.key, t, place.declared)
end

--- `f` where a test that the place is of type `t` holds. A test no value of the place can pass has been refused for
--- that (`compare_disjoint`, `is_disjoint`), so what follows it keeps what was known and reports nothing more.
function Narrowing.when_true(f: Flow.State, place: Place, t: Type): Flow.State
  if t.tag == "never" then
    return f
  end
  return Flow.narrow(f, place.key, t, place.declared)
end

--- `object[key]` read: the element of an array or the value of a map as an optional (an index read may be nil, unless a
--- length test shows the array has the element: [`Tests.length_proves`]), the fields a literal or enum key names in a record.
function Narrowing.index_read(ctx: Ctx, node: Ast.Index, object: Type): Type
  local store = ctx.store
  local t = readable(ctx, node.object, object, "it has no elements to read")
  if t == nil then
    local _ = ctx.walk.expr(ctx, node.key, nil)
    return ctx.invalid
  end
  if (t.tag == "array") then
    local k = ctx.walk.expr(ctx, node.key, store.integer)
    local _ = key_ok(ctx, node.key, k, store.integer, subject(ctx, node.object))
    local element = t.element
    if not t.mut then
      element = view(store, element)
    end
    local maybe = store:optional(element)
    local dense = Tests.dense(ctx, t.element)
    if dense and Tests.length_proves(ctx, node.object, node.key) then
      -- Checked at run time like a narrowed local: a length fact has no other check.
      Narrowing.note_narrowed(ctx, node, maybe, element)
      return element
    end
    if dense and below(ctx, k, store.integer) and Writes.counted_read(ctx, node) then
      Narrowing.note_narrowed(ctx, node, maybe, element)
      return element
    end
    return maybe
  elseif (t.tag == "map") then
    ctx.map_reads[node.id] = true
    local k = ctx.walk.expr(ctx, node.key, t.key)
    local _ = key_ok(ctx, node.key, k, t.key, subject(ctx, node.object))
    local value = t.value
    if not t.mut then
      value = view(store, value)
    end
    return store:optional(value)
  elseif (t.tag == "named") and (t.decl.kind == "record" or t.decl.kind == "class" or t.decl.kind == "userdata") then
    local k = ctx.walk.expr(ctx, node.key, nil)
    if k.tag == "invalid" then
      return ctx.invalid
    end
    local names = key_names(node.key, k)
    if names == nil then
      local index = members_index(ctx, t.decl, t.value)
      local array_part = index ~= nil and index.array or nil -- checked: and_ternary
      if array_part ~= nil and below(ctx, k, store.integer) then
        return store:optional(put_in(ctx, t, array_part))
      end
      local body = t.decl.body
      if not t.value and (Types.inferred_record(t.decl) or Types.shape_record(t.decl)) and body ~= nil and
          below(ctx, k, store.string) then
        -- A record inferred for a literal, or one in braces, reads as a map of strings to its fields: a key it lacks
        -- reads nil.
        local values: mut {Type} = {}
        for _, f in ipairs(body.fields) do
          values[#values + 1] = store:non_nil(f.type)
        end
        local value = join(ctx, values)
        if value ~= nil then
          return store:optional(value)
        end
        report(ctx, "record_index", node, subject(ctx, node.key) .. " is " .. tq(ctx, k) .. ", and the fields of " ..
            tq(ctx, t) .. " have no common type for a read by a key",
          "write the field (`" .. text_of(ctx, node.object) .. ".field`), or declare the literal a map `{string: T}` " ..
            "where it is made", { show(ctx, k) })
        return ctx.invalid
      end
      report(ctx, "record_index", node, subject(ctx, node.key) .. " is " .. tq(ctx, k) .. ", which names no field of " ..
          tq(ctx, t) .. ": a record is not a map",
        "write the field (`" .. text_of(ctx, node.object) .. ".field`), or index a `{K: V}`", { show(ctx, k) })
      return ctx.invalid
    end
    local types: mut {Type} = {}
    for _, name in ipairs(names) do
      local list = member_types(ctx, t, name)
      if list == nil or list[1].method then -- checked: nil_not_allowed
        field_unknown(ctx, node.key, t, name)
        return ctx.invalid
      end
      Writes.note_move(ctx, node, t, name)
      types[#types + 1] = put_in(ctx, t, list[1].type) -- checked: nil_not_allowed
    end
    return store:union(types)
  end
  local _ = ctx.walk.expr(ctx, node.key, nil)
  report(ctx, "not_indexable", node, subject(ctx, node.object) .. " is " .. tq(ctx, t) .. ", which has no elements to index",
    "index an array, a map or a record", { show(ctx, t) })
  return ctx.invalid
end

--- The edges of `field == "lit"` for a field that tells the members of a union of records apart. The true edge keeps
--- the members whose tag enum still has the value, each with all its values. The false edge notes that the tag is not
--- the value, and drops a member once every value of its enum has been noted on the path, so that a chain of tests
--- over the values of a member leaves the rest.
function Narrowing.tag_edges(ctx: Ctx, f: Flow.State, field: Ast.Field, lit: string): Flow.State, Flow.State
  local p = place_of(ctx, f, field.object)
  if p == nil then
    return f, f
  end
  local store = ctx.store
  -- The key of the fact that a test showed the tag of the place is not `value` in the field being tested while it is the
  -- member `m`, told by its place among the members of the declared type. The fact is a path from the place, so an
  -- assignment to the place or to what it is read from takes it away, and a join keeps it only where both paths have it.
  -- A member that is not one of the declared type's (a narrowing is a union of the declared members, so none is believed
  -- to be) has no key, "": nothing is noted of it and nothing is read, so it stays in both branches and keeps every value.
  local whole = members_of(store, store:non_nil(p.declared))
  -- The place of each by its id (a map is not keyed by a type), made once for the walks over the members below.
  local placed: mut {integer: integer} = {}
  for i, member in ipairs(whole) do
    if placed[member.id] == nil then
      placed[member.id] = i
    end
  end
  local function tag_key(m: Type, value: string): string
    local i = placed[m.id]
    if i == nil or whole[i] ~= m then
      return ""
    end
    return p.key .. ".#" .. tostring(i) .. "." .. field.name .. "=" .. value
  end
  local members = members_of(store, store:non_nil(current(f, p)))
  local yes: mut {Type} = {}
  local no: mut {Type} = {}
  local noted: mut {Type} = {}
  for _, m in ipairs(members) do
    local values = Tests.tag_values(ctx, m, field.name)
    if values == nil then
      yes[#yes + 1] = m
      no[#no + 1] = m
    else
      local left = 0
      local has = false
      for _, v in ipairs(values) do
        local key = tag_key(m, v)
        if key == "" or f.facts[key] == nil then
          left = left + 1
          has = has or v == lit
        end
      end
      if has then
        yes[#yes + 1] = m
      end
      if not has or left > 1 then
        no[#no + 1] = m
      end
      if has and left > 1 and tag_key(m, lit) ~= "" then
        noted[#noted + 1] = m
      end
    end
  end
  local after = Narrowing.narrowed_flow(f, p, store:union(no))
  for _, m in ipairs(noted) do
    after = Flow.narrow(after, tag_key(m, lit), store.boolean, store.integer)
  end
  return Narrowing.when_true(f, p, store:union(yes)), after
end

--- The edges of `x == "lit"` for a place `x` whose type holds strings: each edge has it as [`Tests.by_literal`] leaves it.
function Narrowing.literal_edges(ctx: Ctx, yes: Flow.State, no: Flow.State, operand: Ast.Node, lit: string): Flow.State, Flow.State
  local p = place_of(ctx, yes, operand)
  local q = place_of(ctx, no, operand)
  if p == nil or q == nil then
    return yes, no
  end
  local before = current(yes, p)
  if Tests.enum_strings(ctx, before) == nil and not below(ctx, ctx.store.string, before) then
    return yes, no
  end
  return Narrowing.when_true(yes, p, Tests.by_literal(ctx, before, lit, true)),
    Narrowing.narrowed_flow(no, q, Tests.by_literal(ctx, current(no, q), lit, false))
end

--- The edges of `type(x) == "kind"`.
function Narrowing.type_edges(ctx: Ctx, f: Flow.State, call: Ast.Call, kind: string): Flow.State, Flow.State
  local callee = call.callee
  local subject_arg = call.args[1]
  if not ((callee.kind == "Name")) or callee.binding ~= nil or callee.text ~= "type" or #call.args ~= 1 or subject_arg == nil then
    return f, f
  end
  local p = place_of(ctx, f, subject_arg)
  if p == nil then
    return f, f
  end
  local cur = current(f, p)
  return Narrowing.narrowed_flow(f, p, Tests.by_kind(ctx, cur, kind, true)), Narrowing.narrowed_flow(f, p, Tests.by_kind(ctx, cur, kind, false))
end

--- The edges of `a == b`.
function Narrowing.compare_edges(ctx: Ctx, f: Flow.State, node: Ast.Binary): Flow.State, Flow.State
  local l, r = peel(node.left), peel(node.right)
  local yes, no = f, f
  if (r.kind == "Nil") or (l.kind == "Nil") then
    local p = place_of(ctx, f, (r.kind == "Nil") and l or r) -- checked: and_ternary
    if p ~= nil then
      local cur = current(f, p)
      yes, no = Narrowing.when_true(f, p, Tests.nil_of(ctx, cur)), Narrowing.narrowed_flow(f, p, Tests.not_nil_of(ctx, cur))
      -- `v == nil` of the first local of a tie told by `nil` selects the lists of the others.
      local tied_present, tied_nil = Narrowing.tie_edges(ctx, f, if r.kind == "Nil" then l else r end, no, yes, true)
      if tied_present ~= nil and tied_nil ~= nil then
        yes, no = tied_nil, tied_present
      end
    else
      no = Tests.has_element(ctx, f, if r.kind == "Nil" then l else r end)
    end
  elseif (r.kind == "Boolean") or (l.kind == "Boolean") then
    -- What equals `true` or `false` is not nil, which is all the test shows: what differs from one may be the other or
    -- nil. It is the test `condition_type` sends an optional boolean to, in a condition and in an `assert`. The first
    -- local of a tie (`ok == true`) holds only `true` or `false`, so there the test selects the tie's lists.
    local operand = if r.kind == "Boolean" then l else r end
    local tied_yes, tied_no = Narrowing.tie_edges(ctx, f, operand, nil, nil, false)
    if tied_yes ~= nil and tied_no ~= nil then
      local value = true
      if r.kind == "Boolean" then
        value = r.value
      elseif l.kind == "Boolean" then
        value = l.value
      end
      if value then
        yes, no = tied_yes, tied_no
      else
        yes, no = tied_no, tied_yes
      end
    else
      local p = place_of(ctx, f, operand)
      if p ~= nil then
        local cur = current(f, p)
        yes = Narrowing.when_true(f, p, Tests.not_nil_of(ctx, cur))
        -- What differs from `false` is no `false`: `T | false` is `T` there, as `boolean` is `true`.
        local literal = if (r.kind == "Boolean") then r.value elseif (l.kind == "Boolean") then l.value else true end
        local rest = Tests.drop_is(ctx, cur, ctx.store:atom(if literal then "true" else "false" end))
        if rest ~= cur then
          no = Narrowing.narrowed_flow(f, p, rest)
        end
      else
        yes = Tests.has_element(ctx, f, operand)
      end
    end
  elseif (r.kind == "String") and (l.kind == "Call") then
    yes, no = Narrowing.type_edges(ctx, f, l, r.value)
  elseif (l.kind == "String") and (r.kind == "Call") then
    yes, no = Narrowing.type_edges(ctx, f, r, l.value)
  elseif (r.kind == "String") and (l.kind == "Field") then
    yes, no = Narrowing.tag_edges(ctx, f, l, r.value)
    yes, no = Narrowing.literal_edges(ctx, yes, no, l, r.value)
  elseif (l.kind == "String") and (r.kind == "Field") then
    yes, no = Narrowing.tag_edges(ctx, f, r, l.value)
    yes, no = Narrowing.literal_edges(ctx, yes, no, r, l.value)
  elseif (r.kind == "String") then
    yes, no = Narrowing.literal_edges(ctx, f, f, l, r.value)
  elseif (l.kind == "String") then
    yes, no = Narrowing.literal_edges(ctx, f, f, r, l.value)
  elseif (l.kind == "Unary") or (r.kind == "Unary") then
    yes, no = Tests.length_edges(ctx, f, "==", l, r)
  end
  if node.op == "==" then
    return yes, no
  end
  return no, yes
end

--- The key of the fact that the local `id` is tied to the others of its statement: rooted in the local, so that an
--- assignment to it, a new declaration of it, or a function made before an assignment to it takes the fact away, and a join
--- keeps it only where both paths have it.
function Narrowing.tie_key(ctx: Ctx, id: integer): string
  return id_key(ctx, id) .. ".#tie"
end
local tie_key = Narrowing.tie_key

--- The edges of a test of the first local of a tie (`if ok`, `ok == true`): where it is `true`, the others are the types
--- of the lists that begin with `true` (and where `false`, of those that begin with `false`), as far as that narrows what
--- they hold. Nil where `e` is no such local, or where one of the locals has been assigned since the statement.
--- `yes` and `no` are the states to narrow the others in, which the test of the first gave; `by_nil` says which kind of
--- tie the test can tell, nil for either.
function Narrowing.tie_edges(ctx: Ctx, f: Flow.State, e: Ast.Node, yes_base?: Flow.State, no_base?: Flow.State,
                             by_nil?: boolean): Flow.State?, Flow.State?
  local at = peel(e)
  if at.kind ~= "Name" then
    return nil, nil
  end
  local id = at.binding
  local tie = if id ~= nil then ctx.ties[id] else nil end
  if tie == nil or place_of(ctx, f, at) == nil or f.facts[tie_key(ctx, tie.first)] == nil or
      (by_nil == nil and not tie.truth) or (by_nil ~= nil and tie.by_nil ~= by_nil) then
    return nil, nil
  end
  for _, slot in ipairs(tie.rest) do
    if f.facts[tie_key(ctx, slot.id)] == nil or ctx.unfixed_now[slot.id] == true then
      return nil, nil
    end
  end
  local yes, no = yes_base or f, no_base or f
  for _, slot in ipairs(tie.rest) do
    local declared = ctx.vars[slot.id]
    if declared ~= nil then
      local key = id_key(ctx, slot.id)
      local cur = declared
      local fact = f.facts[key]
      if fact ~= nil then
        cur = fact.type
      end
      if accepts(ctx, slot.yes, cur) then
        yes = Narrowing.narrowed_flow(yes, { key = key, declared = declared }, slot.yes)
      end
      if accepts(ctx, slot.no, cur) then
        no = Narrowing.narrowed_flow(no, { key = key, declared = declared }, slot.no)
      end
    end
  end
  return yes, no
end

--- The edges of a name or a field used as a condition: an optional is not nil when true, and nil when false unless
--- what it holds may be false. An index read of an array when true shows the array has the key ([`Tests.has_element`]).
function Narrowing.truthy_edges(ctx: Ctx, f: Flow.State, e: Ast.Node): Flow.State, Flow.State
  local p = place_of(ctx, f, e)
  if p == nil then
    return Tests.has_element(ctx, f, e), f
  end
  local yes, no = f, f
  local cur = current(f, p)
  if nilable(cur) then
    local store = ctx.store
    local kept = store:non_nil(cur)
    local falsy = ctx.nil_type
    for _, m in ipairs(members_of(store, kept)) do
      if is_bool(m) then
        falsy = cur
      end
    end
    yes, no = Narrowing.narrowed_flow(f, p, kept), Narrowing.narrowed_flow(f, p, falsy)
  end
  -- The first local of a tie selects the lists of the others too.
  local tied_yes, tied_no = Narrowing.tie_edges(ctx, f, e, yes, no)
  if tied_yes ~= nil and tied_no ~= nil then
    return tied_yes, tied_no
  end
  return yes, no
end

--- The edges of a test that the place `p` is a `tested`. `is table` tests that it is a table of any shape, the standard
--- library's record `table` being the type of its functions and no type of a value: it narrows as `type(v) == "table"`.
function Narrowing.is_edges(ctx: Ctx, f: Flow.State, p: Place, tested: Type): Flow.State, Flow.State
  local cur = current(f, p)
  local library = ctx.program.globals["table"]
  if (tested.tag == "named") and library ~= nil and tested.decl == library.decl then
    return Narrowing.when_true(f, p, Tests.by_kind(ctx, cur, "table", true)), Narrowing.narrowed_flow(f, p, Tests.by_kind(ctx, cur, "table", false))
  end
  return Narrowing.when_true(f, p, Tests.keep_is(ctx, cur, tested)), Narrowing.narrowed_flow(f, p, Tests.drop_is(ctx, cur, tested))
end

--- The arm text that takes a value of type `t`: `| T name then ...`.
function Narrowing.type_arm(ctx: Ctx, t: Type): string
  return quoted("| " .. show(ctx, t) .. " v then ...")
end

return Narrowing
