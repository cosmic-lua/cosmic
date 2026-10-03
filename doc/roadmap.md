# roadmap

this file records remaining work and open decisions only. [design.md](design.md)
defines the target; once something ships, it leaves this file.

"old" below is the previous tree, kept on the `old` branch (at `96da34e7`):
`git show origin/old:<path>` reads a file it names.

## language and self-check

- implement the cast policy in design.md. a cast is legal only from `any`, from
  a userdata record declared in `.d.tl`, or from the enclosing generic's type
  variable. none of `patch/tl` enforces it yet, and the tree's own Teal holds
  about seventy `as` casts to migrate or justify first. old's
  `3p/tl/tl_patch/cast.tl` and `docs/design/cast-legality.md` are useful
  implementation and migration evidence.
- add earned lint rules and their fixes to [`build/fix/rule.tl`]'s rule list.
  the rewrite stage is in place and the list is still empty.
- add a floor for line coverage, C included: `cosmic test --min PCT
  [--min-file PCT]` fails a whole run whose overall or any one file's line
  coverage falls below it, naming each file under the per-file floor with its
  percentage; with neither flag it reports and passes, as today. every release
  core and the sanitized core already observe their own C, in the processes a
  test starts too, into the same `coverage` table as Teal's ([`core/coverage.c`]),
  and a run already fails for any C function no test enters
  ([`build/c_functions.tl`]); the floor is what catches lines going untested
  inside a function a test does enter. CI states the floor at the call site
  rather than in a committed ratchet file. old's #1778
  (`_tool/coverage/minimum.tl`, `--make coverage --min PCT --min-file PCT`,
  which replaced the `.cosmic-coverage` ratchet and its `--baseline`) and #1781
  (`pr.yml`'s `--min 76 --min-file 0`) are the model.
- add a sensitivity record for coverage gates' host-dependent lines. old's
  `cosmic/coverage/SENSITIVITY.md` is a useful model: establish a floor from CI
  measurements and record why root access, a terminal, a free port, or a
  platform feature changes it.

## untrusted input

design.md promises that the parsers facing untrusted input are fuzzed.
[`build.fuzz`] runs every `*_fuzz_test.tl` property on every `cosmic test`, and
`fuzz.yml` reruns them deep on the checked core each night.
curl, c-ares and yyjson are fuzzed upstream; record that as their evidence
rather than fuzzing them here. [`core/json.c`]'s own walk into Lua values and
its encoder are fuzzed here, in [`cosmic/json_fuzz_test.tl`].

- cap what [`Archive.extract`] writes. `ExtractOptions.max_bytes` was the only
  bound on extracted bytes and went with the removal of options no caller
  used; without one, a zip entry that records 4 GiB and deflates from a few
  kilobytes writes all 4 GiB. a size cap (total, and per entry) would refuse
  it, as `max_entries` bounds the entries.
- fuzz the portable launch. [`build/locator_fuzz_test.tl`] covers a host
  program's trailer and manifest, which share `decode_blocks` with a portable
  artifact, but not the launcher's own reading of the shell header or the core
  a portable start adopts from the cache.
- publish `cosmic-debug`, the sanitized build, once there is a way to
  distribute one fat, cross-platform debug build. until then the checked core
  is built and run only in CI, where its build paths do not matter. the core
  is static musl on Linux and links libSystem on macOS, as the release cores
  do, so one built on any runner of an architecture runs on the others; it
  carries build paths in `.rodata` and its line tables, so a published one
  would be built at a fixed path on every runner.

## process isolation and containment

Contain a dead worker's escaped descendants on macOS. Linux adopts them as a
child subreaper and [`Child.end_strays`] ends them; macOS has no subreaper, so a
process group a timed-out test started for itself is left to launchd.

Add build and test sandbox fencing: a `cosmic.sandbox` module and conformance
matrix implementing the portable policy in design.md, required in CI, with
degraded or skipped enforcement reported on hosts that cannot provide a section.
[`cosmic.http`] now gives the core network egress, which makes the fence's
network section matter sooner.

Per-host egress policy is a separate Linux extension. Landlock can restrict a
port but not a remote address. old's `cosmic/quicksand/` is a reference for a
network namespace, guarded proxy, and declarative child runner; it should not
be folded into the portable sandbox contract.

Add a CI leg that runs the suite as root. Every leg's runner is
unprivileged, so the path a root runner takes -- each sandboxed worker run
as a user of its own, mapped from outside (build/test_sandbox.tl's
`runs_as`, spawn's `user`), and its fallback to root where the host refuses
that user a user namespace -- runs only on developers' and agents' hosts,
and core/syscalls_tool_test.tl checks the drop itself only in a run as root
unsandboxed.

## surface

design.md's core tier names modules the tree does not have yet. the ones the
promises lean on come first:

- convert the sites that still read a decoded JSON value without a
  [`cosmic.shape`] check. None casts it in a function that
  [`build/contracts.tl`]'s `casts` names; what is left:
  - [`ci/cosmic_ci/prerelease.tl`] narrows the `gh` answers with `is` and an
    `assert` per field (`release_ids`, `target`, `workflows_moved`,
    `asset_names`, `flag`). `prerelease_test.tl` pins `release_ids`'
    messages, and it asks for an `id` only of the releases that carry the tag,
    which a record would ask of every one.
  - the workflow files, read as JSON5 and cast to maps in
    [`build/queue_seed_test.tl`], [`build/workflows_test.tl`] and
    `ci/cosmic_ci/orchestration_test.tl`: a record per job, step and matrix
    entry would restate GitHub's schema for the few keys a test reads.
  - readers that are lenient on purpose ([`eval/summarize.tl`] reads a
    transcript as Python's `json` does) or hold no record ([`build/json.tl`],
    [`build/dataset.tl`], [`build/flow.tl`]).
  The call shapes: `record_of(...):decode_into(text)` needs no annotation. A
  top-level array of records does, `Shape.list(ROW.spec)` with `local rows,
  why: {Row} | nil, string` ([`build/archive_test.tl`] and [`build/hash_test.tl`]
  each write a four-line `rows_of`); a `Typed` method for it waits for a
  caller outside a test. `ci/` runs on the release [`ci/cosmic-driver.pin`]
  names, whose [`cosmic.shape`] names a place as `$.a[1].b`, not as a JSON
  Pointer, so its tests match the field and the failure, not the path.
- a hand-written spec that agrees with its record. [`Shape.record_of`] derives
  a spec from the record, and no [`Shape.record`] or [`Shape.strict_record`]
  outside a test or an example is left (`o/bin/cosmic uses Shape.record`
  lists them). Nothing yet checks that one names the fields of the record its
  answer is annotated as, so a field added to the record and not to such a
  spec is never set (and a strict one refuses the key outright): have `cosmic
  fix` compare the specs of [`cosmic/shape_example.tl`], and a project's own,
  with the record their `into` flows into.
- `shape`'s `record_of`, past what landed in the first form (a string literal
  naming a record, resolved where the module is built, in
  [`build/shape_specs.tl`]):
  - `Shape.of<T>()` is not Teal: a call takes no type arguments, so `T` cannot
    be handed to a function. The name is a string, and the build splices in a
    `function(): R return nil end` that gives the result its type; a nil cast
    to the record (`Shape.of(nil as R)`) would drop the string and the
    module's `require` of the record's module, at the cost of a cast in the
    caller, which [`build/contracts.tl`]'s rule 7 refuses outside a `casts`
    entry.
  - a program with no build gets none: `--standalone` has no declarations to
    read, and parsing one at run time needs the Teal compiler (about 300 KB of
    bytecode) in every executable a program is built into. Revisit if a
    standalone script needs it; `cosmic script.tl`, which builds the tree
    around the script, resolves it as any module.
  - `strict_record_of`, or `Typed:strict()`: a config file wants a misspelt
    key refused, and [`Shape.strict_record`] takes a hand-written table. Wait
    for a caller.
  - a record that implements an interface (`record R is Base`) is refused:
    the checker keeps the inherited fields in the interface, and reading them
    is a few lines once a record needs it. A record that holds itself is
    refused too, since a [`Shape.Spec`] is finite; `Shape.lazy` (below) is its
    other half.
  - an enum's values are in byte order, not the order they are declared in:
    the checker keeps an enum as a set. A message that lists them reads
    differently from a hand-written `one_of` in another order.
  - a `module.Record` is found only inside the module's returned record
    ([`receivers.record_named`]): a record another module declares and does
    not hand out is refused. Reading it needs the checker's types of that
    module's own scope, which [`build.receivers`] does not keep.
  - a spec of a record and a spec in a hand-written [`Shape.list`] or
    [`Shape.record`] meet through [`Typed.spec`]: a `Typed` is not a `Spec`, so
    `Shape.list(RECORD)` is `Shape.list(RECORD.spec)`. Teal has no
    polymorphic function a module can implement, so `into` and `decode_into`
    cannot take both without a second name.
  - a tool that predates [`build/shape_specs.tl`] cannot compile a module that
    calls `record_of` (its checker reports the result as `T (unresolved
    generic)`). A comment in [`build/patch.tl`] moves the image fingerprint so
    that such a tool boots the tree rather than rebuilding it. Teach
    [`build/reboot.tl`] to boot when a rebuild's compile fails and the
    compiler's identity moved, and drop the comment.
- read clang's JSON syntax tree in [`build/c/tree.tl`]. It reads the text form
  of `-Xclang -ast-dump`, and `rules.tl` digs about sixteen facts out of a
  node's text line (an operator, a cast's kind, a type, `static`, a literal's
  value). `-ast-dump=json` names each of those as a field, and clang keeps it
  stable where the text is meant for people. Read it with `cosmic.json` and
  give each node a [`Shape.record`], the first real caller of both. Measured on
  `core/json.c`: 76 MB of JSON against 3.9 MB of text, 0.27 s to emit
  against 0.22 s, and 0.4 s for [`Json.decode`] to read it with `max_depth` at
  1000 (clang nests past the default 64), holding about 60 MB of Lua heap
  after. A `loc` in the JSON form also names its file only when it changes,
  so the running position `tree.tl` keeps is still needed, and the system
  headers are still most of the dump.
