--- YAML's flow style as this tree writes it: a text JSON5 and YAML read
--- alike, parsed into a tree that keeps what `cosmic.json` drops -- its
--- `#` comments, its blank lines, the order of an object's keys, and
--- whether a container was written on one line -- and laid back out in
--- one canonical form, so a text read and written again comes back byte
--- for byte once it is in that form. The workflows and actions under
--- `.github/` are held to it (build/workflows_test.tl), and `cosmic fix`
--- writes it.
---
--- The subset (`problems`) is narrower than what the two readers share,
--- and anything it cannot vouch for is refused. The form: a container
--- written on one line stays on one line, `{a: 1, b: [2]}` with no
--- trailing comma; any other holds one member a line, indented two
--- spaces a level, each followed by a comma, with the comments and
--- single blank lines between members where they were and a comment
--- after a member on its line. A key is bare where YAML reads it as its
--- text (`bare`) and quoted otherwise; a string is written as
--- `cosmic.json` writes it, but for the characters the subset refuses
--- raw, which it escapes; a bare word (true, false, null, an integer) as
--- it was. The comments before and after the root keep their places,
--- and the text ends in one line break.
---
--- `format` refuses a text outside the subset, and one whose layout
--- would leave it, read as another value, lose a comment or change again
--- on a second pass, rather than write it.
---
--- A program edits a text through its tree: `parse` it, find a member
--- (`get`), replace or add one (`set`), or write a whole new value over
--- it (`update`), and `render` it; what it did not touch keeps its
--- bytes. `from` builds a tree from Teal values alone, and `value` reads
--- one back.

local Json = require("cosmic.json")

local record flow
  --- A value in the text: an object, an array, or a scalar.
  record Node
    kind: string
    --- A scalar's text as it is written: a string as `quote` writes
    --- it, or a bare word.
    text: string
    --- An object's or array's members, in order.
    items: {flow.Item}
    --- Whether a container stays on one line.
    inline: boolean
    --- For a container `from` built or `update` changed, the widest line
    --- it stays on one line within, decided where it is rendered.
    width: integer
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
    --- A comment after the root on its closing line.
    comment: string
    foot: {string}
  end

  --- How `from` and `update` build what they add.
  record Options
    --- Keys an object lists first, in this order; any other follows,
    --- in byte order. A workflow's, a job's and a step's keys in the
    --- order GitHub's documentation writes them, by default.
    order: {string}
    --- The widest line a container is kept on one line within, its
    --- indentation included (100 by default).
    width: integer
  end
end

--- The order GitHub's documentation writes a workflow's, a job's and a
--- step's keys in, which `from` and `update` add keys in by default.
local WORKFLOW_ORDER <const>: {string} = {
  "name", "description", "on", "permissions", "env", "defaults", "concurrency", "inputs", "outputs",
  "jobs", "id", "if", "needs", "uses", "runs-on", "runs", "using", "environment", "container", "strategy",
  "timeout-minutes", "continue-on-error", "working-directory", "shell", "with", "run", "steps",
}

--- How deep containers may nest, as `cosmic.json` reads them by default.
local MAX_DEPTH <const> = Json.default_depth

local READ <const>: Json.DecodeOptions = { json5 = true, hash_comments = true }

--- Bare keys YAML reads as something other than their text: YAML 1.1's
--- booleans and both versions' null, whatever their case.
local unsafe_keys <const>: {string: boolean} = {
  y = true, yes = true, n = true, no = true, on = true, off = true, ["true"] = true, ["false"] = true,
  null = true,
}

--- Whether `key` may be written bare: an identifier YAML reads as its
--- text.
function flow.bare(key: string): boolean
  return key:match("^[%a_$][%w_$]*$") ~= nil and not unsafe_keys[key:lower()]
end

--- The escapes a double-quoted string may hold, which the two read
--- alike (`\u` takes four hex digits).
local ESCAPES <const>: {string: boolean} = {
  ['"'] = true, ["\\"] = true, ["/"] = true, b = true, f = true, n = true, r = true, t = true, u = true,
}

