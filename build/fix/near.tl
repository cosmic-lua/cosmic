--- Notes on a function the standard library may already have: after a
--- fix, each exported function of a fixed file is compared with the
--- public standard library's, and one that looks like a duplicate earns
--- a note -- never a failure, since both tests are heuristics. The note
--- names the function to look at, so a project's `Paths.which` is met
--- with the library's `Proc.find` when it is written, not after.
---
--- Two things make a note:
---
--- - The function is named for a command or C call (`COMMANDS`) that
---   another module's function names as code (`` `which` ``,
---   `` `mkdir -p` ``) -- what it stands in for -- and no other public
---   symbol but a raw `cosmic.sys` binding is called that. Within one
---   module a backticked name is nearly always a reference to that very
---   sibling, so only other modules count.
--- - The two doc comments share most of their words: at least
---   `SIMILAR` of the words either uses, each having at least
---   `MIN_WORDS` of their own.
---
--- Either is dropped when the function's own documentation already
--- names the other, qualified (`Proc.find`) or as code (`` `find` ``).
-- TODO: tell a sibling a module's documentation refers to from a command
-- it stands in for, so a function named after a command that a sibling
-- in its own module already stands in for (Proc.which beside Proc.find)
-- is noted too.

local Sqlite = require("cosmic.sqlite")
local symbols = require("build.symbols")

local record near
  --- One public standard-library symbol, as the shipped `docs` table
  --- holds it: a function is compared, and every kind's name counts
  --- as taken.
  record Known
    module: string
    --- `"function"`, `"record"`, `"field"`, ...
    kind: string
    --- Its own name (`find`).
    symbol: string
    --- The name it was written as (`Proc.find`).
    source_symbol: string
    --- Its declaration, one line: its parameters are backticked in its
    --- documentation as a matter of course.
    signature: string
    text: string
  end

  --- One exported function of a fixed file.
  record Candidate
    source_symbol: string
    text: string
    line: integer
  end
end

--- The share of words two doc comments must have in common.
local SIMILAR = 0.75

--- The fewest words of its own a doc comment needs to be compared.
local MIN_WORDS = 6

--- The commands and C calls a function may be named for and a library
--- function stand in for. A name must be one of these to be taken as
--- what another function stands in for: documentation backticks
--- parameters, fields, keywords and examples too (`is`, `finish`,
--- `require`), which a function named the same way duplicates nothing.
--- Some are left out on purpose: a project's `command` builds an argv
--- rather than finding one, and its `touch` makes a missing file, which
--- Fs.set_mtime does not.
local COMMANDS: {string: boolean} = {}
for name in ([[
  awk base64 basename cat chmod chown cmp cp curl cut date diff
  dirname du env expand fsync ftruncate getconf getentropy getenv getpid
  getrandom grep gunzip gzip head hostname isatty kill ln ls md5sum mkdir
  mkdtemp mktemp mv nanosleep nproc readdir readlink realpath rename rm
  rmdir sed setenv sha1sum sha256sum sha512sum sleep sort stat tail tar
  tee tr truncate umask uname uniq unlink unzip wc wget which xargs
  zip
]]):gmatch("%S+") do
  COMMANDS[name] = true
end

--- Modules whose documentation names things as examples of something
--- else: `cosmic.removed` lists the names the library no longer has.
local EXAMPLES_ONLY: {string: boolean} = { ["cosmic.removed"] = true }

local STOP: {string: boolean} = {}
for word in ("the and for with that this when not from are was its into " ..
    "only never every any all one each which what whose than"):gmatch("%S+") do
  STOP[word] = true
end

--- A doc comment's distinct words of three letters or more, lowercased,
--- without the commonest, and how many there are.
local function words(text: string): {string: boolean}, integer
  local set: {string: boolean} = {}
  local count = 0
  for word in text:lower():gmatch("[%a_][%w_]*") do
    if #word > 2 and not STOP[word] and not set[word] then
      set[word] = true
      count = count + 1
    end
  end
  return set, count
end

--- A symbol's last name, lowercased: `find` for `Proc.find`.
local function last_name(symbol: string): string
  return (symbol:match("([%w_]+)$") or symbol):lower()
end

local function escaped(text: string): string
  return (text:gsub("%p", "%%%0"))
end

