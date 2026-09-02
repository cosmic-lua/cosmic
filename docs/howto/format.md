# Format a file

steps for formatting Teal and Lua files with the built-in formatter, for a reader whose
file fails `--check fmt`.

## format one file

1. preview the formatted output on stdout.
2. rewrite the file in place when the preview looks right.

```bash
cosmic --format file.tl   # formatted output to stdout
cosmic --fix file.tl      # format in place
```

`--fix` prints nothing. it leaves a file that is already formatted unchanged.

## check a file

run the check to compare the file against its formatted form.

```bash
cosmic --check fmt file.tl
```

a match prints `Format check passed: file.tl` and exits 0. a mismatch prints the
first differing line on stderr and exits nonzero.

## read a mismatch report

a report names the file and line, then shows the line as it is and as the formatter
wants it.

```text
app.tl:1: format mismatch
  have: local x=1  (whitespace differs)
  want: local x = 1  (whitespace differs)
  hint: run 'cosmic --fix app.tl' to fix in place, or 'cosmic --format app.tl' to preview
```

1. read the `want` line. it is the formatter's output for that line.
2. run `cosmic --fix app.tl` to apply it, or edit the line by hand.
3. run `cosmic --check fmt app.tl` again. the report shows one line at a time, so a
   file with several mismatches needs the loop or one `--fix`.

when a shape rule is unclear, write the code and run `--fix`. the formatter is the
authority on shape. `cosmic --docs reference.conventions` lists the rules it applies.

## format a whole project

`--make fmt` checks every formattable file in the project. `--fix` rewrites them.

```bash
cosmic --make fmt          # check every file
cosmic --make fmt --fix    # rewrite every file that differs
cosmic --make fmt cosmic   # check one directory
```

`--fix` belongs to `fmt` alone. `--make ci` runs `fmt` as one of its stages. `--make
build` and `--make test` do not run it.
