# 015 — root `init.tl` compiles but silently never ships

severity: low
type: bug
area: `_make/project.tl`, `_make/artifact.tl`

## issue

a file named `init.tl` at the project root gets `import_path()` of nil (the
trimmed path is the empty string after dropping `init`), yet classification
still calls it kind `module`. it is type-checked and compiled to `o/init.lua`
— then `stage_entry` returns nil for a module with no import path, so the
file is silently absent from every artifact.

## where

- `_make/project.tl:141-151` — `import_path("init.tl")` returns nil;
  classify still yields `module`.
- `_make/artifact.tl:157-158` — an import-less module produces no staged
  entry.

## failure scenario

a user writes root `init.tl` expecting `require("<something>")` or an
entry-like behavior (both plausible misreadings of the init convention),
sees it compile cleanly, and finds it missing from the binary at runtime
with no diagnostic.

## suggested fix

pick one and enforce it: either root `init.tl` is meaningless and the
validator refuses it by name ("a root init.tl has no import path; did you
mean main.tl?"), or it gets a defined import path. refusal is the cheaper
and clearer option — nothing in the design gives the project root a module
name to claim.

## test to add

a validator test with a root `init.tl` asserting the refusal message.
