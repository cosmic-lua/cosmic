--- What of a core a run can turn on, as a digest a verdict's key holds
--- (build.test's `runtime`, build.declared_key's `launcher` and
--- `program`), so that a core rebuilt with other debug information keys
--- the same.
---
--- The checked core keeps its DWARF, for its sanitizer's reports. Its
--- own C and every vendored library's compile with
--- `-fdebug-compilation-dir=.` (build.zig's `debug_dir`), but musl's,
--- which zig builds itself in its global cache with none of our flags,
--- names the tree root of whichever checkout first built libc there: a
--- CI run that restores another run's zig cache links a core whose
--- `.debug_*` bytes differ, whose raw digest -- and so every checked
--- verdict's key -- moved with it. A core that carries DWARF is keyed
--- instead by its image (`digest`): what the kernel maps and runs.
---
--- Why nothing a test can turn on is left out:
---
--- - The kernel reads an ELF executable's header, its program headers
---   and the file bytes each program header names (its segments: the
---   loaded ones, and any it reads by offset, such as PT_INTERP or a
---   note), and nothing else. The image holds all of those, and the
---   header's fields but the four that say where the section headers
---   are, which nothing that runs reads.
--- - What that leaves out -- the section headers and every section no
---   segment holds: `.debug_*`, `.symtab`, `.strtab`, `.shstrtab`,
---   `.comment` -- is never mapped. The core reads it only where its
---   sanitizer runtime symbolizes a report it prints, which says the
---   same failure whatever directory a unit's DWARF names; a verdict is
---   whether the test passed, not the text of the report that failed
---   it.
--- - A core's raw bytes still reach a test, as data: the digest
---   `Store.meta("host_image")` names, [`artifact.trusted_core`]'s bytes,
---   the launcher's COSMIC_PORTABLE_CORE_* and the extracted core's
---   cache name. Each is checked against the core itself, the same
---   whatever those bytes are, and no test's verdict turns on what they
---   hash to.
---
--- A core that carries no DWARF -- every release core, which build.zig
--- strips -- is keyed by its bytes whole: the image stands in only where
--- there is debug information to leave out. So is any file this does not
--- read as a 64-bit little-endian ELF executable or shared object with
--- a segment to load, and one with bytes past everything its headers
--- name (`layout`): no loader runs a relocatable object, whose image
--- would be its header alone, and bytes no header names are read, if at
--- all, by what the image cannot answer for.

local hashing = require("build.digest")

-- Hashed through build.digest, not cosmic.hash: a verdict key that
-- holds a core's image (build.declared_key) turns on no library module
-- outside the harness (build.test's `harness`).
local sha256_hasher, hex_sha256 = hashing.sha256_hasher, hashing.hex_sha256

local record core_image
end

local elf_magic <const> = "\127ELF"
local header_length <const> = 64
local program_header_length <const> = 56
local section_header_length <const> = 64

--- The unsigned little-endian field of `width` bytes (2, 4 or 8) at
--- `at` in `bytes`, which holds it; negative for an 8-byte one past
--- math.maxinteger.
local function field(bytes: string, at: integer, width: integer): integer
  if width == 2 then return (string.unpack("<I2", bytes, at)) end
  if width == 4 then return (string.unpack("<I4", bytes, at)) end
  return (string.unpack("<i8", bytes, at))
end

--- Where, in `bytes`, each segment of the 64-bit little-endian ELF
--- executable it is lies, as {offset, size} pairs, with its program
--- headers' offset and count -- where it is one whose image is all a
--- run can turn on: an executable or a shared object (e_type EXEC or
--- DYN) with a segment to load, carrying DWARF (a `.debug_*` section,
--- or zlib's older `.zdebug_*`), whose every byte past its header lies
--- in its program headers, a segment, a section or its section
--- headers, each within the file, so that nothing a loader might read
--- hides in bytes a key leaves out. nil where it is not so, in any part.
local record Layout
  phoff: integer
  phnum: integer
  segments: {{integer}}
end

local function layout(bytes: string): Layout | nil
  if #bytes < header_length or bytes:sub(1, 6) ~= elf_magic .. "\2\1" then return nil end
  local kind = field(bytes, 17, 2)
  if kind ~= 2 and kind ~= 3 then return nil end
  local phoff, phentsize, phnum = field(bytes, 33, 8), field(bytes, 55, 2), field(bytes, 57, 2)
  local shoff = field(bytes, 41, 8)
  local shentsize, shnum, shstrndx = field(bytes, 59, 2), field(bytes, 61, 2), field(bytes, 63, 2)
  if phoff < header_length or phentsize ~= program_header_length or phnum == 0 or
      phoff > #bytes - phnum * program_header_length or
      shnum == 0 or shoff < header_length or shentsize ~= section_header_length or
      shoff > #bytes - shnum * section_header_length or shstrndx >= shnum then
    return nil
  end
  local reach = math.max(phoff + phnum * program_header_length,
    shoff + shnum * section_header_length)
  local segments: {{integer}} = {}
  local loads = false
  for index = 0, phnum - 1 do
    local at = phoff + index * program_header_length
    local offset, size = field(bytes, at + 9, 8), field(bytes, at + 33, 8)
    if offset < 0 or size < 0 or offset > #bytes - size then return nil end
    if field(bytes, at + 1, 4) == 1 then loads = true end
    segments[#segments + 1] = { offset, size }
    reach = math.max(reach, offset + size)
  end
  if not loads then return nil end
  local names_at = shoff + shstrndx * section_header_length + 1
  local names, names_size = field(bytes, names_at + 24, 8), field(bytes, names_at + 32, 8)
  -- SHT_NOBITS (8) has no bytes in the file to name anything with.
  if field(bytes, names_at + 4, 4) == 8 or names < 0 or names_size < 0 or
      names > #bytes - names_size then
    return nil
  end
  local dwarf = false
  for index = 0, shnum - 1 do
    local at = shoff + index * section_header_length + 1
    local name = field(bytes, at, 4)
    if name >= names_size then return nil end
    local offset, size = field(bytes, at + 24, 8), field(bytes, at + 32, 8)
    if field(bytes, at + 4, 4) ~= 8 then
      if offset < 0 or size < 0 or offset > #bytes - size then return nil end
      reach = math.max(reach, offset + size)
    end
    local named = names + name + 1
    if bytes:sub(named, named + 6) == ".debug_" or bytes:sub(named, named + 7) == ".zdebug_" then
      dwarf = true
    end
  end
  if not dwarf or reach ~= #bytes then return nil end
  return { phoff = phoff, phnum = phnum, segments = segments }
end

--- The SHA-256 digest, as 32 raw bytes, of what of the core `bytes` a
--- run can turn on (see the module's comment), where it is a 64-bit
--- little-endian ELF executable -- as every Linux core is -- that
--- carries DWARF (`layout`): of its image, its header less where its
--- section headers are, its program headers, and each segment's file
--- bytes, in their order, each after its length, under a domain of its
--- own, fed to the hasher piece by piece; nil where it is keyed by its
--- bytes whole.
function core_image.digest(bytes: string): string | nil
  local found = layout(bytes)
  if found == nil then return nil end
  local hasher, _ = sha256_hasher()
  if hasher == nil then return nil end
  -- e_shoff (at 40, 8 bytes) left out, then e_flags, e_ehsize,
  -- e_phentsize and e_phnum (48 to 57) kept, then e_shentsize, e_shnum
  -- and e_shstrndx left out -- here and where a segment holds the
  -- header, as a linker's first one does: mapped, those fields are
  -- read by nothing, and they move with the size of what they follow.
  local header = bytes:sub(1, 40) .. ("\0"):rep(8) .. bytes:sub(49, 58) .. ("\0"):rep(6)
  hasher:update("cosmic-core-image-v1\0")
  hasher:update(header)
  hasher:update(bytes:sub(found.phoff + 1, found.phoff + found.phnum * program_header_length))
  for _, segment in ipairs(found.segments) do
    local offset, size = segment[1], segment[2]
    hasher:update(string.pack(">I8", size))
    if offset < header_length then
      hasher:update(header:sub(offset + 1, math.min(header_length, offset + size)))
      hasher:update(bytes:sub(header_length + 1, offset + size))
    else
      hasher:update(bytes:sub(offset + 1, offset + size))
    end
  end
  local digest, _ = hasher:digest()
  return digest
end

--- The runtime identity a verdict's key holds of a core keyed by its
--- image (`digest`), whose digest, in hex, is `image`, that its
--- artifact's manifest names by `target_id` and `configuration_id`,
--- under the runtime basis `basis`: the encoding core/store.c's
--- `push_portable_runtime` makes of a core's bytes, of its image
--- instead, under a domain of its own.
function core_image.runtime(image: string, target_id: integer, configuration_id: integer,
                            basis: string): string
  return hex_sha256("cosmic-runtime-image-v1\0" ..
      string.pack(">I4I4", target_id, configuration_id) .. image ..
      string.pack(">I8", #basis) .. basis)
end

return core_image
