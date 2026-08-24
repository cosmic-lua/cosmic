## Goal
G5 — adversarial verification. A fuzz bound that outlives its defect
is a permanently blinded property: `_fuzz/json_fuzz_test.tl` stops
drawing floats at 2^53 to route around whilp/cosmopolitan#265, so the
whole `[2^53, 2^63)` band the encoder mishandles is unfuzzed. Retiring
the bound is what turns the upstream fix into restored coverage.

## Problem
`_fuzz/json_fuzz_test.tl` records the bound as a deliberate domain
limit with its own retirement condition (read 2026-08-24 at
`9bcb0f7d`):

    _fuzz/json_fuzz_test.tl:24-29
    -- Two domain bounds below are deliberate, not laziness:
    --
    -- 1. floats are bounded below 2^53 because the C encoder serializes a
    --    float in ~[1e17, 2^63) to an integer-shaped token the decoder
    --    integer-parses -- a real defect, filed as whilp/cosmopolitan#265;
    --    when its fix arrives via a cosmos pin bump, this bound comes off.

The float generator (`:55-60`) and the integer draw (`:16`) both hold
that ceiling.

## Direction
Blocked twice over, and both blockers are outside this item: the fix
must land in whilp/cosmopolitan (board item 3IHHK1Bj), and a cosmos
release carrying it must be pinned here (`3p/cosmos/cosmos_pin.tl`).
Once both hold: widen the float domain past 2^53, keep the ASCII
string bound (bound 2 is the module's contract, not a defect), delete
the retired half of the comment, and let the round-trip property carry
the guarantee the bound was standing in for. The type half matters as
much as the value half — after the fix an integral float decodes back
as a float, so the property should assert `math.type` and not only
value equality.

Sizing and the exact Acceptance commands are a refinement pass once
the pin exists; measure the new bound against the released encoder
rather than against this note.
