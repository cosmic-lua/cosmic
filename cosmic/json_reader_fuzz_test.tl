--- Fuzz properties for [`Json.reader`]: on any text, however the stream
--- splits it, the reader reads the same tokens and fails the same way,
--- never raising; and it agrees with `decode`, reading one whole value
--- exactly when `decode` reads the text, and the same value, by tokens
--- and by `value` alike, and counting lines and columns as it does. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs
--- (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Json = require("cosmic.json")
local Stream = require("cosmic.stream")

--- A Reader that answers `text` in chunks of `size` bytes.
local record Chunked is Stream.Reader
  text: string
  at: integer
  size: integer
  read: function(Chunked, max_bytes?: integer): string | nil, string
  close: function(Chunked): boolean, string
end

local chunked_mt: metatable<Chunked> = { __index = Chunked }

function Chunked:read(_max_bytes?: integer): string | nil, string
  if self.at > #self.text then return nil, "" end
  local chunk = self.text:sub(self.at, self.at + self.size - 1)
  self.at = self.at + self.size
  return chunk, ""
end

function Chunked:close(): boolean, string
  return true, ""
end

local function chunked(text: string, size: integer): Stream.Reader
  local r: Chunked = setmetatable({ text = text, at = 1, size = size }, chunked_mt)
  return r
end

--- Texts to mutate: every token and nesting the reader walks.
local SAMPLES <const> = {
  '{"a": [1, 2.5, "x", true, false, null], "b": {"c": {}, "d": []}}',
  '[0, -0, 1e308, 5e-324, -12.5E+3, 18446744073709551616, 123456789012345678901234567890]',
  '"\\u0000\\u001f\\"\\\\\\/\\b\\f\\n\\r\\t\\u00e9\\ud83d\\ude00\xc3\xa9"',
  '{"k": {"k": [{"k": null}, [[]], {}]}, "\\u006b2": "v"}',
  '[\r\n  1,\n  {"a b": "[{\\"}"},\r  "]"\n]',
  "null", "true", "0", '""', "[]", "{}", "1 2 [3]", "[1\r,\n2\r]\n", "\r1\n",
}

local TOKENS <const> = { "{", "}", "[", "]", ":", ",", '"', "\\", "\\u", "0", "1", "-", ".", "e",
  "true", "false", "null", "a", " ", "\n", "\r", "\t", "\xc3", "\xa9", "\xff" }

local function gen(src: Fuzz.Source): string
  local text: string
  if src:int(0, 4) == 0 then
    local parts: {string} = {}
    while Fuzz.more(src, #parts, 30) do parts[#parts + 1] = Fuzz.pick(src, TOKENS) end
    text = table.concat(parts)
  else
    text = Fuzz.pick(src, SAMPLES)
    local shape = src:int(0, 2)
    if shape > 0 then text = Fuzz.mutate(src, text, shape == 1 and 1 or 6) end
  end
  return Fuzz.pack({ text, tostring(src:int(1, 9)) })
end

--- The tokens of `text` read `size` bytes at a time, one to a line, and
--- the failure that ended them; nil and why when the reader raised.
local function token_lines(text: string, size: integer): string | nil, string
  local ok, result, err = pcall(function(): string, string
    local r = Json.reader(chunked(text, size))
    local out: {string} = {}
    while true do
      local t, why = r:next()
      if t == nil then return table.concat(out, "\n"), why end
      out[#out + 1] = t.kind .. "=" .. Json.quote(tostring(t.value)) .. "@" .. assert(Json.pointer(r:steps()))
    end
  end)
  if not ok then return nil, "raised: " .. tostring(result) end
  return result .. "\n!" .. err, ""
end

--- The values the tokens of `text` build, each with the null stand-in;
--- nil and the failure that ended them.
local function token_values(text: string, size: integer): {any} | nil, string
  local r = Json.reader(chunked(text, size))
  local values: {any} = {}
  local stack: {{any: any}} = {}
  local keys: {string} = {}
  local function place(v: any)
    local top = stack[#stack]
    if top == nil then
      values[#values + 1] = v
    elseif Json.is_array(top) then
      top[rawlen(top) + 1] = v
    else
      top[keys[#stack]] = v
    end
  end
  while true do
    local t, why = r:next()
    if t == nil then
      if why ~= "" then return nil, why end
      return values, ""
    end
    if t.kind == "object" or t.kind == "array" then
      local container: {any: any} = t.kind == "array" and Json.array() as {any: any} or {}
      place(container)
      stack[#stack + 1] = container
    elseif t.kind == "end_object" or t.kind == "end_array" then
      stack[#stack] = nil
    elseif t.kind == "key" then
      keys[#stack] = t.value as string
    elseif t.kind == "null" then
      place(Json.null)
    else
      place(t.value)
    end
  end
end

local function same(a: any, b: any): boolean
  return Json.encode(a, { max_depth = 1000 }) == Json.encode(b, { max_depth = 1000 })
end

--- The line and column of byte `pos` of `text`, counted as `decode`
--- counts them: a line ends at \n, \r, or \r\n taken as one.
local function line_and_column(text: string, pos: integer): integer, integer
  local line, column, i = 1, 1, 1
  while i < pos do
    local c = text:byte(i)
    if c == 13 and i + 1 < pos and text:byte(i + 1) == 10 then i = i + 1 end
    if c == 10 or c == 13 then
      line, column = line + 1, 1
    else
      column = column + 1
    end
    i = i + 1
  end
  return line, column
end

--- A stray byte after a text that decodes is refused where it is, read
--- by tokens and by `value` alike.
local function placed_after(text: string, size: integer): boolean, string
  local stray = text .. " @"
  local line, column = line_and_column(stray, #stray)
  local want = ("json: a byte no JSON token starts with at line %d, column %d (pointer \"\")"):format(line, column)
  local r = Json.reader(chunked(stray, size))
  local why: string
  repeat
    local t, err = r:next()
    why = err
  until t == nil
  if why ~= want then return false, "by tokens: " .. why .. ", not " .. want end
  local v = Json.reader(chunked(stray, size))
  local _, verr = v:value()
  if verr ~= "" then return false, "value: " .. verr end
  local _, after = v:next()
  if after ~= want then return false, "after value: " .. after .. ", not " .. want end
  return true, ""
end

local function holds(input: string): boolean, string
  local fields = Fuzz.unpack(input)
  local text, size = fields[1], math.tointeger(tonumber(fields[2])) as integer
  local whole, raised = token_lines(text, #text + 1)
  if whole == nil then return false, raised end
  local split, split_raised = token_lines(text, size)
  if split == nil then return false, split_raised end
  if split ~= whole then
    return false, "split in " .. size .. "s:\n" .. split .. "\nwhole:\n" .. whole
  end
  local decoded, err = Json.decode(text, { null_value = Json.null })
  local values, why = token_values(text, size)
  if err == "" then
    Fuzz.label("decoded")
    if values == nil then return false, "decode read it, the reader refused: " .. why end
    if #values ~= 1 or not same(values[1], decoded) then
      return false, "the tokens built another value"
    end
    local r = Json.reader(chunked(text, size), { null_value = Json.null })
    local value, verr = r:value()
    if verr ~= "" then return false, "value refused what decode read: " .. verr end
    if not same(value, decoded) then return false, "value read another value" end
    local after, aerr = r:next()
    if after ~= nil or aerr ~= "" then return false, "a token after the one value: " .. aerr end
    local ok, why_not = placed_after(text, size)
    if not ok then return false, why_not end
  elseif values ~= nil and #values == 1 then
    return false, "the reader read one value, decode refused it: " .. err
  elseif values == nil then
    Fuzz.label("refused")
  end
  return true, ""
end

-- About half the drawn texts decode; a share well under it fails the run.
local function test_the_reader_agrees_with_decode(tmp: string)
  Fuzz.run({ name = "json reader", dir = tmp, gen = gen, check = holds,
    requires = { "decoded", "refused" }, shares = { decoded = 0.2 } })
end
