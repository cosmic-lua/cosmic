# stdlib simplification

this document is the plan for landing the fixes a consistency-and-simplicity
review of `cosmic/` recommended (October 2026). it names each fix, the PR it
lands in, the order the PRs go in, and the rules every one of them follows.
once a PR merges its section is marked done; once every section is done the
file is deleted, as [roadmap.md](../roadmap.md) deletes what ships.

## decisions

these were taken up front and are not reopened per PR.

- **removals are outright.** an export that goes gets an entry in
  [`cosmic.removed`]'s `members` naming what to write instead, so a program that
  used it fails to compile with the replacement in the message. no deprecated
  alias and no compatibility shim.
- **verb-only code moves to `build/`.** code only a `cosmic` verb calls is the
  tool's, not the library's. it moves beside its verb and leaves the documented
  stdlib. `ci/` and `eval/` count as callers: a change greps them too, since
  `../o/bin/cosmic fix --check` from `ci/` type-checks that tree against this
  binary.
- **time is nanoseconds everywhere.** every parameter, field and constant that
  holds a span or an instant is an integer of nanoseconds, suffixed `_ns` where
  the name needs a unit; [`cosmic.time`] gains constructors ([`Time.ms`],
  [`Time.seconds`], [`Time.minutes`]) so a caller writes `h:wait(Time.seconds(5))`
  rather than a literal with nine zeros. a span the calendar measures
  (years, months, days and a remainder) is [`Time.Duration`], a record. a
  full duration record for every timeout was considered and left for the
  roadmap: an integer is what every binding takes, compares and adds without
  allocation.
- **the documentation-only modules stay.** [`cosmic.cli`], [`cosmic.layout`],
  [`cosmic.entrypoint`], [`cosmic.errno`] and `removed.fields` exist to give
  `cosmic docs <word>` a page. replacing them means teaching the docs verb to
  index another source; the gain is cosmetic and the change is the tool's,
  not the library's. not in this plan.
- **the two redesigns are in.** [`Poll.wait`] with [`Stream.from_fd`] over it, and
  a shape derived from a Teal record, are the last PRs. each may end by
  landing a smaller form than this document sketches, with the rest named in
  the roadmap, but each is attempted.
