--- CPU-bound scenarios: hashing, encoding, compression, string handling.
--- Exercises the cosmo crypto/codec C bindings and pure-Lua cosmic.string
--- code. Checks use known-answer vectors and round-trip properties, so a
--- faster-but-wrong implementation fails instead of winning.

local hash = require("cosmic.hash")
local codec = require("cosmic.codec")
local compress = require("cosmic.compress")
local cstr = require("cosmic.string")
local pt = require("perf.perf_types")

-- NIST SHA-256 test vector: one million repetitions of "a".
local A_MILLION = string.rep("a", 1000000)
local SHA_A_MILLION = "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"

local CSV_FIELDS = 256

--- Build a deterministic ~64KB blob with enough variety to be a fair
--- compression and encoding workload.
--- @return string The blob
local function build_blob(): string
  local parts: {string} = {}
  for i = 1, 1024 do
    parts[i] = string.format(
      "record %04d: the quick brown fox jumps over the lazy dog %d\n",
      i, i * 37)
  end
  return table.concat(parts)
end

--- Build a deterministic CSV line of CSV_FIELDS fields.
--- @return string The line
local function build_csv(): string
  local fields: {string} = {}
  for i = 1, CSV_FIELDS do
    fields[i] = "field-" .. i
  end
  return table.concat(fields, ",")
end

local BLOB = build_blob()
local CSV = build_csv()

local function scenarios(): {pt.Scenario}, string
  return {
    {
      name = "hash_sha256_1mb",
      fn = function(_: any): any
        return hash.sha256_hex(A_MILLION)
      end,
      check = function(_: any, res: any): boolean, string
        if res as string ~= SHA_A_MILLION then
          return false, "digest mismatch: " .. tostring(res)
        end
        return true
      end,
    },
    {
      name = "codec_hex_roundtrip_64k",
      fn = function(_: any): any
        local encoded = codec.encode_hex(BLOB)
        return (codec.decode_hex(encoded))
      end,
      check = function(_: any, res: any): boolean, string
        if res as string ~= BLOB then
          return false, "hex roundtrip corrupted data"
        end
        return true
      end,
    },
    {
      name = "codec_base64_roundtrip_64k",
      fn = function(_: any): any
        local encoded = codec.encode_base64(BLOB)
        return (codec.decode_base64(encoded))
      end,
      check = function(_: any, res: any): boolean, string
        if res as string ~= BLOB then
          return false, "base64 roundtrip corrupted data"
        end
        return true
      end,
    },
    {
      name = "compress_roundtrip_64k",
      fn = function(_: any): any
        local packed = compress.compress(BLOB)
        return (compress.uncompress(packed))
      end,
      check = function(_: any, res: any): boolean, string
        if res as string ~= BLOB then
          return false, "compression roundtrip corrupted data"
        end
        return true
      end,
    },
    {
      name = "string_split_csv",
      fn = function(_: any): any
        return cstr.split(CSV, ",")
      end,
      check = function(_: any, res: any): boolean, string
        local fields = res as {string}
        if fields == nil or #fields ~= CSV_FIELDS then
          return false, "wrong field count"
        end
        if fields[1] ~= "field-1" or fields[CSV_FIELDS] ~= "field-" .. CSV_FIELDS then
          return false, "wrong field content"
        end
        return true
      end,
    },
  }
end

local function cleanup()
end

local M: pt.BenchModule = {
  scenarios = scenarios,
  cleanup = cleanup,
}

return M
