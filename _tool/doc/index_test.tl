#!/usr/bin/env cosmic
-- test cosmic.doc.index generation

local fs = require("cosmic.fs")
local env = require("cosmic.env")
local index = require("_tool.doc.index")
local check = require("cosmic.check")

--- Load a generated index the way the doc reader does: the index ships
--- without a `return` prefix — the reader supplies the keyword — and
--- loads with an empty environment.
local function decode_index(encoded: string): any, string
  local chunk, lerr = load("return " .. encoded, "=(index)", "t", {})
  if not chunk then
    return nil, lerr
  end
  local pok, data = pcall(chunk)
  if not pok then
    return nil, tostring(data)
  end
  return data
end

local tmpdir = env.get("TEST_TMPDIR")
assert(tmpdir, "TEST_TMPDIR must be set")

local function write_temp(name: string, content: string): string
  local filepath = fs.join(tmpdir, name)
  assert(fs.write(filepath, content))
  return filepath
end

local widget_path = write_temp("widget.tl", [[
--- Widget module.
local function frob(): number
  return 1
end
return { frob = frob }
]])

local widget_example_path = write_temp("widget_example.tl", [[
--- Examples for widgets.
local function Example_frob()
  print("frob")
  -- Output:
  -- frob
end
return {}
]])

local orphan_example_path = write_temp("orphan_example.tl", [[
--- Examples for a topic with no source module.
local function Example_orphan()
  print("orphan")
  -- Output:
  -- orphan
end
return {}
]])

local function generate_modules(files: {string}): {string: any}
  local encoded = check.must(index.generate(files))
  local data, derr = decode_index(encoded)
  assert(data, "index should decode: " .. tostring(derr))
  return (data as {string: any}).modules as {string: any} -- cast: from any
end

local function find_module(modules: {string: any}, suffix: string): {string: any}
  for name, mod in pairs(modules) do
    if name:match("%." .. suffix .. "$") or name == suffix then
      return mod as {string: any} -- cast: from any
    end
  end
  return nil
end

-- Examples merge into their source module.
local function test_examples_merge_into_module()
  local modules = generate_modules({widget_path, widget_example_path})
  local mod = find_module(modules, "widget")
  assert(mod, "widget module should be indexed")
  local examples = mod.examples as {any} -- cast: from any
  assert(examples and #examples == 1,
    "widget_example should merge into the widget module")
  assert(find_module(modules, "widget_example") == nil,
    "the _example shard should not be its own module entry")
end
test_examples_merge_into_module()

-- An example file with no matching source module is registered under
-- its base name instead of being silently dropped (deploy_example.tl
-- is the in-tree case).
local function test_orphan_example_registered()
  local modules = generate_modules({widget_path, orphan_example_path})
  local mod = find_module(modules, "orphan")
  assert(mod, "orphan example file should be indexed under its base name")
  local examples = mod.examples as {any} -- cast: from any
  assert(examples and #examples == 1,
    "orphan examples should be addressable, not dropped")
end
test_orphan_example_registered()

-- Directory-module shards fold into the parent users require: the
-- parent's export list admits a shard's exported function onto the
-- parent page, keeps the shard's private helper off it, and the shard
-- stays addressable under its own name. Without this, `--docs fs`
-- showed a header while every function lived on internal shard pages.
local function test_shards_flatten_into_parent()
  local pdir = fs.join(tmpdir, "gadget")
  assert(fs.make_dirs(pdir))
  local init_path = fs.join(pdir, "init.tl")
  assert(fs.write(init_path, [[
--- Gadget module.
local shard = require("gadget.shard")

local record GadgetModule
  spin: function(n: number): number
end

local M: GadgetModule = {
  spin = shard.spin,
}

return M
]]))
  local shard_path = fs.join(pdir, "shard.tl")
  assert(fs.write(shard_path, [[
--- Gadget internals.

--- Spin a gadget.
--- @param n number Revolutions
--- @return number The spun value
local function spin(n: number): number
  return n * 2
end

--- Private helper the parent does not export.
--- @return number Zero
local function internal_only(): number
  return 0
end

return { spin = spin, internal_only = internal_only }
]]))

  local encoded = check.must(index.generate({init_path, shard_path},
      {[init_path] = "gadget.init", [shard_path] = "gadget.shard"}))
  local data = check.must(decode_index(encoded))
  local modules = (data as {string: any}).modules as {string: any} -- cast: from any
  local parent = modules["gadget"] as {string: any} -- cast: from any
  assert(parent, "gadget.init should normalize to gadget")
  local names: {string: boolean} = {}
  for _, func in ipairs((parent.functions or {}) as {any}) do -- cast: from any
    names[(func as {string: any}).name as string] = true -- cast: from any
  end
  assert(names["spin"], "the shard's exported function belongs on the parent page")
  assert(not names["internal_only"],
    "a shard helper the parent does not export stays off the parent page")
  assert(parent.exports == nil, "the export list must not ship in the index")
  local shard_mod = modules["gadget.shard"] as {string: any} -- cast: from any
  assert(shard_mod, "the shard stays addressable under its own name")
