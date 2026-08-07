# Decisions

architecture-decision records for the tradeoffs behind
[goals.md](../goals.md). each entry records what was decided, what was
rejected, and why — so future work (human or agent) does not relitigate
them by accident. amending one is allowed; doing so silently is not.

format: context → decision → rejected → consequences. entries are
append-only and numbered, **one record per file**; a reversal is a new
entry that supersedes the old one, and it says so in its own file rather
than editing the record it replaces.

| # | decision | |
|---|---|---|
| D1 | builders of command-line software are the user; agents are the lens | [→](d01-users-are-builders.md) |
| D2 | quality is the mission; adoption is not | [→](d02-quality-not-adoption.md) |
| D3 | "no silent bugs" is the anchor promise, at full depth | [→](d03-no-silent-bugs.md) |
| D4 | portability is delegated to Cosmopolitan | [→](d04-portability-via-cosmopolitan.md) |
| D5 | upstream-first, fork-if-blocked on Teal | [→](d05-upstream-first-teal.md) |
| D6 | the promise transfers via runtime defaults plus ratchets | [→](d06-defaults-plus-ratchets.md) |
| D7 | contained by default | [→](d07-contained-by-default.md) |
| D8 | eval win condition: correctness gates, then efficiency | [→](d08-eval-win-condition.md) |
| D9 | batteries include serving; not urgently | [→](d09-batteries-include-serving.md) |
| D10 | perpetual right to break | [→](d10-right-to-break.md) |
| D11 | sequencing: harness first | [→](d11-harness-first.md) |
| D12 | goals and decisions are separate documents | [→](d12-goals-and-decisions-separate.md) |
| D13 | the build's trust root is one pinned artifact behind one committed fetcher | [→](d13-trust-root.md) |
| D14 | no self-hosting: make stays the graph executor | [→](d14-no-self-hosting.md) |
| D15 | an artifact carries its modules and `embed/**`; shipping is opt-in | [→](d15-shipping-is-opt-in.md) |
| D16 | every build input is enumerable from committed files, the version stamp included | [→](d16-enumerable-build-inputs.md) |
| D17 | a graph rule's tool prerequisite is a per-tool stamp, not the binary | [→](d17-tool-stamps.md) |
| D18 | expensive recipe steps skip on input bytes, not just on mtime | [→](d18-step-skip.md) |
| D19 | what "public" means for toolchain modules, and the visibility lint | [→](d19-toolchain-visibility.md) |
| D20 | the naming charter: ten rules, and the renames that applied them | [→](d20-naming-charter.md) |
| D21 | carried patches: the middle path between pin and fork | [→](d21-carried-tl-patch.md) |
| D22 | the CSPRNG surface is infallible; a broken one crashes | [→](d22-infallible-csprng.md) |
