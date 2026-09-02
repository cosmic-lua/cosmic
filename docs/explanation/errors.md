# Why errors are honest nil

why every fallible `cosmic.*` function returns `nil, error` instead of throwing,
and what follows from that for the type, the slots and the modules. the shapes
themselves are in `cosmic --docs reference.errors`.

## The type must admit failure

a function that can fail says so in its return type. `fs.read` returns
`string | nil, string`, not `string`, because a missing file is a normal outcome
and the type is the only place the caller learns about it. a declared `string`
over a value that is sometimes nil is a lie the checker believes. the caller
then indexes a nil at runtime, far from the call that produced it.

the honest type moves the cost to the right place. the caller sees `| nil` at
the call, and the failure is handled where the context to handle it exists.
this is the whole doctrine: the type must admit failure, and library code never
throws.

## Where the checker forces a guard

the checker demands a guard in exactly one position: an index. `s:upper()`,
`t.field` and `a[i]` refuse an unnarrowed `T | nil`. every other position admits
it. a `T | nil` can be assigned to a declared `T`, passed to a non-nil
parameter, added to, and concatenated, and nothing objects.

so a `| nil` annotation is a contract the checker only half enforces. the guard
belongs where the union is produced, at the call that can fail, not downstream
where a caller may or may not index the value. `cosmic --docs howto.narrow-nil`
has the steps for guarding at the call, and `cosmic --docs explanation.types`
has the checker's side.

## Why errors are strings by default

a string is enough for most failures. the caller prints it, logs it, or wraps
it with more context and returns it upward. a failed `cosmo.unix` call already
carries a formatted message and the numeric errno, and `errno.format` and
`errno.is_code` cover the two things a wrapper does with them: add context, and
branch on a code.

a module returns its own error record instead when its failures carry structure
the caller branches on. `cosmic.fetch` classifies every failure with a `kind`,
and a retry policy needs to branch on that kind exhaustively. folding the kind
into the message as a prefix would make callers parse text to branch, which no
language asks of its callers. so the module returns a concrete record with a
typed `kind` field, and the compiler checks the branch.

the record is the module's own, not a shared one. a library-wide error type
would force one enum on every module, and a combinator passing an error through
would flatten it to `message`. classification is by field, never by `is`,
because `is` on a record compiles to a table check and cannot tell one record
from another. `tostring(err)` renders the classified message, and `..` on an
error is a compile error, so rendering is always explicit.

## Why a fallible return has two slots

the two ways everyone calls a fallible function see two slots and no more.
`local v, err = f()` binds two names and drops the rest. `check.must(f())`
feeds slot 2 to `must`'s `err` parameter and never sees slot 3. anything past
the second slot is information the caller has to be told about at every call
site, and one forgotten site is a silent bug.

so extras ride on the value's record. `fs.find` returns a result carrying
`.errors`, and a resource that must be released rides on the record's `__close`.
a `cosmo.*` binding's tuple is decided in C and declared once in the generated
`.d.tl`, so a wrapper names that type instead of restating it.

## Why library code never throws

a throw steals the caller's error handling. the caller loses the value it was
building, the message travels through frames that did not ask for it, and the
only recovery is `pcall`, which erases the type of what came back. a returned
error keeps the decision with the code that has the context to make it.

three boundaries are exempt, because at each of them no caller could receive a
returned value:

- a Lua protocol whose error channel is the throw. `require` distinguishes "not
  found here", a returned string, from "found but broken", a raise. a package
  searcher that returned `nil, string` for a broken module would report it as
  missing.
- a process boundary. a child after `fork` whose `exec` failed has no caller to
  return to; returning would run the parent's continuation in two processes. an
  entry helper that turns a main function's return into an exit status answers
  to the OS.
- an infallible-by-type contract violated past the checker. `cosmic.hash`
  takes a typed `Algo` enum, so the checker already rejects a bad algorithm. a
  value smuggled past it through a cast is a caller bug, and throwing is the
  honest response.

`cosmic.check` is the other exemption, and it is not a boundary but a purpose.
its assertions throw because their caller is the test runner, and an uncaught
error is the failing grade. that is why library code never requires it.

each exempt site states its reason in a marker comment beside the call, so a
reader at the line finds the argument, and a reason that no longer holds is the
signal to return `nil, err` instead.

## Why consistency within a module matters

a caller learns a module's shape once and applies it everywhere. a module that
returns `nil, string` from one function and `false, string` from the next, or
throws from a third, makes every call site a lookup. one shape per module means
the caller's guard is the same at every call, and the reader of that caller
knows what a bare `if not ok` means without opening the module.
