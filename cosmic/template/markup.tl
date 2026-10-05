--- A small HTML state machine over a template's literal text, which says
--- where each `{{slot}}` stands and so how its value must be escaped.
--- Private to [`cosmic.template`].
---
--- It follows the tokenizer the HTML standard gives a browser (the
--- tag, attribute and comment states, and the raw text of `<script>` and
--- `<style>`), because a slot's escaping is right only in the place the
--- browser will read it, not the place the author meant. A place there is
--- no escaping for is a refusal, not a guess:
---
--- - after `<`, in a tag name, an attribute name, or between attributes
---   (a value there makes new markup);
--- - an unquoted attribute value (a space ends it);
--- - a comment, `<!...>` and `<?...>` (a value there could end it);
--- - `<script>` and `<style>` text, until their end tag: no escaper for
---   their languages is held to a standard here yet;
--- - an attribute that is code or a URL list: `on*` handlers, `style`,
---   `srcdoc`, `srcset`, `ping`, and `content` of `<meta>`;
--- - a URL attribute (`href`, `src`, ...) of a tag that makes the page
---   run or load what the URL names (`script`, `link`, `object`,
---   `embed`, `base`, `use`), or one not at the start of the value.
---
--- What is left is a slot in text (also in `<textarea>` and `<title>`,
--- whose text is escaped the same, but not in `<svg>` or `<math>`, where
--- they hold markup and are tags like any other, as the standard has it:
--- `<script>` and `<style>` there are refused as ever), in a quoted attribute
--- value, and in a
--- quoted URL attribute value that the slot begins.
---
--- A URL attribute is `href`, `src`, `action`, `formaction`, `cite`,
--- `data`, `poster`, `background`, `manifest`, `longdesc`, `codebase`,
--- `profile`, `icon` and `xlink:href`: each takes one URL. A slot is
--- taken as a whole URL (the escaper decides whether it may be a link),
--- which is why it must begin the value: after `href="/a/` it would be a
--- piece of one, which needs an escaper for a piece (doc/roadmap.md).

local types = require("cosmic.template.types")

local record Markup
  --- Where the tokenizer is, in the HTML standard's own terms (a state
  --- named there is its name here with underscores).
  enum Phase
    "text"
    "rcdata"
    "raw"
    "lt"
    "decl"
    "decl_dash"
    "comment_start"
    "comment_start_dash"
    "comment"
    "comment_dash"
    "comment_end"
    "comment_end_bang"
    "bogus"
    "end_open"
    "tag_name"
    "before_attr"
    "attr_name"
    "after_attr"
    "before_value"
    "value_dq"
    "value_sq"
    "value_unq"
  end

  --- A place in the markup: the phase, and while in a tag or the text of
  --- a raw text element, the tag (lower case), the attribute in it,
  --- whether it is an end tag, and whether a quoted value has had nothing
  --- but whitespace so far.
  record Place
    --- Where the tokenizer is.
    phase: Phase
    --- The tag, lower case.
    tag: string
    --- The attribute, lower case.
    attr: string
    --- Whether the tag is an end tag.
    closing: boolean
    --- Whether a quoted value has had only whitespace in it so far.
    fresh: boolean
    --- Whether the place is in `<svg>` or `<math>`, where `<title>` and
    --- `<textarea>` hold markup, not text.
    foreign: boolean
  end

  --- A new place: the start of the template, in text.
  start: function(): Place

  --- A copy of a place.
  copy: function(p: Place): Place

  --- Whether two places are the same one.
  same: function(a: Place, b: Place): boolean

  --- Moves a place over literal template text.
  feed: function(p: Place, text: string)

  --- What a slot at a place is, or why there is none.
  slot: function(p: Place): types.Slot | nil, string

  --- Marks that a slot was written at a place, which a URL value must
  --- begin with.
  wrote: function(p: Place)
end

local type Phase = Markup.Phase
local type Place = Markup.Place

