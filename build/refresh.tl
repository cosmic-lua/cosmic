--- `cosmic refresh`: a copy of a cosmic binary whose data is newer.
---
--- A binary carries data the build read from the tree -- the CA roots
--- it trusts (`build.roots`), the time zones `cosmic.time` falls back
--- on -- and that data goes stale on its own schedule, not the code's.
--- This rewrites the database an executable carries (`artifact.split`)
--- with each dataset replaced from a newer release, and puts it back
--- behind the same head -- launcher, cores and manifest byte for byte --
--- in a new file: the tool itself by default, or any program `cosmic
--- build` wrote (`--binary`), since both carry the same tables. The
--- binary it reads is never written.
---
--- Each dataset is one entry of `datasets`: the component its
--- release is recorded under in the bill of materials (`build.bom`),
--- how to fetch the newest release upstream, and how to read one --
--- fetched, or a file given on the command line -- into the rows the
--- binary carries. It is read with the very functions a boot reads the
--- tree's own copy with (`roots.put`, `work.write_zones`,
--- `Vendor.kept` under the PIN's rules), so a release refreshed in makes
--- the table a build from that release would have. Every row is checked
--- before anything is written: a certificate the TLS stack cannot read
--- (`Http.check_certificate`, as `core/http.c` reads each root), or a
--- zone `cosmic.time` cannot read, refuses the release.
---
--- The component's row records the release: its version, where it came
--- from and its sha256. A release whose sha256 is the one already
--- recorded is the same bytes, so its version and origin stand as they
--- were, and the table comes out as it was.

local Archive = require("cosmic.archive")
local Cli = require("cosmic.cli")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Http = require("cosmic.http")
local Json = require("cosmic.json")
local Proc = require("cosmic.proc")
local Shape = require("cosmic.shape")
local Sqlite = require("cosmic.sqlite")
local Time = require("cosmic.time")
local Vendor = require("build.vendor")
local artifact = require("build.artifact")
local bind = require("build.bind")
local clock = require("build.clock")
local roots = require("build.roots")
local work = require("build.work")

local log = require("build.verdict").log

local record refresh
  --- A release of a dataset, as a file on disk.
  record Source
    path: string
    --- Where it was fetched from; "" for a file given on the command line.
    url: string
    --- Its version as upstream names it; "" to take the one `read` finds.
    version: string
    --- The sha256 upstream names it by, as hex; "" when it names none.
    sha256: string
  end

  --- A release read and checked, ready to replace a dataset's rows.
  record Release
    --- The version the file itself names, or "" when it names none.
    version: string
    --- How many rows it makes.
    count: integer
    --- What the file holds that it leaves out, and why, one line each.
    left_out: {string}
    --- Replaces the dataset's rows in the database `db` with these.
    write: function(db: Sqlite.Handle): boolean, string
  end

  --- One dataset a binary carries that a refresh can replace.
  record Dataset
    --- The component its release is recorded under, and the option
    --- (`--<name>`) that names a file to read it from.
    name: string
    --- The newest release upstream, fetched into the directory given.
    fetch: function(scratch: string): refresh.Source | nil, string
    --- The release in the file at `path`, read and checked; `scratch`
    --- is a directory it may unpack into.
    read: function(path: string, scratch: string): refresh.Release | nil, string
  end

  --- Which of an archive's files a vendored tree keeps, as its PIN
  --- says: `strip` holds a `%s` for the release's version.
  record Rules
    strip: string
    keep: {string}
    drop: {string}
  end

  --- What `vendor/tzdata/PIN` keeps of the sdist.
  tzdata_rules: Rules
  --- Every dataset a refresh can replace, in the order it replaces them.
  datasets: {Dataset}
end

--- Where curl publishes Mozilla's bundle as PEM: the newest, and each
--- by the date of the Mozilla data it holds.
local cacert_latest <const> = "https://curl.se/ca/cacert.pem"
local cacert_dated <const> = "https://curl.se/ca/cacert-%s.pem"

--- PyPI's description of the `tzdata` package, whose sdist carries the
--- IANA database compiled to TZif files.
local tzdata_index <const> = "https://pypi.org/pypi/tzdata/json"

local months <const>: {string:string} = {
  Jan = "01", Feb = "02", Mar = "03", Apr = "04", May = "05", Jun = "06",
  Jul = "07", Aug = "08", Sep = "09", Oct = "10", Nov = "11", Dec = "12",
}

