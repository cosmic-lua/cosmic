# tar

 In-process tarball extraction, without a host `tar`.
 Unpacks a `.tar.gz` or plain `.tar` (gzip is detected from the
 header).

 It began as the stage pipeline's replacement for `tar -xzmf`
 and moved here when `--make` needed it too: `_make` unpacks pinned
 archives at runtime, the artifact floor is `cosmic/**`, and a module
 a built binary requires has to be inside it. Making it public is the
 honest consequence — position is the manifest — and "unpack a
 tarball" is a battery beside `cosmic.zip` and `cosmic.compress`
 rather than something peculiar to this repo's build.

 Writes through `cosmic.fs` rather than `_build`'s bootstrap-portable
 shim: that shim exists for a bootstrap predating the 2026.07
 error-convention release, and a module the artifact floor carries
 cannot depend on `_build` at all. The stage pipeline keeps its own
 shim for the paths that still run under the pinned binary.

 FAILURE CONTRACT: extraction is not atomic. Entries are written as
 they are read, so a failure partway through leaves `destdir` holding
 everything up to the refused entry. Extract into a fresh directory
 you own and treat it as scratch on failure -- the pin pipeline does
 exactly that, unpacking into a staging directory it removes. Making
 this atomic would mean staging and moving a whole tree, which is a
 larger change than the guarantee is worth while every caller already
 stages.

 Covers what pinned release tarballs actually contain — the ustar/pax layouts git archive and GNU tar emit:
 regular files, directories, symlinks, pax extended headers (path
 override), and GNU longnames. Anything else fails loudly. Modes are
 masked to 0777; mtimes and ownership are deliberately not restored
 (the stage rule's pledge does not promise utimensat/chown — the same
 policy `-m --no-same-owner` encodes for tar(1)).

## Types

### ExtractOptions

 Options for extract().

```teal
local record ExtractOptions
  --  Cap on the unpacked archive size in bytes (default 512 MiB): the
  --  bound the gunzip step enforces, so a corrupt or malicious archive
  --  cannot balloon memory (api-review #996: was a private constant
  --  while zip's cap was an option).
  max_archive_bytes: integer
end
```

### Header

```teal
local record Header
  name: string
  mode: integer
  size: integer
  typeflag: string
  linkname: string
end
```

### TarModule

```teal
local record TarModule
  extract: function(archive: string, destdir: string, opts?: ExtractOptions): boolean, string
end
```

## Functions

### extract

```teal
function extract(archive: string, destdir: string,
    opts?: ExtractOptions): boolean, string
```

 Extract a tarball into destdir. Gzip compression is detected from
 the file's magic bytes, so `.tar.gz` and plain `.tar` both extract
 with the same call (api-review #996: this used to gunzip
 unconditionally, so an uncompressed tarball was unreadable).

**Parameters:**

- `archive` (string) - Path to the .tar.gz or .tar file
- `destdir` (string) - Directory to extract into (created if needed)
- `opts` (ExtractOptions?) - max_archive_bytes: unpacked size cap

**Returns:**

- boolean - true when every entry was written
- string? - Error message on failure
