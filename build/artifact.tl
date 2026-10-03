--- The one writer for the versioned portable artifact layout.
---
--- `prefix` consumes build.zig's generated target records and the exact raw
--- cores. It generates both the shell case arms and binary manifest from that
--- one sequence. `program` appends one SQLite database and the fixed trailer.
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
local trusted_store: raw_store | nil = nil
if type(extra) == "table" then
  trusted_store = extra as raw_store
end

local record artifact
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
function artifact.trusted_prefix(): string | nil, string
  if trusted_store == nil then
    return nil, "no retained portable artifact capability"
  end
  return trusted_store.trusted_prefix()
end

--- The running core's exact bytes and the identity its manifest names,
--- checked against that digest, from the same trusted capability.
function artifact.trusted_core(): raw_store.Core | nil, string
  if trusted_store == nil then
    return nil, "no retained portable artifact capability"
  end
  return trusted_store.trusted_core()
end

local version = 1
local shell_length = 16384
local core_alignment = 16384
local manifest_length = 4096
local manifest_header_length = 32
local entry_length = 56
local trailer_length = 48
local max_entries = 8
local manifest_magic = "CosmicM1"
local trailer_magic = "CosmicT1"
local host_trailer_magic = "CosmicH1"
local sqlite_header = "SQLite format 3\0"

local record Target
  target_id: integer
  configuration_id: integer
  configuration: string
  target: string
  uname_os: string
  uname_arch: string
  offset: integer
  length: integer
  digest: string
end

local function positive_u32(text: string): integer | nil
  local value = math.tointeger(tonumber(text))
  if value == nil or value <= 0 or value > 0xffffffff then
    return nil
  end
  return value
end

