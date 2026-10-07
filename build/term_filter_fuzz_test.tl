--- Fuzz properties for [`build.term_filter`], which reads what a sandboxed
--- program wrote to its terminal: it never raises for any bytes, what it
--- passes is text and the listed sequences and nothing else -- no ESC but
--- at the start of one, no control, no C1 control in either form, valid
--- UTF-8 -- and is no longer than what it was fed, what it answers is one
--- of its two answers, feeding in pieces passes and answers what feeding
--- whole does, and a stream costs what its length does.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local TermFilter = require("build.term_filter")

--- Pieces that reach each part of the filter: the introducers, the
--- parameters and finals of every class, the controls, and bytes of
--- every width and kind of UTF-8 and of its refusals.
local PIECES <const> = {
  "\27[", "\27[", "\27[", "\27[?", "\27[>", "\27]", "\27P", "\27_", "\27^", "\27X", "\27", "\27\\",
  "\27(", "\27 ", "\27c", "\27D", "\0277", "\0278", "[", "]", ";", ":", "?", ">", "<", " ", "!", "$", "\"",
  "0", "1", "2", "3", "6", "7", "12", "25", "47", "999999", "1047", "1049", "2004", "1000", "38;2;1;2;3",
  "m", "m", "H", "f", "J", "K", "A", "d", "L", "r", "h", "l", "n", "c", "s", "u", "q", "t", "R",
  "\7", "\8", "\9", "\10", "\13", "\24", "\26", "\0", "\1", "\14", "\127", "\155", "\156", "\157",
  "\u{9b}", "\u{9d}", "\u{9c}", "\u{80}", "\u{9f}", "\u{a0}", "caf\u{e9}", "\u{20ac}", "\u{1f600}",
  "\u{10ffff}", "\226\130", "\240\159\152", "\192\175", "\237\160\128", "\244\144\128\128", "\255",
  "\128", "x", "hello", "\27[1;31m", "\27[0m", "\27[?25l", "\27[?1049h", "\27[2J", "\27[H",
  "\27]52;c;aGk=\7", "\27]0;t\27\\", "\27[6n", "\27[c", "\27[0c", "\27[5n",
}

