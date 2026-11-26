--- The checks of the tree over its docs: every type an API names a member of its module, no two doc anchors sharing
--- a name, every docs query a compile advertises answered, every verb's spec listed and readable, no public doc citing
--- the build or carrying a TODO, and no literal plural after a number.

local Sqlite = require("cosmic.sqlite")
local docs = require("build.docs")
local Doc = require("cosmic.doc")
local ErrorRender = require("build.error_render")
local link_text = require("cosmic.internal.link_text")
local Ast = require("lang.ast")
local PluralSites = require("build.plural_sites")
local SyntaxNode = require("build.syntax_node")
local symbols = require("cosmic.internal.symbols")
local String = require("cosmic.string")
local _ = require("build.reads.all")
local tree_common = require("build.tree_checks.common")
local type build_schema = require("build.schema")
local type Build = build_schema.Build

local nth = tree_common.nth

local record tree_docs
  --- What [`plurals`] finds in one text of a file, read off a parse made
  --- before the checks ran ([`plurals_in`]).
  record Plurals
    --- The text the sites were found in.
    source: string
    sites: {{string}}
  end
end

--- The name of the record `source` returns, or nil for none: the returned
--- name is the record itself (`return Child`), a record declared beside it
--- (`local module: Module`) or its capitalized form (`return module`).
local function returned_record(source: string): string?
  local returned = source:match("\nreturn ([%w_]+)%s*$")
  if returned == nil then return nil end
  local record = source:match("\nlocal " .. returned .. "%s*:%s*([%w_]+)")
  if record == nil then
    if source:find("\nlocal record " .. returned .. "%f[^%w_]") ~= nil then
      record = returned
    else
      record = returned:sub(1, 1):upper() .. returned:sub(2)
    end
  end
  return record
end

