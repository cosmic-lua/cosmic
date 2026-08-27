An unquoted `end` column in a trigger body re-introduces the
false-positive class #1438 fixed: END is in SQLite's fallback-keyword
list, so `CREATE TRIGGER trg AFTER INSERT ON t BEGIN UPDATE u SET end
= 1; END` is legal single-statement SQL — but
cosmic/sqlite/sqltext.tl:105-106 decrements body_depth at the
identifier `end`, hits 0 early, sees the internal `;` as top-level,
and exec refuses a legitimate trigger as "multi-statement".
Over-refusal is the documented safe direction and quoting the column
works around it, but it is exactly the shape the commit set out to
remove. The dangerous direction was hunted and is clean (nested
BEGIN, CASE...END in body and WHEN, a trigger named `begin`,
strings/brackets/comments containing END or `;`, blob literals).
Candidate fix: only treat END as a closer when it is not followed by
`=` / not in column position — or track statement-keyword context;
the fuzz oracle item 3IOHnJFA would catch regressions here.
