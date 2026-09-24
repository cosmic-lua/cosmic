--- The one writer for the versioned portable artifact layout.
---
--- `prefix` consumes build.zig's generated target records and the exact raw
--- cores. It generates both the shell case arms and binary manifest from that
--- one sequence. `program` appends one SQLite database and the fixed trailer.
--- `host_program` lays out the other format: the running core alone, at the
--- start of the file, then its manifest, database and trailer, so the kernel
--- executes it directly with no launcher.
--- Neither function writes a path; callers publish the returned bytes through
--- the repository's existing atomic file writer.

local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")
local launcher_template = require("build.launcher")
local type raw_store = require("cosmic.internal.store")

local extra: any = select(2, ...)
local trusted_store: raw_store | nil = nil
if type(extra) == "table" then
  trusted_store = extra as raw_store
end

local record artifact
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
    return nil, "no retained artifact capability"
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
      digest = Hash.sha256(image),
    }
  end
  if #targets == 0 or #targets > max_entries then
    return nil, "generated target count is outside the v1 bound"
  end
  return targets, ""
end

local function hex(bytes: string): string
  return Codec.hex(bytes)
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
  if #database < #sqlite_header or database:sub(1, #sqlite_header) ~= sqlite_header then
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
  if #database < #sqlite_header or database:sub(1, #sqlite_header) ~= sqlite_header then
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

return artifact
