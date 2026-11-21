--- TLS for a server and for a client. A server presents
--- certificates, kept current; a client verifies the server's against
--- the roots it trusts.
---
--- A
--- [`Tls.Certs`] holds the pairs of certificate and key a source
--- obtains, and obtains them again before they expire. [`Net.serve`]
--- (and so [`Server.serve`] and [`Web.serve`]) takes one as its
--- `tls`, and serves each connection it accepts over TLS 1.2 or 1.3
--- with the newest pairs: a renewal reaches the connections accepted
--- after it, and those already open keep what they began with.
---
---     local certs = Tls.certs(Tls.static({ { cert = cert_pem, key = key_pem } }))
---     assert(Server.serve{
---       listeners = { Net.tcp("0.0.0.0", 443) }, tls = certs,
---       handle = function(_: Server.Request): Server.Reply return { status = 200 } end,
---     })
---
--- A source is a function that answers the pairs, so where they come
--- from is the caller's: [`Tls.static`] for pairs in hand,
--- [`cosmic.tailscale.Client.certs`] for the machine's `ts.net`
--- name, an ACME client for any other. A source is called in a task of
--- the server's run, so one that waits on [`cosmic.net`] lets the
--- server go on meanwhile.
---
--- With more than one pair, a client is offered those whose leaves
--- name, among their DNS Subject Alternative Names, the host it asked
--- for (SNI): the name itself, or a `*.` wildcard for one label. A
--- client that names no host, or one no leaf names, is offered every
--- pair. It is served the first offered whose key signs by an algorithm
--- it takes, so an ECDSA and an RSA pair for one name serve old clients
--- and new alike. No client certificate is asked for, and no session is
--- resumed: each connection makes a full handshake.
---
--- A [`Tls.Client`], made by [`Tls.client`], is what a client connects
--- with: [`Net.connect`]'s `tls`, or [`Net.Conn`]'s `start_tls` on a
--- connection already made (STARTTLS). It trusts the roots
--- [`cosmic.http`] does by default -- "minimal", or every root this
--- binary carries -- and verifies that the server's certificate names
--- the host asked for, which it also sends (SNI). After the handshake
--- the connection's `tls` says what the server presented.
---
---     local client = assert(Tls.client({ alpn = { "http/1.1" } }))
---     local conn = assert(Net.connect(Net.tcp(address, 443), { tls = client, server_name = "example.com" }))
---     print(assert(conn:tls()).peer.issuer)

local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")
local Poll = require("cosmic.poll")
local type raw_tls = require("cosmic.internal.tls")

local raw = require("cosmic.internal.tls")

local NS <const> = 1000000000

--- A certificate and its key, as a source answers them: `cert`, the
--- chain, PEM, the leaf first and then each certificate up to, but not
--- needing, the root; and `key`, the leaf's private key, PEM: ECDSA
--- (P-256, P-384, P-521) or RSA.
local type Pair = raw_tls.Pair

--- What a leaf certificate says of itself, as [`Tls.leaf`] reads it.
local record Leaf
  --- The DNS names among its Subject Alternative Names.
  names: {string}
  --- When it becomes valid, in [`Clock.now_ns`]'s nanoseconds.
  not_before_ns: integer
  --- When it stops being valid, the same.
  not_after_ns: integer
end

--- What obtains the pairs: called once before a server first listens,
--- and again as they near expiry, with how long the leaves must still
--- be valid for (nil the first time): a source that keeps certificates
--- of its own renews one that expires sooner. It answers 1 to 64 pairs,
--- or nil and why.
local type Source = function(min_validity_ns?: integer): {Pair}?, string

--- What [`Tls.certs`] takes.
local record CertsOptions
  --- The protocols offered by ALPN, at most 8, each 1 to 255 bytes; nil
  --- for none, which leaves a client to speak the one it would without.
  alpn?: {string}
  --- How long to wait after a renewal fails before the next try,
  --- doubled after each failure up to an hour (1 minute).
  retry_ns?: integer
end

--- The longest wait between tries, however many fail.
local RETRY_MOST_NS <const> = Clock.hours(1)

