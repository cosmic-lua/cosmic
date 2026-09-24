--- Notes on a function the standard library may already have: after a
--- fix, each exported function of a fixed file is compared with the
--- public standard library's, and one that looks like a duplicate earns
--- a note -- never a failure, since both tests are heuristics. The note
--- names the function to look at, so `Proc.which` written beside
--- `Proc.find` is caught when it is written rather than after it lands.
---
--- Two things make a note:
---
--- - Another module's function spells this one's name as code, as the
---   command or call it stands in for (`which`, `mkdir -p`), and no
---   other public symbol but a raw `cosmic.sys` binding is called that. Within one module a backticked
---   name is nearly always a reference to that very sibling, so only
---   other modules count.
--- - The two doc comments share most of their words: at least
---   `SIMILAR` of the words either uses, each having at least
---   `MIN_WORDS` of their own.
-- TODO: tell a sibling a module's documentation refers to from a command
-- it stands in for, so a function named after a command that a sibling
-- in its own module already stands in for is noted too.

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

--- Whether `other`'s documentation spells `name` as code on its own or
--- leading a command line (`` `which` ``, `` `mkdir -p` ``), and `name`
--- is not one of its own parameters, which it backticks anyway.
local function stands_in(other: near.Known, name: string): boolean
  local lower = other.text:lower()
  local spelled = lower:find("`" .. name .. "`", 1, true) ~= nil or
    lower:find("`" .. name .. " -", 1, true) ~= nil
  local escaped = name:gsub("%p", "%%%0")
  local parameter = other.signature:lower():find("[(,]%s*" .. escaped .. "%??:") ~= nil
  return spelled and not parameter
end

--- Whether `text` uses `word` as a word of its own, not inside another.
local function mentions(text: string, word: string): boolean
  local escaped = word:gsub("%p", "%%%0")
  return text:lower():find("%f[%w_]" .. escaped .. "%f[^%w_]") ~= nil
end

--- The notes for `candidates`, declared in `module`, against `known`.
--- Each is one line, `line: message`, in the candidates' order.
function near.notes(module: string, candidates: {near.Candidate},
                    known: {near.Known}): {string}
  local named: {string: integer} = {}
  for _, other in ipairs(known) do
    -- A raw binding's name (sys.mkdir) is what its wrapper stands in
    -- for, so it takes nothing.
    if other.module ~= module and other.module ~= "cosmic.sys" then
      local taken = last_name(other.symbol)
      named[taken] = (named[taken] or 0) + 1
    end
  end
  local out: {string} = {}
  for _, mine in ipairs(candidates) do
    local name = last_name(mine.source_symbol)
    local my_words, my_count = words(mine.text)
    for _, other in ipairs(known) do
      local same = other.module == module and
        (other.source_symbol == mine.source_symbol or other.symbol == name)
      local comparable = (other.kind == "function" or other.kind == "method") and
        other.text ~= ""
      if comparable and not same then
        local why: string = nil
        if other.module ~= module and named[name] == nil and stands_in(other, name) and
            not mentions(mine.text, last_name(other.symbol)) then
          why = "stands in for `" .. name .. "`"
        elseif my_count >= MIN_WORDS then
          local their_words, their_count = words(other.text)
          if their_count >= MIN_WORDS then
            local shared = 0
            for word in pairs(my_words) do
              if their_words[word] then shared = shared + 1 end
            end
            if shared / (my_count + their_count - shared) >= SIMILAR then
              why = "is documented in nearly the same words"
            end
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
function near.known(databases: {Sqlite.Handle}): {near.Known} | nil, string
  local out: {near.Known} = {}
  local owner: {string: integer} = {}
  for index, db in ipairs(databases) do
    local rows, trouble = Sqlite.text_rows(db,
      "SELECT module, symbol, source_symbol, signature, text, kind FROM docs " ..
      "WHERE exported = 1 AND symbol <> '' " ..
      "ORDER BY module, id")
    if rows == nil then
      return nil, trouble
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
