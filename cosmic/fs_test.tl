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
