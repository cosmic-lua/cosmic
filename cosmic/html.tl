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
--- - [`Html.SafeResourceUrl`] is a URL the page loads and runs or styles
---   itself by (a `<script>`'s `src`, a `<link>`'s `href`), made only by
---   [`Html.trust_resource_url`]: no allowlist can say that a script is the
---   program's, so a [`Html.SafeUrl`] from data does not stand in for one.
--- - [`Html.SafeUrlPart`] is percent-escaped text for a URL after literal
---   text (a path segment or a query), made by [`Html.url_part`] or
---   [`Html.url_query`].
--- - [`Html.SafeJson`] is JSON text for an attribute such as `hx-vals`,
---   made by [`Html.json`] or [`Html.json_text`]. It has no unchecked door.
--- - [`Html.raw`], [`Html.raw_attr`], [`Html.raw_url`],
---   [`Html.raw_resource_url`], [`Html.raw_url_part`] and [`Html.raw_json`]
---   are the way back to the
---   string.
---
---     local item = Html.escape("Fish & Chips")
---     local row = Html.concat({ Html.trust("<li>"), item, Html.trust("</li>") })
---     local markup = Html.raw(row) -- "<li>Fish &amp; Chips</li>"
---
--- All the types are opaque: a table literal, a string, or one in the other's
--- place is a type error, and a value is made only in this module, by the
--- escaping or by the `trust` functions, which a review can search for.
--- There is no `__concat` and no `__tostring`: a safe value cannot reach a
--- string except through its `raw` function above. A cast (`x as Html.SafeHtml`)
--- defeats the types, as it does anywhere; it stops forged and
--- accidental values, not deliberate ones.
---
--- The escapers are for UTF-8 documents.

-- The raw module behind every function here lives under the reserved
-- `cosmic.internal.` namespace -- see cosmic/store.tl for why this
-- indirection exists.
local type raw_html = require("cosmic.internal.html")

-- The raw JSON reader and writer, not [`cosmic.json`]: that module's types
-- reach [`cosmic.stream`], which every template that imports this module
-- would then load to type-check.

local Failure = require("cosmic.failure")
local Url = require("cosmic.url")
local raw = require("cosmic.internal.html")
local json = require("cosmic.internal.json")

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

  --- A URL of a script or stylesheet the page loads. Opaque: a value is
  --- made by [`Html.trust_resource_url`] alone. Its text is not
  --- attribute-escaped.
  type SafeResourceUrl = raw_html.SafeResourceUrl

  --- Percent-escaped text that is safe in a URL attribute after literal
  --- text: a path segment, from [`Html.url_part`], or a query, from
  --- [`Html.url_query`], which also holds the `&` and `=` it joins with.
  --- Opaque. Its text is not attribute-escaped.
  type SafeUrlPart = raw_html.SafeUrlPart

  --- JSON text. Opaque: a value is made by [`Html.json`] or
  --- [`Html.json_text`], which check it. Its text is not attribute-escaped.
  type SafeJson = raw_html.SafeJson
end

--- `s` as text in element content, or in a quoted attribute value: `&`,
--- `<`, `>`, `"` and `'` become entities, and every other byte is kept.
---
---     Html.raw(Html.escape("a < b")) -- "a &lt; b"
function Html.escape(s: string): Html.SafeHtml
  return raw.escape(s)
end

