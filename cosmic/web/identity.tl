--- Who a request comes from, by every way cosmic.web finds out: the tailnet
--- ([`Web.tailnet`]), a login with an OpenID Connect provider
--- ([`Web.oidc`]), a passkey ([`Web.passkeys`]) and a client certificate
--- over mutual TLS. [`Web.who`] reads them all at once; each middleware
--- keeps what it found under its key here, so reading needs none of their
--- modules loaded.
---
---     local who = Web.who(req)
---     local tailnet = who.tailnet
---     if tailnet ~= nil then return Web.text("hello " .. tailnet.login_name) end
--- @public

local ClientCert = require("cosmic.web.client_cert")
local type Json = require("cosmic.json")
local Request = require("cosmic.web.request")
local type Tailscale = require("cosmic.tailscale")
local type Tls = require("cosmic.tls")
local Types = require("cosmic.web.types")

local record Identity
  --- Where a [`Tailnet`] identity came from.
  enum TailnetSource
    --- The daemon's whois of the connection's far end.
    "whois"
    --- The headers of `tailscale serve`, from a loopback peer (with
    --- `serve`) or at the socket the daemon's Serve passes requests to.
    "serve"
  end

  --- Who a request comes from on the tailnet, as [`Web.tailnet`] found it.
  record Tailnet
    --- The name a person logs in as; `tagged-devices` for a tagged node.
    login_name: string
    --- The name to show a person.
    display_name: string
    --- Where their picture is, when they have one.
    picture_url?: string
    --- The node the request came from; nil behind `tailscale serve`,
    --- whose headers name the user alone.
    node?: Tailscale.Node
    --- Whether the node is tagged, so that no person is behind it.
    tagged: boolean
    --- The capabilities the policy grants the peer on this node, each
    --- name to the values of its grants: as [`cosmic.tailscale.WhoIs.caps`].
    caps: {string: {Json.Value}}
    --- Where it came from.
    source: TailnetSource
  end

  --- Who logged in with an OpenID Connect provider, as [`Web.oidc`] found it.
  record Oidc
    --- The provider: the ID token's `iss`.
    issuer: string
    --- Who they are at the provider: the ID token's `sub`, which the
    --- provider never gives another person. Key an account by this and
    --- `issuer`, never by `email`, which a person can change. The login
    --- binds the session ([`Handle:bind_subject`]) to this alone, so where
    --- two providers, or passkeys beside one, can name the same text,
    --- `destroy_subject` with it ends the sessions of each person it names.
    subject: string
    --- Their email address, when the provider gave one.
    email?: string
    --- Whether the provider has checked that the address is theirs.
    email_verified: boolean
    --- Their name, to show.
    name?: string
    --- The name they chose to be known by at the provider.
    preferred_username?: string
    --- Where their picture is.
    picture_url?: string
    --- When they logged in, in seconds since the epoch.
    logged_in_at: integer
    --- The claims of the ID token that `keep_claims` names, and the
    --- ones above, as the token held them.
    claims: {string: Json.Value}
  end

  --- Who logged in with a passkey, as [`Web.passkeys`] found it.
  record Passkey
    --- The user handle of the passkey: [`User.handle`].
    user_handle: string
    --- The passkey's credential id, raw bytes.
    credential_id: string
    --- Whether the authenticator verified the user (a PIN, a fingerprint).
    user_verified: boolean
    --- When they logged in, in seconds since the epoch.
    logged_in_at: integer
  end

  --- Who a request comes from: each field is nil where that way found no one, or its middleware does not run.
  record Who
    --- Who [`Web.tailnet`] found on the tailnet.
    tailnet?: Tailnet
    --- Who [`Web.oidc`] found logged in.
    oidc?: Oidc
    --- Who [`Web.passkeys`] found logged in.
    passkey?: Passkey
    --- The certificate the client presented over mutual TLS, where the server verified it and it is still valid.
    client_cert?: Tls.Peer
  end
  --- Internal: the key [`Web.tailnet`] keeps its identity under.
  TAILNET: Types.Key<Tailnet>
  --- Internal: the key [`Web.oidc`] keeps its identity under.
  OIDC: Types.Key<Oidc>
  --- Internal: the key [`Web.passkeys`] keeps its identity under.
  PASSKEY: Types.Key<Passkey>
end

Identity.TAILNET = Request.key("tailnet.identity")
Identity.OIDC = Request.key("oidc.identity")
Identity.PASSKEY = Request.key("passkeys.identity")

--- Who `req` comes from, by each way there is.
--- @param req Types.Request The request
--- @return Identity.Who Who it comes from
function Identity.who(req: Types.Request): Identity.Who
  return {
    tailnet = req:get(Identity.TAILNET),
    oidc = req:get(Identity.OIDC),
    passkey = req:get(Identity.PASSKEY),
    client_cert = ClientCert.peer(req),
  }
end

return Identity
