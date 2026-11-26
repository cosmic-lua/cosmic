--- The lookup of what a query names: exact names, near names and the words of a search of [`cosmic.doc`]. Use [`cosmic.doc`]; apart from it only to keep that module smaller.

local Sqlite = require("cosmic.sqlite")
local String = require("cosmic.string")
local Distance = require("cosmic.internal.distance")
local Types = require("cosmic.doc.types")
local Examples = require("cosmic.doc.examples")
local Search = require("cosmic.doc.search")
local Usage = require("cosmic.doc.usage")
local Members = require("cosmic.doc.members")
local type Command = Types.Command
local type View = Types.View
local type Entry = Types.Entry
local type Lookup = Types.Lookup
local CLOSEST = Search.CLOSEST
local STOP_WORDS = Search.STOP_WORDS
local across = Usage.across
local closest = Search.closest
local coded_words = Usage.coded_words
local command_of = Usage.command_of
local database_of = Usage.database_of
local effective_counts = Usage.effective_counts
local entry_module = Usage.entry_module
local fts_query = Search.fts_query
local has_docs = Search.has_docs
local is_library = Usage.is_library
local module_symbol = Search.module_symbol
local modules_ending = Search.modules_ending
local named = Search.named
local named_all = Search.named_all
local query_words = Search.query_words
local scoped = Search.scoped
local searched = Search.searched
local stand_ins = Search.stand_ins
local text = Examples.text

local record Resolve
  type Entry = Entry
  type Lookup = Lookup
  type View = View
end