--- `s` as the value of a quoted attribute (`title="..."` or
--- `title='...'`). `&`, `"`, `'`, `<` and `>` become entities, as
--- [`Html.escape`] writes them, and a backtick, a C0 control byte and a DEL
--- become decimal character references (`&#96;`, `&#10;`, `&#0;`). Every
--- other byte is kept, so a URL or a path reads as it is
--- (`/a/b.jpg`, `https://h/?q=1&amp;r=2`). In a quoted value only its quote
--- ends it and only `&` begins a reference, so nothing in the result can do
--- either, and a browser reads back `s` (a NUL as U+FFFD, as it reads
--- any).
---
--- It is not for an unquoted value, which a space or a `>` ends: the empty
--- string leaves nothing there, and `title= href=/y` swallows the next
--- attribute. [`cosmic.template`] refuses a slot in one.
---
--- A byte of 0x80 or more is kept, so a UTF-8 character survives
--- whole: a reference per byte would read as other characters. The
--- document is then UTF-8, as its markup is.
---
---     Html.raw_attr(Html.escape_attr('say "hi" & go')) -- "say &quot;hi&quot; &amp; go"
---     Html.raw_attr(Html.escape_attr("/images/a.jpg")) -- "/images/a.jpg"
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
--- An absolute http or https URL may point at any host (`http:evil.com`
--- and `https:\\evil.com` pass): `href` keeps a URL from running script or
--- borrowing the page's scheme, and does not pick hosts. A protocol-relative
--- `//host` is refused because it takes the page's scheme without saying
--- so, not because another host is.
---
--- Anything else, in either case, is `about:invalid`. A byte of 0x80 or
--- more and a space inside the text pass.
---
---     Html.raw_url(Html.href("https://example.com/a")) -- "https://example.com/a"
---     Html.raw_url(Html.href("javascript:alert(1)")) -- "about:invalid"
function Html.href(s: string): Html.SafeUrl
  return raw.href(s)
end

--- `s` as a URL that is already safe, unchecked: the one way to make a
--- [`Html.SafeUrl`] without the allowlist. A script's or a stylesheet's
--- URL is a [`Html.SafeResourceUrl`] ([`Html.trust_resource_url`]).
function Html.trust_url(s: string): Html.SafeUrl
  return raw.trust_url(s)
end

--- Whether a template's `{{if}}` or `{{with}}` holds of `v`: it does not
--- of `nil`, `false`, `""`, a safe value of this module that holds `""`
--- (`Html.trust("")`) or a table with no key (an empty list or map, or a
--- record with no field set), and does of anything else, `0` among them.
--- [`cosmic.template`]'s generated code calls it; a program has `#t > 0`
--- and `s ~= ""`.
---
---     Html.filled({}) -- false
---     Html.filled({ "a" }) -- true
---     Html.filled(0) -- true
---     Html.filled(Html.escape("")) -- false
function Html.filled(v: any): boolean
  return raw.filled(v)
end

--- The string a [`Html.SafeUrl`] holds.
function Html.raw_url(x: Html.SafeUrl): string
  return raw.raw_url(x)
end

--- `s` as the URL of a script or stylesheet the page loads, unchecked: the
--- program vouches that what it names is its own. The one way to fill the
--- `src` of a `<script>` or the `href` of a `<link>` in a template.
---
---     Html.raw_resource_url(Html.trust_resource_url("/static/app.js")) -- "/static/app.js"
function Html.trust_resource_url(s: string): Html.SafeResourceUrl
  return raw.trust_resource_url(s)
end

--- The string a [`Html.SafeResourceUrl`] holds.
function Html.raw_resource_url(x: Html.SafeResourceUrl): string
  return raw.raw_resource_url(x)
end

--- `s` as a URL that may only be a relative reference on this origin, for
--- an `href` or `src` the page must not point elsewhere. Like
--- [`Html.href`] but with no scheme allowed: a colon before the first
--- `/`, `?` or `#` is refused, as are a C0 control byte, a DEL, a space at
--- either end, and a start of two of `/` and `\`. Anything refused is
--- `about:invalid`.
---
---     Html.raw_url(Html.local_href("/a?b=c")) -- "/a?b=c"
---     Html.raw_url(Html.local_href("https://example.com/")) -- "about:invalid"
function Html.local_href(s: string): Html.SafeUrl
  return raw.local_href(s)
end

--- `s`, a string or a number, as one piece of a URL: every byte but the
--- unreserved ones (`A-Z a-z 0-9 - . _ ~`) is written `%` and two
--- uppercase hex digits, exactly as [`Url.escape`] writes it. So it is
--- right as a path segment, a query name or value, or a fragment, and
--- holds no `:`, `/`, `\`, `?`, `#`, `&`, `=`, `+` or `@`. A number is
--- written as `tostring` writes it.
---
--- A value that is exactly `.` or `..` is the one difference from
--- [`Url.escape`], because a browser takes those, and their `%2e` spellings,
--- for a dot segment and drops or climbs a segment, so they are written
--- `%252E` and `%252E%252E`, text a server reads as a name that matches
--- nothing. Only the value is seen: author text beside the slot
--- (`/a/.` and a part of `.`) can still make a dot segment.
---
---     Html.raw_url_part(Html.url_part("a b/c")) -- "a%20b%2Fc"
---     Html.raw_url_part(Html.url_part("..")) -- "%252E%252E"
function Html.url_part(s: string | number): Html.SafeUrlPart
  return raw.url_part(s)
