--- The right answer to shop-git-commit, from cosmic.git: text.tl alone committed with the message asked for.
local Git = require("cosmic.git")

local repo = assert(Git.open("."))
assert(repo:add({ "text.tl" }))
assert(repo:commit({ message = "text: note the trim rule" }))
