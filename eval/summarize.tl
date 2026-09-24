--- Numbers from a Claude Code stream-json transcript: turns, tool calls,
--- minutes, cost, then the friction the journal may not admit to --
--- failed tool calls, `cosmic docs` lookups that found no exact match,
--- the tool call at which `cosmic test` first passed, and how many times
--- the journal was written (one write at the end is a retelling, not a
--- log). Last, every absolute path a tool call named outside the arena,
--- and any mention of this repository or a skills directory: those are
--- contamination or boundary breaches to check before trusting the run.
--- Another agent's transcript needs its own reader.
---
---     cosmic --standalone eval/summarize.tl <arena>/transcript.jsonl
---
--- `eval/summarize` runs this on the bootstrap cosmic, as bin/vendor
--- runs build/vendor.tl: it requires `cosmic.*` modules only. The arena
--- is the transcript's own directory, and the repository is found from
--- this script's path, both with every link resolved.
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")

local record Summarize
end

--- What `summarize` reads from one tool call: its name, its input as
--- JSON text, and the input's fields that say where it acts.
local record Call
  id: string
  name: string
  given: string
  where: string
end

--- What a tool call answered: whether it failed, and its text.
local record Answer
  error: boolean
  text: string
end

--- System locations a shell call may name without leaving the arena.
local system <const>: {string} = {
  "/usr/", "/bin/", "/sbin/", "/lib/", "/etc/", "/dev/", "/proc/", "/opt/",
}

--- How deep a transcript line may nest: as deep as cosmic.json reads.
local max_depth <const> = 1000

local function count(text: string, needle: string): integer
  local n = 0
  local at = 1
  while true do
    local s, e = text:find(needle, at, true)
    if s == nil then
      return n
    end
    n = n + 1
    at = e + 1
  end
end

--- The code point of the UTF-8 character at `at`, and its length; a
--- byte that does not start one is a character of its own.
local function char_at(text: string, at: integer): integer, integer
  local b = text:byte(at)
  local size = b >= 0xf0 and 4 or b >= 0xe0 and 3 or b >= 0xc0 and 2 or 1
  if size == 1 or at + size - 1 > #text then
    return b, 1
  end
  local cp = b & (0x7f >> size)
  for i = at + 1, at + size - 1 do
    local c = text:byte(i)
    if c & 0xc0 ~= 0x80 then
      return b, 1
    end
    cp = (cp << 6) | (c & 0x3f)
  end
  return cp, size
end

--- The start of the UTF-8 character that ends just before `at`.
local function char_before(text: string, at: integer): integer
  local start = at - 1
  while start > 1 and at - start < 4 and text:byte(start) & 0xc0 == 0x80 do
    start = start - 1
  end
  return start
end

--- Whether a code point is a word character, as Python's `\w` takes
--- it: a letter, digit or `_`. Past ASCII, anything but the spaces
--- and punctuation a command is likely to hold -- Latin-1's, the
--- General and CJK Punctuation blocks, and the fullwidth forms' --
--- counts as one.
local function is_word(cp: integer): boolean
  if cp < 0x80 then
    local c = string.char(cp)
    return c:match("[%w_]") ~= nil
  end
  return not (cp <= 0xbf or (cp >= 0x2000 and cp <= 0x206f) or
    (cp >= 0x2e00 and cp <= 0x2e7f) or (cp >= 0x3000 and cp <= 0x303f) or
    (cp >= 0xff00 and cp <= 0xff0f) or (cp >= 0xff1a and cp <= 0xff20) or
    (cp >= 0xff3b and cp <= 0xff40) or (cp >= 0xff5b and cp <= 0xff65))
end

-- TODO: take Python's `\w` past ASCII from Unicode's letter, digit
-- and connector categories, once cosmic carries a table of them;
-- is_word's ranges are an approximation, so a symbol such as `→`
-- counts as part of a path here.

--- A character a path is made of: a word character, or `.@+-`.
local function is_path_char(cp: integer): boolean
  return is_word(cp) or cp == 0x2e or cp == 0x40 or cp == 0x2b or cp == 0x2d
end

--- A character that, just before a `/`, makes it part of something
--- other than an absolute path: `a/b`, `./b`, `$HOME/b`, `~/b`, `<x>/b`.
--- Only ASCII ones do: past ASCII, where is_word only approximates
--- Python, a path is reported rather than missed.
local function is_not_before(cp: integer): boolean
  return cp < 0x80 and (is_word(cp) or cp == 0x2e or cp == 0x24 or cp == 0x7e or
    cp == 0x3c or cp == 0x3e)
end

--- Where the `/name` segment at `at` ends, or nil when `at` holds none.
local function segment(text: string, at: integer): integer | nil
  if text:byte(at) ~= 0x2f then
    return nil
  end
  local stop: integer = nil
  local i = at + 1
  while i <= #text do
    local cp, size = char_at(text, i)
    if not is_path_char(cp) then
      break
    end
    stop = i + size - 1
    i = i + size
  end
  return stop
