# css

 CSS value escaping. No `cosmo.*` binding does this — unlike HTML,
 URL, and JavaScript, cosmopolitan carries no CSS escaper, so this
 module implements the escape itself rather than wrapping one.

## Types

### SafeCss

 Escaped CSS content, wrapped so a raw `string` cannot reach a
 `{{css ...}}` interpolation by accident. The only two ways to get
 one are safe() (escapes, then wraps) and trusted() (wraps without
 escaping — the explicit hatch for a value already known to be
 safe, such as a fixed color keyword).

```teal
local record SafeCss
  raw: string
end
```

### CssModule

```teal
local record CssModule
  escape: function(str: string): string
  safe: function(str: string): SafeCss
  trusted: function(str: string): SafeCss
end
```

## Functions

### escape

```teal
function escape(str: string): string
```

 Escape str for interpolation into a CSS declaration's VALUE position
 (`color: {{css .x}}`) or the body of an already-quoted CSS string
 (`content: "{{css .x}}"`). Every byte that is not an ASCII letter or
 digit becomes a CSS hex escape `\XX ` — a backslash, the byte's
 value in lowercase hex, and a trailing space that terminates the
 escape per the CSS syntax rules (consumed as the terminator, not
 rendered) — and every byte 0x80 and above passes through
 unescaped, since a UTF-8 continuation or lead byte can never
 collide with an ASCII delimiter.
 This does NOT make a value safe inside `url(...)`, a selector, a
 property name, or an `@import`/`@charset` argument. CSS Syntax
 decodes a hex escape wherever it can appear — inside a url token
 and inside an identifier — so the parser reads the DECODED text,
 not the escaped one: `escape("javascript:alert(1)")` produces
 `javascript\3a alert\28 1\29 `, and `url({{that}})` decodes right
 back to `url(javascript:alert(1))`, an arbitrary fetch and (in
 engines that still honor it) a script URL. A URL that needs to sit
 inside CSS goes through `cosmic.url.safe_href` — the whole-URL
 allowlist — and is interpolated already quoted, with the template
 supplying the quotes: `url("{{ ... | url.safe_href}}")`.

**Parameters:**

- `str` (string) - The string to escape

**Returns:**

- string - The CSS-safe string

### safe

```teal
function safe(str: string): SafeCss
```

 Escape str with escape and wrap it as SafeCss.

**Parameters:**

- `str` (string) - The string to escape

**Returns:**

- SafeCss - The escaped, wrapped string

### trusted

```teal
function trusted(str: string): SafeCss
```

 Wrap str as SafeCss WITHOUT escaping it.

**Parameters:**

- `str` (string) - A CSS value already known to be safe

**Returns:**

- SafeCss - The wrapped string, unescaped
