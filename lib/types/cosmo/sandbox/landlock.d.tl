-- type declarations for cosmo.sandbox.landlock
--
-- Raw cosmo.sandbox.landlock surface. cosmic.landlock wraps this with
-- Teal records for Rule / RestrictOpts and cosmic's value,string error
-- convention. Callers should prefer cosmic.landlock over these.

local record landlock
  EXECUTE: integer
  WRITE_FILE: integer
  READ_FILE: integer
  READ_DIR: integer
  REMOVE_DIR: integer
  REMOVE_FILE: integer
  MAKE_CHAR: integer
  MAKE_DIR: integer
  MAKE_REG: integer
  MAKE_SOCK: integer
  MAKE_FIFO: integer
  MAKE_BLOCK: integer
  MAKE_SYM: integer
  REFER: integer
  TRUNCATE: integer
  READ: integer
  EXEC: integer
  WRITE: integer
  RW: integer
  ALL: integer

  --- Returns the kernel's supported landlock ABI (>= 1 when enabled).
  --- Returns nil + error on ENOSYS / non-Linux.
  abi: function(): integer, any

  --- Convenience: true when abi() >= 1.
  available: function(): boolean

  --- Apply a path allowlist to the current thread. Irreversible.
  --- opts is a plain table: { handled, rules = {{path, access}, ...},
  --- no_new_privs = true }.
  restrict: function(opts: any): boolean, string
end

return landlock
