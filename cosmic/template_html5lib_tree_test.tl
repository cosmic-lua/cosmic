--- [`cosmic.template`]'s markup tracker against the HTML parser's
--- tree-construction tests (web-platform-tests' copy of html5lib's):
--- wherever the tracker accepts a slot, the tree the standard builds from
--- the input must put the text, or the attribute value, there in a place
--- that slot's escaping is right for.
---
--- A case gives an input and the tree built from it, which says nothing
--- of where each byte of the input went. So the test maps a position
--- only where the tree leaves no doubt: a text node, or a quoted
--- attribute value, with a literal text that occurs once in the input
--- (and in the whole tree), has no character reference, and stands
--- between `>` and `<` (or between `name="` and `"`). A cut inside that
--- text is a place the tree names the parent of: a slot the tracker
--- accepts there must be text for a parent that is not raw text or
--- RCDATA, `rtext` for `<textarea>` and `<title>`, and never an
--- attribute's; and a slot it accepts in an attribute value, an
--- attribute's, a URL's only for a URL attribute. A refusal is never
--- wrong, so it is never checked.
local Fs = require("cosmic.fs")
local Template = require("cosmic.template")
local Test = require("cosmic.test")

Test.policy{ grants = { { path = "vendor/wpt-html-parsing/html/syntax/parsing/resources", letters = "r" } } }

--- Where the parser tests are: the one place a change of source names.
local DIRECTORY <const> = "vendor/wpt-html-parsing/html/syntax/parsing/resources"

local HEAD <const> = "{{type T from m.t}}\n"

--- The elements, in HTML, whose text a browser does not read as markup
--- and which a slot of text must not be in: the tracker has no escaper
--- for them (`noscript` is raw with scripting on).
local RAW <const>: {string: boolean} = {
  script = true, style = true, xmp = true, iframe = true, noembed = true, noframes = true,
  plaintext = true, noscript = true,
}

--- The elements that hold RCDATA, which a slot takes as `rtext`.
local RCDATA <const>: {string: boolean} = { textarea = true, title = true }

--- The attributes that take one URL, as the HTML standard lists them.
local URL_ATTRS <const>: {string: boolean} = {
  href = true, src = true, action = true, formaction = true, cite = true, data = true,
  poster = true, background = true, manifest = true, longdesc = true, codebase = true,
  profile = true, icon = true, lowsrc = true, dynsrc = true, classid = true, ["xlink:href"] = true,
}

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

--- The element a node is a child of: its name, and whether it is in HTML.
local function parent_of(tree: {string}, at: integer, depth: integer): string, boolean
  for up = at - 1, 1, -1 do
    local d, body = split(tree[up])
    if d >= 0 and d < depth then
      local ns, name = body:match("^<(%a+) ([^>]+)>$")
      if ns == "svg" or ns == "math" then
        return name, false
      end
      return body:match("^<([^ >]+)>$") or "", true
    end
  end
  return "", true
end

--- The element an attribute line belongs to.
local function owner_of(tree: {string}, at: integer, depth: integer): string
  for up = at - 1, 1, -1 do
    local d, body = split(tree[up])
    if d >= 0 and d < depth then
      return body
    end
  end
  return ""
end

local record Reach
  cases: integer
  texts: integer
  values: integer
  positions: integer
  accepted: {string: integer}
  failures: {string}
end

--- Compiles `input` cut at each of `cut`s from `start` with a slot,
--- passing what the slot is (or nil, if refused) to `judge`.
local function try(input: string, start: integer, length: integer, reach: Reach,
                   judge: function(kind: string, at: integer))
  for _, cut in ipairs(cuts(length)) do
    local at = start + cut
    local out = Template.compile(HEAD .. input:sub(1, at) .. "{{.x}}" .. input:sub(at + 1), "t.tmpl")
    reach.positions = reach.positions + 1
    if out ~= nil then
      judge(kind_of(out), at)
    end
  end
end

