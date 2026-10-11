--- Worked examples for [`cosmic.web.headers`], shown by `cosmic docs` under
--- the symbol each one demonstrates and run by `cosmic test` like any other
--- test.

local Headers = require("cosmic.web.headers")
local Web = require("cosmic.web")

local Example = {}

--- Security headers and a CSP for every response, with a nonce for the
--- layout's inline scripts.
function Example.middleware()
  local app = Web.app{
    middleware = { Headers.middleware{
      csp = { directives = {
        ["default-src"] = { "'self'" },
        ["script-src"] = { "'self'", "{nonce}" },
      } },
      nonce = true,
    } },
    routes = { Web.get("/", function(req: Web.Request): Web.Response
      return Web.text("nonce " .. req:get(Headers.NONCE))
    end) },
  }
  local res = Web.test_client(app):get("/")
  print(res.headers["x-frame-options"], res.headers["content-security-policy"] ~= nil)
  assert(res.headers["x-frame-options"] == "DENY")
  assert(res.headers["content-security-policy"]:find("'nonce-", 1, true))
end

--- The CSP of an htmx app, as the header value.
function Example.htmx_default()
  local value = Headers.Csp.format(Headers.Csp.htmx_default())
  print(value)
  assert(value:find("script-src 'self'; style-src 'self'", 1, true))
end

return Example
