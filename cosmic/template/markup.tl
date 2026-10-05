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
--- - an attribute that is code or a URL list: any attribute whose name
---   begins with `on` (handlers), `style`, `srcdoc`, `srcset`, `ping`,
---   `content` of a `<meta>` that has `http-equiv` (anywhere in the
---   tag), and every attribute of the SVG animation elements (`set`,
---   `animate`, `animateMotion`, `animateTransform`: they can animate
---   `href` to `javascript:`). Attributes that frameworks read as code
---   (`hx-*`, `x-on:`, `v-on:`, `@click`, `ng-*`) are not recognised:
---   they are plain attributes here, and a slot in one is the author's
---   to keep out;
--- - `<xmp>`, `<iframe>`, `<noembed>`, `<noframes>`, `<noscript>` and
---   `<plaintext>` text, which browsers read as raw text (`noscript`
---   when scripting is on);
--- - every attribute of `<script>`, and the `charset` of a `<meta>`;
--- - anything inside `<foreignObject>`, `<desc>`, `<title>` of an SVG,
---   `<annotation-xml>` or MathML's text elements: the browser reads
---   HTML there, in rules this tracker does not follow;
--- - a URL attribute (`href`, `src`, ...) of a tag that makes the page
---   run or load what the URL names (`script`, `link`, `object`,
---   `embed`, `base`, `use`), or one not at the start of the value.
---
--- What is left is a slot in text; in `<textarea>` and `<title>`, whose
--- text ends at their end tag, which takes a string or a number and never
--- markup; in a quoted attribute value; and in a quoted URL attribute
--- value that the slot begins, when the literal text after it, up to the
--- first `/`, `?` or `#`, has no `:` or `&` (which could complete a scheme:
--- `href="{{.p}}:alert(1)"`, `{{.p}}&colon;alert(1)`).
---
--- `<svg>` and `<math>` are kept on a stack, popped as an end tag pops
--- them, so nested ones and a self-closed `<svg/>` leave the tracker where
--- the browser is. It does not model the tags that take the parser out of
--- foreign content (`<svg><p>`) or ignore an `<svg>` (in `<select>`), and
--- does not need to: what the stack decides is a refusal (inside an
--- element the browser reads HTML in), or a `<script>`, `<style>`,
--- `<textarea>` or `<title>` in foreign content, which the tracker reads
--- as it would in HTML, where they are raw text or RCDATA. If the text
--- they hold has a `<`, the two readings could part ways, and the place
--- is murky: every later slot is refused. A slot in RCDATA is escaped as
--- text and takes no markup, which is safe in either reading, and
--- `<noscript>` text with a comment in it is the same.
---
--- A URL attribute is `href`, `src`, `action`, `formaction`, `cite`,
--- `data`, `poster`, `background`, `manifest`, `longdesc`, `codebase`,
--- `profile`, `icon`, `lowsrc`, `dynsrc`, `classid` and `xlink:href`: each takes one URL. A slot is
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
    --- The `<svg>` and `<math>` open, and the elements inside them that
    --- the browser reads HTML in, innermost last, each name after a space.
    stack: string
    --- Set when the browser may read what follows by rules this tracker
    --- does not follow, so every later slot is refused: raw text or
    --- RCDATA inside `<svg>` or `<math>` that holds a `<`, `<noscript>`
    --- text that holds a comment.
    murky: boolean
    --- Whether the last byte read was the `/` of a tag, which a `>` at the
    --- start of the next run of text then closes as self-closing.
    slash: boolean
    --- Whether the literal text since a URL slot, in the same value, has
    --- not yet reached a `/`, `?` or `#`.
    after_url: boolean
    --- Set when that text held a `:`.
    colon: boolean
    --- Whether the tag has an `http-equiv` attribute.
    equiv: boolean
    --- Where a slot in the `content` of a `<meta>` stood (the line, then
    --- the column; 0 for none), in case the tag turns out to hold `http-equiv`.
    meta_line: integer
    --- Its column.
    meta_col: integer
    --- A refusal found at the end of a tag, for the slot that stood at
    --- `late_line` and `late_col`.
    late: string
    --- The line of that slot.
    late_line: integer
    --- Its column.
    late_col: integer
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

  --- Marks that a slot of kind `ctx` was written at a place, at a line and
  --- column: a URL value must begin with its slot, and the literal text
  --- after one is watched.
  wrote: function(p: Place, ctx: types.Slot, line: integer, col: integer)

  --- Folds the place `b`, which `same` found the same as `a`, into `a`: a
  --- value is fresh only if it is in both, and a URL slot or a pending
  --- `<meta>` slot in either is kept.
  join: function(a: Place, b: Place)
end

local type Phase = Markup.Phase
local type Place = Markup.Place

