-- type declarations for cosmo.re
-- GENERATED from cosmopolitan's definitions.lua by lib/types/gentype.tl.
-- Do not edit by hand. Regenerate with: bin/make regen-types

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
  search: function(self: Regex, str: string, flags?: number): string, string...
end

local record re
  type Errno = Errno
  type Regex = Regex

  --- No match
  NOMATCH: number
  --- Invalid regex
  BADPAT: number
  --- Unknown collating element
  ECOLLATE: number
  --- Unknown character class name
  ECTYPE: number
  --- Trailing backslash
  EESCAPE: number
  --- Invalid back reference
  ESUBREG: number
  --- Missing ]
  EBRACK: number
  --- Missing )
  EPAREN: number
  --- Missing }
  EBRACE: number
  --- Invalid contents of {}
  BADBR: number
  --- Invalid character range.
  ERANGE: number
  --- Out of memory
  ESPACE: number
  --- Repetition not preceded by valid expression
  BADRPT: number
  --- Use this flag if you prefer the default POSIX regex syntax.
  --- We use extended regex notation by default. For example, an extended regular
  --- expression for matching an IP address might look like
  --- `([0-9]*)\.([0-9]*)\.([0-9]*)\.([0-9]*)` whereas with basic syntax it would
  --- look like `\([0-9]*\)\.\([0-9]*\)\.\([0-9]*\)\.\([0-9]*\)`.
  --- This flag may only be used with `re.compile` and `re.search`.
  BASIC: number
  --- Use this flag if you prefer the default POSIX regex syntax. We use extended
  ---  regex notation by default. For example, an extended regular expression for
  --- matching an IP address might look like `([0-9]*)\.([0-9]*)\.([0-9]*)\.([0-9]*)`
  --- whereas with basic syntax it would look like `\([0-9]*\)\.\([0-9]*\)\.\([0-9]*\)\.\([0-9]*\)`.
  --- This flag may only be used with `re.compile` and `re.search`.
  ICASE: number
  --- Use this flag to change the handling of NEWLINE (\x0a) characters. When this
  --- flag is set, (1) a NEWLINE shall not be matched by a "." or any form of a
  --- non-matching list, (2) a "^" shall match the zero-length string immediately
  --- after a NEWLINE (regardless of `re.NOTBOL`), and (3) a "$" shall match the
  --- zero-length string immediately before a NEWLINE (regardless of `re.NOTEOL`).
  NEWLINE: number
  --- Causes `re.search` to only report success and failure. This is reported via
  --- the API by returning empty string for success. This flag may only be used
  --- ` with `re.compile` and `re.search`.
  NOSUB: number
  --- The first character of the string pointed to by string is not the beginning
  --- of the line. This flag may only be used with `re.search` and `regex_t*:search`.
  NOTBOL: number
  --- The last character of the string pointed to by string is not the end of the
  --- line. This flag may only be used with `re.search` and `regex_t*:search`.
  NOTEOL: number

  --- Searches for regular expression match in text.
  --- This is a shorthand notation roughly equivalent to:
  ---     preg = re.compile(regex)
  ---     patt = preg:search(re, text)
  --- - `re.BASIC`
  --- - `re.ICASE`
  --- - `re.NEWLINE`
  --- - `re.NOSUB`
  --- - `re.NOTBOL`
  --- - `re.NOTEOL`
  --- This has exponential complexity. Please use `re.compile()` to compile your regular expressions once from `/.init.lua`. This API exists for convenience. This isn't recommended for prod.
  --- This uses POSIX extended syntax by default.
  search: function(regex: string, text: string, flags?: number): string, string...
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
  compile: function(regex: string, flags?: number): Regex, Errno
end

return re
