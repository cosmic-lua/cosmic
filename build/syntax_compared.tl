--- The fork's readers against the ports in this directory: for one file, what each reader answers of the file as written
--- (the fork's tree) and of the file translated to the new grammar ([`lang.translate`]), and where the two
--- differ. It is the check that a port reads what the original reads, as [`build.tree_checks`]'s `generated` is for the
--- code generator, run by `read` over every file of the tree.
---
--- A reader is compared on what its callers read, not on its raw rows, since the translation moves columns: the modules
--- a file requires, the lines of its global declarations, the references through an alias and what is in scope at the
--- first token of each line, the lines its stub keeps and whether the stub is declaration-only, its executable lines,
--- and each row of its analysis (its tests, policy, catalog, docs, references, bound names, examples and the links of
--- its comments, [`build.syntax_compared_analysis`]) and the places a literal plural follows a number ([`build.plural_sites`]). [`Shape.record_of`] needs the checker's types of a whole project, so [`build.syntax_shape_specs`]'s tests hold it
--- to the fork's results instead.
---
-- TODO: compare a stub's identifier words line by line, with `nil`, `mut`, `local` and `type` set aside, and compare the
-- lines, bindings and stub of a file whose translation makes a class, and the lines of the rows of its analysis, once the
-- translator gives its result a map of the lines it moved: a stub is compared by the lines it keeps, and the twenty files
-- that make a class by their references and `pruned` alone (their analysis rows without a line), and the stub is the
-- standard library's.
-- TODO: delete this module and the fork's readers it compares with at the switch, when the tree is written in the new
-- grammar and nothing is translated on read (doc/plans/strict-teal.md, "the switch").
local Analysis = require("build.syntax_compared_analysis")
local Ast = require("lang.ast")
local Lexer = require("lang.lexer")
local Globals = require("build.syntax_globals")
local Match = require("build.syntax_match")
local Node = require("build.syntax_node")
local PluralSites = require("build.plural_sites")
local Rewrite = require("build.syntax_rewrite")
local Lexical = require("build.syntax_scopes")
local Stub = require("build.syntax_stub")
local Scopes = require("lang.scopes")
local Translate = require("lang.translate")
local ast = require("build.ast")
local coverage = require("build.coverage")
local fork_globals = require("build.globals")
local fork_scopes = require("build.scopes")
local fork_stub = require("build.stub")
local type compiler = require("build.compiler")

local record Compared
  --- Why the file cannot be compared, "" where it can: the fork or the translation does not parse.
  --- `differences` are the readers whose answers differ, each a line that names the reader and says how.
  record Outcome
    skipped: string
    differences: {string}
    --- How many rows each dimension of [`build.syntax_compared_analysis`] compared, which a tree total shows
    --- compared something.
    counts: {string: integer}
  end

  --- The readers of `file`, whose text is `source` in the fork's Teal, compared; `built` is the fork's compiler.
  file: function(built: compiler, file: string, source: string): Outcome

  --- The dimensions of an [`Outcome`]'s `counts`: the rows of an analysis that are compared.
  dimensions: {string}
end

Compared.dimensions = {}
for _, dimension in ipairs(Analysis.dimensions) do
  Compared.dimensions[#Compared.dimensions + 1] = dimension
end
Compared.dimensions[#Compared.dimensions + 1] = "plurals"

--- A source in the fork's Teal read as the ports read it: through [`lang.translate`], which writes it in the new grammar
--- with its lines where they were.
local record Read
  --- The source in the new grammar.
  text: string
  chunk: Ast.Chunk
  scoped: Scopes.Scoped
  --- Whether the translation moved lines: a method written as `function R:m()` moves into its class, and the lines
  --- after it shift. A place read from the translation is then not one of the original.
  moved: boolean
end

--- `source`, a file named `name`, translated, parsed and scoped against no globals; nil and why where the translation does
--- not parse.
local function translated(source: string, name: string): Read?, string
  local made = Translate.translate(source, name)
  local chunk, why = Node.parse(made.text, name)
  if chunk == nil then
    return nil, why
  end
  return { text = made.text, chunk = chunk, scoped = Node.scope(chunk, name), moved = made.counts["class"] ~= nil }, ""
end

local function joined(list: {string}): string
  return table.concat(list, " ")
end

local function line_set(lines: {integer: boolean}): string
  local numbers: mut {integer} = {}
  for line in pairs(lines) do
    numbers[#numbers + 1] = line
  end
  table.sort(numbers)
  local out: mut {string} = {}
  for _, n in ipairs(numbers) do
    out[#out + 1] = tostring(n)
  end
  return joined(out)
end

--- The first place two lists of words differ, for a message.
local function first_difference(a: {string}, b: {string}): string
  for i = 1, math.max(#a, #b) do
    if a[i] ~= b[i] then
      return "at " .. i .. ": `" .. tostring(a[i]) .. "` against `" .. tostring(b[i]) .. "`"
    end
  end
  return ""
end

local function words(text: string): {string}
  local out: mut {string} = {}
  for word in text:gmatch("%S+") do
    out[#out + 1] = word
  end
  return out
end

--- The lines of `text` that hold anything.
local function filled(text: string): {integer: boolean}
  local out: mut {integer: boolean} = {}
  local y = 0
  for line in (text .. "\n"):gmatch("(.-)\n") do
    y = y + 1
    if line:find("%S") ~= nil then
      out[y] = true
    end
  end
  return out
end

--- The `module name line` of every reference through an alias, sorted, each once.
local function sorted_unique(list: mut {string}): {string}
  table.sort(list)
  local out: mut {string} = {}
  for _, item in ipairs(list) do
    if out[#out] ~= item then
      out[#out + 1] = item
    end
  end
  return out
end

--- The names in scope, as one string.
local function scope_text(names: {string: string}): string
  local keys: mut {string} = {}
  for name in pairs(names) do
    keys[#keys + 1] = name
  end
  table.sort(keys)
  local out: mut {string} = {}
  for _, name in ipairs(keys) do
    out[#out + 1] = name .. "=" .. names[name]
  end
  return joined(out)
end

--- The first token of each line, by line, as {x}.
local function firsts(tokens: {{integer}}): {integer: integer}
  local out: mut {integer: integer} = {}
  for _, t in ipairs(tokens) do
    if out[t[1]] == nil then
      out[t[1]] = t[2]
    end
  end
  return out
end

--- A binding as one line of text for a comparison: its name, module and flags, the lines it is in scope from and to, and the
--- line a comment above its statement stands on.
local function binding_text(name: string, module: string, top: boolean, annotated: boolean, from: integer, to: integer,
                            head: integer): string
  return table.concat({ name, module, tostring(top), tostring(annotated), tostring(from // 1048576),
    tostring(to // 1048576), tostring(head // 1048576) }, ",")
end

--- A module a file requires and the token it is required at.
local record Required
  first: integer
  module: string
end

--- The modules the calls `require($M)` with a literal name and the imports of `chunk` name, in source order, each once, found
--- by the structural matcher.
local function matched_requires(chunk: Ast.Chunk): {string}
  local found: mut {Required} = {}
  local pattern, _ = Match.compile("require($M)")
  if pattern ~= nil then
    for _, hit in ipairs(Rewrite.find_all(pattern, chunk)) do
      local named = hit.caps["_M"]
      local literal = named ~= nil and named.nodes[1] or nil
      if literal ~= nil and (literal.kind == "String") then
        found[#found + 1] = { first = Node.base(hit.node).first, module = literal.value }
      end
    end
  end
  Node.walk(chunk, function(node: Ast.Node)
    if (node.kind == "Import") then
      found[#found + 1] = { first = node.first, module = node.module }
    end
  end)
  table.sort(found, function(a: Required, b: Required): boolean
    return a.first < b.first
  end)
  local seen: mut {string: boolean} = {}
  local out: mut {string} = {}
  for _, entry in ipairs(found) do
    if not seen[entry.module] then
      seen[entry.module] = true
      out[#out + 1] = entry.module
    end
  end
  return out
end

--- `lines` less the lines of the labels the fork's tree holds: the fork counts a label as a statement, whose line holds no
--- instruction, and the translation of `goto continue` removes it.
local function without_labels(parsed: ast.Parsed, lines: {integer: boolean}): {integer: boolean}
  local out: mut {integer: boolean} = {}
  for line in pairs(lines) do
    out[line] = true
  end
  ast.walk(parsed.node, function(node: ast.Node)
    if node.kind == "label" then
      out[node.y] = nil
    end
  end)
  return out
end

function Compared.file(built: compiler, file: string, source: string): Compared.Outcome
  local differences: mut {string} = {}
  local function differ(reader: string, how: string)
    differences[#differences + 1] = reader .. ": " .. how
  end
  local parsed, why = ast.parse(built, source, file)
  if parsed == nil then
    return { skipped = "the fork does not parse it: " .. why, differences = {}, counts = {} }
  end
  local read, trouble = translated(source, file)
  if read == nil then
    return { skipped = "its translation does not parse: " .. trouble, differences = {}, counts = {} }
  end
  local chunk, scoped = read.chunk, read.scoped
  -- A translation that moves lines moves every place read from it: what is compared of such a file does not depend on a
  -- line.
  local placed = not read.moved

  local old_requires, requires_trouble = ast.all_requires(built, parsed)
  local new_requires = Node.requires(chunk)
  if old_requires == nil then
    differ("requires", "the fork's pattern does not compile: " .. requires_trouble)
  elseif joined(old_requires) ~= joined(new_requires) then
    differ("requires", first_difference(old_requires, new_requires))
  end

  -- The matcher and the walk find the requires as the fork's pattern does: the calls of `require` with a literal, and the
  -- type imports, which are no calls in the new tree.
  local matched = matched_requires(chunk)
  if old_requires ~= nil and joined(old_requires) ~= joined(matched) then
    differ("match", first_difference(old_requires, matched))
  end

  local old_globals: mut {string} = {}
  local new_globals: mut {string} = {}
  for _, place in ipairs(fork_globals.found(parsed)) do
    old_globals[#old_globals + 1] = ("%d:%d"):format(place.line, place.column)
  end
  for _, place in ipairs(Globals.found(chunk)) do
    new_globals[#new_globals + 1] = ("%d:%d"):format(place.line, place.column)
  end
  -- The column of a `global` is the same in the translation, as it begins its statement.
  if placed and joined(old_globals) ~= joined(new_globals) then
    differ("globals", first_difference(old_globals, new_globals))
  elseif #old_globals ~= #new_globals then
    differ("globals", #old_globals .. " against " .. #new_globals)
  end

  local old_members: {string} = {}
  local new_members: {string} = {}
  local old_bindings = fork_scopes.walk(parsed, function(module: string, name: string, line: integer)
    old_members[#old_members + 1] = module .. "." .. name .. (if placed then ":" .. line else "" end)
  end)
  local new_bindings = Lexical.walk(chunk, scoped, function(module: string, name: string, line: integer)
    new_members[#new_members + 1] = module .. "." .. name .. (if placed then ":" .. line else "" end)
  end)
  old_members, new_members = sorted_unique(old_members), sorted_unique(new_members)
  if joined(old_members) ~= joined(new_members) then
    differ("references", first_difference(old_members, new_members))
  end

  -- The same bindings, from the same line to the same line (of a file whose lines the translation
  -- keeps; the lists of one that makes a class differ in the locals it removes and the `self` it adds). The fork binds the `...` of a function as
  -- a name, which nothing can refer to by a name in a comment.
  local old_list: mut {string} = {}
  for _, each in ipairs(old_bindings) do
    if each.name ~= "..." then
      old_list[#old_list + 1] = binding_text(each.name, each.module, each.top, each.annotated, each.from, each.to,
        each.head)
    end
  end
  local new_list: mut {string} = {}
  for _, each in ipairs(new_bindings) do
    new_list[#new_list + 1] = binding_text(each.name, each.module, each.top, each.annotated, each.from, each.to,
      each.head)
  end
  -- The order two walks declare the parameters of function literals in one chain of calls is theirs to choose.
  table.sort(old_list)
  table.sort(new_list)
  -- A translation that moves lines also removes the metatable local of a class and adds the `self` of its methods.
  if placed and joined(old_list) ~= joined(new_list) then
    differ("scopes", "bindings " .. first_difference(old_list, new_list))
  elseif placed then
    -- What is in scope at the first token of some lines, with a comment's view of a statement below it.
    local old_first: mut {{integer}} = {}
    for _, t in ipairs(parsed.tokens) do
      old_first[#old_first + 1] = { t.y, t.x }
    end
    local new_first: mut {{integer}} = {}
    for i, y in ipairs(chunk.tokens.y) do
      new_first[#new_first + 1] = { y, Lexer.x(chunk.tokens, i) }
    end
    local old_at, new_at = firsts(old_first), firsts(new_first)
    local probes: mut {integer} = {}
    for y in pairs(new_at) do
      if old_at[y] ~= nil then
        probes[#probes + 1] = y
      end
    end
    table.sort(probes)
    local kept: mut {fork_scopes.Binding} = {}
    for _, each in ipairs(old_bindings) do
      if each.name ~= "..." then
        kept[#kept + 1] = each
      end
    end
    local step: integer = math.max(1, #probes // 24)
    for i = 1, #probes, step do
      local y = probes[i]
      for _, heading in ipairs({ false, true }) do
        local a = scope_text(fork_scopes.in_scope(kept, y, old_at[y], heading))
        local b = scope_text(Lexical.in_scope(new_bindings, y, new_at[y], heading))
        if a ~= b then
          differ("scopes", "line " .. y .. (if heading then " as a heading" else "" end) .. ": `" .. a .. "` against `" .. b .. "`")
          break
        end
      end
    end
  end

  local old_stub, new_stub = fork_stub.made(parsed), Stub.made(chunk)
  if old_stub.pruned ~= new_stub.pruned then
    differ("stub", "pruned " .. tostring(old_stub.pruned) .. " against " .. tostring(new_stub.pruned))
  end
  local old_kept, new_kept = line_set(filled(old_stub.text)), line_set(filled(new_stub.text))
  if placed and old_kept ~= new_kept then
    differ("stub", "lines kept " .. first_difference(words(old_kept), words(new_kept)))
  end

  local old_lines, old_trouble = coverage.executable(built, source, file)
  local new_lines, new_trouble = coverage.syntax_executable(read.text, file)
  if old_lines == nil or new_lines == nil then
    differ("lines", "no lines: " .. old_trouble .. new_trouble)
  elseif placed and line_set(without_labels(parsed, old_lines)) ~= line_set(new_lines) then
    differ("lines", "executable " .. first_difference(words(line_set(old_lines)), words(line_set(new_lines))))
  end
  -- The sites where a literal plural follows a number, in order, with their lines where the translation keeps them.
  local old_plurals = PluralSites.lines(PluralSites.of_fork(parsed), placed)
  local new_plurals = PluralSites.lines(PluralSites.of_chunk(chunk), placed)
  if joined(old_plurals) ~= joined(new_plurals) then
    differ("plurals", first_difference(old_plurals, new_plurals))
  end

  local analysed = Analysis.file(built, file, source, parsed, read.text, chunk, scoped, read.moved)
  for _, line in ipairs(analysed.differences) do
    differences[#differences + 1] = line
  end
  analysed.counts["plurals"] = #old_plurals
  return { skipped = "", differences = differences, counts = analysed.counts }
end

return Compared
