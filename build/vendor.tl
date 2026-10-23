--- Rewrites `vendor/<name>/` trees from the upstream archives their
--- PINs name, keeping only the files the build reads.
---
---     cosmic --standalone build/vendor.tl [name...]
---     cosmic --standalone build/vendor.tl vendor/<name> <archive>
---
--- Like [`build/zig.tl`], this runs standalone -- against the running
--- binary's own standard library, never the tree it sits in -- so it
--- requires `cosmic.*` modules only and holds everything it needs.
---
--- With no archive argument it fetches for itself. Every `name` (every
--- `vendor/*/PIN` by default) is downloaded from its PIN's `url` into
--- `$XDG_CACHE_HOME/cosmic/vendor` (default `$HOME/.cache/cosmic/vendor`;
--- see [`Fs.cache_dir`]), checked against every digest the PIN names --
--- `sha256`, `sha3-256` or both, at least one -- and then rewritten
--- exactly as the two-argument form does. A PIN names the digest its
--- upstream publishes: sqlite.org publishes SHA3-256 alone. A cached
--- file is reused only when every digest still matches the PIN's. This
--- is what [`bin/vendor`] runs; the repository is found from this
--- script's own path, so it works from any working directory.
---
--- The two-argument form rewrites one tree directly from an archive
--- already on disk, without fetching or verifying it. The archive is
--- read with [`cosmic.archive`], whatever its format, and unpacked with
--- [`Archive.extract`] (which refuses absolute and `..` entry paths and
--- keeps permission bits) into a scratch directory beside the tree, so a
--- refused or broken archive never leaves the tree half rewritten. Paths
--- lose a leading `./` and then PIN's `strip` prefix. A file is kept
--- when a `keep` glob matches it and no `drop` glob does: `*` matches
--- within one path segment, `**` across them. Every `keep` must match
--- something, so an upstream rename fails here rather than in the build.
---
--- A PIN with a `file <name>` line vendors a single file that is not an
--- archive at all (a `.pem`, say): its bytes become `<name>`, and every
--- `keep` must match that name. Without a `file` line, an archive
--- [`cosmic.archive`] cannot read is an error, never a single file.
---
--- Everything else in the tree but PIN is removed.
---
--- A PIN with a `feed <url>` line vendors a snapshot of a feed whose
--- newest state is all its URL serves (Mozilla's OneCRL, say), so its
--- `url` cannot be fetched again to the same bytes. Unnamed, such a tree
--- is kept as it is once its file matches the PIN's digests. Named
--- (`bin/vendor onecrl`), the feed's newest state is fetched, written as
--- the file, and the PIN's `version`, `url` and `sha256` rewritten to
--- name it ([`Vendor.feed_pin`]): the state's timestamp, and the feed's
--- URL asking for that timestamp.
local Archive = require("cosmic.archive")
local Codec = require("cosmic.codec")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Http = require("cosmic.http")
local Log = require("cosmic.log")
local sys = require("cosmic.sys")
local String = require("cosmic.string")

local record Vendor
  record Pin
    url: string
    sha256: string
    sha3_256: string
    strip: string
    --- The name a single-file PIN vendors its download as; empty for
    --- an archive.
    file: string
    --- A feed's URL, whose newest state the PIN's file is a snapshot of;
    --- empty for an ordinary download.
    feed: string
    keep: {string}
    drop: {string}
  end

  --- A feed PIN rewritten to name a snapshot ([`Vendor.feed_pin`]).
  record Rewrite
    --- The PIN's new text; "" when it could not be rewritten.
    text: string
    --- Why not; "" when it was.
    why: string
  end

  --- A digest a download is checked against.
  record Digest
    algorithm: Hash.Algorithm
    hex: string
  end
end

local log = Log.new("vendor")

--- `vendor/<name>/PIN`'s text, as `key value` lines. A value is the
--- line's second word, so trailing blanks or a `\r` never become part
--- of it; `keep` and `drop` accumulate, and for every other key the
--- first line naming it wins.
function Vendor.read_pin(text: string): Vendor.Pin
  local pin: Vendor.Pin = { url = "", sha256 = "", sha3_256 = "", strip = "", file = "", feed = "",
    keep = {}, drop = {} }
  local seen: {string:boolean} = {}
  for line in text:gmatch("[^\n]+") do
    local key, value = line:match("^([%w_%-]+)%s+(%S+)")
    if key == "keep" then
      pin.keep[#pin.keep + 1] = value
    elseif key == "drop" then
      pin.drop[#pin.drop + 1] = value
    elseif key ~= nil and not seen[key] then
      seen[key] = true
      if key == "url" then
        pin.url = value
      elseif key == "sha256" then
        pin.sha256 = value
      elseif key == "sha3-256" then
        pin.sha3_256 = value
      elseif key == "strip" then
        pin.strip = value
      elseif key == "file" then
        pin.file = value
      elseif key == "feed" then
        pin.feed = value
      end
    end
  end
  return pin
end

--- `vendor/<name> <archive>`: argv[1] names a tree directly (it holds
--- a "/"), so it and argv[2] are read as the two-argument form.
function Vendor.is_direct_rewrite(argv: {string}): boolean
  return argv[1] ~= nil and argv[2] ~= nil and argv[1]:find("/", 1, true) ~= nil
end

--- The repository root, from this script's own path, Lua's `arg[0]`. Like
--- build/zig.tl's, which names itself in its messages: each runs standalone
--- on cosmic.* modules alone, so neither can load the other's.
function Vendor.repo_root(script_path: string): string | nil, string
  if script_path == nil then
    return nil, "expected to run as .../build/vendor.tl"
  end
  local abs, trouble = Fs.absolute(script_path)
  if abs == nil then
    return nil, trouble
  end
  local root = abs:match("^(.*)/build/[^/]+%.tl$")
  if root == nil then
    return nil, script_path .. ": expected to run as .../build/vendor.tl"
  end
  return root, ""
end

--- Every name `vendor/*/PIN` names under `root`, sorted.
function Vendor.all_names(root: string): {string} | nil, string
  local entries, trouble = Fs.list(root .. "/vendor")
  if entries == nil then
    return nil, trouble
  end
  local names: {string} = {}
  for _, name in ipairs(entries) do
    local pinned, pin_trouble = Fs.exists(root .. "/vendor/" .. name .. "/PIN")
    if pinned == nil then
      return nil, pin_trouble
    end
    if pinned then
      names[#names + 1] = name
    end
  end
  return names, ""
end

--- The digests `pin` names, as algorithm and hex, in a fixed order.
function Vendor.digests(pin: Vendor.Pin): {Vendor.Digest}
  local digests: {Vendor.Digest} = {}
  if pin.sha256 ~= "" then
    digests[#digests + 1] = { algorithm = "sha256", hex = pin.sha256 }
  end
  if pin.sha3_256 ~= "" then
    digests[#digests + 1] = { algorithm = "sha3-256", hex = pin.sha3_256 }
  end
  return digests
end

--- True when `path` exists and has every one of `digests`, at least one.
function Vendor.matches(path: string, digests: {Vendor.Digest}): boolean
  local data, _ = Fs.read(path)
  if data == nil or #digests == 0 then
    return false
  end
  for _, digest in ipairs(digests) do
    if Codec.hex(Hash.digest(digest.algorithm, data)) ~= digest.hex:lower() then
      return false
    end
  end
  return true
end

--- `path`, downloading `url` into it first unless it is already there
--- with every one of `digests`: a stale or corrupt cached file is
--- refetched, never reused, and [`Http.download`] checks each digest as
--- it writes, so a download that lacks one never lands.
function Vendor.fetch(url: string, path: string, digests: {Vendor.Digest}): string | nil, string
  if #digests == 0 then
    return nil, url .. ": no digest to check it against"
  end
  if Vendor.matches(path, digests) then
    return path, ""
  end
  local _, _ = Fs.remove(path)
  -- Upstream's host may have its certificate from any CA Mozilla trusts,
  -- and the download is held to the PIN's digests whoever serves it, so it
  -- trusts every root rather than the minimal set a request trusts by
  -- default.
  local options: Http.Options = { roots = "mozilla" }
  for _, digest in ipairs(digests) do
    if digest.algorithm == "sha256" then
      options.sha256 = digest.hex
    elseif digest.algorithm == "sha3-256" then
      options.sha3_256 = digest.hex
    end
  end
  local ok, trouble = Http.download(url, path, options)
  if not ok then
    return nil, trouble
  end
  return path, ""
end

--- A glob as an anchored Lua pattern.
local function pattern_of(glob: string): string
  local escaped = glob:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0")
  local wild = escaped:gsub("%*%*", "\0"):gsub("%*", "[^/]*"):gsub("\0", ".*")
  return "^" .. wild .. "$"
end

local function matches(globs: {string}, path: string, used?: {string:boolean}): boolean
  local any = false
  for _, glob in ipairs(globs) do
    if path:match(pattern_of(glob)) then
      any = true
      if used ~= nil then
        used[glob] = true
      end
    end
  end
  return any
end

--- `path` without any leading `./` segments.
local function plain(path: string): string
  local out = path
  while out:sub(1, 2) == "./" do
    out = out:sub(3):gsub("^/+", "")
  end
  return out
end

--- The archive's files PIN keeps: by archive path, the path each lands
--- at under the tree. `cosmic refresh` picks a fetched release's files
--- out of its archive with this too, by the rules its PIN names.
function Vendor.kept(pin: Vendor.Pin, entries: {Archive.Entry}): {string:string} | nil, string
  local out: {string:string} = {}
  local used: {string:boolean} = {}
  local strip = plain(pin.strip)
  for _, entry in ipairs(entries) do
    local path = plain(entry.path)
    if entry.kind == "file" and String.starts_with(path, strip) then
      local under = path:sub(#strip + 1)
      if under ~= "" and matches(pin.keep, under, used) and not matches(pin.drop, under) then
        out[entry.path] = under
      end
    end
  end
  for _, glob in ipairs(pin.keep) do
    if not used[glob] then
      return nil, "keep " .. glob .. " matches nothing in the archive"
    end
  end
  return out, ""
end

--- Removes every entry under `tree` -- links included -- but PIN and
--- the `files` names, then every directory that leaves empty.
local function prune(tree: string, files: {string:boolean}, under?: string): boolean, string
  local directory = under == nil and tree or (tree .. "/" .. under)
  local entries, trouble = sys.readdir(directory)
  if entries == nil then
    return false, directory .. ": " .. trouble
  end
  for name, kind in pairs(entries) do
    local path = under == nil and name or (under .. "/" .. name)
    -- A link to a directory is removed, not followed: readdir answers
    -- a link as "link", whatever it leads to.
    if kind == "dir" then
      local pruned, why = prune(tree, files, path)
      if not pruned then
        return false, why
      end
      local left, _ = Fs.list(tree .. "/" .. path)
      if left ~= nil and #left == 0 then
        local _, _ = sys.rmdir(tree .. "/" .. path)
      end
    elseif path ~= "PIN" and not files[path] then
      local gone, why = Fs.remove(tree .. "/" .. path)
      if not gone then
        return false, why
      end
    end
  end
  return true, ""
end

--- Empties `tree` of all but PIN, then moves each `scratch/<archive
--- path>` to `tree/<under>`. Returns how many files it moved.
local function install(tree: string, scratch: string, files: {string:string}): integer | nil, string
  local names: {string:boolean} = {}
  for _, under in pairs(files) do
    names[under] = true
  end
  local pruned, prune_trouble = prune(tree, names)
  if not pruned then
    return nil, prune_trouble
  end
  local count = 0
  for path, under in pairs(files) do
    local dir = under:match("^(.*)/[^/]+$")
    if dir ~= nil then
      local made, trouble = Fs.mkdirs(tree .. "/" .. dir)
      if not made then
        return nil, trouble
      end
    end
    local moved, trouble = Fs.rename(scratch .. "/" .. path, tree .. "/" .. under)
    if not moved then
      return nil, trouble
    end
    count = count + 1
  end
  return count, ""
end

--- A scratch directory beside `tree`, on the same filesystem, so what
--- is unpacked into it can be renamed into place.
local function scratch_beside(tree: string): string | nil, string
  local parent, name = tree:match("^(.*)/([^/]+)$")
  if parent == nil then
    parent, name = ".", tree
  end
  local template = parent .. "/." .. name .. ".vendor.XXXXXX"
  local made, trouble = sys.mkdtemp(template)
  if made == nil then
    return nil, template .. ": " .. trouble
  end
  return made, ""
end

--- Rewrites `tree` to exactly what `pin` keeps of the archive at
--- `archive_path`.
local function from_archive(tree: string, pin: Vendor.Pin, archive_path: string): integer | nil, string
  if #pin.keep == 0 then
    return nil, tree .. "/PIN: a PIN needs at least one keep"
  end
  local entries, list_trouble = Archive.list(archive_path)
  if entries == nil then
    return nil, archive_path .. ": " .. list_trouble
  end
  local files, keep_trouble = Vendor.kept(pin, entries)
  if files == nil then
    return nil, tree .. ": " .. keep_trouble
  end
  local scratch, scratch_trouble = scratch_beside(tree)
  if scratch == nil then
    return nil, scratch_trouble
  end
  local written, extract_trouble = Archive.extract(archive_path, scratch, {
    filter = function(path: string): boolean
      return files[path] ~= nil
    end,
  })
  local count: integer | nil
  local trouble = ""
  if written == nil then
    trouble = archive_path .. ": " .. extract_trouble
  else
    count, trouble = install(tree, scratch, files)
  end
  -- What is left in the scratch directory is only litter; the
  -- extraction's or the install's own answer is the one reported.
  local _, _ = Fs.remove_tree(scratch)
  if count == nil then
    return nil, trouble
  end
  return count, ""
end

--- Rewrites `tree` to hold just `download`'s own bytes, as `pin.file`.
local function as_single_file(tree: string, pin: Vendor.Pin, download: string): integer | nil, string
  if #pin.keep == 0 then
    return nil, tree .. "/PIN: a PIN needs at least one keep"
  end
  for _, glob in ipairs(pin.keep) do
    if not pin.file:match(pattern_of(glob)) then
      return nil, tree .. "/PIN: keep " .. glob .. " does not match file " .. pin.file
    end
  end
  local data, read_trouble = Fs.read(download)
  if data == nil then
    return nil, read_trouble
  end
  local pruned, prune_trouble = prune(tree, { [pin.file] = true })
  if not pruned then
    return nil, prune_trouble
  end
  local written, write_trouble = Fs.write(tree .. "/" .. pin.file, data)
  if not written then
    return nil, write_trouble
  end
  return 1, ""
end

--- Rewrites `tree` from the download at `path`, as its PIN says.
local function rewrite(tree: string, path: string): integer | nil, string
  local text, pin_trouble = Fs.read(tree .. "/PIN")
  if text == nil then
    return nil, pin_trouble
  end
  local pin = Vendor.read_pin(text)
  if pin.file ~= "" then
    if pin.file:find("/", 1, true) ~= nil or pin.file == "PIN" or pin.file:sub(1, 1) == "." then
      return nil, tree .. "/PIN: file " .. pin.file .. " is not a plain name"
    end
    return as_single_file(tree, pin, path)
  end
  return from_archive(tree, pin, path)
end

--- `text`, a feed PIN, naming the snapshot `body` of the feed's state at
--- `timestamp`: its `version` that timestamp, its `url` the feed's with
--- `_expected` asking for it, its `sha256` the body's. No text, and why,
--- when the PIN names no feed, or no `version`, `url` or `sha256` to
--- rewrite.
function Vendor.feed_pin(text: string, timestamp: string, body: string): Vendor.Rewrite
  local feed = text:match("\nfeed%s+(%S+)") or text:match("^feed%s+(%S+)")
  if feed == nil then
    return { text = "", why = "names no feed" }
  end
  local url, replaced = feed:gsub("([?&]_expected=)[^&]*", "%1" .. timestamp)
  if replaced == 0 then
    local separator = "?"
    if feed:find("?", 1, true) ~= nil then separator = "&" end
    url = feed .. separator .. "_expected=" .. timestamp
  end
  local values: {string:string} = { version = timestamp, url = url, sha256 = Hash.hex_sha256(body) }
  local seen: {string:boolean} = {}
  local lines: {string} = {}
  for line in text:gmatch("[^\n]+") do
    local key = line:match("^(%S+)") or ""
    local value = values[key] or ""
    if value ~= "" and seen[key] == nil then
      seen[key] = true
      lines[#lines + 1] = key .. " " .. value
    else
      lines[#lines + 1] = line
    end
  end
  for _, key in ipairs({ "version", "url", "sha256" }) do
    if seen[key] == nil then
      return { text = "", why = "names no " .. key }
    end
  end
  return { text = table.concat(lines, "\n") .. "\n", why = "" }
end

--- A feed tree (`pin.feed`): with `newest`, its file and PIN rewritten
--- from the feed's newest state; without, kept as it is when its file
--- matches the PIN's digests, and refused when it does not. The count of
--- files written and "", or 0 and why. `cache_dir` answers the cache
--- directory and "", or "" and why.
local function feed_tree(tree: string, text: string, pin: Vendor.Pin,
                         cache_dir: function(): (string, string), newest: boolean): integer, string
  if pin.file == "" then
    return 0, tree .. "/PIN: a feed's snapshot needs a file line"
  end
  local digests = Vendor.digests(pin)
  if not newest then
    if pin.file ~= "" and Vendor.matches(tree .. "/" .. pin.file, digests) then
      return 1, ""
    end
    return 0, tree .. "/" .. pin.file .. " does not match its PIN; name the tree to take the feed's newest"
  end
  local cache, cache_trouble = cache_dir()
  if cache == "" then
    return 0, cache_trouble
  end
  local path = cache .. "/" .. pin.file
  local _, _ = Fs.remove(path)
  local ok, trouble = Http.download(pin.feed, path)
  if not ok then
    return 0, pin.feed .. ": " .. trouble
  end
  local body, read_trouble = Fs.read(path)
  if body == nil then
    return 0, read_trouble
  end
  local timestamp = body:match('"timestamp"%s*:%s*(%d+)%s*,%s*"changes"')
  if timestamp == nil then
    return 0, pin.feed .. ": names no timestamp for its state"
  end
  local rewritten = Vendor.feed_pin(text, timestamp, body)
  if rewritten.text == "" then
    return 0, tree .. "/PIN " .. rewritten.why
  end
  local count, rewrite_trouble = as_single_file(tree, pin, path)
  if count == nil then
    return 0, rewrite_trouble
  end
  local written, write_trouble = Fs.write(tree .. "/PIN", rewritten.text)
  if not written then
    return 0, write_trouble
  end
  return count, ""
end

--- Fetches `name`'s PIN's download into `cache` (reusing it when its
--- digests still match) and rewrites `vendor/<name>` from it; a feed's
--- tree as [`feed_tree`] does, from the feed's newest state when `named`.
local function fetch_and_rewrite(root: string, cache_dir: function(): (string, string), name: string,
                                 named: boolean): integer | nil, string
  local tree = root .. "/vendor/" .. name
  local text, pin_trouble = Fs.read(tree .. "/PIN")
  if text == nil then
    return nil, pin_trouble
  end
  local pin = Vendor.read_pin(text)
  if pin.feed ~= "" then
    local count, trouble = feed_tree(tree, text, pin, cache_dir, named)
    if trouble ~= "" then
      return nil, trouble
    end
    return count, ""
  end
  if pin.url == "" then
    return nil, tree .. "/PIN names no url"
  end
  local digests = Vendor.digests(pin)
  if #digests == 0 then
    return nil, tree .. "/PIN names no sha256 or sha3-256"
  end
  local cache, cache_trouble = cache_dir()
  if cache == "" then
    return nil, cache_trouble
  end
  local base = pin.url:match("([^/]+)$") or name
  local fetched, ftrouble = Vendor.fetch(pin.url, cache .. "/" .. base, digests)
  if fetched == nil then
    return nil, ftrouble
  end
  return rewrite(tree, fetched)
end

--- What `bin/vendor --help` says.
local usage = "bin/vendor [name... | vendor/<name> <archive>]"
local about = "Rewrites each vendor/<name> tree -- every one by default -- from the\n" ..
  "archive its PIN names, keeping only what the build reads. Given a tree\n" ..
  "and an archive already on disk, rewrites that tree from it. A feed's\n" ..
  "snapshot (a PIN with a feed line) is kept unless the tree is named, which\n" ..
  "takes the feed's newest state."
local spec: {string:boolean | Flags.Option} = {
  ["--help"] = { about = "show this help" },
  ["-h"] = { about = "show this help" },
}

--- Runs [`bin/vendor`]'s command line: the words are names, or a tree and
--- an archive. It takes no options but `--help`, so a word that begins
--- with "-" is refused (exit 2) rather than read as a name; one that must
--- begin with "-", such as an archive's path, goes after "--".
--- @param argv the words after the script's path
--- @param program this script's own path, to find the repository from
function Vendor.run(argv: {string}, program: string): integer
  local parsed, parse_trouble = Flags.parse(argv, 1, spec)
  if parsed == nil then
    log:complain(parse_trouble .. "; usage: " .. usage)
    return 2
  end
  if parsed.set["--help"] or parsed.set["-h"] then
    log:say(Flags.help({ spec = spec, about = about, usage = "[name... | vendor/<name> <archive>]" }, "bin/vendor"))
    return 0
  end
  local words = parsed.words
  if Vendor.is_direct_rewrite(words) then
    local tree = (words[1]):gsub("/+$", "")
    local count, trouble = rewrite(tree, words[2])
    if count == nil then
      log:complain(trouble)
      return 1
    end
    log:say("vendor: " .. tree .. " (" .. count .. " files)")
    return 0
  end

  local root, root_trouble = Vendor.repo_root(program)
  if root == nil then
    log:complain(root_trouble)
    return 2
  end

  local names = words
  if #names == 0 then
    local found, trouble = Vendor.all_names(root)
    if found == nil then
      log:complain(trouble)
      return 1
    end
    names = found
  end

  -- Asked for once a tree needs it: keeping a feed's snapshot needs none.
  local repo: string = root
  local held: {string:string} = {}
  local function cache_dir(): string, string
    local cache = held["cache"]
    if cache == nil then
      local made, trouble = Fs.cache_dir("vendor")
      if made == nil then
        return "", trouble
      end
      held["cache"] = made
      cache = made
    end
    return cache, ""
  end

  local failed = false
  for _, name in ipairs(names) do
    local count, trouble = fetch_and_rewrite(repo, cache_dir, name, #words > 0)
    if count == nil then
      log:complain(name .. ": " .. trouble)
      failed = true
    else
      log:say("vendor: vendor/" .. name .. " (" .. count .. " files)")
    end
  end
  return failed and 1 or 0
end

--- The entry point: [`Vendor.run`] with this script's path, Lua's `arg[0]`.
function Vendor.main(argv: {string}): integer
  return Vendor.run(argv, (assert(arg[0], "vendor: no script path")))
end

return Vendor
