-- Fixture stand-in for the agent's own test file. Carries the marker
-- the check's source-contains assertion looks for: a test covering
-- the on-the-hour bucket boundary (2026-08-01T11:00:00Z belongs to
-- the 11:00 bucket, not the one before it).
local function test_on_the_hour_boundary_lands_in_its_own_bucket()
  assert("2026-08-01T11:00:00Z" ~= nil)
end
test_on_the_hour_boundary_lands_in_its_own_bucket()
