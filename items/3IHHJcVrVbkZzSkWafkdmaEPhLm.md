Imported from whilp/cosmopolitan#260.

## Goal

No silent bugs, in the C loop's own tooling: every incremental build in
whilp/cosmopolitan silently ignores header edits, so any measurement or
test run after touching a header may be reading stale objects. This
quietly undermines the optimize skill's C-layer chapter (local A/Bs on
a locally built lua) and every "edit, rebuild, re-run" loop in that
repo.

## Evidence

The issue's repro (2026-08-15, fresh clone): cold build succeeds; edit
any header (mbedtls_config.h, luaconf.h, any libc header); `make
o//tool/lua/lua` answers "up to date". `o//depend` is never generated
and `make depend` errors ("No rule to make target 'o//depend'"), while
`make -n o//depend` resolves the rule and claims it current — the
.DEFAULT-rule machinery (Makefile ~line 666 deletes o/$(MODE)/depend on
any unspecified prerequisite) interacting with the `-include` remake
pass. #186 worked around it with a grep-and-touch before each build.

## Direction

Lands in whilp/cosmopolitan. First establish whether upstream
jart/cosmopolitan shows the same behavior or the fork's slimming
dropped something the depend rule needs; then fix the rule (or the
.DEFAULT interaction) so `o//depend` is produced and consulted, with
the issue's repro as the regression check: edit one header, the
dependent object rebuilds.
