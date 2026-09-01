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

### HtmlModule

```teal
local record HtmlModule
  escape: function(str: string): string
  unescape: function(str: string): string
  safe: function(str: string): SafeHtml
  trusted: function(str: string): SafeHtml
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
