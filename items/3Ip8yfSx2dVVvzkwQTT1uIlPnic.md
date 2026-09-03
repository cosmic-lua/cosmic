## Change

`tool/lua/test_definitions_help.lua` reduces every block to
fallible/infallible (`def_is_fallible`, line 130; the compare at line
284), which is why four help.txt blocks kept pre-bundling shapes through
#328/#331/#324 unnoticed. Add one more comparison, per block, per
source:

- `def_slot1(name)` (line 104) already returns the first `@return`'s
  type token. Strip a trailing `|nil` or `?` from it; when what remains
  starts with `unix.` (a class such as `unix.Pipe`, or an array such as
  `unix.IfAddr[]`), require that token to appear verbatim in the text
  of the block's FIRST `├─→`/`└─→` branch (plain `string.find` with
  `plain=true`; the branch text is already captured in
  `block.branches[k].shape`). Report a miss as
  `<source>:<line> unix.<name>: first branch reads "<shape>", definitions.lua declares slot 1 as <type>`.
  Do not compare primitive slot-1 types: `integer|nil clientfd, ...`
  blocks are the AGENTS.md named exception and their doc form is free.
- Rewrite the blocks the new rule refuses (measured below, 13 sites
  after the docs sibling lands; the awk that measured them is the
  puller's re-check). In `third_party/lua/cosmo/lunix.c` this means
  spelling the class instead of `:table` (`result:table` →
  `unix.WaitResult`, `previous:table` → `unix.SignalAction` /
  `unix.Itimerval`, `caps:table` → `unix.Caps`, `remaining:table` →
  `unix.SleepRemainder`, `termios:table` → `unix.Termios`, `uname`'s
  literal table → `unix.Uname`), fixing the one real drift the rule
  catches: `lunix.c:1988` documents `fstatfs` as `unix.Stat`,
  definitions declares `unix.Statfs`. `siocgifconf` in both sources
  spells the array literally; write `unix.IfAddr[]` there.
- Leave `floor` (lines 87-89) alone: block counts do not change.

## Evidence

Comparison today is count-level only (`sed -n 130,134p tool/lua/test_definitions_help.lua`):

    local function def_is_fallible(slot1)
      return slot1 == "nil" or slot1:match("|nil%f[^%w_]") ~= nil or
        slot1:match("^nil|") ~= nil or slot1:match("%?$") ~= nil

Sites the class-name rule refuses at origin/master, from an awk pairing
each `unix.<name>(` signature's first branch with `def_slot1` (help.txt
prefix two spaces, lunix.c prefix `// `; primitive slot-1 rows dropped):

    help.txt:2971  unix.pipe        doc=[reader:int, writer:int]              def=unix.Pipe|nil      (docs sibling)
    help.txt:3931  unix.siocgifconf doc=[{{name:str,ip:uint32,netmask:uint32}, ...}] def=unix.IfAddr[]|nil
    help.txt:4380  unix.setitimer   doc=[intervalsec:int, ...]                def=unix.Itimerval|nil (docs sibling)
    help.txt:4456  unix.getrlimit   doc=[soft:int, hard:int]                  def=unix.Rlimit|nil    (docs sibling)
    lunix.c:1033   unix.capget      doc=[caps:table]        def=unix.Caps|nil
    lunix.c:1315   unix.wait        doc=[result:table]      def=unix.WaitResult|nil
    lunix.c:1696   unix.nanosleep   doc=[remaining:table]   def=unix.SleepRemainder|nil
    lunix.c:1987   unix.fstatfs     doc=[unix.Stat]         def=unix.Statfs|nil
    lunix.c:2269   unix.siocgifconf doc=[{{name:str,...}]   def=unix.IfAddr[]|nil
    lunix.c:2686   unix.sigaction   doc=[previous:table]    def=unix.SignalAction|nil
    lunix.c:2797   unix.setitimer   doc=[previous:table]    def=unix.Itimerval|nil
    lunix.c:2985   unix.tcgetattr   doc=[termios:table]     def=unix.Termios|nil
    lunix.c:4377   unix.uname       doc=[{sysname:str, ...] def=unix.Uname|nil

Blocks already in the target form (`grep -n '├─→ unix\.' tool/net/help.txt`):

    3023: ├─→ unix.WaitResult    3479: ├─→ unix.F_UNLCK    4463: ├─→ unix.Rusage
    4818/4831: ├─→ unix.Stat     4844/4852: ├─→ unix.Statfs

plus named forms the substring rule also accepts (`grep -n ':unix\.' tool/net/help.txt`
finds `previous:unix.SignalAction` at 4275 and `bdt:unix.BrokenDownTime` at 4755/4781).

## Non-goals

Slot types past slot 1 and primitive slot-1 blocks stay uncompared: the
multi-value exception (`accept`, `getsockname`, `recvfrom`, …) is a
contract question for the annotation sibling, not a doc-gate question.
