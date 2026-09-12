--- Checked JSON string decoding scenarios for the ASCII fast path proposal.
--- Inputs and expected bytes are constructed independently of json.decode.

local json = require("cosmic.json")
local pt = require("_perf.perf_types")

local ASCII = " !#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[]^_`" ..
"abcdefghijklmnopqrstuvwxyz{|}~" .. string.char(127)
local UTF8 = string.char(0xc2, 0xa2, 0xe2, 0x82, 0xac, 0xf0, 0x90, 0x8d, 0x88)
local ARRAY_MARKER = getmetatable(json.array({}))

--- Return n bytes from a deterministic rotation of the allowed ASCII alphabet.
local function ascii_bytes(offset: integer, n: integer): string
  if n == 0 then return "" end
  local rotated = ASCII:sub(offset) .. ASCII:sub(1, offset - 1)
  local parts: {string} = {}
  while #table.concat(parts) < n do
    parts[#parts + 1] = rotated
  end
  return table.concat(parts):sub(1, n)
end

local function quote(s: string): string
  return "\"" .. s .. "\""
end

local ASCII_LONG = ascii_bytes(1, 64 * 1024)
local ASCII_LONG_INPUT = quote(ASCII_LONG)

local function build_short(): {string}, string
  local expected: {string} = {}
  local encoded: {string} = {}
  for i = 1, 256 do
    local value = ascii_bytes(((i - 1) % #ASCII) + 1, (i - 1) % 32)
    expected[i] = value
    encoded[i] = quote(value)
  end
  return expected, "[" .. table.concat(encoded, ",") .. "]"
end

local function build_escaped(): {string}, string
  local expected: {string} = {}
  local encoded: {string} = {}
  local prefix = ascii_bytes(1, 1024)
  for i = 1, 64 do
    local suffix = "-escaped-" .. i
    expected[i] = prefix .. "\n\"\\" .. suffix
    encoded[i] = "\"" .. prefix .. "\\n\\\"\\\\" .. suffix .. "\""
  end
  return expected, "[" .. table.concat(encoded, ",") .. "]"
end

local function build_utf8(): {string}, string
  local expected: {string} = {}
  local encoded: {string} = {}
  local lengths = {0, 8, 64, 1024}
  for i = 1, 64 do
    local prefix = ascii_bytes(i, lengths[((i - 1) % #lengths) + 1])
    local suffix = "-utf8-" .. i
    expected[i] = prefix .. UTF8 .. suffix
    encoded[i] = quote(prefix .. UTF8 .. suffix)
  end
  return expected, "[" .. table.concat(encoded, ",") .. "]"
end

local ASCII_SHORT, ASCII_SHORT_INPUT = build_short()
local ASCII_ESCAPED, ASCII_ESCAPED_INPUT = build_escaped()
local ASCII_UTF8, ASCII_UTF8_INPUT = build_utf8()

local function check_string(name: string, res: any, expected: string): boolean, string
  if not (res is string) then return false, name .. ": result is not a string" end
  if res ~= expected then return false, name .. ": decoded bytes differ" end
  return true
end

local function check_array(name: string, res: any, expected: {string}): boolean, string
  if not (res is {any}) or getmetatable(res) ~= ARRAY_MARKER then
    return false, name .. ": result is not a JSON array"
  end
  if #res ~= #expected then return false, name .. ": wrong element count" end
  for i, wanted in ipairs(expected) do
    local got = res[i]
    if not (got is string) or got ~= wanted then
      return false, name .. ": bytes differ at element " .. i
    end
  end
  return true
end

local function scenarios(): {pt.Scenario}, string
  return {
    {
      name = "json_decode_ascii_long",
      fn = function(_: any): any return (json.decode(ASCII_LONG_INPUT)) end,
      check = function(_: any, res: any): boolean, string
        return check_string("json_decode_ascii_long", res, ASCII_LONG)
      end,
    },
    {
      name = "json_decode_ascii_short",
      fn = function(_: any): any return (json.decode(ASCII_SHORT_INPUT)) end,
      check = function(_: any, res: any): boolean, string
        return check_array("json_decode_ascii_short", res, ASCII_SHORT)
      end,
    },
    {
      name = "json_decode_ascii_escaped",
      fn = function(_: any): any return (json.decode(ASCII_ESCAPED_INPUT)) end,
      check = function(_: any, res: any): boolean, string
        return check_array("json_decode_ascii_escaped", res, ASCII_ESCAPED)
      end,
    },
    {
      name = "json_decode_ascii_utf8",
      fn = function(_: any): any return (json.decode(ASCII_UTF8_INPUT)) end,
      check = function(_: any, res: any): boolean, string
        return check_array("json_decode_ascii_utf8", res, ASCII_UTF8)
      end,
    },
  }
end

local M: pt.BenchModule = {scenarios = scenarios, cleanup = function() end}

return M
