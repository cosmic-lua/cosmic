# step 7a: narrowing by construction

the design of step 7a in [strict-teal.md](strict-teal.md). it is written
against main with R2 (effectively-final captures) merged.

## the model

- declared types are never mutated. a new `checker/facts.tl` holds an
  immutable `Facts`: `t` (place id to narrowed type), `gone` (place id to
  what removed it, for messages), and counts of field-path and global keys
  so a call is O(1) when there are none. `nil` means control cannot reach.
- a place's id is its binding's identity, not its name: `Variable.key`, a
  counter value given in `add_var` and `add_global`; `"17"` a local,
  `"17.f"` a field path, `"g:name"` a global. a `local x = x` is a new
  variable with a new key, so the shadowing cases disappear. `Place.key`
  stays the display name in messages.
- operations return new values and share when nothing changes: `with`,
  `without`, `without_prefix` (assignment to a local), `without_suffix`
  (a write to `.f` through any base), `without_paths` (a call),
  `without_globals`, `meet` (a key survives only if both edges hold it),
  `restrict` (loops) and `for_body` (function bodies).
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
- a function body starts from `for_body`: every field path dropped, and a
  local kept only if `local_is_fixed` says nothing assigns it after the
  literal is made. on leaving, the saved facts come back; nothing was
  changed, so there is nothing to undo.
- drop events stay where they are (calls, metamethod operators and
  indexes, `is`, iterators, writes through a reference). one
  `run_event` replaces `drop_all`: it drops field paths and globals and
  sets `runs_code` for `flow.tl`.

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

each keeps the tree green. the first five change no verdict.

0. a verdict harness: a tool that writes every error and warning
   (`file, code, y, x, text`) for a list of sources, run with the PR's
   checker and main's over the tree, the fuzz corpora and dumped fuzz
   programs. also `Variable.key` and loop ids in the pre-pass.
1. `checker/facts.tl` and its property tests (meet is commutative,
   associative, idempotent, with nil as identity; operations agree with a
   model map; frozen values raise on write). unused.
2. shadow mode: the checker keeps `self.facts` beside the old state and,
   under a flag, compares every read. the gate is zero unexplained
   mismatches over the tree, corpora, tests and fuzz. a mismatch that is
   an old-state bug is fixed first, in a PR of its own.
3. reads switch to `self.facts`; the old state is written but unread.
   the harness diff is empty.
4. the old state is deleted. the checker's pinned type-error count moves
   and is measured and set.
5. function declarations keep local facts, as function expressions do
   (accepts more; resolves the TODO in `local_function`).
6. joins unite types instead of requiring the same one (accepts more).
7. edge-pair conditions replace the guard algebra and the clock.
8. the loop edge rule replaces the text-order rule (accepts more: a fact
   re-tested after a drop, drops in branches that leave).
9. if needed, an assignment drops its target after the values are
   evaluated, not before.

each of 5 to 9 ships alone with the harness's list of flipped verdicts,
every flip triaged, and the fuzz soundness property green.

## seed constraints

[`vendor/tl/tl.lua`] (upstream 0.24.8) compiles the checker: no `name?: T`,
no `: never`, no narrowing of a field (copy to a local first), and `nil`
as a typed value through the `local x: T = nil` idiom with its TODO. the
new code lives in `facts.tl` with no type errors; `tl.tl` gets thin call
sites.

## oracles

- debug invariants (`TL_CHECK_FACTS=1`, on in a CI leg): a fact is always
  a subtype of the declared type; the register is `nil` after a statement
  exactly when `flow.ends` says it ends; the frame stack balances.
- a metamorphic fuzz property: insert, between a test and a narrowed
  read, a statement that changes the place (a call that writes the field,
  a write through another reference, `x = nil`); the program must then be
  refused.
- checked narrowing: under the existing `runtime_checks` option, the code
  generator wraps each read whose type came from a fact in a check of the
  fact (mostly `~= nil`), raising "fact violated at y:x". a CI leg runs the
  whole suite with it, so every narrowed read is checked against real
  runs. normal builds emit nothing, so they pay nothing.

## risks

- speed: copy-on-write per refinement; sharing, the path and global
  counts, and precomputed keys keep it small. the gate is under 5% on the
  checker's self-compile, per PR.
- message text and the `narrowing_dropped` fields stay byte-identical
  through PR 4; the harness compares text.
- the type report reads narrowed types at declarations and assignments;
  those two collector calls move to where facts are made.

[`vendor/tl/tl.lua`]: ../../vendor/tl/tl.lua
