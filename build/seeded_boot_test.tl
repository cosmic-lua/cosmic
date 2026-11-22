--- What a boot on a release's core (build/seeded_boot.tl) says for
--- build.zig: the target records it hands the bridge and the patched
--- trees it installs, which build.zig writes where zig boots the tree.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
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

--- The files of a commit and of the index are compared by mode, contents
--- and path, whichever listing names them and in whatever order, with the
--- core's Teal left out; a file whose contents or mode differ, one more
--- and one fewer are each a difference.
local function test_two_listings_of_one_tree_are_the_same()
  local tree = "100644 blob aaaa\tcore/a.c\n100755 blob bbbb\tvendor/x/run\n100644 blob cccc\tcore/m.tl\n"
  local index = "100755 bbbb 0\tvendor/x/run\n100644 aaaa 0\tcore/a.c\n100644 dddd 0\tcore/m.tl\n"
  assert(SeededBoot.listed(tree) == "100644 aaaa core/a.c\n100755 bbbb vendor/x/run", SeededBoot.listed(tree))
  assert(SeededBoot.listed(tree) == SeededBoot.listed(index))
  for _, other in ipairs({
      "100644 aaab 0\tcore/a.c\n100755 bbbb 0\tvendor/x/run\n",
      "100755 aaaa 0\tcore/a.c\n100755 bbbb 0\tvendor/x/run\n",
      "100644 aaaa 0\tcore/a.c\n",
      index .. "100644 eeee 0\tcore/b.h\n",
      "100644 aaaa 0\tcore/a.c\n100755 bbbb 0\tvendor/x/run\n100644 ffff 0\tvendor/y.tl\n",
  }) do
    assert(SeededBoot.listed(tree) ~= SeededBoot.listed(other), other)
  end
  assert(SeededBoot.listed("") == "")
end

--- Unasked, a boot tries the pinned release and then the newest one;
--- `pin` keeps it to the pinned release, whose digest the checkout names,
--- and asks the network nothing. `0` is no seeded boot, and any other
--- value is refused.
local function test_pin_keeps_a_boot_to_the_pinned_release()
  local unset = assert(SeededBoot.plan(""))
  assert(unset.newest and not unset.offline)
  local pin = assert(SeededBoot.plan("pin"))
  assert(not pin.newest and pin.offline)
  local off, off_why = SeededBoot.plan("0")
  assert(off == nil and off_why == "", off_why)
  for _, other in ipairs({ "1", "yes", "newest", "PIN", "pin " }) do
    local refused, why = SeededBoot.plan(other)
    assert(refused == nil and why:find("COSMIC_BOOT_SEED is " .. other .. ":", 1, true) == 1, why)
  end
end

--- A release kept in the cache under its digest's name is hashed again
--- before it runs, against a stale or poisoned cache: one whose bytes are
--- not that digest's is not taken, and is removed so that it is fetched
--- again, and so is a link there, even to the right bytes.
local function test_a_kept_release_is_hashed_before_it_runs(tmp: string)
  local good = "the release's bytes"
  local digest = Hash.hex_sha256(good)
  local path = tmp .. "/cosmic-" .. digest
  local kept, why = SeededBoot.cached(tmp, digest)
  assert(kept == nil and why == "it is not there", why)
  assert(Fs.write(path, good, 0x1ed))
  kept, why = SeededBoot.cached(tmp, digest)
  assert(kept == path and why == "", why)
  assert(Fs.write(path, "other bytes", 0x1ed))
  kept, why = SeededBoot.cached(tmp, digest)
  assert(kept == nil and why == "its bytes are not its digest's", why)
  assert(Fs.exists(path) == false, "a release with other bytes was kept")
  assert(Fs.write(tmp .. "/elsewhere", good, 0x1ed))
  assert(Fs.symlink(tmp .. "/elsewhere", path))
  kept, why = SeededBoot.cached(tmp, digest)
  assert(kept == nil and why == "a link stood there", why)
  local link, _ = Fs.readlink(path)
  assert(link == nil and Fs.exists(path) == false, "a link in the cache was kept")
end
