local mountinfo = require("build.mountinfo")

local sample = table.concat({
  "22 1 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw",
  "30 22 0:40 / /home rw,relatime shared:5 - nfs4 server:/home " ..
    "rw,vers=4.2,rsize=1048576,local_lock=none,addr=10.0.0.1",
  "31 30 8:2 / /home/user/local rw master:3 shared:7 - ext4 /dev/sda2 rw",
  "32 22 0:41 / /mnt/my\\040share rw - cifs //server/share rw,vers=3.1.1",
  "33 22 0:42 / /mnt/back\\134slash rw - tmpfs tmpfs rw",
  "a line that does not parse",
  "34 22 0:43 / /mnt/nosep rw shared:9",
}, "\n") .. "\n"

--- The deepest mount holding a path answers for it: the NFS home, the
--- local disk mounted inside it, the root for everything else.
local function test_the_longest_mount_point_holding_a_path_answers()
  local home = assert(mountinfo.mount_of(sample, "/home/user/wt/o/rebuild.lock"))
  assert(home.point == "/home" and home.fstype == "nfs4", home.point)
  assert(home.options:find("local_lock=none", 1, true), home.options)
  local nested = assert(mountinfo.mount_of(sample, "/home/user/local/tree"))
  assert(nested.point == "/home/user/local" and nested.fstype == "ext4", nested.point)
  assert(assert(mountinfo.mount_of(sample, "/home/user/local")).fstype == "ext4")
  local root = assert(mountinfo.mount_of(sample, "/homework"))
  assert(root.point == "/" and root.fstype == "ext4", root.point)
end

--- A mount point's escaped space and backslash are matched as written
--- in the path, and a line with no " - " is passed over.
local function test_escaped_mount_points_and_unparsed_lines()
  local share = assert(mountinfo.mount_of(sample, "/mnt/my share/tree"))
  assert(share.point == "/mnt/my share" and share.fstype == "cifs", share.point)
  local slash = assert(mountinfo.mount_of(sample, "/mnt/back\\slash"))
  assert(slash.fstype == "tmpfs", slash.fstype)
  assert(assert(mountinfo.mount_of(sample, "/mnt/nosep/x")).point == "/")
  assert(mountinfo.mount_of("", "/x") == nil)
end

--- Of two mounts at one point, the one listed last is on top.
local function test_the_mount_listed_last_at_a_point_is_on_top()
  local text = "22 1 8:1 / / rw - ext4 /dev/sda1 rw\n" ..
    "40 22 0:50 / /srv rw - ext4 /dev/sdb1 rw\n" ..
    "41 40 0:51 / /srv rw - nfs server:/srv rw,local_lock=flock\n"
  local top = assert(mountinfo.mount_of(text, "/srv/tree"))
  assert(top.fstype == "nfs" and top.options == "rw,local_lock=flock", top.fstype)
end
