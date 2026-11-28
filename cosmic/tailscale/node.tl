--- What a Tailscale node's status holds, and what can be asked for it,
--- apart from the client that asks: [`cosmic.tailscale`]'s client is a
--- [`node.Source`], and its `status` returns a [`node.Status`]. A
--- module that reads a status, such as [`cosmic.sandbox.tailnet`], takes
--- a source and requires only this, not the client with its HTTP, TLS and
--- JSON.
--- @public

local type Failure = require("cosmic.failure")

local record node
  --- A user of the tailnet, as the control server names them.
  record User
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

  --- A peer of this node, or the node itself, as a status lists it.
  record Peer
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

  --- The node's status: what a [`Source`] returns.
  record Status
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
    --- Whether MagicDNS resolves names on this node.
    magic_dns: boolean
    --- The names the node can get a certificate for.
    cert_domains: {string}
    --- Every peer, by `dns_name` and then `id`.
    peers: {Peer}
    --- The users of `self` and every peer, by [`User.id`].
    users: {integer: User}
  end

  --- What can be asked for a node's status: [`cosmic.tailscale`]'s
  --- client, or a stand-in a test makes.
  interface Source
    --- The node's status, or nil and a Failure.
    status: function(Source): (Status) | (nil, Failure)
  end
end

return node