--- The attributes that take one URL, which a slot there is escaped as.
local URL_ATTRS <const>: {string: boolean} = {
  href = true, src = true, action = true, formaction = true, cite = true, data = true,
  poster = true, background = true, manifest = true, longdesc = true, codebase = true,
  profile = true, icon = true, lowsrc = true, dynsrc = true, classid = true, ["xlink:href"] = true,
}

--- The tags whose URL attributes make the page run or load what they
--- name, which no URL allowlist makes safe to take from data.
local ACTIVE_TAGS <const>: {string: boolean} = {
  script = true, link = true, object = true, embed = true, base = true, use = true, applet = true,
}

--- The attributes that hold code, a markup document or a list of URLs,
--- each with what a slot there would be.
local CODE_ATTRS <const>: {string: string} = {
  style = "CSS", srcdoc = "HTML", srcset = "a list of URLs", ping = "a list of URLs",
}

--- The tags whose content is raw text, which ends at their end tag (never,
--- for `plaintext`): the ones a slot cannot be in, and the two it can,
--- `textarea` and `title`, escaped as text.
local RAW_TAGS <const>: {string: Phase} = {
  script = "raw", style = "raw", textarea = "rcdata", title = "rcdata", xmp = "raw", iframe = "raw",
  noembed = "raw", noframes = "raw", noscript = "raw", plaintext = "raw",
}

--- The elements, inside `<svg>` or `<math>`, whose content the browser
--- reads as HTML.
local INTEGRATION <const>: {string: boolean} = {
  foreignobject = true, desc = true, title = true, ["annotation-xml"] = true, mi = true, mo = true,
  mn = true, ms = true, mtext = true,
}

--- The SVG elements that can animate an attribute to a value of the
--- author's choosing, `href` to `javascript:` among them.
local ANIMATION <const>: {string: boolean} = {
  set = true, animate = true, animatemotion = true, animatetransform = true,
}

local function start(): Place
  return { phase = "text", tag = "", attr = "", closing = false, fresh = false, stack = "", murky = false,
    slash = false, after_url = false, colon = false, equiv = false, meta_line = 0, meta_col = 0, late = "", late_line = 0, late_col = 0 }
end

local function copy(p: Place): Place
  return { phase = p.phase, tag = p.tag, attr = p.attr, closing = p.closing, fresh = p.fresh, stack = p.stack,
    murky = p.murky, slash = p.slash, after_url = p.after_url, colon = p.colon, equiv = p.equiv,
    meta_line = p.meta_line, meta_col = p.meta_col, late = p.late, late_line = p.late_line,
    late_col = p.late_col }
end

--- The phases in which the tag and whether it is an end tag mean something;
--- elsewhere they are what an earlier tag left.
local TAGGED <const>: {Phase: boolean} = {
  rcdata = true, raw = true, tag_name = true, before_attr = true, attr_name = true,
  after_attr = true, before_value = true, value_dq = true, value_sq = true, value_unq = true,
}

--- The phases in which the attribute means something.
local ATTRIBUTED <const>: {Phase: boolean} = {
  attr_name = true, after_attr = true, before_value = true, value_dq = true, value_sq = true,
}

local function same(a: Place, b: Place): boolean
  if a.phase ~= b.phase or a.stack ~= b.stack or a.murky ~= b.murky then
    return false
  end
  if TAGGED[a.phase] and (a.tag ~= b.tag or a.closing ~= b.closing or a.equiv ~= b.equiv or
      (a.meta_line > 0) ~= (b.meta_line > 0)) then
    return false
  end
  return not ATTRIBUTED[a.phase] or a.attr == b.attr
end

local function join(a: Place, b: Place)
  a.fresh = a.fresh and b.fresh
  a.after_url = a.after_url or b.after_url
  if a.meta_line == 0 then
    a.meta_line = b.meta_line
    a.meta_col = b.meta_col
  end
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

