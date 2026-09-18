# how docs work here

## docs are always right

a doc describes either the current state or an aspirational one. it
says which. either way, when the code and the doc disagree, the code
is wrong and the code changes. a doc is never edited to match a bug.

an aspirational doc carries a marker at the top, one of:

- `state: current` — this is how it works today.
- `state: intended` — this is how it will work; the gap is known work.

when the gap closes, the marker changes. a doc without a marker is
`current`.

## every snippet runs

a doc includes code snippets. every snippet is tested by the build,
or is explicitly skipped with a reason. there is no third kind.

- a fenced block tagged `teal` or `lua` is a test. it compiles under
  the checker and runs. output shown after it is asserted.
- a block tagged `teal skip=<reason>` is not run, and the reason is
  visible to the reader. `skip=intended` marks a snippet that waits
  on an `intended` doc's gap; `skip=network` marks one that needs a
  host the build does not have.
- a block tagged `sh` is a command line. it runs under the fence and
  its verdict line is asserted.
- a block tagged `text` is prose in a box. nothing runs.

the build extracts snippets by position, keys them by content hash
like any test, and records verdicts in the same database. a doc
whose snippet fails is a failing gate.

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

## this doc

`state: intended`. the snippet extractor and the state markers exist
when milestone 2 of the design lands. until then this doc describes
the rule the tree is written to, and the code changes to meet it.
