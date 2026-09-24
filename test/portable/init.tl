--- Small v1 artifact reader shared by portable fixture generators.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")

local record fixture
  record Entry
    target: integer
    configuration: integer
    offset: integer
    length: integer
    digest: string
  end

  record Artifact
    bytes: string
    prefix_length: integer
    manifest_offset: integer
    entries: {Entry}
  end
end

function fixture.read(path: string): fixture.Artifact | nil, string
  local bytes, read_trouble = Fs.read(path)
  if bytes == nil then return nil, read_trouble end
  if #bytes < 48 or bytes:sub(-48, -41) ~= "CosmicT1" then
    return nil, path .. ": portable trailer is missing"
  end
  local version, trailer_length, manifest_offset, manifest_length,
    prefix_length, database_length = string.unpack(">I4I4I8I8I8I8", bytes,
      #bytes - 39)
  if version ~= 1 or trailer_length ~= 48 or manifest_length ~= 4096 or
     prefix_length + database_length + trailer_length ~= #bytes or
     manifest_offset + manifest_length ~= prefix_length then
    return nil, path .. ": portable trailer fields differ"
  end
  local manifest_at = manifest_offset + 1
  if bytes:sub(manifest_at, manifest_at + 7) ~= "CosmicM1" then
    return nil, path .. ": portable manifest is missing"
  end
  local manifest_version, encoded_length, encoded_prefix, count, entry_length,
    at = string.unpack(">I4I4I8I4I4", bytes, manifest_at + 8)
  if manifest_version ~= 1 or encoded_length ~= manifest_length or
     encoded_prefix ~= prefix_length or entry_length ~= 56 or count < 1 or
     32 + count * entry_length > manifest_length then
    return nil, path .. ": portable manifest fields differ"
  end
  local entries: {fixture.Entry} = {}
  for _ = 1, count do
    local target: integer
    local configuration: integer
    local offset: integer
    local length: integer
    target, configuration, offset, length, at =
      string.unpack(">I4I4I8I8", bytes, at)
    local digest = bytes:sub(at, at + 31)
    at = at + 32
    if offset + length > manifest_offset or length < 1 then
      return nil, path .. ": portable core range is invalid"
    end
    entries[#entries + 1] = {
      target = target,
      configuration = configuration,
      offset = offset,
      length = length,
      digest = digest,
    }
  end
  return {
    bytes = bytes,
    prefix_length = prefix_length,
    manifest_offset = manifest_offset,
    entries = entries,
  }
end

function fixture.entry(artifact: fixture.Artifact, target: integer,
                       configuration: integer): fixture.Entry | nil
  for _, entry in ipairs(artifact.entries) do
    if entry.target == target and entry.configuration == configuration then
      return entry
    end
  end
  return nil
end

function fixture.change_byte(bytes: string, offset: integer): string | nil, string
  local at = offset + 1
  local byte = bytes:byte(at)
  if byte == nil then return nil, "byte offset is outside the artifact" end
  return bytes:sub(1, at - 1) .. string.char(byte ~ 1) .. bytes:sub(at + 1), ""
end

function fixture.prefix(artifact: fixture.Artifact): string
  return artifact.bytes:sub(1, artifact.prefix_length)
end

function fixture.prefix_hash(artifact: fixture.Artifact): string
  return Hash.hex_sha256(fixture.prefix(artifact))
end

--- Reads a generated target-record TSV and returns one blob per target, read
--- from MAKE_PATH(target), plus the raw TSV text (which build.artifact's own
--- writers also take directly). The three fixture writers differ only in
--- where each target's blob lives (a raw core under a per-target directory,
--- or a flat native payload file), so they share this loop.
function fixture.load_by_target(records_path: string,
                                make_path: function(string): string):
                                {string:string}, string
  local records = assert(Fs.read(records_path))
  local blobs: {string:string} = {}
  for line in records:gmatch("[^\n]+") do
    local target = line:match("^%d+\t%d+\t[^\t]+\t([^\t]+)\t")
    assert(target ~= nil, "invalid generated target record")
    blobs[target] = assert(Fs.read(make_path(target)))
  end
  return blobs, records
end

return fixture
