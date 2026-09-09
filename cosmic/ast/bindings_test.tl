local source = require("cosmic.ast.source")
local bindings_mod = require("cosmic.ast.bindings")

local type Bindings = bindings_mod.Bindings
local type Binding = bindings_mod.Binding

local function analyze(code: string): Bindings
  local snapshot, parse_err = source.parse(code, "bindings_fixture.tl")
  assert(snapshot, parse_err)
  local bindings, err = bindings_mod.analyze(snapshot)
  assert(bindings, err)
  return bindings
end

local function find_binding(bindings: Bindings, name: string,
    occurrence?: integer): Binding
  local wanted = occurrence or 1
  local seen = 0
  for _, binding in ipairs(bindings.all) do
    if binding.name == name then
      seen = seen + 1
      if seen == wanted then
        return binding
      end
    end
  end
  error("missing binding " .. name) -- throws: test fixture contract
end

local function test_initializer_sees_prior_binding_before_shadow()
  local bindings = analyze([[
local x: number = 1
do
  local x: number = x
  print(x)
end
print(x)
]])
  local outer = find_binding(bindings, "x", 1)
  local inner = find_binding(bindings, "x", 2)
  assert(#bindings_mod.references_of(bindings, outer.id) == 2,
    "outer x should resolve in inner initializer and after block")
  assert(#bindings_mod.references_of(bindings, inner.id) == 1,
    "inner x should resolve in its block after declaration")
end

local function test_local_function_is_recursive_and_parameters_shadow()
  local bindings = analyze([[
local x: number = 1
local function rec(x: number): number
  local again = function(): number return rec(x) end
  return again()
end
return x
]])
  local outer_x = find_binding(bindings, "x", 1)
  local parameter_x = find_binding(bindings, "x", 2)
  local rec = find_binding(bindings, "rec")
  assert(#bindings_mod.references_of(bindings, rec.id) == 1,
    "recursive call should resolve to local function declaration")
  assert(#bindings_mod.references_of(bindings, parameter_x.id) == 1,
    "closure should capture the parameter, even with the same type")
  assert(#bindings_mod.references_of(bindings, outer_x.id) == 1,
    "outer same-typed x should remain distinct")
end

local function test_named_function_assignment_resolves_predeclared_local()
  local bindings = analyze([[
local rec: function(number): number
function rec(n: number): number
  if n == 0 then return 0 end
  return rec(n - 1)
end
]])
  local rec = find_binding(bindings, "rec")
  local refs = bindings_mod.references_of(bindings, rec.id)
  assert(#refs == 2, "function name write and recursive call should resolve locally")
  assert(refs[1].is_write, "function definition should write the predeclared local")
  assert(not refs[2].is_write, "recursive call should be a read")
end

local function test_explicit_global_function_does_not_write_local()
  local bindings = analyze([[
local same = 1
global same = 2
global function same(): number
  if false then return same() end
  return 2
end
return same
]])
  local same = find_binding(bindings, "same")
  assert(#bindings_mod.references_of(bindings, same.id) == 1,
    "explicit global declarations/functions must not resolve to a same-named local")
end

local function test_loop_controls_are_outer_and_loop_vars_are_body_local()
  local bindings = analyze([[
local i = 10
local stop = 2
for i = i, stop do print(i) end
for k, v in pairs(i) do print(k, v) end
return i
]])
  local outer_i = find_binding(bindings, "i", 1)
  local numeric_i = find_binding(bindings, "i", 2)
  local k = find_binding(bindings, "k")
  local v = find_binding(bindings, "v")
  assert(#bindings_mod.references_of(bindings, outer_i.id) == 3,
    "numeric control, iterator expression, and return should see outer i")
  assert(#bindings_mod.references_of(bindings, numeric_i.id) == 1,
    "numeric loop body should see its control variable")
  assert(#bindings_mod.references_of(bindings, k.id) == 1)
  assert(#bindings_mod.references_of(bindings, v.id) == 1)
end

local function test_repeat_locals_are_visible_in_until_condition()
  local bindings = analyze([[
repeat
  local done = true
until done
]])
  local done = find_binding(bindings, "done")
  assert(#bindings_mod.references_of(bindings, done.id) == 1,
    "repeat condition should share the body's lexical scope")
end

local function test_method_has_implicit_self_binding()
  local bindings = analyze([[
local record Box
  value: number
end
function Box:get(extra: number): number
  return self.value + extra
end
]])
  local self_binding = find_binding(bindings, "self")
  local extra = find_binding(bindings, "extra")
  assert(self_binding.kind == "self" and self_binding.is_implicit)
  assert(#bindings_mod.references_of(bindings, self_binding.id) == 1)
  assert(#bindings_mod.references_of(bindings, extra.id) == 1)
end

local function test_type_and_label_names_do_not_join_value_namespace()
  local bindings = analyze([[
local same = "value"
local type same = string
::same::
if same == "again" then goto same end
return same
]])
  local same = find_binding(bindings, "same")
  assert(#bindings_mod.references_of(bindings, same.id) == 2,
    "only expression variables should resolve as value references")
  local unsupported = 0
  for _node, _reason in pairs(bindings.unsupported) do
    unsupported = unsupported + 1
  end
  assert(unsupported >= 3, "type declaration, label, and goto should be explicit")
end

local function test_import_origin_requires_direct_immutable_binding()
  local stable = analyze([[
local hash = require("cosmic.hash")
return hash.digest("sha256", "x")
]])
  local stable_hash = find_binding(stable, "hash")
  assert(bindings_mod.import_origin(stable, stable_hash.id) == "cosmic.hash")
  local member_node: source.Node | nil = nil
  for _, ref in ipairs(bindings_mod.references_of(stable, stable_hash.id)) do
    member_node = source.parent(stable.snapshot, ref.node)
  end
  assert(member_node)
  local from_hash, from_err = bindings_mod.is_from(stable, member_node, "cosmic.hash")
  assert(from_hash == true, from_err)

  local changed = analyze([[
local hash = require("cosmic.hash")
hash = other
return hash
]])
  local changed_hash = find_binding(changed, "hash")
  assert(bindings_mod.import_origin(changed, changed_hash.id) == nil,
    "assignment should invalidate a direct import origin")

  local table_changed = analyze([[
local hash = require("cosmic.hash")
hash.digest = other
]])
  local table_hash = find_binding(table_changed, "hash")
  assert(bindings_mod.import_origin(table_changed, table_hash.id) == nil,
    "table mutation should invalidate an import origin")

  local dynamic = analyze("local mod = require(module_name)\nreturn mod\n")
  local mod = find_binding(dynamic, "mod")
  local dynamic_origin = bindings_mod.origin_of(dynamic, mod.declaration)
  local dynamic_reason = dynamic_origin.reason
  assert(not dynamic_origin.proven)
  assert(dynamic_reason)
  assert(dynamic_reason:match("dynamic"), dynamic_reason)
end

local function test_environment_is_an_implicit_shadowable_binding()
  local bindings = analyze([[
local before = _ENV
do
  local _ENV = before
  return _ENV
end
]])
  local implicit = find_binding(bindings, "_ENV", 1)
  local local_env = find_binding(bindings, "_ENV", 2)
  assert(implicit.kind == "environment" and implicit.is_implicit)
  assert(#bindings_mod.references_of(bindings, implicit.id) == 1)
  assert(#bindings_mod.references_of(bindings, local_env.id) == 1)
end
