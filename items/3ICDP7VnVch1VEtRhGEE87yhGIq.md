## Evidence

2026-08-20 machinery audit of the board branch. Every board commit is
authored as the fixed identity `cosmic-board <board@cosmic>`
(_work/store.tl GIT_DEFAULTS), and a verdict commit's subject
(`verdict <id> <kind> (check -> do)`) records no reviewer session —
so "no session accepts its own work" is enforced only at decision
time (`next --session`) and is UNAUDITABLE after the fact: the log
cannot show whether an accept was written by the builder. Cheap fix
shape: `cmd_verdict` (once it takes --session, see the
builder-distance capture) appends the session to the commit subject
or stores it on the item, making the distance a property the flow
review can measure from the log it already reads.
