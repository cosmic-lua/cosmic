Two of the nine remaining from-any casts exist because resolving a
unix constant BY NAME has no typed surface: cosmic/errno.tl:52
(`(unix as {string: any})[name] as integer` behind code_of, the
errno-name lookup the whole errno.is_code idiom rests on) and
cosmic/quicksand/proc.tl:262 (`by_name[s] as integer` for signal names
in become_init), measured 2026-08-26 at cosmic main b4ad036b. The
constants are registered dynamically from the magnum tables (the
E*/SIG* families, per the coverage test's LoadMagnums note), so the
record type generated for `unix` cannot be indexed by a runtime
string. The unconstrained-cosmo fix: expose the magnum tables as REAL
map values — unix.E: {string: integer} and unix.SIG: {string:
integer} (or one unix.constant(name) -> integer|nil lookup) — built in
C from the same tables that register the constants, annotated as
table<string, integer>, conformance-probed. Both casts then close as
plain typed indexes, and dynamic Lua callers get a first-class lookup
instead of probing the module table.
