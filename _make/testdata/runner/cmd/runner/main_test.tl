-- Runner-mode fixture: `test_one` is defined and never self-called,
-- so the D29 seam's generated tail is what makes it a used local
-- rather than an uncalled-local warning under a strict check.
local function test_one()
  assert(1 == 1)
end
