--- The one place a source is scanned for `require` edges.
---
--- Four consumers want this answer and it must be the SAME answer: the
--- validator (which REFUSES a project over a cross-`cmd` import), the
--- dependency closure (which turns edges into prerequisites), the facts
--- writer (a closure per compiled file), and the fence (which will grant
--- reads from it). While each scanned for itself they drifted --- one
--- got comment handling and a frontier anchor, the others did not ---
--- so the same file had different imports depending on who asked. A
--- commented-out require was invisible to the gate and a phantom
--- prerequisite to the graph at the same time.
---
--- Scanning is also the model's hot loop: every consumer re-read and
--- re-matched every source, and the facts writer does it once per
--- compiled file. `of_file` reads and scans each path once per model
--- build; `forget` starts the next one.
---
--- What is deliberately NOT found: a computed require
--- (`require(name)`). A project that computes its module names has left
--- the shape the model describes, and the consequence is a denied read
--- rather than a wrong one.

local fs = require("cosmic.fs")

--- Skip a long bracket (`[[`, `[==[`, …) opening at `i`.
---
--- Used for long strings and, one character further in, long comments.
--- @param src string The source
--- @param i integer Index of the opening `[`
--- @return integer The index just past the close, or past end-of-source
local function past_long_bracket(src: string, i: integer): integer
  local eq = src:match("^%[(=*)%[", i)
  if not eq then
    return i + 1
  end
  local close = "]" .. eq .. "]"
  local at = src:find(close, i + #eq + 2, true)
  if not at then
    return #src + 1
  end
  return at + #close
end

--- Skip a short string opening at `i`, honouring backslash escapes.
--- @param src string The source
--- @param i integer Index of the opening quote
--- @return integer The index just past the closing quote
local function past_short_string(src: string, i: integer): integer
  local quote = src:sub(i, i)
  local n = #src
  local j = i + 1
  while j <= n do
    local c = src:sub(j, j)
    if c == quote then
      return j + 1
    end
    -- An unterminated string ends at the newline, the way Lua's own
    -- lexer would; scanning is best-effort over sources that may not
    -- even compile yet.
    if c == "\n" then
      return j
    end
    j = j + (c == "\\" and 2 or 1)
  end
  return n + 1
end

--- The literal `require("…")` targets in a source, in file order.
---
--- A scan and not a regex sweep, because the three shapes that fooled a
--- regex are all lexical: a require inside a `--[[ … ]]` block (a
--- line-comment strip removes only the opener's line, so the interior
--- still matched and REFUSED the project); a `--` inside a string
--- literal (which truncated the rest of the line, losing real requires);
--- and `myrequire("x")` (an identifier ending in the word). Walking
--- strings and comments as units answers all three by construction
--- rather than by a longer pattern.
--- @param src string The source text
--- @return {string} Imported module names, in file order
local function scan(src: string): {string}
  local out: {string} = {}
  local n = #src
  local i = 1
  while i <= n do
    local c = src:sub(i, i)
    if c == "-" and src:sub(i + 1, i + 1) == "-" then
      if src:match("^%[=*%[", i + 2) then
        i = past_long_bracket(src, i + 2)
      else
        i = src:find("\n", i, true) or n + 1
      end
    elseif c == "[" and src:match("^%[=*%[", i) then
      i = past_long_bracket(src, i)
    elseif c == '"' or c == "'" then
      i = past_short_string(src, i)
    elseif c:match("[%a_]") then
      local word = src:match("^[%a_][%w_]*", i)
      i = i + #word
      if word == "require" then
        local name = src:match("^%s*%(?%s*[\"']([%w_%.%-]+)[\"']", i)
        if name then
          out[#out + 1] = name
        end
      end
    else
      i = i + 1
    end
  end
  return out
end

--- Edges scanned so far this model build, by absolute path.
local cache: {string: {string}} = {}

--- Drop the memo. Called when a project is scanned, so the map's
--- lifetime is one model build: within a build the tree is a snapshot
--- and re-reading it can only cost time, across builds it may have
--- changed and re-reading is the point.
local function forget()
  cache = {}
end

--- The imports of a source file, read once per model build.
--- An unreadable file has no edges -- the validator reports missing
--- files by their own rule, not through this one.
--- @param path string Absolute path to the source
--- @return {string} Imported module names, in file order
local function of_file(path: string): {string}
  local hit = cache[path]
  if hit then
    return hit
  end
  local content = fs.read(path)
  local found = content and scan(content as string) or {} -- cast: scalar narrowing
  cache[path] = found
  return found
end

local record ImportsModule
  scan: function(src: string): {string}
  of_file: function(path: string): {string}
  forget: function()
end

local M: ImportsModule = {
  scan = scan,
  of_file = of_file,
  forget = forget,
}

return M
