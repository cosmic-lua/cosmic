Removing a tl patch edit leaves the retired edit applied in the
unpacked tree: _make/fetch.tl:174-187's `satisfied()` verifies only
that DECLARED edits are present, so deleting an edit, an entry file of
the split tl_patch/ directory (#1437), or the whole directory leaves
previously patched products in place and `fetch` reports satisfied —
stale until the digest or a product goes missing. Changed and added
edits repair correctly (re-unpack pristine, re-apply); only removal
does not, and the directory form makes partial removal likelier.
Cheap fix: stamp the applied edit-set (names + hash) beside the
manifest and compare it in `satisfied` (_make/patch.tl:193-204 has the
applied-check half).
