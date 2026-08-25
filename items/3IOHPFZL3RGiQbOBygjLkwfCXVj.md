`db:exec` refuses a legitimate single-statement CREATE TRIGGER with
a wrong diagnosis. Measured 2026-08-25 at main a0c4ebd: the trigger
body's internal semicolons — `CREATE TRIGGER trg AFTER INSERT ON t
BEGIN UPDATE ...; END` — trip sqltext.has_multiple_statements
(cosmic/sqlite/sqltext.tl:45), so exec returns "multi-statement sql
is not supported here" about one statement. exec_script runs it
fine, but the error misdiagnoses and nothing points a trigger
author there; no test in cosmic/sqlite covers TRIGGER at all
(grep -rln TRIGGER cosmic/sqlite/*_test.tl is empty). The fix
options to settle in plan: teach the scan that a semicolon inside a
CREATE TRIGGER ... BEGIN/END block is internal (the lexical rule is
bounded: only triggers embed statements in sqlite DDL), or keep the
refusal and name triggers in the message ("a CREATE TRIGGER body
belongs in exec_script"). Either way the sqltext scan gains trigger
fixtures — its coverage floor is the module's lowest (29 of 41
lines) with the skip branches untested.
