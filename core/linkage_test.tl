--- How every core is linked: on Linux each is static musl, the checked
--- core too (build.zig, above `checked_target`), so no shared object --
--- no dynamic loader, no libc or libm of the host's -- is mapped into
--- a core's process, and a test's floats and libc are the ones that
--- ship. macOS's cores link libSystem, which is shared, and are not
--- held to this.

local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

--- /proc, where a process's own mappings are listed.
Test.needs{ host = { "/proc" } }

--- The shared objects mapped into this process, by their paths in
--- /proc/self/maps, each once, sorted.
local function shared_objects(maps: string): {string}
  local seen: {string:boolean} = {}
  local paths: {string} = {}
  for line in maps:gmatch("[^\n]+") do
    -- address perms offset dev inode, then the path, which may hold
    -- spaces (a deleted file's " (deleted)").
    local path = line:match("^%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+(/.*)$")
    if path ~= nil and not seen[path] then
      local name = path:match("([^/]*)$")
      if name:find("%.so$") ~= nil or name:find("%.so[%.%s]") ~= nil or
          name:find("^ld%-") ~= nil then
        seen[path] = true
        paths[#paths + 1] = path
      end
    end
  end
  table.sort(paths)
  return paths
end

local function test_shared_objects_are_found_by_name()
  local maps = table.concat({
    "00400000-00401000 r--p 00000000 08:01 42 /tree/o/bin/cosmic",
    "7f00-7f01 r-xp 00000000 08:01 7 /usr/lib/x86_64-linux-gnu/libm.so.6",
    "7f01-7f02 r--p 00001000 08:01 7 /usr/lib/x86_64-linux-gnu/libm.so.6",
    "7f02-7f03 r-xp 00000000 08:01 8 /usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2",
    "7f03-7f04 r--s 00000000 08:01 9 /tree/o/cosmic.db",
    "7f04-7f05 r-xp 00000000 08:01 10 /lib/libfoo.so (deleted)",
    "7ffd-7ffe r-xp 00000000 00:00 0 [vdso]",
    "7ffe-7fff rw-p 00000000 00:00 0",
  }, "\n") .. "\n"
  local found = shared_objects(maps)
  assert(#found == 3, table.concat(found, ", "))
  assert(found[1] == "/lib/libfoo.so (deleted)")
  assert(found[2] == "/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2")
  assert(found[3] == "/usr/lib/x86_64-linux-gnu/libm.so.6")
end

--- A Linux core maps no shared object: a checked core linked to the
--- build host's glibc mapped its loader, libc and libm.
local function test_a_linux_core_maps_no_shared_object()
  local names = assert(sys.uname())
  if names.sysname ~= "Linux" then return end
  local maps = assert(Fs.read("/proc/self/maps"))
  assert(maps:find("\n", 1, true) ~= nil, "/proc/self/maps names no mapping")
  local found = shared_objects(maps)
  assert(#found == 0, "shared objects mapped into a core: " .. table.concat(found, ", "))
end
