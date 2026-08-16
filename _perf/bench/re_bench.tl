--- POSIX regex scenarios: the cosmic.re wrapper over cosmo.re.
--- The convenience surface (match, split, gsub) takes a pattern STRING
--- per call, so these scenarios measure what naive callers pay —
--- including pattern compilation — while re_search_compiled brackets
--- the engine's own search cost with compilation hoisted out. Checks
--- are known-answer, so a faster-but-wrong match path fails instead of
--- winning.

local re = require("cosmic.re")
local pt = require("_perf.perf_types")

-- A log-like line and the field-extracting pattern a log scanner
-- would run against every line.
local LOG_LINE =
"2026-08-07T01:23:45 GET /api/v1/users/1234?q=abc 200 173ms"
local LOG_PATTERN =
"([0-9]+)-([0-9]+)-([0-9]+)T([0-9:]+) ([A-Z]+) ([^ ]+) ([0-9]+)"

-- A PATH-like list for split, with empty fields at both ends so the
-- check pins the keep-empty-fields contract: 5 separators, 6 fields.
local COLON_LIST = ":/usr/bin:/usr/local/bin:/opt/tool/bin:/home/user/.local/bin:"
local COLON_FIELDS = 6

--- Build a deterministic multi-line block for gsub: 64 lines with a
--- number in each, so redaction has real work on every line.
--- @return string The block
local function build_gsub_text(): string
  local parts: {string} = {}
  for i = 1, 64 do
    parts[i] = "user-" .. (1000 + i) .. " logged in from host-" .. i
  end
  return table.concat(parts, "\n")
end

local GSUB_TEXT = build_gsub_text()

local function scenarios(): {pt.Scenario}, string
  local compiled, cerr = re.compile(LOG_PATTERN)
  if not compiled then
    return nil, "compile: " .. tostring(cerr)
  end

  return {
    {
      -- What a naive per-line log scanner pays: pattern string in,
      -- captures out, every call.
      name = "re_match_log_line",
      fn = function(_: any): any
        local m = re.match(LOG_LINE, LOG_PATTERN)
        if m == nil then return nil end
        return m.caps
      end,
      check = function(_: any, res: any): boolean, string
        if not (res is {string}) then
          return false, "re_match_log_line: result is not a {string}"
        end
        local caps = res
        if #caps ~= 7 then
          return false, "wrong capture count"
        end
        if caps[1] ~= "2026" or caps[5] ~= "GET" or caps[7] ~= "200" then
          return false, "wrong captures: " .. table.concat(caps, ",")
        end
        return true
      end,
    },
    {
      -- The engine floor: same pattern and text, compilation hoisted.
      -- The gap between this and re_match_log_line is the wrapper's
      -- per-call compile cost.
      name = "re_search_compiled",
      fn = function(_: any): any
        local _m, caps = (compiled as re.Regex):match(LOG_LINE) -- cast: record union after guard
        return caps
      end,
      check = function(_: any, res: any): boolean, string
        if not (res is {string}) then
          return false, "re_search_compiled: result is not a {string}"
        end
        local caps = res
        if #caps ~= 7 or caps[5] ~= "GET" then
          return false, "wrong compiled captures"
        end
        return true
      end,
    },
    {
      name = "re_split_colon_list",
      fn = function(_: any): any
        return (re.split(COLON_LIST, ":"))
      end,
      check = function(_: any, res: any): boolean, string
        if not (res is {string}) then
          return false, "re_split_colon_list: result is not a {string}"
        end
        local fields = res
        if #fields ~= COLON_FIELDS then
          return false, "wrong field count: " .. tostring(#fields)
        end
        if fields[1] ~= "" or fields[2] ~= "/usr/bin" or fields[#fields] ~= "" then
          return false, "wrong fields"
        end
        return true
      end,
    },
    {
      name = "re_gsub_redact_numbers",
      fn = function(_: any): any
        return (re.gsub(GSUB_TEXT, "[0-9]+", "N"))
      end,
      check = function(_: any, res: any): boolean, string
        if not (res is string) then
          return false, "re_gsub_redact_numbers: result is not a string"
        end
        local out = res
        if out:find("%d") then
          return false, "digits survived redaction"
        end
        if not out:find("user-N logged in from host-N", 1, true) then
          return false, "redacted shape wrong"
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
