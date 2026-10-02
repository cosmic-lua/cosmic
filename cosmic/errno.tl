--- The message text of the few errno failures a program using cosmic's
--- filesystem calls is likely to meet, each with what to check when it
--- happens. A failing call returns `nil, message, errno`, and a wrapper
--- such as `Fs` joins the path and that message into one string
--- (`path: No such file or directory`). The message is the same on every
--- OS ([`sys.errno_message`] answers it). `cosmic docs ENOENT`, or any
--- field below, finds this page.
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

-- TODO: an uncaught error whose message matches one of these finds no
-- guidance: [`build/analyzer.tl`]'s `catalog_of` records a module's
-- literal failures, not these fields, so no catalog row holds them.
-- Have it record each field's value as a row joined to its doc
-- comment; [`Errors.guidance`] would then find it beneath an uncaught
-- error whose own message matches.

-- Each field's own value is the exact message text it stands for, not
-- a description of it: what an uncaught error's message carries, and
-- what [`Errors.guidance`] would match once the TODO above is done.
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
