# html

 HTML utilities.

## Types

### HtmlModule

```teal
local record HtmlModule
  escape: function(str: string): string
  unescape: function(str: string): string
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
