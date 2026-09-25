--- YAML's flow style as this tree writes it: a text JSON5 and YAML read
--- alike (`build/workflows_test.tl` holds the workflows and actions to
--- that subset), parsed into a tree that keeps what `cosmic.json` drops
--- -- its `#` comments, its blank lines, the order of an object's keys,
--- and whether a container was written on one line -- and laid back out
--- in one canonical form, so a text read and written again comes back
--- byte for byte once it is in that form.
---
--- The form: a container written on one line stays on one line,
--- `{a: 1, b: [2]}` with no trailing comma; any other holds one member a
--- line, indented two spaces a level, each followed by a comma, with
--- the comments and single blank lines between members where they were
--- and a comment after a member on its line. A key is bare where YAML
--- reads it as its text (`flow.bare`) and
--- quoted otherwise; a string is written as `cosmic.json` writes it; a
--- bare word (true, false, null, a number) as it was. The comments
--- before and after the root keep their places, and the text ends in
--- one line break.
---
--- `format` refuses a text whose layout would read as another value, or
--- would not come back unchanged from a second pass, rather than write
--- it. A program may also change a tree `parse` returned -- a scalar's
--- `text`, an item added or removed -- and `render` it: what it did not
--- touch keeps its bytes.
-- TODO: a value-to-tree constructor (and paths to find a member by), so
-- a program can build or edit a workflow from Teal values rather than
-- from nodes, once one is wanted.

local Json = require("cosmic.json")

local record flow
  --- A value in the text: an object, an array, or a scalar.
  record Node
    kind: string
    --- A scalar's text as it is written: a string encoded as
    --- `cosmic.json` encodes it, or a bare word.
    text: string
    --- An object's or array's members, in order.
    items: {flow.Item}
    --- Whether a container stays on one line.
    inline: boolean
    --- A comment on a multi-line container's opening line.
    comment: string
    --- The comments and blank lines after its last member.
    tail: {string}
  end

  --- A member of an object or array.
  record Item
    --- An object member's key, as the key reads; nil in an array.
    key: string
    value: flow.Node
    --- The comment lines before it, "" for a blank line.
    before: {string}
    --- A comment after it on its line.
    comment: string
  end

  --- A whole text: the comments around its root value.
  record Doc
    head: {string}
    root: flow.Node
    foot: {string}
  end
end

--- Bare keys YAML reads as something other than their text: YAML 1.1's
--- booleans and both versions' null, whatever their case.
local unsafe_keys <const>: {string: boolean} = {
  y = true, yes = true, n = true, no = true, on = true, off = true, ["true"] = true, ["false"] = true,
  null = true,
}

local READ <const>: Json.DecodeOptions = { json5 = true, hash_comments = true }

--- Whether `key` may be written bare.
function flow.bare(key: string): boolean
  return key:match("^[%a_$][%w_$]*$") ~= nil and not unsafe_keys[key:lower()]
end

--- A key as the form writes it.
local function key_text(key: string): string
  if flow.bare(key) then return key end
  return (assert(Json.encode(key)))
end

--- A scalar node for a string, boolean or integer, or `Json.null`.
function flow.scalar(value: any): flow.Node
  if value is string then
    return { kind = "scalar", text = (assert(Json.encode(value))) }
  end
  return { kind = "scalar", text = value == Json.null and "null" or tostring(value) }
end

--- A parse failure is raised as its message after this prefix, which
--- `parse` catches and returns; any other error passes on.
local FAILURE <const> = "\0flow\0"

local function fail(line: integer, why: string)
  error(FAILURE .. ("line %d: %s"):format(line, why), 0)
end

--- The parser's place in the text.
local record Reader
  text: string
  at: integer
  line: integer
end

--- What lies between two tokens: the comments, each with the line it
--- is on, and where a blank line fell ("" entries), and how many line
--- breaks the run held in all.
local record Trivia
  entries: {string}
  lines: {integer}
  breaks: integer
end

