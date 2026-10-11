--- Middleware: how a stack of them is folded around a handler, the sink an
--- app writes its lines to, and the access log.

local Clock = require("cosmic.clock")
local Errors = require("cosmic.web.errors")
local Log = require("cosmic.log")
local Types = require("cosmic.web.types")

local record Middleware
  --- What [`Web.access_log`] takes; every field is optional.
  record AccessLogOptions
    --- Where the lines go; the app's own sink by default.
    sink?: Types.Sink
    --- Makes the line from the request, the response and the time the
    --- handler took in nanoseconds, in place of the default.
    format: function(Types.Request, Types.Response, integer): string
    --- Whether to leave a request out of the log.
    skip: function(Types.Request): boolean
    --- Log the query string too (false): a token in a query would be
    --- written down.
    log_query?: boolean
  end
end

--- `handler` with `stack` folded around it: the first of `stack` is
--- outermost, as it sees the request first and the response last. A
--- [`Web.abort`] raised by a middleware or by what is below it is answered
--- at that layer, so the middleware outside it sees the error page as a
--- response (any other raise passes through).
--- @param stack {Types.Middleware} The middleware, outermost first
--- @param handler Types.Handler The handler they wrap
--- @return Types.Handler The wrapped handler
function Middleware.compose(stack: {Types.Middleware}, handler: Types.Handler): Types.Handler
  local composed = handler
  for i = #stack, 1, -1 do
    composed = Errors.guard(stack[i](composed))
  end
  return composed
end

--- A sink that writes each line to standard error under `name`.
--- @param name string | nil The program's name ("web" by default)
--- @return Types.Sink The sink
function Middleware.stderr_sink(name?: string): Types.Sink
  local logger = Log.new(name or "web")
  return { line = function(_self: Types.Sink, text: string) logger:complain(text) end }
end

--- The size of `res`'s body for a log line: bytes, or "stream".
local function size_of(res: Types.Response): string
  local body = res.body
  local n: integer = 0
  if body is string then
    n = #body
  elseif body ~= nil then
    return "stream"
  else
    n = res.length or 0
  end
  if n < 1024 then return ("%dB"):format(n) end
  if n < 1024 * 1024 then return ("%.1fKB"):format(n / 1024) end
  return ("%.1fMB"):format(n / (1024 * 1024))
end

-- TODO: Web.timing, Web.request_id and Web.limit_body (doc/plans/web/core.md
-- section 7.2) once a part of the plan needs one: request ids with the CSP
-- nonce and sessions, the body limit with Server.ServeSpec.body_limit.

--- Writes one line per request once its response is made:
--- `GET /items/42 200 3ms 1.2KB client=127.0.0.1`. The query string is
--- left out unless `log_query` asks for it. It sits where the app puts it,
--- first to time and see everything, including the router's 404s.
--- @param opts AccessLogOptions | nil What to log and where
--- @return Types.Middleware The middleware
function Middleware.access_log(opts?: Middleware.AccessLogOptions): Types.Middleware
  opts = opts or {}
  return function(inner: Types.Handler): Types.Handler
    return function(req: Types.Request): Types.Response
      if opts.skip ~= nil and opts.skip(req) then return inner(req) end
      local started = Clock.monotonic_ns()
      local res = inner(req)
      local elapsed = Clock.monotonic_ns() - started
      local sink = opts.sink or assert(req.app.spec.sink)
      local line: string
      if opts.format ~= nil then
        line = opts.format(req, res, elapsed)
      else
        local path = req.path
        if opts.log_query and req.query_string ~= "" then
          -- A client chooses the query: no control byte may split the line.
          path = path .. "?" .. req.query_string:gsub("[%z\1-\31\127]", function(byte: string): string
            return ("%%%02X"):format(byte:byte())
          end)
        end
        line = ("%s %s %d %dms %s client=%s"):format(req.method, path, res.status,
          elapsed // 1000000, size_of(res), req.client and req.client.host or "-")
      end
      sink:line(line)
      return res
    end
  end
end

return Middleware
