--- Fuzz properties for `Json.parse_path`, which reads a path a person
--- typed: it is total on any bytes, and it reads back the steps
--- `Json.child_path` spelled, for any keys (bytes that are not UTF-8,
--- dots, brackets, quotes, control characters) and any integers.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Json = require("cosmic.json")

--- Keys that need quoting, and one that does not, drawn more often than
--- chance would.
local KEYS <const> = { "a", "rows", "_x1", "a key", "", "a.b", "[0]", "]", "[", '"', "\\", '\\"', "$",
  "*", "..", ".*", "\n", "\0", "\x7f", "\xc3\xa9", "\xe2\x82\xac", "\xf0\x9f\x98\x80", "\xff\xfe", "\xed\xa0\x80", "1", "-1" }

local INTEGERS <const>: {integer} = { 1, 2, 10, 0, -1, 9223372036854775807, math.mininteger }

local function render(steps: {string | integer}): string
  local text = "$"
  for _, step in ipairs(steps) do text = Json.child_path(text, step) end
  return text
end

local function same(a: {string | integer}, b: {string | integer}): boolean
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] or math.type(a[i] as number) ~= math.type(b[i] as number) then return false end
  end
  return true
end

--- Steps as packed fields: `i` and an integer, or `s` and a key.
local function gen_steps(src: Fuzz.Source): string
  local fields: {string} = {}
  while Fuzz.more(src, #fields // 2, 6) do
    local kind = src:int(0, 3)
    if kind == 0 then
      fields[#fields + 1] = "i"
      fields[#fields + 1] = tostring(src:int(0, 3) == 0 and Fuzz.pick(src, INTEGERS) or src:int(-5, 100000))
    else
      fields[#fields + 1] = "s"
      fields[#fields + 1] = kind == 1 and Fuzz.pick(src, KEYS) or Fuzz.bytes(src, 6)
    end
  end
  return Fuzz.pack(fields)
end

-- Drawn paths render and read back as themselves: about half the steps
-- are keys that need `["..."]`, and a few are integers at the edges.
local function test_a_rendered_path_reads_back(tmp: string)
  Fuzz.run({
    name = "json path round trip",
    dir = tmp,
    gen = gen_steps,
    requires = { "quoted key", "bare key", "index", "empty path" },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local steps: {string | integer} = {}
      for i = 1, #fields - 1, 2 do
        if fields[i] == "i" then
          steps[#steps + 1] = math.tointeger(tonumber(fields[i + 1]) as number)
          Fuzz.label("index")
        else
          local key = fields[i + 1]
          steps[#steps + 1] = key
          Fuzz.label(key:match("^[%a_][%w_]*$") and "bare key" or "quoted key")
        end
      end
      if #steps == 0 then Fuzz.label("empty path") end
      local text = render(steps)
      local ok, got, err = pcall(Json.parse_path, text)
      if not ok then return false, "raised on " .. Json.quote(text) .. ": " .. tostring(got) end
      if got == nil then return false, "refused " .. Json.quote(text) .. ": " .. err end
      if not same(got as {string | integer}, steps) then
        return false, "read " .. render(got as {string | integer}) .. " for " .. Json.quote(text)
      end
      -- The same path with no leading `$` and no first dot reads the same.
      local first = steps[1]
      if first is string and first:match("^[%a_][%w_]*$") then
        local bare = text:sub(3)
        local again = Json.parse_path(bare)
        if again == nil or not same(again, steps) then
          return false, "bare " .. Json.quote(bare) .. " read differently"
        end
      end
      return true, ""
    end,
  })
end

--- Well-formed and nearly well-formed paths to mutate: the forms the
--- parser reads, each escape, and the refusals.
local SAMPLES <const> = {
  "$", "$.a", "a.b", ".a.b", "[1]", "$[1][2]", '$["a key"]', '["a"]["b"]', "$.rows[2].name",
  '$["\\u00e9\\ud83d\\ude00"]', '$["\\"\\\\\\/\\b\\f\\n\\r\\t"]', "$[-3]", "$[9223372036854775808]",
  '$["\\ud83d"]', '$["\\ude00"]', '$["\\x"]', '$["a', '$["a"', "$.", "$..a", "$[", "$[]", "$[1", "$[1.5]",
  "$a", "", "a..b", "$.*", "$[*]", "*", "$.a..b", '$["*"]', "$.a*", "$[ 1 ]", '$["a"]x',
}

local TOKENS <const> = { "$", ".", "[", "]", '"', "\\", "\\u", "d83d", "de00", "0", "1", "-", "a", " ",
  "*", "..", "\0", "\xc3", "\xff", "9223372036854775808" }

local function gen_text(src: Fuzz.Source): string
  if src:int(0, 3) == 0 then
    local parts: {string} = {}
    while Fuzz.more(src, #parts, 20) do
      parts[#parts + 1] = src:int(0, 3) == 0 and Fuzz.bytes(src, 3) or Fuzz.pick(src, TOKENS)
    end
    return table.concat(parts)
  end
  return Fuzz.mutate(src, Fuzz.pick(src, SAMPLES), src:int(0, 1) == 0 and 0 or 4)
end

-- Any text is a path or a message, never a raise; a path it reads
-- renders and reads back as itself. About a third of drawn texts read.
local function test_parse_path_is_total_on_any_text(tmp: string)
  Fuzz.run({
    name = "json path total",
    dir = tmp,
    gen = gen_text,
    requires = { "read", "refused" },
    shares = { read = 0.15, refused = 0.15 },
    check = function(input: string): boolean, string
      local ok, got, err = pcall(Json.parse_path, input)
      if not ok then return false, "raised: " .. tostring(got) end
      if got == nil then
        Fuzz.label("refused")
        if not (err is string) or err == "" then return false, "a refusal with no message" end
        return true, ""
      end
      if err ~= "" then return false, "a path with a message: " .. err end
      Fuzz.label("read")
      local steps = got as {string | integer}
      local again, why = Json.parse_path(render(steps))
      if again == nil then return false, "did not read back its own spelling: " .. why end
      if not same(again, steps) then return false, "spelling " .. render(steps) .. " read differently" end
      return true, ""
    end,
  })
end

--- A drawn path followed by a wildcard or a `..` is refused by name,
--- never read as a key: those are kept for later, and a key named `*`
--- is only `["*"]`.
local function test_wildcards_and_descent_are_refused_after_any_path(tmp: string)
  local tails <const> = { ".*", "[*]", "..k", "..", ".a.*", '["k"]..k' }
  Fuzz.run({
    name = "json path reserved",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      return Fuzz.pack({ gen_steps(src), Fuzz.pick(src, tails) })
    end,
    requires = { "refused" },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local steps: {string | integer} = {}
      local packed = Fuzz.unpack(fields[1])
      for i = 1, #packed - 1, 2 do
        steps[#steps + 1] = packed[i] == "i" and math.tointeger(tonumber(packed[i + 1]) as number)
          or packed[i + 1]
      end
      local text = render(steps) .. fields[2]
      local ok, got, err = pcall(Json.parse_path, text)
      if not ok then return false, "raised on " .. Json.quote(text) .. ": " .. tostring(got) end
      if got ~= nil then return false, Json.quote(text) .. " read as " .. render(got as {string | integer}) end
      if not err:find("is not supported yet", 1, true) then
        return false, Json.quote(text) .. " refused without saying so: " .. err
      end
      Fuzz.label("refused")
      return true, ""
    end,
  })
end