- the lint design.md's teal section plans: refuse `v is R` for a record `R`
  on an `any`, which compiles to a table check, and point at [`cosmic.shape`].
- record `shape`'s decisions in design.md: the answer is a copy, a null
  stand-in and a list's hole are missing values, and `integer` is the one
  conversion. old's D28, which chose the opposite on the copy, is not on this
  tree.
- measure `into`'s copy on a large payload (a big NDJSON file) against
  [`Json.decode`] on the same text once the benchmark harness exists.
- [`cosmic.http`] with a request body written a chunk at a time, once a
  caller needs one (`cosmic refresh` posting a large artifact, say): the
  `Http.upload` that was removed with its C `start`, `write` and `finish`
  (a tested streaming path with a read callback that paused the transfer,
  `Expect:` suppressed, a given or chunked length), whose C went with it
  because no test but its own entered it. A 307 or 308 with a streamed body
  needs the caller to hand the body over again (a function answering a
  fresh Reader) behind `CURLOPT_SEEKFUNCTION`; curl answers "necessary data
  rewind was not possible" without one.
- [`cosmic.url`] past escaping, unescaping, a path's segments and an
  absolute URL's parts, each once a caller needs it: `Url.format(parts)`,
  writing a [`Url.Parts`] back into a URL (an IPv6 host bracketed again);
  a query string decoded into names and values (`+` as a space, a name
  given more than once kept as a list), which [`Url.unescape`] leaves to
  the caller since `+` is a form's rule; and a relative reference
  resolved against a base URL (RFC 3986 section 5), which a client
  following a `Location` or a crawler needs and [`Url.parse`] refuses;
  and an IPv6 host with a zone (`[fe80::1%25eth0]`, RFC 6874), which
  [`Url.parse`] refuses.
