--- Errors: the exception layer that turns a raise into a response, the error
--- pages, and the terminal that answers what the router could not route.

local Html = require("cosmic.html")
local Response = require("cosmic.web.response")
local Server = require("cosmic.http.server")
local Types = require("cosmic.web.types")
local errors = require("cosmic.internal.errors")

local record Errors
end

--- The media types an error page can be made in, best first: a client that
--- asks for nothing in particular is given HTML.
local OFFERS <const>: {string} = { "text/html", "application/json", "application/problem+json" }

--- "404 Not Found".
local function title_of(status: integer): string
  local reason = Server.reason(status)
  return reason ~= "" and ("%d %s"):format(status, reason) or tostring(status)
end

--- A small page for `status`, holding `detail` and `trace` escaped.
local function page(status: integer, detail: string?, trace: string?): Types.Response
  local title = title_of(status)
  local parts: mut {Html.SafeHtml} = {
    Html.trust('<!doctype html><html lang="en"><head><meta charset="utf-8"><title>'),
    Html.escape(title), Html.trust("</title></head><body><h1>"), Html.escape(title),
    Html.trust("</h1>"),
  }
  if detail ~= nil and detail ~= "" then
    parts[#parts + 1] = Html.trust("<p>")
    parts[#parts + 1] = Html.escape(detail)
    parts[#parts + 1] = Html.trust("</p>")
  end
  if trace ~= nil then
    parts[#parts + 1] = Html.trust("<p>debug is on: this page shows the fault and its stack</p><pre>")
    parts[#parts + 1] = Html.escape(trace)
    parts[#parts + 1] = Html.trust("</pre>")
  end
  parts[#parts + 1] = Html.trust("</body></html>")
  return Response.html(Html.concat(parts), { status = status })
end

--- Whether the request prefers JSON to a page.
local function wants_json(req: Types.Request): boolean
  local choice = req:accepts(OFFERS)
  return choice == "application/json" or choice == "application/problem+json"
end

--- The default answer: a problem body for a client that prefers JSON, else
--- a page.
local function default_answer(req: Types.Request, status: integer, detail: string?,
                              extra: {string:any}?): Types.Response
  if wants_json(req) then return Response.problem(status, detail, extra) end
  return page(status, detail, nil)
end

--- The answer for `status`: the app's `error_pages` entry, else its
--- `error_view`, else the default one chosen by the request's Accept;
--- `headers` (an `Allow`) are set on it.
local function respond(req: Types.Request, status: integer, detail?: string,
                       extra?: {string:any}, headers?: {string:string}): Types.Response
  local spec = req.app.spec
  local res: Types.Response
  local error_pages = spec.error_pages
  local custom = error_pages ~= nil and error_pages[status] or nil
  local error_view = spec.error_view
  if custom ~= nil then
    res = custom(req)
  elseif error_view ~= nil then
    res = error_view(req, status, detail or "")
  else
    res = default_answer(req, status, detail, extra)
  end
  for name, value in pairs(headers or {}) do Response.set_header(res, name, value) end
  return res
end

--- Answers a request the router did not send to a route, by what it
--- decided: 404, 405 with `Allow`, the automatic OPTIONS, a redirect to
--- the canonical spelling, or 400.
--- @param req Types.Request The request, whose `outcome` says what to answer
--- @return Types.Response The response
function Errors.terminal(req: Types.Request): Types.Response
  local outcome = assert(req.outcome)
  local kind = outcome.kind
  if kind == "not_allowed" then
    return respond(req, 405, nil, nil, { Allow = assert(outcome.allow) })
  elseif kind == "options" then
    return Response.empty(204, { headers = { Allow = assert(outcome.allow) } })
  elseif kind == "redirect" then
    local location = assert(outcome.location)
    if req.query_string ~= "" then location = location .. "?" .. req.query_string end
    return Response.redirect(location, { status = 308 })
  elseif kind == "bad_path" or kind == "bad_host" then
    return respond(req, 400, outcome.detail)
  end
  return respond(req, 404)
end

--- What a raise leaves for the handler of `xpcall`: an abort as it is, any
--- other raise as its message and stack.
local function traced(err: any): any
  if Response.aborted(err) ~= nil then return err end
  -- A layer below has traced it: the first stack is the one that matters.
  if err is string and err:find("\nstack traceback:", 1, true) ~= nil then return err end
  return errors.trace(tostring(err), 2)
end

--- The response for the fault `trace`, which `req` raised.
local function fault(req: Types.Request, trace: string): Types.Response
  local spec = req.app.spec
  assert(req.app.spec.sink):line(("%s %s: %s"):format(req.method, req.path, trace))
  if spec.debug == true then
    local message = trace:match("^[^\n]*") or trace
    if wants_json(req) then
      return Response.problem(500, message, { trace = trace })
    end
    return page(500, message, trace)
  end
  local ok, res = pcall(respond, req, 500)
  if ok then return res end
  return Response.text("Internal Server Error\n", { status = 500 })
end

--- The answer for `abort`, which `req` raised: the error page of its
--- status. A 5xx goes to the sink too.
local function answer_abort(req: Types.Request, abort: Response.Abort): Types.Response
  if abort.status >= 500 then
    assert(req.app.spec.sink):line(("%s %s: aborted %d: %s"):format(req.method, req.path, abort.status,
      abort.detail or ""))
  end
  local answered, answer = pcall(respond, req, abort.status, abort.detail, abort.extra)
  if answered then return answer end
  return fault(req, tostring(answer))
end

--- `inner` with the exception layer around it: an abort is answered with
--- the error page of its status, any other raise with a 500 whose body
--- tells the client nothing (a page of the fault and its stack when the
--- app is in debug), and the fault goes to the app's sink. In debug a
--- response the server would refuse is a fault too, so its trace names
--- the handler.
--- @param inner Types.Handler The handler to guard
--- @return Types.Handler The guarded handler
function Errors.wrap(inner: Types.Handler): Types.Handler
  return function(req: Types.Request): Types.Response
    local ok, res = xpcall(inner, traced, req)
    if ok then
      if req.app.spec.debug == true then
        -- The server's own words for an answer that is no reply (see
        -- `reply_trouble` in cosmic/http/server.tl).
        local trouble: string
        if res == nil then
          trouble = "the handler answered nil, not a Server.Reply"
        else
          trouble = Server.check(res, req.method)
        end
        if trouble ~= "" then
          return fault(req, "web: the handler's response cannot be sent: " .. trouble)
        end
      end
      return res
    end
    local abort = Response.aborted(res)
    if abort == nil then return fault(req, tostring(res)) end
    return answer_abort(req, abort)
  end
end

--- `inner` with an abort answered where it is raised, for a layer of
--- middleware: [`Web.abort`] from a middleware becomes the error page of its
--- status, as a response the middleware outside it sees, so an access log
--- or a header it adds covers it. Any other raise passes on with its
--- stack, for the exception layer or the server to answer 500, as before.
--- @param inner Types.Handler One middleware's handler
--- @return Types.Handler The guarded handler
function Errors.guard(inner: Types.Handler): Types.Handler
  return function(req: Types.Request): Types.Response
    local ok, res = xpcall(inner, traced, req)
    if ok then return res end
    local abort = Response.aborted(res)
    if abort == nil then error(res, 0) end
    return answer_abort(req, abort)
  end
end

return Errors
