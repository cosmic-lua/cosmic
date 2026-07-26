# 016 — relative `COSMIC_MAKE` resolves against the project root, not cwd

severity: low
type: bug
area: `_make/graph.tl`

## issue

`find_make` runs after `open_project` has chdir'd to the project root, so a
relative `COSMIC_MAKE` value resolves against the *project root* rather than
the directory the user invoked from. the code takes explicit care to avoid
exactly this for `arg[-1]` (`_make/init.tl:252-255` absolutizes it before
the chdir) but not for the env var.

## where

- `_make/graph.tl:240-247` — `fs.abspath(named)` on the env value, post
  chdir.
- `_make/init.tl:252-255` — the pattern done right for `arg[-1]`.

## failure scenario

the documented fixture workflow itself:

```
cp -r _make/testdata/hello /tmp/h && cd /tmp/h
COSMIC_MAKE=o/cosmo-make <cosmic> --make build   # relative, meaning ./o in $PWD
```

works only by accident when cwd == root; from a parent directory
(`cosmic --make build /tmp/h` with a relative `COSMIC_MAKE`) it silently
looks inside `/tmp/h/…` instead. all existing tests pass absolute paths, so
nothing catches it.

## suggested fix

absolutize `COSMIC_MAKE` at process start, alongside the `arg[-1]` handling
in `_make/init.tl`, before any chdir — same rule, same place.

## test to add

a graph test setting a relative `COSMIC_MAKE` and invoking against a project
in a different directory, asserting the engine resolves relative to the
invoking cwd.
