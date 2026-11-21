--- The machine's own Tailscale node, through tailscaled's LocalAPI: who
--- a tailnet address belongs to, the node's status and preferences, a
--- TLS certificate for its `ts.net` name, a ping across the tailnet,
--- the daemon's stream of events, and sites and ports put up through
--- Serve and Funnel for as long as the program runs ([`Client.serve`]).
---
---     local Tailscale = require("cosmic.tailscale")
---     local ts = assert(Tailscale.connect())
---     local who = assert(ts:whois("100.101.102.103"))
---     print(who.user.login_name, who.node.name, who.tagged)
---     local status = assert(ts:status())
---     print(status.self.dns_name, #status.peers)
---
--- [`Tailscale.connect`] finds the daemon but keeps no connection open:
--- each call is one HTTP request to it, so a daemon that is down or
--- restarts fails that call, never the client. Every answer is checked against the
--- shape this module declares and handed back as a record with
--- snake_case fields, so a reply the daemon changed fails with the path
--- of the field that does not fit rather than as a nil read far away.
--- [`Client.get`] and [`Client.request`] reach any other endpoint, as
--- bytes.
---
--- A call waits for the daemon as [`cosmic.net`] waits: in a task of
--- [`Poll.run`], as a server's handler runs, the other tasks go on
--- meanwhile, so a whois per request stalls no other connection.
--- [`Client.watch`] alone holds the thread for each event, as
--- [`cosmic.http`] does: run it in a process of its own, or in a program
--- that waits for nothing else.
---
--- What a call may do is the daemon's choice, not this module's. On
--- Linux the socket is open to every local user, and a request that
--- changes something, or asks for a certificate, needs root or the
--- daemon's operator (`tailscale set --operator=$USER`); the daemon
--- answers 403 otherwise, and the call fails with its message.

local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Json = require("cosmic.json")
local Message = require("cosmic.http.message")
local Net = require("cosmic.net")
local Shape = require("cosmic.shape")
local Stream = require("cosmic.stream")
local Tls = require("cosmic.tls")
local Url = require("cosmic.url")
local sys = require("cosmic.sys")

--- The host every request names. Without a token the daemon refuses any
--- other, so that a web page cannot reach it through a DNS name that
--- points at the loopback.
local HOST <const> = "local-tailscaled.sock"

--- The capability version the client says it speaks (`Tailscale-Cap`),
--- as the `tailscale` command sends its own. The daemon reads it to keep
--- old clients working; this module reads no field whose meaning moved.
local CAPABILITY <const> = "130"

-- The records below are the daemon's JSON as it writes it, Go's field
-- names and all, which [`Shape.record_of`] checks a reply against. The
-- public records of [`Tailscale`] are built from them.

local record WireUser
  ID: integer
  LoginName: string
  DisplayName: string
  ProfilePicURL?: string
end

local record WireHostinfo
  Hostname?: string
  OS?: string
end

local record WireNode
  ID: integer
  StableID: string
  Name: string
  User: integer
  Addresses?: {string}
  Tags?: {string}
  Hostinfo?: WireHostinfo
  Online?: boolean
  KeyExpiry?: string
end

local record WireWhoIs
  Node: WireNode
  UserProfile: WireUser
  CapMap: any
end

local record WirePeer
  ID: string
  HostName: string
  DNSName: string
  OS: string
  UserID: integer
  TailscaleIPs?: {string}
  Tags?: {string}
  Online: boolean
  Active: boolean
  ExitNode: boolean
  ExitNodeOption: boolean
  Relay: string
  CurAddr: string
  LastSeen?: string
  KeyExpiry?: string
end

local record WireTailnet
  Name: string
  MagicDNSSuffix: string
  MagicDNSEnabled: boolean
end

local record WireStatus
  Version: string
  BackendState: string
  AuthURL?: string
  TailscaleIPs?: {string}
  Self?: WirePeer
  Health?: {string}
  MagicDNSSuffix: string
  CurrentTailnet?: WireTailnet
  CertDomains?: {string}
  Peer?: {string: WirePeer}
  User?: {string: WireUser}
end

local record WirePrefs
  ControlURL: string
  RouteAll: boolean
  ExitNodeID: string
  CorpDNS: boolean
  RunSSH: boolean
  WantRunning: boolean
  ShieldsUp: boolean
  Hostname: string
  AdvertiseTags?: {string}
  AdvertiseRoutes?: {string}
  OperatorUser?: string
end

local record WirePing
  Err?: string
  LatencySeconds?: number
  Endpoint?: string
  PeerRelay?: string
  DERPRegionID?: integer
  DERPRegionCode?: string
end

local record WireNotify
  Version?: string
  ErrMessage?: string
  State?: integer
  BrowseToURL?: string
  LoginFinished: any
  SessionID?: string
end

local WHOIS <const> = Shape.record_of("WireWhoIs")
local STATUS <const> = Shape.record_of("WireStatus")
local PREFS <const> = Shape.record_of("WirePrefs")
local PING <const> = Shape.record_of("WirePing")
local NOTIFY <const> = Shape.record_of("WireNotify")

--- What a call of the LocalAPI came to: the body of a 200, or why not.
local record Answer
  body?: string
  reason: string
  --- The reply's status; 0 where there was none.
  status: integer
end

--- Where the daemon listens, and what proves the caller may talk to it.
local record Endpoint
  --- The socket file, or the port of 127.0.0.1.
  via: Net.Address
  --- The URL a request's path follows.
  url: string
  --- The same-user proof a port asks for.
  token?: string
end

--- A user of the tailnet, as the control server names them.
local record User
  --- The user's numeric id, unique in the tailnet.
  id: integer
  --- The name a person logs in as: `will@example.com`, or
  --- `tagged-devices` for the owner of every tagged node.
  login_name: string
  --- The name to show a person.
  display_name: string
  --- Where their picture is, when they have one.
  picture_url?: string
end

--- A node of the tailnet, as the network map holds it.
local record Node
  --- The node's numeric id.
  id: integer
  --- The id the Tailscale API names the node by (`n...CNTRL`).
  stable_id: string
  --- Its MagicDNS name, fully qualified, with no final dot:
  --- `laptop.tail1234.ts.net`.
  name: string
  --- Its host name, as the machine reports it; "" where unknown.
  host_name: string
  --- Its operating system, as the machine reports it; "" where unknown.
  os: string
  --- The id of the user that owns it ([`User.id`]).
  user_id: integer
  --- Its tailnet addresses, bare (`100.101.102.103`, `fd7a:115c:a1e0::1`).
  addresses: {string}
  --- Its ACL tags (`tag:server`); none for a node a person owns.
  tags: {string}
end

--- What [`Client.whois`] answers: the node an address belongs to, the
--- user it acts for, and the capabilities the tailnet policy grants it
--- on this node.
local record WhoIs
  --- The node the address belongs to.
  node: Node
  --- The owner of `node`; for a tagged node, the tailnet's
  --- `tagged-devices` user, whom no person logs in as.
  user: User
  --- Whether `node` is tagged, so that `user` is no person.
  tagged: boolean
  --- The capabilities the policy's grants give the peer here, each
  --- name (`example.com/cap/admin`) to the JSON values the grants
  --- attach, one a grant, decoded. A name is present, with an empty
  --- list, when a grant names it with no value.
  caps: {string: {Json.Value}}
end

--- Which way [`Client.whois_result`] came out.
local enum WhoIsKind
  --- The address is a peer's, or this node's own.
  "found"
  --- The daemon knows no node at the address: it is not on the tailnet.
  "not_a_peer"
  --- The daemon could not be asked, or its answer could not be read.
  "failed"
end

--- What [`Client.whois_result`] answers.
local record WhoIsResult
  --- Which way it came out.
  kind: WhoIsKind
  --- Present only for "found".
  whois?: WhoIs
  --- Empty for "found"; otherwise why.
  reason: string
  --- The daemon's HTTP status: 200 for "found", 404 for "not_a_peer",
  --- and for "failed" the status that refused the call (403 for a
  --- caller the daemon will not answer), or 0 where none came back.
  status: integer
end

--- A peer of this node, or the node itself, as [`Client.status`] lists it.
local record Peer
  --- The node's stable id.
  id: string
  --- Its host name, as the machine reports it.
  host_name: string
  --- Its MagicDNS name, with no final dot.
  dns_name: string
  --- Its operating system, as the machine reports it.
  os: string
  --- The id of the user that owns it ([`User.id`]).
  user_id: integer
  --- Its tailnet addresses.
  addresses: {string}
  --- Its ACL tags (`tag:server`).
  tags: {string}
  --- Whether the node is connected to the control server.
  online: boolean
  --- Whether traffic has passed with it lately.
  active: boolean
  --- Whether this node uses it as its exit node.
  exit_node: boolean
  --- Whether it offers to be an exit node, and may.
  exit_node_option: boolean
  --- The DERP region that relays to it, when one does; "" where none.
  relay: string
  --- The address traffic goes to directly, when it does; "" where not.
  direct: string
  --- When it was last seen by the control server, RFC 3339, while offline.
  last_seen?: string
  --- When its key expires, RFC 3339; nil where it never does.
  key_expiry?: string
end

--- What [`Client.status`] answers.
local record Status
  --- The daemon's version.
  version: string
  --- "Running", "Stopped", "NeedsLogin", "NeedsMachineAuth",
  --- "Starting" or "NoState": the daemon's own word, passed on.
  backend_state: string
  --- Where a person goes to log the node in, while it needs one.
  auth_url?: string
  --- This node's own entry; nil before it has logged in.
  self?: Peer
  --- This node's tailnet addresses.
  addresses: {string}
  --- What the daemon finds wrong, a sentence each.
  health: {string}
  --- The tailnet's name, as the admin console shows it; "" before login.
  tailnet: string
  --- The suffix of every MagicDNS name: `tail1234.ts.net`.
  magic_dns_suffix: string
  --- Whether MagicDNS answers on this node.
  magic_dns: boolean
  --- The names [`Client.cert`] can get a certificate for.
  cert_domains: {string}
  --- Every peer, by `dns_name` and then `id`.
  peers: {Peer}
  --- The users of `self` and every peer, by [`User.id`].
  users: {integer: User}
end

--- A subset of the node's preferences, what `tailscale set` changes.
local record Prefs
  --- The control server it logs in to.
  control_url: string
  --- Whether it takes the subnet routes peers offer (`--accept-routes`).
  accept_routes: boolean
  --- Whether it takes the tailnet's DNS settings (`--accept-dns`).
  accept_dns: boolean
  --- The stable id of the exit node it uses; "" for none.
  exit_node_id: string
  --- Whether it runs Tailscale SSH (`--ssh`).
  ssh: boolean
  --- Whether the daemon means to be connected (`tailscale up`/`down`).
  want_running: boolean
  --- Whether it refuses every incoming connection (`--shields-up`).
  shields_up: boolean
  --- The host name it asks for; "" for the machine's own.
  host_name: string
  --- The ACL tags it asks to be given (`--advertise-tags`).
  advertise_tags: {string}
  --- The subnet routes it offers (`--advertise-routes`).
  advertise_routes: {string}
  --- The local user the daemon lets act as root; "" for none.
  operator: string
end

--- A certificate and its key, PEM, as [`Client.cert`] answers them.
local record CertPair
  --- The leaf and the chain to the CA, PEM, leaf first.
  cert: string
  --- The private key, PEM.
  key: string
end

--- Which path [`Client.ping`] sends.
local enum PingKind
  --- Through the WireGuard tunnel, as a peer's traffic goes (the default).
  "disco"
  --- An ICMP echo inside the tunnel, which the peer's own stack answers.
  "ICMP"
  --- A TSMP ping, which the peer's Tailscale answers without its stack.
  "TSMP"
  --- Through the peer's PeerAPI, which proves its daemon serves.
  "peerapi"
end

--- What [`Client.ping`] answers when the peer replied.
local record Ping
  --- The round trip, in nanoseconds.
  latency_ns: integer
  --- The address the reply came from, when it came directly.
  endpoint?: string
  --- The DERP region that relayed it, when one did.
  derp_region?: string
  --- The peer relay that carried it, when one did.
  peer_relay?: string
end

--- What [`Client.cert`] takes; every field is optional.
local record CertOptions
  --- How long the call may take, in nanoseconds: 5 minutes by
  --- default, since the first certificate for a name waits on the CA.
  timeout_ns?: integer
  --- How long the certificate must still be valid, in nanoseconds:
  --- one the daemon holds that expires sooner is renewed first.
  min_validity_ns?: integer
end

--- The daemon's state, as [`Notify.state`] names it.
local enum State
  "NoState"
  "InUseOtherUser"
  "NeedsLogin"
  "NeedsMachineAuth"
  "Stopped"
  "Starting"
  "Running"
end

--- One event of [`Client.watch`]. Each field is present only when the
--- event carries it; `json` is the whole event, for what else it holds.
local record Notify
  --- The daemon's version.
  version?: string
  --- The daemon's new state.
  state?: State
  --- An error the daemon reports.
  error?: string
  --- Where a person goes to log the node in.
  browse_url?: string
  --- Whether a login just finished.
  login_finished: boolean
  --- The stream's own name, in its first event: what a foreground
  --- serve configuration is filed under (see [`Client.serve`]).
  session?: string
  --- The event as the daemon sent it, one line of JSON.
  json: string
end

--- What [`Client.watch`] asks the daemon to send.
local record WatchOptions
  --- Send the daemon's state, and the login URL when there is one,
  --- first (true by default).
  initial_state?: boolean
  --- Send the node's status first (in the event's `InitialStatus`,
  --- which `json` holds).
  initial_status?: boolean
  --- Send changes to the network map, peers and engine as they happen.
  engine?: boolean
