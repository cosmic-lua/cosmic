--- [`cosmic.web.static`] serving a precompressed variant over a socket:
--- the codings on the wire, and that a server compressing replies
--- ([`Server.ServeSpec.compress`]) leaves a reply that is already coded as
--- it is.

local Assets = require("cosmic.web.assets")
local Clock = require("cosmic.clock")
local Compress = require("cosmic.compress")
local Net = require("cosmic.net")
local Server = require("cosmic.http.server")
local StaticFiles = require("cosmic.web.static")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
local Web = require("cosmic.web")

Test.policy{ loopback = { "127.0.0.1" } }

local CSS <const> = ("a { color: red }\n"):rep(200)

local function app_of(): Web.App
  local source = Assets.memory({ ["css/app.css"] = CSS }, { gzip = true, zstd = true })
  return Web.app{ routes = { StaticFiles.mount("/static", { source = source }) } }
end

--- `body` expanded from `coding`, as a client would.
local function expanded(coding: string?, body: string): string
  if coding == "zstd" then
    local out = assert(Stream.run(assert(Compress.zstd_decoder()), body))
    return out
  elseif coding == "gzip" then
    local out = assert(Compress.inflate("gzip", body))
    return out
  end
  return body
end

local function test_the_coding_on_the_wire_follows_accept_encoding()
  Web.with_server(app_of(), function(client: Web.LoopbackClient)
    local function fetch(accept: string?, extra?: {string:string}): Web.TestResponse
      local headers: mut {string:string} = {}
      for name, value in pairs(extra or {}) do headers[name] = value end
      if accept ~= nil then headers["Accept-Encoding"] = accept end
      local res = assert(client:get("/static/css/app.css", { headers = headers }))
      return res
    end
    local cases: {string: string} = {
      ["zstd, gzip"] = "zstd", ["gzip"] = "gzip", ["gzip;q=0.9, zstd;q=0.1"] = "gzip",
      ["zstd;q=0, gzip"] = "gzip", ["*"] = "zstd", ["br"] = "", ["identity"] = "",
    }
    for accept, want in pairs(cases) do
      local res = fetch(accept)
      local coding: string? = if want == "" then nil else want end
      assert(res.status == 200 and res.headers["content-encoding"] == coding, accept)
      assert(res.headers["vary"] == "Accept-Encoding", accept)
      assert(res.headers["content-length"] == tostring(#res.body), accept)
      assert(expanded(coding, res.body) == CSS, accept)
    end
    local bare = fetch(nil)
    assert(bare.body == CSS and bare.headers["content-encoding"] == nil)
    local head = assert(client:head("/static/css/app.css", { headers = { ["Accept-Encoding"] = "zstd" } }))
    local get = fetch("zstd")
    assert(head.body == "" and head.headers["content-encoding"] == "zstd")
    assert(head.headers["content-length"] == get.headers["content-length"])
    assert(head.headers["etag"] == get.headers["etag"])
    local ranged = fetch("zstd, gzip", { Range = "bytes=0-4" })
    assert(ranged.status == 206 and ranged.body == CSS:sub(1, 5))
    assert(ranged.headers["content-encoding"] == nil)
  end)
end

--- The head and body of the one reply to `request`, read to the end of the
--- connection.
local function exchange(address: Net.Address, request: string): string, string
  local conn = assert(Net.connect(address, { timeout_ns = Clock.seconds(5) }))
  assert(conn:write(request))
  local parts: mut {string} = {}
  while true do
    local piece, why = conn:read()
    if piece == nil then
      assert(why == "", "reading: " .. why)
      break
    end
    parts[#parts + 1] = piece
  end
  local _, _ = conn:close()
  local text = table.concat(parts)
  local split = assert(text:find("\r\n\r\n", 1, true), "no head")
  return text:sub(1, split - 1), text:sub(split + 4)
end

--- A server that compresses replies is handed a stored variant: the reply
--- is the stored bytes under the coding the client chose, once, not
--- compressed again, and a plain one is compressed by the server as before.
local function test_a_precompressed_reply_is_not_compressed_again_by_the_server()
  local app = app_of()
  local plain = Assets.memory({ ["notes.txt"] = CSS })
  local other = Web.app{ routes = { StaticFiles.mount("/static", { source = plain }) } }
  local source = assert(Assets.memory({ ["css/app.css"] = CSS }, { zstd = true }):get("css/app.css"))
  local troubles: mut {string} = {}
  local function check(handle: function(Server.Request): Server.Reply, path: string, accept: string,
                       want: string?, body: string)
    local failed = false
    assert(Server.serve({
      listeners = { Net.tcp("127.0.0.1", 0) }, handle = handle, compress = true,
      on_error = function(trouble: string) troubles[#troubles + 1] = trouble end,
      on_ready = function(addresses: {Net.Address}, server: Net.Server)
        local head, got = exchange(assert(addresses[1]),
          "GET " .. path .. " HTTP/1.1\r\nHost: t\r\nConnection: close\r\nAccept-Encoding: " .. accept ..
            "\r\n\r\n")
        local coding = head:lower():match("\r\ncontent%-encoding: ([^\r]*)")
        failed = not (coding == want and expanded(coding, got) == body)
        if want == "zstd" then failed = failed or got ~= source.zstd end
        server:stop()
      end,
    }))
    assert(not failed, path .. " as " .. accept)
  end
  check(app.handle, "/static/css/app.css", "zstd, gzip", "zstd", CSS)
  check(app.handle, "/static/css/app.css", "gzip", "gzip", CSS)
  check(other.handle, "/static/notes.txt", "gzip", "gzip", CSS)
  assert(#troubles == 0, troubles[1])
end
