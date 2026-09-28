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
--- instead by its image (`image`): what the kernel maps and runs.
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
---   `Store.meta("host_image")` names, `artifact.trusted_core`'s bytes,
---   the launcher's COSMIC_PORTABLE_CORE_* and the extracted core's
---   cache name. Each is checked against the core itself, the same
---   whatever those bytes are, and no test's verdict turns on what they
---   hash to.
---
--- A core that carries no DWARF -- every release core, which build.zig
--- strips, and any file this does not read as a 64-bit ELF executable
--- -- is keyed by its bytes whole, as before: the image stands in only
--- where there is debug information to leave out, so the release
--- cores' keys are what they were.

local Hash = require("cosmic.hash")
local type raw_store = require("cosmic.internal.store")

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

--- Whether `bytes`, a 64-bit little-endian ELF file whose header is
--- read already, names a DWARF section (`.debug_*`, or zlib's older
--- `.zdebug_*`), reading no further than its section headers' bounds
--- and their names'; nil where those do not fit the file.
local function names_dwarf(bytes: string): boolean | nil
  local shoff = field(bytes, 41, 8)
  local shentsize, shnum, shstrndx = field(bytes, 59, 2), field(bytes, 61, 2), field(bytes, 63, 2)
  if shnum == 0 then return false end
  if shoff < 0 or shentsize ~= section_header_length or
     shoff > #bytes - shnum * section_header_length or shstrndx >= shnum then
    return nil
  end
  local names_at = shoff + shstrndx * section_header_length + 1
  local names, names_size = field(bytes, names_at + 24, 8), field(bytes, names_at + 32, 8)
  -- SHT_NOBITS (8) has no bytes in the file to name anything with.
  if field(bytes, names_at + 4, 4) == 8 or names < 0 or names_size < 0 or
     names > #bytes - names_size then
    return nil
  end
  local dwarf = false
  for index = 0, shnum - 1 do
    local name = field(bytes, shoff + index * section_header_length + 1, 4)
    if name >= names_size then return nil end
    local at = names + name + 1
    if bytes:sub(at, at + 6) == ".debug_" or bytes:sub(at, at + 7) == ".zdebug_" then
      dwarf = true
    end
  end
  return dwarf
end

--- What of the core `bytes` a run can turn on (see the module's
--- comment), where it is a 64-bit little-endian ELF file -- as every
--- Linux core is -- that carries DWARF: its image, its header less
--- where its section headers are, its program headers, and each
--- segment's file bytes, in their order, each after its length, under
--- a domain of its own; nil where it is keyed by its bytes whole, as
--- one that is not so, in any part, is.
function core_image.image(bytes: string): string | nil
  if #bytes < header_length or bytes:sub(1, 6) ~= elf_magic .. "\2\1" or
     not names_dwarf(bytes) then
    return nil
  end
  local phoff, phentsize, phnum = field(bytes, 33, 8), field(bytes, 55, 2), field(bytes, 57, 2)
  if phoff < 0 or phentsize ~= program_header_length or
     phoff > #bytes - phnum * program_header_length then
    return nil
  end
  -- e_shoff (at 40, 8 bytes) left out, then e_flags, e_ehsize,
  -- e_phentsize and e_phnum (48 to 57) kept, then e_shentsize, e_shnum
  -- and e_shstrndx left out -- here and where a segment holds the
  -- header, as a linker's first one does: mapped, those fields are
  -- read by nothing, and they move with the size of what they follow.
  local header = bytes:sub(1, 40) .. ("\0"):rep(8) .. bytes:sub(49, 58) .. ("\0"):rep(6)
  local parts: {string} = {
    "cosmic-core-image-v1\0", header,
    bytes:sub(phoff + 1, phoff + phnum * program_header_length),
  }
  for index = 0, phnum - 1 do
    local at = phoff + index * program_header_length
    local offset, size = field(bytes, at + 9, 8), field(bytes, at + 33, 8)
    if offset < 0 or size < 0 or offset > #bytes - size then return nil end
    parts[#parts + 1] = string.pack(">I8", size)
    if offset < header_length then
      parts[#parts + 1] = header:sub(offset + 1, math.min(header_length, offset + size))
      parts[#parts + 1] = bytes:sub(header_length + 1, offset + size)
    else
      parts[#parts + 1] = bytes:sub(offset + 1, offset + size)
    end
  end
  return table.concat(parts)
end

--- The runtime identity a verdict's key holds of the core `core` runs
--- under the runtime basis `basis`, given `raw`, the one the running
--- binary names (`Store.meta("runtime")`, core/store.c's
--- `push_portable_runtime`): `raw` itself where the core is keyed by
--- its bytes whole (`image`), as every release core is; else the same
--- encoding with its image's digest in place of the core's, under a
--- domain of its own.
function core_image.runtime(core: raw_store.Core, basis: string, raw: string): string
  local image = core_image.image(core.bytes)
  if image == nil then return raw end
  return Hash.hex_sha256("cosmic-runtime-image-v1\0" ..
    string.pack(">I4I4", core.target_id, core.configuration_id) .. Hash.sha256(image) ..
    string.pack(">I8", #basis) .. basis)
end

return core_image
