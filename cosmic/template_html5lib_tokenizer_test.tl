--- [`cosmic.template`]'s markup tracker against html5lib's tokenizer
--- tests: wherever the tracker accepts a slot, the HTML tokenizer must be
--- in the state that slot's escaping is right for.
---
--- A test case gives an input and the tokens the spec tokenizer makes of
--- it, which say nothing of where it is part way through. So the test
--- holds a second tokenizer, written from the standard's states, and
--- trusts it only for the cases where its tokens are the case's (the
--- ones with no character reference, NUL or CR, which it does not
--- decode). For each such case it cuts the input at every byte boundary,
--- puts a slot there and compiles the template: where the tracker
--- accepts the slot, the state the tokenizer is in at that cut must be
--- one a slot of that kind may stand in. A refusal is never wrong, so
--- it is never checked. A case that starts in RCDATA, RAWTEXT, script
--- data or PLAINTEXT is wrapped in the element that puts a browser's
--- tree builder there.
---
--- Input after a start tag that makes a tree builder switch the tokenizer
--- (`<textarea>`, `<script>`, `<svg>` and the like) is not checked here,
--- since the data's tokenizer does not switch: those slots are covered
--- by the tree-construction test alone.
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Template = require("cosmic.template")
local Test = require("cosmic.test")

Test.policy{ grants = { { path = "vendor/html5lib-tokenizer/tokenizer", letters = "r" } } }

local DIRECTORY <const> = "vendor/html5lib-tokenizer/tokenizer"

--- What the reference tokenizer made of an input.
local record Run
  --- The tokens, one string each (see `emit`).
  tokens: {string}
  --- The state after each prefix of the input: `states[i + 1]` is the
  --- state the tokenizer is in having read `i` bytes.
  states: {string}
  --- The attribute being read in a quoted value, at the same cuts.
  attrs: {string}
  --- In RCDATA, the `<` and what follows it that might become an end tag,
  --- at the same cuts.
  tails: {string}
end

--- What the reference tokenizer holds while it reads: its state, the text
--- gathered for the next token, the tag, attribute and comment being read,
--- and the name of the last start tag.
local record Machine
  mut state: string
  mut chars: string
  mut last_tag: string
  mut tag_kind: string
  mut tag_name: string
  mut tag_self: boolean
  mut tag_attrs: mut {string: string}
  mut attr_name: string
  mut attr_value: string
  mut attr_dup: boolean
  mut has_attr: boolean
  mut comment: string
  mut temp: string
  mut target: string
  mut pi_data: string
end

local function is_alpha(c: string): boolean
  return c:find("^%a$") ~= nil
end

local function is_space(c: string): boolean
  return c == " " or c == "\t" or c == "\n" or c == "\f" or c == "\r"
end

