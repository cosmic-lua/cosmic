# template

 Compiles template text into typed Teal module source. No template
 engine, no runtime, no reflection: this is a text-to-text
 transform, and every guarantee comes from feeding what it emits
 through `cosmic --check types`.

 A template names its data type up front —
 `{{type Page from myapp.page}}` — because Teal records are
 nominal: an inferred record type is one nothing else can satisfy,
 and two templates over one `Page` would need two incompatible
 records. Field paths use the record's own field names
 (`{{.user.name}}`), so `{{.user.nmae}}` is a build-time type error
 rather than a typo that renders as nothing.

 There is no `{{template}}` action: a compiled template exports
 `render(d: T): string`, so composing one inside another is a
 pipeline stage naming that function — one rule instead of two, and
 typed. `{{mode html}}` returns `cosmic.html.SafeHtml` instead, and
 types every interpolation through it, so a raw `string` cannot
 reach an HTML template's output without an explicit escaper
 (`cosmic.html.safe`) or an explicit claim of already-safe markup
 (`cosmic.html.trusted`) — nothing is escaped implicitly, and a
 missing escaper is a compile error naming the template line.

 Example usage:
   local template = require("cosmic.template")
   local src = "{{type Page from myapp.page}}<h1>{{.title}}</h1>"
   local out, err = template.compile(src, "page")
   if not out then
     io.stderr:write("page: " .. err .. "\n")
   else
     fs.write("o/page_render.tl", out)
   end

## Types

### TemplateModule

```teal
local record TemplateModule
  compile: function(src: string, name: string): string | nil, string
end
```

## Functions

### compile

```teal
function compile(src: string, name: string): string | nil, string
```

 Compile a template into Teal module source.
 The generated module `require`s the record's declared import path
 and, in `{{mode html}}`, `cosmic.html`; it exports one function,
 `render(d: <Record>): string` (`html.SafeHtml` in mode html). Each
 interpolation is preceded by a `-- <name>:<line>` comment, so a
 type error in the generated module — an unescaped `{{.body}}` in
 HTML mode, a typo'd field — is reported against the template line
 that caused it.
   `-- <name>:<line>` source-mapping comments, and in any parse
   error, which also carries the template's own line and column

**Parameters:**

- `src` (string) - The template source
- `name` (string) - A name for the template: used only in the

**Returns:**

- string|nil - The generated Teal module source
- string - The error on a malformed template
