# narrowing by construction

the design of the step of that name in [strict-teal.md]. it is written
against main with [captures are read-only] merged, and with the plan's
rule [narrowing only what nothing else can change]: in the fork a place is
a local. the fork's `readonly` syntax (#3081, #3083) is unused by the tree
and goes with the fork; paths of fixed fields become places in the new
checker ([fields are fixed unless declared mutable]), and its one pass
builds them.

## the model

- declared types are never mutated. a new [`checker/facts.tl`] holds an
  immutable `Facts`: `t` (place id to narrowed type) and `gone` (place id
  to what removed it, for messages). `nil` means control cannot reach.
- a place's id is its binding's identity, not its name: `Variable.key`, a
  counter value given in `add_var`; `"17"` a local. a path of fixed
  fields (`"17.f"`) is the shape the new checker's places take; the fork
  has none. a `local x = x` is a new variable with a new key, so
  the shadowing cases disappear. [`Place.key`] stays the display name in
  messages. a global, a mutable field and an index have no id: a test of
  one narrows nothing.
- operations return new values and share when nothing changes: `with`,
  `without`, `without_prefix` (assignment to a local), `meet` (a key
  survives only if both edges hold it), `restrict` (loops) and `for_body`
  (function bodies). `without_suffix`, `without_paths` and
  `without_globals`, which served writes through aliases, calls and
  globals, go with the places they dropped.
- the checker's existing in-order walk carries one register, `self.facts`,
  updated in Lua's evaluation order. there is no separate graph. the walk
  stays in the checker, not in `flow.tl`: narrowing needs types while it
  walks, and `flow.tl` runs afterwards on syntax. both share the event
  marks (`runs_code`, `never_call`) as they do now.
- a condition leaves a pair, the facts when it is true and when it is
  false. `not` swaps them; `a and b` walks `b` under `a`'s true facts and
  meets the false ones; `or` is its dual; `true` has no false edge, so
  `while true` exits only by `break`. this retires the guard algebra and
  the clock (`prune`, `guard_before`, `drop_clock` and the rest): a drop in
  `b` flows into `b`'s edges by construction.
- a stack of frames collects the other edges: an `if` frame (the meet of
  the branch ends, and the facts when every condition so far was false), a
  loop frame (head, breaks, continues, reads) and a function frame (the
  facts to restore). every join is `Facts.meet`. after `return`, `break`,
  a continue or a call that never returns, the register is `nil`.
- a read is `declared ∩ fact`: the fact if one is held, else the declared
  type. `find_var` returns only declared variables.
- loops are checked once, not to a fixpoint. the head guesses the entry
  facts minus the locals the loop assigns (from the pre-pass, by binding,
  not by name). the body is walked once under the guess. at the end, a
  read of a head fact is refused unless the back edge still supports it,
  and an exit edge keeps a head fact only if the back edge does. a fact
  that came unchanged from the head is recognised by object identity,
  which immutability makes sound.
- a function body starts from `for_body`: a local, kept only if `local_is_fixed` says nothing assigns it
  after the literal is made. the same test decides whether a test inside
  the body narrows a local of the code around it at all, since the code
  that declares it can assign it while the function is suspended in a
  coroutine. on leaving, the saved facts come back; nothing was
  changed, so there is nothing to undo.
- a fact is dropped only by an assignment to its local. a closure cannot
  assign a local it does not declare, and the fork narrows no field, so
  no call, write through an alias,
  operator or metamethod can change a place, and the walk keeps no list of
  what runs code for narrowing. `run_event` stays only to set `runs_code`
  for definite assignment in `flow.tl`. the old narrowing lists what drops
  instead, and each missing entry was a hole (`_G` writes, `__close`, a
  rebinding); the places those holes were in are no longer places.

## what goes

`specialize_var`, the `Specialization` enum, `specialized_from`,
`widened_from`, `is_specialized`, the scope's `narrows`, `widens`,
`dropped` and `hidden`, `widen_in_scope`, `widen_back_var`, `widen_all`,
`widen_all_unions`, `assigned_anywhere`, `get_real_var_from_lower_scope`,
the journal and undo, `enter_function` and `leave_function`, the
`on_drop` hook, and later the guard algebra and the clock. `narrowing.tl`
shrinks to places and the two refinements. `flow.tl`, `captures.tl`,
`find_assignments`, `local_is_fixed` and `check_gotos` stay.

## the PRs, in order