local function gen_stream(src: Fuzz.Source): string
  local parts: {string} = {}
  local count = 0
  while Fuzz.more(src, count, 60) do
    count = count + 1
    parts[#parts + 1] = Fuzz.pick(src, PIECES)
  end
  local text = table.concat(parts)
  if src:int(0, 3) == 0 then return Fuzz.mutate(src, text, 4) end
  return text
end

local function whole(input: string): string, string
  return TermFilter.new():feed(input)
end

--- What `input` passes and answers, fed in `size` bytes at a time.
local function sized(input: string, size: integer): string, string
  local filter = TermFilter.new()
  local passed, answered: {string}, {string} = {}, {}
  for at = 1, math.max(#input, 1), size do
    local out, replies = filter:feed(input:sub(at, at + size - 1))
    passed[#passed + 1], answered[#answered + 1] = out, replies
  end
  return table.concat(passed), table.concat(answered)
end

--- The same, cut where the input's own bytes say, so a failure replays.
local function cut_by_content(input: string): string, string
  local filter = TermFilter.new()
  local passed, answered: {string}, {string} = {}, {}
  local from = 1
  for at = 1, #input do
    if (input:byte(at) + at) % 5 == 0 then
      local out, replies = filter:feed(input:sub(from, at))
      passed[#passed + 1], answered[#answered + 1] = out, replies
      from = at + 1
    end
  end
  local out, replies = filter:feed(input:sub(from))
  passed[#passed + 1], answered[#answered + 1] = out, replies
  return table.concat(passed), table.concat(answered)
end

--- The numbers of a mode list, all of the filter's modes.
local MODES <const>: {integer:boolean} = {
  [1] = true, [7] = true, [25] = true, [47] = true, [1047] = true, [1049] = true, [2004] = true,
}

local function listed_modes(numbers: string): boolean
  local count = 0
  for digits in (numbers .. ";"):gmatch("([^;]*);") do
    count = count + 1
    local number = math.tointeger(tonumber(digits))
    if number == nil or MODES[number] == nil then return false end
  end
  return count >= 1 and count <= 8
end

--- Whether `text` is the parameters of an SGR of at most 32 numbers of at
--- most five digits.
local function sgr_holds(text: string): boolean
  if text:find("%d%d%d%d%d%d") then return false end
  local count = 1
  for _ in text:gmatch("[;:]") do count = count + 1 end
  return count <= 32
end

--- Why `out` is not what the filter may pass, or "" when it is: every
--- ESC begins a listed sequence, written whole, and nothing else but
--- valid UTF-8 and the controls that pass is left.
local function unsafe(out: string): string
  local rest: {string} = {}
  local at = 1
  while true do
    local esc = out:find("\27", at, true)
    if esc == nil then
      rest[#rest + 1] = out:sub(at)
      break
    end
    rest[#rest + 1] = out:sub(at, esc - 1)
    local seq = out:sub(esc)
    local length = 0
    local params = seq:match("^\27%[([%d;:]*)m")
    if params ~= nil then
      if not sgr_holds(params) then return "an SGR out of bounds" end
      length = #params + 3
    elseif seq:find("^\27%[%d?%d?%d?%d?%d?[ABCDEFGdLMP@X]") then
      length = #seq:match("^\27%[%d*[ABCDEFGdLMP@X]")
    elseif seq:find("^\27%[%d?%d?%d?%d?%d?;?%d?%d?%d?%d?%d?[Hfr]") then
      length = #seq:match("^\27%[[%d;]*[Hfr]")
    elseif seq:find("^\27%[[0-2]?J") then
      length = #seq:match("^\27%[%d*J")
    elseif seq:find("^\27%[[0-2]?K") then
      length = #seq:match("^\27%[%d*K")
    elseif seq:find("^\27%[[su]") or seq:find("^\27[78]") then
      length = seq:find("^\27%[") and 3 or 2
    else
      local numbers = seq:match("^\27%[%?([%d;]+)[hl]")
      if numbers == nil or not listed_modes(numbers) then
        return "an escape that begins no listed sequence: " .. string.format("%q", seq:sub(1, 12))
      end
      length = #numbers + 4
    end
    at = esc + length
  end
  local text = table.concat(rest)
  if text:find("[\0-\6\11\12\14-\31\127]") then return "a control that does not pass" end
  if utf8.len(text) == nil then return "bytes that are no UTF-8" end
  if text:find("\194[\128-\159]") then return "a C1 control in UTF-8" end
  return ""
end

local function safe_holds(input: string): boolean, string
  local out, replies = whole(input)
  if #out > #input then return false, "passed more bytes than it was fed" end
  local why = unsafe(out)
  if why ~= "" then return false, why end
  if replies ~= "" then
    local rest = replies:gsub("\27%[1;1R", ""):gsub("\27%[%?1;2c", "")
    if rest ~= "" then return false, "an answer that is neither of its two" end
    Fuzz.label("answered")
  end
  if out:find("\27", 1, true) then Fuzz.label("a sequence passed") end
  if out:find("\27[?", 1, true) then Fuzz.label("a mode passed") end
  if input:find("\27]", 1, true) then Fuzz.label("an osc") end
  if input:find("\27[", 1, true) and #out < #input then Fuzz.label("a sequence dropped") end
  if out:find("[\128-\255]") then Fuzz.label("utf-8 passed") end
  if out == "" then Fuzz.label("nothing passed") end
  return true, ""
end

local function split_holds(input: string): boolean, string
  local out, replies = whole(input)
  for _, size in ipairs({ 1, 2, 3, 7 }) do
    local cut_out, cut_replies = sized(input, size)
    if cut_out ~= out or cut_replies ~= replies then
      return false, "fed " .. size .. " bytes at a time it differs"
    end
  end
  local cut_out, cut_replies = cut_by_content(input)
  if cut_out ~= out or cut_replies ~= replies then
    return false, "cut by its own bytes it differs"
  end
  if out ~= "" then Fuzz.label("passed") end
  if replies ~= "" then Fuzz.label("answered") end
  if input:find("[\128-\255]") then Fuzz.label("utf-8") end
  return true, ""
end

--- A stream amplified a hundredfold, fed whole and a copy at a time: a
--- filter that read a sequence again from its start, or scanned a run
--- twice, would spend the property's instruction budget on it.
local function linear_holds(input: string): boolean, string
  local copies = 100
  local out = whole(input:rep(copies))
  if #out > #input * copies then return false, "a stream passed more than it was fed" end
  local filter = TermFilter.new()
  local passed: {string} = {}
  for _ = 1, copies do passed[#passed + 1] = filter:feed(input) end
  if table.concat(passed) ~= out then return false, "copies fed one after another differ" end
  if #input > 0 then Fuzz.label("fed") end
  return true, ""
end

local function test_the_output_is_safe(tmp: string)
  Fuzz.run({
    name = "term filter output is safe",
    dir = tmp,
    gen = gen_stream,
    check = safe_holds,
    requires = { "answered", "a sequence passed", "a mode passed", "an osc", "a sequence dropped",
      "utf-8 passed", "nothing passed" },
  })
end

local function test_pieces_agree_with_the_whole(tmp: string)
  Fuzz.run({
    name = "term filter split feeding",
    dir = tmp,
    gen = gen_stream,
    check = split_holds,
    requires = { "passed", "answered", "utf-8" },
  })
end

local function test_the_work_is_linear(tmp: string)
  Fuzz.run({
    name = "term filter linear work",
    dir = tmp,
    gen = gen_stream,
    check = linear_holds,
    requires = { "fed" },
    iters = 24,
  })
end
