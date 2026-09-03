## Change

`cosmic/css.tl:4-15` says the alphanumeric allowlist makes a value safe
"without parsing CSS: none of those bytes can open a string, a comment, a
`url(…)`, or an `expression(…)`". True for OPENING one; false inside one the
template text already opened. CSS Syntax consumes escapes inside a url token
and inside identifiers, so `background: url({{css .x | cosmic.css.safe}})`
with `.x = "javascript:alert(1)"` decodes back to `url(javascript:alert(1))`
(Evidence) — an arbitrary fetch, and a script URL in engines that still honour
it. The same decoding applies in a selector and a property name.

`cosmic/css.tl` (69 lines): rewrite the doc comment at 4-17 to say (a) the
escape is for a property VALUE position (`color: {{css .x}}`) or the body of
a quoted CSS string (`content: "{{css .x}}"`); (b) it is NOT for the inside of
`url(...)`, a selector, a property name, or an `@import`/`@charset` argument,
because CSS decodes hex escapes there and the decoded text is what the parser
reads; (c) a URL inside CSS goes through `cosmic.url.safe_href` (the
whole-URL constructor) and lands as `url("...")` with the template supplying
the quotes. Mirror the wall in `cosmic/css_example.tl`'s comment at 4 and 18
if either implies url() is covered. No behaviour change to `escape`.

Test the diff carries, in `cosmic/css_test.tl`: extend
`test_escape_breaks_out_of_url_and_expression_syntax` (which currently only
asserts no `(`/`)` survive) to assert the exact output
`css.escape("javascript:alert(1)") == "javascript\\3a alert\\28 1\\29 "`, so
the shape the doc warns about is pinned rather than described.

## Evidence

Shape, computed with the escape body of `cosmic/css.tl:18-30` under
`o/bootstrap/cosmic probe.lua`:
```
css(javascript:alert(1)) -> javascript\3a alert\28 1\29 
```
Per CSS Syntax Level 3 §4.3.6 (consume a url token) and §4.3.7 (consume an
escaped code point), `\3a ` inside an unquoted url token is the code point
U+003A, so the token's value is `javascript:alert(1)`.
Doc text claiming coverage: `git show origin/main:cosmic/css.tl | sed -n 12,15p`
```
--- alphanumerics is what makes this safe without parsing CSS: none of
--- those bytes can open a string, a comment, a `url(…)`, or an
--- `expression(…)`.
```
Current test: `git show origin/main:cosmic/css_test.tl | sed -n 19,24p` asserts only `not result:match("[()]")`.

## Non-goals

No CSS-context escaper for url()/selectors: the correct tool there is a URL
allowlist, which is the `safe_href` item (template-url-context). No
markup scanning in the template.
