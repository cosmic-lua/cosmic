--- The page of an entry: its heading, its type's source, the members it lists and those it inherits of [`cosmic.doc`]. Use [`cosmic.doc`]; apart from it only to keep that module smaller.

local Sqlite = require("cosmic.sqlite")
local String = require("cosmic.string")
local alias_members = require("cosmic.internal.alias_members")
local link_text = require("cosmic.internal.link_text")
local symbols = require("cosmic.internal.symbols")
local Types = require("cosmic.doc.types")
local Examples = require("cosmic.doc.examples")
local Search = require("cosmic.doc.search")
local Usage = require("cosmic.doc.usage")
local type View = Types.View
local type Example = Types.Example
local type Entry = Types.Entry
local EXAMPLES_SHOWN = Examples.EXAMPLES_SHOWN
local NOTE_LIMIT = Search.NOTE_LIMIT
local across = Usage.across
local clipped = Search.clipped
local columns = Examples.columns
local command_of = Usage.command_of
local declared_in = Search.declared_in
local docs_command = Usage.docs_command
local effective_counts = Usage.effective_counts
local entries_of = Examples.entries_of
local entry_module = Usage.entry_module
local example_of = Search.example_of
local examples_for = Examples.examples_for
local first_sentence = Search.first_sentence
local has_docs = Search.has_docs
local heading = Search.heading
local is_call = Search.is_call
local listed = Search.listed
local members_of = Search.members_of
local ranked_examples = Search.ranked_examples
local shown_source = Examples.shown_source
local text = Examples.text
local used_as = Usage.used_as

local record Pages
  type Entry = Entry
  type View = View
end

--- The declaring record or enum of a member's source symbol:
--- [`Child.Options.fds`] is under [`Child.Options`].
local function parent_of(symbol: string): string
  return symbol:match("^(.*)%.[^.]*$") or ""
end

--- The last name of a dotted `symbol`: all of it when it has no dot.
local function last_name(symbol: string): string
  return (assert(symbol:match("([^.]*)$"), "the pattern [^.]*$ matches the empty text"))
end

--- A record's field, or an enum's value, on one line: as declared, then
--- the first sentence of what it says.
local function member_line(member: Entry, limit?: integer): string
  local note = first_sentence(member.text)
  if limit ~= nil then
    note = clipped(note, limit)
  end
  return member.signature .. (if note ~= "" then " -- " .. note else "" end)
end

--- Whether a module's page names call `a` rather than `b` as the way
--- to a member's own page: one with an example over one without, then
--- the more used.
local function points_better(a: Entry, b: Entry): boolean
  if (a.examples > 0) ~= (b.examples > 0) then
    return a.examples > 0
  end
  return a.uses > b.uses
end

--- The first row `sql` finds in any of `view`'s databases: the databases
--- are read whole, whatever they are public for, because a name a public
--- page hands out (an alias, a base) stands for the record it points at
--- even when that record is not itself a public symbol.
local function first_declared(view: View, sql: string,
                              args: {Sqlite.Value}): Entry?, string
  for _, db in ipairs(view.databases) do
    local documented, documented_trouble = has_docs(db)
    if documented == nil then
      return nil, documented_trouble
    end
    if documented then
      local rows, trouble = db:rows(sql, args)
      if rows == nil then
        return nil, tostring(trouble)
      end
      if #rows > 0 then
        return entries_of(rows)[1], ""
      end
    end
  end
  return nil, ""
end