- **the review's measurements are the baseline.** a PR that removes an export
  cites the use count it had (from the tree's own `uses` table); one that
  dedupes cites each copy's `file:line`.

## rules every PR follows

1. it stands alone and passes CI; it starts from `origin/main` in a worktree of
   its own, per [`.claude/skills/ship/SKILL.md`], and is never stacked.
2. the change has a test that fails without it, and the suite passes:
   `bin/zig build boot`, `o/bin/cosmic fix <changed-paths>`, `timeout 30
   o/bin/cosmic test`, `o/bin/cosmic fix --check .` before pushing, and
   `../o/bin/cosmic fix --check` from `ci/` when `ci/` changed.
3. every removed export has a [`cosmic.removed`] entry, every moved one a
   replacement that names its new home, so a program that used it fails to
   compile with the replacement in the message (`cosmic docs` has no
   removed-member lookup; teaching it one is the tool's change, not this
   plan's).
4. a worked example or guide that called a removed export is rewritten to the
   replacement, never deleted to make the export "unearned".
5. a gap the PR leaves is a `TODO:` in the code at the moment it is left, and
   the PR description lists each from `o/bin/cosmic todos <paths>`.
6. a separate agent reviews the diff adversarially before the PR opens;
   every BLOCKING finding is fixed, and what is left is said in the
   description.
7. the PR is titled `area: summary`, opens as a draft, has auto-merge enabled,
   and the next PR that touches the same files starts only once it has merged.

## the PRs, in order

PRs in one wave touch disjoint modules and may be worked in parallel; a wave
starts when the wave before it has merged. within a wave, a PR named as
depending on another waits for it.

### wave 1: shared text helpers

**PR 1 `string: one plural helper, and the tree uses the helpers it has`.**
`String.counted(n, singular, several?)` replaces the seven identical copies
of `counted` (archive.tl:17, compress.tl:13, dataset.tl:76, stream.tl:27,
tar.tl:18, time.tl:25, zip.tl:19); [`build/plural.tl`]'s `count` delegates to
it. the hand-rolled copies of [`String.trim`] (nine in `build/`),
`starts_with` (eleven) and `lines` (ten, in `build/`, `eval/` and
`test/`) become calls. `String` is on the harness's `library` list already,
so no key moves but the modules edited.

### wave 2: data formats and time

**PR 2 `json: the query machinery is cosmic json's`.** moves to
`build/json_query.tl`: `parse_path`, `parse_pattern`, `spell_pattern`,
`select`, `flatten`, `flat_line`, `describe`, `child_path`, `get`, `entries`,
`items`, with `Step`, `StepKind`, `Located`, `WalkOptions`,
`DescribeOptions`, about 830 lines, whose callers are [`build/json.tl`],
[`build/sql.tl`] and `cosmic/dataset.tl` (which moves in PR 3). [`cosmic.shape`]
keeps a private path speller for its failure messages. removed from
`cosmic.json`, each with a hint: `lines`, `write_line`, `encode_lines` (no
caller), and the `EncodeOptions` fields nothing sets (`ascii`,
`nan_as_null`, `sparse_as_null`, `sorted`, `indent`), which the C encoder
keeps supporting for `build/` callers through a `cosmic.internal.json` option
record the verb fills. `decode`, `decode_object`, `decode_array`,
`decode_lines`, `encode`, `array`, `is_array`, `quote`, `null` and the depth
constants stay. one classification of a Lua table as JSON: `layout`
(json.tl:954) becomes the only one, replacing `table_kind` (:456) and
exported as [`Json.layout`] for [`cosmic.shape`], whose `dense_keys`/`split_keys`
(shape.tl:318) go. the two `max_depth` validators (json.tl:933, :1340)
become one.

**PR 3 `sql: the dataset loader lives beside its verb`** (after PR 2).
`cosmic/dataset.tl` becomes [`build/dataset.tl`], its tests and examples
becoming [`build/dataset_test.tl`]; `LoadOptions` is deleted entirely
(`json_column` and `columns` had no caller). [`cosmic.csv`] loses `rows` (a one-line derivative of `table`)
and `encode` (no caller), and gains `Csv.column_names(header, reserved?)`,
the one copy of the header-to-unique-names rule that `names_of`
(csv.tl:224) and `columns_of` (dataset.tl:386) each held. [`Csv.parse`] and
[`Csv.table`] raise for a degenerate delimiter, as a degenerate argument does elsewhere.

**PR 4 `codec: the streaming coders are cosmic codec's`.** [`Codec.encoder`],
[`Codec.decoder`], [`Codec.Coder`] and [`Codec.Name`] (codec.tl:265 to 452) move to
[`build/codec.tl`], their only caller; their tests follow. `hex`, `unhex`,
`base64`, `unbase64`, `base64url`, `unbase64url` stay. the finished-flag
guard the coder shared with [`Hash.Mac`] is written once there.

**PR 5 `shape: one failure mode, and json's table classification`** (after
PR 2). [`Shape.failures`] and the `all`-collecting mode it threads through
`walk` and `walk_either` (shape.tl:401 to 535), which doubles every container
branch, go, with [`Shape.either`]; `optional`, `one_of`, `strict_record` and
`into`/`decode_into` stay. [`Spec.kind`] becomes an enum. the table
classification comes from [`Json.layout`].

**PR 6 `time: nanoseconds, a Duration, and one way to pass a zone`.**
- `Time.ms(n)`, `Time.seconds(n)`, `Time.minutes(n)`, `Time.hours(n)`:
  nanosecond integers from a count, raising on a non-integer result.
- [`Time.Duration`] stays the record it is, as the one calendar span:
  `Change` (time.tl:94), identical to it less `nanoseconds`, goes, and
  `add_calendar(ns, duration, zone?, opts?)` takes a `Duration` and adds its
  exact part (`ns`) last.
  `Time.between(from, to, zone?): Duration` answers the whole years, months,
  days and remainder between two instants, absorbing the 35 lines
  `build/time.tl:336` spends combining `months_between`, `add_calendar` and
  `days_between`; `months_between` and `days_between` go (only that verb
  called them), with hints naming `between`. `between` always answers a
  `Duration` of one sign that `add_calendar(from, d, zone, { overflow =
  "clamp", disambiguation = "compatible" })` adds back to `to` exactly, in a
  zone with folds and skipped days too.
- every calendar function takes `zone?` positionally after its data and
  `opts?` last: `format_rfc3339(ns, zone?, opts?)` and `add_calendar` change;
  `CivilOptions` merges into `AddOptions` less `overflow`.
- `parse_input` and `read_input` (time.tl:1835 to 1935) move to
  `build/time.tl`: a user-text heuristic is the verb's input layer.
  `parse_duration` and `format_duration` stay as `Duration`'s text form.
  `parse_rfc3339_zoned` stays, since the verb's `parse_input` needs the zone
  of RFC 3339 text, and it now always answers a zone: its suffix's, else its
  offset's, else UTC.
  `zone_from_posix` stays (it is how `TZ` is read) but is no longer exported
  unless a caller appears: it becomes local to `local_zone`.
- one cursor helper (`at`, `digits(n)`, `expect(s)`, `name_of(list)`,
  `fail(why)`) replaces the six near-identical scanning primitives
  (time.tl:542 to 623 and 1343 to 1380); the four copies of fraction scaling
  (:1485, :1772, :1847, :1878) and two of fraction trimming (:1332, :1821)
  become one each; the four zero-padded clock writers (:1155, :1338, :1584,
  :1633) become one.
- [`Civil.nanosecond`], [`Zoned.ns`], [`Duration.nanoseconds`] become one word:
  `ns`.
- [`Time.sleep_ns`], `now_ns`, `monotonic_ns` are unchanged.

### wave 3: streams and archives

**PR 7 `stream: one transform contract`.** [`Stream.Transform`] is an interface
in [`cosmic.stream`] (`update(self, chunk): string | nil, string`,
`finish(self): string | nil, string`, optional `pending(self): boolean`)
that [`Compress.Stream`] satisfies; [`Stream.Codec`] is deleted in its favor.
`Stream.run(t, data, max_bytes?): string | nil, string` drives one over a
whole string, bounded. [`Compress.deflate`], [`Compress.inflate`] and zip's inline
deflate (zip.tl:870) become calls to it; [`Compress.inflate`]'s unchecked `max`
is validated (negative raises). [`build/codec.tl`]'s coders satisfy the
interface so `cosmic codec` drives them through [`Stream.transform_writer`].
[`Hash.Hasher`] gains `finish` as an alias of `digest` through a thin
adapter, [`Stream.hashing`] keeping its name. the limit names become
`max_bytes` everywhere a bound is a field: `Compress.inflate(format, data,
max_bytes?)`, `Compress.xz_decoder(max_memory?)`.

**PR 8 `archive: one entry, one reader, one writer`** (after PR 7).
[`Stream.ArchiveEntry`] is an interface with `path`, `kind` (one `Kind` enum,
zip's a subset of tar's), `mode`, `size`, `mtime`, `linkpath` and `open`;
`Tar.Entry is ArchiveEntry` adds `uid`, `gid`, `typeflag`; `Zip.Entry is
ArchiveEntry` adds `compressed_size`, `method`, `crc32`, `offset`.
[`Archive.Reader`] becomes the interface `{ next, close }` both satisfy, so
`wrap_zip` (archive.tl:175) and the two casts [`build/contracts.tl`] exempts go;
`wrap_tar` keeps only its drain. [`Stream.ArchiveWriter`] (`add_file`,
`add_dir`, `add_symlink`, `close`, `abort`) over [`Tar.Writer`] and
[`Zip.Writer`] (zip gains `add_symlink`, refusing with a reason where the
format cannot). `Stream.read_up_to(reader, n): string, string` ("" is a
clean end, short is truncated) replaces the head loops at archive.tl:242 and
tar.tl:199; `Stream.copy_n(reader, writer, n): boolean, string` replaces
tar.tl:722 and halves zip.tl:936. zip's `u16`/`u32`/`u64`/`le16`/`le32`/`le64`
(zip.tl:165) become `string.pack`/`string.unpack`; its civil-date copy
(zip.tl:200) becomes [`Time.civil`]/[`Time.from_civil`], with a DOS date no
calendar has (February 31) clamped to the month's last day and a `TODO:` if
that is not decided. tar's `next` (tar.tl:466, 108 lines) gets a pure
`parse_header` returning `Fields`; zip's `write_entry`/`write_streamed`
share one `put_entry`. the nine inline NUL-in-path refusals become one
helper per module. [`Zip.Reader.entries`] reports failure as `next` does.
[`Archive.list`] takes a path or a Reader, as `extract` does;
[`Archive.open`] (no direct caller) stays as `list`'s and `extract`'s entry.
[`ExtractOptions.unsupported`], `.mtimes`, `.max_bytes` (no caller) go.
[`Hash.byte_sum`] and [`Compress.crc32`] stay, each with the `TODO:` naming
what moving them waits on.

### wave 4: process and network I/O

one PR at a time, in this order, since each touches `child`, `net` and
`poll`.

**PR 9 `time: every span and instant is nanoseconds`.** the unit decision
applied: `timeout_ms` (243 sites), `grace_ms`, `wait_ms`, `now_ms`,
`connect_timeout_ms`, `low_speed_seconds`, `Poll.delay(ms)`, `LOCK_MS` and
every `*_ms` constant become `_ns` (or lose the suffix where the name is a
span already: `Poll.delay(ns)`, `ConnectOptions.timeout`), through
[`Time.ms`]/[`Time.seconds`] at each literal. the C-declared
[`cosmic.internal.http`] options keep milliseconds and seconds; [`cosmic.http`]
converts at the one boundary. the 33 hand conversions in `build/` and
`cosmic/` go. `now_ms` in poll.tl:197 and net.tl:566 become
[`Time.monotonic_ns`]; the three copies of the greatest wait (poll.tl:76,
net.tl:332, child.tl:292) become [`Poll.MOST_NS`]. the harness epoch is
bumped: [`build/test.tl`] and the sandbox read these.

**PR 10 `poll: one wait, one timeout answer`.** `Poll.wait(fd, events,
timeout_ns?): boolean, string` parks in a task under [`Poll.run`] and falls
through to [`sys.poll`] outside one, answering `false, Poll.TIMEOUT` on
expiry; `readable` and `writable` become calls to it. [`Poll.TIMEOUT`] is the
one word every module answers: [`Child.wait_any`] answers `nil, Poll.TIMEOUT`
in place of `nil, ""` (and its contracts exemption goes), net's `"timed
out"` becomes it, [`Poll.ready`] on expiry answers `nil, Poll.TIMEOUT` as
`readable` fails rather than a table of zeros. `Poll.checked_ns(value,
name, level)` is exported and replaces the four validators (poll.tl:370,
net.tl:346, :830, child.tl inline at :993, :1074, :1302, :1551). the six
"in a task or not" branches (net.tl:373, :598, :630; child.tl:581, :1625,
:997) become calls to [`Poll.wait`]. [`Poll.delay`] is the sleep in child.tl:590
and :1632. what landed: [`Poll.wait`] falls through outside a task (and where
a task cannot yield), but not in a killed task's `<close>` handler, where every
wait still raises (`poll_test.tl` holds it); [`Poll.delay`] and
[`Poll.ready`] stay task-only for the same reason, so child's three branches
and net's three (`waited`, `connection`, `locked`, whose waits outside a task
end at a caught [`Child.guard`] signal, which only the core's socket waits and
[`sys.flock`] see) remain, each with a `TODO:` naming what it waits on.
the [`Child.wait_any`] exemption in [`build/contracts.tl`] stays too: it is for
the handle answered beside a group's lingering-member trouble, not for the
timeout.

**PR 11 `stream: a descriptor reader and writer that wait`** (after PR
10). `Stream.from_fd(fd, opts?)` and `Stream.to_fd(fd, opts?)` take `{
timeout_ns, nonblocking }` and wait through [`Poll.wait`]; a read or write that
expires fails with [`Poll.TIMEOUT`], and a write writes whole, so the four
partial-write loops (fs.tl:71, net.tl:431, child.tl:644, :898) become one.
[`Net.Conn.read`]/`write` and child's `pipe_reader`/`feed_writer` are that
object: child's `"stream"` mode hands the caller [`Stream.from_fd`] over the
pipe, deleting [`Pipe.streamed`]/`head`/`tail`, `pipe_reader`, `feed_writer`
and `pump`'s `writable` argument; `pump` (child.tl:533, 139 lines) becomes a
list of `{ fd, events, owner, kind }` records with one handler per kind.
child's `"pipe"` stdin mode and `close_stdin` go (`stdin_stream` and
`input` cover both; no caller). [`Child.Options.stdin`]/`stdout`/`stderr`
become an enum beside the integer. child's end-of-life chain (`terminate`,
`poll_until`, `settle`/`settled`, `clear_group`, `emergency_cleanup`,
`Running`, child.tl:675 to 818 and 1640) becomes one `end_child(h,
deadline_ns)` with one caller, removing the double pcall in `run`
(child.tl:1697). [`Fs.read`] and `copy_bytes` (fs.tl:626) read through
[`Stream.copy`]; [`Stream.read_all`] is the one read-to-end loop.
what landed: [`Stream.from_fd`] and [`Stream.to_fd`] take `{ nonblocking,
timeout_ns, wait }` (`timeout_ns` and `wait` need `nonblocking`: a blocking
descriptor cannot be waited on in pieces); a write goes out whole and fails
with [`Poll.TIMEOUT`] having said how much went through the Writer's
`written()`, as a reason carries no count; `wait` replaces [`Poll.wait`] for a
caller that services other descriptors meanwhile. Child's stdin stream is
[`Stream.to_fd`] over the pipe with that `wait` (`feed_writer`'s loop, and
`pump`'s `writable` argument, are gone), `pump` is a list of `{ fd, events,
owner, kind }` entries with one service per kind, the end-of-life chain is
`end_child(h)` (no `deadline_ns`: every caller wants the grace
period, and a wait that is not a wait for the exit is another loop) under a
safety net, `end_or_kill`, that SIGKILLs and reaps where the ending raises, `"pipe"`
and `close_stdin` are gone, and the three options are enums beside the
integer. Left, each a `TODO:`: a streamed output stays a queue read by
`pipe_reader`, since handing the caller [`Stream.from_fd`] over the bare pipe
ends the service of one output while another is read (the full-stderr and
full-stdout tests); [`Net.Conn`]'s `read`/`write` stay (net.tl's `waited`);
[`Fs.read`] and `copy_bytes` stay, as [`cosmic.fs`] is a harness module that
may not require [`cosmic.stream`]. So the write-whole loops
are not one: `Fs.write_all` (behind [`Fs.put`] and [`Fs.write`]),
[`Stream.to_fd`], net's [`Conn.write`] and child's `input` service remain.

**PR 12 `net: one address, no supervisor`** (after PR 11).
`raw_socket.Address` is [`Net.Address`] (the four fields net.tl:561 copies
go), and `listened` uses [`Net.unix`]/[`Net.tcp`]. [`ServeSpec.workers`] and the
supervisor (net.tl:262 to 315, 1109 to 1160, 1245 to 1549), [`ListenOptions.reclaim`]
(net.tl:91 to 128, 616 to 755), [`Net.pair`], [`Conn:peer`] and [`Conn:writer`]
go, each with a hint (no caller in the tree); [`Proc.arguments`] goes with
the supervisor (its one caller), [`Proc.relaunch`] stays. [`Net.serve`] keeps
one runner (`serving`): `watch`/`stop` have no twin left. `conn.timeout` is
set through a method, not assignment. `Net.serve(spec)` keeps its name and
record: a spec is what it is. the `assert`s on arguments (net.tl:411, :454,
:737, :348) become raises with levels, as the rest of the tree writes them.

**PR 13 `fs: one atomic write, and http streams through it`** (after PR
11). `Fs.write(path, data, mode?)` is [`Stream.create`] plus write plus
close; [`Http.download`] streams into [`Stream.create`] through [`Stream.tee`]
and [`Stream.copy`], a cancellation-aware reader standing in for its three
`opts.cancelled()` polls, from 85 lines to about 30. [`Options.cancelled`]
stays, as the C waits do not read the guard, with a `TODO:` naming that;
download's signal failure says `"interrupted"` as net does, never
`"cancelled"`, which is [`Poll.CANCELLED`]'s word. [`Fs.write`] and
[`Stream.create`] report the caller's path in a failure, never the temporary
file's. removed with hints: [`Http.upload`] (no caller; the C `start`/`finish`
path stays for `cosmic refresh`'s future needs or goes with a `TODO:`),
[`Fs.truncate`] (no caller), [`Fs.cache_path`] folded into `Fs.cache_dir(tool,
{ environment, make = false })`. `Proc.exec(argv, { env })` mirrors
`Child.start(argv, opts)`, argv[1] the path. `Env` stays as the
removed-globals mapping. [`Fs.walk`]'s `skip` and the rest are unchanged.
what landed: [`Fs.write`] is the plan's [`Stream.create`] plus write plus close,
but [`cosmic.fs`] is a harness module that may not require [`cosmic.stream`],
so the one temporary-file-and-rename writer is [`Fs.create`] in [`cosmic.fs`]
(an [`Fs.Staged`], a Writer that can also `sync`), which [`Fs.write`] calls
and [`Stream.create`] wraps (a [`Stream.FileWriter`], a Writer with `sync`):
there is one copy where there were three (`fs.tl`, `stream.tl`, `http.tl`),
and every failure names the caller's path. [`Http.download`] is
[`Stream.create`], [`Stream.tee`] over its hashings and [`Stream.copy`] over a
cancellation-aware Reader (14 lines), 85 lines to 48, the rest its two
checksums, and keeps
its fsync before the rename through `sync`; [`Options.cancelled`] stays with a
`TODO:` naming the C waits. [`Http.upload`] went with its C `start`,
`write` and `finish` (about 200 lines of [`core/http.c`]), not just the
Teal: a test could reach them only through `Http.upload`, and a C function
no test enters fails a run, so the path cannot stay unused. [`doc/roadmap.md`]
holds what it would take back. `Proc.exec(argv, opts?)` takes
`{ env }`, the process's own environment by default.

### wave 5: the rest of the surface

**PR 14 `sqlite: options, an enum, and one step loop`.** `Sqlite.open(path,
opts?)` with `{ writable, immutable }` replaces the two positional booleans
(127 callers, each rewritten; a literal `true` second argument gets a hint).
[`Cell.kind`] becomes an enum. `rows`, `text_rows` and `query` share one
step-and-project loop. [`Sqlite.cell`] (one caller, [`build/sql.tl`]) becomes
[`Sqlite.Query`]'s to answer, or moves to build with a hint.

**PR 15 `flags: one command record for the verbs too`.** [`Flags.help`] takes
a [`Flags.Command`]; [`cosmic.cli`]'s five parallel maps (`options`, `usage`,
`summary`, `groups`, `order`) become `verbs: {string: Flags.Command}` plus
`order` and `groups`; [`build/dispatch.tl`] dispatches through
[`Flags.dispatch`] and loses its own `asks_help` (dispatch.tl:623) and index
renderer. [`Flags.Parsed`] keeps `set`, `values`, `all`, `given`, `words`: the
four views have callers.

**PR 16 `hash: the incremental HMAC is the core's`.** [`core/hash.c`] gains an
incremental HMAC over mbedtls (`hmac_hasher`), replacing the Teal
reimplementation of RFC 2104 (hash.tl:122 to 155) and `BLOCK`; [`Hash.Mac`]
becomes the raw type as [`Hash.Hasher`] is. a new C function gets its
[`core/allocation_test.tl`] walk.

