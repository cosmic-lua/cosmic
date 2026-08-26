## Evidence

Hit on 2026-08-26 while working `3ISlY5Xl` (PR #1419).

An item carries ONE `claim`, and `move ID check --force --why …`
overwrites it with the forcing session's identity. The `work` skill's
final gate rests on that field: "the claim recorded when it pulled the
item survives into `check` and says who did it", so `next` can withhold
a verdict on work the asking session built. A forced takeover erases
exactly that record.

Reproduced, in the board's own history:

- `2893e03e move 3ISlY5Xl ready -> do` — session
  `c16dd460-326a-50f1-b68a-6203f2b87f11` claims and builds the change
  that becomes PR #1419.
- `b6647184 move 3ISlY5Xl do -> check` — same session hands it over.
- `6b3caed4 verdict 3ISlY5Xl request changes (check -> do) by
  24939d25-aad7-5219-92d5-6c587a02f3b7` — reviewed, bounced.
- `6552ce69 move 3ISlY5Xl do -> check (forced: …)` — session
  `24939d25` pushed the one-line rework and took the claim to hand it
  back, because `move` REFUSED with "3ISlY5Xl is claimed by
  c16dd460… — take over a live claim with --force --why".

After that last commit the item reads `claim:
24939d25-aad7-5219-92d5-6c587a02f3b7`. `c16dd460`, which wrote every
line of the diff under review except a deleted comment paragraph, is
no longer recorded anywhere on the item. `next` run under `c16dd460`
will now offer it that PR to accept, and nothing in the tool knows
better. The guarantee the whole review gate is built on — never your
own — is silently void for this item, and for any item a forced
takeover has touched.

Note this is not the same gap as `3ISUA9aR` (a backward `do -> ready`
dropping a claim without `--force`). That one loses a claim; this one
REPLACES a claim whose only remaining job was to remember the builder.
Both point at the same underlying shape: one mutable `claim` field is
being asked to carry two different facts — who holds the work now, and
who built what is under review.

Worth noting about the phase this was hit in: the takeover itself was
the right motion. One worker, a `check` item bounced back to `do` under
a claim from an earlier run, and the chain's only unblock was to finish
it. What is missing is not the ability to take over — it is that taking
over should not cost the board its memory of the builder.

Shapes worth weighing (this item does not pick one):

- a separate `built_by` set the item accumulates and never overwrites,
  with `next` and `verdict` refusing a verdict from any session in it;
- `--force` on a claim takeover appending rather than replacing;
- deriving the builder from the board's own log (the `move … -> do`
  commits already name every session that held it) instead of from a
  field.
