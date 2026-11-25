--- The fixed terms of the artifact layout (version 2) that every writer of
--- one shares: [`build.artifact`], which writes portable and host programs
--- for the build, and [`cosmic.store`]'s [`Store.host_program`], which
--- writes a host program for any program that asks. A host program is the
--- running core at offset 0, zero-filled to the core alignment, a manifest
--- naming it as the one entry (a raw core), a database and a trailer whose
--- magic says host: the kernel runs it directly, with no launcher, where
--- that core runs. It requires nothing, so a verdict key that turns on it
--- turns on the layout alone.
---
---     local layout = require("cosmic.internal.artifact_layout")
---     print(layout.version) -- 2

local type raw_store = require("cosmic.internal.store")

local record artifact_layout
  --- The layout version this writer writes and its readers read.
  version: integer
  --- The bytes of a portable program's launcher, ahead of its cores.
  shell_length: integer
  --- What each core's offset is a multiple of.
  core_alignment: integer
  --- The bytes the manifest takes, zero-filled past its entries.
  manifest_length: integer
  --- The bytes of the manifest's head, ahead of its first entry.
  manifest_header_length: integer
  --- The bytes of one entry of the manifest.
  entry_length: integer
  --- The bytes of the trailer, at the file's end.
  trailer_length: integer
  --- The manifest's magic, its first 8 bytes.
  manifest_magic: string
  --- A portable program's trailer magic.
  trailer_magic: string
  --- A host program's trailer magic.
  host_trailer_magic: string
  --- What a SQLite database begins with.
  sqlite_header: string
  --- An entry's kind: a core.
  kind_core: integer
  --- An entry's kind: the stub that decodes a compressed core.
  kind_stub: integer
  --- An entry's codec: its bytes stored as they are.
  codec_raw: integer
  --- An entry's codec: its bytes stored as a zstd frame.
  codec_zstd: integer
end

artifact_layout.version = 2
artifact_layout.shell_length = 16384
artifact_layout.core_alignment = 16384
artifact_layout.manifest_length = 4096
artifact_layout.manifest_header_length = 32
artifact_layout.entry_length = 104
artifact_layout.trailer_length = 48
artifact_layout.manifest_magic = "CosmicM1"
artifact_layout.trailer_magic = "CosmicT1"
artifact_layout.host_trailer_magic = "CosmicH1"
artifact_layout.sqlite_header = "SQLite format 3\0"
artifact_layout.kind_core = 1
artifact_layout.kind_stub = 2
artifact_layout.codec_raw = 0
artifact_layout.codec_zstd = 1

--- `value` rounded up to a multiple of `boundary`.
function artifact_layout.align(value: integer, boundary: integer): integer
  return ((value + boundary - 1) // boundary) * boundary
end

--- One manifest entry's bytes: the target and configuration it is for,
--- its kind and codec, where its stored bytes start and their digest,
--- then the length and digest of what they decode to.
function artifact_layout.entry(target_id: integer, configuration_id: integer, kind: integer,
                               codec: integer, offset: integer, stored: string,
                               stored_digest: string, length: integer, digest: string): string
  return string.pack(">I4I4I4I4I8I8", target_id, configuration_id, kind, codec, offset, #stored) ..
    stored_digest .. string.pack(">I8", length) .. digest
end

--- A host program of `core` and `database` (see the top of this module).
--- Nil and why when `database` has no SQLite header or `core` is empty
--- or has no digest.
function artifact_layout.host_program(core: raw_store.Core, database: string): string?, string
  local L = artifact_layout
  if #database < #L.sqlite_header or database:sub(1, #L.sqlite_header) ~= L.sqlite_header then
    return nil, "host program database has no SQLite header"
  end
  if #core.bytes == 0 or #core.digest ~= 32 then
    return nil, "host program core is empty or has no digest"
  end
  local manifest_offset = L.align(#core.bytes, L.core_alignment)
  local prefix_length = manifest_offset + L.manifest_length
  local manifest = L.manifest_magic .. string.pack(">I4I4I8I4I4", L.version, L.manifest_length,
    prefix_length, 1, L.entry_length) .. L.entry(core.target_id, core.configuration_id,
      L.kind_core, L.codec_raw, 0, core.bytes, core.digest, #core.bytes, core.digest)
  local trailer = L.host_trailer_magic .. string.pack(">I4I4I8I8I8I8",
    L.version, L.trailer_length, manifest_offset, L.manifest_length,
    prefix_length, #database)
  return table.concat({
    core.bytes,
    string.rep("\0", manifest_offset - #core.bytes),
    manifest, string.rep("\0", L.manifest_length - #manifest),
    database, trailer,
  }), ""
end

return artifact_layout
