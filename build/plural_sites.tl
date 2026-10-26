--- Where the Teal sources of the tree put a literal plural noun after a number (`#rows .. " tests"`, `"%d files"`): the
--- sites [`build.tree_checks`]'s `plurals` refuses, read off the tree of the new checker ([`lang.ast`]) as the file is
--- written.
local Ast = require("lang.ast")
local Lexer = require("lang.lexer")
local Node = require("build.syntax_node")

local record PluralSites
  --- Every literal plural noun in the tree `chunk` ([`Node.parse`]) that follows a number, as `{line, noun, snippet, fix}`,
  --- in source order: after a value that is not provably a string, by `..` (`#rows .. " tests"`, `tostring(n) .. " files"`,
  --- `(a - b) .. " rows"`, any name, field or call), or after a `%d` in a literal.
  of_chunk: function(chunk: Ast.Chunk): {{string}}

  --- `sites` as one line each, to compare two readings of a tree: the noun and the snippet of each, and its line first
  --- where `lined`.
  lines: function(sites: {{string}}, lined: boolean): {string}
end

--- Words after a number that are verbs or particles, not nouns:
--- `at byte %d needs`, `n .. " and files"`.
local NOT_NOUNS: mut {string: boolean} = {}
for word in ([[does needs names leaves takes lacks gives holds reads starts ends makes returns
  wants uses sets means comes always perhaps sometimes towards whereas afterwards
  is was are were has have had must cannot can not no will would and or but in on at of to for
  by from with the a an as if than that which when while so then after before until once now
  also only never still both either]]):gmatch("%S+") do
  NOT_NOUNS[word] = true
end

--- The words before a `%d` that make it a position or a name, not a
--- count: `at byte %d`, `line %d`.
local LABELS: mut {string: boolean} = {}
for word in ([[byte offset line column index position transition version entry step char
  character field row type code number errno signal exit status port pid]]):gmatch("%S+") do
  LABELS[word] = true
end

--- The nouns a count is taken of, which a plural after a bare name
--- (`n .. " files"`) must be one of: a name in front of any other plural
--- is as likely a subject in front of its verb (`name .. " lists"`).
local UNITS: mut {string: boolean} = {}
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
local function plural_after_space(text: string, counted: boolean): string?
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
  local found: mut {string} = {}
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

--- Whether `node` is a number by its shape: a length, `tostring(...)`, a literal, or arithmetic (parenthesized or not).
local function counted_exp(node: Ast.Exp): boolean
  local inner = node
  if (node.kind == "Paren") then inner = node.inner end
  if (inner.kind == "Integer") or (inner.kind == "Float") then return true end
  if (inner.kind == "Unary") then return inner.op == "#" or inner.op == "-" end
  if (inner.kind == "Binary") then
    local op = inner.op
    return op == "+" or op == "-" or op == "*" or op == "//" or op == "%" or op == "/"
  end
  if (inner.kind == "Call") then
    local callee = inner.callee
    return (callee.kind == "Name") and callee.text == "tostring"
  end
  return false
end

--- Whether `node` is a `..`.
local function is_concat_exp(node: Ast.Exp): boolean
  return (node.kind == "Binary") and node.op == ".."
end

--- The text of the string `node` as the source writes it between its quotes or long brackets: an escape stays as written,
--- and the line break that opens a long string stays.
local function written_text(chunk: Ast.Chunk, node: Ast.String): string
  local written = Lexer.token(chunk.tokens, Node.base(node).first).text
  if node.long then
    local _, body = written:match("^%[(=*)%[(.*)%]%1%]$")
    return body or node.value
  end
  return written:sub(2, -2)
end

--- The literal string a concatenation starts with, whether its operand is that string or a chain of `..` that begins with
--- one.
local function leading_literal_exp(chunk: Ast.Chunk, node: Ast.Exp): string?
  if (node.kind == "String") then return written_text(chunk, node) end
  if (node.kind == "Binary") and node.op == ".." then
    return leading_literal_exp(chunk, node.left)
  end
  return nil
end

--- The line of `node`: that of its first token, and for an operator that of the operator itself, which is the line a
--- concatenation is reported at.
local function line_of(chunk: Ast.Chunk, node: Ast.Exp): integer
  if (node.kind == "Binary") then
    local operator = Node.base(node.left).last + 1
    local y = chunk.tokens.y[operator]
    if y ~= nil then return y end
  end
  return Node.span(chunk, node).y
end

function PluralSites.of_chunk(chunk: Ast.Chunk): {{string}}
  local sites: mut {{string}} = {}
  Node.walk(chunk, function(node: Ast.Node)
    if (node.kind == "Binary") and node.op == ".." then
      local left, right = node.left, node.right
      if not ((left.kind == "String")) and not is_concat_exp(left) then
        local literal = leading_literal_exp(chunk, right)
        if literal ~= nil then
          local noun = plural_after_space(literal, counted_exp(left))
          if noun ~= nil then
            sites[#sites + 1] = concat_site(line_of(chunk, right), noun, literal)
          end
        end
      end
    elseif (node.kind == "String") then
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
  local out: mut {string} = {}
  for _, site in ipairs(sites) do
    out[#out + 1] = (if lined then assert(site[1]) .. " " else "" end) .. assert(site[2]) .. ": " .. assert(site[3])
  end
  return out
end

return PluralSites
