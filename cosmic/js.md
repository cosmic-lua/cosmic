# js

 JavaScript string-literal escaping.

## Types

### SafeJs

 Escaped JavaScript string-literal content, wrapped so a raw
 `string` cannot reach a `{{js ...}}` interpolation by accident. The
 only two ways to get one are safe() (escapes, then wraps) and
 trusted() (wraps without escaping — the explicit hatch for a
 literal that is already known to be safe, such as a numeric
 literal formatted by hand).

```teal
local record SafeJs
  raw: string
end
```

### JsModule

```teal
local record JsModule
  escape_literal: function(str: string): string
  safe: function(str: string): SafeJs
  trusted: function(str: string): SafeJs
end
```

## Functions

### escape_literal

```teal
function escape_literal(str: string): string
```

 Escape str for use as the CONTENT of a `'`- or `"`-quoted
 JavaScript string literal inside a `<script>` block — the caller
 writes the surrounding quotes. Canonicalizes the input's UTF-8,
 emits `\uXXXX` sequences for every non-ASCII code point (the
 output is therefore plain ASCII), and also encodes the
 HTML-sensitive characters (`<`, `>`, `&`, …) plus backtick, `$`,
 `{`, `}` and `"` as `\uXXXX` — including when one of them is
 immediately preceded by a literal backslash in the input — so a
 literal built with this needs no separate `cosmic.html.escape`
 even inside a `<script>` block, and cannot be used to open a
 template literal or its `${...}` interpolation if it ever ends up
 between backticks instead. Not for template literals, not for
 `on*=` attributes (the HTML tokenizer does not honor JavaScript's
 backslash escapes), and not for a bare, unquoted expression slot.
 An input sequence this cannot decode as UTF-8 is treated as
 ISO-8859-1; an int with no UTF-16 representation becomes the
 `\xFFFD` replacement character.

**Parameters:**

- `str` (string) - The string to escape

**Returns:**

- string - The literal-safe string

### safe

```teal
function safe(str: string): SafeJs
```

 Escape str with escape_literal and wrap it as SafeJs.

**Parameters:**

- `str` (string) - The string to escape

**Returns:**

- SafeJs - The escaped, wrapped string

### trusted

```teal
function trusted(str: string): SafeJs
```

 Wrap str as SafeJs WITHOUT escaping it.

**Parameters:**

- `str` (string) - A JavaScript string-literal body already known to be safe

**Returns:**

- SafeJs - The wrapped string, unescaped
