--- Fuzz properties for cosmic.re: compiling a user-supplied pattern
--- through the POSIX ERE C binding must never crash the process, and
--- neither must matching, finding or substituting against arbitrary
--- text once a pattern compiles.
--- env: FUZZ_SEED FUZZ_ITERS

local check = require("cosmic.check")
local driver = require("_fuzz.driver")
local re = require("cosmic.re")
local source = require("_fuzz.source")

-- Patterns are capped at MAX_RANDOM_PATTERN_LEN random bytes, or
-- MAX_FRAGMENTS assembled ERE fragments: pathological patterns are
-- small, and long random bytes almost never compile at all. Match and
-- gsub texts stay in the low hundreds of bytes: POSIX ERE matching can
-- be superlinear on a crafted pattern, and this suite must finish
-- inside FUZZ_ITERS=5000 rather than stall on one pathological-but-
-- correct iteration.
local MAX_RANDOM_PATTERN_LEN = 64
local MAX_FRAGMENTS = 12
local MATCH_TEXT_LEN = 256
local GSUB_TEXT_LEN = 128
local GSUB_REPL_LEN = 32
local COMPILABLE_ATTEMPTS = 50

-- ERE metacharacters and syntax pieces a uniform random-byte generator
-- would almost never assemble by chance: grouping, brackets, braces,
-- the quantifiers, alternation, anchors and the escape character.
-- Structured garbage built from these finds far more of the parser's
-- error paths than random bytes do.
local ERE_TOKENS = {
  "(", ")", "[", "]", "{", "}", "*", "+", "?", "|", "^", "$", "\\",
  "a", "b", ".", "-", "0", "9",
}

--- Build one `{m,n}` repetition fragment with random, possibly huge,
--- bounds -- large enough to probe the engine's repetition-count limit.
--- @param src source.Recorder The source to draw from
--- @return string The fragment
local function random_repetition_fragment(src: source.Recorder): string
  return string.format("{%d,%d}", src:int(0, 999999), src:int(0, 999999))
end

--- Build one bracket-expression range fragment over arbitrary bytes.
--- @param src source.Recorder The source to draw from
--- @return string The fragment
local function random_range_fragment(src: source.Recorder): string
  return "[" .. string.char(src:int(0, 255)) .. "-" .. string.char(src:int(0, 255)) .. "]"
end

