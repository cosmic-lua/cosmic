--- Correctness probes for `build.ast.requires`: the narrow shape it
--- resolves (a top-level, un-shadowed `local <alias> =
--- require("cosmic.<m>")`) and the shapes it deliberately leaves alone.
local teal = require("build.teal")
local node_mod = require("build.ast.node")
local requires_mod = require("build.ast.requires")

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

--- Asserts `actual` and `expected` hold exactly the same keys, each
--- mapped to the same value -- a small stand-in for a deep-equality
--- assertion this tree does not have a shared helper for yet.
--- @param actual {string: string}
--- @param expected {string: string}
local function assert_same_map(actual: {string: string}, expected: {string: string})
  for k, v in pairs(expected) do
    assert(actual[k] == v,
      "missing or wrong value for '" .. k .. "': " .. tostring(actual[k]))
  end
  local actual_count, expected_count = 0, 0
  for _ in pairs(actual) do actual_count = actual_count + 1 end
  for _ in pairs(expected) do expected_count = expected_count + 1 end
  assert(actual_count == expected_count,
    "expected " .. expected_count .. " entries, got " .. actual_count)
end

local function test_requires_resolves_a_single_alias()
  local parsed, perr = node_mod.parse(
    built, 'local hash = require("cosmic.hash")\n', "one.tl")
  assert(parsed ~= nil, "parse failed: " .. tostring(perr))
  local result, err = requires_mod.requires(built, parsed)
  assert(result ~= nil, "requires failed: " .. tostring(err))
  assert_same_map(result, {hash = "cosmic.hash"})
end

local function test_requires_resolves_two_aliases()
  local source = 'local hash = require("cosmic.hash")\n'
  .. 'local str = require("cosmic.string")\n'
  local parsed, perr = node_mod.parse(built, source, "two.tl")
  assert(parsed ~= nil, "parse failed: " .. tostring(perr))
  local result, err = requires_mod.requires(built, parsed)
  assert(result ~= nil, "requires failed: " .. tostring(err))
  assert_same_map(result, {hash = "cosmic.hash", str = "cosmic.string"})
end

--- A `require` of a module outside the `cosmic.` namespace is not a
--- `build.ast.requires` alias at all -- excluded by the module-name
--- prefix check, not by the pattern shape.
local function test_requires_excludes_a_non_cosmic_require()
  local parsed, perr = node_mod.parse(
    built, 'local other = require("other.thing")\n', "other.tl")
  assert(parsed ~= nil, "parse failed: " .. tostring(perr))
  local result, err = requires_mod.requires(built, parsed)
  assert(result ~= nil, "requires failed: " .. tostring(err))
  assert_same_map(result, {})
end

--- A `local` binding inside a function body is a local variable, not a
--- module alias -- out of scope by this module's own stated narrowness,
--- not resolved even though its RHS is a `cosmic.*` require.
local function test_requires_excludes_a_require_inside_a_function_body()
  local source = 'local function foo()\n'
  .. '  local nested = require("cosmic.string")\n'
  .. 'end\n'
  local parsed, perr = node_mod.parse(built, source, "nested.tl")
  assert(parsed ~= nil, "parse failed: " .. tostring(perr))
  local result, err = requires_mod.requires(built, parsed)
  assert(result ~= nil, "requires failed: " .. tostring(err))
  assert_same_map(result, {})
end

--- Re-assignment tracking is explicitly out of scope: the alias is
--- still reported bound to its ORIGINAL require, even though a later
--- top-level statement rebinds the same name to something else. This
--- documents the scope limit -- it is not a bug.
local function test_requires_does_not_track_reassignment()
  local source = 'local hash = require("cosmic.hash")\n'
  .. 'hash = "shadowed"\n'
  local parsed, perr = node_mod.parse(built, source, "reassigned.tl")
  assert(parsed ~= nil, "parse failed: " .. tostring(perr))
  local result, err = requires_mod.requires(built, parsed)
  assert(result ~= nil, "requires failed: " .. tostring(err))
  assert_same_map(result, {hash = "cosmic.hash"})
end

local function test_requires_returns_an_empty_table_for_no_requires()
  local parsed, perr = node_mod.parse(built, 'local x = 1\n', "none.tl")
  assert(parsed ~= nil, "parse failed: " .. tostring(perr))
  local result, err = requires_mod.requires(built, parsed)
  assert(result ~= nil, "requires failed: " .. tostring(err))
  local count = 0
  for _ in pairs(result) do
    count = count + 1
  end
  assert(count == 0, "expected an empty table, got " .. count .. " entries")
end
