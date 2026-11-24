--- `cosmic archive list|extract|create`: reads and writes the zip and
--- tar files that a release ships, with no script. See also
--- `cosmic json`.
---
--- Commands:
---
--- - `list <file>|-` prints one entry a line: path (a symlink's
---   `path -> target`), size, mode in octal, and type, separated by
---   tabs, with control bytes escaped. With `--json`, it prints an array
---   of objects (path, type, size, mode as the same octal string, mtime,
---   and a symlink's linkpath) for `cosmic json`.
--- - `extract <file>|- [-C dir] [member...]` unpacks into dir (default
---   the working directory) and prints the paths it wrote. A member is a
---   path in the archive, and takes what is under it.
--- - `create <out> <path>...` packs the paths and what is under them,
---   sorted by name ([`Archive.create`]).
---
--- Formats:
---
--- - `extract` reads the format from the file's first bytes, not its
---   name: zip, tar, or tar under gzip, xz, bzip2 or zstd.
--- - `create` picks the format from the extension of out: `.zip`;
---   `.tar.gz` or `.tgz`; `.tar.xz` or `.txz`; `.tar.bz2`, `.tbz2` or
---   `.tbz`; `.tar.zst` or `.tzst`; or `.tar`.
---
--- Extracting safely ([`Archive.extract`]):
---
--- - An absolute path, a `..`, or a symlink out of the target is
---   refused. Replacing an existing path is refused unless `--force` is
---   given.
--- - Only that refusal and a member not in the archive write nothing.
--- - An unsafe entry, or a file past the default size limits (1 GiB a
---   file, 8 GiB in all), stops the extraction. The entries before it
---   stay written, and the refused file itself is not left.
---
--- Creating:
---
--- - Paths must be relative and stay under the working directory.
--- - A fifo, socket or device is refused, and named, wherever it is
---   found.
--- - `--reproducible` fixes every modification time (tar 0, zip 1980),
---   so the same tree packs to the same bytes. File modes are kept, not
---   normalised.
--- - A symlink is stored as a link in both formats. A zip tool that
---   ignores Unix attributes extracts the target's text as a file.
---
--- It prints no summary, because its output is data for a pipe. It
--- exits 0 when done, and 1 for a member or a path that is not there,
--- or files it would overwrite. It exits 2 for a command line, an
--- archive it cannot read, or one it refuses to unpack.
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
  about = "list, extract or create tar and zip files",
  usage = "<create|extract|list> ...",
  examples = {
    { line = "list release.tar.gz", about = "list what an archive holds" },
    { line = "extract release.zip -C out", about = "unpack it into out" },
    { line = "create out.tar.gz dir --reproducible", about = "pack a directory" },
  },
  subcommands = {
    list = {
      about = "what an archive holds",
      usage = "[--json] <file>|-",
      spec = { ["--json"] = { about = "print an array of objects, not lines" } },
    },
    extract = {
      about = "unpack an archive, or the members named",
      usage = "[-C <dir>] [--force] <file>|- [<member>...]",
      spec = {
        ["-C"] = { value = "dir", about = "unpack into dir", default = "." },
        ["--force"] = { about = "replace existing files" },
      },
    },
    create = {
      about = "pack paths into an archive of the kind its name says",
      usage = "[--reproducible] <out.tar.gz|out.tgz|out.tar.xz|out.txz|out.tar.bz2|out.tbz2|out.tbz|out.tar.zst|" ..
        "out.tzst|out.tar|out.zip> <path>...",
      spec = { ["--reproducible"] = { about = "fix every modification time, so the same tree packs alike" } },
    },
  },
}

return command
