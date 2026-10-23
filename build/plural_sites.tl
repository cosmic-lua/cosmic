--- Where the Teal sources of the tree put a literal plural noun after a number (`#rows .. " tests"`, `"%d files"`): the
--- sites [`build.tree_checks`]'s `plurals` refuses, read off either tree. [`PluralSites.of_fork`] reads the fork's
--- ([`build.ast`]), [`PluralSites.of_chunk`] the new checker's ([`lang.ast`]); [`build.syntax_compared`] holds the second to
--- the first over every file of the tree.
---
-- TODO: delete [`of_fork`] and the fork's helpers below, and read [`of_chunk`] from the tree as written, once the switch deletes
-- the fork and the translation ([`lang.translate`]) it reads through (doc/plans/strict-teal.md, "the switch").
local Ast = require("lang.ast")
local Lexer = require("lang.lexer")
local Node = require("build.syntax_node")
local ast = require("build.ast")

local type ForkNode = ast.Node

local record PluralSites
  --- Every literal plural noun in the fork's tree `parsed` that follows a number, as `{line, noun, snippet, fix}`: after a
  --- value that is not provably a string, by `..` (`#rows .. " tests"`, `tostring(n) .. " files"`, `(a - b) .. " rows"`,
  --- any name, field or call), or after a `%d` in a literal.
  of_fork: function(parsed: ast.Parsed): {{string}}

  --- The same sites of the tree `chunk` of the new grammar ([`Node.parse`]), in source order. A line is the one the fork
  --- gives it for a source the translation leaves its lines in.
  of_chunk: function(chunk: Ast.Chunk): {{string}}

  --- `sites` as one line each, to compare two readings of a tree: the noun and the snippet of each, and its line first
  --- where `lined`.
  lines: function(sites: {{string}}, lined: boolean): {string}
end

--- Words after a number that are verbs or particles, not nouns:
--- `at byte %d needs`, `n .. " and files"`.
local NOT_NOUNS: {string: boolean} = {}
for word in ([[does needs names leaves takes lacks gives holds reads starts ends makes returns
  wants uses sets means comes always perhaps sometimes towards whereas afterwards
  is was are were has have had must cannot can not no will would and or but in on at of to for
  by from with the a an as if than that which when while so then after before until once now
  also only never still both either]]):gmatch("%S+") do
  NOT_NOUNS[word] = true
end

--- The words before a `%d` that make it a position or a name, not a
--- count: `at byte %d`, `line %d`.
local LABELS: {string: boolean} = {}
for word in ([[byte offset line column index position transition version entry step char
  character field row type code number errno signal exit status port pid]]):gmatch("%S+") do
  LABELS[word] = true
end

--- The nouns a count is taken of, which a plural after a bare name
--- (`n .. " files"`) must be one of: a name in front of any other plural
--- is as likely a subject in front of its verb (`name .. " lists"`).
local UNITS: {string: boolean} = {}
for word in ([[bytes files lines rows tests modules entries paths words comments sources targets
  builds attempts assets products releases digests digits seconds minutes hours milliseconds values
  fields stores compilers verbs components patches tables keys columns caches databases
  instructions inputs iters draws tries arguments errors failures directories members
  functions symbols steps bits chunks pieces sites hits results workers processes
  threads children hosts addresses tokens labels parts jobs items]]):gmatch("%S+") do
  UNITS[word] = true
end

--- Whether `word` reads as a plural noun: lowercase, an `s` at its end,
--- and none of the words that end so and are not.
local function is_plural_noun(word: string): boolean
  return #word >= 4 and word:match("^%l+$") ~= nil and word:sub(-1) == "s" and
    not word:match("ss$") and not word:match("[iu]s$") and not NOT_NOUNS[word]
end

--- The plural noun `text` leads with, after one space: its first word,
--- or its second when the first is not a particle or verb (` closure
--- stores`); nil when it leads with neither.
local function plural_after_space(text: string, counted: boolean): string | nil
  local first, rest = text:match("^ (%a+)(.*)$")
  if first == nil then return nil end
  if is_plural_noun(first) then
    if counted or UNITS[first] then return first end
    return nil
  end
  if not first:match("^%l+$") or NOT_NOUNS[first] then return nil end
  local second = rest:match("^ (%l+)%f[^%a]")
  if second ~= nil and is_plural_noun(second) and (counted or UNITS[second]) then return second end
  return nil
end

