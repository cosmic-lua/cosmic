# D27 — every committed floor is a `cosmic.literal` file, and duplicate keys are refused by default

- **date:** 2026-08
- **status:** active
- **context:** three gates already commit a "floor" — a file the build
  reads back and compares against, rather than a config a human hand-edits:
  `_build/casts_baseline.tl` (per-file cast counts), `_build/public_surface_baseline.tl`
  (the public API set), and the coverage ratchet's `.cosmic-coverage`
  (per-file covered/total line counts). The first two are already
  `cosmic.literal` files, written by `literal.format_file` and read back by
  `literal.parse_file` — `_build/casts.tl` and `_build/public_surface.tl` say
  so directly. `.cosmic-coverage`, instead, is its own ad hoc text format: a
  `#`-comment header and space-separated `path covered total` rows, parsed
  by hand in `_tool/coverage/`. Two floors already agree on a format that
  cannot execute code and reads back as exactly the value that wrote it;
  the third invented a second one for no reason the tree states. Meanwhile
  `cosmic.literal.parse` had a real gap for this use: `parse_table` wrote
  `out[key] = value` at five separate unchecked sites, so a table literal
  with a key repeated twice silently kept the last value and said nothing
  — invisible in a hand-written pin, where a repeat is a typo, and unsafe
  in a floor a tool may want to build by `merge=union` across shards or
  parallel lanes, where a repeat is not a mistake but a name collision the
  merge must not launder into silent data loss.
- **decision:**
  1. **One text format for every committed floor: `cosmic.literal`.** A
     gate that needs to commit and re-read a value picks `cosmic.literal`
     rather than a bespoke format, the same way a gate that needs a value
     to test against a build result already does. `cosmic.literal` is not
     invented for this — it already exists, already backs two of the three
     floors, and its whole promise ("this file cannot do anything") is
     exactly what a build-generated, build-read file needs: no reason to
     trust it beyond trusting the reader.
  2. **A duplicate key is refused, by default, everywhere `parse` runs.**
     `parse_table` computes each entry's value into a local and assigns it
     at exactly one site, where a `seen: {string: integer}` local — first-seen
     line numbers, declared fresh per table so a key repeated across two
     *different* nested tables is not a duplicate — gates the write. A
     repeat is refused in the module's existing shape: `<file>:<line>: a
     <noun> repeats the key '<key>' (first at line <n>)`, naming both
     occurrences regardless of which of `name = ` or `["name"] = ` either
     one used.
  3. **The refusal has one opt-in escape: `Options.on_duplicate`.** A
     caller that wants a merge instead of a refusal passes
     `function(key, first, second): any`; its return is stored as-is, a
     nil return included, and it does not fail — resolving is a decision
     between two values, not a fallible operation. No caller passes it
     yet; a merge tool is what will.
- **rejected:**
  - **leave `.cosmic-coverage` as its own format** — the format itself
    costs nothing today, but every future floor then faces the same
    unstated choice the last one got wrong, and a reader learning "how do
    I commit a build result" would need three different answers depending
    on which gate they're extending. One format, learned once, is what
    the pattern is worth having.
  - **a JSON floor** — `cosmic.json` can already round-trip these shapes,
    but JSON's numbers aren't Lua's (no integer/float distinction,
    `NaN`/`Infinity` unrepresentable) and a JSON floor is not readable as
    Teal without a decode step, so a broken floor stops being a `git diff`
    a reviewer reads as source. `cosmic.literal`'s output already **is** valid
    Teal, which is what makes `.tl` floors reviewable the same way code is.
  - **detect duplicates by post-hoc scan of the parsed table** — a `{string:
    any}` has already thrown away which of two colliding writes lost, so a
    scan after the fact can report THAT a collision happened but never
    which value was discarded or on what line; the check has to live at the
    write, not after it.
  - **refuse duplicates unconditionally, no escape** — correct for a
    hand-written pin, wrong for the reason a floor exists: a union merge
    across independently-generated fragments produces the same key by
    design, and the tool combining them (not the parser) is the one that
    knows how two values for the same key should combine.
  - **thread `on_duplicate` as a bare function argument to `parse`/`parse_file`**
    instead of an `Options` field — `Options` already carries `file` and
    `noun`, both about how the SAME error case (a refusal) is worded; a
    second parameter for one more knob on that same case is a second
    options record in disguise, and this module has exactly one.
- **consequences:** `parse`/`parse_file` narrow for all eleven files that
  call `require("cosmic.literal")` today: none of them writes a duplicate
  key, so the new default refusal changes nothing they do and closes the
  gap for every one of them going forward. The lexer moved out to
  `cosmic._literal_lex` to make room for the check within the file-length
  cap — a pure move, so it costs a second flat sibling next to
  `_literal_format` but no behavior change. The cost accepted: `parse_table`
  gained a `seen` table and one more branch on its hot path, on a module
  whose inputs (pins, floors) are small enough that the cost is not
  measured. What this does not yet do: migrate `.cosmic-coverage` to
  `cosmic.literal` (a gate migration, not this decision) or give any
  caller a working `on_duplicate` merge — both are follow-on slices that
  this contract exists to make safe to build. Revisit if a floor needs a
  shape `cosmic.literal`'s domain refuses (an array, a non-string key):
  that is a reason to extend the grammar, not to reach for a second
  format.
