local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Store = require("cosmic.store")
local sys = require("cosmic.sys")

-- Set by the first run of a "reenter" probe so its replacement does not
-- exec again.
local reentered <const> = "COSMIC_FIXTURE_PROBE_REENTERED"

return function(argv: {string}): integer
  local artifact = assert(Store.meta("artifact"))
  assert(Proc.executable() == artifact)
  assert(sys.executable() == artifact)
  local script, first, second = assert(argv[0]), assert(argv[1]), assert(argv[2])
  if argv[3] == "reenter" and Env.get(reentered) == nil then
    -- Replace this process with the same artifact: the portable startup
    -- must find the logical executable again after the exec.
    local environment = Env.all()
    environment[reentered] = "1"
    local _, trouble = Proc.exec({ artifact, script, first, second, "reenter" },
      { env = environment })
    error(trouble)
  end
  Fs.put(Fs.stdout, "script " .. first .. " " .. second .. "\n")
  return 0
end