end

--- `list` as a query string: each [`Url.Pair`] written `name=value`
--- with both halves escaped as by [`Html.url_part`] but for the dot
--- rule, joined by `&`, in order. A name may repeat. It takes the pairs
--- [`Url.encode_query`] takes and [`Url.decode_query`] returns (a
--- [`Url.Query`]'s `pairs`), and differs from that encoding only in
--- writing a space `%20`, as a URL in a page does, not `+`. Raises,
--- blaming its caller, for a [`Url.Pair`] whose name or value is not a
--- string, which only a caller past the checker can pass. Like
--- `ipairs`, it reads `list` up to its first hole.
---
---     Html.raw_url_part(Html.url_query({ { name = "q", value = "a b" }, { name = "t", value = "x&y" } })) -- "q=a%20b&t=x%26y"
function Html.url_query(list: {Url.Pair}): Html.SafeUrlPart
  local entries: mut {{string}} = {}
  for i, pair in ipairs(list) do
    entries[i] = { pair.name, pair.value }
  end
  local part, why = raw.url_query(entries)
  if part == nil then error(why .. " (a Url.Pair's name and value)", 2) end
  return part
end

--- The string a [`Html.SafeUrlPart`] holds.
function Html.raw_url_part(x: Html.SafeUrlPart): string
  return raw.raw_url_part(x)
end

--- `s`, a string or a number, as CSS identifier text in a quoted
--- attribute, for a selector such as `hx-target="#row-..."`. It is
--- `CSS.escape`, whose result needs no escaping as an attribute. Letters,
--- digits (but a leading one), `-` (but alone), `_` and bytes of 0x80 or
--- more stay; every other ASCII byte is a backslash, its code in lowercase
--- hex and a space (`,` is `\2c `); NUL is U+FFFD. The space ends the
--- escape, so a literal space after the slot is still a combinator. Only
--- identifier text is covered, not the inside of a CSS string.
---
---     Html.raw_attr(Html.escape_css_attr("x, body")) -- "x\\2c \\20 body"
function Html.escape_css_attr(s: string | number): Html.SafeAttr
  return raw.escape_css_attr(s)
end

--- `value` as JSON text, encoded as [`Json.encode_any`] encodes it.
--- Returns `nil` and a Failure where it cannot be encoded (a function, a
--- cycle, NaN, ...).
---
---     Html.raw_json(assert(Html.json({ id = 7 }))) -- '{"id":7}'
function Html.json(value: any): (Html.SafeJson) | (nil, Failure)
  local text, why = json.encode(value)
  if text == nil then return nil, Failure.new("json: " .. why) end
  return raw.trust_json(text)
end

--- `text` as JSON text already encoded, if [`Json.check`] reads it.
--- Returns `nil` and a Failure otherwise.
function Html.json_text(text: string): (Html.SafeJson) | (nil, Failure)
  local ok, why = json.check(text)
  if not ok then return nil, Failure.new("json: " .. why) end
  return raw.trust_json(text)
end

--- The string a [`Html.SafeJson`] holds: JSON, not escaped for an
--- attribute.
function Html.raw_json(x: Html.SafeJson): string
  return raw.raw_json(x)
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
