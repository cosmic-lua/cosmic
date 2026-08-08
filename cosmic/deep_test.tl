--- Tests for cosmic.deep.
local deep = require("cosmic.deep")

-- copy

local function test_copy_is_independent()
  local orig: {string: any} = {a = 1, nested = {b = {2, 3}}}
  local copy = deep.copy(orig) as {string: any} -- cast: from any
  assert(deep.equal(orig, copy), "copy differs from original")
  local copy_nested = copy.nested as {string: any} -- cast: from any
  copy_nested.b = "mutated"
  assert(deep.equal((orig.nested as {string: any}).b, {2, 3}), -- cast: from any
    "mutating the copy leaked into the original")
end
test_copy_is_independent()

local function test_copy_passes_scalars_through()
  assert(deep.copy(42) == 42)
  assert(deep.copy("s") == "s")
  assert(deep.copy(nil) == nil)
  assert(deep.copy(true) == true)
end
test_copy_passes_scalars_through()

local function test_copy_preserves_cycles()
  local orig: {string: any} = {name = "root"}
  orig.self = orig
  local copy = deep.copy(orig) as {string: any} -- cast: from any
  assert(copy.self == copy, "cycle not preserved")
  assert(copy ~= orig, "copy is the original")
  assert(copy.name == "root")
end
test_copy_preserves_cycles()

local function test_copy_preserves_shared_references()
  local shared: {number} = {1}
  local orig: {string: any} = {x = shared, y = shared}
  local copy = deep.copy(orig) as {string: any} -- cast: from any
  assert(copy.x == copy.y, "shared reference duplicated")
  assert(copy.x ~= shared, "shared table not copied")
end
test_copy_preserves_shared_references()

local function test_copy_copies_table_keys()
  local key: {string: string} = {id = "k"}
  local orig: {any: any} = {[key] = "v"}
  local copy = deep.copy(orig) as {any: any} -- cast: from any
  assert(copy[key] == nil, "table key was not copied")
  local found = false
  for k, v in pairs(copy) do
    assert(deep.equal(k, key), "copied key differs")
    assert(v == "v")
    found = true
  end
  assert(found, "copied table is empty")
end
test_copy_copies_table_keys()

-- equal

local function test_equal_nested()
  assert(deep.equal({a = {1, {2}}, b = "x"}, {a = {1, {2}}, b = "x"}))
  assert(not deep.equal({a = {1, {2}}}, {a = {1, {3}}}))
end
test_equal_nested()

local function test_equal_key_sets_must_match()
  assert(not deep.equal({a = 1}, {a = 1, b = 2}), "extra key in b")
  assert(not deep.equal({a = 1, b = 2}, {a = 1}), "extra key in a")
  assert(deep.equal({}, {}), "empty tables differ")
end
test_equal_key_sets_must_match()

local function test_equal_scalars_and_mixed()
  assert(deep.equal(1, 1))
  assert(not deep.equal(1, "1"))
  assert(not deep.equal({1}, 1))
  assert(not deep.equal(nil, {}))
end
test_equal_scalars_and_mixed()

local function test_equal_handles_cycles()
  local a: {string: any} = {v = 1}
  a.self = a
  local b: {string: any} = {v = 1}
  b.self = b
  assert(deep.equal(a, b), "equal cyclic tables compared unequal")
  local c: {string: any} = {v = 2}
  c.self = c
  assert(not deep.equal(a, c), "unequal cyclic tables compared equal")
end
test_equal_handles_cycles()

-- merge

local function test_merge_recurses_and_overrides()
  local base: {string: any} = {
    host = "localhost",
    limits = {mem = 64, cpu = 1},
  }
  local override: {string: any} = {
    limits = {mem = 128},
    debug = true,
  }
  local merged = deep.merge(base, override)
  assert(deep.equal(merged, {
        host = "localhost",
        limits = {mem = 128, cpu = 1},
        debug = true,
      }), "unexpected merge result")
end
test_merge_recurses_and_overrides()

local function test_merge_override_wins_on_type_conflict()
  local merged = deep.merge({a = {nested = true}}, {a = "flat"})
  assert(deep.equal(merged, {a = "flat"}))
  local merged2 = deep.merge({a = "flat"}, {a = {nested = true}})
  assert(deep.equal(merged2, {a = {nested = true}}))
end
test_merge_override_wins_on_type_conflict()

local function test_merge_mutates_neither_input()
  local base: {string: any} = {limits = {mem = 64}}
  local override: {string: any} = {limits = {cpu = 2}}
  local merged = deep.merge(base, override)
  assert(deep.equal(base, {limits = {mem = 64}}), "base mutated")
  assert(deep.equal(override, {limits = {cpu = 2}}), "override mutated")
  local merged_limits = merged.limits as {string: any} -- cast: from any
  merged_limits.mem = 999
  assert((base.limits as {string: any}).mem == 64, -- cast: from any
    "merge result shares tables with base")
end
test_merge_mutates_neither_input()

local function test_merge_arrays_merge_by_index()
  local merged = deep.merge({list = {1, 2, 3}}, {list = {9}})
  assert(deep.equal(merged, {list = {9, 2, 3}}),
    "documented by-index array semantics changed")
end
test_merge_arrays_merge_by_index()
