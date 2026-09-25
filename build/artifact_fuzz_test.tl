--- Fuzz property for `artifact.split`: `cosmic refresh` reads the
--- trailer of whatever file `--binary` names, so a corrupt one must be
--- refused by name -- never a raise, nor a head and database that are
--- not the file's own bytes. Each input edits a small program's
--- trailer and manifest fields, cuts it or adds junk.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Hash = require("cosmic.hash")
local artifact = require("build.artifact")

local records = "1\t1\trelease\tx86\tLinux\tx86_64\n"
local core = "ELF-x86-core"

--- Overwrites the big-endian `width`-byte field at `at` in `s`.
local function set_field(s: string, at: integer, width: integer, value: integer): string
  local packed = string.pack(">i8", value):sub(9 - width)
  return s:sub(1, at - 1) .. packed .. s:sub(at + width)
end

local function big(s: string, at: integer, width: integer): integer
  local v = 0
  for i = at, at + width - 1 do v = (v << 8) | (s:byte(i) or 0) end
  return v
end

--- The trailer's fields, as {offset in the trailer, width}.
local TRAILER_FIELDS <const> = { { 9, 4 }, { 13, 4 }, { 17, 8 }, { 25, 8 }, { 33, 8 }, { 41, 8 } }

local function gen(programs: {string}): function(Fuzz.Source): string
  return function(src: Fuzz.Source): string
    local bytes = Fuzz.pick(src, programs)
    local edits = 0
    while Fuzz.more(src, edits, 4) do
      edits = edits + 1
      local what = src:int(1, 4)
      if what == 1 then
        local f = Fuzz.pick(src, TRAILER_FIELDS)
        local at = #bytes - 48 + f[1]
        local near = big(bytes, at, f[2])
        bytes = set_field(bytes, at, f[2], Fuzz.pick(src, { 0, 1, near - 1, near + 1,
          near + 4096, -1, math.mininteger, #bytes }))
      elseif what == 2 then
        bytes = bytes:sub(1, -49) .. Fuzz.mutate(src, bytes:sub(-48), 3)
      elseif what == 3 then
        bytes = bytes:sub(1, src:int(0, #bytes))
      else
        bytes = bytes .. Fuzz.bytes(src, 64)
      end
    end
    return bytes
  end
end

local function test_split_is_total(tmp: string)
  local prefix = assert(artifact.prefix(records, { x86 = core }))
  local database = "SQLite format 3\0" .. ("d"):rep(40)
  local programs = {
    assert(artifact.program(prefix, database)),
    assert(artifact.host_program({ bytes = core, digest = Hash.sha256(core), target_id = 1,
      configuration_id = 1 }, database)),
  }
  Fuzz.run({
    name = "artifact split",
    dir = tmp,
    gen = gen(programs),
    check = function(input: string): boolean, string
      local parts, trouble = artifact.split(input)
      if parts == nil then
        Fuzz.label("refused")
        if trouble == "" then return false, "refused without a reason" end
        return true, ""
      end
      Fuzz.label("split")
      if input:sub(1, #parts.head) ~= parts.head or
         input:sub(#parts.head + 1, #parts.head + #parts.database) ~= parts.database or
         #parts.head + #parts.database + 48 ~= #input then
        return false, "the parts are not the file's own bytes"
      end
      if artifact.rejoin(parts, parts.database) ~= input then
        return false, "rejoining the same database changed the file"
      end
      return true, ""
    end,
    requires = { "split", "refused" },
  })
end
