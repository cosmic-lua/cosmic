# html

 HTML utilities.

## Types

### SafeHtml

 Escaped HTML, wrapped so a raw `string` cannot reach an HTML-mode
 `cosmic.template` render's output by accident. The only two ways to
 get one are safe() (escapes, then wraps) and trusted() (wraps
 without escaping — the explicit hatch for markup that is already
 rendered, such as a nested template's output).

```teal
local record SafeHtml
  raw: string
end
```

### SafeAttr

 Escaped HTML-attribute-value content, wrapped so a raw `string`
 cannot reach an HTML-mode `{{attr ...}}` interpolation by accident.
 A separate type from `SafeHtml`: an attribute value is safe under a
 different rule than HTML text (escape_attr's wider allowlist, not
 escape()'s five entities), so the two are not interchangeable —
 piping `{{attr .x}}` through `html.safe` is a compile-time type
 error, not a weaker escape silently accepted.

```teal
local record SafeAttr
  raw: string
end
```

### HtmlModule

```teal
local record HtmlModule
  escape: function(str: string): string
  unescape: function(str: string): string
  safe: function(str: string): SafeHtml
  trusted: function(str: string): SafeHtml
  escape_attr: function(str: string): string
  safe_attr: function(str: string): SafeAttr
  trusted_attr: function(str: string): SafeAttr
end
```

## Functions

### escape

```teal
function escape(str: string): string
```

 Escape HTML special characters.
 Converts <, >, &, ", and ' to their HTML entity equivalents.

**Parameters:**

- `str` (string) - The string to escape

**Returns:**

- string - The HTML-safe string

### unescape

```teal
function unescape(str: string): string
```

 Unescape HTML entities: the inverse of escape() — a pair ships
 both halves. Decodes the five entities escape() produces
 (&amp; &lt; &gt; &quot; &#39;) plus their common aliases (&apos;,
 &#34;). Unknown entities pass through unchanged; this is not a
 general HTML parser.

**Parameters:**

- `str` (string) - The string holding HTML entities

**Returns:**

- string - The decoded string

### safe

```teal
function safe(str: string): SafeHtml
```

 Escape str and wrap it as SafeHtml.

**Parameters:**

- `str` (string) - The string to escape

**Returns:**

- SafeHtml - The escaped, wrapped string

### trusted

```teal
function trusted(str: string): SafeHtml
```

 Wrap str as SafeHtml WITHOUT escaping it.

**Parameters:**

- `str` (string) - Markup already known to be safe HTML

**Returns:**

- SafeHtml - The wrapped string, unescaped

### escape_attr

```teal
function escape_attr(str: string): string
```

 Escape str for the value of an HTML attribute — a stricter set
 than escape(): every byte that is not an ASCII letter or digit
 becomes a decimal numeric character reference (`&#DD;`), and every
 byte 0x80 and above (a UTF-8 continuation or lead byte) passes
 through unescaped, since it can never collide with an ASCII
 delimiter. Allowlisting alphanumerics — rather than the five
 entities escape() handles — is what keeps an attribute value safe
 whether or not it ends up quoted: a bare space, `=`, or backtick
 can break out of an UNQUOTED attribute the way `"` breaks out of a
 quoted one, and escape() only covers the quoted case.

**Parameters:**

- `str` (string) - The string to escape

**Returns:**

- string - The attribute-safe string

### safe_attr

```teal
function safe_attr(str: string): SafeAttr
```

 Escape str with escape_attr and wrap it as SafeAttr.

**Parameters:**

- `str` (string) - The string to escape

**Returns:**

- SafeAttr - The escaped, wrapped string

### trusted_attr

```teal
function trusted_attr(str: string): SafeAttr
```

 Wrap str as SafeAttr WITHOUT escaping it.

**Parameters:**

- `str` (string) - An attribute value already known to be safe

**Returns:**

- SafeAttr - The wrapped string, unescaped
