--- What `cosmic fix` keeps of laying out a Teal file it found laid out, so that a run over a tree does not format again
--- the files that have not changed.
---
--- A file's layout ([`build.fix.format`]) is a function of its text, its dialect and the code that makes it: the
--- formatter and every module it loads, down to the lexer and the parser, and the core they run on. The answer kept
--- is that this text, in this dialect, is laid out as it stands. It is kept in the check memo ([`build.check_memo`])
--- under the SHA-256 of the bytecode of each of those modules and of the core's identity, so a change to any of them
--- misses and the formatter runs. A file the formatter changes or refuses is not kept: it is formatted again each
--- run, and a run that writes it keeps what it wrote as the next run's text.
---
--- A memo is an optimization and never an answer: where it cannot be opened, or the code that made an answer cannot
--- be named, a file is formatted.
local Format = require("build.fix.format")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local check_memo = require("build.check_memo")
local fanout = require("build.compile_fanout")

local record laid
  --- A run's use of the memo: its database, which is in a transaction until [`laid.finish`], and the salt its keys hold.
  record Kept
    memo: Sqlite.Handle
    salt: string
  end

  --- Begins a run over the memo in `db`, nil where it cannot or where the code cannot be named. A test gives the `salt`
  --- it keys by; otherwise it is the salt of the formatter: the core's identity and the bytecode of
  --- [`build.fix.format`] and of everything it loads, so that a change to the layout, the equivalence, the lexer or the
  --- parser misses.
  begin: function(db: Sqlite.Handle, salt?: string): laid.Kept?
  --- [`build.fix.format`]'s `format` of `source`, the contents of the file `name`, unless `kept` (nil for no memo)
  --- holds that it is laid out already: then the result is `source`. A result of the formatter itself that is `source` is kept, in
  --- the dialect of the name. `layout` is [`build.fix.format`]'s seam, for a test: what a faulty layout gives is never kept.
  format: function(kept: laid.Kept?, source: string, name: string, layout?: Format.Layouter): Format.Result
  --- Ends the run: with `whole`, a run over every file, the answers it did not use are dropped.
  finish: function(kept: laid.Kept, whole: boolean)
  --- Formats, in copies of this process ([`build.compile_fanout`]), each of `files` whose answer `kept` does not
  --- hold, and keeps those the formatter found laid out, so that the run's own [`laid.format`] of each is a look-up:
  --- the files of a tree are formatted one after another in one process otherwise, some 1400 of them in over two
  --- minutes where the formatter changed. `files` are pairs of a file's name and its text. A copy keeps the keys of
  --- the files it found laid out in a file of its own, and nothing else of a copy reaches the run: a file a copy did
  --- not answer, or answered as not laid out, the run formats itself. Answers how many files the copies answered.
  fan: function(kept: laid.Kept, files: {{string}}): integer
end

local KIND <const> = "laid"

--- The modules whose closure is the code that lays out a file.
local MODULES <const>: {string} = { "build.fix.format" }

--- Changes when what is kept would mean something else.
local VERSION <const> = "laid 3"

--- The salt of the formatter: the version, the core's identity (the lexer and what the modules do run on it) and the
--- bytecode of [`MODULES`] and of everything they load. Nil where any of it cannot be named.
local function salt(): string?
  local parts: mut {string} = { VERSION }
  local identity = Store.meta("host_image")
  if identity == nil then
    return nil
  end
  parts[#parts + 1] = identity
  local every: mut {string} = {}
  local listed, _ = pcall(function(): string
    for _, name in ipairs(Store.closure(MODULES)) do
      every[#every + 1] = name
    end
    return ""
  end)
  if not listed then
    return nil
  end
  for _, name in ipairs(every) do
    local bytes, _ = Store.bytecode(name)
    if bytes == nil then
      return nil
    end
    parts[#parts + 1] = name .. "=" .. Hash.hex_sha256(bytes)
  end
  return Hash.hex_sha256(table.concat(parts, "\0"))
end

function laid.begin(db: Sqlite.Handle, given?: string): laid.Kept?
  local keyed = given or salt()
  if keyed == nil then
    return nil
  end
  local prepared, _ = check_memo.prepare(db, KIND)
  if not prepared then
    return nil
  end
  return { memo = db, salt = keyed }
end

function laid.format(kept: laid.Kept?, source: string, name: string, layout?: Format.Layouter): Format.Result
  local dialect = Format.dialect_of(name)
  local key = if kept == nil then "" else check_memo.key(kept.salt, dialect, source) end
  if kept ~= nil and check_memo.get(kept.memo, KIND, key) == "U" then
    return { text = source, why = "" }
  end
  local result = Format.format(source, name, layout)
  if kept ~= nil and layout == nil and result.text == source then
    check_memo.put(kept.memo, KIND, key, "U")
  end
  return result
end

--- What one copy of a fan holds beyond the process it was forked from, as [`fanout.copies`] counts it: the syntax of
--- the file it formats, and what the formatter makes of it.
local copy_bytes <const> = 512 * 1024 * 1024

function laid.fan(kept: laid.Kept, files: {{string}}): integer
  local due: mut {{string}} = {}
  for _, pair in ipairs(files) do
    local name, source = pair[1] or "", pair[2] or ""
    local key = check_memo.key(kept.salt, Format.dialect_of(name), source)
    if check_memo.get(kept.memo, KIND, key) ~= "U" then due[#due + 1] = { name, source, key } end
  end
  local copies = fanout.copies(#due, Proc.cpu_count(), copy_bytes)
  if copies == 0 then return 0 end
  local dir, _ = Fs.mkdtemp("cosmic-laid-")
  if dir == nil then return 0 end
  local ran = fanout.run(copies, function(copy: integer)
    local keys: mut {string} = {}
    for index = copy, #due, copies do
      local one = assert(due[index], "an index within the list is a file")
      local source = one[2] or ""
      -- A file the formatter raises on is the run's to tell, and costs the copy none of its other files.
      local done, formatted = pcall(Format.format, source, one[1] or "")
      if done and formatted.text == source then keys[#keys + 1] = one[3] or "" end
    end
    assert(Fs.write(dir .. "/" .. tostring(copy), table.concat(keys, "\n")))
  end)
  local answered = 0
  for copy = 1, copies do
    if ran.ended[copy] == true then
      local text, _ = Fs.read(dir .. "/" .. tostring(copy))
      for key in (text or ""):gmatch("[0-9a-f]+") do
        check_memo.put(kept.memo, KIND, key, "U")
      end
      for index = copy, #due, copies do
        if due[index] ~= nil then answered = answered + 1 end
      end
    end
  end
  local _, _ = Fs.remove_tree(dir)
  return answered
end

function laid.finish(kept: laid.Kept, whole: boolean)
  if whole then
    check_memo.finish(kept.memo, KIND)
  else
    local _, _ = Sqlite.run(kept.memo, "COMMIT")
  end
end

return laid