--- Each character in `text` that not every YAML reader takes as JSON5
--- does, as `line N: why`: bytes that are not UTF-8; a control
--- character but a tab or a line end, which YAML refuses, among them
--- C1's NEL (U+0085), which YAML 1.1 ends a line at; a `\r` alone;
--- U+2028 and U+2029, which JSON5 ends a line at and YAML 1.2 does not;
--- and U+FEFF, U+FFFE and U+FFFF.
local function characters(text: string): {string}
  local found: {string} = {}
  if utf8.len(text) == nil then
    return { "the text is not UTF-8" }
  end
  local line = 1
  for at, code in utf8.codes(text) do
    if code == 0x0a then
      line = line + 1
    elseif code == 0x0d then
      if text:sub(at + 1, at + 1) ~= "\n" then
        found[#found + 1] = ("line %d: a \\r alone: end a line with \\n"):format(line)
      end
    elseif (code < 0x20 and code ~= 0x09) or (code >= 0x7f and code < 0xa0) or code == 0x2028 or
        code == 0x2029 or code == 0xfeff or code == 0xfffe or code == 0xffff then
      found[#found + 1] = ("line %d: the character U+%04X, which the two read differently"):format(line, code)
    end
  end
  return found
end

--- What in `text` either reader would read differently from the other,
--- or not at all, each as `line N: why`. It holds a text to a subset
--- narrower than the two share, where anything it cannot vouch for is
--- refused:
---
--- - Anywhere, strings and comments too: UTF-8 of tabs, line ends and
---   printable characters alone (`characters`), a line ending at `\n` or
---   `\r\n`.
--- - Outside a string and a comment: only spaces, line ends,
---   `{}[],:`, `#` and bare words; a `#` after a space or a line's
---   start, since YAML reads one right after a token as part of it; a
---   space after each `:`, and the `:` on its key's line; no `//` or
---   `/*` comment and no single-quoted string, which YAML lacks or reads
---   otherwise.
--- - A bare key one `flow.bare` takes: an identifier YAML reads as its
---   text; a bare value true, false, null or a decimal integer of at most
---   15 digits, which both read as the same number.
--- - In a double-quoted string, only ESCAPES, and no `\u` escape of
---   half a surrogate pair, which YAML keeps as a lone half and JSON5
---   joins to its pair: write the character itself.
--- - No key twice in one object, which GitHub refuses.
local function scan(text: string, comments: {string}): {string}
  local found: {string} = characters(text)
  local line = 1
  local function say(why: string)
    found[#found + 1] = ("line %d: %s"):format(line, why)
  end
  --- For each open container, an object's keys seen, or false.
  local open: {{string: boolean} | boolean} = {}
  local function key(name: string)
    local keys = open[#open]
    if keys is {string: boolean} then
      if keys[name] then say("the key " .. name .. " twice in one object") end
      keys[name] = true
    end
  end
  --- The line the last token ended on, which a `:` must share.
  local token_line = 0
  local i = 1
  local n = #text
  while i <= n do
    local c = text:sub(i, i)
    if c == "\r" then
      i = i + 1
    elseif c == "\n" then
      line = line + 1
      i = i + 1
    elseif c == " " then
      i = i + 1
    elseif c == "#" then
      local before = i > 1 and text:sub(i - 1, i - 1) or "\n"
      if before ~= " " and before ~= "\n" then say("a # right after a token: put a space before it") end
      local stop = text:find("\n", i, true) or n + 1
      comments[#comments + 1] = (text:sub(i, stop - 1):gsub("[ \t\r]+$", ""))
      i = stop
    elseif c == '"' or c == "'" then
      if c == "'" then say("a single-quoted string: write it double-quoted") end
      local first = i
      i = i + 1
      while i <= n and text:sub(i, i) ~= c do
        local d = text:sub(i, i)
        if d == "\n" then
          line = line + 1
        elseif d == "\t" then
          say("a tab in a string, which cosmic.json refuses: write \\t")
        elseif d == "\\" then
          local e = text:sub(i + 1, i + 1)
          local hex = text:sub(i + 2, i + 5)
          if not ESCAPES[e] or (e == "u" and not hex:match("^%x%x%x%x$")) then
            say("the escape \\" .. e .. ", which the two read differently: write \\uXXXX")
          elseif e == "u" and hex:upper():match("^D[89A-F]") then
            say("the escape \\u" .. hex .. ", half a surrogate pair: write the character itself")
          end
          i = i + 1
        end
        i = i + 1
      end
      i = i + 1
      token_line = line
      if text:match("^ *:", i) then
        local name, _ = Json.decode(text:sub(first, i - 1), READ)
        if name == "<<" then say("the key <<, which YAML 1.1 reads as a merge") end
        if name is string then key(name) end
      end
    elseif c == "/" and text:sub(i + 1, i + 1):match("[/*]") then
      local opening = text:sub(i, i + 1)
      say("a " .. opening .. " comment, which YAML does not have: write #")
      -- Past the comment, so what it holds is not read as tokens.
      if opening == "//" then
        i = text:find("\n", i, true) or n + 1
      else
        local _, close = text:find("*/", i + 2, true)
        i = close and close + 1 or n + 1
      end
    elseif c == ":" then
      if not text:sub(i + 1, i + 1):match("^[ \r\n]") then say("a : with no space after it") end
      if token_line ~= line then say("a : on another line than its key") end
      i = i + 1
    elseif c == "{" or c == "[" then
      open[#open + 1] = c == "{" and {} or false
      i = i + 1
    elseif c == "}" or c == "]" then
      open[#open] = nil
      token_line = line
      i = i + 1
    elseif c == "," then
      i = i + 1
    elseif c:match("[%w_$+.%-]") then
      local word = text:match("^[%w_$+.%-]+", i)
      i = i + #word
      token_line = line
      if text:match("^ *:", i) then
        if not flow.bare(word) then
          say("the bare key " .. word .. ", which YAML reads otherwise: quote it")
        else
          key(word)
        end
      elseif word ~= "true" and word ~= "false" and word ~= "null" and
          not (word:match("^%-?[1-9]%d*$") and #word:gsub("^%-", "") <= 15) and word ~= "0" then
        say("the bare value " .. word .. ": quote it, or write a decimal integer of at most 15 digits")
      end
    else
      say(("the character %s outside a string, which the two read differently"):format(
        c:byte() < 0x80 and ("%q"):format(c) or ("\\x%02X"):format(c:byte())))
      i = i + 1
    end
  end
  return found
end

--- What in `text` either reader would read differently from the other,
--- or not at all, each as `line N: why` (see `scan`).
function flow.problems(text: string): {string}
  return scan(text, {})
end

--- The characters the subset refuses raw in a string, which `quote`
--- escapes: DEL and C1's controls, U+2028, U+2029, U+FEFF, U+FFFE and
--- U+FFFF, as the UTF-8 byte sequences that write them.
local RAW_REFUSED <const> = {
  "\x7f", "\xc2[\x80-\x9f]", "\xe2\x80[\xa8\xa9]", "\xef\xbb\xbf", "\xef\xbf[\xbe\xbf]",
}

--- A string as the form writes it: as `cosmic.json` encodes it, with
--- each character the subset refuses raw escaped as `\uXXXX`.
local function quote(s: string): string
  local out = (assert(Json.encode(s)))
  for _, pattern in ipairs(RAW_REFUSED) do
    out = out:gsub(pattern, function(char: string): string
      return ("\\u%04x"):format(utf8.codepoint(char))
    end)
  end
  return out
end

--- A key as the form writes it.
local function key_text(key: string): string
  if flow.bare(key) then return key end
  return quote(key)
end

--- A scalar node for a string, a boolean, an integer the subset writes
--- (at most 15 digits), or `Json.null`. Raises for any other value.
function flow.scalar(value: any): flow.Node
  if value is string then
    return { kind = "scalar", text = quote(value) }
  elseif value == Json.null or value is boolean then
    return { kind = "scalar", text = value == Json.null and "null" or tostring(value) }
  elseif math.type(value) == "integer" and #tostring(value):gsub("^%-", "") <= 15 then
    return { kind = "scalar", text = tostring(value) }
  end
  error("flow.scalar: " .. tostring(value) .. " is no string, boolean, integer of at most 15 digits " ..
    "or Json.null", 2)
end

--- A parse failure is raised as its message after this prefix, which
--- `parse` catches and returns; any other error passes on.
local FAILURE <const> = "\0flow\0"

local function fail(line: integer, why: string)
  error(FAILURE .. ("line %d: %s"):format(line, why), 0)
end

--- The parser's place in the text, and how deep it is.
local record Reader
  text: string
  at: integer
  line: integer
  depth: integer
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

--- `entries` with runs of blank lines made one, and none at the start
--- or the end where asked.
local function tidy(entries: {string}, trim_start: boolean, trim_end: boolean): {string}
  local out: {string} = {}
  for _, entry in ipairs(entries or {}) do
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
  r.depth = r.depth + 1
  if r.depth > MAX_DEPTH then fail(r.line, "containers nested deeper than " .. MAX_DEPTH) end
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
      r.depth = r.depth - 1
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
      for _, entry in ipairs(trivia(r).entries) do
        if entry ~= "" then fail(key_line, "a comment between a key and its value") end
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
      local on_comma, beyond = trailing(more, comma_line)
      if on_comma ~= nil and (comment ~= nil or #rest > 0) then
        fail(comma_line, "a comment after a , on a line of its own: put it after the member")
      end
      if comment == nil and #rest == 0 then
        comment, rest = on_comma, beyond
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

--- The tree of a flow-style text, or nil and why it is not one. It does
--- not hold the text to the subset: `format` does.
function flow.parse(text: string): flow.Doc | nil, string
  local r: Reader = { text = text, at = 1, line = 1, depth = 0 }
  local doc: flow.Doc
  local ok, raised = pcall(function(): string
    local head = trivia(r)
    if r.at > #text then fail(r.line, "no value") end
    local root = parse_value(r)
    local foot = trivia(r)
    if r.at <= #text then fail(r.line, "more after the value") end
    local comment, rest = trailing(foot, r.line - foot.breaks)
    doc = { head = head.entries, root = root, comment = comment, foot = rest }
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
--- with no comments, or one written that way that holds only such --
--- and, for one that `width` holds (see `Node.width`), whose text fits
--- in it from `column` with `after` more bytes after it.
local function one_line(node: flow.Node, column: integer, after: integer): boolean
  if node.kind == "scalar" then return true end
  if node.comment ~= nil or #tidy(node.tail, true, true) > 0 then return false end
  if #node.items == 0 then return true end
  if not node.inline then return false end
  for _, item in ipairs(node.items) do
    if item.comment ~= nil or #tidy(item.before, true, true) > 0 or not one_line(item.value, 0, 0) then
      return false
    end
  end
  return node.width == nil or column + #inline_text(node) + after <= node.width
end

local function comment_lines(out: {string}, entries: {string}, pad: string)
  for _, entry in ipairs(entries) do
    out[#out + 1] = entry == "" and "" or pad .. entry
  end
end

--- Appends `node`'s text to `out`, whose last line it continues; `pad`
--- is its line's indentation, and `after` how many bytes follow it on
--- its last line (a member's comma).
local function write(out: {string}, node: flow.Node, pad: string, after: integer)
  if one_line(node, #out[#out], after) then
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
    write(out, item.value, inner, 1)
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
  write(out, doc.root, "", 0)
  if doc.comment ~= nil then out[#out] = out[#out] .. " " .. doc.comment end
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

--- Whether two lists hold the same strings, in any order.
local function same_multiset(a: {string}, b: {string}): boolean
  if #a ~= #b then return false end
  local left, right = { table.unpack(a) }, { table.unpack(b) }
  table.sort(left)
  table.sort(right)
  for i = 1, #left do
    if left[i] ~= right[i] then return false end
  end
  return true
end

--- The comments of `text`, as `problems` finds them.
function flow.comments(text: string): {string}
  local found: {string} = {}
  scan(text, found)
  return found
end

--- `text` in the canonical form, or nil and why not: a text outside the
--- subset, or whose form would leave it, read as another value, lose a
--- comment, or change again on a second pass.
function flow.format(text: string): string | nil, string
  local before_comments: {string} = {}
  local found = scan(text, before_comments)
  if #found > 0 then return nil, found[1] end
  local doc, trouble = flow.parse(text)
  if doc == nil then return nil, trouble end
  local out = flow.render(doc)
  local after_comments: {string} = {}
  found = scan(out, after_comments)
  if #found > 0 then return nil, "laid out, it would leave the subset: " .. found[1] end
  local before, before_trouble = value_of(text)
  if before == nil then return nil, "the text does not read as JSON5: " .. before_trouble end
  local after, _ = value_of(out)
  if after ~= before then return nil, "laid out, it would read as another value" end
  if not same_multiset(before_comments, after_comments) then
    return nil, "laid out, it would lose or change a comment"
  end
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

--- Whether `value` is a Lua table `from` writes as an array: one
--- `cosmic.json` marked, or a non-empty sequence.
local function is_array(value: any): boolean
  if not value is {any: any} then return false end
  if Json.is_array(value) then return true end
  local count = 0
  for _ in pairs(value) do count = count + 1 end
  if value is {any} then return count > 0 and count == #value end
  return false
end

--- An object's keys in the order `opts` writes them.
local function ordered(value: {string: any}, opts: flow.Options): {string}
  local rank: {string: integer} = {}
  for i, key in ipairs(opts.order or WORKFLOW_ORDER) do rank[key] = i end
  local keys: {string} = {}
  for key in pairs(value) do
    if not key is string then error("flow.from: an object key " .. tostring(key) .. " is no string", 0) end
    if key == "<<" then error("flow.from: the key <<, which YAML 1.1 reads as a merge", 0) end
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a: string, b: string): boolean
    local ra, rb = rank[a], rank[b]
    if ra ~= nil and rb ~= nil then return ra < rb end
    if ra ~= nil or rb ~= nil then return ra ~= nil end
    return a < b
  end)
  return keys
end

--- The tree of `value`, `depth` containers down.
local function build(value: any, opts: flow.Options, depth: integer): flow.Node
  if not value is {any: any} or value == Json.null then
    return flow.scalar(value)
  end
  if depth >= MAX_DEPTH then
    error("flow.from: containers nested deeper than " .. MAX_DEPTH .. ", or a table that holds itself", 0)
  end
  local node: flow.Node = { items = {}, tail = {}, width = opts.width or 100 }
  if is_array(value) and value is {any} then
    node.kind = "array"
    for _, each in ipairs(value) do
      node.items[#node.items + 1] = { value = build(each, opts, depth + 1), before = {} }
    end
  elseif value is {string: any} then
    node.kind = "object"
    for _, key in ipairs(ordered(value, opts)) do
      node.items[#node.items + 1] = { key = key, value = build(value[key], opts, depth + 1), before = {} }
    end
  end
  local scalars = true
  for _, item in ipairs(node.items) do
    if item.value.kind ~= "scalar" then scalars = false end
  end
  node.inline = scalars
  return node
end

--- The tree of a Teal value: a table `cosmic.json` would write as an
--- object or an array, and scalars `scalar` takes. An object's keys
--- come in `opts.order`, and a container of scalars alone is kept on one
--- line where it fits `opts.width` in the column it is rendered at.
--- Raises for a value it cannot write.
function flow.from(value: any, opts?: flow.Options): flow.Node
  return build(value, opts or {}, 0)
end

--- A new text of a Teal value, with no comments: `from`, rendered.
function flow.write(value: any, opts?: flow.Options): string
  return flow.render({ head = {}, root = flow.from(value, opts), foot = {} })
end

--- A node's value, as `cosmic.json` reads it (`Json.null` for null), or
--- nil and why it reads as none.
function flow.value(node: flow.Node): any | nil, string
  return Json.decode(inline_text(node), { json5 = true, null_value = Json.null })
end

--- The member of `node` down `path`, a key for each object and an index
--- for each array, or nil where there is none.
function flow.get(node: flow.Node, ...: string | integer): flow.Node | nil
  local at = node
  for _, step in ipairs({ ... }) do
    local found: flow.Node = nil
    for index, item in ipairs(at.items or {}) do
      if (at.kind == "object" and item.key == step) or (at.kind == "array" and index == step) then
        found = item.value
        break
      end
    end
    if found == nil then return nil end
    at = found
  end
  return at
end

--- Sets `node`'s member `key` (an object's key, or an array's index, up
--- to one past its last) to `new` (`from` makes one of a Teal value). A
--- member already there keeps its comments; a new one goes at the end.
--- A `node` written on one line stays there only while it fits 100
--- columns. Raises when `node` is no container, or `key` does not fit it.
-- TODO: hold a one-line container above `node` to the width too, which
-- `set` cannot reach from `node`: take the path from the root, as `get`
-- does, once a program sets a member inside a one-line container.
function flow.set(node: flow.Node, key: string | integer, new: flow.Node)
  if node.kind == "object" and key is string then
    for _, item in ipairs(node.items) do
      if item.key == key then
        item.value = new
        return
      end
    end
    node.items[#node.items + 1] = { key = key, value = new, before = {} }
    if node.inline then node.width = node.width or 100 end
  elseif node.kind == "array" and key is integer and key >= 1 and key <= #node.items + 1 then
    if node.items[key] ~= nil then
      node.items[key].value = new
    else
      node.items[key] = { value = new, before = {} }
    end
    if node.inline then node.width = node.width or 100 end
  else
    error("flow.set: " .. tostring(key) .. " is no member a " .. tostring(node.kind) .. " can have", 2)
  end
end

--- A value's encoding, to tell members apart by; a member whose text
--- reads as no value gets one no value can have.
local function encoded(value: any, trouble: string, index: integer): string
  if trouble ~= nil and trouble ~= "" then return "\0" .. index end
  local text, _ = Json.encode(value)
  return text or "\0" .. index
end

--- What names a member across a change to it: an object's `id`, `name`
--- or the action its `uses` names, without the version after `@` -- a
--- step, a job, a matrix leg -- or nil.
local function identity(value: any): string | nil
  if not value is {string: any} then return nil end
  for _, field in ipairs({ "id", "name" }) do
    local found = value[field]
    if found is string then return field .. "\0" .. found end
  end
  local uses = value.uses
  if uses is string then return "uses\0" .. uses:gsub("@.*$", "") end
  return nil
end

--- Pairs the members of `old` with the values of `new` the way a diff
--- does: those equal in both, longest run in order first, anchor the
--- rest, the common start and end first of all; between two anchors, a
--- run of the same length on both sides is paired in order (members
--- changed in place), and in a run of another length a member is paired
--- with one its `identity` names, in order, the rest dropped from `old`
--- and added from `new`. The pairing, by `new`'s index: the old item,
--- or nil for one to add.
local function paired(old: {flow.Item}, new: {any}): {integer: flow.Item}
  local a, b: {string}, {string} = {}, {}
  local old_values: {any} = {}
  for i, item in ipairs(old) do
    local value, trouble = flow.value(item.value)
    old_values[i] = value
    a[i] = encoded(value, trouble, i)
  end
  for j, value in ipairs(new) do b[j] = encoded(value, "", j) end
  local out: {integer: flow.Item} = {}
  -- The common start and end, which most changes leave most of.
  local lo = 1
  while lo <= #a and lo <= #b and a[lo] == b[lo] do
    out[lo] = old[lo]
    lo = lo + 1
  end
  local hi_a, hi_b = #a, #b
  while hi_a >= lo and hi_b >= lo and a[hi_a] == b[hi_b] do
    out[hi_b] = old[hi_a]
    hi_a, hi_b = hi_a - 1, hi_b - 1
  end
  -- The table of longest common runs from each (i, j) to the middle's end.
  local lcs: {{integer}} = {}
  for i = hi_a + 1, lo, -1 do
    lcs[i] = {}
    for j = hi_b + 1, lo, -1 do
      if i > hi_a or j > hi_b then
        lcs[i][j] = 0
      elseif a[i] == b[j] then
        lcs[i][j] = lcs[i + 1][j + 1] + 1
      else
        lcs[i][j] = math.max(lcs[i + 1][j], lcs[i][j + 1])
      end
    end
  end
  local function between(i1: integer, i2: integer, j1: integer, j2: integer)
    if i2 - i1 == j2 - j1 then
      for k = 0, i2 - i1 - 1 do out[j1 + k] = old[i1 + k] end
      return
    end
    local next_old = i1
    for j = j1, j2 - 1 do
      local want = identity(new[j])
      if want ~= nil then
        for i = next_old, i2 - 1 do
          if identity(old_values[i]) == want then
            out[j] = old[i]
            next_old = i + 1
            break
          end
        end
      end
    end
  end
  local i, j = lo, lo
  local gi, gj = lo, lo
  while i <= hi_a and j <= hi_b do
    if a[i] == b[j] then
      between(gi, i, gj, j)
      out[j] = old[i]
      i, j = i + 1, j + 1
      gi, gj = i, j
    elseif lcs[i + 1][j] >= lcs[i][j + 1] then
      i = i + 1
    else
      j = j + 1
    end
  end
  between(gi, hi_a + 1, gj, hi_b + 1)
  return out
end

--- `update`'s walk.
local function update(node: flow.Node, value: any, o: flow.Options, depth: integer): flow.Node
  if not value is {any: any} or value == Json.null then
    local new = flow.scalar(value)
    if node.kind == "scalar" and node.text == new.text then return node end
    return new
  end
  if depth >= MAX_DEPTH then
    error("flow.update: containers nested deeper than " .. MAX_DEPTH .. ", or a table that holds itself", 0)
  end
  local array = is_array(value) or (node.kind == "array" and next(value) == nil)
  if (array and node.kind ~= "array") or (not array and node.kind ~= "object") then
    return build(value, o, depth)
  end
  local was = inline_text(node)
  local kept: {flow.Item} = {}
  if array and value is {any} then
    local pairing = paired(node.items, value)
    for index, each in ipairs(value) do
      local item = pairing[index]
      if item ~= nil then
        item.value = update(item.value, each, o, depth + 1)
        kept[#kept + 1] = item
      else
        kept[#kept + 1] = { value = build(each, o, depth + 1), before = {} }
      end
    end
  elseif value is {string: any} then
    local seen: {string: boolean} = {}
    for _, item in ipairs(node.items) do
      if value[item.key] ~= nil then
        item.value = update(item.value, value[item.key], o, depth + 1)
        kept[#kept + 1] = item
        seen[item.key] = true
      end
    end
    for _, key in ipairs(ordered(value, o)) do
      if not seen[key] then
        kept[#kept + 1] = { key = key, value = build(value[key], o, depth + 1), before = {} }
      end
    end
  end
  node.items = kept
  -- One written on one line and changed stays there only while it
  -- fits; one left as it was keeps its line, however long.
  if node.inline and inline_text(node) ~= was then node.width = o.width or 100 end
  return node
end

--- `node` with `value` written over it, changed in place: an object's
--- member both hold keeps its place and comments and takes the new
--- value, the same way down; one only `node` holds goes, its comments
--- with it; one only `value` holds is added at the end, in `opts.order`.
--- An array's members are paired as `paired` says, so a member added or
--- removed leaves the others' comments with them. A container written on
--- one line stays there only while it fits `opts.width`. Where the two
--- are not both objects or both arrays, the result is `from(value)`.
--- The order applies to every object, a step's `with` and `env` too.
function flow.update(node: flow.Node, value: any, opts?: flow.Options): flow.Node
  return update(node, value, opts or {}, 0)
end

return flow
