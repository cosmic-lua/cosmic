# Problem

The zipfile virtual table makes every cosmic artifact introspectable
by construction — enumerate its payload, extract members, even add or
strip members transactionally with SQL (all verified 2026-08-24
against the release binary; see the companion test-suite capture for
the exact statements). No shipped doc mentions it: docs/guides/**
(what `cosmic --docs guide.<topic>` serves) has no sqlite-over-self
guide, and `cosmic --docs sqlite` documents only the file/:memory:
open paths. Users who read the fzakaria SELF post
(fzakaria.com/2026/08/23/your-executable-is-a-sqlite-database) would
not discover cosmic already delivers the queryable-executable half
with zero format changes. A guide (plus a runnable `*_example.tl`)
showing self-inspection, member extraction, and payload editing —
with the honest caveats: modules are precompiled bytecode, DELETE
does not reclaim space — would ship in the binary itself.
