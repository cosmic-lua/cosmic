--- The analysis of a source by the fork's analyzer ([`build.analyzer`], [`build.link_text`]) against the port on the new
--- syntax tree ([`build.syntax_analyzer`], [`build.syntax_link_text`]): the rows of a parse that [`build.derivation`]
--- writes, one list for each, and where the two lists differ. [`build.syntax_compared`] runs it with the other readers
--- on every file.
---
--- A list is compared as the rows are read, except where the translation ([`lang.translate`]) changes what the
--- source says. The port reads the translated text, so a signature or an example is the source as the new grammar
--- writes it: `T | nil` is `T?`, a method is a member of its class with `self`, a `metamethod` is a field named `__x`.
--- Those are compared by the words they hold, set apart `nil`, `mut`, `self`, `metamethod`, and a class read as a
--- record; where the translation made a class, the lines of the translation are not the source's, so the rows are
--- compared sorted and without a line.
-- TODO: cut the cost of the analysis rows of `read` (about 75 s of 210 s cold) before the next readers are added to
-- it: read the fork's rows from the working database, where the live build has already written them by source hash,
-- in place of calling the fork's analyzer again, and key the memo of the fork's half by the fork's modules alone, so
-- that an edit to a port does not run the fork's readers on every file again (doc/plans/strict-teal.md, "the switch").
-- TODO: delete this module with [`build.syntax_compared`] and the fork's analyzer and link_text at the switch, when the tree
-- is written in the new grammar and nothing is translated on read (doc/plans/strict-teal.md, "the switch").
local Analyzer = require("build.syntax_analyzer")
local Ast = require("lang.ast")
local LinkText = require("build.link_text")
local PolicyRules = require("build.policy_rules")
local Scopes = require("lang.scopes")
local SyntaxLinkText = require("build.syntax_link_text")
local analyzer = require("build.analyzer")
local ast = require("build.ast")
local link_text = require("build.link_text")
local type compiler = require("build.compiler")

