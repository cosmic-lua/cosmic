--- `cosmic archive`: list, unpack and pack the archives a file turns out
--- to be, for the question ("what is in this release tarball?") that a
--- script costs more than. It is `cosmic.archive` (which detects a zip
--- or a plain, gzip, xz or bzip2 tar from the file's first bytes, not
--- its name, and refuses a member that would land outside the target),
--- `cosmic.tar`, `cosmic.zip` and `cosmic.compress` behind a command
--- line, and nothing of its own.
---
--- Like `cosmic json` it ends in no verdict line: its standard output
--- is data (a listing, the paths written) for a pipe or a `$(...)`.
--- Its exit status is the verdict: 0 done, 1 a member or an input path
--- that is not there, or files that `extract` would overwrite without
--- `--force`, 2 a command line, or an archive or input it cannot read
--- or will not unpack. Complaints go to standard error. build/dispatch.tl's
--- `bare` names it.

local Archive = require("cosmic.archive")
local Cli = require("cosmic.cli")
local Compress = require("cosmic.compress")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Proc = require("cosmic.proc")
local Stream = require("cosmic.stream")
local Tar = require("cosmic.tar")
local Zip = require("cosmic.zip")
local sys = require("cosmic.sys")

--- The `cosmic archive` verb: `run` is what `build/dispatch.tl` calls.
local record verb
  --- Where `run` reads and writes: what a test stands in for.
  record Io
    --- Writes to standard output, as given: the caller adds newlines.
    --- False and why when the bytes did not all go, so the run can
    --- say so: its exit status is its only verdict.
    out: function(text: string): boolean, string
    --- Writes one complaint line, without its newline.
    err: function(line: string)
    --- The whole of standard input, or nil and why.
    stdin: function(): string | nil, string
  end
end

local spec = Cli.options.archive

local usage = "cosmic archive list [--json] <file>|-; " ..
  "cosmic archive extract [-C <dir>] [--force] <file>|- [<member>...]; " ..
  "cosmic archive create [--reproducible] <out.zip|out.tar.gz> <path>..."

--- What a run answers: an exit code and the complaint that goes with it
--- (none for 0).
local record Outcome
  code: integer
  why: string
end

local function fail(code: integer, why: string): Outcome
  return { code = code, why = why }
end

--- An archive module's message, less the "archive: " it starts with,
--- since the complaint names the verb already.
local function bare_message(message: string): string
  return (message:gsub("^archive: ", ""))
end

--- What went wrong reading `path` -- which is `file`, or a temporary
--- copy of standard input -- as one message naming the input once.
local function trouble_of(file: string, path: string, why: string): string
  local message = bare_message(why)
  if path ~= file then
    local start, stop = message:find(path, 1, true)
    while start ~= nil do
      message = message:sub(1, start - 1) .. "standard input" .. message:sub(stop + 1)
      start, stop = message:find(path, 1, true)
    end
  end
  if message:find(file == "-" and "standard input" or file, 1, true) == nil then
    message = (file == "-" and "standard input" or file) .. ": " .. message
  end
  return message
end