--- The date of the Mozilla data a bundle curl published holds, as
--- `YYYY-MM-DD` -- what names it on curl.se -- read from the line
--- `## Certificate data from Mozilla as of: Thu Aug 13 03:12:01 2026 GMT`
--- at its head; nil when it has no such line.
function refresh.cacert_date(pem: string): string | nil
  local month, day, year = pem:match(
    "\n## Certificate data from Mozilla as of: %a+ (%a+) +(%d%d?) [%d:]+ (%d%d%d%d) GMT")
  if month == nil or months[month] == nil then
    return nil
  end
  local number = math.tointeger(tonumber(day)) or 0
  if number < 1 or number > 31 then
    return nil
  end
  return ("%s-%s-%02d"):format(year, months[month], number)
end

--- What PyPI's JSON describes a package by, as far as a refresh reads it.
local record Index
  record Info
    version: string
  end
  record File
    packagetype: string
    url: string
    digests: {string:string}
  end
  info: Info
  urls: {File}
end

local INDEX <const> = Shape.record({
  info = Shape.record({ version = Shape.string }),
  urls = Shape.list(Shape.record({
    packagetype = Shape.string,
    url = Shape.string,
    digests = Shape.map(Shape.string),
  })),
})

--- The newest sdist of `tzdata` PyPI's JSON description names: its
--- version, URL and sha256.
function refresh.tzdata_release(text: string): refresh.Source | nil, string
  local decoded, trouble = Json.decode(text)
  if decoded == nil then
    return nil, "PyPI's description of tzdata: " .. trouble
  end
  local index, shape_trouble: Index | nil, string = Shape.into(decoded, INDEX)
  if index == nil then
    return nil, "PyPI's description of tzdata: " .. shape_trouble
  end
  if not index.info.version:match("^[%w%.]+$") then
    return nil, "PyPI's description of tzdata names an odd version: " .. index.info.version
  end
  for _, file in ipairs(index.urls) do
    local sha256 = file.digests["sha256"]
    if file.packagetype == "sdist" and sha256 ~= nil and #sha256 == 64 and
       sha256:match("^%x+$") then
      return { path = "", url = file.url, version = index.info.version, sha256 = sha256:lower() }, ""
    end
  end
  return nil, "PyPI's description of tzdata " .. index.info.version .. " names no sdist"
end

--- What `vendor/tzdata/PIN` keeps of the sdist, less its version:
--- `strip` holds a `%s` for it. `build/refresh_test.tl` holds these to
--- the PIN, so a boot and a refresh keep the same files.
refresh.tzdata_rules = {
  strip = "tzdata-%s/src/tzdata/",
  keep = { "zoneinfo/**" },
  drop = { "**/__init__.py", "zoneinfo/tzdata.zi", "zoneinfo/leapseconds", "zoneinfo/*.tab" },
}

--- The body `url` answers, refusing anything but a 2xx.
local function fetch_text(url: string): string | nil, string
  local got, trouble = Http.get(url)
  if got == nil then
    return nil, url .. ": " .. trouble
  end
  if got.status < 200 or got.status > 299 then
    return nil, url .. ": HTTP " .. got.status
  end
  return got.body, ""
end

