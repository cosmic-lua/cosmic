# Design log — `cosmic --make`

What each landed slice *settled*, in the order it landed. The design
itself is [../README.md](../README.md) and the roadmap is
[../phasing.md](../phasing.md); this is the record of what each phase
predicted, what actually happened, and why anything that looks arbitrary
is the way it is.

A new file whenever one fills — the 500-line cap applies to every
tracked file and a record only grows.

| file | phases |
|---|---|
| [phase1-2.md](phase1-2.md) | 1 (`-c` shell mode) and 2a–2e (project model, graph, artifact, pins, embedded make) |
| [phase3-dogfood.md](phase3-dogfood.md) | 3a–3g — building this repo with `--make` |
| [phase3-selfbuild.md](phase3-selfbuild.md) | 3h onward — the entry, the hoist, and the engine's move into `o/` |
