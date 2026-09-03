## Change

Doc-only. Bring three prose copies of contracts that changed in #319,
#324, #328, #331, #340 back to what `tool/net/definitions.lua` declares.

- `tool/net/help.txt`: rewrite the success branch of four shape blocks
  to the class the annotation names, using the form `unix.wait`'s block
  already has (`help.txt:3023`, `├─→ unix.WaitResult`):
  `:2972` pipe → `├─→ unix.Pipe`; `:4457` getrlimit → `├─→ unix.Rlimit`;
  `:4381` setitimer → `├─→ unix.Itimerval`; `:5185-5186` Dir:read →
  keep the 4-value line, then `├─→ nil` (end of stream) and
  `└─→ nil, error:str, errno:int`, mirroring `lunix.c:4234-4237`. Update
  each block's prose the same way `unix.wait`'s was (field names
  `reader`/`writer`, `soft`/`hard`, `intervalsec`… and the pipe example
  at the `unix.pipe` entry if help.txt carries one).
- `tool/net/demo/redbean.lua:264-269`: the three `m,a,b,c,d =
  re.search(...)` / `pat:search(s)` lines read the pre-#319 shape;
  `re.search` now returns one `re.SearchMatch`. Bind `local r =
  ...` and render `r.match` and `r.captures[1..4]` in the `<dl>` that
  follows (`:275-290` prints `m`, `a`, `b`, `c` with `%q`); keep the
  `Write` line at `:272` that quotes the call in sync.
- `AGENTS.md:96-101`: the named-exception paragraph still cites
  `unix.wait` (`pid, wstatus, rusage`); #340 made it return one
  `unix.WaitResult`. Drop it from the list, leaving `unix.accept` and
  `Fetch`/`FetchStream`; do not add new members here (that is the
  sibling that fixes their annotations).

The gate `tool/lua/test_definitions_help.lua` compares fallibility
only, so nothing fails today and nothing will fail if a block is
missed; the sibling `help-gate-slot1-type` adds the slot-1 comparison
and is blocked on this item because it refuses the current text.

## Evidence

`sed -n '2971,2973p;4380,4382p;4456,4458p;5184,5186p' tool/net/help.txt`:

    unix.pipe([flags:int])        ├─→ reader:int, writer:int
    unix.setitimer(which[, ...])  ├─→ intervalsec:int, intervalns:int, valuesec:int, valuens:int
    unix.getrlimit(resource:int)  ├─→ soft:int, hard:int
    unix.Dir:read()               ├─→ name:str, kind:int, ino:int, off:int  └─→ nil

`grep -n -B4 '^function unix.pipe(\|^function unix.getrlimit(\|^function unix.setitimer(' tool/net/definitions.lua | grep '@return' | head -3`:

    5021:---@return unix.Pipe|nil
    6955:---@return unix.Rlimit|nil
    6889:---@return unix.Itimerval|nil previous

`sed -n 264,269p tool/net/demo/redbean.lua`:

    m,a,b,c,d = re.search([[\([0-9]*\)\.\([0-9]*\)\.\([0-9]*\)\.\([0-9]*\)]], s, re.BASIC)
    m,a,b,c,d = re.search([[([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})]], s)
    ...
    m,a,b,c,d = pat:search(s)  -- m and rest are nil if match not found

`grep -n -B3 '^function re.search' tool/net/definitions.lua | grep @return`:

    1643:---@return re.SearchMatch|nil result the match, nil when nothing matched

`grep -n 'unix.wait' AGENTS.md` → `99:  info on failure: \`unix.wait\` (\`pid, wstatus, rusage\` vs. \`nil,`.
`git grep -n 'unix.wait' origin/master -- tool/net/demo tool/lua | grep -v 'result'`
finds only bare `unix.wait()` / `unix.wait(-1)` calls whose results are
unused (`unix-unix.lua:7,65`, `unix-subprocess.lua:48`): no other demo
destructures the old shape.
