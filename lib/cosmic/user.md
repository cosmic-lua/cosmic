# user

 User and group identity operations.
 Wraps cosmo.unix for user/group ID queries and modifications.

## Types

### UserModule

```teal
local record UserModule
  getuid: function(): number
  getgid: function(): number
  geteuid: function(): number
  getegid: function(): number
  getlogin: function(): string
  setuid: function(uid: number): boolean
  setgid: function(gid: number): boolean
  setfsuid: function(uid: number): boolean
  setresuid: function(real: number, effective: number, saved: number): boolean
  setresgid: function(real: number, effective: number, saved: number): boolean
  umask: function(newmask: number): number
  chroot: function(path: string): boolean
end
```

## Functions

### getuid

```teal
function getuid(): number
```

 Get the real user ID of the calling process.

**Returns:**

- number - The real user ID

### getgid

```teal
function getgid(): number
```

 Get the real group ID of the calling process.
 On Windows this is polyfilled as getuid().

**Returns:**

- number - The real group ID

### geteuid

```teal
function geteuid(): number
```

 Get the effective user ID of the calling process.
 For example, if your binary is setuid, getuid() returns the uid of the user
 running the program, while geteuid() returns the uid of the file owner.
 On Windows this is polyfilled as getuid().

**Returns:**

- number - The effective user ID

### getegid

```teal
function getegid(): number
```

 Get the effective group ID of the calling process.
 On Windows this is polyfilled as getuid().

**Returns:**

- number - The effective group ID

### getlogin

```teal
function getlogin(): string
```

 Get the login name of the user running the process.
 Returns nil if the login name cannot be determined.

**Returns:**

- string - The login name, or nil on failure

### setuid

```teal
function setuid(uid: number): boolean
```

 Set the user ID of the calling process.
 Returns ENOSYS on Windows NT if uid isn't getuid().

**Parameters:**

- `uid` (number) - The user ID to set

**Returns:**

- boolean - True on success, nil on failure

### setgid

```teal
function setgid(gid: number): boolean
```

 Set the group ID of the calling process.
 Returns ENOSYS on Windows NT if gid isn't getgid().

**Parameters:**

- `gid` (number) - The group ID to set

**Returns:**

- boolean - True on success, nil on failure

### setfsuid

```teal
function setfsuid(uid: number): boolean
```

 Set the filesystem user ID.

**Parameters:**

- `uid` (number) - The filesystem user ID to set

**Returns:**

- boolean - True on success, nil on failure

### setresuid

```teal
function setresuid(real: number, effective: number, saved: number): boolean
```

 Set real, effective, and saved user IDs.
 Pass -1 for any argument to leave that ID unchanged.

**Parameters:**

- `real` (number) - The real user ID to set (-1 to leave unchanged)
- `effective` (number) - The effective user ID to set (-1 to leave unchanged)
- `saved` (number) - The saved user ID to set (-1 to leave unchanged)

**Returns:**

- boolean - True on success, nil on failure

### setresgid

```teal
function setresgid(real: number, effective: number, saved: number): boolean
```

 Set real, effective, and saved group IDs.
 Pass -1 for any argument to leave that ID unchanged.

**Parameters:**

- `real` (number) - The real group ID to set (-1 to leave unchanged)
- `effective` (number) - The effective group ID to set (-1 to leave unchanged)
- `saved` (number) - The saved group ID to set (-1 to leave unchanged)

**Returns:**

- boolean - True on success, nil on failure

### umask

```teal
function umask(newmask: number): number
```

 Set the file mode creation mask.
 The umask is used by open(), mkdir(), etc. to modify the permissions
 of newly created files and directories.

**Parameters:**

- `newmask` (number) - The new file mode creation mask

**Returns:**

- number - The previous umask value

### chroot

```teal
function chroot(path: string): boolean
```

 Change the root directory.
 Changes the root directory of the calling process to the specified path.
 This call requires appropriate privileges (typically root).

**Parameters:**

- `path` (string) - The new root directory path

**Returns:**

- boolean - True on success, nil on failure