**PR 17 `test: the build's validators live in the build`.** [`Test.fields`],
[`Test.any_host_refusal`], [`Test.network_trouble`], [`Test.lua_trouble`] move to
[`build/analyzer.tl`], their one caller; `trouble_of` (test.tl:282) is a
[`cosmic.shape`] spec over `Needs`. [`cosmic.test`] exports `needs` and `skip`.
[`Coverage.native_entries`] and [`Coverage.snapshot`] (no caller outside
`test/`) go with hints.

**PR 18 `errors: one way to raise, one way to refuse`.** a raise names its
module in lower case and a colon (`json: ...`, `child: ...`), never
`cosmic.test:`, `Net.serve:`, `Proc.find:` or a bare message: the 44 bare
raises in child, net and poll, and the `bad argument #N to 'f'` form in fs
and net, are rewritten. a returned failure is prefixed by its module's name
where the module's are today unprefixed (csv, dataset, compress, hash,
stream, json) through one local `refuse(why): nil, string` per module, so
tar, zip, archive and codec are no longer the exceptions. the nine spellings
of "closed", the four of "empty argument" and the two of "truncated" become
one each, per concept. a degenerate argument raises everywhere: the empty
zone name (time.tl:910), the malformed [`Sqlite.Value`] (sqlite.tl:151), the
float year in `from_civil`, zip's negative size.

