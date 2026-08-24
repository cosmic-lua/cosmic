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
  --  Which reader answers: `"auto"` (the default), `"teal"` or `"c"`.
  --  Both admit the same values and refuse the same ones with the same
  --  message, so this picks what runs, not what comes back: it holds
  --  both readers in one process — what a differential test needs — and
  --  pins the Teal one if the C one is ever wrong in the field. `"c"`
  --  without a C reader in the build is refused, never quietly answered.
  engine: string
end
```

### FormatOptions

 How `format` lays its output out. Both layouts admit exactly the
 same values and refuse the same ones by the same key path; what
 differs is the bytes and what they cost to produce.

```teal
local record FormatOptions
  --  `"pin"`, the default, or `"compact"`.
  layout: string
end
```

### LiteralModule

```teal
local record LiteralModule
  parse: function(source: string, opts?: Options): {string: any} | nil, string
  parse_file: function(path: string, opts?: Options): {string: any} | nil, string
  --  The format half: parse(format(v)) round-trips and a value outside
  --  the domain is refused, in either layout — "pin" (the default) is a
  --  fmt fixpoint, "compact" is the faster bulk form; see
  --  _literal_format.
  format: function(value: any, opts?: FormatOptions): string | nil, string
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
 Two readers admit this grammar and answer alike: the C one when this
 build has it and no resolver was asked for, the lexer below
 otherwise. That lexer is the reference implementation, the resolver
 `on_duplicate` needs, and where every refusal is written.
 errors; on_duplicate: resolves a repeated key instead of refusing it;
 engine: "auto" (default), "teal" or "c"

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
 (defaults to the path); on_duplicate: resolves a repeated key;
 engine: "auto" (default), "teal" or "c"

**Parameters:**

- `path` (string) - Path to the file
- `opts` (Options?) - noun: file kind in errors; file: message label

**Returns:**

- {string: - any}|nil The declared table
- string - The error message when unreadable or not a literal

### format

```teal
function format(value: any, opts?: FormatOptions): string | nil, string
```

 Serialize a value as a literal file's source.
 The default `"pin"` layout is the one a committed file wants: one
 entry per line, keys sorted and bracketed, and a `cosmic --check
 fmt` fixpoint, so the file this writes is the file the formatting
 gate accepts. `"compact"` is the bulk layout for data read back by
 machine and never formatted: the same domain and the same
 refusals, on one line, encoded in C — several times faster and
 smaller, with no fixpoint promise. `"compact"` asks for smaller
 output rather than promising it: the few values the C encoder
 cannot spell as literals (a reserved word as a key,
 `math.mininteger`) come back in the `"pin"` layout instead, so what
 this returns is always something `parse` reads back.

**Parameters:**

- `value` (any) - The value to serialize
- `opts` (FormatOptions?) - layout: "pin" (default) or "compact"

**Returns:**

- string - | nil The literal source, or nil when the value is outside the domain
- string? - Error message on failure, naming the key path refused
