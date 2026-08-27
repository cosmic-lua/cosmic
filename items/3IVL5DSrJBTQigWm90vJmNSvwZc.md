Three follow-ups to the closure-carry patch (#1442), each
probe-verified against the pinned checker. (1) Untested soundness
shapes: the ipairs-to-pairs assigned-scan fix exists for assignment
inside an `else` block, inside a stepless `fornum` body, and inside an
assignment statement's rvalue — none is pinned in
cosmic/teal_closure_test.tl (only a top-level statement assignment
is), so a re-port after a tl pin bump could silently reintroduce a
soundness hole. (2) Conservative regression: defining ANY closure now
widens, in the ENCLOSING code, every narrow on a name assigned
anywhere in the file — `guard, then define a lambda, then use` fails
where stock passed (probe: `v = pick(); v = pick(); if not (v is
string) then return end; local cb = function(): integer return 1 end;
v:upper()` now errors). Fix direction: chunk-root scan for the closure
body, own-body scan for the continuation. (3) `assigned_anywhere`
walks the whole chunk AST per narrowed name per function boundary,
uncached (closure.tl widen sites; tl.lua:10787) — memoize per name, and
measure on the tree's largest files first.
