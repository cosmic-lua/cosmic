local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Store = require("cosmic.store")
local sys = require("cosmic.sys")
return function(argv: {string}): integer
  local artifact = assert(Store.meta("artifact"))
  assert(Proc.executable() == artifact)
  assert(sys.executable() == artifact)
  Fs.put(Fs.stdout, "script " .. argv[1] .. " " .. argv[2] .. "\n")
  return 0
end
