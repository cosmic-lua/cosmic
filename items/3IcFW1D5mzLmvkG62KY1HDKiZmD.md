Evidence (review of cosmopolitan PR #286, 2026-08-30):
`build/download-cosmocc.sh` still downloads from
https://github.com/whilp/cosmopolitan/releases — served today only by
GitHub's org-transfer redirect, which is not a permanent guarantee (a
future user named whilp/cosmopolitan would break it). The rename PR
correctly left it (its non-goals excluded build-script changes). The
change: one-line owner swap to cosmic-lua/cosmopolitan in that URL
constant, carried by the next build-touching PR on that repo (or its
own tiny PR if none comes soon); verify the new URL serves the pinned
COSMOCC_VERSION asset before merging.
