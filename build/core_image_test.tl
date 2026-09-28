local Hash = require("cosmic.hash")
local core_image = require("build.core_image")
local fixture = require("build.core_image_fixture")

--- What a key holds of the core `bytes`: its image's digest, or its own.
local function digest(bytes: string): string
  return Hash.sha256(core_image.image(bytes) or bytes)
end

--- A core rebuilt with its DWARF naming another directory -- another
--- length of it, as a comp_dir of another checkout is -- keys the same;
--- one whose code moved does not.
local function test_a_core_carrying_dwarf_is_keyed_by_its_image()
  local one = fixture.elf("code", "DW_AT_comp_dir /home/runner/work/one")
  local other = fixture.elf("code", "DW_AT_comp_dir /__w/a/much/longer/path/two")
  assert(one ~= other)
  assert(core_image.image(one) ~= nil, "a core carrying DWARF has no image")
  assert(digest(one) == digest(other), "its DWARF moved the core")
  assert(digest(one) ~= Hash.sha256(one))
  assert(digest(fixture.elf("edoc", "DW_AT_comp_dir /home/runner/work/one")) ~=
    digest(one), "its code left the core")
end

--- Every release core is stripped: it is keyed by its bytes whole, as
--- its manifest names it, so its keys are what they were before.
local function test_a_core_without_dwarf_is_keyed_whole()
  local stripped = fixture.elf("code")
  assert(core_image.image(stripped) == nil)
  assert(digest(stripped) == Hash.sha256(stripped))
  -- Nor a Mach-O core, nor anything else.
  assert(digest("\207\250\237\254 a macOS core") == Hash.sha256("\207\250\237\254 a macOS core"))
end

--- A file that says it is an ELF executable, but whose headers do not
--- fit it, is keyed whole: nothing is left out of what cannot be read.
local function test_an_elf_whose_headers_do_not_fit_is_keyed_whole()
  local core = fixture.elf("code", "dwarf")
  for _, cut in ipairs({ 63, 64, 100, #core - 1 }) do
    local short = core:sub(1, cut)
    assert(digest(short) == Hash.sha256(short), "cut at " .. cut)
  end
  -- A segment past the end of the file.
  local wide = core:sub(1, 64 + 32) .. string.pack("<i8", #core + 1) .. core:sub(64 + 41)
  assert(core_image.image(wide) == nil)
  -- A big-endian one, which no core is.
  local big = core:sub(1, 5) .. "\2" .. core:sub(7)
  assert(core_image.image(big) == nil)
end

--- The runtime identity: the binary's own where the core is keyed
--- whole, else one of its image that its DWARF does not move.
local function test_the_runtime_identity_holds_the_image()
  local basis = "basis"
  local function runtime(bytes: string): string
    return core_image.runtime({ bytes = bytes, target_id = 1, configuration_id = 2,
      digest = Hash.sha256(bytes) }, basis, "raw " .. Hash.hex_sha256(bytes))
  end
  local stripped = fixture.elf("code")
  assert(runtime(stripped) == "raw " .. Hash.hex_sha256(stripped))
  local one = runtime(fixture.elf("code", "one"))
  assert(one == runtime(fixture.elf("code", "another")), "its DWARF moved the runtime")
  assert(one ~= runtime(fixture.elf("edoc", "one")), "its code left the runtime")
  basis = "another basis"
  assert(one ~= runtime(fixture.elf("code", "one")), "the basis left the runtime")
end
