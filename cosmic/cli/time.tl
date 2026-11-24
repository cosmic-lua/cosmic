--- `cosmic time <now|convert|between|add> ...`: the clock and calendar
--- the same on every host, where GNU and BSD `date` differ. Zones are
--- the IANA names of the tz database the binary carries. `now` prints
--- the time (RFC 3339 in the host's zone, or `--zone`; `--format`
--- rfc3339, date, http or epoch); `convert <time>` writes a time in
--- `--to`'s zone; `between <a> <b>` is `1y2mo3d4h5m6s` from a to b, or
--- with `--days`, `--months` or `--seconds` one number; `add <time>
--- <duration>` moves a time by `1y2mo3d4h5m6s` (negative with a leading
--- `-`, which follows the time: `add 2026-03-31 -1d`). A time is RFC 3339
--- (`2026-09-25T04:09:21Z`, with an optional `[Zone]` suffix), a date,
--- a local `2026-09-25T04:09[:21]` read in `--from` (or `--zone`), or
--- `@<epoch seconds>`. A local time a zone skipped (a spring-forward
--- gap) or has twice (an overlap) is read as `--disambiguate` says:
--- "compatible" by default, a gap landing after the gap and an overlap
--- taking the earlier moment; "earlier", "later" or "reject" (which fails)
--- choose otherwise. `add` moves years and months first, keeping the
--- day of the month, then days on the calendar, then hours, minutes and
--- seconds exactly; a day the month lacks (January 31 plus 1mo) is an
--- error, exit 1, unless `--clamp` takes the month's last day. `between`'s
--- duration reads months as `--clamp` does, on `--zone`'s calendar or the
--- first time's own; `--seconds` is elapsed time.
--- `--json` prints one record: epoch, rfc3339, zone, offset and the
--- civil fields. It prints no summary, as `json` does: exit 0
--- done, 1 an `add` with no result, 2 a command line, time, duration
--- or zone it cannot read
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
  about = "show, convert and calculate with times",
  usage = "<command> ...",
  examples = {
    { line = "now --zone Asia/Tokyo", about = "the time in a zone" },
    { line = "convert 2026-03-08T12:00Z --to America/New_York", about = "convert a time" },
    { line = "between 2026-01-01 2026-09-28 --days", about = "count the days between two dates" },
  },
  spec = {
    ["--zone"] = { value = "IANA", about = "the zone to show, or to run the calendar in (default: the host's)" },
    ["--from"] = { value = "IANA", about = "the zone a local time is read in (default: the host's)" },
    ["--to"] = { value = "IANA", about = "the zone to write in (default: the host's)" },
    ["--format"] = { value = "form", about = "rfc3339 (default), date, http or epoch" },
    ["--days"] = { about = "between: whole calendar days" },
    ["--months"] = { about = "between: whole calendar months" },
    ["--seconds"] = { about = "between: whole seconds" },
    ["--clamp"] = { about = "add: a day the month lacks takes its last day, not an error" },
    ["--disambiguate"] = { value = "how", about = "a local time in a gap or overlap: " ..
        "compatible (default), earlier, later or reject" },
    ["--json"] = { about = "print a record: epoch, rfc3339, zone, offset and the civil fields" },
  },
}

return command
