--- The one writer for the versioned portable artifact layout.
---
--- `prefix` consumes build.zig's generated target records and the exact raw
--- cores, and, where it is given a [`artifact.Packing`], stores the cores it
--- has a decoder stub for compressed, each stub beside its core. It generates
--- both the shell case arms and binary manifest from that one sequence.
--- `program` appends one SQLite database and the fixed trailer.
--- [`host_program`] lays out the other format: the running core alone, at the
--- start of the file, then its manifest, database and trailer, so the kernel
--- executes it directly with no launcher.
--- None of them writes a path; callers publish the returned bytes through
--- the repository's existing atomic file writer.

local core_image = require("build.core_image")
local hashing = require("build.digest")
local key_parts = require("build.key_parts")
local launcher_template = require("build.launcher")
local type raw_store = require("cosmic.internal.store")
local String = require("cosmic.string")

-- Hashed and spelled through build.digest and build.key_parts, not
-- cosmic.hash or cosmic.codec: a verdict key that holds a program's
-- identity (build.declared_key) turns on no library module outside the
-- harness (build.test's `harness`).
local sha256, hex = hashing.sha256, key_parts.hex

local extra: any = select(2, ...)
local trusted_store: raw_store? = nil
if type(extra) == "table" then
  trusted_store = extra as raw_store
end

local record artifact
  --- How a writer stores the release cores: compressed, each with the
  --- decoder stub that restores it ([`artifact.prefix`]).
  record Packing
    --- A decoder stub's bytes by target name. A target that has one is
    --- stored as a zstd frame of its core ([`compress`]) beside the stub;
    --- one that has none is stored raw.
    stubs: {string:string}
    --- The zstd frame of a core, which the stub decodes: it names the
    --- core's size and checksum and a window within the stub's
    --- ([`cosmic.compress.zstd`]). The caller passes it so that this
    --- module, which a verdict's key turns on, needs no library module.
    compress: function(string): string?, string
  end

  --- An artifact cut at its database (`split`).
  record Split
    --- Every byte ahead of the database: the launcher and cores, or
    --- the host core, and the manifest behind them.
    head: string
    --- The SQLite database the artifact carries.
    database: string
    --- Whether it is a host program ([`host_program`]) rather than a
    --- portable one (`program`).
    host: boolean
  end
end

--- Reads the validated reusable prefix from the retained portable descriptor.
--- This capability is injected only when this module is loaded from Cosmic's
--- own trusted Store; the public cosmic.store wrapper does not carry it.
function artifact.trusted_prefix(): string?, string
  if trusted_store == nil then
    return nil, "no retained portable artifact capability"
  end
  return trusted_store.trusted_prefix()
end

--- The running core's exact bytes and the identity its manifest names,
--- checked against that digest, from the same trusted capability.
function artifact.trusted_core(): raw_store.Core?, string
  if trusted_store == nil then
    return nil, "no retained portable artifact capability"
  end
  return trusted_store.trusted_core()
end

-- What every placeholder core begins with, which [`artifact.host_only`]
-- looks for: the shebang and a comment no core of C holds.
local placeholder_head = "#!/bin/sh\n# cosmic-host-only-placeholder-v1\n"

--- The bytes a host-only boot puts in the artifact where the core of
--- `target` goes, which it did not build: a script that says so and exits 1,
--- so that the tool, copied to a host of that target, tells what it is
--- instead of failing in some other way. It is an entry of the manifest
--- like any, so the artifact is the portable layout the core accepts (which
--- holds a core for every required target); [`artifact.host_only`] tells the
--- tool it makes from one that is no portable program for that target.
function artifact.placeholder(target: string): string
  return placeholder_head ..
    "echo 'cosmic: this tool was booted for the host it was built on alone, so it carries " ..
    "no core for " .. target .. "; run bin/zig build boot -Dboot-cores=all in its checkout' >&2\n" ..
    "exit 1\n"
end

--- Whether `prefix`, an artifact's bytes ahead of its database
--- ([`artifact.trusted_prefix`]), holds a placeholder
--- ([`artifact.placeholder`]) for some target's core: the tool it is of was
--- booted for the host's core alone.
function artifact.host_only(prefix: string): boolean
  return prefix:find(placeholder_head, 1, true) ~= nil
end

--- The zstd level a release stores its cores at: the highest the encoder
--- takes, since a core is compressed once and read for the whole life of the
--- artifact. Its window is the stub's ([`cosmic.compress.zstd`]).
function artifact.zstd_level(): integer
  return 19
end

local version = 2
local shell_length = 16384
local core_alignment = 16384
local manifest_length = 4096
local manifest_header_length = 32
local entry_length = 104
local trailer_length = 48
-- Three compressed cores, their three stubs and a raw checked core are
-- seven entries; the eighth is headroom. core/portable.h holds the same bound.
local max_entries = 8
local manifest_magic = "CosmicM1"
local trailer_magic = "CosmicT1"
local host_trailer_magic = "CosmicH1"
local sqlite_header = "SQLite format 3\0"

-- An entry's kind: a core, or the stub that decodes a compressed core of
-- its target and configuration. Its codec: how its bytes are stored.
local kind_core = 1
local kind_stub = 2
local codec_raw = 0
local codec_zstd = 1

--- What a reader of this version says of a file written for another.
local function version_refusal(found: integer): string
  return "artifact format version " .. tostring(found) ..
    "; this release reads version " .. tostring(version)
end

--- One range of the file an entry names: the bytes stored, and the core
--- they decode to (the same bytes for a raw entry).
local record Piece
  target_id: integer
  configuration_id: integer
  kind: integer
  mut codec: integer
  mut offset: integer
  mut stored: string
  mut stored_digest: string
  length: integer
  digest: string
end

local record Target
  target_id: integer
  configuration_id: integer
  configuration: string
  target: string
  uname_os: string
  uname_arch: string
  core: Piece
  stub: Piece?
end

local function positive_u32(text: string): integer?
  local value = math.tointeger(tonumber(text))
  if value == nil or value <= 0 or value > 0xffffffff then
    return nil
  end
  return value
end

local function align(value: integer, boundary: integer): integer
  return ((value + boundary - 1) // boundary) * boundary
end

local function parse(records: string, cores: {string:string},
                     packing?: artifact.Packing): {Target}?, string
  local targets: mut {Target} = {}
  local identities: mut {string:boolean} = {}
  local pieces = 0
  for line in records:gmatch("[^\n]+") do
    local id_text, configuration_id_text, configuration, target, uname_os, uname_arch =
      line:match("^(%d+)\t(%d+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
    if id_text == nil or configuration_id_text == nil or
        configuration == nil or target == nil or uname_os == nil or uname_arch == nil then
      return nil, "invalid generated target record"
    end
    local target_id = positive_u32(id_text)
    local configuration_id = positive_u32(configuration_id_text)
    if target_id == nil or configuration_id == nil then
      return nil, "generated target id is outside the u32 range"
    end
    local identity = tostring(target_id) .. ":" .. tostring(configuration_id)
    if identities[identity] then
      return nil, "duplicate generated target/configuration record"
    end
    local image = cores[target]
    if image == nil or #image == 0 then
      return nil, "no raw core for " .. target
    end
    identities[identity] = true
    local digest = sha256(image)
    local core: Piece = {
      target_id = target_id,
      configuration_id = configuration_id,
      kind = kind_core,
      codec = codec_raw,
      offset = 0,
      stored = image,
      stored_digest = digest,
      length = #image,
      digest = digest,
    }
    local stub: Piece? = nil
    local stub_bytes: string? = nil
    if packing ~= nil then stub_bytes = packing.stubs[target] end
    if packing ~= nil and stub_bytes ~= nil then
      if #stub_bytes == 0 then
        return nil, "empty decoder stub for " .. target
      end
      local frame, trouble = packing.compress(image)
      if frame == nil or #frame == 0 then
        return nil, "cannot compress the core for " .. target .. ": " .. trouble
      end
      core.codec = codec_zstd
      core.stored = frame
      core.stored_digest = sha256(frame)
      stub = {
        target_id = target_id,
        configuration_id = configuration_id,
        kind = kind_stub,
        codec = codec_raw,
        offset = 0,
        stored = stub_bytes,
        stored_digest = sha256(stub_bytes),
        length = #stub_bytes,
        digest = sha256(stub_bytes),
      }
      pieces = pieces + 1
    end
    pieces = pieces + 1
    targets[#targets + 1] = {
      target_id = target_id,
      configuration_id = configuration_id,
      configuration = configuration,
      target = target,
      uname_os = uname_os,
      uname_arch = uname_arch,
      core = core,
      stub = stub,
    }
  end
  if #targets == 0 or pieces > max_entries then
    return nil, "generated target count is outside the v2 bound"
  end
  return targets, ""
end

--- Gives every range its offset, a stub ahead of its core and each on
--- the core alignment, and returns the manifest's offset.
local function place(targets: {Target}): integer
  local at = shell_length
  for _, target in ipairs(targets) do
    local stub = target.stub
    if stub ~= nil then
      stub.offset = at
      at = align(at + #stub.stored, core_alignment)
    end
    target.core.offset = at
    at = align(at + #target.core.stored, core_alignment)
  end
  return at
end

--- The fields of a launcher arm that name where a core lies and what it is,
--- as one run of text ending in a space. Both the arm the launcher is
--- written with and the arm [`keyed_head`] looks for are made by this, so
--- they cannot differ. A raw core's stub fields are empty, and are set all
--- the same: a variable the arm leaves unset could be read from the
--- environment.
local function arm_fields(offset: integer, stored_length: integer, length: integer,
                          digest: string, stub_offset?: integer,
                          stub_length?: integer, stub_digest?: string): string
  return string.format("cosmic_offset=%d; cosmic_block=%d; cosmic_stored=%d; " ..
      "cosmic_length=%d; cosmic_sha256=%s; cosmic_stub_block=%s; " ..
      "cosmic_stub_length=%s; cosmic_stub_sha256=%s ",
    offset, offset // core_alignment, stored_length, length, hex(digest),
    if stub_offset ~= nil then tostring(stub_offset // core_alignment) else "" end,
    if stub_length ~= nil then tostring(stub_length) else "" end,
    if stub_digest ~= nil then hex(stub_digest) else "" end)
end

local function launcher(targets: {Target}, test_hooks: boolean,
                        selected_configuration?: integer): string?, string
  local arms: mut {string} = {}
  local systems: mut {string:boolean} = {}
  for _, target in ipairs(targets) do
    if selected_configuration == nil or
        target.configuration_id == selected_configuration then
      local system = target.uname_os .. ":" .. target.uname_arch
      if systems[system] then
        return nil, "duplicate generated uname record for launcher configuration"
      end
      systems[system] = true
      local core, stub = target.core, target.stub
      arms[#arms + 1] = string.format(
        "  '%s %s') cosmic_os=%s; cosmic_target_id=%d; " ..
          "cosmic_configuration_id=%d; %s;;",
        target.uname_os, target.uname_arch, target.uname_os, target.target_id,
        target.configuration_id,
        if stub ~= nil then
          arm_fields(core.offset, #core.stored, core.length, core.digest,
            stub.offset, #stub.stored, stub.stored_digest)
          else
          arm_fields(core.offset, #core.stored, core.length, core.digest)
          end)
    end
  end
  if #arms == 0 then
    return nil, "launcher configuration has no generated target record"
  end
  local script = launcher_template.render(table.concat(arms, "\n"), test_hooks)
  if #script + 2 > shell_length then
    return nil, "generated shell header exceeds its fixed capacity"
  end
  return script .. "#" .. string.rep(" ", shell_length - #script - 2) .. "\n", ""
end

local function entry_bytes(piece: Piece): string
  return string.pack(">I4I4I4I4I8I8", piece.target_id, piece.configuration_id,
    piece.kind, piece.codec, piece.offset, #piece.stored) ..
    piece.stored_digest .. string.pack(">I8", piece.length) .. piece.digest
end

local function compose(records: string, cores: {string:string},
                       selected_configuration?: integer, packing?: artifact.Packing,
                       test_hooks?: boolean): string?, string
  local targets, trouble = parse(records, cores, packing)
  if targets == nil then
    return nil, trouble
  end
  local manifest_offset = place(targets)
  local prefix_length = manifest_offset + manifest_length
  local shell, shell_trouble = launcher(targets, test_hooks == true, selected_configuration)
  if shell == nil then
    return nil, shell_trouble
  end

  local pieces: mut {Piece} = {}
  for _, target in ipairs(targets) do
    if target.stub ~= nil then pieces[#pieces + 1] = target.stub end
    pieces[#pieces + 1] = target.core
  end
  local parts: mut {string} = { shell }
  local at = shell_length
  for _, piece in ipairs(pieces) do
    if at < piece.offset then
      parts[#parts + 1] = string.rep("\0", piece.offset - at)
    end
    parts[#parts + 1] = piece.stored
    at = piece.offset + #piece.stored
  end
  if at < manifest_offset then
    parts[#parts + 1] = string.rep("\0", manifest_offset - at)
  end

  local manifest: mut {string} = {
    manifest_magic,
    string.pack(">I4I4I8I4I4", version, manifest_length, prefix_length,
      #pieces, entry_length),
  }
  for _, piece in ipairs(pieces) do
    manifest[#manifest + 1] = entry_bytes(piece)
  end
  local manifest_bytes = table.concat(manifest)
  assert(#manifest_bytes == manifest_header_length + #pieces * entry_length)
  parts[#parts + 1] = manifest_bytes ..
    string.rep("\0", manifest_length - #manifest_bytes)
  local prefix = table.concat(parts)
  assert(#prefix == prefix_length)
  return prefix, ""
end

--- Builds reusable prefix bytes from build.zig's generated TSV and exact raw
--- core bytes, keyed by the target-name column. With `packing`, each target
--- it has a decoder stub for is stored as a zstd frame beside that stub, and
--- the rest raw; the launcher's arm for a compressed core names its stub.
function artifact.prefix(records: string, cores: {string:string},
                         selected_configuration?: integer,
                         packing?: artifact.Packing): string?, string
  return compose(records, cores, selected_configuration, packing, false)
end

--- Fixture-only constructor with deterministic FIFO synchronization points.
--- The ordinary `prefix` output contains no hook code or hook field names.
function artifact.test_prefix(records: string, cores: {string:string},
                              packing?: artifact.Packing): string?, string
  return compose(records, cores, nil, packing, true)
end

--- Appends a database and the v2 trailer to prefix bytes made by `prefix`.
function artifact.program(prefix: string, database: string): string?, string
  if #database < #sqlite_header or not String.starts_with(database, sqlite_header) then
    return nil, "portable program database has no SQLite header"
  end
  if #prefix < shell_length + manifest_length then
    return nil, "portable prefix is truncated"
  end
  local manifest_offset = #prefix - manifest_length
  local manifest_at = manifest_offset + 1
  if prefix:sub(manifest_at, manifest_at + 7) ~= manifest_magic then
    return nil, "portable prefix has no manifest"
  end
  local manifest_version, encoded_length, encoded_prefix =
    string.unpack(">I4I4I8", prefix, manifest_at + 8)
  if manifest_version ~= version then
    return nil, version_refusal(manifest_version)
  end
  if encoded_length ~= manifest_length or encoded_prefix ~= #prefix then
    return nil, "portable prefix manifest fields differ"
  end
  local trailer = trailer_magic .. string.pack(">I4I4I8I8I8I8",
    version, trailer_length, manifest_offset, manifest_length,
    #prefix, #database)
  assert(#trailer == trailer_length)
  return prefix .. database .. trailer, ""
end

--- A host program: `core` at offset 0, zero-filled to the core alignment,
--- a manifest naming it as the one entry (a raw core), then `database` and a
--- trailer whose magic says host. It runs only where that core does.
function artifact.host_program(core: raw_store.Core, database: string): string?, string
  if #database < #sqlite_header or not String.starts_with(database, sqlite_header) then
    return nil, "host program database has no SQLite header"
  end
  if #core.bytes == 0 or #core.digest ~= 32 then
    return nil, "host program core is empty or has no digest"
  end
  local manifest_offset = align(#core.bytes, core_alignment)
  local prefix_length = manifest_offset + manifest_length
  local manifest = manifest_magic .. string.pack(">I4I4I8I4I4", version, manifest_length,
    prefix_length, 1, entry_length) .. entry_bytes({
      target_id = core.target_id,
      configuration_id = core.configuration_id,
      kind = kind_core,
      codec = codec_raw,
      offset = 0,
      stored = core.bytes,
      stored_digest = core.digest,
      length = #core.bytes,
      digest = core.digest,
    })
  local trailer = host_trailer_magic .. string.pack(">I4I4I8I8I8I8",
    version, trailer_length, manifest_offset, manifest_length,
    prefix_length, #database)
  return table.concat({
    core.bytes,
    string.rep("\0", manifest_offset - #core.bytes),
    manifest, string.rep("\0", manifest_length - #manifest),
    database, trailer,
  }), ""
end

--- The database an artifact carries and everything ahead of it, read
--- from the trailer of `bytes` -- a portable program's or a host
--- program's alike -- so a new database can be put in its place
--- (`rejoin`). The trailer's fields are checked against each other and
--- against the file: the version and lengths this writer uses, a
--- manifest where it says, a database that starts right behind that
--- manifest, runs to the trailer and begins with SQLite's header. An
--- artifact of another version is refused by name, such as the version 1
--- a release before this one wrote.
function artifact.split(bytes: string): artifact.Split?, string
  if #bytes < trailer_length then
    return nil, "too short for an artifact trailer"
  end
  local at = #bytes - trailer_length + 1
  local magic = bytes:sub(at, at + 7)
  if magic ~= trailer_magic and magic ~= host_trailer_magic then
    return nil, "no artifact trailer"
  end
  local trailer_version, length, manifest_offset, manifest_size, database_offset, database_length =
    string.unpack(">I4I4I8I8I8I8", bytes, at + 8)
  if trailer_version ~= version then
    return nil, version_refusal(trailer_version)
  end
  if length ~= trailer_length then
    return nil, "not a v2 artifact trailer"
  end
  -- An unsigned 64-bit field past math.maxinteger reads as negative.
  if manifest_size ~= manifest_length or manifest_offset < 0 or
      database_offset ~= manifest_offset + manifest_length or
      database_length < #sqlite_header or
      database_length ~= #bytes - trailer_length - database_offset then
    return nil, "the artifact trailer's ranges do not fit the file"
  end
  local manifest_at = manifest_offset + 1
  if bytes:sub(manifest_at, manifest_at + 7) ~= manifest_magic then
    return nil, "the artifact has no manifest where its trailer says"
  end
  local _, _, encoded_prefix = string.unpack(">I4I4I8", bytes, manifest_at + 8)
  if encoded_prefix ~= database_offset then
    return nil, "the artifact's manifest and trailer disagree on where its database starts"
  end
  local database = bytes:sub(database_offset + 1, database_offset + database_length)
  if not String.starts_with(database, sqlite_header) then
    return nil, "the artifact's database has no SQLite header"
  end
  return {
    head = bytes:sub(1, database_offset),
    database = database,
    host = magic == host_trailer_magic,
  }, ""
end

--- Where a core and its stub lie in a head, for the launcher arm
--- [`keyed_head`] looks for.
local record Located
  codec: integer
  offset: integer
  stored_length: integer
  length: integer
  digest: string
  keyed: string
  identity: string
end

--- What of `head`, an artifact's bytes ahead of its database (`split`),
--- a verdict's key holds. It is `head` itself, unless a core its
--- manifest names carries debug information (build.core_image), which is
--- keyed by its image instead. Then it is `head` with each raw core with
--- debug information stood for by its image's digest ([`core_image.digest`]),
--- every other core by `b` and the digest of the core it decodes to (so a
--- compressed core is keyed as the raw one is, and not by its frame), and
--- each decoder stub by `s` and its digest.
---
--- The fields that say where the ranges lie and what their bytes hash to
--- are left out where they name exactly what is there: the manifest's
--- offsets, stored lengths, digests and prefix length, and a launcher
--- arm's `cosmic_offset`, `cosmic_block`, `cosmic_stored`, `cosmic_length`,
--- `cosmic_sha256` and `cosmic_stub_*` fields. Which bytes a launcher
--- extracts, and whether they are the ones its manifest names, is then the
--- image it runs, whatever its debug information weighs. The key does not
--- decode a frame: it takes the manifest's word that its core is the one the
--- digest names, which the launcher checks when it runs. The padding between
--- the ranges is held to zeros, and the comment that pads the launcher is left
--- out. A head that is not so, in any part, or whose stored range does not
--- hash to its stored digest, is keyed whole.
function artifact.keyed_head(head: string): string
  if #head < manifest_length then return head end
  local manifest_offset = #head - manifest_length
  local manifest_at = manifest_offset + 1
  if head:sub(manifest_at, manifest_at + 7) ~= manifest_magic then return head end
  local manifest_version, encoded_length, prefix_length, count, size, at =
    string.unpack(">I4I4I8I4I4", head, manifest_at + 8)
  if manifest_version ~= version or encoded_length ~= manifest_length or
      prefix_length ~= #head or count < 1 or count > max_entries or size ~= entry_length then
    return head
  end
  local shell_end = -1
  local was_end = 0
  local imaged = false
  local entries: mut {string} = {}
  local gaps: mut {string} = {}
  local ranges: mut {{string}} = {}
  local cores: mut {Located} = {}
  local stubs: mut {string:Located} = {}
  for _ = 1, count do
    local target, configuration, kind, codec, offset, stored_length, length:
      integer, integer, integer, integer, integer, integer, integer
    target, configuration, kind, codec, offset, stored_length, at =
      string.unpack(">I4I4I4I4I8I8", head, at)
    local stored_digest = head:sub(at, at + 31)
    length, at = string.unpack(">I8", head, at + 32)
    local digest = head:sub(at, at + 31)
    at = at + 32
    if (kind ~= kind_core and kind ~= kind_stub) or
        (codec ~= codec_raw and codec ~= codec_zstd) then
      return head
    end
    -- An unsigned 64-bit field past math.maxinteger reads as negative.
    if offset < was_end or stored_length <= 0 or length <= 0 or
        offset > manifest_offset - stored_length then
      return head
    end
    if shell_end < 0 then
      shell_end = offset
    else
      gaps[#gaps + 1] = head:sub(was_end + 1, offset)
    end
    local stored = head:sub(offset + 1, offset + stored_length)
    ranges[#ranges + 1] = { stored, stored_digest }
    local keyed: string
    if kind == kind_stub then
      keyed = "s" .. digest
    else
      local image = if codec == codec_raw then core_image.digest(stored) else nil end
      if image ~= nil then imaged = true end
      keyed = if image ~= nil then ("i" .. image) else ("b" .. digest) end
    end
    entries[#entries + 1] = string.pack(">I4I4I4", target, configuration, kind) .. keyed
    local located: Located = {
      codec = codec,
      offset = offset,
      stored_length = stored_length,
      length = length,
      digest = if kind == kind_stub then stored_digest else digest end,
      keyed = keyed,
      identity = tostring(target) .. ":" .. tostring(configuration),
    }
    if kind == kind_stub then
      stubs[located.identity] = located
    else
      cores[#cores + 1] = located
    end
    was_end = offset + stored_length
  end
  if not imaged then return head end
  for _, range in ipairs(ranges) do
    if sha256(range[1]) ~= range[2] then return head end
  end
  gaps[#gaps + 1] = head:sub(was_end + 1, manifest_offset)
  for _, gap in ipairs(gaps) do
    if gap:find("[^\0]") ~= nil then return head end
  end
  local shell = head:sub(1, shell_end)
  for _, core in ipairs(cores) do
    local stub = if core.codec == codec_zstd then stubs[core.identity] else nil end
    local text = if stub ~= nil then
      arm_fields(core.offset, core.stored_length, core.length, core.digest,
        stub.offset, stub.stored_length, stub.digest)
      else
      arm_fields(core.offset, core.stored_length, core.length, core.digest)
      end
    local found = shell:find(text, 1, true)
    if found ~= nil then
      if shell:find(text, found + 1, true) ~= nil then return head end
      shell = shell:sub(1, found - 1) .. "cosmic_core=" .. hex(core.keyed) .. " " ..
        shell:sub(found + #text)
    end
  end
  -- The comment that pads the launcher to its fixed length (`launcher`)
  -- is as long as those fields' digits leave it.
  shell = shell:gsub("\n# *\n$", "\n#\n")
  return table.concat({ "cosmic-head-image-v2\0", shell, "\0",
    head:sub(manifest_at, manifest_at + 15), string.pack(">I4I4", count, size),
    table.concat(entries), head:sub(at, #head) })
end

--- The artifact `split` read `parts` from, with `database` in place of
--- its own: the same head, and a trailer of the same kind whose last
--- field is the new database's length.
function artifact.rejoin(parts: artifact.Split, database: string): string?, string
  if not String.starts_with(database, sqlite_header) then
    return nil, "the new database has no SQLite header"
  end
  local manifest_offset = #parts.head - manifest_length
  local trailer = (parts.host and host_trailer_magic or trailer_magic) ..
    string.pack(">I4I4I8I8I8I8", version, trailer_length, manifest_offset,
      manifest_length, #parts.head, #database)
  return parts.head .. database .. trailer, ""
end

return artifact
