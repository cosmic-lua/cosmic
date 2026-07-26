--- Examples for cosmic.tar: unpacking a gzipped tarball.

-- Example_extract unpacks a .tar.gz into a directory. The archive here
-- is built by compressing a tar stream, which is what a release
-- tarball is; extraction refuses any entry whose name would escape the
-- destination, so an archive from elsewhere cannot write outside it.
local function Example_extract()
  local check = require("cosmic.check")
  local compress = require("cosmic.compress")
  local fs = require("cosmic.fs")
  local tar = require("cosmic.tar")

  local dir = check.must(fs.mkdtemp("/tmp/tar_example_XXXXXX"))

  -- One ustar header block (name, mode, size, checksum) plus its
  -- payload, padded to the 512-byte block size, then two zero blocks.
  local function block(name: string, body: string): string
    local hdr = name .. string.rep("\0", 100 - #name)
    .. "0000644\0" .. "0000000\0" .. "0000000\0"
    .. string.format("%011o", #body) .. "\0"
    .. "00000000000\0" .. "        " .. "0" .. string.rep("\0", 100)
    .. "ustar\0" .. "00" .. string.rep("\0", 247)
    local sum = 0
    for i = 1, #hdr do
      sum = sum + hdr:byte(i)
    end
    hdr = hdr:sub(1, 148) .. string.format("%06o", sum) .. "\0 " .. hdr:sub(157)
    local pad = (512 - #body % 512) % 512
    return hdr .. body .. string.rep("\0", pad)
  end

  local archive = fs.join(dir, "release.tar.gz")
  local tarball = block("notes.txt", "hello from a tarball\n")
  .. string.rep("\0", 1024)
  assert(fs.write(archive, compress.compress(tarball, {format = "gzip"})))

  assert(tar.extract(archive, fs.join(dir, "out")))
  print(check.must(fs.read(fs.join(dir, "out/notes.txt"))))
  fs.rmrf(dir)
  -- Output:
  -- hello from a tarball
end

return {Example_extract = Example_extract}
