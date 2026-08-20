## Evidence

2026-08-20 audit at main 0b2907b9, by reading. `cosmic/rand.tl:197`
(`insecure_source:int`): `max - min + 1` wraps to 0 for
`int(math.mininteger, math.maxinteger)`, producing an unnamed
`attempt to perform 'n%%0'` error. The top-level `rand.int` guards
exactly this case at rand.tl:58-62; the Source method does not, so
the documented contract-violation throw (D22) is an interpreter
error instead of the module's own message. One guard, mirrored from
rand.int.