each keeps the tree green. the first three change no verdict; the field
change refuses the narrowings the rule no longer allows, with the tree's
rewrite; the switch moves exactly the pinned shadow mismatches that
remain. [the pinned-release seed] runs beside these and none of them
needs it.

- **the verdict harness (done, #3070).** a tool that writes every error
  and warning (`file, code, y, x, text`) for a list of sources, run with
  the PR's checker and main's over the tree, the fuzz corpora and dumped
  fuzz programs; also `Variable.key` and loop ids in the pre-pass.
- **the facts module (done, #3069).** [`checker/facts.tl`] and its property
  tests (meet is commutative, associative, idempotent, with nil as
  identity; operations agree with a model map; frozen values raise on
  write), unused.
- **shadow mode (done, #3074).** the checker keeps `self.facts` beside the
  old state and, under a flag, compares every read. the gate is zero
  unexplained mismatches over the tree, corpora, tests and fuzz. a
  mismatch that is an old-state bug is fixed first, in a PR of its own.
  the flag is off by default; it gates the comparison, not the facts.
- **the field reads copied.** one change copies the narrowed field reads
  (752, 609 outside tests) to locals and restricts the old narrowing to
  locals. the facts then narrow only locals, and the field-path and global
  mismatches pinned by shadow mode leave the triage list. this restricts
  old-side machinery that the deletion below removes, an exception to
  building none, so that the switch flips only what the facts decide
  differently. the tree declares no read-only field in the fork, so the
  `readonly` syntax and rules (#3081, #3083) stay unused and go with the
  fork; the new checker's fixed fields bring field paths back as places,
  with the same interface agreement under `mut`: a record declares a field
  `mut` exactly when the interface does.
- **the switch to the facts (done).** reads switch to `self.facts`; the old
  state is written but unread. a refusal's cause (the tombstones that
  `narrowing_dropped` and the `narrowing_not_local` note read) comes from the
  facts, as does a loop's refusal of a read of a fact its body drops. the
  flipped verdicts are pinned in [`build/checker_facts_reads_test.tl`], each
  triaged: a use after an assignment or in a loop is told the assignment
  where the old state said nothing; one after a function declaration that
  widened its place is told nothing where the old state named a later
  assignment; the local of `local x = x` keeps its type past a function
  declaration. unreachable code is checked from the facts at the jump, and a
  test inside a function narrows a local of the code around it only if
  nothing assigns it after the function is made. message text may change
  where the facts give a better cause; no more mirroring of the old
  wording.
- **the old narrowing deleted (done).** the scopes' narrowing, the shadow
  comparison and what only they used are gone; the facts' bookkeeping lost
  its `shadow_` and `sh_` names. the tree, ci and the checker-total corpus
  are byte-identical; these verdicts moved, each pinned in
  [`build/checker_facts_reads_test.tl`]:
  - a read of a local that narrowing had put a view over (`local x: T | nil
    = v`, `local x = x`) was credited to the variable of the same name it
    shadows, so the local got a false `unused` warning and the shadowed
    variable went unwarned. the read is now credited to the local (468
    lines over the corpora and sixteen seeds of 400 programs, all removed
    `unused` warnings);
  - an assignment to a `local x = x`, after a function declaration or in a
    loop, is refused against the type the local was narrowed to, as it is
    without the declaration or the loop (the old state widened the local
    by name and accepted it): stricter, and kept as the sound choice;
  - `warning.shadows` for a local that shadows a narrowed variable (a
    parameter or a local narrowed by a test, an assert or an assignment)
    says where that variable was declared; it said nothing, or named an
    assignment;
  - a `<const>` or `<close>` local that a test narrowed can no longer be
    assigned: the old narrowed copy dropped the attribute, so the
    assignment was accepted, and Lua refuses it at load. a soundness fix;
  - the looser direction: after `local x = x` with a function declaration or
    a loop in between, assigning a value that may be nil and using the local
    is accepted (it was refused), as it is without the declaration or the
    loop. this is the nil leniency of a copy of a narrowed local, the TODO
    in [`build/checker_narrowing_test.tl`] on `y = nil` after a test, and
    it ends with the roadmap's nil item;
  - the `unused` and never-read warning of a `local x = x` whose value was
    narrowed shows the narrowed type, as without a function declaration.

  the checker's pinned type-error count moved from 317 to 314 (two calls
  that passed `nil` for a node and a `Variable` literal were in the
  deleted code), measured and set. once the seed step makes the count a
  ceiling that only falls, it is set as one ([a count the tree cannot yet
  bring to zero is a ceiling]).

the refinements that accept more (one flow pass, function declarations
keeping local facts, joins that unite types, edge-pair conditions, the
loop edge rule, dropping a target after its values) are not built in the
fork. [the new checker] builds its one pass with them, and a measured
need in the tree before then is the only reason to build one here.

## what shadow mode found

comparing every narrowed read found four unsound acceptances in the old
narrowing, each fixed on main before shadow mode merged, and each a
consequence of keying facts by name instead of by binding:

- an assignment under a nested test of the same local kept the outer
  narrowing, because `same_type` ignored a string literal (#3071).
- a field fact outlived a new binding of its base name (`local t = s`, a
  loop variable, a parameter). the old side now drops it for good; the
  facts give it back after the inner scope (#3072).
- a write through `_G` or an alias of it kept a narrowed global, and a
  local that shadowed the global hid it from drops (#3073).
- a `<close>` local's `__close` at its block's end dropped nothing, for
  narrowing or definite assignment (#3075).

the facts side was itself unsound three times before review caught it:
drops skipped behind the old side's early returns, no rule for a loop's
next pass, and the close on a `break` edge. the fuzz caught none of these
nor the four above: its generator makes no globals, `_G`, `<close>`,
rebindings, writing metamethods or loop bodies that drop their own facts.
every checker change also needed a second review round. so:

- the fuzz generator is widened to those shapes, and checked narrowing
  lands, both before the switch, and the fuzz is shown to find each of the
  four bugs on the checker before its fix.
- until the switch, an old-narrowing bug is fixed in the facts only and
  its difference pinned; old-side machinery the deletion removes is not
  built.
- every checker PR gets two independent review rounds.
- what remained pinned in the shadow test after the field
  change (`local x = x` widened by name) was the switch's triage list.

known gaps left with TODOs: a declared field read on a record with
`__index` or `__newindex` drops nothing, which narrowing only locals ends; a `goto` that skips a `<close>`
declaration over-refuses in definite assignment; the harness compares
codes and messages, not types (`--types`).

## seed constraints

the pinned release compiles the checker ([the pinned-release seed]), and
the checker's source may use what that release's checker accepts. until
the pin moves to a release with each rule, that is upstream 0.24.8's: no
`name?: T`, no `: never`, no narrowing of a field (copy to a local first),
and `nil` as a typed value through the `local x: T = nil` idiom with its
TODO. the new code lives in `facts.tl` with no type errors; `tl.tl` gets
thin call sites.

## oracles

- debug invariants (`TL_CHECK_FACTS=1`, on in a CI leg): a fact is always
  a subtype of the declared type; the register is `nil` after a statement
  exactly when `flow.ends` says it ends; the frame stack balances.
- a metamorphic fuzz property: insert, between a test and a narrowed
  read, a statement that changes the place (`x = nil`); the program must then be
  refused, at the read or at the write.
- checked narrowing: under the existing `runtime_checks` option, the code
  generator wraps each read whose type came from a fact in a check of the
  fact (mostly `~= nil`), raising "fact violated at y:x". a CI leg runs the
  whole suite with it, so every narrowed read is checked against real
  runs. normal builds emit nothing, so they pay nothing. it lands before
  the switch, with the fuzz widening, since the switch is where the facts'
  soundness starts to matter.

## risks

- speed: copy-on-write per refinement; sharing, the path and global
  counts, and precomputed keys keep it small. the gate is under 5% on the
  checker's self-compile, per PR.
- message text and the `narrowing_dropped` fields stay byte-identical
  until the old narrowing is deleted; the harness compares text.
- the type report reads narrowed types at declarations and assignments;
  those two collector calls move to where facts are made.

[a count the tree cannot yet bring to zero is a ceiling]: strict-teal.md#decisions
[captures are read-only]: strict-teal.md#captures-are-read-only
[fields are fixed unless declared mutable]: strict-teal.md#fields-are-fixed-unless-declared-mutable
[narrowing only what nothing else can change]: strict-teal.md#narrowing-only-what-nothing-else-can-change
[strict-teal.md]: strict-teal.md
[the new checker]: strict-teal.md#the-new-checker
[the pinned-release seed]: strict-teal.md#the-pinned-release-seed

[`build/checker_facts_reads_test.tl`]: ../../build/checker_facts_reads_test.tl
[`build/checker_narrowing_test.tl`]: ../../build/checker_narrowing_test.tl
[`checker/facts.tl`]: ../../checker/facts.tl
[`Place.key`]: ../../build/checker_narrowing_test.tl
