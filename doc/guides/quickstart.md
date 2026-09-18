# quickstart

cosmic is one executable: the Lua runtime, the Teal compiler, and a
standard library, `cosmic.*`, for the everyday things a script needs.
This guide runs two of those modules and shows what each one prints.

## hashing bytes

`cosmic.hash` turns a string into its SHA-256 digest, as 64 lowercase
hex characters.

```teal
local Hash = require("cosmic.hash")

print(Hash.hex_sha256("cosmic"))
```

```output
01307b41e7ff0bb31cca03fb7ff5bea9fdb3dd83afaca63d588a0c07e7ae98b8
```

## reading a file back

`cosmic.fs` reads and writes files. This example is two pieces: a
companion file, `notes.txt`, and the entry code that reads it.

```teal file=notes.txt
hello from notes.txt
```

```teal
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")

local content, trouble = Fs.read(tmp .. "/notes.txt")
if content == nil then
  error(trouble)
end
print(content)
print(Hash.hex_sha256(content))
```

```output
hello from notes.txt
568a78ac9be8ab08ce84c90363cef53bab5d6aecf684e83cd44193dbad50cca6
```

## what is not here yet

Running another program is not built yet (see roadmap.md's
child-process spawning entry), so this example only shows the shape it
will have. It compiles as a comment, not as code, and does not run.

```teal skip=intended
local Child = require("cosmic.child")

local result = Child.run({ "echo", "hello" })
print(result.stdout)
```
