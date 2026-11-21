--- Who a request comes from on the tailnet, for an app served to it: the
--- user and node behind the connection, as the machine's tailscaled says,
--- and the capabilities the tailnet policy grants them on this node. The
--- policy is the app's permission system and there is no login: a person
--- on the tailnet is already known.
---
---     local Web = require("cosmic.web")
---
---     local app = Web.app{
---       routes = {
---         Web.get("/", function(req: Web.Request): Web.Response
---           local who = assert(Web.tailnet_identity(req))
---           return Web.text("hello " .. who.display_name)
---         end),
---         Web.get("/admin", function(_: Web.Request): Web.Response
---           return Web.text("the switches")
---         end, { middleware = { Web.require_cap("example.com/cap/admin") } }),
---       },
---       middleware = { Web.tailnet() },
---     }
---
--- [`Web.tailnet`] asks the daemon who the connection's far end is
--- ([`cosmic.tailscale.Client.whois_result`]) and keeps the answer on the request, where
--- [`Web.tailnet_identity`] reads it and [`Web.require_cap`] tests it. It
--- answers by itself:
---
--- - 403 to a request from no node of the tailnet, unless `required` is
---   false, when the request goes on with no identity;
--- - 503 where the daemon cannot be asked, or refuses the app (a 403 of
---   its own), writing why to the app's sink: an app that cannot tell who
---   asks admits nobody.
---
--- The address asked about is the connection's own, never one a header
--- names: `trusted_proxy` moves [`Web.Request.client`], not this. A whois
--- waits as a task of the server's run, so other connections go on
--- meanwhile, and an answer is kept for `cache_ns` per address.
---
--- Behind `tailscale serve`, the connection comes from the loopback and
--- the daemon passes who asked in headers instead (`Tailscale-User-Login`,
--- `Tailscale-User-Name`, `Tailscale-User-Profile-Pic`, and
--- `Tailscale-App-Capabilities` where the serve config forwards
--- capabilities). `serve = true` reads them from a loopback peer, and only
--- there. Any local process can connect to the loopback and send them, so
--- turn it on only where the app listens on the loopback alone and the
--- machine's users are trusted. A request through Funnel comes from the
--- internet and carries none of them: it has no identity.
--- @public

local Json = require("cosmic.json")
local Clock = require("cosmic.clock")
local Request = require("cosmic.web.request")
local Response = require("cosmic.web.response")
local Tailscale = require("cosmic.tailscale")
local Types = require("cosmic.web.types")

local record Tailnet
  --- Where [`Identity`] came from.
  enum Source
    --- The daemon's whois of the connection's far end.
    "whois"
    --- The headers of `tailscale serve`, from a loopback peer.
    "serve"
  end

  --- Who a request comes from, as [`Web.tailnet_identity`] answers it.
  record Identity
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
    source: Source
  end

  --- What [`Web.tailnet`] takes; every field is optional.
  record Options
    --- Asks who an address is: a client's [`cosmic.tailscale.Client.whois_result`] by
    --- default, of [`Tailscale.connect`]'s daemon. Given, it is how a
    --- test stands in for the daemon, or a program puts a cache of its
    --- own in front.
    whois?: function(address: string): Tailscale.WhoIsResult
    --- Answer 403 to a request with no identity (true); false lets it
    --- through with none.
    required?: boolean
    --- Read `tailscale serve`'s identity headers from a loopback peer
    --- (false): see the module's description.
    serve?: boolean
    --- How long an answer of the daemon is kept for its address, in
    --- nanoseconds (60 seconds); 0 keeps none. A failure is never kept.
    cache_ns?: integer
  end
end

--- The key a request's identity is kept under.
local IDENTITY: Types.Key<Tailnet.Identity> = Request.key("tailnet.identity")

--- The most addresses a cache holds before it starts again.
local CACHE_ENTRIES <const> = 4096

--- An answer of the daemon, and when it stops counting.
local record Kept
  result: Tailscale.WhoIsResult
  until_ns: integer
end

--- The identity of a whois's answer.
local function of_whois(who: Tailscale.WhoIs): Tailnet.Identity
  return {
    login_name = who.user.login_name,
    display_name = who.user.display_name,
    picture_url = who.user.picture_url,
    node = who.node,
    tagged = who.tagged,
    caps = who.caps,
    source = "whois",
  }
end

--- `text` with RFC 2047's Q encoding of UTF-8 undone, as the daemon
--- writes a name that is not ASCII: one encoded word, or several apart
--- by spaces, which join with nothing between (RFC 2047 6.2). Text that
--- is not wholly such words, or does not decode to UTF-8, is as sent.
local function unq(text: string): string
  if text:sub(1, 2) ~= "=?" then return text end
  local parts: mut {string} = {}
  local rest = text
  while rest ~= "" do
    local inner, after = rest:match("^=%?[Uu][Tt][Ff]%-8%?[Qq]%?([^?]*)%?=%s*(.*)$")
    if inner == nil or after == nil then return text end
    parts[#parts + 1] = inner:gsub("_", " "):gsub("=(%x%x)", function(hex: string): string
      return string.char(assert(tonumber(hex, 16)))
    end)
    rest = after
  end
  local decoded = table.concat(parts)
  if utf8.len(decoded) == nil then return text end
  return decoded
end