--- The plural noun the format `text` puts after a `%d` (`%d files`),
--- and where in `text` the number is, for each place it does. A `%d`
--- that follows a label (`at byte %d`) or a noun followed by `=` is a
--- name, not a count.
local function format_plurals(text: string): {string}
  local found: {string} = {}
  local at = 1
  while true do
    local first, last = string.find(text, "%d ", at, true)
    if first == nil then break end
    at = last
    local noun = plural_after_space(text:sub(last, last + 60), true)
    local label = text:sub(math.max(1, first - 12), first - 1):match("(%l+) $")
    if noun ~= nil and not LABELS[label or ""] then
      local after = text:sub(last + 1):match("^.-" .. noun .. "(.?)")
      if after ~= "=" then found[#found + 1] = noun end
    end
  end
  return found
end

--- The site of a literal that begins with the plural `noun`, joined to a number by `..`, at line `y`.
local function concat_site(y: integer, noun: string, literal: string): {string}
  return { tostring(y), noun, "... .. \"" .. literal:sub(1, 24),
    "write `plural.count(n, singular)` (with the plural as a third argument when it is " ..
      "not the singular and an `s`)" }
end

--- The site of the plural `noun` that the format string at line `y` puts after a `%d`.
local function format_site(y: integer, noun: string): {string}
  return { tostring(y), noun, "%d " .. noun, "print `plural.noun(n, singular)` beside the number" }
end

--- Whether `node` is a number by its shape: a length, `tostring(...)`, a
--- literal, or arithmetic (parenthesized or not).
local function counted(node: ForkNode): boolean
  local inner = node
  local e1 = node.e1
  if node.kind == "paren" and e1 ~= nil then inner = e1 end
  local info = inner.op
  if inner.kind == "integer" or inner.kind == "number" then return true end
  if inner.kind ~= "op" or info == nil then return false end
  if info.op == "#" then return true end
  if info.op == "@funcall" then
    local callee = inner.e1
    return callee ~= nil and callee.tk == "tostring"
  end
  return info.op == "+" or info.op == "-" or info.op == "*" or info.op == "//" or
    info.op == "%" or info.op == "/"
end

--- Whether `node` is a `..`.
local function is_concat(node: ForkNode): boolean
  local info = node.op
  return node.kind == "op" and info ~= nil and info.op == ".."
end

--- The literal string a concatenation starts with, whether its
--- operand is that string or a chain of `..` that begins with one.
local function leading_literal(node: ForkNode): string | nil
  if node.kind == "string" then return node.conststr end
  local e1 = node.e1
  if is_concat(node) and e1 ~= nil then return leading_literal(e1) end
  return nil
end

function PluralSites.of_fork(parsed: ast.Parsed): {{string}}
  local sites: {{string}} = {}
  ast.walk(parsed.node, function(node: ForkNode)
    local left, right = node.e1, node.e2
    local conststr = node.conststr
    if is_concat(node) and left ~= nil and right ~= nil and left.kind ~= "string" and
        not is_concat(left) then
      local literal = leading_literal(right)
      local noun = literal ~= nil and plural_after_space(literal, counted(left)) or nil
      if literal ~= nil and noun ~= nil then
        sites[#sites + 1] = concat_site(right.y, noun, literal)
      end
    elseif node.kind == "string" and conststr ~= nil and conststr:find("%%d ") then
      for _, noun in ipairs(format_plurals(conststr)) do
        sites[#sites + 1] = format_site(node.y, noun)
      end
    end
  end)
  return sites
end

--- Whether `node` is a number by its shape, as [`counted`] reads the fork's tree: a length, `tostring(...)`, a literal, or
--- arithmetic (parenthesized or not).
local function counted_exp(node: Ast.Exp): boolean
  local inner = node
  if node is Ast.Paren then inner = node.inner end
  if inner is Ast.Integer or inner is Ast.Float then return true end
  if inner is Ast.Unary then return inner.op == "#" or inner.op == "-" end
  if inner is Ast.Binary then
    local op = inner.op
    return op == "+" or op == "-" or op == "*" or op == "//" or op == "%" or op == "/"
  end
  if inner is Ast.Call then
    local callee = inner.callee
    return callee is Ast.Name and callee.text == "tostring"
  end
  return false
end

--- Whether `node` is a `..`.
local function is_concat_exp(node: Ast.Exp): boolean
  return node is Ast.Binary and node.op == ".."
end

--- The text of the string `node` as the source writes it between its quotes or long brackets, which is what the fork's tree
--- holds of it: an escape stays as written, and the line break that opens a long string stays.
local function written_text(chunk: Ast.Chunk, node: Ast.String): string
  local written = Lexer.token(chunk.tokens, Node.base(node).first).text
  if node.long then
    local _, body = written:match("^%[(=*)%[(.*)%]%1%]$")
    return body or node.value
  end
  return written:sub(2, -2)
end

--- The literal string a concatenation starts with, as [`leading_literal`] reads the fork's tree.
local function leading_literal_exp(chunk: Ast.Chunk, node: Ast.Exp): string | nil
  if node is Ast.String then return written_text(chunk, node) end
  if node is Ast.Binary and node.op == ".." then return leading_literal_exp(chunk, node.left) end
  return nil
end

--- The line the fork gives `node`: that of its first token, and for an operator that of the operator itself, which the
--- fork's tree puts a binary node at.
local function line_of(chunk: Ast.Chunk, node: Ast.Exp): integer
  if node is Ast.Binary then
    local operator = Node.base(node.left).last + 1
    local y = chunk.tokens.y[operator]
    if y ~= nil then return y end
  end
  return Node.span(chunk, node).y
end

function PluralSites.of_chunk(chunk: Ast.Chunk): {{string}}
  local sites: {{string}} = {}
  Node.walk(chunk, function(node: Ast.Node)
    if node is Ast.Binary and node.op == ".." then
      local left, right = node.left, node.right
      if not (left is Ast.String) and not is_concat_exp(left) then
        local literal = leading_literal_exp(chunk, right)
        if literal ~= nil then
          local noun = plural_after_space(literal, counted_exp(left))
          if noun ~= nil then
            sites[#sites + 1] = concat_site(line_of(chunk, right), noun, literal)
          end
        end
      end
    elseif node is Ast.String then
      local text = written_text(chunk, node)
      if text:find("%%d ") ~= nil then
        for _, noun in ipairs(format_plurals(text)) do
          sites[#sites + 1] = format_site(Node.span(chunk, node).y, noun)
        end
      end
    end
  end)
  return sites
end

function PluralSites.lines(sites: {{string}}, lined: boolean): {string}
  local out: {string} = {}
  for _, site in ipairs(sites) do
    out[#out + 1] = (lined and assert(site[1]) .. " " or "") .. assert(site[2]) .. ": " .. assert(site[3])
  end
  return out
end

return PluralSites
