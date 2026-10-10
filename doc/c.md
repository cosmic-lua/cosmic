# c

How to write the C of cosmic's core (`core/`). Read it before writing or
reviewing C.

## warnings and analysis

The core's own C builds under `own_warnings` in `build.zig`, as errors.
Fix a warning rather than silencing it. `-Wcast-qual` is left out only
because the core's calls take const-dropping casts by design.

`bin/zig build analyze` runs the static analyzer over the same files, and
`bin/zig build sanitized` runs it too, so CI fails on a finding.

## what `cosmic fix` checks

`cosmic fix` writes each C file back in Lua's own layout
([`build/c/layout.tl`]), then holds it to the items marked (checked) below, as
[`build/c/rules.tl`] defines them. A case a rule cannot see past goes in
`exempt` there, with its reason.

## the checklist

When writing or reviewing C, check for:

- A value pushed above an open `luaL_Buffer`: only `luaL_addvalue` may
  find one there. Every other buffer call needs the buffer's own slot on
  top. (checked)
- A pointer into a Lua string kept after the value leaves the stack. Copy
  it first. (checked, for a string counted from the top)
- A resource held in a C local across a Lua call that can allocate: any
  call can raise on memory. Hold it in a guard ([`core/guard.h`]), or, for
  one the caller is to own, acquire it after everything that allocates.
  (checked)
- An integer argument cast to `int`. Use `cosmic_checkint` or
  `cosmic_optint` ([`core/check.h`]), which refuse a value that does not
  fit. (checked)
- A binding's failure in another shape than its contract's: a degenerate
  argument raises, and a runtime failure returns `nil` or `false`, a
  message, and an errno ([`core/fail.h`]): `false` through
  `cosmic_fail_effect` for one declared `boolean`, `nil` through
  `cosmic_fail` for one declared a value, never `boolean|nil`. (checked:
  what a binding returns, against its declaration in
  [`core/syscalls.h`])
- A header's function returning `int` that only ever answers 0, 1 or a
  truth: it is a pass or a fail, so it returns `bool`, true for success.
  One forwarding a library's status stays `int`, its contract said where
  it is declared. (checked)
- A function of external linkage returning the same constant on every
  path: it returns `void`. (checked)
- A binding that answers `true` and nothing else on every path: it answers
  nothing. (checked)
- A function a header declares that only its own file refers to: it is
  `static` there and out of the header. (checked, only when every C file
  is checked at once, as CI's `fix --check .` does)
- A function that never returns without `_Noreturn`.
- A new C function without a test that enters it: a whole run fails for
  one unless [`build/c_functions.tl`] exempts it with the reason no test
  can. Allocation-failure paths are walked on the checked core in
  [`core/allocation_test.tl`].

A change to C also runs [`ci/run-local`] ([`doc/contributing.md`]).

[`build/c/layout.tl`]: ../build/c/layout.tl
[`build/c/rules.tl`]: ../build/c/rules.tl
[`build/c_functions.tl`]: ../build/c_functions.tl
[`ci/run-local`]: ../ci/run-local
[`core/allocation_test.tl`]: ../core/allocation_test.tl
[`core/check.h`]: ../core/check.h
[`core/fail.h`]: ../core/fail.h
[`core/guard.h`]: ../core/guard.h
[`core/syscalls.h`]: ../core/syscalls.h
[`doc/contributing.md`]: contributing.md
