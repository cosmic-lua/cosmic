--- Worked examples for [`cosmic.web.csrf`] (here, where the session's stores
--- can be required), shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any other test.

local Csrf = require("cosmic.web.csrf")
local Html = require("cosmic.html")
local Secret = require("cosmic.web.secret")
local Session = require("cosmic.web.session")
local SessionCookie = require("cosmic.web.session.cookie")
local Web = require("cosmic.web")

local Example = {}

--- An app with a page that carries the token and a form that returns it.
local function page_and_form(): Web.TestClient
  local app = Web.app{
    middleware = { Session.middleware{ store = SessionCookie.store{ keys = { Secret.generate() } } }, Csrf.middleware() },
    routes = {
      Web.get("/form", function(req: Web.Request): Web.Response
        return Web.text(Csrf.token(req))
      end),
      Web.post("/save", function(_req: Web.Request): Web.Response
        return Web.text("saved")
      end),
    },
  }
  return Web.test_client(app)
end

--- A page renders `Csrf.token(req)`; the form or an htmx request sends it
--- back in the `csrf_token` field or the `X-CSRF-Token` header.
function Example.token()
  local client = page_and_form()
  local token = client:get("/form").body
  local with = client:post("/save", { form = { [Csrf.FIELD] = token } })
  local without = client:post("/save", { form = {} })
  print(with.status, without.status)
  assert(with.status == 200 and without.status == 403)
  local header = client:post("/save", { headers = { [Csrf.HEADER] = token } })
  assert(header.status == 200)
end

--- The hidden input of a form.
function Example.field()
  local seen: mut {string} = {}
  local app = Web.app{
    middleware = { Session.middleware{ store = SessionCookie.store{ keys = { Secret.generate() } } } },
    routes = { Web.get("/", function(req: Web.Request): Web.Response
      local field = Html.raw(Csrf.field(req))
      local meta = Html.raw(Csrf.meta(req))
      local headers = Html.raw_json(Csrf.hx_headers(req))
      seen[#seen + 1] = field
      seen[#seen + 1] = meta
      seen[#seen + 1] = headers
      return Web.text("ok")
    end) },
  }
  Web.test_client(app):get("/")
  local field, meta, headers = seen[1], seen[2], seen[3]
  print(field)
  assert(field and field:find('<input type="hidden" name="csrf_token" value="', 1, true))
  assert(meta and meta:find('<meta name="csrf-token" content="', 1, true))
  assert(headers and headers:find('{"X-CSRF-Token":"', 1, true))
end

--- A site with no session relies on the Origin check alone: a POST from
--- another site is refused, one from the site itself (or from curl) is not.
function Example.middleware()
  local app = Web.app{
    middleware = { Csrf.middleware{ token = false } },
    routes = { Web.post("/subscribe", function(_req: Web.Request): Web.Response
      return Web.text("subscribed")
    end) },
  }
  local client = Web.test_client(app)
  local own = client:post("/subscribe", { headers = { Origin = "http://testserver" } })
  local other = client:post("/subscribe", { headers = { Origin = "https://evil.example" } })
  print(own.status, other.status)
  assert(own.status == 200 and other.status == 403)
end

--- The meta tag, for a script that sets the header itself.
function Example.meta()
  local seen: {string} = {}
  local app = Web.app{
    middleware = { Session.middleware{ store = SessionCookie.store{ keys = { Secret.generate() } } } },
    routes = { Web.get("/", function(req: Web.Request): Web.Response
      seen[1] = Html.raw(Csrf.meta(req))
      return Web.text("ok")
    end) },
  }
  Web.test_client(app):get("/")
  local shown = assert(seen[1], "the handler never ran")
  print(shown)
  assert(shown:find('name="csrf-token"', 1, true))
end

--- The attribute value that puts the token on every htmx request below an
--- element: `<body hx-headers='...'>`.
function Example.hx_headers()
  local seen: {string} = {}
  local app = Web.app{
    middleware = { Session.middleware{ store = SessionCookie.store{ keys = { Secret.generate() } } } },
    routes = { Web.get("/", function(req: Web.Request): Web.Response
      seen[1] = Html.raw_json(Csrf.hx_headers(req))
      return Web.text("ok")
    end) },
  }
  Web.test_client(app):get("/")
  local shown = assert(seen[1], "the handler never ran")
  print(shown)
  assert(shown:find('{"X-CSRF-Token":"', 1, true))
end

return Example
