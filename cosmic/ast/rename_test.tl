local source = require("cosmic.ast.source")
local bindings_mod = require("cosmic.ast.bindings")
local rename = require("cosmic.ast.rename")
local edit = require("cosmic.edit")

local type Snapshot = source.Snapshot
local type Bindings = bindings_mod.Bindings
local type Binding = bindings_mod.Binding

local function analyzed(code: string): Snapshot, Bindings
  local snapshot, parse_err = source.parse(code, "rename_fixture.tl")
  assert(snapshot, parse_err)
  local bindings, bindings_err = bindings_mod.analyze(snapshot)
  assert(bindings, bindings_err)
  return snapshot, bindings
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

local function apply_rename(code: string, old_name: string,
    new_name: string): string, integer
  local snapshot, bindings = analyzed(code)
  local binding = find_binding(bindings, old_name)
  local fix, plan_err = rename.plan(bindings, binding.id, new_name)
  assert(fix, plan_err)
  local result, apply_err = edit.apply(snapshot, {fix})
  assert(result, apply_err)
  return result.code, result.applied_edits
end

local function test_renames_declaration_and_closure_references_atomically()
  local code = [[local value = 1
local function read(): number
  return function(): number return value end
end
return value
]]
  local got, count = apply_rename(code, "value", "answer")
  assert(got == [[local answer = 1
local function read(): number
  return function(): number return answer end
end
return answer
]])
  assert(count == 3, "declaration and two references should be one fix")
end

local function test_shadowed_same_spelling_is_not_renamed()
  local code = [[local item = 1
do
  local item = 2
  print(item)
end
return item
]]
  local got, count = apply_rename(code, "item", "outer_item")
  assert(got == [[local outer_item = 1
do
  local item = 2
  print(item)
end
return outer_item
]])
  assert(count == 2)
end

local function test_initializer_before_inner_activation_remains_safe()
  local code = [[local old = 1
do
  local fresh = old
  return fresh
end
]]
  local got = apply_rename(code, "old", "fresh")
  assert(got == [[local fresh = 1
do
  local fresh = fresh
  return fresh
end
]])
end

local function test_refuses_same_scope_collision()
  local _, bindings = analyzed([[
local left = 1
local right = 2
return left + right
]])
  local left = find_binding(bindings, "left")
  local fix, err = rename.plan(bindings, left.id, "right")
  assert(fix == nil and err:match("already bound"), tostring(err))
end

local function test_refuses_capture_inside_closure()
  local _, bindings = analyzed([[
local outer = 1
do
  local captured = 2
  local function sum(): number
    return outer + captured
  end
  print(sum())
end
]])
  local outer = find_binding(bindings, "outer")
  local fix, err = rename.plan(bindings, outer.id, "captured")
  assert(fix == nil and err:match("would be captured"), tostring(err))
end

local function test_refuses_implicit_self_and_environment_changes()
  local _, method_bindings = analyzed([[
local record Box
  value: number
end
function Box:get(): number return self.value end
]])
  local self_binding = find_binding(method_bindings, "self")
  local self_fix, self_err = rename.plan(method_bindings, self_binding.id, "receiver")
  assert(self_fix == nil and self_err:match("implicit binding"), tostring(self_err))

  local _, env_bindings = analyzed("local value = _ENV\nreturn value\n")
  local value = find_binding(env_bindings, "value")
  local env_fix, env_err = rename.plan(env_bindings, value.id, "_ENV")
  assert(env_fix == nil and env_err:match("_ENV"), tostring(env_err))
end

local function test_refuses_labels_and_type_names_explicitly()
  local _, bindings = analyzed([[
local type Named = string
::again::
goto again
]])
  local checked = 0
  for node, _reason in pairs(bindings.unsupported) do
    if node.kind == "local_type" or node.kind == "label" or node.kind == "goto" then
      local fix, err = rename.plan_node(bindings, node, "changed")
      assert(fix == nil and err:match("outside value bindings"), tostring(err))
      checked = checked + 1
    end
  end
  assert(checked == 3, "all unsupported namespace operations should refuse")
end

local function test_refuses_invalid_or_unchanged_names()
  local _, bindings = analyzed("local value = 1\nreturn value\n")
  local value = find_binding(bindings, "value")
  local invalid, invalid_err = rename.plan(bindings, value.id, "not-valid")
  assert(invalid == nil and invalid_err:match("safe identifier"), tostring(invalid_err))
  local keyword, keyword_err = rename.plan(bindings, value.id, "local")
  assert(keyword == nil and keyword_err:match("safe identifier"), tostring(keyword_err))
  local unchanged, unchanged_err = rename.plan(bindings, value.id, "value")
  assert(unchanged == nil and unchanged_err:match("unchanged"), tostring(unchanged_err))
end
