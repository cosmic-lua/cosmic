# contributor docs

the same four kinds as [the user docs](../README.md), for people who
work on cosmic itself. nothing here ships in the binary.

## tutorial

- [first-contribution](tutorial/first-contribution.md): clone, build,
  add a module with its test and example, run the gate, open a PR.

## how-to

- [add-module](howto/add-module.md): add a public module in the shape
  every module has.
- [add-dependency](howto/add-dependency.md): pin an external asset.
- [bump-pin](howto/bump-pin.md): bump the cosmos, tl, or cosmic pin,
  and prove a candidate carries a checker change.
- [swap-checker](howto/swap-checker.md): measure a different Teal
  checker than the shipped one.
- [try-make-change](howto/try-make-change.md): try a `--make` change
  by hand on a fixture project.

## reference

- [layout](reference/layout.md): every top-level directory, the module
  root rule, what the binary embeds.
- [ci](reference/ci.md): the workflow lanes and what each asserts.

## explanation

- [architecture](explanation/architecture.md): the executable zip, the
  two binding layers, the ratchet pattern.
- [bootstrap](explanation/bootstrap.md): why building cosmic needs a
  cosmic, and why a gate verb converges.
- [make/](explanation/make/README.md): the design of `cosmic --make`,
  one chapter per concern.
- [casts](explanation/casts.md), [cast-legality](explanation/cast-legality.md),
  [nil-flow](explanation/nil-flow.md): the census documents behind the
  honest-type-layer goal. each states the commit it measured.
- [agent-usability-study](explanation/agent-usability-study.md): the
  dated clean-room study that seeded the agent-eval instrument.

the mission and the ranked goals are [../goals.md](../goals.md); the
tradeoffs are [../decisions/](../decisions/), and `skills/decide` is
how one is written.
