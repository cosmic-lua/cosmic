# literal

 Teal source read as **data**: one `return { … }` of literals, lexed
 and matched, never loaded and never called.

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
     local cfg = literal.of_file("config.tl")

## Types

### Token

 One lexical token: its raw text, what it is, and the line it began on.
 This module lexes for itself rather than borrowing `tl.lex`, so a
 safe-config reader does not drag in the ~15k-line Teal compiler. A
 stripped artifact keeps `cosmic/**` and drops `tl.lua`, so a shared
 lexer would make `require("cosmic.literal")` throw `module 'tl' not
 found` in exactly the artifacts whose authors want a config file
 that cannot do anything. The literal grammar needs identifiers,
 strings, numbers and punctuation; that is the lexer below, and it
 leaves this module with no dependency beyond `cosmic.fs`.

```teal
local record Token
  tk: string
  kind: string
  y: integer
end
```

### Options

 Options for of_source/of_file: how errors talk about the file.
 (api-review-6: these were two message-wording positionals. The
 field is `file`, not `where`: `where` opens a record invariant
 clause in Teal and cannot name a field.)

```teal
local record Options
  --  File name to prefix messages with (of_source only — of_file
  --  always uses the path it read). Default "literal".
  file: string
  --  What to call the file in errors — `cosmic --make` reads pins with
  --  noun "pin", so the same grammar complains about "a pin". Default
  --  "literal".
  noun: string
end
```

### LiteralModule

```teal
local record LiteralModule
  parse: function(source: string, opts?: Options): {string: any} | nil, string
  parse_file: function(path: string, opts?: Options): {string: any} | nil, string
  --  DEPRECATED aliases (api-review-8 pin-advance transition)
  of_source: function(source: string, opts?: Options): {string: any} | nil, string
  of_file: function(path: string, opts?: Options): {string: any} | nil, string
end
```

## Functions

### parse

```teal
function parse(source: string, opts?: Options): {string: any} | nil, string
```

 Read the literal a file returns, without running it.

**Parameters:**

- `source` (string) - The file's contents
- `opts` (Options?) - where: file name for messages; noun: file kind in errors

**Returns:**

- {string: - any}|nil The declared table
- string - The error message when the file is not a literal

### parse_file

```teal
function parse_file(path: string, opts?: Options): {string: any} | nil, string
```

 Read a file as a literal table, without running it.

**Parameters:**

- `path` (string) - Path to the file
- `opts` (Options?) - noun: file kind in errors (where is always the path)

**Returns:**

- {string: - any}|nil The declared table
- string - The error message when unreadable or not a literal