--- `entries` as a lookup's result, with the entries of `ahead` standing before them.
function Resolve.lookup(entries: {Entry}, exact: boolean, count: integer,
                        partial?: boolean, ahead?: {Entry}): Lookup
  local items: mut {Entry} = {}
  for _, entry in ipairs(ahead or {}) do items[#items + 1] = entry end
  for _, entry in ipairs(entries) do items[#items + 1] = entry end
  -- A record that is also an array takes its items where it is made and nowhere after.
  local out: Lookup = { exact = exact, named = count, closest = partial == true, modules = 0,
    table.unpack(items) }
  return out
end
local lookup = Resolve.lookup

--- `written` as FTS5's default tokenizer reads it, closely enough for a
--- match: lowercased, each run of anything but letters and digits (`_`
--- among them) one space, and a space at each end, so a phrase is found
--- as " phrase " and never inside a longer word.
local function tokens_of(written: string): string
  local spaced = written:lower():gsub("[^%w]+", " ")
  return " " .. String.trim(spaced) .. " "
end

--- The commands whose symbol, prose and help together carry every word of `query`, as the entries that document
--- them (`cosmic.cli.<verb>` for the tool's): the search reads doc comments, and what a command's help says -- its
--- `about`, `usage`, `options` and `examples` ([`Command`]) -- is data, so it is matched here instead, as the
--- documented binary has it and `render` shows it. Each word is a phrase, as [`fts_query`] quotes it:
--- `COSMIC_TEST_TIMEOUT` must be those three tokens in a row. They come after what the index found, as the lesser
--- match: most of what a verb's options say is said again, closer, by the code they drive. Those whose row,
--- `about` and `usage` carry the words come first, then those that needed their options or examples, each in the
--- order of the rows; where no command says more than its options, as the tool's verbs do, all are in the order
--- of the rows. A usage or example line is matched without the program's name it opens with, which every one
--- holds. A command `found` already holds is not repeated.
local function by_help(view: View, query: string,
                       found: {Entry}): {Entry}?, string
  local wanted: mut {string} = {}
  for quoted in (fts_query(query) .. " "):gmatch('"([^"]*)" ') do
    local phrase = tokens_of(quoted)
    if phrase ~= "  " then wanted[#wanted + 1] = phrase end
  end
  if #wanted == 0 then
    return {}, ""
  end
  local commands: mut {string: Command} = {}
  local names: mut {string} = {}
  for _, command in ipairs(view.commands) do
    if command.options ~= nil or command.about ~= nil or command.usage ~= nil or command.examples ~= nil then
      names[#names + 1] = if command.symbol == "" then command.module else command.symbol end
      commands[command.module .. "\n" .. command.symbol] = command
    end
  end
  table.sort(names)
  local fields, trouble = across(view,
    function(db: Sqlite.Handle, public: boolean): {Entry}?, string
      return named_all(db, public, names)
    end, entry_module)
  if fields == nil then
    return nil, trouble
  end
  local held: mut {string:boolean} = {}
  for _, entry in ipairs(found) do held[entry.module .. "\n" .. entry.symbol] = true end
  local function carries(spoken: string): boolean
    for _, phrase in ipairs(wanted) do
      if not spoken:find(phrase, 1, true) then return false end
    end
    return true
  end
  -- A line a command is typed as opens with the program's name and the command's word, which every such line
  -- holds alike: what a search matches of it is the rest.
  local function typed_rest(lines?: string): string
    if lines == nil then
      return ""
    end
    local out: mut {string} = {}
    for line in String.lines(lines) do
      local rest = line
      local program = view.program
      if program ~= nil and rest:sub(1, #program + 3) == "  " .. program .. " " then
        rest = rest:sub(#program + 4)
      elseif program ~= nil and rest:sub(1, #program + 1) == program .. " " then
        rest = rest:sub(#program + 2)
      end
      out[#out + 1] = rest
    end
    return table.concat(out, "\n")
  end
  -- The tool's verbs say nothing but their options: they keep the order of their rows, as they always have.
  local ranked = false
  for _, command in ipairs(view.commands) do
    if command.about ~= nil or command.usage ~= nil or command.examples ~= nil then
      ranked = true
    end
  end
  local first: mut {Entry} = {}
  local after: mut {Entry} = {}
  for _, entry in ipairs(fields) do
    -- A row of the name that documents no command has no help to speak of.
    local key = entry.module .. "\n" .. entry.symbol
    local command = commands[key]
    if command ~= nil and held[key] ~= true then
      held[key] = true
      local said = (if entry.symbol == "" then entry.module else entry.source_symbol end) .. "\n" .. entry.signature .. "\n" .. entry.text .. "\n" ..
        (command.about or "") .. "\n" .. typed_rest(command.usage)
      if carries(tokens_of(said)) then
        first[#first + 1] = entry
      elseif carries(tokens_of(said .. "\n" .. (command.options or "") .. "\n" .. typed_rest(command.examples))) then
        if ranked then after[#after + 1] = entry else first[#first + 1] = entry end
      end
    end
  end
  for _, entry in ipairs(after) do first[#first + 1] = entry end
  return first, ""
end

--- Whether some database of `view` documents `word`, in any form the index stems alike ("reads" for "reading").
local function documented_word(view: View, word: string): boolean?, string
  for _, db in ipairs(view.databases) do
    local documented, documented_trouble = has_docs(db)
    if documented == nil then
      return nil, documented_trouble
    end
    if documented then
      local rows, trouble = db:rows("SELECT 1 FROM docs_fts WHERE docs_fts MATCH ?1 LIMIT 1",
        { text('"' .. word .. '"') })
      if rows == nil then
        return nil, tostring(trouble)
      end
      if #rows > 0 then
        return true, ""
      end
    end
  end
  return false, ""
end

--- The word of the documentation a mistyped `word` most likely meant, or "" when none is within reach
--- ([`Distance.reach`]): of the words the databases of `view` list (`docs_words`), the one the fewest edits from
--- `word`, then the one more rows carry, counted over every database, then by spelling. A `word` under four
--- letters has none, being near too many. A word a search never
--- requires ([`STOP_WORDS`]) is never returned, and a database written before it listed its words offers none. The
--- words are those of every row, a public source's private rows among them: a word only those hold is searched
--- for and finds nothing, and none of them is shown.
local function nearest_word(view: View, word: string): string?, string
  local lower = word:lower()
  local reach = Distance.reach(lower)
  -- A word of three letters is one edit from too many others for the nearest to be the one meant.
  if reach == 0 or #lower < 4 then
    return "", ""
  end
  local carried: mut {string: integer} = {}
  for _, db in ipairs(view.databases) do
    local listed, listed_trouble = db:rows(
      "SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = 'docs_words'")
    if listed == nil then
      return nil, tostring(listed_trouble)
    end
    if #listed > 0 then
      local rows, trouble = db:rows(
        "SELECT word, rows FROM docs_words WHERE length(word) BETWEEN ?1 AND ?2",
        { { integer = #lower - reach }, { integer = #lower + reach } })
      if rows == nil then
        return nil, tostring(trouble)
      end
      for _, row in ipairs(rows) do
        local listed_word = row:text(1)
        carried[listed_word] = (carried[listed_word] or 0) + (row:integer(2))
      end
    end
  end
  local best, best_far, best_rows = "", reach + 1, 0
  for listed_word, rows in pairs(carried) do
    if STOP_WORDS[listed_word] ~= true and listed_word ~= lower then
      local far = Distance.between(lower, listed_word, reach)
      if far < best_far or (far == best_far and far <= reach and
          (rows > best_rows or (rows == best_rows and listed_word < best))) then
        best, best_far, best_rows = listed_word, far, rows
      end
    end
  end
  return best, ""
end

--- `query` with each word no documentation holds taken for the nearest word one does ([`nearest_word`]), or ""
--- when no word of it changes. Only a word of letters is respelled: a name with a digit or an underscore is
--- code, which is looked up as written.
local function respelled(view: View, query: string): string?, string
  local words: mut {string} = {}
  local changed = false
  for _, word in ipairs(query_words(query)) do
    local kept = word
    if word:match("^%a+$") ~= nil then
      local known, known_trouble = documented_word(view, word)
      if known == nil then
        return nil, known_trouble
      end
      if not known then
        local near, near_trouble = nearest_word(view, word)
        if near == nil then
          return nil, near_trouble
        end
        if near ~= "" then
          kept = near
          changed = true
        end
      end
    end
    words[#words + 1] = kept
  end
  return if changed then table.concat(words, " ") else "" end, ""
end

--- What `query` names, across `databases`, by the first rule that
--- matches:
--- - the public module a bare lowercase name ends (`json`, `fs`), with
---   its verb, if it is one (`test`), as a see-also line after it;
--- - its exact matches, when it names a symbol or a module, a member of
---   a type an alias stands for, or a module's member written in full
---   ([`cosmic.fs.read`]) or from its last name (`Cli.order`);
--- - a field of a global [`cosmic.removed`] lists as withheld, which no
---   live row covers (`os.getenv`): what to write instead, as the
---   compiler says it (see [`Members.removed_by`]);
--- - for a qualified name that names nothing, what its qualifier offers
---   (see `scoped`);
--- - the documentation that carries all its words, and the verbs whose
---   help does (see [`by_help`]).
--- - Where nothing carries them, what the words a misspelling of them meant
---   name or are documented by (see [`respelled`]), then the rows that carry
---   some of them.
function Resolve.lookup_names(view: View, query: string, as_respelled?: boolean): Lookup?, string
  -- A bare lowercase name that ends a public module's name is that
  -- module (`json` is `cosmic.json`, not the internal record `json`);
  -- the symbols it names exactly follow the module (`string` is
  -- [`cosmic.string`], then [`Shape.string`]).
  local modules: {Entry} = {}
  if query:match("^%l[%w_]*$") ~= nil then
    local found_modules, modules_trouble = across(view,
      function(db: Sqlite.Handle, _: boolean): {Entry}?, string
        return modules_ending(db, query)
      end, entry_module)
    if found_modules == nil then
      return nil, modules_trouble
    end
    modules = found_modules
  end
  local exact, exact_trouble = across(view,
    function(db: Sqlite.Handle, public: boolean): {Entry}?, string
      return named(db, public, query)
    end, entry_module)
  if exact == nil then
    return nil, exact_trouble
  end
  if #modules > 0 then
    -- What only shares the module's name, an internal record (`json`),
    -- is not another result.
    local seen: mut {string: boolean} = {}
    for _, entry in ipairs(modules) do
      seen[entry.module .. "\n" .. entry.symbol] = true
    end
    -- With a library module of the name, the module comes first, then
    -- the other symbols, and the verb `cosmic <query>` names is a
    -- see-also line after the modules. Otherwise (a tool's or a
    -- project's own module of the name) the verb comes first, as
    -- `cosmic docs sql` says it does.
    local answers: mut {Entry} = {}
    local rest: mut {Entry} = {}
    local verb: Entry? = nil
    -- A command a module documents (`cosmic.cli.json` for `cosmic json`) is the verb, not one of the modules.
    local named_modules: mut {Entry} = {}
    local commands: mut {Entry} = {}
    for _, entry in ipairs(modules) do
      local command = command_of(view, entry)
      if command ~= nil and command.name == query then
        commands[#commands + 1] = entry
      else
        named_modules[#named_modules + 1] = entry
      end
    end
    modules = named_modules
    local library = false
    for _, entry in ipairs(modules) do
      if is_library(view, entry.module) then library = true end
    end
    for _, entry in ipairs(commands) do
      if library then verb = entry else answers[#answers + 1] = entry end
    end
    for _, entry in ipairs(exact) do
      local internal = entry.module:sub(1, 16) == "cosmic.internal." and
        entry.symbol == query
      local command = command_of(view, entry)
      if command ~= nil and command.name == query then
        if library then verb = entry else answers[#answers + 1] = entry end
        seen[entry.module .. "\n" .. entry.symbol] = true
      elseif not internal and seen[entry.module .. "\n" .. entry.symbol] ~= true then
        rest[#rest + 1] = entry
      end
    end
    for _, entry in ipairs(modules) do answers[#answers + 1] = entry end
    local module_count = #answers
    for _, entry in ipairs(rest) do answers[#answers + 1] = entry end
    local counted, count_trouble = effective_counts(view, answers)
    if not counted then
      return nil, count_trouble
    end
    local found = lookup(answers, true, #answers)
    found.verb = verb
    found.modules = module_count
    return found, ""
  end
  if #exact > 0 then
    local named_count = #exact
    -- A raw binding's name is also what its wrapper stands in for:
    -- "unlink" finds sys.unlink and then Fs.remove.
    local raw = query:match("^[%w_]+$") ~= nil
    for _, entry in ipairs(exact) do
      if entry.module ~= "cosmic.sys" then
        raw = false
      end
    end
    if raw then
      local wrapping, wrapping_trouble = across(view,
        function(db: Sqlite.Handle, public: boolean): {Entry}?, string
          return stand_ins(db, public, query)
        end, entry_module)
      if wrapping == nil then
        return nil, wrapping_trouble
      end
      for _, entry in ipairs(wrapping) do
        exact[#exact + 1] = entry
      end
    end
    -- An environment variable's declaration ([`Env.Name.COSMIC_TEST_TIMEOUT`])
    -- is not all there is to say of it: the verbs whose options carry it
    -- follow, as for a search.
    local answers: mut {Entry} = {}
    for _, entry in ipairs(exact) do answers[#answers + 1] = entry end
    if query:match("^%u[%u%d_]*$") ~= nil then
      local verbs, verbs_trouble = by_help(view, query, exact)
      if verbs == nil then
        return nil, verbs_trouble
      end
      for _, entry in ipairs(verbs) do answers[#answers + 1] = entry end
    end
    local counted, count_trouble = effective_counts(view, answers)
    if not counted then
      return nil, count_trouble
    end
    return lookup(answers, true, named_count), ""
  end
  -- A field of a withheld global resolves to what replaces it, before a search offers another module's member of the same name.
  local gone = Members.removed_by(query)
  if gone ~= nil then
    return lookup({ gone }, true, 1), ""
  end
  -- A module the index lists is always found, though it has no row
  -- of its own to name it.
  local owner = view.owners[query]
  if owner ~= nil then
    local held, held_trouble = module_symbol(database_of(view, owner), view.public[owner] == true, query)
    if held == nil then
      return nil, held_trouble
    end
    if #held > 0 then
      local counted, count_trouble = effective_counts(view, held)
      if not counted then
        return nil, count_trouble
      end
      return lookup(held, true, #held), ""
    end
  end
  local through, through_trouble = Members.in_full(view, query)
  if through == nil then
    return nil, through_trouble
  end
  if #through == 0 then
    local short, short_trouble = Members.by_last_name(view, query)
    if short == nil then
      return nil, short_trouble
    end
    through = short
  end
  if #through > 0 then
    local counted, count_trouble = effective_counts(view, through)
    if not counted then
      return nil, count_trouble
    end
    return lookup(through, true, #through), ""
  end
  local found: mut {Entry} = {}
  local qualifier, name = query:match("^([%w_]+)[.:]([%w_]+)$")
  if qualifier ~= nil and name ~= nil then
    local near, near_trouble = across(view,
      function(db: Sqlite.Handle, public: boolean): {Entry}?, string
        return scoped(db, public, qualifier, name)
      end, entry_module)
    if near == nil then
      return nil, near_trouble
    end
    found = near
  end
  if #found == 0 then
    local searched_found, search_trouble = across(view,
      function(db: Sqlite.Handle, public: boolean): {Entry}?, string
        return searched(db, public, query)
      end, entry_module)
    if searched_found == nil then
      return nil, search_trouble
    end
    found = searched_found
    local verbs, verbs_trouble = by_help(view, query, found)
    if verbs == nil then
      return nil, verbs_trouble
    end
    for _, entry in ipairs(verbs) do found[#found + 1] = entry end
    if #found == 0 then
      local ruled, ruled_trouble = coded_words(view, query)
      if ruled == nil then
        return nil, ruled_trouble
      end
      found = ruled
    end
    if #found == 0 then
      -- Nothing holds the words as given: look up the words a misspelling of them meant, as that query alone
      -- would be, its closest matches among them.
      local again = ""
      if as_respelled ~= true then
        local meant, meant_trouble = respelled(view, query)
        if meant == nil then
          return nil, meant_trouble
        end
        again = meant
      end
      if again ~= "" then
        local meant, meant_trouble = Resolve.lookup_names(view, again, true)
        if meant == nil then
          return nil, meant_trouble
        end
        if #meant > 0 then
          meant.respelled = again
          return meant, ""
        end
      end
    end
    if #found == 0 then
      local near, near_trouble = across(view,
        function(db: Sqlite.Handle, public: boolean): {Entry}?, string
          return closest(db, public, query)
        end, entry_module)
      if near == nil then
        return nil, near_trouble
      end
      local nearest: mut {Entry} = {}
      for position, entry in ipairs(near) do
        if position > CLOSEST then break end
        nearest[position] = entry
      end
      local counted, count_trouble = effective_counts(view, nearest)
      if not counted then
        return nil, count_trouble
      end
      return lookup(nearest, false, 0, #nearest > 0), ""
    end
  end
  local counted, count_trouble = effective_counts(view, found)
  if not counted then
    return nil, count_trouble
  end
  return lookup(found, false, 0), ""
end

return Resolve