--- The canonical text of a tag token: its name, its attributes in name
--- order and whether it closes itself.
local function tag_text(kind: string, name: string, attrs: {string: string}, self: boolean): string
  local names: mut {string} = {}
  for k in pairs(attrs) do
    names[#names + 1] = k
  end
  table.sort(names)
  local parts: mut {string} = {}
  for _, k in ipairs(names) do
    parts[#parts + 1] = k .. "=" .. attrs[k]
  end
  return kind .. ":" .. name .. ":" .. table.concat(parts, "&") .. (if self then ":/" else "" end)
end

--- The tokens, and the state at every cut, that the HTML standard's
--- tokenizer states make of `input` starting in `initial`. Character
--- references are not decoded (so are read as text, which they are
--- everywhere but in what a token holds: a reference takes only letters,
--- digits, `#` and `;` and returns to the state it began in, so it moves
--- no state the tracker follows, and a slot inside one is escaped text
--- there as anywhere), and a doctype is one state to
--- its `>`, which every one of the standard's doctype states ends at.
local function tokenize(input: string, initial: string, last_tag: string): Run
  local n = #input
  local tokens: mut {string} = {}
  local states: mut {string} = {}
  local attr_at: mut {string} = {}
  local tails: mut {string} = {}
  local m: Machine = {
    state = initial, chars = "", last_tag = last_tag,
    tag_kind = "S", tag_name = "", tag_self = false, tag_attrs = {},
    attr_name = "", attr_value = "", attr_dup = false, has_attr = false,
    comment = "", temp = "", target = "", pi_data = "",
  }

  local function flush()
    if m.chars ~= "" then
      tokens[#tokens + 1] = "C:" .. m.chars
      m.chars = ""
    end
  end
  local function finish_attr()
    if m.has_attr and not m.attr_dup then
      m.tag_attrs[m.attr_name] = m.attr_value
    end
    m.has_attr, m.attr_dup = false, false
  end
  local function emit_tag()
    finish_attr()
    flush()
    if m.tag_kind == "S" then
      m.last_tag = m.tag_name
      table.insert(tokens, tag_text("S", m.tag_name, m.tag_attrs, m.tag_self))
    else
      tokens[#tokens + 1] = "E:" .. m.tag_name
    end
  end
  local function new_tag(kind: string)
    m.tag_kind, m.tag_name, m.tag_self, m.tag_attrs = kind, "", false, {}
    m.has_attr, m.attr_dup = false, false
  end
  local function new_attr(first: string)
    finish_attr()
    m.attr_name, m.attr_value, m.has_attr = first, "", true
    m.attr_dup = m.tag_attrs[first] ~= nil
  end
  local function emit_comment()
    flush()
    tokens[#tokens + 1] = "M:" .. m.comment
    m.comment = ""
  end
  local function appropriate(): boolean
    return m.tag_kind == "E" and m.tag_name == m.last_tag
  end

  --- Reads `c` in the current state; true when the state it left must
  --- read `c` again.
  local function step(c: string): boolean
    local s = m.state
    if s == "data" then
      if c == "<" then m.state = "tag_open" else m.chars = m.chars .. c end
    elseif s == "rcdata" or s == "rawtext" or s == "script" then
      if c == "<" then m.state = s .. "_lt" else m.chars = m.chars .. c end
    elseif s == "rcdata_lt" or s == "rawtext_lt" or s == "script_lt" then
      local back = s:sub(1, -4)
      if c == "/" then
        m.temp, m.state = "", back .. "_end_open"
      elseif c == "!" and back == "script" then
        m.chars = m.chars .. "<!"
        m.state = "script_escape_start"
      else
        m.chars = m.chars .. "<"
        m.state = back
        return true
      end
    elseif s:find("_end_open$") then
      local back = s:sub(1, -10)
      if is_alpha(c) then
        new_tag("E")
        m.state = back .. "_end_name"
        return true
      end
      m.chars = m.chars .. "</"
      m.state = back
      return true
    elseif s:find("_end_name$") then
      local back = s:sub(1, -10)
      if is_space(c) and appropriate() then
        m.state = "before_attr_name"
      elseif c == "/" and appropriate() then
        m.state = "self_closing"
      elseif c == ">" and appropriate() then
        emit_tag()
        m.state = "data"
      elseif is_alpha(c) then
        m.tag_name = m.tag_name .. c:lower()
        m.temp = m.temp .. c
      else
        m.chars = m.chars .. "</" .. m.temp
        m.state = back
        return true
      end
    elseif s == "plaintext" then
      m.chars = m.chars .. c
    elseif s == "script_escape_start" then
      if c == "-" then
        m.chars = m.chars .. c
        m.state = "script_escape_start_dash"
      else
        m.state = "script"
        return true
      end
    elseif s == "script_escape_start_dash" then
      if c == "-" then
        m.chars = m.chars .. c
        m.state = "script_escaped_dash_dash"
      else
        m.state = "script"
        return true
      end
    elseif s == "script_escaped" then
      if c == "-" then
        m.chars = m.chars .. c
        m.state = "script_escaped_dash"
      elseif c == "<" then
        m.state = "script_escaped_lt"
      else
        m.chars = m.chars .. c
      end
    elseif s == "script_escaped_dash" then
      if c == "-" then
        m.chars = m.chars .. c
        m.state = "script_escaped_dash_dash"
      elseif c == "<" then
        m.state = "script_escaped_lt"
      else
        m.chars = m.chars .. c
        m.state = "script_escaped"
      end
    elseif s == "script_escaped_dash_dash" then
      if c == "-" then
        m.chars = m.chars .. c
      elseif c == "<" then
        m.state = "script_escaped_lt"
      elseif c == ">" then
        m.chars = m.chars .. c
        m.state = "script"
      else
        m.chars = m.chars .. c
        m.state = "script_escaped"
      end
    elseif s == "script_escaped_lt" then
      if c == "/" then
        m.temp, m.state = "", "script_escaped_end_open"
      elseif is_alpha(c) then
        m.temp = ""
        m.chars = m.chars .. "<"
        m.state = "script_double_escape_start"
        return true
      else
        m.chars = m.chars .. "<"
        m.state = "script_escaped"
        return true
      end
    elseif s == "script_double_escape_start" then
      if is_space(c) or c == "/" or c == ">" then
        m.state = if m.temp == "script" then "script_double_escaped" else "script_escaped" end
        m.chars = m.chars .. c
      elseif is_alpha(c) then
        m.temp = m.temp .. c:lower()
        m.chars = m.chars .. c
      else
        m.state = "script_escaped"
        return true
      end
    elseif s == "script_double_escaped" then
      m.chars = m.chars .. c
      if c == "-" then
        m.state = "script_double_escaped_dash"
      elseif c == "<" then
        m.state = "script_double_escaped_lt"
      end
    elseif s == "script_double_escaped_dash" then
      m.chars = m.chars .. c
      if c == "-" then
        m.state = "script_double_escaped_dash_dash"
      elseif c == "<" then
        m.state = "script_double_escaped_lt"
      else
        m.state = "script_double_escaped"
      end
    elseif s == "script_double_escaped_dash_dash" then
      m.chars = m.chars .. c
      if c == "<" then
        m.state = "script_double_escaped_lt"
      elseif c == ">" then
        m.state = "script"
      elseif c ~= "-" then
        m.state = "script_double_escaped"
      end
    elseif s == "script_double_escaped_lt" then
      if c == "/" then
        m.temp = ""
        m.chars = m.chars .. c
        m.state = "script_double_escape_end"
      else
        m.state = "script_double_escaped"
        return true
      end
    elseif s == "script_double_escape_end" then
      if is_space(c) or c == "/" or c == ">" then
        m.state = if m.temp == "script" then "script_escaped" else "script_double_escaped" end
        m.chars = m.chars .. c
      elseif is_alpha(c) then
        m.temp = m.temp .. c:lower()
        m.chars = m.chars .. c
      else
        m.state = "script_double_escaped"
        return true
      end
    elseif s == "tag_open" then
      if c == "!" then
        m.state = "markup_declaration"
      elseif c == "/" then
        m.state = "end_tag_open"
      elseif is_alpha(c) then
        new_tag("S")
        m.state = "tag_name"
        return true
      elseif c == "?" then
        m.state = "pi_start"
      else
        m.chars = m.chars .. "<"
        m.state = "data"
        return true
      end
    elseif s == "end_tag_open" then
      if is_alpha(c) then
        new_tag("E")
        m.state = "tag_name"
        return true
      elseif c == ">" then
        m.state = "data"
      else
        m.comment = ""
        m.state = "bogus_comment"
        return true
      end
    elseif s == "tag_name" then
      if is_space(c) then
        m.state = "before_attr_name"
      elseif c == "/" then
        m.state = "self_closing"
      elseif c == ">" then
        emit_tag()
        m.state = "data"
      else
        m.tag_name = m.tag_name .. c:lower()
      end
    elseif s == "before_attr_name" then
      if c == "/" or c == ">" then
        m.state = "after_attr_name"
        return true
      elseif c == "=" then
        new_attr("=")
        m.state = "attr_name"
      elseif not is_space(c) then
        new_attr("")
        m.state = "attr_name"
        return true
      end
    elseif s == "attr_name" then
      if is_space(c) or c == "/" or c == ">" then
        m.state = "after_attr_name"
        return true
      elseif c == "=" then
        m.state = "before_attr_value"
      else
        m.attr_name = m.attr_name .. c:lower()
        m.attr_dup = m.tag_attrs[m.attr_name] ~= nil
      end
    elseif s == "after_attr_name" then
      if c == "/" then
        m.state = "self_closing"
      elseif c == "=" then
        m.state = "before_attr_value"
      elseif c == ">" then
        emit_tag()
        m.state = "data"
      elseif not is_space(c) then
        new_attr("")
        m.state = "attr_name"
        return true
      end
    elseif s == "before_attr_value" then
      if c == '"' then
        m.state = "value_dq"
      elseif c == "'" then
        m.state = "value_sq"
      elseif c == ">" then
        emit_tag()
        m.state = "data"
      elseif not is_space(c) then
        m.state = "value_unq"
        return true
      end
    elseif s == "value_dq" or s == "value_sq" then
      if c == (if s == "value_dq" then '"' else "'" end) then
        m.state = "after_value"
      else
        m.attr_value = m.attr_value .. c
      end
    elseif s == "value_unq" then
      if is_space(c) then
        m.state = "before_attr_name"
      elseif c == ">" then
        emit_tag()
        m.state = "data"
      else
        m.attr_value = m.attr_value .. c
      end
    elseif s == "after_value" then
      if is_space(c) then
        m.state = "before_attr_name"
      elseif c == "/" then
        m.state = "self_closing"
      elseif c == ">" then
        emit_tag()
        m.state = "data"
      else
        m.state = "before_attr_name"
        return true
      end
    elseif s == "self_closing" then
      if c == ">" then
        m.tag_self = true
        emit_tag()
        m.state = "data"
      else
        m.state = "before_attr_name"
        return true
      end
    elseif s == "pi_start" then
      if is_alpha(c) then
        m.target, m.pi_data = "", ""
        m.state = "pi_target"
        return true
      end
      m.comment = "?"
      m.state = "bogus_comment"
      return true
    elseif s == "pi_target" then
      if is_space(c) then
        m.state = "pi_data"
      elseif c == ">" then
        flush()
        tokens[#tokens + 1] = "P:" .. m.target .. ":"
        m.state = "data"
      else
        m.target = m.target .. c
      end
    elseif s == "pi_data" then
      if c == "?" then
        m.state = "pi_question"
      elseif c == ">" then
        flush()
        tokens[#tokens + 1] = "P:" .. m.target .. ":" .. m.pi_data
        m.state = "data"
      else
        m.pi_data = m.pi_data .. c
      end
    elseif s == "pi_question" then
      if c == ">" then
        flush()
        tokens[#tokens + 1] = "P:" .. m.target .. ":" .. m.pi_data
        m.state = "data"
      elseif c == "?" then
        m.pi_data = m.pi_data .. "?"
      else
        m.pi_data = m.pi_data .. "?" .. c
        m.state = "pi_data"
      end
    elseif s == "bogus_comment" then
      if c == ">" then
        emit_comment()
        m.state = "data"
      else
        m.comment = m.comment .. c
      end
    elseif s == "doctype" then
      if c == ">" then
        flush()
        tokens[#tokens + 1] = "D"
        m.state = "data"
      end
    elseif s == "comment_start" then
      if c == "-" then
        m.state = "comment_start_dash"
      elseif c == ">" then
        emit_comment()
        m.state = "data"
      else
        m.state = "comment"
        return true
      end
    elseif s == "comment_start_dash" then
      if c == "-" then
        m.state = "comment_end"
      elseif c == ">" then
        emit_comment()
        m.state = "data"
      else
        m.comment = m.comment .. "-"
        m.state = "comment"
        return true
      end
    elseif s == "comment" then
      if c == "<" then
        m.comment = m.comment .. c
        m.state = "comment_lt"
      elseif c == "-" then
        m.state = "comment_end_dash"
      else
        m.comment = m.comment .. c
      end
    elseif s == "comment_lt" then
      if c == "!" then
        m.comment = m.comment .. c
        m.state = "comment_lt_bang"
      elseif c == "<" then
        m.comment = m.comment .. c
      else
        m.state = "comment"
        return true
      end
    elseif s == "comment_lt_bang" then
      if c == "-" then
        m.state = "comment_lt_bang_dash"
      else
        m.state = "comment"
        return true
      end
    elseif s == "comment_lt_bang_dash" then
      if c == "-" then
        m.state = "comment_lt_bang_dash_dash"
      else
        m.state = "comment_end_dash"
        return true
      end
    elseif s == "comment_lt_bang_dash_dash" then
      m.state = "comment_end"
      return true
    elseif s == "comment_end_dash" then
      if c == "-" then
        m.state = "comment_end"
      else
        m.comment = m.comment .. "-"
        m.state = "comment"
        return true
      end
    elseif s == "comment_end" then
      if c == ">" then
        emit_comment()
        m.state = "data"
      elseif c == "!" then
        m.state = "comment_end_bang"
      elseif c == "-" then
        m.comment = m.comment .. "-"
      else
        m.comment = m.comment .. "--"
        m.state = "comment"
        return true
      end
    elseif s == "comment_end_bang" then
      if c == "-" then
        m.comment = m.comment .. "--!"
        m.state = "comment_end_dash"
      elseif c == ">" then
        emit_comment()
        m.state = "data"
      else
        m.comment = m.comment .. "--!"
        m.state = "comment"
        return true
      end
    else
      error("no state " .. s)
    end
    return false
  end

  local function tail(): string
    if m.state == "rcdata_lt" then
      return "<"
    elseif m.state == "rcdata_end_open" then
      return "</"
    elseif m.state == "rcdata_end_name" then
      return "</" .. m.temp
    end
    return ""
  end

  states[1] = m.state
  attr_at[1] = ""
  tails[1] = ""
  local i = 1
  while i <= n do
    local c = input:sub(i, i)
    if m.state == "markup_declaration" then
      -- The standard looks ahead here: `--`, `DOCTYPE` or `[CDATA[` are
      -- taken whole; the cuts inside them stand in this state.
      local width = 0
      local next_state = "bogus_comment"
      m.comment = ""
      if input:sub(i, i + 1) == "--" then
        width, next_state = 2, "comment_start"
      elseif input:sub(i, i + 6):upper() == "DOCTYPE" then
        width, next_state = 7, "doctype"
      elseif input:sub(i, i + 6) == "[CDATA[" then
        -- Outside foreign content, which the tests never reach.
        width, next_state, m.comment = 7, "bogus_comment", "[CDATA["
      end
      for k = 1, width - 1 do
        states[i + k] = "markup_declaration"
        attr_at[i + k] = ""
        tails[i + k] = ""
      end
      if width > 0 then
        i = i + width
        m.state = next_state
        states[i] = m.state
        attr_at[i] = ""
        tails[i] = ""
      else
        m.state = next_state
      end
    else
      while step(c) do
      end
      i = i + 1
      states[i] = m.state
      attr_at[i] = (m.state == "value_dq" or m.state == "value_sq") and m.attr_name or ""
      tails[i] = tail()
    end
  end

  -- The end of the input, in whatever state it leaves the tokenizer:
  -- what a state held back is text, and an open comment or doctype ends.
  local s = m.state
  if s == "tag_open" or s == "rcdata_lt" or s == "rawtext_lt" or s == "script_lt" or
      s == "script_escaped_lt" then
    m.chars = m.chars .. "<"
  elseif s:find("_end_open$") then
    m.chars = m.chars .. "</"
  elseif s == "end_tag_open" then
    m.chars = m.chars .. "</"
  elseif s:find("_end_name$") then
    m.chars = m.chars .. "</" .. m.temp
  elseif s == "markup_declaration" then
    m.comment = ""
    emit_comment()
  elseif s == "bogus_comment" or s:find("^comment") then
    emit_comment()
  elseif s == "doctype" then
    flush()
    tokens[#tokens + 1] = "D"
  end
  flush()
  return { tokens = tokens, states = states, attrs = attr_at, tails = tails }
end

local HEAD <const> = "{{type T from m.t}}\n"

--- The start tags a browser's tree builder answers with a tokenizer state
--- of its own (or, in foreign content, other rules), which the test data
--- does not model: the input after one is not held to the tokenizer's.
local SWITCHING <const>: {string} = {
  "textarea", "title", "script", "style", "xmp", "iframe", "noembed", "noframes", "noscript",
  "plaintext", "svg", "math", "select",
}

--- The tokenizer's states for the names the cases give.
local STATES <const>: {string: string} = {
  ["Data state"] = "data", ["RCDATA state"] = "rcdata", ["RAWTEXT state"] = "rawtext",
  ["Script data state"] = "script", ["PLAINTEXT state"] = "plaintext",
}

--- The element whose start tag puts the tree builder's tokenizer in the
--- state, by default and in the ones a case may say its last start tag
--- was.
local WRAPPERS <const>: {string: {string: boolean}} = {
  rcdata = { textarea = true, title = true },
  rawtext = { xmp = true, iframe = true, noembed = true, noframes = true, style = true },
  script = { script = true },
  plaintext = { plaintext = true },
}
local DEFAULT_WRAPPER <const>: {string: string} = {
  rcdata = "textarea", rawtext = "xmp", script = "script", plaintext = "plaintext",
}

--- The attributes that take one URL, as the HTML standard lists them: a
--- slot in a value of one is a URL, and so is one in `archive`, which
--- the list does not hold yet (once #2737 merges it does, and it joins
--- this list).
local URL_ATTRS <const>: {string: boolean} = {
  href = true, src = true, action = true, formaction = true, cite = true, data = true,
  poster = true, background = true, manifest = true, longdesc = true, codebase = true,
  profile = true, icon = true, lowsrc = true, dynsrc = true, classid = true, ["xlink:href"] = true,
}

--- What a slot is, from the Teal the template compiles to.
local function kind_of(out: string): string
  for _, kind in ipairs({ "text", "rtext", "ftext", "attr", "url", "part" }) do
    if out:find("parts[#parts + 1] = _" .. kind .. "(", 1, true) then
      return kind
    end
  end
  error("no slot in " .. out)
end

--- The attributes whose value a slot may never be in, by name: handlers,
--- and the ones that hold code or a list of URLs.
local function is_code(attr: string): boolean
  return attr:sub(1, 2) == "on" or attr == "style" or attr == "srcdoc" or attr == "srcset" or
    attr == "imagesrcset" or attr == "ping"
end

--- Whether a slot of `kind` may stand where the tokenizer is in `state`
--- (reading the attribute `attr`, when in a quoted value): in text, one
--- the escaper for text is right for (`ftext` too, which takes less); in
--- RCDATA, the one for it; in a quoted attribute value, a URL's where the
--- attribute takes one and an attribute's elsewhere, and never in one
--- that is code; nowhere else.
local function allowed(state: string, kind: string, attr: string, tail: string, tag: string): boolean
  if state == "data" then
    return kind == "text" or kind == "ftext"
  elseif state == "rcdata" then
    return kind == "rtext"
  elseif state == "rcdata_lt" or state == "rcdata_end_open" or state == "rcdata_end_name" then
    -- A slot there is escaped text, which can only add to the name of an
    -- end tag: it is safe unless that name may become the element's.
    return kind == "rtext" and ("</" .. tag):sub(1, #tail) ~= tail:lower()
  elseif state == "value_dq" or state == "value_sq" then
    if is_code(attr) then
      return false
    elseif URL_ATTRS[attr] then
      return kind == "url" or kind == "part"
    end
    return kind == "attr" or ((kind == "url" or kind == "part") and attr == "archive")
  end
  return false
end

--- Where `input` first has a switching start tag after `from`.
local function switches(input: string, from: integer): boolean
  local rest = input:sub(from + 1):lower()
  for _, name in ipairs(SWITCHING) do
    if rest:find("<" .. name, 1, true) then
      return true
    end
  end
  return false
end

--- What closes the markup a case leaves open, tried in order: the end of
--- a tag, a quoted value, a comment, and then the end tag of the wrapper.
local MARKUP_CLOSERS <const>: {string} = { "", ">", "\">", "'>", "-->" }

--- Text that, put after `input` in its wrapper, leaves the template in
--- plain text (an `html` template must end there), or nil if none of the
--- ones tried does. What follows a slot cannot change where the slot
--- stands, so any that compiles will do, and one is found with no slot.
local function closer_for(wrapper: string, input: string): string?
  local tag = wrapper:match("^<(%a+)>$")
  for _, base in ipairs(MARKUP_CLOSERS) do
    for _, tail in ipairs({ "", if tag then ("</" .. tag .. ">") else "" end }) do
      local closer = base .. tail
      if Template.compile(HEAD .. wrapper .. input .. closer, "t.tmpl") ~= nil then
        return closer
      end
    end
  end
  return nil
end

--- What the checks reached, so the test can hold a floor under them.
local record Reach
  mut cases: integer
  mut unclosed: integer
  mut closers: integer
  mut validated: integer
  mut positions: integer
  accepted: mut {string: integer}
  failures: mut {string}
end

--- The tokens a case expects, as `tokenize` writes them.
local function expected_tokens(output: {any}): {string}
  local tokens: mut {string} = {}
  local chars = ""
  for _, raw in ipairs(output) do
    local item = raw as {any}
    local kind = item[1] as string
    if kind == "Character" then
      chars = chars .. (item[2] as string)
    else
      if chars ~= "" then
        tokens[#tokens + 1] = "C:" .. chars
        chars = ""
      end
      if kind == "StartTag" then
        local attrs: mut {string: string} = {}
        for k, v in pairs(item[3] as {string: any}) do
          attrs[k] = v as string
        end
        tokens[#tokens + 1] = tag_text("S", item[2] as string, attrs, item[4] == true)
      elseif kind == "EndTag" then
        tokens[#tokens + 1] = "E:" .. (item[2] as string)
      elseif kind == "ProcessingInstruction" then
        tokens[#tokens + 1] = "P:" .. (item[2] as string) .. ":" .. (item[3] as string)
      elseif kind == "Comment" then
        tokens[#tokens + 1] = "M:" .. (item[2] as string)
      else
        tokens[#tokens + 1] = "D"
      end
    end
  end
  if chars ~= "" then
    tokens[#tokens + 1] = "C:" .. chars
  end
  return tokens
end

local function same_tokens(a: {string}, b: {string}): boolean
  if #a ~= #b then
    return false
  end
  for k = 1, #a do
    if a[k] ~= b[k] then
      return false
    end
  end
  return true
end

local function check_case(
    description: string, input: string, initial: string, last_tag: string?,
    output: {any}, reach: Reach)
  local state = STATES[initial]
  if state == nil or input:find("{{", 1, true) or input:find("[&%z\r]") then
    return
  end
  local wrapper, last = "", last_tag
  -- A case whose last start tag is not one the state goes with (RCDATA
  -- after `<xmp>`) is read after the wrapper's own, which only changes
  -- what its tokens are when its input holds that tag's end tag: so it
  -- stands only if its tokens are the same.
  local borrowed = false
  if state ~= "data" then
    local named: string
    if last ~= nil and WRAPPERS[state][last] then
      named = last
    else
      borrowed = last ~= nil
      named = DEFAULT_WRAPPER[state]
    end
    last = named
    wrapper = "<" .. named .. ">"
  end
  reach.cases = reach.cases + 1
  local run = tokenize(input, state, last or "")
  if not same_tokens(run.tokens, expected_tokens(output)) then
    if borrowed then
      return
    end
    table.insert(reach.failures, ("reference tokenizer: %s (%s): %q"):format(description, initial, input))
    return
  end
  -- The input after the end tag that leaves RCDATA, RAWTEXT or script
  -- data is read by a tree builder that follows the tags in it.
  local from = 0
  if state ~= "data" then
    from = #input
    for at = 0, #input do
      if run.states[at + 1]:sub(1, #state) ~= state then
        from = at
        break
      end
    end
  end
  if switches(input, from) then
    return
  end
  local closer = closer_for(wrapper, input)
  if closer == nil then
    -- Nothing leaves the template in text (PLAINTEXT never ends).
    reach.unclosed = reach.unclosed + 1
    return
  end
  reach.validated = reach.validated + 1
  if closer ~= "" then
    reach.closers = reach.closers + 1
  end
  for at = 0, #input do
    local next_byte = input:byte(at + 1)
    if next_byte == nil or next_byte < 0x80 or next_byte >= 0xC0 then
      local template = HEAD .. wrapper .. input:sub(1, at) .. "{{.x}}" .. input:sub(at + 1) .. closer
      local out = Template.compile(template, "t.tmpl")
      reach.positions = reach.positions + 1
      if out ~= nil then
        local kind = kind_of(out)
        local where = run.states[at + 1]
        local key = where .. "/" .. kind
        reach.accepted[key] = (reach.accepted[key] or 0) + 1
        if not allowed(where, kind, run.attrs[at + 1], run.tails[at + 1], last or "") then
          table.insert(reach.failures, ("%s (%s): slot %s at %d of %q: tokenizer is in %s"):format(
            description, initial, kind, at, input, where))
        end
      end
    end
  end
end

local function test_a_slot_is_accepted_only_where_the_tokenizer_is_in_the_state_for_it()
  local reach: Reach = { cases = 0, unclosed = 0, closers = 0, validated = 0, positions = 0, accepted = {}, failures = {} }
  local files = assert(Fs.list(DIRECTORY))
  for _, file in ipairs(files) do
    if file:find("%.test$") then
      local text = assert(Fs.read(DIRECTORY .. "/" .. file))
      local document = assert(Json.decode(text, { lone_surrogates = true })) as {string: any}
      -- The XML-violation cases give the tokens of a coercing consumer.
      document.xmlViolationTests = nil
      for _, list in pairs(document) do
        for _, raw in ipairs(list as {any}) do
          local case = raw as {string: any}
          local input = case.input
          local output = case.output
          if input is string and output is {any} and case.doubleEscaped == nil then
            local states = case.initialStates
            local initials: {string} = {}
            if states is {string} then
              initials = states
            else
              initials = { "Data state" }
            end
            local last = case.lastStartTag
            for _, initial in ipairs(initials) do
              check_case(tostring(case.description), input, initial, last is string and last or nil,
                output, reach)
            end
          end
        end
      end
    end
  end
  assert(#reach.failures == 0, tostring(#reach.failures) .. " failures:\n" ..
      table.concat(reach.failures, "\n", 1, math.min(#reach.failures, 30)))
  local summary: mut {string} = {}
  for key, count in pairs(reach.accepted) do
    summary[#summary + 1] = key .. "=" .. tostring(count)
  end
  table.sort(summary)
  print(("tokenizer: %d cases, %d validated, %d unclosed, %d positions; accepted %s"):format(
    reach.cases, reach.validated, reach.unclosed, reach.positions, table.concat(summary, " ")))
  -- It reaches 2148 cases, 2086 validated, 21803 positions, and accepts
  -- 2841 slots of text, 134 of rtext, 21 of rtext in the name of an end
  -- tag that cannot be the element's, and 209 in attributes.
  assert(reach.cases >= 2050 and reach.validated >= 2050, "only " .. tostring(reach.validated) .. " cases were validated")
  -- The template's ending is held to: many cases need a closer to compile.
  assert(reach.closers >= 1000, "only " .. tostring(reach.closers) .. " cases needed a closer")
  assert(reach.positions >= 20500, "only " .. tostring(reach.positions) .. " positions were checked")
  local attrs = (reach.accepted["value_dq/attr"] or 0) + (reach.accepted["value_sq/attr"] or 0)
  assert((reach.accepted["data/text"] or 0) >= 2600 and (reach.accepted["rcdata/rtext"] or 0) >= 120 and
      (reach.accepted["rcdata_end_name/rtext"] or 0) >= 15 and attrs >= 190,
    "too few slots were accepted: " .. table.concat(summary, " "))
end
