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
---   begins with `on` (handlers), `style`, `srcdoc`, `srcset`, `imagesrcset`,
---   `ping`,
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
--- - a URL attribute (`href`, `src`, ...) of a tag that makes the page
---   run or load what the URL names (`script`, `link`, `object`,
---   `embed`, `base`, `use`), or one not at the start of the value.
---
--- The state is the tokenizer's in full, carried over every action: text
--- fed in runs is read as it would be whole, whether an action that emits
--- nothing splits it (`</text{{if .a}}{{end}}area>`) or a string action
--- is one of the runs (`</text{{"area>"}}`), so an end tag, a comment or
--- a script's escape states cut short between runs are completed by the
--- run after.
---
--- A slot in a template's end must leave it in plain text: see `ending`.
---
--- What is left is a slot in text; in `<textarea>` and `<title>`, whose
--- text ends at their end tag, which takes a string or a number and never
--- markup; in a quoted attribute value; and in a quoted URL attribute
--- value that the slot begins, when the literal text after it, up to the
--- first `/`, `?` or `#`, has no `:` or `&` (which could complete a scheme:
--- `href="{{.p}}:alert(1)"`, `{{.p}}&colon;alert(1)`), and does not begin
--- with `/` or `\` (which, after a value of `/`, would make `//host`, the
--- protocol-relative URL [`Html.href`] refuses; a tab, line feed or carriage
--- return before it is dropped by a URL parser and does not count).
---
--- Foreign content (`<svg>`, `<math>`) is followed only as far as the
--- elements in them, their attributes and plain text, on a stack of the
--- elements open. Anything else the browser could read by other rules
--- makes the place murky, for good (every later slot in the template is
--- refused), because the tracker cannot tell where the browser comes out
--- of it: `<!--`, `<![CDATA[`, any `<!` or `<?`; a tag that takes the
--- parser out of foreign content (`<p>`, `<div>`, `<br>`, `<table>`, `<font
--- size=1>`, ...); a tag the browser reads HTML in (`<foreignObject>`,
--- `<desc>`, `<title>`, `<annotation-xml>`, `<mi>`, ...); an end tag that
--- is not the innermost open element's (`</g>` after `<svg><a>`); an
--- `<svg>` or `<math>` in a `<select>`; and the text of a `<script>`,
--- `<style>`, `<textarea>` or `<title>` in foreign content when it holds a
--- `<`, and `<noscript>` text with a comment in it. So does a start tag of
--- raw text or RCDATA in a `<select>` other than `<script>` and
--- `<textarea>`, or after a `<frameset>` other than `<noframes>`: a parser
--- in the classic "in select" or "in frameset" mode ignores it and reads
--- the markup in its text as tags, where a newer one opens the element
--- (`<select><title><option onclick="{{.x}}">`). A tag that carries a
--- `/` across a block boundary (`<svg {{if .a}}/{{end}}>`) is a place of
--- its own, so the arms of a block that differ in it are refused.
---
--- The arms of a block may leave a tag at different boundaries between its
--- attributes, as one that adds a whole attribute does
--- (`<input{{if .a}} checked{{end}} name=n>`, `<input {{if .a}}checked {{end}}name=n>`).
--- The place is then each of them, and the text after the block is read in
--- each until they agree, at a byte that begins a new attribute or ends the
--- tag. Text that carries a name or value on in one of them, or gives an
--- attribute a value (`<input{{if .a}} checked{{end}}=x>`,
--- `<input {{if .a}}chec{{end}}ked>`), is refused, as is a slot or the end of
--- the template before they agree. So is a block whose arms end apart in a
--- tag where text carried a name or unquoted value on, or gave an attribute
--- a value, across an action (`<input a{{if .b}}c d{{end}}>`): an arm may have
--- ended the attribute the block cut or not.
--- A slot in RCDATA is escaped as text and takes no markup, which is safe
--- in either reading, except after a `<` or a partial end tag (`</tex`) in
--- it, where the slot could complete the end tag and the place after it is
--- not RCDATA: that is refused. `<svg>`, `<g>`, `<a href="{{.u}}">`, `<text>{{.x}}`
--- and a slot after a cleanly closed `</svg>` are not murky.
---
--- A URL attribute is `href`, `src`, `action`, `formaction`, `cite`,
--- `data`, `poster`, `background`, `manifest`, `longdesc`, `codebase`,
--- `profile`, `icon`, `lowsrc`, `dynsrc`, `classid`, `archive` and
--- `xlink:href`: each takes one URL. A slot is
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
    --- The tokenizer's state, which decides what a slot may be.
    phase: Phase
    --- The tag being read or last read, whose name decides the raw text it
    --- opens and which of its attributes mean what.
    tag: string
    --- The attribute being read or last read, lower case: `on...` and `href`
    --- are judged by it.
    attr: string
    --- Whether the tag is an end tag, whose attributes the browser ignores.
    closing: boolean
    --- A URL slot must begin its value: true until text or a slot is in it.
    fresh: boolean
    --- The `<svg>` and `<math>` open, and the elements inside them that
    --- the browser reads HTML in, innermost last, each name after a space.
    stack: string
    --- Set when the browser may read what follows by rules this tracker
    --- does not follow, so every later slot is refused: raw text or
    --- RCDATA inside `<svg>` or `<math>` that holds a `<`, `<noscript>`
    --- text that holds a comment, most raw text or RCDATA in `<select>` or
    --- after `<frameset>`.
    murky: boolean
    --- Whether a `<select>` is open in HTML, where an `<svg>` may be ignored.
    select: boolean
    --- Whether a `<frameset>` has started in HTML. A parser in frameset
    --- stays there to the end of the document and ignores most tags.
    frameset: boolean
    --- Whether the `<font>` being read has `color`, `face` or `size`.
    fontattr: boolean
    --- Whether the last byte read was the `/` of a tag, which a `>` at the
    --- start of the next run of text then closes as self-closing.
    slash: boolean
    --- Whether the literal text since a URL slot, in the same value, has
    --- not yet reached a `/`, `?` or `#`.
    after_url: boolean
    --- Set when that text held a `:`.
    colon: boolean
    --- Whether no literal text has followed a URL slot yet in its value (a
    --- tab, line feed or carriage return, which a URL parser drops, aside).
    bare: boolean
    --- Set when the first such text began with `/` or `\`: a slot value of
    --- `/` and that text would make `//host`.
    rooted: boolean
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
    --- In the text of a raw text or RCDATA element, the longest end of its
    --- text that the next run could complete into something read here: a
    --- start of `</tag` (`<`, `</`, `</tex`); in `<noscript>` also of `<!--`
    --- (`<!`, `<!-`); in `<script>` also `<scr`, `-`, `--`. The next run,
    --- after a block that emits nothing or a string action, is read after
    --- it, and a slot after it could complete the tag.
    raw_tail: string
    --- In the text of a `<script>`, whether a `<!--` has opened (and no `-->`
    --- has closed) the escaped state, in which a `<script` opens a nested
    --- script whose `</script>` does not end the element.
    escaped: boolean
    --- Whether that nested script is open.
    double: boolean
    --- Whether a name or an unquoted value in this tag went on, or an
    --- attribute took a value, across an action (`<input a{{if .b}}c{{end}}>`,
    --- `<input a{{if .b}}=c{{end}}>`), which a block's arms may then have done
    --- in ways their places do not show: such a tag is never left apart
    --- (see `apart`).
    split: boolean
    --- The other places this one may be, where the arms of a block left
    --- one tag at different attribute boundaries (`<input{{if .a}} checked{{end}}`):
    --- each as its phase, a `:` and its attribute (empty where the phase
    --- does not read one), sorted and joined by spaces; "" for none. They
    --- share every other field with this place. The text after the block
    --- is read in each until they agree (see `settle`).
    alts: string
  end

  --- A new place: the start of the template, in text.
  start: function(): Place

  --- A copy of a place.
  copy: function(p: Place): Place

  --- A string that two places give alike only when every field of the two
  --- is alike.
  key: function(p: Place): string

  --- Whether two places are the same one, or are in one tag at boundaries
  --- between its attributes, which `join` holds as one place until the
  --- text after them decides.
  same: function(a: Place, b: Place): boolean

  --- Moves a place over literal template text, whose first byte stands at
  --- `line` and `col`: where the text reads differently in the places it
  --- may be, `late` says so, at the byte where it does.
  feed: function(p: Place, text: string, line: integer, col: integer)

  --- What a slot at a place is, or why there is none.
  slot: function(p: Place): types.Slot | nil, string

  --- Marks that a slot of kind `ctx` was written at a place, at a line and
  --- column: a URL value must begin with its slot, and the literal text
  --- after one is watched.
  wrote: function(p: Place, ctx: types.Slot, line: integer, col: integer)

  --- Why a template that ends at this place may not be spliced into
  --- markup (a `SafeHtml` goes into another template's text slot as it is),
  --- or "" when it ends in plain text.
  ending: function(p: Place): string

  --- How two places that `same` found different differ in the text of a raw
  --- text or RCDATA element, or "" when they differ otherwise.
  differ: function(a: Place, b: Place): string

  --- Folds the place `b`, which `same` found the same as `a`, into `a`: a
  --- value is fresh only if it is in both, a URL slot or a pending
  --- `<meta>` slot in either is kept, and `a` may be any place either may.
  join: function(a: Place, b: Place)
end

local type Phase = Markup.Phase
local type Place = Markup.Place

--- The attributes that take one URL, which a slot there is escaped as.
local URL_ATTRS <const>: {string: boolean} = {
  href = true, src = true, action = true, formaction = true, cite = true, data = true,
  poster = true, background = true, manifest = true, longdesc = true, codebase = true,
  profile = true, icon = true, lowsrc = true, dynsrc = true, classid = true, archive = true,
  ["xlink:href"] = true,
}

-- Attributes Go's html/template treats as URLs that are plain attributes
-- here, on purpose: `usemap` (a fragment naming a map), `xmlns` and
-- `xmlns:*` (namespaces, which an HTML parser ignores), and any `data-*` or
-- custom attribute whose name merely contains `src`, `uri` or `url`.
-- Browsers do not navigate or load on them; script that reads a `data-*`
-- attribute owns what it does with the value, as it does for `hx-*`.

--- The tags whose URL attributes make the page run or load what they
--- name, which no URL allowlist makes safe to take from data.
local ACTIVE_TAGS <const>: {string: boolean} = {
  script = true, link = true, object = true, embed = true, base = true, use = true, applet = true,
}

--- The attributes that hold code, a markup document or a list of URLs,
--- each with what a slot there would be.
local CODE_ATTRS <const>: {string: string} = {
  style = "CSS", srcdoc = "HTML", srcset = "a list of URLs", ping = "a list of URLs",
  imagesrcset = "a list of URLs",
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
    select = false, frameset = false, fontattr = false, slash = false, after_url = false, colon = false, bare = false, rooted = false,
    equiv = false,
    meta_line = 0, meta_col = 0, late = "", late_line = 0, late_col = 0, raw_tail = "",
    escaped = false, double = false, split = false, alts = "" }
end

local function copy(p: Place): Place
  return { phase = p.phase, tag = p.tag, attr = p.attr, closing = p.closing, fresh = p.fresh, stack = p.stack,
    murky = p.murky, select = p.select, frameset = p.frameset, fontattr = p.fontattr, slash = p.slash, after_url = p.after_url, colon = p.colon, bare = p.bare,
    rooted = p.rooted, equiv = p.equiv,
    meta_line = p.meta_line, meta_col = p.meta_col, late = p.late, late_line = p.late_line,
    late_col = p.late_col, raw_tail = p.raw_tail,
    escaped = p.escaped, double = p.double, split = p.split, alts = p.alts }
end

local function key(p: Place): string
  return string.format("%s %q %q %s %s %q %s %s %s %s %s %s %s %s %s %s %d %d %q %d %d %q %s %s %s %q", p.phase, p.tag,
    p.attr, p.closing, p.fresh, p.stack, p.murky, p.select, p.frameset, p.fontattr, p.slash, p.after_url, p.colon, p.bare,
    p.rooted, p.equiv, p.meta_line, p.meta_col, p.late, p.late_line, p.late_col, p.raw_tail, p.escaped, p.double, p.split, p.alts)
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

--- Whether `a` and `b` are one place, alternatives aside.
local function alike(a: Place, b: Place): boolean
  if a.phase ~= b.phase or a.stack ~= b.stack or a.murky ~= b.murky or a.select ~= b.select or a.frameset ~= b.frameset or
      a.slash ~= b.slash then
    return false
  end
  if TAGGED[a.phase] and (a.tag ~= b.tag or a.closing ~= b.closing or a.equiv ~= b.equiv or a.fontattr ~= b.fontattr or
      (a.meta_line > 0) ~= (b.meta_line > 0)) then
    return false
  end
  if (a.phase == "rcdata" or a.phase == "raw") and
      (a.raw_tail ~= b.raw_tail or a.escaped ~= b.escaped or a.double ~= b.double) then
    return false
  end
  return not ATTRIBUTED[a.phase] or a.attr == b.attr
end

--- The phases at a boundary between attributes, in a name that a space,
--- `/` or `>` would end, or in an unquoted value that a space or `>` would
--- end, where a tag may stand after a block that adds a whole attribute to it.
local BOUNDARY <const>: {string: Phase} = {
  tag_name = "tag_name", before_attr = "before_attr", attr_name = "attr_name", after_attr = "after_attr",
  value_unq = "value_unq",
}

--- Whether `a` and `b` stand in one tag at boundaries that the text after
--- them may yet bring together: everything but the phase and the attribute
--- agrees.
local function apart(a: Place, b: Place): boolean
  return BOUNDARY[a.phase] ~= nil and BOUNDARY[b.phase] ~= nil and a.tag == b.tag and a.closing == b.closing and
    a.stack == b.stack and a.murky == b.murky and a.select == b.select and a.frameset == b.frameset and a.slash == b.slash and
    a.equiv == b.equiv and a.fontattr == b.fontattr and (a.meta_line > 0) == (b.meta_line > 0) and
    not a.split and not b.split
end

--- `p`'s phase and attribute as `alts` holds them.
local function alt_key(p: Place): string
  return p.phase .. ":" .. (ATTRIBUTED[p.phase] and p.attr or "")
end

--- The keys in `set` other than `p`'s own, as `alts` holds them.
local function alts_of(p: Place, set: {string: boolean}): string
  local list: {string} = {}
  for k in pairs(set) do
    if k ~= alt_key(p) then
      list[#list + 1] = k
    end
  end
  table.sort(list)
  return table.concat(list, " ")
end

--- `p` as the alternative `k` of it.
local function as_alt(p: Place, k: string): Place
  local q = copy(p)
  local phase, attr = k:match("^([^:]*):(.*)$")
  q.phase = BOUNDARY[phase]
  q.attr = attr
  q.alts = ""
  return q
end

local function same(a: Place, b: Place): boolean
  if a.alts == "" and b.alts == "" and alike(a, b) then
    return true
  end
  return apart(a, b)
end

--- Where a place stands in the text of a raw text or RCDATA element.
local function raw_state(p: Place): string
  local out = "<" .. p.tag .. ">"
  if p.raw_tail ~= "" then
    out = out .. " after '" .. p.raw_tail .. "'"
  end
  if p.escaped then
    out = out .. (p.double and " inside a <!-- and a nested <script" or " inside a <!--")
  end
  return out
end

local function differ(a: Place, b: Place): string
  if (a.phase == "rcdata" or a.phase == "raw") and a.phase == b.phase then
    local x, y = raw_state(a), raw_state(b)
    if x ~= y then
      return "one leaves " .. x .. ", another " .. y
    end
  end
  return ""
end

local function join(a: Place, b: Place)
  a.fresh = a.fresh and b.fresh
  a.after_url = a.after_url or b.after_url
  a.bare = a.bare or b.bare
  a.split = a.split or b.split
  if a.meta_line == 0 then
    a.meta_line = b.meta_line
    a.meta_col = b.meta_col
  end
  local set: {string: boolean} = { [alt_key(a)] = true, [alt_key(b)] = true }
  for _, alts in ipairs({ a.alts, b.alts }) do
    for k in alts:gmatch("%S+") do
      set[k] = true
    end
  end
  if alts_of(a, set) == "" then
    return
  end
  -- Closed under what a run of spaces or a `/` makes of each, so the body
  -- of a `{{range}}` walked from the set ends in it and a third walk finds
  -- what the second did. The places added refuse no text the others take.
  local ended: {string} = { "before_attr:" }
  for k in pairs(set) do
    local name = k:match("^attr_name:(.*)$")
    if name ~= nil then
      ended[#ended + 1] = "after_attr:" .. name
    end
  end
  for _, k in ipairs(ended) do
    set[k] = true
  end
  a.alts = alts_of(a, set)
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

--- The longest end of `region`, in the text of `tag`, that the next run
--- could complete into something read here: the start of `</tag` (whole
--- too, as it needs the delimiter after it) or, in `<noscript>`, a proper
--- start of `<!--`.
local function plain_tail(region: string, tag: string): string
  local close = "</" .. tag
  for len = math.min(#region, #close), 1, -1 do
    local tail = region:sub(-len):lower()
    if close:sub(1, len) == tail or (tag == "noscript" and len < 4 and ("<!--"):sub(1, len) == tail) then
      return region:sub(-len)
    end
  end
  return ""
end

--- What a `<script>` acts on in its text, of which [`script_tail`] keeps the
--- start of one cut short.
local SCRIPT_MARKS <const>: {string} = { "<!--", "<script", "</script", "-->" }

--- The longest end of `region` that is the start of one of those and not
--- yet the whole of it (`<script` and `</script` are whole only with the
--- delimiter after them), or "".
local function script_tail(region: string, escaped: boolean): string
  for len = math.min(#region, 8), 1, -1 do
    local tail = region:sub(-len):lower()
    for _, mark in ipairs(SCRIPT_MARKS) do
      -- A dash only matters in a comment, where `-->` leaves it.
      local dashes = mark == "-->" and not escaped
      if not dashes and #tail <= #mark and mark:sub(1, #tail) == tail and
          (#tail < #mark or mark:find("script", 1, true) ~= nil) then
        return region:sub(-len)
      end
    end
  end
  return ""
end

--- Where a `<script>`'s end tag next begins in `text` from `from`: the
--- offset of its `<`, or nil. A script that opens a comment (`<!--`)
--- and a script in it (`<script`) has its first `</script>` in the
--- script, not at its end, as the standard has it; `-->` leaves the
--- comment. Those states are `p`'s, so they hold across a block that
--- emits nothing, and are left as they stand at the end of `text`.
local function script_end(p: Place, text: string, from: integer): integer | nil
  local at = from
  while true do
    local hit = text:find("[<%-]", at)
    if hit == nil then
      return nil
    end
    if text:byte(hit) == 45 then
      if p.escaped and text:sub(hit, hit + 2) == "-->" then
        p.escaped = false
        p.double = false
        at = hit + 3
      else
        at = hit + 1
      end
    elseif text:sub(hit, hit + 3) == "<!--" and not p.escaped then
      p.escaped = true
      at = hit + 2
    elseif text:byte(hit + 1) == 47 and text:sub(hit + 2, hit + 7):lower() == "script" and
        delimiter(text, hit + 8) then
      if not p.double then
        return hit
      end
      p.double = false
      at = hit + 8
    elseif p.escaped and text:sub(hit + 1, hit + 6):lower() == "script" and delimiter(text, hit + 7) then
      p.double = true
      at = hit + 7
    else
      at = hit + 1
    end
  end
end

--- The tags that take the HTML parser out of `<svg>` or `<math>` (the
--- standard's list; `font` only with a `color`, `face` or `size`).
local BREAKOUT <const>: {string: boolean} = {}
for _, name in ipairs({
    "b", "big", "blockquote", "body", "br", "center", "code", "dd", "div", "dl", "dt", "em", "embed", "h1", "h2",
    "h3", "h4", "h5", "h6", "head", "hr", "i", "img", "li", "listing", "menu", "meta", "nobr", "ol", "p", "pre",
    "ruby", "s", "small", "span", "strong", "strike", "sub", "sup", "table", "tt", "u", "ul", "var",
}) do
  BREAKOUT[name] = true
end

--- Counts a start or end tag, for the stack of foreign elements. The
--- tracker follows foreign content only as far as `<svg>` and `<math>`,
--- the elements in them, and text; whatever else the browser could read
--- differently makes the place murky for good, since the tracker cannot
--- tell where the browser comes out of it: a breakout tag, a tag the
--- browser reads HTML in, an end tag that is not the innermost element's,
--- and an `<svg>` or `<math>` in a `<select>`, which the parser may ignore.
local function count(p: Place, selfclosed: boolean)
  local tag = p.tag
  if p.stack == "" then
    if tag == "select" then
      p.select = not p.closing
    elseif tag == "frameset" and not p.closing then
      p.frameset = true
    elseif (tag == "svg" or tag == "math") and not p.closing then
      if p.select then
        p.murky = true
      elseif not selfclosed then
        p.stack = " " .. tag
      end
    end
    return
  end
  if p.closing then
    if p.stack:match("%S+$") == tag then
      p.stack = p.stack:gsub(" %S+$", "")
    else
      p.murky = true
    end
    return
  end
  if BREAKOUT[tag] or INTEGRATION[tag] or (tag == "font" and p.fontattr) then
    p.murky = true
  end
  if not selfclosed then
    p.stack = p.stack .. " " .. tag
  end
end

--- Whether a parser in the classic "in select" or "in frameset" mode may
--- ignore the raw text or RCDATA start tag just read, and read its text as
--- markup, where a newer one opens the element. "in select" reads only
--- `<script>` (by the rules in head) and `<textarea>` (which closes the
--- select), and "in frameset" only `<noframes>`.
local function ignored(p: Place): boolean
  if p.stack ~= "" then
    return false
  end
  return (p.select and p.tag ~= "script" and p.tag ~= "textarea") or (p.frameset and p.tag ~= "noframes")
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
  if phase ~= nil and not p.closing and ignored(p) then
    p.murky = true
  end
  p.phase = (p.closing or phase == nil) and "text" or phase
  return from
end

--- Notes that the attribute just named is `http-equiv`.
local function named(p: Place)
  if p.attr == "http-equiv" then
    p.equiv = true
  elseif p.tag == "font" and (p.attr == "color" or p.attr == "face" or p.attr == "size") then
    p.fontattr = true
  end
end

--- Starts a tag.
local function open_tag(p: Place, closing: boolean)
  p.phase = "tag_name"
  p.tag = ""
  p.closing = closing
  p.equiv = false
  p.fontattr = false
  p.meta_line = 0
  p.meta_col = 0
  p.split = false
end

--- Moves `p` over `text` one state at a time. A run of text ends where a
--- slot or the template does, so the places a slot may not stand in
--- (inside a tag) are never left half read.
local function scan(p: Place, text: string)
  if p.raw_tail ~= "" and (p.phase == "raw" or p.phase == "rcdata") then
    text = p.raw_tail .. text
    p.raw_tail = ""
  end
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
        p.murky = p.murky or p.stack ~= ""
        i = i + 1
      elseif b == 63 then
        p.phase = "bogus"
        p.murky = p.murky or p.stack ~= ""
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
      if p.bare then
        local first = text:match("^[\t\n\r]*()", i)
        if first <= last then
          p.bare = false
          p.rooted = text:find("^[/\\]", first) ~= nil
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
      p.bare = false
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
        found = script_end(p, text, i)
      else
        found = plain_end(text, i, p.tag)
      end
      local region = text:sub(i, (found or n + 1) - 1)
      local tail = ""
      if found == nil then
        tail = p.tag == "script" and script_tail(region, p.escaped) or plain_tail(region, p.tag)
      end
      -- The tail is judged with the run that completes it, as it would be
      -- whole: `</sty` that becomes `</style>` holds no `<` of the text.
      local settled = region:sub(1, #region - #tail)
      -- TODO: `<noscript>` is read as raw text, as a browser with scripting
      -- on reads it; with scripting off its text is markup, so
      -- `<noscript><style></noscript>{{.x}}</style>` puts the slot in
      -- `<style>` (or `<xmp>`, `<textarea>`, ...) with only the text
      -- escaper. In noscript text, a `<` before a raw text or RCDATA tag
      -- name (style, script, textarea, title, xmp, iframe, noembed,
      -- noframes, plaintext), or a `<!` or `<?`, should make the place
      -- murky, as `<!--` does.
      if (p.stack ~= "" and settled:find("<", 1, true)) or (p.tag == "noscript" and settled:find("<!--", 1, true)) then
        p.murky = true
      end
      if found == nil then
        p.raw_tail = tail
        return
      end
      p.phase = "text"
      p.escaped = false
      p.double = false
      i = found
    end
  end
end

--- Whether byte `b` carries on the tag name, attribute name or unquoted
--- value that `phase` is reading, or gives the attribute just named a value,
--- rather than leaving it whole.
local function continues(phase: Phase, b: integer | nil): boolean
  if b == nil or space(b) or b == 62 then
    return false
  elseif phase == "value_unq" then
    return true
  elseif phase == "after_attr" then
    return b == 61
  end
  return (phase == "tag_name" or phase == "attr_name") and b ~= 47
end

--- Where the byte at `i` of `text`, whose first byte stands at `line` and
--- `col`, stands.
local function locate(text: string, i: integer, line: integer, col: integer): integer, integer
  local before = text:sub(1, i - 1)
  local _, lines = before:gsub("\n", "")
  if lines == 0 then
    return line, col + i - 1
  end
  return line + lines, i - before:match(".*()\n")
end

--- Reads `text` a byte at a time in each place `p` may be, until they are
--- one place, and answers where the rest of it begins. Each must read the
--- same thing: a byte that continues a name or value in one (`ked` after
--- `{{if .a}}chec{{end}}`) or brings a value (`=`), or that leaves them apart
--- in more than phase and attribute (`http-equiv` named in one), makes
--- `late` a refusal at that byte. Until one byte begins a new attribute
--- or ends the tag, they stay apart.
local function settle(p: Place, text: string, line: integer, col: integer): integer
  local i = 1
  while p.alts ~= "" and i <= #text do
    local c = text:sub(i, i)
    local places: {Place} = { p }
    for k in p.alts:gmatch("%S+") do
      places[#places + 1] = as_alt(p, k)
    end
    p.alts = ""
    local one, together, extended = true, true, false
    for _, q in ipairs(places) do
      extended = extended or continues(q.phase, c:byte())
      scan(q, c)
      q.slash = q.phase == "before_attr" and c == "/"
      one = one and alike(p, q)
      together = together and apart(p, q)
    end
    if not extended and one then
      for _, q in ipairs(places) do
        if p.late == "" and q.late ~= "" then
          p.late, p.late_line, p.late_col = q.late, q.late_line, q.late_col
        end
      end
    elseif not extended and together then
      local set: {string: boolean} = {}
      for _, q in ipairs(places) do
        set[alt_key(q)] = true
      end
      p.alts = alts_of(p, set)
    else
      p.late = "a block before this text, or the {{range}} it is in, may leave the tag at different attributes, " ..
        "and this text reads differently after each: in one and not another it carries on a name or value, " ..
        "gives an attribute a value, or ends a name that changes the tag (http-equiv, or color, face or size " ..
        "in <font>)"
      p.late_line, p.late_col = locate(text, i, line, col)
      return #text + 1
    end
    i = i + 1
  end
  return i
end

local function feed(p: Place, text: string, line: integer, col: integer)
  -- Empty text moves nothing; past here it would forget a tag's last `/`.
  if text == "" then
    return
  end
  p.split = p.split or continues(p.phase, text:byte(1))
  local from = p.alts ~= "" and settle(p, text, line, col) or 1
  scan(p, from == 1 and text or text:sub(from))
  p.slash = p.phase == "before_attr" and text:byte(#text) == 47
end

local function slot(p: Place): types.Slot | nil, string
  local phase = p.phase
  if p.alts ~= "" then
    return nil, "a slot after a block whose arms leave this tag at different attributes"
  elseif p.murky then
    return nil, "a slot after markup in <svg>, <math>, <noscript>, <select> or <frameset> that a browser may read differently from the tracker here (see the notes in markup.tl)"
  elseif phase == "text" then
    -- TODO: a `SafeHtml` in a text slot inside `<select>`, `<svg>` or
    -- `<math>`, or after `<frameset>`, is read in that mode, though the
    -- template that made it was checked from plain text: a `<title>` in it
    -- opens nothing in a classic parser's select. Give such a slot a kind
    -- of its own in types.Slot that takes a string or a number only.
    return "text", ""
  elseif phase == "rcdata" then
    if p.raw_tail ~= "" then
      return nil, "a slot after '" .. p.raw_tail .. "' in <" .. p.tag ..
        "> could complete its end tag"
    end
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
        -- TODO: once [`cosmic.html`] carries an escaper for one component of
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
  p.raw_tail = ""
  p.after_url = ctx == "url"
  p.bare = ctx == "url"
  if p.tag == "meta" and p.attr == "content" and ctx == "attr" then
    p.meta_line = line
    p.meta_col = col
  end
end

local function ending(p: Place): string
  if p.murky then
    return "in markup in <svg>, <math>, <noscript>, <select> or <frameset> that the tracker could not follow"
  elseif p.stack ~= "" then
    return "inside <" .. p.stack:match("%S+") .. ">"
  elseif p.select then
    return "inside <select>"
  elseif p.frameset then
    return "inside <frameset>"
  end
  local phase = p.phase
  if phase == "text" then
    return ""
  elseif phase == "rcdata" or phase == "raw" then
    return "inside the text of <" .. p.tag .. ">"
  elseif phase == "value_dq" or phase == "value_sq" or phase == "value_unq" or phase == "before_value" then
    return "inside the value of the attribute '" .. p.attr .. "'"
  elseif phase == "lt" or phase == "end_open" or phase == "tag_name" or phase == "before_attr" or
      phase == "attr_name" or phase == "after_attr" then
    return "inside a tag"
  end
  return "inside a comment or markup declaration"
end

local M: Markup = { start = start, ending = ending, copy = copy, same = same, differ = differ, join = join, feed = feed,
  slot = slot, wrote = wrote, key = key }
return M
