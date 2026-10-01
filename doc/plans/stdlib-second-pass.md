# stdlib second pass

this document plans what follows [stdlib-simplification.md](stdlib-simplification.md)
once its nineteen PRs have merged: the mechanical follow-ups those PRs left
behind, one object style for the tree, the build's own raw syscalls routed
through [`cosmic.fs`] and held there by a check, the verb-level loose ends, and
then the five public modules the tier order in [design.md](../design.md)
names next: `re`, `url`, `uuid`, `ksuid` and `template`. it follows the
first plan's rules for every PR, and its sections are marked done and the
file deleted the same way.

## decisions

- **the first plan's decisions stand**: removals outright with
  [`cosmic.removed`] hints, verb-only code in `build/`, nanoseconds
  everywhere, every PR reviewed adversarially before it opens and
  auto-merged when green.
- **a verb is documented by its help text alone.** `build/` modules carry no
  worked examples, and will not: what a verb does is `cosmic help <verb>`'s to
  say, and its tests pin it. an export in `build/` is earned by the verb
  that calls it. the examples PRs 2, 3 and 4 dropped when their subject left
  the library are not coming back.
- **one object style.** an object a module hands out -- a reader, a writer,
  a handle, a connection, a query -- is a record whose methods live on one
  shared method table reached through a metatable, with its state in fields,
  as [`Stream.create`]'s writer and tar's and zip's entries already are. a
  closure-in-a-table object stays only where it has one or two methods and no
  state but an upvalue or two (a `Collector`, a `Lines`). the measurement that
  decides it: 35 per-instance closures in [`cosmic/stream.tl`] alone, and three
  modules (tar, zip, stream) that already use the other style for the
  objects made per entry, with a comment saying why. a method table typed
  `{string:any}` is not the way: the record is declared with its methods as
  function fields and the table is that record's.
- **the build calls [`cosmic.fs`], not [`cosmic.sys`], unless it must.** a raw
  syscall belongs to the modules that abstract one (`fs`, `proc`, `env`,
  `time`, `net`, `child`, `poll`, `stream`, `rand`, `http`, `zip`, `archive`)
  and to the sandbox and its probes, which are the sandbox's own enforcement
  and have no abstraction to go through. everywhere else the tree reads a
  file through `Fs`. a tree check holds it there, with an allowance list that
  names each module that keeps the raw table and why, so the list cannot grow
  silently.
- **the new modules come from `old` where `old` has them, rewritten to the
  tree's conventions**, never copied: `git show origin/old:cosmic/<name>.tl`
  reads each. `old`'s `re` wraps the cosmopolitan fork's engine, which this
  tree does not have; `old`'s `template` compiles text to Teal source at build
  time (five files, about 820 lines), which is the right shape for a runtime
  with a compiler in it, and is kept.
- **`re` is C, vendored, fuzzed.** design.md's line: a regex engine is never
  borrowed from the libc, since musl and libSystem disagree on `regcomp`'s
  corners; the planned engine is a standalone extraction of musl's TRE-derived
  one, about 4,300 lines, compiled the same on both targets. it enters as a
  vendored tree under [`bin/vendor`]'s rules, with a `patch/` record for every
  change, a fuzz test beside the binding, and its size named in the size
  report.

## wave A: the mechanical follow-ups

**PR A1 `ci: move the driver pin, and take up every TODO it unblocks`.**
once main has published a `next-<commit>` prerelease carrying the first plan's
changes, [`ci/cosmic-driver.pin`] moves to it (its commit, URL and SHA-256,
checked against the digest the release records), and every `TODO:` that
`o/bin/cosmic todos '"cosmic-driver.pin"'` lists is taken up: PR 1's
[`ci/cosmic_ci/plural.tl`] returns `String.counted`; anything the later PRs
left for [`bin/zig`], [`bin/vendor`], `ci/` or the standalone scripts. one PR, as
#2061 was.