local function check_case(file: string, case: Case, reach: Reach)
  local input, tree = case.input, case.tree
  if case.other or input:find("{{", 1, true) or input:find("[&%z\r]") then
    return
  end
  reach.cases = reach.cases + 1
  local document = table.concat(tree, "\n")
  for at, line in ipairs(tree) do
    local depth, body = split(line)
    local text = body:match('^"(.*)"$')
    local name, value = body:match('^([^%s="<]+ ?[^%s="<]*)="(.*)"$')
    if text ~= nil and text ~= "" and #text > 2 and count(input, text) == 1 and count(document, text) == 1 then
      local start = input:find(text, 1, true) as integer
      local before = input:sub(start - 1, start - 1)
      local after = input:sub(start + #text, start + #text)
      if (before == ">" or start == 1) and (after == "<" or after == "") then
        local parent, html = parent_of(tree, at, depth)
        reach.texts = reach.texts + 1
        try(input, start - 1, #text, reach, function(kind: string, cut: integer)
          local key = (html and "html " or "foreign ") .. kind
          reach.accepted[key] = (reach.accepted[key] or 0) + 1
          local fine: boolean
          if kind == "text" then
            fine = not html or not (RAW[parent] or RCDATA[parent])
          elseif kind == "rtext" then
            fine = RCDATA[parent] == true
          else
            fine = false
          end
          if not fine then
            reach.failures[#reach.failures + 1] = ("%s: slot %s at %d of %q: the tree has the text %q in %s%s"):format(
              file, kind, cut, input, text, html and "" or "foreign ", parent)
          end
        end)
      end
    elseif name ~= nil and value ~= "" and not value:find("[\"']") and count(input, value) == 1 and
        count(document, value) == 1 then
      local start = input:find(value, 1, true) as integer
      local quote = input:sub(start - 1, start - 1)
      local written = name:gsub(" ", ":")
      local before = input:sub(start - 2 - #written, start - 2):lower()
      if (quote == '"' or quote == "'") and input:sub(start + #value, start + #value) == quote and
          before == written:lower() .. "=" and owner_of(tree, at, depth) ~= "" then
        reach.values = reach.values + 1
        try(input, start - 1, #value, reach, function(kind: string, cut: integer)
          reach.accepted["value " .. kind] = (reach.accepted["value " .. kind] or 0) + 1
          if not (kind == "attr" or (kind == "url" and URL_ATTRS[written:lower()])) then
            reach.failures[#reach.failures + 1] = ("%s: slot %s at %d of %q: the tree has the value of %s"):format(
              file, kind, cut, input, name)
          end
        end)
      end
    end
  end
end

local function test_a_slot_is_accepted_only_where_the_tree_has_text_or_an_attribute_value_for_it()
  local reach: Reach = { cases = 0, texts = 0, values = 0, positions = 0, accepted = {}, failures = {} }
  for _, file in ipairs((assert(Fs.list(DIRECTORY)))) do
    -- The scripted files give the tree a script's changes to it make.
    if file:find("%.dat$") and not file:find("^scripted_") then
      local text = assert(Fs.read(DIRECTORY .. "/" .. file))
      for _, case in ipairs(cases_of(text)) do
        check_case(file, case, reach)
      end
    end
  end
  local summary: {string} = {}
  for key, count_of in pairs(reach.accepted) do
    summary[#summary + 1] = key .. "=" .. count_of
  end
  table.sort(summary)
  print(("tree: %d cases, %d texts, %d values, %d positions; accepted %s"):format(
    reach.cases, reach.texts, reach.values, reach.positions, table.concat(summary, " ")))
  assert(#reach.failures == 0, #reach.failures .. " failures:\n" ..
      table.concat(reach.failures, "\n", 1, math.min(#reach.failures, 30)))
  -- It reaches 1534 cases, 790 texts, 63 values and 4250 positions, and
  -- accepts 1950 slots of text, 115 of rtext, 104 in foreign text, 131 of
  -- attributes and 7 of URLs.
  local accepted = reach.accepted
  assert(reach.cases >= 1400 and reach.texts >= 700 and reach.values >= 50 and reach.positions >= 4000,
    "only " .. reach.texts .. " texts and " .. reach.values .. " values were reached")
  assert((accepted["html text"] or 0) >= 1800 and (accepted["html rtext"] or 0) >= 100 and
      (accepted["foreign text"] or 0) >= 90 and (accepted["value attr"] or 0) >= 100 and
      (accepted["value url"] or 0) >= 5, "too few slots were accepted: " .. table.concat(summary, " "))
end
