--- Worked examples for [`cosmic.web.csp`], shown by `cosmic docs` under
--- the symbol each one demonstrates and run by `cosmic test` like any other
--- test.

local Csp = require("cosmic.web.csp")

local Example = {}

--- The CSP of an htmx app, as the header value.
function Example.htmx_default()
  local value = Csp.format(Csp.htmx_default())
  print(value)
  assert(value:find("script-src 'self'; style-src 'self'", 1, true))
end

return Example