--- Whether `other`'s documentation spells `name` as code on its own or
--- leading a command line (`` `which` ``, `` `mkdir -p` ``), and `name`
--- is not one of its own parameters, which it backticks anyway.
local function stands_in(other: near.Known, name: string): boolean
  local lower = other.text:lower()
  local spelled = lower:find("`" .. name .. "`", 1, true) ~= nil or
    lower:find("`" .. name .. " -", 1, true) ~= nil
  local parameter = other.signature:lower():find("[(,]%s*" .. escaped(name) .. "%??:") ~= nil
  return spelled and not parameter
end

--- Whether `text` already names `other`: by the name it was written as
--- (`Proc.find`), or by its own name as code (`` `find` ``). A bare word
--- does not count: short names (find, list, rename) are everyday verbs.
local function names(text: string, other: near.Known): boolean
  local lower = text:lower()
  local qualified = "%f[%w_.]" .. escaped(other.source_symbol:lower()) .. "%f[^%w_]"
  return lower:find(qualified) ~= nil or
    lower:find("`" .. last_name(other.symbol) .. "`", 1, true) ~= nil
end

--- The notes for `candidates`, declared in `module`, against `known`.
--- Each is one line, `line: message`, in the candidates' order.
function near.notes(module: string, candidates: {near.Candidate},
                    known: {near.Known}): {string}
  local named: {string: integer} = {}
  -- Each library function's words, counted once rather than once per
  -- candidate.
  local their_words: {integer: {string: boolean}} = {}
  local their_counts: {integer: integer} = {}
  for index, other in ipairs(known) do
    -- A raw binding's name (sys.mkdir) is what its wrapper stands in
    -- for, so it takes nothing.
    if other.module ~= module and other.module ~= "cosmic.sys" then
      local taken = last_name(other.symbol)
      named[taken] = (named[taken] or 0) + 1
    end
    if other.kind == "function" or other.kind == "method" then
      their_words[index], their_counts[index] = words(other.text)
    end
  end
  local out: {string} = {}
  for _, mine in ipairs(candidates) do
    local name = last_name(mine.source_symbol)
    local my_words, my_count = words(mine.text)
    for index, other in ipairs(known) do
      local same = other.module == module and
        (other.source_symbol == mine.source_symbol or other.symbol == name)
      local comparable = (other.kind == "function" or other.kind == "method") and
        other.text ~= "" and not EXAMPLES_ONLY[other.module]
      if comparable and not same and not names(mine.text, other) then
        local why: string = nil
        if other.module ~= module and COMMANDS[name] and named[name] == nil and
            stands_in(other, name) then
          why = "stands in for `" .. name .. "`"
        elseif my_count >= MIN_WORDS and their_counts[index] >= MIN_WORDS then
          local shared = 0
          for word in pairs(my_words) do
            if their_words[index][word] then shared = shared + 1 end
          end
          if shared / (my_count + their_counts[index] - shared) >= SIMILAR then
            why = "is documented in nearly the same words"
          end
        end
        if why ~= nil then
          out[#out + 1] = mine.line .. ": " .. mine.source_symbol .. ": " ..
            other.source_symbol .. " (" .. other.module .. ") " .. why ..
            "; see cosmic docs " .. other.source_symbol
        end
      end
    end
  end
  return out
end

--- Every exported public standard-library symbol `databases` document,
--- each once: the first database to answer for a module answers for it.
--- A database built before the `docs` table existed answers nothing.
function near.known(databases: {Sqlite.Handle}): {near.Known} | nil, string
  local out: {near.Known} = {}
  local owner: {string: integer} = {}
  for index, db in ipairs(databases) do
    local tables, tables_trouble = Sqlite.text_rows(db,
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'docs'")
    if tables == nil then
      return nil, tables_trouble
    end
    local rows: {{string}} = {}
    if #tables > 0 then
      local found, trouble = Sqlite.text_rows(db,
        "SELECT module, symbol, source_symbol, signature, text, kind FROM docs " ..
        "WHERE exported = 1 AND symbol <> '' ORDER BY module, id")
      if found == nil then
        return nil, trouble
      end
      rows = found
    end
    for _, row in ipairs(rows) do
      local module = row[1]
      if symbols.is_public_module(module) and module:sub(-8) ~= "_example" then
        owner[module] = owner[module] or index
        if owner[module] == index then
          out[#out + 1] = { module = module, symbol = row[2],
            source_symbol = row[3], signature = row[4], text = row[5], kind = row[6] }
        end
      end
    end
  end
  return out, ""
end

return near
