--- Octal digit strings parsed to permission-bit integers.
--- Internal submodule used by cosmic.fs.

local record OctalModule
  octal: function(digits: string): integer
end

--- Parse a run of octal digits into its integer value.
--- Infallible by design: the whole string must match `^[0-7]+$`, and
--- anything else — an empty string, a digit outside the base, any other
--- character — yields `0` rather than a nil the caller must narrow.
--- That contract fits every caller in practice: a mode argument is
--- either a hard-coded octal literal, which cannot fail, or a digit run
--- already extracted by a `[0-7]+` pattern, which cannot fail either. A
--- `0` result also matches what cosmic.tar already substitutes for an
--- absent mode field. Runtime numeric strings of unknown shape (hex,
--- decimal, `%d` output) want an honest fallible parser instead, not
--- this one.
--- @param digits string octal digits, e.g. "755"
--- @return integer the base-8 value, or 0 when digits is not all [0-7]
local function octal(digits: string): integer
  if not digits:match("^[0-7]+$") then return 0 end
  return tonumber(digits, 8) as integer -- cast: octal digits parse integral
end

local M: OctalModule = {
  octal = octal,
}

return M
