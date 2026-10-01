--- `cosmic archive`: list, unpack and pack the archives a file turns out
--- to be, for the question ("what is in this release tarball?") that a
--- script costs more than. It is [`cosmic.archive`] (which detects a zip
--- or a plain, gzip, xz or bzip2 tar from the file's first bytes, not
--- its name, and refuses a member that would land outside the target),
--- [`cosmic.tar`], [`cosmic.zip`] and [`cosmic.compress`] behind a command
--- line.
---
--- Like `cosmic json` it ends in no verdict line: its standard output
--- is data (a listing, the paths written) for a pipe or a `$(...)`.
--- Its exit status is the verdict: 0 done, 1 a member or an input path
--- that is not there, or files that `extract` would overwrite without
--- `--force`, 2 a command line, or an archive or input it cannot read
--- or will not unpack. Complaints go to standard error. Its spec's
--- `bare = true` makes it one of the bare verbs (build/bare.tl).

local Archive = require("cosmic.archive")
local Cli = require("cosmic.cli")
local Compress = require("cosmic.compress")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Stream = require("cosmic.stream")
local Tar = require("cosmic.tar")
local Zip = require("cosmic.zip")
local sys = require("cosmic.sys")
local bare = require("build.bare")
local verb_spec = require("build.verb_spec")
local plural = require("build.plural")
local String = require("cosmic.string")

--- The `cosmic archive` verb: `run` is what [`build/dispatch.tl`] calls.
local record verb
  --- The verb's registration: see build/verb_spec.tl.
  spec: verb_spec.Spec
  --- Where `run` reads and writes: what a test stands in for.
  record Io
    --- Writes to standard output, as given: the caller adds newlines.
    --- False and why when the bytes did not all go, so the run can
    --- say so: its exit status is its only verdict.
    out: function(text: string): boolean, string
    --- Writes one complaint line, without its newline.
    err: function(line: string)
    --- Standard input as a stream, or nil and why. Read as it comes,
    --- never whole: an archive of any size passes through.
    stdin: function(): Stream.Reader | nil, string
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