### wave 6: the redesign

**PR 19 `shape: a spec from the record itself`.** `Shape.of<T>()` (or
`Shape.record_of("module.Record")`) derives a `Spec` from the Teal record
declaration the binary carries in `decls`, so a record and its shape are one
declaration and `into`'s cast to the caller's annotation is checked against
what the spec was built from. the implementing agent decides between
building the spec at build time (the analyzer sees every `Shape.of<T>()`
and writes a row the module reads at load) and parsing the declaration at
run time through the compiler the binary carries; the first keeps the
runtime small and is preferred. [`Shape.record`], `list`, `map`, `optional`,
`one_of` and `strict_record` stay for a shape with no record. what does not
land goes to [`doc/roadmap.md`] under "shape", with the reason.

## what stays, on purpose

- the nine copies of the raw-module hand-off prologue (`select(2, ...)`):
  a shared module would be reachable by `require`, which the prologue
  exists to prevent.
- [`cosmic.store`]'s one-line forwarders: they are the gate on
  [`cosmic.internal.store`]; [`Store.meta`] is folded to two slots in PR 18.
- `Fs`'s path-prefixing wrappers over `sys`: the prefix is the contract
  [`cosmic.errno`] documents. the build's direct `sys` calls are left; a
  sweep to `Fs` is a follow-up when it pays.
