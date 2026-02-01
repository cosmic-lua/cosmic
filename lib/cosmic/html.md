# html

 HTML utilities.

## Types

### HtmlModule

```teal
local record HtmlModule
  escape: function(str: string): string
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