--- `path` without its `.` and empty components, so `./a//b/` and `a/b`
--- are one name.
local function normal(path: string): string
  local parts: {string} = {}
  for part in path:gmatch("[^/]+") do
    if part ~= "." then parts[#parts + 1] = part end
  end
  return table.concat(parts, "/")
end

local function has_dotdot(path: string): boolean
  for part in (path .. "/"):gmatch("([^/]*)/") do
    if part == ".." then return true end
  end
  return false
end

--- Runs `body` on a file holding the archive to read: `file` itself, or
--- standard input written out to a temporary one, since the readers
--- want a file to detect a format from and to seek in. The temporary
--- directory is removed after.
-- TODO: stream standard input rather than holding it whole and writing
-- it out, once Archive.open can take a Stream.Reader (it opens a path,
-- and a zip needs positional reads of one).
local function with_archive(file: string, to: verb.Io, body: function(string): Outcome): Outcome
  if file ~= "-" then return body(file) end
  if Proc.is_tty(Fs.stdin) then
    return fail(2, "no file given and standard input is a terminal; give a file or pipe an archive in")
  end
  local text, why = to.stdin()
  if text == nil then return fail(2, why) end
  local dir, dir_why = Fs.mkdtemp("cosmic-archive-")
  if dir == nil then return fail(2, dir_why) end
  local path = dir .. "/stdin"
  local written, write_why = Fs.write(path, text)
  local outcome: Outcome
  if written then
    outcome = body(path)
  else
    outcome = fail(2, write_why)
  end
  local _, _ = Fs.remove_tree(dir)
  return outcome
end

--- Text with a backslash, tab, newline or return as \\, \t, \n or \r
--- and any other control byte as \xHH, so a name never breaks a line
--- or a column (`cosmic sql` escapes a cell the same way).
local function escaped(text: string): string
  return (text:gsub("[%c\\]", function(c: string): string
    if c == "\\" then return "\\\\" end
    if c == "\t" then return "\\t" end
    if c == "\n" then return "\\n" end
    if c == "\r" then return "\\r" end
    return string.format("\\x%02X", c:byte())
  end))
end

------------------------------------------------------------------
-- list
------------------------------------------------------------------

local function list(file: string, as_json: boolean, to: verb.Io): Outcome
  return with_archive(file, to, function(path: string): Outcome
    local entries, why = Archive.list(path)
    if entries == nil then return fail(2, trouble_of(file, path, why)) end
    local text: string
    if as_json then
      local rows = Json.array()
      for _, entry in ipairs(entries) do
        local row: {string:any} = {
          path = entry.path, type = entry.kind, size = entry.size,
          mode = string.format("%04o", entry.mode & 0xfff), mtime = entry.mtime,
        }
        if entry.linkpath ~= "" then row.linkpath = entry.linkpath end
        rows[#rows + 1] = row
      end
      local encoded, encode_why = Json.encode(rows, { pretty = true })
      if encoded == nil then return fail(2, encode_why) end
      text = encoded .. "\n"
    else
      local lines: {string} = {}
      for _, entry in ipairs(entries) do
        local name = escaped(entry.path)
        if entry.linkpath ~= "" then name = name .. " -> " .. escaped(entry.linkpath) end
        lines[#lines + 1] = string.format("%s\t%d\t%04o\t%s", name, entry.size,
          entry.mode & 0xfff, entry.kind)
      end
      text = #lines > 0 and (table.concat(lines, "\n") .. "\n") or ""
    end
    local ok, out_why = to.out(text)
    if not ok then return fail(2, "standard output: " .. out_why) end
    return fail(0, "")
  end)
end

------------------------------------------------------------------
-- extract
------------------------------------------------------------------

--- Whether `name` is `member` or lies under it.
local function under(name: string, member: string): boolean
  return name == member or name:sub(1, #member + 1) == member .. "/"
end

local function extract(file: string, dest: string, force: boolean, members: {string},
    to: verb.Io): Outcome
  local wanted: {string} = {}
  for _, member in ipairs(members) do
    local name = normal(member)
    if name == "" then return fail(2, "an empty member name; " .. usage) end
    wanted[#wanted + 1] = name
  end
  local function selected(name: string): boolean
    if #wanted == 0 then return true end
    for _, member in ipairs(wanted) do
      if under(normal(name), member) then return true end
    end
    return false
  end
  return with_archive(file, to, function(path: string): Outcome
    -- One look first, for what a walk that writes would find too late:
    -- a member that is not in the archive, and files it would replace.
    local entries, why = Archive.list(path)
    if entries == nil then return fail(2, trouble_of(file, path, why)) end
    local missing: {string} = {}
    for _, member in ipairs(wanted) do
      local found = false
      for _, entry in ipairs(entries) do
        if under(normal(entry.path), member) then
          found = true
          break
        end
      end
      if not found then missing[#missing + 1] = member end
    end
    if #missing > 0 then
      return fail(1, file .. ": no such member: " .. table.concat(missing, ", "))
    end
    if not force then
      local clashes: {string} = {}
      for _, entry in ipairs(entries) do
        local name = normal(entry.path)
        -- A path that escapes is for `Archive.extract` to refuse, by
        -- name; it is not looked up outside `dest` here.
        if name ~= "" and entry.path:sub(1, 1) ~= "/" and not has_dotdot(entry.path) and
            selected(entry.path) then
          local st, _ = sys.lstat(dest .. "/" .. name)
          if st ~= nil and not (st.kind == "dir" and entry.kind == "dir") then
            clashes[#clashes + 1] = name
          end
        end
      end
      if #clashes > 0 then
        return fail(1, "would overwrite " .. #clashes .. " existing " ..
          (#clashes == 1 and "path" or "paths") .. " under " .. dest .. " (" ..
          table.concat(clashes, ", ", 1, math.min(#clashes, 5)) ..
          (#clashes > 5 and ", ..." or "") .. "); nothing written, use --force to replace")
      end
    end
    -- No rollback: `Archive.extract` streams entries out as it reads
    -- them, so a refusal partway (an escaping link, a path through a
    -- symlink, a corrupt body) leaves the entries before it written.
    -- Undoing them would mean unpacking into a staging directory and
    -- moving it into place, which breaks extracting into a directory
    -- that already holds files, as `tar -x` does; only what a look at
    -- the listing can settle first (a missing member, an overwrite) is
    -- checked before anything is written.
    local written, extract_why = Archive.extract(path, dest, {
      links = "create",
      filter = selected,
    })
    if written == nil then return fail(2, trouble_of(file, path, extract_why)) end
    local lines: {string} = {}
    for _, name in ipairs(written) do lines[#lines + 1] = escaped(name) end
    local text = #lines > 0 and (table.concat(lines, "\n") .. "\n") or ""
    local ok, out_why = to.out(text)
    if not ok then return fail(2, "standard output: " .. out_why) end
    return fail(0, "")
  end)
end

------------------------------------------------------------------
-- create
------------------------------------------------------------------

--- One thing to archive: its name in the archive and where it is.
local record Item
  name: string
  full: string
  kind: string
  mode: integer
  mtime: integer
  size: integer
  target: string
end

--- "zip" or "tgz" for the extension of `out`, else nil and why not.
local function format_of(out: string): string | nil, string
  local lower = out:lower()
  if lower:match("%.zip$") then return "zip", "" end
  if lower:match("%.tar%.gz$") or lower:match("%.tgz$") then return "tgz", "" end
  -- TODO: once cosmic.compress carries an xz encoder (it has only
  -- `xz_decoder`), accept `.tar.xz` here, and `.tar.bz2` likewise once
  -- it carries a bzip2 encoder (it has only `bz2_decoder`).
  if lower:match("%.tar%.xz$") or lower:match("%.txz$") then
    return nil, out .. ": cannot write .tar.xz, there is no xz encoder; use .tar.gz or .zip"
  end
  if lower:match("%.tar%.bz2$") or lower:match("%.tbz2?$") then
    return nil, out .. ": cannot write .tar.bz2, there is no bzip2 encoder; use .tar.gz or .zip"
  end
  if lower:match("%.tar$") then
    return nil, out .. ": plain .tar is not written; use .tar.gz or .zip"
  end
  return nil, out .. ": cannot tell the format from the name; end it in .zip or .tar.gz"
end

--- The items for the paths given, by name, sorted, and nil and an
--- outcome when one cannot be archived.
local function gather(paths: {string}, skip_file: string | nil, format: string): {Item} | nil, Outcome
  local by_name: {string:Item} = {}
  local function add(name: string, full: string): Outcome | nil
    local st, why = sys.lstat(full)
    if st == nil then return fail(1, full .. ": " .. why) end
    local item: Item = { name = name, full = full, kind = st.kind, mode = st.mode & 0x1ff,
      mtime = st.mtime, size = st.size, target = "" }
    if st.kind == "file" then
      if skip_file ~= nil then
        local same, _ = Fs.absolute(full)
        if same == skip_file then return nil end
      end
    elseif st.kind == "link" then
      if format == "zip" then
        return fail(2, full .. ": a symlink, which zip does not hold; use .tar.gz")
      end
      local target, target_why = Fs.readlink(full)
      if target == nil then return fail(2, target_why) end
      item.target = target
    elseif st.kind ~= "dir" then
      return fail(2, full .. ": neither a file, a directory nor a symlink")
    end
    by_name[name] = item
    return nil
  end
  for _, given in ipairs(paths) do
    local name = normal(given)
    if given == "" or given:sub(1, 1) == "/" or has_dotdot(given) then
      return nil, fail(2, given .. ": an absolute path or one with .. would extract outside its " ..
        "directory; run from the directory it is under")
    end
    -- `.` is the working directory itself: its contents, named from it.
    local root = name == ""
    if not root then
      local trouble = add(name, given)
      if trouble ~= nil then return nil, trouble end
    end
    local rooted, _ = Fs.is_dir(given)
    if (root and rooted) or (not root and by_name[name].kind == "dir") then
      local seen: {{string, string}} = {}
      local odd: string | nil
      local listed, walk_why = Fs.walk(given, function(relative: string, _bare: string, kind: string): boolean
        if kind == "dir" or kind == "link" then
          seen[#seen + 1] = { relative, kind }
        elseif kind ~= "file" and odd == nil then
          -- A fifo, a socket or a device: `Fs.walk` lists only files,
          -- directories and links, so it is met here or not at all.
          odd = relative
        end
        return false
      end)
      if listed == nil then return nil, fail(2, walk_why) end
      if odd ~= nil then
        return nil, fail(2, given .. "/" .. odd .. ": neither a file, a directory nor a symlink")
      end
      for _, relative in ipairs(listed) do seen[#seen + 1] = { relative, "file" } end
      for _, pair in ipairs(seen) do
        local sub = add(root and pair[1] or (name .. "/" .. pair[1]), given .. "/" .. pair[1])
        if sub ~= nil then return nil, sub end
      end
    end
  end
  local names: {string} = {}
  for name in pairs(by_name) do names[#names + 1] = name end
  table.sort(names)
  local items: {Item} = {}
  for _, name in ipairs(names) do items[#items + 1] = by_name[name] end
  return items, fail(0, "")
end

local function create(out: string, paths: {string}, reproducible: boolean, to: verb.Io): Outcome
  local format, format_why = format_of(out)
  if format == nil then return fail(2, format_why) end
  local skip_file: string | nil
  local present, _ = Fs.exists(out)
  if present then
    local resolved, _ = Fs.absolute(out)
    skip_file = resolved
  end
  local items, trouble = gather(paths, skip_file, format)
  if items == nil then return trouble end
  local packed: {Item} = items
  local file, file_why = Stream.create(out)
  if file == nil then return fail(2, file_why) end
  local add_file: function(string, string, integer, integer, integer): boolean, string
  local add_dir: function(string, integer, integer): boolean, string
  local add_link: function(string, string, integer): boolean, string
  local close: function(): boolean, string
  local abort: function(): boolean, string
  if format == "zip" then
    local writer = Zip.writer(file, { deterministic = reproducible })
    add_file = function(name: string, full: string, mode: integer, mtime: integer, size: integer): boolean, string
      local body, why = Stream.open(full)
      if body == nil then return false, why end
      local ok, added = writer:add_file(name, body, { mode = mode, mtime = mtime, size = size })
      local _, _ = body:close()
      if not ok then return false, added end
      return true, ""
    end
    add_dir = function(name: string, mode: integer, mtime: integer): boolean, string
      return writer:add_dir(name, { mode = mode, mtime = mtime })
    end
    add_link = function(_name: string, _target: string, _mtime: integer): boolean, string
      return false, "a symlink, which zip does not hold"
    end
    close = function(): boolean, string return writer:close() end
    abort = function(): boolean, string return writer:abort() end
  else
    local codec, codec_why = Compress.deflater("gzip")
    if codec == nil then
      local _, _ = file:abort()
      return fail(2, codec_why)
    end
    local writer = Tar.writer(Stream.transform_writer(file, codec), { deterministic = reproducible })
    add_file = function(name: string, full: string, mode: integer, mtime: integer, size: integer): boolean, string
      local body, why = Stream.open(full)
      if body == nil then return false, why end
      -- Tar reads only the size it was given, so the body is not read
      -- to its end: close it here, on every path.
      local ok, added = writer:add_file(name, body, { mode = mode, mtime = mtime, size = size })
      local _, _ = body:close()
      if not ok then return false, added end
      return true, ""
    end
    add_dir = function(name: string, mode: integer, mtime: integer): boolean, string
      return writer:add_dir(name, { mode = mode, mtime = mtime })
    end
    add_link = function(name: string, target: string, mtime: integer): boolean, string
      return writer:add_symlink(name, target, { mtime = mtime })
    end
    close = function(): boolean, string return writer:close() end
    abort = function(): boolean, string return writer:abort() end
  end
  for _, item in ipairs(packed) do
    local ok: boolean
    local why: string
    if item.kind == "dir" then
      ok, why = add_dir(item.name, item.mode, item.mtime)
    elseif item.kind == "link" then
      ok, why = add_link(item.name, item.target, item.mtime)
    else
      ok, why = add_file(item.name, item.full, item.mode, item.mtime, item.size)
    end
    if not ok then
      local _, _ = abort()
      return fail(2, item.full .. ": " .. why)
    end
  end
  local closed, close_why = close()
  if not closed then return fail(2, out .. ": " .. close_why) end
  local lines: {string} = {}
  for _, item in ipairs(packed) do lines[#lines + 1] = escaped(item.name) end
  local ok, out_why = to.out(#lines > 0 and (table.concat(lines, "\n") .. "\n") or "")
  if not ok then return fail(2, "standard output: " .. out_why) end
  return fail(0, "")
end

------------------------------------------------------------------
-- the verb
------------------------------------------------------------------

local function read_stdin(): string | nil, string
  return Stream.read_all(Stream.from_fd(Fs.stdin))
end

local standard: verb.Io = {
  out = function(text: string): boolean, string
    return Fs.put(Fs.stdout, text)
  end,
  err = function(line: string)
    local _, _ = Fs.put(Fs.stderr, line .. "\n")
  end,
  stdin = read_stdin,
}

--- `cosmic archive list|extract|create ...`: returns the exit code: 0
--- done, 1 a member or input that is not there or files that would be
--- overwritten, 2 a command line or an archive it cannot read or unpack.
--- @param argv the command line, `archive` at slot 1
--- @param io where the text is read and written; the process's own when nil
function verb.run(argv: {integer:string}, io?: verb.Io): integer
  local to = io or standard
  local function complain(line: string)
    to.err("cosmic: archive: " .. line)
  end
  local parsed, trouble = Flags.parse(argv, 2, spec)
  if parsed == nil then
    complain(trouble .. "; " .. usage)
    return 2
  end
  local flags: Flags.Parsed = parsed
  local words = flags.words
  local action = words[1]
  local function only(option: string, actions: {string}): boolean
    if not flags.set[option] and flags.values[option] == nil then return true end
    for _, name in ipairs(actions) do
      if name == action then return true end
    end
    complain(option .. " does not go with " .. tostring(action) .. "; " .. usage)
    return false
  end
  if action ~= "list" and action ~= "extract" and action ~= "create" then
    complain((action == nil and "name list, extract or create" or ("no such action: " .. action)) ..
      "; " .. usage)
    return 2
  end
  if not (only("--json", { "list" }) and only("-C", { "extract" }) and
      only("--force", { "extract" }) and only("--reproducible", { "create" })) then
    return 2
  end
  local outcome: Outcome
  if action == "list" then
    if #words ~= 2 then
      complain("give one file, or - for standard input; " .. usage)
      return 2
    end
    if words[2] == "" then
      complain("an empty file name; " .. usage)
      return 2
    end
    outcome = list(words[2], flags.set["--json"] or false, to)
  elseif action == "extract" then
    if #words < 2 then
      complain("give a file, or - for standard input; " .. usage)
      return 2
    end
    if words[2] == "" then
      complain("an empty file name; " .. usage)
      return 2
    end
    local members: {string} = {}
    for slot = 3, #words do members[#members + 1] = words[slot] end
    outcome = extract(words[2], flags.values["-C"] or ".", flags.set["--force"] or false,
      members, to)
  else
    if #words < 3 then
      complain("give an output file and at least one path; " .. usage)
      return 2
    end
    local paths: {string} = {}
    for slot = 3, #words do paths[#paths + 1] = words[slot] end
    outcome = create(words[2], paths, flags.set["--reproducible"] or false, to)
  end
  if outcome.why ~= "" then complain(outcome.why) end
  return outcome.code
end

return verb
