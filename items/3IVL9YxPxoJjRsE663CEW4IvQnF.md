cosmo.EncodeLua's `literal=true` (#278) encodes nestings its own
reader refuses: lcosmo.c:108 defaults maxdepth to 64 while DecodeLua's
cap is 32 (llua.c:33, "Matches the Lua-side reader's cap"). A 40-deep
table encodes successfully and DecodeLua refuses the output with
"nests deeper than 32 tables" — defeating #278's stated purpose ("a
caller that needs the output read back no longer has to walk the value
first"). The committed test exercised only an explicit maxdepth=2, so
the default-depth mismatch is unpinned. Fix: literal mode's effective
depth cap becomes 32 (or the two caps become one constant), plus a
round-trip test at depth 33. Same class as cosmic-side 3ICDKhO3
(format renders what parse refuses), different site.
