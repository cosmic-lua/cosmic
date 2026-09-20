--- Times one portable re-entry without a host `time` command.

local Env = require("cosmic.env")
local Proc = require("cosmic.proc")
local Time = require("cosmic.time")

local marker = "COSMIC_FIXTURE_TIMING_STARTED"

return function(argv: {string}): integer
  local artifact, cache = argv[1], argv[2]
  assert(artifact ~= nil and cache ~= nil and argv[3] == nil,
    "usage: time_runtime.tl ARTIFACT CACHE")
  local started = Env.get(marker)
  if started ~= nil then
    assert(Proc.executable() == artifact,
      "runtime timing re-entry changed logical executable")
    local before = assert(math.tointeger(tonumber(started)),
      "runtime timing marker is invalid")
    local after = assert(Time.monotonic_ns())
    print(string.format("real %.6f", (after - before) / 1000000000))
    return 0
  end

  local environment = Env.all()
  environment[marker] = tostring(assert(Time.monotonic_ns()))
  environment["COSMIC_PORTABLE_CACHE"] = cache
  local arguments = { artifact, argv[0], artifact, cache }
  local _, trouble = Proc.exec(artifact, arguments, environment)
  error(trouble)
end