--- Reads the spaces, line breaks and comments from the reader's place
--- to the next token.
local function trivia(r: Reader): Trivia
  local t: Trivia = { entries = {}, lines = {}, breaks = 0 }
  local run = 0
  local text = r.text
  while r.at <= #text do
    local c = text:sub(r.at, r.at)
    if c == " " or c == "\t" or c == "\r" then
      r.at = r.at + 1
    elseif c == "\n" then
      run = run + 1
      t.breaks = t.breaks + 1
      r.line = r.line + 1
      r.at = r.at + 1
    elseif c == "#" then
      if run >= 2 then
        t.entries[#t.entries + 1] = ""
        t.lines[#t.lines + 1] = r.line
      end
      local stop = text:find("\n", r.at, true) or #text + 1
      t.entries[#t.entries + 1] = (text:sub(r.at, stop - 1):gsub("[ \t\r]+$", ""))
      t.lines[#t.lines + 1] = r.line
      r.at = stop
      run = 0
    else
      break
    end
  end
  if run >= 2 then
    t.entries[#t.entries + 1] = ""
    t.lines[#t.lines + 1] = r.line
  end
  return t
end

--- `entries` with runs of blank lines made one, and none at either end
--- where `trim` asks.
local function tidy(entries: {string}, trim_start: boolean, trim_end: boolean): {string}
  local out: {string} = {}
  for _, entry in ipairs(entries) do
    if entry ~= "" or (#out > 0 and out[#out] ~= "") or (#out == 0 and not trim_start) then
      out[#out + 1] = entry
    end
  end
  if trim_end then
    while #out > 0 and out[#out] == "" do out[#out] = nil end
  end
  return out
end

--- Splits `t` at the comment on `line`, the line the token before it
--- ended: that comment, then everything after it.
local function trailing(t: Trivia, line: integer): string, {string}
  if #t.entries > 0 and t.entries[1] ~= "" and t.lines[1] == line then
    return t.entries[1], { table.unpack(t.entries, 2) }
  end
  return nil, t.entries
end

local parse_value: function(r: Reader): flow.Node

--- The string token at the reader's place, as the text it reads as.
local function read_string(r: Reader): string
  local text = r.text
  local first = r.at
  if text:sub(first, first) ~= '"' then fail(r.line, "a single-quoted string: write it double-quoted") end
  local i = first + 1
  while i <= #text do
    local c = text:sub(i, i)
    if c == "\\" then
      i = i + 2
    elseif c == '"' then
      break
    else
      if c == "\n" then fail(r.line, "a line break in a string") end
      i = i + 1
    end
  end
  if i > #text then fail(r.line, "a string with no end") end
  r.at = i + 1
  local value, _ = Json.decode(text:sub(first, i), READ)
  if not value is string then
    error(FAILURE .. ("line %d: a string neither reader reads"):format(r.line), 0)
  end
  return value
end

local function read_word(r: Reader): string
  local word = r.text:match("^[%w_$+.%-]+", r.at)
  if word == nil then
    fail(r.line, ("the character %q where a value belongs"):format(r.text:sub(r.at, r.at)))
  end
  r.at = r.at + #word
  return word
end

local function parse_container(r: Reader): flow.Node
  local open = r.text:sub(r.at, r.at)
  local close = open == "{" and "}" or "]"
  local node: flow.Node = { kind = open == "{" and "object" or "array", items = {}, tail = {} }
  local open_line = r.line
  r.at = r.at + 1
  local t = trivia(r)
  local pending: {string}
  node.comment, pending = trailing(t, open_line)
  while true do
    if r.at > #r.text then fail(r.line, "a " .. open .. " with no " .. close) end
    if r.text:sub(r.at, r.at) == close then
      node.tail = pending
      node.inline = r.line == open_line
      r.at = r.at + 1
      return node
    end
    local item: flow.Item = { before = pending }
    if node.kind == "object" then
      local key_line = r.line
      if r.text:sub(r.at, r.at) == '"' or r.text:sub(r.at, r.at) == "'" then
        item.key = read_string(r)
      else
        item.key = read_word(r)
      end
      while r.text:sub(r.at, r.at) == " " do r.at = r.at + 1 end
      if r.text:sub(r.at, r.at) ~= ":" then fail(key_line, "a key with no : after it on its line") end
      r.at = r.at + 1
      local between = trivia(r)
      if #between.entries > 0 and between.entries[1] ~= "" then
        fail(key_line, "a comment between a key and its value")
      end
    end
    item.value = parse_value(r)
    local after = trivia(r)
    local value_line = r.line - after.breaks
    local comment, rest = trailing(after, value_line)
    if r.text:sub(r.at, r.at) == "," then
      local comma_line = r.line
      r.at = r.at + 1
      local more = trivia(r)
      if comment == nil and #rest == 0 then
        comment, rest = trailing(more, comma_line)
      else
        for _, entry in ipairs(more.entries) do rest[#rest + 1] = entry end
      end
    elseif r.text:sub(r.at, r.at) ~= close then
      fail(r.line, "a member with no , after it")
    end
    item.comment = comment
    pending = rest
    node.items[#node.items + 1] = item
  end
end

parse_value = function(r: Reader): flow.Node
  local c = r.text:sub(r.at, r.at)
  if c == "{" or c == "[" then
    return parse_container(r)
  elseif c == '"' or c == "'" then
    return flow.scalar(read_string(r))
  end
  return { kind = "scalar", text = read_word(r) }
end

--- The tree of a flow-style text, or nil and why it is not one.
function flow.parse(text: string): flow.Doc | nil, string
  local r: Reader = { text = text, at = 1, line = 1 }
  local doc: flow.Doc
  local ok, raised = pcall(function(): string
    local head = trivia(r)
    if r.at > #text then fail(r.line, "no value") end
    local root = parse_value(r)
    local foot = trivia(r)
    if r.at <= #text then fail(r.line, "more after the value") end
    doc = { head = head.entries, root = root, foot = foot.entries }
    return ""
  end)
  if not ok then
    if raised is string and raised:sub(1, #FAILURE) == FAILURE then
      return nil, raised:sub(#FAILURE + 1)
    end
    error(raised, 0)
  end
  return doc
end

local function inline_text(node: flow.Node): string
  if node.kind == "scalar" then return node.text end
  local parts: {string} = {}
  for _, item in ipairs(node.items) do
    local value = inline_text(item.value)
    parts[#parts + 1] = item.key ~= nil and key_text(item.key) .. ": " .. value or value
  end
  local open, close = "[", "]"
  if node.kind == "object" then open, close = "{", "}" end
  return open .. table.concat(parts, ", ") .. close
end

--- Whether a node is written on one line: a scalar, an empty container
--- with no comments, or one written that way that holds only such.
local function one_line(node: flow.Node): boolean
  if node.kind == "scalar" then return true end
  if node.comment ~= nil or #tidy(node.tail, true, true) > 0 then return false end
  if #node.items == 0 then return true end
  if not node.inline then return false end
  for _, item in ipairs(node.items) do
    if item.comment ~= nil or #tidy(item.before, true, true) > 0 or not one_line(item.value) then
      return false
    end
  end
  return true
end

local function comment_lines(out: {string}, entries: {string}, pad: string)
  for _, entry in ipairs(entries) do
    out[#out + 1] = entry == "" and "" or pad .. entry
  end
end

--- Appends `node`'s text to `out`, whose last line it continues; `pad`
--- is its line's indentation.
local function write(out: {string}, node: flow.Node, pad: string)
  if one_line(node) then
    out[#out] = out[#out] .. inline_text(node)
    return
  end
  local open, close = "[", "]"
  if node.kind == "object" then open, close = "{", "}" end
  out[#out] = out[#out] .. open .. (node.comment ~= nil and " " .. node.comment or "")
  local inner = pad .. "  "
  for index, item in ipairs(node.items) do
    comment_lines(out, tidy(item.before, index == 1, false), inner)
    out[#out + 1] = inner .. (item.key ~= nil and key_text(item.key) .. ": " or "")
    write(out, item.value, inner)
    out[#out] = out[#out] .. "," .. (item.comment ~= nil and " " .. item.comment or "")
  end
  comment_lines(out, tidy(node.tail, #node.items == 0, true), inner)
  out[#out + 1] = pad .. close
end

--- A tree's text, in the canonical form.
function flow.render(doc: flow.Doc): string
  local out: {string} = {}
  comment_lines(out, tidy(doc.head, true, false), "")
  out[#out + 1] = ""
  write(out, doc.root, "")
  comment_lines(out, tidy(doc.foot, false, true), "")
  return table.concat(out, "\n") .. "\n"
end

--- `text`'s value, with `null` kept, as one canonical encoding to
--- compare.
local function value_of(text: string): string | nil, string
  local value, trouble = Json.decode(text, { json5 = true, hash_comments = true, null_value = Json.null })
  if trouble ~= nil and trouble ~= "" then return nil, trouble end
  return Json.encode(value)
end

--- `text` in the canonical form, or nil and why not: a text that is not
--- in flow style, or whose form would read as another value or change
--- again on a second pass.
function flow.format(text: string): string | nil, string
  local doc, trouble = flow.parse(text)
  if doc == nil then return nil, trouble end
  local out = flow.render(doc)
  if out == text then return out end
  local before, before_trouble = value_of(text)
  if before == nil then return nil, "the text does not read as JSON5: " .. before_trouble end
  local after, _ = value_of(out)
  if after ~= before then return nil, "laid out, it would read as another value" end
  local again, _ = flow.parse(out)
  if again == nil or flow.render(again) ~= out then
    return nil, "laid out, a second pass would change it again"
  end
  return out
end

--- Whether `text` is in flow style: its first line that is neither
--- blank nor a comment opens with `{` or `[`.
function flow.is_flow(text: string): boolean
  for row in text:gmatch("[^\n]*") do
    if row:match("%S") and not row:match("^%s*#") then
      return row:match("^%s*[{[]") ~= nil
    end
  end
  return false
end

return flow