- [`Http.serve`] past HTTP/1.1 over plain sockets, each once a caller
  needs it: TLS, for a server reached past the loopback (a certificate
  and key handed to the listener, over the TLS stack curl already
  carries); HTTP/2; a reply compressed for an `Accept-Encoding` the
  client sent, the server choosing the coding and writing `Vary`;
  routing, a table of methods and path patterns to handlers in place
  of one handler's `if`s; and static files, a directory served by
  [`Url.segments`] with types, answering ranges ([`Http.range`]) and
  conditional requests ([`Http.none_match`]).
- an `Archive.add_tree(writer, dir, opts?)` that walks a directory into an
  [`Archive.create`] writer, once a caller needs one. `cosmic archive
  create` ([`build/archive.tl`]) is the only walk today, and it gathers and
  checks every path (a FIFO refused by name, the output skipped) before
  creating the archive and prints each name it packs, which a plain walk
  would not do for it.
- `format`, `check`: small modules a program
  otherwise hand-rolls.
- `ast`, `teal`, `doc` and `embed` exist only as build internals under
  `build/`, and of `test` only [`cosmic.test`]'s `needs` is public, the
  runner staying in `build/`. decide which become public `cosmic.*`
  modules and what a program gets from each.
- `shape` specs a caller may come to need, each added once one does: a
  `nullable` that tells `null` from a missing key (a PATCH body's two
  meanings); `big_integer`, taking the digits `big_numbers_as_strings`
  decodes an integer past 64 bits to; checks past a value's type (a
  range, a pattern, a length) as `Shape.check(spec, fn)` or a few named
  ones; and `Shape.lazy(function(): Spec)`, so a spec can name itself for
  a tree-shaped payload, `need_spec` checking it on first use.
