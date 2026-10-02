# Frozen validation of the performance classifier

This protocol is fixed before running the repaired classifier. It takes no
artifact measurements or candidate results as inputs. A failed criterion is
reported and investigated; neither seeds nor criteria change to obtain a pass.

The generator is Park–Miller: `state = state * 16807 % 2147483647`, returning
`state / 2147483647`. Base seeds are 104729, 130363, 155921 and 196613.
For numbered case `c`, sample size `n`, and trial `t` (all starting at 1),
initialize the stream to
`(base[(c-1)%4+1] + 1009*c + 9176*n + 104729*t) % 2147483646 + 1`.
Each case/size has exactly 5000 trials. A/A and A/B use independent draws unless
a case explicitly introduces shared delay. Normal draws use Box–Muller, retaining
only the cosine draw; every normal value consumes two uniforms.

Cases 1–4 are independent null samples from, respectively:

1. Normal, mean 100 and standard deviation 10.
2. Exponential, mean 100.
3. Lognormal, median 100 and log standard deviation 1.
4. A mixture: 90% uniform [90,110], 10% uniform [180,220].

Run each at n = 30, 100, 200 and 400. At n >= 200, each population/size must
have at least 94% coverage for each reported 95% median or difference interval,
at most 6% false regressions, and at least 80% classifier passes. The individual
p95 bounds are 97.5% intervals; their difference uses the Bonferroni joint 95%
bound and must meet the 94% coverage floor. At n < 200 no trial may pass.
Report every component's coverage and positive-interval frequency separately,
including individual p95 coverage. Report 95% Wilson Monte Carlo intervals for
the observed proportions; these describe simulation uncertainty, not runtime
measurement confidence.

Case 5 uses independent normal samples with the candidate shifted by +10 at
n = 200; at least 95% must be blocked (regression or inconclusive).
Case 6 doubles only the upper component of the mixture for the candidate at
n = 400; at least 85% must be blocked. Report positive median and positive tail
interval detection independently so a blanket refusal cannot masquerade as power.

Advisory cases 7–14 enumerate the four populations in the order above, each with
a +5% then +10% shift of its population median, at n = 200 and 400. Cases 15–16
increase only the mixture's upper component by 20% then 50%, at both sizes.
Case 17 is a normal null with an independent uniform [0,40] delay shared within
each pair. Case 18 is a normal null with a +10 delay on whichever observation
runs second, alternating order by pair, plus a shared linear drift of 0.05 per
pair. Run cases 17–18 at both sizes. These last cases diagnose pairing and order
sensitivity; do not claim independent-observation coverage for the order case.
For case 17, the marginal median is 120 and both paired median and p95
differences are zero. Omit marginal p95 coverage: its convolution quantile is
not supplied. Case 18 reports decisions and positive intervals, not coverage.

Numerical unit tests use a separate integer reference: sum
`C(n,k) * numerator^k * (denominator-numerator)^(n-k)` against the exact integer
total `denominator^n`. Median tails are 1/40 each, p95 tails 1/80 each. This is
independent of the production mode-centered floating-point recurrence.

| n | Median lower/upper ranks | p95 lower/upper ranks |
|---:|:---:|:---:|
| 6 | 1 / 6 | 4 / 7 |
| 30 | 10 / 21 | 25 / 31 |
| 85 | 33 / 53 | 76 / 86 |
| 86 | 34 / 53 | 77 / 86 |
| 100 | 40 / 61 | 90 / 100 |
| 200 | 86 / 115 | 183 / 197 |
| 400 | 180 / 221 | 370 / 390 |
| 1000 | 469 / 532 | 934 / 966 |
| 1074 | 505 / 570 | 1004 / 1037 |
| 1075 | 505 / 571 | 1005 / 1038 |
| 1076 | 506 / 571 | 1006 / 1039 |
| 2000 | 956 / 1045 | 1878 / 1922 |

Rank 0 means an unbounded lower endpoint; rank n+1 means an unbounded upper
endpoint. Neither is replaced by a finite observation. Ties, even/odd samples,
input immutability, positive intervals within calibration uncertainty, and
tail-only slowdowns are separate deterministic regression cases.
