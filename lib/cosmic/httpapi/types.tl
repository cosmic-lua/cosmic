--- Shared type definitions for the httpapi framework.
local request_mod = require("cosmic.httpapi.request")
local response_mod = require("cosmic.httpapi.response")

--- Request handler function.
local type Handler = function(request_mod.Request): response_mod.Response

  --- Middleware function that wraps a handler.
  local type Middleware = function(request_mod.Request, Handler): response_mod.Response

    return {
      Handler = Handler,
      Middleware = Middleware,
    }