end

--- What one path of a [`ServeSite`] answers with: exactly one field.
local record ServeHandler
  --- The URL of a local server the daemon passes requests to, with
  --- the `Tailscale-User-*` headers that name the tailnet user:
  --- `http://127.0.0.1:8080`, or `https+insecure://...` to skip
  --- checking its certificate.
  proxy?: string
  --- A body the daemon answers with itself.
  text?: string
  --- A file or directory of the daemon's machine it serves.
  path?: string
end

--- A web server the daemon runs on a port of the node's tailnet name.
local record ServeSite
  --- The port: 443 by default, 80 where `http` is set.
  port?: integer
  --- Plain HTTP rather than HTTPS with the node's `ts.net` certificate.
  http?: boolean
  --- Open the site to the internet as well (Funnel): ports 443, 8443
  --- and 10000 only, and only where the tailnet's policy lets the
  --- node.
  funnel?: boolean
  --- What each path answers, by the path it is mounted at (`/`,
  --- `/api`); the longest that a request's path starts with wins.
  handlers: {string: ServeHandler}
end

--- A TCP port of the node the daemon passes on, bytes as they come.
local record ServeForward
  --- The node's port the connections come to.
  port: integer
  --- Where the connections go: `127.0.0.1:5432`.
  to: string
  --- End TLS with the node's `ts.net` certificate before passing the
  --- bytes on.
  terminate_tls?: boolean
  --- Open the port to the internet as well, as [`ServeSite.funnel`].
  funnel?: boolean