**PR A2 `json: the core's encoder keeps only the options the library offers`.**
PR 2 removed `sorted`, `indent`, `ascii`, `nan_as_null` and `sparse_as_null`
from [`Json.EncodeOptions`] and left the C encoder supporting them for no
caller, with `build/json_raw.tl` reaching the raw table so tests could keep
exercising them. delete the five options from [`core/json.c`], the module, its
`casts` entry in [`build/contracts.tl`], and the tests that exist only for
them (`core/json_encode_test.tl`'s option cases, the raw-table fuzz
properties); keep every test of what the library offers. a C change, so
`bin/zig build analyze` and the checked core run as PR 16 ran them.

**PR A3 `doc: the first plan is done, and the review's measurements are
re-taken`.** re-run the review's measurements over the merged tree -- exports
with no caller outside tests and examples (from the `uses` table), duplicated
helpers, lines per module, the `counted`/prologue/temp-and-rename copies --
and record them against the first plan's baseline in this document's
"baseline" section below; delete `stdlib-simplification.md`, as roadmap.md
deletes what ships; move anything a PR left to the roadmap to
[`doc/roadmap.md`] if it is not there yet.

## wave B: one style, one door

**PR B1 `stream, http, sqlite, json: one object style`.** the decision above
applied to the modules whose objects are made often: every Reader and Writer
[`cosmic/stream.tl`] makes (`from_string`, `from_fd`, `transform`, `limit`,
`prepend`, `lines`, `to_fd`, `collect`, `hashing`, `tee`,
`transform_writer`), [`Http.Response`] and [`Http.Upload`], [`Sqlite.Query`],
`Json`'s remaining per-call closures. each becomes a declared record with
its methods as function fields, one shared method table per kind, its
state in fields, and `__close` where it has one; the behaviour and every
test pin stay. the measurement reported in the PR: per-instance
allocations before and after for one reader and one writer (a `collectgarbage("count")`
delta over 10,000 constructions), and the suite's time.

**PR B2 `child, net, poll: one object style`** (after B1, and after the
first plan's wave 4, which reshapes these). [`Child.Handle`] (today a record
with five per-handle closures assigned in `make_handle` plus a metatable
only for `__close`/`__gc`), [`Net.Conn`], [`Net.Listener`], [`Poll.Task`] and the
guard. the same measurement.