--- The text of the declaration of the record `record` in `source`, or nil
--- where it is not declared there.
local function record_body(source: string, record: string): string?
  local from = source:find("\nlocal record " .. record .. "%f[^%w_]")
  if from == nil then return nil end
  local to = source:find("\nend\n", from, true)
  return source:sub(from, to or #source)
end

--- Whether the returned record `record` (with `body`, its text) has the
--- type `name` as a member: `type Any = Name` or a nested declaration in
--- its body, or an assignment `record.Name = ...` beside it. Where the body
--- cannot be found the whole of `source` stands in for it.
local function member_type(source: string, record: string?, body: string?,
                           name: string): boolean
  for line in (body or source):gmatch("[^\n]+") do
    -- `type View = View`, or `type View = Types.View`: an alias of a sibling's record of that name.
    if line:find("^%s+type [%w_]+%s*=%s*" .. name .. "%f[^%w_]") ~= nil or
        line:find("^%s+type " .. name .. "%s*=%s*[%w_]+%." .. name .. "%f[^%w_]") ~= nil or
        line:find("^%s+record " .. name .. "%f[^%w_]") ~= nil or
        line:find("^%s+enum " .. name .. "%f[^%w_]") ~= nil or
        line:find("^%s+interface " .. name .. "%f[^%w_]") ~= nil then
      return true
    end
  end
  if record ~= nil then
    return source:find("\n" .. record .. "%." .. name .. "%s*=") ~= nil
  end
  return false
end

--- Every type a public `cosmic/` module's API names that the module does
--- not export as `Module.Name`, as `<file>:<line>: <module>: <Name> ...`.
---
--- A caller writes `local stream: integer | Child.Stdout`; a type that
--- the module declares `local` and its record does not re-export is
--- listed by `cosmic docs` and named in a type error, but [`Child.Stdout`]
--- is "unknown type". The types reached are those of the module's own
--- top level (a record, enum, interface or type) that a signature of an
--- exported member names, and then those that a member of such a type
--- names, a method declared outside its record included and a member
--- whose name starts with `_` (private by convention) left out. The returned
--- record itself is no member of itself, and `cosmic/internal/` is not
--- asked.
---
--- A member is found by text, not by resolving the name: `type Any = Name`
--- in the returned record's body, a nested declaration there, or
--- `Record.Name = ...`.
function tree_docs.unnamed_types(db: Build): {string}
  local rows, trouble = db:rows(
    "SELECT d.module, d.symbol, d.kind, d.signature, d.file, d.line, d.exported " ..
      "FROM docs d WHERE d.file GLOB 'cosmic/*.tl' " ..
      "AND d.file NOT GLOB 'cosmic/internal/*' AND d.file NOT GLOB '*_test.tl' " ..
      "AND d.file NOT GLOB '*.d.tl' ORDER BY d.module, d.line")
  if rows == nil then
    return { "reading the docs: " .. tostring(trouble) }
  end
  local sources, why = db:rows(
    "SELECT path, CAST(inflate(source) AS TEXT) FROM modules")
  if sources == nil then
    return { "reading the modules: " .. tostring(why) }
  end
  local text: mut {string:string} = {}
  for _, row in ipairs(sources) do text[row:text(1)] = row:text(2) end
  local by_module: mut {string:Sqlite.Rows} = {}
  local order: mut {string} = {}
  for _, row in ipairs(rows) do
    if by_module[row:text(1)] == nil then
      by_module[row:text(1)] = {}
      order[#order + 1] = row:text(1)
    end
    table.insert(by_module[row:text(1)], row) -- checked: overload_none -- untyped: call
  end
  local out: mut {string} = {}
  for _, module in ipairs(order) do
    local members = assert(by_module[module], "every module of the order has its rows")
    local source = text[module] or ""
    local record = returned_record(source)
    local body = if record ~= nil then record_body(source, record) else nil end
    local tops: mut {string:Sqlite.Row} = {}
    for _, row in ipairs(members) do
      if row:text(2) ~= "" and not row:text(2):find("[.:]") and row:text(2) ~= record and
          (row:text(3) == "record" or row:text(3) == "enum" or row:text(3) == "interface" or
              row:text(3) == "type") then
        tops[row:text(2)] = row
      end
    end
    local reached: mut {string:boolean} = {}
    local pending: mut {string} = {}
    local function names_in(signature: string)
      for name in pairs(tops) do
        if reached[name] ~= true and signature:find("%f[%w_.]" .. name .. "%f[^%w_]") ~= nil then
          reached[name] = true
          pending[#pending + 1] = name
        end
      end
    end
    for _, row in ipairs(members) do
      if row:integer(7) == 1 and row:text(2) ~= "" and not row:text(2):find("[.:]") and
          (row:text(3) == "function" or row:text(3) == "method" or row:text(3) == "field" or
              row:text(3) == "value") then
        names_in(row:text(4))
      end
    end
    while #pending > 0 do
      local name = pending[#pending]
      pending[#pending] = nil
      for _, row in ipairs(members) do
        local head = row:text(2):sub(1, #name + 1)
        if (head == name .. "." or head == name .. ":") and
            row:text(2):sub(#name + 2, #name + 2) ~= "_" and
            (row:text(3) == "function" or row:text(3) == "method" or row:text(3) == "field") then
          names_in(row:text(4))
        end
      end
    end
    local unnamed: mut {string} = {}
    for name in pairs(reached) do
      if not member_type(source, record, body, name) then unnamed[#unnamed + 1] = name end
    end
    table.sort(unnamed)
    for _, name in ipairs(unnamed) do
      local row = assert(tops[name], "a reached name is one of the tops")
      local owner = record or module:match("[^.]+$") or module
      out[#out + 1] = row:text(5) .. ":" .. tostring(row:integer(6)) .. ": " .. module .. ": " .. name ..
        " is named by the API but is no member of the module: add `type " .. name .. " = " ..
        name .. "` to " .. owner .. ", so a caller can write " .. owner .. "." .. name
    end
  end
  return out
end

--- One row of the public catalog, as `anchors` reads it.
local record Row
  module: string
  symbol: string
  kind: string
  signature: string
  text: string
  file: string
  line: string
end

--- Whether `signature` names the type `name` as a whole word.
local function mentions(signature: string, name: string): boolean
  return signature:find("%f[%w_]" .. name .. "%f[^%w_]") ~= nil
end

--- The records the tree's doc anchors are known to be, as
--- `<module> <record>`: each must still be taken for one, so a change
--- to what counts as an anchor cannot leave the check vacuous.
local anchors_expected: {string} = { "cosmic.layout Layout", "cosmic.entrypoint Entrypoint", "cosmic.errno Errno" }

--- Every pair of doc anchors in `db` that share a bare name, as
--- `<file>:<line>: <module> <symbol> and <module> <symbol>: ...`,
--- sorted, and then each of `expected` (by default the tree's own
--- anchors) that is no longer taken for one.
---
--- For a name that resolves to a doc anchor, `cosmic docs <name>`
--- shows that one anchor alone (doc/design.md, principle 8). A bare name
--- matches every symbol ending in it -- `cosmic docs read` lists each
--- `X.read`, by design -- so a real member that shares an anchor's name
--- ([`Proc.Relaunch.argv`] beside [`Entrypoint.argv`]) is listed beside it
--- as any two members are. What is refused is two anchors sharing one:
--- a reader asking for `test` would also be shown the layout
--- rule for test files.
---
--- A doc anchor is a record of a public `cosmic/` module that exists to
--- be looked up, not passed around: every field of it is a documented
--- `string` (`tests: string` in [`cosmic.layout`]'s `Layout`), no function
--- or method in the public catalog takes or returns it, and no field holds it
--- (`examples?: {Example}` in [`cosmic.flags`]'s `Command`). [`cosmic.shape`]'s
--- `Failure` has only strings too, but `failures` hands it out, so its
--- fields are an API's, not anchors.
function tree_docs.anchors(db: Build, expected?: {string}): {string}
  local rows, trouble = db:rows(
    "SELECT module, symbol, kind, signature, text, file, line FROM docs WHERE " ..
      symbols.public_only("module", true) .. " ORDER BY module, id")
  if rows == nil then
    return { "reading the public catalog: " .. tostring(trouble) }
  end
  local all: mut {Row} = {}
  for _, r in ipairs(rows) do
    all[#all + 1] = { module = r:text(1), symbol = r:text(2), kind = r:text(3), signature = r:text(4),
      text = r:text(5), file = r:text(6), line = tostring(r:integer(7)) }
  end
  -- What takes, returns or holds a value: a function, a method, or a field, whose type may be a function or
  -- hold the record (`examples?: {Example}`).
  local callable: mut {string} = {}
  for _, r in ipairs(all) do
    if r.kind == "function" or r.kind == "method" or r.kind == "field" then
      callable[#callable + 1] = r.signature
    end
  end
  local by_name: mut {string: mut {Row}} = {}
  local found: mut {string: boolean} = {}
  for _, owner in ipairs(all) do
    if owner.kind == "record" then
      local prefix = owner.symbol .. "."
      local fields: mut {Row} = {}
      local anchor = true
      for _, r in ipairs(all) do
        if r.module == owner.module and String.starts_with(r.symbol, prefix) and
            r.symbol:find(".", #prefix + 1, true) == nil then
          local name = r.symbol:sub(#prefix + 1)
          fields[#fields + 1] = r
          if r.kind ~= "field" or r.signature ~= name .. ": string" or r.text == "" then
            anchor = false
          end
        end
      end
      for _, signature in ipairs(callable) do
        if mentions(signature, owner.symbol) then anchor = false end
      end
      if anchor then
        found[owner.module .. " " .. owner.symbol] = true
        for _, r in ipairs(fields) do
          local name = r.symbol:sub(#prefix + 1)
          local list = by_name[name] or {}
          list[#list + 1] = r
          by_name[name] = list
        end
      end
    end
  end
  local out: mut {string} = {}
  for name, list in pairs(by_name) do
    for i = 2, #list do
      local first, other = nth(list, 1), nth(list, i)
      out[#out + 1] = string.format(
        "%s:%s: %s %s and %s %s: `cosmic docs %s` answers both -- rename one",
        other.file, other.line, first.module, first.symbol, other.module, other.symbol, name)
    end
  end
  table.sort(out)
  for _, name in ipairs(expected or anchors_expected) do
    if found[name] ~= true then
      out[#out + 1] = name .. " is no longer taken for a doc anchor"
    end
  end
  return out
end

--- The worked examples a reader is pointed to or expected to find by a
--- compile's failure: every one [`build.error_render`] advertises, and the
--- guide to a type's shape, which no hint names but a malformed type's
--- diagnostic leaves its reader to look up.
local function queries_expected(): {string}
  local out: mut {string} = {}
  out[#out + 1] = ErrorRender.queries.arguments
  out[#out + 1] = ErrorRender.queries.record_key
  out[#out + 1] = "enums_arrays_maps_tuples"
  table.sort(out)
  return out
end

--- Each of `wanted` (by default what a compile's failure points to) that
--- `cosmic docs` does not resolve from `db`.
function tree_docs.queries(db: Build, wanted?: {string}): {string}
  local looked, trouble = docs.view({ db }, { true })
  if looked == nil then
    return { "reading the docs: " .. trouble }
  end
  local out: mut {string} = {}
  for _, query in ipairs(wanted or queries_expected()) do
    local found, lookup_trouble = Doc.lookup(looked, query)
    if found == nil then
      out[#out + 1] = "`cosmic docs " .. query .. "`: " .. tostring(lookup_trouble)
    elseif #found == 0 then
      out[#out + 1] = "`cosmic docs " .. query .. "` answers nothing, though a " ..
        "compile's failure points its reader there"
    end
  end
  return out
end

--- A spec table's top-level fields as its source writes them: `name`,
--- `guide` and the like as string literals, `tests` as a list of them.
--- A field of another shape (a variable, a long string, a list with a
--- non-literal in it) is `nonliteral`.
local record Fields
  strings: mut {string:string}
  lists: mut {string:{string}}
  nonliteral: mut {string:boolean}
end

--- The value of the string literal that opens at `at` (a quote) and the
--- index after its closing quote.
local function scan_string(text: string, at: integer): string, integer
  local quote = text:sub(at, at)
  local named: {string:string} = { n = "\n", t = "\t" }
  local out: mut {string} = {}
  local i = at + 1
  while i <= #text do
    local c = text:sub(i, i)
    if c == quote then
      return table.concat(out), i + 1
    elseif c == "\\" then
      local after = text:sub(i + 1, i + 1)
      out[#out + 1] = named[after] or after
      i = i + 2
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out), i
end

--- One token of a spec's source: a string literal (`kind` "str", its
--- `value` unescaped), a long string ("long"), a name ("word") or a mark
--- ("mark"), one character.
local record Token
  kind: string
  value: string
end

--- The tokens of the table that opens at the first `{` of `text` from
--- `start`, through its closing brace. Comments are skipped, and a string's
--- braces and quotes stay its own.
local function tokens_of(text: string, start: integer): {Token}
  local out: mut {Token} = {}
  local i = text:find("{", start, true)
  if i == nil then return out end
  local depth = 0
  while i <= #text do
    local c = text:sub(i, i)
    if text:sub(i, i + 1) == "--" then
      i = text:find("\n", i, true) or #text + 1
    elseif c == "\"" or c == "'" then
      local value, after = scan_string(text, i)
      out[#out + 1] = { kind = "str", value = value }
      i = after
    elseif text:match("^%[=*%[", i) ~= nil then
      local level = assert(text:match("^%[(=*)%[", i), "the branch tested this pattern")
      local close = text:find("]" .. level .. "]", i, true)
      out[#out + 1] = { kind = "long", value = "" }
      i = if close ~= nil then close + #level + 2 else #text + 1 end
    elseif c:match("[%a_]") then
      local word = assert(text:match("^[%w_]+", i), "the branch tested a character this pattern starts with")
      out[#out + 1] = { kind = "word", value = word }
      i = i + #word
    else
      if c == "{" then depth = depth + 1 end
      if c == "}" then depth = depth - 1 end
      if not c:match("%s") then out[#out + 1] = { kind = "mark", value = c } end
      i = i + 1
      if depth == 0 then break end
    end
  end
  return out
end

--- The top-level fields of the spec table that opens after `start` in
--- `text`. The projection holds a table's signature and docs but not its
--- values ([`build.docs`]), so a spec's fields are read from its source, as
--- literals; a first occurrence of a name wins, and a `name = "..."` that
--- a function body inside the table writes at its own top level would be
--- taken for a field (a spec's `run` is one line that calls another
--- function, so none does).
local function spec_fields(text: string, start: integer): Fields
  local fields: Fields = { strings = {}, lists = {}, nonliteral = {} }
  local tokens = tokens_of(text, start)
  local depth = 0
  local i = 1
  while i <= #tokens do
    local token = nth(tokens, i)
    local after, third = tokens[i + 1], tokens[i + 2]
    if token.kind == "mark" and token.value == "{" then
      depth = depth + 1
    elseif token.kind == "mark" and token.value == "}" then
      depth = depth - 1
    elseif depth == 1 and token.kind == "word" and after ~= nil and
        after.value == "=" and after.kind == "mark" and
        third ~= nil and third.value ~= "=" then
      local name, value = token.value, third
      if value.kind == "str" then
        if fields.strings[name] == nil then fields.strings[name] = value.value end
        i = i + 2
      elseif value.kind == "mark" and value.value == "{" then
        local list: mut {string} = {}
        local j = i + 3
        local item = tokens[j]
        while item ~= nil and not (item.kind == "mark" and item.value == "}") do
          if item.kind == "str" then
            list[#list + 1] = item.value
          elseif not (item.kind == "mark" and (item.value == "," or item.value == ";")) then
            fields.nonliteral[name] = true
          end
          j = j + 1
          item = tokens[j]
        end
        if fields.lists[name] == nil then fields.lists[name] = list end
        i = j
      elseif value.kind == "long" or value.kind == "word" then
        fields.nonliteral[name] = true
        i = i + 2
      end
    end
    i = i + 1
  end
  return fields
end

--- Each verb's registration (build/verb_spec.tl) that its module leaves
--- short:
---
--- - a module of `db` that assigns a `spec` but that build/verb_list.tl
---   does not require, so nothing dispatches to it;
--- - a listed verb whose module has no spec assigned as a table literal
---   to `<x>.spec` or `<x>.<y>_spec` at the start of a line, which
---   nothing here could then read;
--- - a `guide` that names no `## ` heading of `quickstart` (the text of
---   doc/guides/quickstart.md) whose section mentions `cosmic <name>`,
---   nor gives a reason ("none: ...");
--- - `tests` that is empty or names a module that is no test of `db`.
---
--- A spec is read from its module's source, where `name`, `guide` and
--- `tests` must be literals ([`spec_fields`]): the listing module cannot be
--- loaded here (it reaches [`build.fix`], which runs this), and the
--- projection holds no table's values, so there is no row to read
--- instead. The limit is decided: a spec built any other way (a local
--- table exported afterward, fields computed) is refused as a listed verb
--- with no spec here, not passed over. `help`, which dispatch assigns to a
--- local and no list holds, is not read. A verb's `Cli` prose is held by
--- build/verbs_store_test.tl, and a bare verb's `passthrough` by
--- build/verb_list_test.tl.
---
--- With no `quickstart` (its file unread, which `fix` has reported), the
--- guides are not held to it.
function tree_docs.verbs(db: Build, quickstart: string?): {string}
  local out: mut {string} = {}
  local required, trouble = db:rows(
    "SELECT requires FROM imports WHERE path = 'build.verb_list'")
  if required == nil then
    return { "reading the imports: " .. tostring(trouble) }
  end
  local listed: mut {string:boolean} = {}
  for _, row in ipairs(required) do listed[row:text(1)] = true end
  local modules, module_trouble = db:rows(
    "SELECT path, kind, CAST(inflate(source) AS TEXT) FROM modules ORDER BY path")
  if modules == nil then
    return { "reading the modules: " .. tostring(module_trouble) }
  end
  local kinds: mut {string:string} = {}
  local texts: mut {string:string} = {}
  for _, row in ipairs(modules) do
    kinds[row:text(1)] = row:text(2)
    texts[row:text(1)] = row:text(3)
  end

  -- Each `## ` heading of the quickstart, outside a fenced block, and the
  -- text of its section.
  local sections: mut {string:string} = {}
  local current: string? = nil
  local fenced = false
  for line in String.lines(quickstart or "") do
    if line:match("^```") then fenced = not fenced end
    local heading = if not fenced then line:match("^## (.+)$") else nil end
    if heading ~= nil then
      current = heading
      sections[heading] = sections[heading] or ""
    elseif current ~= nil then
      sections[current] = (sections[current] or "") .. line .. "\n"
    end
  end

  -- The spec each listed entry loads, `require("<module>").<field>`, so a
  -- listed verb whose spec cannot be read is not passed over.
  local expected: mut {string:{string}} = {}
  for entry_module, field in (texts["build.verb_list"] or ""):gmatch(
      "require%(\"([%w_.]+)\"%)%.([%w_]*spec)") do
    expected[entry_module] = expected[entry_module] or {}
    table.insert(expected[entry_module], field) -- checked: overload_none -- untyped: call
  end
  local found_fields: mut {string:mut {string:boolean}} = {}

  for _, row in ipairs(modules) do
    if row:text(2) ~= "test" then
      local assigned = 0
      local at = 1
      while true do
        local first, last, field = row:text(3):find("\n[%w_]+%.([%w_]*spec) = {", at)
        if first == nil or last == nil or field == nil then break end
        at = last + 1
        if field == "spec" or field:match("^[%w_]*_spec$") ~= nil then
          assigned = assigned + 1
          local own_fields = found_fields[row:text(1)] or {}
          found_fields[row:text(1)] = own_fields
          own_fields[field] = true
          local spec = spec_fields(row:text(3), last)
          local name = spec.strings.name or "?" -- checked: map_field
          if listed[row:text(1)] ~= true then
            out[#out + 1] = "`" .. name .. "` (" .. row:text(1) .. ") assigns a `spec` but " ..
              "build/verb_list.tl does not list its module, so no verb dispatches to it -- " ..
              "list it there"
          end
          local guide = spec.strings.guide -- checked: map_field
          if guide == nil then
            out[#out + 1] = "`" .. name .. "` has no guide as a string literal: name its `## ` " ..
              "heading in doc/guides/quickstart.md, or \"none: <why>\""
          elseif guide:sub(1, 5) == "none:" then -- untyped: call
            if guide:sub(6):match("^%s*$") then -- untyped: call*2
              out[#out + 1] = "`" .. name .. "` has no guide and gives no reason after \"none:\""
            end
          elseif quickstart ~= nil then
            local section = sections[guide]
            if section == nil then
              out[#out + 1] = "`" .. name .. "`'s guide is \"" .. guide .. "\", which is no `## ` " ..
                "heading of doc/guides/quickstart.md -- name one, or \"none: <why>\""
            elseif not section:find("cosmic " .. name, 1, true) then
              out[#out + 1] = "`" .. name .. "`'s guide is \"" .. guide .. "\", whose section " ..
                "never mentions `cosmic " .. name .. "` -- name the section that does, or " ..
                "\"none: <why>\""
            end
          end
          local tests = spec.lists.tests -- checked: map_field
          if tests == nil or #tests == 0 or spec.nonliteral.tests then -- checked: map_field
            out[#out + 1] = "`" .. name .. "` names no test module in `tests`, as string literals"
          end
          for _, test in ipairs(tests or {}) do -- checked: literal_needs_type
            if kinds[test] ~= "test" then
              out[#out + 1] = "`" .. name .. "`'s tests name " .. test ..
                ", which is no test module of the tree"
            end
          end
        end
      end
    end
  end
  local unread: mut {string} = {}
  for entry_module, fields in pairs(expected) do
    for _, field in ipairs(fields) do
      if (found_fields[entry_module] or {})[field] ~= true then
        unread[#unread + 1] = "build/verb_list.tl loads `" .. entry_module .. "`'s `" .. field ..
          "`, but that module assigns no `<x>." .. field .. " = {` table literal at the start " ..
          "of a line, which is how a spec is read here"
      end
    end
  end
  table.sort(unread)
  for _, line in ipairs(unread) do out[#out + 1] = line end
  return out
end

--- The public doc text that may cite an implementation path, by
--- `<module> <symbol> <rule>` (`doc_rules`' name; `(module)` for a
--- module's own doc), and why each stays.
local doc_exempt: mut {string: string} = {}

doc_exempt["cosmic.cli.todos (module) todo"] = "`cosmic todos` lists the tree's " ..
  "`TODO:` comments: the marker is the verb's subject"

--- The rules a public doc is held to: a name, the Lua pattern that
--- finds a candidate, whether the candidate breaks the rule (given the
--- text around it and the tree's module names), and what to do instead.
local record DocRule
  name: string
  pattern: string
  breaks: function(before: string, hit: string, after: string, modules: {string: boolean}): boolean
  fix: string
end

--- The `build.<name>` modules whose name is also a file a reader knows:
--- `build.zig` is zig's build script, not build/zig.tl.
local FILE_NAMES: {string: boolean} = { zig = true }

--- Whether `hit`, a `build.<name>` found in prose, names a module of the
--- tree (or a package under one): [`build.this_program`], not "the build."
local function names_a_module(hit: string, modules: {string: boolean}): boolean
  local name = hit:match("^build%.([%w_.]*[%w_])")
  if name ~= nil and FILE_NAMES[name] == true then return false end
  while name ~= nil and name ~= "" do
    if modules["build." .. name] == true then return true end
    name = name:match("^(.*)%.[^.]*$")
  end
  return false
end

local doc_rules: {DocRule} = {
  { name = "todo", pattern = "TODO:", fix = "move the TODO to a `--` comment where the better fix would go",
    breaks = function(_b: string, _h: string, _a: string, _m: {string: boolean}): boolean
      return true
    end },
  { name = "path", pattern = "%f[%w_]build/", fix = "say what a caller needs, not where the build keeps it",
    breaks = function(_b: string, _h: string, _a: string, _m: {string: boolean}): boolean
      return true
    end },
  { name = "path", pattern = "%f[%w_]build%.[%w_]+[%w_.]*", fix = "say what a caller needs, not which build module does it",
    breaks = function(before: string, hit: string, _a: string, modules: {string: boolean}): boolean
      return before ~= "/" and before ~= "." and names_a_module(hit, modules)
    end },
  { name = "path", pattern = "%f[%w_]core/", fix = "say what a caller needs, not which C file does it",
    breaks = function(_b: string, _h: string, _a: string, _m: {string: boolean}): boolean
      return true
    end },
  { name = "path", pattern = "cosmic%.internal%f[^%w_]",
    fix = "say what a caller needs, not which internal module does it",
    breaks = function(_b: string, _h: string, _a: string, _m: {string: boolean}): boolean
      return true
    end },
  { name = "path", pattern = "cosmic/internal/", fix = "say what a caller needs, not which internal module does it",
    breaks = function(_b: string, _h: string, _a: string, _m: {string: boolean}): boolean
      return true
    end },
  { name = "path", pattern = "%f[%w_]vendor/", fix = "say what a caller needs, not which vendored tree does it",
    breaks = function(_b: string, _h: string, _a: string, _m: {string: boolean}): boolean
      return true
    end },
  -- A C file's name: a word of three letters or more and `.c` or `.h`,
  -- not a system header in angle brackets nor the tail of a dotted name.
  { name = "path", pattern = "%f[%w_][%l_][%l_][%l_]+%.[ch]%f[^%w_]",
    fix = "say what a caller needs, not which C file does it",
    breaks = function(before: string, _h: string, after: string, _m: {string: boolean}): boolean
      return before ~= "<" and before ~= "." and after ~= ">" and after ~= "."
    end },
}

--- Every `---` doc text that a public source shows in `db` (see
--- `symbols.shown_docs`: a public module's, [`core/syscalls.h`]'s, which
--- is [`cosmic.sys`], and the shipped user guides'), and every `--` run
--- adjacent to a declaration, which `cosmic docs` folds into its doc
--- text, that carries a `TODO:` or cites an implementation path, one
--- line per hit as `<file>:<line>: <module> <symbol>: ...` with the
--- fix, and then each name in `excused` (by default `doc_exempt`) that
--- nothing matches any more.
---
--- A doc is what `cosmic docs` shows a caller ([`link_text.unlinked`]:
--- no definition a code span's link reads), in a binary that carries
--- neither the build nor the C. A TODO belongs in a `--` comment set
--- off from the doc by a blank line (doc/writing.md); a path or a `build.`
--- module is a fact about the implementation, which the doc says as
--- what a caller can rely on. The paths refused are `build/`, a
--- `build.<module>` the tree has, `core/`, `cosmic.internal`,
--- `cosmic/internal/`, `vendor/` and a C file's name (`foo.c`, not a
--- header in angle brackets). `build.zig` is a file name, not a module.
--- @param files where given, the files (paths from the tree's root) whose docs are checked, as a run of `cosmic fix` over
---   some paths checks them: no word is said of an exemption, since the files not named may match it
function tree_docs.public_docs(db: Build, excused?: {string: string}, files?: {string: boolean}): {string}
  excused = excused or doc_exempt
  local named = ""
  local values: mut {Sqlite.Value} = {}
  if files ~= nil then
    local marks: mut {string} = {}
    for file in pairs(files) do
      values[#values + 1] = { text = file }
      marks[#marks + 1] = "?"
    end
    named = " AND d.file IN (" .. table.concat(marks, ", ") .. ")"
  end
  local rows, trouble = db:rows(
    "SELECT d.module, d.symbol, d.text, d.file, d.line FROM docs d WHERE " ..
      symbols.shown_docs("d", true) .. " AND d.text <> ''" .. named .. " ORDER BY d.file, d.line, d.id", values)
  if rows == nil then
    return { "reading the public docs: " .. tostring(trouble) }
  end
  local names, names_trouble = db:rows("SELECT path FROM modules")
  if names == nil then
    return { "reading the modules: " .. tostring(names_trouble) }
  end
  local modules: mut {string: boolean} = {}
  for _, row in ipairs(names) do modules[row:text(1)] = true end
  local out: mut {string} = {}
  local found: mut {string: boolean} = {}
  for _, row in ipairs(rows) do
    local text = " " .. link_text.unlinked(row:text(3)) .. " "
    local seen: mut {string: boolean} = {}
    for _, rule in ipairs(doc_rules) do
      local at = 1
      while true do
        local from, to = text:find(rule.pattern, at)
        if from == nil or to == nil then break end
        at = to + 1
        local hit = text:sub(from, to)
        -- The whole word around the match, for the finding.
        local start, stop = from, to
        while start > 1 and not text:sub(start - 1, start - 1):match("%s") do start = start - 1 end
        while stop < #text and not text:sub(stop + 1, stop + 1):match("%s") do stop = stop + 1 end
        local word = text:sub(start, stop)
        local before, after = text:sub(from - 1, from - 1), text:sub(to + 1, to + 1)
        if rule.breaks(before, hit, after, modules) then
          local key = row:text(1) .. " " .. (if row:text(2) ~= "" then row:text(2) else "(module)" end) .. " " .. rule.name
          found[key] = true
          if excused[key] == nil and seen[word] ~= true then
            seen[word] = true
            out[#out + 1] = row:text(4) .. ":" .. tostring(row:integer(5)) .. ": " .. row:text(1) .. " " ..
              (if row:text(2) ~= "" then row:text(2) else "(module)" end) .. ": its doc text has `" .. word ..
              "` (" .. rule.name .. " rule) -- " .. rule.fix
          end
        end
      end
    end
  end
  local stale: mut {string} = {}
  local unexcused: {string: string} = {}
  for key in pairs(if files == nil then excused else unexcused end) do
    if found[key] ~= true then
      stale[#stale + 1] = key .. ": exempt, but its doc no longer breaks the rule -- " ..
        "remove the exemption"
    end
  end
  table.sort(stale)
  for _, line in ipairs(stale) do out[#out + 1] = line end
  return out
end

--- The literal plurals after a number that may stay, by
--- `<file>:<noun>`, and why each does. An entry masks every place in
--- that file that puts `<noun>` after a number, so the reason holds for
--- all of them.
local plural_exempt: mut {string: string} = {}

plural_exempt["build/vendor.tl:files"] = "runs on the bootstrap release " ..
  "(bin/vendor), which cannot require build.plural"
plural_exempt["build/confine.tl:paths"] = "a count above the unveil limit, so never 1; " ..
  "every worker loads build.confine, and none loads build.plural"
plural_exempt["build/fetch.tl:digests"] = "\"name different sha256 digests\": two differ, so never 1"
plural_exempt["build/test.tl:seconds"] = "the limit is math.maxinteger // 1000, never 1"
plural_exempt["build/test_key.tl:tables"] = "a label before its value (\"tables <digest>\"), not a count"
plural_exempt["cosmic/net.tl:bytes"] = "SOCKET_NAME_MAX is the platform's sun_path size, never 1"
plural_exempt["build/patch.tl:matches"] = "runs on the bootstrap release " ..
  "(bin/vendor applies patches), which cannot require build.plural"
plural_exempt["build/zig_fetch.tl:attempts"] = "runs on the bootstrap release " ..
  "(bin/zig), which cannot require build.plural"

--- [`PluralSites.of_chunk`] of `source`, parsed as the new checker reads it.
local function plural_sites(source: string, file: string): {{string}}?, string
  local chunk, trouble = SyntaxNode.parse(source, file)
  if chunk == nil then return nil, trouble end
  return PluralSites.of_chunk(chunk), ""
end

--- Whether the plural check reads `file`, a path from the tree's root: a Teal source under `build/`, `cmd/`, `cosmic/` or
--- `ci/cosmic_ci/` that is no test or declaration file.
local function plural_file(file: string): boolean
  return file:match("%.tl$") ~= nil and file:match("_test%.tl$") == nil and file:match("%.d%.tl$") == nil and
    (file:match("^build/") ~= nil or file:match("^cmd/") ~= nil or file:match("^cosmic/") ~= nil or
      file:match("^ci/cosmic_ci/") ~= nil)
end

--- The lines [`plurals`] says of `sources` (`{file, source}` pairs), and the `<file>:<noun>` keys found, which an exemption in
--- `excused` matches; `read` as [`plurals`] takes it.
local function plural_lines(sources: {{string}}, excused: {string: string}, read?: {string: tree_docs.Plurals}):
    mut {string}, {string: boolean}
  local out: mut {string} = {}
  local found: mut {string: boolean} = {}
  for _, row in ipairs(sources) do
    local file_name, source_text = row[1], row[2]
    local kept = if read ~= nil and file_name ~= nil then read[file_name] else nil end
    local sites: {{string}}?
    local parse_trouble: string?
    if file_name == nil or source_text == nil then
      out[#out + 1] = "a source to check for plurals is a file's path and its text"
      sites = {}
    elseif kept ~= nil and kept.source == source_text then
      sites = kept.sites
    else
      sites, parse_trouble = plural_sites(source_text, file_name)
    end
    if sites == nil then
      out[#out + 1] = (file_name or "?") .. ": cannot read it to check its plurals: " .. (parse_trouble or "")
    else
      for _, site in ipairs(sites) do
        local line, noun, literal, fix = site[1], site[2], site[3], site[4]
        if file_name ~= nil and line ~= nil and noun ~= nil and literal ~= nil and fix ~= nil then
          local key = file_name .. ":" .. noun
          found[key] = true
          if excused[key] == nil then
            out[#out + 1] = file_name .. ":" .. line .. ": `" .. literal ..
              "` puts the literal plural `" .. noun .. "` after a number, which reads \"1 " ..
              noun .. "\" -- " .. fix
          end
        end
      end
    end
  end
  return out, found
end

--- What [`plurals`] finds in `source`, the text of `file` (its path from the tree's root), read off `chunk`, the
--- caller's parse of it, or parsed here, so that the checks need not parse it again; nil for a file they do not read,
--- and for one that cannot be read, which [`plurals`] then says.
function tree_docs.plurals_in(file: string, source: string, chunk?: Ast.Chunk): tree_docs.Plurals?
  if not plural_file(file) then return nil end
  if chunk ~= nil then return { source = source, sites = PluralSites.of_chunk(chunk) } end
  local sites, _ = plural_sites(source, file)
  if sites == nil then return nil end
  return { source = source, sites = sites }
end

--- Every place in the Teal sources under `build/`, `cmd/` and
--- `cosmic/` of `db` (a test's excepted), and in `extra` (`{file,
--- source}` pairs, [`build.tree_checks.ci.ci_sources`]'s), that puts a literal plural noun
--- after a number, as `<file>:<line>: ...` with the fix, and then each
--- name in `excused` (by default `plural_exempt`) that nothing matches
--- any more.
---
--- The two spellings refused are a value that is not provably a string
--- joined to a literal by `..` (`#rows .. " tests"`, `tostring(n) ..
--- " files"`, `(a - b) .. " rows"`, `count .. " closure stores"`), and a
--- `%d` in a literal followed by one (`"%d files"`). Either prints "1
--- tests"; `plural.count(n, "test")` is right for every count, and
--- [`plural.noun`] when the line prints the number itself. The noun is
--- the first word of the literal after its space, or the second when
--- the first is not a verb or particle; a value in front of a verb
--- (`name .. " needs"`) is passed over, and a count spelled by a name
--- in front of a plural that is right for it (a count that cannot be 1)
--- goes in `plural_exempt` with the reason.
--- @param read what [`plurals_in`] found before the checks, by file: a
---   file whose text is the one read there is not parsed again
function tree_docs.plurals(db: Build, extra?: {{string}}, excused?: {string: string},
                           read?: {string: tree_docs.Plurals}): {string}
  excused = excused or plural_exempt
  local rows, trouble = db:rows(
    "SELECT file, CAST(inflate(source) AS TEXT) FROM modules WHERE kind <> 'test' " ..
      "AND file GLOB '*.tl' AND file NOT GLOB '*.d.tl' AND (file GLOB 'build/*' " ..
      "OR file GLOB 'cmd/*' OR file GLOB 'cosmic/*') ORDER BY file")
  if rows == nil then
    return { "reading the sources: " .. tostring(trouble) }
  end
  local sources: mut {{string}} = {}
  for _, row in ipairs(rows) do sources[#sources + 1] = { row:text(1), row:text(2) } end
  for _, row in ipairs(extra or {}) do sources[#sources + 1] = row end
  local out, found = plural_lines(sources, excused, read)
  local stale: mut {string} = {}
  for key in pairs(excused) do
    if found[key] ~= true then
      stale[#stale + 1] = key .. ": exempt, but nothing there writes a literal plural " ..
        "after a number any more -- remove the exemption"
    end
  end
  table.sort(stale)
  for _, tail in ipairs(stale) do out[#out + 1] = tail end
  return out
end

--- [`plurals`] over `sources` alone (`{file, source}` pairs, each file a path from the tree's root), with no word on an
--- exemption nothing matches: what a run of `cosmic fix` over some paths holds them to, where the whole tree's check
--- takes its sources from the projection. A file [`plurals`] does not read is passed over.
function tree_docs.plurals_of(sources: {{string}}, excused?: {string: string}): {string}
  local read: mut {{string}} = {}
  for _, row in ipairs(sources) do
    local file = row[1]
    if file ~= nil and plural_file(file) then read[#read + 1] = row end
  end
  local out, _ = plural_lines(read, excused or plural_exempt)
  return out
end

return tree_docs
