local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")

local function test_path_predicates_distinguish_answers_from_errors(tmp: string)
  local file = tmp .. "/file"
  assert(Fs.write(file, "contents"))

  local exists, exists_trouble = Fs.exists(file)
  assert(exists == true and exists_trouble == "")
  local directory, directory_trouble = Fs.is_dir(tmp)
  assert(directory == true and directory_trouble == "")
  local plain, plain_trouble = Fs.is_dir(file)
  assert(plain == false and plain_trouble == "")

  local missing, missing_trouble = Fs.exists(tmp .. "/missing")
  assert(missing == false and missing_trouble == "")
  local below_file, below_file_trouble = Fs.exists(file .. "/child")
  assert(below_file == false and below_file_trouble == "")
  local missing_dir, missing_dir_trouble = Fs.is_dir(tmp .. "/missing")
  assert(missing_dir == false and missing_dir_trouble == "")

  local too_long = tmp .. "/" .. string.rep("x", 300)
  local unknown, unknown_trouble = Fs.exists(too_long)
  assert(unknown == nil and unknown_trouble:find(too_long, 1, true))
  local unknown_dir, unknown_dir_trouble = Fs.is_dir(too_long)
  assert(unknown_dir == nil and unknown_dir_trouble:find(too_long, 1, true))
end

local function test_remove_tolerates_absence_but_reports_other_errors(tmp: string)
  local missing = tmp .. "/missing"
  local gone, gone_trouble = Fs.remove(missing)
  assert(gone and gone_trouble == "")

  local file = tmp .. "/file"
  assert(Fs.write(file, "contents"))
  local below_file, below_file_trouble = Fs.remove(file .. "/child")
  assert(below_file and below_file_trouble == "")
  local removed, removed_trouble = Fs.remove(file)
  assert(removed and removed_trouble == "")
  assert(Fs.exists(file) == false)

  local too_long = tmp .. "/" .. string.rep("x", 300)
  local failed, trouble = Fs.remove(too_long)
  assert(not failed and trouble:find(too_long, 1, true))
end

local function test_write_leaves_the_old_fixed_neighbor_untouched(tmp: string)
  local path = tmp .. "/target"
  local neighbor = path .. ".writing"
  assert(Fs.write(path, "old"))
  assert(Fs.write(neighbor, "belongs to somebody else"))
  assert(Fs.write(path, "new"))
  assert(Fs.read(path) == "new")
  assert(Fs.read(neighbor) == "belongs to somebody else")
end

