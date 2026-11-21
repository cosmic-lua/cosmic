--- TLS for a server: the certificates it presents, kept current. A
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

local Clock = require("cosmic.clock")
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

local record Tls
  type Pair = Pair
  type Leaf = Leaf
  type Source = Source
  type CertsOptions = CertsOptions
  type Certs = Certs
  --- What a connection's handshake settled: see [`Net.Conn`]'s `tls`.
  type Info = raw_tls.Info
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
