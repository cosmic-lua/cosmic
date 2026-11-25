--- The fake arena `cosmic` of eval/check/grade_test.tl's API tests,
--- run as a [`cosmic.fake`] main. Its `test` stands in for a hidden API
--- test that ran on a copy of the project: it prints the variables
--- `probes` names, lists its directory, leaves a file behind, writes
--- its directory's path to `cwd_file`, prints `lines` and ends with
--- `code`. It does all that only where `kv_api_test.tl` is there, and
--- ends with 0 otherwise. Given `sleep_ms`, its `test` sleeps that long
--- first; given `fix_refuses_journal`, its `fix` fails where a
--- JOURNAL.md is in its directory. Every other command passes. What it
--- does is the JSON [`Fake.given`] reads.

local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fake = require("cosmic.fake")
local Fs = require("cosmic.fs")
local Shape = require("cosmic.shape")
local sys = require("cosmic.sys")

--- What a placed copy is given.
local record Given
  probes?: {string}
  lines?: {string}
  code?: integer
  cwd_file?: string
  sleep_ms?: integer
  fix_refuses_journal?: boolean
end

local GIVEN <const> = Shape.record_of("Given")

local function main(argv: {string}): integer
  local given, trouble = Shape.decode_into(Fake.given() or "{}", GIVEN.spec)
  if given == nil then
    local _, _ = Fs.put(2, "grade fake: " .. trouble .. "\n")
    return 2
  end
  if argv[1] == "fix" and given.fix_refuses_journal == true then
    return if assert(Fs.status("JOURNAL.md")).exists then 1 else 0 end
  end
  if argv[1] ~= "test" then return 0 end
  if given.sleep_ms ~= nil then assert(Clock.sleep(Clock.ms(given.sleep_ms))) end
  if given.cwd_file == nil then return given.code or 0 end
  local out: mut {string} = {}
  for _, name in ipairs(given.probes or {}) do
    local value = Env.get(name)
    out[#out + 1] = if value ~= nil then name .. "=" .. value else name .. " unset" end
  end
  if #out > 0 then assert(Fs.put(1, table.concat(out, "\n") .. "\n")) end
  out = {}
  if not assert(Fs.status("kv_api_test.tl")).exists then return 0 end
  local names = assert(Fs.list("."))
  local sorted: mut {string} = {}
  for _, name in ipairs(names) do sorted[#sorted + 1] = name end
  table.sort(sorted)
  for _, name in ipairs(sorted) do out[#out + 1] = name end
  assert(Fs.write("leftover.txt", "written by the hidden test\n"))
  assert(Fs.write(given.cwd_file, assert(sys.getcwd()) .. "\n"))
  for _, line in ipairs(given.lines or {}) do out[#out + 1] = line end
  if #out > 0 then assert(Fs.put(1, table.concat(out, "\n") .. "\n")) end
  return given.code or 0
end

return main
