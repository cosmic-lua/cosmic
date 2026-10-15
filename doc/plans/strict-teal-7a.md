# step 7a: narrowing by construction

the design of step 7a in [strict-teal.md](strict-teal.md). it is written
against main with R2 (effectively-final captures) merged, and with the
plan's rule 4: a place is a local or a path of read-only fields from one.

## the model

- declared types are never mutated. a new `checker/facts.tl` holds an
  immutable `Facts`: `t` (place id to narrowed type) and `gone` (place id
  to what removed it, for messages). `nil` means control cannot reach.
- a place's id is its binding's identity, not its name: `Variable.key`, a
  counter value given in `add_var`; `"17"` a local, `"17.f"` a path of
  read-only fields. a `local x = x` is a new variable with a new key, so
  the shadowing cases disappear. `Place.key` stays the display name in
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
- a function body starts from `for_body`: a local, and the read-only
  paths from it, kept only if `local_is_fixed` says nothing assigns it
  after the literal is made. the same test decides whether a test inside
  the body narrows a local of the code around it at all, since the code
  that declares it can assign it while the function is suspended in a
  coroutine. on leaving, the saved facts come back; nothing was
  changed, so there is nothing to undo.
- a fact is dropped only by an assignment to its local. a closure cannot
  assign a local it does not declare (R2), and nothing assigns a read-only
  field after its table is made, so no call, write through an alias,
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

## the order of PRs

each keeps the tree green. PRs 0 to 2 change no verdict; 2a refuses the
narrowings rule 4 no longer allows, with the tree's rewrite; PR 3 moves
exactly the pinned shadow mismatches that remain. the seed (the plan's
step 7b) runs beside these and none of them needs it.

0. a verdict harness: a tool that writes every error and warning
   (`file, code, y, x, text`) for a list of sources, run with the PR's
   checker and main's over the tree, the fuzz corpora and dumped fuzz
   programs. also `Variable.key` and loop ids in the pre-pass (done,
   #3070).
1. `checker/facts.tl` and its property tests (meet is commutative,
   associative, idempotent, with nil as identity; operations agree with a
   model map; frozen values raise on write). unused (done, #3069).
2. shadow mode: the checker keeps `self.facts` beside the old state and,
   under a flag, compares every read. the gate is zero unexplained
   mismatches over the tree, corpora, tests and fuzz. a mismatch that is
   an old-state bug is fixed first, in a PR of its own (done, #3074; the
   flag is off by default and nothing is kept without it).
2a. read-only fields, in the PRs [strict-teal.md](strict-teal.md)'s step
   7a lists: the syntax and the write refusal, the literal rules, interface
   agreement and the casts that would forge a writer, the [`cosmic.sys`]
   audit, rule 11, and the change that declares the tree's read-only
   fields, copies the other narrowed reads to locals, and restricts the
   old narrowing to the same places. the facts then narrow only locals and
   read-only paths, and the field-path and global mismatches pinned by
   shadow mode leave the triage list. the old places are one field deep,
   so a mismatch on a deeper read-only path is expected and pinned. this
   restricts old-side machinery PR 4 deletes, an exception to building
   none, so that PR 3 flips only what the facts decide differently.
3. reads switch to `self.facts`; the old state is written but unread.
   the flipped verdicts are the pinned shadow mismatches, each triaged.
   message text may change where the facts give a better cause; no more
   mirroring of the old wording.
4. the old state is deleted. the checker's pinned type-error count moves
   and is measured and set.
PRs 4b to 9 of the earlier order (one flow pass, function declarations
keeping local facts, joins that unite types, edge-pair conditions, the loop
edge rule, dropping a target after its values) are not built in the fork. the new checker
(the plan's step 10) builds its one pass with them, and a measured need in
the tree before then is the only reason to build one here.

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
  lands, both before PR 3, and the fuzz is shown to find each of the four
  bugs on the checker before its fix.
- until PR 3, an old-narrowing bug is fixed in the facts only and its
  difference pinned; old-side machinery that PR 4 deletes is not built.
- every checker PR gets two independent review rounds.
- what remains pinned in `build/checker_shadow_test.tl` (old drops more
  after #3072, the facts refuse where old misses in loops, and `local x =
  x` widened by name) is PR 3's triage list.

known gaps left with TODOs: a declared field read on a record with
`__index` or `__newindex` drops nothing, which PR 2a ends by narrowing no
mutable field; a `goto` that skips a `<close>`
declaration over-refuses in definite assignment; the shadow's comparison
of generic types equates type variables of one name; the harness compares
codes and messages, not types (`--types`).

## seed constraints

until the plan's step 7b, [`vendor/tl/tl.lua`] (upstream 0.24.8) compiles the checker:
no `name?: T`, no `: never`, no narrowing of a field (copy to a local
first), and `nil` as a typed value through the `local x: T = nil` idiom
with its TODO. the new code lives in `facts.tl` with no type errors;
`tl.tl` gets thin call sites. from step 7b the pinned release compiles it,
and the checker's source may use what that release's checker accepts.

## oracles

- debug invariants (`TL_CHECK_FACTS=1`, on in a CI leg): a fact is always
  a subtype of the declared type; the register is `nil` after a statement
  exactly when `flow.ends` says it ends; the frame stack balances.
- a metamorphic fuzz property: insert, between a test and a narrowed
  read, a statement that changes the place (`x = nil`, a write to a
  read-only field through another reference); the program must then be
  refused, at the read or at the write.
- checked narrowing: under the existing `runtime_checks` option, the code
  generator wraps each read whose type came from a fact in a check of the
  fact (mostly `~= nil`), raising "fact violated at y:x". a CI leg runs the
  whole suite with it, so every narrowed read is checked against real
  runs. normal builds emit nothing, so they pay nothing. it lands before
  PR 3, with the fuzz widening, since PR 3 is where the facts' soundness
  starts to matter.

## risks

- speed: copy-on-write per refinement; sharing, the path and global
  counts, and precomputed keys keep it small. the gate is under 5% on the
  checker's self-compile, per PR.
- message text and the `narrowing_dropped` fields stay byte-identical
  through PR 4; the harness compares text.
- the type report reads narrowed types at declarations and assignments;
  those two collector calls move to where facts are made.

[`cosmic.sys`]: ../../core/syscalls.h
[`vendor/tl/tl.lua`]: ../../vendor/tl/tl.lua
