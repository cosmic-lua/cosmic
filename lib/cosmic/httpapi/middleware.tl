--- Middleware chaining for HTTP request/response pipeline.
--- Composes a list of middleware functions with a final handler into
--- a single handler. Middleware runs in list order (first added = outermost).
local request_mod = require("cosmic.httpapi.request")
local response_mod = require("cosmic.httpapi.response")
local types = require("cosmic.httpapi.types")

local type Handler = types.Handler
local type Middleware = types.Middleware

--- Compose middleware and a handler into a single handler.
--- Middleware runs in order: first in the list wraps outermost.
---
--- Example:
---   local h = chain({logging, auth}, my_handler)
---   -- Executes: logging -> auth -> my_handler -> auth -> logging
---
--- @param middlewares {Middleware} List of middleware functions
--- @param handler Handler Final request handler
--- @return Handler Composed handler
local function chain(middlewares: {Middleware}, handler: Handler): Handler
  local h = handler
  for i = #middlewares, 1, -1 do
    local mw = middlewares[i]
    local nxt = h
    h = function(req: request_mod.Request): response_mod.Response
      return mw(req, nxt)
    end
  end
  return h
end

return {
  Handler = Handler,
  Middleware = Middleware,
  chain = chain,
}
