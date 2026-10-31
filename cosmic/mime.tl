--- Content types by file name, for the files a web program serves. The
--- build stores the answer beside each embedded asset, so this module
--- requires only the standard library and a program that never loads
--- [`cosmic.web`] carries the same types.

local Compress = require("cosmic.compress")

local record Mime
end

local TEXT <const> = "; charset=utf-8"

--- Lowercase extension to Content-Type.
local TYPES <const>: {string:string} = {
  html = "text/html" .. TEXT, htm = "text/html" .. TEXT,
  css = "text/css" .. TEXT,
  js = "text/javascript" .. TEXT, mjs = "text/javascript" .. TEXT,
  json = "application/json" .. TEXT, map = "application/json" .. TEXT,
  txt = "text/plain" .. TEXT,
  xml = "application/xml" .. TEXT, xsl = "application/xml" .. TEXT,
  xhtml = "application/xhtml+xml" .. TEXT,
  svg = "image/svg+xml" .. TEXT,
  webmanifest = "application/manifest+json",
  csv = "text/csv" .. TEXT,
  md = "text/markdown" .. TEXT,
  png = "image/png", jpg = "image/jpeg", jpeg = "image/jpeg", gif = "image/gif",
  webp = "image/webp", avif = "image/avif", ico = "image/vnd.microsoft.icon",
  bmp = "image/bmp",
  woff = "font/woff", woff2 = "font/woff2", ttf = "font/ttf", otf = "font/otf",
  wasm = "application/wasm", pdf = "application/pdf", zip = "application/zip",
  gz = "application/gzip",
  mp3 = "audio/mpeg", mp4 = "video/mp4", webm = "video/webm", ogg = "audio/ogg",
  wav = "audio/wav",
}

--- Whether bytes of `content_type` shrink under gzip: text, and the
--- structured types and fonts that are not already compressed.
local COMPRESSIBLE <const>: {string:boolean} = {
  svg = true, json = true, map = true, xml = true, webmanifest = true, wasm = true,
  ttf = true, otf = true, bmp = true, ico = true,
}

--- The lowercase extension of the last component of `path`, without its dot;
--- nil for a name with none (a leading dot alone is no extension).
local function extension(path: string): string?
  local name = path:match("([^/]*)$")
  local ext = name:match("^.+%.([^.]*)$")
  if ext == nil or ext == "" then return nil end
  return ext:lower()
end

--- The Content-Type for a file called `path`, by its extension, in any
--- case: "text/css; charset=utf-8" for "css/app.CSS". Text, JSON,
--- JavaScript, SVG and XML carry `charset=utf-8`; a name with no known
--- extension is "application/octet-stream". Content is never sniffed.
--- @param path string A file name or path
--- @return string The Content-Type
function Mime.of(path: string): string
  local ext = extension(path)
  return ext ~= nil and TYPES[ext] or "application/octet-stream"
end

--- Whether a file of `content_type` can carry script a browser runs when it
--- is opened as a page: SVG, XML (an XSLT stylesheet or an inline XHTML
--- namespace runs script) and XHTML. A server sends such a file under a
--- `Content-Security-Policy: sandbox`. Case and the whitespace around the
--- type are ignored, as a browser ignores them.
--- @param content_type string A Content-Type, with or without parameters
--- @return boolean Whether the type needs the sandbox
function Mime.scripted(content_type: string): boolean
  local kind = content_type:match("^%s*([^;]*)"):lower():gsub("%s+$", "")
  return kind == "image/svg+xml" or kind == "application/xml" or kind == "text/xml" or
    kind == "application/xhtml+xml"
end

--- The most bytes of a file that are not worth compressing.
local MIN_BYTES <const> = 1024

--- The level the zstd of a file is written at. Every projection write
--- compresses every asset again, so the cost is paid often: on 5.9 MB of
--- source text level 12 takes about what gzip level 9 does (370 ms against
--- 360) and is 14% smaller than it, where level 19 is 10 times slower for 24%
--- and level 9 is 2.4 times faster for 12%. Levels 3 to 12 stay near gzip's
--- cost; above 12 the time climbs steeply for a few percent of size.
local ZSTD_LEVEL <const> = 12

--- Whether a file called `path` with contents `data` is worth sending
--- compressed: the type is text or another format not compressed already,
--- and `data` is over 1 KiB.
local function compressible(path: string, data: string): boolean
  local ext = extension(path)
  if ext == nil or #data <= MIN_BYTES then return false end
  local kind = TYPES[ext]
  return kind ~= nil and (kind:sub(1, 5) == "text/" or COMPRESSIBLE[ext] == true)
end

--- `packed` when it is at least 10% smaller than `data`, else nil.
local function worth(packed: string?, data: string): string?
  if packed == nil or #packed * 10 > #data * 9 then return nil end
  return packed
end

--- The gzip of `data`, the contents of a file called `path`, when that is
--- worth sending in its place: the type is text or another format not
--- compressed already, `data` is over 1 KiB and the gzip is at least 10%
--- smaller. Level 9 and a header with no time make the bytes a function of
--- `data` alone, so a reproducible build stays so. Nil where gzip is not
--- worth it.
--- @param path string A file name or path
--- @param data string The file's bytes
--- @return string | nil The gzip, or nil
function Mime.gzip(path: string, data: string): string?
  if not compressible(path, data) then return nil end
  local packed, _ = Compress.deflate("gzip", data, 9)
  return worth(packed, data)
end

--- The zstd of `data`, the contents of a file called `path`, when that is
--- worth sending in its place: the same rule as [`Mime.gzip`] (a type not
--- compressed already, over 1 KiB, at least 10% smaller). One frame at a
--- fixed level and no dictionary, so for the same zstd build the bytes are
--- those of `data` alone and a reproducible build stays so. Nil where zstd
--- is not worth it.
--- @param path string A file name or path
--- @param data string The file's bytes
--- @return string | nil The zstd frame, or nil
function Mime.zstd(path: string, data: string): string?
  if not compressible(path, data) then return nil end
  local encoder, _ = Compress.zstd_encoder(ZSTD_LEVEL)
  if encoder == nil then return nil end
  local head, _ = encoder:update(data)
  local tail, _ = encoder:finish()
  if head == nil or tail == nil then return nil end
  return worth(head .. tail, data)
end

return Mime
