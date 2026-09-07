#!/usr/bin/env cosmic
--- Correctness probes for `cosmic.ast.requires`: the narrow shape it
--- resolves (a top-level, un-shadowed `local <alias> =
--- require("cosmic.<m>")`) and the shapes it deliberately leaves alone.
local check = require("cosmic.check")
local node_mod = require("cosmic.ast.node")
local requires_mod = require("cosmic.ast.requires")

local function test_requires_resolves_a_single_alias()
  local parsed = check.must(node_mod.parse('local hash = require("cosmic.hash")\n', "one.tl"))
  check.equal(requires_mod.requires(parsed), {hash = "cosmic.hash"})
end

local function test_requires_resolves_two_aliases()
  local source = 'local hash = require("cosmic.hash")\n'
  .. 'local str = require("cosmic.string")\n'
  local parsed = check.must(node_mod.parse(source, "two.tl"))
  check.equal(requires_mod.requires(parsed), {hash = "cosmic.hash", str = "cosmic.string"})
end

--- A `require` of a module outside the `cosmic.` namespace is not a
--- `cosmic.ast.requires` alias at all -- excluded by the module-name
--- prefix check, not by the pattern shape.
local function test_requires_excludes_a_non_cosmic_require()
  local parsed = check.must(node_mod.parse('local other = require("other.thing")\n', "other.tl"))
  check.equal(requires_mod.requires(parsed), {})
end

--- A `local` binding inside a function body is a local variable, not a
--- module alias -- out of scope by this module's own stated narrowness,
--- not resolved even though its RHS is a `cosmic.*` require.
local function test_requires_excludes_a_require_inside_a_function_body()
  local source = 'local function foo()\n'
  .. '  local nested = require("cosmic.string")\n'
  .. 'end\n'
  local parsed = check.must(node_mod.parse(source, "nested.tl"))
  check.equal(requires_mod.requires(parsed), {})
end

--- Re-assignment tracking is explicitly out of scope: the alias is
--- still reported bound to its ORIGINAL require, even though a later
--- top-level statement rebinds the same name to something else. This
--- documents the scope limit -- it is not a bug.
local function test_requires_does_not_track_reassignment()
  local source = 'local hash = require("cosmic.hash")\n'
  .. 'hash = "shadowed"\n'
  local parsed = check.must(node_mod.parse(source, "reassigned.tl"))
  check.equal(requires_mod.requires(parsed), {hash = "cosmic.hash"})
end

local function test_requires_returns_an_empty_table_for_no_requires()
  local parsed = check.must(node_mod.parse('local x = 1\n', "none.tl"))
  local result = requires_mod.requires(parsed)
  check.truthy(result ~= nil, "result must not be nil")
  local count = 0
  for _ in pairs(result) do
    count = count + 1
  end
  check.equal(count, 0)
end
