--- Fuzz properties for `core_image.digest` and `artifact.keyed_head`: a
--- key reads every program a test runs, and every artifact's head, so
--- one whose headers or manifest lie must be keyed whole -- never a
--- raise, nor a read past the file. Each input edits a small core's
--- header, program header and section header fields, or an artifact's
--- manifest fields, cuts it or adds junk. And a core's image holds its
--- code whatever its DWARF: a core drawn with other debug bytes keys the
--- same, one with other code does not.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Hash = require("cosmic.hash")
local artifact = require("build.artifact")
local core_image = require("build.core_image")
local fixture = require("build.core_image_fixture")

--- Overwrites the little-endian `width`-byte field at `at` in `s`.
local function set_field(s: string, at: integer, width: integer, value: integer,
                         order: string): string
  local packed = order == "<" and string.pack("<i8", value):sub(1, width) or
    string.pack(">i8", value):sub(9 - width)
  return s:sub(1, at - 1) .. packed .. s:sub(at + width)
end

--- Draws edits of `fields` ({offset, width}, each from the end where
--- `from_end`) in `order`, cuts and junk onto one of `bases`.
local function gen(bases: {string}, fields: function(string): {{integer}},
                   order: string): function(Fuzz.Source): string
  return function(src: Fuzz.Source): string
    local bytes = Fuzz.pick(src, bases)
    local edits = 0
    while Fuzz.more(src, edits, 4) do
      edits = edits + 1
      local what = src:int(1, 4)
      if what == 1 then
        local f = Fuzz.pick(src, fields(bytes))
        bytes = set_field(bytes, f[1], f[2], Fuzz.pick(src, { 0, 1, 2, 64, 120, #bytes - 1,
          #bytes, #bytes + 1, -1, math.maxinteger, 65535 }), order)
      elseif what == 2 then
        bytes = Fuzz.mutate(src, bytes, 3)
      elseif what == 3 then
        bytes = bytes:sub(1, src:int(0, #bytes))
      else
        bytes = bytes .. Fuzz.bytes(src, 64)
      end
    end
    return bytes
  end
end

--- An ELF file's header, first program header and section header
--- fields, as {1-based offset, width}.
local function elf_fields(bytes: string): {{integer}}
  local fields: {{integer}} = { { 33, 8 }, { 41, 8 }, { 55, 2 }, { 57, 2 }, { 59, 2 },
    { 61, 2 }, { 63, 2 }, { 73, 8 }, { 97, 8 } }
  local shoff = #bytes >= 48 and (string.unpack("<i8", bytes, 41)) or 0
  for index = 0, 3 do
    local at = shoff + index * 64 + 1
    for _, f in ipairs({ { 0, 4 }, { 4, 4 }, { 24, 8 }, { 32, 8 } }) do
      if at + f[1] + f[2] - 1 <= #bytes and at > 0 then
        fields[#fields + 1] = { at + f[1], f[2] }
      end
    end
  end
  return fields
end

local function test_image_is_total(tmp: string)
  Fuzz.run({
    name = "core image",
    dir = tmp,
    gen = gen({ fixture.elf("code", "dwarf"), fixture.elf("code"),
      fixture.elf(("c"):rep(300), ("d"):rep(100)) }, elf_fields, "<"),
    check = function(input: string): boolean, string
      local image = core_image.digest(input)
      if image == nil then
        Fuzz.label("whole")
        return true, ""
      end
      Fuzz.label("image")
      if #image ~= 32 then return false, "an image's digest is not 32 bytes" end
      return true, ""
    end,
    requires = { "image", "whole" },
  })
end

--- Two cores that differ only in their DWARF -- its bytes and its
--- length, which moves the section headers behind it -- key the same;
--- two that differ in their code do not.
local function test_an_image_holds_the_code_and_not_the_dwarf(tmp: string)
  Fuzz.run({
    name = "core image dwarf",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local code = "c" .. Fuzz.bytes(src, 64)
      local other_code = src:int(0, 1) == 0 and code or Fuzz.mutate(src, code, 3)
      return Fuzz.pack({ code, other_code, "d" .. Fuzz.bytes(src, 64), "d" .. Fuzz.bytes(src, 64) })
    end,
    check = function(input: string): boolean, string
      local f = Fuzz.unpack(input)
      if #f ~= 4 or f[1] == "" or f[2] == "" then return true, "" end
      local one = core_image.digest(fixture.elf(f[1], f[3]))
      if one == nil then return false, "a well-formed core carrying DWARF has no image" end
      if core_image.digest(fixture.elf(f[1], f[4])) ~= one then
        return false, "its DWARF moved the image"
      end
      if f[3] ~= f[4] then Fuzz.label("dwarf moved") end
      local other = core_image.digest(fixture.elf(f[2], f[3]))
      if f[2] ~= f[1] then
        Fuzz.label("code moved")
        if other == one then return false, "its code left the image" end
      elseif other ~= one then
        return false, "the same core keyed apart"
      end
      return true, ""
    end,
    requires = { "dwarf moved", "code moved" },
  })
end

--- A head's manifest fields, from its end: the prefix length, count and
--- entry size, and the first entries' offsets and lengths.
local function manifest_fields(bytes: string): {{integer}}
  local at = #bytes - 4096 + 1
  local fields: {{integer}} = { { at + 16, 8 }, { at + 24, 4 }, { at + 28, 4 } }
  for entry = 0, 1 do
    fields[#fields + 1] = { at + 32 + entry * 56 + 8, 8 }
    fields[#fields + 1] = { at + 32 + entry * 56 + 16, 8 }
  end
  for i = #fields, 1, -1 do
    if fields[i][1] < 1 then table.remove(fields, i) end
  end
  if #fields == 0 then fields[1] = { 1, 1 } end
  return fields
end

local function test_keyed_head_is_total(tmp: string)
  local records = "1\t1\trelease\tx86\tLinux\tx86_64\n2\t1\trelease\tarm\tLinux\taarch64\n"
  local function head(prefix: string): string
    return assert(artifact.split((assert(artifact.program(prefix, "SQLite format 3\0db"))))).head
  end
  local core = fixture.elf("code", "dwarf")
  local bases = {
    head((assert(artifact.prefix(records, { x86 = core, arm = "arm core" })))),
    assert(artifact.split((assert(artifact.host_program({ bytes = core, target_id = 1,
      configuration_id = 2, digest = Hash.sha256(core) }, "SQLite format 3\0db"))))).head,
  }
  Fuzz.run({
    name = "keyed head",
    dir = tmp,
    gen = gen(bases, manifest_fields, ">"),
    check = function(input: string): boolean, string
      local keyed = artifact.keyed_head(input)
      if keyed == input then
        Fuzz.label("whole")
        return true, ""
      end
      Fuzz.label("imaged")
      if keyed:sub(1, 21) ~= "cosmic-head-image-v1\0" then
        return false, "a head keyed by its images has no domain"
      end
      return true, ""
    end,
    requires = { "imaged", "whole" },
  })
end
