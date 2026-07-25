--- Pins: `*.pin.tl` is Teal **data**, not Teal code.
---
--- A pin declares an external asset — a URL and the sha256 of the bytes
--- it must produce. Fetching is deliberately NOT a generator: a
--- generator runs code, and the whole posture here is that a build runs
--- only bytes you pinned. So a pin is read the way a config file is
--- read: lexed, matched against a literal grammar, and turned into a
--- table. It is never loaded, never compiled to a chunk, never called.
---
--- The grammar is exactly one `return { … }` of literals. No
--- concatenation, no variables, no function calls — not because those
--- are hard, but because "this file cannot do anything" is the property
--- worth having. A pin that wants to compute its URL is a pin that
--- wants to be code, and the answer is no.

local fs = require("cosmic.fs")
local tl = require("tl")

--- A resolved pin.
local record Pin
  --- Path to the `*.pin.tl`, relative to the project root.
  source: string
  --- Where the fetched bytes land, relative to the project root.
  output: string
  --- The URL to fetch, after `{version}` substitution.
  url: string
  --- Expected sha256 of the fetched bytes, lowercase hex.
  sha256: string
  --- Optional version, substituted into `{version}` in the URL.
  version: string
end

--- Token kinds the literal grammar admits, beyond punctuation.
local scalar: {string: boolean} = {
  string = true,
  number = true,
  integer = true,
}

--- Parse a literal table from a token stream, starting at `{`.
--- Returns the value and the index just past the closing `}`.
--- @param toks {tl.Token} The lexed tokens
--- @param i integer Index of the opening brace
--- @param where string File name, for messages
--- @return {string: any}|nil The table, or nil on a grammar violation
--- @return integer|string Next index, or the error message
local function parse_table(toks: {tl.Token}, i: integer, where: string): {string: any} | nil, integer | string
  local out: {string: any} = {}
  local n = #toks
  i = i + 1 -- step over `{`
  while i <= n do
    local t = toks[i]
    if t.tk == "}" then
      return out, i + 1
    end
    -- key: `name =` or `["name"] =`
    local key: string = nil
    if t.kind == "identifier" and toks[i + 1] and toks[i + 1].tk == "=" then
      key = t.tk
      i = i + 2
    elseif t.tk == "[" and toks[i + 1] and toks[i + 1].kind == "string"
    and toks[i + 2] and toks[i + 2].tk == "]"
    and toks[i + 3] and toks[i + 3].tk == "=" then
      key = toks[i + 1].tk:sub(2, -2)
      i = i + 4
    else
      return nil, where .. ":" .. tostring(t.y) ..
      ": a pin is a table of `name = <literal>` entries; found '" ..
      t.tk .. "'"
    end
    -- value: a scalar, a keyword literal, or a nested table
    local v = toks[i]
    if not v then
      return nil, where .. ": unexpected end of pin"
    end
    if v.tk == "{" then
      local sub, nexti = parse_table(toks, i, where)
      if not sub then
        return nil, nexti as string -- cast: the failure branch returns a message
      end
      out[key] = sub
      i = nexti as integer -- cast: the success branch returns an index
    elseif v.kind == "string" then
      out[key] = v.tk:sub(2, -2)
      i = i + 1
    elseif scalar[v.kind] then
      out[key] = tonumber(v.tk)
      i = i + 1
    elseif v.tk == "true" or v.tk == "false" then
      out[key] = v.tk == "true"
      i = i + 1
    else
      return nil, where .. ":" .. tostring(v.y) ..
      ": a pin holds literals only; found '" .. v.tk ..
      "' (no variables, calls or concatenation)"
    end
    -- A value is followed by a separator or the closing brace, and
    -- nothing else. Without this an operator after a literal (`"a" ..
    -- "b"`) would be read as the next key, and the complaint would be
    -- about a missing name rather than about the concatenation.
    local sep = toks[i]
    if sep and (sep.tk == "," or sep.tk == ";") then
      i = i + 1
    elseif not sep or sep.tk ~= "}" then
      return nil, where .. ":" .. tostring(v.y) ..
      ": a pin holds literals only; found '" .. (sep and sep.tk or "<eof>") ..
      "' after a value (no variables, calls or concatenation)"
    end
  end
  return nil, where .. ": unterminated table in pin"
end

--- Extract the literal a pin file returns, without running it.
--- @param source string The file's contents
--- @param where string File name, for messages
--- @return {string: any}|nil The declared table
--- @return string The error message when the file is not a literal pin
local function extract(source: string, where: string): {string: any} | nil, string
  local toks, lex_errs = tl.lex(source, where)
  if lex_errs and #lex_errs > 0 then
    local e = lex_errs[1]
    return nil, where .. ":" .. tostring(e.y) .. ": " .. tostring(e.msg)
  end
  local i = 1
  -- The lexer emits an `$EOF$` sentinel; everything before the `return`
  -- must be nothing at all.
  if not toks[i] or toks[i].tk ~= "return" then
    return nil, where .. ": a pin must be exactly `return { … }`"
  end
  i = i + 1
  if not toks[i] or toks[i].tk ~= "{" then
    return nil, where .. ": a pin must return a table literal"
  end
  local value, nexti = parse_table(toks, i, where)
  if not value then
    return nil, nexti as string -- cast: the failure branch returns a message
  end
  local after = toks[nexti as integer] -- cast: the success branch returns an index
  if after and after.tk ~= "$EOF$" then
    return nil, where .. ":" .. tostring(after.y) ..
    ": a pin ends after its table; found '" .. after.tk .. "'"
  end
  return value
end

--- Read and validate one pin file.
---
--- `url` and `sha256` are required — a pin without a digest is a
--- download, and the point of a pin is that the bytes are named. An
--- optional `version` is substituted into `{version}` in the URL, which
--- is the one templating this grammar allows and the reason a bump is a
--- one-line diff.
--- @param path string Path to the `*.pin.tl`, relative to the root
--- @return Pin|nil The resolved pin
--- @return string The error message
local function read(path: string): Pin | nil, string
  local source, rerr = fs.read(path)
  if not source then
    return nil, "make: cannot read " .. path .. ": " .. (rerr or "unknown error")
  end
  local data, eerr = extract(source, path)
  if not data then
    return nil, "make: " .. (eerr or "not a pin")
  end
  local fields = data as {string: any} -- cast: record union after the guard
  local url = fields.url
  local sha = fields.sha256
  local version_field = fields.version
  local version: string = nil
  if version_field is string then
    version = version_field
  end
  if not (url is string) or url == "" then
    return nil, "make: " .. path .. ": a pin needs a url"
  end
  if not (sha is string) or not sha:match("^%x%x%x%x%x%x%x%x+$") then
    return nil, "make: " .. path ..
    ": a pin needs a sha256 (hex); without one it is a download, not a pin"
  end
  local resolved = url
  if version then
    resolved = (url:gsub("{version}", version))
  end
  -- The output name comes from the URL, not the pin's position: a pin
  -- fetches a named artifact and its extension matters to whatever
  -- reads it next.
  local name = resolved:match("([^/]+)$") or "asset"
  return {
    source = path,
    output = fs.join(fs.dirname(path), name),
    url = resolved,
    sha256 = sha:lower(),
    version = version,
  }
end

local record PinModule
  type Pin = Pin
  extract: function(source: string, where: string): {string: any} | nil, string
  read: function(path: string): Pin | nil, string
end

local M: PinModule = {
  extract = extract,
  read = read,
}

return M