end

--- What [`Client.serve`] puts up. Two entries may not share a port.
local record ServeSpec
  --- The web servers, one a port.
  sites?: {ServeSite}
  --- The TCP ports passed on, one a port.
  forwards?: {ServeForward}
  --- The name the sites answer to: the node's first certificate name
  --- by default, else its MagicDNS name.
  domain?: string
end

local DEFAULT_TIMEOUT_NS <const> = 10 * 1000000000
local CERT_TIMEOUT_NS <const> = 300 * 1000000000

--- `text`, or nil where it is nil or empty.
local function nonempty(text: string?): string?
  if text == nil or text == "" then return nil end
  return text
end

--- `list`, or an empty list where it is nil.
local function listed(list: {string}?): {string}
  if list == nil then return {} end
  return list
end

--- A DNS name without its final dot.
local function undotted(name: string): string
  return (name:gsub("%.$", ""))
end

--- `prefixes` (`100.101.102.103/32`) as bare addresses.
local function bare(prefixes: {string}?): {string}
  local out: mut {string} = {}
  for _, prefix in ipairs(listed(prefixes)) do
    out[#out + 1] = prefix:match("^([^/]+)") or prefix
  end
  return out
end

local function user_of(wire: WireUser): User
  return {
    id = wire.ID,
    login_name = wire.LoginName,
    display_name = wire.DisplayName,
    picture_url = nonempty(wire.ProfilePicURL),
  }
end

local function node_of(wire: WireNode): Node
  local info = wire.Hostinfo
  return {
    id = wire.ID,
    stable_id = wire.StableID,
    name = undotted(wire.Name),
    host_name = (info and info.Hostname) or "",
    os = (info and info.OS) or "",
    user_id = wire.User,
    addresses = bare(wire.Addresses),
    tags = listed(wire.Tags),
  }
end

local function whois_of(wire: WireWhoIs): WhoIs
  local caps: mut {string: {Json.Value}} = {}
  local granted, _ = Json.to_object(wire.CapMap)
  for name, values in pairs(granted or {}) do
    -- A grant with no value is Go's nil slice, which the daemon writes
    -- as null: the name is granted all the same.
    local list, _ = Json.to_array(values)
    caps[name] = list or {}
  end
  local node = node_of(wire.Node)
  return { node = node, user = user_of(wire.UserProfile), tagged = #node.tags > 0, caps = caps }
end

--- Go's zero time, which the daemon writes for a time it does not know.
local ZERO_TIME <const> = "0001-01-01T00:00:00Z"

local function peer_of(wire: WirePeer): Peer
  return {
    id = wire.ID,
    host_name = wire.HostName,
    dns_name = undotted(wire.DNSName),
    os = wire.OS,
    user_id = wire.UserID,
    addresses = listed(wire.TailscaleIPs),
    tags = listed(wire.Tags),
    online = wire.Online,
    active = wire.Active,
    exit_node = wire.ExitNode,
    exit_node_option = wire.ExitNodeOption,
    relay = wire.Relay,
    direct = wire.CurAddr,
    last_seen = if wire.LastSeen == ZERO_TIME then nil else nonempty(wire.LastSeen) end,
    key_expiry = nonempty(wire.KeyExpiry),
  }
end

local function status_of(wire: WireStatus): Status
  local peers: mut {Peer} = {}
  for _, peer in pairs(wire.Peer or {}) do peers[#peers + 1] = peer_of(peer) end
  table.sort(peers, function(a: Peer, b: Peer): boolean
    if a.dns_name ~= b.dns_name then return a.dns_name < b.dns_name end
    return a.id < b.id
  end)
  local users: mut {integer: User} = {}
  for _, user in pairs(wire.User or {}) do users[user.ID] = user_of(user) end
  local tailnet = wire.CurrentTailnet
  local self_wire = wire.Self
  local self_peer = if self_wire ~= nil then peer_of(self_wire) else nil end
  return {
    version = wire.Version,
    backend_state = wire.BackendState,
    auth_url = nonempty(wire.AuthURL),
    self = self_peer,
    addresses = listed(wire.TailscaleIPs),
    health = listed(wire.Health),
    tailnet = if tailnet ~= nil then tailnet.Name else "" end,
    magic_dns_suffix = wire.MagicDNSSuffix,
    magic_dns = tailnet ~= nil and tailnet.MagicDNSEnabled,
    cert_domains = listed(wire.CertDomains),
    peers = peers,
    users = users,
  }
end

local function prefs_of(wire: WirePrefs): Prefs
  return {
    control_url = wire.ControlURL,
    accept_routes = wire.RouteAll,
    accept_dns = wire.CorpDNS,
    exit_node_id = wire.ExitNodeID,
    ssh = wire.RunSSH,
    want_running = wire.WantRunning,
    shields_up = wire.ShieldsUp,
    host_name = wire.Hostname,
    advertise_tags = listed(wire.AdvertiseTags),
    advertise_routes = listed(wire.AdvertiseRoutes),
    operator = wire.OperatorUser or "",
  }
end

--- The key and the chain of a `type=pair` reply: the key's PEM block
--- first, then the certificates', as the daemon writes them.
local function pair_of(text: string): CertPair?, string
  local key: string? = nil
  local certs: mut {string} = {}
  for block in text:gmatch("%-%-%-%-%-BEGIN [^\n]-%-%-%-%-%-.-%-%-%-%-%-END [^\n]-%-%-%-%-%-") do
    local label = block:match("^%-%-%-%-%-BEGIN ([^\n]-)%-%-%-%-%-")
    if label == "CERTIFICATE" then
      certs[#certs + 1] = block .. "\n"
    elseif label ~= nil and label:find("PRIVATE KEY", 1, true) ~= nil and key == nil then
      key = block .. "\n"
    end
  end
  if key == nil then return nil, "tailscale: cert: the reply holds no private key" end
  if #certs == 0 then return nil, "tailscale: cert: the reply holds no certificate" end
  return { cert = table.concat(certs), key = key }, ""
end

--- The daemon's states, by the number it sends (`ipn.State`).
local STATES <const>: {integer: State} = {
  [0] = "NoState",
  [1] = "InUseOtherUser",
  [2] = "NeedsLogin",
  [3] = "NeedsMachineAuth",
  [4] = "Stopped",
  [5] = "Starting",
  [6] = "Running",
}

local function notify_of(line: string): Notify?, string
  local wire, bad = NOTIFY:decode_into(line)
  if wire == nil then return nil, "tailscale: watch-ipn-bus: " .. bad end
  local state = wire.State
  return {
    version = nonempty(wire.Version),
    state = if state ~= nil then STATES[state] else nil end,
    error = nonempty(wire.ErrMessage),
    browse_url = nonempty(wire.BrowseToURL),
    login_finished = wire.LoginFinished ~= nil,
    session = nonempty(wire.SessionID),
    json = line,
  }, ""
end

-- TODO: read the IPN bus over cosmic.net, as `sent` does, once a chunked
-- body can be read a chunk at a time from cosmic.http.message, so that
-- `watch` waits as a task does.

--- The options of `watch`'s request to `endpoint`. `timeout_ns` is the call's limit, `default_ns` by default; 0 is none.
local function options(endpoint: Endpoint, default_ns: integer, method: string, body?: string, timeout_ns?: integer): Http.Options
  local headers: mut {string: string} = {
    -- Over a port the URL names 127.0.0.1, which the daemon takes only
    -- with a token; this one it always takes, as its own client sends.
    ["Host"] = HOST,
    ["Tailscale-Cap"] = CAPABILITY,
  }
  local token = endpoint.token
  if token ~= nil then
    headers["Authorization"] = "Basic " .. Codec.base64(":" .. token)
  end
  if body ~= nil then headers["Content-Type"] = "application/json" end
  local via = endpoint.via
  local limit = timeout_ns or default_ns
  return {
    method = method,
    headers = headers,
    body = body,
    via = if via.kind == "unix" then via else nil end,
    timeout_ns = if limit == 0 then Http.FOREVER else limit end,
    low_speed_bytes = if limit == 0 then 0 else nil end,
    follow = false,
  }
end

--- The most bytes of a reply's body: a status of a large tailnet runs
--- to megabytes.
local REPLY_BYTES <const> = 256 * 1024 * 1024

--- `method` sent to `path` at `endpoint`, with `extra` headers, and the
--- whole reply, within `timeout_ns` (`default_ns` when nil, none when 0)
--- in all. It speaks
--- HTTP/1.1 over a connection of its own, which it closes, rather than
--- through [`cosmic.http`]: a wait here is [`cosmic.net`]'s, so in a task
--- of [`Poll.run`] (a server's handler) the other tasks run meanwhile.
local function sent(endpoint: Endpoint, default_ns: integer, method: string, path: string, body?: string,
                    timeout_ns?: integer, extra?: {string: string}): Http.Body?, string
  local limit = timeout_ns or default_ns
  local deadline = if limit == 0 then nil else Clock.monotonic_ns() + limit end
  local function left(): integer?
    if deadline == nil then return nil end
    return math.max(deadline - Clock.monotonic_ns(), 0)
  end
  local headers: mut {string: string} = {
    ["Host"] = HOST,
    ["Tailscale-Cap"] = CAPABILITY,
    ["Connection"] = "close",
    ["User-Agent"] = "cosmic",
  }
  local token = endpoint.token
  if token ~= nil then headers["Authorization"] = "Basic " .. Codec.base64(":" .. token) end
  if body ~= nil then headers["Content-Type"] = "application/json" end
  for name, value in pairs(extra or {}) do headers[name] = value end
  -- A POST with no body says so, as the daemon's own client does.
  local sending = body or (if method == "GET" then nil else "" end)
  local request, bad = Message.format_request({ method = method, target = path, headers = headers, body = sending })
  if request == nil then return nil, "tailscale: " .. bad end
  local conn <close>, why = Net.connect(endpoint.via, { timeout_ns = left() })
  if conn == nil then return nil, "tailscale: " .. why end
  conn:set_timeout(left())
  local wrote, refused = conn:write(request)
  if not wrote then return nil, "tailscale: " .. refused end
  local reader = Message.response_reader({ body_bytes = REPLY_BYTES })
  while true do
    conn:set_timeout(left())
    local chunk, trouble = conn:read()
    local read = if chunk ~= nil then reader:feed(chunk) elseif trouble == "" then reader:finish() else nil end
    if read == nil then return nil, "tailscale: " .. trouble end
    if read.status == "done" then
      local response = read.response
      if response == nil then return nil, "tailscale: the reply holds no response" end
      -- The daemon sends no interim reply; one would be no answer.
      if response.status < 200 then return nil, "tailscale: the daemon's reply is interim" end
      return { status = response.status, body = response.body, headers = response.headers }, ""
    end
    if read.status ~= "more" then
      return nil, "tailscale: the daemon's reply: " .. (if read.reason ~= "" then read.reason else read.status end)
    end
  end
end

--- `path`'s body, or why it is not one of status 200.
local function ok(endpoint: Endpoint, default_ns: integer, method: string, path: string, body?: string, timeout_ns?: integer): Answer
  local got, why = sent(endpoint, default_ns, method, path, body, timeout_ns)
  if got == nil then return { reason = why, status = 0 } end
  if got.status ~= 200 then
    local said = got.body:gsub("%s+$", "")
    -- Some endpoints refuse with `{"error": "..."}`, others with text.
    local refusal, _ = Json.decode_object(said)
    local message = if refusal ~= nil then refusal["error"] else nil end
    if message is string then said = message end
    if said == "" then said = "status " .. tostring(got.status) end
    return { reason = "tailscale: " .. (path:match("^[^?]*") or path) .. ": " .. said, status = got.status }
  end
  return { body = got.body, reason = "", status = 200 }
end

--- The ports Funnel opens to the internet.
local FUNNEL_PORTS <const>: {integer: boolean} = { [443] = true, [8443] = true, [10000] = true }

--- How many times [`Client.serve`] reads the configuration again after
--- another writer changed it between its read and its write.
local SERVE_TRIES <const> = 8

--- Raises, naming `where`, unless `port` is one a node can serve.
local function checked_port(port: integer, where: string): integer
  if math.type(port) ~= "integer" or port < 1 or port > 65535 then
    error("tailscale: " .. where .. ".port must be 1 to 65535", 4)
  end
  return port
end

--- The daemon's handler for `handler`, mounted at `mount` of `where`;
--- raises on one that is not exactly one thing.
local function handler_of(handler: ServeHandler, mount: string, where: string): {string: Json.Value}
  if mount:sub(1, 1) ~= "/" then
    error("tailscale: " .. where .. ": a mount path starts with /", 4)
  end
  local out: mut {string: Json.Value} = {}
  local count = 0
  local proxy = handler.proxy
  if proxy ~= nil then
    if proxy:match("^https?://.") == nil and proxy:match("^https%+insecure://.") == nil then
      error("tailscale: " .. where .. "[" .. mount .. "].proxy must be an http://, https:// or https+insecure:// URL", 4)
    end
    out["Proxy"] = proxy
    count = count + 1
  end
  if handler.text ~= nil then
    out["Text"] = handler.text
    count = count + 1
  end
  if handler.path ~= nil then
    out["Path"] = handler.path
    count = count + 1
  end
  if count ~= 1 then
    error("tailscale: " .. where .. "[" .. mount .. "] takes exactly one of proxy, text and path", 4)
  end
  return out
end

--- What [`Client.serve`] files for `spec` at `domain`, as the daemon's
--- JSON reads it, and the URLs of its sites. Raises on a spec it
--- cannot file: one of the wrong shape, or Funnel where it does not go.
local function foreground_of(spec: ServeSpec, domain: string): {string: Json.Value}, {string}
  local tcp: mut {string: Json.Value} = {}
  local web: mut {string: Json.Value} = {}
  local funnel: mut {string: Json.Value} = {}
  local urls: mut {string} = {}
  local used: mut {integer: boolean} = {}
  local function claim(port: integer, where: string, opened: boolean)
    if used[port] == true then
      error("tailscale: " .. where .. ": port " .. tostring(port) .. " is served twice", 4)
    end
    used[port] = true
    if opened and FUNNEL_PORTS[port] ~= true then
      error("tailscale: " .. where .. ": Funnel opens ports 443, 8443 and 10000 only, not " .. tostring(port), 4)
    end
  end
  for i, site in ipairs(spec.sites or {}) do
    local where = "sites[" .. tostring(i) .. "]"
    local plain = site.http == true
    local port = checked_port(site.port or (if plain then 80 else 443 end), where)
    if plain and site.funnel == true then
      error("tailscale: " .. where .. ": Funnel serves HTTPS only, not plain HTTP", 3)
    end
    claim(port, where, site.funnel == true)
    local host = domain .. ":" .. tostring(port)
    local handlers: mut {string: Json.Value} = {}
    local any = false
    for mount, handler in pairs(site.handlers) do
      handlers[mount] = handler_of(handler, mount, where .. ".handlers")
      any = true
    end
    if not any then error("tailscale: " .. where .. ".handlers is empty", 3) end
    tcp[tostring(port)] = if plain then { HTTP = true } else { HTTPS = true } end
    web[host] = { Handlers = handlers }
    if site.funnel == true then funnel[host] = true end
    local default = if plain then 80 else 443 end
    urls[#urls + 1] = (if plain then "http://" else "https://" end) .. domain ..
      (if port == default then "" else ":" .. tostring(port) end) .. "/"
  end
  for i, forward in ipairs(spec.forwards or {}) do
    local where = "forwards[" .. tostring(i) .. "]"
    local port = checked_port(forward.port, where)
    if forward.to:match("^.+:%d+$") == nil then
      error("tailscale: " .. where .. ".to must be host:port", 3)
    end
    if forward.funnel == true and forward.terminate_tls ~= true then
      error("tailscale: " .. where .. ": Funnel forwards only what it terminates TLS for (terminate_tls)", 3)
    end
    claim(port, where, forward.funnel == true)
    local handler: mut {string: Json.Value} = { TCPForward = forward.to }
    if forward.terminate_tls == true then handler["TerminateTLS"] = domain end
    tcp[tostring(port)] = handler
    if forward.funnel == true then funnel[domain .. ":" .. tostring(port)] = true end
  end
  if next(used) == nil then error("tailscale: serve takes at least one site or forward", 3) end
  local config: mut {string: Json.Value} = { TCP = tcp }
  if next(web) ~= nil then config["Web"] = web end
  if next(funnel) ~= nil then config["AllowFunnel"] = funnel end
  return config, urls
end

--- The ports `config` (the daemon's JSON, or one of its foreground
--- entries) serves, by number.
local function ports_of(config: {string: Json.Value}): {integer: boolean}
  local ports: mut {integer: boolean} = {}
  local tcp, _ = Json.to_object(config["TCP"])
  for key, _ in pairs(tcp or {}) do
    local port = math.tointeger(tonumber(key))
    if port ~= nil then ports[port] = true end
  end
  return ports
end

--- The events of [`Client.watch`], one a read: a line of JSON an
--- event. A class, so a `<close>` local holds one.
local class Events
  --- Internal: the daemon's reply. No caller reads it.
  response: Http.Response
  --- Internal: its lines.
  lines: Stream.Lines
  --- Internal: set by `close`.
  mut closed: boolean

  --- The next event; nil and "" at the stream's end, which is the
  --- daemon's, or nil and why. Holds the thread until one comes.
  function read(self): Notify?, string
    if self.closed then return nil, "tailscale: the events are closed" end
    while true do
      local line, why = self.lines:read()
      if line == nil then
        if why ~= "" then return nil, "tailscale: " .. why end
        return nil, ""
      end
      if line:find("%S") ~= nil then return notify_of(line) end
    end
  end

  --- Ends the stream. Safe to call more than once.
  function close(self): boolean, string
    self.closed = true
    return self.response:close()
  end

  function __close(self)
    local _, _ = self:close()
  end
end

--- The events at `endpoint` that `mask` asks for, as [`Client.watch`]
--- answers them.
local function bus(endpoint: Endpoint, default_ns: integer, mask: integer): Events?, string
  local path = "/localapi/v0/watch-ipn-bus?mask=" .. tostring(mask)
  local response, why = Http.open(endpoint.url .. path, options(endpoint, default_ns, "GET", nil, 0))
  if response == nil then return nil, "tailscale: " .. why end
  if response.status ~= 200 then
    local said, _ = Stream.read_up_to(response, 4096)
    local _, _ = response:close()
    return nil, "tailscale: watch-ipn-bus: " .. ((said or ""):gsub("%s+$", "")) .. " (status " ..
      tostring(response.status) .. ")"
  end
  local events: Events = { response = response, lines = Stream.lines(response, 64 * 1024 * 1024),
    closed = false }
  return events, ""
end

--- The events of the stream [`Client.serve`] files under: the daemon's
--- state first, which names the stream, and no private key in any.
local SERVE_MASK <const> = 2 | 16

--- What [`Client.serve`] put up, for as long as it holds the stream it
--- filed it under. A class, so a `<close>` local holds one.
local class Serving
  --- The stream's name, under which the configuration is filed.
  session: string
  --- The name the sites answer to.
  domain: string
  --- The URLs of the sites, in the order of [`ServeSpec.sites`].
  urls: {string}
  --- Internal: the stream the daemon ties the configuration to.
  events: Events

  --- Takes the configuration down: the daemon drops it once the
  --- stream ends. Safe to call more than once.
  function close(self): boolean, string
    return self.events:close()
  end

  function __close(self)
    local _, _ = self:close()
  end
end

--- The client of one daemon, as [`Tailscale.connect`] answers it.
local class Client
  --- Internal: where the daemon is. No caller reads it.
  endpoint: Endpoint
  --- Internal: how long a call may take.
  timeout_ns: integer

  --- `method` sent to `path` of the LocalAPI (`/localapi/v0/status`),
  --- with `body` when given, and the whole reply, whatever its status.
  ---
  ---     local got = assert(ts:request("GET", "/localapi/v0/derpmap"))
  function request(self, method: string, path: string, body?: string): Http.Body?, string
    if path:sub(1, 1) ~= "/" then error("tailscale: path must start with /", 2) end
    return sent(self.endpoint, self.timeout_ns, method, path, body)
  end

  --- A GET of `path`, as [`Client.request`] sends it.
  function get(self, path: string): Http.Body?, string
    return self:request("GET", path)
  end

  --- Who `address` is: an IP address of the tailnet, alone or with a
  --- port (`100.101.102.103:443`, `[fd7a:115c:a1e0::1]:443`), as a
  --- server sees a connection's far end. The answer's `caps` are the
  --- grants that apply to the peer on this node, so a server reads its
  --- own permissions there:
  ---
  ---     local who = assert(ts:whois(peer))
  ---     if who.caps["example.com/cap/admin"] == nil then return forbidden() end
  ---
  --- [`Client.whois_result`] tells an address that is no peer's from a
  --- daemon that cannot be asked.
  function whois(self, address: string): WhoIs?, string
    local result = self:whois_result(address)
    local whois = result.whois
    if whois == nil then return nil, result.reason end
    return whois, ""
  end

  --- [`Client.whois`], classified: "not_a_peer" where the daemon knows
  --- no node at the address, as for one off the tailnet.
  -- TODO: take the daemon's `svc_name` and `proto` once a server answers
  -- for a Tailscale Service, whose grants scope the CapMap to it.
  function whois_result(self, address: string): WhoIsResult
    local answer = ok(self.endpoint, self.timeout_ns, "GET", "/localapi/v0/whois?addr=" .. Url.escape(address))
    local text = answer.body
    if text == nil then
      if answer.status == 404 then
        return { kind = "not_a_peer", reason = "tailscale: no node has the address " .. address, status = 404 }
      end
      return { kind = "failed", reason = answer.reason, status = answer.status }
    end
    -- Null kept as itself, so that a capability granted with no value
    -- stays a key of CapMap.
    local wire, bad = WHOIS:decode_into(text, { null_value = Json.null })
    if wire == nil then
      return { kind = "failed", reason = "tailscale: whois: " .. bad, status = 200 }
    end
    return { kind = "found", whois = whois_of(wire), reason = "", status = 200 }
  end

  --- The node's status and its peers' (`tailscale status`).
  function status(self): Status?, string
    local answer = ok(self.endpoint, self.timeout_ns, "GET", "/localapi/v0/status")
    local text = answer.body
    if text == nil then return nil, answer.reason end
    local wire, bad = STATUS:decode_into(text)
    if wire == nil then return nil, "tailscale: status: " .. bad end
    return status_of(wire), ""
  end

  --- The node's preferences (`tailscale debug prefs`).
  function prefs(self): Prefs?, string
    local answer = ok(self.endpoint, self.timeout_ns, "GET", "/localapi/v0/prefs")
    local text = answer.body
    if text == nil then return nil, answer.reason end
    local wire, bad = PREFS:decode_into(text)
    if wire == nil then return nil, "tailscale: prefs: " .. bad end
    return prefs_of(wire), ""
  end

  --- A certificate for `domain`, one of [`Status.cert_domains`], and its
  --- key, from Let's Encrypt through the daemon, which keeps them and
  --- renews them a third of their life before they expire: a second call
  --- answers the one it holds. The first call for a name may take a
  --- minute while the CA checks it. It needs HTTPS enabled for the
  --- tailnet, and a caller the daemon lets have certificates.
  ---
  ---     local pair = assert(ts:cert(assert(status.cert_domains[1])))
  function cert(self, domain: string, opts?: CertOptions): CertPair?, string
    if domain == "" or domain:find("[/?#%%%s]") ~= nil then
      return nil, "tailscale: cert: no such domain " .. string.format("%q", domain)
    end
    local o: CertOptions = opts or {}
    local query = "?type=pair"
    local validity = o.min_validity_ns
    if validity ~= nil then
      if math.type(validity) ~= "integer" or validity < 0 then
        error("tailscale: min_validity_ns must be an integer of at least 0", 2)
      end
      -- Go's duration, in whole seconds rounded up.
      query = query .. "&min_validity=" .. tostring((validity + 999999999) // 1000000000) .. "s"
    end
    local answer = ok(self.endpoint, self.timeout_ns, "GET", "/localapi/v0/cert/" .. domain .. query, nil, o.timeout_ns or CERT_TIMEOUT_NS)
    local text = answer.body
    if text == nil then return nil, answer.reason end
    return pair_of(text)
  end

  --- The certificate of `domain`, one of [`Status.cert_domains`], kept
  --- current for a server's `tls` ([`cosmic.tls`]): each load is a
  --- [`cert`], asking for leaves valid as long as the renewal needs, so
  --- the daemon renews its own first where it would not have yet. With
  --- no `domain`, each load takes the node's first name of
  --- [`Status.cert_domains`]. Nothing is asked of the daemon until a
  --- server starts, or [`Tls.Certs.load`] is called.
  ---
  ---     assert(Server.serve{ listeners = { Net.tcp(address, 443) }, tls = ts:certs(), handle = handle })
  function certs(self, domain?: string, opts?: Tls.CertsOptions): Tls.Certs
    return Tls.certs(function(min_validity_ns?: integer): {Tls.Pair}?, string
      local name = domain
      if name == nil then
        local status, why = self:status()
        if status == nil then return nil, why end
        name = status.cert_domains[1]
        if name == nil then
          return nil, "tailscale: the node has no name to get a certificate for: is HTTPS enabled for the tailnet?"
        end
      end
      local pair, why = self:cert(name, { min_validity_ns = min_validity_ns })
      if pair == nil then return nil, why end
      return { { cert = pair.cert, key = pair.key } }, ""
    end, opts)
  end

  --- How long a ping to the node at `address` takes over the tailnet,
  --- by the path `kind` names ("disco" by default). A peer that does not
  --- answer fails it, with the daemon's reason.
  function ping(self, address: string, kind?: PingKind): Ping?, string
    local query = Url.encode_query({
      { name = "ip", value = address },
      { name = "type", value = kind or "disco" },
    })
    local answer = ok(self.endpoint, self.timeout_ns, "POST", "/localapi/v0/ping?" .. query)
    local text = answer.body
    if text == nil then return nil, answer.reason end
    local wire, bad = PING:decode_into(text)
    if wire == nil then return nil, "tailscale: ping: " .. bad end
    local err = wire.Err
    if err ~= nil and err ~= "" then return nil, "tailscale: ping " .. address .. ": " .. err end
    return {
      latency_ns = math.floor((wire.LatencySeconds or 0) * 1e9 + 0.5),
      endpoint = nonempty(wire.Endpoint),
      derp_region = nonempty(wire.DERPRegionCode),
      peer_relay = nonempty(wire.PeerRelay),
    }, ""
  end

  --- The daemon's events as they happen (the IPN bus), first those
  --- `opts` asks for. A stream that is open holds a connection to the
  --- daemon; a daemon that restarts ends it.
  ---
  ---     local events <close> = assert(ts:watch())
  ---     while true do
  ---       local event = assert(events:read())
  ---       if event.state == "Running" then break end
  ---     end
  function watch(self, opts?: WatchOptions): Events?, string
    local o: WatchOptions = opts or {}
    local mask = 0
    if o.engine == true then mask = mask | 1 end
    if o.initial_state ~= false then mask = mask | 2 end
    if o.initial_status == true then mask = mask | (1 << 14) end
    return bus(self.endpoint, self.timeout_ns, mask)
  end

  --- Puts up `spec` through the daemon's Serve, and Funnel where a site
  --- asks for it: the daemon terminates TLS with the node's `ts.net`
  --- certificate and passes each request on. The configuration is the
  --- program's own, filed in the daemon as a foreground one (as
  --- `tailscale serve` without `--bg` files its own) under a stream of
  --- [`Client.watch`] that the answer holds. The daemon drops it when
  --- that stream ends, which [`Serving.close`] does, and so does the
  --- program's exit, however it ends; it never changes what the node
  --- serves for others, and fails where they already serve a port it
  --- names. A daemon that restarts drops it too, and the program is not
  --- told. Holds the thread while it opens the stream, as `watch` does.
  --- Raises on a spec it cannot file, before it asks the daemon.
  ---
  ---     local served <close> = assert(ts:serve({
  ---       sites = { { funnel = true, handlers = { ["/"] = { proxy = "http://127.0.0.1:8080" } } } },
  ---     }))
  ---     print(served.urls[1]) -- https://box.tail1234.ts.net/
  function serve(self, spec: ServeSpec): Serving?, string
    -- The spec is checked before the daemon is asked.
    local _, _ = foreground_of(spec, spec.domain or "")
    local domain = spec.domain
    if domain == nil then
      local status, why = self:status()
      if status == nil then return nil, why end
      local own = status.self
      domain = status.cert_domains[1] or (if own ~= nil then undotted(own.dns_name) else nil end)
      if domain == nil or domain == "" then
        return nil, "tailscale: serve: the node has no name yet: is it logged in?"
      end
    end
    local config, urls = foreground_of(spec, domain)
    local events, why = bus(self.endpoint, self.timeout_ns, SERVE_MASK)
    if events == nil then return nil, why end
    local function failed(reason: string): Serving?, string
      local _, _ = events:close()
      return nil, reason
    end
    local first, bad = events:read()
    if first == nil then
      return failed(if bad ~= "" then bad else "tailscale: serve: the daemon ended the stream" end)
    end
    local session = first.session
    if session == nil then
      return failed("tailscale: serve: the daemon names no session: it predates foreground serving")
    end
    local wanted = ports_of(config)
    for _ = 1, SERVE_TRIES do
      local got, trouble = sent(self.endpoint, self.timeout_ns, "GET", "/localapi/v0/serve-config")
      if got == nil then return failed(trouble) end
      if got.status ~= 200 then
        return failed("tailscale: serve-config: " .. got.body:gsub("%s+$", "") .. " (status " .. tostring(got.status) .. ")")
      end
      local text = got.body:gsub("%s+$", "")
      local whole: mut {string: Json.Value} = {}
      if text ~= "null" and text ~= "" then
        local decoded, wrong = Json.decode_object(text)
        if decoded == nil then return failed("tailscale: serve-config: " .. wrong) end
        for name, value in pairs(decoded) do whole[name] = value end
      end
      local foreground: mut {string: Json.Value} = {}
      local others, _ = Json.to_object(whole["Foreground"])
      local served: mut {{string: Json.Value}} = { whole }
      for name, other in pairs(others or {}) do
        local entry, _ = Json.to_object(other)
        if entry ~= nil then
          foreground[name] = entry
          served[#served + 1] = entry
        end
      end
      for _, taken in ipairs(served) do
        for port, _ in pairs(ports_of(taken)) do
          if wanted[port] == true then
            return failed("tailscale: serve: port " .. tostring(port) .. " is already served")
          end
        end
      end
      foreground[session] = config
      whole["Foreground"] = foreground
      local body, unencodable = Json.encode(whole)
      if body == nil then return failed("tailscale: serve-config: " .. unencodable) end
      local etag = got.headers["etag"]
      if etag == nil then
        return failed("tailscale: serve-config: the daemon's reply holds no ETag")
      end
      local put, lost = sent(self.endpoint, self.timeout_ns, "POST", "/localapi/v0/serve-config", body, nil,
        { ["If-Match"] = etag })
      if put == nil then return failed(lost) end
      if put.status == 200 then
        local serving: Serving = { session = session, domain = domain, urls = urls, events = events }
        return serving, ""
      end
      if put.status ~= 412 then
        return failed("tailscale: serve-config: " .. put.body:gsub("%s+$", "") .. " (status " .. tostring(put.status) .. ")")
      end
    end
    return failed("tailscale: serve-config: others changed it between each read and write")
  end
end

local record Tailscale
  --- A client of one daemon, as [`Tailscale.connect`] answers it.
  type Client = Client
  --- Where a [`Client`] reaches its daemon.
  type Endpoint = Endpoint
  type User = User
  type Node = Node
  type WhoIs = WhoIs
  type WhoIsKind = WhoIsKind
  type WhoIsResult = WhoIsResult
  type Peer = Peer
  type Status = Status
  type Prefs = Prefs
  type CertPair = CertPair
  type PingKind = PingKind
  type Ping = Ping
  type CertOptions = CertOptions
  type State = State
  type Notify = Notify
  type WatchOptions = WatchOptions
  type Events = Events
  type ServeHandler = ServeHandler
  type ServeSite = ServeSite
  type ServeForward = ServeForward
  type ServeSpec = ServeSpec
  type Serving = Serving

  --- How [`Tailscale.connect`] reaches the daemon. With none of these,
  --- it looks where the platform's daemon listens.
  record Daemon
    --- The daemon's socket file, as `tailscaled --socket` names it.
    socket?: string
    --- A port of 127.0.0.1 the daemon listens at, as macOS's app does.
    port?: integer
    --- The token that port asks for, the same-user proof.
    token?: string
    --- How long a call may take, in nanoseconds; 10 seconds by default.
    --- [`Client.watch`] takes no limit.
    timeout_ns?: integer
  end
end

--- `port` of 127.0.0.1 as an endpoint, where something listens there:
--- a proof file outlives the app that wrote it, until the app starts again.
local function listening(port: integer, token: string): Endpoint?
  if port < 1 or port > 65535 then return nil end
  local address = Net.tcp("127.0.0.1", port)
  local conn, _ = Net.connect(address, { timeout_ns = 1000000000 })
  if conn == nil then return nil end
  local _, _ = conn:close()
  return { via = address, url = "http://127.0.0.1:" .. tostring(port), token = token }
end

--- The same-user proof of macOS's standalone app, which its system
--- extension writes under /Library/Tailscale: `ipnport`, a link whose
--- target is the port, and `sameuserproof-<port>`, the token.
local function macsys_proof(): Endpoint?
  local port_text, _ = Fs.readlink("/Library/Tailscale/ipnport")
  local port = math.tointeger(tonumber(port_text or ""))
  if port == nil then return nil end
  local token, _ = Fs.read("/Library/Tailscale/sameuserproof-" .. tostring(port))
  if token == nil then return nil end
  token = token:gsub("%s+$", "")
  if token == "" then return nil end
  return listening(port, token)
end

--- The same-user proof of macOS's App Store app: a file named
--- `sameuserproof-<port>-<token>` in the app's group container, which
--- only the user who runs the app can list. The first whose port is
--- listening wins.
local function app_store_proof(): Endpoint?
  local home = Env.get("HOME")
  if home == nil or home == "" then return nil end
  local containers = home .. "/Library/Group Containers"
  local names, _ = Fs.list(containers)
  if names == nil then return nil end
  local sorted: mut {string} = {}
  for _, name in ipairs(names) do sorted[#sorted + 1] = name end
  table.sort(sorted)
  for _, name in ipairs(sorted) do
    if name:sub(-#"io.tailscale.ipn.macos") == "io.tailscale.ipn.macos" then
      local files, _ = Fs.list(containers .. "/" .. name)
      for _, file in ipairs(files or {}) do
        local port_text, token = file:match("^sameuserproof%-(%d+)%-(%w+)$")
        local port = math.tointeger(tonumber(port_text or ""))
        local found = if port ~= nil and token ~= nil then listening(port, token) else nil end
        if found ~= nil then return found end
      end
    end
  end
  return nil
end

--- Where tailscaled listens by default: the first of the platform's
--- socket files that exists, else the first, which a call then fails to
--- reach, naming it.
local function default_socket(darwin: boolean): string
  -- TODO: look where Synology, QNAP and gokrazy put the socket
  -- (tailscale's paths.DefaultTailscaledSocket) once a caller runs there;
  -- `opts.socket` reaches it until then.
  local candidates: {string} = if darwin then { "/var/run/tailscaled.socket" } else {
    "/var/run/tailscale/tailscaled.sock", "/run/tailscale/tailscaled.sock",
  } end
  for _, path in ipairs(candidates) do
    local there, _ = Fs.exists(path)
    if there == true then return path end
  end
  return assert(candidates[1])
end

local function unix_endpoint(path: string): Endpoint
  return { via = Net.unix(path), url = "http://" .. HOST }
end

--- A client of the machine's tailscaled. With no `opts` it takes, on
--- macOS, the app's same-user proof (the App Store app's, then the
--- standalone app's) and else the open-source daemon's socket; on Linux
--- `/var/run/tailscale/tailscaled.sock`, or `/run/tailscale/` where only
--- that exists. An app proof is taken only while its port listens. `opts.socket` names the socket instead, and `opts.port`
--- a port of 127.0.0.1, with `opts.token` its proof. No connection is
--- kept open: a daemon that is not there fails the first call.
--- Raises on options of the wrong shape: both `socket` and `port`, a
--- `token` without `port`, or a port or timeout out of range.
---
---     local ts = assert(Tailscale.connect({ socket = "/tmp/ts/tailscaled.sock" }))
function Tailscale.connect(opts?: Tailscale.Daemon): Client?, string
  local o: Tailscale.Daemon = opts or {}
  if o.socket ~= nil and o.port ~= nil then error("tailscale: give socket or port, not both", 2) end
  if o.token ~= nil and o.port == nil then error("tailscale: token needs port", 2) end
  local port = o.port
  if port ~= nil and (math.type(port) ~= "integer" or port < 1 or port > 65535) then
    error("tailscale: port must be from 1 to 65535", 2)
  end
  local timeout_ns = o.timeout_ns or DEFAULT_TIMEOUT_NS
  if timeout_ns < 1 then error("tailscale: timeout_ns must be at least 1", 2) end
  local endpoint: Endpoint
  local socket = o.socket
  if socket ~= nil then
    if socket == "" then return nil, "tailscale: the socket path is empty" end
    endpoint = unix_endpoint(socket)
  elseif port ~= nil then
    endpoint = { via = Net.tcp("127.0.0.1", port), url = "http://127.0.0.1:" .. tostring(port), token = o.token }
  else
    local names, _ = sys.uname()
    local darwin = names ~= nil and names.sysname == "Darwin"
    local proof = if darwin then app_store_proof() or macsys_proof() else nil end
    endpoint = proof or unix_endpoint(default_socket(darwin))
  end
  local client: Client = { endpoint = endpoint, timeout_ns = timeout_ns }
  return client, ""
end

return Tailscale