local function test_interleaved_writers_have_distinct_temporary_files(tmp: string)
  local path = tmp .. "/target"
  assert(Fs.write(path, "old"))
  local real_open_temporary = sys.open_temporary
  local real_write = sys.write
  local temporaries: {string} = {}
  local nested = false
  sys.open_temporary = function(destination: string, mode?: integer): sys.TemporaryFile | nil, string, integer
    local file, trouble, number = real_open_temporary(destination, mode)
    if file ~= nil then
      temporaries[#temporaries + 1] = file.path
    end
    return file, trouble, number
  end
  sys.write = function(fd: integer, data: string): integer | nil, string, integer
    if not nested then
      nested = true
      assert(Fs.write(path, "inner"))
    end
    return real_write(fd, data)
  end
  local ok, trouble = Fs.write(path, "outer")
  sys.write = real_write
  sys.open_temporary = real_open_temporary
  assert(ok, trouble)
  assert(#temporaries == 2 and temporaries[1] ~= temporaries[2])
  assert(Fs.read(path) == "outer")
end

local function test_write_failure_preserves_destination_and_cleans_its_temp(tmp: string)
  local path = tmp .. "/target"
  assert(Fs.write(path, "old"))
  local real_write = sys.write
  local created = ""
  local real_open_temporary = sys.open_temporary
  sys.open_temporary = function(destination: string, mode?: integer): sys.TemporaryFile | nil, string, integer
    local file, trouble, number = real_open_temporary(destination, mode)
    if file ~= nil then created = file.path end
    return file, trouble, number
  end
  sys.write = function(_fd: integer, _data: string): integer | nil, string, integer
    return nil, "injected write failure", 0
  end
  local ok, trouble = Fs.write(path, "new")
  sys.write = real_write
  sys.open_temporary = real_open_temporary
  assert(not ok and trouble:find("injected write failure", 1, true))
  assert(Fs.read(path) == "old")
  assert(created ~= "" and Fs.exists(created) == false)
end

local function test_close_failure_preserves_destination_and_cleans_its_temp(tmp: string)
  local path = tmp .. "/target"
  assert(Fs.write(path, "old"))
  local real_close = sys.close
  local real_open_temporary = sys.open_temporary
  local created = ""
  local injected_fd = -1
  sys.open_temporary = function(destination: string, mode?: integer): sys.TemporaryFile | nil, string, integer
    local file, trouble, number = real_open_temporary(destination, mode)
    if file ~= nil then
      created = file.path
      injected_fd = file.fd
    end
    return file, trouble, number
  end
  sys.close = function(fd: integer): boolean, string, integer
    if fd == injected_fd then
      real_close(fd)
      return false, "injected close failure", 0
    end
    local ok, trouble, number = real_close(fd)
    return ok, trouble, number
  end
  local ok, trouble = Fs.write(path, "new")
  sys.close = real_close
  sys.open_temporary = real_open_temporary
  assert(not ok and trouble:find("injected close failure", 1, true))
  assert(Fs.read(path) == "old")
  assert(created ~= "" and Fs.exists(created) == false)
end

local function test_rename_failure_preserves_destination_and_cleans_its_temp(tmp: string)
  local path = tmp .. "/target"
  assert(Fs.write(path, "old"))
  local real_rename = sys.rename
  local real_open_temporary = sys.open_temporary
  local created = ""
  sys.open_temporary = function(destination: string, mode?: integer): sys.TemporaryFile | nil, string, integer
    local file, trouble, number = real_open_temporary(destination, mode)
    if file ~= nil then created = file.path end
    return file, trouble, number
  end
  sys.rename = function(_from: string, _to: string): boolean, string, integer
    return false, "injected rename failure", 0
  end
  local ok, trouble = Fs.write(path, "new")
  sys.rename = real_rename
  sys.open_temporary = real_open_temporary
  assert(not ok and trouble:find("injected rename failure", 1, true))
  assert(Fs.read(path) == "old")
  assert(created ~= "" and Fs.exists(created) == false)
end

local function test_put_rejects_zero_progress(tmp: string)
  local path = tmp .. "/stream"
  local fd = assert(Fs.open_write(path))
  local real_write = sys.write
  sys.write = function(_fd: integer, _data: string): integer | nil, string, integer
    return 0, "", 0
  end
  local ok, trouble = Fs.put(fd, "data")
  sys.write = real_write
  assert(Fs.close(fd))
  assert(not ok and trouble == "write made no progress")
end

local function test_cache_dir_has_no_shared_fallback()
  for _, environment in ipairs({ {}, { HOME = "" }, { XDG_CACHE_HOME = "rel", HOME = "also/rel" } }) do
    local dir, trouble = Fs.cache_dir("tool", environment)
    assert(dir == nil and trouble:find("no cache directory", 1, true) ~= nil, tostring(dir))
  end
end

local function test_cache_dir_is_made_private_under_xdg_or_home(tmp: string)
  local dir = assert(Fs.cache_dir("tool", { XDG_CACHE_HOME = tmp .. "/xdg", HOME = tmp .. "/home" }))
  assert(dir == tmp .. "/xdg/cosmic/tool", dir)
  for _, path in ipairs({ tmp .. "/xdg/cosmic", dir }) do
    local st = assert(Fs.stat(path))
    assert(st.uid == sys.getuid() and st.mode & 0x3f == 0, path)
  end
  -- a relative XDG_CACHE_HOME is ignored, as the XDG spec says
  dir = assert(Fs.cache_dir("tool", { XDG_CACHE_HOME = "rel", HOME = tmp .. "/home" }))
  assert(dir == tmp .. "/home/.cache/cosmic/tool", dir)
end

local function test_cache_dir_refuses_one_others_can_write_to(tmp: string)
  local environment = { XDG_CACHE_HOME = tmp }
  assert(Fs.cache_dir("tool", environment))
  assert(sys.chmod(tmp .. "/cosmic/tool", 0x1ff))
  local dir, trouble = Fs.cache_dir("tool", environment)
  assert(dir == nil and trouble:find("writable by its group or others", 1, true) ~= nil, trouble)
  assert(sys.chmod(tmp .. "/cosmic", 0x1f8))
  dir, trouble = Fs.cache_dir("other", environment)
  assert(dir == nil and trouble == tmp .. "/cosmic: writable by its group or others", trouble)
  assert(Fs.write(tmp .. "/plain", ""))
  dir, trouble = Fs.cache_dir("tool", { XDG_CACHE_HOME = tmp .. "/plain" })
  assert(dir == nil, tostring(dir))
end

local function test_mkdirs_with_a_trailing_slash_makes_every_parent()
  local root = assert(Fs.mkdtemp("mkdirs"))
  local ok, trouble = Fs.mkdirs(root .. "/a/b/c/")
  assert(ok, trouble)
  assert(Fs.is_dir(root .. "/a/b/c") == true)
end

local function test_symlink_and_readlink_round_trip(tmp: string)
  local target = tmp .. "/target"
  local link = tmp .. "/link"
  assert(Fs.write(target, "contents"))
  local made, trouble = Fs.symlink(target, link)
  assert(made and trouble == "")

  local read_back, read_trouble = Fs.readlink(link)
  assert(read_back == target and read_trouble == "")

  -- The link resolves through to the target's contents.
  assert(Fs.read(link) == "contents")

  local missing, missing_trouble = Fs.readlink(tmp .. "/missing")
  assert(missing == nil and missing_trouble:find(tmp .. "/missing", 1, true))
end

--- The modification time is set to the nanosecond, and the access
--- time is left as it was.
local function test_set_mtime_sets_nanoseconds_and_leaves_the_access_time(tmp: string)
  local path = tmp .. "/file"
  assert(Fs.write(path, "contents"))
  assert(sys.utimensat(path, 1000, 7))
  local set, trouble = Fs.set_mtime(path, 2000, 123456789)
  assert(set and trouble == "")
  local st = assert(sys.stat(path))
  assert(st.mtime == 2000 and st.mtime_ns == 123456789, st.mtime .. "." .. st.mtime_ns)
  assert(st.atime == 1000 and st.atime_ns == 7, st.atime .. "." .. st.atime_ns)
end

--- A whole second is the default, and nanoseconds out of range are a
--- mistake that raises rather than a time to set.
local function test_set_mtime_defaults_to_a_whole_second_and_checks_ns(tmp: string)
  local path = tmp .. "/file"
  assert(Fs.write(path, "contents"))
  assert(Fs.set_mtime(path, 3000, 5))
  assert(Fs.set_mtime(path, 4000))
  local st = assert(sys.stat(path))
  assert(st.mtime == 4000 and st.mtime_ns == 0, st.mtime .. "." .. st.mtime_ns)
  local ok, why = pcall(Fs.set_mtime, path, 4000, 1000000000)
  assert(not ok and tostring(why):find("#3 to 'set_mtime'", 1, true), tostring(why))
  assert(not pcall(Fs.set_mtime, path, 4000, -1))
end

local function test_chmod_sets_the_bits_stat_reads_back(tmp: string)
  local path = tmp .. "/file"
  assert(Fs.write(path, "contents", 0x1a4))
  local set, trouble = Fs.chmod(path, 0x9c0)
  assert(set and trouble == "", trouble)
  assert(assert(Fs.stat(path)).mode & 0xfff == 0x9c0)
  assert(Fs.chmod(path, 0))
  assert(assert(Fs.stat(path)).mode & 0xfff == 0)

  assert(not pcall(Fs.chmod, path, -1))
  assert(not pcall(Fs.chmod, path, 0x1000))
  assert(assert(Fs.stat(path)).mode & 0xfff == 0)

  local missing, missing_trouble = Fs.chmod(tmp .. "/missing", 0x1a4)
  assert(not missing and missing_trouble:find(tmp .. "/missing", 1, true))
end

local function test_fsync_reports_bad_descriptor(tmp: string)
  local path = tmp .. "/file"
  local fd = assert(Fs.open_write(path))
  local ok, trouble = Fs.fsync(fd)
  assert(ok and trouble == "")
  assert(Fs.close(fd))

  local failed, failed_trouble = Fs.fsync(fd)
  assert(not failed and failed_trouble ~= "")
end

local function test_remove_tree_removes_everything_but_follows_no_link(tmp: string)
  local outside = tmp .. "/outside"
  assert(Fs.mkdirs(outside))
  assert(Fs.write(outside .. "/keep", "kept"))
  local tree = tmp .. "/tree"
  assert(Fs.mkdirs(tree .. "/a/b"))
  assert(Fs.write(tree .. "/a/b/file", "gone"))
  assert(Fs.write(tree .. "/top", "gone"))
  assert(Fs.symlink(outside, tree .. "/a/link"))
  assert(Fs.remove_tree(tree))
  assert(Fs.exists(tree) == false)
  assert(Fs.read(outside .. "/keep") == "kept", "a link was followed")
  -- Already gone is not a failure, and neither is a plain file.
  assert(Fs.remove_tree(tree))
  assert(Fs.remove_tree(outside .. "/keep"))
  assert(Fs.exists(outside .. "/keep") == false)
end

--- A regular file comes back in the one read its size asks for, and a
--- file that says nothing true of its size (/proc's) in chunks.
local function test_read_takes_a_file_in_the_one_read_its_size_asks_for(tmp: string)
  local path = tmp .. "/big"
  local data = string.rep("0123456789abcdef", 20000)
  assert(Fs.write(path, data))
  local real_read = sys.read
  local reads = 0
  sys.read = function(fd: integer, count: integer): string | nil, string, integer
    reads = reads + 1
    return real_read(fd, count)
  end
  local read, trouble = Fs.read(path)
  local file_reads = reads
  local proc = Fs.exists("/proc/self/status") and Fs.read("/proc/self/status") or nil
  sys.read = real_read
  assert(read == data, trouble)
  assert(file_reads == 2, "one read for the bytes and one for the end, not " .. file_reads)
  if proc ~= nil then
    assert(proc:find("SigIgn:", 1, true) ~= nil, proc)
  end
end

--- A write the kernel takes part of goes on from where it stopped.
local function test_write_resumes_a_short_write(tmp: string)
  local path = tmp .. "/short"
  local real_write = sys.write
  sys.write = function(fd: integer, bytes: string): integer | nil, string, integer
    return real_write(fd, bytes:sub(1, 3))
  end
  local ok, trouble = Fs.write(path, "abcdefghij")
  sys.write = real_write
  assert(ok, trouble)
  assert(Fs.read(path) == "abcdefghij")
end

local function test_copy_tree_keeps_bytes_modes_times_and_links(tmp: string)
  local from = tmp .. "/from"
  assert(Fs.mkdirs(from .. "/sub/empty"))
  local big = ("0123456789abcdef"):rep(200000)
  assert(Fs.write(from .. "/big", big))
  assert(Fs.write(from .. "/sub/run", "#!/bin/sh\n", 0x1ed))
  assert(sys.chmod(from .. "/sub/run", 0x1e8))
  assert(Fs.write(from .. "/sub/secret", "s", 0x180))
  assert(Fs.symlink("../big", from .. "/sub/link"))
  assert(Fs.symlink("nowhere", from .. "/dangling"))
  assert(Fs.set_mtime(from .. "/big", 1000000000, 123456789))
  assert(Fs.set_mtime(from .. "/sub/link", 1500000000, 5))
  -- 2300-01-01, past the last time nanoseconds since the epoch can count.
  assert(sys.utimensat(from .. "/sub/secret", 1000000000, 42, 10413792000, 7))
  assert(sys.chmod(from .. "/sub", 0x16d))
  local to = tmp .. "/to"
  local copied, trouble = Fs.copy_tree(from, to)
  assert(copied, trouble)
  assert(assert(Fs.read(to .. "/big")) == big)
  local big_st = assert(Fs.stat(to .. "/big"))
  assert(big_st.mtime == 1000000000 and big_st.mtime_ns == 123456789,
    big_st.mtime .. "." .. big_st.mtime_ns)
  assert(assert(Fs.stat(to .. "/sub/run")).mode & 0xfff == 0x1e8)
  local secret = assert(Fs.stat(to .. "/sub/secret"))
  assert(secret.mode & 0xfff == 0x180)
  -- What the filesystem kept of 2300: itself where it counts seconds
  -- (ext4), its own last time where it counts nanoseconds (APFS).
  local kept = assert(Fs.stat(from .. "/sub/secret"))
  assert(secret.mtime == kept.mtime and secret.mtime_ns == kept.mtime_ns,
    secret.mtime .. "." .. secret.mtime_ns)
  assert(secret.atime == 1000000000 and secret.atime_ns == 42, secret.atime .. "." .. secret.atime_ns)
  assert(assert(Fs.stat(to .. "/sub")).mode & 0xfff == 0x16d)
  assert(assert(Fs.is_dir(to .. "/sub/empty")))
  assert(assert(Fs.readlink(to .. "/sub/link")) == "../big")
  local link_st = assert(sys.lstat(to .. "/sub/link"))
  assert(link_st.mtime == 1500000000 and link_st.mtime_ns == 5,
    link_st.mtime .. "." .. link_st.mtime_ns)
  assert(assert(Fs.readlink(to .. "/dangling")) == "nowhere")
  assert(sys.chmod(from .. "/sub", 0x1ed) and sys.chmod(to .. "/sub", 0x1ed))
end

local function test_copy_tree_refuses_an_existing_target(tmp: string)
  assert(Fs.mkdirs(tmp .. "/from") and Fs.mkdirs(tmp .. "/to"))
  local copied, trouble = Fs.copy_tree(tmp .. "/from", tmp .. "/to")
  assert(not copied and trouble == tmp .. "/to: already exists", trouble)
  local missing, why = Fs.copy_tree(tmp .. "/absent", tmp .. "/new")
  assert(not missing and why:find("absent", 1, true), why)
end

local function test_copy_tree_copies_a_single_file(tmp: string)
  assert(Fs.write(tmp .. "/one", "1", 0x1c0))
  assert(Fs.copy_tree(tmp .. "/one", tmp .. "/two"))
  assert(assert(Fs.read(tmp .. "/two")) == "1")
  assert(assert(Fs.stat(tmp .. "/two")).mode & 0xfff == 0x1c0)
end

local function test_copy_tree_into_itself_copies_once(tmp: string)
  local from = tmp .. "/a"
  assert(Fs.mkdirs(from .. "/x"))
  assert(Fs.write(from .. "/x/f", "f"))
  local copied, trouble = Fs.copy_tree(from, from .. "/b")
  assert(copied, trouble)
  assert(assert(Fs.read(from .. "/b/x/f")) == "f")
  assert(Fs.exists(from .. "/b/b") == false, "the copy was copied again")
end

local function test_copy_tree_names_why_a_target_cannot_be_made(tmp: string)
  assert(Fs.write(tmp .. "/file", "f"))
  local copied, trouble = Fs.copy_tree(tmp .. "/file", tmp .. "/file/x")
  assert(not copied and not trouble:find("already exists", 1, true) and
    trouble:find(tmp .. "/file/x", 1, true), trouble)
end

local function test_copy_tree_drops_setuid_and_setgid(tmp: string)
  assert(Fs.write(tmp .. "/run", "#!/bin/sh\n", 0x1ed))
  assert(sys.chmod(tmp .. "/run", 0x9ed))
  assert(Fs.copy_tree(tmp .. "/run", tmp .. "/copy"))
  assert(assert(Fs.stat(tmp .. "/copy")).mode & 0xfff == 0x1ed)
end

local function test_basename_as_basename_names_it()
  local cases: {{string}} = {
    { "a", "a" }, { "a/b", "b" }, { "a/b/", "b" }, { "/a", "a" },
    { "/", "/" }, { "//", "/" }, { "", "" }, { "a//b//", "b" }, { ".", "." },
  }
  for _, case in ipairs(cases) do
    assert(Fs.basename(case[1]) == case[2],
      case[1] .. ": " .. Fs.basename(case[1]))
  end
end

local function test_dirname_as_dirname_answers()
  local cases: {{string}} = {
    { "a", "." }, { "a/b", "a" }, { "a/b/", "a" }, { "/a", "/" },
    { "/a/", "/" }, { "/", "/" }, { "//", "/" }, { "", "." },
    { "a//b", "a" }, { "/a/b/c", "/a/b" }, { "a/..", "a" }, { "//a", "/" },
  }
  for _, case in ipairs(cases) do
    assert(Fs.dirname(case[1]) == case[2],
      case[1] .. ": " .. Fs.dirname(case[1]))
  end
end

local function test_within_compares_whole_components()
  assert(Fs.within("a/b", "a/b"))
  assert(Fs.within("a/b/c", "a/b"))
  assert(not Fs.within("a/bc", "a/b"))
  assert(not Fs.within("a", "a/b"))
  assert(Fs.within("/x/y", "/"))
  assert(Fs.within("a/b/c", "a/b/"))
  assert(Fs.within("a/b", "a/b/"))
  assert(not Fs.within("a/bc", "a/b/"))
  assert(not Fs.within("a", ""))
end

local function test_relative_answers_the_rest_or_why_not()
  assert(Fs.relative("a/b/c", "a/b") == "c")
  assert(Fs.relative("a/b/c/d", "a/b") == "c/d")
  assert(Fs.relative("a/b", "a/b") == ".")
  assert(Fs.relative("/x/y", "/") == "x/y")
  assert(Fs.relative("a/b/c", "a/b/") == "c")
  local rest, why = Fs.relative("a/bc", "a/b")
  assert(rest == nil and why == "a/bc: not within a/b", why)
end

local function test_path_edges_the_call_sites_rely_on()
  assert(Fs.dirname("///a") == "/" and Fs.basename("///a") == "a")
  assert(Fs.dirname("a/./b") == "a/." and Fs.basename("a/b/.") == ".")
  assert(Fs.within("a/", "a") and Fs.within("a/b", "a//"))
  assert(Fs.within("/b", "//") and not Fs.within("b", "/"))
  assert(Fs.relative("a//b", "a") == "b")
  assert(Fs.relative("a/b/", "a") == "b")
  assert(Fs.relative("/", "/") == ".")
  assert(Fs.relative("a", "") == nil)
end

local function test_paths_are_linear_in_runs_of_slashes()
  local slashes = ("/"):rep(200000)
  assert(Fs.basename(slashes .. "a" .. slashes) == "a")
  assert(Fs.dirname(slashes .. "a" .. slashes) == "/")
  assert(Fs.within("a" .. slashes, "a"))
end

local function test_truncate_cuts_and_extends(tmp: string)
  local path = tmp .. "/file"
  assert(Fs.write(path, "abcdef"))
  local fd = assert(sys.open(path, sys.O_WRONLY))
  local cut, cut_trouble = Fs.truncate(fd, 2)
  assert(cut and cut_trouble == "", cut_trouble)
  assert(Fs.truncate(fd, 4))
  assert(not pcall(Fs.truncate, fd, -1))
  assert(Fs.close(fd))
  assert(assert(Fs.read(path)) == "ab\0\0")
  local failed, trouble = Fs.truncate(fd, 0)
  assert(not failed and trouble ~= "", "a closed descriptor was truncated")
end
