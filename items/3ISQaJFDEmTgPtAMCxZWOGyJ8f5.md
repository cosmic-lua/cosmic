The check queue's drain rate is bounded by an ELIGIBLE reviewer being
awake, and parallelism makes ineligibility the common case: review
distance (no session judges what it built) means that when N active
sessions are all builders of the in-check items, nobody present may
issue a verdict, and the queue grows until a non-builder happens to
ask. Measured 2026-08-26: check peaked at 5 items whose claims
belonged to just two sessions; every verdict issued today came from a
session that happened to be running for other reasons, with latencies
of 10-40 minutes between a PR going green and its verdict. The
ordering already puts verdicts first ("verdicts before new work") —
the gap is purely that no session exists whose PRESENCE is scheduled
rather than incidental. The shape: a Routine-fired fresh session on a
short cadence whose whole loop is sync, then next, then only verdict/
land actions until next stops offering them, then exit — never
pulling or refining, so it is cheap when the queue is empty and its
identity is fresh each firing (review distance holds by
construction). Prior art on the board: scheduled runs already exist
as a concept (3IHDCJ3o's required-lanes observer); this is the same
mechanism pointed at the right edge of the board. The known blocker
to inherit: gitboard land's merge call is 403 from scheduled sessions
(3IJUTfm2), so the cadence session may need the out-of-band merge
path until that lands.
