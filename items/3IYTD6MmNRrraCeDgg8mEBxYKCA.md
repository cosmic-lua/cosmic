## Evidence

Measured 2026-08-28 against `origin/main` `40776231`.

`docs/guides/lint.md:3-6` promises:

> `cosmic --make lint` (and its per-file form `cosmic --check lint <file>`)
> runs the style gate. every rule it can fire is enumerated here, with the
> failure it produces and the fix — so the first time you meet a rule is
> not the moment you have to reverse-engineer it.

The gate can fire 15 rules; the guide enumerates 13.

    grep -rhon 'rule = "[a-z-]*"' _cli/*.tl _tool/*.tl | sed 's/.*rule = //' \
      | sort -u | wc -l                        # 13
    grep -n 'unjustified(file, t, "' _cli/throw_lint.tl   # throw-justify, exit-justify
    grep -c '^## ' docs/guides/lint.md         # 13, of which 12 are rule sections
                                               # ("throw-justify and exit-justify"
                                               #  covers two, and one section is
                                               #  "running one rule's worth of output")

Undocumented: `doc-citation` and `reads-declaration`. `3IYPq8Sx` adds the
`## doc-citation` section, which leaves `reads-declaration` — the rule
`3I1RuEqx` introduced, which flags a test that reads the tree without a
`--- reads:` declaration. A session meeting it gets exactly the experience
the guide's own sentence promises it will not.

The guide ships in the binary (`cosmic --docs guide.lint`), so the false
sentence is delivered by the tool.

The slice: add a `## reads-declaration` section in the shape the other
sections use — what the rule checks, the diagnostic verbatim, the fix
(the `--- reads: <path>` header, and how make consumes it as the target's
prerequisite). Measured now: `wc -l docs/guides/lint.md` is 353, 147 lines
under the 500-line cap.

Worth considering as the durable fix instead of a one-time sweep: a
`_build/` ratchet asserting that every rule name the lint can emit has a
`## <rule>` heading in the guide. The rule names are string literals in
`_cli/*.tl`, so the check is a grep pair, and it is what would have caught
both of these gaps when they were introduced.
