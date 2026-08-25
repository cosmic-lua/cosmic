Fuzz cosmic.sqlite.sqltext's statement scan. The scan is the guard
between every parameterized exec/query and sqlite's
silently-runs-only-the-first-statement behavior — a false negative
reopens exactly the silent-prefix bug the wrapper exists to prevent,
and a false positive refuses legitimate SQL (the CREATE TRIGGER
misdiagnosis is a known one, its own item). It is also the sqlite
module's least-covered file: 29 of 41 lines in .cosmic-coverage at
2026-08-25, with the quoted-string, bracket-identifier, and comment
skip branches among the untested lines. The property for
_fuzz/: generate SQL-shaped strings mixing statements, quoted
strings with doubled-quote escapes and embedded semicolons,
backtick and bracket identifiers, line and block comments, and
trailing semicolons; assert the scan agrees with an oracle that
counts statements by actually preparing successive statements with
sqlite (prepare returns the tail position, so the oracle is exact
on valid SQL), and never crashes or hangs on invalid input. Seeds
follow the existing _fuzz driver conventions (FUZZ_SEED replay,
budget).