end

--- Every absolute path in `text`, in order: a `/` no path character
--- precedes, then one or more `/name` segments.
function Summarize.paths(text: string): {string}
  local found: {string} = {}
  local at = 1
  while at <= #text do
    local slash = text:find("/", at, true)
    if slash == nil then
      break
    end
    local after = slash + 1
    if slash == 1 or not is_not_before((char_at(text, char_before(text, slash)))) then
      local stop = slash - 1
      while true do
        local e = segment(text, stop + 1)
        if e == nil then
          break
        end
        stop = e
      end
      if stop >= slash then
        found[#found + 1] = text:sub(slash, stop)
        after = stop + 1
      end
    end
    at = after
  end
  return found
end

--- A line with every lone surrogate escape (`\ud83d` with no low half
--- after it, or a low half alone) written as U+FFFD, which cosmic.json
--- would otherwise refuse the whole line for. Claude Code writes one
--- when it cuts a tool's output in the middle of an emoji.
-- TODO: decode with an option that takes a lone surrogate as it
-- stands, once cosmic.json carries one (yyjson reads with
-- YYJSON_READ_ALLOW_INVALID_UNICODE), rather than rewriting the escape.
function Summarize.without_lone_surrogates(line: string): string
  local out: {string} = {}
  local from = 1
  local at = 1
  while true do
    local s = line:find("\\", at, true)
    if s == nil then
      break
    end
    local hex = line:match("^u(%x%x%x%x)", s + 1)
    if hex == nil then
      at = s + 2
    else
      local unit = tonumber(hex, 16)
      local low = line:match("^\\u(%x%x%x%x)", s + 6)
      local low_unit = low ~= nil and tonumber(low, 16) or 0
      if unit >= 0xd800 and unit <= 0xdbff and low_unit >= 0xdc00 and low_unit <= 0xdfff then
        at = s + 12
      elseif unit >= 0xd800 and unit <= 0xdfff then
        out[#out + 1] = line:sub(from, s - 1)
        out[#out + 1] = "\\ufffd"
        from = s + 6
        at = from
      else
        at = s + 6
      end
    end
  end
  out[#out + 1] = line:sub(from)
  return table.concat(out)
end

--- One line's value, or nil. A lone surrogate, which Python's
--- json.loads also reads, is read as U+FFFD.
local function decode(line: string): any
  local value, trouble = Json.decode(line, { max_depth = max_depth })
  if trouble:find("surrogate", 1, true) then
    value = Json.decode(Summarize.without_lone_surrogates(line), { max_depth = max_depth })
  end
  return value
end

local function starts(text: string, prefix: string): boolean
  return text:sub(1, #prefix) == prefix
end

local function is_system(path: string): boolean
  for _, prefix in ipairs(system) do
    if starts(path, prefix) or path .. "/" == prefix then
      return true
    end
  end
  return false
end

--- A value as text, for a field whose value need not be a string.
local function as_text(value: any): string
  if value == nil then
    return ""
  elseif value is string then
    return value
  elseif value is number or value is boolean then
    return tostring(value)
  end
  return Json.encode(value, { max_depth = max_depth }) or ""
end

--- A tool call's id as a key: a number that is a whole one names the
--- same call whether it is written `1` or `1.0`, as it would in Python.
local function id_key(value: any): string
  if value is number and math.tointeger(value) ~= nil then
    return tostring(math.tointeger(value))
  end
  return as_text(value)
end

--- Whether a value is true as Python's `bool` takes it: not nil,
--- false, zero, or an empty string or table.
local function truthy(value: any): boolean
  if value is string then
    return value ~= ""
  elseif value is number then
    return value ~= 0
  elseif value is table then
    return next(value) ~= nil
  end
  return value ~= nil and value ~= false
end

--- Whether a call wrote the journal: its input names JOURNAL.md, and it
--- is a Write or an Edit, or a shell redirection or `tee` into it.
local function writes_journal(call: Call): boolean
  local given = call.given
  if not given:find("JOURNAL.md", 1, true) then
    return false
  end
  return call.name == "Write" or call.name == "Edit" or
    given:find(">>?%s*%S*JOURNAL%.md") ~= nil or
    given:find("tee%f[^%w_][^|]*JOURNAL%.md") ~= nil
end

--- The report for a transcript's text, one line per fact, given the
--- arena and repository as absolute paths.
function Summarize.report(transcript: string, arena: string, repo: string): string
  local calls: {Call} = {}
  local results: {string: Answer} = {}
  local result: {string: any} = nil
  -- Lines end as Python's universal newlines end them.
  for line in transcript:gsub("\r\n?", "\n"):gmatch("[^\n]+") do
    local event = decode(line)
    if event is {string: any} then
      local kind = event["type"]
      local message = event["message"]
      local content: any = message is {string: any} and message["content"] or nil
      if kind == "assistant" and content is {any} then
        for _, part in ipairs(content) do
          if part is {string: any} and part["type"] == "tool_use" then
            local input = part["input"]
            local where: {string} = {}
            for _, key in ipairs({ "command", "file_path", "path", "pattern" }) do
              where[#where + 1] = input is {string: any} and as_text(input[key]) or ""
            end
            calls[#calls + 1] = {
              id = id_key(part["id"]),
              name = as_text(part["name"]),
              given = Json.encode(input, { max_depth = max_depth }) or "",
              where = table.concat(where, " "),
            }
          end
        end
      elseif kind == "user" and content is {any} then
        for _, part in ipairs(content) do
          if part is {string: any} and part["type"] == "tool_result" then
            local body = part["content"]
            local text: string
            if body is {any} then
              local pieces: {string} = {}
              for _, piece in ipairs(body) do
                pieces[#pieces + 1] = piece is {string: any} and as_text(piece["text"]) or ""
              end
              text = table.concat(pieces, " ")
            else
              text = as_text(body)
            end
            results[id_key(part["tool_use_id"])] = {
              error = truthy(part["is_error"]),
              text = text,
            }
          end
        end
      elseif kind == "result" then
        result = event
      end
    end
  end

  local failed, docs_misses, journal_writes = 0, 0, 0
  local first_green: integer = nil
  local outside: {string: boolean} = {}
  local tainted: {string: boolean} = {}
  for index, call in ipairs(calls) do
    local answer = results[call.id]
    local text = answer ~= nil and answer.text or ""
    if answer ~= nil and answer.error then
      failed = failed + 1
    end
    docs_misses = docs_misses + count(text, "No exact symbol match") + count(text, "docs: FAIL")
    if first_green == nil and text:find("test: PASS", 1, true) then
      first_green = index
    end
    if writes_journal(call) then
      journal_writes = journal_writes + 1
    end
    -- Where the call acts, not what it writes: a file's own contents
    -- would otherwise count every path its prose mentions.
    for _, path in ipairs(Summarize.paths(call.where)) do
      if not (path == arena or starts(path, arena .. "/") or is_system(path)) then
        outside[path] = true
      end
    end
    for _, mark in ipairs({ repo, ".claude/skills", ".claude/plugins" }) do
      if call.given:find(mark, 1, true) then
        tainted[mark] = true
      end
    end
  end

  local out: {string} = {}
  if result ~= nil then
    local turns = result["num_turns"]
    local ms = result["duration_ms"]
    local cost = result["total_cost_usd"]
    out[#out + 1] = string.format("turns=%s tools=%d minutes=%.1f cost=$%.2f",
      turns == nil and "null" or as_text(turns), #calls,
      (ms is number and ms or 0) / 60000, cost is number and cost or 0)
  else
    out[#out + 1] = string.format(
      "turns=null tools=%d minutes=null cost=null (no result event: timed out?)", #calls)
  end
  out[#out + 1] = string.format(
    "failed_calls=%d docs_misses=%d first_green_test_call=%s journal_writes=%d",
    failed, docs_misses, first_green == nil and "null" or tostring(first_green),
    journal_writes)
  local function sorted(set: {string: boolean}): {string}
    local list: {string} = {}
    for key in pairs(set) do
      list[#list + 1] = key
    end
    table.sort(list)
    return list
  end
  for _, path in ipairs(sorted(outside)) do
    out[#out + 1] = "outside-arena: " .. path
  end
  for _, mark in ipairs(sorted(tainted)) do
    out[#out + 1] = "CONTAMINATION: a tool call named " .. mark
  end
  return table.concat(out, "\n") .. "\n"
end

local function complain(message: string)
  Fs.put(Fs.stderr, "eval/summarize: " .. message .. "\n")
end

function Summarize.main(argv: {integer: string}): integer
  local transcript = argv[1]
  if transcript == nil or argv[2] ~= nil then
    Fs.put(Fs.stderr, "usage: eval/summarize <transcript.jsonl>\n")
    return 2
  end
  local script, strouble = Fs.absolute(argv[0])
  if script == nil then
    complain(strouble)
    return 2
  end
  local repo = script:match("^(.*)/eval/[^/]+%.tl$")
  if repo == nil then
    complain(argv[0] .. ": expected to run as .../eval/summarize.tl")
    return 2
  end
  local parent = transcript:match("^(.*)/[^/]*$") or "."
  local arena, atrouble = Fs.absolute(parent == "" and "/" or parent)
  if arena == nil then
    complain(atrouble)
    return 2
  end
  local text, trouble = Fs.read(transcript)
  if text == nil then
    complain(trouble)
    return 1
  end
  Fs.put(Fs.stdout, Summarize.report(text, arena, repo))
  return 0
end

return Summarize
