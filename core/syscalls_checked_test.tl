--- What the checked core's instruments reach of the syscall bindings: a
--- directory entry of unknown type, a path buffer too small, and the mount
--- table of an NFS file. Another core has none of them, so this module
--- requires `checked`.

local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local testing = require("cosmic.internal.testing")
local Test = require("cosmic.test")

Test.policy{ requires = { "checked" } }

--- An entry whose type the filesystem leaves unknown is asked with an
--- lstat, which answers a link as one too: the checked core's fault
--- point makes each entry in turn unknown.
local function test_readdir_names_an_entry_of_unknown_type_as_lstat_does(tmp: string)
  local d = tmp .. "/d"
  assert(sys.mkdir(d))
  assert(Fs.write(d .. "/file", ""))
  assert(sys.mkdir(d .. "/sub"))
  assert(sys.mkfifo(d .. "/fifo"))
  assert(sys.symlink("file", d .. "/to_file"))
  assert(sys.symlink("sub", d .. "/to_dir"))
  assert(sys.symlink("missing", d .. "/dangling"))
  local want: {string:sys.Kind} = { file = "file", sub = "dir", fifo = "fifo", to_file = "link",
    to_dir = "link", dangling = "link" }
  for skip = 0, 5 do
    testing.fail_at("readdir_d_type", skip)
    local entries = assert(sys.readdir(d))
    assert(not testing.fail_at(), "entry " .. skip .. " never reached readdir_d_type")
    for name, kind in pairs(want) do
      assert(entries[name] == kind, "entry " .. skip .. " of unknown type: " .. name .. " is " ..
          tostring(entries[name]))
    end
  end
end

--- The core's own lookup of its path refuses a buffer the path does not
--- fit in, NUL included, rather than answering it cut short. Only the
--- checked core can hand it a buffer that small.
local function test_executable_path_refuses_a_room_it_does_not_fit()
  local path = assert(testing.executable_path(4096))
  assert(path:sub(1, 1) == "/", "the executable's path is absolute")
  assert(testing.executable_path(#path + 1) == path)
  local short = testing.executable_path(#path)
  assert(short == nil, "a path with no room for its NUL came back as " ..
      tostring(short))
  assert(testing.executable_path(1) == nil)
end

--- `flock_kind`'s reading of an NFS file's mount (checked core only,
--- whose instrument reaches it): the lines of its device, the third
--- field, say whether local_lock "flock" or "all" is among the
--- filesystem's own options, after the lone "-"; a mount's own options
--- before it, another device's line, a word that only begins so, and a
--- line that does not parse say nothing.
local function test_flock_kind_reads_an_nfs_mounts_local_lock()
  local sample = table.concat({
    "22 1 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw",
    "30 22 0:40 / /home rw,relatime shared:5 - nfs4 server:/home " ..
      "rw,vers=4.2,rsize=1048576,local_lock=none,addr=10.0.0.1",
    "31 22 0:41 / /mnt/my\\040share rw master:3 shared:7 - nfs server:/a local_lock=flock,rw",
    "32 22 0:42 / /srv rw - nfs server:/srv rw,vers=3,local_lock=all",
    "33 22 0:43 / /opt rw,local_lock=flock - nfs server:/opt rw,local_lock=flocks",
    "a line that does not parse",
    "34 22 0:44 / /mnt/nosep rw shared:9 local_lock=flock",
  }, "\n") .. "\n"
  local want: {string:boolean} = { ["8:1"] = false, ["0:40"] = false, ["0:41"] = true,
    ["0:42"] = true, ["0:43"] = false, ["0:44"] = false, ["0:4"] = false, ["0:420"] = false }
  for device, local_flock in pairs(want) do
    assert(testing.mountinfo_local_flock(sample, device) == local_flock, device)
  end
  assert(not testing.mountinfo_local_flock("", "0:41"))
  assert(testing.mountinfo_local_flock("32 22 0:42 / /srv rw - nfs s:/srv local_lock=all", "0:42"),
    "a last line with no newline")
end

--- The raw calls a sandbox's own setup makes, each in its shape: true, or
--- false, the message and the errno, never a raise. Made so that nothing
--- changes, run as anyone: an unshare of nothing, and the rest on what is
--- not there to act on. What they do inside a sandbox is
--- cosmic/child_policy_nest_checked_test.tl's.
local function test_the_sandbox_calls_answer_true_or_an_errno(tmp: string)
  local function shaped(name: string, ok: boolean, why: string, errno: integer)
    assert(ok == true or (ok == false and type(why) == "string" and why ~= "" and
      math.type(errno) == "integer" and errno > 0), name .. ": " .. tostring(why))
  end
  local missing = tmp .. "/missing"
  local ok, why, errno = testing.unshare(0)
  assert(ok or errno == sys.EPERM, "unshare(0): " .. tostring(why))
  shaped("unshare", ok, why, errno)
  ok, why, errno = testing.mount(nil, missing, nil, 0)
  assert(not ok, "a mount of nothing on nothing")
  shaped("mount", ok, why, errno)
  ok, why, errno = testing.umount2(missing, 0)
  assert(not ok, "an unmount of nothing")
  shaped("umount2", ok, why, errno)
  ok, why, errno = testing.setns(-1, 0)
  assert(not ok, "setns on no descriptor")
  shaped("setns", ok, why, errno)
  ok, why, errno = testing.chroot(missing)
  assert(not ok, "a chroot into nothing")
  shaped("chroot", ok, why, errno)
  assert(not pcall(testing.mount, nil, missing, nil, -1), "negative mount flags raise")
end
