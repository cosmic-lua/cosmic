-- Fixture stand-in; the check only greps for this file's existence
-- and the import chain, never compiles or runs it.
local function tokenize(s: string): {string}
  return {}
end
return {tokenize = tokenize}
