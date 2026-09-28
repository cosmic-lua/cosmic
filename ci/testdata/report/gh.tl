-- A stand-in for the gh CLI, for report_test.tl: it answers `gh api
-- <endpoint>` from a state directory, FAKE_GH_STATE, and appends each
-- invocation to its `calls` file. Run with `cosmic --standalone`. The
-- state directory holds:
--
--   api/<endpoint>    the answer to `gh api <endpoint>` (an artifact's
--                     zip, too), every character of the endpoint but a
--                     letter or digit made "_"
--
-- Anything else answers as gh does a missing resource: HTTP 404, status 1.
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")

local state = assert(Env.get("FAKE_GH_STATE"), "FAKE_GH_STATE is unset")

local function read(path: string): string return (assert(Fs.read(path))) end
local function write(path: string, data: string) assert(Fs.write(path, data)) end
local function exists(path: string): boolean
  local there, why = Fs.exists(path)
  assert(there ~= nil, why)
  return there
end

local function missing(what: string): integer
  assert(Fs.put(Fs.stderr, "gh: Not Found (HTTP 404): " .. what .. "\n"))
  return 1
end

local function api(endpoint: string): integer
  local path = state .. "/api/" .. (endpoint:gsub("[^%w]", "_"))
  if not exists(path) then return missing(endpoint) end
  assert(Fs.put(Fs.stdout, read(path)))
  return 0
end

return function(argv: {integer:string}): integer
  local words: {string} = {}
  local i = 1
  while argv[i] do words[#words + 1] = argv[i]; i = i + 1 end
  local calls = state .. "/calls"
  local logged = exists(calls) and read(calls) or ""
  write(calls, logged .. table.concat(words, " ") .. "\n")
  if argv[1] == "api" and argv[2] then return api(argv[2]) end
  return missing(table.concat(words, " "))
end
