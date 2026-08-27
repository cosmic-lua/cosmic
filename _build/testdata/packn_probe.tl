-- The `_` prefix is required: an unused local is an error here, so
-- without it this probe would exit 1 under every checker and prove nothing.
local t = table.pack(1, "a")
local _n: integer = t.n