- [`Hash.byte_sum`], [`Compress.crc32`]: moving them waits on a module being
  handed another module's internal table; their `TODO:`s say so.
- `Env`: 28 lines, but the replacement the removed-globals mapping names.
- the object styles (closures in a table against a shared method table):
  each module keeps the one it has; a tree-wide choice is a separate
  decision.

## process

each PR is implemented by an agent in a worktree of its own, following
[`.claude/skills/ship/SKILL.md`]; a second agent reviews the diff
adversarially, with the worktree path and `git diff origin/main...HEAD`,
and the first fixes what it finds; the PR opens as a draft with auto-merge
enabled and is marked ready once its own CI is green; the next PR on the
same files starts from the merged main. a PR that cannot land as written
lands what it can and moves the rest to the roadmap, saying so in its
description.

[`.claude/skills/ship/SKILL.md`]: ../../.claude/skills/ship/SKILL.md
[`Archive.list`]: ../../cosmic/archive.tl
[`Archive.open`]: ../../cosmic/archive.tl
[`Archive.Reader`]: ../../cosmic/archive.tl
[`build/analyzer.tl`]: ../../build/analyzer.tl
[`build/codec.tl`]: ../../build/codec.tl
[`build/contracts.tl`]: ../../build/contracts.tl
[`build/dataset.tl`]: ../../build/dataset.tl
[`build/dataset_test.tl`]: ../../build/dataset_test.tl
[`build/dispatch.tl`]: ../../build/dispatch.tl
[`build/json.tl`]: ../../build/json.tl
[`build/plural.tl`]: ../../build/plural.tl
[`build/sql.tl`]: ../../build/sql.tl
[`build/test.tl`]: ../../build/test.tl
[`Cell.kind`]: ../../cosmic/sqlite.tl
[`Child.guard`]: ../../cosmic/child.tl
[`Child.Options.stdin`]: ../../cosmic/child.tl
[`Child.wait_any`]: ../../cosmic/child.tl
[`Civil.nanosecond`]: ../../cosmic/time.tl
[`Codec.Coder`]: ../../cosmic/codec.tl
[`Codec.decoder`]: ../../cosmic/codec.tl
[`Codec.encoder`]: ../../cosmic/codec.tl
[`Codec.Name`]: ../../cosmic/codec.tl
[`Compress.crc32`]: ../../cosmic/compress.tl
[`Compress.deflate`]: ../../cosmic/compress.tl
[`Compress.inflate`]: ../../cosmic/compress.tl
[`Compress.Stream`]: ../../cosmic/compress.tl
[`Conn.write`]: ../../cosmic/net.tl
[`Conn:peer`]: ../../cosmic/net.tl
[`Conn:writer`]: ../../cosmic/net.tl
[`core/allocation_test.tl`]: ../../core/allocation_test.tl
[`core/hash.c`]: ../../core/hash.c
[`core/http.c`]: ../../core/http.c
[`cosmic.cli`]: ../../cosmic/cli.tl
[`cosmic.csv`]: ../../cosmic/csv.tl
[`cosmic.entrypoint`]: ../../cosmic/entrypoint.tl
[`cosmic.errno`]: ../../cosmic/errno.tl
[`cosmic.fs`]: ../../cosmic/fs.tl
[`cosmic.http`]: ../../cosmic/http.tl
[`cosmic.internal.http`]: ../../cosmic/internal/http.d.tl
[`cosmic.internal.store`]: ../../cosmic/internal/store.d.tl
[`cosmic.layout`]: ../../cosmic/layout.tl
[`cosmic.removed`]: ../../cosmic/removed.tl
[`cosmic.shape`]: ../../cosmic/shape.tl
[`cosmic.store`]: ../../cosmic/store.tl
[`cosmic.stream`]: ../../cosmic/stream.tl
[`cosmic.test`]: ../../cosmic/test.tl
[`cosmic.time`]: ../../cosmic/time.tl
[`Coverage.native_entries`]: ../../cosmic/coverage.tl
[`Coverage.snapshot`]: ../../cosmic/coverage.tl
[`Csv.parse`]: ../../cosmic/csv.tl
[`Csv.table`]: ../../cosmic/csv.tl
[`doc/roadmap.md`]: ../roadmap.md
[`Duration.nanoseconds`]: ../../cosmic/time.tl
[`ExtractOptions.unsupported`]: ../../cosmic/archive.tl
[`Flags.Command`]: ../../cosmic/flags.tl
[`Flags.dispatch`]: ../../cosmic/flags.tl
[`Flags.help`]: ../../cosmic/flags.tl
[`Flags.Parsed`]: ../../cosmic/flags.tl
[`Fs.cache_path`]: ../../cosmic/fs.tl
[`Fs.create`]: ../../cosmic/fs.tl
[`Fs.put`]: ../../cosmic/fs.tl
[`Fs.read`]: ../../cosmic/fs.tl
[`Fs.Staged`]: ../../cosmic/fs.tl
[`Fs.truncate`]: ../../cosmic/fs.tl
[`Fs.walk`]: ../../cosmic/fs.tl
[`Fs.write`]: ../../cosmic/fs.tl
[`Hash.byte_sum`]: ../../cosmic/hash.tl
[`Hash.Hasher`]: ../../cosmic/hash.tl
[`Hash.Mac`]: ../../cosmic/hash.tl
[`Http.download`]: ../../cosmic/http.tl
[`Http.upload`]: ../../cosmic/http.tl
[`Json.layout`]: ../../cosmic/json.tl
[`ListenOptions.reclaim`]: ../../cosmic/net.tl
[`Net.Address`]: ../../cosmic/net.tl
[`Net.Conn.read`]: ../../cosmic/net.tl
[`Net.Conn`]: ../../cosmic/net.tl
[`Net.pair`]: ../../cosmic/net.tl
[`Net.serve`]: ../../cosmic/net.tl
[`Net.tcp`]: ../../cosmic/net.tl
[`Net.unix`]: ../../cosmic/net.tl
[`Options.cancelled`]: ../../cosmic/http.tl
[`Pipe.streamed`]: ../../cosmic/child.tl
[`Poll.CANCELLED`]: ../../cosmic/poll.tl
[`Poll.delay`]: ../../cosmic/poll.tl
[`Poll.MOST_NS`]: ../../cosmic/poll.tl
[`Poll.ready`]: ../../cosmic/poll.tl
[`Poll.run`]: ../../cosmic/poll.tl
[`Poll.TIMEOUT`]: ../../cosmic/poll.tl
[`Poll.wait`]: ../../cosmic/poll.tl
[`Proc.arguments`]: ../../cosmic/proc.tl
[`Proc.relaunch`]: ../../cosmic/proc.tl
[`ServeSpec.workers`]: ../../cosmic/net.tl
[`Shape.either`]: ../../cosmic/shape.tl
[`Shape.failures`]: ../../cosmic/shape.tl
[`Shape.record`]: ../../cosmic/shape.tl
[`Spec.kind`]: ../../cosmic/shape.tl
[`Sqlite.cell`]: ../../cosmic/sqlite.tl
[`Sqlite.Query`]: ../../cosmic/sqlite.tl
[`Sqlite.Value`]: ../../cosmic/sqlite.tl
[`Store.meta`]: ../../cosmic/store.tl
[`Stream.ArchiveEntry`]: ../../cosmic/stream.tl
[`Stream.ArchiveWriter`]: ../../cosmic/stream.tl
[`Stream.Codec`]: ../../cosmic/stream.tl
[`Stream.copy`]: ../../cosmic/stream.tl
[`Stream.create`]: ../../cosmic/stream.tl
[`Stream.FileWriter`]: ../../cosmic/stream.tl
[`Stream.from_fd`]: ../../cosmic/stream.tl
[`Stream.hashing`]: ../../cosmic/stream.tl
[`Stream.read_all`]: ../../cosmic/stream.tl
[`Stream.tee`]: ../../cosmic/stream.tl
[`Stream.to_fd`]: ../../cosmic/stream.tl
[`Stream.transform_writer`]: ../../cosmic/stream.tl
[`Stream.Transform`]: ../../cosmic/stream.tl
[`String.trim`]: ../../cosmic/string.tl
[`sys.flock`]: ../../core/syscalls.h
[`sys.poll`]: ../../core/syscalls.h
[`Tar.Writer`]: ../../cosmic/tar.tl
[`Test.any_host_refusal`]: ../../cosmic/test.tl
[`Test.fields`]: ../../cosmic/test.tl
[`Test.lua_trouble`]: ../../cosmic/test.tl
[`Test.network_trouble`]: ../../cosmic/test.tl
[`Time.civil`]: ../../cosmic/time.tl
[`Time.Duration`]: ../../cosmic/time.tl
[`Time.from_civil`]: ../../cosmic/time.tl
[`Time.minutes`]: ../../cosmic/time.tl
[`Time.monotonic_ns`]: ../../cosmic/time.tl
[`Time.ms`]: ../../cosmic/time.tl
[`Time.seconds`]: ../../cosmic/time.tl
[`Time.sleep_ns`]: ../../cosmic/time.tl
[`Zip.Reader.entries`]: ../../cosmic/zip.tl
[`Zip.Writer`]: ../../cosmic/zip.tl
[`Zoned.ns`]: ../../cosmic/time.tl
