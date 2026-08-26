D23's amendment licenses a library `assert` on a cosmo binding return
whose `| nil` is unreachable for the arguments passed, "provided the
assert carries a trailing `-- assert: <why the nil cannot occur>`
comment" — and nothing enforces the proviso, where the parallel
`-- cast:` convention has the cast-justify lint. Split out 2026-08-26
from item 3IQfhI33 (whose slice fixes the one real un-licensed library
throw); prior specs deferred the lint here by name. Timing note that
shapes the priority: PR #1395 (in check at filing) retires all six
existing dance instances by making the upstream contracts exact, so at
merge the convention has ZERO live instances — the lint is insurance
for the next binding whose union is argument-dependent, not a debt
burn-down. Evidence for the shape: the cast-justify lint
(`_tool/` lint family, surfaced as `cosmic --check lint`) already
walks casts and reads the trailing/above-line comment; an
assert-justify twin would fire on `assert(` in non-test `cosmic/**`
source outside doc comments and string constants, pass the D22/D23
sanctioned modules (cosmic.check, the CSPRNG throw), and demand the
`-- assert:` marker on the licensed shape. The string-constant
exclusion matters: `cosmic/embed/init.tl:186`'s assert lives inside
the generated artifact wrapper's long-bracket source, which a naive
grep counts and a lexer-based walk correctly skips.