--- The attributes that take one URL, which a slot there is escaped as.
local URL_ATTRS <const>: {string: boolean} = {
  href = true, src = true, action = true, formaction = true, cite = true, data = true,
  poster = true, background = true, manifest = true, longdesc = true, codebase = true,
  profile = true, icon = true, ["xlink:href"] = true,
}

--- The tags whose URL attributes make the page run or load what they
--- name, which no URL allowlist makes safe to take from data.
local ACTIVE_TAGS <const>: {string: boolean} = {
  script = true, link = true, object = true, embed = true, base = true, use = true,
}

--- The attributes that hold code, a markup document or a list of URLs,
--- each with what a slot there would be.
local CODE_ATTRS <const>: {string: string} = {
  style = "CSS", srcdoc = "HTML", srcset = "a list of URLs", ping = "a list of URLs",
}

--- The tags whose content is raw text, which ends at their end tag: the
--- two a slot cannot be in, and the two it can (escaped as text is).
local RAW_TAGS <const>: {string: Phase} = {
  script = "raw", style = "raw", textarea = "rcdata", title = "rcdata",
}

local function start(): Place
  return { phase = "text", tag = "", attr = "", closing = false, fresh = false }
end

local function copy(p: Place): Place
  return { phase = p.phase, tag = p.tag, attr = p.attr, closing = p.closing, fresh = p.fresh }
end

--- The phases in which `tag`, `attr`, `closing` and `fresh` mean
--- something; elsewhere they are what an earlier tag left.
local TAGGED <const>: {Phase: boolean} = {
  rcdata = true, raw = true, tag_name = true, before_attr = true, attr_name = true,
  after_attr = true, before_value = true, value_dq = true, value_sq = true, value_unq = true,
}

local function same(a: Place, b: Place): boolean
  if a.phase ~= b.phase or a.foreign ~= b.foreign then
    return false
  end
  return not TAGGED[a.phase] or (a.tag == b.tag and a.attr == b.attr and a.closing == b.closing and
    a.fresh == b.fresh)
end

--- Whether byte `b` is an HTML space.
local function space(b: integer): boolean
  return b == 32 or b == 9 or b == 10 or b == 13 or b == 12
end

--- Whether byte `b` is an ASCII letter.
local function letter(b: integer): boolean
  return (b >= 65 and b <= 90) or (b >= 97 and b <= 122)
end

--- Whether the byte at `i` ends a tag name: a space, `/` or `>`.
local function delimiter(text: string, i: integer): boolean
  local b = text:byte(i)
  return b ~= nil and (space(b) or b == 47 or b == 62)
end

