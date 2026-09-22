local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")

--- The public wrapper and annotated syscall name the same directly executable
--- logical program. Native mode preserves the physical executable answer;
--- portable coverage supplies the artifact answer in identity_test.tl.
local function test_executable_wraps_the_public_syscall()
  local direct = assert(sys.executable())
  local wrapped = assert(Proc.executable())
  assert(wrapped == direct)
  assert(wrapped:sub(1, 1) == "/")
end
