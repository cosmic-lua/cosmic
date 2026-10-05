--- [`cosmic.template`]'s markup tracker against the HTML parser's
--- tree-construction tests (web-platform-tests' copy of html5lib's):
--- wherever the tracker accepts a slot, the tree the standard builds from
--- the input must put the text, or the attribute value, there in a place
--- that slot's escaping is right for.
---
--- A case gives an input and the tree built from it, which says nothing
--- of where each byte of the input went. So the test maps a position
--- only where the tree leaves no doubt: a literal (a text node, a comment,
--- a CDATA section, or a quoted attribute value) that occurs once in the
--- input, has no character reference, and stands between `>` and `<`
--- (`<!--` and `-->`, `<![CDATA[` and `]]>`, `name="` and `"`). A cut
--- inside it is a place the tree names the ancestors of, and a slot the
--- tracker accepts there must be:
---
--- - in text: `text` for a parent that is not raw text (`script` and
---   `style` in any namespace, `xmp` and the like in HTML) or RCDATA,
---   and for none of the places the tracker refuses to follow, which are
---   the elements the browser reads HTML in inside `<svg>` or `<math>`
---   and an HTML element inside one; `rtext` only for an HTML `<textarea>`
---   or `<title>`;
--- - in a comment or CDATA: no slot at all;
--- - in a quoted attribute value: a URL where the attribute takes one, an
---   attribute's elsewhere, and none for code (`on...`, `style`).
---
--- A refusal is never wrong, so it is never checked.
local Fs = require("cosmic.fs")
local Template = require("cosmic.template")
local Test = require("cosmic.test")

Test.policy{ grants = { { path = "vendor/wpt-html-parsing/html/syntax/parsing/resources", letters = "r" } } }

--- Where the parser tests are: the one place a change of source names.
local DIRECTORY <const> = "vendor/wpt-html-parsing/html/syntax/parsing/resources"

local HEAD <const> = "{{type T from m.t}}\n"

--- The elements, in HTML, whose text a browser does not read as markup
--- and which a slot of text must not be in: the tracker has no escaper
--- for them (`noscript` is raw with scripting on). `script` and `style`
--- are raw in SVG as well.
local RAW <const>: {string: boolean} = {
  script = true, style = true, xmp = true, iframe = true, noembed = true, noframes = true,
  plaintext = true, noscript = true,
}

--- The elements that hold RCDATA, which a slot takes as `rtext`.
local RCDATA <const>: {string: boolean} = { textarea = true, title = true }