--- Assemble a pattern out of ERE syntax fragments.
--- @param src source.Recorder The source to draw from
--- @return string The generated pattern
local function structured_pattern(src: source.Recorder): string
  local n = src:int(1, MAX_FRAGMENTS)
  local parts: {string} = {}
  for i = 1, n do
    local kind = src:int(1, 3)
    if kind == 1 then
      parts[i] = ERE_TOKENS[src:int(1, #ERE_TOKENS)]
    elseif kind == 2 then
      parts[i] = random_repetition_fragment(src)
    else
      parts[i] = random_range_fragment(src)
    end
  end
  return table.concat(parts)
end

--- Generate one candidate pattern: half the time arbitrary bytes, half
--- the time assembled ERE fragments.
--- @param src source.Recorder The source to draw from
--- @return string The generated pattern
local function gen_pattern(src: source.Recorder): string
  if src:int(1, 2) == 1 then
    return driver.bytes(src, MAX_RANDOM_PATTERN_LEN)
  end
  return structured_pattern(src)
end

--- Verify a `value | nil, string` return never breaks its own contract:
--- a nil value paired with a non-nil error means that error is a
--- non-empty string. Does not require an error on nil -- a clean "no
--- match" is bare nil, not an error.
--- @param label string What is being checked, for the failure message
--- @param value any The first return
--- @param err any The second return
--- @return boolean True when the shape holds
--- @return string What broke, when it doesn't
local function fallible_shape_ok(label: string, value: any, err: any): boolean, string
  if value == nil and err ~= nil and (type(err) ~= "string" or err == "") then
    return false, label .. ": nil value paired with a non-string/empty error: " .. tostring(err)
  end
  return true
end

--- Like fallible_shape_ok, but for contracts with no clean-nil case.
--- compile()'s contract is `Regex | nil, string` -- unlike match/find,
--- there is no "honest no-match" nil, so a nil value REQUIRES a
--- non-empty string error rather than merely permitting one.
--- @param label string What is being checked, for the failure message
--- @param value any The first return
--- @param err any The second return
--- @return boolean True when the shape holds
--- @return string What broke, when it doesn't
local function fallible_shape_ok_no_clean_nil(label: string, value: any, err: any): boolean, string
  if value == nil and (err == nil or type(err) ~= "string" or err == "") then
    return false, label .. ": nil value without a non-empty error: " .. tostring(err)
  end
  return true
end

local function test_compile_totality()
  local ok, msg = driver.run({
      name = "re_compile_totality",
      gen = gen_pattern,
      check = function(input: string): boolean, string
        local rx, err = re.compile(input)
        return fallible_shape_ok_no_clean_nil("compile", rx, err)
      end,
    })
  check.truthy(ok, msg)
end
test_compile_totality()

-- The generated input is self-describing: a decimal pattern length,
-- one LF, then the pattern bytes immediately followed by the text
-- bytes. A length prefix (not a delimiter) is required because the
-- pattern itself is arbitrary bytes and may contain LF.
local function gen_match_input(src: source.Recorder): string
  local pattern = gen_pattern(src)
  local text = driver.bytes(src, MATCH_TEXT_LEN)
  return tostring(#pattern) .. "\n" .. pattern .. text
end

--- Split a generated match/find input back into its pattern and text.
--- @param input string The generated input
--- @return string The pattern
--- @return string The text
local function decode_match_input(input: string): string, string
  local header_end = input:find("\n", 1, true)
  local plen = math.floor(tonumber(input:sub(1, header_end - 1)) or 0)
  local rest = input:sub(header_end + 1)
  return rest:sub(1, plen), rest:sub(plen + 1)
end

local function test_match_totality()
  local ok, msg = driver.run({
      name = "re_match_totality",
      gen = gen_match_input,
      check = function(input: string): boolean, string
        local pattern, text = decode_match_input(input)
        if re.compile(pattern) == nil then
          -- Uncompilable pattern: property 1 already covers compile().
          return true
        end
        local m, merr = re.match(text, pattern)
        local held, detail = fallible_shape_ok("match", m, merr)
        if not held then
          return false, detail
        end
        local f, ferr = re.find(text, pattern)
        held, detail = fallible_shape_ok("find", f, ferr)
        if not held then
          return false, detail
        end
        local fa, faerr = re.find_all(text, pattern)
        held, detail = fallible_shape_ok("find_all", fa, faerr)
        if not held then
          return false, detail
        end
        return true
      end,
    })
  check.truthy(ok, msg)
end
test_match_totality()

--- Generate a pattern that compiles, retrying a bounded number of
--- times; falls back to a trivial literal so the property always has
--- something to gsub against even on an unlucky run of candidates.
--- @param src source.Recorder The source to draw from
--- @return string A pattern re.compile accepts
local function gen_compilable_pattern(src: source.Recorder): string
  for _ = 1, COMPILABLE_ATTEMPTS do
    local candidate = gen_pattern(src)
    if re.compile(candidate) ~= nil then
      return candidate
    end
  end
  return "a"
end

--- Generate a replacement string, occasionally carrying a `\N`-style
--- backreference token. cosmic.re's gsub treats a string replacement as
--- a literal (see re.tl's Repl doc comment), so these tokens are not
--- expected to be interpolated -- the property under test is that their
--- raw bytes do not upset gsub, not that they expand.
--- @param src source.Recorder The source to draw from
--- @return string The generated replacement
local function gen_replacement(src: source.Recorder): string
  local out = driver.bytes(src, GSUB_REPL_LEN)
  if src:int(1, 2) == 1 then
    out = out .. "\\" .. tostring(src:int(0, 9))
  end
  return out
end

-- Same length-prefixed encoding as the match input, with a second
-- header field for the text length so the replacement can be sliced
-- off the end.
local function gen_gsub_input(src: source.Recorder): string
  local pattern = gen_compilable_pattern(src)
  local text = driver.bytes(src, GSUB_TEXT_LEN)
  local repl = gen_replacement(src)
  return string.format("%d,%d\n%s%s%s", #pattern, #text, pattern, text, repl)
end

--- Split a generated gsub input back into its pattern, text and
--- replacement.
--- @param input string The generated input
--- @return string The pattern
--- @return string The text
--- @return string The replacement
local function decode_gsub_input(input: string): string, string, string
  local header_end = input:find("\n", 1, true)
  local header = input:sub(1, header_end - 1)
  local comma = header:find(",", 1, true)
  local plen = math.floor(tonumber(header:sub(1, comma - 1)) or 0)
  local tlen = math.floor(tonumber(header:sub(comma + 1)) or 0)
  local rest = input:sub(header_end + 1)
  return rest:sub(1, plen), rest:sub(plen + 1, plen + tlen), rest:sub(plen + tlen + 1)
end

local function test_gsub_totality()
  local ok, msg = driver.run({
      name = "re_gsub_totality",
      gen = gen_gsub_input,
      check = function(input: string): boolean, string
        local pattern, text, repl = decode_gsub_input(input)
        local result, err = re.gsub(text, pattern, repl)
        local held, detail = fallible_shape_ok("gsub", result, err)
        if not held then
          return false, detail
        end
        if result == nil and err == nil then
          return false, "gsub returned nil without an error"
        end
        return true
      end,
    })
  check.truthy(ok, msg)
end
test_gsub_totality()
