--- Who a request comes from by the certificate its client presented
--- over mutual TLS: a server whose `tls` asks clients for one
--- ([`cosmic.tls.CertsOptions.clients`]) verifies it in the handshake,
--- and the app reads it here.
---
---     local type Tls = require("cosmic.tls")
---     local Web = require("cosmic.web")
---
---     local app = Web.app{
---       routes = {
---         Web.get("/", function(req: Web.Request): Web.Response
---           local peer = assert(Web.client_cert(req))
---           return Web.text("hello " .. (peer.uris[1] or peer.subject))
---         end),
---       },
---       middleware = { Web.require_client_cert(function(peer: Tls.Peer): boolean
---         return peer.uris[1] == "spiffe://example.com/deploy"
---       end) },
---     }
---
--- A certificate the handshake did not verify -- a server with
--- `required = false` serves such a client -- is never answered here, and
--- [`Web.require_client_cert`] refuses it; nor is one that has expired
--- since, on a connection kept open. Behind a proxy that ends TLS itself
--- (`trusted_proxy`, Serve) no request has one, so every one is refused.
--- @public

local Clock = require("cosmic.clock")
local Response = require("cosmic.web.response")
local type Tls = require("cosmic.tls")
local Types = require("cosmic.web.types")

local record ClientCert
end

--- The certificate `req`'s client presented, where the server verified
--- it and it is still valid; nil where it presented none, or one that
--- did not verify or has expired, or the request came in the clear.
function ClientCert.peer(req: Types.Request): Tls.Peer?
  local tls = req.raw.tls
  if tls == nil then return nil end
  local peer = tls.peer
  if peer == nil or not peer.verified or peer.not_after_ns <= Clock.now_ns() then return nil end
  return peer
end

--- Middleware that answers 403 to a request whose client presented no
--- verified certificate, or one `accept` (when given) refuses: put it on
--- the app, a mount or a route.
function ClientCert.require(accept?: function(peer: Tls.Peer): boolean): Types.Middleware
  return function(inner: Types.Handler): Types.Handler
    return function(req: Types.Request): Types.Response
      local peer = ClientCert.peer(req)
      if peer == nil then return Response.problem(403, "this needs a client certificate") end
      if accept ~= nil and not accept(peer) then
        return Response.problem(403, "this client's certificate is not one admitted here")
      end
      return inner(req)
    end
  end
end

return ClientCert
