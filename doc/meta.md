# how docs work here

## docs are always right

a doc describes either the current state or an intended one. either
way, when the code and the doc disagree, the code is wrong and the
code changes. a doc is never edited to match a bug.

what is intended and not yet built shows in the doc's snippets: a
snippet that cannot run yet is skipped, and the skip says so. a doc
with no skipped snippets describes what works today.

## every snippet runs

a doc includes code snippets. every snippet is tested by the build,
or is explicitly skipped with a reason. there is no third kind.

a doc is a literate program. the build compiles it to one Teal file:
the prose becomes comments, the fenced blocks become the code, in
order, sharing one scope. a doc is a test the way a `*_test.tl` is,
and it passes or fails as one.

- a fenced block tagged `teal` or `lua` is code. it compiles under
  the checker and runs. output shown after it is asserted.
- a block tagged `teal skip=<reason>` becomes a comment, and the
  reason is visible to the reader. `skip=intended` marks a snippet
  that waits on work not yet done; `skip=network` marks one that
  needs a host the build does not have.
- a block tagged `sh` is a command line. it runs under the fence and
  its verdict line is asserted.
- a block tagged `text` is prose in a box. nothing runs.

the build keys a doc by content hash like any test and records its
verdict in the same database. a doc whose snippet fails is a failing
gate. a skip that no longer needs to be one is a lint finding.
## docs are short and stand alone

a doc says one thing. a reader gets what they need from that doc
without opening another, except by a link they choose to follow.
prefer a second short doc to a long one.

a doc states what something is for and the details a reader needs to
use it. it does not carry history, commit references, or the story of
how it got that way; the decision log holds that.

## the language

clear technical English in the spirit of a simplified style, not
under its rules. concretely:

- one idea per sentence. short sentences. a verb in each.
- say the thing, not a name for the thing. expand an acronym once.
- prefer the plain word: `use` over `utilize`, `before` over `prior
  to`, `if` over `in the event that`.
- state facts. "the build fails" not "the build should fail".
- an example is worth a paragraph of description, and it runs.
