--- Text made safe for HTML, as values the type checker will not let a
--- plain string stand in for.
---
--- - [`Html.SafeHtml`] is markup for element content, made by
---   [`Html.escape`] (text, escaped) or [`Html.trust`] (markup you vouch
---   for), and joined by [`Html.concat`].
--- - [`Html.SafeAttr`] is a value for an attribute, made by
---   [`Html.escape_attr`] or [`Html.trust_attr`].
--- - [`Html.SafeUrl`] is a URL for an attribute such as `href`, made by
---   [`Html.href`] (from data, through an allowlist) or [`Html.trust_url`].
---   It is not escaped for an attribute: the page does that where it
---   puts the URL in one.
--- - [`Html.raw`], [`Html.raw_attr`] and [`Html.raw_url`] are the way back
---   to the string.
---
---     local item = Html.escape("Fish & Chips")
---     local row = Html.concat({ Html.trust("<li>"), item, Html.trust("</li>") })
---     local markup = Html.raw(row) -- "<li>Fish &amp; Chips</li>"
---
--- All three types are opaque: a table literal, a string, or one in the other's
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

  --- A value that can go inside a quoted attribute value. Opaque: a
  --- value is made by [`Html.escape_attr`] or [`Html.trust_attr`].
  type SafeAttr = raw_html.SafeAttr

  --- A URL that can go in an `href` or `src`. Opaque: a value is made
  --- by [`Html.href`] or [`Html.trust_url`]. Its text is a URL, not
  --- attribute-escaped.
  type SafeUrl = raw_html.SafeUrl
end

--- `s` as text in element content, or in a quoted attribute value: `&`,
--- `<`, `>`, `"` and `'` become entities, and every other byte is kept.
---
---     Html.raw(Html.escape("a < b")) -- "a &lt; b"
function Html.escape(s: string): Html.SafeHtml
  return raw.escape(s)
end

--- `s` as the value of a quoted attribute (`title="..."`). Every ASCII
--- byte but a letter or a digit becomes a decimal character reference
--- (`&#34;` for a quote, `&#32;` for a space), so nothing in it can end
--- the quotes or open a tag or a reference. It is not for an unquoted
--- value: the empty string leaves nothing there, and `title= href=/y`
--- swallows the next attribute.
---
--- A byte of 0x80 or more is kept, so a UTF-8 character survives
--- whole: a reference per byte would read as other characters. The
--- document is then UTF-8, as its markup is.
---
---     Html.raw(Html.escape_attr("a b")) -- "a&#32;b"
function Html.escape_attr(s: string): Html.SafeAttr
  return raw.escape_attr(s)
end

--- `s` as a whole URL from untrusted data, for an `href`, `src` or the
--- like: `s` itself if a browser would take it for an http, https or
--- mailto URL or for a relative reference, else `about:invalid`. The
--- text is not escaped for an attribute: escape it with
--- [`Html.escape_attr`] where it goes into one.
---
--- What passes is read as a browser reads a URL, with refusals where the
--- browser would silently repair the text:
---
--- - a C0 control byte (`\0` to `\31`, so a tab or a newline too), a DEL,
---   or a space at either end is refused: browsers remove or trim them
---   before reading a scheme, so `java\tscript:` is `javascript:` to them;
--- - a colon before the first `/`, `?` or `#` ends a scheme, which must be
---   a letter then letters, digits, `+`, `-` or `.`, and be `http`, `https`
---   or `mailto` in any case. Another scheme, or text that is no scheme
---   (`%6Aavascript:`, `1a:`), is refused;
--- - with no such colon, the text is a relative reference (`/a?b:c`,
---   `a/b:c`, `?x:y`, `#x:y`, the empty string) and passes, unless it begins
---   with two of `/` and `\`, which a browser takes for a host
---   (`//h`, `\\h`, `/\h`, `\/h`).
---
--- Anything else, in either case, is `about:invalid`. A byte of 0x80 or
--- more and a space inside the text pass.
---
---     Html.raw_url(Html.href("https://example.com/a")) -- "https://example.com/a"
---     Html.raw_url(Html.href("javascript:alert(1)")) -- "about:invalid"
function Html.href(s: string): Html.SafeUrl
  return raw.href(s)
end

--- `s` as a URL that is already safe, unchecked: the one way to put a
--- URL you wrote into a page without the allowlist.
function Html.trust_url(s: string): Html.SafeUrl
  return raw.trust_url(s)
end

--- The string a [`Html.SafeUrl`] holds.
function Html.raw_url(x: Html.SafeUrl): string
  return raw.raw_url(x)
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

--- The markup of `parts`, one after another. `parts` is a sequence:
--- raises on a table with a hole, or a key other than 1 to its length,
--- and on an element that is not a [`Html.SafeHtml`] (one the type
--- checker would have refused, such as a [`Html.SafeAttr`]).
function Html.concat(parts: {Html.SafeHtml}): Html.SafeHtml
  return raw.concat(parts)
end

return Html
