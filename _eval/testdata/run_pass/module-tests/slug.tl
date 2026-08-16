-- Fixture stand-in for the agent's slug module source. Not executed
-- by the check (the check only greps for its existence); the built
-- o/bin/slug stub carries the actual behavior the check exercises.
local function slugify(s: string): string
  return s
end
return {slugify = slugify}