--- The identity `tailscale serve`'s headers give, or nil where they name
--- nobody. A capability header that is no JSON object grants nothing,
--- and nor does a member whose value is no array.
local function of_serve(req: Types.Request): Tailnet.Identity?
  local login = req.headers["tailscale-user-login"]
  if login == nil or login == "" then return nil end
  local caps: mut {string: {Json.Value}} = {}
  local header = req.headers["tailscale-app-capabilities"]
  local granted: {string: Json.Value} = {}
  if header ~= nil then
    local decoded, _ = Json.decode_object(header)
    if decoded ~= nil then granted = decoded end
  end
  for name, values in pairs(granted) do
    local list, _ = Json.to_array(values)
    if list ~= nil then caps[name] = list end
  end
  local picture = req.headers["tailscale-user-profile-pic"]
  return {
    login_name = unq(login),
    display_name = unq(req.headers["tailscale-user-name"] or login),
    picture_url = if picture ~= nil and picture ~= "" then picture else nil end,
    tagged = false,
    caps = caps,
    source = "serve",
  }
end

--- Whether `address` is the machine's loopback.
local function loopback(host: string): boolean
  return host == "::1" or host:match("^127%.%d+%.%d+%.%d+$") ~= nil
end

--- `host` with an IPv4 address mapped into IPv6 (`::ffff:100.64.0.2`, as
--- a listener on `::` names an IPv4 peer) written as the IPv4 address,
--- so that it is asked about, kept and tested as one.
local function unmapped(host: string): string
  return host:match("^::[Ff][Ff][Ff][Ff]:(%d+%.%d+%.%d+%.%d+)$") or host
end

--- The whois of [`Tailscale.connect`]'s daemon, made on the first call,
--- so an app that never meets a request asks for no daemon.
local function daemon_whois(): function(address: string): Tailscale.WhoIsResult
  local client: Tailscale.Client? = nil
  return function(address: string): Tailscale.WhoIsResult
    local c = client
    if c == nil then
      local made, why = Tailscale.connect()
      if made == nil then return { kind = "failed", reason = why, status = 0 } end
      client = made
      c = made
    end
    return c:whois_result(address)
  end
end

--- The middleware that finds who each request comes from: see the module's
--- description.
---
---     local app = Web.app{ routes = routes, middleware = { Web.tailnet() } }
function Tailnet.middleware(opts?: Tailnet.Options): Types.Middleware
  local o: Tailnet.Options = opts or {}
  local cache_ns = o.cache_ns or Clock.seconds(60)
  if math.type(cache_ns) ~= "integer" or cache_ns < 0 then
    error("web: tailnet: cache_ns must be an integer of at least 0", 2)
  end
  local whois = o.whois or daemon_whois()
  local required = o.required ~= false
  local serve = o.serve == true
  local cache: mut {string: Kept} = {}
  local held = 0
  local function asked(host: string): Tailscale.WhoIsResult
    local now = Clock.monotonic_ns()
    local kept = cache[host]
    if kept ~= nil and kept.until_ns > now then return kept.result end
    local result = whois(host)
    if cache_ns > 0 and result.kind ~= "failed" then
      if kept == nil then
        if held >= CACHE_ENTRIES then cache, held = {}, 0 end
        held = held + 1
      end
      cache[host] = { result = result, until_ns = Clock.monotonic_ns() + cache_ns }
    end
    return result
  end
  return function(inner: Types.Handler): Types.Handler
    return function(req: Types.Request): Types.Response
      local peer = req.raw.peer
      local identity: Tailnet.Identity? = nil
      if peer ~= nil and peer.kind == "tcp" and peer.host ~= nil then
        local host = unmapped(assert(peer.host))
        if serve and loopback(host) then
          identity = of_serve(req)
        else
          local result = asked(host)
          if result.kind == "failed" then
            local sink = req.app.spec.sink
            if sink ~= nil then sink:line("tailnet: " .. result.reason) end
            return Response.problem(503, "who this request is from cannot be told")
          end
          local who = result.whois
          if who ~= nil then identity = of_whois(who) end
        end
      end
      if identity ~= nil then
        req:set(IDENTITY, identity)
      elseif required then
        return Response.problem(403, "this is served to the tailnet alone")
      end
      return inner(req)
    end
  end
end

--- The identity [`Web.tailnet`] found for `req`, or nil where it found none
--- (or does not run).
function Tailnet.identity(req: Types.Request): Tailnet.Identity?
  return req:get(IDENTITY)
end

--- Middleware that answers 403 to a request whose identity lacks the
--- capability `name` (`example.com/cap/admin`), or that has none: put it
--- inside [`Web.tailnet`], on the app, a mount or a route. A capability is
--- granted in the tailnet policy's `grants`, with an `app` member naming it:
---
---     { "src": ["group:admins"], "dst": ["tag:web"],
---       "app": { "example.com/cap/admin": [{}] } }
function Tailnet.require_cap(name: string): Types.Middleware
  if name == "" then error("web: require_cap takes a capability's name", 2) end
  return function(inner: Types.Handler): Types.Handler
    return function(req: Types.Request): Types.Response
      local identity = req:get(IDENTITY)
      if identity == nil or identity.caps[name] == nil then
        return Response.problem(403, "this needs the capability " .. name)
      end
      return inner(req)
    end
  end
end

return Tailnet
