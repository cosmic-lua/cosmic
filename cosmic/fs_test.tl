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

local function test_set_mtime_changes_the_stat(tmp: string)
  local path = tmp .. "/file"
  assert(Fs.write(path, "contents"))
  local set, trouble = Fs.set_mtime(path, 1000, 2000)
  assert(set and trouble == "")
  local st = assert(sys.stat(path))
  assert(st.mtime == 2000)
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