end
test_shards_flatten_into_parent()

-- A directory module WITH a sibling example file: init must normalize
-- before examples merge, or the example doc registers itself under the
-- module's name first, the init rename finds the name taken, and the
-- page users see is a bare example with every shard helper merged
-- unfiltered (cosmic.flags is the in-tree case).
local function test_example_beside_directory_module()
  local pdir = fs.join(tmpdir, "widgetdir")
  assert(fs.make_dirs(pdir))
  local init_path = fs.join(pdir, "init.tl")
  assert(fs.write(init_path, [[
--- Widgetdir module.
local shard = require("widgetdir.shard")

local record WidgetdirModule
  spin: function(n: number): number
end

local M: WidgetdirModule = {
  spin = shard.spin,
}

return M
]]))
  local shard_path = fs.join(pdir, "shard.tl")
  assert(fs.write(shard_path, [[
--- Widgetdir internals.

--- Spin a widget.
--- @param n number Revolutions
--- @return number The spun value
local function spin(n: number): number
  return n * 2
end

--- Private helper.
--- @return number Zero
local function internal_only(): number
  return 0
end

return { spin = spin, internal_only = internal_only }
]]))
  local example_path = fs.join(tmpdir, "widgetdir_example.tl")
  assert(fs.write(example_path, [[
--- Examples for widgetdir.
local function Example_spin()
  print("spun")
  -- Output:
  -- spun
end
return {}
]]))

  local encoded = check.must(index.generate(
      {init_path, shard_path, example_path},
      {
        [init_path] = "widgetdir.init",
        [shard_path] = "widgetdir.shard",
        [example_path] = "widgetdir_example",
      }))
  local data = check.must(decode_index(encoded))
  local modules = (data as {string: any}).modules as {string: any} -- cast: from any
  local parent = modules["widgetdir"] as {string: any} -- cast: from any
  assert(parent, "widgetdir.init should normalize to widgetdir")
  assert(modules["widgetdir.init"] == nil,
    "the init shard must not survive under its own name")
  local names: {string: boolean} = {}
  for _, func in ipairs((parent.functions or {}) as {any}) do -- cast: from any
    names[(func as {string: any}).name as string] = true -- cast: from any
  end
  assert(names["spin"], "the module's real doc reaches the page")
  assert(not names["internal_only"],
    "the export filter survives the example merge")
  local examples = parent.examples as {any} -- cast: from any
  assert(examples and #examples == 1, "the example merges onto the same page")
end
test_example_beside_directory_module()

-- An example file beside an init shard (gizmo/init_example.tl)
-- documents the directory module: it must land on the normalized
-- parent entry, not re-register a stranded `.init` module — merging
-- examples before init normalization would strand every directory
-- module's example under its own unreachable `.init` entry instead of
-- landing on the module's real page.
local function test_init_example_lands_on_directory_module()
  local pdir = fs.join(tmpdir, "gizmo")
  assert(fs.make_dirs(pdir))
  local init_path = fs.join(pdir, "init.tl")
  assert(fs.write(init_path, [[
--- Gizmo module.

--- Turn a gizmo.
--- @param n number Turns
--- @return number The turned value
local function turn(n: number): number
  return n + 1
end

return { turn = turn }
]]))
  local example_path = fs.join(pdir, "init_example.tl")
  assert(fs.write(example_path, [[
--- Examples for gizmo.
local function Example_turn()
  print("turned")
  -- Output:
  -- turned
end
return {}
]]))

  local encoded = check.must(index.generate(
      {init_path, example_path},
      {
        [init_path] = "gizmo.init",
        [example_path] = "gizmo.init_example",
      }))
  local data = check.must(decode_index(encoded))
  local modules = (data as {string: any}).modules as {string: any} -- cast: from any
  assert(modules["gizmo"], "gizmo.init should normalize to gizmo")
  assert(modules["gizmo.init"] == nil,
    "the init name must not be re-registered by its example")
  local parent = modules["gizmo"] as {string: any} -- cast: from any
  local examples = parent.examples as {any} -- cast: from any
  assert(examples and #examples == 1,
    "the init example lands on the directory module's page")
end
test_init_example_lands_on_directory_module()

-- A private helper stays OFF the module's own page: a doc comment is
-- not an export, and a page that names a helper a caller cannot reach
-- is a page that lies. The exported neighbour beside it is the
-- control — filtering may not cost a real function.
local function test_private_helpers_stay_off_the_page()
  local path = write_temp("gizmo.tl", [[
--- Gizmo module.
--- Reachable.
local function spin(): number
  return 1
end
--- A helper nobody outside this file can call.
local function grind(): number
  return 2
end
local record GizmoModule
  spin: function(): number
end
local M: GizmoModule = {
  spin = spin,
}
return M
]])
  local mod = find_module(generate_modules({path}), "gizmo")
  assert(mod, "gizmo module should be indexed")
  local names: {string: boolean} = {}
  for _, f in ipairs(mod.functions as {any}) do -- cast: from any
    names[(f as {string: any}).name as string] = true -- cast: from any
  end
  assert(names["spin"], "an exported function must stay documented")
  assert(not names["grind"],
    "a private helper must not be documented as public API")
end
test_private_helpers_stay_off_the_page()

-- A module that IS its record (`return stream`) states its exports as
-- that record's function fields, and defines them dot-qualified. Both
-- halves are read: the dotted definition is documented under its own
-- bare name, and the private helper beside it is still dropped.
local function test_record_module_exports_and_dotted_names()
  local path = write_temp("sprocket.tl", [[
--- Sprocket module.
local record sprocket
  --- Turn it.
  turn: function(n: number): number
end
--- A helper nobody outside this file can call.
local function grind(n: number): number
  return n
end
--- Turn it.
function sprocket.turn(n: number): number
  return grind(n)
end
return sprocket
]])
  local mod = find_module(generate_modules({path}), "sprocket")
  assert(mod, "sprocket module should be indexed")
  local names: {string: boolean} = {}
  for _, f in ipairs(mod.functions as {any}) do -- cast: from any
    names[(f as {string: any}).name as string] = true -- cast: from any
  end
  assert(names["turn"],
    "`function sprocket.turn` must be documented as `turn`, not `sprocket`")
  assert(not names["sprocket"],
    "the table's own name is not a function anyone can call")
  assert(not names["grind"], "the private helper must stay off the page")
end
test_record_module_exports_and_dotted_names()

-- A `function` word inside a doc comment must not swallow the real
-- definition on the next line: a scan that ran past the newline to the
-- next `(` would consume the very function the comment documents, and
-- the module's page would be missing it.
local function test_doc_comment_does_not_eat_the_next_function()
  local path = write_temp("ratchet.tl", [[
--- Ratchet module.
--- @return function Iterator yielding each click
local function clicks(): function
  return function() end
end
return { clicks = clicks }
]])
  local mod = find_module(generate_modules({path}), "ratchet")
  assert(mod, "ratchet module should be indexed")
  local names: {string: boolean} = {}
  for _, f in ipairs(mod.functions as {any}) do -- cast: from any
    names[(f as {string: any}).name as string] = true -- cast: from any
  end
  assert(names["clicks"],
    "a `function` word in the doc comment must not hide the function")
end
test_doc_comment_does_not_eat_the_next_function()

-- The word `function` inside a string literal is not a definition.
-- Only a line that BEGINS with the definition is one, which is why
-- prose like "a function on your MODULE's record" stopped putting a
-- phantom `on` on cosmic._teal_hints' page. The record field in the
-- same fixture is the other half of the rule: `spin: function(): number`
-- names a field, not a definition to document twice.
local function test_a_function_word_in_a_string_is_not_a_definition()
  local path = write_temp("lathe.tl", [[
--- Lathe module.
local record LatheModule
  spin: function(): number
end
--- Turn it.
local function spin(): number
  local _advice = "a function on your MODULE's record is dot-called"
  return 1
end
local M: LatheModule = {
  spin = spin,
}
return M
]])
  local mod = find_module(generate_modules({path}), "lathe")
  assert(mod, "lathe module should be indexed")
  local names: {string: boolean} = {}
  for _, f in ipairs(mod.functions as {any}) do -- cast: from any
    names[(f as {string: any}).name as string] = true -- cast: from any
  end
  assert(names["spin"], "the real definition must be documented")
  assert(not names["on"],
    "`function on` inside a string literal is prose, not an export")
end
test_a_function_word_in_a_string_is_not_a_definition()
