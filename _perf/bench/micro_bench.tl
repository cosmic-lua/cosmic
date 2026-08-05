--- CPU-bound scenarios: hashing, encoding, compression, string handling.
--- Exercises the cosmo crypto/codec C bindings and pure-Lua cosmic.string
--- code. Checks use known-answer vectors and round-trip properties, so a
--- faster-but-wrong implementation fails instead of winning.

local hash = require("cosmic.hash")
local codec = require("cosmic.codec")
local compress = require("cosmic.compress")
local cstr = require("cosmic.string")
local ip = require("cosmic.ip")
local url = require("cosmic.url")
local pt = require("_perf.perf_types")

-- NIST SHA-256 test vector: one million repetitions of "a".
local A_MILLION = string.rep("a", 1000000)
local SHA_A_MILLION = "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"

-- NIST SHA-256 test vector: "abc".
local ABC = "abc"
local SHA_ABC = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

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

--- Build a deterministic query-value-like string with a realistic mix of
--- safe characters and ones url.encode must percent-escape, so decode()
--- has a real handful of %XX sequences to validate, not zero.
--- @return string The value
local function build_query_value(): string
  local parts: {string} = {}
  for i = 1, 64 do
    parts[i] = string.format("field %d: a/b+c=d&e %04d", i, i * 37)
  end
  return table.concat(parts, " ")
end

local BLOB = build_blob()
local CSV = build_csv()
local QUERY_VALUE = build_query_value()
local QUERY_ENCODED = url.encode(QUERY_VALUE)

local function scenarios(): {pt.Scenario}, string
  return {
    {
      name = "hash_sha256_1mb",
      fn = function(_: any): any
        return hash.sha256_hex(A_MILLION)
      end,
      check = function(_: any, res: any): boolean, string
        if res as string ~= SHA_A_MILLION then -- cast: from any
          return false, "digest mismatch: " .. tostring(res)
        end
        return true
      end,
    },
    {
      -- A tiny input, unlike hash_sha256_1mb: isolates fixed per-call
      -- wrapper overhead (encode + any post-processing) from the SHA-256
      -- compute itself, which is negligible here.
      name = "hash_sha256_small",
      fn = function(_: any): any
        return hash.sha256_hex(ABC)
      end,
      check = function(_: any, res: any): boolean, string
        if res as string ~= SHA_ABC then -- cast: from any
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
        if res as string ~= BLOB then -- cast: from any
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
        if res as string ~= BLOB then -- cast: from any
          return false, "base64 roundtrip corrupted data"
        end
        return true
      end,
    },
    {
      name = "compress_roundtrip_64k",
      fn = function(_: any): any
        local packed = assert(compress.compress(BLOB))
        return (compress.decompress(packed))
      end,
      check = function(_: any, res: any): boolean, string
        if res as string ~= BLOB then -- cast: from any
          return false, "compression roundtrip corrupted data"
        end
        return true
      end,
    },
    {
      -- A small input, unlike compress_roundtrip_64k: isolates the
      -- per-call wrapper overhead from the zlib compute itself, which
      -- barely registers on this little data. Replaces
      -- compress_deflate_roundtrip_small when deleted the
      -- size-prefixed deflate format.
      name = "compress_raw_roundtrip_small",
      fn = function(_: any): any
        local packed = assert(compress.compress(ABC, {format = "raw"}))
        return (compress.decompress(packed, {format = "raw"}))
      end,
      check = function(_: any, res: any): boolean, string
        if res as string ~= ABC then -- cast: from any
          return false, "raw roundtrip corrupted data"
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
        local fields = res as {string} -- cast: from any
        if fields == nil or #fields ~= CSV_FIELDS then
          return false, "wrong field count"
        end
        if fields[1] ~= "field-1" or fields[CSV_FIELDS] ~= "field-" .. CSV_FIELDS then
          return false, "wrong field content"
        end
        return true
      end,
    },
    {
      name = "net_ip_roundtrip",
      fn = function(_: any): any
        local a = ip.parse("192.168.1.1")
        -- cast: record union; literal always parses
        return (a as ip.Addr):format()
      end,
      check = function(_: any, res: any): boolean, string
        if res as string ~= "192.168.1.1" then -- cast: from any
          return false, "ip roundtrip mismatch: " .. tostring(res)
        end
        return true
      end,
    },
    {
      -- A pre-encoded query value with a real handful of %XX sequences,
      -- so decode()'s percent-encoding validation has actual work to do
      -- rather than short-circuiting on a string with no '%' at all.
      name = "url_decode_query_value",
      fn = function(_: any): any
        return (url.decode(QUERY_ENCODED))
      end,
      check = function(_: any, res: any): boolean, string
        if res as string ~= QUERY_VALUE then -- cast: from any
          return false, "url decode roundtrip corrupted data"
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
