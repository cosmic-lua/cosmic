local Proc = require("cosmic.proc")
local Store = require("cosmic.store")
local sys = require("cosmic.sys")

return function(): integer
  local artifact = assert(Store.meta("artifact"))
  assert(Proc.executable() == artifact)
  assert(sys.executable() == artifact)
  print("hello from the portable fixture")
  return 0
end
