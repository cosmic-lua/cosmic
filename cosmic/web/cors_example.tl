--- Worked examples for [`cosmic.web.cors`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any other test.

local Cors = require("cosmic.web.cors")
local Web = require("cosmic.web")

local Example = {}

--- One partner site may read the API with its cookies; a preflight is answered
--- without calling a route.
function Example.middleware()
  local app = Web.app{
    middleware = { Cors.middleware{ allow_origins = { "https://app.example.com" }, allow_credentials = true } },
    routes = { Web.get("/api", function(_req: Web.Request): Web.Response
      return Web.json({ ok = true })
    end) },
  }
  local client = Web.test_client(app)
  local res = client:get("/api", { headers = { Origin = "https://app.example.com" } })
  print(res.headers["access-control-allow-origin"])
  assert(res.headers["access-control-allow-origin"] == "https://app.example.com")
  local preflight = client:options("/api", { headers = { Origin = "https://app.example.com",
    ["Access-Control-Request-Method"] = "GET" } })
  assert(preflight.status == 204)
end

--- The origins to give [`Csrf.middleware`] too, so the two lists agree.
function Example.trusted()
  local origins = Cors.trusted({ allow_origins = { "https://App.example.com", "null" } })
  print(origins[1])
  assert(#origins == 1 and origins[1] == "https://app.example.com")
end

return Example