local cacert: refresh.Dataset = {
  name = "cacert",
  fetch = function(scratch: string): refresh.Source | nil, string
    local pem, trouble = fetch_text(cacert_latest)
    if pem == nil then
      return nil, trouble
    end
    local date = refresh.cacert_date(pem)
    if date == nil then
      return nil, cacert_latest .. ": names no date for its Mozilla data"
    end
    -- Recorded by the dated name, which keeps naming these bytes after
    -- the newest has moved on: fetched again by it, so the record
    -- names what it holds.
    local url = cacert_dated:format(date)
    local path = scratch .. "/cacert.pem"
    local sha256 = Hash.hex_sha256(pem)
    local ok, download_trouble = Http.download(url, path, { sha256 = sha256 })
    if not ok then
      return nil, url .. ": " .. download_trouble
    end
    return { path = path, url = url, version = date, sha256 = sha256 }, ""
  end,
  read = function(path: string, _scratch: string): refresh.Release | nil, string
    local pem, trouble = Fs.read(path)
    if pem == nil then
      return nil, trouble
    end
    local found, parse_trouble = roots.parse(pem)
    if found == nil then
      return nil, path .. ": " .. parse_trouble
    end
    if #found == 0 then
      return nil, path .. ": holds no certificate"
    end
    -- A root the TLS stack cannot read is one `core/http.c` drops as it
    -- loads them: left out here too, and named, so a bundle with one
    -- root this build cannot read still refreshes the rest. A bundle
    -- with none it can read would leave a binary trusting nothing.
    local distinct: {string:boolean} = {}
    local readable: {roots.Root} = {}
    local left_out: {string} = {}
    local count = 0
    for i, one in ipairs(found) do
      local ok, why = Http.check_certificate(one.der)
      if not ok then
        left_out[#left_out + 1] = ("certificate %d (%s): %s"):format(i, one.label, why)
      else
        readable[#readable + 1] = one
        local digest = Hash.sha256(one.der)
        if not distinct[digest] then
          distinct[digest] = true
          count = count + 1
        end
      end
    end
    if #readable == 0 then
      return nil, path .. ": no certificate the TLS stack can read: " .. left_out[1]
    end
    return {
      version = refresh.cacert_date(pem) or "",
      count = count,
      left_out = left_out,
      write = function(db: Sqlite.Handle): boolean, string
        local cleared, clear_trouble = db:exec("DELETE FROM ca_roots")
        if not cleared then
          return false, clear_trouble
        end
        return roots.put(db, "", readable)
      end,
    }, ""
  end,
}

local tzdata: refresh.Dataset = {
  name = "tzdata",
  fetch = function(scratch: string): refresh.Source | nil, string
    local index, trouble = fetch_text(tzdata_index)
    if index == nil then
      return nil, trouble
    end
    local source, release_trouble = refresh.tzdata_release(index)
    if source == nil then
      return nil, release_trouble
    end
    source.path = scratch .. "/tzdata-sdist"
    local ok, download_trouble = Http.download(source.url, source.path, { sha256 = source.sha256 })
    if not ok then
      return nil, source.url .. ": " .. download_trouble
    end
    return source, ""
  end,
  -- TODO: take a zoneinfo directory too (/usr/share/zoneinfo, an
  -- unpacked tzdata), naming its version by the `# version` line of the
  -- `tzdata.zi` beside it; today only the sdist PyPI publishes is read.
  -- A system zoneinfo holds its aliases as links (and some a `posix ->
  -- .` loop), so reading one wants `Fs.walk_following`, as
  -- work.read_zoneinfo walks, not `Fs.walk`, which lists no link.
  read = function(path: string, scratch: string): refresh.Release | nil, string
    local entries, trouble = Archive.list(path)
    if entries == nil then
      return nil, path .. ": " .. trouble
    end
    -- The sdist's one top directory names its version.
    local version: string = nil
    for _, entry in ipairs(entries) do
      local path_in = entry.path
      while path_in:sub(1, 2) == "./" do
        path_in = path_in:sub(3):gsub("^/+", "")
      end
      version = path_in:match("^tzdata%-([%w%.]+)/src/tzdata/zoneinfo/")
      if version ~= nil then
        break
      end
    end
    if version == nil then
      return nil, path .. ": not a tzdata sdist: no tzdata-<version>/src/tzdata/zoneinfo/"
    end
    local rules = refresh.tzdata_rules
    local files, keep_trouble = Vendor.kept({ url = "", sha256 = "", file = "",
      strip = rules.strip:format(version), keep = rules.keep, drop = rules.drop }, entries)
    if files == nil then
      return nil, path .. ": " .. keep_trouble
    end
    local into = scratch .. "/tzdata"
    local extracted, extract_trouble = Archive.extract(path, into, {
      filter = function(entry: string): boolean
        return files[entry] ~= nil
      end,
    })
    if extracted == nil then
      return nil, path .. ": " .. extract_trouble
    end
    local zones: {string:string} = {}
    local count = 0
    for entry, under in pairs(files) do
      local data, read_trouble = Fs.read(into .. "/" .. entry)
      if data == nil then
        return nil, read_trouble
      end
      local name = under:gsub("^zoneinfo/", "")
      local _, why = Time.zone_from_tzif(data, name)
      if why ~= "" then
        return nil, ("%s: zone %s: %s"):format(path, name, why)
      end
      -- `./a` and `a` in one archive land on one file: one zone.
      if zones[name] == nil then
        count = count + 1
      end
      zones[name] = data
    end
    return {
      version = version,
      count = count,
      left_out = {},
      write = function(db: Sqlite.Handle): boolean, string
        return work.write_zones(db, zones)
      end,
    }, ""
  end,
}

refresh.datasets = { cacert, tzdata }

--- What the binary records of the release it carries of `name`.
local function recorded(db: Sqlite.Handle, name: string): {string} | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT version, url, sha256, patches FROM components WHERE name = ?1", { bind.text(name) })
  if rows == nil then
    return nil, trouble
  end
  if #rows == 0 then
    return nil, "the binary records no " .. name .. " component"
  end
  -- A release as upstream publishes it would lose what cosmic changed.
  if rows[1][4] ~= "" then
    return nil, "the binary's " .. name .. " carries cosmic's patches, which a refresh cannot apply"
  end
  return rows[1], ""
end

--- Replaces `dataset`'s rows in `db` with the release at `source` and
--- records it; one line saying what changed.
local function apply(db: Sqlite.Handle, dataset: refresh.Dataset, source: refresh.Source,
                       scratch: string): string | nil, string
  local bytes, trouble = Fs.read(source.path)
  if bytes == nil then
    return nil, trouble
  end
  local sha256 = Hash.hex_sha256(bytes)
  local unpack_into = scratch .. "/" .. dataset.name
  local made_dir, dir_trouble = Fs.mkdirs(unpack_into)
  if not made_dir then
    return nil, dir_trouble
  end
  local release, read_trouble = dataset.read(source.path, unpack_into)
  if release == nil then
    return nil, read_trouble
  end
  local was, was_trouble = recorded(db, dataset.name)
  if was == nil then
    return nil, was_trouble
  end
  local version, url = was[1], was[2]
  if sha256 ~= was[3] then
    version = source.version ~= "" and source.version or release.version
    if version == "" then
      version = "sha256:" .. sha256:sub(1, 12)
    end
    url = source.url ~= "" and source.url or "file:" .. Fs.basename(source.path)
  end
  local made, made_trouble = Sqlite.transact(db, function(): boolean, string
    local written, write_trouble = release.write(db)
    if not written then
      return false, write_trouble
    end
    return Sqlite.run(db,
      "UPDATE components SET version = ?1, url = ?2, sha256 = ?3 WHERE name = ?4",
      { bind.text(version), bind.text(url), bind.text(sha256), bind.text(dataset.name) })
  end)
  if not made then
    return nil, made_trouble
  end
  local change = sha256 == was[3] and version .. " (as it was)" or was[1] .. " -> " .. version
  local line = ("%s %s, %d rows"):format(dataset.name, change, release.count)
  for _, why in ipairs(release.left_out) do
    line = line .. "\n  left out " .. why
  end
  return line, ""
end

--- Whether `a` and `b` name the same file: never true when either is
--- missing.
local function same_file(a: string, b: string): boolean
  local sa, _ = Fs.stat(a)
  local sb, _ = Fs.stat(b)
  return sa ~= nil and sb ~= nil and sa.dev == sb.dev and sa.ino == sb.ino
end

--- The executable at `binary` with each of `chosen` replaced from its
--- source -- `sources[name]`, a file, or fetched upstream when that is
--- nil -- written to `out`; a line per dataset saying what changed.
function refresh.binary(binary: string, out: string, chosen: {refresh.Dataset},
                        sources: {string:string}): {string} | nil, string
  local bytes, trouble = Fs.read(binary)
  if bytes == nil then
    return nil, trouble
  end
  local split, split_trouble = artifact.split(bytes)
  if split == nil then
    return nil, binary .. ": " .. split_trouble
  end
  local parts: artifact.Split = split
  local mode = 0x1ed
  local st, _ = Fs.stat(binary)
  if st ~= nil then
    mode = st.mode & 0x1ff
  end
  local scratch, scratch_trouble = Fs.mkdtemp("cosmic-refresh-")
  if scratch == nil then
    return nil, scratch_trouble
  end
  local lines: {string} = {}
  local function write(): string
    local path = scratch .. "/carried.db"
    local written, write_trouble = Fs.write(path, parts.database)
    if not written then
      return write_trouble
    end
    local opened, open_trouble = Sqlite.open(path, true)
    if opened == nil then
      return path .. ": " .. open_trouble
    end
    local db: Sqlite.Handle = opened
    local function done(why: string): string
      local _, _ = db:close()
      return why
    end
    for _, dataset in ipairs(chosen) do
      local source: refresh.Source
      local given = sources[dataset.name]
      if given ~= nil then
        source = { path = given, url = "", version = "", sha256 = "" }
      else
        local fetched, fetch_trouble = dataset.fetch(scratch)
        if fetched == nil then
          -- The fetch trusts this binary's own roots, which may be the
          -- stale data being replaced.
          return done(("%s: %s; --%s <file> reads a release with no network"):format(
            dataset.name, fetch_trouble, dataset.name))
        end
        source = fetched
      end
      local line, apply_trouble = apply(db, dataset, source, scratch)
      if line == nil then
        return done(dataset.name .. ": " .. apply_trouble)
      end
      lines[#lines + 1] = line
    end
    -- Vacuumed, as every database a build writes is, so the file is a
    -- function of its rows. A vacuum writes the schema cookie one past
    -- the source's, which no row here moved: set back by one first, so
    -- the copy carries the cookie the binary did.
    local cookie, cookie_trouble = Sqlite.text_rows(db, "PRAGMA schema_version")
    if cookie == nil then
      return done(cookie_trouble)
    end
    local kept, keep_trouble = db:exec("PRAGMA schema_version = " ..
      (math.tointeger(tonumber(cookie[1][1])) - 1))
    if not kept then
      return done(keep_trouble)
    end
    local vacuumed, vacuum_trouble = Sqlite.run(db, "VACUUM INTO ?1",
      { bind.text(scratch .. "/refreshed.db") })
    if not vacuumed then
      return done(vacuum_trouble)
    end
    done("")
    local database, read_trouble = Fs.read(scratch .. "/refreshed.db")
    if database == nil then
      return read_trouble
    end
    local program, join_trouble = artifact.rejoin(parts, database)
    if program == nil then
      return join_trouble
    end
    local published, publish_trouble = Fs.write(out, program, mode)
    if not published then
      return publish_trouble
    end
    return ""
  end
  local failure = write()
  local _, _ = Fs.remove_tree(scratch)
  if failure ~= "" then
    return nil, failure
  end
  return lines, ""
end

local usage <const> = "cosmic refresh -o <path> [--binary <path>] [--<dataset> <file>...] [dataset...]"

--- `cosmic refresh`'s command line: see `Cli.refresh`.
function refresh.run(argv: {integer:string}): integer
  local started = Time.monotonic_ns()
  local function finish(code: integer, detail: string): integer
    log:verdict("refresh", code == 0, detail .. ", " .. clock.took(started))
    return code
  end
  local function refuse(why: string): integer
    log:complain("refresh: " .. why .. "; " .. usage)
    return finish(2, "usage: see `cosmic help refresh`")
  end
  local parsed, parse_trouble = Flags.parse(argv, 2, Cli.options.refresh)
  if parsed == nil then
    return refuse(parse_trouble)
  end
  local out = parsed.values["-o"]
  if out == nil then
    return refuse("-o names the file to write")
  end
  local by_name: {string:refresh.Dataset} = {}
  for _, dataset in ipairs(refresh.datasets) do
    by_name[dataset.name] = dataset
  end
  local wanted: {string:boolean} = {}
  local sources: {string:string} = {}
  for _, word in ipairs(parsed.words) do
    if by_name[word] == nil then
      return refuse("no such dataset: " .. word)
    end
    wanted[word] = true
  end
  for _, dataset in ipairs(refresh.datasets) do
    local given = parsed.values["--" .. dataset.name]
    if given ~= nil then
      local path, trouble = Fs.absolute(given)
      if path == nil then
        log:complain("refresh: " .. trouble)
        return finish(1, "nothing written")
      end
      sources[dataset.name] = path
      wanted[dataset.name] = true
    end
  end
  -- Neither a name nor a file: every dataset, from upstream.
  local chosen: {refresh.Dataset} = {}
  for _, dataset in ipairs(refresh.datasets) do
    if next(wanted) == nil or wanted[dataset.name] then
      chosen[#chosen + 1] = dataset
    end
  end
  local binary = parsed.values["--binary"]
  -- TODO: read the running binary from the descriptor startup retained
  -- rather than opening its path again, once the store offers the whole
  -- file as it offers its core (trusted_core): a binary renamed over
  -- this one after launch -- a package upgrade -- is refreshed in its
  -- place. `cosmic --version` has the same gap (build/dispatch.tl).
  if binary == nil then
    local running, trouble = Proc.executable()
    if running == nil then
      log:complain("refresh: " .. trouble)
      return finish(1, "no binary")
    end
    binary = running
  end
  if same_file(binary, out) then
    log:complain("refresh: " .. out .. " is the binary it refreshes, which is never written")
    return finish(1, "nothing written")
  end
  local lines, trouble = refresh.binary(binary, out, chosen, sources)
  if lines == nil then
    log:complain("refresh: " .. trouble)
    return finish(1, "nothing written")
  end
  for _, line in ipairs(lines) do
    log:say(line)
  end
  return finish(0, "wrote " .. out)
end

return refresh
