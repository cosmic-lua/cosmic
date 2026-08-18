28 of the board's 62 items — every one carrying "Imported from
whilp/cosmic#NNNN" whose importer preserved special characters at all —
have HTML-entity-encoded text baked into their spec sidecar's COMMITTED
content: literal `&#39;` in place of `'`, `&#34;` in place of `"`, `&lt;`
in place of `<`, `&gt;` in place of `>`, and presumably `&amp;` in place
of `&`. This is not a display artifact of `gitboard show` — it is in the
git-tracked bytes of the `.md` file itself.

Confirmed directly on disk (not through any rendering path):

```
$ grep -c "&#39;\|&#34;" items/3I1J83ZrdZ2D027WFZhGm2WB2mM.md
9
$ sed -n '63p' items/3I1J83ZrdZ2D027WFZhGm2WB2mM.md
$ git ls-files | grep -c &#39;^_tool/floor&#39;
```

That last line is a ```facts``` block command `gitboard check` executes
literally via the shell. As committed, it is not
`git ls-files | grep -c '^_tool/floor'` — it is `git ls-files | grep -c
&#39;^_tool/floor&#39;`. `&` is a shell metacharacter (backgrounds the
preceding command) when it appears unquoted, so this line does not even
run the intended `grep` — it runs `git ls-files | grep -c` in the
foreground with no pattern argument (dumping the whole `grep -c`'s usage
behavior or matching nothing depending on grep's default), backgrounds
nothing effectively since `&#39;...` is left as unparsed trailing text
that the shell treats as a syntax element, and `check`'s comparison
against the item's stated expected value fails. This is exactly the
failure `gitboard check 3I1J83Zr --root /home/user/cosmic` produces
today: several facts report "got" values that are the entire
unfiltered `git ls-files` output (thousands of lines) instead of a
single count, because the `grep -c '...'` pattern argument never
reached `grep` as a quoted string.

Scope, measured just now:

```facts
$ grep -l "Imported from whilp/cosmic#" items/*.md | wc -l
37

$ grep -l "Imported from whilp/cosmic#" items/*.md | xargs grep -lc "&#39;\|&#34;" 2>/dev/null | wc -l
28

$ grep -c "&#39;\|&#34;" items/3I5FXjkeLGLSkxRK9dIi696xBnl.md items/3I0uVrEjqHRdRqvF2ruVexdtbfr.md items/3I0L8yuRpu3qARCS9LGEi5Lo517.md
items/3I5FXjkeLGLSkxRK9dIi696xBnl.md:0
items/3I0uVrEjqHRdRqvF2ruVexdtbfr.md:0
items/3I0L8yuRpu3qARCS9LGEi5Lo517.md:0
```

The three items above were authored or fully rewritten by this session
today via `gitboard spec`/`gitboard new` with plain-text `.md` files, and
carry zero corruption — confirming the pipeline that broke these 28 is
specifically whatever imported the original GitHub issue bodies, not
`gitboard spec`/`gitboard new`/`git commit` themselves. The likely
mechanism: the import step round-tripped each issue body through
something that HTML-escapes (a markdown renderer, or GitHub's own
rendered-HTML API response) without ever unescaping it back to plain
text before writing the `.md` sidecar.

**Why this matters beyond cosmetics:** any of the 28 items' `## Change`
or `## Acceptance` sections that carry a ```facts``` block with a quote,
angle-bracket, or ampersand in the command is silently unrunnable or
runs something other than what it says — `gitboard check ID` either
fails with a confusing "got: <huge unrelated output>" (as reproduced
above for `3I1J83ZrdZ2D027WFZhGm2WB2mM`) or, worse, could pass an
already-wrong or truncated comparison and let a broken fact through.
Every one of the 28 needs re-verification once decorrupted, not just a
mechanical find-and-replace, since a planner refining any of them today
would have to work around the corruption by eye rather than trusting
`check`'s output.

The exact affected item ids (28 total), for whoever picks this up:

3HyArM3A3zHuRxn3VYCvKmUZ7KW, 3HyCQm05dHCVp7IqBqm9ISGI3VU,
3HyCSe5UymQuLd6ZuQr16pklSp9, 3HyEE7RJtMNPYTEwmXQpZzNfxtt,
3HyEla9Ld3pHajEG8TUgM6XbRCt, 3I0L1TbUu5oX2PDrFxsao27qaKY,
3I0c25z7w2pYGONQUwkDW1oUOCA, 3I0sXotS6pEUCRe89KIgqfaXQVn,
3I1IfJ228vyPoO9rhbHhc6RjxJB, 3I1IoF4k4xEZz3fd6VMKpIfXaNr,
3I1J83ZrdZ2D027WFZhGm2WB2mM, 3I1J9Xhgg9FfvW4fxvQ2UZ3LS37,
3I1JDVLmiWji4tVjJ8dkxK7MuJk, 3I1RuEqxAS9H5DxYWADw1IXF5bI,
3I1RvbvauO4NY1OYCNtSWGUMrOd, 3I1iGY7ZvS8SZXztxvBZ1ceTc0d,
3I1j7yQAawHLQwtQA1bp1i3tUj4, 3I1mysETIUe6KsDNXW10QynySQC,
3I1n3sUPbF3KpbYFv8Is4xKsjsn, 3I28cCZVB4ncMdv2tM7ApUi9zyz,
3I29lm02ZpSQL5IfxFXHf2rZTMP, 3I29nhZCsHYICGr2fafPxMMmVMH,
3I2UTbnHGmWLMf6JTiT2vbCOkrY, 3I2UV1xRmth5RWXmmoVbmEW9jhN,
3I2qqRxrpQtRrqrH64sGzLPSy14, 3I2rIA9uI4DQqlcRe47TQfQaTFK,
3I2rLWw2UwaLkErUPjy0zDpbg4L, 3I3m8NDOhNtmITYURFnZBDmF20x

A likely-cheap fix: a one-shot decode pass (HTML-unescape `&#39;`,
`&#34;`, `&lt;`, `&gt;`, `&amp;` — in that order, `&amp;` last, to avoid
double-unescaping) over exactly these 28 `.md` files via
`gitboard spec ID <decoded-file>` per item (or a small one-off script
if the tool grows a bulk-rewrite path), followed by a fresh
`gitboard check ID --root <clean-clone>` on each to confirm the
decoded facts blocks now execute and compare correctly — some may
newly reveal STALE facts (measured against an older tree state) once
they can actually run, which is separate cleanup work each item's own
refinement pass should absorb, not this fix.
