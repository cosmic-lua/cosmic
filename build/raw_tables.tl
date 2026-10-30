--- Typed access to the raw tables the core hands a module's loader.
---
--- core/store.c hands each wrapper of its `raw_modules` the C table behind
--- it ([`cosmic.internal.process`] to [`cosmic.child`], say) as the `extra`
--- value of the store's searcher, and `require` passes it on to the
--- loader. A test or a tool that calls the C bindings itself asks the
--- searchers for it by hand, which is no escalation: the table reaches
--- nothing the wrapper does not already. The searchers answer it only for
--- a module of the caller's closure, so a caller requires the wrapper:
---
---     local _ = require("cosmic.child")
---     local process = RawTables.process()
---
--- The searchers hand it back untyped. This module is the one place it is
--- checked and given its type: each accessor refuses, naming the wrapper
--- and what it lacked, a wrapper handed no table, a table with a key that
--- is no name, and a table that lacks the members it is asked to be a
--- table of. The members are a few of each declaration, enough to tell the
--- tables apart and to catch a wrapper handed another's; that the rest of
--- a declaration matches the core is core/declarations_test.tl's to hold.
--- What an accessor answers is the very table the loader is handed, not a
--- copy: a test that replaces a member of it ([`build.confine`]'s `spawn`,
--- say) replaces it for the module too. No `as` stands behind the type, only
--- [`cosmic.shape`]'s `into`, which the checks above precede.
---
--- A module that needs the table of a wrapper not named here names it:
--- `process("build.confine")`.
local Shape = require("cosmic.shape")
local type raw_hash = require("cosmic.internal.hash")
local type raw_process = require("cosmic.internal.process")
local type raw_socket = require("cosmic.internal.socket")

local record raw_tables
  --- The two descriptors of a connector pair: the controller's, which asks and is answered, and the connector's, which
  --- the connector is started on.
  record Ends
    controller: integer
    connector: integer
  end
  --- The table core/store.c hands `wrapper`'s loader, by name. A reflection
  --- test reads the members of a table no declaration describes through
  --- it. Raises where `wrapper` is handed no table or one with a key that
  --- is no name.
  fields: function(wrapper: string): {string: any}
  --- The two descriptors of `pair`, a connector pair ([`cosmic.internal.process`]'s [`connector_pair`]): the controller's
  --- first, the connector's second. Raises where `pair` holds fewer. It allocates nothing but its results' frames, so it
  --- may run in a walk that fails allocations once the pair is made.
  pair_ends: function(pair: {integer}): raw_tables.Ends
  --- A new connector pair, made by `wrapper`'s process table ([`cosmic.child`]'s by default), as its two ends. Raises
  --- where the core cannot make one. It looks the table up on each call, so a test that fails allocations makes the
  --- pair by the table itself and holds it with [`pair_ends`].
  connector_pair: function(wrapper?: string): raw_tables.Ends
  --- The port the kernel gave `bound`, a socket that listens or was accepted. Raises where it has none.
  bound_port: function(bound: raw_socket.Socket): integer
  --- The hash table (cosmic/internal/hash.d.tl) handed `wrapper`, [`cosmic.hash`]'s
  --- by default.
  hash: function(wrapper?: string): raw_hash
  --- The process table (core/process.h) handed `wrapper`, [`cosmic.child`]'s
  --- by default.
  process: function(wrapper?: string): raw_process
  --- The socket table (core/socket.h) handed `wrapper`, [`cosmic.net`]'s by
  --- default.
  socket: function(wrapper?: string): raw_socket
end

--- A table whose keys are all names, whatever it holds: `into` answers a copy of it, which a check can read by name.
--- `optional` lets the value [`Json.null`] (the raw json table holds it) through, which the copy leaves out.
local NAMED <const> = Shape.map(Shape.optional(Shape.any))

--- The table the store's searchers hand `wrapper`'s loader, as the `T` the caller names, which holds a function for
--- each of `required`: the members that tell this table from another's. It is the very table the loader is handed, not
--- a copy: a test that replaces a member of it replaces it for the module too.
local function table_behind<T>(wrapper: string, required: {string}): T
  for _, searcher in ipairs(package.searchers) do
    local loader, extra = searcher(wrapper)
    if type(loader) == "function" and type(extra) == "table" then
      local named, why: {string: any}?, string = Shape.into(extra, NAMED)
      assert(named, wrapper .. " is handed a raw table that is no table of the core's: " .. why)
      for _, name in ipairs(required) do
        if type(named[name]) ~= "function" then
          error(wrapper .. " is handed a raw table with no function `" .. name .. "`: it is another wrapper's " ..
              "table, or the core is another build")
        end
      end
      -- [`Shape.any`] checks nothing and copies nothing: the checks are the ones above.
      local same, _: T?, string = Shape.into(extra, Shape.any)
      return (assert(same, "a table is no missing value, which is all `Shape.any` refuses"))
    end
  end
  error(wrapper .. " is handed no raw table: the store's searchers give one only for a module of the closure, " ..
      "so require " .. wrapper .. " at the top of the file, as `local _ = require(\"" .. wrapper .. "\")`")
end

function raw_tables.fields(wrapper: string): {string: any}
  return table_behind(wrapper, {})
end

function raw_tables.pair_ends(pair: {integer}): raw_tables.Ends
  local controller, connector = pair[1], pair[2]
  assert(controller and connector, "a connector pair holds two descriptors")
  return { controller = controller, connector = connector }
end

function raw_tables.connector_pair(wrapper?: string): raw_tables.Ends
  local pair = assert(raw_tables.process(wrapper).connector_pair())
  return raw_tables.pair_ends(pair)
end

function raw_tables.bound_port(bound: raw_socket.Socket): integer
  local address = assert(raw_tables.socket().bound(bound:fd()))
  local port = assert(address.port, "a bound TCP socket has a port")
  return port
end

function raw_tables.hash(wrapper?: string): raw_hash
  return table_behind(wrapper or "cosmic.hash", { "digest", "hmac", "equal" })
end

function raw_tables.process(wrapper?: string): raw_process
  return table_behind(wrapper or "cosmic.child", { "spawn", "landlock_abi", "user" })
end

function raw_tables.socket(wrapper?: string): raw_socket
  return table_behind(wrapper or "cosmic.net", { "listen", "datagram", "connect" })
end

return raw_tables
