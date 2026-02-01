-- type declarations for cosmo.re

local record Errno
  --- - `unix.NOMATCH` No match
  --- - `unix.BADPAT` Invalid regex
  --- - `unix.ECOLLATE` Unknown collating element
  --- - `unix.ECTYPE` Unknown character class name
  --- - `unix.EESCAPE` Trailing backslash
  --- - `unix.ESUBREG` Invalid back reference
  --- - `unix.EBRACK` Missing `]`
  --- - `unix.EPAREN` Missing `)`
  --- - `unix.EBRACE` Missing `}`
  --- - `unix.BADBR` Invalid contents of `{}`
  --- - `unix.ERANGE` Invalid character range.
  --- - `unix.ESPACE` Out of memory
  --- - `unix.BADRPT` Repetition not preceded by valid expression
  errno: function(self: Errno): number
  doc: function(self: Errno): string
  --- Delegates to `re.Errno:doc()`.
  __tostring: function(self: Errno): string
end

local record Regex
  --- Executes precompiled regular expression.
  --- Returns nothing (`nil`) if the pattern doesn't match anything. Otherwise it
  --- pushes the matched substring and any parenthesis-captured values too. Flags may
  --- contain `re.NOTBOL` or `re.NOTEOL` to indicate whether or not text should be
  --- considered at the start and/or end of a line.
  --- - `re.NOTBOL`
  --- - `re.NOTEOL`
  --- This has an O(𝑛) cost.
  search: function(self: Regex, str: string, flags?: number): string
end

local record re
  -- Error codes
  NOMATCH: number
  BADPAT: number
  ECOLLATE: number
  ECTYPE: number
  EESCAPE: number
  ESUBREG: number
  EBRACK: number
  EPAREN: number

  -- Compile flags
  BASIC: number    -- Use basic (obsolete) regex syntax instead of extended
  ICASE: number    -- Case-insensitive matching
  NEWLINE: number  -- Treat newline as special (affects ^ and $)
  NOSUB: number    -- Report only success/failure, not match position

  -- Search flags
  NOTBOL: number   -- First character is not at beginning of line
  NOTEOL: number   -- Last character is not at end of line

  --- Searches for regular expression match in text.
  --- This is a shorthand notation roughly equivalent to:
  --- preg = re.compile(regex)
  --- patt = preg:search(re, text)
  --- - `re.BASIC`
  --- - `re.ICASE`
  --- - `re.NEWLINE`
  --- - `re.NOSUB`
  --- - `re.NOTBOL`
  --- - `re.NOTEOL`
  --- This has exponential complexity. Please use `re.compile()` to compile your regular expressions once from `/.init.lua`. This API exists for convenience. This isn't recommended for prod.
  --- This uses POSIX extended syntax by default.
  search: function(regex: string, text: string, flags?: number): string
  --- Compiles regular expression.
  --- - `re.BASIC`
  --- - `re.ICASE`
  --- - `re.NEWLINE`
  --- - `re.NOSUB`
  --- This has an O(2^𝑛) cost. Consider compiling regular expressions once
  --- from your `/.init.lua` file.
  --- If regex is an untrusted user value, then `unix.setrlimit` should be
  --- used to impose cpu and memory quotas for security.
  --- This uses POSIX extended syntax by default.
  --- Returns nil and an Errno on failure.
  compile: function(regex: string, flags?: number): Regex, Errno
end

return re

