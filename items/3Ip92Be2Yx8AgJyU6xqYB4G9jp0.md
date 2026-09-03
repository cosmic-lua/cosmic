## Change

The `{{url ...}}` context in `cosmic.template`'s html mode splices a
`SafeUrl.raw` into an attribute unchanged (`cosmic/template/codegen.tl:141-143`),
and every per-component constructor except `safe_param` keeps `:`, `/`, `'`, `&`,
`(`, `)` (see Evidence). The PR's own idiom, `<a href="{{url .title |
cosmic.url.safe_path}}">` (`cosmic/template/init_test.tl:84`), therefore emits
`javascript:alert(1)` verbatim. Two changes in one PR — they are halves of one
contract, the html-mode `{{url}}` slot:

1. `cosmic/url.tl` (440 lines; the new function plus doc must fit under the
   500 cap — trim the `SafeUrl` doc block at 339-345 if needed): add
   `safe_href(str: string): SafeUrl`, infallible, the constructor for a WHOLE
   URL landing in an `href`/`src`/`action` attribute. Body: (a) if `str`
   contains any byte < 0x20 or 0x7f, return `{raw = "about:invalid"}` — browsers
   strip tab/newline before scheme detection, so `java\tscript:x` (which
   `url.parse` reads as scheme-less, see Evidence) would otherwise pass; (b)
   `local u = parse(str)`; nil → `about:invalid`; (c) accept when `u.scheme` is
   `http`, `https` or `mailto` (compare lowercased), or when `u.scheme == nil`
   AND `u.host == nil` (path-relative and absolute-path references); anything
   else — `javascript:`, `data:`, `vbscript:`, and the protocol-relative
   `//evil.com/x`, which parses to scheme nil / host `evil.com` — returns
   `about:invalid`; (d) accepted input returns `{raw = format(u)}`, so each
   component is re-escaped by the existing `format` (spaces to `%20`, extra
   leading slashes to `%2F`). `about:invalid` is WHATWG's always-failing URL;
   `trusted()` stays the hatch for a deliberate `//cdn` or custom scheme. Add
   `safe_href` to `UrlModule` and `M`. Rewrite the `SafeUrl` doc (339-345) and
   each `safe_param/safe_path/safe_segment/safe_host/safe_fragment` doc to say:
   these escape ONE COMPONENT of a URL whose scheme and authority the template
   text already fixes (`href="/users/{{url .id | cosmic.url.safe_segment}}"`);
   a whole URL from data goes through `safe_href`.
2. `cosmic/template/codegen.tl`: for `node.ctx == "url"` only, emit
   `parts[#parts + 1] = <html_alias>.escape(vN.raw)` instead of `vN.raw`
   (`ctx.html_alias` is already on `Ctx`, line 93). `html.escape` turns the
   `'`, `"`, `<`, `>`, `&` the path/fragment/authority tables keep into
   entities, which is what makes the value safe inside a quoted attribute; the
   tables already percent-encode space and backtick, so an unquoted attribute
   is covered too. Update the module doc at lines 7-15 to say the url context
   is the one context that escapes twice (URL rules in the constructor,
   attribute rules at the splice) and why. Update `cosmic/template/init.tl`
   17-29 to name `safe_href` as the whole-URL escaper.

Tests the diff carries:
- `cosmic/url_test.tl` (347 lines): `safe_href` probes — `"javascript:alert(1)"`,
  `"JavaScript:alert(1)"`, `"data:text/html,x"`, `"//evil.com/x"`,
  `"java\tscript:x"` each yield `raw == "about:invalid"`;
  `"http://ok.example/a b?q=1&r=2"` yields `"http://ok.example/a%20b?q=1&r=2"`;
  `"/x/y?z=1"`, `"mailto:a@b.example"`, `"relative/path"` pass through
  `format` unchanged; `"' onmouseover='alert(1)"` (no scheme, no host) is
  accepted and its `'` survives as `%27`-free text — the codegen half is what
  neutralises it, which the next test pins.
- `cosmic/template/codegen_test.tl`: the url-context test at 98-105 asserts
  `parts%[#parts %+ 1%] = html%.escape%(v1%.raw%)` and that the html-context
  test still emits bare `.raw`.
- `cosmic/template/init_test.tl`: the every-context fixture at 74-97 switches
  its `href` to `cosmic.url.safe_href` and still type-checks.

## Evidence

Tables, from the cosmopolitan checkout (`origin/master`):
`grep -n "xlat" net/http/kescapepath.c net/http/kescapesegment.c net/http/kescapeauthority.c net/http/kescapefragment.c net/http/kescapeparam.c`
```
kescapepath.c:      -DUL '.-~_@:!$&'"'"'()*+,;=/'
kescapesegment.c:   -DUL '.-~_@:!$&'"'"'()*+,;='
kescapeauthority.c: -DUL '_.!~*'"'"'();&=+$,-'
kescapefragment.c:  -DUL '/?.~_@:!$&'"'"'()*+,;=-'
kescapeparam.c:     -DUL '.-*_'
```
Behaviour under the pinned binary (`o/bootstrap/cosmic probe.lua`, probe
calling `cosmic.url`; `safe_*` are `{raw = escape_*(s)}` per `cosmic/url.tl:353-383`):
```
escape_path("javascript:alert(1)") -> "javascript:alert(1)"
escape_fragment("javascript:alert(1)") -> "javascript:alert(1)"
escape_path("//evil.com/x") -> "//evil.com/x"
escape_path("' onmouseover='alert(1)") -> "'%20onmouseover='alert(1)"
escape_host("' onmouseover='alert(1)") -> "'%20onmouseover='alert(1)"
escape_path("java\9script:x") -> "java%09script:x"
escape_param("javascript:alert(1)") -> "javascript%3Aalert%281%29"
parse("javascript:alert(1)") scheme=javascript host=nil path=alert(1)
parse("//evil.com/x") scheme=nil host=evil.com path=/x
parse("java\9script:x") scheme=nil host=nil path=java	script:x
```
Splice: `git show origin/main:cosmic/template/codegen.tl | sed -n 138,144p`
```
    if ctx.mode == "html" then
      local target = CTX_TARGET[node.ctx]
      ...
      out[#out + 1] = indent .. "parts[#parts + 1] = " .. v .. ".raw"
```
Callers of the url context outside tests: `git grep -n "{{url" origin/main | grep -v _test` — doc comments only (`cosmic/template/init.tl:19`, `cosmic/url.tl:340`), so no template in the tree changes output.

## Non-goals

No markup scanning: the context word stays the author's declaration
(`cosmic/template/parse.tl:80-89`). `cosmo.EscapePath` and friends are C
contracts and stay as they are; the fix is cosmic-side.
