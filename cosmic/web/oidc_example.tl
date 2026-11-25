--- Worked examples for [`Web.oidc`], shown by `cosmic docs` under
--- the symbol each one demonstrates and run by `cosmic test` like any other
--- test. A stand-in provider takes the place of a real one's network.

local Clock = require("cosmic.clock")
local Http = require("cosmic.http")
local Jose = require("cosmic.jose")
local Json = require("cosmic.json")
local Key = require("cosmic.key")
local Secret = require("cosmic.web.secret")
local Session = require("cosmic.web.session")
local SessionCookie = require("cosmic.web.session.cookie")
local Url = require("cosmic.url")
local Web = require("cosmic.web")

local record Example
end

--- A page behind a login: a visit with nobody logged in is sent to the
--- provider, and the provider's response logs in and comes back. The
--- provider here is a stand-in that logs in anyone as `ada`.
function Example.oidc()
  local issuer = "https://id.example.com"
  local nonce: mut {string: string} = {}
  local signer = Key.generate("p256")
  local function provider(method: string, url: string, _: Http.Options): Http.Body?, string
    local body: Json.Value
    if url == issuer .. "/.well-known/openid-configuration" then
      body = {
        issuer = issuer, authorization_endpoint = issuer .. "/authorize",
        token_endpoint = issuer .. "/token", jwks_uri = issuer .. "/jwks",
      }
    elseif url == issuer .. "/jwks" then
      body = { keys = Json.array({ Jose.jwk(signer.public, "k") }) }
    elseif url == issuer .. "/token" and method == "POST" then
      body = { id_token = Jose.sign(signer, {
        iss = issuer, sub = "ada", aud = "my-app", nonce = nonce["value"] or "",
        exp = Clock.now_ns() // 1000000000 + 300, name = "Ada",
      }, { kid = "k" }) }
    else
      return nil, "no such URL"
    end
    return { status = 200, body = assert(Json.encode(body)), headers = {} }, ""
  end
  local app = Web.app{
    routes = {
      Web.get("/", function(req: Web.Request): Web.Response
        local who = assert(Web.who(req).oidc)
        return Web.text("hello " .. (who.name or who.subject))
      end, { middleware = { Web.require_login() } }),
    },
    middleware = {
      Session.middleware{ store = SessionCookie.store{ keys = { Secret.generate() } } },
      Web.oidc{
        issuer = issuer, client_id = "my-app", redirect_uri = "https://app.example.com/auth/callback",
        fetch = provider,
      },
    },
  }
  local client = Web.test_client(app)
  -- A browser on an https page: the session cookie is Secure.
  client.scheme = "https"
  local first = client:get("/", { headers = { Accept = "text/html" } })
  print(first.status, first.redirect_location)
  local sent = client:get(assert(first.redirect_location))
  local asked = assert(Url.decode_query(assert(Url.parse(assert(sent.redirect_location))).query or ""))
  nonce["value"] = assert(Url.query_first(asked, "nonce"))
  local back = client:get("/auth/callback", { query = {
    state = assert(Url.query_first(asked, "state")), code = "c",
  } })
  print(back.status, back.redirect_location)
  print(client:get("/"):text())
  assert(client:get("/"):text() == "hello Ada")
end

return Example
