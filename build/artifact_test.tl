--- [`build.artifact`]'s byte layout: a prefix the same on every write,
--- holding each core once where its manifest says, a program's trailer,
--- a split at the database, and the head a key reads. The C reader of
--- the same format (core/portable.c) is tested by
--- test/portable/format_test.c.

local Compress = require("cosmic.compress")
local Hash = require("cosmic.hash")
local Stream = require("cosmic.stream")
local artifact = require("build.artifact")
local fixture = require("build.core_image_fixture")
local String = require("cosmic.string")

local records = table.concat({
  "1\t1\trelease\tx86\tLinux\tx86_64",
  "2\t1\trelease\tarm\tLinux\taarch64",
  "3\t1\trelease\tmac\tDarwin\tarm64",
}, "\n") .. "\n"

local cores: {string:string} = {
  x86 = "ELF-x86\0CosmicM1-in-core",
  arm = "ELF-arm-contents",
  mac = "MACHO-signed-core-contents",
}

--- The core the fixtures name.
local function core_named(name: string): string
  return assert(cores[name])
end

local function occurrences(haystack: string, needle: string): integer
  local count = 0
  local at = 1
  while true do
    local found = haystack:find(needle, at, true)
    if found == nil then return count end
    count = count + 1
    at = found + #needle
  end
end

