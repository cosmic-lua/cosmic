local Compress = require("cosmic.compress")
local Mime = require("cosmic.mime")
local Stream = require("cosmic.stream")

local function test_of_names_a_type_by_extension_in_any_case()
  assert(Mime.of("css/app.css") == "text/css; charset=utf-8")
  assert(Mime.of("APP.CSS") == "text/css; charset=utf-8")
  assert(Mime.of("a/b.min.js") == "text/javascript; charset=utf-8")
  assert(Mime.of("data.json") == "application/json; charset=utf-8")
  assert(Mime.of("logo.svg") == "image/svg+xml; charset=utf-8")
  assert(Mime.of("pic.JPEG") == "image/jpeg")
  assert(Mime.of("font.woff2") == "font/woff2")
  assert(Mime.of("m.wasm") == "application/wasm")
  assert(Mime.of("site.webmanifest") == "application/manifest+json")
end

local function test_of_never_guesses_past_the_last_extension()
  assert(Mime.of("README") == "application/octet-stream")
  assert(Mime.of(".css") == "application/octet-stream")
  assert(Mime.of("dir.css/file") == "application/octet-stream")
  assert(Mime.of("archive.tar.xyz") == "application/octet-stream")
  assert(Mime.of("trailing.") == "application/octet-stream")
end

local function test_gzip_keeps_only_a_text_file_it_shrinks_enough()
  local text = ("body { margin: 0 }\n"):rep(200)
  local packed = assert(Mime.gzip("app.css", text))
  assert(#packed * 10 <= #text * 9)
  assert(Compress.inflate("gzip", packed) == text)
  -- deterministic: the bytes depend on the input alone.
  assert(Mime.gzip("app.css", text) == packed)
  assert(Mime.gzip("app.css", ("x"):rep(1024)) == nil, "1 KiB is not past the minimum")
  assert(Mime.gzip("photo.png", text) == nil, "an image is not gzipped")
  assert(Mime.gzip("noext", text) == nil)
  local noise: mut {string} = {}
  local state = 12345
  for i = 1, 4000 do
    state = (state * 1103515245 + 12345) % 2147483648
    noise[i] = string.char((state // 65536) % 256)
  end
  assert(Mime.gzip("random.txt", table.concat(noise)) == nil, "no gzip that saves under 10%")
end

local function unzstd(packed: string): string
  local out = assert(Stream.run(assert(Compress.zstd_decoder()), packed))
  return out
end

local function test_zstd_keeps_only_a_text_file_it_shrinks_enough()
  local text = ("body { margin: 0 }\n"):rep(200)
  local packed = assert(Mime.zstd("app.css", text))
  assert(#packed * 10 <= #text * 9)
  assert(unzstd(packed) == text)
  assert(Mime.zstd("app.css", text) == packed, "the bytes depend on the input alone")
  assert(#packed <= #assert(Mime.gzip("app.css", text)), "level 19 is no larger than gzip here")
  assert(Mime.zstd("app.css", ("x"):rep(1024)) == nil, "1 KiB is not past the minimum")
  assert(Mime.zstd("photo.png", text) == nil, "an image is not compressed")
  assert(Mime.zstd("noext", text) == nil)
  local noise: mut {string} = {}
  local state = 12345
  for i = 1, 4000 do
    state = (state * 1103515245 + 12345) % 2147483648
    noise[i] = string.char((state // 65536) % 256)
  end
  assert(Mime.zstd("random.txt", table.concat(noise)) == nil, "no zstd that saves under 10%")
end

local function test_scripted_names_the_types_a_browser_runs_script_from()
  for _, kind in ipairs({ "image/svg+xml; charset=utf-8", "application/xml", "TEXT/XML ;x=y",
      "application/xhtml+xml", Mime.of("a.xml"), Mime.of("a.xhtml"), Mime.of("s.XSL") }) do
    assert(Mime.scripted(kind), kind)
  end
  for _, kind in ipairs({ "text/html; charset=utf-8", "image/png", "application/json",
      "text/plain", "application/xmlish" }) do
    assert(not Mime.scripted(kind), kind)
  end
end

local function test_scripted_ignores_whitespace_before_the_type()
  assert(Mime.scripted(" image/svg+xml"))
  assert(Mime.scripted("\t text/xml ; charset=utf-8"))
end
