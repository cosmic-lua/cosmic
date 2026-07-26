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
local sys = require("cosmic.sys")

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
  --- Optional archive format ("zip" or "tar.gz"). A pin that declares
  --- one is unpacked after it is verified; a pin without one is bytes.
  format: string
  --- The platform key this pin resolved through: the host's tag, `*`
  --- for a pin that is the same everywhere, or "" for one that names
  --- its digest at the top level.
  platform: string
  --- Leading path segments to drop when unpacking, for archives that
  --- wrap their contents in a directory named for the release.
  strip_components: integer
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

--- One platform's half of a pin: the fields that may differ per host.
---
--- A pin whose bytes are the same everywhere (a fat binary, a source
--- tarball) says so with `platforms = {["*"] = …}` or by naming
--- `sha256` at the top level; one whose bytes differ carries a row per
--- `os-arch` tag. Either way the resolved Pin has exactly one digest,
--- so nothing downstream has to know which shape it came from.
--- @param fields {string: any} The pin's declared table
--- @return {string: any}|nil The matching platform row, or nil
--- @return string The platform key it matched
local function platform_row(fields: {string: any}): {string: any} | nil, string
  local platforms = fields.platforms
  if not (platforms is {string: any}) then
    return nil, ""
  end
  local host = sys.platform()
  local row = platforms[host]
  if row is {string: any} then
    return row, host
  end
  local any = platforms["*"]
  if any is {string: any} then
    return any, "*"
  end
  return nil, host
end

--- Read and validate one pin file.
---
--- `url` and a digest are required — a pin without one is a download,
--- and the point of a pin is that the bytes are named. The digest is
--- either `sha256` at the top level or `sha` on the matching
--- `platforms` row; the two spellings exist because this reader and
--- the older `_build` fetcher read the same committed files, and a pin
--- that had to be written twice would be a pin that can disagree with
--- itself. An optional `version` is substituted into `{version}` in
--- the URL, and the resolved platform tag into `{platform}` — the only
--- templating this grammar allows, and the reason a bump is a one-line
--- diff.
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
  local row, platform = platform_row(fields)
  local plat: {string: any} = {}
  if row is {string: any} then
    plat = row
  elseif fields.platforms ~= nil then
    return nil, "make: " .. path .. ": no platform row for " .. platform ..
    " and no '*'"
  end
  local url = fields.url
  local sha = fields.sha256
  if not (sha is string) then
    sha = plat.sha
  end
  local version_field = fields.version
  local version: string = nil
  if version_field is string then
    version = version_field
  end
  if not (url is string) or url == "" then
    return nil, "make: " .. path .. ": a pin needs a url"
  end
  if not (sha is string) then
    return nil, "make: " .. path ..
    ": a pin needs a sha256 (hex); without one it is a download, not a pin"
  end
  -- Exactly 64, not "8 or more": a truncated digest is a common
  -- copy-paste slip, and the old pattern accepted it. Every fetch then
  -- failed with `sha256 mismatch`, which is a correct refusal wearing
  -- the wrong diagnosis -- it sends the reader to check the url when
  -- the pin's own digest is what is malformed.
  if not sha:match("^%x+$") or #sha ~= 64 then
    return nil, "make: " .. path .. ": sha256 must be 64 hex characters, got " ..
    #sha .. "; a truncated digest fails later as a mismatch"
  end
  local format_field = fields.format
  if not (format_field is string) then
    format_field = plat.format
  end
  local format: string = nil
  if format_field is string then
    format = format_field
  end
  local strip_field = fields.strip_components
  local strip = 0
  if strip_field is number then
    strip = math.tointeger(strip_field) or 0
  end
  local resolved = url
  if version then
    resolved = (url:gsub("{version}", version))
  end
  if platform ~= "" then
    resolved = (resolved:gsub("{platform}", platform))
  end
  -- The output name comes from the URL, not the pin's position: a pin
  -- fetches a named artifact and its extension matters to whatever
  -- reads it next. It is url-derived, so it is checked before it
  -- reaches `fs.join`: a query string, a `..`, or a backslash in the
  -- tail would otherwise survive into the landing path and break the
  -- "mirrors the pin's position" contract the build relies on. The
  -- older `_build` fetcher validates the same derivation.
  local name = resolved:match("([^/]+)$") or ""
  if name == "" or name == "." or name == ".."
  or not name:match("^[%w._%-]+$") then
    return nil, "make: " .. path .. ": the url's last segment is not a usable " ..
    "file name: '" .. name .. "'"
  end
  return {
    source = path,
    output = fs.join(fs.dirname(path), name),
    url = resolved,
    sha256 = sha:lower(),
    version = version,
    format = format,
    platform = platform,
    strip_components = strip,
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
