--- One entry point over whatever archive format a file turns out to
--- be: detected from its first bytes, walked through a single entry
--- shape shared by tar (plain or compressed) and zip, and extracted to
--- a destination directory with the usual path-escape refusals a
--- caller expects from something unpacking bytes it did not write;
--- and written, the format chosen by the file's name, through the one
--- writer shape tar and zip share.

local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Compress = require("cosmic.compress")
local Stream = require("cosmic.stream")
local Tar = require("cosmic.tar")
local Zip = require("cosmic.zip")
local String = require("cosmic.string")

--- What a failure of this module answers, nil and `why` under the
--- module's name.
local function refuse(why: string): nil, string
  return nil, "archive: " .. why
end

local record Archive
  --- One entry of an archive, whichever format it came from: the
  --- [`Stream.ArchiveEntry`] that tar's and zip's entries are. Teal's
  --- interface conformance is nominal, so the interface is declared in
  --- [`cosmic.stream`], which [`cosmic.tar`] and [`cosmic.zip`] can
  --- require, and not here, where both are required.
  type Entry = Stream.ArchiveEntry

  --- What walks an archive's entries: the [`Stream.ArchiveReader`] that
  --- tar's and zip's readers are, declared in [`cosmic.stream`] for the
  --- reason [`Entry`] is.
  type Reader = Stream.ArchiveReader

  --- What writes an archive: the [`Stream.ArchiveWriter`] that tar's
  --- and zip's writers are, and what [`Archive.create`] answers,
  --- declared in [`cosmic.stream`] for the reason [`Entry`] is.
  type Writer = Stream.ArchiveWriter

  --- What [`Archive.create`] writes: a tar compressed with gzip, a
  --- plain tar, or a zip.
  enum Format
    "tar.gz"
    "tar"
    "zip"
  end

  record CreateOptions
    --- Writes every entry's time as the format's own zero, so the same
    --- calls make the same bytes, as [`Tar.WriterOptions`] and
    --- [`Zip.WriterOptions`] say.
    deterministic: boolean
  end

  --- What `extract` does with a symlink entry: "skip" leaves it out,
  --- "create" makes it (see ExtractOptions.links).
  enum Links
    "skip"
    "create"
  end

  record ExtractOptions
    --- A path prefix to drop from every path, whole components only,
    --- with or without a trailing `/`. An entry the prefix does not
    --- match is skipped.
    strip_prefix: string
    --- A number of leading path components to drop from every path
    --- (tar's --strip-components), after `strip_prefix` when both are
    --- given. An entry that runs out of components is skipped; a
    --- negative count raises.
    strip_components: integer
    --- Asked with a path already stripped; false skips the entry.
    filter: function(string): boolean
    --- "skip" (the default) or "create". Created symlinks are made
    --- last, after every other entry, and nothing is ever written
    --- through one, so no symlink -- this archive's or one already in
    --- `dest` -- can redirect a write outside `dest`. A link's target
    --- may pass only through directories already extracted, never
    --- through another link or a name that does not exist yet.
    links: Links
    --- Fails once more than this many entries would be written.
    --- Unlimited by default; a negative limit raises.
    max_entries: integer
    --- A directory whose real directories a symlink's target may also
    --- pass through, for entries unpacked apart from where they will
    --- be put: a staging directory that is later moved into this one.
    --- Only read for links, and only to look; nothing is written there.
    resolve_in: string
  end
end

------------------------------------------------------------------
-- format detection
------------------------------------------------------------------

local GZIP_MAGIC <const> = "\31\139"
local XZ_MAGIC <const> = "\253" .. "7zXZ\0"
local BZIP2_MAGIC <const> = "BZh"
local ZIP_MAGIC <const> = "PK\3\4"
local EMPTY_ZIP_MAGIC <const> = "PK\5\6"

local function detect(head: string): string
  if head:sub(1, 4) == ZIP_MAGIC or head:sub(1, 4) == EMPTY_ZIP_MAGIC then return "zip" end
  if head:sub(1, 2) == GZIP_MAGIC then return "gzip" end
  if head:sub(1, 6) == XZ_MAGIC then return "xz" end
  if head:sub(1, 3) == BZIP2_MAGIC then return "bzip2" end
  if #head >= 262 and head:sub(258, 262) == "ustar" then return "tar" end
  return "unknown"
end

------------------------------------------------------------------
-- readers
------------------------------------------------------------------

--- `tr`, which reads the decompressed stream `source`: once the tar end
--- is reached, whatever follows it is read through to the decompressor's
--- own end, so its errors (a truncated stream, a bad checksum) surface
--- instead of vanishing with the unread tail.
local function draining(tr: Tar.Reader, source: Stream.Reader): Archive.Reader
  local finished = false
  local ar: Archive.Reader = {}
  ar.next = function(_self: Archive.Reader): Archive.Entry | nil, string
    local e, trouble = tr:next()
    if e ~= nil then return e, "" end
    if trouble ~= "" then return nil, trouble end
    if not finished then
      finished = true
      while true do
        local chunk, dtrouble = source:read()
        if chunk == nil then
          if dtrouble ~= "" then return nil, dtrouble end
          break
        end
      end
    end
    return nil, ""
  end
  ar.close = function(_self: Archive.Reader): boolean, string
    return tr:close()
  end
  return ar
end

--- The tar `source` holds, of format `kind` ("tar", "gzip", "xz" or
--- "bzip2"): the reader [`Archive.open`] and [`Archive.open_stream`] share.
--- `label` names the input in a complaint.
local function open_tar(kind: string, source: Stream.Reader, label: string):
    Archive.Reader | nil, string
  if kind == "tar" then return Tar.reader(source), "" end
  local codec: Compress.Stream
  local ctrouble: string
  if kind == "gzip" then
    codec, ctrouble = Compress.inflater("gzip")
  elseif kind == "xz" then
    codec, ctrouble = Compress.xz_decoder()
  else
    codec, ctrouble = Compress.bz2_decoder()
  end
  if codec == nil then
    local _, _ = source:close()
    return refuse(label .. ": " .. ctrouble)
  end
  local transformed = Stream.transform(source, codec)
  return draining(Tar.reader(transformed), transformed), ""
end

--- Detects `path`'s format from its first bytes and returns a reader
--- over its entries, uniform whether it turns out to be a zip, a
--- plain ustar tar, or a tar compressed with gzip, xz, or bzip2.
function Archive.open(path: string): Archive.Reader | nil, string
  local fd, trouble = Fs.open_read(path)
  if fd == nil then return nil, trouble end
  local head, htrouble = Fs.take(fd, 262)
  local _, _ = Fs.close(fd)
  if head == nil then return nil, htrouble end
  local kind = detect(head)
  if kind == "zip" then return Zip.open(path) end
  if kind == "unknown" then
    return refuse(path .. ": not a recognized archive format")
  end
  local raw, otrouble = Stream.open(path)
  if raw == nil then return nil, otrouble end
  return open_tar(kind, raw, path)
end

--- Like `open`, for an archive that arrives as a stream (a pipe, a
--- socket) rather than as a file: a plain, gzip, xz or bzip2 tar, read
--- as `source` yields it, so memory stays bounded however long it is.
--- The format is detected from the first bytes, which are not lost.
--- A zip is refused, since reading one means seeking in it: write the
--- stream to a file and `open` that. Closing the reader closes `source`,
--- which is closed here as well when this fails.
function Archive.open_stream(source: Stream.Reader): Archive.Reader | nil, string
  local head, trouble = Stream.read_up_to(source, 262)
  if head == nil then
    local _, _ = source:close()
    return refuse(trouble)
  end
  local kind = detect(head)
  if kind == "zip" then
    local _, _ = source:close()
    return refuse("a zip cannot be read from a stream; write it to a file and open that")
  end
  if kind == "unknown" then
    local _, _ = source:close()
    return refuse("not a recognized archive format")
  end
  return open_tar(kind, Stream.prepend(head, source), "stream")
end

local function listed_open(_e: Archive.Entry): Stream.Reader | nil, string
  return refuse("an entry from Archive.list cannot be opened; walk Archive.open instead")
end

--- Every entry `reader` yields, read to the end and then closed (on
--- every path), as [`Archive.extract_reader`] reads a reader. The
--- entries' `open` fails, since the reader is closed before this
--- returns; walk the reader to read bodies.
function Archive.list_reader(reader: Archive.Reader): {Archive.Entry} | nil, string
  local out: {Archive.Entry} = {}
  while true do
    local entry, etrouble = reader:next()
    if entry == nil then
      local _, _ = reader:close()
      if etrouble ~= "" then return nil, etrouble end
      return out, ""
    end
    -- Dropping the per-entry reader closure keeps a long listing small.
    entry.open = listed_open
    out[#out + 1] = entry
  end
end

--- Every entry of the archive at `path`, as [`Archive.list_reader`]
--- lists them. Walk [`Archive.open`] to read bodies.
function Archive.list(path: string): {Archive.Entry} | nil, string
  local reader, trouble = Archive.open(path)
  if reader == nil then return nil, trouble end
  return Archive.list_reader(reader)
end

------------------------------------------------------------------
-- writers
------------------------------------------------------------------

--- The format [`Archive.create`] would write at `path`, from the
--- suffix the name ends in, whatever its case: `.tar.gz` or `.tgz`,
--- `.tar`, `.zip`. Any other name is nil and why, naming the suffixes
--- it knows. Nothing is read or created, so a caller can refuse a name
--- before doing work for it.
function Archive.format_of(path: string): Archive.Format | nil, string
  local lower = path:lower()
  if lower:match("%.zip$") then return "zip", "" end
  if lower:match("%.tar%.gz$") or lower:match("%.tgz$") then return "tar.gz", "" end
  if lower:match("%.tar$") then return "tar", "" end
  -- TODO: once cosmic.compress carries an xz encoder (it has only
  -- `xz_decoder`), write `.tar.xz` here, and `.tar.bz2` likewise once
  -- it carries a bzip2 encoder (it has only `bz2_decoder`).
  if lower:match("%.tar%.xz$") or lower:match("%.txz$") then
    return refuse(path .. ": cannot write .tar.xz, there is no xz encoder; use .tar.gz, .tgz, .tar or .zip")
  end
  if lower:match("%.tar%.bz2$") or lower:match("%.tbz2?$") then
    return refuse(path .. ": cannot write .tar.bz2, there is no bzip2 encoder; use .tar.gz, .tgz, .tar or .zip")
  end
  return refuse(path .. ": cannot tell the format from the name; end it in .tar.gz, .tgz, .tar or .zip")
end

--- A writer of a new archive at `path`, of the format its name ends
--- in, whatever its case: `.tar.gz` or `.tgz` (a tar compressed with
--- gzip), `.tar` or `.zip`. The inverse of [`Archive.open`], which
--- reads any of them back. The bytes go to a temporary neighbor, as
--- [`Stream.create`] writes, so `path` holds nothing until `close`
--- succeeds, and then the whole archive; a failed call or `abort`
--- leaves `path` as it was. Any other name answers nil and why, naming
--- the suffixes it knows, and creates nothing.
---
---     local w = assert(Archive.create("release.tar.gz"))
---     assert(w:add_file("README", "read me first"))
---     assert(w:close())
function Archive.create(path: string, opts?: Archive.CreateOptions): Archive.Writer | nil, string
  local format, why = Archive.format_of(path)
  if format == nil then return nil, why end
  local deterministic = opts ~= nil and opts.deterministic or false
  local codec: Compress.Stream
  if format == "tar.gz" then
    local ctrouble: string
    codec, ctrouble = Compress.deflater("gzip")
    if codec == nil then return refuse(path .. ": " .. ctrouble) end
  end
  local file, trouble = Stream.create(path)
  if file == nil then return nil, trouble end
  if format == "zip" then return Zip.writer(file, { deterministic = deterministic }), "" end
  local sink: Stream.Writer = file
  if codec ~= nil then sink = Stream.transform_writer(file, codec) end
  return Tar.writer(sink, { deterministic = deterministic }), ""
end

------------------------------------------------------------------
-- extraction
------------------------------------------------------------------

--- Whether `path` holds a NUL byte or a backslash anywhere, or starts
--- with a drive letter: a path no archive entry or link may name.
local function foreign_syntax(path: string): boolean
  return path:find("[%z\\]") ~= nil or path:find("^%a:") ~= nil
end

--- False for an absolute path, a `\`-separated or drive/UNC path, one
--- holding a NUL byte (which every system call would silently cut the
--- path at), or one with a `..` component -- the archive path itself,
--- before `strip_prefix` or `strip_components` is applied, since each
--- only removes leading components and cannot make an escaping path
--- safe.
local function safe_relative(path: string): boolean
  if path == "" or path:byte(1) == 47 then return false end -- '/'
  if foreign_syntax(path) then return false end
  -- Only a path holding ".." at all can have it as a component.
  if path:find("..", 1, true) ~= nil then
    for segment in (path .. "/"):gmatch("([^/]*)/") do
      if segment == ".." then return false end
    end
  end
  return true
end

--- `path` split into its components, without empty or `.` ones.
local function components(path: string): {string}
  local out: {string} = {}
  for segment in path:gmatch("[^/]+") do
    if segment ~= "." then out[#out + 1] = segment end
  end
  return out
end

local function apply_strip(path: string, prefix: string | nil, count: integer | nil): string | nil
  local rest = path
  if prefix ~= nil then
    prefix = prefix:gsub("/+$", "")
    if prefix ~= "" then
      if rest:sub(1, #prefix) ~= prefix then return nil end
      rest = rest:sub(#prefix + 1)
      if rest ~= "" and rest:sub(1, 1) ~= "/" then return nil end
      rest = rest:gsub("^/+", "")
    end
  end
  -- A float that is a whole number (2.0) counts as one; [`extract_from`]
  -- has already refused any other.
  for _ = 1, math.tointeger(count) or 0 do
    local slash = rest:find("/", 1, true)
    if slash == nil then return nil end
    rest = rest:sub(slash + 1)
  end
  return rest
end

--- Whether a symlink in `rel_dir` with `target` stays inside the
--- extraction root, tracked as a lexical depth rather than by
--- resolving real paths, since the destination need not exist yet.
--- `extract` separately refuses a target that walks through another
--- symlink, which would make this lexical walk meaningless.
local function stays_inside(rel_dir: string, target: string): boolean
  if target == "" or target:sub(1, 1) == "/" then return false end
  if foreign_syntax(target) then return false end
  local depth = #components(rel_dir)
  for seg in (target .. "/"):gmatch("([^/]*)/") do
    if seg == "" or seg == "." then
      -- no change
    elseif seg == ".." then
      depth = depth - 1
      if depth < 0 then return false end
    else
      depth = depth + 1
    end
  end
  return true
end

--- Permission bits only, and never setuid, setgid or sticky -- those
--- all live above 0o777, so masking to it drops them along with any
--- file-type bits.
local function safe_mode(mode: integer): integer
  return mode & 0x1FF
end

local function join(parts: {string}, n: integer): string
  return table.concat(parts, "/", 1, n)
end

local record PendingLink
  rel: string
  parts: {string}
  target: string
  mtime: integer
end

--- The extraction [`Archive.extract`] and [`Archive.extract_reader`] share:
--- `from` is a path to open or a Reader to walk to its end.
local function extract_from(from: string | Archive.Reader, dest: string,
    given: Archive.ExtractOptions | nil): {string} | nil, string
  local opts: Archive.ExtractOptions = given or {}
  if opts.max_entries ~= nil and opts.max_entries < 0 then
    error("archive: max_entries is negative", 2)
  end
  local count = opts.strip_components
  if count ~= nil and math.tointeger(count) == nil then
    error("archive: strip_components is not a whole number of components", 2)
  elseif count ~= nil and count < 0 then
    error("archive: strip_components is negative", 2)
  end
  local links_mode = opts.links or "skip"
  local entries_left = opts.max_entries
  local reader: Archive.Reader
  if from is string then
    local opened, trouble = Archive.open(from)
    if opened == nil then return nil, trouble end
    reader = opened
  else
    reader = from
  end
  local dest_made, dest_trouble = Fs.mkdirs(dest)
  if not dest_made then
    local _, _ = reader:close()
    return nil, dest_trouble
  end

  local written: {string} = {}
  -- Directories under `dest` known to be real directories (not
  -- symlinks), by dest-relative path: checked with lstat, or made here.
  local real_dirs: {string:boolean} = {}
  -- Symlinks still to be made, by dest-relative path; a later entry
  -- at the same path replaces an earlier one.
  local pending: {string:PendingLink} = {}
  local pending_order: {PendingLink} = {}
  -- How many paths `pending` holds.
  local pending_count = 0
  local dir_times: {{string, integer}} = {}

  local function bail(message: string): nil, string
    local _, _ = reader:close()
    return nil, message
  end

  --- Makes sure the first `n` components of `parts` name real
  --- directories under `dest`, creating missing ones, and refusing
  --- a symlink (made or to be made) anywhere along the way.
  local function ensure_dirs(parts: {string}, n: integer, entry_path: string): boolean, string
    for i = 1, n do
      local rel = join(parts, i)
      if pending[rel] ~= nil then
        return false, "archive: refusing to write through a symlink: " .. entry_path
      end
      if not real_dirs[rel] then
        local full = dest .. "/" .. rel
        local found, why, errno = sys.lstat(full)
        if found == nil then
          if errno ~= sys.ENOENT then return false, full .. ": " .. why end
          local made, mtrouble, merr = sys.mkdir(full, 0x1ed)
          if not made and merr ~= sys.EEXIST then return false, full .. ": " .. mtrouble end
          found, why = sys.lstat(full)
        end
        if found == nil then return false, full .. ": " .. why end
        local st: sys.Stat = found
        if st.kind ~= "dir" then
          if st.kind == "link" then
            return false, "archive: refusing to write through a symlink: " .. entry_path
          end
          return false, "archive: " .. full .. " is not a directory"
        end
        real_dirs[rel] = true
      end
    end
    return true, ""
  end

  local function extract_file(dest_path: string, entry: Archive.Entry): boolean, string
    local body, otrouble = entry:open()
    if body == nil then return false, otrouble end
    local mode = safe_mode(entry.mode)
    if mode == 0 then mode = 0x1a4 end
    local w, ctrouble = Stream.create(dest_path, mode)
    if w == nil then return false, ctrouble end
    local copied, rtrouble = Stream.copy(body, w)
    if copied == nil then
      local _, _ = w:abort()
      return false, rtrouble
    end
    local ok, wtrouble = w:close()
    if not ok then return false, wtrouble end
    local _, _ = Fs.set_mtime(dest_path, entry.mtime)
    return true, ""
  end

  --- Whether `target`, read from the directory `parts[1..n]`, walks
  --- through anything but a real directory already in `dest` before
  --- its last component: a symlink this archive makes or `dest`
  --- already holds, or a name that is missing. The lexical
  --- [`stays_inside`] check is only sound when it does not. A missing
  --- name counts because it may be another link's name under a
  --- different spelling: on a case-insensitive filesystem `x -> b/..`
  --- then `B -> .` makes `x` dest's parent, though no `b` exists.
  local function target_crosses_link(parts: {string}, n: integer, target: string): boolean
    local at: {string} = {}
    for i = 1, n do at[i] = parts[i] end
    local segs = components(target)
    for k = 1, #segs - 1 do
      local seg = segs[k]
      if seg == ".." then
        at[#at] = nil
      else
        at[#at + 1] = seg
        local rel = table.concat(at, "/")
        if pending[rel] ~= nil then return true end
        local st, _ = sys.lstat(dest .. "/" .. rel)
        if (st == nil or st.kind ~= "dir") and opts.resolve_in ~= nil and not pending[rel] then
          -- Staged apart: a directory the real destination holds counts,
          -- unless something staged took its place.
          local there, _ = sys.lstat(opts.resolve_in .. "/" .. rel)
          if st == nil and there ~= nil and there.kind == "dir" then st = there end
        end
        if st == nil or st.kind ~= "dir" then return true end
      end
    end
    return false
  end

  local function make_link(link: PendingLink): boolean, string
    local parts = link.parts
    -- Its own parents, like any other entry's, must be real
    -- directories -- `pending` still holds every link, made or not.
    local ok, why = ensure_dirs(parts, #parts - 1, link.rel)
    if not ok then return false, why end
    if target_crosses_link(parts, #parts - 1, link.target) then
      return false, "archive: refusing a symlink whose target runs through another symlink " ..
        "or a missing directory: " ..
        link.rel
    end
    local full = dest .. "/" .. link.rel
    local st, _ = sys.lstat(full)
    if st ~= nil then
      if st.kind == "dir" then return false, "archive: " .. full .. " is a directory" end
      local _, _ = sys.unlink(full)
    end
    ok, why = Fs.symlink(link.target, full)
    if not ok then return false, why end
    local _, _ = Fs.set_mtime(full, link.mtime)
    return true, ""
  end

  while true do
    local entry, etrouble = reader:next()
    if entry == nil then
      if etrouble ~= "" then return bail(etrouble) end
      break
    end
    if not safe_relative(entry.path) then
      return bail("archive: refusing an unsafe entry path: " .. entry.path)
    end
    local stripped = apply_strip(entry.path, opts.strip_prefix, count)
    -- A path with no empty or `.` components is its own
    -- destination-relative path, and is split into components only
    -- when its parent is not already known to be a real directory.
    local rel: string
    local parent: string
    local parts: {string}
    if stripped ~= nil and ("/" .. stripped .. "/"):find("/%.?/") == nil then
      rel = stripped
      parent = stripped:match("^(.*)/")
    else
      parts = stripped ~= nil and components(stripped) or {}
      rel = join(parts, #parts)
      if #parts > 1 then parent = join(parts, #parts - 1) end
    end
    if rel ~= "" and (opts.filter == nil or opts.filter(stripped)) then
      local kind = entry.kind
      local wanted = kind == "dir" or kind == "file" or
        (kind == "symlink" and links_mode == "create")
      if not wanted and kind ~= "symlink" then
        return bail("archive: cannot extract " .. entry.path .. ": unsupported entry kind '" ..
          kind .. "'")
      end
      if wanted then
        if entries_left ~= nil then
          if entries_left <= 0 then
            return bail("archive: more than " .. String.counted(opts.max_entries, "entry", "entries") ..
              " to extract")
          end
          entries_left = entries_left - 1
        end
        local dest_path = dest .. "/" .. rel
        if kind == "symlink" then
          parts = parts or components(rel)
          if not stays_inside(join(parts, #parts - 1), entry.linkpath) then
            return bail("archive: refusing a symlink escaping the destination: " .. entry.path)
          end
          local link: PendingLink = {
            rel = rel, parts = parts, target = entry.linkpath, mtime = entry.mtime,
          }
          if pending[rel] == nil then pending_count = pending_count + 1 end
          pending[rel] = link
          pending_order[#pending_order + 1] = link
        else
          -- A later entry at a symlink's path replaces it.
          if pending_count > 0 and pending[rel] ~= nil then
            pending[rel] = nil
            pending_count = pending_count - 1
          end
          -- With no symlink pending anywhere, a directory already
          -- checked (and so every directory above it) needs no
          -- second look.
          if kind == "dir" then
            if pending_count > 0 or not real_dirs[rel] then
              parts = parts or components(rel)
              local ok, dtrouble = ensure_dirs(parts, #parts, entry.path)
              if not ok then return bail(dtrouble) end
            end
            dir_times[#dir_times + 1] = { dest_path, entry.mtime }
          else
            if parent ~= nil and (pending_count > 0 or not real_dirs[parent]) then
              parts = parts or components(rel)
              local ok, dtrouble = ensure_dirs(parts, #parts - 1, entry.path)
              if not ok then return bail(dtrouble) end
            end
            local fok, ftrouble = extract_file(dest_path, entry)
            if not fok then return bail(ftrouble) end
          end
          written[#written + 1] = rel
        end
      end
    end
  end

  for _, link in ipairs(pending_order) do
    if pending[link.rel] == link then
      local ok, ltrouble = make_link(link)
      if not ok then return bail(ltrouble) end
      written[#written + 1] = link.rel
    end
  end
  -- Deepest last-listed first, so setting a directory's time is not
  -- undone by then touching something inside it.
  for i = #dir_times, 1, -1 do
    local d = dir_times[i]
    local _, _ = Fs.set_mtime(d[1], d[2])
  end
  local _, _ = reader:close()
  return written, ""
end

--- Unpacks `path` into `dest`, as `tar -x` or `unzip` would. Refuses an
--- absolute entry path, one with a `..` component or a NUL byte, any
--- entry whose path runs through a symlink, an entry it cannot extract
--- (a hard link, a device, a FIFO, a sparse file) and -- when `links` is
--- "create" -- a symlink whose target would land outside `dest`. Each
--- file, directory and symlink gets its archived modification time.
--- Returns the destination-relative paths actually written. A failure
--- partway leaves whatever was already written; a file that fails its
--- own checks (a CRC32, a size) is never put in place.
function Archive.extract(path: string, dest: string, opts?: Archive.ExtractOptions):
    {string} | nil, string
  -- A tail call: [`extract_from`]'s argument errors, raised at level 2,
  -- blame this function's caller.
  return extract_from(path, dest, opts)
end

--- Like `extract`, for the entries `reader` yields (from [`open_stream`],
--- say) rather than a path: read once, to the end, as they arrive, so a
--- stream is unpacked in one pass and bounded memory. Closes `reader`,
--- on every path but a raised argument error, which leaves it open. The
--- same refusals apply, and a failure partway likewise leaves what was
--- already written: unpack into a scratch directory and move it into
--- place to have all or nothing.
function Archive.extract_reader(reader: Archive.Reader, dest: string, opts?: Archive.ExtractOptions):
    {string} | nil, string
  -- A tail call, as in `extract`.
  return extract_from(reader, dest, opts)
end

return Archive
