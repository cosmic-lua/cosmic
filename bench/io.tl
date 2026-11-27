--- Run-time microbenchmarks of files and archives: `bin/cosmic bench/io.tl [name...]`.
--- Whole-file reads and writes, a directory of 1000 files listed and walked, tar and zip written and read, and a
--- stream passed through a transform. Each case is one line on [`bench.harness`], which takes `--json`,
--- `--rounds` and `--against <old-binary>`. It measures; it gates nothing, and no test reads its numbers.
local Bench = require("bench.harness")
local Fs = require("cosmic.fs")
local Rand = require("cosmic.rand")
local Stream = require("cosmic.stream")
local Tar = require("cosmic.tar")
local Zip = require("cosmic.zip")

local bench = Bench.new("io")
local case = bench.case

local MIB <const> = 1024 * 1024
local bytes = Rand.new(2026):bytes(MIB)

--- Reads the whole of the entry's body, raising where it fails.
local function drain(r: Stream.Reader)
  local body, trouble = Stream.read_all(r)
  if body == nil then error(tostring(trouble)) end
end

-- The files live in a temporary directory made when a case that needs it is selected.
local root = ""
local file = ""
local function make_root()
  if root ~= "" then return end
  root = Fs.temp_dir() .. "/cosmic-bench-io-" .. tostring(math.random(1, 1 << 30))
  assert(Fs.mkdirs(root .. "/many"))
  file = root .. "/one"
  assert(Fs.write(file, bytes))
  for i = 1, 1000 do assert(Fs.write(root .. "/many/f" .. tostring(i), "x")) end
end

case("fs.read 1 MiB", function(n: integer)
  for _ = 1, n do local _ = Fs.read(file)! end
end, { bytes = MIB, setup = make_root })
case("fs.write 1 MiB", function(n: integer)
  for _ = 1, n do assert(Fs.write(root .. "/out", bytes)) end
end, { bytes = MIB, setup = make_root })
case("fs.list 1000 files", function(n: integer)
  for _ = 1, n do local _ = Fs.list(root .. "/many")! end
end, { setup = make_root })
case("fs.walk 1000 files", function(n: integer)
  for _ = 1, n do local _ = Fs.walk(root .. "/many")! end
end, { setup = make_root })
case("fs.stat 1000 files", function(n: integer)
  for _ = 1, n do
    for i = 1, 1000 do local _ = Fs.stat(root .. "/many/f" .. tostring(i))! end
  end
end, { setup = make_root })

-- Archives: 1000 small files, written to memory and read back.
local small: mut {string} = {}
for i = 1, 1000 do
  local body = string.rep(tostring(i), 20)
  small[#small + 1] = body
end

local function tar_bytes(): string
  local out = Stream.collect()
  local w = Tar.writer(out, { deterministic = true })
  for i, body in ipairs(small) do assert(w:add_file("dir/f" .. tostring(i), body)) end
  assert(w:close())
  return out:result()
end
local function zip_bytes(): string
  local out = Stream.collect()
  local w = Zip.writer(out)
  for i, body in ipairs(small) do assert(w:add_file("dir/f" .. tostring(i), body)) end
  assert(w:close())
  return out:result()
end

local tarred = ""
local zipped = ""
case("tar.writer 1000 files", function(n: integer)
  for _ = 1, n do local _ = tar_bytes() end
end)
case("tar.reader 1000 files", function(n: integer)
  for _ = 1, n do
    local r = Tar.reader(Stream.from_string(tarred))
    while true do
      local entry, trouble = r:next()
      assert(entry ~= nil, tostring(trouble))
      if entry == false then break end
      drain(entry:open()!)
    end
    assert(r:close())
  end
end, { setup = function() tarred = tar_bytes() end })
case("zip.writer 1000 files", function(n: integer)
  for _ = 1, n do local _ = zip_bytes() end
end)
case("zip.reader 1000 files", function(n: integer)
  for _ = 1, n do
    local r = Zip.open_string(zipped)!
    for _, entry in ipairs(r:entries()!) do
      drain(entry:open()!)
    end
    assert(r:close())
  end
end, { setup = function() zipped = zip_bytes() end })

-- A stream: 1 MiB read in 4 KiB chunks and in one call.
case("stream.from_string chunks 1 MiB", function(n: integer)
  for _ = 1, n do
    local r = Stream.from_string(bytes, 4096)
    while true do
      local chunk, why = r:read(4096)
      if chunk == nil then error(tostring(why)) end
      if chunk == false then break end
    end
  end
end, { bytes = MIB })

return function(argv: {string}): integer return bench.main(argv) end
