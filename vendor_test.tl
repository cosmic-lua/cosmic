--- `vendor.tl` against archives built here: a zip holding a stored and
--- a deflated entry, and a gzipped tar under a prefix, each checked for
--- what the tree holds afterward.
local Compress = require("cosmic.compress")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local vendor = require("vendor")

--- `deflate` writes a zlib stream; an archive carries it raw, without
--- the two-byte header and the four-byte checksum.
local function raw_deflate(data: string): string
  local packed = assert(Compress.deflate(data))
  return packed:sub(3, -5)
end

local function zip(entries: {{string}}): string
  local body: {string} = {}
  local directory: {string} = {}
  local at = 0
  for _, e in ipairs(entries) do
    local name, data, method = e[1], e[2], e[3]
    local stored = method == "deflate" and raw_deflate(data) or data
    local code = method == "deflate" and 8 or 0
    local header = string.pack("<I4I2I2I2I4I4I4I4I2I2", 0x04034b50, 20, 0,
      code, 0, 0, #stored, #data, #name, 0) .. name
    directory[#directory + 1] = string.pack(
      "<I4I2I2I2I2I4I4I4I4I2I2I2I2I2I4I4", 0x02014b50, 20, 20, 0, code, 0,
      0, #stored, #data, #name, 0, 0, 0, 0, 0, at) .. name
    body[#body + 1] = header .. stored
    at = at + #header + #stored
  end
  local central = table.concat(directory)
  return table.concat(body) .. central ..
    string.pack("<I4I2I2I2I2I4I4I2", 0x06054b50, 0, 0, #entries, #entries,
      #central, at, 0)
end

local function tar_gz(entries: {{string}}): string
  local out: {string} = {}
  for _, e in ipairs(entries) do
    local name, data = e[1], e[2]
    local header = name .. string.rep("\0", 124 - #name) ..
      string.format("%011o\0", #data) .. string.rep("\0", 20) .. "0" ..
      string.rep("\0", 100) .. "ustar\0"
    out[#out + 1] = header .. string.rep("\0", 512 - #header)
    out[#out + 1] = data .. string.rep("\0", (512 - #data % 512) % 512)
  end
  out[#out + 1] = string.rep("\0", 1024)
  local tar = table.concat(out)
  return "\31\139\8\0\0\0\0\0\0\3" .. raw_deflate(tar) ..
    string.pack("<I4I4", 0, #tar)
end

--- Writes `archive` and a PIN naming its hash and `rules`, runs
--- `vendor.tl` over the tree, and returns its exit status.
local function run(dir: string, archive: string, rules: string): integer
  local tree = dir .. "/tree"
  assert(Fs.mkdirs(tree .. "/old"))
  assert(Fs.write(tree .. "/old/gone.c", "stale"))
  assert(Fs.write(tree .. "/PIN",
    "version 1\nsha256 " .. Hash.hex_sha256(archive) .. "\n" .. rules))
  assert(Fs.write(dir .. "/archive", archive))
  return vendor({ [1] = "vendor.tl", [2] = tree, [3] = dir .. "/archive" })
end

local function test_a_zip_keeps_what_the_pin_names(dir: string)
  local archive = zip({
    { "a/x.c", "stored bytes", "store" },
    { "a/y.c", string.rep("deflated bytes ", 40), "deflate" },
    { "a/skip.c", "dropped", "store" },
    { "b/z.h", "not kept", "store" },
  })
  assert(run(dir, archive, "keep a/*.c\ndrop a/skip.c\n") == 0)
  local tree = dir .. "/tree"
  assert(Fs.read(tree .. "/a/x.c") == "stored bytes")
  assert(Fs.read(tree .. "/a/y.c") == string.rep("deflated bytes ", 40))
  assert(not Fs.exists(tree .. "/a/skip.c"))
  assert(not Fs.exists(tree .. "/b"))
  assert(not Fs.exists(tree .. "/old"), "the stale tree was not pruned")
  assert(Fs.exists(tree .. "/PIN"))
end

local function test_a_tar_gz_loses_its_prefix(dir: string)
  local archive = tar_gz({
    { "pkg-1/src/one.c", "one" },
    { "pkg-1/doc/manual.html", "prose" },
  })
  assert(run(dir, archive, "strip pkg-1/\nkeep src/*.c\n") == 0)
  assert(Fs.read(dir .. "/tree/src/one.c") == "one")
  assert(not Fs.exists(dir .. "/tree/doc"))
end

local function test_an_archive_the_pin_does_not_name_is_refused(dir: string)
  local archive = zip({ { "a.c", "a", "store" } })
  local tree = dir .. "/tree"
  assert(Fs.mkdirs(tree))
  assert(Fs.write(tree .. "/PIN", "sha256 " .. string.rep("0", 64) ..
    "\nkeep a.c\n"))
  assert(Fs.write(dir .. "/archive", archive))
  assert(vendor({ [1] = "vendor.tl", [2] = tree, [3] = dir .. "/archive" }) == 1)
  assert(not Fs.exists(tree .. "/a.c"))
end

local function test_a_keep_that_matches_nothing_fails(dir: string)
  local archive = zip({ { "a.c", "a", "store" } })
  assert(run(dir, archive, "keep b.c\n") == 1)
  assert(Fs.exists(dir .. "/tree/old/gone.c"), "a failed run pruned the tree")
end
