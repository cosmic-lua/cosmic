--- `cosmic rand <gamma|int|normal|pick|shuffle|token|uuid> ...`: prints
--- an id, a token, a number, a shuffled list, or a normal or gamma draw,
--- with no script to write.
---
--- - `uuid [--v4|--v7] [-n N]` prints N UUIDs (default one, version 4).
---   Version 7 (RFC 9562) starts with the millisecond clock, then a 12-bit
---   counter, then entropy, so one run's values sort in the order they
---   were drawn. The counter is the RFC's method 3 (section 6.2): the
---   clock's fraction of the millisecond, increased by one where a draw
---   would not sort after the last. A clock that steps far back leaves
---   the values ahead of real time for the rest of the run.
--- - `token [--bytes N] [--hex|--base64url]` prints N random bytes
---   (default 32, at most 1048576) as base64url without padding, or as hex.
--- - `int [-n N] <lo> <hi>` prints N integers (default one), uniform over
---   lo..hi inclusive. It draws by rejection, so no value is more likely
---   than another. The bounds may be negative (`int -5 5`); lo above hi is
---   refused.
--- - `pick [-n N] [file|-]` prints N distinct lines, and
---   `shuffle [file|-]` prints all of them, in an order drawn by
---   Fisher-Yates. A line ends at a newline, and a carriage return before
---   the newline is dropped (CRLF input reads as LF). An empty input has
---   no lines. Asking `pick` for more lines than there are is refused
---   (exit 2), and nothing is printed.
--- - `normal [-n N] [--mean M] [--stddev SD]` prints N draws (default one)
---   from the normal distribution: mean 0 and standard deviation 1 unless
---   given. SD may be 0, but not negative.
--- - `gamma [-n N] --shape K [--scale T]` prints N draws from the gamma
---   distribution of shape K, which is required, and scale T (default 1).
---   The mean is K * T, and both must be above 0.
---
--- `-n` is at most 10000000; more is refused (exit 2). Ten million UUIDs
--- take about 40 seconds, and ten million integers about 15.
---
--- A parameter is a finite decimal number (`-5`, `.5`, `1e-3`). `inf`,
--- `nan`, hexadecimal and a value too large for a double are refused
--- (exit 2). Each float prints on a line as `%.17g`, which reads back as
--- the same double. A gamma draw can print 0 for a tiny shape, and a draw
--- can print inf where it overflows.
---
--- Randomness:
---
--- Everything secret-grade comes from the operating system's entropy
--- source ([`Rand.entropy`]), never from a seeded generator: uuid, token,
--- and the other commands without `--seed`. `--seed N` (int, pick,
--- shuffle, normal, gamma) draws from `Rand.new(N)` instead, so a test or
--- a script can replay it. A float draw agrees across targets only as far
--- as their `log` and `pow` do. Seeded output is NOT secret, and `--seed`
--- is refused with uuid and token.
---
--- Its standard output is data, and it prints no summary. It exits 0 when
--- it printed, and 1 when the entropy source failed. It exits 2 for a
--- command line, a file or a request that it refuses, or a failed write
--- to standard output.
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
  about = "uuids, tokens, integers, picks and draws",
  usage = "<gamma|int|normal|pick|shuffle|token|uuid> ...",
  examples = {
    { line = "uuid", about = "a random UUID" },
    { line = "token", about = "a 32-byte token" },
    { line = "int 1 6", about = "roll a die" },
  },
  subcommands = {
    uuid = {
      about = "random UUIDs",
      spec = {
        ["--v4"] = { about = "version 4, random (the default)" },
        ["--v7"] = { about = "version 7, time-ordered within a run" },
        ["-n"] = { value = "n", about = "how many", integer = { min = 1, max = 10000000 }, default = "1" },
        ["--seed"] = { value = "n", about = "refused: the output is secret" },
      },
    },
    token = {
      about = "a random token",
      spec = {
        ["--bytes"] = { value = "n", about = "bytes of entropy", integer = { min = 1, max = 1048576 }, default = "32" },
        ["--hex"] = { about = "lowercase hex" },
        ["--base64url"] = { about = "unpadded base64url (the default)" },
        ["--seed"] = { value = "n", about = "refused: the output is secret" },
      },
    },
    int = {
      about = "integers, uniform over lo..hi inclusive",
      usage = "[options] [--] <lo> <hi>",
      spec = {
        ["-n"] = { value = "n", about = "how many", integer = { min = 1, max = 10000000 }, default = "1" },
        ["--seed"] = { value = "n", about = "replayable, NOT secret", integer = {} },
      },
    },
    pick = {
      about = "distinct lines of a file",
      usage = "[options] [file|-]",
      spec = {
        ["-n"] = { value = "n", about = "how many", integer = { min = 1, max = 10000000 }, default = "1" },
        ["--seed"] = { value = "n", about = "replayable, NOT secret", integer = {} },
      },
    },
    shuffle = {
      about = "every line of a file, shuffled",
      usage = "[options] [file|-]",
      spec = {
        ["--seed"] = { value = "n", about = "replayable, NOT secret", integer = {} },
      },
    },
    normal = {
      about = "draws from the normal distribution",
      spec = {
        ["-n"] = { value = "n", about = "how many", integer = { min = 1, max = 10000000 }, default = "1" },
        ["--seed"] = { value = "n", about = "replayable, NOT secret", integer = {} },
        ["--mean"] = { value = "m", about = "the mean", default = "0" },
        ["--stddev"] = { value = "sd", about = "the standard deviation, not negative", default = "1" },
      },
    },
    gamma = {
      about = "draws from the gamma distribution",
      spec = {
        ["-n"] = { value = "n", about = "how many", integer = { min = 1, max = 10000000 }, default = "1" },
        ["--seed"] = { value = "n", about = "replayable, NOT secret", integer = {} },
        ["--shape"] = { value = "k", about = "the shape, above 0", required = true },
        ["--scale"] = { value = "t", about = "the scale, above 0", default = "1" },
      },
    },
  },
}

return command
