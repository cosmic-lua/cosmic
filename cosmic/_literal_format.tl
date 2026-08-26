--- The format half of cosmic.literal: format and format_file mirror
--- literal's parse and parse_file. A flat `_literal_format` sibling for
--- the same reason `_teal_engine` is one: literal.tl sits at the
--- file-length cap. The public surface is cosmic.literal's.
---
--- The renderer is this module's own rather than a general Lua encoder:
--- it serializes exactly the domain `parse` reads and refuses everything
--- else, so the two halves admit the same values. Its layout is fixed
--- and is a `cosmic --check fmt` fixpoint by construction, so a file
--- written here is a file this repo's own formatting gate accepts.

local cosmo = require("cosmo")

--- How deep a value may nest before format refuses it.
---
--- Mirrors `literal.tl`'s `MAX_DEPTH`, duplicated rather than imported
--- because literal.tl requires this module and reaching back for the
--- constant would close a cycle. The two move together: format must
--- refuse exactly the depth parse refuses.
local MAX_DEPTH < const > = 32

--- One string as a Lua short-string literal, on one line.
---
--- `%q` does the escaping, which is what makes every byte survive the
--- round trip through the lexer. Its one shape this layout cannot use is
--- the newline: `%q` writes it as a backslash followed by a REAL
--- newline, which is valid Lua and reads back correctly but splits an
--- entry across lines, and the formatter then moves the trailing comma
--- to a line of its own — so the file would no longer be its own fmt
--- fixpoint. Rewriting that one escape as `\n` keeps both properties:
--- the same bytes come back, on one line.
--- @param s string The string to render
--- @return string The quoted literal
local function quoted(s: string): string
  local out = string.format("%q", s):gsub("\\\n", "\\n")
  return out
end

--- True when a number has a spelling this grammar admits.
---
--- NaN and the infinities do not: Lua writes them as `0/0`,
--- `math.huge` and `-math.huge`, which are arithmetic and a global
--- read rather than literals, so the reader refuses all three.
--- @param n number The number
--- @return boolean True when the number is finite
local function is_finite(n: number): boolean
  return n == n and n ~= math.huge and n ~= -math.huge
end

--- Render one scalar the literal grammar admits.
---
--- Integers keep their exact spelling through `%d`; every other finite
--- number goes through `%.17g`, enough digits to name a double uniquely,
--- so the value parse reads back is the value that was written. The
--- integer test is `math.tointeger` rather than `math.type` because it
--- both classifies and converts in one step, and `%.17g` spells an
--- integral float the same way `%d` does. NaN and the infinities have no
--- spelling the grammar admits and are refused here.
--- @param v any The value
--- @return string|nil The rendered scalar, or nil when it is not one
local function scalar(v: any): string | nil
  if v is string then
    return quoted(v)
  end
  if v is boolean then
    return v and "true" or "false"
  end
  if v is number then
    if not is_finite(v) then
      return nil
    end
    local whole = math.tointeger(v)
    if whole then
      return string.format("%d", whole)
    end
    return string.format("%.17g", v)
  end
  return nil
end

--- The key path a message names: dotted, and just the key at the root.
--- @param path string The enclosing table's path, empty at the root
--- @param key string The key within it
--- @return string The path to that key
local function under(path: string, key: string): string
  if path == "" then
    return key
  end
  return path .. "." .. key
end

--- A refusal, prefixed with the key path when there is one.
--- @param path string The key path, empty at the root
--- @param what string What was refused
--- @return string The message
local function refusal(path: string, what: string): string
  if path == "" then
    return what
  end
  return path .. ": " .. what
end

