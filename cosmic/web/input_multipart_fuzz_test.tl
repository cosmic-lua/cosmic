--- Fuzz property for the web layer's multipart read, which writes what a
--- client sends to disk: whatever the body and the caps, the read answers a
--- value within the caps or a refusal with one of the statuses of the
--- package, never raises, and leaves no file in the upload directory once
--- the request is over.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fs = require("cosmic.fs")
local Fuzz = require("build.fuzz")
local Input = require("cosmic.web.input")
local Server = require("cosmic.http.server")
local Stream = require("cosmic.stream")
local Types = require("cosmic.web.types")
local Web = require("cosmic.web")

local B <const> = "fuzzB"
local NAMES <const>: {string} = { "a", "f", "pic", "tags", "é", "x y" }
local FILENAMES <const>: {string} = { "a.txt", "../x", "C:\\y\\z", "", "é", "b.bin", "c", "a.txt", "q\0r", "t%0Au",
  string.rep("n", 300) }
local PIECES <const>: {string} = { "abc", "\r\n", "--", "\r\n--fuzz", "", "\255", "0123456789" }
local CHARSETS <const>: {string} = { "", "", "", "", "", "", "Content-Type: text/plain; charset=iso-8859-1\r\n",
  "Content-Type: text/plain; charset=utf-16\r\n", "Content-Transfer-Encoding: base64\r\n" }

local function draw_text(src: Fuzz.Source): string
  local out: mut {string} = {}
  local count = 0
  while Fuzz.more(src, count, 6) do
    count = count + 1
    local head = "--" .. B .. '\r\nContent-Disposition: form-data; name="' .. Fuzz.pick(src, NAMES) .. '"'
    if src:int(0, 1) == 1 then head = head .. '; filename="' .. Fuzz.pick(src, FILENAMES) .. '"' end
    head = head .. "\r\n" .. Fuzz.pick(src, CHARSETS) .. "\r\n"
    local body: mut {string} = {}
    while Fuzz.more(src, #body, 5) do
      body[#body + 1] = if src:int(0, 3) == 0 then Fuzz.bytes(src, 40) else Fuzz.pick(src, PIECES) end
    end
    out[#out + 1] = head .. table.concat(body) .. "\r\n"
  end
  out[#out + 1] = "--" .. B .. "--\r\n"
  return table.concat(out)
end

local function test_any_multipart_body_is_bounded_and_leaves_no_file(tmp: string)
  -- The fuzzer keeps the input under test in `tmp`: uploads go below it.
  local uploads = tmp .. "/uploads"
  assert(Fs.mkdirs(uploads))
  local app: Web.App
  -- What the handler is told to read with, and what it read.
  local handler = { opts = nil as Types.InputOptions?, outcome = nil as Types.Parsed<Input.Multipart>? }
  app = Web.app{ routes = { Web.post("/x", function(req: Web.Request): Web.Response
    local parsed = Input.multipart(req, handler.opts)
    handler.outcome = parsed
    local value = parsed.value
    if value ~= nil then
      -- What a handler could still read while the request lasts.
      for _, list in pairs(assert(value).files) do
        for _, up in ipairs(list) do
          local st = assert(Fs.stat(up.path))
          assert(st.size == up.size, "the size is the file's")
        end
      end
    end
    return Web.empty()
  end) }, sink = { line = function(_self: Web.Sink, _text: string) end } }
  local ALLOWED <const>: {integer:boolean} = { [400] = true, [413] = true, [415] = true, [408] = false }
  Fuzz.run({
    name = "web multipart read",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local text = draw_text(src)
      if src:int(0, 2) == 0 then text = Fuzz.mutate(src, text, 4) end
      return Fuzz.pack({ text, tostring(src:int(1, 60)), tostring(src:int(1, 60)), tostring(src:int(1, 3)),
        tostring(src:int(2, 6)), tostring(src:int(0, 1)) })
    end,
    requires = { "bound", "file_spooled", "refused_400", "refused_413" },
    shares = { bound = 0.1 },
    check = function(input: string): boolean, string
      local f = Fuzz.unpack(input)
      local text = f[1]
      local max_file_bytes = assert(math.tointeger(tonumber(f[2])))
      local max_field_bytes = assert(math.tointeger(tonumber(f[3])))
      local max_files = assert(math.tointeger(tonumber(f[4])))
      local max_parts = assert(math.tointeger(tonumber(f[5])))
      handler.opts = { dir = uploads, max_file_bytes = max_file_bytes, max_field_bytes = max_field_bytes,
        max_files = max_files, max_parts = max_parts, max_bytes = 600 }
      local chunked = f[6] == "1"
      handler.outcome = nil
      local raw: Server.Request = { method = "POST", target = "/x", path = "/x", query = "", version = "HTTP/1.1",
        headers = { host = "x", ["content-type"] = "multipart/form-data; boundary=" .. B },
        body = Stream.from_string(text), length = if not chunked then #text else nil end }
      local ok, reply = pcall(app.handle, raw)
      if not ok then return false, "raised: " .. tostring(reply) end
      if reply.status ~= 204 then return false, "the handler faulted: " .. reply.status end
      local left = assert(Fs.list(uploads))
      if #left ~= 0 then return false, "left behind: " .. table.concat(left, ", ") end
      local read = assert(handler.outcome, "the handler read nothing")
      local invalid = read.invalid
      if invalid ~= nil then
        if read.value ~= nil or not ALLOWED[invalid.status] then
          return false, "a bad refusal: " .. invalid.status
        end
        Fuzz.label("refused_" .. invalid.status)
        return true, ""
      end
      local m = assert(read.value)
      local files = 0
      for _, list in pairs(m.files) do
        for _, up in ipairs(list) do
          files = files + 1
          if up.size > max_file_bytes then return false, "a file over its cap" end
          if up.filename:find("[/\\]") or up.filename:find("%c") then
            return false, "an unsafe filename"
          end
          if not up.path:find("^" .. uploads:gsub("%p", "%%%0") .. "/%x+$") then
            return false, "a path not of ours"
          end
        end
      end
      if files > max_files then return false, "more files than max_files" end
      if files + #m.fields.pairs > max_parts then return false, "more parts than max_parts" end
      if m.size > #text then return false, "a size beyond the body" end
      for _, pair in ipairs(m.fields.pairs) do
        -- ISO-8859-1 text grows by at most a byte per byte on conversion.
        if #pair.value > 2 * max_field_bytes or not utf8.len(pair.value) then
          return false, "a bad text field"
        end
      end
      Fuzz.label("bound")
      if files > 0 then Fuzz.label("file_spooled") end
      return true, ""
    end,
  })
end
