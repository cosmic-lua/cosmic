--- Tests for cosmic.table.
local tbl = require("cosmic.table")

-- deep_copy

local function test_deep_copy_is_independent()
  local orig: {string: any} = {a = 1, nested = {b = {2, 3}}}
  local copy = tbl.deep_copy(orig) as {string: any} -- cast: from any
  assert(tbl.deep_eq(orig, copy), "copy differs from original")
  local copy_nested = copy.nested as {string: any} -- cast: from any
  copy_nested.b = "mutated"
  assert(tbl.deep_eq((orig.nested as {string: any}).b, {2, 3}), -- cast: from any
    "mutating the copy leaked into the original")
end

local function test_deep_copy_passes_scalars_through()
  assert(tbl.deep_copy(42) == 42)
  assert(tbl.deep_copy("s") == "s")
  assert(tbl.deep_copy(nil) == nil)
  assert(tbl.deep_copy(true) == true)
end

local function test_deep_copy_preserves_cycles()
  local orig: {string: any} = {name = "root"}
  orig.self = orig
  local copy = tbl.deep_copy(orig) as {string: any} -- cast: from any
  assert(copy.self == copy, "cycle not preserved")
  assert(copy ~= orig, "copy is the original")
  assert(copy.name == "root")
end

local function test_deep_copy_preserves_shared_references()
  local shared: {number} = {1}
  local orig: {string: any} = {x = shared, y = shared}
  local copy = tbl.deep_copy(orig) as {string: any} -- cast: from any
  assert(copy.x == copy.y, "shared reference duplicated")
  assert(copy.x ~= shared, "shared table not copied")
end

local function test_deep_copy_copies_table_keys()
  local key: {string: string} = {id = "k"}
  local orig: {any: any} = {[key] = "v"}
  local copy = tbl.deep_copy(orig) as {any: any} -- cast: from any
  assert(copy[key] == nil, "table key was not copied")
  local found = false
  for k, v in pairs(copy) do
    assert(tbl.deep_eq(k, key), "copied key differs")
    assert(v == "v")
    found = true
  end
  assert(found, "copied table is empty")
end

-- deep_eq

local function test_deep_eq_nested()
  assert(tbl.deep_eq({a = {1, {2}}, b = "x"}, {a = {1, {2}}, b = "x"}))
  assert(not tbl.deep_eq({a = {1, {2}}}, {a = {1, {3}}}))
end

local function test_deep_eq_key_sets_must_match()
  assert(not tbl.deep_eq({a = 1}, {a = 1, b = 2}), "extra key in b")
  assert(not tbl.deep_eq({a = 1, b = 2}, {a = 1}), "extra key in a")
  assert(tbl.deep_eq({}, {}), "empty tables differ")
end

local function test_deep_eq_scalars_and_mixed()
  assert(tbl.deep_eq(1, 1))
  assert(not tbl.deep_eq(1, "1"))
  assert(not tbl.deep_eq({1}, 1))
  assert(not tbl.deep_eq(nil, {}))
end

local function test_deep_eq_handles_cycles()
  local a: {string: any} = {v = 1}
  a.self = a
  local b: {string: any} = {v = 1}
  b.self = b
  assert(tbl.deep_eq(a, b), "equal cyclic tables compared unequal")
  local c: {string: any} = {v = 2}
  c.self = c
  assert(not tbl.deep_eq(a, c), "unequal cyclic tables compared equal")
end

-- deep_merge

local function test_deep_merge_recurses_and_overrides()
  local base: {string: any} = {
    host = "localhost",
    limits = {mem = 64, cpu = 1},
  }
  local override: {string: any} = {
    limits = {mem = 128},
    debug = true,
  }
  local merged = tbl.deep_merge(base, override)
  assert(tbl.deep_eq(merged, {
        host = "localhost",
        limits = {mem = 128, cpu = 1},
        debug = true,
      }), "unexpected merge result")
end

local function test_deep_merge_override_wins_on_type_conflict()
  local merged = tbl.deep_merge({a = {nested = true}}, {a = "flat"})
  assert(tbl.deep_eq(merged, {a = "flat"}))
  local merged2 = tbl.deep_merge({a = "flat"}, {a = {nested = true}})
  assert(tbl.deep_eq(merged2, {a = {nested = true}}))
end

local function test_deep_merge_mutates_neither_input()
  local base: {string: any} = {limits = {mem = 64}}
  local override: {string: any} = {limits = {cpu = 2}}
  local merged = tbl.deep_merge(base, override)
  assert(tbl.deep_eq(base, {limits = {mem = 64}}), "base mutated")
  assert(tbl.deep_eq(override, {limits = {cpu = 2}}), "override mutated")
  local merged_limits = merged.limits as {string: any} -- cast: from any
  merged_limits.mem = 999
  assert((base.limits as {string: any}).mem == 64, -- cast: from any
    "merge result shares tables with base")
end

local function test_deep_merge_arrays_merge_by_index()
  local merged = tbl.deep_merge({list = {1, 2, 3}}, {list = {9}})
  assert(tbl.deep_eq(merged, {list = {9, 2, 3}}),
    "documented by-index array semantics changed")
end

-- map / filter / reduce

local function test_map()
  local out = tbl.map({1, 2, 3}, function(n: number): number
      return n * n
    end)
  assert(tbl.deep_eq(out, {1, 4, 9}))
  local strs = tbl.map({1, 2}, function(n: number): string
      return "#" .. tostring(n)
    end)
  assert(tbl.deep_eq(strs, {"#1", "#2"}))
end

local function test_filter()
  local out = tbl.filter({1, 2, 3, 4, 5}, function(n: number): boolean
      return n % 2 == 0
    end)
  assert(tbl.deep_eq(out, {2, 4}))
end

local function test_reduce()
  local sum = tbl.reduce({1, 2, 3, 4}, function(acc: number, n: number): number
      return acc + n
    end, 0)
  assert(sum == 10, "got: " .. tostring(sum))
  local joined = tbl.reduce({"a", "b"}, function(acc: string, s: string): string
      return acc .. s
    end, "")
  assert(joined == "ab", "got: " .. joined)
end

local function test_map_filter_reduce_empty_list()
  assert(tbl.deep_eq(tbl.map({}, function(n: number): number return n end), {}))
  assert(tbl.deep_eq(tbl.filter({}, function(_: number): boolean return true end), {}))
  local acc = tbl.reduce({}, function(a: number, n: number): number return a + n end, 7)
  assert(acc == 7, "reduce of empty list changed init")
end

local function test_inputs_not_mutated_by_list_transforms()
  local input = {3, 1, 2}
  tbl.map(input, function(n: number): number return -n end)
  tbl.filter(input, function(n: number): boolean return n > 1 end)
  tbl.reduce(input, function(a: number, n: number): number return a + n end, 0)
  assert(tbl.deep_eq(input, {3, 1, 2}), "a transform mutated its input")
end

test_deep_copy_is_independent()
test_deep_copy_passes_scalars_through()
test_deep_copy_preserves_cycles()
test_deep_copy_preserves_shared_references()
test_deep_copy_copies_table_keys()
test_deep_eq_nested()
test_deep_eq_key_sets_must_match()
test_deep_eq_scalars_and_mixed()
test_deep_eq_handles_cycles()
test_deep_merge_recurses_and_overrides()
test_deep_merge_override_wins_on_type_conflict()
test_deep_merge_mutates_neither_input()
test_deep_merge_arrays_merge_by_index()
test_map()
test_filter()
test_reduce()
test_map_filter_reduce_empty_list()
test_inputs_not_mutated_by_list_transforms()
