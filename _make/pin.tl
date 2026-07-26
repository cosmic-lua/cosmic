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
---
--- The grammar itself now lives in `cosmic.literal`, which is public:
--- it turned out to have callers outside `cosmic/` (this repo reads its
--- own dependency pins with it), and "a config file that cannot do
--- anything" is worth more than one caller. What stays here is what is
--- specific to a PIN: url, sha256, `{version}` substitution, and where
--- the fetched bytes land.

local fs = require("cosmic.fs")
local literal = require("cosmic.literal")

--- A resolved pin.
local record Pin
  --- Path to the `*.pin.tl`, relative to the project root.
  source: string
  --- The asset's name and position, relative to the project root.
  --- Where the bytes actually LAND is the build's business, not the
  --- pin's: `fetch` puts them under the build directory.
  output: string
  --- The URL to fetch, after `{version}` substitution.
  url: string
  --- Expected sha256 of the fetched bytes, lowercase hex.
  sha256: string
  --- Optional version, substituted into `{version}` in the URL.
  version: string
end

--- Extract the literal a pin file returns, without running it.
---
--- The grammar lives in `cosmic.literal`; the `"pin"` noun is what
--- makes its complaints say "a pin holds literals only" rather than
--- something generic, since a pin is what the author was writing.
--- @param source string The file's contents
--- @param where string File name, for messages
--- @return {string: any}|nil The declared table
--- @return string The error message when the file is not a literal pin
local function extract(source: string, where: string): {string: any} | nil, string
  return literal.of_source(source, where, "pin")
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
