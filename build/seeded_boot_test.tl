--- What a boot on a release's core (build/seeded_boot.tl) says for
--- build.zig: the target records it hands the bridge and the patched
--- trees it installs, which build.zig writes where zig boots the tree.

local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local SeededBoot = require("build.seeded_boot")

Test.policy{ grants = { { path = "build.zig", letters = "r" } } }

--- The records are build.zig's: one line a target of its `targets`, as
--- `targetRecord` formats it for the release configuration, in its order.
local function test_the_records_are_build_zigs_targets()
  local source = assert(Fs.read("build.zig"))
  local lines: mut {string} = {}
  for id, name, os, arch in source:gmatch(
      '%.id = (%d+), %.name = "([^"]+)", %.uname_os = "([^"]+)", %.uname_arch = "([^"]+)"') do
    lines[#lines + 1] = id .. "\t1\trelease\t" .. name .. "\t" .. os .. "\t" .. arch .. "\n"
  end
  assert(#lines >= 3, "build.zig's targets were not read: " .. tostring(#lines))
  assert(source:find("release_configuration", 1, true) ~= nil)
  assert(table.concat(lines) == SeededBoot.records, table.concat(lines))
end

--- The patched trees installed are those build.zig's `vendored` step
--- installs, each `.{ "<name>", <tree> }` of its list.
local function test_the_vendored_trees_are_build_zigs()
  local source = assert(Fs.read("build.zig"))
  local from = assert(source:find('b.step("vendor"', 1, true))
  local to = assert(source:find("}) |pair|", from, true))
  local names: mut {string:boolean} = {}
  local count = 0
  for name in source:sub(from, to):gmatch('%.{ "([^"]+)",') do
    names[name] = true
    count = count + 1
  end
  assert(count == #SeededBoot.vendored, tostring(count) .. " in build.zig")
  for _, name in ipairs(SeededBoot.vendored) do
    assert(names[name] == true, name .. " is not installed by build.zig")
  end
end

--- What a core is built from names the core's C, the vendored trees and
--- the patches, and leaves the core's Teal out.
local function test_the_c_inputs_leave_the_cores_teal_out()
  local named: mut {string:boolean} = {}
  for _, path in ipairs(SeededBoot.c_inputs) do named[path] = true end
  for _, path in ipairs({ "core", "vendor", "patch", "build.zig", "bin/zig.pin", ":(exclude)core/*.tl" }) do
    assert(named[path] == true, path)
  end
end
