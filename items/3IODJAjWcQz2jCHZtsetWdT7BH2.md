`from any` is the dominant cast bucket: 192 of the tree's 402
justified casts (measured 2026-08-25: `git ls-files '*.tl' | xargs
grep -h -- "-- cast: " | wc -l` = 402; `... | grep -c "from any"` =
192). The heaviest files are tests and eval tooling
(cosmic/quicksand/box/merge_test.tl 14, _eval/score_test.tl 12,
cosmic/json_test.tl 10), where `is` dispatch over any and typed
decode surfaces (json.decode_object/decode_array) may already close
sites without new mechanism. The slice is the research: classify all
192 sites by shape (decoded-json access, pcall/load returns, test
probes of removed surface, genuine dynamic boundaries), record which
existing tool closes each class and which classes need a new
mechanism (a typed accessor, a carried-patch narrowing, an upstream
tl fix), and mint the follow-up closure slices. Deliverable is the
recorded census and the minted items, not code.
