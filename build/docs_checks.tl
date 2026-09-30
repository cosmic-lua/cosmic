--- The checks over what `cosmic docs` shows a user, which
--- [`build.tree_checks`] runs beside its own: the pages a release binary
--- renders (`rendered`), and the names those pages and the guides and
--- help texts refer to (`references`).
---
--- Both read the tree's projection, `o/cosmic.db`, through
--- [`build.docs`]'s own view marked as a public source: the view a
--- project sees of the binary it builds with, so a page here is the
--- page a user gets, made by the code that makes it.

local Cli = require("cosmic.cli")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local String = require("cosmic.string")
local docs = require("build.docs")
local symbols = require("build.symbols")
local writer = require("build.writer")

local record docs_checks
  --- What `rendered` lets stand, each with its reason.
  record Exempt
    --- Public members without a doc comment, by `<module>.<symbol>`.
    undocumented: {string: string}
    --- Records a module returns that no public signature names, by
    --- `<module>.<record>`.
    surfaces: {string: string}
  end
end

--- The database a release binary carries of the projection at `whole`
--- ([`build.writer`]'s `carried`): the only rows a public source has,
--- read without a query of the rest. Made at `scratch`, opened, and
--- unlinked, so nothing is left behind.
function docs_checks.carried(whole: string, scratch: string): Sqlite.Handle | nil, string
  local made, made_trouble = writer.carried(whole, scratch)
  if not made then
    return nil, made_trouble
  end
  local db, open_trouble = Sqlite.open(scratch, false)
  local removed, remove_trouble = Fs.remove(scratch)
  if db == nil then
    return nil, open_trouble
  end
  if not removed then
    local _, _ = db:close()
    return nil, remove_trouble
  end
  return db
end

--- The kinds whose page lists other symbols, which only the renderer
--- knows how to list.
local containers: {string: boolean} = {
  record = true, interface = true, enum = true, type = true,
}

--- The records a module returns whose members are not named for it, so
--- the page cannot tell them from a `local` type of the module's own,
--- by `<module>.<record>`, and why each is shown. None today: a module
--- whose value is typed by such a record says so in its own row's
--- signature (`local module: Module`), which names it.
local surfaces: {string: string} = {}

--- The backticked `cosmic docs <query>` and `Module.symbol` references
--- that name nothing, by the text between the backticks, and why each
--- is fine.
local unresolved: {string: string} = {}

unresolved["cosmic docs Tally.words"] = "the project guide's own module, which its " ..
  "reader has just written"

--- The public members left without a doc comment, by
--- `<module>.<symbol>` as `cosmic docs` names them, and why each is
--- fine or what it waits on.
local undocumented: {string: string} = {}

--- Where an internal path (`cosmic/internal/`, `build/`, `core/`) or a
--- module name of the build (`cosmic.internal.`) shows in a rendered
--- page's text, as a Lua pattern for what precedes it.
local boundary = "[^%w_/%.]"

local internal_paths: {string} = { "cosmic/internal/", "build/", "core/", "cosmic%.internal%." }

--- Whether `line` names an internal path outside a code sample.
local function internal_in(line: string): string | nil
  local padded = " " .. line
  for _, pattern in ipairs(internal_paths) do
    local from = padded:find(boundary .. pattern)
    if from ~= nil then
      return (padded:match(boundary .. "(" .. pattern .. "[%w_/%.]*)", from))
    end
  end
  return nil
end

--- The lines of a rendered page that are prose or listing, not the
--- location line (the first, `cosmic.fs Fs.read (cosmic/fs.tl:37)`,
--- which names the file on purpose) and not an example's source, which
--- is a worked program and may say what it likes.
local function shown_prose(lines: {string}): {string}
  local out: {string} = {}
  local source = false
  local example = false
  for at, line in ipairs(lines) do
    if at > 1 then
      if line:match("^  example ") ~= nil then
        example = true
        source = false
        out[#out + 1] = line
      elseif example and line:sub(1, 4) == "    " then
        source = true
      elseif line:match("^  %S") ~= nil then
        example = false
        source = false
        out[#out + 1] = line
      elseif not source then
        out[#out + 1] = line
      end
    end
  end
  return out
end

--- Whether a rendered line lists a member whose name a module keeps to
--- itself: a field, value or function written `_name`.
local function private_member(line: string): boolean
  return line:match("^%s+_[^_][%w_]*%??:") ~= nil or
    line:match("^%s+function [%w_%.]*[%.:]_[^_][%w_]*%(") ~= nil or
    line:match("^%s+function _[^_][%w_]*%(") ~= nil or
    line:match("^%s+_[^_][%w_]*%(") ~= nil
end

--- What the projection `db`, read as a public source, renders wrongly.
--- Every public module and every record, enum, interface, type and
--- function is looked up as `cosmic docs <name>` would and, for a
--- module or a type, rendered; a field or an enum value is judged by
--- its row and by the page of the type that lists it.
---
--- - Every name the index lists resolves to a page, and so does every
---   name a type's page lists under a type it stands for
---   ([`Child.Options.fds`], [`Sqlite.Handle.exec`]).
--- - No `local` type is shown that no public signature names (a
---   record the module returns is named by its members instead), and no
---   `_`-named member is listed.
--- - No `--` in a signature, where a comment inside a function body
---   would surface.
--- - Every public function, and every field of a public record, has a
---   doc comment; `exempt.undocumented` names the ones left out and
---   why, and one now documented is reported as stale.
--- - No internal path (`cosmic/internal/`, `build/`, `core/`) in the
---   prose, a note under an inherited member included. The first line
---   of a page, which locates the declaration in its file, is not
---   prose, and an example's source is a program of its own. A member
---   inherited from a `cosmic.internal` type is shown without a
---   location, so no internal file is named for one.
--- @param exempt what to let stand; defaults to the tree's own
function docs_checks.rendered(db: Sqlite.Handle, exempt?: docs_checks.Exempt): {string}
  local excused = exempt and exempt.undocumented or undocumented
  local kept = exempt and exempt.surfaces or surfaces
  local out: {string} = {}
  local view, view_trouble = docs.view({ db }, { true })
  if view == nil then
    return { "reading the view: " .. view_trouble }
  end
  local index, index_trouble = docs.index(view)
  if index == nil then
    return { "reading the index: " .. index_trouble }
  end
  local modules: {docs.Summary} = index
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT d.module, d.symbol, d.source_symbol, d.kind, d.signature, d.text, d.file, d.line " ..
    "FROM docs d WHERE d.module GLOB 'cosmic.*' AND d.module NOT LIKE '%\\_example' ESCAPE '\\' " ..
    "AND " .. symbols.shown_docs("d", true) .. " ORDER BY d.module, d.id")
  if rows == nil then
    return { "reading the docs: " .. trouble }
  end
  local shown: {{string}} = rows

  -- Several modules declare `Entry.path`, so one lookup answers each.
  local looked: {string: docs.Lookup} = {}
  local function lookup(name: string): docs.Lookup | nil
    local found = looked[name]
    if found == nil then
      local fresh, found_trouble = docs.lookup(view, name)
      if fresh == nil then
        out[#out + 1] = name .. ": " .. found_trouble
        return nil
      end
      looked[name] = fresh
      found = fresh
    end
    return found
  end

  -- The page of a container: its rendered lines, held to what a reader
  -- may see, and each name it lists under a type it stands for.
  local function inspect(label: string, entry: docs.Entry)
    local lines, render_trouble = docs.render(view, entry)
    if lines == nil then
      out[#out + 1] = label .. ": " .. render_trouble
      return
    end
    for _, line in ipairs(lines) do
      if private_member(line) then
        out[#out + 1] = label .. ": lists a member the module keeps to itself: " ..
          line:match("^%s*(.-)%s*$")
      end
    end
    for _, line in ipairs(shown_prose(lines)) do
      local path = internal_in(line)
      if path ~= nil then
        out[#out + 1] = label .. ": names " .. path .. " in its prose"
        break
      end
    end
    -- What a type stands for lists its target's members, each of which
    -- has to answer as `Type.member`.
    local alias = entry.signature:match("^type ") ~= nil
    local inherited = false
    for _, line in ipairs(lines) do
      local title = line:match("^  ([%a ]+):$")
      if title ~= nil then
        inherited = title:match("^inherited ") ~= nil or title == "methods" or
          (alias and title ~= "options")
      elseif line:match("^  %S") ~= nil then
        inherited = false
      elseif inherited and line:match("^    [%a_]") ~= nil then
        local name = line:match("^    ([%w_]+)")
        local asked = entry.source_symbol .. "." .. name
        local reached = lookup(asked)
        local found = false
        for _, item in ipairs(reached or {}) do
          if item.module == entry.module and item.source_symbol == asked then
            found = true
          end
        end
        if reached ~= nil and not (found and reached.exact) then
          out[#out + 1] = label .. ": lists `" .. name .. "`, but `cosmic docs " ..
            asked .. "` does not answer with it"
        end
      end
    end
  end

  -- A module's page and the index's line for it.
  for _, summary in ipairs(modules) do
    local found = lookup(summary.module)
    if found ~= nil and (#found == 0 or not found.exact) then
      out[#out + 1] = "the index lists " .. summary.module .. ", but `cosmic docs " ..
        summary.module .. "` does not resolve it"
    end
    if found ~= nil and symbols.is_public_module(summary.module) then
      local answered = false
      for _, entry in ipairs(found) do
        if entry.module == summary.module and entry.symbol == "" then
          answered = true
          inspect(summary.module, entry)
        end
      end
      if not answered then
        out[#out + 1] = summary.module .. ": `cosmic docs " .. summary.module ..
          "` does not answer with its page"
      end
    end
  end

  -- A `local` type is shown only where a public signature names it, or
  -- as the record the module returns, whose members are named for it
  -- ([`Fs.read`] is `read`). Nothing else of a module's own is a reader's.
  local signatures: {string: {string}} = {}
  local canonical: {string: boolean} = {}
  for _, row in ipairs(shown) do
    local module, symbol, source_symbol, signature = row[1], row[2], row[3], row[5]
    signatures[module] = signatures[module] or {}
    table.insert(signatures[module], " " .. signature .. " ")
    if symbol ~= source_symbol then
      canonical[module .. "\n" .. source_symbol:match("^[^.:]*")] = true
    end
  end

  local used: {string: boolean} = {}
  local kept_used: {string: boolean} = {}
  for _, row in ipairs(shown) do
    local module, symbol, source_symbol, kind, signature, text =
      row[1], row[2], row[3], row[4], row[5], row[6]
    local key = module .. "." .. source_symbol
    local where = row[7] .. ":" .. row[8] .. ": " .. key
    if symbol ~= "" then
      if signature:gsub("^local ", ""):find("--", 1, true) ~= nil then
        out[#out + 1] = where .. ": the signature has a comment in it: " ..
          signature:gsub("%s+", " ")
      end
      if source_symbol:find("[.:]_[^_]") ~= nil or source_symbol:find("^_[^_]") ~= nil then
        out[#out + 1] = where .. ": a member the module keeps to itself is shown"
      end
      for line in String.lines(text) do
        local path = internal_in(line)
        if path ~= nil then
          out[#out + 1] = where .. ": names " .. path .. " in its prose"
          break
        end
      end
      -- A function or a container has a page of its own to reach.
      if kind == "function" or kind == "method" or containers[kind] then
        local found = lookup(source_symbol)
        local answer: docs.Entry | nil = nil
        for _, entry in ipairs(found or {}) do
          if entry.module == module and entry.source_symbol == source_symbol then
            answer = entry
          end
        end
        if found ~= nil and answer == nil then
          out[#out + 1] = where .. ": `cosmic docs " .. source_symbol .. "` does not answer with it"
        elseif answer ~= nil and containers[kind] then
          inspect(module .. " " .. source_symbol, answer)
        end
      end
      if signature:sub(1, 6) == "local " and source_symbol:find("[.:]") == nil and
          containers[kind] and not canonical[module .. "\n" .. source_symbol] then
        local named = false
        for _, other in ipairs(signatures[module]) do
          if other:find("[^.%w_]" .. source_symbol .. "[^%w_]") ~= nil and
              other ~= " " .. signature .. " " then
            named = true
            break
          end
        end
        if not named then
          if kept[key] ~= nil then
            kept_used[key] = true
          else
            out[#out + 1] = where .. ": a `local` " .. kind ..
              " that no public signature names is shown"
          end
        end
      end
      -- `type Result = Result` re-exports a type: the type's own docs are its.
      local under = source_symbol:match("^(.*)%.[^.]*$")
      local is_field = kind == "field" and under ~= nil and signature:sub(1, 5) ~= "type "
      if (kind == "function" or kind == "method" or is_field) and text:match("%S") == nil then
        if excused[key] ~= nil then
          used[key] = true
        else
          out[#out + 1] = where .. ": no doc comment (write one, or name it in " ..
            "`undocumented` with the reason)"
        end
      end
    end
  end
  for key, reason in pairs(excused) do
    if not used[key] then
      out[#out + 1] = key .. ": excused (" .. reason .. "), but it is documented or gone"
    end
  end
  for key, reason in pairs(kept) do
    if not kept_used[key] then
      out[#out + 1] = key .. ": kept as a surface (" .. reason .. "), but it is gone"
    end
  end
  table.sort(out)
  return out
end

--- Every backticked span of `text` outside a fenced block, with its
--- line breaks read as spaces: a doc comment wraps where it likes.
local function spans(text: string): {string}
  local out: {string} = {}
  local prose = (text:gsub("```.-```", " "):gsub("%s+", " "))
  for span in prose:gmatch("`([^`]+)`") do
    out[#out + 1] = span
  end
  return out
end

--- Whether `word` stands for something the reader fills in
--- (`<module>`, `[verb]`, `...`, an option): no name to resolve.
local function placeholder(word: string): boolean
  return word:find("[<>%[%]]") ~= nil or word:find("...", 1, true) ~= nil or
    word:sub(1, 1) == "-"
end

--- What the projection `db` and the texts `help` name, that names
--- nothing: a backticked `cosmic docs <q>` whose query finds no page, a
--- `cosmic help <verb>` naming no verb, and a `Module.symbol` ([`Fs.read`])
--- of a public module that resolves to no symbol. Read in a public
--- module's docs (its own and its symbols'), in each user guide, and in
--- every text `cosmic help` prints.
--- @param help what `cosmic help` prints, by what asks for it (see
---   [`build.help_source`]' `texts`); none by default
--- @param verbs the words `cosmic help <verb>` takes; defaults to the
---   tree's own
--- @param allowed the references left dangling on purpose, by the text
---   between the backticks, with the reason; defaults to the tree's own,
---   and one that now resolves is reported as stale
function docs_checks.references(db: Sqlite.Handle, help?: {string: string},
                                verbs?: {string}, allowed?: {string: string}): {string}
  help = help or {}
  local dangling = allowed or unresolved
  local danglers: {string: boolean} = {}
  local known: {string: boolean} = { exit = true }
  for _, verb in ipairs(verbs or Cli.order) do known[verb] = true end
  local view, view_trouble = docs.view({ db }, { true })
  if view == nil then
    return { "reading the view: " .. view_trouble }
  end
  local index, index_trouble = docs.index(view)
  if index == nil then
    return { "reading the index: " .. index_trouble }
  end
  -- The record a public module returns is its last name, capitalized:
  -- `Fs` for [`cosmic.fs`].
  local records: {string: boolean} = {}
  for _, summary in ipairs(index) do
    if symbols.is_public_module(summary.module) then
      local last = summary.module:match("[^.]+$")
      records[last:sub(1, 1):upper() .. last:sub(2)] = true
    end
  end
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT d.module, d.symbol, d.text, d.file, d.line FROM docs d WHERE " ..
    "d.module NOT LIKE '%\\_example' ESCAPE '\\' AND d.text <> '' AND " ..
    symbols.shown_docs("d", true) .. " ORDER BY d.module, d.id")
  if rows == nil then
    return { "reading the docs: " .. trouble }
  end
  local texts: {{string}} = rows

  local out: {string} = {}
  local answered: {string: boolean} = {}
  local function resolves(query: string): boolean
    local cached = answered[query]
    if cached == nil then
      local found, _ = docs.lookup(view, query)
      cached = found ~= nil and #found > 0 and (found.exact or query:find(" ", 1, true) ~= nil)
      answered[query] = cached
    end
    return cached
  end
  local function check(where: string, text: string)
    for _, span in ipairs(spans(text)) do
      local problem: string | nil = nil
      local query = span:match("^cosmic docs (.+)$")
      local verb = span:match("^cosmic help (%S+)$")
      if query ~= nil then
        query = query:gsub("^([\"'])(.*)%1$", "%2")
        if not placeholder(query) and not resolves(query) then
          problem = "finds nothing"
        end
      elseif verb ~= nil then
        if not placeholder(verb) and not known[verb] then
          problem = "names no verb"
        end
      else
        local chain = span:match("^(%u[%w]*[%.:][%w_%.:]*[%w_])")
        if chain ~= nil and records[chain:match("^[%w]+")] and
            (#chain == #span or span:sub(#chain + 1, #chain + 1):match("[%s(]") ~= nil) then
          chain = chain:gsub(":", ".")
          if not resolves(chain) then
            problem = "names no symbol"
          end
        end
      end
      if problem ~= nil then
        if dangling[span] ~= nil then
          danglers[span] = true
        else
          out[#out + 1] = where .. ": `" .. span .. "` " .. problem
        end
      end
    end
  end
  for _, row in ipairs(texts) do
    check(row[4] .. ":" .. row[5] .. ": " .. row[1] ..
      (row[2] ~= "" and " " .. row[2] or ""), row[3])
  end
  for name, text in pairs(help) do
    check("`cosmic help" .. (name ~= "" and " " .. name or "") .. "`", text)
  end
  for span, reason in pairs(dangling) do
    if not danglers[span] then
      out[#out + 1] = "`" .. span .. "` is allowed to dangle (" .. reason ..
        "), but it resolves or is gone"
    end
  end
  table.sort(out)
  return out
end

return docs_checks
