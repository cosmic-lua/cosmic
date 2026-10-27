--- Where a web program's static files come from: embedded in the
--- executable (the files under the project's `static/`), read from a
--- directory (development), or held in memory (tests, generated files).
--- [`cosmic.web.static`] serves any of them; a handler may read a bundled file
--- through one too (a favicon, a font to embed in a PDF).
---
---     local Assets = require("cosmic.web.assets")
---
---     local source = Assets.memory({ ["css/app.css"] = "body{margin:0}" })
---     local asset = assert(source:get("css/app.css"))
---     assert(asset.type == "text/css; charset=utf-8")
---     assert(asset.etag == '"' .. asset.sha256:sub(1, 32) .. '"')

local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Mime = require("cosmic.mime")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")

local record Assets
  --- An algorithm an [`Assets.Asset`]'s `integrity` can name.
  enum Algorithm
    "sha256"
    "sha384"
    "sha512"
  end

  --- One file of a source, immutable once returned: `data` is the bytes
  --- whatever mode the source reads in.
  record Asset
    --- The path under the source's root, "css/app.css": no leading
    --- slash, and no empty, "." or ".." component.
    path: string
    --- The bytes.
    data: string
    --- The size of `data`.
    size: integer
    --- The lowercase hex SHA-256 of `data`.
    sha256: string
    --- The strong entity tag, `"<first 32 hex of sha256>"`, quotes
    --- included.
    etag: string
    --- The Content-Type, as [`Mime.of`] gives it.
    type: string
    --- The gzip of `data` when the source holds one, else nil. Its entity
    --- tag is `etag` with "-gzip" before the closing quote.
    gzip?: string
    --- The file's modification time in seconds, for Last-Modified: 0 for
    --- an asset that has none (an embedded one: a reproducible build
    --- carries no time).
    mtime: integer
    --- The subresource-integrity value, "sha384-<base64>" by default,
    --- computed on first use and kept.
    integrity: function(self: Asset, algorithm?: Algorithm): string
  end

  --- Where assets come from. `get` answers nil, and why, for a path the
  --- source does not hold, and raises for none.
  record Source
    --- The asset at `path` ("css/app.css"), or nil and why.
    get: function(self: Source, path: string): Asset?, string
    --- Every path the source holds, sorted.
    paths: function(self: Source): {string}
    --- True when `get` may answer differently later (a directory being
    --- edited): a caller then trusts nothing it computed from an earlier
    --- answer.
    dynamic: function(self: Source): boolean
  end

  --- What [`Assets.default`] takes.
  record DefaultOptions
    --- Read `root` from disk whatever is embedded: the development mode.
    dev?: boolean
    --- The directory read from disk ("static", against the working
    --- directory).
    root?: string
    --- Receives the one line saying a directory is read in place of an
    --- embedded source (standard error by default).
    log?: function(text: string)
  end
end

--- The most bytes a directory source reads of one file: what the build
--- allows an embedded one.
local MAX_BYTES <const> = 16 * 1024 * 1024

--- The longest path a source holds.
local MAX_PATH <const> = 255

--- Why `path` names no file of a source, or nil when it might: relative,
--- with no empty, "." or ".." component, and no backslash or NUL.
local function path_refusal(path: any): string?
  if not path is string then return "the path is not a string" end
  if path == "" then return "the path is empty" end
  if #path > MAX_PATH then return "the path is longer than a source holds" end
  if path:find("[\0\\]") then return "the path holds a backslash or a NUL" end
  if path:sub(1, 1) == "/" then return "the path is absolute" end
  for part in (path .. "/"):gmatch("([^/]*)/") do
    if part == "" or part == "." or part == ".." then
      return "the path holds an empty, '.' or '..' component"
    end
  end
  return nil
end

--- The digest of `data` as an SRI value: "<algorithm>-<base64>".
local function integrity_of(data: string, algorithm: Assets.Algorithm): string
  local digest: Hash.Algorithm = if algorithm == "sha256" then "sha256" elseif
    algorithm == "sha384" then "sha384" else "sha512" end
  return algorithm .. "-" .. Codec.base64(Hash.digest(digest, data))
end

--- What an asset has beside its path and bytes, when its source knows it.
local record Known
  sha256?: string
  type?: string
  gzip?: string
  mtime?: integer
end

--- An asset of `data` at `path`, its hash and entity tag computed unless
--- `known` holds the hash, with its type, gzip and mtime as `known` has
--- them (the type by `path` otherwise).
local function make(path: string, data: string, known: Known): Assets.Asset
  local sha256 = known.sha256 or Hash.hex_sha256(data)
  local kept: mut {string:string} = {}
  return {
    path = path, data = data, size = #data, sha256 = sha256,
    etag = '"' .. sha256:sub(1, 32) .. '"',
    type = known.type or Mime.of(path), gzip = known.gzip, mtime = known.mtime or 0,
    integrity = function(_self: Assets.Asset, algorithm?: Assets.Algorithm): string
      local which: Assets.Algorithm = algorithm or "sha384"
      local value = kept[which]
      if value == nil then
        value = integrity_of(data, which)
        kept[which] = value
      end
      return value
    end,
  }
end

--- A miss: nil and a reason naming `path`.
local function miss(path: any, why: string): nil, string
  return nil, ("no such asset: %s (%s)"):format(tostring(path), why)
end

--- A source of the given files, `path` to bytes: for tests and for files
--- a program generates. A path that is no valid relative path raises. With
--- `opts.gzip`, a file worth it is held gzipped too ([`Mime.gzip`]).
--- @param files {string:string} The files by path
--- @param opts {string:boolean} | nil `gzip` stores a gzip variant
--- @return Assets.Source The source
function Assets.memory(files: {string:string}, opts?: {string:boolean}): Assets.Source
  local held: mut {string:Assets.Asset} = {}
  local names: mut {string} = {}
  for path, data in pairs(files) do
    local why = path_refusal(path)
    if why ~= nil then error(("web: assets: memory: %q: %s"):format(tostring(path), why), 2) end
    local gzip: string? = nil
    if opts ~= nil and opts.gzip then gzip = Mime.gzip(path, data) end
    held[path] = make(path, data, { gzip = gzip })
    names[#names + 1] = path
  end
  table.sort(names)
  return {
    get = function(_self: Assets.Source, path: string): Assets.Asset?, string
      local why = path_refusal(path)
      if why ~= nil then return miss(path, why) end
      local asset = held[path]
      if asset == nil then return miss(path, "not held") end
      return asset, ""
    end,
    paths = function(_self: Assets.Source): {string}
      local copy: mut {string} = {}
      for i, name in ipairs(names) do copy[i] = name end
      return copy
    end,
    dynamic = function(_self: Assets.Source): boolean return false end,
  }
end

--- What a directory source remembers of a file it read.
local record Seen
  mtime: integer
  mtime_ns: integer
  size: integer
  asset: Assets.Asset
end

-- TODO: serve a file past 1 MiB as a Reader with `length` set and a
-- modification-time tag, as doc/plans/web/assets.md section 3.3 has it, once
-- [`Source.get`] can answer a file without its bytes in memory; every file is
-- read whole today, so development holds the largest asset in memory.
--- A source reading the files under `root` from disk, hidden files (a
--- component starting with ".") excepted, re-reading a file
--- when its size or modification time changed: for development, where
--- the files are edited while the program runs. A request costs a
--- stat call, a real-path check and, after an edit, a read.
---
--- A link inside `root` that leads outside it is not followed: the
--- file's real path must be under `root`'s. This is no protection for a
--- directory a user writes to (a race between the check and the read
--- remains): never serve uploads with it.
--- @param root string The directory
--- @return Assets.Source The source
function Assets.directory(root: string): Assets.Source
  if not root is string or root == "" then
    error("web: assets: directory: root is not a path", 2)
  end
  local seen: mut {string:Seen} = {}
  return {
    get = function(_self: Assets.Source, path: string): Assets.Asset?, string
      local why = path_refusal(path)
      if why ~= nil then return miss(path, why) end
      if ("/" .. path):find("/%.") then return miss(path, "a hidden file") end
      local base, base_why = Fs.absolute(root)
      if base == nil then return miss(path, base_why) end
      local full = root .. "/" .. path
      local real, real_why = Fs.absolute(full)
      if real == nil then return miss(path, real_why) end
      local prefix = base:sub(-1) == "/" and base or base .. "/"
      if real:sub(1, #prefix) ~= prefix then return miss(path, "outside the root") end
      local st, st_why = Fs.stat(real)
      if st == nil then return miss(path, st_why) end
      if st.kind ~= "file" then return miss(path, "not a file") end
      if st.size > MAX_BYTES then return miss(path, "past the 16 MiB limit") end
      local before = seen[path]
      if before ~= nil and before.size == st.size and before.mtime == st.mtime and
          before.mtime_ns == st.mtime_ns then
        return before.asset, ""
      end
      local data, read_why = Fs.read(real)
      if data == nil then return miss(path, read_why) end
      local asset = make(path, data, { mtime = st.mtime })
      seen[path] = { mtime = st.mtime, mtime_ns = st.mtime_ns, size = st.size, asset = asset }
      return asset, ""
    end,
    paths = function(_self: Assets.Source): {string}
      local list, _ = Fs.walk(root, function(_rel: string, name: string): boolean
        return name:sub(1, 1) == "."
      end)
      return list or {}
    end,
    dynamic = function(_self: Assets.Source): boolean return true end,
  }
end

--- The first database of the store holding the payload table, queried.
--- Each handle is tried in search order; one without the table is
--- skipped.
local function payload_query(sql: string, values: {Sqlite.Value}): Sqlite.Rows?
  for _, handle in ipairs(Store.databases()) do
    local rows, _ = Sqlite.text_rows(handle, sql, values)
    if rows ~= nil and #rows > 0 then return rows end
  end
  return nil
end

--- A source of the files under the project's `static/`, carried in the
--- executable's database (its `payload` table). A file is read once and
--- kept for the life of the process, so its memory is the total of
--- `static/`. A program built without `static/` holds none.
--- @return Assets.Source The source
function Assets.embedded(): Assets.Source
  local held: mut {string:Assets.Asset} = {}
  return {
    get = function(_self: Assets.Source, path: string): Assets.Asset?, string
      local why = path_refusal(path)
      if why ~= nil then return miss(path, why) end
      local asset = held[path]
      if asset ~= nil then return asset, "" end
      local rows = payload_query(
        "SELECT data, sha256, type, gzip, gzip IS NOT NULL FROM payload WHERE path = ?",
        { { text = path } })
      if rows == nil then return miss(path, "not held") end
      local row = rows[1]
      local packed: string? = nil
      if row:text(5) == "1" then packed = row:text(4) end
      asset = make(path, row:text(1), { sha256 = row:text(2), type = row:text(3), gzip = packed })
      held[path] = asset
      return asset, ""
    end,
    paths = function(_self: Assets.Source): {string}
      local rows = payload_query("SELECT path FROM payload ORDER BY path", {})
      local list: mut {string} = {}
      for i, row in ipairs(rows or {}) do list[i] = row:text(1) end
      return list
    end,
    dynamic = function(_self: Assets.Source): boolean return false end,
  }
end

-- TODO: a test of a project that has a `cmd/` main reads that `main` in
-- its sealed database, so [`is_built`] below takes the test for a built
-- program and [`Assets.default`] serves the embedded files, of which the
-- sealed database holds none: every `static/` path is a miss in such a
-- test. Seal the project's payload with the closure store, or leave `main`
-- out of a test's meta; until then a test gives its app [`Assets.memory`]
-- or [`Assets.directory`].

--- Whether this program is a built executable, which carries its own
--- database with its main module recorded: the `cosmic` tool and a script
--- it runs record none.
local function is_built(): boolean
  local main = Store.meta("main")
  return main ~= nil and main ~= ""
end

--- The source for an app: with `opts.dev` the directory `opts.root`
--- ("static" against the working directory); else the embedded source of
--- a built program, which serves only what it carries (none, if it was
--- built without `static/`) and never an unrelated `static/` it is run
--- beside; else, for a program run from source before it is built, the
--- directory, with one log line.
--- @param opts DefaultOptions | nil Dev mode, the directory and the log
--- @return Assets.Source The source
function Assets.default(opts?: Assets.DefaultOptions): Assets.Source
  local root = opts and opts.root or "static"
  if opts ~= nil and opts.dev then return Assets.directory(root) end
  if is_built() then return Assets.embedded() end
  local log = opts and opts.log or function(text: string)
    local _, _ = Fs.put(Fs.stderr, text .. "\n")
  end
  log(("web: not a built program; serving %q from disk"):format(root))
  return Assets.directory(root)
end

return Assets
