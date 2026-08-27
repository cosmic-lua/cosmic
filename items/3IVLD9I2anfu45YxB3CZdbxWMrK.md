Two false-negative gaps in the D23/D30 justification lints
(#1401/#1412). (1) The licence marker is matched anywhere in the RAW
line, not in comment position: _tool/lint.tl:54-63's pattern accepts
`error("bad flag -- throws: see docs")` — a string literal licenses
the throw, likewise `-- assert:`/`-- exits:` inside string content on
the site line. Site DETECTION is token-exact; the justification check
is not. (2) Paren-less call sugar escapes site detection entirely:
_cli/throw_lint.tl:87 and _cli/assert_lint.tl:224 require the next
token to be `(`, so `error "msg"`, `error{...}`, and an aliased `local
exit = os.exit; exit(1)` are never sites. The tree currently contains
zero such spellings (grepped), so both are future holes rather than
live ones — but these lints transfer to user projects, where both
spellings are ordinary Lua. Fix: match the marker against the line's
trailing comment token only, and extend site detection to the string-
and table-call sugar forms.