local function test_prefix_is_deterministic_and_holds_each_exact_core_once()
  local one = assert(artifact.prefix(records, cores))
  local two = assert(artifact.prefix(records, cores))
  assert(one == two)
  assert(#one % 4096 == 0)
  assert(one:sub(1, 10) == "#!/bin/sh\n")
  for name, image in pairs(cores) do
    assert(occurrences(one, image) == 1, name .. " core is not present once")
    assert(one:find(Hash.hex_sha256(image), 1, true) ~= nil,
      name .. " digest is absent from the generated shell arm")
  end
end

--- The entries of a prefix's manifest, in order.
local record Entry
  target: integer
  configuration: integer
  kind: integer
  codec: integer
  offset: integer
  stored_length: integer
  stored_digest: string
  length: integer
  digest: string
end

local function manifest_of(prefix: string): {Entry}
  local manifest_at = #prefix - 4096 + 1
  assert(prefix:sub(manifest_at, manifest_at + 7) == "CosmicM1")
  local version, encoded, prefix_length, count, entry_size, at =
    string.unpack(">I4I4I8I4I4", prefix, manifest_at + 8)
  assert(version == 2 and encoded == 4096 and prefix_length == #prefix)
  assert(entry_size == 104)
  local entries: mut {Entry} = {}
  for _ = 1, count do
    local target, configuration, kind, codec, offset, stored_length, length:
      integer, integer, integer, integer, integer, integer, integer
    target, configuration, kind, codec, offset, stored_length, at =
      string.unpack(">I4I4I4I4I8I8", prefix, at)
    local stored_digest = prefix:sub(at, at + 31)
    length, at = string.unpack(">I8", prefix, at + 32)
    local digest = prefix:sub(at, at + 31)
    at = at + 32
    entries[#entries + 1] = { target = target, configuration = configuration, kind = kind,
      codec = codec, offset = offset, stored_length = stored_length,
      stored_digest = stored_digest, length = length, digest = digest }
  end
  assert(prefix:sub(at, at + 31) == string.rep("\0", 32), "unused manifest bytes are zero")
  return entries
end

local function test_manifest_ranges_name_the_exact_core_bytes()
  local prefix = assert(artifact.prefix(records, cores))
  local entries = manifest_of(prefix)
  assert(#entries == 3)
  local names = { "x86", "arm", "mac" }
  for i, entry in ipairs(entries) do
    local image = core_named(assert(names[i]))
    assert(entry.target == i and entry.configuration == 1)
    assert(entry.kind == 1 and entry.codec == 0, "a raw core is the core kind, raw")
    assert(entry.length == #image and entry.stored_length == #image)
    assert(prefix:sub(entry.offset + 1, entry.offset + entry.length) == image)
    assert(entry.digest == Hash.sha256(image) and entry.stored_digest == entry.digest)
  end
end

--- A stand-in for the zstd stub and its frame: the writer is told what to
--- store and never decodes it.
local stubs: {string:string} = { x86 = "STUB-x86\0", arm = "STUB-arm", mac = "STUB-mac\1\2\3" }

local function packing(): artifact.Packing
  return {
    stubs = stubs,
    compress = function(core: string): string?, string
      return "FRAME(" .. core .. ")", ""
    end,
  }
end

local function test_a_packed_prefix_stores_frames_and_their_stubs()
  local prefix = assert(artifact.prefix(records, cores, nil, packing()))
  assert(assert(artifact.prefix(records, cores, nil, packing())) == prefix)
  local entries = manifest_of(prefix)
  assert(#entries == 6, "a stub beside each of three cores")
  local seen: mut {string:boolean} = {}
  local last_end = 16384
  for _, entry in ipairs(entries) do
    local name = assert(({ "x86", "arm", "mac" })[entry.target])
    local image = core_named(name)
    local stored = prefix:sub(entry.offset + 1, entry.offset + entry.stored_length)
    assert(entry.offset % 16384 == 0 and entry.offset >= last_end, "ranges ascend, aligned")
    last_end = entry.offset + entry.stored_length
    assert(entry.stored_digest == Hash.sha256(stored))
    if entry.kind == 1 then
      assert(entry.codec == 1 and stored == "FRAME(" .. image .. ")")
      assert(entry.length == #image and entry.digest == Hash.sha256(image),
        "the core's identity is the raw core's")
      assert(occurrences(prefix, image) == 1)
    else
      assert(entry.kind == 2 and entry.codec == 0)
      assert(stored == assert(stubs[name]))
      assert(entry.length == entry.stored_length and entry.digest == entry.stored_digest)
    end
    seen[name .. ":" .. tostring(entry.kind)] = true
  end
  for _, name in ipairs({ "x86", "arm", "mac" }) do
    assert(seen[name .. ":1"] == true and seen[name .. ":2"] == true, name)
  end
  -- The arm of a compressed core names the stub and the stored length; the
  -- launcher's cache entry stays named for the raw core.
  local x86 = core_named("x86")
  local x86_digest = Hash.hex_sha256(x86)
  local frame_length = #("FRAME(" .. x86 .. ")")
  assert(prefix:find("cosmic_stored=" .. tostring(frame_length) .. "; cosmic_length=" ..
      tostring(#x86) .. "; cosmic_sha256=" .. x86_digest .. "; cosmic_stub_block=1; " ..
      "cosmic_stub_length=9; cosmic_stub_sha256=" .. Hash.hex_sha256("STUB-x86\0") .. " ;;", 1, true),
    "the arm names the raw digest and its stub")
end

local function test_a_core_without_a_stub_stays_raw_beside_compressed_ones()
  local only: artifact.Packing = { stubs = { x86 = "STUB-x86" },
    compress = function(core: string): string?, string return "F" .. core, "" end }
  local entries = manifest_of((assert(artifact.prefix(records, cores, nil, only))))
  assert(#entries == 4)
  local codecs: mut {string:integer} = {}
  for _, entry in ipairs(entries) do
    if entry.kind == 1 then codecs[tostring(entry.target)] = entry.codec end
  end
  assert(codecs["1"] == 1 and codecs["2"] == 0 and codecs["3"] == 0)
end

local function test_a_packed_writer_refuses_what_it_cannot_store()
  local empty: artifact.Packing = { stubs = { x86 = "" }, compress = packing().compress }
  local none, trouble = artifact.prefix(records, cores, nil, empty)
  assert(none == nil and trouble:find("empty decoder stub", 1, true) ~= nil, trouble)
  local failing: artifact.Packing = { stubs = { x86 = "S" },
    compress = function(_core: string): string?, string return nil, "no frame today" end }
  local nothing, why = artifact.prefix(records, cores, nil, failing)
  assert(nothing == nil and why:find("no frame today", 1, true) ~= nil, why)
  -- Three compressed cores and three stubs are six of the eight an artifact may hold; a
  -- checked core makes seven, and nothing more fits two more pairs.
  local many = records .. "4\t1\trelease\tfour\tLinux\tother\n" .. "5\t1\trelease\tfive\tLinux\tmore\n"
  local images: mut {string:string} = { x86 = core_named("x86"), arm = core_named("arm"),
    mac = core_named("mac"), four = "ELF-four", five = "ELF-five" }
  local big: artifact.Packing = { stubs = { x86 = "a", arm = "b", mac = "c", four = "d", five = "e" },
    compress = packing().compress }
  local too_many, bound = artifact.prefix(many, images, nil, big)
  assert(too_many == nil and bound:find("outside the v2 bound", 1, true) ~= nil, bound)
  assert(artifact.prefix(many, images) ~= nil, "five raw cores fit")
end

--- A zstd frame the stub would take decodes to the core it names.
local function test_the_frames_a_release_writes_decode_to_their_cores()
  local core = ("a core, repeated; "):rep(5000) .. "ELF"
  local frame = assert(Compress.zstd(core, 19))
  local prefix = assert(artifact.prefix("1\t1\trelease\tx86\tLinux\tx86_64\n", { x86 = core }, nil,
    { stubs = { x86 = "STUB" }, compress = function(c: string): string?, string
      return Compress.zstd(c, 19)
    end }))
  local entries = manifest_of(prefix)
  local core_entry = assert(entries[2])
  local stored = prefix:sub(core_entry.offset + 1, core_entry.offset + core_entry.stored_length)
  assert(stored == frame and #stored < #core // 10)
  assert(assert(Stream.run(assert(Compress.zstd_decoder()), stored)) == core)
end

local function test_programs_share_the_prefix_and_have_distinct_suffixes()
  local prefix = assert(artifact.prefix(records, cores))
  local db_one = "SQLite format 3\0one database"
  local db_two = "SQLite format 3\0two database"
  local one = assert(artifact.program(prefix, db_one))
  local two = assert(artifact.program(prefix, db_two))
  assert(String.starts_with(one, prefix) and String.starts_with(two, prefix))
  assert(one:sub(#prefix + 1) ~= two:sub(#prefix + 1))
  assert(one:sub(-48, -41) == "CosmicT1")
  local version, length, manifest_offset, manifest_length,
    database_offset, database_length = string.unpack(">I4I4I8I8I8I8", one, #one - 39)
  assert(version == 2 and length == 48)
  assert(manifest_offset == #prefix - 4096 and manifest_length == 4096)
  assert(database_offset == #prefix and database_length == #db_one)
end

local function test_writer_rejects_ambiguous_or_incomplete_inputs()
  local missing, trouble = artifact.prefix(records, { x86 = cores.x86 })
  assert(missing == nil and trouble:find("no raw core", 1, true) ~= nil)
  local duplicate = records .. "1\t1\trelease\tother\tOther\tarch\n"
  local bad, duplicate_trouble = artifact.prefix(duplicate, {
    x86 = cores.x86, arm = cores.arm, mac = cores.mac, other = "core",
  })
  assert(bad == nil and duplicate_trouble:find("duplicate", 1, true) ~= nil)
  local program, database_trouble = artifact.program(
    assert(artifact.prefix(records, cores)), "not sqlite")
  assert(program == nil and database_trouble:find("SQLite", 1, true) ~= nil)
end

local function test_checked_manifest_keeps_release_entries_but_selects_checked()
  local checked_records = records ..
    "1\t2\tsanitized\tsanitized-x86\tLinux\tx86_64\n"
  local checked_cores: mut {string:string} = {
    x86 = cores.x86,
    arm = cores.arm,
    mac = cores.mac,
    ["sanitized-x86"] = "ELF-checked-x86-contents",
  }
  local prefix = assert(artifact.prefix(checked_records, checked_cores, 2))
  assert(prefix:find("cosmic_configuration_id=2", 1, true) ~= nil)
  assert(prefix:find("cosmic_configuration_id=1", 1, true) == nil)
  local manifest_at = #prefix - 4096 + 1
  local _, _, _, count = string.unpack(">I4I4I8I4", prefix,
    manifest_at + 8)
  assert(count == 4)
  for _, image in pairs(checked_cores) do
    assert(occurrences(prefix, image) == 1)
  end

  local absent, absent_trouble = artifact.prefix(records, cores, 2)
  assert(absent == nil and
      absent_trouble:find("has no generated", 1, true) ~= nil)
  local duplicate_system = checked_records ..
    "2\t2\tsanitized\tsanitized-arm\tLinux\tx86_64\n"
  checked_cores["sanitized-arm"] = "ELF-other-checked-contents"
  local ambiguous, ambiguous_trouble =
    artifact.prefix(duplicate_system, checked_cores, 2)
  assert(ambiguous == nil and
      ambiguous_trouble:find("duplicate generated uname", 1, true) ~= nil)
end

--- A host-only boot puts a script where it built no core, and a prefix with
--- one says so: it is the ordinary layout (every target has an entry, as the
--- core requires), found by what each placeholder begins with, which no
--- real core does.
local function test_a_placeholder_core_marks_a_host_only_prefix()
  local placeholder = artifact.placeholder("arm")
  assert(String.starts_with(placeholder, "#!/bin/sh\n"), "it runs as a script")
  assert(placeholder:find("arm", 1, true) ~= nil, "it names the target")
  assert(placeholder:find("-Dboot-cores=all", 1, true) ~= nil, "it names the boot that builds the core")
  assert(artifact.placeholder("arm") == placeholder and artifact.placeholder("mac") ~= placeholder,
    "it is a function of the target")
  local own, other = "ELF-x86\0a core of this host", "ELF-arm-another"
  local whole = assert(artifact.prefix(records, { x86 = own, arm = other, mac = other }))
  assert(not artifact.host_only(whole), "a prefix of every core is no host-only boot's")
  local only = assert(artifact.prefix(records, { x86 = own, arm = placeholder,
    mac = artifact.placeholder("mac") }))
  assert(artifact.host_only(only), "a prefix with placeholders is")
  local partly = assert(artifact.prefix(records, { x86 = own, arm = other,
    mac = artifact.placeholder("mac") }))
  assert(artifact.host_only(partly), "one placeholder is enough")
  local program = assert(artifact.program(only, "SQLite format 3\0db"))
  local parts = assert(artifact.split(program))
  assert(parts.head == only and not parts.host, "a program of it splits as any does")
end

--- A portable and a host program alike split at their database, and
--- rejoin to the same bytes, or around a new database to what the
--- writer would have written with it.
local function test_split_finds_the_database_either_writer_appended()
  local prefix = assert(artifact.prefix(records, cores))
  local one = "SQLite format 3\0one"
  local two = "SQLite format 3\0the second, longer"
  local portable = assert(artifact.program(prefix, one))
  local host = assert(artifact.host_program({ bytes = cores.x86, digest = Hash.sha256(cores.x86),
    target_id = 1, configuration_id = 1 }, one))
  for bytes, is_host in pairs({ [portable] = false, [host] = true }) do
    local parts = assert(artifact.split(bytes))
    assert(parts.database == one)
    assert(parts.host == is_host)
    assert(artifact.rejoin(parts, one) == bytes)
    local swapped = assert(artifact.rejoin(parts, two))
    local again = assert(artifact.split(swapped))
    assert(again.database == two and again.head == parts.head and again.host == is_host)
  end
  assert(artifact.rejoin(assert(artifact.split(portable)), two) == artifact.program(prefix, two))
end

--- A trailer whose fields do not fit the file is refused, never read
--- past.
local function test_split_refuses_a_trailer_that_does_not_fit()
  local prefix = assert(artifact.prefix(records, cores))
  local program = assert(artifact.program(prefix, "SQLite format 3\0db"))
  local refused: {string} = {
    "",
    program:sub(2),
    program .. "x",
    program:sub(1, -49) .. "CosmicX1" .. program:sub(-40),
    -- The database's length one longer than the file holds.
    program:sub(1, -9) .. string.pack(">I8", 19),
    -- One too long for any integer, which reads negative.
    program:sub(1, -9) .. string.pack(">I8", -1),
  }
  for i, bytes in ipairs(refused) do
    local parts, trouble = artifact.split(bytes)
    assert(parts == nil and trouble ~= "", "case " .. tostring(i))
  end
  local not_sqlite = assert(artifact.split(program))
  local joined, trouble = artifact.rejoin(not_sqlite, "not sqlite")
  assert(joined == nil and trouble:find("SQLite", 1, true) ~= nil, trouble)
end

--- A head is keyed whole where no core carries DWARF, as every release
--- artifact's is. Where one does, as the checked artifact's checked core
--- does, the head is keyed by the core's image. A rebuild whose DWARF
--- names another directory (of another length, which moves the cores
--- behind it, the manifest's offsets and the launcher's arm) keys the
--- same; a rebuild whose code or launcher moved does not.
local function test_a_head_is_keyed_by_its_cores_images()
  local database = "SQLite format 3\0db"
  local function head(checked: string, arm?: string): string
    local with: {string:string} = { x86 = checked, arm = cores.arm, mac = cores.mac }
    local prefix = assert(artifact.prefix(records, with))
    if arm ~= nil then prefix = prefix:gsub("x86_64'%)", arm .. "')", 1) end
    return assert(artifact.split((assert(artifact.program(prefix, database))))).head
  end
  local stripped = head(fixture.elf("code"))
  assert(artifact.keyed_head(stripped) == stripped, "a head with no DWARF was not keyed whole")
  local one = head(fixture.elf("code", "comp_dir /one"))
  local other = head(fixture.elf("code", "comp_dir /a/longer/two" .. ("x"):rep(20000)))
  assert(#one ~= #other and artifact.keyed_head(one) ~= one)
  assert(artifact.keyed_head(one) == artifact.keyed_head(other), "the DWARF moved the head")
  assert(artifact.keyed_head(head(fixture.elf("edoc", "comp_dir /one"))) ~=
      artifact.keyed_head(one), "the code left the head")
  assert(artifact.keyed_head(head(fixture.elf("code", "comp_dir /one"), "x86_65")) ~=
      artifact.keyed_head(one), "the launcher left the head")
  -- A core whose manifest digest is not its own is keyed whole.
  local wrong = one:gsub("comp_dir /one", "comp_dir /eno", 1)
  assert(artifact.keyed_head(wrong) == wrong)
  -- A host program's head likewise.
  local function host(core: string): string
    return assert(artifact.split((assert(artifact.host_program({ bytes = core, target_id = 1,
      configuration_id = 2, digest = Hash.sha256(core) }, database))))).head
  end
  assert(artifact.keyed_head(host(fixture.elf("code", "one"))) ==
      artifact.keyed_head(host(fixture.elf("code", "another one"))))
  assert(artifact.keyed_head(host(fixture.elf("code", "one"))) ~=
      artifact.keyed_head(host(fixture.elf("edoc", "one"))))
end

--- A compressed core is keyed as the raw core its digest names, not by its
--- frame, and a decoder stub by its digest: a head whose frames were
--- written by another encoder, or whose ranges moved, keys the same while
--- one whose stub or core differs does not. A frame that does not hash to the
--- manifest's stored digest is keyed whole.
local function test_a_head_with_compressed_cores_is_keyed_by_their_digests_and_stubs()
  local database = "SQLite format 3\0db"
  local function head(dwarf: string, frame: string, stub: string): string
    local pack: artifact.Packing = { stubs = { arm = stub, mac = "STUB-mac" },
      compress = function(core: string): string?, string
        return frame .. core, ""
      end }
    local prefix = assert(artifact.prefix(records,
      { x86 = fixture.elf("code", dwarf), arm = core_named("arm"), mac = core_named("mac") }, nil, pack))
    return assert(artifact.split((assert(artifact.program(prefix, database))))).head
  end
  local base = head("comp_dir /one", "frame-a:", "STUB-arm")
  local keyed = artifact.keyed_head(base)
  assert(keyed ~= base, "the DWARF core keys the head by its image")
  assert(keyed:find("cosmic_stub_length=", 1, true) == nil and keyed:find("cosmic_stored=", 1, true) == nil,
    "no arm field that says where a range lies is left in the key")
  assert(artifact.keyed_head(head("comp_dir /a/longer/two" .. ("x"):rep(20000), "another frame, longer:",
    "STUB-arm")) == keyed, "the frames and ranges left the key")
  assert(artifact.keyed_head(head("comp_dir /one", "frame-a:", "STUB-ARM")) ~= keyed,
    "a changed stub left the key")
  -- A frame that is not the bytes its stored digest names.
  local at = assert(base:find("frame-a:" .. core_named("arm"), 1, true))
  local damaged = base:sub(1, at) .. "X" .. base:sub(at + 2)
  assert(artifact.keyed_head(damaged) == damaged, "a damaged range was keyed by its digest")
end

--- A raw entry stores what it is, so its stored and decoded pairs agree. One
--- whose `digest` differs from its stored digest would be keyed by a digest
--- nothing checks: the head is keyed whole instead.
local function test_a_raw_entry_whose_digest_disagrees_keys_the_head_whole()
  local images: {string:string} = { x86 = fixture.elf("code", "comp_dir /one"), arm = core_named("arm"),
    mac = core_named("mac") }
  local prefix = assert(artifact.prefix(records, images))
  local base = assert(artifact.split((assert(artifact.program(prefix, "SQLite format 3\0db"))))).head
  assert(artifact.keyed_head(base) ~= base, "the DWARF core keys the head by its image")
  local digest = Hash.sha256(core_named("arm"))
  local manifest_at = #base - 4096 + 1
  local at = assert(base:find(digest, manifest_at, true))
  assert(base:find(digest, at + 1, true) ~= nil, "the entry names the digest twice")
  local second = assert(base:find(digest, at + 1, true))
  local damaged = base:sub(1, second - 1) .. string.char((assert(digest:byte(1)) + 1) % 256) .. base:sub(second + 1)
  assert(artifact.keyed_head(damaged) == damaged, "a raw entry was keyed by a digest it does not have")
end

--- Version 1 is what a release before this one wrote. A reader names both
--- versions rather than calling the file damaged.
local function test_a_version_1_artifact_is_refused_naming_both_versions()
  local prefix = assert(artifact.prefix(records, cores))
  local program = assert(artifact.program(prefix, "SQLite format 3\0db"))
  local old_trailer = program:sub(1, -41) .. string.pack(">I4", 1) .. program:sub(-36)
  local parts, trouble = artifact.split(old_trailer)
  assert(parts == nil and trouble == "artifact format version 1; this release reads version 2", trouble)
  local manifest_at = #prefix - 4096 + 1
  local old_prefix = prefix:sub(1, manifest_at + 7) .. string.pack(">I4", 1) .. prefix:sub(manifest_at + 12)
  local joined, why = artifact.program(old_prefix, "SQLite format 3\0db")
  assert(joined == nil and why == "artifact format version 1; this release reads version 2", why)
  -- A version no release wrote is named as well.
  local future = program:sub(1, -41) .. string.pack(">I4", 9) .. program:sub(-36)
  local none, future_trouble = artifact.split(future)
  assert(none == nil and future_trouble == "artifact format version 9; this release reads version 2",
    future_trouble)
end

--- The release's frames are a function of the core: compressing it again, in
--- the same process after other work, gives the same bytes, which is what lets
--- the platform legs agree on the artifact. The frame names its size and a
--- checksum and keeps to the stub's window.
local function test_a_release_frame_is_the_same_every_time_and_names_its_size()
  local state = 12345
  local pieces: mut {string} = {}
  for i = 1, 6000 do
    state = (state * 1103515245 + 12345) & 0x7fffffff
    pieces[#pieces + 1] = string.format("%08x:%d;", state, i % 17)
  end
  local core = table.concat(pieces):rep(8)
  local level = artifact.zstd_level()
  local one = assert(Compress.zstd(core, level))
  assert(Compress.zstd("other work between the two", level) ~= nil)
  local two = assert(Compress.zstd(core, level))
  assert(one == two, "the same core compressed to two frames")
  assert(one:sub(1, 4) == "\40\181\47\253", "a zstd frame")
  -- The frame header descriptor: bit 2 a content checksum, bits 6-7 the size of
  -- a content size field, which the single-segment and size flags make present.
  local descriptor = assert(one:byte(5))
  assert(descriptor & 0x04 ~= 0, "the frame carries a checksum")
  assert(descriptor & 0xc0 ~= 0 or descriptor & 0x20 ~= 0, "the frame names its content size")
  assert(assert(Stream.run(assert(Compress.zstd_decoder(1 << 23)), one)) == core)
end
