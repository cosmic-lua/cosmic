#!/usr/bin/env cosmic
local check = require("cosmic.check")
local surface = require("_tool.surface")
local surface_diff = require("_tool.surface_diff")

local function make_surface(modules: {string},
    entries: {string: string}): surface.Surface
  return {modules = modules, entries = entries}
end

local function mixed(): {surface_diff.Delta}
  local old = make_surface({"cosmic.zeta", "cosmic.gone", "cosmic.beta"}, {
      ["cosmic.beta.B.old"] = "boolean",
      ["cosmic.gone.G.value"] = "function ( ) : string",
      ["cosmic.zeta.R.change"] = "string | nil",
      ["cosmic.zeta.R.old"] = "{ string : integer }",
      ["cosmic.zeta.R.same"] = "integer",
    })
  local new = make_surface({"cosmic.beta", "cosmic.alpha", "cosmic.zeta"}, {
      ["cosmic.alpha.A.value"] = "thread",
      ["cosmic.beta.B.new"] = "boolean | nil",
      ["cosmic.zeta.R.change"] = "string",
      ["cosmic.zeta.R.new"] = "function ( value : string ) : boolean",
      ["cosmic.zeta.R.same"] = "integer",
    })
  return surface_diff.diff(old, new)
end

local function test_all_five_kinds_and_mixed_ordering()
  check.equal(mixed(), {
      {
        kind = "module-added",
        module = "cosmic.alpha",
        key = "",
      },
      {
        kind = "added",
        module = "cosmic.alpha",
        key = "cosmic.alpha.A.value",
        new_type = "thread",
      },
      {
        kind = "added",
        module = "cosmic.beta",
        key = "cosmic.beta.B.new",
        new_type = "boolean | nil",
      },
      {
        kind = "removed",
        module = "cosmic.beta",
        key = "cosmic.beta.B.old",
        old_type = "boolean",
      },
      {
        kind = "module-removed",
        module = "cosmic.gone",
        key = "",
      },
      {
        kind = "removed",
        module = "cosmic.gone",
        key = "cosmic.gone.G.value",
        old_type = "function ( ) : string",
      },
      {
        kind = "retyped",
        module = "cosmic.zeta",
        key = "cosmic.zeta.R.change",
        old_type = "string | nil",
        new_type = "string",
      },
      {
        kind = "added",
        module = "cosmic.zeta",
        key = "cosmic.zeta.R.new",
        new_type = "function ( value : string ) : boolean",
      },
      {
        kind = "removed",
        module = "cosmic.zeta",
        key = "cosmic.zeta.R.old",
        old_type = "{ string : integer }",
      },
    })
end

local function test_empty_and_equal_surfaces_have_no_deltas()
  local empty = make_surface({}, {})
  check.equal(surface_diff.diff(empty, empty), {})
  local same = make_surface({"cosmic.alpha"}, {
      ["cosmic.alpha.A.value"] = "function ( ) : string",
    })
  check.equal(surface_diff.diff(same, same), {})
  check.equal(surface_diff.render({}),
    "diff: 0 removed or retyped, 0 added\n")
end

local function test_retype_preserves_canonical_strings_verbatim()
  local old_type = "function < T > ( value : T ) : T | nil , string"
  local new_type = "function < T > ( value : T ) : T"
  local deltas = surface_diff.diff(
    make_surface({"cosmic.api"}, {["cosmic.api.Box.map"] = old_type}),
    make_surface({"cosmic.api"}, {["cosmic.api.Box.map"] = new_type}))
  check.equal(#deltas, 1)
  check.equal(deltas[1].kind, "retyped")
  check.equal(deltas[1].old_type, old_type)
  check.equal(deltas[1].new_type, new_type)
end

local function test_exact_module_blocks_and_verdict_counts()
  check.equal(surface_diff.render(mixed()), [[cosmic.alpha:
  module-added
  added A.value: thread

cosmic.beta:
  added B.new: boolean | nil
  removed B.old: boolean

cosmic.gone:
  module-removed
  removed G.value: function ( ) : string

cosmic.zeta:
  retyped R.change: string | nil -> string
  added R.new: function ( value : string ) : boolean
  removed R.old: { string : integer }

diff: 5 removed or retyped, 4 added
]])
end

local function test_breaking_classification()
  check.equal(surface_diff.has_breaking({}), false)
  check.equal(surface_diff.has_breaking({{
          kind = "added", module = "cosmic.a", key = "cosmic.a.R.x",
          new_type = "string",
        }, {
          kind = "module-added", module = "cosmic.b", key = "",
        }}), false)
  for _, kind in ipairs({"removed", "retyped", "module-removed"}) do
    local typed = kind as surface_diff.DeltaKind -- cast: values are the closed enum
    check.equal(surface_diff.has_breaking({{
            kind = typed, module = "cosmic.a", key = "cosmic.a.R.x",
            old_type = "string", new_type = "integer",
          }}), true, kind)
  end
end
