## Change

Extend `cosmic.template`'s html mode past HTML text context to the three contexts
that need different escaping, each carried by its own nominal type so the wrong
escaper is a build-time type error rather than an injection.

The core item establishes the mechanism: `cosmic.html` holds `record SafeHtml { raw:
string }` with `safe()` (escapes and wraps) and `trusted()` (wraps only), and the
generator binds every html-mode interpolation through it. This item adds the
remaining contexts and the escapers behind them.

### Contexts and where each escaper comes from

- **URL** (`href`, `src`, an attribute whose value is a URL). `cosmic.url` already
  wraps the needed C bindings — `escape_param`, `escape_path`, `escape_segment`,
  `escape_host`, `escape_fragment`, over `cosmo.EscapeParam` / `EscapePath` /
  `EscapeSegment` / `EscapeHost` / `EscapeFragment`. This item adds a `SafeUrl`
  type and safe-returning constructors; the escaping itself already exists.
- **JavaScript** (inside `<script>`, or an inline event handler). The escaper
  exists at the C boundary and **nothing in cosmic wraps it**:

  ```
  $ grep -rn "EscapeLiteral" --include=*.tl . | grep -v "^./o/"
  $ grep -oE "[A-Za-z]*Escape[A-Za-z]*\(" ../cosmopolitan/tool/net/definitions.lua | sort -u
  EscapeFragment(  EscapeHost(  EscapeHtml(  EscapeIp(  EscapeLiteral(
  EscapeParam(  EscapePass(  EscapePath(  EscapeSegment(  EscapeUser(
  ```

  `cosmo.EscapeLiteral` is the JavaScript string-literal escaper
  (`escapejsstringliteral.c`): it canonicalises encodings, emits UTF-16 `\uxxxx`
  sequences, and substitutes `\xFFFD` for unencodable ints. So the JS half is a
  wrapper plus a `SafeJs` type, not an implementation.
- **CSS.** No escaper exists at any level — the enumeration above is the whole set,
  and there is no `EscapeCss`. This is the only context needing a real
  implementation, and it is the one to size the item around. Decide during
  refinement whether it belongs here in Teal or upstream in
  cosmic-lua/cosmopolitan beside the others; upstream means a pin bump and a
  `definitions.lua` entry in the same commit, per that repo's conventions.

### Attribute position

Interpolating into an attribute value differs from HTML text: quoting matters, and
an unquoted attribute is exploitable in ways a quoted one is not. Decide during
refinement whether the generator **requires** quoted attributes in html mode (a
template-syntax rule the parser can enforce, refusing an unquoted interpolation) or
carries a distinct `SafeAttr` type. The first is smaller and refuses at parse time;
the second is uniform with the rest.

### What the template author writes

Nothing implicit. Each context has its own type, so the pipeline names the escaper
and the checker enforces the match — an interpolation in a `<script>` block bound
as `SafeJs` cannot be satisfied by `html.safe`, and the error names the line.

## Non-goals

- **No context inference.** The generator does not scan surrounding markup to
  decide which escaper you meant. The type at the interpolation is the obligation,
  and it is written down.
- No change to `cosmic.html.escape` / `unescape` signatures.
