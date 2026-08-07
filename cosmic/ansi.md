# ansi

 ANSI terminal styling.
 Wraps text in SGR escape sequences for colors and attributes, with
 helpers to strip styling and to decide whether a stream should be
 colored at all. All styling functions are pure and infallible:
 they return the wrapped string and never inspect the terminal —
 gate output with is_enabled() at the call site.

 Example usage:
   local ansi = require("cosmic.ansi")
   if ansi.is_enabled(1) then
     print(ansi.bold(ansi.red("error:")) .. " something broke")
   end

 Styles close with their specific off-code (39 for foreground, 49
 for background, 24 for underline, ...) rather than a full reset,
 so wrapped styles compose: bold(red("x")) renders bold red.
 Caveat: bold and dim share off-code 22, so nesting one inside the
 other ends both at the inner close.

 Reserved names: rgb / color256 (24-bit and 256-color output),
 cursor (movement/erase sequences), and hyperlink (OSC 8) are
 reserved for a post-stable battery. Do not reuse these names.

## Types

### AnsiModule

```teal
local record AnsiModule
  --  Full reset sequence (SGR 0), for manual composition.
  reset: string
  color: function(text: string, c: Color): string
  bg: function(text: string, c: Color): string
  attr: function(text: string, a: Attr): string
  red: function(text: string): string
  green: function(text: string): string
  yellow: function(text: string): string
  blue: function(text: string): string
  magenta: function(text: string): string
  cyan: function(text: string): string
  bold: function(text: string): string
  dim: function(text: string): string
  underline: function(text: string): string
  strip: function(text: string): string
  is_enabled: function(fd?: integer): boolean
end
```

## Functions

### color

```teal
function color(text: string, c: Color): string
```

 Color text's foreground. Closes with code 39 (default foreground)
 so surrounding styles survive.

**Parameters:**

- `text` (string) - The text to style
- `c` (Color) - The foreground color

**Returns:**

- string - The wrapped text

### bg

```teal
function bg(text: string, c: Color): string
```

 Color text's background. Closes with code 49 (default background).

**Parameters:**

- `text` (string) - The text to style
- `c` (Color) - The background color

**Returns:**

- string - The wrapped text

### attr

```teal
function attr(text: string, a: Attr): string
```

 Apply a text attribute. Closes with the attribute's own off-code
 (see the module header for the bold/dim caveat).

**Parameters:**

- `text` (string) - The text to style
- `a` (Attr) - The attribute to apply

**Returns:**

- string - The wrapped text

### red

```teal
function red(text: string): string
```

 Style text red. Shorthand for color(text, "red").

**Parameters:**

- `text` (string) - The text to style

**Returns:**

- string - The wrapped text

### green

```teal
function green(text: string): string
```

 Style text green. Shorthand for color(text, "green").

**Parameters:**

- `text` (string) - The text to style

**Returns:**

- string - The wrapped text

### yellow

```teal
function yellow(text: string): string
```

 Style text yellow. Shorthand for color(text, "yellow").

**Parameters:**

- `text` (string) - The text to style

**Returns:**

- string - The wrapped text

### blue

```teal
function blue(text: string): string
```

 Style text blue. Shorthand for color(text, "blue").

**Parameters:**

- `text` (string) - The text to style

**Returns:**

- string - The wrapped text

### magenta

```teal
function magenta(text: string): string
```

 Style text magenta. Shorthand for color(text, "magenta").

**Parameters:**

- `text` (string) - The text to style

**Returns:**

- string - The wrapped text

### cyan

```teal
function cyan(text: string): string
```

 Style text cyan. Shorthand for color(text, "cyan").

**Parameters:**

- `text` (string) - The text to style

**Returns:**

- string - The wrapped text

### bold

```teal
function bold(text: string): string
```

 Make text bold. Shorthand for attr(text, "bold").

**Parameters:**

- `text` (string) - The text to style

**Returns:**

- string - The wrapped text

### dim

```teal
function dim(text: string): string
```

 Make text dim. Shorthand for attr(text, "dim").

**Parameters:**

- `text` (string) - The text to style

**Returns:**

- string - The wrapped text

### underline

```teal
function underline(text: string): string
```

 Underline text. Shorthand for attr(text, "underline").

**Parameters:**

- `text` (string) - The text to style

**Returns:**

- string - The wrapped text

### strip

```teal
function strip(text: string): string
```

 Remove all SGR escape sequences from text, returning the plain
 string. Only styling sequences (CSI ... m) are removed; other
 escape sequences pass through untouched.

**Parameters:**

- `text` (string) - The possibly-styled text

**Returns:**

- string - The text with SGR sequences removed

### is_enabled

```teal
function is_enabled(fd?: integer): boolean
```

 Decide whether styled output is appropriate for a stream, honoring
 the NO_COLOR convention (https://no-color.org: set to any value,
 including empty, disables color), TERM=dumb, and whether the fd is
 a terminal.

**Parameters:**

- `fd` (integer?) - File descriptor to check (default 1, stdout)

**Returns:**

- boolean - True when it is reasonable to emit styled output
