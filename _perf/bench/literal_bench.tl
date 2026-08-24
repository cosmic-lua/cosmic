--- Literal scenarios: cosmic.literal read and written at the two shapes the
--- toolchain meets — a pin, and a coverage floor. Both are build wall clock
--- (`--make fetch` parses every `*_pin.tl`, `_tool/floor.tl` every committed
--- floor) and no scenario covered them. Inputs are built in memory, not read
--- from the files they imitate. The floor scenarios run FIRST: they churn most
--- per op, so a small scenario after them meets the same heap in every pass,
--- which keeps an A/A self-check quiet. Each check pins a probe value AND the
--- key count, so a reader or writer that dropped entries fails, not wins.

local check = require("cosmic.check")
local literal = require("cosmic.literal")
local pt = require("_perf.perf_types")

local PLATFORMS = {"linux-x86_64", "macos-arm64", "windows-x86_64"}
local FLOOR_ROWS = 100
local FLOOR_PATH = "cosmic/module%03d.tl"

--- Count a table's top-level keys.
--- @param t {string: any} The table
--- @return integer How many keys it has
local function count_keys(t: {string: any}): integer
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n
end

--- Build a pin-shaped table: the fields a `*_pin.tl` carries, one 64-hex
--- sha per platform, formatting to the few hundred bytes
--- `3p/cosmos/cosmos_pin.tl` (276 bytes) occupies.
--- @return {string: any} The pin
local function build_pin(): {string: any}
  local platforms: {string: any} = {}
  for i, name in ipairs(PLATFORMS) do
    platforms[name] = {sha = string.rep(string.format("%02x", i * 17), 32)}
  end
  return {
    format = "zip",
    platforms = platforms,
    strip_components = 0,
    url = "https://example.invalid/download/{version}/cosmos.zip",
    version = "2026.08.24-354c17e08",
  }
end

--- Build a coverage-floor-shaped table: one `{covered, total}` row per
--- source path. `.cosmic-coverage` carries 251 and is the largest literal
--- this toolchain reads; 100 is that shape at a per-op cost the harness
--- resolves without flagging its own A/A noise floor.
--- @return {string: any} The floor, keyed by path
local function build_floor(): {string: any}
  local rows: {string: any} = {}
  for i = 1, FLOOR_ROWS do
    rows[string.format(FLOOR_PATH, i)] = {covered = i * 3, total = i * 4}
  end
  return rows
end

local PIN, FLOOR = build_pin(), build_floor()
local PIN_KEYS = count_keys(PIN)
local PIN_SOURCE = check.must(literal.format(PIN))
local FLOOR_SOURCE = check.must(literal.format(FLOOR))
local FLOOR_KEY, FLOOR_COVERED = string.format(FLOOR_PATH, 50), 50 * 3

--- Check what a scenario produced: the top-level key count its input had,
--- and one probe value — `t[key]`, or `t[key][field]` when `field` is not
--- "". A formatted source is read back first, so the writer is held to
--- the reader's bar.
--- @param name string The scenario, for the message
--- @param res any What the scenario returned
--- @param keys integer How many top-level keys the input had
--- @param key string The probed key
--- @param field string The probed key's field, "" to probe the key
--- @param want any What the probe must equal
--- @return boolean Whether it all held
--- @return string What was wrong
local function verify(name: string, res: any, keys: integer, key: string,
    field: string, want: any): boolean, string
  local read: any = res
  if res is string then
    local back, err = literal.parse(res)
    if not back then
      return false, name .. ": its own output does not parse: " .. tostring(err)
    end
    read = back
  end
  if not (read is {string: any}) then
    return false, name .. ": result is not a table, got " .. type(res)
  end
  local got = count_keys(read)
  if got ~= keys then
    return false, name .. ": read " .. tostring(got) .. " keys, not " .. tostring(keys)
  end
  local at = read[key]
  if field ~= "" then
    if not (at is {string: any}) then
      return false, name .. ": " .. key .. " is not a row"
    end
    at = at[field]
  end
  if at ~= want then
    return false, name .. " " .. key .. ": " .. tostring(at) .. " not " .. tostring(want)
  end
  return true
end

local function scenarios(): {pt.Scenario}, string
  return {
    {
      name = "literal_parse_floor",
      fn = function(_: any): any
        return (literal.parse(FLOOR_SOURCE))
      end,
      check = function(_: any, res: any): boolean, string
        return verify("literal_parse_floor", res, FLOOR_ROWS, FLOOR_KEY, "covered",
          FLOOR_COVERED)
      end,
    },
    {
      name = "literal_format_floor",
      fn = function(_: any): any
        return (literal.format(FLOOR))
      end,
      check = function(_: any, res: any): boolean, string
        return verify("literal_format_floor", res, FLOOR_ROWS, FLOOR_KEY, "covered",
          FLOOR_COVERED)
      end,
    },
    {
      name = "literal_parse_pin",
      fn = function(_: any): any
        return (literal.parse(PIN_SOURCE))
      end,
      check = function(_: any, res: any): boolean, string
        return verify("literal_parse_pin", res, PIN_KEYS, "version", "", PIN.version)
      end,
    },
    {
      name = "literal_format_pin",
      fn = function(_: any): any
        return (literal.format(PIN))
      end,
      check = function(_: any, res: any): boolean, string
        return verify("literal_format_pin", res, PIN_KEYS, "version", "", PIN.version)
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