- [`cosmic.net`] past stream sockets over unix socket files and TCP, each
  once a caller needs it: a host name looked up (c-ares, which curl
  already carries) where a "tcp" `Address` takes a numeric one; TLS
  over a connection, for the
  loopback server build/fetch_test.tl's https `TODO:` waits on;
  datagrams ("udp", "unixgram") as a
  socket of their own with `send_to` and `receive_from` over the same
  `Address`; a [`Net.serve`] listener taking a listen's own options
  (`backlog`); a listen that takes over a socket file a listener left
  behind (`reclaim`, for a daemon restarting at its socket file); a
  [`Net.serve`] in several processes of this program, which take
  connections from the listeners it hands them; a connection's `peer`
  address; of a unix socket, its peer's user and process
  (`SO_PEERCRED`, `getpeereid`), descriptors passed over it
  (`SCM_RIGHTS`), Linux's abstract names, and a socket file's mode.

## documentation and examples

New documentation extends the one build-time index and runtime query path
behind `cosmic docs` and `cosmic uses`; API guidance goes in the indexed doc
comment beside the source, and a guide is only for a task larger than one
symbol.

- add focused `*_example.tl` files for the public modules `cosmic/` has
  none for yet: `env` and `store`.
- add mention search for prose references that `cosmic uses` cannot see.
  old's `cosmic/doc/mentions.tl` demonstrates the separate full-text query.
- an uncaught error's guidance ([`Errors.guidance`] in [`cosmic/errors.tl`]) is
  chosen by word overlap between the message and the catalog's messages, and
  two shared ordinary words are enough to attach an entry about something
  else: #2008 reworded two `removed` messages to get out of its way. Match a
  catalog row only when the message carries that row's own static text.
- decide whether README's runnable-looking shell example moves into
  `doc/guides/`, where the doctest extractor enforces it, or remains an
  explicit manual exception.

## release evidence

The release bar is three checks: Cosmic builds and tests gitboard from its own
tree; `eval/` passes the task's grader under `eval/check/<task>`; and the
release product covers all three targets with byte agreement proved by the
four-producer provenance join.

- decide what “builds and tests gitboard from its own tree” means. A separately
  pinned gitboard, as on main, proves a different property from building its
  source here. Write the check only after choosing the property.
- grow `eval/` into a fixed task suite with tested graders and known pass,
  partial, and fail fixtures. `notes` is still the only task. The next should
  exercise a different part of the library (child processes, the store,
  compression, or now `http` and archives) so one task's friction is not
  mistaken for the whole product's. old's `_eval/` is a reference for keeping
  briefs, graders, their registry, and golden run directories consistent.
- add a performance gate once stable comparison targets exist. It should
  re-measure a suspected regression against one baseline, run an A/A noise
  check, and use a third reading to break a tie. old's `_perf/gate.tl`,
  `compare.tl`, `reproduce.tl`, and `tiebreak.tl` show this shape. The same
  harness is what design.md says moves a module across the C/Teal line.

## open decisions

- **host language and toolchain.** Re-evaluate the current C core and pinned Zig
  build against Rust, Zig as the implementation language, and old's vendored
  Cosmopolitan approach. Include size, portability, reproducibility, patch
  ownership, and failure consistency. [`bin/zig`] and [`bin/vendor`] now run on a
  pinned bootstrap cosmic, so the build driver is already self-hosted while the
  compiler is not; that is evidence, not the answer. Do not assume full
  self-hosting is the desired answer before comparing the maintained systems.
