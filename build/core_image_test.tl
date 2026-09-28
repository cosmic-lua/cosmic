local Hash = require("cosmic.hash")
local core_image = require("build.core_image")
local fixture = require("build.core_image_fixture")

--- What a key holds of the core `bytes`: its image's digest, or its own.
local function digest(bytes: string): string
  return core_image.digest(bytes) or Hash.sha256(bytes)
end

--- Overwrites the little-endian `width`-byte field at `at` (1-based).
local function set(bytes: string, at: integer, width: integer, value: integer): string
  return bytes:sub(1, at - 1) .. string.pack("<i8", value):sub(1, width) .. bytes:sub(at + width)
end

--- A core rebuilt with its DWARF naming another directory -- another
--- length of it, as a comp_dir of another checkout is -- keys the same;
--- one whose code moved does not.
local function test_a_core_carrying_dwarf_is_keyed_by_its_image()
  local one = fixture.elf("code", "DW_AT_comp_dir /home/runner/work/one")
  local other = fixture.elf("code", "DW_AT_comp_dir /__w/a/much/longer/path/two")
  assert(one ~= other)
  assert(core_image.digest(one) ~= nil, "a core carrying DWARF has no image")
  assert(#core_image.digest(one) == 32)
  assert(digest(one) == digest(other), "its DWARF moved the core")
  assert(digest(one) ~= Hash.sha256(one))
  assert(digest(fixture.elf("edoc", "DW_AT_comp_dir /home/runner/work/one")) ~=
    digest(one), "its code left the core")
end

--- Every release core is stripped: it is keyed by its bytes whole, as
--- its manifest names it, so its keys are what they were before.
local function test_a_core_without_dwarf_is_keyed_whole()
  assert(core_image.digest(fixture.elf("code")) == nil)
  -- Nor a Mach-O core, nor anything else.
  assert(core_image.digest("\207\250\237\254 a macOS core") == nil)
end

--- A file that says it is an ELF executable, but whose headers do not
--- fit it, is keyed whole: nothing is left out of what cannot be read.
local function test_an_elf_whose_headers_do_not_fit_is_keyed_whole()
  local core = fixture.elf("code", "dwarf")
  for _, cut in ipairs({ 63, 64, 100, #core - 1 }) do
    assert(core_image.digest(core:sub(1, cut)) == nil, "cut at " .. cut)
  end
  -- A segment past the end of the file.
  assert(core_image.digest(set(core, 97, 8, #core + 1)) == nil)
  -- A big-endian one, which no core is.
  assert(core_image.digest(core:sub(1, 5) .. "\2" .. core:sub(7)) == nil)
end

--- Only an executable's image is all a run of it can turn on: a file
--- whose image would not hold everything a loader or its reader might
--- read is keyed whole -- else two files that differ there would share
--- a key.
local function test_what_an_image_would_leave_out_keys_it_whole()
  local core = fixture.elf("code", "dwarf")
  -- Bytes past everything its headers name.
  assert(core_image.digest(core .. "PAYLOAD") == nil, "appended bytes were left out")
  -- A relocatable object (ET_REL), and one of no type: no loader runs them.
  assert(core_image.digest(set(core, 17, 2, 1)) == nil)
  assert(core_image.digest(set(core, 17, 2, 0)) == nil)
  -- No program headers, whose image would be its header alone.
  assert(core_image.digest(set(core, 57, 2, 0)) == nil)
  -- Program headers, but none that loads anything.
  assert(core_image.digest(set(core, 65, 4, 4)) == nil)
  -- A shared object (ET_DYN, a PIE) is keyed by its image as an executable is.
  assert(core_image.digest(set(core, 17, 2, 3)) ~= nil)
end

--- The runtime identity of an image moves with the image, the target
--- and configuration its manifest names it by, and the runtime basis.
local function test_the_runtime_identity_holds_the_image()
  local one = assert(core_image.digest(fixture.elf("code", "one")))
  local other = assert(core_image.digest(fixture.elf("code", "another")))
  local runtime = core_image.runtime(one, 1, 2, "basis")
  assert(runtime == core_image.runtime(other, 1, 2, "basis"), "its DWARF moved the runtime")
  local code = assert(core_image.digest(fixture.elf("edoc", "one")))
  assert(runtime ~= core_image.runtime(code, 1, 2, "basis"), "its code left the runtime")
  assert(runtime ~= core_image.runtime(one, 2, 2, "basis"), "the target left the runtime")
  assert(runtime ~= core_image.runtime(one, 1, 1, "basis"), "the configuration left the runtime")
  assert(runtime ~= core_image.runtime(one, 1, 2, "another basis"), "the basis left the runtime")
end