--- The first `n` bytes of `source` (fewer at its end), read and not yet
--- put back ([`Stream.prepend`] does that), or nil and why when a read
--- failed, which closes `source`.
local function peek(source: Stream.Reader, n: integer): string | nil, string
  local parts: {string} = {}
  local have = 0
  while have < n do
    local chunk, why = source:read(n - have)
    if chunk == nil then
      if why ~= "" then
        local _, _ = source:close()
        return nil, why
      end
      break
    end
    parts[#parts + 1] = chunk
    have = have + #chunk
  end
  return table.concat(parts), ""
end

--- Writes `source` to a file in a temporary directory, a chunk at a
--- time, and closes `source`: the directory and the path, or nil and
--- why. The caller removes the directory.
local function spool(source: Stream.Reader): string | nil, string
  local dir, dir_why = Fs.mkdtemp("cosmic-archive-")
  if dir == nil then
    local _, _ = source:close()
    return nil, dir_why
  end
  local path = dir .. "/stdin"
  local sink, sink_why = Stream.create(path)
  if sink == nil then
    local _, _ = source:close()
    local _, _ = Fs.remove_tree(dir)
    return nil, sink_why
  end
  local copied, why = Stream.copy(source, sink)
  local _, _ = source:close()
  local closed, close_why = false, ""
  if copied ~= nil then
    closed, close_why = sink:close()
  else
    local _, _ = sink:abort()
  end
  if copied == nil or not closed then
    local _, _ = Fs.remove_tree(dir)
    return nil, why ~= "" and why or close_why
  end
  return dir, ""
end

--- Runs `on_path` on a file holding the archive to read: `file` itself,
--- or, for a zip on standard input, that written out to a temporary
--- file (removed after): a zip's central directory is at its end, so it
--- is read by seeking, not in one pass. Any other archive on standard
--- input is handed to `on_stream` as it arrives, with the bytes sniffed
--- for the format put back.
local function with_archive(file: string, to: verb.Io, on_path: function(string): Outcome,
    on_stream: function(Stream.Reader): Outcome): Outcome
  if file ~= "-" then return on_path(file) end
  local source, why = to.stdin()
  if source == nil then return fail(bare.refused, why) end
  local head, peek_why = peek(source, 4)
  if head == nil then return fail(bare.refused, trouble_of(file, file, peek_why)) end
  local replay = Stream.prepend(head, source)
  if head ~= "PK\3\4" and head ~= "PK\5\6" then return on_stream(replay) end
  local dir, spool_why = spool(replay)
  if dir == nil then return fail(bare.refused, spool_why) end
  local outcome = on_path(dir .. "/stdin")
  local _, _ = Fs.remove_tree(dir)
  return outcome
end

--- The entries of `file`, for `body`. A tar on standard input is read as
--- it arrives, with no file and memory that stays bounded; a zip there
--- is spooled to a temporary file first, since it is read by seeking.
local function with_entries(file: string, to: verb.Io,
    body: function({Archive.Entry}): Outcome): Outcome
  if file ~= "-" then
    local entries, why = Archive.list(file)
    if entries == nil then return fail(bare.refused, trouble_of(file, file, why)) end
    return body(entries)
  end
  local source, why = to.stdin()
  if source == nil then return fail(bare.refused, why) end
  local head, peek_why = peek(source, 4)
  if head == nil then return fail(bare.refused, trouble_of(file, file, peek_why)) end
  local replay = Stream.prepend(head, source)
  if head == "PK\3\4" or head == "PK\5\6" then
    local dir, spool_why = spool(replay)
    if dir == nil then return fail(bare.refused, spool_why) end
    local entries, list_why = Archive.list(dir .. "/stdin")
    local _, _ = Fs.remove_tree(dir)
    if entries == nil then return fail(bare.refused, trouble_of(file, dir .. "/stdin", list_why)) end
    return body(entries)
  end
  local reader, open_why = Archive.open_stream(replay)
  if reader == nil then return fail(bare.refused, trouble_of(file, file, open_why)) end
  local entries, list_why = Archive.list_reader(reader)
  if entries == nil then return fail(bare.refused, trouble_of(file, file, list_why)) end
  return body(entries)
end

--- A name written as [`bare.escape`] does with `named`: a backslash, tab,
--- newline or return as \\, \t, \n or \r and any other control byte as
--- \xHH, so a name never breaks a line or a column (`cosmic sql` escapes a
--- cell the same way).
local function escaped(text: string): string
  return bare.escape(text, { named = true })
end

------------------------------------------------------------------
-- list
------------------------------------------------------------------

local function list(file: string, as_json: boolean, to: verb.Io): Outcome
  return with_entries(file, to, function(entries: {Archive.Entry}): Outcome
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
      if encoded == nil then return fail(bare.refused, encode_why) end
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
    if not ok then return fail(bare.refused, bare.lost(out_why)) end
    return fail(bare.ok, "")
  end)
end

------------------------------------------------------------------
-- extract
------------------------------------------------------------------

--- Whether `name` is `member` or lies under it.
local function under(name: string, member: string): boolean
  return name == member or String.starts_with(name, member .. "/")
end

--- What `extract` refuses for files that are in the way: how many, and
--- the first five.
local record Clashes
  count: integer
  first: {string}
end

--- The path under `dest` that writing `entry` would replace, if any: not
--- a directory it would only be put into.
local function clash_of(entry: Archive.Entry, dest: string, selected: function(string): boolean): string | nil
  local name = normal(entry.path)
  -- A path that escapes is for [`Archive.extract`] to refuse, by
  -- name; it is not looked up outside `dest` here.
  if name == "" or entry.path:sub(1, 1) == "/" or has_dotdot(entry.path) or
      not selected(entry.path) then
    return nil
  end
  local st, _ = sys.lstat(dest .. "/" .. name)
  if st ~= nil and not (st.kind == "dir" and entry.kind == "dir") then return name end
  return nil
end

local function note_clash(clashes: Clashes, name: string)
  clashes.count = clashes.count + 1
  if #clashes.first < 5 then clashes.first[#clashes.first + 1] = name end
end

local function overwrite_refusal(dest: string, clashes: Clashes): Outcome
  return fail(bare.failed, "would overwrite " .. clashes.count .. " existing " ..
    (clashes.count == 1 and "path" or "paths") .. " under " .. dest .. " (" ..
    table.concat(clashes.first, ", ") .. (clashes.count > 5 and ", ..." or "") ..
    "); nothing written, use --force to replace")
end

--- `text` with each `from` in it read as `to`.
local function replaced(text: string, from: string, to: string): string
  local out: {string} = {}
  local at = 1
  while true do
    local start, stop = text:find(from, at, true)
    if start == nil then break end
    out[#out + 1] = text:sub(at, start - 1)
    out[#out + 1] = to
    at = stop + 1
  end
  out[#out + 1] = text:sub(at)
  return table.concat(out)
end

local function print_written(written: {string}, to: verb.Io): Outcome
  local lines: {string} = {}
  for _, name in ipairs(written) do lines[#lines + 1] = escaped(name) end
  local text = #lines > 0 and (table.concat(lines, "\n") .. "\n") or ""
  local ok, out_why = to.out(text)
  if not ok then return fail(bare.refused, bare.lost(out_why)) end
  return fail(bare.ok, "")
end

------------------------------------------------------------------
-- a staged extraction: a stream, all or nothing
------------------------------------------------------------------

--- One change to `dest` that moving a staged tree into it makes: a
--- path moved in (`rel`), replacing what a forced extraction finds
--- there (`replace`), or a directory the destination already holds
--- (`keep`) that takes the archive's time once what is in it has moved.
local record Step
  rel: string
  replace: boolean
  keep: boolean
  mtime: integer
  before: integer
  backup: string
end

--- The names in the directory `path`, sorted, and nil and why when it
--- cannot be read.
local function names_in(path: string): {string} | nil, string
  local entries, why = sys.readdir(path)
  if entries == nil then return nil, path .. ": " .. why end
  local names: {string} = {}
  for name in pairs(entries) do names[#names + 1] = name end
  table.sort(names)
  return names, ""
end

--- Looks the staged tree `tree` over against `dest` -- what is there
--- now -- for everything a move into place would meet, and appends what
--- the move is to do to `steps`; nothing is moved. Returns nil, or the
--- refusal a direct extraction would have made at that path: through a
--- symlink the destination holds, onto a directory or over a file.
--- `rel` is the directory of `tree` looked at, "" for the top.
--- Checked, then moved: a file that appears at a path between this look
--- and [`apply_steps`]' rename of it is replaced without a refusal. That
--- stays -- only another process racing the extraction reaches it, and
--- holding the destination still would need a lock no reader honours.
local function plan_move(tree: string, dest: string, force: boolean, rel: string,
    steps: {Step}, why_of: function(string): string): Outcome | nil
  local names, list_why = names_in(rel == "" and tree or (tree .. "/" .. rel))
  if names == nil then return fail(bare.refused, list_why) end
  for _, name in ipairs(names) do
    local child = rel == "" and name or (rel .. "/" .. name)
    local staged, staged_why = sys.lstat(tree .. "/" .. child)
    if staged == nil then return fail(bare.refused, tree .. "/" .. child .. ": " .. staged_why) end
    local target = dest .. "/" .. child
    local there, there_why, errno = sys.lstat(target)
    if there == nil then
      if errno ~= sys.ENOENT then return fail(bare.refused, target .. ": " .. there_why) end
      steps[#steps + 1] = { rel = child, replace = false, keep = false, mtime = 0, before = 0, backup = "" }
    elseif staged.kind == "dir" then
      if there.kind == "link" then
        return fail(bare.refused, why_of("archive: refusing to write through a symlink: " .. child .. "/"))
      elseif there.kind ~= "dir" then
        return fail(bare.refused, why_of("archive: " .. target .. " is not a directory"))
      end
      local trouble = plan_move(tree, dest, force, child, steps, why_of)
      if trouble ~= nil then return trouble end
      steps[#steps + 1] = { rel = child, replace = false, keep = true, mtime = staged.mtime,
        before = there.mtime, backup = "" }
    elseif not force then
      -- Decided already from the listing; a path that appeared since is
      -- one more that would be overwritten.
      return fail(bare.failed, "would overwrite 1 existing path under " .. dest .. " (" ..
        child .. "); nothing written, use --force to replace")
    elseif there.kind == "dir" then
      return fail(bare.refused, why_of(staged.kind == "link" and ("archive: " .. target .. " is a directory") or
        (target .. ": Is a directory")))
    else
      steps[#steps + 1] = { rel = child, replace = true, keep = false, mtime = 0, before = 0, backup = "" }
    end
  end
  return nil
end

--- How a move ended: `why` is "" when it was done, else what failed;
--- `whole` is false when a failed move could not be entirely undone.
local record Moved
  why: string
  whole: boolean
end

--- Does `steps`, moving each staged path from `tree` to `dest`, an
--- existing file or link it replaces going aside under `aside` first.
--- On a failure every step done is undone, in reverse.
local function apply_steps(tree: string, dest: string, aside: string, steps: {Step}): Moved
  local done = 0
  local trouble = ""
  for slot, step in ipairs(steps) do
    local from, target = tree .. "/" .. step.rel, dest .. "/" .. step.rel
    if step.keep then
      local _, _ = Fs.set_mtime(target, step.mtime)
    else
      if step.replace then
        local _, _ = sys.mkdir(aside)
        step.backup = aside .. "/" .. slot
        local moved, why = Fs.rename(target, step.backup)
        if not moved then
          trouble = why
          break
        end
      end
      local moved, why = Fs.rename(from, target)
      if not moved then
        trouble = why
        if step.replace then local _, _ = Fs.rename(step.backup, target) end
        break
      end
    end
    done = slot
  end
  if trouble == "" then return { why = "", whole = true } end
  local whole = true
  for slot = done, 1, -1 do
    local step = steps[slot]
    local target = dest .. "/" .. step.rel
    if step.keep then
      local _, _ = Fs.set_mtime(target, step.before)
    else
      local back, _ = Fs.rename(target, tree .. "/" .. step.rel)
      if step.replace then
        local restored, _ = Fs.rename(step.backup, target)
        back = back and restored
      end
      whole = whole and back
    end
  end
  return { why = trouble, whole = whole }
end

--- The directories above `dir` that do not exist yet, deepest first.
local function missing_above(dir: string): {string}
  local out: {string} = {}
  local at = dir
  while true do
    local present, _ = Fs.is_dir(at)
    if present ~= false then break end
    out[#out + 1] = at
    local up = Fs.dirname(at)
    if up == at then break end
    at = up
  end
  return out
end

--- An archive read once, as it arrives: unpacked into a staging
--- directory (inside `dest` when that exists, else beside it), with
--- every check `extract` makes of a file made as the members go by, and
--- moved into `dest` only when the stream has ended cleanly and every
--- check passed. A failure removes the staging directory and leaves
--- `dest` as it was, the directories above a `dest` it would have made
--- included.
---
--- What stays non-atomic: the move is one rename per path (one for the
--- whole tree when `dest` does not exist, which is all or nothing), and
--- a move that fails partway is undone, but a process killed in the
--- middle of one leaves the paths moved so far, and a staging directory
--- named `.cosmic-extract-*` to remove. The kernel has no rename of many
--- paths at once, and journalling the move would cost more than a kill
--- at that instant is worth. A kill before the move leaves only the
--- staging directory.
local function extract_streamed(file: string, source: Stream.Reader, dest: string, force: boolean,
    wanted: {string}, selected: function(string): boolean, to: verb.Io): Outcome
  local reader, open_why = Archive.open_stream(source)
  if reader == nil then return fail(bare.refused, trouble_of(file, file, open_why)) end
  local inner: Archive.Reader = reader

  local dest_exists = false
  local is_dir, _ = Fs.is_dir(dest)
  if is_dir == true then dest_exists = true end
  local made: {string} = {}
  local parent = dest_exists and dest or Fs.dirname(dest)
  if not dest_exists then made = missing_above(parent) end
  local function undo_made()
    for _, dir in ipairs(made) do local _, _ = sys.rmdir(dir) end
  end
  local parents_made, parents_why = Fs.mkdirs(parent)
  if not parents_made then
    local _, _ = inner:close()
    return fail(bare.refused, trouble_of(file, file, parents_why))
  end
  local stage, stage_why = sys.mkdtemp(parent .. "/.cosmic-extract-XXXXXX")
  if stage == nil then
    local _, _ = inner:close()
    undo_made()
    return fail(bare.refused, trouble_of(file, file, parent .. ": " .. stage_why))
  end
  local tree = stage .. "/tree"
  local function give_up(outcome: Outcome): Outcome
    local _, _ = Fs.remove_tree(stage)
    undo_made()
    return outcome
  end
  --- A message from the staged tree, as it would read of `dest`.
  local function why_of(message: string): string
    return trouble_of(file, file, replaced(message, tree, dest))
  end

  -- What the whole listing tells: which members were seen, and the
  -- files in the way. Read as the entries pass; the entries are not kept.
  local found: {boolean} = {}
  local clashes: Clashes = { count = 0, first = {} }
  local halted = false
  local finished, finish_why = false, ""
  local function record(entry: Archive.Entry)
    local name = normal(entry.path)
    for slot, member in ipairs(wanted) do
      if not found[slot] and under(name, member) then found[slot] = true end
    end
    if not force then
      local clash = clash_of(entry, dest, selected)
      if clash ~= nil then note_clash(clashes, clash) end
    end
  end
  local function advance(): Archive.Entry | nil
    if finished then return nil end
    local entry, why = inner:next()
    if entry == nil then
      finished, finish_why = true, why
      return nil
    end
    record(entry)
    return entry
  end
  local watched: Archive.Reader = {
    next = function(_self: Archive.Reader): Archive.Entry | nil, string
      if halted then return nil, "" end
      local entry = advance()
      if entry == nil then return nil, finish_why end
      -- Files are already in the way and nothing will be written: read
      -- on for the rest of the listing without unpacking any more.
      if clashes.count > 0 then
        halted = true
        return nil, ""
      end
      return entry, ""
    end,
    -- Whatever ends the extraction, the input is read to its end below
    -- and closed once there.
    close = function(_self: Archive.Reader): boolean, string return true, "" end,
  }

  local written, extract_why = Archive.extract_reader(watched, tree, {
    links = "create",
    filter = selected,
    resolve_in = dest_exists and dest or nil,
  })
  -- The rest of the stream, as [`Archive.list`] would have read it whole
  -- before anything was written: its trouble comes first.
  while advance() ~= nil do end
  local _, _ = inner:close()
  if finish_why ~= "" then return give_up(fail(bare.refused, trouble_of(file, file, finish_why))) end
  local missing: {string} = {}
  for slot, member in ipairs(wanted) do
    if not found[slot] then missing[#missing + 1] = member end
  end
  if #missing > 0 then
    return give_up(fail(bare.failed, file .. ": no such member: " .. table.concat(missing, ", ")))
  end
  if clashes.count > 0 then return give_up(overwrite_refusal(dest, clashes)) end
  if written == nil then return give_up(fail(bare.refused, why_of(extract_why))) end

  if not dest_exists then
    local moved, move_why = Fs.rename(tree, dest)
    if not moved then
      -- `dest` is a file or a directory that appeared since: say what
      -- a direct extraction would have.
      local made_dest, made_why = Fs.mkdirs(dest)
      return give_up(fail(bare.refused, trouble_of(file, file, made_dest and move_why or made_why)))
    end
    local _, _ = Fs.remove_tree(stage)
    return print_written(written, to)
  end
  local steps: {Step} = {}
  local trouble = plan_move(tree, dest, force, "", steps, why_of)
  if trouble ~= nil then return give_up(trouble) end
  local moved = apply_steps(tree, dest, stage .. "/aside", steps)
  if moved.why ~= "" then
    if not moved.whole then
      return fail(bare.refused, why_of(moved.why .. "; the paths it had moved could not all be put back, " ..
        "and are under " .. stage))
    end
    -- A rename names the staged path it moved from: read as `dest`'s.
    return give_up(fail(bare.refused, why_of(moved.why)))
  end
  local _, _ = Fs.remove_tree(stage)
  return print_written(written, to)
end

local function extract(file: string, dest: string, force: boolean, members: {string},
    to: verb.Io): Outcome
  local wanted: {string} = {}
  for _, member in ipairs(members) do
    local name = normal(member)
    if name == "" then return fail(bare.refused, "an empty member name; " .. usage) end
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
    if entries == nil then return fail(bare.refused, trouble_of(file, path, why)) end
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
      -- TODO: name standard input as the other messages here do
      -- ("standard input: no such member"), not by its `-`; this and the
      -- spooled zip's branch both still print `-:`.
      return fail(bare.failed, file .. ": no such member: " .. table.concat(missing, ", "))
    end
    if not force then
      local clashes: Clashes = { count = 0, first = {} }
      for _, entry in ipairs(entries) do
        local clash = clash_of(entry, dest, selected)
        if clash ~= nil then note_clash(clashes, clash) end
      end
      if clashes.count > 0 then return overwrite_refusal(dest, clashes) end
    end
    -- No rollback: [`Archive.extract`] streams entries out as it reads
    -- them, so a refusal partway (an escaping link, a path through a
    -- symlink, a corrupt body) leaves the entries before it written.
    -- A file is read twice anyway (the look above, then this), and an
    -- archive that arrives as a stream is staged instead
    -- ([`extract_streamed`]); a file, which is the caller's own, keeps
    -- `tar -x`'s way of extracting into a directory that already holds
    -- files, with only what a look at the listing can settle first (a
    -- missing member, an overwrite) checked before anything is written.
    local written, extract_why = Archive.extract(path, dest, {
      links = "create",
      filter = selected,
    })
    if written == nil then return fail(bare.refused, trouble_of(file, path, extract_why)) end
    return print_written(written, to)
  end, function(source: Stream.Reader): Outcome
    return extract_streamed(file, source, dest, force, wanted, selected, to)
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
local function gather(paths: {string}, skip_file: string | nil): {Item} | nil, Outcome
  local by_name: {string:Item} = {}
  local function add(name: string, full: string): Outcome | nil
    local st, why = sys.lstat(full)
    if st == nil then return fail(bare.failed, full .. ": " .. why) end
    local item: Item = { name = name, full = full, kind = st.kind, mode = st.mode & 0x1ff,
      mtime = st.mtime, size = st.size, target = "" }
    if st.kind == "file" then
      if skip_file ~= nil then
        local same, _ = Fs.absolute(full)
        if same == skip_file then return nil end
      end
    elseif st.kind == "link" then
      local target, target_why = Fs.readlink(full)
      if target == nil then return fail(bare.refused, target_why) end
      item.target = target
    elseif st.kind ~= "dir" then
      return fail(bare.refused, full .. ": neither a file, a directory nor a symlink")
    end
    by_name[name] = item
    return nil
  end
  for _, given in ipairs(paths) do
    local name = normal(given)
    if given == "" or given:sub(1, 1) == "/" or has_dotdot(given) then
      return nil, fail(bare.refused, given .. ": an absolute path or one with .. would extract outside its " ..
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
          -- A fifo, a socket or a device: [`Fs.walk`] lists only files,
          -- directories and links, so it is met here or not at all.
          odd = relative
        end
        return false
      end)
      if listed == nil then return nil, fail(bare.refused, walk_why) end
      if odd ~= nil then
        return nil, fail(bare.refused, given .. "/" .. odd .. ": neither a file, a directory nor a symlink")
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
  return items, fail(bare.ok, "")
end

--- `item`, a file, added to `writer` as the one body it was when its size was read.
local function add_file(writer: Stream.ArchiveWriter, item: Item): boolean, string
  local body, why = Stream.open(item.full)
  if body == nil then return false, why end
  local ok, added = writer:add_file(item.name, body, { mode = item.mode, mtime = item.mtime, size = item.size })
  -- A tar reads only the size it was given, so a file that grew since
  -- it was stat'd has bytes past it that would be silently dropped; a
  -- zip has read to the end and refused it already.
  local more, more_why: string | nil, string = nil, ""
  if ok then more, more_why = body:read(1) end
  -- A writer does not close its body.
  local _, _ = body:close()
  if not ok then return false, added end
  if more == nil and more_why ~= "" then return false, item.full .. ": " .. more_why end
  if more ~= nil and more ~= "" then
    return false, item.full .. ": grew past " .. plural.count(item.size, "byte") .. " as it was read"
  end
  return true, ""
end

local function create(out: string, paths: {string}, reproducible: boolean, to: verb.Io): Outcome
  local format, format_why = format_of(out)
  if format == nil then return fail(bare.refused, format_why) end
  local skip_file: string | nil
  local present, _ = Fs.exists(out)
  if present then
    local resolved, _ = Fs.absolute(out)
    skip_file = resolved
  end
  local items, trouble = gather(paths, skip_file)
  if items == nil then return trouble end
  local packed: {Item} = items
  local file, file_why = Stream.create(out)
  if file == nil then return fail(bare.refused, file_why) end
  local writer: Stream.ArchiveWriter
  if format == "zip" then
    writer = Zip.writer(file, { deterministic = reproducible })
  else
    local codec, codec_why = Compress.deflater("gzip")
    if codec == nil then
      local _, _ = file:abort()
      return fail(bare.refused, codec_why)
    end
    writer = Tar.writer(Stream.transform_writer(file, codec), { deterministic = reproducible })
  end
  for _, item in ipairs(packed) do
    local ok: boolean
    local why: string
    if item.kind == "dir" then
      ok, why = writer:add_dir(item.name, { mode = item.mode, mtime = item.mtime })
    elseif item.kind == "link" then
      ok, why = writer:add_symlink(item.name, item.target, { mtime = item.mtime })
    else
      ok, why = add_file(writer, item)
    end
    if not ok then
      local _, _ = writer:abort()
      return fail(bare.refused, item.full .. ": " .. why)
    end
  end
  local closed, close_why = writer:close()
  if not closed then return fail(bare.refused, out .. ": " .. close_why) end
  local lines: {string} = {}
  for _, item in ipairs(packed) do lines[#lines + 1] = escaped(item.name) end
  local ok, out_why = to.out(#lines > 0 and (table.concat(lines, "\n") .. "\n") or "")
  if not ok then return fail(bare.refused, bare.lost(out_why)) end
  return fail(bare.ok, "")
end

------------------------------------------------------------------
-- the verb
------------------------------------------------------------------

--- The Reader over standard input, refusing a terminal, where nothing
--- would ever end the bytes.
local function open_stdin(): Stream.Reader | nil, string
  return bare.stdin_reader("no file given and standard input is a terminal; give a file or pipe an archive in")
end

local standard: verb.Io = {
  out = bare.out,
  err = bare.err,
  stdin = open_stdin,
}

--- `cosmic archive list|extract|create ...`: returns the exit code: 0
--- done, 1 a member or input that is not there or files that would be
--- overwritten, 2 a command line or an archive it cannot read or unpack.
--- @param argv the command line, `archive` at slot 1
--- @param io where the text is read and written; the process's own when nil
function verb.run(argv: {integer:string}, io?: verb.Io): integer
  local to = io or standard
  local complain = bare.complainer("archive", to.err)
  local parsed, trouble = Flags.parse(argv, 2, spec)
  if parsed == nil then
    complain(trouble .. "; " .. usage)
    return bare.refused
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
    return bare.refused
  end
  if not (only("--json", { "list" }) and only("-C", { "extract" }) and
      only("--force", { "extract" }) and only("--reproducible", { "create" })) then
    return bare.refused
  end
  local outcome: Outcome
  if action == "list" then
    if #words ~= 2 then
      complain("give one file, or - for standard input; " .. usage)
      return bare.refused
    end
    if words[2] == "" then
      complain(bare.empty_file .. "; " .. usage)
      return bare.refused
    end
    outcome = list(words[2], flags.set["--json"] or false, to)
  elseif action == "extract" then
    if #words < 2 then
      complain("give a file, or - for standard input; " .. usage)
      return bare.refused
    end
    if words[2] == "" then
      complain(bare.empty_file .. "; " .. usage)
      return bare.refused
    end
    local members: {string} = {}
    for slot = 3, #words do members[#members + 1] = words[slot] end
    outcome = extract(words[2], flags.values["-C"] or ".", flags.set["--force"] or false,
      members, to)
  else
    if #words < 3 then
      complain("give an output file and at least one path; " .. usage)
      return bare.refused
    end
    local paths: {string} = {}
    for slot = 3, #words do paths[#paths + 1] = words[slot] end
    outcome = create(words[2], paths, flags.set["--reproducible"] or false, to)
  end
  if outcome.why ~= "" then complain(outcome.why) end
  return outcome.code
end

--- The `archive` verb as [`build/verb_list.tl`] lists it. Reads an archive
--- it is given, never the tree: not stale-checked.
verb.spec = {
  name = "archive",
  guide = "a quick look inside an archive",
  tests = { "build.archive_test", "build.archive_tool_test" },
  run = function(argv: {integer:string}): integer return verb.run(argv) end,
  bare = true,
  takes = "a subcommand and its paths",
  exits = "`archive` prints its listing or the paths it wrote, and exits 0, 1 or 2 as `json` does.",
  passthrough = "its output is data for a pipe, so its exit status is the verdict (build/archive_test.tl)",
}

return verb
