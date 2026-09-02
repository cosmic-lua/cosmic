## Evidence

Found by the fresh-context review of cosmic-lua/cosmic#1617 (item
3Ikbg3US, the board's tests to runner mode). Two board test files end
with a module-scope `print("all ... tests passed")` banner:
`_work/publish_race_test.tl` and `_work/publish_test.tl` (last line of
each at board `4313770b`; `grep -n 'tests passed' _work/*_test.tl`).
Under the legacy self-calling shape that line ran after the last
case; in runner mode (D29) the cases run after the module loads, so
the banner now prints BEFORE any case runs, and prints even when a
case then fails — a stale, misleading line in the gate's output.
#1617's spec held "delete the self-call lines and nothing else", so
the banners were correctly left for their own item.

## Change

Board-tooling change on the `board` branch of cosmic-lua/cosmic, as a
PR against base `board`: delete the two banner lines. Nothing else in
either file moves. `bin/cosmic --make ci` on the board branch ends
`ci: PASS` with the same test counts.

## Non-goals

- No change to any case, assertion, or other file.
