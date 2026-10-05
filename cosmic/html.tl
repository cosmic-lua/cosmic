--- Text made safe for HTML, as values the type checker will not let a
--- plain string stand in for.
---
--- - [`Html.SafeHtml`] is markup for element content, made by
---   [`Html.escape`] (text, escaped) or [`Html.trust`] (markup you vouch
---   for), and joined by [`Html.concat`].
--- - [`Html.SafeAttr`] is a value for an attribute, made by
---   [`Html.escape_attr`] or [`Html.trust_attr`].
--- - [`Html.raw`] and [`Html.raw_attr`] are the way back to the string.
---
---     local item = Html.escape("Fish & Chips")
---     local row = Html.concat({ Html.trust("<li>"), item, Html.trust("</li>") })
---     local markup = Html.raw(row) -- "<li>Fish &amp; Chips</li>"
---
--- Both types are opaque: a table literal, a string, or one in the other's
--- place is a type error, and a value is made only in this module, by the
--- escaping or by the `trust` functions, which a review can search for.
--- There is no `__concat` and no `__tostring`: a safe value cannot reach a
--- string except through [`Html.raw`] or [`Html.raw_attr`]. A cast (`x as Html.SafeHtml`)
--- defeats the types, as it does anywhere; it stops forged and
--- accidental values, not deliberate ones.
---
--- The escapers are for UTF-8 documents.

-- The raw module behind every function here lives under the reserved
-- `cosmic.internal.` namespace -- see cosmic/store.tl for why this
-- indirection exists.
local type raw_html = require("cosmic.internal.html")

local extra: any = select(2, ...)
local raw: raw_html
if type(extra) == "table" then
  raw = extra as raw_html
else
  raw = require("cosmic.internal.html")
end

local record Html
  --- Markup that can go in element content as it is. Opaque: a value
  --- is made by [`Html.escape`], [`Html.trust`] or [`Html.concat`].
  type SafeHtml = raw_html.SafeHtml

  --- A value that can go inside an attribute, quoted or not. Opaque: a
  --- value is made by [`Html.escape_attr`] or [`Html.trust_attr`].
  type SafeAttr = raw_html.SafeAttr
end

--- `s` as text in element content, or in a quoted attribute value: `&`,
--- `<`, `>`, `"` and `'` become entities, and every other byte is kept.
---
---     Html.raw(Html.escape("a < b")) -- "a &lt; b"
function Html.escape(s: string): Html.SafeHtml
  return raw.escape(s)
end

--- `s` as the value of an attribute, quoted or not. Every ASCII byte
--- but a letter or a digit becomes a decimal character reference
--- (`&#34;` for a quote, `&#32;` for a space), so nothing in it can end
--- an unquoted value or open a tag or a reference.
---
--- A byte of 0x80 or more is kept, so a UTF-8 character survives
--- whole: a reference per byte would read as other characters. The
--- document is then UTF-8, as its markup is.
---
---     Html.raw(Html.escape_attr("a b")) -- "a&#32;b"
function Html.escape_attr(s: string): Html.SafeAttr
  return raw.escape_attr(s)
end

--- `s` as markup that is already safe, unchecked: the one way to put
--- HTML you wrote, or sanitized, into a page.
function Html.trust(s: string): Html.SafeHtml
  return raw.trust(s)
end

--- `s` as an attribute value that is already safe, unchecked: it must
--- hold nothing that ends the value where it is used.
function Html.trust_attr(s: string): Html.SafeAttr
  return raw.trust_attr(s)
end

--- The string a [`Html.SafeHtml`] holds: markup, escaped as it was made.
function Html.raw(x: Html.SafeHtml): string
  return raw.raw(x)
end

--- The string a [`Html.SafeAttr`] holds.
function Html.raw_attr(x: Html.SafeAttr): string
  return raw.raw_attr(x)
end

--- The markup of `parts`, one after another. Raises on an element that
--- is not a [`Html.SafeHtml`], and on one the type checker would have
--- refused, such as a [`Html.SafeAttr`].
function Html.concat(parts: {Html.SafeHtml}): Html.SafeHtml
  return raw.concat(parts)
end

return Html
