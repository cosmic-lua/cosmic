--- A connector pair and a bound port, read from the raw tables a test calls the C bindings of itself.
local type raw_socket = require("cosmic.internal.socket")

local record connector_ends
  --- The two descriptors of a connector pair: the controller's, which asks and is answered, and the connector's, which
  --- the connector is started on.
  record Ends
    controller: integer
    connector: integer
  end
  --- The two descriptors of `pair`, a connector pair ([`cosmic.internal.process`]'s [`connector_pair`]): the controller's
  --- first, the connector's second. Raises where `pair` holds fewer. It makes one small table for its answer, so a test
  --- that fails allocations holds a pair with it only once allocations are allowed again.
  pair_ends: function(pair: {integer}): connector_ends.Ends
  --- A new connector pair, made by the process table, as its two ends. Raises where the core cannot make one. A test
  --- that fails allocations makes the pair by the table itself and holds it with [`pair_ends`].
  connector_pair: function(): connector_ends.Ends
  --- The port the kernel gave `bound`, a socket that listens or was accepted. Raises where it has none.
  bound_port: function(bound: raw_socket.Socket): integer
end

function connector_ends.pair_ends(pair: {integer}): connector_ends.Ends
  local controller, connector = pair[1], pair[2]
  assert(controller and connector, "a connector pair holds two descriptors")
  return { controller = controller, connector = connector }
end

function connector_ends.connector_pair(): connector_ends.Ends
  local pair = assert(require("cosmic.internal.process").connector_pair())
  return connector_ends.pair_ends(pair)
end

function connector_ends.bound_port(bound: raw_socket.Socket): integer
  local address = assert(require("cosmic.internal.socket").bound(bound:fd()))
  local port = assert(address.port, "a bound TCP socket has a port")
  return port
end

return connector_ends
