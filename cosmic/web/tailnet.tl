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
---           local who = assert(Web.who(req).tailnet)
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
--- ([`cosmic.tailscale.Client.whois`]) and keeps the result on the request, where
--- [`Web.who`] reads it and [`Web.require_cap`] tests it. It
--- responds by itself:
---
--- - 403 to a request from no node of the tailnet, unless `required` is
---   false, when the request goes on with no identity;
--- - 503 where the daemon cannot be asked, or refuses the app (a 403 of
---   its own), writing why to the app's sink: an app that cannot tell who
---   asks admits nobody.
---
--- The address asked about is the connection's own, never one a header
--- names: `trusted_proxy` moves [`Web.Request.client`], not this. A
--- whois waits as a task of the server's run, so other connections go
--- on meanwhile, and a reply is kept for `cache_ns` per address. A
--- connection from this node's own address has no identity: any process
--- here can make one, a proxy or a Serve or Funnel forward among them.
---
--- Behind `tailscale serve`, the connection comes from the loopback and
--- the daemon passes who asked in headers instead (`Tailscale-User-Login`,
--- `Tailscale-User-Name`, `Tailscale-User-Profile-Pic`, and
--- `Tailscale-App-Capabilities` where the serve config forwards
--- capabilities), deleting any copy a client sent. `serve = true` reads
--- the user's headers from a loopback peer, and only there, but no
--- capabilities, since this cannot tell whether the config forwards
--- them, and a daemon deletes a client's copy only where it does. Any
--- local process can connect to the loopback and send them, so behind a
--- loopback port turn it on only where the machine's users are trusted.
--- [`Web.serve`]'s `tailnet = { via = "serve" }` is the safer way: it
--- listens at a unix socket of a private directory, which only the
--- daemon and the program's own user can reach, and files the daemon's
--- Serve configuration itself, taking it down when the server stops.
--- There the headers are read with or without `serve`, with the
--- capabilities its `caps` names, once the daemon is seen to keep them.
--- Where a Serve configuration filed outside the app passes requests to
--- a unix socket the app listens at (a Tailscale Service's, say),
--- `socket` names that socket, and its headers are read there, with no
--- capabilities, as on the loopback. Any process that can connect to it
--- can send them: keep it where only the daemon and the program's own
--- user reach it.
--- A request whose `X-Forwarded-For` (the last entry, which the daemon
--- sets) is this node's own address has no identity, as a connection
--- from it has none: the daemon names the node's owner then, though any
--- process here can ask by the node's name. Where the daemon cannot be
--- asked about that address the response is 503, as above. On the
--- loopback this guards only against Serve's own forwards, since any
--- local process can write the header there.
--- `via = "funnel"` opens the site to the internet as well. A request
--- through Funnel carries none of the headers and has no identity;
--- [`Web.tailnet_funnel`] tells it apart, so a public app can set
--- `required = false` and still know who on the tailnet asks.
--- @public

local Json = require("cosmic.json")
local type Failure = require("cosmic.failure")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Identities = require("cosmic.web.identity")
local Request = require("cosmic.web.request")
local Response = require("cosmic.web.response")
local Tailscale = require("cosmic.tailscale")
local type Tls = require("cosmic.tls")
local Types = require("cosmic.web.types")

--- Where [`Tailnet.serving`] serves an app, and what it presents.
local record Reached
  --- Each of the node's tailnet addresses, at the port; or, through
  --- the daemon's Serve, the one unix socket it passes requests to.
  listeners: {Net.Address}
  --- The node's certificate, from its daemon, kept current; nil
  --- through Serve, where the daemon presents it.
  certs?: Tls.Certs
  --- Through Serve: files the daemon's configuration, once the
  --- listener is open. The result takes it down when closed.
  put_up?: function(): Tailscale.Serving?, string
  --- Through Serve: removes the socket and its directory.
  cleanup?: function()
  --- Through Serve: the socket's path.
  socket?: string
  --- Through Serve: the capabilities the daemon was told to pass on.
  caps?: {string}
end

local record Tailnet
  --- Where [`serving`] serves an app, and what it presents.
  type Reached = Reached
  --- Where [`Identity`] came from: see [`cosmic.web.identity.TailnetSource`].
  type Source = Identities.TailnetSource
  --- Who a request comes from: see [`cosmic.web.identity.Tailnet`].
  type Identity = Identities.Tailnet

  --- What [`Web.tailnet`] takes; every field is optional.
  record Options
    --- Asks who an address is: a client's [`cosmic.tailscale.Client.whois`] by
    --- default, of [`Tailscale.connect`]'s daemon. Given, it is how a
    --- test stands in for the daemon, or a program puts a cache of its
    --- own in front.
    whois?: function(address: string): (Tailscale.WhoIs | false) | (nil, Failure)
    --- Respond 403 to a request with no identity (true); false lets it
    --- through with none.
    required?: boolean
    --- Read `tailscale serve`'s identity headers from a loopback peer
    --- (false): see the module's description.
    serve?: boolean
    --- The path of a unix socket a Serve configuration filed outside the
    --- app passes requests to: `tailscale serve`'s identity headers are
    --- read from a request that comes in at it, as from a loopback peer
    --- with `serve`. It is the path exactly as the listener names it. See
    --- the module's description.
    socket?: string
    --- How long a reply of the daemon is kept for its address, in
    --- nanoseconds (60 seconds); 0 keeps none. A failure is never kept.
    cache_ns?: integer
  end
end

--- The key a request's identity is kept under.
local IDENTITY: Types.Key<Tailnet.Identity> = Identities.TAILNET

--- The key that marks a request Funnel brought from the internet.
local FUNNEL: Types.Key<boolean> = Request.key("tailnet.funnel")

--- The most addresses a cache holds. A full one drops the replies that
--- stopped counting, and starts again where that frees less than a
--- quarter of it, so that it is not swept on every reply.
local CACHE_ENTRIES <const> = 4096

--- A reply of the daemon, and when it stops counting.
local record Kept
  who: Tailscale.WhoIs | false
  until_ns: integer
end

--- The replies kept for some addresses, and how many.
local record Cache
  mut entries: mut {string: Kept}
  mut held: integer
end

--- `cache` with room for one more address at `now`.
local function room(cache: Cache, now: integer)
  if cache.held < CACHE_ENTRIES then return end
  local live: mut {string: Kept} = {}
  local held = 0
  for host, kept in pairs(cache.entries) do
    if kept.until_ns > now then
      live[host] = kept
      held = held + 1
    end
  end
  if held > CACHE_ENTRIES * 3 // 4 then live, held = {}, 0 end
  cache.entries, cache.held = live, held
end

--- The identity a whois reply names.
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
--- nobody, with the capabilities of the header named in `forwarded`
--- alone: those [`Web.serve`] told the daemon to pass on, and saw it
--- keep. A daemon deletes a client's copy of the header only where it
--- forwards capabilities, so any other name is the client's. A
--- capability header that is no JSON object grants nothing, and nor
--- does a member whose value is no array.
local function of_serve(req: Types.Request, forwarded: {string}): Tailnet.Identity?
  local login = req.headers["tailscale-user-login"]
  if login == nil or login == "" then return nil end
  local caps: mut {string: {Json.Value}} = {}
  local header = req.headers["tailscale-app-capabilities"]
  local granted: {string: Json.Value} = {}
  if header ~= nil then
    local decoded, _ = Json.decode_object(header)
    if decoded ~= nil then granted = decoded end
  end
  for _, name in ipairs(forwarded) do
    local list, _ = Json.to_array(granted[name])
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

--- `host` with an IPv4 address mapped into IPv6 (`::ffff:100.64.0.2`, as
--- a listener on `::` names an IPv4 peer) written as the IPv4 address,
--- so that it is asked about, kept and tested as one.
local function unmapped(host: string): string
  return host:match("^::[Ff][Ff][Ff][Ff]:(%d+%.%d+%.%d+%.%d+)$") or host
end

--- The whois of [`Tailscale.connect`]'s daemon, made on the first call,
--- so an app that never meets a request asks for no daemon.
local function daemon_whois(): function(address: string): (Tailscale.WhoIs | false) | (nil, Failure)
  local client: Tailscale.Client? = nil
  return function(address: string): (Tailscale.WhoIs | false) | (nil, Failure)
    local c = client
    if c == nil then
      local made, why = Tailscale.connect()
      if made == nil then return nil, why end
      client = made
      c = made
    end
    return c:whois(address)
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
  local named = o.socket
  if named ~= nil and (type(named) ~= "string" or named == "") then
    error("web: tailnet: socket must be a socket's path", 2)
  end
  -- Peers and strangers apart, so that addresses off the tailnet,
  -- which anyone has many of, never push a peer's reply out.
  local peers: Cache = { entries = {}, held = 0 }
  local strangers: Cache = { entries = {}, held = 0 }
  local function asked(host: string): (Tailscale.WhoIs | false) | (nil, Failure)
    local now = Clock.monotonic_ns()
    local kept = peers.entries[host] or strangers.entries[host]
    if kept ~= nil and kept.until_ns > now then return kept.who end
    local who, why = whois(host)
    if who == nil then return nil, why end
    if cache_ns > 0 then
      local into = if who ~= false then peers else strangers end
      local other = if who ~= false then strangers else peers end
      if other.entries[host] ~= nil then
        other.entries[host] = nil
        other.held = other.held - 1
      end
      local later = Clock.monotonic_ns()
      if into.entries[host] == nil then
        room(into, later)
        into.held = into.held + 1
      end
      into.entries[host] = { who = who, until_ns = later + cache_ns }
    end
    return who
  end
  -- The 503 for a request whose sender the daemon could not be asked
  -- about, `why` saying why in the app's sink.
  local function unasked(req: Types.Request, why: Failure): Types.Response
    local sink = req.app.spec.sink
    if sink ~= nil then sink:line("tailnet: " .. tostring(why)) end
    return Response.problem(503, "who this request is from cannot be told")
  end
  -- The address the daemon's Serve says the request came from, in the
  -- X-Forwarded-For it sets over any a client sent (its last entry), or
  -- nil where there is none. The daemon names this node's owner in its
  -- headers for a request from this node's own address, though any
  -- process here can make one (by the node's own name).
  local function forwarded_from(req: Types.Request): string?
    local list = req.headers["x-forwarded-for"]
    if list == nil then return nil end
    local last = assert(assert(list:match("([^,]*)$")):match("^%s*(.-)%s*$"))
    if last == "" then return nil end
    return unmapped(last)
  end
  -- The serve identity, kept only where the forwarded address is a
  -- peer's other than this node's; nil and a Failure where the daemon
  -- could not be asked.
  local function vouched(req: Types.Request, identity: Tailnet.Identity?): (Tailnet.Identity?, Failure?)
    if identity == nil then return nil, nil end
    local host = forwarded_from(req)
    if host == nil then return identity, nil end
    local who, why = asked(host)
    if who == nil then return nil, why end
    if who == false or who.own then return nil, nil end
    return identity, nil
  end
  return function(inner: Types.Handler): Types.Handler
    return function(req: Types.Request): Types.Response
      local peer = req.raw.peer
      local identity: Tailnet.Identity? = nil
      local funneled = false
      local at = req.raw.listener
      local own = req.app.serve_socket
      local filed = at ~= nil and at.kind == "unix" and own ~= nil and at.path == own
      if filed or (at ~= nil and at.kind == "unix" and named ~= nil and at.path == named) then
        -- The socket Web.serve opened for the daemon's Serve, in a
        -- directory only the daemon and this user can reach, or the one
        -- `socket` names: the daemon's headers say who asked. Only the
        -- first is known to forward capabilities.
        funneled = req.headers["tailscale-funnel-request"] == "?1"
        if not funneled then
          identity = of_serve(req, if filed then req.app.serve_caps or {} else {} end)
        end
        local kept, why = vouched(req, identity)
        if why ~= nil then return unasked(req, why) end
        identity = kept
      elseif peer == nil or peer.kind == "unix" then
        -- Any other unix socket: nobody this middleware can name.
        identity = nil
      elseif peer.kind == "tcp" and peer.host ~= nil then
        local host = unmapped(assert(peer.host))
        if serve and Net.is_loopback(host) then
          -- No capabilities: a daemon passes a client's own header on
          -- unless the serve config forwards them, which is not known here.
          funneled = req.headers["tailscale-funnel-request"] == "?1"
          if not funneled then identity = of_serve(req, {}) end
          local kept, why = vouched(req, identity)
          if why ~= nil then return unasked(req, why) end
          identity = kept
        else
          local who, why = asked(host)
          if who == nil then return unasked(req, assert(why)) end
          -- This node's own address is any process here, not its owner.
          if who ~= false and not who.own then identity = of_whois(who) end
        end
      end
      if funneled then req:set(FUNNEL, true) end
      if identity ~= nil then
        req:set(IDENTITY, identity)
      elseif required then
        return Response.problem(403, "this is served to the tailnet alone")
      end
      return inner(req)
    end
  end
end

--- Whether [`Web.tailnet`] found that Funnel brought `req` from the
--- internet, as the daemon's `Tailscale-Funnel-Request` header says
--- wherever its other headers are read. Such a request has no identity.
function Tailnet.funnel(req: Types.Request): boolean
  return req:get(FUNNEL) == true
end

--- Middleware that responds 403 to a request whose identity lacks the
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

--- Where an app served through the daemon's Serve listens: a unix
--- socket of a fresh private directory (mode 0700, so the daemon, as
--- root, and the program's own user alone can reach it), which the
--- daemon's site at `port` of `domain` (the node's first name by
--- default) passes every path to.
local function through_serve(client: Tailscale.Client, o: Types.TailnetServe, via: Types.TailnetVia,
                             port: integer, domain?: string): Reached?, string
  local dir, why = Fs.mkdtemp("cosmic-serve-")
  if dir == nil then return nil, "web: tailnet: " .. tostring(why) end
  local socket = dir .. "/s"
  -- The most a socket's path holds on macOS, less its NUL; Linux holds 107.
  if #socket > 103 then
    local _, _ = Fs.remove_tree(dir)
    return nil, "web: tailnet: the socket's path " .. socket .. " is longer than a socket's path may be: set a shorter TMPDIR"
  end
  -- A copy, so that a change to the caller's list after the daemon
  -- kept it trusts nothing more.
  local caps: {string}? = nil
  local asked = o.caps
  if asked ~= nil then caps = table.move(asked, 1, #asked, 1, {}) end
  local spec: Tailscale.ServeSpec = {
    domain = domain,
    sites = { {
      port = port,
      funnel = via == "funnel",
      handlers = { ["/"] = { proxy = "unix:" .. socket, accept_caps = caps } },
    } },
  }
  return {
    listeners = { Net.unix(socket) },
    certs = nil,
    put_up = function(): Tailscale.Serving?, string
      local served, refused = client:serve(spec)
      if served == nil then return nil, "web: tailnet: " .. tostring(refused) end
      return served, ""
    end,
    cleanup = function()
      local _, _ = Fs.remove_tree(dir)
    end,
    socket = socket,
    caps = caps,
  }, ""
end

--- Where [`Web.serve`]'s `tailnet` listens, and the certificates it
--- presents: each of the node's tailnet addresses at `o.port` (443), and
--- the certificate of `o.domain`, the node's first name by default,
--- from the daemon of `o.client`, [`Tailscale.connect`]'s by default.
--- Nil and why where the daemon cannot be asked, the node is not
--- running, or it has no address or no name to get a certificate for.
--- With `o.via` "serve" or "funnel", it listens at a private unix
--- socket instead, and the daemon serves the node's name, passing each
--- request on: see [`Types.TailnetVia`].
function Tailnet.serving(o: Types.TailnetServe): Reached?, string
  local via: Types.TailnetVia = o.via or "listen"
  -- Read as text: a caller the checker does not read may pass any value, and no narrowing of it is taken as proved.
  local via_text = tostring(via)
  if via_text ~= "listen" and via_text ~= "serve" and via_text ~= "funnel" then
    error("web: tailnet.via must be listen, serve or funnel", 3)
  end
  local port = o.port or 443
  local least = if via == "listen" then 0 else 1 end
  if math.type(port) ~= "integer" or port < least or port > 65535 then
    error("web: tailnet.port must be from " .. tostring(least) .. " to 65535", 3)
  end
  if o.caps ~= nil and via == "listen" then
    error("web: tailnet.caps needs via serve or funnel", 3)
  end
  if via == "funnel" and port ~= 443 and port ~= 8443 and port ~= 10000 then
    error("web: tailnet: Funnel opens ports 443, 8443 and 10000 only", 3)
  end
  local client = o.client
  if client == nil then
    local made, why = Tailscale.connect()
    if made == nil then return nil, "web: tailnet: " .. tostring(why) end
    client = made
  end
  local status, why = client:status()
  if status == nil then return nil, "web: tailnet: " .. tostring(why) end
  if status.backend_state ~= "Running" then
    return nil, "web: tailnet: the node is not running (" .. status.backend_state .. ")"
  end
  local domain = o.domain or status.cert_domains[1]
  if via ~= "listen" then return through_serve(client, o, via, port, domain) end
  if domain == nil then
    return nil, "web: tailnet: the node has no name to get a certificate for: enable HTTPS in the tailnet's DNS settings"
  end
  local listeners: mut {Net.Address} = {}
  -- TODO: leave out an address the host cannot listen at (an IPv6 one
  -- where the kernel has IPv6 off) once Net.ServeSpec can take a
  -- listener that may fail; today one such address fails the serve.
  for _, address in ipairs(status.addresses) do
    listeners[#listeners + 1] = Net.tcp(address, port)
  end
  if #listeners == 0 then return nil, "web: tailnet: the node has no tailnet address" end
  return { listeners = listeners, certs = client:certs(domain) }, ""
end

return Tailnet