local function align(value: integer, boundary: integer): integer
  return ((value + boundary - 1) // boundary) * boundary
end

local function parse(records: string, cores: {string:string}): {Target} | nil, string
  local targets: {Target} = {}
  local identities: {string:boolean} = {}
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
      return nil, "generated target id is outside the v1 range"
    end
    local identity = target_id .. ":" .. configuration_id
    if identities[identity] then
      return nil, "duplicate generated target/configuration record"
    end
    local image = cores[target]
    if image == nil or #image == 0 then
      return nil, "no raw core for " .. target
    end
    identities[identity] = true
    targets[#targets + 1] = {
      target_id = target_id,
      configuration_id = configuration_id,
      configuration = configuration,
      target = target,
      uname_os = uname_os,
      uname_arch = uname_arch,
      offset = 0,
      length = #image,
      digest = sha256(image),
    }
  end
  if #targets == 0 or #targets > max_entries then
    return nil, "generated target count is outside the v1 bound"
  end
  return targets, ""
end

local function launcher(targets: {Target}, test_hooks: boolean,
                        selected_configuration?: integer): string | nil, string
  local arms: {string} = {}
  local systems: {string:boolean} = {}
  for _, target in ipairs(targets) do
    if selected_configuration == nil or
        target.configuration_id == selected_configuration then
      local system = target.uname_os .. ":" .. target.uname_arch
      if systems[system] then
        return nil, "duplicate generated uname record for launcher configuration"
      end
      systems[system] = true
      arms[#arms + 1] = string.format(
        "  '%s %s') cosmic_os=%s; cosmic_target_id=%d; " ..
          "cosmic_configuration_id=%d; cosmic_offset=%d; cosmic_block=%d; " ..
          "cosmic_length=%d; cosmic_sha256=%s ;;",
        target.uname_os, target.uname_arch, target.uname_os, target.target_id,
        target.configuration_id, target.offset, target.offset // core_alignment,
        target.length,
        hex(target.digest))
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

--- Builds reusable prefix bytes from build.zig's generated TSV and exact raw
--- core bytes, keyed by the target-name column.
function artifact.prefix(records: string, cores: {string:string},
                         selected_configuration?: integer): string | nil, string
  local targets, trouble = parse(records, cores)
  if targets == nil then
    return nil, trouble
  end

  local at = shell_length
  for _, target in ipairs(targets) do
    target.offset = at
    at = align(at + target.length, core_alignment)
  end
  local manifest_offset = at
  local prefix_length = manifest_offset + manifest_length
  local shell, shell_trouble = launcher(targets, false, selected_configuration)
  if shell == nil then
    return nil, shell_trouble
  end

  local parts: {string} = { shell }
  at = shell_length
  for _, target in ipairs(targets) do
    if at < target.offset then
      parts[#parts + 1] = string.rep("\0", target.offset - at)
    end
    local image = cores[target.target]
    parts[#parts + 1] = image
    at = target.offset + #image
    local next_at = align(at, core_alignment)
    if at < next_at then
      parts[#parts + 1] = string.rep("\0", next_at - at)
    end
    at = next_at
  end
  assert(at == manifest_offset)

  local manifest: {string} = {
    manifest_magic,
    string.pack(">I4I4I8I4I4", version, manifest_length, prefix_length,
      #targets, entry_length),
  }
  for _, target in ipairs(targets) do
    manifest[#manifest + 1] = string.pack(">I4I4I8I8", target.target_id,
      target.configuration_id, target.offset, target.length) .. target.digest
  end
  local manifest_bytes = table.concat(manifest)
  assert(#manifest_bytes == manifest_header_length + #targets * entry_length)
  parts[#parts + 1] = manifest_bytes ..
    string.rep("\0", manifest_length - #manifest_bytes)
  local prefix = table.concat(parts)
  assert(#prefix == prefix_length)
  return prefix, ""
end

--- Fixture-only constructor with deterministic FIFO synchronization points.
--- The ordinary `prefix` output contains no hook code or hook field names.
function artifact.test_prefix(records: string, cores: {string:string}): string | nil, string
  local targets, trouble = parse(records, cores)
  if targets == nil then return nil, trouble end
  local at = shell_length
  for _, target in ipairs(targets) do
    target.offset = at
    at = align(at + target.length, core_alignment)
  end
  local shell, shell_trouble = launcher(targets, true)
  if shell == nil then return nil, shell_trouble end
  local release = assert(artifact.prefix(records, cores))
  return shell .. release:sub(shell_length + 1), ""
end

--- Appends a database and the v1 trailer to prefix bytes made by `prefix`.
function artifact.program(prefix: string, database: string): string | nil, string
  if #database < #sqlite_header or not String.starts_with(database, sqlite_header) then
    return nil, "portable program database has no SQLite header"
  end
  if #prefix < shell_length + manifest_length then
    return nil, "portable prefix is truncated"
  end
  local manifest_offset = #prefix - manifest_length
  local manifest_at = manifest_offset + 1
  if prefix:sub(manifest_at, manifest_at + 7) ~= manifest_magic then
    return nil, "portable prefix has no v1 manifest"
  end
  local manifest_version, encoded_length, encoded_prefix =
    string.unpack(">I4I4I8", prefix, manifest_at + 8)
  if manifest_version ~= version or encoded_length ~= manifest_length or
      encoded_prefix ~= #prefix then
    return nil, "portable prefix manifest fields differ"
  end
  local trailer = trailer_magic .. string.pack(">I4I4I8I8I8I8",
    version, trailer_length, manifest_offset, manifest_length,
    #prefix, #database)
  assert(#trailer == trailer_length)
  return prefix .. database .. trailer, ""
end

--- A host program: `core` at offset 0, zero-filled to the core alignment,
--- a manifest naming it as the one entry, then `database` and a trailer
--- whose magic says host. It runs only where that core does.
function artifact.host_program(core: raw_store.Core, database: string): string | nil, string
  if #database < #sqlite_header or not String.starts_with(database, sqlite_header) then
    return nil, "host program database has no SQLite header"
  end
  if #core.bytes == 0 or #core.digest ~= 32 then
    return nil, "host program core is empty or has no digest"
  end
  local manifest_offset = align(#core.bytes, core_alignment)
  local prefix_length = manifest_offset + manifest_length
  local manifest = manifest_magic .. string.pack(">I4I4I8I4I4", version, manifest_length,
    prefix_length, 1, entry_length) .. string.pack(">I4I4I8I8", core.target_id,
      core.configuration_id, 0, #core.bytes) .. core.digest
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
--- against the file: a version and lengths this writer uses, a v1
--- manifest where it says, a database that starts right behind that
--- manifest, runs to the trailer and begins with SQLite's header.
function artifact.split(bytes: string): artifact.Split | nil, string
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
  if trailer_version ~= version or length ~= trailer_length then
    return nil, "not a v1 artifact trailer"
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
    return nil, "the artifact has no v1 manifest where its trailer says"
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

--- What of `head`, an artifact's bytes ahead of its database (`split`),
--- a verdict's key holds. It is `head` itself, unless a core its
--- manifest names carries debug information (build.core_image), which is
--- keyed by its image instead. Then it is `head` with each core stood
--- for by its image's digest ([`core_image.digest`]).
---
--- The fields that say where the cores lie and what their bytes hash to
--- are left out where they name exactly what is there: the manifest's
--- offsets, lengths, digests and prefix length, and a launcher arm's
--- `cosmic_offset`, `cosmic_block`, `cosmic_length` and `cosmic_sha256`.
--- Which bytes a launcher extracts, and whether they are the ones its
--- manifest names, is then the image it runs, whatever its debug
--- information weighs. The padding between the cores is held to zeros,
--- and the comment that pads the launcher is left out. A head that is
--- not so, in any part, is keyed whole.
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
  local entries: {string} = {}
  local gaps: {string} = {}
  local arms: {{string}} = {}
  local cores: {{string}} = {}
  for _ = 1, count do
    local target, configuration, offset, length: integer, integer, integer, integer
    target, configuration, offset, length, at = string.unpack(">I4I4I8I8", head, at)
    local digest = head:sub(at, at + 31)
    at = at + 32
    -- An unsigned 64-bit field past math.maxinteger reads as negative.
    if offset < was_end or length <= 0 or offset > manifest_offset - length then
      return head
    end
    if shell_end < 0 then
      shell_end = offset
    else
      gaps[#gaps + 1] = head:sub(was_end + 1, offset)
    end
    local core = head:sub(offset + 1, offset + length)
    local image = core_image.digest(core)
    if image ~= nil then imaged = true end
    cores[#cores + 1] = { core, digest }
    local keyed = image ~= nil and ("i" .. image) or ("b" .. digest)
    entries[#entries + 1] = string.pack(">I4I4", target, configuration) .. keyed
    arms[#arms + 1] = { string.format("cosmic_offset=%d; cosmic_block=%d; cosmic_length=%d; " ..
        "cosmic_sha256=%s ", offset, offset // core_alignment, length, hex(digest)),
      "cosmic_core=" .. hex(keyed) .. " " }
    was_end = offset + length
  end
  if not imaged then return head end
  for _, core in ipairs(cores) do
    if sha256(core[1]) ~= core[2] then return head end
  end
  gaps[#gaps + 1] = head:sub(was_end + 1, manifest_offset)
  for _, gap in ipairs(gaps) do
    if gap:find("[^\0]") ~= nil then return head end
  end
  local shell = head:sub(1, shell_end)
  for _, arm in ipairs(arms) do
    local found = shell:find(arm[1], 1, true)
    if found ~= nil then
      if shell:find(arm[1], found + 1, true) ~= nil then return head end
      shell = shell:sub(1, found - 1) .. arm[2] .. shell:sub(found + #arm[1])
    end
  end
  -- The comment that pads the launcher to its fixed length (`launcher`)
  -- is as long as those fields' digits leave it.
  shell = shell:gsub("\n# *\n$", "\n#\n")
  return table.concat({ "cosmic-head-image-v1\0", shell, "\0",
    head:sub(manifest_at, manifest_at + 15), string.pack(">I4I4", count, size),
    table.concat(entries), head:sub(at, #head) })
end

--- The artifact `split` read `parts` from, with `database` in place of
--- its own: the same head, and a trailer of the same kind whose last
--- field is the new database's length.
function artifact.rejoin(parts: artifact.Split, database: string): string | nil, string
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
