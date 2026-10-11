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
  xml = "application/xml" .. TEXT,
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
local function extension(path: string): string | nil
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

--- The most bytes of a file that are not worth gzipping.
local GZIP_MIN <const> = 1024

--- The gzip of `data`, the contents of a file called `path`, when that is
--- worth sending in its place: the type is text or another format not
--- compressed already, `data` is over 1 KiB and the gzip is at least 10%
--- smaller. Level 9 and a header with no time make the bytes a function of
--- `data` alone, so a reproducible build stays so. Nil where gzip is not
--- worth it.
--- @param path string A file name or path
--- @param data string The file's bytes
--- @return string | nil The gzip, or nil
function Mime.gzip(path: string, data: string): string | nil
  local ext = extension(path)
  if ext == nil or #data <= GZIP_MIN then return nil end
  local kind = TYPES[ext]
  if kind == nil or not (kind:sub(1, 5) == "text/" or COMPRESSIBLE[ext] == true) then
    return nil
  end
  local packed, _ = Compress.deflate("gzip", data, 9)
  if packed == nil or #packed * 10 > #data * 9 then return nil end
  return packed
end

return Mime
