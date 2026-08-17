--- JSON scenarios: decode/encode of small and large payloads.
--- Exercises cosmic.json wrappers and the cosmo DecodeJson/EncodeJson
--- C bindings end to end.

local json = require("cosmic.json")
local pt = require("_perf.perf_types")

local SMALL = [[{"name":"cosmic","version":3,"tags":["lua","teal","cosmo"],"nested":{"a":1,"b":true,"c":null}}]]
local LARGE_ITEMS = 1000

--- Build a deterministic 1000-record payload.
--- @return {any} The records
local function build_large(): {any}
  local items: {any} = {}
  for i = 1, LARGE_ITEMS do
    items[i] = {
      id = i,
      name = "item-" .. i,
      active = i % 2 == 0,
      score = i * 0.5,
      tags = {"alpha", "beta", "gamma"},
    }
  end
  return items
end

local large_table = build_large()
local large_json = json.encode(large_table)

local function scenarios(): {pt.Scenario}, string
  return {
    {
      name = "json_decode_small",
      fn = function(_: any): any
        return (json.decode(SMALL))
      end,
      check = function(_: any, res: any): boolean, string
        if not (res is {string: any}) then
          return false, "json_decode_small: result is not a {string: any}"
        end
        local t = res
        if t.name ~= "cosmic" then
          return false, "bad name: " .. tostring(t.name)
        end
        local tags = t.tags
        if not (tags is {any}) then
          return false, "json_decode_small: tags is not a {any}"
        end
        if #tags ~= 3 then
          return false, "bad tags"
        end
        return true
      end,
    },
    {
      name = "json_decode_large",
      fn = function(_: any): any
        return (json.decode(large_json))
      end,
      check = function(_: any, res: any): boolean, string
        if not (res is {{string: any}}) then
          return false, "json_decode_large: result is not a {{string: any}}"
        end
        local items = res
        if #items ~= LARGE_ITEMS then
          return false, "bad item count"
        end
        if items[500].id ~= 500 or items[500].name ~= "item-500" then
          return false, "bad item content"
        end
        return true
      end,
    },
    {
      name = "json_encode_large",
      fn = function(_: any): any
        return (json.encode(large_table))
      end,
      check = function(_: any, res: any): boolean, string
        if not (res is string) then
          return false, "json_encode_large: result is not a string"
        end
        local s = res
        if #s == 0 then
          return false, "encode returned nothing"
        end
        local decoded = json.decode(s)
        if not (decoded is {{string: any}}) then
          return false, "json_encode_large: roundtrip decode is not a {{string: any}}"
        end
        local items = decoded
        if #items ~= LARGE_ITEMS then
          return false, "roundtrip lost items"
        end
        if items[LARGE_ITEMS].name ~= "item-" .. LARGE_ITEMS then
          return false, "roundtrip corrupted content"
        end
        return true
      end,
    },
    {
      name = "json_roundtrip_small",
      fn = function(_: any): any
        local decoded = json.decode(SMALL)
        return (json.encode(decoded))
      end,
      check = function(_: any, res: any): boolean, string
        if not (res is string) then
          return false, "json_roundtrip_small: result is not a string"
        end
        local s = res
        local decoded = json.decode(s)
        if not (decoded is {string: any}) then
          return false, "json_roundtrip_small: decoded result is not a {string: any}"
        end
        local t = decoded
        if t.version ~= 3 then
          return false, "roundtrip corrupted content"
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
