--- `build.tree`: what a root is to the running tool.

local Fs = require("cosmic.fs")
local paths = require("build.paths")
local tree = require("build.tree")

--- A directory made at `root`, with `core/`.
local function checkout(root: string)
  assert(Fs.mkdirs(root .. "/core"))
end

local function test_a_root_is_own_to_a_tool_built_from_its_path(tmp: string)
  local root = tmp .. "/tree"
  checkout(root)
  local standing, trouble = tree.standing(root, (assert(tree.built_from(root))))
  assert(standing ~= nil and standing.own, tostring(trouble))
end

--- A directory that has cosmic's layout is a project to a tool not built from it.
local function test_a_layout_makes_no_root_own(tmp: string)
  local root = tmp .. "/tree"
  checkout(root)
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/importer.tl", "return {}\n"))
  local standing, trouble = tree.standing(root, tmp .. "/another")
  assert(standing ~= nil and not standing.own, tostring(trouble))
  local unrecorded, unrecorded_trouble = tree.standing(root)
  assert(unrecorded ~= nil and not unrecorded.own, tostring(unrecorded_trouble))
end

--- A tool in the build directory of a root that says it was built from it where the checkout has lost its `core/` is
--- an error: the tree it was built from is not here. A tool outside it is just not the root's own.
local function test_a_tool_built_from_a_root_without_core_is_an_error_only_in_its_build_directory(tmp: string)
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root))
  local here = assert(tree.built_from(root))
  local outside, outside_trouble = tree.standing(root, here)
  assert(outside ~= nil and not outside.own, tostring(outside_trouble))
  local layout = paths.resolve(root)
  assert(Fs.mkdirs(layout.bin))
  assert(Fs.write(layout.tool, "binary", 0x1ed))
  local inside, trouble = tree.standing(root, here, layout.tool)
  assert(inside == nil and trouble:find("has no core/", 1, true) ~= nil, tostring(trouble))
end

--- A release is built from no checkout, so it is a project's tool wherever it runs: in a checkout of cosmic, in a
--- directory of the path CI built in, with or without a `core/`.
local function test_a_tool_that_records_no_checkout_is_a_projects_tool_everywhere(tmp: string)
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root .. "/core"))
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/importer.tl", "return {}\n"))
  local release, release_trouble = tree.standing(root, "")
  assert(release ~= nil and not release.own, tostring(release_trouble))
  local bare = tmp .. "/bare"
  assert(Fs.mkdirs(bare))
  local without, without_trouble = tree.standing(bare, "")
  assert(without ~= nil and not without.own, tostring(without_trouble))
end

--- A boot is the act that makes a root's tool, so the root is its own to it; with no `core/` there is nothing to boot.
local function test_a_boot_stands_on_the_root_it_writes_a_tool_for(tmp: string)
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root .. "/core"))
  local booted, trouble = tree.booted(root)
  assert(booted ~= nil and booted.own, tostring(trouble))
  local bare = tmp .. "/bare"
  assert(Fs.mkdirs(bare))
  local none, none_trouble = tree.booted(bare)
  assert(none == nil and none_trouble:find("needs the checkout's core/", 1, true) ~= nil, tostring(none_trouble))
end

--- Neither a root that cannot be resolved nor a tool in a build directory it was not built for
--- goes on as if the root were a project.
local function test_an_unreadable_root_and_a_misplaced_tool_are_errors(tmp: string)
  local gone, gone_trouble = tree.standing(tmp .. "/nowhere", tmp)
  assert(gone == nil and gone_trouble:find("nowhere", 1, true) ~= nil, tostring(gone_trouble))

  local root = tmp .. "/tree"
  checkout(root)
  local layout = paths.resolve(root)
  assert(Fs.mkdirs(layout.bin))
  assert(Fs.write(layout.tool, "binary", 0x1ed))
  local moved, moved_trouble = tree.standing(root, tmp .. "/old", layout.tool)
  assert(moved == nil and moved_trouble:find("was built from " .. tmp .. "/old; run bin/zig build boot", 1, true) ~= nil,
    tostring(moved_trouble))
end