--- Where `tag`'s end tag next begins in `text` from `from`, for a tag of
--- text that has no markup in it (`style`, `textarea`, `title`): the
--- offset of its `<`, or nil.
local function plain_end(text: string, from: integer, tag: string): integer | nil
  local at = from
  while true do
    local lt = text:find("</", at, true)
    if lt == nil then
      return nil
    end
    if text:sub(lt + 2, lt + 1 + #tag):lower() == tag and delimiter(text, lt + 2 + #tag) then
      return lt
    end
    at = lt + 1
  end
end

--- Where a `<script>`'s end tag next begins in `text` from `from`: the
--- offset of its `<`, or nil. A script that opens a comment (`<!--`)
--- and a script in it (`<script`) has its first `</script>` in the
--- script, not at its end, as the standard has it; `-->` leaves the
--- comment.
local function script_end(text: string, from: integer): integer | nil
  local at = from
  local escaped = false
  local double = false
  while true do
    local hit = text:find("[<%-]", at)
    if hit == nil then
      return nil
    end
    if text:byte(hit) == 45 then
      if escaped and text:sub(hit, hit + 2) == "-->" then
        escaped = false
        double = false
        at = hit + 3
      else
        at = hit + 1
      end
    elseif text:sub(hit, hit + 3) == "<!--" and not escaped then
      escaped = true
      at = hit + 2
    elseif text:byte(hit + 1) == 47 and text:sub(hit + 2, hit + 7):lower() == "script" and
        delimiter(text, hit + 8) then
      if not double then
        return hit
      end
      double = false
      at = hit + 8
    elseif escaped and text:sub(hit + 1, hit + 6):lower() == "script" and delimiter(text, hit + 7) then
      double = true
      at = hit + 7
    else
      at = hit + 1
    end
  end
end

--- Ends the tag just read: into the text of a raw text element if it
--- opens one, else into text. Answers where reading goes on.
local function end_tag(p: Place, from: integer): integer
  if p.tag == "svg" or p.tag == "math" then
    p.foreign = not p.closing
  end
  local phase = RAW_TAGS[p.tag]
  if p.foreign and phase == "rcdata" then
    phase = nil
  end
  p.phase = (p.closing or phase == nil) and "text" or phase
  return from
end

local function feed(p: Place, text: string)
  local i = 1
  local n = #text
  while i <= n do
    local b = text:byte(i)
    local phase = p.phase
    if phase == "text" then
      local lt = text:find("<", i, true)
      if lt == nil then
        return
      end
      p.phase = "lt"
      i = lt + 1
    elseif phase == "lt" then
      if letter(b) then
        p.phase = "tag_name"
        p.tag = ""
        p.closing = false
      elseif b == 47 then
        p.phase = "end_open"
        i = i + 1
      elseif b == 33 then
        p.phase = "decl"
        i = i + 1
      elseif b == 63 then
        p.phase = "bogus"
        i = i + 1
      elseif b ~= 60 then
        p.phase = "text"
      else
        i = i + 1
      end
    elseif phase == "tag_name" then
      local stop = text:find("[ \t\r\n\f/>]", i) or n + 1
      p.tag = p.tag .. text:sub(i, stop - 1):lower()
      i = stop
      if i <= n then
        p.phase = "before_attr"
      end
    elseif phase == "end_open" then
      if letter(b) then
        p.phase = "tag_name"
        p.tag = ""
        p.closing = true
      elseif b == 62 then
        p.phase = "text"
        i = i + 1
      else
        p.phase = "bogus"
      end
    elseif phase == "before_attr" or phase == "after_attr" then
      if space(b) or b == 47 then
        if b == 47 and phase == "after_attr" then
          p.phase = "before_attr"
        end
        i = i + 1
      elseif b == 62 then
        i = end_tag(p, i + 1)
      elseif b == 61 then
        -- After a name, `=` brings its value; before one it is the first
        -- byte of a name, as the standard has it.
        p.phase = phase == "after_attr" and "before_value" or "attr_name"
        p.attr = phase == "after_attr" and p.attr or "="
        i = i + 1
      else
        p.phase = "attr_name"
        p.attr = ""
      end
    elseif phase == "attr_name" then
      local stop = text:find("[ \t\r\n\f/>=]", i) or n + 1
      p.attr = p.attr .. text:sub(i, stop - 1):lower()
      i = stop
      if i <= n then
        local d = text:byte(i)
        if d == 61 then
          p.phase = "before_value"
          i = i + 1
        elseif d == 62 then
          i = end_tag(p, i + 1)
        else
          p.phase = d == 47 and "before_attr" or "after_attr"
          i = i + 1
        end
      end
    elseif phase == "before_value" then
      if space(b) then
        i = i + 1
      elseif b == 34 or b == 39 then
        p.phase = b == 34 and "value_dq" or "value_sq"
        p.fresh = true
        i = i + 1
      elseif b == 62 then
        i = end_tag(p, i + 1)
      else
        p.phase = "value_unq"
      end
    elseif phase == "value_dq" or phase == "value_sq" then
      local close = text:find(phase == "value_dq" and '"' or "'", i, true)
      local last = (close or n + 1) - 1
      if p.fresh then
        local seen = text:find("[^ \t\r\n\f]", i)
        if seen ~= nil and seen <= last then
          p.fresh = false
        end
      end
      if close == nil then
        return
      end
      p.phase = "before_attr"
      p.fresh = false
      i = close + 1
    elseif phase == "value_unq" then
      if b == 62 then
        i = end_tag(p, i + 1)
      else
        if space(b) then
          p.phase = "before_attr"
        end
        i = i + 1
      end
    elseif phase == "decl" then
      if b == 45 then
        p.phase = "decl_dash"
        i = i + 1
      elseif b == 62 then
        p.phase = "text"
        i = i + 1
      else
        p.phase = "bogus"
      end
    elseif phase == "decl_dash" then
      if b == 45 then
        p.phase = "comment_start"
        i = i + 1
      elseif b == 62 then
        p.phase = "text"
        i = i + 1
      else
        p.phase = "bogus"
      end
    elseif phase == "comment_start" then
      if b == 62 then
        p.phase = "text"
      elseif b == 45 then
        p.phase = "comment_start_dash"
      else
        p.phase = "comment"
      end
      i = i + 1
    elseif phase == "comment_start_dash" then
      if b == 62 then
        p.phase = "text"
      elseif b == 45 then
        p.phase = "comment_end"
      else
        p.phase = "comment"
      end
      i = i + 1
    elseif phase == "comment" then
      local dash = text:find("-", i, true)
      if dash == nil then
        return
      end
      p.phase = "comment_dash"
      i = dash + 1
    elseif phase == "comment_dash" then
      p.phase = b == 45 and "comment_end" or "comment"
      i = i + 1
    elseif phase == "comment_end" then
      if b == 62 then
        p.phase = "text"
      elseif b == 33 then
        p.phase = "comment_end_bang"
      elseif b ~= 45 then
        p.phase = "comment"
      end
      i = i + 1
    elseif phase == "comment_end_bang" then
      if b == 62 then
        p.phase = "text"
      elseif b == 45 then
        p.phase = "comment_dash"
      else
        p.phase = "comment"
      end
      i = i + 1
    elseif phase == "bogus" then
      local gt = text:find(">", i, true)
      if gt == nil then
        return
      end
      p.phase = "text"
      i = gt + 1
    else
      local found: integer | nil
      if p.tag == "script" then
        found = script_end(text, i)
      else
        found = plain_end(text, i, p.tag)
      end
      if found == nil then
        return
      end
      p.phase = "text"
      i = found
    end
  end
end

local function slot(p: Place): types.Slot | nil, string
  local phase = p.phase
  if phase == "text" or phase == "rcdata" then
    return "text", ""
  elseif phase == "raw" then
    return nil, "a slot inside <" .. p.tag .. "> has no escaper"
  elseif phase == "value_dq" or phase == "value_sq" then
    local attr = p.attr
    if attr:sub(1, 2) == "on" then
      return nil, "a slot in the event handler attribute '" .. attr .. "' would be script"
    end
    local code = CODE_ATTRS[attr]
    if code ~= nil then
      return nil, "a slot in the '" .. attr .. "' attribute would be " .. code
    end
    if attr == "content" and p.tag == "meta" then
      return nil, "a slot in the content of a <meta> could be a redirect"
    end
    if URL_ATTRS[attr] then
      if ACTIVE_TAGS[p.tag] then
        return nil, "a slot in the '" .. attr .. "' of <" .. p.tag .. "> would make the page load or run it"
      end
      if not p.fresh then
        -- TODO: once `cosmic.html` carries an escaper for one component of
        -- a URL (a path segment, a query value), let a slot stand after
        -- literal text in a URL attribute, escaped by that.
        return nil, "a slot in a URL must begin the value of '" .. attr .. "': after other text it is a piece of one"
      end
      return "url", ""
    end
    return "attr", ""
  elseif phase == "value_unq" or phase == "before_value" then
    return nil, "a slot in an unquoted attribute value: quote the value"
  elseif phase == "tag_name" or phase == "lt" or phase == "end_open" then
    return nil, "a slot in a tag name"
  elseif phase == "before_attr" or phase == "attr_name" or phase == "after_attr" then
    return nil, "a slot in a tag, as an attribute or its name"
  end
  return nil, "a slot in a comment or markup declaration"
end

local function wrote(p: Place)
  p.fresh = false
end

local M: Markup = { start = start, copy = copy, same = same, feed = feed, slot = slot, wrote = wrote }
return M
