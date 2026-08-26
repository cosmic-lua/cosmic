Every lint diagnostic prints its `file:line` twice. `_cli/lint_render.tl:36`
renders `string.format("%s:%d:%d: %s: %s", d.file, d.line, d.col, d.rule,
d.message)`, and every rule ALSO opens its `message` field with a
`"%s:%d: "` prefix built from the same file and line.

Observed against main `14ff1d1d` with the pinned `bin/cosmic`, on a scratch
file carrying one unjustified cast:

```
$ bin/cosmic --check lint /tmp/probe.tl
/tmp/probe.tl:2:1: cast-justify: /tmp/probe.tl:2: `as` cast without
justification: prefer `is` narrowing or check.must (see `cosmic --docs
guide.checking`); a deliberate cast takes a trailing `-- cast: <reason>`
(or on the line above)
    | local y = x as string
```

The prefix predates the renderer: messages carried their own location back
when they were printed bare, and `_cli/lint_render.tl` (added later, and
deliberately its own module) prefixed them again without the messages being
stripped. It affects 13 rule sites, not one —
`git grep -n '"%s:%d:' -- '_cli/*.tl' | grep -v '_test\.tl' | grep -v
lint_render` lists them across `assert_lint.tl` (1), `citations.tl` (3),
`lint.tl` (4), `pattern_args.tl` (2), `reads_lint.tl` (1), `returns.tl` (1),
`visibility.tl` (1). New rules copy it because every neighbour has it:
`assert-justify` (#1401) inherited the shape from `return-assert` beside it,
and that PR's own demo transcript silently omitted the doubled prefix,
which is how easy it is to not see.

The cost is a wasted line-width on every finding — the doubled path is worst
on long absolute paths, where it can push the actual message off the first
terminal line — and a message field that cannot be reused anywhere the
location is supplied separately.

Two candidate shapes, not decided here: strip the prefix from the 13 message
literals and let the renderer be the one place location is formatted; or keep
the messages self-describing and have the renderer emit only `col: rule:`.
The first is the smaller change to the renderer and the larger one to the
rules. Note AGENTS.md and several specs describe the diagnostic format as
frozen (`file:line: rule: message`) because downstream reads it, so this
needs a look at what actually consumes the rendered text before either shape
is chosen.
