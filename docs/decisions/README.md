# Decisions

architecture decision records for the tradeoffs behind
[goals.md](../goals.md). each entry records what was decided, what was
rejected, and why — so future work (human or agent) does not relitigate
them by accident. the rejected options are the point: an alternative
listed without the reason it lost is an invitation to try it again.

**format:** one record per file, `d<NN>-<slug>.md`, taking the next free
number — never reused, never renumbered. the first line is
`# D<n> — <title>`, then a header block (`date`, `status`) and four
sections: context → decision → rejected → consequences.

**a record's state** is its `status` header, and it is one of three:

| status | meaning |
|---|---|
| `active` | stands as written |
| `amended <YYYY-MM>` | the decision stands; a fact under it moved, and a final `amended` bullet says what |
| `superseded by D<n>` | the call was reversed by a later record |

a merged record's body is never rewritten to look right in hindsight:
an amendment is appended, a reversal is a **new** record that names the
one it replaces, and nothing is ever deleted — a recorded dead end is
the most useful thing here. amending a decision is allowed; doing so
silently is not.

**to add or amend one:** the method is `skills/decide` — when a
tradeoff earns a record, how to write each section, and how to audit
existing ones. the process itself is a decision, recorded in
[D26](d26-decision-records.md). after writing, run
`bin/cosmic _docs/derive.tl` to rewrite the table below; it is derived
from every record's H1 and status, and `_build/docs_test.tl` fails the
build when the committed copy drifts.

| # | decision | status | |
|---|---|---|---|
| D1 | builders of command-line software are the user; agents are the lens | active | [→](d01-users-are-builders.md) |
| D2 | quality is the mission; adoption is not | active | [→](d02-quality-not-adoption.md) |
| D3 | "no silent bugs" is the anchor promise, at full depth | active | [→](d03-no-silent-bugs.md) |
| D4 | portability is delegated to Cosmopolitan | active | [→](d04-portability-via-cosmopolitan.md) |
| D5 | upstream-first, fork-if-blocked on Teal | active | [→](d05-upstream-first-teal.md) |
| D6 | the promise transfers via runtime defaults plus ratchets | active | [→](d06-defaults-plus-ratchets.md) |
| D7 | contained by default where the OS can enforce it | amended 2026-08 (rescoped by D25) | [→](d07-contained-where-enforceable.md) |
| D8 | eval win condition: correctness gates, then efficiency | active | [→](d08-eval-win-condition.md) |
| D9 | batteries include serving; not urgently | active | [→](d09-batteries-include-serving.md) |
| D10 | perpetual right to break | active | [→](d10-right-to-break.md) |
| D11 | sequencing: harness first | amended 2026-08 (the ordering is retired; ranking lives in D25) | [→](d11-harness-first.md) |
| D12 | goals and decisions are separate documents | amended 2026-08 (one record per file; the process is D26) | [→](d12-goals-and-decisions-separate.md) |
| D13 | the build's trust root is one pinned artifact behind one committed fetcher | amended 2026-07 | [→](d13-trust-root.md) |
| D14 | no self-hosting: make stays the graph executor | amended 2026-07 | [→](d14-no-self-hosting.md) |
| D15 | an artifact carries its modules and `embed/**`; shipping is opt-in | active | [→](d15-shipping-is-opt-in.md) |
| D16 | every build input is enumerable from committed files, the version stamp included | active | [→](d16-enumerable-build-inputs.md) |
| D17 | a graph rule's tool prerequisite is a per-tool stamp, not the binary | active | [→](d17-tool-stamps.md) |
| D18 | expensive recipe steps skip on input bytes, not just on mtime | amended 2026-08 (declared env) | [→](d18-step-skip.md) |
| D19 | what "public" means for toolchain modules, and the visibility lint | amended 2026-08 (a root `_tool/` tree) | [→](d19-toolchain-visibility.md) |
| D20 | the naming charter, and the renames that applied it | amended 2026-08 (the kept-POSIX set; rule 11) | [→](d20-naming-charter.md) |
| D21 | carried patches: the middle path between pin and fork | active | [→](d21-carried-tl-patch.md) |
| D22 | the CSPRNG surface is infallible; a broken one crashes | active | [→](d22-infallible-csprng.md) |
| D23 | cosmic.check throws by design; needs/reap may exit | active | [→](d23-check-throws.md) |
| D24 | slot 2 may carry a structured error: concrete per-module records, one `Failure` supertype | active | [→](d24-structured-failures.md) |
| D25 | goals split into ranked outcomes and instruments; ratchets gate, peers are the scoreboard | active | [→](d25-outcomes-and-instruments.md) |
| D26 | a decision record: four sections, a status header, amended in place | active | [→](d26-decision-records.md) |