local record CompareAnalysis
  --- What the comparison of one file found: each difference a line that names the reader and says how, and how many
  --- rows each dimension compared (the rows of both lists, when they are equal).
  record Differences
    differences: {string}
    counts: {string: integer}
  end

  --- The readers a file is compared in, in the order [`CompareAnalysis.file`] names them.
  dimensions: {string}

  --- The analysis of `source` (the fork's Teal, the text of `parsed`, a file named `file`) against that of `text`, its
  --- translation, `chunk` the tree and `scoped` the names of it. `moved` says the translation made a class, which
  --- moves lines.
  file: function(built: compiler, file: string, source: string, parsed: ast.Parsed, text: string, chunk: Ast.Chunk,
                 scoped: Scopes.Scoped, moved: boolean): Differences
end

CompareAnalysis.dimensions = { "analyzer tests", "analyzer export", "analyzer inputs", "analyzer catalog",
  "analyzer docs", "analyzer references", "analyzer bound", "analyzer examples", "link_text" }

--- The words the translation changes, set apart. The head of a method has no owner (it is a member of its class) and
--- its `self`.
local APART <const>: {string: boolean} = { ["nil"] = true, mut = true, self = true, metamethod = true, type = true }

--- The words that move with the code the translation writes in another form: a ternary `a and b or c` is an `if`
--- expression.
local CODE <const>: {string: boolean} = { ["and"] = true, ["or"] = true, ["if"] = true, ["then"] = true,
  ["else"] = true, ["end"] = true }

--- The tokens of `text` in order, as one string: its words (set apart the ones the translation changes, a class as a
--- record; with `code`, those of code as well) and the marks of a type (`{ } ? : ,`). The translation writes `T | nil`
--- as `T?`, a type declaration `local type R = record` as `local record R` and a parameter of a function type that had
--- no name as `argN: T`; each is folded to the form the fork's source has, and nothing else is: the order of the
--- parameters, an optional mark, a list or a map and a lost `:` or `,` are what a reader of the signature sees.
local function words(text: string, owner?: string, code?: boolean): string
  local folded = (text:gsub("%s*|%s*nil%f[%W]", "?"))
  folded = (folded:gsub("^local%s+type%s+([%w_]+)%s*=%s*(%a+)%f[%W]", function(name: string, what: string): string
    if what == "record" or what == "enum" or what == "interface" then
      return "local " .. what .. " " .. name
    end
    return "local type " .. name .. " = " .. what
  end))
  folded = (folded:gsub("%f[%w_]arg%d+(%??)%s*:%s*", "%1"))
  -- The first parameter of a function type that had none, or of a method, is `self`; a rest parameter `...: T` the fork writes `T...`.
  folded = (folded:gsub("%f[%w_]self%s*[,:]%s*", ""):gsub("%.%.%.%s*:%s*", ""))
  if owner ~= nil then
    -- The head of a method has no owner: `function R:m()` is a member `m` of its class.
    folded = (folded:gsub("%f[%w_]" .. owner:gsub("%p", "%%%0") .. "%s*[:.]%s*", " "))
  end
  folded = (folded:gsub("[^%w_{}?:,]+", " "):gsub("([{}?:,])", " %1 "))
  local out: {string} = {}
  local owned: {string: boolean} = {}
  for part in (owner or ""):gmatch("[%w_]+") do
    owned[part] = true
  end
  for word in folded:gmatch("%S+") do
    if APART[word] == nil and owned[word] == nil and not (code == true and CODE[word] == true) then
      out[#out + 1] = word == "class" and "record" or word
    end
  end
  return table.concat(out, " ")
end

local SEPARATOR <const> = "\1"

local function row(...: string): string
  return table.concat({ ... }, SEPARATOR)
end

local function listed(list: {string}): string
  return table.concat(list, ",")
end

local function flag(value: boolean): string
  if value then
    return "1"
  end
  return "0"
end

--- `yes` where `condition` holds, else `no`.
local function choose(condition: boolean, yes: string, no: string): string
  if condition then
    return yes
  end
  return no
end

--- The first place two lists of rows differ, for a message.
local function first_difference(a: {string}, b: {string}): string
  for i = 1, math.max(#a, #b) do
    if a[i] ~= b[i] then
      local function shown(each: string | nil): string
        if each == nil then
          return "nothing"
        end
        return "`" .. each:gsub(SEPARATOR, "|"):gsub("\n", "\\n") .. "`"
      end
      return "row " .. tostring(i) .. " (of " .. tostring(#a) .. " against " .. tostring(#b) .. "): " .. shown(a[i]) .. " against " .. shown(b[i])
    end
  end
  return ""
end

--- A policy declaration as a row, its line left out where `placed` is false.
local function inputs_row(declared: PolicyRules.Declared | nil, placed: boolean): string
  if declared == nil then
    return "none"
  end
  return row(choose(placed, tostring(declared.line), ""), listed(declared.reads), listed(declared.host),
    listed(declared.env), listed(declared.network), flag(declared.tool), flag(declared.lua), flag(declared.nests),
    flag(declared.noexec), flag(declared.store), flag(declared.system), listed(declared.caches),
    listed(declared.parent or {}), listed(declared.requires))
end

--- A refusal with the place it names left out where `placed` is false: `file:LINE: test.policy: ...`.
local function refusal(why: string, placed: boolean): string
  if placed then
    return why
  end
  return (why:gsub("^([^:]*):%d+:", "%1:"))
end

--- The fork's analysis as the port's record, field for field.
local function as_port(found: analyzer.Analysis): Analyzer.Analysis
  local catalog: {Analyzer.CatalogEntry} = {}
  for _, each in ipairs(found.catalog) do
    catalog[#catalog + 1] = { symbol = each.symbol, message = each.message, line = each.line }
  end
  local docs: {Analyzer.DocEntry} = {}
  for _, each in ipairs(found.docs) do
    docs[#docs + 1] = { symbol = each.symbol, source_symbol = each.source_symbol, exported = each.exported,
      kind = each.kind, signature = each.signature, text = each.text, line = each.line }
  end
  local examples: {Analyzer.ExampleEntry} = {}
  for _, each in ipairs(found.examples) do
    examples[#examples + 1] = { name = each.name, text = each.text, source = each.source, line = each.line }
  end
  local references: {Analyzer.Reference} = {}
  for _, each in ipairs(found.references) do
    references[#references + 1] = { module = each.module, member = each.member, line = each.line }
  end
  local bound: {Analyzer.Bound} = {}
  for _, each in ipairs(found.bound) do
    bound[#bound + 1] = { name = each.name, module = each.module }
  end
  return { tests = found.tests, inputs = found.inputs, has_top_level_return = found.has_top_level_return,
    export = found.export, catalog = catalog, docs = docs, examples = examples, references = references,
    bound = bound }
end

--- `docs` less the field rows a class has no use for: where the fork's source declares `read: function(self: R)` in a
--- record and `function R:read()` outside it, the translation makes the one method `read` of a class, which takes the
--- field's doc comment above the function's own. The fork's rows are those of the method, with that text.
local function as_class(docs: {Analyzer.DocEntry}): {Analyzer.DocEntry}
  local fields: {string: Analyzer.DocEntry} = {}
  local methods: {string: boolean} = {}
  for _, entry in ipairs(docs) do
    if entry.kind == "field" then
      fields[entry.source_symbol] = entry
    elseif entry.kind == "method" then
      methods[(entry.source_symbol:gsub(":", "."))] = true
    end
  end
  local out: {Analyzer.DocEntry} = {}
  for _, entry in ipairs(docs) do
    local key = (entry.source_symbol:gsub(":", "."))
    local field = fields[key]
    if entry.kind == "field" and methods[entry.source_symbol] == true then
      -- The method takes its place.
    elseif entry.kind == "method" and field ~= nil then
      local text = entry.text
      if text == "" then
        text = field.text
      elseif field.text ~= "" then
        text = field.text .. "\n" .. text
      end
      out[#out + 1] = { symbol = entry.symbol, source_symbol = entry.source_symbol, exported = entry.exported,
        kind = entry.kind, signature = entry.signature, text = text, line = entry.line }
    else
      out[#out + 1] = entry
    end
  end
  return out
end

--- `docs` less the metamethods that `held` has none of: a metatable's `__close = function(self)` is a method of the
--- class the translation makes, which the fork's reader does not see in a table.
local function without_made_metamethods(docs: {Analyzer.DocEntry}, held: {Analyzer.DocEntry}): {Analyzer.DocEntry}
  local known: {string: boolean} = {}
  for _, entry in ipairs(held) do
    if entry.kind == "metamethod" then
      known[entry.source_symbol] = true
    end
  end
  local out: {Analyzer.DocEntry} = {}
  for _, entry in ipairs(docs) do
    if entry.kind ~= "metamethod" or known[entry.source_symbol] == true then
      out[#out + 1] = entry
    end
  end
  return out
end

--- The words of the signature of `entry`: a method's without its owner, a metamethod's none where the translation moved
--- lines (the class it is a method of has no field to compare it with).
local function signature_words(entry: Analyzer.DocEntry, moved: boolean): string
  if moved and entry.kind == "metamethod" then
    return ""
  end
  local owner: string | nil = nil
  if entry.kind == "method" then
    owner = entry.source_symbol:match("^(.*):")
  end
  return words(entry.signature, owner)
end

--- The rows of an analysis, by dimension; `placed` leaves the lines out where it is false.
local function rows_of(found: Analyzer.Analysis, docs_of: {Analyzer.DocEntry}, placed: boolean, moved: boolean):
    {string: {string}}
  local by: {string: {string}} = {}
  local function line(number: integer): string
    return choose(placed, tostring(number), "")
  end
  by["analyzer tests"] = found.tests
  by["analyzer export"] = { row(found.export, flag(found.has_top_level_return)) }
  by["analyzer inputs"] = { inputs_row(found.inputs, placed) }
  local catalog: {string} = {}
  for _, each in ipairs(found.catalog) do
    catalog[#catalog + 1] = row(each.symbol, each.message, line(each.line))
  end
  by["analyzer catalog"] = catalog
  local docs: {string} = {}
  for _, each in ipairs(docs_of) do
    docs[#docs + 1] = row(each.symbol, each.source_symbol, flag(each.exported), each.kind, each.text,
      line(each.line), signature_words(each, moved))
  end
  by["analyzer docs"] = docs
  local references: {string} = {}
  for _, each in ipairs(found.references) do
    references[#references + 1] = row(each.module, each.member, line(each.line))
  end
  by["analyzer references"] = references
  local bound: {string} = {}
  for _, each in ipairs(found.bound) do
    bound[#bound + 1] = row(each.name, each.module)
  end
  by["analyzer bound"] = bound
  local examples: {string} = {}
  for _, each in ipairs(found.examples) do
    examples[#examples + 1] = row(each.name, each.text, line(each.line),
      choose(placed, words(each.source, nil, true), ""))
  end
  by["analyzer examples"] = examples
  return by
end

--- The lines of `text`.
local function lines_of(text: string): {string}
  local out: {string} = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    out[#out + 1] = line
  end
  return out
end

--- The links of an analysis as rows. A link's column is compared where the line it is on is the same in the source and
--- in the translation.
local function link_rows(found: {LinkText.Found}, placed: boolean, same: {integer: boolean}): {string}
  local out: {string} = {}
  for _, each in ipairs(found) do
    local link = each.link
    out[#out + 1] = row(choose(placed, tostring(link.line), ""),
      choose(placed and same[link.line] == true, tostring(link.column), ""),
      link.form, link.text, link.target, link.label or "", flag(each.doc), flag(each.own), each.alias)
  end
  return out
end

function CompareAnalysis.file(built: compiler, file: string, source: string, parsed: ast.Parsed, text: string,
                              chunk: Ast.Chunk, scoped: Scopes.Scoped, moved: boolean): CompareAnalysis.Differences
  local differences: {string} = {}
  local counts: {string: integer} = {}
  local placed = not moved
  local function compare(dimension: string, old: {string}, new: {string}, counted: boolean)
    if moved then
      table.sort(old)
      table.sort(new)
    end
    if counted and #old == #new then
      counts[dimension] = (counts[dimension] or 0) + #new
    end
    for i = 1, math.max(#old, #new) do
      if old[i] ~= new[i] then
        differences[#differences + 1] = dimension .. ": " .. first_difference(old, new)
        return
      end
    end
  end
  local old_found, old_why = analyzer.analysis_of(built, parsed, source)
  local new_found, new_why = Analyzer.analysis_of(chunk, scoped, text, file)
  if old_found == nil or new_found == nil then
    -- A policy the build cannot read is refused by both, in the words of both.
    if old_found == nil and new_found == nil then
      local old_said, new_said = refusal(old_why, placed), refusal(new_why, placed)
      if old_said ~= new_said then
        differences[#differences + 1] = "analyzer inputs: refused as `" .. old_said .. "` against `" .. new_said .. "`"
      end
      counts["analyzer inputs"] = (counts["analyzer inputs"] or 0) + 1
    else
      differences[#differences + 1] = "analyzer inputs: " .. (old_found == nil and "the fork refuses it: " .. old_why or
        "the port refuses it: " .. new_why)
    end
  else
    local old_port = as_port(old_found)
    local old_docs, new_docs = old_port.docs, new_found.docs
    if moved then
      old_docs = as_class(old_docs)
      new_docs = without_made_metamethods(new_docs, old_docs)
    end
    local old_rows, new_rows = rows_of(old_port, old_docs, placed, moved), rows_of(new_found, new_docs, placed, moved)
    for _, dimension in ipairs(CompareAnalysis.dimensions) do
      if dimension ~= "link_text" then
        -- A file has an export and a policy row whether or not it has an export or a policy; only a row that says
        -- something is counted, so that a reader that found none would leave the dimension empty.
        local says = true
        if dimension == "analyzer export" then
          says = new_found.export ~= ""
        elseif dimension == "analyzer inputs" then
          says = new_found.inputs ~= nil
        end
        compare(dimension, old_rows[dimension], new_rows[dimension], says)
      end
    end
  end
  -- The links of the comments, by line where the lines are the source's.
  local old_lines, new_lines = lines_of(source), lines_of(text)
  local same: {integer: boolean} = {}
  for y, line in ipairs(old_lines) do
    same[y] = new_lines[y] == line
  end
  compare("link_text", link_rows(link_text.found(built, parsed.node, source, file), placed, same),
    link_rows(SyntaxLinkText.found(chunk, scoped, text), placed, same), true)
  return { differences = differences, counts = counts }
end

return CompareAnalysis
