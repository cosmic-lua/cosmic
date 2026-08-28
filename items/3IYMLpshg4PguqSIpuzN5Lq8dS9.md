## Goal

G3 — an honest type layer, no escape hatches. From the census in
`docs/design/casts.md`: the **enum relation** class, 11 sites. Files:
`cosmic/compress_test.tl` 3; `cosmic/hash.tl` 3; `cosmic/sys_test.tl`
2; `_fuzz/compress_fuzz_test.tl` 1; `cosmic/fetch/init.tl` 1;
`cosmic/sys.tl` 1. The shape is an enum value used where a plain
`string` is wanted, or one enum's word set used where a wider enum is
declared even though every word of the narrow set is a word of the wide
one — `CompressFormat` nesting inside `DecompressFormat` is the clean
example, and `sys.host_os()` handed to a `string` parameter is the
other. Teal relates neither pair, so a relation a reader verifies by
eye costs a cast at every site. The census verdict is **what closes it
upstream**: the missing rules are tl subtyping rules — an enum whose
words are a subset of another enum's is a subtype of it, and every enum
is a subtype of `string`. Both are the kind of rule the carried patch
already holds (`3p/tl/tl_patch/`, mechanism in `_make/patch.tl`), so
this can land either as a patch entry here or upstream in tl; either
way it stages behind a release and a `bin/cosmic.pin` bump under the
cold-build rule, because a source relying on a new checker rule passes
the converged `--make ci` and fails a cold build. `_build/coldbuild_test.tl`
is what catches that on the PR. Once the rule lands, deleting the 11
casts lowers the affected `_build/casts_baseline.tl` rows. The class
description and exemplar citation are the `### enum relation` section
of `docs/design/casts.md`; the per-site list is
`docs/design/cast-sites.tsv`.
