--- [`Web.who`] reads what each identity middleware kept, in one record.

local Identity = require("cosmic.web.identity")
local Web = require("cosmic.web")

--- A request no middleware has seen comes from no one; one whose tailnet and passkey middleware kept an identity
--- answers both, one whose login kept one answers it, and the ways that found none stay nil.
local function test_who_answers_what_each_middleware_kept()
  local seen: mut {Web.Who} = {}
  local function keep(inner: Web.Handler): Web.Handler
    return function(req: Web.Request): Web.Response
      if req.path == "/known" then
        req:set(Identity.TAILNET, { login_name = "will@example.com", display_name = "Will", tagged = false,
          caps = {}, source = "whois" })
        req:set(Identity.PASSKEY, { user_handle = "u1", credential_id = "c1", user_verified = true, logged_in_at = 1 })
      elseif req.path == "/login" then
        req:set(Identity.OIDC, { issuer = "https://id.example.com", subject = "s1", email_verified = false,
          logged_in_at = 1, claims = {} })
      end
      return inner(req)
    end
  end
  local app = Web.app{
    routes = {
      Web.get("/:where", function(req: Web.Request): Web.Response
        local who = Web.who(req)
        seen[#seen + 1] = who
        return Web.empty()
      end),
    },
    middleware = { keep },
  }
  local client = Web.test_client(app)
  assert(client:get("/unknown").status == 204 and client:get("/known").status == 204)
  assert(client:get("/login").status == 204)
  local nobody, known, login = assert(seen[1]), assert(seen[2]), assert(seen[3])
  assert(assert(login.oidc).subject == "s1" and login.tailnet == nil and login.passkey == nil)
  assert(nobody.tailnet == nil and nobody.oidc == nil and nobody.passkey == nil and nobody.client_cert == nil)
  assert(assert(known.tailnet).login_name == "will@example.com" and assert(known.passkey).user_handle == "u1")
  assert(known.oidc == nil and known.client_cert == nil)
end
