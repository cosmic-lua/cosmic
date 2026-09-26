# how docs work here

## docs are always right

a doc describes either the current state or an intended one. either
way, when the code and the doc disagree, the code is wrong and the
code changes. a doc is never edited to match a bug.

intended behavior that is not yet built is labeled as intended. an
example that cannot run yet uses `skip=intended`.

## every example runs

a doc includes examples. every example is compiled by the build, and
run when it says what it prints. there is no third kind, other than
an explicit skip with a reason.

an example is the shape Go gave it: a function-sized unit with its
own scope, compiled every time, run when it declares its output. a
doc compiles to one Teal file, the same shape as a hand-written test
file and discovered the same way; each example inside it becomes its
own function, never a chunk shared with the others, so a `return` at
an example's end is an ordinary function return and two examples
declaring the same local name never collide. nothing else is
different: the compiled file is a test file, run by the same runner,
under the same assertion and the same eventual isolation, with no
doctest machinery of its own.

- a fenced block tagged `teal` or `lua` opens an example, becoming a
  function's first statements, or joins the one before it when
  tagged `teal continue`, adding more statements to that same
  function. it compiles under the checker.
- a block tagged `teal file=<path>` is a file in that example's
  project rather than a statement in its function; a multi-file
  guide is one example with several files and one entry, the block
  without a `file=`. the entry's own code runs with a `tmp` variable
  in scope, naming the fresh directory holding those files, so it
  reads one back with a path like `tmp .. "/<path>"`.
- a block tagged `output` that follows an example is what the entry
  prints, captured and asserted line by line as that function's own
  assertion. an example with no `output` block compiles and does
  not run.
- a block tagged `teal skip=<reason>` produces no function at all,
  only a comment carrying the reason. `skip=intended` marks an
  example that waits on work not yet done; `skip=network` marks one
  that needs a host the build does not have. a shebang line, real
  only as a file's first line, is always a skip, shown for reading,
  never run.
- a block tagged `text` is prose in a box. nothing runs.
- a line `<!-- inputs: processes = true -->`, alone and outside any
  fence, is what the doc's examples read beyond their default inputs,
  as a test module's `_inputs` declares it (`build.inputs`). it
  renders as nothing, and a doc has one at most.

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
