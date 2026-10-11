--- Fuzz properties for the router's path handling, which reads paths a
--- client chose: canonicalising never raises and is idempotent, a lookup
--- is total on any path, and every redirect it makes leads to a path of
--- one leading "/" that is not itself sent on again.

local Fuzz = require("build.fuzz")
local Router = require("cosmic.web.router")
local Server = require("cosmic.http.server")
local Stream = require("cosmic.stream")
local Web = require("cosmic.web")

--- Pieces of a path that reach routes.
local GOOD <const>: {string} = { "items", "7", "new", "api", "v1", "ping", "static", "a", "docs", "x%20y", "é",
  "evil.com", "~", "%7e" }

--- Pieces that climb, hide a separator, or are not text.
local BAD <const>: {string} = { ".", "..", "%2e", "%2E%2e", "", "%2f", "%2F", "%00", "%zz", "%", "\\", "?" }

--- A path drawn from the pieces, with extra slashes and a trailing one at times.
local function gen_path(src: Fuzz.Source): string
  local parts: {string} = {}
  while Fuzz.more(src, #parts, 5) do
    local kind = src:int(0, 11)
    if kind == 0 then
      parts[#parts + 1] = Fuzz.pick(src, BAD)
    elseif kind == 1 then
      parts[#parts + 1] = Fuzz.bytes(src, 6)
    else
      parts[#parts + 1] = Fuzz.pick(src, GOOD)
    end
  end
  local lead = ("/"):rep(src:int(0, 7) == 0 and src:int(2, 3) or 1)
  local tail = src:int(0, 3) == 0 and "/" or ""
  return lead .. table.concat(parts, "/") .. tail
end

local function ok(_req: Web.Request): Web.Response
  return Web.text("ok")
end

local router = Web.router({
  Web.get("/", ok), Web.get("/items", ok), Web.get("/items/new", ok), Web.get("/items/:id", ok),
  Web.post("/items/:id", ok), Web.get("/docs/", ok), Web.get("/static/*path", ok),
  Web.mount("/api", { Web.get("/", ok), Web.get("/items/:id", ok),
    Web.mount("/v1", { Web.get("/ping", ok) }) }),
  Web.mount_handler("/legacy", ok),
})

local KINDS <const>: {string:boolean} = { match = true, not_found = true, not_allowed = true, options = true,
  redirect = true, bad_path = true, bad_host = true }

local function test_canonical_never_raises_and_is_idempotent(tmp: string)
  Fuzz.run({
    name = "web canonical path",
    dir = tmp,
    gen = gen_path,
    requires = { "canonical", "refused", "changed" },
    shares = { canonical = 0.2, refused = 0.03 },
    check = function(input: string): boolean, string
      local canon, why = Router.canonical(input)
      if canon == nil then
        if not why:find("^url: ") then return false, "refused with " .. why end
        Fuzz.label("refused")
        return true, ""
      end
      if canon.path:sub(1, 1) ~= "/" or canon.path:sub(2, 2) == "/" then
        return false, ("canonical path %q has not one leading slash"):format(canon.path)
      end
      for _, segment in ipairs(canon.segments) do
        if segment == "" or segment == "." or segment == ".." or segment:find("[/%z]") then
          return false, ("segment %q"):format(segment)
        end
      end
      local again, again_why = Router.canonical(canon.path)
      if again == nil then
        return false, ("the canonical path %q is refused: %s"):format(canon.path, again_why)
      end
      if again.path ~= canon.path or again.changed or again.trailing ~= canon.trailing then
        return false, ("%q is canonical as %q, but that is %q (changed %s)"):format(input, canon.path,
          again.path, tostring(again.changed))
      end
      if #again.segments ~= #canon.segments then
        return false, "segments differ on the second pass"
      end
      Fuzz.label("canonical")
      if canon.changed then Fuzz.label("changed") end
      return true, ""
    end,
  })
end

local function test_lookup_is_total_and_redirects_stay_local(tmp: string)
  Fuzz.run({
    name = "web router lookup",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      return Fuzz.pack({ Fuzz.pick(src, { "GET", "HEAD", "POST", "OPTIONS", "PUT" }), gen_path(src) })
    end,
    requires = { "match", "redirect", "bad_path", "not_found", "not_allowed" },
    shares = { match = 0.05, not_found = 0.05 },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local method, path = fields[1], fields[2]
      local outcome = router:match(method, path)
      if not KINDS[outcome.kind] then return false, "kind " .. tostring(outcome.kind) end
      Fuzz.label(outcome.kind)
      if outcome.kind == "match" then
        for name, value in pairs(outcome.params) do
          if value == "" and name == "id" then return false, "an empty :id" end
        end
      elseif outcome.kind == "redirect" then
        local location = outcome.location
        if location:sub(1, 1) ~= "/" or location:sub(2, 2) == "/" or location:find("[%z\1-\31\127\\]") then
          return false, ("redirect to %q"):format(location)
        end
        local next_outcome = router:match(method, location)
        if next_outcome.kind == "bad_path" then
          return false, "the redirect leads to a refused path"
        end
        if next_outcome.kind == "redirect" then
          if router:match(method, next_outcome.location).kind == "redirect" then
            return false, ("redirects chain from %q through %q"):format(path, location)
          end
        end
      elseif outcome.kind == "not_allowed" or outcome.kind == "options" then
        if not outcome.allow:find("OPTIONS", 1, true) then return false, "Allow lacks OPTIONS" end
      end
      return true, ""
    end,
  })
end

local function test_the_app_answers_any_path_with_a_sane_status(tmp: string)
  local app = Web.app{ routes = {
    Web.get("/items/:id", ok), Web.get("/docs/", ok), Web.mount("/api", { Web.get("/x", ok) }),
  }, sink = { line = function(_self: Web.Sink, _text: string) end } }
  Fuzz.run({
    name = "web app path",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      if src:int(0, 2) == 0 then
        return Fuzz.pick(src, { "/items/7", "/docs/", "/api/x", "/items/a%20b" })
      end
      return gen_path(src)
    end,
    requires = { "ok", "redirect", "refused" },
    shares = { ok = 0.1, redirect = 0.05 },
    check = function(input: string): boolean, string
      local raw: Server.Request = { method = "GET", target = input, path = input, query = "", version = "HTTP/1.1",
        headers = { host = "x" }, body = Stream.from_string(""), length = 0 }
      local res = app.handle(raw)
      if res.status ~= 200 and res.status ~= 308 and res.status ~= 400 and res.status ~= 404 then
        return false, ("%q answered %d"):format(input, res.status)
      end
      local location = Web.header(res, "Location")
      if res.status == 308 then
        Fuzz.label("redirect")
        if location == nil or location:sub(1, 1) ~= "/" or location:sub(2, 2) == "/" then
          return false, ("%q redirected to %s"):format(input, tostring(location))
        end
      elseif res.status == 400 then
        Fuzz.label("refused")
      elseif res.status == 200 then
        Fuzz.label("ok")
      end
      if location ~= nil and res.status ~= 308 then
        return false, "a Location beside " .. res.status
      end
      return true, ""
    end,
  })
end
