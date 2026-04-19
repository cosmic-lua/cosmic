-- type declarations for cosmo.sandbox.fs
--
-- Raw cosmo.sandbox.fs surface — filesystem primitives for building a
-- mount-based box root. These wrap Linux mount(2) / pivot_root(2) /
-- umount2(2) with opinionated defaults. Intended to be called from a
-- child that has already CLONE_NEWNS'd its mount namespace.
--
-- cosmic does not yet ship a public wrapper over these; they surface
-- through cosmic.quicksand.Box as implementation details.

local record fs
  --- Directory mode 0755.
  MODE_DIR: integer
  --- Directory mode 0700.
  MODE_DIR_PRIV: integer
  --- File mode 0644.
  MODE_FILE: integer
  --- Directory mode 01777 (sticky tmp).
  MODE_TMP_STICKY: integer

  --- True if `path` exists (any file type).
  exists: function(path: string): boolean

  --- Mount an empty tmpfs at `path`. `mode` is the mount mode (defaults
  --- to MODE_TMP_STICKY). `size_bytes` is the tmpfs size= option; pass
  --- nil for kernel default.
  tmpfs: function(path: string, mode?: integer, size_bytes?: integer): boolean, any

  --- Mark the root mount private so subsequent mount ops don't leak
  --- back to the parent mount namespace. Call once per fresh mount ns.
  private_root: function(): boolean, any

  --- Bind-mount `src` onto `dst` read-write. Creates `dst` if missing.
  bind: function(src: string, dst: string): boolean, any

  --- Bind-mount `src` onto `dst` read-only.
  bind_ro: function(src: string, dst: string): boolean, any

  --- pivot_root(2) into `new_root`, then unmount the old root. The new
  --- root must itself be a mount point (typically a tmpfs) with a
  --- `/put_old` subdirectory for the pivot to use as its temporary
  --- anchor. Irreversible for the calling mount ns.
  pivot_to: function(new_root: string): boolean, any

  --- Like pivot_to(), but on failure terminate the calling process with
  --- `exit_code` instead of returning. Use in fork-then-pivot flows
  --- where a partial pivot would leave the child running in a half-
  --- unwound mount ns — safer to exit fast than to hand back to
  --- execvp.
  pivot_to_or_exit: function(new_root: string, exit_code: integer)
end

return fs
