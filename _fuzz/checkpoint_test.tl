local check = require("cosmic.check")
local checkpoint = require("_fuzz.checkpoint")
local env = require("cosmic.env")
local fd = require("cosmic.fd")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local testprocess = require("_tool.testprocess")

local HEADER < const > = ">c8i8i8i8I1I1i8I4"
local CAP < const > = 1048576

local function fixture(): checkpoint.Snapshot
  return {seed = -19, iters = 7, iteration = 3, phase = 2, stage = 1,
    draws = 13, input = "a\0\255z"}
end

-- All corrupt headers share the protocol fixture, without guessed offsets.
local function packed(s: checkpoint.Snapshot, magic?: string, length?: integer): string
  return string.pack(HEADER, magic or "CFUZZ001", s.seed, s.iters, s.iteration,
    s.phase, s.stage, s.draws, length or #s.input) .. s.input
end

local function encoded(s: checkpoint.Snapshot): string
  local result = checkpoint.encode(s)
  assert(result.valid, result.error)
  local bytes = result.bytes
  assert(bytes)
  return bytes
end

local function snapshot(result: checkpoint.Decoded): checkpoint.Snapshot
  assert(result.valid, result.error)
  local s = result.snapshot
  assert(s)
  check.equal(result.error, "")
  return s
end

local function invalid(result: checkpoint.Decoded)
  check.equal(result.valid, false)
  check.equal(result.snapshot, nil, "invalid record must not expose an input")
  check.truthy(#result.error > 0)
end

local function test_binary_empty_and_signed_seed_round_trips()
  check.equal(string.packsize(HEADER), 46)
  local all_bytes = ""
  for i = 0, 255 do all_bytes = all_bytes .. string.char(i) end
  for _, seed in ipairs({math.mininteger, -1, 0, math.maxinteger}) do
    for _, input in ipairs({"", all_bytes}) do
      local s = fixture()
      s.seed, s.input = seed, input
      local bytes = encoded(s)
      check.equal(bytes, packed(s))
      local decoded = snapshot(checkpoint.decode(bytes, seed, s.iters))
      check.equal(decoded.input, input)
      check.equal(decoded.seed, seed)
      check.equal(decoded.draws, s.draws)
      check.equal(decoded.iteration, s.iteration)
    end
  end
end

local function test_every_phase_and_stage()
  for phase = 1, 4 do
    for stage = 1, 3 do
      local s = fixture()
      s.phase, s.stage = phase, stage
      if phase ~= 2 then s.draws, s.input = 0, "" end
      local decoded = snapshot(checkpoint.decode(encoded(s), s.seed, s.iters))
      check.equal(decoded.phase, phase)
      check.equal(decoded.stage, stage)
      check.equal(decoded.draws, s.draws)
      check.equal(decoded.input, s.input)
    end
  end
end

local function test_cap_and_oversized_normalization()
  local s = fixture()
  s.input = string.rep("\0", CAP)
  local bytes = encoded(s)
  check.equal(#bytes, string.packsize(HEADER) + CAP)
  check.equal(snapshot(checkpoint.decode(bytes, s.seed, s.iters)).input, s.input)
  s.input, s.stage = s.input .. "x", 3
  local decoded = snapshot(checkpoint.decode(encoded(s), s.seed, s.iters))
  check.equal(decoded.phase, 4)
  check.equal(decoded.stage, 3)
  check.equal(decoded.iteration, s.iteration)
  check.equal(decoded.input, "")
  check.equal(decoded.draws, 0)
  check.equal(s.phase, 2, "encoding must not mutate its caller's snapshot")
  check.equal(#s.input, CAP + 1)
end

local function test_invalid_metadata_is_rejected_by_encode_and_decode()
  local mutations: {function(s: checkpoint.Snapshot)} = {
    function(s: checkpoint.Snapshot) s.iters = 0 end,
    function(s: checkpoint.Snapshot) s.iters = -1 end,
    function(s: checkpoint.Snapshot) s.iteration = 0 end,
    function(s: checkpoint.Snapshot) s.iteration = s.iters + 1 end,
    function(s: checkpoint.Snapshot) s.draws = -1 end,
    function(s: checkpoint.Snapshot) s.phase = 0 end,
    function(s: checkpoint.Snapshot) s.phase = 5 end,
    function(s: checkpoint.Snapshot) s.stage = 0 end,
    function(s: checkpoint.Snapshot) s.stage = 4 end,
  }
  for _, mutate in ipairs(mutations) do
    local s = fixture()
    mutate(s)
    local result = checkpoint.encode(s)
    check.equal(result.valid, false)
    check.equal(result.bytes, nil)
    check.truthy(#result.error > 0)
    invalid(checkpoint.decode(packed(s), s.seed, s.iters))
  end
  for _, phase in ipairs({1, 3, 4}) do
    for _, input in ipairs({"", "x"}) do
      local s = fixture()
      s.phase, s.input = phase, input
      if input ~= "" then s.draws = 0 end
      check.equal(checkpoint.encode(s).valid, false)
      invalid(checkpoint.decode(packed(s), s.seed, s.iters))
    end
  end
end

local function test_malformed_lengths_identity_and_arbitrary_bytes()
  local s = fixture()
  local bytes = encoded(s)
  invalid(checkpoint.decode(bytes, s.seed + 1, s.iters))
  invalid(checkpoint.decode(bytes, s.seed, s.iters + 1))
  for _, bad in ipairs({packed(s, "CFUZZ002"), packed(s, nil, 0),
      packed(s, nil, #s.input - 1), packed(s, nil, #s.input + 1),
      packed(s, nil, CAP + 1), packed(s, nil, 0xffffffff),
      bytes .. "x", bytes:sub(1, -2)}) do
    invalid(checkpoint.decode(bad, s.seed, s.iters))
  end
  for length = 0, #bytes - 1 do
    invalid(checkpoint.decode(bytes:sub(1, length), s.seed, s.iters))
  end
  for byte = 0, 255 do
    local ok, result = pcall(checkpoint.decode, string.rep(string.char(byte), 128),
      s.seed, s.iters)
    check.truthy(ok, "arbitrary bytes must not throw")
    invalid(result)
  end
end

local function test_atomic_write_read_and_fresh_directory_identity()
  local dir = check.must(fs.temp_dir())
  local path = fs.join(dir, "checkpoint")
  local s = fixture()
  invalid(checkpoint.read(path, s.seed, s.iters))
  assert(checkpoint.write(path, s))
  check.equal(check.must(fs.stat(path)):mode() & fs.octal("777"), fs.octal("600"))
  check.equal(snapshot(checkpoint.read(path, s.seed, s.iters)).input, s.input)
  invalid(checkpoint.read(path, s.seed + 1, s.iters))
  invalid(checkpoint.read(path, s.seed, s.iters + 1))
  s.phase, s.draws, s.input = 3, 0, ""
  assert(checkpoint.write(path, s))
  check.equal(snapshot(checkpoint.read(path, s.seed, s.iters)).phase, 3)
  local fresh = check.must(fs.temp_dir())
  invalid(checkpoint.read(fs.join(fresh, "checkpoint"), s.seed, s.iters))
  assert(fs.remove_all(fresh))
  assert(fs.remove_all(dir))
end

local function test_nonregular_paths_and_disk_cap_plus_one()
  local dir = check.must(fs.temp_dir())
  local path = fs.join(dir, "checkpoint")
  local s = fixture()
  invalid(checkpoint.read(dir, s.seed, s.iters))
  assert(checkpoint.write(path, s))
  local link = fs.join(dir, "link")
  assert(fs.symlink(path, link))
  invalid(checkpoint.read(link, s.seed, s.iters))
  s.input = string.rep("x", CAP)
  assert(fs.write(path, encoded(s) .. "x"))
  invalid(checkpoint.read(path, s.seed, s.iters))
  assert(fs.remove_all(dir))
end

local function test_read_budget_and_descriptor_closure()
  local dir = check.must(fs.temp_dir())
  local path = fs.join(dir, "checkpoint")
  assert(fs.write(path, string.rep("x", 2 * CAP)))
  local open = fd.open
  local bytes_read, largest_request = 0, 0
  local handle: fd.Handle | nil
  fd.open = function(p: string, flags: integer, mode?: integer,
      dirfd?: integer): fd.Handle | nil, string
    local h, err = open(p, flags, mode, dirfd)
    if h then
      handle = h
      local read = h.read
      h.read = function(self: fd.Handle, size?: integer, offset?: integer): string | nil, string
        largest_request = math.max(largest_request, size or 0)
        local bytes, read_err = read(self, size, offset)
        if bytes then bytes_read = bytes_read + #bytes end
        return bytes, read_err
      end
    end
    return h, err
  end
  local result = checkpoint.read(path, -19, 7)
  fd.open = open
  invalid(result)
  check.equal(bytes_read, string.packsize(HEADER) + CAP + 1)
  check.truthy(largest_request <= string.packsize(HEADER) + CAP + 1)
  assert(handle)
  check.truthy(handle:closed())
  assert(fs.remove_all(dir))
end

local function test_write_failures_are_values()
  local path = fs.join(os.getenv("TEST_TMPDIR"), "absent", "checkpoint")
  local ok, err = checkpoint.write(path, fixture())
  check.equal(ok, false)
  check.truthy(#err > 0)
  local s = fixture()
  s.phase = 255
  ok, err = checkpoint.write(path, s)
  check.equal(ok, false)
  check.truthy(#err > 0)
  local write = fs.write
  fs.write = function(_path: string, _bytes: string, opts?: fs.WriteOptions): boolean, string
    assert(opts and opts.atomic and opts.mode == fs.octal("600"))
    return false, "injected disk failure"
  end
  ok, err = checkpoint.write(path, fixture())
  fs.write = write
  check.equal(ok, false)
  check.truthy(err:find("injected disk failure", 1, true), err)
end

local function test_fifo_without_writer_exits_normally_under_supervision()
  local dir = check.must(fs.temp_dir())
  local path = fs.join(dir, "fifo")
  local script = fs.join(dir, "child.lua")
  assert(fs.write(script, [[
local checkpoint = require("_fuzz.checkpoint")
local result = checkpoint.read(arg[1], -19, 7)
assert(not result.valid and result.snapshot == nil and #result.error > 0)
print("fifo rejected")
]]))
  local result = testprocess.run({"/bin/sh", "-c",
      'mkfifo "$1" && exec "$2" "$3" "$1"', "checkpoint-fifo", path,
      check.must(proc.interpreter()), script}, {
      temp_dir = dir, env = env.list(), timeout_ms = 5000,
    })
  assert(fs.remove_all(dir))
  check.equal(result.timed_out, false, "FIFO open must not wait for a writer")
  check.equal(result.start_error, "")
  check.equal(result.cleanup_error, "")
  check.equal(result.signal, nil)
  check.equal(result.exit_code, 0, result.stderr)
  check.equal(result.stdout, "fifo rejected\n")
end

local function test_short_reads_and_io_failures_close_the_descriptor()
  local dir = check.must(fs.temp_dir())
  local path = fs.join(dir, "checkpoint")
  local s = fixture()
  assert(checkpoint.write(path, s))
  for _, failure in ipairs({"short", "read", "stat", "close"}) do
    local open, stat_fd = fd.open, fs.stat_fd
    local handle: fd.Handle | nil
    fd.open = function(p: string, flags: integer, mode?: integer,
        dirfd?: integer): fd.Handle | nil, string
      local h, err = open(p, flags, mode, dirfd)
      if h then
        handle = h
        local read, close = h.read, h.close
        h.read = function(self: fd.Handle, size?: integer,
            offset?: integer): string | nil, string
          if failure == "read" then return nil, "injected read failure" end
          return read(self, math.min(size or 3, 3), offset)
        end
        h.close = function(self: fd.Handle): boolean, string
          local ok, close_err = close(self)
          if failure == "close" then return false, "injected close failure" end
          return ok, close_err
        end
      end
      return h, err
    end
    if failure == "stat" then
      fs.stat_fd = function(_rawfd: integer): fs.Stat | nil, string
        return nil, "injected stat failure"
      end
    end
    local result = checkpoint.read(path, s.seed, s.iters)
    fd.open, fs.stat_fd = open, stat_fd
    assert(handle)
    check.truthy(handle:closed(), "descriptor leaked after " .. failure)
    if failure == "short" then check.equal(snapshot(result).input, s.input)
    else
      invalid(result)
      check.truthy(result.error:find("injected " .. failure .. " failure", 1, true), result.error)
    end
  end
  assert(fs.remove_all(dir))
end

local function test_pack_unpack_and_write_exceptions_are_values()
  local pack = string.pack
  string.pack = function(_format: string, ...: any): string
    local _args = {...}
    error("injected pack exception")
  end
  local result = checkpoint.encode(fixture())
  string.pack = pack
  check.equal(result.valid, false)
  check.equal(result.bytes, nil)
  check.truthy(result.error:find("injected pack exception", 1, true), result.error)
  local bytes = encoded(fixture())
  local unpack = string.unpack
  string.unpack = function(_format: string, _bytes: string, _position?: integer): any
    error("injected unpack exception")
  end
  local decoded = checkpoint.decode(bytes, -19, 7)
  string.unpack = unpack
  invalid(decoded)
  check.truthy(decoded.error:find("injected unpack exception", 1, true), decoded.error)
  local write = fs.write
  fs.write = function(_path: string, _bytes: string, _opts?: fs.WriteOptions): boolean, string
    error("injected write exception")
  end
  local ok, err = checkpoint.write("unused", fixture())
  fs.write = write
  check.equal(ok, false)
  check.truthy(err:find("injected write exception", 1, true), err)
end
