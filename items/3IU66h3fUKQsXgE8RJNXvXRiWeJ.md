## Capture

Tracker, the 3ITsuHMB pattern for the next cycle: a cosmic release
whose tag commit carries main c78504bd (#1439's narrow-metatable
entries; #1442's closure-carry rule precedes it), and a
bin/cosmic.pin bump to it. This is the wall 3IU5Vhvy bounced off at
pull (2026-08-27 ~05:05: pin 2026-08-27-6b88a0d, latest release the
same — `git merge-base --is-ancestor c78504bd 6b88a0db` fails).

The 06:00 UTC release cron should produce an eligible tag;
dispatching one early is a human's call, never this item's. When the
release exists: bump bin/cosmic.pin per the 3ISVlHT6/3ITpcO21
procedure (two pin lines, sha from the downloaded asset, cold-start
`rm -f o/bin/cosmic && bin/cosmic --make fetch && bin/cosmic --make
ci` -> `ci: PASS`), eligibility by the ancestry check above. Then
this ends and 3IU5Vhvy unblocks.
