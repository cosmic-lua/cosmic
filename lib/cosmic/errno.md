# errno

 Error information from system calls.

 Failed `cosmo.unix` calls return `nil, err, errno`: a formatted string
 (`"open: ENOENT: No such file or directory"`) plus the numeric errno.
 This module provides the canonical formatter (`str`) that most
 `cosmic.*` wrappers use to add operation context, and helpers for
 programmatic errno handling (`is`, `code`), so error messages share
 one shape across the stdlib:

     local ok, err = unix.mkdir(path, mode)
     if not ok then return false, errno.str(err, "mkdir: " .. path) end
     -- -> "mkdir: /x: EACCES: Permission denied"
