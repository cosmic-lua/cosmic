# literal

 Teal source read and written as data: one `return { … }` of literals.
 Lexed and matched, never loaded and never called; format/format_file
 write what parse reads and refuse what parse would refuse.
 This is the reader behind `*_pin.tl` (`cosmic --make fetch`), and it
 is public because it has callers outside `cosmic/` — this repo's own
 build tooling reads its dependency pins with it, and any project
 that wants a config file which *cannot do anything* wants exactly
 this. A file read this way can declare values and nothing else: no
 concatenation, no variables, no function calls. Not because those
 are hard to support, but because "this file cannot do anything" is
 the property worth having.

 Nested tables and `["key"] =` entries are admitted; everything else
 is refused by name, with the line it was found on.

     local literal = require("cosmic.literal")
     local cfg = literal.parse_file("config.tl")

## Types

### Parsed

 One parsed table literal: the value, and the index just past its
 closing `}` — one record keeps the error in slot 2.

```teal
local record Parsed
  value: {string: any}
  next: integer
end
```

### Options

 Options for parse/parse_file: how errors talk about the file.
 (The field is `file`, not `where`, which Teal reserves.)

```teal
local record Options
  --  File name to prefix messages with. Default "literal" for parse;
  --  parse_file defaults it to the path it read.
  file: string
  --  What to call the file in errors — `cosmic --make` reads pins with
  --  noun "pin", so the same grammar complains about "a pin". Default
  --  "literal".
  noun: string
  --  Resolves a key repeated within one table instead of refusing it.
  --  Default nil: a repeated key is refused, naming both lines.
  on_duplicate: OnDuplicate
end
```

### LiteralModule

```teal
local record LiteralModule
  parse: function(source: string, opts?: Options): {string: any} | nil, string
  parse_file: function(path: string, opts?: Options): {string: any} | nil, string
  --  The format half: parse(format(v)) round-trips, a value outside the
  --  domain is refused, output is a fmt fixpoint; see _literal_format.
  format: function(value: any): string | nil, string
  format_file: function(path: string, value: any): boolean, string
end
```

### Token

 One lexical token: its raw text, what it is, and the line it began on.
 Lexing itself lives in `cosmic._literal_lex` (see that module's
 header for why this module lexes for itself rather than borrowing
 `tl.lex`); `Token` and `lex` are re-exposed here because `parse_table`
 and `parse` are their callers.

alias of `cosmic._literal_lex.Token` — field and method table: `cosmic --docs cosmic._literal_lex.Token`

### OnDuplicate

 Resolves a repeated key: called with the value already stored for it
 and the newly parsed one for the SAME key in the SAME table. Its
 return value is stored as-is — a nil return stores nil. The resolver
 is infallible: it decides between the two values, it does not fail;
 a duplicate key with no resolver is refused instead, in
 `parse_table` below.

alias of `function`

## Functions

### parse

```teal
function parse(source: string, opts?: Options): {string: any} | nil, string
```

 Read the literal a file returns, without running it.
 errors; on_duplicate: resolves a repeated key instead of refusing it

**Parameters:**

- `source` (string) - The file's contents
- `opts` (Options?) - file: name for messages; noun: file kind in

**Returns:**

- {string: - any}|nil The declared table
- string - The error message when the file is not a literal

### parse_file

```teal
function parse_file(path: string, opts?: Options): {string: any} | nil, string
```

 Read a file as a literal table, without running it.
 (defaults to the path); on_duplicate: resolves a repeated key

**Parameters:**

- `path` (string) - Path to the file
- `opts` (Options?) - noun: file kind in errors; file: message label

**Returns:**

- {string: - any}|nil The declared table
- string - The error message when unreadable or not a literal
