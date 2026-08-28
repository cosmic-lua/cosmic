## Goal

G3 — an honest type layer, no escape hatches. From the census in
`docs/design/casts.md`: the **function shape** class, 10 sites. Files:
`cosmic/net/socket.tl` 3; `cosmic/quicksand/proxy.tl` 3;
`cosmic/check_assertions_test.tl` 1; `cosmic/coverage/init.tl` 1;
`cosmic/net/connect.tl` 1; `cosmic/quicksand/init.tl` 1. The shape is
an overloaded binding declared as a union of signatures, with one arm
selected by casting the FUNCTION before calling it rather than casting
the result. `cosmic/net/socket.tl` is the pure case: `unix.bind` and
`unix.connect` take either a sockaddr or a filesystem path, one
generated declaration covers both, and a caller that knows it is on the
unix-path arm has no way to say so except by restating the signature.
The census verdict is **what closes it upstream**:
`tool/net/definitions.lua` in `whilp/cosmopolitan` declares one
function per C entry point, so an overload is one annotation covering
two contracts. Splitting the overloaded entries into separately
annotated names — or annotating the union so `_types/gentype.tl` emits
a real function union tl can dispatch over — removes the cast at every
call site, and lands as a change in the other repository followed by a
`3p/cosmos/cosmos_pin.tl` bump here. Note the neighbouring precedent:
the `-- cast: function shape` reason string also covers three sites in
`cosmic/quicksand/proxy.tl` that are function reads off a map view
rather than binding overloads, so read each site before assuming it is
the same fix. Deleting the casts afterwards lowers the affected
`_build/casts_baseline.tl` rows. The class description and its two
exemplar citations are the `### function shape` section of
`docs/design/casts.md`; the per-site list is
`docs/design/cast-sites.tsv`.
