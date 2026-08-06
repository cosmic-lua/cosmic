#!/usr/bin/env cosmic
-- test cosmic.doc.index generation

local fs = require("cosmic.fs")
local env = require("cosmic.env")
local codec = require("cosmic.codec")
local index = require("cosmic.doc.index")
local check = require("cosmic.check")

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
  local data, derr = codec.decode_lua_unsafe(encoded)
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
  local data = check.must(codec.decode_lua_unsafe(encoded))
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
-- unfiltered (cosmic.flags was the in-tree case).
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
  local data = check.must(codec.decode_lua_unsafe(encoded))
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
-- parent entry, not re-register a stranded `.init` module. The shipped
-- index regressed exactly this way (seven stranded .init entries) when
-- normalization moved ahead of the example merge.
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
  local data = check.must(codec.decode_lua_unsafe(encoded))
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