--- The longest one wait for a renewal lasts before it looks at the wall
--- clock again, which can jump while the process sleeps.
local WAIT_MOST_NS <const> = Clock.hours(1)

--- What the first certificate of the PEM chain `pem` says of itself.
local function leaf_of(pem: string): Leaf?, string
  local leaf, why = raw.leaf(pem)
  if leaf == nil then return nil, why end
  return { names = leaf.names, not_before_ns = leaf.not_before * NS, not_after_ns = leaf.not_after * NS }, ""
end

--- The pairs a server presents, from a source, kept current: see
--- [`cosmic.tls`]. A class, made by [`Tls.certs`].
local class Certs
  --- Internal: what obtains the pairs. No caller reads it.
  source: Source
  --- Internal: the protocols ALPN offers. No caller reads them.
  alpn?: {string}
  --- Internal: the first wait after a failed renewal. No caller reads it.
  retry_ns: integer
  --- Internal: the newest configuration, once one is loaded.
  mut current?: raw_tls.Config
  --- Internal: the leaves of the newest pairs, in their order.
  mut held: {Leaf}
  --- Internal: when the next renewal is due, in [`Clock.now_ns`]'s
  --- nanoseconds.
  mut due_ns: integer
  --- Internal: how long the newest leaf with the shortest life lasts.
  mut life_ns: integer

  --- Obtains the pairs from the source now and serves them to every
  --- connection after, with `min_validity_ns` given to the source. True,
  --- or false and why, the pairs before kept: a source that fails or
  --- raises (what it raised is the why), or answers no pair, a pair whose certificate or key cannot be read,
  --- a key that is not its certificate's, or a leaf already expired.
  function load(self, min_validity_ns?: integer): boolean, string
    local ran, obtained, why = pcall(self.source, min_validity_ns)
    if not ran then return false, "tls: the source raised: " .. tostring(obtained) end
    if obtained == nil then return false, why end
    if #obtained == 0 then return false, "tls: the source answered no pair" end
    if #obtained > 64 then return false, "tls: the source answered more than 64 pairs" end
    local leaves: mut {Leaf} = {}
    local now = Clock.now_ns()
    local due = math.maxinteger
    local life = math.maxinteger
    for i, pair in ipairs(obtained) do
      local leaf, bad = leaf_of(pair.cert)
      if leaf == nil then return false, "tls: pair " .. tostring(i) .. ": " .. bad end
      if leaf.not_after_ns <= now then
        return false, "tls: pair " .. tostring(i) .. "'s certificate has expired"
      end
      leaves[i] = leaf
      local span = math.max(leaf.not_after_ns - leaf.not_before_ns, 0)
      -- A third of its life before it ends, as Let's Encrypt and
      -- tailscaled renew.
      due = math.min(due, leaf.not_after_ns - span // 3)
      life = math.min(life, span)
    end
    local config, refused = raw.config(obtained, self.alpn)
    if config == nil then return false, refused end
    self.current = config
    self.held = leaves
    self.due_ns = due
    self.life_ns = life
    return true, ""
  end

  --- The leaves of the pairs served now, in the order the source gave
  --- them; empty before the first load.
  function leaves(self): {Leaf}
    return self.held
  end

  --- When the next renewal is due, in [`Clock.now_ns`]'s nanoseconds;
  --- nil before the first load.
  function renews_at(self): integer?
    if self.current == nil then return nil end
    return self.due_ns
  end

  --- Internal: the configuration a new connection takes; nil before the
  --- first load. [`Net.serve`] reads it.
  function config(self): raw_tls.Config?
    return self.current
  end

  --- Loads the pairs where none are, then renews them as they come due, until `stopping` says to stop
  --- or a wait is cancelled, in a task of [`Poll.run`]: a server runs
  --- this for its run. Each renewal asks the source for leaves valid
  --- for at least half the life of those it holds, so a source with a
  --- store of its own renews too. A failure goes to `report` and is
  --- tried again after `retry_ns`, doubled after each, the pairs before
  --- served meanwhile. Leaves the source answers already due are served
  --- and asked for again the same way, reported once.
  function keep(self, report: function(trouble: string), stopping: function(): boolean)
    local retry = self.retry_ns
    -- Set while each load answers leaves already due, so that is
    -- reported once, not at every retry: a source that renews nothing
    -- ([`Tls.static`]) does so for the last third of its leaves' life.
    local stale = false
    while not stopping() do
      local wait = math.min(math.max(self.due_ns - Clock.now_ns(), 0), WAIT_MOST_NS)
      if wait > 0 then
        local waited, _ = Poll.delay(wait)
        if not waited then return end
      else
        local ok, why = self:load(if self.life_ns > 0 then self.life_ns // 2 else nil end)
        if stopping() then return end
        if ok and self.due_ns > Clock.now_ns() then
          retry = self.retry_ns
          stale = false
        else
          -- A source that answered leaves already due is tried again
          -- later too, so it is not asked again at once, without end.
          if not ok then
            report(why)
          elseif not stale then
            stale = true
            report("tls: the source answered certificates already due for renewal; serving them, and asking again")
          end
          local waited, _ = Poll.delay(retry)
          if not waited then return end
          retry = math.min(retry * 2, RETRY_MOST_NS)
        end
      end
    end
  end
end

--- What the peer's certificate says of itself, as a connection's
--- [`Info.peer`] gives it.
local record Peer
  --- Its subject, as the TLS stack words a distinguished name:
  --- `CN=example.com, O=Example`; "" where it cannot.
  subject: string
  --- Its issuer, worded as `subject` is.
  issuer: string
  --- Its serial number, as colon-separated hex bytes (`01:A2:...`).
  serial: string
  --- The DNS names among its Subject Alternative Names.
  names: {string}
  --- The IP addresses among them, as text (`127.0.0.1`, `::1`).
  addresses: {string}
  --- The URIs among them: a SPIFFE ID is one.
  uris: {string}
  --- The email addresses among them.
  emails: {string}
  --- When it becomes valid, in [`Clock.now_ns`]'s nanoseconds.
  not_before_ns: integer
  --- When it stops being valid, the same.
  not_after_ns: integer
  --- Whether its chain was verified against roots the side that read
  --- it trusts, and passed: false where that side verifies nothing.
  verified: boolean
  --- The certificate, DER.
  der: string
  --- The SHA-256 of `der`, lower-case hex.
  sha256: string
  --- Its public key pin, as [`ClientOptions.pin`] and
  --- [`cosmic.http`]'s `opts.pin` take one: `sha256//` and the base64
  --- of the SHA-256 of its SubjectPublicKeyInfo.
  pin: string
end

--- What a connection's handshake settled: see [`Net.Conn`]'s `tls`.
local record Info
  --- "TLSv1.2" or "TLSv1.3".
  version: string
  --- The protocol ALPN chose; nil where none was.
  alpn?: string
  --- On a server, the name the client asked for (SNI): nil where it
  --- named none, or one with a byte no host name has. On a client, the
  --- name it verified the server against.
  server_name?: string
  --- The peer's certificate: the server's, on a client; nil where the
  --- peer presented none, as a client does to a server that asks for
  --- none.
  peer?: Peer
end

--- What [`Tls.client`] takes. With none of `roots`, `ca` and `pin`, a
--- client trusts what [`cosmic.http`] does with none.
local record ClientOptions
  --- The CA roots to trust, as [`cosmic.http`]'s `opts.roots` names
  --- them: "minimal", "mozilla", "none", or a list of the SHA-256
  --- digests of roots this binary carries; nil for
  --- [`Http.default_roots`]. The certificates `$SSL_CERT_FILE` names
  --- are trusted besides, but with "none".
  roots?: string | {string}
  --- Certificates to trust besides `roots`: PEM, or one DER. A private
  --- CA's root is given here, with `roots = "none"` to trust it alone,
  --- when Mozilla's distrust dates and OneCRL, which come with the
  --- carried roots, are not read either.
  ca?: string
  --- One public key pin or more, as [`Peer.pin`] words one: the
  --- server's key must be one of them, besides its chain verifying.
  --- [`Http.public_key_pin`] makes one from a certificate.
  pin?: string | {string}
  --- False to verify no chain and no name: what the server presents is
  --- taken as it is, but a `pin` is still held to. True by default.
  verify?: boolean
  --- The protocols offered by ALPN, at most 8, each 1 to 255 bytes, in
  --- the order preferred; nil for none.
  alpn?: {string}
  --- A certificate and its key to present to a server that asks for
  --- one (mutual TLS); nil for none.
  identity?: Pair
end

--- What [`Peer`] reads of the raw module's certificate.
local function peer_of(raw_peer: raw_tls.Peer): Peer
  return {
    subject = raw_peer.subject, issuer = raw_peer.issuer, serial = raw_peer.serial,
    names = raw_peer.names, addresses = raw_peer.addresses, uris = raw_peer.uris, emails = raw_peer.emails,
    not_before_ns = raw_peer.not_before * NS, not_after_ns = raw_peer.not_after * NS,
    verified = raw_peer.verified, der = raw_peer.der, sha256 = Codec.hex(Hash.sha256(raw_peer.der)),
    pin = "sha256//" .. Codec.base64(Hash.sha256(raw_peer.public_key)),
  }
end

--- The pins of `pin`, as a set; raises at the caller of [`Tls.client`]
--- on one of the wrong shape.
local function pins_of(pin: (string | {string})?): {string: boolean}?
  if pin == nil then return nil end
  local listed: {string}
  if pin is string then
    listed = { pin }
  else
    listed = pin
  end
  if #listed == 0 then error("tls: opts.pin must hold a pin", 3) end
  local set: mut {string: boolean} = {}
  for i, one in ipairs(listed) do
    if type(one) ~= "string" or #one ~= 52 or not one:match("^sha256//[%w+/]+=$") then
      error(("tls: opts.pin[%d] must be sha256// and the base64 of 32 bytes, as Peer.pin words one"):format(i), 3)
    end
    set[one] = true
  end
  return set
end

--- What a client connects with: the roots it trusts, parsed once, and
--- what else it holds a server to. A class, made by [`Tls.client`];
--- one serves any number of connections, each its own session of it.
local class Client
  --- Internal: the configuration each session is made of. No caller reads it.
  config: raw_tls.Config
  --- Internal: whether a chain and a name are verified.
  verify: boolean
  --- Internal: the pins a server's key must be among; nil for none.
  pins?: {string: boolean}

  --- Internal: a session of this client over the connected socket `fd`,
  --- asking for `server_name`; nil and why where none can be made.
  --- [`Net.Conn`]'s `start_tls` makes one.
  function session(self, fd: integer, server_name?: string): raw_tls.Session?, string
    if self.verify and server_name == nil then
      return nil, "tls: a client that verifies needs a server name to verify against"
    end
    if server_name ~= nil and (#server_name < 1 or #server_name > 255 or server_name:find("%z") ~= nil) then
      return nil, "tls: a server name is 1 to 255 bytes, with no NUL"
    end
    return raw.session(self.config, fd, server_name)
  end

  --- Internal: `trouble`, a failed handshake's why, with what to do
  --- where it is that the chain leads to no root this client trusts.
  function explained(self, trouble: string): string
    if not self.verify or trouble:find("not correctly signed by the trusted CA", 1, true) == nil then
      return trouble
    end
    return trouble .. "; the roots this client trusts do not include this peer's: opts.roots = \"mozilla\" " ..
      "trusts every root this binary carries, and opts.ca or $SSL_CERT_FILE one more"
  end

  --- Internal: true where what a finished handshake settled holds to
  --- the pins; false and why otherwise.
  function accepts(self, info: Info): boolean, string
    local pins = self.pins
    if pins == nil then return true, "" end
    local peer = info.peer
    if peer == nil then
      return false, "tls: the server presented no certificate to hold to the pin"
    end
    if pins[peer.pin] ~= true then
      return false, "tls: the server's key is none of the pinned ones: it is " .. peer.pin
    end
    return true, ""
  end
end

local record Tls
  type Pair = Pair
  type Leaf = Leaf
  type Source = Source
  type CertsOptions = CertsOptions
  type Certs = Certs
  type Info = Info
  type Peer = Peer
  type ClientOptions = ClientOptions
  type Client = Client
end

--- What a session's handshake settled, as [`Info`] says it; nil for
--- one not done. [`Net.Conn`]'s `tls` reads it.
function Tls.info(session: raw_tls.Session): Info
  local got = session:info()
  local raw_peer = got.peer
  return {
    version = got.version, alpn = got.alpn, server_name = got.server_name,
    peer = if raw_peer ~= nil then peer_of(raw_peer) else nil end,
  }
end

--- A client that trusts what `opts` chooses: see [`ClientOptions`]. Nil
--- and why where the roots cannot be had (the binary carries none, or
--- `ca` holds what the TLS stack cannot read), or `identity` cannot be
--- read or its key is not its certificate's. Raises on options of the
--- wrong shape, naming them.
---
---     local client = assert(Tls.client({ roots = "none", ca = assert(Fs.read("ca.pem")) }))
function Tls.client(opts?: ClientOptions): Client?, string
  local o: ClientOptions = opts or {}
  local alpn = o.alpn
  if alpn ~= nil then
    if #alpn > 8 then error("tls: opts.alpn takes at most 8 protocols", 2) end
    for _, name in ipairs(alpn) do
      if type(name) ~= "string" or #name < 1 or #name > 255 then
        error("tls: an ALPN protocol is a string of 1 to 255 bytes", 2)
      end
    end
  end
  local verify = o.verify ~= false
  if not verify and (o.roots ~= nil or o.ca ~= nil) then
    error("tls: opts.roots and opts.ca choose what to verify against, so take no verify = false", 2)
  end
  local pins = pins_of(o.pin)
  local roots: string | boolean = false
  if verify then
    -- Required here, so a program that only serves loads none of the
    -- trust store.
    local Trust = require("cosmic.internal.trust")
    local chosen, untold = Trust.chosen(o.roots, o.ca, "tls", 2)
    if untold ~= "" then return nil, untold end
    local pem, why = Trust.pem(chosen or Trust.everything(), "tls")
    if pem == nil then return nil, why end
    roots = pem
  end
  local config, refused = raw.client(roots, alpn, o.identity)
  if config == nil then return nil, refused end
  local client: Client = { config = config, verify = verify, pins = pins }
  return client, ""
end

--- What the first certificate of the PEM chain `pem` says of itself;
--- nil and why where it cannot be read.
---
---     local leaf = assert(Tls.leaf(pair.cert))
---     print(leaf.names[1], (leaf.not_after_ns - Clock.now_ns()) // Clock.hours(24), "days left")
function Tls.leaf(pem: string): Leaf?, string
  return leaf_of(pem)
end

--- A source that always answers the pairs `held`: certificates the program
--- holds already, renewed only by a new program.
function Tls.static(held: {Pair}): Source
  return function(_?: integer): {Pair}?, string
    if #held == 0 then return nil, "tls: static holds no pair" end
    return held, ""
  end
end

--- Certificates obtained from `source` and kept current, for a server's
--- `tls`: nothing is obtained until a server starts, or [`Certs.load`]
--- is called. Raises on options out of range.
---
---     local certs = Tls.certs(Tls.static({ pair }), { alpn = { "http/1.1" } })
function Tls.certs(source: Source, opts?: CertsOptions): Certs
  local o: CertsOptions = opts or {}
  local alpn = o.alpn
  if alpn ~= nil then
    if #alpn > 8 then error("tls: alpn takes at most 8 protocols", 2) end
    for _, name in ipairs(alpn) do
      if #name < 1 or #name > 255 then error("tls: an ALPN protocol is 1 to 255 bytes", 2) end
    end
  end
  local retry = o.retry_ns or Clock.minutes(1)
  if retry < 1 then error("tls: retry_ns must be at least 1", 2) end
  local certs: Certs = {
    source = source, alpn = alpn, retry_ns = retry, current = nil, held = {},
    due_ns = 0, life_ns = 0,
  }
  return certs
end

return Tls
