--- Worked examples for [`cosmic.web.origin`], shown by `cosmic docs` under
--- the symbol each one demonstrates and run by `cosmic test` like any other
--- test.

local Origin = require("cosmic.web.origin")

local record Example end

--- The origin a URL names, in one spelling: the scheme and host in
--- lowercase, the default port dropped, the path, query and fragment
--- gone. A URL that carries userinfo names none.
function Example.of_url()
  print(Origin.of_url("HTTPS://Example.com:443/a?b#c"))
  assert(Origin.of_url("HTTPS://Example.com:443/a?b#c") == "https://example.com")
  assert(Origin.of_url("http://localhost:8080/") == "http://localhost:8080")
  assert(Origin.of_url("https://user@example.com/") == nil)
end

return Example
