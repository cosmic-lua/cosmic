#!/usr/bin/env cosmic
-- test cosmic.doc.index generation

local fs = require("cosmic.fs")
local env = require("cosmic.env")
local codec = require("cosmic.codec")
local index = require("cosmic.doc.index")

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
  local encoded, err = index.generate(files)
  assert(encoded, "generate failed: " .. tostring(err))
  local data, derr = codec.decode_lua_unsafe(encoded as string)
  assert(data, "index should decode: " .. tostring(derr))
  return (data as {string: any}).modules as {string: any}
end

local function find_module(modules: {string: any}, suffix: string): {string: any}
  for name, mod in pairs(modules) do
    if name:match("%." .. suffix .. "$") or name == suffix then
      return mod as {string: any}
    end
  end
  return nil
end

-- Examples merge into their source module.
local function test_examples_merge_into_module()
  local modules = generate_modules({widget_path, widget_example_path})
  local mod = find_module(modules, "widget")
  assert(mod, "widget module should be indexed")
  local examples = mod.examples as {any}
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
  local examples = mod.examples as {any}
  assert(examples and #examples == 1,
    "orphan examples should be addressable, not dropped")
end
test_orphan_example_registered()