--- The elements, inside `<svg>` or `<math>`, that a browser reads HTML in,
--- so the tracker follows nothing past them.
local INTEGRATION <const>: {string: boolean} = {
  foreignobject = true, desc = true, title = true, ["annotation-xml"] = true, mi = true, mo = true,
  mn = true, ms = true, mtext = true,
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

--- The attributes whose value a slot may never be in, by name: handlers,
--- and the ones that hold code or a list of URLs.
local function is_code(attr: string): boolean
  return attr:sub(1, 2) == "on" or attr == "style" or attr == "srcdoc" or attr == "srcset" or
    attr == "imagesrcset" or attr == "ping"
end

--- A case of a `.dat` file.
local record Case
  input: string
  tree: {string}
  --- Whether the case is not a plain document parse (a fragment's
  --- context, scripting on or off), which its tree is made under.
  other: boolean
end

--- The cases of the text of a `.dat` file.
local function cases_of(text: string): {Case}
  local cases: {Case} = {}
  local current: Case | nil = nil
  local section = ""
  local data: {string} = {}
  local function finish()
    if current ~= nil then
      current.input = table.concat(data, "\n")
      while #current.tree > 0 and current.tree[#current.tree] == "" do
        current.tree[#current.tree] = nil
      end
      cases[#cases + 1] = current
    end
  end
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line == "#data" then
      finish()
      current = { input = "", tree = {}, other = false }
      data = {}
      section = "data"
    elseif line == "#errors" or line == "#new-errors" then
      section = "errors"
    elseif line == "#document" then
      section = "document"
    elseif line == "#document-fragment" or line == "#script-on" or line == "#script-off" then
      if current ~= nil then
        current.other = true
      end
      section = "other"
    elseif current ~= nil then
      if section == "data" then
        data[#data + 1] = line
      elseif section == "document" then
        current.tree[#current.tree + 1] = line
      end
    end
  end
  finish()
  -- A data block ends at its `#errors`, after the newline that precedes it.
  return cases
end

--- The number of times `needle` occurs in `text`, overlaps counted.
local function count(text: string, needle: string): integer
  local found, from = 0, 1
  while true do
    local at = text:find(needle, from, true)
    if at == nil then
      return found
    end
    found = found + 1
    from = at + 1
  end
end

--- What a slot is, from the Teal the template compiles to.
local function kind_of(out: string): string
  for _, kind in ipairs({ "text", "rtext", "attr", "url" }) do
    if out:find("parts[#parts + 1] = _" .. kind .. "(", 1, true) then
      return kind
    end
  end
  error("no slot in " .. out)
end

--- The cuts of a text of `length` bytes to try: both ends and a few
--- between, the same ones every run.
local function cuts(length: integer): {integer}
  local list: {integer} = {}
  local steps = math.min(length, 5)
  local last = -1
  for step = 0, steps do
    local at = (length * step) // steps
    if at ~= last then
      list[#list + 1] = at
      last = at
    end
  end
  return list
end

--- A line of the tree: how deep it is and what it says.
local function split(line: string): integer, string
  local indent, body = line:match("^| ( *)(.*)$")
  if indent == nil then
    return -1, line
  end
  return #indent // 2, body
end

--- What a line of the tree says, less its depth.
local function body_of(line: string): string
  local _, body = split(line)
  return body
end

--- An element of the tree: its name (lower case) and whether it is foreign
--- (`<svg x>` and `<math x>` in the dump, against `<x>` in HTML).
local record Element
  name: string
  foreign: boolean
end

--- The elements a node at line `at`, `depth` deep, is inside, nearest first.
local function ancestors(tree: {string}, at: integer, depth: integer): {Element}
  local list: {Element} = {}
  local below = depth
  for up = at - 1, 1, -1 do
    local d, body = split(tree[up])
    if d >= 0 and d < below then
      below = d
      local ns, name = body:match("^<(%a+) ([^>]+)>$")
      if ns == "svg" or ns == "math" then
        list[#list + 1] = { name = name:lower(), foreign = true }
      else
        local plain = body:match("^<([^ >]+)>$")
        if plain ~= nil then
          list[#list + 1] = { name = plain, foreign = false }
        end
      end
    end
  end
  return list
end

--- The element an attribute line belongs to.
local function owner_of(tree: {string}, at: integer, depth: integer): Element | nil
  return ancestors(tree, at, depth)[1]
end

--- Why a slot of `kind` may not be in the text of an element with these
--- ancestors, or nil if it may.
local function text_trouble(kind: string, up: {Element}): string | nil
  local parent = up[1]
  if parent == nil then
    return nil
  end
  if kind == "rtext" then
    if parent.foreign or not RCDATA[parent.name] then
      return "rtext but it is not in an HTML textarea or title"
    end
    return nil
  elseif kind ~= "text" then
    return kind .. " in text"
  end
  if parent.name == "script" or parent.name == "style" then
    return "text in raw text"
  elseif not parent.foreign and (RAW[parent.name] or RCDATA[parent.name]) then
    return "text in raw text or RCDATA"
  end
  local html_below = false
  for _, element in ipairs(up) do
    if element.foreign then
      if INTEGRATION[element.name] then
        return "text in or under " .. element.name .. ", where a browser reads HTML"
      elseif html_below then
        return "text in an HTML element inside foreign content"
      end
    else
      html_below = true
    end
  end
  return nil
end

local record Reach
  cases: integer
  unclosed: integer
  texts: integer
  values: integer
  hidden: integer
  positions: integer
  accepted: {string: integer}
  failures: {string}
end

--- The elements, in a document's tree, that are foreign: the names a
--- template could have to close to end in text.
local function foreign_names(tree: {string}): {string}
  local seen: {string: boolean} = {}
  local names: {string} = {}
  for _, line in ipairs(tree) do
    local name = body_of(line):match("^<%a+ ([^>]+)>$")
    if name ~= nil and not seen[name] and #names < 5 then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  return names
end

--- What closes the markup a case leaves open, tried in order: the end of
--- a tag, a quoted value, a comment, and then end tags.
local MARKUP_CLOSERS <const>: {string} = { "", ">", "\">", "'>", "-->" }
local END_TAGS <const>: {string} = {
  "", "</svg>", "</math>", "</textarea>", "</title>", "</script>", "</style>", "</select>",
  "</noscript>", "</xmp>", "</iframe>", "</noembed>", "</noframes>",
}

--- Text that, put after `input`, leaves the template in plain text (an
--- `html` template must end there), or nil if none of the ones tried does.
--- What follows a slot cannot change where the slot stands, so any that
--- compiles will do, and one is found with no slot.
local function closer_for(input: string, tree: {string}): string | nil
  local tails: {string} = {}
  for _, tail in ipairs(END_TAGS) do
    tails[#tails + 1] = tail
  end
  local names = foreign_names(tree)
  for _, root in ipairs({ "svg", "math" }) do
    for _, one in ipairs(names) do
      tails[#tails + 1] = "</" .. one .. "></" .. root .. ">"
      for _, two in ipairs(names) do
        tails[#tails + 1] = "</" .. one .. "></" .. two .. "></" .. root .. ">"
      end
    end
  end
  for _, base in ipairs(MARKUP_CLOSERS) do
    for _, tail in ipairs(tails) do
      local closer = base .. tail
      if Template.compile(HEAD .. input .. closer, "t.tmpl") ~= nil then
        return closer
      end
    end
  end
  return nil
end

--- Compiles `input` cut at each of `cut`s from `start` with a slot, closed
--- by `closer`, passing what the slot is, if it is not refused, to `judge`.
local function try(input: string, closer: string, start: integer, length: integer, reach: Reach,
                   judge: function(kind: string, at: integer))
  for _, cut in ipairs(cuts(length)) do
    local at = start + cut
    local out = Template.compile(HEAD .. input:sub(1, at) .. "{{.x}}" .. input:sub(at + 1) .. closer, "t.tmpl")
    reach.positions = reach.positions + 1
    if out ~= nil then
      judge(kind_of(out), at)
    end
  end
end

--- Notes that a slot of `kind` was accepted at a place of this `label`.
local function note(reach: Reach, label: string, kind: string)
  local key = label .. " " .. kind
  reach.accepted[key] = (reach.accepted[key] or 0) + 1
end

local function fail(reach: Reach, file: string, kind: string, at: integer, input: string, what: string)
  reach.failures[#reach.failures + 1] = ("%s: slot %s at %d of %q: %s"):format(file, kind, at, input, what)
end

local function check_case(file: string, case: Case, reach: Reach)
  local input, tree = case.input, case.tree
  if case.other or input:find("{{", 1, true) or input:find("[&%z\r]") then
    return
  end
  reach.cases = reach.cases + 1
  local document = table.concat(tree, "\n")
  -- The attribute lines of the tree by value: the name each is written
  -- with, or false when two differ.
  local named: {string: string | boolean} = {}
  for _, line in ipairs(tree) do
    local name, value = body_of(line):match('^([^%s="<]+ ?[^%s="<]*)="(.*)"$')
    if name ~= nil then
      named[value] = (named[value] == nil or named[value] == name) and name or false
    end
  end
  local closer: string | nil = nil
  local tried = false
  local function closed(): string | nil
    if not tried then
      tried = true
      closer = closer_for(input, tree)
      if closer == nil then
        reach.unclosed = reach.unclosed + 1
      end
    end
    return closer
  end
  for at, line in ipairs(tree) do
    local depth, body = split(line)
    local text = body:match('^"(.*)"$')
    local comment = body:match("^<!%-%- (.*) %-%->$")
    local name, value = body:match('^([^%s="<]+ ?[^%s="<]*)="(.*)"$')
    if text ~= nil and text ~= "" and #text > 2 and count(input, text) == 1 and count(document, text) == 1 then
      local start = input:find(text, 1, true) as integer
      local before = input:sub(start - 1, start - 1)
      local after = input:sub(start + #text, start + #text)
      local cdata = input:sub(start - 9, start - 1) == "<![CDATA[" and input:sub(start + #text, start + #text + 2) == "]]>"
      local use: string | nil = nil
      if cdata or ((before == ">" or start == 1) and (after == "<" or after == "")) then
        use = closed()
      end
      if use ~= nil then
        local up = ancestors(tree, at, depth)
        reach.texts = reach.texts + 1
        try(input, use, start - 1, #text, reach, function(kind: string, cut: integer)
          local parent = up[1]
          note(reach, (parent ~= nil and parent.foreign) and "foreign" or "html", kind)
          if cdata then
            fail(reach, file, kind, cut, input, "the tree has a CDATA section there")
          else
            local trouble = text_trouble(kind, up)
            if trouble ~= nil then
              fail(reach, file, kind, cut, input, ("%s (inside %s)"):format(trouble, parent ~= nil and parent.name or "nothing"))
            end
          end
        end)
      end
    elseif comment ~= nil and comment ~= "" and #comment > 2 and count(input, comment) == 1 and
        count(document, comment) == 1 then
      local start = input:find(comment, 1, true) as integer
      local use: string | nil = nil
      if input:sub(start - 4, start - 1) == "<!--" and input:sub(start + #comment, start + #comment + 2) == "-->" then
        use = closed()
      end
      if use ~= nil then
        reach.hidden = reach.hidden + 1
        try(input, use, start - 1, #comment, reach, function(kind: string, cut: integer)
          note(reach, "comment", kind)
          fail(reach, file, kind, cut, input, "the tree has a comment there")
        end)
      end
    elseif name ~= nil and value ~= "" and not value:find("[\"']") and count(input, value) == 1 and
        named[value] == name then
      local start = input:find(value, 1, true) as integer
      local quote = input:sub(start - 1, start - 1)
      local written = (name:gsub(" ", ":")):lower()
      local before = input:sub(start - 2 - #written, start - 2):lower()
      local use: string | nil = nil
      if (quote == '"' or quote == "'") and input:sub(start + #value, start + #value) == quote and
          before == written .. "=" and owner_of(tree, at, depth) ~= nil then
        use = closed()
      end
      if use ~= nil then
        reach.values = reach.values + 1
        try(input, use, start - 1, #value, reach, function(kind: string, cut: integer)
          note(reach, "value", kind)
          if is_code(written) then
            fail(reach, file, kind, cut, input, "the tree has the value of the code attribute " .. name)
          elseif URL_ATTRS[written] then
            if kind ~= "url" then
              fail(reach, file, kind, cut, input, "the tree has the value of the URL attribute " .. name)
            end
          elseif not (kind == "attr" or (kind == "url" and written == "archive")) then
            fail(reach, file, kind, cut, input, "the tree has the value of " .. name)
          end
        end)
      end
    end
  end
end

local function test_a_slot_is_accepted_only_where_the_tree_has_text_or_an_attribute_value_for_it()
  local reach: Reach = { cases = 0, unclosed = 0, texts = 0, values = 0, hidden = 0, positions = 0,
    accepted = {}, failures = {} }
  for _, file in ipairs((assert(Fs.list(DIRECTORY)))) do
    -- The scripted files give the tree a script's changes to it make.
    if file:find("%.dat$") and not file:find("^scripted_") then
      local text = assert(Fs.read(DIRECTORY .. "/" .. file))
      for _, case in ipairs(cases_of(text)) do
        check_case(file, case, reach)
      end
    end
  end
  assert(#reach.failures == 0, #reach.failures .. " failures:\n" ..
      table.concat(reach.failures, "\n", 1, math.min(#reach.failures, 30)))
  local summary: {string} = {}
  for key, count_of in pairs(reach.accepted) do
    summary[#summary + 1] = key .. "=" .. count_of
  end
  table.sort(summary)
  print(("tree: %d cases, %d texts, %d comments, %d values, %d positions; accepted %s"):format(
    reach.cases, reach.texts, reach.hidden, reach.values, reach.positions, table.concat(summary, " ")))
  -- It reaches 1534 cases, 680 texts, 32 comments, 75 values and 3944
  -- positions, and accepts 1934 slots of HTML text, 97 of rtext, 56 of
  -- foreign text, 109 in attributes and 17 in URLs.
  local accepted = reach.accepted
  assert(reach.cases >= 1400 and reach.texts >= 600 and reach.hidden >= 25 and reach.values >= 65 and
      reach.positions >= 3500, "only " .. reach.texts .. " texts and " .. reach.values .. " values were reached")
  assert((accepted["html text"] or 0) >= 1700 and (accepted["html rtext"] or 0) >= 85 and
      (accepted["foreign text"] or 0) >= 45 and (accepted["value attr"] or 0) >= 95 and
      (accepted["value url"] or 0) >= 14, "too few slots were accepted: " .. table.concat(summary, " "))
end