--- The keys of one table, sorted bytewise.
---
--- Sorting is what makes the output deterministic, so a regenerated
--- baseline diffs as the rows that moved and nothing else.
--- @param t {string: any} The table
--- @param path string The table's key path, for the message
--- @return {string}|nil The sorted keys
--- @return string The error when a key is not a string
local function sorted_keys(t: {string: any}, path: string): {string} | nil, string
  local keys: {string} = {}
  for k in pairs(t as {any: any}) do -- cast: runtime keys are unconstrained
    if k is string then
      keys[#keys + 1] = k
    else
      return nil, refusal(under(path, tostring(k)),
        "a " .. type(k) .. " is not a string key")
    end
  end
  table.sort(keys)
  return keys
end

--- True when every value in `t` is a scalar this grammar accepts: no
--- nested table anywhere in it, so the whole table renders on one
--- line. Vacuously true for the empty table.
--- @param t {string: any} The table
--- @return boolean
local function all_scalar_values(t: {string: any}): boolean
  for _, v in pairs(t as {any: any}) do -- cast: runtime keys are unconstrained
    if v is {string: any} then
      return false
    end
  end
  return true
end

--- Render a flat table's entries as one line: `{[k] = v, ...}`, or
--- `{}` when empty -- no padding space just inside the braces, which
--- is what makes this a `cosmic --check fmt` fixpoint: the general
--- formatter strips that padding on an inline table. Every value must
--- already be known scalar (checked by `all_scalar_values` before
--- this is called).
--- @param t {string: any} The table to render
--- @param path string The table's key path, for a refusal message
--- @return string|nil The one-line rendering, or nil on a refusal
--- @return string The error naming the key path refused
local function render_inline(t: {string: any}, path: string): string | nil, string
  local keys, kerr = sorted_keys(t, path)
  if not keys then
    return nil, kerr
  end
  if #keys == 0 then
    return "{}"
  end
  local parts: {string} = {}
  for _, key in ipairs(keys) do
    local v = t[key]
    local here = under(path, key)
    local text = scalar(v)
    if not text then
      return nil, refusal(here, "a " .. type(v) .. " is not a literal")
    end
    parts[#parts + 1] = "[" .. quoted(key) .. "] = " .. text
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

--- Append one table's entries to `out`, one per line.
--- @param out {string} The lines rendered so far
--- @param t {string: any} The table to render
--- @param depth integer How many tables enclose this one, this one counted
--- @param path string The key path to `t`, empty at the root
--- @return boolean True when the whole subtree rendered
--- @return string The error naming the key path that was refused
local function render_table(out: {string}, t: {string: any}, depth: integer,
    path: string): boolean, string
  if depth > MAX_DEPTH then
    return false, refusal(path, "nests deeper than " .. MAX_DEPTH .. " tables")
  end
  local keys, kerr = sorted_keys(t, path)
  if not keys then
    return false, kerr
  end
  local pad = string.rep("  ", depth)
  for _, key in ipairs(keys) do
    local v = t[key]
    local here = under(path, key)
    -- The key goes through the same quoter as a string value: a key may
    -- hold any byte, newlines included, and `[%q]` alone would put one
    -- on a line of its own.
    local lead = pad .. "[" .. quoted(key) .. "] = "
    if v is {string: any} then
      if all_scalar_values(v) then
        local inline, ierr = render_inline(v, here)
        if not inline then
          return false, ierr
        end
        out[#out + 1] = lead .. inline .. ","
      else
        out[#out + 1] = lead .. "{"
        local ok, err = render_table(out, v, depth + 1, here)
        if not ok then
          return false, err
        end
        out[#out + 1] = pad .. "},"
      end
    else
      local text = scalar(v)
      if not text then
        return false, refusal(here, "a " .. type(v) .. " is not a literal")
      end
      out[#out + 1] = lead .. text .. ","
    end
  end
  return true
end

--- Serialize a value as a literal file's SOURCE: `return { ... }`,
--- newline-terminated, so `literal.parse(literal.format(v))` round-trips
--- and `cosmic --check fmt` leaves the result byte-for-byte alone.
---
--- The domain is exactly the one parse reads: the value is a table, its
--- keys are strings, and its values are strings, finite numbers,
--- booleans, or nested such tables, at most 32 tables deep. Everything
--- else — an array-style table, a function, a non-string key, NaN or an
--- infinity — is refused by key path rather than written as source parse
--- would then have to reject.
---
--- The layout is fixed: `return {}` for an empty table, otherwise one
--- entry per line, indented two spaces per nesting depth, every entry
--- ending in a comma, every key bracketed and quoted, keys sorted
--- bytewise at every depth. A nested table whose own values are all
--- scalars (vacuously true when it is empty) is the one exception:
--- it renders on the SAME line as its key, `{[k] = v, ...},` or
--- `{},` when empty, instead of spanning multiple lines — a nested
--- table containing a table keeps the multi-line layout.
--- @param value any The value to serialize
--- @return string | nil The literal source, or nil when the value is outside the domain
--- @return string? Error message on failure, naming the key path refused
local function format(value: any): string | nil, string
  if value is {string: any} then
    local out: {string} = {}
    local ok, err = render_table(out, value, 1, "")
    if not ok then
      return nil, err
    end
    if #out == 0 then
      return "return {}\n"
    end
    return "return {\n" .. table.concat(out, "\n") .. "\n}\n"
  end
  return nil, "a " .. type(value) .. " is not a literal table"
end

--- Serialize a value the compact way: the same domain and the same
--- refusals as `format`, on one line, through the C encoder.
---
--- `format`'s layout is a `cosmic --check fmt` fixpoint, which is what
--- a committed file wants and what costs the time: every key and every
--- string goes through `%q` and the lines are assembled in Lua. This
--- writer is for the bulk case that is read back by machine and never
--- formatted — it hands the value to the C encoder in one pass, which
--- is several times faster and smaller on the wire, at the price of the
--- fixpoint promise and the one-entry-per-line layout.
---
--- `literal` is what makes that safe. Without it the encoder describes
--- rather than serializes: a function becomes the string `"func@0x…"`
--- and a cycle the string `"cyclic@0x…"`, which the reader then accepts
--- as plain strings, so the value that comes back is quietly not the
--- value that went in. With it the encoder answers the domain question
--- on the pass it was already making, and refuses instead of describing.
---
--- `maxdepth` is pinned to `MAX_DEPTH` because the binding's default is
--- deeper than the reader accepts: left alone it would spell a value
--- nested past the reader's limit, which then cannot be read back. The
--- two sides count depth from different ends, so a table nested exactly
--- `MAX_DEPTH` deep with contents is refused here and rendered by the
--- pin layout instead — the same value, the other layout.
---
--- Whatever the encoder turns down goes to the renderer, and that one
--- handoff covers both reasons it can turn something down. A value
--- outside the grammar gets the renderer's refusal, which is the
--- message BOTH layouts give for that input, so naming the offending
--- key path stays written down once. A value inside the grammar that
--- the encoder cannot spell gets the pin layout, which can spell
--- anything the grammar admits: the compact layout is a request for
--- smaller output, never a narrower domain, so no caller has to know
--- that `{["end"] = 1}` is a special case. The encoder's own reason is
--- discarded for that reason — the renderer's message is the one both
--- layouts give.
---
--- `sorted` is not optional either: it is what makes the output
--- deterministic, so the same value serializes to the same bytes.
--- @param value any The value to serialize
--- @return string | nil The literal source, or nil when the value is outside the domain
--- @return string? Error message on failure, naming the key path refused
local function format_compact(value: any): string | nil, string
  if value is {any: any} then
    local encoded = cosmo.EncodeLua(value,
      {sorted = true, literal = true, maxdepth = MAX_DEPTH})
    if not encoded then
      return format(value)
    end
    return "return " .. encoded .. "\n"
  end
  return nil, "a " .. type(value) .. " is not a literal table"
end

--- Write a value as a literal file: format, then write to path.
--- The file variant of format (the `<verb>_file` convention), the
--- mirror of parse_file. A value format refuses is never written.
--- @param path string Where to write
--- @param value any The value to serialize
--- @return boolean True on success
--- @return string? Error message on failure
local function format_file(path: string, value: any): boolean, string
  local body, err = format(value)
  if not body then
    return false, err
  end
  local ok, werr = require("cosmic.fs").write(path, body)
  if not ok then
    return false, werr
  end
  return true
end

local record LiteralFormatModule
  format: function(value: any): string | nil, string
  format_compact: function(value: any): string | nil, string
  format_file: function(path: string, value: any): boolean, string
end

local M: LiteralFormatModule = {
  format = format,
  format_compact = format_compact,
  format_file = format_file,
}

return M
