--- Fuzz properties for [`hash.parse_sums`], which reads a sums file that
--- may be anyone's: [`hash.format_line`] then `parse_sums` gives back the
--- digest and the name for any name (bytes that are not UTF-8, backslashes,
--- newlines, spaces, `*`), and `parse_sums` is total on any bytes, listing
--- what it cannot read rather than raising. `FUZZ_SEED` and `FUZZ_ITERS`
--- pick the inputs (build/fuzz/init.tl).

local Codec = require("cosmic.codec")
local Fuzz = require("build.fuzz")
local hash = require("build.hash")

--- Names that need care, drawn more often than chance would.
local NAMES <const> = { "a", "dir/file.txt", "a b", " lead", "trail ", "*star", "a*b", "\\", "\\n", "a\\b",
  "a\nb", "\n", "\\\n", "\\\\", "#hash", "-", "\xc3\xa9", "\xff\xfe", "\r", "a\r", "\0", "..", "x\ty" }

local SIZES <const>: {integer} = { 16, 20, 28, 32, 48, 64 }

local function gen_entries(src: Fuzz.Source): string
  local fields: {string} = { tostring(Fuzz.pick(src, SIZES)) }
  while Fuzz.more(src, #fields - 1, 6) do
    fields[#fields + 1] = src:int(0, 2) == 0 and Fuzz.bytes(src, 6) or Fuzz.pick(src, NAMES)
  end
  return Fuzz.pack(fields)
end

-- Every name formats to a line that parses to itself, alone and among others.
local function test_a_formatted_line_reads_back(tmp: string)
  Fuzz.run({
    name = "sums round trip",
    dir = tmp,
    gen = gen_entries,
    requires = { "escaped name", "plain name", "several lines" },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local size = math.tointeger(tonumber(fields[1]) as number) as integer
      local lines: {string} = {}
      local names: {string} = {}
      local digests: {string} = {}
      for i = 2, #fields do
        if fields[i] ~= "" then
          local digest = Codec.hex(string.rep(string.char((i * 37) % 256), size))
          names[#names + 1], digests[#digests + 1] = fields[i], digest
          lines[#lines + 1] = hash.format_line(digest, fields[i])
          Fuzz.label(fields[i]:find("[\\\n\r]") and "escaped name" or "plain name")
        end
      end
      if #lines > 1 then Fuzz.label("several lines") end
      local ok, sums = pcall(hash.parse_sums, table.concat(lines, "\n") .. (#lines > 0 and "\n" or ""), size)
      if not ok then return false, "raised: " .. tostring(sums) end
      local got = sums as hash.Sums
      if #got.bad ~= 0 then
        return false, "refused line " .. got.bad[1].line .. ": " .. got.bad[1].why
      end
      for i, name in ipairs(names) do
        local entry = got.entries[i]
        if entry == nil then return false, "lost " .. Codec.hex(name) end
        if entry.name ~= name or entry.digest ~= digests[i] then
          return false, "read " .. Codec.hex(entry.name) .. " for " .. Codec.hex(name)
        end
      end
      if #got.entries ~= #names then
        return false, "read " .. #got.entries .. " entries, wrote " .. #names
      end
      return true, ""
    end,
  })
end

local HEX <const> = string.rep("ab", 32)

--- Well-formed and nearly well-formed sums lines to mutate.
local SAMPLES <const> = {
  HEX .. "  file\n", HEX .. " *file\n", "\\" .. HEX .. "  a\\nb\n", "\\" .. HEX .. "  a\\\\b\n",
  "\\" .. HEX .. "  bad\\x\n", "\\" .. HEX .. "  trailing\\", HEX:upper() .. "  F\n",
  HEX .. "  \n", HEX .. "\n", HEX:sub(2) .. "  short\n", HEX .. "x file\n", HEX .. "   three\n",
  "# comment\n\n" .. HEX .. "  a\n", "not a sum\n", "", "\n\n", "\\\n", HEX .. "  a\r\n", "zz" .. HEX:sub(3) .. "  a\n",
}

local TOKENS <const> = { HEX, "\n", " ", "  ", "*", "\\", "\\n", "\\\\", "#", "a", "\r", "\0", "\xff", "ab" }

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

-- Any bytes are a sums file, never a raise; each entry has a digest of
-- the right size and a name, and formats and reads back as itself.
local function test_parse_sums_is_total_on_any_bytes(tmp: string)
  Fuzz.run({
    name = "sums total",
    dir = tmp,
    gen = gen_text,
    requires = { "entry", "refused", "escaped name", "skipped" },
    shares = { entry = 0.1, refused = 0.1 },
    check = function(input: string): boolean, string
      local ok, sums = pcall(hash.parse_sums, input, 32)
      if not ok then return false, "raised: " .. tostring(sums) end
      local got = sums as hash.Sums
      if #got.entries > 0 then Fuzz.label("entry") end
      if #got.bad > 0 then Fuzz.label("refused") end
      if input:find("^%s*#") or input:find("\n\n") or input == "" then Fuzz.label("skipped") end
      local last = 0
      for _, entry in ipairs(got.entries) do
        if #entry.digest ~= 64 or not entry.digest:match("^%x+$") or entry.digest:lower() ~= entry.digest then
          return false, "digest " .. entry.digest
        end
        if entry.name == "" then return false, "empty name at line " .. entry.line end
        if entry.line <= last then return false, "lines out of order" end
        last = entry.line
        if entry.name:find("[\\\n\r]") then Fuzz.label("escaped name") end
        -- Formatting an entry and reading it again gives the same entry.
        local again = hash.parse_sums(hash.format_line(entry.digest, entry.name), 32)
        local first = again.entries[1]
        if #again.bad ~= 0 or first == nil or first.name ~= entry.name or first.digest ~= entry.digest then
          return false, "no round trip of " .. Codec.hex(entry.name)
        end
      end
      for _, bad in ipairs(got.bad) do
        if bad.why == "" or bad.line < 1 then return false, "bad line without a reason" end
      end
      return true, ""
    end,
  })
end