**PR B3 `archive, tar, zip, codec: one object style`** (after the first
plan's PR 8). the readers and writers of the three formats, and
[`build/codec.tl`]'s coders, on the shared tables tar and zip already use for
their entries, with the `{string:any}` method tables they use today replaced
by the declared records.

**PR B4 `build: files are read through cosmic.fs`.** the 29 modules under
`build/`, `cmd/`, `eval/` and `ci/` that require [`cosmic.sys`] today, less
the ones the allowance below keeps, call `Fs` instead: [`sys.stat`] (nine
modules), [`sys.open`]/[`sys.close`] (eight), [`sys.mkdir`] (seven),
[`sys.readdir`] (five), [`sys.getenv`] (seven, which is [`Env.get`]), [`sys.lstat`]
(seven; `Fs` gains `lstat` or a `follow = false` option on `stat`, the one
call this sweep shows `Fs` lacks), [`sys.realpath`] ([`Fs.absolute`]),
[`sys.getcwd`], [`sys.uname`], [`sys.getpid`] (`Proc`). where a module needs the
errno ([`Fs.exists`] and [`Fs.remove`] already fold ENOENT; a module comparing
`number == sys.EEXIST` by hand is a candidate for a new `Fs` predicate, not
for keeping the raw call). what remains raw after the sweep is named in the
allowance with its reason.

**PR B5 `fix: a tree check holds the raw syscall table to its door`**
(after B4). a check in [`build/tree_checks.tl`]: every module that requires
[`cosmic.sys`] (or stores a stand-in into it) is either a `cosmic/` module
that abstracts a syscall, the sandbox and its probes ([`build/confine.tl`],
[`build/test_sandbox.tl`], [`build/sandbox_probe.tl`], [`build/stand_in_probe.tl`],
`build/retained_probe.tl`, [`build/test_worker.tl`], [`build/this_program.tl`]),
or named in an allowance with the reason no `Fs`/`Proc`/`Env` call can stand
in; the check fails `fix --check .` for any other, and refuses a stale
allowance. the test harness's `library` list already names which
`cosmic.*` modules the harness may reach; this is the same shape for the
raw table.

## wave C: the verb-level loose ends

**PR C1 `docs: a removed name answers its replacement`.** `cosmic docs
Codec.encoder` today falls back to related symbols or, worse, answers
`build.codec verb.encoder`; three reviews noted it. the docs verb consults
[`cosmic.removed`]'s `members`, `replacements` and `names` before searching,
and answers the hint as a page, so the first plan's original rule 3 holds.
one test per shape of name (a member, a type, a removed global's field).

**PR C2 `codec: the verb drives its coders as transforms`.** `cosmic codec`
still hand-drives `update`/`finish` because a decoder's output is held one
chunk back so a refused input of at most 64 KiB writes nothing; PR 7
recorded that as a limit. close it: [`Stream.transform_writer`] gains the
hold-back as an option (`{ hold = n }`: write nothing of a chunk until the
next arrives or `close` commits), the verb uses it, and the verb's own loop
goes. only if that leaves the verb simpler; otherwise the comment stands and
this PR is dropped from the plan with a line saying so.

**PR C3 `stream: a Reader's read takes max_bytes`.** the one bound still
named `max` after the first plan: `Reader.read(max?)` and every
implementation (zip, tar, net, http, child, stream). a chunk size the caller
picks is a bound on what one call answers, so the name is right; this is a
rename across the tree with no behaviour change, done once the first plan's
wave 4 has reshaped the readers so it is done once.

## wave D: the next public modules

each is one PR; `re` is two. each starts from `old`'s module where there is
one, rewritten: honest returns, enums for modes, options records, `_ns`
units, doc comments in the tree's voice, a worked example per export, a fuzz
test for every parser of untrusted text, a `cosmic docs` page that reads
well, and an entry in the quickstart guide. a module enters the tier list in
design.md as it lands.

**PR D1 `uuid: versions 4 and 7`.** `cosmic rand uuid` already makes both
([`build/rand.tl`]'s `uuid`, `uuid_text`, `last_v7`): that code becomes
`cosmic/uuid.tl` -- `Uuid.v4(): string`, `Uuid.v7(): string`, `Uuid.parse(text):
Uuid.Fields | nil, string` (version, variant, the 16 bytes, and for v7 its
timestamp in nanoseconds), `Uuid.format(bytes): string`, `Uuid.nil` -- over
[`Rand.entropy`] and [`Time.now_ns`], with v7's monotonic counter a `Uuid.Source`
record a caller makes rather than module state (a process that makes ids
from two places must not share one counter unknowingly). the verb calls
it. `old`'s `uuid.tl` is 35 lines over the cosmopolitan fork and contributes
only its names.

**PR D2 `ksuid: k-sortable ids`.** `old`'s `cosmic/ksuid.tl` (163 lines:
20 bytes, a 4-byte big-endian timestamp from the KSUID epoch 2014-05-13 and
16 random bytes, base62 to 27 characters) rewritten: `Ksuid.new(): string`,
`Ksuid.parse(text): Ksuid.Fields | nil, string`, `Ksuid.format(bytes)`, the
base62 alphabet shared with [`cosmic.codec`] if codec gains base62 (it does
not today; the alphabet stays private to ksuid unless a second caller
appears). a fuzz property that parse∘format is identity over random bytes
and that a 27-character text either parses or is refused with its position.

**PR D3 `url: parse, format, resolve, and the query`.** `old`'s
`cosmic/url.tl` (485 lines) rewritten to RFC 3986: `Url.parse(text): Url.Parts |
nil, string` (scheme, userinfo, host, port, path, query, fragment, each
nil when absent, host in brackets kept for IPv6), `Url.format(parts)`,
`Url.resolve(base, reference)` (RFC 3986 section 5, the one algorithm every
redirect and relative link needs), `Url.escape`/`Url.unescape` for a
component (percent-encoding by component, as RFC 3986 2.2 to 2.4 define the
reserved sets), and `Url.query(text): {string:{string}}` / `Url.encode_query`
(application/x-www-form-urlencoded, `+` for space, repeated keys kept in
order). [`cosmic.http`] keeps taking a string; [`build/bare.tl`]'s
password-stripping of a URL for a message moves onto `Url.parse`/`format`.
fuzzed: parse∘format is identity on what parse accepts; resolve agrees with
the RFC's 5.4 examples, which are the corpus.

**PR D4 `re: a vendored regex engine`.** vendor the engine design.md names:
musl's TRE-derived `regcomp`/`regexec` (`src/regex/` in musl, about 4,300
lines across `regcomp.c`, `regexec.c`, `tre.h`, `tre-mem.c`), extracted to a
standalone tree under `vendor/tre/` by [`bin/vendor`] from a pin, built in
`build.zig` under `own_warnings` as far as it compiles clean and otherwise
under the vendored-library flags, with its differences from musl recorded as
`patch/` entries: the allocator routed through the core's `cosmic_malloc`
so the allocation walk sees it, `REG_ENHANCED` or any libSystem-only flag
left out, and nothing else. a C binding `core/re.c` (`compile(pattern,
flags)` to a userdata with `exec(subject, start)` answering the match
spans, `__gc`/`__close`), declared in `cosmic/internal/re.d.tl`, handed to
its wrapper as the other raw tables are. the size report names its bytes.
a fuzz test drives `compile` with random patterns (must not crash or
leak; refuses or compiles) and `exec` with random subjects against
compiled patterns (the allocation walk on the checked core covers
out-of-memory inside the engine once it allocates through the core).

**PR D5 `re: the module`** (after D4). `cosmic/re.tl` over the binding,
POSIX extended syntax only (one grammar, documented in the module's doc
comment with the differences from Lua patterns a reader will trip on):
`Re.compile(pattern, opts?): Re.Pattern | nil, string` (`{ ignore_case,
multiline, newline }` as an options record, a bad pattern answering nil and
the engine's message with the position), `Pattern:find(text, start?): Re.Match
| nil` (nil for no match, never a failure), `Re.Match` with `start`, `stop`
and `groups` (each group's span or nil), `Pattern:gmatch(text)`,
`Pattern:gsub(text, replacement)` with `\1`-style references and a function
replacement, `Pattern:split(text)`, and the one-shot forms `Re.find(text,
pattern)`, `Re.match`, taking subject first as `old`'s did. a compiled
pattern is cached per module only by the caller: no module-level cache. the
module's own fuzz test checks `find` against a brute-force matcher for a
small pattern grammar (literals, `.`, `*`, `|`, groups) so the engine's
answers are checked, not just its survival. `cosmic docs re` is the page a
person reads before writing their first pattern.

**PR D6 `template: text to a typed Teal module`.** `old`'s
`cosmic/template/` (`init.tl`, `lex.tl`, `parse.tl`, `codegen.tl`,
`types.tl`, about 820 lines) rewritten under the tree's rules: a template
file (`<name>.tmpl`) compiles at build time to a Teal module exporting
`render(data: <Record>): string`, where the record is declared in the
template's own header, so a missing field or a wrong type is a compile
error in the program that renders it, and nothing is reflected at run time.
the grammar: `{{ expr }}` with escaping by default, `{{- -}}` trimming,
`{% if %}`/`{% for %}`/`{% end %}`, includes of another template by module
name, and nothing else in the first version (filters and inheritance go to
the roadmap with the reason). the build recognises the file by position
(`<name>.tmpl` beside the module that requires it, the way `*_test.tl` is
a test), compiles it through [`build/importer.tl`]'s parse step, and the
generated Teal is checked like any other module. the lexer and parser are
fuzzed; the renderer is checked by examples in `cosmic/template_example.tl`
whose output is asserted byte for byte.

## what stays, on purpose

- [`cosmic.sys`] itself: the raw table is the one door; this plan narrows who
  walks through it, not what it is.
- `old`'s `cosmic/fs/tree.tl` and the rest of `old`'s surface this plan does
  not name: each waits for a caller, as design.md's principle 5 asks.
- `ip`, `dns`, `sse`, `tty`, `ansi`, `user`, `host`, `deep`, `graph`,
  `fuzzy`, `literal` from the second tier: not pulled yet. `sse` and `ip`
  are the likeliest next, once `url` and `re` are in and `http` has a caller
  for streamed events.

## baseline

to be filled by PR A3: the first plan's measurements re-taken over the
merged tree, beside the review's numbers (46 exports with no caller
outside tests and examples; seven `counted` copies; nine raw-module
prologues; three temp-and-rename copies; 243 `timeout_ms` sites; 33 hand
unit conversions; 20,194 lines under `cosmic/` excluding tests and
examples).

[`bin/vendor`]: ../../bin/vendor
[`bin/zig`]: ../../bin/zig
[`build/bare.tl`]: ../../build/bare.tl
[`build/codec.tl`]: ../../build/codec.tl
[`build/confine.tl`]: ../../build/confine.tl
[`build/contracts.tl`]: ../../build/contracts.tl
[`build/importer.tl`]: ../../build/importer.tl
[`build/rand.tl`]: ../../build/rand.tl
[`build/sandbox_probe.tl`]: ../../build/sandbox_probe.tl
[`build/stand_in_probe.tl`]: ../../build/stand_in_probe.tl
[`build/test_sandbox.tl`]: ../../build/test_sandbox.tl
[`build/test_worker.tl`]: ../../build/test_worker.tl
[`build/this_program.tl`]: ../../build/this_program.tl
[`build/tree_checks.tl`]: ../../build/tree_checks.tl
[`Child.Handle`]: ../../cosmic/child.tl
[`ci/cosmic-driver.pin`]: ../../ci/cosmic-driver.pin
[`ci/cosmic_ci/plural.tl`]: ../../ci/cosmic_ci/plural.tl
[`core/json.c`]: ../../core/json.c
[`cosmic.codec`]: ../../cosmic/codec.tl
[`cosmic.fs`]: ../../cosmic/fs.tl
[`cosmic.http`]: ../../cosmic/http.tl
[`cosmic.removed`]: ../../cosmic/removed.tl
[`cosmic.sys`]: ../../core/syscalls.h
[`cosmic/stream.tl`]: ../../cosmic/stream.tl
[`doc/roadmap.md`]: ../roadmap.md
[`Env.get`]: ../../cosmic/env.tl
[`Fs.absolute`]: ../../cosmic/fs.tl
[`Fs.exists`]: ../../cosmic/fs.tl
[`Fs.remove`]: ../../cosmic/fs.tl
[`Http.Response`]: ../../cosmic/http.tl
[`Http.Upload`]: ../../cosmic/http.tl
[`Json.EncodeOptions`]: ../../cosmic/json.tl
[`Net.Conn`]: ../../cosmic/net.tl
[`Net.Listener`]: ../../cosmic/net.tl
[`Poll.Task`]: ../../cosmic/poll.tl
[`Rand.entropy`]: ../../cosmic/rand.tl
[`Sqlite.Query`]: ../../cosmic/sqlite.tl
[`Stream.create`]: ../../cosmic/stream.tl
[`Stream.transform_writer`]: ../../cosmic/stream.tl
[`sys.close`]: ../../core/syscalls.h
[`sys.getcwd`]: ../../core/syscalls.h
[`sys.getenv`]: ../../core/syscalls.h
[`sys.getpid`]: ../../core/syscalls.h
[`sys.lstat`]: ../../core/syscalls.h
[`sys.mkdir`]: ../../core/syscalls.h
[`sys.open`]: ../../core/syscalls.h
[`sys.readdir`]: ../../core/syscalls.h
[`sys.realpath`]: ../../core/syscalls.h
[`sys.stat`]: ../../core/syscalls.h
[`sys.uname`]: ../../core/syscalls.h
[`Time.now_ns`]: ../../cosmic/time.tl
