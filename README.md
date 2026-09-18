# cosmic

cosmic is a runtime for self-contained command-line software: one file
holds the language, the compiler, the standard library, and the build.
Programs it builds ship the same way, one executable, carrying a
database of compiled modules rather than reading files at run time.

## build

```text
bin/zig build cores boot
```

## run a file

```sh
echo 'print("hello from the database")' > hello.tl
cosmic hello.tl
```

```output
hello from the database
```

## design

what cosmic is for and how it is built lives in
[doc/design.md](doc/design.md); how this documentation works, and what
its examples promise, is [doc/meta.md](doc/meta.md).
