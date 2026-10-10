# Typed templates

A port of the `old` branch's [`cosmic.template`] (#1599, #1648, #1653,
#1654, #1658), redesigned for the current tree.

## What carries over

- A template compiles to Teal source; there is no template engine at
  run time, and every guarantee is the type checker's.
- A template names its data type first: `{{type Page from myapp.page}}`.
  Teal records are nominal, so a typo'd field (`{{.user.nmae}}`) is a
  type error, not empty output.
- Actions: `{{.a.b}}`, `{{if}}`/`{{else if}}`/`{{else}}`/`{{end}}`,
  `{{range}}` (rebinds dot to each element), `{{with}}` (rescopes dot),
  pipeline stages `{{.x | myapp.fmt.date}}` (a function by import path),
  and the trim markers `{{-` and `-}}`, which drop the whitespace beside
  them.
- No `{{template}}` action: a compiled template exports `render(d: T)`,
  so composing one in another is a pipeline stage naming its `render`.
- Generated code never shadows a local (a warning is a refusal).

## What changes

### Safe types are opaque, made in C

On `old`, `SafeHtml` was `record SafeHtml raw: string end`: any table
literal `{raw = "<script>"}` type-checked as one. Now [`cosmic.html`] is a
core C module, and `SafeHtml`, `SafeAttr` and `SafeUrl` are records
declared `userdata`. The checker refuses a table literal, a string, and
one context's type in another's place (checked: `got {}, expected
m.SafeHtml`; `SafeHtml is not a m.SafeAttr`). A value of one is made
only by:

- `escape(s): SafeHtml`, `escape_attr(s): SafeAttr`: the escaping is
  done in C, so making the value is the proof it was escaped.
  `escape_attr` turns every ASCII byte but a letter or digit into a
  decimal character reference, so a value is safe in a quoted attribute
  (not an unquoted one: an empty value leaves nothing, and the next
  attribute is read as its value; the compiler refuses an unquoted slot); bytes of
  0x80 or more pass, since a reference per byte would not keep a UTF-8
  character whole (the document is UTF-8);
- `href(s): SafeUrl`: a whole URL from data, through an allowlist
  (http, https, mailto, or a relative reference that is not
  protocol-relative; any control byte, DEL or edge space refused, since
  browsers strip them before reading a scheme; a colon before the first
  `/`, `?` or `#` must end an allowed scheme), else `about:invalid`. The
  result is the URL, not attribute-escaped; the template escapes it where
  it splices it. `trust_url(s)` and `raw_url(x)` are its other two;
- `trust(s)` and `trust_attr(s)`: the unchecked doors, named so they can
  be found;
- `concat({SafeHtml}): SafeHtml`.

