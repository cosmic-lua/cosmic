--- Serves the files of an [`Assets.Source`] (the project's `static/`,
--- embedded in the executable, or a directory in development) over GET
--- and HEAD: strong ETags from the content hash, `If-None-Match`,
--- `If-Modified-Since` where the source has times, `Range` with
--- `If-Range`, stored zstd and gzip variants, and fingerprinted names
--- (`/static/css/app.3f9a1c8e2b.css`) that are cached for a year.
---
---     local StaticFiles = require("cosmic.web.static")
---
---     local app = Web.app{ routes = {
---       StaticFiles.mount("/static"),   -- named "static"
---       Web.get("/", home),
---     } }
---     -- app:url_for("static", { path = "css/app.css" }) is
---     -- "/static/css/app.3f9a1c8e2b.css", the name for a template's `href`
---
--- A request is answered from the file it names and no other: a segment
--- that is empty, `.` or `..`, begins with `.`, or holds a backslash or a
--- NUL is a 404, so a dotfile and a path out of the root are never read; a
--- directory has no listing. Everything below `static/` is public: put
--- nothing private there.

local Assets = require("cosmic.web.assets")
local Mime = require("cosmic.mime")
local Response = require("cosmic.web.response")
local Route = require("cosmic.web.route")
local Server = require("cosmic.http.server")
local Time = require("cosmic.time")
local Types = require("cosmic.web.types")
local Url = require("cosmic.url")

