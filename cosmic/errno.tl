--- Guidance for the handful of errno messages cosmic's own syscalls
--- can plausibly raise. `core/fail.h`'s `cosmic_fail` returns `nil,
--- message, errno`, the message core/errnos.c's table gives -- musl's
--- words, the same on every OS, which `sys.errno_message` answers --
--- and a stdlib wrapper like `cosmic/fs.tl`'s `path .. ": " .. trouble`
--- stitches that literal text straight into what a program sees.
--- `cosmic docs ENOENT` (or any field below) finds this doc comment
--- directly.
---
--- TODO: an uncaught error whose message matches one of these finds no
--- guidance: `build/analyzer.tl`'s `catalog_of` records a module's
--- literal failures, not these fields, so no catalog row holds them.
--- Have it record each field's value as a row joined to its doc
--- comment; `Errors.guidance` would then find it
--- beneath an uncaught error whose own message matches.
local record Errno
  --- the path does not exist -- check it is spelled right, and that
  --- every parent directory already exists; cosmic.fs creates no
  --- parent directories on its own
  ENOENT: string
  --- the process does not have permission for this path -- check its
  --- ownership and mode, cosmic.fs.stat's own fields
  EACCES: string
  --- something is already at this path -- cosmic.fs.remove it first,
  --- or use a call that tolerates an existing target
  EEXIST: string
  --- a path segment that should be a directory is a plain file
  --- instead -- check every component up to the last
  ENOTDIR: string
  --- the path names a directory where a file was expected -- reading
  --- or writing needs a file path, not a directory
  EISDIR: string
  --- the filesystem holding this path is full
  ENOSPC: string
  --- this process already has too many files open -- close ones no
  --- longer needed before opening more
  EMFILE: string
end

--- Each field's own value is the exact message text it stands
--- for -- the thing `Errors.guidance` actually matches an uncaught
--- error's message against, not a description of it.
local errno: Errno = {
  ENOENT = "No such file or directory",
  EACCES = "Permission denied",
  EEXIST = "File exists",
  ENOTDIR = "Not a directory",
  EISDIR = "Is a directory",
  ENOSPC = "No space left on device",
  EMFILE = "No file descriptors available",
}

return errno
