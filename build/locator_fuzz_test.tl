--- Fuzz properties for the executable locator (core/portable.c): a host
--- program finds its manifest and database from its own trailer, before
--- any Lua runs, so a corrupt one must be refused by name -- never a
--- crash, a hang, or a run on ranges that were not checked. Each input
--- rewrites the manifest block, the trailer, and where the database ends,
--- and runs the program in a process of its own.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Fuzz = require("build.fuzz")
local embed = require("build.embed")
local sys = require("cosmic.sys")

local TRAILER <const> = 48
local MANIFEST <const> = 4096

--- The layout of a host program's tail, read from its own trailer.
local record Tail
  prefix: string
  manifest: string
  database: string
  trailer: string
end

--- The big-endian `width`-byte field at `at` in `s`, as a Lua integer;
--- bytes past the end of `s`, which an earlier edit may have cut, are 0.
local function field(s: string, at: integer, width: integer): integer
  local v = 0
  for i = at, at + width - 1 do v = (v << 8) | (s:byte(i) or 0) end
  return v
end

local function split(bytes: string): Tail
  local trailer = bytes:sub(-TRAILER)
  local manifest_offset = field(trailer, 17, 8)
  local database_offset, database_length = field(trailer, 33, 8), field(trailer, 41, 8)
  return {
    prefix = bytes:sub(1, manifest_offset),
    manifest = bytes:sub(manifest_offset + 1, manifest_offset + MANIFEST),
    database = bytes:sub(database_offset + 1, database_offset + database_length),
    trailer = trailer,
  }
end

--- Values a field of the trailer or manifest is most likely mishandled at.
local function interesting(src: Fuzz.Source, near: integer): integer
  return Fuzz.pick(src, { 0, 1, near - 1, near, near + 1, near + 4096, near * 2,
    0x7fffffffffffffff, -1, math.mininteger, 0xffffffff, 0x100000000 })
end

--- Overwrites the big-endian `width`-byte field at `at` in `s`.
local function set_field(s: string, at: integer, width: integer, value: integer): string
  local packed = string.pack(">i8", value):sub(9 - width)
  return s:sub(1, at - 1) .. packed .. s:sub(at + width)
end

--- Fields worth aiming at, as {offset in its block, width}: the
--- trailer's version, length and four ranges, and the manifest header's
--- and first two entries' fields.
local TRAILER_FIELDS <const> = { { 9, 4 }, { 13, 4 }, { 17, 8 }, { 25, 8 }, { 33, 8 }, { 41, 8 } }
local MANIFEST_FIELDS <const> = { { 9, 4 }, { 13, 4 }, { 17, 8 }, { 25, 4 }, { 29, 4 },
  { 33, 4 }, { 37, 4 }, { 41, 8 }, { 49, 8 }, { 89, 4 }, { 93, 4 }, { 97, 8 }, { 105, 8 } }

local function gen(tail: Tail): function(Fuzz.Source): string
  return function(src: Fuzz.Source): string
    local manifest, trailer = tail.manifest, tail.trailer
    local cut, junk = 0, ""
    local edits = 0
    repeat
      edits = edits + 1
      local what = src:int(1, 5)
      if what == 1 then
        local f = Fuzz.pick(src, TRAILER_FIELDS)
        local current = field(trailer, f[1], f[2])
        trailer = set_field(trailer, f[1], f[2], interesting(src, current))
      elseif what == 2 then
        local f = Fuzz.pick(src, MANIFEST_FIELDS)
        local current = field(manifest, f[1], f[2])
        manifest = set_field(manifest, f[1], f[2], interesting(src, current))
      elseif what == 3 then
        trailer = Fuzz.mutate(src, trailer, 3)
      elseif what == 4 then
        manifest = Fuzz.mutate(src, manifest:sub(1, 160), 3) .. manifest:sub(161)
      else
        cut = Fuzz.pick(src, { 1, 16, 4096, #tail.database })
        junk = Fuzz.bytes(src, 64)
      end
    until not Fuzz.more(src, edits, 4)
    return Fuzz.pack({ manifest, trailer, tostring(cut), junk })
  end
end

local function test_a_corrupt_host_program_is_refused_by_name(tmp: string)
  local tree = tmp .. "/tree"
  assert(Fs.mkdirs(tree .. "/cmd/ok"))
  assert(Fs.write(tree .. "/cmd/ok/main.tl", 'return function(): integer print("ok") return 0 end\n'))
  assert(embed.tree(tree, true))
  local tail = split((assert(Fs.read(tree .. "/o/bin/ok"))))
  local program = tmp .. "/program"
  -- The core is written once; each input rewrites only what follows it
  -- and cuts the file to its own length, since an input can be shorter.
  assert(Fs.write(program, tail.prefix, 0x1ed))
  local function rewrite(rest: string)
    local fd = assert(sys.open(program, sys.O_WRONLY))
    local called, failure = pcall(function(): boolean
      assert(sys.lseek(fd, #tail.prefix, sys.SEEK_SET))
      assert(Fs.put(fd, rest))
      return (assert(sys.ftruncate(fd, #tail.prefix + #rest)))
    end)
    assert(Fs.close(fd))
    if not called then error(failure) end
  end
  Fuzz.run({
    name = "host program locator",
    dir = tmp,
    gen = gen(tail),
    check = function(input: string): boolean, string
      local f = Fuzz.unpack(input)
      local cut = math.tointeger(tonumber(f[3])) or 0
      local database = tail.database:sub(1, #tail.database - cut) .. f[4]
      rewrite(f[1] .. database .. f[2])
      local r, trouble = Child.run({ program }, { stdout = "capture", stderr = "capture",
        timeout_ms = 10000 })
      if r == nil then return false, "run: " .. trouble end
      if r.timed_out then return false, "hung past 10 s" end
      if r.ok and r.stdout == "ok\n" then return true, "" end
      local said = tostring(r.stderr)
      if r.code == 2 and said:sub(1, 8) == "cosmic: " then return true, "" end
      return false, ("exit %s, signal %s: %s"):format(tostring(r.code), tostring(r.signal), said)
    end,
  })
end