local record StaticFiles
  --- What [`StaticFiles.handler`] and [`StaticFiles.mount`] take.
  record Options
    --- Where the files come from; nil for [`Assets.default`].
    mut source?: Assets.Source
    --- Cache-Control of a file requested by its plain name (default
    --- "public, no-cache": cached, but revalidated by ETag every time).
    cache_control?: string
    --- Cache-Control of a fingerprinted name (default "public,
    --- max-age=31536000, immutable").
    immutable_control?: string
    --- Serve `index.html` for a directory ("/docs/" is docs/index.html,
    --- and "/docs" redirects to "/docs/"); default false, where a
    --- directory is a 404.
    html?: boolean
    --- Answers a path no file has (default: a 404 through the app's error
    --- page). A stale fingerprint is never answered by it.
    not_found?: Types.Handler
    --- Added to every 200, 206, 304 and 416, replacing a header of the
    --- same name.
    headers?: {string:string}
    --- Serve the source's gzip variant; default true. `false` never
    --- serves it.
    gzip?: boolean
    --- Serve the source's zstd variant; default true. `false` never serves
    --- it. With both, the client's Accept-Encoding chooses
    --- ([`Server.encoding`]: zstd on a tie), and with neither it gets the
    --- plain bytes.
    zstd?: boolean
  end
end

local DEFAULT_CACHE <const> = "public, no-cache"
local DEFAULT_IMMUTABLE <const> = "public, max-age=31536000, immutable"
local MAX_PATH <const> = 255
local NS <const> = 1000000000

local HEX10 <const> = ("[0-9a-f]"):rep(10)

--- A fingerprinted name taken apart.
local record Parts
  --- The path with the digits left out: "css/app.css".
  plain: string
  --- The ten hex digits.
  digits: string
end

--- The asset path a fingerprinted `rel` stands for, with its digits:
--- "css/app.3f9a1c8e2b.css" is "css/app.css" and "3f9a1c8e2b"; nil for a
--- name that is not one.
local function unfingerprint(rel: string): Parts?
  local dir, name = rel:match("^(.-)([^/]+)$")
  if dir == nil or name == nil then return nil end
  local stem, digits, ext = name:match("^(.+)%.(" .. HEX10 .. ")(%.[^.]+)$")
  if stem == nil then
    stem, digits = name:match("^(.+)%.(" .. HEX10 .. ")$")
    ext = ""
  end
  if stem == nil or digits == nil or ext == nil then return nil end
  return { plain = dir .. stem .. ext, digits = digits }
end

--- The fingerprinted spelling of `path`, an asset with this `sha256`:
--- "css/app.css" is "css/app.3f9a1c8e2b.css", and a name with no
--- extension takes the digits as one.
local function fingerprinted(path: string, sha256: string): string
  local digits = sha256:sub(1, 10)
  local dir, name = path:match("^(.-)([^/]+)$")
  if dir == nil or name == nil then
    error(("static: cannot fingerprint %q, which names no file"):format(path), 2)
  end
  local stem, ext = name:match("^(.+)(%.[^.]+)$")
  if stem == nil or ext == nil then return dir .. name .. "." .. digits end
  return dir .. stem .. "." .. digits .. ext
end

--- The number of segments in a mount's prefix.
local function depth(mount_path: string): integer
  local n = 0
  for _ in mount_path:gmatch("[^/]+") do n = n + 1 end
  return n
end

--- Whether a segment can name a file: not empty, `.`, `..` or a
--- dotfile, with no backslash, NUL or "/".
local function servable(segment: string): boolean
  return segment ~= "" and segment:sub(1, 1) ~= "." and not segment:find("[\0\\/]")
end

--- The path under the mount, "css/app.css", or nil for a request that
--- names no file; "" for the mount's root.
local function relative(req: Types.Request): string?
  local parts: mut {string} = {}
  for i = depth(req.mount_path) + 1, #req.segments do
    local segment = req.segments[i]
    if segment == nil or not servable(segment) then return nil end
    parts[#parts + 1] = segment
  end
  local rel = table.concat(parts, "/")
  if #rel > MAX_PATH then return nil end
  return rel
end

--- The coding `asset` is sent in for Accept-Encoding `header`: "zstd" or
--- "gzip" when the asset holds that variant, `zstd` or `gzip` allow it and
--- [`Server.encoding`] picks it by the client's q-values (zstd first on a
--- tie); nil for the plain bytes, which is also the answer where the client
--- takes none of them.
local function coding_of(asset: Assets.Asset, header: string?, zstd: boolean, gzip: boolean): string?
  local offered: mut {string} = {}
  if zstd and asset.zstd ~= nil then offered[#offered + 1] = "zstd" end
  if gzip and asset.gzip ~= nil then offered[#offered + 1] = "gzip" end
  if #offered == 0 then return nil end
  local chosen = Server.encoding(header, offered)
  if chosen == "zstd" or chosen == "gzip" then return chosen end
  return nil
end

--- Whether an `If-Range` header (an entity tag or a date) holds for a
--- representation with strong `etag`: only an equal strong tag does.
local function if_range_holds(header: string?, etag: string): boolean
  if header == nil then return true end
  return header == etag
end

--- The plain 404 of a stale fingerprint: not the app's page, and told to
--- be kept by no cache, so a CDN does not keep it across a deploy.
local function stale(): Types.Response
  return Response.text("Not Found\n", { status = 404, headers = { ["Cache-Control"] = "no-store" } })
end

--- Sets `opts.headers` on `res`, over what it holds.
local function with_headers(res: Types.Response, extra: {string:string}?): Types.Response
  for name, value in pairs(extra or {}) do Response.set_header(res, name, value) end
  return res
end

--- The headers every answer about `asset` carries.
local function validators(asset: Assets.Asset, etag: string, control: string,
                          coding: string?): mut {string: string | {string}}
  local headers: mut {string: string | {string}} = {
    ["Content-Type"] = asset.type, ["ETag"] = etag, ["Cache-Control"] = control,
    ["X-Content-Type-Options"] = "nosniff",
  }
  if asset.mtime > 0 then headers["Last-Modified"] = Time.format_http(asset.mtime * NS) end
  if Mime.scripted(asset.type) then
    headers["Content-Security-Policy"] = "sandbox"
  end
  if coding ~= nil then headers["Content-Encoding"] = coding end
  return headers
end

--- A handler serving `opts.source`. Mount it, which strips its prefix
--- from the path it sees: [`StaticFiles.mount`] does.
--- @param opts Options | nil Where the files come from and how they are cached
--- @return Types.Handler The handler
function StaticFiles.handler(opts?: StaticFiles.Options): Types.Handler
  local o: StaticFiles.Options = opts or {}
  local source = o.source or Assets.default()
  local plain_control = o.cache_control or DEFAULT_CACHE
  local immutable_control = o.immutable_control or DEFAULT_IMMUTABLE
  local use_gzip = o.gzip ~= false
  local use_zstd = o.zstd ~= false

  local function missing(req: Types.Request): Types.Response
    local not_found = o.not_found
    if not_found ~= nil then return not_found(req) end
    return Response.abort(404)
  end

  --- The asset `rel` names, whether by its fingerprint, and what is
  --- wrong when there is none: "stale" for a fingerprint of other content,
  --- "none" for a path no file has.
  local function find(rel: string): Assets.Asset?, boolean, string
    local asset, _ = source:get(rel)
    if asset ~= nil then return asset, false, "" end
    local parts = unfingerprint(rel)
    if parts ~= nil then
      local named, _ = source:get(parts.plain)
      if named ~= nil then
        if named.sha256:sub(1, 10) == parts.digits then return named, true, "" end
        return nil, false, "stale"
      end
    end
    return nil, false, "none"
  end

  return function(req: Types.Request): Types.Response
    local method = req.method
    if method ~= "GET" and method ~= "HEAD" then
      return Response.text("Method Not Allowed\n", { status = 405, headers = { Allow = "GET, HEAD" } })
    end
    local rel = relative(req)
    if rel == nil then return missing(req) end
    if req.trailing and o.html ~= true then return missing(req) end
    local asset: Assets.Asset?
    local by_digest: boolean
    local trouble: string
    if o.html == true and (rel == "" or req.trailing) then
      asset, by_digest, trouble = find(if rel == "" then "index.html" else rel .. "/index.html" end)
    elseif rel == "" then
      return missing(req)
    else
      asset, by_digest, trouble = find(rel)
      if asset == nil and o.html == true then
        local index, _ = source:get(rel .. "/index.html")
        if index ~= nil then
          local location = req.path .. "/"
          if req.query_string ~= "" then location = location .. "?" .. req.query_string end
          return Response.redirect(location, { status = 308 })
        end
      end
    end
    if asset == nil then
      if trouble == "stale" then return stale() end
      return missing(req)
    end

    local control = by_digest and immutable_control or plain_control
    local has_range = req:header("range") ~= nil
    local coding: string? = nil
    if not has_range then
      coding = coding_of(asset, req:header("accept-encoding"), use_zstd, use_gzip)
    end
    local etag = asset.etag
    if coding ~= nil then etag = etag:sub(1, -2) .. '-' .. coding .. '"' end
    local vary = (asset.gzip ~= nil and use_gzip) or (asset.zstd ~= nil and use_zstd)

    local none_match = req:header("if-none-match")
    local not_modified = false
    if none_match ~= nil then
      not_modified = Server.none_match(none_match, etag)
    elseif asset.mtime > 0 then
      local since = req:header("if-modified-since")
      local stamp: integer? = nil
      if since ~= nil then
        local parsed, _ = Time.parse_http(since)
        stamp = parsed
      end
      not_modified = stamp ~= nil and asset.mtime * NS <= stamp
    end
    if not_modified then
      local res: Types.Response = { status = 304, headers = {
        ["ETag"] = etag, ["Cache-Control"] = control } }
      if asset.mtime > 0 then
        Response.set_header(res, "Last-Modified", Time.format_http(asset.mtime * NS))
      end
      if vary then Response.add_header(res, "Vary", "Accept-Encoding") end
      return with_headers(res, o.headers)
    end

    local headers = validators(asset, etag, control, coding)
    local res: Types.Response = { status = 200, headers = headers }
    local data = asset.data
    if coding == "zstd" then
      data = assert(asset.zstd)
    elseif coding == "gzip" then
      data = assert(asset.gzip)
    end
    headers["Accept-Ranges"] = "bytes"
    if method == "GET" and coding == nil and has_range and
        if_range_holds(req:header("if-range"), asset.etag) then
      local range = Server.range(req:header("range"), #data)
      if range.kind == "span" then
        res.status = 206
        local first, last = assert(range.first), assert(range.last)
        headers["Content-Range"] = ("bytes %d-%d/%d"):format(first, last, #data)
        data = data:sub(first + 1, last + 1)
      elseif range.kind == "unsatisfiable" then
        res = { status = 416, headers = { ["Content-Range"] = "bytes */" .. tostring(#data),
          ["X-Content-Type-Options"] = "nosniff" } }
        if vary then Response.add_header(res, "Vary", "Accept-Encoding") end
        return with_headers(res, o.headers)
      end
    end
    res.body = data
    if vary then Response.add_header(res, "Vary", "Accept-Encoding") end
    return with_headers(res, o.headers)
  end
end

--- The URL of the asset at `path` under `prefix`, in its fingerprinted
--- spelling: "/static/css/app.3f9a1c8e2b.css" for "css/app.css". A file
--- read from disk is hashed again when it changes, so a page rendered after
--- an edit names the new content. Nil and why for a path the source does
--- not hold: a `href` to a typo is found when the page is made.
--- @param source Assets.Source Where the files come from
--- @param prefix string The mount's full prefix, "/static"
--- @param path string The asset's path, "css/app.css"
--- @return string | nil The URL
--- @return string Why there is none
function StaticFiles.url(source: Assets.Source, prefix: string, path: string): string?, string
  local asset, why = source:get(path)
  if asset == nil then return nil, why end
  local parts: mut {string} = {}
  for part in fingerprinted(path, asset.sha256):gmatch("[^/]+") do
    parts[#parts + 1] = Url.escape(part)
  end
  return (if prefix == "/" then "" else prefix end) .. "/" .. table.concat(parts, "/"), ""
end

--- The route for `prefix` serving `opts.source`: [`Web.mount_handler`]
--- over [`StaticFiles.handler`], named "static", whose `url_for` takes a
--- `path` parameter and answers the fingerprinted URL
--- ([`StaticFiles.url`]).
--- @param prefix string The prefix, "/static"
--- @param opts Options | nil Where the files come from and how they are cached
--- @return Types.Route The mount
function StaticFiles.mount(prefix: string, opts?: StaticFiles.Options): Types.Route
  local source: Assets.Source = opts and opts.source or Assets.default()
  local o: StaticFiles.Options = {
    source = source, cache_control = opts and opts.cache_control,
    immutable_control = opts and opts.immutable_control, html = opts and opts.html,
    not_found = opts and opts.not_found, headers = opts and opts.headers,
    gzip = opts and opts.gzip, zstd = opts and opts.zstd,
  }
  return Route.mount_handler(prefix, StaticFiles.handler(o), { name = "static",
    reverse = function(full: string, params: {string:string}): string?, string
      local path = params.path
      if path == nil then return nil, "static: url_for needs a 'path' parameter" end
      return StaticFiles.url(source, full, path)
    end })
end

return StaticFiles
