-- A module the test below imports, so the `.lua` test has a real
-- dependency closure: its `deps_` variable is what makes it re-run when
-- this file changes and what its fence grants it a read of. With the
-- closure empty, both are silently wrong and the test still passes.
local greet = {}

function greet.hi(name)
  return "hello, " .. name
end

return greet
