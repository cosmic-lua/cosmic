# how docs work here

## docs are always right

a doc describes either the current state or an intended one. either
way, when the code and the doc disagree, the code is wrong and the
code changes. a doc is never edited to match a bug.

what is intended and not yet built shows in the doc's examples: an
example that cannot run yet is skipped, and the skip says so. a doc
with no skipped examples describes what works today.

## every example runs

a doc includes examples. every example is compiled by the build, and
run when it says what it prints. there is no third kind, other than
an explicit skip with a reason.

an example is the shape Go gave it: a function-sized unit with its
own scope, compiled every time, run when it declares its output. in
a doc, an example is one or more fenced blocks, and the build turns
each example into its own Teal chunk; nothing leaks from one example
to the next.

- a fenced block tagged `teal` or `lua` opens an example, or joins
  the one before it when tagged `teal continue`. it compiles under
  the checker.
- a block tagged `teal file=<path>` is a file in that example's
  project rather than its entry; a multi-file guide is one example
  with several files and one entry. the entry is the block without
  a `file=`.
- a block tagged `output` that follows an example is what the entry
  prints, asserted line by line. an example with no `output` block
  compiles and does not run.
- a block tagged `sh` is a command line. it runs under the fence and
  its verdict line is asserted by the `output` block after it.
- a block tagged `teal skip=<reason>` is compiled by nothing, and
  the reason is visible to the reader. `skip=intended` marks an
  example that waits on work not yet done; `skip=network` marks one
  that needs a host the build does not have.
- a block tagged `text` is prose in a box. nothing runs.

the build keys each example by content hash like any test and
records its verdict beside the tests. a doc whose example fails is a
failing gate. a skip that no longer needs to be one is a lint
finding.

## docs are short and stand alone

a doc says one thing. a reader gets what they need from that doc
without opening another, except by a link they choose to follow.
prefer a second short doc to a long one.

a doc states what something is for and the details a reader needs to
use it. it does not carry history, commit references, or the story of
how it got that way.

## the language

clear technical English in the spirit of a simplified style, not
under its rules. concretely:

- one idea per sentence. short sentences. a verb in each.
- say the thing, not a name for the thing. expand an acronym once.
- prefer the plain word: `use` over `utilize`, `before` over `prior
  to`, `if` over `in the event that`.
- state facts. "the build fails" not "the build should fail".
- an example is worth a paragraph of description, and it runs.
