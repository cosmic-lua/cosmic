# user

 User and group identity operations.
 Wraps cosmo.unix for user/group ID queries and modifications.

## Types

### UserModule

```teal
local record UserModule
  getuid: function(): integer
  getgid: function(): integer
  geteuid: function(): integer
  getegid: function(): integer
  getlogin: function(): string | nil, string
  setuid: function(uid: integer): boolean, string
  setgid: function(gid: integer): boolean, string
  setfsuid: function(uid: integer): boolean, string
  setresuid: function(real: integer, effective: integer, saved: integer): boolean, string
  setresgid: function(real: integer, effective: integer, saved: integer): boolean, string
  umask: function(newmask: integer): integer
  chroot: function(path: string): boolean, string
end
```

## Functions

### getuid

```teal
function getuid(): integer
```

 Get the real user ID of the calling process.

**Returns:**

- integer - The real user ID

### getgid

```teal
function getgid(): integer
```

 Get the real group ID of the calling process.
 On Windows this is polyfilled as getuid().

**Returns:**

- integer - The real group ID

### geteuid

```teal
function geteuid(): integer
```

 Get the effective user ID of the calling process.
 For example, if your binary is setuid, getuid() returns the uid of the user
 running the program, while geteuid() returns the uid of the file owner.
 On Windows this is polyfilled as getuid().

**Returns:**

- integer - The effective user ID

### getegid

```teal
function getegid(): integer
```

 Get the effective group ID of the calling process.
 On Windows this is polyfilled as getuid().

**Returns:**

- integer - The effective group ID

### getlogin

```teal
function getlogin(): string | nil, string
```

 Get the login name of the user running the process.

**Returns:**

- string - | nil The login name, or nil on failure
- string? - Error message if the login name cannot be determined

### setuid

```teal
function setuid(uid: integer): boolean, string
```

 Set the user ID of the calling process.
 Returns ENOSYS on Windows NT if uid isn't getuid().

**Parameters:**

- `uid` (integer) - The user ID to set

**Returns:**

- boolean - True on success
- string? - Error message on failure

### setgid

```teal
function setgid(gid: integer): boolean, string
```

 Set the group ID of the calling process.
 Returns ENOSYS on Windows NT if gid isn't getgid().

**Parameters:**

- `gid` (integer) - The group ID to set

**Returns:**

- boolean - True on success
- string? - Error message on failure

### setfsuid

```teal
function setfsuid(uid: integer): boolean, string
```

 Set the filesystem user ID.

**Parameters:**

- `uid` (integer) - The filesystem user ID to set

**Returns:**

- boolean - True on success
- string? - Error message on failure

### setresuid

```teal
function setresuid(real: integer, effective: integer, saved: integer): boolean, string
```

 Set real, effective, and saved user IDs.
 Pass -1 for any argument to leave that ID unchanged.

**Parameters:**

- `real` (integer) - The real user ID to set (-1 to leave unchanged)
- `effective` (integer) - The effective user ID to set (-1 to leave unchanged)
- `saved` (integer) - The saved user ID to set (-1 to leave unchanged)

**Returns:**

- boolean - True on success
- string? - Error message on failure

### setresgid

```teal
function setresgid(real: integer, effective: integer, saved: integer): boolean, string
```

 Set real, effective, and saved group IDs.
 Pass -1 for any argument to leave that ID unchanged.

**Parameters:**

- `real` (integer) - The real group ID to set (-1 to leave unchanged)
- `effective` (integer) - The effective group ID to set (-1 to leave unchanged)
- `saved` (integer) - The saved group ID to set (-1 to leave unchanged)

**Returns:**

- boolean - True on success
- string? - Error message on failure

### umask

```teal
function umask(newmask: integer): integer
```

 Set the file mode creation mask.
 The umask is used by open(), mkdir(), etc. to modify the permissions
 of newly created files and directories.

**Parameters:**

- `newmask` (integer) - The new file mode creation mask

**Returns:**

- integer - The previous umask value

### chroot

```teal
function chroot(path: string): boolean, string
```

 Change the root directory.
 Changes the root directory of the calling process to the specified path.
 This call requires appropriate privileges (typically root).

**Parameters:**

- `path` (string) - The new root directory path

**Returns:**

- boolean - True on success
- string? - Error message on failure
