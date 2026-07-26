# 033 — minor cleanups: stale comments, stray export, duplicated helper

severity: low
type: cleanup
area: various

small items found during review, none worth a file each; each is a
one-liner to fix.

1. **`cosmic/tar.tl:224`** — `parse_pax` is exported but used only by tar's
   own tests. drop it from the return table (tests can exercise it through
   extraction fixtures) or mark why it is public.

2. **`cosmic/embed/init.tl:390-392`** — stale comment still describes the
   pre-3d `.lua/cosmic/**` floor layout; the floor moved to `cosmic/**`.

3. **`cosmic/embed/init.tl:396,407`** — both `appender:remove()` calls
   discard their error returns. at minimum propagate the second (the
   remove-before-add that a failed removal turns into a duplicate-entry
   surprise).

4. **`_cli/driver.tl:82`** — `paths_of` doc comment declares six `@return`
   values; the function returns four. stale copy-paste.

5. **`_make/graph.tl:54-69` / `_make/facts.tl:58-61`** — `write_if_changed`
   duplicated. facts.tl is documented as temporary (retires with the
   bridge), so a pointer comment is enough if the dedup is not worth the
   churn.

6. **`_make/build_test.tl:11-12`** — comment says "cosmic does not carry
   one yet" about the make engine; stale since `/zip/make` is embedded and
   `_make/graph.tl:196-258` extracts it.

7. **`.github/workflows/pr.yml:19`** — comment "like any 3p/*/version.lua
   pin" references the retired pin mechanism (see 034 for the doc-level
   sweep).

8. **`embed/init.tl` strip floor prefixes** — prefixes match without a
   separator, so keeping `.args` would also keep a hypothetical `.argsX`.
   harmless today; a `/`-or-exact match closes it.

9. **`_make/init.tl:283-286`** — `fetch` is the only verb that skips
   validation. harmless (fetch reads only pins), but undocumented; one
   sentence at the site saying why.