--- The names in the stack of open foreign elements.
local function names(p: Place): {string}
  local out: {string} = {}
  for name in p.stack:gmatch("%S+") do
    out[#out + 1] = name
  end
  return out
end

--- Pops the innermost `name` and all it holds, as the HTML parser does an
--- end tag in foreign content; an end tag with no such element open is
--- ignored, as it is there.
local function pop(p: Place, name: string)
  local open = names(p)
  for at = #open, 1, -1 do
    if open[at] == name then
      p.stack = ""
      for keep = 1, at - 1 do
        p.stack = p.stack .. " " .. open[keep]
      end
      return
    end
  end
end

--- Whether an element the browser reads HTML in is open inside `<svg>`
--- or `<math>`. A count too high only refuses more: after an unmatched
--- `<svg><mi>` every later slot is refused, as after any element the HTML
--- parser pops out of foreign content (`<svg><p>`) the stack keeps what
--- the parser dropped, and every decision that reads it errs to refusing.
local function opaque(p: Place): boolean
  for _, name in ipairs(names(p)) do
    if INTEGRATION[name] then
      return true
    end
  end
  return false
end

--- Counts a start or end tag of `<svg>`, `<math>` and the elements inside
--- them that the browser reads HTML in.
local function count(p: Place, selfclosed: boolean)
  local tag = p.tag
  if tag == "svg" or tag == "math" or (INTEGRATION[tag] and p.stack ~= "") then
    if p.closing then
      pop(p, tag)
    elseif not selfclosed then
      p.stack = p.stack .. " " .. tag
    end
  end
end

--- Ends the tag just read, at the `>` before `from` (after a value with no
--- quotes, which a `/` ends nothing in): into the text of a raw text
--- element if it opens one, else into text. Answers where reading goes on.
--- `<textarea>` and `<title>` are RCDATA wherever they stand: inside
--- `<svg>` the browser may read them as ordinary elements instead, and
--- `scan` marks the place murky if what they hold could tell the two apart.
local function end_tag(p: Place, text: string, from: integer, unquoted: boolean): integer
  if p.attr == "http-equiv" and ATTRIBUTED[p.phase] then
    p.equiv = true
  end
  local before = from >= 3 and text:byte(from - 2) or (p.slash and 47 or 0)
  count(p, not unquoted and before == 47)
  if p.tag == "meta" and not p.closing and p.equiv and p.meta_line > 0 then
    p.late = "a slot in the content of a <meta> that has http-equiv could be a redirect"
    p.late_line = p.meta_line
    p.late_col = p.meta_col
  end
  local phase = RAW_TAGS[p.tag]
  p.phase = (p.closing or phase == nil) and "text" or phase
  return from
end

--- Notes that the attribute just named is `http-equiv`.
local function named(p: Place)
  if p.attr == "http-equiv" then
    p.equiv = true
  end
end

--- Starts a tag.
local function open_tag(p: Place, closing: boolean)
  p.phase = "tag_name"
  p.tag = ""
  p.closing = closing
  p.equiv = false
  p.meta_line = 0
  p.meta_col = 0
end

local function scan(p: Place, text: string)
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
        open_tag(p, false)
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
        open_tag(p, true)
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
        i = end_tag(p, text, i + 1, false)
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
        named(p)
        if d == 61 then
          p.phase = "before_value"
          i = i + 1
        elseif d == 62 then
          i = end_tag(p, text, i + 1, false)
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
        i = end_tag(p, text, i + 1, false)
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
      if p.after_url then
        local seg = text:sub(i, last)
        local cut = seg:find("[/?#]")
        if (cut and seg:sub(1, cut - 1) or seg):find("[:&]") then
          p.colon = true
        end
        if cut then
          p.after_url = false
        end
      end
      if close == nil then
        return
      end
      p.phase = "before_attr"
      p.fresh = false
      p.after_url = false
      i = close + 1
    elseif phase == "value_unq" then
      if b == 62 then
        i = end_tag(p, text, i + 1, true)
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
      if p.tag == "plaintext" then
        return
      end
      local found: integer | nil
      if p.tag == "script" then
        found = script_end(text, i)
      else
        found = plain_end(text, i, p.tag)
      end
      local region = text:sub(i, (found or n + 1) - 1)
      if (p.stack ~= "" and region:find("<", 1, true)) or (p.tag == "noscript" and region:find("<!--", 1, true)) then
        p.murky = true
      end
      if found == nil then
        return
      end
      p.phase = "text"
      i = found
    end
  end
end

local function feed(p: Place, text: string)
  scan(p, text)
  p.slash = p.phase == "before_attr" and text:byte(#text) == 47
end

local function slot(p: Place): types.Slot | nil, string
  local phase = p.phase
  if p.murky then
    return nil, "a slot after markup in <svg>, <math> or <noscript> that a browser may read differently from the tracker here"
  elseif opaque(p) then
    return nil, "a slot inside <" .. p.tag .. "> in an <svg> or <math>, where the browser reads HTML by rules not followed here"
  elseif phase == "text" then
    return "text", ""
  elseif phase == "rcdata" then
    return "rtext", ""
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
    if p.tag == "script" then
      return nil, "a slot in an attribute of <script> could name the code it runs"
    end
    if attr == "charset" and p.tag == "meta" then
      return nil, "a slot in the charset of a <meta> could change how the page is read"
    end
    if ANIMATION[p.tag] then
      return nil, "a slot in an attribute of <" .. p.tag .. "> could animate one to a script URL"
    end
    if attr == "content" and p.tag == "meta" and p.equiv then
      return nil, "a slot in the content of a <meta> that has http-equiv could be a redirect"
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

local function wrote(p: Place, ctx: types.Slot, line: integer, col: integer)
  p.fresh = false
  p.after_url = ctx == "url"
  if p.tag == "meta" and p.attr == "content" and ctx == "attr" then
    p.meta_line = line
    p.meta_col = col
  end
end

local M: Markup = { start = start, copy = copy, same = same, join = join, feed = feed, slot = slot, wrote = wrote }
return M