`raw(x: SafeHtml): string` and `raw_attr(x: SafeAttr): string` are the
only way back to a string: Teal refuses one parameter typed as a union of
two userdata records ("cannot discriminate a union between multiple
userdata types"), so each type has its own. No `__concat` or
`__tostring`, so a leak is greppable. What opacity does not stop: a
cast (`x as SafeHtml`), which the tree's contracts refuse in its own
modules but a project may write. It stops forged and accidental values,
not deliberate ones.

### Escaping follows the slot's position

On `old`, an author wrote a context word (`{{url .x}}`, `{{js .x}}`)
and piped through the matching escaper; choosing wrong was the main
hazard. Now the compiler tracks the literal markup around each slot
with a small HTML state machine and knows its context:

- text: a `string` or number is escaped with `escape`; a `SafeHtml`
  goes in as is;
- a quoted attribute value: `escape_attr`; a `SafeAttr` as is;
- a quoted URL attribute value (`href`, `src`, `action`, `formaction`,
  ...): `href`, then attribute escaping; a `SafeUrl` as is;
- any other Safe type in a slot is a type error.

Refused, as a compile error naming the line and column: a slot in an
unquoted attribute value, a tag or attribute name, an `on*` attribute,
`style` attribute, a comment, or inside `<script>` or `<style>` (whose
escapers were where `old`'s bugs were: #1654, #1658). Each is a
roadmap entry, not a promise.

HTML is the default mode; `{{mode text}}` opts out, returning a plain
`string` and escaping nothing.

As built (`cosmic/template/`), where it differs from the above:

- A URL slot must begin the attribute's value (`href="{{.u}}"`, not
  `href="/a/{{.id}}"`: a piece of a URL needs an escaper for a piece,
  [`doc/roadmap.md`]), and the literal text after it, up to the first `/`,
  `?` or `#`, may not hold `:` or `&`, which could complete a scheme, and
  may not begin with `/` or `\`, which after a value of `/` would make a
  protocol-relative `//host`. A URL that is a base and a path is built in a
  typed function and passed whole.
  A `{{range}}` body is walked twice, so a URL it began is not fresh the
  second time round; the arms of a block must end in the same place in the
  markup.
- A number is accepted in a text or attribute slot (written with
  `tostring`, which has no markup byte); a URL slot takes a string or a
  `SafeUrl`.
- `<title>` and `<textarea>` slots take a string or a number, escaped,
  never `SafeHtml`: trusted markup would end the element.
- `{{with}}` runs its body when the value is truthy. `{{with}}` and
  `{{range}}` take one `{{else}}` (a range's runs when the list has no
  first element); `{{else if}}` in them is refused.
- Refused as well as the places above: `srcdoc`, `srcset` and `ping`
  attributes; the `content` of a `<meta>` that has `http-equiv` (anywhere
  in the tag) and the `charset` of a `<meta>`; every attribute of
  `<script>`; a URL attribute of `script`, `link`, `object`, `embed`,
  `base`, `use` and `applet`; every attribute of the SVG animation
  elements; the text of `<xmp>`, `<iframe>`, `<noembed>`, `<noframes>`,
  `<noscript>` and `<plaintext>`; any attribute named `on...`.
- `<svg>` and `<math>` are followed only as far as their elements,
  attributes and text. A comment, CDATA, `<!` or `<?`; a tag that takes the
  parser out of foreign content, or one the browser reads HTML in; an end
  tag that is not the innermost element's; an `<svg>` in a `<select>`; and
  raw text in them that holds a `<`, make the place murky, and every later
  slot in the template is refused.

### Templates are source files

`pages/home.tmpl` is a module, `pages.home`, built by the build itself,
for a project and for cosmic's own tree alike: `require("pages.home")
.render(d)`, with nothing generated checked in. `pages/init.tmpl` is
`pages`. A `.tmpl` and a `.tl` at one import path are refused as any two
files are. A `derive_templates` step in [`build/derivation.tl`] (beside
`derive_doc_guides`) writes a `derived` row per template, keyed by the
template's hash; [`cosmic.template`] joins the analyzer's identity, so a
change to the compiler, or a new cosmic, regenerates every template.
`cosmic fix` accepts a `.tmpl` as check-only (it parses it); there is
no formatter.

### Errors land on the template's line

Generated code keeps the template's lines: line N of `home.tmpl` is
line N of its module. The prelude is joined onto line 1, each line of
literal text is one generated line, and the closing `return` sits on
the last. The build already attributes a derived module's errors to its
origin file, so a type error or a traceback reads `pages/home.tmpl:12:
... SafeHtml ...`. Columns are the generated code's: the line is what
the build maps back, and a column map is not worth its cost until
something reads columns (a plain comment in `codegen.tl`).

### Tests type-check generated output in process

As [`test/visibility_test.tl`] and [`cosmic/fs_kind_test.tl`] do, a test
writes a small project (a `page.tmpl` and its data module) into its
temporary directory, stages it, and compiles it with [`build.work`],
[`build.importer`] and [`build.teal`], asserting either a clean compile or
a refusal naming `page.tmpl:<line>` and the Safe type.

## The sequence

1. [`cosmic.html`] in C: `SafeHtml`, `SafeAttr`, `escape`, `escape_attr`,
   `trust`, `trust_attr`, `raw`, `raw_attr`, `concat`; this plan.
2. `href`, `trust_url`, `raw_url` and `SafeUrl`, the allowlist scanned in C (not
   [`cosmic.url`]'s parse, which is not a browser's).
3. `cosmic.template`: lexer, parser, HTML context tracker, line-keeping
   code generation, its fuzz test.
4. `.tmpl` in the build: the derivation, its keying, `fix`, the layout
   and the project guide, the in-process type-check tests, an example.

[`build.importer`]: ../../build/importer.tl
[`build.teal`]: ../../build/teal.tl
[`build.work`]: ../../build/work.tl
[`build/derivation.tl`]: ../../build/derivation.tl
[`cosmic.html`]: ../../cosmic/html.tl
[`cosmic.template`]: ../../cosmic/template/init.tl
[`cosmic.url`]: ../../cosmic/url.tl
[`cosmic/fs_kind_test.tl`]: ../../cosmic/fs_kind_test.tl
[`doc/roadmap.md`]: ../roadmap.md
[`test/visibility_test.tl`]: ../../test/visibility_test.tl