--- The fields, methods or values declared directly under `target`, as
--- its own module documents them, less any named `_...`: what a type
--- alias or a base record hands to its users.
local function members_under(view: View, target: Entry): {Entry}?, string
  local out: mut {Entry} = {}
  for _, db in ipairs(view.databases) do
    local documented, documented_trouble = has_docs(db)
    if documented == nil then
      return nil, documented_trouble
    end
    if documented then
      local rows, trouble = db:rows(
        "SELECT " .. columns .. " FROM docs d WHERE d.module = ?1 AND " ..
          "((d.kind IN ('field', 'value') AND d.source_symbol GLOB ?2) OR " ..
          "(d.kind = 'method' AND d.source_symbol GLOB ?3)) ORDER BY d.id",
        { text(target.module), text(target.source_symbol .. ".*"), text(target.source_symbol .. ":*") })
      if rows == nil then
        return nil, tostring(trouble)
      end
      for _, member in ipairs(entries_of(rows)) do
        -- A class's method is `Lid:open`; as a member it is `Lid.open`.
        if member.kind == "method" then
          member.source_symbol = member.source_symbol:gsub(":([^:.]*)$", ".%1")
        end
        local name = last_name(member.source_symbol)
        if parent_of(member.source_symbol) == target.source_symbol and
            name:sub(1, 1) ~= "_" then
          out[#out + 1] = member
        end
      end
      if #out > 0 then
        return out, ""
      end
    end
  end
  return out, ""
end

--- The rows of `view` that [`cosmic.internal.alias_members`] follows a
--- declaration through, each read from whichever database holds it.
function Pages.type_source(view: View): alias_members.Source<Entry>
  local types = "(d.kind IN ('record', 'interface', 'enum') OR d.signature GLOB 'type * = *') "
  return {
    declared = function(module: string, name: string): Entry?, string
      return first_declared(view,
        "SELECT " .. columns .. " FROM docs d WHERE d.module = ?1 AND d.source_symbol = ?2 " ..
          "AND " .. types .. "ORDER BY d.id LIMIT 1",
        { text(module), text(name) })
    end,
    exported = function(module: string, name: string): Entry?, string
      return first_declared(view,
        "SELECT " .. columns .. " FROM docs d WHERE d.module = ?1 AND d.symbol = ?2 " ..
          "AND d.exported = 1 AND " .. types .. "ORDER BY d.id LIMIT 1",
        { text(module), text(name) })
    end,
    bound = function(module: string, name: string): string?, string
      local cached = view.bound
      if cached ~= nil then
        return cached[module .. "\n" .. name], ""
      end
      local bound: mut {string: string} = {}
      for _, db in ipairs(view.databases) do
        local ok, trouble = symbols.add_bound(bound, db, "")
        if not ok then
          return nil, trouble
        end
      end
      view.bound = bound
      return bound[module .. "\n" .. name], ""
    end,
    under = function(target: Entry): {Entry}?, string
      return members_under(view, target)
    end,
    as_member = function(owner: Entry, member: Entry, name: string): Entry
      member.module = owner.module
      member.symbol = owner.symbol .. "." .. name
      member.source_symbol = owner.source_symbol .. "." .. name
      member.exported = true
      return member
    end,
  }
end
local type_source = Pages.type_source

--- What a declaration that stands for another type adds to its page:
--- the target's fields (or values), and its methods, each with its
--- documentation. [`Sqlite.Handle`] and [`Child.Options`] are aliases, so
--- they list what their target does; [`Http.GetOptions`] extends one, so it
--- lists what it inherits after its own. Empty for a declaration that
--- stands for nothing.
local function inherited_lines(view: View, entry: Entry): {string}?, string
  local lines: mut {string} = {}
  local references: {string} = {}
  if entry.symbol ~= "" then references = alias_members.references(entry) end
  if #references == 0 then
    return lines, ""
  end
  local own: mut {string: boolean} = {}
  if entry.kind == "record" or entry.kind == "interface" then
    local mine, mine_trouble = members_under(view, entry)
    if mine == nil then
      return nil, mine_trouble
    end
    for _, member in ipairs(mine) do own[last_name(member.source_symbol)] = true end
  end
  local inherited = if (entry.kind == "record" or entry.kind == "interface") then "inherited " else "" end
  local fields: mut {string} = {}
  local methods: mut {string} = {}
  local values: mut {string} = {}
  for _, reference in ipairs(references) do
    local target, target_trouble = alias_members.resolved(type_source(view), entry, reference)
    if target == nil and target_trouble ~= "" then
      return nil, target_trouble
    end
    if target ~= nil and target.source_symbol ~= entry.source_symbol then
      local members, members_trouble = members_under(view, target)
      if members == nil then
        return nil, members_trouble
      end
      local short = last_name(target.source_symbol)
      for _, member in ipairs(members) do
        local name = last_name(member.source_symbol)
        if own[name] ~= true then
          local note = first_sentence(member.text)
          local tail = member.signature:match("^[%w_]+: function%(" .. short .. "(.*)$") or
            member.signature:match("^function [%w_]+%(self(.*)$")
          if member.kind == "value" then
            values[#values + 1] = "    " .. member_line(member)
          elseif tail ~= nil then
            methods[#methods + 1] = "    " .. name .. "(" ..
              (if tail:sub(1, 2) == ", " then tail:sub(3) else tail end) ..
              (if note ~= "" then " -- " .. note else "" end)
          else
            fields[#fields + 1] = "    " .. member_line(member)
          end
        end
      end
    end
  end
  local function emit(title: string, rows: {string})
    if #rows > 0 then
      if #lines > 0 then lines[#lines + 1] = "" end
      lines[#lines + 1] = "  " .. title
      for _, row in ipairs(rows) do lines[#lines + 1] = row end
    end
  end
  emit(inherited .. "values:", values)
  emit(inherited .. "fields:", fields)
  emit(inherited .. "methods:", methods)
  return lines, ""
end

-- Doc.render, its failure in words.
function Pages.render_text(view: View, entry: Entry): {string}?, string
  local first_line = heading(entry)
  local lines: mut {string} = { first_line }
  if entry.kind == "example" then
    local ex = example_of(entry)
    for line in String.lines(ex.text) do
      lines[#lines + 1] = if #line > 0 then "  " .. line else "" end
    end
    for line in String.lines(ex.source) do
      lines[#lines + 1] = if #line > 0 then "    " .. line else "" end
    end
    return lines, ""
  end
  if entry.kind == "removed" then
    -- A name that is gone has no declaration to show, only what its
    -- module's catalog says to write instead.
    return { first_line, "  " .. entry.text }, ""
  end
  if entry.kind == "section" then
    -- A guide's section is its heading and its text, as written.
    lines[#lines + 1] = "  " .. entry.signature
    for line in String.lines(link_text.unlinked(entry.text)) do
      lines[#lines + 1] = if #line > 0 then "  " .. line else "" end
    end
    return lines, ""
  end
  if entry.kind == "code" then
    -- A code has no declaration, only its row: what emits it, its rule, why it holds and the fix.
    local title, rule, why, fix = entry.text:match("^([^\n]*)\nrule: ([^\n]*)\nwhy: ([^\n]*)\nfix: ([^\n]*)$")
    if title == nil or rule == nil or why == nil or fix == nil then
      return { heading(entry), "  " .. entry.text }, ""
    end
    return { heading(entry), "  " .. title, "  rule: " .. rule, "  why: " .. why, "  fix: " .. fix }, ""
  end
  if entry.symbol ~= "" then
    -- `local` says only how the module spelled a declaration it hands
    -- out; a caller reads it as a record like any other.
    lines[#lines + 1] = "  " .. (if entry.exported then (entry.signature:gsub("^local ", "")) else
      entry.signature end)
  end
  if #entry.related > 0 then
    lines[#lines + 1] = "  related search examples:"
    for _, ex in ipairs(entry.related) do
      lines[#lines + 1] = "  example " .. ex.name .. " (" .. ex.file .. ":" ..
        tostring(ex.line) .. "):"
      for line in String.lines(ex.text) do
        lines[#lines + 1] = if #line > 0 then "  " .. line else "" end
      end
      for line in String.lines(ex.source) do
        lines[#lines + 1] = if #line > 0 then "    " .. line else "" end
      end
    end
  end
  -- A module's signatures come right after its opening paragraph, ahead
  -- of the long prose: a reader scanning for a call wants the shapes
  -- first, and the prose that follows explains their shared contract.
  local index: mut {string} = {}
  -- The call a module's page ends by naming, as the way to see any
  -- member's own page: the most used of those with an example, else
  -- the most used. None where the module lists no call, whose first
  -- declaration may be its own record, which stands for the module.
  local pointed: string?
  if entry.symbol == "" then
    local declared, declared_trouble = across(view,
      function(db: Sqlite.Handle, public: boolean): {Entry}?, string
        return declared_in(db, public, entry.module)
      end, entry_module)
    if declared == nil then
      return nil, declared_trouble
    end
    local counted, count_trouble = effective_counts(view, declared)
    if not counted then
      return nil, count_trouble
    end
    local members, members_trouble = across(view,
      function(db: Sqlite.Handle, public: boolean): {Entry}?, string
        return members_of(db, public, entry.module)
      end, entry_module)
    if members == nil then
      return nil, members_trouble
    end
    local under: mut {string: mut {Entry}} = {}
    for _, member in ipairs(members) do
      local parent = parent_of(member.source_symbol)
      local held: mut {Entry} = under[parent] or {}
      under[parent] = held
      held[#held + 1] = member
    end
    -- A call the module's own record declares is listed as a function
    -- already, so it is not a field under that record as well.
    local listed_symbols: mut {string: boolean} = {}
    for _, item in ipairs(declared) do
      listed_symbols[item.symbol] = true
    end
    local best: Entry?
    for _, item in ipairs(declared) do
      if is_call(item) and (best == nil or points_better(item, best)) then best = item end
      if view.program ~= nil then
        item.uses, item.links = 0, 0
      end
      index[#index + 1] = "  " .. listed(item)
      for _, member in ipairs(under[item.source_symbol] or {}) do
        if listed_symbols[member.symbol] ~= true then
          index[#index + 1] = "    " .. member_line(member, NOTE_LIMIT)
        end
      end
    end
    pointed = if best ~= nil then best.source_symbol else nil end
  end
  -- The listing goes after the first paragraph, or, when that ends in
  -- a colon, after the run of indented or fenced blocks it introduces
  -- (an example), or else the next block, so the two stay together.
  local text_lines: mut {string} = {}
  for line in String.lines(link_text.unlinked(entry.text)) do text_lines[#text_lines + 1] = line end
  local function code_at(from: integer): boolean
    for j = from, #text_lines do
      local text_line = text_lines[j]
      if text_line ~= nil and text_line ~= "" then
        return text_line:match("^%s") ~= nil or text_line:sub(1, 3) == "```"
      end
    end
    return false
  end
  local placed = #index == 0
  local last = ""
  local hold = false
  local fence = false
  for at, line in ipairs(text_lines) do
    if line:sub(1, 3) == "```" then fence = not fence end
    if not placed and not fence and line == "" and last ~= "" then
      if last:sub(-1) == ":" then
        hold = true
      elseif not (hold and code_at(at + 1)) then
        lines[#lines + 1] = ""
        for _, row in ipairs(index) do lines[#lines + 1] = row end
        placed = true
      end
    end
    if line ~= "" then last = line end
    lines[#lines + 1] = if #line > 0 then "  " .. line else "" end
  end
  if not placed then
    if entry.text ~= "" then lines[#lines + 1] = "" end
    for _, row in ipairs(index) do lines[#lines + 1] = row end
  end
  if entry.symbol ~= "" and (entry.kind == "record" or entry.kind == "interface" or
      entry.kind == "enum") then
    local members, members_trouble = across(view,
      function(db: Sqlite.Handle, public: boolean): {Entry}?, string
        return members_of(db, public, entry.module)
      end, entry_module)
    if members == nil then
      return nil, members_trouble
    end
    local first = true
    for _, member in ipairs(members) do
      if parent_of(member.source_symbol) == entry.source_symbol then
        if first then
          if lines[#lines] ~= "" then
            lines[#lines + 1] = ""
          end
          lines[#lines + 1] = "  " .. (if entry.kind == "enum" then "values:" else "fields:" end)
          first = false
        end
        lines[#lines + 1] = "    " .. member_line(member)
      end
    end
  end
  local inherited, inherited_trouble = inherited_lines(view, entry)
  if inherited == nil then
    return nil, inherited_trouble
  end
  if #inherited > 0 and lines[#lines] ~= "" then lines[#lines + 1] = "" end
  for _, line in ipairs(inherited) do lines[#lines + 1] = line end
  -- What a command's help says is data ([`cosmic.doc.types.Command`]), not prose: shown under its field in the order its help
  -- shows it, and searched by `by_help` in [`cosmic.doc.resolve`].
  local command = command_of(view, entry)
  if command ~= nil then
    local usage, about, options, examples = command.usage, command.about, command.options, command.examples
    if usage ~= nil and usage ~= "" then
      local prefix = "  usage: "
      for line in String.lines(usage) do
        lines[#lines + 1] = prefix .. line
        prefix = "    "
      end
    end
    if about ~= nil and about ~= "" then
      for line in String.lines(about) do lines[#lines + 1] = "  " .. line end
    end
    if options ~= nil then
      lines[#lines + 1] = "  options:"
      for line in String.lines(options) do
        lines[#lines + 1] = "  " .. line
      end
    end
    if examples ~= nil and examples ~= "" then
      lines[#lines + 1] = "  examples:"
      for line in String.lines(examples) do
        lines[#lines + 1] = "  " .. line
      end
    end
  end
  if entry.links > 0 and entry.symbol == "" then
    lines[#lines + 1] = "  linked from " .. String.counted(entry.links, "place") ..
      "; cosmic uses " .. entry.module
  end
  if pointed ~= nil then
    lines[#lines + 1] = "  a symbol's own page has its whole doc and its examples: " .. docs_command(view) .. " " ..
      pointed
  end
  if entry.symbol ~= "" then
    if entry.uses > 0 or entry.links > 0 then
      local said: mut {string} = {}
      if entry.uses > 0 then
        said[#said + 1] = "used in " .. String.counted(entry.uses, "place")
      end
      if entry.links > 0 then
        said[#said + 1] = (if entry.uses > 0 then "linked from " .. tostring(entry.links) else
          "linked from " .. String.counted(entry.links, "place") end)
      end
      -- A member of the record the module's value is typed as is asked
      -- for by the module's name, which no other module's shares.
      local used, used_trouble = used_as(view, entry)
      if used == nil and used_trouble ~= "" then
        return nil, used_trouble
      end
      lines[#lines + 1] = "  " .. table.concat(said, " and ") .. "; cosmic uses " ..
        (if used ~= nil then entry.module .. "." .. used else entry.source_symbol end)
    end
    local examples, examples_trouble = across(view,
      function(db: Sqlite.Handle, public: boolean): {Example}?, string
        return examples_for(db, public, entry.module, entry.source_symbol)
      end, function(_: Example): string return entry.module end)
    if examples == nil then
      return nil, examples_trouble
    end
    local more: mut {string} = {}
    for at, ex in ipairs(ranked_examples(examples, entry.source_symbol)) do
      if at > EXAMPLES_SHOWN then
        more[#more + 1] = ex.name .. " (" .. ex.file .. ":" .. tostring(ex.line) .. ")"
      else
        lines[#lines + 1] = "  example " .. ex.name .. " (" .. ex.file .. ":" ..
          tostring(ex.line) .. "):"
        for line in String.lines(ex.text) do
          lines[#lines + 1] = if #line > 0 then "  " .. line else "" end
        end
        for line in String.lines(shown_source(ex.source, entry.source_symbol)) do
          lines[#lines + 1] = if #line > 0 then "    " .. line else "" end
        end
      end
    end
    if #more > 0 then
      lines[#lines + 1] = "  " .. String.counted(#more, "more example") .. ": " ..
        table.concat(more, ", ")
    end
  end
  return lines, ""
end

return Pages
