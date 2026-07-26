# 060 — the coverage ratchet's environment-sensitivity is the root of CI's complexity

severity: low (design observation; treatments exist and work, but they compound)
type: ci / design
area: coverage ratchet, pr.yml container pinning, the builder-user dance

## observation

two of CI's heaviest complications exist to hold the **coverage
ratchet's inputs** still, because the floors encode which lines
execute, and that depends on the environment:

- the digest-pinned container (#734) exists because an OS image roll
  moved coverage (#722's floor churn) — so the image became a pin.
- the non-root builder dance (useradd + chown + runuser, in every
  lane) exists because tests skip differently as root
  (`fs/walk_test` skips its EACCES path under `geteuid()==0`) — so
  *identity* became a pinned build input too.

both treatments are correct given the ratchet's design, and the pin
comments are exemplary. but the shape is: an environment-sensitive
metric forced CI to pin the environment, twice, and each new
sensitivity discovered (the next kernel-dependent skip, the next
image-dependent branch) adds another pin. the ratchet is doing its job
— the question is whether the metric could stop being sensitive
instead.

## options, none free

1. **skip-aware coverage**: lines inside a test that reported skip
   (status 2) are excluded from the denominator, so a skipped path
   moves no floor. requires the coverage collector to know test
   boundaries — it may already, via the per-test `.got` contract.
2. **floor on the intersection**: ratchet against lines covered in
   *every* lane rather than one lane's totals — environment-variable
   lines fall out of the floor by construction. costs cross-lane
   aggregation.
3. **accept and document**: keep the pins, and add the missing half —
   a recorded inventory of known environment-sensitive tests (the
   walk_test root-skip is folklore today), so the next floor churn is
   diagnosable in minutes instead of rediscovered.

option 3 is cheap and worth doing regardless; 1 is the structural fix
if the collector's data supports it. this item is deliberately an
observation with options rather than a prescription — the ratchet's
authors know its data model best. filed because 057/058 clean up the
*symptoms'* duplication, and it would be a shame to polish the pins
without recording why they exist.
