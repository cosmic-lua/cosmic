Both literal readers — cosmic/_literal_lex.tl and cosmopolitan's
tool/net/llua.c — diverge from `load` on the short-string CR family,
the same defect class #1436/#1447 (\z, long brackets) fixed, left
unfixed for the third line-crossing construct. Confirmed against
third_party/lua/llex.c (read_string folds \<LF>, \<CR>, \<CR><LF>,
\<LF><CR> all to one "\n" via inclinenumber; raw CR and LF both refuse
as unfinished string): (a) `"a\<CR><LF>b"` — a CRLF checkout's
line-continuation — is REFUSED by both engines where load accepts
value "a\nb" (_literal_lex.tl:118-137 consumes \+CR as an opaque pair
then the raw LF hits the "\n"-only terminator; llua.c:208-215's escape
table has no CR entry); (b) `"a\<CR>b"` refused, load accepts; (c)
`"a\<LF><CR>b"` — both engines ACCEPT with the WRONG VALUE "a\n\rb"
vs load's "a\nb", a silent value divergence in the module whose
contract is "result equals what executing the source returns"; (d) raw
CR inside a short string is accepted by both engines, load refuses —
the C half of (d) is already filed as 3IVBT4ya; (e) llua.c:149's
SkipTrivia ends a `--` comment only at LF where load's lexer also ends
at CR, so a lone-CR file's comment swallows source. One defect class,
two repos: the Teal-side fix lands in cosmic, the C twin plus (e) in
whilp/cosmopolitan (extend llua.c:196's terminator check and the
escape table), with raw-byte-13 differential tests on both sides —
the existing %q-based byte sweep escapes CR so never covers it.