- **sanitizer tier.** The Linux lane already runs the whole suite on a checked
  core (ReleaseSafe, full undefined-behavior checking, Lua's own assertions),
  the static analyzer, and a walk of every allocation-failure path. What is
  missing is memory-safety checking: zig ships no address sanitizer, so that
  lane needs a compiler outside the pinned production toolchain. curl, c-ares
  and mbedtls's TLS layer grew the C that faces the network; decide whether
  that is the size that justifies the lane, and keep its evidence separate from
  reproducible release production.
- **target tiers.** design.md lists core, second and later tiers; define what
  test, documentation, portability, and maintenance evidence promotes a module
  from one to the next, and whether a second-tier module that shipped ahead of
  the core tier (`http`, `tar`, `zip`, `stream`) is held to the same bar.
- **decision records.** Adopt a small durable format before resolved questions
  disappear from this file. Record context, the decision, rejected alternatives,
  and consequences; amend a record when the decision changes.

[`Archive.create`]: ../cosmic/archive.tl
[`Archive.extract`]: ../cosmic/archive.tl
[`bin/vendor`]: ../bin/vendor
[`bin/zig`]: ../bin/zig
[`build.fuzz`]: ../build/fuzz/init.tl
[`build.receivers`]: ../build/receivers.tl
[`build/archive.tl`]: ../build/archive.tl
[`build/archive_test.tl`]: ../build/archive_test.tl
[`build/c/tree.tl`]: ../build/c/tree.tl
[`build/c_functions.tl`]: ../build/c_functions.tl
[`build/contracts.tl`]: ../build/contracts.tl
[`build/dataset.tl`]: ../build/dataset.tl
[`build/fix/rule.tl`]: ../build/fix/rule.tl
[`build/flow.tl`]: ../build/flow.tl
[`build/hash_test.tl`]: ../build/hash_test.tl
[`build/json.tl`]: ../build/json.tl
[`build/locator_fuzz_test.tl`]: ../build/locator_fuzz_test.tl
[`build/patch.tl`]: ../build/patch.tl
[`build/queue_seed_test.tl`]: ../build/queue_seed_test.tl
[`build/reboot.tl`]: ../build/reboot.tl
[`build/shape_specs.tl`]: ../build/shape_specs.tl
[`build/workflows_test.tl`]: ../build/workflows_test.tl
[`Child.end_strays`]: ../cosmic/child.tl
[`ci/cosmic-driver.pin`]: ../ci/cosmic-driver.pin
[`ci/cosmic_ci/prerelease.tl`]: ../ci/cosmic_ci/prerelease.tl
[`core/coverage.c`]: ../core/coverage.c
[`core/json.c`]: ../core/json.c
[`cosmic.http`]: ../cosmic/http/init.tl
[`cosmic.net`]: ../cosmic/net.tl
[`cosmic.shape`]: ../cosmic/shape.tl
[`cosmic.test`]: ../cosmic/test.tl
[`cosmic.url`]: ../cosmic/url.tl
[`cosmic/errors.tl`]: ../cosmic/errors.tl
[`cosmic/json_fuzz_test.tl`]: ../cosmic/json_fuzz_test.tl
[`cosmic/shape_example.tl`]: ../cosmic/shape_example.tl
[`Errors.guidance`]: ../cosmic/errors.tl
[`eval/summarize.tl`]: ../eval/summarize.tl
[`Http.none_match`]: ../cosmic/http/init.tl
[`Http.range`]: ../cosmic/http/init.tl
[`Http.serve`]: ../cosmic/http/init.tl
[`Json.decode`]: ../cosmic/json.tl
[`Net.serve`]: ../cosmic/net.tl
[`receivers.record_named`]: ../build/receivers.tl
[`Shape.list`]: ../cosmic/shape.tl
[`Shape.record_of`]: ../cosmic/shape.tl
[`Shape.record`]: ../cosmic/shape.tl
[`Shape.Spec`]: ../cosmic/shape.tl
[`Shape.strict_record`]: ../cosmic/shape.tl
[`Typed.spec`]: ../cosmic/shape.tl
[`Url.parse`]: ../cosmic/url.tl
[`Url.Parts`]: ../cosmic/url.tl
[`Url.segments`]: ../cosmic/url.tl
[`Url.unescape`]: ../cosmic/url.tl
