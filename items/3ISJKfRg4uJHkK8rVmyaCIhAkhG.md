The two from-any casts no other open item claims, measured 2026-08-26
at cosmic main b4ad036b. (1) cosmic/teal.tl:166 casts `fd as FILE`
after tl.search_module — an under-typing in OUR OWN generator:
_types/gentl.tl curates the narrowed tl.d.tl surface, and
search_module's second return is left loose where tl's source returns
the open file handle; declaring it FILE in the curation closes the
cast with no upstream change. (2) cosmic/surface_test.tl:92 casts a
dynamic `require("cosmic." .. name)` to {string: any} while walking
the published surface — the is-guard shape the other dynamic-require
sites adopted (assert(mod is {string: any}, name .. ": not a module
table")) closes it and improves the failure message. Together with the
sibling captures (overload splits, constant maps) and the census's
Fetch classification, these are the last two sites between the tree
and zero unjustified from-any casts.
