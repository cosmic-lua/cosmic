local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")

local function test_append_creates_preserves_and_accepts_binary_bytes(tmp: string)
  local path = tmp .. "/log"
  local empty = table.pack(Fs.append(path, ""))
  assert(empty.n == 2 and empty[1] == true and empty[2] == "")
  assert(Fs.read(path) == "")
  assert(Fs.append(path, "old\0"))
  assert(Fs.append(path, "new\255"))
  assert(Fs.read(path) == "old\0new\255")
end

local function test_append_creation_modes_obey_umask_and_preserve_existing_inode(tmp: string)
  for i, mode in ipairs({ 0x1a4, 0x180 }) do
    local control = tmp .. "/control" .. i
    local fd = assert(sys.open(control, sys.O_WRONLY | sys.O_CREAT | sys.O_APPEND, mode))
    assert(sys.close(fd))
    local path = tmp .. "/log" .. i
    if i == 1 then assert(Fs.append(path, "")) else assert(Fs.append(path, "", mode)) end
    local before = assert(Fs.stat(path))
    assert(before.mode == assert(Fs.stat(control)).mode)
    assert(Fs.append(path, "more", 0x1ff))
    local after = assert(Fs.stat(path))
    assert(after.ino == before.ino and after.dev == before.dev and after.mode == before.mode)
  end
end

local function test_append_follows_symlink_without_replacing_it(tmp: string)
  local path = tmp .. "/target"
  local link = tmp .. "/link"
  assert(Fs.write(path, "before"))
  assert(Fs.symlink("target", link))
  assert(Fs.append(link, "after"))
  assert(Fs.readlink(link) == "target" and Fs.read(path) == "beforeafter")
end

local function test_append_open_failures_name_the_path(tmp: string)
  for _, path in ipairs({ tmp, tmp .. "/missing/log" }) do
    local result = table.pack(Fs.append(path, "data"))
    assert(result.n == 2 and result[1] == false)
    assert((result[2] as string):sub(1, #path + 2) == path .. ": ")
  end
  local real_open = sys.open
  sys.open = function(_path: string, _flags: integer, _mode?: integer): integer | nil, string, integer
    return nil, "permission denied", sys.EACCES
  end
  local ok, why = Fs.append(tmp .. "/denied", "data")
  sys.open = real_open
  assert(not ok and why == tmp .. "/denied: permission denied", why)
  assert(Fs.exists(tmp .. "/denied") == false)
end

local function test_append_completes_short_writes(tmp: string)
  local path = tmp .. "/log"
  assert(Fs.write(path, "before"))
  local real_write = sys.write
  local writes = 0
  sys.write = function(fd: integer, data: string): integer | nil, string, integer
    writes = writes + 1
    return real_write(fd, data:sub(1, 2))
  end
  local ok, why = Fs.append(path, "abcdefg")
  sys.write = real_write
  assert(ok and why == "" and writes == 4)
  assert(Fs.read(path) == "beforeabcdefg")
end

local function test_append_zero_progress_closes_once(tmp: string)
  local real_write, real_close = sys.write, sys.close
  local closes = 0
  sys.write = function(_fd: integer, _data: string): integer | nil, string, integer
    return 0, "", 0
  end
  sys.close = function(fd: integer): boolean, string, integer
    closes = closes + 1
    return real_close(fd)
  end
  local path = tmp .. "/log"
  local ok, why = Fs.append(path, "data")
  sys.write, sys.close = real_write, real_close
  assert(not ok and why == path .. ": write made no progress", why)
  assert(closes == 1 and Fs.read(path) == "")
end

local function test_append_partial_failure_keeps_prefix_and_first_error(tmp: string)
  local path = tmp .. "/log"
  assert(Fs.write(path, "before"))
  local real_write, real_close = sys.write, sys.close
  local writes, closes = 0, 0
  sys.write = function(fd: integer, data: string): integer | nil, string, integer
    writes = writes + 1
    if writes == 1 then return real_write(fd, data:sub(1, 2)) end
    return nil, "write refused", 0
  end
  sys.close = function(fd: integer): boolean, string, integer
    closes = closes + 1
    assert(real_close(fd))
    return false, "close refused", 0
  end
  local ok, why = Fs.append(path, "abcdef")
  sys.write, sys.close = real_write, real_close
  assert(not ok and why == path .. ": write refused", why)
  assert(closes == 1 and Fs.read(path) == "beforeab")
end

local function test_append_close_failure_does_not_retry_a_recycled_descriptor(tmp: string)
  local path = tmp .. "/log"
  local real_close = sys.close
  local closes, recycled = 0, -1
  sys.close = function(fd: integer): boolean, string, integer
    closes = closes + 1
    assert(real_close(fd))
    recycled = assert(sys.open(tmp .. "/other", sys.O_WRONLY | sys.O_CREAT, 0x180))
    return false, "close refused", 0
  end
  local ok, why = Fs.append(path, "data")
  sys.close = real_close
  local written = sys.write(recycled, "still open")
  assert(sys.close(recycled))
  assert(not ok and why == path .. ": close refused", why)
  assert(closes == 1 and written == 10 and Fs.read(path) == "data")
end

local function test_append_raising_write_releases_descriptor_and_keeps_exception(tmp: string)
  local real_write, real_close = sys.write, sys.close
  local closes = 0
  local marker = {}
  sys.write = function(_fd: integer, _data: string): integer | nil, string, integer
    error(marker)
  end
  sys.close = function(fd: integer): boolean, string, integer
    closes = closes + 1
    return real_close(fd)
  end
  local ok, why = pcall(Fs.append, tmp .. "/log", "data")
  sys.write, sys.close = real_write, real_close
  assert(not ok and why == marker and closes == 1)
end

local function test_append_rejects_invalid_data_before_creating_file(tmp: string)
  local path = tmp .. "/log"
  local ok = pcall(Fs.append, path, {} as string)
  assert(not ok and Fs.exists(path) == false)
end
